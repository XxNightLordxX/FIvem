--[[
    qbx_k9unit/server/main.lua

    Phase 1 scaffold only (coder-architect). Fill per TODOs; do not change
    event names, callback names, or the exposed global function names below
    without also updating every other stub file that references them (see
    the "FILE-TO-FILE CONTRACT" section) and re-syncing with coder-frontend.

    ======================================================================
    EVENT/CALLBACK CONTRACT (full copy — identical in every stub file so
    coder-backend and coder-frontend can work in parallel without live
    coordination):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean
       job.name in Config.Departments AND (active cert cache hit for
       citizenid+job OR autoAccessGrade bypass configured and grade
       qualifies). [lives in server/certifications.lua as global
       HasK9Access(source); THIS FILE calls it, does not define it]
    2. 'qbx_k9unit:server:requestSpawnK9' (pedKey: string) -> { ok: bool, reason?: string }
       Re-check hasK9Access logic AND that pedKey exists in Config.Peds.
       Server does NOT spawn anything — only authorizes the client to
       create+network the ped locally. [THIS FILE]

    Server events (RegisterNetEvent, client->server):
    3. 'qbx_k9unit:server:registerK9' (netId: number) [THIS FILE]
       Re-validate access; if citizenid already has a registered netId,
       TriggerClientEvent('qbx_k9unit:client:despawnK9', src, oldNetId)
       before overwriting the registry with the new one.
    4. 'qbx_k9unit:server:unregisterK9' () [THIS FILE]
       Clear this citizenid's registry entry. No-op if none.
    5. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [server/certifications.lua]
    6. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [server/certifications.lua]
    7. 'qbx_k9unit:server:relayBark' (netId: number, barkType: string) [THIS FILE]
       Verify sender currently owns that registered netId, then
       TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType).
       Must be a no-op if Config.Features.BasicBarkSounds is false (§3).

    Client events (RegisterNetEvent, server->client):
    8. 'qbx_k9unit:client:despawnK9' (netId: number) [client/main.lua]
    9. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [client/main.lua]

    Commands (server-registered, call the same internal function as events 5/6):
    10. '/k9certify [targetServerId]' [server/certifications.lua]
    11. '/k9decertify [targetServerId]' [server/certifications.lua]

    Player disconnect: server 'playerDropped' starts a
    Config.K9DespawnGraceSeconds timer; if not reclaimed, clear the
    registry entry. [THIS FILE]

    Cross-cutting security rule (SPEC.md §3 + §4.3): every access point
    above must re-check server-side, independent of client claims, and a
    disabled Config.Features.X must make the corresponding event a
    server-side no-op, not just a hidden client-side menu item.
    ======================================================================

    FILE-TO-FILE CONTRACT (server side):
    - server/certifications.lua exposes a resource-global (no `local`)
      function `HasK9Access(source)` returning boolean. THIS FILE calls it
      from the requestSpawnK9 callback. Do not duplicate the access-check
      logic here — always delegate to certifications.lua so there is one
      source of truth for "who can use a K9 right now".
    - THIS FILE owns the K9 registry (citizenid -> { netId, job }) and does
      NOT expose it as a global table; certifications.lua does not need it
      (cert check is independent of whether a K9 is currently spawned).

    ASSUMPTION FLAGGED FOR coder-backend (per task instructions — stating
    this rather than guessing silently): oxmysql does NOT, to the best of
    this scaffold's knowledge, auto-execute arbitrary .sql files dropped
    into a resource's own folder the way e.g. a migration framework would.
    `qbx_k9unit/sql/install.sql` (produced separately by db-schema) is most
    likely a manual-import artifact — the server owner runs it once via
    their DB client, same convention as most qb-core-lineage resources
    shipping a `.sql` file. If a smoother first-run experience is wanted,
    coder-backend could additionally run the `CREATE TABLE IF NOT EXISTS
    k9_certifications (...)` statement defensively here (or in
    certifications.lua) on resource start, mirroring install.sql's schema,
    so the resource self-installs even if the owner forgets the manual
    step. Confirm/finalize this — do not assume auto-migration silently.
]]

-- K9 registry: citizenid -> { netId = number, job = string, dropTimer = number|nil }
-- Kept local: no other file needs direct access. If that changes, expose
-- accessor functions (GetK9RegistryEntry/SetK9RegistryEntry) rather than
-- making this table global.
local K9Registry = {}

-- TODO(coder-backend): on resource start / qbx_core player-loaded event,
-- decide whether this file needs its own player-load hook at all (see
-- SPEC.md §8 step 5 "despawn-on-handler-offline grace period" — this is
-- about registry *reclaim* on (re)connect, i.e. cancel a pending grace
-- timer if the same citizenid reconnects within Config.K9DespawnGraceSeconds).
-- NOTE: server/certifications.lua ALSO hooks a player-loaded event (to
-- populate the certification cache per SPEC.md §4.3). Decide whether both
-- hook the same qbx_core event independently (simplest, recommended) or
-- whether one should call into the other — do not silently merge them
-- into a single handler across files without a comment explaining why.
-- AddEventHandler('QBCore:Server:PlayerLoaded', function(Player) end)

--- Re-checks K9 access and that pedKey is a real config entry.
--- @param source number
--- @param pedKey string
--- @return { ok: boolean, reason: string? }
lib.callback.register('qbx_k9unit:server:requestSpawnK9', function(source, pedKey)
    -- TODO(coder-backend): SPEC.md §4 (access) + §6.1 bullet 2 (model
    -- validation). Steps:
    --   1. if not HasK9Access(source) then return { ok = false, reason = 'no_access' } end
    --   2. Validate `pedKey` is a string matching some Config.Peds[i].model
    --      exactly (reject if not found — this is the "invalid/tampered
    --      model key is rejected server-side" acceptance bullet).
    --   3. Return { ok = true } — do NOT create/network any entity here;
    --      the client is solely responsible for spawning once authorized.
    return { ok = false, reason = 'not_implemented' }
end)

--- Client informs the server which netId it just spawned/networked as its K9.
--- @param netId number
RegisterNetEvent('qbx_k9unit:server:registerK9', function(netId)
    local src = source
    -- TODO(coder-backend): SPEC.md §8 step 5.
    --   1. Re-validate HasK9Access(src) — a client could fire this event
    --      directly without ever having called requestSpawnK9.
    --   2. Look up this player's citizenid (via qbx_core player object).
    --   3. If K9Registry[citizenid] already exists with a different netId
    --      (previous K9 wasn't cleanly unregistered — e.g. selecting a new
    --      ped per the "only one active K9" rule, §6.1 bullet 3):
    --         TriggerClientEvent('qbx_k9unit:client:despawnK9', src, oldNetId)
    --      BEFORE overwriting the registry entry.
    --   4. K9Registry[citizenid] = { netId = netId, job = <current job name> }
    --   5. Cancel any pending grace-period despawn timer for this citizenid.
end)

--- Client (or an internal call) tells the server to drop this handler's K9 link.
RegisterNetEvent('qbx_k9unit:server:unregisterK9', function()
    local src = source
    -- TODO(coder-backend): look up citizenid, clear K9Registry[citizenid]
    -- if present. No-op (do nothing, no error) if there was no entry.
end)

--- Relays a bark to every client so anyone near the K9 entity hears it.
--- @param netId number
--- @param barkType string
RegisterNetEvent('qbx_k9unit:server:relayBark', function(netId, barkType)
    local src = source
    -- TODO(coder-backend): SPEC.md §6.1 bark bullet + §3 (feature gating
    -- must be enforced server-side, not just hidden client-side).
    --   1. if not Config.Features.BasicBarkSounds then return end  -- silent no-op
    --   2. Look up this player's citizenid, confirm
    --      K9Registry[citizenid] and K9Registry[citizenid].netId == netId
    --      — reject/ignore otherwise (do not trust the caller's netId claim).
    --   3. NOTE: `barkType` enum is not yet defined anywhere in SPEC.md or
    --      config.lua. coder-frontend is defining/using specific string
    --      values in client/radial.lua's Bark item(s) — coder-backend
    --      should NOT invent its own separate list; treat barkType as an
    --      opaque string to pass through, and flag to coder-frontend if a
    --      config-driven enum (e.g. Config.BarkSounds) ends up being
    --      needed for validation here.
    --   4. TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType)
end)

--- Grace period before clearing a disconnected handler's registry entry.
AddEventHandler('playerDropped', function(reason)
    local src = source
    -- TODO(coder-backend): SPEC.md §6.1 "Handler disconnecting despawns
    -- their K9 after a grace period" + §8 step 5.
    --   1. Look up citizenid for `src` (must happen synchronously before
    --      the player object is torn down by qbx_core's own playerDropped
    --      handling — verify ordering/resource load order with coder-backend's
    --      own judgement, this may need `deferrals`-style care).
    --   2. If K9Registry[citizenid] exists, start a SetTimeout for
    --      Config.K9DespawnGraceSeconds * 1000 ms.
    --   3. When the timer fires, if the entry is still the SAME netId
    --      (i.e. not reclaimed by a fresh registerK9 call in the meantime),
    --      clear K9Registry[citizenid].
    --   4. OPEN QUESTION flagged for coder-backend to resolve, not decided
    --      here: does clearing the registry entry need an explicit
    --      DeleteEntity/NetworkGetEntityFromNetworkId + delete on some
    --      client, or is it safe to rely on FiveM's own cleanup of a
    --      networked entity once its owning player has fully disconnected
    --      and no other client claims ownership? If the K9 ped's network
    --      owner migrates to another client instead of despawning (default
    --      FiveM entity-ownership migration behavior), an explicit despawn
    --      broadcast (reusing 'qbx_k9unit:client:despawnK9') may still be
    --      required here to satisfy "no orphaned, uncontrolled K9 peds"
    --      (§6.1). Decide and document the chosen approach in this TODO's
    --      place once implemented.
end)
