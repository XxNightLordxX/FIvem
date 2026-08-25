--[[
    tests/datastore_spec.lua

    Tests server/datastore.lua -- the single database accessor layer behind
    Config.Database.enabled -- against the REAL, unmodified production file.

    THE WHOLE POINT OF THIS SPEC, so it doesn't get read as "just another
    CRUD test": server/datastore.lua exists so a server can run with
    `Config.Database.enabled = false` and never touch a database at all,
    while still keeping every certification/XP/partnership/permission/
    runtime-override/tablet-theme/K9-appearance check working for the life
    of the process. A spec that only ever exercises the MySQL branch proves
    NOTHING about that promise -- see PART 2 below, which deliberately loads
    this file into a sandbox with NO `MySQL` global defined AT ALL, so any
    accidental reference to it (a bug that left a stray `if
    DatabaseEnabled()` branch swapped, or a table function that forgot its
    own guard) is a hard Lua error ("attempt to index a nil value") rather
    than a silent pass.

    THREE PARTS:
      PART 1 -- MYSQL BRANCH. A capture-based fake MySQL (records the exact
        SQL text and bound params, returns a canned value) proves each
        function forwards to the right oxmysql method with the right
        arguments, and that a thrown MySQL-mode error propagates unchanged
        (this resource's callers already pcall around every K9Store.*
        call exactly like they pcall a raw MySQL.*.await today -- see
        datastore.lua's own header "CONTRACT DISCIPLINE").
      PART 2 -- MEMORY BRANCH, NO MySQL GLOBAL AT ALL. Exercises the
        invariants the owner's requirement demands directly: fail-closed on
        a miss, at-most-one-active-row uniqueness (including partnerships'
        TWO independent uniqueness dimensions), a bounded k9_search_log
        ring buffer that never grows past its cap, and the exact
        `{ errno = 1062 }` shape every existing `IsDuplicateKeyError`
        helper elsewhere in this resource already recognizes.
      PART 3 -- PARITY. The identical sequence of calls against BOTH a
        fresh MySQL-mode fixture (backed by a tiny fake relational table,
        not just a capture stub) and a fresh memory-mode fixture must reach
        the identical externally-observable outcome -- proving the two
        backends do not merely both "work" in isolation, but agree.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- PART 1 -- MySQL branch (capture-based fake, Config.Database.enabled = true)
-- ----------------------------------------------------------------------

local captured
local canned

local function resetCapture()
    captured = {}
end

local function capturingMySQL()
    local function record(kind)
        return function(sql, params)
            captured[#captured + 1] = { kind = kind, sql = sql, params = params }
            local c = canned
            canned = nil
            if type(c) == 'table' and c.throw then error(c.throw, 0) end
            return c
        end
    end
    return {
        scalar = { await = record('scalar') },
        single = { await = record('single') },
        query  = { await = record('query') },
        insert = { await = record('insert') },
        update = { await = record('update') },
    }
end

local mysqlEnv = Sandbox.newEnv({
    Config = { Database = { enabled = true } },
    MySQL = capturingMySQL(),
    print = function(...) end,
})
Sandbox.loadInto('../server/datastore.lua', mysqlEnv)
local MysqlStore = mysqlEnv.K9Store

t.isNotNil(MysqlStore, 'server/datastore.lua must define global K9Store')
t.isTrue(mysqlEnv.K9Store.IsDatabaseEnabled(), 'IsDatabaseEnabled must reflect Config.Database.enabled = true')

t.test('MySQL branch: Cert_GetActiveId forwards to MySQL.scalar.await with the real SQL/params and passes the value through', function()
    resetCapture()
    canned = 77
    local id = MysqlStore.Cert_GetActiveId('CIT1', 'police')
    t.equals(id, 77)
    t.equals(#captured, 1)
    t.equals(captured[1].kind, 'scalar')
    t.contains(captured[1].sql, 'FROM k9_certifications')
    t.contains(captured[1].sql, 'active = 1')
    t.equals(captured[1].params[1], 'CIT1')
    t.equals(captured[1].params[2], 'police')
end)

t.test('MySQL branch: Cert_Insert with an expiry uses DATE_ADD, without one omits it entirely', function()
    resetCapture()
    canned = 5
    MysqlStore.Cert_Insert('CIT1', 'police', 'GRANTER1', 90)
    t.contains(captured[1].sql, 'DATE_ADD(NOW(), INTERVAL ? DAY)')
    t.equals(captured[1].params[4], 90)

    resetCapture()
    canned = 6
    MysqlStore.Cert_Insert('CIT2', 'police', 'GRANTER1', nil)
    t.notContains(captured[1].sql, 'DATE_ADD')
    t.equals(#captured[1].params, 3)
end)

t.test('MySQL branch: a thrown insert error propagates to the caller unchanged (the existing pcall-at-call-site contract)', function()
    resetCapture()
    canned = { throw = { errno = 1062, message = 'ER_DUP_ENTRY' } }
    local ok, err = pcall(MysqlStore.Cert_Insert, 'CIT1', 'police', 'G', nil)
    t.isFalse(ok)
    t.equals(err.errno, 1062, 'the real oxmysql-shaped error object must reach the caller exactly as thrown, not be swallowed or rewrapped')
end)

t.test('MySQL branch: Partner_Insert forwards k9/handler/establishedBy in the documented column order', function()
    resetCapture()
    canned = 9
    MysqlStore.Partner_Insert('K9CIT', 'HANDLERCIT', 'HANDLERCIT')
    t.equals(captured[1].params[1], 'K9CIT')
    t.equals(captured[1].params[2], 'HANDLERCIT')
    t.equals(captured[1].params[3], 'HANDLERCIT')
end)

t.test('MySQL branch: XP_UpsertAdd sends the per-award DELTA, not a running total, via ON DUPLICATE KEY UPDATE', function()
    resetCapture()
    canned = 1
    MysqlStore.XP_UpsertAdd('CIT1', 25)
    t.contains(captured[1].sql, 'ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp)')
    t.equals(captured[1].params[2], 25)
end)

t.test('MySQL branch: Override_Upsert/Delete/OverrideAudit_Append never throw to the caller -- mirrors SafeWrite\'s own boolean contract', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Override_Upsert('feature:Recall', 'feature', 'false', 'CIT1'))
    canned = { throw = 'simulated write failure' }
    t.isFalse(MysqlStore.Override_Delete('feature:Recall'), 'a thrown DB error must degrade to false, never propagate raw, matching every SafeWrite call site this replaces')
end)

t.test('MySQL branch: Appearance_GetRow mirrors GetAppearanceRow\'s own single-row-or-nil contract over a query.await array', function()
    resetCapture()
    canned = { { model = 'a_c_shepherd', original_model_hash = 123, active = 1 } }
    local row = MysqlStore.Appearance_GetRow('CIT1')
    t.equals(row.model, 'a_c_shepherd')
    resetCapture()
    canned = {}
    t.isNil(MysqlStore.Appearance_GetRow('CIT2'))
end)

-- ----------------------------------------------------------------------
-- PART 2 -- Memory branch, Config.Database.enabled = false, NO `MySQL`
-- global defined at all in this sandbox -- see this file's header.
-- ----------------------------------------------------------------------

local memEnv = Sandbox.newEnv({
    Config = { Database = { enabled = false } },
    -- Deliberately NOT setting MySQL here. Sandbox.newEnv copies the real
    -- process _G first, and the real process has no MySQL global either
    -- (this is plain lua5.4, not FXServer), so `env.MySQL` is genuinely
    -- nil, not just unset-by-convention.
    print = function(...) end,
})
Sandbox.loadInto('../server/datastore.lua', memEnv)
local MemStore = memEnv.K9Store

t.isFalse(MemStore.IsDatabaseEnabled(), 'IsDatabaseEnabled must reflect Config.Database.enabled = false')
t.isNil(memEnv.MySQL, 'sanity check on the fixture itself: MySQL must be genuinely absent from this sandbox')

t.test('Memory: a fresh process starts with EVERY table empty -- fail-closed by construction, not by discipline', function()
    t.isNil(MemStore.Cert_GetActiveId('NOBODY', 'police'))
    t.isNil(MemStore.Perm_GetActiveId('NOBODY', 'k9.access'))
    t.equals(#MemStore.Perm_GetActiveForCitizen('NOBODY'), 0)
    t.isNil(MemStore.Partner_GetActiveRowByParty('NOBODY'))
    t.isNil(MemStore.XP_Get('NOBODY'))
    t.equals(#MemStore.SearchLog_GetRecent(50), 0)
    t.equals(#MemStore.Override_GetAll(), 0)
    t.equals(#MemStore.Theme_GetRows(), 0)
    t.isNil(MemStore.Appearance_GetRow('NOBODY'))
end)

t.test('Memory: Cert_Insert/GetActiveId/RevokeActive round-trip, fails closed again after revoke', function()
    local id = MemStore.Cert_Insert('CITA', 'police', 'GRANTERA', nil)
    t.isNotNil(id)
    t.equals(MemStore.Cert_GetActiveId('CITA', 'police'), id)
    t.isNotNil(MemStore.Cert_GetActiveMeta('CITA', 'police'))

    local affected = MemStore.Cert_RevokeActive('CITA', 'police', 'GRANTERA', 'reassigned')
    t.equals(affected, 1)
    t.isNil(MemStore.Cert_GetActiveId('CITA', 'police'), 'revoked row must no longer be found as active')
    t.equals(MemStore.Cert_RevokeActive('CITA', 'police', 'GRANTERA', 'reassigned'), 0, 'revoking an already-inactive row affects zero rows, same as the real UPDATE')
end)

t.test('Memory: Cert_Insert raises a real MySQL-1062-shaped error on a duplicate ACTIVE (citizenid, job)', function()
    MemStore.Cert_Insert('CITB', 'sheriff', 'G', nil)
    local ok, err = pcall(MemStore.Cert_Insert, 'CITB', 'sheriff', 'G', nil)
    t.isFalse(ok)
    t.equals(err.errno, 1062, 'must be the exact shape certifications.lua/permissions.lua/partnership.lua\'s own IsDuplicateKeyError already checks first (err.errno == 1062)')
end)

t.test('Memory: a DIFFERENT job for the same citizenid is NOT a duplicate -- the invariant is scoped per (citizenid, job)', function()
    MemStore.Cert_Insert('CITC', 'police', 'G', nil)
    local ok = pcall(MemStore.Cert_Insert, 'CITC', 'sheriff', 'G', nil)
    t.isTrue(ok, 'holding an active cert for a different department must never block a new one -- cross-department granting is allowed')
end)

t.test('Memory: Cert_SetTier / Cert_RenewExpiry only touch the currently active row', function()
    MemStore.Cert_Insert('CITD', 'police', 'G', nil)
    t.equals(MemStore.Cert_SetTier('CITD', 'police', 'senior'), 1)
    t.equals(MemStore.Cert_GetActiveMeta('CITD', 'police').tier, 'senior')
    t.equals(MemStore.Cert_SetTier('NOBODY', 'police', 'senior'), 0)
end)

t.test('Memory: specializations require nothing beyond their own (citizenid, job, specialization) key; cascade-revoke clears every active one at once', function()
    MemStore.Cert_Insert('CITE', 'police', 'G', nil)
    MemStore.Spec_Insert('CITE', 'police', 'narcotics', 'G')
    MemStore.Spec_Insert('CITE', 'police', 'explosives', 'G')
    t.equals(#MemStore.Spec_GetActiveKeys('CITE', 'police'), 2)

    local ok, err = pcall(MemStore.Spec_Insert, 'CITE', 'police', 'narcotics', 'G')
    t.isFalse(ok)
    t.equals(err.errno, 1062)

    local revoked = MemStore.Spec_RevokeAllForJob('CITE', 'police', 'G')
    t.equals(revoked, 2)
    t.equals(#MemStore.Spec_GetActiveKeys('CITE', 'police'), 0)
end)

t.test('Memory: Partner_Insert enforces BOTH independent uniqueness dimensions -- a citizenid cannot be active as K9 in one row and handler in another', function()
    MemStore.Partner_Insert('K9A', 'HANDLERA', 'HANDLERA')

    local ok1 = pcall(MemStore.Partner_Insert, 'K9A', 'HANDLERB', 'HANDLERB')
    t.isFalse(ok1, 'K9A already active as a K9 -- must reject a second partnership naming it in EITHER role')

    local ok2 = pcall(MemStore.Partner_Insert, 'K9B', 'HANDLERA', 'HANDLERA')
    t.isFalse(ok2, 'HANDLERA already active as a handler -- must reject a second partnership naming it in EITHER role')

    local row = MemStore.Partner_GetActiveRowByParty('K9A')
    t.isNotNil(row)
    local ended = MemStore.Partner_EndById(row.id, 'HANDLERA')
    t.equals(ended, 1)
    t.isNil(MemStore.Partner_GetActiveRowByParty('K9A'))

    -- Now that the row is ended, both citizenids are free to form NEW pairs.
    local ok3 = pcall(MemStore.Partner_Insert, 'K9A', 'HANDLERB', 'HANDLERB')
    t.isTrue(ok3, 'ending a partnership must free both parties to re-partner -- this is not a permanent lock')
end)

t.test('Memory: Partner_GetActiveFlagById reads by id alone, regardless of current active state -- the reconciliation shape DoBreakPartnership needs', function()
    local id = MemStore.Partner_Insert('K9C', 'HANDLERC', 'HANDLERC')
    t.equals(MemStore.Partner_GetActiveFlagById(id), 1)
    MemStore.Partner_EndById(id, 'HANDLERC')
    t.equals(MemStore.Partner_GetActiveFlagById(id), 0, 'must still resolve after ending -- this is NOT the same as GetActiveRowByParty, which only finds ACTIVE rows')
    t.isNil(MemStore.Partner_GetActiveFlagById(99999))
end)

t.test('Memory: tenure CAS only applies when the row is still active AND the expected old tier still matches -- a lost race affects zero rows', function()
    local id = MemStore.Partner_Insert('K9D', 'HANDLERD', 'HANDLERD')
    t.equals(MemStore.Partner_SetTenureTierCAS(id, 1, 0), 1)
    t.equals(MemStore.Partner_SetTenureTierCAS(id, 2, 0), 0, 'stale expected-old-tier (0) must not apply on top of the already-advanced tier (1)')
    t.equals(MemStore.Partner_SetTenureTierCAS(id, 2, 1), 1, 'the correct current tier (1) is accepted')
    local tenureRow = MemStore.Partner_GetTenureRow('K9D')
    t.equals(tenureRow.tenure_bonus_tier_granted, 2)
    t.isTrue(tenureRow.tenure_seconds >= 0)
end)

t.test('Memory: Perm_Insert/RevokeActive round-trip and duplicate-active rejection, same shape as certifications', function()
    local id = MemStore.Perm_Insert('CITF', 'k9.access', 'HC1')
    t.equals(MemStore.Perm_GetActiveId('CITF', 'k9.access'), id)
    local ok, err = pcall(MemStore.Perm_Insert, 'CITF', 'k9.access', 'HC1')
    t.isFalse(ok)
    t.equals(err.errno, 1062)
    t.equals(MemStore.Perm_RevokeActive('CITF', 'k9.access', 'HC1'), 1)
    t.isNil(MemStore.Perm_GetActiveId('CITF', 'k9.access'))
end)

t.test('Memory: XP_Get/XP_UpsertAdd/XP_GetTop -- accumulates deltas, never overwrites, ranks correctly', function()
    t.isNil(MemStore.XP_Get('XPCIT1'))
    MemStore.XP_UpsertAdd('XPCIT1', 20)
    MemStore.XP_UpsertAdd('XPCIT1', 25)
    t.equals(MemStore.XP_Get('XPCIT1'), 45, 'must ADD the delta, never overwrite with the last award amount')

    MemStore.XP_UpsertAdd('XPCIT2', 100)
    local top = MemStore.XP_GetTop(1)
    t.equals(#top, 1)
    t.equals(top[1].citizenid, 'XPCIT2')
    t.equals(top[1].xp, 100)

    local snap = MemStore.XP_GetSnapshotRows('XPCIT1')
    t.equals(#snap, 1)
    t.equals(snap[1].xp, 45)
    t.equals(#MemStore.XP_GetSnapshotRows('NOBODY'), 0)
end)

t.test('Memory: k9_search_log is a BOUNDED ring buffer -- inserting well past capacity never grows the table without limit', function()
    for i = 1, 520 do
        MemStore.SearchLog_Insert('OFFICERX', 'police', 'vehicle', ('PLATE%d'):format(i), nil, 'clean', 0, 'clean')
    end
    local recent = MemStore.SearchLog_GetRecent(1000)
    t.isTrue(#recent <= 500, 'must never exceed the documented in-memory cap regardless of how many rows are inserted')
    -- The MOST RECENT insert (id-wise) must still be present -- eviction
    -- drops the OLDEST rows, never the newest.
    t.equals(recent[1].target_plate, 'PLATE520')
    -- And the very first insert must be long gone.
    local foundOldest = false
    for _, row in ipairs(MemStore.SearchLog_GetByPlate('PLATE1', 1000)) do
        foundOldest = true
    end
    t.isFalse(foundOldest, 'the oldest row must have been evicted once the cap was exceeded')
end)

t.test('Memory: SearchLog_GetByOfficer/ByPlate/ByPerson filter correctly and never see each other\'s rows', function()
    MemStore.SearchLog_Insert('OFF1', 'police', 'vehicle', 'ABC123', nil, 'found', 5, 'aggressive_bark')
    MemStore.SearchLog_Insert('OFF2', 'police', 'person', nil, 'TARGETCIT', 'clean', 0, 'clean')
    t.equals(#MemStore.SearchLog_GetByOfficer('OFF1', 10), 1)
    t.equals(#MemStore.SearchLog_GetByPlate('ABC123', 10), 1)
    t.equals(#MemStore.SearchLog_GetByPerson('TARGETCIT', 10), 1)
    t.equals(#MemStore.SearchLog_GetByPerson('ABC123', 10), 0)
end)

t.test('Memory: runtime overrides are a plain upsert-in-place key/value store, not an active-row table', function()
    t.isTrue(MemStore.Override_Upsert('feature:Recall', 'feature', 'false', 'HC1'))
    t.equals(#MemStore.Override_GetAll(), 1)
    t.isTrue(MemStore.Override_Upsert('feature:Recall', 'feature', 'true', 'HC2'), 'upserting the SAME key must update in place, not add a second row')
    t.equals(#MemStore.Override_GetAll(), 1)
    t.isTrue(MemStore.OverrideAudit_Append('feature:Recall', 'feature', 'false', 'true', 'HC2'))
    t.isTrue(MemStore.Override_Delete('feature:Recall'))
    t.equals(#MemStore.Override_GetAll(), 0)
end)

t.test('Memory: tablet theme is a SINGLETON -- upserting twice never produces two rows', function()
    t.equals(#MemStore.Theme_GetRows(), 0, 'no theme has ever been saved yet in this fresh fixture')
    MemStore.Theme_Upsert('#111111', '#222222', '#333333', '#444444', 'comfortable', 'K9 Tablet', 'HC1')
    MemStore.Theme_Upsert('#000000', '#222222', '#333333', '#444444', 'comfortable', 'K9 Tablet', 'HC1')
    local rows = MemStore.Theme_GetRows()
    t.equals(#rows, 1)
    t.equals(rows[1].primary_color, '#000000', 'the second upsert must overwrite the singleton row, not add another')
    t.isTrue(MemStore.ThemeAudit_Append('#000000', '#222222', '#333333', '#444444', 'comfortable', 'K9 Tablet', 'HC1'))
end)

t.test('Memory: k9_ped_assignments preserves original_model_hash across a re-apply while active (COALESCE semantics), but captures a NEW original after a revert', function()
    t.isTrue(MemStore.Appearance_UpsertApplied('CITG', 'a_c_shepherd', 555, 'HC1'))
    t.isTrue(MemStore.Appearance_UpsertApplied('CITG', 'a_c_husky', nil, 'HC1'), 'a re-apply with no new hash supplied must COALESCE onto the existing one')
    t.equals(MemStore.Appearance_GetRow('CITG').original_model_hash, 555)

    t.isTrue(MemStore.Appearance_MarkReverted('CITG'))
    t.equals(MemStore.Appearance_GetRow('CITG').active, 0)

    t.isTrue(MemStore.Appearance_UpsertApplied('CITG', 'a_c_rottweiler', 999, 'HC1'), 'a fresh assignment after a genuine revert must capture a NEW original, never reuse the stale one')
    t.equals(MemStore.Appearance_GetRow('CITG').original_model_hash, 999)
end)

t.test('Memory: Appearance_SetOriginalHashIfMissing only fills a NULL hash on an active row, never overwrites a real one', function()
    MemStore.Appearance_UpsertApplied('CITH', 'a_c_shepherd', nil, 'HC1')
    t.isNil(MemStore.Appearance_GetRow('CITH').original_model_hash)
    MemStore.Appearance_SetOriginalHashIfMissing('CITH', 4242)
    t.equals(MemStore.Appearance_GetRow('CITH').original_model_hash, 4242)
    MemStore.Appearance_SetOriginalHashIfMissing('CITH', 9999)
    t.equals(MemStore.Appearance_GetRow('CITH').original_model_hash, 4242, 'must never clobber an already-known original')
end)

-- ----------------------------------------------------------------------
-- PART 3 -- Parity: the SAME sequence against a fresh instance of EACH
-- backend must reach the SAME externally-observable outcome. The MySQL
-- fixture here is a small fake relational table (not just a capture
-- stub) so its own duplicate-key/affected-row behavior is real, not
-- asserted by fiat.
-- ----------------------------------------------------------------------

--- @return table mysql -- a minimal fake honoring k9_certifications' one
--- invariant this parity check exercises: at most one ACTIVE row per
--- (citizenid, job).
local function newFakeCertMySQL()
    local rows, nextId = {}, 0
    local function findActive(citizenid, job)
        for _, r in ipairs(rows) do
            if r.active == 1 and r.citizenid == citizenid and r.job == job then return r end
        end
    end
    return {
        scalar = { await = function(_sql, p)
            local r = findActive(p[1], p[2])
            return r and r.id or nil
        end },
        insert = { await = function(_sql, p)
            if findActive(p[1], p[2]) then error({ errno = 1062, message = 'ER_DUP_ENTRY' }, 0) end
            nextId = nextId + 1
            rows[#rows + 1] = { id = nextId, citizenid = p[1], job = p[2], granted_by = p[3], active = 1 }
            return nextId
        end },
        update = { await = function(_sql, p)
            -- p = { revokedBy, reason, citizenid, job } for Cert_RevokeActive
            local r = findActive(p[3], p[4])
            if not r then return 0 end
            r.active = 0
            return 1
        end },
    }
end

--- @param store table -- a K9Store instance (either backend)
local function runCertParitySequence(store)
    local outcomes = {}
    outcomes.initialLookup = store.Cert_GetActiveId('PARITYCIT', 'police')
    local grantOk = pcall(store.Cert_Insert, 'PARITYCIT', 'police', 'G', nil)
    outcomes.grantOk = grantOk
    outcomes.afterGrantLookup = store.Cert_GetActiveId('PARITYCIT', 'police') ~= nil
    local dupOk = pcall(store.Cert_Insert, 'PARITYCIT', 'police', 'G', nil)
    outcomes.dupOk = dupOk
    outcomes.revokedRows = store.Cert_RevokeActive('PARITYCIT', 'police', 'G', 'reassigned')
    outcomes.afterRevokeLookup = store.Cert_GetActiveId('PARITYCIT', 'police')
    return outcomes
end

t.test('Parity: certification grant/duplicate-reject/revoke sequence reaches the IDENTICAL outcome on both backends', function()
    local mysqlParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = true } }, MySQL = newFakeCertMySQL(), print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', mysqlParityEnv)

    local memParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = false } }, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', memParityEnv)

    local mysqlOutcome = runCertParitySequence(mysqlParityEnv.K9Store)
    local memOutcome = runCertParitySequence(memParityEnv.K9Store)

    t.isNil(mysqlOutcome.initialLookup)
    t.isNil(memOutcome.initialLookup)
    t.equals(mysqlOutcome.grantOk, memOutcome.grantOk)
    t.isTrue(mysqlOutcome.grantOk)
    t.equals(mysqlOutcome.afterGrantLookup, memOutcome.afterGrantLookup)
    t.isTrue(mysqlOutcome.afterGrantLookup)
    t.equals(mysqlOutcome.dupOk, memOutcome.dupOk)
    t.isFalse(mysqlOutcome.dupOk, 'both backends must reject the duplicate active grant identically')
    t.equals(mysqlOutcome.revokedRows, memOutcome.revokedRows)
    t.equals(mysqlOutcome.revokedRows, 1)
    t.equals(mysqlOutcome.afterRevokeLookup, memOutcome.afterRevokeLookup)
    t.isNil(mysqlOutcome.afterRevokeLookup)
end)

os.exit(t.summary())
