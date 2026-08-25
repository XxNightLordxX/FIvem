# qbx_k9unit — Technical Debt Roadmap, Pass 2

Written as a fresh audit alongside the existing `REFACTOR_ROADMAP.md` (not a
revision of it — that file's Revision 6 is left untouched, per instruction).
Every claim below was checked by reading the actual source at the paths
cited, not inferred from a grep count alone. Where a grep informed where to
look, the surrounding code was read before anything here was written down.

**Headline finding: this codebase is in noticeably better shape than the
brief's framing predicted.** The three debt clusters the brief specifically
asked about as likely trouble spots — hand-rolled notify functions,
hand-rolled cooldown tables, hand-rolled entity resolvers — are all
already consolidated and, as of this pass, still holding under continued
parallel-agent editing (re-verified directly, not assumed from
`REFACTOR_ROADMAP.md`'s own say-so; see "Re-verification" below). The
feature-flag surface, while large, is more disciplined than 40 independent
booleans usually are: every place a real interdependency exists between two
flags, the code enforces it with a runtime existence guard or an explicit
compound check, not just a comment asking the operator to remember. The test
harness is well-factored, not ad hoc. What debt remains is small, cheap, and
mostly documentation catching up to code that has already been fixed —
which is itself a real and recurring pattern worth naming precisely, not
papering over.

This is a **six-item roadmap**, not a thirty-item list, because that is
roughly how much real, actionable debt a direct read turned up.

---

## Re-verification of the three "likely cluster" claims

- **Cooldowns**: grepped for the exact hand-rolled shape `server/cooldowns.lua`
  replaced (`local <x>At = {}` tables, raw `GetGameTimer()` delta comparisons
  outside `server/cooldowns.lua` itself) across every `client/*.lua` and
  `server/*.lua` file as of this pass. Zero matches. Holding.
- **Entity resolvers**: zero raw `NetworkGetEntityFromNetworkId` call sites
  outside `server/entities.lua`'s/`client/main.lua`'s own function bodies
  remain (confirmed via `client/propattachment.lua`, the one file
  `REFACTOR_ROADMAP.md` had flagged as a fresh regression of this pattern —
  it now calls `ResolveNetworkEntity(netId)` directly at
  `client/propattachment.lua`'s attach handler, matching every other
  consumer). Holding.
- **NotifyPlayer**: `server/notify.lua:150` is the single shared
  implementation. `server/admin.lua:331` and `server/bonetool.lua:234` keep
  a one-line local wrapper (different player-visible title per subsystem),
  each explicitly calling `_G.NotifyPlayer(...)` — read both directly,
  confirmed neither redefines the notify body itself, just forwards to it.
  This extraction (item 3 in `REFACTOR_ROADMAP.md`'s near-term list) is
  **done**, not merely "cheap, do opportunistically" as that document still
  frames it — worth flagging to whoever owns that file next so it isn't
  re-queued as outstanding work.

---

## Item 1 (near-term): the one real remaining duplicate of the `DenyK9UIAccess` pattern, plus the stale comment describing it

**What's wrong.** `client/main.lua:184` defines the shared
`DenyK9UIAccess()` global specifically to end a *different* instance of the
same duplication class the brief asked about — a `lib.notify({...
common.no_k9_access ...})` call that the function's own header (lines
177-183) says was "previously duplicated verbatim across
client/radial.lua, client/search.lua, and client/vehicle.lua
(client/movement.lua and client/tracking.lua also have their own copy, out
of scope for this pass — left as-is)."

Checking that claim directly against the current tree:

- `client/movement.lua:404-406` now calls `DenyK9UIAccess()` — this file
  **has already been migrated**, contradicting the comment that still lists
  it as an unmigrated holdout.
- `client/tracking.lua:186` still has the raw, un-migrated copy:

  ```lua
  -- client/tracking.lua:180-188
  local function StartTrack(trackType)
      if not CanShowK9UI() then
          -- Reuses common.no_k9_access rather than minting a duplicate — this
          -- exact string was flagged for reuse by locales/README.md's
          -- "common.no_k9_access promotion" note, confirmed by grep before
          -- this pass ever touched this file.
          lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
          return
      end
  ```

**Why it matters.** This is a small-scale live instance of exactly the
"comment drifts from the code it describes" failure mode the brief asked to
watch for, caught in the wild rather than hypothesized. It costs little
today (both forms produce an identical toast), but a comment that says "2
files still need this" when only 1 does will send the next agent to
re-check a file that's already fixed, and — worse — may cause someone to
"fix" `client/movement.lua` a second time or skip `client/tracking.lua`
because the header made it sound like parallel, equally-unmigrated work.

**The change.** Two mechanical edits:
1. `client/tracking.lua:186` → replace the inline `lib.notify({...})` call
   with `DenyK9UIAccess()`.
2. `client/main.lua:180-181` → drop `client/movement.lua` from the "still
   has their own copy" list (it's migrated) and update the sentence to name
   only `client/tracking.lua` as the remaining holdout — or, once step 1
   lands, delete the parenthetical entirely.

**Scope/risk.** Trivially small — one call-site swap, one comment edit,
same file family, no config/manifest/schema touched. Behaviorally
identical (both paths call the same `lib.notify` with the same locale
keys). Essentially zero risk.

**Order.** First — it's the cheapest possible fix in this entire roadmap
and directly closes out a consolidation that is already 80% done.

---

## Item 2 (near-term): `tests/README.md`'s coverage table is one spec file behind the actual suite

**What's wrong.** `tests/README.md` states "118 test cases total across 7
spec files" and its coverage table lists exactly 7 files
(`cooldowns`, `admin`, `progression`, `entities`, `notify`, `tenure`,
`search`). Reading the `tests/` directory directly shows **8** `*_spec.lua`
files — `tests/exports_spec.lua` exists, is dated to this same audit window
(its own header says "following a security audit pass (2026-08-25)"), tests
both `server/exports.lua`'s 9 exports and `client/exports.lua`'s 18 exports
against the real production files, and appears nowhere in the README's
table or file count.

**Why it matters.** `tests/run.sh` is glob-based (`for spec in
*_spec.lua`), so the suite itself is not broken — `exports_spec.lua` runs
fine today. The cost is purely to the next reader: this resource's entire
public cross-resource export surface (the one thing other resources
actually call) now has real test coverage, and the one document whose whole
job is to tell a reader what's covered doesn't mention it. This is the same
class of drift as item 1, in a doc file instead of a code comment — a
correctly-landed fix whose paper trail didn't keep up, which
`REFACTOR_ROADMAP.md`'s own "single highest-value thing to do right now"
section already identified as this codebase's most expensive recurring
failure mode.

**The change.** Add an `exports_spec.lua` row to the coverage table (what's
tested / how reached — its own header already states this clearly), and
correct "7 spec files" / "118 test cases" to the real current numbers.

**Scope/risk.** One markdown file, no code touched. Zero risk.

**Order.** Second — same cheap-and-mechanical shape as item 1, bundle
both into one small documentation-sync pass.

---

## Item 3 (medium-term): a first, narrowly-scoped client-side spec, not a wholesale push

**What's wrong / the gap.** `tests/README.md` correctly and honestly
discloses that `client/*.lua` has zero test coverage, and gives a real
reason: every client file calls heavy natives (`GetEntityCoords`,
`DisableControlAction`, ped/camera natives, NUI messaging) with no
server-side equivalent to sandbox against, "no client file currently has
anything as isolable as `NewCooldown` or `ResolveTier`." That claim is true
for the *large* client files (`client/movement.lua`, `client/combat.lua`,
`client/radial.lua`) — but it is not true of `client/main.lua`'s own small
cluster of pure-logic resource-globals: `IsEntityModelK9`, `IsOwnModelK9`,
`HasK9Access`, `CanShowK9UI`, `DenyK9UIAccess` (read directly at
`client/main.lua:100-186`). Their only native/global dependencies are
`GetHashKey`, `GetEntityModel`, `PlayerPedId`, `GetGameTimer`,
`lib.callback.await`, and `lib.notify`/`locale` — every one of which is
already stubbed in some form by the existing server specs' sibling
patterns (`fixtures/sandbox.lua` already builds exactly this shape of
override table for `Sandbox.newEnv`).

**Why it matters.** This is genuinely the cheapest possible way to convert
"client is untestable" from a blanket, resource-wide statement into a
narrower, accurate one — proving out that the *sandbox pattern itself*
(not just the specific natives `server/*.lua` happens to need) generalizes
to `client/*.lua`, which the current README doesn't establish either way
because nobody has tried it on the easiest possible target yet. It would
also give real regression coverage to the exact TTL-cache/debounce logic in
`HasK9Access` (`HAS_K9_ACCESS_CACHE_TTL_MS`) that every hot ox_target
`canInteract` predicate in this resource depends on.

**The change.** One new `tests/main_spec.lua`: `Sandbox.newEnv` with stubs
for the five natives above (a `lib.callback.await` stub that returns a
controllable boolean, a fake `Config.Peds`-driven model set), then
`Sandbox.loadInto('../client/main.lua', env)`, then assert on
`env.IsEntityModelK9`/`env.HasK9Access`/`env.CanShowK9UI` directly — same
shape as `entities_spec.lua` already uses for `server/entities.lua`'s
`ResolveNetworkEntity`. This does **not** attempt to load `client/main.lua`
in full if later sections of that file need natives not worth stubbing for
this pass (the file's own top section, before the placeholder-sound code at
line ~188, is the target); if something below the target functions forces
disproportionate stubbing, stop there and say so in the spec's own header,
matching this suite's existing "disclose the gap, don't force it" rule.

**Scope/risk.** One new test file, zero production code changes (this
suite's own rule 6: "never edit the production file to make it more
testable"). Zero risk to shipped behavior.

**Order.** Third — do this once items 1-2 are landed and before proposing
any *broader* client coverage push, since its real value is answering "does
the sandbox pattern generalize to client/" before committing more effort on
that assumption.

---

## Item 4 (medium-term): `server/tenure.lua`'s disclosed cache/header mismatch

**What's wrong.** This is not a new finding — `tests/README.md`'s own
"What's NOT covered, and why" section already discloses it, and a test
(`tenure_spec.lua`'s own `DISCREPANCY:`-tagged case) already locks in the
real behavior — but it has sat disclosed-and-unfixed since the suite found
it, and re-reading `server/tenure.lua` directly confirms it is still true:
the `TenureFullyCollected` local cache's own header comment claims it is
"a per-process, in-memory SKIP-CACHE to avoid re-running the SELECT below
every tick," but the cache is keyed by `row.id`, which is only known
*after* the same `MySQL.single.await` SELECT it's meant to skip has already
returned. The SELECT runs every tick regardless of cache state.

**Why it matters.** Read in isolation this is a one-file, bounded
performance cost (one extra indexed SELECT per online, fully-tenured K9 per
`checkIntervalMs` tick — not a correctness bug; the real double-grant
protection is the persisted `tenure_bonus_tier_granted` column's
optimistic-UPDATE guard, separately confirmed still holding by the same
spec). What makes it worth a line in this roadmap rather than "watch, don't
act" is that it is a second, independent instance of the exact
header-claims-something-the-code-doesn't-do pattern item 1 above is — just
inside a code file's header this time instead of a doc file — and it has
already been sitting disclosed, with a fix suggested (re-key the cache on
`k9Citizenid`, which is known before the SELECT, instead of `row.id`,
which isn't), without anyone acting on it.

**The change.** Either (a) re-key `TenureFullyCollected` on `k9Citizenid`
so it actually skips the redundant SELECT, or (b) if there's a reason not
previously written down that `row.id`-keying is intentional, correct the
header to say what the cache actually does. Either is a same-file, few-line
change with an existing test already asserting the current behavior (so a
real fix will make that specific `DISCREPANCY:` test's assertion need
updating in the same commit — expected, not a regression).

**Scope/risk.** One file (`server/tenure.lua`), one already-tightly-scoped
test file to update alongside it. Low risk — the double-grant guarantee
this feature actually depends on lives in the SQL UPDATE...WHERE guard, not
this cache, so getting the cache's skip logic right or wrong cannot
reintroduce a double-grant either way.

**Order.** Fourth — bundle with item 3 or do it whenever `server/tenure.lua`
is next opened for any reason; not worth a dedicated pass on its own.

---

## Watch, don't act yet

- **`WATCHDOG_LOG.md`'s per-feature table, `PropDragging` row.** Line ~982
  still reads "`RequestDrag`/`ReleaseDrag`/`IsDragEngaged` have zero callers
  anywhere at `HEAD` (grepped)." That's now false — `client/radial.lua:608-623`
  wires a real "Drag / Release" radial option that calls both. This is *not*
  a fresh discovery: the same document's own later entry (~line 1001-1017)
  already flagged this exact gap as "in flight, not yet landed as of this
  pass's last check" and named the precise diff that would close it. That
  diff has since landed. This needs one more line-edit whenever whoever owns
  `WATCHDOG_LOG.md` next touches it — not urgent, since the document already
  contains its own correct forward pointer to the fix, so no reader following
  the document's own trail gets misled. Not promoted to an active item
  because it's a documentation-only, already-self-tracked gap, not new debt.
- **The `Config.Features` surface (40 flags, 5 default-`true`).** Read the
  full block at `config.lua:24-164` directly rather than trusting the
  count: confirmed exactly 40 leaf flags, exactly 5 `true`
  (`LeashMechanics`, `RadialMenu`, `VehicleEntryExit`, `BasicBarkSounds`,
  `AgilityBasicJump`). Checked every place a real cross-flag dependency is
  *documented* in a comment for whether it's *enforced* in code, not just
  asked of the operator:
  - `HandlerDownDefense` reading partnership state: `server/defense.lua:206-216`
    guards the accessor call with `type(GetActivePartnerCitizenId) ==
    'function'`, and the comment there explicitly notes it degrades to a
    silent no-op if `HandlerPartnership` is off or `server/partnership.lua`
    isn't loaded — verified this is a real runtime guard, not a comment
    asking the operator to remember to also flip `HandlerPartnership`.
  - `Recall`'s termination path deliberately does **not** gate on
    `HasK9Access`/`CanShowK9UI` on either party (`server/recall.lua:35-49`)
    — read this specifically because the brief asked not to propose
    anything that would weaken a "no unbounded trap" escape path, and
    confirmed this is exactly that kind of load-bearing gate, not an
    oversight to "fix."
  - `PartnershipTenureBonus` is double-gated on `HandlerPartnership AND
    XPProgression AND PartnershipTenureBonus` at both file-load time
    (`server/tenure.lua:556`) and inside its own polling thread
    (`server/tenure.lua:529`) — the one place three flags really are
    interdependent, and the interdependency is enforced twice, not once.

  **Conclusion: no action.** This is a large flag surface, but every real
  interdependency found was enforced in code via a runtime guard or a
  compound check, not left to operator memory — the opposite of the failure
  mode the brief was checking for. Restructuring 40 independently-gated
  flags into a nested/grouped config shape (e.g. per-phase sub-tables) would
  touch every one of the ~30 files that reads `Config.Features.X` for a
  purely organizational win with real risk of breaking a gate check
  mid-edit — exactly the "restructuring for its own sake" this task asked
  not to propose. Leave it.
- **File header length** (`server/combat.lua`, `client/combat.lua`,
  `server/partnership.lua` at 200+ header lines each). Independently spot-
  read `server/notify.lua`'s and `server/defense.lua`'s headers this pass
  (not previously quoted in `REFACTOR_ROADMAP.md`) as a fresh check rather
  than trusting that document's own "zero contradictions found" claim —
  both carry the same FILE-TO-FILE CONTRACT / trust-boundary-reasoning
  shape, and both matched current code exactly (`server/defense.lua:256`'s
  gate, `server/notify.lua:150`'s signature). No new evidence to add;
  agrees with the existing roadmap's "do not trim" call.

## Explicitly not worth doing

- **Consolidating `#(GetEntityCoords(a) - GetEntityCoords(b))`.** Found 17
  occurrences across 12 files (`server/partnership.lua`, `server/wellbeing.lua`
  x2, `server/tenure.lua`, `client/audio.lua`, `server/main.lua` x2,
  `server/fetch.lua` x2, `server/defense.lua`, `server/inventory.lua`,
  `server/medkit.lua`, `server/combat.lua` x2, `server/search.lua`,
  `server/certifications.lua` x2). This is a single-line idiomatic
  expression, not a hand-copied function — no per-site logic to drift
  (unlike `NotifyPlayer`'s title/type parameters before extraction), and a
  `DistanceBetween(a, b)` wrapper would trade one arithmetic expression for
  one function call with no correctness or maintenance benefit. Same
  category the existing roadmap already correctly rejected for the
  `GetPlayers()`-iteration idiom.
- **Consolidating `Player and Player.PlayerData and Player.PlayerData.citizenid`.**
  Found 40+ occurrences. Spot-checked several (`server/certifications.lua:224`,
  `server/progression.lua:570`, `server/main.lua:310`) — in every case
  checked, nil is already ruled out by a preceding guard, so the "unsafe-
  looking" bare-access variants seen elsewhere are not actually unsafe, just
  stylistically different from the defensive-chain variants. No live
  inconsistency, and most call sites already have `Player` in scope from an
  earlier line for an unrelated reason, so a wrapper function would often
  cost a second lookup rather than save one. Not worth acting on.
- **Broader client-side test coverage beyond item 3's single starter
  spec.** `client/movement.lua`/`client/combat.lua`/`client/radial.lua`
  are correctly assessed by `tests/README.md` as a much larger stubbing lift
  for comparatively little isolable pure logic — confirmed by reading
  `client/movement.lua`'s structure (leash/sit/door-scratch/agility gating
  is interleaved with per-frame control-disable natives throughout, not
  segregated into a testable pure core). Accept this as a real boundary,
  not a rewrite target.

---

## Ranked order

1. Fix `client/tracking.lua:186`'s remaining `DenyK9UIAccess` copy + correct
   `client/main.lua`'s stale "2 files left" comment. *(trivial, do first)*
2. Sync `tests/README.md`'s coverage table to include `exports_spec.lua`
   (8 files, not 7). *(trivial, bundle with #1)*
3. Add `tests/main_spec.lua` covering `client/main.lua`'s pure-logic globals.
   *(small, proves out client-side testability on the easiest real target)*
4. Fix or correctly re-document `server/tenure.lua`'s `TenureFullyCollected`
   cache. *(small, already scoped by an existing test)*
5. *(watch only)* `WATCHDOG_LOG.md`'s `PropDragging` row — one line, whenever
   that file is next touched.
6. *(watch only)* `Config.Features` surface — confirmed maintainable as-is;
   re-assess only if a future flag's interdependency is found *not* to have
   a runtime guard, which was not the case for any flag checked this pass.

## Which `REFACTOR_ROADMAP.md` items are now done

Cross-checked against this pass's own independent reads, not copied from
that document's own status lines:

- **Item 1 (cooldowns)** — confirmed still DONE and durable.
- **Items 2/2b (entity/player resolvers)** — confirmed still DONE, including
  the one regression that document tracked (`client/propattachment.lua`) —
  confirmed fixed and registered in `fxmanifest.lua`.
- **Item 3 (`IsEntityModelK9` consolidation)** — confirmed DONE.
- **`NotifyPlayer` extraction** — confirmed DONE (this document's near-term
  item 3 can be marked complete, not merely "do opportunistically").
- **`fxmanifest.lua` registration gap** (propattachment/bonetool/fetch pairs)
  — confirmed resolved.
- **`WATCHDOG_LOG.md` feature-table refresh** (near-term item 1) — mostly
  done; the `HandlerDownDefense`/`Recall` rows were corrected via an
  appended note, but the `PropDragging` "zero callers" line is now stale
  again for an unrelated, later reason (see "Watch, don't act yet" above) —
  that document's own text already anticipates this, so it's a one-line
  follow-up, not a reopened item.
- **Medium-term/watch items** (combat.lua size, `FindNearestEntity`-shape
  consolidation, `Config.LeashMaxDistance` overload) — no new evidence this
  pass; the existing "defer" calls still hold.

## Overall read

This codebase's cited debt-generating pattern (parallel agents each
hand-rolling the same helper) did happen here, exactly as expected — but it
was caught and fixed at each of the three points the brief predicted, and
those fixes are holding under continued concurrent editing rather than
silently regressing. The actual live cost right now is almost entirely in
the second-order problem `REFACTOR_ROADMAP.md` itself already named as the
most expensive one: a correct fix landing in code faster than the
comment/doc describing it gets updated. This pass found three fresh,
concrete instances of exactly that (the `DenyK9UIAccess` header, the tests
README's spec count, `WATCHDOG_LOG.md`'s `PropDragging` line) and zero
instances of unfixed duplicated logic, unenforced flag interdependencies,
or a test harness that doesn't scale. That is a good sign for this
resource's maintainability, not a gap in this audit — the roadmap above is
short because there genuinely isn't much load-bearing debt left to find.
