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

--- Test helper: runs one command invocation from a FRESH, always-authorized,
--- never-previously-rate-limited source (a new integer every call), so each
--- test case is isolated from AuditCooldown's shared per-source state
--- without needing to fast-forward the fake clock. Returns nothing; inspect
--- capturedQueries/capturedNotifications/capturedPrints afterward.
local nextSource = 1000
local function freshAuthorizedSource()
    nextSource = nextSource + 1
    aceGrants[tostring(nextSource)] = true
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

t.test('IsAuthorizedAdmin: a source with no ACE grant is denied, no query ever runs', function()
    resetCaptures()
    local src = 9001
    aceGrants[tostring(src)] = false
    registeredCommands.k9auditcert(src, { 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: denial is checked before argument shape (malformed args never even inspected)', function()
    resetCaptures()
    local src = 9002
    aceGrants[tostring(src)] = false
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

os.exit(t.summary())
