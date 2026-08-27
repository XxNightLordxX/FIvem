--[[
    tests/clientdefense_spec.lua

    Direct, black-box tests of client/defense.lua against the REAL,
    unmodified production file -- the client half of Handler-Down Defense
    (server/defense.lua's own contract). This file exposes three
    resource-globals (ConfirmHandlerDownDefense, HasFreshDefensePrompt,
    GetDefenseSuggestedTargetNetId), one RegisterNetEvent handler
    ('qbx_k9unit:client:handlerDownDefenseTrigger'), and one
    'gameEventTriggered' AddEventHandler (the attacker-hint capture). This
    spec drives all of them directly.

    ======================================================================
    THE ONE THING THIS SPEC EXISTS TO PIN, PER THIS TASK'S OWN INSTRUCTION:
    "client/defense.lua is the odd one out -- it is a UI-convenience layer
    that never moves the dog or fires an action by itself." This file's OWN
    header states the same thing at length ("§12.0 ITEM 2 ACCEPTANCE
    CRITERIA"): the handlerDownDefenseTrigger handler's only effects are a
    `lib.notify` and writing a plain Lua table; nothing here ever calls a
    task/control/movement/animation native on the K9's own ped, ever,
    autonomously. Sections B and F below prove this the same way this
    suite's other files prove a "never calls X" claim -- by OMITTING every
    plausible movement/task native from the sandbox entirely (not merely
    stubbing them) and confirming the relevant handler still runs to
    completion without error. If a future change made this file act on its
    own -- exactly the "significant behavioural change nobody asked for"
    this task warns against -- one of these tests would fail with
    "attempt to call a nil value", not silently pass.
    ======================================================================

    STUBBING EFFORT: proportionate. CanShowK9UI/DenyK9UIAccess,
    IsBiteHoldEngaged (soft dependency), ResolveNetworkEntity,
    TriggerServerEvent/RegisterNetEvent/RegisterCommand/RegisterKeyMapping,
    GetGameTimer, NetworkGetNetworkIdFromEntity/DoesEntityExist/
    GetEntityType, lib.notify -- every one a small, cheap
    recording/controllable stand-in. Deliberately absent from every
    fixture: SetEntityCoords, SetEntityHeading, TaskPlayAnim,
    TaskCombatPed, TaskGoToEntity, ClearPedTasks, DisableControlAction,
    SetFollowPedCamViewMode, SetPedMoveRateOverride -- see the header note
    above.

    ONE FRESH SANDBOX PER TEST -- PendingDefensePrompt is exactly the kind
    of module-lifetime state that must never leak between two unrelated
    test cases.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { handlerDownDefense: boolean?, canShowK9UI: boolean?, hasK9Access: boolean?, provideIsBiteHoldEngaged: boolean?, confirmKey: string?, promptTtlMs: number? }?
local function newDefenseFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    -- Kept controllable even though ConfirmHandlerDownDefense no longer
    -- calls it directly (PERMISSION AUDIT FOLLOW-UP, this pass -- was
    -- CanShowK9UI(), widened to match server/combat.lua's shared
    -- ValidateCombatRequest, which gates access on HasK9Access(src) alone
    -- -- see that function's own "GATE WIDENED" doc comment) -- same
    -- "kept controllable so a High-Command-bypass-shape test can prove it's
    -- irrelevant" reasoning tests/clientcombat_spec.lua's own newCombatFixture
    -- already established for the identical fix on RequestBiteHold/RequestTakedown.
    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local function CanShowK9UI() return canShowK9UI end

    -- GATE WIDENED TO HasK9Access() ALONE (permission audit finding, this
    -- pass) -- see ConfirmHandlerDownDefense()'s own doc comment. Defaults
    -- to true so every PRE-EXISTING test written before this gate changed
    -- keeps exercising the same "access granted" path without needing to
    -- opt in.
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end
    local denyCalls = 0
    local denyReasons = {}
    local function HasK9Access() return hasK9Access end
    local function DenyK9UIAccess(reason) denyCalls = denyCalls + 1; denyReasons[#denyReasons + 1] = reason end

    local isBiteHoldEngaged = false
    local function IsBiteHoldEngaged() return isBiteHoldEngaged end

    local resolvableNetIds = {} -- netId -> truthy entity handle, or explicitly false to model "not streamed in"
    local function ResolveNetworkEntity(netId)
        local v = resolvableNetIds[netId]
        if v == nil then return netId end -- default: resolvable, mirrors "streamed in" the common case
        if v == false then return nil end
        return v
    end

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted) commandHandlers[name] = handler end
    local keyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        keyMappingCalls[#keyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    local gameEventHandlers = {}
    local function AddEventHandler(eventName, handler)
        gameEventHandlers[eventName] = gameEventHandlers[eventName] or {}
        gameEventHandlers[eventName][#gameEventHandlers[eventName] + 1] = handler
    end

    local myPed = 1
    local function PlayerPedId() return myPed end
    local existingEntities = { [1] = true }
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local entityTypeByHandle = {}
    local function GetEntityType(entity) return entityTypeByHandle[entity] or 0 end
    local function NetworkGetNetworkIdFromEntity(entity) return entity * 1000 end

    local Config = {
        Features = { HandlerDownDefense = opts.handlerDownDefense ~= false },
        Combat = { HandlerDownDefense = {
            promptTtlMs = opts.promptTtlMs or 5000,
            confirmKey = opts.confirmKey or 'G',
        } },
    }

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        CanShowK9UI = CanShowK9UI,
        HasK9Access = HasK9Access,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        AddEventHandler = AddEventHandler,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        source = 65535,
    }
    if opts.provideIsBiteHoldEngaged ~= false then
        overrides.IsBiteHoldEngaged = IsBiteHoldEngaged
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../client/defense.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        serverEvents = serverEvents,
        keyMappingCalls = keyMappingCalls,
        denyCallCount = function() return denyCalls end,
        lastDenyReason = function() return denyReasons[#denyReasons] end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setIsBiteHoldEngaged = function(v) isBiteHoldEngaged = v end,
        setNow = function(v) fakeNow = v end,
        setEntityExists = function(entity, v) existingEntities[entity] = v end,
        setEntityType = function(entity, v) entityTypeByHandle[entity] = v end,
        setNetIdResolvable = function(netId, v) resolvableNetIds[netId] = v end,
        commandCount = function()
            local n = 0
            for _ in pairs(commandHandlers) do n = n + 1 end
            return n
        end,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEventHandlers) do n = n + 1 end
            return n
        end,
        gameEventHandlerCount = function() return #(gameEventHandlers['gameEventTriggered'] or {}) end,
        onResourceStopHandlerCount = function() return #(gameEventHandlers['onResourceStop'] or {}) end,
        runConfirmCommand = function()
            local handler = assert(commandHandlers['qbx_k9unit:confirmHandlerDownDefense'],
                'client/defense.lua did not register qbx_k9unit:confirmHandlerDownDefense')
            handler()
        end,
        fireTrigger = function(forged, handlerNetId, suggestedTargetNetId)
            env.source = forged and 999 or 65535
            local handler = assert(netEventHandlers['qbx_k9unit:client:handlerDownDefenseTrigger'],
                'client/defense.lua did not register qbx_k9unit:client:handlerDownDefenseTrigger')
            handler(handlerNetId, suggestedTargetNetId)
        end,
        fireGameEvent = function(eventName, data)
            for _, handler in ipairs(gameEventHandlers['gameEventTriggered'] or {}) do
                handler(eventName, data)
            end
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- feature flag off: GENUINELY inert.
-- ----------------------------------------------------------------------

t.test('Config.Features.HandlerDownDefense = false: registers NO command, NO keybind, NO net event, NO gameEventTriggered handler; all three resource-globals stay undefined', function()
    local f = newDefenseFixture({ handlerDownDefense = false })
    t.equals(f.commandCount(), 0)
    t.equals(f.netEventCount(), 0)
    t.equals(f.gameEventHandlerCount(), 0)
    t.isNil(f.env.ConfirmHandlerDownDefense)
    t.isNil(f.env.HasFreshDefensePrompt)
    t.isNil(f.env.GetDefenseSuggestedTargetNetId)
end)

t.test('Config.Features.HandlerDownDefense = true: registers its command, keybind, net event, and gameEventTriggered handler; all three resource-globals exist', function()
    local f = newDefenseFixture()
    t.equals(f.commandCount(), 1)
    t.equals(f.netEventCount(), 1)
    t.equals(f.gameEventHandlerCount(), 1)
    t.equals(#f.keyMappingCalls, 1)
    t.equals(f.keyMappingCalls[1].defaultKey, 'G')
    t.isNotNil(f.env.ConfirmHandlerDownDefense)
    t.isNotNil(f.env.HasFreshDefensePrompt)
    t.isNotNil(f.env.GetDefenseSuggestedTargetNetId)
end)

t.test('DISCLOSED, CONFIRMED CORRECT: no onResourceStop handler is ever registered -- this file applies no native side effect, so there is nothing to restore on a resource restart', function()
    local f = newDefenseFixture()
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

-- ----------------------------------------------------------------------
-- SECTION B -- THE CORE PIN: handlerDownDefenseTrigger NEVER acts
-- autonomously. Every plausible movement/task native is entirely absent
-- from this fixture -- if the handler ever called one, this would fail
-- with "attempt to call a nil value", not silently pass.
-- ----------------------------------------------------------------------

t.test('handlerDownDefenseTrigger never calls ANY movement/task/animation native -- proven by their total absence from the sandbox', function()
    local f = newDefenseFixture()
    for _, name in ipairs({
        'SetEntityCoords', 'SetEntityHeading', 'TaskPlayAnim', 'TaskCombatPed',
        'TaskGoToEntity', 'ClearPedTasks', 'ClearPedTasksImmediately',
        'DisableControlAction', 'SetFollowPedCamViewMode', 'SetPedMoveRateOverride',
        'TaskLeaveAnyVehicle', 'SetEntityVelocity', 'TaskCombatPedTimed',
    }) do
        t.isNil(f.env[name], name .. ' must be genuinely absent from this sandbox for this test to prove anything')
    end

    f.fireTrigger(false, 5000, 6000) -- must not error
    t.isTrue(f.env.HasFreshDefensePrompt())
    t.equals(#f.notifyCalls, 1, 'the ONLY observable effect is one lib.notify call')
end)

t.test('handlerDownDefenseTrigger: notifies with the configured confirmKey substituted, and records the prompt', function()
    local f = newDefenseFixture({ confirmKey = 'H' })
    f.fireTrigger(false, 5000, 6000)
    t.equals(f.notifyCalls[1].description, locale('defense.handler_under_attack', 'H'))
    t.equals(f.env.GetDefenseSuggestedTargetNetId(), 6000)
end)

t.test('handlerDownDefenseTrigger: a non-number suggestedTargetNetId (or nil) is normalized to nil, never stored as garbage', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 'not-a-number')
    t.isNil(f.env.GetDefenseSuggestedTargetNetId())
    t.isTrue(f.env.HasFreshDefensePrompt(), 'the prompt itself is still fresh even with no usable target')

    local f2 = newDefenseFixture()
    f2.fireTrigger(false, 5000, nil)
    t.isNil(f2.env.GetDefenseSuggestedTargetNetId())
end)

t.test('a forged (non-65535 source) trigger push is rejected outright -- no prompt, no notify', function()
    local f = newDefenseFixture()
    f.fireTrigger(true, 5000, 6000)
    t.isFalse(f.env.HasFreshDefensePrompt())
    t.equals(#f.notifyCalls, 0)
end)

t.test('a SECOND trigger overwrites the first (last-write-wins, no session/id merging) -- the newer suggestedTargetNetId replaces the older one', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 6000)
    t.equals(f.env.GetDefenseSuggestedTargetNetId(), 6000)
    f.fireTrigger(false, 5001, 7000)
    t.equals(f.env.GetDefenseSuggestedTargetNetId(), 7000)
    t.equals(#f.notifyCalls, 2)
end)

-- ----------------------------------------------------------------------
-- SECTION C -- prompt expiry (lazy, on next check -- no continuous thread).
-- ----------------------------------------------------------------------

t.test('a fresh prompt expires once GetGameTimer reaches its own expiresAt (checked lazily, on the next HasFreshDefensePrompt/GetDefenseSuggestedTargetNetId call)', function()
    local f = newDefenseFixture({ promptTtlMs = 1000 })
    f.setNow(0)
    f.fireTrigger(false, 5000, 6000)
    t.isTrue(f.env.HasFreshDefensePrompt())

    f.setNow(999)
    t.isTrue(f.env.HasFreshDefensePrompt(), 'not yet expired one tick before the boundary')

    f.setNow(1000)
    t.isFalse(f.env.HasFreshDefensePrompt(), 'expires AT the boundary (>=), not strictly after it')
    t.isNil(f.env.GetDefenseSuggestedTargetNetId())
end)

t.test('NO CONTINUOUS THREAD: this file registers zero CreateThread calls of any kind -- expiry is purely a lazy, on-read check', function()
    local threadCalls = 0
    local function CreateThread(_fn) threadCalls = threadCalls + 1 end
    local env = Sandbox.newEnv({
        Config = { Features = { HandlerDownDefense = true }, Combat = { HandlerDownDefense = { promptTtlMs = 5000, confirmKey = 'G' } } },
        GetGameTimer = function() return 0 end,
        CanShowK9UI = function() return true end,
        DenyK9UIAccess = function() end,
        lib = { notify = function() end },
        TriggerServerEvent = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        RegisterKeyMapping = function() end,
        AddEventHandler = function() end,
        PlayerPedId = function() return 1 end,
        DoesEntityExist = function() return true end,
        GetEntityType = function() return 1 end,
        NetworkGetNetworkIdFromEntity = function(e) return e * 1000 end,
        ResolveNetworkEntity = function(netId) return netId end,
        CreateThread = CreateThread,
    })
    Sandbox.loadInto('../client/defense.lua', env)
    t.equals(threadCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- ConfirmHandlerDownDefense(): every rejection path, ANY PED,
-- the "pure consumer, not RequestBiteHold/RequestTakedown" contract, and
-- the GATE WIDENED TO HasK9Access() ALONE fix (permission audit finding,
-- this pass -- was CanShowK9UI(); see that function's own doc comment).
-- ----------------------------------------------------------------------

t.test('CONTROL: ConfirmHandlerDownDefense: HasK9Access() false denies access with reason combat.no_access, no server event, prompt untouched', function()
    local f = newDefenseFixture({ hasK9Access = false })
    f.fireTrigger(false, 5000, 6000)
    f.runConfirmCommand()
    t.equals(f.denyCallCount(), 1)
    t.equals(f.lastDenyReason(), 'combat.no_access')
    t.equals(#f.serverEvents, 0)
    f.setHasK9Access(true)
    t.isTrue(f.env.HasFreshDefensePrompt(), 'a denial on the access check must not have consumed the prompt')
end)

t.test('GATE WIDENED: HasK9Access() true with CanShowK9UI() false (High Command/autoAccessGrade-bypass shape) still reaches the server -- proves this gate is HasK9Access() alone, not the broader CanShowK9UI() combinator', function()
    local f = newDefenseFixture({ hasK9Access = true, canShowK9UI = false })
    f.fireTrigger(false, 5000, 6000)
    f.runConfirmCommand()
    t.equals(f.denyCallCount(), 0, 'a HasK9Access()-true bypass holder must never be denied even though CanShowK9UI() would have refused them')
    t.equals(#f.serverEvents, 1, 'a HasK9Access()-true bypass holder must reach the server even though CanShowK9UI() would have refused them')
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:requestBiteHold')
    t.equals(f.serverEvents[1].args[1], 6000)
end)

t.test('ANY PED: ConfirmHandlerDownDefense never touches a model native directly -- proven by omitting IsOwnModelK9/GetEntityModel from the sandbox entirely', function()
    local f = newDefenseFixture()
    t.isNil(f.env.IsOwnModelK9)
    t.isNil(f.env.GetEntityModel)
    f.fireTrigger(false, 5000, 6000)
    f.runConfirmCommand() -- must not error
    t.equals(#f.serverEvents, 1)
end)

t.test('ConfirmHandlerDownDefense: no fresh prompt (never triggered) notifies no_active_alert, no server event', function()
    local f = newDefenseFixture()
    f.runConfirmCommand()
    t.equals(f.notifyCalls[1].description, locale('defense.no_active_alert'))
    t.equals(#f.serverEvents, 0)
end)

t.test('ConfirmHandlerDownDefense: an EXPIRED prompt is refused the SAME WAY as no prompt at all (no server event) but with DIFFERENT, more specific wording -- EXPIRED-VS-NEVER-TRIGGERED fix, this pass', function()
    local f = newDefenseFixture({ promptTtlMs = 100 })
    f.fireTrigger(false, 5000, 6000)
    f.setNow(100)
    f.runConfirmCommand()
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('defense.alert_expired'), 'an alert that genuinely existed and timed out must say so, not the generic "no active alert" copy')
    t.equals(#f.serverEvents, 0)
end)

t.test('ConfirmHandlerDownDefense: EXPIRED-VS-NEVER-TRIGGERED CONTROL -- a prompt that never existed at all still gets the plain no_active_alert copy, never the expired one', function()
    local f = newDefenseFixture()
    f.runConfirmCommand()
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('defense.no_active_alert'), 'never having a prompt must not be misreported as one that expired')
    t.equals(#f.serverEvents, 0)
end)

t.test('ConfirmHandlerDownDefense: IsBiteHoldEngaged() true rejects with already_engaged and does NOT consume the prompt (a later retry can still succeed)', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 6000)
    f.setIsBiteHoldEngaged(true)
    f.runConfirmCommand()
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('defense.already_engaged'))
    t.equals(#f.serverEvents, 0)

    f.setIsBiteHoldEngaged(false)
    f.runConfirmCommand()
    t.equals(#f.serverEvents, 1, 'the prompt must still have been fresh -- the engaged rejection never consumed it')
end)

t.test('ConfirmHandlerDownDefense: silently tolerates IsBiteHoldEngaged being entirely undefined (soft dependency)', function()
    local f = newDefenseFixture({ provideIsBiteHoldEngaged = false })
    t.isNil(f.env.IsBiteHoldEngaged)
    f.fireTrigger(false, 5000, 6000)
    f.runConfirmCommand() -- must not error
    t.equals(#f.serverEvents, 1)
end)

t.test('ConfirmHandlerDownDefense: a suggested target not currently resolvable (ResolveNetworkEntity returns nil -- not streamed in) falls back to no_hostile_detected, no server event', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 6000)
    f.setNetIdResolvable(6000, false)
    f.runConfirmCommand()
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('defense.no_hostile_detected'))
    t.equals(#f.serverEvents, 0)
end)

t.test('ConfirmHandlerDownDefense: no suggested target at all never even calls ResolveNetworkEntity, and falls back to no_hostile_detected', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, nil)
    f.env.ResolveNetworkEntity = function() error('must not be called when there is no suggested target at all') end
    f.runConfirmCommand()
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('defense.no_hostile_detected'))
end)

t.test('PURE CONSUMER: a bite confirm fires the RAW requestBiteHold server event, never client/combat.lua own RequestBiteHold wrapper (entirely absent from this sandbox)', function()
    local f = newDefenseFixture()
    t.isNil(f.env.RequestBiteHold)
    t.isNil(f.env.RequestTakedown)
    f.fireTrigger(false, 5000, 6000)
    f.runConfirmCommand() -- default actionType == 'bite'
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:requestBiteHold')
    t.equals(f.serverEvents[1].args[1], 6000)
end)

t.test('an explicit takedown confirm fires the RAW requestTakedown server event', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 6000)
    f.env.ConfirmHandlerDownDefense('takedown')
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:requestTakedown')
    t.equals(f.serverEvents[1].args[1], 6000)
end)

t.test('an invalid actionType (neither bite nor takedown) silently falls back to bite, per this file own documented default', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 6000)
    f.env.ConfirmHandlerDownDefense('something-else')
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:requestBiteHold')
end)

t.test('a successful confirm CONSUMES the prompt -- a second press without a fresh trigger falls through to no_active_alert, never double-fires', function()
    local f = newDefenseFixture()
    f.fireTrigger(false, 5000, 6000)
    f.runConfirmCommand()
    t.equals(#f.serverEvents, 1)

    f.runConfirmCommand()
    t.equals(#f.serverEvents, 1, 'the second press must not have fired a second request')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('defense.no_active_alert'))
end)

-- ----------------------------------------------------------------------
-- SECTION E -- attacker-hint capture (gameEventTriggered).
-- ----------------------------------------------------------------------

t.test('gameEventTriggered: a genuine victim-is-me, valid-ped attacker reports reportHandlerAttacker with the right netId', function()
    local f = newDefenseFixture()
    f.setEntityExists(42, true)
    f.setEntityType(42, 1) -- ped
    f.fireGameEvent('CEventNetworkEntityDamage', { 1, 42 })
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:reportHandlerAttacker')
    t.equals(f.serverEvents[1].args[1], 42000)
end)

t.test('gameEventTriggered: ignores every non-CEventNetworkEntityDamage event name', function()
    local f = newDefenseFixture()
    f.fireGameEvent('CEventSomethingElse', { 1, 42 })
    t.equals(#f.serverEvents, 0)
end)

t.test('gameEventTriggered: ignores damage where the LOCAL player is not the victim', function()
    local f = newDefenseFixture()
    f.setEntityExists(42, true)
    f.setEntityType(42, 1)
    f.fireGameEvent('CEventNetworkEntityDamage', { 2, 42 }) -- victim (data[1]) is NOT PlayerPedId() (1)
    t.equals(#f.serverEvents, 0)
end)

t.test('gameEventTriggered: ignores a non-ped damage source (attacker == -1)', function()
    local f = newDefenseFixture()
    f.fireGameEvent('CEventNetworkEntityDamage', { 1, -1 })
    t.equals(#f.serverEvents, 0)
end)

t.test('gameEventTriggered: ignores attacker == victim (self-damage / same-entity source)', function()
    local f = newDefenseFixture()
    f.fireGameEvent('CEventNetworkEntityDamage', { 1, 1 })
    t.equals(#f.serverEvents, 0)
end)

t.test('gameEventTriggered: ignores an attacker handle that does not exist', function()
    local f = newDefenseFixture()
    f.setEntityExists(42, false)
    f.fireGameEvent('CEventNetworkEntityDamage', { 1, 42 })
    t.equals(#f.serverEvents, 0)
end)

t.test('gameEventTriggered: ignores a non-ped attacker entity type', function()
    local f = newDefenseFixture()
    f.setEntityExists(42, true)
    f.setEntityType(42, 3) -- e.g. an object, not a ped
    f.fireGameEvent('CEventNetworkEntityDamage', { 1, 42 })
    t.equals(#f.serverEvents, 0)
end)

t.test('gameEventTriggered: NEVER touches PendingDefensePrompt/HasFreshDefensePrompt -- this is a pure relay, not a second way to set a prompt', function()
    local f = newDefenseFixture()
    f.setEntityExists(42, true)
    f.setEntityType(42, 1)
    f.fireGameEvent('CEventNetworkEntityDamage', { 1, 42 })
    t.isFalse(f.env.HasFreshDefensePrompt(), 'an attacker report must never itself create a defense prompt')
end)

os.exit(t.summary())
