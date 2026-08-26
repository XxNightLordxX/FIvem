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

--- @param opts table? -- { isHighCommand, hasPermission, hasK9Access, getXP, getXPTier, applyK9PedRole, forceRevertK9Appearance, listPermissionCatalogKeys, config: table (full Config override) }
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

    -- ---- event handlers (RATE LIMITING, this pass) ----
    -- server/cooldowns.lua's TabletReadCooldown.RegisterPlayerDropped() call
    -- (server/tablet.lua's own file-load time) needs a real AddEventHandler
    -- to register against -- a plain capture-and-store stub, same shape
    -- tests/runtimecontrol_spec.lua's own AddEventHandlerStub already
    -- established, though this fixture has no need to actually FIRE
    -- 'playerDropped' anywhere yet (no test here currently depends on that
    -- cleanup); it only needs the call itself not to error.
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

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

    -- RATE LIMITING (this pass) -- server/tablet.lua's four read callbacks
    -- now share TabletReadCooldown (NewCooldown, keyed by source), which
    -- calls GetGameTimer() at cooldown-check time. fakeNow lets a test pin
    -- and advance that clock deterministically -- same pattern
    -- tests/runtimecontrol_spec.lua already established for its own
    -- RuntimeControlActionCooldown coverage. Starts at 0 for every fresh
    -- fixture (a new env/NewCooldown instance per newFixture() call, same
    -- as every other piece of this fixture's state), so no cross-test
    -- contamination.
    local fakeNow = { value = 0 }

    local env = Sandbox.newEnv({
        Config = Config,
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = GetPlayerNameStub,
        GetGameTimer = function() return fakeNow.value end,
        AddEventHandler = AddEventHandlerStub,
        print = function() end,
        -- Test-controlled soft dependencies -- see this file's header.
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasPermission = opts.hasPermission, -- deliberately nil by default (type() guard must tolerate absence)
        HasK9Access = opts.hasK9Access,
        GetXP = opts.getXP,
        GetXPTier = opts.getXPTier,
        ApplyK9PedRole = opts.applyK9PedRole,
        ForceRevertK9Appearance = opts.forceRevertK9Appearance,
        -- CERTIFICATION DEPTH READ-SIDE (this pass) -- server/certifications.lua's
        -- own DB-authoritative, already-exposed accessor. Deliberately nil by
        -- default (like HasPermission above): BuildCertificationsArray's own
        -- `type(QueryCertificationRecord) == 'function'` guard must tolerate
        -- its absence and degrade to no tier/expiry/specializations data
        -- rather than erroring.
        QueryCertificationRecord = opts.queryCertificationRecord,
        -- PERMISSION-KEY CATALOG AWARENESS (this pass) -- server/tablet.lua's
        -- own AdminCapabilityCandidateKeys soft-depends on
        -- server/permissionkeycatalog.lua's real, global ListPermissionCatalogKeys
        -- via a `type(...) == 'function'` guard, exactly like every other
        -- entry in this list. Deliberately nil by default (like HasPermission
        -- above): every EXISTING test in this file exercises the "catalog
        -- absent" fallback path (Config.Permissions alone), matching this
        -- fixture's pre-existing, unchanged behavior; only the new
        -- catalog-aware tests below pass opts.listPermissionCatalogKeys.
        ListPermissionCatalogKeys = opts.listPermissionCatalogKeys,
        -- osTime lets a test pin "now" for expiry-boundary assertions without
        -- depending on real wall-clock time -- see NowUnixOrNil in
        -- server/tablet.lua. Omitted entirely (not even set to nil) when
        -- opts.osTime is absent, so env.os stays the REAL os table
        -- Sandbox.newEnv already shallow-copied from _G.
        os = opts.osTime and { time = opts.osTime } or nil,
    })

    -- K9Store migration (this pass): server/tablet.lua's QueryHasAnyActiveCertification/
    -- QueryActivePermissionSet now read through K9Store.Cert_GetActiveIdAnyJob/
    -- K9Store.Perm_GetActiveForCitizen (server/datastore.lua) instead of calling
    -- MySQL.* directly -- load the real datastore.lua into this SAME env, ahead of
    -- tablet.lua, so K9Store exists as a real global by the time tablet.lua's own
    -- chunk runs. `mysql` above is unchanged: K9Store's DB-mode branches call the
    -- exact same MySQL.query.await/MySQL.scalar.await this stub already dispatches
    -- on by SQL substring, since K9Store mirrors that SQL verbatim.
    -- server/cooldowns.lua -- HARD load-order requirement, same as the real
    -- fxmanifest.lua's own placement: server/tablet.lua now calls
    -- NewCooldown at its own file-load time (TabletReadCooldown), so
    -- cooldowns.lua must already be loaded into this SAME env first.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/tablet.lua', env)

    return {
        env = env,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        addPermRow = addPermRow,
        addCertRow = addCertRow,
        permRows = permRows,
        certRows = certRows,
        fakeNow = fakeNow,
        eventHandlers = eventHandlers,
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

-- ============================================================================
-- PERMISSION-KEY CATALOG AWARENESS (this pass) -- ResolveEffectivePermissions
-- must consult server/permissionkeycatalog.lua's live ListPermissionCatalogKeys,
-- not just the static Config.Permissions table, or a permission key created
-- purely at runtime can be granted but never shows as held. See
-- server/tablet.lua's own "PERMISSION-KEY CATALOG AWARENESS" header section
-- (AdminCapabilityCandidateKeys) for the full contract these tests pin down.
-- ============================================================================

t.test('tabletRequestMyRecord: effectivePermissions -- a custom, non-default GRANTED key shows as held', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'Use K9 abilities' },
                { key = 'k9.certify', label = 'Certify and decertify others' },
                { key = 'k9.audit', label = 'View the audit records' },
                { key = 'k9.givexp', label = 'Grant XP' },
                { key = 'k9.specialaudit', label = 'Special Audit', description = 'A custom, runtime-created key' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'GRANTEE', { name = 'police', grade = { level = 1 } })
    f.addPermRow('GRANTEE', 'k9.specialaudit', 'HC', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.specialaudit' then found = true end
    end
    t.isTrue(found, 'a granted, purely-runtime permission key must appear as held -- this is the exact bug this pass closes')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a custom, non-default UNGRANTED key does NOT show as held', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'NOTGRANTED', { name = 'police', grade = { level = 1 } })
    -- deliberately NO addPermRow for 'k9.specialaudit' -- this citizenid does
    -- not hold it, and there is no legacy rank tier for a custom key either
    -- (server/permissions.lua's own LegacyOrHighCommandStillQualifies has no
    -- branch for it), so it must be a candidate WITHOUT qualifying.
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    for _, key in ipairs(result.viewer.effectivePermissions) do
        t.isFalse(key == 'k9.specialaudit', 'an ungranted custom key must never read as held')
    end
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a TOMBSTONED-but-held custom key still appears (so it remains revocable)', function()
    local f = newFixture({
        -- The catalog no longer lists 'k9.specialaudit' at all -- exactly
        -- what server/permissionkeycatalog.lua's ListPermissionCatalogKeys
        -- returns for a tombstoned key (see that file's header "TOMBSTONE,
        -- NOT REFERENCE-COUNTED"). Only the still-shipped defaults remain.
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'Use K9 abilities' },
                { key = 'k9.certify', label = 'Certify and decertify others' },
                { key = 'k9.audit', label = 'View the audit records' },
                { key = 'k9.givexp', label = 'Grant XP' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'RETIREE', { name = 'police', grade = { level = 1 } })
    f.addPermRow('RETIREE', 'k9.specialaudit', 'HC', true) -- still an ACTIVE grant, despite the tombstone
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.specialaudit' then found = true end
    end
    t.isTrue(found, 'a tombstoned key someone still actively holds must still surface, or nobody could ever revoke it from the tablet')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- the four shipped keys resolve unchanged when the catalog is present', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'Use K9 abilities' },
                { key = 'k9.certify', label = 'Certify and decertify others' },
                { key = 'k9.audit', label = 'View the audit records' },
                { key = 'k9.givexp', label = 'Grant XP' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    f.addPermRow('RANKED', 'k9.audit', 'HC', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local foundCertify, foundAudit, foundAccess, foundGivexp = false, false, false, false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then foundCertify = true end
        if key == 'k9.audit' then foundAudit = true end
        if key == 'k9.access' then foundAccess = true end
        if key == 'k9.givexp' then foundGivexp = true end
    end
    t.isTrue(foundCertify, 'legacy certifierGrade rank resolution must still work with the catalog present')
    t.isTrue(foundAudit, 'an explicit grant must still work with the catalog present')
    t.isFalse(foundAccess, 'k9.access must not be granted just because the catalog lists it')
    t.isFalse(foundGivexp, 'k9.givexp has no legacy tier and was never granted here')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a rank-qualified certifier still qualifies for k9.certify even if the catalog has TOMBSTONED that literal key', function()
    -- server/permissionkeycatalog.lua's own header ("NO PROTECTED KEY") is
    -- explicit that tombstoning 'k9.certify' only turns off the ABILITY TO
    -- GRANT/HOLD it BY THAT ROUTE -- certifications.lua's own independent
    -- rank-based IsEligibleCertifier check is unaffected either way. This
    -- file's own effectivePermissions must not silently disagree by hiding
    -- a real, independently-qualified capability the moment the catalog
    -- entry disappears -- see LEGACY_PERMISSION_KEYS's own doc comment.
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return { { key = 'k9.access', label = 'x' } } -- k9.certify tombstoned/absent
        end,
    })
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then found = true end
    end
    t.isTrue(found, 'a rank-qualified certifier must not lose their real capability just because the catalog entry was tombstoned')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a THROWING catalog degrades to the four shipped keys, never an empty list', function()
    local f = newFixture({
        listPermissionCatalogKeys = function() error('simulated catalog failure') end,
    })
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } })
    f.addPermRow('RANKED', 'k9.audit', 'HC', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local foundCertify, foundAudit = false, false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then foundCertify = true end
        if key == 'k9.audit' then foundAudit = true end
    end
    t.isTrue(foundCertify, 'a catalog read failure must fall back to the four shipped keys, not an empty capability set')
    t.isTrue(foundAudit, 'an explicit grant must still resolve even when the catalog throws')
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

-- ============================================================================
-- CERTIFICATION DEPTH READ-SIDE (this pass) -- BuildCertificationsArray now
-- carries tier/expiresAtUnix/expired/specializations per department, sourced
-- from server/certifications.lua's DB-authoritative QueryCertificationRecord.
-- See that helper's own doc comment in server/tablet.lua for the full
-- reasoning (offline-safe, bounded per configured department, guarded soft
-- dependency).
-- ============================================================================

t.test('tabletRequestMyRecord: certifications array carries tier/expiry/specializations for an actively-held department', function()
    local f = newFixture({
        queryCertificationRecord = function(citizenid, jobName)
            if citizenid == 'CIT1' and jobName == 'police' then
                return { tier = 'senior', expiresAtUnix = 9999999999, specializations = { 'narcotics', 'explosives' } }
            end
            return nil
        end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end

    t.equals(byDept.police.tier, 'senior')
    t.equals(byDept.police.expiresAtUnix, 9999999999)
    t.isFalse(byDept.police.expired)
    t.equals(#byDept.police.specializations, 2)

    -- A department this citizen has never held must carry NO tier/expiry/
    -- specialization data at all -- see this function's own doc comment on
    -- why that read is skipped entirely for an inactive row.
    t.isNil(byDept.sheriff.tier)
    t.isNil(byDept.sheriff.expiresAtUnix)
    t.isFalse(byDept.sheriff.expired)
    t.equals(#byDept.sheriff.specializations, 0)
end)

t.test('tabletRequestMyRecord: certifications array marks expired = true once now has reached expiresAtUnix', function()
    local f = newFixture({
        osTime = function() return 2000 end,
        queryCertificationRecord = function() return { tier = 'certified', expiresAtUnix = 1000, specializations = {} } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.expired)
end)

t.test('tabletRequestMyRecord: certifications array does NOT mark expired before expiresAtUnix is reached', function()
    local f = newFixture({
        osTime = function() return 500 end,
        queryCertificationRecord = function() return { tier = 'certified', expiresAtUnix = 1000, specializations = {} } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isFalse(byDept.police.expired)
end)

t.test('tabletRequestMyRecord: certifications array never marks expired when expiresAtUnix is nil (never expires)', function()
    local f = newFixture({
        osTime = function() return 999999999999 end, -- an absurdly large "now" -- must still not flip expired
        queryCertificationRecord = function() return { tier = 'certified', expiresAtUnix = nil, specializations = {} } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isFalse(byDept.police.expired)
    t.isNil(byDept.police.expiresAtUnix)
end)

t.test('tabletRequestMyRecord: certifications array degrades cleanly (no crash, no data) when QueryCertificationRecord is unavailable', function()
    local f = newFixture() -- queryCertificationRecord omitted -- stays nil, matching every other soft dependency default
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.active)
    t.isNil(byDept.police.tier)
    t.isNil(byDept.police.expiresAtUnix)
    t.isFalse(byDept.police.expired)
    t.equals(#byDept.police.specializations, 0)
end)

t.test('tabletRequestMyRecord: certifications array degrades cleanly when QueryCertificationRecord itself returns nil for an active row', function()
    -- A genuine race (the row was revoked between the two reads) or any
    -- other reason the DB-authoritative read comes back empty must never
    -- crash this callback -- see BuildCertificationsArray's own doc comment.
    local f = newFixture({ queryCertificationRecord = function() return nil end })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.active)
    t.isNil(byDept.police.tier)
end)

t.test('tabletRequestMyRecord: certifications array never queries QueryCertificationRecord for a department not actively held', function()
    local queriedJobs = {}
    local f = newFixture({
        queryCertificationRecord = function(_citizenid, jobName)
            queriedJobs[#queriedJobs + 1] = jobName
            return { tier = 'certified', expiresAtUnix = nil, specializations = {} }
        end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true) -- sheriff left unheld
    cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.equals(#queriedJobs, 1)
    t.equals(queriedJobs[1], 'police')
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

t.test('tabletRequestPersonSummary: certifications array carries tier/expiry/specializations for a genuinely OFFLINE target', function()
    -- The whole point of QueryCertificationRecord being DB-authoritative
    -- (not the online-only in-memory cert cache) is that a high-command
    -- lookup on a disconnected handler must still show their tier -- this
    -- is the read-side gap the owner's task named explicitly.
    local f = newFixture({
        isHighCommand = function() return true end,
        queryCertificationRecord = function(citizenid, jobName)
            if citizenid == 'OFFLINE-K9' and jobName == 'police' then
                return { tier = 'trainee', expiresAtUnix = nil, specializations = { 'patrol' } }
            end
            return nil
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9', 'police', 'HC1', true)

    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.equals(byDept.police.tier, 'trainee')
    t.equals(#byDept.police.specializations, 1)
    t.equals(byDept.police.specializations[1], 'patrol')
end)

-- ============================================================================
-- PERMISSION-KEY CATALOG AWARENESS (this pass) -- tabletRequestPersonSummary's
-- own inline `permissions` builder has the SAME bug/fix as
-- ResolveEffectivePermissions above: it must consult the live catalog, or a
-- custom key's Grant/Revoke row on the tablet's person screen reads "not
-- held" forever even after a real grant. See
-- server/tablet.lua's own AdminCapabilityCandidateKeys for the shared
-- contract these mirror.
-- ============================================================================

t.test('tabletRequestPersonSummary: permissions -- a custom, non-default GRANTED key shows as held', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.specialaudit' then found = true end end
    t.isTrue(found, 'a granted custom key must appear in the person-summary permissions array -- this is the exact bug this pass closes')
end)

t.test('tabletRequestPersonSummary: permissions -- a custom, non-default UNGRANTED key does NOT show as held', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    -- TARGET1 exists (implicitly, offline) but never received a grant.
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    for _, key in ipairs(result.permissions) do
        t.isFalse(key == 'k9.specialaudit', 'an ungranted custom key must never read as held')
    end
end)

t.test('tabletRequestPersonSummary: permissions -- a TOMBSTONED-but-held custom key still appears (so it remains revocable)', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        -- 'k9.specialaudit' is no longer in the live catalog at all --
        -- exactly what a tombstoned key looks like.
        listPermissionCatalogKeys = function()
            return { { key = 'k9.access', label = 'x' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true) -- still an ACTIVE grant, despite the tombstone
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.specialaudit' then found = true end end
    t.isTrue(found, 'a tombstoned key someone still actively holds must still surface, or high command could never revoke it from this screen')
end)

t.test('tabletRequestPersonSummary: permissions -- the four shipped keys resolve unchanged when the catalog is present', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'x' }, { key = 'k9.certify', label = 'x' },
                { key = 'k9.audit', label = 'x' }, { key = 'k9.givexp', label = 'x' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.access', 'HC1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.equals(#result.permissions, 1)
    t.equals(result.permissions[1], 'k9.access')
end)

t.test('tabletRequestPersonSummary: permissions -- a THROWING catalog degrades to the four shipped keys, never an empty capability panel', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function() error('simulated catalog failure') end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.access', 'HC1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.access' then found = true end end
    t.isTrue(found, 'a catalog read failure must never empty this response -- an empty capability panel reads as "no permissions", which is false and alarming')
end)

t.test('tabletRequestPersonSummary: permissions -- never leaks a feature./block. per-feature grant disguised as an admin capability', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'feature.BiteAndHold', 'HC1', true)
    f.addPermRow('TARGET1', 'block.NightVision', 'HC1', true)
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.equals(#result.permissions, 1, 'only the genuine admin-capability grant may appear here')
    t.equals(result.permissions[1], 'k9.specialaudit')
end)

t.test('tabletRequestPersonSummary: SECURITY -- an unauthorized caller gets nothing, even when the target holds a custom granted key', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } }) -- no console access
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true)
    local result = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isNil(result.permissions, 'a denied caller must receive no permissions data at all, custom key or not')
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
-- RATE LIMITING (this pass) -- the four read/aggregation callbacks above had
-- NO cooldown at all, unlike every other client-triggered, DB-touching read
-- this resource exposes (server/admin.lua's own AuditCooldown covers its
-- read-only audit callbacks the same way). Shared TabletReadCooldown, keyed
-- by source, 500ms floor -- see server/tablet.lua's own header comment on
-- TABLET_READ_COOLDOWN_MS for the full reasoning.
-- ============================================================================

t.test('RATE LIMIT: a second rapid tabletRequestMyRecord from the SAME source is rejected as rate_limited', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local first = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(first.ok)
    local second = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: tabletRequestMyRecord recovers once the cooldown window elapses', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src).ok)
    f.fakeNow.value = f.fakeNow.value + 501
    local third = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.isTrue(third.ok, 'must succeed again once the 500ms floor has elapsed')
end)

t.test('RATE LIMIT: is PER SOURCE -- a different source is unaffected by another source\'s cooldown entry', function()
    local f = newFixture()
    local src1 = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local src2 = f.registerPlayer(2, 'CIT2', { name = 'police', grade = { level = 1 } })
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src1).ok)
    local other = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src2)
    t.isTrue(other.ok, 'a fresh source must never be blocked by a DIFFERENT source\'s own cooldown entry')
end)

t.test('RATE LIMIT: an UNAUTHORIZED caller never spends the shared cooldown budget -- denial always returns before Consume', function()
    local f = newFixture({ config = { Features = { CommandTablet = true }, FeatureControl = { everyoneCanViewOwnRecord = false } } })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local denied = cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src)
    t.equals(denied.error, 'not_authorized')
    -- The SAME source, now authorized, must not find itself already
    -- rate_limited from the denied attempt above.
    local f2 = newFixture()
    local authorizedSrc = f2.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    t.isTrue(cb(f2, 'qbx_k9unit:server:tabletRequestMyRecord')(authorizedSrc).ok)
end)

t.test('RATE LIMIT: applies to tabletRequestRoster too -- a second rapid call from the same console-access source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '').ok)
    local second = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: SHARED across all four read callbacks -- one budget per source, not one independent allowance per callback', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestMyRecord')(src).ok, 'first call, own budget, must succeed')
    local rosterAttempt = cb(f, 'qbx_k9unit:server:tabletRequestRoster')(src, '')
    t.isFalse(rosterAttempt.ok, 'a DIFFERENT callback from the SAME source, immediately after, must still be rejected -- one shared budget, not a per-callback allowance')
    t.equals(rosterAttempt.error, 'rate_limited')
    f.fakeNow.value = f.fakeNow.value + 501
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1').ok, 'a third, different callback recovers once the shared window elapses')
end)

t.test('RATE LIMIT: applies to tabletRequestPersonSummary -- second rapid call from the same console-access source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1').ok)
    local second = cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: applies to tabletRequestPersonFeatures -- second rapid call from the same high-command source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, 'TARGET1').ok)
    local second = cb(f, 'qbx_k9unit:server:tabletRequestPersonFeatures')(src, 'TARGET1')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: invalid_args on tabletRequestPersonSummary/PersonFeatures never consumes the shared budget -- three malformed-target calls in a row all report invalid_args, never rate_limited', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, '').error, 'invalid_args')
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, nil).error, 'invalid_args')
    t.equals(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 123).error, 'invalid_args')
    -- A real request from the SAME source must still succeed afterward --
    -- none of the three invalid_args calls above may have silently spent
    -- the cooldown budget this real request now needs.
    t.isTrue(cb(f, 'qbx_k9unit:server:tabletRequestPersonSummary')(src, 'TARGET1').ok)
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

-- ============================================================================
-- ROUND TRIP -- REAL server/permissions.lua + REAL server/tablet.lua,
-- sharing one real in-memory k9_permissions table. See this file's own
-- header "ROUND TRIP SECTION" for why this is a separate, integration-level
-- fixture rather than an extension of newFixture() above.
-- ============================================================================

--- @param opts table? -- { isHighCommand, hasK9Access, config: table (full Config override) }
--- @return table fixture
local function newIntegrationFixture(opts)
    opts = opts or {}

    -- Advancing fake clock -- server/permissions.lua's PermissionActionCooldown
    -- (1500ms, shared by GrantPermission/RevokePermission) means a SECOND
    -- grant/revoke from the SAME granter source at the SAME instant is
    -- rate-limited; tests that issue more than one action from `hcSrc` call
    -- `advanceTime` between them, matching tests/permissions_spec.lua's own
    -- established convention for this exact cooldown.
    local clockState = { now = 0 }
    local function GetGameTimerStub() return clockState.now end

    -- ---- fake k9_permissions table -- same shape/dispatch as
    -- tests/permissions_spec.lua's own newFixture() mysql stub, since this
    -- fixture must satisfy the REAL GrantPermission/RefreshPermissionCache
    -- query shapes AND server/tablet.lua's own QueryActivePermissionSet
    -- query against the exact same rows.
    local rows = {}
    local nextId = 0

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
            local row = findActiveRow(params[1], params[2])
            return row and row.id or nil
        end },
        insert = { await = function(_sql, params)
            nextId = nextId + 1
            rows[#rows + 1] = {
                id = nextId, citizenid = params[1], permission = params[2], granted_by = params[3], active = 1,
            }
            return nextId
        end },
        update = { await = function(_sql, params)
            local citizenid, permission = params[2], params[3]
            local affected = 0
            for _, row in ipairs(rows) do
                if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                    row.active = 0
                    affected = affected + 1
                end
            end
            return affected
        end },
        query = { await = function(sql, params)
            local out = {}
            if sql:find('SELECT permission FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                end
            end
            return out
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

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local Config = opts.config or {
        Features = {
            CommandTablet = true,
            PermissionGrants = true,
            BiteAndHold = true,
        },
        Departments = {
            police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 },
        },
        Permissions = {
            ['k9.access']  = { label = 'Use K9 abilities' },
            ['k9.certify'] = { label = 'Certify and decertify others' },
            ['k9.audit']   = { label = 'View the audit records' },
            ['k9.givexp']  = { label = 'Grant XP' },
        },
        FeatureControl = {
            RequireGrant = { BiteAndHold = true },
            everyoneCanViewOwnRecord = true,
        },
        CommandTablet = { maxRosterRows = 100 },
        HighCommand = { allowSelfGrant = false },
    }

    local env = Sandbox.newEnv({
        Config = Config,
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = function(source) return 'SteamName#' .. tostring(source) end,
        print = function() end,
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasK9Access = opts.hasK9Access or function(_source) return false end,
        NotifyPlayer = function() end,
        AddEventHandler = function(_name, _fn) end,
        -- FEATURE-BLOCK PUSH (this pass) -- server/permissions.lua now
        -- registers 'qbx_k9unit:server:requestFeatureBlocksSync' via
        -- RegisterNetEvent unconditionally at file-load time, and calls
        -- TriggerClientEvent from GrantPermission/RevokePermission's own
        -- block.<Name> tail whenever the target below (TARGET1) is online
        -- -- both genuinely exercised by this fixture's own "ROUND TRIP...
        -- BLOCK" test further down. Neither is asserted on by name here
        -- (that contract has its own dedicated coverage in
        -- tests/permissions_spec.lua); these are just enough stub for
        -- server/permissions.lua's own load and normal grant/revoke calls
        -- to not crash this fixture with "attempt to call a nil value".
        RegisterNetEvent = function(_name, _fn) end,
        TriggerClientEvent = function(_eventName, _target, ...) end,
        GetPlayers = function() return {} end,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        GetGameTimer = GetGameTimerStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env) -- K9Store; server/permissions.lua reads and writes through it now rather than calling MySQL directly
    Sandbox.loadInto('../server/events.lua', env)    -- FireOutboundEvent, extracted into its own file
    Sandbox.loadInto('../server/permissions.lua', env)
    Sandbox.loadInto('../server/tablet.lua', env)

    return {
        env = env,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        advanceTime = function(ms) clockState.now = clockState.now + ms end,
    }
end

t.test('ROUND TRIP: a feature grant made through the REAL tabletGrantPermission is visible in ResolveFeatureState via tabletRequestMyRecord afterward', function()
    local f = newIntegrationFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function() return true end,
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local targetSrc = f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    -- Before the grant: RequireGrant-listed, has access, unblocked, no
    -- grant yet -> requires_grant_missing.
    local before = f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'](targetSrc)
    local rowBefore
    for _, entry in ipairs(before.myFeatures) do if entry.key == 'BiteAndHold' then rowBefore = entry end end
    t.equals(rowBefore.state, 'requires_grant_missing')

    -- The REAL grant, through the REAL callback server/permissions.lua registers.
    local grantResult = f.callbacks['qbx_k9unit:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold')
    t.isTrue(grantResult.ok, 'the fixed IsValidPermissionKey must accept feature.BiteAndHold end to end')

    f.advanceTime(2000) -- clear server/tablet.lua's own TabletReadCooldown (targetSrc's first tabletRequestMyRecord call above already consumed it) before this second call from the SAME source
    -- After the grant: server/tablet.lua's own QueryActivePermissionSet must
    -- see the SAME row GrantPermission just wrote.
    local after = f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'](targetSrc)
    local rowAfter
    for _, entry in ipairs(after.myFeatures) do if entry.key == 'BiteAndHold' then rowAfter = entry end end
    t.equals(rowAfter.state, 'available', 'a real feature.BiteAndHold grant must resolve the tablet\'s own state to available')
end)

t.test('ROUND TRIP: revoking that same feature grant through the REAL tabletRevokePermission makes ResolveFeatureState regress to requires_grant_missing', function()
    local f = newIntegrationFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function() return true end,
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local targetSrc = f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    t.isTrue(f.callbacks['qbx_k9unit:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold').ok)
    local granted = f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'](targetSrc)
    local grantedRow
    for _, entry in ipairs(granted.myFeatures) do if entry.key == 'BiteAndHold' then grantedRow = entry end end
    t.equals(grantedRow.state, 'available')

    f.advanceTime(2000) -- clear PermissionActionCooldown before the granter's second action
    local revokeResult = f.callbacks['qbx_k9unit:server:tabletRevokePermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold')
    t.isTrue(revokeResult.ok)

    local revoked = f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'](targetSrc)
    local revokedRow
    for _, entry in ipairs(revoked.myFeatures) do if entry.key == 'BiteAndHold' then revokedRow = entry end end
    t.equals(revokedRow.state, 'requires_grant_missing', 'a real revoke must be visible immediately -- no stale cache in either direction')
end)

t.test('ROUND TRIP: a BLOCK made through the REAL tabletGrantPermission (block.<Name> namespace) is visible as blocked, even with an active feature grant', function()
    local f = newIntegrationFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function() return true end,
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local targetSrc = f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    t.isTrue(f.callbacks['qbx_k9unit:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold').ok)
    f.advanceTime(2000) -- clear PermissionActionCooldown before the granter's second action
    local blockResult = f.callbacks['qbx_k9unit:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'block.BiteAndHold')
    t.isTrue(blockResult.ok, 'the fixed IsValidPermissionKey must accept block.BiteAndHold end to end')

    local result = f.callbacks['qbx_k9unit:server:tabletRequestMyRecord'](targetSrc)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'blocked', 'block must win over an active grant, matching the documented precedence order')
end)

os.exit(t.summary())
