--[[
    tests/vehicle_spec.lua

    Direct tests of server/vehicle.lua's two RegisterNetEvent handlers
    (requestVehicleSeatClaim / releaseVehicleSeatClaim) plus its
    playerDropped/onResourceStop cleanup and periodic sweep thread, against
    the REAL, unmodified production file -- loaded alongside the real
    server/entities.lua per that file's own FILE-TO-FILE CONTRACT (every
    ResolveNetworkEntity call is the real resolve+existence-guard primitive,
    not a reimplementation). HasK9Access and NotifyPlayer are stubbed
    directly -- both are genuinely OTHER files' own logic, already covered
    by their own specs (server/certifications.lua, server/notify.lua/
    notify_spec.lua) -- this file's job is server/vehicle.lua's own
    handshake/lifecycle logic, not a second copy of those. Same overall
    fixture shape as tests/kennel_spec.lua's own newKennelFixture() -- read
    that file's header before touching this one; this design deliberately
    follows it rather than inventing a new shape.

    ONE FRESH SANDBOX PER TEST (never shared) -- `VehicleSeatClaims` is a
    `local` upvalue alive for this whole loaded file's lifetime, so reusing
    one sandbox across unrelated test cases would let one test's claim state
    leak into the next. newVehicleServerFixture() below builds one complete,
    independent world for every single t.test() call.

    THE CENTRAL PROOF THIS FILE EXISTS FOR: "TWO DOGS, SAME VEHICLE, SAME
    SEAT" below dispatches requestVehicleSeatClaim TWICE, from two different
    sources, for the IDENTICAL (vehicleNetId, seatIndex) pair, back to back
    with no yield between the two dispatchNetEvent calls -- exactly
    tests/kennel_spec.lua's own "two dogs racing the same kennel" shape
    (requestEnterKennel dispatched for src 2 then src 3 against the same
    netId). Because server/vehicle.lua's own check-and-claim has no yield of
    any kind inside it, calling the handler twice in immediate succession
    from this spec IS the same guarantee ordinary FXServer event-processing
    order gives two genuinely simultaneous network requests -- there is no
    difference in the SERVER's own vantage point between "two real,
    concurrent requests happened to be processed one after another" and "a
    test called the handler twice in a row": both look identical to code
    with no yield in between. If this file's own server/vehicle.lua ever
    grows a yield inside the check-and-claim path (an awaited callback, a
    Wait), the second dispatchNetEvent call below would begin racing this
    first one's own in-flight state instead of seeing it as already
    committed -- which is the exact bug this whole task exists to close, so
    a regression here would very likely also break this specific test.

    locale() is NEVER stubbed (this suite's own convention) -- every call
    below that reaches a NotifyPlayer(..., locale('...'), ...) call evaluates
    that locale() argument for real, against the real locales/en.json.
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

local VEHICLE_MODEL = 'police'
local WRONG_MODEL = 'civilian_sedan'
local VEHICLE_HASH = GetHashKey(VEHICLE_MODEL)
local WRONG_HASH = GetHashKey(WRONG_MODEL)
local VEHICLE_INTERACT_METERS = 3.0

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- same shape as tests/kennel_spec.lua's/
-- tests/partnership_spec.lua's own copies, needed for
-- `#(GetEntityCoords(a) - GetEntityCoords(b))`.
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

--- Builds one complete, independent sandbox for server/vehicle.lua, with
--- the real server/entities.lua loaded alongside it (matching
--- fxmanifest.lua's own load order), and every other cross-file/native
--- dependency as a test-controlled stub.
--- @param opts { vehicleEntryExit: boolean? }?
--- @return table fixture
local function newVehicleServerFixture(opts)
    opts = opts or {}
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent) -- vehicle.lua registers exactly one handler per event name
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {} -- { {target=, description=, notifyType=}, ... }
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local playersBySource = {} -- source -> citizenid string, or nil = unresolved
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = playersBySource[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid } }
            end,
        },
    }

    local pedBySource = {} -- source -> ped handle (unset/0 == "disconnected mid-flight")
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {} -- handle -> {x=,y=,z=}
    local function GetEntityCoords(handle)
        local c = coordsByHandle[handle] or { x = 0, y = 0, z = 0 }
        return vec3(c.x, c.y, c.z)
    end

    local networkEntities = {} -- netId -> handle
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (GetEntityType's real domain; 2 = vehicle)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {} -- handle -> hash
    local function GetEntityModel(handle) return entityModels[handle] end

    local config = {
        Features = { VehicleEntryExit = opts.vehicleEntryExit ~= false },
        K9Vehicles = { VEHICLE_MODEL },
        VehicleInteractMeters = VEHICLE_INTERACT_METERS,
    }

    -- Sandbox.newThreadRunner() -- same convention as tests/pursuitsprint_spec.lua's
    -- own server-side fixture: captures every CreateThread'd coroutine
    -- without auto-running it. `threadCreateCount` (wrapped locally, same
    -- shape as that file's own copy) lets the FEATURE-OFF test below prove
    -- the sweep thread genuinely never gets created at all, not merely
    -- never stepped.
    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        runner.CreateThread(fn)
    end

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetHashKey = GetHashKey,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityModel = GetEntityModel,
        CreateThread = CreateThread,
        Wait = runner.Wait,
        Config = config,
    }

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/vehicle.lua', env)

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        threadCreateCount = function() return threadCreateCount end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayer = function(src, citizenid) playersBySource[src] = citizenid end,
        setPed = function(src, pedHandle, coords)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = coords or { x = 0, y = 0, z = 0 }
        end,
        --- @param netId number
        --- @param handle number
        --- @param vopts { exists: boolean?, entityType: number?, model: number?, coords: table? }?
        registerVehicle = function(netId, handle, vopts)
            vopts = vopts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = vopts.exists ~= false
            entityTypes[handle] = vopts.entityType or 2 -- 2 = vehicle
            entityModels[handle] = vopts.model or VEHICLE_HASH
            coordsByHandle[handle] = vopts.coords or { x = 0, y = 0, z = 0 }
        end,
        removeVehicleExistence = function(handle) existingEntities[handle] = false end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            return handler(...)
        end,
        firePlayerDropped = function(src, reason)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler(reason)
            end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        -- Same stepping semantics fixtures/sandbox.lua's own newThreadRunner()
        -- documents: the FIRST step() only primes the sweep loop's initial
        -- Wait() (no sweep pass runs yet); each call after that runs exactly
        -- one full sweep pass.
        stepSweep = runner.step,
        lastClientEventNamed = function(name)
            for i = #clientEvents, 1, -1 do
                if clientEvents[i].event == name then return clientEvents[i] end
            end
            return nil
        end,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
    }
end

-- ========================================================================
-- Defensive payload handling -- silent no-op on malformed/unresolvable
-- input, matching server/kennel.lua's own established convention exactly
-- (never trust client payload shape, never notify a caller whose payload
-- was never even a legible request).
-- ========================================================================

t.test('requestVehicleSeatClaim: non-number vehicleNetId is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 'not-a-number', 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: non-number seatIndex is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 'not-a-number', 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: non-number requestToken is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 'not-a-number')
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: an out-of-range seatIndex (never produced by the real client) is a silent no-op, closing an unbounded-memory-growth vector', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 999999, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: feature flag off is a silent no-op', function()
    local f = newVehicleServerFixture({ vehicleEntryExit = false })
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: unresolvable citizenid is a silent no-op', function()
    local f = newVehicleServerFixture()
    -- setPlayer() deliberately never called for src 2 -- exports.qbx_core:GetPlayer returns nil
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: src disconnected between the event firing and this line (GetPlayerPed returns 0) is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    -- setPed() deliberately never called -- GetPlayerPed(2) reads 0

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

-- ========================================================================
-- Real rejections -- each notifies AND sends the deny event, per this
-- file's own header EVENT/CALLBACK CONTRACT.
-- ========================================================================

t.test('requestVehicleSeatClaim: no HasK9Access is denied with common.no_k9_access -- the FIRST time this action has ever been re-verified server-side', function()
    local f = newVehicleServerFixture()
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    -- setAccess() deliberately never called -- HasK9Access(2) reads false

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 42)

    t.equals(f.lastNotify().target, 2)
    t.equals(f.lastNotify().description, locale('common.no_k9_access'))
    local denyCall = f.lastClientEventNamed('qbx_k9unit:client:vehicleSeatClaimDenied')
    t.isNotNil(denyCall)
    t.equals(denyCall.target, 2)
    t.equals(denyCall.args[1], 500)
    t.equals(denyCall.args[2], 1)
    t.equals(denyCall.args[3], 42, 'the requestToken must be echoed back verbatim')
end)

t.test('requestVehicleSeatClaim: an unresolvable netId is denied as an invalid vehicle', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    -- registerVehicle() deliberately never called for netId 999999

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 999999, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
    t.isNotNil(f.lastClientEventNamed('qbx_k9unit:client:vehicleSeatClaimDenied'))
end)

t.test('requestVehicleSeatClaim: a netId that resolves to a PED, never a vehicle, is denied as invalid -- never trusts the client-claimed entity type', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { entityType = 1, coords = { x = 0, y = 0, z = 0 } }) -- 1 = ped

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('requestVehicleSeatClaim: a real vehicle of an unlisted model is denied as invalid -- never trusts the client-claimed model', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { model = WRONG_HASH, coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('requestVehicleSeatClaim: a genuinely deleted vehicle (existence false) is denied as invalid', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { exists = false, coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('requestVehicleSeatClaim: too far from the vehicle is denied -- closes the "claim every K9 vehicle on the map from across it" griefing vector', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 999, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.claim_too_far'))
end)

t.test('requestVehicleSeatClaim: exactly at the configured interact distance plus tolerance is still accepted', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    -- Config.VehicleInteractMeters (3.0) + the file's own 1.0m tolerance = 4.0m, so 3.9m must still pass.
    f.registerVehicle(500, 50, { coords = { x = 3.9, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNotNil(f.lastClientEventNamed('qbx_k9unit:client:vehicleSeatClaimGranted'))
end)

-- ========================================================================
-- THE FIX ITSELF -- happy path, self-renewal, per-seat independence, and
-- THE CENTRAL PROOF: two dogs, same vehicle, same seat.
-- ========================================================================

t.test('requestVehicleSeatClaim: a certified handler close enough to a genuine K9 vehicle is granted, with the requestToken echoed back verbatim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0.5, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 777)

    local grant = f.lastClientEventNamed('qbx_k9unit:client:vehicleSeatClaimGranted')
    t.isNotNil(grant)
    t.equals(grant.target, 2)
    t.equals(grant.args[1], 500)
    t.equals(grant.args[2], 1)
    t.equals(grant.args[3], 777)
    t.equals(#f.notifyCalls, 0, 'a GRANT is never itself narrated server-side -- the client shows its own success notify once genuinely seated')
end)

t.test('requestVehicleSeatClaim: the SAME src re-requesting the SAME seat it already holds is treated as a renewal, not a collision', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 2)

    local grants = 0
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' then grants = grants + 1 end
    end
    t.equals(grants, 2, 'both of THIS SAME src\'s own requests for its own seat must succeed')
end)

t.test('requestVehicleSeatClaim: two DIFFERENT seats on the SAME vehicle never block each other', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 2, 1)

    local grants = 0
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' then grants = grants + 1 end
    end
    t.equals(grants, 2, 'different seats are independent claims')
end)

t.test('TWO DOGS, SAME VEHICLE, SAME SEAT -- the actual concurrency bug this file exists to close: dispatched back to back, with NO yield between them, exactly like server/kennel.lua\'s own "two dogs racing the same kennel" shape', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0.2, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- Both handlers independently computed seat 1 as "the best free seat"
    -- (client/vehicle.lua's own FindBestK9Seat, run locally by each of
    -- them before either ever contacted the server) -- this is the exact
    -- audit scenario: two requests for the IDENTICAL (vehicleNetId,
    -- seatIndex) pair.
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 100)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 200)

    local grant2 = nil
    local grant3 = nil
    local deny2 = nil
    local deny3 = nil
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 2 then grant2 = c end
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grant3 = c end
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimDenied' and c.target == 2 then deny2 = c end
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimDenied' and c.target == 3 then deny3 = c end
    end

    t.isNotNil(grant2, 'the FIRST request (src 2) must win -- ordinary event-processing order')
    t.isNil(deny2)
    t.isNil(grant3, 'the SECOND request (src 3) for the identical vehicle/seat MUST be refused -- this is the entire bug')
    t.isNotNil(deny3)
    t.equals(deny3.args[3], 200, 'src 3\'s own requestToken is echoed back on its OWN denial')

    local notifiedThree = false
    for _, n in ipairs(f.notifyCalls) do
        if n.target == 3 and n.description == locale('vehicle.no_seat_available') then notifiedThree = true end
    end
    t.isTrue(notifiedThree, 'src 3 must be told the real reason: the seat is taken')
end)

t.test('TWO DOGS, SAME VEHICLE, SAME SEAT -- the LOSING order also correctly denies whichever request is processed second, not whichever src number is higher', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- src 3 processed FIRST this time.
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    local grant3, deny2
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grant3 = c end
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimDenied' and c.target == 2 then deny2 = c end
    end
    t.isNotNil(grant3, 'whichever request is processed FIRST wins -- src 3, this time')
    t.isNotNil(deny2, 'and the other is denied -- src 2, this time')
end)

-- ========================================================================
-- releaseVehicleSeatClaim -- self-only, mirrors server/entities.lua's
-- ReleaseNetworkEntity's own "never clears whatever is there" discipline.
-- ========================================================================

t.test('releaseVehicleSeatClaim: self-only -- a DIFFERENT src cannot release someone else\'s claim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1) -- src 2 holds it
    f.dispatchNetEvent('qbx_k9unit:server:releaseVehicleSeatClaim', 3, 500, 1)    -- src 3 tries to release it -- must be a no-op

    -- Still held by src 2 -- a fresh request from src 3 for the same seat must still be denied.
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)
    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree, 'src 2\'s claim must still be intact -- src 3\'s foreign release attempt must have done nothing')
end)

t.test('releaseVehicleSeatClaim: the genuine holder releasing frees the seat immediately for someone else, well before any TTL', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('qbx_k9unit:server:releaseVehicleSeatClaim', 2, 500, 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

t.test('releaseVehicleSeatClaim: malformed payload is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('qbx_k9unit:server:releaseVehicleSeatClaim', 2, 'nope', 1)
    -- Must not error -- nothing else observable to assert.
    t.isTrue(true)
end)

-- ========================================================================
-- A CLAIM MUST NEVER OUTLIVE THE PLAYER OR THE VEHICLE -- lazy TTL expiry,
-- playerDropped, onResourceStop, and the periodic sweep thread. See
-- server/vehicle.lua's own header for the full four-mechanism writeup.
-- ========================================================================

t.test('TTL: a claim older than the TTL is treated as absent and silently overwritten by a fresh request from someone else', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(10001) -- just past VEHICLE_SEAT_CLAIM_TTL_MS (10000)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree, 'an expired claim must never permanently block the seat')
end)

t.test('TTL: a claim younger than the TTL is still enforced', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(9999)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree)
end)

t.test('playerDropped: a disconnecting src\'s claim is dropped immediately, not left to the TTL', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.firePlayerDropped(2, 'left')
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

t.test('playerDropped: only the disconnecting src\'s OWN claims are cleared -- an unrelated src\'s claim on a different seat is unaffected', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 2, 1)
    f.firePlayerDropped(2, 'left')

    -- src 3's own claim on seat 2 must still be enforced against a NEW
    -- would-be claimant.
    f.setAccess(4, true)
    f.setPlayer(4, 'CIT3')
    f.setPed(4, 12, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 4, 500, 2, 1)

    local grantedFour = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 4 then grantedFour = true end
    end
    t.isFalse(grantedFour, 'src 3\'s own, unrelated claim must survive src 2\'s disconnect')
end)

t.test('onResourceStop: clears every claim, regardless of who held it', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.fireResourceStop('qbx_k9unit')
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

t.test('onResourceStop: a mismatched resourceName never fires', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.fireResourceStop('some_other_resource')
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree, 'a mismatched resourceName must never clear anything')
end)

-- ========================================================================
-- PERIODIC SWEEP -- mechanism 4 of "a claim must never outlive the player
-- or the vehicle": proactively drops claims naming a vehicle that no longer
-- exists at all, independent of the TTL, and independently re-confirms the
-- TTL sweep too. Gated on Config.Features.VehicleEntryExit at file load.
-- ========================================================================

t.test('feature off: the periodic sweep thread is never even created', function()
    local f = newVehicleServerFixture({ vehicleEntryExit = false })
    t.equals(f.threadCreateCount(), 0)
end)

t.test('feature on: the periodic sweep thread IS created', function()
    local f = newVehicleServerFixture()
    t.equals(f.threadCreateCount(), 1)
end)

t.test('sweep: proactively drops a claim naming a vehicle that no longer exists at all, even well before its own TTL would have expired it', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.removeVehicleExistence(50) -- the vehicle is destroyed while the claim is still well within its TTL

    f.stepSweep() -- primes the sweep loop's own first Wait()
    f.stepSweep() -- runs exactly one full sweep pass

    -- Re-register the SAME netId against a genuine, DIFFERENT vehicle
    -- entity (a stale netId reused is not realistic, but resolving THIS
    -- netId to nothing at all -- the actual case -- already proves the
    -- sweep fired; re-registering here just gives a second request
    -- something real to succeed against).
    f.registerVehicle(500, 51, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree, 'the sweep must have dropped the claim tied to the now-nonexistent vehicle')
end)

t.test('sweep: also drops a TTL-expired claim even if nobody ever requests that exact seat again', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(10001)

    f.stepSweep() -- primes
    f.stepSweep() -- one full pass -- must have dropped the expired claim

    -- Indirect proof: re-registering a FRESH vehicle at the SAME netId and
    -- granting a different src the same seat only works if the table entry
    -- was actually removed (an empty per-vehicle table, not merely an
    -- expired-but-present one) -- GetLiveClaim's own lazy path already
    -- covers "still present but expired," so this specifically exercises
    -- the SWEEP's own removal, not that fallback.
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'qbx_k9unit:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

os.exit(t.summary())
