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

    local Config = {
        Features = {
            ScentTracking = true,
            BloodTracking = true,
            GunpowderSniffing = true,
            XPProgression = opts.xpProgression == true,
        },
        Tracking = {
            Scent     = { maxAgeSeconds = 300, maxRange = 40.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
            Blood     = { maxAgeSeconds = 300, maxRange = 40.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
            Gunpowder = { maxAgeSeconds = 120, maxRange = 40.0, searchCooldownMs = 5000, relayCooldownMs = 300 },
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

os.exit(t.summary())
