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
-- 'announce.lua', 'selfcheck.lua', 'vehicle.lua', 'webhook.lua' added this
-- pass -- all four were missing from this hand-maintained snapshot; none of
-- the four registers any command today (confirmed by reading each file, not
-- assumed), so adding them changes nothing about either loop below, only
-- future-proofs this list against the exact "silently missing FILE" gap
-- class dangerwarn.lua's own command was found in. 'dogcharacter.lua'
-- (family #2, k9setdog/k9removedog) is added separately, alongside that
-- family's own HIDDEN_ALIAS_COMMANDS entries, since those two names need
-- the allowlist skip to land in the SAME change as this list gaining
-- visibility into them.
local SERVER_LUA_FILES = {
    'admin.lua', 'announce.lua', 'appearance.lua', 'bonetool.lua', 'certifications.lua', 'certtiers.lua',
    'combat.lua', 'cooldowns.lua', 'datastore.lua', 'defense.lua', 'dogcharacter.lua', 'entities.lua',
    'equipmentshop.lua', 'events.lua', 'exports.lua', 'fetch.lua', 'findalert.lua',
    'highcommand.lua', 'integrations.lua', 'inventory.lua', 'k9profiles.lua', 'kennel.lua',
    'leaderboard.lua', 'main.lua', 'medkit.lua', 'notify.lua', 'partnership.lua',
    'permissionkeycatalog.lua', 'permissions.lua', 'progression.lua', 'propattachment.lua',
    'pursuitsprint.lua', 'recall.lua', 'runtimecontrol.lua', 'sarcalls.lua', 'scentlineup.lua',
    'scenttrail.lua', 'search.lua', 'selfcheck.lua', 'tablet.lua', 'tenure.lua', 'tracking.lua', 'training.lua',
    'vehicle.lua', 'webhook.lua', 'wellbeing.lua', 'xptiers.lua',
}

-- 'announce.lua'/'dangerwarn.lua' added this pass -- both were missing from
-- this hand-maintained snapshot despite each registering a real command
-- (k9announce, qbx_k9unit:dangerWarnAlert) that ALREADY has a full
-- COMMAND_REFERENCE/DEFAULT_STRINGS/TABLET_STRING_KEYS entry -- confirmed by
-- reading html/tablet.js and client/tablet.lua directly, not assumed --
-- so this closes a pure list-gap with no documentation debt behind it,
-- the same class of gap dangerwarn.lua's own command was found in on the
-- client/commandsuggestions.lua side.
local CLIENT_LUA_FILES = {
    'agility.lua', 'announce.lua', 'appearance.lua', 'audio.lua', 'bonetool.lua', 'combat.lua', 'dangerwarn.lua', 'defense.lua',
    'equipmentshop.lua', 'exports.lua', 'featureblocks.lua', 'fetch.lua', 'findalert.lua',
    'hud.lua', 'inventory.lua', 'keybinds.lua', 'kennel.lua', 'leashvisual.lua', 'main.lua', 'medkit.lua',
    'movement.lua', 'partnership.lua', 'progression.lua', 'propattachment.lua', 'proximityaudio.lua',
    'pursuitsprint.lua', 'radial.lua', 'recall.lua', 'sarcalls.lua', 'scentlineup.lua',
    'scenttrail.lua', 'screenfx.lua', 'search.lua', 'tablet.lua', 'tracking.lua', 'training.lua',
    'vehicle.lua', 'vision.lua', 'wellbeing.lua',
}

-- HIDDEN_ALIAS_COMMANDS (COMMAND_CONSOLIDATION_SPEC.md §3) -- SAME
-- MEMBERSHIP as tests/commandsuggestions_spec.lua's own table of the same
-- name (kept as an independent, duplicated literal, same disclosed
-- tradeoff as this file's own SERVER_LUA_FILES/CLIENT_LUA_FILES snapshot,
-- not a shared `require` between two otherwise-independent spec files),
-- but shaped as name -> owning family here (not name -> true) so the
-- "Commands tab cleanup" test below can key off which FAMILY a name
-- belongs to -- see COMMANDS_TAB_CLEANUP_COMPLETE immediately below this
-- table for why.
local HIDDEN_ALIAS_COMMANDS = {
    -- family #1: audit (5 -> 1, 'k9audit') -- server/admin.lua
    k9auditcert = 'audit',
    k9auditpartner = 'audit',
    k9auditsearch = 'audit',
    k9auditxp = 'audit',
    k9auditdept = 'audit',
    -- family #2: dog record (2 -> 1, 'k9dog') -- server/dogcharacter.lua.
    -- Unlike audit's five originals, k9setdog/k9removedog have NEVER had a
    -- COMMAND_REFERENCE entry at all (a pre-existing, pre-this-pass gap,
    -- confirmed by reading html/tablet.js directly) -- so for THIS family
    -- specifically, the "skip from undocumented" behavior below is already
    -- the FINAL state, not an interim one: there is nothing to remove from
    -- COMMAND_REFERENCE later, only a new 'k9dog' entry to add (reported to
    -- project-lead separately). COMMANDS_TAB_CLEANUP_COMPLETE.dog_record can
    -- be set true as soon as that's confirmed -- it costs nothing either way
    -- since these two names were never documented to begin with.
    k9setdog = 'dog_record',
    k9removedog = 'dog_record',
    -- family #3: fetch (3 -> 1, 'k9fetch') -- client/fetch.lua. Same
    -- "never had a COMMAND_REFERENCE entry to begin with" shape as
    -- k9throwfetchball/k9dropfetchball/k9recallfetchball actually DO have
    -- entries today (confirmed by reading html/tablet.js) -- these three
    -- are NOT yet flagged complete below because their COMMAND_REFERENCE
    -- entries are real, live, and not yet removed (same interim state as
    -- audit's five).
    k9throwfetchball = 'fetch',
    k9dropfetchball = 'fetch',
    k9recallfetchball = 'fetch',
    -- family #4: training (3 -> 1, 'k9train') -- client/training.lua.
    -- Same interim shape as fetch's three -- real COMMAND_REFERENCE
    -- entries exist today (confirmed by reading html/tablet.js), not yet
    -- removed.
    k9training = 'training',
    k9trainsearch = 'training',
    k9trainbite = 'training',
    -- family #5: kennel (ADDITIVE, 'k9kennel') -- client/kennel.lua +
    -- client/keybinds.lua. k9deploykennel/k9exitkennel keep their own
    -- registration forever (see tests/commandsuggestions_spec.lua's own
    -- matching comment) -- only their COMMAND_REFERENCE visibility is
    -- targeted for removal here, once batched with the rest.
    k9deploykennel = 'kennel',
    k9exitkennel = 'kennel',
    -- family #7: permissions (2 -> 1, 'k9permission') -- server/permissions.lua.
    -- Unlike audit/fetch/training's "interim" state, this family's
    -- COMMAND_REFERENCE removal landed in the SAME change as the merge
    -- itself (no hot-file blocker for this family) -- see
    -- COMMANDS_TAB_CLEANUP_COMPLETE.permissions below, flipped true here,
    -- not left as a follow-up.
    k9grantpermission = 'permissions',
    k9revokepermission = 'permissions',
    -- family #8: online/offline certification pairs (10 -> 5) --
    -- server/certifications.lua. k9certify/k9decertify/k9settier/
    -- k9recertify/k9unspecialize keep their own existing canonical names
    -- (no new name introduced -- they now simply also accept the offline
    -- citizenid+job shape) and are NOT in this table; only their five
    -- *offline counterparts fold away. Same "landed in the same change,
    -- not deferred" shape as permissions above -- see
    -- COMMANDS_TAB_CLEANUP_COMPLETE.cert_pairs below.
    k9certifyoffline = 'cert_pairs',
    k9decertifyoffline = 'cert_pairs',
    k9settieroffline = 'cert_pairs',
    k9recertifyoffline = 'cert_pairs',
    k9unspecializeoffline = 'cert_pairs',
}

-- COMMANDS_TAB_CLEANUP_COMPLETE -- coordination table, project-lead-owned.
-- STARTS EMPTY ON PURPOSE (2026-08-26). html/tablet.js's own
-- COMMAND_REFERENCE currently still documents all five original audit
-- commands ALONGSIDE 'k9audit' (six entries total, matching
-- html/tests/tablet_command_reference_spec.js's own "21 admin-tier
-- commands" count) -- a real, disclosed, INTENTIONALLY TEMPORARY state:
-- removing those five is a coordinated edit across COMMAND_REFERENCE,
-- DEFAULT_STRINGS, client/tablet.lua's TABLET_STRING_KEYS, and
-- locales/en.json's tablet group all at once (this resource's own
-- tabletlocalization_spec.lua fails on a partial removal, per that spec's
-- own strict key-set-equality assertion), batched across every family at
-- once rather than once per family while a UI agent is live in
-- html/tablet.js.
--
-- THE TEST BELOW THEREFORE DOES NOT YET FAIL for any name in
-- HIDDEN_ALIAS_COMMANDS -- it only starts enforcing "this alias's five (or
-- however many) old names must no longer appear in COMMAND_REFERENCE" for
-- a family once that family's key is added HERE, in the SAME change that
-- actually does the removal in html/tablet.js. This is deliberately NOT a
-- "we'll add the guard afterwards" promise (this codebase has been bitten
-- by exactly that pattern before) -- the guard ships now, inert until the
-- fact it checks becomes true, then it starts enforcing itself the moment
-- that fact changes, with zero further code to write at that point beyond
-- flipping this one flag.
local COMMANDS_TAB_CLEANUP_COMPLETE = {
    -- audit = true, -- flip once html/tablet.js's COMMAND_REFERENCE (and
    -- its own DEFAULT_STRINGS/TABLET_STRING_KEYS/locales/en.json
    -- three-way-contract siblings) no longer list k9auditcert/
    -- k9auditpartner/k9auditsearch/k9auditxp/k9auditdept as their own
    -- separate entries.

    -- dog_record = true, set HONESTLY (not a placeholder): k9setdog/
    -- k9removedog never had a COMMAND_REFERENCE entry at all -- confirmed
    -- by reading html/tablet.js directly, not assumed -- so this family
    -- has zero Commands-tab cleanup debt to pay down; there was never
    -- anything for this flag to catch turning false. Unlike audit (still
    -- commented out above because that debt is real and outstanding),
    -- flipping this one true costs nothing and starts the guard actually
    -- enforcing "neither old name may creep into COMMAND_REFERENCE later"
    -- from this pass onward.
    dog_record = true,

    -- permissions/cert_pairs = true, SET HONESTLY (this pass, coder-backend):
    -- both families' html/tablet.js COMMAND_REFERENCE removals landed in
    -- THIS SAME CHANGE as their server-side merges (server/permissions.lua,
    -- server/certifications.lua) -- neither was blocked by a hot-file
    -- conflict the way k9dog/k9fetch/k9train/k9kennel were (see
    -- PENDING_NEW_CANONICAL_COMMANDS below -- N/A here anyway, since
    -- neither family introduces a genuinely NEW command name; k9permission
    -- is new but was added directly, with its own real COMMAND_REFERENCE
    -- entry, in this same change too).
    permissions = true,
    cert_pairs = true,
}

-- PENDING_NEW_CANONICAL_COMMANDS -- a DIFFERENT exception from
-- HIDDEN_ALIAS_COMMANDS, disclosed separately rather than folded into it:
-- these are the brand-NEW merged command names themselves (e.g. 'k9dog'),
-- real and registered, that do not YET have their own first-ever
-- COMMAND_REFERENCE/DEFAULT_STRINGS entry (and client/tablet.lua's matching
-- TABLET_STRING_KEYS triple) because html/tablet.js is a hot file this pass
-- cannot edit while a UI agent is live in it. This is the mirror image of
-- the audit situation (there, project-lead landed html/tablet.js's entry
-- BEFORE this pass's server/admin.lua registration existed; here, this
-- pass's registration exists BEFORE html/tablet.js has an entry for it) --
-- same underlying cause (this pass cannot touch that file directly),
-- opposite ordering. Reported to project-lead per family below; remove a
-- name from this table in the SAME change that adds its real
-- COMMAND_REFERENCE entry.
local PENDING_NEW_CANONICAL_COMMANDS = {
    k9dog = true, -- family #2 (dog record) -- needs cmdref_k9dog_usage/_does/_needs; see client/commandsuggestions.lua's own PENDING_LOCALE_KEYS for the exact interim _does/_usage text already in use client-side.
    k9fetch = true, -- family #3 (fetch) -- needs cmdref_k9fetch_usage/_does/_needs; same interim text location.
    k9train = true, -- family #4 (training) -- needs cmdref_k9train_usage/_does/_needs; same interim text location.
    k9kennel = true, -- family #5 (kennel, ADDITIVE) -- needs cmdref_k9kennel_usage/_does/_needs; same interim text location.
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
        -- HIDDEN_ALIAS_COMMANDS: skip a real, live command that a family
        -- merge deliberately stopped documenting as its own separate
        -- Commands-tab entry -- see that table's own header comment above
        -- for the current, disclosed exception (audit's five originals are
        -- still documented today; this skip is a no-op for them until/
        -- unless that changes, and becomes load-bearing the moment a
        -- future family DOES hide its old names from COMMAND_REFERENCE).
        if not documented[name] and not HIDDEN_ALIAS_COMMANDS[name] and not PENDING_NEW_CANONICAL_COMMANDS[name] then undocumented[#undocumented + 1] = name end
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

t.test('HIDDEN_ALIAS_COMMANDS GUARD: every allowlisted name is still a real, live RegisterCommand(...) call somewhere in server/*.lua or client/*.lua', function()
    -- Same "the allowlist can only ever excuse a name that is still live"
    -- property as tests/commandsuggestions_spec.lua's own identically-named
    -- test -- see that file's header comment for the full reasoning and the
    -- "delete this guard and watch it fail" proof.
    local realServer = RealCommandNamesIn('../server', SERVER_LUA_FILES)
    local realClient = RealCommandNamesIn('../client', CLIENT_LUA_FILES)
    local real = {}
    for name in pairs(realServer) do real[name] = true end
    for name in pairs(realClient) do real[name] = true end

    local phantomAliases = {}
    for name in pairs(HIDDEN_ALIAS_COMMANDS) do
        if not real[name] then phantomAliases[#phantomAliases + 1] = name end
    end

    if #phantomAliases > 0 then
        table.sort(phantomAliases)
        error((
            '%d name(s) in HIDDEN_ALIAS_COMMANDS are NOT a real RegisterCommand(...) call anywhere in server/*.lua ' ..
            'or client/*.lua: %s.\n\nA genuinely removed command must never keep hiding behind this allowlist -- ' ..
            'FIX THIS BY: removing the stale entry from HIDDEN_ALIAS_COMMANDS (if the command was truly deleted), ' ..
            'or restoring its RegisterCommand call (if it was deleted by mistake).'
        ):format(#phantomAliases, table.concat(phantomAliases, ', ')), 0)
    end
end)

t.test('PENDING_NEW_CANONICAL_COMMANDS GUARD: every name in it is (a) still a real, live RegisterCommand(...) call, and (b) NOT already documented -- a name that already landed in COMMAND_REFERENCE must be removed from this table in the same change, not left here as stale noise', function()
    local realServer = RealCommandNamesIn('../server', SERVER_LUA_FILES)
    local realClient = RealCommandNamesIn('../client', CLIENT_LUA_FILES)
    local real = {}
    for name in pairs(realServer) do real[name] = true end
    for name in pairs(realClient) do real[name] = true end

    local documented = ExtractDocumentedCommandNames(ReadFile('../html/tablet.js'))

    local phantomPending, stalePending = {}, {}
    for name in pairs(PENDING_NEW_CANONICAL_COMMANDS) do
        if not real[name] then phantomPending[#phantomPending + 1] = name end
        if documented[name] then stalePending[#stalePending + 1] = name end
    end

    if #phantomPending > 0 then
        table.sort(phantomPending)
        error(('%d name(s) in PENDING_NEW_CANONICAL_COMMANDS are NOT a real RegisterCommand(...) call: %s.'):format(#phantomPending, table.concat(phantomPending, ', ')), 0)
    end
    if #stalePending > 0 then
        table.sort(stalePending)
        error((
            '%d name(s) in PENDING_NEW_CANONICAL_COMMANDS already have a real COMMAND_REFERENCE entry: %s.\n\n' ..
            'FIX THIS BY: removing them from PENDING_NEW_CANONICAL_COMMANDS now that html/tablet.js documents them for real.'
        ):format(#stalePending, table.concat(stalePending, ', ')), 0)
    end
end)

t.test('COMMANDS TAB CLEANUP (currently inert, starts enforcing per-family the moment COMMANDS_TAB_CLEANUP_COMPLETE lists that family): once a family is flagged complete, none of its HIDDEN_ALIAS_COMMANDS names may still appear in html/tablet.js\'s COMMAND_REFERENCE', function()
    local documented = ExtractDocumentedCommandNames(ReadFile('../html/tablet.js'))

    local stillDocumented = {}
    for name, family in pairs(HIDDEN_ALIAS_COMMANDS) do
        if COMMANDS_TAB_CLEANUP_COMPLETE[family] and documented[name] then
            stillDocumented[#stillDocumented + 1] = name
        end
    end

    if #stillDocumented > 0 then
        table.sort(stillDocumented)
        error((
            '%d name(s) are flagged as COMMANDS_TAB_CLEANUP_COMPLETE but still have a COMMAND_REFERENCE entry in ' ..
            'html/tablet.js: %s.\n\nFIX THIS BY: removing their COMMAND_REFERENCE entries (and now-orphaned ' ..
            'DEFAULT_STRINGS keys, and client/tablet.lua\'s matching TABLET_STRING_KEYS entries) as part of the ' ..
            'same change that flips this family in COMMANDS_TAB_CLEANUP_COMPLETE -- or revert the flag if the ' ..
            'removal has not actually landed yet.'
        ):format(#stillDocumented, table.concat(stillDocumented, ', ')), 0)
    end
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
