# qbx_k9unit — Watchdog Log

This file is a running record of watchdog passes over this resource: what
was re-checked each time, what's still fine, and what changed or
regressed. Each entry should let the next pass pick up without starting
from zero.

---

## 2026-08-23 — Pass #1 (first run, no prior entry to pick up from)

**Reviewed:** full `git log --oneline` history (28 commits, `66b8aee` through
`0a38656`, all landed 2026-08-23 — this resource's entire history to date).
No prior WATCHDOG_LOG.md existed; this pass establishes the baseline.

### Syntax baseline — `luac5.4 -p` on every `.lua` file

Ran against all 8 `.lua` files in the resource:

- `config.lua`
- `fxmanifest.lua`
- `client/main.lua`
- `client/movement.lua`
- `client/radial.lua`
- `client/vehicle.lua`
- `server/main.lua`
- `server/certifications.lua`

Result: **all 8 pass with no syntax errors.**

### Fix-regression checks (5 specific items requested)

All five previously-landed fixes were located in the current code and read
in enough surrounding context to confirm they're intact and not
contradicted by a later commit:

1. **`AgilityBasicJump` is read somewhere** — confirmed.
   `client/movement.lua:546`: `if not Config.Features.AgilityBasicJump then`
   gates a `CreateThread` that calls `DisableControlAction` on
   `INPUT_JUMP`/`INPUT_DUCK` only when the flag is `false`; when `true`
   (default) no thread starts at all. This is the `d6fbf21` fix
   ("Wire up the orphaned AgilityBasicJump feature flag") — still wired,
   not reverted.

2. **Role-aware `LeashPairs` structure exists** — confirmed.
   `server/main.lua:183`: `local LeashPairs = {}`, populated at lines
   453-454 as `LeashPairs[k9Src] = { partner = officerSrc, isK9 = true }`
   / `LeashPairs[officerSrc] = { partner = k9Src, isK9 = false }`. The
   `isK9` field is actively consumed by `ForceDetachLeashForSource`
   (line 517, only detaches when `pairing.isK9` is true) and
   `ForceDetachOfficerLeashForSource` (line 541, only detaches when
   `pairing.isK9` is false) — the two independent role-aware teardown
   paths added in `5a5d9b1`/`e4a8dcf`/`27ebca9`. Still present and still
   the only place `LeashPairs` is mutated on detach (`doDetachLeash` at
   line 468 is the single shared mutation point, as its own comment
   claims — verified true by reading all four call sites: line 468 itself,
   plus the `playerDropped` handler at line 578 which also nils both
   halves directly, consistent with the same shape).

3. **`RevokeCertificationOffline` calls `RefreshCertificationCache`** —
   confirmed. `server/certifications.lua:542` defines
   `RevokeCertificationOffline`; line 618, inside that same function body
   (verified no other `function`/`local function` definition appears
   between lines 542 and 680), calls
   `RefreshCertificationCache(citizenid, job)` after the `UPDATE`
   succeeds. This is the `5a5d9b1` cache-staleness fix — still in place.

4. **`vehicle.lua`'s `onResourceStop` cleanup exists** — confirmed.
   `client/vehicle.lua:191-197`: `AddEventHandler('onResourceStop', ...)`
   checks `resourceName == GetCurrentResourceName()` and `vehicleState`,
   then calls `ReleasePedFromVehicleState(PlayerPedId(), ResolveVehicleFromState())`
   and nils `vehicleState`. This is the `3b7b275` fix ("Fix vehicle state
   leak on resource restart") — still present, still reuses the same
   cleanup path `ExitK9Vehicle()` uses (no duplicated native calls).

5. **Leash pull-back thread checks `IsInK9Vehicle`** — confirmed.
   `client/movement.lua:361`: the soft pull-back branch condition is
   `elseif dist > pullZoneStart and not IsPedInAnyVehicle(myPed, false) and not (IsInK9Vehicle and IsInK9Vehicle()) then`.
   This is the `1c6a651` fix ("Fix leash pull-back fighting vehicle attach
   state") — still guarded, using the existence-check-then-call pattern
   documented inline to tolerate load order between `movement.lua` and
   `vehicle.lua`.

**None of the five fixes have been reverted or contradicted by a later
change.** All still hold as of `0a38656`.

### Other things noticed this pass (not requested, flagging for awareness only)

- `fxmanifest.lua`'s `client_scripts`/`server_scripts` lists match exactly
  the `.lua` files actually present in `client/` and `server/` — no
  orphaned or unregistered file.
- Several inline comments in `server/certifications.lua` (e.g. around
  `RevokeCertificationOffline` and `GetPlayerByCitizenId` usage) and in
  `client/radial.lua`/`client/main.lua`/`server/main.lua` carry
  "CONFIDENCE NOTE" / "not independently verified against a live qbx_core
  install" caveats about qbx_core export conventions. These are exactly
  the kind of externally-uncertain flag this role is supposed to
  re-check on a cadence — not verified this pass (first run, no
  qbx_core install available in this sandbox to check against), but
  flagged here so the next pass (or whoever has a live Qbox install)
  knows they're still open. Listed in full: `server/certifications.lua`,
  `client/radial.lua`, `client/main.lua`, `server/main.lua`, `SPEC.md`.
- `SPEC.md`'s header (`Status: CORRECTED — Phase 1 build in progress...`)
  reads as slightly behind `README.md`'s header (`Phase 1 ... is
  feature-complete and reviewed`), but both are dated 2026-08-23 and the
  SPEC.md Phase-2-scoping note explicitly says it was written "while
  Phase 1 was still in its final review gate" — i.e. this is sequential
  history within the same day's work, not drift. Not flagging as a
  regression.

### Verdict

**All clear.** No regressions found. All 5 requested fixes confirmed
present and functioning as designed; full `.lua` syntax baseline is clean
across all 8 files.

### For next pass

- Re-check the same 5 fixes again (cheap, mechanical) plus diff any new
  commits since `0a38656`.
- If a live qbx_core/Qbox install becomes available, resolve the
  "not independently verified" qbx_core-export-convention notes listed
  above (`GetPlayerByCitizenId`, etc.) — currently unverified assumptions
  carried since Phase 1/Phase 2 spec work.
- No Phase 2 code has landed yet (only design notes in `phase2_notes/`
  and SPEC.md §11) — nothing to regression-check there yet, but worth a
  first pass once Phase 2 implementation starts.

---

## 2026-08-23 — Pass #2 (scheduled trigger, running as top-level session)

**Reviewed:** `git log` since Pass #1 — commits `4c287a5` through `6270a71`
(a large batch: the radial-menu registration fix Pass #1 didn't yet know
about, Phase 2's config schema, and full Phase 2 client+server
implementations for tracking/search/vision/door-interaction). All landed
same-day (2026-08-23).

**Externally-uncertain facts re-verified:** ox_lib/ox_target/oxmysql/
ox_inventory (all `overextended/*`) re-confirmed actively maintained
earlier this session by a dedicated tech-scout pass — a `CommunityOx` fork
claiming the originals were abandoned was itself archived, dead end. Bark
sound placeholder asset gap (SPEC.md §7) remains **unresolved** — still no
real audio file backing `qbx_k9unit_sounds`, unchanged status, not a new
finding.

**Regression spot-checks — all 5 confirmed present, no drift:**
- `AgilityBasicJump` still read at `client/movement.lua:561`.
- `LeashPairs[x] = { partner, isK9 }` role-aware structure intact,
  `server/main.lua:606`.
- `RevokeCertificationOffline` still calls `RefreshCertificationCache`
  (`server/certifications.lua:665`).
- `client/vehicle.lua`'s `onResourceStop` cleanup still registered
  (line 191).
- `client/radial.lua`'s `lib.registerRadial`/`lib.addRadialItem` split
  (the fix for the hard-error bug found earlier today) is still correct,
  and now also has 3 more items using the same submenu-items pattern
  (Track Scent/Blood/Gunpowder) added in this same pass.

**SPEC.md "Done"/"Resolved" claims:** spot-checked against actual code
during this same session's review passes (correctness-overseer,
integration-verifier) rather than re-derived from scratch here — no
contradiction found beyond what those passes already surfaced and this
pass then closed (see below).

**`luac5.4 -p` baseline:** clean across every `.lua` file in the resource
(client, server, and both new Phase 2 subdirectories).

**Regressions/gaps found and fixed in this same pass** (not pre-existing
regressions from Pass #1's baseline — these were real gaps in Phase 2 work
that landed *during* the gap between passes, closed before this entry):
1. `client/search.lua` held a raw ox_target entity handle across the full
   sniff-animation delay before converting to netId — a stale-handle reuse
   risk if the target disconnected mid-animation. Fixed: capture the netId
   before the animation starts.
2. `client/tracking.lua`'s water-crossing hard-break path set
   `brokenByWater = true` before the same tick's draw loop checked it,
   making the whole trail vanish instantly instead of rendering up to the
   water's edge. Fixed: removed the redundant same-tick gate.
3. `client/tracking.lua`'s `StartScentTrack`/`StartBloodTrack`/
   `StartGunpowderTrack`/`StopTracking` had zero callers anywhere in the
   resource — no in-game way to trigger or cancel a trail. Fixed: wired
   three context-sensitive radial items into `client/radial.lua`.

### Verdict

**Not a clean pass, but closed out before ending it** — three real,
concrete bugs found (all in code that landed since Pass #1, none regressed
from anything Pass #1 already checked) and fixed directly rather than just
reported, consistent with this trigger's real Agent-tool access. All 5
previously-fixed items from Pass #1 remain intact. Full syntax baseline
clean.

### For next pass

- Re-check the same 5 Pass-#1 items plus the 3 new fixes above (radial
  wiring, netId-capture-timing, water-crossing ordering) for regression.
- Door interaction (scratch-to-alert) has a server-side handler
  (`server/main.lua`) but still has **no client-side implementation**
  (`client/movement.lua`) — a coder-frontend dispatch for this failed
  mid-session on an unrelated API rate limit and hasn't been re-run yet as
  of this pass. Not a regression, just genuinely unfinished — worth
  checking whether it landed by the next pass.
- Bark-audio placeholder asset gap (SPEC.md §7) still unresolved, unchanged
  status — not urgent, same as every prior pass.
- `client/vision.lua`'s HUD-visibility-gate open question (flagged in
  `phase2_notes/phase4_hud_bridge_design.md` vs.
  `phase2_notes/phase4_hud_early_design.md` — they disagree) is still
  unresolved; will block `client/hud.lua` once someone starts writing it.

---

## 2026-08-23 — Pass #3 (issue-closer sweep; overdue relative to 13 commits since Pass #2)

**Reviewed:** `git log` since Pass #2's `c52a402` — through `19c57f8`
(door-scratch abuse-vector/entity-type-spoofing fixes, client-side door
interaction landing, Phase 3 combat research + evidence-backed resolution
of 3 of 4 design forks, CHANGELOG.md's initial add, README refresh,
REFACTOR_ROADMAP.md's Phase-2 retrospective, and the tech-scout confirmation
of a real `ox_inventory` scent-drop hook). All landed same-day (2026-08-23).
This pass ran concurrently with what git status showed to be live,
in-progress work on a shared cooldown/TTL helper (`server/cooldowns.lua`,
uncommitted `server/main.lua`/`fxmanifest.lua` changes present at the time
of this pass) — **that work was deliberately left untouched and
unreviewed here**, including its files, per this pass's own scope
boundary; a future pass should review it once it lands and commits.

**`luac5.4 -p` baseline:** ran against all 13 `.lua` files currently in the
resource (`config.lua`, `fxmanifest.lua`, 6 `client/*.lua`, 4 `server/*.lua`
at the time of this pass, plus `server/cooldowns.lua` which was present but
uncommitted and not reviewed for content, only confirmed present). All
pass with no syntax errors.

**Regression spot-checks — all 8 previously-confirmed items still present,
no drift:**
1. `AgilityBasicJump` still gates its thread — `client/movement.lua:605`.
2. `LeashPairs[x] = { partner, isK9 }` intact — `server/main.lua:718-719`.
3. `RevokeCertificationOffline` still calls `RefreshCertificationCache` —
   `server/certifications.lua:585`/`665`.
4. `client/vehicle.lua`'s `onResourceStop` cleanup still registered —
   line 191.
5. Leash pull-back thread still checks `IsInK9Vehicle` —
   `client/movement.lua:420`.
6. Radial `lib.registerRadial`/`lib.addRadialItem` split still correct,
   still has the 3 tracking items.
7. `client/search.lua`'s netId-capture-before-animation fix still in
   place; water-crossing draw-order fix still in place.
8. Door-scratch's dual cooldown (`lastDoorScratchAt` per-source +
   `lastDoorScratchAtByDoor` per-door, `server/main.lua:420-512`), the
   entity-type cross-check (`GetEntityType(doorEntity) ~= 3`, line 493),
   and the vehicle-tuck exclusion (`IsInK9Vehicle` guard in the door
   `canInteract` predicate, `client/movement.lua:833`) — all confirmed
   present, matching CHANGELOG.md's claims about them.

**New since Pass #2, confirmed landed correctly (not just claimed):**
- Client-side door interaction (scratch-to-alert) — Pass #2's "for next
  pass" item. Confirmed: `client/movement.lua`'s ox_target option, sit-
  scenario-based scratch animation, and `playDoorScratch` receiver are
  all present and wired.
- `Config.DoorInteraction.nudgeRequiresUnlocked` resource-start assert
  (`server/main.lua:274-283`) — confirmed present, fails loudly on a bad
  config value as CHANGELOG.md describes.
- `SumContrabandWeight`/`ResolveAlertTier` pcall-wrapping — not
  independently re-verified line-by-line this pass (out of the 8-item
  regression set), noted only as a commit that landed; no reason found to
  doubt it.

**Stale documentation found and fixed this pass (not a code regression):**
- `CHANGELOG.md`'s "Known Limitations" entry for `Config.Features.ScentTracking`
  still said the `ox_inventory` drop-location hook was "unconfirmed,"
  contradicting `SPEC.md` §9 item 17's own update (tech-scout, same day)
  confirming a real hook (`registerHook('swapItems', ...)`) exists.
  `SPEC.md` itself was already current; only `CHANGELOG.md` had drifted.
  Fixed by updating the bullet to reflect: research done, hook confirmed,
  `server/tracking.lua` implementation still pending, flag still ships
  `false`. No code changed, no behavior changed.

**New open item found and NOT closed here (see the dedicated decision
doc):** `PHASE3_SPEC.md`'s handler-partnership-link fork (§12.0 item 7) —
the one design fork the same-day Phase 3 resolution pass could not close
from available evidence — is written up as a standalone decision doc,
`phase2_notes/phase3_handler_partnership_decision.md`, so a human/
specialist doesn't have to extract it from a 1,600+ line spec file. Not a
new finding (already flagged in `PHASE3_SPEC.md` itself), just made
easier to act on.

**Deliberately not touched this pass, and why:**
- `Config.Features.ScentTracking`'s remaining `.lua` implementation
  (`server/tracking.lua`'s `'scent'` branch) — research is done
  (`phase2_notes/scent_source_resolution.md`) but the implementation
  itself was explicitly out of scope for the tech-scout pass that produced
  it, and `server/tracking.lua` was also one of the files with live,
  uncommitted work in progress at the time of this pass (see above) —
  touching it risks colliding with that work.
- The cooldown/TTL helper extraction (`REFACTOR_ROADMAP.md`'s top
  near-term item) — confirmed in progress (uncommitted
  `server/cooldowns.lua`, `server/main.lua`, `fxmanifest.lua` changes
  present at the start of this pass); left entirely alone, including not
  reviewing its partial contents.
- Bark-audio placeholder asset gap (`SPEC.md` §7) — still unresolved,
  unchanged status across all 3 passes now; needs an actual sourced audio
  asset, not a code fix.
- `client/vision.lua`'s HUD-visibility-gate disagreement (Pass #2's own
  "for next pass" note) — still unresolved; still not urgent since Phase 4
  (`client/hud.lua`) hasn't started, re-flagging rather than re-solving.
- `phase2_notes/EXPORT_TRACKING.md` — last updated at the Phase 2
  *scaffold* commit (`4c287a5`), predating the full client/server
  implementations that landed afterward (`6270a71` onward). Its own
  content is still accurate for everything it covers (function names,
  file placement), so this isn't a wrong-information gap, just a
  currency gap against `REFACTOR_ROADMAP.md`'s "actively maintained"
  characterization — flagging for whoever next touches Phase 3's public
  surface to fold Phase 2's final shape in before extending it, rather
  than fixing prose-only currency here.

### Verdict

**No regressions.** All 8 previously-confirmed fixes intact, all new
Phase-2-completion claims verified against actual code (not just
CHANGELOG's word), full syntax baseline clean. One stale-documentation
drift found and fixed (CHANGELOG.md's scent-tracking limitation wording).
One already-known open design fork made easier to act on via a dedicated
decision doc, not newly discovered. Two areas of confirmed-live concurrent
work (cooldown extraction, scent-tracking implementation) deliberately
left untouched rather than risking a collision.

### For next pass

- Re-check the same 8 items above, plus confirm the cooldown/TTL helper
  extraction (`server/cooldowns.lua` + its call-site migrations) landed
  cleanly once it's committed — re-verify the door-scratch dual-cooldown
  and search's `SearchInFlight`/`lastTargetSearchAt` TTL-vs-`playerDropped`
  split specifically, since `REFACTOR_ROADMAP.md` flags those as the exact
  behavior-preservation risk of that migration.
- Check whether `server/tracking.lua`'s `'scent'` branch has been
  implemented per `phase2_notes/scent_source_resolution.md` §4, and if so
  whether `Config.Features.ScentTracking` was safely flipped to `true`
  with acceptance criteria actually met, per `SPEC.md` §11.5.
- Check whether `phase2_notes/phase3_handler_partnership_decision.md` has
  received a decision; if so, confirm `PHASE3_SPEC.md` §12.0 item 7/§12.7
  item 7 were updated to reflect it before Phase 3's 3b/3e sub-phases
  start implementation.
- Bark-audio asset gap and the HUD-visibility-gate disagreement remain
  open with no change in status; carry forward again.

---

## 2026-08-23 — Pass #4 (whole-project vantage; ran alongside ~18 concurrent file/feature-level agents per the live "maximum parallelism" directive)

**Scope note, upfront:** this pass explicitly does not re-review every line
(that's what the concurrent QA/spec-conformance/refactor/wiring/exploit
agents running right now are for) — it checks that the batch since Pass #3
matches its own commit messages, that the project's own docs (`CHANGELOG.md`,
`REFACTOR_ROADMAP.md`, `SPEC.md`/`PHASE3_SPEC.md`) are/aren't drifting from
what's actually shipped, and looks specifically for the kind of cross-file
interaction a single-file reviewer has no reason to go looking for.

**Reviewed:** `git log --oneline 37d6765..cf0f90f -- qbx_k9unit` — the 8
commits Pass #3 hadn't seen yet: `f44f8c8` (Phase 4 HUD visibility-gate
design fork resolved: gate on `CanShowK9UI()`, not `IsOwnModelK9()`),
`ac29069` (shared `server/cooldowns.lua` extraction), `531c537` (luacheck
CI added), `258d2b1` (Phase 4 vitality HUD wired into the manifest),
`09082df` (door-interaction nudge-open), `efe07c5` (search TOCTOU fix),
`f70d28f` (3 native-correctness sweep fixes), `cf0f90f` (`PHASE3_SPEC.md`
Revision 3: PvP re-opened by explicit product override). **Important
caveat: the repo did not hold still during this pass.** Four more commits
(`cc78fc6`, `b37f00d`, `4536f17`, `6ba0fd2`) and a fifth (`9e99e5d`,
Phase 3 `AgilityAdvanced`) landed *while this review was running*, plus
live uncommitted work touching `CHANGELOG.md`, `README.md`,
`client/{hud,main,radial,search,vehicle,tracking}.lua`,
`server/{certifications,main,tracking}.lua`, `config.lua`, and
`.luacheckrc` was still in flight as this entry was being written. Per
this project's own established convention (Pass #3 did the same for the
cooldown extraction), that live work was **not** deep-reviewed here —
noted for awareness, left for the next pass once it lands.

### `luac5.4 -p` / `luacheck` baseline

Ran against all 15 `.lua` files in the resource (14 checked by `luacheck`
per its own `.luacheckrc` scope — `fxmanifest.lua` is intentionally
excluded, same as every prior pass's convention): **all pass `luac5.4 -p`
with no syntax errors; `luacheck` reports 0 warnings / 0 errors across all
14 files.** This is the first pass where `luacheck` itself could be run
directly (installed in this sandbox) rather than only trusted via CI —
confirmed clean, not just assumed from `531c537`'s commit message.

### Commit-message-vs-diff spot checks

- **`efe07c5` (search TOCTOU fix):** verified in full. The re-check
  (`if not HasK9Access(source) then ... return { ok = false, reason =
  'access_revoked' } end`, `server/search.lua`) lands exactly where the
  commit message says (immediately after the awaited
  `GetInventoryItems` call, before `totalWeight`/tier/broadcast), logs
  `search_failed` to `k9_search_log` as claimed, and `client/search.lua`'s
  existing generic `else` branch (line 198) already handles the new
  `access_revoked` reason with no client-side change needed, exactly as
  the commit message asserts. **Matches.**
- **`ac29069` (cooldown/mutex extraction):** verified the "fails closed on
  a nil/non-positive threshold" claim directly — `server/cooldowns.lua`'s
  `IsOnCooldown` (both the flat and nested variants, lines ~146-161 and
  ~245-256) return `true` (blocked) rather than silently disabling the
  cooldown, exactly as described. Spot-checked `server/main.lua`'s
  `DoorScratchCooldown`/`DoorScratchByDoorCooldown` migration onto
  `NewCooldown()` — present, consistent with the dual-cooldown shape
  Pass #3 flagged as the specific behavior-preservation risk to watch.
  **Matches**, though this pass did not re-diff every one of the 11
  migrated call sites line-by-line (left to the concurrent QA/regression
  agents' file-level passes).
- **`f70d28f` (three native-correctness fixes) — one real commit-message/
  diff mismatch found, not a code bug:** the `config.lua` husky-typo fix
  and the `tracking.lua` `GetWaterHeightNoWaves` comment fix are both
  present exactly as described. **The claimed third fix — "client/hud.lua:
  fixed inverted stamina semantics" — is not in this commit's diff at
  all** (`git show --stat f70d28f` touches only `client/tracking.lua` and
  `config.lua`). `git blame` shows the correct `100 -
  GetPlayerSprintStaminaRemaining(...)` formula was already present in
  `client/hud.lua` from the moment it was authored, one commit earlier
  (`258d2b1`, 19 seconds before `f70d28f`). Net effect: the shipped code
  is correct (the stamina bug the commit message describes does not
  exist in the current tree), but the commit message describes a fix that
  a different, concurrent pass had already baked into the file's first
  version — a benign case of two agents independently catching the same
  finding, where the second one's commit message wasn't trimmed down to
  match its actual diff. Flagging for accuracy, not because anything needs
  fixing in `.lua`.
- **`cf0f90f` (`PHASE3_SPEC.md` Revision 3):** confirmed doc-only (`git
  show --stat` — one file, 1530 lines touched, no `.lua`). Confirmed
  `SPEC.md` §2's non-goals list was **not** given a "player-vs-player K9
  combat" bullet (Revision 2 had flagged that fold-in step as pending;
  Revision 3 correctly says not to take it now, and `SPEC.md` itself
  currently has no such bullet — checked directly).
- **`f44f8c8`, `531c537`, `258d2b1`, `09082df`:** spot-checked against
  their diffs; all match their commit messages. `258d2b1`'s manifest wiring
  (`ui_page 'html/index.html'`, `files {...}`, `client/hud.lua` in
  `client_scripts`) is present exactly as described.

### New finding: a real, small cross-file regression from `f70d28f`'s config fix — already caught and being fixed by concurrent work

`f70d28f` corrected `config.lua`'s `Config.Peds` husky entry
(`a_c_huskie` → `a_c_husky`). The three generic model-*recognition*
tables (`client/main.lua`'s `K9ModelHashes`, `client/movement.lua`'s
`k9ModelHashesForTargeting`, `server/certifications.lua`'s
`K9ModelHashes`) all derive their keys by iterating `Config.Peds` at load
time, so they picked up the fix automatically — no problem there. But
`client/movement.lua` also has two **hand-written, literal-string**
breed-to-*scenario* tables that don't iterate `Config.Peds`:
`K9_SIT_SCENARIO_BY_MODEL_HASH` (Sit action) and
`K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH` (Scratch-to-Alert action, added
one commit later in `09082df` — and authored with the *already-corrected*
`a_c_husky` string, so it never broke). At `f70d28f`'s own commit,
`K9_SIT_SCENARIO_BY_MODEL_HASH` still keyed off `GetHashKey('a_c_huskie')`
— a real, verified miss against `GetHashKey('a_c_husky')` (the actual
model), which would have silently fallen through to
`K9_SIT_DEFAULT_SCENARIO` (Shepherd) instead of the intended Retriever
substitute for a Husky K9's Sit action. Cosmetic-only (no security/
correctness impact — worst case is the wrong idle animation plays), but a
genuine, confirmed regression, and exactly the kind of interaction a
file-scoped reviewer of either `config.lua` or `client/movement.lua` alone
could plausibly miss (the fix commit touched the former; the stale table
lives in the latter, in code that predates the fix commit by several
commits). **Status: as of this pass, a concurrent, uncommitted diff to
`client/movement.lua` (from whichever agent is implementing Phase 3's
`AgilityAdvanced`, landed moments later as `9e99e5d`) already corrects
`K9_SIT_SCENARIO_BY_MODEL_HASH`'s key to `a_c_husky` — found already fixed
in flight, not left open.** Wrote up the underlying *pattern* (hand-copied
`Config.Peds` string literals with no enforcement mechanism keeping them in
sync) as a new item in `REFACTOR_ROADMAP.md`'s Revision 3 note and folded
it into near-term item 3, since a 3rd or 4th such table is a realistic
risk for future breed-specific features (Phase 3 agility, future bark
variety).

### Documentation currency — findings and one edit made, one deliberately left alone

- **`REFACTOR_ROADMAP.md` — stale, updated this pass.** Its near-term
  item 1 (the cooldown/TTL/mutex helper) was still written up as "do
  next"/"highest-value item... precisely because it's overdue" despite
  having shipped in `ac29069`. Added a Revision 3 status note at the top
  marking item 1 **DONE** (verified, not just taken on the commit
  message's word — see the fail-closed check above), confirmed item 2
  (defensive netId resolution) is still genuinely open (`ac29069`'s own
  file list never touched it), and folded in the breed-to-scenario-table
  finding above as a widened item 3. Original retrospective text left
  intact underneath, per this document's own established pattern of
  layering revision notes rather than rewriting history.
- **`CHANGELOG.md` — confirmed stale (still says "nudge-open is not
  implemented" under Known Limitations, and has no entry at all for the
  cooldown extraction, luacheck CI, TOCTOU fix, native-correctness sweep,
  or Phase 3 Revision 3), but deliberately NOT touched here.** Checked
  before writing anything: a docs-agent instance is actively editing
  `CHANGELOG.md` right now (confirmed via `git diff` on the live working
  tree partway through this pass — the in-progress rewrite already covers
  scent-tracking closure, nudge-open, the TOCTOU fix, and the Revision 3
  PvP change, and reads accurate against what's actually shipped from a
  spot check). Left entirely alone to avoid colliding with it, per this
  pass's own instructions.
- **`SPEC.md`'s top-of-file Status paragraph is now more stale than Pass
  #1 judged it** — it still describes Phase 2 as "actual logic still
  mid-implementation by concurrent agents," which was accurate when
  written but is now well behind reality (Phase 2 is implementation-
  complete except scent-tracking, which itself is being closed out in the
  same live work this pass observed but didn't review). Not fixed here,
  consistent with `PHASE3_SPEC.md`/`PHASE4_SPEC.md`'s own stated reason
  for staying as separate documents rather than being folded in: no
  incremental-edit tool access to a ~113KB file safely, real risk of
  corrupting reviewed content for a prose-only fix. Flagging for whoever
  next has safe edit access to `SPEC.md` to fold in a status-paragraph
  refresh alongside the Phase 2/3/4 section folds already pending.
- **Two new planning documents appeared uncommitted during this pass and
  were not deep-reviewed** (out of scope, and actively in flux):
  `PHASE4_SPEC.md` (detailed spec for the 9 non-HUD Phase 4 features,
  explicitly scoped to exclude `HealthStaminaHUD`) and
  `phase2_notes/phase5_features_research.md` (native/pattern research for
  Phase 5). Both landed committed later in this same pass
  (`b37f00d`, `4536f17`) — noted for the record that planning work is now
  running two phases ahead of implementation (Phase 2 substantially
  shipped, Phase 3 mid-implementation, Phase 4/5 already speced/
  researched), which is a healthy lead time, not a concern by itself.

### Regression spot-checks carried forward from Pass #3 — all still present

Re-checked the 8 items Pass #3 confirmed (not a fresh re-derivation, a
targeted re-grep against current `HEAD`): `AgilityBasicJump` gate,
`LeashPairs[x] = { partner, isK9 }`, `RevokeCertificationOffline` →
`RefreshCertificationCache`, `client/vehicle.lua`'s `onResourceStop`
cleanup, leash pull-back's `IsInK9Vehicle` check, radial's
`lib.registerRadial`/`lib.addRadialItem` split, `client/search.lua`'s
netId-capture-before-animation + water-crossing draw-order fixes, and the
door-scratch dual-cooldown/entity-type-check/vehicle-tuck exclusion — all
confirmed still present in the current tree (now migrated onto
`server/cooldowns.lua` for the cooldown-shaped ones, behavior unchanged).

### Verdict

**No uncaught regressions.** One real (but already self-healing, cosmetic-
only) cross-file regression found and confirmed being fixed in concurrent
flight; one commit-message/diff mismatch found (`f70d28f`'s hud.lua claim)
that doesn't correspond to any actual code defect; `REFACTOR_ROADMAP.md`
updated to reflect item 1's completion; `CHANGELOG.md` correctly left to
the docs-agent already handling it; `SPEC.md`'s top-level staleness
reconfirmed and left for a safe-incremental-edit pass. Full `luac5.4 -p`
and (newly, directly-run) `luacheck` baselines both clean.

### For next pass

- Confirm the in-flight work observed but not reviewed here actually
  landed cleanly: Phase 3 `AgilityAdvanced` (`9e99e5d`, already committed
  by the end of this pass — worth a first real look), scent-tracking's
  `server/tracking.lua` `swapItems` hook implementation (still uncommitted
  as of this pass's end), and whatever `client/main.lua`/`client/radial.lua`
  changes were mid-flight (not yet identified what they wire up).
- Re-verify `REFACTOR_ROADMAP.md`'s item 2 (defensive netId resolution)
  status — still open as of this pass; check it hasn't been silently
  addressed by any of the in-flight work above without an update here.
- Confirm `CHANGELOG.md`'s in-progress rewrite actually landed and reads
  consistent with whatever else committed after it (the docs-agent was
  working from a snapshot that itself kept moving during this pass).
- Re-check `PHASE3_SPEC.md` §12.0 item 8 (the client-relay/non-cooperating-
  client architecture question) — flagged in this pass's briefing as being
  worked by a coder-security instance live; not yet resolved as of the
  version reviewed here (`cf0f90f`), status unknown by the time this pass
  ended given how much else landed concurrently.
- Once Phase 3 implementation is further along, re-run the same 8
  Pass-#3-era regression spot-checks plus this pass's breed-to-scenario-
  table fix, and confirm `REFACTOR_ROADMAP.md`'s widened item 3 (or a
  dedicated fix) actually lands for `K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH`'s
  sibling table if a similar drift ever recurs there.
- Bark-audio placeholder asset gap and the HUD-visibility-gate
  disagreement (the latter resolved by `f44f8c8` this pass, see above) —
  bark-audio remains open with no change in status; carry forward again.

---

## 2026-08-24 — Pass #5 (scheduled trigger; run by the top-level session)

**Scope:** the 8 commits since Pass #4 (`3a604e7..8d3efa4`), plus this
pass's own recovery work after four concurrent implementation agents were
killed mid-write by a session usage limit. Deliberately does NOT re-review
every line of the eight commits — each landed with its own review pass at
the time; this checks for regressions, drift, and anything the interrupted
agents left in a broken state.

### Commits since Pass #4

`5afef62` scent-tracking source resolution (closed Phase 2's last disclosed
gap), `9e1bb48` ResolveNetworkEntity extraction (REFACTOR_ROADMAP near-term
item 2 — the item Pass #4 named as top priority, now DONE), `0587c0e`
K9Inventory, `5f5e142` DeployableKennel, `89b8668` K9Medkit + manifest
wiring, `29706d8` AdvancedBarkRadial, `969d10b` handler-partnership
decision (PHASE3_SPEC §12.0 item 7 — the second of Pass #4's two named
blockers, now RESOLVED in design), `8d3efa4` wellbeing subsystem + XP
progression.

Both blockers Pass #4 flagged as gating their phases are now closed:
scent-tracking landed in code, and item 7 landed as a design decision
(implementation still pending). PHASE3_SPEC §12.0 item 8 (client-relay
architecture) was also resolved by a coder-security pass during this window.

### Interrupted-agent recovery (this pass's main finding)

Four agents died mid-write. Their partial output was assessed rather than
assumed good: all five orphaned files parsed clean and ended at natural
statement boundaries, but none were registered in `fxmanifest.lua`, so all
were dead code — an accidentally-safe state, not a designed one.

- **wellbeing + XP progression** (4 files) were complete and fully
  event-paired in both directions; only the final manifest/lint wiring was
  missing. Finished by hand and committed as `8d3efa4`. Verified before
  committing that all six feature flags still default `false`, that the
  wellbeing tick thread is gated at REGISTRATION (not inside the loop, per
  this resource's convention), and that each net handler independently
  re-validates its own flag so a disabled feature is a genuine server-side
  no-op. Its second handler on `relayDamageEvent`/`relayWeaponFire` uses the
  separate `RegisterNetEvent`/`AddEventHandler` idiom — an additional
  consumer alongside `server/tracking.lua`'s, which is the documented intent.
- **`server/combat.lua`** (811 lines, BiteAndHold/NonLethalTakedown) is a
  server half with NO client half — `client/combat.lua` was never written,
  despite a second agent's report implying it existed. It fires six client
  events with no handlers anywhere. Left uncommitted and unregistered
  (therefore inert); dispatched to coder-frontend to complete. **Do not
  register `server/combat.lua` in the manifest until its client half lands.**
- One stale `.luacheckrc` comment corrected: it claimed `server/search.lua`
  reads `AwardXP`; `server/tracking.lua` is the only call site.

### Regression spot-checks — all five intact

`Config.Features.AgilityBasicJump` still read (`client/movement.lua:639`);
role-aware `LeashPairs[a] = { partner, isK9 }` structure still in place
(`server/main.lua:189`); `RevokeCertificationOffline` still calls
`RefreshCertificationCache` (`server/certifications.lua`, in-body, not just
in a comment — verified against the real function range after a first grep
returned only comment matches); vehicle `onResourceStop` cleanup still
present (`client/vehicle.lua:197`); `client/radial.lua`'s
`lib.registerRadial`-then-`lib.addRadialItem` split still correct and still
in that order (lines 411/421).

### Baseline health

`luac5.4 -p` passes on all 26 `.lua` files. `luacheck` is clean across the
resource EXCEPT `server/combat.lua`'s 10 warnings — confined to the
uncommitted, unregistered file above and assigned to the agent completing
it. Every manifest-listed file exists on disk.

### Externally-uncertain facts

- **Bark-audio placeholder gap: STILL OPEN, no change.** Confirmed no
  `.ogg`/`.wav`/`.awc`/`.rel` asset ships anywhere in the resource, and
  `'qbx_k9unit_sounds'` is still the placeholder soundset in
  `client/main.lua`/`client/movement.lua`. `29706d8`'s AdvancedBarkRadial
  added three more placeholder sound names, widening rather than closing
  this gap — as that commit itself disclosed. Carry forward.
- **Dependency maintenance status: only PARTIALLY re-verified, question
  stands.** `overextended/ox_lib` (3.39.0) and `overextended/ox_target`
  (1.18.1) both serve a live `main` fxmanifest, so those repos are alive.
  But the GitHub API is gated for out-of-scope repos in this environment
  and `oxmysql`'s manifest returned no version line, so recency-of-activity
  and the Overextended-vs-CommunityOx governance question could NOT be
  settled. Recording this as unresolved rather than reading "repo responds"
  as "actively maintained." Carry forward for a pass with real API access.

### SPEC "Done"/"Resolved" claims vs. code

No new mismatch found in this window. Pass #4's flagged staleness in
`SPEC.md`'s top-of-file Status paragraph (still describing Phase 2 as
mid-implementation) was partly addressed by `5afef62`'s §9/§11.5 edits, but
the header paragraph itself should be re-checked next pass now that Phase 2
is genuinely complete.

---

## 2026-08-24 — Pass #6 (scheduled trigger, 06:45 UTC; run by the top-level session)

**Window:** the 9 commits since Pass #5's marker (`b172141`) —
`111075f`, `bbf7c1b`, `5a9fc18`, `17e4429`, `885c6ea`, `cb8f240`,
`0020c2b`, `f9c91c5`, `afde4f5`. Every one was reviewed and committed by
the top-level session as it landed, so nothing entered the branch
unreviewed in this window. Working tree clean at pass time.

### Health baseline

- `luac5.4 -p`: all 28 `.lua` files parse, no errors.
- `luacheck` (repo-root `.luacheckrc`): **0 warnings / 0 errors across 27
  files** — and this is now an honest zero. Pass #5 recorded a temporary
  `exclude_files` entry hiding 10 warnings in the then-unfinished
  `server/combat.lua`; `afde4f5` removed that entry and fixed the
  warnings for real rather than carrying the exclusion forward.

### Regression spot-checks — all five INTACT

`AgilityBasicJump` still read (`client/movement.lua`); role-aware
`LeashPairs` (`isK9`) still in place; `RevokeCertificationOffline` still
calls `RefreshCertificationCache`; `client/vehicle.lua`'s
`onResourceStop` cleanup still present; `client/radial.lua`'s
`lib.registerRadial` (line 411) still precedes `lib.addRadialItem`
(line 421), so the 2026-08-23 hard-error fix holds. No regression
despite this window touching `movement.lua`, `radial.lua` and
`vehicle.lua`.

### Externally-uncertain facts

- **Dependency maintenance status: RESOLVED** (`5a9fc18`), closing a
  question Passes #4 and #5 both carried forward. Overextended is again
  the canonical maintained home for ox_lib/ox_target/oxmysql/ox_inventory
  (discontinued 2025, resumed 2026); CommunityOx, the stopgap fork, is
  itself archived as of 2026-04-28. The `api.github.com` 403 that blocked
  both earlier passes reproduced again — but `github.com` HTML and
  `raw.githubusercontent.com` were reachable and gave equivalent data,
  an avenue neither earlier pass had tried. Note the research flagged
  rather than hid a source conflict (a releases page dating v3.39.0 to
  2024 against commit lists giving 2026) and reasoned to 2026. **Stop
  carrying this item forward.**
- **Bark-audio gap: STILL OPEN**, unchanged — 0 real audio assets ship,
  `'qbx_k9unit_sounds'` remains the placeholder soundset. But `5a9fc18`
  identified a concrete lower-cost path (extend the already-running NUI
  bridge rather than author a RAGE `.awc`/`dat151`/`dat54` bank), plus an
  explicitly-unconfirmed hypothesis that the vanilla `WORLD_DOG_BARKING_*`
  scenarios already in use may carry usable audio for free — worth a
  short in-engine test before anyone builds either path. Carry forward as
  an open gap, but no longer an unscoped one.

### SPEC/CHANGELOG "Done"/"Resolved" claims vs. code — ONE REAL FINDING

`SPEC.md`'s top-of-file Status paragraph, flagged stale by Passes #4 and
#5, was rewritten at `885c6ea` and is now accurate; it correctly records
that the partnership registry is unbuilt and `HandlerDownDefense`
uncoded, both of which match the code (`server/partnership.lua` does not
exist — only its schema does).

**But `CHANGELOG.md` documented a security control that does not
exist.** Docs were last synced at `885c6ea`; four commits landed after it
touching none of them. The resulting passage (~lines 176-182) presented
`Config.K9Inventory.accessScope = 'ownerOnly'` as a working
personal-locker mode "restricted to the K9's own citizenid", claimed an
unrecognized value "fails closed to `'ownerOnly'`", and asserted the real
boundary was "ox_inventory's own owner/groups check". All three are false
as of `f9c91c5`: `'ownerOnly'` never provided any access control (ox_
inventory never compares `owner` against the caller; only `groups` gates
anything, and `'ownerOnly'` passed nil groups, short-circuiting to
allow), it is not implementable at all, and it is now hard-asserted out
at resource start rather than failing closed to anything.

This is the failure mode watchdog item 4 exists to catch: not a doc
lagging behind code, but a doc confidently describing protection a server
owner does not have. Dispatched to docs-agent to correct, along with the
other three unsynced commits (`cb8f240`, `0020c2b`, `afde4f5`).

### Carried forward to Pass #7

- Bark-audio asset gap (now with two scoped candidate paths, above).
- `fxmanifest.lua` pins no dependency versions at all — a real
  reproducibility gap for a dependency set that just went through a
  discontinuation/fork/re-fork cycle (raised by `5a9fc18`, unactioned).
- Phase 3 combat has **no in-game entry point** — its client triggers are
  not registered in `client/radial.lua`. The feature is complete and
  registered but unreachable in-game.
- Recall (`PHASE3_SPEC.md` §12.5.1) unimplemented, blocked on
  `server/partnership.lua`.
- FearStress residual: one sustained forged reporter is still
  indistinguishable server-side from one real continuous shooter
  (disclosed in-code at `0020c2b`, deliberately not claimed closed).

---

## 2026-08-24 — Pass #7 (whole-project vantage; run as a subagent, NOT the
top-level session — see Platform note below)

**Platform note, upfront:** this pass's tool list has no `ListAgents`/Agent
tool at all (checked at the start, per this role's standing instruction —
it is simply absent, not merely failing), confirming this instance is
running as a subagent, not the top-level session Passes #5/#6 ran as.
Nothing found below could be dispatched directly; everything is reported
for the invoking session to act on. Scope for this pass was also
explicitly narrowed to `qbx_k9unit/WATCHDOG_LOG.md` only — no other file
was touched, including the several real findings below that would
normally get a direct fix.

**Window:** 5 commits since Pass #6's marker (`afde4f5`) —
`3536b1e` (Phase 3 combat radial entry point), `575c1b7` (Phase 5 research:
ProximityAudioFX/PropAttachments/FetchMechanic, notes only), `3b98dca`
(REFACTOR_ROADMAP Revision 5: whole-codebase netId/player-resolver audit),
`52a58a1` (K9 partnership registry, recovered from a mid-task agent death),
`94fbc4e` (PropDragging implementation + four combat defect fixes). **The
tree was not holding still while this pass ran**: `git status` showed
`client/combat.lua`, `client/radial.lua`, `server/combat.lua`,
`server/entities.lua`, `server/inventory.lua`, `server/search.lua` all
modified-uncommitted throughout, and the diff sizes grew between separate
checks within this same pass (e.g. `server/combat.lua`'s uncommitted diff
went from 48 to 158 changed lines partway through). Per this project's
established convention (Pass #3/#4 did the same), that live work was
**read for context where it directly bore on a finding below, but not
deep-reviewed** — everything in this entry that cites the working tree
rather than `HEAD` says so explicitly; everything else was read via
`git show 94fbc4e:<path>` for stability.

### Health baseline

- `luac5.4 -p` at `HEAD` (`94fbc4e`): all 30 `.lua` files parse, no errors.
- `luac5.4 -p` on the live, uncommitted working tree: also clean (no
  syntax errors introduced by the in-flight work as of the last check).
- `luacheck` at `HEAD` (root `.luacheckrc`, `fxmanifest.lua` excluded per
  its own established scope): **0 warnings / 0 errors across 29 files.**
- 2 new `.lua` files since Pass #6: `client/partnership.lua`,
  `server/partnership.lua` (both from `52a58a1`), accounting for the
  28→30 file count growth.

### Regression spot-checks — all five INTACT (re-verified at `HEAD`, not assumed)

- `AgilityBasicJump` still read: `client/movement.lua:936`
  (`if not Config.Features.AgilityBasicJump then`).
- Role-aware `LeashPairs[x] = { partner, isK9 }` still in place:
  `server/main.lua:806-807`, still the only mutation site (`doDetachLeash`
  region, lines 822-827).
- `RevokeCertificationOffline` still calls `RefreshCertificationCache` —
  confirmed in-body, not just in a comment: the function starts at
  `server/certifications.lua:670` and the real call is at line 746, inside
  its own body (read the full function, not just grepped both symbols
  independently).
- `client/vehicle.lua`'s `onResourceStop` cleanup still registered
  (line 197).
- `client/radial.lua`'s `lib.registerRadial` (line 521) still precedes
  `lib.addRadialItem` (line 531) at `HEAD`. **Note:** the working tree's
  uncommitted diff adds ~50 more lines to this file (a new "Drag /
  Release" item, see below) — not yet re-verified for the split's
  ordering once that lands, since it's still moving.

### Item 1 — flag-off safety sweep (the priority item this pass)

**Method:** grepped every `client/*.lua` for `RegisterNetEvent(`, then for
each one checked whether the handler body (or an enclosing `if
Config.Features.X then` block wrapping the whole file section) re-gates on
the owning flag, rather than trusting that the flag being `false`
server-side means the server simply never sends the trigger. A locally
forged `TriggerEvent` reaches these handlers regardless of what the server
would have done, so a handler that applies an effect unconditionally
breaks the "false means inert" invariant even if no legitimate code path
ever fires it with the flag off.

**`client/combat.lua`'s fix (this session, prior to this pass, `94fbc4e`)
verified solid.** All fourteen `RegisterNetEvent` handlers are correctly
partitioned into three `if Config.Features.X then ... end` blocks
(`BiteAndHold` lines 15-122, `NonLethalTakedown` 124-213, `PropDragging`
215-295 in the working copy) — no shared OR, no handler outside its own
mechanic's gate. `onResourceStop` (line 1060) and the `pcall(EndHold, ...)`
guard the commit message describes are both present (the latter in
`server/combat.lua:967/972`, correctly server-side, not client).

**Three further, previously-unflagged instances of the exact same defect
class found this pass, all still open at `HEAD`:**

1. **`client/kennel.lua`'s `deployKennelAt`/`removeKennel` handlers
   (lines 130, 188) have no `Config.Features.DeployableKennel` check at
   all.** The flag is only checked in `RequestDeployKennel()` (line 100,
   the player-initiated request path) and in a separate `if
   Config.Features.DeployableKennel then ... end` block (lines 244-265,
   the ox_target/UI registration) — neither wraps these two
   server-issued receivers. A forged `deployKennelAt(x, y, z)` spawns a
   real networked prop at attacker-chosen coordinates with the feature off
   (only a `type()` check on the three arguments); a forged
   `removeKennel(netId)` calls `DeleteEntity` on **any** currently-streamed
   networked entity the attacker supplies a valid netId for, not
   necessarily a kennel — the more serious of the two, since it's an
   arbitrary-entity-deletion primitive independent of `DeployableKennel`'s
   state.
2. **`client/medkit.lua`'s `applyMedkitHeal` handler (line 129) has no
   `Config.Features.K9Medkit` check.** The file's only reference to that
   flag (line 89) is inside the ox_target `canInteract` predicate for the
   *request* path. The handler itself does `SetEntityHealth(PlayerPedId(),
   newHealth)` on any numeric argument — an unbounded, cooldown-free,
   item-free self-heal reachable with `K9Medkit = false`.
3. **`client/progression.lua`'s `xpTierChanged` handler (line 138) has no
   `Config.Features.XPProgression` check anywhere in the file** (grepped
   the whole file for the flag — the only hit is a header comment).
   `ApplyXPTierMoveRateEffect()` sets `K9MoveRateModifiers.xpTier` from the
   forged payload's `speedMultiplier` unconditionally and calls
   `RecomputeK9MoveRate()`. Impact is bounded but real: `movement.lua`'s
   composer only applies a non-1.0 override while `IsOwnModelK9()` is true
   and clamps the product to `[0.1, 2.0]`, so this is a self-only, up-to-
   2x speed modifier reachable with `XPProgression = false`, not an
   other-player-affecting exploit.

**Checked and confirmed clean (same pattern, no defect):**
`client/partnership.lua` gates its entire back half behind a single
file-scope `if not Config.Features.HandlerPartnership then return end`
(line 202) *before* any `RegisterNetEvent` call, so the handlers
(`partnerUpRequest`, `partnershipEstablished`, `partnershipEnded`) are
never even registered when the flag is off — the correct shape.
`client/wellbeing.lua`'s `wellbeingUpdate` handler (line 167) is not
itself gated, but the effect-application function it calls,
`ApplyMoveRateModifiers()`, individually gates each of its four move-rate
contributions on its own owning flag (`Config.Features.FatigueSystem`
etc., lines 98/106/115/143/153) — a disabled stat's modifier is simply
never touched, so this is a deliberately layered defense, not a gap.
`client/hud.lua` gates its entire tail (including its poll thread) behind
a single early `if not Config.Features.HealthStaminaHUD then return end`
(line 142) — same correct shape as partnership.lua.

**Two low-severity instances noted for completeness, not fixed or
escalated:** `client/main.lua`'s `playBark` handler is ungated, but
`BasicBarkSounds` is a Phase-1 base feature that defaults `true` (not one
of the "ships false" flags this invariant is about) — forging it just
plays a sound, by design always reachable. `client/search.lua`'s
`playContrabandAlert` handler (line 323) is ungated against
`Config.Features.ContrabandAlerts = false`, but its only effect is playing
a sound on a resolved nearby entity — cosmetic, no gameplay state change,
much lower priority than the three above.

**Server-side spot check (the actual security boundary, separate
question):** every server-side `RegisterNetEvent`/`lib.callback.register`
handler checked this pass for a newly-landed feature (`server/kennel.lua`'s
`requestDeployKennel`, `server/medkit.lua`'s `useK9Medkit`,
`server/wellbeing.lua`'s `petK9`, `server/partnership.lua`'s
`requestPartnerUp` via `CheckPartnershipEligibility`, `server/combat.lua`'s
`requestBiteHold` via `ValidateCombatRequest`) does correctly check its own
`Config.Features.X` flag before honoring a client-initiated request. The
gap above is specifically about client-side receivers of *server-issued*
instructions, not server-side trust of client requests.

**Recommendation:** dispatch all three findings above (kennel.lua,
medkit.lua, progression.lua) to whichever agent is doing this session's
security sweep, in that priority order (arbitrary entity deletion >
unbounded self-heal > bounded self-speed-boost). Same shape, same fix each
time: add `if not Config.Features.X then return end` as the first line of
each handler body.

### Item 2 — documentation-vs-reality drift: method and hit rate

**Method:** sampled load-bearing status claims specifically about the
features this window's commits touched (Phase 3 combat entry point,
partnership registry, PropDragging), rather than re-sampling old claims
already verified clean in Passes #5/#6.

**4 claims sampled, 2 confirmed accurate, 2 confirmed stale:**

- **HIT.** `server/partnership.lua`'s header (as corrected in `94fbc4e`)
  claims `server/certifications.lua` calls `ForceBreakPartnershipForCitizenId`
  from "three places... [the third with] TWO branches" (RevokeCertification,
  RevokeCertificationOffline, and OnJobUpdate's two branches = 4 total call
  sites). Grepped all four: lines 644, 788, 837, 891 — all real, all
  present. Accurate.
- **HIT.** `REFACTOR_ROADMAP.md`'s Revision 5 (`3b98dca`) claim of raw
  `NetworkGetEntityFromNetworkId` copies at "`server/kennel.lua` (3),
  `client/kennel.lua` (2)... `server/inventory.lua` (1)" — counted all
  three at `HEAD`: 3, 2, 1 respectively. Exact match.
- **MISS.** The same Revision 5 claim's fourth count, "`client/combat.lua`
  (5)," is now stale: **actual count at `HEAD` is 9**, not 5. Cause
  identified, not just observed: `3b98dca` (the roadmap audit) landed
  *before* `94fbc4e` (PropDragging), and PropDragging's drag-handling code
  added 4 more inline `NetworkGetEntityFromNetworkId` + `DoesEntityExist`
  guards (all individually safe — each does include the existence check;
  this is a duplication/maintainability gap, not a security one) without
  adopting the shared resolver. A doc that was correct when written went
  stale within the same review window because unrelated work landed after
  the audit but before this pass — the exact "some of what you're
  checking isn't about code changes" case this role exists to catch.
- **MISS, larger.** `SPEC.md`'s top-of-file Status paragraph (last
  rewritten `885c6ea`, confirmed accurate as of Pass #6) is now wrong in
  three places, and **so are `README.md` and `CHANGELOG.md`, identically**
  — none of the three docs files were touched by any of this window's 5
  commits. All three still say: Phase 3 combat "has no in-game entry
  point" / "is still not reachable by any player" (false since `3536b1e`);
  the partnership registry / `server/partnership.lua` "does not exist,
  only its schema does" (false since `52a58a1`); and (`SPEC.md`/README.md
  only) "`PropDragging` has no code at all" (false since `94fbc4e`). This
  is plain staleness, not a fabricated-control case like `CHANGELOG.md`'s
  `accessScope` claim in Pass #6, but it's the same failure mode at scale:
  a server owner or the next implementing agent reading any of the three
  primary docs right now would be told the wrong thing about three
  separate, currently-shipped-behind-a-flag features.

**Also re-confirmed still accurate, not re-litigated:**
`Config.K9Inventory.accessScope`'s hard `'department'` assert
(`server/inventory.lua:293-300`, Pass #6's fix) is untouched by this
window's commits and the live in-flight diff to that file (which touches a
different section, lines 208+, migrating netId-resolver duplication) does
not go near it.

### Item 3 — per-feature status: implemented / reachable / enabled / reviewed

| Feature | Implemented | Reachable in-game | Enabled (flag) | Reviewed |
|---|---|---|---|---|
| BiteAndHold | Yes | Yes (`client/radial.lua`, `3536b1e`) | No (false) | Yes (2 passes + this one) |
| NonLethalTakedown | Yes | Yes (same radial item set) | No (false) | Yes |
| PropDragging | Yes (`94fbc4e`) | **No** — `RequestDrag`/`ReleaseDrag`/`IsDragEngaged` have zero callers anywhere at `HEAD` (grepped) | No (false) | Partial (author-disclosed gaps only) |
| HandlerPartnership | Yes (`52a58a1`) | Yes — `exports.ox_target:addGlobalPlayer` "Partner Up" option | No (false) | Partial (recovered mid-task-death work, not independently reviewed this pass beyond the header-claim spot check above) |
| HandlerDownDefense | **No** — flag and comments only, no function bodies anywhere | No | No (false) | N/A |
| Recall | **No** — same, flag/comments only | No | No (false) | N/A |
| AgilityAdvanced | Yes (prior window) | Yes | No (false) | Yes (prior passes) |

**Correction, added by a later documentation pass (not by Pass #7 itself —
kept as an appended note per this document's own "layer corrections, don't
rewrite history" convention, matching REFACTOR_ROADMAP.md's practice):**
the two "No" rows above (`HandlerDownDefense`, `Recall`) are stale as of
this correction. Both are now real, implemented code — `server/defense.lua`
+ `client/defense.lua` and `server/recall.lua` + `client/recall.lua`
respectively — both listed in `fxmanifest.lua` and gated on their own
still-`false` flags. This table was accurate at the moment Pass #7 wrote
it; it stopped being accurate before this correction landed.
`REFACTOR_ROADMAP.md` Revision 6 flagged this exact table as due for a
refresh (its Part 6 "near-term item 1") — this note is that refresh,
scoped to a minimal correction rather than rewriting Pass #7's own text.

**In-flight, not yet landed as of this pass's last check:** the working
tree's uncommitted `client/radial.lua` diff adds a "Drag / Release" item
mirroring Bite & Hold's context-sensitive pattern — **this closes the
PropDragging reachability gap above**, found already being fixed while
writing this entry, not left open. Per this project's convention (Pass #4
did the same for a different in-flight fix), not counted as done above
since it wasn't committed at the time of the last check, but flagged here
so the next pass doesn't rediscover it as new. The same uncommitted batch
also migrates `server/kennel.lua`, `server/inventory.lua`, and
`server/combat.lua`'s server-side netId/player-resolver duplication onto
`server/entities.lua`'s shared globals (`ResolveNetworkEntity`,
a new `ResolveConnectedPlayerFromPed` — REFACTOR_ROADMAP items 2 and 2b),
and adds a `reportBiteHoldTargetDied` trust-boundary handler plus a
disclosed red-team note about `PropDragging`'s `IsPlayerDownedOverride`
metadata trust assumption. None of this was deep-reviewed here (heavy
churn mid-pass, per this entry's own scope note above) — worth a first
real look once it commits.

### Verdict

No regressions in the five standing checks. Full syntax/lint baseline
clean at `HEAD`. Three new, real instances of the exact flag-off-safety
defect class this session already fixed once in `client/combat.lua` — none
of them registered/reachable enough to be under live exploit today in the
sense that none has an enabled flag, but all three are reachable via a
locally forged event *regardless* of flag state, which is precisely the
invariant this resource claims to hold everywhere. Two documentation
findings: one roadmap count gone stale mid-window from unrelated work
landing after the audit (low stakes, easy fix), and one bigger one — all
three of `SPEC.md`/`README.md`/`CHANGELOG.md` now describe three
already-shipped-behind-a-flag features as either unreachable or
unimplemented, identically and simultaneously, because none of the five
commits in this window touched any doc file.

### Prioritized recommendation for the invoking session

1. **Dispatch the three flag-off-safety findings** (`client/kennel.lua`
   deploy/remove, `client/medkit.lua` applyMedkitHeal,
   `client/progression.lua` xpTierChanged) to a security-focused pass —
   same one-line fix each, cheap, and this is the second time this exact
   defect class has been found in one session, which suggests a repo-wide
   convention check (e.g. a luacheck-style grep-based check: "every
   `client/*.lua` `RegisterNetEvent` handler must reference its owning
   `Config.Features` flag somewhere in its own body or an enclosing
   file-scope guard") would be worth adding once the current parallel
   batch settles, so a 13th feature doesn't reintroduce it a third time.
2. **Let the in-flight `server/{entities,kennel,inventory,combat}.lua` +
   `client/{combat,radial}.lua` batch land, then do a first real review of
   it** — it's already fixing the PropDragging-reachability gap and the
   REFACTOR_ROADMAP item 2/2b duplication this pass flagged, so re-flagging
   either now would be redundant; the value is in confirming it landed
   clean once committed, not in re-deriving what it's already fixing.
3. **Sync `SPEC.md`, `README.md`, and `CHANGELOG.md` in one pass** once
   the in-flight batch above lands too (so the sync captures both this
   window's changes and that batch's, rather than needing two doc passes
   back to back) — all three need the same three corrections (combat entry
   point, partnership registry existence, PropDragging code existence/
   reachability), so this is one dispatch, not three.
4. **Build HandlerDownDefense and/or Recall** now that their shared
   blocker (the partnership registry) exists — this is the next real
   feature-completion step for Phase 3, distinct from the safety/docs
   cleanup above, and is genuinely unblocked for the first time this
   session.
5. Carried forward unchanged, no new information this window: bark-audio
   placeholder asset gap (two scoped candidate paths from Pass #6, still
   neither attempted); `fxmanifest.lua` still pins no dependency versions.

## 2026-08-24 — Watchdog pass (scheduled trigger, project-lead recurring mode)

Clean, with one stale doc claim corrected and four files cleared for registration.

- **Syntax baseline**: `luac5.4 -p` on all 48 `.lua` files — all parse. `luacheck` 0 warnings / 0 errors, no suppressions.
- **Regression spot-checks — all five intact, each verified against code, not comments**:
  - `AgilityBasicJump` is genuinely read at `client/movement.lua:964` (a real file-scope gate). Note: its only other appearances are in comments in `combat.lua`/`tracking.lua`, so a naive grep looks reassuring for the wrong reason.
  - Role-aware `LeashPairs` intact — `server/main.lua:798-799` still writes `{ partner, isK9 }` for both directions.
  - `RevokeCertificationOffline` still calls `RefreshCertificationCache` (`server/certifications.lua:794`).
  - `client/vehicle.lua`'s `onResourceStop` cleanup present (line 197) and still detaches/restores visibility and collision.
  - `lib.registerRadial` / `lib.addRadialItem` split (the 2026-08-23 hard-error fix) still correct — real calls at `client/radial.lua:226`, `:671`, `:681`. Checked for actual call sites specifically because the surrounding comment block quotes both API names heavily; comment matches alone would have been misleading.
- **Externally-uncertain facts re-verified this session** (by a dependency scout, against live `main` branches via `raw.githubusercontent.com`): `qbx_core` 1.24.0, `ox_lib` 3.39.0, `ox_target` 1.18.1, `oxmysql` 2.14.1, `ox_inventory` 2.47.9 — all exact matches to the recorded "last verified", no drift. Overextended confirmed as the canonical maintained home; CommunityOx is an archived fork. The two `ox_inventory` commits since verification were read and are orthogonal to this resource's usage.
- **Bark audio gap (SPEC.md §7): STILL OPEN.** No real asset. A sourcing attempt found this environment's egress blocked to every audio host; `html/sounds/CREDITS.md` records that, four unverified CC0 leads, and exactly what an operator must supply. Nothing was fabricated.
- **SPEC.md audit — one stale claim found and fixed**: it still described `ContrabandScreenFX`'s timecycle-modifier name as "an unverified candidate". It is no longer unverified — the shipped value `drug_wobbly_shroom` **does not exist** (a game-data extraction of 2806+ modifiers contains only `drug_wobbly`), so the feature would have rendered nothing, silently, forever. Corrected in code and config earlier this session; SPEC.md now says so.
- **Registered after their security review cleared**: `client/propattachment.lua`, `server/propattachment.lua`, `client/bonetool.lua`, `server/bonetool.lua`, `client/proximityaudio.lua`. All ship `false`.
- **Still deliberately unregistered**: `client/fetch.lua`, `server/fetch.lua` — held only because both were being actively edited during this pass, not for any unresolved finding; the sweep covered them and found them clean.
- **Known open, not regressions**: the two XP farms (track-source and contraband-search) are still live and assigned. They remain the reason `0.2.0` is not cuttable.

## 2026-08-24 (18:45 UTC) — Watchdog pass #2 (scheduled trigger)

Clean. No regressions. One unreviewed commit reviewed, two stale SPEC claims corrected.

- **Since pass #1 (`faae5ff`)**: two commits. `e6bc0f4` was mine. `09b52b2` ("Close the contraband-search XP farm; mark NotifyPlayer extraction resolved") landed from an agent while I was mid-work and had **not** been reviewed — reviewed now, and it holds. Specifically I checked the "NotifyPlayer extraction resolved" claim, since two local `NotifyPlayer` definitions survive in `server/admin.lua` and `server/bonetool.lua` and I had earlier relayed a peer's concern that these were leftovers. **They are not leftovers**: both are deliberate thin wrappers delegating to `_G.NotifyPlayer` with a per-file title, and each carries a comment explaining that a bare call would resolve to the same-named local and self-recurse. The claim is accurate; my earlier relay of that concern was based on a stale read.
- **Syntax/lint**: `luac5.4 -p` on all 48 `.lua` files — all parse. `luacheck` 0 warnings / 0 errors, no suppressions. Working tree clean at pass start.
- **Regression spot-checks — all five still intact**: `AgilityBasicJump` file-scope gate present in `client/movement.lua`; both `LeashPairs` write sites still carry `isK9` (`server/main.lua:798-799` — the other grep hits are comments); `RevokeCertificationOffline` still calls `RefreshCertificationCache` within its own body; `client/vehicle.lua`'s `onResourceStop` handler present; `lib.registerRadial`/`lib.addRadialItem` split still has 4 real code-level calls.
- **Bark audio gap (SPEC.md §7): STILL OPEN, unchanged.** `html/sounds/` contains only `CREDITS.md`. A resource-wide search for `.ogg`/`.wav`/`.mp3`/`.awc` returns nothing. Nothing fabricated.
- **Dependencies**: re-verified against live sources earlier this same day — all five exact matches to the recorded "last verified", Overextended canonical, CommunityOx archived. Not re-fetched this pass; no signal suggesting drift within the interval.
- **SPEC.md audit — two stale claims found and corrected**: it still said none of `ProximityAudioFX`/`PropAttachments`/`FetchMechanic` were listed in `fxmanifest.lua` and that the bone tool was "also not yet wired". Both were overtaken by `faae5ff`, which registered propattachment (both halves), bonetool (both halves) and proximityaudio after their security review cleared. Fetch is now the only unregistered one. Worth noting the paragraph had explicitly warned the reader to verify `fxmanifest.lua` directly if time had passed — that warning did its job.
- **Both XP farms are now CLOSED** (`09b52b2` contraband-search, `e6bc0f4` track-source). Pass #1's log entry listing them as open is superseded.
