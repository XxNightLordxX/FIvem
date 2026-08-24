--[[
    qbx_k9unit/client/vehicle.lua

    Phase 1 scaffold (coder-architect). Owns K9 vehicle entry/exit only —
    self-administered (the K9 player interacts with the vehicle
    themselves, nobody does it to them, per SPEC.md §6.1). Never touches
    leash/ox_target-on-peds (that's client/movement.lua's job) — keep that
    split.

    ======================================================================
    EVENT/CALLBACK CONTRACT — this file does not register or trigger any
    network event/callback. Vehicle entry/exit is purely a client-local
    cosmetic state (hide/freeze own ped, restore on exit) — no other
    player's state is affected and nothing needs to be persisted, so
    there's no dedicated server event for it, matching the same reasoning
    originally applied to leash before the leash mechanic grew a real
    consent+restriction requirement. UNLIKE leash, vehicle entry/exit is
    still single-player-only in its effects, so that reasoning still
    holds here — flagged for coder-security to confirm rather than
    asserted as certainly fine, same as the original leash flag was
    (before leash's requirements changed and proved that assumption wrong
    there; it may or may not still hold here).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        EnterNearestK9Vehicle()
        ExitK9Vehicle()
        IsInK9Vehicle() -> boolean
    - THIS FILE calls client/main.lua's global CanShowK9UI() before acting
      on any of the above, and client/main.lua's global
      ResolveNetworkEntity(netId) inside ResolveVehicleFromState() below
      (REFACTOR_ROADMAP.md near-term item 2 — was this file's own
      independent copy of the same defensive-resolve sequence).
]]

-- Local-only "am I currently tucked into a vehicle" state. Not exposed
-- directly — always go through IsInK9Vehicle()/EnterNearestK9Vehicle()/
-- ExitK9Vehicle(). Stores the vehicle's NETWORK id, not a raw entity
-- handle — see ResolveVehicleFromState() below for why (a cached raw
-- handle can go stale over a ride of unknown length; client/movement.lua's
-- leash pull-back thread established this exact re-resolve-every-use
-- pattern for the same reason on a ped handle).
--- @type { vehicleNetId: number } | nil
local vehicleState = nil

--- @return boolean
function IsInK9Vehicle()
    return vehicleState ~= nil
end

-- Precomputed set of Config.K9Vehicles model hashes, built once at file
-- load — no hardcoded model name anywhere, generic over the config
-- (SPEC.md §3 acceptance bullet 3 spirit, applied here to vehicles too).
local K9VehicleHashes = {}
for _, model in ipairs(Config.K9Vehicles) do
    K9VehicleHashes[GetHashKey(model)] = true
end

--- @param maxDistance number
--- @return number? vehicle
local function FindNearestK9Vehicle(maxDistance)
    local myCoords = GetEntityCoords(PlayerPedId())
    local vehicles = GetGamePool('CVehicle')
    local nearestVehicle, nearestDist

    for i = 1, #vehicles do
        local vehicle = vehicles[i]
        if K9VehicleHashes[GetEntityModel(vehicle)] then
            local dist = #(myCoords - GetEntityCoords(vehicle))
            if dist <= maxDistance and (not nearestDist or dist < nearestDist) then
                nearestVehicle, nearestDist = vehicle, dist
            end
        end
    end

    return nearestVehicle
end

--- Re-resolves the vehicle referenced by vehicleState back to a live
--- entity handle via its network id, rather than trusting a raw handle
--- cached at entry time to stay valid for the whole ride (the vehicle can
--- be streamed out and back in, in which case the old handle silently
--- refers to nothing/something else). Mirrors client/movement.lua's leash
--- pull-back thread, which re-resolves its partner ped from a server id
--- every tick for the identical reason ("a cached ped handle can go
--- stale"). The actual resolve-and-guard sequence is now
--- client/main.lua's shared ResolveNetworkEntity() (REFACTOR_ROADMAP.md
--- near-term item 2) — this function's only remaining job is the
--- vehicleState-nil short-circuit, which is specific to this file's own
--- local state and doesn't belong in the generic resolver.
--- @return number? vehicle
local function ResolveVehicleFromState()
    if not vehicleState then return nil end
    return ResolveNetworkEntity(vehicleState.vehicleNetId)
end

--- Reverses the four persisted native states EnterNearestK9Vehicle()
--- applies to the player's own ped (attach, freeze, visibility, collision
--- all persist on the entity itself and never revert on their own), and
--- repositions the ped next to `vehicle` if it still exists. Shared by
--- ExitK9Vehicle() (the normal player-driven release) and the
--- onResourceStop handler below, so a resource restart mid-ride can't
--- permanently strand a player frozen/invisible/collisionless/attached
--- with no self-service recovery path (the ship-blocking bug this helper
--- exists to close).
--- @param ped number
--- @param vehicle number|nil  -- resolved live vehicle entity, or nil if it no longer exists
local function ReleasePedFromVehicleState(ped, vehicle)
    DetachEntity(ped, true, false)
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)

    if vehicle and DoesEntityExist(vehicle) then
        local exitCoords = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -3.0, 0.0)
        SetEntityCoords(ped, exitCoords.x, exitCoords.y, exitCoords.z, false, false, false, true)
        SetEntityHeading(ped, GetEntityHeading(vehicle))
    end
    -- If the vehicle itself no longer exists (despawned while "loaded"),
    -- just restore the ped in place rather than erroring — better than
    -- leaving the player permanently frozen/invisible with no vehicle to
    -- reference.
end

--- Finds the nearest vehicle within Config.VehicleInteractMeters whose
--- model is in Config.K9Vehicles and enters it (hides/freezes the K9's
--- own ped, per SPEC.md §6.1 vehicle bullet).
function EnterNearestK9Vehicle()
    if not Config.Features.VehicleEntryExit then return end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if IsInK9Vehicle() then return end -- already in one

    local vehicle = FindNearestK9Vehicle(Config.VehicleInteractMeters)
    if not vehicle then
        lib.notify({ title = 'K9 Unit', description = 'No K9 vehicle nearby.', type = 'error' })
        return
    end

    local ped = PlayerPedId()
    -- "Tucked away" treatment: frozen, invisible, no collision, AND
    -- attached to the vehicle. SPEC.md §6.1 only says "hidden/frozen," but
    -- freezing in place without attaching would leave the K9 stranded,
    -- motionless, in world space the instant the vehicle actually drives
    -- anywhere — defeating the entire real-world point of "loading" a K9
    -- into a cruiser (riding along to a scene). Attaching at a rear/boot
    -- offset is a reasonable Phase 1 approximation since the ped is
    -- invisible anyway; exact bone precision doesn't matter here.
    SetEntityCollision(ped, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    AttachEntityToEntity(ped, vehicle, 0, 0.0, -1.5, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)

    -- Store the NETWORK id, not the raw `vehicle` handle above — see
    -- ResolveVehicleFromState()'s doc comment for why the handle itself
    -- isn't trusted to stay valid for the whole ride.
    vehicleState = { vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle) }
    lib.notify({ title = 'K9 Unit', description = 'Loaded into the vehicle.', type = 'success' })
end

--- Restores the K9's ped at the vehicle's door and clears vehicleState.
--- No-op if not currently in a vehicle. Deliberately NOT gated behind
--- CanShowK9UI() — a K9 whose certification lapses mid-ride must always
--- be able to un-freeze/un-hide themselves; this mirrors the same
--- "never leave a player stuck" principle SPEC.md §9 item 3b establishes
--- as a hard requirement for leash detach, applied here by extension
--- since unfreezing your own visible ped isn't itself a security-relevant
--- capability grant. Not spelled out verbatim in SPEC.md — a deliberate
--- client-logic judgment call, flagged here rather than made silently.
function ExitK9Vehicle()
    if not IsInK9Vehicle() then return end

    local ped = PlayerPedId()
    ReleasePedFromVehicleState(ped, ResolveVehicleFromState())

    vehicleState = nil
    lib.notify({ title = 'K9 Unit', description = 'Released from the vehicle.', type = 'success' })
end

-- Resource-restart safety net (ship-blocking QA finding): vehicleState is
-- a plain Lua local, so it resets to nil on `restart qbx_k9unit` — but the
-- native states EnterNearestK9Vehicle() applied to the ped (frozen,
-- invisible, collisionless, attached) are entity-persisted and do NOT
-- revert on their own just because the script unloads. Without this
-- handler, restarting this resource mid-ride permanently strands the
-- player: the new script instance boots with vehicleState = nil, so
-- IsInK9Vehicle() reports false and ExitK9Vehicle() immediately no-ops,
-- leaving no self-service recovery path. Reuses ReleasePedFromVehicleState
-- (the exact same cleanup ExitK9Vehicle() runs above) rather than
-- duplicating the native calls.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not vehicleState then return end

    ReleasePedFromVehicleState(PlayerPedId(), ResolveVehicleFromState())
    vehicleState = nil
end)

-- Register the ox_target vehicle options for every model in
-- Config.K9Vehicles, labeled contextually ("Load Into Vehicle" /
-- "Release From Vehicle" via two separate canInteract predicates rather
-- than one dynamic label, since ox_lib/ox_target options don't have a
-- documented live "recompute this label" hook this session verified).
-- The enter option's canInteract uses CanShowK9UI() (not just
-- IsOwnModelK9()) — this is EXACTLY the "hot call site" client/main.lua's
-- header names as the reason HasK9Access() has a short TTL cache, since
-- canInteract can run several times a second while hovering.
-- Gate visibility with Config.Features.VehicleEntryExit AND the access
-- check above — this is a DISPLAY optimization per SPEC.md §3/§4.5, not
-- the security boundary (there's no server round-trip to independently
-- re-verify here since this action has no server event at all, per this
-- file's header note — if that turns out to be the wrong call per
-- coder-security's review, the fix is adding a thin gated server event
-- here the same way leash ended up needing one, not silently trusting
-- the client further than intended; nothing below forecloses adding one
-- later).
exports.ox_target:addGlobalVehicle({
    {
        name = 'qbx_k9unit:enterVehicle',
        icon = 'fas fa-dog',
        label = 'Load K9 Into Vehicle',
        distance = Config.VehicleInteractMeters,
        canInteract = function(entity, distance, coords, name)
            if not Config.Features.VehicleEntryExit then return false end
            if IsInK9Vehicle() then return false end
            if not K9VehicleHashes[GetEntityModel(entity)] then return false end
            return CanShowK9UI()
        end,
        onSelect = function()
            EnterNearestK9Vehicle()
        end,
    },
    {
        name = 'qbx_k9unit:exitVehicle',
        icon = 'fas fa-dog',
        label = 'Release K9 From Vehicle',
        distance = Config.VehicleInteractMeters,
        canInteract = function(entity, distance, coords, name)
            if not Config.Features.VehicleEntryExit then return false end
            return IsInK9Vehicle() and ResolveVehicleFromState() == entity
        end,
        onSelect = function()
            ExitK9Vehicle()
        end,
    },
})
