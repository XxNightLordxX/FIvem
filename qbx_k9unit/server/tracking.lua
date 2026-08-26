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
    not account data). DEVELOPER_REFERENCE.md §10 flags this as still needing db-schema's
    confirmation that the precedent holds here too; not assumed settled by
    this file.

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE:
    1. DEVELOPER_REFERENCE.md §11.4 items 1, 3, 4 (event/callback contract) and §11.5's
       "Scent tracking" / "Blood trail tracking" / "Gunpowder residue
       sniffing" / "Water tracking" acceptance criteria — the base
       contract.
    2. DEVELOPER_REFERENCE.md §11.6's reality-check refinements (gunpowder/blood relay is
       genuinely authored code, not free). Its framing of scent's
       ox_inventory hook as unconfirmed is SUPERSEDED by item 9 below —
       kept here verbatim rather than edited so the historical reasoning
       trail stays intact.
    3. DEVELOPER_REFERENCE.md#tracking — client-logic-lens refinement
       of §11.4 items 1/3, plus two explicit "flag for coder-security"
       notes worth restating here since THIS file is where they land:
       (a) `findTrackableSource`'s signature must never grow a
       client-supplied coordinate parameter, (b) `relayDamageEvent` trusts
       the FACT of damage but never the reported location.
    4. DEVELOPER_REFERENCE.md#tracking — confirms the
       `CEventNetworkEntityDamage` relay pattern is real and sound, but
       flags that it does NOT fire for script-applied damage (only organic
       gameplay damage) — a real, documented gap, not a bug to fix here.
    5. DEVELOPER_REFERENCE.md#tracking — confirms `IsPedShooting`
       debounce is the right client-side
       trigger for gunpowder (this file only ever receives the resulting
       relay event, it does no shooting-detection itself), and that the
       water-crossing modifier is entirely a CLIENT-side concern
       (client/tracking.lua) — this file never needs to know about water.
    6. DEVELOPER_REFERENCE.md §9 items 10, 11, 14 — standing open questions touching this
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
    9. DEVELOPER_REFERENCE.md#scent-source-resolution (tech-scout pass, same day)
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
    their own extra state) for a feature DEVELOPER_REFERENCE.md §11.6 and
    DEVELOPER_REFERENCE.md#tracking §3 item 2 already explicitly frame
    as acceptable-risk: tracking grants no real capability (DEVELOPER_REFERENCE.md §11.6),
    and "a false report just plants a harmless phantom blood-trail
    location" (DEVELOPER_REFERENCE.md#tracking §3 item 2's own words, written
    before this exact scenario was raised again by exploit-tester).
    DECISION: accept this as a known, documented limitation — a griefer can
    waste a K9 officer's time with a fabricated trail, never anything
    server-authoritative (no money/items/permissions/evidence hinges on
    trail accuracy) — rather than add corroboration logic that would
    degrade the legitimate feature for real players wearing armor or
    switching weapons. Revisit ONLY if a later phase ever conditions
    something server-authoritative on a resolved trail source (mirrors the
    exact "revisit if a later phase changes the stakes" framing DEVELOPER_REFERENCE.md
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
    EVENT/CALLBACK CONTRACT — Phase 2, per DEVELOPER_REFERENCE.md §11.4 items 1, 3, 4.
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
       later, see DEVELOPER_REFERENCE.md#tracking §3 item 1).
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:relayDamageEvent' () [THIS FILE]
       Triggered by a client's own `gameEventTriggered('CEventNetworkEntityDamage', ...)`
       handler when the LOCAL PLAYER IS THE VICTIM (confirmed real pattern,
       DEVELOPER_REFERENCE.md#tracking §0). Takes no meaningful
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
       ADDITION (Config.Features.XPProgression, DEVELOPER_REFERENCE.md §13.4.1).
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
    THIS FILE, server-to-server — added this pass, DEVELOPER_REFERENCE.md §9 items 11/17,
    DEVELOPER_REFERENCE.md#scent-source-resolution):
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
    — per DEVELOPER_REFERENCE.md §11.4 item 7's own reasoning (already applied to
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
      by DEVELOPER_REFERENCE.md#scent-source-resolution's confirmed
      registerHook-based design (see item 9 in this file's header
      AUTHORITATIVE SOURCES list) before it was ever built.
    - SCENT BRANCH STATUS, UPDATED THIS PASS: the ox_inventory
      `swapItems` hook is now confirmed (DEVELOPER_REFERENCE.md#scent-source-resolution,
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
-- Gunpowder tracking (DEVELOPER_REFERENCE.md §11.3, §11.4 items 3/4; scent's entry added
-- this pass per DEVELOPER_REFERENCE.md#scent-source-resolution — see the
-- FILE-TO-FILE CONTRACT "STRUCTURAL NOTE, UPDATED THIS PASS" above for why
-- it's now structurally identical to blood/gunpowder rather than absent) —
-- NOT persisted, mirrors server/main.lua's `LeashPairs` precedent (DEVELOPER_REFERENCE.md
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
-- Config.Tracking.<Type>.searchCooldownMs (DEVELOPER_REFERENCE.md §11.4 item 1). Distinct
-- from the LOGGING-side rate limits below (relayDamageEvent/
-- relayWeaponFire) — this one throttles how often a K9 can re-run
-- "Track <Type>", not how often a shooter/victim's own client can report
-- a source event.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled
-- `LastTrackQueryAt[source][trackType]` table, now a NewNestedCooldown()
-- instance (server/cooldowns.lua) — same two-level (source, trackType) key,
-- no default threshold baked in (each call site passes the relevant
-- trackingConfig.searchCooldownMs explicitly, since it varies by
-- trackType), same playerDropped-based cleanup that drops every trackType
-- for a disconnecting source in one call (see
-- TrackQueryCooldown.RegisterPlayerDropped() below), behavior unchanged.
local TrackQueryCooldown = NewNestedCooldown()
TrackQueryCooldown.RegisterPlayerDropped()

-- Per-source LOGGING-side rate limits (DEVELOPER_REFERENCE.md §11.4 items 3/4, sized by
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
-- DEVELOPER_REFERENCE.md item 1: both were their own hand-rolled per-source
-- tables, now NewCooldown() instances (server/cooldowns.lua) — same
-- per-source key, same playerDropped-based cleanup, behavior unchanged.
local DamageRelayCooldown = NewCooldown()
DamageRelayCooldown.RegisterPlayerDropped()
local WeaponFireRelayCooldown = NewCooldown()
WeaponFireRelayCooldown.RegisterPlayerDropped()

-- PHASE 4 ADDITION (coder-backend, XPProgression pass) -- PendingTrackArrival[src]
-- = { trackType, coords, expiresAt, createdAt, minElapsedMs }. Backs
-- Config.XP.awards.trackSourceResolved (config.lua, DEVELOPER_REFERENCE.md §13.4.1
-- open question 3): findTrackableSource's own `found = true` reveal below
-- is deliberately NOT the XP award trigger -- awarding there would let a K9
-- farm XP by repeatedly triggering a search without ever completing it (the
-- exact gap that open question flags, explicitly left unresolved by
-- DEVELOPER_REFERENCE.md and closed here). Instead, a successful resolve stores
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
-- this pass, DEVELOPER_REFERENCE.md §9 items 11/17, DEVELOPER_REFERENCE.md#scent-source-resolution).
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
-- implementation detail, not a spec-mandated number (DEVELOPER_REFERENCE.md §11.4 items
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

--- DEVELOPER_REFERENCE.md §11.4 item 3. Triggered by a client's own `gameEventTriggered`
--- ('CEventNetworkEntityDamage') handler, filtered CLIENT-SIDE to "local
--- player is the victim" (confirmed real pattern,
--- DEVELOPER_REFERENCE.md#tracking §0 — `data[1]` is the
--- cross-source-corroborated victim entity handle). Takes no meaningful
--- payload by design — do not add a coordinate argument later (see this
--- file's header FILE-TO-FILE CONTRACT / DEVELOPER_REFERENCE.md#tracking
--- §3 item 2's explicit warning that this is an easy regression).
---
--- CAVEAT (DEVELOPER_REFERENCE.md#tracking §0): `CEventNetworkEntityDamage`
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

    if not Config.Features.BloodTracking then return end -- silent no-op, per DEVELOPER_REFERENCE.md §3

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

--- DEVELOPER_REFERENCE.md §11.4 item 4. Triggered by a client on a debounced local
--- false->true transition of IsPedShooting(PlayerPedId()) (confirmed
--- real, stable native — DEVELOPER_REFERENCE.md#tracking §0 "adjacent
--- check", DEVELOPER_REFERENCE.md#tracking §2 Option A). Takes no
--- meaningful payload — same "never trust a client-supplied coordinate"
--- rule as relayDamageEvent above.
---
--- NOTE: `IsPedShooting`'s exact per-round vs. per-burst semantics are
--- UNCONFIRMED this session (DEVELOPER_REFERENCE.md#tracking
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
---
--- COMPAT-LAYER MIGRATION (this pass, coder-backend): this whole function is
--- DELETED, not kept alongside a new call, and every word of reasoning
--- above is preserved here (not deleted with it) because it is EXACTLY the
--- reasoning `IsResourceExportCapable` in shared/compat/inventory.lua now
--- implements generically, per-adapter, for WHATEVER inventory backend
--- Config.Compat actually resolved — same order (`GetResourceState(...) ==
--- 'started'` checked first, unconditionally, before any export access is
--- attempted), same shape (a pcall'd INDEX, never a probe CALL), same
--- disclosed honesty limit (indexing an export cannot prove a specific
--- name truly exists on FXServer, only that accessing it didn't throw). A
--- second, ox_inventory-only copy of this exact check would have answered
--- the wrong question on any other backend (ox_inventory not started ->
--- always `false`, even when e.g. qb-inventory's own real hook mechanism IS
--- available) — this is the identical REFACTOR_ROADMAP duplicate
--- server/inventory.lua's own header already flagged for its byte-for-byte
--- copy of this same function, now resolved on both sides by routing
--- through the shared adapter layer instead of keeping either local copy.
--- `RegisterScentInventoryHook` below now reads `K9Compat.Get('inventory').RegisterHook`'s
--- own boolean return value in place of this function's result, preserving
--- the exact "warn once, feature stays cleanly inert" behavior this file's
--- own doc comment below already documents.

--- DEVELOPER_REFERENCE.md §9 items 11/17. GATED AT REGISTRATION (this pass) on BOTH
--- Config.Features.ScentTracking AND the routed `RegisterHook` call's own
--- boolean return below (see the migration note above this doc comment) —
--- matches this resource's established "config-gated registration, not
--- just config-gated behavior" convention (client/vision.lua's `if
--- Config.Features.ThermalVision then RegisterCommand(...) end`,
--- server/admin.lua's/server/combat.lua's own `onResourceStart`-gated
--- blocks below this comment mirrors): if the feature flag is off,
--- `K9Compat.Get('inventory').RegisterHook` is never called at all — not
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
--- implementation, DEVELOPER_REFERENCE.md#scent-source-resolution §2/§4
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
--- DEVELOPER_REFERENCE.md#scent-source-resolution §2/§6): HIGH confidence the hook
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
-- COMPAT-LAYER MIGRATION + STUB-DEGRADE ANALYSIS (coder-backend, this pass):
-- ROUTED THROUGH K9Compat.Get('inventory') (shared/compat/core.lua's
-- RequiredMethods.inventory.server.RegisterHook) below, never a direct
-- `exports.ox_inventory:registerHook` call. `RegisterHook`'s own boolean
-- return replaces the deleted `IsOxInventoryHookCapable()` (see that
-- function's own migration note above) for deciding whether to print the
-- warning -- the plain-Lua-function calling convention for `callback`
-- itself is UNCHANGED (confirmed correct: any function crossing a resource
-- export boundary is msgpack-packed into a callable table by the runtime
-- before it ever reaches the far side, so a plain function here is, and has
-- always been, the only convention that works -- see
-- shared/compat/inventory.lua's own RegisterHook doc comment for the full
-- citation) -- do not wrap `callback` in anything else.
--
-- STUB-DEGRADE, undetected inventory: `RegisterHook` returns `false`, the
-- warning below prints once, and TrackableLog.scent simply never receives
-- an entry -- `findTrackableSource('scent')` already, correctly, falls
-- through to `{ found = false }`, exactly the pre-existing "silently
-- inert, loudly warned once" posture this file's own header already
-- documents for an ox_inventory-missing session. A clean, disclosed
-- "feature switched off" degrade, never a crash.
--
-- STUB-DEGRADE, qb-inventory specifically (the other CONFIRMED backend) --
-- CORRECTED this pass (coder-backend): an EARLIER revision of this comment
-- recorded a "registers successfully but silently does nothing" failure
-- shape here -- the worst one in the codebase, per this task's own framing
-- -- based on a claim that qb-inventory never fires any real event for a
-- ground drop. That claim was WRONG: re-fetching and re-reading
-- qbcore-framework/qb-inventory's `main` branch directly this session found
-- the real, current call site the earlier pass missed (server/main.lua's
-- own `qb-inventory:server:createDrop` callback: `TriggerHook('ItemDropped',
-- hookData.item.type, hookData)`, firing on every real ground drop with a
-- payload containing the dropping player's own `source`). See
-- shared/compat/inventory.lua's own qb-inventory RegisterHook doc comment
-- for the full citation and the translation this file's `RegisterHook`
-- call below now benefits from with NO code change needed at this call
-- site: `RegisterHook('swapItems', ...)` now also registers a second, real
-- `AddHook('ItemDropped', ...)` internally, and translates it onto this
-- same `'swapItems'`-with-`toType == 'drop'` vocabulary this callback
-- already expects -- `payload.toType` and `payload.source` (the only two
-- fields this callback body reads) are both genuinely populated for a real
-- qb-inventory ground drop now, so the `if payload.toType ~= 'drop' then
-- return end` guard below is reached for real, and scent tracking is a
-- real, working feature on qb-inventory, not merely a disclosed gap.
--
-- The one residual degrade left to disclose: if qb-inventory's own
-- `AddHook('ItemDropped', ...)` registration specifically fails while the
-- unrelated `AddHook('ItemAdded', ...)` veto registration succeeds -- a REAL
-- possibility, not merely a hypothetical one: fxmanifest.lua's
-- `dependencies` mechanism has no version-constraint syntax, so an operator
-- could genuinely be running an older qb-inventory build (or a fork) that
-- predates `Events.ItemDropped` while still having `Events.ItemAdded` --
-- `RegisterHook` still returns `true` here (the capability this feature does
-- NOT depend on keeps working) -- shared/compat/inventory.lua's own adapter
-- prints a dedicated, one-time warning for exactly that narrower case, so it
-- is still never a silent gap even then; this call site needs no
-- separate handling for it.
local function RegisterScentInventoryHook()
    if not Config.Features.ScentTracking then return end -- nothing to gate for; do not probe/warn about a disabled-by-default feature

    local registered = K9Compat.Get('inventory').RegisterHook('swapItems', function(payload)
        if payload.toType ~= 'drop' then return end -- only a ground-drop counts as a scent source; trunk/stash/give moves are not

        -- payload.source must be a real number before it is used as a cooldown
        -- KEY. Not defensive padding: the qb-inventory adapter's ItemAdded
        -- translation hardcodes `source = nil` (that event genuinely does not
        -- carry one), and its toType vocabulary is documented as unconfirmed --
        -- so if that backend ever reports toType == 'drop' via ItemAdded, this
        -- reached Consume(nil, ...) -> Touch(nil) -> `store[nil] = now`, which
        -- is a hard "table index is nil" error. It was swallowed by the
        -- adapter's own pcall, so it failed safe and vetoed nothing, but it
        -- silently dropped the scent observation AND hid a real Lua error from
        -- the operator -- the worst combination for diagnosing why tracking is
        -- missing drops on that backend. Found by a red-team pass over the
        -- ItemDropped hook, 2026-08-26.
        if type(payload.source) ~= 'number' then return end

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
            coords = GetEntityCoords(ped), -- the DROPPING PLAYER'S OWN live position — NEVER ox_inventory's internal/eventual drop-inventory .coords (not yet created at this point in ox_inventory's own dropItem flow anyway, per DEVELOPER_REFERENCE.md#scent-source-resolution §2) and NEVER anything client-supplied
            loggedAt = GetGameTimer(),
            ticketIssued = false, -- ANTI-FARM FIX (this pass) — see findTrackableSource's own comment on this field for the full writeup
        }
    end)

    if not registered then
        print('[qbx_k9unit] WARNING: Config.Features.ScentTracking is enabled but ' ..
            'no compatible inventory backend hook registration succeeded (see /k9compat, if ' ..
            'enabled, for exactly why) -- scent tracking disabled. No scent sources will ever be ' ..
            'logged; findTrackableSource(\'scent\') will always report found = false.')
    end
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
--
-- COMPAT-LAYER MIGRATION (this pass): branch 2's condition used to hardcode
-- `resourceName == 'ox_inventory'` -- now asks K9Compat itself which
-- resource actually backs the 'inventory' system, same pattern
-- server/inventory.lua's own RegisterK9InventoryItemFilterHook dispatch and
-- client/inventory.lua's own RegisterK9InventoryOxTargetOption dispatch
-- already establish for this exact class of gap. `K9Compat.Redetect()` is
-- forced here (not relying on shared/compat/core.lua's own onResourceStart
-- redetect hook having already run for this SAME event) for the same
-- "correct regardless of relative handler-registration order" reason those
-- two call sites give. Hardcoding 'ox_inventory' here would have silently
-- reopened exactly the single-backend gap this whole pass exists to close.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterScentInventoryHook()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('inventory') then
        RegisterScentInventoryHook()
    end
end)

-- ======================================================================
-- PER-PERSON FEATURE CONTROL (Config.FeatureControl -- config.lua's own
-- header documents the 4-step resolution; step 1, Config.Features.<Type>,
-- is checked separately below before this function is ever reached).
-- Mirrors server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId
-- shape verbatim (that file's own header says to read it before writing
-- another variant) -- parameterized by featureName here since this file
-- gates THREE independent Config.Features flags (ScentTracking/
-- BloodTracking/GunpowderSniffing) through the identical shape, one call
-- site each, rather than three near-duplicate functions.
--
-- SCOPE, DELIBERATE: this gates ONLY the QUERY side (findTrackableSource
-- below -- the "use the ability" entry point a K9 actually presses a
-- button for). It does NOT gate relayDamageEvent/relayWeaponFire (blood/
-- gunpowder CAPTURE) or the 'swapItems' ox_inventory hook (scent CAPTURE)
-- above -- those log an AMBIENT world event (a victim taking damage, a
-- shooter firing, an item hitting the ground) keyed by WHOEVER caused it,
-- not by the K9 who might later search for it. Gating capture on a
-- searching K9's own block/grant status would be a category error (the
-- reporting party is frequently a suspect, never the K9 in question), and
-- for gunpowder specifically this was examined and deliberately rejected
-- today: gating capture would stop logging shots fired by exactly the
-- people this feature exists to track, defeating the feature for every K9
-- who might legitimately search that log later, blocked or not. See
-- tests/tracking_spec.lua's regression coverage asserting capture stays
-- ungated.
--- @param citizenid string
--- @param featureName string -- exact Config.Features key: 'ScentTracking' | 'BloodTracking' | 'GunpowderSniffing'
--- @return boolean allowed
local function IsTrackingFeaturePermittedForCitizenId(citizenid, featureName)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.' .. featureName) == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant[featureName] == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.' .. featureName) == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- DEVELOPER_REFERENCE.md §11.4 item 1. Resolves the nearest trackable source of
--- `trackType` for the CALLING K9's own live server-side position.
--- Validation order (cheapest/most-defensive checks first, same discipline
--- DEVELOPER_REFERENCE.md#contraband-search §3 establishes for the
--- higher-stakes searchTarget callback in server/search.lua — applied here
--- too even though the stakes are lower, since this reveal is
--- client-cosmetic only, no real capability granted, per DEVELOPER_REFERENCE.md §11.6's
--- own framing):
---   1. Payload-shape / trackType validity.
---   2. Config.Features.<Type> — real server-side no-op regardless of
---      client UI state.
---   3. HasK9Access(source).
---   3b. PER-PERSON FEATURE CONTROL (IsTrackingFeaturePermittedForCitizenId
---      above) -- checked BEFORE the cooldown below is ever consumed, so a
---      blocked/not-yet-granted K9 never burns their own query cooldown on
---      a request that was always going to be refused.
---   4. Per-(source, trackType) cooldown — stamped BEFORE any lookup work
---      below, mirroring the ordering fix DEVELOPER_REFERENCE.md#contraband-search §3
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
---     DEVELOPER_REFERENCE.md#tracking §2.4 flags this as a small,
---     genuinely open UX question, not decided here. This implementation
---     collapses all three into a bare `{ found = false }`, matching the
---     signature DEVELOPER_REFERENCE.md §11.4 item 1 actually specifies.
---   - Whether an in-progress tracking session should auto-cancel on
---     mid-session loss of K9 access (mirroring
---     ForceDetachLeashForSource's precedent for leash) —
---     DEVELOPER_REFERENCE.md#tracking §5 item 4 flags this as
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

    -- PER-PERSON FEATURE CONTROL -- see IsTrackingFeaturePermittedForCitizenId
    -- above for the full 4-step resolution and why this gates the QUERY only,
    -- never blood/gunpowder/scent CAPTURE. Deliberately BEFORE the cooldown
    -- consume just below -- a block must never burn a cooldown slot.
    local trackerPlayerForPermission = exports.qbx_core:GetPlayer(source)
    local trackerCitizenidForPermission = trackerPlayerForPermission and trackerPlayerForPermission.PlayerData
        and trackerPlayerForPermission.PlayerData.citizenid
    if not trackerCitizenidForPermission
        or not IsTrackingFeaturePermittedForCitizenId(trackerCitizenidForPermission, TRACK_TYPE_FEATURE_FLAGS[trackType]) then
        return { found = false } -- same bare, reasonless shape every other denial in this callback already uses (§11.4 item 1's own signature has no reason field)
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

    -- PHASE 4 ADDITION (coder-backend, XPProgression pass, DEVELOPER_REFERENCE.md
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
    if Config.Features.XPProgression then
        local trackerPlayer = exports.qbx_core:GetPlayer(source)
        local trackerCitizenid = trackerPlayer and trackerPlayer.PlayerData and trackerPlayer.PlayerData.citizenid
        if trackerCitizenid then
            -- INDIVIDUAL-OVERRIDE FIX (this pass, coder-backend) -- see
            -- server/k9profiles.lua's own header, "INTEGRATION HANDOFF", for
            -- the exact one-line gap this closes: this branch used to read
            -- GetXPTier(trackerCitizenid).scentRangeMultiplier RAW, so a
            -- per-K9 individual override on scentRangeMultiplier
            -- (server/k9profiles.lua's k9ProfileUpsert) was stored, audited,
            -- and even shown back to the operator through k9ProfileGet's own
            -- `effective` field, but THIS FILE -- the one real server-side
            -- consumer of scentRangeMultiplier for an actual detection-range
            -- calculation -- never read it, so the override had literally
            -- zero effect on live behavior. FIXED by resolving through
            -- GetK9EffectiveMultipliers (server/k9profiles.lua), the SAME
            -- single seam server/progression.lua's own
            -- GetXPTierMedkitCooldownMs already calls for the sibling
            -- medkit-cooldown field -- never GetXPTier directly when an
            -- override might apply, per that file's own resolution-order
            -- contract (GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE).
            -- Not a fourth ladder and not a re-implementation of that
            -- composition -- this is the one call into it.
            --
            -- Soft dependency, this resource's established `type(...) ==
            -- 'function'` convention: server/tracking.lua loads BEFORE
            -- server/k9profiles.lua in fxmanifest.lua's server_scripts list,
            -- but this call happens at CALLBACK-INVOCATION time, long after
            -- every server_scripts file has already finished loading -- no
            -- load-order assumption either way. Falls back to a direct
            -- GetXPTier read (the file's ORIGINAL behavior, pcall-free
            -- because GetXPTier itself never yields/throws for a valid
            -- citizenid) when GetK9EffectiveMultipliers is unavailable (an
            -- install that predates server/k9profiles.lua, or one that had
            -- it removed), so this file works identically whether or not
            -- that file happens to be present.
            local scentRangeMultiplier
            if type(GetK9EffectiveMultipliers) == 'function' then
                local ok, effective = pcall(GetK9EffectiveMultipliers, trackerCitizenid)
                if ok and type(effective) == 'table' and type(effective.scentRangeMultiplier) == 'number' then
                    scentRangeMultiplier = effective.scentRangeMultiplier
                end
            end
            if scentRangeMultiplier == nil and type(GetXPTier) == 'function' then
                local tier = GetXPTier(trackerCitizenid)
                if tier and type(tier.scentRangeMultiplier) == 'number' then
                    scentRangeMultiplier = tier.scentRangeMultiplier
                end
            end
            if type(scentRangeMultiplier) == 'number' and scentRangeMultiplier > 1.0 then
                maxRange = trackingConfig.maxRange * scentRangeMultiplier
            end
        end
    end

    local sourceCoords

    -- 'scent' / 'blood' / 'gunpowder': nearest still-fresh logged entry
    -- within maxRange. UPDATED THIS PASS (DEVELOPER_REFERENCE.md §9 items 11/17,
    -- DEVELOPER_REFERENCE.md#scent-source-resolution §4): 'scent' no longer
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
    -- when the feature is enabled, per DEVELOPER_REFERENCE.md §3's "read the flag at the
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
        -- Informational only (DEVELOPER_REFERENCE.md#tracking
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
-- DELIBERATELY NOT RE-CHECKED against IsTrackingFeaturePermittedForCitizenId
-- here: the block/grant gate is the ENTRY POINT (findTrackableSource above,
-- where the ticket was minted) -- by the time a K9 is walking toward an
-- already-resolved, already-authorized source, they hold a ticket earned
-- fair and square. Re-checking here would gate the SYMPTOM (claiming an
-- already-earned reward) rather than the entry point, and would strand a K9
-- who was blocked one tick after a legitimate find, with real travel already
-- spent, out of an XP award they had already qualified for -- the same
-- "no unbounded trap" reasoning this resource applies to termination paths,
-- applied here to an in-flight reward instead.
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
-- DEVELOPER_REFERENCE.md item 1: TrackQueryCooldown/DamageRelayCooldown/
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
-- ======================================================================
-- SCENT VISION (Config.Features.ScentVision) -- owner-directed pass: "make
-- scent tracking... a keybind that makes a colour dot appear where players['
-- ] blood etc have walked and have a delay before the scent markers go
-- away... if multiple people, multiple different colours... to
-- differentiate smells." Coordinator follow-ups (verbatim, folded into this
-- design as it evolved): "person" (colour is per PERSON, never per
-- permission -- that reading was raised and explicitly closed); "big
-- population... won't cause an issue" (bounded capture, bounded reveal, no
-- server-wide broadcast); "handful near the dog" / "they go away after 45
-- seconds" (colours scoped to a small proximity-ranked set, 45s default dot
-- lifetime); "diffrent dots will be all seprate timers... slowly go away"
-- (EACH DOT expires on its OWN individual timer from its OWN capture time --
-- never one shared trail-wide clock).
--
-- WHAT THIS IS, AND IS NOT, RELATIVE TO THE REST OF THIS FILE: Track
-- Scent/Blood/Gunpowder above (findTrackableSource) resolve and reveal
-- exactly ONE nearest logged EVENT (a damage hit, a gunshot, an item drop)
-- and hand the client a coordinate to walk toward. ScentVision instead
-- reveals SEVERAL people's own recent walked PATHS at once, colour-coded so
-- more than one trail through the same ground can be told apart -- a
-- different SHAPE of reveal, built on a NEW, separate capture stream
-- (PositionTrail below), not on TrackableLog. Kept separate deliberately:
-- TrackableLog's own anti-farm ticket-minting machinery (ticketIssued,
-- MIN_TRACK_XP_DISTANCE, TrackTicketMintCooldown, ...) exists entirely to
-- guard trackSourceResolved XP, which ScentVision never awards (this
-- feature mints ZERO XP, same "cosmetic reveal, no real capability granted"
-- framing DEVELOPER_REFERENCE.md §11.6 already established for the three trail types
-- above) -- entangling a brand-new, always-on, population-wide capture
-- stream with that machinery would have changed its risk profile for no
-- reason. This does mean an existing K9 handler's own recent
-- blood/gunpowder/scent-drop TrackableLog events are NOT folded in as extra
-- ScentVision dots this pass -- a disclosed, deliberate scope decision (see
-- this pass's own report), not an oversight; nothing here prevents adding
-- that later as a genuinely separate, additive reveal source.
--
-- SCALE, WORKED OUT, NOT ASSUMED (owner's own explicit requirement: this
-- must stay smooth on a populated server) -- full arithmetic in this pass's
-- own report; summarised at each bound below:
--   - CAPTURE cost: one GetPlayerPed+GetEntityCoords pair per CONNECTED
--     player, once per sampleIntervalMs (4s shipped) -- at 200 concurrent
--     players that is 50 native-call-pairs/sec, the same shape and order of
--     magnitude as this file's own pre-existing GetPlayers() population
--     scans (server/entities.lua's ResolveConnectedPlayerFromPed) and
--     server/wellbeing.lua's GetAllObjects/GetAllVehicles scans -- nothing
--     new in KIND, only in cadence.
--   - STORAGE ceiling: maxPointsPerPerson (15 shipped) is a HARD cap,
--     independent of dotLifetimeMs/sampleIntervalMs math, enforced on every
--     write (oldest evicted first) -- so total stored points can never
--     exceed connectedPlayers x maxPointsPerPerson regardless of how the
--     other two are configured. Each point is a 4-number array-style table
--     ({x, y, z, loggedAt}, never string-keyed) -- a conservative ~150
--     bytes/point estimate (a reasoned order-of-magnitude figure, NOT
--     profiled against a live FXServer's real Lua 5.4 allocator this pass --
--     disclosed as an estimate, not measured) puts 200 players x 15 points
--     x 150 bytes at roughly 440KB, and even FiveM's documented 1024-slot
--     hard ceiling x 15 x 150 bytes at roughly 2.2MB -- trivial against a
--     real server's memory budget either way, and a number the owner can
--     lower further via maxPointsPerPerson/dotLifetimeMs if a real profile
--     ever disagrees. DISCARDED ON WRITE (every capture pass drops that
--     SAME person's already-expired points before appending a new one, per
--     each point's OWN loggedAt timestamp -- never a decremented countdown)
--     -- never accumulated indefinitely and filtered only at query time; the
--     sweep thread below additionally catches a person who stops moving
--     (and so stops triggering that on-write sweep) on its own periodic
--     cadence.
--   - REVEAL cost: a query scans PositionTrail once (O(connectedPlayers x
--     maxPointsPerPerson) point-distance checks -- 200 x 15 = 3,000 at the
--     shipped defaults, microseconds of Lua work), then returns AT MOST
--     maxVisibleTrails (5, "a handful", the owner's own word) distinct
--     people's trails, each capped at queryMaxPointsPerTrail (12) points,
--     nearest-first -- so the PAYLOAD sent to any one client, and the
--     number of dots that client ever has to draw, is bounded at 60 points
--     REGARDLESS of server population. Degradation under load always drops
--     the FURTHEST trail/point first, per the owner's own instruction, at
--     both the trail-selection and per-trail-point levels below.
--   - COLOUR SPACE: exactly `maxVisibleTrails` (5) fixed, curated swatches
--     (Config.Tracking.ScentVision.palette), one per "handful" slot -- see
--     ResolveScentVisionColors below for why scoping colours to this same
--     small, proximity-ranked visible set (never the server's whole
--     population) makes a colour COLLISION between two SIMULTANEOUSLY SHOWN
--     trails structurally impossible, not merely statistically unlikely.
--
-- TRUST BOUNDARY: every point returned by getScentVisionPoints below is
-- this SERVER's own resolved position for some OTHER connected player,
-- gathered by this file's own capture thread -- never a client-supplied
-- coordinate, and never a coordinate for anyone outside the caller's own
-- queryRangeMeters/maxVisibleTrails/queryMaxPointsPerTrail limits. A client
-- is never handed the whole server's positions, and never learns WHO a dot
-- belongs to (no citizenid/name/source is ever put on the wire) -- only
-- WHERE, and which of its own "handful" colours that trail currently holds.
-- ======================================================================

-- Load-time sanity check -- see `palette`'s own config.lua comment for what
-- happens if it is shorter than maxVisibleTrails (colour REUSE across two
-- simultaneously-visible trails -- the one case this design cannot make
-- structurally impossible, since there are only as many fixed swatches as
-- the operator configured).
do
    local svConfig = Config.Tracking.ScentVision
    if type(svConfig) == 'table' then
        local paletteLen = type(svConfig.palette) == 'table' and #svConfig.palette or 0
        local wantSlots = type(svConfig.maxVisibleTrails) == 'number' and svConfig.maxVisibleTrails or 0
        if paletteLen > 0 and wantSlots > paletteLen then
            print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.maxVisibleTrails (%s) exceeds ' ..
                'Config.Tracking.ScentVision.palette\'s length (%d) -- colours will be REUSED across ' ..
                'simultaneously-visible trails once more than %d distinct people are shown to the same K9 ' ..
                'at once. Add more palette entries or lower maxVisibleTrails to keep every visible trail a ' ..
                'genuinely distinct colour.'):format(tostring(wantSlots), paletteLen, paletteLen))
        end
    end
end

-- PositionTrail[source] = { {x, y, z, loggedAt}, ... } -- one array-style
-- (never string-keyed) table per CONNECTED player, oldest points evicted
-- first. TrackableLog above is the event-based cousin -- see this section's
-- own header for why the two are kept deliberately separate. Ephemeral,
-- in-memory only, cleared entirely on that source's own playerDropped (see
-- the bottom of this file) -- never persisted, same "live-session data, not
-- account data" posture TrackableLog's own header already documents for
-- itself.
local PositionTrail = {}

-- Per-OBSERVER (the QUERYING K9's own source) stable colour-slot
-- assignment. ScentVisionColorSlots[observerSource][slotIndex] =
-- targetSource -- see ResolveScentVisionColors below for the full stability
-- rule (owner's own words: "hold a colour stable for as long as that trail
-- stays in the visible set, reassign only when it drops out entirely").
-- Bounded at (connected observers) x maxVisibleTrails entries, trivial
-- regardless of population -- cleared on the OBSERVING source's own
-- playerDropped.
local ScentVisionColorSlots = {}

local ScentVisionQueryCooldown = NewCooldown()
ScentVisionQueryCooldown.RegisterPlayerDropped()

-- How often this thread merely re-checks Config.Features.ScentVision while
-- the feature is off -- cheap, matches client/tracking.lua's own
-- gunpowder-capture-thread idle-poll precedent for the identical
-- "always-existing thread, real work only while the flag is on" shape.
local SCENT_VISION_CAPTURE_IDLE_MS = 5000

--- Simple clamp-and-warn for a ScentVision numeric field that is NOT a
--- millisecond threshold (those go through ResolveConfiguredThresholdMs at
--- each of their own call sites below instead -- see server/cooldowns.lua's
--- own header for why that specific helper exists and is reused rather than
--- duplicated). This one is for a plain count/distance floor -- clamps and
--- warns once per bad read, never throws, same "clamp and warn, never
--- assert" posture this whole resource applies to every operator-editable
--- Config field (a bare assert here would kill every registration below it
--- for this file's whole uptime over one bad number in a 2,000+ line
--- config.lua).
--- @param configuredValue any
--- @param fallback number
--- @param minAllowed number
--- @param configKeyName string
--- @return number
local function ResolveScentVisionNumber(configuredValue, fallback, minAllowed, configKeyName)
    if type(configuredValue) == 'number' and configuredValue == configuredValue and configuredValue >= minAllowed then
        return configuredValue
    end
    print(('[qbx_k9unit] ScentVision: %s must be a number >= %s (found: %s) -- falling back to %s.')
        :format(configKeyName, tostring(minAllowed), tostring(configuredValue), tostring(fallback)))
    return fallback
end

--- Drops every already-expired point from `bucket` IN PLACE, evaluated
--- against EACH POINT'S OWN `loggedAt` timestamp compared to `now` -- never
--- a decremented per-frame countdown (owner's own explicit requirement: a
--- stutter, an alt-tab, or a paused resource must never stretch a 45s dot
--- into something longer). Used both at CAPTURE time (discard-on-write,
--- below) and by the periodic sweep thread further below (for a person who
--- has stopped moving and so stopped triggering the on-write sweep).
--- @param bucket table
--- @param now number
--- @param lifetimeMs number
local function DiscardExpiredScentVisionPoints(bucket, now, lifetimeMs)
    local i = 1
    while i <= #bucket do
        if (now - bucket[i][4]) >= lifetimeMs then
            table.remove(bucket, i) -- cheap: bucket is capped at maxPointsPerPerson (15 shipped), never a real hot-path array
        else
            i = i + 1
        end
    end
end

--- Records one fresh sample of `src`'s own live position, IF they have
--- moved far enough since their own last recorded point. DISCARD ON WRITE
--- (owner's own explicit instruction): every call first drops this SAME
--- person's already-expired points before deciding whether to append a new
--- one -- never accumulate-then-filter-only-at-read.
--- @param src number
--- @param coords vector3
--- @param now number
--- @param minMovement number
--- @param maxPoints number
--- @param lifetimeMs number
local function RecordScentVisionPoint(src, coords, now, minMovement, maxPoints, lifetimeMs)
    local bucket = PositionTrail[src]
    if not bucket then
        bucket = {}
        PositionTrail[src] = bucket
    end

    DiscardExpiredScentVisionPoints(bucket, now, lifetimeMs)

    local last = bucket[#bucket]
    if last then
        local dx, dy, dz = coords.x - last[1], coords.y - last[2], coords.z - last[3]
        if (dx * dx + dy * dy + dz * dz) < (minMovement * minMovement) then
            return -- hasn't moved far enough since their own last recorded point
        end
    end

    bucket[#bucket + 1] = { coords.x, coords.y, coords.z, now }

    -- Hard count ceiling, independent of the age-based discard above -- see
    -- this section's own header "STORAGE ceiling" note for why this is the
    -- number this pass's memory math is actually computed from.
    while #bucket > maxPoints do
        table.remove(bucket, 1)
    end
end

-- CAPTURE THREAD -- population-wide, unconditional while the feature flag
-- is on (mirrors this file's own established "capture is population-wide by
-- design" posture already documented above for blood/gunpowder/scent --
-- ScentVision is not a suspect-targeted mechanic, it is a general "who
-- walked through here" reveal). `Wait` is the FIRST statement of every pass
-- through this loop, matching PruneTrackableLogs' own thread above and this
-- resource's general sweep-thread convention.
CreateThread(function()
    while true do
        if Config.Features.ScentVision then
            local svConfig = Config.Tracking.ScentVision or {}
            local interval = ResolveConfiguredThresholdMs(svConfig.sampleIntervalMs, 4000, 'Config.Tracking.ScentVision.sampleIntervalMs')
            Wait(interval)

            local minMovement = ResolveScentVisionNumber(svConfig.minSampleMovementMeters, 2.0, 0.0, 'Config.Tracking.ScentVision.minSampleMovementMeters')
            local maxPoints = ResolveScentVisionNumber(svConfig.maxPointsPerPerson, 15, 1, 'Config.Tracking.ScentVision.maxPointsPerPerson')
            local lifetimeMs = ResolveConfiguredThresholdMs(svConfig.dotLifetimeMs, 45000, 'Config.Tracking.ScentVision.dotLifetimeMs')
            local now = GetGameTimer()

            for _, playerIdStr in ipairs(GetPlayers()) do
                local src = tonumber(playerIdStr)
                if src then
                    local ped = GetPlayerPed(src)
                    if ped ~= 0 then
                        RecordScentVisionPoint(src, GetEntityCoords(ped), now, minMovement, maxPoints, lifetimeMs)
                    end
                end
            end
        else
            Wait(SCENT_VISION_CAPTURE_IDLE_MS)
        end
    end
end)

--- Age-based sweep for PositionTrail, on its OWN independent thread/cadence
--- (TRACKABLE_LOG_PRUNE_INTERVAL_MS, the same interval PruneTrackableLogs'
--- own thread already uses above, reused here for consistency rather than
--- inventing a second magic number -- kept as a SEPARATE thread rather than
--- folded into that existing one so this section stays self-contained and
--- does not require editing that earlier, already-tested thread body).
--- Belt-and-suspenders alongside RecordScentVisionPoint's own
--- discard-on-write above, for a person who has stopped moving (and so
--- stopped triggering that on-write sweep) or disconnected without a clean
--- playerDropped firing for some reason. Drops the whole bucket once it
--- holds no remaining live points, so an idle/departed player's entry does
--- not linger in PositionTrail forever.
local function PruneScentVisionPoints()
    local svConfig = Config.Tracking.ScentVision or {}
    local lifetimeMs = ResolveConfiguredThresholdMs(svConfig.dotLifetimeMs, 45000, 'Config.Tracking.ScentVision.dotLifetimeMs')
    local now = GetGameTimer()

    for src, bucket in pairs(PositionTrail) do
        DiscardExpiredScentVisionPoints(bucket, now, lifetimeMs)
        if #bucket == 0 then
            PositionTrail[src] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(TRACKABLE_LOG_PRUNE_INTERVAL_MS)
        PruneScentVisionPoints()
    end
end)

--- @return table[] -- Config.Tracking.ScentVision.palette, defensively
--- defaulted to a single fallback swatch if config.lua's own array is
--- missing/empty (should never happen with a shipped config.lua -- see this
--- section's own load-time sanity check above for the "too SHORT" case,
--- which degrades to colour reuse rather than this near-impossible "empty"
--- case).
local function ResolveScentVisionPalette()
    local palette = Config.Tracking.ScentVision and Config.Tracking.ScentVision.palette
    if type(palette) == 'table' and #palette > 0 then
        return palette
    end
    return { { r = 255, g = 255, b = 255 } }
end

--- Resolves a STABLE colour for each entry in `visibleSources` (already
--- ranked nearest-first, length already capped at maxVisibleTrails by the
--- caller) for THIS ONE observer. Reuses `observerSource`'s own existing
--- slot for a trail that was already visible on that same observer's last
--- query; only hands out a fresh slot to a trail newly entering the visible
--- set; frees a slot the INSTANT its trail is no longer anywhere in the
--- current visible set -- never merely because it slipped a rank within it.
--- This is deliberately PER-OBSERVER state (two different K9s can, and
--- will, assign the same suspect two different colours, independently) and
--- deliberately PROXIMITY-scoped rather than a global per-citizenid hash --
--- see this section's own header for why: the owner's own resolution to
--- "colours only for a handful near the dog" is what makes a colour
--- COLLISION between two SIMULTANEOUSLY VISIBLE trails structurally
--- impossible (one fixed swatch per slot, and never more slots handed out
--- than `visibleSources` has entries), not merely statistically unlikely.
--- @param observerSource number
--- @param visibleSources number[]
--- @return table<number, table> colorBySource
local function ResolveScentVisionColors(observerSource, visibleSources)
    local palette = ResolveScentVisionPalette()

    local slots = ScentVisionColorSlots[observerSource]
    if not slots then
        slots = {}
        ScentVisionColorSlots[observerSource] = slots
    end

    local stillVisible = {}
    for _, src in ipairs(visibleSources) do stillVisible[src] = true end

    -- Free a slot ONLY when its trail has left the visible set ENTIRELY --
    -- owner's own explicit rule: never reassign merely because a trail's
    -- RANK moved within an already-visible set.
    for slotIndex, holder in pairs(slots) do
        if not stillVisible[holder] then
            slots[slotIndex] = nil
        end
    end

    local slotOfSource = {}
    for slotIndex, holder in pairs(slots) do
        slotOfSource[holder] = slotIndex
    end

    local colorBySource = {}
    local nextFreeSlot = 1
    for _, src in ipairs(visibleSources) do
        local slotIndex = slotOfSource[src]
        if not slotIndex then
            while slots[nextFreeSlot] ~= nil do
                nextFreeSlot = nextFreeSlot + 1
            end
            slotIndex = nextFreeSlot
            slots[slotIndex] = src
            slotOfSource[src] = slotIndex
        end
        colorBySource[src] = palette[((slotIndex - 1) % #palette) + 1]
    end

    return colorBySource
end

--- Owner-directed pass ("scent vision" keybind). Resolves the caller's own
--- live server position (never a client-supplied one) and returns AT MOST
--- Config.Tracking.ScentVision.maxVisibleTrails distinct OTHER connected
--- players' own recent walked-path points, nearest trail first, each
--- ALREADY coloured server-side (see ResolveScentVisionColors above) -- the
--- client never learns WHO a dot belongs to, never learns about anyone
--- outside range/the visible-set cap, and never receives the server's whole
--- population regardless of how many people are actually connected. See
--- this section's own header for the full per-query cost bound.
lib.callback.register('qbx_k9unit:server:getScentVisionPoints', function(source)
    if not Config.Features.ScentVision then return { points = {} } end
    if not HasK9Access(source) then return { points = {} } end

    -- PER-PERSON FEATURE CONTROL -- same shared 4-step resolution as
    -- Scent/Blood/Gunpowder above (IsTrackingFeaturePermittedForCitizenId),
    -- checked BEFORE the query cooldown below is ever consumed, same "a
    -- block must never burn a cooldown slot" ordering findTrackableSource
    -- already establishes.
    local callerPlayer = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = callerPlayer and callerPlayer.PlayerData and callerPlayer.PlayerData.citizenid
    if not callerCitizenid or not IsTrackingFeaturePermittedForCitizenId(callerCitizenid, 'ScentVision') then
        return { points = {} }
    end

    local svConfig = Config.Tracking.ScentVision or {}
    local now = GetGameTimer()
    local cooldownMs = ResolveConfiguredThresholdMs(svConfig.queryCooldownMs, 1000, 'Config.Tracking.ScentVision.queryCooldownMs')
    if not ScentVisionQueryCooldown.Consume(source, cooldownMs, now) then
        return { points = {} } -- rate-limited -- same bare, reasonless shape every other denial in this callback uses
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { points = {} } end
    local myCoords = GetEntityCoords(ped)

    local range = ResolveScentVisionNumber(svConfig.queryRangeMeters, 40.0, 1.0, 'Config.Tracking.ScentVision.queryRangeMeters')
    local rangeSq = range * range
    local lifetimeMs = ResolveConfiguredThresholdMs(svConfig.dotLifetimeMs, 45000, 'Config.Tracking.ScentVision.dotLifetimeMs')
    local maxVisible = ResolveScentVisionNumber(svConfig.maxVisibleTrails, 5, 1, 'Config.Tracking.ScentVision.maxVisibleTrails')
    local maxPerTrail = ResolveScentVisionNumber(svConfig.queryMaxPointsPerTrail, 12, 1, 'Config.Tracking.ScentVision.queryMaxPointsPerTrail')

    -- Rank every OTHER connected player with at least one still-live point
    -- in range by THAT trail's OWN nearest point -- never the caller's own
    -- trail (showing a K9 handler their own footprints is not useful; see
    -- this section's header).
    local ranked = {}
    for src, bucket in pairs(PositionTrail) do
        if src ~= source then
            local nearestDistSq
            for _, pt in ipairs(bucket) do
                if (now - pt[4]) < lifetimeMs then
                    local dx, dy, dz = pt[1] - myCoords.x, pt[2] - myCoords.y, pt[3] - myCoords.z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= rangeSq and (not nearestDistSq or distSq < nearestDistSq) then
                        nearestDistSq = distSq
                    end
                end
            end
            if nearestDistSq then
                ranked[#ranked + 1] = { src = src, distSq = nearestDistSq }
            end
        end
    end
    table.sort(ranked, function(a, b) return a.distSq < b.distSq end)

    -- DEGRADE RULE (owner's own explicit instruction): under load, drop the
    -- FURTHEST trail first -- `ranked` is already nearest-first, so simple
    -- truncation IS that rule.
    local visibleSources = {}
    for i = 1, math.min(#ranked, maxVisible) do
        visibleSources[#visibleSources + 1] = ranked[i].src
    end

    local colorBySource = ResolveScentVisionColors(source, visibleSources)

    local points = {}
    for _, src in ipairs(visibleSources) do
        local bucket = PositionTrail[src]
        local color = colorBySource[src]
        if bucket and color then
            -- Nearest-first WITHIN this one trail too, so a per-trail cap
            -- also drops the FURTHEST points of that one trail first.
            local trailPoints = {}
            for _, pt in ipairs(bucket) do
                local age = now - pt[4]
                if age < lifetimeMs then
                    local dx, dy, dz = pt[1] - myCoords.x, pt[2] - myCoords.y, pt[3] - myCoords.z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= rangeSq then
                        trailPoints[#trailPoints + 1] = { x = pt[1], y = pt[2], z = pt[3], ageMs = age, distSq = distSq }
                    end
                end
            end
            table.sort(trailPoints, function(a, b) return a.distSq < b.distSq end)

            for i = 1, math.min(#trailPoints, maxPerTrail) do
                local tp = trailPoints[i]
                points[#points + 1] = {
                    x = tp.x, y = tp.y, z = tp.z,
                    -- RELATIVE age, in milliseconds, as measured by THIS
                    -- SERVER's own clock at THIS instant -- never a raw
                    -- GetGameTimer() timestamp handed to the client. Server
                    -- and client each run their OWN independent
                    -- GetGameTimer() counter (process uptime, not a shared
                    -- wall clock), so sending a raw server timestamp for the
                    -- client to compare against its own GetGameTimer() would
                    -- be comparing two unrelated counters. The client instead
                    -- anchors this relative age to ITS OWN GetGameTimer() the
                    -- instant this response arrives and counts up locally
                    -- from there -- see client/tracking.lua's own comment on
                    -- this exact field for the receiving side.
                    ageMs = tp.ageMs,
                    r = color.r, g = color.g, b = color.b,
                }
            end
        end
    end

    return {
        points = points,
        -- Echoed back so the client fades/expires every point in THIS
        -- response against the SAME lifetime THIS SERVER actually enforced
        -- for it, rather than trusting its own possibly-stale local config
        -- copy -- informational/defense-in-depth, same posture
        -- findTrackableSource's own `breaksAtWater` field already documents
        -- for itself above.
        dotLifetimeMs = lifetimeMs,
    }
end)

AddEventHandler('playerDropped', function(_reason)
    local src = source
    PendingTrackArrival[src] = nil
    -- SCENT VISION cleanup -- see PositionTrail's/ScentVisionColorSlots' own
    -- declaration comments above. Clearing PositionTrail[src] here (rather
    -- than waiting for PruneScentVisionPoints' own periodic sweep) also
    -- means every OTHER observer's ResolveScentVisionColors call frees any
    -- slot this disconnecting player held on their own very next query --
    -- no special cross-observer cleanup is needed for that half, since a
    -- source with no PositionTrail entry can never again appear in a future
    -- query's `ranked` candidate list for anyone.
    PositionTrail[src] = nil
    ScentVisionColorSlots[src] = nil
end)
