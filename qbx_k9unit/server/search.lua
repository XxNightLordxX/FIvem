--[[
    qbx_k9unit/server/search.lua

    Phase 2 SCAFFOLD ONLY (coder-backend lens) — NOT final implementation
    and NOT wired into fxmanifest.lua yet. Written ahead of Phase 1's
    confirmation wave closing, per explicit work-ahead direction (safe to
    read/review, not safe to merge/enable blindly). Every function body
    below is a `-- TODO` stub citing the authoritative source for exactly
    what must go there — do not treat anything here as reviewed,
    security-checked, or mergeable as-is.

    THIS IS THE SECURITY-CRITICAL FILE OF PHASE 2, per SPEC.md §11.1
    sub-phase 2b ("this is also the piece coder-security should review
    first, per the task's explicit direction to confirm search results
    can't be client-claimed") and per phase2_notes/contraband_search_contract.md's
    own framing ("designing early because the trust boundary doesn't move
    even if config field names do"). Treat every TODO below as a hard
    requirement to satisfy before this file is considered done, not a
    suggestion — and get an explicit coder-security sign-off on the real
    implementation before it ships, the same standard
    server/certifications.lua's header already sets for §4's grant/revoke
    flow.

    Owns (SPEC.md §11.3's `server/search.lua` row): the
    `qbx_k9unit:server:searchTarget` callback — server-authoritative
    "search vehicle/person for contraband" (§6.3/§11.5), including the
    contraband-alert broadcast (§11.4 item 2, gated on
    Config.Features.ContrabandAlerts). New file, not folded into
    server/main.lua, for the SAME "real capability grant deserves the
    certification-file's level of scrutiny" reasoning §11.3 gives for
    splitting client/search.lua from client/tracking.lua by TRUST MODEL,
    not feature name: this file reads a target's REAL, live ox_inventory
    contents — the same category of real capability grant as
    server/certifications.lua's grant/revoke — whereas server/tracking.lua
    (this file's sibling) only ever reveals a client-cosmetic marker trail
    (SPEC.md §11.6, no real capability granted).

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE
    (read all three in full before writing real code — none of them are
    optional background):
    1. SPEC.md §11.4 item 2 (event/callback contract) and §11.5's
       "Search vehicle/person + contraband alert tiers" acceptance
       criteria — the base contract this file must satisfy.
    2. phase2_notes/contraband_search_contract.md — supplements §11.4/
       §11.5 with the exact server-authoritative validation order (its
       §3, 15 numbered steps — reproduced/renumbered as 17 steps in
       HandleSearchTarget's own doc comment below to fold in the security
       review's blocking additions inline, rather than as a separate
       pass), the REAL confirmed ox_inventory export surface (its §1 —
       `GetInventoryItems`, `GetInventory`, `GetItemCount`,
       `GetContainerFromSlot`, read against the actual
       overextended/ox_inventory source, not guessed), the mandatory
       container-recursion requirement (its §2), and the race-safe
       rate-limiting/mutex design (its §4).
    3. phase2_notes/contraband_search_security_review.md — reviews §11.4
       item 2 adversarially and lists BLOCKING findings (its §8 summary)
       that §11.4's own text does not state explicitly. Every blocking
       item there is treated as equal in authority to SPEC.md itself
       below, not as optional hardening:
         - Blocking: contraband alert broadcast must be DISTANCE-FILTERED,
           never a global `-1` broadcast like relayBark's (§1).
         - Blocking: broadcast payload carries `netId` + `alertTier`
           ONLY — never `totalWeight`/`contrabandFound` (§1).
         - Add a flat per-source cooldown on `searchTarget` (ANY target),
           independent of the existing per-(source, targetNetId) cooldown
           (§2).
         - Write the per-pair cooldown timestamp BEFORE the awaited
           ox_inventory read, not after (§3).
         - Cross-validate the resolved entity's REAL type against the
           claimed `targetType`; for 'person', confirm `IsPedAPlayer`-
           equivalent and a currently-connected player before treating it
           as searchable (§4).
         - Explicit, stated decision (not a silent default) on whether a
           per-target-ONLY backstop cooldown exists alongside the
           per-(K9, target) one (§5) — NOT resolved by this scaffold.
         - Nice-to-have: key the person-search cooldown by citizenid, not
           raw ped netId (§7).

    api-contract-agent's phase2_notes/EXPORT_TRACKING.md validation pass
    flags that an EARLIER draft of the security review proposed a
    competing two-event, tier-only-response shape that CONTRADICTS
    §11.4's single lib.callback / requester-gets-totalWeight shape. That
    contradiction is RESOLVED in this scaffold's EVENT/CALLBACK CONTRACT
    below in favor of §11.4's shape: one `lib.callback`
    (`searchTarget`), `totalWeight` returned to the REQUESTER only (never
    broadcast), tier-only for the broadcast-to-bystanders alert. This is
    the reconciliation EXPORT_TRACKING.md itself recommends — do not
    re-introduce the two-event shape without an explicit, separate
    decision to override this reconciliation.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2 scaffold, reconciled per the
    precedence list above. Identical in format to
    server/certifications.lua's contract block for the same
    parallel-work-without-live-coordination reason that file states.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:searchTarget' (targetType: 'vehicle'|'person', targetNetId: number)
       -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
       [THIS FILE]
       See HandleSearchTarget's own doc comment below for the full
       17-step validation order.

    Server events (RegisterNetEvent, client->server): none. This feature
    is entirely request/response shaped (SPEC.md §11.4 item 7's own
    reasoning for why lib.callback is the right fit for tracking-result
    delivery applies identically here) — there is deliberately no
    fire-and-forget "I searched" event.

    Client events (RegisterNetEvent, server->client):
    2. 'qbx_k9unit:client:playContrabandAlert' (netId: number, alertTier: string)
       [client/search.lua — NOT YET SCAFFOLDED as of this file] — the
       distance-filtered broadcast described in step 15 below. NOTE the
       DELIBERATE ABSENCE of `totalWeight`/`contrabandFound` in this
       payload — see the security review's blocking finding §1.
       NAMING NOTE: this exact event name is NOT locked anywhere in
       SPEC.md §11.4 or phase2_notes/EXPORT_TRACKING.md as of this
       scaffold — §11.4 item 2 only says the alert "triggers a broadcast
       ... the same way relayBark does" without naming the client-side
       event. Proposed here following this resource's own established
       naming convention (`qbx_k9unit:client:<verbNoun>`, camelCase) —
       confirm with whoever scaffolds client/search.lua before treating
       this as final, and update EXPORT_TRACKING.md's naming table once
       confirmed.

    Commands: none.

    Automatic path: none.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, resource-global from
      server/certifications.lua — reused, never re-derived, per that
      file's own "SINGLE source of truth" rule. Does NOT call
      `IsConfiguredK9Model` — a search requester's eligibility is pure
      job+certification (HasK9Access), same posture as
      server/tracking.lua's own FILE-TO-FILE CONTRACT note for the same
      reason.
    - THIS FILE exposes NO resource-global functions as of this scaffold.
      OPEN QUESTION (SPEC.md §11.3's own search.lua row): "consider
      exposing a small shared helper from server/main.lua if [relayBark's
      broadcast and this file's alert broadcast] end up wanting
      byte-identical broadcast logic" — NOT the case here, since the
      security review's blocking finding §1 requires THIS broadcast to be
      distance-filtered while relayBark's stays a raw `-1` broadcast (its
      payload is harmless server-wide, this one is not) — so the two are
      NOT byte-identical and should NOT naively share relayBark's helper
      as-is. Whether a NEW shared "distance-filtered broadcast" helper is
      worth factoring out (e.g. if server/main.lua's future
      relayDoorScratch ever wants the same targeted-audience treatment,
      per phase2_notes/EXPORT_TRACKING.md's own open item on door-scratch
      broadcast scope) is a judgment call for whoever writes the real
      body — not decided by this scaffold either way.
    - THIS FILE owns `SearchInFlight`, `lastSearchAt`, and
      `lastTargetSearchAt` below as file-local state — see each table's
      own doc comment for why each exists.
    ======================================================================
]]

-- In-flight mutex per source (contraband_search_contract.md §4A — "closes
-- the exact check-then-act race server/certifications.lua's DB
-- unique-index backstop exists to close for grant INSERTs, recurring here
-- in a different shape"). MUST be set synchronously, BEFORE any await,
-- checked as validation step 4 below, and cleared on EVERY exit path
-- (success, failure, AND error — the equivalent of a `finally`) so a
-- thrown error inside the ox_inventory call doesn't permanently wedge a
-- source out of ever searching again.
-- SearchInFlight[source] = true | nil
local SearchInFlight = {}

-- Flat per-source cooldown — BLOCKING per
-- contraband_search_security_review.md §2 ("nothing stops a single
-- source from searching many different targets back-to-back with zero
-- delay" — NOT present in SPEC.md §11.4's original text, which only
-- specifies a per-(source, target) cooldown). Recommended sizing: around
-- Config.SearchZones.sniffAnimDurationMs (that finding's own suggestion).
-- Mirrors BARK_COOLDOWN_MS/lastBarkAt's exact shape in server/main.lua.
-- lastSearchAt[source] = <GetGameTimer() ms>
local lastSearchAt = {}

-- Per-resolved-target cooldown backing Config.SearchZones.searchCooldownMs
-- (SPEC.md §11.4 item 2's originally-specified "per (source, targetNetId)
-- pair" cooldown) — REFINED per contraband_search_contract.md §4B to key
-- on the RESOLVED, STABLE identity (plate for vehicles; for persons,
-- prefer citizenid over raw server id per
-- contraband_search_security_review.md §7's "survives a ped-recreation
-- edge case" nice-to-have — TODO: confirm citizenid vs. targetServerId
-- before writing the real body), NOT the raw client-supplied
-- `targetNetId` (recyclable/spoofable-adjacent, per §4B's own reasoning).
-- Outlives any single player's connection (a plate persists after the
-- searching officer disconnects), so — unlike lastSearchAt/SearchInFlight
-- above, which clear on that source's own playerDropped — this table
-- needs its OWN independent TTL-based sweep so it doesn't grow unbounded
-- for the resource's lifetime (contraband_search_contract.md §4, mirrors
-- server/certifications.lua's own "regression-test fix" for its
-- citizenid-keyed cache's unbounded growth).
-- lastTargetSearchAt[<resolved identity string>] = <GetGameTimer() ms>
local lastTargetSearchAt = {}

--- TODO (contraband_search_contract.md §4 — "an independent TTL-based
--- sweep... so it doesn't grow unbounded for the lifetime of the
--- resource"): a CreateThread loop on a modest interval (e.g. every
--- 60-120s — exact interval not spec-mandated) that drops
--- `lastTargetSearchAt` entries older than some multiple of
--- Config.SearchZones.searchCooldownMs (an entry older than its own
--- cooldown window is by definition no longer doing any rate-limiting
--- work and is safe to drop). Not the same table as
--- server/tracking.lua's `TrackableLog` prune pass — do not merge the two
--- threads, they prune different, unrelated tables on different schedules
--- for different reasons.
local function PruneTargetSearchCooldowns()
    -- TODO: implementation — see doc comment above.
end

CreateThread(function()
    -- TODO: while true do PruneTargetSearchCooldowns(); Wait(<interval>) end
end)

--- SPEC.md §11.4 item 2 / contraband_search_contract.md §3. THE
--- security-critical callback of Phase 2 (SPEC.md §11.1 sub-phase 2b).
---
--- TODO: full body, validation order MATTERS — cheapest/most-defensive
--- checks first, expensive/leaky ones last (contract doc §3's own
--- framing; reordering "for convenience," e.g. moving the inventory read
--- before the proximity check, silently reopens the map-wide oracle
--- finding in step 8 below — this is, per the contract doc's own §6,
--- "the single most important ordering constraint in this whole
--- contract"). Exact steps, in order:
---   1. `type(targetType) ~= 'string'` or `targetType` not one of
---      `'vehicle'|'person'`, or `type(targetNetId) ~= 'number'` ->
---      `{ ok = false, reason = 'invalid_target' }`. Defensive
---      payload-shape check, same posture as relayBark's
---      `type(barkType) ~= 'string'` guard and
---      GrantCertification's `type(targetServerId) ~= 'number'` guard.
---   2. `not Config.Features.SearchZones` -> `{ ok = false, reason =
---      'feature_disabled' }`. Real server-side no-op regardless of
---      client UI state, per §3's cross-cutting acceptance criteria.
---   3. `not HasK9Access(source)` -> `{ ok = false, reason = 'no_access' }`.
---      Reuse the global from server/certifications.lua — do NOT
---      re-derive job/cert logic here.
---   4. `SearchInFlight[source]` already true -> `{ ok = false, reason =
---      'search_in_progress' }` (contract doc §4A) — reject outright,
---      do not queue or silently overwrite the in-flight call.
---   5. Cooldown check, BOTH halves:
---        (a) `lastSearchAt[source]` vs.
---            `Config.SearchZones.sniffAnimDurationMs` — BLOCKING per
---            security review §2, NOT present in §11.4's original text —
---            a flat per-source floor independent of which target is
---            named, closing the "sweep every vehicle in a parking lot
---            with zero delay" flood vector.
---        (b) `lastTargetSearchAt[<resolved identity>]` vs.
---            `Config.SearchZones.searchCooldownMs` — the
---            originally-specified per-(K9, target) cooldown (§11.4 item
---            2). NOTE: the resolved identity this half keys on isn't
---            known until step 10 below (plate/citizenid), so
---            IMPLEMENTATION-WISE this half of the check physically runs
---            AFTER entity resolution (steps 6-9) even though it's
---            listed here for logical grouping with (a) — mirrors
---            contract doc §3's own step 5 vs. step 9 structuring, don't
---            "fix" this into one single early check by keying on raw
---            `targetNetId` instead (that would reopen the exact
---            recycled-netId gap contract doc §4B warns against).
---      Either half failing -> `{ ok = false, reason = 'on_cooldown' }`.
---   6. Resolve `targetNetId` to a live entity:
---      `local entity = NetworkGetEntityFromNetworkId(targetNetId)`.
---      `entity == 0` -> `{ ok = false, reason = 'invalid_target' }`
---      (doesn't exist — despawned, garbage netId, or never existed).
---   7. Cross-check the resolved entity's REAL type against the CLAIMED
---      `targetType` — BLOCKING per security review §4, NOT explicit in
---      §11.4's own text: `GetEntityType(entity)` must be `2` (vehicle)
---      for `targetType == 'vehicle'`; or `1` (ped) AND
---      `NetworkGetPlayerIndexFromPed(entity) ~= -1` (a REAL, currently
---      connected player, never an NPC — SPEC.md §11.3's own "person"
---      search scoping is player-only) for `targetType == 'person'`.
---      Mismatch on either axis -> `{ ok = false, reason =
---      'invalid_target' }` — closes the spoofing angle where a client
---      sends `targetType = 'vehicle'` but a ped's netId (or vice versa)
---      to probe how a mismatched code path behaves.
---   8. MANDATORY, FIRST-CLASS live proximity check — distance between
---      `GetEntityCoords(GetPlayerPed(source))` and
---      `GetEntityCoords(entity)` must be `<=
---      Config.SearchZones.vehicleSearchDistance` or `.personSearchDistance`
---      as appropriate. THIS MUST RUN BEFORE ANY ox_inventory QUERY,
---      UNCONDITIONALLY (contract doc §3 step 8 / §6: "without this
---      check enforced first, a modified client could supply the netId
---      of ANY vehicle/player anywhere on the map and get back a real
---      contrabandFound/totalWeight result for it, turning the feature
---      into a server-wide 'scan any vehicle for drugs' oracle"). Too
---      far -> `{ ok = false, reason = 'too_far' }`.
---   9. NOW stamp BOTH cooldowns (`lastSearchAt[source]` and
---      `lastTargetSearchAt[<resolved identity>]`) — BEFORE the awaited
---      ox_inventory call in step 11, NOT after. BLOCKING per security
---      review §3 / contract doc §3 step 13's explicit ordering
---      requirement: writing the cooldown AFTER an awaited call leaves a
---      window where a second call for the same source/target can
---      interleave before the first stamps anything, causing a
---      double-search/double-broadcast. If the search is later rejected
---      for an unrelated reason (target vanished mid-await, etc.), that's
---      an acceptable minor false-positive on the cooldown — far smaller
---      than a double-search bypassing rate-limiting entirely.
---   10. Derive the real inventory id server-side ONLY now — NEVER
---       anything client-supplied: plate via
---       `GetVehicleNumberPlateText(entity)` for vehicles (inventory id
---       is literally `'trunk' .. plate`, confirmed against the real
---       overextended/ox_inventory source per contract doc §1); the
---       target's own live server id (and/or citizenid, per the
---       `lastTargetSearchAt` doc comment above) via
---       `GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))` for
---       persons.
---   11. Query contents via `exports.ox_inventory:GetInventoryItems(id)`
---       (confirmed real export, contract doc §1 — returns
---       `table<slot, ItemSlot>?`, `nil` if the inventory can't be
---       resolved/loaded), wrapped in `pcall`. LOAD-BEARING DETAIL
---       (contract doc §1): for an uncached vehicle trunk, ox_inventory
---       internally awaits its OWN `lib.callback.await('ox_inventory:getVehicleData', source, netid)`
---       against the ambient `source` of whatever coroutine is executing
---       — meaning this lookup MUST happen from WITHIN this callback's
---       own execution context (the one FiveM already set `source` to =
---       the requesting K9 player), never deferred to a different tick,
---       thread, or a helper called outside that context, or
---       ox_inventory's own internal callback has no valid client to ask
---       about the vehicle and the lazy load silently fails. A person's
---       own inventory needs no such lazy-load dance (already loaded
---       while they're online). A caught error or a `nil` result ->
---       `{ ok = false, reason = 'search_failed' }` — NEVER collapse this
---       into `contrabandFound = false` (contract doc §3 step 10 /
---       security review §6: "conflating 'we couldn't check' with 'we
---       checked and it's clean' is a correctness bug with real
---       in-fiction consequences," independent of exploitability).
---   12. RECURSE into every container slot (contract doc §2 — via
---       `GetContainerFromSlot(inv, slotId)`, confirmed real export) to
---       an EXPLICIT, chosen max depth (e.g. 3 — not unbounded, and not
---       skipped) and include nested `GetInventoryItems` results in the
---       same scan. THIS IS A MUST-HANDLE, NOT OPTIONAL POLISH — a naive
---       top-level-only scan will not match a bag's OWN item name against
---       `Config.SearchContrabandItems`, so "put the drugs in a bag"
---       becomes a trivial, realistic, fully-defeating bypass of the
---       entire feature if this step is skipped.
---   13. Sum `.weight` across every matching slot (top-level + recursed
---       containers) whose `.name` is in `Config.SearchContrabandItems`.
---       Per contract doc §1, `.weight` on each `ItemSlot` is ALREADY the
---       total weight for that slot (`item.weight * slot.count`, plus
---       adjustments) — do NOT re-multiply by `.count`, that would
---       double-count. This sum is `totalWeight`.
---       `contrabandFound = totalWeight > 0`.
---   14. Look up `alertTier` from `Config.ContrabandAlertTiers` (highest
---       `minWeight` not exceeding `totalWeight`). REQUIRES an explicit
---       baseline "clean" tier (e.g. `{ minWeight = 0, alert = 'clean' }`
---       as config.lua's first `Config.ContrabandAlertTiers` entry) to
---       already exist — contract doc §5 option (a), recommended there —
---       so a genuinely clean search has defined feedback rather than an
---       unhandled fallback case. `config.lua`'s CURRENT placeholder table
---       (per SPEC.md §5 / config.lua as of this scaffold) only defines
---       the two found-contraband tiers (`'whine'`, `'aggressive_bark'`)
---       — flag to coder-architect if that baseline tier hasn't landed
---       yet by the time this file is implemented for real; do NOT
---       hardcode a `'clean'` fallback string inside this file instead
---       (contract doc §5 option (b), explicitly the non-recommended
---       alternative).
---   15. If `Config.Features.ContrabandAlerts` and `alertTier` isn't the
---       `'clean'` case, broadcast the alert. BLOCKING per security
---       review §1: this broadcast MUST be DISTANCE-FILTERED — iterate
---       connected players server-side and `TriggerClientEvent` only to
---       those within some `Config.SearchZones`-driven audible radius of
---       the TARGET's live coordinates (computed server-side, same
---       live-position discipline as every other check above) — NEVER
---       reuse relayBark's raw `TriggerClientEvent(..., -1, ...)` shape
---       for this event, even though §11.3's own wording ("mirrors how
---       relayBark already broadcasts") reads as an instruction to copy
---       it literally. The payload must carry ONLY `netId` + `alertTier`
---       (whatever a client needs to pick a sound/animation) — NEVER
---       `totalWeight`, `contrabandFound`, or item identities, to any
---       client other than the requester (security review §1's
---       "Secondary, same root cause" finding — a "just pass the whole
---       result table into the broadcast for convenience" shortcut would
---       silently leak `totalWeight` server-wide to anyone running a
---       listener).
---   16. Return `{ ok = true, contrabandFound, totalWeight, alertTier }`
---       to the CALLER ONLY. This is the ONE place `totalWeight` is
---       allowed to appear (security review §6: "the requester gets the
---       real number... and that boundary only holds if the broadcast
---       path is actually distance-filtered and tier-only" — step 15
---       above is what makes that boundary hold). Applies identically
---       when `Config.Features.ContrabandAlerts == false`: per §11.5's
---       explicit acceptance bullet, a successful search STILL reports
---       `contrabandFound`/`totalWeight` to the requester even with
---       alerts off — that flag gates the broadcast in step 15, not the
---       requester's own result in this step.
---   17. Clear `SearchInFlight[source]` on EVERY exit path above,
---       including every early return in steps 1-9 and any pcall-caught
---       error path in step 11 (contract doc §4A's "finally" requirement)
---       — a thrown error must never permanently wedge a source out of
---       searching again.
---
--- STILL-OPEN, NOT DECIDED BY THIS SCAFFOLD (flag before finalizing —
--- pick one explicitly, do not let either fall out by accident):
---   - Per-target-ONLY backstop cooldown, independent of searcher
---     identity — security review §5: nothing currently stops MULTIPLE
---     distinct, legitimately certified K9 officers from re-probing the
---     SAME target back-to-back, since each individual searcher's own
---     per-pair cooldown (step 5b) is satisfied every time. Either answer
---     ("intended, multiple units working a scene should each be able to
---     search" vs. "add a lighter target-side floor") is defensible —
---     this scaffold does not pick one.
---   - Search action audit logging, mirroring `k9_certifications`' audit
---     trail (contract doc §6's last bullet) — open question for
---     coder-architect/db-schema, not resolved here.
---   - `citizenid` vs. raw `targetServerId` as the person-search cooldown
---     key (security review §7, nice-to-have, not blocking).
lib.callback.register('qbx_k9unit:server:searchTarget', function(source, targetType, targetNetId)
    -- TODO: see doc comment above for the full 17-step body.
    return { ok = false, reason = 'not_implemented' }
end)

--- Cleans up this file's per-SOURCE ephemeral state on disconnect (does
--- NOT touch `lastTargetSearchAt`, which is intentionally NOT keyed by
--- source — see that table's own doc comment on why it needs an
--- independent TTL sweep instead of playerDropped-based cleanup). Same
--- rationale as server/main.lua's playerDropped handler and
--- server/tracking.lua's own equivalent handler.
---
--- TODO: full body —
---   `SearchInFlight[src] = nil`
---   `lastSearchAt[src] = nil`
AddEventHandler('playerDropped', function(_reason)
    local src = source
    -- TODO: see doc comment above for the exact cleanup body.
end)
