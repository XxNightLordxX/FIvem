--[[
    qbx_k9unit/client/movement.lua

    Phase 1 scaffold (coder-architect). Owns everything about the K9
    player's own body: the camera toggle, the "Sit" self-emote, and the
    two-player leash mechanic in full (consent handshake, the elastic
    movement restriction while attached, and zero-consent detach). Native
    run/jump/crouch locomotion needs no wrapper code — it's inherent to
    the ped model — so it isn't stubbed here beyond the AgilityBasicJump
    note near the bottom.

    ======================================================================
    EVENT/CALLBACK CONTRACT — certification events are documented in full
    in server/certifications.lua / client/main.lua (kept in sync manually,
    not re-duplicated here). THIS FILE owns the client side of the leash
    subsystem, documented in full in server/main.lua's header — read that
    file together with this one for the complete picture. Summary of what
    THIS FILE registers/triggers:

    Server events (client->server):
    - 'qbx_k9unit:server:requestLeashAttach' (targetServerId: number)
    - 'qbx_k9unit:server:respondLeashAttach' (fromServerId: number, accepted: boolean)
    - 'qbx_k9unit:server:detachLeash' ()

    Client events (server->client):
    - 'qbx_k9unit:client:leashAttachRequest' (fromServerId: number) [THIS FILE]
    - 'qbx_k9unit:client:leashAttached' (partnerServerId: number, isConstrained: boolean) [THIS FILE]
    - 'qbx_k9unit:client:leashDetached' (reason: string) [THIS FILE]
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        ToggleK9Camera()
        K9Sit()
        RequestLeashAttach(targetPlayerServerId: number)  -- was named
            AttachLeash() in the earlier (pre-consent) scaffold draft;
            renamed because it no longer attaches anything by itself, it
            only sends a request.
        DetachLeash()
        IsLeashed() -> boolean
    - THIS FILE calls client/main.lua's global CanShowK9UI() before
      initiating a request (radial.lua is also expected to gate
      visibility, but per SPEC.md §3's "must not be triggerable by a
      modified client" spirit, don't rely solely on the caller having
      already checked — and the server re-validates independently anyway,
      see server/main.lua's CheckLeashEligibility).
    - THIS FILE registers the "Attach Leash" ox_target option on nearby
      player peds (the SPEC.md §6.1 leash bullet's "either the K9 or a
      nearby officer initiates 'Attach Leash' (ox_target) on the other").
      client/vehicle.lua owns the vehicle ox_target option instead; keep
      that split — this file should never touch vehicles, vehicle.lua
      should never touch leash/ox_target-on-peds.
    - client/radial.lua's "Attach/Detach Leash" item is a context-sensitive
      SELF-initiated alternative entry point: if not IsLeashed(), it finds
      a nearby candidate and calls RequestLeashAttach(candidateServerId);
      if IsLeashed(), it calls DetachLeash(). Both surfaces (ox_target and
      radial) end up calling the SAME two functions — don't let a second,
      divergent leash-request code path grow in radial.lua.

    LEASH SUBSYSTEM DESIGN (per requester's confirmation, resolving
    SPEC.md §9 item 3b — see server/main.lua's header for the full
    rationale, repeated here only as it affects THIS file):
    1. Attach requires consent — RequestLeashAttach() only ever sends a
       request; the actual pairing is formed server-side after the OTHER
       player accepts via the ox_lib prompt this file shows them.
    2. While attached, the CONSTRAINED party (always the K9-role side,
       server-assigned — see leashAttached's `isConstrained` flag) runs an
       elastic pull-back on THEIR OWN ped as they approach
       Config.LeashMaxDistance from their partner. This must run on the
       constrained player's own client because a client can only reliably
       control its own ped's position — you cannot dependably force
       another client's ped to a position from here, their own game
       instance keeps simulating and re-networking their own movement.
    3. DetachLeash() must work at ANY time for EITHER role, no
       confirmation/consent step of its own — hard requirement, no trapped
       state.
    4. If the elastic pull-back still can't keep distance under control
       (disconnect, teleport, desync) and a hard cap is exceeded, the
       CONSTRAINED client calls DetachLeash() itself as a safety valve —
       reuse this exact function, don't build a second detach code path.
]]

--- Toggles first/third-person camera at the K9's eye height while playing
--- a K9 character. See client/main.lua's OPEN QUESTION about whether this
--- needs to be gated by CanShowK9UI() at all — this scaffold's lean is no.
--- TODO(coder-frontend): SPEC.md §6.1 bullet 2, §8 step 5. Likely a
--- CreateCam/SetCamActive toggle bound to a keybind (RegisterKeyMapping)
--- or a client/radial.lua item — pick one and note the choice here.
function ToggleK9Camera()
end

--- Self-emote "Sit" action triggered from the radial menu.
--- TODO(coder-frontend): SPEC.md §6.1 radial bullet, §8 step 7. Play an
--- appropriate anim/task on PlayerPedId() (e.g. TaskPlayAnim with a
--- quadruped sit clip if one exists on the current model, else a
--- reasonable native fallback). Gate with CanShowK9UI() at the top —
--- return early (and notify) if false, don't just rely on radial.lua
--- having already hidden the item.
function K9Sit()
end

--- Local-only UI/role bookkeeping for the CURRENT leash pairing, if any.
--- The pairing's existence is server-authoritative (server/main.lua's
--- LeashPairs); this is just this client's cached view of it, refreshed
--- by the leashAttached/leashDetached handlers below. Not exposed
--- directly — always go through IsLeashed()/DetachLeash().
--- @type { partnerServerId: number, isConstrained: boolean }|nil
local leashState = nil

--- @return boolean
function IsLeashed()
    return leashState ~= nil
end

--- Sends a leash request to `targetPlayerServerId`. Does NOT attach
--- anything by itself — see leashAttached event handler below for where
--- the pairing actually activates, after the target accepts.
--- @param targetPlayerServerId number
--- TODO(coder-frontend): SPEC.md §6.1 leash bullet, §8 step 6.
--   1. if not CanShowK9UI() then notify + return end -- re-check, don't
--      trust that the caller (ox_target predicate or radial item) already
--      verified this — cheap client-side sanity check before bothering
--      the server (which re-validates authoritatively regardless).
--   2. if IsLeashed() then notify "already leashed" + return end
--   3. TriggerServerEvent('qbx_k9unit:server:requestLeashAttach', targetPlayerServerId)
--   4. Optionally notify the local player "request sent" — the target's
--      client is the one that shows the actual accept/decline prompt (see
--      the leashAttachRequest handler below), not this client.
function RequestLeashAttach(targetPlayerServerId)
end

--- Detaches the current leash, if any, with ZERO consent required from
--- the other party. No-op (locally and server-side) if not currently
--- leashed. This is the SAME function the elastic-restriction safety
--- valve calls automatically — see the CreateThread below.
--- TODO(coder-frontend): TriggerServerEvent('qbx_k9unit:server:detachLeash')
--- — let the server-authoritative leashDetached broadcast (handled below)
--- be what actually clears leashState/stops the thread, rather than
--- clearing local state immediately here, so this client's view stays in
--- sync with whatever the server decides (e.g. if this was already a
--- no-op server-side because the pairing had already ended for some other
--- reason, the local state should reflect that reality, not what this
--- function optimistically assumed).
function DetachLeash()
end

--- Step 1 of the consent handshake, received on the TARGET's client.
--- @param fromServerId number
RegisterNetEvent('qbx_k9unit:client:leashAttachRequest', function(fromServerId)
    -- TODO(coder-frontend): show an ox_lib prompt (e.g. lib.alertDialog or
    -- a small registerContext with Accept/Decline) naming the requester.
    -- On the player's choice:
    --   TriggerServerEvent('qbx_k9unit:server:respondLeashAttach', fromServerId, accepted)
    -- Consider what happens if the local player is already leashed to
    -- someone else, or leashes/unleashes mid-prompt, by the time they
    -- answer — the server re-validates everything at accept time
    -- regardless (see server/main.lua), so an accept that's now invalid
    -- will simply be rejected server-side; this client just needs to
    -- handle that gracefully (e.g. a "no longer possible" notify) rather
    -- than assuming acceptance always succeeds.
end)

--- Step 2 of the consent handshake: the server has confirmed the pairing
--- and told THIS client its role. Sent individually to each party with
--- their own `isConstrained` value — do not assume both clients receive
--- the same boolean.
--- @param partnerServerId number
--- @param isConstrained boolean  -- true only on the K9-role party's client
RegisterNetEvent('qbx_k9unit:client:leashAttached', function(partnerServerId, isConstrained)
    -- TODO(coder-frontend):
    --   leashState = { partnerServerId = partnerServerId, isConstrained = isConstrained }
    --   Notify locally ("Leashed to <partner>").
    --   If isConstrained, ensure the elastic-restriction thread below is
    --   running (it should already be gated on IsLeashed(), so setting
    --   leashState is likely sufficient to wake it — coder-frontend's
    --   call on the exact thread-lifecycle pattern used).
end)

--- The pairing has ended — manual detach by either side, the constrained
--- client's own safety valve, or a partner disconnect (server/main.lua's
--- playerDropped cleanup). Sent to whichever client(s) are still around.
--- @param reason string  -- e.g. 'detached' | 'partner_disconnected'
RegisterNetEvent('qbx_k9unit:client:leashDetached', function(reason)
    -- TODO(coder-frontend): leashState = nil; notify locally with a
    -- message appropriate to `reason`. The elastic-restriction thread
    -- should naturally stop doing anything once IsLeashed() is false —
    -- don't leave a dangling loop still trying to read a partner ped that
    -- may no longer be valid.
end)

-- TODO(coder-frontend): elastic movement-restriction thread — this is the
-- part of the leash mechanic coder-security specifically asked to see be
-- an actual constraint, not a passive monitor. Runs only while
-- IsLeashed() AND leashState.isConstrained is true (the anchor/officer
-- side does nothing here beyond tracking the pairing for its own UI).
-- Per-tick (or a short fixed interval — your call on the smoothness/perf
-- tradeoff), resolve the partner ped from leashState.partnerServerId
-- (GetPlayerPed(GetPlayerFromServerId(partnerServerId)) — re-resolve each
-- check, don't cache the ped handle across a respawn), measure distance
-- to it, and as it approaches Config.LeashMaxDistance, apply a
-- proportional soft pull-back on the LOCAL ped (this client's own —
-- perfectly fine to move, per point 2 above) rather than a hard snap at
-- the exact threshold. If distance still exceeds some larger hard cap
-- despite that (disconnect/teleport/desync — point 4 above), call
-- DetachLeash() and notify locally as the safety-valve fallback. The
-- exact natives/easing curve for the pull-back are a client-native
-- feasibility question — coder-frontend's call, not dictated here.

-- TODO(coder-frontend): register the "Attach Leash" ox_target option on
-- nearby player peds (exports.ox_target:addModel is wrong here since the
-- target is a PLAYER ped, not a vehicle/prop model — use ox_target's
-- player-targeting API, e.g. addGlobalPlayer with a canInteract
-- predicate). Gate visibility with: Config.Features.LeashMechanics AND a
-- cheap client-side plausibility check (e.g. neither party already
-- IsLeashed(), at least one of us plausibly a K9 via IsOwnModelK9()/the
-- target's model if inspectable) — this is a DISPLAY optimization only,
-- the server independently re-validates everything for real in
-- CheckLeashEligibility (server/main.lua), so don't over-invest in
-- perfecting the client-side predicate.

-- NOTE on AgilityBasicJump (Config.Features.AgilityBasicJump): SPEC.md
-- §6.1 describes this as "native jump/crouch only, no fence-vault logic
-- yet" — i.e. Phase 1 doesn't add any custom jump/crouch code at all, the
-- flag exists so Phase 3's AgilityAdvanced has something to sit alongside
-- later. No stub function is needed here for it; if a future pass wants
-- to gate jump input itself behind this flag (e.g. disable jump entirely
-- when false), that's a deliberate addition, not implied by Phase 1.
