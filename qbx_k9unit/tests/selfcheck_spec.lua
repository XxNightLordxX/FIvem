--[[
    tests/selfcheck_spec.lua

    Tests server/selfcheck.lua -- the boot-time dependency-version check and
    the Config.Features unrecognized-key check (see that file's own header
    for the full design reasoning). Structured the same way as
    tests/cooldowns_spec.lua/tests/runtimefeaturetiers_spec.lua: pure logic
    exercised directly with fabricated inputs, PLUS at least one test that
    loads the REAL, unmodified server/selfcheck.lua (and, for the
    Config.Features check, the REAL config.lua + server/runtimecontrol.lua)
    so this suite proves the wiring, not just the helper functions in
    isolation.

    RED/GREEN PROOF PERFORMED FOR THIS PASS (both checks, as required):
    after writing every test below, server/selfcheck.lua's two real fixes
    were each temporarily neutralized in turn (CompareSemver forced to
    compare version strings lexically instead of numerically; then
    FindUnrecognizedFeatureKeys forced to always return an empty list) and
    `lua5.4 selfcheck_spec.lua` was re-run against each broken copy. Both
    breaks turned the exact tests that name them red (never a whole-suite
    crash -- each failure was a clean, named assertion failure), confirming
    those tests actually exercise the fix and are not vacuously passing.
    The file was restored to its real, working form immediately after each
    check; the version in the working tree is the fixed one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Load the real, unmodified server/selfcheck.lua into a bare sandbox with
-- NO FiveM natives stubbed at all, to get at K9SelfCheck's pure functions
-- directly. Since every native touch in that file is guarded (`type(...)
-- == 'function'`), loading it here registers nothing and calls nothing --
-- exactly like server/datastore.lua's own schema probe in every OTHER
-- spec that loads that file without stubbing AddEventHandler.
-- ----------------------------------------------------------------------
local function loadPureModule()
    local env = Sandbox.newEnv({})
    Sandbox.loadInto('../server/selfcheck.lua', env)
    return env.K9SelfCheck
end

local K9SelfCheck = loadPureModule()

t.test('sanity: loading the real file in a native-less sandbox registers nothing and defines K9SelfCheck', function()
    t.isNotNil(K9SelfCheck, 'K9SelfCheck must be defined as a resource-global table')
    t.equals(type(K9SelfCheck.ParseSemver), 'function')
    t.equals(type(K9SelfCheck.FindUnrecognizedFeatureKeys), 'function')
end)

-- ----------------------------------------------------------------------
-- ParseSemver / CompareSemver
-- ----------------------------------------------------------------------

t.test('ParseSemver parses a plain MAJOR.MINOR.PATCH string', function()
    local v = K9SelfCheck.ParseSemver('3.39.0')
    t.isNotNil(v)
    t.equals(v.major, 3)
    t.equals(v.minor, 39)
    t.equals(v.patch, 0)
end)

t.test('ParseSemver tolerates a leading "v" and a missing patch component', function()
    local v = K9SelfCheck.ParseSemver('v1.2')
    t.isNotNil(v)
    t.equals(v.major, 1)
    t.equals(v.minor, 2)
    t.equals(v.patch, 0)
end)

t.test('ParseSemver ignores a trailing pre-release/build suffix', function()
    local v = K9SelfCheck.ParseSemver('2.14.1-rc1+build5')
    t.isNotNil(v)
    t.equals(v.major, 2)
    t.equals(v.minor, 14)
    t.equals(v.patch, 1)
end)

t.test('ParseSemver returns nil for a git hash (not semver at all)', function()
    t.isNil(K9SelfCheck.ParseSemver('a3f9e21'))
end)

t.test('ParseSemver returns nil for a bare date written with dashes', function()
    t.isNil(K9SelfCheck.ParseSemver('2026-08-26'))
end)

t.test('ParseSemver returns nil for an empty string, and for non-string input', function()
    t.isNil(K9SelfCheck.ParseSemver(''))
    t.isNil(K9SelfCheck.ParseSemver(nil))
    t.isNil(K9SelfCheck.ParseSemver(42))
end)

t.test('CompareSemver: THE STRING-COMPARISON TRAP -- 3.39.0 must compare NEWER than 3.4.0, never the other way around', function()
    local a = K9SelfCheck.ParseSemver('3.39.0')
    local b = K9SelfCheck.ParseSemver('3.4.0')
    t.isTrue(K9SelfCheck.CompareSemver(a, b) > 0, '3.39.0 must be greater than 3.4.0 numerically, even though "3.4.0" > "3.39.0" as a plain string')
    t.isTrue(K9SelfCheck.CompareSemver(b, a) < 0)
end)

t.test('CompareSemver: equal versions compare as 0', function()
    local a = K9SelfCheck.ParseSemver('1.18.1')
    local b = K9SelfCheck.ParseSemver('1.18.1')
    t.equals(K9SelfCheck.CompareSemver(a, b), 0)
end)

-- ----------------------------------------------------------------------
-- EvaluateDependencyVersion -- the five cases the design brief names
-- ----------------------------------------------------------------------

t.test('EvaluateDependencyVersion: dependency not started at all', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('stopped', nil, '3.39.0')
    t.equals(verdict.status, 'not_started')
end)

t.test('EvaluateDependencyVersion: started but ships no version metadata -- NOT an error, a distinct case', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', nil, '3.39.0')
    t.equals(verdict.status, 'no_metadata')
end)

t.test('EvaluateDependencyVersion: version string is not semver at all (git hash) -- UNKNOWN, never "too old"', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', 'a3f9e21', '3.39.0')
    t.equals(verdict.status, 'unknown_format')
end)

t.test('EvaluateDependencyVersion: THE REAL-WORLD TRAP -- 3.4.0 is below minimum 3.39.0, must be reported as below_minimum, never "ok" via string comparison', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', '3.4.0', '3.39.0')
    t.equals(verdict.status, 'below_minimum')
    t.equals(verdict.found, '3.4.0')
end)

t.test('EvaluateDependencyVersion: exactly at minimum is ok', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', '3.39.0', '3.39.0')
    t.equals(verdict.status, 'ok')
end)

t.test('EvaluateDependencyVersion: newer than minimum is ok ("say nothing" case)', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', '4.0.0', '3.39.0')
    t.equals(verdict.status, 'ok')
end)

-- ----------------------------------------------------------------------
-- FormatDependencyWarning -- WARN LOUDLY, NEVER BLOCK; nil on the good path
-- ----------------------------------------------------------------------

t.test('FormatDependencyWarning: returns nil for an ok verdict -- the "say nothing" case', function()
    t.isNil(K9SelfCheck.FormatDependencyWarning({ name = 'ox_lib', minVersion = '3.39.0' }, { status = 'ok', found = '3.39.0' }))
end)

t.test('FormatDependencyWarning: below_minimum names the resource, the version found, and the minimum -- never claims it will refuse to start', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'ox_lib', minVersion = '3.39.0' }, { status = 'below_minimum', found = '3.4.0' })
    t.isNotNil(line)
    t.contains(line, 'ox_lib')
    t.contains(line, '3.4.0')
    t.contains(line, '3.39.0')
    t.notContains(line, 'refus', 'must never threaten to refuse to start over a version warning')
    t.notContains(line, 'assert', 'must never mention asserting/crashing')
end)

t.test('FormatDependencyWarning: no_metadata is informational, not alarming ("!!")', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'oxmysql', minVersion = '2.14.1' }, { status = 'no_metadata' })
    t.isNotNil(line)
    t.contains(line, 'oxmysql')
    t.notContains(line, '!!', 'a resource shipping no version metadata is a normal, expected case, not a loud warning')
end)

t.test('FormatDependencyWarning: unknown_format explicitly disclaims "too old" rather than silently implying it', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'ox_target', minVersion = '1.18.1' }, { status = 'unknown_format', found = 'a3f9e21' })
    t.isNotNil(line)
    t.contains(line, 'a3f9e21')
    t.contains(line, 'NOT treated as too old')
end)

t.test('FormatDependencyWarning: not_started names the resource and does not claim its version is bad', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'ox_inventory', minVersion = '2.47.9' }, { status = 'not_started', resourceState = 'stopped' })
    t.isNotNil(line)
    t.contains(line, 'ox_inventory')
    t.contains(line, 'stopped')
end)

-- ----------------------------------------------------------------------
-- FindUnrecognizedFeatureKeys -- the Config.Features typo check
-- ----------------------------------------------------------------------

t.test('FindUnrecognizedFeatureKeys: a typo key not present anywhere in the registry text is flagged', function()
    local configFeatures = { ScentTracking = true, ScentTraking = false }
    local registryText = "local FEATURE_TIERS = {\n    ScentTracking = { tier = 'live' },\n}"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 1)
    t.equals(unrecognized[1], 'ScentTraking')
end)

t.test('FindUnrecognizedFeatureKeys: every real key present in the registry text produces zero warnings (no false positives)', function()
    local configFeatures = { LeashMechanics = true, RadialMenu = true }
    local registryText = "LeashMechanics = { tier = 'live' },\nRadialMenu = { tier = 'onstart' },"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 0)
end)

t.test('FindUnrecognizedFeatureKeys: WHOLE-WORD BOUNDARY -- a key must not falsely match as a substring of a longer name', function()
    -- The registry only ever names 'ScentTrackingAdvanced'; a Config.Features
    -- key of plain 'ScentTracking' must NOT be considered found just because
    -- it is a textual prefix of that longer name.
    local configFeatures = { ScentTracking = true }
    local registryText = "ScentTrackingAdvanced = { tier = 'live' },"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 1)
    t.equals(unrecognized[1], 'ScentTracking')
end)

t.test('FindUnrecognizedFeatureKeys: WHOLE-WORD BOUNDARY, the other direction -- a longer real key is not falsely matched by a shorter substring appearing elsewhere', function()
    local configFeatures = { ScentTrackingAdvanced = true }
    local registryText = "ScentTracking = { tier = 'live' },"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 1)
    t.equals(unrecognized[1], 'ScentTrackingAdvanced')
end)

t.test('FindUnrecognizedFeatureKeys: malformed input (nil/non-table) never errors, just reports nothing', function()
    t.equals(#K9SelfCheck.FindUnrecognizedFeatureKeys(nil, 'text'), 0)
    t.equals(#K9SelfCheck.FindUnrecognizedFeatureKeys({ A = true }, nil), 0)
end)

t.test('LOAD-BEARING, AGAINST THE REAL CODEBASE: every real Config.Features key (config.lua) is found somewhere in the real feature registry (server/runtimecontrol.lua) -- zero false positives against what actually ships today', function()
    local configEnv = Sandbox.newEnv({})
    Sandbox.loadInto('../config.lua', configEnv)

    local handle = assert(io.open('../server/runtimecontrol.lua', 'r'), 'expected to run with cwd = qbx_k9unit/tests')
    local registryText = handle:read('a')
    handle:close()

    local totalFeatures = 0
    for _ in pairs(configEnv.Config.Features) do totalFeatures = totalFeatures + 1 end
    -- Sanity, same discipline as tests/runtimefeaturetiers_spec.lua's own
    -- "a loadfile typo silently produces an empty table" guard.
    t.isTrue(totalFeatures >= 56, ('sanity: only saw %d Config.Features key(s); config.lua may not have loaded correctly for this spec'):format(totalFeatures))

    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configEnv.Config.Features, registryText)
    if #unrecognized > 0 then
        error(('%d real Config.Features key(s) were not found anywhere in server/runtimecontrol.lua, and would be warned about at real boot: %s'):format(#unrecognized, table.concat(unrecognized, ', ')), 0)
    end
end)

-- ----------------------------------------------------------------------
-- BuildBootSummaryLine -- one line, real information, never fabricated
-- ----------------------------------------------------------------------

t.test('BuildBootSummaryLine: a healthy boot produces exactly one line with real counts', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        version = '0.1.0',
        deps = { total = 5, ok = 5, unverified = 0, problems = 0 },
        features = { total = 58, unrecognized = 0 },
        databaseState = 'connected (no whole-resource schema collision detected)',
    })
    t.notContains(line, '\n', 'must be exactly one line, never a banner')
    t.contains(line, '0.1.0')
    t.contains(line, '5/5')
    t.contains(line, '58/58')
    t.contains(line, 'connected')
end)

t.test('BuildBootSummaryLine: never fabricates a state it was not given -- missing deps/features report "not checked", not a made-up number', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        version = nil,
        deps = nil,
        features = nil,
        databaseState = 'unknown (server/datastore.lua not loaded)',
    })
    t.contains(line, 'version unknown')
    t.contains(line, 'dependencies: not checked')
    t.contains(line, 'Config.Features: not checked')
    t.notContains(line, '\n')
end)

t.test('BuildBootSummaryLine: a boot with warnings still reports honest counts on the same one line', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        version = '0.1.0',
        deps = { total = 5, ok = 4, unverified = 0, problems = 1 },
        features = { total = 58, unrecognized = 2 },
        databaseState = 'memory-only (see any warning above from server/datastore.lua for why)',
    })
    t.notContains(line, '\n')
    t.contains(line, '4/5')
    t.contains(line, '56/58')
end)

-- ----------------------------------------------------------------------
-- FULL BOOT WIRING -- loads the REAL server/selfcheck.lua with every
-- native it touches stubbed, fires the real 'onResourceStart' handler it
-- registers, and asserts on what it actually prints. Same shape as
-- tests/runtimefeaturetiers_spec.lua's own boot() helper.
-- ----------------------------------------------------------------------

--- @param overrides table { resourceStates, resourceVersions, resourceFiles, config, k9Store }
local function boot(overrides)
    overrides = overrides or {}
    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local resourceStates = overrides.resourceStates or {}
    local resourceVersions = overrides.resourceVersions or {}
    local resourceFiles = overrides.resourceFiles or {}

    local env = Sandbox.newEnv({
        AddEventHandler = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        GetResourceState = function(name) return resourceStates[name] or 'started' end,
        GetResourceMetadata = function(name, key, _index)
            if key ~= 'version' then return nil end
            return resourceVersions[name]
        end,
        LoadResourceFile = function(_name, path) return resourceFiles[path] end,
        print = printStub,
        Config = overrides.config or { Features = {} },
        K9Store = overrides.k9Store,
    })

    Sandbox.loadInto('../server/selfcheck.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    return { env = env, printedLines = printedLines }
end

local ALL_OK_VERSIONS = {
    qbx_core = '1.24.0', ox_lib = '3.39.0', ox_target = '1.18.1',
    oxmysql = '2.14.1', ox_inventory = '2.47.9',
}
local REGISTRY_WITH_ALL_58_KEYS_STUB = "-- fabricated for this spec only\nRadialMenu = { tier = 'onstart' },"

t.test('END-TO-END: a below-minimum ox_lib prints a named, loud warning at real boot', function()
    local versions = {}
    for k, v in pairs(ALL_OK_VERSIONS) do versions[k] = v end
    versions.ox_lib = '3.4.0' -- the string-comparison trap version, below the real 3.39.0 minimum

    local f = boot({
        resourceVersions = versions,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true } },
    })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) and line:find('ox_lib', 1, true) and line:find('3.4.0', 1, true) and line:find('3.39.0', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'expected a loud warning naming ox_lib, 3.4.0, and 3.39.0')
end)

t.test('END-TO-END: every dependency at/above minimum prints NO per-dependency warning at all', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true } },
    })
    for _, line in ipairs(f.printedLines) do
        t.notContains(line, '!!', 'no dependency warning expected when every real dependency is at/above its minimum: ' .. line)
    end
end)

t.test('END-TO-END: an unrecognized Config.Features key prints a named warning at real boot', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true, ScentTraking = false } },
    })
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) and line:find('ScentTraking', 1, true) then warned = true end
    end
    t.isTrue(warned, 'expected a named warning for the unrecognized key ScentTraking')
end)

t.test('END-TO-END: the final line is a single, informative summary printed last, after any warnings', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true, ScentTraking = false } },
        k9Store = { IsDatabaseEnabled = function() return false end },
    })
    t.isTrue(#f.printedLines > 0)
    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'boot summary')
    t.contains(lastLine, 'memory-only')
    t.notContains(lastLine, '\n')
end)

t.test('END-TO-END: a healthy boot (no dependency or config problems) still prints the one summary line, proving the check ran even when there is nothing to warn about', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true } },
        k9Store = {
            IsDatabaseEnabled = function() return true end,
            WaitForSchemaCheckToSettle = function() return true end,
        },
    })
    local sawBangBang = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) then sawBangBang = true end
    end
    t.isFalse(sawBangBang, 'a fully healthy boot must print no loud warnings at all')

    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'boot summary')
    t.contains(lastLine, '5/5')
    t.contains(lastLine, '1/1')
    t.contains(lastLine, 'connected')
end)

t.test('SAFETY: with no FiveM natives available at all (plain Lua), loading the real file registers nothing and errors nothing', function()
    local env = Sandbox.newEnv({})
    -- No AddEventHandler, no GetResourceState/GetResourceMetadata/LoadResourceFile,
    -- no Config, no K9Store -- the exact shape of a plain lua5.4 process.
    Sandbox.loadInto('../server/selfcheck.lua', env)
    t.isNotNil(env.K9SelfCheck)
end)

os.exit(t.summary())
