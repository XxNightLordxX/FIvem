--[[
    qbx_k9unit/server/kennel.lua

    Phase 5 R&D scaffold (coder-architect structural pass).
    Config.Features.DeployableKennel (phase2_notes/phase5_features_research.md
    §5): "a certified handler can place a world object (the kennel prop)
    near themselves... server-authoritative validation (proximity,
    certification, one-per-handler limit), with cleanup on resource stop/
    handler disconnect."

    NEW FILE PAIR (this file + client/kennel.lua), not folded into
    server/main.lua or server/certifications.lua — same "one responsibility
    per file, don't let it balloon into an everything-file" convention
    those two files' own headers already establish. PHASE4_SPEC.md's own
    file-layout table reaches the identical conclusion for the structurally
    similar K9Inventory feature ("a real ... capability grant deserves the
    certification-file's level of scrutiny... new pair, not folded into an
    existing file") — a kennel is the same category of thing: a brand new,
    persistent, visible, network-synced world entity, not a small
    incremental gated action.

    ======================================================================
    WHY THE SERVER COMPUTES THE PLACEMENT COORDS, NOT THE CLIENT: every
    other gated action in this resource that names a specific world
    position either (a) re-derives it from the caller's OWN live
    server-side ped coords (relayBark's netId, CheckLeashEligibility's
    proximity check), or (b) independently re-validates a client-claimed
    entity before trusting it (relayDoorScratch's doorNetId distance+type
    check, per that handler's own "never trust a client-supplied id"
    comment). A kennel placement has no OTHER pre-existing entity to name —
    it's a brand-new object at a position — so there's no analogous "claim"
    to validate the way relayDoorScratch has one. Rather than accepting a
    client-claimed spawn position and validating it after the fact
    (workable, but an unforced trust boundary this resource's own
    convention avoids everywhere else), RequestDeployKennel below computes
    the spawn point itself from the requester's live, server-side ped
    position + forward vector, and hands that back to the client as an
    INSTRUCTION (event 5), not something to validate. The client cannot
    place a kennel anywhere the server didn't already choose.
    ======================================================================

    EVENT/CALLBACK CONTRACT:
    Server events (RegisterNetEvent, client->server):
    1. 'qbx_k9unit:server:requestDeployKennel' () [THIS FILE]
       Certified handler asks to place a kennel near themselves. Validates
       the feature flag, HasK9Access, a per-source deploy cooldown, and the
       one-active-kennel-per-citizenid limit (see the header note at the
       bottom of this file) — then computes spawn coords server-side and
       instructs the SAME client to actually create the object (event 5).
       CreateObject/PlaceObjectOnGroundProperly/FreezeEntityPosition are
       native-only, client-side operations per
       phase2_notes/phase5_features_research.md §5's confirmed natives —
       this file never attempts to create the object itself.
    2. 'qbx_k9unit:server:confirmKennelPlaced' (netId: number) [THIS FILE]
       Client reports the network id of the object it actually created, in
       response to event 5. Re-validates everything event 1 already
       checked (a certification revoke or feature-flag toggle could have
       landed mid-flight), PLUS confirms the reported entity actually
       exists, is one of the two configured kennel prop models, is
       actually an OBJECT (not some other entity type), and sits within a
       small tolerance of the coords THIS file itself chose — defense in
       depth mirroring relayDoorScratch's "never trust a client-supplied
       id" standard (server/main.lua). Here the id names an entity the
       client was JUST instructed to create, but a modified client could
       still report an arbitrary pre-existing networked entity's id
       instead of a genuine new kennel.
    3. 'qbx_k9unit:server:cancelKennelPlacement' () [THIS FILE]
       Client reports its own placement attempt failed (model never
       loaded, PlaceObjectOnGroundProperly returned false) so the pending
       slot frees up immediately instead of sitting until its TTL expires.
    4. 'qbx_k9unit:server:requestPickupKennel' (netId: number) [THIS FILE]
       Owning handler removes their own kennel early, freeing their
       one-slot limit without waiting to disconnect — same "never leave a
       player stuck" principle client/vehicle.lua's header cites for its
       own exit path.

    Client events (RegisterNetEvent, server->client):
    5. 'qbx_k9unit:client:deployKennelAt' (x: number, y: number, z: number)
       [client/kennel.lua] — an instruction, not a request; see the "WHY
       THE SERVER COMPUTES" block above. Sent as three plain numbers
       rather than a vector3 — this resource has no existing precedent for
       putting a vector3 value on the wire, and three numbers is
       unambiguous either way.
    6. 'qbx_k9unit:client:removeKennel' (netId: number) [client/kennel.lua]
       Broadcast (-1) cleanup backstop — see the CONFIDENCE NOTE on
       RemoveKennelForCitizenid below.

    Commands: '/k9deploykennel' lives in client/kennel.lua, not here — this
    is a self-administered action (the handler acts on themselves), which
    in this resource is always triggered from a client-side entry point
    calling a client-side global (see client/vehicle.lua's
    EnterNearestK9Vehicle/ExitK9Vehicle), unlike certify/revoke (which act
    ON another player and so live alongside their own server-side handlers
    in server/certifications.lua).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, exposed by
      server/certifications.lua — do not re-derive the job/cert check here.
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)`,
      exposed by server/entities.lua (REFACTOR_ROADMAP.md item 2) — do not
      re-implement the resolve/existence-guard sequence here.
      RemoveKennelForCitizenid, confirmKennelPlaced, and the onResourceStop
      sweep all previously hand-rolled their own
      `NetworkDoesEntityExistWithNetworkId`/`NetworkGetEntityFromNetworkId`/
      `DoesEntityExist` sequence — three of the 11 copies the Revision 5
      whole-codebase audit found still bypassing this helper. confirmKennelPlaced
      additionally used to re-derive a separate `GetEntityType(entity) ~= 3`
      check alongside its own genuinely kennel-specific `KennelModelHashes`
      model-hash check; the type check is now folded into
      `ResolveNetworkEntity`'s `expectedEntityType = 3` argument (mirroring
      server/main.lua's relayDoorScratch), while the model-hash check stays
      at that call site, unchanged, since it isn't part of the generic
      resolve.
    - THIS FILE owns `Kennels` (citizenid -> { netId, ownerSrc, createdAt })
      and `PendingKennelPlacements` (citizenid -> { src, coords, expiresAt }),
      both local to this file. Nothing outside this file reads them
      directly.
    - THIS FILE does NOT touch LeashPairs, PendingLeashRequests, or any
      other server/main.lua-owned state — kennels are a wholly independent
      mechanic from leash/vehicle/bark/door-scratch.

    ONE-KENNEL-PER-HANDLER LIMIT — JUDGMENT CALL, documented per the task
    that scoped this feature ("one-per-handler-or-per-area limit — your
    call"). Chosen over a per-area/spatial limit for three reasons:
      1. Every other ephemeral per-player mechanic in this resource
         (LeashPairs, PendingLeashRequests, the certification cache) is
         keyed by citizenid or source, not by world position — a
         per-handler limit reuses that exact same shape (a plain
         `citizenid -> single entry` table) instead of introducing this
         resource's first spatial-radius-scan-based limit.
      2. A per-area limit needs a defined "area" (a zone list? a radius
         around every existing kennel? around each station?) that
         SPEC.md/PHASE4_SPEC.md/the Phase 5 research doc never define for
         this feature — inventing one here would be a real, undocumented
         design decision dressed up as a structural default.
      3. A per-handler cap already prevents the concrete abuse this limit
         exists for (one certified handler spamming kennels to clutter the
         world) without needing to reason about legitimate multi-handler
         cases (e.g. two separate K9 units at the same precinct both
         wanting a kennel nearby), which a naive per-area limit could
         wrongly block.
    NOT configurable — config.lua's Config.DeployableKennel deliberately has
    no `maxActivePerHandler` field. `Kennels` below is a single-slot
    `citizenid -> entry` table, not an array, so raising this limit later
    is a real code change (switch to an array + a count check), not a
    config flip. Flagged here rather than silently implying a tunable that
    doesn't exist.

    CLEANUP CONFIDENCE NOTE: RemoveKennelForCitizenid below attempts a
    direct server-side `DeleteEntity` on the resolved network entity.
    Deleting a networked mission entity from the SERVER side is an
    established, widely-used FiveM/OneSync pattern (e.g. server-side
    vehicle-impound/despawn scripts across the ecosystem routinely call
    `DeleteEntity` on a server-resolved vehicle) — used here with
    medium-high confidence per that convention, but NOT independently
    re-verified against this exact FXServer version's native behavior this
    session (no live server was reachable to test against, same sandbox
    limitation phase2_notes/*_natives.md files already document
    elsewhere). The broadcast to 'qbx_k9unit:client:removeKennel' (-1)
    immediately below it is a deliberate backstop, not redundant
    belt-and-suspenders for its own sake: if server-side DeleteEntity turns
    out to be a no-op in a given FXServer build, whichever CONNECTED client
    currently holds real network ownership of that entity (OneSync migrates
    ownership among connected clients as the original owner streams out or
    disconnects) still receives the broadcast and deletes it locally,
    closing the gap without needing to know which client that is.
]]

-- Kennels[citizenid] = { netId: number, ownerSrc: number, createdAt: number }
-- At most one entry per citizenid — see this file's header for the
-- one-kennel-per-handler reasoning. Local: nothing outside this file
-- should read it directly.
local Kennels = {}

-- PendingKennelPlacements[citizenid] = { src: number, coords: {x,y,z},
-- expiresAt: number } — mirrors server/main.lua's PendingLeashRequests
-- shape (a request awaiting a client-side follow-up action, with a TTL so
-- an unanswered one doesn't linger forever). Local: nothing outside this
-- file should read it directly.
local PendingKennelPlacements = {}

-- REFACTOR_ROADMAP.md item 1 convention (server/cooldowns.lua): per-source
-- rate limit on requesting a NEW placement — spam defense only, distinct
-- from the one-active-kennel-per-citizenid limit enforced separately below.
local DeployCooldown = NewCooldown(Config.DeployableKennel.deployCooldownMs)
DeployCooldown.RegisterPlayerDropped()

-- Meters of slack over the server-chosen spawn point allowed when
-- confirming a placement — covers PlaceObjectOnGroundProperly's vertical
-- ground-snap plus ordinary network/latency drift. Mirrors
-- DOOR_SCRATCH_DISTANCE_TOLERANCE's exact reasoning in server/main.lua.
local KENNEL_CONFIRM_DISTANCE_TOLERANCE = 3.0

-- Precomputed set of allowed kennel prop model hashes (primary +
-- documented fallback — see config.lua's Config.DeployableKennel comment
-- for why both are legitimate). Built once at file load, same pattern as
-- server/certifications.lua's K9ModelHashes.
local KennelModelHashes = {
    [GetHashKey(Config.DeployableKennel.propModel)] = true,
    [GetHashKey(Config.DeployableKennel.fallbackPropModel)] = true,
}

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by REFACTOR_ROADMAP.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

--- Deletes the citizenid's active kennel (server-side attempt + broadcast
--- backstop — see this file's header CLEANUP CONFIDENCE NOTE) and clears
--- the registry entry. Shared by the manual pickup path, the
--- playerDropped handler-disconnect path, and the onResourceStop path, so
--- there is exactly one place that mutates `Kennels` on removal.
--- @param citizenid string
local function RemoveKennelForCitizenid(citizenid)
    local kennel = Kennels[citizenid]
    if not kennel then return end
    Kennels[citizenid] = nil

    -- REFACTOR_ROADMAP.md item 2 (Revision 5 migration): was this file's
    -- own inline `NetworkDoesEntityExistWithNetworkId` / `NetworkGetEntityFromNetworkId`
    -- / `DoesEntityExist` sequence. No entity-type restriction is needed
    -- here (a kennel is being deleted by its own recorded netId, not
    -- validated against an unrelated claim), so this is called without
    -- expectedEntityType, same as server/search.lua's HandleSearchTarget.
    local entity = ResolveNetworkEntity(kennel.netId)
    if entity then
        DeleteEntity(entity)
    end

    -- Backstop broadcast — see CLEANUP CONFIDENCE NOTE above. A safe no-op
    -- for any client that doesn't have this netId streamed in at all
    -- (client/kennel.lua's own handler guards on
    -- NetworkDoesEntityExistWithNetworkId before doing anything).
    TriggerClientEvent('qbx_k9unit:client:removeKennel', -1, kennel.netId)
end

--- Step 1: certified handler asks to place a kennel near themselves. See
--- this file's header "WHY THE SERVER COMPUTES THE PLACEMENT COORDS" block
--- for why this computes and hands over a spawn point rather than
--- accepting one.
RegisterNetEvent('qbx_k9unit:server:requestDeployKennel', function()
    local src = source

    if not Config.Features.DeployableKennel then return end -- silent no-op, matches every other feature-flag gate in this resource

    if not HasK9Access(src) then
        NotifyPlayer(src, 'You are not authorized to deploy a K9 kennel.', 'error')
        return
    end

    if not DeployCooldown.Consume(src) then
        return -- silent no-op: rate-limited, matches bark/leash-request/certify-action convention
    end

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then
        NotifyPlayer(src, 'Unable to resolve your own citizen ID.', 'error')
        return
    end

    if Kennels[citizenid] then
        NotifyPlayer(src, 'You already have an active kennel deployed — pick it up before deploying another.', 'error')
        return
    end

    if PendingKennelPlacements[citizenid] then
        NotifyPlayer(src, 'A kennel placement is already in progress.', 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    local pedCoords = GetEntityCoords(ped)
    local forward = GetEntityForwardVector(ped)
    local offset = Config.DeployableKennel.placementForwardOffsetMeters

    local spawnX = pedCoords.x + forward.x * offset
    local spawnY = pedCoords.y + forward.y * offset
    local spawnZ = pedCoords.z -- PlaceObjectOnGroundProperly (client-side) corrects height for terrain; a rough same-level estimate is enough to hand off

    PendingKennelPlacements[citizenid] = {
        src = src,
        coords = { x = spawnX, y = spawnY, z = spawnZ },
        expiresAt = GetGameTimer() + Config.DeployableKennel.pendingPlacementTtlMs,
    }

    TriggerClientEvent('qbx_k9unit:client:deployKennelAt', src, spawnX, spawnY, spawnZ)
end)

--- Step 2: client reports the network id of the object it actually
--- created. Re-validates everything from step 1 plus the entity itself —
--- see this file's header EVENT/CALLBACK CONTRACT item 2 for the full
--- reasoning.
--- @param netId number
RegisterNetEvent('qbx_k9unit:server:confirmKennelPlaced', function(netId)
    local src = source

    if type(netId) ~= 'number' then return end

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    local pending = PendingKennelPlacements[citizenid]
    if not pending or pending.src ~= src then
        return -- no matching pending placement for this citizenid/source pair — ignore, never trust an unsolicited confirm
    end
    PendingKennelPlacements[citizenid] = nil -- consumed either way, success or rejected below

    if GetGameTimer() > pending.expiresAt then
        NotifyPlayer(src, 'Kennel placement timed out — try again.', 'error')
        return
    end

    -- Re-validate — a certification revoke, a feature-flag toggle, or
    -- (shouldn't be reachable, but never trust an invariant alone) a
    -- second kennel landing could have happened during the round trip.
    if not Config.Features.DeployableKennel then return end
    if not HasK9Access(src) then return end
    if Kennels[citizenid] then return end

    -- REFACTOR_ROADMAP.md item 2 (Revision 5 migration): was this file's
    -- own `NetworkDoesEntityExistWithNetworkId` existence guard followed by
    -- a SEPARATE `GetEntityType(entity) ~= 3` check further down — both
    -- are now server/entities.lua's shared ResolveNetworkEntity(), called
    -- with expectedEntityType = 3 to fold the object-only restriction in
    -- as one call, mirroring server/main.lua's relayDoorScratch exactly.
    -- The genuinely kennel-specific KennelModelHashes check stays here,
    -- unchanged, since it isn't part of the generic resolve.
    --
    -- DISCLOSED, NOT SILENT, MESSAGE-WORDING CHANGE: before this
    -- migration, an entity that existed but had the wrong GetEntityType
    -- got its own distinct "unexpected entity type" notification, separate
    -- from the "could not be confirmed" wording used for a nonexistent
    -- entity. Folding both into one ResolveNetworkEntity(netId, 3) call
    -- means both cases now return nil and share the "could not be
    -- confirmed" message below — the REJECTION itself is unchanged (both
    -- cases still fail closed), only the player-facing wording for the
    -- wrong-type case is now less specific. Flagged explicitly per this
    -- resource's own "strengthen/change silently never, disclose always"
    -- convention (see server/entities.lua's own doc comment for the
    -- precedent on HandleSearchTarget's existence-check strengthening).
    local entity = ResolveNetworkEntity(netId, 3)
    if not entity then
        NotifyPlayer(src, 'Kennel placement failed — the object could not be confirmed.', 'error')
        return
    end

    -- Defense-in-depth (relayDoorScratch precedent, server/main.lua):
    -- confirm the reported entity is actually one of the two configured
    -- kennel prop models, not an arbitrary pre-existing networked object a
    -- modified client could report instead of a genuine new kennel.
    if not KennelModelHashes[GetEntityModel(entity)] then
        NotifyPlayer(src, 'Kennel placement failed — unexpected object model.', 'error')
        return
    end

    local entityCoords = GetEntityCoords(entity)
    local dx = entityCoords.x - pending.coords.x
    local dy = entityCoords.y - pending.coords.y
    local dz = entityCoords.z - pending.coords.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > KENNEL_CONFIRM_DISTANCE_TOLERANCE then
        NotifyPlayer(src, 'Kennel placement failed — placed too far from the assigned spot.', 'error')
        return
    end

    Kennels[citizenid] = {
        netId = netId,
        ownerSrc = src,
        createdAt = GetGameTimer(),
    }

    NotifyPlayer(src, 'Kennel deployed.', 'success')
end)

--- Client reports its own placement attempt failed (model never loaded,
--- PlaceObjectOnGroundProperly returned false) — frees the pending slot
--- immediately rather than making the handler wait out the TTL before
--- retrying.
RegisterNetEvent('qbx_k9unit:server:cancelKennelPlacement', function()
    local src = source

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    local pending = PendingKennelPlacements[citizenid]
    if pending and pending.src == src then
        PendingKennelPlacements[citizenid] = nil
    end
end)

--- Owning handler removes their own kennel early — see this file's header
--- item 4. Ownership is re-verified against the registry, never trusted
--- from the client's own claim of "this is my kennel."
--- @param netId number
RegisterNetEvent('qbx_k9unit:server:requestPickupKennel', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    local kennel = Kennels[citizenid]
    if not kennel or kennel.netId ~= netId then
        NotifyPlayer(src, 'You do not own that kennel.', 'error')
        return
    end

    RemoveKennelForCitizenid(citizenid)
    NotifyPlayer(src, 'Kennel picked up.', 'success')
end)

-- Handler-disconnect cleanup (task requirement: kennels must not leak
-- permanently into the world). Resolves citizenid for the disconnecting
-- source BEFORE the framework fully tears down the player object, same
-- established pattern as server/certifications.lua's own playerDropped
-- handler.
AddEventHandler('playerDropped', function(_reason)
    local src = source

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    if PendingKennelPlacements[citizenid] and PendingKennelPlacements[citizenid].src == src then
        PendingKennelPlacements[citizenid] = nil
    end

    -- Only remove if THIS disconnecting source is actually the current
    -- owner on record — guards the (narrow, practically unreachable today
    -- since Kennels is keyed by citizenid 1:1 with a live source) case of
    -- acting on stale ownership.
    if Kennels[citizenid] and Kennels[citizenid].ownerSrc == src then
        RemoveKennelForCitizenid(citizenid)
    end

    -- DeployCooldown already registered its own playerDropped handler via
    -- :RegisterPlayerDropped() above — REFACTOR_ROADMAP.md item 1
    -- convention, nothing to do for it here.
end)

-- Resource-stop cleanup (task requirement, same class of gap
-- client/vehicle.lua's own onResourceStop comment calls "ship-blocking"
-- for its own entity-state case): a resource restart must not leave any
-- already-deployed kennel behind as a permanent, orphaned world object.
-- This pass is specifically for kennels whose ORIGINAL creating client
-- already disconnected earlier in the session — client/kennel.lua's own
-- onResourceStop handler independently covers the (more common) case of a
-- still-connected client cleaning up its own creation; this loop exists to
-- catch what that can't.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- REFACTOR_ROADMAP.md item 2 (Revision 5 migration): was this file's
    -- own inline existence-check sequence, same as RemoveKennelForCitizenid
    -- above (no expectedEntityType needed here either).
    for _, kennel in pairs(Kennels) do
        local entity = ResolveNetworkEntity(kennel.netId)
        if entity then
            DeleteEntity(entity)
        end
    end
    -- Deliberately NOT also broadcasting 'qbx_k9unit:client:removeKennel'
    -- here — every other client's copy of THIS resource is stopping at
    -- essentially the same time, so their own removeKennel handler is
    -- about to be unregistered anyway (or already is), making a broadcast
    -- from this handler unreliable busywork, not a real backstop. The
    -- backstop's actual value (see CLEANUP CONFIDENCE NOTE) is for the
    -- ordinary pickup/disconnect paths above, while the resource and its
    -- clients are still fully running.
end)
