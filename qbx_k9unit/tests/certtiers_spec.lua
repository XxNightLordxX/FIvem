--[[
    tests/certtiers_spec.lua

    Tests server/certtiers.lua -- the owner-directed "high command can
    edit K9 cert tiers at runtime" pass -- against the REAL, unmodified
    production file, via tests/fixtures/sandbox.lua. Harness style mirrors
    tests/runtimecontrol_spec.lua closely: a fake in-memory table backing
    every SQL statement this file issues (k9_certification_tiers,
    k9_certification_tier_capabilities, k9_certification_tier_audit, plus
    a fake k9_certifications table for the reference-count check DeleteTier
    reads), mutated by the real production callbacks exactly like a real
    database would be. TWO BOOTS, ONE FAKE DATABASE, same as that spec's
    own pattern, is what proves persistence-across-restart.

    NOT COVERED HERE (disclosed, not silently skipped): the cross-file
    TierEditMutex race this pass closes between server/certtiers.lua's own
    DeleteTier and server/certifications.lua's SetCertificationTier is not
    exercised by either this spec or tests/certifications_spec.lua -- doing
    so would need a real concurrent-coroutine harness interleaving two
    MySQL.await yield points across TWO loaded production files sharing one
    TierEditMutex instance, which neither existing harness in this
    directory currently supports. What IS covered: TierEditMutex exists,
    is a real mutex object (TryAcquire/Release/IsHeld), and this file's own
    single-actor mutation paths behave correctly in isolation.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @return table world
local function newWorld()
    return {
        tiers = {},          -- tier_key -> { label, ordinal, deleted, updated_by }
        capabilities = {},   -- array of { tier_key, capability_key, granted_by }
        audit = {},          -- array of { action, tier_key, detail, changed_by }
        certifications = {}, -- array of { tier } -- fake k9_certifications rows for the reference-count check
    }
end

--- @param world table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers', 1, true) then
            local out = {}
            for key, row in pairs(world.tiers) do
                out[#out + 1] = { tier_key = key, label = row.label, ordinal = row.ordinal, deleted = row.deleted }
            end
            return out
        elseif sql:find('SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?', 1, true) then
            local row = world.tiers[params[1]]
            if row then return { { deleted = row.deleted } } end
            return {}
        elseif sql:find('INSERT INTO k9_certification_tiers', 1, true) then
            local key, label, ordinal, updatedBy = params[1], params[2], params[3], params[4]
            local deletedLiteral = sql:find('VALUES (?, ?, ?, 1, ?)', 1, true) and 1 or 0
            world.tiers[key] = { label = label, ordinal = ordinal, deleted = deletedLiteral, updated_by = updatedBy }
            return {}
        elseif sql:find('SELECT tier_key, capability_key FROM k9_certification_tier_capabilities', 1, true) then
            local out = {}
            for _, row in ipairs(world.capabilities) do
                out[#out + 1] = { tier_key = row.tier_key, capability_key = row.capability_key }
            end
            return out
        elseif sql:find('SELECT capability_key FROM k9_certification_tier_capabilities WHERE tier_key = ?', 1, true) then
            local out = {}
            for _, row in ipairs(world.capabilities) do
                if row.tier_key == params[1] then out[#out + 1] = { capability_key = row.capability_key } end
            end
            return out
        elseif sql:find('INSERT INTO k9_certification_tier_capabilities', 1, true) then
            world.capabilities[#world.capabilities + 1] = { tier_key = params[1], capability_key = params[2], granted_by = params[3] }
            return {}
        elseif sql:find('DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND capability_key = ?', 1, true) then
            for i = #world.capabilities, 1, -1 do
                local row = world.capabilities[i]
                if row.tier_key == params[1] and row.capability_key == params[2] then
                    table.remove(world.capabilities, i)
                end
            end
            return {}
        elseif sql:find('INSERT INTO k9_certification_tier_audit', 1, true) then
            world.audit[#world.audit + 1] = { action = params[1], tier_key = params[2], detail = params[3], changed_by = params[4] }
            return {}
        end
        error('certtiers_spec test stub: unhandled MySQL.query.await SQL: ' .. tostring(sql))
    end
end

--- @param world table
local function makeScalarAwait(world)
    return function(sql, params)
        if sql:find('SELECT COUNT(*) FROM k9_certifications WHERE tier = ?', 1, true) then
            local count = 0
            for _, row in ipairs(world.certifications) do
                if row.tier == params[1] then count = count + 1 end
            end
            return count
        end
        error('certtiers_spec test stub: unhandled MySQL.scalar.await SQL: ' .. tostring(sql))
    end
end

--- @param opts table? -- { world, config, isHighCommand }
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
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local playersBySource = opts.playersBySource or {}
    local exportsStub = { qbx_core = { GetPlayer = function(_self, src) return playersBySource[src] end } }

    local isHighCommand = opts.isHighCommand or function() return false end

    local defaultConfig = {
        CertificationTiers = opts.certificationTiers or {
            { key = 'trainee',   label = 'Trainee',   ordinal = 1, capabilities = {} },
            { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} },
            { key = 'senior',    label = 'Senior',    ordinal = 3, capabilities = {} },
        },
    }
    local config = opts.config or defaultConfig

    local fakeNow = { value = 0 }
    local env = Sandbox.newEnv({
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        print                  = printStub,
        lib                    = lib,
        exports                = exportsStub,
        MySQL                  = { query = { await = makeQueryAwait(world) }, scalar = { await = makeScalarAwait(world) } },
        IsHighCommand          = isHighCommand,
        Config                 = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/certtiers.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    return { env = env, world = world, callbacks = callbacks, printedLines = printedLines, fakeNow = fakeNow }
end

--- @param fixture table
--- @param key string
--- @return table? -- the tier entry from a fresh certTiersList call, or nil
local function findTier(fixture, hcSource, key)
    local result = fixture.callbacks['qbx_k9unit:server:certTiersList'](hcSource)
    for _, tier in ipairs(result.tiers) do
        if tier.key == key then return tier end
    end
    return nil
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

-- ============================================================================
-- SECTION 1 -- registration + HAZARD 1 (existing rows / zero-behavior-change
-- default).
-- ============================================================================

t.test('registration: all four callbacks are registered', function()
    local f = boot()
    for _, name in ipairs({
        'qbx_k9unit:server:certTiersList', 'qbx_k9unit:server:certTiersUpsert',
        'qbx_k9unit:server:certTiersReorder', 'qbx_k9unit:server:certTiersDelete',
    }) do
        t.isNotNil(f.callbacks[name], name .. ' must always be registered')
    end
end)

t.test('HAZARD 1: default catalog (no tablet edit ever made) keeps the three legacy keys at ordinals 1/2/3 with empty capabilities', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersList'](HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(#result.tiers, 3)
    t.equals(result.tiers[1].key, 'trainee')
    t.equals(result.tiers[1].ordinal, 1)
    t.equals(result.tiers[2].key, 'certified')
    t.equals(result.tiers[2].ordinal, 2)
    t.equals(result.tiers[3].key, 'senior')
    t.equals(result.tiers[3].ordinal, 3)
    t.isNil(next(result.tiers[2].capabilities), 'certified must ship with zero capabilities by default')
end)

t.test('HAZARD 1: GetCertificationTierOrdinal/IsKnownCertificationTierKey resolve the legacy keys with no tablet edit ever made', function()
    local f = boot()
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'))
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 1)
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 2)
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 3)
    t.isFalse(f.env.IsKnownCertificationTierKey('made_up_tier'))
end)

t.test('HAZARD 1: a malformed Config.CertificationTiers (missing \'certified\') falls back to the built-in legacy defaults, never crashes', function()
    local f = boot({ config = { CertificationTiers = { { key = 'foo', label = 'Foo', ordinal = 1, capabilities = {} } } } })
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'), 'must still resolve certified via the hardcoded fallback')
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 2)
end)

-- ============================================================================
-- SECTION 2 -- AUTHORIZATION (HAZARD 4): every one of the four callbacks
-- re-verifies IsHighCommand(source) server-side, including the read-only
-- list.
-- ============================================================================

t.test('AUTHORIZATION: certTiersList denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersList'](NON_HC_SOURCE)
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('AUTHORIZATION: certTiersUpsert denies a non-high-command source even with a well-formed payload', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](NON_HC_SOURCE, { key = 'master', label = 'Master', capabilities = {} })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.isFalse(f.env.IsKnownCertificationTierKey('master'), 'a denied caller must never actually create the tier')
end)

t.test('AUTHORIZATION: certTiersReorder and certTiersDelete both deny a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local reorderResult = f.callbacks['qbx_k9unit:server:certTiersReorder'](NON_HC_SOURCE, { 'senior', 'certified', 'trainee' })
    t.isFalse(reorderResult.ok)
    t.equals(reorderResult.reason, 'denied')
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 1, 'a denied reorder must not touch any ordinal')

    local deleteResult = f.callbacks['qbx_k9unit:server:certTiersDelete'](NON_HC_SOURCE, 'trainee')
    t.isFalse(deleteResult.ok)
    t.equals(deleteResult.reason, 'denied')
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'), 'a denied delete must not tombstone anything')
end)

t.test('AUTHORIZATION: server-side re-check ignores whatever the caller claims -- IsHighCommand alone decides, never a payload flag', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    -- A forged payload trying to smuggle its own authorization claim
    -- changes nothing -- CanManageCertTiers never reads the payload at all.
    local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](NON_HC_SOURCE, { key = 'master', label = 'Master', isHighCommand = true, ok = true })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

-- ============================================================================
-- SECTION 3 -- ADD A ROLE / EDIT PERMISSIONS (the owner's literal ask).
-- ============================================================================

t.test('ADD A ROLE: a brand-new tier is appended at the end of the ordinal list, with only catalog capabilities accepted', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, {
        key = 'master', label = 'Master Handler', capabilities = { 'advanced_tracking', 'mentor_trainees' },
    })
    t.isTrue(result.ok)
    local masterTier = findTier(f, HC_SOURCE, 'master')
    t.isNotNil(masterTier)
    t.equals(masterTier.ordinal, 4, 'a new tier is appended after ordinal 3 (senior)')
    t.isTrue(masterTier.capabilities.advanced_tracking)
    t.isTrue(masterTier.capabilities.mentor_trainees)
    t.equals(f.env.GetCertificationTierOrdinal('master'), 4)
end)

t.test('EDIT PERMISSIONS: toggling capabilities on an already-live tier never touches its ordinal', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })
    local seniorTier = findTier(f, HC_SOURCE, 'senior')
    t.equals(seniorTier.ordinal, 3, 'editing capabilities must not move the ordinal')
    t.isTrue(seniorTier.capabilities.bite_hold_and_takedown)
    t.isTrue(f.env.TierHasCapability('senior', 'bite_hold_and_takedown'))

    -- Re-upsert with an EMPTY capability set revokes the one just granted.
    -- fakeNow advanced past CERT_TIER_ACTION_COOLDOWN_MS so this second
    -- call from the SAME officer is not itself rejected as rate_limited.
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = {} })
    t.isFalse(f.env.TierHasCapability('senior', 'bite_hold_and_takedown'))
end)

t.test('EDIT PERMISSIONS: an unrecognized capability key rejects the WHOLE request -- the fixed catalog is closed (HAZARD 4)', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, {
        key = 'master', label = 'Master', capabilities = { 'become_high_command' },
    })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_capabilities')
    t.isFalse(f.env.IsKnownCertificationTierKey('master'), 'the whole upsert must be refused, not partially applied')
end)

t.test('RENAME: an existing tier\'s label can change while its key (the load-bearing identity) stays fixed', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'certified', label = 'Standard Handler', capabilities = {} })
    local certifiedTier = findTier(f, HC_SOURCE, 'certified')
    t.equals(certifiedTier.label, 'Standard Handler')
    t.equals(certifiedTier.ordinal, 2, 'renaming must never change the ordinal')
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'), 'the KEY must remain \'certified\' -- this is what k9_certifications.tier rows reference')
end)

t.test('VALIDATION: an invalid tier key (uppercase/too long/empty) is rejected before any write', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'Master', '', 'x', 'has spaces', string.rep('a', 40) }) do
        -- Advance past the cooldown before EVERY attempt in this loop --
        -- otherwise the second+ attempt would report 'rate_limited'
        -- (correct production behavior: the cooldown is consumed before
        -- payload validation, mirroring server/runtimecontrol.lua's own
        -- ordering) rather than exercising this test's own 'invalid_key'
        -- assertion.
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = badKey, label = 'X', capabilities = {} })
        t.isFalse(result.ok, 'key ' .. tostring(badKey) .. ' must be rejected')
        t.equals(result.reason, 'invalid_key')
    end
end)

-- ============================================================================
-- SECTION 4 -- HAZARD 2: a deleted tier with rows still pointing at it.
-- ============================================================================

t.test('HAZARD 2: deleting a tier with zero referencing k9_certifications rows succeeds and tombstones it', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isTrue(result.ok)
    t.isFalse(f.env.IsKnownCertificationTierKey('trainee'), 'a deleted tier must disappear from the live catalog')
    t.equals(#result.tiers, 2, 'the response reflects the post-delete catalog immediately')
end)

t.test('HAZARD 2: deleting a tier with at least one referencing k9_certifications row is REFUSED, never silently reassigned', function()
    local world = newWorld()
    world.certifications = { { tier = 'trainee' } }
    local f = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isFalse(result.ok)
    t.equals(result.reason, 'tier_in_use')
    t.equals(result.referenceCount, 1)
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'), 'a refused delete must leave the tier fully intact')
end)

t.test('HAZARD 2: \'certified\' can NEVER be deleted, even with zero referencing rows -- unconditional protection independent of reference count', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end }) -- fresh world, zero k9_certifications rows at all
    local result = f.callbacks['qbx_k9unit:server:certTiersDelete'](HC_SOURCE, 'certified')
    t.isFalse(result.ok)
    t.equals(result.reason, 'protected_tier')
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'))
end)

t.test('HAZARD 2: deleting an unknown tier key is refused as unknown_tier, not a no-op success', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersDelete'](HC_SOURCE, 'never_existed')
    t.isFalse(result.ok)
    t.equals(result.reason, 'unknown_tier')
end)

t.test('RESTORE: re-adding a deleted (tombstoned) key un-deletes it, appended at a NEW end-of-list ordinal, not its old position', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:certTiersDelete'](HC_SOURCE, 'trainee') -- ordinal 1, now tombstoned
    t.isFalse(f.env.IsKnownCertificationTierKey('trainee'))

    f.fakeNow.value = f.fakeNow.value + 2000 -- past the same-officer cooldown from the delete above
    local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'trainee', label = 'Trainee', capabilities = {} })
    t.isTrue(result.ok)
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'))
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 3, 'a restore is appended at the end (after certified=2, senior=3), never reclaiming ordinal 1')
end)

-- ============================================================================
-- SECTION 5 -- HAZARD 3: reordering.
-- ============================================================================

t.test('HAZARD 3: a full, valid reorder succeeds, reassigns sequential ordinals, and returns a non-empty retroactive-rerank warning', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee', 'certified' })
    t.isTrue(result.ok)
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 1)
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 2)
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 3)
    t.isTrue(type(result.warning) == 'string' and #result.warning > 0, 'a successful reorder must always carry a non-empty warning string')
    t.contains(result.warning:lower(), 'retroactiv')
end)

t.test('HAZARD 3: a PARTIAL reorder (missing a known key) is refused outright -- no ordinal is touched', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee' }) -- missing 'certified'
    t.isFalse(result.ok)
    t.equals(result.reason, 'must_include_every_tier')
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 1, 'refused reorder must leave every ordinal exactly as it was')
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 3)
end)

t.test('HAZARD 3: a reorder listing an unknown key is refused as invalid_key_set', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee', 'certified', 'made_up' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key_set')
end)

t.test('HAZARD 3: a reorder listing the same key twice is refused (duplicate), never silently deduped', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['qbx_k9unit:server:certTiersReorder'](HC_SOURCE, { 'senior', 'senior', 'certified' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key_set')
end)

-- ============================================================================
-- SECTION 6 -- persistence across a restart (mirrors
-- tests/runtimecontrol_spec.lua's own two-boot pattern).
-- ============================================================================

t.test('PERSISTENCE: a tablet-added tier, a rename, and a delete all survive a resource restart via the shared fake database', function()
    local world = newWorld()
    local first = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    first.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'master', label = 'Master', capabilities = { 'advanced_tracking' } })
    first.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'certified', label = 'Standard Handler', capabilities = {} })
    first.callbacks['qbx_k9unit:server:certTiersDelete'](HC_SOURCE, 'trainee')

    local second = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(second.env.IsKnownCertificationTierKey('master'), 'the custom tier must survive a restart')
    t.equals(second.env.GetCertificationTierOrdinal('master'), 4)
    t.isTrue(second.env.TierHasCapability('master', 'advanced_tracking'))
    local certifiedTier = findTier(second, HC_SOURCE, 'certified')
    t.equals(certifiedTier.label, 'Standard Handler', 'the rename must survive a restart')
    t.isFalse(second.env.IsKnownCertificationTierKey('trainee'), 'the deletion (tombstone) must survive a restart, never silently un-delete')
end)

-- ============================================================================
-- SECTION 7 -- rate limiting (anti-fat-finger, mirrors
-- server/runtimecontrol.lua's own RuntimeControlActionCooldown pattern).
-- ============================================================================

t.test('RATE LIMIT: a second mutating call from the same officer inside the cooldown window is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local first = f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'master', label = 'Master', capabilities = {} })
    t.isTrue(first.ok)
    local second = f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'master2', label = 'Master 2', capabilities = {} })
    t.isFalse(second.ok)
    t.equals(second.reason, 'rate_limited')
    t.isFalse(f.env.IsKnownCertificationTierKey('master2'))
end)

t.test('RATE LIMIT: is per-OFFICER, not global -- a different high-command officer is unaffected', function()
    local OTHER_HC_SOURCE = 300
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE or src == OTHER_HC_SOURCE end })
    f.callbacks['qbx_k9unit:server:certTiersUpsert'](HC_SOURCE, { key = 'master', label = 'Master', capabilities = {} })
    local result = f.callbacks['qbx_k9unit:server:certTiersUpsert'](OTHER_HC_SOURCE, { key = 'elite', label = 'Elite', capabilities = {} })
    t.isTrue(result.ok, 'a different officer\'s own action must not be blocked by the first officer\'s cooldown')
end)

-- ============================================================================
-- SECTION 8 -- HAZARD 4: the mutex primitive this pass introduces exists
-- and behaves as a real mutex (the cross-file race it closes is exercised
-- indirectly via server/certifications.lua's own SetCertificationTier
-- soft-dependency guard, covered in tests/certifications_spec.lua, which
-- passes with TierEditMutex entirely ABSENT from that spec's sandbox --
-- proving the soft-dependency fallback works when this file is not
-- loaded at all).
-- ============================================================================

t.test('HAZARD 4: TierEditMutex is a real mutex object exposed as a bare global', function()
    local f = boot()
    t.equals(type(f.env.TierEditMutex), 'table')
    t.isTrue(f.env.TierEditMutex.TryAcquire('trainee'))
    t.isFalse(f.env.TierEditMutex.TryAcquire('trainee'), 'a second acquire of the same key while held must fail')
    f.env.TierEditMutex.Release('trainee')
    t.isTrue(f.env.TierEditMutex.TryAcquire('trainee'), 'released, then re-acquirable')
end)

os.exit(t.summary())
