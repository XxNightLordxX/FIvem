# qbx_k9unit — Whole-Project Status Assessment (project-lead pass)

Author: project-lead (whole-project oversight pass), read-only on code.
Written 2026-08-25, against commit `fb797e2` ("Close the bite-and-hold XP
farm; drop a sixth silent no-op native"), 154 commits on
`claude/code-improver-subagent-qlt3bn`. **This repo is being edited by
~20 parallel agents right now and a new commit landed between two of my own
`git log` calls during this pass** — treat every number below as a snapshot
of `fb797e2`, not a durable fact, and re-run the checks in §0 before trusting
this document if much time has passed. A prior `PROJECT_STATUS.md` existed
at this path (dated 2026-08-24, last touched 03:09) and is superseded by
this one — it was already ~30 commits stale by the time I started (its own
top section already carried a "documentation sync correction" patching
itself for the same reason).

I did not edit any `.lua`/config/manifest/locale file. I did read full file
contents (not grep-only) for every claim below unless explicitly marked as
re-stated from a document rather than independently checked.

---

## 0. Ground truth, verified directly this pass

- **154 commits** on this branch (`git log --oneline | wc -l`).
- **Working tree is not clean**: 7 modified files, all uncommitted, all
  in-flight edits by (presumably) one other active agent right now —
  `client/medkit.lua`, `server/bonetool.lua`, `server/defense.lua`,
  `server/inventory.lua`, `server/kennel.lua`, `server/wellbeing.lua`,
  `sql/migrations/0004_add_k9_certifications_active_cert_key.sql`. I read
  the diffs: these are small, well-reasoned, disclosed defect-sweep edits
  (e.g. the migration diff reorders steps so the two non-conflicting
  indexes land even if the unique-key step fails on a dirty database; the
  wellbeing diff upgrades a native-confidence grading from "medium-high,
  unverified" to "confirmed against citizenfx/fivem's own native-decls").
  This is **not** the same risk class the prior `PROJECT_STATUS.md` flagged
  (ten complete-but-orphaned feature files with no commit) — it's normal,
  bounded WIP from an agent mid-edit. Still worth a `git status` glance
  before assuming it's landed.
- **Exactly 40 `Config.Features` flags**, read directly line-by-line from
  `config.lua` (not a regex — a prior pass documented two separate
  mis-counts caused by naive character-class regexes missing digit-bearing
  names like `K9Inventory`). **5 `true`** (`LeashMechanics`, `RadialMenu`,
  `VehicleEntryExit`, `BasicBarkSounds`, `AgilityBasicJump`), **35 `false`**.
- **All 47 `.lua` files on disk are referenced in `fxmanifest.lua`**: I
  counted 25 `client/*.lua` files on disk and 25 corresponding
  `client_scripts` entries; 22 `server/*.lua` files on disk and 22
  corresponding `server_scripts` entries. "Built but not wired" is
  genuinely not a category in this resource right now.
- **`luacheck . --config .luacheckrc`: 0 warnings / 0 errors across 58
  files** — I ran this myself, not read a claim of it. **`luac5.4 -p`
  parses every `.lua` file clean** — also run myself.
- **`tests/run.sh`: ALL 8 SPEC FILES PASSED** — I ran the suite myself.
  `tests/` holds `admin_spec.lua`, `cooldowns_spec.lua`, `entities_spec.lua`,
  `exports_spec.lua`, `notify_spec.lua`, `progression_spec.lua`,
  `search_spec.lua`, `tenure_spec.lua` (8 files, confirmed by `ls`).
- **27 public exports**: `grep -c '^exports('` gives 9 in `server/exports.lua`
  and 18 in `client/exports.lua` = 27, and `tests/exports_spec.lua` (read in
  full) genuinely exercises both files' type/nil/pcall guards against the
  real production files via a sandboxed env, not a re-implementation.
- **`locales/en.json`: 223 leaf keys** across 23 top-level namespaces —
  counted with a small script that recurses the actual JSON structure, not
  a line count (271 lines includes braces/whitespace).
- **The "four server-side death gates never fired" claim, read in full at
  the source**: `server/combat.lua` and `server/medkit.lua` both carry
  detailed comments (with citizenfx/fivem file-path citations) showing
  `IsEntityDead`/`IsPedDeadOrDying` have no `RegisterNativeHandler` call
  anywhere in `ServerGameState_Scripting.cpp`, so every prior call to them
  server-side silently returned `false` forever. The fix (`da474e0`)
  replaced them with `GetEntityHealth(ped) <= 100`, and the code comment
  explains *why* 100 and not 0 (GTA's ped-death convention, corroborated by
  this same resource's own `NonLethalTakedown.healthFloor = 100`) — a
  substitution that could easily have been "fixed" into a second, subtler
  no-op (`<= 0`) had the choice not been deliberate. The very latest commit
  (`fb797e2`, landed as I was reading) found and removed a **sixth**
  instance of the same class: a server-side `SetEntityHealth` call that
  also has no server registration, removed rather than left as
  "reassuring dead code" once traced.

---

## 1. Phase-by-phase status — implemented / implemented-but-disabled / never-built, kept distinct

**Phase 1 (vertical slice) — done, live, re-verified.** `LeashMechanics`,
`RadialMenu`, `VehicleEntryExit`, `BasicBarkSounds`, `AgilityBasicJump` all
ship `true`. `WATCHDOG_LOG.md` has re-spot-checked five specific regression
points every single pass since Pass #1 (the `AgilityBasicJump` file-scope
gate, role-aware `LeashPairs` writes, `RevokeCertificationOffline` calling
`RefreshCertificationCache`, `client/vehicle.lua`'s `onResourceStop`
cleanup, the `lib.registerRadial`/`lib.addRadialItem` split) — I did not
re-run all five myself this pass (time budget), but the discipline of
re-checking code, not comments, each time is itself a good sign, and none
of the seven uncommitted diffs in §0 touch any of those five files.

**Phase 2 (tracking/search/vision/door) — implementation-complete, ships
false.** Every leaf flag (`ScentTracking`, `BloodTracking`,
`WaterTrackingDecay`, `GunpowderSniffing`, `SearchZones`,
`ContrabandAlerts`, `ThermalVision`, `NightVision`, `DoorInteraction`) has
real, reviewed client+server code and is registered. This is correctly
*disabled-pending-review*, not incomplete — `DECISIONS_NEEDED.md` and
`OPERATOR_RUNBOOK.md` both independently name this as the lowest-risk group
to enable first, for the same reason (read-only w.r.t. other players, most
re-reviewed subsystem in the resource). `ScentTracking` specifically still
needs a one-time live-payload check against a real `ox_inventory` install
(§5 below).

**Phase 3 (combat/action) — code-complete for all six mechanics, all
disabled by design.** `BiteAndHold`, `NonLethalTakedown`,
`HandlerDownDefense`, `PropDragging`, `AgilityAdvanced`, plus `Recall` (the
handler's "call the dog off" escape hatch) and `HandlerPartnership` (the
prerequisite registry) are all implemented and reachable via the "K9 Unit"
radial menu. This is a genuinely mature phase from a build-completeness
standpoint; every disabled flag here is a deliberate go-live gate, not a
missing feature. Six separate XP-farming exploits have been found and
closed against this phase and Phase 4 across this session (track-source,
contraband-search, a third unnamed one, `NonLethalTakedown`'s target
cooldown, a fifth alongside a cert race, and — in the very latest commit —
`BiteAndHold`'s own re-take-same-target loop). I read the `fb797e2` commit
message and diff directly: it is real and specific (a targetNetId-keyed
cooldown, checked before either cooldown is stamped), not a restatement.

**Phase 4 (inventory/progression/vitality) — code-complete, ships false.**
`K9Inventory`, `XPProgression`, `HealthStaminaHUD`, the five-stat wellbeing
system (`FatigueSystem`/`MoodSystem`/`FearStressSystem`/
`DistractionSystem`/`InjuryLimping`), `K9Medkit`, and `ContrabandScreenFX`
all have real code and are registered. `ContrabandScreenFX`'s timecycle
modifier name bug (`drug_wobbly_shroom` doesn't exist; only `drug_wobbly`
does — confirmed against a real timecycle-data extraction) is fixed. Two
real numeric defects (the dead flat `scentRange` floor that never exceeded
`maxRange`, and the farmable contraband-search XP) are both fixed in code;
what's left is tuning the replacement numbers, not closing a gap.

**Phase 5 (audio/props/camera R&D) — mixed, and this is the phase where
"implemented but disabled" and "specified and never built" genuinely
coexist rather than one masquerading as the other.** `DeployableKennel`,
`AdvancedBarkRadial`, `ProximityAudioFX`, `PropAttachments`, and
`FetchMechanic` are all real, reviewed, registered code shipping `false`.
`PropAttachments`/`FetchMechanic` are functionally complete but ship a
placeholder attach point (root bone, index 0) until an operator runs the
dev-only `client/bonetool.lua`/`server/bonetool.lua` sweep — this is
disclosed as a polish gap, not a safety or correctness one. **The bark/
ambient audio itself is genuinely unbuilt in the sense that matters to a
player**: `html/sounds/` contains only `CREDITS.md` — I listed the
directory myself. No `.ogg`/`.wav` file exists anywhere in the resource.
Every bark and the proximity-audio ambient sound resolves to a silent
no-op by design, not a bug, pending a licensing decision only the server
owner can make (§4, D7). `CameraFeedPiP` is the one flag in the whole
table with **zero** implementing code, and correctly so — confirmed
independently this pass (see §5) that citizenfx/fivem issue #3835 is still
open, unlabelled as resolved, with no linked PR, and no native exists that
goes the direction this feature would need (render a second camera into an
NUI/DUI texture; the only native going that direction,
`CreateRuntimeTextureFromDuiHandle`, goes the opposite way).

---

## 2. Drift from spec

I read the actual divergence write-ups against the actual shipped code for
the three previously-flagged divergences (`HandlerDownDefense`'s
attacker-identity assumption, `ContrabandScreenFX`'s file-location, the
tenure bonus's file-scope narrowing) and they hold up: all three are
disclosed, reasoned re-routings around a spec assumption that didn't
survive contact with actual file ownership/data availability, not silent
misses. I did not find a new instance of silent drift this pass.

**On the one settled, non-relitigable decision (K9 combat is PvP by
explicit owner choice, not NPC-only):** I read `DECISIONS_NEEDED.md`'s D2
in full and the combat code's own trust-boundary comments. The
implementation is consistent with the PvP decision — Category B combat
effects (movement restriction, forced ragdoll, damage suppression) are
built to apply against *any* target including a player, with the
documented, disclosed consequence that a modified client can decline them,
and the project's own text is explicit that "no code change fixes this."
I found no drift back toward an NPC-only model anywhere in the currently
shipped or in-flight code — `RequireWantedStatus`'s player-targeting gate
and the NPC-relay code path both exist side by side, exactly as the PvP
decision implies they should.

---

## 3. Readiness — what has to be true before enabling each disabled group

`OPERATOR_RUNBOOK.md` (new, read in full) is genuinely good and covers most
of this ground concretely: install order including all 4 SQL migrations
with a specific warning about what skipping migration 0004 silently allows
(two simultaneously-active certifications for one citizenid/job with no
error), a sequenced (not naive) test for the client-event origin guard, and
a per-flag "what to check before flipping this" section for `ScentTracking`,
`PropAttachments`/`FetchMechanic`, and `DeployableKennel`.

**Where it is thin:**

- It does not mention the numeric placeholders in `Config.XPTiers`
  (scentRangeMultiplier 1.00/1.05/1.10/1.20) or
  `Config.ContrabandAlertTiers` (minWeight 1/250) as needing a
  server-specific economy pass before go-live, even though
  `DECISIONS_NEEDED.md` explicitly frames these as "tune the numbers if you
  want a bigger effect" rather than settled. An operator following only the
  runbook could enable Phase 4 XP/tiers with numbers nobody outside this
  session's own placeholder judgment has looked at.
- It gives no guidance on the **order** to enable flags *within* a phase
  when a cross-flag interaction exists — e.g. it correctly tells you to fix
  `Config.SearchContrabandItems` item names before enabling `SearchZones`,
  but doesn't call out that enabling `SearchZones` + `ContrabandAlerts` +
  `XPProgression` together is exactly the combination the now-fixed D5 XP
  farm depended on, so re-verifying that fix (not just trusting the
  changelog entry) before flipping all three together on a live server
  would be a reasonable extra step for an operator to take, and the runbook
  doesn't prompt it.
- It has no equivalent "sequenced check" section for the newest fix
  (`fb797e2`'s `BiteAndHold` target cooldown, landed after the runbook was
  last touched at 03:30) — reasonable, since it's newer than the runbook,
  but a live gap right now if someone reads the runbook today and assumes
  it's current on every combat-adjacent gotcha.
- It doesn't mention the six-and-counting silent-no-op-native pattern
  (`IsEntityDead`/`IsPedDeadOrDying`/`SetEntityHealth`, all found this
  session) as a standing reason to be skeptical of any *other* uncommon
  native this resource calls server-side that isn't already flagged — that
  framing exists in `WATCHDOG_LOG.md`/commit messages but not in the
  operator-facing document.

None of this is a defect in the runbook — it does what it says it does
(step-by-step install + the two highest-value dev checks) — but an operator
relying on it alone would still be missing the "these numbers are
placeholders" and "these two fixes are very recent, re-confirm before
trusting" framing that `DECISIONS_NEEDED.md` carries.

---

## 4. Open decisions — read `DECISIONS_NEEDED.md` in full; my read on each

- **D1 (which tranche to enable)** — genuinely open, correctly framed as
  the owner's call, not overtaken by events.
- **D2 (Category B combat / modified-client limitation)** — genuinely open
  and **not** a decision that further engineering closes; correctly framed
  as a platform property with no third option. Not relitigating the PvP
  choice itself (settled, per the brief) — this is the narrower, still-open
  "accept the enforcement gap or don't ship these three flags" question.
- **D3 (client-event origin guard, fail-open concern)** — genuinely open,
  and I made two small, honest, non-conclusive contributions to it this
  pass rather than closing it (see §5). Still needs the sequenced in-engine
  test `OPERATOR_RUNBOOK.md` §3 describes; nobody has run it as of this
  commit.
- **D4/D5 (XP tier multiplier, contraband-search farm)** — both **closed as
  code defects**, correctly described in `DECISIONS_NEEDED.md` as "tune the
  numbers if you like" now, not blocking anything. My own read agrees:
  these are resolved, not open.
- **D6 (ox_inventory swapItems hook)** — **partially closed**, and I did
  not re-derive this myself this pass (a prior pass already did the
  upstream-source fetch and field-match); `DECISIONS_NEEDED.md`'s own
  framing ("run it as a formality, not because there's a live open
  question") reads as accurate based on what I could check. Still requires
  an actual live-server run before `ScentTracking` should go live — that
  part is not overtaken by any amount of source-reading.
- **D7 (bark audio licensing)** — genuinely open and correctly scoped to
  three real options now (CC BY-SA / OGA-BY / commission-or-silence); I
  independently confirmed via `ls html/sounds/` that nothing has been
  fabricated or silently added since this was written — the directory
  still holds only `CREDITS.md`.
- **D8 (bone-index sweep)** — genuinely open, correctly described as
  polish rather than a blocker; nothing to add.
- **D9 (kennel prop model)** — I noticed this document is slightly behind
  the actual code: `DECISIONS_NEEDED.md`'s D9 doesn't mention that
  `prop_doghouse_01` was already refuted and replaced with
  `prop_dog_cage_01` (`a65dd5d`, "Refute the kennel prop model") — I
  confirmed this against `git log` and the commit's own reasoning (a
  5,171-entry object database with real screenshots has an entry and a
  real screenshot for the new model, and a 404 for the old one). This is a
  minor, low-stakes doc lag (the D9 recommendation — "eyeball it on a dev
  server" — is unaffected either way), but worth a one-line correction the
  next time this file is touched.
- **D10 (complementary work)** — the top three (export API, admin/audit
  surface, tenure bonus) are described as done; I independently confirmed
  all three exist, are registered, and are lint-clean. Accurate.
- **D11 (dependency version pinning)** — I did not re-derive the core
  claim (FiveM's dependency block has no version-constraint syntax) myself
  this pass; this requires cloning/reading citizenfx/fivem's C++ resource
  loader, which I did not have a specific reason to re-check (no drift
  signal), and time was better spent on the two facts in §5 that had an
  actual "sharpened" or "re-check this" flag attached. Flagging as
  **not re-verified this pass**, consistent with the prior pass's own
  honest disclosure of the same gap.
- **D12 (version cut)** — still open, still `0.1.0`, still reasonable to
  defer until D1.

---

## 5. Externally-dependent facts — what I checked this pass, with real results

I had `raw.githubusercontent.com`, GitHub issue pages, and general web
search reachable this session (unlike some prior passes, which reported
`github.com` blocked) — so I used that reach on the two facts the task
specifically flagged as highest-risk of going stale, rather than restating
what earlier passes already found.

**`IsEntityDead`/`IsPedDeadOrDying`/`SetEntityHealth` have no FXServer
server registration.** I independently fetched
`citizenfx/fivem`'s live `master`
`code/components/citizen-server-impl/src/state/ServerGameState_Scripting.cpp`
and searched it for `RegisterNativeHandler` calls naming `IS_ENTITY_DEAD`,
`IS_PED_DEAD_OR_DYING`, `SET_ENTITY_HEALTH`, and `SET_PED_HEALTH`: **none
of the four are present**, while `GET_ENTITY_HEALTH` and two other health
getters are. I also confirmed `SetEntityHealth.md` and `IsEntityDead.md`
return 404 on `citizenfx/fivem`'s `ext/native-decls/` path (no doc page at
all), consistent with — though not by itself proof of — the "not
registered" finding. **This corroborates the project's own claim from an
independent read this pass**, not just a re-statement of the commit
message. Residual uncertainty: I checked one registration file, the same
one the project's own commits cite as authoritative; I did not rule out a
second, separate registration site for any of these four names elsewhere
in the monorepo, though the fact that `GET_ENTITY_HEALTH`'s companion
registrations sit in the exact same file is reasonable (if not airtight)
evidence that a `SET_ENTITY_HEALTH` registration, if one existed, would be
adjacent to it.

**Camera-feed PiP (issue #3835).** Independently confirmed via a live
fetch of the issue page: **still open**, labelled `documentation` +
`triage`, explicitly "No branches or pull requests" (no linked PR), opened
2026-02-24. This matches the project's characterization exactly (a
documentation *request* for a native that doesn't exist, not a report of
an undocumented one that does). This is a genuinely fresh re-check, not a
restatement — worth re-running again in a future pass since triage-labelled
issues are exactly the kind that can flip status without much warning.

**The `source ~= 65535` client-event-origin guard — I could not resolve
this, and want to be precise about what I tried and why it didn't land.**
I searched for where FiveM's Lua runtime populates the `source` global
before invoking a client event handler. The one file I could fetch and
read (`citizen-resources-core/src/ResourceEventComponent.cpp`) passes
`eventSource` as a function parameter through its C++ call chain rather
than storing it in a persistent variable at that layer — which is mild,
circumstantial evidence *against* the "stale global that never clears"
failure mode this session's own review flagged as newly plausible, since a
purely parameter-threaded value has nothing to go stale in at this specific
layer. But **this is not the layer that matters**: the actual Lua-visible
`source` global is set by the scripting-runtime glue that wraps
`AddEventHandler` callback invocation (in `citizen-scripting-lua` or the
resource bootstrap, not this file), which I was not able to locate and
read this pass. **I am explicitly not closing D3 or upgrading its
confidence grading** — the project's own "medium-high, not certain" stands,
and the only test that actually resolves it is the in-engine sequenced
check `OPERATOR_RUNBOOK.md` §3 describes, which nobody has run. This is the
single externally-dependent fact in this project I'd flag as **most at
risk of being wrong in the dangerous direction** (fail-open, not fail-safe)
precisely because it gates the one category of feature (combat) where a
wrong "it's fine" belief has real gameplay-integrity cost, and because nine
watchdog/status passes across this session have all correctly declined to
resolve it from a read-only pass rather than guessing.

**Not re-checked this pass, no signal of drift:** the "last verified
compatible" dependency versions (`qbx_core` 1.24.0 etc.) — a watchdog pass
already re-fetched these within the last ~24h of session time and found
zero drift; re-fetching a third time within one day has low expected
value. `qbx_prison` dead / `ps-dispatch`/`ps-mdt` maintained — low
ambiguity, not re-checked.

---

## 6. What's next — ranked, three items

**1. Run the D3 sequenced origin-guard test on a real dev server, before
anything else gates on it.** This is the highest-leverage single action
available: it's a five-minute, already-fully-specified test
(`OPERATOR_RUNBOOK.md` §3), it resolves the one fact this whole session has
repeatedly declined to resolve from a read-only pass, and its answer
directly determines whether "enable Category B combat" is a reasonable
next step or a live exploit waiting to be found by a player. Every other
recommendation on this list is either independent of this question or
downstream of it — this is the one item that is both cheap and blocking.

**2. Enable the tracking/search tranche (`ScentTracking`, `BloodTracking`,
`GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`) on a dev server and
playtest it**, after the D6 `ScentTracking` payload check and after
replacing `Config.SearchContrabandItems`' placeholder item names with real
ones. This is the single highest-value-for-lowest-risk action in the whole
resource: it's the most reviewed subsystem here, it's read-only with
respect to other players, and — per `DECISIONS_NEEDED.md`'s own framing,
which I agree with — it's the tranche that produces visible gameplay value
without touching any of the still-open cross-cutting questions (D2/D3)
above. Doing this before Phase 4's XP/tiers also means the XP-farm fixes
(D4/D5, and the newly-closed sixth farm in `fb797e2`) get real playtest
pressure on a live server before more XP-earning surfaces go live on top
of them.

**3. Commit the current in-flight working-tree edits (§0) at the next
natural stopping point, and do a fresh flag-off-safety sweep against the
six newest files those edits touch** (`medkit.lua`, `bonetool.lua`,
`defense.lua`, `inventory.lua`, `kennel.lua`, `wellbeing.lua`) once they
land. This isn't the crisis the prior `PROJECT_STATUS.md` flagged (that was
ten complete, unwired files; this is seven files with modest, disclosed
diffs from what looks like one active agent) — but the underlying process
risk it named is still real: this project has found the same
"flag-off-safety" defect class (an unconditionally-registered handler that
should have been gated) more than once in one session, in more than one
new file, including a security bug that reappeared in a new file after
being fixed once in an older one (the kennel/prop-attachment delete-handler
pattern `DECISIONS_NEEDED.md` §6 documents). A newly-touched file is
exactly the population that pattern recurs in, and nobody has re-run that
specific sweep against this newest batch.

---

## 7. What I could not verify from this read-only pass

- Whether the seven currently-uncommitted diffs (§0) will land clean, or
  whether the agent editing them is still mid-change as this document is
  read — I read a snapshot, not a settled state.
- The FiveM Lua-runtime mechanism that actually sets/clears the `source`
  global per event invocation (§5) — I found the wrong layer, not the
  right one, and did not have a second good lead to chase within this
  pass's time budget.
- `D11`'s core claim about the dependency-block having no version-syntax
  at all — not re-derived this pass (no drift signal to justify the cost).
- Whether anyone is concurrently editing `fxmanifest.lua`/`config.lua`/
  `.luacheckrc` beyond the seven files already flagged in §0 — I have no
  visibility into other agents' in-progress edits beyond `git status`.
