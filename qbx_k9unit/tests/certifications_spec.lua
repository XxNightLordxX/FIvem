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

--- @param opts table? -- { includePartnershipHook: boolean (default true), departments: table (default 2-dept Config.Departments), allowSelfCert: boolean (default true), proximityMeters: number (default 5.0) }
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

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

    local playersBySource = {}
    local playersByCitizenId = {}

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
    }
    if Config.AllowSelfCertification == nil then Config.AllowSelfCertification = true end

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

    local env = Sandbox.newEnv(overrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/certifications.lua', env)

    return {
        env = env,
        state = state,
        notifyLog = notifyLog,
        outboundEvents = outboundEvents,
        leashDetachCalls = leashDetachCalls,
        officerLeashDetachCalls = officerLeashDetachCalls,
        partnershipBreakCalls = partnershipBreakCalls,
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

t.test('GrantCertification: a target whose LIVE ped model is not a configured K9 model is rejected, even if job/proximity pass', function()
    local f = newFixture()
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

    t.equals(updateParams[1], 'REVOKER')
    t.equals(updateParams[2], 'REVOKEE')
    t.equals(updateParams[3], 'police')
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

    t.equals(updateParams[1], 'REVOKER')
    t.equals(updateParams[2], 'REVOKEE')
    t.equals(updateParams[3], 'police')
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

    t.equals(updateParams[1], 'system:job_change')
    t.equals(updateParams[2], 'CIT40')
    t.equals(updateParams[3], 'police')
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

os.exit(t.summary())
