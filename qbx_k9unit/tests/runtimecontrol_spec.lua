--[[
    tests/runtimecontrol_spec.lua

    Tests server/runtimecontrol.lua -- runtime feature control + tablet
    theming -- against the REAL, unmodified production file, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/highcommand_spec.lua/
    tests/permissions_spec.lua: a fake in-memory table backing every SQL
    statement this file issues (k9_runtime_feature_overrides,
    k9_runtime_override_audit, k9_tablet_theme, k9_tablet_theme_audit),
    mutated by the real production callbacks exactly like a real database
    would be.

    TWO BOOTS, ONE FAKE DATABASE: `newWorld()` builds the shared fake tables
    (survive across "restarts" -- they are plain upvalues captured by the
    MySQL stub closure, not reset between boots). `boot(world, opts)` loads
    a FRESH copy of server/cooldowns.lua + server/runtimecontrol.lua into a
    brand-new sandbox env (fresh CONFIG_LUA_DEFAULT_FEATURES/_TUNABLES
    captures, exactly like a real resource restart) pointed at the SAME
    fake tables, and fires 'onResourceStart' once. This is what makes the
    "an override survives a restart" tests possible: `boot()` twice against
    the same `world`, asserting the second boot's live Config values already
    reflect what the first boot's callbacks wrote to the fake DB.

    THE LOAD-BEARING TESTS this task named explicitly, and where each lives:
      - "a runtime OFF toggle is actually honoured by the handler"
        -> Section 2 (tier='live'; asserts the mutation lands in the exact
           shared `Config.Features` table object every real feature file
           reads, AND drives a hand-written stand-in handler using the
           SAME `if not Config.Features.X then return end` shape every
           real 'live'-tier file in this resource actually uses -- see
           server/runtimecontrol.lua's own header "THE FULL AUDIT" for the
           direct-code-read evidence backing each tier classification;
           re-deriving that evidence here would just be a second, driftable
           copy of it).
      - "an ON toggle for a load-gated feature reports restart required
        rather than lying" -> Section 3 (tier='onstart' and tier='rawtoplevel',
        including the extra `configEditRequired` distinction for the
        latter).
      - "a non-positive tuning value is refused" -> Section 5.
      - "a theme value that is not a valid colour is refused" -> Section 7.
      - "non-high-command callers are denied" -> Section 4 (features/tuning)
        and Section 7 (theme mutation) -- GetTheme itself is deliberately
        NOT covered here as a denial case; it is documented, and tested, as
        open to anyone (Section 6).

    locale() is never called by server/runtimecontrol.lua (see that file's
    own header "LOCALE KEYS THIS FILE NEEDS: none") -- so, unlike several
    sibling specs, nothing here is gated on any locale key landing.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Builds one shared fake-database world: four in-memory tables backing
--- every SQL statement server/runtimecontrol.lua issues. Survives across
--- multiple boot() calls against it, exactly like a real database survives
--- a resource restart.
--- @return table world
local function newWorld()
    return {
        overrides = {},      -- override_key -> { kind, value, updated_by, updated_at }
        overrideAudit = {},  -- array of { override_key, kind, old_value, new_value, changed_by }
        theme = nil,         -- nil | { primary_color, accent_color, background_color, text_color, density, header_title }
        themeAudit = {},     -- array of full-snapshot rows
    }
end

--- @param world table
--- @return fun(sql: string, params: table): table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT override_key, kind, value, updated_by, updated_at FROM k9_runtime_feature_overrides', 1, true) then
            local out = {}
            for key, row in pairs(world.overrides) do
                out[#out + 1] = { override_key = key, kind = row.kind, value = row.value, updated_by = row.updated_by, updated_at = row.updated_at }
            end
            return out
        elseif sql:find('INSERT INTO k9_runtime_feature_overrides', 1, true) then
            local key, kind, value, updatedBy = params[1], params[2], params[3], params[4]
            world.overrides[key] = { kind = kind, value = value, updated_by = updatedBy, updated_at = '2026-01-01 00:00:00' }
            return {}
        elseif sql:find('DELETE FROM k9_runtime_feature_overrides', 1, true) then
            world.overrides[params[1]] = nil
            return {}
        elseif sql:find('INSERT INTO k9_runtime_override_audit', 1, true) then
            -- Two shapes, matching production exactly: SetFeature/SetTunable
            -- bind new_value as a 5th `?` (params has 5 entries); Reset*
            -- hardcodes `NULL` as literal SQL text for new_value (params
            -- has only 4 entries -- old_value, then changed_by) -- see
            -- server/runtimecontrol.lua's own two INSERT statements.
            if sql:find('VALUES (?, ?, ?, NULL, ?)', 1, true) then
                world.overrideAudit[#world.overrideAudit + 1] = {
                    override_key = params[1], kind = params[2], old_value = params[3], new_value = nil, changed_by = params[4],
                }
            else
                world.overrideAudit[#world.overrideAudit + 1] = {
                    override_key = params[1], kind = params[2], old_value = params[3], new_value = params[4], changed_by = params[5],
                }
            end
            return {}
        elseif sql:find('INSERT INTO k9_tablet_theme_audit', 1, true) then
            world.themeAudit[#world.themeAudit + 1] = {
                primary_color = params[1], accent_color = params[2], background_color = params[3],
                text_color = params[4], density = params[5], header_title = params[6], changed_by = params[7],
            }
            return {}
        elseif sql:find('SELECT primary_color, accent_color, background_color, text_color, density, header_title FROM k9_tablet_theme', 1, true) then
            if world.theme then return { world.theme } end
            return {}
        elseif sql:find('INSERT INTO k9_tablet_theme (', 1, true) then
            world.theme = {
                primary_color = params[1], accent_color = params[2], background_color = params[3],
                text_color = params[4], density = params[5], header_title = params[6],
            }
            return {}
        end
        error('runtimecontrol_spec test stub: unhandled SQL: ' .. tostring(sql))
    end
end

--- @param opts table? -- { world: table (default: fresh), config: table (Config overrides), isHighCommand: fun(source):boolean, hasPermission: fun(citizenid, key):boolean, printCapture: table? (appended to) }
--- @return table fixture -- { env, world, callbacks, printedLines, broadcasts, playersBySource }
local function boot(opts)
    opts = opts or {}
    local world = opts.world or newWorld()

    local printedLines = opts.printCapture or {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local broadcasts = {}
    local function TriggerClientEventStub(eventName, target, payload)
        broadcasts[#broadcasts + 1] = { eventName = eventName, target = target, payload = payload }
    end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local playersBySource = opts.playersBySource or {}
    local exportsStub = { qbx_core = { GetPlayer = function(_self, src) return playersBySource[src] end } }

    local isHighCommand = opts.isHighCommand or function() return false end
    local hasPermission = opts.hasPermission -- nil unless a test wants the permission-grant escape hatch

    local defaultConfig = {
        Features = {
            RuntimeFeatureControl = true,
            TabletTheming = true,
            XPProgression = true,
            BasicBarkSounds = true,
            DoorInteraction = true,
            FetchMechanic = false,
            HandlerDownDefense = false,
            AdminAuditCommands = false,
            HighCommand = true,
            PermissionGrants = true,
        },
        Tracking = {
            Scent     = { searchCooldownMs = 5000, relayCooldownMs = 1000, maxRange = 40.0, maxAgeSeconds = 900 },
            Blood     = { searchCooldownMs = 5000, relayCooldownMs = 500,  maxRange = 40.0, maxAgeSeconds = 300 },
            Gunpowder = { searchCooldownMs = 5000, relayCooldownMs = 300,  maxRange = 40.0, maxAgeSeconds = 120 },
        },
        AdminAudit = {
            CommandCooldownMs = 3000,
            MaxResults = { Certifications = 25, Partnerships = 25, SearchLog = 25 },
        },
        LeashMaxDistance = 8.0,
        CertifyProximityMeters = 5.0,
        VehicleInteractMeters = 3.0,
        CertificationExpiryCheckIntervalMs = 300000,
    }
    local config = opts.config or defaultConfig

    local fakeNow = { value = 0 }
    local env = Sandbox.newEnv({
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = TriggerClientEventStub,
        exports                = exportsStub,
        MySQL                  = { query = { await = makeQueryAwait(world) } },
        IsHighCommand          = isHighCommand,
        HasPermission          = hasPermission,
        Config                 = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)

    -- server/datastore.lua -- REAL, unmodified, loaded alongside (this
    -- file's own header: "the ONLY place in this resource that may name a
    -- `k9_*` table or call `MySQL.*` directly" -- server/runtimecontrol.lua's
    -- own SafeQuery/SafeWrite helpers are gone; every read/write below now
    -- goes through K9Store.Override_*/OverrideAudit_Append/Theme_*/
    -- ThemeAudit_Append). Config.Database is deliberately absent from this
    -- fixture's `config`/`defaultConfig` tables above -- K9Store's own
    -- DatabaseEnabled() fails safe to `true` (real-DB mode) on a missing
    -- Config.Database, which is exactly what makes every K9Store call below
    -- run the SAME MySQL.query.await call (against this file's own
    -- makeQueryAwait(world) stub, assigned as env.MySQL above) that this
    -- file's local SafeQuery/SafeWrite used to run directly, so every
    -- existing assertion below keeps exercising the identical SQL/params
    -- shape this fixture was written against. ONE INTENTIONAL EXCEPTION:
    -- K9Store.OverrideAudit_Append always binds `new_value` as a 5th `?`
    -- (nil for a reset), rather than this file's old two-shape SQL text
    -- (a literal `NULL` in the reset-path INSERT with only 4 bound params)
    -- -- functionally identical (both bind SQL NULL), and makeQueryAwait's
    -- own INSERT INTO k9_runtime_override_audit branch already reads
    -- params[4]/params[5] by direct index rather than by table length, so
    -- it classifies a reset row (new_value = nil) correctly either way
    -- without needing a fixture change of its own.
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    return {
        env = env, world = world, callbacks = callbacks, printedLines = printedLines,
        broadcasts = broadcasts, playersBySource = playersBySource, fakeNow = fakeNow,
    }
end

--- @param fixture table
--- @param source number
--- @param citizenid string
local function registerPlayer(fixture, source, citizenid)
    fixture.playersBySource[source] = { PlayerData = { citizenid = citizenid } }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

-- ============================================================================
-- SECTION 1 -- registration surface: every callback this file promises
-- exists, unconditionally (self-hosting design -- see header "SELF-HOSTING").
-- ============================================================================

t.test('registration: all seven callbacks are registered even when RuntimeFeatureControl/TabletTheming are both false at boot', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = false, TabletTheming = false, HighCommand = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    for _, name in ipairs({
        'qbx_k9unit:server:runtimeListFeatures', 'qbx_k9unit:server:runtimeSetFeature', 'qbx_k9unit:server:runtimeResetFeature',
        'qbx_k9unit:server:runtimeListTunables', 'qbx_k9unit:server:runtimeSetTunable', 'qbx_k9unit:server:runtimeResetTunable',
        'qbx_k9unit:server:tabletGetTheme', 'qbx_k9unit:server:tabletSetTheme', 'qbx_k9unit:server:tabletResetTheme',
    }) do
        t.isNotNil(f.callbacks[name], name .. ' must always be registered')
    end
end)

-- ============================================================================
-- SECTION 2 -- LOAD-BEARING: a runtime OFF toggle is actually honoured.
-- ============================================================================

t.test('LOAD-BEARING: SetFeature(false) on a tier=live feature mutates the SAME Config.Features table every real feature file reads, live, no restart', function()
    local f = boot()
    registerPlayer(f, HC_SOURCE, 'HC1')
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end

    t.isTrue(f.env.Config.Features.BasicBarkSounds, 'sanity: starts on')

    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive, 'tier=live must apply live')
    t.isFalse(result.restartRequired)

    -- The mutation is observable on the EXACT table object every real
    -- feature file's own `if not Config.Features.BasicBarkSounds then
    -- return end` check reads -- env.Config IS that table (Sandbox.newEnv
    -- injects it as the global `Config` every loaded file shares).
    t.isFalse(f.env.Config.Features.BasicBarkSounds)

    -- Stand-in for a real live-tier handler, using the EXACT shape
    -- server/main.lua's real relayBark handler uses (confirmed by direct
    -- read -- see server/runtimecontrol.lua's own header "THE FULL AUDIT"):
    -- `if not Config.Features.BasicBarkSounds then return end`, evaluated
    -- FRESH on every simulated "request", against the SAME Config table
    -- this test's own SetFeature call above already mutated.
    local barkHandlerCallCount = 0
    local function standInBarkHandler()
        if not f.env.Config.Features.BasicBarkSounds then return end
        barkHandlerCallCount = barkHandlerCallCount + 1
    end
    standInBarkHandler()
    t.equals(barkHandlerCallCount, 0, 'the OFF toggle must be honoured by a handler reading the live flag -- it must NOT fire')

    -- And turning it back on works immediately too, tier=live in both
    -- directions -- fakeNow advanced past RUNTIME_CONTROL_ACTION_COOLDOWN_MS
    -- so this is a genuinely SEPARATE action, not itself proof of the
    -- rate limiter (that is Section 9's own job).
    f.fakeNow.value = f.fakeNow.value + 2000
    local onResult = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', true)
    t.isTrue(onResult.ok)
    t.isTrue(onResult.appliedLive)
    t.isFalse(onResult.restartRequired)
    standInBarkHandler()
    t.equals(barkHandlerCallCount, 1, 'turning it back on must be honoured immediately too')
end)

t.test('tier=live: DoorInteraction OFF is honoured the same way (a second, independent live-tier feature)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive)
    t.isFalse(f.env.Config.Features.DoorInteraction)
end)

-- ============================================================================
-- SECTION 3 -- LOAD-BEARING: an ON toggle for a load-gated feature reports
-- restart required rather than lying, with the extra configEditRequired
-- distinction for a raw-top-level gate.
-- ============================================================================

t.test('LOAD-BEARING: SetFeature(true) on a tier=onstart feature (AdminAuditCommands, off at boot) reports restartRequired, never claims it is already live', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    t.isFalse(f.env.Config.Features.AdminAuditCommands, 'sanity: off at boot')

    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'AdminAuditCommands', true)
    t.isTrue(result.ok, 'the override itself is still saved')
    t.isFalse(result.appliedLive, 'must not claim this is live now')
    t.isTrue(result.restartRequired)
    t.isNil(result.configEditRequired, 'onstart tier needs a restart, not a config.lua edit')
    t.equals(result.tier, 'onstart')

    -- The Config value itself DOES flip (for the NEXT restart's benefit,
    -- and for consistency), but that must never be confused with "already
    -- working this session" -- the response above is what the tablet must
    -- render, and it does not claim success in the live sense.
    t.isTrue(f.env.Config.Features.AdminAuditCommands)
end)

t.test('LOAD-BEARING: SetFeature(true) on a tier=rawtoplevel feature (FetchMechanic, off at boot) reports BOTH restartRequired AND configEditRequired', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    t.isFalse(f.env.Config.Features.FetchMechanic, 'sanity: off at boot')

    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'FetchMechanic', true)
    t.isTrue(result.ok)
    t.isFalse(result.appliedLive)
    t.isTrue(result.restartRequired)
    t.isTrue(result.configEditRequired, 'a restart of THIS resource alone is not sufficient for a rawtoplevel-tier feature -- config.lua itself must change')
    t.equals(result.tier, 'rawtoplevel')
end)

t.test('a tier=rawtoplevel feature reports restartRequired+configEditRequired for OFF too (Recall, on by default -- the termination-path case)', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, TabletTheming = true, HighCommand = true, Recall = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'Recall', false)
    t.isTrue(result.ok)
    t.isFalse(result.appliedLive, 'Recall genuinely does not stop once registered -- OFF must not be reported as live either')
    t.isTrue(result.configEditRequired)
end)

t.test('LOAD-BEARING: ResetFeature on a tier=onstart feature reports restartRequired, matching SetFeature\'s own tier-awareness (regression test for the reset/set asymmetry this pass fixed)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    -- AdminAuditCommands starts `false` in this fixture's defaultConfig --
    -- SetFeature(true) first so there is a real override in place for
    -- ResetFeature to actually remove (Config.Features.AdminAuditCommands
    -- flips true -> false again on reset, back to the config.lua default).
    f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'AdminAuditCommands', true)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['qbx_k9unit:server:runtimeResetFeature'](HC_SOURCE, 'AdminAuditCommands')
    t.isTrue(result.ok)
    t.equals(result.value, false, 'restored to the config.lua default (false)')
    t.isFalse(result.appliedLive, 'an onstart-tier feature does not re-check its flag after registration -- a reset must not claim this is live now, exactly like SetFeature does not')
    t.isTrue(result.restartRequired, 'BUG THIS PASS FIXED: this used to unconditionally report restartRequired = false regardless of tier')
    t.isNil(result.configEditRequired, 'onstart tier needs a restart, not a config.lua edit')
    t.equals(result.tier, 'onstart')
end)

t.test('LOAD-BEARING: ResetFeature on a tier=rawtoplevel feature reports BOTH restartRequired AND configEditRequired, matching SetFeature', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    -- FetchMechanic starts `false` in this fixture -- flip it on via
    -- SetFeature first so there is an override to reset away.
    f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'FetchMechanic', true)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['qbx_k9unit:server:runtimeResetFeature'](HC_SOURCE, 'FetchMechanic')
    t.isTrue(result.ok)
    t.equals(result.value, false)
    t.isFalse(result.appliedLive)
    t.isTrue(result.restartRequired, 'BUG THIS PASS FIXED: rawtoplevel reset used to falsely report restartRequired = false')
    t.isTrue(result.configEditRequired, 'a restart of THIS resource alone is not sufficient for a rawtoplevel-tier feature, on reset exactly as on set')
    t.equals(result.tier, 'rawtoplevel')
end)

t.test('ResetFeature on a tier=live feature still reports restartRequired = false (the fix must not regress the already-correct live case)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['qbx_k9unit:server:runtimeResetFeature'](HC_SOURCE, 'BasicBarkSounds')
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive)
    t.isFalse(result.restartRequired)
    t.equals(result.tier, 'live')
end)

t.test('protected features (HighCommand, PermissionGrants) refuse SetFeature outright, regardless of caller', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local r1 = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'HighCommand', false)
    t.isFalse(r1.ok)
    t.equals(r1.reason, 'protected_feature')
    t.isTrue(f.env.Config.Features.HighCommand, 'must be completely unchanged')

    f.fakeNow.value = f.fakeNow.value + 2000
    local r2 = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'PermissionGrants', false)
    t.isFalse(r2.ok)
    t.equals(r2.reason, 'protected_feature')
end)

t.test('LOAD-BEARING: SetFeature refuses tier=unaudited outright (the fail-closed net for a feature nobody has classified yet), with a named console warning', function()
    -- A Config.Features key that exists ONLY in this test's fixture config,
    -- never in the real FEATURE_TIERS table server/runtimecontrol.lua ships
    -- with -- genuinely 'unaudited' from that real, unmodified production
    -- file's own point of view, exactly the shape of the bug this refusal
    -- exists to close (see server/runtimecontrol.lua's header "UPDATED
    -- 2026-08-26" / "FEATURE REGISTRY").
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, HighCommand = true, TabletTheming = false, SomeBrandNewFeatureNobodyClassifiedYet = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    f.env.IsHighCommand = function() return true end

    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'SomeBrandNewFeatureNobodyClassifiedYet', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'unaudited_feature')
    t.isTrue(f.env.Config.Features.SomeBrandNewFeatureNobodyClassifiedYet, 'must be completely unchanged, exactly like a protected-feature refusal')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('SomeBrandNewFeatureNobodyClassifiedYet', 1, true) then warned = true end
    end
    t.isTrue(warned, 'the refusal must print a loud, named warning identifying the exact feature -- a silent denial here would reproduce the exact bug this check exists to close')
end)

t.test('a Config.Features key with no FEATURE_TIERS entry is loudly warned about at BOOT TIME too, not only when someone tries to toggle it', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, HighCommand = true, AnotherUnclassifiedOne = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('AnotherUnclassifiedOne', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an unclassified Config.Features key must be visible on every boot, not only discovered later via a failed toggle attempt')
end)

t.test('tier=clientonly still applies via SetFeature (never refused) -- only protected/unaudited are refused, clientonly is a KNOWN, classified tier', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, HighCommand = true, RadialMenu = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    f.env.IsHighCommand = function() return true end

    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'RadialMenu', false)
    t.isTrue(result.ok)
    t.isFalse(result.appliedLive)
    t.isTrue(result.restartRequired)
    t.equals(result.tier, 'clientonly')
    t.isFalse(f.env.Config.Features.RadialMenu)
end)

t.test('an unrecognized feature name is rejected as invalid_feature, never silently accepted', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'ThisFeatureDoesNotExist', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_feature')
end)

t.test('feature_disabled: SetFeature refuses when Config.Features.RuntimeFeatureControl is false, even for real high command', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.env.Config.Features.RuntimeFeatureControl = false
    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'feature_disabled')
    t.isTrue(f.env.Config.Features.BasicBarkSounds, 'nothing must have changed')
end)

-- ============================================================================
-- SECTION 4 -- LOAD-BEARING: non-high-command callers are denied, for
-- every mutating callback, and for the two list callbacks.
-- ============================================================================

t.test('LOAD-BEARING: every mutating callback denies a non-high-command, non-permission-holding caller', function()
    local f = boot()
    registerPlayer(f, NON_HC_SOURCE, 'PLEB1')
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end -- NON_HC_SOURCE never qualifies

    local r1 = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](NON_HC_SOURCE, 'BasicBarkSounds', false)
    t.isFalse(r1.ok); t.equals(r1.reason, 'denied')
    t.isTrue(f.env.Config.Features.BasicBarkSounds, 'must not have changed')

    local r2 = f.callbacks['qbx_k9unit:server:runtimeResetFeature'](NON_HC_SOURCE, 'BasicBarkSounds')
    t.isFalse(r2.ok); t.equals(r2.reason, 'denied')

    local r3 = f.callbacks['qbx_k9unit:server:runtimeListFeatures'](NON_HC_SOURCE)
    t.isFalse(r3.ok); t.equals(r3.reason, 'denied')

    local r4 = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](NON_HC_SOURCE, 'LeashMaxDistance', 10.0)
    t.isFalse(r4.ok); t.equals(r4.reason, 'denied')

    local r5 = f.callbacks['qbx_k9unit:server:runtimeResetTunable'](NON_HC_SOURCE, 'LeashMaxDistance')
    t.isFalse(r5.ok); t.equals(r5.reason, 'denied')

    local r6 = f.callbacks['qbx_k9unit:server:runtimeListTunables'](NON_HC_SOURCE)
    t.isFalse(r6.ok); t.equals(r6.reason, 'denied')
end)

t.test('the k9.runtimecontrol permission grant, once HasPermission says yes, is an alternate authorized path (forward-compatible escape hatch)', function()
    local f = boot({ hasPermission = function(citizenid, key) return citizenid == 'GRANTED1' and key == 'k9.runtimecontrol' end })
    registerPlayer(f, NON_HC_SOURCE, 'GRANTED1')
    f.env.IsHighCommand = function() return false end -- not high command at all

    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](NON_HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(result.ok, 'a citizenid holding the k9.runtimecontrol grant must be authorized even without high command')
end)

-- ============================================================================
-- SECTION 5 -- LOAD-BEARING: a non-positive tuning value is refused.
-- ============================================================================

t.test('LOAD-BEARING: a zero tuning value is refused (the cooldowns.lua footgun this file exists to prevent from ever reaching a cooldown tracker)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', 0)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
    t.equals(result.min, 100)
    t.equals(f.env.Config.Tracking.Blood.relayCooldownMs, 500, 'must be completely unchanged')
end)

t.test('a negative tuning value is refused', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', -500)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
end)

t.test('a NaN tuning value is refused, does not throw', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local ok, result = pcall(f.callbacks['qbx_k9unit:server:runtimeSetTunable'], HC_SOURCE, 'Tracking.Blood.relayCooldownMs', 0 / 0)
    t.isTrue(ok, 'must not raise on NaN')
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
end)

t.test('an infinite tuning value is refused', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', math.huge)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
end)

t.test('a value above the registry max is refused, told the exact max back', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', 999999)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
    t.equals(result.max, 10000)
end)

t.test('a fractional value for an integer-kind tunable is refused', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'AdminAudit.MaxResults.Certifications', 10.5)
    t.isFalse(result.ok)
    t.equals(result.reason, 'not_integer')
end)

t.test('a value inside range is accepted and applied live, and reads back via ListTunables', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 12.5)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive)
    t.equals(f.env.Config.LeashMaxDistance, 12.5)

    local listed = f.callbacks['qbx_k9unit:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    local found
    for _, row in ipairs(listed.tunables) do
        if row.key == 'LeashMaxDistance' then found = row end
    end
    t.isNotNil(found)
    t.equals(found.currentValue, 12.5)
    t.equals(found.configLuaDefault, 8.0)
    t.isTrue(found.overridden)
end)

t.test('an unrecognized tunable key is rejected as invalid_key', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Config.XP.awards.searchContrabandFound', 999999)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key')
end)

t.test('resetting a tunable restores the config.lua default and removes the override', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 12.5)
    t.equals(f.env.Config.LeashMaxDistance, 12.5)

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['qbx_k9unit:server:runtimeResetTunable'](HC_SOURCE, 'LeashMaxDistance')
    t.isTrue(result.ok)
    t.equals(result.value, 8.0)
    t.equals(f.env.Config.LeashMaxDistance, 8.0)
    t.isNil(f.world.overrides['tuning:LeashMaxDistance'], 'the override row must be gone, not merely re-set to the default value')
end)

-- ============================================================================
-- SECTION 6 -- theme GET is open to anyone (no authorization check).
-- ============================================================================

t.test('GetTheme requires no authorization at all -- any connected source gets the current theme', function()
    local f = boot()
    f.env.IsHighCommand = function() return false end
    local result = f.callbacks['qbx_k9unit:server:tabletGetTheme'](NON_HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(result.theme.primaryColor, '#2563eb')
    t.equals(result.theme.headerTitle, 'K9 Command Tablet')
end)

t.test('GetTheme rejects an invalid source defensively (never a table lookup on garbage)', function()
    local f = boot()
    local result = f.callbacks['qbx_k9unit:server:tabletGetTheme']('not-a-source')
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_source')
end)

-- ============================================================================
-- SECTION 7 -- LOAD-BEARING: a theme value that is not a valid colour is
-- refused, plus the denial/feature-disabled/XSS-shaped-string cases.
-- ============================================================================

t.test('LOAD-BEARING: SetTheme refuses a non-colour primaryColor', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { primaryColor = 'not-a-color' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_field')
    t.equals(result.field, 'primaryColor')
    t.equals(f.env.Config, f.env.Config, 'sanity')
end)

t.test('SetTheme refuses a 3-digit shorthand hex colour (strict #RRGGBB only)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { accentColor = '#fff' })
    t.isFalse(result.ok)
    t.equals(result.field, 'accentColor')
end)

t.test('SetTheme refuses an unrecognized density value (fixed enum, never free text)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { density = 'ultra-wide' })
    t.isFalse(result.ok)
    t.equals(result.field, 'density')
end)

t.test('SetTheme refuses a headerTitle containing HTML-special characters, never lets it reach the DOM as markup', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { headerTitle = '<img src=x onerror=alert(1)>' })
    t.isFalse(result.ok)
    t.equals(result.field, 'headerTitle')
end)

t.test('SetTheme refuses a headerTitle over 40 characters', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { headerTitle = ('x'):rep(41) })
    t.isFalse(result.ok)
    t.equals(result.field, 'headerTitle')
end)

t.test('SetTheme accepts a valid partial update, merges onto the current theme (does not blank untouched fields), persists, broadcasts', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'HC1')

    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { headerTitle = 'Bark Squad HQ', density = 'compact' })
    t.isTrue(result.ok)
    t.equals(result.theme.headerTitle, 'Bark Squad HQ')
    t.equals(result.theme.density, 'compact')
    t.equals(result.theme.primaryColor, '#2563eb', 'untouched fields must survive a partial update unchanged')

    local getResult = f.callbacks['qbx_k9unit:server:tabletGetTheme'](NON_HC_SOURCE)
    t.equals(getResult.theme.headerTitle, 'Bark Squad HQ', 'GetTheme must reflect the just-applied change immediately')

    t.equals(#f.broadcasts, 1)
    t.equals(f.broadcasts[1].eventName, 'qbx_k9unit:client:themeUpdated')
    t.equals(f.broadcasts[1].target, -1, 'must broadcast to every client, not one target')
    t.equals(f.broadcasts[1].payload.headerTitle, 'Bark Squad HQ')

    t.equals(#f.world.themeAudit, 1, 'the change must be recorded in the append-only audit table')
    t.equals(f.world.themeAudit[1].changed_by, 'HC1')
end)

t.test('SetTheme denies a non-high-command caller', function()
    local f = boot()
    f.env.IsHighCommand = function() return false end
    local result = f.callbacks['qbx_k9unit:server:tabletSetTheme'](NON_HC_SOURCE, { density = 'compact' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('SetTheme/ResetTheme refuse when Config.Features.TabletTheming is false', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.env.Config.Features.TabletTheming = false
    local r1 = f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { density = 'compact' })
    t.isFalse(r1.ok); t.equals(r1.reason, 'feature_disabled')
    local r2 = f.callbacks['qbx_k9unit:server:tabletResetTheme'](HC_SOURCE)
    t.isFalse(r2.ok); t.equals(r2.reason, 'feature_disabled')
end)

t.test('ResetTheme restores every field to the built-in default and broadcasts', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.callbacks['qbx_k9unit:server:tabletSetTheme'](HC_SOURCE, { density = 'compact', headerTitle = 'Changed' })

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['qbx_k9unit:server:tabletResetTheme'](HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(result.theme.density, 'comfortable')
    t.equals(result.theme.headerTitle, 'K9 Command Tablet')
    t.equals(#f.broadcasts, 2, 'both the set and the reset must each broadcast once')
end)

-- ============================================================================
-- SECTION 8 -- persistence across a restart, and the audit trail.
-- ============================================================================

t.test('PERSISTENCE: a feature override survives a fresh boot against the same database', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end
    first.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isFalse(first.env.Config.Features.BasicBarkSounds)

    -- Simulate a full resource restart: a BRAND NEW sandbox env, a BRAND
    -- NEW CONFIG_LUA_DEFAULT_FEATURES capture (config.lua's own shipped
    -- default, BasicBarkSounds = true, exactly like the fresh `defaultConfig`
    -- table boot() builds), against the SAME fake database.
    local second = boot({ world = world })
    t.isFalse(second.env.Config.Features.BasicBarkSounds, 'the override must be re-applied on this fresh boot, before any player ever connects -- a restart must not silently revert it')
end)

t.test('PERSISTENCE: a tuning override survives a fresh boot, and a stale/out-of-range override is skipped with a warning rather than applied blindly', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end
    first.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 15.0)

    -- Manually corrupt the persisted value to something now out of range,
    -- exactly as if a registry bound were tightened between two versions
    -- of this file, or the DB were hand-edited.
    world.overrides['tuning:LeashMaxDistance'].value = '999999'

    local second = boot({ world = world })
    t.equals(second.env.Config.LeashMaxDistance, 8.0, 'an out-of-range persisted value must NEVER be blindly re-applied -- falls back to the config.lua default instead')
    local warned = false
    for _, line in ipairs(second.printedLines) do
        if line:find('skipped stale/unrecognized override', 1, true) then warned = true end
    end
    t.isTrue(warned, 'the skip must be logged, not silent')
end)

t.test('AUDIT: SetFeature/ResetFeature/SetTunable/ResetTunable each append one row naming who changed what, from what, to what', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'AUDITOR1')

    f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:runtimeResetFeature'](HC_SOURCE, 'BasicBarkSounds')
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 10.0)
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:runtimeResetTunable'](HC_SOURCE, 'LeashMaxDistance')

    t.equals(#f.world.overrideAudit, 4)

    local setRow = f.world.overrideAudit[1]
    t.equals(setRow.override_key, 'feature:BasicBarkSounds')
    t.equals(setRow.old_value, 'true')
    t.equals(setRow.new_value, 'false')
    t.equals(setRow.changed_by, 'AUDITOR1')

    local resetRow = f.world.overrideAudit[2]
    t.equals(resetRow.override_key, 'feature:BasicBarkSounds')
    t.equals(resetRow.old_value, 'false')
    t.isNil(resetRow.new_value, 'new_value NULL means "reset to the config.lua default" per the migration\'s own documented convention')
end)

t.test('the console AUDIT print line names the acting citizenid, the action, and the outcome', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'PRINTAUDIT1')
    f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)

    local auditLine
    for _, line in ipairs(f.printedLines) do
        if line:find('AUDIT:', 1, true) and line:find('runtimeSetFeature', 1, true) then auditLine = line end
    end
    t.isNotNil(auditLine)
    t.contains(auditLine, 'citizenid=PRINTAUDIT1')
    t.contains(auditLine, '-> ok')
end)

-- ============================================================================
-- SECTION 9 -- rate limiting (anti-fat-finger, per this file's own header).
-- ============================================================================

t.test('rate limiting: a second mutating call from the same officer inside the cooldown window is rejected, recovers once elapsed', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    f.fakeNow.value = 0
    local r1 = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(r1.ok)

    f.fakeNow.value = 100 -- inside the 1000ms window
    local r2 = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    t.isFalse(r2.ok)
    t.equals(r2.reason, 'rate_limited')
    t.isTrue(f.env.Config.Features.DoorInteraction, 'the rate-limited call must not have applied anything')

    f.fakeNow.value = 1500 -- past the window
    local r3 = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    t.isTrue(r3.ok)
end)

t.test('rate limiting is per-OFFICER, not global -- a different officer is unaffected', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local OTHER_HC_SOURCE = 300

    f.fakeNow.value = 0
    f.callbacks['qbx_k9unit:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    local result = f.callbacks['qbx_k9unit:server:runtimeSetFeature'](OTHER_HC_SOURCE, 'DoorInteraction', false)
    t.isTrue(result.ok, 'a different officer, same fakeNow, must not be blocked by the first officer\'s cooldown')
end)

-- ============================================================================
-- SECTION 10 -- LOAD-BEARING DRIFT GUARD: every TUNABLE_REGISTRY entry's
-- `path` actually resolves against the REAL, unmodified config.lua, and the
-- value config.lua ships with today falls INSIDE that entry's own declared
-- [min, max] -- the exact class of mistake a hand-typed `path` array (a
-- typo'd key, a table nested one level differently than assumed) or an
-- overly-narrow range would otherwise ship silently: SetTunable would refuse
-- config.lua's OWN shipped default as "out_of_range" the first time anyone
-- reset to it, or GetConfigByPath would silently resolve to `nil` forever.
-- Mirrors tests/runtimefeaturetiers_spec.lua's own "load the REAL config.lua,
-- never a fixture stand-in" discipline for the identical reason: a curated
-- fixture Config table could never catch a `path` that only breaks against
-- the real shape.
-- ============================================================================

--- @return table fixture -- { env, callbacks, fakeNow }
local function bootAgainstRealConfig()
    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Mutable, unlike runtimefeaturetiers_spec.lua's own fixed `return 0`
    -- (that spec never calls a mutating/rate-limited callback more than
    -- once) -- this section's own tests call multiple mutating SetTunable
    -- callbacks back to back from the SAME officer, which would otherwise
    -- collide with RuntimeControlActionCooldown's real 1000ms anti-fat-
    -- finger window every single time.
    local fakeNow = { value = 0 }

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        GetGameTimer           = function() return fakeNow.value end,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = function() end,
        exports                = { qbx_core = { GetPlayer = function() return nil end } },
        IsHighCommand          = function() return true end,
    })

    -- REAL config.lua -- see this section's own header for why a fixture
    -- Config table cannot substitute here.
    Sandbox.loadInto('../config.lua', env)
    env.Config.Database = env.Config.Database or {}
    env.Config.Database.enabled = false -- route K9Store through its in-memory backend -- see runtimefeaturetiers_spec.lua's identical "NO MYSQL STUB NEEDED" note

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('qbx_k9unit') end

    return { env = env, callbacks = callbacks, printedLines = printedLines, fakeNow = fakeNow }
end

t.test('LOAD-BEARING DRIFT GUARD: every TUNABLE_REGISTRY path resolves against the REAL config.lua, to a value inside that entry\'s own [min, max]', function()
    local f = bootAgainstRealConfig()

    local listed = f.callbacks['qbx_k9unit:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)

    local problems = {}
    for _, row in ipairs(listed.tunables) do
        if row.currentValue == nil then
            problems[#problems + 1] = row.key .. ' (path does not resolve against real config.lua -- currentValue is nil; check for a mistyped key or a differently-nested table)'
        elseif type(row.currentValue) ~= 'number' then
            problems[#problems + 1] = row.key .. (' (config.lua value is a %s, not a number: %s)'):format(type(row.currentValue), tostring(row.currentValue))
        else
            if row.currentValue < row.min or row.currentValue > row.max then
                problems[#problems + 1] = row.key .. (' (config.lua ships %s, outside this entry\'s own declared [%s, %s] -- SetTunable would refuse config.lua\'s OWN default)'):format(tostring(row.currentValue), tostring(row.min), tostring(row.max))
            end
            if row.integer and row.currentValue ~= math.floor(row.currentValue) then
                problems[#problems + 1] = row.key .. (' (marked integer = true but config.lua ships a fractional value: %s)'):format(tostring(row.currentValue))
            end
        end
    end

    if #problems > 0 then
        table.sort(problems)
        error(('%d TUNABLE_REGISTRY entr(ies) failed against the real config.lua:\n  - %s'):format(#problems, table.concat(problems, '\n  - ')), 0)
    end

    -- Sanity: this really exercised a substantially-expanded registry, not
    -- an accidentally-empty or truncated one -- mirrors
    -- runtimefeaturetiers_spec.lua's own ">= 56" sanity floor for the
    -- identical reason (a loadfile typo silently producing a near-empty
    -- table would otherwise make the loop above pass vacuously).
    t.isTrue(#listed.tunables >= 90, ('sanity: only saw %d tunable(s) registered -- expected at least 90 after this pass\'s expansion'):format(#listed.tunables))
end)

t.test('K9Medkit.cooldownMs must never be exposed as a tunable -- server/medkit.lua\'s own StartSweep prune window (staleAfterMs) is a captured-once-at-load local, not a fresh Config read, so a LIVE RAISE of this value would be silently undermined by the sweep evicting the tracker entry using the OLD, now-too-short window, letting the cooldown reset early', function()
    local f = bootAgainstRealConfig()
    local listed = f.callbacks['qbx_k9unit:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    for _, row in ipairs(listed.tunables) do
        t.isFalse(row.key == 'K9Medkit.cooldownMs', 'K9Medkit.cooldownMs must stay excluded from TUNABLE_REGISTRY -- see this file\'s own header comment on that exclusion for the full bypass this would otherwise open')
    end

    -- SetTunable must refuse it outright too, not merely omit it from the
    -- list -- the exclusion has to hold end to end, not just in ListTunables'
    -- own response.
    local setResult = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'K9Medkit.cooldownMs', 120000)
    t.isFalse(setResult.ok)
    t.equals(setResult.reason, 'invalid_key')
end)

t.test('every out-of-range rejection for a newly-added tunable still names the exact configured bounds back to the caller (spot-check across the expansion, not just the original 20)', function()
    local f = bootAgainstRealConfig()

    -- RuntimeControlActionCooldown.Consume runs BEFORE the range check in
    -- the real callback -- an out-of-range rejection still consumes the
    -- officer's own anti-fat-finger window, exactly like a successful call
    -- does. fakeNow is advanced past RUNTIME_CONTROL_ACTION_COOLDOWN_MS
    -- between every call below for that reason, matching the primary
    -- boot() fixture's own convention throughout this file, so this test
    -- proves the range/bounds behavior and never accidentally collides with
    -- the rate limiter instead.
    local r1 = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'K9DownDispatch.minDurationMs', -1)
    t.isFalse(r1.ok); t.equals(r1.reason, 'out_of_range'); t.equals(r1.min, 0)

    f.fakeNow.value = f.fakeNow.value + 2000
    local r2 = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Wellbeing.Injury.deathRespawnRestoreAmount', 101)
    t.isFalse(r2.ok); t.equals(r2.reason, 'out_of_range'); t.equals(r2.max, 100)

    f.fakeNow.value = f.fakeNow.value + 2000
    local r3 = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'Combat.BiteAndHold.maxDurationMs', 4999)
    t.isFalse(r3.ok); t.equals(r3.reason, 'out_of_range'); t.equals(r3.min, 5000)

    -- And a genuinely in-range write to one of them actually applies live,
    -- proving these new paths are not merely well-formed but functional
    -- end to end against the real Config table.
    f.fakeNow.value = f.fakeNow.value + 2000
    local ok = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'SearchZones.searchCooldownMs', 20000)
    t.isTrue(ok.ok)
    t.equals(f.env.Config.SearchZones.searchCooldownMs, 20000)
end)

t.test('SearchZones.alertBroadcastRadius is deliberately NOT a tunable -- that file\'s own onResourceStart assert calls it "a hard safety ceiling, not a server-tunable-to-anything toggle"', function()
    local f = bootAgainstRealConfig()
    local result = f.callbacks['qbx_k9unit:server:runtimeSetTunable'](HC_SOURCE, 'SearchZones.alertBroadcastRadius', 50.0)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key')
end)

os.exit(t.summary())
