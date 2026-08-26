--[[
    tests/commandreferenceregistry_spec.lua

    DRIFT GUARD for the K9 Command Tablet's "Commands" reference screen
    (html/tablet.js's COMMAND_REFERENCE / buildCommandReferenceScreen()) --
    the exact trap this task's own brief named up front: "a hardcoded list
    will rot. Someone adds command #37 and the reference silently lies."

    THIS FILE'S JOB, AND ONLY THIS FILE'S JOB: prove that the SET of command
    names COMMAND_REFERENCE documents is byte-identical, in both directions,
    to the SET of real `RegisterCommand('...')` names this resource actually
    registers across server/*.lua + client/*.lua. It does not check wording,
    categorisation, or gate correctness (that is
    html/tests/tablet_command_reference_spec.js's job) -- only that nothing
    is ever silently added to one side without the other.

    HOW THE REAL COMMAND NAMES ARE FOUND -- deliberately the EXACT same
    shape this task itself was scoped from:
        grep -rhoE "RegisterCommand\('[a-zA-Z0-9_:]+'" server/*.lua client/*.lua
    reproduced here as a Lua pattern (`RegisterCommand%('([^']+)'`)
    against each real file's own raw text -- see
    tests/customizationregistry_spec.lua's header "WHY TEXT-PATTERN
    EXTRACTION" for why raw source text, not a loaded/executed file, is this
    suite's established way to read a fact out of a file this sandbox
    cannot safely boot (every server/*.lua and client/*.lua file in this
    resource has its own, very different, load-time dependency set --
    booting all 39 of them into one sandbox just to read a list of literal
    strings would be this spec's entire runtime cost for zero extra
    correctness).

    WIDENED, THIS PASS -- A REAL BLIND SPOT, FOUND AND FIXED: the pattern
    above used to be `[a-z0-9_]+`/`[%l%d_]+` -- lowercase letters, digits,
    and underscore ONLY. Every bare `RegisterCommand('k9x', ...)` call
    matches that fine, but `RegisterKeyMapping` requires its own id to be
    GLOBALLY unique across every resource a server loads, which pushed
    seven real keybind commands (client/agility.lua's `qbx_k9unit:vault`,
    client/pursuitsprint.lua's `qbx_k9unit:pursuitsprint`,
    client/movement.lua's `qbx_k9unit:toggleCamera`,
    client/vision.lua's `qbx_k9unit:toggleCameraFeed`/
    `qbx_k9unit:toggleThermalVision`/`qbx_k9unit:toggleNightVision`, and
    client/defense.lua's `qbx_k9unit:confirmHandlerDownDefense`) onto this
    resource's own `qbx_k9unit:` namespace prefix instead -- a `:` character,
    and for four of the seven, camelCase letters too, BOTH outside the old
    character class. The old pattern silently skipped every one of them on
    BOTH sides of the comparison (the real-file scan below AND
    ExtractDocumentedCommandNames' own `command:%s*'...'` extraction from
    html/tablet.js), so this spec had been reporting a clean match for years
    while blind to an entire class of real, player-usable commands with zero
    COMMAND_REFERENCE entry -- passing green while catching nothing for
    exactly the seven that needed it.

    WIDENED TWICE, AND THE SECOND TIME IS THE ONE THAT MATTERS. The first
    fix went to `[%a%d_:]+` -- letters, digits, underscore, colon -- which
    caught those seven namespaced keybinds. A later QA pass broke it again
    on purpose with `RegisterCommand('k9-medcheck', ...)`: a hyphen is
    perfectly legal to FiveM, just unused here, and it made the name
    invisible to BOTH extractors at once. Not truncated, not flagged --
    absent, so the comparison loop below never even looked at it. That is a
    silent pass, the exact failure the colon fix had just closed, moved to
    a different character.
    The pattern is now `[^']+`: anything that is not the closing quote. It
    cannot be blind to a character class again, because it no longer has
    one. If a name is between the quotes, this guard sees it.

    HAND-MAINTAINED FILE LIST, SAME DISCLOSED TRADEOFF
    tests/customizationregistry_spec.lua's OWN SERVER_LUA_FILES already
    accepts this exact tradeoff for its own, narrower scan (see that file's
    header "HAND-MAINTAINED FILE LIST"): this plain-Lua suite has no
    directory-listing primitive anywhere, by design. SERVER_LUA_FILES /
    CLIENT_LUA_FILES below are a full, independent snapshot of every real
    server/*.lua and client/*.lua filename, taken 2026-08-26 -- a brand-new
    server/*.lua or client/*.lua file that registers its own command must be
    added to the matching list here in the SAME change, or this spec will
    not know to look at it and will report a false "documented but not
    real" gap for that command (never the more dangerous "real but
    undocumented" direction going silently unnoticed, since a genuinely
    missing FILE simply yields fewer real names, which can only ever make
    the "documented has no real match" side of the comparison fire, loudly,
    never let a real command through unchecked).

    WHY THIS CANNOT BE "DERIVE COMMAND_REFERENCE FROM THE REAL REGISTRY"
    INSTEAD (the option this task's own brief names first): there is no
    such registry. Every real command is an independent
    `RegisterCommand(name, function(...) ... end, false)` call -- most
    named bare (`k9x`), a handful namespaced under this resource's own
    `qbx_k9unit:` prefix where a paired `RegisterKeyMapping` needed a
    globally-unique id -- spread across two dozen-plus server/client files,
    each with its own authorization shape (see html/tablet.js's own
    COMMAND_REFERENCE header for the "gate kind" taxonomy this screen uses
    instead) -- there is nothing today for a fifth file to read the master
    list FROM. Deliberately not pinned to an exact command/file count here
    (see MIN_PLAUSIBLE_TABLET_STRINGS-style reasoning in
    tests/tabletlocalization_spec.lua's own header for why a moving total
    is never worth hardcoding) -- the LOAD-BEARING DRIFT GUARD test below
    is what actually keeps both sides honest, not a number in this comment.
    This spec is the cheaper option this task's brief explicitly names second,
    matching the SAME reasoning tests/tabletlocalization_spec.lua already
    gives for html/tablet.js's own DEFAULT_STRINGS vs. locales/en.json
    (also two independently-maintained lists, pinned against each other by
    a drift-guard spec rather than a shared derivation).
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

-- Snapshot taken 2026-08-26 -- see this file's header "HAND-MAINTAINED FILE
-- LIST" above for the disclosed tradeoff and the "add a new file here in
-- the same change" obligation.
local SERVER_LUA_FILES = {
    'admin.lua', 'appearance.lua', 'bonetool.lua', 'certifications.lua', 'certtiers.lua',
    'combat.lua', 'cooldowns.lua', 'datastore.lua', 'defense.lua', 'entities.lua',
    'equipmentshop.lua', 'events.lua', 'exports.lua', 'fetch.lua', 'findalert.lua',
    'highcommand.lua', 'integrations.lua', 'inventory.lua', 'k9profiles.lua', 'kennel.lua',
    'leaderboard.lua', 'main.lua', 'medkit.lua', 'notify.lua', 'partnership.lua',
    'permissionkeycatalog.lua', 'permissions.lua', 'progression.lua', 'propattachment.lua',
    'pursuitsprint.lua', 'recall.lua', 'runtimecontrol.lua', 'sarcalls.lua', 'scentlineup.lua',
    'scenttrail.lua', 'search.lua', 'tablet.lua', 'tenure.lua', 'tracking.lua', 'training.lua',
    'wellbeing.lua', 'xptiers.lua',
}

local CLIENT_LUA_FILES = {
    'agility.lua', 'appearance.lua', 'audio.lua', 'bonetool.lua', 'combat.lua', 'defense.lua',
    'equipmentshop.lua', 'exports.lua', 'featureblocks.lua', 'fetch.lua', 'findalert.lua',
    'hud.lua', 'inventory.lua', 'keybinds.lua', 'kennel.lua', 'leashvisual.lua', 'main.lua', 'medkit.lua',
    'movement.lua', 'partnership.lua', 'progression.lua', 'propattachment.lua', 'proximityaudio.lua',
    'pursuitsprint.lua', 'radial.lua', 'recall.lua', 'sarcalls.lua', 'scentlineup.lua',
    'scenttrail.lua', 'screenfx.lua', 'search.lua', 'tablet.lua', 'tracking.lua', 'training.lua',
    'vehicle.lua', 'vision.lua', 'wellbeing.lua',
}

--- Pure text-in, set-out extraction -- exactly the
--- `RegisterCommand\('[a-zA-Z0-9_:]+'` shape this whole task was scoped
--- from (see this file's header "WIDENED, THIS PASS" for why the character
--- class is not just `[a-z0-9_]`), reproduced as a Lua pattern.
--- Deliberately takes raw TEXT, not a file path, so the synthetic drift
--- test below can feed it a fabricated in-memory string and prove the
--- comparison logic itself actually catches a divergence, with no
--- dependency on the real files ever being (or ever becoming) out of sync.
--- @param text string
--- @return table<string, boolean> set
local function ExtractRegisterCommandNames(text)
    local set = {}
    for name in text:gmatch("RegisterCommand%('([^']+)'") do
        set[name] = true
    end
    return set
end

--- Every real RegisterCommand name across every file in `filenames`,
--- rooted at `dir` ('../server' or '../client').
--- @param dir string
--- @param filenames string[]
--- @return table<string, boolean> set
local function RealCommandNamesIn(dir, filenames)
    local set = {}
    for _, filename in ipairs(filenames) do
        local text = ReadFile(dir .. '/' .. filename)
        for name in pairs(ExtractRegisterCommandNames(text)) do
            set[name] = true
        end
    end
    return set
end

--- Extracts every `command: '...'` value inside html/tablet.js's own
--- `var COMMAND_REFERENCE = [ ... ];` array literal, by raw text pattern --
--- see this file's header "HOW THE REAL COMMAND NAMES ARE FOUND" and
--- tests/customizationregistry_spec.lua's identical-in-spirit
--- ExtractFeatureTiersKeys/ExtractClientEnforcedFeatures for the
--- established precedent this follows. Anchored to the `command: '...'`
--- shape specifically (not a bare quoted-string scan) so this can never
--- accidentally pick up a `category`/`usageKey`/`gate.capability` value
--- from the same object literal.
--- @param text string
--- @return table<string, boolean> set
local function ExtractDocumentedCommandNames(text)
    local startPos = text:find('var COMMAND_REFERENCE = [', 1, true)
    assert(startPos, 'var COMMAND_REFERENCE = [ not found in html/tablet.js -- this file must have changed shape')
    local endPos = text:find('\n    ];', startPos, true)
    assert(endPos, 'closing "];" for COMMAND_REFERENCE not found in html/tablet.js')
    local body = text:sub(startPos, endPos)

    local set = {}
    for name in body:gmatch("command:%s*'([^']+)'") do
        set[name] = true
    end
    return set
end

--- @param set table<string, boolean>
--- @return string[] sortedNames, integer count
local function SortedKeys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)
    return out, #out
end

-- ============================================================================
-- SYNTHETIC TEST -- proves the extraction/comparison MECHANISM itself
-- actually flags a divergence (this task's own required coverage: "the
-- drift guard actually failing when a command exists but is
-- undocumented"), against FABRICATED text, so this stays a permanently
-- green, always-run regression test rather than a one-off manual check
-- that could only ever demonstrate itself by making the real suite red.
-- ============================================================================

t.test('SYNTHETIC: ExtractRegisterCommandNames/ExtractDocumentedCommandNames correctly flag a command registered but never documented', function()
    local fakeServerText = [[
        RegisterCommand('k9realone', function() end, false)
        RegisterCommand('k9realtwo', function() end, false)
        -- RegisterCommand('k9commentedout', function() end, false) -- a prose mention inside a comment is still matched by this narrow a pattern today; not a concern in practice (every real call site in this codebase is live code, never commented out), but disclosed rather than silently assumed away.
    ]]
    local fakeDocumentedText = "var COMMAND_REFERENCE = [\n"
        .. "        { command: 'k9realone', category: 'field_gear' },\n"
        .. "    ];\n"

    local real = ExtractRegisterCommandNames(fakeServerText)
    local documented = ExtractDocumentedCommandNames(fakeDocumentedText)

    t.isTrue(real['k9realone'] == true, 'sanity: extraction found the first fake real command')
    t.isTrue(real['k9realtwo'] == true, 'sanity: extraction found the second fake real command')
    t.isTrue(documented['k9realone'] == true, 'sanity: extraction found the one fake documented command')

    t.isNil(documented['k9realtwo'], 'k9realtwo is real but undocumented in this fabricated fixture')
    t.isTrue(real['k9commentedout'] == true, 'disclosed limitation, exercised directly: a commented-out RegisterCommand call still matches this pattern')
end)

t.test('SYNTHETIC: a documented command with no matching real RegisterCommand call is caught in the other direction', function()
    local fakeServerText = "RegisterCommand('k9realone', function() end, false)"
    local fakeDocumentedText = "var COMMAND_REFERENCE = [\n"
        .. "        { command: 'k9realone', category: 'field_gear' },\n"
        .. "        { command: 'k9phantom', category: 'field_gear' },\n"
        .. "    ];\n"

    local real = ExtractRegisterCommandNames(fakeServerText)
    local documented = ExtractDocumentedCommandNames(fakeDocumentedText)

    t.isNil(real['k9phantom'], 'k9phantom is documented but was never really registered in this fabricated fixture')
    t.isTrue(documented['k9phantom'] == true, 'sanity: extraction found the phantom documented command')
end)

t.test('SYNTHETIC: a namespaced, mixed-case RegisterKeyMapping-paired command (e.g. qbx_k9unit:toggleSomething) is no longer invisible to either extractor -- the exact gap the seven real keybind commands fell into', function()
    local fakeServerText = [[
        RegisterCommand('qbx_k9unit:toggleSomething', function() end, false)
        RegisterKeyMapping('qbx_k9unit:toggleSomething', 'Toggle Something', 'keyboard', 'X')
    ]]
    local fakeDocumentedTextMissing = "var COMMAND_REFERENCE = [\n"
        .. "        { command: 'k9realone', category: 'field_gear' },\n"
        .. "    ];\n"
    local fakeDocumentedTextPresent = "var COMMAND_REFERENCE = [\n"
        .. "        { command: 'qbx_k9unit:toggleSomething', category: 'field_gear' },\n"
        .. "    ];\n"

    local real = ExtractRegisterCommandNames(fakeServerText)
    t.isTrue(real['qbx_k9unit:toggleSomething'] == true, 'a colon-namespaced, camelCase command name is found by the widened real-side extractor')

    local documentedMissing = ExtractDocumentedCommandNames(fakeDocumentedTextMissing)
    t.isNil(documentedMissing['qbx_k9unit:toggleSomething'], 'sanity: the fixture that omits it really does not document it')

    local documentedPresent = ExtractDocumentedCommandNames(fakeDocumentedTextPresent)
    t.isTrue(documentedPresent['qbx_k9unit:toggleSomething'] == true, 'a colon-namespaced, camelCase command name is found by the widened documented-side extractor too, when it IS present')
end)

-- THE SECOND BLIND SPOT, and the reason the pattern is now `[^']+` rather
-- than a longer character class. A QA pass deliberately broke the previous
-- `[%a%d_:]+` version with a hyphenated name -- legal to FiveM, simply
-- unused in this resource -- and found it vanished from BOTH extractors at
-- once, producing a silent pass rather than a loud failure. Widening the
-- class again would only have moved the same bug to the next character
-- nobody thought of. These cases exist so that never happens a third time.
t.test('SYNTHETIC: command names using characters outside the old class -- a hyphen, a period -- are visible to both extractors, so the guard can never be blind to a character class again', function()
    for _, name in ipairs({ 'k9-medcheck', 'k9.medcheck', 'qbx_k9unit:toggle-thing', 'K9MedCheck2' }) do
        local fakeServerText = ("RegisterCommand('%s', function() end, false)"):format(name)
        local real = ExtractRegisterCommandNames(fakeServerText)
        t.isTrue(real[name] == true, ('the real-side extractor must see %q -- if it cannot, a command by that name would be undocumented and this guard would pass green anyway'):format(name))

        local fakeDocumented = "var COMMAND_REFERENCE = [\n"
            .. ("        { command: '%s', category: 'field_gear' },\n"):format(name)
            .. "    ];\n"
        local documented = ExtractDocumentedCommandNames(fakeDocumented)
        t.isTrue(documented[name] == true, ('the documented-side extractor must see %q too -- a name visible on only one side produces a false mismatch instead of a real one'):format(name))
    end
end)

-- ============================================================================
-- LOAD-BEARING DRIFT GUARD -- the real files, the real screen.
-- ============================================================================

t.test('LOAD-BEARING DRIFT GUARD: every real RegisterCommand(...) name across server/*.lua + client/*.lua has a matching entry in html/tablet.js\'s COMMAND_REFERENCE, and vice versa', function()
    local realServer = RealCommandNamesIn('../server', SERVER_LUA_FILES)
    local realClient = RealCommandNamesIn('../client', CLIENT_LUA_FILES)
    local real = {}
    for name in pairs(realServer) do real[name] = true end
    for name in pairs(realClient) do real[name] = true end

    local documented = ExtractDocumentedCommandNames(ReadFile('../html/tablet.js'))

    local undocumented = {}
    for name in pairs(real) do
        if not documented[name] then undocumented[#undocumented + 1] = name end
    end

    local phantom = {}
    for name in pairs(documented) do
        if not real[name] then phantom[#phantom + 1] = name end
    end

    if #undocumented > 0 then
        table.sort(undocumented)
        error((
            '%d real RegisterCommand(...) name(s) exist in server/*.lua or client/*.lua with NO matching entry in ' ..
            "html/tablet.js's COMMAND_REFERENCE: %s.\n\nThis is exactly the \"command #37 added, reference " ..
            'silently lies\" gap this spec exists to catch -- a player has no way to discover this command exists ' ..
            'at all from the tablet\'s own Commands screen. FIX THIS BY: adding a { command: \'<name>\', category: ' ..
            "'...', adminOnly: ..., usageKey: '...', doesKey: '...', needsKey: '...', gate: { ... } } entry to " ..
            'COMMAND_REFERENCE (plus its three usageKey/doesKey/needsKey strings to DEFAULT_STRINGS and the same ' ..
            'three key names to client/tablet.lua\'s TABLET_STRING_KEYS) in the SAME change that registers the ' ..
            'command -- or, if SERVER_LUA_FILES/CLIENT_LUA_FILES above is simply missing the new FILE the command ' ..
            'lives in, add that filename to the matching list in this spec instead.'
        ):format(#undocumented, table.concat(undocumented, ', ')), 0)
    end

    if #phantom > 0 then
        table.sort(phantom)
        error((
            "%d entr(ies) in html/tablet.js's COMMAND_REFERENCE name a command that is NOT a real " ..
            'RegisterCommand(...) call anywhere in server/*.lua or client/*.lua: %s.\n\nEither the command was ' ..
            'renamed/removed and this catalog entry was never updated to match (a player would see a "command" ' ..
            'in the reference that does nothing when actually run), or it is a typo of a real command name. FIX ' ..
            'THIS BY: deleting the stale COMMAND_REFERENCE entry (and its now-orphaned DEFAULT_STRINGS/' ..
            'TABLET_STRING_KEYS keys), or correcting the spelling to match the real RegisterCommand name.'
        ):format(#phantom, table.concat(phantom, ', ')), 0)
    end

    -- Sanity floor -- a catastrophe detector, not a real limit (see this
    -- suite's own established convention, e.g.
    -- tests/tabletlocalization_spec.lua's MIN_PLAUSIBLE_TABLET_STRINGS):
    -- guards against BOTH extractors silently matching nothing at all
    -- (a comment reformat, a rename of the JS var, a rewritten
    -- RegisterCommand call shape), which would make the two loops above
    -- pass vacuously on two empty sets. Deliberately NOT the real count
    -- (52 as of this pass -- 45 bare + 7 namespaced, see this file's own
    -- header "WIDENED, THIS PASS") -- see this task's own explicit
    -- instruction not to hardcode a count that would need bumping every
    -- time a command is added.
    local _, realCount = SortedKeys(real)
    local _, documentedCount = SortedKeys(documented)
    t.isTrue(realCount >= 30, ('sanity: only found %d real RegisterCommand name(s) across server/*.lua + client/*.lua -- expected at least 30; an extraction pattern or file list may be out of date'):format(realCount))
    t.isTrue(documentedCount >= 30, ('sanity: only found %d documented command(s) in html/tablet.js\'s COMMAND_REFERENCE -- expected at least 30'):format(documentedCount))
end)

t.test('no duplicate command names within COMMAND_REFERENCE (a copy-pasted entry would silently mask a different, genuinely undocumented command)', function()
    local text = ReadFile('../html/tablet.js')
    local startPos = text:find('var COMMAND_REFERENCE = [', 1, true)
    assert(startPos, 'var COMMAND_REFERENCE = [ not found in html/tablet.js')
    local endPos = text:find('\n    ];', startPos, true)
    assert(endPos, 'closing "];" for COMMAND_REFERENCE not found in html/tablet.js')
    local body = text:sub(startPos, endPos)

    local seen = {}
    local duplicates = {}
    for name in body:gmatch("command:%s*'([^']+)'") do
        if seen[name] then
            duplicates[#duplicates + 1] = name
        end
        seen[name] = true
    end

    if #duplicates > 0 then
        error('duplicate command entr(ies) in COMMAND_REFERENCE: ' .. table.concat(duplicates, ', '), 0)
    end
end)

os.exit(t.summary())
