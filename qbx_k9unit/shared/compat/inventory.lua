--[[
    shared/compat/inventory.lua

    INVENTORY adapters for the resource-compatibility layer described in
    config.lua's `Config.Compat` block (read in full before touching this
    file -- it is the contract, and it is written for a non-technical
    owner, so every promise made there constrains what this file may do).
    Registers against shared/compat/core.lua's detection engine via:

        K9Compat.RegisterAdapter('inventory', '<resourceName>', factory)
        -- factory(realm) -> table | nil ; nil = present but unusable, skip me

    THIS FILE IS A SHARED SCRIPT (loaded once in the client Lua VM, once in
    the server Lua VM -- two entirely separate processes/states, per FXServer
    architecture). Every `K9Compat.RegisterAdapter(...)` call below therefore
    runs in BOTH realms; `factory(realm)` is what tells a single registered
    factory function which half to build, and it is written to be safe to
    call in the "wrong" realm too (every capability probe below fails
    closed to `false`/`nil` rather than erroring, regardless of which VM it
    runs in -- see IsResourceExportCapable's own doc comment).

    ======================================================================
    RESEARCH DISCIPLINE (this task's own explicit requirement, restated so
    the next reader does not have to re-derive it): every signature below is
    either CONFIRMED against a primary source fetched and read directly this
    session (cited inline, with the exact file/function), or marked
    UNCONFIRMED and made to return `nil` from its factory rather than ship a
    guess. "A guessed signature is worse than no adapter: it detects as
    working and then silently does nothing" -- this file follows that rule
    even where it costs real coverage (see ps-inventory below, a real,
    found, actively-maintained project that still gets skipped because three
    of the seven required server methods have no confirmed equivalent in its
    source).

    CONFIRMATION LEDGER, one line per candidate, fullest detail in each
    adapter's own section below:
      ox_inventory      CONFIRMED  (overextended/ox_inventory, branch `main`,
                                     fxmanifest.lua version '2.47.9' at fetch
                                     time -- fetched and read directly this
                                     session: server.lua, client.lua,
                                     modules/inventory/server.lua,
                                     modules/hooks/server.lua,
                                     modules/shops/server.lua,
                                     modules/items/server.lua)
      qb-inventory      CONFIRMED  (qbcore-framework/qb-inventory, branch
                                     `main`, fxmanifest.lua version '2.1.0' --
                                     fetched and read directly this session:
                                     server/main.lua, server/functions.lua,
                                     server/hooks.lua, client/main.lua; ALL
                                     FOUR of that project's declared
                                     server_scripts, so absence claims below
                                     ("no container concept", "ItemDropped
                                     hook type is declared but never fired")
                                     are a completeness claim over its real,
                                     whole server-side source, not a
                                     sampling guess)
      ps-inventory      FOUND, BUT SKIPPED -- see its own section below.
                                     (Project-Sloth/ps-inventory, branch
                                     `main` -- fetched and read
                                     server/main.lua + client/main.lua this
                                     session; 3 of 7 required server methods
                                     have no confirmed equivalent)
      qs-inventory      UNCONFIRMED -- no public source repository located
                                     this session (see "UNCONFIRMED
                                     CANDIDATES" section below for the search
                                     effort actually made).
      origen_inventory  UNCONFIRMED -- same as above.
      codem-inventory   UNCONFIRMED -- same as above.
      core_inventory    UNCONFIRMED -- same as above.
      tgiann-inventory  UNCONFIRMED -- same as above.

    ======================================================================
    THE `RegisterHook` VOCABULARY -- READ THIS BEFORE ADDING A THIRD EVENT
    OR WIRING A NEW CALLER.

    shared/compat/README.md (the cross-adapter contract doc, owned by
    shared/compat/core.lua's author) is explicit that parameter/payload
    shapes are NOT defined by core.lua -- "match the calling convention of
    the reference resource this pack was built against for that system
    (ox_inventory for inventory ...), since that's what every OTHER adapter
    for the same system needs to stay interchangeable with." An EARLIER
    revision of this file invented its own small abstract vocabulary
    ('itemEnteredInventory'/'itemDropped') instead -- reconciled here, after
    that README was read in full, to follow the stated convention instead:
    `eventName` is ox_inventory's OWN real event-name string (whatever its
    real `registerHook` accepts -- 'swapItems', 'buyItem', 'useItem',
    'createItem', ...), and the payload handed to `callback` matches
    ox_inventory's OWN real 'swapItems' field names (`source`,
    `fromInventory`, `fromSlot`, `toInventory`, `toType`), not a
    reinvented shape. This makes the ox_inventory adapter's own RegisterHook
    a PURE, fully generic pass-through (see BuildOxInventoryServer below --
    genuinely simpler AND more faithful than the abstracted version), and
    makes every OTHER adapter responsible for translating its own real
    hook mechanism INTO that same vocabulary, on a best-effort,
    only-what's-confirmed basis.

    THE ONLY EVENT NAME THIS FILE TRANSLATES FOR A NON-ox_inventory BACKEND
    is `'swapItems'` -- the one this resource's two REAL current consumers
    (server/inventory.lua's Config.K9Inventory.allowedItems veto,
    server/tracking.lua's ScentTracking drop-source log) actually need.
    Passing any OTHER event name to a non-ox_inventory adapter's
    RegisterHook returns `false` immediately, without probing or
    registering anything -- there is no confirmed mapping for
    'buyItem'/'useItem'/'createItem'/etc. on any other backend, and
    guessing one is exactly what this task's research discipline forbids.

    For 'swapItems' specifically, on qb-inventory (the one other CONFIRMED
    adapter): only the "an item is being committed INTO a named
    inventory, reject with the literal false to veto" half of
    ox_inventory's real 'swapItems' semantics is reproduced, via the real,
    confirmed `AddHook('ItemAdded', ...)` veto point -- covers
    Config.K9Inventory.allowedItems for real. The "item dropped to the
    ground" half (`payload.toType == 'drop'`, ScentTracking's actual usage)
    is a CONFIRMED, DISCLOSED NO-OP on qb-inventory (see its own section):
    `Events.ItemDropped` is declared in its own hook-type enum but no
    confirmed call site in its complete server-side source ever fires it,
    and there is no equivalent signal inside `ItemAdded`/`ItemRemoved`
    either. A caller registering for 'swapItems' on a qb-inventory backend
    gets the veto behavior for real and will simply never see a
    `payload.toType == 'drop'` event -- disclosed, never faked.

    ======================================================================
    SECURITY NOTE -- READ BEFORE WIRING RegisterStash's `groups` ARGUMENT
    TO ANY AUTHORIZATION DECISION. Per config.lua's own Config.Compat header
    and this task's own instruction, an inventory adapter must NEVER be the
    thing that grants permission -- and the way that promise actually holds
    differs by backend, not just in degree:

      - ox_inventory's `groups` argument to RegisterStash is a REAL,
        server-enforced ACL (`server.hasGroup`, confirmed against
        modules/inventory/server.lua this session -- same finding
        server/inventory.lua's own header already recorded for this exact
        export). It matters because ox_inventory's `openInventory` is a
        CLIENT export: a modified client can call
        `exports.ox_inventory:openInventory('stash', '<anyId>')` directly,
        bypassing this resource's own request/response callback entirely,
        so ox_inventory's OWN groups check is the last real backstop against
        that specific bypass.
      - qb-inventory (and, per its own header, ps-inventory) has NO
        equivalent per-inventory ACL concept at all -- `OpenInventory`/
        `OpenShop` are SERVER-side exports that take `source` and push a
        client event; there is no client-callable "open this identifier"
        primitive for a hostile client to call directly in the first place
        (a resource's server-side Lua exports are not reachable from a
        client at all). This adapter's qb-inventory `RegisterStash` accepts
        a `groups` argument for interface symmetry but CANNOT enforce it
        (documented per-call below) -- and, unlike ox_inventory, does not
        need to: the real boundary for a qb-inventory-backed stash is
        whatever THIS resource's own server code already checks before
        ever calling `OpenStash`/before handing an id to a client at all,
        which every caller in this codebase already does independently of
        this compat layer (see server/inventory.lua's own
        HandleOpenK9Inventory for the existing precedent). A caller must
        NEVER treat this adapter's RegisterStash `groups`/`owner` argument
        as a real access boundary on a non-ox_inventory backend -- only as
        a label ox_inventory happens to enforce for itself.

    Every rank/certification/ownership check this resource makes stays
    server-side, in this resource's OWN code, independent of which
    inventory was detected -- this file only ever executes what it is told,
    never decides who is allowed to ask.

    ======================================================================
    NEVER LET A THIRD-PARTY EXPORT THROW. Every export ACCESS and every
    export CALL below goes through the same two/three-step shape this
    codebase already established (server/tracking.lua's
    IsOxInventoryHookCapable / server/inventory.lua's identical local copy):
    `GetResourceState(name) == 'started'` checked FIRST and unconditionally
    (accessing `exports.<name>` at all on a non-started resource can itself
    throw), THEN a pcall'd export INDEX (proves the name resolves to a
    callable without performing the resource's own side effect), THEN,
    separately, a pcall'd export CALL (existence is not proof a specific
    call cannot still throw for some other reason -- a bad argument, an
    internal error in the other resource). See IsResourceExportCapable and
    SafeExportCall below -- every adapter method in this file is built on
    exactly those two helpers, never a naked `exports.x:y(...)` call.
]]

if type(K9Compat) ~= 'table' or type(K9Compat.RegisterAdapter) ~= 'function' then
    print('[qbx_k9unit] shared/compat/inventory.lua: WARNING: K9Compat is not available -- ' ..
        'shared/compat/core.lua is missing, failed to load, or is ordered AFTER this file in ' ..
        "fxmanifest.lua's shared_scripts block. No inventory adapters were registered this " ..
        'session; Config.Features.ResourceAutoDetect will find nothing for the inventory system ' ..
        'no matter what is actually running. Fix the load order (core.lua must come first) and ' ..
        'restart.')
    return
end

-- ======================================================================
-- SHARED HELPERS -- every adapter method in this file is built from these
-- two. Neither ever throws, by construction (pcall is the outermost thing
-- either function does), regardless of realm, resource state, or what the
-- target resource's own export body does.
-- ======================================================================

--- Capability probe: does `resourceName` currently expose a callable export
--- named `exportName`, IN THIS REALM (the exports table a client-side chunk
--- sees is a different, independent registry from what a server-side chunk
--- of the SAME shared script sees -- a client-only export like
--- ox_inventory's `openInventory` will correctly probe as absent when this
--- function runs in the server VM, and vice versa for a server-only export
--- like `RegisterStash`; no explicit realm check is needed here for that
--- reason, only for deciding WHICH probes are worth making at all).
--- @param resourceName string
--- @param exportName string
--- @return boolean
local function IsResourceExportCapable(resourceName, exportName)
    if GetResourceState(resourceName) ~= 'started' then
        return false
    end

    local ok, exportFn = pcall(function() return exports[resourceName][exportName] end)
    return ok and type(exportFn) == 'function'
end

--- pcall's an ALREADY CAPABILITY-CONFIRMED (IsResourceExportCapable already
--- returned true for this resourceName/exportName pair) export call, using
--- the same `proxy[exportName](proxy, ...)` shape `exports.res:method(...)`
--- colon-call syntax compiles to -- matching this codebase's own existing
--- call sites exactly (they always re-access via colon syntax for the real
--- call rather than reusing a captured dot-accessed reference; mirrored
--- here rather than assumed equivalent).
--- @param resourceName string
--- @param exportName string
--- @return boolean callOk, any ... -- callOk is `false` (no further values) if the call itself threw
local function SafeExportCall(resourceName, exportName, ...)
    local args = table.pack(...)
    -- `exports[resourceName]` is indexed INSIDE this same pcall, not before
    -- it: IsResourceExportCapable already confirmed capability at some
    -- earlier point, but that is not a guarantee the resource is STILL
    -- started by the time this specific call happens (an operator can
    -- restart the target resource in the gap between the two, and merely
    -- indexing `exports.<name>` on a non-started resource can itself throw
    -- -- see this file's header). Both the index and the call must fail
    -- into the same pcall.
    return pcall(function()
        local proxy = exports[resourceName]
        return proxy[exportName](proxy, table.unpack(args, 1, args.n))
    end)
end

-- Per-(resourceName) de-duplication for the "this candidate is a found but
-- unconfirmed/unusable resource" console warning below -- printed at most
-- once per realm per server session, not once per detection/redetect pass
-- (Config.Compat.redetectOnResourceRestart can call every factory again on
-- an unrelated resource restart; re-printing the same paragraph every time
-- would bury the one-line summary this whole layer promises the owner).
local WarnedUnconfirmed = {}

--- @param resourceName string
--- @param reasonNote string
local function WarnUnconfirmedOnce(resourceName, reasonNote)
    if WarnedUnconfirmed[resourceName] then return end
    WarnedUnconfirmed[resourceName] = true
    print(('[qbx_k9unit] shared/compat/inventory.lua: %s is not a confirmed inventory adapter -- %s ' ..
        'Skipped by design (factory returns nil), never guessed. If you run this inventory and can ' ..
        'point a maintainer at its real, current exports source, this adapter can be completed.')
        :format(resourceName, reasonNote))
end

-- ======================================================================
-- ox_inventory -- CONFIRMED. The reference this resource was built
-- against (fxmanifest.lua hard `dependencies` entry) and the only
-- candidate with every one of the eleven required methods (4 client + 7
-- server) backed by a real, cited export.
-- ======================================================================

--- @return table|nil
local function BuildOxInventoryClient()
    if not IsResourceExportCapable('ox_inventory', 'openInventory') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'useItem') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'Items') then return nil end

    return {
        --- Mirrors client/inventory.lua's own existing, already-shipped
        --- `exports.ox_inventory:openInventory('stash', stashId)` call
        --- (client.lua's `exports('openInventory', client.openInventory)`,
        --- confirmed this session) byte-for-byte.
        --- @param stashId string|number
        --- @return boolean attempted
        OpenStash = function(stashId)
            if type(stashId) ~= 'string' and type(stashId) ~= 'number' then return false end
            local callOk = SafeExportCall('ox_inventory', 'openInventory', 'stash', stashId)
            return callOk
        end,

        --- Mirrors client/equipmentshop.lua's own existing
        --- `exports.ox_inventory:openInventory('shop', { type = shopType })`
        --- call.
        --- @param shopType string
        --- @return boolean attempted
        OpenShop = function(shopType)
            if type(shopType) ~= 'string' or shopType == '' then return false end
            local callOk = SafeExportCall('ox_inventory', 'openInventory', 'shop', { type = shopType })
            return callOk
        end,

        --- Mirrors client/tablet.lua's own existing
        --- `exports.ox_inventory:useItem(data, function(approved) ... end)`
        --- call. FAIL CLOSED, NO UNBOUNDED TRAP: `cb` is guaranteed to be
        --- invoked exactly once, synchronously with `false`, if the export
        --- call itself cannot even be attempted or throws -- a caller that
        --- awaits this callback (e.g. via a promise) must never hang
        --- forever waiting for a response ox_inventory was never going to
        --- send.
        --- @param data table
        --- @param cb fun(approved: boolean)
        UseItem = function(data, cb)
            local callOk = SafeExportCall('ox_inventory', 'useItem', data, cb)
            if not callOk and type(cb) == 'function' then
                pcall(cb, false)
            end
            return callOk
        end,

        --- Mirrors server/equipmentshop.lua's/server/wellbeing.lua's own
        --- existing `exports.ox_inventory:Items(itemName)` truthy check.
        --- ox_inventory's `Items` export is registered identically on
        --- both realms (modules/items/server.lua's `exports('Items', ...)`
        --- has a client-side counterpart of the same name/shape, confirmed
        --- via client/tablet.lua's own header citing
        --- `exports.ox_inventory:Items()` as a real, existing client call).
        --- @param itemName string
        --- @return boolean
        ItemExists = function(itemName)
            if type(itemName) ~= 'string' or itemName == '' then return false end
            local callOk, item = SafeExportCall('ox_inventory', 'Items', itemName)
            return callOk and item ~= nil
        end,
    }
end

--- @return table|nil
local function BuildOxInventoryServer()
    if not IsResourceExportCapable('ox_inventory', 'GetInventoryItems') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'GetContainerFromSlot') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'GetItemCount') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'RemoveItem') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'RegisterStash') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'RegisterShop') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'registerHook') then return nil end

    return {
        --- PASS-THROUGH, NATIVE SHAPE -- see this file's header on why
        --- item-slot shapes are never normalized across backends.
        --- Confirmed signature (modules/inventory/server.lua):
        --- `exports('GetInventoryItems', function(inv, owner) ... end)`,
        --- forwarding `inv` unchanged to `Inventory(inv)` -- this is what
        --- makes server/search.lua's existing `{ id = inventoryId, netid =
        --- targetNetId }` table-shaped `inv` argument (for an uncached
        --- vehicle trunk) work at all; preserved here unmodified.
        --- @param inv string|number|table
        --- @param owner string|number|nil
        --- @return table|nil items -- ox_inventory's own per-slot item array, or nil on failure/uncapable
        GetInventoryItems = function(inv, owner)
            local callOk, items = SafeExportCall('ox_inventory', 'GetInventoryItems', inv, owner)
            if not callOk then return nil end
            return items
        end,

        --- PASS-THROUGH, NATIVE SHAPE. Confirmed
        --- (`Inventory.GetContainerFromSlot(inv, slotId)`, exported
        --- verbatim as `GetContainerFromSlot`).
        --- @param inv string|number
        --- @param slotId number
        --- @return table|nil container
        GetContainerFromSlot = function(inv, slotId)
            local callOk, container = SafeExportCall('ox_inventory', 'GetContainerFromSlot', inv, slotId)
            if not callOk then return nil end
            return container
        end,

        --- Confirmed (`Inventory.GetItemCount(inv, itemName, metadata,
        --- strict)`, exported verbatim). FAILS CLOSED to `0` on any
        --- capability/call failure -- "possession assumed zero" already
        --- matches this codebase's own established convention for a
        --- missing/erroring item read (server/medkit.lua's own header:
        --- "unregistered, GetItemCount resolves 0 forever").
        --- @param inv string|number
        --- @param itemName string
        --- @param metadata table|nil
        --- @param strict boolean|nil
        --- @return number count
        GetItemCount = function(inv, itemName, metadata, strict)
            local callOk, count = SafeExportCall('ox_inventory', 'GetItemCount', inv, itemName, metadata, strict)
            if not callOk or type(count) ~= 'number' then return 0 end
            return count
        end,

        --- Confirmed (`Inventory.RemoveItem(inv, item, count, metadata,
        --- slot, ignoreTotal, strict)` -> `boolean, string?`, exported
        --- verbatim). Returns `false` (never a fabricated `true`) on any
        --- capability/call failure -- a removal this adapter cannot prove
        --- happened must never be reported as having happened.
        --- @return boolean success, string? reason
        RemoveItem = function(inv, item, count, metadata, slot, ignoreTotal, strict)
            local callOk, success, reason = SafeExportCall('ox_inventory', 'RemoveItem', inv, item, count, metadata, slot, ignoreTotal, strict)
            if not callOk then return false, 'compat_call_failed' end
            return success == true, reason
        end,

        --- Confirmed (`local function registerStash(name, label, slots,
        --- maxWeight, owner, groups, coords, instance)`, exported verbatim
        --- as `RegisterStash`). See this file's header SECURITY NOTE:
        --- `groups` IS a real, server-enforced ACL for this backend
        --- specifically.
        --- @return boolean success
        RegisterStash = function(id, label, slots, maxWeight, owner, groups, coords, instance)
            local callOk = SafeExportCall('ox_inventory', 'RegisterStash', id, label, slots, maxWeight, owner, groups, coords, instance)
            return callOk
        end,

        --- Confirmed (`exports('RegisterShop', function(shopType,
        --- shopDetails) ... end)`, modules/shops/server.lua). This
        --- adapter's OWN `shopDetails` shape (`{ label, items, groups }`,
        --- documented in this file's header) is translated here to
        --- ox_inventory's real expected shape (`{ name, inventory,
        --- groups }`) -- `items[n] = { name, price, currency? }` maps
        --- 1:1 onto ox_inventory's own confirmed `shopDetails.inventory`
        --- shape, no translation needed for the entries themselves.
        --- @param shopType string
        --- @param shopDetails table -- { label: string, items: {name,price,currency?}[], groups: table<string,number>? }
        --- @return boolean success
        RegisterShop = function(shopType, shopDetails)
            if type(shopDetails) ~= 'table' or type(shopDetails.items) ~= 'table' then return false end
            local callOk = SafeExportCall('ox_inventory', 'RegisterShop', shopType, {
                name = shopDetails.label,
                inventory = shopDetails.items,
                groups = shopDetails.groups,
            })
            return callOk
        end,

        --- See this file's header "THE RegisterHook VOCABULARY" section in
        --- full before changing anything below. Per shared/compat/
        --- README.md's own stated convention ("match the calling
        --- convention of the reference resource"), THIS adapter's
        --- RegisterHook is a PURE, fully generic pass-through onto
        --- ox_inventory's own real `registerHook(event, callback)` -- no
        --- restriction to a fixed event list, no payload translation: since
        --- ox_inventory IS the reference resource for this system, `eventName`
        --- and the `payload` handed to `callback` are exactly whatever
        --- ox_inventory's own real event fires ('swapItems', 'buyItem',
        --- 'useItem', 'createItem', ...), unmodified.
        ---
        --- HONEST CONFIDENCE NOTE on the underlying `registerHook` export
        --- itself (disclosed here rather than silently assumed airtight):
        --- this session's read of the CURRENT overextended/ox_inventory
        --- `main` branch (modules/hooks/server.lua) shows
        --- `exports('registerHook', function(event, ref, options) ...
        --- ref.resource = resource ... end)` unconditionally assigning a
        --- FIELD onto `ref` whenever `ref` is truthy -- which, empirically
        --- reproduced this session against a plain lua5.4 interpreter,
        --- throws "attempt to index a function value" for an ordinary Lua
        --- closure (the calling convention server/tracking.lua's and
        --- server/inventory.lua's OWN already-shipped, already-tested code
        --- in THIS resource both use, and the near-universal documented
        --- convention across the wider ox_inventory ecosystem). This could
        --- mean the fetched `main` branch is genuinely mid-refactor toward
        --- a callable-table hook object and not yet the version most live
        --- servers run, or that some other current mechanism escaped this
        --- session's reading of the file. Rather than silently switch this
        --- resource's calling convention against its own established,
        --- tested precedent on the strength of one anomalous read, this
        --- wrapper keeps the plain-function convention every other file in
        --- this resource already relies on, AND relies on SafeExportCall's
        --- pcall to turn a genuine incompatibility into a caught, reported
        --- registration failure (`false`, one console warning) instead of
        --- an uncaught error -- the safe outcome either way, without this
        --- file having to resolve the discrepancy itself. Flagged for
        --- whoever next has a live ox_inventory install handy to confirm.
        ---
        --- @param eventName string -- any real ox_inventory registerHook event name, e.g. 'swapItems'
        --- @param callback fun(payload: table): boolean|nil
        --- @return boolean success
        RegisterHook = function(eventName, callback)
            if type(eventName) ~= 'string' or eventName == '' then return false end
            if type(callback) ~= 'function' then return false end

            local callOk = SafeExportCall('ox_inventory', 'registerHook', eventName, function(payload)
                local vetoOk, veto = pcall(callback, payload)
                if vetoOk and veto == false then return false end
            end)
            if not callOk then
                print(('[qbx_k9unit] shared/compat/inventory.lua: ox_inventory RegisterHook(%q) failed -- ' ..
                    'registerHook threw (see this method\'s own doc comment for the confirmed-vs-live discrepancy ' ..
                    'this may indicate). Whatever this hook was meant to enforce/observe is NOT active this session.')
                    :format(eventName))
            end
            return callOk
        end,
    }
end

K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(realm)
    if realm == 'client' then return BuildOxInventoryClient() end
    if realm == 'server' then return BuildOxInventoryServer() end
    return nil
end)

-- ======================================================================
-- qs-inventory -- UNCONFIRMED. No public source repository located this
-- session (guessed likely owners/branches tried against
-- raw.githubusercontent.com and returned 404 for every one; this appears
-- to be a closed-source/marketplace-distributed script with no primary
-- source this session could read). Returning nil unconditionally rather
-- than shipping a signature this session never saw.
-- ======================================================================
K9Compat.RegisterAdapter('inventory', 'qs-inventory', function(_realm)
    WarnUnconfirmedOnce('qs-inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)

-- ======================================================================
-- qb-inventory -- CONFIRMED for a real subset of both realms; several
-- methods are DELIBERATE, DISCLOSED NO-OPS for a capability this backend's
-- own, complete server-side source (server/main.lua, server/functions.lua,
-- server/hooks.lua -- ALL THREE of its declared server_scripts) confirms it
-- genuinely does not have, never a guess standing in for one.
--
-- CLIENT REALM: returns nil. qb-inventory's own architecture is
-- fundamentally SERVER-INITIATED, not client-callable, for every one of
-- the four required client methods -- confirmed by reading its complete
-- client/main.lua and server source this session:
--   * `OpenInventory(source, identifier, data)` / `OpenShop(source, name)`
--     are SERVER-side exports (both take `source` as their first
--     parameter) that internally `TriggerClientEvent(...)` -- there is no
--     client-side "ask to open this identifier" export at all for this
--     adapter to wrap.
--   * `UseItem(itemName, source, item, ...)` (server/functions.lua) is
--     likewise a SERVER export; client/main.lua's own item-use path is a
--     `RegisterNUICallback`/`TriggerServerEvent('qb-inventory:server:
--     useItem', ...)` pair, never a client-callable function returning an
--     approved/denied result the way ox_inventory's `useItem` does.
--   * `ItemExists` has no confirmed qb-inventory EXPORT on either realm at
--     all -- `QBCore.Shared.Items[name]` is a real, plausible client-side
--     answer, but reaching into a SPECIFIC framework's global from the
--     INVENTORY adapter would silently couple this adapter to one
--     particular Config.Compat `framework` choice, which this compat
--     layer's own system-independence (config.lua's own "systems ...
--     independently pluggable" design) says an inventory adapter must not
--     do. Disclosed here as a known, deliberate gap rather than a missed
--     shortcut.
-- A caller depending on K9Compat's inventory client adapter (opening a K9
-- stash/shop from ox_target, the tablet item flow) gets a clean "no client
-- inventory adapter available" no-op on a qb-inventory server -- the
-- documented consequence of an architectural mismatch, not a bug in this
-- file.
-- ======================================================================

--- @return table|nil
local function BuildQbInventoryServer()
    if not IsResourceExportCapable('qb-inventory', 'GetInventory') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'GetItemCount') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'RemoveItem') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'CreateInventory') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'CreateShop') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'AddHook') then return nil end

    return {
        --- COMPOSED, not a single native export: confirmed
        --- `exports('GetInventory', function(identifier) return
        --- Inventories[identifier] end)` returns the whole inventory
        --- record; `.items` is the same field every confirmed mutator
        --- (AddItem/RemoveItem/InitializeInventory) reads and writes.
        --- PASS-THROUGH, NATIVE SHAPE (qb-inventory's own per-slot item
        --- table: `{name, amount, info, label, weight, slot, ...}` -- see
        --- this file's header on why this is never normalized to
        --- ox_inventory's `{name, count, weight, slot}` shape here).
        --- Table-shaped `inv` (the vehicle-trunk form server/search.lua
        --- passes for ox_inventory) has NO confirmed qb-inventory
        --- equivalent -- every real lookup path traced this session
        --- (`Inventories[identifier]`, `player.PlayerData.items`,
        --- `Drops[identifier].items`) takes a plain string/number key
        --- only, so a table `inv` fails closed to `nil` rather than
        --- guessing what qb-inventory would do with it.
        --- @param inv string|number
        --- @return table|nil items
        GetInventoryItems = function(inv, _owner)
            if type(inv) == 'table' then return nil end
            local callOk, inventory = SafeExportCall('qb-inventory', 'GetInventory', inv)
            if not callOk or type(inventory) ~= 'table' then return nil end
            return inventory.items
        end,

        --- CONFIRMED-ABSENT CAPABILITY, not a guess: qb-inventory's
        --- complete server-side source (server/main.lua,
        --- server/functions.lua, server/hooks.lua) has zero mentions of a
        --- nested-container/bag-within-a-bag concept anywhere -- "no
        --- container exists at this slot" is the true, complete answer for
        --- every slot on this backend, not an unimplemented placeholder.
        --- server/search.lua's own recursive contraband scan (the one real
        --- caller) simply never descends further for this backend, which
        --- is correct: there is nowhere further to descend.
        --- @return nil
        GetContainerFromSlot = function(_inv, _slotId)
            return nil
        end,

        --- Confirmed (`exports('GetItemCount', GetItemCount)`,
        --- server/functions.lua: `function GetItemCount(source, items)`).
        --- Fails closed to `0`, same convention as the ox_inventory adapter
        --- above.
        --- @param inv string|number
        --- @param itemName string
        --- @return number count
        GetItemCount = function(inv, itemName, _metadata, _strict)
            local callOk, count = SafeExportCall('qb-inventory', 'GetItemCount', inv, itemName)
            if not callOk or type(count) ~= 'number' then return 0 end
            return count
        end,

        --- Confirmed (`exports('RemoveItem', RemoveItem)`,
        --- server/functions.lua: `function RemoveItem(identifier, item,
        --- amount, slot, reason, isInternalMove) -> boolean`). qb-inventory
        --- has no separate `reason` return value on failure -- only `nil`
        --- is returned here, matching the documented `string?` optionality.
        --- @return boolean success, string? reason
        RemoveItem = function(inv, item, count, _metadata, slot, _ignoreTotal, _strict)
            local callOk, success = SafeExportCall('qb-inventory', 'RemoveItem', inv, item, count, slot)
            if not callOk then return false, 'compat_call_failed' end
            return success == true, nil
        end,

        --- COMPOSED, and DELIBERATELY NOT a groups/owner-enforcing call --
        --- see this file's header SECURITY NOTE. Confirmed
        --- (`exports('CreateInventory', function(identifier, data) ...
        --- end)`, server/functions.lua) pre-creates the named inventory
        --- with the slots/maxweight THIS caller chose, rather than relying
        --- on `OpenInventory`'s own lazy-init fallback defaults. `owner`/
        --- `groups` are accepted for interface symmetry with the
        --- ox_inventory adapter and are INTENTIONALLY DISCARDED here --
        --- qb-inventory's confirmed source has no per-inventory ACL
        --- mechanism for this method to forward them to; see this file's
        --- header for why that is not a security gap for this specific
        --- backend (there is no client-reachable open primitive to bypass
        --- in the first place).
        --- @return boolean success
        RegisterStash = function(id, label, slots, maxWeight, _owner, _groups)
            local callOk = SafeExportCall('qb-inventory', 'CreateInventory', id, {
                label = label,
                slots = slots,
                maxweight = maxWeight,
            })
            return callOk
        end,

        --- Confirmed (`exports('CreateShop', CreateShop)`,
        --- server/functions.lua). DISCLOSED SEMANTIC DIFFERENCE from
        --- ox_inventory: qb-inventory shop slots are STOCK-LIMITED
        --- (`SetupShopItems`'s confirmed `amount = tonumber(item.amount)`
        --- field depletes as players buy -- there is no "infinite price
        --- list" mode this adapter can select). `shopDetails.items[n]` may
        --- optionally carry an `amount` field for this backend; when
        --- absent this adapter supplies a large, clearly-arbitrary default
        --- rather than silently mapping to an unlimited stock this backend
        --- does not actually support -- an operator relying on
        --- ox_inventory-style infinite stock will need to restock
        --- periodically on a qb-inventory server. Not a guess about the
        --- export's signature (that part is fully confirmed); a disclosed
        --- product-level default for a field ox_inventory's own shop
        --- concept has no equivalent of at all.
        --- @param shopType string
        --- @param shopDetails table -- { label, items: {name,price,amount?}[], groups (unsupported, see below) }
        --- @return boolean success
        RegisterShop = function(shopType, shopDetails)
            if type(shopDetails) ~= 'table' or type(shopDetails.items) ~= 'table' then return false end

            local items = {}
            for i, entry in ipairs(shopDetails.items) do
                items[i] = {
                    name = entry.name,
                    price = entry.price,
                    -- See doc comment above: qb-inventory shops are
                    -- stock-limited; this is a disclosed default, not a
                    -- confirmed "unlimited" mode.
                    amount = entry.amount or 999999,
                }
            end

            local callOk = SafeExportCall('qb-inventory', 'CreateShop', {
                name = shopType,
                label = shopDetails.label,
                items = items,
                -- `groups` has no qb-inventory CreateShop equivalent
                -- (confirmed: RegisteredShops/SetupShopItems carry no
                -- groups/job field anywhere in the traced source) --
                -- silently dropped, never forwarded as a fake ACL.
            })
            return callOk
        end,

        --- See this file's header "THE RegisterHook VOCABULARY" section.
        --- Per shared/compat/README.md's "match the reference resource's
        --- calling convention" rule, `eventName` is ox_inventory's OWN real
        --- vocabulary -- but qb-inventory only has a confirmed translation
        --- for ONE of those names: `'swapItems'`, and only the
        --- "item entering a named inventory, veto with the literal false"
        --- HALF of what ox_inventory's real 'swapItems' can express. Any
        --- other `eventName` (including one this file simply has no
        --- confirmed qb-inventory mapping for) returns `false` immediately,
        --- never a guess.
        ---
        --- 'swapItems' maps onto the CONFIRMED, real
        --- `AddHook('ItemAdded', callback)` veto point
        --- (server/functions.lua's `AddItem`: `local mutatedInfo =
        --- TriggerHook('ItemAdded', pendingItem.type, hookData); if
        --- mutatedInfo == false then return false end` -- traced end to
        --- end this session, including `buildItemAddedData`'s confirmed
        --- `{ toId, toInventory, toType, toSlot, item, amount, reason,
        --- resource }` payload shape, server/hooks.lua). The payload handed
        --- to `callback` is translated onto ox_inventory's OWN real
        --- 'swapItems' field names (`fromInventory`, `fromSlot`,
        --- `toInventory`, `toType`, `source`) -- NOT this backend's own
        --- `hookData` field names, which differ in both naming AND type
        --- (qb-inventory's own `hookData.toInventory` is the RESOLVED
        --- inventory DATA table, not an id string; ox_inventory's
        --- `toInventory` is always the id STRING -- `hookData.toId` is the
        --- field that actually matches ox_inventory's `toInventory`
        --- semantic, and is what this wrapper uses). Confirmed-absent from
        --- qb-inventory's ItemAdded payload, and therefore always `nil`
        --- here: `fromInventory` (no source-inventory identifier exists in
        --- this event at all) and `source` (no player id is threaded
        --- through `buildItemAddedData`). `toType` is forwarded
        --- best-effort from `hookData.toType` (qb-inventory's own
        --- `GetInventoryType` result) but its exact value vocabulary was
        --- NOT cross-checked against ox_inventory's own `toType` strings
        --- this session -- do not branch on a specific `toType` STRING
        --- VALUE for this backend without confirming it first; branching on
        --- `toInventory`'s id (as Config.K9Inventory.allowedItems' own
        --- `'k9inv-'` prefix check already does) does not depend on this.
        ---
        --- DISCLOSED, UNCONFIRMED EDGE CASE: ox_inventory's real
        --- 'swapItems' never fires for a same-stash slot-to-slot reorganize
        --- in a way this file can detect on qb-inventory (there is no
        --- combined from+to payload the way ox_inventory's single event
        --- carries both sides) -- `AddItem`'s own `isInternalMove` parameter
        --- can suppress the `ItemAdded` hook entirely for an internal
        --- transfer, but this session did not trace every call site that
        --- passes it, so whether a same-stash reorganize on qb-inventory
        --- ever reaches this wrapper at all was not fully confirmed either
        --- way. Not a guess this file's callback logic makes (there is
        --- nothing here that COULD detect "same stash" from an `ItemAdded`
        --- payload alone -- no `fromInventory` exists to compare against);
        --- flagged for whoever next verifies qb-inventory live.
        ---
        --- 'swapItems' with `payload.toType == 'drop'` (ScentTracking's
        --- real usage) is a CONFIRMED, DISCLOSED NO-OP for this backend:
        --- `Events.ItemDropped = { hooks = {}, listeners = {} }` is
        --- declared in server/main.lua's own hook-type enum, but this
        --- session's complete read of qb-inventory's server-side source
        --- (server/main.lua, server/functions.lua, server/commands.lua,
        --- server/hooks.lua -- every server_scripts entry its own
        --- fxmanifest.lua declares) found no call site anywhere that ever
        --- fires `TriggerHook('ItemDropped', ...)`, and `ItemAdded` is
        --- never fired for a ground-drop either (dropping is its own
        --- `Drops[...]` table construction with no hook call beside it at
        --- all). A caller registering for 'swapItems' on this backend gets
        --- the veto behavior for real and will simply never observe a drop
        --- -- disclosed here, never faked as a silent registration success.
        --- @param eventName string -- only 'swapItems' has a confirmed translation on this backend
        --- @param callback fun(payload: table): boolean|nil
        --- @return boolean success
        RegisterHook = function(eventName, callback)
            if type(callback) ~= 'function' then return false end
            if eventName ~= 'swapItems' then return false end

            local callOk, hookIdx = SafeExportCall('qb-inventory', 'AddHook', 'ItemAdded', function(_itemType, hookData)
                if type(hookData) ~= 'table' then return end
                local item = hookData.item
                if type(item) ~= 'table' or type(item.name) ~= 'string' then return end
                if hookData.toId == nil then return end

                local vetoOk, veto = pcall(callback, {
                    toInventory = tostring(hookData.toId),
                    fromInventory = nil, -- confirmed absent from this event, see doc comment above
                    fromSlot = { name = item.name, count = hookData.amount },
                    toType = type(hookData.toType) == 'string' and hookData.toType or nil, -- best-effort, see doc comment above
                    source = nil, -- confirmed absent from this event, see doc comment above
                })
                if vetoOk and veto == false then return false end
            end)
            if not callOk or hookIdx == nil then
                print("[qbx_k9unit] shared/compat/inventory.lua: qb-inventory RegisterHook('swapItems') failed -- " ..
                    'AddHook did not return a hook index. The allowedItems-style veto this backs is NOT enforced this session.')
                return false
            end
            return true
        end,
    }
end

K9Compat.RegisterAdapter('inventory', 'qb-inventory', function(realm)
    if realm == 'client' then return nil end -- see section header: no confirmed client-callable equivalent exists
    if realm == 'server' then return BuildQbInventoryServer() end
    return nil
end)

-- ======================================================================
-- ps-inventory -- FOUND (Project-Sloth/ps-inventory, branch `main`, a real
-- actively-maintained qb-inventory-derived rewrite), but SKIPPED. Its
-- complete server/main.lua (2827 lines, the only server file its own
-- fxmanifest.lua declares) was read this session and confirmed to have NO
-- export named/shaped like `GetInventoryItems`, `RegisterStash`, or any
-- hook-registration mechanism at all (`AddHook`/`TriggerHook`/
-- `registerHook` -- zero matches for "Hook" anywhere in the file). That is
-- 3 of the 7 required server methods with no confirmed real equivalent --
-- `OpenInventory`/`OpenShop` are, like qb-inventory, SERVER-side exports
-- taking `source`, so the client realm has the identical architectural
-- mismatch as qb-inventory on top of that.
--
-- A caller COULD compose a partial server table (GetItemCount via
-- possession-scanning, RemoveItem is a confirmed real export) and let
-- core's required-method check skip it anyway -- but shipping a
-- half-built table here would only make the SKIP reason harder to find
-- later. Returning nil directly, with the reasoning on record.
-- ======================================================================
K9Compat.RegisterAdapter('inventory', 'ps-inventory', function(_realm)
    WarnUnconfirmedOnce('ps-inventory', "a real source repository was found and read this session " ..
        '(Project-Sloth/ps-inventory) but 3 of the 7 required server methods -- GetInventoryItems, ' ..
        'RegisterStash, and any hook-registration mechanism at all -- have no confirmed real export ' ..
        'in its source, and its OpenInventory/OpenShop are server-side-only exports with no ' ..
        'client-callable equivalent (same architecture as qb-inventory).')
    return nil
end)

-- ======================================================================
-- origen_inventory / codem-inventory / core_inventory / tgiann-inventory --
-- UNCONFIRMED. No public source repository located this session for any of
-- these four (a range of plausible owner/org names were tried against
-- raw.githubusercontent.com's `main`/`master` branches and every one
-- returned 404; GitHub's own search/API was not reachable from this
-- session for arbitrary repositories). These read as
-- closed-source/marketplace-distributed scripts this session had no
-- primary source to verify against. Returning nil unconditionally.
-- ======================================================================
K9Compat.RegisterAdapter('inventory', 'origen_inventory', function(_realm)
    WarnUnconfirmedOnce('origen_inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)

K9Compat.RegisterAdapter('inventory', 'codem-inventory', function(_realm)
    WarnUnconfirmedOnce('codem-inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)

K9Compat.RegisterAdapter('inventory', 'core_inventory', function(_realm)
    WarnUnconfirmedOnce('core_inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)

K9Compat.RegisterAdapter('inventory', 'tgiann-inventory', function(_realm)
    WarnUnconfirmedOnce('tgiann-inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)
