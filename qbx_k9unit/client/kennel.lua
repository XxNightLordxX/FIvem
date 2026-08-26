--[[
    qbx_k9unit/client/kennel.lua

    Phase 5 R&D scaffold (coder-architect structural pass). Owns the
    DeployableKennel feature's client-side placement mechanics and the
    "Pick Up Kennel"/"Rest in Kennel"/"Exit Kennel" ox_target entry points.
    See server/kennel.lua's header for the full event contract and the
    "server computes the placement coords" design rationale — this file
    only ever executes an instruction the server already validated, it
    never decides WHERE a kennel goes, WHO may attach to it, or whether an
    attach is authorized.

    NEW FILE (paired with server/kennel.lua), not folded into
    client/vehicle.lua or client/main.lua — same "one responsibility per
    file" convention as every other file pairing in this resource (see
    server/kennel.lua's header for the fuller version of this reasoning).

    ======================================================================
    K9-CAN-RIDE-ALONG PASS — CRITICAL SAFETY REDESIGN (this pass). Read
    server/kennel.lua's own header CRITICAL SAFETY / architecture section
    FIRST — this file is the client-side half of that same redesign, and
    repeats none of that reasoning here beyond what's specific to this
    file's own native calls.

    THE OCCUPANT IS ALWAYS A REAL, CURRENTLY-CONNECTED PLAYER'S OWN PED —
    owner's own explicit instruction, this pass: "Ensure its the k9 player
    that gets put in the cage not a spawned in dog." CONFIRMED: this file
    never calls CreatePed, anywhere. The "occupant" in every comment below
    means PlayerPedId() on THAT PLAYER'S OWN CLIENT (this file, running on
    their machine, reacting to their own 'qbx_k9unit:client:enterKennelConfirmed'),
    never an NPC and never a ped driven remotely from the handler's client.
    That occupant has their own live client throughout — they can move the
    camera, open the tablet, press keys, and disconnect, exactly like any
    other connected player, at every moment they are "resting" — nothing
    below ever assumes otherwise (see ReleaseKennelRest's own doc comment
    for the exit path this guarantees regardless of any of that).

    NO CROSS-PED DRIVING / NETWORK OWNERSHIP (owner's own explicit
    instruction, this pass): "Positioning is done to that player's own ped,
    on their own client... Do not try to drive another player's ped from
    the handler's client... Attaching one to the other crosses that
    boundary. client/combat.lua has extensive verified
    NetworkRequestControlOfEntity handling for exactly this situation; read
    it rather than inventing something." Read in full this pass (see that
    file's own "NETWORK OWNERSHIP OF THE TARGET PED" header section) rather
    than assumed. THIS FILE reuses that EXACT, already-verified pattern —
    a best-effort, fire-and-forget NetworkRequestControlOfEntity call on
    whichever entity is about to become the CHILD of an AttachEntityToEntity
    call THIS client does not already control, immediately before the
    attach itself, never a blocking wait (that file's own header explains
    why a wait loop would stall its one shared maintenance thread; this
    file's own maintenance thread, further below, would have the identical
    problem) — and never proceeds by attaching an entity this client does
    not itself own or have just requested control of onto ANOTHER PLAYER's
    ped. Concretely, two independent attach relationships exist, each
    maintained ONLY by whichever client is responsible for that
    relationship's own CHILD side:
      1. An occupant's OWN client attaches its OWN ped (the CHILD, always
         already self-owned — no control request needed, mirroring
         client/vehicle.lua's own EnterNearestK9Vehicle(), which attaches
         the player's own ped to a vehicle it does NOT necessarily own with
         zero NetworkRequestControlOfEntity calls anywhere in that file) to
         the kennel object (the PARENT, owned by whoever, irrelevant to this
         relationship).
      2. A carrying HANDLER's OWN client attaches the kennel OBJECT (the
         CHILD — NOT self-owned in general, since some other client
         created/last-touched it, exactly client/combat.lua's PropDragging
         scenario) to their OWN ped (the PARENT, always self-owned) —
         THIS is the relationship that needs NetworkRequestControlOfEntity,
         called on the kennel object, before every (re-)attach.
    Neither client ever attaches, detaches, or repositions the OTHER
    party's ped. The two relationships compose automatically into "the
    occupant moves with the handler" via the game engine's own transitive
    attachment hierarchy (a grandchild follows its parent's parent) — no
    code anywhere makes the occupant's ped and the handler's ped aware of
    each other at all.

    WHY A ONE-SHOT ATTACH (PLUS A COARSE, ~1s WATCHDOG RE-ASSERTION), NOT A
    PER-FRAME Wait(0) REASSERTION LOOP LIKE client/combat.lua's OWN
    PropDragging: that file's own header is explicit about WHY it reasserts
    every single frame — "a hostile TARGET can [detach] itself at any
    moment... the ONLY defense... is re-asserting... EVERY TICK." That
    reasoning is about an ADVERSARIAL party actively trying to break free.
    Neither relationship here has one: an occupant voluntarily rests inside
    a kennel it chose to enter, and a kennel object does not "fight" being
    carried. client/vehicle.lua's own EnterNearestK9Vehicle() — attaching a
    player's own, willing ped to a vehicle it does not own, the more
    directly analogous precedent for relationship 1 above — does a single
    ONE-SHOT AttachEntityToEntity call with NO per-frame reassertion loop
    at all, relying only on a coarse watchdog thread for backstop safety
    checks (has the vehicle despawned, has the rider died). This file
    follows THAT precedent for both relationships: attach once at the
    moment of entry/pickup, then let a single coarse (idle 2000ms / active
    1000ms, mirroring client/vehicle.lua's own dual-interval shape) shared
    watchdog thread (near the bottom of this file) handle: (a) safety
    backstops for BOTH relationships (own-death, entity-no-longer-
    resolvable with a debounced miss-streak, an occupant wandering out of
    range) that unconditionally self-release, and (b) — as a defensive
    middle ground for the ONE relationship that genuinely does cross an
    ownership boundary (the carry attach, relationship 2 above) — a
    periodic NetworkRequestControlOfEntity + AttachEntityToEntity
    re-assertion at that same ~1s cadence, cheap insurance against a rare
    silent detach without paying combat.lua's own Wait(0) cost for a
    feature with no adversarial party to defend against.

    ======================================================================
    EVENT/CALLBACK CONTRACT (client side; see server/kennel.lua for the
    full server-side version):
    Server events this file triggers (client->server):
      'qbx_k9unit:server:requestDeployKennel' ()
      'qbx_k9unit:server:confirmKennelPlaced' (netId: number)
      'qbx_k9unit:server:cancelKennelPlacement' ()
      'qbx_k9unit:server:requestPickupKennel' (netId: number)
      'qbx_k9unit:server:requestPutDownKennel' () -- NEW, this pass
      'qbx_k9unit:server:requestEnterKennel' (netId: number) -- NEW, this pass
      'qbx_k9unit:server:requestExitKennel' () -- NEW, this pass
    Client events this file registers (server->client):
      'qbx_k9unit:client:deployKennelAt' (x: number, y: number, z: number)
      'qbx_k9unit:client:removeKennel' (netId: number)
      'qbx_k9unit:client:pickupKennelConfirmed' (netId: number) -- NEW
      'qbx_k9unit:client:putDownKennelAt' (netId, x, y, z) -- NEW
      'qbx_k9unit:client:enterKennelConfirmed' (netId: number) -- NEW
      'qbx_k9unit:client:kennelCarrierLost' (netId: number) -- NEW
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes FOUR resource-globals (no `local`):
        RequestDeployKennel()
            Runs the command's own gating (feature flag, CanShowK9UI(),
            "already have one deployed" local check) and sends the deploy
            request — UNLESS this client is CURRENTLY CARRYING a kennel, in
            which case it means "put it back down instead" (see that
            function's own doc comment for why one entry point correctly
            serves both meanings, and why the carry branch is checked
            FIRST, ahead of even the feature-flag/CanShowK9UI() gates, the
            same "never gate an exit-adjacent action" doctrine
            client/vehicle.lua's own ExitK9Vehicle() already establishes).
            Exposed globally, not kept as a command-local closure, so a
            future radial item can call it directly — client/radial.lua's
            EXISTING "Deploy Kennel" item already does, unmodified, and
            gains the put-down behavior for free.
        IsRestingInKennel() -> boolean
            Whether THIS client's own ped is currently attached to a
            kennel as an occupant. Exposed for a future cross-file guard
            (client/appearance.lua's own K9 model-swap refusal list already
            checks the equivalently-shaped IsInK9Vehicle()/
            IsPropAttachmentEngaged() — this is the SAME shape, for a
            future consumer to wire in; not wired into that file by this
            pass, which does not own it).
        IsCarryingKennel() -> boolean
            Whether THIS client is currently carrying (has attached to
            its own hands) a kennel object.
    - THIS FILE calls client/main.lua's CanShowK9UI() and DenyK9UIAccess()
      before acting, same as every other gated client action in this
      resource. ANY PED (this resource's own established convention): this
      file never calls IsOwnModelK9() anywhere, confirmed by this file's
      own test suite — CanShowK9UI() alone already internally decouples
      role from model (Config.K9Appearance.requireK9ModelForRole), so a
      second, redundant model check here would wrongly hide the "Rest in
      Kennel" option from a K9-role holder on a non-dog body.
    - THIS FILE calls client/main.lua's ResolveNetworkEntity(netId)
      (DEVELOPER_REFERENCE.md item 2) everywhere an entity needs to be
      resolved from a netId — do not re-implement the
      NetworkDoesEntityExistWithNetworkId/NetworkGetEntityFromNetworkId/
      DoesEntityExist sequence here.
    - THIS FILE does NOT call client/propattachment.lua's AttachPropToOwnPed
      for the carry mechanic (a DELIBERATE DEVIATION from this pass's
      original brief, which named that helper as the thing to reuse for
      "make the pickup feel real" — recorded here rather than silently
      dropped): that helper always CreateObjects a brand NEW, separate
      prop, which is exactly incompatible with the owner's own subsequent,
      more specific correction that the SAME real object — with any
      occupant still attached to it — must be the one that ends up in the
      handler's hands. This file instead re-attaches the EXISTING,
      already-tracked kennel object directly (see the header architecture
      section above) — a small, dedicated AttachEntityToEntity call of its
      own, not a reimplementation of that helper's model-loading/CreateObject
      logic (there is no new model to load; the object already exists).
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
-- Config.DeployableKennel) -- built once at file load, used by the
-- removeKennel handler's defense-in-depth model check and by
-- kennelCarrierLost below. Not the same table client/main.lua's
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

-- Currently-active "I am resting inside a kennel" state for THIS client's
-- OWN ped, if any (nil otherwise). THIS PASS. Local-only. See
-- ReleaseKennelRest's own doc comment for the unconditional, always-
-- available exit this state's every consumer is built around.
--- @type { kennelNetId: number } | nil
local restState = nil

-- Network id of the kennel object THIS client is currently carrying
-- (attached to its own hands), if any (nil otherwise). THIS PASS.
-- Deliberately a NETWORK ID, not a cached raw entity handle, for the exact
-- reason client/vehicle.lua's own vehicleState stores a netId instead of a
-- handle (a handle can go stale if the entity streams out and back in over
-- a long carry) -- see ResolveNetworkEntity's own re-resolve-on-every-use
-- contract, used everywhere below instead of caching the handle across
-- calls.
local carriedKennelNetId = nil

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
        -- LEAK FIX: RequestModel above increments this model's streaming
        -- reference count; failing to load in time is a real exit path
        -- that must still release it.
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end
    return modelHash
end

--- @return boolean
function IsRestingInKennel()
    return restState ~= nil
end

--- @return boolean
function IsCarryingKennel()
    return carriedKennelNetId ~= nil
end

--- Re-resolves the kennel this client's own ped is currently attached to,
--- from its network id -- never trusts a cached handle to stay valid for
--- the whole rest (this resource's established
--- ResolveNetworkEntity-everywhere convention, mirroring
--- client/vehicle.lua's own ResolveVehicleFromState).
--- @return number? entity
local function ResolveKennelFromRestState()
    if not restState then return nil end
    return ResolveNetworkEntity(restState.kennelNetId)
end

--- Occupant's own, ALWAYS-AVAILABLE local release. See this file's header
--- CRITICAL SAFETY / architecture section. Detaches THIS client's own ped
--- from whatever it is currently attached to and restores collision,
--- REGARDLESS of Config.Features.DeployableKennel, HasK9Access, whether
--- the server can even be reached, or the kennel's own carried/deployed
--- state — DetachEntity never depends on its former parent still
--- existing, so this is safe to call unconditionally from every exit path
--- below (manual "Exit Kennel", wandering out of range, own death, the
--- kennel being lost/removed, this client's own resource stop). Runs its
--- own native cleanup FIRST, then fires the best-effort server bookkeeping
--- event — an occupant is guaranteed to be standing free, unfrozen,
--- visible, and collidable the instant this function's own native calls
--- return, whether or not 'qbx_k9unit:server:requestExitKennel' is ever
--- received, or has anything left to receive it at all.
--- @param notifyLocaleKey string?
local function ReleaseKennelRest(notifyLocaleKey)
    if not restState then return end
    restState = nil

    local ped = PlayerPedId()
    if DoesEntityExist(ped) then
        DetachEntity(ped, true, false)
        SetEntityCollision(ped, true, true)
    end

    if notifyLocaleKey then
        lib.notify({ title = locale('common.notify_title'), description = locale(notifyLocaleKey), type = 'success' })
    end

    TriggerServerEvent('qbx_k9unit:server:requestExitKennel')
end

--- Runs RequestDeployKennel()'s own client-side gating and, if it passes,
--- asks the server to compute a spawn point. See FILE-TO-FILE CONTRACT
--- above for why this is exposed globally rather than kept command-local,
--- and for the carry/put-down branch THIS PASS adds.
function RequestDeployKennel()
    if carriedKennelNetId then
        -- "Put it back down" -- deliberately checked FIRST, ahead of even
        -- the feature-flag/CanShowK9UI() gates below, mirroring
        -- client/vehicle.lua's own ExitK9Vehicle() precedent ("a handler
        -- whose certification lapses mid-ride must always be able to
        -- un-freeze/set down themselves"). server/kennel.lua's own
        -- requestPutDownKennel handler is itself unconditional for the
        -- identical reason -- see that handler's own doc comment.
        TriggerServerEvent('qbx_k9unit:server:requestPutDownKennel')
        return
    end

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

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE (coder-frontend precedent) -- mirrors
-- client/propattachment.lua's own identically-shaped fix; read that file's
-- own "REGISTRATION-TIME FEATURE GATE" header before changing this one --
-- this block follows it, not a second independent design. Every net event
-- registration, ox_target registration, and the shared watchdog thread
-- below are inside this single `if`, evaluated once at this file's own
-- load time (config.lua is a shared_scripts file, loaded in full before
-- any client_scripts file runs). RequestDeployKennel()/IsRestingInKennel()/
-- IsCarryingKennel() above stay OUTSIDE this gate on purpose -- they
-- already gate themselves internally (or are trivially false/no-op with
-- the feature off) and must stay reachable-but-inert for client/radial.lua/
-- client/tablet.lua's own `type(...) == 'function'` call sites, exactly as
-- client/propattachment.lua's own header documents for
-- RequestToggleK9PropAttachment.
-- ======================================================================
if Config.Features.DeployableKennel then

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
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD, see client/combat.lua's own header block
    if not Config.Features.DeployableKennel then return end
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    -- STALE-KENNEL GUARD (client/propattachment.lua's own "STALE-VEST
    -- GUARD" on attachK9Prop is the precedent this follows).
    if myKennelNetId then
        local staleEntity = ResolveNetworkEntity(myKennelNetId)
        if staleEntity then
            DeleteEntity(staleEntity)
        end
        myKennelNetId = nil
    end

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
---
--- THIS PASS: also the OCCUPANT's own defense-in-depth self-release check
--- — reachable far less often now that RemoveKennelForCitizenid itself
--- structurally refuses to run at all while occupied (see that function's
--- own doc comment), but kept as belt-and-suspenders in case some future
--- caller/admin action ever deletes a kennel out from under an occupant
--- anyway: this client must never depend on that never happening.
---
--- GATE THE START OF A THING, NEVER THE STOP (same doctrine as the "Exit
--- Kennel" ox_target option's own canInteract fix, this pass): the
--- self-release above must never be skippable by a stale/toggled
--- Config.Features.DeployableKennel reread, or the exact same
--- future-live-config-push trap applies here too — this handler no longer
--- rereads the flag at all. It is only ever registered while the feature
--- was on at THIS file's own load time (the REGISTRATION-TIME FEATURE GATE
--- further down already covers "genuinely inert with the feature off from
--- the start"); nothing below needs, or should have, a second, live check.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:removeKennel', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD, see client/combat.lua's own header block
    if type(netId) ~= 'number' then return end

    if restState and restState.kennelNetId == netId then
        ReleaseKennelRest('kennel.exit_kennel_removed')
    end

    if myKennelNetId == netId then
        myKennelNetId = nil
    end

    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    -- DEFENSE-IN-DEPTH MODEL CHECK — restricts the delete to an entity
    -- whose CURRENT model actually matches a configured kennel prop.
    if not KennelPropModelHashes[GetEntityModel(entity)] then return end

    DeleteEntity(entity)
end)

--- Server-issued instruction: the picker's own client attaches the SAME,
--- already-existing, real kennel object to its own hands. THIS PASS.
--- Never CreateObjects a new prop — see this file's header FILE-TO-FILE
--- CONTRACT note on why client/propattachment.lua's AttachPropToOwnPed is
--- deliberately NOT reused here.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:pickupKennelConfirmed', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if not Config.Features.DeployableKennel then return end
    if type(netId) ~= 'number' then return end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity or not KennelPropModelHashes[GetEntityModel(entity)] then
        -- The server already validated this before sending the
        -- instruction; a failure here means the object streamed out (or
        -- changed) in the brief round trip. Fail closed: don't attach
        -- anything, don't claim to be carrying anything.
        return
    end

    -- NETWORK OWNERSHIP -- see this file's header section. This client did
    -- not necessarily create/last-touch this object, so it must ask for
    -- control before attaching it to itself, mirroring
    -- client/combat.lua's own PropDragging precedent exactly (best-effort,
    -- fire-and-forget, never a blocking wait).
    NetworkRequestControlOfEntity(entity)

    -- Was frozen in place since deployment (or since its last put-down) —
    -- must be unfrozen before being repositioned via attachment, or the
    -- two would fight each other.
    FreezeEntityPosition(entity, false)

    local cfg = Config.DeployableKennel
    -- entity1 = the kennel OBJECT (not a ped) -- isPed = false, matching
    -- client/propattachment.lua's own vest-attach call shape exactly (same
    -- trailing flag set, same reasoning: a carried prop should not
    -- physically collide with its carrier, and should not use the
    -- ped-specific pitch/roll behavior since entity1 here is an object).
    AttachEntityToEntity(entity, PlayerPedId(), cfg.carryBoneIndex,
        cfg.carryOffsetX, cfg.carryOffsetY, cfg.carryOffsetZ,
        cfg.carryRotX, cfg.carryRotY, cfg.carryRotZ,
        true, false, false, false, 2, true)

    carriedKennelNetId = netId
end)

--- Server-issued instruction: detach the kennel this client is carrying,
--- reposition it at the server-computed drop point, and re-freeze it —
--- the mirror image of deployKennelAt, applied to an already-existing
--- object instead of a freshly created one. THIS PASS.
--- @param netId number
--- @param x number
--- @param y number
--- @param z number
RegisterNetEvent('qbx_k9unit:client:putDownKennelAt', function(netId, x, y, z)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if type(netId) ~= 'number' or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    if carriedKennelNetId == netId then
        carriedKennelNetId = nil
    end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity then return end -- nothing left to put down -- server already cleared its own bookkeeping regardless

    DetachEntity(entity, true, false)
    SetEntityCoords(entity, x, y, z, false, false, false, true)
    -- Not treated as fatal if this returns false (bad terrain under the
    -- drop point) — UNLIKE the fresh-deploy flow, this object can never be
    -- deleted on a placement failure here (it might have an occupant
    -- attached to it) — see server/kennel.lua's header CRITICAL SAFETY
    -- section. Freeze it wherever it ended up either way.
    PlaceObjectOnGroundProperly(entity)
    FreezeEntityPosition(entity, true)
end)

--- Server-issued instruction: this client's OWN ped attaches itself to the
--- kennel it just asked, and was authorized, to rest in. THIS PASS. Never
--- touches any OTHER player's ped — see this file's header NO CROSS-PED
--- DRIVING section.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:enterKennelConfirmed', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if not Config.Features.DeployableKennel then return end
    if type(netId) ~= 'number' then return end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity or not KennelPropModelHashes[GetEntityModel(entity)] then
        return -- streamed out / changed in the brief round trip -- fail closed
    end

    local ped = PlayerPedId()
    local kennelCoords = GetEntityCoords(entity)
    local kennelHeading = GetEntityHeading(entity)

    -- Positioned directly at the kennel's own coords/heading before
    -- attaching, so the very first rendered frame already shows the
    -- occupant genuinely inside the prop rather than snapping there over
    -- one visible tick.
    SetEntityCoords(ped, kennelCoords.x, kennelCoords.y, kennelCoords.z, false, false, false, true)
    SetEntityHeading(ped, kennelHeading)

    -- Collision disabled between the occupant and the (typically
    -- small-footprint) cage prop it now overlaps -- mirrors
    -- client/vehicle.lua's own EnterNearestK9Vehicle() precedent
    -- (SetEntityCollision(ped, false, false) while tucked into another
    -- entity's space) -- restored unconditionally by ReleaseKennelRest on
    -- every exit path.
    SetEntityCollision(ped, false, false)

    -- entity1 = the occupant's own PED -- isPed intentionally matches
    -- client/combat.lua's own PropDragging call (isPed = false) rather
    -- than this native's own doc-described "true for a ped" reading: that
    -- file's call also attaches a real ped (targetPed) as entity1 and is
    -- the only existing, shipped precedent in this codebase for this
    -- exact combination — matching a proven, already-integrated pattern
    -- was judged safer than a fresh, unverified deviation based on a
    -- doc-only reading with no live client available to test against this
    -- session. Config.DeployableKennel.restOffsetX/Y/Z default to 0,0,0
    -- (the prop's own origin) -- see that config field's own comment for
    -- why an untuned, disclosed placeholder was chosen over guessing a
    -- bone-specific offset.
    local cfg = Config.DeployableKennel
    AttachEntityToEntity(ped, entity, 0,
        cfg.restOffsetX, cfg.restOffsetY, cfg.restOffsetZ,
        0.0, 0.0, 0.0,
        true, false, false, false, 2, true)

    restState = { kennelNetId = netId }
    lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_success'), type = 'success' })
end)

--- Carrier-disconnect safety net (server/kennel.lua's own playerDropped
--- handler, event 12) — see that file's own doc comment for the full
--- reasoning. Broadcast (-1): whichever connected client currently has
--- this object streamed in settles it, since the disconnecting carrier's
--- own client can no longer do so itself. Never touches KennelOccupants or
--- any occupant's own restState -- an occupant riding inside is completely
--- unaffected by who is or isn't carrying the object it is itself attached
--- to, and keeps its own, completely independent exit throughout.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:kennelCarrierLost', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if not Config.Features.DeployableKennel then return end
    if type(netId) ~= 'number' then return end

    if carriedKennelNetId == netId then
        carriedKennelNetId = nil
    end

    local entity = ResolveNetworkEntity(netId)
    if not entity then return end
    if not KennelPropModelHashes[GetEntityModel(entity)] then return end

    -- Harmless no-op on an entity that's already detached/frozen -- safe
    -- for every client that happens to have this object streamed in to run
    -- this redundantly.
    DetachEntity(entity, true, false)
    FreezeEntityPosition(entity, true)
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
--
-- THIS PASS: also unconditionally releases THIS client's own restState
-- (detach own ped, restore collision -- exactly ReleaseKennelRest's own
-- native cleanup, run directly here rather than through that function
-- since there is no meaningful "notify" or "tell the server" step left to
-- run when this resource's own script instance is already stopping) and
-- carriedKennelNetId (detach only, NOT delete — the object itself is
-- server/kennel.lua's own onResourceStop sweep's responsibility, and that
-- sweep runs unconditionally, even for a carried/occupied kennel, exactly
-- because it is safe for it to: see that file's own doc comment for why
-- resource-restart deletion never depends on, and never endangers, an
-- occupant's own independent client-side release, which is exactly what
-- this handler performs regardless of what the server does to the shared
-- object).
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if myKennelNetId then
        local entity = ResolveNetworkEntity(myKennelNetId)
        if entity then
            DeleteEntity(entity)
        end
        myKennelNetId = nil
    end

    if restState then
        local ped = PlayerPedId()
        if DoesEntityExist(ped) then
            DetachEntity(ped, true, false)
            SetEntityCollision(ped, true, true)
        end
        restState = nil
    end

    if carriedKennelNetId then
        local entity = ResolveNetworkEntity(carriedKennelNetId)
        if entity then
            DetachEntity(entity, true, false)
        end
        carriedKennelNetId = nil
    end
end)

-- ======================================================================
-- SHARED WATCHDOG THREAD -- see this file's header "WHY A ONE-SHOT ATTACH"
-- section for the full reasoning behind this shape (mirrors
-- client/vehicle.lua's own dual-interval watchdog thread, not
-- client/combat.lua's per-frame reassertion thread). Handles safety
-- backstops for BOTH the occupant relationship (restState) and the carry
-- relationship (carriedKennelNetId) independently -- either can be active
-- without the other, and this thread's own idle/active interval choice
-- reflects whichever (if either) currently is, exactly like
-- client/vehicle.lua's own vehicleState-driven sleepMs selection.
-- ======================================================================
local KENNEL_WATCHDOG_IDLE_MS = 2000
local KENNEL_WATCHDOG_ACTIVE_MS = 1000
local KENNEL_WATCHDOG_MISS_THRESHOLD = 3 -- consecutive misses before treating an entity as actually gone -- see client/vehicle.lua's own identical constant for why a single miss is not trusted alone

CreateThread(function()
    local restMissStreak = 0
    local carryMissStreak = 0

    while true do
        local sleepMs = KENNEL_WATCHDOG_IDLE_MS

        if restState then
            sleepMs = KENNEL_WATCHDOG_ACTIVE_MS
            local ped = PlayerPedId()

            if DoesEntityExist(ped) and IsEntityDead(ped) then
                -- OWN-DEATH RELEASE -- mirrors client/vehicle.lua's own
                -- OWN-DEATH RELEASE branch exactly. ReleaseKennelRest
                -- itself is what actually frees the player; this branch
                -- only decides WHEN to call it.
                restMissStreak = 0
                ReleaseKennelRest('kennel.exit_own_downed')
            else
                local kennelEntity = ResolveKennelFromRestState()
                if kennelEntity then
                    restMissStreak = 0
                    -- WANDER-OFF EXIT: since this feature deliberately
                    -- never freezes or disables control on the occupant
                    -- (see this file's header), simply walking away is
                    -- ALREADY an unconditional, code-independent way out —
                    -- this branch only converts "wandered away" into a
                    -- clean, tracked exit (clears server-side occupancy)
                    -- rather than leaving a stale KennelOccupants entry
                    -- for a K9 who is provably no longer anywhere near the
                    -- kennel.
                    local dist = #(GetEntityCoords(ped) - GetEntityCoords(kennelEntity))
                    if dist > Config.DeployableKennel.interactDistanceMeters then
                        ReleaseKennelRest('kennel.exit_success')
                    end
                else
                    -- ENTITY-LOST WATCHDOG, debounced exactly like
                    -- client/vehicle.lua's own VEHICLE_WATCHDOG_MISS_THRESHOLD
                    -- (a single miss can be a momentary streaming hiccup,
                    -- not proof the object is actually gone).
                    restMissStreak = restMissStreak + 1
                    if restMissStreak >= KENNEL_WATCHDOG_MISS_THRESHOLD then
                        restMissStreak = 0
                        ReleaseKennelRest('kennel.exit_kennel_lost')
                    end
                end
            end
        else
            restMissStreak = 0
        end

        if carriedKennelNetId then
            sleepMs = KENNEL_WATCHDOG_ACTIVE_MS
            local ped = PlayerPedId()
            local kennelEntity = ResolveNetworkEntity(carriedKennelNetId)

            if DoesEntityExist(ped) and IsEntityDead(ped) then
                -- OWN-DEATH AUTO-DROP (carrier side) -- mirrors
                -- client/propattachment.lua's own OWN-DEATH AUTO-DETACH
                -- precedent. Reuses the SAME requestPutDownKennel flow an
                -- ordinary, voluntary put-down uses (server computes a
                -- fresh drop point from this now-downed ped's own live
                -- position and instructs the matching detach/reposition/
                -- refreeze) rather than a separate, duplicate native
                -- sequence here -- carriedKennelNetId is cleared by that
                -- response handler itself once it arrives, not here, so a
                -- delayed response still finds a consistent local state.
                carryMissStreak = 0
                lib.notify({ title = locale('common.notify_title'), description = locale('kennel.exit_own_downed'), type = 'error' })
                TriggerServerEvent('qbx_k9unit:server:requestPutDownKennel')
            elseif kennelEntity then
                carryMissStreak = 0
                -- PERIODIC RE-ASSERTION (this file's header "WHY A ONE-SHOT
                -- ATTACH" section) -- cheap insurance at this coarse
                -- cadence against a rare silent detach, for the one
                -- relationship that genuinely crosses an ownership
                -- boundary.
                NetworkRequestControlOfEntity(kennelEntity)
                local cfg = Config.DeployableKennel
                AttachEntityToEntity(kennelEntity, ped, cfg.carryBoneIndex,
                    cfg.carryOffsetX, cfg.carryOffsetY, cfg.carryOffsetZ,
                    cfg.carryRotX, cfg.carryRotY, cfg.carryRotZ,
                    true, false, false, false, 2, true)
            else
                carryMissStreak = carryMissStreak + 1
                if carryMissStreak >= KENNEL_WATCHDOG_MISS_THRESHOLD then
                    carryMissStreak = 0
                    carriedKennelNetId = nil
                    lib.notify({ title = locale('common.notify_title'), description = locale('kennel.exit_kennel_lost'), type = 'error' })
                end
            end
        else
            carryMissStreak = 0
        end

        Wait(sleepMs)
    end
end)

-- "Pick Up Kennel" / "Rest in Kennel" / "Exit Kennel" ox_target entry
-- points — target EITHER configured kennel model (primary or fallback,
-- see config.lua's comment on why both are legitimate) directly by model
-- hash via ox_target's addModel.
--
-- VISIBILITY VS. AUTHORIZATION: every canInteract below is a UX
-- convenience only (this resource's established standard,
-- server/certifications.lua's own header: "client-side ox_target option
-- visibility... [is a] UX convenience only, not access control") —
-- server/kennel.lua's own handlers independently re-verify real
-- authorization/ownership/proximity/occupancy and reject (with a
-- notification, not silently) anyone who slips past a stale or
-- optimistic canInteract.
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call.
--
-- ICON/GATE CONVENTION (coder-frontend, cross-file input this pass):
-- 'fas fa-dog' + CanShowK9UI() marks an action the K9 itself performs on
-- itself (Enter/Exit Kennel, matching this resource's existing fa-dog
-- convention for self-administered K9 actions);
-- 'fas fa-user-tie' + a lighter HasK9Access()-only check marks the
-- separate HUMAN HANDLER action of picking the kennel up — a handler
-- carrying a box does not require currently being a dog, so this option
-- is deliberately NOT gated behind CanShowK9UI() the way it
-- was before this pass (that old gate meant only a player literally in K9
-- form could ever see "Pick Up Kennel" at all, which never made sense for
-- a handler-side action and is fixed here as part of the same pass that
-- widens WHO may perform it server-side).
--
-- LIFECYCLE FIX: extracted into a named function so these options can be
-- re-registered any time the resource actually backing the 'target'
-- system (re)starts, not just once at this file's own load time — mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory.
local function RegisterKennelOxTargetOption()
    if not Config.Features.DeployableKennel then return end

    K9Compat.Get('target').AddModel({
        GetHashKey(Config.DeployableKennel.propModel),
        GetHashKey(Config.DeployableKennel.fallbackPropModel),
    }, {
        {
            name = 'qbx_k9unit:pickupKennel',
            icon = 'fas fa-user-tie',
            label = locale('kennel.pickup_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.DeployableKennel then return false end
                if IsCarryingKennel() then return false end -- can't pick up a second one while already carrying one
                -- Soft dependency, this resource's established convention
                -- (client/vehicle.lua's own IsDragEngaged/IsBiteHoldEngaged
                -- guards) -- client/main.lua's HasK9Access() is a
                -- resource-global that always exists once that file loads,
                -- but guarded anyway for consistency with every other
                -- cross-file optional check in this file.
                return type(HasK9Access) == 'function' and HasK9Access()
            end,
            onSelect = function(data)
                if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                TriggerServerEvent('qbx_k9unit:server:requestPickupKennel', netId)
            end,
        },
        {
            name = 'qbx_k9unit:enterKennel',
            icon = 'fas fa-dog',
            label = locale('kennel.enter_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.DeployableKennel then return false end
                if IsRestingInKennel() or IsCarryingKennel() then return false end
                -- ANY PED (this resource's own established convention,
                -- confirmed by this file's own test suite: "never calls
                -- IsOwnModelK9() anywhere") -- CanShowK9UI() alone already
                -- internally decouples role from model
                -- (Config.K9Appearance.requireK9ModelForRole), so a K9-role
                -- holder on a non-dog body is not wrongly hidden from this
                -- option by a second, redundant model check here.
                return CanShowK9UI()
            end,
            onSelect = function(data)
                if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                TriggerServerEvent('qbx_k9unit:server:requestEnterKennel', netId)
            end,
        },
        {
            name = 'qbx_k9unit:exitKennel',
            icon = 'fas fa-dog',
            label = locale('kennel.exit_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            -- GATE THE START OF A THING, NEVER THE STOP: this is the exact
            -- client-side half of server/kennel.lua's own requestExitKennel
            -- handler (that file's event 7' doc comment: "NEVER gated on
            -- Config.Features.DeployableKennel... or anything else outside
            -- the occupant's own citizenid"). ReleaseKennelRest itself is
            -- already unconditional (see its own doc comment) and does not
            -- read this flag either -- rereading it here bought nothing but
            -- a way for a future live config push to hide this option out
            -- from under a still-attached occupant and strand them inside
            -- the prop. No flag check belongs on an exit path.
            canInteract = function(entity, distance, coords, name)
                return IsRestingInKennel() and ResolveKennelFromRestState() == entity
            end,
            onSelect = function()
                ReleaseKennelRest('kennel.exit_success')
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterKennelOxTargetOption()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterKennelOxTargetOption()
    end
end)

end -- if Config.Features.DeployableKennel -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
