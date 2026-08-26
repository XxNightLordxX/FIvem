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
