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
    EDGE CASE flagged, not resolved: if BOTH parties are K9-modeled and
    both hold access, which one is "constrained" is arbitrary — this
    scaffold suggests defaulting the REQUEST TARGET to the constrained
    role (i.e. whoever gets asked ends up "on the leash"), but that's a
    judgment call for coder-backend to confirm, not a spec mandate.

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

-- TODO(coder-backend): STRUCTURAL GAP flagged by coder-architect, not
-- explicit in SPEC.md itself — server/certifications.lua's cache
-- populates per-player on a player-loaded event (see that file's last
-- TODO), which only fires for players who connect/load AFTER that
-- handler is registered. On a `/restart qbx_k9unit` (or a crash-restart)
-- while players are already online, nobody re-fires that event for them,
-- so their cache entry would sit empty (= "no access") until their next
-- job change or reconnect — a certified officer could be silently locked
-- out of K9 features for the remainder of their session. Backfill here:
--   AddEventHandler('onResourceStart', function(resourceName)
--       if GetCurrentResourceName() ~= resourceName then return end
--       for _, playerId in ipairs(GetPlayers()) do
--           -- resolve citizenid + current job.name for playerId via the
--           -- qbx_core player object, then:
--           -- RefreshCertificationCache(citizenid, job.name)
--       end
--   end)
-- Confirm GetPlayers() (a server native returning connected player ids as
-- strings) is the right source here vs. an equivalent qbx_core export —
-- either is fine as long as it covers everyone already connected at the
-- moment this resource (re)starts.

--- Relays a bark to every client so anyone near the K9 entity hears it.
--- Gated by Config.Features.BasicBarkSounds AND HasK9Access(source) —
--- both re-checked HERE, server-side, regardless of whether the client UI
--- that triggered this (client/radial.lua's Bark item) already checked
--- them, per SPEC.md §3's "disabled feature must be a no-op server-side,
--- not just hidden client-side" requirement.
--- @param barkType string
RegisterNetEvent('qbx_k9unit:server:relayBark', function(barkType)
    local src = source
    -- TODO(coder-backend): SPEC.md §6.1 bark bullet + §3 (feature gating).
    --   1. if not Config.Features.BasicBarkSounds then return end -- silent no-op
    --   2. if not HasK9Access(src) then return end -- reuse the global from
    --      server/certifications.lua, do not re-derive the job/cert check here.
    --   3. local ped = GetPlayerPed(src)
    --      local netId = NetworkGetNetworkIdFromEntity(ped)
    --   4. TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType)
    --
    --   NOTE on `barkType`: no enum is defined anywhere yet in SPEC.md or
    --   config.lua — Phase 1 only needs a single generic bark per §6.1
    --   ("Basic bark sound plays on a radial-triggered 'Bark' action"),
    --   see client/radial.lua for the literal string it sends. Treat
    --   barkType as an opaque passthrough string here; don't invent a
    --   validation enum unless client/radial.lua's comment says otherwise
    --   for Phase 5's AdvancedBarkRadial.
end)

--- @param source number
--- @return boolean
local function IsAlreadyLeashed(source)
    return LeashPairs[source] ~= nil
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
    -- TODO(coder-backend): SPEC.md §6.1 leash bullet + §9 item 3b resolution.
    --   1. if not Config.Features.LeashMechanics then return false, nil, nil, 'feature_disabled' end
    --   2. if IsAlreadyLeashed(initiatorSrc) or IsAlreadyLeashed(targetSrc) then
    --          return false, nil, nil, 'already_leashed'
    --      end
    --   3. Proximity: GetEntityCoords on both peds, must be within
    --      Config.LeashMaxDistance of each other (see the "No config
    --      constant" note in this file's header for why LeashMaxDistance
    --      does double duty here).
    --   4. Determine roles via live model check (never client-claimed):
    --      local initiatorIsK9 = IsConfiguredK9Model(GetEntityModel(GetPlayerPed(initiatorSrc)))
    --      local targetIsK9 = IsConfiguredK9Model(GetEntityModel(GetPlayerPed(targetSrc)))
    --      If NEITHER is a K9 model, reject ('no_k9_party'). If BOTH are,
    --      see the header's EDGE CASE note (this scaffold suggests
    --      defaulting targetSrc to the constrained role — confirm before
    --      relying on that).
    --   5. Whichever src is the K9-role party MUST pass HasK9Access(k9Src)
    --      — reject ('not_certified') otherwise. The other party (officer
    --      role) has no access requirement per this file's header note.
    --   6. Return true, k9Src, officerSrc.
    return false, nil, nil, 'not_implemented'
end

--- Step 1 of the consent handshake: initiator asks to attach to target.
--- Does NOT form the pair — only relays a prompt to the target if the
--- request itself is currently valid.
--- @param targetServerId number
RegisterNetEvent('qbx_k9unit:server:requestLeashAttach', function(targetServerId)
    local src = source
    -- TODO(coder-backend):
    --   local ok, _, _, reason = CheckLeashEligibility(src, targetServerId)
    --   if not ok then notify src with `reason` and return end
    --   TriggerClientEvent('qbx_k9unit:client:leashAttachRequest', targetServerId, src)
    --   (Consider a short server-side pending-request expiry/timeout so a
    --   request that's never answered doesn't linger indefinitely — not
    --   spelled out in SPEC.md, coder-backend's call whether Phase 1 needs
    --   one or whether relying on the player simply not accepting is fine.)
end)

--- Step 2 of the consent handshake: target's response.
--- @param fromServerId number
--- @param accepted boolean
RegisterNetEvent('qbx_k9unit:server:respondLeashAttach', function(fromServerId, accepted)
    local src = source -- the target, responding
    -- TODO(coder-backend):
    --   if not accepted then
    --       TriggerClientEvent's the requester with a "declined" notify and return
    --   end
    --   -- RE-VALIDATE — do not trust that nothing changed since the
    --   -- request was sent (classic TOCTOU: either party could have
    --   -- disconnected, moved out of range, or gotten leashed to someone
    --   -- else in the meantime):
    --   local ok, k9Src, officerSrc, reason = CheckLeashEligibility(fromServerId, src)
    --   if not ok then notify both sides with `reason` and return end
    --   LeashPairs[fromServerId] = src
    --   LeashPairs[src] = fromServerId
    --   TriggerClientEvent('qbx_k9unit:client:leashAttached', k9Src, officerSrc, true)  -- isConstrained = true
    --   TriggerClientEvent('qbx_k9unit:client:leashAttached', officerSrc, k9Src, false) -- isConstrained = false
end)

--- Either party detaches unilaterally, no consent required. No-op if the
--- caller isn't currently leashed to anyone.
RegisterNetEvent('qbx_k9unit:server:detachLeash', function()
    local src = source
    -- TODO(coder-backend):
    --   local partner = LeashPairs[src]
    --   if not partner then return end -- no-op, not an error
    --   LeashPairs[src] = nil
    --   LeashPairs[partner] = nil
    --   TriggerClientEvent('qbx_k9unit:client:leashDetached', src, 'detached')
    --   TriggerClientEvent('qbx_k9unit:client:leashDetached', partner, 'detached')
end)

--- Cleans up an orphaned leash pairing if one half disconnects, so the
--- remaining party's client isn't left thinking it's still leashed to
--- someone who no longer exists. NOTE: unrelated to the old (removed)
--- K9-spawn registry's disconnect handling — this is new, ephemeral state
--- introduced specifically by the leash subsystem above.
AddEventHandler('playerDropped', function(reason)
    local src = source
    -- TODO(coder-backend):
    --   local partner = LeashPairs[src]
    --   if not partner then return end
    --   LeashPairs[src] = nil
    --   LeashPairs[partner] = nil
    --   TriggerClientEvent('qbx_k9unit:client:leashDetached', partner, 'partner_disconnected')
end)

-- Reserved for future Phase 2+ small, access-gated K9 actions that need
-- server authority but aren't part of the certification/permission system
-- itself (e.g. a scent-reveal trigger, a contraband-alert trigger). Keep
-- server/certifications.lua scoped to grant/revoke/check/cache only.
