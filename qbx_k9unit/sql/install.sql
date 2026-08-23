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

-- =====================================================================
-- qbx_k9unit :: k9_search_log
--
-- Persistent audit log for the Phase 2 contraband-search action
-- (`qbx_k9unit:server:searchTarget`, phase2_notes/contraband_search_contract.md
-- §6 last bullet, SPEC.md §11.4 item 2's "STILL-OPEN" list). Added per
-- db-schema's Phase 2 review of the open question both of those raised:
-- does a search action warrant the same kind of durable accountability
-- trail `k9_certifications` already provides for grants/revokes?
--
-- db-schema recommendation (recorded here, not just in review notes):
-- YES -- log it, for a materially different reason than why
-- k9_certifications is persisted. k9_certifications persists a
-- *permission grant* -- current authorization state that must survive a
-- restart and be checked/revoked while the target is offline; its
-- `active` row IS the access-control mechanism, not just a record of
-- one. A search event is not that: nothing ever re-checks a past search
-- to decide whether a *future* search is allowed (rate limiting is
-- handled entirely by the in-memory cooldown tables in
-- server/search.lua, which is correct -- cooldowns are ephemeral by
-- nature and do not need to survive a restart). What tips this table
-- into "persist it" territory instead is the same real-world category
-- server/certifications.lua's header already names for its own audit
-- trail: in-fiction accountability for a disputed claim. "Did this K9
-- unit actually search my vehicle, or fabricate probable cause after
-- the fact" is a dispute a server admin has no way to resolve without a
-- durable record -- unlike a certification dispute, there is no
-- "current state" left behind anywhere (not in ox_inventory, not on the
-- vehicle, not on the player) for an admin to inspect after the fact and
-- reconstruct what happened. The DB-write cost is not a real concern:
-- writes here are gated behind the same human-paced action (an officer
-- manually initiating a search, already throttled by
-- `Config.SearchZones.searchCooldownMs` plus the per-source
-- cooldown/mutex in server/search.lua) that already rate-limits the far
-- more expensive ox_inventory round trip each row corresponds to --
-- this INSERT rides along a path that is already throttled, it does not
-- open a new hot path of its own.
--
-- Scope: only searches that reach a real inventory-read attempt are
-- logged (`result` = 'found' | 'clean' | 'search_failed', corresponding
-- to searchTarget's own step 11+ outcomes) -- NOT early rejections
-- ('feature_disabled', 'no_access', 'search_in_progress', 'on_cooldown',
-- 'too_far', 'invalid_target'). Those never touched the target's real
-- inventory and carry no forensic value for the "did a search actually
-- happen" question this table exists to answer; logging them would only
-- add noise and write volume for no accountability benefit. If a future
-- need emerges to also audit e.g. repeated 'too_far' probing as a
-- harassment signal, that is a deliberately separate decision, not
-- assumed by this table's current scope.
--
-- Shape deliberately differs from k9_certifications: this is a plain
-- append-only log (INSERT-only, never UPDATE, no `active` flag, no
-- revocation semantics) -- there is no "at most one X" invariant here
-- for a generated column + unique index to backstop, the way
-- `active_cert_key` backstops k9_certifications' "one active cert per
-- (citizenid, job)" rule. A resolved target being searched many times
-- over its lifetime is the entire point of a log, not a race to
-- prevent -- adding that kind of backstop here would be decoration, not
-- protection, so none is added.
--
-- No FK to a `players`/vehicle-ownership table, for the exact same
-- reason k9_certifications declares none (see that table's own comment
-- above): this resource's migration must not depend on qbx_core's
-- schema existing first, and a player-data reset workflow on another
-- resource's table must never be able to fail this table's constraints.
-- Relational integrity to qbx_core players / vehicle ownership is
-- enforced at the application layer, same convention as above.
--
-- Integration note for coder-backend (server/search.lua): write exactly
-- one row per completed search attempt, at the point in
-- HandleSearchTarget's validation-order body where the result is already
-- known (after the tier lookup for 'found'/'clean', or immediately upon
-- the pcall failure for 'search_failed') -- do NOT await this INSERT
-- inline before returning to the caller; fire it non-blockingly
-- (`MySQL.insert(...)` without `.await`) so a slow/contended DB write
-- never delays or risks the search callback's own response to the
-- requesting officer. Resolve `searcher_citizenid`/`searcher_job` via
-- `exports.qbx_core:GetPlayer(source).PlayerData` (same pattern
-- server/certifications.lua already uses for granter/target citizenid
-- lookups) -- prefer whatever job value `HasK9Access` already resolved
-- for this source over re-deriving it, per this resource's existing
-- "single source of truth" convention. Resolve `target_citizenid` for a
-- person search the same way, from the target's live server id
-- (`exports.qbx_core:GetPlayer(targetServerId).PlayerData.citizenid`),
-- not the raw ped netId.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_search_log` (
  `id`                 INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `searcher_citizenid` VARCHAR(50)  NOT NULL,                      -- qbx_core / QBCore citizenid convention; the certified officer who performed the search
  `searcher_job`       VARCHAR(50)  NOT NULL,                      -- department job at time of search (Config.Departments key) -- same rationale as k9_certifications.job
  `target_type`        ENUM('vehicle', 'person') NOT NULL,         -- mirrors searchTarget's own targetType argument; closed set, so ENUM (not VARCHAR) is the correct type
  `target_plate`       VARCHAR(15)  DEFAULT NULL,                  -- populated only when target_type = 'vehicle' (GetVehicleNumberPlateText, resolved server-side -- never client-supplied)
  `target_citizenid`   VARCHAR(50)  DEFAULT NULL,                  -- populated only when target_type = 'person' (resolved server-side from the target's live server id -- never client-supplied)
  `result`             ENUM('found', 'clean', 'search_failed') NOT NULL,
                                                                    -- 'found'/'clean' = a real inventory read completed (contrabandFound true/false);
                                                                    -- 'search_failed' = the inventory read itself errored/returned nil (searchTarget's
                                                                    -- reason = 'search_failed' path) -- kept as its own distinct value, never
                                                                    -- collapsed into 'clean', carrying phase2_notes/contraband_search_contract.md's
                                                                    -- explicit "never collapse search_failed into contrabandFound=false" requirement
                                                                    -- all the way down into the audit record itself.
  `total_weight`       INT UNSIGNED DEFAULT NULL,                  -- the real computed totalWeight for 'found'/'clean' (0 for 'clean'); NULL for
                                                                    -- 'search_failed', where no real number was ever computed -- NULL here means
                                                                    -- "unknown", not "zero", so a query summing this column can't silently
                                                                    -- misrepresent a failed check as a clean one.
  `alert_tier`         VARCHAR(32)  DEFAULT NULL,                  -- Config.ContrabandAlertTiers key looked up for 'found'/'clean' results
                                                                    -- (e.g. 'whine', 'aggressive_bark', 'clean'); NULL for 'search_failed'
  `searched_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),

  -- Officer-accountability query: "every search citizenid X has performed,
  -- most recent first" -- the other half of the dispute question this
  -- table exists for ("was this specific K9 unit even in a position to
  -- have searched anyone that shift").
  --   SELECT * FROM k9_search_log
  --   WHERE searcher_citizenid = ? ORDER BY searched_at DESC;
  KEY `idx_searcher_searched_at` (`searcher_citizenid`, `searched_at`),

  -- Target-accountability query, vehicle side -- the primary dispute
  -- query this table is built to answer: "was vehicle with plate X ever
  -- actually searched, by whom, when, and with what result".
  --   SELECT * FROM k9_search_log
  --   WHERE target_plate = ? ORDER BY searched_at DESC;
  KEY `idx_target_plate_searched_at` (`target_plate`, `searched_at`),

  -- Same query shape, person side.
  --   SELECT * FROM k9_search_log
  --   WHERE target_citizenid = ? ORDER BY searched_at DESC;
  KEY `idx_target_citizenid_searched_at` (`target_citizenid`, `searched_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
