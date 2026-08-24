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
    3. phase2_notes/scent_blood_tracking.md — client-logic-lens refinement
       of §11.4 items 1/3, plus two explicit "flag for coder-security"
       notes worth restating here since THIS file is where they land:
       (a) `findTrackableSource`'s signature must never grow a
       client-supplied coordinate parameter, (b) `relayDamageEvent` trusts
       the FACT of damage but never the reported location.
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
    9. phase2_notes/scent_source_resolution.md (tech-scout pass, same day)
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
    phase2_notes/scent_blood_tracking.md §3 item 2 already explicitly frame
    as acceptable-risk: tracking grants no real capability (SPEC.md §11.6),
    and "a false report just plants a harmless phantom blood-trail
    location" (scent_blood_tracking.md §3 item 2's own words, written
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

    ox_inventory hooks (exports.ox_inventory:registerHook, ox_inventory ->
    THIS FILE, server-to-server — added this pass, SPEC.md §9 items 11/17,
    phase2_notes/scent_source_resolution.md):
    4. 'swapItems' [THIS FILE]
       Registered once at file load. Fires synchronously, server-side,
       whenever ox_inventory processes ANY slot-to-slot item move —
       filtered here to `payload.toType == 'drop'` (a ground-drop) only.
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
      block and phase2_notes/EXPORT_TRACKING.md's function-name table.
    - THIS FILE also CONSUMES one export from ox_inventory (a dependency
      per fxmanifest.lua, already running by the time this file's file-load
      code executes) — `exports.ox_inventory:registerHook('swapItems', ...)`
      — added this pass. This is a one-way consumption (this file registers
      a callback ox_inventory invokes); THIS FILE still exposes nothing of
      its own for ox_inventory or any other resource to call.
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
      by phase2_notes/scent_source_resolution.md's confirmed
      registerHook-based design (see item 9 in this file's header
      AUTHORITATIVE SOURCES list) before it was ever built.
    - SCENT BRANCH STATUS, UPDATED THIS PASS: the ox_inventory
      `swapItems` hook is now confirmed (phase2_notes/scent_source_resolution.md,
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
-- this pass per phase2_notes/scent_source_resolution.md — see the
-- FILE-TO-FILE CONTRACT "STRUCTURAL NOTE, UPDATED THIS PASS" above for why
-- it's now structurally identical to blood/gunpowder rather than absent) —
-- NOT persisted, mirrors server/main.lua's `LeashPairs` precedent (SPEC.md
-- §10 flags this precedent as still needing db-schema's confirmation, not
-- assumed settled here).
-- TrackableLog[trackType][i] = { coords = vector3, loggedAt = <GetGameTimer() ms> }
-- trackType in {'scent', 'blood', 'gunpowder'}.
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

-- Per-source rate limit on the 'swapItems' ox_inventory hook below (added
-- this pass, SPEC.md §9 items 11/17, phase2_notes/scent_source_resolution.md).
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
--- phase2_notes/scent_blood_natives.md §0 — `data[1]` is the
--- cross-source-corroborated victim entity handle). Takes no meaningful
--- payload by design — do not add a coordinate argument later (see this
--- file's header FILE-TO-FILE CONTRACT / phase2_notes/scent_blood_tracking.md
--- §3 item 2's explicit warning that this is an easy regression).
---
--- CAVEAT (phase2_notes/scent_blood_natives.md §0): `CEventNetworkEntityDamage`
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
    }
end)

--- SPEC.md §11.4 item 4. Triggered by a client on a debounced local
--- false->true transition of IsPedShooting(PlayerPedId()) (confirmed
--- real, stable native — phase2_notes/scent_blood_natives.md §0 "adjacent
--- check", phase2_notes/water_gunpowder_natives.md §2 Option A). Takes no
--- meaningful payload — same "never trust a client-supplied coordinate"
--- rule as relayDamageEvent above.
---
--- NOTE: `IsPedShooting`'s exact per-round vs. per-burst semantics are
--- UNCONFIRMED this session (phase2_notes/water_gunpowder_tracking.md
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
    }
end)

--- SPEC.md §9 items 11/17. Registered once at file load (ox_inventory is a
--- hard `dependencies` entry in fxmanifest.lua, so it is already running by
--- the time this file's top-level code executes — same ordering guarantee
--- server/search.lua's own ox_inventory export calls already rely on).
--- Confirmed real mechanism, phase2_notes/scent_source_resolution.md §2/§4
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
--- phase2_notes/scent_source_resolution.md §2/§6): HIGH confidence the hook
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
exports.ox_inventory:registerHook('swapItems', function(payload)
    if not Config.Features.ScentTracking then return end -- real server-side no-op regardless of client UI state, per §3
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
        coords = GetEntityCoords(ped), -- the DROPPING PLAYER'S OWN live position — NEVER ox_inventory's internal/eventual drop-inventory .coords (not yet created at this point in ox_inventory's own dropItem flow anyway, per scent_source_resolution.md §2) and NEVER anything client-supplied
        loggedAt = GetGameTimer(),
    }
end)

--- SPEC.md §11.4 item 1. Resolves the nearest trackable source of
--- `trackType` for the CALLING K9's own live server-side position.
--- Validation order (cheapest/most-defensive checks first, same discipline
--- phase2_notes/contraband_search_contract.md §3 establishes for the
--- higher-stakes searchTarget callback in server/search.lua — applied here
--- too even though the stakes are lower, since this reveal is
--- client-cosmetic only, no real capability granted, per SPEC.md §11.6's
--- own framing):
---   1. Payload-shape / trackType validity.
---   2. Config.Features.<Type> — real server-side no-op regardless of
---      client UI state.
---   3. HasK9Access(source).
---   4. Per-(source, trackType) cooldown — stamped BEFORE any lookup work
---      below, mirroring the ordering fix contraband_search_contract.md §3
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
---     phase2_notes/scent_blood_tracking.md §2.4 flags this as a small,
---     genuinely open UX question, not decided here. This implementation
---     collapses all three into a bare `{ found = false }`, matching the
---     signature SPEC.md §11.4 item 1 actually specifies.
---   - Whether an in-progress tracking session should auto-cancel on
---     mid-session loss of K9 access (mirroring
---     ForceDetachLeashForSource's precedent for leash) —
---     phase2_notes/scent_blood_tracking.md §5 item 4 flags this as
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

    local sourceCoords

    -- 'scent' / 'blood' / 'gunpowder': nearest still-fresh logged entry
    -- within maxRange. UPDATED THIS PASS (SPEC.md §9 items 11/17,
    -- phase2_notes/scent_source_resolution.md §4): 'scent' no longer
    -- special-cases `sourceCoords = nil` — TrackableLog.scent is now fed by
    -- the 'swapItems' ox_inventory hook above, so it is scanned by this
    -- exact same loop, identically to blood/gunpowder. Discards entries
    -- already older than maxAgeSeconds even if PruneTrackableLogs hasn't
    -- swept them yet (belt-and-suspenders against a prune-timing gap, not a
    -- substitute for pruning).
    local maxAgeMs = trackingConfig.maxAgeSeconds * 1000
    local nearestDist

    for _, entry in ipairs(TrackableLog[trackType]) do
        if (now - entry.loggedAt) < maxAgeMs then
            local dist = #(myCoords - entry.coords)
            if dist <= trackingConfig.maxRange and (not nearestDist or dist < nearestDist) then
                nearestDist = dist
                sourceCoords = entry.coords
            end
        end
    end

    if not sourceCoords then
        return { found = false }
    end

    return {
        found = true,
        coords = sourceCoords,
        -- Informational only (phase2_notes/water_gunpowder_tracking.md
        -- §1.2) — config.lua is a shared_script so the client can already
        -- read Config.WaterTrackingDecay.breaksTrail directly; populate it
        -- anyway for future-proofing (e.g. a later per-type override).
        breaksAtWater = Config.WaterTrackingDecay.breaksTrail,
    }
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
