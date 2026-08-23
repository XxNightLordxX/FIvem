# qbx_k9unit — Phase 2 Search/Contraband Server-Authoritative Contract

Status: design note only — **no `.lua` implementation here**. Written to lock
down the security-critical shape of `qbx_k9unit:server:searchTarget` ahead of
full Phase 2 implementation, per explicit direction that this piece is worth
designing early because the trust boundary doesn't move even if config field
names do.

**Alignment note (mid-task update):** while this note was being drafted,
`SPEC.md` gained a real §11 ("Phase 2 Detailed Spec", product-agent) that
already names this exact callback — `qbx_k9unit:server:searchTarget(targetType,
targetNetId) -> {ok, reason?, contrabandFound?, totalWeight?, alertTier?}`,
backed by `Config.SearchContrabandItems` (item-name list only, weight read
live from ox_inventory) and `Config.SearchZones.searchCooldownMs` — see
`SPEC.md` §11.2, §11.4 item 2, §11.5 "Search vehicle/person..." bullets. This
document does **not** invent a competing contract. It:

1. Confirms and pins down the exact ox_inventory export surface §11.6 flagged
   as "genuinely uncertain export names, not a feasibility blocker" (§9 item
   11) — resolved below by reading the real `overextended/ox_inventory`
   source (`main` branch), not guessed.
2. Fills in the operational detail SPEC §11 states as intent but doesn't
   spell out step-by-step: validation order, cooldown key shape, and the
   concurrent-call race that Phase 1's own `certifications.lua` already had
   to defend against once (the DB unique-index backstop) — the same class of
   bug recurs here without an async-safe design.
3. Surfaces one real gap SPEC §11 does not mention at all: **container
   recursion** (contraband hidden inside a backpack/bag placed in a searched
   trunk is invisible to a naive top-level inventory scan) — found while
   reading the real ox_inventory source, not a hypothetical.
4. Answers the task's explicit "what happens on zero contraband" question,
   which SPEC §11.5's acceptance bullets partially answer (the *requester*
   gets `contrabandFound = false` back) but don't fully close for the
   *broadcast* side.

Everything below should be read as "how `server/search.lua` must behave",
supplementing SPEC §11 rather than replacing it. Reconcile against SPEC.md
§11 directly if either drifts.

---

## 1. Real ox_inventory server-side API (confirmed against source)

Fetched and read directly from `overextended/ox_inventory@main` (not
assumed) — `server.lua`, `modules/inventory/server.lua`,
`modules/items/server.lua`, `modules/items/containers.lua`:

| Export | Signature | Behavior confirmed from source |
|---|---|---|
| `GetInventoryItems` | `(inv: string\|number, owner?: string\|number) -> table<slot, ItemSlot>?` | Thin wrapper around the internal `Inventory(inv)` lookup; returns the inventory's `.items` table keyed by slot number, or `nil` if the inventory can't be resolved/loaded. |
| `GetInventory` | `(inv, owner?) -> OxInventory\|false\|nil` | Same lookup, returns the full inventory object (`.items`, `.weight`, `.type`, `.id`, ...). |
| `GetItemCount` | `(inv, itemName, metadata?, strict?) -> number` | Sums `.count` across all slots whose `.name` matches, ignoring nested containers (see §3 below). |
| `GetContainerFromSlot` | `(inv, slotId) -> OxInventory?` | Resolves a container item's own nested inventory (e.g. a backpack's contents) — this is the export that makes container recursion possible; its existence is itself confirmation that top-level-only scanning is an intentional gap in ox_inventory's own design (containers are opaque at the parent level by design), not an oversight this resource can ignore. |

**Item slot shape**, confirmed from `Inventory.GetInventoryItems`'s
implementation (`modules/inventory/server.lua`, the loop building
`returnData`): each entry is
`{ name, label, weight, slot, count, description, metadata, stack, close }`.
Critically, **`.weight` here is already the total weight for that slot**
(`Inventory.SlotWeight(item, slot)` = `item.weight * slot.count`, plus any
weapon-component/ammo/metadata-weight adjustments), **not** a per-unit
weight. Summing `.weight` directly across matching slots gives the correct
total in the same units (grams-equivalent) `Config.ContrabandAlertTiers`'
`minWeight` thresholds are already expressed in — no unit conversion or
re-multiplication by `.count` needed, and doing so would double-count.

**Vehicle trunk inventory id.** Confirmed from `loadInventoryData` in
`modules/inventory/server.lua`: a vehicle's trunk inventory id is literally
`'trunk' .. plate` (glovebox is the `'glove...'` prefix family) — `data.id:sub(6)`
strips the 5-character `'trunk'` prefix to recover the plate. This means
`server/search.lua` must derive the plate **live, server-side**, via
`GetVehicleNumberPlateText(vehicleEntity)` on the entity resolved from the
(distance-checked) `targetNetId` — **never** accept a plate string from the
client. The resulting id is then just `('trunk%s'):format(plate)` passed
straight into `GetInventoryItems`.

**Load-bearing detail, not obvious from the export signature alone:** if the
trunk inventory isn't already cached (`Inventories[id]`), `Inventory()`
lazily loads it via `lib.callback.await('ox_inventory:getVehicleData', source,
netid)` — and that `source` is Lua's ambient global inside whatever coroutine
is executing, **not an explicit parameter you pass in**. This means
`server/search.lua`'s `searchTarget` callback must do this lookup **from
within its own callback/event execution context** (the one FiveM already set
`source` to = the requesting K9 player), not deferred to a different tick,
thread, or a helper called outside that context — otherwise ox_inventory's
own internal callback has no valid client to ask about the vehicle and the
lazy load silently fails. Document this coupling explicitly in
`server/search.lua`'s header when it's written; it's exactly the kind of
implicit-ambient-state gotcha that's invisible until it breaks intermittently
for cached-vs-uncached vehicles.

**Person inventory.** A connected player's own inventory is keyed by their
live numeric server id while online — `GetInventoryItems(targetServerId)`
resolves directly, no lazy-load/callback dance needed (unlike vehicles),
since ox_inventory already keeps an online player's own inventory loaded.

**No native "contraband" concept exists in ox_inventory** — confirmed by
searching the entire fetched source for the word; zero hits outside this
resource's own docs. `Config.SearchContrabandItems` (a flat item-name list,
per SPEC §11.2) is correctly the *only* source of truth for "what counts",
and per-unit weight must be read from ox_inventory's real item registry
(`exports.ox_inventory:Items(name).weight`, confirmed export) at query time —
SPEC §11.2 already states this "single source of truth, never duplicated"
principle; this section just confirms the concrete export that backs it.

---

## 2. Container recursion — a real gap, not covered by SPEC §11

`GetInventoryItems(inv)` only returns **top-level** slots. A container item
(backpack, duffel bag, evidence bag — anything registered via
`modules/items/containers.lua`'s container registry) appears in that result
as a single slot whose `.name` is the *container's* item name (e.g.
`'bag_normal'`), not the names of whatever is stashed inside it. Its `.weight`
field does roll up the *contents'* total weight (confirmed via
`Inventory.ContainerWeight`), but that weight is attributed to the container
slot as a whole — a naive
`for slot in items: if slot.name in ContrabandItems then sum += slot.weight`
scan **will not match a bag's own item name against
`Config.SearchContrabandItems`**, so contraband hidden inside any container
placed in a searched trunk/pocket is invisible to that scan even though
`GetContainerFromSlot(inv, slotId)` exists specifically to reach it.

This is a realistic, trivially-discoverable exploit if left unhandled: "put
the drugs in a bag" becomes a hard counter to the entire search mechanic.
**`server/search.lua` must recurse into any slot that is a registered
container** (check `slot.metadata.container` is present, or attempt
`GetContainerFromSlot`) and include its nested `GetInventoryItems` result in
the same contraband scan, to an implementer-chosen but *explicitly decided*
depth (unbounded nesting is theoretically possible — bag-in-a-bag — so pick a
max recursion depth, e.g. 3, and treat hitting the cap as "stop scanning
deeper, don't error" rather than an unbounded loop). This is flagged here as
a **must-handle**, not a nice-to-have — it's the single biggest way this
whole feature could ship "working" in the demo (loose contraband in a trunk)
and be trivially defeated in practice (contraband in a bag in the trunk).

Flag for coder-architect: this doesn't need a new config field (recursion is
a `server/search.lua` implementation detail), but it does mean "read the
target's real inventory contents" in SPEC §11.4 item 2 must be read as
"recursively", and that should be called out explicitly in that file's own
header comment once written, the same way this note calls it out.

---

## 3. Server-authoritative validation order (the actual contract)

`qbx_k9unit:server:searchTarget(targetType: 'vehicle'|'person', targetNetId:
number) -> { ok, reason?, contrabandFound?, totalWeight?, alertTier? }`,
registered via `lib.callback.register` (matches SPEC §11.4 item 2 and the
existing `hasK9Access` callback pattern in `server/certifications.lua`).

**Order matters — cheapest/most-defensive checks first, expensive/leaky ones
last:**

1. `type(targetType) ~= 'string'` or not one of `'vehicle'|'person'`, or
   `type(targetNetId) ~= 'number'` → `{ ok = false, reason = 'invalid_target' }`.
   Defensive payload-shape check, never trust the client sent what the
   signature implies (same posture as `relayBark`'s
   `type(barkType) ~= 'string'` guard and `GrantCertification`'s
   `type(targetServerId) ~= 'number'` guard).
2. `not Config.Features.SearchZones` → `{ ok = false, reason =
   'feature_disabled' }`. Must be a real server-side no-op regardless of
   client UI state, per §3's acceptance criteria applied identically here —
   SPEC §11.5's own bullet already states this for `SearchZones = false`.
3. `not HasK9Access(source)` → `{ ok = false, reason = 'no_access' }`. Reuse
   the existing global from `server/certifications.lua` — do **not**
   re-derive job/cert logic here, same rule as `relayBark` and
   `CheckLeashEligibility` already follow.
4. **In-flight mutex per source** (see §4 below) → if a search from this same
   `source` is already awaiting its own ox_inventory round trip,
   `{ ok = false, reason = 'search_in_progress' }`, reject outright rather
   than queueing or racing.
5. **Cooldown check** (see §4 below, both the per-source and the
   per-resolved-target keys) → `{ ok = false, reason = 'on_cooldown' }`.
6. Resolve `targetNetId` to a live entity: `local entity =
   NetworkGetEntityFromNetworkId(targetNetId)`. `entity == 0` →
   `{ ok = false, reason = 'invalid_target' }` (doesn't exist — despawned,
   garbage netId, or never existed).
7. **Verify the entity's real type independently of the client's
   `targetType` claim** — `GetEntityType(entity)` must be `2` (vehicle) for
   `targetType == 'vehicle'`, or `1` (ped) **and**
   `NetworkGetPlayerIndexFromPed(entity) ~= -1` (a real player-controlled
   ped, not an NPC — Phase 2's "person" search is player-only per SPEC
   §11.3's own scoping note) for `targetType == 'person'`. Mismatch on either
   axis → `{ ok = false, reason = 'invalid_target' }`. This closes a spoofing
   angle where a client sends `targetType = 'vehicle'` but a ped's netId (or
   vice versa) to probe how the mismatched code path behaves, or sends a
   real player's netId labeled `'vehicle'` to dodge whichever validation
   branch is presumed weaker.
8. **Live proximity check, mandatory and first-class** — distance between
   `GetEntityCoords(GetPlayerPed(source))` and `GetEntityCoords(entity)` must
   be `<= Config.SearchZones.vehicleSearchDistance` or
   `personSearchDistance` as appropriate. **This must run before any
   ox_inventory query, unconditionally.** The server always knows the live
   coordinates of any valid networked entity regardless of whether that
   entity happens to be streamed in for the *requesting* client — so without
   this check enforced first, a modified client could supply the netId of
   *any* vehicle/player anywhere on the map and get back a real
   `contrabandFound`/`totalWeight` result for it, turning the feature into a
   server-wide "scan any vehicle for drugs" oracle. Too far →
   `{ ok = false, reason = 'too_far' }`.
9. Derive the real inventory id server-side only now (plate via
   `GetVehicleNumberPlateText(entity)` for vehicles;
   `GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))` for persons) —
   never anything client-supplied.
10. Query contents (recursively, §2) via `GetInventoryItems`. Wrap in
    `pcall` — a lazily-loaded vehicle inventory can error on edge-case
    vehicle classes/timing (entity despawns mid-lookup, `ox_inventory:getVehicleData`
    callback to the client times out, etc.). A caught error or a `nil`
    result → `{ ok = false, reason = 'search_failed' }` — **never** collapse
    this into `contrabandFound = false`. Conflating "we couldn't check" with
    "we checked and it's clean" is a correctness bug with real in-fiction
    consequences (an officer relying on a false "clean" result), independent
    of whether it's separately exploitable.
11. Sum `.weight` across every matching slot (top-level + recursed
    containers, §2) whose `.name ∈ Config.SearchContrabandItems`. This is
    `totalWeight`. `contrabandFound = totalWeight > 0`.
12. Look up `alertTier` from `Config.ContrabandAlertTiers` (highest
    `minWeight` not exceeding `totalWeight`), or the explicit "clean" case if
    none match — see §5.
13. **Stamp the cooldown/mutex state now** (see §4 — timing matters, must
    happen regardless of the eventual return value, including on the
    `search_failed` path, so a client can't dodge rate-limiting by
    triggering repeated failures).
14. If `Config.Features.ContrabandAlerts` and `alertTier` isn't the "clean"
    case, broadcast the alert (§5) — sound/animation only, **never**
    `totalWeight` or item names, to any client other than the requester (see
    §6, "what the payload must never leak").
15. Return `{ ok = true, contrabandFound, totalWeight, alertTier }` to the
    caller only.

`SEARCH_REJECT_MESSAGES`, mirroring `server/main.lua`'s existing
`LEASH_REJECT_MESSAGES` table shape exactly (per the coordinator's
correction to follow that convention) — keys used above:
`invalid_target`, `feature_disabled`, `no_access`, `search_in_progress`,
`on_cooldown`, `too_far`, `search_failed`. Human-readable strings TBD at
implementation time, same pattern as the leash table (a lookup with a
generic fallback string for anything unmapped).

---

## 4. Rate limiting — mutex + dual cooldown, race-safe

Two independent concerns, both real:

**A. Same-source concurrent-call race.** `GetInventoryItems` against an
uncached vehicle trunk `await`s an internal ox_inventory `lib.callback` round
trip to the requesting client — a genuine yield point. Lua coroutines
cooperate: while one invocation of `searchTarget` is suspended on that await,
a **second** `searchTarget` call from the *same* source (a modified client
firing the callback twice back-to-back, since each `lib.callback` invocation
gets its own independent request id and nothing stops a client from doing
this) can begin executing and reach its own cooldown check *before* the
first call ever gets to stamp its cooldown timestamp — the exact
check-then-act race `server/certifications.lua`'s DB unique-index backstop
exists to close for grant INSERTs, recurring here in a different shape.
Mitigation: a simple boolean mutex, `SearchInFlight[source] = true`, set
**synchronously, before any `await`**, checked as step 4 above, and cleared
in a way that runs on every exit path (success, failure, and error — the
equivalent of a `finally`) so a thrown error inside the ox_inventory call
doesn't permanently wedge that source out of ever searching again.

**B. Cooldown key shape — resolved identity, not raw netId.** SPEC §11.4
item 2 describes the cooldown as "per `(source, targetNetId)` pair." Netids
are ephemeral and can be recycled when an entity is destroyed and a new one
created (rare, but real over a long session) — recommend keying the
*cooldown table* by the same **resolved, stable identity** already derived
in step 9 above (plate for vehicles, `targetServerId` for persons) rather
than the raw client-supplied `targetNetId`, for two reasons: (a) it's
strictly more correct — the cooldown should track "this vehicle" / "this
person", which plate/server-id represent and netId only approximates; (b) it
removes any chance, however narrow, that a client could dodge the per-target
cooldown by supplying a stale-but-still-technically-valid alternate netId
that happens to resolve to the same real-world target through some
entity-recreation edge case. This is a refinement on SPEC §11.4's wording,
not a contradiction of it — the *behavior* ("can't spam-search the same
target") is identical, only the table key is more precise. Flag for
coder-backend to confirm when writing `server/search.lua`.

Both cooldown tables (per-source, per-resolved-target) need the same
disconnect/prune hygiene `server/main.lua` already established for
`lastBarkAt`/`lastLeashRequestAt` (clear the source's entry on
`playerDropped`) — plus, since the per-target table is keyed by something
that outlives any single player (a plate persists after the searching
officer disconnects), it also needs an independent TTL-based sweep (e.g. on
a periodic `SetTimeout` loop, or lazily pruned on next access) so it doesn't
grow unbounded for the lifetime of the resource, mirroring the *pattern*
`server/certifications.lua`'s own `playerDropped` handler already documents
as a "regression-test fix" for the citizenid cache's unbounded growth.

**Rejection UX note (flag for coder-frontend, not a hard requirement):** an
`on_cooldown` rejection is expected, routine traffic (an officer
double-tapping the search option), not an error — recommend the client treat
it the same low-key way `BARK_COOLDOWN_MS`'s silent no-op and the leash
request cooldown's silent no-op are treated elsewhere in this codebase (a
soft/no notification, or at most a brief unobtrusive toast), not a jarring
error-styled message.

---

## 5. Zero-contraband ("clean") feedback — must not be silence

The task's explicit requirement, and SPEC §11.5's acceptance bullets only
partially close it: they confirm the **requester** gets an honest
`contrabandFound = false` / `totalWeight = 0` back from the callback (so
"did I find anything" always works for the searching officer specifically —
never silence *to them*), but say nothing about what plays for
*bystanders*, and `Config.ContrabandAlertTiers` (§11.2, unchanged from
SPEC's original Phase 2 placeholder) only defines `'whine'` and
`'aggressive_bark'` — both **found-contraband** tiers. There is currently no
config-driven "clean" tier at all.

Two options, presented for coder-architect to pick (this note doesn't decide
it, since it's a config-shape question and Phase 2's config isn't finalized):

- **(a) Recommended — add an explicit baseline tier**, e.g.
  `{ minWeight = 0, alert = 'clean' }` as the first entry in
  `Config.ContrabandAlertTiers`. Tier lookup (step 12 above) then never needs
  a special-cased fallback outside the config-driven table — "clean" is just
  the tier whose `minWeight` (`0`) is the highest one not exceeding a
  `totalWeight` of `0`, found by the exact same lookup logic as every other
  tier. Symmetric, and consistent with this codebase's general preference
  for config-driven behavior over hardcoded special cases (e.g. how
  `Config.Peds`/`Config.Departments` are already designed to need zero code
  changes for new entries).
- **(b) Hardcode `'clean'` as the fallback** inside `server/search.lua` when
  no configured tier matches. Simpler, no config schema change, but
  reintroduces exactly the kind of hardcoded special case (a) avoids.

Either way, **the requester's own client must render some explicit "nothing
found" feedback** (a calm sniff-then-disengage animation, a neutral
notification) driven directly off the callback's own `contrabandFound =
false` return value — this doesn't need a server broadcast at all, since
it's private feedback to the one client who asked and already has the
answer in hand. Whether a "clean" result *also* triggers a broadcast
sound/animation audible to bystanders (matching the "found" case's
broadcast, for symmetry/immersion — e.g. other officers see the dog
calmly move on) is a judgment call, not a security requirement; recommend
(a) above specifically because it makes that choice trivial to make later
(just decide whether the broadcast step runs for the `'clean'` tier too, or
skips broadcasting for it) without a separate code path.

---

## 6. Exploit vectors considered (for coder-security review)

- **Fake "search completed" to skip the real check.** Not possible by
  construction: `contrabandFound`/`totalWeight`/`alertTier` are 100%
  server-computed return values of a `lib.callback`, never fields the client
  sends *in* and gets echoed back — there is nothing in the request payload
  (`targetType`, `targetNetId`) for a client to "claim a result" with in the
  first place. The client can lie about which entity it wants searched
  (mitigated by steps 6–9), but cannot lie about the outcome of searching it.
- **Map-wide contraband oracle via arbitrary netId.** Mitigated by step 8's
  mandatory, unconditional, first-class proximity check running *before* any
  inventory read — see step 8's own rationale. This is the single most
  important ordering constraint in this whole contract; if an implementer
  ever reorders steps for convenience (e.g. "just try the inventory read
  first, it's cheap"), this protection silently disappears.
- **Entity-type spoofing** (claiming `targetType = 'vehicle'` for a person's
  netId or vice versa, to hit a differently-validated code path). Mitigated
  by step 7's independent `GetEntityType`/`NetworkGetPlayerIndexFromPed`
  re-derivation — the client's `targetType` is only ever used as a label for
  which branch to *attempt*, never trusted as the ground truth for what the
  entity actually is.
- **Spam-searching the same target to farm information** (repeatedly
  re-searching one vehicle/person, e.g. to detect the exact moment
  contraband is moved in/out as a timing side-channel, or just to harass a
  restrained player). Mitigated by the per-resolved-target cooldown (§4B) —
  independent of which certified officer (or alt) is doing the searching,
  distinct from the per-source cooldown which only stops one officer from
  searching *fast*, not a rotating group of officers from searching the same
  target back-to-back. Note the residual gap: nothing stops *multiple
  distinct, legitimately certified* officers from sequentially searching the
  same target once each cooldown window (each search is individually
  legitimate) — this is an inherent property of the feature working as
  designed for multiple real officers on scene, not a bug, but worth naming
  so it isn't mistaken for a gap in the cooldown design later.
- **Concurrent double-fire from the same client** (double-click before the
  UI disables, or a deliberate rapid-fire modified client). Mitigated by the
  in-flight mutex (§4A) closing the await-yield race that a cooldown
  timestamp alone cannot close if stamped after the async work.
- **Contraband hidden in a container to defeat the scan.** Mitigated by §2's
  required recursion into container slots — flagged as a must-handle, not
  optional polish, since it's the most obvious way to "beat" the mechanic
  once discovered by players.
- **Leaking exact contraband detail to the wrong audience.** The
  broadcast-to-bystanders channel (step 14) must carry only the alert
  tier/animation selector, never `totalWeight` or item identities — those
  values are returned solely to the requester (step 15), who is the one
  party the server has already verified is a certified, on-scene K9 officer.
  A bystander (including, notably, an accomplice of the search target)
  should never be able to derive precise contraband quantity from what's
  broadcast.
- **Conflating a failed check with a clean result.** Mitigated by step 10's
  explicit `search_failed` reason, kept structurally distinct from
  `contrabandFound = false` — an implementer collapsing these on error
  (e.g. `local ok, items = pcall(...); return { ok = true, contrabandFound =
  false }` on failure "to keep it simple") would create a real, if
  low-probability, false-negative exactly when the check errors out, which
  is arguably the worst time to be wrong.
- **Abuse of legitimate access** (a corrupt certified K9 officer using a
  real search on an ally's vehicle to "scout" for them, or searching a
  target repeatedly for reasons unrelated to actual police work). This is a
  social/administrative problem inherent to any real capability grant — the
  same category as an officer misusing certify power (§4.3's audit trail is
  qbx_k9unit's existing answer to that category for certifications) — not a
  code-level exploit this contract can close by itself. Flagging as an open
  question for coder-architect/db-schema: should `server/search.lua` log
  search actions (who searched what/whom, when, result) the same way
  `k9_certifications` provides an audit trail for grants, given searches are
  the other action in this resource with real in-fiction accountability
  stakes (a disputed "the K9 found nothing" claim)? Not resolved here — a
  schema/logging-scope decision, not a trust-boundary one.

---

## 7. Open items for other agents

- **coder-architect** — pick §5's option (a) vs (b) for the explicit "clean"
  tier; confirm whether container recursion (§2) needs a documented max
  depth constant or is fine as an implementation-local literal in
  `server/search.lua`.
- **coder-backend** — confirm the resolved-identity cooldown key (§4B) when
  writing `server/search.lua`; implement the in-flight mutex (§4A) with a
  guaranteed-cleared-on-error exit path.
- **coder-frontend** — confirm `client/search.lua`'s ox_target zone
  registration only ever fires `searchTarget` for entities actually inside
  the configured distance (UX correctness, not security — the server
  enforces distance independently regardless), and confirm the "clean"
  result's local animation/notification per §5.
- **db-schema** — weigh in on whether search actions warrant an audit table
  (§6, last bullet), given the precedent already set for certifications.
- **coder-security** — requested review of this note directly (see
  accompanying message) before any of the above starts implementation.
