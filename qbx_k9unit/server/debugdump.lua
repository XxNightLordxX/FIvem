--[[
    qbx_k9unit/server/debugdump.lua

    NEW FILE. The `/k9debug` command -- owner's own words: "I want a debug
    mode setup... so that way when I am testing I can give you the
    information for fixes etc," "I also want that debug super
    comprehensive," "I don't want it showing up in the console I want it to
    log in a folder in the script itself," "for if you as Claude turn it on
    will help you drastically in finding and fixing all issues." See
    Config.DebugDump (config.lua) for the settings this file reads, and
    DIAGNOSTIC_CHECKS.md for the full catalogue this file's checks are
    drawn from (cited inline, section by section, below).

    ======================================================================
    SHIPS OFF, DOES NOTHING AT ALL UNLESS Config.DebugDump.enabled IS
    EXACTLY `true` -- see the early `return` right after the clamp-and-warn
    block below. Not a Config.Features entry on purpose; see config.lua's
    own comment on Config.DebugDump for why. Not wired into the runtime
    control tablet, not wired into any permission/tier system of its own --
    "own state only" (a caller can only ever dump THEIR OWN state; see
    RegisterCommand('k9debug', ...) below) is what makes a bespoke
    permission gate unnecessary here, matching this resource's own
    "why some things need a gate and some don't" convention (compare
    server/roster.lua's admin-only surfaces, which DO re-derive High
    Command authority server-side on every call, to this file's, which
    never needs to because it never looks past `source`).

    ======================================================================
    THREE-TIER REPORT SHAPE, PER DUMP FILE (see BuildReport below):
      - findings      -- definitely wrong, high confidence, worst first.
                          Usually short or empty.
      - worthChecking -- suspicious, innocent explanations possible,
                          worded as a question, never a verdict.
      - fullState     -- everything, exhaustively, no judgement. Meant to be
                          searched by a developer/Claude, never read top to
                          bottom.

    ======================================================================
    SECTION A OF DIAGNOSTIC_CHECKS.MD -- RE-SURFACING, NOT REIMPLEMENTING.
    Three of this resource's four existing-but-boot-only diagnostics are
    re-surfaced here by calling their REAL, ALREADY-TESTED accessors --
    never a second copy of their logic:
      - A3 (which database tables are memory-only, and why) --
        K9Store.IsDatabaseEnabled(tableName), a real, already-public
        accessor in server/datastore.lua (K9Store.IsDatabaseEnabled =
        DatabaseEnabled, no `local`). The per-table NAME LIST itself is
        read from server/datastore.lua's own EXPECTED_TABLE_COLUMNS at
        RUN TIME via LoadResourceFile + a narrow, delimited text extraction
        -- the SAME technique tests/fixtures/sandbox.lua's own
        Sandbox.installedSchemaRows() already uses for the identical
        table, and server/selfcheck.lua's own FindUnrecognizedFeatureKeys
        uses the sibling technique for a different table -- specifically so
        this list can never quietly drift out of sync with the real one
        the way a hand-typed second copy could.
      - A4 (dependency version check) -- K9SelfCheck.EvaluateDependencyVersion
        / K9SelfCheck.FormatDependencyWarning, real, already-public
        functions in server/selfcheck.lua (K9SelfCheck = K9SelfCheck or {},
        no `local`). The DEPENDENCIES data table itself (name + minVersion)
        is likewise read from server/selfcheck.lua's own source text at run
        time, same reasoning as A3 above.
      - A1 (Config.Features vs Config.FeatureGroups disagreement) --
        PARTIALLY re-surfaced, not fully: config.lua's own
        ReportFlatGroupedDisagreement and the FEATURE_GROUP_MEMBERS/
        STANDALONE_FEATURE_KEYS mapping it depends on are ALL `local` to
        config.lua, and this file does not own config.lua beyond its own
        Config.DebugDump block (hard rule for this pass), so there is no
        way to call config.lua's real function or read its real
        family-membership mapping from here. What IS real and public:
        Config.Features, Config.FeatureGroups, and
        Config.FeaturesBeforeGrouping (all plain fields on the global
        `Config` table, not `local`). CheckFeatureGroupsDisagreement below
        does the best HONEST job possible with only those three: it can
        always tell you a flat/grouped VALUE disagrees, but it can only
        tell you with FINDING-level confidence that the disagreement is a
        genuine surprise (rather than an expected cascade from a disabled
        Config.FeatureGroups family) when it can first confirm NO family is
        currently disabled at all -- see that function's own comment for
        the exact reasoning. When at least one family IS disabled, every
        mismatch this run is reported at WORTH-CHECKING instead, worded as
        a real, disclosed limitation, never dressed up as more certain than
        it is. Reported to the project as a genuine follow-up: exposing
        config.lua's own comparison as a small, real export (e.g. a
        `Config.LastFeatureGroupDisagreements` list, built the one place
        that already has the real family mapping) would let a future pass
        upgrade this to the full-fidelity FINDING DIAGNOSTIC_CHECKS.md
        describes.
      - A2 (runtime tablet override vs config.lua disagreement) -- also
        PARTIAL. The raw list of currently active overrides
        (K9Store.Override_GetAll(), real and public) is reported in full,
        unconditionally, as FULL STATE -- zero false-positive risk, this is
        just a fact. The "does this disagree with config.lua" comparison
        server/runtimecontrol.lua's own boot-time "HEADS UP" line makes
        uses CONFIG_LUA_DEFAULT_FEATURES/_TUNABLES and TUNABLE_REGISTRY,
        all `local` to that file, captured at ITS OWN load time (which is
        AFTER config.lua's Config.FeatureGroups resolution already ran) --
        a genuinely different, later snapshot than Config.FeaturesBeforeGrouping,
        and not recoverable from outside that file. The best this file can
        do without an export is compare a 'feature' kind override against
        Config.FeaturesBeforeGrouping (the FLAT default, before
        Config.FeatureGroups) and report it at WORTH-CHECKING with that
        exact caveat stated -- see CheckRuntimeOverrides below. 'tuning'
        kind overrides are reported as raw state only; there is no
        accessible baseline to compare them against at all. Flagged as a
        genuine follow-up needed from whoever owns server/runtimecontrol.lua:
        a small read-only export exposing CONFIG_LUA_DEFAULT_FEATURES/
        _TUNABLES (pure data snapshots, no risk in exposing them) would
        close this gap completely.

    Three checks this pass could NOT build at all without an export from a
    file this pass does not own (and, per this task's own shared-tree
    caution, will not edit): F1 (asymmetric leash/partnership pairs --
    LeashPairs is `local` to server/main.lua), F3 (an active Bite/Hold/
    Takedown/Drag past its own hard expiry -- ActiveHolds is `local` to
    server/combat.lua), E1 (a per-dog speed override above the movement
    engine's real ceiling -- DescribeSpeedOverrideCeiling/RefreshOverrideCache
    are `local` to server/k9profiles.lua). Every dump this file writes says
    so explicitly, by name, in fullState.knownGaps below -- so a developer
    (or a future Claude session) reading the dump file itself, not just this
    header, knows exactly what was not checked and why, without having to
    guess.

    ======================================================================
    NEW CHECKS THIS FILE OWNS OUTRIGHT (no export needed, built fresh here):
      - B1 (has the bowl/rest-prop world-model scan ever matched anything)
        -- a ONE-SHOT GetAllObjects()/GetAllVehicles() census scan against
        Config.Wellbeing.Thirst.bowlSources / Config.Wellbeing.Fatigue.
        restSources, run independently by THIS file (server/wellbeing.lua
        is untouched -- this does not read or write anything of that
        file's). Reported at WORTH-CHECKING ONLY, with BOTH disclosed
        caveats DIAGNOSTIC_CHECKS.md §B1 names: (a) this is a single
        snapshot at the moment /k9debug ran, which is much weaker evidence
        than an accumulated "never once matched since boot" record -- run
        it more than once across a real testing session before trusting a
        zero; (b) GetAllObjects()/GetAllVehicles() only see currently
        NETWORKED/spawned entities, never static .ymap map decoration --  a
        correct model name for a prop that is only ever placed as map
        scenery reports zero matches FOREVER, correctly, with the config
        entirely right. Never reported as a FINDING for exactly that
        reason.
      - B2 (do the configured food/water/medkit/distraction item names
        actually exist) -- calls `exports.ox_inventory:Items(name)`
        directly, the exact same real export server/wellbeing.lua's own
        (untouched) WarnIfItemMissing already calls at boot -- re-derived
        independently here, not reimplemented as a copy of that function
        (which is `local` anyway). Same disclosed, ox_inventory-only
        limitation that file's own header already states: other inventory
        backends have no server-side existence check in this resource's
        compat contract today.
      - H1 (the two independent self-grant switches, reported together) --
        a direct, unconditional read of two real Config fields
        (Config.HighCommand.allowSelfGrant, Config.FeatureControl.
        allowHighCommandSelfGrant). Always STATE, never a finding --
        KNOWN_ISSUES.md is explicit that disagreeing values here are a
        valid, intentional configuration.

    ======================================================================
    THE DECISION TRAIL (verbose level only) -- config.lua's own comment on
    Config.DebugDump.level names this exactly: "the decision-log wrapping
    around HasK9Access/IsHighCommand/HasPermission." All three are real,
    resource-global functions (`function HasK9Access(source)` in
    server/certifications.lua, `function IsHighCommand(source)` in
    server/highcommand.lua, `function HasPermission(citizenid,
    permissionKey)` in server/permissions.lua -- none `local`), so this
    file can wrap them from the OUTSIDE, with no edit to any of those three
    files, by reassigning `_G[name]` to a thin pass-through AFTER the real
    function already exists as a global -- which is exactly why this file
    is loaded LAST among this resource's own server_scripts (see
    fxmanifest.lua): every function it might wrap is guaranteed to already
    be the real one, not a stub, at the moment InstallDecisionWrapping runs.
    The wrapper calls the REAL function FIRST, unconditionally, and returns
    its REAL result UNCHANGED -- recording the call (fn name, first
    argument, result) is wrapped in its own pcall so a bug in the recording
    code can NEVER affect the return value every other file in this
    resource depends on for real authorization decisions. This is
    genuinely the highest-blast-radius code in this whole file (these three
    functions are called constantly, by nearly every other server/*.lua
    file) -- it is installed ONLY when Config.DebugDump.level == 'verbose'
    (never at 'normal'), matching that config field's own documented cost
    disclosure exactly, and only once (decisionWrappingInstalled guard).
    The trail itself is a fixed-size ring buffer (DECISION_TRAIL_CAP
    entries, O(1) per insert, never grows) filtered down to the CURRENT
    requester's own citizenid at report time -- "own state only" applies to
    the decision trail too, never showing one player another's checks.

    ======================================================================
    FILE OUTPUT -- VERIFIED, NOT ASSUMED. This resource has already shipped
    one feature built on natives that turned out not to exist as assumed
    (.luacheckrc's own "I ALLOWLISTED A NATIVE THAT DOES NOT EXIST HERE"
    entry, SetResourceKvpString). Before building on it, `SaveResourceFile`
    was independently re-verified this pass the SAME way that file already
    establishes as this project's bar: fetching
    raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/
    SaveResourceFile.md returned HTTP 200, `ns: CFX`, `apiset: server`,
    `BOOL SAVE_RESOURCE_FILE(char* resourceName, char* fileName, char*
    data, int dataLength)`. `LoadResourceFile` was NOT re-verified fresh
    this pass -- server/selfcheck.lua already depends on it unconditionally
    (its own header cites the identical HTTP-200/ns-CFX verification), so
    this file rides that same already-load-bearing assumption rather than
    introducing a new one, exactly server/webhook.lua's own stated
    reasoning for riding ox_lib's json.encode dependency instead of
    re-verifying it.

    One real, disclosed uncertainty SaveResourceFile's own decl page does
    NOT settle: whether it creates an intermediate directory that does not
    yet exist on disk (`fileName` containing a `/`). Community precedent
    for FXServer resources is that it does NOT (the parent folder must
    already exist), so this resource ships a real, git-tracked
    `diagnostics/.gitkeep` placeholder file specifically so that folder
    exists on disk from the moment this resource is deployed, regardless of
    which way that native actually behaves. Every write below is also
    pcall-wrapped and checks the native's own boolean return -- a failed
    write is reported back to the player as a failure (locale
    'debugdump.write_failed'), never silently swallowed.

    WHY EMPTYING, NOT DELETING (Config.DebugDump.maxRetainedDumps): there is
    no native this resource could verify for deleting a resource file
    outright (no DELETE_RESOURCE_FILE-shaped CFX native exists in the
    ext/native-decls index at all). So retention here means: a small,
    bounded manifest (diagnostics/_manifest.json, itself capped at
    maxRetainedDumps entries) tracks every dump file this resource has
    written THIS SESSION, oldest first; once a NEW dump would push the
    manifest over the cap, the OLDEST tracked file is overwritten with a
    short placeholder string (via the exact same SaveResourceFile call,
    same filename) rather than left with real content, and dropped from the
    manifest. Total real, meaningful content on disk is therefore always
    bounded to maxRetainedDumps files' worth, even though the raw file
    COUNT on disk can exceed that over a very long testing history (each
    excess file is a few dozen bytes of placeholder text, not a real dump)
    -- "capped so repeated use cannot fill a disk" is about content volume,
    which this satisfies; it cannot be about file COUNT, because nothing
    this resource can verify can shrink that number once a name has been
    used.

    ======================================================================
    FILENAMES -- timestamped and player-identified so two dumps can be
    compared and ordered: `diagnostics/k9debug_<citizenid>_<YYYYMMDD_HHMMSS>_<seq>.json`.
    citizenid, not server id -- a server id is a per-connection number that
    means nothing across a reconnect; citizenid is this resource's own
    established durable identity everywhere else (every audit log in this
    resource already keys on it). The citizenid component is sanitized to
    `[%w%-_]` ONLY before ever reaching SaveResourceFile's own `fileName`
    argument, with an explicit belt-and-suspenders re-check that the result
    contains no `..`, `/`, or `\` -- SaveResourceFile writes relative to
    this resource's own folder, and a citizenid that somehow contained a
    path-escape sequence must never be allowed to turn into a write outside
    (or, worse, ELSEWHERE INSIDE) this resource's own directory. citizenid
    is server-derived (via exports.qbx_core:GetPlayer(source)), never a raw
    client-supplied string, but this file treats it as untrusted input for
    this one purpose anyway, on the theory that a defense that is free is
    worth having even when the specific attack it stops looks unlikely
    today.

    ======================================================================
    DIFFABILITY -- STABLE KEY ORDER. This file's report is built as a
    strictly valid JSON document, but deliberately NEVER via `json.encode`
    on a plain Lua table with string keys for anything where ORDER matters
    (the whole report, and every nested object in it): CFX's Lua 5.4
    runtime does not document its hash-table iteration order as stable
    ACROSS PROCESS RESTARTS (string-key hashing may be seeded per-process
    for hash-flooding resistance in some Lua 5.4 builds), and this file's
    single most common real use case is "the SAME player, run twice, with a
    restart between the two runs, to see what changed" -- a report whose
    KEY ORDER could silently reshuffle across that exact restart would make
    `diff` between two otherwise-identical dumps noisy for a reason that has
    nothing to do with anything the operator changed. So: EncodeOrderedJson
    below (a small, hand-rolled, deterministic JSON writer) takes explicit,
    ordered {key, value} pairs (JsonObj) and explicit ordered arrays
    (JsonArr) and emits them in EXACTLY that order, every time, by
    construction -- never by relying on any table's own iteration order.
    json.encode (the real, CFX-provided global) is still used, deliberately,
    for the tiny manifest file (diagnostics/_manifest.json) -- that file is
    a flat list of filenames with no key-order question at all, so there is
    nothing for stability to protect there.

    ======================================================================
    FORMAT CHOICE -- JSON BODY, PLAIN ENGLISH AT THE TOP, IN ONE VALID
    JSON DOCUMENT: the top-level object's FIRST key is `readMeFirst` (a
    short prose paragraph naming the finding/worth-checking counts), and
    `findings`/`worthChecking` are plain JSON STRING ARRAYS placed
    immediately after it -- each array element is one already-formatted,
    human-readable sentence, pretty-printed one per line by
    EncodeOrderedJson. A human opening the raw file in any plain text
    editor sees readable English on the first several screens without any
    JSON-aware tool; a script (or Claude) can `json.decode` the ENTIRE file
    with zero special-casing, because it never stops being strictly valid
    JSON. The alternative this pass considered and rejected -- a plain-text
    prose header PREPENDING a separate JSON blob in the same file -- was
    rejected specifically because it would break "parse it reliably" for
    the very first, simplest thing any tool would try: decoding the whole
    file.

    ======================================================================
    NEVER BREAKS WHAT IT OBSERVES: every native call in this file is inside
    a `pcall` or behind a `type(x) == 'function'` guard (usually both); every
    check function degrades to an honest "could not verify" state entry
    rather than throwing; BuildReport itself never calls anything that was
    not already defensively wrapped by the functions it calls. If writing
    the file itself fails, the player is told so via NotifyPlayer -- this
    command never errors out to the console with no explanation.
]]

-- ======================================================================
-- SECTION 0 -- CONFIG CLAMP-AND-WARN, THEN THE ONE EARLY EXIT THIS WHOLE
-- FILE HAS.
-- ======================================================================

if type(Config) ~= 'table' then Config = {} end
if type(Config.DebugDump) ~= 'table' then
    Config.DebugDump = { enabled = false, level = 'normal', maxRetainedDumps = 200, autoOnBoot = false }
end

local function ClampDebugDumpConfig()
    local dd = Config.DebugDump

    if type(dd.enabled) ~= 'boolean' then
        print(('[qbx_k9unit] debugdump: Config.DebugDump.enabled is not a boolean (got %s) -- using false (this whole subsystem ships off by default). Fix Config.DebugDump.enabled in config.lua.'):format(type(dd.enabled)))
        dd.enabled = false
    end

    if dd.level ~= 'normal' and dd.level ~= 'verbose' then
        if dd.level ~= nil then
            print(('[qbx_k9unit] debugdump: Config.DebugDump.level is %q, not "normal" or "verbose" -- using "normal". Fix Config.DebugDump.level in config.lua.'):format(tostring(dd.level)))
        end
        dd.level = 'normal'
    end

    if type(dd.maxRetainedDumps) ~= 'number' or dd.maxRetainedDumps <= 0 then
        print(('[qbx_k9unit] debugdump: Config.DebugDump.maxRetainedDumps is not a positive number (got %s) -- using 200. Fix Config.DebugDump.maxRetainedDumps in config.lua.'):format(tostring(dd.maxRetainedDumps)))
        dd.maxRetainedDumps = 200
    else
        dd.maxRetainedDumps = math.floor(dd.maxRetainedDumps)
    end

    if type(dd.autoOnBoot) ~= 'boolean' then
        dd.autoOnBoot = true
    end
end

ClampDebugDumpConfig()

if Config.DebugDump.enabled ~= true then
    -- Ships off. Nothing below this line ever runs: no command, no
    -- wrapping, no thread, no file I/O. See this file's own header.
    return
end

-- ======================================================================
-- SECTION 1 -- SMALL, SHARED HELPERS
-- ======================================================================

local DUMP_DIR = 'diagnostics'
local MANIFEST_PATH = DUMP_DIR .. '/_manifest.json'

--- Mirrors server/selfcheck.lua's own ReadOwnResourceFile (a `local` there,
--- so not reusable directly). Reads a file from THIS SAME, currently
--- installed copy of this resource -- never a second hand-typed copy of
--- another file's content. Never throws; nil means "could not read",
--- which every caller below already treats as a normal, expected outcome.
--- @param relativePath string
--- @return string?
local function ReadOwnResourceFile(relativePath)
    if type(LoadResourceFile) ~= 'function' or type(GetCurrentResourceName) ~= 'function' then
        return nil
    end
    local ok, content = pcall(LoadResourceFile, GetCurrentResourceName(), relativePath)
    if ok and type(content) == 'string' and content ~= '' then return content end
    return nil
end

--- @param relativePath string
--- @param content string
--- @return boolean
local function SafeSaveResourceFile(relativePath, content)
    if type(SaveResourceFile) ~= 'function' or type(GetCurrentResourceName) ~= 'function' then return false end
    if type(relativePath) ~= 'string' or type(content) ~= 'string' then return false end
    local ok, result = pcall(SaveResourceFile, GetCurrentResourceName(), relativePath, content, #content)
    return ok == true and result == true
end

--- @param v any
--- @return boolean?
local function ClampBoolean(v)
    if v == true or v == false then return v end
    return nil
end

--- @param v any
--- @param min number
--- @param max number
--- @return number?
local function ClampNumber(v, min, max)
    if type(v) ~= 'number' or v ~= v then return nil end -- v ~= v rejects NaN
    if v < min then return min end
    if v > max then return max end
    return math.floor(v)
end

--- Whitelists a raw string down to `[%w%-_]` for safe use as ONE PATH
--- COMPONENT inside a SaveResourceFile fileName -- see this file's own
--- header "FILENAMES" for the full threat model this defends against.
--- @param raw any
--- @param fallback string
--- @return string
local function SanitizeForFilename(raw, fallback)
    if type(raw) ~= 'string' or raw == '' then return fallback end
    local cleaned = raw:gsub('[^%w%-]', '_'):gsub('_+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if cleaned == '' then return fallback end
    -- Belt-and-suspenders: a string built ONLY from [%w_-] cannot contain
    -- '.', '/', or '\\' at all -- but this is checked explicitly anyway
    -- rather than trusted, since a bug in the substitution above feeding a
    -- path-escape straight into SaveResourceFile's own fileName argument
    -- would be a serious bug, not a cosmetic one.
    if cleaned:find('%.%.', 1, true) or cleaned:find('[/\\]') then return fallback end
    return cleaned
end

--- @param source number
--- @return string? citizenid, string? displayName
local function ResolvePlayerIdentity(source)
    local ok, citizenid, displayName = pcall(function()
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player or not Player.PlayerData then return nil, nil end
        local id = Player.PlayerData.citizenid
        local name = nil
        local charinfo = Player.PlayerData.charinfo
        if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
            name = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
        end
        return id, name
    end)
    if not ok then return nil, nil end
    if type(citizenid) ~= 'string' or citizenid == '' then citizenid = nil end
    return citizenid, displayName
end

-- ======================================================================
-- SECTION 2 -- MINIMAL, DETERMINISTIC JSON ENCODER (see this file's own
-- header "DIFFABILITY" for why this exists instead of `json.encode`).
-- ======================================================================

--- @param orderedPairs table[] -- array of {key, value} 2-element arrays, IN THE EXACT ORDER TO EMIT
local function JsonObj(orderedPairs) return { __jsonKind = 'obj', pairs = orderedPairs } end
--- @param items any[] -- plain array, IN THE EXACT ORDER TO EMIT
local function JsonArr(items) return { __jsonKind = 'arr', items = items } end

local JSON_SIMPLE_ESCAPES = {
    ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
    ['\b'] = '\\b', ['\f'] = '\\f',
}

--- @param s string
--- @return string -- WITH surrounding quotes
local function JsonEncodeString(s)
    local escaped = s:gsub('[%c\\"]', function(c)
        return JSON_SIMPLE_ESCAPES[c] or ('\\u%04x'):format(c:byte())
    end)
    return '"' .. escaped .. '"'
end

local JsonEncodeValue -- forward declaration, for the obj/arr branches' own recursive calls

--- @param value any
--- @param depth number
--- @param buffer string[] -- appended to in place
JsonEncodeValue = function(value, depth, buffer)
    if value == nil then
        buffer[#buffer + 1] = 'null'
        return
    end

    local t = type(value)
    if t == 'string' then
        buffer[#buffer + 1] = JsonEncodeString(value)
    elseif t == 'boolean' then
        buffer[#buffer + 1] = value and 'true' or 'false'
    elseif t == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then
            buffer[#buffer + 1] = 'null' -- NaN/inf have no JSON representation; never emit invalid JSON over one bad number
        else
            buffer[#buffer + 1] = tostring(value)
        end
    elseif t == 'table' and value.__jsonKind == 'obj' then
        local indent, childIndent = ('  '):rep(depth), ('  '):rep(depth + 1)
        if #value.pairs == 0 then
            buffer[#buffer + 1] = '{}'
        else
            buffer[#buffer + 1] = '{\n'
            for i, kv in ipairs(value.pairs) do
                buffer[#buffer + 1] = childIndent
                buffer[#buffer + 1] = JsonEncodeString(tostring(kv[1]))
                buffer[#buffer + 1] = ': '
                JsonEncodeValue(kv[2], depth + 1, buffer)
                buffer[#buffer + 1] = (i < #value.pairs) and ',\n' or '\n'
            end
            buffer[#buffer + 1] = indent .. '}'
        end
    elseif t == 'table' and value.__jsonKind == 'arr' then
        local indent, childIndent = ('  '):rep(depth), ('  '):rep(depth + 1)
        if #value.items == 0 then
            buffer[#buffer + 1] = '[]'
        else
            buffer[#buffer + 1] = '[\n'
            for i, item in ipairs(value.items) do
                buffer[#buffer + 1] = childIndent
                JsonEncodeValue(item, depth + 1, buffer)
                buffer[#buffer + 1] = (i < #value.items) and ',\n' or '\n'
            end
            buffer[#buffer + 1] = indent .. ']'
        end
    else
        -- Should never happen -- every call site in this file only ever
        -- hands this strings/numbers/booleans/JsonObj/JsonArr/nil. Falls
        -- back to a harmless placeholder string rather than throwing, per
        -- this file's own "must never break what it observes" rule.
        buffer[#buffer + 1] = JsonEncodeString('(unencodable value of type ' .. t .. ')')
    end
end

--- @param root table -- a JsonObj(...) or JsonArr(...)
--- @return string?
local function EncodeOrderedJson(root)
    local buffer = {}
    local ok = pcall(JsonEncodeValue, root, 0, buffer)
    if not ok then return nil end
    return table.concat(buffer)
end

-- ======================================================================
-- SECTION 3 -- MANIFEST / RETENTION (see this file's own header "WHY
-- EMPTYING, NOT DELETING").
-- ======================================================================

local EMPTIED_PLACEHOLDER = '{"readMeFirst":"This dump was emptied to keep this resource under Config.DebugDump.maxRetainedDumps. There is no verified CFX native for deleting a resource file outright, so old dumps are emptied instead of deleted -- see server/debugdump.lua\'s own header, WHY EMPTYING NOT DELETING. Its real content is gone."}'

--- @return string[] -- filenames, oldest first; empty on any read/parse failure
local function LoadManifest()
    local content = ReadOwnResourceFile(MANIFEST_PATH)
    if not content then return {} end
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then return {} end
    local ok, decoded = pcall(json.decode, content)
    if not ok or type(decoded) ~= 'table' then return {} end
    local out = {}
    for _, entry in ipairs(decoded) do
        if type(entry) == 'string' and entry ~= '' then out[#out + 1] = entry end
    end
    return out
end

--- @param list string[]
--- @return boolean
local function SaveManifest(list)
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then return false end
    local ok, encoded = pcall(json.encode, list)
    if not ok or type(encoded) ~= 'string' then return false end
    return SafeSaveResourceFile(MANIFEST_PATH, encoded)
end

--- Mutates `manifest` in place: empties (never deletes) the oldest entries
--- until at most `cap` remain, dropping each emptied entry from the list.
--- @param manifest string[]
--- @param cap number
local function EnforceRetention(manifest, cap)
    while #manifest > cap do
        local oldest = table.remove(manifest, 1)
        if type(oldest) == 'string' then
            SafeSaveResourceFile(oldest, EMPTIED_PLACEHOLDER)
        end
    end
end

local dumpSeq = 0

--- @param citizenid string?
--- @param jsonContent string
--- @return string? filename, string? errorReason
local function WriteDumpFile(citizenid, jsonContent)
    dumpSeq = dumpSeq + 1
    local safeId = SanitizeForFilename(citizenid, 'unknown')
    local stamp = os.date('%Y%m%d_%H%M%S')
    local filename = ('%s/k9debug_%s_%s_%03d.json'):format(DUMP_DIR, safeId, stamp, dumpSeq % 1000)

    local cap = Config.DebugDump.maxRetainedDumps
    local manifest = LoadManifest()
    EnforceRetention(manifest, math.max(0, cap - 1)) -- make room for the one about to be added

    local wrote = SafeSaveResourceFile(filename, jsonContent)
    if not wrote then
        return nil, 'write_failed'
    end

    manifest[#manifest + 1] = filename
    SaveManifest(manifest) -- best-effort: a manifest write failure only affects FUTURE retention bookkeeping, never this dump's own success

    return filename, nil
end

-- ======================================================================
-- SECTION 4 -- RE-SURFACED / NEW CHECKS. See this file's own header for
-- which of these are full re-surfacings, which are partial (with the exact
-- accessible-data reasoning), and which are new. Every function below
-- degrades to an honest "could not verify" line rather than throwing.
-- ======================================================================

--- A1 -- see this file's own header for the full "why WORTH-CHECKING, not
--- FINDING, whenever a family is disabled" reasoning.
--- @return { findings: string[], worthChecking: string[] }
local function CheckFeatureGroupsDisagreement()
    local out = { findings = {}, worthChecking = {} }
    if type(Config.Features) ~= 'table' or type(Config.FeaturesBeforeGrouping) ~= 'table' then
        return out -- classic flat config.lua, or ResolveFeatureGroups never ran -- nothing to compare, nothing wrong
    end

    local anyFamilyDisabled = false
    if type(Config.FeatureGroups) == 'table' then
        for _, value in pairs(Config.FeatureGroups) do
            if type(value) == 'table' and value.enabled == false then
                anyFamilyDisabled = true
                break
            end
        end
    end

    local mismatchKeys = {}
    for key, flatValue in pairs(Config.FeaturesBeforeGrouping) do
        local current = Config.Features[key]
        if current ~= nil and current ~= flatValue then
            mismatchKeys[#mismatchKeys + 1] = key
        end
    end
    table.sort(mismatchKeys)

    for _, key in ipairs(mismatchKeys) do
        local flatValue, currentValue = Config.FeaturesBeforeGrouping[key], Config.Features[key]
        if anyFamilyDisabled then
            out.worthChecking[#out.worthChecking + 1] = ('Config.Features.%s was authored as %s but is currently in effect as %s. This MAY be an intentional cascade from a Config.FeatureGroups family that is currently disabled (at least one family in your config has enabled = false right now), or it may be a quiet, unintended override -- search config.lua for "%s" and check which Config.FeatureGroups family it belongs to and whether that family is the one you meant to turn off.'):format(key, tostring(flatValue), tostring(currentValue), key)
        else
            out.findings[#out.findings + 1] = ('Config.Features.%s was authored as %s but is currently in effect as %s, and no Config.FeatureGroups family is disabled right now -- so this is not an intentional cascade, Config.FeatureGroups is quietly overriding this flat switch on its own. Search config.lua for "%s" to find both settings and make them agree.'):format(key, tostring(flatValue), tostring(currentValue), key)
        end
    end
    return out
end

--- A2 (partial -- see this file's own header). @return string[] state, string[] worthChecking
local function CheckRuntimeOverrides()
    local state, worthChecking = {}, {}
    if type(K9Store) ~= 'table' or type(K9Store.Override_GetAll) ~= 'function' then
        state[#state + 1] = 'K9Store.Override_GetAll is not available -- cannot list runtime tablet overrides this run.'
        return state, worthChecking
    end

    local ok, rows = pcall(K9Store.Override_GetAll)
    if not ok or type(rows) ~= 'table' then
        state[#state + 1] = 'K9Store.Override_GetAll failed or returned something unexpected -- cannot list runtime tablet overrides this run.'
        return state, worthChecking
    end

    table.sort(rows, function(a, b) return tostring(a.override_key) < tostring(b.override_key) end)

    if #rows == 0 then
        state[#state + 1] = 'No runtime tablet overrides are currently active for any Config.Features flag or tunable.'
    end

    for _, row in ipairs(rows) do
        state[#state + 1] = ('override_key=%s kind=%s value=%s updated_by=%s updated_at=%s'):format(
            tostring(row.override_key), tostring(row.kind), tostring(row.value), tostring(row.updated_by), tostring(row.updated_at))

        if row.kind == 'feature' and type(row.override_key) == 'string' and type(Config.FeaturesBeforeGrouping) == 'table' then
            local name = row.override_key:match('^feature:(.+)$')
            local fileFlat = name and Config.FeaturesBeforeGrouping[name]
            if fileFlat ~= nil then
                local storedValue = (row.value == 'true')
                if fileFlat ~= storedValue then
                    worthChecking[#worthChecking + 1] = ('A tablet override for Config.Features.%s is currently stored as %s, while config.lua\'s own FLAT switch says %s. This comparison is against the flat switch ONLY (before any Config.FeatureGroups resolution) -- if Config.FeatureGroups also touches this key, this may not reflect the fully-resolved picture. The authoritative comparison is server/runtimecontrol.lua\'s own "HEADS UP" console line at boot -- check the server console history from the last restart for it.'):format(name, tostring(storedValue), tostring(fileFlat))
                end
            end
        end
    end
    return state, worthChecking
end

--- PERFORMANCE FIX (load audit, this pass): server/datastore.lua (~238KB)
--- cannot change while this resource is running, so its
--- EXPECTED_TABLE_COLUMNS extraction below is invariant for the lifetime of
--- the process -- re-reading and re-parsing the whole file on every single
--- /k9debug run (CheckDatabaseSchemaState calls ExtractDatastoreTableNames
--- unconditionally, every BuildReport) was pure waste past the first call.
--- Memoized here, module-level, nil-checked -- a SUCCESSFUL extraction is
--- cached forever; a FAILED one (nil -- unreadable file, anchors not found,
--- zero names parsed) is deliberately NEVER cached, so one transient read
--- failure (e.g. a hypothetical future sandboxed/restricted environment, or
--- a fixture in this file's own spec) can never poison every later run for
--- the remainder of this resource's uptime. See ExtractSelfcheckDependencies
--- below for the identical pattern applied to the sibling extraction.
local datastoreTableNamesCache = nil

--- A3 -- reads server/datastore.lua's own EXPECTED_TABLE_COLUMNS table
--- NAMES straight out of its source text, so this list can never drift out
--- of sync with the real one (see this file's own header). Deliberately
--- narrow: it only ever locates ONE specific, named, delimited block via
--- exact anchor strings and extracts `identifier =` lines from inside it --
--- never a generic sweep of the file's text.
--- @return string[]?
local function ExtractDatastoreTableNames()
    if datastoreTableNamesCache ~= nil then return datastoreTableNamesCache end

    local src = ReadOwnResourceFile('server/datastore.lua')
    if not src then return nil end
    local startPos = src:find('local EXPECTED_TABLE_COLUMNS = {', 1, true)
    if not startPos then return nil end
    local endPos = src:find('\n}', startPos, true)
    if not endPos then return nil end
    local block = src:sub(startPos, endPos)
    local names = {}
    for name in block:gmatch('\n%s*(k9_[%w_]+)%s*=%s*{') do
        names[#names + 1] = name
    end
    if #names == 0 then return nil end
    datastoreTableNamesCache = names -- only a SUCCESSFUL parse is ever cached -- see this cache's own declaration comment above
    return names
end

-- Short, hand-written descriptions for the handful of tables an owner is
-- most likely to actually notice missing (matches DIAGNOSTIC_CHECKS.md
-- §A3's own priority list) -- written fresh for this file, NOT copied from
-- server/datastore.lua's own MISSING_TABLE_FEATURE_DESCRIPTIONS (a `local`
-- this file has no access to and does not own). Any table not in this map
-- is still reported, just by its bare name -- see CheckDatabaseSchemaState.
local NOTABLE_TABLE_DESCRIPTIONS = {
    k9_wellbeing = 'K9 fatigue/mood/fear-stress/injury/hunger/thirst',
    k9_dog_characters = 'admin-pinned "this citizenid is permanently a dog" records (/k9setdog)',
    k9_personnel = 'the K9/Handler roster assignments and callsigns',
    k9_individual_overrides = 'per-officer speed/scent/cooldown overrides',
    k9_certifications = 'certifications (who is certified, and at what tier)',
    k9_partnerships = 'K9/handler partnerships',
    k9_progression = 'XP and handler XP',
    k9_permissions = 'individual permission grants and per-person feature blocks',
}

--- @return string[] findings, string[] state
local function CheckDatabaseSchemaState()
    local findings, state = {}, {}
    if type(K9Store) ~= 'table' or type(K9Store.IsDatabaseEnabled) ~= 'function' then
        state[#state + 1] = 'K9Store is not available -- cannot check database schema state this run.'
        return findings, state
    end

    if type(K9Store.WaitForSchemaCheckToSettle) == 'function' then
        pcall(K9Store.WaitForSchemaCheckToSettle)
    end

    local wholeOk, wholeEnabled = pcall(K9Store.IsDatabaseEnabled)
    if wholeOk and wholeEnabled == false then
        findings[#findings + 1] = 'The ENTIRE resource is running memory-only this session -- either Config.Database.enabled is false, the database is unreachable, or server/datastore.lua found a whole-resource schema collision at boot. Nothing saved to ANY table will survive a restart. Check the server console from this boot for server/datastore.lua\'s own "SCHEMA COLLISION" warning.'
    end

    local names = ExtractDatastoreTableNames()
    if not names then
        state[#state + 1] = 'Could not automatically read the list of tables this resource expects from server/datastore.lua -- skipping the per-table breakdown. This never blocks anything else in this dump.'
        return findings, state
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local ok, enabled = pcall(K9Store.IsDatabaseEnabled, name)
        local description = NOTABLE_TABLE_DESCRIPTIONS[name]
        if ok and enabled == false then
            local line = description
                and ('Table `%s` (%s) is memory-only this session -- it either does not exist yet (run your migrations) or its columns do not match what this resource expects (a name collision with a different resource\'s table). Data in it will NOT survive a restart.'):format(name, description)
                or ('Table `%s` is memory-only this session (missing, or a schema collision).'):format(name)
            if description then
                findings[#findings + 1] = line
            else
                state[#state + 1] = line
            end
        elseif ok then
            state[#state + 1] = ('Table `%s`: OK (database-backed).'):format(name)
        else
            state[#state + 1] = ('Table `%s`: could not verify (K9Store.IsDatabaseEnabled threw).'):format(name)
        end
    end
    return findings, state
end

--- PERFORMANCE FIX (load audit, this pass) -- same reasoning/technique as
--- datastoreTableNamesCache above, applied to this sibling extraction:
--- server/selfcheck.lua (~45KB) cannot change while this resource is
--- running, so a successful DEPENDENCIES extraction is memoized forever; a
--- failed one is never cached, for the identical "one transient failure
--- must not poison every later run" reason given above.
local selfcheckDependenciesCache = nil

--- A4 -- reads server/selfcheck.lua's own DEPENDENCIES table straight out
--- of its source text, same reasoning/technique as ExtractDatastoreTableNames
--- above.
--- @return { name: string, minVersion: string }[]?
local function ExtractSelfcheckDependencies()
    if selfcheckDependenciesCache ~= nil then return selfcheckDependenciesCache end

    local src = ReadOwnResourceFile('server/selfcheck.lua')
    if not src then return nil end
    local startPos = src:find('local DEPENDENCIES = {', 1, true)
    if not startPos then return nil end
    local endPos = src:find('\n}', startPos, true)
    if not endPos then return nil end
    local block = src:sub(startPos, endPos)
    local deps = {}
    for name, minVersion in block:gmatch("name%s*=%s*'([%w_%.%-]+)'%s*,%s*minVersion%s*=%s*'([%d%.]+)'") do
        deps[#deps + 1] = { name = name, minVersion = minVersion }
    end
    if #deps == 0 then return nil end
    selfcheckDependenciesCache = deps -- only a SUCCESSFUL parse is ever cached -- see this cache's own declaration comment above
    return deps
end

--- @return string[]
local function CheckDependencyVersions()
    local state = {}
    if type(K9SelfCheck) ~= 'table' or type(K9SelfCheck.EvaluateDependencyVersion) ~= 'function' or type(K9SelfCheck.FormatDependencyWarning) ~= 'function' then
        state[#state + 1] = 'K9SelfCheck is not available -- cannot re-check dependency versions this run.'
        return state
    end
    if type(GetResourceState) ~= 'function' or type(GetResourceMetadata) ~= 'function' then
        state[#state + 1] = 'GetResourceState/GetResourceMetadata are not available in this environment -- cannot re-check dependency versions this run.'
        return state
    end

    local deps = ExtractSelfcheckDependencies()
    if not deps then
        state[#state + 1] = 'Could not automatically read the dependency list from server/selfcheck.lua -- skipping this check.'
        return state
    end

    for _, dep in ipairs(deps) do
        local okState, resourceState = pcall(GetResourceState, dep.name)
        resourceState = (okState and type(resourceState) == 'string') and resourceState or 'unknown'
        local version = nil
        if resourceState == 'started' then
            local okVer, v = pcall(GetResourceMetadata, dep.name, 'version', 0)
            if okVer and type(v) == 'string' and v ~= '' then version = v end
        end
        local verdict = K9SelfCheck.EvaluateDependencyVersion(resourceState, version, dep.minVersion)
        local line = K9SelfCheck.FormatDependencyWarning(dep, verdict)
        state[#state + 1] = line or ('%s: ok (%s, minimum checked-compatible version %s)'):format(dep.name, version or resourceState, dep.minVersion)
    end
    return state
end

--- B1 -- one-shot world-model census. NEVER a finding -- see this file's
--- own header for both disclosed caveats. Returns nil, nil for both if the
--- relevant feature(s) are off (nothing to scan) or the required natives
--- are unavailable.
--- @return number? matches, number? modelCount
local function ScanForConfiguredWorldModels(modelNames)
    if type(modelNames) ~= 'table' or #modelNames == 0 then return nil, nil end
    if type(GetAllObjects) ~= 'function' or type(GetAllVehicles) ~= 'function'
        or type(GetEntityModel) ~= 'function' or type(GetHashKey) ~= 'function' then
        return nil, nil
    end

    local hashSet, hashCount = {}, 0
    for _, name in ipairs(modelNames) do
        if type(name) == 'string' and name ~= '' then
            local ok, hash = pcall(GetHashKey, name)
            if ok and hash then
                if not hashSet[hash] then hashCount = hashCount + 1 end
                hashSet[hash] = true
            end
        end
    end
    if hashCount == 0 then return nil, nil end

    local matches = 0
    local okObj, objs = pcall(GetAllObjects)
    if okObj and type(objs) == 'table' then
        for _, obj in ipairs(objs) do
            local okm, model = pcall(GetEntityModel, obj)
            if okm and hashSet[model] then matches = matches + 1 end
        end
    end
    local okVeh, vehs = pcall(GetAllVehicles)
    if okVeh and type(vehs) == 'table' then
        for _, veh in ipairs(vehs) do
            local okm, model = pcall(GetEntityModel, veh)
            if okm and hashSet[model] then matches = matches + 1 end
        end
    end
    return matches, hashCount
end

--- @return string[] worthChecking
local function CheckWorldPropScans()
    local out = {}
    if type(Config.Features) ~= 'table' or type(Config.Wellbeing) ~= 'table' then return out end

    if Config.Features.FatigueSystem == true and type(Config.Wellbeing.Fatigue) == 'table' then
        local matches, modelCount = ScanForConfiguredWorldModels(Config.Wellbeing.Fatigue.restSources)
        if matches ~= nil then
            out[#out + 1] = ('Config.Wellbeing.Fatigue.restSources (%d configured model name(s)): %d currently-spawned/networked object or vehicle entity match(es) found in THIS ONE SCAN, just now. A single scan finding zero proves very little -- run /k9debug again at different points in a real testing session before treating a repeated zero as meaningful. Even a sustained zero is not proof the model name is wrong: GetAllObjects()/GetAllVehicles() only see currently networked/spawned entities, never static .ymap map decoration -- a correct model name for a prop placed only as map scenery will report zero matches forever, correctly.'):format(modelCount, matches)
        end
    end

    if Config.Features.HungerThirstSystem == true and type(Config.Wellbeing.Thirst) == 'table' then
        local matches, modelCount = ScanForConfiguredWorldModels(Config.Wellbeing.Thirst.bowlSources)
        if matches ~= nil then
            out[#out + 1] = ('Config.Wellbeing.Thirst.bowlSources (%d configured model name(s)): %d currently-spawned/networked object or vehicle entity match(es) found in THIS ONE SCAN, just now. Same caveats as the Fatigue.restSources line above -- a single scan, and static map scenery is invisible to this scan either way.'):format(modelCount, matches)
        end
    end

    return out
end

--- B2. @return string -- 'ok' | 'missing' | 'invalid_name' | 'not_running' | 'unverifiable'
local function CheckOxInventoryItemExists(itemName)
    if type(itemName) ~= 'string' or itemName == '' then return 'invalid_name' end
    if type(GetResourceState) == 'function' then
        local ok, state = pcall(GetResourceState, 'ox_inventory')
        if ok and state ~= 'started' then return 'not_running' end
    end
    local ok, item = pcall(function() return exports.ox_inventory:Items(itemName) end)
    if not ok then return 'unverifiable' end
    if not item then return 'missing' end
    return 'ok'
end

--- @return string[] findings
local function CheckItemExistence()
    local findings = {}
    if type(Config.Features) ~= 'table' then return findings end

    --- @param itemName any
    --- @param configPath string
    --- @param featureFlagName string
    local function CheckOne(itemName, configPath, featureFlagName)
        local status = CheckOxInventoryItemExists(itemName)
        if status == 'missing' then
            findings[#findings + 1] = ('%s is enabled and %s is set to %q, but that item does not exist in your ox_inventory item registry. Every attempt to use this feature will silently fail as a generic "you do not have that item" error. Add %q to ox_inventory\'s data/items.lua, or point %s at a real item name.'):format(featureFlagName, configPath, itemName, itemName, configPath)
        elseif status == 'invalid_name' then
            findings[#findings + 1] = ('%s is enabled but %s is not a valid, non-empty item name (found: %s) -- cannot verify it against ox_inventory at all.'):format(featureFlagName, configPath, tostring(itemName))
        end
        -- 'ok' / 'not_running' / 'unverifiable' -- all reported nowhere:
        -- 'ok' has nothing worth saying, and 'not_running'/'unverifiable'
        -- are a limitation of THIS check, not evidence of a real problem
        -- (see this file's own header -- other inventory backends have no
        -- server-side existence check in this resource's compat contract).
    end

    if Config.Features.K9Medkit == true and type(Config.K9Medkit) == 'table' then
        CheckOne(Config.K9Medkit.itemName, 'Config.K9Medkit.itemName', 'Config.Features.K9Medkit')
    end
    if Config.Features.MoodSystem == true and type(Config.Wellbeing) == 'table' and type(Config.Wellbeing.Mood) == 'table' then
        CheckOne(Config.Wellbeing.Mood.feedItemName, 'Config.Wellbeing.Mood.feedItemName', 'Config.Features.MoodSystem')
    end
    if Config.Features.DistractionSystem == true and type(Config.Wellbeing) == 'table' and type(Config.Wellbeing.Distraction) == 'table' then
        CheckOne(Config.Wellbeing.Distraction.meatBaitItemName, 'Config.Wellbeing.Distraction.meatBaitItemName', 'Config.Features.DistractionSystem')
        CheckOne(Config.Wellbeing.Distraction.whistleItemName, 'Config.Wellbeing.Distraction.whistleItemName', 'Config.Features.DistractionSystem')
    end
    if Config.Features.HungerThirstSystem == true and type(Config.Wellbeing) == 'table' then
        local hungerCfg = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger or {}
        local thirstCfg = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst or {}
        CheckOne(hungerCfg.feedItemName, 'Config.Wellbeing.Hunger.feedItemName', 'Config.Features.HungerThirstSystem')
        CheckOne(thirstCfg.drinkItemName, 'Config.Wellbeing.Thirst.drinkItemName', 'Config.Features.HungerThirstSystem')
    end

    return findings
end

--- H1. @return string[]
local function CheckSelfGrantSwitches()
    local a = type(Config.HighCommand) == 'table' and Config.HighCommand.allowSelfGrant
    local b = type(Config.FeatureControl) == 'table' and Config.FeatureControl.allowHighCommandSelfGrant
    return {
        ('Config.HighCommand.allowSelfGrant = %s -- controls whether a rank-based High Command officer can grant themselves an explicit k9_permissions row (a certification, specialization, or admin capability) through the normal grant commands.'):format(tostring(a)),
        ('Config.FeatureControl.allowHighCommandSelfGrant = %s -- a SEPARATE switch controlling High Command\'s own rank-based bypass acting on themselves. Both default true; disagreeing values are a valid, intentional configuration, not a bug -- see KNOWN_ISSUES.md.'):format(tostring(b)),
    }
end

--- Known, disclosed gaps -- checks this file could not build with full
--- fidelity because the data they need is `local` to a file this pass does
--- not own. See this file's own header for the full reasoning on each.
local KNOWN_GAPS = {
    'F1 (asymmetric leash/partnership pairs) is NOT checked -- LeashPairs is `local` to server/main.lua with no export. Would need a small read-only accessor added there.',
    'F3 (an active Bite/Hold/Takedown/Drag past its own hard expiry) is NOT checked -- ActiveHolds is `local` to server/combat.lua with no export.',
    'E1 (a per-dog speed override above the movement engine\'s real ceiling) is NOT checked -- DescribeSpeedOverrideCeiling/RefreshOverrideCache are `local` to server/k9profiles.lua with no export.',
    'A2\'s tuning-kind overrides (numeric tunables set from the tablet) are listed above as raw state but NOT compared against config.lua -- TUNABLE_REGISTRY and config.lua\'s own tunable defaults are `local` to server/runtimecontrol.lua with no export.',
}

-- ======================================================================
-- SECTION 5 -- THE DECISION TRAIL (verbose level only). See this file's
-- own header for the full design/risk writeup.
-- ======================================================================

local DECISION_TRAIL_CAP = 300
local DecisionTrail = {}
local decisionTrailWriteIndex = 0
local decisionTrailFilled = 0
local decisionTrailSeq = 0
local decisionWrappingInstalled = false

--- @param fnName string
--- @param resultValue any
--- @param arg1 any -- kept RAW (not stringified) so report-time filtering can match a citizenid or resolve a source
--- @param argsDisplay string
local function RecordDecision(fnName, resultValue, arg1, argsDisplay)
    decisionTrailSeq = decisionTrailSeq + 1
    decisionTrailWriteIndex = (decisionTrailWriteIndex % DECISION_TRAIL_CAP) + 1
    DecisionTrail[decisionTrailWriteIndex] = {
        seq = decisionTrailSeq,
        fn = fnName,
        arg1 = arg1,
        argsDisplay = argsDisplay,
        result = resultValue,
        at = (type(GetGameTimer) == 'function') and GetGameTimer() or 0,
    }
    if decisionTrailFilled < DECISION_TRAIL_CAP then decisionTrailFilled = decisionTrailFilled + 1 end
end

local function InstallDecisionWrapping()
    if decisionWrappingInstalled then return end
    decisionWrappingInstalled = true

    local function WrapGlobal(name)
        local original = _G[name]
        if type(original) ~= 'function' then
            print(('[qbx_k9unit] debugdump: %s is not currently a global function -- the verbose decision trail will not include it this session.'):format(name))
            return
        end
        _G[name] = function(...)
            -- THE REAL CALL, FIRST, UNCONDITIONALLY, UNTOUCHED. Everything
            -- below this line is recording only and is itself pcall-guarded
            -- so a bug in recording can NEVER change what this returns.
            local result = original(...)
            local n = select('#', ...)
            local arg1 = (...)
            local parts = { ... }
            for i = 1, n do parts[i] = tostring(parts[i]) end
            pcall(RecordDecision, name, result, arg1, table.concat(parts, ', ', 1, n))
            return result
        end
    end

    WrapGlobal('HasK9Access')
    WrapGlobal('IsHighCommand')
    WrapGlobal('HasPermission')
end

if Config.DebugDump.level == 'verbose' then
    InstallDecisionWrapping()
end

--- @param entry table -- one DecisionTrail slot
--- @param citizenid string
--- @return boolean
local function DecisionEntryBelongsTo(entry, citizenid)
    if entry.fn == 'HasPermission' then
        return entry.arg1 == citizenid
    end
    -- HasK9Access/IsHighCommand: arg1 is a source number at capture time.
    -- Resolved FRESH here (best-effort -- the player may have reconnected
    -- with a different source since this entry was recorded, in which case
    -- this entry simply will not match anymore, which is the safe failure
    -- direction for "own state only").
    if type(entry.arg1) == 'number' then
        local ok, resolvedId = pcall(function()
            local Player = exports.qbx_core:GetPlayer(entry.arg1)
            return Player and Player.PlayerData and Player.PlayerData.citizenid
        end)
        return ok and resolvedId == citizenid
    end
    return false
end

--- @param citizenid string
--- @return string[]? lines, string? unavailableReason
local function BuildDecisionTrailLines(citizenid)
    if not decisionWrappingInstalled then
        return nil, 'Verbose decision-trail wrapping was never installed this session (Config.DebugDump.level was not "verbose" when this resource started).'
    end

    local entries = {}
    for i = 1, decisionTrailFilled do
        local entry = DecisionTrail[i]
        if entry and DecisionEntryBelongsTo(entry, citizenid) then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b) return a.seq < b.seq end)

    if #entries == 0 then
        return {}, ('No recorded HasK9Access/IsHighCommand/HasPermission calls for citizenid %s yet this session (this trail holds only the most recent %d calls RESOURCE-WIDE -- yours may have scrolled out of it, or you simply have not triggered one of these checks yet).'):format(citizenid, DECISION_TRAIL_CAP)
    end

    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = ('#%d t=%sms %s(%s) -> %s'):format(entry.seq, tostring(entry.at), entry.fn, entry.argsDisplay, tostring(entry.result))
    end
    return lines, nil
end

-- ======================================================================
-- SECTION 6 -- CLIENT SELF-REPORT (client/debugdump.lua's own heartbeat).
-- Own-state-only, never accumulating, never trusted for anything but
-- display -- see this file's own header and client/debugdump.lua's.
-- ======================================================================

local ClientSelfReports = {} -- source -> { receivedAtServerMs = number, data = table }
local HeartbeatCooldown = NewCooldown(2000)
HeartbeatCooldown.RegisterPlayerDropped()

RegisterNetEvent('qbx_k9unit:server:debugDumpClientHeartbeat')
AddEventHandler('qbx_k9unit:server:debugDumpClientHeartbeat', function(payload)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not HeartbeatCooldown.Consume(src) then return end -- a modified client spamming this event beyond a sane rate is simply ignored, never processed
    if type(payload) ~= 'table' then return end

    -- Every field is independently type/range-clamped -- this payload comes
    -- from the calling player's own client, which this file treats as
    -- adversarial input like any other inbound net event, even though the
    -- worst case here is only a misleading line in that SAME player's own
    -- diagnostic dump (never money/items/permissions -- nothing here is
    -- ever used for an authorization decision).
    ClientSelfReports[src] = {
        receivedAtServerMs = (type(GetGameTimer) == 'function') and GetGameTimer() or 0,
        data = {
            modelHash = ClampNumber(payload.modelHash, 0, 4294967295),
            pedHealth = ClampNumber(payload.pedHealth, 0, 2000),
            pedMaxHealth = ClampNumber(payload.pedMaxHealth, 0, 2000),
            isDead = ClampBoolean(payload.isDead),
            isRagdoll = ClampBoolean(payload.isRagdoll),
            inVehicle = ClampBoolean(payload.inVehicle),
            vehicleModelHash = ClampNumber(payload.vehicleModelHash, 0, 4294967295),
            nuiFocused = ClampBoolean(payload.nuiFocused),
            clientGameTimerMs = ClampNumber(payload.clientGameTimerMs, 0, math.huge),
        },
    }
end)

AddEventHandler('playerDropped', function()
    ClientSelfReports[source] = nil
end)

-- ======================================================================
-- SECTION 7 -- REPORT ASSEMBLY
-- ======================================================================

local ownVersionCache = nil
local function GetOwnVersion()
    if ownVersionCache == nil then
        if type(GetCurrentResourceName) == 'function' and type(GetResourceMetadata) == 'function' then
            local ok, v = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
            ownVersionCache = (ok and type(v) == 'string' and v ~= '') and v or false
        else
            ownVersionCache = false
        end
    end
    return ownVersionCache or 'unknown'
end

--- @param clientReport table? -- ClientSelfReports[source], or nil
--- @return table -- JsonObj
local function BuildClientStateObj(clientReport)
    if not clientReport then
        return JsonObj({
            { 'received', false },
            { 'note', 'No client self-report received yet this session (the player may have connected very recently -- client/debugdump.lua sends one within a few seconds of loading, and every 5 seconds after that while Config.DebugDump.enabled is true).' },
        })
    end
    local d = clientReport.data
    return JsonObj({
        { 'received', true },
        { 'ageMs', (type(GetGameTimer) == 'function' and GetGameTimer() or 0) - clientReport.receivedAtServerMs },
        { 'modelHash', d.modelHash },
        { 'pedHealth', d.pedHealth },
        { 'pedMaxHealth', d.pedMaxHealth },
        { 'isDead', d.isDead },
        { 'isRagdoll', d.isRagdoll },
        { 'inVehicle', d.inVehicle },
        { 'vehicleModelHash', d.vehicleModelHash },
        { 'nuiFocused', d.nuiFocused },
        { 'clientGameTimerMs', d.clientGameTimerMs },
    })
end

--- @param stringList string[]
--- @return table -- JsonArr of strings
local function StringArr(stringList)
    return JsonArr(stringList)
end

--- @param source number
--- @param citizenid string
--- @param displayName string?
--- @param level string -- 'normal' | 'verbose', for THIS dump only
--- @param trigger string -- 'command' | 'auto_on_boot'
--- @return string? jsonText, number findingCount, number worthCheckingCount
local function BuildReport(source, citizenid, displayName, level, trigger)
    local findings, worthChecking = {}, {}

    local a1 = CheckFeatureGroupsDisagreement()
    for _, l in ipairs(a1.findings) do findings[#findings + 1] = '[A1] ' .. l end
    for _, l in ipairs(a1.worthChecking) do worthChecking[#worthChecking + 1] = '[A1] ' .. l end

    local a2State, a2Worth = CheckRuntimeOverrides()
    for _, l in ipairs(a2Worth) do worthChecking[#worthChecking + 1] = '[A2] ' .. l end

    local a3Findings, a3State = CheckDatabaseSchemaState()
    for _, l in ipairs(a3Findings) do findings[#findings + 1] = '[A3] ' .. l end

    local a4State = CheckDependencyVersions()

    local b1Worth = CheckWorldPropScans()
    for _, l in ipairs(b1Worth) do worthChecking[#worthChecking + 1] = '[B1] ' .. l end

    local b2Findings = CheckItemExistence()
    for _, l in ipairs(b2Findings) do findings[#findings + 1] = '[B2] ' .. l end

    local h1State = CheckSelfGrantSwitches()

    local decisionTrailLines, decisionTrailNote = nil, nil
    if level == 'verbose' then
        decisionTrailLines, decisionTrailNote = BuildDecisionTrailLines(citizenid)
    end

    local generatedAt = os.date('%Y-%m-%d %H:%M:%S')

    local readMeFirst = ('K9 Debug Dump for %s (citizenid %s), generated %s -- level: %s, trigger: %s.\n\n' ..
        '%d FINDING(S) below (see "findings"): things this resource is confident are actually wrong, worst first.\n' ..
        '%d WORTH-CHECKING item(s) below (see "worthChecking"): suspicious, with an innocent explanation possible -- read as questions, not verdicts.\n' ..
        'Everything else ("fullState") is exhaustive raw detail with no judgement attached -- meant to be searched, not read top to bottom. ' ..
        'See "fullState.knownGaps" for what this tool could NOT check and why.'
    ):format(displayName or 'unknown', citizenid, generatedAt, level, trigger, #findings, #worthChecking)

    local fullStatePairs = {
        { 'dependencyVersions', StringArr(a4State) },
        { 'databaseTables', StringArr(a3State) },
        { 'runtimeOverrides', StringArr(a2State) },
        { 'selfGrantSwitches', StringArr(h1State) },
        { 'clientSelfReport', BuildClientStateObj(ClientSelfReports[source]) },
        { 'knownGaps', StringArr(KNOWN_GAPS) },
    }

    if level == 'verbose' then
        fullStatePairs[#fullStatePairs + 1] = { 'decisionTrail', decisionTrailLines and StringArr(decisionTrailLines) or JsonArr({}) }
        if decisionTrailNote then
            fullStatePairs[#fullStatePairs + 1] = { 'decisionTrailNote', decisionTrailNote }
        end
    end

    local root = JsonObj({
        { 'readMeFirst', readMeFirst },
        { 'findings', StringArr(findings) },
        { 'worthChecking', StringArr(worthChecking) },
        { 'meta', JsonObj({
            { 'generatedAt', generatedAt },
            { 'resourceVersion', GetOwnVersion() },
            { 'requestedByCitizenid', citizenid },
            { 'requestedByName', displayName },
            { 'level', level },
            { 'trigger', trigger },
        }) },
        { 'fullState', JsonObj(fullStatePairs) },
    })

    return EncodeOrderedJson(root), #findings, #worthChecking
end

-- ======================================================================
-- SECTION 8 -- THE COMMAND. Own state only: `source` is the ONLY identity
-- this ever reads, never a target argument -- there is no target argument
-- at all, on purpose (see this file's own header).
-- ======================================================================

local DebugDumpCommandCooldown = NewCooldown(10000)
DebugDumpCommandCooldown.RegisterPlayerDropped()

RegisterCommand('k9debug', function(source, args)
    if type(source) ~= 'number' or source == 0 then
        print('[qbx_k9unit] /k9debug must be run by a connected player, not the server console -- it dumps that PLAYER\'s own state.')
        return
    end

    if not DebugDumpCommandCooldown.Consume(source) then
        NotifyPlayer(source, locale('debugdump.cooldown'), 'error')
        return
    end

    local citizenid, displayName = ResolvePlayerIdentity(source)
    if not citizenid then
        NotifyPlayer(source, locale('debugdump.no_citizenid'), 'error')
        return
    end

    local level = Config.DebugDump.level
    local rawArg = args[1] and tostring(args[1]):lower() or nil
    if rawArg ~= nil then
        if rawArg == 'normal' or rawArg == 'verbose' then
            if rawArg == 'verbose' and Config.DebugDump.level ~= 'verbose' then
                NotifyPlayer(source, locale('debugdump.verbose_not_collected'), 'error')
                level = 'normal'
            else
                level = rawArg
            end
        else
            NotifyPlayer(source, locale('debugdump.bad_level_arg', tostring(args[1]), Config.DebugDump.level), 'error')
            level = Config.DebugDump.level
        end
    end

    local reportJson, findingCount, worthCheckingCount = BuildReport(source, citizenid, displayName, level, 'command')
    if type(reportJson) ~= 'string' then
        NotifyPlayer(source, locale('debugdump.write_failed'), 'error')
        return
    end

    local filename, writeErr = WriteDumpFile(citizenid, reportJson)
    if writeErr or not filename then
        NotifyPlayer(source, locale('debugdump.write_failed'), 'error')
        return
    end

    NotifyPlayer(source, locale('debugdump.written', filename, findingCount, worthCheckingCount), 'success')
end, false)

-- ======================================================================
-- SECTION 9 -- autoOnBoot. Resource-wide facts only (no requesting player,
-- so no citizenid-scoped section -- decision trail/client self-report are
-- both meaningless here and are simply omitted).
-- ======================================================================

if Config.DebugDump.autoOnBoot == true then
    AddEventHandler('onResourceStart', function(resourceName)
        if type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() ~= resourceName then return end

        local a1 = CheckFeatureGroupsDisagreement()
        local a3Findings = CheckDatabaseSchemaState()
        local b2Findings = CheckItemExistence()

        local totalFindings = #a1.findings + #a3Findings + #b2Findings
        if totalFindings == 0 then
            return -- a clean boot writes nothing extra -- see Config.DebugDump.autoOnBoot's own comment in config.lua
        end

        local findings = {}
        for _, l in ipairs(a1.findings) do findings[#findings + 1] = '[A1] ' .. l end
        for _, l in ipairs(a3Findings) do findings[#findings + 1] = '[A3] ' .. l end
        for _, l in ipairs(b2Findings) do findings[#findings + 1] = '[B2] ' .. l end

        local generatedAt = os.date('%Y-%m-%d %H:%M:%S')
        local readMeFirst = ('K9 Debug Dump (automatic, at boot), generated %s -- %d finding(s) were found during this resource\'s own boot-time checks. See "findings" below.'):format(generatedAt, #findings)

        local root = JsonObj({
            { 'readMeFirst', readMeFirst },
            { 'findings', StringArr(findings) },
            { 'meta', JsonObj({
                { 'generatedAt', generatedAt },
                { 'resourceVersion', GetOwnVersion() },
                { 'trigger', 'auto_on_boot' },
            }) },
        })

        local jsonText = EncodeOrderedJson(root)
        if type(jsonText) ~= 'string' then return end

        WriteDumpFile('boot', jsonText)
    end)
end
