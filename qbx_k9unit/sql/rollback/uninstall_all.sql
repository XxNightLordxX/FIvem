-- =====================================================================
-- qbx_k9unit :: FULL UNINSTALL -- DROPS EVERY TABLE THIS RESOURCE OWNS
--
-- This header used to say "ALL SIX TABLES". It has said six for a long
-- time; the real number passed six, then eleven, and migration 0010 took
-- it to fourteen. A hardcoded count in a destructive script is a promise
-- that silently rots every time a migration lands, so it is deliberately
-- not restated as a number here. The DROP list below is the authority.
-- If you add a table in a migration, add it here in the SAME change --
-- and to preflight_check.sql and migration_status.sql, which have the
-- same exposure.
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
--   k9_runtime_feature_overrides / k9_runtime_override_audit
--                      Every currently-active runtime override high
--                      command has made to a feature flag or tuning value
--                      away from config.lua's own shipped default, plus
--                      the full "who changed what, from what, to what"
--                      trail for every override ever set or reset.
--                      Dropping the first silently reverts every live
--                      override to its config.lua default on the next
--                      restart -- a real behavior change, not just an
--                      audit-trail loss; the second is not recomputable
--                      from anything else, since it holds history the
--                      first table never does.
--
--   k9_tablet_theme / k9_tablet_theme_audit
--                      The current K9 command tablet theme (colors,
--                      density, header title) every connected player's
--                      tablet renders, and the full history of every
--                      theme change ever made as a complete snapshot per
--                      change. Dropping the first silently reverts every
--                      tablet to its hardcoded default theme on the next
--                      read.
--
--   k9_ped_assignments Every citizenid's currently-applied K9 ped model
--                      override, and the original model hash needed to
--                      restore their real model. Not recomputable.
--
--   k9_certification_tiers / k9_certification_tier_capabilities /
--   k9_certification_tier_audit
--                      The full high-command-editable certification tier
--                      catalog (trainee/certified/senior plus any custom
--                      tier added or renamed since), exactly which
--                      capabilities each tier currently grants, and the
--                      full history of every tier-catalog create/rename/
--                      reorder/delete ever made. Dropping the first two
--                      silently reverts EVERY tier to config.lua's own
--                      three defaults with NO capabilities granted at all
--                      on the next restart -- including un-deleting a
--                      tier high command deliberately tombstoned. A real
--                      behavior change to a live server, not merely an
--                      audit-trail loss. The audit table is not
--                      recomputable from the other two, which only ever
--                      hold current state.
--
-- ==> THE ONLY WAY BACK IS A BACKUP YOU TOOK BEFORE RUNNING THIS.
--     Run sql/rollback/backup_k9_tables.sh first. It takes seconds.
--     See OPERATOR_RUNBOOK.md §7 step 1. If you have not run it, stop
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
-- leaves every one of our tables intact and harmless on disk in case you
-- ever want them back. Just want permission grants specifically off?
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

    -- OWNED TABLE LIST -- named out in full, byte-identical, in FOUR places
    -- in this procedure: this COUNT, every branch of the dependency report
    -- below, the DRIFT CHECK branch of that same report, and the DROP list
    -- at the bottom. It is deliberately NOT swept from INFORMATION_SCHEMA by
    -- a bare `k9\_%` LIKE/REGEXP pattern instead of typed out repeatedly.
    -- Two real constraints make a blind pattern sweep unsafe for THIS
    -- specific list, unlike the stored-procedure sweep further down this
    -- same file (which safely IS a pattern sweep -- see its own header for
    -- why that one is safe and this one is not):
    --   1. DROP ORDER: if a future table here ever gains a real FK to
    --      another table in this same list, the DROP statements at the
    --      bottom would need to run in dependency order -- a sweep has no
    --      way to know that order, a hand-maintained list can be written in
    --      it. (No such FK exists between any two of our own tables today --
    --      every CREATE TABLE in install.sql/this resource's migrations
    --      declares zero FKs by design, see e.g. k9_certifications' own
    --      header -- but the DROP list is written defensively as if one
    --      could exist tomorrow, since retrofitting order into an existing
    --      DROP list under time pressure is worse than starting with it.)
    --   2. OTHER RESOURCES SHARE THE `k9_` PREFIX: this database can
    --      legitimately contain another K9 resource's own tables (the
    --      "STILL PRESENT" report below and backup_k9_tables.sh's own NOTE
    --      both call out `k9_units`-style tables as a real, expected case)
    --      -- a bare `k9\_%` sweep in the FK-blocker COUNT below would treat
    --      an FK into THAT resource's table as a reason to refuse OUR
    --      uninstall, which is wrong: we are not dropping that table, so a
    --      constraint pointing at it is none of our business.
    -- Because this list must stay hand-maintained, migration 0010's own
    -- three brand-new tables being absent from it for a time (fixed in this
    -- same change, verified by execution -- see this file's own git history/
    -- PR description) is exactly the failure mode this comment exists to
    -- keep from recurring a THIRD time. The DRIFT CHECK branch of the
    -- dependency report below is the backstop for the next time a migration
    -- is missed here anyway: it runs unconditionally, on every single
    -- invocation (armed or not), and names any `k9_%` table in this
    -- database that is not one of the fourteen named below, loudly, in the
    -- one report every operator already reads before doing anything else in
    -- this file.
    SELECT COUNT(*) INTO fk_blockers
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
    WHERE CONSTRAINT_SCHEMA = DATABASE()
      AND REFERENCED_TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships',
                                    'k9_progression','k9_permissions','k9_certification_specializations',
                                    'k9_runtime_feature_overrides','k9_runtime_override_audit',
                                    'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments',
                                    'k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit')
      AND TABLE_NAME NOT IN ('k9_certifications','k9_search_log','k9_partnerships',
                             'k9_progression','k9_permissions','k9_certification_specializations',
                             'k9_runtime_feature_overrides','k9_runtime_override_audit',
                             'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments',
                             'k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit');

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
          AND REFERENCED_TABLE_NAME REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit)$'
          AND TABLE_NAME NOT REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit)$'
        UNION ALL
        SELECT 2,
               'WILL BREAK - view reads one of our tables',
               TABLE_NAME,
               'This view keeps existing after the uninstall but errors with "references invalid table(s)" whenever anything uses it. Drop or rewrite it.'
        FROM INFORMATION_SCHEMA.VIEWS
        WHERE TABLE_SCHEMA = DATABASE()
          AND VIEW_DEFINITION REGEXP 'k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit)'
        UNION ALL
        SELECT 3,
               'WILL BE DELETED - trigger lives on one of our tables',
               TRIGGER_NAME,
               CONCAT('This trigger is attached to ', EVENT_OBJECT_TABLE,
                      ' and MySQL deletes it together with that table. Save its definition now if you want it back (SHOW CREATE TRIGGER `', TRIGGER_NAME, '`).')
        FROM INFORMATION_SCHEMA.TRIGGERS
        WHERE TRIGGER_SCHEMA = DATABASE()
          AND EVENT_OBJECT_TABLE REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit)$'
        UNION ALL
        SELECT 4,
               'WILL BREAK - stored routine reads one of our tables',
               ROUTINE_NAME,
               'This routine keeps existing after the uninstall but fails with "Table doesn''t exist" when called. Drop or rewrite it.'
        FROM INFORMATION_SCHEMA.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
          AND ROUTINE_NAME NOT LIKE 'qbx\_k9unit\_%'
          AND ROUTINE_DEFINITION REGEXP 'k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit)'
        UNION ALL
        -- DRIFT CHECK (db-schema foolproofing pass, 2026-08-25): reproduced by
        -- execution -- a real FK into `k9_certification_tiers` (a table this
        -- file's own FK-blocker COUNT above did not yet know about) was
        -- previously invisible to every check in this file, and an armed run
        -- printed `UNINSTALLED` without ever mentioning it. That specific gap
        -- is now closed (the three migration-0010 tables are named
        -- everywhere above), but the SAME class of gap -- a future migration
        -- adding a table here without also adding it to this file -- cannot
        -- be closed the same way in advance, because this list is
        -- deliberately hand-maintained, not a `k9\_%` pattern sweep (see the
        -- OWNED TABLE LIST comment above this procedure's DECLARE for why a
        -- pattern sweep is unsafe here specifically: DROP ordering and
        -- other-resources'-tables sharing the same prefix). This branch is
        -- the backstop instead: it runs UNCONDITIONALLY, every single time
        -- this file is run, armed or not, as part of the one report every
        -- operator already reads before anything else happens -- so the next
        -- missed table announces itself here instead of hiding the way
        -- migration 0010's three tables did. NOT a refusal/gate by itself
        -- (unlike the FK-blocker check above): a `k9_%` table this file does
        -- not recognize is EITHER a genuine drift bug in this file (report
        -- it) OR another K9 resource's own, unrelated table legitimately
        -- sharing this prefix (the "STILL PRESENT" report below and
        -- backup_k9_tables.sh's own NOTE both document that second case as
        -- real and expected) -- this file cannot tell those two apart from
        -- INFORMATION_SCHEMA alone, so it surfaces the fact loudly and lets
        -- a human decide, exactly like backup_k9_tables.sh's own drift guard
        -- and this file's own "STILL PRESENT" residue report already do,
        -- rather than guessing and either refusing a legitimate uninstall or
        -- silently accepting a real drift.
        SELECT 0,
               'UNRECOGNIZED - k9_* table not in this file''s own table list',
               TABLE_NAME,
               'This table is NOT one of the tables this file knows how to check or drop. If it belongs to qbx_k9unit, this file is out of date -- a migration added a table without this file being updated in the same change (see the OWNED TABLE LIST comment above) -- report it before arming this file. If it belongs to a DIFFERENT K9 resource sharing this database, this is expected and safe to ignore; this file will never touch it.'
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME LIKE 'k9\_%'
          AND TABLE_NAME NOT REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit)$'
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
        -- migration 0010 (db-schema foolproofing pass, 2026-08-25): these
        -- three were previously absent from this list entirely, which is
        -- why the FK-blocker gate above and the dependency report also had
        -- to be fixed in the SAME change -- see the OWNED TABLE LIST comment
        -- near this procedure's DECLARE for the full incident writeup. No FK
        -- exists between any two of our own tables (see that comment), so
        -- their position in this list carries no ordering requirement today.
        DROP TABLE IF EXISTS `k9_certification_tiers`;
        DROP TABLE IF EXISTS `k9_certification_tier_capabilities`;
        DROP TABLE IF EXISTS `k9_certification_tier_audit`;

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
