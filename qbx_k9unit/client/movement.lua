--[[
    qbx_k9unit/client/movement.lua

    Phase 1 scaffold (coder-architect). Owns everything about the K9
    player's own body: the camera toggle, the "Sit" self-emote, and the
    two-player leash mechanic (both the ox_target option that INITIATES an
    attach on a nearby player, and the state/auto-detach logic once
    attached). Native run/jump/crouch locomotion needs no wrapper code —
    it's inherent to the ped model — so it isn't stubbed here at all
    beyond the AgilityBasicJump note below.

    ======================================================================
    EVENT/CALLBACK CONTRACT — see client/main.lua or
    server/certifications.lua for the full copy. THIS FILE doesn't
    register or trigger any of the numbered contract events/callbacks
    directly — it calls client/main.lua's CanShowK9UI()/HasK9Access() and
    is called BY client/radial.lua. No new server events are introduced
    for leash (see DESIGN DECISION below).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        ToggleK9Camera()
        K9Sit()
        AttachLeash(targetPlayerServerId: number)
        DetachLeash()
        IsLeashed() -> boolean
    - THIS FILE calls client/main.lua's global CanShowK9UI() before acting
      on any of the above (radial.lua is also expected to gate visibility,
      but per SPEC.md §3's "must not be triggerable by a modified client"
      spirit, don't rely solely on the caller having already checked).
    - THIS FILE registers the "Attach Leash" ox_target option on nearby
      player peds (the SPEC.md §6.1 leash bullet's "either the K9 or a
      nearby officer initiates 'Attach Leash' (ox_target) on the other").
      client/vehicle.lua owns the vehicle ox_target option instead; keep
      that split — this file should never touch vehicles, vehicle.lua
      should never touch leash/ox_target-on-peds.
    - client/radial.lua's "Attach/Detach Leash" item is a context-sensitive
      SELF-initiated alternative entry point calling the same
      AttachLeash/DetachLeash functions (SPEC.md §8 step 7 lists it as a
      radial item too, alongside the ox_target description in §6.1 — both
      surfaces are legitimate per the spec text, not a contradiction to
      resolve away).

    DESIGN DECISION (coder-architect, flagged for coder-security to
    confirm before Phase 1 ships): leash attach/detach STATE is tracked
    client-side only for Phase 1 — no dedicated server event, no DB/cache
    persistence. Rationale: SPEC.md §6.1 explicitly says Phase 1 "does not
    forcibly move either player's character" (purely cosmetic/informational
    tether) and §9 item 3b flags the whole leash interpretation itself as
    unconfirmed. The GATE on who can even attempt to attach (must the K9
    party pass CanShowK9UI()) still goes through the real server-side
    hasK9Access callback via CanShowK9UI() — so the ACCESS decision is
    server-verified per SPEC.md §3/§4, even though the resulting leash
    STATE afterward isn't server-tracked. If this needs to be a
    server-authoritative, persisted, or two-way-enforced (hard restraint)
    mechanic instead, that's a bigger change — flag it back rather than
    silently building the heavier version.

    OPEN CONFIG GAP flagged for coder-frontend: Config.LeashMaxDistance
    (8.0m) is documented as the AUTO-DETACH threshold once already
    attached. There is no separate "max range to INITIATE an attach"
    constant in config.lua. Using Config.LeashMaxDistance for both
    (can't attach further than you'd immediately auto-detach from) is a
    reasonable Phase 1 default, but wasn't explicitly specified — flag if
    a separate, smaller "attach range" constant turns out to be wanted.
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

-- Local-only leash state for Phase 1 (see DESIGN DECISION above for why
-- this isn't server-tracked). Not exposed directly — always go through
-- AttachLeash/DetachLeash/IsLeashed so calling files don't reach into the
-- shape of this table.
local leashState = nil -- { partnerServerId: number, partnerPed: number } | nil

--- @return boolean
function IsLeashed()
    return leashState ~= nil
end

--- Attaches a leash between the local player and `targetPlayerServerId`.
--- Callable from either the ox_target option below (targeting a nearby
--- player) or client/radial.lua's self-initiated toggle (in which case
--- radial.lua is responsible for having already resolved a valid nearby
--- partner before calling this — see that file's TODO).
--- @param targetPlayerServerId number
--- TODO(coder-frontend): SPEC.md §6.1 leash bullet, §8 step 6.
--   1. if not CanShowK9UI() then notify + return end -- re-check, don't trust the caller
--   2. if not Config.Features.LeashMechanics then return end
--   3. Resolve targetPlayerServerId -> ped, sanity-check proximity
--      client-side (purely for UX feedback; see DESIGN DECISION above —
--      no server round-trip enforces this for Phase 1).
--   4. leashState = { partnerServerId = targetPlayerServerId, partnerPed = targetPed }
--   5. Start (or confirm running) the auto-detach distance-check thread
--      below. Notify both parties (locally; the partner's own client
--      would need its own equivalent trigger/notify — TODO: decide
--      whether attach needs a lightweight two-way client event so the
--      OTHER player's client also learns "you are now leashed" and can
--      run its own auto-detach thread/UI, since Phase 1 has no server
--      relay for this at all under the current DESIGN DECISION. This is
--      a real gap worth a second look: pure client-only state on ONE side
--      means the other player's client doesn't know it's leashed. Flag to
--      coder-security/coder-frontend before treating this design decision
--      as final.
function AttachLeash(targetPlayerServerId)
end

--- Detaches the current leash, if any. No-op if not currently leashed.
--- TODO(coder-frontend): clear leashState, stop the distance-check
--- thread, notify locally (and the partner, per the same two-way-event
--- gap noted in AttachLeash's TODO).
function DetachLeash()
end

-- TODO(coder-frontend): auto-detach thread — while IsLeashed(), poll
-- distance between PlayerPedId() and leashState.partnerPed; if it exceeds
-- Config.LeashMaxDistance, call DetachLeash() and notify. Only needs to
-- run while leashState ~= nil (don't spin an always-on thread).

-- TODO(coder-frontend): register the "Attach Leash" ox_target option on
-- nearby player peds (exports.ox_target:addModel is wrong here since the
-- target is a PLAYER ped, not a vehicle/prop model — use ox_target's
-- player-targeting API, e.g. addGlobalPlayer with a canInteract predicate).
-- Gate visibility with: Config.Features.LeashMechanics AND (CanShowK9UI()
-- for whichever of the local player / target is the K9 party — since
-- EITHER party may initiate per SPEC.md §6.1, the predicate needs to
-- check "is at least one of us a certified K9 and neither of us is
-- already leashed to someone else", not just the local player's own
-- access). Re-check inside AttachLeash() too (see its TODO) — don't rely
-- solely on the ox_target predicate having been correct at hover time.

-- NOTE on AgilityBasicJump (Config.Features.AgilityBasicJump): SPEC.md
-- §6.1 describes this as "native jump/crouch only, no fence-vault logic
-- yet" — i.e. Phase 1 doesn't add any custom jump/crouch code at all, the
-- flag exists so Phase 3's AgilityAdvanced has something to sit alongside
-- later. No stub function is needed here for it; if a future pass wants
-- to gate jump input itself behind this flag (e.g. disable jump entirely
-- when false), that's a deliberate addition, not implied by Phase 1.
