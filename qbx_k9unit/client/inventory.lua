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

    KNOWN GAP, flagged rather than silently omitted: PHASE4_SPEC.md §13.4.2
    describes the ox_target option appearing "on the K9 player's own ped,"
    which server/inventory.lua's contract supports for BOTH a nearby
    department officer AND the K9 player accessing their own stash (see
    IsAuthorizedForK9Inventory's `isSelf` branch there). This file only
    wires the ox_target entry point below — a self-service "Open My Gear"
    RADIAL menu item (client/radial.lua) would be the natural UX for the K9
    player's own access (self-targeting via ox_target is awkward/unusual
    UX), but client/radial.lua is locked to another actively-refactoring
    session as of this pass and is explicitly out of scope here. The
    server-side capability already supports self-access today (a K9 player
    CAN use the ox_target option on their own ped if ox_target permits
    self-targeting on the live install; this was not verified this
    session) — adding the radial entry is a follow-up once that file's lock
    clears, not a redesign.

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
        end,
    },
})
