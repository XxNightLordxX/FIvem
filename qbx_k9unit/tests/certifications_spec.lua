--[[
    tests/certifications_spec.lua

    Direct + indirect tests of server/certifications.lua -- the authorization
    root of this entire resource (HasK9Access gates nearly every feature) --
    against the REAL, unmodified production file. Before this spec, this
    file had ZERO direct coverage despite being the single most
    security-sensitive file in the resource.

    HasK9Access/RefreshCertificationCache/IsConfiguredK9Model are exposed
    resource-globals (no `local`), reached directly. GrantCertification,
    RevokeCertification, RevokeCertificationOffline, and the
    QBCore:Server:OnJobUpdate auto-revoke handler are all `local` -- reached
    the same way a real caller does, through the captured
    RegisterNetEvent/RegisterCommand/AddEventHandler entry points this file
    itself wires them into (same convention as admin_spec.lua/
    progression_spec.lua).

    Loads server/cooldowns.lua into the SAME sandbox env FIRST:
    certifications.lua's own file-load-time `NewCooldown(1500)` call
    (CertifyActionCooldown) needs the real constructor in scope, same
    load-order requirement fxmanifest.lua's own server_scripts list already
    documents. Every test that fires more than one grant/revoke/decertify
    action from the SAME granter source must advance the fake clock by more
    than CERTIFY_ACTION_COOLDOWN_MS (1500) between calls, or the 2nd+ call is
    a silent, by-design no-op -- see newFixture()'s `state.now` / each such
    test's own comment.

    Unlike most specs in this suite, `locale` is NEVER stubbed here
    (Sandbox.newEnv already wires the real locale() reader over the real
    locales/en.json) -- per this task's own brief, every notify path this
    spec drives therefore doubles as a check that the locale key it resolves
    genuinely exists. Expected notification text is built by calling the
    SAME Sandbox.locale(...) the production code calls, rather than
    hardcoding a copy of the English string here, so this spec can never
    silently drift from en.json's actual wording while still asserting
    real content, not just "some string was sent".

    GENUINE FINDING (not a deviation to paper over): this file was audited
    for `assert(...)` calls at file-load time (the shape server/
    propattachment.lua, server/bonetool.lua, server/progression.lua,
    server/admin.lua, and server/search.lua all use to fail loudly at
    resource start on a malformed Config table). server/certifications.lua
    has ZERO such asserts -- a malformed Config.Departments entry (e.g. a
    missing/non-numeric certifierGrade, or Config.Peds containing a
    non-string `model` field) is never validated at load time here; it would
    instead surface later, silently, as a certifier who can never certify
    anyone (job.grade.level >= dept.certifierGrade against a nil/non-number
    certifierGrade is simply always false) or a K9 model that can never pass
    IsConfiguredK9Model. No "startup asserts" section is written below for
    this file because there is nothing to exercise -- see this spec's final
    report for the same note. This is disclosed, not silently worked around.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- GrantCertification/RevokeCertification's proximity
-- check does `#(GetEntityCoords(a) - GetEntityCoords(b))`, so both the `-`
-- and `#` metamethods must be modeled, same as tenure_spec.lua's own vec3.
-- ----------------------------------------------------------------------

local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end

-- Model hash constants shared by every fixture below (matches
-- Config.Peds -- see newFixture()).
local K9_HASH_SHEPHERD = 111
local K9_HASH_ROTTWEILER = 112
local NON_K9_HASH = 999

local function GetHashKey(modelName)
    local hashes = { a_c_shepherd = K9_HASH_SHEPHERD, a_c_rottweiler = K9_HASH_ROTTWEILER }
    return hashes[modelName] or 0
end

-- ----------------------------------------------------------------------
-- Fixture builder: one fresh env + fresh load of cooldowns.lua +
-- certifications.lua per top-level scenario, exactly like
-- tenure_spec.lua's newTenureFixture -- this file's local `Certifications`
-- cache, `GrantInFlight` lock table, and `CertifyActionCooldown` state must
-- never leak between unrelated test cases.
-- ----------------------------------------------------------------------

--- @param opts table? -- { includePartnershipHook: boolean (default true), departments: table (default 2-dept Config.Departments), allowSelfCert: boolean (default true), proximityMeters: number (default 5.0), features: table? (Config.Features -- default nil, matching every pre-existing test's shipped-default posture), expiryDays/expiryWarningDays/expiryCheckIntervalMs: number?, k9Specializations: table? }
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000, nowUnix = 1700000000 }
    local function GetGameTimer() return state.now end
    -- CERTIFICATION DEPTH (this pass): a SEPARATE fake clock from
    -- GetGameTimer's `state.now` (ms-since-resource-start) -- os.time()
    -- models real wall-clock epoch seconds, a genuinely different axis
    -- this file's own EXPIRY design deliberately keeps as the ONLY
    -- Lua-side wall-clock read (see certifications.lua's own NowUnix doc
    -- comment). Overridable per test via advanceUnixTime below.
    local osStub = { time = function() return state.nowUnix end }

    -- CERTIFICATION DEPTH (this pass): GetPlayers() backs
    -- TickCertificationExpiryWarnings' sweep loop -- reflects whichever
    -- sources are CURRENTLY registered (registerPlayer/disconnectPlayer),
    -- exactly like the real native. Returns STRING ids, matching FiveM's
    -- own documented GetPlayers() contract (server/main.lua's own
    -- onResourceStart backfill loop already assumes/tonumber()s this same
    -- shape).
    local playersBySourceRef -- forward-declared; assigned once playersBySource itself exists below
    local function GetPlayers()
        local out = {}
        for src in pairs(playersBySourceRef) do
            out[#out + 1] = tostring(src)
        end
        return out
    end

    local notifyLog = {} -- { {source=, message=, kind=}, ... }
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local outboundEvents = {} -- { {eventName, ...}, ... }
    local function TriggerEvent(eventName, ...)
        outboundEvents[#outboundEvents + 1] = { eventName, ... }
    end

    local leashDetachCalls = {}         -- ForceDetachLeashForSource(src, reason)
    local officerLeashDetachCalls = {}  -- ForceDetachOfficerLeashForSource(src, reason)
    local partnershipBreakCalls = {}    -- ForceBreakPartnershipForCitizenId(citizenid, reason)
    local effectEndCalls = {}           -- EndActiveEffectForHolder(src) -- server/combat.lua, called via pcall at every "must not outlive certification" call site in the production file; never previously stubbed/observed by this spec (opts.includeEffectHook, default true, mirrors opts.includePartnershipHook's own existence-guard test below)

    local playersBySource = {}
    local playersByCitizenId = {}
    playersBySourceRef = playersBySource

    --- @param source number
    --- @param citizenid string
    --- @param job table -- { name, isboss?, grade? = { level } }
    local function registerPlayer(source, citizenid, job)
        local metaWrites = {}
        local p = {
            PlayerData = { citizenid = citizenid, job = job, source = source },
            Functions = {
                SetMetaData = function(key, value)
                    metaWrites[#metaWrites + 1] = { key = key, value = value }
                end,
            },
            _metaWrites = metaWrites,
        }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return p
    end

    --- Simulates a genuine disconnect: removed from BOTH lookup maps, exactly
    --- like the real qbx_core GetPlayer/GetPlayerByCitizenId would behave for
    --- someone no longer connected.
    --- @param source number
    local function disconnectPlayer(source)
        local p = playersBySource[source]
        if not p then return end
        playersBySource[source] = nil
        playersByCitizenId[p.PlayerData.citizenid] = nil
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local pedsBySource = {}
    local pedCoordsByPed = {}
    local pedModelByPed = {}

    local function GetPlayerPed(source) return pedsBySource[source] or 0 end
    local function GetEntityCoords(ped) return pedCoordsByPed[ped] or vec3(0, 0, 0) end
    local function GetEntityModel(ped) return pedModelByPed[ped] end

    --- @param source number
    --- @param pedHandle number
    --- @param coords table -- vec3(x,y,z)
    --- @param modelHash number?
    local function setPed(source, pedHandle, coords, modelHash)
        pedsBySource[source] = pedHandle
        pedCoordsByPed[pedHandle] = coords
        if modelHash then pedModelByPed[pedHandle] = modelHash end
    end

    local mysql = {
        scalar = { await = function(_sql, _params) return nil end }, -- default: "no existing active row"
        insert = { await = function(_sql, _params) return 1 end },   -- default: insert succeeds, fake id 1
        update = { await = function(_sql, _params) return 1 end },   -- default: exactly one row affected
        -- CERTIFICATION DEPTH (this pass): RefreshCertificationCache's tier/
        -- expiry metadata read and RefreshSpecializationCache both go through
        -- MySQL.single.await / MySQL.query.await respectively -- default to
        -- "no metadata row" / "no active specializations" so every
        -- PRE-EXISTING test (which only ever stubs scalar/insert/update) gets
        -- a real, working default rather than an unstubbed-field crash.
        single = { await = function(_sql, _params) return nil end },
        query = { await = function(_sql, _params) return {} end },
    }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local capturedCommands = {}
    local function RegisterCommand(name, fn, restricted) capturedCommands[name] = { fn = fn, restricted = restricted } end

    local eventHandlers = {} -- eventName -> { fn, fn, ... }
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local Config = {
        Peds = {
            { model = 'a_c_shepherd' },
            { model = 'a_c_rottweiler' },
        },
        Departments = opts.departments or {
            police = { label = 'Police Department', certifierGrade = 4, autoAccessGrade = nil },
            sheriff = { label = 'Sheriff', certifierGrade = 3, autoAccessGrade = nil },
        },
        AllowSelfCertification = opts.allowSelfCert,
        CertifyProximityMeters = opts.proximityMeters or 5.0,
        -- K9 role/model decoupling (coder-architect, server/appearance.lua,
        -- landed concurrently with this pass): GrantCertification's own
        -- §4.2.5 model check now only runs when
        -- Config.K9Appearance.requireK9ModelForRole is explicitly true --
        -- absent here by default so most tests match this file's own
        -- pre-decoupling shape (Config.Peds/model-hash tests below opt
        -- in explicitly via opts.k9Appearance where the model check itself
        -- is under test).
        K9Appearance = opts.k9Appearance,
        -- CERTIFICATION DEPTH (this pass): Features/expiry knobs default to
        -- ABSENT (nil), matching every pre-existing test's shipped-default
        -- posture (the feature is off until a test explicitly opts in via
        -- opts.features) -- see this fixture's own header for the full
        -- opts shape.
        Features = opts.features,
        CertificationExpiryDays = opts.expiryDays,
        CertificationExpiryWarningDays = opts.expiryWarningDays,
        CertificationExpiryCheckIntervalMs = opts.expiryCheckIntervalMs,
        K9Specializations = opts.k9Specializations or {
            narcotics = { label = 'Narcotics detection' },
            explosives = { label = 'Explosives detection' },
        },
    }
    if Config.AllowSelfCertification == nil then Config.AllowSelfCertification = true end

    -- CERTIFICATION DEPTH (this pass): the sweep thread's own
    -- CreateThread(...) call happens at THIS FILE'S OWN LOAD TIME (gated
    -- on Config.Features.CertificationExpiry), so the thread runner and
    -- CapturingWait must both be wired into `overrides` BEFORE
    -- Sandbox.loadInto below -- mirrors tests/tenure_spec.lua's own
    -- identical setup for server/tenure.lua's tick loop.
    local threadRunner = Sandbox.newThreadRunner()
    local waitCalls = {}
    local function CapturingWait(ms)
        waitCalls[#waitCalls + 1] = ms
        return threadRunner.Wait(ms)
    end

    local overrides = {
        Config = Config,
        GetHashKey = GetHashKey,
        exports = exportsStub,
        NotifyPlayer = NotifyPlayer,
        MySQL = mysql,
        TriggerEvent = TriggerEvent,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        GetGameTimer = GetGameTimer,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        AddEventHandler = AddEventHandler,
        lib = libStub,
        print = printStub,
        ForceDetachLeashForSource = function(src, reason) leashDetachCalls[#leashDetachCalls + 1] = { src, reason } end,
        ForceDetachOfficerLeashForSource = function(src, reason) officerLeashDetachCalls[#officerLeashDetachCalls + 1] = { src, reason } end,
        os = osStub,
        GetPlayers = GetPlayers,
        CreateThread = threadRunner.CreateThread,
        Wait = CapturingWait,
    }
    -- ForceBreakPartnershipForCitizenId is runtime-existence-guarded
    -- (`type(...) == 'function'`) at every call site in the production file
    -- -- included by default so most tests can assert it fires; a dedicated
    -- test below passes includePartnershipHook = false to confirm the guard
    -- itself actually tolerates the global being entirely absent.
    if opts.includePartnershipHook ~= false then
        overrides.ForceBreakPartnershipForCitizenId = function(citizenid, reason)
            partnershipBreakCalls[#partnershipBreakCalls + 1] = { citizenid, reason }
        end
    end
    -- EndActiveEffectForHolder is runtime-existence-guarded
    -- (`type(...) == 'function'`, always inside a pcall) at every call site
    -- in the production file, exactly like ForceBreakPartnershipForCitizenId
    -- above -- included by default so tests can assert it fires; pass
    -- includeEffectHook = false to confirm a call site's own guard
    -- tolerates the global being entirely absent (server/combat.lua not
    -- loaded / Config.Features.BiteAndHold off).
    if opts.includeEffectHook ~= false then
        overrides.EndActiveEffectForHolder = function(src)
            effectEndCalls[#effectEndCalls + 1] = src
        end
    end

    local env = Sandbox.newEnv(overrides)

    -- server/datastore.lua -- REAL, unmodified, loaded first (fxmanifest.lua's
    -- own load order: the only file allowed to call MySQL.* directly).
    -- server/certifications.lua's own k9_certifications/
    -- k9_certification_specializations reads and writes now go through
    -- K9Store.* rather than a local MySQL.*.await call -- Config.Database
    -- is deliberately absent from this fixture's Config table above, so
    -- K9Store's own DatabaseEnabled() fails safe to `true` (real-DB mode),
    -- routing every K9Store.* call straight through to this fixture's own
    -- `mysql` stub above, unchanged -- including every scalarCallCount-
    -- style call-count assertion below (see this file's own header note
    -- added at the certifications.lua call site for the full reasoning).
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    Sandbox.loadInto('../server/certifications.lua', env)

    return {
        env = env,
        state = state,
        notifyLog = notifyLog,
        outboundEvents = outboundEvents,
        leashDetachCalls = leashDetachCalls,
        officerLeashDetachCalls = officerLeashDetachCalls,
        partnershipBreakCalls = partnershipBreakCalls,
        effectEndCalls = effectEndCalls,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        setPed = setPed,
        mysql = mysql,
        events = capturedEvents,
        commands = capturedCommands,
        callbacks = capturedCallbacks,
        eventHandlers = eventHandlers,
        printLog = printLog,
        setSource = function(src) env.source = src end,
        advanceTime = function(ms) state.now = state.now + ms end,
        -- CERTIFICATION DEPTH (this pass): advances the SEPARATE os.time()
        -- fake clock (real wall-clock seconds), independent of advanceTime
        -- above (GetGameTimer ms).
        advanceUnixTime = function(seconds) state.nowUnix = state.nowUnix + seconds end,
        threadRunner = threadRunner,
        waitCalls = waitCalls,
    }
end

--- @param f table -- a newFixture() result
--- @param source number
--- @return table? -- the LAST notifyLog entry for that source, or nil
local function lastNotifyFor(f, source)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == source then found = entry end
    end
    return found
end

--- @param f table
--- @param source number
--- @param message string
--- @param kind string
--- @return boolean
local function notifiedExactly(f, source, message, kind)
    local entry = lastNotifyFor(f, source)
    return entry ~= nil and entry.message == message and entry.kind == kind
end

--- Unlike notifiedExactly (last entry only), scans EVERY notifyLog entry
--- for `source` -- needed for self-certification, where granterSrc ==
--- targetServerId and BOTH the granter-facing and target-facing
--- NotifyPlayer calls land on the SAME source, so the target message
--- overwrites the granter message as far as "last" is concerned.
--- @param f table
--- @param source number
--- @param message string
--- @param kind string
--- @return boolean
local function anyNotify(f, source, message, kind)
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == source and entry.message == message and entry.kind == kind then return true end
    end
    return false
end

-- COOLDOWN CONSTANT mirrored from the production file's own
-- CERTIFY_ACTION_COOLDOWN_MS (1500) -- not re-derived from the source, just
-- named here so every advanceTime() call below documents WHY it needs to
-- exceed this value.
local COOLDOWN_MS = 1500

-- ======================================================================
-- HasK9Access -- the gate everything else trusts
-- ======================================================================

t.test('HasK9Access: a certified handler in the exact cached job passes', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 42 end -- an active row exists
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1))
end)

t.test('HasK9Access: a player with no cert at all (never refreshed) fails -- pure cache miss', function()
    local f = newFixture()
    f.registerPlayer(2, 'CIT2', { name = 'police', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(2))
end)

t.test('HasK9Access: an unknown citizenid (never seen by this cert system at all) fails, not errors', function()
    local f = newFixture()
    f.registerPlayer(3, 'NEVER-SEEN-CITIZENID', { name = 'police', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(3))
end)

t.test('HasK9Access: cached ACTIVE cert scoped to a DIFFERENT job than the player\'s current job fails (stale cache after a job change)', function()
    local f = newFixture()
    -- CIT4 was certified for police, then switched jobs to sheriff, but
    -- RefreshCertificationCache has not yet re-scoped the cache to sheriff.
    f.mysql.scalar.await = function() return 7 end
    f.env.RefreshCertificationCache('CIT4', 'police')
    f.registerPlayer(4, 'CIT4', { name = 'sheriff', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(4), 'a cert cached for a DIFFERENT job must never grant access under the new job')
end)

t.test('HasK9Access: cached INACTIVE cert (revoked) fails even though a cache entry exists', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return nil end -- no active row -> RefreshCertificationCache caches active=false
    f.env.RefreshCertificationCache('CIT5', 'police')
    f.registerPlayer(5, 'CIT5', { name = 'police', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(5))
end)

t.test('HasK9Access: a job not in Config.Departments fails outright, never consults the cache', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return 99 end
    f.env.RefreshCertificationCache('CIT6', 'taxi')
    f.registerPlayer(6, 'CIT6', { name = 'taxi', grade = { level = 99 } })
    t.isFalse(f.env.HasK9Access(6))
end)

t.test('HasK9Access: GetPlayer resolving to nil (unknown/disconnected source) fails', function()
    local f = newFixture()
    t.isFalse(f.env.HasK9Access(9999))
end)

t.test('HasK9Access: a player object with no PlayerData fails', function()
    local f = newFixture()
    f.env.exports.qbx_core.GetPlayer = function(_self, source)
        if source == 7 then return { PlayerData = nil } end
    end
    t.isFalse(f.env.HasK9Access(7))
end)

t.test('HasK9Access: autoAccessGrade bypass grants access with NO cert cached at all, once grade meets the threshold', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(8, 'CIT8', { name = 'police', grade = { level = 10 } })
    t.isTrue(f.env.HasK9Access(8), 'grade 10 >= autoAccessGrade 10 must bypass the cert requirement entirely')
end)

t.test('HasK9Access: autoAccessGrade bypass does NOT apply below the configured threshold', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(9, 'CIT9', { name = 'police', grade = { level = 9 } })
    t.isFalse(f.env.HasK9Access(9))
end)

t.test('HasK9Access: autoAccessGrade configured but job.grade itself is missing fails defensively, never errors', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(10, 'CIT10', { name = 'police' }) -- no .grade field at all
    t.isFalse(f.env.HasK9Access(10))
end)

t.test('HasK9Access: with autoAccessGrade nil (shipped default), a high grade alone never bypasses the cert requirement', function()
    local f = newFixture() -- shipped-shape Config.Departments.police.autoAccessGrade = nil
    f.registerPlayer(11, 'CIT11', { name = 'police', isboss = true, grade = { level = 99 } })
    t.isFalse(f.env.HasK9Access(11), 'isboss/high grade with no active cert and no autoAccessGrade configured must still fail -- matches the shipped Config.AllowSelfCertification default not implying an access bypass')
end)

-- ======================================================================
-- GrantCertification -- reached via the captured net event; env.source is
-- the ambient global the real RegisterNetEvent closure reads, exactly as
-- FXServer would set it per-invocation.
-- ======================================================================

t.test('GrantCertification: a non-numeric targetServerId is rejected outright, before any MySQL call', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    local scalarCalled = false
    f.mysql.scalar.await = function() scalarCalled = true end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler']('not-a-number')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.invalid_target'), 'error'))
    t.isFalse(scalarCalled)
end)

t.test('GrantCertification: a granter who is not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4, not boss
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.not_authorized_to_certify'), 'error'))
end)

t.test('GrantCertification: the certifier action cooldown silently no-ops the second rapid call from the SAME granter (no notification at all)', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2) -- first call: succeeds
    local notifyCountAfterFirst = #f.notifyLog
    f.events['qbx_k9unit:server:certifyHandler'](2) -- second call, same tick: on cooldown
    t.equals(#f.notifyLog, notifyCountAfterFirst, 'a cooldown rejection must be a silent no-op, matching the bark/leash-request convention documented in the source')
end)

t.test('GrantCertification: self-certification is rejected when Config.AllowSelfCertification is false', function()
    local f = newFixture({ allowSelfCert = false })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.self_certification_disabled'), 'error'))
end)

t.test('GrantCertification: an offline target (not currently connected) is rejected -- grant requires an online target', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2) -- source 2 never registered -> offline
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_must_be_online'), 'error'))
end)

t.test('GrantCertification: a target not employed by any configured department is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'taxi', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_not_in_department'), 'error'))
end)

t.test('GrantCertification: a target beyond Config.CertifyProximityMeters is rejected (live server-side coords, not client-claimed)', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(100, 0, 0), K9_HASH_SHEPHERD) -- 100m away, target IS K9-modeled
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_too_far_to_certify'), 'error'))
end)

t.test('GrantCertification: proximity is skipped for self-certification (nothing to measure distance to)', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD) -- self-cert: same ped serves as both granter and target
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    -- Self-cert means granterSrc == targetServerId, so BOTH the
    -- granter-facing and target-facing NotifyPlayer calls land on the same
    -- source -- use anyNotify (scans every entry), not notifiedExactly
    -- (last entry only, which here would only ever see the target-facing
    -- message since it's sent second).
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'a huge proximity would have rejected this if it were checked -- self-cert must skip it entirely')
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_target'), 'success'))
end)

t.test('GrantCertification: a target whose LIVE ped model is not a configured K9 model is rejected, even if job/proximity pass (Config.K9Appearance.requireK9ModelForRole opted in)', function()
    -- K9 role/model decoupling (coder-architect, server/appearance.lua):
    -- this check now only runs when explicitly opted in -- see this
    -- fixture's own Config.K9Appearance comment above.
    local f = newFixture({ k9Appearance = { requireK9ModelForRole = true } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), NON_K9_HASH)
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_not_k9_model'), 'error'))
end)

t.test('GrantCertification: an already-actively-certified target (existingId pre-check) is rejected as a no-op, never reaches the INSERT', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.scalar.await = function() return 55 end -- an active row already exists
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_already_certified'), 'inform'))
    t.isFalse(insertCalled)
end)

t.test('GrantCertification: full success path -- INSERT fires once, cache reflects the new active grant, both parties notified, outbound event fired, k9certified mirror set', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    local target = f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 77 end
    -- The SAME MySQL.scalar.await backs both the pre-check (must see "no
    -- existing row" to let the insert proceed) and the post-insert
    -- RefreshCertificationCache re-query (must now see the row this INSERT
    -- just created) -- model that with a call counter rather than a single
    -- static return, or the cache would incorrectly re-read as inactive
    -- immediately after its own successful grant.
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end -- pre-check: nothing active yet
        return 77 -- post-insert refresh: the row this INSERT just created
    end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.grant_success_target'), 'success'))
    t.equals(insertParams[1], 'TARGET')
    t.equals(insertParams[2], 'police')
    t.equals(insertParams[3], 'GRANTER')
    t.isTrue(f.env.HasK9Access(20), 'the cache must reflect the fresh grant immediately, without a separate PlayerLoaded/refresh')
    t.equals(target._metaWrites[#target._metaWrites].key, 'k9certified')
    t.isTrue(target._metaWrites[#target._metaWrites].value)

    local firedGrant = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationGranted' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 'GRANTER' then
            firedGrant = true
        end
    end
    t.isTrue(firedGrant, 'the outbound integration event must fire only after the INSERT + cache refresh already committed')
end)

t.test('GrantCertification: a duplicate-key error thrown by the INSERT (DB backstop, uq_one_active_cert_per_job) is treated as the same "already certified" no-op, not a hard error', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.insert.await = function() error({ errno = 1062, message = 'Duplicate entry' }) end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_already_certified'), 'inform'))
end)

-- ----------------------------------------------------------------------
-- GrantInFlight concurrency lock -- the highest-value case in this file.
-- GrantCertification's check-then-INSERT sequence spans two MySQL awaits,
-- each of which yields the real FXServer coroutine. Two coroutines below
-- model two truly overlapping grant attempts for the SAME (citizenid, job)
-- through a MySQL stub that genuinely yields via coroutine.yield(), proving
-- the lock (not test-harness luck) is what prevents a double-insert.
-- ----------------------------------------------------------------------

t.test('GrantCertification: LOAD-BEARING -- two overlapping grants for the SAME (citizenid, job), interleaved through a yielding MySQL stub, produce exactly ONE insert', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER-A', { name = 'police', isboss = true })
    f.registerPlayer(11, 'GRANTER-B', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET-SHARED', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(11, 1011, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0), K9_HASH_SHEPHERD)

    local insertCount = 0
    local scalarCallCount = 0
    -- Every MySQL.scalar.await call (both the pre-check inside
    -- doGrantInsert AND the post-insert RefreshCertificationCache call)
    -- yields the calling coroutine here, modeling a real network round
    -- trip -- exactly the window the old code's TOCTOU bug lived in.
    f.mysql.scalar.await = function(_sql, _params)
        scalarCallCount = scalarCallCount + 1
        coroutine.yield()
        return nil -- no pre-existing active row, in every call, for this test
    end
    f.mysql.insert.await = function(_sql, _params)
        insertCount = insertCount + 1
        return insertCount
    end

    local coA = coroutine.create(function()
        f.setSource(10)
        f.events['qbx_k9unit:server:certifyHandler'](20)
    end)
    local coB = coroutine.create(function()
        f.setSource(11)
        f.events['qbx_k9unit:server:certifyHandler'](20)
    end)

    -- Run A up to its FIRST yield -- this is the point in real FXServer
    -- where A has already synchronously set GrantInFlight[lockKey] = true
    -- and is now suspended awaiting the pre-check SELECT.
    local okA1, errA1 = coroutine.resume(coA)
    t.isTrue(okA1, tostring(errA1))
    t.equals(coroutine.status(coA), 'suspended', 'coroutine A must be paused mid-flight at the MySQL pre-check await')

    -- Now let B run to completion. If the lock did not exist, B would reach
    -- its own pre-check SELECT (also stubbed to yield) and this resume
    -- would leave B suspended too, mirroring the exact double-insert bug
    -- this lock fixes. Because GrantInFlight[lockKey] was already set
    -- (synchronously, before A's own first yield), B must instead observe
    -- the lock and bail out BEFORE ever calling MySQL at all.
    local okB, errB = coroutine.resume(coB)
    t.isTrue(okB, tostring(errB))
    t.equals(coroutine.status(coB), 'dead', 'B must run to completion in a single resume -- proving it never reached (and therefore never yielded at) a MySQL call')

    -- Drain every remaining yield in A (pre-check, then the post-insert
    -- RefreshCertificationCache re-query) until it finishes.
    while coroutine.status(coA) ~= 'dead' do
        local okA, errA = coroutine.resume(coA)
        t.isTrue(okA, tostring(errA))
    end

    t.equals(insertCount, 1, 'exactly one INSERT must occur despite the interleaved concurrent attempt')
    t.equals(scalarCallCount, 2, 'both MySQL.scalar.await calls that DID happen must both be attributable to A alone (its own pre-check + its own post-insert cache refresh) -- B made zero MySQL calls')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'the winner (A) must see a real success')
    t.isTrue(notifiedExactly(f, 11, Sandbox.locale('certifications.target_already_certified'), 'inform'), 'the loser (B) must see the same "already certified" no-op a real post-facto duplicate would -- not an error, not silence')
end)

t.test('GrantCertification: LOAD-BEARING -- GrantInFlight is released even when the critical section throws an unexpected error, so a thrown error can never permanently block future grants for that (citizenid, job)', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER-X', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET-X', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1110, vec3(0, 0, 0))
    f.setPed(20, 1120, vec3(0, 0, 0), K9_HASH_SHEPHERD)

    local scalarShouldThrow = true
    f.mysql.scalar.await = function(_sql, _params)
        if scalarShouldThrow then
            error('simulated connection drop mid-flight')
        end
        return nil
    end
    local insertCount = 0
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20) -- errors inside doGrantInsert -> pcall catches it -> lock must still be released

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.grant_error'), 'error'), 'the caller must see the generic grant_error notification, not a raw Lua error')
    t.equals(insertCount, 0, 'the failed attempt must never have reached the INSERT')

    -- Advance past the certifier-action cooldown (same granter source) and
    -- retry the SAME (citizenid, job) with a now-working MySQL stub. If the
    -- lock had leaked (never released on the error path), this retry would
    -- be rejected as "already in flight" and insertCount would stay 0
    -- forever -- exactly the permanent-un-grantable-target regression this
    -- test guards against.
    f.advanceTime(COOLDOWN_MS + 1)
    scalarShouldThrow = false
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.equals(insertCount, 1, 'the retry must succeed -- proving GrantInFlight[lockKey] was genuinely released after the thrown error, not left held')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'the retry must be a real success, not another "already certified"/still-locked rejection')
end)

-- ======================================================================
-- RevokeCertification (online-capable, numeric targetServerId path) --
-- reached via the captured net event, same ambient-source convention as
-- GrantCertification above.
-- ======================================================================

t.test('RevokeCertification: full online success path -- UPDATE fires with the granter\'s citizenid, cache flips to inactive, leash force-detached, outbound event fired', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    local target = f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- seed an active cert first
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasK9Access(20), 'sanity: the target really is certified before the revoke')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    -- After the revoke, RefreshCertificationCache re-queries -- simulate the
    -- row now being inactive.
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` (nil,
    -- since no reason was passed) is now bound as params[2], shifting
    -- citizenid/job to params[3]/[4] -- see RevokeCertification's own
    -- comment on its UPDATE statement.
    t.equals(updateParams[1], 'REVOKER')
    t.isNil(updateParams[2])
    t.equals(updateParams[3], 'REVOKEE')
    t.equals(updateParams[4], 'police')
    t.isFalse(f.env.HasK9Access(20), 'access must be gone immediately after an online revoke')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.revoked_notice_online'), 'error'))
    t.equals(target._metaWrites[#target._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 20)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'certification_revoked')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[2] == 'REVOKEE' and ev[3] == 'police' and ev[4] == 'manual' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeCertification: a target holding no active cert for that department is a distinguishable no-op, not a silent success', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.update.await = function() return 0 end -- WHERE ... active = 1 matched nothing

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_not_actively_certified'), 'inform'))
    t.equals(#f.outboundEvents, 0, 'no outbound event must fire when nothing actually flipped')
end)

t.test('RevokeCertification: a target beyond proximity is rejected, same rule as grant', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(50, 0, 0))
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_too_far_to_revoke'), 'error'))
end)

t.test('RevokeCertification: a genuinely offline target (numeric-id path) is refused with a pointer to the offline command, never silently proceeds', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.setPed(10, 1010, vec3(0, 0, 0))
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](999) -- never registered -> offline
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_offline_use_decertify_offline'), 'error'))
    t.isFalse(updateCalled, 'the numeric-id revoke path must never attempt an UPDATE against an unresolvable offline target')
end)

t.test('RevokeCertification: not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.not_authorized_to_revoke'), 'error'))
end)

-- ----------------------------------------------------------------------
-- REGRESSION (dependency-verification pass): oxmysql's `.await` funnels
-- every query through one shared `await(fn, query, parameters)` whose
-- callback does `if error then return p:reject(error) end`, and a
-- REJECTED promise raises via `error(promise.value, 2)` inside
-- `Citizen.Await` -- a real DB error (bad connection, deadlock, schema
-- drift) THROWS out of a bare `.await` call, it does not return nil. This
-- file's revoke paths now pcall every `.await` (see RevokeCertification's
-- own doc comment above the UPDATE). The two cases below drive an
-- `error(...)`-throwing MySQL.update.await stub through the real,
-- unmodified production handler and assert: (1) the thrown error never
-- propagates out of the event handler, (2) the granter gets a sensible
-- notification either way, and (3) the in-memory Certifications cache
-- never diverges from what actually happened in the DB.
-- ----------------------------------------------------------------------

t.test('RevokeCertification: REGRESSION -- a throwing UPDATE that genuinely never committed (reconciliation confirms still active) never propagates, notifies revoke_error, and leaves the cert/leash/outbound state completely untouched', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- seed an active cert first
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasK9Access(20), 'sanity: really certified before the simulated outage')

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- Reconciliation SELECT (IsCertRowConfirmedActive) confirms the row is
    -- STILL active -- the UPDATE genuinely never committed.
    f.mysql.scalar.await = function() return 5 end

    f.setSource(10)
    local ok, err = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)
    t.isTrue(ok, 'the event handler must never propagate a thrown DB error: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_error'), 'error'), 'the granter must see a sensible error notification, not silence')
    t.isNil(lastNotifyFor(f, 20), 'the target must NOT be told their cert was revoked -- it genuinely was not')
    t.isTrue(f.env.HasK9Access(20), 'NO PARTIAL STATE: the cache must still report the cert active, matching the DB (the UPDATE never committed)')
    t.equals(#f.leashDetachCalls, 0, 'no leash teardown must run for a revoke that never actually happened')
    t.equals(#f.outboundEvents, 0, 'no outbound certificationRevoked event for a revoke that never actually happened')
end)

t.test('RevokeCertification: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was, never left diverging from the DB', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    local target = f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasK9Access(20))

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    -- Every scalar.await call after the throwing UPDATE (the
    -- IsCertRowConfirmedActive reconciliation read, and then
    -- RefreshCertificationCache's own re-query on the fall-through success
    -- path) now sees the row as inactive -- confirming the UPDATE actually
    -- committed despite the client-side error.
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    local ok, err = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)
    t.isTrue(ok, 'must not propagate: ' .. tostring(err))

    t.isFalse(f.env.HasK9Access(20), 'the cache must reflect the CONFIRMED true outcome (revoked), never the failed client-side call alone')
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.revoked_notice_online'), 'error'), 'the target must be told their cert was actually revoked, since it genuinely was')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'), 'the granter must see a real success, not an error, once reconciliation confirms the DB truth')
    t.equals(target._metaWrites[#target._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 20)
end)

t.test('RevokeCertification: REGRESSION -- the reconciliation read ITSELF also failing (true outcome unknown) still degrades safely, never propagates, and never claims success it cannot confirm', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    f.mysql.scalar.await = function() error('simulated: DB still unreachable for the reconciliation read too') end

    f.setSource(10)
    local ok, err = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)
    t.isTrue(ok, 'must not propagate even when BOTH the UPDATE and the reconciliation read throw: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_error'), 'error'), 'an unconfirmable outcome must still notify an honest error, never silence')
    t.isTrue(f.env.HasK9Access(20), 'an unconfirmed outcome must never flip the cache toward "revoked" on a guess')
    t.equals(#f.outboundEvents, 0)
end)

-- ======================================================================
-- RevokeCertificationOffline -- the ONLY path reachable, per the file's own
-- header, through the '/k9decertifyoffline [citizenid] [job]' command (no
-- net-event counterpart exists for a genuinely disconnected target).
-- ======================================================================

t.test('RevokeCertificationOffline: full offline success path -- UPDATE fires, cache re-primed to inactive for next login, outbound event reason is manual_offline', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE is intentionally never registered -- genuinely offline.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end -- post-revoke re-cache: no active row

    f.commands['k9decertifyoffline'].fn(10, { 'REVOKEE', 'police' })

    -- CERTIFICATION DEPTH (this pass, Part A §2): same positional shift as
    -- the online path above.
    t.equals(updateParams[1], 'REVOKER')
    t.isNil(updateParams[2])
    t.equals(updateParams[3], 'REVOKEE')
    t.equals(updateParams[4], 'police')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[4] == 'manual_offline' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeCertificationOffline: SECURITY -- refuses outright when the "offline" citizenid is actually online right now, pointing the caller at /k9decertify instead (closes the proximity-check bypass)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'ACTUALLY-ONLINE', { name = 'police', grade = { level = 1 } })
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    f.commands['k9decertifyoffline'].fn(10, { 'ACTUALLY-ONLINE', 'police' })

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_online_use_decertify_command', 20), 'error'))
    t.isFalse(updateCalled, 'a currently-online target must never be revocable through the proximity-check-free offline path')
end)

t.test('RevokeCertificationOffline: a citizenid with no active cert for that department is a distinguishable no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.mysql.update.await = function() return 0 end
    f.commands['k9decertifyoffline'].fn(10, { 'NOBODY', 'police' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.offline_target_not_certified'), 'inform'))
end)

t.test('RevokeCertificationOffline: a typo\'d/unconfigured department is rejected outright, never runs a query that could never match', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.commands['k9decertifyoffline'].fn(10, { 'SOMEONE', 'not-a-real-department' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.invalid_department', 'not-a-real-department'), 'error'))
    t.isFalse(updateCalled)
end)

t.test('RevokeCertificationOffline: a missing job argument is rejected with the usage message, matching the command\'s own arg-shape guard', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.commands['k9decertifyoffline'].fn(10, { 'SOMEONE' }) -- args[2] missing
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.usage_decertify_offline'), 'error'))
end)

t.test('RevokeCertificationOffline: REGRESSION -- a throwing UPDATE degrades safely (reconciliation confirms still active), never propagates, notifies revoke_error, and leaves the cert untouched', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- Seed the cache as actively certified for REVOKEE (citizenid-keyed,
    -- independent of being online -- REVOKEE is intentionally never
    -- registered here, exactly like the offline success test above).
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- Reconciliation (IsCertRowConfirmedActive) confirms the row is STILL
    -- active -- the UPDATE genuinely never committed.
    f.mysql.scalar.await = function() return 5 end

    local ok, err = pcall(f.commands['k9decertifyoffline'].fn, 10, { 'REVOKEE', 'police' })
    t.isTrue(ok, 'the command handler must never propagate a thrown DB error: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_error'), 'error'))
    t.equals(#f.outboundEvents, 0, 'no outbound certificationRevoked event for a revoke that never actually happened')

    -- NO PARTIAL STATE: REVOKEE's certification cache must still be
    -- observably active for their real, current job.
    f.registerPlayer(21, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    t.isTrue(f.env.HasK9Access(21), 'the cache must still report the cert active, matching the DB (the UPDATE never committed)')
end)

-- ======================================================================
-- Automatic revoke-on-job-change (QBCore:Server:OnJobUpdate) -- no client
-- entry point at all, per the file's own header; fired directly via the
-- captured AddEventHandler closure with an explicit (source, job) pair.
-- ======================================================================

local function fireJobUpdate(f, source, newJob)
    f.eventHandlers['QBCore:Server:OnJobUpdate'][1](source, newJob)
end

t.test('OnJobUpdate: a same-department GRADE change (promotion/demotion) does NOT revoke the certification', function()
    local f = newFixture()
    f.registerPlayer(30, 'CIT30', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 3 end
    f.env.RefreshCertificationCache('CIT30', 'police')
    t.isTrue(f.env.HasK9Access(30))

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    fireJobUpdate(f, 30, { name = 'police', grade = { level = 5 } }) -- SAME job name, just a higher grade

    t.isFalse(updateCalled, 'a grade change within the same department must never trigger a revoke UPDATE')
    -- The player's job object was replaced with a new table (grade=5) but
    -- job.name is unchanged, so re-checking access should still reflect the
    -- cache untouched by this handler (still active for 'police').
    f.registerPlayer(30, 'CIT30', { name = 'police', grade = { level = 5 } })
    t.isTrue(f.env.HasK9Access(30), 'the cached cert must still be intact after a mere grade change')
end)

-- ======================================================================
-- FIX (this pass, "the worst bug this project has already fixed once" --
-- second door): an autoAccessGrade-only holder has no cached certification
-- row at all, so the grade-change guard above (correctly!) never revokes
-- anything for them via a DB write -- but that also meant NOTHING tore
-- down their leash/partnership/hold when a same-department demotion below
-- autoAccessGrade genuinely took their K9 access away. See OnJobUpdate's
-- own new doc comment (server/certifications.lua) for the full writeup.
-- ======================================================================

t.test('OnJobUpdate: FIX -- a same-department demotion below autoAccessGrade, for a citizenid with NO cached cert (autoAccessGrade was their ONLY route), force-detaches the leash, ends any held effect, and breaks the partnership', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(90, 'CIT90', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end -- never certified
    f.env.RefreshCertificationCache('CIT90', 'police') -- populates the cache as inactive, scoped to 'police' -- this is what PlayerLoaded/the onResourceStart backfill would already have done for a real, currently-connected player
    t.isTrue(f.env.HasK9Access(90), 'grade 5 >= autoAccessGrade 5 must grant access with no cert at all')

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    fireJobUpdate(f, 90, { name = 'police', grade = { level = 3 } }) -- demoted below the threshold, SAME department

    t.isFalse(updateCalled, 'there was never an active cert row to revoke -- no DB write should be attempted for this citizenid')
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 90)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'k9_access_lost')
    t.equals(f.effectEndCalls[#f.effectEndCalls], 90)
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][1], 'CIT90')
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][2], 'k9_access_lost')
end)

t.test('OnJobUpdate: FIX -- a same-department demotion that STAYS at/above autoAccessGrade does nothing (access genuinely unchanged)', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(91, 'CIT91', { name = 'police', grade = { level = 10 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT91', 'police')

    fireJobUpdate(f, 91, { name = 'police', grade = { level = 5 } }) -- still >= 5

    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: FIX -- a same-department demotion below autoAccessGrade does NOT tear anything down when the citizenid separately holds an active k9.access permission grant', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(92, 'CIT92', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT92', 'police')
    f.env.HasPermission = function(citizenid, key) return citizenid == 'CIT92' and key == 'k9.access' end

    fireJobUpdate(f, 92, { name = 'police', grade = { level = 1 } }) -- demoted well below the threshold

    t.equals(#f.leashDetachCalls, 0, 'the citizenid still has K9 access via the permission grant -- nothing to tear down')
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: FIX -- a same-department demotion below autoAccessGrade does NOT tear anything down when the citizenid is high command', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(93, 'CIT93', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT93', 'police')
    f.env.IsHighCommand = function(src) return src == 93 end

    fireJobUpdate(f, 93, { name = 'police', grade = { level = 1 } })

    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: FIX -- with NO cached entry at all for this citizenid (never logged in this session), the new autoAccessGrade branch is a disclosed no-op, leaving the existing behavior unchanged rather than guessing', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(94, 'CIT94', { name = 'police', grade = { level = 5 } })
    -- Deliberately never call RefreshCertificationCache -- `Certifications['CIT94']` stays nil.

    fireJobUpdate(f, 94, { name = 'police', grade = { level = 1 } })

    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: a REAL department change revokes the old cert, re-scopes the cache to the new job, notifies, and force-detaches the leash', function()
    local f = newFixture()
    local player = f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT40', 'police')
    t.isTrue(f.env.HasK9Access(40))

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end -- new job ('sheriff') has no active row

    fireJobUpdate(f, 40, { name = 'sheriff', grade = { level = 1 } })

    -- CERTIFICATION DEPTH (this pass, Part A §2): the automatic auto-revoke
    -- path always records revoke_reason='reassigned', now bound as
    -- params[2], shifting citizenid/job to params[3]/[4].
    t.equals(updateParams[1], 'system:job_change')
    t.equals(updateParams[2], 'reassigned')
    t.equals(updateParams[3], 'CIT40')
    t.equals(updateParams[4], 'police')
    t.isTrue(notifiedExactly(f, 40, Sandbox.locale('certifications.revoked_notice_job_change', 'Police Department'), 'error'))
    t.equals(player._metaWrites[#player._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 40)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'certification_revoked')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[2] == 'CIT40' and ev[3] == 'police' and ev[4] == 'job_changed' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('OnJobUpdate: losing department membership entirely (new job not in Config.Departments) force-detaches the OFFICER-role leash even with no cert of the player\'s own', function()
    local f = newFixture()
    f.registerPlayer(50, 'CIT50', { name = 'police', grade = { level = 1 } }) -- never certified -- pure handler/officer role
    fireJobUpdate(f, 50, { name = 'taxi', grade = { level = 1 } })
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 50)
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][2], 'department_changed')
    t.equals(#f.notifyLog, 0, 'a player with no active cert of their own must get no cert-revoke notification from this path')
end)

t.test('OnJobUpdate: a K9-role player who ALSO loses department membership entirely triggers BOTH the officer-role leash detach AND the cert-revoke leash detach -- pinned as observed, not assumed exclusive', function()
    -- FINDING (behavior pin, not a bug report): server/certifications.lua's
    -- header states an officer/handler-role party "never holds a K9
    -- certification of their own" as the reason the department-loss branch
    -- and the cert-revoke branch are independent. That's a gameplay
    -- invariant, not one this handler itself enforces -- a hypothetical
    -- citizenid holding an active cert whose NEW job is not a configured
    -- department at all satisfies BOTH branches' conditions, so both fire.
    local f = newFixture()
    f.registerPlayer(60, 'CIT60', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT60', 'police')

    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 60, { name = 'taxi', grade = { level = 1 } })

    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 60)
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][2], 'department_changed')
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 60)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'certification_revoked')
end)

t.test('OnJobUpdate: ForceBreakPartnershipForCitizenId is called for a real department change when the global is present', function()
    local f = newFixture()
    f.registerPlayer(70, 'CIT70', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT70', 'police')
    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 70, { name = 'taxi', grade = { level = 1 } })

    local found = false
    for _, call in ipairs(f.partnershipBreakCalls) do
        if call[1] == 'CIT70' and call[2] == 'department_changed' then found = true end
    end
    t.isTrue(found)
end)

t.test('OnJobUpdate: the runtime existence guard genuinely tolerates ForceBreakPartnershipForCitizenId being entirely absent (server/partnership.lua not loaded / feature off)', function()
    local f = newFixture({ includePartnershipHook = false })
    f.registerPlayer(80, 'CIT80', { name = 'police', grade = { level = 1 } })
    -- Must not error even though the department-loss branch would otherwise
    -- try to call a nonexistent global.
    fireJobUpdate(f, 80, { name = 'taxi', grade = { level = 1 } })
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 80, 'the rest of the handler must still run normally when this one optional global is absent')
end)

t.test('OnJobUpdate: REGRESSION -- a throwing auto-revoke UPDATE (reconciliation confirms still active) never propagates out of the AddEventHandler and runs ZERO side effects, leaving the cert intact', function()
    local f = newFixture()
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT40', 'police')
    t.isTrue(f.env.HasK9Access(40))

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- Reconciliation confirms the OLD job's row is STILL active.
    f.mysql.scalar.await = function() return 9 end

    local ok, err = pcall(fireJobUpdate, f, 40, { name = 'sheriff', grade = { level = 1 } })
    t.isTrue(ok, 'the AddEventHandler callback must never propagate a thrown DB error: ' .. tostring(err))

    t.equals(#f.notifyLog, 0, 'no accurate notification can be given for an outcome that was never confirmed')
    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
    t.equals(#f.outboundEvents, 0)

    -- NO PARTIAL STATE: re-register under the SAME (unchanged, per this
    -- test) job to confirm the cache still reports the original cert active.
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    t.isTrue(f.env.HasK9Access(40), 'the cache must still report the cert active for the OLD job -- it was never actually revoked')
end)

t.test('OnJobUpdate: REGRESSION -- a throwing auto-revoke UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and the normal revoke side effects still run against that confirmed truth', function()
    local f = newFixture()
    local player = f.registerPlayer(41, 'CIT41', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT41', 'police')
    t.isTrue(f.env.HasK9Access(41))

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    -- Reconciliation, and the later RefreshCertificationCache re-query for
    -- the new job, both see the OLD job's row as inactive.
    f.mysql.scalar.await = function() return nil end

    local ok, err = pcall(fireJobUpdate, f, 41, { name = 'sheriff', grade = { level = 1 } })
    t.isTrue(ok, 'must not propagate: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 41, Sandbox.locale('certifications.revoked_notice_job_change', 'Police Department'), 'error'))
    t.equals(player._metaWrites[#player._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 41)

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[2] == 'CIT41' and ev[3] == 'police' and ev[4] == 'job_changed' then fired = true end
    end
    t.isTrue(fired)
end)

-- ======================================================================
-- Command wiring -- k9certify / k9decertify have their OWN arg-parsing
-- guard (tonumber(args[1])) layered in front of the shared functions above;
-- these two tests exercise that layer specifically, distinct from the net
-- event path's `type(targetServerId) ~= 'number'` guard already covered.
-- ======================================================================

t.test('/k9certify command: a non-numeric args[1] is rejected with the usage message before GrantCertification is ever reached', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9certify'].fn(1, { 'not-a-number' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_certify'), 'error'))
end)

t.test('/k9decertify command: a non-numeric args[1] is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9decertify'].fn(1, {})
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_decertify'), 'error'))
end)

t.test('/k9certify command: a valid numeric string arg reaches the real grant flow end-to-end', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.commands['k9certify'].fn(1, { '2' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'))
end)

-- ======================================================================
-- lib.callback.register('qbx_k9unit:server:hasK9Access', ...) wiring
-- ======================================================================

t.test('hasK9Access callback: registered exactly once, and delegates to the real HasK9Access for the caller\'s own source', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(type(f.callbacks['qbx_k9unit:server:hasK9Access']) == 'function')
    t.isTrue(f.callbacks['qbx_k9unit:server:hasK9Access'](1))
    t.isFalse(f.callbacks['qbx_k9unit:server:hasK9Access'](999))
end)

-- ======================================================================
-- RefreshCertificationCache: fail-closed on a query error
-- ======================================================================

t.test('RefreshCertificationCache: a throwing MySQL.scalar.await fails CLOSED (active = false), never leaves a stale/unknown cache entry', function()
    local f = newFixture()
    f.registerPlayer(90, 'CIT90', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT90', 'police')
    t.isTrue(f.env.HasK9Access(90), 'sanity: really certified before the simulated outage')

    f.mysql.scalar.await = function() error('connection lost') end
    local active = f.env.RefreshCertificationCache('CIT90', 'police')
    t.isFalse(active, 'the return value itself must report the fail-closed result')
    t.isFalse(f.env.HasK9Access(90), 'an unreadable cert row must never be treated as an active grant')
end)

-- ======================================================================
-- CERTIFICATION DEPTH (this pass) -- Part A §2/§5/§9, Part B §11.
-- ======================================================================

-- ----------------------------------------------------------------------
-- MIGRATION PATH: RefreshCertificationCache's tier/expiry metadata read
-- must degrade cleanly on a pre-migration-0006 database (columns don't
-- exist yet -- MySQL.single.await throws), and must correctly parse a
-- real metadata row once they do exist.
-- ----------------------------------------------------------------------

t.test('RefreshCertificationCache: MIGRATION PATH -- a throwing tier/expiry metadata query (pre-0006 schema) still succeeds active=true, defaults to tier=certified with no expiry', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end -- existence check: active row confirmed
    f.mysql.single.await = function() error("unknown column 'tier' in 'field list' (simulated pre-migration-0006 schema)") end

    local active = f.env.RefreshCertificationCache('CIT1', 'police')

    t.isTrue(active, 'the base existence check must still succeed independent of the metadata query')
    t.isTrue(f.env.HasK9Access(1), 'access must not be affected by a metadata-read failure')
    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'certified', 'an unreadable tier must default to certified, never a less-privileged tier')
end)

t.test('RefreshCertificationCache: a real tier/expiry metadata row is parsed correctly into the cache', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior', expires_at_unix = 1700086400 } end -- 1 day after fixture's default nowUnix (1700000000)

    f.env.RefreshCertificationCache('CIT1', 'police')

    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'senior')
    t.isTrue(f.env.HasK9Access(1), 'not yet expired -- 1700086400 > nowUnix 1700000000')
end)

t.test('RefreshCertificationCache: an unrecognized tier value from the DB (data corruption) defaults to certified rather than an unranked string', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'not-a-real-tier', expires_at_unix = nil } end

    f.env.RefreshCertificationCache('CIT1', 'police')

    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'certified')
end)

-- ----------------------------------------------------------------------
-- EXPIRY BOUNDARIES
-- ----------------------------------------------------------------------

t.test('HasK9Access: EXPIRY BOUNDARY -- expiresAtUnix one second in the FUTURE still grants access', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000001 } end -- nowUnix + 1
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1))
end)

t.test('HasK9Access: EXPIRY BOUNDARY -- expiresAtUnix EXACTLY equal to now is treated as expired (>=, not >)', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 } end -- == nowUnix exactly
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isFalse(f.env.HasK9Access(1), 'the exact expiry second must already be treated as expired, not one grace second later')
end)

t.test('HasK9Access: EXPIRY BOUNDARY -- expiresAtUnix one second in the PAST is expired', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- nowUnix - 1
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isFalse(f.env.HasK9Access(1))
end)

t.test('HasK9Access: an expired cert falls through to the autoAccessGrade bypass rather than hard-failing', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 10 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- already expired
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1), 'grade 10 >= autoAccessGrade 10 must still bypass, independent of the expired cert')
end)

t.test('HasK9Access: EXPIRY -- a missing os.time() (environment anomaly) fails TOWARD availability, never toward lockout', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- would be expired, IF os.time() were readable
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isFalse(f.env.HasK9Access(1), 'sanity: genuinely expired under the real os stub')

    -- Simulate os.time being entirely unavailable and re-refresh -- IsExpiredUnix
    -- must degrade to "not expired" rather than erroring or defaulting to locked-out.
    f.env.os = nil
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1), 'a missing os.time must never be indistinguishable from "definitely expired"')
end)

-- ----------------------------------------------------------------------
-- READ-ONLY ACCESSORS: GetCertificationTier / MeetsTierRequirement /
-- HasSpecialization
-- ----------------------------------------------------------------------

t.test('GetCertificationTier: nil for a citizenid with no active/matching cert', function()
    local f = newFixture()
    t.isNil(f.env.GetCertificationTier('NOBODY', 'police'))
end)

t.test('MeetsTierRequirement: senior meets a certified requirement; trainee does not; an unrecognized minTier fails closed', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior' } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isTrue(f.env.MeetsTierRequirement('CIT1', 'police', 'certified'))
    t.isTrue(f.env.MeetsTierRequirement('CIT1', 'police', 'senior'))
    t.isFalse(f.env.MeetsTierRequirement('CIT1', 'police', 'not-a-real-tier'), 'an unrecognized minTier must never be treated as a low bar to clear')

    f.registerPlayer(2, 'CIT2', { name = 'police', grade = { level = 1 } })
    f.mysql.single.await = function() return { tier = 'trainee' } end
    f.env.RefreshCertificationCache('CIT2', 'police')
    t.isFalse(f.env.MeetsTierRequirement('CIT2', 'police', 'certified'))
end)

t.test('HasSpecialization: true only when BOTH the base cert is active/unexpired AND the specialization is active', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isTrue(f.env.HasSpecialization('CIT1', 'police', 'narcotics'))
    t.isFalse(f.env.HasSpecialization('CIT1', 'police', 'explosives'), 'a specialization never granted must read false')
end)

t.test('HasSpecialization: an EXPIRED base cert soft-disables its specializations too, without any DB write', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- expired
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isFalse(f.env.HasK9Access(1), 'sanity: base cert is expired')
    t.isFalse(f.env.HasSpecialization('CIT1', 'police', 'narcotics'), 'the specialization row is still active in the DB but must read as unusable while the base cert is expired')
end)

-- ----------------------------------------------------------------------
-- SetCertificationTier
-- ----------------------------------------------------------------------

t.test('SetCertificationTier: FAIL-CLOSED -- a granter who is not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4, not boss
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](2, 'senior')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.not_authorized_to_certify'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- an invalid tier name is rejected outright, before any MySQL call', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](2, 'not-a-real-tier')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.invalid_tier'), 'error'))
    t.isFalse(updateCalled)
end)

t.test('SetCertificationTier: FAIL-CLOSED -- self-action is rejected when Config.AllowSelfCertification is false', function()
    local f = newFixture({ allowSelfCert = false })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](1, 'senior')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.self_certification_disabled'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- an offline target is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](2, 'senior')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.action_target_must_be_online'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- a target beyond Config.CertifyProximityMeters is rejected', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(50, 0, 0))
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](2, 'senior')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.action_target_too_far'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- a target with no active certification for their current job is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } }) -- never certified
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(0, 0, 0))
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](2, 'senior')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_not_actively_certified'), 'error'))
end)

t.test('SetCertificationTier: already holding the requested tier is a distinguishable no-op', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('T1', 'police')
    f.setSource(1)
    f.events['qbx_k9unit:server:setCertificationTier'](2, 'certified')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.tier_already_set'), 'inform'))
end)

t.test('SetCertificationTier: TIER TRANSITION -- full success path promotes certified -> senior, updates the cache, notifies both parties, fires the outbound event', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'certified', 'sanity')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.single.await = function() return { tier = 'senior' } end -- post-update re-cache reflects the new tier

    f.setSource(10)
    f.events['qbx_k9unit:server:setCertificationTier'](20, 'senior')

    t.equals(updateParams[1], 'senior')
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'senior', 'the cache must reflect the promotion immediately')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.tier_change_success_granter', 'senior'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.tier_change_success_target', 'senior'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationTierChanged' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 'certified' and ev[5] == 'senior' and ev[6] == 'GRANTER' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('SetCertificationTier: TIER TRANSITION -- demotion certified -> trainee also succeeds (a non-punitive refresher, not a revoke)', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.single.await = function() return { tier = 'trainee' } end
    f.setSource(10)
    f.events['qbx_k9unit:server:setCertificationTier'](20, 'trainee')

    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'trainee')
    t.isTrue(f.env.HasK9Access(20), 'a trainee still holds BASE K9 access -- tiering only gates higher capability, never base access')
end)

t.test('SetCertificationTier: a thrown UPDATE reports tier_change_error, never a silent success', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.update.await = function() error('simulated connection drop') end
    f.setSource(10)
    local ok = pcall(f.events['qbx_k9unit:server:setCertificationTier'], 20, 'senior')
    t.isTrue(ok, 'must never propagate a thrown DB error')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.tier_change_error'), 'error'))
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'certified', 'the cache must be untouched by a failed update')
end)

t.test('/k9settier command: a non-numeric args[1] is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9settier'].fn(1, { 'not-a-number', 'senior' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_settier'), 'error'))
end)

-- ----------------------------------------------------------------------
-- RenewCertification
-- ----------------------------------------------------------------------

t.test('RenewCertification: FAIL-CLOSED -- disabled by default (Config.Features.CertificationExpiry absent) is rejected outright', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:renewCertification'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.renew_feature_disabled'), 'error'))
end)

t.test('RenewCertification: FAIL-CLOSED -- a granter who is not certifier-eligible is rejected even with the feature enabled', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:renewCertification'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.not_authorized_to_certify'), 'error'))
end)

t.test('RenewCertification: FAIL-CLOSED -- a target with no active certification is rejected', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(0, 0, 0))
    f.setSource(1)
    f.events['qbx_k9unit:server:renewCertification'](2)
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_not_actively_certified'), 'error'))
end)

t.test('RenewCertification: EXPIRY -- full success path extends expires_at via DATE_ADD(NOW(), INTERVAL ? DAY), refreshes the cache, clears the warned/lapsed flags, fires the outbound event', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000100 } end -- near-expiry
    f.env.RefreshCertificationCache('TARGET', 'police')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1707776000 } end -- ~90 days out, post-renewal

    f.setSource(10)
    f.events['qbx_k9unit:server:renewCertification'](20)

    t.equals(updateParams[1], 90)
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.renew_success_granter'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.renew_success_target'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRenewed' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 1707776000 and ev[5] == 'GRANTER' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RenewCertification: a thrown UPDATE reports renew_error, never a silent success', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.update.await = function() error('simulated connection drop') end
    f.setSource(10)
    local ok = pcall(f.events['qbx_k9unit:server:renewCertification'], 20)
    t.isTrue(ok)
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.renew_error'), 'error'))
end)

t.test('/k9recertify command: a non-numeric args[1] is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9recertify'].fn(1, {})
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_recertify'), 'error'))
end)

-- ----------------------------------------------------------------------
-- GrantSpecialization / RevokeSpecialization / RevokeSpecializationOffline
-- ----------------------------------------------------------------------

t.test('GrantSpecialization: FAIL-CLOSED -- an unconfigured specialization key is rejected outright', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    f.setSource(1)
    f.events['qbx_k9unit:server:grantSpecialization'](2, 'not-a-real-specialization')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.invalid_specialization'), 'error'))
end)

t.test('GrantSpecialization: FAIL-CLOSED -- a target with no active base certification is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    f.setSource(1)
    f.events['qbx_k9unit:server:grantSpecialization'](2, 'narcotics')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.specialization_requires_active_cert'), 'error'))
end)

t.test('GrantSpecialization: full success path -- INSERT fires, cache reflects the grant, both parties notified, outbound event fired', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- active base cert
    f.env.RefreshCertificationCache('TARGET', 'police')

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        return nil -- pre-check: no existing active specialization row
    end
    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 1 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end -- post-insert cache refresh

    f.setSource(10)
    f.events['qbx_k9unit:server:grantSpecialization'](20, 'narcotics')

    t.equals(insertParams[1], 'TARGET')
    t.equals(insertParams[2], 'police')
    t.equals(insertParams[3], 'narcotics')
    t.equals(insertParams[4], 'GRANTER')
    t.isTrue(f.env.HasSpecialization('TARGET', 'police', 'narcotics'))
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_grant_success_granter', 'narcotics'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.specialization_grant_success_target', 'narcotics'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationGranted' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 'narcotics' and ev[5] == 'GRANTER' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('GrantSpecialization: an already-held specialization (existingId pre-check) is rejected as a no-op, never reaches the INSERT', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.scalar.await = function() return 99 end -- existing active specialization row
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.setSource(10)
    f.events['qbx_k9unit:server:grantSpecialization'](20, 'narcotics')

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_already_granted'), 'inform'))
    t.isFalse(insertCalled)
end)

t.test('GrantSpecialization: a duplicate-key error thrown by the INSERT is treated as the same "already granted" no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.scalar.await = function() return nil end
    f.mysql.insert.await = function() error({ errno = 1062, message = 'Duplicate entry' }) end

    f.setSource(10)
    f.events['qbx_k9unit:server:grantSpecialization'](20, 'narcotics')

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_already_granted'), 'inform'))
end)

t.test('/k9specialize command: a non-numeric args[1] is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9specialize'].fn(1, { 'not-a-number', 'narcotics' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_specialize'), 'error'))
end)

t.test('RevokeSpecialization: FAIL-CLOSED -- a granter who is not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:revokeSpecialization'](2, 'narcotics')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.not_authorized_to_revoke'), 'error'))
end)

t.test('RevokeSpecialization: an offline target is refused with a pointer to the offline command', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:revokeSpecialization'](2, 'narcotics')
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.specialization_target_offline_use_offline_command'), 'error'))
end)

t.test('RevokeSpecialization: full online success path -- UPDATE fires, cache refreshed, outbound event reason is manual', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.query.await = function() return {} end -- post-revoke cache refresh: no active specializations left

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeSpecialization'](20, 'narcotics')

    t.equals(updateParams[1], 'REVOKER')
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_revoke_success_granter', 'narcotics'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.specialization_revoke_success_target', 'narcotics'), 'error'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[4] == 'narcotics' and ev[5] == 'manual' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeSpecialization: a specialization not currently held is a distinguishable no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.update.await = function() return 0 end
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeSpecialization'](20, 'narcotics')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_not_granted'), 'inform'))
end)

t.test('RevokeSpecializationOffline: full offline success path -- UPDATE fires, outbound event reason is manual_offline', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- TARGET intentionally never registered -- genuinely offline.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.query.await = function() return {} end

    f.commands['k9unspecializeoffline'].fn(10, { 'TARGET', 'police', 'narcotics' })

    t.equals(updateParams[1], 'REVOKER')
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_revoke_success_granter', 'narcotics'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[5] == 'manual_offline' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeSpecializationOffline: SECURITY -- refuses outright when the "offline" citizenid is actually online right now', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'ACTUALLY-ONLINE', { name = 'police', grade = { level = 1 } })
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.commands['k9unspecializeoffline'].fn(10, { 'ACTUALLY-ONLINE', 'police', 'narcotics' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_target_online_use_online_command', 20), 'error'))
    t.isFalse(updateCalled)
end)

t.test('RevokeSpecializationOffline: a typo\'d/unconfigured department is rejected outright', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.commands['k9unspecializeoffline'].fn(10, { 'SOMEONE', 'not-a-real-department', 'narcotics' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.invalid_department', 'not-a-real-department'), 'error'))
end)

t.test('/k9unspecialize command: a non-numeric args[1] is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9unspecialize'].fn(1, { 'not-a-number', 'narcotics' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_unspecialize'), 'error'))
end)

t.test('/k9unspecializeoffline command: a missing specialization argument is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.commands['k9unspecializeoffline'].fn(10, { 'SOMEONE', 'police' }) -- args[3] missing
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.usage_unspecialize_offline'), 'error'))
end)

-- ----------------------------------------------------------------------
-- SPECIALIZATION CASCADE: a specialization must not outlive the base
-- certification it requires.
-- ----------------------------------------------------------------------

t.test('RevokeCertification: CASCADE -- revoking the base certification also revokes every active specialization for that (citizenid, job)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    f.mysql.scalar.await = function() return 5 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasSpecialization('REVOKEE', 'police', 'narcotics'), 'sanity: specialization active before the revoke')

    local specUpdateParams
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then
            specUpdateParams = params
        end
        return 1
    end
    f.mysql.scalar.await = function() return nil end -- post-revoke base-cert re-cache: no active row

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    -- The cascade UPDATE is a BULK revoke over every active row for
    -- (citizenid, job) -- no `specialization = ?` filter, only 3 bound
    -- params -- unlike a single-specialization RevokeSpecialization call.
    t.isNotNil(specUpdateParams, 'the specialization cascade UPDATE must have fired')
    t.equals(specUpdateParams[1], 'REVOKER')
    t.equals(specUpdateParams[2], 'REVOKEE')
    t.equals(specUpdateParams[3], 'police')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[2] == 'REVOKEE' and ev[3] == 'police' and ev[4] == 'narcotics' and ev[5] == 'certification_revoked' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeCertificationOffline: CASCADE -- revoking an offline citizenid\'s base certification also revokes their active specializations (DB-authoritative, not cache-dependent)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE never registered -- genuinely offline, so its Specializations
    -- cache entry was never populated either -- proves the cascade reads the
    -- DB directly rather than relying on the in-memory cache (see
    -- RevokeAllSpecializationsForCitizenJob's own doc comment).
    local specUpdateParams
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then
            specUpdateParams = params
        end
        return 1
    end
    f.mysql.query.await = function() return { { specialization = 'explosives' } } end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertifyoffline'].fn(10, { 'REVOKEE', 'police' })

    t.isNotNil(specUpdateParams, 'the specialization cascade UPDATE must have fired for the offline path too')
    t.equals(specUpdateParams[1], 'REVOKER')
    t.equals(specUpdateParams[2], 'REVOKEE')
    t.equals(specUpdateParams[3], 'police')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[4] == 'explosives' and ev[5] == 'certification_revoked' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('OnJobUpdate: CASCADE -- a real department change also revokes every active specialization for the OLD (citizenid, job)', function()
    local f = newFixture()
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('CIT40', 'police')

    local specUpdateParams
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then
            specUpdateParams = params
        end
        return 1
    end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 40, { name = 'sheriff', grade = { level = 1 } })

    t.isNotNil(specUpdateParams)
    t.equals(specUpdateParams[1], 'system:job_change')
    t.equals(specUpdateParams[2], 'CIT40')
    t.equals(specUpdateParams[3], 'police')
end)

t.test('RevokeAllSpecializationsForCitizenJob: no active specializations means no UPDATE at all -- common case is a cheap no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police') -- no specializations seeded -- query.await defaults to {}

    local specUpdateCalled = false
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then specUpdateCalled = true end
        return 1
    end
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    t.isFalse(specUpdateCalled, 'no specialization UPDATE should run when the pre-read finds nothing active')
end)

-- ----------------------------------------------------------------------
-- EXPIRY WARNING SWEEP
-- ----------------------------------------------------------------------

t.test('TickCertificationExpiryWarnings: warns an online handler once within the warning window, then never again the same session', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90, expiryWarningDays = 7 })
    local target = f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    -- 3 days remaining (259200s) -- inside the 7-day warning window.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 + 259200 } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    -- Prime, then run one full sweep pass (fixtures/sandbox.lua's own
    -- newThreadRunner convention: the first step() only reaches the
    -- initial Wait()).
    f.threadRunner.step()
    f.threadRunner.step()

    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_warning', '3'), 'inform'))

    local warnCountAfterFirst = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 then warnCountAfterFirst = warnCountAfterFirst + 1 end
    end

    f.threadRunner.step() -- a second sweep pass, same session
    local warnCountAfterSecond = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 then warnCountAfterSecond = warnCountAfterSecond + 1 end
    end
    t.equals(warnCountAfterSecond, warnCountAfterFirst, 'a second sweep pass in the same session must not re-warn')
    t.isNotNil(target) -- silence unused-var lint
end)

t.test('TickCertificationExpiryWarnings: proactively announces a JUST-LAPSED certification once, never every tick', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- already lapsed
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.threadRunner.step()
    f.threadRunner.step()
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_lapsed_notice'), 'error'))

    local lapsedCount = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCount = lapsedCount + 1 end
    end
    f.threadRunner.step()
    local lapsedCountAfter = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCountAfter = lapsedCountAfter + 1 end
    end
    t.equals(lapsedCountAfter, lapsedCount, 'the lapsed notice must fire at most once per session')
end)

t.test('RenewCertification: clears the warned/lapsed session flags so a genuinely renewed handler can be warned again on its own future merits', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- lapsed
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.threadRunner.step()
    f.threadRunner.step()
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_lapsed_notice'), 'error'), 'sanity: lapsed notice sent once')

    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1707776000 } end -- renewed, far future
    f.setSource(10)
    f.events['qbx_k9unit:server:renewCertification'](20)

    local lapsedCountAfterRenewal = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCountAfterRenewal = lapsedCountAfterRenewal + 1 end
    end

    -- Simulate a SECOND, later lapse (e.g. the renewal's own new deadline
    -- eventually passes too) and confirm the flag genuinely resets rather
    -- than staying permanently silenced by the FIRST lapse this session.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end
    f.env.RefreshCertificationCache('TARGET', 'police')
    f.threadRunner.step()

    local lapsedCountAfterSecondLapse = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCountAfterSecondLapse = lapsedCountAfterSecondLapse + 1 end
    end
    t.equals(lapsedCountAfterSecondLapse, lapsedCountAfterRenewal + 1, 'a renewal must clear the one-per-session lapsed flag so a genuinely NEW lapse can be announced again')
end)

os.exit(t.summary())
