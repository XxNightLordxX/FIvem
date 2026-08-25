--[[
    qbx_k9unit/client/equipmentshop.lua

    K9 EQUIPMENT SHOP (client half) -- FEATURE_IDEAS.md Part B §6. See
    server/equipmentshop.lua's own header for the full design and, in
    particular, its "VERIFIED, NOT ASSUMED" section point 2 for exactly why
    this small companion file exists at all: a shop registered from an
    EXTERNAL resource via `exports.ox_inventory:RegisterShop` gains no
    walk-up marker/prompt of its own -- ox_inventory's own internal
    marker/target system only ever reads shops from ITS OWN bundled
    `data/shops.lua`, never from anything registered later via that export.
    This file is the physical interaction point that makes the
    server-registered shop actually reachable.

    NO GAME LOGIC LIVES HERE. This file does exactly one thing: creates an
    `ox_target` sphere zone (ox_target is already a hard dependency of this
    resource) at each configured location, whose only action opens
    ox_inventory's own shop UI via its own real, existing client export.
    Every real check -- can this player see this shop, can they afford an
    item, is the item real -- happens entirely inside ox_inventory's own
    already-security-reviewed code, server-side. This resource decides
    nothing here; it only places a door.

    `groups` on the zone's own option is a VISUAL/UX filter ONLY, mirroring
    ox_inventory's own client module doing the identical thing for its
    internal shops -- it hides the prompt from an obviously-ineligible
    player as a convenience. It is NOT the authorization boundary: even if
    a modified client removed this filter and opened the shop anyway,
    ox_inventory's own server-side `hasGroup` check inside its
    `ox_inventory:openShop` callback (server/equipmentshop.lua's header,
    point 4) still decides what that player can actually see or buy.

    Reads `Config.K9EquipmentShop`/`Config.Features.K9EquipmentShop`
    defensively throughout -- see server/equipmentshop.lua's own header for
    the exact shape this expects and why a server that has not (yet) added
    either is a silent, total no-op here too: no zone, no ox_target call, no
    error.

    FXMANIFEST.LUA PLACEMENT REQUESTED (client_scripts, not edited here):
    insert `'client/equipmentshop.lua',` anywhere after `'client/main.lua',`
    -- no load-order requirement (this file reads only `Config`, a
    shared_script already loaded before any client_scripts entry, and calls
    only `exports.ox_target`/`exports.ox_inventory`, both already-loaded
    dependencies).
]]

CreateThread(function()
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end

    local shopConfig = Config.K9EquipmentShop
    if type(shopConfig) ~= 'table' or type(shopConfig.shopType) ~= 'string' or shopConfig.shopType == '' then
        -- server/equipmentshop.lua's own onResourceStart guard already
        -- warns loudly server-side for this exact case -- nothing further
        -- to print here, a silent client-side no-op is correct (this file
        -- has no server console to be seen in anyway).
        return
    end

    if type(shopConfig.locations) ~= 'table' or #shopConfig.locations == 0 then
        print('[qbx_k9unit] equipmentshop (client): Config.K9EquipmentShop.locations is missing or empty -- no interaction point can be created, so the shop (even if registered server-side) has nowhere to be opened from. Add at least one vector3 to Config.K9EquipmentShop.locations.')
        return
    end

    -- Same groups derivation as server/equipmentshop.lua's own copy, over
    -- the same already-existing Config.Departments -- kept as an
    -- independent copy rather than a shared read, since this is a
    -- CLIENT-side visual filter only (see this file's own header) and the
    -- two files have no other call-time dependency on each other.
    local groups = nil
    if type(Config.Departments) == 'table' then
        groups = {}
        for jobName in pairs(Config.Departments) do
            groups[jobName] = 0
        end
        if next(groups) == nil then groups = nil end
    end

    local label = (type(shopConfig.label) == 'string' and shopConfig.label ~= '') and shopConfig.label or 'K9 Supply'

    for _, coords in ipairs(shopConfig.locations) do
        exports.ox_target:addSphereZone({
            coords = coords,
            radius = 1.5,
            debug = false,
            options = {
                {
                    label = label,
                    icon = 'fas fa-shopping-basket',
                    groups = groups,
                    onSelect = function()
                        exports.ox_inventory:openInventory('shop', { type = shopConfig.shopType })
                    end,
                },
            },
        })
    end
end)
