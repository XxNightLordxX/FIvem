--[[
    qbx_k9unit/server/equipmentshop.lua

    K9 EQUIPMENT SHOP -- FEATURE_IDEAS.md Part B §6 (coder-backend, this
    pass). "The cheapest of the three" per that doc: registers a "K9 Supply"
    shop via `ox_inventory`'s own `RegisterShop` export, selling the item
    names this codebase has already invented and left as documented
    PLACEHOLDERS with nowhere to buy them (`k9_medkit`, `k9_treat`,
    `k9_meat_bait`, `k9_ultrasonic_whistle` -- server/medkit.lua's
    Config.K9Medkit.itemName and server/wellbeing.lua's Mood/Distraction item
    names). Right now, on a fresh install with the wellbeing subsystem
    enabled (it is, by default, per PROJECT_STATUS.md), there is nothing to
    actually buy -- this file finishes that half-built loop, it does not
    start a new one.

    ======================================================================
    THE HARD CONSTRAINT THIS FILE IS BUILT UNDER (this task's own explicit
    instruction, restated here because it drives every choice below): this
    resource must never hardwire a NAMED third-party shop, banking or
    billing resource -- the operator's own custom systems are "not limited
    to any particular ones." `ox_inventory` is different in kind, not
    degree: it is already a DECLARED, HARD dependency of this resource
    (fxmanifest.lua's own `dependencies` block), already required for Phase
    2's own contraband search to function at all -- building on it directly
    here is not a new integration, it is using an existing one for one more
    thing. This file therefore:
      * calls ONLY `exports.ox_inventory:...` -- never any other named
        resource, never a `qb-shops`/similar assumption, never a specific
        banking export;
      * charges against `Config.K9EquipmentShop.currencyItem` -- an ITEM
        NAME ox_inventory itself already tracks (its own built-in cash
        item, conventionally `'money'`), not a separate banking resource --
        so an operator whose economy renames or omits that item still gets
        a clean warning (see WarnIfItemMissing below), never a silent
        assumption;
      * wraps the ENTIRE registration in `pcall`, so an ox_inventory version
        with a different/older `RegisterShop` shape degrades to one loud
        console line, never a resource-start failure.

    ======================================================================
    VERIFIED, NOT ASSUMED, AGAINST THE REAL, CURRENT ox_inventory SOURCE
    (overextended/ox_inventory, `modules/shops/server.lua` and
    `modules/shops/client.lua`, fetched and read directly this pass -- same
    "verify before believing" discipline this resource's own COORDINATION
    notes require for natives, applied here to an export instead) --
    RECORDED HERE so the next person to touch this file does not have to
    re-derive it from scratch:

      1. `exports.ox_inventory:RegisterShop(shopType, shopDetails)` is a
         real, current, server-side export. `shopDetails.inventory` is an
         array of `{ name, price, currency? }` -- `currency` defaults to
         `'money'` when omitted (ox_inventory's own `canAffordItem`/
         `removeCurrency`, which operate on it as a plain `GetItemCount`/
         `RemoveItem` ITEM NAME, never a banking API call).

      2. DELIBERATELY NOT passing `shopDetails.locations`/`.targets`.
         Supplying either would route this shop through ox_inventory's OWN
         internal `data/shops.lua`-driven marker/target system --
         `modules/shops/client.lua`'s `shopTypes` table (which is what that
         system actually reads) is populated ONLY from ox_inventory's own
         bundled `lib.load('data.shops')` at THAT resource's own client
         load time, with no server round-trip and no live sync of anything
         registered later via the `RegisterShop` export. In plain terms: a
         shop registered from an EXTERNAL resource (this one) never gains a
         walk-up marker/prompt of its own for free, no matter what fields
         are passed to `RegisterShop` -- registering WITHOUT `locations`
         instead yields a flat, immediately-open-able `Shops[shopType]`
         entry (`modules/shops/server.lua`'s `registerShopType`, the
         `else` branch, calling `setupShopItems(nil, ...)` so `.items` is
         populated directly), openable by TYPE ALONE with no `id`. This is
         why client/equipmentshop.lua (this pass's own small companion
         file) builds its OWN `ox_target` sphere zone rather than relying
         on anything ox_inventory auto-creates -- confirmed necessary by
         reading the real client module, not assumed from the doc's "one
         small config table + RegisterShop call" estimate, which undersold
         this by exactly this one client-side gap. Reported plainly here so
         a future audit does not "rediscover" a working design as broken.

      3. `exports.ox_inventory:openInventory('shop', { type = shopType })`
         (client/equipmentshop.lua's own call) is the exact, real client
         export (`client.lua`'s `exports('openInventory', client.openInventory)`)
         and the exact `{ type = ... }` shape `ox_inventory:openShop`'s own
         server callback expects when a shop has no `locations`/`.items` is
         already populated (see point 2) -- no `id` field needed for this
         shop's own registration shape.

      4. `groups` (job -> minimum grade) is ox_inventory's own real,
         existing shop-restriction field, enforced SERVER-SIDE inside its
         own `ox_inventory:openShop` callback (`server.hasGroup(playerInv,
         shop.groups)`) -- this file derives it from THIS resource's own,
         already-existing `Config.Departments` (no new config table needed
         for job restriction at all), so only a K9-eligible department may
         see or buy from this shop. The companion `ox_target` zone ALSO
         receives the same `groups` value on its own option (mirroring
         ox_inventory's own client module doing exactly the same thing for
         its internal shops) -- purely a VISUAL/UX filter, never the real
         boundary: per this resource's own "the tablet is a VIEW, it
         decides nothing" convention, the true authorization is
         ox_inventory's own server-side `hasGroup` check, which a modified
         client cannot bypass by pretending the option was visible.

    ======================================================================
    THE WARNING PATTERN -- mirrors server/wellbeing.lua's own
    `WarnIfItemMissing` (that file's own "STUCK-K9 SOFTLOCK FIX item 3")
    EXACTLY, duplicated here as this file's OWN small, self-contained copy
    rather than a shared cross-file call -- same "each file keeps its own
    tiny copy of a genuinely small, self-contained check" convention this
    resource already applies elsewhere (server/certifications.lua's/
    server/partnership.lua's own independent `IsDuplicateKeyError`/
    `FireOutboundEvent` copies). A WARNING ONLY, never an assert, never a
    resource-start failure -- an operator's own item table is THEIR
    configuration, not a defect in this resource, and a missing item must
    never look like a broken FEATURE (the whole shop silently failing to
    register) OR a broken ITEM (one slot silently invisible with nothing
    explaining why) -- every configured item is checked and reported by
    name, and the shop registers with whatever DOES resolve rather than
    refusing outright over one bad entry.

    ======================================================================
    EVENT/CALLBACK CONTRACT: none. This file registers no
    RegisterNetEvent/lib.callback of its own -- every player-facing
    interaction (opening the shop, buying an item) already flows entirely
    through ox_inventory's own existing, already-security-reviewed
    `ox_inventory:openShop`/`ox_inventory:buyItem` callbacks. Adding a
    second, parallel purchase path of this resource's own would be pure
    duplication with a second place to get the authorization checks wrong.

    ======================================================================
    CONFIG THIS FILE NEEDS (reported, not added here -- config.lua has a
    live owner this session; see this pass's own report for the exact
    fields/comments/defaults):
      Config.Features.K9EquipmentShop : boolean
      Config.K9EquipmentShop : {
          shopType     : string  -- ox_inventory's own shop-type key
          label        : string  -- shown in the ox_target prompt and the ox_inventory UI header
          currencyItem : string  -- an ox_inventory item name, e.g. 'money' -- NOT a banking resource
          items        : { { name: string, price: number }, ... }
          locations    : { vector3, ... } -- NOT read by THIS file at all (see point 2 above for why
                          -- this shop is deliberately registered without a `locations` field on the
                          -- ox_inventory payload itself) -- consumed only by client/equipmentshop.lua
                          -- to place its own ox_target interaction point(s). Listed here anyway
                          -- because it lives in the same config table and a server owner adding one
                          -- without the other would silently get a shop that exists but can never be
                          -- opened (server-side warning has no way to detect a client-side gap).
      }
    All fields are read defensively throughout both files (type-checked,
    never assumed) so a server that has not yet added them sees a clean,
    silent no-op -- not an error, not a stub with garbage data.

    FXMANIFEST.LUA PLACEMENT REQUESTED (server_scripts, not edited here):
    insert `'server/equipmentshop.lua',` after `'server/medkit.lua',` and
    before `'server/wellbeing.lua',` -- no load-order requirement of its own
    (this file calls no other file's resource-global, and nothing calls
    into this one), grouped there purely for readability alongside the
    other Phase 4 item-consuming features it shares placeholder item names
    with.

    LOCALE: none needed. This file's own console warnings are operator-
    facing (server console), never player-facing -- matching
    server/wellbeing.lua's own WarnIfItemMissing, which uses plain `print`,
    not `locale()`. Every PLAYER-facing string in the actual shop UI (item
    names, "cannot afford", etc.) is already ox_inventory's own, out of this
    resource's scope entirely.
]]

-- ======================================================================
-- WarnIfItemMissing -- see this file's header "THE WARNING PATTERN"
-- section for the full precedent/reasoning. A WARNING ONLY -- never
-- throws, never prevents resource start.
-- ======================================================================

--- @param itemName any
--- @param configPath string -- e.g. 'Config.K9EquipmentShop.items[2].name', for the printed message only
local function WarnIfItemMissing(itemName, configPath)
    if type(itemName) ~= 'string' or itemName == '' then
        print(('[qbx_k9unit] equipmentshop: WARNING: %s is not a valid item name (%s) -- cannot verify it against ox_inventory at all, and it will be SKIPPED from the shop rather than registered with garbage data.'):format(configPath, tostring(itemName)))
        return false
    end

    local ok, item = pcall(function() return exports.ox_inventory:Items(itemName) end)
    if not ok then
        print(('[qbx_k9unit] equipmentshop: WARNING: could not verify %s (%q) against ox_inventory -- the Items() export itself errored: %s. Confirm ox_inventory is installed and up to date.'):format(configPath, itemName, tostring(item)))
        return false
    end

    if not item then
        print(('[qbx_k9unit] equipmentshop: WARNING: %s (%q) does not exist in this server\'s ox_inventory item registry. This slot will be SKIPPED from the K9 Supply shop rather than sold as a broken, unusable entry -- add %q to your ox_inventory data/items.lua (or point %s at a real, existing item name) to actually sell it.'):format(configPath, itemName, itemName, configPath))
        return false
    end

    return true
end

-- ======================================================================
-- REGISTRATION -- gated at the TOP on Config.Features.K9EquipmentShop, so a
-- server that has not added the flag (or has it false) does ABSOLUTELY
-- NOTHING below this point: no warning prints, no ox_inventory calls, no
-- table allocation. Matches server/integrations.lua's own documented
-- "ABSENCE IS A CLEAN NO-OP" design principle, applied here to a feature
-- flag that may not exist yet at all rather than one that exists and is
-- merely off.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end

    local shopConfig = Config.K9EquipmentShop
    if type(shopConfig) ~= 'table' then
        print('[qbx_k9unit] equipmentshop: WARNING: Config.Features.K9EquipmentShop is true but Config.K9EquipmentShop is missing or not a table -- the K9 Supply shop will NOT be registered. Add Config.K9EquipmentShop (shopType/label/currencyItem/items) to config.lua.')
        return
    end

    if type(shopConfig.shopType) ~= 'string' or shopConfig.shopType == '' then
        print('[qbx_k9unit] equipmentshop: WARNING: Config.K9EquipmentShop.shopType must be a non-empty string -- the K9 Supply shop will NOT be registered.')
        return
    end

    if type(shopConfig.items) ~= 'table' or #shopConfig.items == 0 then
        print('[qbx_k9unit] equipmentshop: WARNING: Config.K9EquipmentShop.items must be a non-empty array -- the K9 Supply shop will NOT be registered (there would be nothing to sell).')
        return
    end

    -- currencyItem defaults to ox_inventory's own 'money' item (its built-in
    -- cash item, NOT a banking resource -- see this file's header) when
    -- unset, matching ox_inventory's own per-item default. Warned about
    -- regardless, since a renamed/removed cash item would make EVERY item
    -- in this shop silently unpurchasable with no explanation.
    local currencyItem = shopConfig.currencyItem
    if type(currencyItem) ~= 'string' or currencyItem == '' then
        currencyItem = 'money'
    end
    WarnIfItemMissing(currencyItem, 'Config.K9EquipmentShop.currencyItem')

    -- Build the ox_inventory `inventory` array, SKIPPING (never
    -- substituting a fake/zero-price placeholder for) any entry that fails
    -- validation or does not resolve against this server's own ox_inventory
    -- item registry -- see WarnIfItemMissing's own doc comment for why a
    -- skip, not a hard failure of the whole shop, is the right response to
    -- one bad entry among several good ones.
    local inventoryItems = {}
    for i, entry in ipairs(shopConfig.items) do
        local configPath = ('Config.K9EquipmentShop.items[%d]'):format(i)
        if type(entry) ~= 'table' then
            print(('[qbx_k9unit] equipmentshop: WARNING: %s is not a table -- skipped.'):format(configPath))
        elseif type(entry.price) ~= 'number' or entry.price ~= entry.price or entry.price < 0 then
            print(('[qbx_k9unit] equipmentshop: WARNING: %s.price must be a non-negative number (got %s) -- skipped.'):format(configPath, tostring(entry and entry.price)))
        elseif WarnIfItemMissing(entry.name, configPath .. '.name') then
            inventoryItems[#inventoryItems + 1] = {
                name = entry.name,
                price = entry.price,
                -- Only set `currency` when it differs from ox_inventory's
                -- own default -- an explicit per-item override is
                -- supported (a future config could price one item in a
                -- different item-currency) but not required for the common
                -- case.
                currency = (entry.currency ~= nil and entry.currency ~= currencyItem) and entry.currency or nil,
            }
        end
    end

    if #inventoryItems == 0 then
        print('[qbx_k9unit] equipmentshop: WARNING: every configured item failed validation or does not exist in this server\'s ox_inventory -- the K9 Supply shop will NOT be registered (there is nothing left to sell). See the WARNING lines above for the exact item(s) to fix.')
        return
    end

    -- Job restriction, derived from THIS resource's own already-existing
    -- Config.Departments -- no new config table needed. `0` (grade 0) means
    -- "any grade in this department," matching this resource's own
    -- "K9-eligible department membership alone, no rank floor" posture for
    -- everything else that gates on Config.Departments membership.
    local groups = nil
    if type(Config.Departments) == 'table' then
        groups = {}
        for jobName in pairs(Config.Departments) do
            groups[jobName] = 0
        end
        if next(groups) == nil then groups = nil end
    end

    local ok, err = pcall(function()
        exports.ox_inventory:RegisterShop(shopConfig.shopType, {
            name = type(shopConfig.label) == 'string' and shopConfig.label ~= '' and shopConfig.label or 'K9 Supply',
            inventory = inventoryItems,
            groups = groups,
            -- Deliberately NO `locations`/`targets` field -- see this
            -- file's header, point 2, for why: this resource's OWN
            -- client/equipmentshop.lua builds the physical interaction
            -- point instead, via ox_target, which is the only way an
            -- externally-registered shop actually becomes reachable.
        })
    end)

    if not ok then
        print(('[qbx_k9unit] equipmentshop: WARNING: exports.ox_inventory:RegisterShop failed -- the K9 Supply shop is NOT available this session. This can mean ox_inventory is missing, not started, or ships a different RegisterShop shape than this file was written against (see this file\'s header for the exact signature this was verified against). Error: %s'):format(tostring(err)))
        return
    end

    print(('[qbx_k9unit] equipmentshop: K9 Supply shop registered (%d/%d configured items resolved).'):format(#inventoryItems, #shopConfig.items))
end)
