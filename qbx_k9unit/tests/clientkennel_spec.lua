--[[
    tests/clientkennel_spec.lua

    Direct, black-box tests of client/kennel.lua against the REAL,
    unmodified production file -- the client half of
    Config.Features.DeployableKennel (server/kennel.lua's own header is the
    authoritative contract). One of six client files this pass writes a
    spec for (see tests/vehiclecombatguard_spec.lua's own header, whose
    disclosed gap this batch exists to close).

    STYLE: follows tests/clientcombat_spec.lua/tests/clientmovement_spec.lua
    -- fresh sandbox per test, a local fixture Config (never the real
    config.lua, so this spec keeps passing regardless of how config.lua's
    other 40 feature flags are set on any given day), K9Compat + a real
    ox_target adapter loaded exactly the way
    tests/vehiclecombatguard_spec.lua already established for a client file
    that routes its ox_target registration through
    K9Compat.Get('target') -- never a hand-written fake translation layer,
    which would just assert against itself.

    NET-EVENT DISPATCH RUNS INSIDE A FRESH COROUTINE, mirroring
    tests/clientagility_spec.lua's `runVault()`: `deployKennelAt`'s own
    LoadModelWithTimeout can call `Wait(50)` in a real poll loop (mirrors
    the real RequestModel/HasModelLoaded pattern), and FiveM's own
    RegisterNetEvent handlers already run inside their own coroutine
    context in production -- exactly what makes that Wait() call legal at
    all. `dispatchNetEvent()` below wraps every captured handler invocation
    in `coroutine.create`/`coroutine.resume`, draining it to completion
    regardless of how many times (zero or more) it yields, so the SAME
    helper works uniformly whether or not a given test's model-load
    behavior ever actually yields.

    TWO REAL DEFECTS FOUND WHILE WRITING THIS SPEC, DISCLOSED HERE AND
    REPORTED TO MAIN RATHER THAN WORKED AROUND (per this task's own
    instruction) -- NEITHER IS FIXED BY THIS SPEC, both are PINNED as
    CURRENT, actual behavior so this file stays green against the real,
    unmodified production code:

    1. NOT GENUINELY INERT WITH THE FEATURE OFF. Unlike
       client/partnership.lua, client/propattachment.lua and
       client/fetch.lua (each of which has a real top-of-file
       `if not Config.Features.X then return end` gate -- confirmed by
       reading all three), client/kennel.lua has NO such gate. With
       Config.Features.DeployableKennel = false, this file still calls
       RegisterCommand('k9deploykennel', ...), RegisterNetEvent(...) for
       both 'qbx_k9unit:client:deployKennelAt' and
       'qbx_k9unit:client:removeKennel', and AddEventHandler(...) for both
       'onResourceStart' and 'onResourceStop' -- every one of those
       registrations happens UNCONDITIONALLY at file-load time; only the
       WORK each one does is internally gated. client/partnership.lua's own
       header calls this exact shape (unconditional registration regardless
       of a file's own feature flags) "the exact gap a red-team pass just
       found in client/combat.lua" and documents client/kennel.lua's
       PER-HANDLER gating as the thing that gate was contrasted against --
       but per-handler gating alone does not make the file genuinely inert
       at the REGISTRATION level the way this task's own brief asks for
       ("no threads started, no events registered"). The "feature off"
       tests below pin the file's CURRENT, real behavior (registration
       happens regardless; only the internal WORK no-ops) rather than
       asserting the stronger claim and going red against real production
       code.
    2. NO STALE-KENNEL GUARD ON deployKennelAt (an asymmetry with
       client/propattachment.lua's own attachK9Prop, which DOES have one --
       see that file's "STALE-VEST GUARD" comment). If
       'qbx_k9unit:client:deployKennelAt' is ever dispatched to the same
       client TWICE before the first kennel's netId is cleared (a
       server-side TOCTOU on the one-kennel-per-citizenid check, a retried/
       duplicated event, or -- the residual D3 risk every SOURCE-ORIGIN
       GUARD in this codebase carries -- a forged local trigger), the
       second invocation creates an entirely new kennel object and
       overwrites `myKennelNetId` with the new netId, with no
       DeleteEntity() call against the FIRST kennel first. The first
       kennel's local handle is gone the instant the assignment happens --
       nothing in this file can ever clean it up again (not
       onResourceStop, which only ever knows about the CURRENT
       myKennelNetId). See the dedicated test below for the exact repro.
    ]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'qbx_k9unit'
local PRIMARY_MODEL = 'prop_dog_cage_01'
local FALLBACK_MODEL = 'prop_tennis_ball'

--- @param opts { deployableKennel: boolean? }?
--- @return table fixture
local function newKennelFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local canShowK9UICalls = 0
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local commands = {}
    local function RegisterCommand(name, handler, restricted)
        commands[#commands + 1] = { name = name, handler = handler, restricted = restricted }
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local threadCount = 0
    local function CreateThread(_fn) threadCount = threadCount + 1 end

    -- ---- model loading ----
    -- modelBehavior[hash] = 'loads' (default) | 'timeout' | 'invalid'
    local modelBehavior = {}
    local requestModelCalls, releaseModelCalls = {}, {}
    local printLines = {}
    local function IsModelValid(hash) return modelBehavior[hash] ~= 'invalid' end
    local function RequestModel(hash) requestModelCalls[#requestModelCalls + 1] = hash end
    local function HasModelLoaded(hash) return modelBehavior[hash] ~= 'timeout' end
    local function SetModelAsNoLongerNeeded(hash) releaseModelCalls[#releaseModelCalls + 1] = hash end
    local waitCalls = {}
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms; coroutine.yield() end

    -- ---- object lifecycle ----
    local objectSeq = 0
    local objectBehavior = {} -- default: real object, real ground placement
    local existingEntities = {}
    local entityModels = {}
    local createObjectCalls, deleteEntityCalls, freezeCalls, placeCalls = {}, {}, {}, {}
    local function CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag)
        objectSeq = objectSeq + 1
        local entity = objectSeq
        createObjectCalls[#createObjectCalls + 1] = { entity = entity, modelHash = modelHash, x = x, y = y, z = z }
        if objectBehavior.createFails then
            return 0
        end
        existingEntities[entity] = true
        entityModels[entity] = modelHash
        return entity
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityModel(entity) return entityModels[entity] end
    local function PlaceObjectOnGroundProperly(entity)
        placeCalls[#placeCalls + 1] = entity
        return not objectBehavior.groundFails
    end
    local function FreezeEntityPosition(entity, toggle) freezeCalls[#freezeCalls + 1] = { entity = entity, toggle = toggle } end
    local function DeleteEntity(entity)
        deleteEntityCalls[#deleteEntityCalls + 1] = entity
        existingEntities[entity] = nil
    end

    local netIdSeq = 0
    local netIdByEntity = {}
    local function NetworkGetNetworkIdFromEntity(entity)
        if not netIdByEntity[entity] then
            netIdSeq = netIdSeq + 1
            netIdByEntity[entity] = netIdSeq
        end
        return netIdByEntity[entity]
    end
    -- Direct, controllable stand-in for client/main.lua's cross-file
    -- ResolveNetworkEntity -- this spec tests client/kennel.lua, not
    -- client/main.lua's own resolve sequence (already covered elsewhere),
    -- so stubbing it directly (rather than reimplementing
    -- NetworkDoesEntityExistWithNetworkId/NetworkGetEntityFromNetworkId)
    -- matches this suite's own established convention (see
    -- tests/clientcombat_spec.lua's identical treatment of the same global).
    local function ResolveNetworkEntity(netId)
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    -- ---- K9Compat -- DIRECT stub, not the real shared/compat/core.lua +
    -- shared/compat/target.lua adapter pair. Real-adapter detection
    -- (K9Compat.Get) is lazy and gated behind Config.Compat.Systems.*/
    -- Config.Features.ResourceAutoDetect/Config.Compat.autoDetect, none of
    -- which this file's own local fixture Config below defines (loading the
    -- REAL config.lua just for those fields would coincidentally re-import
    -- config.lua's OWN Config.Features.DeployableKennel default and every
    -- other unrelated flag, exactly the drift risk this suite's "FIXTURE
    -- CONFIG, NOT REAL config.lua" convention exists to avoid -- see
    -- tests/clientcombat_spec.lua's header). client/kennel.lua's own
    -- interaction with K9Compat is exactly two calls
    -- (K9Compat.Get('target').AddModel(options), K9Compat.Redetect() +
    -- K9Compat.Which('target')) -- stubbing K9Compat directly here still
    -- exercises every bit of client/kennel.lua's OWN logic (the option
    -- table's name/icon/label/distance/canInteract/onSelect are all real,
    -- unmodified client/kennel.lua code reaching this stub) without
    -- re-testing the compat TRANSLATION layer itself, which is already
    -- covered by tests/compattarget_spec.lua/tests/compat_spec.lua.
    local addModelCalls = {}
    local redetectCallCount = 0
    local K9Compat = {
        Get = function(_system)
            return {
                AddModel = function(models, options) addModelCalls[#addModelCalls + 1] = { models = models, options = options } end,
            }
        end,
        Redetect = function() redetectCallCount = redetectCallCount + 1 end,
        Which = function(_system) return 'ox_target' end,
    }

    local config = {
        Features = { DeployableKennel = opts.deployableKennel ~= false },
        DeployableKennel = {
            propModel = PRIMARY_MODEL,
            fallbackPropModel = FALLBACK_MODEL,
            interactDistanceMeters = 2.5,
        },
    }

    local env = Sandbox.newEnv({
        Config = config,
        GetHashKey = GetHashKey,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CreateThread,
        IsModelValid = IsModelValid,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        Wait = Wait,
        CreateObject = CreateObject,
        DoesEntityExist = DoesEntityExist,
        GetEntityModel = GetEntityModel,
        PlaceObjectOnGroundProperly = PlaceObjectOnGroundProperly,
        FreezeEntityPosition = FreezeEntityPosition,
        DeleteEntity = DeleteEntity,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
        print = function(line) printLines[#printLines + 1] = line end,
        K9Compat = K9Compat,
    })

    Sandbox.loadInto('../client/kennel.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        commands = commands,
        netEventNames = netEvents,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEvents) do n = n + 1 end
            return n
        end,
        threadCount = function() return threadCount end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        addModelCalls = addModelCalls,
        redetectCallCount = function() return redetectCallCount end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICalls end,
        denyCallCount = function() return denyCalls end,
        setModelBehavior = function(modelName, behavior) modelBehavior[GetHashKey(modelName)] = behavior end,
        setObjectBehavior = function(t2) objectBehavior = t2 or {} end,
        requestModelCalls = requestModelCalls,
        releaseModelCalls = releaseModelCalls,
        createObjectCalls = createObjectCalls,
        deleteEntityCalls = deleteEntityCalls,
        freezeCalls = freezeCalls,
        placeCalls = placeCalls,
        waitCalls = waitCalls,
        printLines = printLines,
        setEntityMissing = function(entity) existingEntities[entity] = nil end,
        --- Registers a networked entity THIS handler did not itself create
        --- via deployKennelAt (e.g. some other feature's prop, or another
        --- player's real vehicle/ped) -- used only by the DEFENSE-IN-DEPTH
        --- MODEL CHECK test below, which needs a resolvable netId whose
        --- entity is deliberately NOT a configured kennel prop model.
        registerForeignEntity = function(netId, entity, modelHash)
            existingEntities[entity] = true
            entityModels[entity] = modelHash
            netIdByEntity[entity] = netId
        end,
        --- Runs a captured RegisterNetEvent handler to completion inside its
        --- own fresh coroutine -- see this file's header for why.
        dispatchNetEvent = function(eventName, sourceValue, ...)
            local handler = assert(netEvents[eventName], 'no handler registered for ' .. eventName)
            env.source = sourceValue
            local co = coroutine.create(handler)
            local ok, err = coroutine.resume(co, ...)
            if not ok then error('dispatchNetEvent(' .. eventName .. '): ' .. tostring(err)) end
            while coroutine.status(co) ~= 'dead' do
                ok, err = coroutine.resume(co)
                if not ok then error('dispatchNetEvent(' .. eventName .. ') mid-flight: ' .. tostring(err)) end
            end
        end,
    }
end

-- ========================================================================
-- FEATURE OFF -- pins CURRENT, real behavior (registration still happens;
-- see this file's header, disclosed defect #1). Deliberately NOT asserting
-- the stronger "genuinely inert" claim, which would be red against the real
-- production file.
-- ========================================================================

t.test('DISCLOSED FINDING: feature off still registers the command, both net events, and both onResourceStart/onResourceStop handlers (no CreateThread either way -- this file never calls it)', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.equals(#f.commands, 1, 'k9deploykennel is still registered with the feature off')
    t.equals(f.netEventCount(), 2, 'both deployKennelAt/removeKennel handlers are still registered with the feature off')
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
    t.equals(f.threadCount(), 0)
end)

t.test('feature off: the WORK is still correctly gated internally -- RequestDeployKennel() itself no-ops (the per-handler check inside the function)', function()
    local f = newKennelFixture({ deployableKennel = false })
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 0)
    t.equals(f.canShowK9UICallCount(), 0, 'the feature-flag check short-circuits before ever consulting CanShowK9UI()')
end)

t.test('feature off: deployKennelAt/removeKennel handlers both no-op internally even though they are registered', function()
    local f = newKennelFixture({ deployableKennel = false })
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, 999)
    t.equals(#f.deleteEntityCalls, 0)
end)

-- ========================================================================
-- Sanity + happy path
-- ========================================================================

t.test('feature on: registers exactly 1 command, 2 net events, 1 onResourceStart, 1 onResourceStop', function()
    local f = newKennelFixture()
    t.equals(#f.commands, 1)
    t.equals(f.commands[1].name, 'k9deploykennel')
    t.equals(f.netEventCount(), 2)
    t.isNotNil(f.netEventNames['qbx_k9unit:client:deployKennelAt'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:removeKennel'])
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('RequestDeployKennel: CanShowK9UI false denies locally, no server contact', function()
    local f = newKennelFixture()
    f.setCanShowK9UI(false)
    f.env.RequestDeployKennel()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestDeployKennel: happy path sends the real requestDeployKennel event', function()
    local f = newKennelFixture()
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestDeployKennel')
    t.equals(#f.lastServerEvent().args, 0)
end)

t.test('deployKennelAt: happy path -- primary model loads immediately, object created, grounded, frozen, netId reported back', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 100.0, 200.0, 30.0)
    t.equals(#f.createObjectCalls, 1)
    t.equals(f.createObjectCalls[1].x, 100.0)
    t.equals(#f.placeCalls, 1)
    t.equals(#f.freezeCalls, 1)
    t.equals(f.freezeCalls[1].toggle, true)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:confirmKennelPlaced')
    t.equals(#f.waitCalls, 0, 'a model that loads immediately never yields at all')
end)

t.test('deployKennelAt: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 1, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
end)

t.test('deployKennelAt: non-number coordinate arguments are rejected, no object created', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 'x', 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
end)

t.test('deployKennelAt: primary model times out -- falls back to fallbackPropModel, releases the primary\'s streaming reference (LEAK FIX), and logs a breadcrumb', function()
    local f = newKennelFixture()
    f.setModelBehavior(PRIMARY_MODEL, 'timeout')
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 1, 'must still succeed using the fallback')
    t.equals(f.createObjectCalls[1].modelHash, GetHashKey(FALLBACK_MODEL))
    t.equals(#f.waitCalls, 100, 'exactly REQUEST_MODEL_TIMEOUT_MS/50 = 100 polls for the stuck primary')
    t.isTrue(#f.releaseModelCalls >= 1, 'the timed-out primary\'s streaming reference must be released, not leaked')
    t.equals(#f.printLines, 1, 'a fallback breadcrumb must be printed for a server operator to notice')
end)

t.test('deployKennelAt: BOTH primary and fallback fail to load -- notifies, cancels placement, never touches CreateObject', function()
    local f = newKennelFixture()
    f.setModelBehavior(PRIMARY_MODEL, 'invalid')
    f.setModelBehavior(FALLBACK_MODEL, 'invalid')
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
    t.equals(f.lastNotify().description, locale('kennel.prop_load_failed'))
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:cancelKennelPlacement')
end)

t.test('deployKennelAt: CreateObject fails -- notifies, cancels placement', function()
    local f = newKennelFixture()
    f.setObjectBehavior({ createFails = true })
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(f.lastNotify().description, locale('kennel.placement_failed'))
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:cancelKennelPlacement')
end)

t.test('deployKennelAt: PlaceObjectOnGroundProperly fails -- deletes the just-created object, notifies, cancels placement', function()
    local f = newKennelFixture()
    f.setObjectBehavior({ groundFails = true })
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 1)
    t.equals(#f.deleteEntityCalls, 1, 'a kennel the game could not ground properly must never be confirmed')
    t.equals(f.lastNotify().description, locale('kennel.no_suitable_ground'))
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:cancelKennelPlacement')
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- the highest-priority area per this task's own
-- brief.
-- ========================================================================

t.test('onResourceStop: no-op when no kennel was ever deployed', function()
    local f = newKennelFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('onResourceStop: deletes a still-resolvable, self-deployed kennel, and is idempotent on a second firing', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.serverEvents, 1)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'the kennel this client itself created must be deleted on a resource restart, per this file\'s own "ship-blocking QA finding" comment')

    f.fireResourceStop(RESOURCE_NAME) -- fired twice, e.g. two AddEventHandler-registered listeners in practice
    t.equals(#f.deleteEntityCalls, 1, 'myKennelNetId is nil by the second firing -- must not attempt a second delete')
end)

t.test('onResourceStop: a kennel that is no longer resolvable (streamed out / already gone) is a clean no-op, but myKennelNetId is still cleared', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    -- Simulate the object no longer existing on this client (streamed out) --
    -- the ONLY entity created so far is handle 1.
    f.setEntityMissing(1)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 0, 'ResolveNetworkEntity returning nil must never be treated as an error')

    -- Proves myKennelNetId really was cleared (not left stale): a fresh
    -- RequestDeployKennel() after the "restart" must not say "already
    -- deployed" -- this models a genuine post-restart script instance,
    -- where myKennelNetId is guaranteed nil regardless; this test's real
    -- value is confirming onResourceStop's own local clear runs on the
    -- nil-resolve path too, not just the delete-succeeded path.
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 2, 'a second requestDeployKennel must reach the server -- the stale netId must not permanently block future deploys')
end)

t.test('onResourceStop: a mismatched resourceName never fires, even with a live kennel deployed', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    f.fireResourceStop('some_other_resource')
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel (cleanup backstop): source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local netId = f.lastServerEvent().args[1]
    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 1, netId)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel: non-number netId is rejected', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, 'not-a-number')
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel: an unresolvable netId (not streamed in) is a clean no-op', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, 999999)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel: DEFENSE-IN-DEPTH MODEL CHECK -- a resolvable netId whose CURRENT model is NOT a configured kennel prop is never deleted, even though the source guard and feature gate both pass', function()
    local f = newKennelFixture()
    -- A foreign networked entity (some other feature's prop, or another
    -- player's real object) that this handler never created -- registered
    -- directly rather than via deployKennelAt so its model is deliberately
    -- NOT one of the two configured kennel props.
    f.registerForeignEntity(777, 50, GetHashKey('prop_random_other_thing'))

    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, 777)
    t.equals(#f.deleteEntityCalls, 0, 'an entity whose live model is not an allowlisted kennel prop must never be deleted by this handler, regardless of what netId the server named')
end)

t.test('removeKennel: the ACCEPT side of the same allowlist -- a resolvable netId whose model matches the FALLBACK prop (not just the primary) is deleted too', function()
    local f = newKennelFixture()
    f.registerForeignEntity(778, 51, GetHashKey(FALLBACK_MODEL))

    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, 778)
    t.equals(#f.deleteEntityCalls, 1, 'the fallback prop model must be allowlisted exactly like the primary')
end)

t.test('removeKennel: happy path -- resolves the real kennel entity (matching the configured propModel), clears myKennelNetId, deletes it', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local netId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, netId)
    t.equals(#f.deleteEntityCalls, 1)

    -- Proves myKennelNetId was really cleared: onResourceStop afterward must
    -- find nothing left to clean up.
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'onResourceStop must not attempt a SECOND delete of the already-removed kennel')
end)

t.test('removeKennel: feature gate off -- no-op even with a valid, resolvable netId', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local netId = f.lastServerEvent().args[1]
    -- Simulate the feature having been disabled between deploy and this
    -- broadcast (an operator hot-reloading config, or the more realistic
    -- "another client's kennel, this client never had the feature on"
    -- case) by rebuilding with the flag off is not meaningful mid-session
    -- for THIS client's own object (it already deployed one), so this
    -- instead confirms the per-handler check exists as documented: with
    -- the feature off from file-load, the handler must never delete
    -- anything even given a syntactically valid netId.
    local g = newKennelFixture({ deployableKennel = false })
    g.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, netId)
    t.equals(#g.deleteEntityCalls, 0)
end)

t.test('DISCLOSED FINDING: deployKennelAt has NO stale-kennel guard -- a second dispatch before the first is ever removed silently orphans the first kennel (asymmetric with client/propattachment.lua\'s own attachK9Prop STALE-VEST GUARD)', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local firstEntity = f.createObjectCalls[1].entity
    t.equals(#f.deleteEntityCalls, 0, 'the first kennel is still alive and untouched after only one dispatch')

    -- A second deployKennelAt lands for the SAME client before the first
    -- kennel's netId is ever cleared (removeKennel/onResourceStop) -- see
    -- this file's own header for the concrete scenarios this models.
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 10.0, 20.0, 3.0)

    t.equals(#f.createObjectCalls, 2, 'a second, independent kennel object is created')
    t.equals(#f.deleteEntityCalls, 0, 'THE BUG: the first kennel is never deleted -- myKennelNetId now points only at the SECOND kennel')

    -- Proves the first kennel's handle really is gone, not just untested:
    -- onResourceStop only ever knows about the CURRENT myKennelNetId, so it
    -- can delete at most the SECOND kennel -- the first is permanently
    -- orphaned from this client's own perspective.
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'onResourceStop cleans up only the second kennel; the first (entity #1) is never referenced again')
    local deletedEntities = {}
    for _, e in ipairs(f.deleteEntityCalls) do deletedEntities[e] = true end
    t.isNil(deletedEntities[firstEntity], 'the FIRST kennel entity is never the one onResourceStop deletes -- it is orphaned')
end)

-- ========================================================================
-- ANY PED -- this file never calls IsOwnModelK9() anywhere (confirmed by
-- reading the whole file; grepped for it too) -- every gate is
-- CanShowK9UI() alone, which is itself role/model-decoupled. Proven here by
-- OMITTING IsOwnModelK9 from the sandbox entirely: if a regression ever
-- added a direct IsOwnModelK9() call to this file, this test would fail
-- loudly with "attempt to call a nil value" instead of silently passing.
-- ========================================================================

t.test('ANY PED: RequestDeployKennel works via CanShowK9UI() alone, with IsOwnModelK9 entirely undefined', function()
    local f = newKennelFixture()
    t.isNil(f.env.IsOwnModelK9, 'sanity: this fixture genuinely never defines IsOwnModelK9')
    local ok, err = pcall(f.env.RequestDeployKennel)
    t.isTrue(ok, 'must not reach for a global this file does not use: ' .. tostring(err))
    t.equals(#f.serverEvents, 1)
end)

t.test('ANY PED: the "Pick Up Kennel" ox_target option\'s canInteract also relies on CanShowK9UI() alone', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    t.equals(#f.addModelCalls, 1)
    local option = f.addModelCalls[1].options[1]
    t.equals(option.name, 'qbx_k9unit:pickupKennel')
    t.isTrue(option.canInteract(1, 1.0, {}, 'anything'))

    f.setCanShowK9UI(false)
    t.isFalse(option.canInteract(1, 1.0, {}, 'anything'))
end)

-- ========================================================================
-- DOUBLE-FIRE / RE-ENTRANCY
-- ========================================================================

t.test('RequestDeployKennel: two rapid calls BEFORE the first server confirmation ever arrives both reach the server (no client-side in-flight guard) -- safe only because server/kennel.lua independently re-enforces the one-kennel-per-citizenid limit, per this file\'s own comment', function()
    local f = newKennelFixture()
    f.env.RequestDeployKennel()
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 2, 'myKennelNetId is only set once deployKennelAt actually succeeds, so a pre-confirmation double-press is not blocked client-side')
end)

t.test('RequestDeployKennel: a call AFTER a real kennel is already confirmed is correctly blocked locally, no server contact', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.serverEvents, 1)

    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 1, 'once myKennelNetId is set, a second RequestDeployKennel must not reach the server')
    t.equals(f.lastNotify().description, locale('kennel.already_deployed'))
end)

os.exit(t.summary())
