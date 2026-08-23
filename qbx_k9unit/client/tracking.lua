--[[
    qbx_k9unit/client/tracking.lua

    Phase 2 (coder-frontend). Owns the three self-initiated "Track <Type>"
    trail mechanics (scent, blood, gunpowder) and the water-crossing degrade
    modifier that applies to whichever trail is currently rendering —
    SPEC.md §11.1 sub-phases 2d/2e/2f, §11.3's `client/tracking.lua` row.
    All three trail types share ONE file (not one file per type) and call
    ONE parameterized server callback, per §11.3/§11.4 item 1.

    Supplementary implementation detail (non-authoritative — SPEC.md §11 is
    the source of truth if anything here drifts from it):
    phase2_notes/scent_blood_tracking.md, phase2_notes/scent_blood_natives.md,
    phase2_notes/water_gunpowder_tracking.md, phase2_notes/water_gunpowder_natives.md.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per SPEC.md §11.4 items 1, 3, 4 and
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
       this echoed field (phase2_notes/water_gunpowder_tracking.md §1.2).
       No `reason` field exists on this response (unlike searchTarget's) —
       "nothing nearby" / "on cooldown" / "no access" all collapse to the
       same `found = false` here; ship one generic message
       (phase2_notes/scent_blood_tracking.md §2.4).

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

    No client events (server->client) for this file at all — §11.4 item 7
    is explicit that tracking-result delivery is request/response shaped
    (the callback above), not a fire-and-forget event pair, matching the
    already-shipped 'qbx_k9unit:server:hasK9Access' pattern.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes four resource-global (no `local`) functions,
      consumed by client/radial.lua's "Track Scent" / "Track Blood" /
      "Track Gunpowder" items per §11.3's radial.lua row (not wired by this
      file's own pass — grepping client/radial.lua as of this pass shows it
      does not call these yet; that wiring is coder-architect's own file to
      extend, per §11.3's file-plan row assigning that extension to
      client/radial.lua itself, not this one):
        StartScentTrack()
        StartBloodTrack()
        StartGunpowderTrack()
        StopTracking()   -- not named by SPEC.md §11 itself; fills the
            open gap phase2_notes/scent_blood_tracking.md §2.1/§5 item 2
            flags (no self-service "stop" affordance is specified anywhere
            in §11's acceptance criteria) — a manual-cancel item, mirroring
            Attach/Detach Leash's single context-sensitive radial item.
        IsTracking() -> boolean
    - THIS FILE calls client/main.lua's CanShowK9UI() at the top of every
      Start*Track() call — "don't trust the caller already checked," the
      same posture client/movement.lua's RequestLeashAttach() documents for
      itself.
    - THIS FILE reads Config.Tracking.Scent / .Blood / .Gunpowder and
      Config.WaterTrackingDecay (SPEC.md §11.2's config.lua additions,
      confirmed landed in config.lua as of this pass, including the
      relayCooldownMs amendments beyond §11.2's original text — those
      fields are server/tracking.lua's own concern, not read by this file).

    DEPENDENCY NOTE: this file has no compile-time dependency on
    client/search.lua (different trust model, different file) or
    client/vision.lua (unrelated feature). Load order relative to those two
    doesn't matter.
]]

--- Local-only view of the CURRENT tracking session, if any. Set by a
--- successful Start*Track() call below, cleared by StopTracking() or by
--- the render thread's own water-break bookkeeping.
--- Not exposed directly — always go through IsTracking()/StopTracking().
--- @type { trackType: 'scent'|'blood'|'gunpowder', coords: vector3, breaksAtWater: boolean, brokenByWater: boolean } | nil
local trackingState = nil

--- @return boolean
function IsTracking()
    return trackingState ~= nil
end

--- Shared implementation behind StartScentTrack()/StartBloodTrack()/
--- StartGunpowderTrack() below. SPEC.md §11.5's three trail-type
--- acceptance-criteria blocks are textually identical (only the trackType
--- string and its Config.Tracking.<Type> sub-table differ), so this is one
--- function instead of three near-duplicate copies — mirrors e.g.
--- client/vehicle.lua's ReleasePedFromVehicleState being shared rather than
--- duplicated.
--- @param trackType 'scent'|'blood'|'gunpowder'
local function StartTrack(trackType)
    if not CanShowK9UI() then
        lib.notify({ title = 'K9 Unit', description = 'You cannot use K9 features right now.', type = 'error' })
        return
    end

    -- OPEN QUESTION, not decided by SPEC.md §11 (phase2_notes/scent_blood_tracking.md
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
        lib.notify({ title = 'K9 Unit', description = 'Already tracking something — stop first.', type = 'error' })
        return
    end

    local result = lib.callback.await('qbx_k9unit:server:findTrackableSource', false, trackType)
    -- NOTE: §11.4 item 1's response shape has no `reason` field (unlike
    -- searchTarget's, §11.4 item 2), so "nothing nearby" / "on cooldown" /
    -- "no access" all collapse to the same found = false here
    -- (phase2_notes/scent_blood_tracking.md §2.4) — ship one generic
    -- message, don't invent a distinction the server doesn't give data for.
    if not result or not result.found then
        lib.notify({ title = 'K9 Unit', description = 'Nothing to track right now.', type = 'error' })
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
    }
    -- Setting trackingState is sufficient to "wake" the render thread below
    -- — mirrors the exact comment already on client/movement.lua's
    -- leashAttached handler ("simply setting it here is sufficient... no
    -- separate thread-start call needed").
end

--- Radial-facing entry point for scent tracking (Config.Features.ScentTracking).
--- SPEC.md §11.3's client/radial.lua row calls this by this exact name —
--- do not rename without updating that row and radial.lua's eventual
--- wiring (still unwired as of this pass).
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

--- Manual cancel — fills the open gap phase2_notes/scent_blood_tracking.md
--- §2.1/§5 item 2 flags (no self-service "stop" affordance is specified
--- anywhere in SPEC.md §11 itself, only a fresh Start*Track() call after a
--- water-break). No-op if not currently tracking. Silent, cosmetic,
--- low-stakes action (per §11.6's framing of tracking as "no real
--- capability granted") — no confirmation notification needed, matching
--- how DetachLeash() doesn't narrate every internal-state clear either.
function StopTracking()
    trackingState = nil
    -- The render thread below naturally stops drawing once IsTracking() is
    -- false, mirroring how client/movement.lua's DetachLeash() comment
    -- describes its own elastic thread "naturally stopping" once
    -- IsLeashed() is false — no separate thread-teardown call needed.
end

-- Trail-rendering / water-crossing thread. Reuses the exact idle/active
-- tick-rate-switch pattern client/movement.lua's leash pull-back thread
-- already establishes (its LEASH_TICK_MS / LEASH_IDLE_TICK_MS constants) —
-- sleeps long while IsTracking() is false, switches to a short tick only
-- while a session is active. Flagging the exact tick rate for
-- resource-performance-profiler once this is reviewed, per
-- phase2_notes/scent_blood_tracking.md §2.2 (DrawMarker itself needs
-- calling every frame it should be visible, but the recompute/water-sample
-- half of the loop doesn't need to run that often — kept on the same
-- interval here for simplicity; split further only if profiling shows a
-- real cost).
local TRACK_TICK_MS = 250
local TRACK_IDLE_TICK_MS = 1000

-- DrawMarker type 1 = a flat cylinder/checkpoint ring — a reasonable,
-- unremarkable choice for a ground breadcrumb (matches the "checkpoint"
-- framing phase2_notes/water_gunpowder_tracking.md §3 item 4 uses).
local TRAIL_MARKER_TYPE = 1
local TRAIL_MARKER_SCALE = 0.5
local TRAIL_MARKER_COLOR = { r = 255, g = 220, b = 90, a = 180 }
local TRAIL_MARKER_COLOR_UNDERWATER_ALPHA = 60 -- reduced-opacity rendering for breaksTrail == false, per §11.5

--- Draws one breadcrumb marker at `coords`, at reduced alpha if `underwater`.
--- Not independently native-verified this pass (DrawMarker is a
--- long-standing, extremely well-established FiveM/GTA native per
--- phase2_notes/scent_blood_tracking.md §4 — not re-verified against
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
--- phase2_notes/water_gunpowder_natives.md §1's explicit recommendation
--- (frame-stable, appropriate for a fixed-step poll like this; plain
--- GetWaterHeight is wave-jittered and can disagree between adjacent
--- samples on a calm shoreline). Called with a trailing 0.0 "hint" arg for
--- the native's `float* height` out-param, mirroring the exact call shape
--- phase2_notes/scent_blood_natives.md §3 documents for the sibling
--- GetWaterHeight native (`local found, waterZ = GetWaterHeight(x, y, z, 0.0)`)
--- — the height value itself is unused here, only the boolean matters.
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
        local found = GetWaterHeightNoWaves(sample.x, sample.y, sample.z, 0.0)
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
            sleepMs = TRACK_TICK_MS

            local myPed = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            local sourceCoords = trackingState.coords

            -- Recomputed fresh every tick from the K9's LIVE position
            -- toward the fixed resolved source coordinate — NOT a one-time
            -- snapshot (phase2_notes/water_gunpowder_tracking.md §1.2: the
            -- K9's position moves every tick, the resolved source
            -- coordinate does not, for the lifetime of one Start*Track()
            -- call).
            local totalDist = #(sourceCoords - myCoords)

            if totalDist > 0.1 then
                local trackingConfig = Config.Tracking[
                    trackingState.trackType == 'scent' and 'Scent'
                    or trackingState.trackType == 'blood' and 'Blood'
                    or 'Gunpowder'
                ]
                local dir = (sourceCoords - myCoords) / totalDist

                -- OPEN QUESTION, not resolved by SPEC.md §11 either way
                -- (phase2_notes/scent_blood_tracking.md §2.3, §5 item 1):
                -- reveal the WHOLE remaining line at once, or only a capped
                -- preview window near the player? This implementation
                -- reveals the whole remaining line — simpler, and matches
                -- "a trail of markers toward the nearest source" read
                -- literally — flagged per that note's own recommendation to
                -- confirm with product-manager/feature-ideation before this
                -- is treated as final, not silently asserted as the only
                -- right answer.
                local waterCrossingDist = nil
                if Config.Features.WaterTrackingDecay then
                    waterCrossingDist = FindWaterCrossingDistance(myCoords, sourceCoords)

                    if waterCrossingDist and trackingState.breaksAtWater then
                        -- Hard break: stop drawing markers past the
                        -- crossing point, mark broken, notify, and do NOT
                        -- auto-resume — per §11.5's explicit "does not
                        -- silently resume" bullet, a fresh Start*Track()
                        -- call (subject to that type's own
                        -- searchCooldownMs) is required to re-acquire.
                        trackingState.brokenByWater = true
                        lib.notify({
                            title = 'K9 Unit',
                            description = 'The trail is lost at the water\'s edge.',
                            type = 'error',
                        })
                    end
                end

                -- Deliberately NOT gated on `not trackingState.brokenByWater`
                -- here — the outer `IsTracking() and not trackingState.
                -- brokenByWater` check (top of this tick's block) already
                -- stops FUTURE ticks once broken, and the break condition
                -- two lines below already cuts the line off exactly at
                -- waterCrossingDist. Gating this loop on brokenByWater too
                -- was a real bug: brokenByWater gets set to true a few
                -- lines above in THIS SAME tick the instant water is first
                -- detected anywhere on the remaining path, so the old code
                -- skipped drawing anything at all that tick — the whole
                -- trail (including the already-walked near-bank portion)
                -- vanished instantly instead of rendering up to the
                -- water's edge as §11.5 requires. Running this loop
                -- unconditionally lets the current tick still draw the
                -- partial line before the broken state takes effect next
                -- tick (qa-tester/correctness-overseer finding).
                -- Clamped defensively, same rationale/precedent as
                -- FindWaterCrossingDistance's own `step` clamp above: a
                -- misconfigured Config.Tracking.<Type>.markerSpacing of 0
                -- (or negative) would otherwise spin this while loop
                -- forever with no Wait() inside it (qa-tester finding).
                local markerStep = math.max(trackingConfig.markerSpacing, 0.1)
                local traveled = 0.0
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
                    DrawTrailMarker(markerCoords, underwater)

                    traveled = traveled + markerStep
                end
            end
        end

        Wait(sleepMs)
    end
end)

-- Blood-trail capture (Config.Features.BloodTracking): relays a
-- payload-less event to the server on CEventNetworkEntityDamage where the
-- LOCAL player is the victim. Real, documented FiveM game event per
-- SPEC.md §11.6 and independently confirmed against citizenfx/fivem source
-- in phase2_notes/scent_blood_natives.md §0 — victim identity is data[1],
-- confirmed reliable across multiple independent sources; do NOT depend on
-- any other args[] index (weapon hash, etc.) without a fresh confirmation
-- pass, per that note's own explicit caveat (args[3], [5], [6] are NOT
-- independently confirmed).
AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    -- Gate read at the point of firing (SPEC.md §3's hard requirement — a
    -- disabled feature must be a real no-op, not just hidden UI).
    if not Config.Features.BloodTracking then return end

    local victim = tonumber(data[1])
    if victim ~= PlayerPedId() then return end -- only relay when WE are the victim, per §11.4 item 3's exact filter

    -- No payload — the server resolves OUR live coordinates itself
    -- (GetEntityCoords(GetPlayerPed(source))), never a value sent from here.
    TriggerServerEvent('qbx_k9unit:server:relayDamageEvent')
end)

-- Gunpowder capture thread (Config.Features.GunpowderSniffing), SPEC.md
-- §11.4 item 4/§11.6. Debounced local poll of IsPedShooting(PlayerPedId())
-- watching for a false->true transition — NOT a nearby-ped scan (an
-- earlier, discarded hypothesis; see phase2_notes/water_gunpowder_tracking.md
-- §0.1 item 2 for why "search a suspect for residue" isn't this feature's
-- actual shape). Each client only ever checks its OWN single ped handle, so
-- this is cheap regardless of how many other players are nearby
-- (phase2_notes/water_gunpowder_natives.md §2's own note on why this
-- sidesteps the generic "scan nearby peds" perf concern it otherwise flags
-- for a naive implementation). Gated on Config.Features.GunpowderSniffing —
-- idles at a cheap 1000ms poll while the flag is false, mirroring
-- client/movement.lua's AgilityBasicJump thread's "if not
-- Config.Features.X then ... else idle" shape, so this file's thread always
-- exists (simpler than conditionally creating it) but does real work only
-- when the feature is enabled.
local GUNPOWDER_POLL_MS = 200 -- debounce poll interval, per
    -- phase2_notes/water_gunpowder_natives.md §2's perf note on the
    -- (rejected) nearby-ped-scan variant, applied here to the single-ped
    -- case too as a reasonable default (100-250ms range).
local GUNPOWDER_IDLE_POLL_MS = 1000

CreateThread(function()
    local wasShooting = false

    while true do
        if Config.Features.GunpowderSniffing then
            local isShooting = IsPedShooting(PlayerPedId())

            -- NOTE (phase2_notes/water_gunpowder_tracking.md §0.2/§2.3,
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
