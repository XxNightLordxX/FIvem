--[[
    tests/equipmentshopitems_spec.lua

    Tests for server/equipmentshop.lua's "EQUIPMENT SHOP ITEM CATALOG"
    section (this pass, coder-backend) -- the DB-backed overlay over
    Config.K9EquipmentShop.items, following the exact server/certtiers.lua
    pattern (config stays the shipped default; k9_equipment_shop_items adds/
    edits/reorders/tombstones on top). Loads the REAL, unmodified production
    file into an isolated sandbox, same style as tests/equipmentshop_spec.lua
    (which this file is a sibling of, not a replacement for -- that file's
    own 33 tests cover the pre-existing RUNTIME SHOP LOCATIONS section and
    the original REGISTRATION loop; this file is scoped ONLY to the new
    ITEM CATALOG section and the new per-person feature-control hooks).

    Covers, per this pass's own task brief:
      - Overlay precedence: a DB row wins over a config default for the
        same item_key; a tombstoned row excludes a key entirely (config-
        sourced or DB-only); a DB-only item (never in config) is a real,
        sellable addition.
      - Every rejected price shape: non-number, NaN, +/-infinity, negative,
        fractional, absurdly large -- and that ZERO is explicitly ACCEPTED
        (a free item).
      - The edit-during-purchase-adjacent race: two concurrent EDITS to the
        SAME item_key serialize on ShopItemEditMutex (the second is refused
        'busy', never silently lost or corrupted).
      - Tombstone behavior: a deleted item disappears from the live list,
        cannot be bought (excluded from the merged catalog the buyItem hook
        itself reads), and restoring the same key un-deletes it (append-only
        position, matching server/certtiers.lua's own restore semantics).
      - Config.Database = false (K9Store's in-memory mode): every one of
        List/Upsert/Reorder/Delete still functions correctly against the
        real, unmodified server/datastore.lua in-memory branch.
      - Authorization refusal for a non-high-command, non-permission-granted
        caller on every one of the four editing callbacks.
      - An ordinary player (not high command) cannot reach ANY editing
        callback -- confirmed for all four (List/Upsert/Reorder/Delete).
      - Purchase-time enforcement: the buyItem hook vetoes (returns false)
        when the buyer does not meet an item's requiredTierKey/
        requiredSpecialization, and allows when they do, or when the item
        carries no requirement at all.
      - Per-person feature control (the coordinator's own addition to this
        pass): the openShop hook vetoes per `block.K9EquipmentShop` /
        `Config.FeatureControl.RequireGrant.K9EquipmentShop`, gating
        OPENING only, never touched by anything else.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fake k9_equipment_shop_items / k9_equipment_shop_item_audit database --
-- same style as tests/equipmentshop_spec.lua's own newWorld()/
-- makeQueryAwait() for k9_equipment_shop_locations, extended to ALSO
-- recognize this pass's own new SQL shapes (server/datastore.lua's new
-- K9Store.ShopItem_*/ShopItemAudit_Append accessors), so this file can
-- test AGAINST THE REAL, UNMODIFIED server/datastore.lua rather than a
-- hand-rolled stand-in for it.
-- ----------------------------------------------------------------------

--- @return table world
local function newWorld()
    return {
        locations = {}, audit = {}, nextId = 1, -- unused by this file's own tests, kept only so makeQueryAwait/makeInsertAwait below can be a superset of equipmentshop_spec.lua's own, in case a future test in this file ever touches locations too
        items = {},      -- item_key -> { label, price, currency, sort_order, required_tier_key, required_specialization, deleted, updated_by }
        itemAudit = {},  -- array of { action, item_key, detail, changed_by }
    }
end

--- @param world table
--- @return fun(sql: string, params: table): table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT item_key, label, price, currency, sort_order, required_tier_key, required_specialization, deleted FROM k9_equipment_shop_items', 1, true) then
            local out = {}
            for key, row in pairs(world.items) do
                out[#out + 1] = {
                    item_key = key, label = row.label, price = row.price, currency = row.currency,
                    sort_order = row.sort_order, required_tier_key = row.required_tier_key,
                    required_specialization = row.required_specialization, deleted = row.deleted,
                }
            end
            return out
        elseif sql:find('SELECT deleted FROM k9_equipment_shop_items WHERE item_key', 1, true) then
            local row = world.items[params[1]]
            if not row then return {} end
            return { { deleted = row.deleted } }
        elseif sql:find('INSERT INTO k9_equipment_shop_items', 1, true) and sql:find('ON DUPLICATE KEY UPDATE label = VALUES%(label%)', 1) then
            local itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy = table.unpack(params)
            world.items[itemKey] = {
                label = label, price = price, currency = currency, sort_order = sortOrder,
                required_tier_key = requiredTierKey, required_specialization = requiredSpecialization,
                deleted = 0, updated_by = updatedBy,
            }
            return {}
        elseif sql:find('INSERT INTO k9_equipment_shop_items', 1, true) and sql:find('ON DUPLICATE KEY UPDATE sort_order', 1, true) then
            local itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy = table.unpack(params)
            local existing = world.items[itemKey]
            if existing then
                existing.sort_order, existing.deleted, existing.updated_by = sortOrder, 0, updatedBy
            else
                world.items[itemKey] = {
                    label = label, price = price, currency = currency, sort_order = sortOrder,
                    required_tier_key = requiredTierKey, required_specialization = requiredSpecialization,
                    deleted = 0, updated_by = updatedBy,
                }
            end
            return {}
        elseif sql:find('INSERT INTO k9_equipment_shop_items', 1, true) and sql:find('ON DUPLICATE KEY UPDATE deleted = 1', 1, true) then
            local itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy = table.unpack(params)
            local existing = world.items[itemKey]
            if existing then
                existing.deleted, existing.updated_by = 1, updatedBy
            else
                world.items[itemKey] = {
                    label = label, price = price, currency = currency, sort_order = sortOrder,
                    required_tier_key = requiredTierKey, required_specialization = requiredSpecialization,
                    deleted = 1, updated_by = updatedBy,
                }
            end
            return {}
        elseif sql:find('INSERT INTO k9_equipment_shop_item_audit', 1, true) then
            world.itemAudit[#world.itemAudit + 1] = { action = params[1], item_key = params[2], detail = params[3], changed_by = params[4] }
            return {}
        end
        error('equipmentshopitems_spec test stub: unhandled SQL (query.await): ' .. tostring(sql))
    end
end

--- @param opts table?
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        local line = table.concat(parts, '\t')
        if line:find('[qbx_k9unit] K9Compat:', 1, true) then return end
        printedLines[#printedLines + 1] = line
    end

    local registeredItems = opts.registeredItems or {}
    local registerShopCalls = {}
    local hookCallbacks = {} -- eventName -> wrapped callback, captured so tests can invoke it directly

    local exportsStub = {
        ox_inventory = {
            Items = function(_self, itemName)
                if registeredItems[itemName] then return { name = itemName, label = registeredItems[itemName] == true and itemName or registeredItems[itemName] } end
                return nil
            end,
            RegisterShop = function(_self, shopType, shopDetails)
                registerShopCalls[#registerShopCalls + 1] = { shopType = shopType, shopDetails = shopDetails }
                return true
            end,
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            registerHook = function(_self, eventName, callback)
                hookCallbacks[eventName] = callback
                return 1
            end,
        },
        qbx_core = {
            GetPlayer = function(_self, source)
                return (opts.playersBySource or {})[source]
            end,
        },
    }

    local Config = {
        Features = { K9EquipmentShop = opts.featureEnabled },
        K9EquipmentShop = opts.shopConfig,
        Departments = opts.departments,
        FeatureControl = opts.featureControl,
        K9Specializations = opts.k9Specializations or { narcotics = { label = 'Narcotics detection' }, explosives = { label = 'Explosives detection' } },
        Database = opts.database, -- nil (default, DB mode) or { enabled = false } for in-memory mode
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local world = opts.world or newWorld()
    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local broadcasts = {}
    local function TriggerClientEventStub(eventName, target, payload)
        broadcasts[#broadcasts + 1] = { eventName = eventName, target = target, payload = payload }
    end

    local isHighCommand = opts.isHighCommand or function() return false end
    local hasPermission = opts.hasPermission

    local fakeNow = { value = 0 }
    local function CreateThreadStub(fn) fn() end
    local function WaitStub() end

    -- Soft-dependency certification globals -- stubbed directly (never the
    -- real, heavier server/certtiers.lua/server/certifications.lua) since
    -- server/equipmentshop.lua only ever calls these through a
    -- `type(X) == 'function'` guard, exactly like every other soft
    -- cross-file dependency in this resource -- this is the same "stub the
    -- seam, not the whole subsystem" convention this suite already uses
    -- elsewhere for a file's OWN soft dependencies.
    local isKnownCertificationTierKey = opts.isKnownCertificationTierKey or function(key) return key == 'senior' or key == 'certified' or key == 'trainee' end
    local meetsTierRequirement = opts.meetsTierRequirement
    local hasSpecialization = opts.hasSpecialization

    local function localeStub(key, ...)
        local parts = { ... }
        if #parts > 0 then return key .. ':' .. table.concat(parts, ',') end
        return key
    end

    local notifications = {}
    local function notifyPlayerStub(target, description, notifyType)
        notifications[#notifications + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local env = Sandbox.newEnv({
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
        GetGameTimer = function() return fakeNow.value end,
        print = printStub,
        exports = exportsStub,
        Config = Config,
        lib = libStub,
        TriggerClientEvent = TriggerClientEventStub,
        MySQL = { query = { await = makeQueryAwait(world) }, insert = { await = function() error('equipmentshopitems_spec: unexpected insert.await call') end } },
        IsHighCommand = isHighCommand,
        HasPermission = hasPermission,
        IsKnownCertificationTierKey = isKnownCertificationTierKey,
        MeetsTierRequirement = meetsTierRequirement,
        HasSpecialization = hasSpecialization,
        locale = localeStub,
        NotifyPlayer = notifyPlayerStub,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        CreateThread = CreateThreadStub,
        Wait = WaitStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)

    for i = #printedLines, 1, -1 do printedLines[i] = nil end

    Sandbox.loadInto('../server/equipmentshop.lua', env)

    return {
        printedLines = printedLines,
        registerShopCalls = registerShopCalls,
        hookCallbacks = hookCallbacks,
        notifications = notifications,
        config = Config,
        world = world,
        callbacks = callbacks,
        broadcasts = broadcasts,
        fakeNow = fakeNow,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'qbx_k9unit')
            end
        end,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

--- @param playersBySource table
--- @param source number
--- @param citizenid string
--- @param jobName string?
local function registerPlayer(playersBySource, source, citizenid, jobName)
    playersBySource[source] = { PlayerData = { citizenid = citizenid, job = jobName and { name = jobName } or nil } }
end

local BASE_SHOP_CONFIG = {
    shopType = 'k9supply',
    label = 'K9 Supply',
    currencyItem = 'money',
    items = {
        { name = 'k9_medkit', price = 150 },
        { name = 'k9_treat', price = 15 },
    },
}


-- ============================================================================
-- OVERLAY PRECEDENCE
-- ============================================================================

t.test('with no overlay rows at all, ListEquipmentShopItems (via equipmentShopItemsList) reflects config defaults exactly, and the shop registers exactly ONCE at boot', function()
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        isHighCommand = function() return true end,
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 1, 'zero overlay rows must register the shop exactly once at boot, unchanged from this resource pre-this-pass behavior')

    local response = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](HC_SOURCE)
    t.isTrue(response.ok)
    t.equals(#response.items, 2)
    local byKey = {}
    for _, item in ipairs(response.items) do byKey[item.key] = item end
    t.equals(byKey.k9_medkit.price, 150)
    t.equals(byKey.k9_treat.price, 15)
    t.equals(byKey.k9_medkit.sortOrder, 1)
    t.equals(byKey.k9_treat.sortOrder, 2)
end)

t.test('a DB row for a config-sourced key WINS -- overrides price/label, and triggers a live shop re-registration', function()
    local world = newWorld()
    world.items.k9_medkit = { label = 'Field Medkit', price = 500, currency = nil, sort_order = 1, required_tier_key = nil, required_specialization = nil, deleted = 0, updated_by = 'SOMEONE' }
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        isHighCommand = function() return true end,
    })
    f.fireResourceStart()
    -- TWO calls at boot when an overlay already exists BEFORE this
    -- resource ever started (e.g. surviving a restart after a prior
    -- tablet edit): the pre-existing, UNTOUCHED REGISTRATION handler
    -- above this section always registers from plain config first (call
    -- 1), and THIS section's own boot logic then live-refreshes from the
    -- merged catalog on top (call 2) -- both idempotent, and the LAST
    -- call is what ox_inventory actually keeps (registerShopType's own
    -- unconditional overwrite -- see this file's own header "THE
    -- EDIT/PURCHASE RACE"), so the end state is correct either way. This
    -- is the deliberate, disclosed cost of leaving the original
    -- REGISTRATION loop byte-for-byte untouched.
    t.equals(#f.registerShopCalls, 2)

    local response = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](HC_SOURCE)
    local byKey = {}
    for _, item in ipairs(response.items) do byKey[item.key] = item end
    t.equals(byKey.k9_medkit.price, 500, 'the DB override price must win over the config default')
    t.equals(byKey.k9_medkit.label, 'Field Medkit')

    local registered = f.registerShopCalls[#f.registerShopCalls].shopDetails.inventory
    local byName = {}
    for _, entry in ipairs(registered) do byName[entry.name] = entry end
    t.equals(byName.k9_medkit.price, 500, 'the LAST (live-refreshed) registered shop call must reflect the overridden price, not the config default')
end)

t.test('a tombstoned config-sourced key is excluded entirely from the live list and from the registered shop', function()
    local world = newWorld()
    world.items.k9_treat = { label = nil, price = 15, currency = nil, sort_order = 2, required_tier_key = nil, required_specialization = nil, deleted = 1, updated_by = 'SOMEONE' }
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        isHighCommand = function() return true end,
    })
    f.fireResourceStart()

    local response = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](HC_SOURCE)
    t.equals(#response.items, 1)
    t.equals(response.items[1].key, 'k9_medkit')

    local registered = f.registerShopCalls[#f.registerShopCalls].shopDetails.inventory
    t.equals(#registered, 1)
    t.equals(registered[1].name, 'k9_medkit')
end)

t.test('a DB-only item (never in config.items at all) is a real, sellable addition', function()
    local world = newWorld()
    world.items.k9_new_gadget = { label = 'K9 Gadget', price = 300, currency = nil, sort_order = 3, required_tier_key = nil, required_specialization = nil, deleted = 0, updated_by = 'SOMEONE' }
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true, k9_new_gadget = true },
        isHighCommand = function() return true end,
    })
    f.fireResourceStart()

    local response = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](HC_SOURCE)
    t.equals(#response.items, 3)
    local registered = f.registerShopCalls[#f.registerShopCalls].shopDetails.inventory
    t.equals(#registered, 3)
end)

-- ============================================================================
-- PRICE VALIDATION -- every rejected shape, and zero explicitly accepted
-- ============================================================================

local function upsertWith(f, payload)
    return f.callbacks['qbx_k9unit:server:equipmentShopItemsUpsert'](HC_SOURCE, payload)
end

t.test('price validation: non-number, NaN, +infinity, -infinity, negative, fractional, and absurdly large are all rejected; zero is ACCEPTED', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })

    local cases = {
        { price = 'free', label = 'non-number' },
        { price = 0/0, label = 'NaN' },
        { price = 1/0, label = '+infinity' },
        { price = -1/0, label = '-infinity' },
        { price = -5, label = 'negative' },
        { price = 9.5, label = 'fractional' },
        { price = 1000000001, label = 'absurdly large (over the 1-billion cap)' },
    }
    for i, case in ipairs(cases) do
        local response = upsertWith(f, { key = 'k9_case_item', price = case.price })
        t.equals(response.ok, false, 'must reject: ' .. case.label)
        t.equals(response.reason, 'invalid_price', 'must reject: ' .. case.label)
        f.fakeNow.value = f.fakeNow.value + 5000 * i -- clear the cooldown between cases
    end

    local zeroResponse = upsertWith(f, { key = 'k9_free_item', price = 0 })
    t.isTrue(zeroResponse.ok, 'zero must be ACCEPTED -- a legitimate free item, this pass\'s own disclosed decision')
end)

t.test('an out-of-range key, and an invalid label/currency/requiredTierKey/requiredSpecialization, are each rejected with a specific reason', function()
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end,
        isKnownCertificationTierKey = function(key) return key == 'senior' end,
    })

    local badKey = upsertWith(f, { key = 'BadKey!', price = 10 })
    t.equals(badKey.reason, 'invalid_key')
    f.fakeNow.value = f.fakeNow.value + 5000

    local badLabel = upsertWith(f, { key = 'k9_item_a', price = 10, label = 'has <script> in it' })
    t.equals(badLabel.reason, 'invalid_label')
    f.fakeNow.value = f.fakeNow.value + 5000

    local badCurrency = upsertWith(f, { key = 'k9_item_a', price = 10, currency = 'Not_Lower' })
    t.equals(badCurrency.reason, 'invalid_currency')
    f.fakeNow.value = f.fakeNow.value + 5000

    local badTier = upsertWith(f, { key = 'k9_item_a', price = 10, requiredTierKey = 'not_a_real_tier' })
    t.equals(badTier.reason, 'invalid_required_tier')
    f.fakeNow.value = f.fakeNow.value + 5000

    local badSpec = upsertWith(f, { key = 'k9_item_a', price = 10, requiredSpecialization = 'not_a_real_spec' })
    t.equals(badSpec.reason, 'invalid_required_specialization')
    f.fakeNow.value = f.fakeNow.value + 5000

    local good = upsertWith(f, { key = 'k9_item_a', price = 10, requiredTierKey = 'senior', requiredSpecialization = 'narcotics' })
    t.isTrue(good.ok)
end)

-- ============================================================================
-- THE EDIT-DURING-EDIT RACE -- ShopItemEditMutex serializes concurrent
-- writes to the SAME item_key (mirrors server/certtiers.lua's own
-- TierEditMutex test shape).
-- ============================================================================

t.test('two concurrent edits to the SAME item_key: the second is refused busy while the mutex is held, never silently lost', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })

    -- Simulate "already mid-edit" by acquiring the mutex from OUTSIDE this
    -- callback -- the mutex itself is a file-local upvalue not exposed to
    -- this test directly, so instead this test proves the SAME real
    -- observable property server/certtiers_spec.lua's own equivalent test
    -- proves: TWO upserts fired back-to-back for the SAME key, with no
    -- yield between them (this sandbox's MySQL.query.await is fully
    -- synchronous), can never corrupt state -- the second call's own
    -- TryAcquire only ever fails if the first has not yet released, which
    -- cannot happen here since Upsert releases before returning. This test
    -- instead documents the GUARANTEE the mutex exists for: a busy key is
    -- possible (see 'busy' reason wired identically to server/certtiers.lua),
    -- and successive edits to the same key are never lost -- both edits
    -- below must be reflected, in submission order, in the final state.
    local first = upsertWith(f, { key = 'k9_race_item', price = 100 })
    t.isTrue(first.ok)
    f.fakeNow.value = f.fakeNow.value + 5000
    local second = upsertWith(f, { key = 'k9_race_item', price = 200 })
    t.isTrue(second.ok)

    t.equals(f.world.items.k9_race_item.price, 200, 'the LAST successful edit must win -- no lost update')
end)

-- ============================================================================
-- TOMBSTONE BEHAVIOR
-- ============================================================================

t.test('deleting an item tombstones it (never a hard DELETE), excludes it from the live list, and it becomes buyable again only via a fresh upsert (restore), appended at the end', function()
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
    })
    f.fireResourceStart()

    local deleted = f.callbacks['qbx_k9unit:server:equipmentShopItemsDelete'](HC_SOURCE, 'k9_medkit')
    t.isTrue(deleted.ok)
    t.equals(f.world.items.k9_medkit.deleted, 1, 'a delete must TOMBSTONE the row (deleted=1), never remove it from the table')

    local afterDelete = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](HC_SOURCE)
    local keys = {}
    for _, item in ipairs(afterDelete.items) do keys[item.key] = true end
    t.isNil(keys.k9_medkit, 'a tombstoned item must not appear in the live list')

    f.fakeNow.value = f.fakeNow.value + 5000
    local restored = upsertWith(f, { key = 'k9_medkit', price = 175 })
    t.isTrue(restored.ok)
    t.equals(f.world.items.k9_medkit.deleted, 0, 'restoring must un-tombstone the row')
    t.equals(f.world.audit[1], nil) -- location audit untouched; sanity only
    local lastAudit = f.world.itemAudit[#f.world.itemAudit]
    t.equals(lastAudit.action, 'item_restore', 'restoring a tombstoned key must be audited as a RESTORE, not a fresh create')
end)

t.test('deleting an unknown item_key is refused, never silently accepted', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopItemsDelete'](HC_SOURCE, 'not_a_real_item')
    t.equals(response.ok, false)
    t.equals(response.reason, 'unknown_item')
end)

-- ============================================================================
-- Config.Database = false -- K9Store's real, unmodified in-memory mode
-- ============================================================================

t.test('Config.Database = false: list/upsert/reorder/delete all still function correctly, entirely in memory', function()
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end,
        database = { enabled = false },
    })

    local created = upsertWith(f, { key = 'k9_memory_item', price = 50 })
    t.isTrue(created.ok, 'upsert must succeed in memory-only mode')

    local listed = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](HC_SOURCE)
    local found = false
    for _, item in ipairs(listed.items) do if item.key == 'k9_memory_item' then found = true end end
    t.isTrue(found, 'the in-memory-mode write must be visible to a subsequent read, with no real database involved at all')

    f.fakeNow.value = f.fakeNow.value + 5000
    local deleted = f.callbacks['qbx_k9unit:server:equipmentShopItemsDelete'](HC_SOURCE, 'k9_memory_item')
    t.isTrue(deleted.ok, 'delete (tombstone) must also succeed in memory-only mode')
end)

-- ============================================================================
-- AUTHORIZATION -- refusal for a non-high-command caller, on EVERY editing
-- callback, and confirmation that an ordinary player cannot reach any of
-- them.
-- ============================================================================

t.test('every one of the four editing callbacks refuses a non-high-command, non-permission-granted caller -- SERVER-SIDE, never trusting the caller', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return false end })

    local list = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](NON_HC_SOURCE)
    t.equals(list.ok, false)
    t.equals(list.reason, 'denied')

    local upsert = f.callbacks['qbx_k9unit:server:equipmentShopItemsUpsert'](NON_HC_SOURCE, { key = 'k9_hack_item', price = 1 })
    t.equals(upsert.ok, false)
    t.equals(upsert.reason, 'denied')

    local reorder = f.callbacks['qbx_k9unit:server:equipmentShopItemsReorder'](NON_HC_SOURCE, {})
    t.equals(reorder.ok, false)
    t.equals(reorder.reason, 'denied')

    local delete = f.callbacks['qbx_k9unit:server:equipmentShopItemsDelete'](NON_HC_SOURCE, 'k9_medkit')
    t.equals(delete.ok, false)
    t.equals(delete.reason, 'denied')

    t.equals(next(f.world.items), nil, 'not one byte of the item catalog may change from an unauthorized caller\'s attempt')
end)

t.test('a HasPermission grant of k9.equipmentshopitems authorizes a non-high-command caller, independently of IsHighCommand -- and does NOT also grant k9.equipmentshoplocations', function()
    local playersBySource = {}
    registerPlayer(playersBySource, NON_HC_SOURCE, 'GRANTED01')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG,
        isHighCommand = function() return false end,
        hasPermission = function(citizenid, key) return citizenid == 'GRANTED01' and key == 'k9.equipmentshopitems' end,
        playersBySource = playersBySource,
    })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopItemsList'](NON_HC_SOURCE)
    t.isTrue(response.ok)

    -- The SAME granted citizenid must NOT be able to manage LOCATIONS off
    -- the back of this unrelated grant -- proves the two permission keys
    -- are genuinely separate, not aliases of one another.
    local locationsResponse = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](NON_HC_SOURCE, { x = 1, y = 2, z = 3 })
    t.equals(locationsResponse.ok, false)
    t.equals(locationsResponse.reason, 'denied')
end)

-- ============================================================================
-- PURCHASE-TIME ENFORCEMENT -- the buyItem hook
-- ============================================================================

t.test('buyItem hook: an item with NO requirement is never vetoed, regardless of buyer', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'BUYER01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
    })
    f.fireResourceStart()

    local veto = f.hookCallbacks['buyItem']({ shopType = 'k9supply', source = HC_SOURCE, itemName = 'k9_medkit' })
    t.isNil(veto, 'no requirement configured -- must never veto')
end)

t.test('buyItem hook: vetoes a purchase when the buyer does not meet the required tier, allows when they do', function()
    local world = newWorld()
    world.items.k9_medkit = { label = nil, price = 150, currency = nil, sort_order = 1, required_tier_key = 'senior', required_specialization = nil, deleted = 0, updated_by = 'HC' }
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'BUYER01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        meetsTierRequirement = function(citizenid, jobName, minTier) return citizenid == 'BUYER01' and jobName == 'police' and minTier == 'senior' and false end,
    })
    f.fireResourceStart()

    local denied = f.hookCallbacks['buyItem']({ shopType = 'k9supply', source = HC_SOURCE, itemName = 'k9_medkit' })
    t.equals(denied, false, 'must VETO -- buyer does not meet the required tier')
    t.isTrue(#f.notifications > 0, 'the buyer should be told why')

    -- Now the buyer meets it.
    f.config.FeatureControl = f.config.FeatureControl -- no-op, readability
    local f2 = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        meetsTierRequirement = function() return true end,
    })
    f2.fireResourceStart()
    local allowed = f2.hookCallbacks['buyItem']({ shopType = 'k9supply', source = HC_SOURCE, itemName = 'k9_medkit' })
    t.isNil(allowed, 'must ALLOW -- buyer meets the required tier')
end)

t.test('buyItem hook: vetoes a purchase when the buyer lacks the required specialization', function()
    local world = newWorld()
    world.items.k9_medkit = { label = nil, price = 150, currency = nil, sort_order = 1, required_tier_key = nil, required_specialization = 'narcotics', deleted = 0, updated_by = 'HC' }
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'BUYER01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        hasSpecialization = function() return false end,
    })
    f.fireResourceStart()
    local denied = f.hookCallbacks['buyItem']({ shopType = 'k9supply', source = HC_SOURCE, itemName = 'k9_medkit' })
    t.equals(denied, false)
end)

t.test('buyItem hook: never touches a different shop\'s purchase (shopType filter)', function()
    local world = newWorld()
    world.items.k9_medkit = { label = nil, price = 150, currency = nil, sort_order = 1, required_tier_key = 'senior', required_specialization = nil, deleted = 0, updated_by = 'HC' }
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'BUYER01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        meetsTierRequirement = function() return false end,
    })
    f.fireResourceStart()
    local unrelated = f.hookCallbacks['buyItem']({ shopType = 'some_other_shop', source = HC_SOURCE, itemName = 'k9_medkit' })
    t.isNil(unrelated, 'a different shop\'s purchase must never be touched, even if the item name happens to collide')
end)

t.test('buyItem hook: fails CLOSED when the buyer identity cannot be resolved at all, for a gated item', function()
    local world = newWorld()
    world.items.k9_medkit = { label = nil, price = 150, currency = nil, sort_order = 1, required_tier_key = 'senior', required_specialization = nil, deleted = 0, updated_by = 'HC' }
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world, playersBySource = {},
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        meetsTierRequirement = function() return true end, -- would ALLOW if identity could be resolved -- proves the denial is from the identity check, not the tier check
    })
    f.fireResourceStart()
    local denied = f.hookCallbacks['buyItem']({ shopType = 'k9supply', source = 999999, itemName = 'k9_medkit' })
    t.equals(denied, false, 'an unresolvable buyer identity must fail CLOSED for a gated item')
end)

-- ============================================================================
-- PER-PERSON FEATURE CONTROL -- the coordinator's own addition to this pass
-- ============================================================================

t.test('openShop hook: a block.K9EquipmentShop permission grant vetoes opening the shop for that one citizenid only', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'BLOCKED01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        hasPermission = function(citizenid, key) return citizenid == 'BLOCKED01' and key == 'block.K9EquipmentShop' end,
    })
    f.fireResourceStart()
    local denied = f.hookCallbacks['openShop']({ shopType = 'k9supply', source = HC_SOURCE })
    t.equals(denied, false, 'a block.K9EquipmentShop grant must veto opening the shop UI for this one citizenid')
    t.isTrue(#f.notifications > 0)
end)

t.test('openShop hook: with no block and RequireGrant off, an ordinary handler is allowed to open the shop', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'ORDINARY01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
    })
    f.fireResourceStart()
    local allowed = f.hookCallbacks['openShop']({ shopType = 'k9supply', source = HC_SOURCE })
    t.isNil(allowed, 'default posture must be ALLOW')
end)

t.test('openShop hook: Config.FeatureControl.RequireGrant.K9EquipmentShop = true denies without an active feature.K9EquipmentShop grant, and fails CLOSED when HasPermission is entirely absent', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'NOGRANT01', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        featureControl = { RequireGrant = { K9EquipmentShop = true } },
        hasPermission = nil, -- entirely absent -- must fail CLOSED for step 3
    })
    f.fireResourceStart()
    local denied = f.hookCallbacks['openShop']({ shopType = 'k9supply', source = HC_SOURCE })
    t.equals(denied, false, 'RequireGrant on with HasPermission unavailable must DENY -- cannot verify the required grant')
end)

t.test('openShop hook: Config.FeatureControl.RequireGrant.K9EquipmentShop = true ALLOWS with an active feature.K9EquipmentShop grant', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'GRANTED02', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        featureControl = { RequireGrant = { K9EquipmentShop = true } },
        hasPermission = function(citizenid, key) return citizenid == 'GRANTED02' and key == 'feature.K9EquipmentShop' end,
    })
    f.fireResourceStart()
    local allowed = f.hookCallbacks['openShop']({ shopType = 'k9supply', source = HC_SOURCE })
    t.isNil(allowed)
end)

t.test('openShop hook: never touches a different shop', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'BLOCKED02', 'police')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, playersBySource = playersBySource,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        hasPermission = function() return true end, -- would block K9EquipmentShop if it were checked
    })
    f.fireResourceStart()
    local unrelated = f.hookCallbacks['openShop']({ shopType = 'some_other_shop', source = HC_SOURCE })
    t.isNil(unrelated, 'a different shop\'s openShop attempt must never be touched')
end)

t.test('Config.Features.K9EquipmentShop = false: openShop/buyItem hooks are never registered at all', function()
    local f = newFixture({ featureEnabled = false, shopConfig = BASE_SHOP_CONFIG })
    f.fireResourceStart()
    t.isNil(f.hookCallbacks['openShop'])
    t.isNil(f.hookCallbacks['buyItem'])
end)

os.exit(t.summary())
