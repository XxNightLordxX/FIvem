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

os.exit(t.summary())
