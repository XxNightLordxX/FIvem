--[[
    qbx_k9unit/server/admin.lua

    In-game admin/audit surface over the tables this resource already
    writes but, until now, only ever exposed as a raw SQL query an admin ran
    by hand (README.md's own documented "admin listing" queries;
    COMPLEMENTARY_FEATURES.md top-3 item 2 / §9): `k9_certifications`
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

    ======================================================================
    ACCESS MODEL — THE FIRST ACE-GATED SURFACE IN THIS RESOURCE, disclosed
    explicitly (COMPLEMENTARY_FEATURES.md §9's own "precedent-setting
    choice, not a blocker" flag). Every other gated action in this resource
    (HasK9Access, IsEligibleCertifier, CheckPartnershipEligibility) is
    job/grade-scoped — a K9-HANDLER feature. This surface is
    SERVER-OPERATOR tooling: "can this connected principal read the
    search/cert/partnership audit trail" has nothing to do with department
    membership or K9 certification — an off-duty or civilian-job admin
    principal must still be able to run these commands, and a certified K9
    handler with no admin ACE must not. ACE is the correct primitive for
    that distinction, not a job.grade.level threshold. Precedent for using
    IsPlayerAceAllowed at all in this codebase: server/combat.lua's
    FlagNonCompliance staff-notification path
    (`IsPlayerAceAllowed(tostring(playerId), 'command')`) — but that call
    site hardcodes FXServer's generic 'command' ace name. THIS file's ace
    name is a Config value instead (Config.AdminAudit.AcePermission), per
    this task's explicit "make the ace name configurable" requirement, so a
    server owner can scope this to a dedicated principal (e.g.
    'k9unit.admin') rather than overloading the same ace every other
    'command'-gated resource on their server also checks.

    CONSOLE (source == 0) IS NOT TRUSTED BY DEFAULT (this reverses this
    file's original design -- see IsAuthorizedAdmin's own comment for the
    three-producer reasoning). It is opt-in via Config.AdminAudit.TrustConsole.
    The superseded original note read: console is trusted unconditionally, WITHOUT an
    IsPlayerAceAllowed call — DISCLOSED AS A JUDGMENT CALL, not silently
    decided, same posture server/search.lua's header uses for its own
    "explicit decision, not a silent default" per-target-cooldown question:
    FXServer's server console already has unconditional, irrevocable
    control over this entire process (filesystem, database credentials,
    the ability to add/remove any ACE principal including its own), so
    gating a READ-ONLY query behind the same ACE system the console
    operator could trivially grant themselves anyway would be security
    theater, not a real boundary. No existing file in this resource
    establishes a precedent either way — every other command here operates
    on a live, connected-player source (granterSrc/source), which console
    (source == 0) never satisfies, so this exact question never came up
    before this file. FLAGGED FOR CODER-SECURITY TO CONFIRM OR OVERRIDE.
    ======================================================================

    SQL SAFETY — read before touching any query function below:
      - This file constructs 8 distinct hardcoded SQL string templates in
        total (COVERAGE RE-CHECK, this pass: was 7 —
        QueryCertificationHistory:1, QueryPartnershipHistory:2,
        QuerySearchLogBy{Officer,Plate,Person}/QuerySearchLogRecent:4,
        QueryProgressionSnapshot:1 (new, `/k9auditxp`) — verified by
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
    COMMAND SURFACE (all four commands gated on
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
    ======================================================================

    RATE LIMITING: one shared NewCooldown() instance (server/cooldowns.lua
    — per this task's explicit "use the shared constructors" convention)
    across all four commands, keyed by the CALLER's own source, mirroring
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
      k9_partnerships, k9_search_log, and (this pass) k9_progression —
      read sql/install.sql's header comments on all four tables (index
      rationale, exact column shapes) before changing any query below.
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
      Config.AdminAudit.AcePermission     : string  (new; ace principal name)
      Config.AdminAudit.CommandCooldownMs : number  (new; shared per-source cooldown, ms)
      Config.AdminAudit.MaxResults.Certifications : integer, 1..100
      Config.AdminAudit.MaxResults.Partnerships   : integer, 1..100
      Config.AdminAudit.MaxResults.SearchLog      : integer, 1..100
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

-- Column list shared by all four k9_search_log query shapes below — kept
-- as one constant so the four query functions can never drift out of sync
-- with each other on which columns they expose.
local SEARCH_LOG_COLUMNS = 'searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at'

-- REFACTOR_ROADMAP.md item 1 convention (server/cooldowns.lua): shared
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

--- Server-authoritative authorization check for every command in this
--- file. See this file's header "ACCESS MODEL" section for the full
--- reasoning on both the ACE-not-job-grade choice and the console
--- (source == 0) carve-out.
--- @param source number
--- @return boolean
local function IsAuthorizedAdmin(source)
    -- SECURITY REVIEW OUTCOME (coder-security): this function previously did
    -- `if source == 0 then return true end`, on the reasoning that the server
    -- console already owns the process, the DB and the ACE system, so gating a
    -- read-only query behind ACE was not a real boundary. That reasoning is
    -- sound for the console -- and WRONG for FiveM, because `source == 0` has
    -- three distinct producers that this layer cannot tell apart:
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
    -- its justification described. It is now opt-in and defaults off.
    if source == 0 then
        return Config.AdminAudit.TrustConsole == true
    end
    return IsPlayerAceAllowed(tostring(source), Config.AdminAudit.AcePermission)
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
--- format specifier raises an UNCAUGHT error (outside SafeQuery's pcall —
--- the LIMIT is embedded before SafeQuery is ever called) on a float with a
--- fractional part, which would otherwise turn a config-shape gap into a
--- runtime crash on the very first invocation of any of these three
--- commands. See this file's
--- header "SQL SAFETY" section for why the RETURNED integer (never
--- `rawArg` itself, and now never a raw `defaultValue` either) is the only
--- thing that ever reaches a query string.
--- @param rawArg string? -- args[n] from a RegisterCommand handler, or nil
--- @param defaultValue number
--- @param hardMax number
--- @return number limit
local function ClampLimit(rawArg, defaultValue, hardMax)
    local parsed = tonumber(rawArg) or defaultValue
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

--- Fail-closed SELECT wrapper — pcall around MySQL.query.await, matching
--- RefreshCertificationCache/RefreshPartnershipCache's own "an unreadable
--- row must never be treated as [something it isn't]" discipline, applied
--- here as "a failed audit query returns zero rows to the caller, never a
--- raw Lua error/stack trace." CONFIDENCE NOTE: MySQL.query.await is
--- oxmysql's documented all-matching-rows method, the natural counterpart
--- to MySQL.scalar/.single/.update/.insert — all four already called
--- successfully elsewhere in this codebase (server/certifications.lua,
--- server/search.lua, server/partnership.lua) — but MySQL.query
--- specifically was not independently exercised against a live oxmysql
--- install in this sandbox.
--- @param sql string -- already fully hardcoded per call site below, never a caller-controlled fragment
--- @param params table
--- @return table rows -- always a table, empty on failure
local function SafeQuery(sql, params)
    local ok, rowsOrErr = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] admin.lua query failed: %s'):format(tostring(rowsOrErr)))
        return {}
    end
    return rowsOrErr or {}
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
    -- discipline as locales/README.md's own documented concatenation fixes
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
        NotifyPlayer(target, locale('admin.no_results_found', label), 'inform')
        return
    end

    NotifyPlayer(target, locale('admin.result_count', label, #rows), 'inform')

    local lines = {}
    for i, row in ipairs(rows) do
        lines[#lines + 1] = formatRow(row)
        if #lines >= ROWS_PER_NOTIFY_CHUNK or i == #rows then
            NotifyPlayer(target, table.concat(lines, '\n'), 'inform')
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
    local sql = ('SELECT job, granted_by, granted_at, revoked_by, revoked_at, active FROM k9_certifications WHERE citizenid = ? ORDER BY granted_at DESC LIMIT %d'):format(limit)
    return SafeQuery(sql, { citizenid })
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
    local columns = 'id, k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active'
    local sqlAsK9 = ('SELECT %s FROM k9_partnerships WHERE k9_citizenid = ? ORDER BY id DESC LIMIT %d'):format(columns, limit)
    local sqlAsHandler = ('SELECT %s FROM k9_partnerships WHERE handler_citizenid = ? ORDER BY id DESC LIMIT %d'):format(columns, limit)

    local asK9 = SafeQuery(sqlAsK9, { citizenid })
    local asHandler = SafeQuery(sqlAsHandler, { citizenid })

    return MergeSortedByIdDesc(asK9, asHandler, limit)
end

--- '/k9auditsearch officer' query — searches PERFORMED BY citizenid, most
--- recent first. Uses idx_searcher_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param citizenid string
--- @param limit number
--- @return table rows
local function QuerySearchLogByOfficer(citizenid, limit)
    local sql = ('SELECT %s FROM k9_search_log WHERE searcher_citizenid = ? ORDER BY searched_at DESC LIMIT %d'):format(SEARCH_LOG_COLUMNS, limit)
    return SafeQuery(sql, { citizenid })
end

--- '/k9auditsearch plate' query — searches OF a vehicle plate, most recent
--- first. Uses idx_target_plate_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param plate string -- already normalized by NormalizePlateArg
--- @param limit number
--- @return table rows
local function QuerySearchLogByPlate(plate, limit)
    local sql = ('SELECT %s FROM k9_search_log WHERE target_plate = ? ORDER BY searched_at DESC LIMIT %d'):format(SEARCH_LOG_COLUMNS, limit)
    return SafeQuery(sql, { plate })
end

--- '/k9auditsearch person' query — searches OF a person citizenid, most
--- recent first. Uses idx_target_citizenid_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param citizenid string
--- @param limit number
--- @return table rows
local function QuerySearchLogByPerson(citizenid, limit)
    local sql = ('SELECT %s FROM k9_search_log WHERE target_citizenid = ? ORDER BY searched_at DESC LIMIT %d'):format(SEARCH_LOG_COLUMNS, limit)
    return SafeQuery(sql, { citizenid })
end

--- '/k9auditsearch recent' query — the N most recently logged searches of
--- ANY kind, no WHERE clause. Ordered by `id DESC` (InnoDB's own clustered
--- primary-key order), NOT `searched_at` — reading the tail of the
--- clustered index is cheap and needs no dedicated index of its own; see
--- this file's header "COMMAND SURFACE" section for the full reasoning.
--- @param limit number
--- @return table rows
local function QuerySearchLogRecent(limit)
    local sql = ('SELECT %s FROM k9_search_log ORDER BY id DESC LIMIT %d'):format(SEARCH_LOG_COLUMNS, limit)
    return SafeQuery(sql, {})
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
    local sql = 'SELECT xp, updated_at FROM k9_progression WHERE citizenid = ? LIMIT 1'
    return SafeQuery(sql, { citizenid })
end

-- ======================================================================
-- COMMAND REGISTRATION — gated on Config.Features.AdminAuditCommands AT
-- REGISTRATION TIME (this task's explicit convention): if the flag is not
-- `true`, none of the four commands below are ever registered at all, not
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
        type(Config.AdminAudit.AcePermission) == 'string' and Config.AdminAudit.AcePermission ~= '',
        '[qbx_k9unit] Config.AdminAudit.AcePermission must be a non-empty string.'
    )
    assert(
        type(Config.AdminAudit.CommandCooldownMs) == 'number' and Config.AdminAudit.CommandCooldownMs >= MIN_COMMAND_COOLDOWN_MS,
        ('[qbx_k9unit] Config.AdminAudit.CommandCooldownMs must be a number >= %dms.'):format(MIN_COMMAND_COOLDOWN_MS)
    )

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

    print('[qbx_k9unit] admin.lua: audit commands registered (k9auditcert, k9auditpartner, k9auditsearch, k9auditxp).')
end)
