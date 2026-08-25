-- =====================================================================
-- qbx_k9unit :: FULL UNINSTALL -- DROPS ALL SIX TABLES
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
--   k9_certification_specializations
--                      Every K9 specialization ever granted or revoked
--                      (narcotics / tracking / etc.), and by whom. Same
--                      shape of loss as k9_permissions: dropping it
--                      erases the audit trail AND silently removes every
--                      currently-active specialization.
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
-- leaves all six tables intact and harmless on disk in case you ever
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
    -- =================================================================
    -- SAFETY GATE -- runs BEFORE anything is dropped, armed or not.
    --
    -- WHY THIS EXISTS (a real, reproduced failure, not a theoretical one):
    -- if any OTHER table in this database has a FOREIGN KEY pointing at
    -- one of our tables, `DROP TABLE` on that table is refused by InnoDB
    -- with error 1451. Without this gate the uninstall would already have
    -- dropped the earlier tables in the list before hitting that error,
    -- and the `mysql` client aborts the rest of the file -- leaving the
    -- operator with SOME of our tables gone and the rest still there.
    -- Measured before this gate was added: `k9_search_log` (the audit log,
    -- and the one table that is reconstructible from nothing) was already
    -- destroyed, then the run stopped, leaving five tables behind.
    --
    -- A half-completed uninstall is worse than one that refuses to start,
    -- so this refuses to start. Nothing is dropped unless everything can
    -- be dropped.
    -- =================================================================
    DECLARE fk_blockers INT DEFAULT 0;

    SELECT COUNT(*) INTO fk_blockers
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
    WHERE CONSTRAINT_SCHEMA = DATABASE()
      AND REFERENCED_TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships',
                                    'k9_progression','k9_permissions','k9_certification_specializations',
                                    'k9_runtime_feature_overrides','k9_runtime_override_audit',
                                    'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments')
      AND TABLE_NAME NOT IN ('k9_certifications','k9_search_log','k9_partnerships',
                             'k9_progression','k9_permissions','k9_certification_specializations',
                             'k9_runtime_feature_overrides','k9_runtime_override_audit',
                             'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments');

    -- -----------------------------------------------------------------
    -- DEPENDENCY REPORT -- always printed, whether or not this file is
    -- armed. Running it UNARMED is therefore a free dry run: it tells you
    -- exactly what removing this resource would affect, and changes
    -- nothing. An empty report means nothing else in your database
    -- references our tables.
    -- -----------------------------------------------------------------
    SELECT problem, object_name, detail FROM (
        SELECT 1 AS ord,
               'BLOCKS UNINSTALL - foreign key into our table' AS problem,
               CONSTRAINT_NAME AS object_name,
               CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' references ', REFERENCED_TABLE_NAME,
                      ' -- drop this constraint first: ALTER TABLE `', TABLE_NAME,
                      '` DROP FOREIGN KEY `', CONSTRAINT_NAME, '`;') AS detail
        FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
        WHERE CONSTRAINT_SCHEMA = DATABASE()
          AND REFERENCED_TABLE_NAME REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments)$'
          AND TABLE_NAME NOT REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments)$'
        UNION ALL
        SELECT 2,
               'WILL BREAK - view reads one of our tables',
               TABLE_NAME,
               'This view keeps existing after the uninstall but errors with "references invalid table(s)" whenever anything uses it. Drop or rewrite it.'
        FROM INFORMATION_SCHEMA.VIEWS
        WHERE TABLE_SCHEMA = DATABASE()
          AND VIEW_DEFINITION REGEXP 'k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments)'
        UNION ALL
        SELECT 3,
               'WILL BE DELETED - trigger lives on one of our tables',
               TRIGGER_NAME,
               CONCAT('This trigger is attached to ', EVENT_OBJECT_TABLE,
                      ' and MySQL deletes it together with that table. Save its definition now if you want it back (SHOW CREATE TRIGGER `', TRIGGER_NAME, '`).')
        FROM INFORMATION_SCHEMA.TRIGGERS
        WHERE TRIGGER_SCHEMA = DATABASE()
          AND EVENT_OBJECT_TABLE REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments)$'
        UNION ALL
        SELECT 4,
               'WILL BREAK - stored routine reads one of our tables',
               ROUTINE_NAME,
               'This routine keeps existing after the uninstall but fails with "Table doesn''t exist" when called. Drop or rewrite it.'
        FROM INFORMATION_SCHEMA.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
          AND ROUTINE_NAME NOT LIKE 'qbx\_k9unit\_%'
          AND ROUTINE_DEFINITION REGEXP 'k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments)'
    ) deps
    ORDER BY ord, object_name;

    -- `<=>` is NULL-safe equality: when the arming line above is left
    -- commented out, @K9_UNINSTALL_CONFIRM is NULL, and a plain `=` would
    -- yield NULL (neither true nor false) rather than a clean false. `<=>`
    -- makes the unarmed case a definite, reliable "no".
    IF NOT (@K9_UNINSTALL_CONFIRM <=> 'YES-DELETE-ALL-MY-K9-DATA') THEN
        SELECT 'NOT ARMED - NOTHING WAS DELETED' AS status,
               'This file is not armed, so it did nothing at all. Your tables are untouched. Any rows listed above are what removing this resource WOULD affect -- this was a free dry run. To really delete: take a backup first (sql/rollback/backup_k9_tables.sh), then uncomment the SET @K9_UNINSTALL_CONFIRM line near the top of this file and run it again.' AS detail;

    ELSEIF fk_blockers > 0 THEN
        SELECT 'REFUSED - NOTHING WAS DELETED' AS status,
               CONCAT('Another table in this database has ', fk_blockers,
                      ' foreign key column(s) pointing at our tables (listed above). MySQL will not let those tables be dropped while those constraints exist, and dropping only SOME of our tables would leave you half-uninstalled -- so nothing was touched at all. Remove the listed constraint(s) with the ALTER TABLE command shown above, then run this file again.') AS detail;

    ELSE
        DROP TABLE IF EXISTS `k9_search_log`;
        DROP TABLE IF EXISTS `k9_certifications`;
        DROP TABLE IF EXISTS `k9_partnerships`;
        DROP TABLE IF EXISTS `k9_progression`;
        DROP TABLE IF EXISTS `k9_permissions`;
        DROP TABLE IF EXISTS `k9_certification_specializations`;
        DROP TABLE IF EXISTS `k9_runtime_feature_overrides`;
        DROP TABLE IF EXISTS `k9_runtime_override_audit`;
        DROP TABLE IF EXISTS `k9_tablet_theme`;
        DROP TABLE IF EXISTS `k9_tablet_theme_audit`;
        DROP TABLE IF EXISTS `k9_ped_assignments`;

        -- RESIDUE REPORT: name any k9_* table this file did NOT drop. New
        -- migrations add tables, and if one is ever missed out of the list
        -- above it would otherwise be left behind in silence. This turns
        -- that into a visible line. Tables belonging to OTHER K9 resources
        -- (e.g. k9_units) legitimately appear here -- they are not ours to
        -- drop -- so this is a prompt to check, not an error.
        SELECT 'STILL PRESENT - not dropped by this file' AS note, TABLE_NAME AS table_name,
               'If this belongs to qbx_k9unit then this uninstall script is out of date and missed it -- report that. If it belongs to a different K9 resource, this is correct and expected.' AS detail
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'k9\_%';

        SELECT 'UNINSTALLED' AS status,
               'Every qbx_k9unit table has been dropped. This is permanent. If you took a backup with backup_k9_tables.sh, the restore command it printed is now your only way back. Anything listed above as "WILL BREAK" is now broken and needs your attention.' AS detail;
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
-- This used to be a hand-maintained list of DROP PROCEDURE statements,
-- one per migration. That list fell out of date every single time a new
-- migration landed -- which is exactly the kind of silent drift that
-- leaves debris in an operator's database. It now sweeps by NAME PATTERN
-- instead, so a migration added tomorrow is cleaned up without anyone
-- having to remember to edit this file.
--
-- The pattern `qbx_k9unit\_%` is this resource's own reserved prefix and
-- nothing else in a sane database uses it; the escape makes `_` a literal
-- underscore rather than a single-character wildcard. Only PROCEDUREs in
-- the CURRENT database are considered -- never another schema, never a
-- FUNCTION, never a table.
--
-- Runs whether or not the uninstall was armed: it only ever removes this
-- resource's own leftover scaffolding, never a table and never a row, so
-- there is nothing to guard.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `qbx_k9unit_sweep_helper_procedures`;
DELIMITER $$
CREATE PROCEDURE `qbx_k9unit_sweep_helper_procedures`()
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE rname VARCHAR(128);
    DECLARE cur CURSOR FOR
        SELECT ROUTINE_NAME FROM INFORMATION_SCHEMA.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
          AND ROUTINE_TYPE = 'PROCEDURE'
          AND ROUTINE_NAME LIKE 'qbx\_k9unit\_%'
          AND ROUTINE_NAME <> 'qbx_k9unit_sweep_helper_procedures';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    sweep: LOOP
        FETCH cur INTO rname;
        IF done = 1 THEN LEAVE sweep; END IF;
        SET @drop_sql = CONCAT('DROP PROCEDURE IF EXISTS `', rname, '`');
        PREPARE stmt FROM @drop_sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL `qbx_k9unit_sweep_helper_procedures`();
DROP PROCEDURE IF EXISTS `qbx_k9unit_sweep_helper_procedures`;
