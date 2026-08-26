# qbx_k9unit — Operator Runbook

A step-by-step guide for whoever runs this server — what to install, what
to configure before real players touch it, and what to do when something
breaks. For player-facing behavior see `PLAYER_GUIDE.md`; for design
rationale and internals see `DEVELOPER_REFERENCE.md`.

**The state of the feature flags, in one sentence:** nearly every one of
`config.lua`'s 56 `Config.Features` flags ships `true`. The one
exception is `CertificationExpiry` (off on purpose — but it is safe to
turn on: every certification that already exists keeps no expiry date
unless someone explicitly renews it, and only new grants get one. It is
off because starting a recertification cycle is a decision to make on
purpose, not because switching it on would strip anybody). Read
`config.lua`'s own comments before flipping anything; they're written for
this, not just for developers.

**A note on `CameraFeedPiP` specifically**, since its name overpromises:
it ships `true`, and it is real, but it is not a literal
picture-in-picture — a true simultaneous two-camera inset is not possible
with FiveM's current natives (confirmed against the full native list, not
assumed). What it actually does: a handler or K9 with an active partner
can press a key (`H` by default, `Config.CameraFeed.toggleKey`) to switch
their *entire screen* to their partner's viewpoint until they press it
again. It requires `HandlerPartnership` to be on and an active partnership
between the two players; see `PLAYER_GUIDE.md` for the player-facing
description and `Config.CameraFeed` in `config.lua` for the tunables
(field of view, eye-height offsets per body type).

---

## 1. Install

### Fresh install

1. Drop `qbx_k9unit` into `resources`.
2. Set up the database — see "Database setup" below.
3. Add `ensure qbx_k9unit` to `server.cfg`, **after** `qbx_core`,
   `ox_lib`, `ox_target`, `oxmysql`, and `ox_inventory`. All five are hard
   dependencies (`fxmanifest.lua`) — FXServer refuses to start this
   resource if any is missing, and that check happens before `config.lua`
   is ever read.
4. Work through "Go-live checklist" below before real players connect.
5. Certify your first handler — see the certification model overview in
   `README.md`, or just run `/k9certify [your own server id]` once you're
   in an eligible department at a qualifying rank.

### Database setup

Recommended path — from `sql/`:

```bash
cd qbx_k9unit/sql
./k9_setup.sh -d your_database_name -u your_mysql_user           # do it
./k9_setup.sh -d your_database_name -u your_mysql_user --dry-run  # just show the plan
```

Safe to run on a brand-new database, and just as safe to run again on a
server you installed this on long ago — every step is individually safe
to repeat. Each run, in order: checks your database
(`sql/preflight_check.sql`, stops on any `!!` line), **backs up your
entire database automatically** (every table, not just this resource's —
this step cannot be skipped, and nothing below it runs if it fails), then
runs `sql/install.sql` followed by every file in `sql/migrations/` in
filename order, then reports every table found with its row count and a
final `SUCCESS`/`FAILED` line.

**Minimum database engine: MySQL 5.7.8+ or MariaDB 10.2+** (a generated
column in `k9_certifications` needs it — an older engine leaves the
schema half-built partway through).

**Manual path**, if you'd rather not use the script: run `sql/install.sql`
once (safe to re-run; every `CREATE TABLE` is `IF NOT EXISTS`), then every
file in `sql/migrations/` in numeric filename order (also safe to re-run).
A fresh install only strictly needs `install.sql`; the migrations exist to
bring an *older* database up to the same shape. Skipping a migration on an
upgrade can leave a table missing a column or a safety constraint with no
error at the time — see `sql/migration_status.sql` to check what's
actually applied.

---

## 2. Go-live checklist

Work through these before real players see this resource:

- **`Config.Departments`** — your real job names, and per department:
  `certifierGrade` (who can certify), `auditGrade` (the *rank* required to
  run the read-only audit commands — on the shipped default config,
  reaching this rank is not enough by itself; see "Per-person feature
  control" in §5 below, `AdminAuditCommands` needs an individual grant
  too, for every single person, including a department boss),
  `highCommandGrade` (who bypasses every other
  rank check and can mint XP — set this deliberately, and higher than
  `auditGrade`), `nonComplianceAlertGrade`.
- **`Config.Peds`** — which ped models count as a K9. Any model works,
  including a non-dog custom streamed one.
- **`Config.K9Vehicles`** — which vehicles a K9 can load into.
- **`Config.TrainingZones`** and **`Config.K9EquipmentShop.locations`** —
  both ship with a single placeholder coordinate near Mission Row PD.
  Move them, or the training yard/shop simply has nowhere real to be used
  from.
- **Create these `ox_inventory` items** — none exist on a fresh install,
  and a missing one doesn't error, it just silently never works:
  `k9_medkit` (K9 Medkit), `k9_treat` (Feed K9), `k9_meat_bait` and
  `k9_ultrasonic_whistle` (Distraction), and `k9_tablet` **only if** you
  set `Config.CommandTablet.openMode` to `'item'` or `'both'` (default is
  `'both'`).
- **A `water_bowl`-modeled world object**, if you want Fatigue's faster
  near-a-rest-source recovery — `Config.Wellbeing.Fatigue.restSources` is
  an unverified guess at a model name; confirm it exists on your server or
  change it. Fatigue still works without one, just at the slower baseline
  rate.
- **`Config.K9Appearance.applyPedModelOnCertify`** (default `true`) —
  decide this deliberately. On, certifying someone (or granting them K9
  access from the tablet) **actually changes that player's character** to
  a K9 model, and reverts it on revoke. Off, this resource goes back to
  being a pure access-control layer over a character who already chose to
  look like a dog — nothing about appearance is ever touched.
- **`Config.CommandTablet.branding`** — your server name, logo
  (`html/images/logo.png` — replace the file, the manifest entry doesn't
  need to change), and starting theme colors. High command can restyle it
  live afterward if `TabletTheming` is on.
- **Replace `Config.SearchContrabandItems`' placeholder item names**
  (`'weed_bud'`, `'coke_brick'`, etc.) with your own economy's real item
  names before trusting Search Zones results.

---

## 3. Turn this back off: `BoneSweepDevTool`

**`Config.Features.BoneSweepDevTool` ships `true`.** Its own code comment
says, in these words, never to enable it on a production server — it
spawns and attaches real objects in the world on command. Unless you are
actively running the calibration sweep described below, on a private dev
server, turn it off now:

1. Set `Config.Features.BoneSweepDevTool = false` in `config.lua`.
2. Confirm `qbx_k9unit_enable_bone_dev_tool` is not set to `1` anywhere in
   `server.cfg` — this is the second, independent gate (below).
3. **Restart the resource.** Like every command here, `/k9bonetool` is
   registered once at resource start; flipping the flag alone does not
   unregister it. It stays reachable until the next restart.

**`/k9bonetool` is not ACE-gated**, and never was set up as an admin
grant — it needs all three of the following at once:

- `Config.Features.BoneSweepDevTool = true`, **and**
- the convar `setr qbx_k9unit_enable_bone_dev_tool 1` set in `server.cfg`
  (without it, the command doesn't exist regardless of the flag or
  anyone's rank), **and**
- the caller must be a **boss** (`job.isboss == true`) of a job in
  `Config.Departments` — a numeric grade is not enough for this tool
  specifically.

It also refuses to run from the server console — every subcommand acts on
"your own current ped," which the console doesn't have.

**What it's for:** finding the correct bone index on a quadruped skeleton
for `PropAttachments`' vest and `FetchMechanic`'s mouth-carry, both of
which currently ship attached at the root bone (index `0`) — visible but
in the wrong spot. To run it: set both gates above on a dev server, join
as a K9-modeled department boss, then `/k9bonetool help` for the full
workflow (`known` for candidates, `goto`/`next`/`prev` to preview, `test`
to confirm with a real attached object, `stop` to clean up). Record the
index you find in `Config.PropAttachments.boneIndex` or
`Config.FetchMechanic.mouthBoneIndex` (and flip `mouthCarryMode` from
`'fake'` to `'attach'`). Turn the flag back off and restart before this
server goes anywhere near production.

---

## 4. Before you trust the combat features in production

`BiteAndHold`, `NonLethalTakedown`, and `PropDragging` ship `true`. For a
**player** target, the actual restraining effect (input-disable, forced
ragdoll, move-rate reduction) runs on *that player's own client* — a
modified client can simply ignore it. This resource's client event
handlers reject a locally-forged event (`if source ~= 65535 then return
end`), which closes the obvious exploit, but this guard has never been
independently confirmed in-engine against every possible failure mode.
See `DEVELOPER_REFERENCE.md`'s combat trust-boundary write-up for the full
reasoning and the exact sequenced test to run on a dev client if you want
to verify it yourself before going live.

One more gate worth knowing about: if high command has granted the
"Bite & Hold / Non-Lethal Takedown" certification-tier capability to any
tier (§5's "Certification tier editor"), only handlers/K9s holding a
tier with that capability can bite or take down — on a fresh install, no
tier has it, so this gate does nothing until someone opts into it.

**`Config.Combat.NonComplianceDetection.enabled` ships `false`** even
though the three mechanics above are on — turn it on if you want a log
(or staff notification) of suspected non-compliance. It only ever logs or
notifies; it never takes an automated punitive action.

Combat only ever targets a player your dispatch integration has flagged
**wanted** (`Config.Combat.RequireWantedStatus`, default `true`) — wire
`Config.Combat.WantedStatusCheckOverride` to your own dispatch resource;
the built-in fallback guess (reading `metadata.wanted` off `qbx_core`
player data) is lower-confidence and meant as a stopgap only.

---

## 5. The command tablet and high command

`Config.Features.CommandTablet` (on by default) is the in-game UI for
everything below. It is a **view only** — every action it offers is
re-authorized server-side exactly as if the equivalent chat command had
been typed, so a modified client sending a fake NUI callback gains
nothing.

- **Opening it**: `Config.CommandTablet.openMode` — `'command'`
  (`/k9tablet` by default), `'item'` (an `ox_inventory` item, must already
  exist in your items table), or `'both'` (default).
- **High command** (`Config.Departments[job].highCommandGrade`, or
  `job.isboss`) gets the full roster, and can certify, assign/revert the
  K9 role and appearance for any citizenid, grant XP (`/k9givexp`, capped
  by `Config.HighCommand.maxXpPerGrant`), and grant/revoke the four named
  permissions in `Config.Permissions` (`k9.access`, `k9.certify`,
  `k9.audit`, `k9.givexp`) to specific people.
- **Per-person feature control** works two ways, and they are not the same
  tool:
  - **Require a grant** (`Config.FeatureControl.RequireGrant`) — a short,
    named list of features (currently: `BiteAndHold`, `NonLethalTakedown`,
    `PropDragging`, `AdminAuditCommands`, `FindAlerts`, `ScentTrailHunt`,
    `PursuitSprint`, `ScentLineup`, `SARCalls`) that need an individual
    grant from the tablet before anyone can use them **even when their
    global flag is on**. This is opt-IN by default: nobody has any of
    these nine until high command grants them, one person at a time.
    **Note this includes `AdminAuditCommands`** — meeting the
    `auditGrade` rank (or being a department boss, or even being high
    command) is not enough on its own; the `/k9audit*` commands also need
    this explicit grant, for every single person who runs them, on the
    shipped default config.
  - **Block one person** — a much broader mechanism, covering most named
    features in this resource (leash, tracking types, search, combat,
    fetch, kennel, medkit, K9 inventory, bark, door interaction, the
    leaderboard, and more), not only the nine above. This is opt-OUT: a
    feature works normally for everyone until high command explicitly
    blocks it for one specific person or K9, at which point that one
    mechanic refuses for them alone (never for the whole server) until
    unblocked. A handful of purely cosmetic/client-only effects (radial
    menu structure, thermal/night vision, the vitality HUD, ambient audio,
    the camera feed, and a few others) can also be blocked this way, with
    the same disclosed limit every client-side check in this resource has:
    it only works on an ordinary, unmodified client, never against someone
    running modified game files.
  - Either way, **a server-wide flag being `false` always wins** — a
    personal grant or the absence of a block can never turn on something
    switched off globally.
- **Runtime feature control** (`Config.Features.RuntimeFeatureControl`) —
  high command can flip most flags live from the tablet, without editing
  `config.lua`, and can also tune a large number of individual gameplay
  numbers live (ranges, cooldowns, thresholds, XP amounts, and similar —
  not every number in `config.lua`, only the ones a server-side handler
  actually re-reads on each use; the tablet lists exactly which). Whether
  a flag flip or a number change takes effect immediately or needs a
  resource restart depends on how that specific feature registers its own
  commands/events — the tablet tells you which for each one. Two flags,
  `HighCommand` and `PermissionGrants`, can never be toggled this way
  (they gate the authorization check the tablet itself depends on).
- **Certification tier editor** — high command can rename the three
  shipped tiers (Trainee/Certified/Senior), add new ones, reorder them,
  and grant each tier a **capability** from a small, fixed list, all from
  the tablet. Two things worth knowing before touching this:
  - **On a fresh install, capability enforcement does nothing at all.**
    All three shipped tiers start with an empty capability list, and a
    capability only starts being checked, resource-wide, the moment high
    command grants it to **any one tier**. Until then, tier does not
    restrict anything — it is purely a label. This is deliberate (nobody
    should get a new restriction just because this feature existed), but
    it means the first time you grant a capability to a tier, you are
    switching on a real gate for *every* handler and K9 in *every*
    configured department, not just the one you were looking at.
  - Only two of the five listed capabilities currently gate anything:
    **"Bite & Hold / Non-Lethal Takedown"** (grant it to a tier and *only*
    that tier can bite or take down — dragging is unaffected, and anyone
    already mid-hold can still be released) and **"Eligible to hold K9
    specializations"** (grant it to a tier and only that tier can be given
    narcotics/explosives/patrol — anyone who already holds one keeps it).
    The other three are reserved for mechanics that don't exist yet in
    this resource and currently do nothing if granted.
- **Tablet theming** (`Config.Features.TabletTheming`) is purely cosmetic
  — it can never change what anyone is authorized to do or see.

---

## 6. Running with no database

`Config.Database.enabled = false` is a real, supported mode: you skip
importing every `.sql` file entirely, and every feature still works
tonight. Read this in full before choosing it:

- **What you lose**: certifications, XP, partnerships, permission grants,
  runtime overrides, tablet theming, and K9 appearance assignments are
  held in memory only, for as long as the server keeps running. A crash,
  update, or scheduled restart loses all of it — everyone starts over.
  Nothing corrupts and nothing crashes; it simply never remembers past
  today.
- **What's permanently gone, not just unsaved**: the audit trail. No
  record of who certified whom, no search log, no permission-grant
  history. If a dispute comes up, there's nothing to check.
- **`oxmysql` is still required, installed and started, regardless.** It
  is a hard `fxmanifest.lua` dependency, and that check runs before
  `config.lua` is ever read — no setting inside this resource can route
  around it. `Config.Database.enabled = false` means this resource never
  sends `oxmysql` a query and needs none of its own tables to exist. It
  does **not** mean you can remove `oxmysql` from your server.
- This is not the recommended way to run a real server — it exists for a
  trial, a quick test, or someone who genuinely doesn't want to do a
  database import. If you can run the setup script above, do; your
  handlers keep what they earned.

---

## 7. Uninstalling / rolling back

Everything below is run by hand (phpMyAdmin, HeidiSQL, or the `mysql`
CLI) — nothing here runs automatically, and the resource itself never
touches these files.

**Back up first, always:**

```bash
cd qbx_k9unit/sql/rollback
./backup_k9_tables.sh -d YOUR_DATABASE_NAME -u YOUR_MYSQL_USER
```

Read-only; saves every table this resource owns (see the script's own
header for the current full list — certifications, search log,
partnerships, progression, permissions, specializations, runtime
overrides, tablet theme, ped assignments, certification tiers, equipment
shop locations, and each one's own audit table) into one timestamped
file, and prints the exact command to restore it. If you don't see
`BACKUP OK`, stop and fix whatever failed before doing anything else.
`k9_search_log` specifically cannot be rebuilt from anything else — it's
your only record of who searched whom.

Before an install or migration (protecting the *whole* database, not just
this resource's tables), use `./backup_full_database.sh` instead — or
just use `k9_setup.sh` (section 1), which runs that automatically.

**Common situations:**

| Your situation | What to do |
|---|---|
| Just want to stop using the resource | Remove `ensure qbx_k9unit` from `server.cfg`. Leave the tables — they cost nothing sitting there. |
| Installing/migrating gave a duplicate-key error | See `sql/migrations/0004_add_k9_certifications_active_cert_key.sql`'s own header — it gives the exact query to find and resolve the conflicting rows before retrying. |
| Want to undo one specific migration | Run `sql/rollback/000N_down.sql` for that migration number. Every rollback file undoes exactly its matching migration and nothing else, and is safe to run more than once. Re-running the matching migration afterward restores what you undid — this round trip is tested to reproduce the original schema byte-for-byte, with two documented exceptions below. |
| Want the tables gone for good | See "Full uninstall" below. |
| Already broke something and want your data back | Restore your backup (see the command the backup script printed). |

**Two rollbacks lose real information, not just structure** — read their
own file headers before running either: `0003_down.sql` (drops
`k9_partnerships.tenure_bonus_tier_granted` — the column's *values* don't
come back on re-applying the migration, only the column does; restore
your backup if you need the real numbers) and `0004_down.sql` (removes
the unique constraint that stops two staff members certifying the same
officer at the same instant — don't leave a live server in this state).

**Full uninstall.** Re-read the table above first — you almost certainly
don't need this. If you do: back up, then run
`sql/rollback/uninstall_all.sql` **unmodified** first — it deletes
nothing, only reports anything else in your database that depends on
these tables. An empty report means removal is clean. To actually delete
everything: open the file, uncomment the line
`-- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';` near the
top, and run it again — it prints `UNINSTALLED` on success or
`REFUSED — NOTHING WAS DELETED` if you didn't uncomment the line, on
purpose, so pasting the wrong file can't wipe your data by accident.
Prefer the wrapper, `sql/rollback/uninstall.sh` — it backs up
automatically, asks you to type your database name back as confirmation,
and only then arms and runs the file above.

**Requirements**: same as install — MySQL 5.7.8+ or MariaDB 10.2+.
