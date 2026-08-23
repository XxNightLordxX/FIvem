--[[
    qbx_k9unit/client/tracking.lua

    PHASE 2 SCAFFOLD ONLY (coder-frontend) — WRITTEN AHEAD OF GREENLIGHT.
    Phase 1's confirmation wave (qa-tester / regression-interaction /
    correctness-overseer) was still closing out when this was written.
    This is safe work-ahead scaffolding per SPEC.md §11 ("Phase 2 Detailed
    Spec") already being fully specified — it is NOT final implementation
    and must NOT be merged/wired blindly. In particular:
      - fxmanifest.lua does NOT yet list this file under client_scripts.
      - client/radial.lua does NOT yet call any of the globals below.
      - config.lua does NOT yet contain the Config.Tracking / .WaterTrackingDecay
        tables this file's TODOs reference (SPEC.md §11.2 additions).
    All three are explicit, separate follow-up work once Phase 1 is
    greenlit for this — do not add them as part of finishing this file's
    TODOs without that go-ahead.

    Mirrors the exact "header contract + function signature + numbered
    TODO" scaffolding style client/main.lua's ORIGINAL scaffold used
    (see `git log -- qbx_k9unit/client/main.lua`, commit 66b8aee) — not
    the fully-implemented style client/main.lua has today after Phase 1's
    implementation pass.

    Owns the three self-initiated "Track <Type>" trail mechanics (scent,
    blood, gunpowder) and the water-crossing degrade modifier that applies
    to whichever trail is currently rendering — SPEC.md §11.1 sub-phases
    2d/2e/2f, §11.3's `client/tracking.lua` row. All three trail types
    share ONE file (not one file per type) and will call ONE parameterized
    server callback, per §11.3/§11.4 item 1 — an earlier, since-corrected
    design draft proposed two separate per-type callbacks; do not
    resurrect that shape (see phase2_notes/scent_blood_tracking.md §0 for
    the full history of that correction, and phase2_notes/EXPORT_TRACKING.md's
    "Batch 2" section for the reconciliation record).

    Supplementary implementation detail cited in the TODOs below
    (non-authoritative — SPEC.md §11 is the source of truth if anything
    here drifts from it): phase2_notes/scent_blood_tracking.md,
    phase2_notes/scent_blood_natives.md, phase2_notes/water_gunpowder_tracking.md,
    phase2_notes/water_gunpowder_natives.md.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2 (full copy, per SPEC.md §11.4 items
    1, 3, 4 and §11.4 item 7's "no dedicated result-delivery event" note;
    the server side of this contract belongs in server/tracking.lua, NOT
    YET WRITTEN — this is client-side scaffolding only):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:findTrackableSource' (trackType: 'scent'|'blood'|'gunpowder')
       -> { found: boolean, coords: vector3?, breaksAtWater: boolean }
       [server/tracking.lua, not yet written]
       Re-validates Config.Features.<Type> and HasK9Access(source)
       server-side regardless of client UI state. Resolves the CALLER'S
       OWN live server-side position — never a client-supplied coordinate.
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.
       `breaksAtWater` is documented (§11.4 item 1) as informational only
       — since config.lua is a shared_script, THIS FILE can and should
       read Config.WaterTrackingDecay.breaksTrail directly rather than
       trusting this echoed field (see phase2_notes/water_gunpowder_tracking.md
       §1.2's note on why the field exists anyway: future-proofing for a
       possible per-department/per-type override, not because the client
       couldn't otherwise know it).

    Server events (RegisterNetEvent, client->server; THIS FILE triggers,
    does not receive, these two):
    2. 'qbx_k9unit:server:relayDamageEvent' () [server/tracking.lua, not yet written]
       Fired by THIS FILE's own 'gameEventTriggered' handler below when
       the LOCAL player is the CEventNetworkEntityDamage victim. No
       payload — the server resolves the reporting client's own live
       coordinates itself, this file never sends a coordinate.
    3. 'qbx_k9unit:server:relayWeaponFire' () [server/tracking.lua, not yet written]
       Fired by THIS FILE on a debounced false->true transition of
       IsPedShooting(PlayerPedId()). No payload, same reasoning as above.

    No client events (server->client) for this file at all — §11.4 item 7
    is explicit that tracking-result delivery is request/response shaped
    (the callback above), not a fire-and-forget event pair, matching the
    already-shipped 'qbx_k9unit:server:hasK9Access' pattern.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE will expose four resource-global (no `local`) functions,
      to be consumed by client/radial.lua's three new "Track Scent" /
      "Track Blood" / "Track Gunpowder" items per §11.3's radial.lua row
      — NOT WIRED YET, radial.lua is explicitly out of scope for this
      pass (see the standing caveat at the top of this header):
        StartScentTrack()
        StartBloodTrack()
        StartGunpowderTrack()
        StopTracking()   -- not named by SPEC.md §11 itself; fills the
            open gap phase2_notes/scent_blood_tracking.md §2.1/§5 item 2
            flags (no self-service "stop" affordance is specified
            anywhere in §11's acceptance criteria) — a manual-cancel
            item, mirroring Attach/Detach Leash's single
            context-sensitive radial item once this is actually wired.
        IsTracking() -> boolean
    - THIS FILE calls client/main.lua's CanShowK9UI() at the top of every
      Start*Track() call — "don't trust the caller already checked," the
      same posture client/movement.lua's RequestLeashAttach() documents
      for itself.
    - THIS FILE reads Config.Tracking.Scent / .Blood / .Gunpowder and
      Config.WaterTrackingDecay (SPEC.md §11.2's config.lua additions) —
      NOT YET LANDED in config.lua as of this scaffold. Every TODO below
      names the exact field path §11.2 specifies so config.lua's eventual
      Phase 2 addition and this file's eventual implementation stay in
      sync on field names without either side guessing at the other.
      Config.Features.ScentTracking / .BloodTracking / .GunpowderSniffing /
      .WaterTrackingDecay already exist in config.lua today (added in
      Phase 1's scaffold pass, currently `false`) — only the tuning
      sub-tables (Config.Tracking.*, Config.WaterTrackingDecay.*) are
      still pending.

    DEPENDENCY NOTE: this file has no compile-time dependency on
    client/search.lua (different trust model, different file — see that
    file's own header for why per §11.3) or client/vision.lua (unrelated
    feature). Load order relative to those two doesn't matter.
]]

--- Local-only view of the CURRENT tracking session, if any. Set by a
--- successful Start*Track() call below, cleared by StopTracking() or by
--- the (not-yet-written) render thread's own water-break bookkeeping.
--- Not exposed directly — always go through IsTracking()/StopTracking().
--- @type { trackType: 'scent'|'blood'|'gunpowder', coords: vector3, breaksAtWater: boolean, brokenByWater: boolean } | nil
local trackingState = nil

--- @return boolean
function IsTracking()
    return trackingState ~= nil
end

--- Shared implementation behind StartScentTrack()/StartBloodTrack()/
--- StartGunpowderTrack() below. SPEC.md §11.5's three trail-type
--- acceptance-criteria blocks are textually identical (only the
--- trackType string and its Config.Tracking.<Type> sub-table differ), so
--- this is one function instead of three near-duplicate copies — mirrors
--- e.g. client/vehicle.lua's ReleasePedFromVehicleState being shared by
--- ExitK9Vehicle() and its onResourceStop safety net rather than
--- duplicated.
--- @param trackType 'scent'|'blood'|'gunpowder'
--- TODO(coder-frontend): SPEC.md §11.4 item 1, §11.5's three tracking
--- acceptance-criteria blocks, phase2_notes/scent_blood_tracking.md §2.1.
--   1. if not CanShowK9UI() then lib.notify(...) return end -- cheap
--      client-side re-check before bothering the server; the server
--      independently re-validates regardless (§11.4 item 1).
--   2. if IsTracking() then lib.notify(...) return end -- OPEN QUESTION,
--      not decided by SPEC.md §11: should starting a NEW track type while
--      already tracking something else silently replace the old session,
--      or be rejected until StopTracking() is called first? Recommend
--      rejecting, matching IsLeashed()'s own "already leashed" rejection
--      in client/movement.lua's RequestLeashAttach() — flag disagreement
--      rather than silently picking the other way.
--   3. local result = lib.callback.await('qbx_k9unit:server:findTrackableSource', false, trackType)
--   4. if not result.found then lib.notify(<generic "nothing to track
--      right now" message>) return end -- NOTE: §11.4 item 1's response
--      shape has no `reason` field (unlike searchTarget's, §11.4 item 2),
--      so "nothing nearby" / "on cooldown" / "no access" all collapse to
--      the same found = false here. phase2_notes/scent_blood_tracking.md
--      §2.4 flags this as a small, still-open UX gap — ship one generic
--      message for now, don't invent a distinction the server doesn't
--      give you data for.
--   5. trackingState = { trackType = trackType, coords = result.coords,
--      breaksAtWater = Config.WaterTrackingDecay.breaksTrail, brokenByWater = false }
--      -- read breaksTrail from the LOCAL shared_script config directly
--      rather than trusting result.breaksAtWater (documented
--      informational-only, see this file's EVENT/CALLBACK CONTRACT above).
--   6. Setting trackingState is sufficient to "wake" the render thread
--      described further below — mirrors the exact comment already on
--      client/movement.lua's leashAttached handler ("simply setting it
--      here is sufficient... no separate thread-start call needed"). Do
--      not add a separate thread-start call here.
local function StartTrack(trackType)
end

--- Radial-facing entry point for scent tracking (Config.Features.ScentTracking).
--- SPEC.md §11.3's client/radial.lua row calls this by this exact name —
--- do not rename without updating that row and radial.lua's eventual
--- wiring (still unwired as of this scaffold).
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
--- anywhere in SPEC.md §11 itself, only a fresh Start*Track() call after
--- a water-break). No-op if not currently tracking.
--- TODO(coder-frontend): trackingState = nil. The render thread below
--- naturally stops drawing once IsTracking() is false, mirroring how
--- client/movement.lua's DetachLeash() comment describes its own elastic
--- thread "naturally stopping" once IsLeashed() is false — no separate
--- thread-teardown call needed. Open, not decided here: does this deserve
--- its own lib.notify() confirmation, or should it be silent (cosmetic,
--- low-stakes action per §11.6's framing of tracking as "no real
--- capability granted")?
function StopTracking()
end

-- TODO(coder-frontend): trail-rendering / water-crossing thread. Reuse
-- the exact idle/active tick-rate-switch pattern client/movement.lua's
-- leash pull-back thread already establishes (its LEASH_TICK_MS /
-- LEASH_IDLE_TICK_MS constants) — sleep long while IsTracking() is
-- false, switch to a short tick only while a session is active. Do NOT
-- run this at Wait(0) unconditionally; flag the exact tick rate for
-- resource-performance-profiler once this is real code, per
-- phase2_notes/scent_blood_tracking.md §2.2 (DrawMarker itself needs
-- calling every frame it should be visible, but the recompute/water-
-- sample half of the loop may not need to run that often — these two
-- rates don't have to match). Per iteration, while IsTracking():
--   1. SPEC.md §11.5's trail-rendering acceptance bullets: compute the
--      LIVE line from GetEntityCoords(PlayerPedId()) toward
--      trackingState.coords, recomputed fresh every tick (NOT a one-time
--      snapshot) — see phase2_notes/water_gunpowder_tracking.md §1.2 for
--      why (the K9's position moves every tick, the resolved source
--      coordinate does not, for the lifetime of one Start*Track() call).
--   2. DrawMarker breadcrumb checkpoints spaced
--      Config.Tracking.<Type>.markerSpacing meters apart along that line.
--      OPEN QUESTION, not resolved by SPEC.md §11 either way
--      (phase2_notes/scent_blood_tracking.md §2.3, §5 item 1): reveal the
--      WHOLE remaining line at once, or only a capped preview window near
--      the player? That note recommends confirming with
--      product-manager/feature-ideation before committing to one — don't
--      silently pick a side here.
--   3. If Config.Features.WaterTrackingDecay, sample the same live line
--      every Config.WaterTrackingDecay.sampleIntervalMeters using
--      GetWaterHeightNoWaves — NOT plain GetWaterHeight, per
--      phase2_notes/water_gunpowder_natives.md §1's explicit
--      recommendation (frame-stable, appropriate for a fixed-step poll
--      like this; plain GetWaterHeight is wave-jittered and can disagree
--      between adjacent samples on a calm shoreline). On a hit:
--        - if trackingState.breaksAtWater (== Config.WaterTrackingDecay.breaksTrail
--          at the moment this session started): stop drawing markers past
--          the crossing point, set trackingState.brokenByWater = true,
--          lib.notify(...), and do NOT auto-resume — per §11.5's explicit
--          "does not silently resume" bullet, a fresh Start*Track() call
--          (subject to that type's own searchCooldownMs) is required to
--          re-acquire, most likely resolving the SAME source coordinate
--          from the far-bank position (nothing server-side is
--          water-aware, per §11.4 item 1's "informational only" note).
--        - else: render markers within/near the water at reduced alpha
--          instead of omitting them; keep rendering past the crossing —
--          this only changes a marker-drawing parameter, the sampling
--          logic itself runs identically either way.
--   4. If Config.Features.WaterTrackingDecay is false: plain straight-line
--      rendering, no water sampling of any kind — confirms this really is
--      a pure modifier per §11.5's own acceptance bullet for the flag-off
--      case, not a prerequisite for scent/blood/gunpowder tracking to
--      work at all.
--   Once IsTracking() is false, drop back to the idle tick — the next
--   Start*Track() call restarts active rendering, nothing else to do.

-- Blood-trail capture (Config.Features.BloodTracking): relays a
-- payload-less event to the server on CEventNetworkEntityDamage where the
-- LOCAL player is the victim. Real, documented FiveM game event per
-- SPEC.md §11.6 and independently confirmed against citizenfx/fivem
-- source in phase2_notes/scent_blood_natives.md §0 — victim identity is
-- data[1], confirmed reliable across multiple independent sources; do
-- NOT depend on any other args[] index (weapon hash, etc.) without a
-- fresh confirmation pass, per that note's own explicit caveat (args[3],
-- [5], [6] are NOT independently confirmed).
AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    -- TODO(coder-frontend): SPEC.md §11.4 item 3.
    --   1. Gate on Config.Features.BloodTracking, read at the point of
    --      firing (SPEC.md §3's hard requirement — a disabled feature
    --      must be a real no-op, not just hidden UI).
    --   2. local victim = tonumber(data[1])
    --      if victim ~= PlayerPedId() then return end -- only relay when
    --      WE are the victim, per §11.4 item 3's exact filter.
    --   3. TriggerServerEvent('qbx_k9unit:server:relayDamageEvent')
    --      -- no payload; the server resolves OUR live coordinates itself
    --      (GetEntityCoords(GetPlayerPed(source))), never a value sent
    --      from here.
end)

-- TODO(coder-frontend): gunpowder capture thread (Config.Features.GunpowderSniffing),
-- SPEC.md §11.4 item 4/§11.6. Debounced local poll of
-- IsPedShooting(PlayerPedId()) watching for a false->true transition —
-- NOT a nearby-ped scan (an earlier, discarded hypothesis; see
-- phase2_notes/water_gunpowder_tracking.md §0.1 item 2 for why "search a
-- suspect for residue" isn't this feature's actual shape — it answers
-- "where was the nearest recent gunfire," not "did this specific ped
-- shoot"). Each client only ever checks its OWN single ped handle, so
-- this is cheap regardless of how many other players are nearby
-- (phase2_notes/water_gunpowder_natives.md §2's own note on why this
-- sidesteps the generic "scan nearby peds" perf concern it otherwise
-- flags for a naive implementation).
--   1. Gate on Config.Features.GunpowderSniffing; this thread should idle
--      entirely (or run a cheap 1000ms poll) while the flag is false,
--      mirroring client/movement.lua's AgilityBasicJump thread's
--      "if not Config.Features.X then start a thread, else don't" shape.
--   2. Poll IsPedShooting(PlayerPedId()) on a modest interval — NOT
--      Wait(0), this is a debounce poll, not a rendering concern; 100-
--      250ms per phase2_notes/water_gunpowder_natives.md §2's perf note
--      on the (rejected) nearby-ped-scan variant, applied here to the
--      single-ped case too as a reasonable default.
--   3. On a false->true transition: TriggerServerEvent('qbx_k9unit:server:relayWeaponFire')
--      -- no payload, same "server resolves our own live position" rule
--      as the damage-event relay above.
--      NOTE (phase2_notes/water_gunpowder_tracking.md §0.2/§2.3, still
--      unconfirmed this session): IsPedShooting's exact per-shot vs.
--      per-burst semantics across a sustained automatic-weapon fire are
--      NOT independently verified — get that confirmed
--      (native-api-assistant) before assuming this debounce alone bounds
--      event frequency. The real flood protection is server/tracking.lua's
--      own dedicated rate limit on relayWeaponFire (§11.4 item 4,
--      explicitly required to be separate from
--      Config.Tracking.Gunpowder.searchCooldownMs) — this client-side
--      debounce is a courtesy reduction, not the safety net itself.
