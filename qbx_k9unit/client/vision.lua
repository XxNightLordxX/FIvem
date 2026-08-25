--[[
    qbx_k9unit/client/vision.lua

    Phase 2 (coder-frontend). fxmanifest.lua lists this file under
    client_scripts, config.lua's Config.Vision (§11.2) has landed, and
    client/radial.lua deliberately gets NO items for this feature (this is
    keybind-only, by design — see below).

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
local function EnsureOnlyOneVisionEffectActive(keepingActive)
    -- Checked via the Is*Active() getters above (authoritative,
    -- native-backed), never a locally-tracked boolean that could desync —
    -- same reasoning as the getters themselves.
    if keepingActive == 'thermal' and IsNightVisionActive() then
        SetNightvision(false)
    elseif keepingActive == 'night' and IsThermalVisionActive() then
        SetSeethrough(false)
    end
end

-- Maintenance/cleanup thread lifecycle guard — see the thread definition
-- further below for the full shape. Started explicitly from each
-- Toggle*Vision() function's "turning on" branch rather than an
-- always-idling poll (unlike client/movement.lua's leash thread, which can
-- afford to idle at 1000ms forever since it's a single perpetual thread for
-- a Phase 1 feature already always loaded) — resource-performance-profiler's
-- lens: a feature most players never touch should not run any thread at
-- all until it's actually used at least once.
local visionMaintenanceThreadRunning = false

--- Starts the maintenance/cleanup thread (see below) if it isn't already
--- running. Safe to call from both Toggle*Vision() functions on every
--- "turning on" transition — a no-op if the thread is already active.
local function EnsureVisionMaintenanceThreadRunning()
    if visionMaintenanceThreadRunning then return end
    visionMaintenanceThreadRunning = true

    CreateThread(function()
        -- Captured once at thread start, then refreshed every tick below —
        -- this is what makes the HasK9Access() check a TRANSITION check
        -- (true -> false) rather than a plain "is it currently false"
        -- check. This distinction matters: the toggle itself is
        -- deliberately gated on IsOwnModelK9() only (see the RESOLVED
        -- ACCESS-GATING DECISION in this file's header), so a player who
        -- never had K9 access at all (always false) must NOT have their
        -- vision force-cleared by this thread every tick — only a player
        -- who HAD access and just lost it gets the one-time defensive
        -- clear.
        local hadK9Access = HasK9Access()

        while IsThermalVisionActive() or IsNightVisionActive() do
            Wait(1000) -- cleanup/safety poll, not a rendering concern — no sub-frame precision needed

            if IsEntityDead(PlayerPedId()) then
                -- §11.6's "player death" exit path — not automatic, the
                -- natives have "no automatic reset" full stop.
                SetSeethrough(false)
                SetNightvision(false)
            elseif not IsOwnModelK9() then
                -- The player's live model has stopped being a configured
                -- K9 model (the same rare appearance-swap edge case SPEC.md
                -- §9 item 8 flags for certification) — a direct corollary
                -- of the exact gate Toggle*Vision() already uses: if the
                -- gate that allows turning it on no longer holds, the same
                -- check should also be able to turn it back off.
                SetSeethrough(false)
                SetNightvision(false)
            else
                -- Deliberate ~1s-latency POLLING detection, not an event
                -- push — a one-time defensive UX courtesy (§11.6: "a player
                -- left in a stuck thermal/NV view after losing K9 access
                -- would be a real bug"). Does NOT, and structurally cannot,
                -- prevent the player from immediately toggling it back on a
                -- moment later, since the toggle itself is gated on
                -- IsOwnModelK9() only, never on HasK9Access() — this is not
                -- a persistent "vision disabled while uncertified" state
                -- machine.
                local hasK9Access = HasK9Access()
                if hadK9Access and not hasK9Access then
                    SetSeethrough(false)
                    SetNightvision(false)
                end
                hadK9Access = hasK9Access
            end
        end

        -- Once both effects are off (checked at the top of the loop above,
        -- including immediately after this iteration's own force-off), the
        -- thread exits — no reason to keep polling once there's nothing
        -- left to clean up. The next Toggle*Vision() call that turns
        -- something on calls EnsureVisionMaintenanceThreadRunning() again.
        visionMaintenanceThreadRunning = false
    end)
end

--- Toggles GTA's built-in heat-vision effect. SPEC.md §11.5/§11.6:
--- SetSeethrough(BOOL) — confirmed real, toggle-and-forget (no per-frame
--- re-assertion needed to HOLD the effect, only the maintenance/cleanup
--- thread further below is needed, and only while at least one vision
--- effect is active).
--- See RESOLVED ACCESS-GATING DECISION above: gates on IsOwnModelK9()
--- only, NOT CanShowK9UI().
function ToggleThermalVision()
    if not IsOwnModelK9() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.not_k9_model'), type = 'error' })
        return
    end

    local turningOn = not IsThermalVisionActive()
    -- Mutual exclusion happens BEFORE flipping this effect on, per
    -- phase2_notes/thermal_night_vision.md §4's ordering.
    if turningOn then
        EnsureOnlyOneVisionEffectActive('thermal')
    end

    SetSeethrough(turningOn)
    lib.notify({
        title = locale('common.notify_title'),
        description = turningOn and locale('vision.thermal_on') or locale('vision.thermal_off'),
        type = 'info',
    })

    if turningOn then
        EnsureVisionMaintenanceThreadRunning()
    end
end

--- Toggles GTA's built-in night-vision-goggle effect. SPEC.md §11.5/§11.6:
--- SetNightvision(BOOL) — confirmed real, same toggle-and-forget shape as
--- thermal above. Identical shape to ToggleThermalVision() above,
--- substituting SetNightvision/IsNightVisionActive and
--- EnsureOnlyOneVisionEffectActive('night').
function ToggleNightVision()
    if not IsOwnModelK9() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.not_k9_model'), type = 'error' })
        return
    end

    local turningOn = not IsNightVisionActive()
    if turningOn then
        EnsureOnlyOneVisionEffectActive('night')
    end

    SetNightvision(turningOn)
    lib.notify({
        title = locale('common.notify_title'),
        description = turningOn and locale('vision.night_on') or locale('vision.night_off'),
        type = 'info',
    })

    if turningOn then
        EnsureVisionMaintenanceThreadRunning()
    end
end

-- Config-gated command + keybind registration for BOTH toggles — SPEC.md
-- §11.2's Config.Vision schema,
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
if Config.Features.ThermalVision then
    RegisterCommand('qbx_k9unit:toggleThermalVision', function() ToggleThermalVision() end, false)
    RegisterKeyMapping('qbx_k9unit:toggleThermalVision', locale('vision.thermal_keybind_label'), 'keyboard', Config.Vision.Thermal.toggleKey)
end
if Config.Features.NightVision then
    RegisterCommand('qbx_k9unit:toggleNightVision', function() ToggleNightVision() end, false)
    RegisterKeyMapping('qbx_k9unit:toggleNightVision', locale('vision.night_keybind_label'), 'keyboard', Config.Vision.Night.toggleKey)
end
-- NOT added to client/radial.lua at all — per §11.3's file-plan row,
-- "Vision toggles and door interaction are not added to the radial...
-- consistent with the camera toggle's existing precedent."

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
