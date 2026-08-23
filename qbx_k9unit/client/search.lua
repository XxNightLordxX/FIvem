--[[
    qbx_k9unit/client/search.lua

    PHASE 2 SCAFFOLD ONLY (coder-frontend) — WRITTEN AHEAD OF GREENLIGHT.
    Same standing caveat as client/tracking.lua's header: written while
    Phase 1's confirmation wave was still closing out, per SPEC.md §11
    already being fully specified, but NOT final implementation and NOT
    to be merged/wired blindly. In particular:
      - fxmanifest.lua does NOT yet list this file under client_scripts.
      - client/radial.lua gets NO new item for this feature at all (by
        design — see FILE-TO-FILE CONTRACT below, this is ox_target-only).
      - config.lua does NOT yet contain Config.SearchZones /
        Config.SearchContrabandItems (SPEC.md §11.2 additions), and its
        existing Config.ContrabandAlertTiers has no explicit "clean"
        baseline tier yet (see the TODO on that below).
    Mirrors the exact "header contract + function signature + numbered
    TODO" scaffolding style client/main.lua's ORIGINAL scaffold used (see
    `git log -- qbx_k9unit/client/main.lua`, commit 66b8aee), not the
    fully-implemented style Phase 1 files have today.

    Owns Search Vehicle / Search Person: the two ox_target options that
    play a sniff animation, then await the server's real, server-computed
    contraband result — SPEC.md §11.1 sub-phases 2b/2c, §11.3's
    `client/search.lua` row. Deliberately a SEPARATE file from
    client/tracking.lua even though both are "K9 sniffs, a result
    appears" in flavor — §11.3's own stated reason is the TRUST MODEL,
    not the feature name: tracking reveals a client-cosmetic trail (no
    real capability granted, informational only per §11.6); search
    reveals a target's REAL, server-verified inventory contents (a real
    capability grant, the same trust category as certification, per
    §11.3's "splitting by trust model... mirrors how Phase 1 split
    certifications.lua from main.lua" reasoning). Do not fold this file
    into client/tracking.lua, and do not let any of tracking.lua's
    trail-rendering logic grow into this file.

    Supplementary implementation detail cited in the TODOs below
    (non-authoritative — SPEC.md §11 is the source of truth if anything
    here drifts from it): phase2_notes/contraband_search_contract.md
    (the concrete ox_inventory export surface, validation order, and
    container-recursion requirement) and phase2_notes/contraband_search_security_review.md
    (superseded by SPEC.md §11.4's callback shape per
    phase2_notes/EXPORT_TRACKING.md's reconciliation record — read that
    tracking doc's "FINAL VALIDATION PASS" section before trusting
    anything in the security-review note that contradicts §11.4).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2 (full copy, per SPEC.md §11.4 item
    2; the full server-side validation order belongs in
    phase2_notes/contraband_search_contract.md §3, which supplements but
    does not replace §11.4 — the server side of this contract belongs in
    server/search.lua, NOT YET WRITTEN — this is client-side scaffolding
    only):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:searchTarget' (targetType: 'vehicle'|'person', targetNetId: number)
       -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
       [server/search.lua, not yet written]
       THE SECURITY-CRITICAL CALLBACK, per the task's explicit direction
       to confirm search results can't be client-claimed — read
       phase2_notes/contraband_search_contract.md IN FULL before
       implementing server/search.lua (container recursion into bagged
       contraband, an in-flight mutex to close a same-source concurrent-
       call race, `search_failed` kept structurally distinct from
       `contrabandFound = false`, and an explicit "clean" tier — all
       flagged there as must-handle, not optional polish). THIS FILE (the
       client side) only ever CONSUMES this callback's return value — it
       must never compute or pre-display a result on its own, and every
       field in the response is 100% server-computed, never an echo of
       anything this file sent (`targetType`/`targetNetId` are the only
       two fields THIS FILE controls, and only ever select WHICH entity
       gets checked, never the outcome).
       `reason` values to handle (per phase2_notes/contraband_search_contract.md
       §3): 'invalid_target', 'feature_disabled', 'no_access',
       'search_in_progress', 'on_cooldown', 'too_far', 'search_failed'.
       `search_failed` must be shown to the player as distinct from a
       clean result ("couldn't complete the search, try again" — NOT
       "nothing found") — collapsing the two is the exact correctness bug
       that note's §3 step 10 and §6 flag explicitly.

    OPEN GAP, flagged here rather than guessed at: SPEC.md §11.4 does NOT
    name a broadcast event for the found-contraband ALERT that's audible
    to bystanders (§11.5's "plays as a broadcast sound/animation audible
    to nearby players, not just the requesting K9 player" bullet). §11.4
    item 7 only rules out a dedicated event for RESULT DELIVERY to the
    requester (that's the callback above) — it says nothing about the
    separate bystander-broadcast concern, and §11.3's server/search.lua
    row only says the broadcast is done "the same way server/main.lua's
    relayBark does," which could plausibly mean literally reusing the
    already-shipped 'qbx_k9unit:client:playBark' event (with
    barkType = alertTier — 'whine'/'aggressive_bark' read naturally as
    bark-type strings) rather than inventing a new event name. THIS FILE
    does not need to register any handler for that broadcast either way —
    if it reuses playBark, client/main.lua already owns that handler; if
    a new dedicated event is chosen instead (e.g.
    'qbx_k9unit:client:playContrabandAlert'), that handler belongs in
    whichever file ends up documented as owning it, most likely
    client/main.lua by analogy to playBark, not necessarily this file.
    Flag for coder-backend/coder-architect to settle explicitly when
    server/search.lua is written — not decided here, and not something
    this scaffold should guess at by picking a name unilaterally.

    No server events (client->server) or client events (server->client)
    for THIS FILE at all — result delivery to the requester is the
    callback above; the bystander broadcast (whatever event backs it) is
    someone else's receive-side concern per the paragraph above.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes NO resource-global functions to other client
      files. Resolves phase2_notes/EXPORT_TRACKING.md's open naming slot
      #3 ("client/search.lua's exposed resource-global(s), if any") as:
      NONE — this is confirmed ox_target-only, mirroring how
      client/vehicle.lua's ox_target options call that file's OWN
      internal logic directly rather than exposing a cross-file global
      for it. client/radial.lua gets no "Search Vehicle/Person" item —
      SPEC.md §11.5's acceptance criteria only ever describe ox_target as
      the entry point for this feature.
    - THIS FILE calls client/main.lua's CanShowK9UI() inside each
      ox_target option's canInteract AND again, defensively, inside
      onSelect before awaiting the callback — mirrors
      client/vehicle.lua's enterVehicle option, which is exactly the kind
      of "hot call site" client/main.lua's header names as the reason
      HasK9Access() carries a short TTL cache (canInteract can run
      several times a second while hovering).
    - THIS FILE reads Config.SearchZones and Config.SearchContrabandItems
      (the latter only for display/UX purposes if at all — the
      authoritative contraband list is read server-side, per §11.2's
      "single source of truth" framing; this file should NOT duplicate
      contraband-detection logic client-side even for a preview) — SPEC.md
      §11.2 additions to config.lua, NOT YET LANDED as of this scaffold.
      Also flags: config.lua's EXISTING Config.ContrabandAlertTiers (two
      entries today, 'whine'/'aggressive_bark') has no explicit "clean"
      baseline tier yet — phase2_notes/contraband_search_contract.md §5
      recommends adding `{ minWeight = 0, alert = 'clean' }` as the first
      entry so tier lookup never needs a hardcoded fallback outside the
      config-driven table. That's a config.lua/server/search.lua change,
      not something this file can fix on its own, but THIS FILE's
      "nothing found" feedback path (below) depends on that tier (or an
      equivalent fallback) existing so it has something non-empty to
      react to — flagged here so it isn't discovered as a surprise later.

    Ped/NPC search (a "person" search against a non-player ped) is
    explicitly a STRETCH item per §11.3's own scoping note, not required
    for Phase 2 — this scaffold's TODOs only cover the player-only scope
    §11.4 item 2's server-side validation (step 7's
    NetworkGetPlayerIndexFromPed check) already assumes.

    DEPENDENCY NOTE: no compile-time dependency on client/tracking.lua or
    client/vision.lua. Load order relative to those two doesn't matter.
]]

--- Local-only UX guard against double-dispatching the SAME ox_target
--- option while a previous search is still awaiting its callback (e.g. a
--- double-click before the sniff animation/progress bar visually
--- disables the option). This is a UX nicety only, NOT the security
--- boundary — server/search.lua's own in-flight mutex (per
--- phase2_notes/contraband_search_contract.md §4A) is what actually
--- closes the exploitable race; this local flag exists purely so this
--- client doesn't visibly fire two overlapping sniff animations/progress
--- bars against itself.
--- @type boolean
local searchInProgress = false

--- Shared implementation behind the two ox_target options below. Plays
--- the sniff animation/progress bar, awaits the server's authoritative
--- result, and renders feedback — never computes or guesses a result
--- itself. Kept as one function rather than two near-duplicate copies
--- for the same "textually identical acceptance criteria" reason
--- client/tracking.lua's StartTrack() helper documents for its own three
--- callers.
--- @param targetType 'vehicle'|'person'
--- @param targetEntity number  -- resolved live entity handle from the ox_target callback's own `data.entity`
--- TODO(coder-frontend): SPEC.md §11.4 item 2, §11.5's
--- "Search vehicle/person + contraband alert tiers" acceptance-criteria
--- block, phase2_notes/contraband_search_contract.md §3/§5.
--   1. if not CanShowK9UI() then lib.notify(...) return end -- defensive
--      re-check, same posture as every other gated action in this
--      resource; canInteract below is a DISPLAY optimization only, the
--      server independently re-validates HasK9Access(source) regardless
--      (§11.4 item 2 step 3 per the contract note).
--   2. if searchInProgress then return end -- silent, this is routine
--      double-click protection, not an error state worth a notification
--      (mirrors phase2_notes/contraband_search_contract.md §4's own
--      "Rejection UX note" recommendation for on_cooldown/search_in_progress
--      being low-key, not error-styled).
--   3. searchInProgress = true (cleared on every exit path below,
--      mirroring server/search.lua's own in-flight-mutex "cleared on
--      every exit path including errors" requirement — this is the same
--      shape applied client-side for UX rather than security).
--   4. Play the sniff animation for Config.SearchZones.sniffAnimDurationMs.
--      OPEN, not resolved by SPEC.md §11 or any phase2_notes file: exact
--      anim/scenario native. client/movement.lua's K9Sit() precedent used
--      breed-specific WORLD_DOG_SITTING_* scenarios confirmed by
--      native-api-assistant — a "sniffing/searching" scenario would need
--      the SAME kind of confirmation pass before shipping (per
--      phase2_notes/scent_blood_tracking.md §4's identical flag for a
--      tracking-session sniff animation), not a guessed scenario name.
--      lib.progressBar (ox_lib) is a reasonable UX shell around whichever
--      anim is chosen — it already fits this codebase's established
--      player-feedback convention and gives a natural
--      cancel/interrupt hook if the player moves away mid-sniff.
--   5. local result = lib.callback.await('qbx_k9unit:server:searchTarget', false, targetType, NetworkGetNetworkIdFromEntity(targetEntity))
--   6. if not result.ok then
--        - result.reason == 'search_failed': show a DISTINCT "search
--          couldn't be completed, try again" message — NEVER the same
--          copy as a clean result (see the EVENT/CALLBACK CONTRACT block
--          above on why `search_failed` must stay visually distinct from
--          contrabandFound = false).
--        - result.reason == 'on_cooldown' or 'search_in_progress': low-key
--          / no notification, per the contract note's Rejection UX note.
--        - anything else ('no_access', 'feature_disabled', 'too_far',
--          'invalid_target'): a plain error notify is fine, these are
--          not expected to be routine traffic the way cooldown is.
--        return (after clearing searchInProgress).
--   7. if result.ok: render feedback purely from result.contrabandFound /
--      result.totalWeight (private to this requester, per §11.4 item 2 —
--      "returned ONLY to the requesting caller... never broadcast"):
--        - contrabandFound == false: an explicit, NON-SILENT "nothing
--          found" notification/animation beat — per
--          phase2_notes/contraband_search_contract.md §5's explicit
--          requirement ("the requester's own client must render some
--          explicit 'nothing found' feedback... this doesn't need a
--          server broadcast at all, since it's private feedback to the
--          one client who asked and already has the answer in hand").
--          Do NOT leave this case silent.
--        - contrabandFound == true: local success feedback for the
--          requester. The BYSTANDER-audible broadcast alert (if
--          Config.Features.ContrabandAlerts) is a SEPARATE thing the
--          server triggers independently (see this file's header's
--          "OPEN GAP" note above on which event backs it) — THIS
--          function does not need to (and per §11.4 item 2's "never
--          broadcast" language, must NOT try to) trigger any broadcast
--          itself from the client side.
--   8. Clear searchInProgress on every exit path above, including the
--      early returns in steps 1-2 and 6.
local function PerformSearch(targetType, targetEntity)
end

-- TODO(coder-frontend): register the "Search Vehicle" ox_target option
-- (exports.ox_target:addGlobalVehicle, mirroring client/vehicle.lua's
-- existing addGlobalVehicle registration shape exactly) — name
-- 'qbx_k9unit:searchVehicle' (fills phase2_notes/EXPORT_TRACKING.md's
-- open naming slot #4, following the established
-- 'qbx_k9unit:<verbNoun>' convention). distance =
-- Config.SearchZones.vehicleSearchDistance. canInteract: gate on
-- Config.Features.SearchZones (read at registration/predicate time, per
-- SPEC.md §3) AND CanShowK9UI() — this is a DISPLAY optimization only
-- per SPEC.md §3/§4.5, same "not the security boundary" framing
-- client/vehicle.lua's own header already documents for its enterVehicle
-- option, since server/search.lua independently re-verifies everything
-- (§11.4 item 2). onSelect: PerformSearch('vehicle', data.entity).

-- TODO(coder-frontend): register the "Search Person" ox_target option
-- (exports.ox_target:addGlobalPlayer, mirroring client/movement.lua's
-- existing addGlobalPlayer registrations, e.g. its "Attach Leash"
-- option's shape) — name 'qbx_k9unit:searchPerson'. distance =
-- Config.SearchZones.personSearchDistance. canInteract: same
-- Config.Features.SearchZones + CanShowK9UI() gate as above, PLUS
-- NetworkGetPlayerIndexFromPed(entity) == PlayerId() should probably
-- exclude self (mirrors the self-exclusion already established for the
-- leash and certify/revoke ox_target options in client/movement.lua) —
-- not addressed one way or the other by SPEC.md §11, low-stakes UX
-- judgment call rather than a security question (server/search.lua's own
-- proximity + entity-type checks make a self-search harmless even if
-- attempted). onSelect: PerformSearch('person', data.entity).
-- Ped/NPC variant (non-player peds) is an explicit STRETCH item per
-- §11.3 — do not add an addGlobalPed/addModel registration for this pass
-- unless separately greenlit, since server/search.lua's contract
-- (phase2_notes/contraband_search_contract.md §3 step 7) only validates
-- a real connected player's ped for targetType == 'person'.
