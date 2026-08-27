--[[
    qbx_k9unit/client/commandsuggestions.lua

    NEW FILE. Registers `chat:addSuggestion` for every chat command this
    resource actually registers, so a player typing `/` sees this
    resource's ~55 commands in their own client's autocomplete, instead of
    the tablet's Commands tab being the ONLY place any of them are
    documented (a fresh-install walkthrough finding: `grep -rn
    "chat:addSuggestion"` across this whole resource returned ZERO hits
    before this file existed).

    ======================================================================
    DERIVATION -- "DO NOT HAND-TYPE A LIST" (this task's own stated risk),
    ADDRESSED THE SAME WAY tests/commandreferenceregistry_spec.lua ALREADY
    ADDRESSES IT FOR html/tablet.js's COMMAND_REFERENCE:

    There is no runtime registry this file could read a command list FROM
    instead. FiveM's `GetRegisteredCommands()` only reports commands
    registered ON THE SIDE IT IS CALLED FROM (client sees client-registered
    commands, server sees server-registered ones) -- it cannot tell this
    CLIENT file about the ~35 commands server/*.lua registers, which is the
    entire reason `chat:addSuggestion` exists as a manual, client-side
    registration step in the first place (this is standard, well-known
    FiveM/CitizenFX behaviour, not something this resource invented or
    could design around). So the command list below is, like
    COMMAND_REFERENCE itself, a HAND-MAINTAINED TABLE -- the exact thing
    this task's own brief warns rots silently -- but DRIFT-GUARDED the same
    way: tests/commandsuggestions_spec.lua extracts every real
    RegisterCommand call's literal, quoted first argument from
    server/*.lua + client/*.lua using the IDENTICAL text-pattern approach
    tests/commandreferenceregistry_spec.lua already established (a Lua
    pattern matching a single-quoted string right after the opening paren,
    the exact same widened character class that spec's own header
    documents fixing twice already, reused rather than re-derived), and
    fails loudly if this file's own COMMAND_SUGGESTIONS table (below) ever
    drifts from that real set in either direction. Add a command's
    registration and this file's own matching entry in the SAME change,
    exactly like COMMAND_REFERENCE's own established discipline.

    (NOTE for anyone editing THIS header: avoid ever writing a literal
    `RegisterCommand(` immediately followed by a single-quoted string
    anywhere in this file's own prose, including this note -- doing so
    once already made tests/commandsuggestions_spec.lua's own drift-guard
    extraction mistake this file's DOC COMMENTS for real registration
    calls, since that spec scans every file's raw text, this one included.
    Describe the shape in words instead, as done throughout this header.)

    THREE DYNAMIC-NAME COMMANDS (config-driven, not a call with a literal,
    quoted command name at all, so NEITHER this file's own drift-guard spec
    NOR tests/commandreferenceregistry_spec.lua's own text-pattern
    extraction can ever see them): client/tablet.lua's two
    `RegisterCommand(tabletCommand, ...)` / `RegisterCommand(hqTabletCommand,
    ...)` calls (Config.CommandTablet.command / .highCommandCommand) and
    shared/compat/core.lua's `RegisterCommand(cmdName, ...)` call
    (Config.Compat.diagnosticCommand). These are handled separately, below
    the main table, reading the SAME config fields those two files
    themselves read to decide the real, live command name -- an operator
    who renames `k9tablet` to something else in config.lua gets a matching
    suggestion automatically, with no edit needed here.

    ======================================================================
    DESCRIPTIONS -- REUSED, NOT DUPLICATED: html/tablet.js's own
    COMMAND_REFERENCE (the Commands tab) already carries a
    `tablet.cmdref_<name>_does` / `tablet.cmdref_<name>_usage` locale-key
    pair for every one of the 54 literally-named commands below (52 as of
    this file's own original landing, +2 this pass: k9eat/k9drink,
    Config.Features.HungerThirstSystem, client/wellbeing.lua -- see that
    file's own tablet.cmdref_k9eat_*/tablet.cmdref_k9drink_* keys). Reused
    here VERBATIM via `locale('tablet.cmdref_' .. keySuffix .. '_does')` /
    `..._usage` rather than minting a second, parallel copy of the same
    player-facing sentence under a new key -- duplicating already-landed
    strings would have been exactly the wrong move this task's own
    brief warned against. `keySuffix` matches the literal command name for
    every entry except the 7 colon-namespaced, keybind-paired commands
    (`qbx_k9unit:vault` etc.), whose tablet.js locale keys were minted
    under a shorter, de-namespaced suffix (`vault`, `toggle_camera`, ...) --
    see COMMAND_SUGGESTIONS' own `keySuffix` field for each.

    The three dynamic-name commands have NO existing tablet.js entry at all
    (tests/commandreferenceregistry_spec.lua's own SERVER_LUA_FILES/
    CLIENT_LUA_FILES scan cannot see a `RegisterCommand(someVariable, ...)`
    call any more than this file's drift-guard spec can, and shared/compat/
    core.lua is not even IN either of those two file lists) -- so those
    three need genuinely NEW locale text. See the NEW LOCALE KEYS NEEDED
    block right above DYNAMIC_NAME_COMMANDS below for the exact keys/text
    handed to whoever owns locales/en.json.

    ======================================================================
    PARAMETER HINTS: `ParseUsageParams` below extracts each `<required>` /
    `[optional]` token, IN ORDER, straight out of the SAME
    `tablet.cmdref_<name>_usage` string every description above already
    reuses (e.g. "/k9decertify <server id> [reason]" ->
    `{ {name='server id'}, {name='reason', help='Optional.'} }`) -- so a
    parameter hint can never name an argument the tablet's own Commands tab
    doesn't already agree exists, and a future usage-string edit updates
    both surfaces from the one place it was made. This is a generic bracket
    parser, not a per-command special case: it makes no attempt to
    represent a variadic tail (`k9lineup <server id> <server id> ...`
    surfaces as two identically-named `server id` parameter hints, the
    "..." itself is not represented) or an enumerated-choice token as
    anything other than one literal parameter name
    (`<officer|plate|person|recent>` surfaces as one parameter named
    exactly that) -- both are disclosed, accepted simplifications: FiveM's
    own chat suggestion UI has no native concept of either shape, so a
    fully faithful representation is not available to reach for regardless.

    ======================================================================
    SAFE WITH NO CHAT RESOURCE LISTENING: `chat:addSuggestion` is fired via
    a plain, LOCAL `TriggerEvent` (never `TriggerServerEvent`/
    `TriggerClientEvent` — no network round trip, no server involvement at
    all). CitizenFX's own event dispatch for a LOCAL TriggerEvent with zero
    registered handlers for that event name is a well-established,
    documented no-op: the call simply returns, exactly as it does today for
    the dozens of OTHER `TriggerEvent`/`AddEventHandler`-only local events
    already firing throughout this resource (e.g. this very file's sibling
    client/radial.lua's own `qbx_k9unit:client:featureBlocksApplied` local
    re-broadcast) into whatever set of listeners happens to exist. A server
    running a chat replacement that never implements `chat:addSuggestion`
    (or no chat resource at all) sees this file do nothing whatsoever --
    not an error, not a delay, not a console line. Every registration call
    below is therefore unconditional and never wrapped in a
    `type(...) == 'function'` existence guard the way a resource-global
    FUNCTION call would be elsewhere in this codebase -- `TriggerEvent`
    itself is the guard here, by design, not an omission of this file's
    established convention.

    RE-REGISTRATION SAFETY: FiveM's own default `chat` resource resolves a
    repeated `chat:addSuggestion` call for the SAME command name by
    replacing the existing entry, never appending a duplicate row (its
    client script keys its own `suggestions` array by `name` and does a
    find-and-replace-or-push, the same REGISTER/REPLACE-by-id shape
    client/radial.lua's own `lib.registerRadial`/`lib.addRadialItem` calls
    rely on against ox_lib, per that file's own "DUPLICATE-VS-REPLACE"
    header note). This file's own two call sites below (this resource's own
    start, and a same-shaped `chat` resource independently restarting) are
    therefore both safe to fire repeatedly across a long session with no
    accumulating duplicate suggestions, mirroring client/radial.lua's own
    ox_lib-restart dispatcher precedent for the identical reason: a
    restarted `chat` resource reconstructs its own suggestions list empty,
    with nothing else in this resource ever prompting a re-add, unless
    something re-fires the registration -- exactly the bug class that file
    already fixed once for ox_lib.

    NO PERMISSION-AWARENESS, BY DESIGN (this task's own explicit
    instruction): every command below is suggested to every player
    regardless of job/certification/rank. A civilian seeing `/k9certify` in
    their own autocomplete and being refused by the server on use is
    correct and expected -- identical in spirit to html/tablet.js's own
    Commands tab, which documents every command to every viewer regardless
    of whether THEY personally could run it right now. This file adds no
    new authorization logic of any kind, and never could: a suggestion is
    purely a client-side autocomplete hint, and every command it describes
    is already independently gated server-side (or, for the handful of
    purely client-local commands like `/k9sit`, gated by
    CanShowK9UI()/HasK9Access() at the point of actual use, unchanged by
    this file).
]]

-- ----------------------------------------------------------------------
-- NEW LOCALE KEYS NEEDED (locales/en.json is not this file's own to edit --
-- handed to whoever owns it). Three keys, one per dynamic-name command
-- below, none of which has any existing tablet.js COMMAND_REFERENCE entry
-- to reuse (see this file's own header "DESCRIPTIONS" section for why).
-- pendingLocale() immediately below tries the REAL locale() first and only
-- substitutes this placeholder text when that genuinely raises -- the
-- moment these three keys land in locales/en.json for real, this table
-- becomes silently unused with no follow-up edit required here (same
-- established pattern as tests/clientradial_spec.lua's own
-- PENDING_LOCALE_KEYS/pendingLocale for this exact "new key not landed
-- yet" situation).
--
--   commandsuggestions.k9tablet_does   = "Opens the K9 Command Tablet."
--   commandsuggestions.k9hqtablet_does = "Opens the K9 Command Tablet directly to the High Command view."
--   commandsuggestions.k9compat_does   = "Reprints this resource's compatibility detection summary (which framework, inventory, target and other integrations it detected) to your own client console."
-- ----------------------------------------------------------------------
-- COMMAND_CONSOLIDATION_SPEC.md new-canonical-command entries (this pass,
-- coder-backend): 'k9dog' is a genuinely NEW command name (family #2's
-- merged '/k9dog <set|remove> <target> ...') with no existing
-- `tablet.cmdref_k9dog_*` locale key yet -- html/tablet.js is a hot file
-- this pass cannot edit (a UI agent is live in it), so its real
-- COMMAND_REFERENCE/DEFAULT_STRINGS entry (and client/tablet.lua's matching
-- TABLET_STRING_KEYS pair) is reported to project-lead rather than added
-- here. Same "tries the real locale() first, only falls back here while the
-- key hasn't landed yet" contract as the three dynamic-name commands below.
local PENDING_LOCALE_KEYS = {
    ['commandsuggestions.k9tablet_does'] = 'Opens the K9 Command Tablet.',
    ['commandsuggestions.k9hqtablet_does'] = 'Opens the K9 Command Tablet directly to the High Command view.',
    ['commandsuggestions.k9compat_does'] = "Reprints this resource's compatibility detection summary (which framework, inventory, target and other integrations it detected) to your own client console.",
    ['tablet.cmdref_k9dog_does'] = 'Shows or changes whether a character is permanently pinned as a K9. One command for both: /k9setdog and /k9removedog still work too.',
    -- Deliberately just the bare "show status" shape for the chat
    -- suggestion's own parameter hint (ParseUsageParams below only ever
    -- extracts ONE flat parameter list, and this command's other two forms
    -- put a literal 'set'/'remove' word BEFORE the target, which a single
    -- bracket-token usage string cannot represent without misleading
    -- param-order hints) -- the explicit set/remove forms are documented in
    -- full in the `_does` string above and in dogcharacter.usage_dog's own
    -- in-game usage print.
    ['tablet.cmdref_k9dog_usage'] = '/k9dog <target>',
    ['tablet.cmdref_k9fetch_does'] = 'Throws, recalls, or drops the fetch ball -- whichever one makes sense right now. Old names /k9throwfetchball, /k9recallfetchball and /k9dropfetchball still work too.',
    ['tablet.cmdref_k9fetch_usage'] = '/k9fetch',
    ['tablet.cmdref_k9train_does'] = 'Turns Training Mode on or off (whichever it isn\'t right now). Use /k9train search or /k9train bite for a specific drill. Old names /k9training, /k9trainsearch and /k9trainbite still work too.',
    ['tablet.cmdref_k9train_usage'] = '/k9train',
    ['tablet.cmdref_k9kennel_does'] = 'Deploys, enters, or exits your kennel -- whichever one makes sense right now. Old names /k9deploykennel and /k9exitkennel still work too.',
    ['tablet.cmdref_k9kennel_usage'] = '/k9kennel',
}
local function pendingLocale(key, ...)
    local ok, value = pcall(locale, key, ...)
    if ok then return value end
    local pending = PENDING_LOCALE_KEYS[key]
    if pending then return pending end
    error(value, 0) -- a genuinely unrelated missing key -- never silently swallow it
end

--- Extracts every `<required>` / `[optional]` token from a usage string,
--- IN ORDER OF APPEARANCE. See this file's own header "PARAMETER HINTS"
--- section for the disclosed simplifications (a variadic tail is not
--- represented as such; an enumerated-choice token is one literal
--- parameter name). Deliberately does not validate that a `<` token is
--- closed by `>` specifically (rather than `]`) or vice versa -- every
--- input this is ever fed comes from this resource's own locale file, not
--- from anything a player supplies, so a well-formed but "wrong bracket"
--- token pair is not a risk this needs to defend against.
--- @param usage string -- e.g. "/k9decertify <server id> [reason]"
--- @return { name: string, help: string }[] params
local function ParseUsageParams(usage)
    local params = {}
    for opener, token in usage:gmatch('([<%[])([^<>%[%]]+)[%]>]') do
        params[#params + 1] = {
            name = token,
            help = (opener == '[') and 'Optional.' or '',
        }
    end
    return params
end

-- ----------------------------------------------------------------------
-- COMMAND_SUGGESTIONS -- every LITERALLY-NAMED RegisterCommand call
-- (a literal, quoted command name, not a variable) in server/*.lua +
-- client/*.lua, one entry per real command. See
-- this file's own header "DERIVATION" for why this is a hand-maintained
-- table (same disclosed tradeoff as tests/commandreferenceregistry_spec.lua's
-- own SERVER_LUA_FILES/CLIENT_LUA_FILES lists) and
-- tests/commandsuggestions_spec.lua for the drift guard that keeps it
-- honest. `keySuffix` is the exact string this file plugs into
-- `tablet.cmdref_<keySuffix>_does` / `_usage` -- equal to `command` for
-- every entry except the 7 colon-namespaced ones (see this file's own
-- header "DESCRIPTIONS" section).
--
-- Snapshot taken 2026-08-26, matching
-- tests/commandreferenceregistry_spec.lua's own SERVER_LUA_FILES/
-- CLIENT_LUA_FILES snapshot date -- a brand-new command registered after
-- this date must be added here in the SAME change, or
-- tests/commandsuggestions_spec.lua's own drift guard reports it as a real
-- command with no chat suggestion, exactly as intended.
-- ----------------------------------------------------------------------
local COMMAND_SUGGESTIONS = {
    -- client/scenttrail.lua
    { command = 'k9nosehunt', keySuffix = 'k9nosehunt' },
    -- client/pursuitsprint.lua (qbx_k9unit: namespace -- RegisterKeyMapping global-uniqueness requirement)
    { command = 'qbx_k9unit:pursuitsprint', keySuffix = 'pursuitsprint' },
    -- client/kennel.lua -- COMMAND_CONSOLIDATION_SPEC.md #5 (ADDITIVE):
    -- k9deploykennel keeps its own registration forever (RegisterKeyMapping/
    -- radial.lua both call it directly by this literal name -- see that
    -- file's own comment), but is no longer chat-suggested under its own
    -- name now that 'k9kennel' exists as the one thing a player sees --
    -- same HIDDEN_ALIAS_COMMANDS treatment as a folded-away name, even
    -- though this one's registration is NOT going away.
    { command = 'k9kennel', keySuffix = 'k9kennel' },
    -- client/keybinds.lua
    { command = 'k9bitehold', keySuffix = 'k9bitehold' },
    { command = 'k9takedown', keySuffix = 'k9takedown' },
    { command = 'k9track', keySuffix = 'k9track' },
    { command = 'k9dragtoggle', keySuffix = 'k9dragtoggle' },
    { command = 'k9sit', keySuffix = 'k9sit' },
    { command = 'k9bark', keySuffix = 'k9bark' },
    { command = 'k9scentvision', keySuffix = 'k9scentvision' },
    -- k9exitkennel: same ADDITIVE hidden treatment as k9deploykennel above
    -- -- RegisterKeyMapping('k9exitkennel', ..., 'O') in this same file
    -- still needs the real registration to keep the rebinding UI working;
    -- only the chat suggestion is gone.
    -- client/agility.lua (qbx_k9unit: namespace)
    { command = 'qbx_k9unit:vault', keySuffix = 'vault' },
    -- client/training.lua -- COMMAND_CONSOLIDATION_SPEC.md #4:
    -- k9training/k9trainsearch/k9trainbite are now HIDDEN ALIASES of
    -- 'k9train' (still real, working RegisterCommand calls -- see that
    -- file's own comment), never chat-suggested under their own names.
    { command = 'k9train', keySuffix = 'k9train' },
    -- client/vision.lua (qbx_k9unit: namespace)
    { command = 'qbx_k9unit:toggleCameraFeed', keySuffix = 'toggle_camera_feed' },
    { command = 'qbx_k9unit:toggleThermalVision', keySuffix = 'toggle_thermal_vision' },
    { command = 'qbx_k9unit:toggleNightVision', keySuffix = 'toggle_night_vision' },
    -- client/recall.lua
    { command = 'k9recall', keySuffix = 'k9recall' },
    -- client/movement.lua (qbx_k9unit: namespace)
    { command = 'qbx_k9unit:toggleCamera', keySuffix = 'toggle_camera' },
    -- client/sarcalls.lua
    { command = 'k9sarcall', keySuffix = 'k9sarcall' },
    -- client/defense.lua (qbx_k9unit: namespace)
    { command = 'qbx_k9unit:confirmHandlerDownDefense', keySuffix = 'confirm_handler_down_defense' },
    { command = 'qbx_k9unit:dangerWarnAlert', keySuffix = 'danger_warn_alert' },
    -- client/fetch.lua -- COMMAND_CONSOLIDATION_SPEC.md #3:
    -- k9throwfetchball/k9dropfetchball/k9recallfetchball are now HIDDEN
    -- ALIASES of 'k9fetch' (still real, working RegisterCommand calls --
    -- see that file's own comment), never chat-suggested under their own
    -- names.
    { command = 'k9fetch', keySuffix = 'k9fetch' },
    -- client/wellbeing.lua
    { command = 'k9calmdown', keySuffix = 'k9calmdown' },
    { command = 'k9meatbait', keySuffix = 'k9meatbait' },
    { command = 'k9whistle', keySuffix = 'k9whistle' },
    -- client/wellbeing.lua (HungerThirstSystem, this pass, coder-backend)
    { command = 'k9eat', keySuffix = 'k9eat' },
    { command = 'k9drink', keySuffix = 'k9drink' },
    -- client/propattachment.lua
    { command = 'k9propattach', keySuffix = 'k9propattach' },
    -- server/highcommand.lua
    { command = 'k9givexp', keySuffix = 'k9givexp' },
    -- server/certifications.lua -- COMMAND_CONSOLIDATION_SPEC.md §2/§5 item
    -- 8: k9certifyoffline/k9decertifyoffline/k9settieroffline/
    -- k9recertifyoffline/k9unspecializeoffline are now HIDDEN ALIASES (still
    -- real, working RegisterCommand calls -- see that file's own comment),
    -- folded into their online counterparts below (which now resolve
    -- online-vs-offline from args[1]'s own shape: numeric -> online,
    -- non-numeric -> offline). Never chat-suggested under their own names
    -- anymore. See HIDDEN_ALIAS_COMMANDS in tests/commandsuggestions_spec.lua.
    { command = 'k9certify', keySuffix = 'k9certify' },
    { command = 'k9decertify', keySuffix = 'k9decertify' },
    { command = 'k9settier', keySuffix = 'k9settier' },
    { command = 'k9recertify', keySuffix = 'k9recertify' },
    { command = 'k9specialize', keySuffix = 'k9specialize' },
    { command = 'k9unspecialize', keySuffix = 'k9unspecialize' },
    -- server/admin.lua -- COMMAND_CONSOLIDATION_SPEC.md #1: k9auditcert/
    -- k9auditpartner/k9auditsearch/k9auditxp/k9auditdept are now HIDDEN
    -- ALIASES of 'k9audit' (still real, working RegisterCommand calls in
    -- server/admin.lua -- see that file's own comment -- just no longer
    -- chat-suggested). See HIDDEN_ALIAS_COMMANDS in
    -- tests/commandsuggestions_spec.lua for the drift-guard allowlist that
    -- makes removing their entries here intentional, not a silent gap.
    { command = 'k9announce', keySuffix = 'k9announce' },
    { command = 'k9audit', keySuffix = 'k9audit' },
    -- server/dogcharacter.lua -- COMMAND_CONSOLIDATION_SPEC.md #2:
    -- k9setdog/k9removedog are now HIDDEN ALIASES of 'k9dog' (still real,
    -- working RegisterCommand calls in server/dogcharacter.lua -- see that
    -- file's own comment), never chat-suggested under their own names.
    { command = 'k9dog', keySuffix = 'k9dog' },
    -- server/leaderboard.lua
    { command = 'k9stats', keySuffix = 'k9stats' },
    -- server/bonetool.lua
    { command = 'k9bonetool', keySuffix = 'k9bonetool' },
    -- server/permissions.lua -- COMMAND_CONSOLIDATION_SPEC.md §5 item 7:
    -- k9grantpermission/k9revokepermission are now HIDDEN ALIASES of
    -- 'k9permission' (still real, working RegisterCommand calls -- see that
    -- file's own comment), never chat-suggested under their own names.
    { command = 'k9permission', keySuffix = 'k9permission' },
    -- server/scentlineup.lua
    { command = 'k9lineup', keySuffix = 'k9lineup' },
    { command = 'k9lineuppick', keySuffix = 'k9lineuppick' },
    { command = 'k9lineupcancel', keySuffix = 'k9lineupcancel' },
}

--- Registers one `chat:addSuggestion` for a resolved command name, reading
--- its description/usage from the SAME `tablet.cmdref_<keySuffix>_does` /
--- `_usage` locale keys html/tablet.js's own Commands tab already shows --
--- see this file's own header "DESCRIPTIONS" section. `descriptionOverride`
--- is used only by the three dynamic-name commands below, whose keySuffix
--- has no matching tablet.js entry to read a `_does` string from at all.
--- @param command string
--- @param keySuffix string
--- @param descriptionOverride string?
local function RegisterSuggestion(command, keySuffix, descriptionOverride)
    local description = descriptionOverride or pendingLocale('tablet.cmdref_' .. keySuffix .. '_does')
    local usage = descriptionOverride and ('/' .. command) or pendingLocale('tablet.cmdref_' .. keySuffix .. '_usage')
    TriggerEvent('chat:addSuggestion', '/' .. command, description, ParseUsageParams(usage))
end

--- Registers every entry in COMMAND_SUGGESTIONS above, then the three
--- dynamic-name commands (see this file's own header "THREE DYNAMIC-NAME
--- COMMANDS" section), reading their real, LIVE command name straight out
--- of Config the exact same way client/tablet.lua/shared/compat/core.lua
--- themselves decide whether/what to register -- an operator who renames
--- one of these three, or disables it outright, is reflected here with no
--- edit needed to this file.
local function RegisterAllCommandSuggestions()
    for _, entry in ipairs(COMMAND_SUGGESTIONS) do
        RegisterSuggestion(entry.command, entry.keySuffix)
    end

    -- client/tablet.lua's two command entry points. Mirrors that file's own
    -- Config.CommandTablet.openMode resolution (including its own
    -- 'command'/'item'/'both' validity fallback to 'command') so this file
    -- never suggests a command client/tablet.lua itself would not actually
    -- register this session. Config.Features.CommandTablet gates BOTH --
    -- see client/tablet.lua's own `if not Config.Features.CommandTablet
    -- then return end` file-level guard, which this mirrors exactly.
    if Config.Features and Config.Features.CommandTablet == true then
        local cfgTablet = type(Config.CommandTablet) == 'table' and Config.CommandTablet or {}
        local openMode = cfgTablet.openMode
        if openMode ~= 'command' and openMode ~= 'item' and openMode ~= 'both' then
            openMode = 'command'
        end

        if openMode == 'command' or openMode == 'both' then
            local tabletCommand = cfgTablet.command
            if type(tabletCommand) == 'string' and tabletCommand ~= '' then
                RegisterSuggestion(tabletCommand, nil, pendingLocale('commandsuggestions.k9tablet_does'))
            end
        end

        -- Registered UNCONDITIONALLY of `openMode` (matching
        -- client/tablet.lua's own SECOND ENTRY POINT comment: "registered
        -- UNCONDITIONALLY here... this is a wholly separate, always-
        -- available shortcut whenever Config.Features.CommandTablet is on
        -- at all").
        local hqTabletCommand = cfgTablet.highCommandCommand
        if type(hqTabletCommand) == 'string' and hqTabletCommand ~= '' then
            RegisterSuggestion(hqTabletCommand, nil, pendingLocale('commandsuggestions.k9hqtablet_does'))
        end
    end

    -- shared/compat/core.lua's diagnostic command. That file's own
    -- registration is SERVER-ONLY (`if REALM == 'server' then`), which is
    -- irrelevant here: a chat suggestion is purely a client-side
    -- autocomplete hint, and typing a command dispatches to whichever side
    -- actually registered it regardless of which side offered the
    -- suggestion (every server-registered command in COMMAND_SUGGESTIONS
    -- above already works the same way). Mirrors that file's own exact
    -- validity check (`type(cmdName) == 'string' and cmdName ~= ''`,
    -- `false` means "disabled, on purpose") so this never suggests a
    -- command an operator has turned off.
    if type(Config.Compat) == 'table' then
        local diagnosticCommand = Config.Compat.diagnosticCommand
        if type(diagnosticCommand) == 'string' and diagnosticCommand ~= '' then
            RegisterSuggestion(diagnosticCommand, nil, pendingLocale('commandsuggestions.k9compat_does'))
        end
    end
end

-- Fires on EITHER this resource's own start OR a same-shaped `chat`
-- resource's own restart -- see this file's own header "RE-REGISTRATION
-- SAFETY" section for why the second branch matters (the stock `chat`
-- resource's own suggestions list is reconstructed empty by ITS OWN
-- restart, with nothing else in this resource ever prompting a re-add,
-- mirroring client/radial.lua's own ox_lib-restart dispatcher fix for the
-- identical bug class). Harmless on a server running a different chat
-- resource under a different name -- that branch of the condition simply
-- never matches, and this resource's own start still fires the real
-- registration regardless (see this file's own header "SAFE WITH NO CHAT
-- RESOURCE LISTENING" section for why firing into a name nothing is
-- listening for is itself always safe, independent of this dispatcher
-- entirely).
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == 'chat' then
        RegisterAllCommandSuggestions()
    end
end)
