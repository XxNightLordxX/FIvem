# Watchdog log

One line per recurring watchdog pass, newest last. The point of this file is
so the next pass knows what was already covered and does not re-derive it.

Passes before 2026-08-26 were recorded only as `Watchdog:` markers in commit
messages; they are reconstructed here from `git log --grep="Watchdog:"` so
the history is in one place. From now on, add a line here as part of the
pass itself.

| Date | Summary |
|---|---|
| 2026-08-23 | Pass #2 — found and closed 3 real Phase 2 gaps, no regressions |
| 2026-08-24 | Pass #5 — recovered interrupted-agent work, verified no regressions |
| 2026-08-24 | Pass #6 — one real finding: docs described a control that does not exist |
| 2026-08-24 | Registered cleared Phase 5 files, fixed two inverted/stale doc claims |
| 2026-08-25 | Clean; finished the documentation consolidation |
| 2026-08-26 | Corrected a wrong security claim in the manifest, closed three dangling citations |
| 2026-08-26 | First pass recorded in a file rather than only a commit marker; clean, one item honestly unverified |
| 2026-08-26 | Clean. 85 commits reviewed, 5 regression spot-checks pass, dependency status re-verified upstream, bark-audio gap confirmed closed. No findings. |
| 2026-08-27 | Watchdog's own checks all clean. The real findings this pass came from a separate 12-agent production-readiness audit running alongside it -- including two live bugs the watchdog's fixed checklist would never have caught. |

## 2026-08-26 — detail

Checked, in the order the trigger asks for them.

**Commits since the last pass:** 85, all from one long working session.
Every one was reviewed as it landed rather than in bulk here, and each
behavioural change in them carries a test that was proved to fail without
the fix. Nothing unreviewed.

**Externally-uncertain facts, re-verified against source rather than
memory:**

- Dependency maintenance status — **unchanged, and the docs are accurate.**
  `overextended/ox_lib` is not archived, last pushed 2026-08-17, 413 stars;
  `overextended/oxmysql` not archived, updated 2026-08-23;
  `overextended/ox_target` not archived, updated 2026-08-16. All three are
  alive. `CommunityOx` — the community fork that existed while Overextended
  was briefly dormant in 2025 — is itself archived (April 2026), exactly as
  `DEVELOPER_REFERENCE.md`'s "Dependency maintenance" section already
  states. Nothing to change. Worth re-checking periodically anyway, since
  this is the one fact in this project that can go stale without anybody
  touching the code.
- Bark-audio placeholder gap — **resolved, and has been since 2026-08-25.**
  All five files in `html/sounds/` are genuine Ogg Vorbis (verified with
  `file`, not assumed from the extension), are listed in `fxmanifest.lua`'s
  `files{}` block so they actually reach clients, and are licensed and
  attributed in `html/sounds/CREDITS.md` (OGA-BY 3.0 and CC-BY 3.0/4.0).
- Still open, and blocked on the owner rather than on us:
  `html/images/logo.png` is still the 2.7KB placeholder. Already disclosed
  in `KNOWN_ISSUES.md`; needs a real file from the owner.

**Regression spot-checks — all five pass, verified in real code rather than
in comments (an early grep of mine matched only prose and had to be
redone):**

- `AgilityBasicJump` still read — `client/movement.lua:1693`.
- Role-aware `LeashPairs` structure intact — `server/main.lua:1368-1369`
  still writes `{ partner = ..., isK9 = ... }` for both parties.
- `RevokeCertificationOffline` still refreshes the certification cache —
  via `EndK9AccessForCitizenId`, which also calls
  `pcall(EndActiveEffectForHolder, src)` and
  `ForceBreakPartnershipForCitizenId`.
- Vehicle `onResourceStop` cleanup present on both sides —
  `client/vehicle.lua:911`, `server/vehicle.lua:393`.
- `client/radial.lua`'s `lib.registerRadial` / `lib.addRadialItem` split
  still correct — five `registerRadial` calls, two `addRadialItem`, the
  shape the 2026-08-23 hard-error fix established.

**Documented "fixed" claims re-checked against code:** `SPEC.md` no longer
exists — it was consolidated into `README.md` and
`DEVELOPER_REFERENCE.md`, so the trigger's "SPEC.md §7" reference is itself
stale and a future pass should read it as "the docs" generally.
`KNOWN_ISSUES.md`'s "Fixed — worth remembering" section carries 17 claims;
four were sampled (cooldown-`0` clamping, mid-hold teardown on decertify,
the both-parties-are-K9 partnership rejection, the citizenid-keyed pursuit
sprint cooldown) and all four still hold in real code.

**Health baseline:** `luac5.4 -p` clean on all 189 `.lua` files; `luacheck`
0 warnings / 0 errors across 188; 99 Lua specs and 33 HTML specs green.

**Findings: none.** Nothing was manufactured to fill this section.


## 2026-08-27 — detail

**A note on this pass, because it matters more than the result.** Every
check the trigger asks for came back clean. Separately, and at the same
time, a twelve-agent production-readiness audit found two genuinely serious
live bugs. Neither was anywhere near this checklist:

- Thermal and night vision could be switched on but never off, because both
  getters named a native that does not exist. Silent since the day they were
  written. The test suite passed throughout, because the test invented the
  same two names in its own sandbox.
- An unarmed player could switch off the abilities of the dog chasing them
  by spamming a payload-less event until the dog hesitated.

That is worth recording plainly: **a watchdog that only re-checks the things
already known to have broken will keep coming back clean while real bugs
accumulate beside it.** The five spot-checks below are still worth running —
they are cheap and they pin real past regressions — but they are a
regression net, not an audit, and this pass should not be read as "the
resource is fine".

**1. Commits since the last pass:** a large batch from one long session
(scent-tracking merge, command consolidation, feature grouping, roster data
layer, per-dog speed/stamina/scent overrides, closeable kennel, danger
warnings, Discord logging, bowls). Each was reviewed as it landed, each
behavioural change carries a test proved to fail without its fix. Nothing
unreviewed.

**2. Externally-uncertain facts, re-verified against source rather than
memory:**

- Dependencies — **all three alive.** `overextended/ox_lib` 3.39.0,
  `overextended/ox_target` 1.18.1, `overextended/oxmysql` all reachable and
  maintained. Unchanged from the last pass; the docs remain accurate.
- Bark audio — **resolved and still resolved.** All five files in
  `html/sounds/` verified as genuine Ogg Vorbis with `file` rather than
  trusted by extension, all listed in `fxmanifest.lua`'s `files{}` block so
  they actually reach clients, and attributed in `html/sounds/CREDITS.md`.

**3. Regression spot-checks — all five pass:**

- `AgilityBasicJump` still read in real code.
- Role-aware `LeashPairs` structure intact in `server/main.lua`.
- `RevokeCertificationOffline` still refreshes the certification cache.
- Vehicle `onResourceStop` cleanup present on both sides.
- `client/radial.lua`'s `lib.registerRadial` / `lib.addRadialItem` split
  still correct. The raw counts have grown a lot since the last pass (11 and
  9 including comments), which looks alarming and is not: all three real
  `addRadialItem` calls still register the single `k9unit_open` root opener,
  which is exactly the convention the 2026-08-23 hard-error fix
  established. Counting lines rather than calls would have reported a
  regression that is not there — worth knowing for the next pass.

**4. Documented "fixed" claims:** `SPEC.md` still does not exist — it was
consolidated into `README.md` and `DEVELOPER_REFERENCE.md`, so the
trigger's "SPEC.md §7" reference is itself stale and should be read as "the
docs" generally. A dedicated comment-truth pass ran this session and
corrected five genuinely stale claims, so this ground is freshly covered.

**5. Health baseline:** `luac5.4 -p` clean on all 207 `.lua` files.

**Findings from the watchdog's own checks: none.** Nothing was manufactured
to fill this section — see the note at the top for why that sentence is
worth less than it sounds.
