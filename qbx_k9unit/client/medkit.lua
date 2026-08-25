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
]]

exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:treatK9',
        icon = 'fas fa-kit-medical',
        label = 'Treat K9',
        distance = Config.K9Medkit.range,
        canInteract = function(entity, distance, coords, name)
            if not Config.Features.K9Medkit then return false end
            return IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
            if not targetServerId then return end

            local result = lib.callback.await('qbx_k9unit:server:useK9Medkit', false, targetServerId)
            if not result then return end

            if result.ok then
                lib.notify({ title = 'K9 Unit', description = 'K9 treated.', type = 'success' })
            else
                -- Mirrors client/search.lua's own "unrecognized reason ->
                -- plain error notify" fallback discipline — no client-side
                -- change is required if server/medkit.lua ever adds a new
                -- reason value.
                local reasonLabel = ({
                    feature_disabled      = 'K9 medkit is not enabled.',
                    no_access             = 'You are not authorized to treat a K9.',
                    invalid_target        = 'That is not a valid K9 to treat.',
                    -- 'target_dead' — server/medkit.lua's own correctness
                    -- pass: a medkit heals an injured, ALIVE K9, never
                    -- revives a dead one (that's a real laststand/EMS
                    -- system's job, not a plain consumable's).
                    target_dead           = 'That K9 needs a real revive, not a medkit.',
                    too_far               = 'Get closer to the K9 first.',
                    on_cooldown           = 'This K9 was treated too recently.',
                    no_item               = 'You do not have a K9 medkit.',
                    treatment_in_progress = 'This K9 is already being treated.',
                    medkit_failed         = 'Unable to treat the K9 right now.',
                })[result.reason] or 'Unable to treat the K9 right now.'

                lib.notify({ title = 'K9 Unit', description = reasonLabel, type = 'error' })
            end
        end,
    },
})

--- Server-pushed heal application — see server/medkit.lua's header for why
--- this is client-self-applied rather than a direct server-side
--- SetEntityHealth call (PHASE4_SPEC.md §13.4.4 open question 1).
--- `newHealth` is an already-clamped ABSOLUTE health value computed
--- server-side — this handler never adds/interprets a delta of its own.
--- @param newHealth number
RegisterNetEvent('qbx_k9unit:client:applyMedkitHeal', function(newHealth)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- phase2_notes/client_event_trust_boundary.md for the full writeup;
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
    newHealth = math.max(0, math.min(newHealth, GetEntityMaxHealth(ped)))

    SetEntityHealth(ped, newHealth)
end)
