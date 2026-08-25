--[[
    qbx_k9unit/client/kennel.lua

    Phase 5 R&D scaffold (coder-architect structural pass). Owns the
    DeployableKennel feature's client-side placement mechanics and the
    "Pick Up Kennel" ox_target entry point. See server/kennel.lua's header
    for the full event contract and the "server computes the placement
    coords" design rationale — this file only ever executes an instruction
    the server already validated, it never decides WHERE a kennel goes.

    NEW FILE (paired with server/kennel.lua), not folded into
    client/vehicle.lua or client/main.lua — same "one responsibility per
    file" convention as every other file pairing in this resource (see
    server/kennel.lua's header for the fuller version of this reasoning).

    ======================================================================
    EVENT/CALLBACK CONTRACT (client side; see server/kennel.lua for the
    full server-side version):
    Server events this file triggers (client->server):
      'qbx_k9unit:server:requestDeployKennel' ()
      'qbx_k9unit:server:confirmKennelPlaced' (netId: number)
      'qbx_k9unit:server:cancelKennelPlacement' ()
      'qbx_k9unit:server:requestPickupKennel' (netId: number)
    Client events this file registers (server->client):
      'qbx_k9unit:client:deployKennelAt' (x: number, y: number, z: number)
      'qbx_k9unit:client:removeKennel' (netId: number)
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        RequestDeployKennel()
            Runs the command's own gating (feature flag, CanShowK9UI(),
            "already have one deployed" local check) and sends the deploy
            request. Exposed globally, not kept as a command-local closure,
            so a future radial item can call it directly once
            client/radial.lua is available to extend again (that file is
            out of scope for this pass — see the live task notes this
            change was made under) without this file needing to change at
            all, mirroring how client/vehicle.lua's
            EnterNearestK9Vehicle()/ExitK9Vehicle() are consumed by
            client/radial.lua today.
    - THIS FILE calls client/main.lua's CanShowK9UI() and DenyK9UIAccess()
      before acting, same as every other gated client action in this
      resource.
    - THIS FILE calls client/main.lua's ResolveNetworkEntity(netId)
      (DEVELOPER_REFERENCE.md item 2) in the removeKennel handler and the
      onResourceStop cleanup below — do not re-implement the
      NetworkDoesEntityExistWithNetworkId/NetworkGetEntityFromNetworkId/
      DoesEntityExist sequence here; both were 2 of the 11 copies the
      Revision 5 whole-codebase audit found still bypassing this helper.
    - THIS FILE does NOT touch client/vehicle.lua's or
      client/movement.lua's state — kennels are a wholly independent
      mechanic.
]]

-- Milliseconds to wait for RequestModel to actually finish loading before
-- giving up. RequestModel/HasModelLoaded is the standard vanilla polling
-- pattern (no ox_lib model-loading helper is used elsewhere in this
-- resource to reuse instead) — 5s is a generous ceiling for a single small
-- prop model on typical connections, matching the general "fail loudly
-- rather than hang forever" convention already applied elsewhere in this
-- resource (e.g. LEASH_REQUEST_TTL_MS, PendingKennelPlacements' own TTL in
-- server/kennel.lua).
local REQUEST_MODEL_TIMEOUT_MS = 5000

-- Recognized kennel prop model hashes (primary + fallback, config.lua's
-- Config.DeployableKennel) -- built once at file load, used ONLY by the
-- removeKennel handler's defense-in-depth model check below (see that
-- handler's own comment for why). Not the same table client/main.lua's
-- K9ModelHashes covers (that one is PED models; this is the kennel OBJECT
-- prop), so it is not a duplicate of an existing global.
local KennelPropModelHashes = {
    [GetHashKey(Config.DeployableKennel.propModel)] = true,
    [GetHashKey(Config.DeployableKennel.fallbackPropModel)] = true,
}

-- Currently-active kennel THIS client deployed, if any (nil otherwise).
-- Local-only, never read from another file. This is a CLIENT-SIDE MIRROR
-- of server/kennel.lua's authoritative Kennels[citizenid] entry, not an
-- independent source of truth — it exists only so (a) this file's own
-- onResourceStop handler below knows what to clean up, and (b)
-- RequestDeployKennel() can give an immediate "you already have one"
-- notice for the common case without a network round trip. The server
-- independently re-validates the one-kennel-per-citizenid limit regardless
-- of what this local variable currently believes (see
-- server/kennel.lua's requestDeployKennel handler).
local myKennelNetId = nil

--- Requests `modelName`'s hash and blocks (via Wait, same convention as
--- every other polling loop in this resource) until it loads or
--- REQUEST_MODEL_TIMEOUT_MS elapses.
--- @param modelName string
--- @return number? modelHash — nil if the model hash is invalid, or never finished loading in time
local function LoadModelWithTimeout(modelName)
    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then
        return nil -- not even a recognized model hash on this client's installed game data — don't bother requesting it
    end

    RequestModel(modelHash)
    local waited = 0
    while not HasModelLoaded(modelHash) and waited < REQUEST_MODEL_TIMEOUT_MS do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        -- LEAK FIX, THIS PASS: RequestModel above increments this model's
        -- streaming reference count; failing to load in time is a real
        -- exit path (not just the "invalid hash" early-return above, which
        -- never called RequestModel at all) and previously left that
        -- reference held forever -- nothing else in this file's only
        -- caller ever released a model that DIDN'T end up used to
        -- CreateObject (the caller only calls SetModelAsNoLongerNeeded on
        -- the modelHash it actually built the kennel with, e.g. the
        -- fallback's hash when the primary timed out -- the primary's own
        -- still-pending request was never released). Every RequestModel in
        -- this resource must have a matching SetModelAsNoLongerNeeded on
        -- every exit path, including this failure one; release it here,
        -- at the one place that knows this exact request is being
        -- abandoned, rather than relying on a caller that has no reason to
        -- know this particular RequestModel ever happened.
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end
    return modelHash
end

--- Runs RequestDeployKennel()'s own client-side gating and, if it passes,
--- asks the server to compute a spawn point. See FILE-TO-FILE CONTRACT
--- above for why this is exposed globally rather than kept command-local.
function RequestDeployKennel()
    if not Config.Features.DeployableKennel then return end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if myKennelNetId then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.already_deployed'), type = 'error' })
        return
    end

    -- This is a UX convenience only (avoids an obviously-pointless round
    -- trip) — server/kennel.lua's requestDeployKennel handler independently
    -- re-checks the real, authoritative one-kennel-per-citizenid limit
    -- regardless of what this local variable currently believes.
    TriggerServerEvent('qbx_k9unit:server:requestDeployKennel')
end

RegisterCommand('k9deploykennel', function()
    RequestDeployKennel()
end, false)

--- Server-issued instruction (never a request to validate — see
--- server/kennel.lua's header "WHY THE SERVER COMPUTES THE PLACEMENT
--- COORDS" block): create the kennel object at exactly (x, y, z), ground
--- it, freeze it, and report the resulting network id back.
--- @param x number
--- @param y number
--- @param z number
RegisterNetEvent('qbx_k9unit:client:deployKennelAt', function(x, y, z)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- DEVELOPER_REFERENCE.md#trust-boundary for the full writeup;
    -- not re-derived here). 65535 is FiveM's documented client-side
    -- sentinel for "this event genuinely came from the server"
    -- (citizenfx/fivem-docs, "Secure your events"). Without this, a
    -- forged local `TriggerEvent('qbx_k9unit:client:deployKennelAt', x, y,
    -- z)` would spawn a real networked object at attacker-chosen
    -- coordinates with zero server contact. Confidence: MEDIUM-HIGH, the
    -- official documented pattern, not independently verified in-engine
    -- this pass.
    if source ~= 65535 then return end

    -- FEATURE GATE -- this handler was previously registered
    -- unconditionally regardless of Config.Features.DeployableKennel,
    -- breaking this resource's "flag off means genuinely inert" invariant
    -- (client/hud.lua / client/vision.lua / client/combat.lua precedent).
    -- Matches server/kennel.lua's own per-handler gating convention.
    if not Config.Features.DeployableKennel then return end

    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    local modelHash = LoadModelWithTimeout(Config.DeployableKennel.propModel)
    local usedFallback = false
    if not modelHash then
        usedFallback = true
        modelHash = LoadModelWithTimeout(Config.DeployableKennel.fallbackPropModel)
    end

    if not modelHash then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.prop_load_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelKennelPlacement')
        return
    end

    if usedFallback then
        -- Low-key server-console breadcrumb, not a player-facing error —
        -- the fallback existing and working IS the intended, documented
        -- behavior (config.lua's Config.DeployableKennel comment), but a
        -- server owner should still be able to notice this is happening
        -- and go confirm/replace the primary propModel.
        print(('[qbx_k9unit] DeployableKennel: propModel "%s" failed to load, used fallbackPropModel "%s" instead — see config.lua\'s Config.DeployableKennel comment (single-source, unconfirmed prop name).'):format(Config.DeployableKennel.propModel, Config.DeployableKennel.fallbackPropModel))
    end

    local obj = CreateObject(modelHash, x, y, z, true, true, false)
    SetModelAsNoLongerNeeded(modelHash)

    if not DoesEntityExist(obj) then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.placement_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelKennelPlacement')
        return
    end

    local placedOk = PlaceObjectOnGroundProperly(obj)
    if not placedOk then
        -- Not necessarily fatal on its own (bad terrain under the
        -- handler), but per this resource's own "fail loudly rather than
        -- silently ship a broken result" convention, don't confirm a
        -- kennel the game itself couldn't ground properly.
        DeleteEntity(obj)
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.no_suitable_ground'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelKennelPlacement')
        return
    end

    FreezeEntityPosition(obj, true)

    local netId = NetworkGetNetworkIdFromEntity(obj)
    myKennelNetId = netId
    TriggerServerEvent('qbx_k9unit:server:confirmKennelPlaced', netId)
end)

--- Cleanup backstop broadcast from server/kennel.lua — see that file's
--- RemoveKennelForCitizenid CLEANUP CONFIDENCE NOTE for why this exists
--- alongside the server's own direct DeleteEntity attempt. Safe no-op for
--- any client that doesn't have this netId streamed in.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:removeKennel', function(netId)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- DEVELOPER_REFERENCE.md#trust-boundary for the full writeup;
    -- not re-derived here). THIS is the highest-severity handler in this
    -- file to guard: without this check, and before the feature gate and
    -- model check below existed, a forged local
    -- `TriggerEvent('qbx_k9unit:client:removeKennel', <any streamed netId>)`
    -- was an arbitrary-entity-DeleteEntity primitive -- not scoped to
    -- kennels at all, since the only prior validation was `type(netId) ==
    -- 'number'`. Confidence: MEDIUM-HIGH, the official documented pattern
    -- for distinguishing a genuine server-sent event from a local
    -- self-trigger, not independently verified in-engine this pass.
    if source ~= 65535 then return end

    -- FEATURE GATE -- this handler was previously registered
    -- unconditionally regardless of Config.Features.DeployableKennel. See
    -- deployKennelAt's own comment above for the same reasoning.
    if not Config.Features.DeployableKennel then return end

    if type(netId) ~= 'number' then return end

    if myKennelNetId == netId then
        myKennelNetId = nil
    end

    -- DEVELOPER_REFERENCE.md item 2 (Revision 5 migration): was this handler's
    -- own inline NetworkDoesEntityExistWithNetworkId -> NetworkGetEntityFromNetworkId
    -- -> DoesEntityExist sequence.
    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    -- DEFENSE-IN-DEPTH MODEL CHECK (coder-security, this pass): even with
    -- the origin guard and feature gate above, this is a DeleteEntity call
    -- driven entirely by a caller-supplied netId -- server/kennel.lua's own
    -- dispatch site only ever sends a real kennel's netId, but nothing
    -- upstream of this line re-derives that fact. Restricting the delete to
    -- an entity whose CURRENT model actually matches a configured kennel
    -- prop turns "arbitrary entity deletion" (any streamed vehicle/ped/
    -- object) into, at worst, "delete some other player's legitimately
    -- placed kennel prop" -- narrower, and free (a live model read, no
    -- extra round trip) -- should the origin guard above ever be defeated
    -- by something this pass could not evaluate (see its own confidence
    -- note).
    if not KennelPropModelHashes[GetEntityModel(entity)] then return end

    DeleteEntity(entity)
end)

-- Resource-restart safety net (same class of fix as client/vehicle.lua's
-- own onResourceStop handler, flagged there as a "ship-blocking QA
-- finding" for a different piece of entity state): if THIS client created
-- a kennel and the resource stops while it's still connected, delete it
-- locally rather than leaving a frozen, ownerless object behind that
-- nothing will ever clean up once this resource's own scripts (client and
-- server) are gone. Covers the common "still connected at resource
-- restart" case; server/kennel.lua's own onResourceStop loop covers
-- kennels whose creating client already disconnected earlier in the
-- session (see that file's header for why the two are complementary, not
-- redundant).
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not myKennelNetId then return end

    -- DEVELOPER_REFERENCE.md item 2 (Revision 5 migration): same inline
    -- sequence as the removeKennel handler above, now the shared resolver.
    local entity = ResolveNetworkEntity(myKennelNetId)
    if entity then
        DeleteEntity(entity)
    end
    myKennelNetId = nil
end)

-- "Pick Up Kennel" ox_target entry point — targets EITHER configured
-- kennel model (primary or fallback, see config.lua's comment on why both
-- are legitimate) directly by model hash via ox_target's addModel, rather
-- than a global-ped/vehicle option the way client/vehicle.lua targets a
-- vehicle model list, since a kennel is a plain OBJECT with no other
-- distinguishing registry client-side to filter on.
--
-- VISIBILITY VS. AUTHORIZATION: canInteract below only gates on
-- CanShowK9UI() — it does NOT (and structurally cannot, without either a
-- server round-trip per hover-tick or a client-side ownership mirror this
-- resource has no equivalent of elsewhere) verify the interacting player
-- actually OWNS this specific kennel. That's fine per this resource's
-- established standard (server/certifications.lua's own header: "client-
-- side ox_target option visibility... [is a] UX convenience only, not
-- access control") — server/kennel.lua's requestPickupKennel handler
-- independently re-verifies real ownership against its Kennels registry
-- and rejects (with a notification, not silently) anyone who isn't the
-- actual owner.
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call -- canInteract/onSelect below are
-- unchanged (still authored against ox_target's own convention), so an
-- operator running a different supported target script gets this option
-- translated automatically instead of losing it outright.
--
-- LIFECYCLE FIX (this pass): extracted into a named function so this option
-- can be re-registered any time the resource actually backing the 'target'
-- system (re)starts, not just once at this file's own load time — every
-- supported target script keeps its own registry in a plain file-local Lua
-- table inside its own client chunk, reloaded empty on THAT resource's own
-- restart with nothing else prompting a re-add. Mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. The Config.Features.
-- DeployableKennel gate stays AT REGISTRATION (inside this function, not
-- just inside canInteract) exactly as before, so a re-registration on the
-- target resource's restart never adds an option this file's original
-- load-time code would have skipped. DUPLICATE-VS-REPLACE: the option
-- below always sets `name`, and every adapter's own registration primitive
-- dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running this
-- never duplicates the entry.
local function RegisterKennelOxTargetOption()
    if Config.Features.DeployableKennel then
        K9Compat.Get('target').AddModel({
            GetHashKey(Config.DeployableKennel.propModel),
            GetHashKey(Config.DeployableKennel.fallbackPropModel),
        }, {
            {
                name = 'qbx_k9unit:pickupKennel',
                icon = 'fas fa-dog',
                label = locale('kennel.pickup_target_label'),
                distance = Config.DeployableKennel.interactDistanceMeters,
                canInteract = function(entity, distance, coords, name)
                    if not Config.Features.DeployableKennel then return false end
                    return CanShowK9UI()
                end,
                onSelect = function(data)
                    if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                    local netId = NetworkGetNetworkIdFromEntity(data.entity)
                    TriggerServerEvent('qbx_k9unit:server:requestPickupKennel', netId)
                end,
            },
        })
    end
end

-- Sole call site for RegisterKennelOxTargetOption(): this resource's own
-- start, or ox_target's own start — mirrors server/tracking.lua's
-- RegisterScentInventoryHook / server/inventory.lua's
-- RegisterK9InventoryItemFilterHook fixes for the identical class of gap
-- against ox_inventory.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterKennelOxTargetOption()
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
        RegisterKennelOxTargetOption()
    end
end)
