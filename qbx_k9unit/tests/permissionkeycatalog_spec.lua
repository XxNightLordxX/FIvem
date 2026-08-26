--[[
    tests/permissionkeycatalog_spec.lua

    Tests server/permissionkeycatalog.lua -- the owner-directed "high
    command can add/relabel/remove PERMISSION KEYS at runtime" pass -- and
    its one seam into server/permissions.lua (IsValidPermissionKey /
    PermissionLabelFor / GrantPermission's new PermissionKeyEditMutex
    acquisition), against the REAL, unmodified production files, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/certtiers_spec.lua
    closely (read that file first -- this one follows its fake-database/
    two-boot conventions) and tests/permissions_spec.lua for the
    k9_permissions grant-row stub shape.

    ONE SHARED FAKE DATABASE covering FOUR real tables this pass's two files
    read/write through K9Store: k9_permission_keys, k9_permission_key_audit
    (this file's own new tables) and k9_permissions (server/permissions.lua's
    existing grant-row table, read via the SAME K9Store instance since both
    production files share one `require`-free Lua env in every fixture
    below) -- mutated by the real production callbacks/functions exactly
    like a real database would be.

    NOT COVERED HERE (disclosed, not silently skipped): the cross-file
    PermissionKeyEditMutex race this pass closes between
    server/permissionkeycatalog.lua's own DeleteKey/UpsertKey and
    server/permissions.lua's GrantPermission is not exercised via two
    ACTUAL concurrent coroutines (this harness has no such primitive,
    identical disclosed limitation as tests/certtiers_spec.lua's own header
    states for TierEditMutex). What IS covered: PermissionKeyEditMutex
    exists, is a real mutex, and GrantPermission genuinely observes it (a
    pre-held lock makes GrantPermission report 'busy' rather than writing a
    grant row) -- proving the wiring is real, not merely declared.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @return table world
local function newWorld()
    return {
        permKeys = {},     -- permission_key -> { label, description, deleted, updated_by }
        permKeyAudit = {}, -- array of { action, permission_key, detail, changed_by }
        grants = {},       -- array of { id, citizenid, permission, granted_by, active }
        nextGrantId = 0,
        forceKeysQueryError = false, -- toggled mid-test for the FAIL-CLOSED section
    }
end

--- @param world table
--- @param citizenid string
--- @param permission string
--- @return table?
local function findActiveGrant(world, citizenid, permission)
    for _, row in ipairs(world.grants) do
        if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
            return row
        end
    end
    return nil
end

--- @param world table
--- @return table mysql
local function makeMysqlStub(world)
    return {
        query = { await = function(sql, params)
            if world.forceKeysQueryError and sql:find('SELECT permission_key, label, description, deleted FROM k9_permission_keys', 1, true) then
                error('simulated k9_permission_keys read failure')
            end
            if sql:find('SELECT permission_key, label, description, deleted FROM k9_permission_keys', 1, true) then
                local out = {}
                for key, row in pairs(world.permKeys) do
                    out[#out + 1] = { permission_key = key, label = row.label, description = row.description, deleted = row.deleted }
                end
                return out
            elseif sql:find('SELECT deleted FROM k9_permission_keys WHERE permission_key = ?', 1, true) then
                local row = world.permKeys[params[1]]
                if row then return { { deleted = row.deleted } } end
                return {}
            elseif sql:find('INSERT INTO k9_permission_keys', 1, true) then
                local key, label, description, updatedBy = params[1], params[2], params[3], params[4]
                local deletedLiteral = sql:find('VALUES (?, ?, ?, 1, ?)', 1, true) and 1 or 0
                world.permKeys[key] = { label = label, description = description, deleted = deletedLiteral, updated_by = updatedBy }
                return {}
            elseif sql:find('INSERT INTO k9_permission_key_audit', 1, true) then
                world.permKeyAudit[#world.permKeyAudit + 1] = { action = params[1], permission_key = params[2], detail = params[3], changed_by = params[4] }
                return {}
            elseif sql:find('SELECT permission FROM k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(world.grants) do
                    if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                end
                return out
            elseif sql:find('SELECT permission, granted_by, granted_at FROM k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(world.grants) do
                    if row.citizenid == params[1] and row.active == 1 then
                        out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = '2026-01-01 00:00:00' }
                    end
                end
                return out
            elseif sql:find('SELECT citizenid, granted_by, granted_at FROM k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(world.grants) do
                    if row.permission == params[1] and row.active == 1 then
                        out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = '2026-01-01 00:00:00' }
                    end
                end
                return out
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.query.await SQL: ' .. tostring(sql))
        end },
        scalar = { await = function(sql, params)
            if sql:find('SELECT id FROM k9_permissions WHERE citizenid = ? AND permission = ? AND active = 1', 1, true) then
                local row = findActiveGrant(world, params[1], params[2])
                return row and row.id or nil
            elseif sql:find('SELECT COUNT(*) FROM k9_permissions WHERE permission = ? AND active = 1', 1, true) then
                local count = 0
                for _, row in ipairs(world.grants) do
                    if row.permission == params[1] and row.active == 1 then count = count + 1 end
                end
                return count
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.scalar.await SQL: ' .. tostring(sql))
        end },
        insert = { await = function(sql, params)
            if sql:find('INSERT INTO k9_permissions', 1, true) then
                world.nextGrantId = world.nextGrantId + 1
                world.grants[#world.grants + 1] = { id = world.nextGrantId, citizenid = params[1], permission = params[2], granted_by = params[3], active = 1 }
                return world.nextGrantId
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.insert.await SQL: ' .. tostring(sql))
        end },
        update = { await = function(sql, params)
            if sql:find('UPDATE k9_permissions SET active = 0', 1, true) then
                local revokedBy, citizenid, permission = params[1], params[2], params[3]
                local affected = 0
                for _, row in ipairs(world.grants) do
                    if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                        row.active = 0
                        row.revoked_by = revokedBy
                        affected = affected + 1
                    end
                end
                return affected
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.update.await SQL: ' .. tostring(sql))
        end },
    }
end

local DEFAULT_PERMISSIONS = {
    ['k9.access']  = { label = 'Use K9 abilities', description = 'x' },
    ['k9.certify'] = { label = 'Certify and decertify others', description = 'x' },
    ['k9.audit']   = { label = 'View the audit records', description = 'x' },
    ['k9.givexp']  = { label = 'Grant XP', description = 'x' },
}

--- @param opts table? -- { world, database, isHighCommand (pass exactly `false`,
---   not merely nil/omitted, to leave IsHighCommand entirely UNDEFINED in the
---   sandbox env -- the strong form of the gating-function-undefined failure
---   mode, distinct from every other caller's isHighCommand, which is always a
---   real, callable function that merely RETURNS false for a non-HC source),
---   permissions, features, loadCatalog (default true) }
--- @return table fixture
local function boot(opts)
    opts = opts or {}
    local world = opts.world or newWorld()

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- HC_SOURCE (100, the constant every test's own isHighCommand stub
    -- authorizes) always resolves to a real player/citizenid by default --
    -- GrantPermission's own granter-resolution step (`exports.qbx_core:
    -- GetPlayer(granterSrc)`) needs this for EVERY call, not just the tests
    -- that care about a specific target. Merged with (never silently
    -- replaced by) whatever `opts.playersBySource` a test supplies, so a
    -- test adding its own TARGET entry does not have to also remember to
    -- re-declare the granter.
    local playersBySource = { [100] = { PlayerData = { citizenid = 'HC_CIT', source = 100 } } }
    for src, p in pairs(opts.playersBySource or {}) do playersBySource[src] = p end
    local playersByCitizenId = {}
    for _, p in pairs(playersBySource) do
        if p.PlayerData and p.PlayerData.citizenid then playersByCitizenId[p.PlayerData.citizenid] = p end
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    -- opts.isHighCommand == false (an explicit false, never merely nil/omitted)
    -- means "never define IsHighCommand in the sandbox env at all" -- see this
    -- function's own doc comment above. Every other caller gets a real, callable
    -- stub (default: always denies).
    local omitIsHighCommand = opts.isHighCommand == false
    local isHighCommand = (not omitIsHighCommand) and (opts.isHighCommand or function() return false end) or nil
    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local Config = {
        Features = opts.features or { PermissionGrants = true, CommandTablet = false, BiteAndHold = true },
        Permissions = opts.permissions or DEFAULT_PERMISSIONS,
        Departments = opts.departments or { police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
        Database = opts.database, -- nil (absent) by default -> real-DB mode, per K9Store's own fail-safe default
    }

    local fakeNow = { value = 0 }
    local envOverrides = {
        GetGameTimer = function() return fakeNow.value end,
        AddEventHandler = AddEventHandlerStub,
        -- server/permissions.lua now unconditionally calls RegisterNetEvent
        -- at file-load time (client/featureblocks.lua's per-person feature
        -- block sync, a separate pass this file does not otherwise
        -- exercise) -- not exercised by these tests, mirrors
        -- tests/permissions_spec.lua's own identical no-op stub.
        RegisterNetEvent = function(_name, _fn) end,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        print = printStub,
        lib = libStub,
        exports = exportsStub,
        MySQL = makeMysqlStub(world),
        NotifyPlayer = NotifyPlayer,
        GetPlayers = function() return opts.onlineSources or {} end,
        Config = Config,
    }
    -- Only added when NOT omitted -- Sandbox.newEnv's own `for key, value in
    -- pairs(overrides)` would otherwise happily set env.IsHighCommand = nil,
    -- which is a no-op in Lua (assigning nil to a table field never creates the
    -- key), so this branch is purely documentation of intent -- but written
    -- explicitly rather than relying on that no-op so a future reader/refactor
    -- never "fixes" this into always assigning a stub.
    if not omitIsHighCommand then
        envOverrides.IsHighCommand = isHighCommand
    end
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    for i = #printedLines, 1, -1 do printedLines[i] = nil end -- discard datastore's own boot-line print

    Sandbox.loadInto('../server/permissions.lua', env)
    if opts.loadCatalog ~= false then
        Sandbox.loadInto('../server/permissionkeycatalog.lua', env)
    end

    local function triggerResourceStart()
        for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
            handler('qbx_k9unit')
        end
    end
    triggerResourceStart()

    return {
        env = env, world = world, callbacks = callbacks, printedLines = printedLines,
        fakeNow = fakeNow, notifyLog = notifyLog, triggerResourceStart = triggerResourceStart,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

--- @param f table
--- @param key string
--- @return table?
local function findCatalogKey(f, key)
    local result = f.callbacks['qbx_k9unit:server:permKeysList'](HC_SOURCE)
    for _, entry in ipairs(result.keys) do
        if entry.key == key then return entry end
    end
    return nil
end

-- ============================================================================
-- SECTION 1 -- registration + AUTHORIZATION
-- ============================================================================

t.test('registration: all three callbacks are registered', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, name in ipairs({
        'qbx_k9unit:server:permKeysList', 'qbx_k9unit:server:permKeysUpsert', 'qbx_k9unit:server:permKeysDelete',
    }) do
        t.isNotNil(f.callbacks[name], name .. ' must always be registered')
    end
end)

t.test('AUTHORIZATION: permKeysList denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysList'](NON_HC_SOURCE)
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('AUTHORIZATION: permKeysUpsert denies a non-high-command source even with a well-formed payload', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](NON_HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.custom'), 'a denied caller must never actually create the key')
end)

t.test('AUTHORIZATION: permKeysDelete denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysDelete'](NON_HC_SOURCE, 'k9.access')
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'), 'a denied delete must not tombstone anything')
end)

t.test('AUTHORIZATION: server-side re-check ignores whatever the caller claims -- IsHighCommand alone decides, never a payload flag', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](NON_HC_SOURCE, { key = 'k9.custom', label = 'Custom', isHighCommand = true, ok = true })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('AUTHORIZATION: FAILS CLOSED when IsHighCommand is entirely UNDEFINED (not merely false) -- all three callbacks, for ANY source including one that would otherwise be high command', function()
    -- The STRONG form: CanManagePermissionKeys' own production guard is
    -- `type(IsHighCommand) == 'function' and IsHighCommand(source)` -- this
    -- proves that guard is real (denies when the global genuinely does not
    -- exist, e.g. a load-order break that left server/highcommand.lua never
    -- loaded), not merely that a stub returning false is honoured. Every
    -- OTHER test in this section only ever proves the weaker "a defined
    -- IsHighCommand that returns false denies" case.
    local f = boot({ isHighCommand = false })
    t.isNil(f.env.IsHighCommand, 'sanity: this fixture genuinely never defines IsHighCommand')

    local listResult = f.callbacks['qbx_k9unit:server:permKeysList'](HC_SOURCE)
    t.isFalse(listResult.ok)
    t.equals(listResult.reason, 'denied')

    local upsertResult = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isFalse(upsertResult.ok)
    t.equals(upsertResult.reason, 'denied')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.custom'), 'an undefined-gate caller must never actually create the key')

    local deleteResult = f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.access')
    t.isFalse(deleteResult.ok)
    t.equals(deleteResult.reason, 'denied')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'), 'an undefined-gate delete must not tombstone anything')
end)

-- ============================================================================
-- SECTION 2 -- default catalog (zero-behavior-change on every pre-this-pass
-- install).
-- ============================================================================

t.test('DEFAULT CATALOG: the four shipped Config.Permissions keys are all known with no tablet edit ever made', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for key in pairs(DEFAULT_PERMISSIONS) do
        t.isTrue(f.env.IsKnownPermissionCatalogKey(key), key .. ' must resolve from Config.Permissions alone')
    end
    t.equals(f.env.GetPermissionCatalogLabel('k9.access'), 'Use K9 abilities')
end)

t.test('DEFAULT CATALOG: an unknown/made-up key is not known', function()
    local f = boot()
    t.isFalse(f.env.IsKnownPermissionCatalogKey('made_up_permission'))
    t.isNil(f.env.GetPermissionCatalogLabel('made_up_permission'))
end)

-- ============================================================================
-- SECTION 3 -- OVERLAY PRECEDENCE: the database wins over Config.Permissions.
-- ============================================================================

t.test('OVERLAY: relabeling a shipped default key through the catalog wins over Config.Permissions -- the key itself is unchanged', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.access', label = 'Operate as a K9', description = 'Renamed by high command' })
    t.isTrue(result.ok)
    t.equals(f.env.GetPermissionCatalogLabel('k9.access'), 'Operate as a K9', 'the DB row must win over the config default')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'))
end)

t.test('OVERLAY: a brand-new, purely-DB-created key validates through IsValidPermissionKey (server/permissions.lua seam)', function()
    -- TARGET_CIT must be registered ONLINE for the HasPermission assertion
    -- below to mean anything -- server/permissions.lua's own PermissionCache
    -- is scoped ONLY to online citizenids (that file's own header "CACHING
    -- / SCOPE"): HasPermission for a citizenid with no cache entry at all
    -- always reads as false regardless of what the DB actually holds, by
    -- design, not a bug in this catalog.
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom_ability', label = 'Custom Ability' })
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.custom_ability'))

    -- HasPermission (server/permissions.lua) is the real proof this seam
    -- actually reaches the authorization root, not merely this file's own
    -- accessor -- GrantPermission below only succeeds if IsValidPermissionKey
    -- accepts the key.
    local ok = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.custom_ability')
    t.isTrue(ok, 'a purely-DB-created permission key must be grantable once added')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.custom_ability'))
end)

t.test('OVERLAY: PermissionLabelFor (used in the grant-notify message) reflects the LIVE catalog label, not the stale Config.Permissions one', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.access', label = 'Operate as a K9' })
    f.fakeNow.value = f.fakeNow.value + 2000

    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    local lastNotify = f.notifyLog[#f.notifyLog]
    t.isNotNil(lastNotify)
    t.contains(lastNotify.message, 'Operate as a K9', 'the notify text must use the RELABELED name, not the original Config.Permissions label')
end)

-- ============================================================================
-- SECTION 4 -- TOMBSTONE (not reference-counted -- see this file's own
-- header "TOMBSTONE, NOT REFERENCE-COUNTED").
-- ============================================================================

t.test('TOMBSTONE: deleting a key excludes it from the live catalog immediately, with no reference-count refusal', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    -- Grant it first, so a real, ACTIVE k9_permissions row exists for this
    -- key -- proving the delete below is NOT refused despite that reference,
    -- unlike server/certtiers.lua's own DeleteTier.
    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.audit')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.audit'))

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.audit')
    t.isTrue(result.ok, 'delete must succeed unconditionally -- no tier-style tier_in_use refusal exists for a permission key')
    t.equals(result.activeGrantCount, 1, 'the response still discloses how many active grants are about to go inert')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.audit'))
end)

t.test('TOMBSTONE: HasPermission resolves to false for an ALREADY-ACTIVE grant of a now-tombstoned key -- "resolves predictably", never a stale true', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.audit')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.audit'))

    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.audit')

    -- The k9_permissions row itself is UNTOUCHED (still active = 1) -- only
    -- the catalog's own validity gate changed. This is the load-bearing
    -- proof of this file's own "no reference-count refusal needed" claim.
    t.isNotNil(findActiveGrant(f.world, 'TARGET_CIT', 'k9.audit'), 'the grant row itself must be untouched by a catalog delete')
    t.isFalse(f.env.HasPermission('TARGET_CIT', 'k9.audit'), 'HasPermission must now deny it -- a tombstoned key can never resolve to true')
end)

t.test('TOMBSTONE: GrantPermission refuses to grant an already-deleted key -- invalid_permission, not a silent no-op', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.givexp')

    local ok, outcome = f.env.GrantPermission(HC_SOURCE, 'SOME_CIT', 'k9.givexp')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_permission')
end)

t.test('RESTORE: re-adding a tombstoned key restores it, and an old, never-revoked grant becomes valid again', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.audit')
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.audit')
    t.isFalse(f.env.HasPermission('TARGET_CIT', 'k9.audit'))

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.audit', label = 'View the audit records' })
    t.isTrue(result.ok)
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.audit'))
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.audit'), 'restoring the key must revive the grant that was never itself revoked')
end)

t.test('TOMBSTONE: deleting a purely-custom key removes it from ListPermissionCatalogKeys entirely', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isNotNil(findCatalogKey(f, 'k9.custom'))

    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.custom')
    t.isNil(findCatalogKey(f, 'k9.custom'))
end)

-- ============================================================================
-- SECTION 5 -- NAMESPACE PROTECTION: block.<Feature>/feature.<Feature> can
-- never be created, renamed, or shadowed through this surface.
-- ============================================================================

t.test('NAMESPACE: creating a key named feature.<Name> is refused as reserved_namespace', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'feature.BiteAndHold', label = 'Shadow' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'reserved_namespace')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('feature.BiteAndHold'))
end)

t.test('NAMESPACE: creating a key named block.<Name> is refused as reserved_namespace', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'block.BiteAndHold', label = 'Shadow' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'reserved_namespace')
end)

t.test('NAMESPACE: the bare literal keys "feature" and "block" are both refused too', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'feature', 'block' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = badKey, label = 'X' })
        t.isFalse(result.ok)
        t.equals(result.reason, 'reserved_namespace')
    end
end)

t.test('NAMESPACE: the feature./block. namespace keeps working UNAFFECTED by this catalog -- IsValidPermissionKey never routes it through the catalog at all', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'SOME_CIT', source = 300 } } },
    })
    local ok = f.env.GrantPermission(HC_SOURCE, 'SOME_CIT', 'feature.BiteAndHold')
    t.isTrue(ok, 'a real Config.Features key must still validate for feature.<Name> regardless of this catalog existing')
    t.isTrue(f.env.HasPermission('SOME_CIT', 'feature.BiteAndHold'))
    -- And the catalog itself never claims to know this key -- it belongs to
    -- an entirely different validation path.
    t.isFalse(f.env.IsKnownPermissionCatalogKey('feature.BiteAndHold'))
end)

-- ============================================================================
-- SECTION 6 -- THE DELETE-VS-GRANT RACE.
-- ============================================================================

t.test('RACE GUARD: PermissionKeyEditMutex is a real mutex object exposed as a bare global', function()
    local f = boot()
    t.equals(type(f.env.PermissionKeyEditMutex), 'table')
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'))
    t.isFalse(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'), 'a second acquire of the same key while held must fail')
    f.env.PermissionKeyEditMutex.Release('k9.access')
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'), 'released, then re-acquirable')
end)

t.test('RACE GUARD: GrantPermission reports "busy" and writes NOTHING while a concurrent catalog edit holds the same key\'s lock', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })

    -- Simulates the exact window server/permissionkeycatalog.lua's own
    -- DeleteKey/UpsertKey hold this lock for -- a concurrent GrantPermission
    -- for the SAME key must not be able to interleave its own check-then-
    -- write around it.
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'))

    local ok, outcome = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    t.isFalse(ok)
    t.equals(outcome, 'busy')
    t.isNil(findActiveGrant(f.world, 'TARGET_CIT', 'k9.access'), 'a busy grant attempt must never write a row')

    f.env.PermissionKeyEditMutex.Release('k9.access')
    -- The rejected attempt above already consumed the SAME officer's own
    -- rate limit (the cooldown check runs before the mutex acquisition, so
    -- a busy refusal still counts as one action, matching
    -- server/certtiers.lua's own identical ordering) -- advance past it so
    -- this second call is judged on the mutex/key state alone.
    f.fakeNow.value = f.fakeNow.value + 2000
    local ok2 = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    t.isTrue(ok2, 'once released, the identical grant succeeds normally')
end)

t.test('RACE GUARD: permKeysDelete itself refuses when the key\'s lock is already held (busy), never silently skipping the hold', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'))

    local result = f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.access')
    t.isFalse(result.ok)
    t.equals(result.reason, 'busy')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'))
end)

t.test('RACE GUARD: absent server/permissionkeycatalog.lua entirely, GrantPermission still works via the documented fallback (soft dependency)', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        loadCatalog = false,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    t.isNil(f.env.PermissionKeyEditMutex, 'this fixture genuinely has no permissionkeycatalog.lua loaded')
    t.isNil(f.env.IsKnownPermissionCatalogKey)

    local ok = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    t.isTrue(ok, 'GrantPermission must still succeed against Config.Permissions alone with this file entirely absent')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.access'))
end)

-- ============================================================================
-- SECTION 7 -- FAIL-CLOSED, NOT FAIL-OPEN, on a genuine DB read failure.
-- ============================================================================

t.test('FAIL-CLOSED: a failed catalog refresh never WIDENS validity beyond the Config.Permissions baseline', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.custom'))

    -- Simulate a genuine DB outage on the exact read RefreshPermissionKeyCatalog
    -- performs, then force a refresh the same way a resource restart would
    -- (onResourceStart) -- this file has no OTHER externally-triggerable
    -- refresh point, matching server/certtiers.lua's own identical shape.
    f.world.forceKeysQueryError = true
    f.triggerResourceStart()

    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.custom'),
        'a degraded read must never leave a purely-DB-sourced key looking MORE valid than Config.Permissions alone would say')
    -- The four shipped defaults are UNAFFECTED -- Config.Permissions itself
    -- was never touched by the simulated database outage.
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'))
end)

t.test('FAIL-CLOSED: DISCLOSED, tier-consistent limitation -- a failed refresh can transiently un-tombstone a DEFAULT key (self-heals on the next successful refresh). Documented, not silently hidden.', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.givexp')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.givexp'))

    f.world.forceKeysQueryError = true
    f.triggerResourceStart()
    -- This mirrors server/certtiers.lua's own RefreshCertificationTierCatalog,
    -- which has the identical property for a tombstoned TIER on a failed
    -- read -- see server/permissionkeycatalog.lua's own header
    -- "FAIL-CLOSED, NOT FAIL-OPEN" for the full writeup of why this is
    -- accepted rather than engineered away, and why it never widens beyond
    -- what Config.Permissions itself already grants.
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.givexp'), 'documented limitation: a failed read cannot see the tombstone row, so a DEFAULT key reverts to its config-shipped validity until the next successful refresh')

    -- Self-heals the instant a real read succeeds again.
    f.world.forceKeysQueryError = false
    f.triggerResourceStart()
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.givexp'), 'a subsequent successful refresh must re-apply the tombstone')
end)

t.test('FAIL-CLOSED: a malformed Config.Permissions degrades this file\'s own base catalog to empty, never asserts/errors', function()
    local f = boot({ permissions = { ['not-a-table'] = 'oops' } })
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.access'), 'a malformed Config.Permissions must not silently grant anything')
    -- The file must have loaded cleanly regardless (no error thrown at load
    -- time) -- reaching this line at all proves that.
    t.isNotNil(f.env.ListPermissionCatalogKeys)
end)

-- ============================================================================
-- SECTION 8 -- Config.Database.enabled = false: still runs, forgets on
-- restart.
-- ============================================================================

t.test('MEMORY MODE: Config.Database.enabled = false -- upsert/list/delete all still work with zero real database calls', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end, database = { enabled = false } })

    local upsertResult = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.memory_only', label = 'Memory Only' })
    t.isTrue(upsertResult.ok)
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.memory_only'))

    f.fakeNow.value = f.fakeNow.value + 2000
    local deleteResult = f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.memory_only')
    t.isTrue(deleteResult.ok)
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.memory_only'))

    -- Zero rows were ever written to the fake SQL world -- proves this ran
    -- entirely through K9Store's in-memory backend, never MySQL.*.
    t.isNil(next(f.world.permKeys), 'no real database row should exist in memory mode')
    t.isNil(next(f.world.permKeyAudit), 'no real audit row should exist in memory mode either')
end)

t.test('MEMORY MODE: a custom key created while Config.Database.enabled = false is FORGOTTEN across a resource restart', function()
    local first = boot({ isHighCommand = function(src) return src == HC_SOURCE end, database = { enabled = false } })
    first.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.session_only', label = 'Session Only' })
    t.isTrue(first.env.IsKnownPermissionCatalogKey('k9.session_only'))

    -- A fresh boot = a fresh server/datastore.lua closure (its own local
    -- in-memory tables are re-initialized empty) -- this is the honest
    -- "forgotten on restart" story server/datastore.lua's own header
    -- promises for Config.Database.enabled = false.
    local second = boot({ isHighCommand = function(src) return src == HC_SOURCE end, database = { enabled = false } })
    t.isFalse(second.env.IsKnownPermissionCatalogKey('k9.session_only'), 'memory-mode state must not survive a restart')
    t.isTrue(second.env.IsKnownPermissionCatalogKey('k9.access'), 'the config-shipped defaults are unaffected either way')
end)

-- ============================================================================
-- SECTION 9 -- VALIDATION.
-- ============================================================================

t.test('VALIDATION: an invalid key format (uppercase/too long/empty/bad chars) is rejected before any write', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'K9.Access', '', 'x ', 'has spaces', string.rep('a', 60), '.leadingdot' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = badKey, label = 'X' })
        t.isFalse(result.ok, 'key ' .. tostring(badKey) .. ' must be rejected')
        t.equals(result.reason, 'invalid_key')
    end
end)

t.test('VALIDATION: an invalid label (empty, too long, unsafe characters) is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badLabel in ipairs({ '', string.rep('a', 61), 'has <a> tag' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = badLabel })
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_label')
    end
end)

t.test('VALIDATION: description is optional -- nil is accepted, an over-long one is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local okResult = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isTrue(okResult.ok, 'a nil description must be accepted')

    f.fakeNow.value = f.fakeNow.value + 2000
    local badResult = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom2', label = 'Custom 2', description = string.rep('a', 301) })
    t.isFalse(badResult.ok)
    t.equals(badResult.reason, 'invalid_description')
end)

t.test('VALIDATION: deleting an unknown key is refused as unknown_key, not a no-op success', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'never_existed')
    t.isFalse(result.ok)
    t.equals(result.reason, 'unknown_key')
end)

-- ============================================================================
-- SECTION 10 -- rate limiting (mirrors server/certtiers.lua's own
-- CertTierActionCooldown pattern).
-- ============================================================================

t.test('RATE LIMIT: a second mutating call from the same officer inside the cooldown window is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local first = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.one', label = 'One' })
    t.isTrue(first.ok)
    local second = f.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.two', label = 'Two' })
    t.isFalse(second.ok)
    t.equals(second.reason, 'rate_limited')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.two'))
end)

-- ============================================================================
-- SECTION 11 -- persistence across a restart (real-DB mode, mirrors
-- tests/certtiers_spec.lua's own two-boot pattern).
-- ============================================================================

t.test('PERSISTENCE: a custom key, a relabel, and a delete all survive a resource restart via the shared fake database', function()
    local world = newWorld()
    local first = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    first.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    first.fakeNow.value = first.fakeNow.value + 2000
    first.callbacks['qbx_k9unit:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.access', label = 'Renamed Access' })
    first.fakeNow.value = first.fakeNow.value + 2000
    first.callbacks['qbx_k9unit:server:permKeysDelete'](HC_SOURCE, 'k9.givexp')

    local second = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(second.env.IsKnownPermissionCatalogKey('k9.custom'), 'the custom key must survive a restart')
    t.equals(second.env.GetPermissionCatalogLabel('k9.access'), 'Renamed Access', 'the relabel must survive a restart')
    t.isFalse(second.env.IsKnownPermissionCatalogKey('k9.givexp'), 'the deletion (tombstone) must survive a restart, never silently un-delete')
end)

os.exit(t.summary())
