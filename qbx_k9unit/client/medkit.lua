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
    - Builds its own local `K9ModelHashes` set from the shared `Config.Peds`
      table, mirroring server/certifications.lua's own `K9ModelHashes`
      precomputation — deliberately NOT calling any server-global
      (`IsConfiguredK9Model` is server-only) since this is a client-side
      display filter only, not the real check (server/medkit.lua re-derives
      the target's real model server-side regardless).
    - Triggers `qbx_k9unit:server:useK9Medkit` (server/medkit.lua) and
      handles `qbx_k9unit:client:applyMedkitHeal` (server/medkit.lua) — see
      that file's header for the full event/callback contract.
]]

local K9ModelHashes = {}
for _, pedEntry in ipairs(Config.Peds) do
    K9ModelHashes[GetHashKey(pedEntry.model)] = true
end

--- Resolves a targeted ped entity to the server id of the player it
--- belongs to, or nil if it isn't (currently) a real player's own ped.
--- CLIENT-SIDE ONLY — NetworkGetPlayerIndexFromPed + GetPlayerServerId is
--- the standard, well-established client-side combo for this.
--- server/search.lua's own header flags this SAME native combo as
--- unverified SERVER-side only; that caveat does not apply to this
--- client-side use, and server/medkit.lua never calls this combo itself —
--- see its header for why.
--- @param entity number
--- @return number? targetServerId
local function ResolvePlayerServerIdFromPed(entity)
    local playerIndex = NetworkGetPlayerIndexFromPed(entity)
    if playerIndex == -1 then return nil end

    local targetServerId = GetPlayerServerId(playerIndex)
    if not targetServerId or targetServerId == 0 then return nil end

    return targetServerId
end

exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:treatK9',
        icon = 'fas fa-kit-medical',
        label = 'Treat K9',
        distance = Config.K9Medkit.range,
        canInteract = function(entity, distance, coords, name)
            if not Config.Features.K9Medkit then return false end
            return K9ModelHashes[GetEntityModel(entity)] == true
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
    if type(newHealth) ~= 'number' then return end
    SetEntityHealth(PlayerPedId(), newHealth)
end)
