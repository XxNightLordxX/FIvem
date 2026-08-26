--[[
    tests/commandsuggestions_spec.lua

    NEW FILE, pairing client/commandsuggestions.lua (also new this pass).
    Two jobs:

    1. DRIFT GUARD, same shape and same reasoning as
       tests/commandreferenceregistry_spec.lua's own LOAD-BEARING DRIFT
       GUARD test (read that file's header before touching this one's own
       extraction logic -- this follows it deliberately, not a second,
       independent design): proves client/commandsuggestions.lua's own
       hand-maintained COMMAND_SUGGESTIONS table names EXACTLY the same set
       of commands as the real `RegisterCommand('...')` calls across
       server/*.lua + client/*.lua, in both directions, using the
       IDENTICAL text-pattern extraction
       (`RegisterCommand%('([^']+)'`) that spec already established and
       this file's own header ("DERIVATION") explicitly says it reuses
       rather than re-deriving.

    2. BEHAVIOUR: loads the REAL client/commandsuggestions.lua into a
       sandbox and proves it actually calls
       `TriggerEvent('chat:addSuggestion', ...)` with the right command
       name, a real (or correctly-pending) locale-backed description, and
       correctly-parsed parameter hints -- for a representative sample
       spanning every shape this file's own header documents (a bare
       no-arg command, one with a single required param, one with a
       required-plus-optional pair, one of the seven colon-namespaced
       keybind commands, and all three dynamic-name commands under every
       relevant Config combination).

    HAND-MAINTAINED FILE LIST, SAME DISCLOSED TRADEOFF as
    tests/commandreferenceregistry_spec.lua's own SERVER_LUA_FILES/
    CLIENT_LUA_FILES (see that file's header for the full writeup) --
    SERVER_LUA_FILES/CLIENT_LUA_FILES below are an INDEPENDENT snapshot of
    the exact same real files, taken the same day (2026-08-26). A brand-new
    server/*.lua or client/*.lua file that registers its own command must
    be added to the matching list in BOTH this file and
    tests/commandreferenceregistry_spec.lua in the same change, or each
    spec will independently under-report the real command set (never over-
    report -- a missing FILE only ever yields FEWER real names, which can
    only make the "documented/suggested has no real match" side of each
    comparison fire, loudly, never let a real command through unnoticed).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

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

-- ============================================================================
-- PART 1: DRIFT GUARD
-- ============================================================================

-- Snapshot taken 2026-08-26 -- see this file's own header "HAND-MAINTAINED
-- FILE LIST" above for the disclosed tradeoff and obligation.
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
    'agility.lua', 'appearance.lua', 'audio.lua', 'bonetool.lua', 'combat.lua',
    'commandsuggestions.lua', 'defense.lua',
    'equipmentshop.lua', 'exports.lua', 'featureblocks.lua', 'fetch.lua', 'findalert.lua',
    'hud.lua', 'inventory.lua', 'keybinds.lua', 'kennel.lua', 'leashvisual.lua', 'main.lua', 'medkit.lua',
    'movement.lua', 'partnership.lua', 'progression.lua', 'propattachment.lua', 'proximityaudio.lua',
    'pursuitsprint.lua', 'radial.lua', 'recall.lua', 'sarcalls.lua', 'scentlineup.lua',
    'scenttrail.lua', 'screenfx.lua', 'search.lua', 'tablet.lua', 'tracking.lua', 'training.lua',
    'vehicle.lua', 'vision.lua', 'wellbeing.lua',
}

--- Identical shape to tests/commandreferenceregistry_spec.lua's own
--- ExtractRegisterCommandNames -- see that file's header "WIDENED, THIS
--- PASS" / "WIDENED TWICE" for why the pattern is `[^']+`, not a narrower
--- character class.
--- @param text string
--- @return table<string, boolean> set
local function ExtractRegisterCommandNames(text)
    local set = {}
    for name in text:gmatch("RegisterCommand%('([^']+)'") do
        set[name] = true
    end
    return set
end

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

--- Extracts every `command = '...'` value inside
--- client/commandsuggestions.lua's own `COMMAND_SUGGESTIONS` table literal,
--- by the same raw-text-pattern technique
--- tests/commandreferenceregistry_spec.lua's own ExtractDocumentedCommandNames
--- uses against html/tablet.js's COMMAND_REFERENCE.
--- @param text string
--- @return table<string, boolean> set
local function ExtractSuggestedCommandNames(text)
    local startPos = text:find('local COMMAND_SUGGESTIONS = {', 1, true)
    assert(startPos, 'local COMMAND_SUGGESTIONS = { not found in client/commandsuggestions.lua -- this file must have changed shape')
    local endPos = text:find('\n}', startPos, true)
    assert(endPos, 'closing "}" for COMMAND_SUGGESTIONS not found in client/commandsuggestions.lua')
    local body = text:sub(startPos, endPos)

    local set = {}
    for name in body:gmatch("command%s*=%s*'([^']+)'") do
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

t.test('LOAD-BEARING DRIFT GUARD: every real RegisterCommand(...) name across server/*.lua + client/*.lua has a matching entry in client/commandsuggestions.lua\'s COMMAND_SUGGESTIONS, and vice versa', function()
    local realServer = RealCommandNamesIn('../server', SERVER_LUA_FILES)
    local realClient = RealCommandNamesIn('../client', CLIENT_LUA_FILES)
    local real = {}
    for name in pairs(realServer) do real[name] = true end
    for name in pairs(realClient) do real[name] = true end

    local suggested = ExtractSuggestedCommandNames(ReadFile('../client/commandsuggestions.lua'))

    local unsuggested = {}
    for name in pairs(real) do
        if not suggested[name] then unsuggested[#unsuggested + 1] = name end
    end

    local phantom = {}
    for name in pairs(suggested) do
        if not real[name] then phantom[#phantom + 1] = name end
    end

    if #unsuggested > 0 then
        table.sort(unsuggested)
        error((
            '%d real RegisterCommand(...) name(s) exist in server/*.lua or client/*.lua with NO matching entry in ' ..
            "client/commandsuggestions.lua's COMMAND_SUGGESTIONS: %s.\n\nA player has no chat:addSuggestion for " ..
            'this command at all. FIX THIS BY: adding a { command = \'<name>\', keySuffix = \'<suffix>\' } entry to ' ..
            'COMMAND_SUGGESTIONS in the SAME change that registers the command -- or, if SERVER_LUA_FILES/' ..
            'CLIENT_LUA_FILES above is simply missing the new FILE the command lives in, add that filename to the ' ..
            'matching list in this spec instead.'
        ):format(#unsuggested, table.concat(unsuggested, ', ')), 0)
    end

    if #phantom > 0 then
        table.sort(phantom)
        error((
            "%d entr(ies) in client/commandsuggestions.lua's COMMAND_SUGGESTIONS name a command that is NOT a " ..
            'real RegisterCommand(...) call anywhere in server/*.lua or client/*.lua: %s.\n\nEither the command ' ..
            'was renamed/removed and this entry was never updated to match, or it is a typo. FIX THIS BY: deleting ' ..
            'the stale COMMAND_SUGGESTIONS entry, or correcting the spelling.'
        ):format(#phantom, table.concat(phantom, ', ')), 0)
    end

    -- Sanity floor, same "catastrophe detector, not a real limit" reasoning
    -- as tests/commandreferenceregistry_spec.lua's own -- guards against
    -- BOTH extractors silently matching nothing at all (a comment reformat,
    -- a rewritten RegisterCommand/table-literal shape), which would make
    -- the two loops above pass vacuously on two empty sets.
    local _, realCount = SortedKeys(real)
    local _, suggestedCount = SortedKeys(suggested)
    t.isTrue(realCount >= 30, ('sanity: only found %d real RegisterCommand name(s) -- expected at least 30'):format(realCount))
    t.isTrue(suggestedCount >= 30, ('sanity: only found %d COMMAND_SUGGESTIONS entr(ies) -- expected at least 30'):format(suggestedCount))
end)

t.test('no duplicate command names within COMMAND_SUGGESTIONS (a copy-pasted entry would silently mask a genuinely missing one)', function()
    local text = ReadFile('../client/commandsuggestions.lua')
    local startPos = text:find('local COMMAND_SUGGESTIONS = {', 1, true)
    local endPos = text:find('\n}', startPos, true)
    local body = text:sub(startPos, endPos)

    local seen = {}
    local duplicates = {}
    for name in body:gmatch("command%s*=%s*'([^']+)'") do
        if seen[name] then duplicates[#duplicates + 1] = name end
        seen[name] = true
    end

    if #duplicates > 0 then
        error('duplicate command entr(ies) in COMMAND_SUGGESTIONS: ' .. table.concat(duplicates, ', '), 0)
    end
end)

-- ============================================================================
-- PART 2: BEHAVIOUR -- load the real file, drive its real dispatcher.
-- ============================================================================

--- @param opts { config: table? }?
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local suggestionCalls = {}
    local function TriggerEvent(eventName, ...)
        suggestionCalls[#suggestionCalls + 1] = { event = eventName, args = { ... } }
    end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function GetCurrentResourceName() return 'qbx_k9unit' end
    local function fireResourceStart(resourceName)
        for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
            handler(resourceName)
        end
    end

    local env = Sandbox.newEnv({
        TriggerEvent = TriggerEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
    })
    Sandbox.loadInto('../config.lua', env)
    for key, value in pairs(opts.config or {}) do
        env.Config[key] = value
    end
    Sandbox.loadInto('../client/commandsuggestions.lua', env)

    return {
        env = env,
        Config = env.Config,
        fireResourceStart = fireResourceStart,
        suggestionCalls = suggestionCalls,
        --- @param command string -- WITHOUT the leading '/'
        --- @return table? call -- { event, args = { name, description, params } }
        findSuggestion = function(command)
            for _, call in ipairs(suggestionCalls) do
                if call.event == 'chat:addSuggestion' and call.args[1] == '/' .. command then
                    return { name = call.args[1], description = call.args[2], params = call.args[3] }
                end
            end
            return nil
        end,
    }
end

t.test('onResourceStart(qbx_k9unit): registers a chat:addSuggestion for every COMMAND_SUGGESTIONS entry, using the SAME description text as html/tablet.js\'s own Commands tab', function()
    local f = newFixture()
    f.fireResourceStart('qbx_k9unit')

    -- Bare, no-arg command.
    local sit = f.findSuggestion('k9sit')
    t.isNotNil(sit, '/k9sit must have a registered suggestion')
    t.equals(sit.description, Sandbox.locale('tablet.cmdref_k9sit_does'), 'k9sit description must match the tablet\'s own Commands tab text verbatim')
    t.equals(#sit.params, 0, 'k9sit takes no arguments -- params must be empty')

    -- Single required param.
    local certify = f.findSuggestion('k9certify')
    t.isNotNil(certify, '/k9certify must have a registered suggestion')
    t.equals(certify.description, Sandbox.locale('tablet.cmdref_k9certify_does'))
    t.equals(#certify.params, 1)
    t.equals(certify.params[1].name, 'server id')
    t.equals(certify.params[1].help, '', 'a required param carries no "Optional." marker')

    -- Required + optional pair.
    local decertify = f.findSuggestion('k9decertify')
    t.isNotNil(decertify, '/k9decertify must have a registered suggestion')
    t.equals(#decertify.params, 2)
    t.equals(decertify.params[1].name, 'server id')
    t.equals(decertify.params[1].help, '')
    t.equals(decertify.params[2].name, 'reason')
    t.equals(decertify.params[2].help, 'Optional.', 'an optional param must carry the "Optional." marker')

    -- A colon-namespaced keybind-paired command, whose keySuffix is
    -- de-namespaced -- proves the keySuffix indirection actually resolves
    -- to the right locale keys, not just the literal command name.
    local vault = f.findSuggestion('qbx_k9unit:vault')
    t.isNotNil(vault, '/qbx_k9unit:vault must have a registered suggestion')
    t.equals(vault.description, Sandbox.locale('tablet.cmdref_vault_does'))
end)

t.test('onResourceStart(qbx_k9unit): dynamic-name commands (tablet/hq-tablet/compat) are suggested under their REAL, CONFIGURED name, not a hardcoded literal', function()
    local f = newFixture()
    -- Merge onto the real Config.Features/Config.CommandTablet/Config.Compat
    -- rather than replacing either table wholesale (config.lua's own copies
    -- already carry every OTHER flag/field commandsuggestions.lua does not
    -- care about -- this only forces the fields this test actually
    -- exercises).
    f.Config.Features.CommandTablet = true
    f.Config.CommandTablet = { openMode = 'command', command = 'k9customtablet', highCommandCommand = 'k9customhq' }
    f.Config.Compat = { diagnosticCommand = 'k9customcompat' }
    f.fireResourceStart('qbx_k9unit')

    local tablet = f.findSuggestion('k9customtablet')
    t.isNotNil(tablet, 'the tablet command must be suggested under its CONFIGURED name, not the shipped default k9tablet')
    t.isTrue(type(tablet.description) == 'string' and #tablet.description > 0, 'the tablet suggestion must carry a non-empty description')
    t.isNil(f.findSuggestion('k9tablet'), 'the shipped DEFAULT name must NOT also get a suggestion once renamed')

    local hq = f.findSuggestion('k9customhq')
    t.isNotNil(hq, 'the high-command tablet command must be suggested under its CONFIGURED name')

    local compat = f.findSuggestion('k9customcompat')
    t.isNotNil(compat, 'the compat diagnostic command must be suggested under its CONFIGURED name')
end)

t.test('onResourceStart(qbx_k9unit): CommandTablet openMode = \'item\' suppresses the plain tablet command suggestion but NOT the always-on high-command one', function()
    local f = newFixture()
    f.Config.Features.CommandTablet = true
    f.Config.CommandTablet = { openMode = 'item', command = 'k9tablet', highCommandCommand = 'k9hqtablet' }
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9tablet'), 'openMode = \'item\' means the plain command is never registered by client/tablet.lua itself, so it must not be suggested either')
    t.isNotNil(f.findSuggestion('k9hqtablet'), 'the high-command shortcut is unconditional on openMode, per client/tablet.lua\'s own SECOND ENTRY POINT contract')
end)

t.test('onResourceStart(qbx_k9unit): Config.Features.CommandTablet = false suggests NEITHER tablet command, mirroring client/tablet.lua\'s own file-level early return', function()
    local f = newFixture()
    f.Config.Features.CommandTablet = false
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9tablet'))
    t.isNil(f.findSuggestion('k9hqtablet'))
end)

t.test('onResourceStart(qbx_k9unit): Config.Compat.diagnosticCommand = false suggests no compat command, mirroring shared/compat/core.lua\'s own "false means disabled" contract', function()
    local f = newFixture()
    f.Config.Compat = { diagnosticCommand = false }
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9compat'))
end)

t.test('onResourceStart fires for THIS resource and for a "chat" resource restarting, never for an unrelated resource', function()
    local f = newFixture()
    t.equals(#f.suggestionCalls, 0, 'nothing registered before onResourceStart ever fires')

    f.fireResourceStart('some_other_resource')
    t.equals(#f.suggestionCalls, 0, 'an unrelated resource starting must not trigger registration')

    f.fireResourceStart('chat')
    t.isTrue(#f.suggestionCalls > 0, 'a "chat" resource (re)starting must (re-)trigger registration, so a stock chat resource restarting independently does not lose every suggestion this resource ever sent it')
end)

t.test('re-firing onResourceStart is safe -- calls TriggerEvent again for every command with no error, never accumulates state of its own', function()
    local f = newFixture()
    f.fireResourceStart('qbx_k9unit')
    local firstCount = #f.suggestionCalls
    t.isTrue(firstCount > 30, 'sanity: the first pass actually registered a realistic number of suggestions')

    local ok = pcall(f.fireResourceStart, 'qbx_k9unit')
    t.isTrue(ok, 're-firing onResourceStart must not throw')
    t.equals(#f.suggestionCalls, firstCount * 2, 'a second pass calls TriggerEvent again for every command (this file itself holds no dedup state -- the real chat resource\'s own addSuggestion is what replaces-by-name, per this file\'s own header "RE-REGISTRATION SAFETY")')
end)

os.exit(t.summary())
