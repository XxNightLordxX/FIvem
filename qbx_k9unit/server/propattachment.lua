--[[
    qbx_k9unit/server/propattachment.lua

    Config.Features.PropAttachments (Phase 5 R&D, still `false` by default —
    see config.lua's own "ship disabled until acceptance criteria are fully
    met" convention). A certified handler, while their OWN character is a
    recognized K9 model, may toggle a visible cosmetic prop (a vest/harness)
    attached to their own ped, visible to everyone. NEW FILE PAIR (this file
    + client/propattachment.lua), not folded into server/kennel.lua or
    server/main.lua — same "one responsibility per file" convention those
    two files' own headers already establish; a prop-attach registry is a
    different lifecycle/ownership shape than a placed world object (kennel)
    or a small stateless relay (main.lua's bark/door-scratch).

    ======================================================================
    THE RESEARCH BLOCKER AND THE REFRAME (read before touching boneIndex
    anywhere in this file or config.lua's Config.PropAttachments):
    AttachEntityToEntity takes a bone INDEX, not a name — no documented bone
    NAME exists for a quadruped/animal skeleton in this codebase's own
    research, and none of this resource's Phase 3 combat/drag code needed
    one either (client/combat.lua's PropDragging attach call already uses a
    bare numeric bone index, 0, against a PLAYER ped for exactly this
    reason). The correct way to find the RIGHT index for "on the K9's back"
    is an in-engine visual sweep, not more documentation searching — see
    client/bonetool.lua / server/bonetool.lua, the dev-only tool built
    alongside this feature specifically to answer that question on a real
    dev server. Config.PropAttachments.boneIndex defaults to 0 (the root
    bone — present on virtually any skeleton) so an unconfirmed value
    degrades to "attached at the wrong point, visibly wrong," never a
    crash — see this file's own model/attach validation below for why a bad
    boneIndex can never become a security or entity-leak problem either.
    ======================================================================

    ======================================================================
    WHY THIS NEVER ACCEPTS A CLIENT-CLAIMED TARGET PED, UNLIKE KENNEL'S
    PICKUP/CONFIRM FLOW: every action in this file operates ONLY on the
    calling player's OWN ped, resolved server-side via GetPlayerPed(source)
    — there is no "attach to netId X" event anywhere in this contract, and
    no such event should ever be added without re-deriving this reasoning.
    This is a STRONGER posture than server/kennel.lua's own
    confirmKennelPlaced (which has to accept a client-claimed netId because
    a kennel is a brand-new object with no pre-existing entity to anchor to)
    — here there IS a pre-existing entity to anchor to (the caller's own
    ped), so accepting a claimed netId for it at all would be an unforced
    trust boundary this file simply does not create. The one place a netId
    IS accepted from the client (confirmPropAttached below) is the object
    the CLIENT just created in response to this file's own instruction —
    and even then, this file does not trust that claim blindly: see
    HandleConfirmPropAttached's defense-in-depth checks (model allowlist +
    live-position tolerance against the caller's own ped, mirroring
    server/kennel.lua's KENNEL_CONFIRM_DISTANCE_TOLERANCE pattern) before
    that netId is ever stored in `PropAttachmentState` (and therefore ever
    reachable by a future DeleteEntity call).
    ======================================================================

    EVENT/CALLBACK CONTRACT:
    Server events (RegisterNetEvent, client->server):
    1. 'qbx_k9unit:server:requestToggleK9PropAttachment' () [THIS FILE]
       No arguments — see "WHY THIS NEVER ACCEPTS" above. If the caller
       currently has an active attachment on record, this is a REMOVE
       (immediate, no round trip needed — nothing to confirm when taking
       something off). Otherwise this is an ADD: validates flag/access/own
       model/cooldown, opens a short-lived pending slot, and instructs the
       SAME client to create+attach the prop to its own ped (event 3).
    2. 'qbx_k9unit:server:confirmPropAttached' (netId: number) [THIS FILE]
       Client reports the network id of the object it actually created in
       response to event 3. Re-validates everything event 1 already
       checked, PLUS the object's model (allowlist) and live position
       (tolerance against the caller's own live ped coords) — see
       HandleConfirmPropAttached.
    3. 'qbx_k9unit:server:cancelPropAttachRequest' () [THIS FILE]
       Client reports its own attach attempt failed (model never loaded) —
       frees the pending slot immediately, mirrors
       server/kennel.lua's 'qbx_k9unit:server:cancelKennelPlacement'.
    4. 'qbx_k9unit:server:reportOwnK9PropAttachDeath' () [THIS FILE]
       Self-report: "my own ped, which currently owns an active prop
       attachment, just died." Self-reported facts about the reporting
       player's OWN state are an already-accepted trust category in this
       resource (server/tracking.lua's relayDamageEvent/relayWeaponFire —
       "victim/shooter reports their own event" — and
       server/wellbeing.lua's consumption of those same relays); the worst
       a lie here can do is remove the reporter's OWN cosmetic attachment
       early, which is not a security-relevant outcome. Re-verifies
       ownership (PropAttachmentState[citizenid].ownerSrc == src) before
       acting regardless.

    Client events (RegisterNetEvent, server->client), both sent ONLY to the
    one client the action concerns, never broadcast:
    5. 'qbx_k9unit:client:attachK9Prop' () [client/propattachment.lua]
       Instruction: create+attach the configured prop to your OWN ped, then
       report its netId back via event 2.
    6. 'qbx_k9unit:client:rejectK9PropAttach' () [client/propattachment.lua]
       This file rejected a confirm (event 2) after the client already
       created+attached something locally — tells that client to undo it.
    7. 'qbx_k9unit:client:removeK9PropAttachment' (netId: number)
       [client/propattachment.lua] — broadcast (-1) cleanup backstop for a
       removal (manual toggle-off, disconnect, resource stop, or a death
       report), same CLEANUP CONFIDENCE NOTE/reasoning as
       server/kennel.lua's own 'qbx_k9unit:client:removeKennel' broadcast:
       a direct server-side DeleteEntity is attempted first; this broadcast
       is the belt-and-suspenders backstop for whichever connected client
       currently holds real OneSync network ownership of that entity, in
       case the server-side delete turns out to be a no-op for this exact
       FXServer build (not independently re-verified in this sandbox).

    Commands: '/k9propattach' toggle command lives in client/propattachment.lua
    (self-administered action, same "client-side entry point calling a
    client-side global" convention as client/kennel.lua's '/k9deploykennel'
    — see that file's header for the fuller version of this reasoning).

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)` and `IsConfiguredK9Model(modelHash)`,
      both exposed by server/certifications.lua — do not re-derive either
      check here.
    - THIS FILE calls `NewCooldown()` (server/cooldowns.lua) at file-load
      time — must load after that file, same requirement every other
      consumer already states.
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)`
      (server/entities.lua) — do not re-implement the resolve/
      existence-guard sequence here.
    - THIS FILE owns `PropAttachmentState` (citizenid -> { netId, ownerSrc })
      and `PendingPropAttachConfirm` (citizenid -> { src, expiresAt }), both
      local to this file. Nothing outside this file reads them directly.
    - THIS FILE exposes NO resource-global functions — no other file in this
      resource, and (per this pass's own cross-agent note) no consumer of
      the concurrently-built FetchMechanic feature, needs to call into
      prop-attachment state directly. What IS shared with FetchMechanic is
      client-side (see client/propattachment.lua's own FILE-TO-FILE
      CONTRACT: AttachPropToOwnPed/DetachAndDeleteProp) and the dev-only
      bone-index tool (client/bonetool.lua + server/bonetool.lua) — neither
      of those lives in this file.

    CONFIG THIS FILE ASSUMES EXISTS — NOT owned by this file (coder-architect
    owns config.lua/fxmanifest.lua/.luacheckrc for this task; see this pass's
    own hand-off note for the exact blocks needed). Config.Features.PropAttachments
    already exists in config.lua (still `false`) — no new feature flag is
    needed for this file. New shape required, asserted at resource start
    below exactly like server/admin.lua's own config-safety-guard convention:
      Config.PropAttachments.propModel                : string
      Config.PropAttachments.fallbackPropModel         : string
      Config.PropAttachments.boneIndex                 : number (integer >= 0)
      Config.PropAttachments.offsetX/offsetY/offsetZ    : number
      Config.PropAttachments.rotX/rotY/rotZ             : number
      Config.PropAttachments.toggleCooldownMs          : number
      Config.PropAttachments.pendingConfirmTtlMs       : number
      Config.PropAttachments.confirmDistanceTolerance  : number
]]

-- PropAttachmentState[citizenid] = { netId: number, ownerSrc: number }
-- At most one active attachment per citizenid. Local: nothing outside this
-- file should read it directly.
local PropAttachmentState = {}

-- PendingPropAttachConfirm[citizenid] = { src: number, expiresAt: number } —
-- mirrors server/kennel.lua's PendingKennelPlacements shape (a request
-- awaiting a client-side follow-up action, with a TTL so an unanswered one
-- doesn't linger forever). Local: nothing outside this file should read it
-- directly.
local PendingPropAttachConfirm = {}

-- REFACTOR_ROADMAP.md item 1 convention (server/cooldowns.lua): per-source
-- rate limit on toggling the attachment — spam/abuse guard only, distinct
-- from the one-active-attachment-per-citizenid limit enforced separately
-- below. Threshold supplied per-call from Config.PropAttachments.toggleCooldownMs,
-- matching server/kennel.lua's DeployCooldown shape (no default baked in at
-- construction).
local ToggleCooldown = NewCooldown()
ToggleCooldown.RegisterPlayerDropped()

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by REFACTOR_ROADMAP.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

--- Resolves the calling source's own citizenid, or nil if it can't be
--- resolved (disconnected mid-flight, qbx_core not ready yet, etc.). Every
--- handler in this file bails out on nil, same defensive posture as every
--- other file in this resource that keys state by citizenid.
--- @param src number
--- @return string? citizenid
local function ResolveCitizenId(src)
    local player = exports.qbx_core:GetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

--- Precomputed set of allowed prop model hashes (primary + configured
--- fallback). Built once at file load, same pattern as
--- server/kennel.lua's own KennelModelHashes. Used ONLY by
--- HandleConfirmPropAttached's defense-in-depth model check below — this is
--- what makes "the attach path can't be used to attach an arbitrary
--- caller-supplied netId" concretely true: even a fully-forged confirm
--- payload can only ever be accepted if it names something that already
--- has one of these two exact models.
local PropAttachmentModelHashes

--- Builds/rebuilds PropAttachmentModelHashes from live config. Deferred
--- into a function (rather than a bare file-load-time block like
--- server/kennel.lua's KennelModelHashes) purely so the onResourceStart
--- config-shape assert below can run BEFORE this reads
--- Config.PropAttachments fields — see that guard's own comment for why a
--- missing/malformed Config.PropAttachments must fail loudly at start
--- rather than let this table silently build out of two nil hashes.
local function BuildPropAttachmentModelHashes()
    PropAttachmentModelHashes = {
        [GetHashKey(Config.PropAttachments.propModel)] = true,
        [GetHashKey(Config.PropAttachments.fallbackPropModel)] = true,
    }
end

--- Removes citizenid's active prop attachment: server-side DeleteEntity
--- attempt + broadcast backstop (see this file's header CLEANUP CONFIDENCE
--- NOTE on event 7), then clears the registry entry. Shared by the manual
--- toggle-off path, the death-report path, the playerDropped path, and the
--- onResourceStop path, so there is exactly one place that mutates
--- `PropAttachmentState` on removal — mirrors server/kennel.lua's
--- RemoveKennelForCitizenid exactly.
--- @param citizenid string
local function RemovePropAttachmentForCitizenid(citizenid)
    local attachment = PropAttachmentState[citizenid]
    if not attachment then return end
    PropAttachmentState[citizenid] = nil

    local entity = ResolveNetworkEntity(attachment.netId)
    if entity then
        DeleteEntity(entity)
    end

    TriggerClientEvent('qbx_k9unit:client:removeK9PropAttachment', -1, attachment.netId)
end

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE (coder-security, this pass) — everything
-- below (all four RegisterNetEvent handlers, the playerDropped/onResourceStop
-- cleanup hooks, and the onResourceStart config-safety guard) is now inside
-- this single `if`, evaluated once at this file's own load time. Config.lua
-- is a shared_scripts file, loaded in full before any server_scripts file
-- runs, so Config.Features.PropAttachments already holds its real
-- true/false value by the time this line executes — this is NOT a
-- load-order gamble.
-- WHY THIS MATTERS BEYOND THE EXISTING PER-HANDLER `if not
-- Config.Features.PropAttachments then return end` CHECKS ALREADY INSIDE
-- each handler below (kept, deliberately, as defense-in-depth — same
-- "layered checks over a single point of failure" posture as the
-- SOURCE-ORIGIN GUARD in client/propattachment.lua remaining even though
-- the feature gate also exists): a per-handler check still means
-- 'qbx_k9unit:server:requestToggleK9PropAttachment' (etc.) IS a registered,
-- reachable event on a server with the feature left off — a client can
-- still fire it, still reach this file's Lua, and only then get turned
-- away. Wrapping the registration itself in the flag means an operator who
-- has never opted into PropAttachments has a server where these events do
-- not exist AT ALL — genuinely inert, not merely hidden behind an early
-- return. This resource's own established convention already does this at
-- COMMAND-registration time (server/bonetool.lua's '/k9bonetool' is only
-- ever RegisterCommand'd inside its own flag-checked onResourceStart) —
-- this applies the identical reasoning to RegisterNetEvent/AddEventHandler.
-- ======================================================================
if Config.Features.PropAttachments then

--- Step 1: toggle. See this file's header EVENT/CALLBACK CONTRACT item 1.
RegisterNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', function()
    local src = source

    if not Config.Features.PropAttachments then return end -- silent no-op, matches every other feature-flag gate in this resource

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    -- Already active -> this request means "take it off." No round trip
    -- needed to remove something, unlike placing it.
    if PropAttachmentState[citizenid] then
        RemovePropAttachmentForCitizenid(citizenid)
        NotifyPlayer(src, 'K9 vest removed.', 'success')
        return
    end

    -- Eligibility is re-checked BEFORE consuming the cooldown below —
    -- mirrors server/kennel.lua's requestDeployKennel ordering exactly
    -- (HasK9Access checked before DeployCooldown.Consume there), so an
    -- ineligible caller repeatedly hitting this event never burns down
    -- their own cooldown allowance for attempts that were always going to
    -- be rejected anyway.
    if not HasK9Access(src) then
        NotifyPlayer(src, 'You are not authorized to use K9 equipment.', 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    if not IsConfiguredK9Model(GetEntityModel(ped)) then
        NotifyPlayer(src, 'You must be in a K9 form to wear this.', 'error')
        return
    end

    if PendingPropAttachConfirm[citizenid] then
        return -- an attach is already in flight for this citizenid; don't open a second pending slot
    end

    if not ToggleCooldown.Consume(src, Config.PropAttachments.toggleCooldownMs) then
        return -- silent no-op: rate-limited, matches bark/leash-request/certify-action convention
    end

    PendingPropAttachConfirm[citizenid] = {
        src = src,
        expiresAt = GetGameTimer() + Config.PropAttachments.pendingConfirmTtlMs,
    }

    TriggerClientEvent('qbx_k9unit:client:attachK9Prop', src)
end)

--- Step 2: client reports the network id of the object it actually
--- created+attached. See this file's header "WHY THIS NEVER ACCEPTS..."
--- block for the full reasoning on why this is still independently
--- re-validated even though the id names an entity the client was JUST
--- instructed to create.
--- @param netId number
RegisterNetEvent('qbx_k9unit:server:confirmPropAttached', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local pending = PendingPropAttachConfirm[citizenid]
    if not pending or pending.src ~= src then
        return -- no matching pending request for this citizenid/source pair — ignore, never trust an unsolicited confirm
    end
    PendingPropAttachConfirm[citizenid] = nil -- consumed either way, success or rejected below

    if GetGameTimer() > pending.expiresAt then
        NotifyPlayer(src, 'K9 vest attach timed out — try again.', 'error')
        -- ORPHANED-PROP FIX (coder-backend, this pass): this branch used to
        -- notify but never send 'qbx_k9unit:client:rejectK9PropAttach' —
        -- unlike every one of this handler's sibling failure branches below
        -- (model/position checks), which correctly pair their own
        -- NotifyPlayer with this same event. The client already created a
        -- real, attached, networked vest object before this confirm was
        -- even sent (client/propattachment.lua's own attachK9Prop handler)
        -- — notifying without this event left that object permanently
        -- untracked both server- and client-side (see that file's own
        -- STALE-VEST GUARD comment, which documents this exact gap and the
        -- narrower client-only mitigation it added without owning this
        -- file). No netId-trust concern here (unlike server/fetch.lua's
        -- equivalent fix): this event takes no argument — the client's own
        -- handler deletes ITS OWN locally-tracked `myVestEntity`, never a
        -- server-supplied netId, so there is no equivalent to that file's
        -- GLOBAL NETID-UNIQUENESS collision risk to reason about here.
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end

    -- Re-validate — a certification revoke, a feature-flag toggle, or a
    -- second attachment landing during the round trip must all be caught
    -- again here, exactly like server/kennel.lua's confirmKennelPlaced.
    --
    -- ORPHANED-PROP FIX (coder-backend, this pass): all three re-checks
    -- below used to `return` with nothing sent back at all — not even a
    -- NotifyPlayer — leaving the client's just-created, just-attached vest
    -- object both untracked here and un-signalled that anything failed. See
    -- the TTL-expiry branch's own comment above for why sending
    -- 'qbx_k9unit:client:rejectK9PropAttach' here carries none of
    -- server/fetch.lua's netId-trust concerns.
    if not Config.Features.PropAttachments then
        -- Unreachable in current practice — nothing in this codebase ever
        -- reassigns Config.Features.PropAttachments at runtime (config.lua
        -- is a shared_scripts file, loaded once, synchronously, identically
        -- on both sides before either side's own code runs; verified no
        -- assignment to this field exists anywhere else in this resource).
        -- Kept as genuine defense-in-depth, same "layered checks over a
        -- single point of failure" posture this file's own REGISTRATION-
        -- TIME FEATURE GATE header already argues for — in case a future
        -- live-reconfiguration path ever makes this reachable.
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end
    if not HasK9Access(src) then
        NotifyPlayer(src, 'You are not authorized to use K9 equipment.', 'error')
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end
    if PropAttachmentState[citizenid] then
        -- No NotifyPlayer here deliberately: this citizenid already has a
        -- confirmed, active attachment on record (a race between two
        -- in-flight confirms) — that is the true, correct state, so an
        -- "attach failed" toast would be actively misleading. The cleanup
        -- event is still required: it targets THIS confirm's own
        -- just-created object (client/propattachment.lua's attachK9Prop
        -- handler sets `myVestEntity = obj` synchronously, before firing
        -- this very confirm), not the other, already-tracked one.
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end

    -- GetEntityType expectedEntityType = 3 (object) — see
    -- server/entities.lua's own ResolveNetworkEntity doc comment for the
    -- GetEntityType numbering.
    local entity = ResolveNetworkEntity(netId, 3)
    if not entity then
        NotifyPlayer(src, 'K9 vest attach failed — the object could not be confirmed.', 'error')
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end

    -- DEFENSE-IN-DEPTH MODEL CHECK — mirrors server/kennel.lua's own
    -- KennelModelHashes check on confirmKennelPlaced verbatim: confirms the
    -- reported entity is actually one of the two configured prop models,
    -- not an arbitrary pre-existing networked object a modified client
    -- could report instead of a genuinely newly-created vest.
    if not PropAttachmentModelHashes[GetEntityModel(entity)] then
        NotifyPlayer(src, 'K9 vest attach failed — unexpected object model.', 'error')
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end

    -- DEFENSE-IN-DEPTH POSITION CHECK — same role as server/kennel.lua's
    -- KENNEL_CONFIRM_DISTANCE_TOLERANCE, checked against the CALLER'S OWN
    -- live ped position (a moving attach point) rather than a fixed
    -- placement spot, since that's what this feature actually anchors to.
    -- This is what turns "a modified client reports an arbitrary
    -- pre-existing networked entity's netId" from "this file now tracks
    -- and will later DeleteEntity someone else's unrelated object" into a
    -- rejected confirm — a real object of the right model sitting far from
    -- the caller's own ped cannot be the vest this file just asked that
    -- caller's client to create.
    local pedCoords = GetEntityCoords(ped)
    local entityCoords = GetEntityCoords(entity)
    local dx = entityCoords.x - pedCoords.x
    local dy = entityCoords.y - pedCoords.y
    local dz = entityCoords.z - pedCoords.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > Config.PropAttachments.confirmDistanceTolerance then
        NotifyPlayer(src, 'K9 vest attach failed — reported object too far from you.', 'error')
        TriggerClientEvent('qbx_k9unit:client:rejectK9PropAttach', src)
        return
    end

    PropAttachmentState[citizenid] = { netId = netId, ownerSrc = src }
    NotifyPlayer(src, 'K9 vest attached.', 'success')
end)

--- Client reports its own attach attempt failed (model never loaded) —
--- frees the pending slot immediately. Mirrors server/kennel.lua's
--- 'qbx_k9unit:server:cancelKennelPlacement' exactly.
RegisterNetEvent('qbx_k9unit:server:cancelPropAttachRequest', function()
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local pending = PendingPropAttachConfirm[citizenid]
    if pending and pending.src == src then
        PendingPropAttachConfirm[citizenid] = nil
    end
end)

--- Self-report: "my own ped just died, and it currently owns an active
--- attachment." See this file's header event 4 for the full trust-category
--- reasoning (self-reported fact about the reporter's own state, same
--- category as server/tracking.lua's relayDamageEvent/relayWeaponFire).
--- Ownership is still re-verified below before anything is removed.
RegisterNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', function()
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local attachment = PropAttachmentState[citizenid]
    if not attachment or attachment.ownerSrc ~= src then
        return -- nothing to remove, or this source isn't the one holding it on record — ignore
    end

    RemovePropAttachmentForCitizenid(citizenid)
end)

-- Handler-disconnect cleanup (task requirement: an attached prop must not
-- leak permanently into the world). Resolves citizenid for the
-- disconnecting source BEFORE the framework fully tears down the player
-- object, same established pattern as server/kennel.lua's own
-- playerDropped handler.
AddEventHandler('playerDropped', function(_reason)
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    if PendingPropAttachConfirm[citizenid] and PendingPropAttachConfirm[citizenid].src == src then
        PendingPropAttachConfirm[citizenid] = nil
    end

    if PropAttachmentState[citizenid] and PropAttachmentState[citizenid].ownerSrc == src then
        RemovePropAttachmentForCitizenid(citizenid)
    end

    -- ToggleCooldown already registered its own playerDropped handler via
    -- :RegisterPlayerDropped() above — nothing to do for it here.
end)

-- Resource-stop cleanup (task requirement, same class of gap
-- client/vehicle.lua's own onResourceStop comment calls "ship-blocking" for
-- its own entity-state case): a resource restart must not leave any
-- currently-attached prop behind as a permanent, orphaned world object.
-- This pass is specifically for attachments whose ORIGINAL creating client
-- already disconnected earlier in the session — client/propattachment.lua's
-- own onResourceStop handler independently covers the (more common) case of
-- a still-connected client cleaning up its own creation.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, attachment in pairs(PropAttachmentState) do
        local entity = ResolveNetworkEntity(attachment.netId)
        if entity then
            DeleteEntity(entity)
        end
    end
    -- Deliberately NOT also broadcasting 'qbx_k9unit:client:removeK9PropAttachment'
    -- here — same reasoning as server/kennel.lua's own onResourceStop
    -- handler: every other client's copy of this resource is stopping at
    -- essentially the same time, making a broadcast from this handler
    -- unreliable busywork rather than a real backstop.
end)

-- ======================================================================
-- CONFIG-SAFETY GUARD — mirrors server/admin.lua's own onResourceStart
-- convention: Config.Features.PropAttachments already exists in config.lua
-- (still `false`), so no assert on the flag itself is needed here (a
-- missing/false flag is a normal, supported state, not a misconfiguration).
-- Once the flag IS `true`, Config.PropAttachments must exist with the exact
-- shape this file assumes, or this resource refuses to finish starting —
-- fail loudly on a genuine misconfiguration, once the operator has actually
-- opted in, never silently on an unrelated server that hasn't touched this
-- feature at all.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not (Config.Features and Config.Features.PropAttachments == true) then return end

    local cfg = Config.PropAttachments
    assert(type(cfg) == 'table', '[qbx_k9unit] Config.Features.PropAttachments is true but Config.PropAttachments is missing.')
    assert(type(cfg.propModel) == 'string' and cfg.propModel ~= '', '[qbx_k9unit] Config.PropAttachments.propModel must be a non-empty string.')
    assert(type(cfg.fallbackPropModel) == 'string' and cfg.fallbackPropModel ~= '', '[qbx_k9unit] Config.PropAttachments.fallbackPropModel must be a non-empty string.')
    assert(type(cfg.boneIndex) == 'number' and cfg.boneIndex >= 0, '[qbx_k9unit] Config.PropAttachments.boneIndex must be a number >= 0.')
    for _, key in ipairs({ 'offsetX', 'offsetY', 'offsetZ', 'rotX', 'rotY', 'rotZ' }) do
        assert(type(cfg[key]) == 'number', ('[qbx_k9unit] Config.PropAttachments.%s must be a number.'):format(key))
    end
    assert(type(cfg.toggleCooldownMs) == 'number' and cfg.toggleCooldownMs >= 0, '[qbx_k9unit] Config.PropAttachments.toggleCooldownMs must be a number >= 0.')
    assert(type(cfg.pendingConfirmTtlMs) == 'number' and cfg.pendingConfirmTtlMs > 0, '[qbx_k9unit] Config.PropAttachments.pendingConfirmTtlMs must be a positive number.')
    assert(type(cfg.confirmDistanceTolerance) == 'number' and cfg.confirmDistanceTolerance > 0, '[qbx_k9unit] Config.PropAttachments.confirmDistanceTolerance must be a positive number.')

    BuildPropAttachmentModelHashes()

    print('[qbx_k9unit] propattachment.lua: PropAttachments feature is enabled and config-validated.')
end)

end -- if Config.Features.PropAttachments -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
