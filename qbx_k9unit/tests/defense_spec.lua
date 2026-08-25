--[[
    tests/defense_spec.lua

    First test coverage for server/defense.lua (previously zero, flagged by
    a lifecycle QA pass). Loads the REAL, unmodified server/cooldowns.lua ->
    server/entities.lua -> server/defense.lua chain into one sandbox (the
    exact fxmanifest.lua server_scripts order), and drives it through:

      - the maintenance CreateThread loop (stepped via
        fixtures/sandbox.lua's coroutine thread runner, same technique
        tenure_spec.lua already established for the only other
        thread-driven file in this suite),
      - the real captured 'qbx_k9unit:server:reportHandlerAttacker'
        RegisterNetEvent handler,
      - the real captured 'onResourceStart'/'playerDropped' AddEventHandler
        handlers.

    Every function under test here is `local` (IsHandlerDown,
    TryNotifyPartnerK9) or reached only via one of the three entry points
    above (the net event, GetGameTimer-driven poll thread, playerDropped) --
    exactly the "no local is ever reached by copying its logic into the
    test" discipline tests/README.md requires. Nothing here reimplements
    defense.lua's own decision logic; every assertion is against an
    OBSERVABLE side effect (a captured TriggerClientEvent call, a printed
    warning line, whether a query/resolve stub was even invoked) of the
    real production code running for real.

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - client/defense.lua is untested here (out of scope for this file --
        client-only natives, no server-side equivalent to sandbox against;
        same blanket exclusion tests/README.md already states for every
        client/*.lua file).
      - server/combat.lua's requestBiteHold/requestTakedown validation path
        that a real handlerDownDefenseTrigger notification eventually feeds
        into (via client/defense.lua, per this file's own header REALITY-
        CHECK item 2) is NOT re-verified here -- this file's own header is
        explicit that server/defense.lua is a "pure consumer" of that
        contract at the protocol level only, never re-implementing or
        re-validating it, and this suite follows the same boundary: it
        proves this file sends (or withholds) the RIGHT notification, never
        that a downstream requestBiteHold call later succeeds.
      - The disclosed, out-of-scope griefing vector this task's brief named
        (server/combat.lua's weapon-fire relay having no proximity check on
        its victim, letting any connected player raise a K9 officer's
        fear-stress/health from anywhere) is NOT server/defense.lua's own
        code and is not re-tested here as a combat.lua concern -- but the
        KNOCK-ON surface it has THROUGH this file (a proximity-free, cause-
        agnostic health drop reaching IsHandlerDown's raw-health fallback,
        and reportHandlerAttacker's own missing handler<->attacker proximity
        check) is this file's own attack surface and IS pinned explicitly
        below (see the "BOUNDED-BY-DESIGN SURFACES" section) -- not to
        argue it should change (it should not; this is a disclosed,
        deliberate design decision per this file's own header), but so the
        bound is an executable fact instead of only a comment.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to tenure_spec.lua's own
-- copy (the only other file needing GetEntityCoords' `-`/`#` operators).
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
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Real, shipped config.lua values for Config.Combat.HandlerDownDefense --
--- used as this fixture's baseline so boundary tests (triggerRadius,
--- hostileLookbackSeconds, ...) exercise the actual numbers this resource
--- ships, not arbitrary round test numbers.
--- @return table
local function baselineHandlerDownDefenseConfig()
    return {
        handlerHealthThreshold   = 140,
        triggerRadius            = 15.0,
        hostileLookbackSeconds   = 10,
        pollIntervalMs           = 1000,
        retriggerCooldownMs      = 30000,
        promptTtlMs              = 10000,
        attackerReportCooldownMs = 500,
        confirmKey               = 'G',
    }
end

--- Builds one complete, independent sandbox for server/defense.lua, with
--- the real server/cooldowns.lua and server/entities.lua loaded alongside
--- it first (the exact fxmanifest.lua server_scripts order), and every
--- other cross-file/native dependency as a test-controlled stub.
--- @param opts table? -- { featureOn (default true), downedOverride, handlerDownDefenseCfg, noPartnershipModule }
--- @return table fixture
local function newDefenseFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()

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

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- exports.qbx_core:GetPlayer(src) -- keyed by source, holds citizenid + metadata
    local playersBySource = {} -- src -> { citizenid = , metadata = { isdead=, inlaststand= } }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    -- exports.qbx_core:GetPlayerByCitizenId(citizenid) -- keyed by citizenid, holds source
    local sourceByCitizenid = {}
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        local src = sourceByCitizenid[citizenid]
        if not src then return nil end
        return { PlayerData = { source = src } }
    end

    -- server/partnership.lua's real accessor, stubbed
    local partnerByCitizenid = {} -- citizenid -> { partner = citizenid, isK9 = bool }
    local function GetActivePartnerCitizenId(citizenid)
        local entry = partnerByCitizenid[citizenid]
        if not entry then return nil, false end
        return entry.partner, entry.isK9
    end

    local onlinePlayerIds = {}
    local function GetPlayers()
        local out = {}
        for i, id in ipairs(onlinePlayerIds) do out[i] = tostring(id) end
        return out
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 900000) end

    -- Shared "networked entity" world for both reportHandlerAttacker's own
    -- ResolveNetworkEntity call and TryNotifyPartnerK9's read-time
    -- re-resolve -- same tables an entities_spec.lua-style fixture would use.
    local networkEntities = {} -- netId -> handle
    local existingEntities = {} -- handle -> true
    local entityTypes = {} -- handle -> 1|2|3
    local resolveCallCount = 0
    local function NetworkGetEntityFromNetworkId(netId)
        resolveCallCount = resolveCallCount + 1
        return networkEntities[netId] or 0
    end
    local function DoesEntityExist(handle) return existingEntities[handle] == true end
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local handlerDownDefenseCfg = opts.handlerDownDefenseCfg or baselineHandlerDownDefenseConfig()
    local config = {
        Features = { HandlerDownDefense = opts.featureOn ~= false },
        Combat = {
            PropDragging = { IsPlayerDownedOverride = opts.downedOverride },
            HandlerDownDefense = handlerDownDefenseCfg,
        },
    }

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        print = printStub,
        exports = {
            qbx_core = {
                GetPlayer = qbxGetPlayer,
                GetPlayerByCitizenId = qbxGetPlayerByCitizenId,
            },
        },
        GetPlayers = GetPlayers,
        GetPlayerPed = GetPlayerPed,
        GetEntityHealth = GetEntityHealth,
        GetEntityCoords = GetEntityCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        Config = config,
    }
    if not opts.noPartnershipModule then
        envOverrides.GetActivePartnerCitizenId = GetActivePartnerCitizenId
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/defense.lua', env)

    local primed = false
    local function primeIfNeeded()
        if not primed then
            threadRunner.step()
            primed = true
        end
    end

    return {
        config = config,
        clientEvents = clientEvents,
        printedLines = printedLines,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setPlayer = function(src, shape)
            playersBySource[src] = {
                citizenid = shape.citizenid,
                metadata = { isdead = shape.isdead == true, inlaststand = shape.inlaststand == true },
            }
        end,
        clearPlayer = function(src) playersBySource[src] = nil end,
        setPartner = function(citizenid, partnerCitizenid, isK9)
            partnerByCitizenid[citizenid] = { partner = partnerCitizenid, isK9 = isK9 }
        end,
        clearPartner = function(citizenid) partnerByCitizenid[citizenid] = nil end,
        setCitizenidSource = function(citizenid, src) sourceByCitizenid[citizenid] = src end,
        clearCitizenidSource = function(citizenid) sourceByCitizenid[citizenid] = nil end,
        setOnline = function(ids) onlinePlayerIds = ids end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setNetId = function(ped, netId) netIdByPed[ped] = netId end,
        registerEntity = function(netId, handle, entityType)
            networkEntities[netId] = handle
            existingEntities[handle] = true
            entityTypes[handle] = entityType or 1
        end,
        despawnEntity = function(handle) existingEntities[handle] = false end,
        resolveCallCount = function() return resolveCallCount end,
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
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName)
            end
        end,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        primeIfNeeded = primeIfNeeded,
        runOneTick = function()
            primeIfNeeded()
            threadRunner.step()
        end,
    }
end

--- @param f table
--- @param eventName string
--- @return table?
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then
            return f.clientEvents[i]
        end
    end
    return nil
end

--- @param f table
--- @param eventName string
--- @return integer
local function countClientEvents(f, eventName)
    local n = 0
    for _, e in ipairs(f.clientEvents) do
        if e.event == eventName then n = n + 1 end
    end
    return n
end

-- Fixed source ids used throughout, named for readability.
local HANDLER_SRC = 1
local K9_SRC = 2

--- Wires up the common "handler is down, partnered, K9 online and in
--- range" baseline every TryNotifyPartnerK9 scenario tweaks exactly one
--- thing off of. Handler health is set BELOW handlerHealthThreshold (raw
--- fallback path, no override) unless opts.healthy is set.
--- @param f table
--- @param opts table?
local function wireHappyPath(f, opts)
    opts = opts or {}
    local handlerSrc = opts.handlerSrc or HANDLER_SRC
    local k9Src = opts.k9Src or K9_SRC
    f.setOnline({ handlerSrc, k9Src })
    f.setPlayer(handlerSrc, { citizenid = 'HANDLER-CID', isdead = opts.isdead, inlaststand = opts.inlaststand })
    f.setPartner('HANDLER-CID', 'K9-CID', opts.handlerIsK9 == true)
    f.setCitizenidSource('K9-CID', k9Src)
    f.setPed(handlerSrc, 5001)
    f.setPed(k9Src, 5002)
    f.setCoords(5001, 0, 0, 0)
    f.setCoords(5002, opts.distance or 0, 0, 0)
    f.setNetId(5001, opts.handlerNetId or 77001)
    if not opts.healthy then
        f.setHealth(5001, opts.health or 50) -- well below the 140 baseline threshold
    else
        f.setHealth(5001, opts.health or 200)
    end
    return handlerSrc, k9Src
end

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/defense.lua registers exactly its one documented server net event', function()
    local f = newDefenseFixture()
    local names, count = {}, 0
    for name in pairs(f.netEventNames) do names[name] = true; count = count + 1 end
    t.equals(count, 1)
    t.isTrue(names['qbx_k9unit:server:reportHandlerAttacker'] ~= nil)
end)

t.test('server/defense.lua registers a playerDropped handler and an onResourceStart handler', function()
    local f = newDefenseFixture()
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1, "this file's own handler, plus both cooldowns' own via RegisterPlayerDropped()")
    t.isTrue(f.eventHandlerCount('onResourceStart') >= 1)
end)

t.test('Config.Features.HandlerDownDefense = false: no net event, no thread, no crash even with an otherwise-invalid config', function()
    -- Deliberately pairs the feature flag OFF with a pollIntervalMs that
    -- would fail the load-time assert if the feature were ON -- proves the
    -- early `if not Config.Features.HandlerDownDefense then return end`
    -- guard genuinely short-circuits the WHOLE file, including the assert
    -- below it, not just the event/thread registration.
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = 0
    local ok, f = pcall(newDefenseFixture, { featureOn = false, handlerDownDefenseCfg = cfg })
    t.isTrue(ok, 'loading with the feature flag off must never error, regardless of how broken the rest of the config block is')
    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 0, 'no net event registered when the feature is off')
    f.runOneTick()
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

-- ========================================================================
-- pollIntervalMs load-time assert -- what shape of config makes it fire.
-- ========================================================================

t.test('pollIntervalMs assert: a normal positive integer (the shipped default, 1000) loads fine', function()
    local ok = pcall(newDefenseFixture)
    t.isTrue(ok)
end)

t.test('pollIntervalMs assert: 0 fails to load, naming pollIntervalMs in the error', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = 0
    local ok, err = pcall(newDefenseFixture, { handlerDownDefenseCfg = cfg })
    t.isFalse(ok, 'a zero pollIntervalMs must fail resource-start loudly, not silently kill the thread on its first Wait()')
    t.contains(tostring(err), 'pollIntervalMs')
end)

t.test('pollIntervalMs assert: a negative value fails to load', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = -500
    local ok = pcall(newDefenseFixture, { handlerDownDefenseCfg = cfg })
    t.isFalse(ok)
end)

t.test('pollIntervalMs assert: NaN fails to load (a naive `> 0` check alone would miss this)', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = 0 / 0
    local ok = pcall(newDefenseFixture, { handlerDownDefenseCfg = cfg })
    t.isFalse(ok, 'NaN > 0 is false in Lua, but NaN == NaN is also false -- the assert must catch it via the self-equality test, not a bare > 0')
end)

t.test('pollIntervalMs assert: nil (key omitted from config) fails to load', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = nil
    local ok, err = pcall(newDefenseFixture, { handlerDownDefenseCfg = cfg })
    t.isFalse(ok)
    t.contains(tostring(err), 'pollIntervalMs')
end)

t.test('pollIntervalMs assert: a non-number (string) config value fails to load', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = '1000'
    local ok = pcall(newDefenseFixture, { handlerDownDefenseCfg = cfg })
    t.isFalse(ok, 'a stringly-typed Config value (e.g. from a copy-paste config mistake) must not slip past type(x) == "number"')
end)

t.test('pollIntervalMs assert: math.huge (positive, non-NaN) is CURRENTLY accepted -- documents the exact boundary of what this assert catches', function()
    -- Not a recommendation to ever configure this -- pinning the real,
    -- observed boundary: the assert only demands positive + non-NaN, not
    -- "sane". An operator typo producing an enormous number would load
    -- without error and simply poll extremely infrequently, not crash.
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.pollIntervalMs = math.huge
    local ok = pcall(newDefenseFixture, { handlerDownDefenseCfg = cfg })
    t.isTrue(ok, 'math.huge is a positive, non-NaN Lua number, so the current assert lets it through')
end)

-- ========================================================================
-- The two cooldowns' fail-closed direction: NewCooldown treats a
-- non-positive threshold as PERMANENTLY on, never as "no cooldown".
--
-- UPDATED, this pass (QA sandbox repro against server/combat.lua -- same
-- mechanism applies here; see server/cooldowns.lua's header ADDENDUM): this
-- section used to assert both cooldowns FAILED THE ENTIRE FILE'S LOAD on a
-- bad value, "blamed on NewCooldown" at construction time. That was itself
-- the bug: an uncaught error thrown from this file's own top-level chunk
-- aborts THIS FILE's execution from that line onward -- not just the one
-- misconfigured cooldown, but every RegisterNetEvent/AddEventHandler below
-- it too (reportHandlerAttacker, onResourceStart, the maintenance thread).
-- Both raw Config reads now go through ResolveConfiguredThresholdMs
-- (server/cooldowns.lua) before ever reaching NewCooldown, so a bad value
-- degrades to "this cooldown uses a safe built-in fallback, loudly warned
-- about" instead of "this file never finishes loading."
-- ========================================================================

t.test('retriggerCooldownMs = 0 no longer aborts this file\'s load -- clamps to the shipped 30000ms fallback and warns loudly, naming the exact key/value/substitute', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.retriggerCooldownMs = 0
    local f = newDefenseFixture({ handlerDownDefenseCfg = cfg })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.Combat.HandlerDownDefense.retriggerCooldownMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find('30000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')
    t.isNotNil(f.netEventNames['qbx_k9unit:server:reportHandlerAttacker'],
        'the net event must still be registered -- the whole file kept loading past the bad value')
end)

t.test('attackerReportCooldownMs = -1 no longer aborts this file\'s load -- clamps to the shipped 500ms fallback and warns loudly', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.attackerReportCooldownMs = -1
    local f = newDefenseFixture({ handlerDownDefenseCfg = cfg })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.Combat.HandlerDownDefense.attackerReportCooldownMs', 1, true)
            and line:find('found: -1', 1, true)
            and line:find('500', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)
    t.isNotNil(f.netEventNames['qbx_k9unit:server:reportHandlerAttacker'])
end)

t.test('retriggerCooldownMs = NaN no longer aborts this file\'s load', function()
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.retriggerCooldownMs = 0 / 0
    local f = newDefenseFixture({ handlerDownDefenseCfg = cfg })
    t.isNotNil(f.netEventNames['qbx_k9unit:server:reportHandlerAttacker'])
end)

t.test('Both cooldown thresholds failing closed means a misconfigured value never becomes "no cooldown" -- but it also never takes this file, or its net event/onResourceStart/playerDropped handlers, down with it', function()
    -- Restates the fail-closed DIRECTION as one assertion: there is no
    -- config shape under which a bad threshold here degrades into "no
    -- cooldown" (still structurally impossible -- IsOnCooldown's own
    -- fail-closed handling guarantees that regardless of how the threshold
    -- got here) NOR does it degrade into "the whole file stops loading"
    -- (ResolveConfiguredThresholdMs's whole purpose) -- it always resolves
    -- to a valid, positive, working cooldown.
    local cfg = baselineHandlerDownDefenseConfig()
    cfg.attackerReportCooldownMs = 0
    local f1 = newDefenseFixture({ handlerDownDefenseCfg = cfg })
    cfg = baselineHandlerDownDefenseConfig()
    cfg.retriggerCooldownMs = -30000
    local f2 = newDefenseFixture({ handlerDownDefenseCfg = cfg })
    t.isNotNil(f1.netEventNames['qbx_k9unit:server:reportHandlerAttacker'])
    t.isNotNil(f2.netEventNames['qbx_k9unit:server:reportHandlerAttacker'])
    t.equals(f1.eventHandlerCount('onResourceStart'), 1, 'onResourceStart must still be registered even with a misconfigured cooldown')
end)

-- ========================================================================
-- IsHandlerDown / onResourceStart spoofable-override warning
-- ========================================================================

t.test('onResourceStart: prints the spoofable-default warning when the feature is on and IsPlayerDownedOverride is nil', function()
    local f = newDefenseFixture({ downedOverride = nil })
    f.fireResourceStart('qbx_k9unit')
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('IsPlayerDownedOverride is nil', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('onResourceStart: no warning printed when a real IsPlayerDownedOverride is configured', function()
    local f = newDefenseFixture({ downedOverride = function() return false end })
    f.fireResourceStart('qbx_k9unit')
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('IsPlayerDownedOverride is nil', 1, true) ~= nil)
    end
end)

t.test('onResourceStart: ignores a DIFFERENT resource restarting (GetCurrentResourceName mismatch)', function()
    local f = newDefenseFixture({ downedOverride = nil })
    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0, 'a different resource restarting must never print this resource\'s own warning')
end)

t.test('IsHandlerDown: override returning true triggers a notification even with healthy raw HP', function()
    local f = newDefenseFixture({ downedOverride = function(_src) return true end })
    wireHappyPath(f, { healthy = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, 'the override is authoritative over raw health when configured')
end)

t.test('IsHandlerDown: override returning false suppresses a notification even with lethal raw HP', function()
    local f = newDefenseFixture({ downedOverride = function(_src) return false end })
    wireHappyPath(f, { health = 1 })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 0, 'an override present and returning false takes precedence over the raw-health fallback')
end)

t.test('IsHandlerDown: an override that ERRORS fails CLOSED (treated as not-down), never manufactures a trigger', function()
    local f = newDefenseFixture({ downedOverride = function(_src) error('boom') end })
    wireHappyPath(f, { healthy = true }) -- raw HP alone would not trigger either, isolating the override-error path
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 0)
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('errored for source', 1, true) then found = true end
    end
    t.isTrue(found, 'an override error must be logged, not silently swallowed with no trace')
end)

t.test('IsHandlerDown: no override configured, raw health at/below handlerHealthThreshold triggers via the fallback', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { health = 140 }) -- exactly AT the threshold
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, '<= is the documented comparison, not strictly <')
end)

t.test('IsHandlerDown: no override configured, health one point ABOVE threshold does not trigger', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { health = 141 })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 0)
end)

t.test('IsHandlerDown: no override configured, metadata.isdead alone triggers regardless of healthy raw HP', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { healthy = true, isdead = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)
end)

t.test('IsHandlerDown: no override configured, metadata.inlaststand alone triggers regardless of healthy raw HP', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { healthy = true, inlaststand = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)
end)

-- ========================================================================
-- TryNotifyPartnerK9 -- who gets notified, when.
-- ========================================================================

t.test('Happy path: down, partnered, K9 online and in range -> exactly one notification, to the K9, carrying the handler netId', function()
    local f = newDefenseFixture()
    local _, k9Src = wireHappyPath(f)
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev)
    t.equals(ev.target, k9Src)
    t.equals(ev.args[1], 77001)
    t.isNil(ev.args[2], 'no fresh hostile hint on record -> suggestedTargetNetId must be nil, not an error')
end)

t.test('Not down at all (healthy, no override, no metadata flags): no notification', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { healthy = true })
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test('Down but never partnered: silent no-op', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.clearPartner('HANDLER-CID')
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test('Down and "partnered", but the down party is itself the K9-role citizenid (queriedIsK9Role == true): no notification', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { handlerIsK9 = true })
    f.runOneTick()
    t.equals(#f.clientEvents, 0, 'HandlerDownDefense only concerns the handler-role party crossing the threshold, not the K9')
end)

t.test('Down, partnered, but the resolved K9 citizenid is not currently online: no notification', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.clearCitizenidSource('K9-CID')
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test('Down, partnered, K9 "online" per source mapping but GetPlayerPed resolves to 0 (mid-connect): no notification', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.setPed(K9_SRC, 0)
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test('Down, partnered, K9 online but beyond triggerRadius: no notification', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { distance = 15.1 }) -- baseline triggerRadius is 15.0
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test('Down, partnered, K9 exactly AT triggerRadius: notification still fires (<=, not strictly <)', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { distance = 15.0 })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)
end)

t.test('server/partnership.lua module absent (GetActivePartnerCitizenId not a function): silent no-op, no crash', function()
    local f = newDefenseFixture({ noPartnershipModule = true })
    wireHappyPath(f)
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'a missing partnership module must degrade to a no-op, never error the shared maintenance thread')
    t.equals(#f.clientEvents, 0)
end)

t.test('Handler player unresolvable via exports.qbx_core:GetPlayer (e.g. a race at disconnect): no crash, no notification', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.clearPlayer(HANDLER_SRC) -- IsHandlerDown's raw-health fallback does not need this; TryNotifyPartnerK9 does
    local ok = pcall(f.runOneTick)
    t.isTrue(ok)
    t.equals(#f.clientEvents, 0)
end)

t.test('Retry-while-down: a NON-dead down handler is re-notified every retriggerCooldownMs while still down (not edge-triggered-once)', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)

    -- Still down, but within the cooldown window -- must not re-fire yet.
    f.advance(29999)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, 'still within retriggerCooldownMs -- no second notification yet')

    -- Cooldown has now elapsed, handler is still down -- must fire again.
    f.advance(2)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 2, 'a non-corpse down handler must be retried, not silenced after the first notification')
end)

-- ========================================================================
-- reportHandlerAttacker -- suggestedTargetNetId hint plumbing, read fresh
-- at TryNotifyPartnerK9 time, never trusted as still valid.
-- ========================================================================

t.test('A fresh, still-resolvable hostile hint is included as suggestedTargetNetId', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(99001, 6001, 1) -- ped
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 99001)
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev)
    t.equals(ev.args[2], 99001)
end)

t.test('A hostile hint older than hostileLookbackSeconds is excluded (nil suggestedTargetNetId), not sent stale', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(99001, 6001, 1)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 99001)
    f.advance(10001) -- baseline hostileLookbackSeconds is 10 (i.e. 10000ms)
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev)
    t.isNil(ev.args[2])
end)

t.test('A stored hint whose entity has since despawned is re-resolved and excluded at READ time, not trusted from store time', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(99001, 6001, 1)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 99001)
    f.despawnEntity(6001) -- entity no longer exists by the time the poll thread reads the hint
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev)
    t.isNil(ev.args[2], 'a hint that no longer resolves must never be forwarded as a live pre-selection')
end)

t.test('reportHandlerAttacker: a non-number attackerNetId is rejected without even calling the resolver', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    local before = f.resolveCallCount()
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 'not-a-number')
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, { 1, 2, 3 })
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, nil)
    t.equals(f.resolveCallCount(), before, 'the type check must short-circuit BEFORE ResolveNetworkEntity is ever invoked')
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNil(ev.args[2], 'none of the malformed reports above may have stored a hint')
end)

t.test('reportHandlerAttacker: a claimed netId that resolves to nothing real is dropped, never stored', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 424242) -- never registered -> resolves to 0
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNil(ev.args[2])
end)

t.test('reportHandlerAttacker: the reporter cannot name their OWN ped as their attacker (self-inflicted/environmental damage guard)', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(55001, 5001, 1) -- 5001 is HANDLER_SRC's own ped, per wireHappyPath
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 55001)
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNil(ev.args[2], 'the reporter\'s own ped must never be recorded as their own attacker')
end)

t.test('reportHandlerAttacker: a malformed-TYPE report never consumes the cooldown -- a real report right behind it at the same instant still lands', function()
    -- Only the type(attackerNetId) ~= 'number' branch returns BEFORE
    -- AttackerReportCooldown.Consume(src) is ever called -- proven by a
    -- real, valid report immediately afterwards succeeding rather than
    -- being rate-limited by the earlier junk reports.
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(99001, 6001, 1) -- a real, distinct attacker
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 'garbage')
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, { 1 })
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 99001) -- same tick, same source
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.equals(ev.args[2], 99001, 'a real report must still land even immediately after rejected malformed-type reports at the same timestamp')
end)

t.test('DISCREPANCY, worth flagging: a report that PASSES the type check but is then rejected by the self-check (or fails to resolve) STILL consumes the per-source cooldown', function()
    -- AttackerReportCooldown.Consume(src) is called BEFORE the resolve
    -- and self-check below it in the real source, not after -- so a
    -- self-targeting (or otherwise-rejected) report is not "free": it
    -- burns that source's rate-limit slot for attackerReportCooldownMs
    -- exactly as a successful report would, even though nothing gets
    -- stored. A legitimate report immediately behind a spurious
    -- self-attack event (plausible in practice -- server/defense.lua's own
    -- comment on this exact self-check names self-inflicted/environmental
    -- damage as a real source of a degenerate attacker-is-victim game
    -- event) is therefore itself rate-limited away, not merely the
    -- spurious one. Not a security hole (LastHostile is only ever an
    -- optional pre-fill hint, never a capability), but real, observable
    -- behavior distinct from the type-check branch above -- pinned here
    -- rather than assumed to behave the same way.
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(55001, 5001, 1) -- reporter's own ped (HANDLER_SRC's own, per wireHappyPath)
    f.registerEntity(99001, 6001, 1) -- a real, distinct attacker
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 55001) -- self -- rejected AFTER consuming the cooldown
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 99001) -- same instant -- now rate-limited by the self-report above
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNil(ev.args[2], 'current behavior: the real report right behind the self-report is rate-limited away, not accepted')
end)

t.test('reportHandlerAttacker: AttackerReportCooldown genuinely rate-limits back-to-back VALID reports from the same source', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(11111, 7001, 1) -- first, real attacker
    f.registerEntity(22222, 7002, 1) -- second, real attacker, reported within the cooldown window
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 11111)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 22222) -- baseline attackerReportCooldownMs is 500; same instant here
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.equals(ev.args[2], 11111, 'the second, rate-limited report must not overwrite the first')

    -- That first runOneTick() already sent a real notification, which
    -- stamped DefenseTriggerCooldown (a SEPARATE cooldown from
    -- AttackerReportCooldown -- see this file's own report) at
    -- retriggerCooldownMs (30000ms, well past attackerReportCooldownMs'
    -- 500ms). Advance past retriggerCooldownMs too, not just the attacker
    -- cooldown, so the NEXT tick can actually emit a fresh, observable
    -- client event carrying whatever LastHostile holds by then.
    f.advance(30001)
    f.registerEntity(33333, 7003, 1)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 33333)
    f.runOneTick()
    local ev2 = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.equals(ev2.args[2], 33333, 'once the cooldown has elapsed, a fresh report must be accepted and overwrite the stale one')
end)

t.test('reportHandlerAttacker is rate-limited PER SOURCE -- a different reporting source is unaffected by another source\'s cooldown', function()
    local f = newDefenseFixture()
    -- Second handler+K9 pair, independent of HANDLER_SRC/K9_SRC.
    local otherHandlerSrc, otherK9Src = 3, 4
    wireHappyPath(f, { handlerSrc = HANDLER_SRC, k9Src = K9_SRC })
    f.setOnline({ HANDLER_SRC, K9_SRC, otherHandlerSrc, otherK9Src })
    f.setPlayer(otherHandlerSrc, { citizenid = 'HANDLER2-CID' })
    f.setPartner('HANDLER2-CID', 'K92-CID', false)
    f.setCitizenidSource('K92-CID', otherK9Src)
    f.setPed(otherHandlerSrc, 5003)
    f.setPed(otherK9Src, 5004)
    f.setCoords(5003, 0, 0, 0)
    f.setCoords(5004, 0, 0, 0)
    f.setHealth(5003, 50)
    f.setNetId(5003, 77003)

    f.registerEntity(1001, 8001, 1)
    f.registerEntity(2002, 8002, 1)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 1001) -- consumes HANDLER_SRC's cooldown
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', otherHandlerSrc, 2002) -- a DIFFERENT source, same instant

    f.runOneTick()
    local ev1 = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev1)
    -- Find the event actually targeted at each K9.
    local byTarget = {}
    for _, e in ipairs(f.clientEvents) do
        if e.event == 'qbx_k9unit:client:handlerDownDefenseTrigger' then byTarget[e.target] = e end
    end
    t.equals(byTarget[K9_SRC].args[2], 1001)
    t.equals(byTarget[otherK9Src].args[2], 2002, 'a second source\'s own first report must not be blocked by an unrelated source\'s cooldown')
end)

-- ========================================================================
-- Confirmed-corpse dedup (DeadHandlerAlreadyNotified) -- one notification
-- per down-episode while metadata.isdead == true, independent of
-- DefenseTriggerCooldown itself, and clearing correctly on full recovery.
-- ========================================================================

t.test('A confirmed-dead handler gets exactly one notification per down-episode, even after retriggerCooldownMs elapses again', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { isdead = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)

    -- Advance well past retriggerCooldownMs -- the cooldown alone would
    -- allow a second send; DeadHandlerAlreadyNotified must independently
    -- suppress it anyway, proving this is a SEPARATE gate, not merely the
    -- same cooldown re-observed.
    f.advance(60000)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, 'a confirmed corpse must not be re-alerted just because the retrigger cooldown expired')

    f.advance(120000)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, 'still deduped arbitrarily far into the same down-episode')
end)

t.test('The corpse dedup resets on full respawn: a FRESH down-and-dead episode after fully recovering notifies again', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { isdead = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)

    -- Full respawn: healthy again, isdead cleared -- IsHandlerDown must now
    -- read false, which is what clears DeadHandlerAlreadyNotified.
    f.setHealth(5001, 200)
    f.setPlayer(HANDLER_SRC, { citizenid = 'HANDLER-CID', isdead = false })
    f.advance(60000) -- also past retriggerCooldownMs, isolating the dedup-reset itself
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, 'a not-down tick must not itself send a notification')

    -- A brand new down-and-dead episode must now notify again.
    f.setHealth(5001, 50)
    f.setPlayer(HANDLER_SRC, { citizenid = 'HANDLER-CID', isdead = true })
    f.advance(60000)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 2, 'the flag must have been cleared by the intervening not-down tick, allowing a fresh corpse episode to notify once more')
end)

t.test('A merely-laststand (not confirmed-dead) handler is NOT deduped by DeadHandlerAlreadyNotified -- retry-while-down still applies', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { inlaststand = true, healthy = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)
    f.advance(30001)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 2, 'laststand-only (isdead still false) must retry every retriggerCooldownMs, unlike a confirmed corpse')
end)

-- ========================================================================
-- playerDropped: clears BOTH LastHostile and DeadHandlerAlreadyNotified --
-- including the recycled-source-id case, where a stale entry left by a
-- disconnected occupant must never leak into whoever gets that same
-- server id next.
-- ========================================================================

t.test('playerDropped clears a pending hostile hint for that source', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    f.registerEntity(99001, 6001, 1)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 99001)
    f.firePlayerDropped(HANDLER_SRC)
    -- Re-wire the SAME source (simulating a fast reconnect as the same
    -- player) and go down again -- the old hint must be gone.
    wireHappyPath(f)
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev)
    t.isNil(ev.args[2], 'a playerDropped in between must have cleared the previously-reported hostile hint')
end)

t.test('playerDropped clears the DeadHandlerAlreadyNotified flag for that source', function()
    local f = newDefenseFixture()
    wireHappyPath(f, { isdead = true })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)
    f.firePlayerDropped(HANDLER_SRC)
    wireHappyPath(f, { isdead = true })
    f.advance(60000) -- past retriggerCooldownMs too, isolating the dedup flag itself
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 2, 'playerDropped must have cleared the corpse-dedup flag, not just left it stuck forever')
end)

t.test('RECYCLED SERVER ID: a brand-new, unrelated player who inherits a disconnected player\'s old source id does not inherit their hostile hint', function()
    -- The prior occupant of source=9 reports a hostile, then disconnects
    -- WHILE that hint is still fresh (never consumed, never expired).
    local f = newDefenseFixture()
    local recycledSrc = 9
    f.setOnline({ recycledSrc, K9_SRC })
    f.setPlayer(recycledSrc, { citizenid = 'OLD-OCCUPANT-CID' })
    f.setPartner('OLD-OCCUPANT-CID', 'OLD-K9-CID', false)
    f.setCitizenidSource('OLD-K9-CID', K9_SRC)
    f.setPed(recycledSrc, 4001)
    f.setPed(K9_SRC, 4002)
    f.setCoords(4001, 0, 0, 0)
    f.setCoords(4002, 0, 0, 0)
    f.setHealth(4001, 200) -- old occupant currently healthy -- never actually triggers, just reports a hint and leaves
    f.registerEntity(31337, 7777, 1)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', recycledSrc, 31337)
    f.firePlayerDropped(recycledSrc)

    -- A completely different player connects and is assigned the SAME
    -- recycled source id, with a DIFFERENT citizenid/partner, and goes down.
    f.setPlayer(recycledSrc, { citizenid = 'NEW-OCCUPANT-CID' })
    f.setPartner('NEW-OCCUPANT-CID', 'NEW-K9-CID', false)
    f.setCitizenidSource('NEW-K9-CID', K9_SRC)
    f.setHealth(4001, 50) -- reuses the same ped handle number, which is fine/realistic -- a fresh spawn can reuse a low ped handle too
    f.runOneTick()

    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.isNotNil(ev, 'the new occupant must still be able to trigger a fresh notification at all')
    t.isNil(ev.args[2], 'the new occupant must never inherit the old occupant\'s stale hostile-attacker hint via the recycled source id')
end)

t.test('RECYCLED SERVER ID: a new occupant is not silently deduped by a corpse-notified flag the OLD occupant left behind at disconnect', function()
    -- The prior occupant of source=9 was confirmed-dead and already
    -- notified once, then disconnected WHILE STILL DOWN (never naturally
    -- respawned, so the maintenance thread's own "not down -> clear" path
    -- never ran for them) -- proving playerDropped's cleanup is what
    -- resets this, not merely the natural respawn transition.
    local f = newDefenseFixture()
    local recycledSrc = 9
    f.setOnline({ recycledSrc, K9_SRC })
    f.setPlayer(recycledSrc, { citizenid = 'OLD-OCCUPANT-CID', isdead = true })
    f.setPartner('OLD-OCCUPANT-CID', 'OLD-K9-CID', false)
    f.setCitizenidSource('OLD-K9-CID', K9_SRC)
    f.setPed(recycledSrc, 4001)
    f.setPed(K9_SRC, 4002)
    f.setCoords(4001, 0, 0, 0)
    f.setCoords(4002, 0, 0, 0)
    f.setHealth(4001, 1)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1)

    f.firePlayerDropped(recycledSrc) -- disconnects WHILE still confirmed-dead, flag never cleared by the natural respawn path

    -- New occupant, same source id, also confirmed-dead, past the retrigger
    -- cooldown so only the dedup flag itself is under test.
    f.setPlayer(recycledSrc, { citizenid = 'NEW-OCCUPANT-CID', isdead = true })
    f.setPartner('NEW-OCCUPANT-CID', 'NEW-K9-CID', false)
    f.setCitizenidSource('NEW-K9-CID', K9_SRC)
    f.advance(60000)
    f.runOneTick()

    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 2, 'the new occupant must be notified once for their own corpse episode -- the old occupant\'s dedup flag must not have survived the disconnect')
end)

-- ========================================================================
-- BOUNDED-BY-DESIGN SURFACES -- pinning, as an executable fact rather than
-- only a comment, exactly how far this file's own deliberately low-trust
-- inputs reach. Neither test argues these should change; both match this
-- file's own header framing ("carries no more capability than the K9
-- manually radial-selecting the same [...] target already would today").
-- ========================================================================

t.test('BOUNDED: IsHandlerDown\'s raw-health fallback reacts to ANY health drop with no attribution or proximity check on its cause -- the same trigger surface a remote, proximity-free damage source elsewhere in this resource would also cross', function()
    -- No attacker report, no override -- purely "health happens to be low
    -- right now, however it got that way". This is the exact surface a
    -- disclosed, out-of-scope griefing vector adjacent to this file
    -- (server/combat.lua's weapon-fire relay, which has no proximity check
    -- on ITS victim) would land on if it drove a handler's health below
    -- handlerHealthThreshold: a REAL notification still fires here, bounded
    -- only by retriggerCooldownMs and by never granting any capability
    -- beyond a pre-fill suggestion the K9 must still manually confirm.
    local f = newDefenseFixture()
    wireHappyPath(f, { health = 1 })
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:handlerDownDefenseTrigger'), 1, 'the trigger fires on the health FACT alone, never re-deriving or requiring who/what/how-far-away caused it')
end)

t.test('BOUNDED: reportHandlerAttacker has no proximity check between the reporting handler and the claimed attacker entity -- a report naming a far-away, unrelated ped is still accepted', function()
    local f = newDefenseFixture()
    wireHappyPath(f)
    -- Attacker entity placed far outside triggerRadius from the handler --
    -- proving there is no "the named attacker must be near me" gate here.
    f.registerEntity(88001, 9999, 1)
    f.setCoords(9999, 10000.0, 10000.0, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:reportHandlerAttacker', HANDLER_SRC, 88001)
    f.runOneTick()
    local ev = lastClientEvent(f, 'qbx_k9unit:client:handlerDownDefenseTrigger')
    t.equals(ev.args[2], 88001, 'a far-away entity is accepted as a hint -- the only real bounds are the per-source rate limit and that this is a manually-confirmed pre-fill suggestion, never an authorization')
end)

os.exit(t.summary())
