--[[
    qbx_k9unit/server/admin.lua

    In-game admin/audit surface over the tables this resource already
    writes but, until now, only ever exposed as a raw SQL query an admin ran
    by hand (README.md's own documented "admin listing" queries;
    DEVELOPER_REFERENCE.md Part B top-3 item 2 / §9 -- formerly COMPLEMENTARY_FEATURES.md,
    merged 2026-08-25): `k9_certifications`
    (server/certifications.lua), `k9_partnerships` (server/partnership.lua),
    `k9_search_log` (server/search.lua), `k9_progression`
    (server/progression.lua). THIS FILE COMPUTES NOTHING NEW — it is a
    read-only, server-authoritative wrapper over query shapes sql/install.sql
    already documents and already indexes for. It never INSERTs/UPDATEs/
    DELETEs anything.

    COVERAGE RE-CHECK (this pass): three things landed under this file
    since its own last review — K9Inventory.allowedItems enforcement
    (server/inventory.lua), new wellbeing state (server/wellbeing.lua), and
    six outbound `qbx_k9unit:events:*` dispatch events — plus
    `k9_partnerships` grew the `tenure_bonus_tier_granted` column
    (server/tenure.lua). Checked each against this file's own "read-only
    wrapper over a real table" scope:
      - `k9_progression` (server/progression.lua's XP/tier persistence) was
        a genuine, undocumented GAP: a real table this resource has
        written to since Phase 4, with no query surface here at all — the
        same class of gap this file's own brief warns is "worse than one
        that admits its scope." CLOSED this pass: `/k9auditxp` below.
      - `tenure_bonus_tier_granted` needs no new command: it is a column on
        `k9_partnerships`, already fully returned by `/k9auditpartner`
        (QueryPartnershipHistory selects every column via its own `columns`
        local, which already includes it) — an admin auditing a
        partnership's history sees its current tenure-tier progress for
        free, no code change required.
      - The six `qbx_k9unit:events:*` events are fire-and-forget
        `TriggerEvent` dispatches, not a persisted store — there is no
        table row to query that isn't already one of `k9_certifications`
        (certificationGranted/Revoked), `k9_partnerships`
        (partnershipEstablished/Ended), `k9_search_log`
        (searchCompleted), or, as of this pass, `k9_progression`
        (xpTierReached). Nothing further to add here; the underlying data
        each event reports on is fully covered once `/k9auditxp` lands.
      - K9Inventory.allowedItems enforcement (server/inventory.lua) rejects
        a mutation against ox_inventory's own stash contents — it writes
        no row to any `k9_*` table this file (or this resource) owns.
        ox_inventory's own stash/logging is that system's audit surface,
        not this resource's; out of this file's scope by the same
        "wraps this resource's own tables only" boundary that already
        excludes qbx_core/ox_inventory's own schemas entirely. Documented
        here, not silently skipped.
      - Wellbeing (server/wellbeing.lua) state is in-memory only (that
        file's own header — no `k9_wellbeing`/similar table exists in
        sql/install.sql) — there is no durable row for a read-only audit
        surface to wrap. Nothing to add unless/until that state is ever
        persisted.

    COVERAGE RE-CHECK (this pass, take 2): a schema review flagged
    `idx_job_active` (`job`, `active`) on `k9_certifications` — sql/
    install.sql's own comment on that index names the exact query it
    exists to serve, "list all certified handlers in department X" — as
    specified and indexed for but never queried by any code in this
    resource. Confirmed independently before building on that premise: a
    repo-wide search for `WHERE job` / `idx_job_active` found the CREATE
    TABLE's own KEY declaration and doc comment, and nothing else — every
    query this file already had (QueryCertificationHistory) filters on
    `citizenid`, using `idx_citizen_job_active` as a prefix scan, never
    `idx_job_active`. The index has been paying its write-amplification
    cost on every INSERT/UPDATE to `k9_certifications` since it was added,
    for a read path nothing exercised. CLOSED this pass: `/k9auditdept`
    below, whose query is sql/install.sql's own documented `idx_job_active`
    shape verbatim (`SELECT citizenid, granted_by, granted_at FROM
    k9_certifications WHERE job = ? AND active = 1`), plus the same
    ORDER BY/LIMIT discipline every other query in this file already
    follows.

    ======================================================================
    ACCESS MODEL — REVISED (project-owner-directed design change, this
    pass): this surface was originally the first ACE-gated action in this
    resource (DEVELOPER_REFERENCE.md Part B §9's own "precedent-setting choice,
    not a blocker" flag), on the reasoning that "can this connected
    principal read the search/cert/partnership audit trail" is
    SERVER-OPERATOR tooling, unrelated to department membership or K9
    certification. That reasoning was sound for what it covered, but the
    project owner's own correction is sound too: ACE is granted from the
    server console or a permissions file — a SERVER-ADMIN trust boundary —
    but this is a POLICE resource, and the people who should be trusted to
    review K9 certification/partnership/search history are SENIOR OFFICERS
    IN-GAME, not whoever happens to have console access. Every OTHER gated
    action in this resource (HasK9Access, IsEligibleCertifier,
    CheckPartnershipEligibility) already uses a job/grade threshold for
    exactly this kind of authority question; this file now does too.

    GATED ON POLICE JOB RANK, mirroring server/certifications.lua's
    IsEligibleCertifier EXACTLY — read that function before touching
    IsAuthorizedAdmin below — including both of its hardening properties,
    carried over here from day one rather than waiting to rediscover them:
      - `job.isboss` ALWAYS qualifies, regardless of the configured numeric
        threshold. A department boss must be able to audit their own
        department at least as freely as they can already certify/revoke
        in it.
      - `job.grade.level` is explicitly type-checked (`type(...) ==
        'number'`) before ever reaching the `>=` comparison — never merely
        checked for truthiness/non-nil. A job object shaped differently
        than qbx_core's documented `{ name, level: number }` schema (a
        non-number `level`) must FAIL CLOSED (deny) here, never throw an
        uncaught "attempt to compare number with <type>" error on this
        authorization path — the exact class of bug coder-security already
        found and fixed twice in server/certifications.lua
        (IsEligibleCertifier's own certifierGrade comparison, and
        HasK9Access's autoAccessGrade branch).
    Threshold: `Config.Departments[job.name].auditGrade` — a NEW per-
    department field (config.lua's to add; not this file's). Deliberately
    a SEPARATE field from `certifierGrade`, not a reuse of it: auditing is
    a read-only oversight action over a genuinely privacy-sensitive dataset
    (who searched whom), and a server owner may reasonably want that bar
    set independently of who is trusted to grant/revoke certifications —
    e.g. restricting audit to command staff while certifierGrade stays at
    "K9 training sergeant," or the reverse. Both currently ship with the
    same default per department (see this file's own "CONFIG THIS FILE
    ASSUMES EXISTS" section below) purely so day-one behavior doesn't
    surprise an operator who hasn't reconsidered the split yet — nothing
    about the code ties the two together.

    NOT SCOPED TO THE CALLER'S OWN DEPARTMENT: passing IsAuthorizedAdmin at
    all (senior enough in ANY configured Config.Departments job) authorizes
    every command in this file, including `/k9auditdept` against a
    DIFFERENT department's roster than the caller's own. This mirrors an
    existing precedent already established in this resource —
    GrantCertification explicitly allows cross-department certification
    (§4.2.3: "this only requires the target be in *some* configured
    department, not the SAME one as the granter") — rather than inventing a
    new, narrower same-department-only rule found nowhere else in this
    codebase. Flagged for coder-security/project-owner to confirm or
    override if audit access should in fact be department-scoped.

    CONSOLE (source == 0) IS STILL NOT TRUSTED BY DEFAULT — opt-in via the
    SAME Config.AdminAudit.TrustConsole flag this file already had, kept
    UNCHANGED by this rewrite, and for a STRONGER reason than before: a
    job-rank check has NOTHING to compare for source == 0 at all (the
    console has no Player/PlayerData/job — Config.Departments[nil] is
    simply nil, not a crash, but it can never be a truthy match either).
    Without this explicit, separately-reasoned bypass, console access would
    not merely default off, it would be STRUCTURALLY IMPOSSIBLE under a
    job-rank gate — silently removing a documented operator capability as a
    side effect of swapping the authorization mechanism, not a decision
    anyone actually made. The original three-producer rationale for
    defaulting this OFF is UNCHANGED by this rewrite — see
    IsAuthorizedAdmin's own comment below for the full writeup, preserved
    verbatim from before this pass. A server owner who wants a genuine
    console operator to run these commands still sets TrustConsole = true
    and still accepts that all three producers (console, RCON, any
    co-located resource via ExecuteCommand) gain access, exactly as before.

    ACE IS NO LONGER USED BY THIS FILE AT ALL, as of this pass.
    `Config.AdminAudit.AcePermission` is now DEAD CONFIG — see this pass's
    hand-off note to the config owner: recommended for removal, not merely
    left unread by this file. `IsPlayerAceAllowed` itself remains a
    confirmed apiset:server native (`curl`-verified against
    ext/native-decls/IsPlayerAceAllowed.md this pass) and is still used
    elsewhere in this resource (server/combat.lua's FlagNonCompliance
    staff-notification path, and, until later the
    same day, server/bonetool.lua. NOTE: bonetool.lua has SINCE been
    converted off ACE too, so any claim here that it was "deliberately left
    ACE-gated" is stale. It now gates on `job.isboss` only -- a deliberately
    stricter principal than this file's `auditGrade`, because read-only audit
    access must not also confer a prop-spawning dev tool -- plus a replicated
    convar an operator must set on purpose. server/combat.lua's
    FlagNonCompliance staff-notification path is now the only live
    IsPlayerAceAllowed call site left in this resource) — nothing about this rewrite
    calls that native's own correctness into question, this file simply no
    longer has a reason to call it.
    ======================================================================

    SQL SAFETY — read before touching any query function below:
      - This file constructs 9 distinct hardcoded SQL string templates in
        total (COVERAGE RE-CHECK, this pass: was 8 —
        QueryCertificationHistory:1, QueryPartnershipHistory:2,
        QuerySearchLogBy{Officer,Plate,Person}/QuerySearchLogRecent:4,
        QueryProgressionSnapshot:1, QueryDepartmentRoster:1 (new,
        `/k9auditdept`) — verified by
        re-reading every `:format(`/literal-string call site below, not
        re-counted from memory). The security property that matters (every
        one of them is 100% hardcoded text, never built from a
        caller-controlled fragment) holds regardless of the exact count,
        but the count itself should be accurate.
      - Every WHERE-clause value (citizenid, plate) is bound via a `?`
        oxmysql placeholder — NEVER string-concatenated. No caller-supplied
        string ever reaches raw SQL text.
      - The one thing embedded via string.format rather than bound as a
        placeholder is each query's row LIMIT — and that value, by the time
        it reaches string.format, is a plain Lua integer already produced
        by ClampLimit below (clamped into [1, HARD_MAX_RESULTS]), never a
        value copied verbatim from a command's `args`. DISCLOSED REASONING:
        oxmysql's prepared-statement binding of a `LIMIT ?` placeholder
        specifically (as opposed to WHERE/VALUES placeholders, which is all
        every other query in this codebase ever binds — search.lua,
        certifications.lua, partnership.lua) could not be independently
        confirmed against a live oxmysql/mysql2 install in this sandbox,
        and no existing file in this resource establishes a precedent to
        confirm against either. Embedding an already-clamped-server-side
        integer is not a SQL-injection vector (there is no
        attacker-reachable string in that position — only a number this
        file's own clamping code produced) and sidesteps that unconfirmed
        compatibility question entirely.
      - `/k9auditsearch`'s `mode` argument is checked against a fixed
        whitelist table (VALID_SEARCH_LOG_MODES) and used ONLY to select
        which of four separately hardcoded query functions runs — never
        concatenated into a query, never used to select a column/table name
        dynamically.
      - Every query orders by a plain integer column (`id` — AUTO_INCREMENT,
        strictly increasing with insertion order) or by a column MySQL
        itself sorts server-side (`granted_at`/`searched_at`, via a
        hardcoded ORDER BY clause) — this file never parses or compares a
        DATETIME value in Lua. The one place two separately-fetched row
        sets must be merged (QueryPartnershipHistory below, one query per
        unique index) sorts by `id` for exactly this reason: whether
        oxmysql/mysql2 marshals a MySQL DATETIME into Lua as a plain string,
        a table, or something else was never independently confirmed in
        this sandbox, so comparing `id` (always a plain Lua number,
        unambiguous either way) avoids the question rather than assuming an
        answer.
      - Every result set is bounded. HARD_MAX_RESULTS below is enforced at
        resource start regardless of what Config.AdminAudit.MaxResults.* is
        configured to — an unbounded (or absurdly large) LIMIT against
        k9_search_log on a busy server is both a footgun and a DoS vector
        against this resource's own database, exactly the failure mode this
        task's brief names directly.

    ======================================================================
    COMMAND SURFACE (all five commands gated on
    Config.Features.AdminAuditCommands AT REGISTRATION TIME — if that flag
    is not `true`, none of these commands exist at all, not merely a
    runtime no-op; see the onResourceStart block at the bottom of this
    file):

    1. '/k9auditcert <citizenid>'
       Full certification grant/revoke history for one citizenid, across
       every department, most recently GRANTED first. Uses
       idx_citizen_job_active's leading `citizenid` column as a prefix scan
       — sql/install.sql's own comment on that index names this exact
       "full cert history for citizenid X across all jobs" query shape.

    2. '/k9auditpartner <citizenid>'
       Full partnership history (active and historical) for one citizenid,
       in EITHER role. Two separate equality queries — one per unique index
       (idx_k9_citizenid_active / idx_handler_citizenid_active) — merged
       and re-sorted here rather than one OR'd query, so each half of the
       work hits its own purpose-built index instead of forcing an
       index-merge access plan on a single OR'd WHERE clause.

    3. '/k9auditsearch <mode> [value] [limit]'
       mode ∈ {'officer', 'plate', 'person', 'recent'} — STRICT WHITELIST,
       see VALID_SEARCH_LOG_MODES:
         officer <citizenid> [limit] — searches PERFORMED BY citizenid,
           most recent first (idx_searcher_searched_at — the exact query
           shape sql/install.sql's own comment on that index names).
         plate <plate> [limit]       — searches OF vehicle plate, most
           recent first (idx_target_plate_searched_at, same exact-shape
           reuse).
         person <citizenid> [limit]  — searches OF person citizenid, most
           recent first (idx_target_citizenid_searched_at, same exact-shape
           reuse).
         recent [limit]              — the N most recently logged searches
           of ANY kind, ordered by `id DESC` (NOT `searched_at`) with no
           WHERE clause at all — reading the last N rows off the end of
           InnoDB's own clustered primary-key index is cheap and needs no
           dedicated index of its own, honoring this task's explicit
           instruction to use the three existing purpose-built indexes
           rather than add a new one for a "recent window" query
           sql/install.sql's own header never anticipated.

    4. '/k9auditxp <citizenid>'
       Current persisted XP total for one citizenid, from `k9_progression`
       (server/progression.lua) — added this pass, see this file's own
       header "COVERAGE RE-CHECK" section for why. `citizenid` is that
       table's own PRIMARY KEY (sql/install.sql), so this is a single-row
       point lookup: no `[limit]` argument, no ORDER BY, and no
       Config.AdminAudit.MaxResults.* entry needed for it (there is never
       more than one row to bound). Deliberately reports the raw `xp`
       integer only, NOT a derived tier — this file's own "COMPUTES
       NOTHING NEW" rule (see this header's opening paragraph) means it
       does not re-implement server/progression.lua's `ResolveTier`
       threshold walk (a `local` function, not exposed as a
       resource-global) here as a second, driftable copy; an admin can
       compare the reported total against Config.XPTiers directly.

    5. '/k9auditdept <job> [limit]'
       Current ACTIVE certified-handler roster for one department (a
       Config.Departments key), most recently GRANTED first. Added this
       pass — see this file's header "COVERAGE RE-CHECK (this pass, take
       2)" section above for why. Uses `idx_job_active` — the exact query
       shape sql/install.sql's own comment on that index names ("list all
       certified handlers in department X").

       ARGUMENT SHAPE: a department name, validated against
       `Config.Departments` the same way server/certifications.lua's
       `/k9decertifyoffline` validates its own `job` argument
       (`if not Config.Departments[job] then ... end`, that file's own
       `RevokeCertificationOffline`) — reusing an existing, already-vetted
       validation shape rather than inventing a new one for the same kind
       of argument. A department name that is not a configured
       `Config.Departments` key is rejected outright as `invalid_args`,
       the same posture `IsValidCitizenId`/`NormalizePlateArg` already
       take for this file's other string arguments — a typo'd/unconfigured
       job could never have a matching row, so failing fast beats a
       silent, confusing "no results found."

       ACTIVE-ONLY, NOT FULL HISTORY: this command reports only
       `active = 1` rows, never revoked ones. Three independent reasons,
       not just "the index says so": (1) `idx_job_active`'s own
       sql/install.sql doc comment names this exact query as "list all
       certified handlers in department X" — a present-tense ROSTER
       question, not a historical one; (2) `/k9auditcert` above already
       covers full grant/revoke history (including every department) for
       one citizenid — a second, department-scoped full-history view
       would duplicate that command's job rather than serve the roster
       use case this index exists for; (3) a revoked-history view keyed
       by department, unlike `/k9auditcert`'s per-citizenid view, would
       accumulate EVERY citizenid ever certified-then-revoked in that
       department with no natural per-target scope to bound it — the
       roster framing keeps this a small, bounded, genuinely useful
       result set instead.

       RESULT CAP: reuses `Config.AdminAudit.MaxResults.Certifications`
       (still clamped into `[1, HARD_MAX_RESULTS]` by ClampLimit either
       way) rather than a new dedicated config key — this queries the
       exact same `k9_certifications` table `/k9auditcert` already caps
       under that same key, and a roster is naturally smaller than a
       full per-citizenid history in the common case (one row per
       currently-certified handler, not one row per grant/revoke event
       ever recorded), so the existing per-table cap is the right unit,
       not a new one.

       DISPLAY BOUNDARY: reuses the exact same three columns
       `idx_job_active`'s own doc comment names — `citizenid, granted_by,
       granted_at` — nothing wider. Deliberately does NOT also return
       `revoked_by`/`revoked_at` (always NULL for an active-only row
       anyway) or any column `/k9auditcert` does not already expose for
       the very same table; this command widens WHO the query is scoped
       by (department instead of citizenid), never WHAT is disclosed.
    ======================================================================

    CALLBACK SURFACE (this pass) — every command above only ever formats
    its query results into a chat toast or a console print; there was, until
    now, no way for the tablet (or any other in-game consumer) to reach the
    RAW rows themselves. Five `lib.callback.register` endpoints now mirror
    the five commands one-to-one, each a thin wrapper around the EXACT SAME
    Query* function (therefore the exact same K9Store.* accessor) its
    command counterpart already calls, gated by the EXACT SAME
    IsAuthorizedAdmin(source) call, the EXACT SAME shared AuditCooldown
    budget, and the EXACT SAME ClampLimit bound — registered inside the same
    onResourceStart block, behind the same Config.Features.AdminAuditCommands
    gate, so a callback can never be reached more easily than the command it
    mirrors. See the full "CALLBACK SURFACE" comment block immediately above
    the five `lib.callback.register(...)` calls near the end of this file
    (inside onResourceStart, right after the five RegisterCommand blocks)
    for the complete argument/return-shape contract:
      qbx_k9unit:server:tabletAuditCert    (source, citizenid, limit)
      qbx_k9unit:server:tabletAuditPartner (source, citizenid, limit)
      qbx_k9unit:server:tabletAuditSearch  (source, mode, value, limit)
      qbx_k9unit:server:tabletAuditXp      (source, citizenid)
      qbx_k9unit:server:tabletAuditDept    (source, job, limit)
    Every one returns `{ ok = true, rows = <table>, label = <string> }` on
    success or `{ ok = false, error = 'not_authorized'|'rate_limited'|'invalid_args', message = string? }`
    otherwise — never a formatted string. No NUI callback and no
    client/tablet.lua change are part of this pass; this is the
    server-side contract a follow-up tablet screen builds against.

    RATE LIMITING: one shared NewCooldown() instance (server/cooldowns.lua
    — per this task's explicit "use the shared constructors" convention)
    across all five commands, keyed by the CALLER's own source, mirroring
    server/certifications.lua's CertifyActionCooldown shape (one cooldown
    covering several related actions, not one per command). This is a
    DB-load/spam guard, not an authorization boundary — nothing here
    mutates state or costs an ox_inventory round trip the way certify/
    search does, but k9_search_log grows without bound on a busy server and
    a scripted polling loop against it is real, avoidable DB load.

    AUDIT-OF-THE-AUDIT: every invocation of every command below — allowed,
    denied, rate-limited, or malformed — is logged to the server console
    via LogAuditInvocation. An audit surface over a genuine
    privacy-sensitive dataset (who searched whom, when) that nobody can
    itself audit is exactly the gap this task calls out by name. This is
    deliberately a `print()`, not a new DB table: a persisted "audit of
    audits" table would be a real schema change, and config.lua/
    fxmanifest.lua/sql/install.sql are explicitly out of this file's scope
    for this pass — flagged as a reasonable follow-up for db-schema/
    coder-architect to weigh in on, not silently skipped.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `NewCooldown`, resource-global from
      server/cooldowns.lua — must load after that file in fxmanifest.lua's
      server_scripts, same requirement every other consumer of it already
      states.
    - THIS FILE does NOT call HasK9Access / IsConfiguredK9Model /
      GetActivePartnerCitizenId / IsActivePartnerOf or any other
      resource-global from server/certifications.lua or
      server/partnership.lua — deliberately: this surface's authorization
      is pure ACE, unrelated to K9 certification or department membership
      (see ACCESS MODEL above). No load-order dependency on either file.
    - THIS FILE exposes no resource-global functions of its own — nothing
      else in this resource needs to call into an admin/audit query.
    - THIS FILE performs SELECT-only queries against k9_certifications,
      k9_partnerships, k9_search_log, and k9_progression — read
      sql/install.sql's header comments on all four tables (index
      rationale, exact column shapes) before changing any query below.
    - THIS FILE calls `lib.callback.register` (ox_lib, CALLBACK SURFACE
      section above) — same soft dependency every other `lib.callback.
      register`/`locale()` call site in this resource already has on
      ox_lib being started first; no NEW load-order requirement this file
      did not already have via its own pre-existing `locale(...)` calls.
    ======================================================================

    CONFIG THIS FILE ASSUMES EXISTS — NOT owned by this file for this task
    (coder-backend does not own config.lua/fxmanifest.lua/.luacheckrc here;
    see this pass's hand-off note for the exact blocks needed). A missing
    Config.Features.AdminAuditCommands is treated as `false` (feature
    disabled, no crash) by the guard below — but if that flag IS `true`,
    Config.AdminAudit must exist with the exact shape asserted in the
    onResourceStart block below, or this resource will refuse to finish
    starting (fail loudly on a genuine misconfiguration, once the operator
    has actually opted in — never silently on an unrelated server that
    hasn't touched this feature at all):
      Config.Features.AdminAuditCommands  : boolean (new; default false)
      Config.AdminAudit.TrustConsole      : boolean (existing; default false — see ACCESS MODEL above for why this is unchanged, not removed, by the ACE->job-rank rewrite)
      Config.AdminAudit.CommandCooldownMs : number  (existing; shared per-source cooldown, ms)
      Config.AdminAudit.MaxResults.Certifications : integer, 1..100
      Config.AdminAudit.MaxResults.Partnerships   : integer, 1..100
      Config.AdminAudit.MaxResults.SearchLog      : integer, 1..100
      Config.Departments[job].auditGrade  : number (NEW this pass, per department —
                                            see ACCESS MODEL above; job.grade.level
                                            required to run any command in this file,
                                            job.isboss always qualifies too, same
                                            shape as Config.Departments[job].certifierGrade
                                            in server/certifications.lua). Recommended
                                            defaults matching this pass's report to the
                                            config owner: police=4, sheriff=3, bcso=3
                                            (identical to each department's own
                                            certifierGrade, day one — see rationale above).

      Config.AdminAudit.AcePermission is now DEAD CONFIG — no longer read by
      this file as of this pass (see ACCESS MODEL above). Recommended for
      removal from config.lua, not merely left in place unread.
]]

-- Hard ceiling enforced regardless of what Config.AdminAudit.MaxResults.*
-- is configured to — same "config is a tunable, not a bypass" posture as
-- server/search.lua's own Config.SearchZones.alertBroadcastRadius <= 200.0
-- assert. An admin audit query is still a real query against a
-- potentially large, ever-growing table (k9_search_log) — an unbounded or
-- absurdly large LIMIT is both a footgun and a DoS vector against this
-- resource's own database, the exact failure mode this task's brief names
-- directly.
local HARD_MAX_RESULTS = 100

-- Floor enforced on Config.AdminAudit.CommandCooldownMs for the same
-- reason server/cooldowns.lua's own IsOnCooldown FAILS CLOSED on a
-- non-positive threshold (treats it as "on cooldown forever," never as "no
-- cooldown") — a misconfigured 0/negative value here would not open a gap,
-- it would silently brick this entire command surface for every caller
-- including legitimate admins. Worth failing loudly on at resource start
-- rather than discovering in the field.
local MIN_COMMAND_COOLDOWN_MS = 250

-- How many formatted rows are batched into a single ox_lib toast — kept
-- small so one command's results don't render as one unreadable wall of
-- text, and so multiple short toasts don't spam the screen either.
local ROWS_PER_NOTIFY_CHUNK = 5

-- Fixed whitelist of valid `/k9auditsearch` modes — see this file's header
-- "SQL SAFETY" section for why this is a strict table lookup, never a
-- value that reaches SQL text directly.
local VALID_SEARCH_LOG_MODES = { officer = true, plate = true, person = true, recent = true }

-- DEVELOPER_REFERENCE.md item 1 convention (server/cooldowns.lua): shared
-- constructor, not a hand-rolled table. One instance covers all three
-- commands in this file, keyed by the CALLING admin's own source — see
-- this file's header "RATE LIMITING" section. No default threshold baked
-- in (mirrors server/search.lua's TargetSearchCooldown shape); the
-- threshold is supplied explicitly at every .Consume() call from
-- Config.AdminAudit.CommandCooldownMs.
local AuditCooldown = NewCooldown()
AuditCooldown.RegisterPlayerDropped()

--- Sends an ox_lib notification to a specific player, using this file's own
--- 'K9 Unit — Admin Audit' title. Deliberately kept as a thin LOCAL wrapper
--- (same name, shadowing the resource-global on purpose) rather than
--- flattened onto server/notify.lua's shared implementation directly at
--- every call site below — see that file's header "TWO CALL SITES
--- DELIBERATELY KEPT AS LOCAL WRAPPERS" section for the full reasoning
--- (this title is a deliberate, player-visible per-subsystem difference,
--- not an accident, and keeping it here in one place avoids duplicating the
--- title string at all 11 of this file's own call sites instead). The
--- explicit `_G.` prefix below is required, not decorative: a bare
--- `NotifyPlayer(...)` call inside this same-named local function's own
--- body would resolve to this local (already in scope inside its own body)
--- and recurse forever instead of reaching the shared global. NEVER called
--- with `target == 0` (server console) by any call site in this file —
--- console has no client to notify; see each command handler's own console
--- branch for how it surfaces results instead (a plain print()).
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    _G.NotifyPlayer(target, description, notifyType, 'K9 Unit — Admin Audit')
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- 4-step "first match wins" resolution, steps 2-4 (step 1 -- this
-- feature's own Config.Features.AdminAuditCommands flag -- is already
-- checked by this file's own COMMAND REGISTRATION gate further down, at
-- resource-start time, before any command handler IsAuthorizedAdmin below
-- guards can ever be registered at all). Mirrors
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId shape
-- exactly -- see that function's own doc comment for the full reasoning;
-- kept as this file's own tiny local copy rather than a shared export,
-- matching this resource's established "each file keeps its own tiny copy
-- of a genuinely small, self-contained check" convention
-- (server/permissions.lua's IsDuplicateKeyError doc comment names the same
-- precedent explicitly).
--
-- Called ONLY from inside IsAuthorizedAdmin below, and ONLY once every
-- OTHER (legacy auditGrade rank / job.isboss / high-command / k9.audit
-- capability-grant) qualification has ALREADY independently passed -- see
-- that function's own restructure below for exactly where. An explicit
-- per-person BLOCK or a missing per-person GRANT can therefore only ever
-- NARROW who this file's commands allow, never widen it: holding
-- 'feature.AdminAuditCommands' does not, by itself, ever authorize someone
-- who fails every other check IsAuthorizedAdmin already performs -- purely
-- additive in the opposite direction from every OTHER bypass in that
-- function (isboss/k9.audit-grant/high-command all WIDEN access; this
-- narrows it), exactly matching config.lua's own documented Config.FeatureControl
-- precedence ("global off... a block... can never switch on something...").
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsAdminFeaturePermittedForCitizenId(citizenid)
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.AdminAuditCommands') == true then
        return false -- step 2: an explicit block always wins, even over an otherwise-qualifying rank/high-command/capability-grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.AdminAuditCommands == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.AdminAuditCommands') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Server-authoritative authorization check for every command in this
--- file. See this file's header "ACCESS MODEL" section for the full
--- reasoning on both the ACE->job-rank rewrite and the console
--- (source == 0) carve-out.
---
--- PER-PERSON FEATURE CONTROL (this pass, coder-security -- see
--- IsAdminFeaturePermittedForCitizenId immediately above for the full
--- contract): every path below that used to `return true` directly now
--- routes through that check first, keyed to the caller's OWN
--- server-resolved citizenid -- never a client claim, never the console's
--- (source == 0 has no citizenid and is a distinct trust boundary --
--- Config.AdminAudit.TrustConsole -- untouched by this addition, see that
--- branch below). A block/missing-grant can therefore revoke a
--- specific officer's audit access WITHOUT touching their job grade, and
--- takes effect on their VERY NEXT command invocation (this function is
--- re-checked from scratch on every one of this file's five command
--- handlers, never cached) -- never gated behind a restart, matching this
--- resource's "gate at registration, not just inside the handler" rule
--- for the FEATURE flag itself while keeping the PER-PERSON layer fully
--- live.
---
--- JOB-RANK CHECK (this pass, project-owner-directed): mirrors
--- server/certifications.lua's IsEligibleCertifier exactly — same
--- Config.Departments[job.name] membership requirement, same job.isboss
--- short-circuit, same explicit `type(job.grade.level) == 'number'` guard
--- before ever comparing it, applied against a NEW, separate threshold
--- (Config.Departments[job.name].auditGrade, not certifierGrade — see
--- header for why these are deliberately independent fields). FAILS CLOSED
--- on every path where a job cannot be fully resolved: no Player, no
--- PlayerData, no job, job.name not a configured department, no
--- dept.auditGrade (or a non-number one), no job.grade, or a non-number
--- job.grade.level all return false — none of them ever reach the `>=`
--- comparison, so none of them can throw. `job.isboss` is the only path
--- that returns true without inspecting job.grade at all, matching
--- IsEligibleCertifier's own documented behavior.
---
--- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
--- project-owner-directed this pass): a caller for whom IsHighCommand(source)
--- is true also qualifies, regardless of auditGrade — see that file's own
--- header for the full "run any command" contract. Guarded by a
--- `type(...) == 'function'` runtime existence check, so this function is
--- byte-identical in behavior to before if server/highcommand.lua is ever
--- removed or Config.Features.HighCommand is false.
--- @param source number
--- @return boolean
local function IsAuthorizedAdmin(source)
    -- SECURITY REVIEW OUTCOME (coder-security, prior pass, preserved verbatim
    -- -- the reasoning below is about `source == 0` itself and is unaffected
    -- by swapping the second branch from an ACE check to a job-rank check):
    -- this function previously did `if source == 0 then return true end`, on
    -- the reasoning that the server console already owns the process, the DB
    -- and the ACE system, so gating a read-only query behind ACE was not a
    -- real boundary. That reasoning is sound for the console -- and WRONG for
    -- FiveM, because `source == 0` has three distinct producers that this
    -- layer cannot tell apart:
    --   1. the real server console (the case the reasoning describes),
    --   2. an RCON client, authenticated only by `rcon_password` -- a
    --      network-facing credential, entirely separate from filesystem/DB/ACE
    --      control, so a leaked RCON password does NOT imply "already owns
    --      everything",
    --   3. ANY other resource on this server, via the `ExecuteCommand` native.
    --      These commands are registered with `restricted = false`, so nothing
    --      at the native layer stops a compromised, malicious or merely buggy
    --      co-located resource from running `k9auditsearch recent 100` and
    --      reading the entire privacy-sensitive audit trail with no ACE grant
    --      of its own.
    -- So the blanket bypass trusted a far broader and weaker set of actors than
    -- its justification described. It is opt-in and defaults off. THIS PASS
    -- ADDS A SECOND, INDEPENDENT REASON THIS BRANCH MUST STAY EXPLICIT: a
    -- job-rank check has no job object to consult for source == 0 at all, so
    -- without this early, separately-reasoned return, console access would be
    -- structurally impossible rather than a deliberate default -- see header
    -- ACCESS MODEL for the full writeup.
    if source == 0 then
        return Config.AdminAudit.TrustConsole == true
    end

    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- Resolved once, reused by every qualification path below AND by the
    -- PER-PERSON FEATURE CONTROL check each of them now routes through --
    -- same citizenid the pre-existing 'k9.audit' permission-grant bypass
    -- immediately below already reads from this exact field.
    local citizenid = Player.PlayerData.citizenid

    -- job.isboss always qualifies regardless of the configured numeric
    -- threshold -- same rule, same reasoning, as
    -- server/certifications.lua's IsEligibleCertifier. PER-PERSON FEATURE
    -- CONTROL (this pass) is layered on AFTER this qualifies, never
    -- instead of it -- see IsAdminFeaturePermittedForCitizenId's own doc
    -- comment above for why a block/missing-grant can narrow even a boss's
    -- own audit access without touching their job rank.
    if job.isboss then return IsAdminFeaturePermittedForCitizenId(citizenid) end

    -- PERMISSION GRANT BYPASS (server/permissions.lua, Config.Features.PermissionGrants,
    -- resolution-order STEP 1) -- an active granted 'k9.audit' permission
    -- ALLOWS outright, checked before the high-command bypass and the
    -- auditGrade comparison below, matching config.lua's own documented
    -- "first match wins" order. Guarded by a `type(...) == 'function'`
    -- runtime existence check -- this function still works exactly as
    -- before if server/permissions.lua is ever removed or
    -- Config.Features.PermissionGrants is false. PER-PERSON FEATURE
    -- CONTROL (this pass) still applies on top of this bypass -- holding
    -- the 'k9.audit' CAPABILITY grant is a different fact from holding the
    -- 'feature.AdminAuditCommands' FEATURE grant Config.FeatureControl.RequireGrant
    -- asks for; a block on the latter still wins even for someone who
    -- holds the former.
    if type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.audit') then
        return IsAdminFeaturePermittedForCitizenId(citizenid)
    end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- project-owner-directed this pass) -- auditGrade is explicitly one of
    -- the gates a High Command officer must bypass (see that file's own
    -- header PART 1 for the full contract). Guarded by a
    -- `type(...) == 'function'` runtime existence check, this resource's
    -- established soft-dependency convention -- this function still works
    -- exactly as before if server/highcommand.lua is ever removed or
    -- Config.Features.HighCommand is false (IsHighCommand re-checks that
    -- flag itself and returns false). PER-PERSON FEATURE CONTROL (this
    -- pass) still applies on top of this bypass -- see
    -- server/tablet.lua's own disclosed "NO high-command bypass at step 3"
    -- reading of config.lua's Config.FeatureControl order, which this
    -- mirrors: high command triggering ITS OWN audit access is still
    -- subject to a block/RequireGrant the same as anyone else.
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return IsAdminFeaturePermittedForCitizenId(citizenid)
    end

    -- SAME hardening IsEligibleCertifier/HasK9Access already carry: an
    -- explicit type check on BOTH operands before the `>=` comparison, not a
    -- pcall. A pcall here would convert a real job-shape bug into exactly the
    -- silent "this rank can never audit anything" no-op this codebase's own
    -- prior security fixes exist to stop happening quietly. Non-number
    -- dept.auditGrade (unset/misconfigured department) or non-number
    -- job.grade.level (a job object shaped differently than qbx_core's
    -- documented `{ name, level: number }` schema) both FAIL CLOSED here --
    -- this function returns false, never throws, and never reaches the
    -- comparison with a bad operand on either side.
    local dept = Config.Departments[job.name]
    if type(dept.auditGrade) ~= 'number' then return false end

    if not (job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.auditGrade) then
        return false
    end

    -- PER-PERSON FEATURE CONTROL, final path (this pass) -- same check as
    -- every bypass above, applied to the ordinary rank-qualified case too.
    return IsAdminFeaturePermittedForCitizenId(citizenid)
end

--- Parses and clamps an optional caller-supplied result-count argument.
--- Never trusts the raw value directly into a query — always returns a
--- plain Lua integer already clamped into [1, hardMax]. `defaultValue` is
--- substituted when `rawArg` is absent/unparseable, but is then put through
--- the EXACT SAME floor+range-clamp pass as a parsed `rawArg` would be —
--- deliberately not returned raw. The onResourceStart config-shape assert
--- below now also rejects a non-integer/out-of-range
--- `Config.AdminAudit.MaxResults.*` at startup (belt-and-suspenders), but
--- this function does not rely on that assert alone: floor+clamp always
--- runs here too, so `defaultValue` can never reach `string.format('...
--- LIMIT %d', limit)` un-floored regardless of how it got here. Lua's `%d`
--- format specifier raises an UNCAUGHT error on a float with a fractional
--- part -- that `%d` embed now happens inside server/datastore.lua's own
--- K9Store.* functions (this file no longer builds its own SQL text at
--- all), OUTSIDE of and before that layer's own fail-closed pcall wrap,
--- which would otherwise turn a config-shape gap into a runtime crash on
--- the very first invocation of any of these three commands. See this file's
--- header "SQL SAFETY" section for why the RETURNED integer (never
--- `rawArg` itself, and now never a raw `defaultValue` either) is the only
--- thing that ever reaches a query string.
---
--- NaN HARDENING (this pass, added for the CALLBACK SURFACE below): every
--- pre-existing caller of this function is a RegisterCommand handler, whose
--- `rawArg` is always either nil or a plain string straight from chat
--- input -- `tonumber('nan')` is nil on this codebase's own Lua 5.4 build
--- (see tests/admin_spec.lua's own locked-in regression case for that
--- exact fact), so a real NaN value could never previously reach `parsed`
--- at all. The CALLBACK SURFACE below accepts `limit` as a plain Lua
--- number straight off the wire (a `lib.callback` argument, never a
--- string), and `tonumber(x)` on an ALREADY-NaN number returns that SAME
--- NaN unchanged, not nil -- so a malicious/buggy client could send a raw
--- NaN double as `limit` and reach this function with a `parsed` value no
--- comparison against it can ever resolve (`nan < 1` and `nan > hardMax`
--- are BOTH false; `math.floor(nan)` itself does not error, so unlike the
--- string.format('%d', ...) UNCAUGHT-error case this file's docs already
--- name, NaN would instead silently walk straight past both clamp checks
--- and OUT of this function, only to throw later, inside
--- server/datastore.lua's own `%d` embed, the very failure mode this
--- function exists to prevent). Guarded explicitly here, once, for every
--- caller (command or callback alike) via the standard `x ~= x` NaN
--- self-inequality test -- treated identically to an unparseable/absent
--- `rawArg` (falls back to `defaultValue`, then still runs through the
--- SAME floor+range clamp below, same as every other path through this
--- function).
--- @param rawArg string|number|nil -- a RegisterCommand string arg, a lib.callback numeric arg, or nil/absent
--- @param defaultValue number
--- @param hardMax number
--- @return number limit
local function ClampLimit(rawArg, defaultValue, hardMax)
    local parsed = tonumber(rawArg)
    if parsed == nil or parsed ~= parsed then
        parsed = defaultValue
    end
    parsed = math.floor(parsed)
    if parsed < 1 then return 1 end
    if parsed > hardMax then return hardMax end
    return parsed
end

--- @param value string?
--- @return boolean
local function IsValidCitizenId(value)
    -- VARCHAR(50) per every k9_* citizenid column (sql/install.sql) —
    -- bounding the length to the actual column width rather than accepting
    -- an arbitrarily long string into a query parameter. Not an injection
    -- backstop (this value only ever reaches a bound `?` placeholder,
    -- never raw SQL text) — a plain sanity/DoS-lite bound, matching this
    -- task's "validate type/range/length of every argument" requirement.
    return type(value) == 'string' and value ~= '' and #value <= 50
end

--- @param value string?
--- @return boolean
local function IsValidDepartment(value)
    -- Same validation shape server/certifications.lua's
    -- RevokeCertificationOffline already applies to its own `job` argument
    -- (`if not Config.Departments[job] then ... end`) — reused here rather
    -- than invented fresh, per this file's header "COMMAND SURFACE" item 5
    -- "ARGUMENT SHAPE" reasoning. A typo'd/unconfigured department name
    -- could never have a matching k9_certifications row, so this rejects
    -- it outright as `invalid_args` instead of silently returning zero
    -- results — same posture IsValidCitizenId/NormalizePlateArg already
    -- take for this file's other string arguments.
    return type(value) == 'string' and value ~= '' and Config.Departments[value] ~= nil
end

--- @param value string?
--- @return string? trimmedPlate -- nil if invalid
local function NormalizePlateArg(value)
    if type(value) ~= 'string' then return nil end
    -- Same trim server/search.lua applies to GTA's own space-padded
    -- GetVehicleNumberPlateText result — mirrored here for the same
    -- reason (a human admin typing a plate by hand is just as likely to
    -- add stray whitespace), not re-derived independently.
    local trimmed = value:match('^%s*(.-)%s*$')
    if not trimmed or trimmed == '' or #trimmed > 15 then return nil end -- VARCHAR(15) per k9_search_log.target_plate
    return trimmed
end

--- Console log line for EVERY invocation of every command in this file —
--- allowed, denied, rate-limited, or malformed. "An audit tool nobody can
--- audit is a gap" (this task's own framing). Deliberately a print(), not
--- a new DB table — see this file's header "AUDIT-OF-THE-AUDIT" section
--- for why a persisted meta-audit table is a schema decision out of this
--- file's scope. `detail` is deliberately 'n/a' for a denied/unauthorized
--- attempt (logged BEFORE any argument is parsed — see each command
--- handler's own auth-check-first ordering) so an unauthorized caller's
--- attempted query target is never even parsed, let alone logged.
--- @param source number
--- @param commandName string
--- @param detail string
--- @param outcome string -- 'ok' | 'denied' | 'rate_limited' | 'invalid_args'
local function LogAuditInvocation(source, commandName, detail, outcome)
    local whoLabel = 'console'
    if source ~= 0 then
        local Player = exports.qbx_core:GetPlayer(source)
        local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
        whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    end
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, commandName, detail, outcome))
end

--- Merges two already-LIMITed row sets (one per unique index — see
--- QueryPartnershipHistory below) into one list, sorts by `id` DESC (see
--- this file's header "SQL SAFETY" section for why `id`, never a DATETIME
--- column, is compared in Lua), then truncates to `limit`. Cheap: each
--- input list is already bounded by the SAME `limit`, so this never
--- operates on more than 2 * limit rows (<= 2 * HARD_MAX_RESULTS worst
--- case).
--- @param rowsA table
--- @param rowsB table
--- @param limit number
--- @return table merged
local function MergeSortedByIdDesc(rowsA, rowsB, limit)
    local merged = {}
    for _, row in ipairs(rowsA) do merged[#merged + 1] = row end
    for _, row in ipairs(rowsB) do merged[#merged + 1] = row end

    table.sort(merged, function(a, b) return a.id > b.id end)

    local truncated = {}
    for i = 1, math.min(limit, #merged) do
        truncated[i] = merged[i]
    end
    return truncated
end

--- @param row table -- one k9_certifications row
--- @return string
local function FormatCertRow(row)
    return locale('admin.cert_row_format',
        tostring(row.job), tostring(row.active == 1), tostring(row.granted_by), tostring(row.granted_at),
        row.revoked_by and tostring(row.revoked_by) or 'N/A',
        row.revoked_at and tostring(row.revoked_at) or 'N/A'
    )
end

--- @param row table -- one k9_partnerships row
--- @return string
local function FormatPartnershipRow(row)
    return locale('admin.partnership_row_format',
        tostring(row.k9_citizenid), tostring(row.handler_citizenid), tostring(row.active == 1),
        tostring(row.established_by), tostring(row.established_at),
        row.ended_by and tostring(row.ended_by) or 'N/A',
        row.ended_at and tostring(row.ended_at) or 'N/A'
    )
end

--- @param row table -- one k9_search_log row
--- @return string
local function FormatSearchLogRow(row)
    -- Dynamic-value substitution via locale()'s own %s placeholder, not `..`
    -- concatenation — same "no string-built player-facing fragments"
    -- discipline as DEVELOPER_REFERENCE.md's own documented concatenation fixes
    -- (movement.officer_fallback_name, bonetool.bone_index_label, etc.).
    local targetLabel = row.target_type == 'vehicle'
        and locale('admin.search_log_target_plate_label', tostring(row.target_plate))
        or locale('admin.search_log_target_citizenid_label', tostring(row.target_citizenid))
    return locale('admin.search_log_row_format',
        tostring(row.searched_at), tostring(row.searcher_citizenid), tostring(row.searcher_job),
        tostring(row.target_type), targetLabel, tostring(row.result),
        row.total_weight and tostring(row.total_weight) or 'N/A',
        row.alert_tier and tostring(row.alert_tier) or 'N/A'
    )
end

--- @param row table -- one k9_progression row
--- @return string
local function FormatProgressionRow(row)
    -- Deliberately reports the raw `xp` total only — see this file's
    -- header "COMMAND SURFACE" item 4 for why a tier is not derived here.
    return locale('admin.progression_row_format', tostring(row.xp), tostring(row.updated_at))
end

--- @param row table -- one k9_certifications row (active-only roster shape)
--- @return string
local function FormatDeptCertRow(row)
    -- Deliberately omits `job` (already the query's own fixed argument —
    -- same "never repeat the field the query is scoped by" convention
    -- FormatCertRow above follows by omitting `citizenid`) and
    -- `active`/`revoked_by`/`revoked_at` (always true/NULL/NULL for an
    -- active-only roster row — see this file's header "COMMAND SURFACE"
    -- item 5 "DISPLAY BOUNDARY" reasoning for why nothing wider than
    -- idx_job_active's own documented column list is exposed here).
    return locale('admin.dept_cert_row_format', tostring(row.citizenid), tostring(row.granted_by), tostring(row.granted_at))
end

--- Presents `rows` (already fetched, already bounded) to a connected
--- caller as a small number of batched ox_lib toasts — a deliberately
--- minimal in-game presentation. This file's scope is the command/query/
--- authorization layer, not a new NUI screen; a proper list view is
--- natural follow-up work for coder-ui once this command surface proves
--- useful, not built here. NEVER called for console (source == 0).
--- @param target number
--- @param label string
--- @param rows table
--- @param formatRow fun(row: table): string
local function PresentRows(target, label, rows, formatRow)
    if #rows == 0 then
        NotifyPlayer(target, locale('admin.no_results_found', label), 'info')
        return
    end

    NotifyPlayer(target, locale('admin.result_count', label, #rows), 'info')

    local lines = {}
    for i, row in ipairs(rows) do
        lines[#lines + 1] = formatRow(row)
        if #lines >= ROWS_PER_NOTIFY_CHUNK or i == #rows then
            NotifyPlayer(target, table.concat(lines, '\n'), 'info')
            lines = {}
        end
    end
end

--- Console-side presentation counterpart to PresentRows above — a plain
--- print() per row, no client to notify.
--- @param label string
--- @param rows table
--- @param formatRow fun(row: table): string
local function PrintRowsToConsole(label, rows, formatRow)
    print(('[qbx_k9unit] %s: %d result(s)'):format(label, #rows))
    for _, row in ipairs(rows) do
        print('[qbx_k9unit]   ' .. formatRow(row))
    end
end

--- '/k9auditcert' query. Uses idx_citizen_job_active's leading `citizenid`
--- column as a prefix scan (sql/install.sql's own comment on that index
--- names this exact "full cert history for citizenid X" shape). Ordered by
--- `granted_at DESC` — MySQL sorts this server-side; this file never
--- parses/compares that value in Lua (see header "SQL SAFETY").
--- @param citizenid string
--- @param limit number -- already clamped by ClampLimit
--- @return table rows
local function QueryCertificationHistory(citizenid, limit)
    return K9Store.Cert_GetHistory(citizenid, limit)
end

--- '/k9auditpartner' query. Two separate equality queries — one per unique
--- index (idx_k9_citizenid_active / idx_handler_citizenid_active) — merged
--- in Lua by MergeSortedByIdDesc above, rather than one OR'd WHERE clause
--- forcing an index-merge plan across two independent indexes. Each
--- sub-query is itself ordered `id DESC LIMIT limit` (not `established_at
--- DESC`) precisely so the Lua-side merge and the SQL-side LIMIT selection
--- agree on the exact same sort key — see header "SQL SAFETY".
--- @param citizenid string
--- @param limit number -- already clamped by ClampLimit
--- @return table rows
local function QueryPartnershipHistory(citizenid, limit)
    local asK9 = K9Store.Partner_GetHistoryByK9(citizenid, limit)
    local asHandler = K9Store.Partner_GetHistoryByHandler(citizenid, limit)

    return MergeSortedByIdDesc(asK9, asHandler, limit)
end

--- '/k9auditsearch officer' query — searches PERFORMED BY citizenid, most
--- recent first. Uses idx_searcher_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param citizenid string
--- @param limit number
--- @return table rows
local function QuerySearchLogByOfficer(citizenid, limit)
    return K9Store.SearchLog_GetByOfficer(citizenid, limit)
end

--- '/k9auditsearch plate' query — searches OF a vehicle plate, most recent
--- first. Uses idx_target_plate_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param plate string -- already normalized by NormalizePlateArg
--- @param limit number
--- @return table rows
local function QuerySearchLogByPlate(plate, limit)
    return K9Store.SearchLog_GetByPlate(plate, limit)
end

--- '/k9auditsearch person' query — searches OF a person citizenid, most
--- recent first. Uses idx_target_citizenid_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param citizenid string
--- @param limit number
--- @return table rows
local function QuerySearchLogByPerson(citizenid, limit)
    return K9Store.SearchLog_GetByPerson(citizenid, limit)
end

--- '/k9auditsearch recent' query — the N most recently logged searches of
--- ANY kind, no WHERE clause. Ordered by `id DESC` (InnoDB's own clustered
--- primary-key order), NOT `searched_at` — reading the tail of the
--- clustered index is cheap and needs no dedicated index of its own; see
--- this file's header "COMMAND SURFACE" section for the full reasoning.
--- @param limit number
--- @return table rows
local function QuerySearchLogRecent(limit)
    return K9Store.SearchLog_GetRecent(limit)
end

--- '/k9auditxp' query — see this file's header "COMMAND SURFACE" item 4
--- and "COVERAGE RE-CHECK" for the full reasoning. `citizenid` is
--- k9_progression's own PRIMARY KEY (sql/install.sql) — a plain,
--- unclamped `LIMIT 1` literal is correct here, NOT a caller-influenced
--- ClampLimit value, because there is structurally never more than one
--- matching row regardless of what any argument says.
--- @param citizenid string
--- @return table rows -- 0 or 1 rows
local function QueryProgressionSnapshot(citizenid)
    return K9Store.XP_GetSnapshotRows(citizenid)
end

--- '/k9auditdept' query — see this file's header "COMMAND SURFACE" item 5
--- and "COVERAGE RE-CHECK (this pass, take 2)" for the full reasoning.
--- Uses `idx_job_active` (`job`, `active`) — this is sql/install.sql's own
--- documented query for that index, verbatim, with only ORDER BY/LIMIT
--- added on top (same discipline every other query function in this file
--- already follows). `active = 1` restricts this to the CURRENT roster,
--- never revoked history — see this file's header "ACTIVE-ONLY, NOT FULL
--- HISTORY" reasoning. Ordered by `granted_at DESC` — MySQL sorts this
--- server-side; this file never parses/compares that value in Lua (see
--- header "SQL SAFETY").
--- @param job string -- already validated against Config.Departments by IsValidDepartment
--- @param limit number -- already clamped by ClampLimit
--- @return table rows
local function QueryDepartmentRoster(job, limit)
    return K9Store.Cert_GetActiveRosterByJob(job, limit)
end

-- ======================================================================
-- COMMAND REGISTRATION — gated on Config.Features.AdminAuditCommands AT
-- REGISTRATION TIME (this task's explicit convention): if the flag is not
-- `true`, none of the five commands below are ever registered at all, not
-- merely a runtime no-op. A missing/nil flag is treated identically to
-- `false` (feature disabled, no crash) — this resource must not fail to
-- start for an unrelated server that hasn't touched config.lua's new
-- fields yet. Only once the flag is explicitly `true` does this block
-- require Config.AdminAudit's full shape, and fails loudly (assert) if
-- that shape is wrong — the operator has opted in and deserves an
-- immediate, obvious failure rather than a silently broken command
-- surface. Mirrors server/search.lua's own onResourceStart config-safety-
-- guard convention.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if not (Config.Features and Config.Features.AdminAuditCommands == true) then
        return -- feature disabled (or not yet configured) — nothing below this line ever runs
    end

    assert(
        type(Config.AdminAudit) == 'table',
        '[qbx_k9unit] Config.Features.AdminAuditCommands is true but Config.AdminAudit is missing.'
    )
    assert(
        type(Config.AdminAudit.CommandCooldownMs) == 'number' and Config.AdminAudit.CommandCooldownMs >= MIN_COMMAND_COOLDOWN_MS,
        ('[qbx_k9unit] Config.AdminAudit.CommandCooldownMs must be a number >= %dms.'):format(MIN_COMMAND_COOLDOWN_MS)
    )
    -- Config.AdminAudit.AcePermission is intentionally NOT asserted here any
    -- more -- this file no longer calls IsPlayerAceAllowed at all as of this
    -- pass (see header "ACCESS MODEL"). If a shipped config still declares
    -- it, that's harmless dead data, not a startup failure.

    -- NEW this pass (ACE->job-rank rewrite): IsAuthorizedAdmin compares
    -- job.grade.level against Config.Departments[job.name].auditGrade for
    -- every non-boss caller. Asserted here, not left to fail silently at
    -- first use, for the SAME reason server/certifications.lua asserts
    -- dept.certifierGrade at its own load time: a missing/malformed
    -- auditGrade on any configured department would otherwise mean every
    -- non-boss officer in that department silently, permanently fails
    -- every audit command (IsAuthorizedAdmin's own type-check already fails
    -- closed at runtime -- see that function's doc comment -- but a
    -- fail-closed RUNTIME default is not a substitute for a loud STARTUP
    -- error once this feature has actually been opted into). Only run once
    -- Config.Features.AdminAuditCommands is true, matching this whole
    -- block's own "operator has opted in, deserves an immediate failure"
    -- convention -- an unrelated server that never touches this feature at
    -- all must not be forced to add auditGrade to every department it
    -- didn't otherwise need to configure for this file.
    assert(type(Config.Departments) == 'table', '[qbx_k9unit] Config.Features.AdminAuditCommands is true but Config.Departments is missing -- IsAuthorizedAdmin requires it to resolve the caller\'s own department threshold.')
    for jobName, dept in pairs(Config.Departments) do
        assert(
            type(dept) == 'table' and type(dept.auditGrade) == 'number',
            ('[qbx_k9unit] Config.Departments[%s].auditGrade must be a number -- IsAuthorizedAdmin compares job.grade.level >= dept.auditGrade for every non-boss officer in that department. A missing/malformed value here means every audit command silently (but safely, per IsAuthorizedAdmin\'s own fail-closed type check) denies every non-boss caller in that department, with nothing logged at startup to explain why.'):format(tostring(jobName))
        )
    end

    local maxResults = Config.AdminAudit.MaxResults
    assert(type(maxResults) == 'table', '[qbx_k9unit] Config.AdminAudit.MaxResults must be a table.')
    for _, key in ipairs({ 'Certifications', 'Partnerships', 'SearchLog' }) do
        local value = maxResults[key]
        -- Integer-ness is checked here too (not just range) even though
        -- ClampLimit below independently floors this same value before it
        -- can ever reach a query string — belt-and-suspenders: an operator
        -- who sets e.g. `50.5` deserves a loud, immediate startup error
        -- naming exactly which config key is wrong, not a value that
        -- silently gets floored to `50` and behaves as if nothing were
        -- misconfigured.
        assert(
            type(value) == 'number' and value == math.floor(value) and value >= 1 and value <= HARD_MAX_RESULTS,
            ('[qbx_k9unit] Config.AdminAudit.MaxResults.%s must be an integer in [1, %d].'):format(key, HARD_MAX_RESULTS)
        )
    end

    --- '/k9auditcert [citizenid] [limit]' — see this file's header
    --- "COMMAND SURFACE" item 1.
    RegisterCommand('k9auditcert', function(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9auditcert', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9auditcert', 'n/a', 'rate_limited')
            return -- silent no-op: rate-limited, not an error worth notifying about (matches this resource's bark/leash-request/certify-action convention)
        end

        local citizenid = args[1]
        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'k9auditcert', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditcert')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryCertificationHistory(citizenid, limit)
        local label = locale('admin.cert_history_label', citizenid)

        LogAuditInvocation(source, 'k9auditcert', citizenid, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatCertRow)
        else
            PresentRows(source, label, rows, FormatCertRow)
        end
    end, false)

    --- '/k9auditpartner [citizenid] [limit]' — see this file's header
    --- "COMMAND SURFACE" item 2.
    RegisterCommand('k9auditpartner', function(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9auditpartner', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9auditpartner', 'n/a', 'rate_limited')
            return
        end

        local citizenid = args[1]
        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'k9auditpartner', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditpartner')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.Partnerships, HARD_MAX_RESULTS)
        local rows = QueryPartnershipHistory(citizenid, limit)
        local label = locale('admin.partnership_history_label', citizenid)

        LogAuditInvocation(source, 'k9auditpartner', citizenid, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatPartnershipRow)
        else
            PresentRows(source, label, rows, FormatPartnershipRow)
        end
    end, false)

    --- '/k9auditsearch <officer|plate|person|recent> [value] [limit]' —
    --- see this file's header "COMMAND SURFACE" item 3. Authorization is
    --- checked BEFORE the `mode` argument is even inspected — an
    --- unauthorized caller learns nothing about argument validity, not
    --- even whether their chosen mode string was recognized. This is a
    --- deliberate divergence from server/certifications.lua's own
    --- GrantCertification ordering (which validates argument shape BEFORE
    --- eligibility) — justified here because this surface is explicitly a
    --- privacy-sensitive audit tool (this task's own framing), not a
    --- capability grant with an obvious legitimate target already implied
    --- by the caller reaching the handler at all. Flagged for
    --- coder-security to confirm or override, same as the console
    --- carve-out in this file's header.
    RegisterCommand('k9auditsearch', function(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9auditsearch', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9auditsearch', 'n/a', 'rate_limited')
            return
        end

        local mode = args[1]
        if not VALID_SEARCH_LOG_MODES[mode] then
            LogAuditInvocation(source, 'k9auditsearch', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditsearch')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local rows, label

        if mode == 'officer' or mode == 'person' then
            local citizenid = args[2]
            if not IsValidCitizenId(citizenid) then
                LogAuditInvocation(source, 'k9auditsearch', 'n/a', 'invalid_args')
                local usage = locale('admin.usage_auditsearch_mode', mode)
                if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
                return
            end
            local limit = ClampLimit(args[3], Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = (mode == 'officer') and QuerySearchLogByOfficer(citizenid, limit) or QuerySearchLogByPerson(citizenid, limit)
            label = locale('admin.search_log_label_by_value', mode, citizenid)
        elseif mode == 'plate' then
            local plate = NormalizePlateArg(args[2])
            if not plate then
                LogAuditInvocation(source, 'k9auditsearch', 'n/a', 'invalid_args')
                local usage = locale('admin.usage_auditsearch_plate')
                if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
                return
            end
            local limit = ClampLimit(args[3], Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogByPlate(plate, limit)
            label = locale('admin.search_log_label_plate', plate)
        else -- 'recent'
            local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogRecent(limit)
            label = locale('admin.search_log_label_recent')
        end

        LogAuditInvocation(source, 'k9auditsearch', label, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatSearchLogRow)
        else
            PresentRows(source, label, rows, FormatSearchLogRow)
        end
    end, false)

    --- '/k9auditxp [citizenid]' — see this file's header "COMMAND SURFACE"
    --- item 4 and "COVERAGE RE-CHECK" for the full reasoning. No `[limit]`
    --- argument — `citizenid` is k9_progression's own PRIMARY KEY, so
    --- there is never more than one row to bound.
    RegisterCommand('k9auditxp', function(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9auditxp', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9auditxp', 'n/a', 'rate_limited')
            return
        end

        local citizenid = args[1]
        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'k9auditxp', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditxp')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local rows = QueryProgressionSnapshot(citizenid)
        local label = locale('admin.xp_snapshot_label', citizenid)

        LogAuditInvocation(source, 'k9auditxp', citizenid, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatProgressionRow)
        else
            PresentRows(source, label, rows, FormatProgressionRow)
        end
    end, false)

    --- '/k9auditdept <job> [limit]' — see this file's header "COMMAND
    --- SURFACE" item 5 and "COVERAGE RE-CHECK (this pass, take 2)" for the
    --- full reasoning (idx_job_active, specified/indexed for but never
    --- queried until now). Reuses Config.AdminAudit.MaxResults.Certifications
    --- as its result cap — see item 5's own "RESULT CAP" note for why no
    --- new config key was added.
    RegisterCommand('k9auditdept', function(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9auditdept', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9auditdept', 'n/a', 'rate_limited')
            return
        end

        local job = args[1]
        if not IsValidDepartment(job) then
            LogAuditInvocation(source, 'k9auditdept', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditdept')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryDepartmentRoster(job, limit)
        local label = locale('admin.dept_roster_label', job)

        LogAuditInvocation(source, 'k9auditdept', job, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatDeptCertRow)
        else
            PresentRows(source, label, rows, FormatDeptCertRow)
        end
    end, false)

    -- ======================================================================
    -- CALLBACK SURFACE (this pass) -- the missing half this task exists to
    -- close: the five commands above only ever format their query results
    -- into a chat toast (PresentRows) or a console print
    -- (PrintRowsToConsole); there was, until now, no way for the tablet (or
    -- any other in-game consumer) to reach the underlying ROWS themselves.
    -- Every callback below is a thin `lib.callback.register` wrapper around
    -- the EXACT SAME Query* local function (therefore the EXACT SAME
    -- K9Store.* accessor, the EXACT SAME hardcoded SQL text) its command
    -- counterpart already calls above -- see this file's header "SQL
    -- SAFETY" section, entirely unchanged by this addition. THIS FILE
    -- STILL COMPUTES NOTHING NEW: a callback returns the raw row table a
    -- Query* function already produced, nothing more.
    --
    -- AUTHORIZATION IS IDENTICAL TO THE COMMAND IT MIRRORS -- not a
    -- separate, easier-to-reach check. Every callback below calls the SAME
    -- `IsAuthorizedAdmin(source)` every RegisterCommand handler above
    -- already calls, re-deriving the caller's job/grade/permission state
    -- from their OWN server-held `source` on every single invocation --
    -- never a client-sent flag, never a value cached from an earlier call.
    -- These callbacks are registered inside this SAME onResourceStart
    -- block, behind the SAME `Config.Features.AdminAuditCommands` gate the
    -- five commands above already require: if that flag is not `true`,
    -- NONE of these callbacks are ever registered either, not merely a
    -- runtime no-op that still replies once invoked -- a callback reachable
    -- while the feature is off would be a strictly EASIER path into this
    -- data than the commands it is supposed to mirror, exactly the
    -- privilege-escalation shape this task's own brief warns against by
    -- name.
    --
    -- RATE LIMITING IS THE SAME SHARED BUDGET, NOT A SEPARATE ONE -- every
    -- callback below calls the SAME `AuditCooldown` instance, keyed by the
    -- SAME caller `source`, as every command above. A caller cannot double
    -- their effective query rate against k9_search_log by alternating
    -- between the chat command and the tablet callback; both draw down the
    -- one cooldown bucket per source.
    --
    -- EVERY RESULT SET IS BOUNDED THE SAME WAY -- every `limit` argument
    -- below is passed through the SAME `ClampLimit(rawArg, defaultValue,
    -- HARD_MAX_RESULTS)` the command path already uses before it can ever
    -- reach a Query* function, never a client-supplied value passed through
    -- unclamped. See ClampLimit's own doc comment above, "NaN HARDENING
    -- (this pass)", for the ONE new hostile-input case this callback
    -- surface specifically opens (a raw NaN Lua number, only reachable
    -- because `limit` here arrives as a number over the wire rather than a
    -- string from chat) and why it is closed inside ClampLimit itself, once,
    -- rather than re-derived per call site here.
    --
    -- RETURN SHAPE mirrors server/tablet.lua's own established
    -- `{ ok, error, message, ... }` convention (see e.g. that file's
    -- tabletRequestPersonSummary) rather than inventing a new one:
    --   success: { ok = true, rows = <table>, label = <string> }
    --     `rows` is the RAW array K9Store.* already returns for that query
    --     (see each Query* function's own doc comment a few hundred lines
    --     above for the exact column list) -- the entire point of this
    --     task, never a formatted string. `label` is the SAME human-
    --     readable description (via the SAME `locale(...)` call) the
    --     command path already builds for its own toast/console header --
    --     included purely as a display convenience, never itself a source
    --     of additional data.
    --   failure: { ok = false, error = 'not_authorized' | 'rate_limited' | 'invalid_args', message = string? }
    --     `message` is only ever populated on `not_authorized` (the SAME
    --     `locale('admin.not_authorized')` text NotifyPlayer already sends
    --     for a denied command), matching server/tablet.lua's own
    --     documented "message stays optional, absence is a clean fallback"
    --     contract for its other two error codes.
    -- A callback NEVER exposes a wider column set than its command
    -- counterpart already prints -- e.g. tabletAuditDept's rows are the
    -- SAME `citizenid, granted_by, granted_at` triple `/k9auditdept`'s own
    -- "DISPLAY BOUNDARY" header section documents, nothing wider.
    --
    -- AUDIT-OF-THE-AUDIT still applies unchanged -- every callback
    -- invocation (allowed, denied, rate-limited, or malformed) is logged
    -- via the SAME `LogAuditInvocation` the commands use, under a DISTINCT
    -- `tabletAuditX` label (rather than `k9auditx`) so an operator reading
    -- the console log can tell which path -- console/chat command vs.
    -- tablet callback -- a given invocation came through.
    --
    -- NUI/CLIENT WIRING IS DELIBERATELY OUT OF SCOPE HERE: no
    -- `client/tablet.lua` change and no NUI callback are part of this pass
    -- -- these five `lib.callback.register` names, their argument shapes,
    -- and their `{ ok, rows, label, error, message }` return shape are the
    -- CONTRACT a follow-up tablet screen builds against, not built here.
    -- ======================================================================

    --- 'qbx_k9unit:server:tabletAuditCert' -- mirrors '/k9auditcert'. See
    --- QueryCertificationHistory above for the exact row shape returned.
    --- @param source number
    --- @param citizenid string?
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditCert', function(source, citizenid, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditCert', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditCert', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'tabletAuditCert', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit = ClampLimit(limit, Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryCertificationHistory(citizenid, clampedLimit)
        local label = locale('admin.cert_history_label', citizenid)

        LogAuditInvocation(source, 'tabletAuditCert', citizenid, 'ok')
        return { ok = true, rows = rows, label = label }
    end)

    --- 'qbx_k9unit:server:tabletAuditPartner' -- mirrors '/k9auditpartner'.
    --- See QueryPartnershipHistory above for the exact row shape returned
    --- (already merged across both roles and sorted/truncated by
    --- MergeSortedByIdDesc).
    --- @param source number
    --- @param citizenid string?
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditPartner', function(source, citizenid, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditPartner', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditPartner', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'tabletAuditPartner', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit = ClampLimit(limit, Config.AdminAudit.MaxResults.Partnerships, HARD_MAX_RESULTS)
        local rows = QueryPartnershipHistory(citizenid, clampedLimit)
        local label = locale('admin.partnership_history_label', citizenid)

        LogAuditInvocation(source, 'tabletAuditPartner', citizenid, 'ok')
        return { ok = true, rows = rows, label = label }
    end)

    --- 'qbx_k9unit:server:tabletAuditSearch' -- mirrors '/k9auditsearch'.
    --- `mode` is checked against the SAME VALID_SEARCH_LOG_MODES whitelist
    --- BEFORE `value` is even inspected -- same "an unauthorized/malformed
    --- caller learns nothing about argument validity, not even whether
    --- their chosen mode string was recognized" posture this file's own
    --- '/k9auditsearch' command comment already documents. See
    --- QuerySearchLogByOfficer/ByPlate/ByPerson/Recent above for the exact
    --- row shape returned (identical across all four modes).
    --- @param source number
    --- @param mode string? -- 'officer' | 'plate' | 'person' | 'recent'
    --- @param value string? -- citizenid (officer/person) or plate (plate); ignored for 'recent'
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditSearch', function(source, mode, value, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not VALID_SEARCH_LOG_MODES[mode] then
            LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local rows, label

        if mode == 'officer' or mode == 'person' then
            if not IsValidCitizenId(value) then
                LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'invalid_args')
                return { ok = false, error = 'invalid_args' }
            end
            local clampedLimit = ClampLimit(limit, Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = (mode == 'officer') and QuerySearchLogByOfficer(value, clampedLimit) or QuerySearchLogByPerson(value, clampedLimit)
            label = locale('admin.search_log_label_by_value', mode, value)
        elseif mode == 'plate' then
            local plate = NormalizePlateArg(value)
            if not plate then
                LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'invalid_args')
                return { ok = false, error = 'invalid_args' }
            end
            local clampedLimit = ClampLimit(limit, Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogByPlate(plate, clampedLimit)
            label = locale('admin.search_log_label_plate', plate)
        else -- 'recent'
            local clampedLimit = ClampLimit(limit, Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogRecent(clampedLimit)
            label = locale('admin.search_log_label_recent')
        end

        LogAuditInvocation(source, 'tabletAuditSearch', label, 'ok')
        return { ok = true, rows = rows, label = label }
    end)

    --- 'qbx_k9unit:server:tabletAuditXp' -- mirrors '/k9auditxp'. No
    --- `limit` argument -- `citizenid` is k9_progression's own PRIMARY KEY
    --- (see QueryProgressionSnapshot's own doc comment above), so `rows` is
    --- always an array of 0 or 1 elements regardless of what any caller
    --- supplies.
    --- @param source number
    --- @param citizenid string?
    --- @return table { ok: boolean, rows: table?, label: string?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditXp', function(source, citizenid)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditXp', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditXp', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'tabletAuditXp', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local rows = QueryProgressionSnapshot(citizenid)
        local label = locale('admin.xp_snapshot_label', citizenid)

        LogAuditInvocation(source, 'tabletAuditXp', citizenid, 'ok')
        return { ok = true, rows = rows, label = label }
    end)

    --- 'qbx_k9unit:server:tabletAuditDept' -- mirrors '/k9auditdept'. See
    --- QueryDepartmentRoster above for the exact row shape returned
    --- (active roster only, same three columns idx_job_active's own doc
    --- comment names -- nothing wider).
    --- @param source number
    --- @param job string? -- must be a configured Config.Departments key
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditDept', function(source, job, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditDept', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditDept', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidDepartment(job) then
            LogAuditInvocation(source, 'tabletAuditDept', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit = ClampLimit(limit, Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryDepartmentRoster(job, clampedLimit)
        local label = locale('admin.dept_roster_label', job)

        LogAuditInvocation(source, 'tabletAuditDept', job, 'ok')
        return { ok = true, rows = rows, label = label }
    end)

    print('[qbx_k9unit] admin.lua: audit commands registered (k9auditcert, k9auditpartner, k9auditsearch, k9auditxp, k9auditdept); audit callbacks registered (tabletAuditCert, tabletAuditPartner, tabletAuditSearch, tabletAuditXp, tabletAuditDept).')
end)
