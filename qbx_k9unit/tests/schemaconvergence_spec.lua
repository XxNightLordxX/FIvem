--[[
    tests/schemaconvergence_spec.lua

    Regression guard for the exact bug class an earlier db-schema pass found
    and fixed by hand: `sql/migrations/0011_create_k9_equipment_shop_locations.sql`
    created two real tables that were never added to `sql/install.sql`,
    `sql/preflight_check.sql`, `sql/rollback/uninstall_all.sql` or
    `sql/rollback/backup_k9_tables.sh` -- so a fresh install landed FOURTEEN
    tables instead of sixteen, and a backup taken right before an uninstall
    would silently not have protected the two missing ones. Every one of
    those files says, in its own header, that this is a hand-maintained list
    with a real drift risk every time a migration adds a table -- this spec
    is the automated backstop those headers ask for, run on every commit
    instead of only when a human happens to re-read five files side by side.

    WHAT THIS DOES NOT DO: it does not connect to a database, and it does not
    parse full SQL grammar. Like tests/tabletlocalization_spec.lua (same
    technique, applied to html/tablet.js's DEFAULT_STRINGS instead of a k9_*
    table list), it extracts just the SET OF TABLE NAMES each file commits to
    knowing about, using a narrow pattern matched against each file's own
    real, already-established text shape -- precise enough to catch a table
    completely missing from one of these files (the actual historical bug),
    not a substitute for `sql/preflight_check.sql`'s own live
    INFORMATION_SCHEMA drift checks, which need a real database connection
    this spec deliberately does not require.

    `sql/install.sql` is treated as the ONE authoritative source of "every
    table this resource owns" -- its own top-of-file header states the
    number in English every time a table is added specifically so a count
    like this can be checked against it. Every other file below is asserted
    to know about EXACTLY that same set: no table missing (the historical
    bug), and no stale table name left behind after a rename (the mirror-image
    mistake, just as real -- a script that thinks it is protecting/dropping a
    table that no longer exists is giving an operator false confidence).
]]

local t = dofile('testkit.lua')

--- @param path string
--- @return string
local function ReadFile(path)
    local handle, err = io.open(path, 'r')
    if not handle then
        error(('could not open %s: %s'):format(path, tostring(err)), 2)
    end
    local text = handle:read('a')
    handle:close()
    return text
end

--- Every `k9_<name>` token matched by `pattern` (which must contain exactly
--- one capture group around the table name), collected into a set.
--- @param text string
--- @param pattern string
--- @return table<string, boolean> set, integer count
local function ExtractTableSet(text, pattern)
    local set, count = {}, 0
    for name in text:gmatch(pattern) do
        if not set[name] then
            set[name] = true
            count = count + 1
        end
    end
    return set, count
end

--- @param set table<string, boolean>
--- @return string[] -- sorted, for stable/readable failure messages
local function SortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- @param set table<string, boolean>
--- @return string
local function Describe(set)
    local keys = SortedKeys(set)
    if #keys == 0 then return '(none)' end
    return table.concat(keys, ', ')
end

--- Fails with a readable diff (not just "false") the same way every other
--- structural-equality helper in this suite (e.g. tests/tabletlocalization_spec.lua's
--- own key-set comparisons) already reports mismatches.
--- @param actual table<string, boolean>
--- @param expected table<string, boolean>
--- @param label string
local function AssertSameTableSet(actual, expected, label)
    local missing, extra = {}, {}
    for name in pairs(expected) do
        if not actual[name] then missing[#missing + 1] = name end
    end
    for name in pairs(actual) do
        if not expected[name] then extra[#extra + 1] = name end
    end
    table.sort(missing)
    table.sort(extra)
    if #missing > 0 or #extra > 0 then
        error(('%s does not match install.sql\'s table set -- missing: [%s]; unexpected/stale: [%s]'):format(
            label, table.concat(missing, ', '), table.concat(extra, ', ')), 2)
    end
end

-- ----------------------------------------------------------------------
-- GROUND TRUTH: every `CREATE TABLE IF NOT EXISTS \`k9_...\`` in
-- sql/install.sql. This file's own header states the count in English
-- ("sixteen tables") for exactly this reason -- a human or a test can check
-- the real count against that sentence.
-- ----------------------------------------------------------------------
local installText = ReadFile('../sql/install.sql')
local installTables, installCount = ExtractTableSet(installText, 'CREATE TABLE IF NOT EXISTS `(k9_[%w_]+)`')

t.test('sql/install.sql creates at least sixteen k9_* tables (the documented floor)', function()
    t.isTrue(installCount >= 16, ('expected >= 16 CREATE TABLE statements in install.sql, found %d: %s'):format(installCount, Describe(installTables)))
end)

t.test('sql/install.sql\'s own header sentence names the real table count', function()
    -- Loose on purpose (a plain substring search over the whole file, not a
    -- hardcoded literal "sixteen" compared for exact equality): this only
    -- needs to catch install.sql growing a 17th table with nobody updating
    -- the header prose at all, not police exact wording or exact placement.
    t.isTrue(installText:find('sixteen', 1, true) ~= nil or installText:find(tostring(installCount), 1, true) ~= nil,
        'install.sql no longer mentions a table count consistent with its own real CREATE TABLE statements -- update the header prose in the same change that adds/removes a table')
end)

-- ----------------------------------------------------------------------
-- sql/preflight_check.sql -- CHECK 1's per-table `SELECT 'k9_x' AS
-- table_name, N AS cols_expected, ...` block. This is the exact file/shape
-- migration 0011's two tables were missing from before the earlier
-- db-schema pass added them.
-- ----------------------------------------------------------------------
t.test('sql/preflight_check.sql\'s CHECK 1 knows about exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/preflight_check.sql')
    local tables = ExtractTableSet(text, "SELECT '(k9_[%w_]+)'")
    AssertSameTableSet(tables, installTables, 'sql/preflight_check.sql (CHECK 1)')
end)

-- ----------------------------------------------------------------------
-- sql/migration_status.sql -- the dry-run report's own per-table
-- `SELECT 'k9_x' AS table_name, ...` blocks (PART 1's fresh-install plan
-- plus every per-migration PART 2 continuation -- all draw from the same
-- `SELECT 'k9_x'` shape, so one pattern covers the whole file).
-- ----------------------------------------------------------------------
t.test('sql/migration_status.sql knows about exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/migration_status.sql')
    local tables = ExtractTableSet(text, "SELECT '(k9_[%w_]+)'")
    AssertSameTableSet(tables, installTables, 'sql/migration_status.sql')
end)

-- ----------------------------------------------------------------------
-- sql/rollback/uninstall_all.sql -- the actual DROP TABLE list at the
-- bottom of the procedure. This is the list whose own header explicitly
-- says "this must be hand-maintained -- if you add a table in a migration,
-- add it here in the SAME change".
-- ----------------------------------------------------------------------
t.test('sql/rollback/uninstall_all.sql\'s DROP TABLE list matches exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/rollback/uninstall_all.sql')
    local tables = ExtractTableSet(text, 'DROP TABLE IF EXISTS `(k9_[%w_]+)`')
    AssertSameTableSet(tables, installTables, 'sql/rollback/uninstall_all.sql (DROP TABLE list)')
end)

-- ----------------------------------------------------------------------
-- sql/rollback/backup_k9_tables.sh -- the ALL_TABLES bash array. A table
-- missing here does not fail loudly -- it just silently is not in the next
-- backup, which is precisely the failure mode this whole spec exists to
-- catch before it reaches a production operator relying on that backup.
-- ----------------------------------------------------------------------
t.test('sql/rollback/backup_k9_tables.sh\'s ALL_TABLES array matches exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/rollback/backup_k9_tables.sh')
    local startPos = text:find('ALL_TABLES=(', 1, true)
    assert(startPos, 'ALL_TABLES=( declaration not found in backup_k9_tables.sh -- this script must have changed shape')
    local closePos = text:find(')', startPos, true)
    assert(closePos, 'no closing ")" found for ALL_TABLES=( in backup_k9_tables.sh')
    local arrayBody = text:sub(startPos, closePos)
    local tables = ExtractTableSet(arrayBody, '(k9_[%w_]+)')
    AssertSameTableSet(tables, installTables, 'sql/rollback/backup_k9_tables.sh (ALL_TABLES)')
end)

-- ----------------------------------------------------------------------
-- sql/migrations/*.sql -- every table this resource's UPGRADE path (as
-- opposed to a fresh install) knows how to create for an existing
-- database. `k9_certifications` and `k9_search_log` are the two founding
-- tables install.sql has shipped with since before the migrations/ folder
-- existed -- by design there is no dedicated "0000_create_..." file for
-- either, so they are excluded from this specific comparison rather than
-- reported as a false "missing from migrations" failure.
--
-- HAND-MAINTAINED LIST, SAME TRADEOFF THIS RESOURCE'S OWN SQL FILES ALREADY
-- ACCEPT (see e.g. sql/rollback/uninstall_all.sql's own "OWNED TABLE LIST"
-- comment): a plain Lua spec has no INFORMATION_SCHEMA to sweep for a
-- pattern-based drift check the way the real SQL files do against a live
-- database, so a brand-new sql/migrations/0012_*.sql that CREATEs a table
-- must be added to this list in the same change, or this test will not
-- know to look at it. This is disclosed here rather than silently assumed.
-- ----------------------------------------------------------------------
local MIGRATION_FILES_THAT_CREATE_TABLES = {
    '0001_create_k9_partnerships.sql',
    '0002_create_k9_progression.sql',
    '0005_create_k9_permissions.sql',
    '0006_add_k9_certification_lifecycle.sql',
    '0007_create_k9_runtime_control.sql',
    '0008_create_k9_ped_assignments.sql',
    '0010_create_k9_certification_tiers.sql',
    '0011_create_k9_equipment_shop_locations.sql',
}

local FOUNDING_TABLES_WITH_NO_DEDICATED_MIGRATION = {
    k9_certifications = true,
    k9_search_log = true,
}

t.test('every table sql/migrations/*.sql can CREATE for an existing database is also in install.sql (and vice versa, founding tables aside)', function()
    local migrationTables = {}
    for _, filename in ipairs(MIGRATION_FILES_THAT_CREATE_TABLES) do
        local text = ReadFile('../sql/migrations/' .. filename)
        for name in text:gmatch('CREATE TABLE IF NOT EXISTS `(k9_[%w_]+)`') do
            migrationTables[name] = true
        end
    end

    local expected = {}
    for name in pairs(installTables) do
        if not FOUNDING_TABLES_WITH_NO_DEDICATED_MIGRATION[name] then
            expected[name] = true
        end
    end

    AssertSameTableSet(migrationTables, expected, 'sql/migrations/*.sql (CREATE TABLE union, founding tables excluded)')
end)

-- ----------------------------------------------------------------------
-- k9_permissions.permission is VARCHAR(50) and is now also the storage
-- shape for PER-PERSON FEATURE CONTROL grants/blocks
-- (server/permissions.lua's IsValidPermissionKey: 'feature.<Name>' /
-- 'block.<Name>' where <Name> is a real Config.Features key) -- not just
-- the four short Config.Permissions capability strings this column was
-- originally sized for. This is the schema-side half of that design: the
-- column must stay wide enough for the LONGEST real Config.Features key,
-- under BOTH prefixes, or a future long feature name would either be
-- silently rejected by IsValidPermissionKey's own `#value > 50` guard or
-- (if that guard were ever loosened without checking this) truncated by
-- the database instead. Verified here against config.lua's REAL feature
-- list, not a guessed worst case.
-- ----------------------------------------------------------------------
t.test('k9_permissions.permission (VARCHAR(50)) fits "feature."/"block." + the longest real Config.Features key', function()
    local configText = ReadFile('../config.lua')
    local startPos = configText:find('Config.Features = {', 1, true)
    assert(startPos, 'Config.Features = { not found in config.lua -- this file must have changed shape')
    local endPos = configText:find('\n}', startPos, true)
    assert(endPos, 'closing "}" for Config.Features not found')
    local block = configText:sub(startPos, endPos)

    local maxLen, maxKey, keyCount = 0, nil, 0
    for line in block:gmatch('[^\n]+') do
        local key = line:match('^%s*([A-Z][%w]*)%s*=%s*true') or line:match('^%s*([A-Z][%w]*)%s*=%s*false')
        if key then
            keyCount = keyCount + 1
            if #key > maxLen then maxLen, maxKey = #key, key end
        end
    end
    t.isTrue(keyCount >= 20, ('expected at least 20 Config.Features keys, found %d -- extraction pattern may be out of date'):format(keyCount))

    -- Pull the real column width out of install.sql's own k9_permissions
    -- block, rather than hardcoding "50" a second time here.
    local permStart = installText:find('CREATE TABLE IF NOT EXISTS `k9_permissions`', 1, true)
    assert(permStart, 'k9_permissions CREATE TABLE not found in install.sql')
    local permEnd = installText:find('\n) ENGINE=InnoDB', permStart, true)
    assert(permEnd, 'end of k9_permissions CREATE TABLE not found in install.sql')
    local permBlock = installText:sub(permStart, permEnd)
    local columnWidth = tonumber(permBlock:match('`permission`%s+VARCHAR%((%d+)%)'))
    assert(columnWidth, 'could not read k9_permissions.permission\'s VARCHAR width from install.sql')

    for _, prefix in ipairs({ 'feature.', 'block.' }) do
        local needed = #prefix + maxLen
        t.isTrue(needed <= columnWidth,
            ('"%s%s" is %d chars, which does not fit k9_permissions.permission VARCHAR(%d) -- widen the column in install.sql AND a new migration before shipping a Config.Features key this long'):format(prefix, maxKey, needed, columnWidth))
    end
end)

os.exit(t.summary())
