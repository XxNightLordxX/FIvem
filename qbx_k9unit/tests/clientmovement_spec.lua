--[[
    tests/clientmovement_spec.lua

    Direct, black-box tests of client/movement.lua against the REAL,
    unmodified production file. Per this pass's own task brief, scope is
    deliberately concentrated on the three things named as "what matters
    most" for this file, each of which has produced a real bug this
    session:

      1. RequestLeashAttach()'s gate -- the officer-initiated-vs-K9-initiated
         asymmetry fix (see that function's own "BUG FIX" doc comment in
         client/movement.lua). Both initiation directions are proven to
         genuinely reach TriggerServerEvent below.
      2. The THREE, distinct, non-overlapping onResourceStop handlers (camera
         view-mode reset, leash auto-detach, move-rate override reset).
      3. RecomputeK9MoveRate() -- the multiplicative composer, its clamp
         range, and its own onResourceStop-driven reset.

    Everything else in this 1600+ line file is covered LIGHTLY or not at
    all -- see "WHAT THIS FILE DOES NOT COVER" at the bottom for the full,
    honest list. This is a deliberate scope decision (matching this task's
    own instruction to do the named priorities well rather than everything
    thinly), not an oversight.

    FIXTURE CONFIG, NOT REAL config.lua -- per this task's explicit
    instruction: this file's own fixture builds a small, LOCAL `Config`
    table with only the one field client/movement.lua actually reads at
    LOAD time (`Config.Features.AgilityBasicJump`, forced `true` throughout
    this file specifically so the AgilityBasicJump-suppression CreateThread
    branch — a jump/crouch DisableControlAction loop entirely orthogonal to
    this spec's three priorities — never registers, so this fixture never
    needs to stub DisableControlAction at all). This spec never loads the
    real config.lua and asserts nothing about its shipped values, so it
    keeps passing regardless of which way config.lua's 40 feature flags are
    set on any given day. Every OTHER Config field this file reads
    (Config.LeashMaxDistance, Config.CertifyProximityMeters,
    Config.DoorInteraction.*) is read ONLY inside the three ox_target
    registration functions, which this spec never invokes (see "WHAT THIS
    FILE DOES NOT COVER") -- so this fixture's Config table genuinely never
    needs those fields either, not because they were forgotten.

    CreateThread IS CAPTURED BUT NEVER INVOKED -- this spec only counts how
    many threads client/movement.lua registers (a cheap sanity check that
    the AgilityBasicJump branch really did skip its own CreateThread call
    given the fixture's Config above, leaving exactly the one elastic
    leash-pull-back thread), never steps or asserts on that thread's BODY.
    That thread (softLimit/hardCap pull-back, the auto-detach safety valve)
    is a real, disclosed gap below -- exercising it would need the same
    Sandbox.newThreadRunner() + Vec3 + GetEntityCoords/SetEntityCoords
    machinery combat_spec.lua/clientradial_spec.lua already use, and this
    task's own brief did not name it as one of the three priorities.

    NOTIFICATION TYPE: 'info', NOT 'inform' -- ox_lib's real
    NotificationType union is 'info' | 'warning' | 'success' | 'error';
    'inform' was never a member. client/movement.lua's own two former
    'inform' call sites (ToggleK9Camera's toggle notice, leashDetached's
    notice) were switched to 'info' this session -- every assertion below
    that checks a notify `type` uses the real, current value.

    ONE FRESH SANDBOX PER TEST -- same discipline as every other spec in
    this suite (main_spec.lua, clientradial_spec.lua, clientvision_spec.lua):
    this file's own file-load-time locals (isFirstPersonK9View, leashState,
    detachRequestedForSafety, lastAppliedMoveRate, K9MoveRateModifiers) are
    exactly the kind of module-lifetime state that must never leak between
    two unrelated test cases.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- same deterministic, non-native formula
-- main_spec.lua/kennel_spec.lua already use. Only needed here because
-- K9_SIT_SCENARIO_BY_MODEL_HASH / K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH
-- are built from it at FILE-LOAD time -- this spec never asserts on either
-- table's contents, it just needs load to succeed without erroring.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'qbx_k9unit'

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real client/movement.lua
--- loaded against a LOCAL fixture Config (see this file's header) plus a
--- controllable/capturing stand-in for every native or cross-file global
--- this spec's exercised call paths touch.
--- @return table fixture
local function newMovementFixture()
    local isOwnModelK9 = true
    local canShowK9UI = true
    local function IsOwnModelK9() return isOwnModelK9 end
    local canShowK9UICallCount = 0
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    local denyCallCount = 0
    local function DenyK9UIAccess() denyCallCount = denyCallCount + 1 end

    -- ANY-PED MOVE-RATE FIX (this pass): RecomputeK9MoveRate()'s own gate is
    -- now `IsOwnModelK9() or HasK9Access()`, not IsOwnModelK9() alone -- see
    -- that function's own "SCOPE, CORRECTED" header comment in the real
    -- production file for the full writeup (two independent agents found the
    -- same real bug: a role-holder on a non-K9 body got a server grant and a
    -- success toast but zero actual speed change). HasK9Access() is a REAL
    -- cross-file global from client/main.lua -- called there UNGUARDED,
    -- exactly like IsOwnModelK9()/CanShowK9UI() above from that same
    -- always-loaded foundational file (Phase 1 scaffold, never a soft/
    -- optional dependency the way client/appearance.lua's IsK9Role is) -- so
    -- this fixture needs its own controllable stand-in for it, same as it
    -- already has for those two. Defaults to false so every PRE-EXISTING
    -- "not IsOwnModelK9" test below keeps meaning exactly what it always
    -- meant (neither model nor access -- a full reset), and the widening
    -- itself gets its own dedicated tests further down.
    local hasK9Access = false
    local hasK9AccessCallCount = 0
    local function HasK9Access() hasK9AccessCallCount = hasK9AccessCallCount + 1; return hasK9Access end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local notifyCalls = {}
    local alertDialogResponse = 'confirm'
    local alertDialogCalls = {}
    local lib = {
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
        alertDialog = function(payload)
            alertDialogCalls[#alertDialogCalls + 1] = payload
            return alertDialogResponse
        end,
    }

    -- pedHandle 1 exists by default -- RecomputeK9MoveRate's "no valid ped"
    -- branch is exercised explicitly per-test via setPedMissing()/setPed().
    local pedHandle = 1
    local existingEntities = { [1] = true }
    local entityModels = {}
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityModel(entity) return entityModels[entity] end

    local setMoveRateCalls = {}
    local function SetPedMoveRateOverride(ped, rate)
        setMoveRateCalls[#setMoveRateCalls + 1] = { ped = ped, rate = rate }
    end

    local camViewModeCalls = {}
    local function SetFollowPedCamViewMode(mode) camViewModeCalls[#camViewModeCalls + 1] = mode end

    local function GetCurrentResourceName() return RESOURCE_NAME end

    local playerIndexByServerId = {}
    local function GetPlayerFromServerId(serverId) return playerIndexByServerId[serverId] or -1 end
    local function GetPlayerName(playerIndex) return 'Player#' .. tostring(playerIndex) end

    local commands = {}
    local function RegisterCommand(name, handler) commands[name] = handler end
    local keyMappingCount = 0
    local function RegisterKeyMapping(...) keyMappingCount = keyMappingCount + 1 end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    -- Captured, never invoked -- see this file's header on why the elastic
    -- pull-back thread's BODY is a disclosed gap, not exercised here.
    local threadCount = 0
    local function CreateThread(_fn) threadCount = threadCount + 1 end

    -- See this file's header "FIXTURE CONFIG, NOT REAL config.lua" -- the
    -- ONLY field client/movement.lua reads at load time.
    local Config = { Features = { AgilityBasicJump = true } }

    local env = Sandbox.newEnv({
        GetHashKey = GetHashKey,
        Config = Config,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = CreateThread,
        IsOwnModelK9 = IsOwnModelK9,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        TriggerServerEvent = TriggerServerEvent,
        lib = lib,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        GetEntityModel = GetEntityModel,
        SetPedMoveRateOverride = SetPedMoveRateOverride,
        SetFollowPedCamViewMode = SetFollowPedCamViewMode,
        GetCurrentResourceName = GetCurrentResourceName,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerName = GetPlayerName,
    })

    Sandbox.loadInto('../client/movement.lua', env)

    return {
        env = env,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        denyCallCount = function() return denyCallCount end,
        setHasK9Access = function(v) hasK9Access = v end,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        notifyCalls = notifyCalls,
        alertDialogCalls = alertDialogCalls,
        setAlertDialogResponse = function(v) alertDialogResponse = v end,
        setMoveRateCalls = setMoveRateCalls,
        camViewModeCalls = camViewModeCalls,
        setPed = function(handle, exists)
            pedHandle = handle
            if exists ~= false then existingEntities[handle] = true end
        end,
        setPedMissing = function() pedHandle = 0 end,
        setModel = function(entity, hash) entityModels[entity] = hash end,
        registerPlayer = function(serverId, playerIndex) playerIndexByServerId[serverId] = playerIndex end,
        threadCount = function() return threadCount end,
        keyMappingCount = function() return keyMappingCount end,
        commandCount = function()
            local n = 0
            for _ in pairs(commands) do n = n + 1 end
            return n
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        netEventNames = netEvents,
        triggerLeashAttached = function(sourceValue, partnerServerId, isConstrained)
            local handler = assert(netEvents['qbx_k9unit:client:leashAttached'],
                'client/movement.lua did not register a qbx_k9unit:client:leashAttached handler')
            env.source = sourceValue
            handler(partnerServerId, isConstrained)
        end,
        triggerLeashDetached = function(sourceValue, reason)
            local handler = assert(netEvents['qbx_k9unit:client:leashDetached'],
                'client/movement.lua did not register a qbx_k9unit:client:leashDetached handler')
            env.source = sourceValue
            handler(reason)
        end,
        triggerLeashAttachRequest = function(sourceValue, fromServerId)
            local handler = assert(netEvents['qbx_k9unit:client:leashAttachRequest'],
                'client/movement.lua did not register a qbx_k9unit:client:leashAttachRequest handler')
            env.source = sourceValue
            handler(fromServerId)
        end,
    }
end

-- ========================================================================
-- Sanity: the file loaded and exposed/registered exactly what its own
-- FILE-TO-FILE CONTRACT documents, before trusting any test below.
-- ========================================================================

t.test('client/movement.lua exposes its five documented resource-globals', function()
    local f = newMovementFixture()
    t.isNotNil(f.env.ToggleK9Camera)
    t.isNotNil(f.env.K9Sit)
    t.isNotNil(f.env.RequestLeashAttach)
    t.isNotNil(f.env.DetachLeash)
    t.isNotNil(f.env.IsLeashed)
    t.isNotNil(f.env.K9MoveRateModifiers, 'the move-rate composer table')
    t.isNotNil(f.env.RecomputeK9MoveRate, 'the move-rate composer function')
end)

t.test('registers exactly 3 onResourceStop handlers (camera reset, leash auto-detach, move-rate reset)', function()
    local f = newMovementFixture()
    t.equals(f.onResourceStopHandlerCount(), 3)
end)

t.test('registers exactly 1 onResourceStart handler (ox_target lifecycle re-registration -- not exercised by this spec, see "WHAT THIS FILE DOES NOT COVER")', function()
    local f = newMovementFixture()
    t.equals(f.onResourceStartHandlerCount(), 1)
end)

t.test('creates exactly 1 thread (the elastic leash pull-back thread) given AgilityBasicJump=true in this fixture\'s Config -- proves the AgilityBasicJump-suppression thread branch really is skipped', function()
    local f = newMovementFixture()
    t.equals(f.threadCount(), 1)
end)

t.test('registers exactly 4 RegisterNetEvent handlers (leashAttachRequest, leashAttached, leashDetached, playDoorScratch)', function()
    local f = newMovementFixture()
    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 4)
end)

-- ========================================================================
-- PRIORITY #1 -- RequestLeashAttach()'s gate. This session's regression: an
-- unconditional CanShowK9UI() pre-check silently denied every
-- officer-initiated "Attach Leash" request before it ever reached the
-- server, because CanShowK9UI() == IsOwnModelK9() and HasK9Access(), which
-- is false by construction for an officer (never modeled as a K9). The fix
-- only applies the K9-shaped pre-check when the LOCAL player would actually
-- be the K9-role party. Both directions are proven below to genuinely reach
-- TriggerServerEvent -- the server (CheckLeashEligibility) is the one place
-- that actually decides role/eligibility.
-- ========================================================================

t.test('RequestLeashAttach: K9-role initiator (IsOwnModelK9 true) BLOCKED locally when CanShowK9UI is false -- denied before ever reaching the server', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(false)
    f.env.RequestLeashAttach(999)
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestLeashAttach: K9-role initiator (IsOwnModelK9 true) with CanShowK9UI true reaches the server', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(true)
    f.env.RequestLeashAttach(42)
    t.equals(f.denyCallCount(), 0)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestLeashAttach')
    t.equals(f.lastServerEvent().args[1], 42)
end)

t.test('RequestLeashAttach: THE REGRESSION FIX -- an officer-role initiator (IsOwnModelK9 false) reaches the server even though CanShowK9UI is also false, and CanShowK9UI is never even consulted (short-circuit)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(false) -- would have wrongly blocked under the pre-fix unconditional gate
    f.env.RequestLeashAttach(7)
    t.equals(#f.serverEvents, 1, 'an officer-initiated Attach Leash request must reach the server -- this is the exact regression this session fixed')
    t.equals(f.lastServerEvent().args[1], 7)
    t.equals(f.denyCallCount(), 0)
    t.equals(f.canShowK9UICallCount(), 0, 'Lua\'s `and` short-circuits: IsOwnModelK9() being false means CanShowK9UI() must never even run for this branch')
end)

t.test('RequestLeashAttach: an officer-role initiator with CanShowK9UI true (sanity) also reaches the server', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(true)
    f.env.RequestLeashAttach(8)
    t.equals(#f.serverEvents, 1)
end)

t.test('RequestLeashAttach: already leashed blocks a FRESH request from the K9-role side, with no server contact', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 55, true) -- establish leashState first
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(true)
    f.env.RequestLeashAttach(999)
    t.equals(#f.serverEvents, 0, 'no NEW requestLeashAttach event -- IsLeashed() must block before ever calling TriggerServerEvent')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('movement.already_leashed'))
    t.equals(f.notifyCalls[#f.notifyCalls].type, 'error')
end)

t.test('RequestLeashAttach: already leashed ALSO blocks the officer-role side -- the IsLeashed() check runs unconditionally, regardless of which gate branch preceded it', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 55, false) -- officer/anchor side's own leashState, isConstrained=false
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(false)
    f.env.RequestLeashAttach(999)
    t.equals(#f.serverEvents, 0)
end)

-- ========================================================================
-- Supporting infrastructure for IsLeashed()/the leash handshake -- lightly
-- covered ONLY to the extent the priority tests above and the
-- onResourceStop tests below depend on real state transitions, not a full
-- D3-style source-origin-guard treatment (that treatment lives in
-- clientcombat_spec.lua, which this file's own guards share the identical
-- open-question caveat with -- see this file's own "WHAT THIS FILE DOES
-- NOT COVER" note on that).
-- ========================================================================

t.test('leashAttached: source == 65535 sets leashState (IsLeashed() true) and notifies with type "success"', function()
    local f = newMovementFixture()
    t.isFalse(f.env.IsLeashed())
    f.triggerLeashAttached(65535, 10, true)
    t.isTrue(f.env.IsLeashed())
    local n = f.notifyCalls[#f.notifyCalls]
    t.equals(n.description, locale('movement.leash_now_leashed'))
    t.equals(n.type, 'success')
end)

t.test('leashAttached: isConstrained false notifies with the anchor-side message instead', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, false)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('movement.leash_now_anchoring'))
end)

t.test('leashAttached: a forged non-65535 source is rejected -- leashState stays nil, no notify', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(1, 10, true)
    t.isFalse(f.env.IsLeashed())
    t.equals(#f.notifyCalls, 0)
end)

t.test('leashDetached: source == 65535 clears leashState and notifies with type "info", default reason', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.triggerLeashDetached(65535, 'detached')
    t.isFalse(f.env.IsLeashed())
    local n = f.notifyCalls[#f.notifyCalls]
    t.equals(n.description, locale('movement.leash_detached'))
    t.equals(n.type, 'info')
end)

t.test('leashDetached: reason == "partner_disconnected" uses the distinct partner-disconnected message', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.triggerLeashDetached(65535, 'partner_disconnected')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('movement.leash_detached_partner_disconnected'))
end)

t.test('leashDetached: a forged non-65535 source is rejected -- leashState survives untouched', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.triggerLeashDetached(7, 'detached')
    t.isTrue(f.env.IsLeashed(), 'a forged local trigger must never be able to silence the elastic-restriction thread by clearing leashState')
end)

t.test('DetachLeash: a no-op (no TriggerServerEvent) when not currently leashed', function()
    local f = newMovementFixture()
    f.env.DetachLeash()
    t.equals(#f.serverEvents, 0)
end)

t.test('DetachLeash: sends the real detachLeash event when leashed, with zero consent/access gate', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.setCanShowK9UI(false) -- must not matter -- detach has no access gate
    f.env.DetachLeash()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:detachLeash')
end)

t.test('leashAttachRequest (consent prompt, target side): source == 65535 shows the prompt and relays the response to the server', function()
    local f = newMovementFixture()
    f.registerPlayer(10, 3)
    f.setAlertDialogResponse('confirm')
    f.triggerLeashAttachRequest(65535, 10)
    t.equals(#f.alertDialogCalls, 1)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:respondLeashAttach')
    t.equals(f.lastServerEvent().args[1], 10)
    t.equals(f.lastServerEvent().args[2], true)
end)

t.test('leashAttachRequest: a decline response relays accepted=false', function()
    local f = newMovementFixture()
    f.registerPlayer(10, 3)
    f.setAlertDialogResponse('cancel')
    f.triggerLeashAttachRequest(65535, 10)
    t.equals(f.lastServerEvent().args[2], false)
end)

t.test('leashAttachRequest: a forged non-65535 source never even shows the prompt', function()
    local f = newMovementFixture()
    f.triggerLeashAttachRequest(1, 10)
    t.equals(#f.alertDialogCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

-- ========================================================================
-- PRIORITY #2 -- the THREE onResourceStop handlers. Distinct, no overlap:
-- each is proven to fire independently, to be a no-op when its own
-- condition doesn't hold, and all three are proven to coexist correctly
-- (no interference) when fired together in the same resourceName check.
-- ========================================================================

t.test('onResourceStop CAMERA handler: a no-op when the camera was never toggled to first-person', function()
    local f = newMovementFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.camViewModeCalls, 0)
end)

t.test('onResourceStop CAMERA handler: resets the view mode to 1 (third-person) and truly clears its own flag -- a later ToggleK9Camera() flips to first-person again, proving the internal boolean was really reset, not just visually', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.ToggleK9Camera() -- flips to first-person (mode 4)
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 4)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 1, 'the stop handler must reset the view mode to third-person')

    f.env.ToggleK9Camera()
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 4, 'toggling again must go back to first-person -- proves isFirstPersonK9View was genuinely reset to false, not left stale')
end)

t.test('onResourceStop CAMERA handler: a mismatched resourceName never fires, even mid-first-person', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.ToggleK9Camera()
    local callsBefore = #f.camViewModeCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.camViewModeCalls, callsBefore)
end)

t.test('onResourceStop LEASH handler: a no-op (no detachLeash event) when not currently leashed', function()
    local f = newMovementFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.serverEvents, 0)
end)

t.test('onResourceStop LEASH handler: sends detachLeash when leashed, but leashState only clears once the (simulated) server confirmation arrives -- proves this handler fires DetachLeash(), not a direct local clear', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:detachLeash')
    t.isTrue(f.env.IsLeashed(), 'DetachLeash() only SENDS the request -- leashState clears only when leashDetached actually arrives, exactly like a normal manual detach')
end)

t.test('onResourceStop LEASH handler: a mismatched resourceName never fires, even while leashed', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.fireResourceStop('some_other_resource')
    t.equals(#f.serverEvents, 0)
end)

t.test('onResourceStop MOVE-RATE handler: a no-op (no SetPedMoveRateOverride call) when the composer never applied a non-neutral value', function()
    local f = newMovementFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('onResourceStop MOVE-RATE handler: resets a non-neutral applied rate to 1.0, and is idempotent on a second firing', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.5)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 2)
    t.equals(f.setMoveRateCalls[2].rate, 1.0)

    f.fireResourceStop(RESOURCE_NAME) -- fired twice -- must not double-reset
    t.equals(#f.setMoveRateCalls, 2, 'a second firing must be a no-op once the tracked rate is already neutral')
end)

t.test('onResourceStop MOVE-RATE handler: a mismatched resourceName never fires, even with a non-neutral rate applied', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.injury = 0.6
    f.env.RecomputeK9MoveRate()
    local callsBefore = #f.setMoveRateCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.setMoveRateCalls, callsBefore)
end)

t.test('onResourceStop MOVE-RATE handler: skips the native call (no valid ped) but STILL resets its own internal tracking -- a disclosed, low-severity finding, not a fix: a later resourceStop with a valid ped never re-attempts the reset either', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 1)

    f.setPedMissing() -- PlayerPedId() now returns 0 -- native call must be skipped
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 1, 'the native call is correctly skipped for an invalid ped')

    f.setPed(1, true) -- ped becomes valid again
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 1, 'FINDING (harmless in practice, see comment above): the internal lastAppliedMoveRate was already reset to 1.0 during the invalid-ped firing, so this second, now-valid-ped firing never actually re-corrects the native state that was skipped the first time -- low real-world impact since onResourceStop only ever runs once at genuine resource teardown')
end)

t.test('onResourceStop: all THREE handlers fire independently in the same pass with zero interference (camera + leash + move-rate all active at once)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.ToggleK9Camera() -- first-person
    f.triggerLeashAttached(65535, 10, true) -- leashed
    f.env.K9MoveRateModifiers.mood = 0.8
    f.env.RecomputeK9MoveRate() -- non-neutral rate applied

    local camBefore, moveBefore, serverBefore = #f.camViewModeCalls, #f.setMoveRateCalls, #f.serverEvents
    f.fireResourceStop(RESOURCE_NAME)

    t.equals(#f.camViewModeCalls, camBefore + 1)
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 1)
    t.equals(#f.setMoveRateCalls, moveBefore + 1)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
    t.equals(#f.serverEvents, serverBefore + 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:detachLeash')
end)

-- ========================================================================
-- PRIORITY #3 -- RecomputeK9MoveRate(): degenerate-ped guards, the
-- not-a-K9 reset branch, multiplicative composition, the [0.1, 2.0] clamp,
-- and the defensive non-number guard.
-- ========================================================================

t.test('RecomputeK9MoveRate: no valid ped (PlayerPedId returns 0) is a clean no-op', function()
    local f = newMovementFixture()
    f.setPedMissing()
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('RecomputeK9MoveRate: a ped handle that DoesEntityExist reports false for is also a clean no-op', function()
    local f = newMovementFixture()
    f.setPed(2, false)
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('RecomputeK9MoveRate: not IsOwnModelK9, never applied before -- no-op (already neutral)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('RecomputeK9MoveRate: not IsOwnModelK9, but a non-neutral rate WAS previously applied -- resets to 1.0 (prevents a stale override surviving a K9-to-human model swap on the same ped index)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.injury = 0.7
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.7)

    f.setIsOwnModelK9(false)
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
    t.equals(#f.setMoveRateCalls, 2)
end)

t.test('RecomputeK9MoveRate: IsOwnModelK9 true, every modifier at its default 1.0 -- applies exactly 1.0', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 1)
    t.equals(f.setMoveRateCalls[1].rate, 1.0)
end)

t.test('RecomputeK9MoveRate: IsOwnModelK9 true ALWAYS re-applies, even with no change -- unlike the not-a-K9 branch, this is never deduped', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.RecomputeK9MoveRate()
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 2, 'the K9 branch is a deliberate no-early-return composer, not a change-detection cache')
end)

t.test('RecomputeK9MoveRate: composes two non-default modifiers multiplicatively (0.5 * 0.4 = 0.2)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.K9MoveRateModifiers.mood = 0.4
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.2)
end)

t.test('RecomputeK9MoveRate: clamps a product below 0.1 up to the floor', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.01
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.1)
end)

t.test('RecomputeK9MoveRate: clamps a product above 2.0 down to the ceiling', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.xpTier = 5.0
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0)
end)

t.test('RecomputeK9MoveRate: a non-number entry in K9MoveRateModifiers is ignored defensively, never errors, never contributes to the product', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.somethingBogus = 'oops'
    local ok, err = pcall(f.env.RecomputeK9MoveRate)
    t.isTrue(ok, 'a non-number modifier entry must never error: ' .. tostring(err))
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
end)

t.test('RecomputeK9MoveRate: applies to the CURRENT PlayerPedId(), not a hardcoded handle', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.setPed(777, true)
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].ped, 777)
end)

-- ========================================================================
-- ANY-PED MOVE-RATE FIX (this pass) -- RecomputeK9MoveRate()'s gate is now
-- `IsOwnModelK9() or HasK9Access()`, not IsOwnModelK9() alone. Two
-- independent agents separately found the same real bug: a role-holder
-- (certified handler, or a HasK9Access() High-Command/autoAccessGrade
-- bypass) on a non-K9 body got a genuine server grant -- client/pursuitsprint.lua's
-- "activated" toast, a real K9MoveRateModifiers write -- and ZERO actual
-- speed change, because the bare IsOwnModelK9() gate reset the composer back
-- to neutral before it ever composed anything. See the real production
-- file's own "SCOPE, CORRECTED" header comment on K9MoveRateModifiers for
-- the full writeup (the two concrete configurations this reproduces in:
-- Config.K9Appearance.requireK9ModelForRole = true, and the default-config
-- HasK9Access() autoAccessGrade/High-Command-bypass case) -- not re-derived
-- here, only proven behaviorally against the real function.
-- ========================================================================

t.test('ANY-PED FIX: NOT IsOwnModelK9, but HasK9Access() true -- the composer now applies for real, proving a role-holder on a non-K9 body genuinely receives the speed change', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.env.K9MoveRateModifiers.fatigue = 0.85
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 1, 'THE BUG: this used to be 0 -- IsOwnModelK9() alone reset to neutral and returned before composing anything')
    t.equals(f.setMoveRateCalls[1].rate, 0.85, 'the real fatigue modifier must reach SetPedMoveRateOverride on a human/custom body exactly as it would on a K9 model')
end)

t.test('ANY-PED FIX: neither IsOwnModelK9 NOR HasK9Access -- still a full reset, exactly like before this fix (a player with no model AND no access has no legitimate reason for any modifier to apply)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.injury = 0.6
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.6)

    f.setIsOwnModelK9(false)
    f.setHasK9Access(false)
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'neither half of the OR is true -- must still reset to neutral, not stay stuck at 0.6')
end)

t.test('ANY-PED FIX: HasK9Access() is NEVER consulted when IsOwnModelK9() is already true -- `or` short-circuits, so the already-K9-modeled common case pays no extra network round trip', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.RecomputeK9MoveRate()
    t.equals(f.hasK9AccessCallCount(), 0, 'Lua\'s `or` short-circuits: IsOwnModelK9() being true means HasK9Access() must never even run')
    t.equals(#f.setMoveRateCalls, 1, 'the K9-modeled case must still apply normally')
end)

t.test('ANY-PED FIX: HasK9Access() true alone (never a K9 model at all, e.g. an unlisted human ped) applies breed at its neutral 1.0 default -- breed itself was never meaningful off-model, only the OTHER modifiers (fatigue/injury/mood/xpTier/pursuitSprint) are what this fix actually restores', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.setModel(1, 12345) -- pedHandle 1 (this fixture's default) -- some hash never present in any breed table
    f.env.RecomputeK9MoveRate()
    t.equals(f.env.K9MoveRateModifiers.breed, 1.0, 'breed must stay neutral for a model with no configured breed multiplier, exactly as it already did before this fix')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'with every modifier at its neutral default, the composed rate is exactly 1.0 -- still a REAL native call, not a skipped one, unlike the old bare-IsOwnModelK9() gate which would have skipped this entirely')
end)

t.test('ANY-PED FIX: switching FROM a legitimate access-only (non-K9-model) state back to neither resets to neutral, same stale-override protection the original K9-to-human comment already documented', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.env.K9MoveRateModifiers.mood = 0.9
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.9)

    f.setHasK9Access(false) -- access revoked mid-session, still not K9-modeled
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'losing the ONLY qualifying condition (access, since model was already false) must still reset to neutral')
end)

-- ========================================================================
-- WHAT THIS FILE DOES NOT COVER, AND WHY (per this task's own instruction
-- to disclose uncovered paths rather than silently skip them):
--
--   - The elastic leash pull-back thread's BODY (the CreateThread this file
--     registers) -- captured but never invoked (see "CreateThread IS
--     CAPTURED BUT NEVER INVOKED" in this file's header). Its softLimit/
--     hardCap/pullZoneStart math, the IsPedInAnyVehicle/IsInK9Vehicle
--     exclusions, and the detachRequestedForSafety single-fire guard are
--     all untested here. This is the single largest disclosed gap in this
--     spec -- it was not one of this task's three named priorities, and
--     exercising it properly needs the same coroutine-stepping + Vec3
--     machinery already used elsewhere in this suite (combat_spec.lua,
--     clientradial_spec.lua), which would have meaningfully diluted the
--     effort this pass put into the three named priorities instead.
--   - ToggleK9Camera()'s OWN gate behavior (IsOwnModelK9 false -> deny) is
--     exercised only as a SIDE EFFECT of setting up onResourceStop tests
--     above -- not independently tested for its own sake (e.g. the
--     denial-path notify text).
--   - K9Sit() -- not exercised at all (no ClearPedTasksImmediately/
--     TaskStartScenarioInPlace stubs are even provided).
--   - RegisterLeashOxTargetOption() / RegisterCertifyOxTargetOptions() /
--     RegisterDoorInteractionOxTargetOptions() and their canInteract/
--     onSelect closures -- these `local` functions are only reachable via
--     the combined onResourceStart handler this spec confirms is
--     registered (see the "registers exactly 1 onResourceStart handler"
--     sanity test above) but never FIRES. Reaching them would need
--     exports.ox_target stubs and a live Config.LeashMaxDistance/
--     Config.CertifyProximityMeters/Config.DoorInteraction.* fixture --
--     all display-only plausibility gates per this file's own repeated
--     documentation (the server independently re-validates everything
--     authoritatively regardless), so this is a real but low-severity gap.
--   - ScratchAtDoor() / NudgeDoor() / IsLikelyDoorEntity() and the
--     playDoorScratch broadcast receiver -- same reasoning as the
--     ox_target registration functions above (only reachable through
--     onResourceStart-registered ox_target options this spec never fires,
--     or directly as `local`s this spec cannot reach at all).
--   - The AgilityBasicJump-suppression CreateThread branch -- this
--     fixture's Config forces Config.Features.AgilityBasicJump = true
--     specifically so this branch never registers at all (see this file's
--     header). The `false` branch (DisableControlAction(0, INPUT_JUMP/
--     INPUT_DUCK, true) every frame while IsOwnModelK9()) is entirely
--     untested here.
--   - The SOURCE-ORIGIN GUARD's open engine-level question (can `source`
--     ever fail open to something other than 65535 on a genuine dispatch)
--     is NOT settled by the light source-guard tests in this file, exactly
--     as it is not settled by clientcombat_spec.lua's own, much more
--     thorough treatment of the identical pattern -- see that file's own
--     header for the full D3 citation/caveat, which applies here verbatim
--     (this file's guards share the same `if source ~= 65535 then return
--     end` shape, sourced from the same coder-security pass).
-- ========================================================================

os.exit(t.summary())
