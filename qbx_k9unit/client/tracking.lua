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
    phase2_notes/DEVELOPER_REFERENCE.md#tracking, phase2_notes/DEVELOPER_REFERENCE.md#tracking,
    phase2_notes/DEVELOPER_REFERENCE.md#tracking, phase2_notes/DEVELOPER_REFERENCE.md#tracking.

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
       this echoed field (phase2_notes/DEVELOPER_REFERENCE.md#tracking §1.2).
       No `reason` field exists on this response (unlike searchTarget's) —
       "nothing nearby" / "on cooldown" / "no access" all collapse to the
       same `found = false` here; ship one generic message
       (phase2_notes/DEVELOPER_REFERENCE.md#tracking §2.4).

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
            open gap phase2_notes/DEVELOPER_REFERENCE.md#tracking §2.1/§5 item 2
            flags (no self-service "stop" affordance is specified anywhere
            in §11's acceptance criteria) — a manual-cancel item, mirroring
            Attach/Detach Leash's single context-sensitive radial item.
        IsTracking() -> boolean
        GetActiveTrackType() -> 'scent'|'blood'|'gunpowder'|nil
    - THIS FILE calls client/main.lua's CanShowK9UI() at the top of every
      Start*Track() call — "don't trust the caller already checked," the
      same posture client/movement.lua's RequestLeashAttach() documents for
      itself.
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
    if not CanShowK9UI() then
        -- Migrated to the shared client/main.lua helper (DEVELOPER_REFERENCE.md
        -- Part B item 1 -- formerly DEVELOPER_REFERENCE.md, merged 2026-08-25)
        -- — this was the last raw inline copy of the
        -- common.no_k9_access lib.notify() pattern; DenyK9UIAccess()'s own
        -- payload (title/description/type) is byte-identical to what this
        -- call site used to build directly.
        DenyK9UIAccess()
        return
    end

    -- OPEN QUESTION, not decided by DEVELOPER_REFERENCE.md §11 (phase2_notes/DEVELOPER_REFERENCE.md#tracking
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
    -- (phase2_notes/DEVELOPER_REFERENCE.md#tracking §2.4) — ship one generic
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

--- Manual cancel — fills the open gap phase2_notes/DEVELOPER_REFERENCE.md#tracking
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
-- framing phase2_notes/DEVELOPER_REFERENCE.md#tracking §3 item 4 uses).
local TRAIL_MARKER_TYPE = 1
local TRAIL_MARKER_SCALE = 0.5
local TRAIL_MARKER_COLOR = { r = 255, g = 220, b = 90, a = 180 }
local TRAIL_MARKER_COLOR_UNDERWATER_ALPHA = 60 -- reduced-opacity rendering for breaksTrail == false, per §11.5

--- Draws one breadcrumb marker at `coords`, at reduced alpha if `underwater`.
--- Not independently native-verified this pass (DrawMarker is a
--- long-standing, extremely well-established FiveM/GTA native per
--- phase2_notes/DEVELOPER_REFERENCE.md#tracking §4 — not re-verified against
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
--- phase2_notes/DEVELOPER_REFERENCE.md#tracking §1's explicit recommendation
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
                StopTracking()
            else
                sleepMs = TRACK_TICK_MS

                local myCoords = GetEntityCoords(myPed)
                local sourceCoords = trackingState.coords

                -- Recomputed fresh every tick from the K9's LIVE position
                -- toward the fixed resolved source coordinate — NOT a
                -- one-time snapshot (phase2_notes/DEVELOPER_REFERENCE.md#tracking
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
                    -- (phase2_notes/DEVELOPER_REFERENCE.md#tracking §2.3, §5 item 1):
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
                    if Config.Features.WaterTrackingDecay then
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
        if currentTrailMarkers and #currentTrailMarkers > 0 then
            for i = 1, #currentTrailMarkers do
                local marker = currentTrailMarkers[i]
                DrawTrailMarker(marker.coords, marker.underwater)
            end
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
-- in phase2_notes/DEVELOPER_REFERENCE.md#tracking §0 — victim identity is data[1],
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
-- earlier, discarded hypothesis; see phase2_notes/DEVELOPER_REFERENCE.md#tracking
-- §0.1 item 2 for why "search a suspect for residue" isn't this feature's
-- actual shape). Each client only ever checks its OWN single ped handle, so
-- this is cheap regardless of how many other players are nearby
-- (phase2_notes/DEVELOPER_REFERENCE.md#tracking §2's own note on why this
-- sidesteps the generic "scan nearby peds" perf concern it otherwise flags
-- for a naive implementation). Gated on Config.Features.GunpowderSniffing —
-- idles at a cheap 1000ms poll while the flag is false, mirroring
-- client/movement.lua's AgilityBasicJump thread's "if not
-- Config.Features.X then ... else idle" shape, so this file's thread always
-- exists (simpler than conditionally creating it) but does real work only
-- when the feature is enabled.
local GUNPOWDER_POLL_MS = 200 -- debounce poll interval, per
    -- phase2_notes/DEVELOPER_REFERENCE.md#tracking §2's perf note on the
    -- (rejected) nearby-ped-scan variant, applied here to the single-ped
    -- case too as a reasonable default (100-250ms range).
local GUNPOWDER_IDLE_POLL_MS = 1000

CreateThread(function()
    local wasShooting = false

    while true do
        if Config.Features.GunpowderSniffing then
            local isShooting = IsPedShooting(PlayerPedId())

            -- NOTE (phase2_notes/DEVELOPER_REFERENCE.md#tracking §0.2/§2.3,
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
