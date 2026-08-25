-- =====================================================================
-- qbx_k9unit :: FULL UNINSTALL -- DROPS ALL FIVE TABLES
--
-- #####################################################################
-- #  THIS FILE PERMANENTLY DELETES DATA. THERE IS NO UNDO.            #
-- #                                                                   #
-- #  IT IS INERT AS SHIPPED. Running it right now, as-is, does        #
-- #  NOTHING except print a refusal. You have to arm it by hand       #
-- #  (STEP 1 below) before it will delete anything. That is           #
-- #  deliberate: it means you cannot destroy your server's K9 data by #
-- #  pasting the wrong file into HeidiSQL or phpMyAdmin.              #
-- #####################################################################
--
-- WHAT YOU LOSE, permanently, when you arm and run this:
--
--   k9_certifications  Every K9-handler certification ever granted or
--                      revoked, and by whom. Your access-control record.
--
--   k9_search_log      Every contraband search ever performed: who
--                      searched, what they searched, when, and what was
--                      found. THIS IS THE ONE THAT MATTERS MOST. It is a
--                      privacy and accountability record -- the evidence
--                      trail for "did an officer actually search that
--                      player, and when". It is APPEND-ONLY and it is
--                      reconstructible from NOTHING. Once dropped, the
--                      answer to any future question about a past search
--                      is gone for good.
--
--   k9_partnerships    The full history of every K9/handler partnership:
--                      who, with whom, when formed, who ended it, when.
--
--   k9_progression     Every player's accumulated K9 XP, earned over
--                      weeks of play. Not recomputable.
--
--   k9_permissions     Every named K9 permission ever granted or revoked
--                      (k9.access / k9.certify / k9.audit / k9.givexp),
--                      and by whom. Your grantable-capability record --
--                      dropping this also silently strips every
--                      currently-active grant, not just the history.
--
-- ==> THE ONLY WAY BACK IS A BACKUP YOU TOOK BEFORE RUNNING THIS.
--     Run sql/rollback/backup_k9_tables.sh first. It takes seconds.
--     See sql/rollback/README.md step 1. If you have not run it, stop
--     now and go run it.
--
-- YOU PROBABLY DO NOT NEED THIS FILE. Almost every real "I need to undo
-- the install" situation is solved by the per-migration rollback scripts
-- in this directory (0004_down.sql / 0003_down.sql), which reverse a
-- schema change WITHOUT deleting anything. This file is only for
-- genuinely removing the resource from a server for good. If you are
-- unsure which you want: you want 0004_down.sql, not this.
--
-- Also note: you do NOT need to uninstall to stop using the resource.
-- Removing `ensure qbx_k9unit` from server.cfg stops it completely, and
-- leaves all five tables intact and harmless on disk in case you ever
-- want them back. Just want permission grants specifically off?
-- `Config.Features.PermissionGrants = false` does that without touching
-- any table at all -- see sql/rollback/0005_down.sql.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1 -- ARM IT (this is the safety catch)
--
-- The line immediately below resets the confirmation to "not armed" every
-- single time this file runs, so a leftover setting from an earlier
-- session can never arm it behind your back.
-- ---------------------------------------------------------------------
SET @K9_UNINSTALL_CONFIRM = NULL;

-- To actually delete the tables, REMOVE THE TWO DASHES AND THE SPACE from
-- the start of the next line (turning it from a comment into a real
-- statement), then run this file:
--
-- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';
--
-- Leave it commented and this file stays a harmless no-op.
-- ---------------------------------------------------------------------


DROP PROCEDURE IF EXISTS `qbx_k9unit_uninstall_all`;
DELIMITER $$
CREATE PROCEDURE `qbx_k9unit_uninstall_all`()
BEGIN
    -- `<=>` is NULL-safe equality: when the arming line above is left
    -- commented out, @K9_UNINSTALL_CONFIRM is NULL, and a plain `=` would
    -- yield NULL (neither true nor false) rather than a clean false. `<=>`
    -- makes the unarmed case a definite, reliable "no".
    IF @K9_UNINSTALL_CONFIRM <=> 'YES-DELETE-ALL-MY-K9-DATA' THEN

        DROP TABLE IF EXISTS `k9_search_log`;
        DROP TABLE IF EXISTS `k9_certifications`;
        DROP TABLE IF EXISTS `k9_partnerships`;
        DROP TABLE IF EXISTS `k9_progression`;
        DROP TABLE IF EXISTS `k9_permissions`;

        SELECT 'UNINSTALLED' AS status,
               'All five qbx_k9unit tables have been dropped. This is permanent. If you took a backup with backup_k9_tables.sh, the restore command it printed is now your only way back.' AS detail;
    ELSE
        SELECT 'REFUSED - NOTHING WAS DELETED' AS status,
               'This file is not armed, so it did nothing at all. Your tables are untouched. If you genuinely want to delete them: take a backup first (sql/rollback/backup_k9_tables.sh), then uncomment the SET @K9_UNINSTALL_CONFIRM line near the top of this file and run it again.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `qbx_k9unit_uninstall_all`();
DROP PROCEDURE IF EXISTS `qbx_k9unit_uninstall_all`;


-- ---------------------------------------------------------------------
-- HOUSEKEEPING: remove every helper procedure this resource's migrations
-- or rollbacks could have left behind in this schema, so a full uninstall
-- really does leave nothing of qbx_k9unit anywhere in the database.
--
-- These run whether or not the uninstall was armed -- they only ever
-- delete this resource's own leftover scaffolding, never any table or any
-- row, so there is nothing to guard.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `qbx_k9unit_migration_0003_add_tenure_column`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_migration_0004_add_active_cert_key_column`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_migration_0004_add_idx_citizen_job_active`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_migration_0004_add_idx_job_active`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_migration_0004_add_uq_one_active_cert_per_job`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0001_report`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0002_report`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0003_drop_tenure_column`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0004_drop_active_cert_key_column`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0004_drop_idx_citizen_job_active`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0004_drop_idx_job_active`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0004_drop_uq_one_active_cert_per_job`;
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0005_report`;
