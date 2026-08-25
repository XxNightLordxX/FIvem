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
    RUNTIME SHOP LOCATIONS (this pass, coder-frontend). The owner's own
    words: "make the shop a dog ped and i can change the locations in the
    config or add more locations remove locations etc along with in the
    high command tablet." Two things landed this pass:

      1. THE SHOP PED. client/equipmentshop.lua now spawns a real, visible
         ped at each shop location and targets THAT PED via ox_target's
         `addLocalEntity` -- not a bare invisible sphere. Which model, and
         any idle scenario it plays, is fully operator-configurable
         (Config.K9EquipmentShop.pedModel/pedHeading/pedScenario below, or
         a per-location override), never hardcoded, and never validated
         against Config.Peds -- a shop attendant is not a K9. See that
         file's own header for the full entity-lifecycle contract (what
         owns each ped's lifetime, what deletes it, and why these are
         local, non-networked entities -- no netId, no cross-client race).

      2. RUNTIME-EDITABLE LOCATIONS. Config.K9EquipmentShop.locations
         already covers "change in the config" (add/remove/reorder
         entries freely, no code change -- unchanged by this pass). NEW
         this pass: a database-backed pool of ADDITIONAL locations the
         high command tablet can add to, move within, and remove from AT
         RUNTIME, persisted across restarts (sql/migrations/0011_create_k9_equipment_shop_locations.sql
         + its audit-table companion, following the exact
         current-state-table + append-only-audit-table shape
         server/runtimecontrol.lua's own migration 0007 already
         established). SCOPE, stated plainly: these callbacks manage ONLY
         the database-native pool (`db:<id>` keys) -- a config.lua-defined
         location (`db:<n>` -- no, a config-sourced `cfg:<n>` key) is never
         overridden or suppressed from here; it stays editable only by
         hand-editing config.lua and restarting, exactly as before this
         pass. This is a deliberate decision, not an oversight: a stored
         override keyed to config.lua's own ARRAY INDEX would silently
         apply to the wrong location the instant an operator reorders that
         array -- which Config.K9EquipmentShop's own comment explicitly
         invites doing freely -- so this file does not introduce that
         hazard. The EFFECTIVE location list any player actually sees
         (BuildEffectiveLocations below) is always a pure UNION of both
         sources, never a conflict to resolve.

      PRIVILEGE, per this task's own explicit instruction: every mutating
      callback below (`equipmentShopAddLocation`/`MoveLocation`/
      `RemoveLocation`) re-verifies `IsHighCommand(source)` SERVER-SIDE, at
      the point of the action, every single call -- never a flag the NUI
      sent, never a cached client value, never a client-supplied grade.
      Mirrors server/runtimecontrol.lua's own CanManageRuntimeControl/
      CanManageTabletTheme shape as an independent, self-contained copy
      (this file owns no resource-global of runtimecontrol.lua's and calls
      none -- see that file's own header: "THIS FILE exposes no
      resource-global functions") -- same `IsHighCommand` first, then a
      `HasPermission(citizenid, 'k9.equipmentshoplocations')` escape hatch
      behind the usual `type(HasPermission) == 'function'` guard, which
      today always returns false (that key is not yet in
      Config.Permissions) so IsHighCommand alone gates this, exactly
      matching this resource's established "the permission-grant escape
      hatch activates automatically the moment that key is added, zero
      code change here" convention.

      Every mutation is followed by
      `TriggerClientEvent('qbx_k9unit:client:equipmentShopLocationsUpdated', -1, locations)`
      -- the FULL effective location table, same shape GetLocations
      returns -- so an already-connected player's own shop-ped thread (and
      any already-open tablet screen) updates live, without a reconnect or
      a tablet reopen, mirroring server/runtimecontrol.lua's own
      `themeUpdated` broadcast-on-change pattern exactly.

      Callbacks (ox_lib lib.callback), all in THIS file:
        'qbx_k9unit:server:equipmentShopGetLocations' (source) ->
            { ok, locations: table<string, ShopLocation> } -- open to ANY
            connected player (read-only, no privilege check), same
            openness as server/runtimecontrol.lua's GetTheme -- a player
            needs to know where a shop ped goes before they've done
            anything to earn special trust, exactly like the OLD sphere
            zone was reachable by anyone with no gate beyond the flag.
        'qbx_k9unit:server:equipmentShopAddLocation' (source, location:
            { x, y, z, heading?, model?, scenario?, label? }) ->
            { ok, locationKey, locations } | { ok = false, reason }
        'qbx_k9unit:server:equipmentShopMoveLocation' (source,
            locationKey: string, updates: { x?, y?, z?, heading?, model?,
            scenario?, label? }) -> { ok, locations } | { ok = false, reason }
            -- only valid on a `db:` key; see SCOPE above.
        'qbx_k9unit:server:equipmentShopRemoveLocation' (source,
            locationKey: string) -> { ok, locations } | { ok = false, reason }
            -- only valid on a `db:` key; see SCOPE above.
      Every response is a structured `{ ok, reason, ... }` outcome table,
      never player-facing prose -- matches server/runtimecontrol.lua's own
      established "no toast from this file, the tablet renders its own
      inline feedback from `reason`" precedent. No locale keys needed here
      for the identical reason that file states none are needed for itself.

      Client events (server->client), THIS file (server half) / the
      companion client/equipmentshop.lua (client half):
        'qbx_k9unit:client:equipmentShopLocationsUpdated' (locations: table)
            [broadcast to -1 on every successful mutation above]

    ======================================================================
    EVENT/CALLBACK CONTRACT (the ORIGINAL, unchanged shop-registration
    half of this file): no RegisterNetEvent/lib.callback of its own for
    the actual shop transaction. Every player-facing interaction (opening
    the shop, buying an item) already flows entirely through ox_inventory's
    own existing, already-security-reviewed `ox_inventory:openShop`/
    `ox_inventory:buyItem` callbacks. Adding a second, parallel purchase
    path of this resource's own would be pure duplication with a second
    place to get the authorization checks wrong. The RUNTIME SHOP LOCATIONS
    callbacks immediately above are new and additional to this paragraph,
    not a contradiction of it -- they manage WHERE a shop ped stands, never
    what it sells or what it costs.

    ======================================================================
    CONFIG THIS FILE NEEDS (reported, not added here -- config.lua has a
    live owner this session; see this pass's own report for the exact
    fields/comments/defaults):
      Config.Features.K9EquipmentShop : boolean
      Config.K9EquipmentShop : {
          shopType     : string  -- ox_inventory's own shop-type key
          label        : string  -- shown in the ox_target prompt and the ox_inventory UI header;
                          -- also this shop's DEFAULT per-location ox_target label (see below)
          currencyItem : string  -- an ox_inventory item name, e.g. 'money' -- NOT a banking resource
          items        : { { name: string, price: number }, ... }
          pedModel     : string  -- DEFAULT ped model for every shop location (NEW this pass) -- any
                          -- streamed ped, never validated against Config.Peds -- a shop attendant is
                          -- not a K9
          pedHeading   : number  -- DEFAULT heading (degrees) for every shop location (NEW this pass)
          pedScenario  : string|false -- DEFAULT idle scenario for every shop location, or false for
                          -- no scenario (NEW this pass) -- a REAL, VERIFIED scenario name, e.g.
                          -- 'WORLD_DOG_SITTING_SHEPHERD' (client/movement.lua's own K9Sit doc comment
                          -- has the verification this reuses)
          pedModelLoadTimeoutMs : number -- NEW this pass, same purpose/precedent as
                          -- Config.K9Appearance.modelLoadTimeoutMs
          locations    : { { x, y, z, model?, heading?, scenario?, label? }, ... } -- NOT read by
                          -- THIS file's RegisterShop call at all (see point 2 above for why this shop
                          -- is deliberately registered without a `locations` field on the ox_inventory
                          -- payload itself) -- consumed by BuildEffectiveLocations below (for the
                          -- runtime-locations callbacks' read side) and by client/equipmentshop.lua (to
                          -- actually place a ped and an ox_target interaction point per location).
                          -- Each entry may optionally override model/heading/scenario/label for that
                          -- ONE location only, falling back to the four shop-wide defaults above when
                          -- absent (NEW this pass -- previously plain { x, y, z } only). Listed here
                          -- anyway because it lives in the same config table and a server owner adding
                          -- one without the other would silently get a shop that exists but can never
                          -- be opened (server-side warning has no way to detect a client-side gap).
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

-- ======================================================================
-- RUNTIME SHOP LOCATIONS -- see this file's own header "RUNTIME SHOP
-- LOCATIONS" section for the full design/scope/privilege writeup. Every
-- helper and callback below is a SELF-CONTAINED addition: it shares no
-- local with the RegisterShop section above (other than reading the same
-- `Config.K9EquipmentShop` table) and can be read/reviewed independently
-- of it.
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- Server-authoritative: may `source` add/move/remove a runtime shop
--- location right now? Re-resolved fresh on every call, per this task's
--- explicit "re-verifies IsHighCommand() SERVER-SIDE at the point of the
--- action, never trusting a flag the NUI sent" instruction -- never
--- cached, never trusts a client claim of authority. Mirrors
--- server/runtimecontrol.lua's own CanManageRuntimeControl/
--- CanManageTabletTheme SHAPE as an independent, self-contained copy (see
--- this file's own header for why this is not a shared call into that
--- file) -- kept under its OWN permission key
--- ('k9.equipmentshoplocations', not 'k9.runtimecontrol'/'k9.tablettheme')
--- so a server could one day grant "may edit shop locations" without also
--- granting either of those, matching that file's own "kept SEPARATE"
--- reasoning for its own two keys.
--- @param source number
--- @return boolean, string? citizenid -- citizenid is returned when known, for the caller to use as the audit `changed_by`
local function CanManageShopLocations(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.equipmentshoplocations') == true then
        return true, citizenid
    end
    return false, citizenid
end

--- Console log line for every mutating call below -- matches
--- server/runtimecontrol.lua's/server/admin.lua's own "%s ran %s(%s) ->
--- %s" audit format exactly.
--- @param source number
--- @param action string
--- @param detail string
--- @param outcome string
local function LogShopLocationAudit(source, action, detail, outcome)
    local citizenid = ResolveCitizenId(source)
    local whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

--- Fail-closed SELECT wrapper -- pcall around MySQL.query.await, matching
--- server/runtimecontrol.lua's/server/admin.lua's own SafeQuery. A failed
--- read returns an empty table, never a raw Lua error.
--- @param sql string
--- @param params table
--- @return table rows
local function SafeQuery(sql, params)
    local ok, rowsOrErr = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] equipmentshop.lua query failed: %s'):format(tostring(rowsOrErr)))
        return {}
    end
    return rowsOrErr or {}
end

--- pcall-wrapped write helper for INSERT/UPDATE/DELETE that don't need a
--- generated id back -- returns true/false rather than throwing. Every
--- write in this file is a plain statement with `?`-bound parameters only,
--- never a caller-controlled fragment.
--- @param sql string
--- @param params table
--- @return boolean ok
local function SafeWrite(sql, params)
    local ok, err = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] equipmentshop.lua write failed: %s'):format(tostring(err)))
        return false
    end
    return true
end

--- pcall-wrapped INSERT helper for the one write in this file that needs
--- the generated auto-increment id back (equipmentShopAddLocation, to
--- build that new row's own `db:<id>` location key).
--- @param sql string
--- @param params table
--- @return boolean ok, number? insertId
local function SafeInsert(sql, params)
    local ok, resultOrErr = pcall(MySQL.insert.await, sql, params)
    if not ok or type(resultOrErr) ~= 'number' then
        print(('[qbx_k9unit] equipmentshop.lua insert failed: %s'):format(tostring(resultOrErr)))
        return false, nil
    end
    return true, resultOrErr
end

--- Rejects nil, non-number, NaN, and +/-infinity -- never a bare
--- `type(x) == 'number'` alone. Same NaN test as
--- server/runtimecontrol.lua's own SetTunable comment cites
--- (`newValue == newValue`, Lua's standard NaN idiom).
--- @param value any
--- @return boolean
local function IsFiniteNumber(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

--- Strict, small character-level filter for a short player/officer-typed
--- string (a shop ped's model/scenario/label) before it is ever persisted
--- -- a self-contained duplicate of server/runtimecontrol.lua's own
--- IsSafeHeaderTitle, same reasoning: defense in depth on top of whatever
--- renders it later (the tablet's own textContent-only discipline), so a
--- value that somehow reached a different, less careful renderer still
--- could not carry markup or a control sequence. Rejects empty, anything
--- over `maxLen`, and any of `< > & " ' \`` or a control/CR/LF/TAB byte.
--- @param value any
--- @param maxLen number
--- @return boolean
local function IsSafeShortString(value, maxLen)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > maxLen then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

--- In-memory mirror of every row currently in k9_equipment_shop_locations,
--- keyed by that row's own `db:<id>` location key -- populated once at
--- boot (below) and kept in sync by the three mutating callbacks below,
--- rather than re-querying the database on every GetLocations call or
--- every BuildEffectiveLocations build -- same "populated at boot, kept in
--- sync by Set/Reset... rather than re-querying the DB on every tablet
--- open" performance posture as server/runtimecontrol.lua's own
--- ActiveOverrides.
--- @type table<string, { x: number, y: number, z: number, heading: number, model: string?, scenario: string?, label: string? }>
local RuntimeShopLocations = {}

--- @class ShopLocation
--- @field x number
--- @field y number
--- @field z number
--- @field heading number
--- @field model string -- already resolved against Config.K9EquipmentShop.pedModel -- never nil/empty
--- @field scenario string -- already resolved against Config.K9EquipmentShop.pedScenario -- '' means "no scenario", never nil
--- @field label string -- already resolved against Config.K9EquipmentShop.label -- never nil/empty

--- Resolves ONE location's model/heading/scenario/label against this
--- shop's own pedModel/pedHeading/pedScenario/label defaults. Shared by
--- BOTH a Config.K9EquipmentShop.locations entry and a
--- k9_equipment_shop_locations database row below -- both use the exact
--- same optional-field-with-shop-wide-fallback shape, just sourced from a
--- Lua table vs. a SQL row (where a SQL NULL already reads back as Lua
--- `nil` via oxmysql, so no separate NULL-handling branch is needed here).
--- `scenario` distinguishes three states, matching config.lua's own
--- per-location `scenario = false` convention: `false` OR the literal
--- empty string `''` (the database's own way of persisting that same
--- "explicitly no scenario" choice, since SQL has no boolean-false-vs-
--- string type to reuse instead) means "no scenario, even if the shop-wide
--- default has one"; a non-empty string is a real override; `nil` (never
--- set at all) falls through to the shop-wide default.
--- @param x number @param y number @param z number
--- @param heading number? @param model string? @param scenario string|false|nil @param label string?
--- @param shopConfig table -- Config.K9EquipmentShop
--- @return ShopLocation
local function ResolveLocation(x, y, z, heading, model, scenario, label, shopConfig)
    local resolvedHeading = type(heading) == 'number' and heading or shopConfig.pedHeading
    if type(resolvedHeading) ~= 'number' then resolvedHeading = 0.0 end

    local resolvedModel = (type(model) == 'string' and model ~= '') and model or shopConfig.pedModel
    if type(resolvedModel) ~= 'string' or resolvedModel == '' then resolvedModel = 'a_c_shepherd' end

    local resolvedScenario
    if scenario == false or scenario == '' then
        resolvedScenario = ''
    elseif type(scenario) == 'string' then
        resolvedScenario = scenario
    elseif shopConfig.pedScenario == false then
        resolvedScenario = ''
    elseif type(shopConfig.pedScenario) == 'string' and shopConfig.pedScenario ~= '' then
        resolvedScenario = shopConfig.pedScenario
    else
        resolvedScenario = ''
    end

    local resolvedLabel = (type(label) == 'string' and label ~= '') and label
        or (type(shopConfig.label) == 'string' and shopConfig.label ~= '' and shopConfig.label)
        or 'K9 Supply'

    return { x = x, y = y, z = z, heading = resolvedHeading, model = resolvedModel, scenario = resolvedScenario, label = resolvedLabel }
end

--- The full, effective shop location list: every valid
--- Config.K9EquipmentShop.locations entry (keyed `cfg:<index>`) UNIONED
--- with every row currently in RuntimeShopLocations (keyed `db:<id>`) --
--- see this file's header "SCOPE" note for why this is always a pure
--- union, never a conflict to resolve. Safe to call with
--- Config.K9EquipmentShop missing/malformed (returns whatever runtime
--- locations exist, or an empty table) -- this function is read by
--- GetLocations (any connected player) and after every mutation below, so
--- it must never throw regardless of config shape.
--- @return table<string, ShopLocation>
local function BuildEffectiveLocations()
    local out = {}
    local shopConfig = Config.K9EquipmentShop

    if type(shopConfig) == 'table' and type(shopConfig.locations) == 'table' then
        for i, entry in ipairs(shopConfig.locations) do
            if type(entry) == 'table' and IsFiniteNumber(entry.x) and IsFiniteNumber(entry.y) and IsFiniteNumber(entry.z) then
                out['cfg:' .. i] = ResolveLocation(entry.x, entry.y, entry.z, entry.heading, entry.model, entry.scenario, entry.label, shopConfig)
            end
        end
    end

    for key, loc in pairs(RuntimeShopLocations) do
        out[key] = ResolveLocation(loc.x, loc.y, loc.z, loc.heading, loc.model, loc.scenario, loc.label, type(shopConfig) == 'table' and shopConfig or {})
    end

    return out
end

-- Anti-fat-finger cooldown, one shared instance keyed by the calling
-- officer's own source -- covers every mutating callback below. Mirrors
-- server/runtimecontrol.lua's RuntimeControlActionCooldown shape exactly,
-- as a SEPARATE instance (every caller here is already high command or an
-- explicit permission holder, i.e. already trusted -- this guards against
-- a held key or a double-submitted click, not abuse).
local EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS = 1000
local EquipmentShopLocationActionCooldown = NewCooldown(EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS)
EquipmentShopLocationActionCooldown.RegisterPlayerDropped()

-- ======================================================================
-- BOOT -- load every persisted runtime shop location. Deferred to
-- onResourceStart (not this file's own raw top-level), matching
-- server/runtimecontrol.lua's own documented "every existing DB-dependent
-- startup path in this resource defers its first real query into
-- onResourceStart" convention. Independent of the RegisterShop
-- onResourceStart handler above (AddEventHandler allows any number of
-- handlers for the same event; both run, in registration order, when the
-- event actually fires) -- deliberately NOT folded into that same handler,
-- since loading runtime locations must not depend on shopType/items
-- having validated successfully (a broken `items` list still leaves the
-- shop ped worth spawning at its configured spot; ox_inventory simply has
-- nothing to sell there until that's fixed, same as today).
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end

    local rows = SafeQuery('SELECT id, x, y, z, heading, model, scenario, label FROM k9_equipment_shop_locations', {})
    for _, row in ipairs(rows) do
        RuntimeShopLocations['db:' .. row.id] = {
            x = row.x, y = row.y, z = row.z, heading = row.heading,
            model = row.model, scenario = row.scenario, label = row.label,
        }
    end

    print(('[qbx_k9unit] equipmentshop.lua: %d runtime shop location(s) loaded from the database.'):format(#rows))
end)

-- ======================================================================
-- CALLBACKS -- see this file's header "RUNTIME SHOP LOCATIONS" section
-- for the full contract. ALWAYS registered, unconditionally -- each
-- re-checks Config.Features.K9EquipmentShop live, on every call, matching
-- this resource's "live"-tier convention (server/runtimecontrol.lua's own
-- header, "THE ENGINE CONSTRAINT").
-- ======================================================================

lib.callback.register('qbx_k9unit:server:equipmentShopGetLocations', function(source)
    if type(source) ~= 'number' or source <= 0 then
        return { ok = false, reason = 'invalid_source' }
    end
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end
    return { ok = true, locations = BuildEffectiveLocations() }
end)

lib.callback.register('qbx_k9unit:server:equipmentShopAddLocation', function(source, location)
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageShopLocations(source)
    if not authorized then
        LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not EquipmentShopLocationActionCooldown.Consume(source, EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(location) ~= 'table' or not IsFiniteNumber(location.x) or not IsFiniteNumber(location.y) or not IsFiniteNumber(location.z) then
        LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_coords')
        return { ok = false, reason = 'invalid_coords' }
    end

    local heading = 0.0
    if location.heading ~= nil then
        if not IsFiniteNumber(location.heading) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_heading')
            return { ok = false, reason = 'invalid_heading' }
        end
        heading = location.heading % 360
    end

    local model = nil
    if location.model ~= nil then
        if not IsSafeShortString(location.model, 64) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_model')
            return { ok = false, reason = 'invalid_model' }
        end
        model = location.model
    end

    local scenario = nil
    if location.scenario == false then
        scenario = ''
    elseif location.scenario ~= nil then
        if not IsSafeShortString(location.scenario, 64) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_scenario')
            return { ok = false, reason = 'invalid_scenario' }
        end
        scenario = location.scenario
    end

    local label = nil
    if location.label ~= nil then
        if not IsSafeShortString(location.label, 100) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_label')
            return { ok = false, reason = 'invalid_label' }
        end
        label = location.label
    end

    local insertOk, newId = SafeInsert(
        'INSERT INTO k9_equipment_shop_locations (x, y, z, heading, model, scenario, label, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { location.x, location.y, location.z, heading, model, scenario, label, citizenid or 'unknown' }
    )
    if not insertOk then
        LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    local locationKey = 'db:' .. newId
    RuntimeShopLocations[locationKey] = { x = location.x, y = location.y, z = location.z, heading = heading, model = model, scenario = scenario, label = label }

    SafeWrite(
        'INSERT INTO k9_equipment_shop_locations_audit (location_id, action, x, y, z, heading, model, scenario, label, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { newId, 'add', location.x, location.y, location.z, heading, model, scenario, label, citizenid or 'unknown' }
    )

    LogShopLocationAudit(source, 'equipmentShopAddLocation', ('key=%s x=%.2f y=%.2f z=%.2f'):format(locationKey, location.x, location.y, location.z), 'ok')

    local effective = BuildEffectiveLocations()
    TriggerClientEvent('qbx_k9unit:client:equipmentShopLocationsUpdated', -1, effective)

    return { ok = true, locationKey = locationKey, locations = effective }
end)

lib.callback.register('qbx_k9unit:server:equipmentShopMoveLocation', function(source, locationKey, updates)
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageShopLocations(source)
    if not authorized then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(tostring(locationKey)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not EquipmentShopLocationActionCooldown.Consume(source, EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    -- Only ever valid on a `db:<id>` key -- see this file's header "SCOPE"
    -- note. A `cfg:<n>` key (or any other malformed string) is refused
    -- here, never silently accepted and dropped.
    local dbId = type(locationKey) == 'string' and locationKey:match('^db:(%d+)$')
    local current = dbId and RuntimeShopLocations[locationKey]
    if not dbId or not current then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(tostring(locationKey)), 'invalid_key')
        return { ok = false, reason = 'invalid_key' }
    end

    if type(updates) ~= 'table' then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_payload')
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Merge onto the CURRENT row (never onto an empty table) -- an admin
    -- moving only x/y/z must not accidentally blank model/scenario/label
    -- back to nil, mirroring server/runtimecontrol.lua's own SetTheme
    -- merge-then-validate discipline.
    local merged = { x = current.x, y = current.y, z = current.z, heading = current.heading, model = current.model, scenario = current.scenario, label = current.label }

    if updates.x ~= nil or updates.y ~= nil or updates.z ~= nil then
        local x = updates.x ~= nil and updates.x or current.x
        local y = updates.y ~= nil and updates.y or current.y
        local z = updates.z ~= nil and updates.z or current.z
        if not IsFiniteNumber(x) or not IsFiniteNumber(y) or not IsFiniteNumber(z) then
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_coords')
            return { ok = false, reason = 'invalid_coords' }
        end
        merged.x, merged.y, merged.z = x, y, z
    end

    if updates.heading ~= nil then
        if not IsFiniteNumber(updates.heading) then
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_heading')
            return { ok = false, reason = 'invalid_heading' }
        end
        merged.heading = updates.heading % 360
    end

    -- For model/scenario/label: `false` explicitly resets that field back
    -- to nil (i.e. "use the shop-wide default again"), a non-empty valid
    -- string overrides it, anything else is refused outright.
    if updates.model ~= nil then
        if updates.model == false then
            merged.model = nil
        elseif IsSafeShortString(updates.model, 64) then
            merged.model = updates.model
        else
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_model')
            return { ok = false, reason = 'invalid_model' }
        end
    end

    if updates.scenario ~= nil then
        if updates.scenario == false then
            merged.scenario = ''
        elseif IsSafeShortString(updates.scenario, 64) then
            merged.scenario = updates.scenario
        else
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_scenario')
            return { ok = false, reason = 'invalid_scenario' }
        end
    end

    if updates.label ~= nil then
        if updates.label == false then
            merged.label = nil
        elseif IsSafeShortString(updates.label, 100) then
            merged.label = updates.label
        else
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_label')
            return { ok = false, reason = 'invalid_label' }
        end
    end

    local wrote = SafeWrite(
        'UPDATE k9_equipment_shop_locations SET x = ?, y = ?, z = ?, heading = ?, model = ?, scenario = ?, label = ?, updated_by = ? WHERE id = ?',
        { merged.x, merged.y, merged.z, merged.heading, merged.model, merged.scenario, merged.label, citizenid or 'unknown', tonumber(dbId) }
    )
    if not wrote then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    RuntimeShopLocations[locationKey] = merged

    SafeWrite(
        'INSERT INTO k9_equipment_shop_locations_audit (location_id, action, x, y, z, heading, model, scenario, label, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { tonumber(dbId), 'move', merged.x, merged.y, merged.z, merged.heading, merged.model, merged.scenario, merged.label, citizenid or 'unknown' }
    )

    LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s x=%.2f y=%.2f z=%.2f'):format(locationKey, merged.x, merged.y, merged.z), 'ok')

    local effective = BuildEffectiveLocations()
    TriggerClientEvent('qbx_k9unit:client:equipmentShopLocationsUpdated', -1, effective)

    return { ok = true, locations = effective }
end)

lib.callback.register('qbx_k9unit:server:equipmentShopRemoveLocation', function(source, locationKey)
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageShopLocations(source)
    if not authorized then
        LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(tostring(locationKey)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not EquipmentShopLocationActionCooldown.Consume(source, EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    -- Only ever valid on a `db:<id>` key -- see this file's header "SCOPE"
    -- note. Removing a `cfg:<n>` location is not supported from here at
    -- all (never silently accepted and ignored) -- config.lua stays the
    -- one source of truth for its own entries.
    local dbId = type(locationKey) == 'string' and locationKey:match('^db:(%d+)$')
    local existing = dbId and RuntimeShopLocations[locationKey]
    if not dbId or not existing then
        LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(tostring(locationKey)), 'invalid_key')
        return { ok = false, reason = 'invalid_key' }
    end

    local wrote = SafeWrite('DELETE FROM k9_equipment_shop_locations WHERE id = ?', { tonumber(dbId) })
    if not wrote then
        LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(locationKey), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    SafeWrite(
        'INSERT INTO k9_equipment_shop_locations_audit (location_id, action, x, y, z, heading, model, scenario, label, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { tonumber(dbId), 'remove', existing.x, existing.y, existing.z, existing.heading, existing.model, existing.scenario, existing.label, citizenid or 'unknown' }
    )

    RuntimeShopLocations[locationKey] = nil

    LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(locationKey), 'ok')

    local effective = BuildEffectiveLocations()
    TriggerClientEvent('qbx_k9unit:client:equipmentShopLocationsUpdated', -1, effective)

    return { ok = true, locations = effective }
end)
