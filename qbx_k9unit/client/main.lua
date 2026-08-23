--[[
    qbx_k9unit/client/main.lua

    Phase 1 scaffold only (coder-architect). Owns the ped-selection UI,
    the actual spawn/despawn of the K9 entity, and the single source of
    truth for "which K9 is this client currently controlling" — every
    other client file reads/writes that state through the accessor
    functions below, never a raw shared variable.

    ======================================================================
    EVENT/CALLBACK CONTRACT (full copy — identical in every stub file so
    coder-backend and coder-frontend can work in parallel without live
    coordination):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [server/certifications.lua]
    2. 'qbx_k9unit:server:requestSpawnK9' (pedKey: string) -> { ok: bool, reason?: string }
       [server/main.lua] Re-check hasK9Access logic AND that pedKey exists
       in Config.Peds. Server does NOT spawn anything — only authorizes
       THIS FILE to create+network the ped locally.

    Server events (RegisterNetEvent, client->server):
    3. 'qbx_k9unit:server:registerK9' (netId: number) [server/main.lua] —
       THIS FILE triggers it after locally creating+networking the ped.
    4. 'qbx_k9unit:server:unregisterK9' () [server/main.lua] — THIS FILE
       triggers it when voluntarily dismissing the current K9.
    5. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [server/certifications.lua]
    6. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [server/certifications.lua]
    7. 'qbx_k9unit:server:relayBark' (netId: number, barkType: string)
       [client/radial.lua triggers it; server/main.lua handles it]

    Client events (RegisterNetEvent, server->client):
    8. 'qbx_k9unit:client:despawnK9' (netId: number) [THIS FILE]
    9. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [THIS FILE]

    Commands (server-registered, call the same internal function as events 5/6):
    10. '/k9certify [targetServerId]' [server/certifications.lua]
    11. '/k9decertify [targetServerId]' [server/certifications.lua]

    Player disconnect: handled server-side in server/main.lua; THIS FILE
    only needs to react to the resulting 'qbx_k9unit:client:despawnK9'
    broadcast like any other despawn trigger.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes resource-global (no `local`) accessor functions
      for the single active-K9 state, used by client/movement.lua,
      client/radial.lua, and client/vehicle.lua:
        GetCurrentK9() -> { ped: entity, netId: number, pedKey: string, inVehicle: boolean }|nil
        SetCurrentK9(data: table)
        ClearCurrentK9()
      Do NOT introduce a second/parallel "which K9 is active" variable in
      any other file — always go through these three functions, or the
      "only one active K9 per handler" invariant (SPEC.md §6.1 bullet 3)
      becomes impossible to enforce consistently across files.
    - client/vehicle.lua sets/reads `inVehicle` on the table returned by
      GetCurrentK9() to know whether to render/freeze the ped.

    OPEN QUESTION flagged for coder-frontend (not decided here): SPEC.md's
    Phase 1 radial item list (§6.1, §8 step 8) is Leash/Unleash, Sit/Stay,
    Heel/Follow, Recall, Load/Release Vehicle, Bark — there is no explicit
    "dismiss/despawn K9" item. The only documented despawn triggers are (a)
    selecting a NEW ped from the roster (which despawns the old one first,
    §6.1 bullet 3) and (b) the forced server-driven despawn event. Decide
    whether Phase 1 needs an explicit "Dismiss K9" action of its own, or
    whether re-opening ped selection and picking any ped (even the same
    one) is an acceptable stand-in for now.
]]

--- Single source of truth for the locally controlled K9, or nil if none.
--- @type { ped: number, netId: number, pedKey: string, inVehicle: boolean }|nil
local currentK9 = nil

function GetCurrentK9()
    return currentK9
end

function SetCurrentK9(data)
    currentK9 = data
end

function ClearCurrentK9()
    currentK9 = nil
end

--- Opens the ox_lib context menu listing every Config.Peds entry, gated by
--- the server-authoritative access check.
--- TODO(coder-frontend): SPEC.md §6.1 bullet 1, §8 step 4.
--   1. local hasAccess = lib.callback.await('qbx_k9unit:server:hasK9Access', false)
--      — if false, lib.notify(...) and return.
--   2. Build an ox_lib `lib.registerContext` menu with one option per
--      Config.Peds entry (model + label), `onSelect` calling SpawnK9(model).
--      No hardcoded model name anywhere here — iterate Config.Peds
--      generically (SPEC.md §3 acceptance bullet 3).
--   3. lib.showContext with that menu's id.
--   OPEN QUESTION (not decided here, coder-frontend's call): what actually
--   triggers OpenK9PedSelection() in Phase 1 — a command, a keybind, an
--   ox_target option on self, an item? SPEC.md doesn't pin this down.
--   Pick one, register it in THIS FILE (or a dedicated place), and note
--   the choice here in a follow-up comment so it isn't re-litigated later.
local function OpenK9PedSelection()
end

--- Requests server authorization, then locally creates+networks the ped.
--- @param pedKey string  -- must be one of Config.Peds[i].model
--- TODO(coder-frontend): SPEC.md §6.1 bullets 2-3, §8 step 5.
--   1. local result = lib.callback.await('qbx_k9unit:server:requestSpawnK9', false, pedKey)
--      if not result.ok then lib.notify(...) return end
--   2. If GetCurrentK9() is already set, despawn/delete that ped LOCALLY
--      first (client-side mirror of the "one active K9" rule — the server
--      will also emit despawnK9 for the old netId once registerK9 fires,
--      but don't rely solely on that round-trip to avoid a visible frame
--      of two dogs existing).
--   3. RequestModel(pedKey) / IsModelInCdimage(pedKey) generically — no
--      hardcoded model name (SPEC.md §3 acceptance bullet 3) — wait for
--      HasModelLoaded before CreatePed.
--   4. CreatePed(...), SetEntityAsMissionEntity / NetworkRegisterEntityAsNetworked
--      as appropriate so it has a netId, then
--      NetworkGetNetworkIdFromEntity(ped) to get that netId.
--   5. SetCurrentK9({ ped = ped, netId = netId, pedKey = pedKey, inVehicle = false })
--   6. TriggerServerEvent('qbx_k9unit:server:registerK9', netId)
local function SpawnK9(pedKey)
end

--- Locally deletes the currently controlled K9 ped and clears state, then
--- tells the server. Use for a VOLUNTARY dismiss (not for reacting to the
--- server's despawnK9 broadcast — see the RegisterNetEvent below, which
--- must NOT call this, to avoid an unregisterK9 -> despawnK9 -> unregisterK9
--- event loop).
--- TODO(coder-frontend): delete/cleanup the ped entity, ClearCurrentK9(),
--- TriggerServerEvent('qbx_k9unit:server:unregisterK9').
local function DismissCurrentK9()
end

--- Server-forced despawn (e.g. stale netId being replaced per contract
--- item 3, or a disconnect-grace-period cleanup broadcast — see
--- server/main.lua's playerDropped TODO for whether this fires there too).
--- Do NOT TriggerServerEvent('qbx_k9unit:server:unregisterK9') from here —
--- the server already knows, that's WHY it sent this event.
RegisterNetEvent('qbx_k9unit:client:despawnK9', function(netId)
    -- TODO(coder-frontend): resolve the entity via
    -- NetworkGetEntityFromNetworkId(netId) — guard with
    -- NetworkDoesEntityExistWithNetworkId(netId) first, it may not exist
    -- for this client at all. Delete it if it does. If it matches
    -- GetCurrentK9()?.netId, ClearCurrentK9() too.
end)

--- Plays a bark on the K9 identified by netId, for any client that has it
--- streamed in (broadcast via TriggerClientEvent(..., -1, ...)).
--- @param netId number
--- @param barkType string
--- TODO(coder-frontend): NOTE the same barkType-enum gap flagged in
--- server/main.lua's relayBark TODO — SPEC.md/config.lua do not yet define
--- valid barkType values or their sound assets. Whatever enum/asset
--- mapping client/radial.lua uses to trigger a bark must be the SAME one
--- this handler uses to play it (they're two ends of one contract item,
--- 7+9) — keep them in the same place (e.g. a small local table at the
--- top of this file, or promote it to Config.BarkSounds in config.lua if
--- it should be server-owner-editable) rather than hardcoding matching
--- strings independently in two files.
RegisterNetEvent('qbx_k9unit:client:playBark', function(netId, barkType)
    -- TODO(coder-frontend): guard with NetworkDoesEntityExistWithNetworkId,
    -- resolve entity, PlaySoundFromEntity (or equivalent) using an asset
    -- keyed by barkType. SPEC.md §7 notes bark sounds need bundled audio
    -- asset files (not zero-asset) — coordinate with asset-pipeline-agent
    -- on where those files live if they don't exist yet.
end)
