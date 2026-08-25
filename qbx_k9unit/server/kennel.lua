--[[
    qbx_k9unit/server/kennel.lua

    Phase 5 R&D scaffold (coder-architect structural pass).
    Config.Features.DeployableKennel (phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research
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
       phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research §5's confirmed natives —
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
       instead of a genuine new kennel — including, in the worst case,
       ANOTHER citizen's already-confirmed kennel.

       RED-TEAM FIX, THIS PASS — CLOSES A LIVE, REPEATABLE GRIEFING
       PRIMITIVE: `safeToCleanup` below (computed once, immediately after
       the pending/src/TTL-eligible confirm is accepted, and reused by
       EVERY rejection branch that follows) mirrors server/fetch.lua's
       confirmFetchBallThrown/confirmFetchBallDropped `safeToCleanup`
       pattern exactly — see that file's own doc comment for the reasoning
       this is copied from. Previously, every rejection branch below either
       called a since-removed `CleanupUnclaimedKennelEntity` helper (TTL
       expiry, feature-flag toggle, certification revoke, already-has-a-
       kennel) or performed its own inline, unconditional `DeleteEntity`
       (the too-far-from-spawn branch) — EVERY one of those paths deleted
       whatever `netId` resolved to and model-matched, with NO check that
       the reporting citizenid actually owned it. Exploit: an attacker with
       K9 access calls requestDeployKennel (opens their own pending slot,
       creates nothing client-side), then calls confirmKennelPlaced naming
       a VICTIM's real, already-deployed kennel's netId. The entity
       resolves, the model matches (it's a real kennel), and landing on
       ANY rejection branch — already owning a kennel, letting the TTL
       expire, or simply placing far enough from the attacker's OWN spawn
       point to trip the too-far branch (no proximity to the victim's
       kennel required at all) — deleted the victim's real kennel and
       broadcast its removal to every connected client. Repeatable roughly
       every DeployCooldown interval.
       `safeToCleanup` requires the netId to (a) resolve to a real,
       currently-existing OBJECT, (b) match a configured kennel prop model,
       AND (c) NOT already be recorded against a DIFFERENT citizenid's
       `Kennels` entry (via `FindKennelOwnerByNetId` — the exact
       server/fetch.lua `FindOtherBallByNetId` shape, applied to this
       file's own registry). Condition (c) is what actually closes the
       exploit: a victim's real kennel is, by definition, already recorded
       in `Kennels` under the victim's own citizenid by the time an
       attacker could name its netId, so `safeToCleanup` is false for it —
       every rejection branch below now notifies the caller their placement
       failed WITHOUT deleting an entity they don't own. Kept from the
       prior pass unchanged: EVERY rejection branch still ALWAYS notifies
       the player (never silent), and — ONLY when `safeToCleanup` is true —
       still reclaims the real, genuinely-owned object rather than leaving
       it orphaned (the "no unbounded trap" requirement this feature is
       built to; see RemoveKennelForCitizenid's own note and the playerDropped/
       onResourceStop sweeps below, all independent of this check and all
       keyed off `Kennels`' own entries, never a client-supplied netId).
       The one deliberate exception, unchanged from before, is the
       wrong-model rejection (see that branch's own comment for why it
       stays a plain, non-cleanup-attempting rejection even though
       `safeToCleanup` would already be false for it anyway: at that point
       `entity` might not be the genuine kennel at all).

       CROSS-FEATURE GAP — CLOSED THIS PASS (coder-architect):
       `safeToCleanup`'s condition (c) above only ever cross-checked THIS
       file's own `Kennels` registry — it had no visibility into
       server/fetch.lua's private `FetchBalls`/`PendingFetchDrops` tables or
       server/propattachment.lua's own tracked attachments. Confirmed by
       reading config.lua: `Config.DeployableKennel.fallbackPropModel`,
       `Config.FetchMechanic.ballPropModel`, and
       `Config.PropAttachments.fallbackPropModel` are ALL configured as the
       identical `'prop_tennis_ball'` model — a real object of the right
       type, wearing the right (shared) model, but never recorded in
       `Kennels` at all, therefore used to read as `safeToCleanup == true`
       here. Worse, auditing this pass found the SAME shared-model blindness
       also let a foreign object be silently WRITTEN into `Kennels` on the
       plain SUCCESS path below (no rejection branch needed at all) — see
       the DEFENSE-IN-DEPTH pre-write check further down for that half of
       the fix.
       FIXED via server/entities.lua's new `IsNetworkEntityClaimedByOther`
       (a shared, resource-global "netId currently claimed by feature X"
       registry, exactly the shape this comment previously named as the
       needed-but-out-of-remit fix) — every one of this file's own
       `safeToCleanup` computations and pre-write uniqueness checks now
       additionally requires `not IsNetworkEntityClaimedByOther(netId,
       'kennel', citizenid)`, and every successful write/removal of a
       `Kennels` entry now calls `ClaimNetworkEntity`/`ReleaseNetworkEntity`
       so server/fetch.lua's and server/propattachment.lua's own equivalent
       checks can see THIS file's claims too. See that file's own header
       section for the full exploit writeup and why a shared table was
       chosen over retrofitting server/propattachment.lua's
       NetworkGetEntityOwner-based guard into this file instead. The
       existing `FindKennelOwnerByNetId` same-feature check is UNCHANGED and
       stays in place alongside the new cross-feature check, layered, not
       replaced.
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
    limitation phase2_notes/RESEARCH_ARCHIVE.md's native-reference tables
    already document elsewhere). The broadcast to 'qbx_k9unit:client:removeKennel' (-1)
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
    -- Releases this citizenid's claim on kennel.netId in the shared
    -- cross-feature registry (server/entities.lua) so the netId can be
    -- legitimately reused/reclaimed afterward without tripping
    -- IsNetworkEntityClaimedByOther for anyone else -- a no-op if this
    -- exact (feature, ownerId) pair never held the claim.
    ReleaseNetworkEntity(kennel.netId, 'kennel', citizenid)

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
        NotifyPlayer(src, locale('kennel.not_authorized_to_deploy'), 'error')
        return
    end

    if not DeployCooldown.Consume(src) then
        return -- silent no-op: rate-limited, matches bark/leash-request/certify-action convention
    end

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then
        NotifyPlayer(src, locale('common.unable_to_resolve_citizenid'), 'error')
        return
    end

    if Kennels[citizenid] then
        NotifyPlayer(src, locale('kennel.already_active_deployed'), 'error')
        return
    end

    if PendingKennelPlacements[citizenid] then
        NotifyPlayer(src, locale('kennel.placement_already_in_progress'), 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    local pedCoords = GetEntityCoords(ped)

    -- NOT GetEntityForwardVector(ped) — CONFIRMED BROKEN SERVER-SIDE, not just
    -- "probably client-only" per the native audit that flagged this. Verified
    -- this pass directly against the FXServer C++ source
    -- (citizenfx/fivem, code/components/citizen-server-impl/src/state/
    -- ServerGameState_Scripting.cpp): that file is the exhaustive list of
    -- GET_ENTITY_* natives FXServer registers a real server-side handler for
    -- (GET_ENTITY_COORDS, GET_ENTITY_HEADING, GET_ENTITY_MODEL, etc., all
    -- backed by the synced-entity sync tree) — GET_ENTITY_FORWARD_VECTOR is
    -- NOT among them, and does not appear anywhere else in that component or
    -- in ext/native-decls. Traced the actual dispatch path in
    -- citizen-scripting-core/src/ScriptInvoker.cpp: on the server build
    -- (IS_FXSERVER), a native with no registered fx handler resolves to
    -- `s_invalidNativeHandler`, a no-op lambda (`g_StrictTypeInfo` is a
    -- hardcoded `false` constant in that same file, so it never throws) —
    -- and the result buffer it's called with (`ScriptNativeContext`'s
    -- `results[4]`) is zero-initialized and never written. Net effect:
    -- calling this native server-side does not error, it silently returns
    -- vector3(0, 0, 0) every time, unconditionally. With that confirmed,
    -- `forward.x`/`forward.y` below would ALWAYS have been exactly 0 — not
    -- "occasionally wrong orientation" but a total no-op on
    -- placementForwardOffsetMeters, meaning every kennel would have spawned
    -- exactly on top of the placing handler's own feet, not in front of them.
    -- (server/fetch.lua's HandleThrowFetchItem has the identical
    -- GetEntityForwardVector(ped) call at its own line 345, with the same
    -- consequence for both its spawn offset AND its throw force — flagged to
    -- the file's owner separately since it's outside this file's ownership.)
    --
    -- Substitute: GetEntityHeading(ped) + the standard heading->direction
    -- trig conversion. GetEntityHeading IS in that same server-registered
    -- native list (GET_ENTITY_HEADING, ServerGameState_Scripting.cpp), and
    -- for a Ped it reads `entity->syncTree->GetPedOrientation()->
    -- currentHeading` — the identical sync-tree mechanism (same file, same
    -- pattern) that GET_ENTITY_COORDS itself reads position from, i.e. no
    -- less reliable server-side than the `pedCoords` line directly above,
    -- which this handler already trusts. The audit that flagged
    -- GetEntityForwardVector declined to substitute this, citing "reported
    -- reliability issues under some OneSync configs" for GetEntityHeading —
    -- that claim was NOT independently verified this pass (no live OneSync
    -- server was reachable to reproduce it against), so it is not being
    -- asserted as false. It is noted only that nothing in the FXServer
    -- source inspected this pass structurally distinguishes heading's
    -- reliability from coords', and a command a player triggers after
    -- already being connected and moving (this feature requires HasK9Access
    -- + being in-world) is well past the one theoretical edge case found
    -- (a ped whose orientation sync node has never yet populated, which
    -- would read back as heading 0 — same zero-conf failure class as coords
    -- would have for a brand-new, not-yet-synced entity, not unique to
    -- heading). Confidence: HIGH that this is strictly better than the
    -- previous native (which was 100% broken, always 0,0,0); MEDIUM on
    -- heading's real-world precision under heavy network jitter, not
    -- independently re-measured in this pass.
    local heading = GetEntityHeading(ped)
    local headingRad = math.rad(heading)
    local forward = { x = -math.sin(headingRad), y = math.cos(headingRad) }
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

--- Enforces "at most one `Kennels` entry may ever claim a given netId" —
--- mirrors server/fetch.lua's `FindOtherBallByNetId` exactly (see that
--- function's own doc comment for the fuller GLOBAL NETID-UNIQUENESS
--- INVARIANT framing), applied to this file's own `Kennels` registry.
--- Returns the citizenid of a DIFFERENT registry entry that already claims
--- `netId`, if one exists — `excludeCitizenId` lets a caller checking its
--- OWN citizenid's prospective claim not treat its own prior entry (if any)
--- as a collision.
---
--- SECURITY-CRITICAL, RED-TEAM FIX THIS PASS: every decision about whether
--- a client-reported netId is SAFE TO DELETE, and every write of a
--- client-reported netId into `Kennels`, MUST be guarded by this returning
--- nil first — see confirmKennelPlaced's own `safeToCleanup` below (this
--- file's header EVENT/CALLBACK CONTRACT item 2 has the full writeup of the
--- griefing primitive this closes: previously, confirmKennelPlaced's
--- rejection branches deleted whatever a client-reported netId resolved to
--- and model-matched, with NO check that the reporting citizenid actually
--- owned it — an attacker naming a victim's real, already-confirmed
--- kennel's netId on a call engineered to land on any rejection branch
--- could delete it out from under them). Do not remove this check from
--- confirmKennelPlaced without replacing it with an equally strict
--- alternative.
--- @param netId number
--- @param excludeCitizenId string?
--- @return string? otherCitizenId
local function FindKennelOwnerByNetId(netId, excludeCitizenId)
    for citizenid, kennel in pairs(Kennels) do
        if citizenid ~= excludeCitizenId and kennel.netId == netId then
            return citizenid
        end
    end
    return nil
end

--- Step 2: client reports the network id of the object it actually
--- created. Re-validates everything from step 1 plus the entity itself —
--- see this file's header EVENT/CALLBACK CONTRACT item 2 for the full
--- reasoning, INCLUDING the red-team fix documented there this pass
--- (`safeToCleanup` below).
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

    -- REFACTOR_ROADMAP.md item 2 (Revision 5 migration): was this file's
    -- own `NetworkDoesEntityExistWithNetworkId` existence guard followed by
    -- a SEPARATE `GetEntityType(entity) ~= 3` check further down — both
    -- are now server/entities.lua's shared ResolveNetworkEntity(), called
    -- with expectedEntityType = 3 to fold the object-only restriction in
    -- as one call, mirroring server/main.lua's relayDoorScratch exactly.
    --
    -- SECURITY-CRITICAL, RED-TEAM FIX THIS PASS: resolved HERE, immediately
    -- after the pending/src match is confirmed, and reused by EVERY branch
    -- below (never re-resolved) — mirrors server/fetch.lua's
    -- confirmFetchBallThrown `entity`/`safeToCleanup` placement exactly.
    -- `safeToCleanup` is the ONLY thing any rejection branch below consults
    -- before touching this entity: it is NOT simply "did the netId resolve
    -- to a real, correctly-modeled object" — it additionally requires the
    -- netId to NOT already be recorded against a DIFFERENT citizenid's
    -- `Kennels` entry (`FindKennelOwnerByNetId`). That third condition is
    -- the one that actually matters: without it, an attacker could report
    -- ANOTHER citizen's real, already-confirmed kennel's netId, deliberately
    -- land on a rejection branch (already own a kennel, let the TTL expire,
    -- or place far enough from their OWN spawn point to trip the too-far
    -- branch below), and this handler would delete that OTHER citizen's
    -- kennel via THIS caller's own confirm — see this file's header EVENT/
    -- CALLBACK CONTRACT item 2 for the full griefing-primitive writeup this
    -- closes. Every branch that independently re-reaches the identical
    -- cross-citizenid collision case (the DEFENSE-IN-DEPTH check further
    -- down, before the success write) gets `safeToCleanup == false` for
    -- free from this same check.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass): `FindKennelOwnerByNetId`
    -- alone only ever catches a collision against ANOTHER `Kennels` entry --
    -- it has no visibility into server/fetch.lua's `FetchBalls` or
    -- server/propattachment.lua's `PropAttachmentState`, both of which share
    -- this exact prop model with `Kennels` per config.lua (see this file's
    -- header CROSS-FEATURE GAP section). `IsNetworkEntityClaimedByOther`
    -- (server/entities.lua) closes that: it is false only when `netId` is
    -- either unclaimed anywhere, or already claimed by THIS citizenid's own
    -- kennel -- never when it names a genuinely different feature's or
    -- citizen's real, live object.
    --
    -- PRE-CONFIRMATION-WINDOW FIX (coder-architect, urgent red-team finding
    -- this pass): neither `FindKennelOwnerByNetId` NOR
    -- `IsNetworkEntityClaimedByOther` can catch a netId BEFORE its genuine
    -- owner's own confirm has ever reached this server -- both registries
    -- are only ever written at the moment a confirm SUCCEEDS. A victim's
    -- client CreateObject()s a real, networked entity, then still has to run
    -- PlaceObjectOnGroundProperly/FreezeEntityPosition/
    -- NetworkGetNetworkIdFromEntity before it ever calls
    -- confirmKennelPlaced -- OneSync can (and, per this codebase's own
    -- FIRST-WRITER-WINS PROP-HIJACK RACE finding in
    -- server/propattachment.lua, often does) replicate that entity to a
    -- nearby attacker FASTER than the victim's own multi-step client
    -- sequence finishes. An attacker with their own pending slot already
    -- open (never having created anything real) can read that netId off the
    -- wire and confirm it before the victim does -- landing on either a
    -- rejection branch (deleting the victim's real kennel with
    -- `safeToCleanup` reading true, since NOTHING has claimed it yet) or, if
    -- the attacker's own pending coords happen to be within
    -- KENNEL_CONFIRM_DISTANCE_TOLERANCE of the victim's real object (two
    -- handlers deploying near the same station, which this file's own
    -- header already treats as an ordinary case), the plain SUCCESS path --
    -- outright theft: `Kennels[attacker] = victim's real object`.
    -- FIXED the same way server/propattachment.lua's own NETWORK-OWNERSHIP
    -- GUARD closes the identical shape of race for that file (see that
    -- file's own header FIRST-WRITER-WINS PROP-HIJACK RACE section for the
    -- full trace this mirrors): `NetworkGetEntityOwner(entity) == src` asks
    -- the one question a registry populated only-on-confirm structurally
    -- cannot answer -- is `src` the reported entity's CURRENT OneSync
    -- network owner RIGHT NOW, independent of whether anyone has confirmed
    -- anything yet. A networked object is owned, at creation, by the client
    -- that created it (client/kennel.lua's own CreateObject call) -- never
    -- by a merely-nearby OTHER client, no matter how quickly that other
    -- client reacts. NetworkGetEntityOwner is verified server-callable
    -- (`.luacheckrc`'s own read_globals entry: apiset `shared`, same
    -- verification propattachment.lua's own guard already relies on).
    -- Layered ALONGSIDE the existing checks below, not instead of them --
    -- see this function's own RejectPlacement for why a non-owner's
    -- rejection must still notify but never delete.
    local entity = ResolveNetworkEntity(netId, 3)
    local safeToCleanup = entity ~= nil
        and KennelModelHashes[GetEntityModel(entity)]
        and NetworkGetEntityOwner(entity) == src
        and not FindKennelOwnerByNetId(netId, citizenid)
        and not IsNetworkEntityClaimedByOther(netId, 'kennel', citizenid)

    --- Notifies `src` their placement was rejected and, ONLY if
    --- `safeToCleanup` says this citizenid genuinely owns the resolved
    --- entity, reclaims it (direct server-side DeleteEntity attempt plus
    --- the broadcast backstop — see RemoveKennelForCitizenid's own CLEANUP
    --- CONFIDENCE NOTE in this file's header for why both). Shared by every
    --- rejection branch below that is reachable only once the client has
    --- already created a real networked object in response to event 5 (TTL
    --- expiry, a feature-flag toggle or certification revoke landing
    --- mid-flight, a race with another kennel already occupying the
    --- citizenid's slot, or placing too far from the assigned spot) so
    --- there is exactly one place that decides "is it actually safe to
    --- delete this" — never re-derived, and never skipped, per branch.
    --- @param message string
    local function RejectPlacement(message)
        NotifyPlayer(src, message, 'error')
        if safeToCleanup then
            DeleteEntity(entity)
            TriggerClientEvent('qbx_k9unit:client:removeKennel', -1, netId)
        end
    end

    if GetGameTimer() > pending.expiresAt then
        RejectPlacement(locale('kennel.placement_timed_out'))
        return
    end

    -- Re-validate — a certification revoke, a feature-flag toggle, or
    -- (shouldn't be reachable, but never trust an invariant alone) a
    -- second kennel landing could have happened during the round trip. A
    -- rejection this deep in the flow (past the pending/src/TTL checks
    -- above) is never an unsolicited or forged confirm — it's a genuine
    -- client honestly reporting a placement it was just instructed to make,
    -- so the player is always told, and — only when `safeToCleanup` says
    -- it is genuinely this citizenid's own object — it is always reclaimed.
    if not Config.Features.DeployableKennel then
        RejectPlacement(locale('kennel.placement_failed_unconfirmed'))
        return
    end
    if not HasK9Access(src) then
        RejectPlacement(locale('kennel.placement_failed_unconfirmed'))
        return
    end
    if Kennels[citizenid] then
        RejectPlacement(locale('kennel.placement_failed_unconfirmed'))
        return
    end

    -- DISCLOSED, NOT SILENT, MESSAGE-WORDING CHANGE: before the
    -- ResolveNetworkEntity migration, an entity that existed but had the
    -- wrong GetEntityType got its own distinct "unexpected entity type"
    -- notification, separate from the "could not be confirmed" wording used
    -- for a nonexistent entity. Folding both into one
    -- ResolveNetworkEntity(netId, 3) call means both cases share the "could
    -- not be confirmed" message below — the REJECTION itself is unchanged
    -- (both cases still fail closed), only the player-facing wording for
    -- the wrong-type case is less specific. Nothing to clean up either way
    -- (there was never a real, correctly-typed entity to resolve), so this
    -- stays a plain notify, not routed through RejectPlacement.
    if not entity then
        NotifyPlayer(src, locale('kennel.placement_failed_unconfirmed'), 'error')
        return
    end

    -- Defense-in-depth (relayDoorScratch precedent, server/main.lua):
    -- confirm the reported entity is actually one of the two configured
    -- kennel prop models, not an arbitrary pre-existing networked object a
    -- modified client could report instead of a genuine new kennel.
    if not KennelModelHashes[GetEntityModel(entity)] then
        -- DELIBERATELY NOT deleting `entity` here, even though this file's
        -- other rejection branches DO (via RejectPlacement, when
        -- `safeToCleanup` allows it). This is the one branch where `entity`
        -- might NOT be the kennel the client actually created at all — it's
        -- exactly the "modified client reports an arbitrary pre-existing
        -- networked entity's id instead" case this check exists to catch
        -- (see this file's header EVENT/CALLBACK CONTRACT item 2).
        -- `safeToCleanup` is already false here regardless (it requires the
        -- identical model match), so routing this through RejectPlacement
        -- would behave identically — but this branch stays a deliberately
        -- separate, plain, non-cleanup-attempting rejection anyway: calling
        -- any cleanup-capable path here, even one that happens to be a
        -- no-op today, would reintroduce the exact arbitrary-entity-deletion
        -- shape this whole model-check exists to prevent should that
        -- invariant ever change underneath it. Fail closed: refuse to
        -- track it, touch nothing else.
        NotifyPlayer(src, locale('kennel.placement_failed_wrong_model'), 'error')
        return
    end

    local entityCoords = GetEntityCoords(entity)
    local dx = entityCoords.x - pending.coords.x
    local dy = entityCoords.y - pending.coords.y
    local dz = entityCoords.z - pending.coords.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > KENNEL_CONFIRM_DISTANCE_TOLERANCE then
        -- `entity` has already passed the object-type check
        -- (ResolveNetworkEntity's expectedEntityType = 3), the
        -- KennelModelHashes model check above, AND (via `safeToCleanup`)
        -- the cross-citizenid ownership check — by this point it is
        -- credibly THIS citizenid's own genuine kennel prop, just placed
        -- somewhere the ground-snap moved too far from it. Reachable
        -- WITHOUT any proximity to another citizen's kennel at all (this
        -- citizenid's own pending.coords is all that's compared against),
        -- so — unlike before this pass — this can never be used to delete
        -- an entity `safeToCleanup` doesn't already vouch for. Cleaned up
        -- via RejectPlacement rather than leaving this real, frozen,
        -- now-permanently-untracked object sitting in the world forever
        -- (it never enters `Kennels`, so RemoveKennelForCitizenid, the
        -- playerDropped handler, and the onResourceStop sweep would never
        -- otherwise see it) — the exact "every placed kennel must always be
        -- removable" requirement this feature is built to.
        RejectPlacement(locale('kennel.placement_failed_too_far'))
        return
    end

    -- NETWORK-OWNERSHIP GUARD (coder-architect, urgent red-team finding this
    -- pass — mirrors server/propattachment.lua's own guard, see
    -- `safeToCleanup`'s own comment above for the full PRE-CONFIRMATION-
    -- WINDOW trace). Model, type, and distance can ALL be satisfied by an
    -- attacker naming a DIFFERENT, still-unconfirmed citizen's real kennel —
    -- distance in particular is trivially satisfiable whenever two certified
    -- handlers deploy near the same station (this file's own DEFENSE-IN-
    -- DEPTH comment immediately below already calls that an ordinary case).
    -- Without this, THAT is the outright-theft shape this finding described:
    -- `FindKennelOwnerByNetId`/`IsNetworkEntityClaimedByOther` both read
    -- "unclaimed" for an object nobody has successfully confirmed yet, so
    -- the write below would otherwise proceed, registering the VICTIM's
    -- real, live object as the ATTACKER's own kennel. `safeToCleanup`
    -- already reads false here for a non-owner (see above), so routing this
    -- through RejectPlacement is safe by construction: notifies, attempts no
    -- delete.
    if NetworkGetEntityOwner(entity) ~= src then
        RejectPlacement(locale('kennel.placement_failed_unconfirmed'))
        return
    end

    -- DEFENSE-IN-DEPTH: reject if this exact netId is already recorded as a
    -- DIFFERENT citizenid's active kennel. Without this, a modified client
    -- could exploit the distance tolerance above (reachable whenever two
    -- certified handlers place within KENNEL_CONFIRM_DISTANCE_TOLERANCE of
    -- each other, e.g. side by side at the same station) to report someone
    -- else's already-confirmed kennel's netId as its own new placement.
    -- Kennels[citizenid] would then point at an entity a DIFFERENT
    -- citizenid's entry ALSO still points at — the first of the two to pick
    -- theirs up (or disconnect) DeleteEntity's the shared entity out from
    -- under the other, whose own registry slot is left referencing a netId
    -- that no longer resolves to anything. RemoveKennelForCitizenid's
    -- ResolveNetworkEntity call on that stale netId then simply finds
    -- nothing and returns without ever clearing their Kennels slot — an
    -- unbounded trap (this feature's own explicit "always removable by its
    -- owner" requirement): they can never place a new kennel again ("you
    -- already have an active kennel deployed") and have nothing left in the
    -- world to pick up to clear it.
    -- Re-runs FindKennelOwnerByNetId explicitly here (rather than only
    -- trusting `safeToCleanup`'s earlier snapshot) for the same reason
    -- server/fetch.lua's confirmFetchBallThrown re-runs FindOtherBallByNetId
    -- a second time before its own success write: `citizenid` is confirmed
    -- above to have no `Kennels` entry of its own yet, so any hit here is
    -- necessarily a genuine cross-citizenid collision, and this is the
    -- gate that actually decides whether to WRITE `Kennels[citizenid]`, a
    -- distinct concern from `safeToCleanup` deciding whether to DELETE.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass) — THE MORE SEVERE HALF
    -- of this pass's fix, found auditing this exact gate: `FindKennelOwnerByNetId`
    -- alone only rejects a netId already sitting in `Kennels` -- a netId
    -- naming another citizen's REAL, LIVE server/fetch.lua ball or
    -- server/propattachment.lua vest (never in `Kennels` at all, sharing
    -- this exact model per config.lua) sailed straight through this gate
    -- and got WRITTEN into `Kennels[citizenid]` below as if it were this
    -- citizenid's own genuine kennel -- no rejection branch needed at all.
    -- The attacker's own very next requestPickupKennel (a clean, ordinary,
    -- already-audited call) would then delete the victim's real fetch
    -- ball/vest via THIS file's own RemoveKennelForCitizenid. Closed the
    -- same way as `safeToCleanup` above: `IsNetworkEntityClaimedByOther`
    -- (server/entities.lua) additionally guards this write.
    local otherCitizenid = FindKennelOwnerByNetId(netId, citizenid)
    if otherCitizenid or IsNetworkEntityClaimedByOther(netId, 'kennel', citizenid) then
        NotifyPlayer(src, locale('kennel.placement_failed_already_claimed'), 'error')
        return
    end

    Kennels[citizenid] = {
        netId = netId,
        ownerSrc = src,
        createdAt = GetGameTimer(),
    }
    -- Records this claim in the shared cross-feature registry so
    -- server/fetch.lua's and server/propattachment.lua's own equivalent
    -- checks can see it too -- see server/entities.lua's own header section.
    ClaimNetworkEntity(netId, 'kennel', citizenid)

    NotifyPlayer(src, locale('kennel.deployed_success'), 'success')
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
        NotifyPlayer(src, locale('kennel.not_owner'), 'error')
        return
    end

    RemoveKennelForCitizenid(citizenid)
    NotifyPlayer(src, locale('kennel.picked_up_success'), 'success')
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
