--[[
    tests/featureflagexistence_spec.lua

    ONE GUARANTEE: every `Config.Features.<Name>` that real code gates on
    either EXISTS in the shipped config.lua, or is on the small allowlist
    below of keys that are absent on purpose.

    WHY THIS FILE EXISTS. A feature flag that code reads but config never
    defines resolves to `nil`. `if not Config.Features.Foo then return end`
    then fires on every client, forever, and the entire feature goes dark --
    silently. No error, no warning, no failing test. luacheck cannot see it
    (a table lookup is valid Lua whatever the key). server/selfcheck.lua
    catches the OPPOSITE direction (a config key nothing recognises) but not
    this one. Every spec in this suite that touches feature flags builds its
    own fixture Config, so none of them read the shipped file to find out
    whether the key is really there.

    That gap was found the honest way: a maintenance pass resolved every
    `Config.*` path referenced anywhere in client/ and server/ against the
    real config table and found `Config.Features.ScentTrailHunt` missing --
    which turned out to be INTENTIONAL (the feature was removed
    owner-approved as redundant; see Config.Features' own "REMOVED" block).
    But nothing anywhere distinguished "deliberately removed" from
    "renamed/typo'd last week and now silently dead", and the second case
    looks exactly like the first from the outside.

    WHAT MAKES THIS A REAL GUARD AND NOT A RESTATEMENT. The allowlist is
    the whole point. Adding a key to it is a deliberate, reviewable act with
    a written reason; forgetting to define a flag you just started gating on
    is not. So a rename that kills a feature goes RED here, while an
    intentional removal stays green only once someone says so in writing.

    The allowlist is also checked in the other direction: an entry that is
    no longer absent (someone restored the flag) fails too, so this file
    cannot rot into a list of stale exemptions that quietly permits real
    breakage.

    WHY THIS CHECKS THE RESOLVED TABLE, NOT THE LITERAL IN config.lua.
    Config.Features is not the last word on its own contents: the
    FeatureGroups resolution at the bottom of config.lua WRITES BACK into
    it, both for family children (`Config.Features[flatName] = enabled`)
    and for standalone/base keys (`Tablet = { base = 'CommandTablet' }`
    means Config.FeatureGroups.Tablet.enabled decides
    Config.Features.CommandTablet, whatever the literal above says).

    So for any grouped flag, the literal in the Config.Features table is
    only a pre-grouping default -- config.lua keeps the originals in
    Config.FeaturesBeforeGrouping precisely because they are not the final
    answer. Renaming such a key in the literal table does NOT kill the
    feature; the resolver puts it straight back, and the feature keeps
    working. That is correct behaviour and this test must not flag it.

    Loading the real config and reading what survives resolution is
    therefore the only check that matches what a running server actually
    sees. Found the hard way: an early version of this file was
    "red-proven" by renaming a flag in the literal table, stayed green, and
    looked broken -- it was measuring the right thing all along.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Keys that real code gates on and config.lua deliberately does NOT
--- define. Each entry must say why, and must be a decision someone
--- actually made -- never a parking space for "we'll get to it".
---
--- A nil flag means the feature is OFF, not broken: every consumer of these
--- keys is written to no-op cleanly when the lookup returns nil (that is
--- what makes the removal safe in the first place). If you add a key here,
--- confirm that is true of its consumers before you do.
local INTENTIONALLY_ABSENT = {
    ScentTrailHunt = 'Removed outright, owner-approved, judged redundant with the '
        .. 'scent-tracking action (see Config.Features\' own "REMOVED" block, '
        .. 'README.md, and FEATURE_STRUCTURE_SPEC.md §2.2.1). client/scenttrail.lua '
        .. 'and server/scenttrail.lua are kept intact and inert on purpose -- both '
        .. 'top-level-return on this exact nil lookup -- so restoring it is a '
        .. 'one-line config change and nothing else.',
}

--- Every distinct `Config.Features.<Name>` referenced from real source.
--- Reads the files off disk rather than taking a curated list, which is the
--- only version of this test worth having: a hand-maintained list would
--- need updating by the same person who forgot to define the flag.
---
--- Scans client/ and server/ only. Deliberately NOT tests/ (fixtures invent
--- flag names freely, by design) and NOT config.lua itself (its own
--- FeatureGroups map and prose mention names that are not gates).
---
--- Comments are stripped before matching -- see the note inside.
--- @return table<string, string[]> name -> list of "file:line" citations
local function ReferencedFeatureFlags()
    local found = {}

    local listing = assert(io.popen('ls ../client/*.lua ../server/*.lua 2>/dev/null'))
    local paths = {}
    for line in listing:lines() do paths[#paths + 1] = line end
    listing:close()

    for _, path in ipairs(paths) do
        local handle = io.open(path, 'r')
        if handle then
            local text = handle:read('a')
            handle:close()

            -- STRIP COMMENTS BEFORE MATCHING, both kinds, and block
            -- comments FIRST. This is the difference between a guard and a
            -- noise generator: this codebase's doc-comments are enormous
            -- and routinely NAME feature flags while discussing them, and
            -- several use `Config.Features.X` as a literal placeholder in
            -- prose. A scan that misses block comments reports those as
            -- undefined flags, which is exactly how a test like this gets
            -- muted by the first person who trusts it.
            --
            -- Long-bracket forms (--[[ ]], --[==[ ]==]) are handled by
            -- level, so a nested example inside a comment cannot end it
            -- early. Line comments go second, once block spans are gone.
            -- NEWLINES ARE PRESERVED when a span is removed, so the line
            -- numbers in the citations below stay true to the real file.
            -- Collapsing a 40-line block comment to one space renumbers
            -- everything after it, and this test's whole output is a list
            -- of "go look at file:line" pointers -- sending someone to the
            -- wrong line is most of the way to sending them nowhere.
            -- The pattern captures the WHOLE match as capture 1, because
            -- gsub hands a replacement function its CAPTURES, never the
            -- match itself. An earlier attempt captured only the bracket
            -- level `(=*)`, so the function received an empty string,
            -- returned an empty string, and silently deleted every newline
            -- it was written to preserve -- the fix looked applied and
            -- changed nothing. Caught by re-reading the emitted citations
            -- rather than trusting the edit.
            local function blankKeepingLines(whole)
                return (whole:gsub('[^\n]', ''))
            end
            text = text:gsub('(%-%-%[(=*)%[.-%]%2%])', blankKeepingLines)
            text = text:gsub('%-%-[^\n]*', '')

            local lineNo = 1
            for line in (text .. '\n'):gmatch('([^\n]*)\n') do
                for name in line:gmatch('Config%.Features%.([A-Za-z0-9_]+)') do
                    found[name] = found[name] or {}
                    local citation = path:gsub('^%.%./', '') .. ':' .. lineNo
                    local already = false
                    for _, c in ipairs(found[name]) do
                        if c == citation then already = true break end
                    end
                    if not already then found[name][#found[name] + 1] = citation end
                end
                lineNo = lineNo + 1
            end
        end
    end

    return found
end

local env = Sandbox.newEnv({ print = function() end })
Sandbox.loadInto('../config.lua', env)
local shipped = env.Config and env.Config.Features

t.test('sanity: the real config.lua loads and Config.Features is a populated table', function()
    -- Without this, every assertion below would pass vacuously against an
    -- empty table -- the exact failure mode a guard like this must not have.
    t.equals(type(shipped), 'table')
    local count = 0
    for _ in pairs(shipped) do count = count + 1 end
    t.isTrue(count > 40, 'expected the full shipped flag set, got ' .. tostring(count) .. ' keys')
end)

t.test('sanity: the scan finds real gates, so a silent scan failure cannot make this file pass vacuously', function()
    local refs = ReferencedFeatureFlags()
    local count = 0
    for _ in pairs(refs) do count = count + 1 end
    t.isTrue(count > 30,
        'expected to find Config.Features.<Name> references across client/ and server/, found ' .. tostring(count)
        .. ' -- if this dropped to zero the grep or the paths are wrong and every check below is meaningless')
end)

t.test('every Config.Features flag that code gates on is DEFINED in the shipped config.lua', function()
    local refs = ReferencedFeatureFlags()
    local missing = {}

    for name, citations in pairs(refs) do
        if shipped[name] == nil and INTENTIONALLY_ABSENT[name] == nil then
            missing[#missing + 1] = name .. ' (read at ' .. table.concat(citations, ', ') .. ')'
        end
    end
    table.sort(missing)

    t.equals(#missing, 0,
        'These Config.Features keys are gated on in real code but do not exist in config.lua, so they read nil '
        .. 'and every feature behind them is silently OFF on a stock install:\n  - '
        .. table.concat(missing, '\n  - ')
        .. '\nIf that is a mistake (a rename, a typo, a flag someone forgot to add), define the key in '
        .. 'config.lua. If it is deliberate, add it to INTENTIONALLY_ABSENT at the top of this file with the '
        .. 'reason -- that is the whole point of this test: making the difference between the two explicit.')
end)

t.test('every INTENTIONALLY_ABSENT entry is still genuinely absent -- the allowlist cannot rot into stale exemptions', function()
    local stale = {}
    for name in pairs(INTENTIONALLY_ABSENT) do
        if shipped[name] ~= nil then stale[#stale + 1] = name end
    end
    table.sort(stale)

    t.equals(#stale, 0,
        'These keys are on the INTENTIONALLY_ABSENT allowlist but config.lua now DOES define them: '
        .. table.concat(stale, ', ')
        .. '. The feature was restored -- remove the allowlist entry so this file goes back to actually '
        .. 'guarding it, rather than carrying a permanent exemption nobody re-reads.')
end)

t.test('every INTENTIONALLY_ABSENT entry is still referenced by real code -- an exemption for a key nothing reads is dead weight', function()
    local refs = ReferencedFeatureFlags()
    local orphaned = {}
    for name in pairs(INTENTIONALLY_ABSENT) do
        if refs[name] == nil then orphaned[#orphaned + 1] = name end
    end
    table.sort(orphaned)

    t.equals(#orphaned, 0,
        'These keys are allowlisted as intentionally absent, but no code in client/ or server/ gates on them '
        .. 'any more: ' .. table.concat(orphaned, ', ')
        .. '. The consuming code was deleted or renamed; drop the allowlist entry too.')
end)

t.test('every INTENTIONALLY_ABSENT entry carries a real written reason, not a placeholder', function()
    -- An allowlist whose entries say "TODO" would pass every check above
    -- while defeating the purpose of having one.
    for name, reason in pairs(INTENTIONALLY_ABSENT) do
        t.equals(type(reason), 'string', name .. ' must have a string reason')
        t.isTrue(#reason >= 60,
            name .. "'s reason is too short to be a real justification -- say what was decided and where it is "
            .. 'written down, so the next reader does not have to re-derive it')
        t.isFalse(reason:upper():find('TODO', 1, true) ~= nil, name .. "'s reason is a placeholder, not a decision")
    end
end)

t.test('THE CASE THAT PROMPTED THIS FILE: ScentTrailHunt is absent, allowlisted, and its consumers really do top-level-return on it', function()
    -- Pins the specific shape that makes this removal safe rather than
    -- broken: both files bail at the top on the nil lookup, so nothing
    -- below runs half-initialised. If someone later moves that guard
    -- deeper into either file, this fails and the removal needs re-checking.
    t.isNil(shipped.ScentTrailHunt, 'sanity: still removed from config.lua')
    t.isNotNil(INTENTIONALLY_ABSENT.ScentTrailHunt, 'sanity: still allowlisted')

    -- The two halves guard themselves DIFFERENTLY, and both are correct:
    --   client/scenttrail.lua top-level-returns, so the command and every
    --     thread below it are never registered at all on any client.
    --   server/scenttrail.lua registers its handlers and re-checks the flag
    --     inside each one, which is the right shape server-side -- a
    --     registered-but-refusing callback answers a spoofed call properly
    --     instead of leaving the event name unhandled.
    -- Asserting one shape for both would have been wrong, and did fail here
    -- first time; each is pinned as what it actually is.
    local clientHandle = assert(io.open('../client/scenttrail.lua', 'r'))
    local clientText = clientHandle:read('a')
    clientHandle:close()
    t.isTrue(clientText:find('if not Config%.Features%.ScentTrailHunt then return end') ~= nil,
        'client/scenttrail.lua must still bail at the top on the nil flag -- that top-level return is what '
        .. 'makes the removal inert rather than half-loaded')

    local serverHandle = assert(io.open('../server/scenttrail.lua', 'r'))
    local serverText = serverHandle:read('a')
    serverHandle:close()
    t.isTrue(serverText:find('Config%.Features%.ScentTrailHunt') ~= nil,
        'server/scenttrail.lua must still re-check the flag inside its handlers, so a call that reaches the '
        .. 'server while the feature is off is refused rather than silently unhandled')
end)

-- ======================================================================
-- SHIPPED DEFAULT: Config.Database.enabled
--
-- Pinned here because nothing else pinned it, and the whole suite stayed
-- green when the default was flipped -- every datastore test builds its
-- own fixture Config (correctly: it tests BOTH backends), so none of them
-- read the shipped file. A default this consequential should not be
-- changeable without a test saying so out loud.
--
-- It is not a correctness constraint. Both values are fully supported and
-- exercised: server/datastore.lua's K9Store has one branch per function
-- and tests/datastore_spec.lua runs both. This is a "say it deliberately"
-- guard on a product decision, in the same spirit as INTENTIONALLY_ABSENT
-- above.
-- ======================================================================

t.test('Config.Database.enabled ships FALSE -- the resource is drag-and-drop out of the box', function()
    t.equals(type(env.Config.Database), 'table', 'the Config.Database block must exist at all')
    t.isFalse(env.Config.Database.enabled,
        'The shipped default was deliberately set to false so the resource runs with no .sql import: drop it in, '
        .. 'start it, everything works. If you are flipping this to true, that is a real product decision -- the '
        .. 'trade is that with it OFF nothing survives a restart (certifications, XP, partnerships, permissions, '
        .. 'callsigns, themes) and no audit trail is written at all. Update this test, config.lua\'s own '
        .. 'Config.Database block, README.md\'s Installing section, and sql/DATABASE_GUIDE.md together -- all four '
        .. 'state the default in prose and will otherwise contradict each other.')
end)

t.test('DatabaseEnabled fails SAFE to true on a missing Config.Database -- an operator who deletes the block gets persistence, not silent data loss', function()
    -- The one asymmetry worth pinning about this flag: only a LITERAL
    -- false turns the database off. A missing or malformed block means
    -- "on", so a config edit that accidentally removes it cannot quietly
    -- stop writing everyone's progress to disk -- the failure mode is a
    -- loud missing-table error, never silent amnesia.
    local probe = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', probe)
    probe.Config.Database = nil

    local store = Sandbox.newEnv({ Config = probe.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    t.isTrue(store.K9Store.IsDatabaseEnabled(),
        'with Config.Database absent entirely, the store must report ENABLED -- failing safe toward persistence')
end)

t.test('DRAG-AND-DROP IS REAL: with the shipped config, NO K9Store function touches MySQL at all', function()
    -- The guarantee the shipped default rests on. server/datastore.lua's
    -- architecture is "one `if DatabaseEnabled() then <SQL> else <memory>
    -- end` branch per function" -- 100+ functions, each of which has to
    -- remember the branch. One function added without it would issue a
    -- real query on a server that has no tables, and the operator would
    -- see a missing-table error for a feature they never set up.
    --
    -- Rather than eyeball 100+ branches, this hands the store a MySQL
    -- object that ERRORS on any field access whatsoever and then calls
    -- every function it exposes. Nothing may reach it.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    t.isFalse(cfgEnv.Config.Database.enabled, 'sanity: this test only means something with the DB off')

    local touched = {}
    local trapMySQL = setmetatable({}, { __index = function(_, key)
        touched[#touched + 1] = tostring(key)
        error('MySQL.' .. tostring(key) .. ' was accessed with the database OFF', 2)
    end })

    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = trapMySQL, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)

    local names = {}
    for name, value in pairs(store.K9Store) do
        if type(value) == 'function' then names[#names + 1] = name end
    end
    table.sort(names)
    t.isTrue(#names > 90, 'sanity: expected the full K9Store surface, found ' .. #names)

    -- Benign args. A function that rejects them returns early or raises on
    -- its own arithmetic -- either way it has already passed the branch
    -- point, which is the only thing being measured here.
    for _, name in ipairs(names) do
        pcall(store.K9Store[name], 'CID_TEST', 'police', 1)
    end

    t.equals(#touched, 0,
        'These MySQL fields were accessed with Config.Database.enabled = false: ' .. table.concat(touched, ', ')
        .. '. A K9Store function is missing its `if DatabaseEnabled() then ... else ... end` branch, so a '
        .. 'drag-and-drop server with no tables would hit a real query. Add the memory-mode branch.')
end)

t.test('DRAG-AND-DROP IS REAL: memory mode actually REMEMBERS within the session -- it is not a silent no-op', function()
    -- The other half, and the easier one to get wrong: a store that
    -- discarded every write would also pass the test above. Memory mode
    -- has to behave like a database that simply forgets on restart, not
    -- like a black hole -- otherwise XP is unearnable rather than
    -- unsaved, and the mode is broken in a way nobody notices until a
    -- player asks why their rank never moves.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    local K9 = store.K9Store

    t.isNil(K9.XP_Get('CID_FRESH'), 'a citizenid with no history reads as nil, exactly as it would from an empty table')

    K9.XP_UpsertAdd('CID_FRESH', 25)
    t.equals(K9.XP_Get('CID_FRESH'), 25, 'a write must be readable back in the same session')
    K9.XP_UpsertAdd('CID_FRESH', 10)
    t.equals(K9.XP_Get('CID_FRESH'), 35, 'and must ACCUMULATE, not overwrite')

    K9.HandlerXP_UpsertAdd('CID_FRESH', 10)
    t.equals(K9.HandlerXP_Get('CID_FRESH'), 10, 'the handler ladder is stored independently of the K9 one')
    t.equals(K9.XP_Get('CID_FRESH'), 35, 'and writing one must not disturb the other')
end)

t.test('MEMORY MODE KEEPS AN AUDIT TRAIL -- capped and session-scoped, but genuinely there', function()
    -- Pinned because the documentation said the exact opposite in four
    -- places at once ("no record of who certified whom, no search log, no
    -- permission-grant history... not a smaller record. None."). It was
    -- wrong, and it mattered: it would have talked an operator out of
    -- checking a dispute they could actually have checked.
    --
    -- The real limits are different and smaller -- capped, and lost on
    -- restart -- and that is what the docs now say. This test is what stops
    -- either claim drifting again.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    local K9 = store.K9Store
    t.isFalse(K9.IsDatabaseEnabled(), 'sanity: memory mode')

    K9.Cert_Insert('CID_AUDIT', 'police', 'GRANTER1', nil)
    t.equals(#K9.Cert_GetHistory('CID_AUDIT', 10), 1, 'certification history is recorded and readable')

    K9.SearchLog_Insert('CID_AUDIT', 'police', 'vehicle', 'PLATE1', nil, 'clean', 0, nil)
    t.equals(#K9.SearchLog_GetRecent(10), 1, 'the search log is recorded and readable')
    t.equals(#K9.SearchLog_GetByOfficer('CID_AUDIT', 10), 1, 'and is queryable by officer, as the tablet does')

    K9.OverrideAudit_Append('FeatureX', 'grant', 'ADMIN1', 'Chief', 'reason')
    t.equals(#K9.OverrideAudit_GetRecent(10), 1, 'the override audit is recorded and readable')
end)

t.test('MEMORY MODE audit growth is CAPPED, so a long-running drag-and-drop server cannot leak memory through it', function()
    -- The other half of the corrected claim, and the reason "capped" is
    -- the honest word rather than "complete". With the database off now
    -- being the shipped default, an unbounded audit table would be a slow
    -- memory leak on exactly the servers least likely to notice.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    local K9 = store.K9Store

    for i = 1, 520 do
        K9.SearchLog_Insert('CID_CAP', 'police', 'vehicle', 'P' .. i, nil, 'clean', 0, nil)
    end

    -- Asked for far more than the cap, so the number returned is the
    -- store's own ceiling rather than the query limit.
    t.equals(#K9.SearchLog_GetRecent(100000), 500,
        'the search log must stop at its 500-row memory cap, discarding oldest-first, not grow without bound')
end)

t.test('DRAG-AND-DROP IS REAL: every table the schema creates has a memory-mode gate, so no feature is SQL-only', function()
    -- The structural half of the drag-and-drop guarantee. The other tests
    -- above prove no K9Store function reaches MySQL and that memory mode
    -- remembers -- but both only cover tables K9Store already knows about.
    -- A table added to sql/install.sql with a real-SQL accessor and no
    -- memory branch would slip past them entirely: its own feature would
    -- query a table the operator never created, on the SHIPPED default,
    -- and fail for them alone.
    --
    -- So this walks the schema itself and requires each table to be gated
    -- somewhere. Almost all of them are gated inside server/datastore.lua;
    -- k9_dog_characters is a disclosed exception gated in
    -- server/dogcharacter.lua instead (that file could not edit datastore
    -- when the table was added, and uses the same public
    -- K9Store.IsDatabaseEnabled(tableName) check). Both shapes count --
    -- what must never happen is a table gated NOWHERE.
    local function stripComments(text)
        text = text:gsub('(%-%-%[(=*)%[.-%]%2%])', function(w) return (w:gsub('[^\n]', '')) end)
        return (text:gsub('%-%-[^\n]*', ''))
    end

    local function readStripped(path)
        local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
        local text = handle:read('a')
        handle:close()
        return stripComments(text)
    end

    local schema = readStripped('../sql/install.sql')
    -- `[%w_]+`, NOT `%w+`: Lua's %w is alphanumeric and does NOT include
    -- the underscore, so `k9_%w+` matched only single-underscore names and
    -- silently found 17 of the 28 tables. The sanity assertion below is
    -- what caught it -- without it this test would have passed while
    -- checking well under half the schema.
    local tables = {}
    for name in schema:gmatch('CREATE TABLE%s+IF NOT EXISTS%s+`?(k9_[%w_]+)`?') do tables[name:lower()] = true end
    for name in schema:gmatch('CREATE TABLE%s+`?(k9_[%w_]+)`?') do tables[name:lower()] = true end

    local sorted = {}
    for name in pairs(tables) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    t.isTrue(#sorted >= 25, 'sanity: expected the full shipped schema, found ' .. #sorted .. ' k9_ tables')

    -- Every server file may hold a gate, not just datastore.lua -- see the
    -- k9_dog_characters exception above.
    local listing = assert(io.popen('ls ../server/*.lua 2>/dev/null'))
    local gateText = {}
    for path in listing:lines() do gateText[#gateText + 1] = readStripped(path) end
    listing:close()
    local allServer = table.concat(gateText, '\n')

    local ungated = {}
    for _, name in ipairs(sorted) do
        if not allServer:find("DatabaseEnabled('" .. name .. "')", 1, true) then
            ungated[#ungated + 1] = name
        end
    end

    t.equals(#ungated, 0,
        'These tables exist in sql/install.sql but nothing anywhere calls DatabaseEnabled(\'<table>\') for them: '
        .. table.concat(ungated, ', ')
        .. '. On the shipped default (Config.Database.enabled = false) their feature would query a table the '
        .. 'operator never created. Add the memory-mode branch, gated per-table, in server/datastore.lua -- or, '
        .. 'if that file genuinely cannot own it, via K9Store.IsDatabaseEnabled(\'<table>\') where it does live, '
        .. 'the way server/dogcharacter.lua does.')
end)


-- ======================================================================
-- STATUS CLAIMS: a comment that says what a flag SHIPS AS must be right
--
-- FOUND BY THIS CHECK, 2026-08-31: server/tenure.lua's header stated
-- "config.lua carries `Config.Features.PartnershipTenureBonus = false`
-- (still off by default...)". It ships TRUE (config.lua:362), and has for
-- some time -- the flag was flipped on and the header was not updated. So
-- the file that OWNS the tenure bonus told anyone reading it the feature
-- was inert, while it was quietly awarding 15/40/100 XP at the 1/7/30-day
-- milestones. An owner auditing why their XP economy pays out more than
-- expected would read that and rule it out.
--
-- WHY THIS IS NARROW ON PURPOSE. Only sentences that ASSERT a default are
-- checked -- "ships", "by default", "defaults to", "off by default". A bare
-- `Config.X = false` in a comment is almost always conditional prose ("the
-- Config.Features.RadialMenu=false path") or an instruction to the operator
-- ("Set `Config.Database.enabled = true`"), both correct and neither a
-- claim. A first draft of this check without that filter reported 24
-- disagreements, every one of them a false positive.
-- ======================================================================

t.test('every comment that asserts what a config flag SHIPS AS matches the shipped value', function()
    local shippedConfig = env.Config
    t.isNotNil(shippedConfig, 'shipped Config must load')

    --- Flattens Config into dotted paths -> stringified scalar values.
    local flat = {}
    local function flatten(tbl, prefix)
        for key, value in pairs(tbl) do
            local path = prefix .. '.' .. tostring(key)
            if type(value) == 'table' then
                flatten(value, path)
            elseif type(value) == 'boolean' then
                flat[path] = tostring(value)
            end
        end
    end
    flatten(shippedConfig, 'Config')

    local STATUS_WORDS = {
        'ships', 'shipped', 'by default', 'defaults to', 'default is',
        'off by default', 'on by default', 'still off', 'still on',
    }
    local function assertsADefault(text)
        local lowered = text:lower()
        for _, word in ipairs(STATUS_WORDS) do
            if lowered:find(word, 1, true) then return true end
        end
        return false
    end

    local files = {}
    local pipe = io.popen([[cd .. && find client server shared -name '*.lua' | sort]])
    if pipe then
        for line in pipe:lines() do files[#files + 1] = line end
        pipe:close()
    end
    t.isTrue(#files > 50, ('expected >50 lua files to scan, found %d'):format(#files))

    local wrong = {}
    for _, rel in ipairs(files) do
        local fh = io.open('../' .. rel, 'r')
        if fh then
            local lines = {}
            for line in fh:lines() do lines[#lines + 1] = line end
            fh:close()
            -- BLOCK COMMENTS COUNT TOO. The first draft of this check only
            -- matched `^%s*%-%-` line comments, and stayed GREEN against the
            -- very defect that motivated it: server/tenure.lua's wrong claim
            -- lives inside a `--[[ ]]` header block, whose lines start with
            -- plain text. Caught by running the check against the reverted
            -- defect instead of trusting a passing run.
            local inBlock = false
            for i, line in ipairs(lines) do
                local opensBlock = line:find('%-%-%[%[')
                local closesBlock = line:find('%]%]')
                local isComment = inBlock or line:match('^%s*%-%-') ~= nil
                if opensBlock and not closesBlock then inBlock = true end
                if closesBlock then inBlock = false end
                if isComment then
                    -- Neighbour lines included: these are wrapped comment
                    -- blocks, so the asserting phrase and the flag routinely
                    -- sit on different lines.
                    local ctx = table.concat({ lines[i - 1] or '', line, lines[i + 1] or '' }, ' ')
                    if assertsADefault(ctx) then
                        for path, claimed in line:gmatch('(Config%.[%a_][%w_.]*)%s*=%s*`?(%a+)`?') do
                            if (claimed == 'true' or claimed == 'false')
                                and flat[path] ~= nil and flat[path] ~= claimed then
                                wrong[#wrong + 1] = ('%s:%d  %s -- comment says %s, ships %s')
                                    :format(rel, i, path, claimed, flat[path])
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(wrong)
    t.equals(#wrong, 0,
        'these comments state a shipped default that is wrong:\n    ' .. table.concat(wrong, '\n    ') ..
        '\n  Fix the sentence to match config.lua, or reword it so it is not asserting a default.')
end)

os.exit(t.summary())
