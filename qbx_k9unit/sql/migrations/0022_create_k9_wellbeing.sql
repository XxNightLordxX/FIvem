-- =====================================================================
-- qbx_k9unit :: migration 0022 :: create k9_wellbeing
--
-- WHO NEEDS THIS FILE: an existing installation whose `qbx_k9unit/sql/install.sql`
-- was applied BEFORE `k9_wellbeing` existed in it. A brand-new install
-- needs this file too, right now, as of this pass -- unlike most of the
-- migrations in this folder, `sql/install.sql` has NOT yet been updated to
-- create this table (see the DISCLOSED CROSS-FILE DEPENDENCY note below).
-- Run this file explicitly (or via `sql/k9_setup.sh`, which already runs
-- every file in this folder after install.sql) until install.sql catches
-- up.
--
-- WHAT THIS TABLE IS FOR: server/wellbeing.lua's six per-K9 stats
-- (fatigue, mood, fearStress, injury, hunger, thirst) used to live ONLY in
-- that file's own in-memory table, with no database write of any kind
-- ever existing for it -- a routine resource restart (or a crash) silently
-- reset every online K9's condition to fresh-and-uninjured, no matter what
-- had happened to it in-game, with no config flag, no log line and no
-- player-visible warning that this was happening. This table is what
-- server/wellbeing.lua's new `K9Store.Wellbeing_Get`/
-- `K9Store.Wellbeing_Upsert` accessors read/write, one row per citizenid,
-- exactly mirroring `k9_progression`'s own shape (a single UPSERT-able
-- row per citizenid, no history table -- there is nothing here worth
-- keeping a change log of, unlike a certification grant/revoke).
--
-- WHAT IS DELIBERATELY NOT IN THIS TABLE: the four short-lived
-- "GetGameTimer() timer window" fields server/wellbeing.lua's own
-- in-memory struct also tracks (distractedUntil, hesitatingUntil,
-- hesitationEpisodeStartedAt, injuryDeathEpisodeStartedAt) are
-- process-uptime-relative timestamps, not wall-clock ones -- meaningless,
-- and actively misleading, the instant the server process restarts. Only
-- the six real, wall-clock-meaningful magnitude stats are persisted. See
-- server/wellbeing.lua's own header, "DATABASE PERSISTENCE" section, for
-- the full design writeup this table exists to support.
--
-- DISCLOSED CROSS-FILE DEPENDENCY, NOT SILENTLY ASSUMED COMPLETE: this
-- migration was authored under a file-ownership boundary that does not
-- include server/datastore.lua (the ONLY file in this resource permitted
-- to name a `k9_*` table or call `MySQL.*` directly), sql/install.sql,
-- sql/preflight_check.sql, sql/migration_status.sql,
-- sql/rollback/uninstall_all.sql, sql/rollback/backup_k9_tables.sh, or
-- tests/schemaconvergence_spec.lua's own hand-maintained
-- MIGRATION_FILES_THAT_CREATE_TABLES list. Every one of those needs a
-- matching entry for `k9_wellbeing` (server/datastore.lua specifically
-- needs two new accessors, `K9Store.Wellbeing_Get(citizenid)` mirroring
-- `MySQL.single.await` and `K9Store.Wellbeing_Upsert(citizenid, row)`
-- returning a boolean and never throwing, mirroring this resource's own
-- SafeWrite-style bespoke-wrapper contract) before this table is actually
-- reachable from a running server. server/wellbeing.lua itself already
-- degrades safely in the meantime -- every `K9Store.Wellbeing_*` call site
-- there is soft-guarded (`type(K9Store.Wellbeing_Get) == 'function'`) and
-- falls back to exactly its own pre-existing memory-only behaviour, never
-- an error, until those accessors exist. This migration is shipped now,
-- rather than withheld, so the schema half of this work is not blocked on
-- the wiring half landing first.
--
-- IDEMPOTENT / SAFE TO RE-RUN: `CREATE TABLE IF NOT EXISTS` is a no-op if
-- the table already exists -- never ALTERs, never DROPs, never touches
-- existing rows. Safe to run any number of times, in any order relative
-- to install.sql or the other migration files in this folder. Never
-- writes into any table this resource does not own -- this file creates
-- exactly one new table and touches nothing else.
--
-- NO DATA LOSS RISK ON A LIVE, POPULATED DATABASE: this is a brand-new
-- table name, never previously used by this resource -- there is no
-- existing `k9_wellbeing` data anywhere for this migration to collide
-- with, and no other table's rows are read, modified, or referenced by
-- this statement.
--
-- SHAPE: one row per citizenid, matching `k9_progression`'s own
-- (migration 0002 / install.sql) established style for a single-row-per-
-- citizenid UPSERT-able table -- VARCHAR(50) citizenid primary key (same
-- width as every other citizenid column in this schema), DECIMAL(6,2) for
-- each 0-100-range stat (two decimal places is ample precision for a
-- gauge this resource already displays as a whole/near-whole number; the
-- full-precision running value stays in server/wellbeing.lua's own memory
-- for the whole session and is only ever rounded at the moment it is
-- flushed to disk), and the same DATETIME `updated_at ON UPDATE
-- CURRENT_TIMESTAMP` convention `k9_progression` already uses.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_wellbeing` (
  `citizenid`   VARCHAR(50)  NOT NULL,
  `fatigue`     DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `mood`        DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `fear_stress` DECIMAL(6,2) NOT NULL DEFAULT 0.00,
  `injury`      DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `hunger`      DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `thirst`      DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `updated_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
