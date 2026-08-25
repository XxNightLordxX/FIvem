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

t.test('MySQL branch: Cert_GetActiveJobsForCitizen forwards the real SQL/params, degrades to {} on a thrown error (SafeQuery contract)', function()
    resetCapture()
    canned = { { job = 'police', granted_by = 'G1' } }
    local rows = MysqlStore.Cert_GetActiveJobsForCitizen('CIT1')
    t.equals(#rows, 1)
    t.contains(captured[1].sql, 'FROM k9_certifications WHERE citizenid = ? AND active = 1')
    t.notContains(captured[1].sql, 'LIMIT')
    t.equals(captured[1].params[1], 'CIT1')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.equals(#MysqlStore.Cert_GetActiveJobsForCitizen('CIT1'), 0, 'a thrown error must degrade to {}, never propagate raw -- this is a SafeQuery-contract accessor, unlike a scalar mirror')
end)

t.test('MySQL branch: Cert_GetActiveRosterByJobUnordered embeds the server-computed LIMIT and issues NO ORDER BY (the filesort this accessor exists to avoid)', function()
    resetCapture()
    canned = { { citizenid = 'CIT1', granted_by = 'G1' } }
    local rows = MysqlStore.Cert_GetActiveRosterByJobUnordered('police', 250)
    t.equals(#rows, 1)
    t.contains(captured[1].sql, 'WHERE job = ? AND active = 1 LIMIT 250')
    t.notContains(captured[1].sql, 'ORDER BY', 'this accessor must never sort -- that is the whole point of NOT reusing Cert_GetActiveRosterByJob')
    t.equals(captured[1].params[1], 'police')
end)

t.test('MySQL branch: Cert_CountByTier mirrors MySQL.scalar.await DIRECTLY -- no active filter, and a thrown error propagates unchanged (NOT the SafeQuery contract)', function()
    resetCapture()
    canned = 3
    local count = MysqlStore.Cert_CountByTier('trainee')
    t.equals(count, 3)
    t.equals(captured[1].kind, 'scalar')
    t.contains(captured[1].sql, 'SELECT COUNT(*) FROM k9_certifications WHERE tier = ?')
    t.notContains(captured[1].sql, 'active', 'must count EVERY row, active or not -- see certtiers.lua\'s own HAZARD 2')

    resetCapture()
    canned = { throw = 'simulated failure' }
    local ok = pcall(MysqlStore.Cert_CountByTier, 'trainee')
    t.isFalse(ok, 'unlike every SafeQuery-contract accessor above, this one must propagate a thrown error to its caller unchanged -- certtiers.lua\'s own DeleteTier pcalls this itself, exactly like it pcalled a raw MySQL.scalar.await before this migration')
end)

t.test('MySQL branch: Tier_GetAllRows / Tier_GetDeletedFlagByKey forward correctly and degrade to {} on failure', function()
    resetCapture()
    canned = { { tier_key = 'master', label = 'Master', ordinal = 4, deleted = 0 } }
    t.equals(#MysqlStore.Tier_GetAllRows(), 1)
    t.contains(captured[1].sql, 'SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers')

    resetCapture()
    canned = { { deleted = 1 } }
    local rows = MysqlStore.Tier_GetDeletedFlagByKey('master')
    t.equals(rows[1].deleted, 1)
    t.contains(captured[1].sql, 'SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?')
    t.equals(captured[1].params[1], 'master')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.equals(#MysqlStore.Tier_GetDeletedFlagByKey('master'), 0)
end)

t.test('MySQL branch: Tier_Upsert writes label AND ordinal on conflict; Tier_UpdateOrdinal/Tier_Tombstone deliberately do NOT mention label in their own ON DUPLICATE KEY UPDATE clause', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Tier_Upsert('master', 'Master', 4, 'HC1'))
    t.contains(captured[1].sql, 'label = VALUES(label)')
    t.contains(captured[1].sql, 'ordinal = VALUES(ordinal)')
    t.contains(captured[1].sql, 'deleted = 0')
    t.equals(captured[1].params[1], 'master')
    t.equals(captured[1].params[2], 'Master')
    t.equals(captured[1].params[3], 4)
    t.equals(captured[1].params[4], 'HC1')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Tier_UpdateOrdinal('master', 'Master', 9, 'HC2'))
    t.notContains(captured[1].sql, 'label = VALUES(label)', 'a reorder write must never be able to overwrite label on an existing row -- see this function\'s own doc comment for the race this closes')
    t.contains(captured[1].sql, 'ordinal = VALUES(ordinal)')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Tier_Tombstone('master', 'Master', 9, 'HC3'))
    t.contains(captured[1].sql, 'VALUES (?, ?, ?, 1, ?)', 'a tombstone write is a literal deleted=1 in the VALUES list, never a bound placeholder')
    t.notContains(captured[1].sql, 'label = VALUES(label)')
    t.notContains(captured[1].sql, 'ordinal = VALUES(ordinal)', 'a delete must never touch ordinal on an existing row either')
    t.contains(captured[1].sql, 'deleted = 1')
end)

t.test('MySQL branch: TierCap_GetAllRows/GetForTier/Insert/Delete forward the real SQL/params', function()
    resetCapture()
    canned = { { tier_key = 'master', capability_key = 'advanced_tracking' } }
    t.equals(#MysqlStore.TierCap_GetAllRows(), 1)
    t.contains(captured[1].sql, 'SELECT tier_key, capability_key FROM k9_certification_tier_capabilities')

    resetCapture()
    canned = { { capability_key = 'advanced_tracking' } }
    local rows = MysqlStore.TierCap_GetForTier('master')
    t.equals(rows[1].capability_key, 'advanced_tracking')
    t.contains(captured[1].sql, 'WHERE tier_key = ?')
    t.equals(captured[1].params[1], 'master')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.TierCap_Insert('master', 'advanced_tracking', 'HC1'))
    t.contains(captured[1].sql, 'INSERT INTO k9_certification_tier_capabilities')
    t.equals(captured[1].params[1], 'master')
    t.equals(captured[1].params[2], 'advanced_tracking')
    t.equals(captured[1].params[3], 'HC1')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.TierCap_Delete('master', 'advanced_tracking'))
    t.contains(captured[1].sql, 'DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND capability_key = ?')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.isFalse(MysqlStore.TierCap_Insert('master', 'advanced_tracking', 'HC1'), 'SafeWrite contract: a thrown error degrades to false, never propagates')
end)

t.test('MySQL branch: TierAudit_Append forwards the real SQL/params and never throws (SafeWrite contract)', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.TierAudit_Append('tier_create', 'master', 'label=Master ordinal=4', 'HC1'))
    t.contains(captured[1].sql, 'INSERT INTO k9_certification_tier_audit')
    t.equals(captured[1].params[1], 'tier_create')
    t.equals(captured[1].params[2], 'master')
    t.equals(captured[1].params[4], 'HC1')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.isFalse(MysqlStore.TierAudit_Append('tier_create', 'master', 'x', 'HC1'))
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

t.test('Memory: Cert_GetActiveJobsForCitizen returns one row per ACTIVE department, excludes a revoked one, never leaks another citizenid\'s row', function()
    t.equals(#MemStore.Cert_GetActiveJobsForCitizen('NEVERCERT'), 0)
    MemStore.Cert_Insert('CITI', 'police', 'G1', nil)
    MemStore.Cert_Insert('CITI', 'sheriff', 'G2', nil)
    MemStore.Cert_Insert('OTHERCIT', 'police', 'G3', nil)
    local rows = MemStore.Cert_GetActiveJobsForCitizen('CITI')
    t.equals(#rows, 2)
    local byJob = {}
    for _, row in ipairs(rows) do byJob[row.job] = row.granted_by end
    t.equals(byJob.police, 'G1')
    t.equals(byJob.sheriff, 'G2')

    MemStore.Cert_RevokeActive('CITI', 'sheriff', 'G2', 'reassigned')
    t.equals(#MemStore.Cert_GetActiveJobsForCitizen('CITI'), 1, 'a revoked department must disappear from this accessor exactly like the real active=1 filter')
end)

t.test('Memory: Cert_GetActiveRosterByJobUnordered filters by job, respects LIMIT, and never sorts (no ORDER BY to reproduce)', function()
    -- Unique job name ('rosterdept') deliberately NOT reused by any other
    -- test in this shared-MemStore file -- every job used elsewhere
    -- ('police'/'sheriff') already accumulates rows from earlier tests
    -- above, which would make a LIMIT-3-of-exactly-these-5 assertion
    -- flaky/order-dependent through no fault of the accessor itself.
    for i = 1, 5 do
        MemStore.Cert_Insert(('ROSTERCIT%d'):format(i), 'rosterdept', 'HC1', nil)
    end
    MemStore.Cert_Insert('SHERIFFCIT', 'sheriff', 'HC1', nil)

    local rows = MemStore.Cert_GetActiveRosterByJobUnordered('rosterdept', 3)
    t.equals(#rows, 3, 'LIMIT must be honored in memory mode exactly like a real SQL LIMIT clause')
    for _, row in ipairs(rows) do
        t.isTrue(row.citizenid:find('ROSTERCIT', 1, true) ~= nil, 'must never leak a different job\'s row')
    end

    local allRosterDept = MemStore.Cert_GetActiveRosterByJobUnordered('rosterdept', 100)
    t.equals(#allRosterDept, 5)
end)

t.test('Memory: Cert_CountByTier counts EVERY row referencing a tier, active or revoked, never filtered by active -- matches HAZARD 2\'s own reasoning', function()
    -- Unique tier strings ('countertierA'/'countertierB') deliberately NOT
    -- reused by any other test -- Cert_Insert's own memory-mode default
    -- ('certified') and Cert_SetTier('senior') are both already exercised,
    -- and contaminated, by earlier tests sharing this same MemStore.
    t.equals(MemStore.Cert_CountByTier('countertierA'), 0)
    MemStore.Cert_Insert('TIERCIT1', 'countertierdept', 'HC1', nil) -- defaults to tier='certified', per the real DB DEFAULT
    MemStore.Cert_Insert('TIERCIT2', 'countertierdept', 'HC1', nil)
    MemStore.Cert_SetTier('TIERCIT2', 'countertierdept', 'countertierA')
    t.equals(MemStore.Cert_CountByTier('countertierA'), 1)

    -- Revoking must NOT remove the row from this count -- an inactive row
    -- still holds a real, audit-trail-relevant tier value.
    MemStore.Cert_RevokeActive('TIERCIT2', 'countertierdept', 'HC1', 'reassigned')
    t.equals(MemStore.Cert_CountByTier('countertierA'), 1, 'a revoked row must still be counted -- this is what makes DeleteTier\'s reference-count check correctly refuse a delete for a tier only historical rows still reference')
end)

t.test('Memory: Tier_GetAllRows/TierCap_GetAllRows/TierCap_GetForTier/Cert_CountByTier all start empty on a fresh process', function()
    t.equals(#MemStore.Tier_GetAllRows(), 0)
    t.equals(#MemStore.TierCap_GetAllRows(), 0)
    t.equals(#MemStore.TierCap_GetForTier('anything'), 0)
    t.equals(#MemStore.Tier_GetDeletedFlagByKey('anything'), 0)
end)

t.test('Memory: Tier_Upsert creates a brand-new row and later renames/re-ordinals it in place -- both label AND ordinal move', function()
    t.isTrue(MemStore.Tier_Upsert('mastert', 'Master', 4, 'HC1'))
    local rows = MemStore.Tier_GetAllRows()
    t.equals(#rows, 1)
    t.equals(rows[1].tier_key, 'mastert')
    t.equals(rows[1].label, 'Master')
    t.equals(rows[1].ordinal, 4)
    t.equals(rows[1].deleted, 0)

    t.isTrue(MemStore.Tier_Upsert('mastert', 'Standard Handler', 4, 'HC2'), 'renaming an already-live tier via Tier_Upsert must update label in place')
    t.equals(MemStore.Tier_GetAllRows()[1].label, 'Standard Handler')
end)

t.test('Memory: Tier_UpdateOrdinal (the reorder write) moves ordinal but NEVER touches an already-existing row\'s label -- the exact race this accessor exists to close', function()
    MemStore.Tier_Upsert('reordert', 'Real Label', 3, 'HC1')
    MemStore.Tier_UpdateOrdinal('reordert', 'STALE-SNAPSHOT-LABEL', 9, 'HC2')
    local rows = MemStore.Tier_GetAllRows()
    local found
    for _, row in ipairs(rows) do if row.tier_key == 'reordert' then found = row end end
    t.isNotNil(found)
    t.equals(found.ordinal, 9, 'ordinal must move')
    t.equals(found.label, 'Real Label', 'label must be COMPLETELY UNTOUCHED by a reorder write, even though a label value was passed through as a parameter -- reusing Tier_Upsert here would have silently overwritten this with the stale snapshot')

    -- The brand-new-row branch DOES use the passed label, matching the
    -- real SQL's own INSERT column list (only reachable when no row
    -- exists yet at all for this key).
    MemStore.Tier_UpdateOrdinal('brandnewviareorder', 'From Config Default', 1, 'HC3')
    local created = MemStore.Tier_GetDeletedFlagByKey('brandnewviareorder')
    t.equals(#created, 1)
    t.equals(created[1].deleted, 0)
end)

t.test('Memory: Tier_Tombstone deletes (tombstones) an existing row without touching its label/ordinal, and can also create a fresh tombstone for a never-before-seen key', function()
    MemStore.Tier_Upsert('tombstonet', 'Tombstone Me', 2, 'HC1')
    t.isTrue(MemStore.Tier_Tombstone('tombstonet', 'IGNORED-LABEL', 999, 'HC2'))
    local rows = MemStore.Tier_GetAllRows()
    local found
    for _, row in ipairs(rows) do if row.tier_key == 'tombstonet' then found = row end end
    t.equals(found.deleted, 1)
    t.equals(found.label, 'Tombstone Me', 'a tombstone of an EXISTING row must never touch label')
    t.equals(found.ordinal, 2, 'a tombstone of an EXISTING row must never touch ordinal')

    -- A legacy config-only key (e.g. 'trainee') that has never had a row
    -- in this table before -- Tier_Tombstone's own brand-new-row branch.
    t.isTrue(MemStore.Tier_Tombstone('trainee', 'Trainee', 1, 'HC3'))
    t.equals(MemStore.Tier_GetDeletedFlagByKey('trainee')[1].deleted, 1)
end)

t.test('Memory: TierCap_Insert/GetForTier/GetAllRows/Delete round-trip correctly, scoped per tier_key, idempotent on a duplicate insert', function()
    MemStore.TierCap_Insert('capt1', 'advanced_tracking', 'HC1')
    MemStore.TierCap_Insert('capt1', 'mentor_trainees', 'HC1')
    MemStore.TierCap_Insert('capt2', 'advanced_tracking', 'HC1')
    t.equals(#MemStore.TierCap_GetForTier('capt1'), 2)
    t.equals(#MemStore.TierCap_GetForTier('capt2'), 1)
    t.equals(#MemStore.TierCap_GetAllRows(), 3)

    -- Re-inserting the SAME (tier_key, capability_key) pair must never
    -- duplicate -- matches the real table's own composite PRIMARY KEY.
    MemStore.TierCap_Insert('capt1', 'advanced_tracking', 'HC2')
    t.equals(#MemStore.TierCap_GetForTier('capt1'), 2, 'a re-insert of the same pair must not create a second row')

    MemStore.TierCap_Delete('capt1', 'advanced_tracking')
    t.equals(#MemStore.TierCap_GetForTier('capt1'), 1)
    t.equals(#MemStore.TierCap_GetAllRows(), 2)
end)

t.test('Memory: TierAudit_Append never throws regardless of volume (bounded ring buffer, same treatment as every other admin-gated audit table in this file)', function()
    for i = 1, 250 do
        t.isTrue(MemStore.TierAudit_Append('tier_update', 'sometier', ('detail %d'):format(i), 'HC1'))
    end
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

--- @return table mysql -- a minimal fake honoring k9_certification_tiers'
--- real semantics closely enough to matter for THIS parity check: on a
--- conflicting key, an ON DUPLICATE KEY UPDATE clause only overwrites the
--- COLUMNS IT ACTUALLY MENTIONS (real MySQL/MariaDB behavior) -- this fake
--- inspects the SQL text for `label = VALUES(label)` / `ordinal =
--- VALUES(ordinal)` before applying either, exactly like a real server
--- would, rather than blindly overwriting every column from the VALUES
--- list. This is what makes the Tier_UpdateOrdinal-must-never-touch-label
--- assertion below a REAL parity proof, not merely two implementations
--- that happen to agree by coincidence.
local function newFakeTierMySQL()
    local tiers = {}
    return {
        query = { await = function(sql, p)
            if sql:find('SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers', 1, true) then
                local out = {}
                for key, row in pairs(tiers) do
                    out[#out + 1] = { tier_key = key, label = row.label, ordinal = row.ordinal, deleted = row.deleted }
                end
                return out
            elseif sql:find('SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?', 1, true) then
                local row = tiers[p[1]]
                if row then return { { deleted = row.deleted } } end
                return {}
            elseif sql:find('INSERT INTO k9_certification_tiers', 1, true) then
                local key, label, ordinal, updatedBy = p[1], p[2], p[3], p[4]
                local deletedLiteral = sql:find('VALUES (?, ?, ?, 1, ?)', 1, true) and 1 or 0
                local existing = tiers[key]
                if existing then
                    if sql:find('label = VALUES(label)', 1, true) then existing.label = label end
                    if sql:find('ordinal = VALUES(ordinal)', 1, true) then existing.ordinal = ordinal end
                    existing.deleted = deletedLiteral
                    existing.updated_by = updatedBy
                else
                    tiers[key] = { label = label, ordinal = ordinal, deleted = deletedLiteral, updated_by = updatedBy }
                end
                return {}
            end
            error('newFakeTierMySQL: unhandled SQL: ' .. tostring(sql))
        end },
    }
end

--- @param store table -- a K9Store instance (either backend)
local function runTierParitySequence(store)
    local outcomes = {}
    store.Tier_Upsert('paritytier', 'Original Label', 4, 'HC1')

    -- The reorder write: passes a STALE label snapshot through, exactly
    -- like server/certtiers.lua's ReorderTiers loop does -- must NEVER
    -- stick.
    store.Tier_UpdateOrdinal('paritytier', 'STALE-LABEL-FROM-REORDER', 9, 'HC2')
    local rows = store.Tier_GetAllRows()
    for _, row in ipairs(rows) do
        if row.tier_key == 'paritytier' then
            outcomes.labelAfterReorder = row.label
            outcomes.ordinalAfterReorder = row.ordinal
        end
    end

    outcomes.deletedBeforeTombstone = store.Tier_GetDeletedFlagByKey('paritytier')[1].deleted
    store.Tier_Tombstone('paritytier', 'IGNORED', 999, 'HC3')
    outcomes.deletedAfterTombstone = store.Tier_GetDeletedFlagByKey('paritytier')[1].deleted

    return outcomes
end

t.test('Parity: Tier_Upsert/Tier_UpdateOrdinal/Tier_Tombstone reach the IDENTICAL outcome on both backends -- INCLUDING that a reorder write never overwrites label', function()
    local mysqlParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = true } }, MySQL = newFakeTierMySQL(), print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', mysqlParityEnv)

    local memParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = false } }, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', memParityEnv)

    local mysqlOutcome = runTierParitySequence(mysqlParityEnv.K9Store)
    local memOutcome = runTierParitySequence(memParityEnv.K9Store)

    t.equals(mysqlOutcome.labelAfterReorder, memOutcome.labelAfterReorder)
    t.equals(mysqlOutcome.labelAfterReorder, 'Original Label', 'BOTH backends must preserve the pre-reorder label -- neither may adopt the stale snapshot the reorder call passed through')
    t.equals(mysqlOutcome.ordinalAfterReorder, memOutcome.ordinalAfterReorder)
    t.equals(mysqlOutcome.ordinalAfterReorder, 9)
    t.equals(mysqlOutcome.deletedBeforeTombstone, memOutcome.deletedBeforeTombstone)
    t.equals(mysqlOutcome.deletedBeforeTombstone, 0)
    t.equals(mysqlOutcome.deletedAfterTombstone, memOutcome.deletedAfterTombstone)
    t.equals(mysqlOutcome.deletedAfterTombstone, 1)
end)

os.exit(t.summary())
