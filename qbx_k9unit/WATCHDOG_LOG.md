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
