--[[
    tests/permissions_spec.lua

    Tests server/permissions.lua -- the grantable-permissions layer -- against
    the REAL, unmodified production file, via tests/fixtures/sandbox.lua.
    Harness style mirrors tests/admin_spec.lua (read end to end before
    writing this file) and tests/highcommand_spec.lua (multiple independent
    fixtures where load-time/registration-time behavior must be observed
    fresh).

    TWO FIXTURE BUILDERS:
      newFixture(opts)             -- UNIT level: loads only server/cooldowns.lua
        + server/permissions.lua. `IsHighCommand`/`HasK9Access` are
        TEST-CONTROLLED stubs (plain functions the test swaps in), not the
        real server/highcommand.lua/server/certifications.lua -- this is a
        deliberate substitution for isolating server/permissions.lua's own
        logic, exactly matching this codebase's `type(fn) == 'function'`
        soft-dependency contract (a real deployment satisfies it via those
        two real files; this fixture satisfies it via a double).
      newIntegrationFixture(opts)  -- loads the REAL server/highcommand.lua,
        server/certifications.lua and server/admin.lua alongside
        server/permissions.lua in ONE shared env, to prove the actual
        4-step resolution order end-to-end through real production code on
        every step, not a re-implementation of it. Used for the
        "RESOLUTION ORDER" section and the "REVOKED BUT STILL HAS IT BY
        RANK" end-to-end case.

    FAKE k9_permissions TABLE: an in-memory array the MySQL stub below reads/
    writes, keyed exactly the way the real table is (citizenid, permission,
    active) -- built once per fixture, mutated by GrantPermission/
    RevokePermission exactly like a real database would be, so cache/DB
    consistency is exercised for real rather than asserted by fiat.
    `forceInsertError`/`forceUpdateError`/`forceScalarError` are the
    failure-injection knobs used by the "DB ERRORS THROW, NOT NIL" section.

    LOCALE: never stubbed (Sandbox.newEnv already wires the real locale()
    reader over the real locales/en.json), matching
    tests/certifications_spec.lua's own choice -- every notify path this
    spec drives is therefore also a check that
    permissions.grant_notify_target / permissions.revoke_notify_target /
    common.unable_to_resolve_citizenid genuinely exist.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture 1: UNIT level. server/cooldowns.lua + server/permissions.lua only.
-- ----------------------------------------------------------------------

--- @param opts table? -- { permissions: table (default 4-key catalog), departments: table (default police w/ certifierGrade=4,auditGrade=4), isHighCommand: fun(source):boolean (default: always false), hasK9Access: fun(source):boolean (default: always false), commandTablet: boolean (default false) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 0 }
    local function GetGameTimer() return state.now end

    -- ---- fake k9_permissions table ----
    local rows = {}
    local nextId = 0
    local forceInsertError = nil -- nil | 'duplicate' | 'generic'
    local forceUpdateError = nil -- nil | 'not_committed' | 'committed'
    local forceScalarError = false

    local function findActiveRow(citizenid, permission)
        for _, row in ipairs(rows) do
            if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                return row
            end
        end
        return nil
    end

    local mysql = {
        scalar = { await = function(_sql, params)
            if forceScalarError then error('simulated scalar read failure') end
            local row = findActiveRow(params[1], params[2])
            return row and row.id or nil
        end },
        insert = { await = function(_sql, params)
            if forceInsertError == 'duplicate' then
                error({ errno = 1062, message = 'Duplicate entry for key uq_one_active_permission_per_citizen' })
            end
            if forceInsertError == 'generic' then error('simulated insert failure') end
            nextId = nextId + 1
            rows[#rows + 1] = {
                id = nextId, citizenid = params[1], permission = params[2], granted_by = params[3],
                granted_at = '2026-01-01 00:00:00', revoked_by = nil, revoked_at = nil, active = 1,
            }
            return nextId
        end },
        update = { await = function(_sql, params)
            local granterCid, citizenid, permission = params[1], params[2], params[3]
            local affected = 0
            for _, row in ipairs(rows) do
                if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                    if forceUpdateError ~= 'not_committed' then
                        row.active = 0
                        row.revoked_by = granterCid
                        row.revoked_at = '2026-01-01 00:00:00'
                        affected = affected + 1
                    end
                end
            end
            if forceUpdateError == 'not_committed' or forceUpdateError == 'committed' then
                error('simulated update failure')
            end
            return affected
        end },
        query = { await = function(sql, params)
            local out = {}
            if sql:find('SELECT permission FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                end
            elseif sql:find('SELECT permission, granted_by, granted_at FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.citizenid == params[1] and row.active == 1 then
                        out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = row.granted_at }
                    end
                end
            elseif sql:find('SELECT citizenid, granted_by, granted_at FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.permission == params[1] and row.active == 1 then
                        out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = row.granted_at }
                    end
                end
            end
            return out
        end },
    }

    -- ---- players ----
    local playersBySource = {}
    local playersByCitizenId = {}
    local onlineSources = {} -- array of source numbers "already connected" for the onResourceStart backfill test

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        onlineSources[#onlineSources + 1] = source
        return source
    end

    local function disconnectPlayer(source)
        local p = playersBySource[source]
        if not p then return end
        playersBySource[source] = nil
        playersByCitizenId[p.PlayerData.citizenid] = nil
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local function GetPlayersStub() return onlineSources end

    -- ---- misc capture ----
    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceNameStub() return 'qbx_k9unit' end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local Config = {
        Features = opts.features or {
            PermissionGrants = (opts.permissionGrantsEnabled ~= false), -- default true
            CommandTablet = opts.commandTablet == true,                 -- default false
            -- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl)
            -- -- real-shaped extra keys so IsValidPermissionKey's
            -- 'feature.<Name>'/'block.<Name>' validation (this pass) has a
            -- real Config.Features table to validate `<Name>` against, same
            -- table every production feature flag lives in. BiteAndHold
            -- mirrors an actual RequireGrant-listed feature;
            -- SomeFeatureOff is DELIBERATELY `false` (not merely absent) --
            -- IsValidPermissionKey must accept a real key regardless of its
            -- current on/off value (existence, not truthiness, is what is
            -- being checked; "is it currently on" is an entirely separate
            -- question this file never answers).
            BiteAndHold = true,
            SomeFeatureOff = false,
        },
        Permissions = opts.permissions or {
            ['k9.access']  = { label = 'Use K9 abilities', description = 'x' },
            ['k9.certify'] = { label = 'Certify and decertify others', description = 'x' },
            ['k9.audit']   = { label = 'View the audit records', description = 'x' },
            ['k9.givexp']  = { label = 'Grant XP', description = 'x' },
        },
        Departments = opts.departments or {
            police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6, autoAccessGrade = nil },
        },
    }

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        MySQL = mysql,
        exports = exportsStub,
        GetPlayers = GetPlayersStub,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceNameStub,
        lib = libStub,
        -- Test-controlled soft dependencies -- see this file's header.
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasK9Access = opts.hasK9Access, -- deliberately nil by default (type() guard must tolerate absence)
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/permissions.lua', env)

    return {
        env = env,
        state = state,
        rows = rows,
        notifyLog = notifyLog,
        printLog = printLog,
        eventHandlers = eventHandlers,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        setSource = function(src) env.source = src end,
        advanceTime = function(ms) state.now = state.now + ms end,
        setForceInsertError = function(v) forceInsertError = v end,
        setForceUpdateError = function(v) forceUpdateError = v end,
        setForceScalarError = function(v) forceScalarError = v end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do handler() end
        end,
        firePlayerLoaded = function(playerObj)
            for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do handler(playerObj) end
        end,
        fireOnResourceStart = function()
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('qbx_k9unit') end
        end,
    }
end

--- @param f table
--- @param source number
--- @return table?
local function lastNotifyFor(f, source)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == source then found = entry end
    end
    return found
end

-- ----------------------------------------------------------------------
-- Fixture 2: INTEGRATION level. Real server/highcommand.lua +
-- server/certifications.lua + server/admin.lua + server/permissions.lua,
-- all in ONE env, to prove the real 4-step resolution order end to end.
-- ----------------------------------------------------------------------

--- @return table fixture
local function newIntegrationFixture()
    local state = { now = 0 }
    local function GetGameTimer() return state.now end

    local permRows = {}
    local nextPermId = 0
    local function findActivePermRow(citizenid, permission)
        for _, row in ipairs(permRows) do
            if row.citizenid == citizenid and row.permission == permission and row.active == 1 then return row end
        end
        return nil
    end

    local mysql = {
        scalar = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local row = findActivePermRow(params[1], params[2])
                return row and row.id or nil
            end
            return nil -- k9_certifications pre-checks: no existing row, not exercised by these tests
        end },
        insert = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                nextPermId = nextPermId + 1
                permRows[#permRows + 1] = {
                    id = nextPermId, citizenid = params[1], permission = params[2], granted_by = params[3],
                    granted_at = '2026-01-01 00:00:00', active = 1,
                }
                return nextPermId
            end
            return 1
        end },
        update = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local granterCid, citizenid, permission = params[1], params[2], params[3]
                local affected = 0
                for _, row in ipairs(permRows) do
                    if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                        row.active = 0
                        row.revoked_by = granterCid
                        affected = affected + 1
                    end
                end
                return affected
            end
            return 0 -- k9_certifications update: pretend nothing was active -- these tests only exercise the authorization gate, not a real cert flip
        end },
        query = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local out = {}
                if sql:find('SELECT permission FROM k9_permissions', 1, true) then
                    for _, row in ipairs(permRows) do
                        if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                    end
                elseif sql:find('SELECT permission, granted_by, granted_at FROM k9_permissions', 1, true) then
                    for _, row in ipairs(permRows) do
                        if row.citizenid == params[1] and row.active == 1 then
                            out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = row.granted_at }
                        end
                    end
                end
                return out
            end
            return {} -- k9_certifications SELECTs (admin.lua audit queries): always empty, not exercised
        end },
    }

    local playersBySource = {}
    local playersByCitizenId = {}
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return source
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCommands = {}
    local function RegisterCommand(name, fn, _restricted) capturedCommands[name] = fn end

    local function RegisterNetEvent(_name, _fn) end -- not exercised by these tests

    local function GetCurrentResourceNameStub() return 'qbx_k9unit' end
    local function GetHashKeyStub(_name) return 111 end
    local function TriggerEventStub(_name, ...) end

    -- lib.callback.register is only actually reached by server/certifications.lua's
    -- hasK9Access callback here (permissions.lua's OWN tabletGrant/Revoke
    -- registrations are gated behind Config.Features.CommandTablet, false in
    -- this fixture) -- nothing in this suite needs to invoke it, so this is a
    -- pure no-op stub, just enough for `lib.callback.register(...)` to not
    -- throw "attempt to index a nil value" at those files' own load time.
    local libStub = { callback = { register = function(_name, _fn) end } }

    local Config = {
        Features = { PermissionGrants = true, HighCommand = true, AdminAuditCommands = true, CommandTablet = false },
        Departments = {
            police = { label = 'LSPD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6, autoAccessGrade = nil },
        },
        Peds = { { model = 'a_c_shepherd' } },
        CertifyProximityMeters = 5.0,
        AllowSelfCertification = true,
        -- Required by server/highcommand.lua's onResourceStart guard since
        -- Config.Features.HighCommand is true above -- '/k9givexp' itself is
        -- never exercised by these tests, but this file's onResourceStart
        -- fires for every loaded file indiscriminately, so it must pass.
        HighCommand = { maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false },
        AdminAudit = {
            TrustConsole = false,
            CommandCooldownMs = 300,
            MaxResults = { Certifications = 50, Partnerships = 50, SearchLog = 50 },
        },
        Permissions = {
            ['k9.access']  = { label = 'Use K9 abilities' },
            ['k9.certify'] = { label = 'Certify and decertify others' },
            ['k9.audit']   = { label = 'View the audit records' },
            ['k9.givexp']  = { label = 'Grant XP' },
        },
    }

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        MySQL = mysql,
        exports = exportsStub,
        GetPlayers = function() return {} end,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        AddEventHandler = AddEventHandler,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceNameStub,
        GetHashKey = GetHashKeyStub,
        TriggerEvent = TriggerEventStub,
        lib = libStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/highcommand.lua', env)   -- real IsHighCommand
    Sandbox.loadInto('../server/certifications.lua', env) -- real HasK9Access / IsEligibleCertifier
    Sandbox.loadInto('../server/admin.lua', env)           -- real IsAuthorizedAdmin
    Sandbox.loadInto('../server/permissions.lua', env)     -- real HasPermission / GrantPermission / RevokePermission

    -- Register admin.lua's commands (k9auditcert etc.) -- gated on
    -- Config.Features.AdminAuditCommands, already true above.
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    return {
        env = env,
        state = state,
        permRows = permRows,
        notifyLog = notifyLog,
        printLog = printLog,
        commands = capturedCommands,
        registerPlayer = registerPlayer,
        advanceTime = function(ms) state.now = state.now + ms end,
    }
end

--- @param f table -- an integration fixture
--- @param label string -- substring to search recent prints for
--- @return boolean
local function lastPrintContains(f, label)
    local last = f.printLog[#f.printLog]
    return last ~= nil and last:find(label, 1, true) ~= nil
end

-- ============================================================================
-- LOAD-TIME CONFIG-SAFETY GUARD -- Config.Permissions is asserted
-- unconditionally at THIS FILE'S OWN LOAD TIME (not deferred to
-- onResourceStart), matching server/certifications.lua's authorization-root
-- convention. Each case here loads a FRESH, minimal env directly (not
-- newFixture(), since the point is to observe the load itself failing).
-- ============================================================================

local function tryLoadPermissionsWithConfig(permissionsConfig)
    local env = Sandbox.newEnv({
        Config = { Permissions = permissionsConfig },
        GetGameTimer = function() return 0 end,
        AddEventHandler = function(_name, _fn) end,
    })
    return pcall(function()
        Sandbox.loadInto('../server/cooldowns.lua', env)
        Sandbox.loadInto('../server/permissions.lua', env)
    end)
end

t.test('LOAD-TIME: a well-formed Config.Permissions loads cleanly', function()
    local ok = tryLoadPermissionsWithConfig({ ['k9.access'] = { label = 'Use K9 abilities' } })
    t.isTrue(ok)
end)

t.test('LOAD-TIME: Config.Permissions missing entirely fails loudly at load time', function()
    local ok = pcall(function()
        local env = Sandbox.newEnv({ Config = {}, GetGameTimer = function() return 0 end })
        Sandbox.loadInto('../server/cooldowns.lua', env)
        Sandbox.loadInto('../server/permissions.lua', env)
    end)
    t.isFalse(ok, 'a missing Config.Permissions must fail resource start, not silently pass')
end)

t.test('LOAD-TIME: a Config.Permissions entry with no label fails loudly', function()
    local ok = tryLoadPermissionsWithConfig({ ['k9.access'] = { description = 'no label here' } })
    t.isFalse(ok)
end)

t.test('LOAD-TIME: a Config.Permissions entry with an empty-string label fails loudly', function()
    local ok = tryLoadPermissionsWithConfig({ ['k9.access'] = { label = '' } })
    t.isFalse(ok)
end)

t.test('LOAD-TIME: a Config.Permissions entry with a non-string description fails loudly', function()
    local ok = tryLoadPermissionsWithConfig({ ['k9.access'] = { label = 'ok', description = 123 } })
    t.isFalse(ok)
end)

-- ============================================================================
-- HasPermission -- step 1 of the resolution order, in isolation. Every
-- fail-closed path.
-- ============================================================================

do
    local f = newFixture()
    f.registerPlayer(1, 'K9-1', { name = 'police', grade = { level = 1 } })

    t.test('HasPermission: false with no cache entry at all (never crashes on an unknown citizenid)', function()
        t.isFalse(f.env.HasPermission('NEVER-SEEN', 'k9.access'))
    end)

    t.test('HasPermission: false for a non-string citizenid', function()
        t.isFalse(f.env.HasPermission(nil, 'k9.access'))
        t.isFalse(f.env.HasPermission(123, 'k9.access'))
    end)

    t.test('HasPermission: false for an empty-string citizenid', function()
        t.isFalse(f.env.HasPermission('', 'k9.access'))
    end)

    t.test('HasPermission: false for a permission key not in Config.Permissions', function()
        f.env.GrantPermission(nil, 'K9-1', 'k9.access') -- irrelevant call just to prove this isn't about the grant itself
        t.isFalse(f.env.HasPermission('K9-1', 'not.a.real.permission'))
    end)

    t.test('HasPermission: false when Config.Features.PermissionGrants is off, even with an active grant', function()
        f.registerPlayer(2, 'K9-2', { name = 'police', grade = { level = 1 } })
        local hc = newFixture({ isHighCommand = function() return true end })
        local hcSrc = hc.registerPlayer(50, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
        hc.registerPlayer(51, 'K9-OFF', { name = 'police', grade = { level = 1 } })
        local ok = hc.env.GrantPermission(hcSrc, 'K9-OFF', 'k9.access')
        t.isTrue(ok)
        t.isTrue(hc.env.HasPermission('K9-OFF', 'k9.access'))
        hc.env.Config.Features.PermissionGrants = false
        t.isFalse(hc.env.HasPermission('K9-OFF', 'k9.access'), 'feature flag must be re-checked on EVERY call, not cached')
    end)
end

-- ============================================================================
-- GrantPermission -- authorization, validation, self-grant, cooldown,
-- TOCTOU lock, duplicate-key handling, DB error handling, notifications.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 100 end })
    local hcSrc = f.registerPlayer(100, 'HC-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(101, 'LOWRANK', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(102, 'TARGET-A', { name = 'police', grade = { level = 1 } })

    t.test('GrantPermission: feature disabled -> feature_disabled, nothing granted', function()
        f.env.Config.Features.PermissionGrants = false
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        f.env.Config.Features.PermissionGrants = true
        t.isFalse(ok)
        t.equals(outcome, 'feature_disabled')
    end)

    t.test('GrantPermission: a non-high-command caller is denied', function()
        local ok, outcome = f.env.GrantPermission(101, 'TARGET-A', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    t.test('GrantPermission: an unconfigured permission key is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'not.real')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    -- ------------------------------------------------------------------
    -- IsValidPermissionKey: 'feature.<Name>'/'block.<Name>' -- THE HEADLINE
    -- FIX this pass exists to make. Before this fix, EVERY one of these
    -- calls failed as 'invalid_permission', which is exactly why
    -- Config.FeatureControl.RequireGrant/per-person blocks had zero real
    -- effect regardless of what any consuming gate (server/combat.lua,
    -- server/pursuitsprint.lua, server/admin.lua) already checked for.
    -- Proven here against the REAL, unmodified IsValidPermissionKey via
    -- GrantPermission/RevokePermission -- never a reimplementation.
    -- ------------------------------------------------------------------

    t.test('GrantPermission: feature.<Name> is accepted when <Name> is a real Config.Features key', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.BiteAndHold')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: block.<Name> is accepted when <Name> is a real Config.Features key', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.BiteAndHold')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: feature.<Name> is accepted even when <Name>\'s CURRENT VALUE is false -- existence in Config.Features is what is checked, not truthiness', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.SomeFeatureOff')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: feature.<Name> is STILL rejected when <Name> is NOT a real Config.Features key -- validated against what actually exists, not a free-form string', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.NotARealFeature')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: block.<Name> is STILL rejected when <Name> is NOT a real Config.Features key', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.NotARealFeature')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: a bare "feature." with no name suffix at all is rejected, not treated as Config.Features[""]', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: an injection-shaped feature.<Name> payload is rejected exactly like any other unrecognized key -- never reaches SQL text either way (parameterized)', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', "feature.'; DROP TABLE k9_permissions;--")
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: an oversized feature.<Name> payload (> 50 chars, the k9_permissions.permission column width) is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.' .. string.rep('x', 50))
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('END-TO-END: a granted feature.<Name> is genuinely readable back via HasPermission once the target is online (not merely accepted by the validator)', function()
        f.advanceTime(2000)
        local targetSrc = f.registerPlayer(103, 'TARGET-FC', { name = 'police', grade = { level = 1 } })
        local ok = f.env.GrantPermission(hcSrc, 'TARGET-FC', 'feature.BiteAndHold')
        t.isTrue(ok)
        t.isTrue(f.env.HasPermission('TARGET-FC', 'feature.BiteAndHold'))
        f.disconnectPlayer(targetSrc)
    end)

    t.test('END-TO-END: RevokePermission genuinely removes a previously granted block.<Name> row', function()
        f.advanceTime(2000)
        local targetSrc = f.registerPlayer(104, 'TARGET-FC2', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'TARGET-FC2', 'block.BiteAndHold')
        t.isTrue(f.env.HasPermission('TARGET-FC2', 'block.BiteAndHold'))

        f.advanceTime(2000)
        local ok = f.env.RevokePermission(hcSrc, 'TARGET-FC2', 'block.BiteAndHold')
        t.isTrue(ok)
        t.isFalse(f.env.HasPermission('TARGET-FC2', 'block.BiteAndHold'))
        f.disconnectPlayer(targetSrc)
    end)

    t.test('GrantPermission: an empty-string target citizenid is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, '', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('GrantPermission: a target citizenid over 50 chars is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, string.rep('x', 51), 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('GrantPermission: an unresolvable granter citizenid fails as invalid_granter and reuses common.unable_to_resolve_citizenid', function()
        f.advanceTime(2000)
        local hc2 = newFixture({ isHighCommand = function() return true end })
        local src = 900
        hc2.env.exports.qbx_core.GetPlayer = function(_self, s) if s == src then return { PlayerData = {} } end return nil end
        local ok, outcome = hc2.env.GrantPermission(src, 'X', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_granter')
        t.contains(lastNotifyFor(hc2, src).message, 'Unable to resolve')
    end)

    t.test('GrantPermission: self-grant is unconditionally blocked, no config escape hatch', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'HC-GRANTER', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'self_grant_blocked')
    end)

    t.test('GrantPermission: a successful grant returns ok, notifies the online target, and HasPermission reflects it', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isTrue(f.env.HasPermission('TARGET-A', 'k9.access'))
        local n = lastNotifyFor(f, 102)
        t.isNotNil(n)
        t.contains(n.message, 'Use K9 abilities')
    end)

    t.test('GrantPermission: granting an already-active permission reports already_granted, no duplicate row', function()
        f.advanceTime(2000)
        local before = #f.rows
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'already_granted')
        t.equals(#f.rows, before, 'no second row should be inserted')
    end)

    t.test('GrantPermission: a TOCTOU duplicate-key error from the INSERT is treated as already_granted, not a hard failure', function()
        f.advanceTime(2000)
        f.registerPlayer(103, 'TARGET-RACE', { name = 'police', grade = { level = 1 } })
        f.setForceInsertError('duplicate')
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-RACE', 'k9.certify')
        f.setForceInsertError(nil)
        t.isFalse(ok)
        t.equals(outcome, 'already_granted')
    end)

    t.test('GrantPermission: a generic thrown INSERT error surfaces as db_error, does not propagate', function()
        f.advanceTime(2000)
        f.registerPlayer(104, 'TARGET-DBERR', { name = 'police', grade = { level = 1 } })
        f.setForceInsertError('generic')
        local pcallOk, ok, outcome = pcall(f.env.GrantPermission, hcSrc, 'TARGET-DBERR', 'k9.audit')
        f.setForceInsertError(nil)
        t.isTrue(pcallOk, 'must not raise out of GrantPermission: ' .. tostring(ok))
        t.isFalse(ok)
        t.equals(outcome, 'db_error')
    end)

    t.test('GrantPermission: an unresolvable pre-check read (thrown scalar.await) surfaces as db_error, does not propagate', function()
        f.advanceTime(2000)
        f.registerPlayer(105, 'TARGET-SCALARERR', { name = 'police', grade = { level = 1 } })
        f.setForceScalarError(true)
        local ok, err = pcall(function() return f.env.GrantPermission(hcSrc, 'TARGET-SCALARERR', 'k9.givexp') end)
        f.setForceScalarError(false)
        t.isTrue(ok, 'must not raise out of GrantPermission: ' .. tostring(err))
    end)

    t.test('GrantPermission: a second grant from the same officer inside the cooldown window is rate_limited', function()
        f.advanceTime(2000)
        f.registerPlayer(110, 'RATE-A', { name = 'police', grade = { level = 1 } })
        f.registerPlayer(111, 'RATE-B', { name = 'police', grade = { level = 1 } })
        local ok1 = f.env.GrantPermission(hcSrc, 'RATE-A', 'k9.access')
        t.isTrue(ok1)
        f.advanceTime(100) -- well within the 1500ms cooldown
        local ok2, outcome2 = f.env.GrantPermission(hcSrc, 'RATE-B', 'k9.access')
        t.isFalse(ok2)
        t.equals(outcome2, 'rate_limited')
        f.advanceTime(1600) -- past the cooldown
        local ok3 = f.env.GrantPermission(hcSrc, 'RATE-B', 'k9.access')
        t.isTrue(ok3, 'a grant after the cooldown window has elapsed must succeed')
    end)

    t.test('GrantPermission: granting to an OFFLINE citizenid succeeds but creates no cache entry (HasPermission stays false until they connect)', function()
        f.advanceTime(2000)
        local ok = f.env.GrantPermission(hcSrc, 'OFFLINE-K9', 'k9.access')
        t.isTrue(ok)
        t.isFalse(f.env.HasPermission('OFFLINE-K9', 'k9.access'), 'no cache entry should exist for a citizenid who was never online')
        -- Now they connect -- PlayerLoaded warms the cache from the real DB row.
        f.firePlayerLoaded({ PlayerData = { citizenid = 'OFFLINE-K9', job = { name = 'police' } } })
        t.isTrue(f.env.HasPermission('OFFLINE-K9', 'k9.access'), 'connecting must warm the cache from the already-granted DB row')
    end)
end

-- ============================================================================
-- RevokePermission -- authorization, validation, not_granted, cooldown,
-- DB-throw reconciliation, cache invalidation, the 3-way stillHasAccess
-- contract, and target notification suppression.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 200 end })
    local hcSrc = f.registerPlayer(200, 'HC-REVOKER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(201, 'LOWRANK2', { name = 'police', grade = { level = 1 } })

    t.test('RevokePermission: feature disabled -> feature_disabled', function()
        f.env.Config.Features.PermissionGrants = false
        local ok, outcome = f.env.RevokePermission(hcSrc, 'X', 'k9.access')
        f.env.Config.Features.PermissionGrants = true
        t.isFalse(ok)
        t.equals(outcome, 'feature_disabled')
    end)

    t.test('RevokePermission: a non-high-command caller is denied', function()
        local ok, outcome = f.env.RevokePermission(201, 'X', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    t.test('RevokePermission: an unconfigured permission key is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.RevokePermission(hcSrc, 'X', 'not.real')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('RevokePermission: an invalid target citizenid is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.RevokePermission(hcSrc, '', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('RevokePermission: revoking a permission nobody holds reports not_granted', function()
        f.advanceTime(2000)
        f.registerPlayer(202, 'NEVER-GRANTED', { name = 'police', grade = { level = 1 } })
        local ok, outcome = f.env.RevokePermission(hcSrc, 'NEVER-GRANTED', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'not_granted')
    end)

    t.test('RevokePermission: fully removes access -- ok, stillHasAccess is nil, target notified', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(203, 'FULLREMOVE', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'FULLREMOVE', 'k9.access')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'FULLREMOVE', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)
        t.isFalse(f.env.HasPermission('FULLREMOVE', 'k9.access'))
        local n = lastNotifyFor(f, target)
        t.isNotNil(n)
        t.contains(n.message, 'Use K9 abilities')
    end)

    t.test('RevokePermission: self-revoke (an officer revoking their own earlier grant) is allowed -- unlike self-grant', function()
        f.advanceTime(2000)
        -- HC-REVOKER cannot self-grant (blocked), so simulate a pre-existing
        -- row directly in the fake table, as if granted by a DIFFERENT officer
        -- earlier, then revoked by this same officer now.
        f.rows[#f.rows + 1] = { id = 99000, citizenid = 'HC-REVOKER', permission = 'k9.audit', granted_by = 'SOMEONE-ELSE', active = 1 }
        local ok, outcome = f.env.RevokePermission(hcSrc, 'HC-REVOKER', 'k9.audit')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
    end)

    t.test('RevokePermission: a second revoke from the same officer inside the cooldown window is rate_limited (shared cooldown w/ grant)', function()
        f.advanceTime(2000)
        f.registerPlayer(204, 'CD-TARGET-A', { name = 'police', grade = { level = 1 } })
        f.registerPlayer(205, 'CD-TARGET-B', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'CD-TARGET-A', 'k9.access')
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'CD-TARGET-B', 'k9.access')
        f.advanceTime(2000)
        local ok1 = f.env.RevokePermission(hcSrc, 'CD-TARGET-A', 'k9.access')
        t.isTrue(ok1)
        f.advanceTime(100)
        local ok2, outcome2 = f.env.RevokePermission(hcSrc, 'CD-TARGET-B', 'k9.access')
        t.isFalse(ok2)
        t.equals(outcome2, 'rate_limited', 'grant and revoke must share ONE cooldown tracker')
    end)
end

-- ============================================================================
-- DB ERRORS THROW, NOT NIL -- RevokePermission's reconciliation-on-throw.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 300 end })
    local hcSrc = f.registerPlayer(300, 'HC-DB', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('RevokePermission: a thrown UPDATE where the row is confirmed STILL ACTIVE (never committed) reports db_error, changes nothing', function()
        f.registerPlayer(301, 'DBERR-NOTCOMMITTED', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DBERR-NOTCOMMITTED', 'k9.access')
        f.advanceTime(2000)
        f.setForceUpdateError('not_committed')
        local ok, outcome = f.env.RevokePermission(hcSrc, 'DBERR-NOTCOMMITTED', 'k9.access')
        f.setForceUpdateError(nil)
        t.isFalse(ok)
        t.equals(outcome, 'db_error')
        t.isTrue(f.env.HasPermission('DBERR-NOTCOMMITTED', 'k9.access'), 'a never-committed revoke must leave access intact')
    end)

    t.test('RevokePermission: a thrown UPDATE where the row is confirmed INACTIVE (committed despite the throw) reports success', function()
        f.advanceTime(2000)
        f.registerPlayer(302, 'DBERR-COMMITTED', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DBERR-COMMITTED', 'k9.access')
        f.advanceTime(2000)
        f.setForceUpdateError('committed')
        local ok, outcome = f.env.RevokePermission(hcSrc, 'DBERR-COMMITTED', 'k9.access')
        f.setForceUpdateError(nil)
        t.isTrue(ok, 'the reconciliation read must confirm the real commit and report success')
        t.equals(outcome, 'ok')
        t.isFalse(f.env.HasPermission('DBERR-COMMITTED', 'k9.access'))
    end)

    t.test('RevokePermission: a thrown UPDATE whose reconciliation read ALSO fails (unreadable) reports db_error, never guesses success', function()
        f.advanceTime(2000)
        f.registerPlayer(303, 'DBERR-UNREADABLE', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DBERR-UNREADABLE', 'k9.access')
        f.advanceTime(2000)
        f.setForceUpdateError('not_committed')
        f.setForceScalarError(true)
        local ok, outcome = f.env.RevokePermission(hcSrc, 'DBERR-UNREADABLE', 'k9.access')
        f.setForceUpdateError(nil)
        f.setForceScalarError(false)
        t.isFalse(ok)
        t.equals(outcome, 'db_error')
    end)
end

-- ============================================================================
-- THE "REVOKED BUT STILL HAS IT BY RANK" 3-WAY stillHasAccess CONTRACT --
-- unit-level, using injected IsHighCommand/HasK9Access doubles.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 400 end })
    local hcSrc = f.registerPlayer(400, 'HC-RANK', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('RevokePermission: stillHasAccess is "rank_or_high_command" when the online target ALSO meets the legacy rank gate (k9.certify/certifierGrade=4)', function()
        f.registerPlayer(401, 'STILLCERT', { name = 'police', grade = { level = 5 } }) -- >= certifierGrade 4
        f.env.GrantPermission(hcSrc, 'STILLCERT', 'k9.certify')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'STILLCERT', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')
    end)

    t.test('RevokePermission: stillHasAccess is nil when the online target does NOT meet the legacy rank gate', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(402, 'NOTCERT', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4
        f.env.GrantPermission(hcSrc, 'NOTCERT', 'k9.certify')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'NOTCERT', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)
        t.isNotNil(lastNotifyFor(f, target), 'a genuine full removal must still notify the target')
    end)

    t.test('RevokePermission: stillHasAccess is "rank_or_high_command" for k9.givexp when the target IS high command (no legacy tier below it exists)', function()
        f.advanceTime(2000)
        local hcTarget = f.registerPlayer(403, 'HC-TARGET-GIVEXP', { name = 'police', isboss = true, grade = { level = 0 } })
        -- Give this SECOND high-command officer the grant via a different granter identity isn't needed --
        -- self-grant only blocks the GRANTER's own citizenid; grant from hcSrc to a DIFFERENT high-command citizenid is fine.
        f.env.GrantPermission(hcSrc, 'HC-TARGET-GIVEXP', 'k9.givexp')
        f.advanceTime(2000)
        -- Make IsHighCommand ALSO true for this target's own source for this one check.
        local originalIsHighCommand = f.env.IsHighCommand
        f.env.IsHighCommand = function(source) return source == 400 or source == hcTarget end
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'HC-TARGET-GIVEXP', 'k9.givexp')
        f.env.IsHighCommand = originalIsHighCommand
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')
    end)

    t.test('RevokePermission: stillHasAccess is "unknown_target_offline" when the target is not currently connected', function()
        f.advanceTime(2000)
        f.registerPlayer(404, 'WILLDISCONNECT', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'WILLDISCONNECT', 'k9.access')
        f.disconnectPlayer(404)
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'WILLDISCONNECT', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'unknown_target_offline')
    end)

    t.test('RevokePermission: for k9.access, reuses the real HasK9Access (via type() guard) for the reconciliation check', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(405, 'ACCESSCHECK', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'ACCESSCHECK', 'k9.access')
        f.advanceTime(2000)
        -- Simulate HasK9Access still returning true for this citizenid via some
        -- OTHER path (e.g. an active cert cache entry) after the grant is gone.
        f.env.HasK9Access = function(source) return source == target end
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'ACCESSCHECK', 'k9.access')
        f.env.HasK9Access = nil
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')
    end)
end

-- ============================================================================
-- CACHE INVALIDATION -- grant, revoke, and playerDropped. Granular per-key
-- correctness (revoking one permission must not disturb another).
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 500 end })
    local hcSrc = f.registerPlayer(500, 'HC-CACHE', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('cache: granting TWO different permissions to the same citizenid, then revoking ONE, leaves the other intact', function()
        f.registerPlayer(501, 'MULTI', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'MULTI', 'k9.access')
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'MULTI', 'k9.audit')
        f.advanceTime(2000)
        t.isTrue(f.env.HasPermission('MULTI', 'k9.access'))
        t.isTrue(f.env.HasPermission('MULTI', 'k9.audit'))

        f.env.RevokePermission(hcSrc, 'MULTI', 'k9.access')
        t.isFalse(f.env.HasPermission('MULTI', 'k9.access'), 'the revoked permission must be gone')
        t.isTrue(f.env.HasPermission('MULTI', 'k9.audit'), 'the UNRELATED permission must survive the revoke of the other one')
    end)

    t.test('cache: playerDropped clears the cache entry; a later reconnect re-warms it from the DB', function()
        f.advanceTime(2000)
        f.registerPlayer(502, 'DROPTEST', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DROPTEST', 'k9.access')
        t.isTrue(f.env.HasPermission('DROPTEST', 'k9.access'))

        f.firePlayerDropped(502)
        t.isFalse(f.env.HasPermission('DROPTEST', 'k9.access'), 'the cache entry must be evicted on disconnect')

        f.firePlayerLoaded({ PlayerData = { citizenid = 'DROPTEST', job = { name = 'police' } } })
        t.isTrue(f.env.HasPermission('DROPTEST', 'k9.access'), 'reconnecting must re-warm the cache from the still-active DB row')
    end)

    t.test('cache: onResourceStart backfills already-connected players (a restart while players are online)', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(503, 'RESTARTED', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'RESTARTED', 'k9.givexp')
        -- Wipe the cache to simulate a fresh resource load with no PlayerLoaded
        -- having fired yet for this already-connected player.
        f.firePlayerDropped(target)
        f.registerPlayer(target, 'RESTARTED', { name = 'police', grade = { level = 1 } })
        t.isFalse(f.env.HasPermission('RESTARTED', 'k9.givexp'), 'sanity: cache genuinely empty before the backfill runs')

        f.fireOnResourceStart()
        t.isTrue(f.env.HasPermission('RESTARTED', 'k9.givexp'), 'onResourceStart must backfill every already-connected citizenid\'s real grants')
    end)
end

-- ============================================================================
-- ListActivePermissionsForCitizenId / ListPermissionRoster -- authorization,
-- validation, and correct row shape.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 600 end })
    local hcSrc = f.registerPlayer(600, 'HC-LIST', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(601, 'LOWRANK3', { name = 'police', grade = { level = 1 } })

    f.env.GrantPermission(hcSrc, 'ROSTER-A', 'k9.audit')
    f.advanceTime(2000)
    f.env.GrantPermission(hcSrc, 'ROSTER-B', 'k9.audit')
    f.advanceTime(2000)
    f.env.GrantPermission(hcSrc, 'ROSTER-A', 'k9.certify')

    t.test('ListActivePermissionsForCitizenId: a non-high-command caller is denied', function()
        local ok, outcome = f.env.ListActivePermissionsForCitizenId(601, 'ROSTER-A')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    t.test('ListActivePermissionsForCitizenId: an invalid target citizenid is rejected', function()
        local ok, outcome = f.env.ListActivePermissionsForCitizenId(hcSrc, '')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('ListActivePermissionsForCitizenId: returns every active permission for the target, shaped correctly', function()
        local ok, list = f.env.ListActivePermissionsForCitizenId(hcSrc, 'ROSTER-A')
        t.isTrue(ok)
        t.equals(#list, 2)
        local perms = {}
        for _, row in ipairs(list) do perms[row.permission] = row end
        t.isNotNil(perms['k9.audit'])
        t.isNotNil(perms['k9.certify'])
        t.equals(perms['k9.audit'].grantedBy, 'HC-LIST')
    end)

    t.test('ListPermissionRoster: a non-high-command caller is denied', function()
        local ok, outcome = f.env.ListPermissionRoster(601, 'k9.audit')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    t.test('ListPermissionRoster: an unconfigured permission key is rejected', function()
        local ok, outcome = f.env.ListPermissionRoster(hcSrc, 'not.real')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('ListPermissionRoster: returns every citizenid holding the given permission', function()
        local ok, roster = f.env.ListPermissionRoster(hcSrc, 'k9.audit')
        t.isTrue(ok)
        t.equals(#roster, 2)
        local citizenids = {}
        for _, row in ipairs(roster) do citizenids[row.citizenid] = true end
        t.isTrue(citizenids['ROSTER-A'])
        t.isTrue(citizenids['ROSTER-B'])
    end)
end

-- ============================================================================
-- TABLET CALLBACKS -- registered only when Config.Features.CommandTablet is
-- true; exact return-shape contract client/tablet.lua depends on.
-- ============================================================================

t.test('tablet callbacks: NOT registered when Config.Features.CommandTablet is false (the default)', function()
    local f = newFixture({ commandTablet = false })
    t.isNil(f.callbacks['qbx_k9unit:server:tabletGrantPermission'])
    t.isNil(f.callbacks['qbx_k9unit:server:tabletRevokePermission'])
end)

do
    local f = newFixture({ commandTablet = true, isHighCommand = function(source) return source == 700 end })
    local hcSrc = f.registerPlayer(700, 'HC-TABLET', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(701, 'TABLET-TARGET', { name = 'police', grade = { level = 5 } }) -- meets certifierGrade too, for the "still has it" case

    t.test('tablet callbacks: ARE registered when Config.Features.CommandTablet is true', function()
        t.isNotNil(f.callbacks['qbx_k9unit:server:tabletGrantPermission'])
        t.isNotNil(f.callbacks['qbx_k9unit:server:tabletRevokePermission'])
    end)

    t.test('tabletGrantPermission: success returns { ok = true }', function()
        local result = f.callbacks['qbx_k9unit:server:tabletGrantPermission'](hcSrc, 'TABLET-TARGET', 'k9.certify')
        t.isTrue(result.ok)
        t.isNil(result.reason)
    end)

    t.test('tabletGrantPermission: failure returns { ok = false, reason = <outcome> }', function()
        local result = f.callbacks['qbx_k9unit:server:tabletGrantPermission'](701, 'TABLET-TARGET', 'k9.certify') -- 701 is not high command
        t.isFalse(result.ok)
        t.equals(result.reason, 'denied')
    end)

    t.test('tabletRevokePermission: full removal returns { ok = true } with no reason', function()
        f.advanceTime(2000)
        f.registerPlayer(702, 'TABLET-FULLREMOVE', { name = 'police', grade = { level = 1 } }) -- below certifierGrade
        f.env.GrantPermission(hcSrc, 'TABLET-FULLREMOVE', 'k9.certify')
        f.advanceTime(2000)
        local result = f.callbacks['qbx_k9unit:server:tabletRevokePermission'](hcSrc, 'TABLET-FULLREMOVE', 'k9.certify')
        t.isTrue(result.ok)
        t.isNil(result.reason)
    end)

    t.test('tabletRevokePermission: revoking from someone who still qualifies by rank returns { ok = true, reason = "rank_or_high_command" } -- never a silent, unqualified success', function()
        f.advanceTime(2000)
        local result = f.callbacks['qbx_k9unit:server:tabletRevokePermission'](hcSrc, 'TABLET-TARGET', 'k9.certify')
        t.isTrue(result.ok, 'the revoke DB write itself did succeed')
        t.equals(result.reason, 'rank_or_high_command', 'the UI must be told this did not actually remove their access')
    end)

    t.test('tabletRevokePermission: failure returns { ok = false, reason = <outcome> }', function()
        f.advanceTime(2000)
        local result = f.callbacks['qbx_k9unit:server:tabletRevokePermission'](hcSrc, 'TABLET-TARGET', 'not.real')
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_permission')
    end)
end

-- ============================================================================
-- RESOLUTION ORDER -- end-to-end, through the REAL server/highcommand.lua,
-- server/certifications.lua and server/admin.lua (newIntegrationFixture).
-- ============================================================================

do
    local f = newIntegrationFixture()

    -- Step 1 alone: a grant with NO high command and rank below every
    -- legacy threshold must still ALLOW.
    t.test('resolution order STEP 1 (k9.access): a bare grant, no high command, rank below every threshold, still allows HasK9Access', function()
        local src = f.registerPlayer(1001, 'STEP1-ACCESS', { name = 'police', grade = { level = 0 } })
        t.isFalse(f.env.HasK9Access(src), 'sanity: no access before any grant')
        local granterSrc = f.registerPlayer(1002, 'STEP1-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
        local ok = f.env.GrantPermission(granterSrc, 'STEP1-ACCESS', 'k9.access')
        t.isTrue(ok)
        t.isTrue(f.env.HasK9Access(src), 'step 1 alone must allow -- purely additive')
    end)

    t.test('resolution order STEP 1 (k9.certify): a bare grant lets a low-rank officer pass IsEligibleCertifier, reached via /k9decertifyoffline', function()
        local granterSrc = f.registerPlayer(1003, 'STEP1-GRANTER2', { name = 'police', isboss = true, grade = { level = 0 } })
        local lowRankSrc = f.registerPlayer(1004, 'STEP1-CERTIFY', { name = 'police', grade = { level = 0 } }) -- far below certifierGrade 4
        f.env.GrantPermission(granterSrc, 'STEP1-CERTIFY', 'k9.certify')
        f.advanceTime(2000)
        f.commands.k9decertifyoffline(lowRankSrc, { 'SOMETARGET', 'police' })
        local last = f.notifyLog[#f.notifyLog]
        t.isNotNil(last)
        t.notContains(last.message, 'not authorized', 'a k9.certify grant must let this officer past the eligibility gate (the actual revoke result -- "not actively certified" -- is a separate, expected outcome)')
    end)

    t.test('resolution order STEP 1 (k9.audit): a bare grant lets a low-rank officer pass IsAuthorizedAdmin, reached via /k9auditcert', function()
        local granterSrc = f.registerPlayer(1005, 'STEP1-GRANTER3', { name = 'police', isboss = true, grade = { level = 0 } })
        local lowRankSrc = f.registerPlayer(1006, 'STEP1-AUDIT', { name = 'police', grade = { level = 0 } }) -- far below auditGrade 4
        f.env.GrantPermission(granterSrc, 'STEP1-AUDIT', 'k9.audit')
        f.advanceTime(2000)
        f.commands.k9auditcert(lowRankSrc, { 'ANYCITIZEN' })
        t.isFalse(lastPrintContains(f, 'denied'), 'a k9.audit grant must let this officer past the authorization gate')
    end)

    t.test('resolution order STEP 2: no grant, not high command, but IS high command (highCommandGrade) still allows (unaffected by adding permission grants)', function()
        local src = f.registerPlayer(1007, 'STEP2-HC', { name = 'police', grade = { level = 6 } }) -- meets highCommandGrade
        t.isTrue(f.env.HasK9Access(src))
    end)

    t.test('resolution order STEP 3: no grant, not high command, meets the legacy rank gate -- still allows (nothing that worked on rank stops working)', function()
        local src = f.registerPlayer(1008, 'STEP3-RANK', { name = 'police', grade = { level = 4 } }) -- meets certifierGrade/auditGrade exactly
        f.commands.k9auditcert(src, { 'ANYCITIZEN' })
        t.isFalse(lastPrintContains(f, 'denied'))
    end)

    t.test('resolution order STEP 4: no grant, not high command, below every legacy threshold -- denied', function()
        local src = f.registerPlayer(1009, 'STEP4-NOBODY', { name = 'police', grade = { level = 0 } })
        f.commands.k9auditcert(src, { 'ANYCITIZEN' })
        t.isTrue(lastPrintContains(f, 'denied'))
    end)

    t.test('END-TO-END "revoked but still has it by rank": revoking a k9.certify grant from an officer who ALSO meets certifierGrade does not remove their eligibility, and RevokePermission reports it honestly', function()
        local granterSrc = f.registerPlayer(1010, 'E2E-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
        local officerSrc = f.registerPlayer(1011, 'E2E-OFFICER', { name = 'police', grade = { level = 4 } }) -- meets certifierGrade exactly
        f.env.GrantPermission(granterSrc, 'E2E-OFFICER', 'k9.certify')
        f.advanceTime(2000)

        local ok, outcome, stillHasAccess = f.env.RevokePermission(granterSrc, 'E2E-OFFICER', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command', 'the caller must be told this revoke did not actually remove access')

        -- Confirm it end-to-end against the REAL IsEligibleCertifier, not just the reconciliation's own verdict.
        f.commands.k9decertifyoffline(officerSrc, { 'SOMEOTHERTARGET', 'police' })
        local last = f.notifyLog[#f.notifyLog]
        t.notContains(last.message, 'not authorized', 'the officer must still pass IsEligibleCertifier via rank alone, exactly as config.lua documents')
    end)
end

os.exit(t.summary())
