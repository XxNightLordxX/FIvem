--[[
    qbx_k9unit/server/main.lua

    Phase 1 scaffold only (coder-architect). REWRITTEN after SPEC.md's
    post-draft correction — the K9 is a player's own persistent character,
    so there is no spawn/despawn/registry concept for this file to own
    anymore (see server/certifications.lua's header for the full removed
    list). This file's remaining role, deliberately kept separate from
    server/certifications.lua:
      1. Resource-start cache backfill (see TODO below) — a structural gap
         SPEC.md doesn't call out explicitly, flagged here.
      2. A home for small, access-gated K9 actions that need SOME server
         authority but aren't part of the certification/permission system
         itself — Phase 1 has exactly one of these (bark relay). Keeping
         them out of certifications.lua stops that file from turning into
         an everything-file as Phase 2+ adds more (scent-reveal trigger,
         contraband-alert trigger, etc. would land here too).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1 (full copy, see
    server/certifications.lua for the same block with more detail on the
    grant/revoke/check side; identical contract, kept in sync manually):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [server/certifications.lua]

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [server/certifications.lua]
    3. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [server/certifications.lua]
    4. 'qbx_k9unit:server:relayBark' (barkType: string) [THIS FILE]
       NOTE the signature change from the pre-correction draft: no `netId`
       argument anymore. There is no registry of "which netId belongs to
       which player" to validate against, because the K9 IS the player's
       own ped, always — so THIS FILE resolves the sender's own ped/netId
       itself (GetPlayerPed(source) -> NetworkGetNetworkIdFromEntity)
       rather than trusting a client-supplied netId claim.

    Client events (RegisterNetEvent, server->client):
    5. 'qbx_k9unit:client:playBark' (netId: number, barkType: string)
       [client/main.lua] — netId IS still present here (contract item 5),
       because the *receiving* clients need to know which entity to attach
       the sound to; it's just server-resolved from the sender now,
       instead of coming from a registry lookup.

    Commands: both live in server/certifications.lua.

    Automatic path: QBCore:Server:OnJobUpdate lives in
    server/certifications.lua (§4.4).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, a resource-global function
      exposed by server/certifications.lua — do not re-implement the
      access check here.
    - THIS FILE calls `RefreshCertificationCache(citizenid, jobName)`,
      also exposed by server/certifications.lua, from the resource-start
      backfill loop below.
]]

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

-- Reserved for future Phase 2+ small, access-gated K9 actions that need
-- server authority but aren't part of the certification/permission system
-- itself (e.g. a scent-reveal trigger, a contraband-alert trigger). Keep
-- server/certifications.lua scoped to grant/revoke/check/cache only.
