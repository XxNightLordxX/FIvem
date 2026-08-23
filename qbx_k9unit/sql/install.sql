-- =====================================================================
-- qbx_k9unit :: k9_certifications
--
-- Source of truth for K9 handler certification grants/revocations.
-- See SPEC.md section 4.3 for full rationale. This table is an
-- append-mostly audit log: granting INSERTs a new row, revoking UPDATEs
-- the existing active row to active = 0 (never deletes), so the full
-- grant/revoke history per citizenid+job is always reconstructable —
-- including revocations issued while the target is offline.
--
-- db-schema review notes (per SPEC.md 4.3 / 9.1):
--   * citizenid/job/granted_by/revoked_by use the standard qbx_core /
--     QBCore VARCHAR(50) citizenid convention, matched consistently
--     across every citizenid-shaped column in this table.
--   * No FK to a `players` table is declared here on purpose: qbx_core's
--     player table does not live in this repo/resource, and this
--     resource's own migration should not have a hard install-order
--     dependency on qbx_core's schema existing first, nor should a
--     player-data reset/delete workflow on another resource's table be
--     able to fail this table's constraints. Relational integrity to
--     qbx_core players is enforced at the application layer (same
--     convention used by other standalone oxmysql resources).
--   * Two purpose-built indexes below, plus a generated-column unique
--     constraint that gives the "at most one active row per
--     (citizenid, job)" invariant a real DB-level backstop instead of
--     relying on application logic alone — see the column/index
--     comments for exact query patterns each one supports.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,                          -- qbx_core / QBCore citizenid convention
  `job`              VARCHAR(50)  NOT NULL,                          -- department job name at grant time (Config.Departments key)
  `granted_by`       VARCHAR(50)  NOT NULL,                          -- citizenid of the certifying officer
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,                      -- citizenid of the revoking officer; NULL until revoked.
                                                                      -- Per SPEC.md 4.4, may also hold the non-citizenid
                                                                      -- sentinel 'system:job_change' when auto-revoked by
                                                                      -- a department firing rather than a manual revoke.
                                                                      -- No FK/format constraint on this column, so no
                                                                      -- migration change is needed to support the sentinel;
                                                                      -- coder-backend's audit-reading logic should just
                                                                      -- expect it as a valid non-citizenid value.
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,                -- 1 = currently grants access, 0 = historical/revoked row

  -- Generated helper column (derived only, never written directly by
  -- app code): NULL for every inactive/revoked row, and
  -- `citizenid::job` for an active row. MySQL/MariaDB unique indexes
  -- treat every NULL as a distinct value (never collides with another
  -- NULL), so a UNIQUE index on this column lets the database itself
  -- reject a second concurrent INSERT that would create two active
  -- rows for the same (citizenid, job) pair, without changing the
  -- semantics of `active` (still a plain NOT NULL 0/1 flag) and without
  -- ever deleting/blocking historical audit rows.
  `active_cert_key`  VARCHAR(105)
                       GENERATED ALWAYS AS (
                         CASE WHEN `active` = 1
                              THEN CONCAT(`citizenid`, '::', `job`)
                              ELSE NULL
                         END
                       ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- Hot-path index: "does citizenid X hold an active cert for job Y".
  -- Checked on player load, job change, grant, and revoke (per
  -- SPEC.md 4.3 the result is cached in memory after that, so this
  -- index is NOT hit on every menu-open/spawn request — only on the
  -- less-frequent events that (re)populate the cache).
  --   SELECT id FROM k9_certifications
  --   WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1;
  -- citizenid leads the index so it also serves "full cert history for
  -- citizenid X across all jobs" (WHERE citizenid = ?) as a prefix scan.
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),

  -- Admin-path index: "list all certified handlers in department X"
  -- (SPEC.md 4.3 rationale). idx_citizen_job_active above cannot serve
  -- this efficiently because job is not its leading column; this index
  -- makes it an index seek instead of a full table scan:
  --   SELECT citizenid, granted_by, granted_at FROM k9_certifications
  --   WHERE job = ? AND active = 1;
  KEY `idx_job_active` (`job`, `active`),

  -- DB-level backstop for the app-enforced "one active row per
  -- (citizenid, job)" invariant. Closes the check-then-insert race
  -- window (e.g. two near-simultaneous grant requests for the same
  -- target/job) that pure application-level enforcement cannot fully
  -- close on its own. coder-backend: on the grant INSERT, treat a
  -- duplicate-key error on this constraint (MySQL/MariaDB error 1062)
  -- identically to the normal pre-check "already certified" no-op —
  -- it means another request won the race, not a real failure.
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
