--[[
    qbx_k9unit/client/vision.lua

    PHASE 2 SCAFFOLD ONLY (coder-frontend) — WRITTEN AHEAD OF GREENLIGHT.
    Same standing caveat as client/tracking.lua and client/search.lua's
    headers: written while Phase 1's confirmation wave was still closing
    out, per SPEC.md §11 already being fully specified, but NOT final
    implementation and NOT to be merged/wired blindly. In particular:
      - fxmanifest.lua does NOT yet list this file under client_scripts.
      - client/radial.lua gets NO items for this feature at all (by
        design — see below, this is keybind-only).
      - config.lua does NOT yet contain Config.Vision.Thermal.toggleKey /
        Config.Vision.Night.toggleKey (SPEC.md §11.2 additions).
        Config.Features.ThermalVision / .NightVision already exist today
        (Phase 1 scaffold pass, currently `false`).
    Mirrors the exact "header contract + function signature + numbered
    TODO" scaffolding style client/main.lua's ORIGINAL scaffold used (see
    `git log -- qbx_k9unit/client/main.lua`, commit 66b8aee), not the
    fully-implemented style Phase 1 files have today.

    Owns the two independent thermal/night vision toggle keybinds —
    SPEC.md §11.1 sub-phase 2a, §11.3's `client/vision.lua` row (new file,
    not folded into client/movement.lua, "vision is a big enough sibling
    concern... to warrant its own file rather than a fourth unrelated
    concern bolted onto that one"). Both toggles mirror
    client/movement.lua's ToggleK9Camera()'s exact shape and gating
    philosophy (a perception/QoL toggle, not a granted departmental
    capability) — see §1 below for the one place that shape is
    DELIBERATELY extended beyond ToggleK9Camera()'s precedent
    (config-gated registration).

    Supplementary implementation detail cited in the TODOs below
    (non-authoritative — SPEC.md §11 is the source of truth if anything
    here drifts from it): phase2_notes/thermal_night_vision.md (the
    revised, §11-reconciled pass — read its own header before trusting
    anything in it that contradicts SPEC.md §11.5/§11.6 directly) and
    phase2_notes/thermal_night_vision_natives.md /
    phase2_notes/water_gunpowder_natives.md §3 (two independent native
    confirmation passes, both agreeing on the same hashes).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2: NONE. This file registers or
    triggers no network event or callback of any kind — thermal/night
    vision are purely client-local render toggles (SPEC.md §11.6: "both
    natives are global local-render toggles," no server-side fact to
    check, no other player's state affected). This mirrors
    client/vehicle.lua's own "no dedicated server event" precedent for
    vehicle entry/exit almost exactly, for the identical underlying
    reason (a purely single-player-local cosmetic state with nothing to
    persist or broadcast).
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE will expose four resource-global (no `local`) functions.
      These names are already settled — SPEC.md §11 left this an open
      naming slot, phase2_notes/thermal_night_vision.md §7 filled it, and
      phase2_notes/EXPORT_TRACKING.md's "Batch 2" validation pass
      confirmed no other design note proposed a competing name for the
      same slot:
        ToggleThermalVision()
        ToggleNightVision()
        IsThermalVisionActive()
        IsNightVisionActive()
      No other Phase 2 file currently needs to call into these (§1 of
      phase2_notes/thermal_night_vision.md: "no radial item; no other
      Phase 2 file's design references vision toggling") — exposed as
      resource-globals anyway, per this codebase's established convention
      that every toggle/action function is a resource-global (see
      phase2_notes/EXPORT_TRACKING.md's Phase 1 contract table), in case a
      later phase wants to call in from outside this file.
    - THIS FILE calls client/main.lua's IsOwnModelK9() — see the RESOLVED
      ACCESS-GATING DECISION section immediately below for why this is
      IsOwnModelK9() and explicitly NOT CanShowK9UI().

    ======================================================================
    RESOLVED ACCESS-GATING DECISION (do not re-litigate — settled by
    SPEC.md §11.5, quoted here so it can't be silently drifted from again):
    thermal/night vision gate on IsOwnModelK9() ONLY, the SAME cheap,
    local, free check client/movement.lua's ToggleK9Camera() already uses
    — NOT CanShowK9UI() (the full server-backed combinator Bark/Sit/
    Leash/Vehicle use). §11.5's own stated reasoning: "thermal/night
    vision is presented in SPEC.md as the K9's own innate perception, not
    a granted departmental privilege." Apply IDENTICALLY to both Thermal
    and Night vision — §11.5 is explicit that whichever answer is chosen
    must apply to both for consistency with each other.

    HISTORY WORTH KNOWING (not a live disagreement — recorded so nobody
    re-opens this by reading stale material out of order): the FIRST
    draft of phase2_notes/thermal_night_vision.md picked the OPPOSITE
    answer (CanShowK9UI()), reasoning by analogy to ScentTracking/
    BloodTracking being certified-K9 capabilities. That note's OWN
    revised pass (§3) explicitly corrects itself once SPEC.md §11.5
    landed and settled the question the other way — the correction is
    already made in that note; this file's implementation should reflect
    §11.5's settled answer directly, not the earlier draft's guess.

    Practical effect (intentional, not a gap): an uncertified K9-model
    player (or one whose job isn't in Config.Departments) can still
    toggle thermal/night vision, exactly as they can already toggle the
    first/third-person camera.
    ======================================================================
]]

--- Thin wrapper over the native's OWN getter — the native is the source
--- of truth for "is thermal vision currently on," not a separately
--- tracked local boolean that could desync from it (per SPEC.md §11.6 /
--- phase2_notes/thermal_night_vision.md §7: "the native's own getter is
--- the source of truth, not a separately-tracked local boolean"). Real
--- IsSeethroughActive() native, confirmed to exist alongside its setter
--- by native-api-assistant (SPEC.md §11.6) and independently by
--- phase2_notes/water_gunpowder_natives.md §3.
--- @return boolean
function IsThermalVisionActive()
    return IsSeethroughActive() == true
end

--- Thin wrapper over IsNightvisionActive(), same reasoning as above.
--- @return boolean
function IsNightVisionActive()
    return IsNightvisionActive() == true
end

--- Shared internal helper for the mutual-exclusivity judgment call
--- confirmed (not mandated by the engine) in SPEC.md §11.5: "Thermal and
--- night vision are mutually exclusive at any given moment (toggling one
--- off the other if both were somehow active)... a reasonable default
--- given both are full-screen post-effects that would otherwise visually
--- conflict." One small shared helper here rather than duplicating the
--- check-and-turn-off logic once per toggle function below, per
--- phase2_notes/thermal_night_vision.md §4's explicit implementation-shape
--- recommendation.
--- @param keepingActive 'thermal'|'night'  -- the effect about to be turned ON; turn OFF whichever of the two this is NOT
--- TODO(coder-frontend): SPEC.md §11.5's mutual-exclusion bullet,
--- phase2_notes/thermal_night_vision.md §4.
--   if keepingActive == 'thermal' and IsNightVisionActive() then
--       SetNightvision(false)
--   elseif keepingActive == 'night' and IsThermalVisionActive() then
--       SetSeethrough(false)
--   end
--   -- Check via the Is*Active() getters above (authoritative,
--   -- native-backed), never a locally-tracked boolean that could desync
--   -- — same reasoning as the getters themselves.
local function EnsureOnlyOneVisionEffectActive(keepingActive)
end

--- Toggles GTA's built-in heat-vision effect. SPEC.md §11.5/§11.6:
--- SetSeethrough(BOOL) — confirmed real, toggle-and-forget (no per-frame
--- re-assertion needed to HOLD the effect, only the maintenance/cleanup
--- thread further below is needed, and only while at least one vision
--- effect is active).
--- TODO(coder-frontend): SPEC.md §11.5's "Thermal vision" acceptance
--- block.
--   1. if not IsOwnModelK9() then lib.notify(<"only works while playing
--      a K9 character">) return end -- see RESOLVED ACCESS-GATING
--      DECISION above: IsOwnModelK9() only, NOT CanShowK9UI().
--   2. local turningOn = not IsThermalVisionActive()
--   3. if turningOn then EnsureOnlyOneVisionEffectActive('thermal') end
--      -- mutual exclusion happens BEFORE flipping this effect on, per
--      phase2_notes/thermal_night_vision.md §4's ordering.
--   4. SetSeethrough(turningOn)
--   5. lib.notify(<"Thermal vision on/off">)
--   6. If turningOn, ensure the maintenance/cleanup thread further below
--      is running (it should already be gated on "either effect active,"
--      so this may already be sufficient without an explicit start call
--      — coder-frontend's call on the exact thread-lifecycle pattern,
--      mirroring how client/movement.lua's leash thread is woken purely
--      by setting state rather than an explicit start call).
function ToggleThermalVision()
end

--- Toggles GTA's built-in night-vision-goggle effect. SPEC.md §11.5/§11.6:
--- SetNightvision(BOOL) — confirmed real, same toggle-and-forget shape as
--- thermal above.
--- TODO(coder-frontend): identical shape to ToggleThermalVision() above,
--- substituting SetNightvision/IsNightVisionActive and
--- EnsureOnlyOneVisionEffectActive('night').
function ToggleNightVision()
end

-- TODO(coder-frontend): config-gated command + keybind registration for
-- BOTH toggles — SPEC.md §11.2's Config.Vision schema,
-- phase2_notes/thermal_night_vision.md §1's "Config-gated registration,
-- not just config-gated behavior" requirement. THIS IS THE ONE PLACE
-- this file DELIBERATELY diverges from ToggleK9Camera()'s exact
-- precedent, not just mirrors it: client/movement.lua's
-- RegisterCommand/RegisterKeyMapping for the camera toggle is
-- UNCONDITIONAL (camera has no Config.Features entry to gate on at all).
-- Thermal/night vision DO have Config.Features.ThermalVision /
-- .NightVision entries (already present in config.lua today), so per
-- SPEC.md §3's hard requirement ("read at the point where that feature
-- would activate... command registration... not read once at resource
-- start and then ignored"), each registration below must be wrapped in
-- its OWN independent `if Config.Features.X then ... end` at file-load
-- time — mirrors client/radial.lua's existing convention of only pushing
-- a flagged item into its array at file-load time, applied here to
-- RegisterCommand/RegisterKeyMapping instead of a radial item array
-- entry. The two flags are fully independent (§11.2's config comment: "a
-- server can enable exactly one of the two... in which case only that
-- one keybind/command gets registered at all") — do not couple their
-- registration together.
--   if Config.Features.ThermalVision then
--       RegisterCommand('qbx_k9unit:toggleThermalVision', function() ToggleThermalVision() end, false)
--       RegisterKeyMapping('qbx_k9unit:toggleThermalVision', 'Toggle K9 Thermal Vision', 'keyboard', Config.Vision.Thermal.toggleKey)
--   end
--   if Config.Features.NightVision then
--       RegisterCommand('qbx_k9unit:toggleNightVision', function() ToggleNightVision() end, false)
--       RegisterKeyMapping('qbx_k9unit:toggleNightVision', 'Toggle K9 Night Vision', 'keyboard', Config.Vision.Night.toggleKey)
--   end
-- NOT added to client/radial.lua at all — per §11.3's file-plan row,
-- "Vision toggles and door interaction are not added to the radial...
-- consistent with the camera toggle's existing precedent."

-- TODO(coder-frontend): maintenance/cleanup thread — the piece SPEC.md
-- §11.6 surfaced as a NEW requirement during verification, not present in
-- the original design, and phase2_notes/thermal_night_vision.md §6 works
-- out the exact shape for. A single lightweight thread, started only
-- when either effect transitions to active (NOT running idly at all
-- times — resource-performance-profiler's lens: this must not become a
-- tight always-on loop for a feature most players never touch), that on
-- each ~1000ms tick (a cleanup/safety poll, not a rendering concern — no
-- sub-frame precision needed for any of these three conditions) checks,
-- IN ORDER:
--   1. IsEntityDead(PlayerPedId()) -> if true, force both SetSeethrough(false)
--      and SetNightvision(false) off (§11.6's "player death" exit path —
--      not automatic, the natives have "no automatic reset" full stop).
--   2. not IsOwnModelK9() -> if the player's live model has stopped being
--      a configured K9 model (the same rare appearance-swap edge case
--      SPEC.md §9 item 8 flags for certification, applied here as a
--      direct corollary of the exact gate ToggleThermalVision()/
--      ToggleNightVision() already use in §3 above — "if the gate that
--      allows turning it on no longer holds, the same check should also
--      be able to turn it back off") -> force both off.
--   3. HasK9Access() (client/main.lua's existing global, already
--      TTL-cached ~1000ms per phase2_notes/EXPORT_TRACKING.md's Phase 1
--      contract table — this REUSES that existing cache, does not add a
--      new server round-trip) has transitioned from true to false since
--      this thread's own LAST tick -> force both off. This is a
--      deliberate, accepted ~1s-latency POLLING detection, not an event
--      push, and is a one-time defensive UX courtesy per §11.6's stated
--      rationale ("a player left in a stuck thermal/NV view after losing
--      K9 access would be a real bug") — it does NOT, and structurally
--      cannot, prevent the player from immediately toggling it back on a
--      moment later, since the toggle itself is deliberately gated on
--      IsOwnModelK9() only (§3 above), not on HasK9Access() at all. Do
--      not build this into a persistent "vision disabled while
--      uncertified" state machine — that would contradict the RESOLVED
--      ACCESS-GATING DECISION above. (Open escalation path, not decided
--      here: if ~1s polling latency proves noticeable in QA,
--      phase2_notes/thermal_night_vision.md §6's "Open question flagged
--      for coder-backend" proposes a small additive
--      'qbx_k9unit:client:k9AccessRevoked' broadcast from
--      server/certifications.lua's two revoke paths instead — not the
--      default here, since it means reopening an already-reviewed Phase
--      1 file for a Phase 2 concern.)
--   4. Once BOTH effects are off (checked at the top of each iteration),
--      the thread exits — no reason to keep polling once there's nothing
--      left to clean up; the next Toggle*Vision() call that turns
--      something on restarts it.

-- Resource-stop safety net — mirrors client/vehicle.lua's ALREADY-SHIPPED
-- onResourceStop pattern for the identical underlying reason: per SPEC.md
-- §11.5's own thermal-vision acceptance bullet, "the native effect itself
-- persists across a resource restart independent of script state, exactly
-- the same class of bug client/vehicle.lua's header already documents and
-- fixes for vehicle entry/exit." Unlike the maintenance thread above
-- (genuinely open tick-rate/ordering questions), this handler's body is a
-- zero-ambiguity, spec-mandated pair of native calls — safe to write
-- directly rather than leaving as a TODO. Force BOTH off unconditionally,
-- regardless of which (if either) was actually on this session: both
-- natives are idempotent boolean toggles, not stacking counters, so
-- calling SetSeethrough(false)/SetNightvision(false) when an effect was
-- never on this session is a harmless no-op (phase2_notes/thermal_night_vision.md
-- §6 item 2). Also covers disconnect per that note's §6 item 3 (FiveM
-- stops every currently-loaded resource, firing this same handler, as
-- part of a player disconnecting) — high confidence per that note's own
-- reasoning, flagged there as "verify this assumption once real code
-- exists" rather than asserted with certainty, since it was not
-- independently tested in-engine this session.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    SetSeethrough(false)
    SetNightvision(false)
end)
