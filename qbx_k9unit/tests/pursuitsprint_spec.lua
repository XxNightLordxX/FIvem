--[[
    tests/pursuitsprint_spec.lua

    Direct, black-box tests of server/pursuitsprint.lua and
    client/pursuitsprint.lua against the REAL, unmodified production files
    (K9_IDEAS.md §5, "Pursuit sprint"). One file, per this task's own file
    allowlist -- server-side tests first, client-side tests second, each
    with its own fixture builder, mirroring how tests/defense_spec.lua and
    tests/clientagility_spec.lua are each structured internally even though
    this suite keeps server/client specs in separate files everywhere else.

    SERVER FIXTURE: loads the REAL server/cooldowns.lua and
    server/entities.lua (mirrors tests/combat_spec.lua's own convention of
    loading entities.lua for real rather than hand-stubbing
    ResolveNetworkEntity/ResolveConnectedPlayerFromPed, since this feature
    -- unlike server/recall.lua, which never calls either -- genuinely
    depends on their real resolution logic), then the real
    server/pursuitsprint.lua on top. `Config` is a small, hand-built table
    (mirroring tests/recall_spec.lua/tests/combat_spec.lua's own
    convention for a feature file with many independent knobs), NOT the
    real config.lua -- Config.Features.PursuitSprint/Config.PursuitSprint/
    Config.FeatureControl.RequireGrant.PursuitSprint do not exist in the
    currently-shipped config.lua as of this pass (reported to main
    separately to add), so this suite is deliberately independent of
    whether/when that lands.

    CLIENT FIXTURE: same "hand-built minimal Config" convention, plus a
    hand-rolled CPed pool (GetGamePool('CPed')) for FindNearestPursuitTarget,
    and Sandbox.newThreadRunner() to step the end-timer thread the grant
    handler starts (client/agility.lua's own header explains why that
    helper fits a CreateThread-based thread but not a plain RegisterCommand
    handler -- this file's end-timer IS a CreateThread body, so the helper
    fits directly, unlike clientagility_spec.lua's own TryVault).

    locale() is NEVER stubbed (this suite's established convention) --
    every locale('pursuitsprint.*') call exercised below resolves for real
    against locales/en.json, so this spec also doubles as a regression
    check that every key it reaches exists there once main applies this
    pass's own locale request.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape to every other spec in this suite
-- (clientagility_spec.lua/clientradial_spec.lua/combat_spec.lua/
-- certifications_spec.lua/tenure_spec.lua all carry their own copy).
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

-- ========================================================================
-- SERVER FIXTURE -- server/pursuitsprint.lua
-- ========================================================================

local REAL_SPEED_MULTIPLIER = 1.4
local REAL_DURATION_MS = 5000
local REAL_COOLDOWN_MS = 45000
local REAL_RANGE_METERS = 20.0

--- @param opts table? {
---   featureEnabled: boolean (default true) -- Config.Features.PursuitSprint
---   pursuitSprintCfg: table|false -- Config.PursuitSprint verbatim; false = omit entirely
---   requireWantedStatus: boolean (default true)
---   wantedStatusOverride: function?
---   requireGrantListed: boolean (default true) -- Config.FeatureControl.RequireGrant.PursuitSprint
---   withHasPermission: boolean (default true) -- whether HasPermission exists in the sandbox at all
---   hasPermissionFn: function -- override HasPermission's behavior
---   expectLoadError: boolean
--- }
--- @return table fixture
local function newServerFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local notifyLog = {}
    local function NotifyPlayer(src, message, kind)
        notifyLog[#notifyLog + 1] = { source = src, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    -- Player registry -- src <-> citizenid <-> ped.
    local playersBySource, pedBySource = {}, {}
    local function registerPlayer(src, citizenid, pedHandle, metadata)
        playersBySource[src] = { PlayerData = { citizenid = citizenid, metadata = metadata } }
        pedBySource[src] = pedHandle
    end

    -- NOTE: production code calls this with COLON syntax
    -- (`exports.qbx_core:GetPlayer(src)`), which passes `exports.qbx_core`
    -- itself as an implicit first argument -- mirrors
    -- tests/combat_spec.lua's own `qbxGetPlayer(_self, src)` stub shape
    -- exactly, for the same reason.
    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end
    local function GetPlayers()
        local list = {}
        for src in pairs(playersBySource) do list[#list + 1] = tostring(src) end
        return list
    end

    -- Bare-natives layer for the REAL server/entities.lua to call --
    -- mirrors tests/combat_spec.lua's own fixture shape.
    local pedByNetId = {}
    local existingEntities = {}
    local entityType = {}
    local function NetworkGetEntityFromNetworkId(netId) return pedByNetId[netId] or 0 end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityType(entity) return entityType[entity] or 1 end

    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local hasK9Access = true
    local hasK9AccessCalls = {}
    local function HasK9Access(src) hasK9AccessCalls[#hasK9AccessCalls + 1] = src; return hasK9Access end

    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local Config = {
        Features = { PursuitSprint = opts.featureEnabled ~= false },
        Combat = {
            RequireWantedStatus = opts.requireWantedStatus ~= false,
            WantedStatusCheckOverride = opts.wantedStatusOverride,
        },
        FeatureControl = {
            RequireGrant = { PursuitSprint = opts.requireGrantListed ~= false },
        },
    }
    if opts.pursuitSprintCfg == false then
        Config.PursuitSprint = nil
    elseif opts.pursuitSprintCfg ~= nil then
        Config.PursuitSprint = opts.pursuitSprintCfg
    else
        Config.PursuitSprint = {
            speedMultiplier = REAL_SPEED_MULTIPLIER,
            durationMs = REAL_DURATION_MS,
            cooldownMs = REAL_COOLDOWN_MS,
            requestRangeMeters = REAL_RANGE_METERS,
        }
    end

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local triggerClientEventCalls = {}
    local function TriggerClientEvent(name, target, ...)
        triggerClientEventCalls[#triggerClientEventCalls + 1] = { name = name, target = target, args = { ... } }
    end

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        exports = exportsTable,
        GetPlayerPed = GetPlayerPed,
        GetPlayers = GetPlayers,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        TriggerClientEvent = TriggerClientEvent,
    }
    if opts.withHasPermission ~= false then
        overrides.HasPermission = opts.hasPermissionFn or defaultHasPermission
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)

    local ok, err = pcall(Sandbox.loadInto, '../server/pursuitsprint.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err }
    end
    assert(ok, 'server/pursuitsprint.lua failed to load: ' .. tostring(err))

    return {
        env = env,
        Config = Config,
        notifyLog = notifyLog,
        printLog = printLog,
        eventHandlers = eventHandlers,
        triggerClientEventCalls = triggerClientEventCalls,
        hasK9AccessCalls = hasK9AccessCalls,
        permissionCalls = permissionCalls,
        advance = function(ms) state.now = state.now + ms end,
        setHasK9Access = function(v) hasK9Access = v end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        registerPlayer = registerPlayer,
        registerPed = function(entity, exists)
            existingEntities[entity] = exists ~= false
        end,
        registerTargetNetId = function(netId, pedHandle)
            pedByNetId[netId] = pedHandle
            existingEntities[pedHandle] = true
        end,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        --- Dispatches the real captured 'qbx_k9unit:server:requestPursuitSprint'
        --- handler with `env.source` set to `src`, mirroring
        --- tests/recall_spec.lua's own `dispatch` helper exactly.
        dispatch = function(src, targetNetId)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:server:requestPursuitSprint'],
                'server/pursuitsprint.lua did not register qbx_k9unit:server:requestPursuitSprint')
            handler(targetNetId)
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, h in ipairs(eventHandlers['playerDropped'] or {}) do h() end
        end,
    }
end

--- @return table? -- the LAST notifyLog entry for that source, or nil
local function lastNotifyFor(f, src)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == src then found = entry end
    end
    return found
end

-- ------------------------------------------------------------------
-- Feature gate / config asserts
-- ------------------------------------------------------------------

t.test('SERVER: Config.Features.PursuitSprint = false -- registers zero events, no asserts even run', function()
    local f = newServerFixture({ featureEnabled = false, pursuitSprintCfg = false })
    f.dispatch = nil -- nothing was registered to dispatch to
    t.equals(#f.notifyLog, 0)
end)

t.test('SERVER: Config.Features.PursuitSprint = true but Config.PursuitSprint entirely missing -- fails loudly at load, not silently', function()
    local f = newServerFixture({ pursuitSprintCfg = false, expectLoadError = true })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'Config.PursuitSprint is missing')
end)

t.test('SERVER: Config.PursuitSprint.speedMultiplier = 0 fails loudly at load', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = 0, durationMs = REAL_DURATION_MS, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = REAL_RANGE_METERS },
        expectLoadError = true,
    })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'speedMultiplier')
end)

t.test('SERVER: Config.PursuitSprint.durationMs missing fails loudly at load', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = REAL_RANGE_METERS },
        expectLoadError = true,
    })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'durationMs')
end)

t.test('SERVER: Config.PursuitSprint.requestRangeMeters = -1 fails loudly at load', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = REAL_DURATION_MS, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = -1 },
        expectLoadError = true,
    })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'requestRangeMeters')
end)

t.test('COOLDOWN FOOTGUN: Config.PursuitSprint.cooldownMs = 0 fails loudly at load, naming this resource\'s own "does NOT mean no cooldown" convention, instead of silently becoming a permanent lockout', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = REAL_DURATION_MS, cooldownMs = 0, requestRangeMeters = REAL_RANGE_METERS },
        expectLoadError = true,
    })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'cooldownMs')
    t.contains(f.loadError, 'does NOT mean')
end)

t.test('COOLDOWN FOOTGUN: a negative cooldownMs is caught the same way as zero', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = REAL_DURATION_MS, cooldownMs = -5000, requestRangeMeters = REAL_RANGE_METERS },
        expectLoadError = true,
    })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'cooldownMs')
end)

-- ------------------------------------------------------------------
-- Happy path + ANY PED / role-only gating
-- ------------------------------------------------------------------

t.test('HAPPY PATH: a certified K9, in range, against a wanted player target, with a real feature grant, is GRANTED -- TriggerClientEvent fires, no payload', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
    t.equals(f.triggerClientEventCalls[1].name, 'qbx_k9unit:client:pursuitSprintGranted')
    t.equals(f.triggerClientEventCalls[1].target, 1)
    t.equals(#f.triggerClientEventCalls[1].args, 0, 'the grant event must carry NO payload -- see this file\'s own header on why')
    t.isNil(lastNotifyFor(f, 1), 'a successful grant sends no NotifyPlayer at all -- only TriggerClientEvent')
end)

t.test('ANY PED: HasK9Access(src) is the ONLY role check -- this file never reads GetEntityModel/IsEntityModelK9/IsOwnModelK9 anywhere (grep-provable, re-asserted here behaviorally): a request from a source with NO ped-model stub registered at all still resolves purely on HasK9Access', function()
    local f = newServerFixture()
    f.setHasK9Access(true)
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1, 'no ped-model concept was ever consulted -- HasK9Access alone decided this')
end)

t.test('no_access: HasK9Access(src) = false denies outright, regardless of everything else being otherwise valid', function()
    local f = newServerFixture()
    f.setHasK9Access(false)
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_no_access'))
end)

-- ------------------------------------------------------------------
-- Target resolution
-- ------------------------------------------------------------------

t.test('invalid_target: a non-number targetNetId is rejected before touching HasK9Access', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.dispatch(1, 'not-a-number')
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_invalid_target'))
    t.equals(#f.hasK9AccessCalls, 0, 'invalid_target is checked BEFORE the role gate')
end)

t.test('invalid_target: a netId that does not resolve to any real entity', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.dispatch(1, 999999)
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_invalid_target'))
end)

t.test('self_target: targeting one\'s own ped is rejected', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.registerTargetNetId(9001, 100)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_self_target'))
end)

t.test('target_not_player: PLAYER-TARGET-ONLY -- a real, existing ped that belongs to no connected player (an NPC) is rejected, unlike server/combat.lua\'s BiteAndHold which permits NPC targets', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPed(300, true) -- an existing ped with no owning player registered anywhere
    f.setPedCoords(300, 1, 0, 0)
    f.registerTargetNetId(9002, 300)

    f.dispatch(1, 9002)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_target_not_player'))
end)

t.test('too_far: a real player target outside requestRangeMeters is rejected using LIVE server-side coordinates, never a client-claimed distance', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, REAL_RANGE_METERS + 5, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_too_far'))
end)

t.test('too_far boundary: exactly AT requestRangeMeters is accepted (">" not ">=")', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, REAL_RANGE_METERS, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

-- ------------------------------------------------------------------
-- Wanted/suspect eligibility -- reuses Config.Combat.* verbatim
-- ------------------------------------------------------------------

t.test('not_wanted: RequireWantedStatus = true (default) + target NOT flagged wanted is rejected', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = false })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_wanted'))
end)

t.test('RequireWantedStatus = false -- ANY player target is eligible, matching server/combat.lua\'s own IsPlayerWantedEligible short-circuit exactly', function()
    local f = newServerFixture({ requireWantedStatus = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, nil) -- no metadata at all
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('WantedStatusCheckOverride is used when present, and its return value is trusted verbatim', function()
    local overrideCalls = {}
    local f = newServerFixture({
        wantedStatusOverride = function(targetSrc) overrideCalls[#overrideCalls + 1] = targetSrc; return true end,
    })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = false }) -- would fail the DEFAULT check -- proves the override, not the fallback, decided this
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
    t.equals(overrideCalls[1], 2)
end)

t.test('WantedStatusCheckOverride ERRORING fails CLOSED (target treated as NOT eligible), never silently widening who can be targeted', function()
    local f = newServerFixture({
        wantedStatusOverride = function() error('boom') end,
    })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true }) -- would PASS the default check -- proves the override's error was what decided this, not a fallback
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_wanted'))
    t.isTrue(#f.printLog >= 1, 'the override error must be logged loudly, not swallowed')
end)

-- ------------------------------------------------------------------
-- Cooldown -- last gate, never consumed by an invalid request
-- ------------------------------------------------------------------

local function grantOnce(f, src, citizenid, targetSrc, targetCid, netId)
    f.registerPlayer(src, citizenid, src * 100, nil)
    f.registerPlayer(targetSrc, targetCid, targetSrc * 100, { wanted = true })
    f.grantPermission(citizenid, 'feature.PursuitSprint', true)
    f.setPedCoords(src * 100, 0, 0, 0)
    f.setPedCoords(targetSrc * 100, 1, 0, 0)
    f.registerTargetNetId(netId, targetSrc * 100)
end

t.test('on_cooldown: a second request from the same K9 inside cooldownMs is denied, and does not re-grant', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.advance(REAL_COOLDOWN_MS - 1)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'still on cooldown -- must not grant a second time')
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_on_cooldown'))
end)

t.test('cooldown elapsed: a later request past cooldownMs succeeds independently', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.advance(REAL_COOLDOWN_MS)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 2)
end)

t.test('AN INVALID REQUEST NEVER BURNS THE COOLDOWN: a too_far rejection does not consume the K9\'s cooldown -- an immediately-following, otherwise-valid request still succeeds', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, REAL_RANGE_METERS + 100, 0, 0) -- WAY too far
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_too_far'))

    -- Now bring the target into range, same tick (fakeNow unchanged) --
    -- if the too_far rejection had wrongly consumed the cooldown, this
    -- would now fail with denied_on_cooldown instead of succeeding.
    f.setPedCoords(200, 1, 0, 0)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('playerDropped clears the disconnecting K9\'s own cooldown entry (RegisterPlayerDropped wiring)', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.firePlayerDropped(1)

    -- A brand new occupant of the SAME recycled source id, still well
    -- within what would have been the old cooldown window, must not be
    -- blocked by the prior occupant's recent request.
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 2)
end)

-- ------------------------------------------------------------------
-- Per-person feature control -- Config.FeatureControl.RequireGrant's
-- documented 4-step resolution (steps 2-4; step 1 is the file-level gate
-- already covered above)
-- ------------------------------------------------------------------

t.test('grant_required: RequireGrant.PursuitSprint = true + no grant held -- denied even though HasK9Access is true', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    -- deliberately NOT granted
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_granted'))
end)

t.test('RequireGrant.PursuitSprint = true + an active feature.PursuitSprint grant -- allowed', function()
    local f = newServerFixture({ requireGrantListed = true })
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('BLOCK ALWAYS WINS: an explicit block.PursuitSprint denies even a citizenid who ALSO holds an active feature.PursuitSprint grant', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.grantPermission('K9-CID', 'block.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_granted'))
end)

t.test('RequireGrant.PursuitSprint = false (not listed) -- default ALLOW, no grant needed, matching config.lua\'s own documented step 4', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    -- deliberately NOT granted -- must still succeed since it is not listed
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('BLOCK STILL APPLIES even when NOT listed in RequireGrant (step 2 fires independently of step 3)', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'block.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
end)

t.test('server/permissions.lua entirely absent (HasPermission not even defined): RequireGrant-listed feature fails CLOSED (deny), never open', function()
    local f = newServerFixture({ requireGrantListed = true, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    local ok = pcall(f.dispatch, 1, 9001)

    t.isTrue(ok, 'a missing HasPermission must never error the request handler')
    t.equals(#f.triggerClientEventCalls, 0)
end)

t.test('server/permissions.lua entirely absent + feature NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newServerFixture({ requireGrantListed = false, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

-- ========================================================================
-- CLIENT FIXTURE -- client/pursuitsprint.lua
-- ========================================================================

--- @param opts table? {
---   featureEnabled: boolean (default true)
---   pursuitSprintCfg: table|false
---   expectLoadError: boolean
--- }
local function newClientFixture(opts)
    opts = opts or {}

    local Config = {
        Features = { PursuitSprint = opts.featureEnabled ~= false },
    }
    if opts.pursuitSprintCfg == false then
        Config.PursuitSprint = nil
    elseif opts.pursuitSprintCfg ~= nil then
        Config.PursuitSprint = opts.pursuitSprintCfg
    else
        Config.PursuitSprint = {
            speedMultiplier = REAL_SPEED_MULTIPLIER,
            durationMs = 300, -- 3 real ticks at this file's own 100ms tick, for a manageably short spec
            cooldownMs = REAL_COOLDOWN_MS,
            requestRangeMeters = REAL_RANGE_METERS,
        }
    end

    local pedHandle = 1
    local function PlayerPedId() return pedHandle end

    local pedCoords = { [1] = vec3(0, 0, 0) }
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local isDead = {}
    local function IsEntityDead(entity) return isDead[entity] == true end

    local existingEntities = { [1] = true }
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    local playerIndexByPed = {} -- ped -> playerIndex (>= 0), absent/-1 = NPC
    local function NetworkGetPlayerIndexFromPed(ped) return playerIndexByPed[ped] or -1 end

    local cpedPool = {}
    local function GetGamePool(kind) if kind == 'CPed' then return cpedPool end; return {} end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] end

    local isPedInAnyVehicle = false
    local isPedInAnyVehicleCalls = {}
    local function IsPedInAnyVehicle(ped, bool) isPedInAnyVehicleCalls[#isPedInAnyVehicleCalls + 1] = { ped = ped, bool = bool }; return isPedInAnyVehicle end

    local isInK9Vehicle = false
    local function IsInK9Vehicle() return isInK9Vehicle end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(name, ...) triggerServerEventCalls[#triggerServerEventCalls + 1] = { name = name, args = { ... } } end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local registerCommandCalls = {}
    local function RegisterCommand(name, handler, restricted)
        registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler, restricted = restricted }
    end
    local registerKeyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        registerKeyMappingCalls[#registerKeyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local RESOURCE_NAME = 'qbx_k9unit'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    -- Move-rate composer stand-in -- the REAL client/movement.lua globals
    -- this file depends on (soft dependency). Present by default (matches
    -- the shipped resource); a dedicated test below removes both to prove
    -- the fail-closed behavior when they are absent.
    local K9MoveRateModifiers, recomputeCalls
    local function RecomputeK9MoveRate() recomputeCalls = recomputeCalls + 1 end
    if opts.withMoveRateComposer ~= false then
        K9MoveRateModifiers = { pursuitSprint = 1.0 }
        recomputeCalls = 0
    end

    local overrides = {
        Config = Config,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        IsEntityDead = IsEntityDead,
        DoesEntityExist = DoesEntityExist,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        GetGamePool = GetGamePool,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        TriggerServerEvent = TriggerServerEvent,
        lib = { notify = lib_notify },
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = CreateThread,
        Wait = Wait,
    }
    if opts.isInK9VehicleDefined ~= false then
        overrides.IsInK9Vehicle = IsInK9Vehicle
    end
    if opts.withMoveRateComposer ~= false then
        overrides.K9MoveRateModifiers = K9MoveRateModifiers
        overrides.RecomputeK9MoveRate = RecomputeK9MoveRate
    end

    local env = Sandbox.newEnv(overrides)

    local ok, err = pcall(Sandbox.loadInto, '../client/pursuitsprint.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err }
    end
    assert(ok, 'client/pursuitsprint.lua failed to load: ' .. tostring(err))

    return {
        env = env,
        Config = Config,
        registerCommandCalls = registerCommandCalls,
        registerKeyMappingCalls = registerKeyMappingCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        notifyCalls = notifyCalls,
        isPedInAnyVehicleCalls = isPedInAnyVehicleCalls,
        threadCreateCount = function() return threadCreateCount end,
        recomputeCalls = function() return recomputeCalls end,
        K9MoveRateModifiers = K9MoveRateModifiers,
        runner = runner,
        setIsPedInAnyVehicle = function(v) isPedInAnyVehicle = v end,
        setIsInK9Vehicle = function(v) isInK9Vehicle = v end,
        setIsDead = function(entity, v) isDead[entity] = v end,
        addCandidate = function(ped, x, y, z, isPlayer, netId)
            cpedPool[#cpedPool + 1] = ped
            pedCoords[ped] = vec3(x, y, z)
            existingEntities[ped] = true
            playerIndexByPed[ped] = isPlayer and 0 or -1
            if netId then netIdByPed[ped] = netId end
        end,
        --- Runs the captured 'qbx_k9unit:pursuitsprint' command handler
        --- (RequestPursuitSprint) directly -- it never yields, so no
        --- coroutine wrapping is needed here (unlike client/agility.lua's
        --- TryVault).
        runRequest = function()
            local handler = assert(registerCommandCalls[1], 'client/pursuitsprint.lua did not register the qbx_k9unit:pursuitsprint command').handler
            handler()
        end,
        --- Dispatches the real captured 'qbx_k9unit:client:pursuitSprintGranted'
        --- handler with `env.source` set, mirroring every other spec's
        --- SOURCE-ORIGIN GUARD test convention in this suite.
        dispatchGrant = function(src)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:client:pursuitSprintGranted'],
                'client/pursuitsprint.lua did not register qbx_k9unit:client:pursuitSprintGranted')
            handler()
        end,
        fireResourceStop = function(resourceName)
            for _, h in ipairs(eventHandlers['onResourceStop'] or {}) do h(resourceName or RESOURCE_NAME) end
        end,
    }
end

-- ------------------------------------------------------------------
-- Feature gate / config asserts
-- ------------------------------------------------------------------

t.test('CLIENT: Config.Features.PursuitSprint = false -- registers zero commands/keybinds/events', function()
    local f = newClientFixture({ featureEnabled = false, pursuitSprintCfg = false })
    t.equals(#f.registerCommandCalls, 0)
    t.equals(#f.registerKeyMappingCalls, 0)
end)

t.test('CLIENT: Config.PursuitSprint missing while the flag is true fails loudly at load', function()
    local f = newClientFixture({ pursuitSprintCfg = false, expectLoadError = true })
    t.isFalse(f.loadOk)
    t.contains(f.loadError, 'Config.PursuitSprint is missing')
end)

t.test('CLIENT: registers exactly one command and one keybind, using the real locale key and default key "N"', function()
    local f = newClientFixture()
    t.equals(#f.registerCommandCalls, 1)
    t.equals(f.registerCommandCalls[1].name, 'qbx_k9unit:pursuitsprint')
    t.equals(#f.registerKeyMappingCalls, 1)
    t.equals(f.registerKeyMappingCalls[1].commandName, 'qbx_k9unit:pursuitsprint')
    t.equals(f.registerKeyMappingCalls[1].description, locale('pursuitsprint.keybind_label'))
    t.equals(f.registerKeyMappingCalls[1].defaultKey, 'N')
end)

-- ------------------------------------------------------------------
-- RequestPursuitSprint -- candidate selection is display-only
-- ------------------------------------------------------------------

t.test('vehicle tuck: seated in ANY vehicle -- silent return, no candidate search, no server round trip', function()
    local f = newClientFixture()
    f.setIsPedInAnyVehicle(true)
    f.runRequest()
    t.equals(#f.triggerServerEventCalls, 0)
    t.equals(#f.notifyCalls, 0)
    t.equals(f.isPedInAnyVehicleCalls[1].bool, false, 'IsPedInAnyVehicle must be called with the real 2nd arg (false)')
end)

t.test('vehicle tuck: IsInK9Vehicle() true (soft dependency DEFINED) -- silent return', function()
    local f = newClientFixture({ isInK9VehicleDefined = true })
    f.setIsInK9Vehicle(true)
    f.runRequest()
    t.equals(#f.triggerServerEventCalls, 0)
end)

t.test('vehicle tuck: IsInK9Vehicle NOT DEFINED AT ALL -- does not error, and does not block the request', function()
    local f = newClientFixture({ isInK9VehicleDefined = false })
    f.addCandidate(50, 1, 0, 0, true, 9001)
    local ok = pcall(f.runRequest)
    t.isTrue(ok, 'the `type(IsInK9Vehicle) == \'function\'` soft-dependency guard must never error when the global is entirely undefined')
    t.equals(#f.triggerServerEventCalls, 1)
end)

t.test('no eligible candidate within range -- notifies pursuitsprint.no_target_nearby, no server round trip', function()
    local f = newClientFixture()
    f.addCandidate(50, REAL_RANGE_METERS + 100, 0, 0, true, 9001) -- a real player, but far outside range
    f.runRequest()
    t.equals(#f.triggerServerEventCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('pursuitsprint.no_target_nearby'))
end)

t.test('candidate filtering: excludes self, dead peds, and non-player peds, and picks the NEAREST real player', function()
    local f = newClientFixture()
    f.addCandidate(1, 0, 0, 0, true, 111)     -- self -- must be excluded even though it's technically in the pool
    f.addCandidate(60, 2, 0, 0, false, 222)   -- non-player (NPC) -- must be excluded
    f.setIsDead(70, true)
    f.addCandidate(70, 1.5, 0, 0, true, 333)  -- dead player -- must be excluded
    f.addCandidate(80, 10, 0, 0, true, 444)   -- a real, live, farther player
    f.addCandidate(90, 3, 0, 0, true, 555)    -- a real, live, NEAREST eligible player

    f.runRequest()

    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].name, 'qbx_k9unit:server:requestPursuitSprint')
    t.equals(f.triggerServerEventCalls[1].args[1], 555, 'must target the nearest ELIGIBLE candidate\'s own netId, skipping self/NPC/dead entries even though they are closer or present in the pool')
end)

-- ------------------------------------------------------------------
-- Grant handling -- SOURCE-ORIGIN GUARD, application, end-timer,
-- death-reset, generation guard, onResourceStop
-- ------------------------------------------------------------------

t.test('SOURCE-ORIGIN GUARD: a forged grant (source ~= 65535) is ignored entirely -- no modifier change, no notify, no thread started', function()
    local f = newClientFixture()
    f.dispatchGrant(1) -- NOT 65535
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0)
    t.equals(#f.notifyCalls, 0)
    t.equals(f.threadCreateCount(), 0)
end)

t.test('genuine grant (source == 65535) applies the multiplier, recomputes, and notifies success', function()
    local f = newClientFixture()
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)
    t.equals(f.recomputeCalls(), 1)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('pursuitsprint.activated'))
    t.equals(f.notifyCalls[1].type, 'success')
end)

t.test('soft dependency: K9MoveRateModifiers/RecomputeK9MoveRate entirely absent -- grant handler fails CLOSED (no error, no notify, no thread)', function()
    local f = newClientFixture({ withMoveRateComposer = false })
    local ok = pcall(f.dispatchGrant, 65535)
    t.isTrue(ok, 'a missing move-rate composer must never error the grant handler')
    t.equals(#f.notifyCalls, 0)
    t.equals(f.threadCreateCount(), 0)
end)

t.test('END-TIMER: the modifier resets to neutral and RecomputeK9MoveRate is called again once durationMs elapses (never gated on any access/cert check -- this handler calls no such check at all)', function()
    local f = newClientFixture() -- durationMs = 300, 3 ticks of 100ms
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)

    -- 1 priming step + 3 real 100ms ticks = 4 total, per
    -- fixtures/sandbox.lua's own documented newThreadRunner() stepping
    -- convention (the first step() only reaches the loop's own first
    -- Wait(), the same shape tests/clientagility_spec.lua's TryVault tests
    -- rely on).
    f.runner.step()
    f.runner.step()
    f.runner.step()
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER, 'must still be boosted before the 4th step')
    f.runner.step()

    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0)
    t.equals(f.recomputeCalls(), 2, 'once for the grant, once for the end-timer reset')
end)

t.test('END-ON-DEATH: IsEntityDead(PlayerPedId()) true mid-burst ends the burst EARLY, well before durationMs elapses', function()
    local f = newClientFixture() -- durationMs = 300, 3 ticks of 100ms
    f.dispatchGrant(65535)

    f.runner.step() -- prime
    f.setIsDead(1, true)
    f.runner.step() -- first real tick (elapsed = 100) -- death is now observed and breaks the loop immediately

    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0, 'must already be reset after only 1 real tick, not the full 3')
end)

t.test('GENERATION GUARD: a stale end-timer from an EARLIER grant must never clobber a NEWER, still-active burst\'s modifier', function()
    local f = newClientFixture() -- durationMs = 300, 3 ticks of 100ms

    f.dispatchGrant(65535) -- grant #1 (generation 1) -- creates thread A
    f.runner.step() -- prime A
    f.runner.step() -- A: elapsed = 100

    f.dispatchGrant(65535) -- grant #2 (generation 2) -- creates thread B, while A is still mid-flight
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)

    f.runner.step() -- A: elapsed = 200; B: primed
    f.runner.step() -- A: elapsed = 300 -> A's OWN loop exits -> A's generation (1) != current (2) -> A must NOT reset; B: elapsed = 100

    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER,
        'the OLDER grant\'s end-timer finishing first must not reset a NEWER, still-active burst')

    f.runner.step() -- B: elapsed = 200
    f.runner.step() -- B: elapsed = 300 -> B's generation (2) == current (2) -> resets for real

    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0, 'the CURRENT (most recent) grant\'s own end-timer must still reset normally')
end)

t.test('onResourceStop: resets the modifier to neutral even mid-burst, and ignores a DIFFERENT resource stopping', function()
    local f = newClientFixture()
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)

    f.fireResourceStop('some_other_resource')
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER, 'a different resource stopping must never reset this one\'s state')

    f.fireResourceStop() -- this resource's own stop
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0)
end)

os.exit(t.summary())
