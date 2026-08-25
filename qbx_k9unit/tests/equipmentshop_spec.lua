--[[
    tests/equipmentshop_spec.lua

    Tests for server/equipmentshop.lua -- FEATURE_IDEAS.md Part B §6 (the K9
    equipment shop). Loads the REAL, unmodified production file into an
    isolated sandbox and drives its onResourceStart handler directly --
    same style as tests/wellbeing_spec.lua's own "STARTUP VALIDATION"
    section, which this file's WarnIfItemMissing pattern is a deliberate,
    documented duplicate of (see server/equipmentshop.lua's own header,
    "THE WARNING PATTERN").

    Covers:
      - Config.Features.K9EquipmentShop absent/false: a total, silent
        no-op -- zero prints, zero exports.ox_inventory calls at all
        (matches server/integrations.lua's own documented "ABSENCE IS A
        CLEAN NO-OP" principle, applied here to a flag that may not exist
        yet at all, not merely one that exists and is off).
      - Config.K9EquipmentShop missing/malformed while the flag is true: a
        loud warning, never a thrown error, and no RegisterShop call.
      - Per-item validation: a missing/invalid price, or an item name that
        does not resolve in ox_inventory's own registry, is warned about BY
        NAME and SKIPPED -- never silently substituted, never aborting the
        whole shop over one bad entry.
      - Every item missing at once: the shop is NOT registered at all (there
        would be nothing to sell) -- still just a warning, never a throw.
      - currencyItem missing from ox_inventory's own registry: warned about,
        but does NOT block registration (a missing cash item is an operator
        misconfiguration to fix, not a reason to withhold the whole shop).
      - groups derived from Config.Departments, correctly, with no new
        config field of its own.
      - exports.ox_inventory:RegisterShop itself throwing (an incompatible
        ox_inventory version): caught, warned, never propagates.
      - The happy path: exact `inventory`/`groups`/`name` shape handed to
        RegisterShop, and the exact success log line.
      - GetCurrentResourceName() guard: an onResourceStart for a different
        resource entirely produces zero output and zero calls.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- RUNTIME SHOP LOCATIONS fake database -- backs k9_equipment_shop_locations
-- / k9_equipment_shop_locations_audit for the new callbacks this pass adds
-- (equipmentShopGetLocations/AddLocation/MoveLocation/RemoveLocation).
-- Same style as tests/runtimecontrol_spec.lua's own newWorld()/
-- makeQueryAwait(): a fake in-memory table mutated by the REAL production
-- callbacks exactly like a real database would be, so a "survives a
-- restart" test can boot twice against the same world.
-- ----------------------------------------------------------------------

--- @return table world
local function newWorld()
    return {
        locations = {}, -- [id] = { x, y, z, heading, model, scenario, label, created_by, updated_by }
        audit = {},     -- array of { location_id, action, x, y, z, heading, model, scenario, label, changed_by }
        nextId = 1,
    }
end

--- @param world table
--- @return fun(sql: string, params: table): table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT id, x, y, z, heading, model, scenario, label FROM k9_equipment_shop_locations', 1, true) then
            local out = {}
            for id, row in pairs(world.locations) do
                out[#out + 1] = { id = id, x = row.x, y = row.y, z = row.z, heading = row.heading, model = row.model, scenario = row.scenario, label = row.label }
            end
            return out
        elseif sql:find('UPDATE k9_equipment_shop_locations SET', 1, true) then
            local x, y, z, heading, model, scenario, label, updatedBy, id = params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9]
            local row = world.locations[id]
            if row then
                row.x, row.y, row.z, row.heading, row.model, row.scenario, row.label, row.updated_by = x, y, z, heading, model, scenario, label, updatedBy
            end
            return {}
        elseif sql:find('DELETE FROM k9_equipment_shop_locations WHERE id', 1, true) then
            world.locations[params[1]] = nil
            return {}
        elseif sql:find('INSERT INTO k9_equipment_shop_locations_audit', 1, true) then
            world.audit[#world.audit + 1] = {
                location_id = params[1], action = params[2], x = params[3], y = params[4], z = params[5],
                heading = params[6], model = params[7], scenario = params[8], label = params[9], changed_by = params[10],
            }
            return {}
        end
        error('equipmentshop_spec test stub: unhandled SQL (query.await): ' .. tostring(sql))
    end
end

--- @param world table
--- @return fun(sql: string, params: table): number
local function makeInsertAwait(world)
    return function(sql, params)
        if sql:find('INSERT INTO k9_equipment_shop_locations (', 1, true) then
            local id = world.nextId
            world.nextId = id + 1
            world.locations[id] = {
                x = params[1], y = params[2], z = params[3], heading = params[4],
                model = params[5], scenario = params[6], label = params[7], created_by = params[8],
            }
            return id
        end
        error('equipmentshop_spec test stub: unhandled SQL (insert.await): ' .. tostring(sql))
    end
end

--- @param opts table? -- { featureEnabled: boolean?, shopConfig: table?, departments: table?, registeredItems: table<string, boolean>?, throwOnRegisterShop: boolean?, world: table?, isHighCommand: fun(source):boolean?, hasPermission: fun(citizenid, key):boolean?, playersBySource: table? }
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
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local registeredItems = opts.registeredItems or {}
    local throwOnRegisterShop = opts.throwOnRegisterShop or false
    local registerShopCalls = {}

    local exportsStub = {
        ox_inventory = {
            Items = function(_self, itemName)
                if registeredItems[itemName] then return { name = itemName } end
                return nil
            end,
            RegisterShop = function(_self, shopType, shopDetails)
                if throwOnRegisterShop then
                    error('simulated incompatible ox_inventory RegisterShop signature')
                end
                registerShopCalls[#registerShopCalls + 1] = { shopType = shopType, shopDetails = shopDetails }
            end,
        },
        qbx_core = {
            GetPlayer = function(_self, source)
                local player = (opts.playersBySource or {})[source]
                return player
            end,
        },
    }

    local Config = {
        Features = { K9EquipmentShop = opts.featureEnabled },
        K9EquipmentShop = opts.shopConfig,
        Departments = opts.departments,
    }

    local world = opts.world or newWorld()
    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local broadcasts = {}
    local function TriggerClientEventStub(eventName, target, payload)
        broadcasts[#broadcasts + 1] = { eventName = eventName, target = target, payload = payload }
    end

    local isHighCommand = opts.isHighCommand or function() return false end
    local hasPermission = opts.hasPermission -- nil unless a test wants the permission-grant escape hatch

    -- server/cooldowns.lua's Consume falls back to GetGameTimer() whenever
    -- a caller (every mutating callback below) omits the optional `now`
    -- argument -- exactly what server/equipmentshop.lua's own call sites
    -- do. A deterministic fake clock (same shape as
    -- tests/runtimecontrol_spec.lua's own fakeNow) is what makes the
    -- rate-limiting tests below controllable rather than flaky against
    -- real wall-clock time.
    local fakeNow = { value = 0 }

    local env = Sandbox.newEnv({
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
        GetGameTimer = function() return fakeNow.value end,
        print = printStub,
        exports = exportsStub,
        Config = Config,
        lib = libStub,
        TriggerClientEvent = TriggerClientEventStub,
        MySQL = { query = { await = makeQueryAwait(world) }, insert = { await = makeInsertAwait(world) } },
        IsHighCommand = isHighCommand,
        HasPermission = hasPermission,
    })

    -- server/equipmentshop.lua's new runtime-locations section calls
    -- NewCooldown at its own file-load time (EquipmentShopLocationActionCooldown)
    -- -- load the REAL, unmodified server/cooldowns.lua first, exactly like
    -- tests/runtimecontrol_spec.lua's own boot() does for the identical
    -- reason, so this suite exercises the real cooldown behavior rather
    -- than a hand-rolled stand-in.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/equipmentshop.lua', env)

    return {
        printedLines = printedLines,
        registerShopCalls = registerShopCalls,
        config = Config,
        world = world,
        callbacks = callbacks,
        broadcasts = broadcasts,
        fakeNow = fakeNow,
        --- @param resourceName string?
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'qbx_k9unit')
            end
        end,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200
local HC_CITIZENID = 'HC001'

--- @param printedLines string[]
--- @param substring string
--- @return boolean
local function anyLineContains(printedLines, substring)
    for _, line in ipairs(printedLines) do
        if line:find(substring, 1, true) then return true end
    end
    return false
end

-- ----------------------------------------------------------------------
-- Absence is a clean no-op
-- ----------------------------------------------------------------------

t.test('Config.Features.K9EquipmentShop absent (nil): zero prints, zero RegisterShop calls', function()
    local f = newFixture({ featureEnabled = nil, shopConfig = { shopType = 'k9supply', items = { { name = 'k9_medkit', price = 10 } } } })
    f.fireResourceStart()
    t.equals(#f.printedLines, 0, 'a feature flag that has not even been added yet must produce ZERO output, not a warning about its own absence')
    t.equals(#f.registerShopCalls, 0)
end)

t.test('Config.Features.K9EquipmentShop = false: zero prints, zero RegisterShop calls, even with an otherwise-valid shop config', function()
    local f = newFixture({ featureEnabled = false, shopConfig = { shopType = 'k9supply', items = { { name = 'k9_medkit', price = 10 } } } })
    f.fireResourceStart()
    t.equals(#f.printedLines, 0)
    t.equals(#f.registerShopCalls, 0)
end)

t.test('onResourceStart fired for a different resource entirely is ignored -- zero output even with the feature on and everything missing', function()
    local f = newFixture({ featureEnabled = true, shopConfig = nil })
    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0)
    t.equals(#f.registerShopCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Config.K9EquipmentShop shape validation
-- ----------------------------------------------------------------------

t.test('feature on but Config.K9EquipmentShop missing entirely: one loud warning, never a thrown error, no RegisterShop call', function()
    local f = newFixture({ featureEnabled = true, shopConfig = nil })
    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'a missing config table must never crash resource start')
    t.isTrue(anyLineContains(f.printedLines, 'WARNING'))
    t.equals(#f.registerShopCalls, 0)
end)

t.test('shopType missing/empty: warned, no RegisterShop call', function()
    local f = newFixture({ featureEnabled = true, shopConfig = { items = { { name = 'k9_medkit', price = 10 } } } })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'shopType'))
    t.equals(#f.registerShopCalls, 0)
end)

t.test('items missing/empty: warned, no RegisterShop call', function()
    local f = newFixture({ featureEnabled = true, shopConfig = { shopType = 'k9supply', items = {} } })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'items'))
    t.equals(#f.registerShopCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Per-item validation -- skip, never substitute, never abort the whole shop
-- ----------------------------------------------------------------------

t.test('one item missing from ox_inventory\'s own registry: warned by name, SKIPPED -- the shop still registers with the remaining valid items', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_treat = true }, -- k9_medkit deliberately NOT registered
        shopConfig = {
            shopType = 'k9supply',
            items = {
                { name = 'k9_medkit', price = 150 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'k9_medkit'), 'the missing item must be named in a warning')
    t.equals(#f.registerShopCalls, 1, 'the shop must still register -- one good item is enough')
    local inventory = f.registerShopCalls[1].shopDetails.inventory
    t.equals(#inventory, 1, 'only the resolvable item may be included')
    t.equals(inventory[1].name, 'k9_treat')
end)

t.test('every configured item missing: warned, and the shop is NOT registered at all (nothing to sell)', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true },
        shopConfig = {
            shopType = 'k9supply',
            items = {
                { name = 'k9_medkit', price = 150 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 0)
    t.isTrue(anyLineContains(f.printedLines, 'nothing left to sell'))
end)

t.test('an item with a non-numeric/negative price is skipped and warned about, independent of whether the item name itself is real', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        shopConfig = {
            shopType = 'k9supply',
            items = {
                { name = 'k9_medkit', price = -5 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 1)
    local inventory = f.registerShopCalls[1].shopDetails.inventory
    t.equals(#inventory, 1)
    t.equals(inventory[1].name, 'k9_treat', 'the negative-priced entry must be excluded, not registered at price 0 or as a negative price')
end)

t.test('currencyItem missing from ox_inventory: warned about, but does NOT block registration', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { k9_medkit = true }, -- 'money' (the implicit default currencyItem) deliberately NOT registered
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'currencyItem'), 'a missing currency item must still be warned about loudly')
    t.equals(#f.registerShopCalls, 1, 'a missing currency item is an operator misconfiguration to fix, not a reason to withhold the whole shop')
end)

-- ----------------------------------------------------------------------
-- groups derived from Config.Departments -- no new config field of its own
-- ----------------------------------------------------------------------

t.test('groups are derived from Config.Departments -- every configured department, grade 0 (any rank)', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true },
        departments = { police = {}, sheriff = {} },
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 1)
    local groups = f.registerShopCalls[1].shopDetails.groups
    t.isNotNil(groups)
    t.equals(groups.police, 0)
    t.equals(groups.sheriff, 0)
end)

t.test('Config.Departments missing entirely: registration still succeeds, with no groups restriction rather than an error', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true },
        departments = nil,
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok)
    t.equals(#f.registerShopCalls, 1)
    t.isNil(f.registerShopCalls[1].shopDetails.groups)
end)

-- ----------------------------------------------------------------------
-- RegisterShop itself throwing -- an incompatible ox_inventory version
-- ----------------------------------------------------------------------

t.test('exports.ox_inventory:RegisterShop throwing is caught -- a distinct warning, never a thrown error out of onResourceStart', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true },
        throwOnRegisterShop = true,
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'an incompatible ox_inventory RegisterShop shape must never crash resource start')
    t.isTrue(anyLineContains(f.printedLines, 'WARNING'))
    t.isTrue(anyLineContains(f.printedLines, 'RegisterShop'))
end)

-- ----------------------------------------------------------------------
-- Happy path -- exact shape handed to RegisterShop, exact success log
-- ----------------------------------------------------------------------

t.test('happy path: RegisterShop receives the exact shopType/name/inventory shape, and no `locations`/`targets` field at all', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        departments = { police = {} },
        shopConfig = {
            shopType = 'k9supply',
            label = 'K9 Supply',
            currencyItem = 'money',
            items = {
                { name = 'k9_medkit', price = 150 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()

    t.equals(#f.registerShopCalls, 1)
    local call = f.registerShopCalls[1]
    t.equals(call.shopType, 'k9supply')
    t.equals(call.shopDetails.name, 'K9 Supply')
    t.isNil(call.shopDetails.locations, 'this shop must never carry a `locations` field -- see server/equipmentshop.lua\'s own header, point 2, for exactly why: ox_inventory\'s own client marker system never reads a dynamically-registered shop\'s locations at all, so client/equipmentshop.lua\'s own ox_target zone is the ONLY real interaction point')
    t.isNil(call.shopDetails.targets)
    t.equals(#call.shopDetails.inventory, 2)

    local byName = {}
    for _, item in ipairs(call.shopDetails.inventory) do byName[item.name] = item end
    t.equals(byName.k9_medkit.price, 150)
    t.equals(byName.k9_treat.price, 15)

    t.isTrue(anyLineContains(f.printedLines, 'K9 Supply shop registered'))
    t.isTrue(anyLineContains(f.printedLines, '2/2'))
end)

os.exit(t.summary())
