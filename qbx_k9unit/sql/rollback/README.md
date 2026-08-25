# Undoing the qbx_k9unit database install

**This folder is your safety net.** If running `sql/install.sql` broke
something, or you want to remove this resource's database tables, this is
where you undo it.

Everything here is written to be run by hand, one file at a time, in
phpMyAdmin, HeidiSQL, or the `mysql` command line — whatever you already
use to run `install.sql`. Nothing here runs automatically, and the
resource itself never runs any of it.

**One rule above all others: do STEP 1 first.** Every other step assumes
you already have a backup.

---

## Words you will see, in plain English

| Word | What it actually means |
|---|---|
| **table** | One spreadsheet-like store of rows. This resource uses five of them. |
| **column** | One field on every row — like one spreadsheet column. |
| **index** | A lookup shortcut the database keeps so searches are fast. It holds no data of its own; deleting one never deletes rows. |
| **migration** | A numbered file that changes the shape of a table. `sql/migrations/0001…0005`. |
| **rollback** / **down script** | A file in this folder that undoes one migration. |
| **schema** | The *shape* of your tables — the columns and indexes. Separate from the *data* (the rows). |
| **drop** | Delete permanently. Dropping a table deletes every row in it, forever. |

---

## STEP 0 — Before you install anything: run the safety check

If you have not installed this resource yet, or you are about to upgrade,
run this first. It is **read-only** — it changes nothing and is safe on a
live server:

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < ../preflight_check.sql
```

It answers three questions in a few seconds: is your database server new
enough, does anything already own one of our five table names, and does
your database user have the privileges the migration files need.

**You want every line to start with `OK`.** A line starting with `!!` means
stop and fix that first. The most important one it catches:

```
k9_certifications  !! CONFLICT - a DIFFERENT table already uses this name
                      (matched only 0 of 7 expected columns).
                      Do NOT install until this is resolved.
```

That means some other resource already has a table with the same name.
Installing will not damage it — but this resource will not be able to use
it either, and you will get confusing `Unknown column` errors later. See
"Will this affect my existing database?" in `OPERATOR_RUNBOOK.md`.

---

## STEP 1 — Back up first. Always. Every time.

Run this before touching anything else:

```bash
cd qbx_k9unit/sql/rollback
./backup_k9_tables.sh -d YOUR_DATABASE_NAME -u YOUR_MYSQL_USER
```

Replace `YOUR_DATABASE_NAME` with the database you ran `install.sql`
against, and `YOUR_MYSQL_USER` with your MySQL username (often `root`).
It will ask for your password — typing nothing and pressing Enter is fine
if your database has no password.

**What it does:** saves a copy of all five qbx_k9unit tables into one
timestamped file. It only reads; it changes nothing.

**How to tell it worked:** you will see a block like this, and the last
line of the command will not be an error:

```
======================================================================
 BACKUP OK
======================================================================
 File: ./qbx_k9unit-backup-mydb-20260825-114547.sql
 Size: 8.0K

 Rows saved:
   k9_certifications    3
   k9_search_log        3
   k9_partnerships      2
   k9_progression       2
   k9_permissions       1

 TO PUT IT ALL BACK, run exactly this one line:

   mysql -h 127.0.0.1 -P 3306 -u root -p mydb < ./qbx_k9unit-backup-mydb-20260825-114547.sql
```

**Copy that "put it all back" line somewhere safe.** It is your undo
button for everything below.

**If you do NOT see `BACKUP OK`, stop.** Something went wrong and you do
not have a backup. Do not run any other file in this folder until the
backup succeeds. The script tells you what failed; fix that first.

> **Why this matters most for `k9_search_log`:** that table is the record
> of every contraband search anyone ever performed — who searched, what,
> when, and what was found. It is your accountability trail. It cannot be
> rebuilt from anything else. If it is gone, it is gone.

Options if you need them: `-h HOST`, `-P PORT`, `-S /path/to/socket`,
`-o DIRECTORY` (where to save the file). Run the script with no arguments
to see the full list.

---

## STEP 2 — Work out what you actually want

Most people who come here do **not** need to delete anything. Find your
situation:

| Your situation | What you need | Deletes data? |
|---|---|---|
| "Installing gave me a **duplicate entry** error and I'm stuck" | **STEP 5** | No |
| "I want to undo the most recent schema change" | **STEP 3** | No |
| "I want to undo the tenure-bonus column too" | **STEP 4** | Loses one column's values — read it first |
| "I just want to stop using the resource" | **Do nothing here.** Remove `ensure qbx_k9unit` from `server.cfg`. Your tables sit there harmlessly. | No |
| "I want the tables gone from my database for good" | **STEP 7** | **Yes — everything** |
| "I already broke something and want my data back" | **STEP 8** | No (it restores) |

---

## STEP 3 — Undo the newest change (migration 0004)

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < 0004_down.sql
```

**What it does:** removes the `active_cert_key` column and three indexes
from `k9_certifications`.

**What it does NOT do:** delete any rows. Not one. That column is
*calculated* — the database works it out on the fly from columns that are
already there, so it stores nothing and removing it loses nothing. The
three indexes are just lookup shortcuts.

**How to tell it worked:** the command finishes with no error. To check
directly:

```sql
SHOW INDEX FROM k9_certifications;
```
You should no longer see `uq_one_active_cert_per_job`, `idx_job_active`,
or `idx_citizen_job_active`. Your row count is unchanged:
```sql
SELECT COUNT(*) FROM k9_certifications;
```

**Safe to run twice.** Running it again does nothing and reports no error.

> ⚠️ **Do not leave your live server in this state.** That
> `uq_one_active_cert_per_job` index is what stops two staff members
> certifying the same officer at the same instant from both succeeding.
> Tested on a real server: with it, 20 simultaneous requests produced
> exactly 1 certification and 19 clean rejections. Without it, all 20
> succeeded — 20 active certifications for one person, with no error
> anywhere. Use STEP 3 to get unstuck, then go to **STEP 6** and put it
> back.

---

## STEP 4 — Also undo the tenure column (migration 0003)

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < 0003_down.sql
```

**What it does:** removes the `tenure_bonus_tier_granted` column from
`k9_partnerships`.

**⚠️ This is the one file here that loses information.** No rows are
deleted — but that column is the only record of which tenure bonuses have
already been paid out. Remove it and put it back and every value resets to
zero, which the resource reads as "never paid." Every long-running
partnership will then be paid its 1-day, 7-day and 30-day XP bonuses all
over again.

Your STEP 1 backup contains those values. Nothing else does.

**How to tell it worked:**
```sql
SHOW COLUMNS FROM k9_partnerships;
```
`tenure_bonus_tier_granted` should be gone; every other column stays.

**Safe to run twice.**

---

## STEP 5 — "It said *Duplicate entry … for key uq_one_active_cert_per_job*"

This is the most common reason people end up in this folder, so here is
the whole fix.

**What happened, in plain terms:** your database already contains the same
officer certified twice for the same job at the same time. That should
never happen, and migration `0004` exists precisely to make it impossible
from now on. But it cannot switch that rule on while the database already
breaks it — so it stops and tells you.

**Nothing is broken and nothing is lost.** Work through it in order:

**5a. Roll back the half-applied migration:**
```bash
mysql -u YOUR_USER -p YOUR_DATABASE < 0004_down.sql
```

**5b. See who is duplicated:**
```sql
SELECT citizenid, job, COUNT(*) AS dupes
FROM k9_certifications
WHERE active = 1
GROUP BY citizenid, job
HAVING COUNT(*) > 1;
```

**5c. Fix them.** This keeps the newest certification for each person and
marks the older extras as revoked. It **deletes nothing** — the old rows
stay in place as history, exactly as an audit log should:
```sql
UPDATE k9_certifications c
JOIN (
    SELECT citizenid, job, MAX(id) AS keep_id
    FROM k9_certifications
    WHERE active = 1
    GROUP BY citizenid, job
) k ON c.citizenid = k.citizenid AND c.job = k.job
SET c.active = 0,
    c.revoked_by = 'MIGRATION-DEDUPE',
    c.revoked_at = NOW()
WHERE c.active = 1 AND c.id <> k.keep_id;
```

Run 5b again — it should now return no rows.

**5d. Retry the migration:**
```bash
mysql -u YOUR_USER -p YOUR_DATABASE < ../migrations/0004_add_k9_certifications_active_cert_key.sql
```

It should finish with no error. Confirm:
```sql
SHOW INDEX FROM k9_certifications;
```
`uq_one_active_cert_per_job` is back. You are done.

---

## STEP 6 — Put a rollback back (go forward again)

Rollbacks are not one-way. To re-apply what you undid, run the matching
migration from `sql/migrations/`, in number order:

```bash
mysql -u YOUR_USER -p YOUR_DATABASE < ../migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql
mysql -u YOUR_USER -p YOUR_DATABASE < ../migrations/0004_add_k9_certifications_active_cert_key.sql
```

This round trip is tested: install → roll back → re-apply produces a
schema byte-for-byte identical to where you started, with every row
untouched.

(Remember the STEP 4 caveat: the *shape* comes back identical, but
`tenure_bonus_tier_granted`'s **values** come back as zero. Restore your
backup if you need those.)

---

## STEP 7 — Delete everything (full uninstall)

**Read STEP 2 again first.** You almost certainly do not need this. To
simply stop using the resource, remove `ensure qbx_k9unit` from
`server.cfg` and leave the tables alone — they cost you nothing.

If you genuinely want the tables gone:

1. **Do STEP 1.** This is the last moment a backup can save you.
2. Open `uninstall_all.sql` in a text editor.
3. Find this line near the top:
   ```
   -- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';
   ```
4. Delete the two dashes and the space at the start, so it becomes:
   ```
   SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';
   ```
5. Save, then run:
   ```bash
   mysql -u YOUR_USER -p YOUR_DATABASE < uninstall_all.sql
   ```

**How to tell it worked:** it prints `UNINSTALLED`. If it prints
`REFUSED - NOTHING WAS DELETED`, you did not uncomment the line — and
nothing was deleted, so just try again.

**Run it unmodified and it does nothing at all.** That is deliberate: you
cannot wipe your K9 data by pasting the wrong file.

This deletes all five tables and everything in them, permanently. Your
STEP 1 backup is the only way back.

---

## STEP 8 — Restore from your backup

Use the line the backup script printed in STEP 1:

```bash
mysql -h 127.0.0.1 -P 3306 -u YOUR_USER -p YOUR_DATABASE < qbx_k9unit-backup-....sql
```

This puts all five tables back exactly as they were when you took the
backup. Anything written *after* the backup is not in it.

**How to tell it worked:**
```sql
SELECT COUNT(*) FROM k9_certifications;
SELECT COUNT(*) FROM k9_search_log;
SELECT COUNT(*) FROM k9_partnerships;
SELECT COUNT(*) FROM k9_progression;
```
The numbers should match the "Rows saved" list the backup printed.

Tested end to end: dropping all five tables and restoring from a backup
returns every row, and every calculated column, exactly as it was.

---

## What each file in this folder is

| File | Undoes | Deletes rows? | Safe to re-run? |
|---|---|---|---|
| `backup_k9_tables.sh` | *(nothing — it saves)* | No, read-only | Yes |
| `0004_down.sql` | migration 0004 | **No** | Yes |
| `0003_down.sql` | migration 0003 | No rows, but loses one column's values | Yes |
| `0002_down.sql` | migration 0002 | **No — does nothing on purpose** | Yes |
| `0005_down.sql` | migration 0005 | **No — does nothing on purpose** | Yes |
| `0001_down.sql` | migration 0001 | **No — does nothing on purpose** | Yes |
| `uninstall_all.sql` | the whole install | **YES, all five tables** — inert until you arm it | Yes |

**Why do `0001_down.sql` and `0002_down.sql` do nothing?** Those two
migrations each create a table. The only way to undo "create a table" is
to delete it and everything in it. No rollback file here will ever do
that — deleting data is a separate, deliberate decision, and it lives in
exactly one clearly-labelled place (`uninstall_all.sql`). Run those two
files anyway and they will safely report how many rows they *would* have
destroyed, so you can decide with real numbers in front of you.

---

## Requirements

Same as the install: **MySQL 5.7.8 or newer, or MariaDB 10.2 or newer.**

MySQL 5.6 and older cannot run this resource's schema at all — see the
note at the top of `sql/install.sql`.

Everything in this folder is tested on MariaDB 10.11, MySQL 5.7 and
MySQL 8.0.
