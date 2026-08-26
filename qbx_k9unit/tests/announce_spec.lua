--[[
    tests/announce_spec.lua

    First test coverage for server/announce.lua and client/announce.lua
    (APPREHENSION ANNOUNCEMENT, Config.Features.ApprehensionAnnouncement).
    See server/announce.lua's own header for the full design writeup this
    suite exercises -- not re-derived here.

    SERVER FIXTURE: loads the REAL, unmodified server/cooldowns.lua ->
    server/entities.lua -> server/announce.lua chain (the exact
    fxmanifest.lua server_scripts order this file's own report proposes),
    mirroring tests/defense_spec.lua's/tests/combat_spec.lua's established
    convention for a feature file with real cross-file dependencies.
    HasK9Access is stubbed directly (same convention tests/combat_spec.lua
    and tests/kennel_spec.lua already established: it is genuinely another
    file's own logic, server/certifications.lua, already covered by its own
    spec -- this file's job is server/announce.lua's own gating/window/
    cleanup logic, not a second copy of certification checking).

    CLIENT FIXTURE: same "hand-built minimal Config, real production file"
    convention, for client/announce.lua.

    LOCALE, DELIBERATELY NOT the "never stub locale()" convention
    tests/pursuitsprint_spec.lua's own header documents for itself: THIS
    feature's own two new keys (announce.warning_received,
    announce.keybind_label) do not exist in locales/en.json yet --
    locales/en.json is off-limits to this pass (see this pass's own report
    for the exact proposed wording routed to main) -- so resolving them
    through Sandbox.locale's real, hard-asserting-on-a-miss implementation
    would fail this whole file at the very first client/announce.lua load,
    for a key that is EXPECTED to be missing right now, not a real bug.
    `testLocale` below therefore delegates every OTHER key (combat.
    no_target_in_range, combat.feature_disabled, common.notify_title --
    every one of which this file's own production code reuses verbatim
    from client/combat.lua rather than minting new duplicates) to the REAL
    Sandbox.locale, so this suite still doubles as a regression check that
    those reused keys really exist -- only the two brand-new keys get a
    clearly-marked stub, via Sandbox.newEnv's own documented `overrides`
    parameter (not a hack -- that parameter exists specifically for a spec
    to override one or two env entries on top of the shared defaults).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to
-- tests/defense_spec.lua's own copy (the only other file needing
-- GetEntityCoords' `-`/`#` operators).
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

-- ----------------------------------------------------------------------
-- Locale wrapper -- see this file's own header for the full reasoning.
-- ----------------------------------------------------------------------
local NEW_KEYS_NOT_YET_LANDED = {
    ['announce.warning_received'] = true,
    ['announce.keybind_label'] = true,
}
local function testLocale(key, ...)
    if NEW_KEYS_NOT_YET_LANDED[key] then
        return '[[stub:' .. key .. ']]'
    end
    return Sandbox.locale(key, ...)
end

--- Baseline Config.Combat.ApprehensionAnnouncement block, matching this
--- pass's own proposed config.lua numbers (see this pass's own report).
local function baselineAnnounceConfig()
    return { range = 8.0, windowMs = 20000, announceCooldownMs = 5000 }
end

-- ========================================================================
-- SERVER FIXTURE
-- ========================================================================

--- @param opts table? -- { featureOn (default true), announceCfg }
--- @return table fixture
local function newServerFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local k9AccessBySource = {}
    local function HasK9Access(src) return k9AccessBySource[src] == true end

    local onlinePlayerIds = {}
    local function GetPlayers()
        local out = {}
        for i, id in ipairs(onlinePlayerIds) do out[i] = tostring(id) end
        return out
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 900000) end

    -- Networked-entity world for ResolveNetworkEntity (server/entities.lua),
    -- same shape tests/defense_spec.lua's own copy uses.
    local networkEntities = {} -- netId -> handle
    local existingEntities = {} -- handle -> true
    local entityTypes = {} -- handle -> 1|2|3
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end
    local function DoesEntityExist(handle) return existingEntities[handle] == true end
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local announceCfg = opts.announceCfg or baselineAnnounceConfig()
    local config = {
        Features = { ApprehensionAnnouncement = opts.featureOn ~= false },
        Combat = { ApprehensionAnnouncement = announceCfg },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        HasK9Access = HasK9Access,
        GetPlayers = GetPlayers,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        Config = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/announce.lua', env)

    return {
        config = config,
        clientEvents = clientEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setK9Access = function(src, allowed) k9AccessBySource[src] = allowed end,
        setOnline = function(ids) onlinePlayerIds = ids end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setNetId = function(ped, netId) netIdByPed[ped] = netId end,
        registerEntity = function(netId, handle, entityType)
            networkEntities[netId] = handle
            existingEntities[handle] = true
            entityTypes[handle] = entityType or 1
        end,
        despawnEntity = function(handle) existingEntities[handle] = false end,
        isApprehensionWarned = function(targetNetId) return env.IsApprehensionWarned(targetNetId) end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            return handler(...)
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler()
            end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        clientEventsTo = function(target, eventName)
            local out = {}
            for _, e in ipairs(clientEvents) do
                if e.target == target and (not eventName or e.event == eventName) then
                    out[#out + 1] = e
                end
            end
            return out
        end,
        countClientEvents = function(eventName)
            local n = 0
            for _, e in ipairs(clientEvents) do
                if e.event == eventName then n = n + 1 end
            end
            return n
        end,
    }
end

-- Convenience: sets up one announcer (src 1, ped 101, netId 1101) and one
-- player target (src 2, ped 102, netId 1102) 3 meters apart, both with K9
-- access, ready to send a passing announce request.
local function setupBasicPair(f)
    f.setK9Access(1, true)
    f.setPed(1, 101)
    f.registerEntity(1101, 101, 1)
    f.setNetId(101, 1101)
    f.setCoords(101, 0, 0, 0)

    f.setPed(2, 102)
    f.registerEntity(1102, 102, 1)
    f.setNetId(102, 1102)
    f.setCoords(102, 3, 0, 0)

    f.setOnline({ 1, 2 })
end

t.test('server: IsApprehensionWarned is fully permissive when the feature flag is off', function()
    local f = newServerFixture({ featureOn = false })
    t.isTrue(f.isApprehensionWarned(1102), 'feature off must never block -- see this file header point 6')
end)

t.test('server: IsApprehensionWarned refuses a target with no announcement on file', function()
    local f = newServerFixture()
    t.isFalse(f.isApprehensionWarned(1102))
end)

t.test('server: a successful announce opens a window IsApprehensionWarned then reports true', function()
    local f = newServerFixture()
    setupBasicPair(f)

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    t.isTrue(f.isApprehensionWarned(1102))
end)

t.test('server: HasK9Access(false) refuses to open a window at all', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.setK9Access(1, false)

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    t.isFalse(f.isApprehensionWarned(1102))
end)

t.test('server: an announcer too far from the target cannot open a window (RED-TEAM: proximity is live, not client-claimed)', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.setCoords(102, 500, 0, 0) -- far outside the 8m default range

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    t.isFalse(f.isApprehensionWarned(1102))
end)

t.test('server: announcing at your own ped is a no-op', function()
    local f = newServerFixture()
    setupBasicPair(f)

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1101)

    t.isFalse(f.isApprehensionWarned(1101))
end)

t.test('server: a non-numeric targetNetId is rejected without erroring', function()
    local f = newServerFixture()
    setupBasicPair(f)

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:announceApprehensionWarning', 1, 'not-a-netid')
    t.isTrue(ok, 'a bad payload must be refused cleanly, never crash the handler')
end)

t.test('server: the window EXPIRES -- IsApprehensionWarned goes back to false after windowMs elapses', function()
    local f = newServerFixture({ announceCfg = { range = 8.0, windowMs = 5000, announceCooldownMs = 1000 } })
    setupBasicPair(f)

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)
    t.isTrue(f.isApprehensionWarned(1102))

    f.advance(4999)
    t.isTrue(f.isApprehensionWarned(1102), 'must still be open one ms before expiry')

    f.advance(2) -- now 5001ms since announce
    t.isFalse(f.isApprehensionWarned(1102), 'must be closed once expiresAt has passed')
end)

t.test('server: the per-ANNOUNCER cooldown blocks a second announce (against a DIFFERENT target) inside its window', function()
    local f = newServerFixture({ announceCfg = { range = 8.0, windowMs = 20000, announceCooldownMs = 10000 } })
    setupBasicPair(f)
    -- a third ped, far enough from the first target to prove this is a
    -- per-ANNOUNCER cooldown, not a per-target one
    f.setPed(3, 103)
    f.registerEntity(1103, 103, 1)
    f.setCoords(103, 2, 0, 0)
    f.setCoords(101, 0, 0, 0) -- announcer stays put; both targets in range of the announcer only

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)
    t.isTrue(f.isApprehensionWarned(1102))

    f.advance(1) -- still well inside announceCooldownMs
    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1103)
    t.isFalse(f.isApprehensionWarned(1103), 'same announcer, same cooldown window -- must be refused')

    f.advance(10000)
    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1103)
    t.isTrue(f.isApprehensionWarned(1103), 'cooldown elapsed -- must now succeed')
end)

t.test('server: a successful announce sends apprehensionWarningReceived to the resolved PLAYER target only', function()
    local f = newServerFixture()
    setupBasicPair(f)

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    local toTarget = f.clientEventsTo(2, 'qbx_k9unit:client:apprehensionWarningReceived')
    t.equals(#toTarget, 1, 'the suspect must be told, per requirement 6')
    local toAnnouncer = f.clientEventsTo(1, 'qbx_k9unit:client:apprehensionWarningReceived')
    t.equals(#toAnnouncer, 0, 'this notice is for the SUSPECT, never the announcer')
end)

t.test('server: an NPC target (no connected player behind the ped) never receives apprehensionWarningReceived, but the window still opens', function()
    local f = newServerFixture()
    f.setK9Access(1, true)
    f.setPed(1, 101)
    f.registerEntity(1101, 101, 1)
    f.setCoords(101, 0, 0, 0)
    -- 1102 resolves to a real, existing ped, but no `src` is ever
    -- registered as controlling it (setPed is never called for it) --
    -- exactly what an NPC target looks like to ResolveConnectedPlayerFromPed.
    f.registerEntity(1102, 902, 1)
    f.setCoords(902, 3, 0, 0)
    f.setOnline({ 1 })

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    t.isTrue(f.isApprehensionWarned(1102), 'the gate applies uniformly to NPC and player targets alike (see file header point 4)')
    t.equals(f.countClientEvents('qbx_k9unit:client:apprehensionWarningReceived'), 0)
end)

t.test('server: a successful announce broadcasts playBark to nearby players (including the target) but not to a far-away player', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.setPed(4, 104)
    f.setCoords(104, 9000, 0, 0) -- far outside ANNOUNCE_BROADCAST_RADIUS_METERS
    f.setOnline({ 1, 2, 4 })

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    t.equals(#f.clientEventsTo(1, 'qbx_k9unit:client:playBark'), 1, 'the announcer hears their own warning')
    t.equals(#f.clientEventsTo(2, 'qbx_k9unit:client:playBark'), 1, 'the suspect, specifically, must hear it -- requirement 6')
    t.equals(#f.clientEventsTo(4, 'qbx_k9unit:client:playBark'), 0, 'far bystanders are not spammed')
end)

t.test('server: playerDropped clears a PLAYER-target window (CLEANUP requirement)', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)
    t.isTrue(f.isApprehensionWarned(1102))

    f.firePlayerDropped(2) -- the TARGET disconnects

    t.isFalse(f.isApprehensionWarned(1102), 'a disconnected target\'s stale window must not linger')
end)

t.test('server: playerDropped for an unrelated source does not clear an open window', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    f.firePlayerDropped(999)

    t.isTrue(f.isApprehensionWarned(1102))
end)

t.test('server: onResourceStop wipes every open window, player and NPC target alike (CLEANUP requirement)', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)
    t.isTrue(f.isApprehensionWarned(1102))

    f.fireResourceStop('qbx_k9unit')

    t.isFalse(f.isApprehensionWarned(1102))
end)

t.test('server: onResourceStop for a DIFFERENT resource name is ignored', function()
    local f = newServerFixture()
    setupBasicPair(f)
    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)

    f.fireResourceStop('some_other_resource')

    t.isTrue(f.isApprehensionWarned(1102), 'must not react to an unrelated resource stopping')
end)

t.test('server: re-announcing while a window is already open REFRESHES its expiry rather than being ignored', function()
    local f = newServerFixture({ announceCfg = { range = 8.0, windowMs = 5000, announceCooldownMs = 1000 } })
    setupBasicPair(f)

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102)
    f.advance(4000) -- 1000ms left on the FIRST window; announceCooldownMs has also elapsed

    f.dispatchNetEvent('qbx_k9unit:server:announceApprehensionWarning', 1, 1102) -- re-announce
    f.advance(2000) -- 6000ms since the FIRST announce (would already be expired), only 2000ms since the SECOND

    t.isTrue(f.isApprehensionWarned(1102), 'the refreshed window must still be open')
end)

-- ========================================================================
-- CLIENT FIXTURE
-- ========================================================================

--- @param opts table? -- { featureOn (default true), announceCfg }
--- @return table fixture
local function newClientFixture(opts)
    opts = opts or {}

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local registeredCommands = {}
    local function RegisterCommand(name, handler) registeredCommands[name] = handler end

    local keyMappings = {}
    local function RegisterKeyMapping(commandString, description, mapper, defaultKey)
        keyMappings[#keyMappings + 1] = { commandString = commandString, description = description, mapper = mapper, defaultKey = defaultKey }
    end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local notifications = {}
    local fakeLib = {
        notify = function(payload) notifications[#notifications + 1] = payload end,
    }

    local myPed = 1
    local function PlayerPedId() return myPed end

    local coordsByPed = { [myPed] = vec3(0, 0, 0) }
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local pedPool = {}
    local function GetGamePool(poolName)
        if poolName == 'CPed' then return pedPool end
        return {}
    end

    local existingPeds = {}
    local function DoesEntityExist(ped) return existingPeds[ped] == true end

    local deadPeds = {}
    local function IsEntityDead(ped) return deadPeds[ped] == true end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 900000) end

    local canShowUi = opts.canShowK9UI ~= false
    local denyCalls = 0
    local function CanShowK9UI() return canShowUi end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local config = {
        Features = { ApprehensionAnnouncement = opts.featureOn ~= false },
        Combat = { ApprehensionAnnouncement = opts.announceCfg or baselineAnnounceConfig() },
    }

    local env = Sandbox.newEnv({
        locale = testLocale,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        TriggerServerEvent = TriggerServerEvent,
        lib = fakeLib,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        GetGamePool = GetGamePool,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        Config = config,
        source = 65535,
    })

    Sandbox.loadInto('../client/announce.lua', env)

    return {
        notifications = notifications,
        serverEvents = serverEvents,
        keyMappings = keyMappings,
        denyCalls = function() return denyCalls end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        addPed = function(ped, x, y, z, isDead)
            pedPool[#pedPool + 1] = ped
            existingPeds[ped] = true
            deadPeds[ped] = isDead == true
            coordsByPed[ped] = vec3(x, y, z)
        end,
        setNetId = function(ped, netId) netIdByPed[ped] = netId end,
        requestApprehensionWarning = function() env.RequestApprehensionWarning() end,
        fireWarningReceived = function(source, expiresAt)
            env.source = source
            local handler = netEvents['qbx_k9unit:client:apprehensionWarningReceived']
            assert(handler, 'apprehensionWarningReceived handler not registered')
            return handler(expiresAt)
        end,
        runCommand = function(name) registeredCommands[name]() end,
    }
end

t.test('client: RequestApprehensionWarning refuses locally, with feedback, when the feature is off', function()
    local f = newClientFixture({ featureOn = false })
    f.requestApprehensionWarning()

    t.equals(#f.serverEvents, 0, 'must never send the request when the feature is off')
    t.equals(#f.notifications, 1)
end)

t.test('client: RequestApprehensionWarning defers to CanShowK9UI/DenyK9UIAccess', function()
    local f = newClientFixture({ canShowK9UI = false })
    f.requestApprehensionWarning()

    t.equals(#f.serverEvents, 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('client: RequestApprehensionWarning notifies locally when no ped is in range', function()
    local f = newClientFixture()
    f.requestApprehensionWarning()

    t.equals(#f.serverEvents, 0)
    t.equals(#f.notifications, 1)
end)

t.test('client: RequestApprehensionWarning finds the NEAREST live ped in range and sends its netId', function()
    local f = newClientFixture()
    f.addPed(50, 100, 0, 0) -- outside default 8m range
    f.addPed(51, 4, 0, 0)   -- nearest in-range candidate
    f.addPed(52, 5, 0, 0)   -- also in range, but farther than 51
    f.setNetId(51, 4051)

    f.requestApprehensionWarning()

    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:announceApprehensionWarning')
    t.equals(f.serverEvents[1].args[1], 4051)
end)

t.test('client: RequestApprehensionWarning skips a dead ped', function()
    local f = newClientFixture()
    f.addPed(51, 4, 0, 0, true) -- dead -- must be ignored
    f.requestApprehensionWarning()

    t.equals(#f.serverEvents, 0, 'a dead ped must never be selected as a target')
end)

t.test('client: apprehensionWarningReceived shows a notification only when it genuinely came from the server (SOURCE-ORIGIN GUARD)', function()
    local f = newClientFixture()

    f.fireWarningReceived(65535, 1000)
    t.equals(#f.notifications, 1, 'a genuine server-sent event must notify the suspect')

    f.fireWarningReceived(1, 1000)
    t.equals(#f.notifications, 1, 'a locally self-triggered forgery must be rejected, count unchanged')
end)

t.test('client: the k9announce command routes to RequestApprehensionWarning', function()
    local f = newClientFixture()
    f.addPed(51, 4, 0, 0)
    f.setNetId(51, 4051)

    f.runCommand('k9announce')

    t.equals(#f.serverEvents, 1)
end)

t.test('client: registers a k9announce keybind', function()
    local f = newClientFixture()
    local found = false
    for _, mapping in ipairs(f.keyMappings) do
        if mapping.commandString == 'k9announce' then found = true end
    end
    t.isTrue(found)
end)

print('')
print('tests/announce_spec.lua:')
os.exit(t.summary())
