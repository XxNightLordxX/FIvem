--[[
    qbx_k9unit/client/medkit.lua

    Phase 4 implementation. Owns Config.Features.K9Medkit's client-side
    "Treat K9" ox_target world interaction (PHASE4_SPEC.md §13.4.4) — the
    UX-only half of this feature's trust boundary. ALL real validation
    (using-player eligibility, live proximity, target-model re-verification,
    item possession/consumption, per-target cooldown) happens server-side in
    server/medkit.lua's `qbx_k9unit:server:useK9Medkit` callback — nothing
    below is a security boundary, per this codebase's established "client
    hides the option, server is the real gate" split (SPEC.md §4.1's
    security note, already applied identically to every other gated action
    in this resource).

    Deliberately does NOT check the using player's own job or medkit
    possession client-side beyond hiding the option when the feature flag
    is off — a "Treat K9" prompt shown to a non-eligible or empty-handed
    player is a harmless false-positive UX affordance (the server rejects
    it with a real, distinct reason the ox_lib notify below surfaces), not
    a new trust surface.

    ======================================================================
    OX_TARGET API — CONFIRMED AGAINST THE REAL SOURCE THIS SESSION
    (github.com/overextended/ox_target @ main, fetched and read directly):
    `exports.ox_target:addGlobalPlayer(options)` shares the exact same
    option/callback shape as `addGlobalVehicle` (already used, confirmed
    working, in client/vehicle.lua's own "Load/Release K9" options) — both
    are thin wrappers around the same internal `addTarget(store, ...)`
    dispatcher. `canInteract(entity, distance, coords, name, bone)` receives
    the targeted ped's entity handle (matches client/vehicle.lua's existing
    `canInteract(entity, distance, coords, name)` usage exactly).
    `onSelect(data)` receives a table whose `.entity` field is the SAME
    targeted ped handle (confirmed by reading ox_target's own
    `getResponse()`/NUI 'select' callback in client/main.lua: `response.entity
    = currentTarget.entity`). `addGlobalPlayer` (rather than `addGlobalPed`)
    is used deliberately — the target of this feature is always a
    currently-connected K9 PLAYER, never an NPC, so scoping the option to
    ox_target's own player-detection is a strictly better semantic match
    than filtering an `addGlobalPed` option down to K9 models by hand
    (server/medkit.lua re-verifies both facts independently regardless —
    this is a UX-quality choice, not a security boundary).
    CONFIDENCE: HIGH — read directly from real ox_target source this
    session, not assumed from memory.

    FILE-TO-FILE CONTRACT:
    - Calls client/main.lua's `IsEntityModelK9(entity)` (REFACTOR_ROADMAP.md
      item 3) as its client-side display filter — deliberately NOT calling
      any server-global (`IsConfiguredK9Model` is server-only), since
      server/medkit.lua re-derives the target's real model server-side
      regardless. Used to build its own local `K9ModelHashes` set from
      `Config.Peds` (deleted this pass — see IsEntityModelK9's own doc
      comment in client/main.lua for the full "5 independent copies"
      finding this consolidation closes).
    - Calls client/main.lua's `ResolvePlayerServerIdFromPed(entity)`
      (REFACTOR_ROADMAP.md item 2b) in the "Treat K9" onSelect handler
      below — used to be a local copy of this file's own; extracted once
      client/wellbeing.lua's "Pet K9"/"Feed K9" handlers turned out to be
      hand-copying the identical function.
    - Triggers `qbx_k9unit:server:useK9Medkit` (server/medkit.lua) and
      handles `qbx_k9unit:client:applyMedkitHeal` (server/medkit.lua) — see
      that file's header for the full event/callback contract.
    - THIS FILE exposes one resource-global function for a radial entry
      point: `RequestTreatNearestK9()` — see its own doc comment near the
      bottom of this file for the full contract. Added because, until this
      pass, every bit of "treat a K9" logic lived entirely inside the
      ox_target `onSelect` closure below with nothing else in this
      resource able to reach it — a radial "Treat K9" item had no global to
      call. Mirrors client/movement.lua's RequestLeashAttach() shape: a
      thin, re-checked entry point that funnels into the SAME
      request/response implementation the ox_target option already uses
      (RequestTreatK9(targetServerId) below), never a second, divergent
      treat-request code path.
]]

--- Shared "ask the server to treat this specific K9" implementation —
--- called by both the ox_target `onSelect` below (targetServerId already
--- resolved from the interacted ped) and RequestTreatNearestK9() further
--- down (targetServerId resolved from a self-initiated nearest-K9 scan).
--- Kept as the ONE place that awaits the callback and interprets its
--- result, so a future reason value only needs updating here.
--- @param targetServerId number
local function RequestTreatK9(targetServerId)
    -- FAIL-CLOSED GUARD (dependency-verification finding, this pass):
    -- `lib.callback.await` throws rather than returning nil on a timeout
    -- or unregistered-callback rejection (see client/main.lua's
    -- HasK9Access() doc comment for the full ox_lib/FiveM source
    -- citation). pcall it; the very next line's `if not result then
    -- return end` already treats a nil result as a silent no-op, so a
    -- thrown failure now degrades to that exact same path instead of
    -- aborting this onSelect handler uncaught.
    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:useK9Medkit', false, targetServerId)
    if not ok then result = nil end
    if not result then return end

    -- DUPLICATE-TOAST FIX (this pass, coder-backend): a `result.ok` branch
    -- used to sit here and fire its own lib.notify(medkit.treated_success),
    -- on this SAME using player's client, for the SAME successful treat
    -- server/medkit.lua's RunUseK9MedkitMutation already notifies via
    -- NotifyPlayer(source, locale('medkit.treated_success'), 'success')
    -- (source there IS this client, the player who triggered this exact
    -- callback) -- traced both call sites this pass and confirmed they reach
    -- the identical player with the identical text for one successful
    -- treat. Removed here, kept server-side: the server is the authority on
    -- whether the treat actually succeeded (item consumption, cooldown,
    -- mutex, health clamp all resolve server-side), while this client-side
    -- branch only ever reflected an already-final `result.ok` it received
    -- FROM that same server call -- so it had nothing of its own to add, and
    -- dropping it cannot suppress any outcome the player wasn't already told
    -- about by the server. Inverted to `if not result.ok then ... end`
    -- (rather than an `if result.ok then <nothing> else ... end` shape) so
    -- there is no empty branch left behind for luacheck to flag. Every
    -- rejection reason below is UNCHANGED: server/medkit.lua notifies on NO
    -- rejection path (confirmed by reading HandleUseK9Medkit/
    -- RunUseK9MedkitMutation/the lib.callback.register wrapper in full), so
    -- this remains the ONLY feedback a player gets for every one of those
    -- reasons.
    if not result.ok then
        -- Mirrors client/search.lua's own "unrecognized reason ->
        -- plain error notify" fallback discipline — no client-side
        -- change is required if server/medkit.lua ever adds a new
        -- reason value. 'medkit_failed' and the unrecognized-reason
        -- fallback share the identical English sentence (confirmed before
        -- minting) and both point at medkit.reason_medkit_failed rather
        -- than duplicating it under a second key. `too_far` reuses
        -- common.too_far_from_k9 -- byte-for-byte identical to
        -- client/wellbeing.lua's own too_far rejection text (confirmed by
        -- grep before minting), promoted to common.* rather than kept as
        -- two drifting per-file copies.
        local reasonLabel = ({
            feature_disabled      = locale('medkit.reason_feature_disabled'),
            no_access             = locale('medkit.reason_no_access'),
            invalid_target        = locale('medkit.reason_invalid_target'),
            -- 'target_dead' — server/medkit.lua's own correctness
            -- pass: a medkit heals an injured, ALIVE K9, never
            -- revives a dead one (that's a real laststand/EMS
            -- system's job, not a plain consumable's).
            target_dead           = locale('medkit.reason_target_dead'),
            too_far               = locale('common.too_far_from_k9'),
            on_cooldown           = locale('medkit.reason_on_cooldown'),
            no_item               = locale('medkit.reason_no_item'),
            treatment_in_progress = locale('medkit.reason_treatment_in_progress'),
            medkit_failed         = locale('medkit.reason_medkit_failed'),
        })[result.reason] or locale('medkit.reason_medkit_failed')

        lib.notify({ title = locale('common.notify_title'), description = reasonLabel, type = 'error' })
    end
end

-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call -- canInteract/onSelect below are
-- unchanged (still authored against ox_target's own convention), so an
-- operator running a different supported target script gets this option
-- translated automatically instead of losing it outright.
--
-- LIFECYCLE FIX (this pass): extracted into a named function, sole call
-- site the AddEventHandler('onResourceStart', ...) below, so this option
-- comes back after a bare restart of whatever resource actually backs the
-- 'target' system, not just after this resource's own restart -- every
-- supported target script keeps its own registry in a plain file-local Lua
-- table inside its own client chunk, reloaded empty on THAT resource's own
-- restart with nothing else prompting a re-add. Mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. DUPLICATE-VS-REPLACE: the
-- option below always sets `name`, and every adapter's own registration
-- primitive dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running this
-- never duplicates the entry.
local function RegisterMedkitOxTargetOption()
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'qbx_k9unit:treatK9',
            icon = 'fas fa-kit-medical',
            label = locale('medkit.treat_target_label'),
            distance = Config.K9Medkit.range,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.K9Medkit then return false end
                -- WIDENED (K9 role/model decoupling) with
                -- IsK9RoleForPlayer(...) -- client/appearance.lua's own
                -- per-target-cached (1s TTL) server round trip for "does
                -- THAT player hold the K9 role" -- so a target on a
                -- human/custom model who already holds the role can still
                -- be treated. Short-circuited last: only reached on a
                -- cache miss for the (rare) case IsEntityModelK9 didn't
                -- already answer this.
                return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
            end,
            onSelect = function(data)
                local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                if not targetServerId then return end

                RequestTreatK9(targetServerId)
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterMedkitOxTargetOption()
        return
    end

    -- This file never names a third-party target resource directly (see
    -- shared/compat/target.lua) -- whichever one actually backs the
    -- 'target' system is asked of K9Compat itself. Redetect() is forced
    -- here rather than relying on shared/compat/core.lua's own
    -- onResourceStart/onClientResourceStart redetect hook having already
    -- run for this SAME event, so this check is correct regardless of
    -- relative handler-registration order between the two files.
    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterMedkitOxTargetOption()
    end
end)

--- Same nearest-candidate scan shape as client/radial.lua's own
--- FindNearestLeashCandidate()/FindNearestPartnerCandidate() — duplicated
--- here rather than shared (this file has no import mechanism to reach
--- those, and per this task's file-ownership split client/radial.lua is
--- out of scope here) — for RequestTreatNearestK9()'s self-initiated
--- (radial) entry point below. Filters to a live K9 model OR the decoupled
--- K9 role (K9 role/model decoupling -- IsK9RoleForPlayer(...), same
--- widening and same reasoning as this file's own ox_target `canInteract`
--- above), unlike FindNearestLeashCandidate (which filters to none).
--- Display-only: server/medkit.lua's HandleUseK9Medkit independently
--- re-verifies the target's real model/role, aliveness, proximity, and
--- certification regardless of what this scan picks.
--- @return number? candidateServerId
local function FindNearestTreatableK9()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPlayer, nearestDist

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= PlayerId() then
            local targetPed = GetPlayerPed(playerId)
            if targetPed ~= 0 and DoesEntityExist(targetPed)
                and (IsEntityModelK9(targetPed) or IsK9RoleForPlayer(GetPlayerServerId(playerId))) then
                local dist = #(myCoords - GetEntityCoords(targetPed))
                if dist <= Config.K9Medkit.range and (not nearestDist or dist < nearestDist) then
                    nearestPlayer, nearestDist = playerId, dist
                end
            end
        end
    end

    if not nearestPlayer then return nil end
    return GetPlayerServerId(nearestPlayer)
end

--- Resource-global — radial self-service entry point (see FILE-TO-FILE
--- CONTRACT above). Mirrors client/movement.lua's RequestLeashAttach()
--- shape: re-checks CanShowK9UI() itself rather than trusting that a
--- caller (a future client/radial.lua item) already did, per this
--- codebase's "must not be triggerable by a modified client" spirit — the
--- server re-validates independently regardless (server/medkit.lua's
--- HandleUseK9Medkit). This is an INITIATION action (starts a treat
--- request against a found target), not a release/termination one, so —
--- unlike a termination path — it is gated, not exempted, per this
--- resource's established initiation-vs-termination gating split (see
--- client/movement.lua's DetachLeash()/client/recall.lua's RequestRecall()
--- for the termination side of that split).
--- Feature-flag/no-candidate cases are each notified distinctly so a
--- player understands why nothing happened, then funnels into the SAME
--- RequestTreatK9() implementation the ox_target option above uses.
function RequestTreatNearestK9()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if not Config.Features.K9Medkit then
        -- Byte-for-byte identical to the reasonLabel table's own
        -- feature_disabled entry above (confirmed by grep before minting) --
        -- reused rather than duplicated under a second key.
        lib.notify({ title = locale('common.notify_title'), description = locale('medkit.reason_feature_disabled'), type = 'error' })
        return
    end

    local targetServerId = FindNearestTreatableK9()
    if not targetServerId then
        lib.notify({ title = locale('common.notify_title'), description = locale('medkit.no_nearby_k9'), type = 'error' })
        return
    end

    RequestTreatK9(targetServerId)
end

--- Server-pushed heal application — see server/medkit.lua's header for why
--- this is client-self-applied rather than a direct server-side
--- SetEntityHealth call (PHASE4_SPEC.md §13.4.4 open question 1).
--- `newHealth` is an already-clamped ABSOLUTE health value computed
--- server-side — this handler never adds/interprets a delta of its own.
--- @param newHealth number
RegisterNetEvent('qbx_k9unit:client:applyMedkitHeal', function(newHealth)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- phase2_notes/RESEARCH_ARCHIVE.md#trust-boundary for the full writeup;
    -- not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:applyMedkitHeal', <anything>)`
    -- would reach the exact same SetEntityHealth call a genuine server
    -- push does, with zero server contact. Confidence: MEDIUM-HIGH, the
    -- official documented pattern for distinguishing a genuine
    -- server-sent event from a local self-trigger, not independently
    -- verified in-engine this pass.
    if source ~= 65535 then return end

    -- FEATURE GATE -- this handler was previously registered
    -- unconditionally regardless of Config.Features.K9Medkit (the only
    -- prior reference to that flag in this file was inside the ox_target
    -- `canInteract` predicate above, which only hides the REQUEST side --
    -- it never reached this receiver). Without this, a forged event
    -- reached a live, uncapped, cooldown-free SetEntityHealth self-heal
    -- even with K9Medkit = false. Matches client/hud.lua / client/vision.lua
    -- / client/combat.lua's "gate at registration" precedent.
    if not Config.Features.K9Medkit then return end

    if type(newHealth) ~= 'number' then return end

    local ped = PlayerPedId()

    -- DEAD-K9 GUARD (coder-backend, correctness pass) -- server/medkit.lua
    -- already rejects a request targeting an already-dead K9 up front
    -- (HandleUseK9Medkit's own IsEntityDead check, reason 'target_dead'),
    -- but that check runs at REQUEST time, not at the moment this event is
    -- actually applied here. In the network-latency gap between the
    -- server computing `newHealth` (while this K9 was still alive) and
    -- this handler running, this K9 could have died from unrelated damage
    -- -- without this guard, a heal computed for a live K9 would still
    -- land as a de-facto revive via SetEntityHealth a moment after death,
    -- exactly the outcome server/medkit.lua's own header explains this
    -- item is deliberately NOT meant to cause (a medkit heals an injured,
    -- ALIVE K9; reviving a dead one is a real laststand/EMS system's job).
    -- Never treated as an error -- a stale heal for a K9 that died in
    -- transit is simply dropped, same as any other now-irrelevant queued
    -- effect.
    if IsEntityDead(ped) then return end

    -- RANGE CHECK (coder-security, this pass) -- `newHealth` was
    -- previously type-checked only, never range-checked. server/medkit.lua
    -- always computes it inside [currentHealth, GetEntityMaxHealth(ped)]
    -- (see that file's RunUseK9MedkitMutation), so this clamp is a
    -- true no-op for a genuine server push -- but is the ONLY thing that
    -- would have stopped a forged event carrying an arbitrary numeric
    -- newHealth (e.g. 99999) from being applied verbatim as a free,
    -- uncapped self-heal, independently of whether the origin guard above
    -- holds. Complementary, not redundant, with that guard.
    --
    -- MAX-HEALTH AGREEMENT -- server/medkit.lua's header, CORRECTNESS PASS
    -- finding 1: nothing in this resource ever modifies a K9 ped's real
    -- max health (confirmed by reading server/wellbeing.lua's Injury stat
    -- directly -- it's an entirely separate virtual per-citizenid float,
    -- never written back to the ped's native health fields), so this live
    -- GetEntityMaxHealth(ped) read and the server's own live
    -- GetEntityMaxHealth(targetPed) read at compute time are two reads of
    -- the same never-modified value and cannot disagree from anything this
    -- resource does. This clamp still re-reads it live (rather than
    -- trusting the server's number outright) so that if a THIRD-PARTY
    -- resource or a ped respawn ever DOES change the live ceiling in the
    -- gap between those two reads, the result can only be a safe
    -- under-heal capped to the lower of the two ceilings, never an
    -- overheal above whatever is actually live right now.
    --
    -- MONOTONIC-HEAL FLOOR (this pass, correctness fix): the lower bound
    -- here was previously a flat `0`, not this ped's own CURRENT live
    -- health. server/medkit.lua's RunUseK9MedkitMutation guarantees
    -- newHealth >= currentHealth only as measured AT COMPUTE TIME -- the
    -- exact same network-latency gap the DEAD-K9 GUARD above already
    -- accounts for also means a second, older/reordered/retried
    -- applyMedkitHeal for this same K9 could still arrive and be processed
    -- AFTER a newer one already raised this ped's live health past it. A
    -- "heal" handler applying a lower absolute value than the ped's CURRENT
    -- health would visibly reduce it -- the exact "heal event that hurts"
    -- outcome this file's own header explicitly says a medkit must never
    -- cause. Reading currentHealth live, right here, and using it (not 0)
    -- as the floor makes this call structurally a no-op-or-increase only,
    -- regardless of event ordering.
    local currentHealth = GetEntityHealth(ped)
    newHealth = math.max(currentHealth, math.min(newHealth, GetEntityMaxHealth(ped)))

    SetEntityHealth(ped, newHealth)
end)
