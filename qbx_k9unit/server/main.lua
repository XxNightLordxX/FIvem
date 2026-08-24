--[[
    qbx_k9unit/server/main.lua

    Phase 1 scaffold only (coder-architect). REWRITTEN after SPEC.md's
    post-draft correction — the K9 is a player's own persistent character,
    so there is no spawn/despawn/registry concept for this file to own
    anymore (see server/certifications.lua's header for the full removed
    list). Later REVISED again once the requester confirmed the leash
    mechanic explicitly (consent-based attach, elastic movement restriction
    while attached, zero-consent detach, safety-valve auto-detach —
    SPEC.md §6.1, §9 item 3b resolved). This file's role:
      1. Resource-start cache backfill (see TODO below) — a structural gap
         SPEC.md doesn't call out explicitly, flagged here.
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
      Initiator (either the K9 or the officer, per SPEC.md §6.1) asks to
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
      Phase 2 (SPEC.md §11.4 item 5, phase2_notes/door_interaction.md §4.2).
      Structurally mirrors relayBark above, EXCEPT `doorNetId` names a
      DIFFERENT entity than the sender's own ped, so (unlike relayBark) this
      handler also resolves it (NetworkGetEntityFromNetworkId), confirms it
      still exists (DoesEntityExist), and confirms it's actually near the
      caller before broadcasting — closing the gap flagged in SPEC.md §9
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
      (manual detach by either side, disconnect, or the constrained
      client's own safety-valve auto-detach).

    Commands: both live in server/certifications.lua.

    Automatic path: QBCore:Server:OnJobUpdate lives in
    server/certifications.lua (§4.4).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)` and `IsConfiguredK9Model(modelHash)`,
      resource-global functions exposed by server/certifications.lua — do
      not re-implement either check here.
    - THIS FILE calls `RefreshCertificationCache(citizenid, jobName)`,
      also exposed by server/certifications.lua, from the resource-start
      backfill loop below.
    - THIS FILE exposes `ForceDetachLeashForSource(src, reason)` (resource-
      global, no `local`) for server/certifications.lua to call whenever a
      K9-role party's certification transitions from active to revoked
      (manual RevokeCertification, offline RevokeCertificationOffline, or
      the QBCore:Server:OnJobUpdate auto-revoke) while that citizenid
      currently resolves to a connected server id — SPEC.md §1/§4.4
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
    ======================================================================
    LEASH SUBSYSTEM DESIGN (per requester's confirmation, resolving
    SPEC.md §9 item 3b — supersedes the earlier "client-only state, no
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

    Role assignment: server determines which party is "the K9" (and
    therefore gets `isConstrained = true`) via the SAME live,
    server-authoritative model check used for certification grants
    (IsConfiguredK9Model + GetEntityModel(GetPlayerPed(...))), never a
    client-reported role. The K9-role party's access is checked via
    HasK9Access. The other ("handler"/officer) party does NOT need an
    active K9 certification of their own, but per SPEC.md §6.1/§9 item 9
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
-- REFACTOR_ROADMAP.md item 1: was its own hand-rolled `lastLeashRequestAt`
-- table, now a NewCooldown() instance (server/cooldowns.lua) — same
-- threshold, same per-source key, same playerDropped-based cleanup (see
-- LeashRequestCooldown.RegisterPlayerDropped() below), behavior unchanged.
local LEASH_REQUEST_COOLDOWN_MS = 1000
local LeashRequestCooldown = NewCooldown(LEASH_REQUEST_COOLDOWN_MS)
LeashRequestCooldown.RegisterPlayerDropped()

--- Sends an ox_lib notification to a specific player — see
--- server/certifications.lua's NotifyPlayer for why `ox_lib:notify` was
--- chosen over exports.qbx_core:Notify. Duplicated here rather than
--- shared across files since it's a tiny, generic UI-plumbing helper, not
--- certification/permission logic that must stay a single source of truth.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    TriggerClientEvent('ox_lib:notify', target, {
        title = 'K9 Unit',
        description = description,
        type = notifyType or 'inform',
    })
end

-- STRUCTURAL GAP backfill (flagged by coder-architect, not explicit in
-- SPEC.md itself): server/certifications.lua's cache populates per-player
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
-- and README.md, as "a hard requirement, not a toggle" -- nudge-open (not
-- yet implemented anywhere in this resource) must never be allowed to
-- function as a lockpick bypass. But as shipped it was an ordinary editable
-- boolean with nothing anywhere actually enforcing that. This is harmless
-- today (nudge-open doesn't exist yet, so the flag is inert either way),
-- but the risk config-validator flagged is real: a server owner who long
-- ago flipped it to `false` for an unrelated reason (testing, a copied
-- "permissive" example config) would silently inherit an exploit the
-- moment someone eventually implements nudge-open against this flag,
-- without anyone having deliberately, reviewedly wired it that way. Fail
-- loudly at resource start instead of silently accepting an unsafe value —
-- cheap now, before nudge-open exists, rather than after.
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
-- SPEC.md's general "spammable actions" concern even though a bark itself
-- has no other gameplay effect. A small per-player cooldown closes this
-- without needing a config addition — bark has no legitimate reason to be
-- triggered faster than this.
--
-- REFACTOR_ROADMAP.md item 1: was its own hand-rolled `lastBarkAt` table,
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

--- Relays a bark to every client so anyone near the K9 entity hears it.
--- Gated by Config.Features.BasicBarkSounds AND HasK9Access(source) —
--- both re-checked HERE, server-side, regardless of whether the client UI
--- that triggered this (client/radial.lua's Bark item) already checked
--- them, per SPEC.md §3's "disabled feature must be a no-op server-side,
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

    if not BarkCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local ped = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    -- NOTE on `barkType`: no enum is defined anywhere yet in SPEC.md or
    -- config.lua — Phase 1 only needs a single generic bark per §6.1.
    -- Treat barkType as an opaque passthrough string, don't invent a
    -- validation enum unless client/radial.lua's comment says otherwise
    -- for Phase 5's AdvancedBarkRadial. It IS still length-capped
    -- (BARK_TYPE_MAX_LENGTH above) purely as a bandwidth/abuse bound, not a
    -- content restriction — that check is independent of whether an enum
    -- ever gets added.
    TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType)
end)

-- SPEC.md §9 item 16 (Phase 2 event-contract hardening pass finding, closed
-- here as part of writing this handler for the first time, per that item's
-- own closing note that it "should be closed out as part of writing it, not
-- discovered afterward as a regression"): unlike relayBark above (which only
-- ever resolves and broadcasts the SENDER's own already-access-checked ped),
-- relayDoorScratch's `doorNetId` names a DIFFERENT entity the caller merely
-- claims to be near — neither the original §11.4 item 5 contract nor
-- phase2_notes/door_interaction.md §4.2's handler sketch called for
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
-- cooldowned actions per §11.4/phase2_notes/door_interaction.md §4.2; a
-- player who just barked should not have that consumed against their
-- separate door-scratch allowance, or vice versa.
--
-- REFACTOR_ROADMAP.md item 1: was its own hand-rolled `lastDoorScratchAt`
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
-- REFACTOR_ROADMAP.md item 1: was its own hand-rolled `lastDoorScratchAtByDoor`
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
DoorScratchByDoorCooldown.StartSweep(DOOR_SCRATCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) >= Config.DoorInteraction.scratchCooldownMs
end)

--- Relays a door-scratch sound to every client so anyone with the door
--- entity streamed in hears it. Gated by Config.Features.DoorInteraction AND
--- HasK9Access(source) — both re-checked HERE, server-side, same standard as
--- relayBark above (SPEC.md §3's "disabled feature must be a no-op
--- server-side" requirement).
--- @param doorNetId number
RegisterNetEvent('qbx_k9unit:server:relayDoorScratch', function(doorNetId)
    local src = source

    if not Config.Features.DoorInteraction then return end -- silent no-op
    if type(doorNetId) ~= 'number' then return end -- defensive: never trust client payload shape
    if not HasK9Access(src) then return end -- reuse the global from server/certifications.lua, do not re-derive the job/cert check here

    -- Gap closed per SPEC.md §9 item 16 (see comment above this handler):
    -- resolve the claimed netId to a live entity and confirm it actually
    -- exists before doing anything else with it.
    local doorEntity = NetworkGetEntityFromNetworkId(doorNetId)
    if doorEntity == 0 or not DoesEntityExist(doorEntity) then
        return -- silent no-op: not a real, currently-existing entity
    end

    -- ...and confirm the caller is actually near the entity they're
    -- claiming to be scratching at, not just naming an arbitrary networked
    -- entity anywhere on the map (any vehicle, any player's ped, etc.).
    local ped = GetPlayerPed(src)
    local dist = #(GetEntityCoords(ped) - GetEntityCoords(doorEntity))
    if dist > (Config.DoorInteraction.interactDistance + DOOR_SCRATCH_DISTANCE_TOLERANCE) then
        return -- silent no-op: claimed door is not actually near the caller
    end

    -- Cheap defense-in-depth on top of the distance check above (closes the
    -- narrower residual case the pre-implementation review flagged: an
    -- attacker who is genuinely standing within interactDistance of a real
    -- bystander could otherwise still supply that bystander's own ped/
    -- vehicle netId and have a "scratch" alert broadcast anchored to them
    -- server-wide). GetEntityType returns 1 for a ped, 2 for a vehicle, 3
    -- for an object — door props are objects, so reject anything else
    -- outright, on top of (not instead of) the proximity check above.
    if GetEntityType(doorEntity) ~= 3 then
        return -- silent no-op: claimed entity isn't an object (e.g. a ped/vehicle), never trust the client's own IsLikelyDoorEntity() UX gate as the real check
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
    -- location carries no person/vehicle identity to leak (SPEC.md §11.4
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

--- Human-readable rejection messages for CheckLeashEligibility's `reason`
--- return value.
local LEASH_REJECT_MESSAGES = {
    feature_disabled          = 'Leash mechanics are disabled on this server.',
    invalid_target            = 'Invalid leash target.',
    already_leashed           = 'One of you is already leashed to someone else.',
    offline                   = 'That player is no longer online.',
    too_far                   = 'You are too far apart to attach a leash.',
    no_k9_party               = 'Neither party is playing a recognized K9 model.',
    not_certified             = 'The K9 is not certified for K9 duty.',
    officer_not_in_department = 'The handler must be employed by an eligible department.',
}

--- @param reason string?
--- @return string
local function LeashRejectReasonMessage(reason)
    return LEASH_REJECT_MESSAGES[reason] or 'Unable to attach leash.'
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

    -- Proximity: see this file's header (and config.lua's comment on
    -- Config.LeashMaxDistance) for why the raw base leash range is reused
    -- directly here as the initiate-range check, rather than the derived
    -- pull-back/auto-detach thresholds client/movement.lua computes from
    -- it.
    local dist = #(GetEntityCoords(initiatorPed) - GetEntityCoords(targetPed))
    if dist > Config.LeashMaxDistance then
        return false, nil, nil, 'too_far'
    end

    -- Roles via live model check (never client-claimed).
    local initiatorIsK9 = IsConfiguredK9Model(GetEntityModel(initiatorPed))
    local targetIsK9 = IsConfiguredK9Model(GetEntityModel(targetPed))

    if not initiatorIsK9 and not targetIsK9 then
        return false, nil, nil, 'no_k9_party'
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

    return true, k9Src, officerSrc
end

--- Step 1 of the consent handshake: initiator asks to attach to target.
--- Does NOT form the pair — only relays a prompt to the target if the
--- request itself is currently valid.
--- @param targetServerId number
RegisterNetEvent('qbx_k9unit:server:requestLeashAttach', function(targetServerId)
    local src = source

    if type(targetServerId) ~= 'number' then
        NotifyPlayer(src, 'Invalid leash target.', 'error')
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
        NotifyPlayer(src, 'That player already has a pending leash request.', 'error')
        return
    end

    -- Rate limit — see LEASH_REQUEST_COOLDOWN_MS above.
    if not LeashRequestCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    PendingLeashRequests[targetServerId] = { from = src, expiresAt = GetGameTimer() + LEASH_REQUEST_TTL_MS }

    TriggerClientEvent('qbx_k9unit:client:leashAttachRequest', targetServerId, src)
    NotifyPlayer(src, 'Leash request sent.', 'inform')
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

    if not verifiedMatch or GetGameTimer() > pending.expiresAt then
        PendingLeashRequests[src] = nil -- drop a stale/expired entry, if any, so it doesn't linger
        NotifyPlayer(src, 'That leash request is no longer valid.', 'error')
        -- Only echo the "no longer valid" notice back to fromServerId when
        -- it's a VERIFIED match to a real (if now-expired) pending request
        -- from that exact id — never for an unmatched/spoofed claim, or
        -- this reintroduces the same arbitrary-target notify the fix above
        -- closes.
        if verifiedMatch then
            NotifyPlayer(fromServerId, 'Your leash request is no longer valid.', 'error')
        end
        return
    end

    PendingLeashRequests[src] = nil -- consumed either way, accept or decline, now that it's confirmed genuine

    if not accepted then
        NotifyPlayer(fromServerId, 'Your leash request was declined.', 'inform')
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
--- Shared by the player-initiated detachLeash event below and by
--- ForceDetachLeashForSource (server-triggered, e.g. cert revocation) so
--- there is exactly one place that mutates LeashPairs on detach.
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
--- leashed. SPEC.md §1/§4.4: losing department employment or certification
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
--- party never holds a K9 certification of their own (SPEC.md §9 item 9 —
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

--- Cleans up an orphaned leash pairing if one half disconnects, so the
--- remaining party's client isn't left thinking it's still leashed to
--- someone who no longer exists. NOTE: unrelated to the old (removed)
--- K9-spawn registry's disconnect handling — this is new, ephemeral state
--- introduced specifically by the leash subsystem above.
AddEventHandler('playerDropped', function(reason)
    local src = source

    PendingLeashRequests[src] = nil -- target-side: a request aimed AT the disconnecting player

    -- REFACTOR_ROADMAP.md item 1: BarkCooldown/LeashRequestCooldown/
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

    local pairing = LeashPairs[src]
    if not pairing then return end
    local partner = pairing.partner

    LeashPairs[src] = nil
    LeashPairs[partner] = nil

    TriggerClientEvent('qbx_k9unit:client:leashDetached', partner, 'partner_disconnected')
end)

-- Reserved for future Phase 2+ small, access-gated K9 actions that need
-- server authority but aren't part of the certification/permission system
-- itself (e.g. a scent-reveal trigger, a contraband-alert trigger). Keep
-- server/certifications.lua scoped to grant/revoke/check/cache only.
