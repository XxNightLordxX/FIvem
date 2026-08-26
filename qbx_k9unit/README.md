# qbx_k9unit

A K9 unit add-on for Qbox police/security departments: certification,
leash, vehicle loading, tracking, contraband search, combat mechanics,
wellbeing, XP, a supply shop, a leaderboard, training drills, and an
in-game "command tablet" for high command to run all of it.

Proprietary, not open source — licensed for use on the purchaser's own
server only. See `LICENSE.md` for the full terms.

## How a K9 gets made

Two ways, both server-authoritative:

- **Certify an existing department member.** A qualifying supervisor (or,
  by default, the officer themselves) grants a certification with
  `/k9certify` or the "Certify K9 Handler" ox_target option. The target
  does **not** need to already look like a dog — any member of an eligible
  department is a valid target.
- **High command assigns the role directly**, from the K9 Command Tablet,
  to any citizenid, with a chosen model.

By default (`Config.K9Appearance.applyPedModelOnCertify = true`), either
path **actually changes that player's character** into the configured K9
ped — their original appearance is recorded first, so losing the role
(revoke, job change, or a high-command "revert") changes them back. If you
don't want this resource ever touching a player's appearance, set
`applyPedModelOnCertify = false`; certification then behaves the old way —
a pure access-control layer on top of a character who already chose to
look like a dog on their own.

The "K9 role" itself (what you're allowed to *do*) and "what you look
like" are independent: `Config.K9Appearance.requireK9ModelForRole`
(default `false`) means a role-holder on any model, including an ordinary
human, still gets every K9 ability. Every server-side check re-verifies
the role live — nothing about it is cached client-side or trusted from
what a player's game claims.

## Requirements

Install and start these **before** `qbx_k9unit` (enforced by
`fxmanifest.lua`'s `dependencies` block — FXServer refuses to start this
resource without all five present):

| Resource | Source | Used for |
|---|---|---|
| [`qbx_core`](https://github.com/Qbox-project/qbx_core) | Qbox-project | Player data, jobs, ranks |
| [`ox_lib`](https://github.com/overextended/ox_lib) | overextended | Notifications, callbacks, the radial menu, locales |
| [`ox_target`](https://github.com/overextended/ox_target) | overextended | Every walk-up/look-at interaction (leash, certify, search, shop, etc.) |
| [`oxmysql`](https://github.com/overextended/oxmysql) | overextended | Database access |
| [`ox_inventory`](https://github.com/overextended/ox_inventory) | overextended | Items, stashes, the K9 supply shop, contraband search |

Last checked compatible against: `qbx_core` 1.24.0, `ox_lib` 3.39.0,
`ox_target` 1.18.1, `oxmysql` 2.14.1, `ox_inventory` 2.47.9. Older versions
may work; they simply haven't been re-checked.

This resource also ships an auto-detection layer (`Config.Compat`) that
can talk to some non-`ox_*` inventories/target scripts/frameworks if
that's what your server actually runs. It changes which script this
resource *talks to* at runtime — it does **not** remove the five hard
dependencies above. `ox_target` and `ox_inventory` still have to be
installed and started, full stop, even if `Config.Compat` ends up routing
around them for a specific system. Run `/k9compat` in-game (high command
only) to see what it actually detected.

**No ESX support beyond what `Config.Compat` can auto-detect.** This
resource's own security/permission model is written against Qbox's job/
grade shape; a QBCore- or ESX-flavored framework can be picked up by
`Config.Compat` for player-lookup purposes, but `qbx_core` remains a hard
dependency regardless.

## Installing

1. Drop `qbx_k9unit` into your `resources` folder.
2. **Set up the database.** Easiest path — from the resource's `sql/`
   folder:
   ```bash
   cd qbx_k9unit/sql
   ./k9_setup.sh -d your_database_name -u your_mysql_user
   ```
   This checks your database, backs it up, then runs `install.sql` and
   every file under `sql/migrations/`, safely, whether this is a fresh
   install or an upgrade. See `OPERATOR_RUNBOOK.md` for the manual,
   file-by-file version and for running with **no database at all**.
3. Add `ensure qbx_k9unit` to `server.cfg`, after the five dependencies
   above.
4. Open `config.lua` and set, at minimum:
   - `Config.Departments` — your real job names and rank thresholds.
   - `Config.Peds` — which ped models count as a K9 (any model works, not
     just dogs — see its own comments).
   - `Config.K9Vehicles` — vehicles a K9 can load into.
   - `Config.TrainingZones` and `Config.K9EquipmentShop.locations` — both
     ship with a single placeholder coordinate near Mission Row PD; move
     or add to them.
   See `OPERATOR_RUNBOOK.md` for the full go-live checklist (item names
   you need to create in `ox_inventory`, what to check before combat
   features go live, and the one flag you should turn back off).
5. Certify your first handler — see `OPERATOR_RUNBOOK.md`.

`config.lua` is long but ships with its own plain-English index at the
top ("WHAT IS IN THIS FILE") — search it for the setting you want rather
than hunting by eye. Nearly every one of its ~50 feature flags ships
`true`; the two exceptions are `CameraFeedPiP` (no implementing code
exists — the engine has no native for it) and `CertificationExpiry`
(off by default because turning it on starts an expiry clock on every
certification that already exists).

## Documentation map

- **`PLAYER_GUIDE.md`** — for anyone playing as a K9 or working with one.
- **`OPERATOR_RUNBOOK.md`** — for whoever runs this server: setup,
  configuration checklist, and what to do when something breaks.
- **`DEVELOPER_REFERENCE.md`** — full design history, the combat
  trust-boundary write-up, and internal file-by-file contracts, for
  anyone modifying this resource's code.
- `CHANGELOG.md` / `ISSUES.md` / `K9_IDEAS.md` — history, known problems,
  and unbuilt ideas.

## Public API (exports)

Both sides expose a small, deliberately **read-only** surface — no
export can grant, revoke, or mint anything. Every table returned is a
fresh copy, and every export fails closed (a bad argument returns `false`/
`0`/`nil`, never an error). Each side carries its own `GetAPIVersion()`;
check `.major` before relying on either.

### Server (`server/exports.lua`) — version `1.0.0`

| Export | Signature | Returns |
|---|---|---|
| `GetAPIVersion` | `()` | `{ major, minor, patch, string }` |
| `HasK9Access` | `(source)` | `boolean` — can this connected player use K9 features right now |
| `IsConfiguredK9Model` | `(modelHash)` | `boolean` — is this hash one of `Config.Peds` |
| `IsK9Department` | `(jobName)` | `boolean` — is this job a key in `Config.Departments` |
| `GetActivePartnerCitizenId` | `(citizenid)` | `partnerCitizenid, isK9` or `nil, nil` |
| `IsActivePartnerOf` | `(citizenid, allegedPartnerCitizenid)` | `boolean` |
| `GetXP` | `(citizenid)` | `number`, `0` if unknown |
| `GetXPTier` | `(citizenid)` | `{ xp, label, speedMultiplier, scentRangeMultiplier }` |
| `IsFeatureEnabled` | `(featureKey)` | `boolean?` — `nil` if the key isn't recognized |

### Client (`client/exports.lua`) — version `1.1.0`

| Export | Signature | Returns |
|---|---|---|
| `GetAPIVersion` | `()` | `{ major, minor, patch, string }` |
| `HasK9Access` / `CanShowK9UI` | `()` | `boolean` (yields on a server round trip, ~1s cached) |
| `IsOwnModelK9` / `IsLeashed` / `IsInK9Vehicle` / `IsPartnered` / `IsTracking` / `IsThermalVisionActive` / `IsNightVisionActive` / `IsBiteHoldEngaged` / `IsDragEngaged` / `IsFetchCarryEngaged` / `HasFreshDefensePrompt` | `()` | `boolean` |
| `GetPartnerServerId` | `()` | `number?` |
| `GetCurrentXPTier` | `()` | `{ xp, label, speedMultiplier, scentRangeMultiplier }?` |
| `GetActiveTrackType` | `()` | `'scent' \| 'blood' \| 'gunpowder' \| nil` |
| `GetDefenseSuggestedTargetNetId` | `()` | `number?` |

Client-side state here is display/UI convenience only, never a security
boundary (a modified client can always lie to itself). For anything
security-relevant, use the server export of the same name.

No **action** export exists on either side (no `RequestPartnerUp`,
`GrantCertification`, `AwardXP`, etc.) — every self-initiated action
carries its own consent/proximity/cooldown logic in this resource's own
UI flow that a direct export call would bypass.

Six outbound events also fire under real gameplay conditions, not gated
on any feature flag: `qbx_k9unit:events:certificationGranted`,
`certificationRevoked`, `partnershipEstablished`, `partnershipEnded`,
`searchCompleted`, `xpTierReached`. `AddEventHandler` for any of these
from another resource.
