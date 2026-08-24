# qbx_k9unit — Technical Debt / Refactor Roadmap

**Revision 4 — near-term item 2 landed, coder-architect pass, 2026-08-24.**
Near-term item 2 below (the shared `ResolveNetworkEntity` defensive-netId-
resolution helper) **shipped** this pass as a client-side global in
`client/main.lua` plus a new `server/entities.lua` (see that file's own
header for why a new file rather than joining `server/cooldowns.lua` — the
roadmap left the choice open, and this pass reads item 1's own "one
new file per responsibility" precedent as favoring a dedicated file, not
one shared catch-all utils module). Client-side, reading the actual
current code at the start of this pass found the 4-copy count already
partially self-corrected: an earlier, undocumented-in-this-roadmap dedup
pass had already consolidated `client/main.lua`'s `playBark` handler and
`client/search.lua`'s `playContrabandAlert` handler onto one shared
`PlaySoundOnNetworkEntity()` — so only 3 independent client-side resolve
implementations remained (`PlaySoundOnNetworkEntity` itself,
`client/vehicle.lua`'s `ResolveVehicleFromState`, and
`client/movement.lua`'s `playDoorScratch` receiver), not 4. All 3 now call
the new `ResolveNetworkEntity()`; `playContrabandAlert` picks it up
transitively through `PlaySoundOnNetworkEntity` and needed no direct edit.
Server-side, both `relayDoorScratch` (now passing `expectedEntityType = 3`
to fold its object-only restriction into the same call) and
`HandleSearchTarget` (called without `expectedEntityType` — its
`targetType`-vs-`GetEntityType` cross-check stays at the call site exactly
as this item specified) were migrated with their existing entity-type/
proximity checks preserved. One disclosed, deliberate exception:
`HandleSearchTarget` previously had no `DoesEntityExist` guard at all (only
an `entity == 0` check) — the shared resolver adds one for every caller,
a strengthening, not a weakening, flagged explicitly rather than folded in
silently; see `server/entities.lua`'s own doc comment and
`server/search.lua`'s `HandleSearchTarget` comment for the full reasoning
on why this isn't expected to change observed behavior. `luac5.4 -p` and
`luacheck` (with `ResolveNetworkEntity` added to the root `.luacheckrc`'s
cross-file-globals list) both report 0 warnings/0 errors across the whole
resource. See the **"STATUS: DONE"** marker on the item 2 heading below.

**Revision 3 — near-term item 1 landed, watchdog Pass #4, 2026-08-23.**
Near-term item 1 below (the shared `NewCooldown`/`NewNestedCooldown`/
`NewMutex` extraction) **shipped** in commit `ac29069` as
`server/cooldowns.lua`, migrating all 11 previously hand-rolled
cooldown/mutex tables across `server/main.lua`, `server/certifications.lua`,
`server/tracking.lua`, `server/search.lua` onto it, per that commit's own
message: reviewed by three independent passes plus a direct old-vs-new
numeric-constant comparison, all behavior-preserving, with one real latent
bug (a nil/non-positive threshold silently and permanently disabling a
cooldown) caught and fixed to fail closed instead. Re-verified this pass:
`server/cooldowns.lua`'s `IsOnCooldown` methods do return `true` (blocked)
rather than `false` (allowed) when `threshold` is nil/non-positive — see
`server/cooldowns.lua:146-161` and `:245-256`. The item's write-up below is
kept as-is (historical record of the debt as it stood pre-extraction), not
rewritten, per this document's own established convention of layering
status corrections rather than silently editing history — see the
**"STATUS: DONE"** marker on the item 1 heading below for the current
state.

**Near-term item 2 (defensive-netId-resolution helper) is still open** —
`ac29069` scoped itself to the cooldown/mutex extraction only (confirmed by
its own file list: `fxmanifest.lua`, `server/certifications.lua`,
`server/cooldowns.lua`, `server/main.lua`, `server/search.lua`,
`server/tracking.lua` — no `ResolveNetworkEntity` helper, no client-side
change). Still 6 independent copies of that pattern as of this pass; no
change from the retrospective below.

**New pattern found this pass, same root cause as item 3 below, not
previously tracked:** `client/movement.lua` carries two more
`Config.Peds`-adjacent literal-string tables that item 3 doesn't cover —
`K9_SIT_SCENARIO_BY_MODEL_HASH` and `K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH`
(breed-name -> scenario-name maps for the Sit and Scratch-to-Alert
actions). Unlike the three *model-recognition* tables item 3 already
tracks (which all derive their keys by iterating `Config.Peds` at load
time, so a `Config.Peds` edit can never desync them), these two are
separately hand-written literal `{ a_c_shepherd = ..., a_c_husky = ... }`
tables that must be kept in sync with `Config.Peds`' actual model strings
by hand. This is exactly how the `a_c_huskie` → `a_c_husky` typo fix
(`f70d28f`) briefly desynced them: `config.lua` and the three
`Config.Peds`-iterating tables were fixed, but at `f70d28f`'s own commit
neither breed-to-scenario table was — `K9_SIT_SCENARIO_BY_MODEL_HASH` kept
the stale `a_c_huskie` key (a real, confirmed miss: `GetHashKey('a_c_husky')`
no longer matches the table's `GetHashKey('a_c_huskie')` entry, silently
falling back to `K9_SIT_DEFAULT_SCENARIO` for a Husky K9's Sit action
instead of the intended Retriever substitute), while
`K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH` (added one commit later in
`09082df`) was authored with the already-corrected `a_c_husky` string and
so never broke. See `WATCHDOG_LOG.md`'s Pass #4 entry for the full
before/after; as of this pass a concurrent, uncommitted diff already
corrects `K9_SIT_SCENARIO_BY_MODEL_HASH`'s key too, so this should not need
a separate fix — but the underlying **pattern** (hand-copied breed-string
literals that must track `Config.Peds` without any mechanism enforcing
it) remains, and a 3rd such table is a realistic future risk (Phase 3's
`PHASE3_SPEC.md` §12.5.5 Advanced Agility work and any future bark-variety
work are exactly the kind of per-breed feature likely to add a 4th).
Recommend folding a fourth line item into item 3 below: **either** extend
`IsEntityModelK9`-style consolidation to expose a single
`Config.Peds`-driven `model -> scenario` builder function that all
breed-to-scenario tables call (`BuildScenarioTableByModel({shepherd=...,
rottweiler=..., chop=..., husky=...})`) so a future config typo fix only
needs to touch `config.lua`, **or** at minimum add a one-line assertion at
each table's construction site that every `Config.Peds` entry has a
corresponding scenario mapping (fails loudly at resource start instead of
silently falling back to the default scenario for an unmapped breed).
Low urgency (cosmetic-only misses, not a security/correctness issue), but
cheap to bundle with whichever coder-architect pass eventually does item 3.

---

**Revision 2 — Phase 2 retrospective, 2026-08-23.** Phase 2 (tracking,
search, vision, door interaction — client + server, all four sub-areas) has
now fully landed. This revision re-reads the real, shipped code in
`server/main.lua`, `server/certifications.lua`, `server/tracking.lua`,
`server/search.lua`, `client/main.lua`, `client/vehicle.lua`,
`client/movement.lua`, `client/search.lua`, `client/vision.lua` and checks
every prediction Revision 1 made against what actually shipped, rather than
re-asserting them. Revision 1's specific predictions are quoted and
evaluated below rather than reproduced in full — this document supersedes
Revision 1; treat it as the current source of truth, not an addendum to
read alongside the old one.

**Headline result:** the core mechanism Revision 1 worried about — the same
few small patterns (cooldown table, defensive netId resolution) getting
hand-rolled again for every new feature instead of extracted once — did
keep happening, and in most cases happened *more* than predicted, not less.
No `server/utils.lua` or any shared helper was ever created; every
extraction Revision 1 recommended is still todo. The good news is that the
team's fallback discipline (extremely thorough per-instance comments,
explicit "mirrors X exactly" / "do NOT copy this pattern" cross-references,
and apparently careful review — the door-scratch multi-account flood was
caught by an exploit-tester finding before/at ship time, not after) held
correctness: no forgotten-cleanup or stamp-order bug shipped this round.
That discipline is what's actually paying the interest on this debt right
now, and it gets more expensive, not cheaper, with every additional file.

---

## What actually happened, item by item

### Item 1 (cooldown/TTL helper) — CONFIRMED, and worse than predicted

Revision 1 predicted "6 more hand-rolled instances" landing with Phase 2's
`server/tracking.lua`/`server/search.lua`, on top of the 2 that already
existed in `server/main.lua` (`lastBarkAt`, `lastLeashRequestAt`).

Real count of independent cooldown/mutex/TTL tables now in the four files
in scope, none sharing an implementation:

| File | Table(s) | Predicted? |
|---|---|---|
| `server/main.lua` | `lastBarkAt`, `lastLeashRequestAt` (pre-existing) | n/a |
| `server/main.lua` | `lastDoorScratchAt` (per-source, door-scratch) | yes |
| `server/main.lua` | `lastDoorScratchAtByDoor` (per-door) | **no** — added post-hoc after an exploit-tester finding (2026-08-23) that per-source-only rate limiting lets multiple certified accounts flood one door in concert; see `server/main.lua:391-420` |
| `server/tracking.lua` | `LastTrackQueryAt[source][trackType]` — one unified table covering scent/blood/gunpowder query cooldowns | predicted as **3 separate** tables; actually consolidated to 1 — better than predicted |
| `server/tracking.lua` | `lastDamageRelayAt` (blood logging-side rate limit) | **no** — a "coordinator amendment" concept absent from Revision 1's source material |
| `server/tracking.lua` | `lastWeaponFireRelayAt` (gunpowder logging-side rate limit) | **no**, same reason |
| `server/search.lua` | `SearchInFlight` (mutex) | yes |
| `server/search.lua` | `lastSearchAt` (flat per-source) | yes |
| `server/search.lua` | `lastTargetSearchAt` (per-resolved-target, own TTL sweep) | yes |
| `server/certifications.lua` | `lastCertifyActionAt` (grant/revoke cooldown) | **no** — a security-hardening addition to a file Revision 1 called out as *already* doing the right thing, unrelated to any Phase 2 spec text |

Net: **9 new tables**, not 6 — plus **3 independently hand-rolled periodic
sweep threads** (`PruneDoorScratchCooldowns`, `PruneTrackableLogs`,
`PruneTargetSearchCooldowns`), each reinventing "loop + `Wait` + iterate
`pairs` + evict stale" from scratch with small, non-shared variations
(rebuild-a-fresh-array vs. in-place `nil` removal). Total distinct
cooldown/mutex tables across the resource is now **11**, up from 2 at the
start of Phase 2.

Two things Revision 1 got wrong in useful ways: it undercounted by scoping
the prediction to Phase 2's *named spec files* only (missing the
certifications.lua grant/revoke fix, which arrived via a security pass, not
a spec item) — a reminder that duplication-risk predictions tied to a spec
document will always miss debt introduced by review/security passes on
already-shipped files. It also over-predicted the tracking-cooldown count:
the team correctly saw that Scent/Blood/Gunpowder query cooldowns didn't
need 3 separate tables and generalized to one `[source][trackType]` table —
proof the underlying instinct (a shared per-key cooldown abstraction pays
off) was right even where a formal helper module was never built.

Correctness held throughout: every new table has correct `playerDropped`
cleanup or an independent TTL sweep, and every cooldown is stamped before
the guarded work runs. That didn't happen for free — it took explicit,
repeated doc-comments in every file ("same reasoning as X's
`playerDropped` handler," "mirrors `BARK_COOLDOWN_MS`'s exact shape") to
hold the line. This is now spread across **4 files** instead of 1.

### Item 2 (defensive netId resolution) — CONFIRMED, and the strongest hit on this roadmap

Revision 1 predicted a 3rd client-side copy in the door-interaction handler
and a 4th, security-critical server-side variant in `server/search.lua`.

Real count of independent implementations of the same 3-line
`NetworkDoesEntityExistWithNetworkId` → `NetworkGetEntityFromNetworkId` →
existence-guard shape:

- `client/main.lua`'s `playBark` handler (pre-existing)
- `client/vehicle.lua`'s `ResolveVehicleFromState()` (pre-existing)
- `client/movement.lua`'s `playDoorScratch` receiver (`client/movement.lua:854-863`)
  — **predicted exactly**; its own doc comment says it "mirrors
  `client/main.lua`'s existing `playBark` handler EXACTLY."
- `client/search.lua`'s `playContrabandAlert` receiver
  (`client/search.lua:304-310`) — a **4th client copy Revision 1 did not
  name explicitly** (it inferred the door-scratch copy from spec text, but
  nothing in the source material flagged this second receiver). Its own
  comment says the same thing: "Mirrors `client/main.lua`'s existing
  `playBark` handler exactly."
- `server/main.lua`'s `relayDoorScratch` (`server/main.lua:471-495`) — a
  server-side variant with real security logic layered on top (existence
  check, entity-type check restricting to objects, a proximity re-check
  against the caller's live position).
- `server/search.lua`'s `HandleSearchTarget` (`server/search.lua:423-453`)
  — **predicted exactly** ("4th variant, carrying real security weight");
  cross-checks `GetEntityType` against the claimed `targetType`.

Total: **6 independent copies** (4 client, 2 server) of a pattern that was
2 copies at the start of Phase 2. This is the single item where the
prediction is most clearly vindicated — it called the right file
(`client/movement.lua`) and the right high-stakes file
(`server/search.lua`) — and then undercounted the real total by missing
the second client-side broadcast receiver. The pattern is small (3-4
lines) but now lives in 6 places with only comments, not code, keeping them
in sync.

### Item 3 (triple `Config.Peds` model-hash tables) — accurately assessed as low-urgency, and correctly stayed that way

Still exactly 3 copies: `client/main.lua`'s `K9ModelHashes`,
`client/movement.lua`'s `k9ModelHashesForTargeting`,
`server/certifications.lua`'s `K9ModelHashes`. No 4th appeared:
`client/vision.lua` correctly reuses `IsOwnModelK9()`, and
`server/tracking.lua`/`server/search.lua` both explicitly document that
they deliberately don't need a model check at all (job+certification is
the eligibility model, not "is playing a K9"). Revision 1's call that this
"is not blocking Phase 2's critical path" and "cheap to fix any time" was
correct on both counts — it wasn't fixed, and nothing got worse from
leaving it. This is the one item where "premature to act" turned out to be
the right read, not just a hedge. **Revision 3 update:** see the new
breed-to-scenario-table note at the top of this document — a *related but
distinct* pair of tables (not counted in the "3 copies" above, since they
map to scenario names, not booleans) turned out to be exactly the failure
mode this item's "cheap to fix any time" framing was implicitly betting
against; worth widening this item's scope to cover them when it's finally
picked up.

### Item 4 (shared gated-cooldown-broadcast helper) — partially confirmed, payoff smaller than framed

`relayBark` and `relayDoorScratch` do share the exact tail Revision 1
predicted — both end in a bare `TriggerClientEvent(..., -1, ...)` — and the
shipped code is self-aware of it: `server/main.lua:514-523`'s comment says
this "mirrors `relayBark`'s own -1 broadcast exactly, on purpose." The
contraband-alert broadcast (`server/search.lua`'s `BroadcastContrabandAlert`)
stayed deliberately distance-filtered and structurally different, exactly
matching Revision 1's own hedge that this one "might NOT need
consolidating" — its own comment even says "NOT the pattern to copy if
you're touching `server/search.lua`'s contraband-alert broadcast instead."
So the 3-way split Revision 1 guessed at (2 alike, 1 deliberately
different) is exactly what shipped.

What Revision 1 overstated: the *shared* part of `relayBark` and
`relayDoorScratch` is thin — feature-flag check, `HasK9Access` check,
cooldown check/stamp, then the broadcast — maybe 6-8 lines. Almost all of
`relayDoorScratch`'s real complexity (entity resolution, existence check,
entity-type check, proximity check) is validation logic `relayBark` never
needed at all, because `relayBark` only ever resolves the sender's own
already-verified ped. A shared helper here would save a handful of lines
on one call site, not prevent a bug — no stamp-order or access-check bug
actually occurred at either site. The explicit cross-referencing comments
substituted for the extraction successfully, at real but small ongoing
cost.

### Item 5 (symbol registry) — done, working as intended

`phase2_notes/EXPORT_TRACKING.md` exists and is actively maintained with
every current resource-global listed by owning file. No collision has
occurred. This recommendation was followed; no further action needed
beyond continuing to update it as Phase 3 files land.

### Medium-term items — mixed

- **`NotifyPlayer` duplication (watch item):** predicted to reach 4 copies
  once Phase 2 server files landed. Reality: still only 2
  (`server/main.lua`, `server/certifications.lua`). Neither
  `server/tracking.lua` nor `server/search.lua` duplicated it — both files
  deliberately treat almost all rejections as silent no-ops rather than
  player-notified ones (explicit "not an error worth notifying about"
  comments throughout). Resolved by a different design decision than
  predicted; no action needed, and the same silent-no-op convention means
  the predicted `SEARCH_REJECT_MESSAGES` mirror of `LEASH_REJECT_MESSAGES`
  never got written either — `server/search.lua` has no rejection-message
  table at all. Downgrade both watch items to closed.
- **`FindNearestEntity` (medium-term item 8):** a 3rd "scan a pool, filter,
  keep nearest" shape appeared in `server/tracking.lua`'s blood/gunpowder
  branch (`server/tracking.lua:440-456`), but it's over an array of
  `{coords, loggedAt}` log entries filtered by *both* age and distance, not
  a live entity pool filtered by distance alone — related, not identical.
  The "extract at the 3rd occurrence" trigger is arguably reached, but a
  clean generic helper would need an extra predicate/age parameter to cover
  all three shapes cleanly. Worth a light look, not urgent.
- **`Config.LeashMaxDistance` triple-duty (item 7):** untouched — Phase 2
  didn't touch leash code. Still valid as originally written, still not
  worth doing speculatively.
- **`Config.Peds[].label` unused, ox_target boilerplate, proximity
  one-liners:** unchanged, not re-verified in depth this pass since nothing
  in Phase 2 touched them; no evidence they got worse.

---

## Updated roadmap (post-Phase-2 state)

### Near-term (do next)

#### 1. Extract the shared cooldown/TTL/mutex helper now — retroactively, not preemptively — **STATUS: DONE (`ac29069`)**

**Landed 2026-08-23 as `server/cooldowns.lua`** (`NewCooldown`,
`NewNestedCooldown`, `NewMutex`), migrating all 11 tables named in the
retrospective above across `server/main.lua`, `server/certifications.lua`,
`server/tracking.lua`, `server/search.lua`. See the Revision 3 note at the
top of this document for verification detail. The write-up immediately
below is retained as the original problem statement for the record, not
because the item is still open.

**What's wrong:** 11 independent hand-rolled cooldown/mutex tables and 3
independent periodic-sweep threads now exist across `server/main.lua`,
`server/certifications.lua`, `server/tracking.lua`, `server/search.lua` (up
from 2 tables in 1 file before Phase 2 — see retrospective above for the
full inventory). Every one of them is currently correct, but each new file
had to re-derive, from scratch, the same three subtleties: stamp-before-
vs-after the guarded work, `playerDropped` cleanup for player-keyed tables,
and an independent TTL sweep for tables keyed by something else (door
netId, resolved target identity). That's no longer a predicted risk, it's
the resource's actual current shape.

**Why now:** this is no longer "before the 2nd/3rd copy lands" — the
2nd through 9th copies have already landed. The value proposition has
flipped from *prevention* (stop duplication before it starts) to
*consolidation* (collapse duplication that already cost 4 files' worth of
repeated correctness reasoning). The risk this closes is concrete and
recent: the door-scratch multi-account flood
(`server/main.lua:391-420`) was only caught because someone happened to
retest that specific handler; the next new per-key table (Phase 3 combat/
agility, per `PHASE3_SPEC.md`) gets no benefit from that finding unless
it's encoded in shared code instead of a comment.

**Scope:** New `server/utils.lua` exposing `NewCooldown(ms) ->
{ check(key), touch(key), clear(key) }`, a two-key variant for
per-source-and-per-door-style dual cooldowns (`lastDoorScratchAt` /
`lastDoorScratchAtByDoor`'s shape), `NewTTLTable(ttlMs) -> { get(key),
set(key, val), sweep() }`, and a single shared sweep-thread runner so a new
file registers a table instead of hand-writing `CreateThread`/`Wait`/prune
logic. Migrate the 9 real Phase 2 tables (plus the 2 pre-existing ones)
onto it as the reference implementation — a bigger diff than Revision 1
scoped (2 tables, not 11), but each individual migration is still
mechanical and behavior-preserving; a good candidate to split into one PR
per file (`main.lua`, `certifications.lua`, `tracking.lua`, `search.lua`)
so each is independently reviewable and revertable.

**Payoff:** Removes ~150-250 lines of repeated cooldown/sweep boilerplate
and comments across 4 files; the next Phase 3 feature that needs a cooldown
(combat/agility per `PHASE3_SPEC.md`) gets it in 1-2 lines with the
door-scratch flood fix already baked in, instead of needing to be told
about that finding via yet another comment.

**Order:** Highest-value item on this roadmap now, precisely because it's
overdue — do it before Phase 3 (`PHASE3_SPEC.md`) adds its own cooldowns
using the same hand-rolled convention, which would make this a 12+-table
migration instead of an 11-table one.

#### 2. Extract the "resolve network entity defensively" helper — same call, now backed by 6 real instances instead of 2 — **STATUS: DONE (2026-08-24, coder-architect)**

**Landed this pass** as `client/main.lua`'s `ResolveNetworkEntity(netId)`
(client-side) and `server/entities.lua`'s `ResolveNetworkEntity(netId,
expectedEntityType?)` (server-side, new file — see that file's own header
for the "new file vs. join cooldowns.lua" decision and reasoning). See the
Revision 4 note at the top of this document for the full verification
detail, including the one disclosed exception (a strengthened, not
weakened, existence check picked up by `HandleSearchTarget`). The
write-up immediately below is retained as the original problem statement
for the record, not because the item is still open.

**Confirmed still open this pass** — `ac29069` (item 1 above) did not touch
this pattern; still 6 independent copies, no `ResolveNetworkEntity` helper
anywhere in the tree as of this pass.

**What's wrong:** now 6 independent copies (4 client: `client/main.lua`,
`client/vehicle.lua`, `client/movement.lua`, `client/search.lua`; 2
server: `server/main.lua`, `server/search.lua`) of the same defensive
resolve pattern, confirmed above.

**Scope:** unchanged from Revision 1's proposal — one client-side
`ResolveNetworkEntity(netId)` global in `client/main.lua`, reused by
`playBark`, `ResolveVehicleFromState`, `playDoorScratch`, and
`playContrabandAlert`; one server-side equivalent, reused
by `relayDoorScratch` and `HandleSearchTarget` (the latter keeps its own
additional `GetEntityType`-vs-claimed-`targetType` cross-check on top,
since that's request-specific, not part of the generic resolve). Since
item 1's `server/cooldowns.lua` already established the "new shared
`server/*.lua` module" convention, the server-side half of this item can
either join that file or get its own `server/entities.lua` — either is
consistent with the shipped precedent now.

**Payoff:** Same reasoning as Revision 1, at 3x the current duplication —
one audited place for "does this netId actually resolve to something real"
instead of 6 independently-written (if consistently correct) copies.

**Order:** Now the single highest-value item remaining on this roadmap —
item 1 (its natural pairing) is done; do this next, still ahead of Phase 3
implementation start for the same reason item 1's "order" note gave.

#### 3. Consolidate the `Config.Peds` model-hash tables — no longer time-sensitive, still cheap

**Status change from Revision 1:** was "near-term, cheap, not blocking."
Confirmed over a full Phase 2 cycle that it isn't blocking anything and
hasn't grown a 4th copy. Keep the same proposed fix (expose
`IsEntityModelK9(entity)` from `client/main.lua`, delete
`client/movement.lua`'s local copy) — it's still a one-file, no-behavior-
change diff — but there's no more urgency argument for doing it before any
particular Phase 3 file; bundle it into whichever coder-architect pass
does items 1/2 as a cheap rider, rather than sequencing around it.
**Revision 3:** widen this item's scope to also cover
`K9_SIT_SCENARIO_BY_MODEL_HASH`/`K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH`
(see the Revision 3 note at the top of this document) when picked up — same
root cause (a `Config.Peds` model string hand-copied into another literal
table), slightly higher real-world payoff than the pure model-recognition
tables since this pair already desynced once.

### Medium-term

#### 4. Shared gated-cooldown-broadcast helper for `relayBark`/`relayDoorScratch` — downgrade from near-term

Confirmed the two broadcasts share a real tail shape, but the payoff is a
handful of lines at one call site, not a bug-prevention story — no
stamp-order or access-check bug occurred at either site without the
helper. Worth doing as a small bonus now that item 1's `NewCooldown`
exists (the broadcast tail becomes trivial to wrap around it), but not
worth sequencing ahead of item 2, and not worth a dedicated pass on its
own. Do **not** extend this to `BroadcastContrabandAlert` — that
broadcast's distance-filtering is a real, deliberate difference in scope
(leaking a specific target's search outcome vs. a location-only sound cue),
correctly kept separate in the shipped code, and should stay separate.

#### 5. `FindNearestEntity` — the 3rd occurrence has technically arrived, but shapes still diverge enough to wait

`server/tracking.lua`'s nearest-fresh-log-entry scan is related to but not
identical to `client/radial.lua`'s and `client/vehicle.lua`'s nearest-
entity scans (age-filtered log array vs. distance-filtered live entity
pool). A generic `FindNearestEntity(pool, maxDistance, predicate)` could
cover all three with an optional predicate parameter, but the payoff is
still modest (3 call sites, ~10-15 lines each). Reasonable to fold into the
same coder-architect pass as items 2-3 if it's cheap once that context is
loaded, but not worth a dedicated pass.

#### 6. `Config.LeashMaxDistance`'s triple-duty overload — unchanged, still not urgent

No change from Revision 1: still a deliberate Phase 1 default reused for 3
purposes across 3 files, still not touched by Phase 2, still the right
call to defer until a real Phase 3/4 feature needs to tune one use
independently of the others.

### Watch, don't act yet

- **`NotifyPlayer` duplication** — CLOSED as a concern. Stayed at 2 copies
  through all of Phase 2; the predicted 3rd/4th copies never happened
  because Phase 2's rejections are deliberately silent, not notified. Same
  for the predicted `SEARCH_REJECT_MESSAGES` mirror of
  `LEASH_REJECT_MESSAGES` — it was never written, because `server/search.lua`
  has no player-notified rejections to need it for. No action needed; note
  for the record that this resolved itself via a design choice, not a
  refactor.
- **`Config.Peds[].label` unused**, **trivial proximity one-liners**,
  **ox_target option-registration boilerplate** — unchanged from Revision
  1, not re-verified in depth this pass; no evidence Phase 2 made any of
  these worse.
- **Bare-global cross-file convention (Revision 1's medium-term item 6)** —
  unchanged reasoning: `phase2_notes/EXPORT_TRACKING.md` (item 5) is
  successfully tracking the growing global list; Phase 2 didn't add enough
  new globals to make a namespace-table rewrite worth the disruption.
  Revisit before Phase 3 (`PHASE3_SPEC.md`) starts adding its own globals,
  using the export-tracking doc to judge whether the list has gotten
  unwieldy — same trigger condition as before, just now one phase closer.

---

## Suggested delegation

- **coder-architect**: item 2 (now the top remaining item) and, as a cheap
  rider, items 3 and 5 — add `ResolveNetworkEntity` client- and
  server-side and migrate the 6 existing call sites, add `IsEntityModelK9`
  to `client/main.lua` and delete `client/movement.lua`'s local copy
  (widened per Revision 3 to also cover the two breed-to-scenario tables).
  Item 1 (cooldown/TTL/mutex) is done; no further action needed there
  beyond the periodic regression spot-check watchdog passes already do.
- **coder-backend**: reviewer/co-implementer on the server-side half of the
  above (main.lua, search.lua migrations) given the security-sensitive
  nature of several of these checks (search target type cross-check).
- **coder-frontend**: reviewer/co-implementer on the client-side half
  (main.lua, vehicle.lua, movement.lua, search.lua's
  `ResolveNetworkEntity` migration and `IsEntityModelK9` consolidation).
- **correctness-overseer / qa-tester**: item 2's migration is the same
  class of risk item 1's was — verify every migrated call site preserves
  the existing entity-type/proximity checks byte-for-byte, in particular
  `relayDoorScratch`'s entity-type restriction and `HandleSearchTarget`'s
  `targetType` cross-check, which must not get generalized away by a
  shared helper.
- **project-lead**: sequence item 2 ahead of `PHASE3_SPEC.md`
  implementation start for the same reason item 1 was sequenced ahead of
  it — Phase 3's `AgilityAdvanced` work (already landing as of this pass)
  is client-local and doesn't touch netId resolution, but `BiteAndHold`/
  `NonLethalTakedown`/`PropDragging` will, once PHASE3_SPEC.md §12.0 item 8
  is resolved.
