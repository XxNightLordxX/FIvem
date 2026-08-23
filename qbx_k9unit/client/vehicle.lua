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
      on any of the above.
]]

-- Local-only "am I currently tucked into a vehicle" state. Not exposed
-- directly — always go through IsInK9Vehicle()/EnterNearestK9Vehicle()/
-- ExitK9Vehicle().
--- @type { vehicle: number, doorIndex: number } | nil
local vehicleState = nil

--- @return boolean
function IsInK9Vehicle()
    return vehicleState ~= nil
end

--- Finds the nearest vehicle within Config.VehicleInteractMeters whose
--- model is in Config.K9Vehicles and enters it (hides/freezes the K9's
--- own ped, per SPEC.md §6.1 vehicle bullet).
--- TODO(coder-frontend): SPEC.md §6.1 vehicle bullet, §8 step 8.
--   1. if not Config.Features.VehicleEntryExit then return end
--   2. if not CanShowK9UI() then notify + return end
--   3. if IsInK9Vehicle() then return end -- already in one
--   4. Iterate nearby vehicles (e.g. lib.getNearbyVehicles or a manual
--      GetGamePool('CVehicle') scan), filter to GetEntityModel(v) matching
--      one of Config.K9Vehicles (compare by hash — build the hash set
--      once, don't re-hash every call; no hardcoded model name, iterate
--      Config.K9Vehicles generically per the same §3 spirit applied
--      elsewhere), within Config.VehicleInteractMeters of PlayerPedId().
--   5. If found: FreezeEntityPosition(PlayerPedId(), true),
--      SetEntityVisible(PlayerPedId(), false, false) (or an equivalent
--      "tucked away" treatment — coder-frontend's call on exact natives),
--      vehicleState = { vehicle = foundVehicle, doorIndex = <chosen door> }.
--   6. If not found: notify "no K9 vehicle nearby."
function EnterNearestK9Vehicle()
end

--- Restores the K9's ped at the vehicle's door and clears vehicleState.
--- No-op if not currently in a vehicle.
--- TODO(coder-frontend): unfreeze/re-show the ped at an appropriate
--- position near vehicleState.vehicle's door, then vehicleState = nil.
function ExitK9Vehicle()
end

-- TODO(coder-frontend): register the ox_target vehicle option (e.g.
-- exports.ox_target:addModel or addGlobalVehicle, coder-frontend's call
-- on which ox_target API fits best) for every model in Config.K9Vehicles,
-- within Config.VehicleInteractMeters, labeled contextually ("Load Into
-- Vehicle" / "Release From Vehicle" depending on IsInK9Vehicle()). Gate
-- visibility with Config.Features.VehicleEntryExit AND a client-side
-- CanShowK9UI() check in the option's canInteract predicate — this is a
-- DISPLAY optimization per SPEC.md §3/§4.5, not the security boundary
-- (there's no server round-trip to independently re-verify here since
-- this action has no server event at all, per this file's header note —
-- if that turns out to be the wrong call, the fix is adding a thin
-- gated server event here the same way leash ended up needing one, not
-- silently trusting the client further than intended).
