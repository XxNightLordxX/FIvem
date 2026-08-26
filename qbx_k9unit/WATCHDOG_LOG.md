# Watchdog log

One line per pass. Newest first. A pass records what was **actually
checked**, not what was assumed — an unverified item is written down as
unverified rather than left looking checked.

---

## 2026-08-26 — first recorded pass

**Clean. No regressions found. One item genuinely could not be verified.**

**Checked and passing:**

| Check | Result |
|---|---|
| Every `.lua` parses (`luac5.4 -p`) | 175 files, all parse |
| `luacheck` | 0 warnings, 0 errors |
| Lua spec suite | 90 files, all pass |
| HTML spec suite | 23 files, all pass |
| `AgilityBasicJump` still read in code | 5 call sites |
| `LeashPairs` still role-aware | Still `{ partner = …, isK9 = <bool> }`, not model-derived |
| `RevokeCertificationOffline` refreshes the cert cache | 3 call sites inside the function |
| `client/vehicle.lua` stop-cleanup | Present, 7 references |
| `client/radial.lua` registerRadial/addRadialItem split | Present, 23 references — the 2026-08-23 hard-error fix holds |

**Bark audio asset gap — mostly RESOLVED since it was last recorded.**
Five real assets now ship: `bark.ogg`, `bark_alert.ogg`,
`bark_aggressive.ogg`, `bark_calm.ogg`, `growl_ambient.ogg`. Two of the
six mapped names still have no file — `door_scratch` and `door_nudge`.
Those degrade to silence by design and `client/audio.lua` says so, so
this is a known placeholder rather than a defect. Separately, the
RAGE-native sound path (`PlaySoundFromEntity` against a
`qbx_k9unit_sounds` bank) remains genuinely inert: no `.awc` ships and
no `data_file` is declared. The working sounds all go through the NUI
path.

**SPEC.md no longer exists** — documentation was consolidated from
twenty files to nine, so the "check SPEC.md for stale Done claims" step
has no target. Its role is now split across `README.md`,
`OPERATOR_RUNBOOK.md`, `PLAYER_GUIDE.md`, `DEVELOPER_REFERENCE.md` and
`ISSUES.md`. A documentation-accuracy pass over those five ran earlier
in this same session and corrected several false claims, so they are
freshly checked rather than stale.

**NOT VERIFIED THIS PASS — stated plainly rather than glossed:** the
ox_lib / ox_target / oxmysql (Overextended / CommunityOx) maintenance
status. That question needs live upstream sources and I did not fetch
them, so nothing has changed in what we know since it was last raised.
Do not read this pass as confirming those dependencies are healthy.

**Commits reviewed:** the fifteen since the last recorded state, all
from this session's quality wave. Every one was gated before push
(lint + both suites, verified against the exact staged tree rather than
the working tree, since ~20 agents were editing concurrently).
