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
      rather than trusting a client-supplied netId claim.
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

    Client events (RegisterNetEvent, server->client):
    - 'qbx_k9unit:client:playBark' (netId: number, barkType: string)
      [client/main.lua] — netId is still present here because the
      *receiving* clients need to know which entity to attach the sound
      to; it's server-resolved from the sender, not client-claimed.
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
    client-reported role. Only the K9-role party's access is checked via
    HasK9Access — SPEC.md doesn't gate the human officer partner's job at
    all for this mechanic (§1 calls them a "partnered human officer" but
    §6.1's acceptance criteria never restricts the partner's job) — Phase 1
    scaffold assumption: any nearby player may be the anchor/officer side,
    no department check on them. Flag if a same-department (or "must hold
    a job at all") requirement on the partner is actually wanted.

    IMPLEMENTATION NOTE (coder-backend): the "Role assignment" paragraph
    above is now STALE relative to SPEC.md's current text and is
    superseded below, not followed as-is — see the DEVIATION comment
    inside CheckLeashEligibility for the full reasoning. SPEC.md §6.1
    explicitly states "The non-K9 side ('handler') must also satisfy
    job.name ∈ Config.Departments" and §9 item 9 marks this **Resolved**
    (department membership required, no active K9 cert of their own
    required). That resolved text is more specific and more current than
    this header's hedge, so the implementation below enforces department
    membership on the officer/handler side. Flagging this header itself as
    needing a follow-up correction pass to stay in sync with SPEC.md,
    rather than silently leaving the contradiction for the next reader.

    EDGE CASE flagged, not resolved: if BOTH parties are K9-modeled and
    both hold access, which one is "constrained" is arbitrary — this
    scaffold suggests defaulting the REQUEST TARGET to the constrained
    role (i.e. whoever gets asked ends up "on the leash"), but that's a
    judgment call for coder-backend to confirm, not a spec mandate.
    CONFIRMED below: the request target is the constrained/K9 role when
    both are K9-modeled.

    No config constant exists yet for "max range to INITIATE an attach
    request" (Config.LeashMaxDistance is documented as the post-attach
    AUTO-DETACH threshold). This scaffold reuses Config.LeashMaxDistance
    for the initiate-range check too as a reasonable Phase 1 default —
    flag if a separate, smaller "attach range" constant is wanted instead.
]]

-- Ephemeral, in-memory only leash pairing — NOT persisted, does not
-- survive a resource restart (nor should it need to; this is a live
-- session mechanic, not part of the certification/permission system).
-- Keyed by server id (source), one entry per participant, mirrored both
-- directions: LeashPairs[a] = b and LeashPairs[b] = a while attached.
-- Local: nothing outside this file needs it directly.
local LeashPairs = {}

-- Ephemeral pending leash requests: PendingLeashRequests[targetSrc] = {
-- from = initiatorSrc, expiresAt = <GetGameTimer() timestamp> }.
-- JUDGMENT CALL (this file originally flagged a pending-request expiry as
-- optional/coder-backend's call): added so a request nobody ever answers
-- doesn't linger indefinitely available for a stale accept far later
-- (e.g. after the initiator has moved away, disconnected, or paired with
-- someone else in the meantime) — consumed (cleared) on any response,
-- valid or not. Local: nothing outside this file needs it.
local PendingLeashRequests = {}
local LEASH_REQUEST_TTL_MS = 30000

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
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.job then
                RefreshCertificationCache(Player.PlayerData.citizenid, Player.PlayerData.job.name)
            end
        end
    end
end)

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
    if not HasK9Access(src) then return end -- reuse the global from server/certifications.lua, do not re-derive the job/cert check here

    local ped = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    -- NOTE on `barkType`: no enum is defined anywhere yet in SPEC.md or
    -- config.lua — Phase 1 only needs a single generic bark per §6.1.
    -- Treat barkType as an opaque passthrough string, don't invent a
    -- validation enum unless client/radial.lua's comment says otherwise
    -- for Phase 5's AdvancedBarkRadial.
    TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType)
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

    -- Proximity: see this file's header for why LeashMaxDistance does
    -- double duty as both the post-attach auto-detach threshold and the
    -- initiate-range check.
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

    -- DEVIATION FROM THIS FILE'S OWN HEADER, FLAGGED (see the
    -- IMPLEMENTATION NOTE near the top of this file): SPEC.md §6.1 states
    -- "The non-K9 side ('handler') must also satisfy job.name ∈
    -- Config.Departments" and §9 item 9 marks this **Resolved** — department
    -- membership required on the officer/handler side, but NOT an active
    -- K9 certification of their own (the cert is specifically the "I am a
    -- working K9" credential, not "I am allowed near one"). Implementing
    -- per the resolved SPEC.md text rather than this header's older,
    -- looser "no department check" assumption.
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

    local pending = PendingLeashRequests[src]
    PendingLeashRequests[src] = nil -- consumed either way, accept or decline

    if not accepted then
        NotifyPlayer(fromServerId, 'Your leash request was declined.', 'inform')
        return
    end

    if not pending or pending.from ~= fromServerId or GetGameTimer() > pending.expiresAt then
        NotifyPlayer(src, 'That leash request is no longer valid.', 'error')
        NotifyPlayer(fromServerId, 'Your leash request is no longer valid.', 'error')
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

    LeashPairs[fromServerId] = src
    LeashPairs[src] = fromServerId

    TriggerClientEvent('qbx_k9unit:client:leashAttached', k9Src, officerSrc, true)  -- isConstrained = true
    TriggerClientEvent('qbx_k9unit:client:leashAttached', officerSrc, k9Src, false) -- isConstrained = false
end)

--- Either party detaches unilaterally, no consent required. No-op if the
--- caller isn't currently leashed to anyone.
RegisterNetEvent('qbx_k9unit:server:detachLeash', function()
    local src = source
    local partner = LeashPairs[src]
    if not partner then return end -- no-op, not an error

    LeashPairs[src] = nil
    LeashPairs[partner] = nil

    TriggerClientEvent('qbx_k9unit:client:leashDetached', src, 'detached')
    TriggerClientEvent('qbx_k9unit:client:leashDetached', partner, 'detached')
end)

--- Cleans up an orphaned leash pairing if one half disconnects, so the
--- remaining party's client isn't left thinking it's still leashed to
--- someone who no longer exists. NOTE: unrelated to the old (removed)
--- K9-spawn registry's disconnect handling — this is new, ephemeral state
--- introduced specifically by the leash subsystem above.
AddEventHandler('playerDropped', function(reason)
    local src = source

    PendingLeashRequests[src] = nil

    local partner = LeashPairs[src]
    if not partner then return end

    LeashPairs[src] = nil
    LeashPairs[partner] = nil

    TriggerClientEvent('qbx_k9unit:client:leashDetached', partner, 'partner_disconnected')
end)

-- Reserved for future Phase 2+ small, access-gated K9 actions that need
-- server authority but aren't part of the certification/permission system
-- itself (e.g. a scent-reveal trigger, a contraband-alert trigger). Keep
-- server/certifications.lua scoped to grant/revoke/check/cache only.
