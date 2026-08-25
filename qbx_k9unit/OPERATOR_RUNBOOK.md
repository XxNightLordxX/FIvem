# qbx_k9unit — Operator Runbook

This is a step-by-step guide for the person standing this resource up on a
real server — not a design document. For *why* something works the way it
does, or for the full list of every config flag, see `README.md`. For the
open decisions only a server owner can make, see
`DEVELOPER_REFERENCE.md` §17; this runbook turns several of those decisions
into concrete steps.

**Read this before anything else below: as of 2026-08-25, 39 of this
resource's 40 feature flags are switched on** (checked directly in
`config.lua`, not assumed). The one exception, `CameraFeedPiP`, has no
implementing code at all and was corrected back to `false` — nothing to do
about that one. Every "before you enable X" instruction in this document
below is now "X is already enabled — do this now, not before you flip a
switch that's already flipped." One flag in particular, `BoneSweepDevTool`,
is dangerous to leave on — see section 4 immediately if you haven't
already turned it back off. A second flag, `HighCommand` (and the
`Config.Departments[job].highCommandGrade`/`Config.HighCommand` settings
next to it in `config.lua`), is also switched on but has **no implementing
code anywhere in this resource yet** — `server/highcommand.lua` doesn't
exist and isn't loaded by `fxmanifest.lua`, so there is nothing to
configure or verify for it right now regardless of what `config.lua` says;
this will need its own runbook entry once it actually ships.

**This file needs no `fxmanifest.lua` entry.** Documentation files are never
loaded by the resource — do not add `OPERATOR_RUNBOOK.md` (or `README.md`)
to any `files{}`/`ui_page`/script list. If you see a future PR add one,
that's a mistake, not something this file is missing.

---

## 1. Install order

### 1a. Fresh install (no existing `qbx_k9unit` database)

**Minimum database engine: MySQL 5.7.8+ or MariaDB 10.2+.** `k9_certifications`'
`active_cert_key` column is a `GENERATED ALWAYS AS (...) VIRTUAL` column,
which older engine versions do not support at all — a real attempt against
MySQL 5.6 left the schema only half-built (every table before that one in
`install.sql` created successfully, then the migration stopped). Confirm
your database engine and version before running anything below; upgrading
the engine itself is outside what this resource's own SQL can do for you.

Run **`sql/install.sql`** once, against your database, before first start.
That single file creates all four tables this resource uses
(`k9_certifications`, `k9_search_log`, `k9_partnerships`, `k9_progression`)
in their final shape — including the constraints and indexes described
below. You do **not** need anything under `sql/migrations/` for a fresh
install; those files exist solely to bring an *older* database up to the
same final shape `install.sql` already produces in one pass.

### 1b. Upgrading an existing `qbx_k9unit` database

Run, **in this exact order**:

1. `sql/install.sql` — safe to re-run; every `CREATE TABLE` is
   `IF NOT EXISTS`, so this is a no-op for anything you already have and
   only fills in a table you're missing entirely.
2. `sql/migrations/0001_create_k9_partnerships.sql`
3. `sql/migrations/0002_create_k9_progression.sql`
4. `sql/migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql`
5. `sql/migrations/0004_add_k9_certifications_active_cert_key.sql`

Each migration file is individually idempotent (safe to run more than
once, and safe even if a later one has already been applied) — but **run
all four, in numeric order, every time you upgrade**, not just the ones
you think you need. `CREATE TABLE IF NOT EXISTS` in `install.sql` does
**not** retroactively add a column or index to a table that already exists
in some older shape. If your database created `k9_certifications` or
`k9_partnerships` before a later feature added a column/constraint to it,
`install.sql` alone will silently leave that column/constraint missing —
only the numbered migration for that specific change fixes an
already-existing table.

**A fresh install and a fully-migrated upgrade only converge once all four
migrations have actually run.** Migration `0004` is the one that matters
most and is the easiest to skip by accident: it backfills
`k9_certifications.active_cert_key` and the `uq_one_active_cert_per_job`
unique constraint onto a `k9_certifications` table that predates them.
Without it, `server/certifications.lua`'s grant path — a check, then an
insert, with no transaction between them — relies entirely on that unique
constraint throwing a duplicate-key error to catch two near-simultaneous
grant requests for the same handler/department. On a database missing
migration `0004`, that error never fires: two overlapping grant requests
can **both** succeed, leaving two simultaneously-active certifications for
the same citizenid/job with no error, no log line, and nothing that would
ever notice. A fresh install never has this gap (`install.sql` creates the
constraint from day one); only an upgraded database that skipped `0004`
does. Run it.

If migration `0004`'s `ADD UNIQUE KEY` step fails with a duplicate-entry
error, that means your database already accumulated more than one
simultaneously-active certification for the same citizenid/job before the
constraint existed — exactly the condition it exists to prevent going
forward. The migration file's own header gives you the query to find the
conflicting rows and the manual step to resolve them (deactivate all but
one, never delete the audit row) before re-running it.

### 1c. Resource install

1. Drop `qbx_k9unit` into your `resources` folder.
2. Confirm these five are installed and start **before** `qbx_k9unit` in
   `server.cfg` (they're declared in `fxmanifest.lua`'s `dependencies`
   block, so a missing one will refuse to start `qbx_k9unit` outright):
   `qbx_core`, `ox_lib`, `ox_target`, `oxmysql`, `ox_inventory`.
3. Add `ensure qbx_k9unit` after those five.
4. Open `config.lua` and set `Config.Departments`, `Config.Peds`, and
   `Config.K9Vehicles` for your server (see `README.md`'s own
   [Installation](README.md#installation) section for the full list).
5. **Create the item/object dependencies below.** Every one of these backs
   a feature that ships `true` by default, and every one is a bare
   placeholder name in `config.lua` — none of them exist in a fresh
   `ox_inventory`/world install on their own, and a missing one doesn't
   error, it just silently never works (`GetItemCount`-style checks return
   0 forever, which reads to a player as "this feature is broken," not
   "this feature is unconfigured"):
   - **`k9_medkit`** (`Config.K9Medkit.itemName`) — an `ox_inventory` item.
     Needed for `K9Medkit` (Treat K9).
   - **`k9_treat`** (`Config.Wellbeing.Mood.feedItemName`) — an
     `ox_inventory` item. Needed for `MoodSystem`'s "Feed K9" action (Pet
     K9 needs no item).
   - **`k9_meat_bait`** (`Config.Wellbeing.Distraction.meatBaitItemName`)
     and **`k9_ultrasonic_whistle`**
     (`Config.Wellbeing.Distraction.whistleItemName`) — both `ox_inventory`
     items. Needed for `DistractionSystem` (`/k9meatbait`, `/k9whistle`).
   - **A `water_bowl`-modeled world object** (`Config.Wellbeing.Fatigue.restSources`)
     — not an inventory item, an actual placed object/prop your server's
     map or a placement resource puts in the world. Needed for
     `FatigueSystem`'s rest-recovery bonus specifically (fatigue still
     regenerates slowly without one; a K9 just never gets the faster
     near-a-rest-source rate). `'water_bowl'` is itself an unverified guess
     at a real model name — confirm it against your own server's assets, or
     change `restSources` to a model you know exists.

   Add each item to your server's own `ox_inventory` items table (the exact
   step depends on your `ox_inventory` setup — see its own documentation)
   before enabling the corresponding feature in front of real players, not
   after.
6. Certify your first handler (`README.md`'s
   [How certification works, day one](README.md#how-certification-works-day-one)).

Only after all of the above is in place should you start working through
section 5 (recommended first tranche) below.

---

## 2. Dev-server checks — now overdue, since these flags are already on

**Originally written as "do this before flipping the flag." All of these
flags are already `true`.** Do these on a real dev server as soon as you
can — they're no longer optional pre-checks gating a decision, they're
verification steps for something already live. None of them are hard
blockers (each feature degrades safely if you skip the check), but each
closes a real, disclosed unknown, and skipping it for longer just means
running longer on an unverified assumption.

### 2a. `ScentTracking` — confirm the `ox_inventory` hook payload

`ScentTracking` depends on `exports.ox_inventory:registerHook('swapItems',
...)`. The hook name and payload shape were confirmed by reading
`ox_inventory`'s source directly, but never verified against a live
install you actually run. The hook already fails safe: it only registers
if a runtime check confirms `registerHook` exists on your build of
`ox_inventory`, and disables scent tracking cleanly with one clear warning
if it doesn't.

**What to actually do:** `Config.Features.ScentTracking` is already `true`
(confirm that's still the case in your own `config.lua`), so on a dev
server just restart, drop an item as a certified K9 handler, and read the
logged hook payload once. Confirm the field names it prints match what
`server/tracking.lua` expects before trusting this in production. This is
a five-minute check, not a code change.

### 2b. `PropAttachments` / `FetchMechanic` — run the bone-index sweep

Both features ship fully playable today, but at the wrong attach point:
the vest sits at bone index `0` (the root bone — always valid, never
crashes, but visibly wrong), and `FetchMechanic` ships in
`mouthCarryMode = 'fake'` (delete-and-reappear) instead of a real
mouth-carry. Neither is broken or unsafe as shipped — this step is about
polish, not safety, so it's fine to skip it and enable both features as-is
if you don't mind the placeholder look.

**`Config.Features.BoneSweepDevTool` is currently `true` everywhere,
including on any live server this config file has reached — not just on a
dev server.** Read section 4 below before doing anything else in this
subsection; the short version is that this flag must never stay `true`
outside a private dev session, and if it's `true` on a real server right
now, turning it back off is more urgent than finishing the sweep itself.

If you want to fix it, on a **dev server only**:

1. Confirm `Config.Features.BoneSweepDevTool = true` on that dev server
   (it already is, resource-wide, as of this document's last check —
   confirm your dev server's own copy of `config.lua` still has it set)
   and restart.
2. **Corrected 2026-08-25 — this is no longer an ACE permission.** The tool
   dropped ACE entirely and now needs two things at once, neither of which
   is an ACE grant:
   - Add `setr qbx_k9unit_enable_bone_dev_tool 1` to your **dev server's**
     `server.cfg` (never a live one) and restart. Without this convar set,
     the command does not exist at all, regardless of the flag or anyone's
     rank.
   - Be a **boss** (`job.isboss == true`) of a job listed in
     `Config.Departments` — a numeric grade is not enough for this specific
     tool, unlike the audit commands.
   There is no ACE permission to grant anywhere in this resource any more —
   not for this tool, and not for the admin/audit commands (`/k9auditcert`
   and friends), which check police job rank instead. If you have an old
   `add_ace ... k9unit.bonesweep allow` line in your `server.cfg` from a
   previous version of this resource, it does nothing now and can be
   removed.
3. Connect and play as a K9-modeled ped.
4. Run `/k9bonetool help` for the full workflow, then `/k9bonetool known`
   for a candidate shortlist, `/k9bonetool goto <index>` /
   `next`/`prev` to sweep and preview, and `/k9bonetool test` to confirm
   with a real attached object. `/k9bonetool stop` cleans up when you're
   done.
5. Record the index you found in `config.lua`:
   `Config.PropAttachments.boneIndex` for the vest, or
   `Config.FetchMechanic.mouthBoneIndex` **and** flip
   `Config.FetchMechanic.mouthCarryMode` from `'fake'` to `'attach'` for
   fetch.
6. **Turn `Config.Features.BoneSweepDevTool` back to `false` and restart
   the resource** before this server goes anywhere near production — see
   the one-way-door note in section 4.

### 2c. `DeployableKennel` — eyeball the kennel prop model

`Config.DeployableKennel.propModel` is `'prop_dog_cage_01'` (hash
`379820688`). This replaced an earlier value, `'prop_doghouse_01'`, which
was refuted this pass: it traced to a single unverified third-party
resource's config and does not appear in a 5,171-entry live object
database that has a rendered screenshot for every real entry (its
screenshot URL 404s). `prop_dog_cage_01` **does** appear in that database
with a real screenshot — checkable evidence, not an in-engine
confirmation. Before enabling `DeployableKennel` on a live server, run
`/k9deploykennel` once on a dev server and confirm it actually spawns and
looks reasonable. If it ever fails to load, `Config.DeployableKennel.fallbackPropModel`
(`'prop_tennis_ball'`) takes over automatically — you'll get an obviously-wrong
but real object rather than a silent failure or a broken entity.

---

## 3. The sequenced origin-guard check — run this now, combat is already on

**`BiteAndHold`, `NonLethalTakedown`, and `PropDragging` are already
`true`.** This section used to be framed as a check to run "before
enabling any combat feature." That framing is stale: the decision to
enable them has already been made. What's below is now the check you run
to find out whether that decision is currently safe, not a gate on making
it.

**Background, briefly:** every client-side event handler in this resource
checks `if source ~= 65535 then return end` at the top, to reject a locally
forged event and require a genuine server-originated one. This closed a
real exploit (a player could otherwise loop a local call for indefinite
invincibility, with every feature flag off). The check is applied
resource-wide and is strictly better than nothing — but it has never been
independently confirmed in-engine, and a later review found a specific way
it could plausibly fail **open**: if FiveM's client runtime sets `source`
as an ordinary global that's populated on a genuine network receive and
then simply **never cleared**, any client that has *ever* received one real
server event (which is every client, within seconds of connecting) could be
carrying a stale `source == 65535` that a later, locally-forged call would
inherit and pass through.

**This means the naive test is worthless.** Firing a local `TriggerEvent`
on a client that has never received anything from the server will read
"clean" either way and tell you nothing about which behavior is real.

**The check you actually need to run, on one client, in this exact order:**

1. Connect a test client to your dev server.
2. Let that client **receive at least one genuine server-originated event**
   first. The easiest one is already live by default: trigger a bark
   (`BasicBarkSounds` ships `true`) and let that client receive the
   server's relayed bark event.
3. From **that same client, without reconnecting**, fire a local
   `TriggerEvent(...)` call against one of the guarded event names (a
   temporary debug print of `source, type(source)` at the top of the
   handler you're testing makes this easy to read).
4. Compare: did `source` read `65535` on the genuine event in step 2, and
   does it **still** read `65535` on the locally-forged call in step 3? If
   it does, the guard is not doing its job — a stale value is passing the
   check.

Running steps 2 and 3 out of order (or skipping step 2 and only testing a
fresh client) tells you nothing. This is the whole point of the sequencing
— do not shortcut it.

**Your call**: treat the guard as sufficient as shipped (it's applied
everywhere, and the per-feature flag gating closes the original
"flags-off" exploit independently of whether this specific guard holds),
or run this exact sequenced test on a dev server before trusting
`BiteAndHold`, `NonLethalTakedown`, or `PropDragging` in production — all
three are already enabled by default; this test is what tells you whether
that's currently safe, not a precondition for turning them on. The more of that
Category B combat surface you turn on, the more this result matters —
Category B effects (movement restriction, forced ragdoll, damage
suppression) only work at all if the target's own client executes them,
and this guard is the only thing standing between "a modified client
ignores the effect" (expected, disclosed) and "a modified client can grant
itself the effect on demand" (a live exploit, if the guard doesn't hold).
See `DEVELOPER_REFERENCE.md`'s D3 (§17) and §15 `#trust-boundary` for the
full reasoning behind this guard.

---

## 4. One-way doors — know before you flip these

### `BoneSweepDevTool` — currently `true`. This is the most urgent item in this whole document.

**As of 2026-08-25, `Config.Features.BoneSweepDevTool` is `true`.** Its own
code comment says, in these words, "never enable this on a production
server." It spawns and attaches real objects in the world on command from
any department boss — **and, as of this same date, it also requires a
separate server-startup switch, `setr qbx_k9unit_enable_bone_dev_tool 1`,
to be reachable at all** (this is new; if that convar was never set in
your `server.cfg`, the command doesn't exist regardless of the flag). If
this server has real players on it, check both of these now, not at the
end of your reading list.

**What to do, in order:**
1. Open `config.lua`, set `Config.Features.BoneSweepDevTool = false`.
2. Confirm `qbx_k9unit_enable_bone_dev_tool` is not set to `1` anywhere in
   this server's own `server.cfg` (or any included config file) — remove
   or comment out the line if it is.
3. **Restart the resource.** This is not optional and not implied by
   saving the file.

**Why the restart matters, specifically:** like every other command in
this resource, `/k9bonetool` is registered **once**, at resource start —
gating happens at registration time, not inside the handler, which is what
makes a disabled feature genuinely inert rather than merely hidden. The
consequence: turning `Config.Features.BoneSweepDevTool`
back to `false` **without restarting the resource** does not unregister
`/k9bonetool`. It stays reachable (to any department boss, and only if the
convar above is also set) until the next restart. For most flags in this
resource that's harmless. For this one it isn't — it spawns and attaches
real objects on command. If you ever turn this on for the dev-server check
in section 2b, **restart the resource after turning it back off**, and
never leave the flag `true` or the convar set to `1` on a server real
players connect to.

### Bark/ambient audio — already shipped, nothing for you to do

**Corrected 2026-08-25 — this section used to tell you to source your own
audio. That's no longer true.** All five sound files this resource can
play now ship with it: the plain bark, all three `AdvancedBarkRadial`
variants (Alert/Aggressive/Calm), and `ProximityAudioFX`'s ambient growl.
They're already at their correct paths under `html/sounds/`, already
listed in `fxmanifest.lua`'s `files{}` block, and confirmed wired up to
actually reach a connected client — you do not need to find, license, or
convert anything to hear them.

Every one of these files carries a real attribution obligation (none is
public domain) — that obligation has already been satisfied on your
behalf. `html/sounds/CREDITS.md` has the full source URL, author, license,
and exact required credit text for each file. Read it if:

- You distribute this resource yourself and need to know what attribution
  obligation travels with it, or
- You want to **replace** any of these five files with your own audio —
  in which case follow `html/sounds/CREDITS.md`'s own pre-drop checklist
  (confirm the replacement's license, confirm it's genuinely Ogg Vorbis,
  record its own source/license entry in that file) rather than dropping
  a file in with no record of where it came from.

No action is required otherwise. If a bark or the ambient growl is ever
silent on your server, that's a bug to report, not an asset you're missing.

---

## 5. What used to be "recommended first tranche" — now a catch-up checklist

**This section originally recommended enabling flags gradually, starting
with the lowest-risk group and leaving combat for last, if at all.** That
recommendation has been overtaken: 39 of 40 flags, including combat, are
already `true` (see the top of this document; the one exception,
`CameraFeedPiP`, has no code behind it and isn't relevant here). The advice
below is kept,
rewritten as a checklist of what to verify now that everything is live at
once, rather than a rollout plan — the original reasoning for *why* each
item matters is unchanged, only the tense.

**Tracking/search group** (`ScentTracking`, `BloodTracking`,
`GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`) — still the
lowest-risk group in the whole resource (nothing here restrains, damages,
or moves another player's character, and it's the most reviewed part of
this resource). Two things worth doing now that it's live:

- Run the section 2a dev check for `ScentTracking` — it has an extra
  prerequisite (a live `ox_inventory` hook) the others don't, and that
  check has never been run against a real install.
- Replace `Config.SearchContrabandItems`' placeholder item names
  (`'weed_bud'`, `'coke_brick'`, etc.) with your own economy's real
  `ox_inventory` item names if you haven't already — with `SearchZones`
  live, a search against those placeholder names simply won't find
  anything real on your server.

**Combat group** (`BiteAndHold`, `NonLethalTakedown`, `PropDragging`) —
was the highest-risk group, recommended last "if at all." It's on. That
doesn't mean the risk went away: a modified client can still ignore the
restraining half of these mechanics regardless of config, and the two
open questions in `DEVELOPER_REFERENCE.md` §17 (D3, D13) are exactly about
how much that should worry you. Run section 3's sequenced check now, and
read those D3/D13 write-ups if you haven't. Everything else in this
resource (tracking, search, vision, inventory, wellbeing, progression,
kennel, fetch, prop attachments, the admin/audit surface) carries no
equivalent trust-boundary caveat and can be evaluated purely on whether you
want the feature, not on whether it's safe to expose.

---

## 6. Installing/upgrading with `k9_setup.sh` — the single entry point

If you only remember one command for getting the database in shape, this
is it:

```bash
cd qbx_k9unit/sql
./k9_setup.sh -d your_database_name -u your_mysql_user           # do it
./k9_setup.sh -d your_database_name -u your_mysql_user --dry-run  # just show the plan
```

(If it is not executable yet: `bash k9_setup.sh -d your_database_name -u
your_mysql_user`.) It is safe to run on a brand-new database, and just as
safe to run again on a server you already installed this on months ago —
every piece it calls is individually safe to run more than once. Nothing
in `sql/` ever runs on its own; you always choose to run something.

Every time you run it (without `--dry-run`), in this exact order:

1. **Checks** — right server version, no table-name conflicts, a sanity
   check that this looks like a real qbx_core database
   (`sql/preflight_check.sql`'s content). Stops here, untouched, if anything
   comes back with `!!`.
2. **Backs up your ENTIRE database, automatically, unconditionally** — not
   just this resource's own tables, every table in the database
   (`sql/rollback/backup_full_database.sh`). **This cannot be skipped, and
   if it fails for any reason, nothing below it ever runs.**
3. **Installs/upgrades** — `sql/install.sql`, then every file in
   `sql/migrations/` in filename order. Every one of those files is
   individually safe to run twice.
4. **Reports** — every table found afterward, with its row count, and one
   final line: `SUCCESS` or `FAILED`. Never a silent finish.

`--dry-run` skips steps 2–3 and instead prints a read-only report of
exactly what installing/upgrading right now would do — no backup is taken,
because nothing is being written.

**The two kinds of backup — do not confuse them:**

| | `sql/rollback/backup_k9_tables.sh` | `sql/rollback/backup_full_database.sh` |
|---|---|---|
| Backs up | This resource's own tables only | **Every** table in the database |
| Use before | Uninstalling / rolling back *this resource* | Installing or migrating (any schema change) |
| Called automatically by | `sql/rollback/uninstall.sh` | `k9_setup.sh` |
| File name starts with | `qbx_k9unit-backup-` | `qbx_k9unit-FULLDB-backup-` |

**Honest limits.** This tooling makes a specific set of mistakes
structurally impossible (running the uninstall by accident — it's inert
until hand-armed and re-disarms itself every run; a schema change
proceeding after its own backup silently failed; a "dry run" that
secretly writes; a backup silently overwriting an earlier one), catches and
refuses a second set with a specific reason instead of a bare SQL error
(running a migration before its own dependency; installing on too old an
engine or over a name conflict; a backup with too little free disk;
mistaking a truncated backup for a complete one), and warns-but-doesn't-block
on a third set that's a genuine judgment call (an unrecognized `k9_*` table
that might belong to a different K9 resource sharing your database, or
might mean this tooling's own table list is out of date — it can't tell
which, so it warns loudly rather than guessing). What it cannot protect
against, because no tool can: running the *armed* uninstall against the
wrong database, restoring the wrong backup file, or a privileged user
running raw SQL directly outside any of these scripts.

---

## 7. Uninstalling / rolling back the database

**Installing or upgrading?** See section 6 above, not this one — everything
here is about undoing something. Everything below is written to be run by
hand, one file at a time, in phpMyAdmin, HeidiSQL, or the `mysql` CLI.
Nothing here runs automatically, and the resource itself never runs any of
it.

**One rule above all others: do STEP 1 first.** Every other step assumes
you already have a backup.

### STEP 0 — Before you install anything: run the safety check

Read-only, safe on a live server:

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < sql/preflight_check.sql
```

Every line should start with `OK`. A line starting with `!!` means stop and
fix that first — most commonly, a different resource already owns one of
this resource's table names (a name conflict, not data damage either way).

### STEP 1 — Back up first. Always. Every time.

```bash
cd qbx_k9unit/sql/rollback
./backup_k9_tables.sh -d YOUR_DATABASE_NAME -u YOUR_MYSQL_USER
```

Saves every one of this resource's own tables into one timestamped file; it
only reads, changes nothing. This backs up this resource's tables only —
for a safety net before an *install or migration* (protecting your whole
database), use `./backup_full_database.sh` instead, or just use
`k9_setup.sh` (section 6), which runs that automatically. The two backup
files are named differently on purpose (`qbx_k9unit-backup-...` vs.
`qbx_k9unit-FULLDB-backup-...`) so you can't mix them up under pressure.

A successful run prints a `BACKUP OK` block with the file path, size, and
row counts, and the exact one-line command to restore it — copy that line
somewhere safe. **If you do NOT see `BACKUP OK`, stop** and fix whatever
failed before running anything else in this section. `k9_search_log`
specifically is your only accountability trail of every contraband search
anyone ever performed — it cannot be rebuilt from anything else.

### STEP 2 — Work out what you actually want

| Your situation | What you need | Deletes data? |
|---|---|---|
| "Installing gave me a **duplicate entry** error and I'm stuck" | STEP 5 | No |
| "I want to undo the most recent schema change" | STEP 3 | No |
| "I want to undo the tenure-bonus column too" | STEP 4 | Loses one column's values — read it first |
| "I just want to stop using the resource" | Do nothing here — remove `ensure qbx_k9unit` from `server.cfg`. Tables sit there harmlessly. | No |
| "I want the tables gone from my database for good" | STEP 7 | **Yes — everything** |
| "I already broke something and want my data back" | STEP 8 | No (it restores) |

### STEP 3 — Undo the newest change (migration 0004)

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < sql/rollback/0004_down.sql
```

Removes the `active_cert_key` column and three indexes from
`k9_certifications`. Deletes zero rows — that column is calculated, not
stored. Safe to run twice. **Do not leave a live server in this state**:
the `uq_one_active_cert_per_job` index it removes is what stops two staff
members certifying the same officer at the same instant from both
succeeding (tested: without it, 20 simultaneous requests produced 20 active
certifications for one person, no error anywhere). Use this step to get
unstuck, then STEP 6 to put it back.

### STEP 4 — Also undo the tenure column (migration 0003)

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < sql/rollback/0003_down.sql
```

Removes `tenure_bonus_tier_granted` from `k9_partnerships`. **This is the
one file here that loses information** — no rows are deleted, but that
column is the only record of which tenure bonuses have already been paid
out; removing and restoring it resets every value to zero, which the
resource reads as "never paid," so every long-running partnership gets its
1-day/7-day/30-day bonuses paid all over again. Your STEP 1 backup is the
only way back to the real values.

### STEP 5 — "It said *Duplicate entry … for key uq_one_active_cert_per_job*"

The most common reason to end up here. Your database already has the same
officer certified twice for the same job at the same time — migration 0004
exists to make that impossible going forward, but can't switch the rule on
while the database already breaks it. Nothing is broken and nothing is
lost:

1. Roll back the half-applied migration: `mysql ... < sql/rollback/0004_down.sql`
2. Find the duplicates: `SELECT citizenid, job, COUNT(*) AS dupes FROM k9_certifications WHERE active = 1 GROUP BY citizenid, job HAVING COUNT(*) > 1;`
3. Fix them (keeps the newest, marks older extras revoked — **deletes
   nothing**, the old rows stay as history):
   ```sql
   UPDATE k9_certifications c
   JOIN (SELECT citizenid, job, MAX(id) AS keep_id FROM k9_certifications WHERE active = 1 GROUP BY citizenid, job) k
     ON c.citizenid = k.citizenid AND c.job = k.job
   SET c.active = 0, c.revoked_by = 'MIGRATION-DEDUPE', c.revoked_at = NOW()
   WHERE c.active = 1 AND c.id <> k.keep_id;
   ```
4. Re-run step 2's query — it should return no rows.
5. Retry the migration: `mysql ... < sql/migrations/0004_add_k9_certifications_active_cert_key.sql`

### STEP 6 — Put a rollback back (go forward again)

Rollbacks are not one-way. Re-run the matching migration from
`sql/migrations/`, in number order, to restore what you undid. This
round trip is tested: install → roll back → re-apply produces a schema
byte-for-byte identical to where you started, with every row untouched
(except STEP 4's caveat: the column's *values* come back as zero, not
their originals — restore your backup if you need those).

### STEP 7 — Delete everything (full uninstall)

**Re-read STEP 2 first — you almost certainly do not need this.** To simply
stop using the resource, remove `ensure qbx_k9unit` from `server.cfg` and
leave the tables alone; they cost you nothing.

Before deleting anything, run `sql/rollback/uninstall_all.sql`
**unmodified** — it deletes nothing but prints a report of anything else in
your database that depends on these tables (a foreign key, a view, a
trigger, a stored routine, or an unrecognized `k9_*` table this file
doesn't know about). An empty report means removal is clean; otherwise fix
what it lists and re-run.

If you genuinely want the tables gone: (1) do STEP 1, (2) open
`uninstall_all.sql`, (3) find the commented-out
`-- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';` line near the
top and uncomment it, (4) run the file. It prints `UNINSTALLED` on success
or `REFUSED — NOTHING WAS DELETED` if you didn't uncomment the line — run
unmodified, it does nothing at all, on purpose, so you cannot wipe your K9
data by pasting the wrong file. It also refuses outright (deleting nothing)
if anything else in your database still depends on these tables, rather
than leaving you half-uninstalled.

**Prefer the wrapper**, `sql/rollback/uninstall.sh` — it does STEP 1 for you
automatically (a full-database backup), requires you to type your database
name back as confirmation, and only then arms and runs the file above.

### STEP 8 — Restore from your backup

```bash
mysql -h 127.0.0.1 -P 3306 -u YOUR_USER -p YOUR_DATABASE < qbx_k9unit-backup-....sql
```

Use the exact line the backup script printed in STEP 1. Puts every table
back exactly as it was at backup time; anything written after the backup
is not in it. Tested end to end: dropping every table and restoring from a
backup returns every row, and every calculated column, exactly as it was.

### What each rollback file undoes

| File | Undoes | Deletes rows? |
|---|---|---|
| `backup_k9_tables.sh` / `backup_full_database.sh` | *(nothing — they save)* | No, read-only |
| `0001_down.sql`, `0002_down.sql`, `0005_down.sql`, `0007_down.sql`, `0008_down.sql`, `0010_down.sql` | their matching migration | **No — does nothing on purpose** (each undoes "create a table"; only `uninstall_all.sql` ever drops one) |
| `0003_down.sql` | migration 0003 | No rows, but loses one column's values (see STEP 4) |
| `0004_down.sql`, `0009_down.sql` | migration 0004 / 0009 | No |
| `0006_down.sql` | migration 0006 | No rows |
| `uninstall.sh` | *(wrapper)* | Backs up first, then calls `uninstall_all.sql` |
| `uninstall_all.sql` | the whole install | **Yes, every table** — inert until armed |

### Requirements

Same as install: **MySQL 5.7.8+ or MariaDB 10.2+.** Tested on MariaDB
10.11, MySQL 5.7, and MySQL 8.0.
