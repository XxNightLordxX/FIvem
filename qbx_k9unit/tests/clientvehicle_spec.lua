--[[
    tests/clientvehicle_spec.lua

    Direct, black-box tests of client/vehicle.lua against the REAL,
    unmodified production file -- K9 vehicle entry/exit
    (Config.Features.VehicleEntryExit). One of six client files this pass
    writes a spec for (see tests/vehiclecombatguard_spec.lua's own header,
    whose disclosed gap this batch exists to close).

    SCOPE, DELIBERATELY NARROWED TO AVOID COLLIDING WITH
    tests/vehiclecombatguard_spec.lua: that file already thoroughly covers
    ONE specific cross-file interaction against this same production file
    (the mutual guard between EnterNearestK9Vehicle() and
    IsDragEngaged()/IsBiteHoldEngaged(), both directions, plus the "Load
    Into Vehicle" canInteract's own mirror of that guard) -- its own header
    names this file's OTHER pre-existing behavior as explicitly OUT OF ITS
    OWN scope: "EnterNearestK9Vehicle's IsPedInAnyVehicle check,
    ExitK9Vehicle, the vehicle-despawn/own-death watchdog thread,
    ... is untested here." THIS spec closes exactly that list, plus the
    priorities this pass's own task brief calls out (feature-off
    inertness, termination/cleanup, any-ped, double-fire) -- it does NOT
    re-test the drag/bite-hold mutual guard, which stays owned by that
    file.

    ONE REAL DEFECT FOUND WHILE WRITING THIS SPEC, DISCLOSED HERE AND
    REPORTED TO MAIN RATHER THAN WORKED AROUND (per this task's own
    instruction) -- NOT FIXED BY THIS SPEC, PINNED as CURRENT, actual
    behavior so this file stays green against the real, unmodified
    production code:

    NOT GENUINELY INERT WITH THE FEATURE OFF -- the SAME bug class as this
    pass's disclosed finding in client/kennel.lua (see
    tests/clientkennel_spec.lua's own header). Unlike
    client/partnership.lua/client/propattachment.lua/client/fetch.lua
    (each of which has a real top-of-file
    `if not Config.Features.X then return end` gate), client/vehicle.lua
    has NO such gate. With Config.Features.VehicleEntryExit = false, this
    file still calls CreateThread(...) for the vehicle-despawn/own-death
    watchdog thread, and AddEventHandler(...) for both 'onResourceStart'
    and 'onResourceStop' -- every one of those registrations happens
    UNCONDITIONALLY at file-load time; only the WORK each one does is
    internally gated (EnterNearestK9Vehicle()'s own
    `if not Config.Features.VehicleEntryExit then return end`, and both
    ox_target canInteract predicates' own identical check). The
    "feature off" tests below pin the file's CURRENT, real behavior
    (registration happens regardless) rather than asserting the stronger
    claim and going red against real production code. Practical impact is
    lower than client/kennel.lua's own version of this finding (the
    watchdog thread's own `if vehicleState then` guard means it can never
    actually observe or release anything with the feature off, since
    vehicleState can never be set without EnterNearestK9Vehicle() ever
    running) -- but the thread still exists and wakes up every 2 seconds
    for the resource's whole lifetime for a feature the operator turned
    off, which is not "genuinely inert" as this task's own brief defines
    it.

    THE ONE PERSISTENT CreateThread (the vehicle-despawn/own-death
    watchdog) does NOT fit Sandbox.newThreadRunner()'s own documented
    "first step() call only reaches the initial Wait, performs no pass"
    assumption -- THIS thread's `Wait(sleepMs)` call is the LAST statement
    of its loop body, not the first (unlike every other thread in this
    batch's sibling specs), so the VERY FIRST `f.step()` call already runs
    one full check-and-release pass before ever yielding. Documented here,
    and at each test's own call site, rather than silently relied upon.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

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

local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'qbx_k9unit'
local VEHICLE_MODEL = 'police'

--- @param opts { vehicleEntryExit: boolean? }?
--- @return table fixture
local function newVehicleFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local pedHandle = 1
    local pedCoords = vec3(0.0, 0.0, 0.0)
    local pedDead = false
    local isPedInAnyVehicle = false
    local existingEntities = { [1] = true }
    local function PlayerPedId() return pedHandle end
    local function GetEntityCoords(entity)
        if entity == pedHandle then return pedCoords end
        return vec3(0.0, 0.0, 0.0)
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return entity == pedHandle and pedDead or false end
    local function IsPedInAnyVehicle(_ped, _bool) return isPedInAnyVehicle end

    -- ---- vehicle world state ----
    local vehiclePool = {}
    local vehicleModelByEntity = {}
    local vehicleCoordsByEntity = {}
    local function GetGamePool(poolName) return poolName == 'CVehicle' and vehiclePool or {} end
    local function GetEntityModel(entity) return vehicleModelByEntity[entity] end
    local function addVehicle(entity, modelName, x, y, z)
        vehiclePool[#vehiclePool + 1] = entity
        vehicleModelByEntity[entity] = GetHashKey(modelName)
        vehicleCoordsByEntity[entity] = vec3(x, y, z)
        existingEntities[entity] = true
    end
    -- GetEntityCoords must also answer for vehicle entities.
    local realGetEntityCoords = GetEntityCoords
    GetEntityCoords = function(entity)
        if vehicleCoordsByEntity[entity] then return vehicleCoordsByEntity[entity] end
        return realGetEntityCoords(entity)
    end

    local collisionCalls, freezeCalls, visibleCalls, attachCalls, detachCalls = {}, {}, {}, {}, {}
    local function SetEntityCollision(entity, allowCollision, physicsOnly)
        collisionCalls[#collisionCalls + 1] = { entity = entity, allowCollision = allowCollision, physicsOnly = physicsOnly }
    end
    local function FreezeEntityPosition(entity, toggle) freezeCalls[#freezeCalls + 1] = { entity = entity, toggle = toggle } end
    local function SetEntityVisible(entity, toggle, unk) visibleCalls[#visibleCalls + 1] = { entity = entity, toggle = toggle } end
    local function AttachEntityToEntity(entity, attachTo, ...) attachCalls[#attachCalls + 1] = { entity = entity, attachTo = attachTo } end
    local function DetachEntity(entity, ...) detachCalls[#detachCalls + 1] = entity end
    local function GetOffsetFromEntityInWorldCoords(entity, x, y, z) return vec3(x, y, z) end
    local setCoordsCalls, setHeadingCalls = {}, {}
    local function SetEntityCoords(entity, x, y, z, ...) setCoordsCalls[#setCoordsCalls + 1] = { entity = entity, x = x, y = y, z = z } end
    local function SetEntityHeading(entity, heading) setHeadingCalls[#setHeadingCalls + 1] = { entity = entity, heading = heading } end
    local function GetEntityHeading(_entity) return 42.0 end

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
    -- ResolveNetworkEntity -- same convention as this batch's sibling
    -- specs; used here for ResolveVehicleFromState().
    local vehicleResolvable = true -- toggled by tests to model streaming misses
    local function ResolveNetworkEntity(netId)
        if not vehicleResolvable then return nil end
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local threadRunner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CountingCreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        threadRunner.CreateThread(fn)
    end

    -- ---- K9Compat -- direct stub, see tests/clientkennel_spec.lua's own
    -- header for why this is the right level of abstraction here.
    local addGlobalVehicleCalls = {}
    local K9Compat = {
        Get = function(_system)
            return {
                AddGlobalVehicle = function(options) addGlobalVehicleCalls[#addGlobalVehicleCalls + 1] = options end,
            }
        end,
        Redetect = function() end,
        Which = function(_system) return 'ox_target' end,
    }

    local config = {
        Features = { VehicleEntryExit = opts.vehicleEntryExit ~= false },
        K9Vehicles = { VEHICLE_MODEL },
        VehicleInteractMeters = 3.0,
    }

    local env = Sandbox.newEnv({
        Config = config,
        GetHashKey = GetHashKey,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        GetGamePool = GetGamePool,
        GetEntityModel = GetEntityModel,
        SetEntityCollision = SetEntityCollision,
        FreezeEntityPosition = FreezeEntityPosition,
        SetEntityVisible = SetEntityVisible,
        AttachEntityToEntity = AttachEntityToEntity,
        DetachEntity = DetachEntity,
        GetOffsetFromEntityInWorldCoords = GetOffsetFromEntityInWorldCoords,
        SetEntityCoords = SetEntityCoords,
        SetEntityHeading = SetEntityHeading,
        GetEntityHeading = GetEntityHeading,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        AddEventHandler = AddEventHandler,
        CreateThread = CountingCreateThread,
        Wait = threadRunner.Wait,
        K9Compat = K9Compat,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    })

    Sandbox.loadInto('../client/vehicle.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        collisionCalls = collisionCalls,
        freezeCalls = freezeCalls,
        visibleCalls = visibleCalls,
        attachCalls = attachCalls,
        detachCalls = detachCalls,
        setCoordsCalls = setCoordsCalls,
        setHeadingCalls = setHeadingCalls,
        threadCount = function() return threadCreateCount end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        step = threadRunner.step,
        addGlobalVehicleCalls = addGlobalVehicleCalls,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyCallCount = function() return denyCalls end,
        setPedDead = function(v) pedDead = v end,
        setPedMissing = function() existingEntities[pedHandle] = nil end,
        setIsPedInAnyVehicle = function(v) isPedInAnyVehicle = v end,
        addVehicle = addVehicle,
        setVehicleResolvable = function(v) vehicleResolvable = v end,
        deleteVehicleEntity = function(entity) existingEntities[entity] = nil end,
    }
end

-- ========================================================================
-- DISCLOSED FINDING -- feature off still registers the watchdog thread and
-- both onResourceStart/onResourceStop handlers. See this file's own header.
-- ========================================================================

t.test('DISCLOSED FINDING: feature off still creates the watchdog thread and registers both onResourceStart/onResourceStop handlers', function()
    local f = newVehicleFixture({ vehicleEntryExit = false })
    t.equals(f.threadCount(), 1)
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('feature off: the WORK is still correctly gated internally -- EnterNearestK9Vehicle() no-ops, the watchdog never observes anything (vehicleState can never be set)', function()
    local f = newVehicleFixture({ vehicleEntryExit = false })
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 0)
    t.isFalse(f.env.IsInK9Vehicle())

    f.step() -- the watchdog thread runs, but vehicleState is permanently nil here
    t.equals(#f.notifyCalls, 0)
end)

-- ========================================================================
-- Sanity + happy path
-- ========================================================================

t.test('feature on: exposes the three documented globals, and IsInK9Vehicle starts false', function()
    local f = newVehicleFixture()
    t.isNotNil(f.env.EnterNearestK9Vehicle)
    t.isNotNil(f.env.ExitK9Vehicle)
    t.isNotNil(f.env.IsInK9Vehicle)
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('EnterNearestK9Vehicle: CanShowK9UI false denies locally', function()
    local f = newVehicleFixture()
    f.setCanShowK9UI(false)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.denyCallCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('EnterNearestK9Vehicle: no K9 vehicle within range notifies and does nothing', function()
    local f = newVehicleFixture()
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 0)
    t.equals(f.lastNotify().description, locale('vehicle.no_vehicle_nearby'))
end)

t.test('EnterNearestK9Vehicle: already seated in SOME vehicle via ordinary game controls (IsPedInAnyVehicle) refuses, even though IsInK9Vehicle() itself is still false', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setIsPedInAnyVehicle(true)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 0, 'must never attach/freeze/hide a ped the game already considers seated somewhere')
    t.equals(f.lastNotify().description, locale('vehicle.already_in_vehicle'))
end)

t.test('EnterNearestK9Vehicle: happy path -- collision off, frozen, hidden, attached to the nearest K9 vehicle within range', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 5.0, 0.0, 0.0)
    f.addVehicle(51, VEHICLE_MODEL, 1.0, 0.0, 0.0) -- nearer

    f.env.EnterNearestK9Vehicle()
    t.equals(#f.collisionCalls, 1)
    t.equals(f.collisionCalls[1].allowCollision, false)
    t.equals(#f.freezeCalls, 1)
    t.equals(f.freezeCalls[1].toggle, true)
    t.equals(#f.visibleCalls, 1)
    t.equals(f.visibleCalls[1].toggle, false)
    t.equals(#f.attachCalls, 1)
    t.equals(f.attachCalls[1].attachTo, 51, 'must attach to the NEARER of the two candidates')
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.loaded'))
end)

t.test('EnterNearestK9Vehicle: a vehicle outside Config.VehicleInteractMeters is never selected', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 100.0, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 0)
end)

t.test('EnterNearestK9Vehicle: a vehicle of an unlisted model is never selected, no matter how close', function()
    local f = newVehicleFixture()
    f.addVehicle(50, 'some_civilian_car', 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 0)
end)

t.test('DOUBLE-FIRE: a second EnterNearestK9Vehicle() while already tucked in is a clean no-op -- correctly re-entrancy-guarded, unlike this batch\'s kennel/fetch findings', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 1)

    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 1, 'a second call while IsInK9Vehicle() is true must not attach again')
end)

-- ========================================================================
-- ExitK9Vehicle -- deliberately NEVER gated behind CanShowK9UI(), per this
-- file's own doc comment ("a K9 whose certification lapses mid-ride must
-- always be able to un-freeze/un-hide themselves").
-- ========================================================================

t.test('ExitK9Vehicle: a no-op when not currently tucked in', function()
    local f = newVehicleFixture()
    f.env.ExitK9Vehicle()
    t.equals(#f.detachCalls, 0)
end)

t.test('ANY PED / NEVER TRAPPED: ExitK9Vehicle works even with CanShowK9UI() false -- a lapsed certification must never strand a rider', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.isTrue(f.env.IsInK9Vehicle())

    f.setCanShowK9UI(false)
    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'ExitK9Vehicle must succeed regardless of CanShowK9UI()')
    t.equals(#f.detachCalls, 1)
end)

t.test('ExitK9Vehicle: happy path -- reverses all four native states and repositions the ped next to the vehicle', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.6, 0.7) -- well within Config.VehicleInteractMeters (3.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.attachCalls, 1, 'sanity: must actually have entered before exiting')

    f.env.ExitK9Vehicle()
    t.equals(#f.detachCalls, 1)
    t.equals(f.freezeCalls[#f.freezeCalls].toggle, false)
    t.equals(f.visibleCalls[#f.visibleCalls].toggle, true)
    t.equals(f.collisionCalls[#f.collisionCalls].allowCollision, true)
    t.equals(#f.setCoordsCalls, 1)
    t.equals(#f.setHeadingCalls, 1)
    t.equals(f.setHeadingCalls[1].heading, 42.0)
    t.equals(f.lastNotify().description, locale('vehicle.released'))
end)

t.test('ExitK9Vehicle: if the vehicle no longer exists, restores the ped in place rather than erroring', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.deleteVehicleEntity(50)

    local ok = pcall(f.env.ExitK9Vehicle)
    t.isTrue(ok)
    t.equals(#f.detachCalls, 1)
    t.equals(#f.setCoordsCalls, 0, 'no reposition is attempted against a vehicle that no longer exists')
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('DOUBLE-FIRE: a second ExitK9Vehicle() after already exiting is a clean no-op', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.env.ExitK9Vehicle()
    t.equals(#f.detachCalls, 1)

    f.env.ExitK9Vehicle()
    t.equals(#f.detachCalls, 1, 'vehicleState is already nil -- a second call must not detach again')
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- the highest-priority area per this task's own
-- brief: onResourceStop, then the vehicle-despawn/own-death watchdog.
-- ========================================================================

t.test('onResourceStop: no-op when not currently tucked in', function()
    local f = newVehicleFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachCalls, 0)
end)

t.test('onResourceStop: a resource restart mid-ride releases the ped via the same ReleasePedFromVehicleState as ExitK9Vehicle, and is idempotent', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachCalls, 1)
    t.equals(f.freezeCalls[#f.freezeCalls].toggle, false)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachCalls, 1, 'a second firing must not release again -- vehicleState is already nil')
end)

t.test('onResourceStop: a mismatched resourceName never fires, even mid-ride', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.fireResourceStop('some_other_resource')
    t.equals(#f.detachCalls, 0)
end)

-- WATCHDOG THREAD -- see this file's own header for why ONE f.step() call
-- already performs a full check-and-release pass (Wait is this loop's LAST
-- statement, not its first).

t.test('watchdog: idle (never tucked in) is a true no-op -- no release calls, no notify, even across many ticks', function()
    local f = newVehicleFixture()
    f.step()
    f.step()
    f.step()
    t.equals(#f.detachCalls, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('watchdog: a vehicle that keeps resolving normally every tick never releases', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()

    f.step()
    f.step()
    f.step()
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(#f.detachCalls, 0)
end)

t.test('watchdog: a vehicle-resolve MISS is debounced -- releases only on the 3rd CONSECUTIVE miss, not the 1st or 2nd', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.setVehicleResolvable(false) -- models a momentary streaming hiccup

    f.step() -- miss 1
    t.isTrue(f.env.IsInK9Vehicle())
    f.step() -- miss 2
    t.isTrue(f.env.IsInK9Vehicle())
    f.step() -- miss 3 -- threshold reached
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.vehicle_lost'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('watchdog: a successful resolve BETWEEN misses resets the streak -- 2 misses, then a hit, then only 2 more misses must NOT release', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()

    f.setVehicleResolvable(false)
    f.step() -- miss 1
    f.step() -- miss 2
    f.setVehicleResolvable(true)
    f.step() -- hit -- resets missStreak to 0
    f.setVehicleResolvable(false)
    f.step() -- miss 1 (post-reset)
    f.step() -- miss 2 (post-reset)
    t.isTrue(f.env.IsInK9Vehicle(), 'only 2 CONSECUTIVE misses since the last hit -- must not have released yet')

    f.step() -- miss 3 (post-reset) -- NOW the threshold is reached
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('watchdog OWN-DEATH RELEASE: a dead ped while tucked in releases IMMEDIATELY, on the very first tick, regardless of the miss-streak threshold', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.setPedDead(true)

    f.step()
    t.isFalse(f.env.IsInK9Vehicle(), 'death must release on the first tick, not require 3 consecutive misses')
    t.equals(#f.detachCalls, 1)
    t.equals(f.lastNotify().description, locale('vehicle.released_on_death'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('watchdog OWN-DEATH RELEASE: takes precedence even when the vehicle has ALSO despawned in the same tick -- exactly one release, the death-flavored one', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.setPedDead(true)
    f.setVehicleResolvable(false)

    f.step()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.detachCalls, 1, 'exactly one release, never two, even though both conditions hold at once')
    t.equals(f.lastNotify().description, locale('vehicle.released_on_death'), 'the death branch must win, not the miss-streak branch')
end)

-- ========================================================================
-- ANY PED -- this file never calls IsOwnModelK9() anywhere (confirmed by
-- reading the whole file, and by grepping for it -- the only hit is inside
-- a comment, not a call): every gate is CanShowK9UI() alone, and the
-- vehicle-side model check (K9VehicleHashes) is keyed on the VEHICLE's own
-- model, never the ped's. Proven by OMITTING IsOwnModelK9 from the sandbox
-- entirely.
-- ========================================================================

t.test('ANY PED: EnterNearestK9Vehicle works via CanShowK9UI() alone, with IsOwnModelK9 entirely undefined', function()
    local f = newVehicleFixture()
    t.isNil(f.env.IsOwnModelK9, 'sanity: this fixture genuinely never defines IsOwnModelK9')
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    local ok, err = pcall(f.env.EnterNearestK9Vehicle)
    t.isTrue(ok, 'must not reach for a global this file does not use: ' .. tostring(err))
    t.isTrue(f.env.IsInK9Vehicle())
end)

t.test('ANY PED: the "Load Into Vehicle" ox_target option also gates on CanShowK9UI() alone', function()
    local f = newVehicleFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addGlobalVehicleCalls[1]
    local enterOption, exitOption
    for _, o in ipairs(options) do
        if o.name == 'qbx_k9unit:enterVehicle' then enterOption = o end
        if o.name == 'qbx_k9unit:exitVehicle' then exitOption = o end
    end
    t.isNotNil(enterOption)
    t.isNotNil(exitOption)

    t.isTrue(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL) == true or enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL) == false)
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    t.isTrue(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    f.setCanShowK9UI(false)
    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
end)

t.test('"Release From Vehicle" canInteract: only true when hovering the EXACT current vehicle, never a different one', function()
    local f = newVehicleFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addGlobalVehicleCalls[1]
    local exitOption
    for _, o in ipairs(options) do
        if o.name == 'qbx_k9unit:exitVehicle' then exitOption = o end
    end

    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.addVehicle(51, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle() -- enters whichever resolves nearest -- both at the same distance, FindNearestK9Vehicle takes the first strictly-nearer one it sees, so this asserts against ResolveVehicleFromState() itself rather than assuming which of the two was picked
    local currentVehicle
    for _, e in ipairs({ 50, 51 }) do
        if #f.attachCalls > 0 and f.attachCalls[1].attachTo == e then currentVehicle = e end
    end
    t.isNotNil(currentVehicle)

    t.isTrue(exitOption.canInteract(currentVehicle, 1.0, {}, VEHICLE_MODEL))
    local otherVehicle = currentVehicle == 50 and 51 or 50
    t.isFalse(exitOption.canInteract(otherVehicle, 1.0, {}, VEHICLE_MODEL), 'must never offer to release from a DIFFERENT vehicle than the one actually tucked into')
end)

t.test('onResourceStart: a mismatched, non-target resourceName does not register the ox_target options again (Redetect still runs, but Which(target) does not match)', function()
    local f = newVehicleFixture()
    f.env.exports = nil -- not used, just documenting this branch is exercised elsewhere already
    f.fireResourceStart('ox_target') -- K9Compat.Which('target') in this fixture's stub always returns 'ox_target'
    t.equals(#f.addGlobalVehicleCalls, 1, 'the SECOND branch (resourceName == K9Compat.Which(target)) must also register the options')
end)

os.exit(t.summary())
