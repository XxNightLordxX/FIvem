--[[
    qbx_k9unit/server/tracking.lua

    Phase 2 implementation (coder-backend). Owns the event-relay log backing
    blood-trail and gunpowder-sniff (damage-event / weapon-fire coordinate
    capture, read server-side from the REPORTING CLIENT'S OWN live ped
    position, never a client-supplied coordinate — same "never trust client
    claims" standard server/certifications.lua's header established for
    §4.3), a server-side ox_inventory 'swapItems' hook backing scent-trail
    coordinate capture (added this pass — see AUTHORITATIVE SOURCES item 9
    below), a periodic prune pass dropping entries older than
    Config.Tracking.Scent/Blood/Gunpowder.maxAgeSeconds, and the
    `qbx_k9unit:server:findTrackableSource` callback that resolves the
    nearest matching source (scent/blood/gunpowder) within
    Config.Tracking.<Type>.maxRange of the calling K9's live server-side
    position.

    Ephemeral/in-memory only, deliberately not persisted — mirrors
    server/main.lua's `LeashPairs` precedent (both are live-session data,
    not account data). SPEC.md §10 flags this as still needing db-schema's
    confirmation that the precedent holds here too; not assumed settled by
    this file.

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE:
    1. SPEC.md §11.4 items 1, 3, 4 (event/callback contract) and §11.5's
       "Scent tracking" / "Blood trail tracking" / "Gunpowder residue
       sniffing" / "Water tracking" acceptance criteria — the base
       contract.
    2. SPEC.md §11.6's reality-check refinements (gunpowder/blood relay is
       genuinely authored code, not free). Its framing of scent's
       ox_inventory hook as unconfirmed is SUPERSEDED by item 9 below —
       kept here verbatim rather than edited so the historical reasoning
       trail stays intact.
    3. phase2_notes/RESEARCH_ARCHIVE.md#tracking — client-logic-lens refinement
       of §11.4 items 1/3, plus two explicit "flag for coder-security"
       notes worth restating here since THIS file is where they land:
       (a) `findTrackableSource`'s signature must never grow a
       client-supplied coordinate parameter, (b) `relayDamageEvent` trusts
       the FACT of damage but never the reported location.
    4. phase2_notes/RESEARCH_ARCHIVE.md#tracking — confirms the
       `CEventNetworkEntityDamage` relay pattern is real and sound, but
       flags that it does NOT fire for script-applied damage (only organic
       gameplay damage) — a real, documented gap, not a bug to fix here.
    5. phase2_notes/RESEARCH_ARCHIVE.md#tracking — confirms `IsPedShooting`
       debounce is the right client-side
       trigger for gunpowder (this file only ever receives the resulting
       relay event, it does no shooting-detection itself), and that the
       water-crossing modifier is entirely a CLIENT-side concern
       (client/tracking.lua) — this file never needs to know about water.
    6. SPEC.md §9 items 10, 11, 14 — standing open questions touching this
       file specifically (relay-code effort is real authored work, not
       free; whether tracking needs abuse-limits beyond the per-type
       cooldown is an explicit open judgment call, not decided here). Item
       11's "ox_inventory export for scent-source detection is UNCONFIRMED"
       framing is SUPERSEDED by item 9 below — kept verbatim for the same
       reason as item 2 above.
    7. Coordinator amendment (2026-08-23, this pass): Config.Tracking.Blood
       /Gunpowder.relayCooldownMs are the LOGGING-side rate limits §11.4
       items 3/4 call for (distinct from the QUERY-side searchCooldownMs
       above) — the timestamp is stamped BEFORE any log-append work, since
       CEventNetworkEntityDamage can legitimately fire multiple times per
       hit and a modified client can call TriggerServerEvent directly,
       bypassing the client-side debounce entirely.
    8. exploit-tester finding (2026-08-23, red-team pass against the
       finished client files) + coordinator decision, same day — see
       "FORGED TRAIL DECISION" below.
    9. phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution (tech-scout pass, same day)
       + this pass's implementation (coder-backend, 2026-08-23) — CONFIRMS
       and CLOSES items 2/6's "scent's ox_inventory hook is unconfirmed"
       framing. A real, first-party `ox_inventory` server-side hook,
       `exports.ox_inventory:registerHook('swapItems', callback)`, fires
       synchronously on every item move ox_inventory processes, including a
       ground-drop (`payload.toType == 'drop'`), carrying `payload.source`
       (ox_inventory's own resolved source for the request — the same trust
       level as any RegisterNetEvent's ambient `source`, not a
       client-relabelable value). This is now wired up below (see the
       `exports.ox_inventory:registerHook` call site's own doc comment for
       the full confidence grading) — the "SCENT BRANCH STATUS" note
       further down reflects the new, implemented state; do not trust the
       older "always returns found = false" framing that used to live there
       if you're reading a stale copy of this comment from history/diff.

    FORGED TRAIL DECISION (deliberate, not an oversight — read before
    "fixing" this): relayDamageEvent/relayWeaponFire are payload-less BY
    DESIGN (§11.4 items 3/4 — never trust a client-claimed coordinate), but
    that also means a modified client can call either event directly with
    NO actual damage/shot having occurred at all, skipping
    client/tracking.lua's local "am I really the victim/shooter" filters
    entirely. relayCooldownMs (500ms blood / 300ms gunpowder) throttles the
    RATE of fabricated entries but does not, and structurally cannot,
    prevent an attacker from seeding a decoy at their own current position
    an unlimited number of times over a session, leading a K9 officer's
    subsequent "Track Blood"/"Track Gunpowder" to a fabricated location.
    This CANNOT be closed client-side (any client-side "proof" is exactly
    the claim already established as untrustworthy), and no cheap
    server-side corroboration was added deliberately: the two candidates
    considered (checking the reporter's current health isn't full; checking
    an ammo-consumption delta against a per-player cache) both introduce
    real false-negative risk against legitimate reports (armor can absorb
    all health loss from a genuine hit; weapon switches/reloads would need
    their own extra state) for a feature SPEC.md §11.6 and
    phase2_notes/RESEARCH_ARCHIVE.md#tracking §3 item 2 already explicitly frame
    as acceptable-risk: tracking grants no real capability (SPEC.md §11.6),
    and "a false report just plants a harmless phantom blood-trail
    location" (RESEARCH_ARCHIVE.md#tracking §3 item 2's own words, written
    before this exact scenario was raised again by exploit-tester).
    DECISION: accept this as a known, documented limitation — a griefer can
    waste a K9 officer's time with a fabricated trail, never anything
    server-authoritative (no money/items/permissions/evidence hinges on
    trail accuracy) — rather than add corroboration logic that would
    degrade the legitimate feature for real players wearing armor or
    switching weapons. Revisit ONLY if a later phase ever conditions
    something server-authoritative on a resolved trail source (mirrors the
    exact "revisit if a later phase changes the stakes" framing SPEC.md
    §4.1 already uses for the vehicle-entry-exit exception).

    NOTE — THIS DECISION DOES NOT APPLY TO SCENT (added this pass, see item
    9 above): scent's `swapItems` hook is not a client-triggerable event at
    all — ox_inventory calls it server-to-server, and `payload.source`
    cannot be relabeled by a client to claim a drop that didn't happen.
    There is no "modified client calls the report event directly with
    nothing having actually occurred" vector for scent the way there is for
    blood/gunpowder, so scent's ingest path deliberately has no
    forged-trail-style accepted-risk framing to write — there is no risk of
    that specific shape to accept.

    ADDENDUM (coder-security finding A, this pass — THE "revisit ONLY if a
    later phase..." TRIGGER ABOVE HAS NOW FIRED): Config.Features.XPProgression
    landed this same pass and is precisely that later phase — it conditions
    something server-authoritative (real XP, and therefore a real
    speedMultiplier/scentRangeMultiplier bonus via Config.XPTiers) on a resolved trail
    source, via trackSourceResolved (PendingTrackArrival /
    reportTrackSourceArrival below). Revisiting confirmed this decision's
    own reasoning still holds for the REVEAL itself (a forged/phantom
    location remains cosmetic-only — no money/items/permissions/evidence
    hinges on where the marker trail points), but exposed a SEPARATE,
    orthogonal gap the XP wiring introduced: nothing required the K9 to
    travel any meaningful distance between a source being logged and that
    same K9 reporting arrival at it, so a K9 who plants a source at their
    own feet (forged, for blood/gunpowder) or simply already happens to be
    standing right next to one (true for ANY trackType, including scent's
    non-forgeable hook) could round-trip resolve→arrive for XP with zero
    travel — a stationary farm, not a forged-location problem. This is NOT
    fixed by adding corroboration to relayDamageEvent/relayWeaponFire (the
    false-negative-risk reasoning above for why that was rejected still
    applies unchanged) — it's fixed at the ARRIVAL-ELIGIBILITY layer
    instead, orthogonally to the forged-trail question this section
    otherwise concerns itself with: see `MIN_TRACK_XP_DISTANCE` and its
    call site in findTrackableSource below. The forged-trail accepted-risk
    DECISION above still stands, unmodified, for the REVEAL; only the new
    XP-ticket eligibility gate is new.

    ADDENDUM 2 (economy-audit finding, this pass — MIN_TRACK_XP_DISTANCE
    alone was NOT sufficient): a live economy audit independently confirmed
    trackSourceResolved was still a real, ~3,600-4,200 XP/hr farm even with
    finding A's fix in place, via two holes finding A's own distance-only
    check never touched: (1) a single TrackableLog entry stayed matchable
    for its ENTIRE maxAgeSeconds window, so walking MIN_TRACK_XP_DISTANCE
    away from the SAME still-fresh entry and back re-earned XP off the one
    real logged event indefinitely — no NEW source was ever required; (2)
    MIN_TRACK_XP_DISTANCE and Config.XP.trackArrivalRadius are both
    POSITION-only checks, so a client capable of `SetEntityCoords` could
    satisfy both with a single teleport and ~0ms of real elapsed time. Both
    are now closed: TrackableLog entries carry a `ticketIssued` flag rationing
    each real logged event to at most one ticket ever (see that field's own
    declaration comment), and every PendingTrackArrival ticket now also
    requires genuine elapsed server time, scaled to distance, before it can
    be redeemed (see MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's own declaration
    comment). Neither change touches the forged-trail DECISION above or the
    REVEAL — only trackSourceResolved's XP-ticket eligibility.

    ADDENDUM 3 (coder-backend correctness pass, this pass — ADDENDUM 2's own
    fix was STILL not sufficient): ADDENDUM 2 rations a single TrackableLog
    ENTRY to one ticket ever and requires genuine elapsed time to redeem one,
    but never touched how fast a fresh, never-ticketed entry can be produced
    in the first place — and producing one is cheap: a modified client can
    call the payload-less relayDamageEvent/relayWeaponFire directly (the same
    forgeable-by-design surface the FORGED TRAIL DECISION above already
    accepts for the REVEAL, but that decision was never re-evaluated against
    this XP angle), and 'scent' needs no forgery at all — an ordinary,
    unmodified drop/walk-away/walk-back/pick-up-and-repeat loop manufactures
    a fresh entry every cycle. Config.Tracking.<Type>.searchCooldownMs
    (5000ms shipped) was the only per-cycle throttle either path was actually
    bound by, comfortably longer than MIN_TRACK_XP_DISTANCE's own real-travel
    floor — enough for a farmer to sustain roughly one ticket every ~5s this
    way, ~7,200 XP/hr, HIGHER than the ~3,600-4,200 XP/hr ADDENDUM 2 itself
    treats as worth closing. Closed by `TrackTicketMintCooldown` (see its own
    declaration comment below): a per-source, cross-trackType cooldown on
    ticket-MINTING itself, independent of entry-manufacturing cost or which
    trackType is used. Does not touch the REVEAL (`found = true`/`coords` is
    unaffected) or ADDENDUM 1/2's own mechanisms, which still apply on top of
    this for whatever tickets do get minted.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per SPEC.md §11.4 items 1, 3, 4.
    Identical in shape to server/certifications.lua's contract block so
    coder-backend/coder-frontend can work in parallel without live
    coordination, per that file's own stated rationale for this format.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:findTrackableSource' (trackType: 'scent'|'blood'|'gunpowder')
       -> { found: boolean, coords: vector3?, breaksAtWater: boolean }
       [THIS FILE]
       Re-validates Config.Features.<Type> and HasK9Access(source)
       server-side regardless of client UI state. Resolves the caller's
       OWN live position via GetEntityCoords(GetPlayerPed(source)) —
       NEVER a client-supplied coordinate (the signature deliberately
       takes only `trackType`, no coords parameter — do not add one
       later, see phase2_notes/RESEARCH_ARCHIVE.md#tracking §3 item 1).
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:relayDamageEvent' () [THIS FILE]
       Triggered by a client's own `gameEventTriggered('CEventNetworkEntityDamage', ...)`
       handler when the LOCAL PLAYER IS THE VICTIM (confirmed real pattern,
       phase2_notes/RESEARCH_ARCHIVE.md#tracking §0). Takes no meaningful
       payload — the server logs the reporting client's own live
       coordinates, never a client-supplied position, exactly like
       server/main.lua's relayBark "resolve the sender's own ped, don't
       trust a claimed netId" pattern. Rate-limited by
       Config.Tracking.Blood.relayCooldownMs, stamped BEFORE the log
       append.
    3. 'qbx_k9unit:server:relayWeaponFire' () [THIS FILE]
       Triggered by a client on a debounced local false->true transition
       of IsPedShooting(PlayerPedId()). Same "server logs the reporting
       client's own live coordinates" rule as event 2. Rate-limited by
       Config.Tracking.Gunpowder.relayCooldownMs — independent of, and in
       addition to, Config.Tracking.Gunpowder.searchCooldownMs, which is a
       QUERY-side cooldown (how often a K9 can re-run "Track Gunpowder"),
       not this LOGGING-side cooldown (how often a single shooter's fire
       events get recorded at all). Do not conflate the two.
    4. 'qbx_k9unit:server:reportTrackSourceArrival' () [THIS FILE] PHASE 4
       ADDITION (Config.Features.XPProgression, PHASE4_SPEC.md §13.4.1).
       Fired by client/tracking.lua's render thread the first tick it
       observes its own live distance to a resolved source drop to/below
       Config.XP.trackArrivalRadius (client/tracking.lua's own header, EVENT/
       CALLBACK CONTRACT item 4, confirms this wiring — added same pass as
       this entry). No payload — a trigger only. THIS FILE re-measures the
       caller's OWN live server-side position against the coordinate it
       already resolved and stored in `PendingTrackArrival` (below) —
       NEVER a client-claimed distance/arrival boolean. Rate-limited by
       `TrackArrivalReportCooldown` (defense-in-depth only, see that
       tracker's own declaration comment — the primary anti-farm mechanisms
       are `PendingTrackArrival`'s single-use-then-cleared shape, the
       underlying TrackableLog entry's own one-ticket-ever `ticketIssued`
       rationing, and the real-elapsed-time-vs-distance `minElapsedMs`
       check (ADDENDUM 2, economy-audit fix, this file's header), not this
       rate limit).

    ox_inventory hooks (exports.ox_inventory:registerHook, ox_inventory ->
    THIS FILE, server-to-server — added this pass, SPEC.md §9 items 11/17,
    phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution):
    5. 'swapItems' [THIS FILE]
       ADDENDUM (coordinator decision, 2026-08-24): registration is now
       GATED on a runtime capability check (`IsOxInventoryHookCapable()`,
       this file, checked from an `onResourceStart` handler further down) in
       addition to Config.Features.ScentTracking — fxmanifest.lua's
       `dependencies` block has no version-constraint syntax at all, so it
       cannot guarantee `registerHook` actually exists on whatever
       `ox_inventory` ends up running. If the check fails, this hook is
       never registered at all (not registered-then-early-returning) and
       one warning is printed; see `IsOxInventoryHookCapable()`'s own
       call-site comment for the full reasoning. LIFECYCLE FIX (this pass):
       registration is re-run (via `RegisterScentInventoryHook()`) not only
       on THIS resource's own start but also on ox_inventory's OWN start —
       see the `AddEventHandler('onResourceStart', ...)` call site's own
       doc comment for why a bare `restart ox_inventory` would otherwise
       silently and permanently kill scent tracking without ever restarting
       this resource. Otherwise unchanged: fires
       synchronously, server-side, whenever ox_inventory processes ANY
       slot-to-slot item move — filtered here to `payload.toType == 'drop'`
       (a ground-drop) only.
       Logs the DROPPING PLAYER'S OWN live position, resolved via
       GetEntityCoords(GetPlayerPed(payload.source)) — same "never trust a
       claimed coordinate" rule as events 2/3 above, except there is no
       client relay step at all here: `payload.source` is ox_inventory's
       own resolved source, not a value any client can relabel. Rate-limited
       by Config.Tracking.Scent.relayCooldownMs — see that call site's own
       doc comment for why this is defense-in-depth against ingest volume,
       NOT an anti-forgery measure the way events 2/3's relayCooldownMs is.

    Client events (RegisterNetEvent, server->client): none from this file
    — per SPEC.md §11.4 item 7's own reasoning (already applied to
    Phase 1's `hasK9Access`), tracking-result delivery is
    request/response shaped, so `findTrackableSource` above being a
    lib.callback is sufficient; no fire-and-forget result event is needed.

    Commands: none.

    Automatic path: the internal prune thread (self-scheduled, no external
    trigger) and, as of this pass, the 'swapItems' ox_inventory hook above
    (externally triggered by ox_inventory's own item-move handling, not by
    anything this resource's own client ever calls directly) — otherwise,
    unlike server/certifications.lua's QBCore:Server:OnJobUpdate hook,
    nothing in this file runs outside a direct response to an explicit
    client-initiated event/callback above.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, resource-global from
      server/certifications.lua — reused, never re-derived, per that
      file's own "SINGLE source of truth" rule.
    - THIS FILE does NOT call `IsConfiguredK9Model` — unlike leash
      role-assignment (server/main.lua) or certification grants
      (server/certifications.lua), tracking access is gated purely on
      HasK9Access (job + certification), never on the caller's CURRENT
      ped model. This mirrors HasK9Access's own documented Phase 1
      tradeoff (a certified handler who later isn't K9-modeled still
      passes access checks; client-side display hides the UI for them
      instead) — flagged here so a future edit doesn't "helpfully" add a
      model check that contradicts that established Phase 1 precedent.
    - THIS FILE exposes NO resource-global functions. Nothing outside
      this file calls into it directly — client/tracking.lua interacts
      with it exclusively through the callback/events documented above.
      Do not add exported globals here without updating this contract
      block and README.md's "Public API (exports)" section's function-name table.
    - THIS FILE also CONSUMES one export from ox_inventory (a dependency
      per fxmanifest.lua, already running by the time this file's file-load
      code executes) — `exports.ox_inventory:registerHook('swapItems', ...)`
      — added this pass. This is a one-way consumption (this file registers
      a callback ox_inventory invokes); THIS FILE still exposes nothing of
      its own for ox_inventory or any other resource to call.
      ADDENDUM (coordinator decision, 2026-08-24): fxmanifest.lua's
      `dependencies` block only guarantees ORDERING (ox_inventory starts
      before this resource) — it has no version-constraint syntax at all, so
      it cannot guarantee `registerHook` actually exists on whatever
      `ox_inventory` build ends up running. `IsOxInventoryHookCapable()`
      (declared just above the `registerHook` call site below) is a runtime
      substitute for the version pin fxmanifest.lua cannot express, checked
      once from an `onResourceStart` handler before this hook is ever
      registered.
    - THIS FILE owns `TrackableLog` (scent/blood/gunpowder event log) and
      the cooldown tables below as file-local state. STRUCTURAL NOTE,
      UPDATED THIS PASS (mirrors server/certifications.lua's own
      "STRUCTURAL NOTE" pattern for `Certifications`): 'scent' now HAS an
      entry in `TrackableLog`, fed by the 'swapItems' ox_inventory hook
      documented in the EVENT/CALLBACK CONTRACT block above, structurally
      identical to the blood/gunpowder entries (append-only array of
      `{coords, loggedAt}`, pruned by `Config.Tracking.Scent.maxAgeSeconds`,
      queried by the same nearest-fresh-entry-within-maxRange loop in
      `findTrackableSource` below). This supersedes the OLDER version of
      this note (visible in history/diff) that said scent intentionally had
      no entry here pending a live-query design — that plan was superseded
      by phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution's confirmed
      registerHook-based design (see item 9 in this file's header
      AUTHORITATIVE SOURCES list) before it was ever built.
    - SCENT BRANCH STATUS, UPDATED THIS PASS: the ox_inventory
      `swapItems` hook is now confirmed (phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution,
      tech-scout pass, 2026-08-23 — HIGH confidence on the hook name/payload
      shape from direct source-reading, see that note's §6 confidence table)
      and wired up below. `findTrackableSource`'s 'scent' branch no longer
      special-cases `sourceCoords = nil` — see the "CONFIDENCE NOTE" on the
      `exports.ox_inventory:registerHook` call site itself for the one
      residual sliver of doubt (no independent re-verification against a
      live ox_inventory install this session, and the hook-name enum was
      not confirmed against the canonical docs site directly, both blocked
      by egress restrictions) — this is a real, disclosed confidence
      ceiling, not treated as 100% certain.
    ======================================================================
]]

-- Ephemeral, in-memory only per-type event log backing Scent/Blood/
-- Gunpowder tracking (SPEC.md §11.3, §11.4 items 3/4; scent's entry added
-- this pass per phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution — see the
-- FILE-TO-FILE CONTRACT "STRUCTURAL NOTE, UPDATED THIS PASS" above for why
-- it's now structurally identical to blood/gunpowder rather than absent) —
-- NOT persisted, mirrors server/main.lua's `LeashPairs` precedent (SPEC.md
-- §10 flags this precedent as still needing db-schema's confirmation, not
-- assumed settled here).
-- TrackableLog[trackType][i] = { coords = vector3, loggedAt = <GetGameTimer() ms>,
-- ticketIssued = boolean }. trackType in {'scent', 'blood', 'gunpowder'}.
-- `ticketIssued` ADDED this pass (ANTI-FARM FIX, see findTrackableSource's
-- own doc comment below for the full writeup) — false at log-append time,
-- flipped true the one time (ever) this exact entry is selected as the
-- nearest match AND clears MIN_TRACK_XP_DISTANCE, i.e. the one time it is
-- ever used to mint a PendingTrackArrival ticket. Rations a single real
-- logged event to at most one XP-eligible ticket for its entire lifetime,
-- independent of how many times it is later re-resolved (cosmetically) or
-- how long it remains within maxAgeSeconds.
local TrackableLog = {
    scent = {},
    blood = {},
    gunpowder = {},
}

-- Per-(source, trackType) QUERY-side cooldown backing
-- Config.Tracking.<Type>.searchCooldownMs (SPEC.md §11.4 item 1). Distinct
-- from the LOGGING-side rate limits below (relayDamageEvent/
-- relayWeaponFire) — this one throttles how often a K9 can re-run
-- "Track <Type>", not how often a shooter/victim's own client can report
-- a source event.
--
-- REFACTOR_ROADMAP.md item 1: was its own hand-rolled
-- `LastTrackQueryAt[source][trackType]` table, now a NewNestedCooldown()
-- instance (server/cooldowns.lua) — same two-level (source, trackType) key,
-- no default threshold baked in (each call site passes the relevant
-- trackingConfig.searchCooldownMs explicitly, since it varies by
-- trackType), same playerDropped-based cleanup that drops every trackType
-- for a disconnecting source in one call (see
-- TrackQueryCooldown.RegisterPlayerDropped() below), behavior unchanged.
local TrackQueryCooldown = NewNestedCooldown()
TrackQueryCooldown.RegisterPlayerDropped()

-- Per-source LOGGING-side rate limits (SPEC.md §11.4 items 3/4, sized by
-- the coordinator-amendment fields Config.Tracking.Blood/Gunpowder.relayCooldownMs
-- — "needs its own tight per-player rate limit... independent of, and in
-- addition to, Config.Tracking.Gunpowder's *search*-side cooldown, since
-- this is a *logging* cooldown, not a *query* cooldown"). Stamped BEFORE
-- any log-append work in both relay handlers below — this is the
-- highest-frequency-potential ingest surface in this resource
-- (CEventNetworkEntityDamage can legitimately fire multiple times per hit,
-- and a modified client can call TriggerServerEvent directly, bypassing
-- the client-side debounce entirely).
--
-- REFACTOR_ROADMAP.md item 1: both were their own hand-rolled per-source
-- tables, now NewCooldown() instances (server/cooldowns.lua) — same
-- per-source key, same playerDropped-based cleanup, behavior unchanged.
local DamageRelayCooldown = NewCooldown()
DamageRelayCooldown.RegisterPlayerDropped()
local WeaponFireRelayCooldown = NewCooldown()
WeaponFireRelayCooldown.RegisterPlayerDropped()

-- PHASE 4 ADDITION (coder-backend, XPProgression pass) -- PendingTrackArrival[src]
-- = { trackType, coords, expiresAt, createdAt, minElapsedMs }. Backs
-- Config.XP.awards.trackSourceResolved (config.lua, PHASE4_SPEC.md §13.4.1
-- open question 3): findTrackableSource's own `found = true` reveal below
-- is deliberately NOT the XP award trigger -- awarding there would let a K9
-- farm XP by repeatedly triggering a search without ever completing it (the
-- exact gap that open question flags, explicitly left unresolved by
-- PHASE4_SPEC.md and closed here). Instead, a successful resolve stores
-- where the K9 would need to walk to, and XP is only granted once
-- 'qbx_k9unit:server:reportTrackSourceArrival' below confirms the K9's OWN
-- LIVE server-side position is within Config.XP.trackArrivalRadius of that
-- stored coordinate -- never a client-claimed distance/arrival boolean.
-- Single-slot per source (a fresh resolve overwrites any earlier pending
-- arrival for that source, mirroring server/main.lua's
-- PendingLeashRequests single-slot-per-target shape) -- plain table +
-- manual playerDropped cleanup, NOT a NewCooldown/NewMutex shape (this
-- isn't a rate limiter, it's a short-lived one-shot claim ticket), same
-- reasoning server/main.lua's own PendingLeashRequests declaration gives
-- for its own shape. `createdAt`/`minElapsedMs` ADDED this pass -- see
-- MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's own declaration comment below for the
-- economy-audit finding they close.
local PendingTrackArrival = {}

-- SECURITY FIX (coder-security finding A, this pass) -- see this file's
-- header FORGED TRAIL DECISION addendum for the full exploit writeup this
-- closes. A deliberately LOCAL implementation constant (mirrors
-- server/search.lua's own MAX_CONTAINER_RECURSION_DEPTH precedent for the
-- same "internal defensive bound, not a server-owner tuning knob" posture),
-- not a Config.* field: findTrackableSource below only creates a
-- PendingTrackArrival ticket (i.e. only makes a resolved source eligible
-- for trackSourceResolved XP at all) when the K9's OWN live distance to the
-- resolved source, AT THE MOMENT OF RESOLUTION, is at least this far --
-- otherwise arrival would already be satisfied (or nearly so) with no
-- meaningful travel required, which is exactly the stationary-farm gap
-- finding A identified. Sized well above Config.XP.trackArrivalRadius
-- (3.0 as shipped) so reaching the source from resolve-time position always
-- requires genuine, non-trivial movement -- comfortably below every
-- Config.Tracking.<Type>.maxRange default (40.0), so this does not make
-- otherwise-legitimate, genuinely-distant resolves ineligible.
local MIN_TRACK_XP_DISTANCE = 15.0

-- ECONOMY-AUDIT FIX (this pass, closing two independently-confirmed
-- trackSourceResolved XP-farm holes on top of finding A's stationary-farm
-- fix above):
--
-- HOLE 1 -- REUSABLE SOURCE: MIN_TRACK_XP_DISTANCE above only ever gated
-- whether a TICKET gets created; it never touched the underlying
-- TrackableLog ENTRY itself. A single logged event (one real gunfight, one
-- real item drop) stayed matchable by findTrackableSource's nearest-fresh-
-- entry loop for its ENTIRE maxAgeSeconds window (120-900s) -- so a K9
-- could walk MIN_TRACK_XP_DISTANCE away from that SAME still-fresh entry
-- and back, re-resolve it (once every searchCooldownMs), and re-earn
-- trackSourceResolved XP off the one real event indefinitely, turning any
-- real gunfight or item drop anywhere on the map into a recyclable piñata.
-- FIX: TrackableLog entries now carry their own `ticketIssued` flag (see
-- each log-append call site above and the TrackableLog declaration comment
-- for the full field writeup) -- findTrackableSource below marks the
-- resolved entry `ticketIssued = true` the one time it is ever used to mint
-- a ticket, and refuses to mint a second one for an already-ticketed entry.
-- The cosmetic reveal (`found = true` / `coords`) is completely unaffected
-- either way -- only ticket-minting is gated on this, same "reveal is
-- cosmetic, XP-eligibility is the real gate" split finding A already
-- established.
--
-- HOLE 2 -- NO ELAPSED-TIME REQUIREMENT: reportTrackSourceArrival below
-- only ever compared LIVE POSITION at the moment of the report against
-- `pending.coords` -- it never compared TIME. A client capable of
-- `SetEntityCoords` (teleport) could resolve a source MIN_TRACK_XP_DISTANCE
-- away (satisfying finding A's own check) and then teleport straight onto
-- it, satisfying both the distance-at-resolution AND distance-at-arrival
-- checks with zero real travel and near-zero elapsed time. FIX: every
-- ticket now also stores `createdAt` (GetGameTimer() at ticket-creation)
-- and `minElapsedMs`, computed below from the SAME server-measured
-- `nearestDist` finding A's own check already gates on -- never a
-- client-supplied value -- as `nearestDist / MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS`.
-- reportTrackSourceArrival now additionally requires real elapsed server
-- time (`GetGameTimer() - pending.createdAt`) to be at least that long
-- before paying XP. MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS below is deliberately
-- generous (well above an on-foot sprint, comparable to a patrol vehicle at
-- a brisk city-street pace) precisely so a legitimate K9 handler who
-- reaches the source quickly BY VEHICLE is never falsely blocked -- this
-- closes the "zero elapsed time" teleport case without penalizing
-- genuinely fast, genuinely real travel. Combined with HOLE 1's per-entry
-- rationing above, a farmer can no longer manufacture free tickets by
-- reusing one entry, and even a freshly-earned single ticket can no longer
-- be redeemed with a 0ms teleport-and-report round trip.
local MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS = 25.0 -- ~90 km/h -- a local implementation constant, not a Config.* field, for the same "internal defensive bound" reasoning MIN_TRACK_XP_DISTANCE's own declaration comment gives

-- Defense-in-depth rate limit on the reportTrackSourceArrival event below --
-- same "never leave a per-source ingest path fully unbounded" posture this
-- file already applies to every other event handler (DamageRelayCooldown,
-- WeaponFireRelayCooldown, ScentDropRelayCooldown). This is NOT the primary
-- anti-farm mechanism (that's PendingTrackArrival's single-use-then-cleared
-- shape below, plus TrackQueryCooldown already throttling how often a fresh
-- pending arrival can even be created) -- it just bounds how fast a client
-- can spam this specific event while a pending arrival exists but the K9
-- hasn't reached it yet.
local TrackArrivalReportCooldown = NewCooldown()
TrackArrivalReportCooldown.RegisterPlayerDropped()
local TRACK_ARRIVAL_REPORT_COOLDOWN_MS = 2000

-- SECURITY FIX (coder-backend, this pass -- correctness-pass follow-up on
-- ADDENDUM 2 above): ADDENDUM 2's `ticketIssued` + `minElapsedMs` pair closes
-- "reuse the SAME stale entry indefinitely" and "teleport for ~0ms elapsed
-- time" -- but neither one limits how FAST a brand-new, never-before-ticketed
-- TrackableLog entry can be manufactured in the first place, only what a
-- single already-existing entry can ever yield (one ticket, ever) or how
-- much real travel a single redemption requires. That gap still lets a
-- steady-state farm through both accepted-risk surfaces this file already
-- documents:
--   - Blood/Gunpowder: relayDamageEvent/relayWeaponFire are payload-less and
--     forgeable BY DESIGN (see the FORGED TRAIL DECISION above, which
--     explicitly scoped its "cosmetic-only, acceptable risk" verdict to the
--     REVEAL -- it pre-dates, and was never re-evaluated against, this XP
--     angle). A modified client can call either directly, at its own current
--     position, on nothing but that event's relayCooldownMs (300-500ms).
--   - Scent: needs NO forgery at all -- a genuine, unmodified client
--     drop/walk-15m-away/walk-back/pick-back-up loop (ordinary ox_inventory
--     actions) manufactures a fresh, never-ticketed entry every cycle.
-- Either way, the only per-cycle throttle actually binding this loop today
-- is Config.Tracking.<Type>.searchCooldownMs (5000ms shipped) -- comfortably
-- longer than MIN_TRACK_XP_DISTANCE's own real-travel floor
-- (15m / MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS = 600ms), so a farmer can sustain
-- roughly one trackSourceResolved ticket every ~5s this way: ~7,200 XP/hr at
-- the shipped 10-XP award -- HIGHER than the ~3,600-4,200 XP/hr ADDENDUM 2
-- itself already treats as a real, worth-closing problem, and reachable via
-- 'scent' by any ordinary player with zero forgery whatsoever.
--
-- FIX: one more cooldown, deliberately flat across ALL THREE trackTypes (not
-- nested by trackType the way TrackQueryCooldown is) -- gates how often THIS
-- SOURCE may ever MINT a new PendingTrackArrival ticket at all, independent
-- of which trackType, independent of how cheaply a fresh entry was produced,
-- and independent of the per-type searchCooldownMs above (which only ever
-- throttled the QUERY, never the AWARD). Consumed at the exact point a
-- ticket is minted (see the call site below) -- never at plain resolve-time,
-- so a `found = false`-or-cosmetic-only resolve (nearestDist too small, no
-- match, already-ticketed entry, or feature disabled) never spends this
-- budget. TRACK_TICKET_MINT_COOLDOWN_MS is a local implementation constant,
-- not a Config.* field -- same "internal defensive bound" posture
-- MIN_TRACK_XP_DISTANCE's and MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's own
-- declaration comments already establish for this identical economy-audit
-- context -- sized well above every Config.Tracking.<Type>.searchCooldownMs
-- default (5000ms) specifically so THIS becomes the binding constraint on
-- AWARD frequency regardless of entry-manufacturing cost, while never
-- blocking the cosmetic reveal itself (`found = true`/`coords` above is
-- entirely unaffected either way) or a single legitimate resolve-and-arrive.
local TrackTicketMintCooldown = NewCooldown()
TrackTicketMintCooldown.RegisterPlayerDropped()
local TRACK_TICKET_MINT_COOLDOWN_MS = 30000

-- EIGHTH XP-FARM FIX, CROSS-FILE POINTER (red-team-flagged compound-farm
-- follow-up, this pass): this cooldown's own 1,200 XP/hr ceiling is real and
-- unchanged, but it was never summed against server/search.lua's
-- ContrabandXpMintCooldown (1,500 XP/hr) or server/combat.lua's
-- BiteHoldXpMintCooldown/TakedownXpMintCooldown (1,200 + 1,800 XP/hr) --
-- all four keyed by the same acting player, combining to 5,700 XP/hr
-- uncapped. CLOSED by server/progression.lua's new SHARED, cross-mechanic
-- XP mint budget (XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS, consulted
-- inside AwardXP itself) -- see that file's own declaration comment for the
-- full derivation. Nothing in THIS file needed to change for that half of
-- the fix: AwardXP is the single chokepoint this file's own award call site
-- already goes through. TrackTicketMintCooldown above is KEPT, unchanged --
-- it still shapes how often THIS mechanic can mint; the shared budget in
-- server/progression.lua caps the TOTAL across mechanics.

-- Per-source rate limit on the 'swapItems' ox_inventory hook below (added
-- this pass, SPEC.md §9 items 11/17, phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution).
-- UNLIKE DamageRelayCooldown/WeaponFireRelayCooldown above, this is NOT
-- closing an anti-forgery gap — the hook is server-to-server, so
-- `payload.source` cannot be relabeled by a client to claim a drop that
-- never happened (see this file's header "NOTE — THIS DECISION DOES NOT
-- APPLY TO SCENT"). This exists purely as the same defense-in-depth this
-- file already applies to every ingest surface (never leave a per-source
-- write path fully unbounded) — bounds how fast a rapid drop/pickup/drop
-- loop can grow TrackableLog.scent between prune passes. Costs nothing
-- legitimate: multiple items dropped in the same burst are indistinguishable
-- as scent sources anyway (same coordinate, sub-second apart).
local ScentDropRelayCooldown = NewCooldown()
ScentDropRelayCooldown.RegisterPlayerDropped()

-- trackType -> the Config.Features flag gating that type, and the
-- Config.Tracking sub-table holding its tuning values. Built once at file
-- load (config.lua is a shared_script loaded before this file per
-- fxmanifest.lua's ordering) — no per-call string-casing/lookup needed.
local TRACK_TYPE_FEATURE_FLAGS = {
    scent = 'ScentTracking',
    blood = 'BloodTracking',
    gunpowder = 'GunpowderSniffing',
}
local TRACK_TYPE_CONFIG = {
    scent = Config.Tracking.Scent,
    blood = Config.Tracking.Blood,
    gunpowder = Config.Tracking.Gunpowder,
}

-- Prune pass interval. Deliberately well under the shortest maxAgeSeconds
-- in play (Gunpowder's 120s, "residue is time-sensitive") so a stale entry
-- never lingers past its window by more than this margin — an
-- implementation detail, not a spec-mandated number (SPEC.md §11.4 items
-- 3/4 only require that pruning happen on some periodic interval).
local TRACKABLE_LOG_PRUNE_INTERVAL_MS = 15000

--- Drops any TrackableLog.scent/blood/gunpowder entry older than that
--- type's Config.Tracking.<Type>.maxAgeSeconds. Rebuilds each type's array
--- via a single linear pass (not a full-table `pairs` remove-while-iterating,
--- which is unsafe on Lua arrays) — cheap relative to how infrequently this
--- runs and how small these logs are expected to stay on a normal server
--- (flag for resource-performance-profiler if real entry-count numbers
--- under load ever suggest otherwise).
local function PruneTrackableLogs()
    local now = GetGameTimer()

    local scentMaxAgeMs = Config.Tracking.Scent.maxAgeSeconds * 1000
    local freshScent = {}
    for _, entry in ipairs(TrackableLog.scent) do
        if (now - entry.loggedAt) < scentMaxAgeMs then
            freshScent[#freshScent + 1] = entry
        end
    end
    TrackableLog.scent = freshScent

    local bloodMaxAgeMs = Config.Tracking.Blood.maxAgeSeconds * 1000
    local freshBlood = {}
    for _, entry in ipairs(TrackableLog.blood) do
        if (now - entry.loggedAt) < bloodMaxAgeMs then
            freshBlood[#freshBlood + 1] = entry
        end
    end
    TrackableLog.blood = freshBlood

    local gunpowderMaxAgeMs = Config.Tracking.Gunpowder.maxAgeSeconds * 1000
    local freshGunpowder = {}
    for _, entry in ipairs(TrackableLog.gunpowder) do
        if (now - entry.loggedAt) < gunpowderMaxAgeMs then
            freshGunpowder[#freshGunpowder + 1] = entry
        end
    end
    TrackableLog.gunpowder = freshGunpowder
end

CreateThread(function()
    while true do
        Wait(TRACKABLE_LOG_PRUNE_INTERVAL_MS)
        PruneTrackableLogs()
    end
end)

--- SPEC.md §11.4 item 3. Triggered by a client's own `gameEventTriggered`
--- ('CEventNetworkEntityDamage') handler, filtered CLIENT-SIDE to "local
--- player is the victim" (confirmed real pattern,
--- phase2_notes/RESEARCH_ARCHIVE.md#tracking §0 — `data[1]` is the
--- cross-source-corroborated victim entity handle). Takes no meaningful
--- payload by design — do not add a coordinate argument later (see this
--- file's header FILE-TO-FILE CONTRACT / phase2_notes/RESEARCH_ARCHIVE.md#tracking
--- §3 item 2's explicit warning that this is an easy regression).
---
--- CAVEAT (phase2_notes/RESEARCH_ARCHIVE.md#tracking §0): `CEventNetworkEntityDamage`
--- does NOT fire for script-applied damage (only organic gameplay damage —
--- real weapon hits, falls, vehicle impacts, melee). Not a bug to fix here,
--- just a documented gap worth this comment so a future "why didn't blood
--- tracking pick this up" report isn't mysterious.
---
--- ACCEPTED RISK, not an oversight — see this file's header "FORGED TRAIL
--- DECISION": relayCooldownMs below throttles the RATE a modified client
--- can call this event directly (skipping the "am I really the victim"
--- filter entirely) but cannot prevent it outright. Deliberately not
--- corroborated further.
RegisterNetEvent('qbx_k9unit:server:relayDamageEvent', function()
    local src = source

    if not Config.Features.BloodTracking then return end -- silent no-op, per SPEC.md §3

    -- LOGGING-side rate limit — stamped BEFORE any log-append work (see
    -- DamageRelayCooldown's own doc comment above for why this ordering
    -- matters on this specific ingest surface).
    local now = GetGameTimer()
    if not DamageRelayCooldown.Consume(src, Config.Tracking.Blood.relayCooldownMs, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    TrackableLog.blood[#TrackableLog.blood + 1] = {
        coords = GetEntityCoords(ped), -- NEVER a client-supplied coordinate
        loggedAt = now,
        ticketIssued = false, -- ANTI-FARM FIX (this pass) -- see findTrackableSource's own comment on this field for the full writeup
    }
end)

--- SPEC.md §11.4 item 4. Triggered by a client on a debounced local
--- false->true transition of IsPedShooting(PlayerPedId()) (confirmed
--- real, stable native — phase2_notes/RESEARCH_ARCHIVE.md#tracking §0 "adjacent
--- check", phase2_notes/RESEARCH_ARCHIVE.md#tracking §2 Option A). Takes no
--- meaningful payload — same "never trust a client-supplied coordinate"
--- rule as relayDamageEvent above.
---
--- NOTE: `IsPedShooting`'s exact per-round vs. per-burst semantics are
--- UNCONFIRMED this session (phase2_notes/RESEARCH_ARCHIVE.md#tracking
--- §2.3) — a high-fire-rate weapon could generate many debounced
--- transitions in a short window even with client-side debouncing, so this
--- server-side rate limit does not assume the client-side debounce alone
--- is sufficient.
---
--- ACCEPTED RISK, not an oversight — see this file's header "FORGED TRAIL
--- DECISION": same as relayDamageEvent above, relayCooldownMs throttles
--- rate, not possibility, of a modified client calling this directly with
--- no real shot fired. Deliberately not corroborated further (e.g. against
--- an ammo-consumption delta) — see the header for why.
RegisterNetEvent('qbx_k9unit:server:relayWeaponFire', function()
    local src = source

    if not Config.Features.GunpowderSniffing then return end -- silent no-op, per §3

    -- LOGGING-side rate limit — stamped BEFORE any log-append work, SEPARATE
    -- from Config.Tracking.Gunpowder.searchCooldownMs (§11.4 item 4's
    -- explicit distinction between query-side and logging-side cooldowns).
    local now = GetGameTimer()
    if not WeaponFireRelayCooldown.Consume(src, Config.Tracking.Gunpowder.relayCooldownMs, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    TrackableLog.gunpowder[#TrackableLog.gunpowder + 1] = {
        coords = GetEntityCoords(ped), -- NEVER a client-supplied coordinate
        loggedAt = now,
        ticketIssued = false, -- ANTI-FARM FIX (this pass) -- see findTrackableSource's own comment on this field for the full writeup
    }
end)

--- RUNTIME CAPABILITY CHECK (coordinator decision, 2026-08-24) for the
--- ox_inventory `registerHook` export the 'swapItems' hook below depends on.
--- fxmanifest.lua's `dependencies` block has NO version-constraint syntax at
--- all (confirmed against FiveM's own manifest-parsing source): a
--- dependency string is only ever a constraint when it begins with '/', and
--- the sole defined forms are '/server:BUILD', '/onesync', '/gameBuild:BUILD',
--- '/native:0xHASH' — none of which can pin a DEPENDENT resource's own
--- exports surface. So `dependencies { 'ox_inventory' }` alone cannot
--- guarantee `registerHook` exists on whatever `ox_inventory` actually ends
--- up running — a stale pinned build predating hook support, or a fork that
--- renamed/dropped it, both look identical to fxmanifest.lua. A RUNTIME
--- check is the only thing that can actually confirm it, and is strictly
--- better anyway: a fork can self-declare any version string regardless of
--- its real capabilities, so a version pin (even if the syntax existed)
--- would have been no more trustworthy than this.
---
--- `GetResourceState(...) ~= 'started'` is checked FIRST and treated as an
--- unconditional "unavailable": accessing `exports.ox_inventory` at all on a
--- resource that is not started can itself throw a Lua error (not merely
--- return nil), so this must gate BEFORE any export access is attempted —
--- never be inferred from one.
---
--- The second check deliberately only INDEXES `exports.ox_inventory.registerHook`
--- — it never CALLS it. Calling it is what performs ox_inventory's real
--- hook-registration side effect, so a disposable "probe" call (e.g.
--- registering a throwaway hook just to see if it succeeds) would leave a
--- live, orphaned hook registered forever just to answer this yes/no
--- question — deliberately not done here. The surrounding `pcall` is
--- defense-in-depth against `exports.ox_inventory` itself throwing (see the
--- `GetResourceState` note above — kept as a second layer even with that
--- pre-check in place, the same "never trust a single layer" posture this
--- file already applies everywhere else, e.g. DamageRelayCooldown/
--- WeaponFireRelayCooldown/ScentDropRelayCooldown all being independent
--- per-surface rate limits rather than one shared one).
---
--- HONEST CONFIDENCE NOTE: indexing (not calling) an export is understood,
--- from FiveM's documented exports behavior, to always return a callable
--- wrapper function regardless of whether the target resource actually
--- registered that export name — the real "does it exist" answer is only
--- resolved when the wrapper is CALLED. This was not independently
--- re-verified against FiveM's Lua scripting-runtime source this session
--- (only the fxmanifest.lua dependency-constraint parsing was verified
--- against engine source — a different subsystem). Given that, this
--- indexing check's practical value is mostly as a defensive belt against
--- `exports.ox_inventory` itself erroring (the GetResourceState race noted
--- above); it is NOT guaranteed to catch every case of `registerHook`
--- being absent from an otherwise-started `ox_inventory` (e.g. a fork that
--- removed the hooks module entirely but is still `GetResourceState`
--- `'started'`) — disclosed here rather than silently assumed airtight.
--- @return boolean
local function IsOxInventoryHookCapable()
    if GetResourceState('ox_inventory') ~= 'started' then
        return false
    end

    local ok, hookExport = pcall(function() return exports.ox_inventory.registerHook end)
    return ok and type(hookExport) == 'function'
end

--- SPEC.md §9 items 11/17. GATED AT REGISTRATION (this pass) on BOTH
--- Config.Features.ScentTracking AND IsOxInventoryHookCapable() above —
--- matches this resource's established "config-gated registration, not
--- just config-gated behavior" convention (client/vision.lua's `if
--- Config.Features.ThermalVision then RegisterCommand(...) end`,
--- server/admin.lua's/server/combat.lua's own `onResourceStart`-gated
--- blocks below this comment mirrors): if either check is false,
--- `exports.ox_inventory:registerHook` is never called at all — not
--- registered-then-early-returning inside its own callback body the way
--- relayDamageEvent/relayWeaponFire above stay registered and check
--- Config.Features internally (those are payload-less RegisterNetEvent
--- handlers with no equivalent "leave something live in another resource"
--- cost to avoiding; registering this hook when it should not exist at all
--- is exactly that cost, hence the different shape here).
---
--- Wrapped in `onResourceStart` (THIS resource's own start, per the
--- `GetCurrentResourceName() ~= resourceName` guard — same idiom as
--- server/combat.lua's PropDragging warning and server/admin.lua's command
--- registration) rather than run at bare top-level file-load time, so this
--- is an explicit, one-time "at resource start" checkpoint distinct from
--- mere script-load ordering. Fires exactly once per resource start
--- (`onResourceStart` only ever fires once for a given start), does not
--- poll, and is safe to run this late: ox_inventory is a hard
--- `dependencies` entry in fxmanifest.lua, so it is already running (or
--- knowably not) well before this resource's own `onResourceStart` fires —
--- no player-facing drop can occur before this resource itself has finished
--- starting anyway, so nothing is missed by not registering at bare
--- file-load time instead.
---
--- ON FAILURE (ScentTracking enabled but IsOxInventoryHookCapable() false):
--- prints ONE warning naming ox_inventory, the missing `registerHook`
--- capability, and the exact consequence ("scent tracking disabled"), then
--- leaves the feature genuinely inert — TrackableLog.scent simply never
--- receives an entry (nothing ever calls the hook body below), so
--- findTrackableSource's 'scent' branch always falls through to
--- `{ found = false }` further down, exactly as if no scent source had ever
--- existed. Deliberately NOT an `assert`: this resource reserves hard
--- asserts for actively-dangerous states. (An earlier revision of this
--- sentence cited "server/certifications.lua's two, both access-control
--- invariants". That file contains ZERO asserts -- the claim appears to have
--- conflated it with certifications.lua's two REVOKE PATHS, a different
--- "two" entirely. The real inventory is 25 assert sites across 8 files,
--- each either behind a default-false feature flag or validating a config
--- value config.lua already ships in the safe shape. Corrected because this
--- wrong claim was read as fact and fed straight into a review brief.) — a missing hook here makes the feature
--- silently INERT, never silently EXPLOITABLE, so blocking this entire
--- resource's startup over one disabled-by-default cosmetic feature would
--- be a disproportionate response, mirroring server/combat.lua's own
--- PropDragging warning's identical "enabled but underlying
--- capability/config is missing -> loud warning, not a hard stop" reasoning.
---
--- Confirmed real mechanism otherwise unchanged from the original
--- implementation, phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution §2/§4
--- (tech-scout pass, 2026-08-23): `swapItems` fires SERVER-SIDE,
--- synchronously, on every slot-to-slot item move ox_inventory processes
--- (trunk/stash transfers, giving an item to another player, AND dropping
--- an item on the ground) — `payload.toType == 'drop'` below isolates
--- specifically a drop-to-ground action from the other move types.
---
--- UNLIKE relayDamageEvent/relayWeaponFire above, this is NOT a
--- client-triggerable event at all — ox_inventory calls this hook
--- server-to-server, and `payload.source` is ox_inventory's own resolved
--- `source` for the underlying request (the same trust level as any
--- RegisterNetEvent's ambient `source` global — cannot be relabeled by the
--- client to claim a different player dropped the item). This is why the
--- "FORGED TRAIL DECISION" in this file's header does NOT apply to scent —
--- see the header's own note on this. `ScentDropRelayCooldown` below is
--- NOT closing an anti-forgery gap; it is the same "never leave a
--- per-source write path fully unbounded" defense-in-depth this file
--- already applies to every other ingest surface (see that cooldown's own
--- declaration comment above).
---
--- CONFIDENCE NOTE (honest grading, not independently re-verified against a
--- live ox_inventory install this session — full breakdown in
--- phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution §2/§6): HIGH confidence the hook
--- name/payload shape (`source`, `toType`, `dropId`) is real and current —
--- corroborated two independent ways this session (direct read of
--- `modules/inventory/server.lua`'s `dropItem` function's own
--- `TriggerEventHooks('swapItems', {...})` call site, plus an independent
--- doc-snippet example registration). NOT independently confirmed: the
--- complete, current, version-pinned hook-name enum was never fetched from
--- the canonical docs site (`overextended.dev`/`coxdocs.dev`, both blocked
--- by this environment's egress proxy every time this was checked this
--- session) — a future ox_inventory version renaming/restructuring
--- `swapItems` cannot be ruled out with 100% certainty from source-reading
--- alone. The note's own recommended one-time mitigation (log
--- `json.encode(payload)` once in dev against the actual target-server
--- ox_inventory version to confirm field names before relying on this in
--- production) has NOT been performed as part of this implementation pass —
--- flagging explicitly rather than silently skipping it, so whoever
--- deploys this does it once before going live.
--- Pulled out to a named function (this pass) so it can be invoked from BOTH
--- lifecycle points below — THIS resource's own `onResourceStart` (the
--- original, only call site before this pass) and, NEW this pass,
--- ox_inventory's OWN `onResourceStart` — see the `AddEventHandler` below
--- this function for why the second call site is needed. Behavior at each
--- individual call is completely unchanged from the original single-call-site
--- version.
local function RegisterScentInventoryHook()
    if not Config.Features.ScentTracking then return end -- nothing to gate for; do not probe/warn about a disabled-by-default feature

    if not IsOxInventoryHookCapable() then
        print('[qbx_k9unit] WARNING: Config.Features.ScentTracking is enabled but ' ..
            'ox_inventory\'s registerHook export is unavailable (ox_inventory is missing, not ' ..
            'started, or this build does not support hook registration) -- scent tracking ' ..
            'disabled. No scent sources will ever be logged; findTrackableSource(\'scent\') will ' ..
            'always report found = false.')
        return
    end

    exports.ox_inventory:registerHook('swapItems', function(payload)
        if payload.toType ~= 'drop' then return end -- only a ground-drop counts as a scent source; trunk/stash/give moves are not

        -- Defense-in-depth rate limit, stamped BEFORE any log-append work, same
        -- ordering discipline as every other ingest surface in this file — see
        -- ScentDropRelayCooldown's own declaration comment for why this is NOT
        -- an anti-forgery measure the way relayCooldownMs is for blood/gunpowder.
        if not ScentDropRelayCooldown.Consume(payload.source, Config.Tracking.Scent.relayCooldownMs, GetGameTimer()) then
            return -- silent no-op: rate-limited, not an error worth notifying about
        end

        local ped = GetPlayerPed(payload.source)
        if ped == 0 then return end -- defensive: no live ped (e.g. a system/script-originated drop with no real connected player behind payload.source)

        TrackableLog.scent[#TrackableLog.scent + 1] = {
            coords = GetEntityCoords(ped), -- the DROPPING PLAYER'S OWN live position — NEVER ox_inventory's internal/eventual drop-inventory .coords (not yet created at this point in ox_inventory's own dropItem flow anyway, per RESEARCH_ARCHIVE.md#scent-source-resolution §2) and NEVER anything client-supplied
            loggedAt = GetGameTimer(),
            ticketIssued = false, -- ANTI-FARM FIX (this pass) — see findTrackableSource's own comment on this field for the full writeup
        }
    end)
end

-- LIFECYCLE FIX (coder-backend, this pass): dispatches to
-- RegisterScentInventoryHook() above on TWO distinct triggers, not just one.
--
-- Branch 1 (original, unchanged behavior): THIS resource's own start — see
-- RegisterScentInventoryHook's own doc comment / the original single-call-site
-- version's comments (still accurate) for the full "why onResourceStart, not
-- file-load time" reasoning.
--
-- Branch 2 (NEW this pass — closes a real gap): ox_inventory's OWN start.
-- Confirmed by direct source read of ox_inventory's `modules/hooks/server.lua`
-- this pass: that module keeps its entire hook table in a plain file-local
-- Lua variable (`local eventHooks = {}`), re-initialized empty every single
-- time ox_inventory (re)loads. It DOES clean up correctly when THIS resource
-- (the one that called registerHook) stops — it has its own
-- `AddEventHandler('onResourceStop', ...)` that drops every hook whose
-- `resource` field matches the stopping resource, confirmed via source, so
-- this resource restarting alone (branch 1 re-firing) can never leave a
-- stacked/duplicate hook behind. But it has NO symmetric mechanism to ask a
-- still-running OTHER resource (this one) to re-register after ox_inventory
-- ITSELF restarts — ox_inventory's fresh `eventHooks` table on restart simply
-- has no memory of a hook a still-running qbx_k9unit registered against the
-- PREVIOUS ox_inventory instance. Without this branch, a bare
-- `restart ox_inventory` (a normal, real ops action, e.g. after an
-- ox_inventory update) that does NOT also restart qbx_k9unit would leave
-- scent tracking silently, permanently inert for the rest of qbx_k9unit's
-- uptime — worse than the already-accepted "silently inert, loudly warned
-- ONCE at our own startup" posture RegisterScentInventoryHook's own doc
-- comment describes, since in this specific case no warning would ever print
-- at all (nothing about THIS resource changed to trigger one). Re-running
-- the exact same registration path here re-arms the hook against the
-- freshly-restarted ox_inventory — idempotent to call repeatedly across
-- however many times ox_inventory itself restarts, precisely because each
-- restart already wiped ox_inventory's own hook table clean first, so there
-- is never anything stale here to duplicate.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == 'ox_inventory' then
        RegisterScentInventoryHook()
    end
end)

--- SPEC.md §11.4 item 1. Resolves the nearest trackable source of
--- `trackType` for the CALLING K9's own live server-side position.
--- Validation order (cheapest/most-defensive checks first, same discipline
--- phase2_notes/RESEARCH_ARCHIVE.md#contraband-search §3 establishes for the
--- higher-stakes searchTarget callback in server/search.lua — applied here
--- too even though the stakes are lower, since this reveal is
--- client-cosmetic only, no real capability granted, per SPEC.md §11.6's
--- own framing):
---   1. Payload-shape / trackType validity.
---   2. Config.Features.<Type> — real server-side no-op regardless of
---      client UI state.
---   3. HasK9Access(source).
---   4. Per-(source, trackType) cooldown — stamped BEFORE any lookup work
---      below, mirroring the ordering fix RESEARCH_ARCHIVE.md#contraband-search §3
---      step 13 mandates for searchTarget's cooldown-vs-await race (applies
---      here in case the 'scent' branch ever awaits an ox_inventory call).
---   5. Resolve the caller's own LIVE position — never a client-supplied
---      coordinate (this callback's signature only takes `trackType`, no
---      coords parameter, BY DESIGN — do not add one later).
---   6. Branch by trackType and resolve the nearest matching source.
---
--- STILL-OPEN, NOT DECIDED BY THIS FILE (flag before finalizing elsewhere):
---   - §11 doesn't specify a distinguishing `reason` field for WHY
---     `found = false` (no source in range vs. on cooldown vs. no access) —
---     phase2_notes/RESEARCH_ARCHIVE.md#tracking §2.4 flags this as a small,
---     genuinely open UX question, not decided here. This implementation
---     collapses all three into a bare `{ found = false }`, matching the
---     signature SPEC.md §11.4 item 1 actually specifies.
---   - Whether an in-progress tracking session should auto-cancel on
---     mid-session loss of K9 access (mirroring
---     ForceDetachLeashForSource's precedent for leash) —
---     phase2_notes/RESEARCH_ARCHIVE.md#tracking §5 item 4 flags this as
---     lower-stakes than leash (cosmetic only) but explicitly undecided;
---     not implemented here since a client re-polling this callback next
---     "Track" attempt already re-verifies access on its own.
lib.callback.register('qbx_k9unit:server:findTrackableSource', function(source, trackType)
    if type(trackType) ~= 'string' or not TRACK_TYPE_CONFIG[trackType] then
        return { found = false } -- defensive: never trust client payload shape
    end

    if not Config.Features[TRACK_TYPE_FEATURE_FLAGS[trackType]] then
        return { found = false } -- real server-side no-op regardless of client UI state, per §3
    end

    if not HasK9Access(source) then
        return { found = false } -- reuse the global from server/certifications.lua, do not re-derive
    end

    local trackingConfig = TRACK_TYPE_CONFIG[trackType]

    -- Stamp BEFORE doing any lookup work below — see this function's own
    -- doc comment (step 4) for why. TrackQueryCooldown.Consume checks and
    -- (iff allowed) stamps in one call, at the SAME `now` reused for the
    -- freshness filtering further below.
    local now = GetGameTimer()
    if not TrackQueryCooldown.Consume(source, trackType, trackingConfig.searchCooldownMs, now) then
        return { found = false }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { found = false } end -- defensive: no live ped to read a position from
    local myCoords = GetEntityCoords(ped) -- NEVER a client-supplied coordinate

    -- PHASE 4 ADDITION (coder-backend, XPProgression pass, PHASE4_SPEC.md
    -- §13.4.1 item (a)): "crossing a threshold... changes... the server's
    -- own authoritative scent-range bonus for that K9, read by
    -- server/tracking.lua's findTrackableSource in place of
    -- Config.Tracking.<Type>.maxRange." Read via a `type(GetXPTier) ==
    -- 'function'` runtime existence guard (server/progression.lua, same
    -- soft-dependency convention as server/medkit.lua's RestoreInjury call
    -- site) — this callback works identically whether or not
    -- server/progression.lua happens to be loaded, and is unaffected by
    -- fxmanifest.lua's server_scripts ordering either way (no load-order
    -- assumption is made). Only ever RAISES maxRange (never lowers it below
    -- this type's own configured baseline) — the multiplier check below
    -- (`> 1.0`) means an uncached/base-tier citizenid's
    -- tier.scentRangeMultiplier (Config.XPTiers[1] = 1.00) never changes
    -- maxRange at all, so this is purely an XP-earned BONUS on top of the
    -- type's own tuning, never a silent regression of it. Applied uniformly
    -- to all three trackTypes (scent/blood/gunpowder) — Config.XPTiers has
    -- one `scentRangeMultiplier` value per tier, not one per trackType, so
    -- this reads it as "the K9's general resolved-source detection range
    -- multiplier," not literally scoped to the 'scent' trackType by name;
    -- flagged here as a judgment call on ambiguous spec wording, not a
    -- silently-picked interpretation.
    --
    -- RENAMED + REDESIGNED this pass (economy/config-correctness fix):
    -- this field used to be `scentRange`, a flat replacement value applied
    -- via `math.max(maxRange, tier.scentRange)` — but every tier's
    -- scentRange (5.0-10.0) was smaller than every
    -- Config.Tracking.<Type>.maxRange default (40.0), so that `math.max`
    -- could structurally never take effect: the bonus was dead code from
    -- the moment it shipped. It is now `scentRangeMultiplier`, a factor
    -- applied to THIS type's own `trackingConfig.maxRange` (not a flat
    -- floor), so tiers above base genuinely extend detection range.
    local maxRange = trackingConfig.maxRange
    if Config.Features.XPProgression and type(GetXPTier) == 'function' then
        local trackerPlayer = exports.qbx_core:GetPlayer(source)
        local trackerCitizenid = trackerPlayer and trackerPlayer.PlayerData and trackerPlayer.PlayerData.citizenid
        if trackerCitizenid then
            local tier = GetXPTier(trackerCitizenid)
            if tier and type(tier.scentRangeMultiplier) == 'number' and tier.scentRangeMultiplier > 1.0 then
                maxRange = trackingConfig.maxRange * tier.scentRangeMultiplier
            end
        end
    end

    local sourceCoords

    -- 'scent' / 'blood' / 'gunpowder': nearest still-fresh logged entry
    -- within maxRange. UPDATED THIS PASS (SPEC.md §9 items 11/17,
    -- phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution §4): 'scent' no longer
    -- special-cases `sourceCoords = nil` — TrackableLog.scent is now fed by
    -- the 'swapItems' ox_inventory hook above, so it is scanned by this
    -- exact same loop, identically to blood/gunpowder. Discards entries
    -- already older than maxAgeSeconds even if PruneTrackableLogs hasn't
    -- swept them yet (belt-and-suspenders against a prune-timing gap, not a
    -- substitute for pruning).
    local maxAgeMs = trackingConfig.maxAgeSeconds * 1000
    local nearestDist
    -- ANTI-FARM FIX (this pass) -- the actual TrackableLog entry object the
    -- current best match came from, so the ticket-minting step below can
    -- read/flip its `ticketIssued` flag. NOT reset per-loop-iteration on a
    -- rejected candidate -- only ever (re)assigned in lockstep with
    -- `nearestDist`/`sourceCoords` above, so it always refers to the SAME
    -- entry those two describe.
    local nearestEntry

    for _, entry in ipairs(TrackableLog[trackType]) do
        if (now - entry.loggedAt) < maxAgeMs then
            local dist = #(myCoords - entry.coords)
            if dist <= maxRange and (not nearestDist or dist < nearestDist) then
                nearestDist = dist
                sourceCoords = entry.coords
                nearestEntry = entry
            end
        end
    end

    if not sourceCoords then
        return { found = false }
    end

    -- PHASE 4 ADDITION (coder-backend, XPProgression pass) -- see
    -- PendingTrackArrival's own declaration comment above for the full
    -- anti-farm rationale. Only bothers tracking a pending arrival at all
    -- when the feature is enabled, per SPEC.md §3's "read the flag at the
    -- point of use" rule -- when XPProgression is false this is simply dead
    -- state nobody ever reads (reportTrackSourceArrival's own handler below
    -- also re-checks the flag independently).
    --
    -- SECURITY FIX (coder-security finding A, this pass) -- see this file's
    -- header FORGED TRAIL DECISION addendum for the full exploit writeup:
    -- `nearestDist` (the K9's OWN live distance to `sourceCoords`, computed
    -- entirely server-side above -- never a client value) must clear
    -- MIN_TRACK_XP_DISTANCE before a ticket is created at all. Without this,
    -- a K9 who is ALREADY standing within Config.XP.trackArrivalRadius of a
    -- source at the moment they resolve it (trivially: they just planted
    -- that exact source themselves via relayDamageEvent/relayWeaponFire or
    -- an item-drop at their own feet, but this also applied to any
    -- GENUINE source that merely happened to already be nearby) could
    -- immediately follow up with reportTrackSourceArrival and be awarded
    -- XP for zero meaningful travel -- round-robining scent/blood/gunpowder
    -- turned this into a near-continuous, fully-stationary farm limited
    -- only by TrackArrivalReportCooldown. This check requires the K9 to
    -- cover real distance between resolving a source and arriving at it,
    -- regardless of whether that source was forged or genuine -- the
    -- client-cosmetic marker-trail REVEAL below is entirely unaffected (it
    -- still returns `found = true`/`coords` either way); only XP-ticket
    -- eligibility is gated on this.
    -- ECONOMY-AUDIT FIX, HOLE 1 (this pass) -- see MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's
    -- own declaration comment above for the full writeup: `nearestEntry` (the
    -- exact TrackableLog entry `sourceCoords` came from) must not already
    -- have had a ticket minted from it, ever. Without this, walking
    -- MIN_TRACK_XP_DISTANCE away from the SAME still-fresh entry and back
    -- re-earned XP off the one real logged event indefinitely.
    -- SECURITY FIX (coder-backend, this pass) -- `TrackTicketMintCooldown.Consume`
    -- is deliberately the LAST condition checked (cheapest/most-defensive
    -- checks first, same discipline this function's own doc comment already
    -- establishes) and is a per-SOURCE, cross-trackType budget -- see that
    -- cooldown's own declaration comment above for the full farm writeup
    -- this closes. Ordered after `not nearestEntry.ticketIssued` so an
    -- already-spent entry (which was never going to mint anything anyway)
    -- doesn't burn this budget for nothing.
    if Config.Features.XPProgression and nearestDist >= MIN_TRACK_XP_DISTANCE
        and nearestEntry and not nearestEntry.ticketIssued
        and TrackTicketMintCooldown.Consume(source, TRACK_TICKET_MINT_COOLDOWN_MS, now) then
        nearestEntry.ticketIssued = true -- ration this entry to one ticket, ever -- the cosmetic reveal below is unaffected either way
        PendingTrackArrival[source] = {
            trackType = trackType,
            coords = sourceCoords, -- the SAME server-resolved coordinate returned to the client below -- never re-derived from a later client claim
            expiresAt = now + Config.XP.trackArrivalTTLMs,
            createdAt = now, -- ECONOMY-AUDIT FIX, HOLE 2 -- real elapsed time is measured from this, never a client-reported duration
            minElapsedMs = (nearestDist / MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS) * 1000, -- derived from the SAME server-measured nearestDist gated on just above
        }
    end

    return {
        found = true,
        coords = sourceCoords,
        -- Informational only (phase2_notes/RESEARCH_ARCHIVE.md#tracking
        -- §1.2) — config.lua is a shared_script so the client can already
        -- read Config.WaterTrackingDecay.breaksTrail directly; populate it
        -- anyway for future-proofing (e.g. a later per-type override).
        breaksAtWater = Config.WaterTrackingDecay.breaksTrail,
    }
end)

--- PHASE 4 ADDITION (coder-backend, XPProgression pass). Fired by
--- client/tracking.lua's own render thread the FIRST tick it observes its
--- local distance to the resolved source coordinate drop to/below
--- Config.XP.trackArrivalRadius — see that file's own comment for the exact
--- client-side trigger. No payload: this handler re-measures the CALLER'S
--- OWN LIVE server-side position against the coordinate THIS SERVER already
--- resolved and stored in PendingTrackArrival above — never a client-claimed
--- distance, arrival boolean, or coordinate. A modified client calling this
--- event with no real search having resolved anything, or from far away, or
--- repeatedly, gets nothing: no pending entry / an expired entry / a live
--- distance still over the radius all fall through to a silent no-op below.
RegisterNetEvent('qbx_k9unit:server:reportTrackSourceArrival', function()
    local src = source

    if not Config.Features.XPProgression then return end -- real server-side no-op regardless of client UI state, per §3
    if not HasK9Access(src) then return end -- reuse the global from server/certifications.lua, do not re-derive

    local now = GetGameTimer()

    if not TrackArrivalReportCooldown.Consume(src, TRACK_ARRIVAL_REPORT_COOLDOWN_MS, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local pending = PendingTrackArrival[src]
    if not pending then return end -- no resolved-but-unreached source is currently pending for this source

    if now > pending.expiresAt then
        PendingTrackArrival[src] = nil -- stale — drop it rather than leave it around for a later, unrelated report to consume
        return
    end

    -- ECONOMY-AUDIT FIX, HOLE 2 (this pass) -- see MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's
    -- own declaration comment above for the full writeup. `pending.createdAt`/
    -- `now` are both server GetGameTimer() values -- never a client-reported
    -- duration. Deliberately does NOT clear the pending ticket on this
    -- branch (unlike the expiry/single-use paths below) -- a genuine K9 who
    -- simply arrived faster than expected just needs to wait out the
    -- remainder of `minElapsedMs` and report again (bounded by
    -- TrackArrivalReportCooldown above), not lose their in-flight ticket.
    if (now - pending.createdAt) < pending.minElapsedMs then
        return -- too little real time has passed to be genuine travel
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    local dist = #(GetEntityCoords(ped) - pending.coords) -- LIVE server-side measurement, never a client-supplied distance
    if dist > Config.XP.trackArrivalRadius then return end -- not actually there yet, regardless of what the client's own render thread believes

    -- Single-use: consumed now, regardless of what AwardXP below does with
    -- it, so a second report for the same resolved source (whether a
    -- retry, a race, or an attempted repeat) cannot double-award.
    PendingTrackArrival[src] = nil

    local trackerPlayer = exports.qbx_core:GetPlayer(src)
    local trackerCitizenid = trackerPlayer and trackerPlayer.PlayerData and trackerPlayer.PlayerData.citizenid
    if not trackerCitizenid then return end

    -- Runtime existence guard, same soft-dependency convention as this
    -- file's own GetXPTier call site above and server/medkit.lua's
    -- RestoreInjury precedent — no load-order assumption on
    -- server/progression.lua either way.
    if type(AwardXP) == 'function' then
        AwardXP(trackerCitizenid, 'trackSourceResolved')
    end
end)

-- Cleans up this file's per-source ephemeral state on disconnect, same
-- rationale as server/main.lua's playerDropped handler (drop
-- cooldown-table entries so they don't leak one per session) and
-- server/certifications.lua's own "regression-test fix" for unbounded
-- per-citizenid cache growth. `TrackableLog` itself needs NO per-source
-- cleanup here — its entries are keyed by coordinate/timestamp, not by
-- the reporting source, and are already pruned on their own
-- maxAgeSeconds schedule regardless of whether the original reporter is
-- still connected.
--
-- REFACTOR_ROADMAP.md item 1: TrackQueryCooldown/DamageRelayCooldown/
-- WeaponFireRelayCooldown/ScentDropRelayCooldown each already registered
-- their OWN independent `playerDropped` handler via
-- :RegisterPlayerDropped() at their own declaration above, so there is no
-- longer a dedicated handler for this file's cooldown state — each tracker
-- owns clearing its own entry for the disconnecting source, same net
-- effect as before.
--
-- QA FIX (this pass): `PendingTrackArrival` is NOT one of those tracker
-- instances (it's a plain table storing {trackType, coords, expiresAt}, not
-- a `key -> lastTouchedAtMs` cooldown shape — see its own declaration
-- comment above for why none of NewCooldown/NewNestedCooldown/NewMutex
-- fit), so it was never actually covered by any of the RegisterPlayerDropped
-- calls above, DESPITE that same declaration comment's own claim of "plain
-- table + manual playerDropped cleanup" — no such handler previously
-- existed anywhere in this file. Left uncleaned, a disconnecting source's
-- pending ticket would sit until its own `expiresAt` TTL lapses (up to
-- Config.XP.trackArrivalTTLMs, 60s) — not just an unbounded-growth concern
-- (bounded anyway by the TTL and by there being at most one connected
-- player per source id at a time) but a genuine misattribution risk: FiveM
-- recycles numeric server ids, so a new, unrelated player could be assigned
-- the disconnecting player's old source id before that TTL lapses and,
-- inside that window, unknowingly stand within Config.XP.trackArrivalRadius
-- of a coordinate resolved for a DIFFERENT citizenid's earlier search
-- entirely — awarding trackSourceResolved XP to the wrong K9 for a search
-- they never made. Clearing this below on the disconnecting source's own
-- playerDropped closes that window, mirroring server/main.lua's
-- PendingLeashRequests target-side cleanup (that table's own precedent for
-- "plain table, manual handler" — see this file's PendingTrackArrival
-- declaration comment) for the exact same key shape (keyed by a single
-- source, no initiator/target pairing to additionally scan for, unlike
-- PendingLeashRequests' own two-sided cleanup).
AddEventHandler('playerDropped', function(_reason)
    local src = source
    PendingTrackArrival[src] = nil
end)
