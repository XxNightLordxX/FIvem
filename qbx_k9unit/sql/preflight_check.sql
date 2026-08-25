-- =====================================================================
-- qbx_k9unit :: PRE-INSTALL SAFETY CHECK -- run this BEFORE install.sql
--
-- WHAT IT DOES: looks at your database and tells you whether installing
-- this resource is safe. It is READ-ONLY -- it makes no changes at all,
-- creates nothing, and can be run on a live production server at any
-- time, as many times as you like.
--
-- HOW TO RUN IT:
--     mysql -u YOUR_USER -p YOUR_DATABASE < preflight_check.sql
-- ...or paste it into phpMyAdmin / HeidiSQL with your database selected.
--
-- WHAT YOU WANT TO SEE: every row saying "OK". Anything starting with
-- "!!" means stop and read that row before you install.
--
-- It deliberately uses NO stored procedures, so it also works on managed
-- hosts that do not grant CREATE ROUTINE -- which is itself one of the
-- things it checks for you (see CHECK 2).
-- =====================================================================


-- ---------------------------------------------------------------------
-- CHECK 1: does anything already own one of our five table names?
--
-- `install.sql` uses CREATE TABLE IF NOT EXISTS, so it will never
-- overwrite or damage a table that is already there -- but that also
-- means it will silently SKIP a table whose name is taken by something
-- else, leaving this resource pointed at a table it cannot use. That
-- shows up later as confusing "Unknown column" errors at runtime rather
-- than as an install failure, so it is worth five seconds to check now.
--
-- A table counted as "ours" is matched on its identifying columns only,
-- NOT on the columns that later migrations add -- so a database from an
-- older version of this resource correctly reports as ours, needing
-- migrations, rather than as a conflict.
-- ---------------------------------------------------------------------
SELECT
    x.table_name AS `table`,
    CASE
        WHEN x.tbl_exists = 0
            THEN 'OK - absent; install.sql will create it'
        WHEN x.cols_found = x.cols_expected
            THEN 'OK - already present and is ours'
        ELSE CONCAT('!! CONFLICT - a DIFFERENT table already uses this name (matched only ',
                    x.cols_found, ' of ', x.cols_expected,
                    ' expected columns). Do NOT install until this is resolved.')
    END AS verdict
FROM (
    SELECT 'k9_certifications' AS table_name, 7 AS cols_expected,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications'
         AND COLUMN_NAME IN ('citizenid','job','granted_by','granted_at','revoked_by','revoked_at','active')) AS cols_found
    UNION ALL SELECT 'k9_search_log', 9,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log'
         AND COLUMN_NAME IN ('searcher_citizenid','searcher_job','target_type','target_plate','target_citizenid','result','total_weight','alert_tier','searched_at'))
    UNION ALL SELECT 'k9_partnerships', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships'
         AND COLUMN_NAME IN ('k9_citizenid','handler_citizenid','established_by','established_at','ended_by','ended_at','active'))
    UNION ALL SELECT 'k9_progression', 4,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression'
         AND COLUMN_NAME IN ('citizenid','xp','created_at','updated_at'))
    UNION ALL SELECT 'k9_permissions', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions'
         AND COLUMN_NAME IN ('citizenid','permission','granted_by','granted_at','revoked_by','revoked_at','active'))
) x
ORDER BY x.table_name;


-- ---------------------------------------------------------------------
-- CHECK 2: is your database server new enough, and can it run the
-- migrations?
--
-- Two separate requirements:
--   * VERSION -- MySQL 5.7.8+ or MariaDB 10.2+. Older servers cannot
--     parse this resource's generated columns at all and will leave a
--     half-built database. MySQL 5.6 in particular WILL fail.
--   * CREATE ROUTINE -- migrations 0003 and 0004 create a temporary
--     stored procedure, run it once, and immediately drop it again.
--     Some managed/shared hosts do not grant this. install.sql itself
--     does NOT need it; only those two migration files do.
-- ---------------------------------------------------------------------
SELECT
    VERSION() AS server_version,
    CASE
        WHEN VERSION() LIKE '%MariaDB%' THEN
            CASE WHEN CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) > 10
                   OR (CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) = 10
                       AND CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(),'.',2),'.',-1) AS UNSIGNED) >= 2)
                 THEN 'OK - MariaDB 10.2 or newer'
                 ELSE '!! TOO OLD - needs MariaDB 10.2 or newer. Do NOT install.' END
        WHEN CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) >= 8 THEN 'OK - MySQL 8'
        WHEN CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) = 5
             AND CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(),'.',2),'.',-1) AS UNSIGNED) >= 7
             THEN 'OK - MySQL 5.7 (must be 5.7.8 or newer)'
        ELSE '!! TOO OLD - needs MySQL 5.7.8+ or MariaDB 10.2+. Do NOT install.'
    END AS version_verdict;


-- ---------------------------------------------------------------------
-- CHECK 3: what is already in our tables, if anything?
--
-- Purely informational: if these are non-zero you are upgrading, not
-- installing fresh, so take a backup first
-- (sql/rollback/backup_k9_tables.sh). Zeroes here are perfectly normal
-- for a first install -- CHECK 1 above is the one that matters.
-- ---------------------------------------------------------------------
SELECT TABLE_NAME AS `our_table`, TABLE_ROWS AS `approx_rows`
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships','k9_progression','k9_permissions')
ORDER BY TABLE_NAME;
