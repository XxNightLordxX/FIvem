--[[
    qbx_k9unit/client/tracking.lua

    Phase 2 (coder-frontend). Owns the three self-initiated "Track <Type>"
    trail mechanics (scent, blood, gunpowder) and the water-crossing degrade
    modifier that applies to whichever trail is currently rendering —
    DEVELOPER_REFERENCE.md §11.1 sub-phases 2d/2e/2f, §11.3's `client/tracking.lua` row.
    All three trail types share ONE file (not one file per type) and call
    ONE parameterized server callback, per §11.3/§11.4 item 1.

    Supplementary implementation detail (non-authoritative — DEVELOPER_REFERENCE.md §11 is
    the source of truth if anything here drifts from it):
    DEVELOPER_REFERENCE.md#tracking, DEVELOPER_REFERENCE.md#tracking,
    DEVELOPER_REFERENCE.md#tracking, DEVELOPER_REFERENCE.md#tracking.
    NOTE ON THE "§N" SUFFIXES cited below (e.g. "#tracking §1.2", "#tracking
    §0"): those are leftover pinpoints from the pre-2026-08-25 research
    archive's own internal numbering, which did not survive that file's
    consolidation into DEVELOPER_REFERENCE.md's §15 prose — see that
    section's own header note for the full explanation. Read the anchor
    (#tracking) as the real target; the number after it will not resolve to
    a matching subsection.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per DEVELOPER_REFERENCE.md §11.4 items 1, 3, 4 and
    item 7's "no dedicated result-delivery event" note. Server side lives in
    server/tracking.lua (confirmed against that file's own header as of this
    pass — same contract, no drift).

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:findTrackableSource' (trackType: 'scent'|'blood'|'gunpowder')
       -> { found: boolean, coords: vector3?, breaksAtWater: boolean }
       [server/tracking.lua]
       Re-validates Config.Features.<Type> and HasK9Access(source)
       server-side regardless of client UI state. Resolves the CALLER'S
       OWN live server-side position — never a client-supplied coordinate.
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.
       `breaksAtWater` is documented (§11.4 item 1) as informational only
       — since config.lua is a shared_script, THIS FILE reads
       Config.WaterTrackingDecay.breaksTrail directly rather than trusting
       this echoed field (DEVELOPER_REFERENCE.md#tracking §1.2).
       No `reason` field exists on this response (unlike searchTarget's) —
       "nothing nearby" / "on cooldown" / "no access" all collapse to the
       same `found = false` here; ship one generic message
       (DEVELOPER_REFERENCE.md#tracking §2.4).

    Server events (RegisterNetEvent, client->server; THIS FILE triggers,
    does not receive, these two):
    2. 'qbx_k9unit:server:relayDamageEvent' () [server/tracking.lua]
       Fired by THIS FILE's own 'gameEventTriggered' handler below when the
       LOCAL player is the CEventNetworkEntityDamage victim. No payload —
       the server resolves the reporting client's own live coordinates
       itself, this file never sends a coordinate.
    3. 'qbx_k9unit:server:relayWeaponFire' () [server/tracking.lua]
       Fired by THIS FILE on a debounced false->true transition of
       IsPedShooting(PlayerPedId()). No payload, same reasoning as above.
    4. 'qbx_k9unit:server:reportTrackSourceArrival' () [server/tracking.lua]
       PHASE 4 ADDITION (Config.Features.XPProgression,
       Config.XP.awards.trackSourceResolved). Fired by THIS FILE's render
       thread below the FIRST tick it observes its own live distance to the
       resolved source coordinate drop to/below Config.XP.trackArrivalRadius
       — gated by a per-session `trackingState.arrivalReported` flag so it
       fires exactly once per resolved source, never once per tick (the
       server's own TrackArrivalReportCooldown is defense-in-depth against a
       modified client, not something this file relies on to paper over a
       spam-every-frame implementation here). No payload — this is a
       TRIGGER only, never a claimed distance/arrival boolean/coordinate;
       the server re-measures the caller's own live position against its
       own server-held resolved coordinate before awarding anything (see
       server/tracking.lua's own doc comment on this handler).

    No other client events (server->client) for this file at all — §11.4
    item 7 is explicit that tracking-result delivery is request/response
    shaped (the callback above), not a fire-and-forget event pair, matching
    the already-shipped 'qbx_k9unit:server:hasK9Access' pattern.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes five resource-global (no `local`) functions,
      consumed by client/radial.lua's "Track Scent" / "Track Blood" /
      "Track Gunpowder" items per §11.3's radial.lua row. UPDATED (stale
      "not wired yet" note removed, integration-verifier finding): all five
      are confirmed called from client/radial.lua as of this pass — see
      that file's Track Scent/Blood/Gunpowder item handlers, which use
      GetActiveTrackType()/StopTracking() to distinguish "toggle off THIS
      type" from "a DIFFERENT type is active, defer to StartTrack()'s own
      rejection" before calling the matching Start*Track():
        StartScentTrack()
        StartBloodTrack()
        StartGunpowderTrack()
        StopTracking()   -- not named by DEVELOPER_REFERENCE.md §11 itself; fills the
            open gap DEVELOPER_REFERENCE.md#tracking §2.1/§5 item 2
            flags (no self-service "stop" affordance is specified anywhere
            in §11's acceptance criteria) — a manual-cancel item, mirroring
            Attach/Detach Leash's single context-sensitive radial item.
        IsTracking() -> boolean
        GetActiveTrackType() -> 'scent'|'blood'|'gunpowder'|nil
    - THIS FILE calls client/main.lua's HasK9Access() at the top of every
      Start*Track() call — "don't trust the caller already checked," the
      same posture client/movement.lua's RequestLeashAttach() documents for
      itself. UPDATED (ANY-PED SWEEP FIX, this pass): this used to be
      CanShowK9UI(), which is strictly narrower than what
      server/tracking.lua's own findTrackableSource actually enforces
      (HasK9Access(source) alone, by that file's own explicit design —
      see StartTrack()'s own doc comment below for the full writeup).
    - THIS FILE reads Config.Tracking.Scent / .Blood / .Gunpowder and
      Config.WaterTrackingDecay (DEVELOPER_REFERENCE.md §11.2's config.lua additions,
      confirmed landed in config.lua as of this pass, including the
      relayCooldownMs amendments beyond §11.2's original text — those
      fields are server/tracking.lua's own concern, not read by this file).
    - PHASE 4 ADDITION: THIS FILE also reads Config.Features.XPProgression
      and Config.XP.trackArrivalRadius (config.lua is a shared_script, same
      access pattern as the Config.Tracking reads above) to decide WHEN to
      fire event 4 above — never to decide whether to award XP itself (that
      stays entirely server-side, server/tracking.lua's own concern).

    DEPENDENCY NOTE: this file has no compile-time dependency on
    client/search.lua (different trust model, different file) or
    client/vision.lua (unrelated feature). Load order relative to those two
    doesn't matter.

    ======================================================================
    LEGIBILITY FIX (this pass, coder-frontend) — every OTHER way a trail
    can stop already says so (water break: 'tracking.trail_lost_water';
    manual stop: silent BY DESIGN, per StopTracking()'s own doc comment,
    since the keypress itself is the feedback). The one remaining ending —
    the K9's own death mid-track, which already forced a StopTracking()
    call — said nothing at all: the markers this player was watching just
    stopped appearing, indistinguishable from the render thread having
    broken. Fixed at that one call site (see the OWN-DEATH EXIT PATH branch
    below) with a new notify, not inside StopTracking() itself, so the
    manual-stop path's own deliberate silence is untouched. New locale key,
    see this pass's report: tracking.trail_lost_death. Every other flow in
    this file (start refusals, the already-tracking/starting-in-progress
    guards, the trail render itself as the visible "still live" state, and
    arrival — which deliberately stays a client-side non-event per this
    file's own "never hand the player the answer" design, left to
    server/findalert.lua's existing bark-and-sit reaction on
    'qbx_k9unit:server:reportTrackSourceArrival', Config.FindAlerts.
    reactOnTrackArrival, default on) was reviewed and left unchanged this
    pass.
    ======================================================================
]]

--- Local-only view of the CURRENT tracking session, if any. Set by a
--- successful Start*Track() call below, cleared by StopTracking() or by
--- the state/compute thread's own water-break/own-death bookkeeping below.
--- Not exposed directly — always go through IsTracking()/StopTracking().
--- `arrivalReported` (PHASE 4 addition): set true the first tick this
--- session's live distance to `coords` drops to/below
--- Config.XP.trackArrivalRadius, so 'qbx_k9unit:server:reportTrackSourceArrival'
--- fires exactly once per resolved source — see this file's header EVENT/
--- CALLBACK CONTRACT item 4 and the state/compute thread below.
--- @type { trackType: 'scent'|'blood'|'gunpowder', coords: vector3, breaksAtWater: boolean, brokenByWater: boolean, arrivalReported: boolean } | nil
local trackingState = nil

--- CORRECTNESS FIX (coder-frontend, this pass): cached snapshot of the
--- current tick's trail markers, `{ coords: vector3, underwater: boolean }[]`,
--- or nil when nothing should currently be rendered. Populated by the
--- state/compute thread below every TRACK_TICK_MS, then drawn EVERY FRAME by
--- a separate, lightweight render thread further below. This split exists
--- because DrawMarker (like every GTA "draw this frame" native) only stays
--- visible for the single frame it's called on — the previous single-thread
--- implementation called DrawMarker only once per TRACK_TICK_MS (250ms,
--- ~15 frames at 60fps), so the trail was actually only ever visible for 1
--- out of every ~15 rendered frames: a hard strobe/flicker, not a rendered
--- trail, despite the old code's own header comment already flagging that
--- "DrawMarker itself needs calling every frame it should be visible."
--- Cleared to nil (never left stale) by StopTracking() and by the
--- state/compute thread itself the moment there is nothing left to draw
--- (not tracking, water-broken, or already arrived at the source).
--- @type { coords: vector3, underwater: boolean }[] | nil
local currentTrailMarkers = nil

--- @return boolean
function IsTracking()
    return trackingState ~= nil
end

--- In-flight guard + staleness token for StartTrack()'s awaited server
--- callback (qa-tester finding, this pass): `lib.callback.await` yields for
--- the duration of a full server round-trip, during which `trackingState`
--- is still nil/unchanged, so neither `IsTracking()` nor
--- `trackingState.brokenByWater` can catch a second concurrent
--- Start*Track() call, or a StopTracking() call, that happens WHILE the
--- first call is still pending. `startInFlight` rejects a second concurrent
--- Start*Track() outright (cheap — never even issues a second server
--- callback). `trackRequestGeneration` additionally guards against the
--- narrower race `startInFlight` alone can't close: StopTracking() firing
--- while the ONE in-flight request is still pending, which must not let
--- that pending request "resurrect" a session the player already
--- explicitly stopped once it finally resolves.
local startInFlight = false
local trackRequestGeneration = 0

--- @return 'scent'|'blood'|'gunpowder'|nil
--- regression-tester finding: client/radial.lua's three Track items each
--- need to tell "currently tracking THIS type (real toggle-off)" apart from
--- "currently tracking a DIFFERENT type (should hit StartTrack()'s own
--- 'already tracking — stop first' rejection/notify, not silently cancel
--- the wrong trail)". IsTracking() alone can't make that distinction.
function GetActiveTrackType()
    return trackingState and trackingState.trackType or nil
end

--- Shared implementation behind StartScentTrack()/StartBloodTrack()/
--- StartGunpowderTrack() below. DEVELOPER_REFERENCE.md §11.5's three trail-type
--- acceptance-criteria blocks are textually identical (only the trackType
--- string and its Config.Tracking.<Type> sub-table differ), so this is one
--- function instead of three near-duplicate copies — mirrors e.g.
--- client/vehicle.lua's ReleasePedFromVehicleState being shared rather than
--- duplicated.
--- @param trackType 'scent'|'blood'|'gunpowder'
local function StartTrack(trackType)
    -- ANY-PED SWEEP FIX (coder-frontend, this pass — coordinator finding:
    -- "StartTrack() gates on CanShowK9UI(), which is stricter than what the
    -- server itself checks (HasK9Access(source) alone in
    -- findTrackableSource) — a role-holder the server would allow can be
    -- refused by their own client"). CanShowK9UI() (client/main.lua) is
    -- `IsK9Role() and HasK9Access()` at the Config.K9Appearance.
    -- requireK9ModelForRole == false default (or `IsOwnModelK9() and
    -- HasK9Access()` otherwise) — either way it ANDs in an extra role/model
    -- check on top of HasK9Access(). server/tracking.lua's own
    -- findTrackableSource has NO such extra check: that file's header FILE-
    -- TO-FILE CONTRACT states outright "tracking access is gated purely on
    -- HasK9Access (job + certification), never on the caller's CURRENT ped
    -- model" and deliberately does not call IsConfiguredK9Model, flagging
    -- that a future edit must not "helpfully" add one. A K9-role holder
    -- whose access comes from server/certifications.lua's HasK9Access()
    -- High Command/autoAccessGrade bypass — which IsK9Role() deliberately
    -- EXCLUDES per server/appearance.lua's own header — therefore failed
    -- BOTH halves of the old CanShowK9UI() gate on a non-K9 body
    -- (IsOwnModelK9() false, IsK9Role() false) even though the server would
    -- have answered `found = true` for the identical request: this client
    -- silently refused an action its own server-side authority would have
    -- granted, exactly the "checks whether a player is SHAPED like a dog
    -- where it should check whether they HOLD the role" pattern this sweep
    -- exists to close. Fixed by gating on HasK9Access() alone instead,
    -- matching the server's own real boundary exactly, and reusing this
    -- resource's own established precedent for a role-not-model gate:
    -- client/fetch.lua's RequestThrowFetchBall() and client/radial.lua's
    -- "Throw" item are both documented as deliberately "HasK9Access() alone,
    -- NOT CanShowK9UI()/IsOwnModelK9()" for the identical reason (a
    -- human-handler action must not depend on being modeled as a K9), and
    -- client/movement.lua's RecomputeK9MoveRate() was independently widened
    -- the same way in this same sweep. See
    -- tests/clienttracking_spec.lua for the regression pinning this: a
    -- HasK9Access()-true, IsK9Role()-false, non-K9-model caller must still
    -- reach the real findTrackableSource callback path, not a stubbed
    -- replacement of the function under test.
    if not HasK9Access() then
        -- Migrated to the shared client/main.lua helper (DEVELOPER_REFERENCE.md
        -- Part B item 1 -- formerly DEVELOPER_REFERENCE.md, merged 2026-08-25)
        -- — this was the last raw inline copy of the
        -- common.no_k9_access lib.notify() pattern; DenyK9UIAccess()'s own
        -- payload (title/description/type) is byte-identical to what this
        -- call site used to build directly.
        DenyK9UIAccess()
        return
    end

    -- OPEN QUESTION, not decided by DEVELOPER_REFERENCE.md §11 (DEVELOPER_REFERENCE.md#tracking
    -- §2.1/§5 item 2): should starting a NEW track type while already
    -- tracking something else silently replace the old session, or be
    -- rejected until StopTracking() is called first? This implementation
    -- rejects, matching IsLeashed()'s own "already leashed" rejection in
    -- client/movement.lua's RequestLeashAttach() — flagging the choice
    -- rather than silently picking the other way. A session already broken
    -- by water is NOT treated as "already tracking" for this check — §11.5
    -- requires "a fresh 'Track <Type>' command" to re-acquire after a water
    -- break to actually work, which would be permanently impossible if a
    -- broken session still counted as blocking a new one (with no
    -- self-service StopTracking() affordance wired into client/radial.lua
    -- yet to clear it manually).
    if IsTracking() and not trackingState.brokenByWater then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.already_tracking'), type = 'error' })
        return
    end

    -- In-flight guard (qa-tester finding, this pass) — reject a second
    -- concurrent Start*Track() outright rather than letting two overlapping
    -- lib.callback.await calls race each other; see this function's own
    -- startInFlight/trackRequestGeneration declaration comment above for
    -- the full race description.
    if startInFlight then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.starting_in_progress'), type = 'error' })
        return
    end

    startInFlight = true
    trackRequestGeneration = trackRequestGeneration + 1
    local myGeneration = trackRequestGeneration

    -- FAIL-CLOSED GUARD (dependency-verification finding, this pass):
    -- `lib.callback.await` throws rather than returning nil on a timeout
    -- or unregistered-callback rejection (see client/main.lua's
    -- HasK9Access() doc comment for the full ox_lib/FiveM source
    -- citation). Uncaught here, a throw would skip the `startInFlight =
    -- false` reset below entirely, permanently wedging `startInFlight`
    -- true and bricking every future Start*Track() call for the rest of
    -- this client's session (this function's own in-flight-guard comment
    -- above already flags why that flag must always get reset). pcall it;
    -- the `not result or not result.found` branch further below already
    -- treats a nil `result` the same as "nothing nearby."
    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:findTrackableSource', false, trackType)
    if not ok then result = nil end

    startInFlight = false

    -- Staleness check — if StopTracking() (or, defensively, another
    -- Start*Track() call) ran WHILE the await above was pending, this
    -- result is stale and must not resurrect/stomp whatever the player's
    -- most recent action actually was.
    if myGeneration ~= trackRequestGeneration then
        return
    end

    -- NOTE: §11.4 item 1's response shape has no `reason` field (unlike
    -- searchTarget's, §11.4 item 2), so "nothing nearby" / "on cooldown" /
    -- "no access" all collapse to the same found = false here
    -- (DEVELOPER_REFERENCE.md#tracking §2.4) — ship one generic
    -- message, don't invent a distinction the server doesn't give data for.
    if not result or not result.found then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.nothing_to_track'), type = 'error' })
        return
    end

    -- Read breaksTrail from the LOCAL shared_script config directly rather
    -- than trusting result.breaksAtWater (documented informational-only,
    -- see this file's EVENT/CALLBACK CONTRACT above).
    trackingState = {
        trackType = trackType,
        coords = result.coords,
        breaksAtWater = Config.WaterTrackingDecay.breaksTrail,
        brokenByWater = false,
        arrivalReported = false, -- PHASE 4 addition, see this file's header EVENT/CALLBACK CONTRACT item 4
    }
    -- Setting trackingState is sufficient to "wake" the render thread below
    -- — mirrors the exact comment already on client/movement.lua's
    -- leashAttached handler ("simply setting it here is sufficient... no
    -- separate thread-start call needed").
end

--- Radial-facing entry point for scent tracking (Config.Features.ScentTracking).
--- DEVELOPER_REFERENCE.md §11.3's client/radial.lua row calls this by this exact name —
--- do not rename without also updating that row and radial.lua's own
--- Track Scent item, which calls this directly (confirmed wired, see this
--- file's header FILE-TO-FILE CONTRACT).
function StartScentTrack()
    StartTrack('scent')
end

--- Radial-facing entry point for blood-trail tracking (Config.Features.BloodTracking).
function StartBloodTrack()
    StartTrack('blood')
end

--- Radial-facing entry point for gunpowder-residue tracking (Config.Features.GunpowderSniffing).
function StartGunpowderTrack()
    StartTrack('gunpowder')
end

--- Manual cancel — fills the open gap DEVELOPER_REFERENCE.md#tracking
--- §2.1/§5 item 2 flags (no self-service "stop" affordance is specified
--- anywhere in DEVELOPER_REFERENCE.md §11 itself, only a fresh Start*Track() call after a
--- water-break). No-op if not currently tracking. Silent, cosmetic,
--- low-stakes action (per §11.6's framing of tracking as "no real
--- capability granted") — no confirmation notification needed, matching
--- how DetachLeash() doesn't narrate every internal-state clear either.
function StopTracking()
    -- Bumps trackRequestGeneration so a StartTrack() call still awaiting
    -- its server callback at the moment this runs discards its eventual
    -- result as stale instead of resurrecting the session being stopped
    -- here — see StartTrack()'s own startInFlight/trackRequestGeneration
    -- declaration comment (qa-tester finding, this pass) for the full race.
    trackRequestGeneration = trackRequestGeneration + 1
    trackingState = nil
    -- Explicitly cleared here (not left for the state thread to notice on
    -- its own next tick) so the separate per-frame render thread stops
    -- drawing the instant this is called, rather than up to one
    -- TRACK_TICK_MS late — a stale trail rendering for up to 250ms after an
    -- explicit stop would be exactly the "half-started/leftover trail" this
    -- file is required to avoid.
    currentTrailMarkers = nil
    -- The state thread below naturally idles once IsTracking() is false,
    -- mirroring how client/movement.lua's DetachLeash() comment describes
    -- its own elastic thread "naturally stopping" once IsLeashed() is
    -- false — no separate thread-teardown call needed.
end

-- State/compute thread. Reuses the exact idle/active tick-rate-switch
-- pattern client/movement.lua's leash pull-back thread already establishes
-- (its LEASH_TICK_MS / LEASH_IDLE_TICK_MS constants) — sleeps long while
-- IsTracking() is false, switches to a short tick only while a session is
-- active. CORRECTNESS FIX (coder-frontend, this pass): this thread now only
-- RECOMPUTES the trail (distance, water-crossing sampling, arrival check)
-- at this cadence and writes the result into `currentTrailMarkers` above —
-- it no longer calls DrawMarker directly. The old single-thread version
-- called DrawMarker only once per TRACK_TICK_MS (250ms, ~15 frames at
-- 60fps), which — despite this exact comment already flagging that
-- "DrawMarker itself needs calling every frame it should be visible" —
-- meant the trail was only ever actually visible for 1 out of every ~15
-- rendered frames: a hard strobe, not a rendered trail. The dedicated
-- per-frame render thread further below now owns calling DrawMarker every
-- frame from the cached snapshot this thread produces, so the recompute
-- cost stays at this cheap interval while the visual is actually
-- continuous.
local TRACK_TICK_MS = 250
local TRACK_IDLE_TICK_MS = 1000

-- trackType -> the Config.Tracking sub-table holding its tuning values.
-- Built once at file load rather than re-derived per tick via a
-- ternary/if-else chain (refactor-strategist finding, cosmetic-only, zero
-- behavior change) -- mirrors server/tracking.lua's own TRACK_TYPE_CONFIG
-- lookup table for the identical trackType-to-config mapping.
local TRACKING_STATE_CONFIG = {
    scent = Config.Tracking.Scent,
    blood = Config.Tracking.Blood,
    gunpowder = Config.Tracking.Gunpowder,
}

-- DrawMarker type 1 = a flat cylinder/checkpoint ring — a reasonable,
-- unremarkable choice for a ground breadcrumb (matches the "checkpoint"
-- framing DEVELOPER_REFERENCE.md#tracking §3 item 4 uses).
local TRAIL_MARKER_TYPE = 1
local TRAIL_MARKER_SCALE = 0.5
local TRAIL_MARKER_COLOR = { r = 255, g = 220, b = 90, a = 180 }
local TRAIL_MARKER_COLOR_UNDERWATER_ALPHA = 60 -- reduced-opacity rendering for breaksTrail == false, per §11.5

--- Draws one breadcrumb marker at `coords`, at reduced alpha if `underwater`.
--- Not independently native-verified this pass (DrawMarker is a
--- long-standing, extremely well-established FiveM/GTA native per
--- DEVELOPER_REFERENCE.md#tracking §4 — not re-verified against
--- current docs this session, same "high confidence, not re-confirmed"
--- caveat that note already flags).
--- @param coords vector3
--- @param underwater boolean
local function DrawTrailMarker(coords, underwater)
    local alpha = underwater and TRAIL_MARKER_COLOR_UNDERWATER_ALPHA or TRAIL_MARKER_COLOR.a
    DrawMarker(
        TRAIL_MARKER_TYPE,
        coords.x, coords.y, coords.z - 0.9,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE,
        TRAIL_MARKER_COLOR.r, TRAIL_MARKER_COLOR.g, TRAIL_MARKER_COLOR.b, alpha,
        false, false, 2, false, '', '', false
    )
end

--- Samples the live line from `startCoords` to `endCoords` for a water
--- crossing, per Config.WaterTrackingDecay.sampleIntervalMeters. Returns
--- the distance along the line to the first water hit, or nil if none
--- found before reaching endCoords.
--- Uses GetWaterHeightNoWaves — NOT plain GetWaterHeight, per
--- DEVELOPER_REFERENCE.md#tracking §1's explicit recommendation
--- (frame-stable, appropriate for a fixed-step poll like this; plain
--- GetWaterHeight is wave-jittered and can disagree between adjacent
--- samples on a calm shoreline). CORRECTION (final native-correctness
--- sweep, this session): the native's `float* height` out-param becomes an
--- extra Lua RETURN value, not an input argument — called here as
--- `GetWaterHeightNoWaves(x, y, z)` returning `(found, height)`, matching
--- the real, community-confirmed convention (e.g. the sibling
--- GetWaterHeight's own documented usage
--- `local retval, waterHeight = GetWaterHeight(x, y, z)`). The previous
--- trailing `0.0` argument was inert (Lua silently discards an extra
--- argument the function doesn't consume) — this was never a behavior
--- bug, only an inaccurate comment/call-shape cleanup. The height value
--- itself is still unused here, only the boolean matters.
--- @param startCoords vector3
--- @param endCoords vector3
--- @return number? distanceToWater
local function FindWaterCrossingDistance(startCoords, endCoords)
    local total = #(endCoords - startCoords)
    if total <= 0.0 then return nil end

    local dir = (endCoords - startCoords) / total
    -- Clamped defensively, mirroring client/movement.lua's leash thread
    -- precedent (math.max(_, 0.1), line ~388): a misconfigured
    -- Config.WaterTrackingDecay.sampleIntervalMeters of 0 (or negative)
    -- would otherwise spin this while loop forever with no Wait() inside
    -- it, freezing this thread until FiveM's watchdog intervenes.
    local step = math.max(Config.WaterTrackingDecay.sampleIntervalMeters, 0.1)
    local traveled = 0.0

    while traveled < total do
        local sample = startCoords + dir * traveled
        local found = GetWaterHeightNoWaves(sample.x, sample.y, sample.z)
        if found then
            return traveled
        end
        traveled = traveled + step
    end

    return nil
end

CreateThread(function()
    while true do
        local sleepMs = TRACK_IDLE_TICK_MS

        if IsTracking() and not trackingState.brokenByWater then
            local myPed = PlayerPedId()

            -- OWN-DEATH EXIT PATH (coder-frontend correctness pass, this
            -- session — not previously handled): mirrors this codebase's own
            -- established "own ped death forces an active perception/render
            -- feature to end" precedent (client/vision.lua's maintenance
            -- thread, client/propattachment.lua's "OWN-DEATH AUTO-DETACH").
            -- Continuing to recompute/render a scent/blood/gunpowder trail
            -- from a dead ped's position is narratively nonsensical and, on
            -- respawn, would silently resume rendering a "trail" from
            -- whatever coordinate the player respawns at — unrelated to the
            -- K9's actual path to the resolved source. StopTracking() clears
            -- trackingState AND currentTrailMarkers together and bumps
            -- trackRequestGeneration defensively, same as an explicit manual
            -- stop — a fresh "Track <Type>" is required after respawning,
            -- matching this file's existing "no self-service silent resume"
            -- precedent already established for the water-break case below.
            if IsEntityDead(myPed) then
                -- LEGIBILITY FIX (this pass) — StopTracking() itself stays
                -- silent by design for a MANUAL stop (see its own doc
                -- comment: "no confirmation notification needed"), but an
                -- own-death auto-stop is a genuinely different case: the
                -- trail markers this player was watching simply stop
                -- appearing, on this same tick, with nothing said about why
                -- — indistinguishable from the render thread having broken.
                -- Notified HERE, at this specific call site, not inside
                -- StopTracking() itself, so a manual stop (and the
                -- water-break/generation-staleness paths, which already
                -- have their own explicit notify or are deliberately silent
                -- per this file's own documented reasoning) are entirely
                -- unaffected. New locale key, see this pass's report:
                -- tracking.trail_lost_death.
                StopTracking()
                lib.notify({ title = locale('common.notify_title'), description = locale('tracking.trail_lost_death'), type = 'error' })
            else
                sleepMs = TRACK_TICK_MS

                local myCoords = GetEntityCoords(myPed)
                local sourceCoords = trackingState.coords

                -- Recomputed fresh every tick from the K9's LIVE position
                -- toward the fixed resolved source coordinate — NOT a
                -- one-time snapshot (DEVELOPER_REFERENCE.md#tracking
                -- §1.2: the K9's position moves every tick, the resolved
                -- source coordinate does not, for the lifetime of one
                -- Start*Track() call).
                local totalDist = #(sourceCoords - myCoords)

                -- PHASE 4 ADDITION (Config.Features.XPProgression,
                -- Config.XP.awards.trackSourceResolved) — see this file's
                -- header EVENT/CALLBACK CONTRACT item 4. Fired the FIRST
                -- tick our own live distance to the resolved source drops
                -- to/below Config.XP.trackArrivalRadius, gated by
                -- `arrivalReported` so a sustained standstill at the source
                -- doesn't retrigger this every tick — this is a TRIGGER
                -- only, the server re-measures its OWN live distance against
                -- its OWN stored coordinate before awarding anything
                -- (server/tracking.lua's reportTrackSourceArrival handler
                -- never trusts this call as a claim of arrival). Checked
                -- unconditionally (not nested inside the `totalDist > 0.1`
                -- marker-collection branch below) so arriving close enough
                -- that totalDist itself falls under 0.1 still reports — that
                -- branch only guards collecting markers along a remaining
                -- line, not this check.
                -- DELIBERATELY NOT gated on Config.Features.XPProgression.
                -- It used to be, because this event started life as this
                -- file's own XP trigger. It has a second, independent
                -- consumer now -- server/findalert.lua's trail-arrival
                -- bark-and-sit reaction -- and gating the SEND on an
                -- unrelated flag made that reaction silently dead whenever
                -- XPProgression was off, while FindAlerts' other reaction
                -- (search completion) kept working. That presents to an
                -- operator as "find alerts work for searches but not for
                -- tracking", with no reason to suspect an XP flag.
                -- Sending unconditionally is safe: server/tracking.lua's own
                -- handler returns early on Config.Features.XPProgression at
                -- its top, so no XP is minted when the flag is off. The
                -- server never trusts this as a claim of arrival either --
                -- it re-derives the distance itself.
                if not trackingState.arrivalReported
                    and totalDist <= Config.XP.trackArrivalRadius then
                    trackingState.arrivalReported = true
                    TriggerServerEvent('qbx_k9unit:server:reportTrackSourceArrival')
                end

                if totalDist > 0.1 then
                    local trackingConfig = TRACKING_STATE_CONFIG[trackingState.trackType]
                    local dir = (sourceCoords - myCoords) / totalDist

                    -- OPEN QUESTION, not resolved by DEVELOPER_REFERENCE.md §11 either way
                    -- (DEVELOPER_REFERENCE.md#tracking §2.3, §5 item 1):
                    -- reveal the WHOLE remaining line at once, or only a
                    -- capped preview window near the player? This
                    -- implementation reveals the whole remaining line —
                    -- simpler, and matches "a trail of markers toward the
                    -- nearest source" read literally — flagged per that
                    -- note's own recommendation to confirm with
                    -- product-manager/feature-ideation before this is
                    -- treated as final, not silently asserted as the only
                    -- right answer.
                    local waterCrossingDist = nil
                    -- PER-PERSON BLOCK (client/featureblocks.lua hand-off
                    -- item 1 -- see that file's own header for the full
                    -- contract this follows). This is the EASY hand-off
                    -- case that file's own header describes: this whole
                    -- branch already runs once per tick, unconditionally,
                    -- inside the compute thread above (TRACK_TICK_MS while
                    -- IsTracking() and not brokenByWater), so folding the
                    -- block check into this SAME existing condition is
                    -- enough, by itself, to make a block applied mid-trail
                    -- stop breaking trails at water within one tick, and a
                    -- block cleared mid-trail resume doing so within one
                    -- tick -- no new thread, no new poll, no new cost of any
                    -- kind. `type(...) == 'function'` guarded per this
                    -- resource's soft-dependency convention (see
                    -- client/featureblocks.lua's own header) -- if that file
                    -- is not loaded, this reads exactly as it did before
                    -- this pass (fails OPEN: water crossings still decay the
                    -- trail normally, never silently "always blocked").
                    if Config.Features.WaterTrackingDecay
                        and not (type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('WaterTrackingDecay')) then
                        waterCrossingDist = FindWaterCrossingDistance(myCoords, sourceCoords)

                        if waterCrossingDist and trackingState.breaksAtWater then
                            -- Hard break: stop rendering markers past the
                            -- crossing point, mark broken, notify, and do NOT
                            -- auto-resume — per §11.5's explicit "does not
                            -- silently resume" bullet, a fresh Start*Track()
                            -- call (subject to that type's own
                            -- searchCooldownMs) is required to re-acquire.
                            trackingState.brokenByWater = true
                            lib.notify({
                                title = locale('common.notify_title'),
                                description = locale('tracking.trail_lost_water'),
                                type = 'error',
                            })
                        end
                    end

                    -- Deliberately NOT gated on `not trackingState.
                    -- brokenByWater` here — the outer `IsTracking() and not
                    -- trackingState.brokenByWater` check (top of this tick's
                    -- block) already stops FUTURE ticks once broken, and the
                    -- break condition two lines above already cuts the line
                    -- off exactly at waterCrossingDist. Gating this loop on
                    -- brokenByWater too was a real bug: brokenByWater gets
                    -- set to true a few lines above in THIS SAME tick the
                    -- instant water is first detected anywhere on the
                    -- remaining path, so the old code skipped collecting
                    -- anything at all that tick — the whole trail (including
                    -- the already-walked near-bank portion) vanished
                    -- instantly instead of rendering up to the water's edge
                    -- as §11.5 requires. Running this loop unconditionally
                    -- lets the current tick still render the partial line
                    -- before the broken state takes effect next tick
                    -- (qa-tester/correctness-overseer finding).
                    -- Clamped defensively, same rationale/precedent as
                    -- FindWaterCrossingDistance's own `step` clamp above: a
                    -- misconfigured Config.Tracking.<Type>.markerSpacing of 0
                    -- (or negative) would otherwise spin this while loop
                    -- forever with no Wait() inside it (qa-tester finding).
                    local markerStep = math.max(trackingConfig.markerSpacing, 0.1)
                    local traveled = 0.0
                    local markers = {}
                    while traveled < totalDist do
                        -- If breaksTrail, stop rendering past the crossing
                        -- point entirely. If not breaksTrail (soft fade),
                        -- keep rendering past it at reduced alpha — the
                        -- sampling logic runs identically either way, only
                        -- the marker-drawing parameter changes (§11.5).
                        if waterCrossingDist and trackingState.breaksAtWater and traveled >= waterCrossingDist then
                            break
                        end

                        local markerCoords = myCoords + dir * traveled
                        local underwater = waterCrossingDist ~= nil and traveled >= waterCrossingDist
                        markers[#markers + 1] = { coords = markerCoords, underwater = underwater }

                        traveled = traveled + markerStep
                    end

                    -- Handed off to the dedicated per-frame render thread
                    -- below — see currentTrailMarkers' own declaration
                    -- comment for why DrawMarker itself must not be called
                    -- from this (only-every-TRACK_TICK_MS) thread directly.
                    currentTrailMarkers = markers
                else
                    -- Already at (or within 0.1m of) the resolved source —
                    -- nothing left to render.
                    currentTrailMarkers = nil
                end
            end
        else
            -- Not tracking, or the trail just broke at water (that break's
            -- own final partial-line snapshot was already produced by the
            -- branch above on the exact tick the break was first detected —
            -- see the comment on that branch). Cleared explicitly here on
            -- every subsequent idle tick, rather than left for the render
            -- thread to infer on its own, so a stopped/broken trail's last
            -- rendered frame does not keep rendering forever — exactly the
            -- kind of indefinite, self-inflicted "stuck visual" this file is
            -- required to avoid.
            currentTrailMarkers = nil
        end

        Wait(sleepMs)
    end
end)

-- Per-frame render thread (CORRECTNESS FIX, coder-frontend, this pass) —
-- see currentTrailMarkers' own declaration comment above for the full
-- writeup of the bug this closes (DrawMarker previously only being invoked
-- once per TRACK_TICK_MS, causing a visible strobe instead of a rendered
-- trail). Runs at Wait(0) ONLY while there is something to draw; idles at
-- TRACK_RENDER_IDLE_TICK_MS the rest of the time (the overwhelming majority
-- of a normal session, since tracking is opt-in and short-lived) — mirrors
-- this file's own idle/active tick-rate-switch convention
-- (TRACK_TICK_MS/TRACK_IDLE_TICK_MS above), applied to the render half
-- specifically because that half — unlike the state/compute half above —
-- genuinely does need per-frame execution to actually be visible.
local TRACK_RENDER_IDLE_TICK_MS = 250

-- FORWARD DECLARATION (ScentVision hand-off, this pass): the real
-- implementation lives further below in this file's own SCENT VISION
-- section, alongside the state (`scentVisionSnapshot`) it reads and the
-- config it validates — kept together there rather than splitting that
-- feature's logic across two widely separated parts of this file. Declared
-- `local` here, ASSIGNED (not `local function`-redeclared) later, so this
-- existing thread — which loads first, textually — captures it as a real
-- upvalue and always sees whatever the later assignment set by the time
-- this loop actually runs (file loading completes, in full, before any
-- CreateThread body's first resume). Folding ScentVision's own dots into
-- THIS SAME per-frame thread (rather than a second Wait(0) loop) is a
-- deliberate perf choice — see this resource's own "no thread left
-- spinning at full frequency while its feature is inactive" standard;
-- two independent Wait(0) render loops would double the per-frame
-- call overhead for as long as EITHER feature is active, for no benefit.
-- @type fun(): boolean drewAnything
local DrawScentVisionPoints

CreateThread(function()
    while true do
        -- CORRECTNESS FIX (coder-frontend, this pass): must check for a
        -- non-EMPTY table, not merely a non-nil one. The state/compute
        -- thread above can hand off `markers = {}` (present but empty) on
        -- the exact tick a hard water-break is detected at traveled == 0
        -- (the K9 is already standing in/at the water's edge the instant
        -- Start*Track() resolves) — the break-condition guard there stops
        -- the loop before it ever appends a marker, but still assigns the
        -- (empty) table rather than nil. The old `if currentTrailMarkers
        -- then` check treated that empty table as truthy, so this thread
        -- spun at Wait(0) — a real per-frame cost — despite the for loop
        -- below it having nothing to iterate and drawing nothing at all.
        -- Bounded to at most one TRACK_TICK_MS (the compute thread clears
        -- it to nil on its very next tick once brokenByWater is set), but
        -- still a genuine "idle path doesn't actually idle" instance, not
        -- just a cosmetic no-op.
        local drewTrailMarkers = false
        if currentTrailMarkers and #currentTrailMarkers > 0 then
            for i = 1, #currentTrailMarkers do
                local marker = currentTrailMarkers[i]
                DrawTrailMarker(marker.coords, marker.underwater)
            end
            drewTrailMarkers = true
        end

        -- ScentVision (this pass) — a SEPARATE feature/state from the
        -- Track <Type> trail above (see this file's own SCENT VISION
        -- section header for the full "why separate" writeup); folded into
        -- this SAME frame/Wait decision purely for perf, not because the
        -- two features are otherwise related. `DrawScentVisionPoints` is
        -- nil until the section below runs at file-load time (which always
        -- happens before this thread's first resume) — guarded anyway,
        -- defensively, in case this file is ever loaded partially by a
        -- future test harness.
        local drewScentVisionPoints = false
        if type(DrawScentVisionPoints) == 'function' then
            drewScentVisionPoints = DrawScentVisionPoints()
        end

        if drewTrailMarkers or drewScentVisionPoints then
            Wait(0)
        else
            Wait(TRACK_RENDER_IDLE_TICK_MS)
        end
    end
end)

-- Blood-trail capture (Config.Features.BloodTracking): relays a
-- payload-less event to the server on CEventNetworkEntityDamage where the
-- LOCAL player is the victim. Real, documented FiveM game event per
-- DEVELOPER_REFERENCE.md §11.6 and independently confirmed against citizenfx/fivem source
-- in DEVELOPER_REFERENCE.md#tracking §0 — victim identity is data[1],
-- confirmed reliable across multiple independent sources; do NOT depend on
-- any other args[] index (weapon hash, etc.) without a fresh confirmation
-- pass, per that note's own explicit caveat (args[3], [5], [6] are NOT
-- independently confirmed).
AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    -- Gate read at the point of firing (DEVELOPER_REFERENCE.md §3's hard requirement — a
    -- disabled feature must be a real no-op, not just hidden UI).
    if not Config.Features.BloodTracking then return end

    local victim = tonumber(data[1])
    if victim ~= PlayerPedId() then return end -- only relay when WE are the victim, per §11.4 item 3's exact filter

    -- No payload — the server resolves OUR live coordinates itself
    -- (GetEntityCoords(GetPlayerPed(source))), never a value sent from here.
    TriggerServerEvent('qbx_k9unit:server:relayDamageEvent')
end)

-- Gunpowder capture thread (Config.Features.GunpowderSniffing), DEVELOPER_REFERENCE.md
-- §11.4 item 4/§11.6. Debounced local poll of IsPedShooting(PlayerPedId())
-- watching for a false->true transition — NOT a nearby-ped scan (an
-- earlier, discarded hypothesis; see DEVELOPER_REFERENCE.md#tracking
-- §0.1 item 2 for why "search a suspect for residue" isn't this feature's
-- actual shape). Each client only ever checks its OWN single ped handle, so
-- this is cheap regardless of how many other players are nearby
-- (DEVELOPER_REFERENCE.md#tracking §2's own note on why this
-- sidesteps the generic "scan nearby peds" perf concern it otherwise flags
-- for a naive implementation). Gated on Config.Features.GunpowderSniffing —
-- idles at a cheap 1000ms poll while the flag is false, mirroring
-- client/movement.lua's AgilityBasicJump thread's "if not
-- Config.Features.X then ... else idle" shape, so this file's thread always
-- exists (simpler than conditionally creating it) but does real work only
-- when the feature is enabled.
local GUNPOWDER_POLL_MS = 200 -- debounce poll interval, per
    -- DEVELOPER_REFERENCE.md#tracking §2's perf note on the
    -- (rejected) nearby-ped-scan variant, applied here to the single-ped
    -- case too as a reasonable default (100-250ms range).
local GUNPOWDER_IDLE_POLL_MS = 1000

-- PERF-AUDIT FINDING, THIS PASS (coder-frontend) — a role/model/access gate
-- was CONSIDERED and REJECTED here, not overlooked. A performance audit
-- flagged this thread as polling IsPedShooting() on every connected client
-- forever "for a mechanic only on-duty K9 handlers can ever act on," and
-- suggested gating the active branch below behind CanShowK9UI() or
-- IsOwnModelK9() so only K9 handlers pay the 200ms tick (mirroring
-- client/hud.lua's CanShowK9UI()-gated poll).
--
-- That premise does not hold for THIS specific thread. Confirmed by
-- reading server/tracking.lua directly rather than inheriting the audit's
-- framing (per this pass's own instruction to verify, not assume):
--   1. relayWeaponFire's own handler (server/tracking.lua) has NO
--      HasK9Access(source) check on the SENDER — only
--      Config.Features.GunpowderSniffing and its relayCooldownMs. The
--      sibling relayDamageEvent (blood) is identically ungated on the
--      sender. Neither trail type's CAPTURE path checks the reporting
--      player's K9 status — only the SEARCH path does.
--   2. server/tracking.lua's own header "FORGED TRAIL DECISION" names the
--      threat model for this exact event as "a griefer" who can "plant a
--      decoy at their own current position" — i.e. the file's own author
--      builds it assuming ANY connected player, not a K9 handler, is a
--      legitimate (if occasionally adversarial) caller of this relay.
--   3. findTrackableSource — the SEARCH side, what "Track Gunpowder"
--      actually invokes (gated by StartTrack()'s HasK9Access() call above
--      in this file — UPDATED, ANY-PED SWEEP FIX, this pass, was
--      CanShowK9UI(); see StartTrack()'s own doc comment — and by
--      HasK9Access(source) server-side, the same real check on both ends
--      now) — is the ONLY point in this mechanic where K9-handler status is
--      meant to matter. Capture (this thread, blood's relayDamageEvent, and
--      scent's ox_inventory swapItems hook) is deliberately population-
--      wide: any player's fired shot / taken damage / dropped item
--      becomes a source a K9 handler can LATER search for. That is the
--      entire point of the mechanic — tracking a suspect who is, by
--      construction, essentially never the K9 handler doing the tracking.
--
-- Gating this thread's poll behind CanShowK9UI()/IsOwnModelK9() would
-- therefore not be a perf fix — it would silently stop logging shots
-- fired by every non-handler player (the actual suspects this mechanic
-- exists to make trackable) while leaving K9 handlers, who rarely need to
-- track each other, as the only population still generating entries. That
-- gates the wrong side of the feature. Config.Features.GunpowderSniffing
-- (checked below, unchanged) remains the ONLY correct gate for this
-- thread: when it is on, every connected client legitimately needs to be
-- able to report its own shot. If a future pass revisits this, re-read
-- server/tracking.lua's relayWeaponFire/relayDamageEvent/
-- findTrackableSource before "fixing" it again — see
-- tests/clienttracking_spec.lua's own regression test asserting a
-- CanShowK9UI() == false caller still relays.
CreateThread(function()
    local wasShooting = false

    while true do
        if Config.Features.GunpowderSniffing then
            local isShooting = IsPedShooting(PlayerPedId())

            -- NOTE (DEVELOPER_REFERENCE.md#tracking §0.2/§2.3,
            -- still unconfirmed this session): IsPedShooting's exact
            -- per-shot vs. per-burst semantics across a sustained
            -- automatic-weapon fire are NOT independently verified — the
            -- real flood protection is server/tracking.lua's own dedicated
            -- rate limit on relayWeaponFire (§11.4 item 4, explicitly
            -- required to be separate from
            -- Config.Tracking.Gunpowder.searchCooldownMs) — this
            -- client-side debounce is a courtesy reduction, not the safety
            -- net itself.
            if isShooting and not wasShooting then
                -- No payload, same "server resolves our own live position"
                -- rule as the damage-event relay above.
                TriggerServerEvent('qbx_k9unit:server:relayWeaponFire')
            end

            wasShooting = isShooting
            Wait(GUNPOWDER_POLL_MS)
        else
            wasShooting = false
            Wait(GUNPOWDER_IDLE_POLL_MS)
        end
    end
end)

--[[
    ======================================================================
    SCENT VISION (Config.Features.ScentVision) — owner-directed pass: "make
    scent tracking... a keybind that makes a colour dot appear where players'
    blood etc have walked and have a delay before the scent markers go
    away... if multiple people, multiple different colours... to
    differentiate smells." Coordinator follow-ups folded in as the design
    evolved: "person" (colour per PERSON, never per permission); "handful
    near the dog" / "they go away after 45 seconds" (server scopes colours
    and reveal to a small proximity-ranked set, 45s default lifetime);
    "diffrent dots will be all seprate timers... slowly go away" (EACH DOT
    expires on its OWN individual timer from its OWN capture time).

    A SEPARATE feature/state from this file's Track Scent/Blood/Gunpowder
    trio above (`trackingState`/`currentTrailMarkers`) — that trio resolves
    and walks toward exactly ONE nearest logged event; this instead shows
    several OTHER people's own recent walked paths at once, colour-coded so
    more than one trail can be told apart. The two can run concurrently
    (there is no reason to force mutual exclusion — one is "walk to this one
    thing", the other is "look around"); only the per-frame RENDER decision
    is shared (see the forward-declared `DrawScentVisionPoints` hook near
    this file's own TRACK_RENDER_IDLE_TICK_MS declaration above), purely for
    the perf reason documented at that call site.

    SERVER IS AUTHORITATIVE THROUGHOUT — this file never decides who may use
    this, never decides what is "nearby", and never learns anyone's raw
    identity. Every point this file ever draws is exactly what
    server/tracking.lua's getScentVisionPoints callback chose to send —
    already position-checked, already range-checked, already capped to a
    "handful" of trails, already coloured. See that callback's own header
    for the full trust-boundary and scale writeup (population-wide capture
    cost, storage ceiling, per-query cost bound, and why colours can never
    collide within one visible set).

    PER-DOT EXPIRY, EVALUATED AGAINST A TIMESTAMP, NEVER A COUNTDOWN (owner's
    own explicit requirement): the server sends each point's own age AT THE
    MOMENT OF THE RESPONSE (`ageMs`, relative — never a raw server
    GetGameTimer() value, since server and client run independent
    GetGameTimer() counters and are not the same clock). This file anchors
    that relative age to ITS OWN GetGameTimer() the instant the response
    arrives (`receivedAtClientMs` below) and, every frame, recomputes each
    point's CURRENT effective age as `ageMs + (GetGameTimer() -
    receivedAtClientMs)` — never a value decremented once per frame. A
    stutter, an alt-tab, or a paused resource therefore cannot stretch a 45s
    dot into something longer: whatever real wall-clock time actually
    passed is exactly what this subtraction reflects the next time this
    file's thread actually resumes.

    THE ENTIRE "DELAY BEFORE MARKERS GO AWAY" MECHANISM, ON TOGGLE-OFF:
    ToggleScentVision() turning the ability OFF does NOT clear
    `scentVisionSnapshot` — it only stops polling for FRESH data. The render
    hook below keeps drawing whatever was last received, with each
    individual dot still fading/expiring on its own already-established
    per-dot timer, until the snapshot naturally empties (every dot expired)
    — at which point `DrawScentVisionPoints` clears it itself and the shared
    render thread above goes back to idling. There is deliberately no
    second "linger" timer to configure or maintain: each dot's own
    dotLifetimeMs already IS the delay the owner asked for, so a second
    knob would only be a second, redundant way to get the same answer wrong.
    ======================================================================
]]

-- CLAMP AND WARN (this resource's standing "a non-positive/invalid
-- millisecond value must never silently mean something dangerous" rule —
-- server/cooldowns.lua's own header names the sibling risk for a cooldown
-- threshold; the risk here is a Wait(0)-or-worse poll loop). Resolved ONCE
-- at file load, mirroring client/scenttrail.lua's own PULSE_MAX_INTERVAL_MS
-- precedent exactly (read before writing this), rather than re-validated on
-- every poll.
local SCENT_VISION_POLL_INTERVAL_MS_DEFAULT = 1500
local SCENT_VISION_POLL_INTERVAL_MS = SCENT_VISION_POLL_INTERVAL_MS_DEFAULT
do
    local configured = Config.Tracking.ScentVision and Config.Tracking.ScentVision.pollIntervalMs
    if type(configured) == 'number' and configured == configured and configured > 0 then
        SCENT_VISION_POLL_INTERVAL_MS = configured
    else
        print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.pollIntervalMs must be a positive number of milliseconds (got %s) -- falling back to the shipped default of %dms.'):format(tostring(configured), SCENT_VISION_POLL_INTERVAL_MS_DEFAULT))
    end
end

-- Used ONLY until the first server response arrives (which always echoes
-- back the lifetime it actually enforced for that response — see
-- server/tracking.lua's own comment on `dotLifetimeMs`) — never trusted
-- over a real response. Kept numerically equal to config.lua's own shipped
-- Config.Tracking.ScentVision.dotLifetimeMs default and
-- server/tracking.lua's own ResolveConfiguredThresholdMs fallback so a
-- fresh client's very first frame (before any response has arrived at all,
-- which cannot happen anyway since `scentVisionSnapshot` starts nil and
-- this constant is never read until a response exists) stays consistent
-- with the rest of this resource's defaults.
local SCENT_VISION_DOT_LIFETIME_MS_DEFAULT = 45000

-- Same clamp-and-warn treatment as SCENT_VISION_POLL_INTERVAL_MS above.
-- Clamped to [0, 1) — a dot must stay fully opaque for SOME leading
-- fraction of its life (0 is allowed: fade starts immediately) and must
-- never be told to start fading at or past 100% of its own lifetime (which
-- would either never fade at all before expiring or divide by zero in the
-- fade-progress math below).
local SCENT_VISION_FADE_START_FRACTION_DEFAULT = 0.5
local SCENT_VISION_FADE_START_FRACTION = SCENT_VISION_FADE_START_FRACTION_DEFAULT
do
    local configured = Config.Tracking.ScentVision and Config.Tracking.ScentVision.fadeStartFraction
    if type(configured) == 'number' and configured == configured and configured >= 0.0 and configured < 1.0 then
        SCENT_VISION_FADE_START_FRACTION = configured
    else
        print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.fadeStartFraction must be a number in [0, 1) (got %s) -- falling back to the shipped default of %.2f.'):format(tostring(configured), SCENT_VISION_FADE_START_FRACTION_DEFAULT))
    end
end

-- Full opacity for a not-yet-fading dot -- matches TRAIL_MARKER_COLOR.a
-- above (180) closely enough to read as "the same kind of marker", picked
-- independently since ScentVision markers carry their own per-point colour
-- rather than one fixed TRAIL_MARKER_COLOR.
local SCENT_VISION_MARKER_ALPHA = 200

--- @type boolean
local scentVisionActive = false
--- In-flight/staleness token — same shape/reasoning as this file's own
--- `trackRequestGeneration` above and client/scenttrail.lua's
--- `huntGeneration`: bumped by every toggle so a poll loop started before a
--- toggle-off can never keep acting past it.
--- @type number
local scentVisionGeneration = 0
--- Cached last-received render snapshot, or nil when nothing has ever been
--- received (or everything in it has since individually expired — see
--- DrawScentVisionPoints below, which is the ONLY place this is ever set
--- back to nil once populated).
--- @type { dotLifetimeMs: number, receivedAtClientMs: number, points: { x: number, y: number, z: number, r: number, g: number, b: number, ageMs: number }[] } | nil
local scentVisionSnapshot = nil

--- @return boolean
function IsScentVisionActive()
    return scentVisionActive
end

--- Draws every still-live point in `scentVisionSnapshot` this frame
--- (already-expired ones are skipped, never drawn) and reports whether
--- anything was actually drawn, so the shared render thread (this file's
--- own TRACK_RENDER_IDLE_TICK_MS block above) can decide whether to keep
--- running at Wait(0) or go back to idling. Also clears
--- `scentVisionSnapshot` to nil entirely once EVERY point in it has
--- individually expired, so that thread does not keep re-evaluating an
--- empty, fully-expired snapshot forever — this is also the ENTIRE
--- mechanism behind dots persisting for a while after ToggleScentVision()
--- turns the ability off (see this section's own header).
---
--- DrawMarker — VERIFIED (this pass): its own ext/native-decls page 404s
--- (https://raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/DrawMarker.md
--- — a 404 there is NOT proof of absence for a legacy R* native, per this
--- resource's own standing rule and .luacheckrc's own DrawMarker precedent).
--- Confirmed instead against the documented fallback,
--- runtime.fivem.net/doc/natives.json (fetched this pass): GRAPHICS
--- namespace, hash 0x28477EC23D892089, name DRAW_MARKER, no `apiset` key —
--- which, per this resource's own established reading of that field
--- elsewhere (.luacheckrc's own comments on SetPlayerModel/CreatePed/etc.),
--- means the default, CLIENT-ONLY, matching this file's own existing,
--- already-shipped DrawTrailMarker() call site above and the realm this
--- function itself runs in. No new native is introduced here — this
--- function reuses the EXACT same already-verified DrawMarker call shape
--- DrawTrailMarker() above already uses (type 1, a flat cylinder/checkpoint
--- ring), only parameterized by each point's own colour instead of one
--- fixed TRAIL_MARKER_COLOR.
--- @return boolean drewAnything
DrawScentVisionPoints = function()
    if not scentVisionSnapshot then return false end

    local nowClient = GetGameTimer()
    local elapsedSinceReceived = nowClient - scentVisionSnapshot.receivedAtClientMs
    local lifetimeMs = scentVisionSnapshot.dotLifetimeMs
    local fadeEnabled = Config.Tracking.ScentVision and Config.Tracking.ScentVision.fadeEnabled == true

    local anyLive = false
    local points = scentVisionSnapshot.points
    for i = 1, #points do
        local point = points[i]
        -- EACH DOT'S OWN individual age, evaluated against a TIMESTAMP —
        -- see this section's own header for why this is never a
        -- per-frame-decremented countdown.
        local effectiveAgeMs = point.ageMs + elapsedSinceReceived
        if effectiveAgeMs < lifetimeMs then
            anyLive = true
            local alpha = SCENT_VISION_MARKER_ALPHA
            if fadeEnabled then
                local lifeFraction = effectiveAgeMs / lifetimeMs
                if lifeFraction > SCENT_VISION_FADE_START_FRACTION then
                    local fadeProgress = (lifeFraction - SCENT_VISION_FADE_START_FRACTION) / (1.0 - SCENT_VISION_FADE_START_FRACTION)
                    alpha = math.floor(SCENT_VISION_MARKER_ALPHA * (1.0 - fadeProgress) + 0.5)
                    if alpha < 0 then alpha = 0 end
                end
            end

            DrawMarker(
                TRAIL_MARKER_TYPE,
                point.x, point.y, point.z - 0.9,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE,
                point.r, point.g, point.b, alpha,
                false, false, 2, false, '', '', false
            )
        end
    end

    if not anyLive then
        scentVisionSnapshot = nil
    end

    return anyLive
end

--- Poll loop — same pcall/generation-staleness shape as this file's own
--- StartTrack() above and client/scenttrail.lua's
--- EnsureHuntPollThreadRunning (read before writing this, per this pass's
--- own instruction to extend an established pattern rather than invent a
--- new one). Runs on an INTERVAL, never per-frame — all per-frame work is
--- the separate, shared render thread's job (DrawScentVisionPoints above),
--- reading whatever this loop last stored in `scentVisionSnapshot`.
local function EnsureScentVisionPollThreadRunning()
    CreateThread(function()
        local myGeneration = scentVisionGeneration

        while scentVisionActive and myGeneration == scentVisionGeneration do
            -- OWN-DEATH EXIT PATH — same precedent as this file's own
            -- Track <Type> compute thread above (see that block's own doc
            -- comment for the full reasoning): continuing to poll from a
            -- dead ped's position is narratively nonsensical, and silently
            -- resuming on respawn from an unrelated coordinate would be
            -- worse than just stopping and saying so.
            if IsEntityDead(PlayerPedId()) then
                scentVisionGeneration = scentVisionGeneration + 1
                scentVisionActive = false
                lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_lost_death'), type = 'error' })
                break
            end

            -- FAIL-CLOSED GUARD — same reasoning/precedent as StartTrack()
            -- above and client/scenttrail.lua's own poll loop:
            -- lib.callback.await throws rather than returning nil on a
            -- timeout/rejection. Uncaught here, a throw would abort this
            -- whole CreateThread body, silently killing the poll loop with
            -- `scentVisionActive` still stuck true and no further updates
            -- ever arriving.
            local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:getScentVisionPoints', false)
            if not ok then result = nil end

            -- Staleness check — a ToggleScentVision() off-then-on cycle
            -- that ran while the await above was pending must not let this
            -- stale result resurrect a session the player already moved
            -- past.
            if myGeneration ~= scentVisionGeneration then break end

            if result and type(result.points) == 'table' then
                scentVisionSnapshot = {
                    dotLifetimeMs = type(result.dotLifetimeMs) == 'number' and result.dotLifetimeMs or SCENT_VISION_DOT_LIFETIME_MS_DEFAULT,
                    receivedAtClientMs = GetGameTimer(),
                    points = result.points,
                }
            end
            -- A failed/empty response is NOT treated as "clear the
            -- snapshot" — the last-known trails simply keep fading on
            -- their own already-established per-dot timers (same "a
            -- transient hiccup should not visibly blank the screen"
            -- posture as leaving `scentVisionSnapshot` alone on
            -- ToggleScentVision() off, per this section's own header).

            Wait(SCENT_VISION_POLL_INTERVAL_MS)
        end
    end)
end

--- Resource-global keybind entry point (client/keybinds.lua). A single
--- context-sensitive toggle — mirrors this resource's own established
--- Toggle*() shape (ToggleThermalVision/ToggleNightVision/ToggleK9Camera in
--- client/vision.lua/client/movement.lua) rather than a Start/Stop pair,
--- since there is exactly one on/off state here with no third "which one"
--- choice to make.
---
--- TERMINATION IS NEVER GATED — turning the ability OFF always works,
--- unconditionally, per this resource's standing "no unbounded trap" rule
--- (the same rule StopTracking()/StopScentHunt() above and elsewhere in
--- this resource already document for themselves). Toggling off does NOT
--- clear `scentVisionSnapshot` — see this section's own header for why
--- that omission IS the "delay before markers go away" mechanism, not a
--- bug.
function ToggleScentVision()
    if not Config.Features.ScentVision then
        DenyK9UIAccess()
        return
    end

    if scentVisionActive then
        scentVisionGeneration = scentVisionGeneration + 1
        scentVisionActive = false
        return
    end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    scentVisionGeneration = scentVisionGeneration + 1
    scentVisionActive = true
    EnsureScentVisionPollThreadRunning()
end
