# qbx_k9unit database tooling — start here

If you only remember one command, remember this one:

```bash
cd qbx_k9unit/sql
./k9_setup.sh -d your_database_name -u your_mysql_user
```
(If it is not executable yet: `bash k9_setup.sh -d your_database_name -u your_mysql_user`.)

That one command checks your database, backs up your **entire** database
automatically, then installs or upgrades qbx_k9unit's own tables, and tells
you plainly whether it worked. It is safe to run on a brand-new database, and
just as safe to run again on a server you already installed this on months
ago — every piece it calls is individually safe to run more than once.

Everything below explains what that command does under the hood, and what to
reach for instead if you want more control or need to undo something.

---

## What's in this folder

| File | What it's for | Runs automatically? |
|---|---|---|
| `k9_setup.sh` | **The single entry point.** Check → back up (whole database) → install/upgrade → report. | No — you run it |
| `install.sql` | Creates every qbx_k9unit table in final shape. Safe to run on a database that already has some/all of them (no-op for what exists). | No |
| `migrations/000N_*.sql` | Applies one schema change to an *existing* database that predates it. Each is independently safe to re-run. | No |
| `migration_status.sql` | Read-only "what would running install.sql + every migration do right now" report. `k9_setup.sh --dry-run` runs this for you. | No |
| `preflight_check.sql` | Read-only safety check: right server version? table-name conflicts? `CREATE ROUTINE` available? does this look like a real qbx_core database? `k9_setup.sh` runs this for you automatically. | No |
| `maintenance_prune_k9_search_log.sql` | Optional, manual retention statement for the one table that grows without bound. You decide if/when to use it. | No |
| `rollback/` | Undoing things — backups, per-migration rollbacks, and the full uninstall. See `rollback/README.md`. | No |

**Nothing in this folder ever runs on its own.** The resource itself never
executes any file here; you always choose to run something.

---

## The single entry point: `k9_setup.sh`

```bash
./k9_setup.sh -d your_database_name -u your_mysql_user           # do it
./k9_setup.sh -d your_database_name -u your_mysql_user --dry-run  # just show the plan
```

Every time you run it (without `--dry-run`), in this exact order:

1. **Checks** — the same content as `preflight_check.sql`: right server
   version, no table-name conflicts, a sanity check that this looks like a
   real qbx_core database. Stops here, untouched, if anything comes back
   with `!!`.
2. **Backs up your ENTIRE database, automatically, unconditionally.** Not
   just qbx_k9unit's own tables — every table in the database, via
   `rollback/backup_full_database.sh`. **This cannot be skipped, and if it
   fails for any reason, nothing below it ever runs.** A backup you believe
   you took but didn't is worse than no backup at all, so a failed backup is
   always treated as fatal to the whole operation, not a warning to click
   past.
3. **Installs/upgrades** — runs `install.sql`, then every file in
   `migrations/` in filename order. Every one of those files is individually
   safe to run twice, so this step is exactly as safe on your first install
   as your fiftieth upgrade.
4. **Reports** — every qbx_k9unit table found afterward, with its row count,
   and one final line: `SUCCESS` or `FAILED`. Never a silent finish.

If step 3 fails partway through (say, migration 0004 hits a pre-existing
duplicate-certification row), the script stops immediately, tells you in
plain English what the error means and what to do about it, reminds you
exactly where the Step 2 backup is, and confirms that everything which
already printed `OK:` is unaffected — you do not need to restore anything
just because a later step failed, and re-running the whole script is safe.

`--dry-run` skips steps 2-3 entirely and instead prints `migration_status.sql`
— a read-only report of exactly what installing/upgrading right now would do
(which tables would be created, which columns/indexes would be added, and —
for the one migration that can legitimately fail on dirty data — whether it
would fail and why). No backup is taken for a dry run, because nothing is
being written; there is nothing yet to protect.

### The two kinds of backup — do not confuse them

| | `rollback/backup_k9_tables.sh` | `rollback/backup_full_database.sh` |
|---|---|---|
| Backs up | qbx_k9unit's own ~11 tables only | **Every** table in the database |
| Use before | uninstalling / rolling back *this resource* | installing or migrating (any schema change) |
| Called automatically by | `rollback/uninstall.sh` | `k9_setup.sh` |
| File name starts with | `qbx_k9unit-backup-` | `qbx_k9unit-FULLDB-backup-` |

The full-database one is bigger and slower because it is protecting more —
see its own header comment (`rollback/backup_full_database.sh`) for the
disclosed tradeoffs on size, locking, and permissions before you rely on it
on a very large database.

---

## Honest limits — what this tooling can and cannot protect you from

Nothing here claims to be perfectly foolproof, and a specific list of real
remaining hazards is worth more than a claim of total safety that fails once.

**Now impossible (structurally, not just by convention):**
- Losing data by pasting `uninstall_all.sql` into the wrong window and
  running it — it is inert until hand-armed, and resets its own arming flag
  to "off" every single time it runs.
- A schema change proceeding after its own backup silently failed —
  `k9_setup.sh` and `rollback/uninstall.sh` both hard-stop on any non-zero
  exit from the backup step, before running a single write statement.
- A "dry run" that isn't actually one — `migration_status.sql` never writes
  (verified by construction: every statement in it is a `SELECT`, `SET`,
  `PREPARE`/`EXECUTE` of a `SELECT`, or `DEALLOCATE PREPARE`; there is no
  `CREATE`, `ALTER`, `INSERT`, `UPDATE`, or `DELETE` anywhere in that file).
- A backup silently overwriting an earlier one taken moments before —
  both backup scripts refuse to reuse a filename that already exists.
- The uninstall dropping only *some* of our tables and leaving the rest,
  because something else's foreign key blocked one mid-run — it now checks
  for that dependency first and refuses the whole operation rather than
  drop what it can.

**Caught and refused, with a specific reason, rather than failing raw:**
- Running a migration before the install it depends on (e.g. 0003/0004/
  0006/0009 before `install.sql`) — each now checks its own table exists
  first and stops with one plain sentence instead of a bare
  `ERROR 1146 (42S02)`.
- Installing on a database too old to run this schema, or where one of our
  table names is already taken by something else — `preflight_check.sql`
  (and `k9_setup.sh`, which runs it for you) catch both before any write.
- Running the mandatory backup with too little free disk space —
  `backup_full_database.sh` estimates the database size up front and
  refuses rather than risk filling the disk mid-dump.
- A truncated/interrupted backup being mistaken for a real one — verified
  against mysqldump's own completion marker and a per-table structural
  count before anything is allowed to rely on it; an incomplete file is
  renamed with a `.INCOMPLETE` suffix so it cannot be picked up by mistake.

**Warned, but not blocked (a judgment call is genuinely yours to make):**
- Installing into a database with no `players` table, or no tables at all —
  flagged by `preflight_check.sql`'s CHECK 5 as worth a second look, because
  a brand-new pre-qbx_core database is a real, legitimate situation and not
  automatically a mistake.
- Tight disk space (enough to proceed, but not much margin) before a full
  backup.
- Any non-InnoDB (e.g. MyISAM) table in your database — `--single-transaction`
  cannot guarantee a perfectly consistent snapshot of those specific tables
  if something writes to them mid-dump; `backup_full_database.sh` lists any
  it finds so you know whether this applies to you.

**Still genuinely dangerous — no tool can close these:**
- Running the *armed* `uninstall_all.sql` (or confirming `rollback/uninstall.sh`
  with `--confirm`) against the wrong database. Typing the right database
  name twice does not help if the name itself is wrong. Always check the
  hostname/database in your prompt before confirming anything destructive.
- Restoring the wrong backup file, or restoring a k9-only backup when you
  meant the full-database one (or vice versa) — the differently-prefixed
  filenames make this harder, not impossible.
- A privileged user running raw SQL outside of any of these scripts.
  Nothing here can protect a database from a `DROP TABLE` typed directly
  into a client with no safety rails around it — that is true of every
  database tool that has ever existed, not a gap specific to this resource.
- Anything that requires stopping the FiveM server for true consistency
  that this tooling deliberately avoids requiring (see `--single-transaction`
  above) — if you need an absolutely bit-for-bit consistent copy of a
  non-InnoDB table under write load, no online backup tool can promise that
  without a brief pause on writes to that specific table.

If you find a way past any of the first two categories above, that is a bug
in this tooling — report it. The last two categories are not bugs; they are
the honest edge of what automation can do for an operator who can already
run arbitrary SQL against the database.

---

For undoing something you've already installed, see `rollback/README.md`.
