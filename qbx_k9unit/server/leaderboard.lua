--[[
    qbx_k9unit/server/leaderboard.lua

    Handler leaderboard / '/k9stats' -- FEATURE_IDEAS.md Part A Tier C
    §10. A pure, read-only ranking over `k9_progression` (server/
    progression.lua's own XP persistence table) -- no new state, no new
    write path, no new risk to the economy. Exactly matches this idea's
    own "Effort: small... zero value before Phase 4 exists to feed it"
    framing: Phase 4 (XPProgression) has shipped, so this is now buildable
    for real.

    ======================================================================
    QUERY SHAPE -- READ BEFORE TOUCHING sql/migrations/0009_*.

    `SELECT citizenid, xp FROM k9_progression ORDER BY xp DESC LIMIT ?`.
    `k9_progression` (sql/install.sql, server/progression.lua) had exactly
    ONE key before this pass -- `PRIMARY KEY (citizenid)` -- which has no
    bearing on an `ORDER BY xp` at all. A real EXPLAIN pass this session
    (per this task's own explicit instruction: measure, do not assume)
    confirmed the obvious consequence on a REAL MariaDB 10.11 instance and
    this session's own MySQL 5.7.44 / 8.0.46 containers, at 20,000 and
    150,000 synthetic rows: `type=ALL, rows=<table size>, Extra=Using
    filesort` -- a full table scan PLUS a sort of every row, on every
    single invocation, to return the top N. Exactly the anti-pattern this
    task named by example (an existing admin query filesorting 8,572 rows;
    a maintenance script full-scanning 150k) -- this file does not add a
    third instance of it. `sql/migrations/0009_add_k9_progression_idx_xp.sql`
    (+ matching `sql/rollback/0009_down.sql`) adds a plain `KEY idx_xp
    (xp)`, after which the SAME query measures `type=index, key=idx_xp,
    rows=<LIMIT>, Extra=Using index` on all three engines -- a pure
    covering-index scan (InnoDB secondary indexes always carry the table's
    primary key alongside the indexed column, so `idx_xp` alone already
    contains both columns this query selects) whose cost is the LIMIT, not
    the table size -- confirmed IDENTICAL `rows=50` at both 20,000 and
    150,000 rows. See that migration's own header for the full numbers.
    `sql/install.sql`'s own `k9_progression` CREATE TABLE is being updated
    in the same pass to carry this index directly, per this repo's
    established "install.sql has final shape, a migration backfills an
    existing DB" convention.

    Row LIMIT is embedded via string.format after being floor+range-clamped
    into `[1, HARD_MAX_RESULTS]` by ClampLimit below -- NEVER a raw
    caller-supplied value -- same disclosed reasoning server/admin.lua's own
    ClampLimit already documents in full (oxmysql's prepared-statement
    binding of a `LIMIT ?` placeholder specifically was never independently
    confirmed against a live oxmysql/mysql2 install in this codebase's own
    sandbox, so an already-clamped, server-produced plain Lua integer sidesteps
    that unconfirmed question entirely rather than assuming an answer).
    ClampLimit/HARD_MAX_RESULTS are duplicated here, not imported from
    server/admin.lua -- that file's own local helpers are unreachable from
    outside it (same "this file has no import mechanism to reach that one"
    reasoning server/progression.lua's own CopyTier comment already gives
    for its duplicate of server/exports.lua's ShallowCopyTier).

    DELIBERATELY REPORTS THE RAW `xp` INTEGER ONLY, NEVER A DERIVED TIER --
    same reasoning server/admin.lua's own `/k9auditxp` already documents for
    the identical table: recomputing server/progression.lua's `ResolveTier`
    threshold walk here would be a SECOND, driftable copy of that logic
    (and a real correctness trap this pass specifically ruled out for
    itself -- see "WHY NOT GetXPTier()" below), not a genuine
    'COMPUTES NOTHING NEW' wrapper. A player can compare a reported total
    against Config.XPTiers directly.

    WHY NOT GetXPTier() -- CONSIDERED AND REJECTED, NOT MERELY UNCONSIDERED:
    server/progression.lua's own `GetXPTier(citizenid)` reads the IN-MEMORY
    `K9XP` cache, which is explicitly evicted on `playerDropped` (that
    file's own bounded-memory-growth fix) -- an OFFLINE citizenid's cache
    entry does not exist, so `GetXPTier` would silently resolve them to the
    base tier regardless of their REAL, persisted `xp` value this query
    just read from the database. A leaderboard is precisely the case where
    most listed citizenids are offline at query time -- using GetXPTier
    here would have shown a genuine 9,000-XP Elite K9 as a 0-XP Recruit the
    moment they logged off, a real, silent, and actively misleading
    correctness bug, not a cosmetic one. Reporting the raw persisted `xp`
    integer instead is correct regardless of whether anyone listed is
    currently online.

    NEVER computes anything else, never mutates `k9_progression`, never
    calls AwardXP/AwardXPDirect -- this file's own scope is a single SELECT
    and its presentation, nothing more.
    ======================================================================

    ======================================================================
    ACCESS MODEL -- DECIDED, WITH THE PRIVACY QUESTION ANSWERED EXPLICITLY
    (this task's own instruction), NOT DEFAULTED EITHER WAY.

    Gated on `HasK9Access(source)` -- the caller must be a CURRENTLY VALID,
    certified K9/handler right now, the exact same gate the leash, radial,
    search and tracking mechanics already use for "is this a real, current
    member of the K9 unit." Deliberately NOT the audit surface's own,
    stricter `Config.Departments[job].auditGrade` senior-officer bar
    (server/admin.lua) -- these are two genuinely different privacy
    questions, decided differently on purpose:

      - server/admin.lua's audit commands expose WHO SEARCHED WHOM, WHEN,
        AND WITH WHAT RESULT -- real investigative data about THIRD
        PARTIES (search targets, many of whom are not K9 unit members at
        all), which is why that surface earned a senior-officer bar the
        first time this resource ever needed one (that file's own header:
        "a genuine privacy-sensitive dataset -- who searched whom").
      - `/k9stats` exposes a citizenid + an aggregate lifetime XP total for
        members of the K9 UNIT ITSELF -- no target identity, no incident
        detail, no "what did this K9 do and to whom" content of any kind.
        It is the K9-unit-scoped equivalent of a job scoreboard, not a case
        file. The information disclosed is comparable to what any
        department roster/leaderboard already surfaces in comparable FiveM
        PD resources, and is explicitly the kind of "reliable engagement/
        retention hook" FEATURE_IDEAS.md's own write-up names as this
        idea's value.
      - CONCRETE PRECEDENT ALREADY SET BY THIS RESOURCE, NOT INVENTED HERE:
        server/exports.lua's `GetXP`/`GetXPTier` exports already hand any
        co-located resource, for ANY caller-supplied citizenid, with NO
        gating check of any kind (that file's own header: "NOT gated by
        any Config.Features flag... an export diverging from its own
        wrapped function's real behavior would be a worse bug than not
        gating at all"). A single citizenid's XP total is therefore
        ALREADY exposed, resource-wide, with zero access check, to any
        other resource on the server. Gating `/k9stats` behind
        HasK9Access(source) is STRICTLY MORE conservative than that
        already-shipped, already-reviewed surface -- this command narrows
        who can see a RANKED VIEW of the same class of data the export
        surface already hands out unconditionally, it does not widen
        anything.

    Not open to the whole server (a random citizen with no K9 affiliation
    at all has no legitimate reason to see the department's internal
    leaderboard), and not restricted to senior officers either (nothing
    here is a records-lookup or a supervisory function -- every current
    handler/K9 is a legitimate audience for "how do I rank against my own
    unit").

    CONSOLE (source == 0): no special carve-out, unlike server/admin.lua's
    TrustConsole flag. HasK9Access(0) resolves via
    exports.qbx_core:GetPlayer(0), which has no real player/job to check --
    it naturally, structurally returns false, the same fail-closed result
    every other HasK9Access(0) call site in this resource already gets
    with no special-casing. This is correct for THIS command specifically
    (unlike server/admin.lua's audit surface, "console" has no legitimate
    reason to want a K9 leaderboard at all), so no TrustConsole-style
    opt-in is added.
    ======================================================================

    RATE LIMITING: one NewCooldown() instance, keyed by the CALLER's own
    source (server/cooldowns.lua, REFACTOR_ROADMAP.md item 1's own
    "shared constructor, not a hand-rolled table" convention) -- a DB-load/
    spam guard, not an authorization boundary, same posture
    server/admin.lua's own AuditCooldown documents for its own five
    commands.

    FILE-TO-FILE CONTRACT:
    - Calls `HasK9Access(source)` (server/certifications.lua) via a
      `type(...) == 'function'` runtime existence guard -- this resource's
      established soft-dependency convention, not a load-order assumption.
      Missing/false is a hard deny (fail closed).
    - Calls `NewCooldown()` (server/cooldowns.lua) at THIS file's own
      file-load time -- must load after server/cooldowns.lua in
      fxmanifest.lua's server_scripts, same requirement every other
      consumer already states.
    - Calls `NotifyPlayer` (server/notify.lua) -- must load after that
      file, same as every other consumer.
    - Performs ONE SELECT-only query against `k9_progression` -- never
      INSERTs/UPDATEs/DELETEs anything, never calls AwardXP/AwardXPDirect,
      never calls GetXP/GetXPTier (see "WHY NOT GetXPTier()" above).
    - Exposes no resource-global function of its own -- nothing else in
      this resource needs to call into a leaderboard query.
    ======================================================================

    CONFIG THIS FILE ASSUMES EXISTS -- NOT owned by this file for this task
    (coder-backend does not own config.lua here; reported separately). A
    missing `Config.Features.K9Leaderboard` is treated as `false` (command
    never registered at all, matching server/admin.lua's own
    AdminAuditCommands registration-time gate convention) -- every OTHER
    field below degrades to a safe, loudly-logged built-in default rather
    than erroring (same softer, server/recall.lua-style posture
    server/training.lua's own header already argues for and for the
    identical reason: a broken config here has no security/economy
    consequence, only a wrong default row count/cooldown, so this does not
    need admin.lua's harder assert-at-startup posture):
      Config.Features.K9Leaderboard    : boolean (new; default false)
      Config.Leaderboard.MaxRows       : integer (new; built-in fallback 20 if missing/invalid)
      Config.Leaderboard.CommandCooldownMs : number (new; built-in fallback 5000 if missing/invalid)
]]

if not (Config.Features and Config.Features.K9Leaderboard == true) then return end

-- Hard ceiling enforced regardless of what Config.Leaderboard.MaxRows is
-- configured to -- same "config is a tunable, not a bypass" posture as
-- server/admin.lua's own HARD_MAX_RESULTS.
local HARD_MAX_RESULTS = 100

local MAX_ROWS_FALLBACK = 20
local COOLDOWN_FALLBACK_MS = 5000

local leaderboardCfg = Config.Leaderboard
local defaultMaxRows = MAX_ROWS_FALLBACK
local cooldownMs = COOLDOWN_FALLBACK_MS

if type(leaderboardCfg) == 'table' then
    if type(leaderboardCfg.MaxRows) == 'number' and leaderboardCfg.MaxRows >= 1 and leaderboardCfg.MaxRows == math.floor(leaderboardCfg.MaxRows) then
        defaultMaxRows = math.min(leaderboardCfg.MaxRows, HARD_MAX_RESULTS)
    else
        print(('[qbx_k9unit] leaderboard: Config.Leaderboard.MaxRows is missing or not a positive integer; using a built-in %d default instead.'):format(MAX_ROWS_FALLBACK))
    end

    if type(leaderboardCfg.CommandCooldownMs) == 'number' and leaderboardCfg.CommandCooldownMs > 0 then
        cooldownMs = leaderboardCfg.CommandCooldownMs
    else
        print(('[qbx_k9unit] leaderboard: Config.Leaderboard.CommandCooldownMs is missing or not a positive number; using a built-in %dms default instead.'):format(COOLDOWN_FALLBACK_MS))
    end
else
    print('[qbx_k9unit] leaderboard: Config.Leaderboard is missing entirely; using built-in row-count/cooldown defaults. Add the Config.Leaderboard block from config.lua to configure these.')
end

local StatsCooldown = NewCooldown(cooldownMs)
StatsCooldown.RegisterPlayerDropped()

--- Parses and clamps an optional caller-supplied result-count argument.
--- Identical shape/reasoning to server/admin.lua's own ClampLimit --
--- duplicated here, not imported (see this file's header). Never trusts
--- the raw value directly into a query -- always returns a plain Lua
--- integer already clamped into [1, HARD_MAX_RESULTS].
--- @param rawArg string? -- args[1] from the RegisterCommand handler, or nil
--- @return number limit
local function ClampLimit(rawArg)
    local parsed = tonumber(rawArg) or defaultMaxRows
    parsed = math.floor(parsed)
    if parsed < 1 then return 1 end
    if parsed > HARD_MAX_RESULTS then return HARD_MAX_RESULTS end
    return parsed
end

--- '/k9stats' query -- see this file's header "QUERY SHAPE" for the full
--- index/EXPLAIN rationale. `limit` is already clamped by ClampLimit
--- above before it ever reaches this function.
--- @param limit number
--- @return table rows
local function QueryTopXp(limit)
    local ok, rowsOrErr = pcall(K9Store.XP_GetTop, limit)
    if not ok then
        print(('[qbx_k9unit] leaderboard: query failed: %s'):format(tostring(rowsOrErr)))
        return {}
    end
    return rowsOrErr or {}
end

-- How many formatted rows are batched into a single ox_lib toast -- same
-- constant/reasoning as server/admin.lua's own ROWS_PER_NOTIFY_CHUNK.
local ROWS_PER_NOTIFY_CHUNK = 5

RegisterCommand('k9stats', function(source, args)
    if type(HasK9Access) ~= 'function' or not HasK9Access(source) then
        if source ~= 0 then
            NotifyPlayer(source, locale('leaderboard.no_access'), 'error')
        end
        return
    end

    if not StatsCooldown.Consume(source) then
        return -- silent no-op: rate-limited, matches this resource's established spam-guard convention
    end

    local limit = ClampLimit(args[1])
    local rows = QueryTopXp(limit)

    if #rows == 0 then
        NotifyPlayer(source, locale('leaderboard.no_results'), 'info')
        return
    end

    NotifyPlayer(source, locale('leaderboard.title', #rows), 'info')

    local lines = {}
    for i, row in ipairs(rows) do
        lines[#lines + 1] = locale('leaderboard.row_format', i, tostring(row.citizenid), tostring(row.xp))
        if #lines >= ROWS_PER_NOTIFY_CHUNK or i == #rows then
            NotifyPlayer(source, table.concat(lines, '\n'), 'info')
            lines = {}
        end
    end
end, false)
