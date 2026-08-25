--[[
    qbx_k9unit/client/inventory.lua

    Phase 4 implementation (coder-backend), PHASE4_SPEC.md §13.4.2 ("K9
    Inventory", `Config.Features.K9Inventory`) — see server/inventory.lua's
    header for the full design writeup this file is the client half of
    (RESOLVED accessScope decision, CONFIDENCE NOTEs on every ox_inventory
    export/shape this file's body depends on, the whole validation-order
    discipline). `Config.Features.K9Inventory` stays `false` shipped.

    ======================================================================
    EVENT/CALLBACK CONTRACT — see server/inventory.lua for the full
    'qbx_k9unit:server:openK9Inventory' callback contract (THIS FILE is its
    only client-side caller).

    RESOLVED (was a KNOWN GAP flagged here; closed this pass, not left
    stale): PHASE4_SPEC.md §13.4.2 describes the ox_target option appearing
    "on the K9 player's own ped," which server/inventory.lua's contract
    supports for BOTH a nearby department officer AND the K9 player
    accessing their own stash (see IsAuthorizedForK9Inventory's `isSelf`
    branch there — confirmed self-access still requires the acting
    player's own HasK9Access, same as every other path into this
    callback). This file previously only wired the ox_target entry point
    below, with self-targeting via ox_target being awkward/unusual UX and
    no global exposed for a radial item to call instead. Now closed:
    RequestOpenOwnK9Inventory() below is that self-service entry point —
    see its own doc comment for the full contract. A future
    client/radial.lua "Open My Gear" item can call it directly without
    reaching into ox_inventory itself, per this file's own established
    "radial calls a global, never the export directly" split.

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls the server's 'qbx_k9unit:server:openK9Inventory'
      lib.callback and exports.ox_inventory:openInventory — see this file's
      header CONFIDENCE NOTE below for the latter's verification status.
    - This file's ox_target canInteract predicate below calls
      client/main.lua's resource-global `IsEntityModelK9(entity)`
      (REFACTOR_ROADMAP.md item 3) rather than keeping its own small local
      copy — client/main.lua is loaded first (fxmanifest.lua's
      client_scripts order) and this call only ever happens at
      canInteract-invocation time (never at this file's own load time), so
      no runtime existence guard is needed, matching client/movement.lua's/
      client/partnership.lua's own established pattern for the same call.
      NOT a security check either way — the server independently
      re-verifies the real model via IsConfiguredK9Model.
    - THIS FILE exposes one resource-global function for a radial entry
      point: `RequestOpenOwnK9Inventory()` — see its own doc comment near
      the bottom of this file. It is the ONLY caller-facing seam into this
      file's request/response + exports.ox_inventory:openInventory
      sequence; a caller (a future client/radial.lua item) never needs its
      own exports.ox_inventory:openInventory call, matching this
      resource's convention (see client/movement.lua's/client/fetch.lua's
      own resource-global exports) that a radial item calls a thin global
      here, never a third-party export directly.
    ======================================================================

    CONFIDENCE NOTE: `exports.ox_inventory:openInventory('stash', stashId)`
    is cited directly by PHASE4_SPEC.md §13.4.2 as "the standard ox_target +
    ox_inventory pattern" — MEDIUM confidence, not independently
    re-verified against the real ox_inventory source or a live install this
    session (same status server/inventory.lua's header gives RegisterStash).

    RUNTIME EXISTENCE GUARD (this pass): OpenK9InventoryForNetId's call to
    `exports.ox_inventory:openInventory` used to be a naked, unguarded
    export call — the ONLY third-party-resource export call in this file
    with no `type(x) == 'function'`-style existence check at all, unlike
    this file's server-side counterpart (server/inventory.lua's
    `IsOxInventoryHookCapable` around `registerHook`). Fixed: see
    `IsOxInventoryOpenCapable()` immediately above OpenK9InventoryForNetId —
    same `GetResourceState('ox_inventory') == 'started'` + pcall'd
    export-access shape, so an ox_inventory restart/version mismatch after
    THIS resource has already started degrades to a logged warning + a
    player-facing `inventory.unable_to_open_generic` notify, never an
    uncaught error out of an ox_target onSelect/RequestOpenOwnK9Inventory
    call. The call itself is additionally pcall'd (existence is not proof
    the call can't still throw for some other reason) with the same
    fail-safe notify.
]]

--- Human-readable rejection messages for the openK9Inventory callback's
--- `reason` value. Mirrors server/main.lua's LEASH_REJECT_MESSAGES /
--- server/search.lua's reason-handling shape exactly.
-- NOTE: 'on_cooldown' and 'request_in_progress' are deliberately absent from
-- this table — both are routine, expected traffic (a double-click, a
-- hovering re-trigger), handled as a silent no-op below (never looked up
-- here at all), same treatment RESEARCH_ARCHIVE.md#contraband-search §4's
-- "Rejection UX note" already recommends for search's identical on_cooldown
-- case.
-- Each value below is a distinct locale() call (not a plain string) rather
-- than a table literal, since these must be resolved through ox_lib's
-- locale() at lookup time like every other player-facing string in this
-- resource — see locales/README.md. Kept as six SEPARATE keys (not
-- collapsed into one templated message): each reason is a genuinely
-- different failure cause (disabled feature vs. wrong target vs. no
-- certification vs. too far vs. not authorized vs. a stash-open failure),
-- the same non-collapsing discipline locales/README.md documents for
-- server/kennel.lua's similarly-shaped NotifyPlayer messages.
local K9_INVENTORY_REASON_MESSAGES = {
    feature_disabled  = locale('inventory.reason_feature_disabled'),
    invalid_target    = locale('inventory.reason_invalid_target'),
    no_access         = locale('inventory.reason_no_access'),
    too_far           = locale('inventory.reason_too_far'),
    not_authorized    = locale('inventory.reason_not_authorized'),
    stash_failed      = locale('inventory.reason_stash_failed'),
}

--- RUNTIME EXISTENCE GUARD for the ox_inventory `openInventory` export this
--- file calls below to actually present the stash UI once the server has
--- granted access. ox_inventory is a hard `fxmanifest.lua` `dependencies`
--- entry, which only guarantees it was RUNNING at the moment THIS resource
--- itself started — it does NOT guarantee the export still exists for the
--- rest of this resource's lifetime (an operator can `restart ox_inventory`
--- independently of this one, or run a fork/older build missing this
--- export), so this is a runtime check, never a load-order assumption —
--- same `GetResourceState` + pcall'd export-access shape as
--- server/inventory.lua's own `IsOxInventoryHookCapable` (the server-side
--- `registerHook` export); this is the client-side equivalent for
--- `openInventory`, per this project's "check `type(x) == 'function'`
--- before calling into another resource's global/export" rule.
--- @return boolean
local function IsOxInventoryOpenCapable()
    if GetResourceState('ox_inventory') ~= 'started' then
        return false
    end

    local ok, openExport = pcall(function() return exports.ox_inventory.openInventory end)
    return ok and type(openExport) == 'function'
end

--- Shared "ask the server to open this stash, then open it client-side"
--- implementation — called by both the ox_target `onSelect` below (netId
--- resolved from the interacted ped) and RequestOpenOwnK9Inventory()
--- further down (netId resolved from the local player's own ped). Kept as
--- the ONE place that awaits the callback, interprets its `reason`, and
--- calls exports.ox_inventory:openInventory — so a future reason value, or
--- the ox_inventory open call itself, only needs updating here, and no
--- caller of RequestOpenOwnK9Inventory ever needs its own
--- exports.ox_inventory:openInventory call (this file's header's own
--- "radial calls a global, never the export directly" contract).
--- @param netId number
local function OpenK9InventoryForNetId(netId)
    -- FAIL-CLOSED GUARD (dependency-verification finding, this pass):
    -- `lib.callback.await` throws rather than returning nil on a timeout
    -- or unregistered-callback rejection (see client/main.lua's
    -- HasK9Access() doc comment for the full ox_lib/FiveM source
    -- citation). pcall it; the `not result` branch immediately below
    -- already covers a pcall-caught nil `result` byte-for-byte the same
    -- as any other falsy response (reason stays nil, so this degrades to
    -- the existing silent-return path rather than aborting uncaught).
    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:openK9Inventory', false, netId)
    if not ok then result = nil end

    if not result or not result.ok then
        local reason = result and result.reason
        -- 'on_cooldown'/'request_in_progress' are routine, expected
        -- traffic (a double-click, a hovering re-trigger) — same
        -- silent-no-op treatment RESEARCH_ARCHIVE.md#contraband-search §4's
        -- "Rejection UX note" already recommends for search's
        -- identical on_cooldown case, applied here to this file's
        -- two analogous reasons.
        if reason and reason ~= 'on_cooldown' and reason ~= 'request_in_progress' then
            lib.notify({
                title = locale('common.notify_title'),
                description = K9_INVENTORY_REASON_MESSAGES[reason] or locale('inventory.unable_to_open_generic'),
                type = 'error',
            })
        end
        return
    end

    -- The server has already granted access (EnsureK9Stash succeeded
    -- server-side) by the time we get here — a failure past this point is
    -- purely "could not present the UI client-side," never a
    -- re-litigation of access, so it always gets the same generic
    -- unable-to-open copy rather than any of K9_INVENTORY_REASON_MESSAGES
    -- (those are all server-decision reasons, not applicable here).
    if not IsOxInventoryOpenCapable() then
        print(('[qbx_k9unit] WARNING: server granted K9 stash %s but ox_inventory\'s ' ..
            'openInventory export is unavailable client-side (ox_inventory is missing, not ' ..
            'started, or this build does not support it) -- the stash UI could not be opened.')
            :format(tostring(result.stashId)))
        lib.notify({
            title = locale('common.notify_title'),
            description = locale('inventory.unable_to_open_generic'),
            type = 'error',
        })
        return
    end

    -- pcall'd defensively (not just existence-guarded above): the export
    -- existing is not proof the call itself cannot throw for some other
    -- reason (a malformed stashId, an internal ox_inventory error, etc) —
    -- never let that propagate as an uncaught error out of an ox_target
    -- onSelect/RequestOpenOwnK9Inventory call, same "never a naked
    -- third-party export call with no fail path" discipline this file's
    -- server-side counterpart applies to RegisterStash (EnsureK9Stash).
    local openOk = pcall(function()
        exports.ox_inventory:openInventory('stash', result.stashId)
    end)

    if not openOk then
        lib.notify({
            title = locale('common.notify_title'),
            description = locale('inventory.unable_to_open_generic'),
            type = 'error',
        })
    end
end

--- Register the "Open K9 Gear" ox_target option on nearby player peds whose
--- live model is (plausibly, client-side) a configured K9 model. Display
--- optimization only — server/inventory.lua's openK9Inventory callback
--- independently re-validates feature flag, target model/certification,
--- proximity, and interactor authorization for real; this predicate does
--- not need to be perfect (same posture client/movement.lua's own
--- attachLeash option documents for its analogous canInteract).
---
--- LIFECYCLE FIX (this pass): extracted into a named function, sole call
--- site the `AddEventHandler('onResourceStart', ...)` below, so this
--- option comes back after a bare `restart ox_target` and not just after
--- this resource's own restart — see that handler's own doc comment
--- (mirrors server/tracking.lua's RegisterScentInventoryHook /
--- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
--- identical bug class: ox_target keeps addGlobalPlayer's registry in a
--- plain file-local Lua table inside its own client chunk, confirmed by
--- reading ox_target's client/api.lua, which reloads empty on ox_target's
--- own restart with nothing else prompting a re-add). DUPLICATE-VS-REPLACE:
--- the option below always sets `name`, and ox_target's own `addTarget`
--- unconditionally removes any existing option with the same name+resource
--- before appending, so re-running this never duplicates the entry.
local function RegisterK9InventoryOxTargetOption()
    exports.ox_target:addGlobalPlayer({
        {
            name = 'qbx_k9unit:openK9Inventory',
            icon = 'fas fa-briefcase',
            label = locale('inventory.open_gear_target_label'),
            distance = Config.K9Inventory.interactRange,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.K9Inventory then return false end
                if not IsEntityModelK9(entity) then return false end

                -- The K9 player accessing their OWN stash is always authorized
                -- server-side (see server/inventory.lua's
                -- IsAuthorizedForK9Inventory `isSelf` branch) — always show the
                -- option for self, independent of accessScope or job.
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then
                    return true
                end

                -- Otherwise, DISPLAY-ONLY approximation of accessScope: only
                -- show the option to a player whose own job is a configured
                -- department. `accessScope ~= 'department'` is UNREACHABLE
                -- today — server/inventory.lua's onResourceStart assert
                -- hard-enforces accessScope == 'department' (coder-security
                -- finding: any other value, including 'ownerOnly', provided no
                -- real ox_inventory access control at all) — kept as
                -- defense-in-depth so this UI never shows a stale/misleading
                -- option if that invariant is ever loosened. QBX.PlayerData is
                -- the live-updated client-side job cache this resource's
                -- fxmanifest.lua already documents as the standard source for
                -- this, per '@qbx_core/modules/playerdata.lua'.
                if Config.K9Inventory.accessScope ~= 'department' then
                    return false
                end

                local job = QBX.PlayerData and QBX.PlayerData.job
                return job ~= nil and Config.Departments[job.name] ~= nil
            end,
            onSelect = function(data)
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                OpenK9InventoryForNetId(netId)
            end,
        },
    })
end

-- Sole call site for RegisterK9InventoryOxTargetOption(): this resource's
-- own start, or ox_target's own start — mirrors server/tracking.lua's
-- RegisterScentInventoryHook / server/inventory.lua's
-- RegisterK9InventoryItemFilterHook fixes for the identical class of gap
-- against ox_inventory.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == 'ox_target' then
        RegisterK9InventoryOxTargetOption()
    end
end)

--- Resource-global — radial self-service entry point (see FILE-TO-FILE
--- CONTRACT above and this file's own now-RESOLVED header note). Mirrors
--- client/movement.lua's RequestLeashAttach() / client/medkit.lua's
--- RequestTreatNearestK9() shape: re-checks CanShowK9UI() itself rather
--- than trusting that a caller (a future client/radial.lua item) already
--- did, per this codebase's "must not be triggerable by a modified
--- client" spirit — the server re-validates independently regardless
--- (server/inventory.lua's HandleOpenK9Inventory, including its own
--- HasK9Access(targetServerId) check, which for a self-request means
--- `targetServerId == source`, i.e. the requester's OWN certification is
--- what gates this, exactly matching CanShowK9UI()'s own
--- IsOwnModelK9()-and-HasK9Access() gate below rather than being a looser
--- client-side check). This is an INITIATION action (starts an open-stash
--- request against the local player's own ped), not a release/termination
--- one, so — unlike a termination path — it is gated, not exempted, per
--- this resource's established initiation-vs-termination gating split.
--- No nearest-candidate scan needed (unlike RequestTreatNearestK9()): the
--- target is always the local player's own, already-known ped.
function RequestOpenOwnK9Inventory()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if not Config.Features.K9Inventory then
        lib.notify({
            title = locale('common.notify_title'),
            description = K9_INVENTORY_REASON_MESSAGES.feature_disabled,
            type = 'error',
        })
        return
    end

    local netId = NetworkGetNetworkIdFromEntity(PlayerPedId())
    OpenK9InventoryForNetId(netId)
end
