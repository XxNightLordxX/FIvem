--[[
    qbx_k9unit/server/tracking.lua

    Phase 2 SCAFFOLD ONLY (coder-backend lens) — NOT final implementation
    and NOT wired into fxmanifest.lua yet. Written ahead of Phase 1's
    confirmation wave closing, per explicit work-ahead direction (safe to
    read/review, not safe to merge/enable blindly). Every function body
    below is a `-- TODO` stub describing exactly what must go there and
    citing the authoritative SPEC.md section or phase2_notes/ file — do
    not treat any body here as reviewed, security-checked, or mergeable
    as-is. SPEC.md §11's own header note applies: re-check this scaffold's
    extension points against Phase 1's FINAL files (once that review gate
    actually closes) before writing real logic here, in case Phase 1
    review produced structural changes to server/certifications.lua or
    server/main.lua that this scaffold's FILE-TO-FILE CONTRACT below
    assumes are stable.

    Owns (SPEC.md §11.3's `server/tracking.lua` row): the event-relay log
    backing blood-trail and gunpowder-sniff (damage-event / weapon-fire
    coordinate capture, read server-side from the REPORTING CLIENT'S OWN
    live ped position, never a client-supplied coordinate — same
    "never trust client claims" standard server/certifications.lua's
    header already established for §4.3), a periodic prune pass dropping
    entries older than Config.Tracking.Blood/Gunpowder.maxAgeSeconds, and
    the `qbx_k9unit:server:findTrackableSource` callback that resolves the
    nearest matching source (scent/blood/gunpowder) within
    Config.Tracking.<Type>.maxRange of the calling K9's live server-side
    position. New file, not folded into server/main.lua or
    server/certifications.lua — unlike bark relay (stateless), this file
    owns real per-type state (growing/pruned event logs) large enough to
    warrant the same "don't let one file balloon" split
    server/certifications.lua's own header already establishes relative to
    server/main.lua.

    Ephemeral/in-memory only, deliberately not persisted — mirrors
    server/main.lua's `LeashPairs` precedent (both are live-session data,
    not account data). SPEC.md §10 flags this as still needing db-schema's
    confirmation that the precedent holds here too; not assumed settled by
    this scaffold.

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE:
    1. SPEC.md §11.4 items 1, 3, 4 (event/callback contract) and §11.5's
       "Scent tracking" / "Blood trail tracking" / "Gunpowder residue
       sniffing" / "Water tracking" acceptance criteria — the base
       contract.
    2. SPEC.md §11.6's reality-check refinements (gunpowder/blood relay is
       genuinely authored code, not free; scent's ox_inventory hook is
       unconfirmed).
    3. phase2_notes/scent_blood_tracking.md — client-logic-lens refinement
       of §11.4 items 1/3, plus two explicit "flag for coder-security"
       notes (§3 of that file) worth re-stating here since THIS file is
       where they land: (a) `findTrackableSource`'s signature must never
       grow a client-supplied coordinate parameter, (b) `relayDamageEvent`
       trusts the FACT of damage but never the reported location.
    4. phase2_notes/scent_blood_natives.md — confirms the
       `CEventNetworkEntityDamage` relay pattern is real and sound, but
       flags that it does NOT fire for script-applied damage (only organic
       gameplay damage) — a real, documented gap, not a bug to fix here.
    5. phase2_notes/water_gunpowder_tracking.md / water_gunpowder_natives.md
       — confirms `IsPedShooting` debounce is the right client-side
       trigger for gunpowder (this file only ever receives the resulting
       relay event, it does no shooting-detection itself), and that the
       water-crossing modifier is entirely a CLIENT-side concern
       (client/tracking.lua) — this file never needs to know about water.
    6. SPEC.md §9 items 10, 11, 14 — standing open questions touching this
       file specifically (relay-code effort is real authored work, not
       free; ox_inventory export for scent-source detection is
       UNCONFIRMED; whether tracking needs abuse-limits beyond the
       per-type cooldown is an explicit open judgment call, not decided
       here).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2 scaffold, per SPEC.md §11.4 items 1,
    3, 4. Identical in shape to server/certifications.lua's contract block
    so coder-backend/coder-frontend can work in parallel without live
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
       later, see phase2_notes/scent_blood_tracking.md §3 item 1).
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:relayDamageEvent' () [THIS FILE]
       Triggered by a client's own `gameEventTriggered('CEventNetworkEntityDamage', ...)`
       handler when the LOCAL PLAYER IS THE VICTIM (confirmed real pattern,
       phase2_notes/scent_blood_natives.md §0). Takes no meaningful
       payload — the server logs the reporting client's own live
       coordinates, never a client-supplied position, exactly like
       server/main.lua's relayBark "resolve the sender's own ped, don't
       trust a claimed netId" pattern.
    3. 'qbx_k9unit:server:relayWeaponFire' () [THIS FILE]
       Triggered by a client on a debounced local false->true transition
       of IsPedShooting(PlayerPedId()). Same "server logs the reporting
       client's own live coordinates" rule as event 2. Needs its OWN
       tight per-player rate limit, independent of and in addition to
       Config.Tracking.Gunpowder.searchCooldownMs — that config value is a
       QUERY-side cooldown (how often a K9 can re-run "Track Gunpowder");
       this is a LOGGING-side cooldown (how often a single shooter's fire
       events get recorded at all). Do not conflate the two.

    Client events (RegisterNetEvent, server->client): none from this file
    — per SPEC.md §11.4 item 7's own reasoning (already applied to
    Phase 1's `hasK9Access`), tracking-result delivery is
    request/response shaped, so `findTrackableSource` above being a
    lib.callback is sufficient; no fire-and-forget result event is needed.

    Commands: none.

    Automatic path: none — unlike server/certifications.lua's
    QBCore:Server:OnJobUpdate hook, nothing in this file runs outside a
    direct response to an explicit client-initiated event/callback above,
    plus the internal prune thread (self-scheduled, no external trigger).
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
      block and phase2_notes/EXPORT_TRACKING.md's function-name table.
    - THIS FILE owns `TrackableLog` (blood/gunpowder event log) and the
      cooldown tables below as file-local state. STRUCTURAL NOTE
      (mirrors server/certifications.lua's own "STRUCTURAL NOTE" pattern
      for `Certifications`): 'scent' intentionally has NO entry in
      `TrackableLog` — scent sourcing is a live query against
      ox_inventory drop data (or a client-reported candidate, per §9 item
      11's still-open fallback plan), not a server-side event log the way
      blood/gunpowder are. Do not add a `TrackableLog.scent` table by
      analogy without re-reading §11.6's actual design for scent first.
    ======================================================================
]]

-- Ephemeral, in-memory only per-type event log backing Blood/Gunpowder
-- tracking (SPEC.md §11.3, §11.4 items 3/4) — NOT persisted, mirrors
-- server/main.lua's `LeashPairs` precedent (SPEC.md §10 flags this
-- precedent as still needing db-schema's confirmation, not assumed
-- settled here).
-- TrackableLog[trackType][i] = { coords = vector3, loggedAt = <GetGameTimer() ms> }
-- trackType in {'blood', 'gunpowder'} only — see the FILE-TO-FILE
-- CONTRACT note above for why 'scent' deliberately has no entry here.
local TrackableLog = {
    blood = {},
    gunpowder = {},
}

-- Per-(source, trackType) QUERY-side cooldown backing
-- Config.Tracking.<Type>.searchCooldownMs (SPEC.md §11.4 item 1). Distinct
-- from the LOGGING-side rate limits below (relayDamageEvent/
-- relayWeaponFire) — this one throttles how often a K9 can re-run
-- "Track <Type>", not how often a shooter/victim's own client can report
-- a source event. LastTrackQueryAt[source] = { scent = ms?, blood = ms?,
-- gunpowder = ms? }.
local LastTrackQueryAt = {}

-- Per-source LOGGING-side rate limits (SPEC.md §11.4 items 3/4 — "needs
-- its own tight per-player rate limit... independent of, and in addition
-- to, Config.Tracking.Gunpowder's *search*-side cooldown, since this is a
-- *logging* cooldown, not a *query* cooldown"). No numeric default is
-- given anywhere in SPEC.md §11.2/config.lua for either of these — TODO:
-- pick and document a placeholder constant here (mirroring
-- BARK_COOLDOWN_MS's shape in server/main.lua) rather than leaving these
-- unbounded. Flagged as an explicitly open tuning question in
-- phase2_notes/water_gunpowder_tracking.md §3 item 3, not a spec mandate
-- for an exact number — do not invent one silently without a comment
-- explaining the choice.
local lastDamageRelayAt = {}
local lastWeaponFireRelayAt = {}

--- TODO (SPEC.md §11.4 items 3/4, "a periodic prune pass"): a CreateThread
--- loop, sleeping on an interval short enough that maxAgeSeconds stays a
--- meaningful bound (e.g. every 10-30s — exact interval is an
--- implementation detail, not a spec mandate) that walks
--- TrackableLog.blood and TrackableLog.gunpowder and removes any entry
--- whose `loggedAt` is older than Config.Tracking.Blood.maxAgeSeconds /
--- Config.Tracking.Gunpowder.maxAgeSeconds respectively (convert
--- GetGameTimer()'s millisecond timestamps against the config's
--- seconds-based thresholds consistently — do not mix units). Must not
--- block the main thread with a full-table rebuild if this ever grows
--- large — flag for resource-performance-profiler once real
--- entry-count numbers exist under load; a modest server is unlikely to
--- produce enough gunfire/damage events per maxAgeSeconds window for this
--- to matter, but that should be confirmed, not assumed.
local function PruneTrackableLogs()
    -- TODO: implementation — see doc comment above.
end

CreateThread(function()
    -- TODO: while true do PruneTrackableLogs(); Wait(<interval>) end —
    -- see PruneTrackableLogs' own doc comment for the interval tradeoff.
end)

--- SPEC.md §11.4 item 3. Triggered by a client's own `gameEventTriggered`
--- ('CEventNetworkEntityDamage') handler, filtered CLIENT-SIDE to "local
--- player is the victim" (confirmed real pattern,
--- phase2_notes/scent_blood_natives.md §0 — `data[1]` is the
--- cross-source-corroborated victim entity handle). Takes no meaningful
--- payload by design — do not add a coordinate argument later (see this
--- file's header FILE-TO-FILE CONTRACT / phase2_notes/scent_blood_tracking.md
--- §3 item 2's explicit warning that this is an easy regression).
---
--- TODO: full body —
---   1. `if not Config.Features.BloodTracking then return end` — silent
---      no-op, per SPEC.md §3's "disabled feature must be a no-op
---      server-side, not just hidden client-side" acceptance criterion.
---   2. Tight per-source LOGGING rate limit against lastDamageRelayAt
---      (see that table's own doc comment above for why this is a
---      SEPARATE cooldown from Config.Tracking.Blood.searchCooldownMs).
---      Silent no-op on rejection, mirroring relayBark's own
---      rate-limit-is-not-an-error posture in server/main.lua.
---   3. Resolve `source`'s own LIVE position via
---      GetEntityCoords(GetPlayerPed(source)) — NEVER a client-supplied
---      coordinate.
---   4. Append `{ coords = <resolved>, loggedAt = GetGameTimer() }` to
---      `TrackableLog.blood`.
--- CAVEAT to restate near the real body (phase2_notes/scent_blood_natives.md
--- §0): `CEventNetworkEntityDamage` does NOT fire for script-applied
--- damage (only organic gameplay damage — real weapon hits, falls,
--- vehicle impacts, melee). Not a bug to fix here, just a documented gap
--- worth one sentence so a future "why didn't blood tracking pick this
--- up" report isn't mysterious.
RegisterNetEvent('qbx_k9unit:server:relayDamageEvent', function()
    local src = source
    -- TODO: see doc comment above for the exact 4-step body.
end)

--- SPEC.md §11.4 item 4. Triggered by a client on a debounced local
--- false->true transition of IsPedShooting(PlayerPedId()) (confirmed
--- real, stable native — phase2_notes/scent_blood_natives.md §0 "adjacent
--- check", phase2_notes/water_gunpowder_natives.md §2 Option A). Takes no
--- meaningful payload — same "never trust a client-supplied coordinate"
--- rule as relayDamageEvent above.
---
--- TODO: full body —
---   1. `if not Config.Features.GunpowderSniffing then return end` —
---      silent no-op, per §3's acceptance criteria.
---   2. Tight per-source LOGGING rate limit against
---      lastWeaponFireRelayAt — SEPARATE from
---      Config.Tracking.Gunpowder.searchCooldownMs (§11.4 item 4's
---      explicit distinction). Sized conservatively: per
---      phase2_notes/water_gunpowder_tracking.md §2.3, `IsPedShooting`'s
---      exact per-round vs. per-burst semantics are UNCONFIRMED this
---      session — a high-fire-rate weapon could generate many debounced
---      transitions in a short window even with client-side debouncing,
---      so this server-side rate limit should not assume the client-side
---      debounce alone is sufficient.
---   3. Resolve `source`'s own LIVE position via
---      GetEntityCoords(GetPlayerPed(source)) — NEVER a client-supplied
---      coordinate.
---   4. Append `{ coords = <resolved>, loggedAt = GetGameTimer() }` to
---      `TrackableLog.gunpowder`.
RegisterNetEvent('qbx_k9unit:server:relayWeaponFire', function()
    local src = source
    -- TODO: see doc comment above for the exact 4-step body.
end)

--- SPEC.md §11.4 item 1. Resolves the nearest trackable source of
--- `trackType` for the CALLING K9's own live server-side position.
---
--- TODO: full body, validation order matters — cheapest/most-defensive
--- checks first (same discipline phase2_notes/contraband_search_contract.md
--- §3 establishes for the higher-stakes searchTarget callback in
--- server/search.lua; apply it here too even though the stakes are lower
--- — this reveal is client-cosmetic only, no real capability granted,
--- per SPEC.md §11.6's own framing, but "cheap checks first" is still the
--- right shape):
---   1. `type(trackType) ~= 'string'` or `trackType` not one of
---      `'scent'|'blood'|'gunpowder'` -> `{ found = false }`. Defensive
---      payload-shape check, same posture as every other event/callback
---      already shipped in this resource (e.g. relayBark's
---      `type(barkType) ~= 'string'` guard).
---   2. `not Config.Features[<matching flag>]` -> `{ found = false }`
---      (ScentTracking / BloodTracking / GunpowderSniffing, selected by
---      `trackType`) — real server-side no-op regardless of client UI
---      state, per §3's acceptance criteria applied identically here.
---   3. `not HasK9Access(source)` -> `{ found = false }`. Reuse the
---      global from server/certifications.lua — do NOT re-derive the
---      job/cert check here, per that file's own "SINGLE source of
---      truth" rule.
---   4. Cooldown check against `LastTrackQueryAt[source][trackType]` and
---      `Config.Tracking.<Type>.searchCooldownMs` -> `{ found = false }`
---      if still cooling down. Stamp the NEW timestamp before doing any
---      lookup work below, not after — mirrors the ordering fix
---      phase2_notes/contraband_search_contract.md §3 step 13 mandates
---      for searchTarget's cooldown-vs-await race; apply the same
---      discipline here if the 'scent' branch below ends up awaiting an
---      ox_inventory call (§9 item 11 — not yet confirmed either way).
---   5. Resolve the caller's own LIVE position via
---      GetEntityCoords(GetPlayerPed(source)) — never a client-supplied
---      coordinate (this callback's signature only takes `trackType`, no
---      coords parameter, BY DESIGN — do not add one later, per this
---      file's header FILE-TO-FILE CONTRACT).
---   6. Branch by `trackType`:
---      - 'scent': TODO (SPEC.md §9 item 11, §11.6) — resolve the
---        nearest configured scent source. The exact ox_inventory
---        hook/export for "an item was just dropped in the world at
---        coordinate X" is UNCONFIRMED this session. If no such hook
---        exists, §11.6's documented fallback is a CLIENT-side
---        world-entity proximity scan for ox_inventory's known drop
---        prop model/hash — which would change this branch's shape
---        entirely (the server would resolve/confirm a
---        client-nominated candidate rather than discovering one
---        itself). Do NOT guess at a specific export name here — confirm
---        against a live ox_inventory install before writing this branch
---        for real, same "confidence note, not asserted fact" posture
---        server/certifications.lua already uses for its own unverified
---        qbx_core export guesses.
---      - 'blood' / 'gunpowder': scan `TrackableLog[trackType]` for the
---        nearest entry to the resolved position within
---        `Config.Tracking.<Type>.maxRange`, discarding entries already
---        older than `maxAgeSeconds` even if `PruneTrackableLogs` hasn't
---        swept them yet (belt-and-suspenders against a prune-timing
---        gap, not a substitute for pruning).
---   7. `{ found = false }` if nothing resolved within `maxRange`;
---      otherwise `{ found = true, coords = <resolved source coords>,
---      breaksAtWater = Config.WaterTrackingDecay.breaksTrail }`. NOTE
---      (phase2_notes/water_gunpowder_tracking.md §1.2): `breaksAtWater`
---      is informational only — config.lua is a shared_script, so the
---      client can already read `Config.WaterTrackingDecay.breaksTrail`
---      directly without this field; it exists for future-proofing
---      (e.g. a later per-type/per-department override), not because the
---      client couldn't otherwise know it. Populate it anyway — do not
---      skip it just because it looks redundant today.
---
--- STILL-OPEN, NOT DECIDED BY THIS SCAFFOLD (flag before finalizing):
---   - §11 doesn't specify a distinguishing `reason` field for WHY
---     `found = false` (no source in range vs. on cooldown vs. no
---     access) — phase2_notes/scent_blood_tracking.md §2.4 flags this as
---     a small, genuinely open UX question, not decided here.
---   - Whether an in-progress tracking session should auto-cancel on
---     mid-session loss of K9 access (mirroring
---     ForceDetachLeashForSource's precedent for leash) —
---     phase2_notes/scent_blood_tracking.md §5 item 4 flags this as
---     lower-stakes than leash (cosmetic only) but explicitly undecided.
lib.callback.register('qbx_k9unit:server:findTrackableSource', function(source, trackType)
    -- TODO: see doc comment above for the full 7-step body.
    return { found = false }
end)

--- Cleans up this file's per-source ephemeral state on disconnect, same
--- rationale as server/main.lua's playerDropped handler (drop
--- cooldown-table entries so they don't leak one per session) and
--- server/certifications.lua's own "regression-test fix" for unbounded
--- per-citizenid cache growth.
---
--- TODO: full body —
---   `LastTrackQueryAt[src] = nil`
---   `lastDamageRelayAt[src] = nil`
---   `lastWeaponFireRelayAt[src] = nil`
--- `TrackableLog` itself needs NO per-source cleanup here — its entries
--- are keyed by coordinate/timestamp, not by the reporting source, and
--- are already pruned on their own maxAgeSeconds schedule regardless of
--- whether the original reporter is still connected.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    -- TODO: see doc comment above for the exact cleanup body.
end)
