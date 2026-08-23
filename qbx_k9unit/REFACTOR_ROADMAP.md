# qbx_k9unit — Technical Debt / Refactor Roadmap

Author: refactor-strategist pass, 2026-08-23. Scope: full audit of `client/`,
`server/`, `config.lua`, `sql/install.sql` as they exist after Phase 1
(8 `.lua` files, ~1500 lines total), cross-referenced against `SPEC.md` §11
(Phase 2 detailed spec: `server/tracking.lua`, `server/search.lua`,
`client/tracking.lua`, `client/search.lua`, `client/vision.lua`) and
`phase2_notes/*.md` (design-only, no code yet).

**Framing:** Phase 1 code quality is high — every access-control decision is
server-re-verified, every ephemeral-state table has *eventually* gotten
correct `playerDropped` cleanup (after two rounds of regression fixes), and
file boundaries are deliberate and well-documented. The debt here isn't
sloppiness, it's **the specific shape that accretes from many independent
incremental fixes**: the same small patterns (cooldown table, defensive
netId resolution, model-hash lookup, notify wrapper) got hand-rolled 2-3
times instead of extracted once, and Phase 2's own design notes
(`phase2_notes/contraband_search_contract.md` §4) already say, explicitly,
to hand-roll those same patterns 2-3 *more* times rather than flagging the
duplication. That's the concrete, current-cost problem this roadmap targets
— not hypothetical future maintainability, but Phase 2 files that are
about to be written to spec-documented duplicate existing patterns.

---

## Near-term (do before Phase 2 sub-phases 2b/2c/2e land)

### 1. Extract a shared per-key cooldown/TTL helper before `server/tracking.lua` and `server/search.lua` are written

**What's wrong:** Two near-identical hand-rolled cooldown tables already
exist in `server/main.lua`:
- `BARK_COOLDOWN_MS` / `lastBarkAt` (server/main.lua:255-256, checked at
  server/main.lua:272-276)
- `LEASH_REQUEST_COOLDOWN_MS` / `lastLeashRequestAt` (server/main.lua:203-204,
  checked at server/main.lua:408-412)

Both require manual, easy-to-forget cleanup in `playerDropped`
(server/main.lua:555-556) — and this codebase has *already* shipped two bugs
in this exact family: the `PendingLeashRequests` initiator-side scan gap
(server/main.lua:558-576, fixed only after a security/QA finding) and the
`Certifications` table's unbounded growth (server/certifications.lua:807-826,
fixed as a later "regression-test fix"). This is a recurring bug class, not
a one-off.

**Why it matters now, not later:** SPEC.md §11 and
`phase2_notes/contraband_search_contract.md` §4 already commit Phase 2 to
*at least* five more instances of this exact pattern, each explicitly
directed to "mirror" the existing hand-rolled hygiene rather than share code:
- `Config.Tracking.Scent/Blood/Gunpowder.searchCooldownMs` — 3 per-source
  cooldowns in `server/tracking.lua` (SPEC.md §11.2, §11.4 item 1).
- `Config.SearchZones.searchCooldownMs` per-`(source, targetNetId)` **plus**
  a second, separate flat per-source cooldown in `server/search.lua`
  (SPEC.md §11.4 item 2's "corrected per coder-security's review" note) —
  2 more tables, one of them needing a resolved-identity key (plate/server
  id, not raw netId) per `contraband_search_contract.md` §4B, plus an
  independent TTL sweep because that key outlives any single player session.
- `Config.DoorInteraction.scratchCooldownMs` in `server/main.lua`'s new
  `relayDoorScratch` handler (SPEC.md §11.3/§11.4 item 5) — explicitly
  described as "same cooldown-table pattern using
  `Config.DoorInteraction.scratchCooldownMs`."
- A same-source **in-flight mutex** for `server/search.lua`
  (`SearchInFlight[source]`, `contraband_search_contract.md` §4A) — same
  shape again (per-source table, must clear on every exit path including
  errors, must be cleaned up on disconnect).

That's 6 more hand-rolled per-key tables about to land, each independently
re-solving "cooldown check + stamp-before-or-after-the-await correctly +
playerDropped cleanup + (for search's per-target table) a TTL sweep since it
outlives any one player." The subtlety that already caused one bug
class here (stamp-before-vs-after an `await`, per SPEC §11.4 item 2's
TOCTOU note) is exactly the kind of thing that's easy to get right once and
wrong on the second or third copy-paste.

**Scope:** New `server/utils.lua` (or fold into `server/main.lua`'s already-
reserved "Phase 2+ small access-gated actions" space, but a real module
keeps that file from ballooning per its own stated goal). Exposes something
like `NewCooldown(ms) -> { check(key), touch(key), clear(key) }` and
`NewTTLTable(ttlMs) -> { get(key), set(key, val), sweep() }`, wired into one
shared `playerDropped` registration list so a new file only has to call
`RegisterCooldownForCleanup(cooldownTable)` once instead of hand-writing a
`playerDropped` line. Refactor the two existing cooldowns
(`lastBarkAt`, `lastLeashRequestAt`) onto it as the proof-of-concept — small,
low-risk diff to `server/main.lua`, no behavior change.

**Payoff:** Every one of the 6 Phase 2 additions above becomes a 1-2 line
call instead of a hand-rolled table + comment block, and the
stamp-timing/cleanup/TTL-sweep correctness is centralized in one audited
place instead of re-derived per file. This is the single highest-payoff,
lowest-risk item on this roadmap because Phase 2's own design docs already
name every call site that needs it.

**Order:** First — before `server/tracking.lua` or `server/search.lua` is
started (sub-phases 2b/2d/2e per SPEC.md §11.1).

---

### 2. Extract a shared "resolve network entity defensively" helper

**What's wrong:** The same 2-3 line defensive netId-resolution pattern
(`NetworkDoesEntityExistWithNetworkId` / `NetworkGetEntityFromNetworkId` /
`DoesEntityExist`) is independently implemented in:
- `client/main.lua`'s `playBark` handler (client/main.lua:157-164)
- `client/vehicle.lua`'s `ResolveVehicleFromState()` (client/vehicle.lua:87-91)

**Why it matters now:** SPEC.md §11.4 item 6 explicitly says the new
`qbx_k9unit:client:playDoorScratch` handler "mirrors `client/main.lua`'s
existing `playBark` handler exactly (resolve the network entity, no-op if
not streamed in, play a sound)" — i.e., a 3rd hand-copy is already planned
in the spec text itself. Separately, `server/search.lua`'s `searchTarget`
callback needs a **server-side** variant with additional type-checking
(`GetEntityType` + `NetworkGetPlayerIndexFromPed` cross-check against the
client's claimed `targetType` — the "security-critical" check called out in
`phase2_notes/contraband_search_contract.md` §3 step 7). That's a 4th
variant, this time carrying real security weight, about to be hand-written
from scratch rather than building on a vetted resolver.

**Scope:** Small — add one client-side `ResolveNetworkEntity(netId)` global
to `client/main.lua` (next to `IsOwnModelK9`/`HasK9Access`), refactor
`playBark` and `ResolveVehicleFromState` to use it (trivial diffs, no
behavior change). Add a server-side equivalent in the new `server/utils.lua`
from item 1, with an optional expected-type parameter, for
`server/search.lua` to build on rather than re-deriving the entity-type
cross-check from scratch.

**Payoff:** One fewer copy-paste site for `playDoorScratch`; a single vetted
place to put the entity-type mismatch check that
`contraband_search_contract.md` calls "the single most important ordering
constraint in this whole contract" — worth having audited once, not
reimplemented ad hoc in a brand-new file under time pressure.

**Order:** Alongside item 1, before `client/movement.lua`'s door-interaction
extension and `server/search.lua`.

---

### 3. Consolidate the three independent `Config.Peds` model-hash tables (client side only — server side already does this correctly)

**What's wrong:** Exactly the "resolve entity from netId defensively"-style
duplication the task asked about, but for model checks. Three separate
precomputed hash tables are built from the same `Config.Peds` list, doing
the identical computation:
- `client/main.lua:93-96` — `K9ModelHashes`, backing `IsOwnModelK9()`
  (checks only `PlayerPedId()`, i.e. the local player).
- `client/movement.lua:398-401` — `k9ModelHashesForTargeting`, backing a
  local `IsEntityModelK9(entity)` — explicitly commented as "a small local
  copy of the same generic Config.Peds-driven check... not a security check,
  so a second small local copy... is an acceptable, deliberate tradeoff
  here" (client/movement.lua:391-397).
- `server/certifications.lua:154-157` — `K9ModelHashes`, backing the
  globally-exposed `IsConfiguredK9Model(modelHash)`.

**The asymmetry worth noting:** the **server** side already does this
correctly — `IsConfiguredK9Model` is exposed once from
`server/certifications.lua` and reused as-is by `server/main.lua`'s
`CheckLeashEligibility` (server/main.lua:353-354). The **client** side
never built the equivalent "check an arbitrary entity's model" global, so
`client/movement.lua` quietly grew its own copy instead of extending
`client/main.lua`'s three-function contract (`IsOwnModelK9` /
`HasK9Access` / `CanShowK9UI`, documented at client/main.lua:47-73). This is
the good-pattern/bad-pattern pair worth pointing out to whoever writes
Phase 2's client files, since they'll be reading `client/main.lua`'s header
as the model to imitate.

**Why it matters for Phase 2:** none of `client/tracking.lua`,
`client/search.lua`, `client/vision.lua` currently need an
arbitrary-entity K9-model check per SPEC.md §11.3's file plan (vision.lua
reuses `IsOwnModelK9()` correctly, per SPEC §11.5's thermal-vision bullet).
So this item is **not blocking** Phase 2's critical path — but it's cheap
to fix now, and leaving it means a future file (Phase 3's
`HandlerDownDefense`, which needs to identify "nearest hostile" possibly
relative to a K9 entity, or any stretch item) has two divergent examples to
copy from instead of one.

**Scope:** Add `IsEntityModelK9(entity)` as a fourth exposed global in
`client/main.lua` (one line, generalizing the existing hash table — `
IsOwnModelK9()` becomes `IsEntityModelK9(PlayerPedId())`). Delete
`client/movement.lua`'s local `k9ModelHashesForTargeting`/`IsEntityModelK9`
and call the new shared global instead. Small, isolated, no behavior change.

**Payoff:** Closes the specific duplication pattern the audit was asked to
find; gives future client files one obvious place to look instead of two
inconsistent examples.

**Order:** Cheap enough to do any time before/alongside item 1-2; not a
hard blocker for any specific Phase 2 sub-phase.

---

### 4. Extract `relayBark`'s shape into a shared "gated cooldown broadcast" helper before the contraband-alert and door-scratch broadcasts land

**What's wrong / what's coming:** `server/main.lua`'s `relayBark`
(server/main.lua:265-287) has a clean, repeatable shape: feature-flag check
→ `HasK9Access` check → per-source cooldown check/stamp → resolve sender's
own entity → `TriggerClientEvent(..., -1, ...)` broadcast. SPEC.md §11.3
already flags, in its own words, that `server/search.lua`'s contraband-alert
broadcast and `server/main.lua`'s new `relayDoorScratch` handler are
candidates to reuse this shape rather than hand-copy it: relayDoorScratch is
described as "structurally identical to `relayBark`... same `HasK9Access`
re-check, same per-player cooldown-table pattern... same broadcast-to-nearby-
clients shape," and the contraband broadcast is flagged as "consider
exposing a small shared helper from `server/main.lua` if the two end up
wanting byte-identical broadcast logic" (SPEC.md §11.3, `server/main.lua`
row and `server/search.lua` row).

**Why now:** the spec is explicitly leaving this as an open call for
whoever implements it — doing the extraction *before* those two call sites
land means both get the audited version instead of the second one
inheriting whatever the first implementer happened to get right or wrong
under time pressure (e.g., the specific "stamp cooldown before vs. after the
await" subtlety flagged in item 1).

**Scope:** One function in the `server/utils.lua` module from item 1,
parameterized by feature flag, access-check function, and cooldown table
(built via item 1's `NewCooldown`). Refactor `relayBark` onto it as the
reference implementation.

**Order:** After item 1 (depends on the cooldown helper), before sub-phase
2c (`ContrabandAlerts`) and the door-scratch relay piece of `DoorInteraction`.

---

### 5. Publish a single canonical list of every resource-global identifier before Phase 2 file count nearly doubles

**What's wrong:** Every cross-file "API" in this resource is a bare Lua
global (no module table, no namespace) — `IsOwnModelK9`, `HasK9Access`,
`CanShowK9UI`, `ToggleK9Camera`, `K9Sit`, `RequestLeashAttach`,
`DetachLeash`, `IsLeashed`, `IsInK9Vehicle`, `EnterNearestK9Vehicle`,
`ExitK9Vehicle`, `IsConfiguredK9Model`, `RefreshCertificationCache`,
`ForceDetachLeashForSource`, `ForceDetachOfficerLeashForSource`. This works
today because each file's header comment documents its own contract
carefully and there are only 6 `.lua` files to keep in your head. A silent
global-name collision in Lua produces no error — the second definition just
overwrites the first, silently.

**Why it matters for Phase 2 specifically:** SPEC.md §11.3 plans at least 3
more exposed globals (`StartScentTrack()`, `StartBloodTrack()`,
`StartGunpowderTrack()` from `client/tracking.lua`, called from
`client/radial.lua`) plus whatever `client/search.lua`/`client/vision.lua`/
`server/tracking.lua`/`server/search.lua` end up exposing — client file
count goes from 4 to 7, server from 2 to 4. Nothing currently stops two
authors (or one author reusing a name that sounds natural, like
`IsActive`/`GetState`) from colliding.

**Scope:** Not a code change — a short, explicit reference (a section in
`README.md`'s existing "Where things live" list, or a new small doc)
enumerating every current bare-global identifier and its owning file, kept
up to date as Phase 2 files land. Cheap (well under an hour), zero risk.

**Order:** Do alongside item 3, before Phase 2 implementation starts on any
sub-phase — hand to coder-architect as a short prep task.

---

## Medium-term

### 6. Revisit the bare-global cross-file convention if Phase 3+ keeps adding files at this rate

Item 5's symbol registry is a cheap mitigation, not a structural fix. If
Phase 3 (combat/agility, 5 more features) and Phase 4 (inventory/vitality,
10 more features) keep adding files at the Phase-2 rate, the collision risk
compounds well past what a manually-maintained list can keep safe. Consider
a lightweight namespace convention (e.g. a shared `K9 = K9 or {}` table
populated by each file instead of bare globals) at that point — but this
touches every existing file for a problem that has not yet caused a bug, so
it is **not** worth doing now, and doing it now would be exactly the kind of
rewrite-where-a-narrower-fix-suffices this roadmap is trying to avoid.
Revisit before Phase 3 starts, using item 5's registry to judge whether the
list has actually gotten unwieldy.

### 7. `Config.LeashMaxDistance`'s triple-duty overload

One config value is reused for three semantically distinct purposes across
three files: `client/movement.lua` derives the elastic pull-back start
(75%) and hard-cap auto-detach (150%) from it; `server/main.lua`'s
`CheckLeashEligibility` reuses the raw value as the initiate-range check;
`client/radial.lua`'s `FindNearestLeashCandidate` reuses the raw value as
its search radius (all three cross-referenced in `config.lua`'s own comment
on the field, config.lua:122-142). This is already self-documented as a
deliberate Phase 1 default with an open question flagged for a future
dedicated "attach range" constant. Phase 2 does not touch leash code at all,
so this doesn't block anything — but if Phase 3/4 ever needs to tune
"how close do I need to be to request a leash" independently of "how far can
I roam once leashed," that's the trigger to split it into 2 named constants.
Not worth doing speculatively now.

### 8. `FindNearestLeashCandidate` / `FindNearestK9Vehicle` — parallel "find nearest entity in pool within range" implementations

`client/radial.lua:94-113` and `client/vehicle.lua:60-76` are two
independent implementations of "scan a pool, filter by distance, keep the
nearest." Only 2 instances today, not diverging, low cost. Watch for a 3rd
occurrence (a plausible candidate would be a Phase 3 "nearest hostile for
handler-down defense" scan) as the trigger to extract a generic
`FindNearestEntity(pool, maxDistance, predicate)` helper — extracting for 2
call sites alone isn't worth the abstraction cost yet.

---

## Watch, don't act yet

- **`NotifyPlayer` duplicated verbatim** between `server/certifications.lua`
  (certifications.lua:178-184) and `server/main.lua`
  (server/main.lua:214-220), the latter explicitly commented as a deliberate
  "tiny, generic UI-plumbing helper" duplication rather than a shared
  dependency. Two Phase 2 server files will likely want it too (4 copies
  total). Genuinely low-stakes (6-line wrapper, unlikely to drift in
  behavior) — bundle into the `server/utils.lua` module from item 1 as a
  byproduct of doing that work anyway, but not worth a dedicated pass on its
  own.
- **Rejection-reason-message tables** (`LEASH_REJECT_MESSAGES` in
  `server/main.lua`, and the planned `SEARCH_REJECT_MESSAGES` in
  `server/search.lua` per `phase2_notes/contraband_search_contract.md`'s
  explicit "mirroring... exactly" note) — this is the *good* kind of
  repetition (a documented, intentional convention each new file is meant to
  copy), not drift. No action needed; just don't let a future file invent a
  fourth, different shape for the same idea.
- **Trivial proximity one-liners** (`#(GetEntityCoords(a) -
  GetEntityCoords(b))`) appear 3 times across `certifications.lua`/
  `main.lua`. Too small to be worth extracting into a helper; the clarity
  cost of an indirection outweighs the ~1 line saved per site.
- **`Config.Peds[].label` is unused by any code path** (confirmed in
  README.md's `Config.Peds` section) — dead-ish config data, harmless,
  likely becomes live once a Phase 4 HUD wants display labels. No action
  needed now.
- **SPEC.md §4.1's stale "the actual spawn request" phrase**, already
  self-flagged in `server/certifications.lua`'s header as leftover text from
  the pre-correction draft. A one-line spec wording fix, not code debt —
  low priority, cosmetic.
- **ox_target option registration boilerplate** (4 near-identical option
  blocks across `client/movement.lua` and `client/vehicle.lua`) — this is
  idiomatic ox_target usage where each block's `canInteract`/`onSelect`
  genuinely differs; not duplication worth collapsing.

---

## Suggested delegation

- **coder-architect**: items 1, 2, 4 (new `server/utils.lua` module + the
  two client-side helper extractions in item 3) — structural, cross-file,
  should land as one coordinated pass before Phase 2 sub-phase 2b/2d starts.
  Item 5 (symbol registry) is a quick add-on to the same pass.
- **coder-backend**: consumes items 1/2/4's helpers when writing
  `server/tracking.lua` and `server/search.lua` — flag in each new file's
  header (per this codebase's own convention) that it builds on
  `server/utils.lua` rather than re-deriving cooldown/resolve/broadcast
  logic.
- **coder-frontend**: consumes item 3's `IsEntityModelK9` global if
  `client/tracking.lua`/`client/search.lua` end up needing an
  arbitrary-entity model check (not currently required per SPEC §11.3, but
  cheap insurance if scope shifts during implementation).
- **code-improver**: good complementary pass once `server/tracking.lua` /
  `server/search.lua` are actually drafted — check they used the new shared
  helpers rather than re-copying the old per-file patterns despite this
  roadmap (the failure mode to watch for is Phase 2 landing before this
  near-term work does, in which case the duplication this roadmap flags will
  already exist and become a code-improver finding instead of a prevented
  one).
- **correctness-overseer / qa-tester**: verify items 1-4's extractions are
  pure refactors — `relayBark`, `playBark`, and `ResolveVehicleFromState`'s
  observable behavior must be byte-identical before/after, since Phase 1 is
  shipped and reviewed.
