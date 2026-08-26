--[[
    tests/clientvehicle_spec.lua

    Direct, black-box tests of client/vehicle.lua against the REAL,
    unmodified production file -- K9 vehicle entry/exit
    (Config.Features.VehicleEntryExit).

    REWRITTEN THIS PASS (owner-reported real defect: "put in vehicle" used
    to hide/freeze/attach the K9 to a boot/trunk offset -- invisible, wrong
    place). The production file now finds a genuinely free, non-driver seat
    (rear preferred), opens that seat's real door, SET_PED_INTO_VEHICLE's the
    ped for real (visible, collidable, a genuine game-recognized occupant --
    still PlayerPedId(), the player's own ped; nothing here ever spawns a
    ped of any kind, confirmed by grep having zero CreatePed/SetPlayerModel
    hits in the whole file), and shuts the door again. Every test below that
    used to assert on collisionCalls/freezeCalls/visibleCalls/attachCalls/
    detachCalls now asserts on the real-seat equivalents: seatCalls
    (SET_PED_INTO_VEHICLE), doorOpenCalls/doorShutCalls, and a
    pedCurrentVehicle model of "what vehicle does the game currently
    consider this ped seated in" that TASK_LEAVE_VEHICLE/
    CLEAR_PED_TASKS_IMMEDIATELY/the ped's own ordinary exit controls can all
    independently change -- see this fixture's own comments below for how
    that model works and why it exists.

    THREE DIFFERENT CreateThread LIFETIMES, never confused with each other
    (this fixture's central design constraint, same shape
    tests/vehiclecombatguard_spec.lua's own sibling fixture already
    establishes for the identical reason):
      1. The PERSISTENT watchdog thread (`while true do ... end`, no exit),
         created once at file-load time -- always capturedThreads[1].
      2. EnterNearestK9Vehicle()'s own one-shot door-open/seat/door-shut
         sequence -- created fresh by each call that gets far enough to
         need it (every guard above it passed).
      3. ExitK9Vehicle()'s own one-shot, bounded stall-fallback thread --
         created fresh by each call that gets far enough to need it (the
         ped was actually seated somewhere).
    The fixture's CreateThread stub CAPTURES every thread as a coroutine
    rather than running any of them automatically -- runLatestThreadToCompletion()
    explicitly drives whichever one was most recently created (#2 or #3,
    per whichever action a test just took) to completion or a bounded 50
    resumes, and stepWatchdogOnce() explicitly resumes ONLY
    capturedThreads[1], once. Never mixed: no test calls
    runLatestThreadToCompletion() when it means to drive the watchdog, or
    vice versa.

    SCOPE, DELIBERATELY NARROWED TO AVOID COLLIDING WITH
    tests/vehiclecombatguard_spec.lua: that file already thoroughly covers
    the mutual guard between EnterNearestK9Vehicle() and
    IsDragEngaged()/IsBiteHoldEngaged() (both directions) against this same
    production file, including the mid-delay re-check this pass added --
    this spec does not duplicate that coverage, only this file's OTHER
    behavior (seat/door selection, real termination/cleanup, any-ped,
    double-fire, per-person block, feature-off inertness).
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
local OTHER_VEHICLE_SENTINEL = 777 -- "some unrelated vehicle the ped got into via ordinary game controls"

--- @param opts { vehicleEntryExit: boolean? }?
--- @return table fixture
local function newVehicleFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as CanShowK9UI/DenyK9UIAccess
    -- above. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end
    local denyK9FeatureBlockedCallCount = 0
    local function DenyK9FeatureBlocked() denyK9FeatureBlockedCallCount = denyK9FeatureBlockedCallCount + 1 end

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local pedHandle = 1
    local pedCoords = vec3(0.0, 0.0, 0.0)
    local pedDead = false
    local existingEntities = { [pedHandle] = true, [OTHER_VEHICLE_SENTINEL] = true }

    -- ---- "what vehicle does the game currently consider this ped seated
    -- in" -- nil means not in any vehicle. This is the ONE piece of state
    -- every seating-related native reads and writes, modeling the real
    -- game's own seat bookkeeping (a single source of truth, same as the
    -- real engine has) rather than independent booleans that could drift
    -- out of sync with each other the way this fixture's OLD version's
    -- separate `isPedInAnyVehicle` flag and attach-call list could.
    local pedCurrentVehicle = nil

    local function PlayerPedId() return pedHandle end
    local function GetEntityCoords(entity)
        if entity == pedHandle then return pedCoords end
        return vec3(0.0, 0.0, 0.0)
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return entity == pedHandle and pedDead or false end
    local function IsPedInAnyVehicle(ped, _bool)
        return ped == pedHandle and pedCurrentVehicle ~= nil
    end
    local function GetVehiclePedIsIn(ped, _lastVehicle)
        if ped == pedHandle and pedCurrentVehicle then return pedCurrentVehicle end
        return 0
    end

    -- ---- vehicle world state ----
    local vehiclePool = {}
    local vehicleModelByEntity = {}
    local vehicleCoordsByEntity = {}
    local vehicleMaxPassengers = {}
    local occupiedSeats = {} -- occupiedSeats[vehicle][seatIndex] = true
    local function GetGamePool(poolName) return poolName == 'CVehicle' and vehiclePool or {} end
    local function GetEntityModel(entity) return vehicleModelByEntity[entity] end
    --- @param maxPassengers number? -- defaults to 3 (a standard 4-seat cruiser: seats -1..2)
    local function addVehicle(entity, modelName, x, y, z, maxPassengers)
        vehiclePool[#vehiclePool + 1] = entity
        vehicleModelByEntity[entity] = GetHashKey(modelName)
        vehicleCoordsByEntity[entity] = vec3(x, y, z)
        vehicleMaxPassengers[entity] = maxPassengers or 3
        existingEntities[entity] = true
    end
    -- GetEntityCoords must also answer for vehicle entities.
    local realGetEntityCoords = GetEntityCoords
    GetEntityCoords = function(entity)
        if vehicleCoordsByEntity[entity] then return vehicleCoordsByEntity[entity] end
        return realGetEntityCoords(entity)
    end

    local function GetVehicleMaxNumberOfPassengers(vehicle) return vehicleMaxPassengers[vehicle] or 3 end
    local function IsVehicleSeatFree(vehicle, seatIndex)
        return not (occupiedSeats[vehicle] and occupiedSeats[vehicle][seatIndex])
    end
    local function setSeatOccupied(vehicle, seatIndex, occupied)
        occupiedSeats[vehicle] = occupiedSeats[vehicle] or {}
        occupiedSeats[vehicle][seatIndex] = occupied or nil
    end

    local seatCalls, doorOpenCalls, doorShutCalls, networkControlCalls = {}, {}, {}, {}
    local function SetPedIntoVehicle(ped, vehicle, seatIndex)
        seatCalls[#seatCalls + 1] = { ped = ped, vehicle = vehicle, seatIndex = seatIndex }
        if ped == pedHandle then pedCurrentVehicle = vehicle end
    end
    local function SetVehicleDoorOpen(vehicle, doorIndex, loose, openInstantly)
        doorOpenCalls[#doorOpenCalls + 1] = { vehicle = vehicle, doorIndex = doorIndex, loose = loose, openInstantly = openInstantly }
    end
    local function SetVehicleDoorShut(vehicle, doorIndex, closeInstantly)
        doorShutCalls[#doorShutCalls + 1] = { vehicle = vehicle, doorIndex = doorIndex, closeInstantly = closeInstantly }
    end
    local function NetworkRequestControlOfEntity(entity)
        networkControlCalls[#networkControlCalls + 1] = entity
        return true
    end

    local taskLeaveVehicleCalls, clearTasksCalls = {}, {}
    local function TaskLeaveVehicle(ped, vehicle, flags)
        taskLeaveVehicleCalls[#taskLeaveVehicleCalls + 1] = { ped = ped, vehicle = vehicle, flags = flags }
        -- Deliberately does NOT clear pedCurrentVehicle -- in reality this
        -- is an animated task that takes real time to resolve, so this
        -- fixture never assumes it "worked" on its own; a test that wants
        -- to model the animation completing calls simulatePedExitedVehicle()
        -- explicitly, at whatever point in the timeline it chooses.
    end
    local function ClearPedTasksImmediately(ped)
        clearTasksCalls[#clearTasksCalls + 1] = ped
    end

    local setCoordsCalls, setHeadingCalls = {}, {}
    local function GetOffsetFromEntityInWorldCoords(entity, x, y, z) return vec3(x, y, z) end
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
    -- specs; used here for ResolveVehicleFromState() (purely a
    -- notification-wording decision in the new watchdog design -- see this
    -- file's own WATCHDOG section below).
    local vehicleResolvable = true
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

    -- CAPTURE, DON'T AUTO-RUN -- see this file's own header for the full
    -- "three different CreateThread lifetimes" rationale.
    local capturedThreads = {}
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        capturedThreads[#capturedThreads + 1] = coroutine.create(fn)
    end
    local function Wait(_ms) coroutine.yield() end

    --- Drives the MOST RECENTLY created thread to completion (or a bounded
    --- 50 resumes, so a genuine infinite-loop bug fails loudly instead of
    --- hanging this test process) -- see this file's header.
    local function runLatestThreadToCompletion()
        local co = capturedThreads[#capturedThreads]
        if not co then return end
        local iterations = 0
        while coroutine.status(co) ~= 'dead' and iterations < 50 do
            local ok, err = coroutine.resume(co)
            if not ok then
                error(('vehicle fixture: captured thread errored: %s'):format(tostring(err)))
            end
            iterations = iterations + 1
        end
    end

    --- Resumes ONLY the file-load-time watchdog thread (always
    --- capturedThreads[1]) exactly once.
    local function stepWatchdogOnce()
        local co = capturedThreads[1]
        if not co then return end
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('vehicle fixture: watchdog thread errored: %s'):format(tostring(err)))
        end
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

    local envOverrides = {
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
        GetVehiclePedIsIn = GetVehiclePedIsIn,
        GetGamePool = GetGamePool,
        GetEntityModel = GetEntityModel,
        GetVehicleMaxNumberOfPassengers = GetVehicleMaxNumberOfPassengers,
        IsVehicleSeatFree = IsVehicleSeatFree,
        SetPedIntoVehicle = SetPedIntoVehicle,
        SetVehicleDoorOpen = SetVehicleDoorOpen,
        SetVehicleDoorShut = SetVehicleDoorShut,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        TaskLeaveVehicle = TaskLeaveVehicle,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        GetOffsetFromEntityInWorldCoords = GetOffsetFromEntityInWorldCoords,
        SetEntityCoords = SetEntityCoords,
        SetEntityHeading = SetEntityHeading,
        GetEntityHeading = GetEntityHeading,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        AddEventHandler = AddEventHandler,
        CreateThread = CreateThread,
        Wait = Wait,
        K9Compat = K9Compat,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    }
    if featureBlocksAvailable then
        envOverrides.IsK9FeatureBlocked = IsK9FeatureBlocked
        envOverrides.DenyK9FeatureBlocked = DenyK9FeatureBlocked
    end
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../client/vehicle.lua', env)

    -- File load itself already creates ONE thread (the persistent
    -- watchdog) -- every test below cares about threads created SINCE
    -- fixture setup (i.e. by EnterNearestK9Vehicle()/ExitK9Vehicle() calls
    -- the test itself makes), not that baseline, so threadCount() below is
    -- reported net of it.
    local baselineThreadCount = threadCreateCount

    return {
        env = env,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        seatCalls = seatCalls,
        doorOpenCalls = doorOpenCalls,
        doorShutCalls = doorShutCalls,
        networkControlCalls = networkControlCalls,
        taskLeaveVehicleCalls = taskLeaveVehicleCalls,
        clearTasksCalls = clearTasksCalls,
        setCoordsCalls = setCoordsCalls,
        setHeadingCalls = setHeadingCalls,
        threadCount = function() return threadCreateCount - baselineThreadCount end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        runLatestThreadToCompletion = runLatestThreadToCompletion,
        stepWatchdogOnce = stepWatchdogOnce,
        addGlobalVehicleCalls = addGlobalVehicleCalls,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyCallCount = function() return denyCalls end,
        setPedDead = function(v) pedDead = v end,
        setPedMissing = function() existingEntities[pedHandle] = nil end,
        -- Models "the ped is seated in some vehicle via ordinary game
        -- controls, unrelated to this file's own bookkeeping" -- the
        -- pre-flight IS_PED_IN_ANY_VEHICLE guard's own scenario.
        setIsPedInAnyVehicle = function(v) pedCurrentVehicle = v and OTHER_VEHICLE_SENTINEL or nil end,
        -- Models the ped having actually, successfully left whatever
        -- vehicle it was in -- either its own ordinary "exit vehicle"
        -- control working unaided, or TASK_LEAVE_VEHICLE's animation
        -- finishing. Tests call this explicitly, at whatever point in a
        -- scenario's timeline they choose, rather than having it happen
        -- automatically.
        simulatePedExitedVehicle = function() pedCurrentVehicle = nil end,
        getPedCurrentVehicle = function() return pedCurrentVehicle end,
        addVehicle = addVehicle,
        setSeatOccupied = setSeatOccupied,
        setVehicleResolvable = function(v) vehicleResolvable = v end,
        -- Deletes the vehicle entity AND -- matching the real engine's own
        -- documented behavior (client/vehicle.lua's own header: "the game
        -- engine itself already force-ejects any occupant when their
        -- vehicle is deleted") -- clears pedCurrentVehicle if this ped was
        -- the one seated in it.
        deleteVehicleEntity = function(entity)
            existingEntities[entity] = nil
            if pedCurrentVehicle == entity then pedCurrentVehicle = nil end
        end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        denyK9FeatureBlockedCallCount = function() return denyK9FeatureBlockedCallCount end,
    }
end

-- ========================================================================
-- Feature-off inertness -- unaffected by this pass's real-seat rewrite,
-- kept as a straightforward regression check.
-- ========================================================================

t.test('feature off: creates no watchdog thread and registers neither onResourceStart nor onResourceStop', function()
    local f = newVehicleFixture({ vehicleEntryExit = false })
    t.equals(f.threadCount(), 0)
    t.equals(f.onResourceStartHandlerCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

t.test('feature off: none of EnterNearestK9Vehicle/ExitK9Vehicle/IsInK9Vehicle exist at all', function()
    local f = newVehicleFixture({ vehicleEntryExit = false })
    t.isNil(f.env.EnterNearestK9Vehicle)
    t.isNil(f.env.ExitK9Vehicle)
    t.isNil(f.env.IsInK9Vehicle)
end)

-- ========================================================================
-- Sanity + pre-flight guards
-- ========================================================================

t.test('feature on: exposes the three documented globals, and IsInK9Vehicle starts false', function()
    local f = newVehicleFixture()
    t.isNotNil(f.env.EnterNearestK9Vehicle)
    t.isNotNil(f.env.ExitK9Vehicle)
    t.isNotNil(f.env.IsInK9Vehicle)
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('EnterNearestK9Vehicle: CanShowK9UI false denies locally, creates no thread', function()
    local f = newVehicleFixture()
    f.setCanShowK9UI(false)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.denyCallCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.threadCount(), 0)
end)

t.test('EnterNearestK9Vehicle: no K9 vehicle within range notifies and does nothing', function()
    local f = newVehicleFixture()
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.lastNotify().description, locale('vehicle.no_vehicle_nearby'))
end)

t.test('EnterNearestK9Vehicle: already seated in SOME vehicle via ordinary game controls refuses, even though IsInK9Vehicle() itself is still false', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setIsPedInAnyVehicle(true)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0, 'must never try to seat a ped the game already considers seated somewhere')
    t.equals(f.threadCount(), 0)
    t.equals(f.lastNotify().description, locale('vehicle.already_in_vehicle'))
end)

t.test('EnterNearestK9Vehicle: a vehicle outside Config.VehicleInteractMeters is never selected', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 100.0, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0)
end)

t.test('EnterNearestK9Vehicle: a vehicle of an unlisted model is never selected, no matter how close', function()
    local f = newVehicleFixture()
    f.addVehicle(50, 'some_civilian_car', 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0)
end)

-- ========================================================================
-- REAL SEATING -- happy path, seat/door mapping, and "auto-find the best
-- spot" (rear preferred, never the driver's seat, never a taken seat, clear
-- refusal when nothing qualifies -- no silent fallback to anywhere else).
-- ========================================================================

t.test('happy path: opens the door, seats the ped for real (not attach/freeze/hide), shuts the door, becomes visible-and-collidable by construction (no collision/visibility natives touched at all)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 5.0, 0.0, 0.0)
    f.addVehicle(51, VEHICLE_MODEL, 1.0, 0.0, 0.0) -- nearer

    f.env.EnterNearestK9Vehicle()
    t.equals(f.threadCount(), 1, 'the door-open/seat/door-shut sequence runs in its own thread')
    t.isFalse(f.env.IsInK9Vehicle(), 'not seated yet -- still mid door-open delay')

    f.runLatestThreadToCompletion()

    t.equals(#f.doorOpenCalls, 1)
    t.equals(f.doorOpenCalls[1].vehicle, 51, 'must act on the NEARER of the two candidates')
    t.equals(#f.seatCalls, 1)
    t.equals(f.seatCalls[1].ped, 1)
    t.equals(f.seatCalls[1].vehicle, 51)
    t.equals(#f.doorShutCalls, 1)
    t.equals(f.doorShutCalls[1].vehicle, 51)
    t.equals(f.doorOpenCalls[1].doorIndex, f.doorShutCalls[1].doorIndex, 'opens and shuts the SAME door')
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.loaded'))
    t.equals(f.getPedCurrentVehicle(), 51, 'the ped is now a real, game-recognized occupant of the vehicle')
    t.isTrue(#f.networkControlCalls >= 1, 'must ask for network control of the vehicle at least once (client/combat.lua\'s established fire-and-forget pattern)')
end)

t.test('SEAT/DOOR MAPPING: rear-left (seat 1) is tried first on a standard 4-seat cruiser, and maps to door 1 (DSIDE_R), never door 2', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0) -- default maxPassengers = 3 -> seats -1..2, all free
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 1, 'rear, driver\'s side is first in the preference order')
    t.equals(f.doorOpenCalls[1].doorIndex, 1, 'seat 1 (back, driver\'s side) is door 1 (VEH_EXT_DOOR_DSIDE_R) -- NOT seatIndex+1 (which would wrongly be door 2, the front passenger door)')
end)

t.test('SEAT/DOOR MAPPING: seat 1 occupied falls back to seat 2 (rear, passenger\'s side) -> door 3 (PSIDE_R)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setSeatOccupied(50, 1, true)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 2)
    t.equals(f.doorOpenCalls[1].doorIndex, 3)
end)

t.test('SEAT/DOOR MAPPING: both rear seats occupied falls back to seat 0 (front passenger) -> door 2 (PSIDE_F), never the driver\'s seat -1', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setSeatOccupied(50, 1, true)
    f.setSeatOccupied(50, 2, true)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 0)
    t.equals(f.doorOpenCalls[1].doorIndex, 2)
end)

t.test('NEVER THE TRUNK, NEVER THE DRIVER: every non-driver seat occupied refuses with a clear reason, no seat/door call at all', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setSeatOccupied(50, 0, true)
    f.setSeatOccupied(50, 1, true)
    f.setSeatOccupied(50, 2, true)
    f.env.EnterNearestK9Vehicle()

    t.equals(f.threadCount(), 0, 'must refuse synchronously -- never even start the door-open sequence')
    t.equals(#f.seatCalls, 0)
    t.equals(#f.doorOpenCalls, 0)
    t.equals(f.lastNotify().description, locale('vehicle.no_seat_available'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('a 2-seat vehicle (maxPassengers = 1, no rear seats at all) correctly falls back to the front passenger seat', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0, 1) -- maxPassengers=1 -> valid seats -1..0 only
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 0)
    t.isTrue(f.env.IsInK9Vehicle())
end)

t.test('MID-DELAY ABORT: the vehicle is deleted during the door-open delay -- aborts, shuts nothing (nothing left to shut), never seats', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.doorOpenCalls, 1, 'the door open call already fired before the delay')

    f.deleteVehicleEntity(50) -- something else deletes it mid-delay
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0, 'must never seat the ped once the vehicle is confirmed gone')
    t.equals(#f.doorShutCalls, 0, 'nothing left to shut a door on')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('MID-DELAY ABORT: the chosen seat fills up during the door-open delay -- aborts, shuts the door back, never displaces whoever took it', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle() -- picks seat 1 (rear, driver's side)

    f.setSeatOccupied(50, 1, true) -- someone else takes it mid-delay
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0, 'must never force the seat once it is genuinely occupied')
    t.equals(#f.doorShutCalls, 1, 'the door this file opened must still be shut again')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.no_seat_available'))
end)

t.test('MID-DELAY ABORT: the ped dies during the door-open delay -- aborts rather than seating a corpse', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()

    f.setPedDead(true)
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('DOUBLE-FIRE: a second EnterNearestK9Vehicle() while already tucked in is a clean no-op', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)

    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 1, 'a second call while IsInK9Vehicle() is true must not seat again')
    t.equals(f.threadCount(), 1, 'must not even start a second sequence')
end)

t.test('DOUBLE-FIRE: a second EnterNearestK9Vehicle() DURING the door-open delay (before the first has finished) is also a clean no-op -- vehicleEntryInProgress guard', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.threadCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle(), 'sanity: still mid-delay, not seated yet')

    f.env.EnterNearestK9Vehicle() -- double-click during the animation window
    t.equals(f.threadCount(), 1, 'must not start a second concurrent sequence against the same ped')

    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'exactly one seat call, from the original sequence only')
    t.isTrue(f.env.IsInK9Vehicle())
end)

-- ========================================================================
-- ExitK9Vehicle -- deliberately NEVER gated behind CanShowK9UI(). Real
-- seating changes what "exit" means: vehicleState clears synchronously and
-- immediately, a graceful TASK_LEAVE_VEHICLE is issued, and a bounded
-- courtesy thread force-ejects the ped if that animation never actually
-- finishes (owner's own "bulletproof" requirement).
-- ========================================================================

t.test('ExitK9Vehicle: a no-op when not currently tucked in', function()
    local f = newVehicleFixture()
    f.env.ExitK9Vehicle()
    t.equals(#f.taskLeaveVehicleCalls, 0)
end)

t.test('ExitK9Vehicle: already out via ordinary game controls before this was ever called -- clears state silently, no task, no notify', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())

    f.simulatePedExitedVehicle() -- the player used the ordinary "exit vehicle" control themselves
    local notifyCountBefore = #f.notifyCalls
    f.env.ExitK9Vehicle()

    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.taskLeaveVehicleCalls, 0, 'nothing left to do -- must not re-issue a leave task for a ped already out')
    t.equals(#f.notifyCalls, notifyCountBefore, 'nothing new to tell the player -- they already know they got out')
end)

t.test('ANY PED / NEVER TRAPPED: ExitK9Vehicle works even with CanShowK9UI() false -- a lapsed certification must never strand a rider', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())

    f.setCanShowK9UI(false)
    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'ExitK9Vehicle must succeed regardless of CanShowK9UI()')
    t.equals(#f.taskLeaveVehicleCalls, 1)
    t.equals(f.taskLeaveVehicleCalls[1].flags, 0, 'the graceful, animated exit flag')
end)

t.test('ExitK9Vehicle: happy path -- the animation genuinely finishes before the fallback timeout, no hard eject needed', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'vehicleState clears immediately and synchronously, before the animation even finishes')
    t.equals(#f.taskLeaveVehicleCalls, 1)
    t.equals(f.taskLeaveVehicleCalls[1].vehicle, 50)
    t.equals(f.lastNotify().description, locale('vehicle.released'))

    f.simulatePedExitedVehicle() -- the animation finishes cleanly, well within the fallback window
    f.runLatestThreadToCompletion() -- the courtesy fallback thread's very first check already sees the ped out
    t.equals(#f.clearTasksCalls, 0, 'the hard fallback must never fire once the graceful exit already worked')
    t.equals(#f.taskLeaveVehicleCalls, 1, 'no second, hard TASK_LEAVE_VEHICLE call either')
end)

t.test('BULLETPROOF EXIT: the graceful animation stalls (door jammed, etc.) -- the courtesy fallback force-ejects an ALIVE ped via a second, hard TASK_LEAVE_VEHICLE (flag 16)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    f.env.ExitK9Vehicle()
    -- Deliberately do NOT call simulatePedExitedVehicle() -- models the
    -- animation never actually completing.
    f.runLatestThreadToCompletion() -- drives the fallback thread through its full bounded wait

    t.equals(#f.taskLeaveVehicleCalls, 2, 'the original graceful call, plus the hard fallback')
    t.equals(f.taskLeaveVehicleCalls[2].flags, 16, '"teleports outside, door kept closed" per TASK_LEAVE_VEHICLE\'s own documented flag semantics')
    t.equals(#f.clearTasksCalls, 0, 'the alive path uses TASK_LEAVE_VEHICLE, not the dead-ped CLEAR_PED_TASKS_IMMEDIATELY path')
end)

t.test('BULLETPROOF EXIT: the ped dies before the graceful animation resolves -- the fallback uses CLEAR_PED_TASKS_IMMEDIATELY + reposition instead, never a task a dead ped cannot run', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    f.env.ExitK9Vehicle()
    f.setPedDead(true)
    f.runLatestThreadToCompletion()

    t.equals(#f.clearTasksCalls, 1)
    t.isTrue(#f.setCoordsCalls >= 1, 'must still reposition the ped away from the vehicle')
    t.equals(#f.taskLeaveVehicleCalls, 1, 'only the original graceful call -- the dead-ped fallback path never calls TASK_LEAVE_VEHICLE at all')
end)

t.test('DOUBLE-FIRE: a second ExitK9Vehicle() after already exiting is a clean no-op', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    f.env.ExitK9Vehicle()
    t.equals(#f.taskLeaveVehicleCalls, 1)

    f.env.ExitK9Vehicle()
    t.equals(#f.taskLeaveVehicleCalls, 1, 'vehicleState is already nil -- a second call must not issue another leave task')
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- onResourceStop, then the persistent watchdog.
-- NEVER GATE A TERMINATION PATH: neither of these checks
-- Config.Features.VehicleEntryExit, CanShowK9UI(), or any feature-block --
-- only whether there is an active ride to release at all.
-- ========================================================================

t.test('onResourceStop: no-op when not currently tucked in', function()
    local f = newVehicleFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.equals(#f.clearTasksCalls, 0)
end)

t.test('onResourceStop: a resource restart mid-ride hard-ejects an ALIVE ped via TASK_LEAVE_VEHICLE flag 16, synchronously (no thread, no Wait)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    local threadCountBefore = f.threadCount()

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.taskLeaveVehicleCalls, 1)
    t.equals(f.taskLeaveVehicleCalls[1].flags, 16)
    t.equals(f.threadCount(), threadCountBefore, 'a termination path must resolve synchronously -- no new thread, no Wait')
    t.isFalse(f.env.IsInK9Vehicle())

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.taskLeaveVehicleCalls, 1, 'a second firing must not release again -- vehicleState is already nil')
end)

t.test('onResourceStop: a dead ped mid-ride is hard-ejected via CLEAR_PED_TASKS_IMMEDIATELY + reposition, not TASK_LEAVE_VEHICLE', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    f.setPedDead(true)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.clearTasksCalls, 1)
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.isTrue(#f.setCoordsCalls >= 1)
end)

t.test('onResourceStop: a mismatched resourceName never fires, even mid-ride', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    f.fireResourceStop('some_other_resource')
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.isTrue(f.env.IsInK9Vehicle())
end)

-- WATCHDOG THREAD -- substantially redesigned this pass (see
-- client/vehicle.lua's own header for the full "why the old missStreak
-- debounce no longer applies" reasoning): the primary release decision now
-- reads IsPedInAnyVehicle on this client's own local ped (always reliable,
-- no streaming dependency), so there is no debounce left to test for the
-- release decision itself -- only for which of two notification strings
-- gets shown, which is cosmetic, not a stranding risk.

t.test('watchdog: idle (never tucked in) is a true no-op across many ticks', function()
    local f = newVehicleFixture()
    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    t.equals(#f.notifyCalls, 0)
end)

t.test('watchdog: still genuinely seated -- no release, across many ticks', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.equals(#f.clearTasksCalls, 0)
end)

t.test('watchdog: the ped exits via ordinary game controls -- releases silently on the very next tick, no notify (they already know)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    f.simulatePedExitedVehicle()
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.notifyCalls, 1, 'no new notify beyond the original "loaded" one')
end)

t.test('watchdog: the vehicle is deleted out from under the ped (engine auto-ejects) -- releases AND notifies vehicle_lost, since the vehicle itself is genuinely gone', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()

    f.deleteVehicleEntity(50) -- this fixture's own deleteVehicleEntity() models the engine's auto-eject too
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.vehicle_lost'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('watchdog OWN-DEATH RELEASE: a dead ped while tucked in releases IMMEDIATELY on the very first tick, hard-ejecting via CLEAR_PED_TASKS_IMMEDIATELY + reposition', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    f.setPedDead(true)

    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.clearTasksCalls, 1)
    t.isTrue(#f.setCoordsCalls >= 1)
    t.equals(f.lastNotify().description, locale('vehicle.released_on_death'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('watchdog OWN-DEATH RELEASE: takes precedence even when the vehicle has ALSO despawned in the same tick -- exactly one release, the death-flavored one', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    f.setPedDead(true)
    f.setVehicleResolvable(false)

    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.released_on_death'), 'the death branch must win, not the vehicle-lost branch')
    local deathNotifyCount = 0
    for _, n in ipairs(f.notifyCalls) do
        if n.description == locale('vehicle.released_on_death') then deathNotifyCount = deathNotifyCount + 1 end
    end
    t.equals(deathNotifyCount, 1, 'exactly one release notify, never two')
end)

-- ========================================================================
-- ANY PED -- this file never calls IsOwnModelK9() anywhere: every gate is
-- CanShowK9UI() alone, and the vehicle-side model check (K9VehicleHashes)
-- is keyed on the VEHICLE's own model, never the ped's. The seated entity
-- is always, and only, PlayerPedId() -- the player's own ped -- confirmed
-- by grep having zero CreatePed/SetPlayerModel/other ped-spawning native
-- hits anywhere in client/vehicle.lua; nothing in this file, before or
-- after this pass, ever spawns a decorative or stand-in ped of any kind.
-- ========================================================================

t.test('ANY PED: EnterNearestK9Vehicle works via CanShowK9UI() alone, with IsOwnModelK9 entirely undefined', function()
    local f = newVehicleFixture()
    t.isNil(f.env.IsOwnModelK9, 'sanity: this fixture genuinely never defines IsOwnModelK9')
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    local ok, err = pcall(f.env.EnterNearestK9Vehicle)
    t.isTrue(ok, 'must not reach for a global this file does not use: ' .. tostring(err))
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(f.seatCalls[1].ped, 1, 'the seated entity is PlayerPedId() -- the player\'s own ped -- never a spawned stand-in')
end)

t.test('ANY PED: the "Get in the Back Seat" ox_target option also gates on CanShowK9UI() alone, and hides when every seat is genuinely taken', function()
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

    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    t.isTrue(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    f.setCanShowK9UI(false)
    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    f.setCanShowK9UI(true)

    f.setSeatOccupied(50, 0, true)
    f.setSeatOccupied(50, 1, true)
    f.setSeatOccupied(50, 2, true)
    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL), 'hides the option once every non-driver seat is genuinely occupied, coder-frontend\'s own "never show an option that will just refuse" ask')
end)

t.test('"Get Out of the Vehicle" canInteract: only true when hovering the EXACT current vehicle, never a different one', function()
    local f = newVehicleFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addGlobalVehicleCalls[1]
    local exitOption
    for _, o in ipairs(options) do
        if o.name == 'qbx_k9unit:exitVehicle' then exitOption = o end
    end

    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.addVehicle(51, VEHICLE_MODEL, 1.0, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle() -- nearest is 50
    f.runLatestThreadToCompletion()

    t.isTrue(exitOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    t.isFalse(exitOption.canInteract(51, 1.0, {}, VEHICLE_MODEL), 'must never offer to release from a DIFFERENT vehicle than the one actually tucked into')
end)

t.test('onResourceStart: the SECOND branch (resourceName == K9Compat.Which(target)) also registers the options', function()
    local f = newVehicleFixture()
    f.fireResourceStart('ox_target') -- K9Compat.Which('target') in this fixture's stub always returns 'ox_target'
    t.equals(#f.addGlobalVehicleCalls, 1)
end)

-- ========================================================================
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- checked inside
-- EnterNearestK9Vehicle() itself. ExitK9Vehicle() stays completely
-- untouched -- termination must never be gated.
-- ========================================================================

t.test('EnterNearestK9Vehicle: VehicleEntryExit blocked -- denies via DenyK9FeatureBlocked, never seats, never starts a thread', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setBlocked('VehicleEntryExit', true)

    f.env.EnterNearestK9Vehicle()

    t.equals(#f.seatCalls, 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.denyK9FeatureBlockedCallCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('EnterNearestK9Vehicle: a block on a DIFFERENT feature name never affects VehicleEntryExit', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setBlocked('NightVision', true)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
end)

t.test('ExitK9Vehicle: a block on VehicleEntryExit never refuses exiting -- termination must never be gated', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())

    f.setBlocked('VehicleEntryExit', true)
    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'a block must never prevent exiting an already-entered vehicle')
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- entry works exactly as before this pass', function()
    local f = newVehicleFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'an unknown block state must never freeze this ability -- it must fail OPEN')
end)

os.exit(t.summary())
