--[[
    qbx_k9unit/server/kennel.lua

    Phase 5 R&D scaffold (coder-architect structural pass).
    Config.Features.DeployableKennel (DEVELOPER_REFERENCE.md#phase-5-research
    §5): "a certified handler can place a world object (the kennel prop)
    near themselves... server-authoritative validation (proximity,
    certification, one-per-handler limit), with cleanup on resource stop/
    handler disconnect."

    NEW FILE PAIR (this file + client/kennel.lua), not folded into
    server/main.lua or server/certifications.lua — same "one responsibility
    per file, don't let it balloon into an everything-file" convention
    those two files' own headers already establish. DEVELOPER_REFERENCE.md's own
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

    ======================================================================
    K9-CAN-RIDE-ALONG PASS — CRITICAL SAFETY REDESIGN (this pass). Owner's
    own words, verbatim, restated in ALL CAPS after an earlier version of
    this pass shipped a weaker "pick up = delete the kennel, evict the K9"
    design: "the kennel should allow the K9 IN the cage AND the cage to be
    carried" — "the dog is IN the cage and the handler picks the cage up
    WITH THE DOG STILL IN IT... attached prop, occupant attached to the
    prop, both moving with the handler." A second, separate correction
    then added: "Ensure its the k9 player that gets put in the cage not a
    spawned in dog" — the occupant is ALWAYS a real, currently-connected
    player's own ped (resolved via GetPlayerPed(src) here, PlayerPedId() on
    that player's own client — see client/kennel.lua's own matching
    header note), NEVER a CreatePed/NPC stand-in. Confirmed explicitly in
    this file's own report: nothing in this file ever calls CreatePed.

    THE ARCHITECTURE THIS REQUIRES, AND WHY: a design that deletes the real
    kennel object at pickup time (this pass's own FIRST draft) is
    structurally incompatible with "the occupant rides along inside it" —
    deleting an object a currently-connected player's own ped is attached
    to is exactly the "player permanently trapped inside a deleted prop"
    failure DEVELOPER_REFERENCE.md and this file's own header both treat as
    the single worst outcome this feature could ship. FIXED by making the
    ONE, SAME, real networked kennel object survive its ENTIRE
    deploy -> carry -> put-down -> carry -> ... lifecycle: `Kennels[citizenid]`
    (this file's pre-existing registry) is NEVER cleared by an ordinary
    pickup anymore — only a genuine, occupant-free, carrier-free removal
    (disconnect with nobody using it, an explicit future admin action) ever
    clears it (see RemoveKennelForCitizenid's own new structural guard
    below). Picking a kennel up now means "attach the SAME real object to
    my own hands" (client/kennel.lua's client-side half, using
    client/propattachment.lua's precedent AttachEntityToEntity call shape
    reused, not reimplemented); putting it down means "detach it and place
    it at a freshly server-computed spot" (ComputeForwardSpawnPoint below,
    shared with the ordinary deploy flow). An occupant's own ped is
    attached directly to the KENNEL OBJECT ITSELF (never to the handler,
    never driven by the handler's own client — see "NETWORK OWNERSHIP /
    NO CROSS-PED DRIVING" below) — when the kennel is re-parented onto a
    handler's hands, the occupant comes along for free via the game's own
    transitive attachment hierarchy (a grandchild follows its parent's
    parent), with zero additional code needed on either client to make the
    two move together.

    NETWORK OWNERSHIP / NO CROSS-PED DRIVING (owner's own explicit
    instruction, this pass): "Positioning is done to that player's own ped,
    on their own client, with the server as the authority on whether the
    entry was allowed. Do not try to drive another player's ped from the
    handler's client." THIS FILE never touches an occupant's ped at all —
    requestEnterKennel below only ever validates the REQUESTING player's
    OWN citizenid/ped/access and, on success, instructs THAT SAME client
    (client/kennel.lua's enterKennelConfirmed handler) to attach ITS OWN
    ped to the kennel. The HANDLER's client, symmetrically, only ever
    attaches the KENNEL OBJECT (never the occupant's ped) to itself.
    client/combat.lua's own, extensively verified NETWORK OWNERSHIP OF THE
    TARGET PED section is the precedent this mirrors for the one
    cross-ownership attach this design DOES need (the handler's client
    attaching a kennel object it does not necessarily already own network
    control of to itself) — that file's own header documents
    NetworkRequestControlOfEntity as a best-effort, fire-and-forget request
    (never a blocking wait) preceding the attach; client/kennel.lua's own
    header cites the exact same precedent for its carry logic rather than
    inventing a new pattern.

    OCCUPANT HAS ITS OWN LIVE CLIENT (owner's own explicit instruction,
    this pass): "They see the world from inside the cage, they can press
    keys, they can open the tablet, they can disconnect." Every exit path
    below (requestExitKennel, playerDropped's occupant-disconnect branch,
    and — independent of anything server-side — client/kennel.lua's own
    unconditional local self-release on death/wander/entity-loss/resource-
    stop) is written against that reality: the occupant is never treated as
    a passive, handler-controlled passenger anywhere in this file.

    NEVER DELETE AN OCCUPIED OR CARRIED KENNEL — the one invariant this
    entire redesign exists to enforce, enforced STRUCTURALLY inside
    RemoveKennelForCitizenid itself (not merely as a discipline every
    caller happens to follow) — see that function's own doc comment.
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
       DEVELOPER_REFERENCE.md#phase-5-research §5's confirmed natives —
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
       ANOTHER citizen's already-confirmed kennel. See this file's own
       extensive in-body comments on `safeToCleanup` for the full
       red-team history of this handler; unchanged by this pass.
    3. 'qbx_k9unit:server:cancelKennelPlacement' () [THIS FILE]
       Client reports its own placement attempt failed (model never
       loaded, PlaceObjectOnGroundProperly returned false) so the pending
       slot frees up immediately instead of sitting until its TTL expires.
    4. 'qbx_k9unit:server:requestPickupKennel' (netId: number) [THIS FILE]
       REWORKED THIS PASS (see the header section above): no longer
       deletes anything. The RECORDED OWNER's own pickup remains instant
       and ungated (unchanged, existing behavior, still pinned by this
       file's own tests); a DIFFERENT certified handler picking up
       someone else's kennel is a new, real capability grant this pass
       adds ("the handler [not just the deploying owner] can pick it
       up") — gated on HasK9Access + genuine registry membership for the
       claimed netId + live proximity, exactly the discipline every other
       action-on-another-citizen's-object in this file already applies.
       On success, instructs the picker's own client to attach the SAME,
       still-real, still-registered object to their own hands (event 9)
       — an occupant riding inside, if any, comes along automatically via
       the game's own attachment hierarchy; nothing here treats that as a
       special case to handle.
    5'. 'qbx_k9unit:server:requestPutDownKennel' () [THIS FILE] NEW.
       Carrier's own "set it back down" action — self-only, looks up
       CarriedKennels[citizenid] rather than trusting a client-supplied
       netId, mirroring requestExitKennel's/cancelKennelPlacement's own
       established "never trust a client-claimed identity for its own
       state" discipline. Computes a fresh drop point the SAME way
       requestDeployKennel computes a spawn point (ComputeForwardSpawnPoint,
       shared), then instructs that SAME client to detach + reposition +
       re-freeze the SAME object (event 10) — never creates a new object,
       never destroys the existing one.
    6'. 'qbx_k9unit:server:requestEnterKennel' (netId: number) [THIS FILE]
       NEW. A real, currently-connected player's own K9-modeled-or-role-
       holding, access-holding ped asks to attach itself to a specific,
       currently-deployed (not mid-carry), currently-unoccupied kennel
       within range. Re-validates everything client-side visibility
       already implied (this file's own established "canInteract is a UX
       convenience, never the boundary" standard) — the requesting
       player's own live ped position, never a client-claimed one.
    7'. 'qbx_k9unit:server:requestExitKennel' () [THIS FILE] NEW.
       The occupant's own, ALWAYS-AVAILABLE self-service exit — see the
       header CRITICAL SAFETY section. NEVER gated on
       Config.Features.DeployableKennel, HasK9Access,
       IsDeployableKennelPermittedForCitizenId, or any cooldown, and never
       dependent on the handler, the kennel's carried/deployed state, or
       anything else outside the occupant's own citizenid. Purely a
       registry-bookkeeping clear — client/kennel.lua's own client
       ALREADY released itself locally, unconditionally, before this event
       is even sent; this handler's only job is freeing the registry so
       the kennel is not misreported as occupied to a future caller.

    Client events (RegisterNetEvent, server->client):
    8. 'qbx_k9unit:client:deployKennelAt' (x: number, y: number, z: number)
       [client/kennel.lua] — an instruction, not a request; see the "WHY
       THE SERVER COMPUTES" block above. Sent as three plain numbers
       rather than a vector3 — this resource has no existing precedent for
       putting a vector3 value on the wire, and three numbers is
       unambiguous either way.
    9. 'qbx_k9unit:client:removeKennel' (netId: number) [client/kennel.lua]
       Broadcast (-1) cleanup backstop — see the CONFIDENCE NOTE on
       RemoveKennelForCitizenid below. Reachable far less often now that
       pickup no longer deletes anything (the only remaining
       RemoveKennelForCitizenid caller is playerDropped's owner-disconnect
       branch, itself now refused whenever occupied/carried) — kept
       unchanged as a genuine backstop for the cases that remain (an
       owner-only, never-occupied-or-carried kennel's disconnect cleanup;
       confirmKennelPlaced's own pre-confirm orphan cleanup, which can
       never have an occupant by construction).
    9'. 'qbx_k9unit:client:pickupKennelConfirmed' (netId: number)
       [client/kennel.lua] NEW. Instructs the picker's own client to
       NetworkRequestControlOfEntity + AttachEntityToEntity the SAME real
       object onto their own hands (client/propattachment.lua's
       AttachPropToOwnPed is NOT reused here — that helper always
       CreateObjects a brand new prop, which is exactly what this design
       must not do; see client/kennel.lua's own header for the small,
       dedicated attach call this event drives instead).
    10. 'qbx_k9unit:client:putDownKennelAt' (netId: number, x: number,
        y: number, z: number) [client/kennel.lua] NEW. Instructs the
        carrying client to detach, reposition, and re-freeze the SAME
        object — the mirror image of event 8, applied to an
        already-existing object instead of a freshly created one.
    11. 'qbx_k9unit:client:enterKennelConfirmed' (netId: number)
        [client/kennel.lua] NEW. Instructs the requesting K9's own client
        to attach its OWN ped to the kennel — see the header NETWORK
        OWNERSHIP section for why this file never attempts this itself.
    12. 'qbx_k9unit:client:kennelCarrierLost' (netId: number)
        [client/kennel.lua] NEW. Broadcast (-1) safety-net for a carrier
        disconnecting mid-carry (see playerDropped's own new branch below)
        — whichever connected client currently has this object streamed
        in detaches it from its now-gone carrier and freezes it in place,
        rather than leaving it attached to a ped handle that no longer
        exists. Deliberately never touches KennelOccupants or notifies an
        occupant to do anything — an occupant riding inside is completely
        unaffected by who is or isn't carrying the object it is itself
        attached to (see the header architecture section).

    Commands: '/k9deploykennel' lives in client/kennel.lua, not here — this
    is a self-administered action (the handler acts on themselves), which
    in this resource is always triggered from a client-side entry point
    calling a client-side global (see client/vehicle.lua's
    EnterNearestK9Vehicle/ExitK9Vehicle), unlike certify/revoke (which act
    ON another player and so live alongside their own server-side handlers
    in server/certifications.lua). THIS PASS: that same command now ALSO
    means "put down whatever I'm currently carrying" when the requesting
    client is in that state — see client/kennel.lua's own RequestDeployKennel
    doc comment for why one entry point correctly serves both meanings
    (client/radial.lua's existing "Deploy Kennel" radial item, which already
    calls this exact function, needed no changes to gain this for free).
    No NEW command/'RegisterCommand' name is introduced by this pass —
    tests/commandreferenceregistry_spec.lua's drift guard cross-checks
    every real RegisterCommand name against html/tablet.js's own
    COMMAND_REFERENCE list, and html/tablet.js is outside this pass's file
    ownership; adding a brand-new command here would need a matching entry
    added there in the SAME change by whoever owns that file.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, exposed by
      server/certifications.lua — do not re-derive the job/cert check here.
    - THIS FILE calls `IsConfiguredK9Model(modelHash)`, exposed by
      server/certifications.lua, and the soft dependency `HasK9Role(source)`
      (server/appearance.lua, guarded by `type(HasK9Role) == 'function'`) —
      see ResolveK9PedForKennelRest below, which mirrors
      server/wellbeing.lua's own ResolveK9Ped shape exactly (that function's
      own header has the full access-bypass-fix writeup this copies; not
      re-derived here, a second, small application of the SAME already-
      exported primitives).
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)`,
      exposed by server/entities.lua (DEVELOPER_REFERENCE.md item 2) — do not
      re-implement the resolve/existence-guard sequence here.
    - THIS FILE owns `Kennels` (citizenid -> { netId, ownerSrc, createdAt }),
      `PendingKennelPlacements` (citizenid -> { src, coords, expiresAt }),
      `KennelOccupants` (citizenid -> { netId, enteredSrc, enteredAt }), and
      `CarriedKennels` (citizenid -> { netId, ownerCitizenId, carrierSrc,
      startedAt }), all local to this file. Nothing outside this file reads
      them directly.
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
         DEVELOPER_REFERENCE.md/the Phase 5 research doc never define for
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
    doesn't exist. UNCHANGED by this pass: an owner whose kennel is
    currently out being carried, or currently occupied, STILL cannot
    deploy a second one — `Kennels[citizenid]` stays populated for the
    object's entire deploy -> carry -> put-down lifecycle, exactly as
    before this pass, just for a longer, more eventful lifetime than a
    simple "deployed until picked up" one.

    CLEANUP CONFIDENCE NOTE: RemoveKennelForCitizenid below attempts a
    direct server-side `DeleteEntity` on the resolved network entity.
    Deleting a networked mission entity from the SERVER side is an
    established, widely-used FiveM/OneSync pattern (e.g. server-side
    vehicle-impound/despawn scripts across the ecosystem routinely call
    `DeleteEntity` on a server-resolved vehicle) — used here with
    medium-high confidence per that convention, but NOT independently
    re-verified against this exact FXServer version's native behavior this
    session (no live server was reachable to test against, same sandbox
    limitation DEVELOPER_REFERENCE.md's native-reference tables
    already document elsewhere). The broadcast to 'qbx_k9unit:client:removeKennel' (-1)
    immediately below it is a deliberate backstop, not redundant
    belt-and-suspenders for its own sake: if server-side DeleteEntity turns
    out to be a no-op in a given FXServer build, whichever CONNECTED client
    currently holds real network ownership of that entity (OneSync migrates
    ownership among connected clients as the original owner streams out or
    disconnects) still receives the broadcast and deletes it locally,
    closing the gap without needing to know which client that is. THIS
    PASS: only ever reached for a kennel RemoveKennelForCitizenid's own new
    structural guard has already confirmed has no occupant and no carrier —
    see that function's own doc comment.
]]

-- Kennels[citizenid] = { netId: number, ownerSrc: number, createdAt: number }
-- At most one entry per citizenid — see this file's header for the
-- one-kennel-per-handler reasoning. Local: nothing outside this file
-- should read it directly. THIS PASS: survives an ordinary pickup/carry/
-- put-down cycle unchanged — see this file's header architecture section.
local Kennels = {}

-- PendingKennelPlacements[citizenid] = { src: number, coords: {x,y,z},
-- expiresAt: number } — mirrors server/main.lua's PendingLeashRequests
-- shape (a request awaiting a client-side follow-up action, with a TTL so
-- an unanswered one doesn't linger forever). Local: nothing outside this
-- file should read it directly.
local PendingKennelPlacements = {}

-- KennelOccupants[occupantCitizenId] = { netId: number, enteredSrc: number,
-- enteredAt: number } — this pass. At most one entry per occupant
-- citizenid (a K9 can only be resting in one place). Independent of, and
-- never conflated with, `Kennels` (which tracks the DEPLOYING owner) or
-- `CarriedKennels` (which tracks whoever is currently HOLDING the object)
-- — three separate roles a citizenid can independently occupy with
-- respect to the very same netId (a handler can own a kennel, a different
-- handler can be carrying it, and a K9 can be resting inside it, all at
-- once). Local: nothing outside this file should read it directly.
local KennelOccupants = {}

-- CarriedKennels[carrierCitizenId] = { netId: number, ownerCitizenId:
-- string, carrierSrc: number, startedAt: number } — this pass. At most one
-- entry per carrier citizenid (you cannot carry two kennels at once). See
-- KennelOccupants' own comment above for how this relates to the other two
-- registries. Local: nothing outside this file should read it directly.
local CarriedKennels = {}

--- Mirrors FindKennelOwnerByNetId's exact shape (defined further below,
--- kept as this file's own established "is some OTHER citizenid's registry
--- entry already claiming this netId" pattern) — applied to
--- KennelOccupants instead of Kennels. Declared here, ahead of
--- RemoveKennelForCitizenid, because that function's own new structural
--- guard (see its doc comment) must call this.
--- @param netId number
--- @param excludeCitizenId string?
--- @return string? occupantCitizenId
local function FindKennelOccupantByNetId(netId, excludeCitizenId)
    for citizenid, occupant in pairs(KennelOccupants) do
        if citizenid ~= excludeCitizenId and occupant.netId == netId then
            return citizenid
        end
    end
    return nil
end

--- How many citizenids currently have a KennelOccupants entry right now --
--- a real, live headcount of "how many K9s are genuinely resting inside a
--- deployed kennel this instant", read fresh on every call, never cached.
--- Exposed as a plain global function (this resource's established
--- "global helper, private per-file state" convention) for
--- server/runtimecontrol.lua's own active-usage confirmation gate (see
--- that file's "ACTIVE-USAGE CONFIRMATION FEATURES" section). READ-ONLY --
--- never mutates KennelOccupants, never disturbs an occupant, same
--- "read-only accessor" role FindKennelOccupantByNetId already has above.
--- @return integer count
function CountKennelOccupants()
    local count = 0
    for _ in pairs(KennelOccupants) do
        count = count + 1
    end
    return count
end

--- Mirrors FindKennelOwnerByNetId/FindKennelOccupantByNetId's exact shape,
--- applied to CarriedKennels — "is some citizenid currently carrying this
--- exact netId." Declared here for the same reason as
--- FindKennelOccupantByNetId above.
--- @param netId number
--- @param excludeCitizenId string?
--- @return string? carrierCitizenId
local function FindCarrierByNetId(netId, excludeCitizenId)
    for citizenid, carried in pairs(CarriedKennels) do
        if citizenid ~= excludeCitizenId and carried.netId == netId then
            return citizenid
        end
    end
    return nil
end

-- DEVELOPER_REFERENCE.md item 1 convention (server/cooldowns.lua): per-source
-- rate limit on requesting a NEW placement — spam defense only, distinct
-- from the one-active-kennel-per-citizenid limit enforced separately below.
--
-- ResolveConfiguredThresholdMs (server/cooldowns.lua, this pass, QA sandbox
-- repro — see that file's header ADDENDUM) wraps the raw Config read below
-- rather than handing it straight to NewCooldown: an uncaught non-positive
-- value there would abort THIS FILE's load from that line onward instead of
-- just disabling this one cooldown. Fallback matches config.lua's own
-- shipped default.
local DeployCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.DeployableKennel.deployCooldownMs, 5000, 'Config.DeployableKennel.deployCooldownMs'))
DeployCooldown.RegisterPlayerDropped()

-- Meters of slack over the server-chosen spawn point allowed when
-- confirming a placement — covers PlaceObjectOnGroundProperly's vertical
-- ground-snap plus ordinary network/latency drift. Mirrors
-- DOOR_SCRATCH_DISTANCE_TOLERANCE's exact reasoning in server/main.lua.
local KENNEL_CONFIRM_DISTANCE_TOLERANCE = 3.0

-- Meters of slack over Config.DeployableKennel.interactDistanceMeters
-- allowed for the two NEW proximity checks this pass adds (a non-owner's
-- pickup, and requestEnterKennel) — smaller than
-- KENNEL_CONFIRM_DISTANCE_TOLERANCE on purpose: those two actions compare
-- a live ped position against a REAL, currently-resolved, already-settled
-- object's own coords (no PlaceObjectOnGroundProperly ground-snap drift to
-- absorb), so only ordinary position/latency slack is needed, not the
-- larger placement-confirmation tolerance. Deliberately a LOCAL constant,
-- not a new Config field — same "security-relevant tolerance stays in
-- code" reasoning KENNEL_CONFIRM_DISTANCE_TOLERANCE already established.
local KENNEL_INTERACT_DISTANCE_TOLERANCE = 1.0

-- Precomputed set of allowed kennel prop model hashes (primary +
-- documented fallback — see config.lua's Config.DeployableKennel comment
-- for why both are legitimate). Built once at file load, same pattern as
-- server/certifications.lua's K9ModelHashes.
local KennelModelHashes = {
    [GetHashKey(Config.DeployableKennel.propModel)] = true,
    [GetHashKey(Config.DeployableKennel.fallbackPropModel)] = true,
}

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

--- Resolves whether `source` currently qualifies to REST as a K9 inside a
--- kennel — mirrors server/wellbeing.lua's own ResolveK9Ped shape exactly
--- (see that function's own header for the full access-bypass-fix
--- reasoning this copies): gating on ONLY the ped's current model would let
--- an uncertified player set their own ped model client-side (no server
--- round trip) and immediately claim the Fatigue rest-source bonus this
--- feature wires into (config.lua's Config.Wellbeing.Fatigue.restSources) —
--- exactly the bypass class that function's own fix closes. Not shared code
--- with that file (ResolveK9Ped is `local` there) — a second, small
--- application of the SAME already-exported primitives (IsConfiguredK9Model,
--- HasK9Role, HasK9Access), not a re-derivation of the underlying logic.
--- @param source number
--- @return number ped, boolean isK9 -- ped is 0 if the source isn't a currently-connected player
local function ResolveK9PedForKennelRest(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then return 0, false end
    local looksLikeK9 = IsConfiguredK9Model(GetEntityModel(ped))
    local holdsK9Role = type(HasK9Role) == 'function' and HasK9Role(source)
    return ped, (looksLikeK9 or holdsK9Role) and HasK9Access(source)
end

--- Computes a spawn/drop point Config.DeployableKennel.placementForwardOffsetMeters
--- in front of `ped`'s own live, server-side position and heading — shared
--- by requestDeployKennel (a brand new kennel) and requestPutDownKennel
--- (this pass, an already-existing, currently-carried kennel being set
--- back down), so there is exactly one place that derives "in front of
--- this ped" from server-authoritative data. See requestDeployKennel's own
--- extensive GetEntityForwardVector-vs-GetEntityHeading comment (kept at
--- that call site, not duplicated here) for why heading + trig, never
--- GetEntityForwardVector, is used.
--- @param ped number
--- @return number x, number y, number z
local function ComputeForwardSpawnPoint(ped)
    local pedCoords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local headingRad = math.rad(heading)
    local forward = { x = -math.sin(headingRad), y = math.cos(headingRad) }
    local offset = Config.DeployableKennel.placementForwardOffsetMeters
    return pedCoords.x + forward.x * offset, pedCoords.y + forward.y * offset, pedCoords.z
end

--- Deletes the citizenid's active kennel (server-side attempt + broadcast
--- backstop — see this file's header CLEANUP CONFIDENCE NOTE) and clears
--- the registry entry.
---
--- STRUCTURAL SAFETY GUARD, THIS PASS: REFUSES to run at all — deleting
--- nothing, notifying nobody, changing nothing — whenever the kennel
--- currently has an occupant riding inside it OR is currently being
--- carried by a connected handler. Deleting a real object a real,
--- currently-connected player's own ped is attached to is EXACTLY the
--- "player permanently trapped inside a deleted prop" failure this whole
--- feature is built to never produce (see this file's header CRITICAL
--- SAFETY section). This guard lives INSIDE this function, not merely as
--- a discipline every caller happens to follow, so a future caller cannot
--- reintroduce that exact class of bug by simply forgetting to check
--- first. Only remaining caller as of this pass: playerDropped's own
--- owner-disconnect branch (the manual pickup path no longer calls this
--- at all — see requestPickupKennel's own header note).
--- @param citizenid string
--- @return boolean removed -- false if refused (occupied/carried) or there was nothing to remove
local function RemoveKennelForCitizenid(citizenid)
    local kennel = Kennels[citizenid]
    if not kennel then return false end

    if FindKennelOccupantByNetId(kennel.netId, nil) or FindCarrierByNetId(kennel.netId, nil) then
        return false
    end

    Kennels[citizenid] = nil
    -- Releases this citizenid's claim on kennel.netId in the shared
    -- cross-feature registry (server/entities.lua) so the netId can be
    -- legitimately reused/reclaimed afterward without tripping
    -- IsNetworkEntityClaimedByOther for anyone else -- a no-op if this
    -- exact (feature, ownerId) pair never held the claim.
    ReleaseNetworkEntity(kennel.netId, 'kennel', citizenid)

    -- DEVELOPER_REFERENCE.md item 2 (Revision 5 migration): was this file's
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
    return true
end

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.DeployableKennel
--- flag) is already checked by requestDeployKennel below, before this
--- function is ever reached. Consulted ONLY at requestDeployKennel (the
--- "opening" action, placing a new kennel) -- never at requestPickupKennel,
--- requestPutDownKennel, requestEnterKennel, requestExitKennel,
--- cancelKennelPlacement, the playerDropped handler, or the onResourceStop
--- sweep, all of which are this feature's own "no unbounded trap" exit
--- paths and must keep working exactly as server/recall.lua's own header
--- documents for the identical reason.
---   2. an explicit block.DeployableKennel grant -> DENY
---   3. DeployableKennel listed in RequireGrant -> ALLOW only with an
---      active feature.DeployableKennel grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsDeployableKennelPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.DeployableKennel') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.DeployableKennel == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.DeployableKennel') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
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

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then
        NotifyPlayer(src, locale('common.unable_to_resolve_citizenid'), 'error')
        return
    end

    -- PER-PERSON FEATURE CONTROL -- see IsDeployableKennelPermittedForCitizenId
    -- above. Checked BEFORE DeployCooldown.Consume below, matching
    -- server/pursuitsprint.lua's own "cheapest/no-side-effect checks first"
    -- discipline, so a blocked handler never burns their own deploy
    -- cooldown for a request that was always going to be refused.
    if not IsDeployableKennelPermittedForCitizenId(citizenid) then
        NotifyPlayer(src, locale('kennel.not_authorized_to_deploy'), 'error')
        return
    end

    -- HANDLER XP TIER UNLOCK (dead-config-field pass, coder-backend):
    -- Config.HandlerXPTiers' kennelDeployCooldownMultiplier, consulted via
    -- GetHandlerXPTierKennelDeployCooldownMs (server/progression.lua) --
    -- same soft-dependency shape as every other cross-file consultation in
    -- this resource. `citizenid` is already resolved above -- DeployCooldown
    -- is keyed by `src`, the SAME deploying handler this tier lookup is
    -- for, so (unlike server/medkit.lua's target-vs-actor split) no second
    -- identity needs resolving here. Re-reads Config.DeployableKennel.
    -- deployCooldownMs fresh via ResolveConfiguredThresholdMs on every call
    -- (never the stale value DeployCooldown's own constructor captured once
    -- at file-load) so an operator's live edit reaches this gate the same
    -- tick, matching ResolveMedkitBaseCooldownMs's identical precedent in
    -- server/medkit.lua.
    --
    -- THIS MATTERS FOR ANY FUTURE handlerKennelDeploy AWARD WIRING, NOT
    -- JUST FOR THIS COOLDOWN: this cooldown is now RANK-REDUCED, down to a
    -- worst-case floor of 3000ms (5000ms base * 0.60 Master-Handler, the
    -- shipped multiplier) -- see GetHandlerXPTierKennelDeployCooldownMs's
    -- own doc comment (server/progression.lua, "THE NUMBERS" section) for
    -- the full arithmetic (config.lua's own header already measured the
    -- UNREDUCED 5000ms floor as 5,760 XP/hr gross and judged that unsafe
    -- to award through unthrottled; this pass's reduction makes that
    -- 9,600 XP/hr gross, 67% worse). If handlerKennelDeploy is ever wired
    -- to fire from a successful deploy below, its own per-actor mint
    -- cooldown MUST be sized against the rank-reduced 3000ms floor, not
    -- the unreduced 5000ms config default, and MUST be its own separate
    -- tracker -- never derived from DeployCooldown itself (now
    -- handler-rank-shortened). tests/kennel_spec.lua carries a SOURCE
    -- AUDIT test that fails if handlerKennelDeploy is ever awarded from
    -- this file without a companion *_XP_MINT_COOLDOWN tracker also
    -- present here.
    local baseDeployCooldownMs = ResolveConfiguredThresholdMs(
        Config.DeployableKennel.deployCooldownMs, 5000, 'Config.DeployableKennel.deployCooldownMs')
    local effectiveDeployCooldownMs = baseDeployCooldownMs
    if type(GetHandlerXPTierKennelDeployCooldownMs) == 'function' then
        effectiveDeployCooldownMs = GetHandlerXPTierKennelDeployCooldownMs(citizenid, baseDeployCooldownMs)
    end

    if not DeployCooldown.Consume(src, effectiveDeployCooldownMs) then
        return -- silent no-op: rate-limited, matches bark/leash-request/certify-action convention
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
    -- vector3(0, 0, 0) every time, unconditionally.
    --
    -- Substitute: GetEntityHeading(ped) + the standard heading->direction
    -- trig conversion, shared via ComputeForwardSpawnPoint (this pass) so
    -- requestPutDownKennel's own drop-point computation can never
    -- diverge from this one's reasoning.
    local spawnX, spawnY, spawnZ = ComputeForwardSpawnPoint(ped)

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
--- SECURITY-CRITICAL, RED-TEAM FIX (kept from an earlier pass): every
--- decision about whether a client-reported netId is SAFE TO DELETE, and
--- every write of a client-reported netId into `Kennels`, MUST be guarded
--- by this returning nil first — see confirmKennelPlaced's own
--- `safeToCleanup` below. THIS PASS: also reused (with excludeCitizenId =
--- nil) by requestPickupKennel and requestEnterKennel to answer "which
--- citizenid, if any, genuinely owns this netId" — see those handlers'
--- own comments.
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
--- reasoning, INCLUDING the red-team fix history kept in the in-body
--- comments below (unchanged by this pass — every rejection branch here
--- only ever touches an UNCONFIRMED object, never yet written to `Kennels`,
--- so it can never have an occupant or a carrier by construction; this
--- pass's own occupancy/carry redesign has nothing to add here).
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

    -- DEVELOPER_REFERENCE.md item 2 (Revision 5 migration): was this file's
    -- own `NetworkDoesEntityExistWithNetworkId` existence guard followed by
    -- a SEPARATE `GetEntityType(entity) ~= 3` check further down — both
    -- are now server/entities.lua's shared ResolveNetworkEntity(), called
    -- with expectedEntityType = 3 to fold the object-only restriction in
    -- as one call, mirroring server/main.lua's relayDoorScratch exactly.
    --
    -- SECURITY-CRITICAL: resolved HERE, immediately after the pending/src
    -- match is confirmed, and reused by EVERY branch below (never
    -- re-resolved) — mirrors server/fetch.lua's confirmFetchBallThrown
    -- `entity`/`safeToCleanup` placement exactly. `safeToCleanup` is the
    -- ONLY thing any rejection branch below consults before touching this
    -- entity: it requires the netId to (a) resolve to a real, currently-
    -- existing OBJECT, (b) match a configured kennel prop model, (c) name
    -- an entity this citizenid's own client is the current OneSync network
    -- owner of (NETWORK-OWNERSHIP GUARD — closes the PRE-CONFIRMATION-
    -- WINDOW race a victim's own multi-step client sequence can lose to an
    -- attacker who never created anything real at all), (d) NOT already be
    -- recorded against a DIFFERENT citizenid's `Kennels` entry
    -- (FindKennelOwnerByNetId), and (e) not already claimed by another
    -- feature's own tracked object (IsNetworkEntityClaimedByOther,
    -- server/entities.lua — closes the cross-feature `prop_tennis_ball`
    -- collision with server/fetch.lua's ball / server/propattachment.lua's
    -- fallback vest, both documented in config.lua).
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
    --- CONFIDENCE NOTE in this file's header for why both). An UNCONFIRMED
    --- object can never have an occupant/carrier (both registries are only
    --- ever populated for a netId already present in `Kennels`), so this
    --- reclaim is unaffected by this pass's own new safety guard on
    --- RemoveKennelForCitizenid — it deletes directly rather than going
    --- through that function, exactly as before this pass.
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

    if not entity then
        NotifyPlayer(src, locale('kennel.placement_failed_unconfirmed'), 'error')
        return
    end

    if not KennelModelHashes[GetEntityModel(entity)] then
        -- DELIBERATELY NOT deleting `entity` here, even though this file's
        -- other rejection branches DO (via RejectPlacement, when
        -- `safeToCleanup` allows it) -- see this branch's own established
        -- reasoning (unchanged by this pass): `entity` might not be the
        -- kennel the client actually created at all.
        NotifyPlayer(src, locale('kennel.placement_failed_wrong_model'), 'error')
        return
    end

    local entityCoords = GetEntityCoords(entity)
    local dx = entityCoords.x - pending.coords.x
    local dy = entityCoords.y - pending.coords.y
    local dz = entityCoords.z - pending.coords.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > KENNEL_CONFIRM_DISTANCE_TOLERANCE then
        RejectPlacement(locale('kennel.placement_failed_too_far'))
        return
    end

    if NetworkGetEntityOwner(entity) ~= src then
        RejectPlacement(locale('kennel.placement_failed_unconfirmed'))
        return
    end

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

--- Step 4: a certified handler picks up a deployed kennel. REWORKED THIS
--- PASS — see this file's header architecture section for the full "never
--- delete, only re-attach" redesign. Never deletes anything: on success,
--- the SAME real object is simply marked as carried and the picker's own
--- client is instructed to attach it to their own hands (event 9'); an
--- occupant riding inside, if any, comes along for free via the game's own
--- attachment hierarchy.
---
--- The RECORDED OWNER's own pickup (the first branch below) is UNCHANGED
--- from before this pass — still instant, still never gated on
--- HasK9Access/proximity/anything else beyond "is someone else already
--- carrying it," per this file's own "exit a kennel must never be gated"
--- doctrine and the TERMINATION PATH UNAFFECTED test this exact behavior
--- is pinned by. A DIFFERENT handler picking up SOMEONE ELSE's kennel is a
--- real, new capability grant acting on another citizen's object — unlike
--- the owner's own path, THAT is gated: HasK9Access, genuine `Kennels`
--- registry membership for the claimed netId (never trust the
--- client-supplied netId alone), and live server-side proximity to the
--- real, resolved object (this action never had a proximity check of any
--- kind before this pass — widening WHO may act on a netId without also
--- checking WHERE they are would turn "pick up your own kennel" into
--- "attach any tracked kennel on the map to yourself by netId," a real
--- griefing primitive this file's own header would call disqualifying for
--- every OTHER action in it).
--- @param netId number
RegisterNetEvent('qbx_k9unit:server:requestPickupKennel', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    -- Nobody may pick up something already being carried, regardless of
    -- who is asking (not even its own deployer) -- you cannot have two
    -- people carrying the same physical object at once.
    if FindCarrierByNetId(netId, nil) then
        NotifyPlayer(src, locale('kennel.pickup_already_carried'), 'error')
        return
    end

    local kennel = Kennels[citizenid]
    local ownerCitizenId
    if kennel and kennel.netId == netId then
        ownerCitizenId = citizenid -- RECORDED OWNER'S OWN fast path -- see this handler's own doc comment above
    else
        if not HasK9Access(src) then
            NotifyPlayer(src, locale('kennel.pickup_not_authorized'), 'error')
            return
        end
        ownerCitizenId = FindKennelOwnerByNetId(netId, nil)
        if not ownerCitizenId then
            NotifyPlayer(src, locale('kennel.not_owner'), 'error')
            return
        end
    end

    local ownerKennel = Kennels[ownerCitizenId]
    local entity = ResolveNetworkEntity(ownerKennel.netId, 3)
    if not entity then
        -- Stale registry entry -- the tracked object is genuinely gone
        -- (never deleted BY an ordinary pickup under this pass's own
        -- design, but nothing stops some other, out-of-band cleanup from
        -- having removed it). Clear the registry so the owner isn't stuck
        -- at their one-kennel limit forever with nothing real left to
        -- reclaim -- the exact "no unbounded trap" requirement this
        -- feature is built to satisfy.
        Kennels[ownerCitizenId] = nil
        ReleaseNetworkEntity(ownerKennel.netId, 'kennel', ownerCitizenId)
        NotifyPlayer(src, locale('kennel.invalid_kennel'), 'error')
        return
    end
    if not KennelModelHashes[GetEntityModel(entity)] then
        -- DELIBERATELY NOT clearing the registry here (mirrors
        -- confirmKennelPlaced's own wrong-model branch) -- `entity` might
        -- not be the genuine kennel at all.
        NotifyPlayer(src, locale('kennel.invalid_kennel'), 'error')
        return
    end

    -- Resolve the occupant ITSELF, not merely whether there is one: the
    -- person inside needs telling, and -- since the RIDE-ALONG pass -- the
    -- answer also decides whether the owner's own fast path is gated at
    -- all (see the proximity block immediately below). Being carried is the
    -- only thing in this resource that moves a player across the map with
    -- no input from them and, until this pass, no message either -- their
    -- view simply started travelling. A player whose screen moves for no
    -- stated reason assumes a bug or a cheat. Exiting was already
    -- unconditional (keybind, radial, ox_target, and a watchdog), so the
    -- notify is about knowing, not escaping.
    local occupant = FindKennelOccupantByNetId(ownerKennel.netId, nil)
    local hadOccupant = occupant ~= nil

    -- PROXIMITY.
    --
    -- Two independent reasons to require it, and the owner's own fast path
    -- is subject to the SECOND one only:
    --
    -- (a) A DIFFERENT handler acting on someone else's object -- always
    --     gated, unchanged from the pass that introduced it.
    --
    -- (b) ANY pickup of a kennel that currently has a live occupant riding
    --     inside it -- INCLUDING the recorded owner's own. This one is new,
    --     and it closes a real exploit that the ride-along feature created
    --     without anyone noticing: an attached entity has its transform
    --     re-clamped to its parent every tick by the engine, so picking up
    --     an OCCUPIED kennel snaps the person inside to the carrier. With
    --     the owner's path ungated that was a map-wide, repeatable,
    --     cooldown-free "teleport that player to me" primitive -- walk
    --     anywhere, pick up, and the occupant arrives. Anyone may enter a
    --     deployed kennel voluntarily, so the victim need not have done
    --     anything but accept a ride.
    --
    -- Note carefully what (b) does NOT do. It does not gate an exit, and it
    -- is not the "exit a kennel must never be gated" doctrine being
    -- softened: the OCCUPANT's own way out (keybind, radial, ox_target,
    -- watchdog) is untouched and still unconditional, and the OWNER's own
    -- reclaim of an EMPTY kennel -- the actual termination path, the one
    -- that un-sticks a stray object and frees their one-kennel limit -- is
    -- still instant from any distance, still ungated by HasK9Access,
    -- blocks, or feature flags, exactly as its TERMINATION PATH UNAFFECTED
    -- test pins it. The only thing now refused is moving a kennel that
    -- someone else is inside, from across the map, which was never a
    -- termination path for anybody: the owner can always walk to it, and
    -- the occupant can always simply step out.
    local mustBeClose = (ownerCitizenId ~= citizenid) or hadOccupant
    if mustBeClose then
        local ped = GetPlayerPed(src)
        if ped == 0 then return end -- defensive: src disconnected between the event firing and this line
        local dist = #(GetEntityCoords(ped) - GetEntityCoords(entity))
        if dist > (Config.DeployableKennel.interactDistanceMeters + KENNEL_INTERACT_DISTANCE_TOLERANCE) then
            NotifyPlayer(src, hadOccupant
                and locale('kennel.pickup_occupied_too_far')
                or locale('kennel.pickup_too_far'), 'error')
            return
        end
    end

    CarriedKennels[citizenid] = {
        netId = ownerKennel.netId,
        ownerCitizenId = ownerCitizenId,
        carrierSrc = src,
        startedAt = GetGameTimer(),
    }

    TriggerClientEvent('qbx_k9unit:client:pickupKennelConfirmed', src, ownerKennel.netId)

    if hadOccupant then
        NotifyPlayer(src, locale('kennel.picked_up_success_occupant_released'), 'success')
        -- The occupant's own side of the same event. Guarded because they
        -- may have disconnected between the occupancy read and here.
        if occupant.enteredSrc then
            NotifyPlayer(occupant.enteredSrc, locale('kennel.you_are_being_carried'), 'inform')
        end
    else
        NotifyPlayer(src, locale('kennel.picked_up_success'), 'success')
    end
end)

--- Step 5': carrier sets the kennel they are currently holding back down.
--- THIS PASS. Self-only: looks up whatever CarriedKennels[citizenid]
--- records, never a client-supplied netId -- the SAME "never trust a
--- client-claimed identity for its own state" discipline requestExitKennel/
--- cancelKennelPlacement already establish in this file. Client-side
--- trigger is client/kennel.lua's own RequestDeployKennel() -- see that
--- function's own doc comment for why one entry point correctly serves
--- both "deploy a brand new kennel" and "put down the one I'm carrying."
---
--- NEVER creates a new object and NEVER destroys the existing one -- the
--- one, same, real networked kennel object survives its entire deploy ->
--- carry -> put-down -> carry -> ... lifecycle. This is why an occupant
--- riding along inside is never at risk from a put-down the way it would
--- be from a delete-and-recreate design -- see this file's header
--- CRITICAL SAFETY section.
RegisterNetEvent('qbx_k9unit:server:requestPutDownKennel', function()
    local src = source

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    local carried = CarriedKennels[citizenid]
    if not carried or carried.carrierSrc ~= src then return end -- silent no-op: nothing being carried

    local ownerKennel = Kennels[carried.ownerCitizenId]
    if not ownerKennel or ownerKennel.netId ~= carried.netId then
        -- Registry drifted out of sync (should not be reachable through the
        -- two public net events alone) -- fail closed, clear the stale
        -- carry record rather than instruct a client to manipulate an
        -- entity this file no longer has a matching record of at all.
        CarriedKennels[citizenid] = nil
        return
    end

    local entity = ResolveNetworkEntity(ownerKennel.netId, 3)
    if not entity then
        -- The object is genuinely gone -- nothing in this pass's own design
        -- ever deletes a carried object, but never assume. Clear both
        -- registries so neither citizenid is left stuck: the carrier isn't
        -- holding anything real anymore, and the owner has nothing left to
        -- reclaim.
        CarriedKennels[citizenid] = nil
        Kennels[carried.ownerCitizenId] = nil
        ReleaseNetworkEntity(ownerKennel.netId, 'kennel', carried.ownerCitizenId)
        NotifyPlayer(src, locale('kennel.invalid_kennel'), 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    local x, y, z = ComputeForwardSpawnPoint(ped)
    CarriedKennels[citizenid] = nil

    TriggerClientEvent('qbx_k9unit:client:putDownKennelAt', src, ownerKennel.netId, x, y, z)
    NotifyPlayer(src, locale('kennel.put_down_success'), 'success')
end)

--- Step 6': a real, currently-connected player's own K9-modeled-or-role-
--- holding, access-holding ped asks to attach itself to a specific,
--- currently-deployed (not mid-carry), currently-unoccupied kennel within
--- range. THIS PASS. See this file's header NETWORK OWNERSHIP / NO
--- CROSS-PED DRIVING section -- this handler never touches the requesting
--- player's ped directly, it only ever validates and then instructs that
--- SAME client (event 11) to attach its OWN ped itself.
--- @param netId number
RegisterNetEvent('qbx_k9unit:server:requestEnterKennel', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    if not Config.Features.DeployableKennel then return end -- opening action -- silent no-op, matches requestDeployKennel's own gate

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    local ped, isK9 = ResolveK9PedForKennelRest(src)
    if ped == 0 then return end -- disconnected mid-flight
    if not isK9 then
        NotifyPlayer(src, locale('kennel.enter_not_authorized'), 'error')
        return
    end

    if KennelOccupants[citizenid] then
        NotifyPlayer(src, locale('kennel.enter_already_resting'), 'error')
        return
    end

    local ownerCitizenId = FindKennelOwnerByNetId(netId, nil)
    if not ownerCitizenId then
        NotifyPlayer(src, locale('kennel.invalid_kennel'), 'error')
        return
    end

    local kennel = Kennels[ownerCitizenId]
    local entity = ResolveNetworkEntity(kennel.netId, 3)
    if not entity or not KennelModelHashes[GetEntityModel(entity)] then
        NotifyPlayer(src, locale('kennel.invalid_kennel'), 'error')
        return
    end

    if FindCarrierByNetId(kennel.netId, nil) then
        NotifyPlayer(src, locale('kennel.enter_being_carried'), 'error')
        return
    end

    if FindKennelOccupantByNetId(kennel.netId, nil) then
        NotifyPlayer(src, locale('kennel.enter_kennel_occupied'), 'error')
        return
    end

    local dist = #(GetEntityCoords(ped) - GetEntityCoords(entity))
    if dist > (Config.DeployableKennel.interactDistanceMeters + KENNEL_INTERACT_DISTANCE_TOLERANCE) then
        NotifyPlayer(src, locale('kennel.enter_too_far'), 'error')
        return
    end

    KennelOccupants[citizenid] = {
        netId = kennel.netId,
        enteredSrc = src,
        enteredAt = GetGameTimer(),
    }

    TriggerClientEvent('qbx_k9unit:client:enterKennelConfirmed', src, kennel.netId)
end)

--- Step 7': the occupant's own, ALWAYS-AVAILABLE self-service exit. THIS
--- PASS. See this file's header CRITICAL SAFETY section -- NEVER gated on
--- Config.Features.DeployableKennel, HasK9Access,
--- IsDeployableKennelPermittedForCitizenId, or any cooldown. Purely a
--- registry-bookkeeping clear -- client/kennel.lua's own client has
--- ALREADY released itself locally, unconditionally, before this event is
--- even sent (see that file's ReleaseKennelRest doc comment); this
--- handler's only job is freeing the registry so the kennel is not
--- misreported as occupied to a future requestEnterKennel/requestPickupKennel
--- caller.
RegisterNetEvent('qbx_k9unit:server:requestExitKennel', function()
    local src = source

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    if KennelOccupants[citizenid] and KennelOccupants[citizenid].enteredSrc == src then
        KennelOccupants[citizenid] = nil
    end
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
    -- acting on stale ownership. Return value intentionally unused: `false`
    -- just means RemoveKennelForCitizenid refused because the kennel is
    -- currently occupied or being carried by a still-connected player --
    -- exactly the safe fallback wanted here (leave it in the world,
    -- unowned-but-intact, rather than delete it out from under them). See
    -- that function's own doc comment.
    if Kennels[citizenid] and Kennels[citizenid].ownerSrc == src then
        RemoveKennelForCitizenid(citizenid)
    end

    -- OCCUPANT DISCONNECT (this pass) -- a K9 currently resting who
    -- disconnects must not leave a stale KennelOccupants entry behind (the
    -- kennel they were in would otherwise read as permanently "occupied,"
    -- per FindKennelOccupantByNetId, to every future
    -- requestEnterKennel/requestPickupKennel caller). No entity mutation
    -- needed here -- the kennel object itself is untouched; the
    -- disconnecting player's own ped (and, with it, whatever it was
    -- attached to) is torn down by the platform itself on disconnect,
    -- exactly like every other player-owned entity. Independent of, and
    -- unaffected by, the owner-disconnect branch immediately above -- the
    -- SAME disconnecting citizenid could in principle be both (an owner
    -- resting in their own deployed kennel), in which case both branches
    -- simply run.
    if KennelOccupants[citizenid] and KennelOccupants[citizenid].enteredSrc == src then
        KennelOccupants[citizenid] = nil
    end

    -- CARRIER DISCONNECT (this pass) -- see this file's header event 12
    -- and CRITICAL SAFETY section. The disconnecting client is gone, so
    -- nobody will run the client-side "detach the kennel from my hands"
    -- logic an ordinary put-down performs -- left alone, the object would
    -- stay attached to a ped handle that no longer exists. Broadcast (-1,
    -- matching RemoveKennelForCitizenid's own established backstop shape)
    -- rather than targeting a specific client: whichever CONNECTED client
    -- currently has this object streamed in (very possibly including an
    -- occupant riding inside it) is able to settle it, and this file has
    -- no reliable way to know which one that is. Deliberately does NOT
    -- touch KennelOccupants -- an occupant riding inside is completely
    -- unaffected by WHO is carrying the object and keeps their own,
    -- completely independent self-service exit throughout, unaffected by
    -- this branch.
    if CarriedKennels[citizenid] and CarriedKennels[citizenid].carrierSrc == src then
        local carried = CarriedKennels[citizenid]
        CarriedKennels[citizenid] = nil
        TriggerClientEvent('qbx_k9unit:client:kennelCarrierLost', -1, carried.netId)
    end

    -- DeployCooldown already registered its own playerDropped handler via
    -- :RegisterPlayerDropped() above — DEVELOPER_REFERENCE.md item 1
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
--
-- DELIBERATELY UNCONDITIONAL, EVEN FOR AN OCCUPIED/CARRIED KENNEL (this
-- pass): unlike RemoveKennelForCitizenid's own new structural refusal
-- (playerDropped's own concern -- leave a kennel alone if a DIFFERENT,
-- still-connected player is actively using it), a full resource restart is
-- different in kind: `Kennels`/`KennelOccupants`/`CarriedKennels` are all
-- plain in-memory Lua locals that reset to empty tables the instant this
-- resource restarts, with no persistence across that boundary. NOT
-- deleting the entity here would leave a REAL object in the world that no
-- fresh instance of this file could ever track, pick up, or otherwise
-- remove again -- a permanent orphan, exactly the "every placed kennel
-- must always be removable" invariant this feature exists to satisfy,
-- violated the other way. This is safe for any occupant/carrier because
-- NEITHER depends on the server doing anything at all to stay unstuck:
-- client/kennel.lua's own onResourceStop handler independently detaches
-- and frees its own local ped/attachment state on EVERY connected client,
-- regardless of whether this exact loop manages to delete the shared
-- object first, second, or not at all.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- DEVELOPER_REFERENCE.md item 2 (Revision 5 migration): was this file's
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
    -- clients are still fully running. KennelOccupants/CarriedKennels need
    -- no explicit clearing here either -- this whole file's state (all
    -- four registries) is discarded wholesale the instant this Lua chunk
    -- unloads, and every connected client's own independent local cleanup
    -- (see this comment block's own opening paragraph) never reads any of
    -- it to begin with.
end)
