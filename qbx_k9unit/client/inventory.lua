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
]]

--- Human-readable rejection messages for the openK9Inventory callback's
--- `reason` value. Mirrors server/main.lua's LEASH_REJECT_MESSAGES /
--- server/search.lua's reason-handling shape exactly.
-- NOTE: 'on_cooldown' and 'request_in_progress' are deliberately absent from
-- this table — both are routine, expected traffic (a double-click, a
-- hovering re-trigger), handled as a silent no-op below (never looked up
-- here at all), same treatment contraband_search_contract.md §4's
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
    local result = lib.callback.await('qbx_k9unit:server:openK9Inventory', false, netId)

    if not result or not result.ok then
        local reason = result and result.reason
        -- 'on_cooldown'/'request_in_progress' are routine, expected
        -- traffic (a double-click, a hovering re-trigger) — same
        -- silent-no-op treatment contraband_search_contract.md §4's
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

    exports.ox_inventory:openInventory('stash', result.stashId)
end

--- Register the "Open K9 Gear" ox_target option on nearby player peds whose
--- live model is (plausibly, client-side) a configured K9 model. Display
--- optimization only — server/inventory.lua's openK9Inventory callback
--- independently re-validates feature flag, target model/certification,
--- proximity, and interactor authorization for real; this predicate does
--- not need to be perfect (same posture client/movement.lua's own
--- attachLeash option documents for its analogous canInteract).
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
