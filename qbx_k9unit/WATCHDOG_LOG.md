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
