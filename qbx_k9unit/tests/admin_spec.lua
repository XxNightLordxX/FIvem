--[[
    tests/admin_spec.lua

    Indirect tests of server/admin.lua's local helpers (ClampLimit,
    IsValidCitizenId, NormalizePlateArg, IsAuthorizedAdmin,
    MergeSortedByIdDesc) against the REAL, unmodified production file.

    These five are all `local` -- unreachable directly from outside the
    file (per this suite's "do not modify production files to make them
    testable" constraint). They ARE reachable indirectly, the same way a
    real caller reaches them: by loading the whole file into a sandbox,
    firing 'onResourceStart' (as FXServer would) to register its three
    RegisterCommand handlers, invoking those handlers exactly as
    RegisterCommand would (source, args), and asserting on the observable
    side effects those locals gate/shape: the numeric LIMIT actually
    embedded in the SQL text handed to MySQL.query.await (ClampLimit), the
    usage-error vs. real-query branch taken (IsValidCitizenId/
    NormalizePlateArg), whether a query runs at all (IsAuthorizedAdmin),
    and the merged/sorted/truncated row set handed to PresentRows
    (MergeSortedByIdDesc).

    ClampLimit specifically was flagged upstream as a place a review found
    it could pass a non-integer to string.format('%d') and throw -- see the
    "ClampLimit: hostile numeric inputs" block below for the nan/inf/
    1e400/float/negative battery this locks in as a regression suite,
    exercised through the REAL code path (a real RegisterCommand handler,
    real ClampLimit, real string.format LIMIT embed), not a reimplementation.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer()
    return fakeNow
end

local registeredCommands = {}
local function RegisterCommand(name, handler, _restricted)
    registeredCommands[name] = handler
end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName()
    return 'qbx_k9unit'
end

-- IsPlayerAceAllowed stub: test-controlled per tostring(source).
local aceGrants = {}
local function IsPlayerAceAllowed(sourceIdStr, _ace)
    return aceGrants[sourceIdStr] == true
end

-- exports.qbx_core:GetPlayer(source) stub -- used only by LogAuditInvocation
-- to resolve a citizenid for the console log line; nil is a valid/expected
-- "unresolved source" response.
local playersBySource = {}
local exportsStub = {
    qbx_core = {
        GetPlayer = function(_self, src)
            return playersBySource[src]
        end,
    },
}

-- MySQL.query.await stub: records every query, and lets each test swap in a
-- `fixtureResponder(sql, params)` to hand back canned rows keyed off the
-- REAL SQL text the production file generates (never a duplicated/
-- reimplemented decision of which query "should" run).
local capturedQueries = {}
local fixtureResponder = nil
local MySQLStub = {
    query = {
        await = function(sql, params)
            capturedQueries[#capturedQueries + 1] = { sql = sql, params = params }
            if fixtureResponder then
                return fixtureResponder(sql, params) or {}
            end
            return {}
        end,
    },
}

-- NotifyPlayer stub: server/admin.lua's local NotifyPlayer wrapper calls
-- `_G.NotifyPlayer(...)` explicitly (see that file's own header on why) --
-- Sandbox.newEnv points env._G at env itself, so this is what it reaches.
local capturedNotifications = {}
local function NotifyPlayerStub(target, description, notifyType, title)
    capturedNotifications[#capturedNotifications + 1] = {
        target = target, description = description, notifyType = notifyType, title = title,
    }
end

-- print stub: captures every line admin.lua prints (LogAuditInvocation's
-- audit trail, PrintRowsToConsole's console presentation, usage errors
-- printed for source == 0) so specs can assert on them without spamming
-- test output.
local capturedPrints = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring(select(i, ...))
    end
    capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
end

local Config = {
    Features = { AdminAuditCommands = true },
    AdminAudit = {
        AcePermission = 'k9unit.admin',
        CommandCooldownMs = 300,
        TrustConsole = false,
        MaxResults = { Certifications = 50, Partnerships = 50, SearchLog = 50 },
    },
    -- Only what IsValidDepartment needs (`Config.Departments[job] ~= nil`) --
    -- a single real-shaped entry ('police', matching config.lua's own key
    -- name) plus the absence of any 'ambulance' entry is enough to exercise
    -- both the valid and unconfigured-department branches below.
    Departments = {
        police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, autoAccessGrade = nil },
    },
}

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    RegisterCommand = RegisterCommand,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    IsPlayerAceAllowed = IsPlayerAceAllowed,
    exports = exportsStub,
    MySQL = MySQLStub,
    NotifyPlayer = NotifyPlayerStub,
    print = printStub,
    Config = Config,
})

-- server/admin.lua calls NewCooldown() at file-load time (AuditCooldown) --
-- must load server/cooldowns.lua into the SAME env first, same load-order
-- requirement fxmanifest.lua's own server_scripts list documents.
Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/admin.lua', env)

-- Fire 'onResourceStart' as FXServer would -- this is what actually
-- registers the three commands (gated at registration time, per the
-- production file's own header).
for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('qbx_k9unit')
end

t.isNotNil(registeredCommands.k9auditcert, 'onResourceStart must register k9auditcert')
t.isNotNil(registeredCommands.k9auditpartner, 'onResourceStart must register k9auditpartner')
t.isNotNil(registeredCommands.k9auditsearch, 'onResourceStart must register k9auditsearch')
-- The original 28 cases never asserted these two -- added here (not a
-- behavior change to any existing case) since this pass adds real coverage
-- of both commands below.
t.isNotNil(registeredCommands.k9auditxp, 'onResourceStart must register k9auditxp')
t.isNotNil(registeredCommands.k9auditdept, 'onResourceStart must register k9auditdept')

--- Test helper: runs one command invocation from a FRESH, always-authorized,
--- never-previously-rate-limited source (a new integer every call), so each
--- test case is isolated from AuditCooldown's shared per-source state
--- without needing to fast-forward the fake clock. Returns nothing; inspect
--- capturedQueries/capturedNotifications/capturedPrints afterward.
local nextSource = 1000
--- Authorization moved from an ACE grant to police job rank on 2026-08-25.
--- IsAuthorizedAdmin no longer calls IsPlayerAceAllowed at all, so granting
--- an ACE here would authorize nothing. A source is now authorized by having
--- a resolvable player whose job is a configured department at or above that
--- department's auditGrade -- grade 4 against the fixture's police entry.
local function freshAuthorizedSource()
    nextSource = nextSource + 1
    playersBySource[nextSource] = {
        PlayerData = {
            citizenid = 'CIT' .. tostring(nextSource),
            job = { name = 'police', grade = { level = 4 } },
        },
    }
    return nextSource
end

local function resetCaptures()
    capturedQueries = {}
    capturedNotifications = {}
    capturedPrints = {}
    fixtureResponder = nil
end

-- ----------------------------------------------------------------------
-- ClampLimit: hostile numeric inputs, exercised through the real
-- RegisterCommand handler + real string.format LIMIT embed.
-- ----------------------------------------------------------------------

--- @param limitArg string?
--- @return number embeddedLimit
local function clampLimitViaCommand(limitArg)
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditcert(src, { 'ABCD1234', limitArg })
    t.equals(#capturedQueries, 1, 'a valid citizenid + authorized source must reach exactly one query')
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.isNotNil(limitStr, 'query SQL must contain a plain integer LIMIT: ' .. tostring(capturedQueries[1].sql))
    return tonumber(limitStr)
end

t.test('ClampLimit: nil arg falls back to the configured default (50)', function()
    t.equals(clampLimitViaCommand(nil), 50)
end)

t.test('ClampLimit: non-numeric garbage falls back to the configured default', function()
    t.equals(clampLimitViaCommand('abc'), 50)
end)

t.test('ClampLimit: "nan" never reaches string.format unclamped (PUC Lua tonumber("nan") is nil here)', function()
    -- Locks in current observed behavior as a regression guard: if a future
    -- Lua build's tonumber("nan") ever returns a real NaN instead of nil,
    -- this test starts failing LOUDLY (an uncaught error via
    -- string.format('%d', nan)) instead of the bug silently reappearing.
    t.equals(clampLimitViaCommand('nan'), 50)
end)

t.test('ClampLimit: "-nan" behaves the same as "nan"', function()
    t.equals(clampLimitViaCommand('-nan'), 50)
end)

t.test('ClampLimit: "inf" falls back to default, never reaches string.format as infinity', function()
    t.equals(clampLimitViaCommand('inf'), 50)
end)

t.test('ClampLimit: "1e400" (numeric overflow to +inf) clamps to hardMax (100), never crashes', function()
    t.equals(clampLimitViaCommand('1e400'), 100)
end)

t.test('ClampLimit: "-1e400" (overflow to -inf) clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('-1e400'), 1)
end)

t.test('ClampLimit: a fractional value is floored, not rejected', function()
    t.equals(clampLimitViaCommand('3.9'), 3)
end)

t.test('ClampLimit: a negative value clamps to the floor (1), not passed through negative', function()
    t.equals(clampLimitViaCommand('-5'), 1)
end)

t.test('ClampLimit: zero clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('0'), 1)
end)

t.test('ClampLimit: a value above hardMax clamps down to 100, never embeds the raw huge number', function()
    t.equals(clampLimitViaCommand('999999'), 100)
end)

t.test('ClampLimit: a normal in-range integer passes through unchanged', function()
    t.equals(clampLimitViaCommand('7'), 7)
end)

t.test('ClampLimit: whitespace-padded numeric strings are still parsed', function()
    t.equals(clampLimitViaCommand('  10  '), 10)
end)

-- ----------------------------------------------------------------------
-- IsValidCitizenId gating (k9auditcert / k9auditpartner / k9auditsearch
-- officer|person): malformed input must never reach a query at all.
-- ----------------------------------------------------------------------

t.test('IsValidCitizenId: empty string is rejected before any query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditcert(src, { '' })
    t.equals(#capturedQueries, 0, 'an invalid citizenid must never reach MySQL.query.await')
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'Usage:')
end)

t.test('IsValidCitizenId: missing arg (nil) is rejected before any query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditcert(src, {})
    t.equals(#capturedQueries, 0)
end)

t.test('IsValidCitizenId: a value over 50 chars (VARCHAR(50) column width) is rejected', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditcert(src, { string.rep('x', 51) })
    t.equals(#capturedQueries, 0)
end)

t.test('IsValidCitizenId: exactly 50 chars is accepted (boundary)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditcert(src, { string.rep('x', 50) })
    t.equals(#capturedQueries, 1)
end)

-- ----------------------------------------------------------------------
-- NormalizePlateArg gating (k9auditsearch plate)
-- ----------------------------------------------------------------------

t.test('NormalizePlateArg: whitespace is trimmed and the TRIMMED value reaches the query params', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'plate', '  ABC 123  ' })
    t.equals(#capturedQueries, 1)
    t.equals(capturedQueries[1].params[1], 'ABC 123')
end)

t.test('NormalizePlateArg: an all-whitespace plate is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'plate', '   ' })
    t.equals(#capturedQueries, 0)
end)

t.test('NormalizePlateArg: over 15 chars (VARCHAR(15) column width) is rejected', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'plate', string.rep('P', 16) })
    t.equals(#capturedQueries, 0)
end)

t.test('IsValidSearchLogModes: an unrecognized mode is rejected before any query, before even inspecting value', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'DROP TABLE k9_search_log', 'x' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage:')
end)

-- ----------------------------------------------------------------------
-- IsAuthorizedAdmin: access control, checked BEFORE argument validity
-- ----------------------------------------------------------------------

t.test('IsAuthorizedAdmin: a source with no resolvable player record is denied, no query ever runs', function()
    resetCaptures()
    local src = 9001
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: denial is checked before argument shape (malformed args never even inspected)', function()
    resetCaptures()
    local src = 9002
    -- Deliberately malformed AND unauthorized: if auth were checked after
    -- args, this would fail on citizenid validity with an 'invalid_args'
    -- audit outcome instead of 'denied'.
    registeredCommands.k9auditcert(src, {})
    t.equals(#capturedPrints, 1)
    t.contains(capturedPrints[1], 'denied')
    t.notContains(capturedPrints[1], 'invalid_args')
end)

t.test('IsAuthorizedAdmin: console (source == 0) is denied by default (TrustConsole == false)', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = false
    registeredCommands.k9auditcert(0, { 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    -- source == 0 has no client to notify -- the denial surfaces via
    -- LogAuditInvocation's print(), not NotifyPlayer.
    t.equals(#capturedNotifications, 0)
    t.contains(capturedPrints[1], 'denied')
end)

t.test('IsAuthorizedAdmin: console (source == 0) is allowed once TrustConsole is opted in', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = true
    registeredCommands.k9auditcert(0, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    Config.AdminAudit.TrustConsole = false -- restore for subsequent tests
end)

--- Registers a player record of an ARBITRARY shape at a fresh source, so the
--- cases below can drive IsAuthorizedAdmin's job-rank branches directly
--- rather than only its always-authorized happy path.
--- @param playerData table? the PlayerData table to expose, or nil for "no record"
--- @return number source
local function freshSourceWithPlayerData(playerData)
    nextSource = nextSource + 1
    if playerData ~= nil then
        playersBySource[nextSource] = { PlayerData = playerData }
    end
    return nextSource
end

t.test('IsAuthorizedAdmin: a job that is not a configured K9 department is denied', function()
    resetCaptures()
    -- 'ambulance' is deliberately absent from the Config.Departments fixture.
    -- Grade 10 is far above any auditGrade -- rank must not substitute for
    -- being in a K9 department at all.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITAMB1',
        job = { name = 'ambulance', grade = { level = 10 } },
    })
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: a configured department at a grade BELOW auditGrade is denied', function()
    resetCaptures()
    -- The fixture's police auditGrade is 4; grade 3 is one short. This is the
    -- case that proves the threshold is really compared, not merely that a
    -- configured department was found.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITLOW1',
        job = { name = 'police', grade = { level = 3 } },
    })
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: job.isboss authorizes regardless of grade level', function()
    resetCaptures()
    -- Grade 0 is below auditGrade 4, but qbx_core's isboss flag marks a job
    -- owner -- they are authorized without meeting the numeric threshold.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITBOSS',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)
end)

t.test('IsAuthorizedAdmin: a non-number job.grade.level fails CLOSED, it does not throw', function()
    resetCaptures()
    -- A hand-corrupted DB row (or a future qbx_core shape change) could hand
    -- back a string where a number is expected. A `>=` against a string would
    -- raise an uncaught 'attempt to compare' error inside the command
    -- handler; the guard must deny instead. pcall proves no error escapes.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITBAD1',
        job = { name = 'police', grade = { level = '4' } },
    })
    local ok, err = pcall(registeredCommands.k9auditcert, src, { 'ABCD1234' })
    t.isTrue(ok, 'a non-number grade level must not raise: ' .. tostring(err))
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: a job table with no grade sub-table at all fails CLOSED', function()
    resetCaptures()
    local src = freshSourceWithPlayerData({
        citizenid = 'CITNOG1',
        job = { name = 'police' },
    })
    local ok, err = pcall(registeredCommands.k9auditcert, src, { 'ABCD1234' })
    t.isTrue(ok, 'a missing grade table must not raise: ' .. tostring(err))
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: a player record with no job at all fails CLOSED', function()
    resetCaptures()
    local src = freshSourceWithPlayerData({ citizenid = 'CITNOJ1' })
    local ok, err = pcall(registeredCommands.k9auditcert, src, { 'ABCD1234' })
    t.isTrue(ok, 'a missing job table must not raise: ' .. tostring(err))
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

-- ----------------------------------------------------------------------
-- Rate limiting: AuditCooldown shared across all three commands, keyed by
-- the caller's own source.
-- ----------------------------------------------------------------------

t.test('Rate limiting: a second command from the same source inside the cooldown window is denied', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 0
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 100 -- still within Config.AdminAudit.CommandCooldownMs (300)
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'the rate-limited second call must not reach a query')
    t.contains(capturedPrints[#capturedPrints], 'rate_limited')

    fakeNow = 400 -- now past the 300ms cooldown
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 2, 'a call after the cooldown window has elapsed must succeed')
end)

t.test('Rate limiting: is shared ACROSS commands for the same source, not per-command', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 1000
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 1050 -- within cooldown
    registeredCommands.k9auditpartner(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'k9auditpartner must be rate-limited by k9auditcert\'s own recent call from the same source')
end)

-- ----------------------------------------------------------------------
-- MergeSortedByIdDesc (k9auditpartner): two independently-LIMITed row sets,
-- one per unique index, merged and re-sorted by id DESC, then truncated.
-- ----------------------------------------------------------------------

t.test('MergeSortedByIdDesc: merges both role queries, sorts by id DESC, truncates to limit', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('k9_citizenid = ?', 1, true) then
            return {
                { id = 2, k9_citizenid = 'K9-2', handler_citizenid = 'H', active = 1 },
                { id = 5, k9_citizenid = 'K9-5', handler_citizenid = 'H', active = 1 },
            }
        elseif sql:find('handler_citizenid = ?', 1, true) then
            return {
                { id = 8, k9_citizenid = 'K9-8', handler_citizenid = 'H', active = 0 },
                { id = 1, k9_citizenid = 'K9-1', handler_citizenid = 'H', active = 0 },
            }
        end
        return {}
    end

    local src = freshAuthorizedSource()
    registeredCommands.k9auditpartner(src, { 'ABCD1234', '3' })

    t.equals(#capturedQueries, 2, 'one query per unique index, per this file\'s own documented design')

    -- capturedNotifications[1] is the "N result(s)" summary; [2] is the
    -- formatted-row chunk (<= ROWS_PER_NOTIFY_CHUNK == 5, so all 3 rows
    -- land in one chunk here).
    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    local body = capturedNotifications[2].description

    local posK98 = body:find('K9-8', 1, true)
    local posK95 = body:find('K9-5', 1, true)
    local posK92 = body:find('K9-2', 1, true)
    t.isNotNil(posK98)
    t.isNotNil(posK95)
    t.isNotNil(posK92)
    t.isTrue(posK98 < posK95, 'id=8 must sort before id=5 (DESC)')
    t.isTrue(posK95 < posK92, 'id=5 must sort before id=2 (DESC)')
    t.notContains(body, 'K9-1', 'limit=3 must truncate the 4th-ranked row (id=1) out entirely')
end)

-- ----------------------------------------------------------------------
-- COVERAGE GAP FOUND IN THE ORIGINAL 28 CASES (reported here, not fixed by
-- silently editing any of those 28 -- see this file's own header and the
-- task that produced this pass): NONE of them ever populate
-- MySQL.query.await's stubbed return with actual rows for k9auditcert,
-- k9auditsearch, or k9auditxp -- every one of those 28 either stops before
-- a query runs (denied/rate_limited/invalid_args) or reaches
-- PresentRows/PrintRowsToConsole with an EMPTY row set (no fixtureResponder
-- configured --> MySQLStub returns {}). The one exception is the
-- MergeSortedByIdDesc case, which incidentally exercises FormatPartnershipRow
-- (admin.partnership_row_format) only because it has to supply real rows to
-- prove the merge/sort/truncate logic. That means:
--   - FormatCertRow (admin.cert_row_format),
--   - FormatSearchLogRow (admin.search_log_row_format, plus BOTH of its
--     target-label branches: admin.search_log_target_plate_label and
--     admin.search_log_target_citizenid_label),
--   - FormatProgressionRow (admin.progression_row_format),
-- were NEVER exercised by this suite. This is the EXACT SAME SHAPE as the
-- /k9auditdept locale gap this task's brief names by example: a case that
-- never drives the "render a real row" branch cannot catch a missing or
-- renamed locale key on that branch.
--
-- SEPARATELY, and more starkly: k9auditxp was never invoked AT ALL by any
-- of the 28 (not even once, valid or invalid) -- its entire command surface,
-- including admin.usage_auditxp and admin.xp_snapshot_label, was untested.
-- k9auditsearch's 'officer', 'person', and 'recent' modes were likewise
-- NEVER invoked (only 'plate' and one invalid-mode case were) -- meaning the
-- `(mode == 'officer') and QuerySearchLogByOfficer(...) or
-- QuerySearchLogByPerson(...)` dispatch, QuerySearchLogRecent's no-WHERE
-- shape, and admin.usage_auditsearch_mode were all unexercised. And
-- k9auditpartner's OWN invalid-citizenid branch (admin.usage_auditpartner)
-- was never reached either -- every k9auditpartner invocation in the
-- original 28 used a valid citizenid.
--
-- All closed below with NEW cases. None of the original 28 above are
-- modified.
-- ----------------------------------------------------------------------

t.test('COVERAGE GAP CLOSED: k9auditcert with a populated result set renders via FormatCertRow (admin.cert_row_format) -- no case among the original 28 ever populated a row', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications WHERE citizenid = ?', 1, true) then
            return {
                { job = 'police', active = 1, granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00', revoked_by = nil, revoked_at = nil },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    local body = capturedNotifications[2].description
    t.contains(body, 'job=police')
    t.contains(body, 'active=true')
    t.contains(body, 'granted_by=ADMIN1')
    t.contains(body, 'granted_at=2024-01-01 00:00:00')
    t.contains(body, 'revoked_by=N/A')
    t.contains(body, 'revoked_at=N/A')
end)

t.test('COVERAGE GAP CLOSED: k9auditpartner invalid-citizenid usage message (admin.usage_auditpartner) -- never reached by the original 28 (every k9auditpartner case there used a valid citizenid)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditpartner(src, { '' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage: /k9auditpartner')
end)

t.test('COVERAGE GAP CLOSED: k9auditsearch "officer" mode -- never invoked by the original 28. Dispatches to QuerySearchLogByOfficer (searcher_citizenid = ?), renders via FormatSearchLogRow using the target_citizenid_label branch', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('searcher_citizenid = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER1', searcher_job = 'police', target_type = 'person', target_plate = nil, target_citizenid = 'SUSPECT1', result = 'clean', total_weight = nil, alert_tier = nil, searched_at = '2024-02-02 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'officer', 'OFFICER1' })
    t.equals(#capturedQueries, 1)
    t.contains(capturedQueries[1].sql, 'searcher_citizenid = ?')
    t.equals(capturedQueries[1].params[1], 'OFFICER1')
    local body = capturedNotifications[2].description
    t.contains(body, 'searcher=OFFICER1(police)')
    t.contains(body, 'target=person(citizenid=SUSPECT1)')
    t.contains(body, 'result=clean')
    t.contains(body, 'weight=N/A')
    t.contains(body, 'tier=N/A')
end)

t.test('COVERAGE GAP CLOSED: k9auditsearch "person" mode -- never invoked by the original 28. Dispatches to QuerySearchLogByPerson (target_citizenid = ?), NOT QuerySearchLogByOfficer -- a swapped ternary would fail this case while leaving the "officer" case above green', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('target_citizenid = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER2', searcher_job = 'sheriff', target_type = 'person', target_plate = nil, target_citizenid = 'SUSPECT2', result = 'contraband_found', total_weight = nil, alert_tier = nil, searched_at = '2024-02-03 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'person', 'SUSPECT2' })
    t.equals(#capturedQueries, 1)
    t.contains(capturedQueries[1].sql, 'target_citizenid = ?')
    t.notContains(capturedQueries[1].sql, 'searcher_citizenid = ?')
    t.equals(capturedQueries[1].params[1], 'SUSPECT2')
end)

t.test('COVERAGE GAP CLOSED: k9auditsearch "plate" mode with a populated result set renders via FormatSearchLogRow, target_plate_label branch (admin.search_log_target_plate_label) -- the original 3 plate cases never populated a row', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('target_plate = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER3', searcher_job = 'bcso', target_type = 'vehicle', target_plate = 'ABC123', target_citizenid = nil, result = 'contraband_found', total_weight = 2.5, alert_tier = 3, searched_at = '2024-03-03 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'plate', 'ABC123' })
    t.equals(#capturedQueries, 1)
    local body = capturedNotifications[2].description
    t.contains(body, 'target=vehicle(plate=ABC123)')
    t.contains(body, 'weight=2.5')
    t.contains(body, 'tier=3')
end)

t.test('COVERAGE GAP CLOSED: k9auditsearch "recent" mode -- never invoked by the original 28. No WHERE clause, ordered by id DESC, no bound params', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'recent' })
    t.equals(#capturedQueries, 1)
    t.notContains(capturedQueries[1].sql, 'WHERE')
    t.contains(capturedQueries[1].sql, 'ORDER BY id DESC')
    t.equals(#capturedQueries[1].params, 0, 'recent mode takes no WHERE-bound params')
end)

t.test('COVERAGE GAP CLOSED: k9auditsearch officer/person invalid-citizenid usage message (admin.usage_auditsearch_mode) -- never reached by the original 28 (only "plate" and an invalid mode were ever tried)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditsearch(src, { 'officer', '' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage: /k9auditsearch officer')
end)

t.test('COVERAGE GAP CLOSED: k9auditxp was never invoked by any of the original 28 cases -- invalid-citizenid usage message (admin.usage_auditxp) exercised here', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditxp(src, { '' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage: /k9auditxp')
end)

t.test('COVERAGE GAP CLOSED: k9auditxp with a populated result renders via FormatProgressionRow (admin.progression_row_format) and admin.xp_snapshot_label', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_progression', 1, true) then
            return { { xp = 4200, updated_at = '2024-04-04 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9auditxp(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    t.contains(capturedNotifications[1].description, 'XP snapshot for ABCD1234')
    local body = capturedNotifications[2].description
    t.contains(body, 'xp=4200')
    t.contains(body, 'updated_at=2024-04-04 00:00:00')
end)

-- ----------------------------------------------------------------------
-- /k9auditdept <job> [limit] -- new command, covered the same way the other
-- four are covered above: ACE gate + TrustConsole carve-out, shared
-- cooldown, LogAuditInvocation on every branch, argument validation,
-- ClampLimit reuse, parameterized/read-only query shape, and every locale
-- key this command's own code path can reach (this IS the regression guard
-- for the admin.usage_auditdept / admin.dept_roster_label /
-- admin.dept_cert_row_format keys that shipped missing once already --
-- Sandbox.locale raises on a missing key, so simply reaching each branch
-- below is what would have caught that).
-- ----------------------------------------------------------------------

t.test('k9auditdept: a source with no resolvable player record is denied, no query ever runs', function()
    resetCaptures()
    local src = 9101
    registeredCommands.k9auditdept(src, { 'police' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
    t.contains(capturedPrints[#capturedPrints], 'ran k9auditdept(n/a) -> denied')
end)

t.test('k9auditdept: console (source == 0) is denied by default (TrustConsole == false)', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = false
    registeredCommands.k9auditdept(0, { 'police' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 0, 'source == 0 has no client to notify')
    t.contains(capturedPrints[#capturedPrints], 'ran k9auditdept(n/a) -> denied')
end)

t.test('k9auditdept: console (source == 0) is allowed once TrustConsole is opted in', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = true
    -- Advance the shared fake clock comfortably past CommandCooldownMs (300)
    -- since key `0` may have been touched by an earlier console-path case
    -- elsewhere in this file -- this is the SAME shared-cooldown state every
    -- console (source == 0) case in this suite reads and writes, so this
    -- guards against test-order coupling rather than assuming a fresh key.
    fakeNow = fakeNow + 1000
    registeredCommands.k9auditdept(0, { 'police' })
    t.equals(#capturedQueries, 1)
    Config.AdminAudit.TrustConsole = false -- restore for subsequent tests
end)

t.test('Rate limiting: k9auditdept participates in the shared AuditCooldown -- blocked shortly after another command from the same source, recovers once the window elapses', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 5000
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 5100 -- within CommandCooldownMs (300)
    registeredCommands.k9auditdept(src, { 'police' })
    t.equals(#capturedQueries, 1, 'k9auditdept must be rate-limited by a recent k9auditcert call from the same source')
    t.contains(capturedPrints[#capturedPrints], 'ran k9auditdept(n/a) -> rate_limited')

    fakeNow = 5500 -- past the 300ms cooldown
    registeredCommands.k9auditdept(src, { 'police' })
    t.equals(#capturedQueries, 2, 'a k9auditdept call after the cooldown window has elapsed must succeed')
end)

t.test('Rate limiting: k9auditdept itself feeds the shared AuditCooldown -- blocks a subsequent DIFFERENT command from the same source', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 6000
    registeredCommands.k9auditdept(src, { 'police' })
    t.equals(#capturedQueries, 1)

    fakeNow = 6100 -- within cooldown
    registeredCommands.k9auditpartner(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'k9auditpartner must be rate-limited by k9auditdept\'s own recent call from the same source')
end)

t.test('k9auditdept: a valid, configured department reaches the query; zero rows renders admin.no_results_found with the admin.dept_roster_label', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 'police' })
    t.equals(#capturedQueries, 1)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'Certified handlers for department police')
    t.contains(capturedNotifications[1].description, 'no results found')
    t.contains(capturedPrints[#capturedPrints], 'ran k9auditdept(police) -> ok')
end)

t.test('k9auditdept: an unconfigured department is rejected as invalid_args, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 'ambulance' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage:')
    t.contains(capturedPrints[#capturedPrints], 'ran k9auditdept(n/a) -> invalid_args')
end)

t.test('k9auditdept: a non-string job argument is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 42 })
    t.equals(#capturedQueries, 0)
end)

t.test('k9auditdept: an empty string job argument is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { '' })
    t.equals(#capturedQueries, 0)
end)

t.test('k9auditdept: a limit above the hard maximum clamps down to 100', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 'police', '999999' })
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.equals(tonumber(limitStr), 100)
end)

t.test('k9auditdept: a non-numeric limit falls back to the configured default (Certifications = 50)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 'police', 'not-a-number' })
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.equals(tonumber(limitStr), 50)
end)

t.test('k9auditdept: the query is parameterized (job never concatenated into SQL text) and strictly read-only', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 'police', '10' })
    t.equals(#capturedQueries, 1)
    local sql = capturedQueries[1].sql
    t.contains(sql, 'WHERE job = ?')
    t.contains(sql, 'AND active = 1')
    t.equals(capturedQueries[1].params[1], 'police')
    t.equals(#capturedQueries[1].params, 1, 'job is the ONLY bound parameter -- limit is a server-clamped integer embedded via string.format, never a placeholder')
    t.notContains(sql, "'police'", 'job must never be concatenated as a literal into the SQL text -- it must only ever reach a bound placeholder')
    local upperSql = sql:upper()
    t.notContains(upperSql, 'INSERT')
    t.notContains(upperSql, 'UPDATE')
    t.notContains(upperSql, 'DELETE')
end)

t.test('k9auditdept: a populated roster renders via FormatDeptCertRow (admin.dept_cert_row_format) and admin.result_count -- this IS the regression guard for the three locale keys that shipped missing', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications', 1, true) and sql:find('job = ?', 1, true) then
            return {
                { citizenid = 'ABCD1111', granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00' },
                { citizenid = 'ABCD2222', granted_by = 'ADMIN2', granted_at = '2024-01-02 00:00:00' },
            }
        end
        return {}
    end

    local src = freshAuthorizedSource()
    registeredCommands.k9auditdept(src, { 'police' })

    t.equals(#capturedQueries, 1)
    t.isNotNil(capturedNotifications[1], 'expected the "N result(s)" summary notification')
    t.contains(capturedNotifications[1].description, 'Certified handlers for department police')
    t.contains(capturedNotifications[1].description, '2 result(s)')

    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    local body = capturedNotifications[2].description
    t.contains(body, 'citizenid=ABCD1111')
    t.contains(body, 'granted_by=ADMIN1')
    t.contains(body, 'granted_at=2024-01-01 00:00:00')
    t.contains(body, 'citizenid=ABCD2222')
    t.contains(body, 'granted_by=ADMIN2')
end)

os.exit(t.summary())
