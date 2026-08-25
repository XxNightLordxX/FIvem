-- =====================================================================
-- qbx_k9unit :: MIGRATION PLAN / DRY RUN -- read-only, changes nothing
--
-- WHAT IT DOES: tells you exactly what running `install.sql` and every
-- file in `sql/migrations/` (in order) WOULD do to this database right
-- now, without doing any of it. Every row below is either "no-op — already
-- applied" or a plain-English description of the real CREATE/ALTER
-- statement that file would run.
--
-- WHY THIS IS THE ONLY HONEST WAY TO "DRY RUN" A SCHEMA CHANGE: MySQL and
-- MariaDB both auto-commit CREATE TABLE / ALTER TABLE the instant they run
-- -- there is no way to wrap them in a transaction and roll it back
-- afterward to "preview" them. Actually running the real files is the only
-- way to know for certain they will work; this report is the next best
-- thing -- it reads the exact same INFORMATION_SCHEMA state the guarded
-- migrations themselves check, and prints what they would decide.
--
-- HOW TO RUN IT:
--     mysql -u YOUR_USER -p YOUR_DATABASE < migration_status.sql
-- ...or paste it into phpMyAdmin / HeidiSQL with your database selected.
-- `sql/k9_setup.sh --dry-run` runs this for you automatically.
--
-- SAFE EVEN WHEN OUR TABLES DO NOT EXIST YET (fresh database): every
-- check below either queries INFORMATION_SCHEMA only (which always
-- exists), or -- for the one check that genuinely needs to look at real
-- row data (0004's pre-existing-duplicate-certification check) -- uses
-- PREPARE/EXECUTE to build that query ONLY when the target table is
-- confirmed present. A flat `SELECT ... FROM k9_certifications ...` would
-- itself throw a raw "table doesn't exist" error on a fresh database
-- before ever reaching a WHERE guard (MySQL resolves table names at parse
-- time, not row-evaluation time) -- exactly the kind of raw error this
-- report exists to prevent, so it is avoided here on purpose.
-- PREPARE/EXECUTE needs no elevated privilege (unlike a stored procedure,
-- it does not require CREATE ROUTINE), so this file works on the same
-- restricted/managed hosts preflight_check.sql's own CHECK 4 already
-- flags as sometimes lacking that grant.
--
-- This never touches sql/rollback/uninstall_all.sql -- that file's own
-- unarmed run is already its own free dry run (see that file's header).
-- =====================================================================


-- ---------------------------------------------------------------------
-- PART 1: install.sql -- what would a plain run create right now?
--
-- install.sql only ever CREATEs (CREATE TABLE IF NOT EXISTS); it never
-- ALTERs a table that already exists in some other shape. So for any
-- table already present, install.sql is a guaranteed no-op EVEN IF that
-- table is missing a column/index a later migration would add -- that is
-- exactly what the migrations in PART 2 below are for.
-- ---------------------------------------------------------------------
SELECT
    t.table_name AS `install.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN 'CREATE this table (currently absent)'
         ELSE 'no-op -- table already exists (install.sql never ALTERs an existing table; see PART 2 for column/index-level changes)'
    END AS plan
FROM (
    SELECT 'k9_certifications' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists
    UNION ALL SELECT 'k9_certification_specializations',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations')
    UNION ALL SELECT 'k9_search_log',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log')
    UNION ALL SELECT 'k9_partnerships',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships')
    UNION ALL SELECT 'k9_progression',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression')
    UNION ALL SELECT 'k9_permissions',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions')
    UNION ALL SELECT 'k9_runtime_feature_overrides',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides')
    UNION ALL SELECT 'k9_runtime_override_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit')
    UNION ALL SELECT 'k9_tablet_theme',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme')
    UNION ALL SELECT 'k9_tablet_theme_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit')
    UNION ALL SELECT 'k9_ped_assignments',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments')
    UNION ALL SELECT 'k9_certification_tiers',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tiers')
    UNION ALL SELECT 'k9_certification_tier_capabilities',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_capabilities')
    UNION ALL SELECT 'k9_certification_tier_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_audit')
) t
ORDER BY t.table_name;
-- NOTE: install.sql now converges with sql/migrations/0001-0010 (14 tables
-- total, including k9_progression's idx_xp and migration 0010's three
-- certification-tier tables) -- db-schema foolproofing pass. If this
-- comment and install.sql's real table count ever disagree again,
-- install.sql is out of date; report it rather than trust this file. (This
-- comment previously said "0001-0009 / 11 tables" and did not mention
-- migration 0010 at all -- the exact class of silent omission this note
-- exists to flag, now fixed in this same change alongside PART 2 below.)


-- ---------------------------------------------------------------------
-- PART 2: sql/migrations/0001-0009 -- what would each one do, in order?
--
-- Mirrors each file's own INFORMATION_SCHEMA guard exactly, so the
-- verdict below is what that file will actually decide, not a guess.
-- ---------------------------------------------------------------------

-- 0001 / 0002 / 0005 / 0007: bare CREATE TABLE IF NOT EXISTS, no ALTER,
-- no dependency on any other table -- same no-op-or-create logic as PART 1.
SELECT
    m.migration_file AS `migration`,
    CASE WHEN m.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', m.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', m.table_name, '` already exists')
    END AS plan
FROM (
    SELECT '0001_create_k9_partnerships.sql' AS migration_file, 'k9_partnerships' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships') AS tbl_exists
    UNION ALL SELECT '0002_create_k9_progression.sql', 'k9_progression',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression')
    UNION ALL SELECT '0005_create_k9_permissions.sql', 'k9_permissions',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions')
    UNION ALL SELECT '0007_create_k9_runtime_control.sql', 'k9_runtime_feature_overrides',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides')
    UNION ALL SELECT '0008_create_k9_ped_assignments.sql', 'k9_ped_assignments',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments')
) m;

-- 0007 creates FOUR tables in one file -- the other three, reported
-- separately so a partially-applied 0007 (e.g. interrupted mid-file) shows
-- accurately instead of only reporting on the first table.
SELECT
    '0007_create_k9_runtime_control.sql (cont.)' AS `migration`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_runtime_override_audit' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit') AS tbl_exists
    UNION ALL SELECT 'k9_tablet_theme',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme')
    UNION ALL SELECT 'k9_tablet_theme_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit')
) t;

-- 0003: ALTER k9_partnerships, ADD COLUMN tenure_bonus_tier_granted.
-- Depends on k9_partnerships existing first (see the order-protection
-- guard added to 0003 itself) -- reported here too, so a dry run catches
-- the same "wrong order" problem the migration itself would refuse on.
-- Row count comes from INFORMATION_SCHEMA's own InnoDB estimate
-- (TABLE_ROWS), not a live COUNT(*) -- approximate, but safe to read even
-- when the table does not exist (simply NULL), and this report is
-- explicitly a planning estimate everywhere else too.
SELECT
    '0003_add_k9_partnerships_tenure_bonus_tier_granted.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_partnerships does not exist yet. Run install.sql or migration 0001 first.'
        WHEN base.col_exists > 0
            THEN 'no-op -- tenure_bonus_tier_granted already present'
        ELSE CONCAT('ADD COLUMN tenure_bonus_tier_granted to k9_partnerships (defaults to 0 for all ~',
                    IFNULL(base.approx_rows, 0), ' existing row(s))')
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships' AND COLUMN_NAME='tenure_bonus_tier_granted') AS col_exists,
      (SELECT TABLE_ROWS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships') AS approx_rows
) base;

-- 0004: ALTER k9_certifications -- add active_cert_key, two plain indexes,
-- and the uq_one_active_cert_per_job unique key. Depends on
-- k9_certifications existing first.
--
-- The duplicate-active-row pre-check below (the ONE way this migration can
-- legitimately fail even when the table exists) needs to look at REAL ROWS
-- in k9_certifications, not just INFORMATION_SCHEMA metadata -- so it is
-- built as dynamic SQL (PREPARE/EXECUTE) gated on the table actually
-- existing, per this file's own header note on why a flat SELECT here
-- would be unsafe on a fresh database.
SET @k9ms_has_certs = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications');
SET @k9ms_dupe_pairs = 0;
SET @k9ms_dupe_sql = IF(@k9ms_has_certs > 0,
    'SELECT COUNT(*) INTO @k9ms_dupe_pairs FROM (SELECT citizenid, job FROM k9_certifications WHERE active = 1 GROUP BY citizenid, job HAVING COUNT(*) > 1) k9ms_dupes',
    'SELECT 1');
PREPARE k9ms_stmt FROM @k9ms_dupe_sql;
EXECUTE k9ms_stmt;
DEALLOCATE PREPARE k9ms_stmt;

SELECT
    '0004_add_k9_certifications_active_cert_key.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_certifications does not exist yet. Run install.sql first.'
        WHEN base.col_exists > 0 AND base.uq_exists > 0 AND base.idx1_exists > 0 AND base.idx2_exists > 0
            THEN 'no-op -- active_cert_key column and all three indexes already present'
        ELSE CONCAT(
            'will apply what is missing: ',
            IF(base.col_exists = 0, 'ADD COLUMN active_cert_key; ', ''),
            IF(base.idx1_exists = 0, 'ADD INDEX idx_citizen_job_active; ', ''),
            IF(base.idx2_exists = 0, 'ADD INDEX idx_job_active; ', ''),
            IF(base.uq_exists = 0,
               IF(@k9ms_dupe_pairs > 0,
                  CONCAT('ADD UNIQUE KEY uq_one_active_cert_per_job -- WILL FAIL: ', @k9ms_dupe_pairs,
                         ' (citizenid, job) pair(s) already have more than one active row. See sql/rollback/README.md STEP 5 BEFORE running this migration.'),
                  'ADD UNIQUE KEY uq_one_active_cert_per_job'),
               '')
        )
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='active_cert_key') AS col_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='uq_one_active_cert_per_job') AS uq_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='idx_citizen_job_active') AS idx1_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='idx_job_active') AS idx2_exists
) base;

-- 0006: ALTER k9_certifications (tier / revoke_reason / expires_at /
-- idx_expires_at) + CREATE TABLE k9_certification_specializations. The
-- order-protection guard added to 0006 SIGNALs when k9_certifications is
-- missing, and the plain mysql CLI (this resource's documented invocation
-- method) aborts the rest of the script on that error -- so the WHOLE FILE
-- is blocked as one unit, Step 5's CREATE TABLE included, not just the
-- four ALTER steps (verified by execution; an earlier draft of both this
-- report and 0006's own guard comment said otherwise -- corrected here to
-- match what actually happens).
SELECT
    '0006_add_k9_certification_lifecycle.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED (the whole file, including the new k9_certification_specializations TABLE) -- k9_certifications does not exist yet. Run install.sql first.'
        WHEN base.tier_exists > 0 AND base.reason_exists > 0 AND base.expires_exists > 0 AND base.idx_exists > 0
            THEN 'no-op -- tier, revoke_reason, expires_at and idx_expires_at already present on k9_certifications'
        ELSE CONCAT(
            'will apply what is missing on k9_certifications: ',
            IF(base.tier_exists = 0, 'ADD COLUMN tier (defaults every existing row to ''certified'', preserving current access); ', ''),
            IF(base.reason_exists = 0, 'ADD COLUMN revoke_reason (NULL, no backfill); ', ''),
            IF(base.expires_exists = 0, 'ADD COLUMN expires_at (NULL, no backfill -- never expires); ', ''),
            IF(base.idx_exists = 0, 'ADD INDEX idx_expires_at; ', '')
        )
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='tier') AS tier_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='revoke_reason') AS reason_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='expires_at') AS expires_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='idx_expires_at') AS idx_exists
) base;

SELECT
    '0006_add_k9_certification_lifecycle.sql (cont.)' AS `migration`,
    CASE WHEN spec.tbl_exists = 0
         THEN 'CREATE TABLE k9_certification_specializations (currently absent -- independent of the k9_certifications columns above)'
         ELSE 'no-op -- k9_certification_specializations already exists'
    END AS plan
FROM (
    SELECT (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations') AS tbl_exists
) spec;

-- 0009: ALTER k9_progression, ADD KEY idx_xp (xp) -- for /k9stats
-- (Config.Features.K9Leaderboard). Depends on k9_progression existing
-- first (see the order-protection guard added to 0009 itself). Plain
-- index, no data written, so no duplicate-row failure mode like 0004's.
SELECT
    '0009_add_k9_progression_idx_xp.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_progression does not exist yet. Run install.sql or migration 0002 first.'
        WHEN base.idx_exists > 0
            THEN 'no-op -- idx_xp already present'
        ELSE 'ADD INDEX idx_xp (xp) to k9_progression'
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression' AND INDEX_NAME='idx_xp') AS idx_exists
) base;


-- ---------------------------------------------------------------------
-- PART 3: blast-radius summary -- row counts for every table that
-- ALREADY exists (these are what a full-database backup, taken before you
-- proceed, would be protecting).
-- ---------------------------------------------------------------------
SELECT TABLE_NAME AS `existing_table`, TABLE_ROWS AS `approx_rows`
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships','k9_progression',
                      'k9_permissions','k9_certification_specializations',
                      'k9_runtime_feature_overrides','k9_runtime_override_audit',
                      'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments')
ORDER BY TABLE_NAME;

SELECT 'DRY RUN COMPLETE -- nothing was changed by this report. Run sql/k9_setup.sh (without --dry-run) to actually apply the plan above; it backs up your whole database first, automatically, and refuses to write anything if that backup fails.' AS final_note;
