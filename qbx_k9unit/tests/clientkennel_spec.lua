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
    other Config.Features flags are set on any given day, whatever their
    current count is), K9Compat + a real
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

    WATCHDOG THREAD -- CAPTURE, DON'T AUTO-RUN, mirroring
    tests/clientvehicle_spec.lua's own identical convention (see that
    file's header "THREE DIFFERENT CreateThread LIFETIMES"): this file has
    exactly ONE CreateThread call (the shared rest/carry watchdog, near the
    bottom of client/kennel.lua), so `capturedThreads[1]` always names it.
    `stepWatchdogOnce()` below resumes it exactly once per call (one full
    loop body, up to and including its own `Wait(sleepMs)`), so a test can
    assert on exactly what one tick of that thread does without needing to
    predict how many resumes an unrelated change might require.

    TWO REAL DEFECTS FOUND WHILE WRITING THIS SPEC (an earlier pass), BOTH
    FIXED (client/kennel.lua's own "REGISTRATION-TIME FEATURE GATE" and
    "STALE-KENNEL GUARD" comments are the fixes themselves) -- kept as a
    record of what was wrong and what changed, per this project's own "do
    not leave a stale finding claiming a fixed bug is still current" rule:

    1. NOT GENUINELY INERT WITH THE FEATURE OFF (FIXED) -- see the
       REGISTRATION-TIME FEATURE GATE tests below.
    2. NO STALE-KENNEL GUARD ON deployKennelAt (FIXED) -- see the dedicated
       test below.

    K9-CAN-RIDE-ALONG PASS (this pass) -- adds tests for
    pickupKennelConfirmed/putDownKennelAt/enterKennelConfirmed/
    kennelCarrierLost, the carry-aware RequestDeployKennel() branch, the
    Enter/Exit Kennel ox_target options, IsRestingInKennel()/
    IsCarryingKennel(), and the shared watchdog thread's own-death/
    wander-off/entity-lost/carry-reassertion branches. See
    server/kennel.lua's own header CRITICAL SAFETY section for the full
    architecture this pins from the client side.

    TRAP-HUNT FIX (this pass, coder-frontend): a real, high-probability
    stranding trap was found in "Rest in Kennel" -- the ONLY pre-existing
    exit was re-selecting the same small (likely camera-occluding) kennel
    prop through ox_target, with no radial entry, no keybind. This pass
    adds ExitKennelRest() (a globally-exposed, gate-free wrapper over
    ReleaseKennelRest()), a k9exitkennel keybind (client/keybinds.lua), and
    an "Exit Kennel" radial item (client/radial.lua). It ALSO corrects a
    real false claim this file's own former "WANDER-OFF EXIT" test
    inherited from client/kennel.lua's own (now-fixed) comment: "simply
    walking away is ALREADY an unconditional... way out" -- VERIFIED FALSE,
    since AttachEntityToEntity re-clamps the occupant's position to the
    kennel's bone every tick regardless of movement input (see
    client/combat.lua's own PROP DRAGGING header for the same finding
    applied to its own dragged target). See the "EXITKENNELREST" and
    "REQUIRED (trap-hunt brief)" test sections below for the new coverage,
    and the corrected WATCHDOG test's own new name for the corrected
    framing.
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
local MY_PED = 9001

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- the shared watchdog thread's own wander-off check
-- does `#(GetEntityCoords(ped) - GetEntityCoords(kennelEntity))`. Same
-- shape as tests/kennel_spec.lua's own identical Vec3MT stub (added for
-- the equivalent server-side native this pass).
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

--- @param opts { deployableKennel: boolean? }?
--- @return table fixture
local function newKennelFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local canShowK9UICalls = 0
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- K9-CAN-RIDE-ALONG PASS -- client/main.lua's own real HasK9Access() is
    -- an awaited server callback; this fixture stubs it as a plain
    -- controllable boolean, same level of abstraction CanShowK9UI() above
    -- already uses. Defaults to true so pickup-related tests that don't
    -- care about this gate specifically don't need to opt in every time.
    local hasK9AccessValue = true
    local hasK9AccessCalls = 0
    local function HasK9Access() hasK9AccessCalls = hasK9AccessCalls + 1; return hasK9AccessValue end

    -- ANY PED -- this file never calls IsOwnModelK9() as a hard dependency;
    -- it is consulted ONLY via a `type(IsOwnModelK9) == 'function'` soft
    -- guard on the "Rest in Kennel" option's own canInteract. Defaults to
    -- true (a K9-modeled ped) so tests that don't care about this specific
    -- display optimization aren't forced to opt in.
    local isOwnModelK9Value = true
    local function IsOwnModelK9() return isOwnModelK9Value end

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

    -- CAPTURE, DON'T AUTO-RUN -- see this file's own header for the full
    -- rationale (mirrors tests/clientvehicle_spec.lua's identical
    -- convention). This file has exactly ONE CreateThread call (the shared
    -- rest/carry watchdog), so capturedThreads[1] always names it.
    local capturedThreads = {}
    local function CreateThread(fn)
        capturedThreads[#capturedThreads + 1] = coroutine.create(fn)
    end
    local waitCalls = {}
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms; coroutine.yield() end

    -- ---- model loading ----
    -- modelBehavior[hash] = 'loads' (default) | 'timeout' | 'invalid'
    local modelBehavior = {}
    local requestModelCalls, releaseModelCalls = {}, {}
    local printLines = {}
    local function IsModelValid(hash) return modelBehavior[hash] ~= 'invalid' end
    local function RequestModel(hash) requestModelCalls[#requestModelCalls + 1] = hash end
    local function HasModelLoaded(hash) return modelBehavior[hash] ~= 'timeout' end
    local function SetModelAsNoLongerNeeded(hash) releaseModelCalls[#releaseModelCalls + 1] = hash end

    -- ---- object/ped lifecycle -- ONE shared handle space, exactly like a
    -- real client (peds and objects are both just entity handles) ----
    local objectSeq = 0
    local objectBehavior = {} -- default: real object, real ground placement
    local existingEntities = { [MY_PED] = true }
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

    -- K9-CAN-RIDE-ALONG PASS -- coords/heading are a SHARED table keyed by
    -- ANY handle (ped or object alike, exactly like the real natives).
    local coordsByHandle = { [MY_PED] = { x = 0, y = 0, z = 0 } }
    local headingByHandle = { [MY_PED] = 0.0 }
    local function GetEntityCoords(handle)
        local c = coordsByHandle[handle] or { x = 0, y = 0, z = 0 }
        return vec3(c.x, c.y, c.z)
    end
    local function GetEntityHeading(handle) return headingByHandle[handle] or 0.0 end
    local setCoordsCalls, setHeadingCalls = {}, {}
    local function SetEntityCoords(handle, x, y, z, ...)
        coordsByHandle[handle] = { x = x, y = y, z = z }
        setCoordsCalls[#setCoordsCalls + 1] = { handle = handle, x = x, y = y, z = z }
    end
    local function SetEntityHeading(handle, heading)
        headingByHandle[handle] = heading
        setHeadingCalls[#setHeadingCalls + 1] = { handle = handle, heading = heading }
    end

    local collisionCalls = {}
    local function SetEntityCollision(handle, toggle, keepPhysics)
        collisionCalls[#collisionCalls + 1] = { handle = handle, toggle = toggle, keepPhysics = keepPhysics }
    end

    local detachCalls = {}
    local function DetachEntity(handle, dynamic, collision)
        detachCalls[#detachCalls + 1] = { handle = handle, dynamic = dynamic, collision = collision }
    end

    local attachCalls = {}
    local function AttachEntityToEntity(entity1, entity2, boneIndex, xPos, yPos, zPos, xRot, yRot, zRot, p9, useSoftPinning, collision, isPed, rotationOrder, syncRot)
        attachCalls[#attachCalls + 1] = {
            entity1 = entity1, entity2 = entity2, boneIndex = boneIndex,
            xPos = xPos, yPos = yPos, zPos = zPos, xRot = xRot, yRot = yRot, zRot = zRot,
            isPed = isPed,
        }
    end

    local controlRequestCalls = {}
    local function NetworkRequestControlOfEntity(entity) controlRequestCalls[#controlRequestCalls + 1] = entity end

    local deadPeds = {}
    local function IsEntityDead(ped) return deadPeds[ped] == true end

    local function PlayerPedId() return MY_PED end

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
    -- client/main.lua's own resolve sequence (already covered elsewhere).
    -- The optional second (expectedEntityType) argument client/kennel.lua
    -- now passes at some call sites is deliberately NOT modeled/enforced
    -- here -- same level of abstraction the pre-existing stub already
    -- used for the single-argument call sites.
    local function ResolveNetworkEntity(netId)
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    -- ---- K9Compat -- DIRECT stub, not the real shared/compat/core.lua +
    -- shared/compat/target.lua adapter pair. See this file's own header.
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
            carryBoneIndex = 0,
            carryOffsetX = 0.0,
            carryOffsetY = 0.3,
            carryOffsetZ = 0.35,
            carryRotX = 0.0,
            carryRotY = 0.0,
            carryRotZ = 0.0,
            restOffsetX = 0.0,
            restOffsetY = 0.0,
            restOffsetZ = 0.0,
        },
    }

    local env = Sandbox.newEnv({
        Config = config,
        GetHashKey = GetHashKey,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        IsOwnModelK9 = IsOwnModelK9,
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
        GetEntityCoords = GetEntityCoords,
        GetEntityHeading = GetEntityHeading,
        SetEntityCoords = SetEntityCoords,
        SetEntityHeading = SetEntityHeading,
        SetEntityCollision = SetEntityCollision,
        DetachEntity = DetachEntity,
        AttachEntityToEntity = AttachEntityToEntity,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        IsEntityDead = IsEntityDead,
        PlayerPedId = PlayerPedId,
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
        setHasK9Access = function(v) hasK9AccessValue = v end,
        hasK9AccessCallCount = function() return hasK9AccessCalls end,
        setIsOwnModelK9 = function(v) isOwnModelK9Value = v end,
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
        setCoords = function(handle, x, y, z) coordsByHandle[handle] = { x = x, y = y, z = z } end,
        setHeading = function(handle, heading) headingByHandle[handle] = heading end,
        setCoordsCalls = setCoordsCalls,
        setHeadingCalls = setHeadingCalls,
        collisionCalls = collisionCalls,
        detachCalls = detachCalls,
        attachCalls = attachCalls,
        lastAttachCall = function() return attachCalls[#attachCalls] end,
        controlRequestCalls = controlRequestCalls,
        setPedDead = function(ped, dead) deadPeds[ped] = dead end,
        MY_PED = MY_PED,
        --- Registers a networked entity THIS handler did not itself create
        --- via deployKennelAt (e.g. some other feature's prop, or another
        --- player's real vehicle/ped) -- used only by the DEFENSE-IN-DEPTH
        --- MODEL CHECK test below, which needs a resolvable netId whose
        --- entity is deliberately NOT a configured kennel prop model.
        registerForeignEntity = function(netId, entity, modelHash, coords)
            existingEntities[entity] = true
            entityModels[entity] = modelHash
            netIdByEntity[entity] = netId
            if coords then coordsByHandle[entity] = coords end
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
        --- Resumes the shared watchdog thread exactly once -- one full loop
        --- body, up to and including its own trailing Wait(sleepMs). See
        --- this file's own header.
        stepWatchdogOnce = function()
            local co = capturedThreads[1]
            if not co then return end
            local ok, err = coroutine.resume(co)
            if not ok then error('kennel fixture: watchdog thread errored: ' .. tostring(err)) end
        end,
        watchdogThreadCount = function() return #capturedThreads end,
    }
end

-- ========================================================================
-- FEATURE OFF -- pins the FIXED behavior: genuinely inert at the
-- REGISTRATION level (see this file's header, fixed defect #1), not merely
-- internally no-op.
-- ========================================================================

t.test('FIXED: feature off registers NOTHING at all -- no command, no net events, no onResourceStart/onResourceStop handlers, no threads', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.equals(#f.commands, 0, 'k9deploykennel is not registered with the feature off')
    t.equals(f.netEventCount(), 0, 'none of this file\'s six net events is registered with the feature off')
    t.equals(f.onResourceStartHandlerCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
    t.equals(f.watchdogThreadCount(), 0, 'the shared watchdog thread must not even start with the feature off')
end)

t.test('feature off: RequestDeployKennel() itself stays defined and reachable-but-inert (the per-handler check inside the function), for client/radial.lua/client/tablet.lua\'s own call sites', function()
    local f = newKennelFixture({ deployableKennel = false })
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 0)
    t.equals(f.canShowK9UICallCount(), 0, 'the feature-flag check short-circuits before ever consulting CanShowK9UI()')
end)

t.test('feature off: IsRestingInKennel()/IsCarryingKennel() stay defined and simply report false -- never nil, never erroring', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.isFalse(f.env.IsRestingInKennel())
    t.isFalse(f.env.IsCarryingKennel())
end)

t.test('FIXED: feature off -- none of this file\'s six net events exists to dispatch at all (previously registered but internally no-op; now not registered)', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.isNil(f.netEventNames['qbx_k9unit:client:deployKennelAt'])
    t.isNil(f.netEventNames['qbx_k9unit:client:removeKennel'])
    t.isNil(f.netEventNames['qbx_k9unit:client:pickupKennelConfirmed'])
    t.isNil(f.netEventNames['qbx_k9unit:client:putDownKennelAt'])
    t.isNil(f.netEventNames['qbx_k9unit:client:enterKennelConfirmed'])
    t.isNil(f.netEventNames['qbx_k9unit:client:kennelCarrierLost'])
end)

-- ========================================================================
-- Sanity + happy path
-- ========================================================================

t.test('feature on: registers exactly 1 command, 6 net events, 1 onResourceStart, 1 onResourceStop, and starts the shared watchdog thread', function()
    local f = newKennelFixture()
    t.equals(#f.commands, 1)
    t.equals(f.commands[1].name, 'k9deploykennel')
    t.equals(f.netEventCount(), 6)
    t.isNotNil(f.netEventNames['qbx_k9unit:client:deployKennelAt'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:removeKennel'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:pickupKennelConfirmed'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:putDownKennelAt'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:enterKennelConfirmed'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:kennelCarrierLost'])
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
    t.equals(f.watchdogThreadCount(), 1)
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

    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 2, 'a second requestDeployKennel must reach the server -- the stale netId must not permanently block future deploys')
end)

t.test('onResourceStop: a mismatched resourceName never fires, even with a live kennel deployed', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    f.fireResourceStop('some_other_resource')
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('SAFETY: onResourceStop while resting unconditionally detaches this client\'s own ped and restores collision, with no server round trip required', function()
    local f = newKennelFixture()
    local netId = 500
    f.registerForeignEntity(netId, 42, GetHashKey(PRIMARY_MODEL), { x = 5, y = 5, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.fireResourceStop(RESOURCE_NAME)
    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
end)

t.test('SAFETY: onResourceStop while carrying detaches the carried object (never deletes it -- server/kennel.lua\'s own sweep owns that)', function()
    local f = newKennelFixture()
    local netId = 501
    f.registerForeignEntity(netId, 43, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsCarryingKennel())

    f.fireResourceStop(RESOURCE_NAME)
    t.isFalse(f.env.IsCarryingKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == 43)
    t.isNil(f.deleteEntityCalls[1], 'the carried object must not be deleted client-side -- an occupant could be attached to it')
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

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'onResourceStop must not attempt a SECOND delete of the already-removed kennel')
end)

t.test('SAFETY: removeKennel for the netId THIS client is resting in forces an unconditional local release, even though pickup no longer triggers this path in the ordinary case', function()
    local f = newKennelFixture()
    local netId = 502
    f.registerForeignEntity(netId, 44, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.dispatchNetEvent('qbx_k9unit:client:removeKennel', 65535, netId)
    t.isFalse(f.env.IsRestingInKennel(), 'defense-in-depth: this client must never depend on an ordinary pickup being the only way a kennel it is resting in can disappear')
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestExitKennel', 'the best-effort server bookkeeping fire must still happen')
end)

t.test('FIXED: removeKennel -- feature off from file-load means the handler is not even registered, so there is nothing left to dispatch to', function()
    local g = newKennelFixture({ deployableKennel = false })
    t.isNil(g.netEventNames['qbx_k9unit:client:removeKennel'], 'removeKennel is not registered at all with the feature off (REGISTRATION-TIME FEATURE GATE)')
end)

t.test('FIXED: STALE-KENNEL GUARD -- a second dispatch before the first is ever removed now deletes the first kennel instead of orphaning it (was asymmetric with client/propattachment.lua\'s own attachK9Prop STALE-VEST GUARD; now mirrors it)', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local firstEntity = f.createObjectCalls[1].entity
    t.equals(#f.deleteEntityCalls, 0, 'the first kennel is still alive and untouched after only one dispatch')

    f.dispatchNetEvent('qbx_k9unit:client:deployKennelAt', 65535, 10.0, 20.0, 3.0)
    local secondEntity = f.createObjectCalls[2].entity

    t.equals(#f.createObjectCalls, 2, 'a second, independent kennel object is created')
    t.equals(#f.deleteEntityCalls, 1, 'FIXED: the STALE-KENNEL GUARD deletes the first kennel before the second is even created')
    t.equals(f.deleteEntityCalls[1], firstEntity, 'the entity actually deleted by the guard is the FIRST kennel, not the second')

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 2, 'onResourceStop cleans up the second (now-current) kennel too')
    t.equals(f.deleteEntityCalls[2], secondEntity, 'the second delete call targets the SECOND kennel, confirming myKennelNetId correctly tracks the current one, not the orphaned first')
end)

-- ========================================================================
-- pickupKennelConfirmed -- NEW THIS PASS (K9-can-ride-along). NEVER
-- CreateObjects a new prop -- attaches the SAME, already-existing entity.
-- ========================================================================

t.test('pickupKennelConfirmed: happy path -- requests network control, unfreezes, attaches the SAME object to the picker\'s own hands (entity1 = the object, isPed = false)', function()
    local f = newKennelFixture()
    local netId = 600
    f.registerForeignEntity(netId, 70, GetHashKey(PRIMARY_MODEL))

    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    t.isTrue(f.env.IsCarryingKennel())
    t.isTrue(#f.controlRequestCalls >= 1 and f.controlRequestCalls[#f.controlRequestCalls] == 70, 'NETWORK OWNERSHIP -- must request control of the object before attaching it (client/combat.lua PropDragging precedent)')
    t.isTrue(#f.freezeCalls >= 1 and f.freezeCalls[#f.freezeCalls].entity == 70 and f.freezeCalls[#f.freezeCalls].toggle == false, 'must unfreeze before attaching, or the two would fight each other')
    local attach = f.lastAttachCall()
    t.equals(attach.entity1, 70, 'entity1 is the kennel OBJECT')
    t.equals(attach.entity2, MY_PED, 'entity2 is the picker\'s own ped')
    t.equals(attach.isPed, false, 'entity1 is an object, not a ped')
    t.equals(#f.createObjectCalls, 0, 'must NEVER CreateObject a second, separate prop -- the SAME real object is reused')
end)

t.test('pickupKennelConfirmed: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 601
    f.registerForeignEntity(netId, 71, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 1, netId)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.attachCalls, 0)
end)

t.test('pickupKennelConfirmed: an unresolvable netId fails closed -- never claims to be carrying anything', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, 999999)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.attachCalls, 0)
end)

t.test('pickupKennelConfirmed: a resolvable netId whose model is NOT a configured kennel prop fails closed', function()
    local f = newKennelFixture()
    local netId = 602
    f.registerForeignEntity(netId, 72, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.attachCalls, 0)
end)

-- ========================================================================
-- putDownKennelAt -- NEW THIS PASS. Mirror image of deployKennelAt applied
-- to an already-existing object -- never creates, never deletes.
-- ========================================================================

t.test('putDownKennelAt: happy path -- detaches, repositions at the server-computed spot, re-freezes, clears carry state', function()
    local f = newKennelFixture()
    local netId = 700
    f.registerForeignEntity(netId, 80, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsCarryingKennel())

    f.dispatchNetEvent('qbx_k9unit:client:putDownKennelAt', 65535, netId, 11.0, 22.0, 3.0)
    t.isFalse(f.env.IsCarryingKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == 80)
    t.isTrue(#f.setCoordsCalls >= 1)
    local lastSet = f.setCoordsCalls[#f.setCoordsCalls]
    t.equals(lastSet.handle, 80)
    t.equals(lastSet.x, 11.0)
    t.equals(lastSet.y, 22.0)
    t.equals(#f.placeCalls, 1)
    t.isTrue(f.freezeCalls[#f.freezeCalls].entity == 80 and f.freezeCalls[#f.freezeCalls].toggle == true)
    t.equals(#f.deleteEntityCalls, 0, 'never deletes the object -- an occupant could be attached to it')
    t.equals(#f.createObjectCalls, 0, 'never creates a new one either')
end)

t.test('putDownKennelAt: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 701
    f.registerForeignEntity(netId, 81, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    f.dispatchNetEvent('qbx_k9unit:client:putDownKennelAt', 1, netId, 0, 0, 0)
    t.isTrue(f.env.IsCarryingKennel(), 'a forged event must not affect real carry state')
end)

t.test('putDownKennelAt: an already-gone entity is a clean no-op -- still clears local carry state', function()
    local f = newKennelFixture()
    local netId = 702
    f.registerForeignEntity(netId, 82, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    f.setEntityMissing(82)

    f.dispatchNetEvent('qbx_k9unit:client:putDownKennelAt', 65535, netId, 1, 2, 3)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.setCoordsCalls, 0)
end)

-- ========================================================================
-- enterKennelConfirmed -- NEW THIS PASS. The occupant is ALWAYS
-- PlayerPedId() -- THIS client's own real ped. Confirmed: this file has no
-- CreatePed call anywhere (grepped for it while writing this spec).
-- ========================================================================

t.test('enterKennelConfirmed: happy path -- positions this client\'s OWN ped at the kennel, disables collision, attaches it (entity1 = the ped, isPed = false to match the one existing precedent), sets restState', function()
    local f = newKennelFixture()
    local netId = 800
    f.registerForeignEntity(netId, 90, GetHashKey(PRIMARY_MODEL), { x = 50.0, y = 60.0, z = 10.0 })
    f.setHeading(90, 45.0)

    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    t.isTrue(f.env.IsRestingInKennel())
    t.equals(f.setCoordsCalls[#f.setCoordsCalls].handle, MY_PED)
    t.equals(f.setCoordsCalls[#f.setCoordsCalls].x, 50.0)
    t.equals(f.setCoordsCalls[#f.setCoordsCalls].y, 60.0)
    t.equals(f.setHeadingCalls[#f.setHeadingCalls].handle, MY_PED)
    t.equals(f.setHeadingCalls[#f.setHeadingCalls].heading, 45.0)
    t.isTrue(f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == false)
    local attach = f.lastAttachCall()
    t.equals(attach.entity1, MY_PED, 'entity1 is the OCCUPANT\'S OWN ped -- never a spawned ped, never driven from another client')
    t.equals(attach.entity2, 90, 'entity2 is the kennel object')
    t.equals(#f.createObjectCalls, 0, 'no ped or prop is ever created -- the occupant is a real, already-connected player\'s own ped')
    t.equals(f.lastNotify().description, locale('kennel.enter_success'))
end)

t.test('enterKennelConfirmed: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 801
    f.registerForeignEntity(netId, 91, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 1, netId)
    t.isFalse(f.env.IsRestingInKennel())
end)

t.test('enterKennelConfirmed: an unresolvable/wrong-model netId fails closed', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, 999999)
    t.isFalse(f.env.IsRestingInKennel())

    local netId = 802
    f.registerForeignEntity(netId, 92, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)
    t.isFalse(f.env.IsRestingInKennel())
end)

-- ========================================================================
-- "Exit Kennel" -- the occupant's own, ALWAYS-AVAILABLE local release. See
-- server/kennel.lua's header CRITICAL SAFETY section -- this must work
-- with ZERO server involvement.
-- ========================================================================

t.test('SAFETY: the "Exit Kennel" ox_target option releases unconditionally -- detaches, restores collision, and fires the best-effort server bookkeeping event', function()
    local f = newKennelFixture()
    local netId = 900
    f.registerForeignEntity(netId, 100, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:exitKennel' then exitOption = option end
    end
    t.isNotNil(exitOption, 'an "Exit Kennel" option must be registered')
    t.isTrue(exitOption.canInteract(100, 1.0, {}, 'anything'))

    exitOption.onSelect()
    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestExitKennel')
end)

t.test('SAFETY: the "Exit Kennel" ox_target option calls the SAME ExitKennelRest() global the new k9exitkennel keybind (client/keybinds.lua) and "Exit Kennel" radial item (client/radial.lua) now also call -- never a second, forked release', function()
    local f = newKennelFixture()
    local netId = 951
    f.registerForeignEntity(netId, 151, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:exitKennel' then exitOption = option end
    end

    local exitKennelRestCalls = 0
    local realExitKennelRest = f.env.ExitKennelRest
    f.env.ExitKennelRest = function(...)
        exitKennelRestCalls = exitKennelRestCalls + 1
        return realExitKennelRest(...)
    end

    exitOption.onSelect()
    t.equals(exitKennelRestCalls, 1, 'onSelect must call through the shared ExitKennelRest() global, not a private copy of ReleaseKennelRest')
    t.isFalse(f.env.IsRestingInKennel())
end)

-- ========================================================================
-- ExitKennelRest() -- trap-hunt fix, THIS PASS. The occupant's own
-- ALWAYS-AVAILABLE exit entry point, exposed globally so client/keybinds.lua's
-- new k9exitkennel command/keybind and client/radial.lua's new "Exit
-- Kennel" item can reach it directly, instead of only through ox_target on
-- the kennel prop itself. See client/kennel.lua's own doc comment on this
-- global, and its corrected WANDER-OFF EXIT comment above for the finding
-- this whole addition responds to.
-- ========================================================================

t.test('ExitKennelRest(): defined with the feature ON, and releases exactly like the ox_target option -- detaches, restores collision, fires the best-effort server bookkeeping event', function()
    local f = newKennelFixture()
    local netId = 952
    f.registerForeignEntity(netId, 152, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.env.ExitKennelRest()

    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestExitKennel')
end)

t.test('FIXED: ExitKennelRest() stays defined and reachable-but-inert with the feature OFF at file-load -- mirrors IsRestingInKennel()/IsCarryingKennel()/RequestDeployKennel() above, for client/keybinds.lua/client/radial.lua\'s own call sites', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.isNotNil(f.env.ExitKennelRest)
    f.env.ExitKennelRest() -- must not error even though restState can never be non-nil with the feature off from load
    t.equals(#f.serverEvents, 0, 'a genuine no-op -- ReleaseKennelRest\'s own `if not restState then return end` guard short-circuits before ever touching the network')
end)

t.test('ExitKennelRest(): calling it while not resting is a genuine, harmless no-op -- no detach, no collision change, no server event', function()
    local f = newKennelFixture()
    f.env.ExitKennelRest()
    t.equals(#f.detachCalls, 0)
    t.equals(#f.collisionCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('REQUIRED (trap-hunt brief): ExitKennelRest() releases the occupant even when Config.Features.DeployableKennel has been toggled OFF mid-session, AFTER the occupant already entered while it was on', function()
    local f = newKennelFixture()
    local netId = 953
    f.registerForeignEntity(netId, 153, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    -- Simulates a live config push flipping the flag off while this client
    -- is already resting -- this file's own REGISTRATION-TIME FEATURE GATE
    -- was evaluated once at load time and does not re-run, so every
    -- net-event handler/ox_target option/watchdog thread registered while
    -- the flag was still true stays registered regardless -- but this
    -- proves ExitKennelRest() ITSELF never re-reads the flag on the way
    -- out either.
    f.env.Config.Features.DeployableKennel = false

    f.env.ExitKennelRest()
    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
end)

t.test('REQUIRED (trap-hunt brief): ExitKennelRest() releases the occupant even when CanShowK9UI()/HasK9Access() would now both deny access ("no longer certified") -- neither is even consulted', function()
    local f = newKennelFixture()
    local netId = 954
    f.registerForeignEntity(netId, 154, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.setCanShowK9UI(false)
    f.setHasK9Access(false)
    local canShowK9UICallsBefore = f.canShowK9UICallCount()
    local hasK9AccessCallsBefore = f.hasK9AccessCallCount()

    f.env.ExitKennelRest()

    t.isFalse(f.env.IsRestingInKennel(), 'an exit path must never be deniable by a certification/access check')
    t.equals(f.canShowK9UICallCount(), canShowK9UICallsBefore, 'CanShowK9UI() must never even be consulted on the way out')
    t.equals(f.hasK9AccessCallCount(), hasK9AccessCallsBefore, 'HasK9Access() must never even be consulted on the way out')
    t.equals(f.denyCallCount(), 0, 'DenyK9UIAccess() must never fire for an exit path')
end)

t.test('ANY PED: the "Rest in Kennel" option\'s canInteract relies on CanShowK9UI() alone -- setting IsOwnModelK9 has NO effect either way, proving production code never consults it', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:enterKennel' then enterOption = option end
    end
    f.setIsOwnModelK9(false) -- would matter if production code consulted it -- it must not
    t.isTrue(enterOption.canInteract(1, 1.0, {}, 'anything'), 'CanShowK9UI() alone decides this -- a role-holder on a non-dog body (IsOwnModelK9() == false) must still see the option')
end)

t.test('"Rest in Kennel"/"Exit Kennel" options: name, icon, and gating -- fa-dog + CanShowK9UI() convention (coder-frontend input this pass)', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addModelCalls[#f.addModelCalls].options
    local enterOption, exitOption
    for _, option in ipairs(options) do
        if option.name == 'qbx_k9unit:enterKennel' then enterOption = option end
        if option.name == 'qbx_k9unit:exitKennel' then exitOption = option end
    end
    t.equals(enterOption.icon, 'fas fa-dog')
    t.equals(exitOption.icon, 'fas fa-dog')
    t.isTrue(enterOption.canInteract(1, 1.0, {}, 'anything'))

    f.setCanShowK9UI(false)
    t.isFalse(enterOption.canInteract(1, 1.0, {}, 'anything'), 'Rest in Kennel is gated on CanShowK9UI(), same convention as every self-administered K9 action')
end)

t.test('"Rest in Kennel": canInteract also hides while already resting or carrying (display-only convenience, matches server-side rejection)', function()
    local f = newKennelFixture()
    local netId = 901
    f.registerForeignEntity(netId, 101, GetHashKey(PRIMARY_MODEL))
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:enterKennel' then enterOption = option end
    end
    t.isTrue(enterOption.canInteract(101, 1.0, {}, 'anything'))

    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)
    t.isFalse(enterOption.canInteract(101, 1.0, {}, 'anything'), 'already resting -- must not offer to enter again')
end)

t.test('"Exit Kennel": canInteract only true for the SPECIFIC entity this client is actually resting in', function()
    local f = newKennelFixture()
    local netId = 902
    f.registerForeignEntity(netId, 102, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:exitKennel' then exitOption = option end
    end
    t.isTrue(exitOption.canInteract(102, 1.0, {}, 'anything'))
    t.isFalse(exitOption.canInteract(999, 1.0, {}, 'anything'), 'a DIFFERENT entity must never offer "Exit Kennel" for a kennel this client is not actually inside')
end)

-- ========================================================================
-- "Pick Up Kennel" -- REWORKED THIS PASS (coder-frontend input): fa-user-tie
-- + HasK9Access() alone, deliberately NOT CanShowK9UI()/IsOwnModelK9() --
-- a human handler carrying a box does not require currently being a dog.
-- ========================================================================

t.test('"Pick Up Kennel": icon is fa-user-tie, and canInteract relies on HasK9Access() alone -- NOT CanShowK9UI()/IsOwnModelK9()', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    t.equals(#f.addModelCalls, 1, 'all three options register via ONE AddModel call')
    local options = f.addModelCalls[1].options
    t.equals(#options, 3)
    local pickupOption
    for _, option in ipairs(options) do
        if option.name == 'qbx_k9unit:pickupKennel' then pickupOption = option end
    end
    t.equals(pickupOption.icon, 'fas fa-user-tie')

    -- Not a K9, not able to "show K9 UI" at all -- must still see the option.
    f.setCanShowK9UI(false)
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    t.isTrue(pickupOption.canInteract(1, 1.0, {}, 'anything'), 'a human handler must be able to pick up a kennel without being a dog')

    f.setHasK9Access(false)
    t.isFalse(pickupOption.canInteract(1, 1.0, {}, 'anything'))
end)

t.test('"Pick Up Kennel": canInteract hides while THIS client is already carrying something', function()
    local f = newKennelFixture()
    local netId = 903
    f.registerForeignEntity(netId, 103, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local pickupOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:pickupKennel' then pickupOption = option end
    end
    t.isFalse(pickupOption.canInteract(103, 1.0, {}, 'anything'))
end)

t.test('"Pick Up Kennel": onSelect sends the real requestPickupKennel event with the hovered entity\'s netId', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local pickupOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'qbx_k9unit:pickupKennel' then pickupOption = option end
    end
    local netId = 904
    f.registerForeignEntity(netId, 104, GetHashKey(PRIMARY_MODEL))
    pickupOption.onSelect({ entity = 104 })
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPickupKennel')
    t.equals(f.lastServerEvent().args[1], netId)
end)

-- ========================================================================
-- RequestDeployKennel: carry-aware branch -- THIS PASS. One entry point
-- serves BOTH "deploy a new kennel" and "put down the one I'm carrying,"
-- decided by which state this client is actually in. Checked BEFORE even
-- the feature-flag/CanShowK9UI() gates, mirroring
-- client/vehicle.lua's own ExitK9Vehicle() "never gate an exit-adjacent
-- action" precedent.
-- ========================================================================

t.test('RequestDeployKennel: while carrying, sends requestPutDownKennel instead of requestDeployKennel', function()
    local f = newKennelFixture()
    local netId = 905
    f.registerForeignEntity(netId, 105, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    f.env.RequestDeployKennel()
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPutDownKennel')
end)

t.test('RequestDeployKennel: the put-down branch is NEVER gated behind CanShowK9UI()/the feature flag -- mirrors ExitK9Vehicle()', function()
    local f = newKennelFixture()
    local netId = 906
    f.registerForeignEntity(netId, 106, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    f.setCanShowK9UI(false)
    f.env.RequestDeployKennel()
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPutDownKennel', 'a handler whose certification lapses mid-carry must still be able to set the kennel back down')
    t.equals(f.denyCallCount(), 0)
end)

-- ========================================================================
-- kennelCarrierLost -- NEW THIS PASS (carrier-disconnect safety net,
-- server/kennel.lua's playerDropped handler, event 12).
-- ========================================================================

t.test('kennelCarrierLost: settles the object (detach + freeze) and clears local carry state if it was mine', function()
    local f = newKennelFixture()
    local netId = 1000
    f.registerForeignEntity(netId, 200, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    f.dispatchNetEvent('qbx_k9unit:client:kennelCarrierLost', 65535, netId)
    t.isFalse(f.env.IsCarryingKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == 200)
    t.isTrue(f.freezeCalls[#f.freezeCalls].entity == 200 and f.freezeCalls[#f.freezeCalls].toggle == true)
end)

t.test('kennelCarrierLost: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 1001
    f.registerForeignEntity(netId, 201, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    f.dispatchNetEvent('qbx_k9unit:client:kennelCarrierLost', 1, netId)
    t.isTrue(f.env.IsCarryingKennel())
end)

t.test('kennelCarrierLost: never touches an occupant\'s own restState -- a K9 riding inside is unaffected by who was carrying it', function()
    local f = newKennelFixture()
    local netId = 1002
    f.registerForeignEntity(netId, 202, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId) -- THIS same client is (for test purposes) the occupant

    f.dispatchNetEvent('qbx_k9unit:client:kennelCarrierLost', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel(), 'restState must be completely untouched by a carrier-lost broadcast for the SAME netId')
end)

-- ========================================================================
-- SHARED WATCHDOG THREAD -- own-death / wander-off / entity-lost / carry
-- re-assertion. See this file's header for the capture-and-step
-- convention.
-- ========================================================================

t.test('WATCHDOG: own-death while resting releases the occupant (detach + restore collision)', function()
    local f = newKennelFixture()
    local netId = 1100
    f.registerForeignEntity(netId, 300, GetHashKey(PRIMARY_MODEL), { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.setPedDead(MY_PED, true)
    f.stepWatchdogOnce()

    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
end)

t.test('WATCHDOG: distance-check backstop -- CORRECTED framing (trap-hunt finding, this pass): this does NOT prove "walking away is an escape hatch." An earlier version of this test\'s own name/assertion message claimed exactly that, and it was FALSE -- see client/kennel.lua\'s own corrected WANDER-OFF EXIT comment for the full writeup (AttachEntityToEntity re-clamps the occupant\'s position to the kennel\'s bone every tick; only DetachEntity ends that, never ordinary movement input). This test instead pins the NARROW, REAL case this branch actually catches: this fixture\'s own GetEntityCoords/SetEntityCoords stub directly overwrites coordinates (unlike a real attached ped, which the engine would keep re-clamping) -- standing in for the rare native-level desync where the attachment silently ends while restState has not been told yet. If that ever happens, the occupant really is free-standing, and this branch still correctly converts it into a clean, tracked exit rather than a stale KennelOccupants entry.', function()
    local f = newKennelFixture()
    local netId = 1101
    f.registerForeignEntity(netId, 301, GetHashKey(PRIMARY_MODEL), { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.setCoords(MY_PED, 100.0, 100.0, 0.0) -- simulates a desynced/already-detached ped, far beyond interactDistanceMeters (2.5) -- NOT a claim that ordinary movement can reach this state while genuinely attached
    f.stepWatchdogOnce()

    t.isFalse(f.env.IsRestingInKennel(), 'a free-standing occupant (however that came about) must still be converted into a clean exit')
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestExitKennel')
end)

t.test('REQUIRED (trap-hunt brief): WATCHDOG -- the kennel entity becoming unresolvable releases the occupant after the debounced miss-streak, not on the first miss (this IS the genuine, always-running automatic safety valve for "the kennel prop is destroyed while occupied" -- it never depends on a thread that only starts under some condition: this thread starts whenever the feature was on at file-load, the same condition that is the only way restState could ever become non-nil in the first place)', function()
    local f = newKennelFixture()
    local netId = 1102
    f.registerForeignEntity(netId, 302, GetHashKey(PRIMARY_MODEL), { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:client:enterKennelConfirmed', 65535, netId)

    f.setEntityMissing(302)
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsRestingInKennel(), 'a single miss must not be trusted -- could be a momentary streaming hiccup')
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsRestingInKennel())
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsRestingInKennel(), 'three consecutive misses must release the occupant')
end)

t.test('WATCHDOG: idles (no rest, no carry) without touching any native at all', function()
    local f = newKennelFixture()
    f.stepWatchdogOnce()
    t.equals(#f.detachCalls, 0)
    t.equals(#f.attachCalls, 0)
    t.equals(#f.controlRequestCalls, 0)
end)

t.test('WATCHDOG: while carrying, periodically re-requests network control and re-asserts the attach (defensive re-assertion for the one relationship that crosses an ownership boundary)', function()
    local f = newKennelFixture()
    local netId = 1103
    f.registerForeignEntity(netId, 303, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)
    local controlCallsBefore = #f.controlRequestCalls
    local attachCallsBefore = #f.attachCalls

    f.stepWatchdogOnce()

    t.isTrue(#f.controlRequestCalls > controlCallsBefore)
    t.isTrue(#f.attachCalls > attachCallsBefore)
    t.isTrue(f.env.IsCarryingKennel())
end)

t.test('WATCHDOG: own-death while carrying notifies and requests a put-down through the ordinary server flow (never deletes/detaches unilaterally)', function()
    local f = newKennelFixture()
    local netId = 1104
    f.registerForeignEntity(netId, 304, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    f.setPedDead(MY_PED, true)
    f.stepWatchdogOnce()

    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPutDownKennel')
    t.equals(f.lastNotify().description, locale('kennel.exit_own_downed'))
end)

t.test('WATCHDOG: the carried object becoming unresolvable clears local carry state after the debounced miss-streak', function()
    local f = newKennelFixture()
    local netId = 1105
    f.registerForeignEntity(netId, 305, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('qbx_k9unit:client:pickupKennelConfirmed', 65535, netId)

    f.setEntityMissing(305)
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsCarryingKennel())
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsCarryingKennel())
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsCarryingKennel())
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
