--[[
    qbx_k9unit/server/main.lua

    Phase 1 scaffold only (coder-architect). REWRITTEN after DEVELOPER_REFERENCE.md's
    post-draft correction — the K9 is a player's own persistent character,
    so there is no spawn/despawn/registry concept for this file to own
    anymore (see server/certifications.lua's header for the full removed
    list). Later REVISED again once the requester confirmed the leash
    mechanic explicitly (consent-based attach, elastic movement restriction
    while attached, zero-consent detach, safety-valve auto-detach —
    DEVELOPER_REFERENCE.md §6.1, §9 item 3b resolved). This file's role:
      1. Resource-start cache backfill — IMPLEMENTED below, as the second
         of this file's two `onResourceStart` handlers (see that handler's
         own "STRUCTURAL GAP backfill" comment for the full writeup). Not a
         TODO: without it, an already-connected player's certification
         cache would sit empty after a `/restart qbx_k9unit` (or
         crash-restart) — a structural gap DEVELOPER_REFERENCE.md doesn't
         call out explicitly, closed here. (This header used to say "see
         TODO below" — stale, from before the backfill was written; there
         is no TODO anywhere in this file. See tests/mainserver_spec.lua
         Section 12 for the pinning spec.)
      2. A home for small, access-gated K9 actions that need SOME server
         authority but aren't part of the certification/permission system
         itself: bark relay, and now the leash consent handshake + the
         ephemeral (not persisted) leash-pair registry. Keeping these out
         of certifications.lua stops that file from turning into an
         everything-file as Phase 2+ adds more of this category (e.g. a
         scent-reveal trigger, a contraband-alert trigger).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1. Certification events are documented
    in full in server/certifications.lua (kept in sync manually, not
    duplicated in full detail here). THIS FILE's own events, in full:

    Callbacks: none registered in this file (see
    server/certifications.lua's 'qbx_k9unit:server:hasK9Access').

    Server events (RegisterNetEvent, client->server):
    - 'qbx_k9unit:server:relayBark' (barkType: string)
      NOTE the signature change from the pre-correction draft: no `netId`
      argument. There is no registry of "which netId belongs to which
      player" to validate against, because the K9 IS the player's own
      ped, always — so THIS FILE resolves the sender's own ped/netId
      itself (GetPlayerPed(source) -> NetworkGetNetworkIdFromEntity)
      rather than trusting a client-supplied netId claim. `barkType` is
      also length-capped (BARK_TYPE_MAX_LENGTH, see that constant's own
      comment) — coder-security finding, 2026-08-23: the per-second
      BarkCooldown throttles CALL frequency but never bounded payload
      SIZE, so an eligible client could otherwise turn every accepted
      once-a-second call into a large -1-broadcast (bandwidth
      amplification), independent of any future barkType enum.
    - 'qbx_k9unit:server:requestLeashAttach' (targetServerId: number)
      Initiator (either the K9 or the officer, per DEVELOPER_REFERENCE.md §6.1) asks to
      attach to `targetServerId`. Server validates eligibility/proximity/
      role and, if valid, relays a consent prompt to the TARGET — does
      NOT attach anything yet. See "LEASH SUBSYSTEM" section below.
    - 'qbx_k9unit:server:respondLeashAttach' (fromServerId: number, accepted: boolean)
      The target's response to a pending request from `fromServerId`.
      Server RE-validates everything (time has passed since the request —
      classic TOCTOU window) before actually forming the pair.
    - 'qbx_k9unit:server:detachLeash' ()
      Either party, at any time, zero consent needed (hard requirement per
      the requester's confirmation — no mechanic may trap someone leashed
      with no self-service exit).
    - 'qbx_k9unit:server:relayDoorScratch' (doorNetId: number)
      Phase 2 (DEVELOPER_REFERENCE.md §11.4 item 5, DEVELOPER_REFERENCE.md#door-interaction §4.2).
      Structurally mirrors relayBark above, EXCEPT `doorNetId` names a
      DIFFERENT entity than the sender's own ped, so (unlike relayBark) this
      handler also resolves it (NetworkGetEntityFromNetworkId), confirms it
      still exists (DoesEntityExist), and confirms it's actually near the
      caller before broadcasting — closing the gap flagged in DEVELOPER_REFERENCE.md §9
      item 16. Own independent cooldown table (lastDoorScratchAt), not
      shared with relayBark's.

    Client events (RegisterNetEvent, server->client):
    - 'qbx_k9unit:client:playBark' (netId: number, barkType: string)
      [client/main.lua] — netId is still present here because the
      *receiving* clients need to know which entity to attach the sound
      to; it's server-resolved from the sender, not client-claimed.
    - 'qbx_k9unit:client:playDoorScratch' (doorNetId: number)
      [client/movement.lua] — mirrors playBark above; sent as a global
      broadcast (-1), deliberately, since a door's location carries no
      person/vehicle identity to leak (see the relayDoorScratch handler's
      own comment below for why this is NOT the pattern to copy for
      server/search.lua's contraband-alert broadcast).
    - 'qbx_k9unit:client:leashAttachRequest' (fromServerId: number)
      [client/movement.lua] — shown to the target as an accept/decline
      prompt.
    - 'qbx_k9unit:client:leashAttached' (partnerServerId: number, isConstrained: boolean)
      [client/movement.lua] — sent individually to BOTH parties once
      accepted, each with their OWN role flag. `isConstrained = true`
      means THIS client is the one whose position gets pulled back near
      Config.LeashMaxDistance (the K9 role); `false` means this client is
      the anchor (the officer role) and does nothing but track/display the
      pairing.
    - 'qbx_k9unit:client:leashDetached' (reason: string)
      [client/movement.lua] — sent to both parties whenever the pair ends
      (manual detach by either side, disconnect, the constrained client's
      own safety-valve auto-detach, cert revocation/department change, or
      — DEATH-DETECTION FIX, this pass, reason = 'partner_died' — either
      party dying while remaining connected; see the dedicated
      death-detection thread below doDetachLeash for the full writeup).
      client/movement.lua only special-cases 'partner_disconnected' for its
      own notify text today; every other reason (including this new one)
      falls through to its generic locale('movement.leash_detached')
      message — NOT fixed here (client/movement.lua is outside this pass's
      edit scope), reported to that file's owner as a follow-up so
      'partner_died' gets its own specific wording the same way
      'partner_disconnected' already does.

    Commands: both live in server/certifications.lua.

    Automatic path: QBCore:Server:OnJobUpdate lives in
    server/certifications.lua (§4.4).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)` and `IsConfiguredK9Model(modelHash)`,
      resource-global functions exposed by server/certifications.lua — do
      not re-implement either check here.
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)`,
      exposed by server/entities.lua (DEVELOPER_REFERENCE.md near-term item 2),
      inside relayDoorScratch below — do not re-implement the
      resolve/existence-guard sequence here.
    - THIS FILE calls `RefreshCertificationCache(citizenid, jobName)`,
      also exposed by server/certifications.lua, from the resource-start
      backfill loop below.
    - THIS FILE exposes `ForceDetachLeashForSource(src, reason)` (resource-
      global, no `local`) for server/certifications.lua to call whenever a
      K9-role party's certification transitions from active to revoked
      (manual RevokeCertification, offline RevokeCertificationOffline, or
      the QBCore:Server:OnJobUpdate auto-revoke) while that citizenid
      currently resolves to a connected server id — DEVELOPER_REFERENCE.md §1/§4.4
      "immediately" ending K9 access must also tear down an already-formed
      leash pairing, not just block future attach attempts. No-op (returns
      false) if that source isn't currently leashed to anyone, OR if it is
      leashed but only as the officer/handler-role party of that pairing —
      see this function's own doc comment below for why role (not mere
      participation) is what actually gates the detach. Reuses the exact
      same internal detach path (doDetachLeash) as the player-initiated
      detachLeash event — do not duplicate the LeashPairs mutation/
      broadcast logic in certifications.lua.
    - client/movement.lua is the ONLY client file that should register
      handlers for the three leash client events above, or trigger the
      three leash server events above — keep the full leash subsystem
      confined to {this file, client/movement.lua}. client/radial.lua only
      ever calls client/movement.lua's exposed globals (RequestLeashAttach/
      DetachLeash/IsLeashed), never these events directly.
    - DEATH-DETECTION FIX (this pass, coder-frontend): THIS FILE now calls
      `K9Compat.Get('ambulance').IsDowned(src)` (shared/compat/core.lua,
      via shared/compat/ambulance.lua's registered adapters) and reads
      `Config.Combat.PropDragging.IsPlayerDownedOverride` — the SAME
      override/adapter pair server/defense.lua's own `IsHandlerDown`
      already established for the identical "is this specific connected
      player currently down" question, reused here rather than
      reinvented. See `IsLeashPartyDead`'s own doc comment (near the
      death-detection thread, below `ForceDetachOfficerLeashForSource`)
      for the full precedence writeup.
    ======================================================================
    LEASH SUBSYSTEM DESIGN (per requester's confirmation, resolving
    DEVELOPER_REFERENCE.md §9 item 3b — supersedes the earlier "client-only state, no
    server event" scaffold draft):

    1. Attach requires consent. The target must explicitly accept via an
       ox_lib prompt (client/movement.lua) before anything activates —
       never forced on someone by the initiator alone.
    2. While attached, it's a REAL movement restriction on the K9-role
       party (elastic soft-constraint pulling them back as they approach
       Config.LeashMaxDistance), not just a passive distance-monitor+notify.
       That restriction logic runs entirely client-side, on the
       CONSTRAINED player's OWN client (a client can only reliably control
       its own ped's position — see client/movement.lua for why).
    3. Either party can detach at will, with ZERO consent needed. This is
       a hard requirement — always available to both sides while leashed.
    4. A hard-cap safety-valve auto-detach (disconnect/teleport/desync
       still exceeding the max distance despite the pull-back) is a
       fallback, not the primary behavior — and reuses the SAME detach
       path (client calls DetachLeash() itself), not a separate code path.
    5. DEATH-DETECTION FIX (this pass, coder-frontend — audit-flagged gap):
       either party dying while remaining connected (no disconnect at all)
       is now its OWN independent termination path, server-side, via a
       dedicated poll thread (see `IsLeashPartyDead`/the death-detection
       thread, below `ForceDetachOfficerLeashForSource`) — this was
       previously the one termination-shaped condition this file completely
       missed (confirmed by a full read during the visible-leash work; see
       client/leashvisual.lua's own header for that finding). Reuses
       doDetachLeash exactly like every other path above; does not depend
       on item 4's distance safety-valve to eventually notice (a dead K9
       lying next to its still-standing handler never exceeds
       Config.LeashMaxDistance at all, so item 4 alone would never have
       caught this case).

    Role assignment: server determines which party is "the K9" (and
    therefore gets `isConstrained = true`) via the SAME live,
    server-authoritative model check used for certification grants
    (IsConfiguredK9Model + GetEntityModel(GetPlayerPed(...))), never a
    client-reported role. The K9-role party's access is checked via
    HasK9Access. The other ("handler"/officer) party does NOT need an
    active K9 certification of their own, but per DEVELOPER_REFERENCE.md §6.1/§9 item 9
    (Resolved) they DO need `job.name ∈ Config.Departments` — "handler" is
    defined throughout the spec (§1) as a partnered officer, so an
    arbitrary non-department player cannot hold the other end of a working
    K9's leash even with consent; department membership is a cheap check
    reusing the exact same Config.Departments list. See
    CheckLeashEligibility below for the enforcement of both halves of this
    rule.

    EDGE CASE flagged, not resolved: if BOTH parties are K9-modeled and
    both hold access, which one is "constrained" is arbitrary — this
    scaffold suggests defaulting the REQUEST TARGET to the constrained
    role (i.e. whoever gets asked ends up "on the leash"), but that's a
    judgment call for coder-backend to confirm, not a spec mandate.
    CONFIRMED below: the request target is the constrained/K9 role when
    both are K9-modeled.

    No dedicated config constant exists for "max range to INITIATE an
    attach request" — Config.LeashMaxDistance is the base leash range that
    client/movement.lua derives its actual pull-back-start/auto-detach
    thresholds from (see config.lua's comment on that field for the full
    picture across all three call sites). This scaffold reuses the raw
    Config.LeashMaxDistance value for the initiate-range check too, as a
    reasonable Phase 1 default — flag if a separate, smaller "attach
    range" constant is wanted instead.
]]

-- Ephemeral, in-memory only leash pairing — NOT persisted, does not
-- survive a resource restart (nor should it need to; this is a live
-- session mechanic, not part of the certification/permission system).
-- Keyed by server id (source), one entry per participant, mirrored both
-- directions while attached: LeashPairs[a] = { partner = b, isK9 = <bool> }
-- and LeashPairs[b] = { partner = a, isK9 = <bool> }.
--
-- Regression-test fix: previously this stored the partner id directly
-- (LeashPairs[a] = b), with no record of which server id is the K9-role
-- party vs. the officer/handler-role party for that pairing — role was
-- only ever communicated to each client individually via the
-- `isConstrained` boolean at attach time, never retained server-side. That
-- meant ForceDetachLeashForSource could only key off "is this id a
-- participant in ANY pairing" and would force-detach regardless of role.
-- Since HasK9Access deliberately doesn't check ped model (see
-- server/certifications.lua's header — a certified handler keeps their
-- cert after switching away from a K9 model, a documented tradeoff), a
-- revoked citizenid's stale cert can resolve to a server id that is
-- CURRENTLY anchoring (officer role) someone else's legitimate, unrelated
-- K9 pairing. Revoking that person's cert must not tear down a leash they
-- are only anchoring, not being constrained by — hence storing `isK9`
-- alongside each pairing so ForceDetachLeashForSource can tell the two
-- roles apart. Local: nothing outside this file needs it directly.
local LeashPairs = {}

-- Ephemeral pending leash requests: PendingLeashRequests[targetSrc] = {
-- from = initiatorSrc, expiresAt = <GetGameTimer() timestamp> }.
-- JUDGMENT CALL (this file originally flagged a pending-request expiry as
-- optional/coder-backend's call): added so a request nobody ever answers
-- doesn't linger indefinitely available for a stale accept far later
-- (e.g. after the initiator has moved away, disconnected, or paired with
-- someone else in the meantime) — consumed (cleared) on any response,
-- valid or not. Local: nothing outside this file needs it.
--
-- SECURITY/UX FIX (coder-security, exploit-tester + qa-tester finding,
-- 2026-08-23): this is a single-slot table keyed only by target, so a
-- second request arriving for a target that already has a live, unexpired
-- entry would previously overwrite it wholesale with no notification to
-- the superseded initiator. requestLeashAttach now rejects a second
-- request outright while a live one is still pending for that target — see
-- that handler's own comment for the full writeup and why "reject the
-- second caller" was chosen over "notify the superseded first caller."
local PendingLeashRequests = {}
local LEASH_REQUEST_TTL_MS = 30000

-- Regression-test fix: relayBark got an explicit per-source cooldown
-- (BARK_COOLDOWN_MS below) specifically to close a spam vector — this
-- event had no equivalent, letting an eligible nearby party spam
-- accept/decline modals at a target with zero rate limit. Not a permission
-- escalation (every proximity/model/cert check in CheckLeashEligibility
-- still applies before this ever fires), just a UI-harassment vector.
-- Mirrors the bark cooldown's exact pattern.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastLeashRequestAt`
-- table, now a NewCooldown() instance (server/cooldowns.lua) — same
-- threshold, same per-source key, same playerDropped-based cleanup (see
-- LeashRequestCooldown.RegisterPlayerDropped() below), behavior unchanged.
local LEASH_REQUEST_COOLDOWN_MS = 1000
local LeashRequestCooldown = NewCooldown(LEASH_REQUEST_COOLDOWN_MS)
LeashRequestCooldown.RegisterPlayerDropped()

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation, called at RUN time from this file's handlers exactly as
-- before -- see server/notify.lua's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

-- STRUCTURAL GAP backfill (flagged by coder-architect, not explicit in
-- DEVELOPER_REFERENCE.md itself): server/certifications.lua's cache populates per-player
-- on a player-loaded event, which only fires for players who connect/load
-- AFTER that handler is registered. On a `/restart qbx_k9unit` (or a
-- crash-restart) while players are already online, nobody re-fires that
-- event for them, so their cache entry would sit empty (= "no access")
-- until their next job change or reconnect — a certified officer could be
-- silently locked out of K9 features for the remainder of their session.
-- GetPlayers() returns connected player ids as strings; tonumber'd below.
--
-- Regression-test fix (found by regression-tester, cross-referencing this
-- loop against the metadata.k9certified sync points added to
-- certifications.lua's GrantCertification/RevokeCertification/
-- RevokeCertificationOffline/OnJobUpdate/PlayerLoaded after this loop was
-- first written): this backfill correctly repaired the real access cache
-- but never resynced the read-only k9certified HUD mirror, so a mirror
-- that drifted before a restart (e.g. an out-of-band DB edit, or a crash
-- between a grant/revoke's DB write and its paired SetMetaData call)
-- would keep its stale value indefinitely for an already-connected player
-- — not an auth bypass (HasK9Access never reads metadata), but a real,
-- undocumented HUD-accuracy gap. Now resyncs the mirror the same way
-- PlayerLoaded's own backfill does, from the value RefreshCertificationCache
-- just determined.
-- CONFIG-SAFETY GUARD (config-validator finding): Config.DoorInteraction.
-- nudgeRequiresUnlocked is documented, in config.lua's own inline comment
-- and README.md, as "a hard requirement, not a toggle" -- nudge-open must
-- never be allowed to function as a lockpick bypass. When this guard was
-- first written, nudge-open did not yet exist anywhere in this resource, so
-- the flag was inert either way -- as shipped it was an ordinary editable
-- boolean with nothing anywhere actually enforcing that.
-- STALE-NOTE FIX (issue-closer sweep): nudge-open is now implemented
-- (client/movement.lua's NudgeDoor()), and that file carries its OWN
-- identical assert of this exact field -- see NudgeDoor()'s own header
-- comment ("NUDGE-OPEN — DESIGN PATH TAKEN"). Both asserts stay in
-- place, deliberately not deduplicated into one: nudge-open is fully
-- client-local with zero server round trip (see that file's own header),
-- so the server never gets another chance to catch a bad value once
-- nudge-open actually runs -- this guard is the server's own independent
-- check that config.lua (loaded identically on both sides) still holds a
-- safe value, not a substitute for the client's own assert. The risk
-- config-validator originally flagged is no longer hypothetical: a server
-- owner who long ago flipped this to `false` for an unrelated reason
-- (testing, a copied "permissive" example config) now inherits a real
-- lockpick-bypass exploit the moment nudge-open runs against that value,
-- without anyone having deliberately, reviewedly wired it that way. Fail
-- loudly at resource start instead of silently accepting an unsafe value.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    assert(
        Config.DoorInteraction.nudgeRequiresUnlocked == true,
        '[qbx_k9unit] Config.DoorInteraction.nudgeRequiresUnlocked must be true -- ' ..
        'it is a hard safety requirement, not a server-tunable toggle. ' ..
        'Nudge-open must never be able to bypass a locked door.'
    )
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.job then
                local citizenid = Player.PlayerData.citizenid
                -- SECURITY/CORRECTNESS FIX (coder-security, final pass): this
                -- used to index `Certifications[citizenid]` directly, but
                -- `Certifications` is a `local` table scoped to
                -- certifications.lua's own chunk — it is NOT a shared global
                -- and was never visible here. That indexed a nil global,
                -- throwing an uncaught Lua error on the very first
                -- qualifying player, which aborted this ENTIRE for loop
                -- (FXServer's event dispatch pcalls the whole handler
                -- invocation, not each iteration) — silently breaking not
                -- just the new k9certified mirror resync but the loop's
                -- original, more important purpose: re-warming
                -- RefreshCertificationCache's real access cache for every
                -- already-connected player after a resource restart. That
                -- reintroduced exactly the "certified officer silently
                -- locked out of K9 features for the remainder of their
                -- session" gap this handler exists to prevent, for every
                -- player after the first one processed. Use
                -- RefreshCertificationCache's own return value (the `active`
                -- boolean it already computed) instead of reaching into a
                -- table this file was never able to see.
                local isActive = RefreshCertificationCache(citizenid, Player.PlayerData.job.name)
                Player.Functions.SetMetaData('k9certified', isActive)
            end
        end
    end
end)

-- coder-security: relayBark broadcasts to EVERY connected client
-- (TriggerClientEvent(..., -1, ...) below) on every call — with no
-- per-player throttle, a single modified client spamming this event as
-- fast as the network allows turns into a server-wide broadcast flood
-- (network chatter to every player, plus a PlaySoundFromEntity call fired
-- on every one of their clients), i.e. an abuse-resistance gap per
-- DEVELOPER_REFERENCE.md's general "spammable actions" concern even though a bark itself
-- has no other gameplay effect. A small per-player cooldown closes this
-- without needing a config addition — bark has no legitimate reason to be
-- triggered faster than this.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastBarkAt` table,
-- now a NewCooldown() instance (server/cooldowns.lua) — same threshold,
-- same per-source key, same playerDropped-based cleanup (see
-- BarkCooldown.RegisterPlayerDropped() below), behavior unchanged.
local BARK_COOLDOWN_MS = 1000
local BarkCooldown = NewCooldown(BARK_COOLDOWN_MS)
BarkCooldown.RegisterPlayerDropped()

-- SECURITY FIX (coder-security, exploit-tester + qa-tester finding,
-- 2026-08-23): BarkCooldown above rate-limits CALLS to this event (one
-- accepted broadcast/sec/certified account), but nothing previously bounded
-- the SIZE of the `barkType` payload each accepted call broadcasts —
-- `type(barkType) == 'string'` passes for a string of any length. A
-- modified client held by a legitimately-certified officer (the cooldown
-- doesn't stop a low-and-slow abuser, only a fast-spam one) can still call
-- this directly with an arbitrarily large string, turning every accepted,
-- once-a-second call into a sustained bandwidth-amplification broadcast
-- (TriggerClientEvent(..., -1, ...) below fans it out to every connected
-- player). client/main.lua's playBark handler doesn't even read `barkType`
-- for anything today (see its own comment) — a short cap costs the real
-- feature nothing. Value chosen to comfortably fit the one real value in
-- use today ('bark', see client/radial.lua's Bark item) plus headroom for a
-- handful of short Phase 5 AdvancedBarkRadial variants, without leaving
-- room to smuggle a large payload through this event.
local BARK_TYPE_MAX_LENGTH = 16

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.BasicBarkSounds
--- flag) is already checked by relayBark below, before this function is
--- ever reached.
---   2. an explicit block.BasicBarkSounds grant -> DENY
---   3. BasicBarkSounds listed in RequireGrant -> ALLOW only with an active
---      feature.BasicBarkSounds grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsBasicBarkSoundsPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.BasicBarkSounds') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.BasicBarkSounds == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.BasicBarkSounds') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Relays a bark to every client so anyone near the K9 entity hears it.
--- Gated by Config.Features.BasicBarkSounds AND HasK9Access(source) —
--- both re-checked HERE, server-side, regardless of whether the client UI
--- that triggered this (client/radial.lua's Bark item) already checked
--- them, per DEVELOPER_REFERENCE.md §3's "disabled feature must be a no-op server-side,
--- not just hidden client-side" requirement.
--- @param barkType string
RegisterNetEvent('qbx_k9unit:server:relayBark', function(barkType)
    local src = source

    if not Config.Features.BasicBarkSounds then return end -- silent no-op
    if type(barkType) ~= 'string' then return end -- defensive: never trust client payload shape
    -- SECURITY FIX (see BARK_TYPE_MAX_LENGTH's own comment above): cap length
    -- BEFORE the cert/cooldown checks below so an oversized payload from an
    -- otherwise-eligible, on-cooldown account is rejected outright, not just
    -- rate-limited.
    if #barkType > BARK_TYPE_MAX_LENGTH then return end -- silent no-op: oversized payload, never trust client payload shape
    if not HasK9Access(src) then return end -- reuse the global from server/certifications.lua, do not re-derive the job/cert check here

    -- PER-PERSON FEATURE CONTROL -- see IsBasicBarkSoundsPermittedForCitizenId
    -- above. Checked BEFORE BarkCooldown.Consume below, matching
    -- server/pursuitsprint.lua's own "cheapest/no-side-effect checks first"
    -- discipline, so a blocked K9 never burns their own bark cooldown for a
    -- request that was always going to be refused. Silent no-op on denial,
    -- matching every other rejection branch in this handler.
    do
        local player = exports.qbx_core:GetPlayer(src)
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid
        if not citizenid or not IsBasicBarkSoundsPermittedForCitizenId(citizenid) then return end
    end

    if not BarkCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local ped = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    -- NOTE on `barkType`: no enum is defined anywhere yet in DEVELOPER_REFERENCE.md or
    -- config.lua — Phase 1 only needs a single generic bark per §6.1.
    -- Treat barkType as an opaque passthrough string, don't invent a
    -- validation enum unless client/radial.lua's comment says otherwise
    -- for Phase 5's AdvancedBarkRadial. It IS still length-capped
    -- (BARK_TYPE_MAX_LENGTH above) purely as a bandwidth/abuse bound, not a
    -- content restriction — that check is independent of whether an enum
    -- ever gets added.
    TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType)
end)

-- DEVELOPER_REFERENCE.md §9 item 16 (Phase 2 event-contract hardening pass finding, closed
-- here as part of writing this handler for the first time, per that item's
-- own closing note that it "should be closed out as part of writing it, not
-- discovered afterward as a regression"): unlike relayBark above (which only
-- ever resolves and broadcasts the SENDER's own already-access-checked ped),
-- relayDoorScratch's `doorNetId` names a DIFFERENT entity the caller merely
-- claims to be near — neither the original §11.4 item 5 contract nor
-- DEVELOPER_REFERENCE.md#door-interaction §4.2's handler sketch called for
-- resolving/existence-checking/proximity-checking that id before
-- broadcasting. Left unchecked, a modified client could pass any entity's
-- netId (any vehicle, any other player's ped, even 0) and have the server
-- broadcast a sound event referencing it to every client with that entity
-- streamed in. Closed below via DoesEntityExist + a distance check against
-- the caller's own live position, mirroring the "never trust a
-- client-supplied id" standard already applied elsewhere in this resource
-- (e.g. relayBark resolving the sender's own ped rather than trusting a
-- claimed netId, CheckLeashEligibility's live proximity checks).
local DOOR_SCRATCH_DISTANCE_TOLERANCE = 1.0 -- meters of slack over Config.DoorInteraction.interactDistance for latency/desync, same spirit as other proximity re-checks in this file

-- Sibling, INDEPENDENT per-source cooldown table — deliberately not shared
-- with lastBarkAt above. Bark and door-scratch are two independently
-- cooldowned actions per §11.4/DEVELOPER_REFERENCE.md#door-interaction §4.2; a
-- player who just barked should not have that consumed against their
-- separate door-scratch allowance, or vice versa.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastDoorScratchAt`
-- table, now a NewCooldown() instance (server/cooldowns.lua) — no default
-- threshold baked in at construction since the check below reads
-- Config.DoorInteraction.scratchCooldownMs fresh on every call (matching
-- the original code's own behavior of never caching that config value).
-- playerDropped cleanup via DoorScratchCooldown.RegisterPlayerDropped()
-- below, same as before.
local DoorScratchCooldown = NewCooldown()
DoorScratchCooldown.RegisterPlayerDropped()

-- SECURITY/ABUSE FIX (exploit-tester finding, 2026-08-23): lastDoorScratchAt
-- above only rate-limits per SOURCE, so it does nothing to stop MULTIPLE
-- distinct certified accounts from each independently respecting their own
-- per-source cooldown while all hammering the SAME doorNetId — confirmed
-- reproducible as a sustained, indefinite ~1,200 broadcasts/hour flood
-- against any single real door from just one modified-but-certified client,
-- and it only gets worse with colluding accounts. This second, INDEPENDENT
-- cooldown is keyed by the resolved doorNetId instead of src — BOTH this
-- table and lastDoorScratchAt above must pass their cooldown check for a
-- broadcast to fire: lastDoorScratchAt stops one player spamming across many
-- doors, this one stops many (possibly colluding) players hammering one
-- door. Reuses Config.DoorInteraction.scratchCooldownMs rather than
-- introducing a separate constant — the abuse this closes is volume of
-- broadcasts for a given door, which scratchCooldownMs already expresses
-- ("how often should this door plausibly make this sound"); a distinct,
-- larger value isn't obviously better since a single legitimate K9 handler
-- is already expected to scratch the same real door at most once per
-- scratchCooldownMs, so the per-door and per-source windows naturally
-- coincide in the common, non-abusive case.
--
-- Unlike lastDoorScratchAt (cleaned up in the playerDropped handler below,
-- since it's keyed by a player source) or TrackableLog in
-- server/tracking.lua (which uses a periodic prune thread since its entries
-- are keyed by coordinate/timestamp, not by player), doorNetId has no
-- natural per-connection cleanup hook — a door doesn't disconnect. Following
-- server/tracking.lua's own PruneTrackableLogs precedent (a periodic sweep
-- thread, same shape, see the :StartSweep call below) rather than
-- prune-on-access, since a dedicated thread keeps the eviction logic in one
-- place and doesn't add work to the hot broadcast path above.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastDoorScratchAtByDoor`
-- table + `PruneDoorScratchCooldowns` sweep thread, now a NewCooldown()
-- instance with :StartSweep (server/cooldowns.lua) — same doorNetId key,
-- same staleness rule, same interval, behavior unchanged.
local DoorScratchByDoorCooldown = NewCooldown()

-- Prune interval for DoorScratchByDoorCooldown. Deliberately much coarser
-- than server/tracking.lua's TRACKABLE_LOG_PRUNE_INTERVAL_MS (15000ms) —
-- that table backs a live distance search so staleness has a correctness
-- cost; this table only backs a rate-limit check, so a stale entry
-- lingering a little past its usefulness window costs nothing but a few
-- bytes. 10x Config.DoorInteraction.scratchCooldownMs's default (3000ms)
-- keeps the table from growing unbounded across a long-running server (one
-- entry per distinct door ever scratched) without running the sweep
-- needlessly often.
local DOOR_SCRATCH_COOLDOWN_PRUNE_INTERVAL_MS = 30000

-- Drops any DoorScratchByDoorCooldown entry whose cooldown has already
-- expired — once (now - loggedAt) >= scratchCooldownMs, the entry can no
-- longer affect the cooldown check below, so it's safe to evict.
--
-- PERFORMANCE AUDIT NOTE (this pass, considered and DELIBERATELY left
-- ungated): a performance pass flagged this thread starting unconditionally
-- at file load, rather than behind Config.Features.DoorInteraction, as a
-- convention inconsistency against relayBark's/relayDoorScratch's own
-- per-call `if not Config.Features.X then return end` gating below. Gating
-- the *start* of this thread on that flag was considered and rejected:
-- server/runtimecontrol.lua's own FEATURE_TIERS registers
-- `DoorInteraction = { tier = 'live' }` specifically BECAUSE this feature's
-- registrations (this RegisterNetEvent below, this thread) are never
-- gated at load time and its handler re-checks the flag on every
-- invocation instead — that tier is runtimecontrol.lua's own PROMISE to an
-- operator that flipping this flag ON via `/qbx_k9unit:server:
-- runtimeSetFeature` (Config.Features.RuntimeFeatureControl) takes effect
-- immediately, with `restartRequired = false`, never "only after this
-- resource restarts." A `if Config.Features.DoorInteraction then
-- DoorScratchByDoorCooldown.StartSweep(...) end` guard here would be
-- evaluated exactly once, at this file's own load time -- an operator who
-- starts with the feature off, then flips it on live later in the same
-- session, would get a fully working relayDoorScratch (that handler's own
-- gate is genuinely live) but a sweep thread that NEVER starts for the
-- rest of that server's uptime, silently reopening the exact unbounded
-- per-doorNetId growth this table's own SECURITY/ABUSE FIX comment above
-- exists to bound -- a strictly worse outcome than the flagged
-- inconsistency itself. Left ungated instead: genuinely free when the
-- feature is off (DoorScratchByDoorCooldown's store is only ever written
-- to from inside relayDoorScratch below, which already no-ops before ever
-- calling .Touch(...) when the feature is off, so this sweep walks a
-- permanently empty table every 30s until/unless the feature is on) --
-- the "no unbounded trap" rule this resource applies to every cleanup path
-- cuts the other way here: this IS the cleanup path, and it must not be
-- the thing gated on a feature flag that can flip live.
DoorScratchByDoorCooldown.StartSweep(DOOR_SCRATCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) >= Config.DoorInteraction.scratchCooldownMs
end)

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.DoorInteraction
--- flag) is already checked by relayDoorScratch below, before this function
--- is ever reached.
---   2. an explicit block.DoorInteraction grant -> DENY
---   3. DoorInteraction listed in RequireGrant -> ALLOW only with an active
---      feature.DoorInteraction grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsDoorInteractionPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.DoorInteraction') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.DoorInteraction == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.DoorInteraction') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Relays a door-scratch sound to every client so anyone with the door
--- entity streamed in hears it. Gated by Config.Features.DoorInteraction AND
--- HasK9Access(source) — both re-checked HERE, server-side, same standard as
--- relayBark above (DEVELOPER_REFERENCE.md §3's "disabled feature must be a no-op
--- server-side" requirement).
--- @param doorNetId number
RegisterNetEvent('qbx_k9unit:server:relayDoorScratch', function(doorNetId)
    local src = source

    if not Config.Features.DoorInteraction then return end -- silent no-op
    if type(doorNetId) ~= 'number' then return end -- defensive: never trust client payload shape
    if not HasK9Access(src) then return end -- reuse the global from server/certifications.lua, do not re-derive the job/cert check here

    -- PER-PERSON FEATURE CONTROL -- see IsDoorInteractionPermittedForCitizenId
    -- above. Checked BEFORE either cooldown below is ever consumed, matching
    -- relayBark's own "cheapest/no-side-effect checks first" discipline, so a
    -- blocked K9 never burns their own scratch cooldown for a request that
    -- was always going to be refused. Silent no-op on denial, matching every
    -- other rejection branch in this handler. This is a one-shot relay with
    -- no ongoing state of its own to strand -- nothing here is a
    -- termination/cleanup path, so gating the whole action is safe.
    do
        local player = exports.qbx_core:GetPlayer(src)
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid
        if not citizenid or not IsDoorInteractionPermittedForCitizenId(citizenid) then return end
    end

    -- Gap closed per DEVELOPER_REFERENCE.md §9 item 16 (see comment above this handler):
    -- resolve the claimed netId to a live entity and confirm it actually
    -- exists AND is an object (GetEntityType == 3 — door props are
    -- objects; 1 = ped, 2 = vehicle) before doing anything else with it.
    -- DEVELOPER_REFERENCE.md near-term item 2: was this handler's own inline
    -- "NetworkGetEntityFromNetworkId -> 0/DoesEntityExist guard" followed,
    -- a few lines further down, by a SEPARATE `GetEntityType ~= 3` check —
    -- both are now server/entities.lua's shared ResolveNetworkEntity(),
    -- called with expectedEntityType = 3 to fold the type restriction in
    -- as one call. Behavior unchanged: still object-only, still fails
    -- closed on any mismatch, never trust the client's own
    -- IsLikelyDoorEntity() UX gate as the real check.
    local doorEntity = ResolveNetworkEntity(doorNetId, 3)
    if not doorEntity then
        return -- silent no-op: not a real, currently-existing object entity
    end

    -- ...and confirm the caller is actually near the entity they're
    -- claiming to be scratching at, not just naming an arbitrary networked
    -- entity anywhere on the map (any vehicle, any player's ped, etc.).
    -- Cheap defense-in-depth on top of the object-type check above (closes
    -- the narrower residual case the pre-implementation review flagged: an
    -- attacker who is genuinely standing within interactDistance of a real
    -- bystander could otherwise still supply that bystander's own ped/
    -- vehicle netId — the object-type check above already rejects that
    -- regardless, but this proximity check is independent, not redundant,
    -- since a real door object could still be far away).
    local ped = GetPlayerPed(src)
    local dist = #(GetEntityCoords(ped) - GetEntityCoords(doorEntity))
    if dist > (Config.DoorInteraction.interactDistance + DOOR_SCRATCH_DISTANCE_TOLERANCE) then
        return -- silent no-op: claimed door is not actually near the caller
    end

    -- Both checks must run BEFORE either stamps (preserved from the
    -- pre-extraction code: :IsOnCooldown never mutates, so both reads below
    -- happen against whatever was stamped by a PRIOR call, never against
    -- each other) — only :Touch both once both checks pass.
    local now = GetGameTimer()
    if DoorScratchCooldown.IsOnCooldown(src, Config.DoorInteraction.scratchCooldownMs, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    -- exploit-tester finding (2026-08-23, see DoorScratchByDoorCooldown's
    -- own doc comment above for the full writeup): the per-source check
    -- above does nothing to stop MULTIPLE certified sources from
    -- independently hammering this SAME door, each staying under their own
    -- per-source cooldown. Both checks must pass before a broadcast fires.
    if DoorScratchByDoorCooldown.IsOnCooldown(doorNetId, Config.DoorInteraction.scratchCooldownMs, now) then
        return -- silent no-op: this specific door was already scratched recently by ANY source
    end

    DoorScratchCooldown.Touch(src, now)
    DoorScratchByDoorCooldown.Touch(doorNetId, now)

    -- DELIBERATE broadcast to EVERYONE (-1), not distance-filtered to nearby
    -- clients server-side, and NOT the pattern to copy if you're touching
    -- server/search.lua's contraband-alert broadcast instead: a door's
    -- location carries no person/vehicle identity to leak (DEVELOPER_REFERENCE.md §11.4
    -- item 5: "No inventory/lock-state reveal of any kind — purely a sound
    -- cue"), unlike a search alert which does need scope-limiting to avoid
    -- broadcasting a specific player/vehicle's search outcome resource-wide.
    -- This mirrors relayBark's own -1 broadcast exactly, on purpose — do not
    -- "fix" this later by pattern-matching off the search-alert's
    -- distance-filtering requirement.
    TriggerClientEvent('qbx_k9unit:client:playDoorScratch', -1, doorNetId)
end)

--- @param source number
--- @return boolean
local function IsAlreadyLeashed(source)
    return LeashPairs[source] ~= nil
end

--- Deliberately NARROWER than the model-OR-role widened check
--- (initiatorIsK9/targetIsK9) CheckLeashEligibility computes below -- used
--- ONLY to decide the "both parties are a K9" rejection, never the
--- "neither party is a K9" one. See that function's own "BOTH-ARE-K9 CASE"
--- comment for the exact gap this closes (owner-directed, this pass: two
--- K9s could leash each other, with one silently cast as the officer/
--- handler, since the widened check only ever rejects "neither").
--- Duplicated from server/partnership.lua's identical helper of the same
--- name rather than shared -- same tiny, self-contained, no-shared-state
--- reasoning as this file's/that file's other small duplicated helpers
--- (e.g. IsDuplicateKeyError); see that copy's own doc comment for the
--- full "why role, not model, not HasK9Access" reasoning, which applies
--- verbatim here:
---   - Ped MODEL is NOT evidence of "genuinely a K9" -- a
---     Config.Peds-listed species can be worn by an ordinary department
---     officer for reasons unrelated to K9 access (this resource's own
---     K9 role/model decoupling promise -- "everything works on any ped"
---     -- runs both directions: a K9 can look human, AND a handler can
---     look like the configured K9 species). Folding model in here would
---     misclassify that officer as a second K9 and wrongly refuse an
---     otherwise-legitimate pairing.
---   - HasK9Access is NOT evidence either, in the opposite direction: it
---     is deliberately WIDER than "is the K9" (High Command /
---     autoAccessGrade bypasses -- see server/appearance.lua's own header
---     -- can make it true for a citizenid who has never held the K9 role
---     at all).
--- HasK9Role is server/appearance.lua's own documented answer to "does
--- this citizenid actually hold the K9 identity," independent of current
--- appearance and independent of any blanket access bypass -- exactly the
--- primitive this question needs. FALLS BACK to IsConfiguredK9Model if
--- HasK9Role doesn't exist (mirrors initiatorIsK9/targetIsK9's own
--- `type(...) == 'function'` guard below) -- the pre-decoupling world's
--- only signal for "is this citizenid a K9" -- rather than unconditionally
--- returning `false`, which would silently disable this whole rejection
--- instead of degrading the same way every other check here already does.
--- @param src number
--- @param ped number
--- @return boolean
local function IsGenuinelyK9Party(src, ped)
    if type(HasK9Role) == 'function' then
        return HasK9Role(src)
    end
    return IsConfiguredK9Model(GetEntityModel(ped))
end

--- Human-readable rejection messages for CheckLeashEligibility's `reason`
--- return value.
local LEASH_REJECT_MESSAGES = {
    feature_disabled          = locale('leash.feature_disabled'),
    invalid_target            = locale('leash.invalid_target'),
    already_leashed           = locale('leash.already_leashed'),
    offline                   = locale('common.target_no_longer_online'),
    too_far                   = locale('leash.too_far'),
    no_k9_party               = locale('common.no_k9_party'),
    not_certified             = locale('common.k9_not_certified'),
    officer_not_in_department = locale('common.handler_not_in_department'),
    -- PER-PERSON FEATURE CONTROL denial (config.lua's Config.FeatureControl
    -- -- an explicit 'block.<Name>' row OR 'RequireGrant' listed without an
    -- active 'feature.<Name>' grant; see CheckLeashEligibility's own
    -- IsLeashMechanicsPermittedForCitizenId call below). Reuses the EXISTING
    -- leash.reject_fallback locale key rather than adding a new one --
    -- matches server/combat.lua's own COMBAT_REJECT_MESSAGES.permission_denied
    -- entry: "an explicit mapping is kept here... so a reader of this table
    -- sees the reason was deliberately handled, not merely unmapped."
    permission_denied         = locale('leash.reject_fallback'),
    -- 'both_k9' (see CheckLeashEligibility's own "BOTH-ARE-K9 CASE" comment,
    -- and IsGenuinelyK9Party's doc comment, above) DOES get its own entry,
    -- deliberately NOT reusing 'no_k9_party's message: "neither of you is a
    -- K9" and "you are both K9s" are different problems with different
    -- remedies, and telling the wrong one sends someone looking in the
    -- wrong place. common.both_k9 (shared with server/partnership.lua's
    -- identical PARTNERSHIP_REJECT_MESSAGES entry, same as
    -- common.no_k9_party/common.k9_not_certified/common.handler_not_in_department
    -- above) shipped to locales/en.json for exactly this reason.
    both_k9                   = locale('common.both_k9'),
}

--- @param reason string?
--- @return string
local function LeashRejectReasonMessage(reason)
    return LEASH_REJECT_MESSAGES[reason] or locale('leash.reject_fallback')
end

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.LeashMechanics
--- flag) is already checked at the top of CheckLeashEligibility below,
--- before this function is ever reached. Consulted for BOTH parties of a
--- prospective leash pair (the K9-role party AND the officer/handler-role
--- party) inside CheckLeashEligibility -- never inside doDetachLeash/
--- detachLeash/ForceDetachLeashForSource/ForceDetachOfficerLeashForSource,
--- this feature's own "no unbounded trap" exit paths ("detach a leash" is
--- one of the specific termination actions this pass is required to leave
--- unconditional).
---   2. an explicit block.LeashMechanics grant -> DENY
---   3. LeashMechanics listed in RequireGrant -> ALLOW only with an active
---      feature.LeashMechanics grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsLeashMechanicsPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.LeashMechanics') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.LeashMechanics == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.LeashMechanics') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Shared eligibility/proximity checks for forming a leash pair, run at
--- BOTH request time and accept time (see respondLeashAttach's TOCTOU
--- note below) so nothing that changed in between slips through.
--- @param initiatorSrc number
--- @param targetSrc number
--- @return boolean ok
--- @return number? k9Src        -- whichever of the two is the K9-role party
--- @return number? officerSrc   -- the other party
--- @return string? reason       -- present when ok == false
local function CheckLeashEligibility(initiatorSrc, targetSrc)
    if not Config.Features.LeashMechanics then
        return false, nil, nil, 'feature_disabled'
    end

    if type(initiatorSrc) ~= 'number' or type(targetSrc) ~= 'number' or initiatorSrc == targetSrc then
        return false, nil, nil, 'invalid_target'
    end

    if IsAlreadyLeashed(initiatorSrc) or IsAlreadyLeashed(targetSrc) then
        return false, nil, nil, 'already_leashed'
    end

    local initiatorPed = GetPlayerPed(initiatorSrc)
    local targetPed = GetPlayerPed(targetSrc)
    if initiatorPed == 0 or targetPed == 0 then
        return false, nil, nil, 'offline'
    end

    -- SAME-IDENTITY GUARD, BY CITIZENID (owner-directed, this pass; mirrors
    -- server/partnership.lua's identical CheckPartnershipEligibility guard
    -- -- see that copy's own doc comment for the full writeup): the
    -- `initiatorSrc == targetSrc` check above only rejects self-targeting
    -- by SERVER ID -- but a server id is a per-connection number FiveM
    -- recycles, not a stable identity (see e.g. this file's own
    -- playerDropped handler scanning PendingLeashRequests specifically
    -- because a freed id can be reassigned to an unrelated citizenid
    -- before a pending request's own TTL expires). The citizenid is this
    -- resource's actual identity boundary, so this is the check that
    -- actually matters if a reconnect, or a stale pending request
    -- resolving against a NEW session for the citizenid it used to name,
    -- ever produces two distinct server ids that both resolve to the same
    -- citizenid at once. LeashPairs itself stays source-keyed (this
    -- subsystem's own ephemeral, session-scoped design, per this file's
    -- header) -- this guard only prevents FORMING a pair with oneself
    -- under two different ids, it does not change how an already-formed
    -- pair is stored or torn down.
    do
        local initiatorPlayerForIdentity = exports.qbx_core:GetPlayer(initiatorSrc)
        local targetPlayerForIdentity = exports.qbx_core:GetPlayer(targetSrc)
        local initiatorCitizenidForIdentity = initiatorPlayerForIdentity and initiatorPlayerForIdentity.PlayerData
            and initiatorPlayerForIdentity.PlayerData.citizenid
        local targetCitizenidForIdentity = targetPlayerForIdentity and targetPlayerForIdentity.PlayerData
            and targetPlayerForIdentity.PlayerData.citizenid
        if not initiatorCitizenidForIdentity or not targetCitizenidForIdentity then
            return false, nil, nil, 'offline'
        end
        if initiatorCitizenidForIdentity == targetCitizenidForIdentity then
            return false, nil, nil, 'invalid_target'
        end
    end

    -- Proximity: see this file's header (and config.lua's comment on
    -- Config.LeashMaxDistance) for why the raw base leash range is reused
    -- directly here as the initiate-range check, rather than the derived
    -- pull-back/auto-detach thresholds client/movement.lua computes from
    -- it.
    local dist = #(GetEntityCoords(initiatorPed) - GetEntityCoords(targetPed))
    if dist > Config.LeashMaxDistance then
        return false, nil, nil, 'too_far'
    end

    -- Roles via live model check (never client-claimed), WIDENED (K9
    -- role/model decoupling, server/appearance.lua) to also accept a party
    -- who holds the decoupled K9 ROLE (HasK9Role) on a model
    -- Config.Peds/IsConfiguredK9Model doesn't recognize -- a human, a
    -- custom streamed ped, anything. Guarded with `type(...) == 'function'`
    -- (this file's own established soft-dependency convention -- see
    -- HasK9Access's own call sites above) rather than a load-order
    -- assumption; fails CLOSED to the pre-decoupling model-only check if
    -- server/appearance.lua is ever removed. Does not touch
    -- IsConfiguredK9Model/IsEntityModelK9 themselves -- both stay pure
    -- model predicates for the nine other authorization paths that read
    -- them, one of which (GrantCertification's own requireK9ModelForRole
    -- branch) is an operator's explicit opt-IN to a model check this
    -- widening must never silently bypass.
    local initiatorIsK9 = IsConfiguredK9Model(GetEntityModel(initiatorPed))
        or (type(HasK9Role) == 'function' and HasK9Role(initiatorSrc))
    local targetIsK9 = IsConfiguredK9Model(GetEntityModel(targetPed))
        or (type(HasK9Role) == 'function' and HasK9Role(targetSrc))

    if not initiatorIsK9 and not targetIsK9 then
        return false, nil, nil, 'no_k9_party'
    end

    -- BOTH-ARE-K9 CASE (owner-reported gap, this pass): the check above
    -- only ever rejects "NEITHER party is a K9" -- when initiatorIsK9 AND
    -- targetIsK9 are both true, the EDGE CASE tie-break just below
    -- silently assigns one of two genuine K9s the OFFICER/handler role
    -- instead of rejecting outright, and forming that pair then actually
    -- SUCCEEDS, since a K9 role-holder is typically ALSO a department
    -- member and so trivially clears officer_not_in_department too --
    -- there is nothing downstream that would otherwise catch this.
    -- "Neither of you is a K9" and "you are both K9s" are different
    -- problems with different remedies, so this gets its own reason
    -- rather than being folded into either 'no_k9_party' or the ordinary
    -- success path.
    --
    -- Deliberately does NOT reuse initiatorIsK9/targetIsK9 (the widened
    -- model-OR-role check immediately above) for THIS decision -- see
    -- IsGenuinelyK9Party's own doc comment for exactly why model must not
    -- be read as proof the OTHER party can't legitimately be the officer/
    -- handler (a real handler's ped can coincidentally be a
    -- Config.Peds-listed species for reasons that have nothing to do with
    -- them holding K9 access) and why HasK9Access alone is too WIDE for
    -- this question in the opposite direction (High Command /
    -- autoAccessGrade bypasses).
    if IsGenuinelyK9Party(initiatorSrc, initiatorPed) and IsGenuinelyK9Party(targetSrc, targetPed) then
        return false, nil, nil, 'both_k9'
    end

    -- EDGE CASE (flagged in this file's header, judgment call confirmed
    -- here): if BOTH are K9-modeled, default the REQUEST TARGET to the
    -- constrained role — whoever gets asked ends up "on the leash." Not a
    -- spec mandate, just a low-surprise default given none is specified.
    local k9Src, officerSrc
    if targetIsK9 then
        k9Src, officerSrc = targetSrc, initiatorSrc
    else
        k9Src, officerSrc = initiatorSrc, targetSrc
    end

    if not HasK9Access(k9Src) then
        return false, nil, nil, 'not_certified'
    end

    -- §6.1/§9 item 9 (Resolved): the officer/handler side must satisfy
    -- job.name ∈ Config.Departments, but does NOT need an active K9
    -- certification of their own (the cert is specifically the "I am a
    -- working K9" credential, not "I am allowed near one") — see this
    -- file's header "Role assignment" paragraph.
    local officerPlayer = exports.qbx_core:GetPlayer(officerSrc)
    local officerJob = officerPlayer and officerPlayer.PlayerData and officerPlayer.PlayerData.job
    if not officerJob or not Config.Departments[officerJob.name] then
        return false, nil, nil, 'officer_not_in_department'
    end

    -- PER-PERSON FEATURE CONTROL -- see IsLeashMechanicsPermittedForCitizenId
    -- above. Checked LAST, after every cheaper/no-side-effect check above
    -- has already passed (this function performs no mutation of its own
    -- either way, so there is no cooldown/mutex here to protect from being
    -- burned by a block -- the caller-side cooldown, LeashRequestCooldown,
    -- is consumed by requestLeashAttach only AFTER this whole function
    -- already returned ok == true). Checked for BOTH parties: a block
    -- placed on either the K9-role party OR the officer/handler-role party
    -- must refuse forming the pair.
    local k9Player = exports.qbx_core:GetPlayer(k9Src)
    local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
    local officerCitizenid = officerPlayer.PlayerData.citizenid
    if not k9Citizenid or not IsLeashMechanicsPermittedForCitizenId(k9Citizenid) then
        return false, nil, nil, 'permission_denied'
    end
    if not officerCitizenid or not IsLeashMechanicsPermittedForCitizenId(officerCitizenid) then
        return false, nil, nil, 'permission_denied'
    end

    return true, k9Src, officerSrc
end

--- Step 1 of the consent handshake: initiator asks to attach to target.
--- Does NOT form the pair — only relays a prompt to the target if the
--- request itself is currently valid.
--- @param targetServerId number
RegisterNetEvent('qbx_k9unit:server:requestLeashAttach', function(targetServerId)
    local src = source

    if type(targetServerId) ~= 'number' then
        NotifyPlayer(src, locale('leash.invalid_target'), 'error')
        return
    end

    local ok, _, _, reason = CheckLeashEligibility(src, targetServerId)
    if not ok then
        NotifyPlayer(src, LeashRejectReasonMessage(reason), 'error')
        return
    end

    -- SECURITY/UX FIX (coder-security, exploit-tester + qa-tester finding,
    -- 2026-08-23): PendingLeashRequests is a single-slot table keyed only
    -- by TARGET, with no check here for an already-live, unexpired pending
    -- request before overwriting it wholesale below. If player A requests a
    -- leash to target T, then before T responds player B (also
    -- independently eligible per CheckLeashEligibility above) requests to
    -- that SAME T, B's request used to silently clobber A's entry — A was
    -- never notified their request vanished, and if T then accepted what
    -- they believed was still A's prompt, respondLeashAttach's
    -- `pending.from == fromServerId` check would fail against B's
    -- now-stored value, leaving T with a generic "no longer valid" error
    -- and A with nothing at all. This is a denial-of-service/UX-integrity
    -- gap on the REQUEST phase only — it does not weaken the leash
    -- system's consent/detach guarantees, since respondLeashAttach's
    -- match+TTL check still requires the correct initiator either way.
    -- Reject the SECOND request outright rather than silently overwriting
    -- the first: same "notify the caller of their own rejected action"
    -- convention CheckLeashEligibility's rejection path above already
    -- uses, rather than trying to notify a THIRD party (A) about an action
    -- they themselves didn't take. Checked BEFORE consuming the rate limit
    -- below so a legitimately-rejected duplicate doesn't burn the caller's
    -- own cooldown allowance.
    local existingPending = PendingLeashRequests[targetServerId]
    if existingPending and GetGameTimer() <= existingPending.expiresAt then
        NotifyPlayer(src, locale('leash.pending_request_exists'), 'error')
        return
    end

    -- Rate limit — see LEASH_REQUEST_COOLDOWN_MS above.
    if not LeashRequestCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    PendingLeashRequests[targetServerId] = { from = src, expiresAt = GetGameTimer() + LEASH_REQUEST_TTL_MS }

    TriggerClientEvent('qbx_k9unit:client:leashAttachRequest', targetServerId, src)
    NotifyPlayer(src, locale('leash.request_sent'), 'info')
end)

--- Step 2 of the consent handshake: target's response.
--- @param fromServerId number
--- @param accepted boolean
RegisterNetEvent('qbx_k9unit:server:respondLeashAttach', function(fromServerId, accepted)
    local src = source -- the target, responding

    if type(fromServerId) ~= 'number' then return end

    -- SECURITY FIX (coder-security, final pass): the decline branch below
    -- used to fire NotifyPlayer(fromServerId, ...) — an entirely
    -- client-supplied, unvalidated number — BEFORE ever checking that a
    -- real pending request from that id existed, and unconditionally
    -- cleared PendingLeashRequests[src] regardless of whether fromServerId
    -- matched the actual pending request's initiator. That let a modified
    -- client call this event with an arbitrary/every online server id and
    -- accepted = false, with NO rate limit anywhere on this path, to spam
    -- every other connected player with a fake "Your leash request was
    -- declined" notification indefinitely — and, as a side effect, silently
    -- swallow a genuine pending request aimed at `src` by citing a
    -- different id, so the real requester never learns their request was
    -- consumed. Validate the pending request FIRST (same match+TTL check
    -- previously only run on the accept path) and only notify/consume once
    -- confirmed genuine; an invalid/spoofed/expired claim now only ever
    -- results in an error notice to the caller themselves (self-limiting —
    -- rate abuse only degrades their own client, not anyone else's).
    local pending = PendingLeashRequests[src]
    local verifiedMatch = pending ~= nil and pending.from == fromServerId

    -- BUGFIX (coder-backend, 2026-08-25): this branch used to unconditionally
    -- run `PendingLeashRequests[src] = nil` whenever `not verifiedMatch`,
    -- which also covers the case where a REAL, still-live pending entry
    -- exists for `src` but simply belongs to a DIFFERENT initiator than the
    -- one named in this call. `src` is `source` here and therefore
    -- unspoofable, but no attacker is even required to hit this: an
    -- ordinary duplicate/delayed client response (a UI double-fire, or a
    -- stale queued response naming an OLD, already-resolved fromServerId)
    -- would silently destroy a fresh, completely unrelated, still-valid
    -- request from a different initiator that was created in the meantime —
    -- with that real initiator never told their request just vanished. Only
    -- clear the slot once we've confirmed it is genuinely the entry this
    -- call claims to be about (verifiedMatch) AND it has actually expired.
    -- An unmatched claim — whether because nothing is pending at all, or
    -- because a DIFFERENT, unrelated request occupies the slot — must leave
    -- that slot exactly as it was; there's nothing to leak either way, since
    -- an unmatched-but-genuinely-expired entry left in place here is still
    -- bounded by its own TTL and gets naturally overwritten the next time
    -- requestLeashAttach's own expiry check (above) runs against it.
    if not verifiedMatch then
        NotifyPlayer(src, locale('leash.request_no_longer_valid_self'), 'error')
        -- Deliberately no echo to fromServerId here — this is exactly the
        -- unmatched/spoofed-claim case the coder-security fix above closes;
        -- echoing would reintroduce an arbitrary-target notify driven by a
        -- caller-supplied id that was never actually verified against
        -- anything real.
        return
    end

    if GetGameTimer() > pending.expiresAt then
        PendingLeashRequests[src] = nil -- confirmed genuine match, just too late: safe to drop
        NotifyPlayer(src, locale('leash.request_no_longer_valid_self'), 'error')
        -- Only echo the "no longer valid" notice back to fromServerId when
        -- it's a VERIFIED match to a real (if now-expired) pending request
        -- from that exact id — never for an unmatched/spoofed claim, or
        -- this reintroduces the same arbitrary-target notify the fix above
        -- closes.
        NotifyPlayer(fromServerId, locale('leash.request_no_longer_valid_initiator'), 'error')
        return
    end

    PendingLeashRequests[src] = nil -- consumed either way, accept or decline, now that it's confirmed genuine

    if not accepted then
        NotifyPlayer(fromServerId, locale('leash.request_declined'), 'info')
        return
    end

    -- RE-VALIDATE — do not trust that nothing changed since the request
    -- was sent (classic TOCTOU: either party could have disconnected,
    -- moved out of range, or gotten leashed to someone else in the
    -- meantime).
    local ok, k9Src, officerSrc, reason = CheckLeashEligibility(fromServerId, src)
    if not ok then
        NotifyPlayer(fromServerId, LeashRejectReasonMessage(reason), 'error')
        NotifyPlayer(src, LeashRejectReasonMessage(reason), 'error')
        return
    end

    LeashPairs[k9Src] = { partner = officerSrc, isK9 = true }
    LeashPairs[officerSrc] = { partner = k9Src, isK9 = false }

    TriggerClientEvent('qbx_k9unit:client:leashAttached', k9Src, officerSrc, true)  -- isConstrained = true
    TriggerClientEvent('qbx_k9unit:client:leashAttached', officerSrc, k9Src, false) -- isConstrained = false
end)

--- Internal detach helper — clears both halves of a pairing (if one exists)
--- and broadcasts the detach event to both parties with the given reason.
--- Shared by the player-initiated detachLeash event below,
--- ForceDetachLeashForSource/ForceDetachOfficerLeashForSource
--- (server-triggered, e.g. cert revocation/department change), the
--- playerDropped disconnect cleanup, and the death-detection thread further
--- below (DEATH-DETECTION FIX, this pass — see that thread's own doc
--- comment for the full writeup) so there is exactly one place that mutates
--- LeashPairs on detach. Every one of those four call sites passes this
--- function a `src` and lets IT resolve `pairing.partner` and clear both
--- directions — none of them ever reaches into LeashPairs directly, which
--- is the actual discipline this comment describes, not merely a count of
--- callers.
--- @param src number
--- @param reason string
--- @return boolean detached -- false if `src` wasn't leashed to anyone (no-op)
local function doDetachLeash(src, reason)
    local pairing = LeashPairs[src]
    if not pairing then return false end -- no-op, not an error
    local partner = pairing.partner

    LeashPairs[src] = nil
    LeashPairs[partner] = nil

    TriggerClientEvent('qbx_k9unit:client:leashDetached', src, reason)
    TriggerClientEvent('qbx_k9unit:client:leashDetached', partner, reason)
    return true
end

--- Either party detaches unilaterally, no consent required. No-op if the
--- caller isn't currently leashed to anyone.
RegisterNetEvent('qbx_k9unit:server:detachLeash', function()
    doDetachLeash(source, 'detached')
end)

--- Resource-global (no `local`) — exposed for server/certifications.lua to
--- call when a K9-role party's certification is revoked (manually or via
--- the QBCore:Server:OnJobUpdate auto-revoke) while they're actively
--- leashed. DEVELOPER_REFERENCE.md §1/§4.4: losing department employment or certification
--- must end K9 access "immediately" — without this, an already-formed
--- leash pairing would keep running untouched until someone manually
--- detaches or the distance safety-valve trips, even though the K9-role
--- party is no longer eligible per CheckLeashEligibility. No-op if `src`
--- isn't currently leashed to anyone (covers the common case where the
--- revoked player never had an active pairing at all).
---
--- Regression-test fix: role-blind by id membership alone is not enough.
--- Certifications.lua's callers intend this to fire specifically when "a
--- K9-role party's certification transitions from active to revoked" (see
--- this function's own doc comment above and certifications.lua's
--- FILE-TO-FILE CONTRACT), but HasK9Access deliberately never checks ped
--- model, so a revoked citizenid can resolve to a server id that is
--- CURRENTLY the officer/handler-role party of an unrelated, still-valid
--- pairing. Detaching that pairing would be an incorrect side effect of an
--- unrelated cert revocation. Only actually detach when `src` is the
--- K9-role (`isK9 = true`) half of its own pairing; if `src` is a
--- participant but only in the officer/handler role, do nothing — their
--- revoked cert doesn't affect a leash they're merely anchoring, not being
--- constrained by.
--- @param src number
--- @param reason string?
function ForceDetachLeashForSource(src, reason)
    if type(src) ~= 'number' then return false end

    local pairing = LeashPairs[src]
    if not pairing or not pairing.isK9 then return false end -- not leashed, or leashed only as the officer/handler role — no-op

    return doDetachLeash(src, reason or 'certification_revoked')
end

--- Resource-global (no `local`) — exposed for server/certifications.lua's
--- QBCore:Server:OnJobUpdate handler to call as a SECOND, INDEPENDENT check
--- from ForceDetachLeashForSource above. An officer/handler-role leash
--- party never holds a K9 certification of their own (DEVELOPER_REFERENCE.md §9 item 9 —
--- their eligibility is pure Config.Departments membership, not a cert),
--- so no certification-revocation path can ever observe them losing
--- eligibility; only a job/department change can. Mirrors
--- ForceDetachLeashForSource's role check but for the opposite role: only
--- actually detaches when `src` is currently the officer/handler-role
--- (`isK9 = false`) party of its pairing. No-op if `src` isn't currently
--- leashed to anyone, or is leashed but as the K9-role party (that case is
--- covered by ForceDetachLeashForSource / certification revocation
--- instead, not this function).
--- @param src number
--- @param reason string?
function ForceDetachOfficerLeashForSource(src, reason)
    if type(src) ~= 'number' then return false end

    local pairing = LeashPairs[src]
    if not pairing or pairing.isK9 then return false end -- not leashed, or leashed as the K9-role party — no-op

    return doDetachLeash(src, reason or 'department_changed')
end

--- DEATH-DETECTION FIX (this pass, coder-frontend — audit-flagged gap:
--- confirmed by a full read of this file during the visible-leash work
--- (client/leashvisual.lua's own header CLEANUP section, "Either player
--- dying" row) that LeashPairs had NO death handler touching it at all —
--- no `wasted`/death-shaped event of any kind was ever consulted here.
--- Every OTHER termination path this file's own header lists (manual
--- detach, certification revocation, department change, disconnect) already
--- funnels through doDetachLeash; death did not, so a K9 or handler who
--- died mid-leash stayed leashed indefinitely (or until whichever OTHER
--- termination path happened to fire — e.g. the constrained party's own
--- distance safety-valve, client/movement.lua, once a corpse stopped being
--- dragged along). client/leashvisual.lua's own rope/handle-prop cleanup
--- already self-heals on death (it polls IsEntityDead() independently and
--- clears its OWN rendering either way — see that file's header), which
--- made the underlying gap WORSE, not better: the rope disappeared while
--- LeashPairs, and therefore the real elastic movement restriction on
--- client/movement.lua's constrained side, silently persisted — a mechanic
--- with nothing on screen to show for it.
---
--- DETECTION METHOD — mirrors server/defense.lua's own `IsHandlerDown`
--- precedence EXACTLY (same override, same K9Compat ambulance-adapter
--- fallback, same metadata/health floor), not reinvented: both LeashPairs
--- roles are ALWAYS a real connected player (never an NPC, unlike
--- server/combat.lua's targets), so the SAME "is this specific connected
--- player currently down" signal server/defense.lua already built for
--- HandlerDownDefense is the right, idiomatic tool here too — a raw
--- GetEntityHealth-only threshold (server/combat.lua's own
--- PED_DEAD_HEALTH_THRESHOLD approach, correct THERE because an NPC target
--- has no framework metadata to read at all) would false-positive on an
--- ordinary firefight dip to ~90 HP that a bandage clears a moment later,
--- which for THIS mechanic is a materially worse false positive than for
--- combat.lua's bounded, seconds-long holds: reforming a leash requires the
--- WHOLE consent handshake again, not just a quick re-request.
--- `Config.Combat.PropDragging.IsPlayerDownedOverride` is REUSED here
--- DELIBERATELY, a third time (server/combat.lua's own PropDragging is the
--- first consumer, server/defense.lua's HandlerDownDefense is the second,
--- both already reusing this SAME field rather than each adding a
--- dedicated one — see server/defense.lua's own header for the "one shared
--- per-server integration point" rationale this follows) — an operator who
--- has already wired this once, for either existing mechanic, gets correct
--- leash-death detection for free, with nothing new to configure.
--- FAILS CLOSED on an override error (treated as "not down" THIS tick) —
--- same posture as IsHandlerDown, and safe here for the identical reason:
--- this runs on a REPEATING poll (LEASH_DEATH_CHECK_INTERVAL_MS below), not
--- an edge-triggered one-shot, so an override that errors once is simply
--- retried next tick, never a permanent trap.
--- @param src number
--- @param ped number
--- @return boolean dead
local function IsLeashPartyDead(src, ped)
    local override = Config.Combat.PropDragging.IsPlayerDownedOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, src)
        if not ok then
            print(('[qbx_k9unit] main.lua: Config.Combat.PropDragging.IsPlayerDownedOverride errored for source %s: %s -- treating as NOT down this tick'):format(src, tostring(result)))
            return false
        end
        return result == true
    end

    local ambulanceDowned = K9Compat.Get('ambulance').IsDowned(src)
    if ambulanceDowned == true then return true end

    -- Metadata half is skipped when the adapter already confirmed `false`
    -- (provably redundant — see server/defense.lua's own IsHandlerDown doc
    -- comment for why, identical reasoning applies verbatim here), never
    -- the raw-health half below.
    local player = exports.qbx_core:GetPlayer(src)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if ambulanceDowned ~= false and type(metadata) == 'table'
        and (metadata.isdead == true or metadata.inlaststand == true) then
        return true
    end

    -- Final floor, same threshold/reasoning as server/combat.lua's own
    -- PED_DEAD_HEALTH_THRESHOLD (100, the CPed "already dead" convention —
    -- see that file's own doc comment for the primary-source verification
    -- that IsEntityDead/IsPedDeadOrDying have no FXServer server
    -- registration at all, which is exactly why this is a raw health read
    -- rather than either of those natives) — a LOCAL constant here, not a
    -- shared cross-file one: this is an engine-wide ped mechanic, not
    -- something either file's own logic depends on the other agreeing with
    -- at runtime, and copying a small, stable literal costs nothing extra.
    return ped ~= 0 and GetEntityHealth(ped) <= 100
end

-- LEASH_DEATH_CHECK_INTERVAL_MS: 2s. Not per-frame (this is a correctness
-- backstop, not a real-time constraint — client/leashvisual.lua's own
-- visual cleanup already reacts near-instantly to leashDetached once THIS
-- thread actually fires it, so the player-visible rope disappears within
-- one MONITOR_TICK_MS -- 1s -- of that file's own poll after this one
-- detaches the pairing), and this table is typically tiny (one entry per
-- two participants) so the per-tick cost of one more GetPlayerPed +
-- IsLeashPartyDead per participant is negligible even at this cadence.
-- FILE-LOCAL, not Config -- same "security/correctness floor, not an
-- operator balance dial" reasoning this resource's own established
-- convention already applies to comparable constants elsewhere (e.g.
-- server/combat.lua's MAINTENANCE_INTERVAL_MS, also a fixed, uncofigurable
-- 500ms for the identical "expiry/termination enforcement must never be at
-- the mercy of an operator-tunable interval" reason).
local LEASH_DEATH_CHECK_INTERVAL_MS = 2000

-- CONFIRMED LIVE-FLIP BUG, FIXED (this pass) -- this thread used to be
-- wrapped in `if Config.Features.LeashMechanics then CreateThread(...) end`,
-- a boot-time snapshot of the flag read exactly once, at this file's own
-- load time. The stated justification ("LeashPairs can only ever receive an
-- entry via respondLeashAttach, which itself routes through
-- CheckLeashEligibility's OWN `Config.Features.LeashMechanics` gate, so with
-- the flag off LeashPairs is PROVABLY always empty, so not running this
-- thread is behaviorally identical to running it forever against an empty
-- table") was true only for as long as the flag stayed exactly what it was
-- at boot -- server/runtimecontrol.lua's own FEATURE_TIERS registry lists
-- LeashMechanics as `tier = 'live'`, and ApplyFeatureOverride mutates
-- Config.Features.* immediately and unconditionally, so an operator booting
-- with the flag off and then flipping it on live (high command, from the
-- tablet, in one click) breaks the premise: CheckLeashEligibility re-checks
-- its OWN flag fresh on every call and would start writing real entries
-- into LeashPairs, while THIS thread -- the only place a leash pairing is
-- ever auto-detached on either party's death -- would never have started,
-- for the rest of that server's uptime. A pairing that can be formed must
-- always be detachable; gating this thread's START on a boot-time flag
-- snapshot let a release path be permanently absent instead. This is a
-- TERMINATION path (this resource's "no unbounded trap" guarantee, the same
-- discipline server/combat.lua's own shared expiry thread's doc comment
-- documents for the identical bug shape it was fixed for) -- this
-- resource's own standing rule is to gate the START of a thing, never the
-- STOP, and this gate was on the stop.
--
-- MITIGATED, not masked, by client/movement.lua's own elastic pull-back
-- thread (registered unconditionally, force-detaches once distance from a
-- dead partner exceeds 1.5x LeashMaxDistance) and its onResourceStop
-- force-detach -- both already exist independently of this thread and lower
-- the worst case from "stuck forever" to "has to walk away from a corpse,"
-- but neither is a substitute for the real, immediate, server-authoritative
-- detach this thread provides once it is actually running.
--
-- FIXED the same way as combat.lua's shared expiry thread (see that
-- thread's own comment for the fuller writeup of both shapes and when each
-- applies): this thread now always starts, with NO inner flag check, unlike
-- combat.lua's sibling K9-position-history thread (which DOES need one).
-- The deciding factor there is exactly what combat.lua's own comment names
-- it as: whether the loop body is free to run with the flag off. This loop
-- iterates ONLY `pairs(LeashPairs)` -- never GetPlayers() or any other
-- always-populated collection -- and the "provably always empty" argument
-- the old gate relied on still holds exactly as before with the flag off:
-- pairs() over an empty table is a single, immediate no-op, so an idle (or
-- LeashMechanics-never-used) server pays for one LEASH_DEATH_CHECK_INTERVAL_MS
-- (2s) Wait() per tick and nothing else. Unlike combat.lua's
-- K9-position-history thread, there is no always-populated collection this
-- loop would otherwise have to scan "just in case" -- so unconditional start
-- with no inner check is the right shape here, not merely the convenient
-- one.
CreateThread(function()
    while true do
        Wait(LEASH_DEATH_CHECK_INTERVAL_MS)

        -- Iterating `pairs(LeashPairs)` while doDetachLeash clears
        -- EXISTING keys from underneath this same loop is safe per the
        -- Lua 5.4 reference manual's own explicit carve-out ("you may
        -- however modify existing fields... set existing fields to
        -- nil") -- the identical property server/combat.lua's own
        -- shared maintenance thread already relies on for its
        -- `for targetNetId, hold in pairs(ActiveHolds) do ... EndHold(...)`
        -- loop, not a new assumption introduced here.
        for src, pairing in pairs(LeashPairs) do
            -- Re-check LeashPairs[src] still equals this SAME pairing
            -- table before acting: a partner's own death, visited
            -- EARLIER in this exact same `pairs` traversal, may have
            -- already called doDetachLeash and cleared this src's own
            -- entry (both directions are cleared together) — without
            -- this guard, this iteration would go on to call
            -- doDetachLeash a SECOND time for an already-cleared src,
            -- which is a harmless no-op today (doDetachLeash itself
            -- checks `if not pairing then return false end`) but is
            -- cheaper and clearer to skip outright here.
            if LeashPairs[src] == pairing then
                local ped = GetPlayerPed(src)
                if IsLeashPartyDead(src, ped) then
                    doDetachLeash(src, 'partner_died')
                end
            end
        end
    end
end)

--- Cleans up an orphaned leash pairing if one half disconnects, so the
--- remaining party's client isn't left thinking it's still leashed to
--- someone who no longer exists. NOTE: unrelated to the old (removed)
--- K9-spawn registry's disconnect handling — this is new, ephemeral state
--- introduced specifically by the leash subsystem above.
AddEventHandler('playerDropped', function(reason)
    local src = source

    PendingLeashRequests[src] = nil -- target-side: a request aimed AT the disconnecting player

    -- DEVELOPER_REFERENCE.md item 1: BarkCooldown/LeashRequestCooldown/
    -- DoorScratchCooldown each already registered their OWN independent
    -- `playerDropped` handler via :RegisterPlayerDropped() above (see each
    -- one's own declaration), so this handler no longer clears them
    -- manually — same net effect (each drops its entry for this source),
    -- just no longer hand-written here. DoorScratchByDoorCooldown
    -- deliberately has NO cleanup here — it's keyed by doorNetId, not by
    -- this disconnecting source, so it can't be cleaned up on a
    -- player-keyed hook at all. See its own :StartSweep call above
    -- (exploit-tester finding, 2026-08-23) for how it's kept bounded
    -- instead.

    -- Initiator-side cleanup (coder-security/QA finding): PendingLeashRequests
    -- is keyed by TARGET server id, so the line above only ever clears an
    -- entry where the disconnecting player was the one being asked. It never
    -- catches the case where the disconnecting player was instead the
    -- INITIATOR of a still-open request aimed at someone else. Left
    -- unscanned, that stale entry (`.from` = this now-freed server id)
    -- survives until its TTL — and FiveM recycles numeric server ids, so a
    -- newly-connected, unrelated player could be assigned that same id
    -- before the TTL expires. If the original target then accepts,
    -- respondLeashAttach's re-validation would resolve `fromServerId` to
    -- the NEW player's live ped/job, not the original initiator's, forming
    -- a pair neither side of that stale request actually consented to.
    -- Scan-and-clear closes that window; the table is small and short-lived
    -- (30s TTL) so a linear scan here is not a performance concern.
    for targetSrc, pending in pairs(PendingLeashRequests) do
        if pending.from == src then
            PendingLeashRequests[targetSrc] = nil
        end
    end

    -- CORRECTNESS FIX (dedicated K9 pass, 2026-08-25): this used to
    -- reimplement doDetachLeash's own LeashPairs[src]/LeashPairs[partner]
    -- clear-and-broadcast sequence inline, by hand, instead of calling it —
    -- directly contradicting doDetachLeash's own doc comment above ("there
    -- is exactly one place that mutates LeashPairs on detach") and this
    -- file's FILE-TO-FILE CONTRACT header ("do not duplicate the LeashPairs
    -- mutation/broadcast logic"). Not a live behavioral bug today (both
    -- code paths clear the same two keys), but it is exactly the kind of
    -- silent fork that could reintroduce the leash-trap class of bug this
    -- subsystem's header warns about: a future change to doDetachLeash
    -- (e.g. additional cleanup, a changed broadcast payload) would silently
    -- fail to apply here, on the disconnect exit path, while every other
    -- exit path (voluntary detach, cert-revoke force-detach) picked it up.
    -- doDetachLeash also broadcasts leashDetached to `src` itself, which is
    -- a harmless no-op here (TriggerClientEvent to an already-disconnected
    -- id sends nowhere) — the original hand-written version omitted that
    -- send as a micro-optimization, not a correctness requirement.
    doDetachLeash(src, 'partner_disconnected')
end)

-- Reserved for future Phase 2+ small, access-gated K9 actions that need
-- server authority but aren't part of the certification/permission system
-- itself (e.g. a scent-reveal trigger, a contraband-alert trigger). Keep
-- server/certifications.lua scoped to grant/revoke/check/cache only.
