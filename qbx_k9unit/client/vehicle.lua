--[[
    qbx_k9unit/client/vehicle.lua

    Phase 1 scaffold (coder-architect). Owns K9 vehicle entry/exit only —
    self-administered (the K9 player interacts with the vehicle
    themselves, nobody does it to them, per DEVELOPER_REFERENCE.md §6.1). Never touches
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
      (DEVELOPER_REFERENCE.md near-term item 2 — was this file's own
      independent copy of the same defensive-resolve sequence).
]]

-- ======================================================================
-- FILE-TOP FEATURE GATE (coder-frontend, this pass) -- this file previously
-- had NO such gate at all: EnterNearestK9Vehicle()/ExitK9Vehicle()/
-- IsInK9Vehicle() each self-checked Config.Features.VehicleEntryExit
-- internally, but the onResourceStart handler that registers the "Load/
-- Release" ox_target options and the vehicle-despawn/own-death watchdog
-- thread below both ran unconditionally regardless of the flag -- breaking
-- this resource's "flag off means genuinely inert" invariant (client/
-- fetch.lua / client/audio.lua / client/hud.lua precedent for this exact
-- shape of top-level gate).
--
-- WHY A PLAIN TOP-LEVEL RETURN IS SAFE HERE, NOT AN UNBOUNDED TRAP --
-- worked out deliberately, not assumed, because this file's own watchdog
-- thread exists specifically to prevent a player being stranded frozen/
-- invisible/attached mid-ride:
--   1. VehicleEntryExit is `tier = 'clientonly'` in server/runtimecontrol.lua's
--      own FEATURE_TIERS audit -- there is NO server-side registration point
--      for this feature at all (confirmed by that file's own grep-before-
--      writing claim), and Config.Features itself is a plain static table
--      in config.lua (no metatable, no live-reload proxy -- confirmed by
--      reading config.lua directly). There is therefore no code path,
--      anywhere in this resource, that changes what THIS CLIENT's own
--      Config.Features.VehicleEntryExit evaluates to for the lifetime of
--      this file's current load -- an operator "disabling it" can only mean
--      editing config.lua's source and restarting this resource. A
--      same-session, no-restart toggle simply cannot happen for this flag,
--      by construction, so this gate cannot fire out from under a rider
--      whose current script instance already loaded with the flag true.
--   2. The one real path that DOES change the flag's value for this client
--      -- editing config.lua and restarting this resource -- necessarily
--      stops the OLD script instance first (FXServer fires `onResourceStop`
--      for every client running this resource's client scripts as part of
--      that restart, before the new instance with the new config value ever
--      loads). This file's own `onResourceStop` handler below is registered
--      by that OLD instance while the flag was still true, and is NOT
--      affected by what the NEW instance's top-level gate above will decide
--      -- it already runs today, unconditionally, on every stop of this
--      resource, and releases a mid-ride player exactly as it always has.
--      The watchdog thread below needs no equivalent carve-out: it is a
--      loop inside that same OLD, still-running instance, not something the
--      new instance's gate could reach into and stop early.
--   3. Net effect: a rider mid-ride when the flag flips off (via the only
--      real mechanism above) is released by the existing onResourceStop
--      handler at the moment of restart, same as today; a fresh session
--      that boots with the flag already off never lets a player into a
--      vehicle through this file in the first place (EnterNearestK9Vehicle's
--      own internal check already prevented that before this gate existed),
--      so vehicleState can never be non-nil for that session and the
--      watchdog never has anything to guard. Gating registration here adds
--      no new way to get stuck; it only stops the watchdog/ox_target
--      registration from running at all in a session that could never have
--      produced a mid-ride player to begin with.
-- If a future change ever gives this feature a live, no-restart toggle
-- path, this reasoning must be re-verified before relying on it again.
-- ======================================================================
if not Config.Features.VehicleEntryExit then return end

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
-- (DEVELOPER_REFERENCE.md §3 acceptance bullet 3 spirit, applied here to vehicles too).
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
--- client/main.lua's shared ResolveNetworkEntity() (DEVELOPER_REFERENCE.md
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
--- own ped, per DEVELOPER_REFERENCE.md §6.1 vehicle bullet).
function EnterNearestK9Vehicle()
    if not Config.Features.VehicleEntryExit then return end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- Per-person block (client/featureblocks.lua, REQUESTED -- see that
    -- file's header for the full contract). Checked here, in
    -- EnterNearestK9Vehicle() itself -- the single resource-global every
    -- entry point (radial, keybind/command, tablet trigger) already
    -- routes through, per this file's own header precedent -- so no
    -- second copy of this check is needed anywhere else. ExitK9Vehicle()
    -- below is, and stays, completely unaffected: that function's own doc
    -- comment already states it is deliberately never gated on
    -- CanShowK9UI() at all, for the same "never leave a player stuck"
    -- reasoning this block check must not violate either.
    if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('VehicleEntryExit') then
        if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
        return
    end

    if IsInK9Vehicle() then return end -- already in one

    -- MUTUAL GUARD vs. client/combat.lua's PropDragging/BiteAndHold
    -- (QA-reported real defect, this pass): this function attaches, freezes,
    -- hides, and disables collision on the SAME ped (PlayerPedId()) that
    -- combat.lua's shared maintenance thread re-attaches EVERY TICK as the
    -- HOLDER anchor of an active drag (AttachEntityToEntity(targetPed,
    -- PlayerPedId(), ...), see that file's "ActiveDragAsHolder" block) or
    -- plays a one-shot cosmetic stance on for an active bite hold
    -- (PlayBiteHoldStance). Entering a vehicle mid-drag would attach this
    -- ped to the vehicle as a CHILD while combat.lua keeps attaching the
    -- dragged target to this SAME ped as a PARENT every frame — a nested
    -- attach chain nobody designed for (the dragged target becomes a rigid
    -- child of a ped that is itself invisible/frozen/collisionless/attached
    -- to a vehicle), and a griefing-usable one since the target has no way
    -- to see or reach the now-hidden K9 holding it. Checked here (not just
    -- left to RequestDrag()'s own symmetric IsInK9Vehicle() guard below)
    -- because the two triggers are reachable in EITHER order — a K9 already
    -- mid-drag/mid-hold selecting "Enter Vehicle" is the direction
    -- RequestDrag()'s own guard cannot catch.
    --
    -- Soft dependency, `type(...) == 'function'` runtime existence guard —
    -- this resource's established convention (see client/defense.lua's
    -- identical guard on this exact function) — because IsBiteHoldEngaged/
    -- IsDragEngaged only exist at all once client/combat.lua's own top-level
    -- gate (`Config.Features.BiteAndHold/NonLethalTakedown/PropDragging`)
    -- lets that file's globals get defined; VehicleEntryExit can be enabled
    -- on a server that runs none of those three, in which case neither
    -- global is ever declared.
    if type(IsDragEngaged) == 'function' and IsDragEngaged() then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.blocked_by_drag'), type = 'error' })
        return
    end
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.blocked_by_bite_hold'), type = 'error' })
        return
    end

    local ped = PlayerPedId()
    -- Real-defect guard (client-logic review finding): IS_PED_IN_ANY_VEHICLE
    -- (verified against the Cfx native reference, PED namespace, BOOL
    -- return) catches the case where this ped is already a genuine
    -- occupant of SOME vehicle via ordinary game controls (any ped model,
    -- including a K9 model, can be walked up to a car and seated with the
    -- vanilla "enter vehicle" control — nothing about that path goes
    -- through this file). vehicleState only tracks OUR OWN attach, so
    -- IsInK9Vehicle() above reads false in that case and would otherwise
    -- let this function freeze/hide/attach a ped that the game still
    -- separately considers seated in a (possibly different) vehicle.
    -- ReleasePedFromVehicleState()'s teleport-out on exit never calls
    -- TASK_LEAVE_VEHICLE or clears that seat assignment, so without this
    -- guard the ped could end up in a corrupted "phantom seated" state
    -- after this file's own exit path finishes.
    if IsPedInAnyVehicle(ped, false) then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.already_in_vehicle'), type = 'error' })
        return
    end

    local vehicle = FindNearestK9Vehicle(Config.VehicleInteractMeters)
    if not vehicle then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.no_vehicle_nearby'), type = 'error' })
        return
    end

    -- "Tucked away" treatment: frozen, invisible, no collision, AND
    -- attached to the vehicle. DEVELOPER_REFERENCE.md §6.1 only says "hidden/frozen," but
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
    lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.loaded'), type = 'success' })
end

--- Restores the K9's ped at the vehicle's door and clears vehicleState.
--- No-op if not currently in a vehicle. Deliberately NOT gated behind
--- CanShowK9UI() — a K9 whose certification lapses mid-ride must always
--- be able to un-freeze/un-hide themselves; this mirrors the same
--- "never leave a player stuck" principle DEVELOPER_REFERENCE.md §9 item 3b establishes
--- as a hard requirement for leash detach, applied here by extension
--- since unfreezing your own visible ped isn't itself a security-relevant
--- capability grant. Not spelled out verbatim in DEVELOPER_REFERENCE.md — a deliberate
--- client-logic judgment call, flagged here rather than made silently.
function ExitK9Vehicle()
    if not IsInK9Vehicle() then return end

    local ped = PlayerPedId()
    ReleasePedFromVehicleState(ped, ResolveVehicleFromState())

    vehicleState = nil
    lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.released'), type = 'success' })
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

-- Vehicle-despawn watchdog (client-logic review finding): the native
-- states EnterNearestK9Vehicle() applies to the ped are entity-persisted,
-- exactly like the resource-restart case above, but restarting THIS
-- resource is not the only way vehicleState can be left pointing at
-- nothing. This ped is only ATTACHED to the vehicle, never actually
-- SetPedIntoVehicle'd into a seat, so the game does not count it as an
-- occupant — the vehicle can still be deleted out from under a riding K9
-- by anything else running on this server (a vehicle-cleanup script, the
-- game's own unoccupied-vehicle population sweep, another player's
-- DeleteEntity, despawning after entering water and sinking, etc.) with no
-- event this file is told about. Without this, ExitK9Vehicle() still WORKS
-- afterward (ReleasePedFromVehicleState already tolerates vehicle == nil,
-- and client/radial.lua's "Enter/Exit Vehicle" item calls it with no
-- requirement to be near any entity) — but nothing tells the player their
-- ride is gone, and this file's OWN ox_target "Release From Vehicle"
-- option specifically (canInteract requires hovering a live entity that
-- equals ResolveVehicleFromState()) becomes permanently unreachable the
-- moment the vehicle stops existing, since there is no entity left to
-- hover. This thread closes that gap by self-releasing and telling the
-- player why, rather than leaving them frozen/invisible relying on
-- knowing to open the radial menu instead.
--
-- OWN-DEATH RELEASE (lifecycle QA finding, this pass — the softlock this
-- thread's death branch below exists to close): this was the only place in
-- the codebase applying a persistent native ped state with no own-death
-- handling at all, unlike client/vision.lua (~line 165),
-- client/screenfx.lua (~line 297), client/propattachment.lua's "OWN-DEATH
-- AUTO-DETACH" (~line 384) and client/fetch.lua's "OWN-DEATH AUTO-DETACH/
-- DROP" (~line 558), all of which force-clear on IsEntityDead(PlayerPedId()).
-- That gap mattered here specifically because client/combat.lua's own
-- repeatedly-verified finding (its ActiveBiteHold/ActiveDragSpeedLimit/
-- ActiveForcedRagdoll death branches, ~lines 1435/1564/1611) is that the
-- standard FiveM respawn flow REUSES the same ped handle rather than
-- allocating a new one — none of collision-disabled, frozen, invisible or
-- attached reset on death or respawn on their own, so a K9 who died while
-- tucked would respawn frozen/invisible/collisionless/still-attached with
-- no self-service recovery (no keybind for this, and the ox_target
-- "Release From Vehicle" option above requires hovering the vehicle, which
-- is unreachable while frozen and invisible — let alone while dead).
-- Folded into THIS existing thread rather than a new dedicated one (unlike
-- client/fetch.lua's/client/propattachment.lua's separate poll threads):
-- this thread already runs at the exact cadence needed (active only while
-- vehicleState is set, idling otherwise) for the exact same time window a
-- death-while-tucked can occur in, so a second parallel thread polling the
-- same PlayerPedId() over the same window would be pure duplication.
--
-- One persistent thread for the resource's whole lifetime, matching
-- client/movement.lua's leash pull-back thread's own established
-- idle/active dual-interval convention, rather than spawning a new thread
-- per ride — sleeps at a long interval whenever no ride is active, so this
-- costs nothing on the ~0.01ms resmon idle benchmark while unused.
--
-- Debounced over several consecutive misses rather than acting on a single
-- failed resolve: ResolveVehicleFromState() (via client/main.lua's
-- ResolveNetworkEntity) also reads nil for a vehicle that is merely not
-- currently streamed in to THIS client at this instant, not only for one
-- that has actually been deleted — a single miss is not reliable proof the
-- vehicle is gone for good, and a rider should never be ejected over a
-- momentary streaming hiccup.
local VEHICLE_WATCHDOG_IDLE_MS = 2000
local VEHICLE_WATCHDOG_ACTIVE_MS = 1000
local VEHICLE_WATCHDOG_MISS_THRESHOLD = 3 -- consecutive misses before treating the vehicle as actually gone

CreateThread(function()
    local missStreak = 0

    while true do
        local sleepMs = VEHICLE_WATCHDOG_IDLE_MS

        if vehicleState then
            sleepMs = VEHICLE_WATCHDOG_ACTIVE_MS
            local ped = PlayerPedId()

            if DoesEntityExist(ped) and IsEntityDead(ped) then
                -- OWN-DEATH RELEASE — see this thread's own header comment
                -- above ("OWN-DEATH RELEASE") for the full why. Checked
                -- BEFORE the vehicle-resolve branch below on purpose: death
                -- must release regardless of whether the vehicle is still
                -- present, and doing so here (rather than as a third,
                -- independent branch) keeps this thread's per-iteration
                -- work mutually exclusive — exactly one of "release for
                -- death," "still fine," or "release for vehicle loss" runs
                -- per tick, and vehicleState is nilled inside this same
                -- iteration, so the vehicle-loss branch below can never
                -- ALSO fire for the same tuck. If the vehicle happened to
                -- despawn during the same death (ResolveVehicleFromState()
                -- already nil by the time this runs), that is exactly the
                -- nil-vehicle case ReleasePedFromVehicleState already
                -- documents and tolerates — a single release either way,
                -- never two: once vehicleState is nil, every other release
                -- path (ExitK9Vehicle, onResourceStop, this thread's own
                -- outer `if vehicleState then` guard) already no-ops on a
                -- nil vehicleState, so there is no path left that could
                -- run ReleasePedFromVehicleState a second time for the
                -- same ride.
                --
                -- Reuses ReleasePedFromVehicleState exactly as every other
                -- caller does — including its reposition-near-vehicle step
                -- — rather than a death-specific variant, so the four
                -- native states stay cleared in exactly one place. Calling
                -- SetEntityCoords/SetEntityHeading on an already-dead ped
                -- is harmless, and moving the corpse out from the vehicle's
                -- attach offset to just behind it is arguably nicer than
                -- leaving it floating mid-air relative to a (possibly still
                -- moving, if someone else is driving) vehicle -- but this
                -- is NOT relied on for correctness. Wherever this
                -- resource's actual respawn/ambulance flow next places this
                -- ped once it resurrects it is that flow's decision, same
                -- as for a K9 that died any other way; this thread's only
                -- job is making sure that flow inherits an unfrozen,
                -- visible, collidable, detached ped instead of one still
                -- wearing this file's four vehicle flags.
                missStreak = 0
                ReleasePedFromVehicleState(ped, ResolveVehicleFromState())
                vehicleState = nil
                lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.released_on_death'), type = 'error' })
            elseif ResolveVehicleFromState() then
                missStreak = 0
            else
                missStreak = missStreak + 1
                if missStreak >= VEHICLE_WATCHDOG_MISS_THRESHOLD then
                    missStreak = 0
                    -- Same cleanup ExitK9Vehicle()/onResourceStop already run —
                    -- vehicle is nil here by construction (that's what triggered
                    -- this branch), so ReleasePedFromVehicleState just restores
                    -- the ped in place per its own documented nil-vehicle path.
                    ReleasePedFromVehicleState(ped, nil)
                    vehicleState = nil
                    lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.vehicle_lost'), type = 'error' })
                end
            end
        else
            missStreak = 0
        end

        Wait(sleepMs)
    end
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
-- check above — this is a DISPLAY optimization per DEVELOPER_REFERENCE.md §3/§4.5, not
-- the security boundary (there's no server round-trip to independently
-- re-verify here since this action has no server event at all, per this
-- file's header note — if that turns out to be the wrong call per
-- coder-security's review, the fix is adding a thin gated server event
-- here the same way leash ended up needing one, not silently trusting
-- the client further than intended; nothing below forecloses adding one
-- later).
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call -- both canInteract/onSelect pairs below
-- are unchanged (still authored against ox_target's own convention), so an
-- operator running a different supported target script gets both options
-- translated automatically instead of losing them outright.
--
-- LIFECYCLE FIX (this pass): extracted into a named function, sole call
-- site the AddEventHandler('onResourceStart', ...) below, so both options
-- come back after a bare restart of whatever resource actually backs the
-- 'target' system, not just after this resource's own restart -- every
-- supported target script keeps its own registry in a plain file-local Lua
-- table inside its own client chunk, reloaded empty on THAT resource's own
-- restart with nothing else prompting a re-add. Mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. DUPLICATE-VS-REPLACE: both
-- options below always set `name`, and every adapter's own registration
-- primitive dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running this
-- never duplicates either entry.
local function RegisterVehicleOxTargetOptions()
    K9Compat.Get('target').AddGlobalVehicle({
        {
            name = 'qbx_k9unit:enterVehicle',
            icon = 'fas fa-dog',
            label = locale('vehicle.target_enter_label'),
            distance = Config.VehicleInteractMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.VehicleEntryExit then return false end
                if IsInK9Vehicle() then return false end
                -- DISPLAY-OPTIMIZATION MIRROR of EnterNearestK9Vehicle()'s own
                -- load-bearing mutual guard above — hides the option instead of
                -- letting onSelect show a rejection notify for the common case.
                -- Not the real boundary (that's inside EnterNearestK9Vehicle()
                -- itself, which re-checks this regardless of what canInteract
                -- decided), same "canInteract is a UX convenience" posture this
                -- file already documents for every other predicate here.
                if type(IsDragEngaged) == 'function' and IsDragEngaged() then return false end
                if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then return false end
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
            label = locale('vehicle.target_exit_label'),
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
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterVehicleOxTargetOptions()
        return
    end

    -- This file never names a third-party target resource directly (see
    -- shared/compat/target.lua) -- whichever one actually backs the
    -- 'target' system is asked of K9Compat itself. Redetect() is forced
    -- here rather than relying on shared/compat/core.lua's own
    -- onResourceStart/onClientResourceStart redetect hook having already
    -- run for this SAME event, so this check is correct regardless of
    -- relative handler-registration order between the two files.
    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterVehicleOxTargetOptions()
    end
end)
