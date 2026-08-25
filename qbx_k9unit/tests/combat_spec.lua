--[[
    tests/combat_spec.lua

    First test coverage for server/combat.lua -- the largest and most
    security-sensitive file in this resource, previously with zero direct
    spec coverage despite being where several of this session's worst bugs
    lived (the four dead-native death-check no-ops, the BiteAndHold
    per-target XP farm, the holder-death lifecycle gap, the NPC-target
    native-availability bugs). Loads the REAL, unmodified
    server/cooldowns.lua -> server/entities.lua -> server/combat.lua chain
    (the exact fxmanifest.lua server_scripts order for this file's own
    load-time dependencies), so every NewCooldown/NewMutex/
    ResolveNetworkEntity/ResolveConnectedPlayerFromPed call this file makes
    is the real primitive, never a reimplementation.

    HasK9Access and NotifyPlayer are stubbed directly, same convention
    kennel_spec.lua already established: both are genuinely OTHER files' own
    logic (server/certifications.lua, server/notify.lua), already covered by
    their own specs -- this file's job is server/combat.lua's own
    validation/lifecycle/termination logic, not a second copy of those.
    IsHesitating/IsDistracted/AwardXP are the same "runtime existence guard,
    not a load-order assumption" shape server/combat.lua's own header
    documents -- omitted from the sandbox entirely by default (proving the
    real `type(...) == 'function'` guards degrade cleanly when
    server/wellbeing.lua / server/progression.lua are absent), added back
    as controllable stubs only for the tests that specifically exercise
    them.

    NOTE ON NOT ASSERTING PLAYER-FACING NOTIFICATION TEXT: server/combat.lua
    was, per this task's own instructions, being concurrently migrated to
    locale() by another agent WHILE this spec was authored (STRINGS only,
    not logic). Every assertion below is therefore against a STRUCTURAL,
    non-text observable: which client event fired (and to whom, with what
    typed payload), whether ActiveHolds/K9ActiveEffect changed, whether
    AwardXP was invoked, NotifyPlayer's `notifyType` (a stable enum:
    'error'/'success'/'inform', not prose) and call COUNT -- never
    `NotifyPlayer`'s `description` argument's actual text, and never a
    printed line's exact wording beyond a couple of hardcoded, clearly
    developer-only (not locale-migrated) diagnostic substrings ("failing
    closed") that appear nowhere near a NotifyPlayer/locale() call in the
    real source.

    ONE FRESH SANDBOX PER TEST (never shared) -- ActiveHolds/K9ActiveEffect/
    every cooldown tracker are file-lifetime `local` upvalues, so reusing one
    sandbox across unrelated cases would leak state, same discipline
    kennel_spec.lua/defense_spec.lua already established.

    YIELDING EVENT HANDLERS: HandleTakedownRequest (behind
    'qbx_k9unit:server:requestTakedown') calls a real Wait(...) mid-handler
    for its server-computed speed-sample window, then re-validates
    everything after the yield -- exactly the kind of TOCTOU logic this
    suite exists to exercise for real, not approximate. Every net event is
    therefore dispatched through a real Lua coroutine below (matching how
    FXServer itself invokes a RegisterNetEvent handler in its own
    coroutine, which is what makes a yieldable pcall -- Lua 5.2+'s
    lua_pcallk -- work at all): `dispatchNetEvent` auto-resumes through any
    yield with no test interaction (fine for handlers that don't care what
    happens mid-wait), and `dispatchStepped` exposes an `onSuspend` hook so
    a test can mutate world state (e.g. move the target) at the EXACT
    instant the handler is parked on its Wait(), to drive the real
    before/after speed sample deterministically without any wall-clock
    delay.

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - client/combat.lua is untested here -- client-only natives, no
        server-side equivalent to sandbox against, same blanket exclusion
        tests/README.md already states for every client/*.lua file.
      - NonComplianceDetection (the log-only movement-sampling thread) is
        left disabled (Config.Combat.NonComplianceDetection.enabled =
        false, the real shipped default) throughout this whole file and is
        NOT separately exercised -- it is explicitly non-punitive/
        detection-only (never gates a single server-authoritative outcome
        this suite's own "what matters most" brief cares about) and adds a
        second maintenance thread's worth of stubbing (GetPlayers/
        IsPlayerAceAllowed staff-notify fan-out) for a feature this task's
        brief does not name. Disclosed here as a real, deliberate scope cut,
        not a silent gap.
      - PropDragging gets a materially lighter pass than BiteAndHold/
        NonLethalTakedown (a handful of smoke tests near the bottom of this
        file) -- it shares this file's own EndHold/maintenance-thread/
        ActiveHolds machinery (so every death-check/termination-path
        assertion above already exercises code PropDragging also runs
        through), but its own bespoke logic (IsTargetDowned, the
        dual-release-side releaseDrag, DragExceedsMaxDistance) is not one of
        this task's five named priorities and is covered at "does this
        exist and work at all," not exhaustively.
      - The exact numeric XP payout amount is never asserted (this file
        never reads Config.XP.awards.* itself -- that's server/progression.lua's
        own concern, already covered by progression_spec.lua) -- only
        WHETHER AwardXP('biteHoldSuccess'/'takedownSuccess') was called at
        all, and how many times, which is what this task's brief actually
        asks this spec to pin.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to defense_spec.lua's own
-- copy (the only other files needing GetEntityCoords' `-`/`#` operators).
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
-- Real, shipped config.lua baselines -- used so boundary tests exercise the
-- actual numbers this resource ships, not arbitrary round test numbers,
-- same convention defense_spec.lua's baselineHandlerDownDefenseConfig()
-- already established. Callers may override any field via newCombatFixture's
-- own opts.*Cfg tables.
-- ----------------------------------------------------------------------

local function baselineBiteAndHoldConfig()
    return { range = 2.5, maxDurationMs = 15000, cooldownMs = 20000, targetCooldownMs = 35000 }
end

local function baselineTakedownConfig()
    return { range = 3.0, minTargetSpeed = 4.0, speedSampleWindowMs = 250, ragdollDurationMs = 4000, cooldownMs = 25000, targetCooldownMs = 30000, healthFloor = 100 }
end

local function baselinePropDraggingConfig(downedOverride)
    return { range = 2.5, maxDragDistance = 30.0, maxDragDurationMs = 20000, dragSpeedMultiplier = 0.4, IsPlayerDownedOverride = downedOverride }
end

local function baselineNonComplianceDetectionConfig()
    return {
        enabled = false, -- the real shipped default -- see this file's own header for why this stays disabled throughout
        positionSampleWindowMs = 500,
        biteHoldIdleCeiling = 0.3,
        biteHoldSpeedTolerance = 0.5,
        biteHoldViolationSamples = 2,
        takedownNetDisplacementMeters = 3.0,
        action = 'log',
        OnViolationOverride = nil,
        dragComplianceSlackMeters = 4.0,
    }
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/combat.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it
--- first (the exact fxmanifest.lua server_scripts order), and every other
--- cross-file/native dependency as a test-controlled stub.
--- @param opts table?
--- @return table fixture
local function newCombatFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, _description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, notifyType = notifyType }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local playersBySource = {} -- src -> { citizenid=, metadata={wanted=,iswanted=,isdead=,inlaststand=} }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 900000) end

    local networkEntities, existingEntities, entityTypes = {}, {}, {}
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end
    local function DoesEntityExist(handle) return existingEntities[handle] == true end
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local ragdollByPed = {}
    local function IsPedRagdoll(ped) return ragdollByPed[ped] == true end

    local onlineSet = {}
    local function GetPlayers()
        local out = {}
        for id in pairs(onlineSet) do out[#out + 1] = tostring(id) end
        return out
    end

    local function IsPlayerAceAllowed(_src, _perm) return false end -- staff-notify fan-out is not this spec's focus -- NonComplianceDetection stays disabled throughout, see this file's own header

    local awardCalls = {}
    local function awardXPFn(citizenid, awardKey)
        awardCalls[#awardCalls + 1] = { citizenid = citizenid, awardKey = awardKey }
    end

    local hesitatingByCid, distractedByCid = {}, {}
    local function isHesitatingFn(cid) return hesitatingByCid[cid] == true end
    local function isDistractedFn(cid) return distractedByCid[cid] == true end

    local config = {
        Features = {
            BiteAndHold = opts.biteAndHold ~= false,
            NonLethalTakedown = opts.nonLethalTakedown ~= false,
            PropDragging = opts.propDragging == true,
            HandlerDownDefense = false,
        },
        Combat = {
            RequireWantedStatus = opts.requireWantedStatus ~= false,
            WantedStatusCheckOverride = opts.wantedOverride,
            NonComplianceDetection = opts.nonComplianceDetectionCfg or baselineNonComplianceDetectionConfig(),
            PropDragging = opts.propDraggingCfg or baselinePropDraggingConfig(opts.downedOverride),
            BiteAndHold = opts.biteAndHoldCfg or baselineBiteAndHoldConfig(),
            NonLethalTakedown = opts.takedownCfg or baselineTakedownConfig(),
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
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        HasK9Access = HasK9Access,
        exports = { qbx_core = { GetPlayer = qbxGetPlayer } },
        GetPlayerPed = GetPlayerPed,
        GetEntityHealth = GetEntityHealth,
        GetEntityCoords = GetEntityCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        IsPedRagdoll = IsPedRagdoll,
        GetPlayers = GetPlayers,
        IsPlayerAceAllowed = IsPlayerAceAllowed,
        Config = config,
    }
    if opts.withAwardXP ~= false then envOverrides.AwardXP = awardXPFn end
    if opts.withWellbeing then
        envOverrides.IsHesitating = isHesitatingFn
        envOverrides.IsDistracted = isDistractedFn
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/combat.lua', env)

    --- Drives `netEvents[eventName]` to completion inside a real coroutine,
    --- auto-resuming through any Wait()-yield with no interaction (correct
    --- for every handler in this file except requestTakedown, and even for
    --- that one when a test does not care what happens mid-wait -- e.g. the
    --- "not fleeing" rejection, where leaving world state untouched during
    --- the yield is exactly what the test wants). `onSuspend`, if given, runs
    --- every time the coroutine parks on a Wait(), before it is resumed
    --- again -- this is what lets a test move a target's coordinates at the
    --- exact instant HandleTakedownRequest's own before/after speed sample
    --- is taken.
    --- @param eventName string
    --- @param src number
    --- @param args table
    --- @param onSuspend fun()?
    local function dispatchStepped(eventName, src, args, onSuspend)
        env.source = src
        local handler = netEvents[eventName]
        assert(handler, 'no handler registered for ' .. eventName)
        local co = coroutine.create(handler)
        local first = true
        for _ = 1, 50 do
            local result
            if first then
                result = { coroutine.resume(co, table.unpack(args)) }
                first = false
            else
                result = { coroutine.resume(co) }
            end
            if not result[1] then
                error(('dispatch(%s) coroutine error: %s'):format(eventName, tostring(result[2])))
            end
            if coroutine.status(co) == 'dead' then return end
            if onSuspend then onSuspend() end
        end
        error(('dispatch(%s) did not complete after repeated resumes -- unexpected extra yield?'):format(eventName))
    end

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        printedLines = printedLines,
        awardCalls = awardCalls,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayer = function(src, shape)
            playersBySource[src] = {
                citizenid = shape.citizenid,
                metadata = {
                    wanted = shape.wanted == true,
                    iswanted = shape.iswanted == true,
                    isdead = shape.isdead == true,
                    inlaststand = shape.inlaststand == true,
                },
            }
        end,
        clearPlayer = function(src) playersBySource[src] = nil end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setRagdoll = function(ped, isRagdoll) ragdollByPed[ped] = isRagdoll end,
        registerEntity = function(netId, handle, entityType)
            networkEntities[netId] = handle
            existingEntities[handle] = true
            entityTypes[handle] = entityType or 1
        end,
        addOnline = function(id) onlineSet[id] = true end,
        removeOnline = function(id) onlineSet[id] = nil end,
        setHesitating = function(citizenid, val) hesitatingByCid[citizenid] = val end,
        setDistracted = function(citizenid, val) distractedByCid[citizenid] = val end,
        dispatchNetEvent = function(eventName, src, ...)
            dispatchStepped(eventName, src, { ... }, nil)
        end,
        dispatchStepped = function(eventName, src, args, onSuspend)
            dispatchStepped(eventName, src, args, onSuspend)
        end,
        --- Manual, caller-driven coroutine over a single net event handler --
        --- the only way to interleave a SECOND, fully independent dispatch
        --- (TakedownMutex's own overlapping-call test) while the first is
        --- still parked mid-yield.
        --- @param eventName string
        --- @param src number
        --- @param args table
        --- @return table handle -- { resume = fun(), isDead = fun(): boolean }
        startCoroutine = function(eventName, src, args)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            local co = coroutine.create(handler)
            local started = false
            return {
                resume = function()
                    local result
                    if not started then
                        started = true
                        result = { coroutine.resume(co, table.unpack(args)) }
                    else
                        result = { coroutine.resume(co) }
                    end
                    if not result[1] then
                        error('startCoroutine resume error: ' .. tostring(result[2]))
                    end
                end,
                isDead = function() return coroutine.status(co) == 'dead' end,
            }
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
        runOneTick = function()
            -- Per fixtures/sandbox.lua's own documented stepping semantics:
            -- every captured thread's FIRST step() only reaches its own
            -- initial Wait() (primes, no pass); the loop below always
            -- performs exactly one full pass over every currently-captured
            -- thread by stepping twice from a fresh coroutine, and once more
            -- on every SUBSEQUENT call (matching defense_spec.lua's own
            -- primeIfNeeded/runOneTick split, restated inline here since this
            -- fixture only ever needs "one full pass", never a bare prime).
            if not threadRunner.primed then
                threadRunner.step()
                threadRunner.primed = true
            end
            threadRunner.step()
        end,
    }
end

-- ----------------------------------------------------------------------
-- Wiring helpers -- build a valid K9 / NPC target / player target in one
-- call, shared across most tests below.
-- ----------------------------------------------------------------------

--- @param f table
--- @param src number
--- @param opts table?
--- @return number ped
local function wireK9(f, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100)
    f.setAccess(src, opts.access ~= false)
    f.setPlayer(src, { citizenid = opts.citizenid or ('K9-CID-' .. src) })
    f.setPed(src, ped)
    f.setCoords(ped, opts.x or 0, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    return ped
end

--- @param f table
--- @param netId number
--- @param opts table?
--- @return number ped
local function wireNpcTarget(f, netId, opts)
    opts = opts or {}
    local ped = opts.ped or (netId + 100000)
    f.registerEntity(netId, ped, 1) -- GetEntityType 1 = ped
    f.setCoords(ped, opts.x or 1, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    if opts.ragdoll ~= nil then f.setRagdoll(ped, opts.ragdoll) end
    return ped
end

--- @param f table
--- @param netId number
--- @param src number
--- @param opts table?
--- @return number ped
local function wirePlayerTarget(f, netId, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100)
    f.registerEntity(netId, ped, 1)
    f.setPed(src, ped)
    f.setCoords(ped, opts.x or 1, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    f.setPlayer(src, {
        citizenid = opts.citizenid or ('TARGET-CID-' .. src),
        wanted = opts.wanted ~= false,
        isdead = opts.isdead,
        inlaststand = opts.inlaststand,
    })
    f.addOnline(src)
    return ped
end

--- @param f table
--- @param eventName string
--- @return table?
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then return f.clientEvents[i] end
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

local K9_SRC = 10
local K9_SRC_B = 11
local TARGET_SRC = 20

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/combat.lua registers exactly its 7 documented server net events', function()
    local f = newCombatFixture()
    local names, count = {}, 0
    for name in pairs(f.netEventNames) do names[name] = true; count = count + 1 end
    t.equals(count, 7)
    for _, name in ipairs({
        'qbx_k9unit:server:requestBiteHold', 'qbx_k9unit:server:releaseBiteHold',
        'qbx_k9unit:server:reportBiteHoldTargetDied', 'qbx_k9unit:server:requestTakedown',
        'qbx_k9unit:server:reportHolderDied', 'qbx_k9unit:server:requestDrag',
        'qbx_k9unit:server:releaseDrag',
    }) do
        t.isTrue(names[name] ~= nil, name .. ' must be registered')
    end
end)

t.test('server/combat.lua registers exactly 4 playerDropped handlers (its own, plus BiteHoldCooldown/TakedownCooldown/TakedownMutex own RegisterPlayerDropped)', function()
    local f = newCombatFixture()
    t.equals(f.eventHandlerCount('playerDropped'), 4)
end)

t.test('server/combat.lua registers exactly 1 onResourceStart handler (the PropDragging override warning)', function()
    local f = newCombatFixture()
    t.equals(f.eventHandlerCount('onResourceStart'), 1)
end)

t.test('with every combat feature flag off, the maintenance thread is never created, and requests are silently feature-gated', function()
    local f = newCombatFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = false })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
    local ok = pcall(f.runOneTick) -- must not error even though nothing was ever created
    t.isTrue(ok)
end)

t.test('onResourceStart: prints the spoofable-default warning for PropDragging when enabled with no IsPlayerDownedOverride', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = nil })
    f.fireResourceStart('qbx_k9unit')
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('IsPlayerDownedOverride is nil', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('onResourceStart: no warning when a real IsPlayerDownedOverride is configured', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = function() return false end })
    f.fireResourceStart('qbx_k9unit')
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('IsPlayerDownedOverride is nil', 1, true) ~= nil)
    end
end)

t.test('onResourceStart: ignores a different resource restarting', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = nil })
    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0)
end)

-- ========================================================================
-- ValidateCombatRequest -- the shared prefix, exercised via requestBiteHold.
-- ========================================================================

t.test('requestBiteHold: feature disabled is a silent-to-client no-op (only a NotifyPlayer, no hold created)', function()
    local f = newCombatFixture({ biteAndHold = false })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
end)

t.test('requestBiteHold: a non-number targetNetId is rejected without crashing', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 'not-a-number')
    t.isTrue(ok)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a targetNetId that resolves to nothing real is invalid_target', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 999999)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: no HasK9Access is rejected', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { access = false })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a K9 already engaged with another target is rejected, and the fresh target remains genuinely free for someone else', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldStarted'), 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501) -- already_engaged
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldStarted'), 1, 'no second hold for the same K9')

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldStarted'), 2, 'target 501 was never actually held by the rejected attempt above')
end)

t.test('requestBiteHold: targeting your own ped is self_target', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    f.registerEntity(999, k9Ped, 1) -- claim own ped's netId as the "target"
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 999)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: K9 offline (GetPlayerPed == 0) is a silent no-op, no crash', function()
    local f = newCombatFixture()
    f.setAccess(K9_SRC, true) -- HasK9Access true, but no setPed call -> GetPlayerPed returns 0
    wireNpcTarget(f, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(ok)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: beyond range is too_far', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    wireNpcTarget(f, 500, { x = 100, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a target already held by a different K9 is already_held, and the original holder\'s own hold is untouched', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireK9(f, K9_SRC_B)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'the second K9 must never have been granted the same target')
    -- the original holder can still release it -- proves it is still theirs
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1)
end)

t.test('requestBiteHold: an unwanted player target is not_eligible_target (RequireWantedStatus default true, no override)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = false })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a wanted player target succeeds, relayed ONLY to the target\'s own client', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:applyBiteHold')
    t.isNotNil(ev)
    t.equals(ev.target, TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 0)
end)

t.test('requestBiteHold: an NPC target succeeds, relayed ONLY to the requesting K9\'s own client', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:applyNpcBiteHold')
    t.isNotNil(ev)
    t.equals(ev.target, K9_SRC)
    t.equals(ev.args[1], 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 0)
end)

t.test('requestBiteHold: WantedStatusCheckOverride returning true is authoritative over metadata.wanted == false', function()
    local f = newCombatFixture({ wantedOverride = function(_src) return true end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = false })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 1)
end)

t.test('requestBiteHold: a WantedStatusCheckOverride that errors fails CLOSED (target treated as not eligible), regardless of metadata', function()
    local f = newCombatFixture({ wantedOverride = function(_src) error('boom') end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 0)
end)

t.test('requestBiteHold: a hesitating K9 (server/wellbeing.lua present) is rejected', function()
    local f = newCombatFixture({ withWellbeing = true })
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.setHesitating('K9-CID', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a distracted K9 (server/wellbeing.lua present) is rejected', function()
    local f = newCombatFixture({ withWellbeing = true })
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.setDistracted('K9-CID', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: server/wellbeing.lua entirely absent (no IsHesitating/IsDistracted) never crashes and proceeds normally', function()
    local f = newCombatFixture({ withWellbeing = false })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

-- ========================================================================
-- MUST-MATTER #1: death checks. GetEntityHealth <= 100 (PED_DEAD_HEALTH_
-- THRESHOLD) replaced IsEntityDead/IsPedDeadOrDying, which have no FXServer
-- server registration and always silently returned false. Pin the boundary
-- at 99/100/101 everywhere this file makes a "is this ped dead" decision.
-- ========================================================================

t.test('requestBiteHold: target health exactly 100 (the boundary) is rejected as dead', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 100 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: target health 99 (below the boundary) is rejected as dead', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 99 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: target health 101 (one above the boundary) is accepted as alive', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 101 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('reportBiteHoldTargetDied: target health exactly 100 (the boundary) ends the hold as target_died', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local targetPed = wirePlayerTarget(f, 501, TARGET_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.setHealth(targetPed, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1)
    t.equals(#f.awardCalls, 0, 'target_died must never pay biteHoldSuccess')
end)

t.test('reportBiteHoldTargetDied: target health 101 (still alive) is ignored -- claim does not match live server state', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local targetPed = wirePlayerTarget(f, 501, TARGET_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.setHealth(targetPed, 101)
    f.dispatchNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 0, 'hold must still be active -- the false claim must not end it')
end)

t.test('reportBiteHoldTargetDied: a source that is not genuinely the target of any active bite hold is a silent no-op', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500) -- NPC target -- TARGET_SRC is unrelated
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 0)
end)

t.test('reportHolderDied: holder health exactly 100 (the boundary) ends the hold as holder_died', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.setHealth(k9Ped, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportHolderDied', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 1)
    t.equals(#f.awardCalls, 0, 'holder_died must never pay biteHoldSuccess')
end)

t.test('reportHolderDied: holder health 101 (still alive) is ignored', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.setHealth(k9Ped, 101)
    f.dispatchNetEvent('qbx_k9unit:server:reportHolderDied', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0)
end)

t.test('reportHolderDied: a source not genuinely the holder of anything is a silent no-op', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:reportHolderDied', K9_SRC_B)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0)
end)

t.test('MAINTENANCE-THREAD BACKSTOP: a bite-hold against a PLAYER target has no holder-side client self-report at all -- only the maintenance thread\'s own HolderPedIsDead check ever catches the holder\'s death there', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 1)

    -- The holder dies, but nothing ever calls reportHolderDied for them
    -- (simulating exactly the disclosed gap: a bite/takedown holder holding
    -- a PLAYER target has no client-side per-tick self-check to report from).
    f.setHealth(k9Ped, 100) -- boundary
    f.runOneTick()

    local ev = lastClientEvent(f, 'qbx_k9unit:client:endBiteHold')
    t.isNotNil(ev, 'the maintenance thread must have ended the hold on its own')
    t.equals(ev.target, TARGET_SRC)
    t.equals(#f.awardCalls, 0, 'holder_died must never pay biteHoldSuccess')

    -- K9ActiveEffect must have been cleared too -- the K9 can engage a fresh
    -- target with no lingering already_engaged lockout, once its own
    -- unrelated per-K9 request-rate cooldown (a SEPARATE gate from
    -- K9ActiveEffect, stamped at the ORIGINAL request and untouched by how
    -- that hold ended) has also elapsed -- advanced past here specifically
    -- to isolate the already_engaged/K9ActiveEffect question from that
    -- unrelated cooldown.
    f.advance(baselineBiteAndHoldConfig().cooldownMs + 1)
    wireNpcTarget(f, 900)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 900)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('MAINTENANCE-THREAD BACKSTOP: a holder who is merely still ALIVE (101) is left alone by the maintenance thread', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.setHealth(k9Ped, 101)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endBiteHold'), 0)
end)

-- ========================================================================
-- MUST-MATTER #2: the BiteAndHold per-target cooldown. Prove BOTH the
-- per-K9 (BiteHoldCooldown) and per-target (BiteHoldTargetCooldown)
-- cooldowns are CHECKED before EITHER is stamped -- a rejected request must
-- burn neither.
-- ========================================================================

t.test('a released hold\'s per-target cooldown blocks a DIFFERENT, entirely fresh K9 from immediately re-taking the same target', function()
    local f = newCombatFixture() -- real shipped cooldownMs=20000 < targetCooldownMs=35000
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500) -- same instant, t=0
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'only the original hold -- the target\'s own cooldown must still be blocking the new K9')
end)

t.test('a request rejected purely for the TARGET being on cooldown never stamps the REJECTED K9\'s own per-K9 cooldown', function()
    -- cooldownMs deliberately larger than targetCooldownMs here, specifically
    -- so this test can distinguish "was the per-K9 cooldown wrongly stamped"
    -- from "the target cooldown just naturally cleared too" -- if the
    -- rejected attempt below had wrongly stamped K9 B's own 999999ms
    -- cooldown, the second attempt at t=5001 would still be blocked by IT,
    -- not merely by the (much shorter) target cooldown.
    local f = newCombatFixture({ biteAndHoldCfg = { range = 2.5, maxDurationMs = 15000, cooldownMs = 999999, targetCooldownMs = 5000 } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC) -- stamps target 500's own cooldown at t=0

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500) -- rejected: target still on its own 5000ms cooldown
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)

    f.advance(5001) -- target's own cooldown now clear; K9 B's own cooldown (999999) would STILL be blocking if the rejection above had wrongly stamped it
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2, 'K9 B\'s own per-K9 cooldown must never have been touched by the earlier target-cooldown rejection')
end)

t.test('a request rejected purely for the REQUESTING K9 being on cooldown never stamps the TARGET\'s own per-target cooldown', function()
    local f = newCombatFixture() -- real shipped cooldownMs=20000, targetCooldownMs=35000
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500) -- X: K9 A's own target
    wireNpcTarget(f, 501) -- Y: a completely fresh target, never touched by anyone
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC) -- stamps K9 A's OWN per-K9 cooldown at t=0

    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501) -- rejected: K9 A is on its OWN per-K9 cooldown, target Y itself was never touched
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'K9 A must not have been granted target Y')

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 501) -- same instant, t=0 -- must succeed if Y's own cooldown was never touched
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2, 'target Y\'s own per-target cooldown must never have been stamped by K9 A\'s rejected attempt against it')
end)

t.test('once BOTH cooldowns have genuinely elapsed, the same K9 can retake the same target it held before', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    f.advance(35001) -- past the real shipped targetCooldownMs (the binding one here)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

-- ========================================================================
-- MUST-MATTER #3: XP award exclusions. EndHold pays biteHoldSuccess only on
-- 'released' (with the MIN_BITE_HOLD_XP_DURATION_MS floor) and 'timeout'
-- (always, floor never applies). 'target_died'/'holder_died' are already
-- pinned as zero-payout above; this section covers released/timeout/
-- disconnect.
-- ========================================================================

t.test('released after >= 3000ms held is paid biteHoldSuccess exactly once', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 1)
    t.equals(f.awardCalls[1].citizenid, 'K9-CID')
    t.equals(f.awardCalls[1].awardKey, 'biteHoldSuccess')
end)

t.test('released at EXACTLY the 3000ms floor is paid (>=, not strictly >)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 1)
end)

t.test('released one millisecond under the 3000ms floor (2999ms) is NOT paid -- the anti-farm floor', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(2999)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('released immediately (0ms held) is NOT paid -- the accept-then-immediately-release macro this floor exists to block', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('a genuine timeout always pays biteHoldSuccess, even when maxDurationMs is BELOW the 3000ms anti-farm floor -- timeout bypasses that floor entirely', function()
    local f = newCombatFixture({ biteAndHoldCfg = { range = 2.5, maxDurationMs = 1000, cooldownMs = 20000, targetCooldownMs = 35000 } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(1000)
    f.runOneTick()
    t.equals(#f.awardCalls, 1, 'reason == timeout must pay regardless of held duration')
end)

t.test('target_died never pays (re-confirmed alongside the other three exclusions for a single, explicit side-by-side comparison)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local targetPed = wirePlayerTarget(f, 501, TARGET_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.advance(5000) -- comfortably past the XP floor, isolating the EXCLUSION itself, not the floor
    f.setHealth(targetPed, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('holder_died never pays (same side-by-side comparison as target_died above)', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(5000)
    f.setHealth(k9Ped, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportHolderDied', K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('holder_disconnected never pays', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(5000)
    f.firePlayerDropped(K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('target_disconnected never pays', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.advance(5000)
    f.firePlayerDropped(TARGET_SRC)
    t.equals(#f.awardCalls, 0)
    -- and the holder's own K9ActiveEffect state was genuinely freed by this,
    -- not left stuck -- advanced past the holder's own unrelated per-K9
    -- request-rate cooldown (stamped at the original request, separate from
    -- K9ActiveEffect) so this isolates already_engaged specifically.
    f.advance(baselineBiteAndHoldConfig().cooldownMs)
    wireNpcTarget(f, 900)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 900)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

-- ========================================================================
-- MUST-MATTER #5: termination paths. releaseBiteHold is unconditional once
-- ownership is verified -- no cooldown check, no HasK9Access re-check, no
-- feature-flag re-check. Prove a way out cannot be blocked.
-- ========================================================================

t.test('releaseBiteHold still works even after HasK9Access is revoked AND the feature flag is toggled off mid-hold', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)

    f.setAccess(K9_SRC, false) -- decertified mid-hold
    f.config.Features.BiteAndHold = false -- feature toggled off mid-hold

    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 1, 'a way out must never be blockable by a revoked access grant or a disabled feature flag')
end)

t.test('releaseBiteHold from a source that is NOT the genuine holder is a silent no-op, and the real hold survives it untouched', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:releaseBiteHold', K9_SRC_B)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0, 'an impostor release must never end the real holder\'s hold')

    -- the real holder can still release it themselves afterward
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 1)
end)

t.test('after releaseBiteHold, K9ActiveEffect is cleared -- the same K9 can engage a different target with no already_engaged lockout, once its own unrelated per-K9 cooldown also elapses', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    -- BiteHoldCooldown (a SEPARATE, request-rate gate stamped at the
    -- ORIGINAL request and untouched by release) would otherwise itself
    -- block an immediate second request regardless of K9ActiveEffect --
    -- advance past it so this test isolates already_engaged specifically.
    f.advance(baselineBiteAndHoldConfig().cooldownMs + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

t.test('after releaseBiteHold, ActiveHolds is cleared -- the target is no longer already_held (once its own per-target cooldown has also elapsed)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireK9(f, K9_SRC_B)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    f.advance(35001) -- past the target's own per-target cooldown, isolating already_held itself
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

-- ========================================================================
-- Disconnect cleanup (playerDropped)
-- ========================================================================

t.test('playerDropped for the holder ends the hold as holder_disconnected, relayed to the (player) target', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.firePlayerDropped(K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endBiteHold'), 1)
end)

t.test('playerDropped for the (player) target ends the hold as target_disconnected', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.firePlayerDropped(TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1, 'the holder must be told this ended')
end)

t.test('playerDropped for an unrelated source (neither holder nor target) is a no-op, never errors', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ok = pcall(f.firePlayerDropped, 99999)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0)
end)

t.test('playerDropped also frees BiteHoldCooldown for that source (RegisterPlayerDropped) -- an immediate re-request at the same instant succeeds', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.firePlayerDropped(K9_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501) -- no time advance -- only succeeds if the cooldown was genuinely cleared
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

-- ========================================================================
-- NonLethalTakedown -- server-computed speed gate (yielding handler), and a
-- regression check that its own sibling per-K9/per-target cooldown pair
-- (the shape BiteAndHold was originally missing half of) still holds.
-- ========================================================================

t.test('requestTakedown: a target that does not move during the sample window is rejected as not_fleeing, and neither cooldown is consumed', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 }) -- stationary throughout
    f.dispatchNetEvent('qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)

    -- Prove neither cooldown was burned: an immediate follow-up WITH real
    -- movement during the wait must still succeed at the same instant.
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setHealth(500 + 100000, 200) -- no-op touch, keeps this closure non-trivial
    end)
    -- the second dispatch above still didn't move the target -- do a THIRD,
    -- real attempt with genuine movement to confirm cooldowns are unburned.
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(500 + 100000, 1, 1.2, 0) -- 1.2m during a 250ms window = 4.8 m/s > 4.0 m/s threshold
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1, 'a genuinely fleeing target must still succeed -- proving the earlier not_fleeing rejections never consumed either cooldown')
end)

t.test('requestTakedown: a target that moves fast enough during the sample window succeeds, relaying to the K9 for an NPC target and paying takedownSuccess', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { citizenid = 'K9-CID', x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:applyNpcTakedown')
    t.isNotNil(ev)
    t.equals(ev.target, K9_SRC)
    t.equals(#f.awardCalls, 1)
    t.equals(f.awardCalls[1].awardKey, 'takedownSuccess')
end)

t.test('requestTakedown: a fleeing PLAYER target is relayed ONLY to the target\'s own client (forceRagdoll), never to the K9', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true, x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 501 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:forceRagdoll')
    t.isNotNil(ev)
    t.equals(ev.target, TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 0)
end)

t.test('requestTakedown: the real shipped per-K9/per-target cooldown pair still both gate a second takedown of the same freshly-takedown target', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    wireK9(f, K9_SRC_B, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1)

    -- A DIFFERENT K9 immediately trying the SAME (already ragdolled) target
    -- is blocked by already_held long before either cooldown even matters --
    -- advance past the ragdoll window first so already_held is no longer the
    -- reason, isolating TakedownTargetCooldown itself.
    f.advance(baselineTakedownConfig().ragdollDurationMs + 1)
    f.runOneTick()
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC_B, { 500 }, function()
        f.setCoords(ped, 1, 3, 0) -- keep moving to still pass the speed gate
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1, 'TakedownTargetCooldown must still be blocking a second K9 from an immediate repeat takedown')
end)

t.test('TakedownMutex rejects a second, overlapping requestTakedown from the SAME K9 while the first is still parked mid-wait', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })

    local h1 = f.startCoroutine('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 })
    h1.resume() -- runs into Wait() and parks there -- TakedownMutex is still held
    t.isFalse(h1.isDead())

    f.setCoords(ped, 1, 1.2, 0) -- world moves on while h1 is suspended
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.isTrue(ok, 'the overlapping call must be rejected gracefully, never error')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 0, 'the overlapping call must have been rejected by the mutex, not granted a second in-flight takedown')

    while not h1.isDead() do h1.resume() end
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1, 'the ORIGINAL call must still complete successfully once resumed to completion')
end)

-- ========================================================================
-- PropDragging -- lighter pass (shares this file's own EndHold/maintenance-
-- thread machinery, already exercised extensively above). See this file's
-- own header for why this section is intentionally not exhaustive.
-- ========================================================================

t.test('requestDrag: a target that is not downed at all is rejected, no drag started', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 200, ragdoll = false })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestDrag: an NPC target downed via health <= 100 is accepted', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 100 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:dragStarted')
    t.isNotNil(ev)
    t.equals(ev.args[2], false, 'isPlayerTarget must be false for an NPC target')
end)

t.test('requestDrag: an NPC target downed via IsPedRagdoll alone (healthy) is also accepted', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 200, ragdoll = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 1)
end)

t.test('requestDrag: a downed PLAYER target (metadata.isdead, no override) is accepted, relaying the speed limit to the target too', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    local started = lastClientEvent(f, 'qbx_k9unit:client:dragStarted')
    t.isNotNil(started)
    t.equals(started.args[2], true)
    local speedLimit = lastClientEvent(f, 'qbx_k9unit:client:applyDragSpeedLimit')
    t.isNotNil(speedLimit)
    t.equals(speedLimit.target, TARGET_SRC)
end)

t.test('requestDrag: an IsPlayerDownedOverride that errors fails CLOSED (rejected), even though metadata says downed', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = function(_src) error('boom') end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 0)
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('failing closed', 1, true) then found = true end
    end
    t.isTrue(found, 'an override error must be logged, not silently swallowed with no trace')
end)

t.test('releaseDrag from the HOLDER ends it as released_by_holder', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 100 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseDrag', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragEnded'), 1)
end)

t.test('releaseDrag from the PLAYER TARGET (not the holder) also ends it, with zero consent needed from the holder -- as released_by_target', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    f.dispatchNetEvent('qbx_k9unit:server:releaseDrag', TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragEnded'), 1)
end)

t.test('DragExceedsMaxDistance safety valve: the maintenance thread force-ends a drag once the holder/target gap exceeds maxDragDistance, unconditionally', function()
    local f = newCombatFixture({ propDragging = true, propDraggingCfg = baselinePropDraggingConfig(nil) })
    f.config.Combat.PropDragging.maxDragDistance = 5.0
    local k9Ped = wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local targetPed = wireNpcTarget(f, 500, { health = 100, x = 1, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)

    f.setCoords(targetPed, 100, 0, 0) -- far beyond maxDragDistance from the K9
    f.setCoords(k9Ped, 0, 0, 0)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragEnded'), 1)
end)

os.exit(t.summary())
