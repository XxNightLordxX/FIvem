--[[
    tests/tracking_spec.lua

    First test coverage for server/tracking.lua's per-person feature control
    (Config.FeatureControl -- config.lua's own documented 4-step
    resolution), added alongside that gate itself (see server/tracking.lua's
    own header, "PER-PERSON FEATURE CONTROL", for the design this pins).
    server/tracking.lua otherwise had ZERO existing spec coverage before
    this pass (confirmed: no tests/tracking_spec.lua existed at all,
    client/tracking.lua's own tests/clienttracking_spec.lua is a different
    file testing a different side of this feature) -- this file is scoped
    narrowly to the block/grant gate this pass added, the "capture must
    never be gated" regression this pass's own task explicitly demanded,
    and the "an already-earned reward survives a later block" decision
    documented at reportTrackSourceArrival's own call site. It does not
    attempt to backfill full coverage of every pre-existing branch in this
    file (the XP-farm anti-abuse arithmetic, the ox_inventory scent hook,
    water-crossing decay, etc.) -- those are unrelated to this pass's own
    scope.

    Loads the REAL, unmodified server/cooldowns.lua -> server/tracking.lua
    chain (server/entities.lua is NOT needed -- unlike server/search.lua/
    server/defense.lua, this file never calls ResolveNetworkEntity), mirrors
    tests/pursuitsprint_spec.lua's own fixture shape (that file being the
    canonical per-person-feature-control reference this pass's own task
    named) almost line for line, adapted for findTrackableSource's
    lib.callback shape instead of a RegisterNetEvent.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape to every other spec in this suite.
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

local TRACK_TYPE_FEATURE = {
    scent = 'ScentTracking',
    blood = 'BloodTracking',
    gunpowder = 'GunpowderSniffing',
}

--- DETERMINISTIC ITERATION ORDER: plain `pairs(TRACK_TYPE_FEATURE)` would
--- work fine for correctness (every test body below builds its own fresh
--- fixture and asserts independently of the others), but Lua's table
--- iteration order over string keys is not guaranteed stable across
--- process runs (lstate.c seeds the string hash per-VM-instance) -- this
--- file's own three-type loop below was observed emitting its
--- 'not blocked...'/'block.X denies...'/'block.X on ONE track type...'
--- trios in a different scent/blood/gunpowder order from one `lua5.4
--- tracking_spec.lua` run to the next. Harmless to pass/fail, but it
--- makes a run-to-run diff of this file's own output noisy for no
--- reason. Iterating this fixed array instead of the map directly pins
--- the order without changing which cases run.
local TRACK_TYPES_ORDERED = { 'scent', 'blood', 'gunpowder' }

--- @param opts table? {
---   requireGrantListed: table? -- e.g. { BloodTracking = true } -- Config.FeatureControl.RequireGrant
---   withHasPermission: boolean (default true)
---   hasPermissionFn: function
---   xpProgression: boolean (default false)
---   maxLoggedEntries: table? -- e.g. { blood = 3 } -- per-type Config.Tracking.<Type>.maxLoggedEntries override
--- }
--- @return table fixture
local function newTrackingFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local threadRunner = Sandbox.newThreadRunner() -- prune thread parked at its first Wait forever -- never stepped, matching tests/defense_spec.lua's "not exercised" convention for a thread this suite doesn't need to drive

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, pedBySource = {}, {}
    local function registerPlayer(src, citizenid, pedHandle)
        playersBySource[src] = { PlayerData = { citizenid = citizenid } }
        pedBySource[src] = pedHandle
    end

    -- NOTE: production code calls this with COLON syntax
    -- (`exports.qbx_core:GetPlayer(src)`), passing `exports.qbx_core`
    -- itself as an implicit first arg -- mirrors every other fixture in
    -- this suite (tests/pursuitsprint_spec.lua's own qbxGetPlayer shape).
    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local hasK9Access = true
    local function HasK9Access(_src) return hasK9Access end

    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local awardXpCalls = {}
    local function AwardXP(citizenid, actionKey)
        awardXpCalls[#awardXpCalls + 1] = { citizenid = citizenid, actionKey = actionKey }
    end

    local requireGrant = {}
    for k, v in pairs(opts.requireGrantListed or {}) do requireGrant[k] = v end

    -- ENTRY-COUNT CEILING (performance audit at 128 players, this pass) --
    -- lets a test override any/all of Config.Tracking.<Type>.maxLoggedEntries
    -- (e.g. `{ blood = 3 }`) without needing its own bespoke fixture; any
    -- type not named here falls back to a generous default no existing test
    -- in this file could ever realistically hit.
    local maxLoggedEntriesOverrides = opts.maxLoggedEntries or {}

    local Config = {
        Features = {
            ScentTracking = true,
            BloodTracking = true,
            GunpowderSniffing = true,
            XPProgression = opts.xpProgression == true,
        },
        Tracking = {
            Scent     = { maxAgeSeconds = 300, maxRange = 40.0, searchCooldownMs = 5000, relayCooldownMs = 500, maxLoggedEntries = maxLoggedEntriesOverrides.scent or 6000 },
            Blood     = { maxAgeSeconds = 300, maxRange = 40.0, searchCooldownMs = 5000, relayCooldownMs = 500, maxLoggedEntries = maxLoggedEntriesOverrides.blood or 8000 },
            Gunpowder = { maxAgeSeconds = 120, maxRange = 40.0, searchCooldownMs = 5000, relayCooldownMs = 300, maxLoggedEntries = maxLoggedEntriesOverrides.gunpowder or 6000 },
        },
        WaterTrackingDecay = { breaksTrail = false },
        FeatureControl = { RequireGrant = requireGrant },
        XP = { trackArrivalRadius = 3.0, trackArrivalTTLMs = 60000 },
    }

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, fn) registeredCallbacks[name] = fn end } }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        print = printStub,
        exports = exportsTable,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        lib = libStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
    }
    if opts.withHasPermission ~= false then
        overrides.HasPermission = opts.hasPermissionFn or defaultHasPermission
    end
    if opts.xpProgression then
        overrides.AwardXP = AwardXP
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/tracking.lua', env)

    return {
        Config = Config,
        printLog = printLog,
        permissionCalls = permissionCalls,
        awardXpCalls = awardXpCalls,
        advance = function(ms) state.now = state.now + ms end,
        setHasK9Access = function(v) hasK9Access = v end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        registerPlayer = registerPlayer,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        --- Calls the real captured findTrackableSource callback directly --
        --- ox_lib's own convention (`source` as an explicit first arg, not
        --- the ambient ~ RegisterNetEvent `source` global this file's OTHER
        --- handlers use).
        --- @return table result
        findTrackableSource = function(src, trackType)
            local handler = assert(registeredCallbacks['qbx_k9unit:server:findTrackableSource'],
                'server/tracking.lua did not register qbx_k9unit:server:findTrackableSource')
            return handler(src, trackType)
        end,
        --- Dispatches the real captured relayDamageEvent handler, mirroring
        --- every other RegisterNetEvent-driven fixture's `dispatch` helper
        --- (ambient `source` set via env.source first).
        relayDamageEvent = function(src)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:server:relayDamageEvent'])
            handler()
        end,
        relayWeaponFire = function(src)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:server:relayWeaponFire'])
            handler()
        end,
        reportTrackSourceArrival = function(src)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:server:reportTrackSourceArrival'])
            handler()
        end,
    }
end

-- ========================================================================
-- QUERY-SIDE GATE (findTrackableSource) -- the entry point this pass gates.
-- Table-driven across all three trackTypes, since
-- IsTrackingFeaturePermittedForCitizenId is the SAME shared function
-- parameterized by featureName for all three -- one detailed pass per
-- type would be triplicated, near-identical code.
-- ========================================================================

for _, trackType in ipairs(TRACK_TYPES_ORDERED) do
    local featureName = TRACK_TYPE_FEATURE[trackType]
    t.test(('not blocked, not in RequireGrant -- %s search succeeds (default allow, step 4)'):format(trackType), function()
        local f = newTrackingFixture()
        f.registerPlayer(1, 'K9-CID', 100)
        f.setPedCoords(100, 0, 0, 0)
        -- Log a source of the matching type within range via the REAL
        -- capture path (relayDamageEvent for blood, relayWeaponFire for
        -- gunpowder) -- for 'scent' (fed only by the ox_inventory hook this
        -- suite deliberately never wires up), seed a fresh log entry the
        -- only other way this file offers: report damage/weapon-fire is
        -- type-specific, so 'scent' is exercised via the RequireGrant/block
        -- tests below instead, where `found` is not the assertion (see
        -- those tests' own comments).
        if trackType == 'blood' then
            f.registerPlayer(2, 'VICTIM-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayDamageEvent(2)
        elseif trackType == 'gunpowder' then
            f.registerPlayer(2, 'SHOOTER-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayWeaponFire(2)
        end

        if trackType ~= 'scent' then
            local result = f.findTrackableSource(1, trackType)
            t.isTrue(result.found, ('a fresh, in-range, unblocked %s search must find the logged source'):format(trackType))
        else
            -- 'scent' has no logged entry in this fixture at all (no
            -- ox_inventory hook wired) -- found = false is the CORRECT,
            -- expected answer either way; this loop iteration exists only
            -- so the block test below has a companion "not blocked" case
            -- for the SAME featureName, proving the denial there is really
            -- the block, not an unrelated always-false scent search.
            local result = f.findTrackableSource(1, trackType)
            t.isFalse(result.found)
        end
    end)

    t.test(('block.%s denies the search outright (found = false), even with HasK9Access true'):format(featureName), function()
        local f = newTrackingFixture()
        f.registerPlayer(1, 'K9-CID', 100)
        f.setPedCoords(100, 0, 0, 0)
        f.grantPermission('K9-CID', 'block.' .. featureName, true)

        if trackType == 'blood' then
            f.registerPlayer(2, 'VICTIM-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayDamageEvent(2)
        elseif trackType == 'gunpowder' then
            f.registerPlayer(2, 'SHOOTER-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayWeaponFire(2)
        end

        local result = f.findTrackableSource(1, trackType)
        t.isFalse(result.found, ('block.%s must deny the search regardless of a real, in-range logged source'):format(featureName))
    end)

    t.test(('block.%s on ONE track type does not affect the other two'):format(featureName), function()
        local f = newTrackingFixture()
        f.registerPlayer(1, 'K9-CID', 100)
        f.setPedCoords(100, 0, 0, 0)
        f.grantPermission('K9-CID', 'block.' .. featureName, true)

        for _, otherType in ipairs(TRACK_TYPES_ORDERED) do
            local otherFeature = TRACK_TYPE_FEATURE[otherType]
            if otherType ~= trackType then
                -- Only assert on the two capturable types (blood/gunpowder)
                -- -- scent has no logged source in this fixture regardless.
                if otherType ~= 'scent' then
                    f.registerPlayer(900, 'BYSTANDER-' .. otherType, 800)
                    f.setPedCoords(800, 0, 0, 0)
                    if otherType == 'blood' then f.relayDamageEvent(900) else f.relayWeaponFire(900) end
                    local result = f.findTrackableSource(1, otherType)
                    t.isTrue(result.found, ('blocking %s must not affect an unrelated %s search'):format(featureName, otherFeature))
                end
            end
        end
    end)
end

t.test('A BLOCKED REQUEST NEVER BURNS THE QUERY COOLDOWN: removing the block immediately after still succeeds on the very same tick', function()
    local f = newTrackingFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    f.grantPermission('K9-CID', 'block.BloodTracking', true)
    local blockedResult = f.findTrackableSource(1, 'blood')
    t.isFalse(blockedResult.found)

    -- Same GetGameTimer value (no advance() call) -- if the blocked attempt
    -- above had wrongly stamped TrackQueryCooldown, this would now read as
    -- on_cooldown (found = false) instead of succeeding.
    f.grantPermission('K9-CID', 'block.BloodTracking', false)
    local unblockedResult = f.findTrackableSource(1, 'blood')
    t.isTrue(unblockedResult.found, 'the earlier blocked attempt must not have consumed the per-(source, trackType) query cooldown')
end)

t.test('grant_required: RequireGrant.BloodTracking = true + no grant held -- denied even though HasK9Access is true', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    -- deliberately NOT granted

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found)
end)

t.test('RequireGrant.BloodTracking = true + an active feature.BloodTracking grant -- allowed', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.grantPermission('K9-CID', 'feature.BloodTracking', true)

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found)
end)

t.test('BLOCK ALWAYS WINS even with an active grant held', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.grantPermission('K9-CID', 'feature.BloodTracking', true)
    f.grantPermission('K9-CID', 'block.BloodTracking', true)

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found)
end)

t.test('server/permissions.lua entirely absent (HasPermission not even defined): RequireGrant-listed feature fails CLOSED, never open', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true }, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    local ok, result = pcall(f.findTrackableSource, 1, 'blood')
    t.isTrue(ok, 'a missing HasPermission must never error the request handler')
    t.isFalse(result.found)
end)

t.test('server/permissions.lua entirely absent + feature NOT listed in RequireGrant -- still allowed', function()
    local f = newTrackingFixture({ requireGrantListed = {}, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found)
end)

-- ========================================================================
-- CAPTURE MUST NEVER BE GATED (this pass's own explicit, non-negotiable
-- requirement) -- relayDamageEvent (blood) and relayWeaponFire (gunpowder)
-- never consult HasPermission at all, and a reporting citizenid's own
-- block status has zero effect on whether their event gets logged.
-- ========================================================================

t.test('REGRESSION: relayWeaponFire (gunpowder CAPTURE) never consults HasPermission at all, even when the reporter is block.GunpowderSniffing', function()
    local f = newTrackingFixture()
    f.registerPlayer(2, 'SHOOTER-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.grantPermission('SHOOTER-CID', 'block.GunpowderSniffing', true)

    f.relayWeaponFire(2)

    t.equals(#f.permissionCalls, 0, "capture must not gate on the REPORTER's own block/grant state at all")

    -- Prove the entry really got logged despite the reporter's own block --
    -- a DIFFERENT, unblocked K9 searching for it must find it.
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    local result = f.findTrackableSource(1, 'gunpowder')
    t.isTrue(result.found, 'the shot fired by a block.GunpowderSniffing-flagged reporter must still be trackable by another K9')
end)

t.test('REGRESSION: relayDamageEvent (blood CAPTURE) never consults HasPermission at all, even when the victim is block.BloodTracking', function()
    local f = newTrackingFixture()
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.grantPermission('VICTIM-CID', 'block.BloodTracking', true)

    f.relayDamageEvent(2)

    t.equals(#f.permissionCalls, 0, "capture must not gate on the reporting party's own block/grant state at all")

    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found, 'blood logged by a block.BloodTracking-flagged victim must still be trackable by another K9')
end)

t.test('a BLOCKED K9 (the searcher, not the reporter) still logs their OWN relayDamageEvent/relayWeaponFire normally -- capture is never gated on the acting citizenid either', function()
    local f = newTrackingFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.grantPermission('K9-CID', 'block.BloodTracking', true)
    f.grantPermission('K9-CID', 'block.GunpowderSniffing', true)

    f.relayDamageEvent(1)
    f.relayWeaponFire(1)

    t.equals(#f.permissionCalls, 0)
end)

-- ========================================================================
-- "GATE THE ENTRY POINT, NOT THE SYMPTOM" -- reportTrackSourceArrival is
-- deliberately NOT re-checked against the block/grant gate (see that
-- handler's own comment in server/tracking.lua): a ticket minted while
-- permitted must still pay out even if a block lands afterward, while the
-- K9 is already travelling toward an already-resolved, already-authorized
-- source.
-- ========================================================================

t.test('an in-flight, already-minted track ticket still pays XP on arrival even after the citizenid is blocked in between resolve and arrival', function()
    local f = newTrackingFixture({ xpProgression = true })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)

    -- K9 starts 20m from the logged source -- clears MIN_TRACK_XP_DISTANCE
    -- (15.0, server/tracking.lua's own local constant) so a ticket is
    -- actually minted.
    f.setPedCoords(200, 20, 0, 0)
    f.relayDamageEvent(2) -- logs the blood source at (20, 0, 0)
    f.setPedCoords(100, 0, 0, 0)

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found, 'the resolve itself must succeed while still permitted -- this is the entry point the gate actually applies to')

    -- Block the K9 for BloodTracking AFTER the ticket was already minted --
    -- the non-negotiable this test pins: an already-earned reward must not
    -- be stranded by a block landing on an in-flight action.
    f.grantPermission('K9-CID', 'block.BloodTracking', true)

    -- Real travel + real elapsed time, exactly as server/tracking.lua's own
    -- ADDENDUM 2 economy fix requires (minElapsedMs = 20 / 25.0 * 1000 = 800ms).
    f.setPedCoords(100, 20, 0, 0) -- now co-located with the resolved source
    f.advance(900)

    f.reportTrackSourceArrival(1)

    t.equals(#f.awardXpCalls, 1, 'arrival must still pay out -- this is a completion of an already-authorized action, not a new entry-point request')
    t.equals(f.awardXpCalls[1].citizenid, 'K9-CID')
    t.equals(f.awardXpCalls[1].actionKey, 'trackSourceResolved')
end)

t.test('a citizenid who was ALREADY blocked before ever resolving a source never gets a ticket to redeem in the first place', function()
    local f = newTrackingFixture({ xpProgression = true })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.grantPermission('K9-CID', 'block.BloodTracking', true)

    f.setPedCoords(200, 20, 0, 0)
    f.relayDamageEvent(2)
    f.setPedCoords(100, 0, 0, 0)

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found, 'blocked at resolve time -- no ticket, no reveal')

    f.setPedCoords(100, 20, 0, 0)
    f.advance(900)
    f.reportTrackSourceArrival(1)

    t.equals(#f.awardXpCalls, 0, 'nothing was ever minted for this citizenid to redeem')
end)

-- ========================================================================
-- GAP CLOSURE (this pass, coder-backend): server/k9profiles.lua's own
-- header names THIS FILE's scent-range consumer as one of three left
-- unwired -- `findTrackableSource`'s maxRange bonus used to read
-- `GetXPTier(trackerCitizenid).scentRangeMultiplier` RAW, so a per-K9
-- individual override on `scentRangeMultiplier` was stored, audited, and
-- shown back to the operator, but had ZERO effect on the actual detection
-- range this callback computes. Fixed by routing through
-- GetK9EffectiveMultipliers (see server/tracking.lua's own maxRange
-- calculation for the full writeup) -- this section proves that fix reaches
-- a REAL, VISIBLE effect (found = true vs. found = false), through the
-- REAL, unmodified server/progression.lua + server/k9profiles.lua chain,
-- not a stubbed GetXPTier/GetK9EffectiveMultipliers.
--
-- Deliberately a SEPARATE fixture from newTrackingFixture above (never
-- modifies it): this section additionally loads server/datastore.lua (for
-- K9Store, server/k9profiles.lua's own persistence layer) and
-- server/progression.lua/server/k9profiles.lua themselves, in
-- fxmanifest.lua's real server_scripts order (datastore -> cooldowns ->
-- tracking -> progression -> k9profiles). `onResourceStart` is
-- DELIBERATELY NEVER FIRED here: server/k9profiles.lua's own
-- RefreshOverrideCache() already runs unconditionally, synchronously, right
-- inside k9ProfileUpsert itself after every successful write (see that
-- function's own body) -- it does not depend on the boot-time cache warm --
-- and firing onResourceStart in this fixture would ALSO invoke
-- server/tracking.lua's own scent-inventory-hook registration
-- (RegisterScentInventoryHook, which calls K9Compat.Get('inventory')), an
-- entirely unrelated surface this section has no need to drag in. Every
-- other existing test in this file already establishes the same
-- "onResourceStart is never fired" convention for server/tracking.lua on
-- its own (grep this file: zero prior references to onResourceStart or
-- K9Compat) -- this section does not change that.
-- ========================================================================

--- @return table fixture
local function newTrackingOverrideChainFixture()
    local state = { now = 0 }
    local function GetGameTimer() return state.now end

    -- server/progression.lua starts a recurring mint-budget sweep thread
    -- UNCONDITIONALLY at its own file-load time -- this fixture never needs
    -- to step it, so a one-shot resume that parks it at its first Wait() is
    -- sufficient, matching tests/progression_spec.lua's own GAP 1 fixture
    -- and tests/medkit_spec.lua's own GAP CLOSURE fixture.
    local function CreateThread(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newTrackingOverrideChainFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
    end
    local function Wait(_ms) coroutine.yield() end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, pedBySource = {}, {}
    local function registerPlayer(src, citizenid, pedHandle)
        playersBySource[src] = { PlayerData = { citizenid = citizenid, source = src } }
        pedBySource[src] = pedHandle
    end

    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid)
                for _, p in pairs(playersBySource) do
                    if p.PlayerData.citizenid == citizenid then return p end
                end
                return nil
            end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local function HasK9Access(_src) return true end

    local isHighCommand = true

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, fn) registeredCallbacks[name] = fn end } }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local Config = {
        Features = {
            ScentTracking = true, BloodTracking = true, GunpowderSniffing = true,
            XPProgression = true,
        },
        Tracking = {
            -- A deliberately SMALL maxRange -- see the tests below for
            -- exactly why: it must be small enough that a source PAST it is
            -- reachable only once a genuine override multiplies it.
            Scent     = { maxAgeSeconds = 300, maxRange = 10.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
            Blood     = { maxAgeSeconds = 300, maxRange = 10.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
            Gunpowder = { maxAgeSeconds = 120, maxRange = 10.0, searchCooldownMs = 5000, relayCooldownMs = 300 },
        },
        WaterTrackingDecay = { breaksTrail = false },
        FeatureControl = { RequireGrant = {} },
        XP = {
            trackArrivalRadius = 3.0, trackArrivalTTLMs = 60000,
            scopePerCitizenidOrJob = 'citizenid', awards = {},
        },
        -- A single-rank ladder -- this section is about the INDIVIDUAL
        -- override layered on top, not the XP-tier ladder itself. See
        -- tests/medkit_spec.lua's own identical GAP CLOSURE fixture comment
        -- for why a single rank is a valid, if minimal, Config.XPTiers.
        XPTiers = { { xp = 0, label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 } },
        Database = { enabled = false },
    }

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = Wait,
        print = printStub,
        exports = exportsTable,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        IsHighCommand = function(_src) return isHighCommand end,
        lib = libStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
    })

    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/tracking.lua', env)
    Sandbox.loadInto('../server/progression.lua', env)
    Sandbox.loadInto('../server/k9profiles.lua', env)

    return {
        Config = Config,
        printLog = printLog,
        advance = function(ms) state.now = state.now + ms end,
        registerPlayer = registerPlayer,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        findTrackableSource = function(src, trackType)
            local handler = assert(registeredCallbacks['qbx_k9unit:server:findTrackableSource'])
            return handler(src, trackType)
        end,
        relayDamageEvent = function(src)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:server:relayDamageEvent'])
            handler()
        end,
        upsertProfile = function(hcSrc, payload)
            local handler = assert(registeredCallbacks['qbx_k9unit:server:k9ProfileUpsert'])
            return handler(hcSrc, payload)
        end,
    }
end

t.test('GAP CLOSURE: an individual scentRangeMultiplier override reaches findTrackableSource\'s own maxRange calculation through the REAL server/progression.lua + server/k9profiles.lua chain -- not a stub', function()
    local f = newTrackingOverrideChainFixture()
    local HC_SRC = 999

    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0) -- the K9

    -- Log a blood source 15m away -- PAST Config.Tracking.Blood.maxRange
    -- (10.0) with no override, but well WITHIN it once a 2.0x override
    -- doubles it to 20.0.
    f.setPedCoords(200, 15, 0, 0)
    f.relayDamageEvent(2)

    -- CONTROL: no override exists yet -- the base tier (Recruit,
    -- scentRangeMultiplier = 1.00) never raises maxRange past its
    -- configured 10.0, so a source 15m away must NOT be found.
    local before = f.findTrackableSource(1, 'blood')
    t.isFalse(before.found, 'a source past the plain configured maxRange, with no override, must not be found')

    -- THE OVERRIDE ITSELF: a genuine high-command tablet edit, through
    -- server/k9profiles.lua's own REAL callback.
    local upsert = f.upsertProfile(HC_SRC, { citizenid = 'K9-CID', scentRangeMultiplier = 2.0 })
    t.isTrue(upsert.ok, 'the override write itself must succeed')
    t.equals(upsert.effective.scentRangeMultiplier, 2.0)

    -- Clear TrackQueryCooldown's own per-(source, trackType) searchCooldownMs
    -- (5000ms) floor -- the CONTROL call above already consumed it for
    -- (1, 'blood') at t=0; without this advance, the call below would be
    -- rejected as on_cooldown (found = false) before ever reaching the
    -- maxRange calculation this test actually exists to exercise.
    f.advance(5001)

    -- SAME source, SAME distance, SAME K9 -- the ONLY thing that changed is
    -- the override just written. If this now finds it, the override
    -- demonstrably reached findTrackableSource's own live maxRange
    -- calculation through the real, unmodified GetK9EffectiveMultipliers
    -- chain -- not merely stored, audited, and displayed back inertly.
    local after = f.findTrackableSource(1, 'blood')
    t.isTrue(after.found, 'after a 2.0 scentRangeMultiplier override, the SAME 15m-away source that was unreachable a moment ago must now be found -- this is the exact "reaches a visible effect" property this pass exists to prove')
end)

t.test('GAP CLOSURE control: WITHOUT the individual override (a different K9 citizenid, same distance), the plain configured maxRange still applies -- the effect above is caused by the override, not a fixture quirk', function()
    local f = newTrackingOverrideChainFixture()

    f.registerPlayer(1, 'K9-CID-NO-OVERRIDE', 100)
    f.registerPlayer(2, 'VICTIM-CID-2', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 15, 0, 0)
    f.relayDamageEvent(2)

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found, 'no override was ever set for this citizenid -- the plain configured maxRange (10.0) must still apply to a source 15m away')
end)

-- ========================================================================
-- SCENT VISION (Config.Features.ScentVision) -- owner-directed pass: a
-- keybound coloured-dot "who walked through here" overlay. A NEW, SEPARATE
-- fixture (never modifies newTrackingFixture above): this feature's capture
-- thread scans EVERY CONNECTED player (GetPlayers()), not a single resolved
-- source, and needs a real, steppable CreateThread/Wait pair
-- (Sandbox.newThreadRunner(), the exact same shape newTrackingFixture
-- already uses) to drive the capture/prune threads this pass adds -- no
-- pre-existing test in this file needed either.
-- ========================================================================

--- @param opts table? { requireGrantListed: table?, trackingOverrides: table? }
--- @return table fixture
local function newScentVisionFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local threadRunner = Sandbox.newThreadRunner()

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, pedBySource, connected = {}, {}, {}
    local function registerPlayer(src, citizenid, pedHandle)
        playersBySource[src] = { PlayerData = { citizenid = citizenid } }
        pedBySource[src] = pedHandle
        connected[src] = true
    end

    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end
    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end
    local function setPedCoords(src, x, y, z) pedCoords[pedBySource[src]] = vec3(x, y, z) end

    -- Real GetPlayers() returns an ARRAY OF STRINGS -- mirrored here exactly
    -- (server/entities.lua's own ResolveConnectedPlayerFromPed and this
    -- pass's own capture thread both `tonumber(...)` every entry).
    local function GetPlayers()
        local ids = {}
        for src in pairs(connected) do ids[#ids + 1] = tostring(src) end
        return ids
    end

    local hasK9Access = true
    local function HasK9Access(_src) return hasK9Access end

    local permissionGrants = {}
    local function defaultHasPermission(citizenid, key)
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local requireGrant = {}
    for k, v in pairs(opts.requireGrantListed or {}) do requireGrant[k] = v end

    local Config = {
        Features = { ScentVision = true },
        Tracking = {
            -- REQUIRED even though this fixture never exercises Scent/Blood/
            -- Gunpowder directly (qa-tester finding, this pass): server/tracking.lua's
            -- own PruneTrackableLogs runs on an UNCONDITIONAL thread (no
            -- Config.Features gate at all) and reads
            -- Config.Tracking.Scent/Blood/Gunpowder.maxAgeSeconds every
            -- TRACKABLE_LOG_PRUNE_INTERVAL_MS (15000ms) regardless of which
            -- feature is under test -- a ScentVision test that advances the
            -- clock past that threshold and then calls `f.step()` would
            -- otherwise crash this fixture with "attempt to index a nil
            -- value (field 'Scent')" the instant that thread's own Wait
            -- resolves. Real config.lua always ships all four
            -- Config.Tracking sub-tables together; this fixture must too.
            Scent     = { maxAgeSeconds = 300 },
            Blood     = { maxAgeSeconds = 300 },
            Gunpowder = { maxAgeSeconds = 120 },
            ScentVision = {
                sampleIntervalMs        = 4000,
                minSampleMovementMeters = 2.0,
                maxPointsPerPerson      = 4,  -- small, deliberately, so the hard cap is easy to reach in a test
                dotLifetimeMs           = 45000,
                queryRangeMeters        = 40.0,
                maxVisibleTrails        = 2,  -- small, deliberately, so "handful" truncation is easy to prove
                queryMaxPointsPerTrail  = 12,
                queryCooldownMs         = 1000,
                mode                    = 'keybind', -- matches config.lua's own shipped default; set via opts.trackingOverrides for the MODE section's own tests below
                palette = {
                    { r = 230, g = 25,  b = 75  },
                    { r = 60,  g = 180, b = 75  },
                },
            },
        },
        FeatureControl = { RequireGrant = requireGrant },
    }
    for k, v in pairs(opts.trackingOverrides or {}) do
        Config.Tracking.ScentVision[k] = v
    end

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, fn) registeredCallbacks[name] = fn end } }

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end
    local function RegisterNetEvent(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        print = printStub,
        exports = exportsTable,
        GetPlayers = GetPlayers,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        HasPermission = defaultHasPermission,
        lib = libStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/tracking.lua', env)

    return {
        Config = Config,
        printLog = printLog,
        advance = function(ms) state.now = state.now + ms end,
        step = threadRunner.step,
        registerPlayer = registerPlayer,
        setPedCoords = setPedCoords,
        --- Fires every RegisterPlayerDropped-registered handler AND this
        --- file's own final playerDropped handler -- the real cleanup path,
        --- not a reimplementation of it.
        disconnectPlayer = function(src)
            connected[src] = nil
            env.source = src
            for _, fn in ipairs(eventHandlers['playerDropped'] or {}) do fn('test') end
        end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        getScentVisionPoints = function(src)
            local handler = assert(registeredCallbacks['qbx_k9unit:server:getScentVisionPoints'],
                'server/tracking.lua did not register qbx_k9unit:server:getScentVisionPoints')
            return handler(src)
        end,
    }
end

t.test('ScentVision: a moving player is captured across multiple sample passes and revealed to a nearby K9, coloured', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)      -- the querying K9
    f.registerPlayer(2, 'SUSPECT-CID', 200) -- the person being tracked
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- primes all captured threads (reaches each one's first Wait, no capture work yet)

    -- Walk the suspect a few metres each capture pass -- comfortably past
    -- minSampleMovementMeters (2.0) every time, so every pass records a NEW point.
    f.setPedCoords(2, 5, 0, 0)
    f.step()
    f.setPedCoords(2, 10, 0, 0)
    f.step()
    f.setPedCoords(2, 15, 0, 0)
    f.step()

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points >= 3, ('expected at least 3 captured points, got %d'):format(#result.points))
    for _, p in ipairs(result.points) do
        t.isTrue(type(p.r) == 'number' and type(p.g) == 'number' and type(p.b) == 'number', 'every revealed point must carry a colour')
        t.isNil(p.citizenid, 'the client must never be told WHO a point belongs to')
        t.isNil(p.source, 'the client must never be told WHO a point belongs to')
    end
end)

t.test('ScentVision: each dot expires against its OWN timestamp -- advancing the clock directly (no extra capture passes) expires it', function()
    local f = newScentVisionFixture({ trackingOverrides = { dotLifetimeMs = 10000 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- one point recorded at the current GetGameTimer()

    local beforeExpiry = f.getScentVisionPoints(1)
    t.isTrue(#beforeExpiry.points >= 1, 'the point must still be visible before its own lifetime elapses')

    -- Advance the CLOCK directly past dotLifetimeMs -- no additional capture
    -- passes, no additional frames -- proving expiry is evaluated against a
    -- TIMESTAMP, never a per-frame-decremented countdown (owner's own
    -- explicit requirement).
    f.advance(10001)

    local afterExpiry = f.getScentVisionPoints(1)
    t.equals(#afterExpiry.points, 0, 'a point older than dotLifetimeMs must never be revealed, regardless of how it got old')
end)

t.test('ScentVision: maxPointsPerPerson is a hard cap regardless of how many capture passes accumulate', function()
    local f = newScentVisionFixture({ trackingOverrides = { maxPointsPerPerson = 3 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    for i = 1, 10 do
        f.setPedCoords(2, i * 3, 0, 0) -- always moves well past minSampleMovementMeters
        f.step()
    end

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points <= 3, ('expected at most 3 points (hard cap), got %d'):format(#result.points))
end)

-- ========================================================================
-- UPPER CEILING on maxPointsPerPerson (performance audit at 128 players,
-- this pass). See server/tracking.lua's own
-- SCENT_VISION_MAX_POINTS_PER_PERSON_CEILING declaration comment for the
-- full worked arithmetic. This field is the one caller of
-- ResolveScentVisionNumber that passes an upper `maxAllowed` -- matching
-- server/runtimecontrol.lua's own tablet-side bound (min=1, max=50) for the
-- identical field, so a config.lua hand-edit cannot reach a value the
-- tablet's own UI already refuses.
-- ========================================================================

t.test('ScentVision: an excessively large maxPointsPerPerson is clamped to this resource\'s own ceiling (50) and warns, rather than reintroducing unbounded per-player trail memory', function()
    -- queryMaxPointsPerTrail/queryRangeMeters overridden generously large so
    -- the QUERY side never masks what this test actually cares about: the
    -- STORAGE-side cap enforced by RecordScentVisionPoint's own `maxPoints`
    -- (resolved from maxPointsPerPerson). Clock is never advanced between
    -- capture passes (matching the sibling hard-cap test just above), so
    -- dotLifetimeMs expiry cannot be the reason any point is missing either.
    local f = newScentVisionFixture({ trackingOverrides = {
        maxPointsPerPerson     = 100000, -- far above the 50 ceiling this resource enforces
        minSampleMovementMeters = 0.5,
        queryMaxPointsPerTrail  = 100000,
        queryRangeMeters        = 100000,
    } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    for i = 1, 55 do
        f.setPedCoords(2, i * 1, 0, 0) -- always moves well past minSampleMovementMeters (0.5)
        f.step()
    end

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points <= 50,
        ('expected at most 50 points (this resource\'s own built-in ceiling, matching the tablet\'s own bound), got %d -- an unclamped maxPointsPerPerson would have let this reach 55'):format(#result.points))

    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.ScentVision.maxPointsPerPerson', 1, true) and line:find('exceeds', 1, true) then
            warningLine = line
        end
    end
    t.isNotNil(warningLine, 'an excessively large maxPointsPerPerson must print a warning naming the exact key')
    t.contains(warningLine, '100000', 'the warning must name the value that was actually found')
    t.contains(warningLine, '50', 'the warning must name the ceiling value substituted')
end)

t.test('ScentVision: the shipped default (15) and the tablet\'s own max (50) both sit at-or-under the ceiling -- neither ever warns', function()
    local f1 = newScentVisionFixture() -- fixture default maxPointsPerPerson = 4, well under
    f1.registerPlayer(1, 'K9-CID', 100)
    f1.registerPlayer(2, 'SUSPECT-CID', 200)
    f1.setPedCoords(1, 0, 0, 0)
    f1.setPedCoords(2, 0, 0, 0)
    f1.step()
    f1.setPedCoords(2, 5, 0, 0)
    f1.step()
    for _, line in ipairs(f1.printLog) do
        t.isFalse(line:find('maxPointsPerPerson', 1, true) ~= nil and line:find('exceeds', 1, true) ~= nil,
            'a small, legitimate maxPointsPerPerson must never trip the upper-ceiling warning: ' .. line)
    end

    local f2 = newScentVisionFixture({ trackingOverrides = { maxPointsPerPerson = 50 } }) -- exactly the tablet's own max
    f2.registerPlayer(1, 'K9-CID', 100)
    f2.registerPlayer(2, 'SUSPECT-CID', 200)
    f2.setPedCoords(1, 0, 0, 0)
    f2.setPedCoords(2, 0, 0, 0)
    f2.step()
    f2.setPedCoords(2, 5, 0, 0)
    f2.step()
    for _, line in ipairs(f2.printLog) do
        t.isFalse(line:find('maxPointsPerPerson', 1, true) ~= nil and line:find('exceeds', 1, true) ~= nil,
            'exactly the tablet\'s own max (50) must never itself trigger the "exceeds" warning: ' .. line)
    end
end)

t.test('ScentVision: only maxVisibleTrails distinct trails are revealed at once -- the FURTHEST is dropped under load', function()
    local f = newScentVisionFixture() -- maxVisibleTrails = 2 in this fixture's own defaults
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'NEAR-CID', 200)
    f.registerPlayer(3, 'MID-CID', 300)
    f.registerPlayer(4, 'FAR-CID', 400)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.setPedCoords(3, 15, 0, 0)
    f.setPedCoords(4, 25, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- all three get their first point recorded

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 2, 'only maxVisibleTrails (2) distinct trails-worth of points may be revealed at once')

    local sawFar = false
    for _, p in ipairs(result.points) do
        if p.x == 25 then sawFar = true end
    end
    t.isFalse(sawFar, 'the FURTHEST trail (x=25) must be the one dropped when more than maxVisibleTrails are in range')
end)

t.test('ScentVision: a freed slot is reused by a newcomer, while an UNRELATED still-visible trail keeps its own colour throughout', function()
    local f = newScentVisionFixture() -- maxVisibleTrails = 2, palette length 2
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'A-CID', 200)
    f.registerPlayer(3, 'B-CID', 300)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.setPedCoords(3, 10, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- A and B both logged

    local first = f.getScentVisionPoints(1)
    t.equals(#first.points, 2)
    local colorByX = {}
    for _, p in ipairs(first.points) do colorByX[p.x] = { r = p.r, g = p.g, b = p.b } end
    local aColor, bColor = colorByX[5], colorByX[10]
    t.isNotNil(aColor, 'A must be visible before disconnecting')
    t.isNotNil(bColor, 'B must be visible throughout')

    -- A disconnects entirely -- their slot frees (see this file's own
    -- server/tracking.lua header, ResolveScentVisionColors, for the "reassign
    -- only when it drops out entirely" rule this proves).
    f.disconnectPlayer(2)

    -- C, a brand-new third person, appears and moves into range, taking the
    -- now-free slot.
    f.registerPlayer(4, 'C-CID', 400)
    f.setPedCoords(4, 15, 0, 0)
    f.advance(2000) -- clear queryCooldownMs before the next query
    f.step()

    local second = f.getScentVisionPoints(1)
    t.equals(#second.points, 2, "B (still visible) plus C (newly visible) fill the same 2 slots")
    local colorByX2 = {}
    for _, p in ipairs(second.points) do colorByX2[p.x] = { r = p.r, g = p.g, b = p.b } end

    t.equals(colorByX2[10].r, bColor.r, "B's colour must be UNCHANGED -- it never left the visible set")
    t.equals(colorByX2[10].g, bColor.g, "B's colour must be UNCHANGED -- it never left the visible set")
    t.equals(colorByX2[10].b, bColor.b, "B's colour must be UNCHANGED -- it never left the visible set")

    t.equals(colorByX2[15].r, aColor.r, "the freed slot's colour is now held by C, the new occupant")
    t.equals(colorByX2[15].g, aColor.g, "the freed slot's colour is now held by C, the new occupant")
    t.equals(colorByX2[15].b, aColor.b, "the freed slot's colour is now held by C, the new occupant")
end)

t.test("ScentVision: a K9 never sees their own trail", function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(1, 0, 0, 0)

    f.step()
    f.setPedCoords(1, 5, 0, 0)
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, "a K9's own recorded trail must never be revealed back to themselves")
end)

t.test('ScentVision: a non-positive dotLifetimeMs is clamped to a safe default, never read as "forever" (or the opposite failure -- instant, silent, total blindness)', function()
    local f = newScentVisionFixture({ trackingOverrides = { dotLifetimeMs = 0 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    -- The safe fallback default (45000ms, server/tracking.lua's own
    -- ResolveConfiguredThresholdMs call site) must be in effect -- advancing
    -- well past it must still expire the point, proving 0 did NOT silently
    -- become "no expiry ever".
    f.advance(45001)
    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'dotLifetimeMs = 0 must fall back to a safe positive default, never "forever"')
    t.isTrue(#f.printLog > 0, 'a bad dotLifetimeMs must print a loud, named warning, not fail silently')
end)

t.test('ScentVision: block.ScentVision denies the reveal outright, even with a fresh in-range trail', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.grantPermission('K9-CID', 'block.ScentVision', true)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'block.ScentVision must deny the reveal regardless of a real, in-range trail')
end)

t.test('ScentVision: the server enforces queryCooldownMs regardless of how fast the client asks', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    local firstResult = f.getScentVisionPoints(1)
    t.isTrue(#firstResult.points > 0)

    -- Same instant, no advance() -- a second immediate query must be refused.
    local secondResult = f.getScentVisionPoints(1)
    t.equals(#secondResult.points, 0, 'a query inside queryCooldownMs must be refused, not answered again for free')
end)

-- ========================================================================
-- MODE (Config.Tracking.ScentVision.mode) -- owner-directed pass: "make the
-- scent tracking a keybind and choose always active or [not]". Server-side
-- coverage only: this file never decides whether to RENDER (that is
-- entirely client/tracking.lua's job, covered by tests/clienttracking_spec.lua)
-- -- it only proves (1) getScentVisionPoints echoes the server's own live-
-- resolved mode fresh on every call, the exact channel the client relies on
-- to stop rendering live, and (2) that value never changes what/whether the
-- capture thread records, per this task's own explicit requirement that
-- 'always' must cost nothing extra server-side.
-- ========================================================================

t.test('MODE: getScentVisionPoints echoes the configured mode back on a successful query', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'always' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(result.mode, 'always', 'the echoed mode must match the live server config, not a stale/default guess')
end)

-- THE LEAK THIS SECTION USED TO STEP AROUND.
-- Two independent red-team passes reproduced the same thing: `mode` was
-- resolved only to be echoed back for the client to decide whether to
-- render, and nothing on the server stopped a query when it was 'off'.
-- Any certified handler with a modified client could call this callback
-- directly on the 1s cooldown floor and receive live position trails of
-- every player in range -- a real-time wallhack, running precisely while
-- the admin control meant to prevent it was switched on. Background
-- capture keeps running in 'off' mode by design, so the data was always
-- fresh and waiting.
-- The old MODE test below deliberately flipped mode back to 'keybind'
-- before querying, so this exact case shipped untested. It is tested now.
t.test('MODE: "off" returns NO points to a direct callback call -- the off switch is enforced on the SERVER, not merely respected by a cooperating client', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'off' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    -- Let the capture thread record real, in-range points for the victim.
    -- They must exist and be fresh -- otherwise this test would pass for
    -- the wrong reason, proving only that nothing was captured.
    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'a direct call while mode is "off" must return nothing -- the client choosing not to poll is a courtesy, not a boundary, and a modified client does not extend that courtesy')
    t.equals(result.mode, 'off', 'the echoed mode must still be honest so a cooperating client also stops rendering')

    -- Control: the same fixture, same players, same captured data, with the
    -- switch on -- proving the zero above is caused by the mode and not by
    -- an empty capture.
    local g = newScentVisionFixture({ trackingOverrides = { mode = 'keybind' } })
    g.registerPlayer(1, 'K9-CID', 100)
    g.registerPlayer(2, 'SUSPECT-CID', 200)
    g.setPedCoords(1, 0, 0, 0)
    g.setPedCoords(2, 5, 0, 0)
    g.step()
    g.step()
    t.isTrue(#g.getScentVisionPoints(1).points > 0, 'control: with mode on, this same setup DOES return points -- so the zero above is the mode, not a fixture quirk')
end)

t.test('MODE: an unrecognised Config.Tracking.ScentVision.mode falls back to "keybind" and warns once, naming the exact setting', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'bogus-value' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(result.mode, 'keybind', 'a bad mode value must never silently become "always" -- the safest default wins')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.ScentVision.mode', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a bad mode value must print a loud warning naming this exact setting, never fail silently')
end)

t.test('MODE: Config.Features.ScentVision = false echoes mode = "off" regardless of Config.Tracking.ScentVision.mode\'s own value', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'always' } })
    f.Config.Features.ScentVision = false

    local result = f.getScentVisionPoints(1) -- no players registered at all -- must not error
    t.equals(result.mode, 'off', 'the master feature being off must read as mode == "off" to an already-polling client, regardless of the mode field')
    t.equals(#result.points, 0)
end)

t.test('MODE: "off" does NOT change the capture threads own cost -- population-wide sampling keeps recording exactly as it does under "keybind"/"always"', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'off' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    f.setPedCoords(2, 5, 0, 0)
    f.step()
    f.setPedCoords(2, 10, 0, 0)
    f.step()

    -- Read the reveal back with mode flipped to 'keybind' -- the QUERY side
    -- is allowed to differ by mode in principle, but the CAPTURE that
    -- already happened above (while mode was 'off') must have recorded
    -- real points regardless, proving the capture thread never consulted
    -- `mode` at all -- exactly this task's own "must NOT change the
    -- server-side sampling cost" requirement.
    f.Config.Tracking.ScentVision.mode = 'keybind'
    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points >= 2, ('capture must be unaffected by mode == "off" -- expected at least 2 points, got %d'):format(#result.points))
end)

-- ========================================================================
-- ENTRY-COUNT CEILING (performance audit at 128 players, this pass --
-- coder-backend). Proves TrackableLog.<type> never grows past
-- Config.Tracking.<Type>.maxLoggedEntries no matter how many entries are
-- logged, and that eviction always takes the OLDEST entry first (never the
-- newest -- see server/tracking.lua's own AppendTrackableLogEntry doc
-- comment for why). Exercised entirely through the real, public
-- relayDamageEvent/relayWeaponFire/findTrackableSource surface -- TrackableLog
-- itself is file-local and deliberately not exposed to this suite, matching
-- this file's own "exposes NO resource-global functions" contract.
-- ========================================================================

t.test('ENTRY-COUNT CEILING: exceeding the cap evicts the two OLDEST entries, keeping the boundary entry and everything newer reachable', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 3 } })
    f.registerPlayer(1, 'K9-CID', 100) -- the searching K9

    -- Five distinct victims, each 100 units apart on the X axis -- far
    -- enough that only an entry ACTUALLY STILL PRESENT in the log (within
    -- maxRange=40.0 of the K9's own search position) can ever match.
    for i = 1, 5 do
        local victimSrc = 100 + i
        local ped = 200 + i
        f.registerPlayer(victimSrc, 'VICTIM-' .. i, ped)
        f.setPedCoords(ped, i * 100, 0, 0)
        f.relayDamageEvent(victimSrc) -- appends one TrackableLog.blood entry at (i*100, 0, 0)
    end
    -- Cap is 3, 5 entries were logged in order 1..5 -- entries 1 and 2 (the
    -- two OLDEST) must have been evicted; 3, 4, 5 (the three NEWEST) must
    -- remain, exactly matching AppendTrackableLogEntry's documented
    -- discard-on-write, oldest-first shape.

    local function searchFrom(x)
        f.setPedCoords(100, x, 0, 0) -- move the K9's OWN ped to stand exactly where victim i bled
        local result = f.findTrackableSource(1, 'blood')
        f.advance(6000) -- clear the K9's own per-(source, trackType) query cooldown (5000ms) before the next search
        return result.found
    end

    t.isFalse(searchFrom(1 * 100), 'entry 1 (the oldest) must have been evicted')
    t.isFalse(searchFrom(2 * 100), 'entry 2 must also have been evicted -- the cap of 3 only leaves room for 3, 4, 5')
    t.isTrue(searchFrom(3 * 100), 'entry 3 is the oldest SURVIVING entry -- exactly at the cap boundary -- and must still be found')
    t.isTrue(searchFrom(4 * 100), 'entry 4 must still be found')
    t.isTrue(searchFrom(5 * 100), 'entry 5 (the newest) must never be the one evicted to make room for an older entry')
end)

t.test('ENTRY-COUNT CEILING: the cap holds under MANY repeated writes -- only the newest N (cap) entries are ever findable, no matter how many total entries were logged', function()
    local CAP = 5
    local TOTAL_WRITES = 40
    local f = newTrackingFixture({ maxLoggedEntries = { gunpowder = CAP } })
    f.registerPlayer(1, 'K9-CID', 100) -- the searching K9

    for i = 1, TOTAL_WRITES do
        local shooterSrc = 1000 + i
        local ped = 2000 + i
        f.registerPlayer(shooterSrc, 'SHOOTER-' .. i, ped)
        f.setPedCoords(ped, i * 100, 0, 0)
        f.relayWeaponFire(shooterSrc) -- appends one TrackableLog.gunpowder entry at (i*100, 0, 0)
    end

    -- Only the LAST `CAP` entries (indices TOTAL_WRITES-CAP+1 .. TOTAL_WRITES,
    -- i.e. the 5 most recently logged out of 40 total) can still be found --
    -- every earlier one, no matter how much earlier, must have been evicted.
    --
    -- A FRESH searcher source per check (never the same K9 twice), rather
    -- than advancing the clock between checks: Gunpowder's own
    -- maxAgeSeconds (120s in this fixture) is short enough that advancing
    -- the clock 40 times in a row to dodge TrackQueryCooldown's
    -- per-(source, trackType) 5000ms gate would itself age every entry out
    -- by AGE well before reaching the end of the loop -- an unrelated
    -- expiry, not the CAP eviction this test exists to isolate. A fresh
    -- source has no query-cooldown history at all, so `now` never needs to
    -- move, and only maxLoggedEntries can be responsible for any `found`
    -- result below.
    for i = 1, TOTAL_WRITES do
        local searcherSrc = 5000 + i
        local searcherPed = 6000 + i
        f.registerPlayer(searcherSrc, 'SEARCHER-' .. i, searcherPed)
        f.setPedCoords(searcherPed, i * 100, 0, 0)
        local result = f.findTrackableSource(searcherSrc, 'gunpowder')
        local shouldSurvive = i > (TOTAL_WRITES - CAP)
        t.equals(result.found, shouldSurvive,
            ('entry %d of %d (cap %d) should %s survive'):format(i, TOTAL_WRITES, CAP, shouldSurvive and '' or 'NOT'))
    end
end)

t.test('ENTRY-COUNT CEILING: an invalid Config.Tracking.<Type>.maxLoggedEntries clamps to the built-in fallback and warns, rather than breaking the feature', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 'not-a-number' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.Blood.maxLoggedEntries', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an invalid maxLoggedEntries value must print a warning naming the exact key')

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found, 'the feature must keep working off the built-in fallback -- an invalid cap must never collapse to something that evicts every entry on arrival')
end)

-- ========================================================================
-- UPPER CEILING on maxLoggedEntries (performance audit at 128 players, this
-- pass -- follow-up finding). See server/tracking.lua's own
-- MAX_LOGGED_ENTRIES_CEILING declaration comment for the full worked
-- arithmetic behind the 50000 figure. This field is hand-edit-only (not
-- tablet-reachable), so it was the one place a floor-only clamp still let
-- an operator reintroduce the exact unbounded-growth incident this whole
-- mechanism exists to close.
-- ========================================================================

t.test('UPPER CEILING: a maxLoggedEntries value above the built-in ceiling is clamped down and warns, naming the exact key and the ceiling substituted', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 999999 } })

    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.Blood.maxLoggedEntries', 1, true) and line:find('exceeds', 1, true) then
            warningLine = line
        end
    end
    t.isNotNil(warningLine, 'a maxLoggedEntries value above the ceiling must print a warning naming the exact key')
    t.contains(warningLine, '999999', 'the warning must name the value that was actually found')
    t.contains(warningLine, '50000', 'the warning must name the ceiling value substituted')
end)

t.test('UPPER CEILING: exactly AT the ceiling (50000) is accepted unchanged, with no warning', function()
    local f = newTrackingFixture({ maxLoggedEntries = { gunpowder = 50000 } })

    for _, line in ipairs(f.printLog) do
        t.isNil(line:find('Config.Tracking.Gunpowder.maxLoggedEntries', 1, true) and line:find('exceeds', 1, true),
            'a value exactly at the ceiling must never trigger the "exceeds ceiling" warning')
    end
end)

t.test('UPPER CEILING: one ms over the ceiling (50001) still warns -- boundary is inclusive, not off-by-one', function()
    local f = newTrackingFixture({ maxLoggedEntries = { scent = 50001 } })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.Scent.maxLoggedEntries', 1, true) and line:find('exceeds', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, '50001 (one over the ceiling) must still be clamped and warned about')
end)

t.test('UPPER CEILING: every real shipped config.lua default (6000/8000/6000) sits comfortably under the ceiling -- no warning ever fires for an untouched config', function()
    local f = newTrackingFixture() -- uses this fixture's own defaults, which mirror config.lua's shipped values

    for _, line in ipairs(f.printLog) do
        t.isFalse(line:find('maxLoggedEntries', 1, true) ~= nil and line:find('exceeds', 1, true) ~= nil,
            'the shipped defaults must never trip the new upper-ceiling warning: ' .. line)
    end
end)

os.exit(t.summary())
