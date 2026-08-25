--[[
    tests/tabletserver_spec.lua

    Tests server/tablet.lua -- the K9 Command Tablet's server aggregation
    layer -- against the REAL, unmodified production file, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/permissions_spec.lua's
    UNIT-level newFixture(): IsHighCommand/HasPermission/HasK9Access/GetXP/
    GetXPTier/ApplyK9PedRole/ForceRevertK9Appearance are TEST-CONTROLLED
    stubs (plain functions the test swaps in), matching this codebase's
    `type(fn) == 'function'` soft-dependency contract -- a real deployment
    satisfies it via the real server/permissions.lua, server/certifications.lua,
    server/highcommand.lua, server/progression.lua and server/appearance.lua;
    this fixture satisfies it via doubles, so server/tablet.lua's OWN logic
    (state resolution, authorization re-verification, roster bounding) is
    exercised in isolation from those five files' own already-independently-
    tested internals.

    FAKE k9_permissions / k9_certifications TABLES: two in-memory arrays the
    MySQL stub below reads, dispatched by matching the exact SQL text
    substrings server/tablet.lua's own SafeQuery/scalar calls use -- see
    that file's own four query strings (grepped before writing this stub,
    not guessed).

    tabletCertify and tabletGiveXp are NOT tested here -- per server/tablet.lua's
    own header "ARCHITECTURE DECISION", those two callbacks are registered
    inside server/certifications.lua (GrantCertificationForTablet) and
    server/highcommand.lua (GrantHighCommandXp/IsAuthorizedForXpGrant)
    respectively, not in this file at all; certifications_spec.lua and
    highcommand_spec.lua are the right place for coverage of those two (see
    each file's own test additions this pass).

    ROUND TRIP SECTION (added at coder-security's own request, following
    their server/permissions.lua IsValidPermissionKey fix for the
    'feature.<Name>'/'block.<Name>' namespace): a SEPARATE, INTEGRATION-level
    newIntegrationFixture() below loads the REAL server/permissions.lua
    (cooldowns.lua first, for NewCooldown at that file's own load time)
    alongside the REAL server/tablet.lua in one shared env, backed by a
    single real in-memory k9_permissions table both files read/write
    against -- proving the full path end to end: a grant made through
    tabletGrantPermission is a real, storable row that server/tablet.lua's
    OWN QueryActivePermissionSet/ResolveFeatureState later reads back
    correctly, not merely that each half independently believes it works.
    IsHighCommand/HasK9Access remain test-controlled stubs here too (this is
    still not a full production-topology test -- server/certifications.lua/
    server/highcommand.lua are not loaded), matching this file's own
    established UNIT-level convention for everything this round trip does
    not need a real implementation of.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param opts table? -- { isHighCommand, hasPermission, hasK9Access, getXP, getXPTier, applyK9PedRole, forceRevertK9Appearance, config: table (full Config override) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    -- ---- fake tables ----
    local permRows = {} -- { citizenid, permission, granted_by, active }
    local certRows = {} -- { citizenid, job, granted_by, active }

    local function addPermRow(citizenid, permission, grantedBy, active)
        permRows[#permRows + 1] = { citizenid = citizenid, permission = permission, granted_by = grantedBy, active = active == nil and 1 or (active and 1 or 0) }
    end
    local function addCertRow(citizenid, job, grantedBy, active)
        certRows[#certRows + 1] = { citizenid = citizenid, job = job, granted_by = grantedBy, active = active == nil and 1 or (active and 1 or 0) }
    end

    local mysql = {
        query = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(permRows) do
                    if row.citizenid == params[1] and row.active == 1 then
                        out[#out + 1] = { permission = row.permission }
                    end
                end
                return out
            elseif sql:find('k9_certifications', 1, true) then
                if sql:find('WHERE citizenid = ?', 1, true) then
                    local out = {}
                    for _, row in ipairs(certRows) do
                        if row.citizenid == params[1] and row.active == 1 then
                            out[#out + 1] = { job = row.job, granted_by = row.granted_by }
                        end
                    end
                    return out
                elseif sql:find('WHERE job = ?', 1, true) then
                    local out = {}
                    for _, row in ipairs(certRows) do
                        if row.job == params[1] and row.active == 1 then
                            out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by }
                        end
                    end
                    return out
                end
            end
            return {}
        end },
        scalar = { await = function(sql, params)
            if sql:find('k9_certifications', 1, true) then
                for _, row in ipairs(certRows) do
                    if row.citizenid == params[1] and row.active == 1 then return 1 end
                end
                return nil
            end
            return nil
        end },
    }

    -- ---- players ----
    local playersBySource = {}
    local playersByCitizenId = {}

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    --- @param charinfo table?
    local function registerPlayer(source, citizenid, job, charinfo)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source, charinfo = charinfo } }
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

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local function GetPlayerNameStub(source)
        return 'SteamName#' .. tostring(source)
    end

    local Config = opts.config or {
        Features = {
            CommandTablet = true,
            PermissionGrants = true,
            XPProgression = true,
            HighCommand = true,
            BiteAndHold = true,
            NonLethalTakedown = true,
            LeashMechanics = true,
        },
        Departments = {
            police  = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 },
            sheriff = { label = 'Blaine County Sheriff', certifierGrade = 3, auditGrade = 3, highCommandGrade = 5 },
        },
        Permissions = {
            ['k9.access']  = { label = 'Use K9 abilities' },
            ['k9.certify'] = { label = 'Certify and decertify others' },
            ['k9.audit']   = { label = 'View the audit records' },
            ['k9.givexp']  = { label = 'Grant XP' },
        },
        FeatureControl = {
            RequireGrant = { BiteAndHold = true, NonLethalTakedown = true },
            everyoneCanViewOwnRecord = true,
        },
        CommandTablet = {
            maxRosterRows = 100,
        },
        HighCommand = { allowSelfGrant = false },
    }

    local env = Sandbox.newEnv({
        Config = Config,
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = GetPlayerNameStub,
        print = function() end,
        -- Test-controlled soft dependencies -- see this file's header.
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasPermission = opts.hasPermission, -- deliberately nil by default (type() guard must tolerate absence)
        HasK9Access = opts.hasK9Access,
        GetXP = opts.getXP,
        GetXPTier = opts.getXPTier,
        ApplyK9PedRole = opts.applyK9PedRole,
        ForceRevertK9Appearance = opts.forceRevertK9Appearance,
    })

    Sandbox.loadInto('../server/tablet.lua', env)

    return {
        env = env,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        addPermRow = addPermRow,
        addCertRow = addCertRow,
        permRows = permRows,
        certRows = certRows,
    }
end

--- @param f table
--- @param name string
--- @return function
local function cb(f, name)
    local fn = f.callbacks[name]
    assert(fn, 'callback not registered: ' .. name)
    return fn
end

-- ============================================================================
-- FEATURE GATE: server/tablet.lua registers NOTHING at all when
-- Config.Features.CommandTablet is not true -- matches server/permissions.lua's
-- identical "gate at registration, not just inside the handler" convention.
-- ============================================================================

t.test('Config.Features.CommandTablet == false: none of the four callbacks are registered', function()
    local f = newFixture({ config = { Features = { CommandTablet = false } } })
    t.isNil(f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'])
    t.isNil(f.callbacks['qbx_k9unit:server:tabletRequestRoster'])
    t.isNil(f.callbacks['qbx_k9unit:server:tabletRequestPersonSummary'])
    t.isNil(f.callbacks['qbx_k9unit:server:tabletRequestPersonFeatures'])
    t.isNil(f.callbacks['qbx_k9unit:server:tabletAssignK9Role'])
    t.isNil(f.callbacks['qbx_k9unit:server:tabletRevertK9Ped'])
end)

t.test('Config.Features.CommandTablet == true: all six local callbacks are registered', function()
    local f = newFixture()
    t.isNotNil(f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'])
    t.isNotNil(f.callbacks['qbx_k9unit:server:tabletRequestRoster'])
    t.isNotNil(f.callbacks['qbx_k9unit:server:tabletRequestPersonSummary'])
    t.isNotNil(f.callbacks['qbx_k9unit:server:tabletRequestPersonFeatures'])
    t.isNotNil(f.callbacks['qbx_k9unit:server:tabletAssignK9Role'])
    t.isNotNil(f.callbacks['qbx_k9unit:server:tabletRevertK9Ped'])
end)

-- ============================================================================
-- tabletRequestMyRecord
-- ============================================================================

t.test('tabletRequestMyRecord: an unresolvable caller (no Player/citizenid) fails closed', function()
    local f = newFixture()
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(999)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestMyRecord: everyoneCanViewOwnRecord == false denies a non-high-command caller', function()
    local f = newFixture({
        config = {
            Features = { CommandTablet = true },
            FeatureControl = { everyoneCanViewOwnRecord = false },
            Permissions = { ['k9.access'] = { label = 'x' } },
        },
    })
    f.registerPlayer(1, 'VIEWER1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(1)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestMyRecord: everyoneCanViewOwnRecord == false does NOT deny a high-command caller', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            FeatureControl = { everyoneCanViewOwnRecord = false },
            Permissions = { ['k9.access'] = { label = 'x' } },
        },
    })
    f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(1)
    t.isTrue(result.ok)
    t.isTrue(result.viewer.isHighCommand)
end)

t.test('tabletRequestMyRecord: SECURITY -- never trusts a client-supplied identity; resolves everything from `source`', function()
    local f = newFixture({ isHighCommand = function(source) return source == 1 end })
    f.registerPlayer(1, 'REAL-CALLER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'SOMEONE-ELSE', { name = 'police', grade = { level = 1 } })
    -- The callback signature is (source) only -- there is no citizenid
    -- argument to spoof at all; this test documents that fact by asserting
    -- the returned viewer identity always matches the resolved SOURCE.
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(1)
    t.equals(result.viewer.citizenid, 'REAL-CALLER')
    local result2 = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(2)
    t.equals(result2.viewer.citizenid, 'SOMEONE-ELSE')
    t.isFalse(result2.viewer.isHighCommand)
end)

t.test('tabletRequestMyRecord: effectivePermissions -- an explicit k9_permissions grant row qualifies', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'GRANTEE', { name = 'police', grade = { level = 1 } })
    f.addPermRow('GRANTEE', 'k9.audit', 'HC', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.audit' then found = true end
    end
    t.isTrue(found, 'an explicit k9.audit grant must appear in effectivePermissions')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- legacy certifierGrade rank qualifies for k9.certify without any grant', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then found = true end
    end
    t.isTrue(found)
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a grade ONE BELOW certifierGrade does NOT qualify', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'LOWRANK', { name = 'police', grade = { level = 3 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    for _, key in ipairs(result.viewer.effectivePermissions) do
        t.isFalse(key == 'k9.certify', 'k9.certify must not be present for a below-threshold rank')
    end
end)

t.test('tabletRequestMyRecord: certifications array has ONE ROW PER CONFIGURED DEPARTMENT, including ones never held', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.equals(#result.certifications, 2) -- police + sheriff, both configured
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.active)
    t.equals(byDept.police.grantedBy, 'GRANTER1')
    t.isFalse(byDept.sheriff.active)
    t.isNil(byDept.sheriff.grantedBy)
end)

t.test('tabletRequestMyRecord: xp/tierLabel are nil when XPProgression is off', function()
    local f = newFixture({
        getXP = function() return 500 end,
        getXPTier = function() return { label = 'Trained K9' } end,
        config = {
            Features = { CommandTablet = true, XPProgression = false },
            Departments = {}, Permissions = {}, FeatureControl = {}, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isNil(result.xp)
    t.isNil(result.tierLabel)
end)

t.test('tabletRequestMyRecord: xp/tierLabel are populated when XPProgression is on', function()
    local f = newFixture({
        getXP = function() return 500 end,
        getXPTier = function() return { label = 'Trained K9' } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.equals(result.xp, 500)
    t.equals(result.tierLabel, 'Trained K9')
end)

-- ----------------------------------------------------------------------
-- myFeatures STATE RESOLUTION -- LOAD-BEARING: exact precedence order.
-- ----------------------------------------------------------------------

t.test('myFeatures: a globally-disabled feature reports global_off regardless of anything else', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = false },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CIT1', 'feature.BiteAndHold', 'HC', true) -- even WITH a grant
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'global_off')
end)

t.test('myFeatures: an explicit block row wins over everything below it (has access, no grant needed)', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CIT1', 'block.LeashMechanics', 'HC', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'blocked')
end)

t.test('myFeatures: lacking K9 access resolves not_certified (feature on, not blocked, no grant needed)', function()
    local f = newFixture({
        hasK9Access = function() return false end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true }, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'not_certified')
end)

t.test('myFeatures: RequireGrant-listed feature with K9 access but no grant resolves requires_grant_missing', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'requires_grant_missing')
end)

t.test('myFeatures: RequireGrant-listed feature WITH the grant, K9 access, unblocked resolves available', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CIT1', 'feature.BiteAndHold', 'HC', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'available')
end)

t.test('myFeatures: a feature with NO RequireGrant entry, K9 access, unblocked resolves available with no grant needed', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true }, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'available')
end)

t.test('myFeatures: DYNAMIC LIST -- a feature key with no code-level awareness at all still appears and resolves correctly', function()
    -- Proves server/tablet.lua reads Config.Features live, not a hardcoded
    -- Lua-literal list -- the owner's own explicit mid-pass requirement.
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, SomeBrandNewFeatureNoOneToldTabletAbout = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true }, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do
        if entry.key == 'SomeBrandNewFeatureNoOneToldTabletAbout' then row = entry end
    end
    t.isNotNil(row, 'a feature key never referenced anywhere in server/tablet.lua must still be rendered, purely from Config.Features')
    t.equals(row.state, 'available')
end)

-- ============================================================================
-- tabletRequestRoster
-- ============================================================================

t.test('tabletRequestRoster: an unresolvable caller fails closed', function()
    local f = newFixture()
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(999, '')
    t.isFalse(result.ok)
end)

t.test('tabletRequestRoster: SECURITY -- a caller with no console access (no grant, no rank, not high command) is denied', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestRoster: a high-command caller is granted console access with an empty roster', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 0)
    t.isFalse(result.truncated)
end)

t.test('tabletRequestRoster: a caller with a plain k9.certify RANK (no grant, not high command) also gets console access', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CERTOFFICER', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
end)

t.test('tabletRequestRoster: returns one row per active certification, resolves name/xp/tier', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        getXP = function(citizenid) return citizenid == 'K9-1' and 750 or 0 end,
        getXPTier = function() return { label = 'Trained K9' } end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } }, { firstname = 'Rex', lastname = 'Shepherd' })
    f.addCertRow('K9-1', 'police', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 1)
    t.equals(result.rows[1].citizenid, 'K9-1')
    t.equals(result.rows[1].name, 'Rex Shepherd')
    t.equals(result.rows[1].departmentLabel, 'Los Santos Police Department')
    t.isTrue(result.rows[1].certified)
    t.equals(result.rows[1].xp, 750)
    t.equals(result.rows[1].tierLabel, 'Trained K9')
end)

t.test('tabletRequestRoster: the free-text query matches by citizenid substring, case-insensitively', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('ALPHA-K9', 'police', 'HC1', true)
    f.addCertRow('BRAVO-K9', 'police', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, 'alpha')
    t.equals(#result.rows, 1)
    t.equals(result.rows[1].citizenid, 'ALPHA-K9')
end)

t.test('ROSTER CLAMP: Config.CommandTablet.maxRosterRows <= 0 falls back to the default, never "unlimited"', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = {}, FeatureControl = {},
            CommandTablet = { maxRosterRows = 0 }, -- the footgun value
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 150 do
        f.addCertRow(('ROSTER%03d'):format(i), 'police', 'HC1', true)
    end
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 100, 'a non-positive maxRosterRows must fall back to the documented default (100), never mean unlimited')
    t.isTrue(result.truncated)
end)

t.test('ROSTER CLAMP: more active certifications than maxRosterRows truncates and reports truncated = true', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = {}, FeatureControl = {},
            CommandTablet = { maxRosterRows = 5 },
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 20 do
        f.addCertRow(('ROSTER%03d'):format(i), 'police', 'HC1', true)
    end
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 5)
    t.isTrue(result.truncated)
    -- 'tablet.roster_truncated_notice' has landed -- truncatedMessage is a
    -- real, locale-resolved string whenever truncated == true.
    t.isNotNil(result.truncatedMessage)
end)

t.test('ROSTER CLAMP: exactly maxRosterRows candidates is NOT reported as truncated', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = {}, FeatureControl = {},
            CommandTablet = { maxRosterRows = 5 },
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 5 do
        f.addCertRow(('ROSTER%03d'):format(i), 'police', 'HC1', true)
    end
    local result = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.equals(#result.rows, 5)
    t.isFalse(result.truncated)
end)

-- ============================================================================
-- tabletRequestPersonSummary
-- ============================================================================

t.test('tabletRequestPersonSummary: SECURITY -- console access is denied for a non-qualifying caller regardless of the target argument', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'NOBODY') -- even targeting themselves
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestPersonSummary: invalid_args for a non-string / empty target citizenid', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, '').error, 'invalid_args')
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, nil).error, 'invalid_args')
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 123).error, 'invalid_args')
end)

t.test('tabletRequestPersonSummary: works for a genuinely OFFLINE target citizenid', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9', 'police', 'HC1', true)
    f.addPermRow('OFFLINE-K9', 'k9.access', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    t.equals(result.target.citizenid, 'OFFLINE-K9')
    t.equals(result.target.name, 'OFFLINE-K9', 'an offline citizenid with no verified name source falls back to the citizenid itself')
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.access' then found = true end end
    t.isTrue(found)
end)

-- ============================================================================
-- tabletRequestPersonFeatures -- HIGH COMMAND ONLY (load-bearing).
-- ============================================================================

t.test('tabletRequestPersonFeatures: LOAD-BEARING -- a non-high-command caller is denied, even one with full console access via a rank/grant', function()
    local f = newFixture({
        hasPermission = function(citizenid, key) return citizenid == 'CERTIFIER' and key == 'k9.certify' end,
    })
    local src = f.registerPlayer(1, 'CERTIFIER', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, 'SOMEONE')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestPersonFeatures: invalid_args for a malformed target', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, '').error, 'invalid_args')
end)

t.test('tabletRequestPersonFeatures: an OFFLINE target with an active certification resolves not_certified == false (available, if unblocked/no-grant-needed)', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = { ['k9.access'] = { label = 'x' } },
            FeatureControl = { RequireGrant = {} },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9', 'police', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'an offline target with a real active certification must resolve K9 access from the DB, never as unknowable')
end)

t.test('tabletRequestPersonFeatures: an OFFLINE target with NO credential at all resolves not_certified', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = { ['k9.access'] = { label = 'x' } },
            FeatureControl = { RequireGrant = {} },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })

    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, 'NEVER-CERTIFIED')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'not_certified')
end)

t.test('tabletRequestPersonFeatures: an ONLINE target reuses the real, live HasK9Access(source) for that target', function()
    local f = newFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function(source) return source == 2 end, -- only the ONLINE target's own source qualifies
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {}, FeatureControl = { RequireGrant = {} }, CommandTablet = {},
        },
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'ONLINE-TARGET', { name = 'police', grade = { level = 1 } })

    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(hcSrc, 'ONLINE-TARGET')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'available')
end)

t.test('tabletRequestPersonFeatures: globallyEnabled/requiresGrant/granted/blocked fields are all reported per-row', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true } },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'block.BiteAndHold', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, 'TARGET1')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isTrue(row.globallyEnabled)
    t.isTrue(row.requiresGrant)
    t.isFalse(row.granted)
    t.isTrue(row.blocked)
    t.equals(row.state, 'blocked')
end)

-- ============================================================================
-- tabletAssignK9Role -- thin wrapper over server/appearance.lua's
-- ApplyK9PedRole. Authorization is ApplyK9PedRole's OWN job (already
-- covered by that file's own test suite) -- these tests only prove the
-- wrapper forwards correctly and degrades gracefully when the primitive
-- is absent.
-- ============================================================================

t.test('tabletAssignK9Role: invalid_args for a missing/empty citizenid or model', function()
    local f = newFixture({ applyK9PedRole = function() return true, 'ok' end })
    t.equals(cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, '', 'a_c_shepherd').error, 'invalid_args')
    t.equals(cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, 'CIT1', '').error, 'invalid_args')
    t.equals(cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, 'CIT1', nil).error, 'invalid_args')
end)

t.test('tabletAssignK9Role: not_available when server/appearance.lua is not loaded', function()
    local f = newFixture() -- no applyK9PedRole stub -- type(fn) == 'function' guard must trip
    local result = cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
end)

t.test('tabletAssignK9Role: forwards ApplyK9PedRole success verbatim', function()
    local calls = {}
    local f = newFixture({ applyK9PedRole = function(granterSrc, citizenid, model)
        calls[#calls + 1] = { granterSrc = granterSrc, citizenid = citizenid, model = model }
        return true, 'ok'
    end })
    local result = cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isTrue(result.ok)
    t.equals(#calls, 1)
    t.equals(calls[1].granterSrc, 1)
    t.equals(calls[1].citizenid, 'CIT1')
    t.equals(calls[1].model, 'a_c_shepherd')
end)

t.test('tabletAssignK9Role: forwards ApplyK9PedRole failure outcome (e.g. denied -- caller was not high command) verbatim', function()
    local f = newFixture({ applyK9PedRole = function() return false, 'denied' end })
    local result = cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
end)

t.test('tabletAssignK9Role: a persisted_offline success is translated with a real, existing locale message', function()
    local f = newFixture({ applyK9PedRole = function() return true, 'persisted_offline' end })
    local result = cb(f, 'qbx_k9unit:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isTrue(result.ok)
    t.isNotNil(result.message)
end)

-- ============================================================================
-- tabletRevertK9Ped -- THE NO-UNBOUNDED-TRAP action. Unlike tabletAssignK9Role,
-- THIS file's own callback checks IsHighCommand itself (ForceRevertK9Appearance
-- is requested, not yet a self-authorizing function at the time of writing)
-- -- see server/tablet.lua's own header for why.
-- ============================================================================

t.test('tabletRevertK9Ped: LOAD-BEARING -- a non-high-command caller is denied server-side, the underlying revert is never invoked', function()
    local invoked = false
    local f = newFixture({ forceRevertK9Appearance = function() invoked = true; return true, 'ok' end })
    local src = f.registerPlayer(1, 'NOTHC', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRevertK9Ped')(src, 'TARGET1')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isFalse(invoked, 'a denied caller must never reach the actual revert primitive')
end)

t.test('tabletRevertK9Ped: not_available when the underlying primitive is not yet loaded (disclosed, temporary state)', function()
    local f = newFixture({ isHighCommand = function() return true end }) -- no forceRevertK9Appearance stub
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'qbx_k9unit:server:tabletRevertK9Ped')(src, 'TARGET1')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
end)

t.test('tabletRevertK9Ped: a high-command caller reaches the underlying primitive and its result is forwarded, UNCONDITIONALLY of target credential state', function()
    -- This test's own point: the wrapper does NOT check HasK9Access/
    -- HasPermission/certification status on the TARGET at all before
    -- calling through -- see server/tablet.lua's own "NO UNBOUNDED TRAP"
    -- header note. If this test needed a HasK9Access stub to pass, that
    -- would itself be evidence of a reintroduced gate.
    local calls = {}
    local f = newFixture({
        isHighCommand = function() return true end,
        forceRevertK9Appearance = function(granterSrc, citizenid)
            calls[#calls + 1] = { granterSrc = granterSrc, citizenid = citizenid }
            return true, 'ok'
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    -- STILL CERTIFIED on paper -- the revert must still go through.
    f.addCertRow('STILL-CERTIFIED-K9', 'police', 'HC1', true)
    f.addPermRow('STILL-CERTIFIED-K9', 'k9.access', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRevertK9Ped')(src, 'STILL-CERTIFIED-K9')
    t.isTrue(result.ok)
    t.equals(#calls, 1)
    t.equals(calls[1].citizenid, 'STILL-CERTIFIED-K9')
end)

os.exit(t.summary())
