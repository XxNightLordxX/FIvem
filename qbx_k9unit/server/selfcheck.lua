--[[
    qbx_k9unit/server/selfcheck.lua

    Boot-time self-check, extending a pattern this resource already trusts:
    server/datastore.lua's own "SCHEMA COLLISION SAFETY NET" tells an
    operator, precisely and by name, when its OWN database does not match
    what it expects -- never silently, never by refusing to start. This
    file applies that same discipline to two things nothing previously
    checked at all:

      1. DEPENDENCY VERSIONS. README.md carries a hand-dated table ("last
         checked compatible against ox_lib 3.39.0" and so on) -- a note to
         a human, not a check. A server running an older dependency got no
         warning at all; just divergent behaviour somewhere downstream,
         later, with nothing pointing at the cause. See "PART 1" below.

      2. UNRECOGNISED Config.Features KEYS. `Config.Features` has 58 keys.
         `Config.Features.ScentTraking = false` (typo) previously produced
         no error and no effect -- the real flag stays on, the typo'd one
         does nothing, and an operator has no way to find out short of
         reading every line of source. See "PART 2" below.

    BOTH RULES, THE SAME AS THE SCHEMA SAFETY NET THIS MIRRORS: WARN LOUDLY,
    NEVER BLOCK. Nothing in this file ever refuses to start this resource,
    asserts, or errors past its own pcall boundaries -- every native touch
    is guarded so this file is inert (registers nothing, checks nothing) in
    tests/selfcheck_spec.lua's plain-Lua sandbox, exactly like server/
    datastore.lua's own schema probe already is (see that file's own "WHY
    THIS IS SAFE TO SANDBOX-TEST AGAINST").

    TESTABILITY SHAPE: every function on the `K9SelfCheck` table below is
    PURE -- no native calls, no globals read beyond its own arguments -- so
    tests/selfcheck_spec.lua exercises the real decision logic directly,
    with fabricated inputs, the same "pure core, thin native-touching glue"
    split this resource already uses elsewhere (server/cooldowns.lua's
    constructors, server/certtiers.lua's catalogue helpers). The glue that
    actually calls GetResourceMetadata/GetResourceState/LoadResourceFile and
    prints to the console lives in local functions below `K9SelfCheck`
    itself and is deliberately NOT unit-tested beyond "it does not error in
    a native-less sandbox" -- there is nothing to assert against a real
    FXServer's own natives without one running, and this codebase's own
    tests/fixtures/sandbox.lua header already states that convention
    plainly rather than pretending otherwise.

    ======================================================================
    PART 1 -- DEPENDENCY VERSION CHECK

    NATIVES VERIFIED AGAINST PRIMARY SOURCE BEFORE USE (this resource's own
    established rule -- "no native is allowlisted here on an unverified
    assertion", client/screenfx.lua's own header):
      * GET_RESOURCE_METADATA -- ext/native-decls/GetResourceMetadata.md,
        ns CFX, apiset shared: `char* GET_RESOURCE_METADATA(char*
        resourceName, char* metadataKey, int index)`. A `char*`-returning
        native is FiveM's own "string, or nil if there is nothing there"
        shape (the same convention GetResourceState -- already allowlisted
        in .luacheckrc -- and LoadResourceFile both use) -- confirmed
        against the citizenfx/fivem-natives declaration, not assumed from
        the name. A resource whose fxmanifest.lua never sets `version`
        genuinely has no metadata to return; that is normal, not an error,
        and is handled as its own case below (`no_metadata`), never folded
        into "too old".
      * GET_RESOURCE_STATE -- already verified and allowlisted elsewhere in
        this resource (.luacheckrc's own comment cites
        ext/native-decls/GetResourceState.md, apiset shared) -- reused here
        unchanged. Returns one of "missing", "started", "starting",
        "stopped", "stopping", "uninitialized", "unknown".
      * NEITHER NATIVE WAS EXERCISED AGAINST A LIVE FXSERVER -- none is
        available in this sandboxed development environment. Verification
        here means "read the primary native declaration and reasoned from
        its documented C signature/return type", the same standard this
        resource's own .luacheckrc already applies throughout, not "ran it
        and observed the result". Said plainly rather than implied.

    WHY THE FIVE DEPENDENCIES AND THEIR MINIMUMS ARE HARD-CODED, NOT
    DISCOVERED: fxmanifest.lua's own `dependencies { ... }` block names
    exactly five resources (qbx_core, ox_lib, ox_target, oxmysql,
    ox_inventory) -- read directly from that file, not guessed. README.md's
    "What this needs, before you install it" section states a minimum
    version for every one of those five and no others ("Last checked
    compatible against: qbx_core 1.24.0, ox_lib 3.39.0, ox_target 1.18.1,
    oxmysql 2.14.1, ox_inventory 2.47.9") -- copied verbatim below, not
    invented. `fxmanifest.lua` also exposes each dependency's name as its
    own `dependency` resource-metadata entry (GET_NUM_RESOURCE_METADATA /
    GET_RESOURCE_METADATA(name, 'dependency', i)), which could enumerate
    this list dynamically instead of hard-coding it -- deliberately NOT
    used here: that would be a second, unverified native-behaviour
    assumption (metadata key naming for the `dependencies` manifest
    directive was not confirmed against primary source, unlike `version`,
    which the task this file answers explicitly names) stacked on top of
    the one already verified above, for a five-entry list that changes
    exactly as often as fxmanifest.lua's own dependencies block does -- a
    file that is not this file's to edit and whose owner already reviews
    any change to it. If a sixth hard dependency is ever added, this table
    needs a matching line added in the SAME change (see
    MISSING_TABLE_FEATURE_DESCRIPTIONS in server/datastore.lua for the same
    hand-maintained-list convention, disclosed there for the identical
    reason).

    PARSING VERSIONS HONESTLY: `ParseSemver` below accepts an optional
    leading "v" and a MAJOR.MINOR[.PATCH] numeric core, ignoring any
    trailing pre-release/build suffix ("-rc1", "+build5"). A string with no
    such numeric core at all -- a bare git hash, a date written with
    dashes, anything non-numeric -- fails to parse and is reported as
    `unknown_format`, never as "too old". A string this resource does not
    control (an operator's real dependency version) is untrusted input by
    definition, so this never assumes a shape it has not confirmed.
    ======================================================================
]]

K9SelfCheck = K9SelfCheck or {}

-- ----------------------------------------------------------------------
-- PURE LOGIC -- no native calls, no globals beyond arguments. Exercised
-- directly (fabricated inputs, no natives, no LoadResourceFile) by
-- tests/selfcheck_spec.lua.
-- ----------------------------------------------------------------------

--- Parses a MAJOR.MINOR[.PATCH] numeric core out of a version string,
--- tolerating a leading "v" and ignoring any trailing pre-release/build
--- suffix. Returns nil for anything that does not start with at least
--- MAJOR.MINOR (a git hash, a bare date written with dashes, an empty
--- string, a non-string) -- that is the UNKNOWN case, deliberately never
--- coerced into a number for comparison.
--- @param versionString any
--- @return table? -- { major = integer, minor = integer, patch = integer }
function K9SelfCheck.ParseSemver(versionString)
    if type(versionString) ~= 'string' then return nil end
    local major, minor, patch = versionString:match('^v?(%d+)%.(%d+)%.?(%d*)')
    if not major then return nil end
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch) or 0,
    }
end

--- @param a table -- a K9SelfCheck.ParseSemver() result
--- @param b table -- a K9SelfCheck.ParseSemver() result
--- @return integer -- negative if a < b, 0 if equal, positive if a > b
function K9SelfCheck.CompareSemver(a, b)
    if a.major ~= b.major then return a.major - b.major end
    if a.minor ~= b.minor then return a.minor - b.minor end
    return a.patch - b.patch
end

--- Classifies one dependency's real, observed state against its minimum --
--- pure decision table, no native calls. Every branch here is one of the
--- five cases this check's own design brief requires distinguishing.
--- @param resourceState string -- GetResourceState(name)'s real return, or 'unknown' if that native was unavailable
--- @param versionString string? -- GetResourceMetadata(name, 'version', 0)'s real return; nil = no metadata shipped, or not checked because not started
--- @param minVersionString string -- this resource's own recorded minimum (from README.md), e.g. '3.39.0'
--- @return table { status = 'not_started'|'no_metadata'|'unknown_format'|'below_minimum'|'ok', found = string? }
function K9SelfCheck.EvaluateDependencyVersion(resourceState, versionString, minVersionString)
    if resourceState ~= 'started' then
        return { status = 'not_started', resourceState = resourceState }
    end
    if versionString == nil or versionString == '' then
        return { status = 'no_metadata' }
    end
    local found = K9SelfCheck.ParseSemver(versionString)
    local min = K9SelfCheck.ParseSemver(minVersionString)
    if not found or not min then
        return { status = 'unknown_format', found = versionString }
    end
    if K9SelfCheck.CompareSemver(found, min) < 0 then
        return { status = 'below_minimum', found = versionString }
    end
    -- Equal to, or newer than, the minimum -- both are the quiet "say
    -- nothing" case this check's own design brief calls for explicitly
    -- ("version newer (say nothing)"); there is no useful distinction to
    -- an operator between "exactly the version we last checked" and
    -- "newer", so both collapse into 'ok' rather than a third status.
    return { status = 'ok', found = versionString }
end

--- Builds the one console line for a dependency verdict that is NOT 'ok'
--- -- returns nil for 'ok' (the "say nothing" case), matching this
--- resource's own established voice (plain English, `!!` reserved for
--- something that actually warrants attention -- see server/datastore.lua's
--- schema-collision messages for the same convention). Never asserts,
--- never mentions blocking -- this resource has been bitten before by a
--- top-level failure taking every registration below it down with it, and
--- this check exists to warn, not to repeat that mistake in a new file.
--- @param dep table -- { name = string, minVersion = string }
--- @param verdict table -- a K9SelfCheck.EvaluateDependencyVersion() result
--- @return string?
function K9SelfCheck.FormatDependencyWarning(dep, verdict)
    if verdict.status == 'not_started' then
        return ("[qbx_k9unit] selfcheck: !! dependency '%s' is not currently running (state=%s) -- its version could not be checked. It is a hard dependency in fxmanifest.lua; FXServer should refuse to start qbx_k9unit at all without it running, so seeing this means something stopped it AFTER boot. Start/restart '%s'."):format(dep.name, tostring(verdict.resourceState), dep.name)
    elseif verdict.status == 'no_metadata' then
        return ("[qbx_k9unit] selfcheck: '%s' is running but its own fxmanifest.lua ships no 'version' field, so its version could not be checked against %s, the version this resource was last checked compatible against (see README.md). Shipping no version metadata is normal for some resources/forks -- this is informational, not an error."):format(dep.name, dep.minVersion)
    elseif verdict.status == 'unknown_format' then
        return ("[qbx_k9unit] selfcheck: '%s' reports version '%s', which is not a plain MAJOR.MINOR[.PATCH] number this check knows how to compare against %s, the version this resource was last checked compatible against (see README.md). NOT treated as too old -- just unverifiable automatically. Check by hand if you are unsure."):format(dep.name, tostring(verdict.found), dep.minVersion)
    elseif verdict.status == 'below_minimum' then
        return ("[qbx_k9unit] selfcheck: !! '%s' version %s is older than %s, the version this resource was last checked compatible against (see README.md's compatibility table). It may still work -- this is a warning, never a block -- but if something behaves oddly, updating '%s' is the first thing to try."):format(dep.name, verdict.found, dep.minVersion, dep.name)
    end
    return nil
end

--- ======================================================================
--- PART 2 -- UNRECOGNISED Config.Features KEY CHECK
---
--- WHERE THE "SET THIS RESOURCE REALLY READS" COMES FROM, AND WHY: the one
--- genuinely authoritative list of every real feature key already exists
--- -- server/runtimecontrol.lua's own FEATURE_TIERS table, which that
--- file's own header confirms is kept in lock-step with every real
--- Config.Features key today (tests/runtimefeaturetiers_spec.lua is the
--- existing drift guard proving it, and this pass independently verified
--- the same fact by hand: both currently name the identical 58 keys).
---
--- THAT TABLE CANNOT BE READ DEFENSIVELY FROM HERE -- this is not "it may
--- not be loaded yet", which a guarded read could wait out; it is a plain
--- Lua `local FEATURE_TIERS = { ... }` with no resource-global, no export,
--- and no accessor anywhere. server/runtimecontrol.lua's own header says
--- so outright ("THIS FILE exposes no resource-global functions"), and
--- tests/runtimefeaturetiers_spec.lua's own header independently confirms
--- the same limitation from the test side ("not reachable without
--- exporting FEATURE_TIERS' own key list, which server/runtimecontrol.lua
--- ... declines to do"). There is structurally nothing to guard against --
--- it is invisible from this file regardless of load order, so "read it
--- defensively" is not an option here, only "derive the list another way".
---
--- THE OTHER WAY: this file reads server/runtimecontrol.lua's own RAW
--- TEXT (via LoadResourceFile, at real boot -- via a fabricated string in
--- tests/selfcheck_spec.lua) and checks whether each Config.Features key
--- appears ANYWHERE in it as a whole identifier. This is deliberately NOT
--- a structural parse of the FEATURE_TIERS table (extracting exactly its
--- keys via brace-depth tracking) -- that would break the moment a comment
--- inside that block used an unbalanced brace, or the table were
--- reformatted, for a check whose one job is to never cry wolf. A plain
--- whole-word substring scan across the WHOLE FILE is far more tolerant:
--- every real feature key has to appear literally as text somewhere in
--- that file for FEATURE_TIERS/GetFeatureTier to work AT ALL (a Lua table
--- key is written as literal text even when looked up through a runtime
--- variable elsewhere), so the failure mode this looser check trades away
--- is "misses a truly exotic case where a real key is never once written
--- out literally in that file" -- something that cannot happen today,
--- since every one of the 58 real keys is a literal FEATURE_TIERS entry --
--- in exchange for near-zero risk of the ONE outcome this task explicitly
--- calls worse than not having the check at all: warning about a
--- legitimate key.
---
--- WHY server/runtimecontrol.lua SPECIFICALLY, AND NOT A HAND-MAINTAINED
--- list duplicated into THIS file: a second, independently hand-kept list
--- of "every real feature key" is exactly the failure mode
--- server/runtimecontrol.lua's own header already documents happening
--- once for real (eleven features shipped in Config.Features with no
--- matching FEATURE_TIERS entry, unnoticed for months) -- writing a THIRD
--- copy here would not fix that class of bug, it would add another place
--- for the same drift to happen invisibly. Reading runtimecontrol.lua's
--- own text instead means this check can never drift out of sync with
--- itself; it can only ever be as complete as that file already is, which
--- tests/runtimefeaturetiers_spec.lua independently keeps honest.
--- ======================================================================

--- @param configFeatures table<string, boolean> -- Config.Features
--- @param registrySourceText string -- raw text of server/runtimecontrol.lua (or any equivalent corpus, in a test)
--- @return string[] -- sorted list of keys not found as a whole identifier anywhere in registrySourceText
function K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registrySourceText)
    local unrecognized = {}
    if type(configFeatures) ~= 'table' or type(registrySourceText) ~= 'string' then
        return unrecognized
    end

    for key in pairs(configFeatures) do
        local found = false
        local searchFrom = 1
        while not found do
            local matchStart, matchEnd = registrySourceText:find(key, searchFrom, true)
            if not matchStart then break end
            -- Whole-identifier match only: a key must not be preceded or
            -- followed by another Lua identifier character, so e.g.
            -- 'ScentTracking' cannot falsely match inside a longer name
            -- like 'ScentTrackingAdvanced' that happens to start the same
            -- way (no such key exists today, but this keeps the check
            -- correct as longer names are added later).
            local before = registrySourceText:sub(matchStart - 1, matchStart - 1)
            local after = registrySourceText:sub(matchEnd + 1, matchEnd + 1)
            local boundaryOk = (before == '' or not before:match('[%w_]'))
                and (after == '' or not after:match('[%w_]'))
            if boundaryOk then
                found = true
            else
                searchFrom = matchEnd + 1
            end
        end
        if not found then
            unrecognized[#unrecognized + 1] = key
        end
    end

    table.sort(unrecognized)
    return unrecognized
end

--- ======================================================================
--- FINAL BOOT SUMMARY LINE
---
--- Added after a new-buyer walkthrough found this resource prints
--- essentially nothing on a healthy install -- every print( ) in
--- server/*.lua answers a degraded or error state, so a first-time owner
--- with a clean install has to infer success from silence alone, out of
--- step with how loud and specific this resource is about everything that
--- CAN go wrong. This is the one line that always prints, win or lose --
--- carrying real, already-computed information (this resource's own
--- version, the dependency/feature-key tallies the checks above already
--- produced, and the database backend) rather than a bare "loaded OK".
---
--- NEVER FABRICATES A STATE IT DID NOT VERIFY: the database clause reports
--- only what server/datastore.lua's own K9Store.IsDatabaseEnabled()
--- exposes -- connected-with-no-whole-resource-collision, or memory-only.
--- K9Store exposes no table-count accessor at all (grep confirms exactly
--- one function assigned onto that global table,
--- `K9Store.IsDatabaseEnabled`), so this deliberately does NOT claim "N
--- tables verified" -- a confident number this file cannot actually
--- confirm would be worse than the shorter, honest line below. If an
--- exact verified-table-count becomes available from server/datastore.lua
--- in the future (something to route to whoever owns that file, not
--- edited here), this line can be extended to use it.
--- ======================================================================

--- @param info table {
---   version = string?,                                    -- this resource's own fxmanifest.lua version, or nil if unknown
---   deps = { total, ok, unverified, problems }?,           -- from the dependency check, or nil if it could not run
---   features = { total, unrecognized }?,                   -- from the Config.Features check, or nil if it could not run
---   databaseState = string,                                -- short phrase; never fabricated, see header above
--- }
--- @return string -- exactly ONE line, never a banner
function K9SelfCheck.BuildBootSummaryLine(info)
    local parts = {}

    parts[#parts + 1] = info.version and ('v' .. info.version) or 'version unknown'

    if info.deps then
        if info.deps.problems > 0 or info.deps.unverified > 0 then
            parts[#parts + 1] = ('dependencies: %d/%d at/above minimum (%d unverified, %d warning(s) above)')
                :format(info.deps.ok, info.deps.total, info.deps.unverified, info.deps.problems)
        else
            parts[#parts + 1] = ('dependencies: %d/%d at/above minimum'):format(info.deps.ok, info.deps.total)
        end
    else
        parts[#parts + 1] = 'dependencies: not checked'
    end

    if info.features then
        local recognized = info.features.total - info.features.unrecognized
        if info.features.unrecognized > 0 then
            parts[#parts + 1] = ('Config.Features: %d/%d keys recognized (%d warning(s) above)')
                :format(recognized, info.features.total, info.features.unrecognized)
        else
            parts[#parts + 1] = ('Config.Features: %d/%d keys recognized'):format(info.features.total, info.features.total)
        end
    else
        parts[#parts + 1] = 'Config.Features: not checked'
    end

    parts[#parts + 1] = 'database: ' .. (info.databaseState or 'unknown')

    return '[qbx_k9unit] selfcheck: boot summary -- ' .. table.concat(parts, ' | ')
end

-- ----------------------------------------------------------------------
-- NATIVE-TOUCHING GLUE -- guarded, thin, not independently unit-tested
-- beyond "registers nothing in a native-less sandbox" (see this file's own
-- header). Every native call is pcall-wrapped; nothing here can throw past
-- its own boundary, matching server/datastore.lua's own schema-probe
-- discipline exactly.
-- ----------------------------------------------------------------------

-- Verbatim from README.md's "Last checked compatible against" line and
-- fxmanifest.lua's own `dependencies { ... }` block -- see this file's own
-- header for why this is hand-kept here rather than derived from a
-- dependency-metadata native. Update BOTH this table and README.md's own
-- compatibility line in the same change if either ever changes.
local DEPENDENCIES = {
    { name = 'qbx_core',     minVersion = '1.24.0' },
    { name = 'ox_lib',       minVersion = '3.39.0' },
    { name = 'ox_target',    minVersion = '1.18.1' },
    { name = 'oxmysql',      minVersion = '2.14.1' },
    { name = 'ox_inventory', minVersion = '2.47.9' },
}

--- @param resourceName string
--- @return string -- GetResourceState's real return, or 'unknown' if the native is unavailable or throws
local function SafeGetResourceState(resourceName)
    if type(GetResourceState) ~= 'function' then return 'unknown' end
    local ok, state = pcall(GetResourceState, resourceName)
    if ok and type(state) == 'string' then return state end
    return 'unknown'
end

--- @param resourceName string
--- @return string? -- GetResourceMetadata(resourceName, 'version', 0)'s real return, or nil
local function SafeGetVersionMetadata(resourceName)
    if type(GetResourceMetadata) ~= 'function' then return nil end
    local ok, value = pcall(GetResourceMetadata, resourceName, 'version', 0)
    if ok and type(value) == 'string' and value ~= '' then return value end
    return nil
end

--- Runs the dependency version check, printing one line per dependency
--- that is NOT 'ok' (see K9SelfCheck.FormatDependencyWarning), and returns
--- the tally BuildBootSummaryLine needs. Returns nil (check "could not
--- run", never "everything failed") if the natives it needs are absent --
--- the only realistic way that happens is tests/selfcheck_spec.lua's plain
--- Lua sandbox, which has neither native.
--- @return table? { total, ok, unverified, problems }
local function RunDependencyCheck()
    if type(GetResourceState) ~= 'function' or type(GetResourceMetadata) ~= 'function' then
        print('[qbx_k9unit] selfcheck: dependency version check could not run in this environment (GetResourceState/GetResourceMetadata unavailable) -- skipping. This never blocks startup either way.')
        return nil
    end

    local okCount, unverifiedCount, problemCount = 0, 0, 0
    for _, dep in ipairs(DEPENDENCIES) do
        local state = SafeGetResourceState(dep.name)
        local version = (state == 'started') and SafeGetVersionMetadata(dep.name) or nil
        local verdict = K9SelfCheck.EvaluateDependencyVersion(state, version, dep.minVersion)
        local line = K9SelfCheck.FormatDependencyWarning(dep, verdict)
        if line then print(line) end

        if verdict.status == 'ok' then
            okCount = okCount + 1
        elseif verdict.status == 'no_metadata' or verdict.status == 'unknown_format' then
            unverifiedCount = unverifiedCount + 1
        else
            problemCount = problemCount + 1
        end
    end

    return { total = #DEPENDENCIES, ok = okCount, unverified = unverifiedCount, problems = problemCount }
end

--- @param relativePath string -- e.g. 'server/runtimecontrol.lua'
--- @return string? -- the file's raw text, or nil if it could not be read
local function ReadOwnResourceFile(relativePath)
    if type(LoadResourceFile) ~= 'function' or type(GetCurrentResourceName) ~= 'function' then
        return nil
    end
    local ok, content = pcall(LoadResourceFile, GetCurrentResourceName(), relativePath)
    if ok and type(content) == 'string' and content ~= '' then return content end
    return nil
end

--- Runs the Config.Features key check, printing one named warning if any
--- unrecognized key is found, and returns the tally BuildBootSummaryLine
--- needs. Returns nil ("could not run") if Config.Features is missing, or
--- server/runtimecontrol.lua could not be read -- never treated as "every
--- key is bad".
--- @return table? { total, unrecognized }
local function RunFeatureKeyCheck()
    if type(Config) ~= 'table' or type(Config.Features) ~= 'table' then
        print('[qbx_k9unit] selfcheck: Config.Features is missing or malformed -- skipping the unrecognized-key check.')
        return nil
    end

    local registryText = ReadOwnResourceFile('server/runtimecontrol.lua')
    if not registryText then
        print('[qbx_k9unit] selfcheck: could not read server/runtimecontrol.lua to cross-check Config.Features keys (LoadResourceFile unavailable, or the file is missing) -- skipping that check this boot. This never blocks startup either way.')
        return nil
    end

    local total = 0
    for _ in pairs(Config.Features) do total = total + 1 end

    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(Config.Features, registryText)
    if #unrecognized > 0 then
        print(("[qbx_k9unit] selfcheck: !! %d Config.Features key(s) do not appear anywhere in this resource's own feature registry (server/runtimecontrol.lua) -- almost certainly a typo, a renamed/removed feature, or a leftover from an old install: %s. Setting one of these to true/false has NO EFFECT: nothing in this resource reads it, and the real feature it was probably meant to control keeps whatever value it already has. Check the exact spelling against config.lua's own comments or README.md."):format(#unrecognized, table.concat(unrecognized, ', ')))
    end

    return { total = total, unrecognized = #unrecognized }
end

--- Short, honest phrase for the final summary line's database clause.
--- Waits (bounded) for server/datastore.lua's own schema-collision probe
--- to settle first -- the same K9Store.WaitForSchemaCheckToSettle() every
--- other file's own boot-time reader of that state already calls before
--- its first read, per that function's own doc comment -- so this does
--- not race the answer and report a stale "connected" the instant before
--- a real collision is found. Never claims a table count (see this file's
--- own "FINAL BOOT SUMMARY LINE" header for why).
--- @return string
local function BuildDatabaseStatePhrase()
    if type(K9Store) ~= 'table' or type(K9Store.IsDatabaseEnabled) ~= 'function' then
        return 'unknown (server/datastore.lua not loaded)'
    end
    if type(K9Store.WaitForSchemaCheckToSettle) == 'function' then
        pcall(K9Store.WaitForSchemaCheckToSettle)
    end
    local ok, enabled = pcall(K9Store.IsDatabaseEnabled)
    if not ok then return 'unknown' end
    if enabled then
        return 'connected (no whole-resource schema collision detected -- see any warning above for individual tables)'
    end
    return 'memory-only (see any warning above from server/datastore.lua for why)'
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('onResourceStart', function(resourceName)
        if type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() ~= resourceName then return end

        -- ORDER MATTERS: dependency check, then Config.Features check, then
        -- the one final summary line -- so the summary reads as the
        -- conclusion of the two checks above it, never an unrelated
        -- announcement ahead of them.
        local depResult = RunDependencyCheck()
        local featureResult = RunFeatureKeyCheck()
        local databaseState = BuildDatabaseStatePhrase()

        local ownVersion = nil
        if type(GetCurrentResourceName) == 'function' then
            ownVersion = SafeGetVersionMetadata(GetCurrentResourceName())
        end

        print(K9SelfCheck.BuildBootSummaryLine({
            version = ownVersion,
            deps = depResult,
            features = featureResult,
            databaseState = databaseState,
        }))
    end)
end
