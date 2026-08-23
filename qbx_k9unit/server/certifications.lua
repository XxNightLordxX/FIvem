--[[
    qbx_k9unit/server/certifications.lua

    Phase 1 scaffold only (coder-architect). This file owns the
    k9_certifications table interactions and is the single source of truth
    for "is this player allowed to use a K9 right now" — server/main.lua
    delegates to it rather than re-implementing the check.

    ======================================================================
    EVENT/CALLBACK CONTRACT (full copy — identical in every stub file so
    coder-backend and coder-frontend can work in parallel without live
    coordination):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [THIS FILE]
       job.name in Config.Departments AND (active cert cache hit for
       citizenid+job OR autoAccessGrade bypass configured and grade
       qualifies).
    2. 'qbx_k9unit:server:requestSpawnK9' (pedKey: string) -> { ok: bool, reason?: string }
       [server/main.lua — calls THIS FILE's HasK9Access()]

    Server events (RegisterNetEvent, client->server):
    3. 'qbx_k9unit:server:registerK9' (netId: number) [server/main.lua]
    4. 'qbx_k9unit:server:unregisterK9' () [server/main.lua]
    5. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [THIS FILE]
       Grant flow per SPEC.md §4.2/§4.3 — re-validate granter eligibility,
       target eligibility, and Config.CertifyProximityMeters proximity via
       live server-side coordinates, never client-claimed.
    6. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [THIS FILE]
       Same re-validation as certify.
    7. 'qbx_k9unit:server:relayBark' (netId: number, barkType: string) [server/main.lua]

    Client events (RegisterNetEvent, server->client):
    8. 'qbx_k9unit:client:despawnK9' (netId: number) [client/main.lua]
    9. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [client/main.lua]

    Commands (server-registered, call the same internal function as events 5/6):
    10. '/k9certify [targetServerId]' [THIS FILE]
    11. '/k9decertify [targetServerId]' [THIS FILE]

    Player disconnect: handled in server/main.lua.

    Cross-cutting security rule (SPEC.md §3 + §4.3): every access point
    above must re-check server-side, independent of client claims. This is
    THE file coder-security should scrutinize hardest — see the explicit
    security note quoted from SPEC.md §4.3 below.
    ======================================================================

    SPEC.md §4.3 explicit security note (quoted): "every one of the three
    mechanisms above (grant, revoke, check) must re-verify on the server,
    independent of what the requesting client claims about its own job,
    rank, or proximity. The client-side ox_target option visibility and
    command availability are UX conveniences only, not access control — a
    modified client calling the server event directly with an arbitrary
    target id must still be rejected by the server-side checks in §4.2 and
    §4.3."

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes a resource-global (no `local`) function
      `HasK9Access(source)` -> boolean, called by server/main.lua's
      requestSpawnK9 callback. Keep the signature stable.
    - THIS FILE owns `Certifications` (citizenid -> boolean, per SPEC.md
      §4.3 "Server-side cache", scoped to the player's *current* job) as a
      local table — no other file needs it directly.
]]

-- Certifications[citizenid] = true|false, for the player's CURRENT job.
-- Populated on player load, updated on grant/revoke and on job change
-- (SPEC.md §4.3 "Server-side cache"). Local: nothing outside this file
-- should read it directly — always go through HasK9Access(source).
local Certifications = {}

--- Server-authoritative check: is `source` currently allowed to use a K9?
--- SPEC.md §4.1 "Access rule": job.name in Config.Departments AND
--- (active cert for that job OR configured autoAccessGrade bypass).
--- Exposed globally (no `local`) — server/main.lua calls this directly.
--- @param source number
--- @return boolean
function HasK9Access(source)
    -- TODO(coder-backend): SPEC.md §4.1.
    --   1. Get the player's job (qbx_core player object: Player.PlayerData.job).
    --   2. If job.name is not a key in Config.Departments, return false.
    --   3. If Certifications[citizenid] is true (active cert cached for
    --      this citizenid+job), return true.
    --   4. Else, if Config.Departments[job.name].autoAccessGrade is a
    --      number AND job.grade.level >= that number, return true (opt-in
    --      bypass, defaults to nil/disabled per shipped config — do not
    --      change the default).
    --   5. Otherwise return false.
    return false
end

--- SPEC.md §4.2 certifier eligibility check (granter side only — does not
--- check the target or proximity, see GrantCertification/RevokeCertification).
--- @param source number
--- @return boolean
local function IsEligibleCertifier(source)
    -- TODO(coder-backend): SPEC.md §4.2 points 1-2.
    --   1. job.name must be a key in Config.Departments.
    --   2. job.grade.level >= Config.Departments[job.name].certifierGrade
    --      OR job.isboss == true (boss always qualifies regardless of the
    --      configured numeric threshold).
    return false
end

--- SPEC.md §4.2/§4.3 grant flow. Called by both event 5 and command 10.
--- @param granterSrc number
--- @param targetServerId number
local function GrantCertification(granterSrc, targetServerId)
    -- TODO(coder-backend): SPEC.md §4.2 + §4.3 flow table ("Grant" row).
    --   1. IsEligibleCertifier(granterSrc) — reject with a notify if false.
    --   2. Special case: granterSrc == targetServerId is self-certification
    --      — only allowed if Config.AllowSelfCertification == true (§4.1).
    --      If self-cert and the flag is false, reject.
    --   3. Resolve target player object for targetServerId; reject if
    --      offline (grant requires an online target — unlike revoke, which
    --      SPEC.md §4.3's flow table explicitly says "works offline").
    --   4. Target's job.name must be a key in Config.Departments (§4.2.3 —
    --      cross-department granting IS currently allowed per spec; this is
    --      flagged as an open question in SPEC.md §9.2, not resolved here —
    --      do not silently restrict to same-department without flagging it
    --      back up if you decide to change this).
    --   5. Unless self-certifying, enforce Config.CertifyProximityMeters
    --      between granter's and target's LIVE server-side coordinates
    --      (GetEntityCoords on both peds) — never trust client-claimed
    --      proximity. (SPEC.md §9 doesn't say whether self-cert also skips
    --      the proximity check since granter == target trivially satisfies
    --      it at distance 0 anyway — no special-casing needed there.)
    --   6. Check for an existing active row for (targetCitizenid, job) —
    --      SPEC.md §4.3 invariant: at most one active=1 row per
    --      (citizenid, job). If one exists, this is a no-op ("already
    --      certified" reply), not an error.
    --   7. INSERT into k9_certifications (citizenid, job, granted_by,
    --      granted_at, active) — see qbx_k9unit/sql/install.sql for the
    --      exact column set (produced separately by db-schema; read that
    --      file before writing the query rather than re-deriving the
    --      schema from SPEC.md §4.3's copy, in case db-schema adjusted it).
    --   8. Update Certifications[targetCitizenid] = true if target is
    --      online and currently in that job.
    --   9. Write the read-only metadata.k9certified = true mirror on the
    --      target's qbx_core metadata for client HUD display ONLY (§4.3 —
    --      "never read by any server-side authorization check"; add a code
    --      comment at the write site repeating that constraint).
    --   10. Notify both granter and (if online) target.
end

--- SPEC.md §4.2/§4.3 revoke flow. Called by both event 6 and command 11.
--- Must work even when the target is offline (§4.3).
--- @param granterSrc number
--- @param targetServerId number
local function RevokeCertification(granterSrc, targetServerId)
    -- TODO(coder-backend): SPEC.md §4.3 flow table ("Revoke" row).
    -- Same eligibility/self-cert/proximity rules as GrantCertification
    -- EXCEPT: `targetServerId` here may need to resolve an OFFLINE citizen
    -- (the command form takes an id that "works offline" per the flow
    -- table — clarify with coder-frontend/command design whether offline
    -- revoke uses a server id, citizenid, or a name lookup, since a
    -- disconnected player has no live server id; this scaffold assumes
    -- targetServerId per the given contract signature, but if the target
    -- is offline there IS no server id to check proximity against — in
    -- that case the proximity check in §4.2 point 4 cannot apply, and
    -- revoking an offline target is presumably exempt from proximity by
    -- necessity. Confirm this reading; it's implied but not spelled out
    -- verbatim in SPEC.md and should not be silently assumed further than
    -- this note without flagging it).
    --   1. IsEligibleCertifier(granterSrc).
    --   2. UPDATE the existing active row for (targetCitizenid, job) SET
    --      active = 0, revoked_by, revoked_at (do not DELETE — audit trail).
    --   3. Certifications[targetCitizenid] = false if currently cached.
    --   4. Update/clear metadata.k9certified mirror if target is online.
    --   5. Notify granter, and target if online.
end

lib.callback.register('qbx_k9unit:server:hasK9Access', function(source)
    return HasK9Access(source)
end)

RegisterNetEvent('qbx_k9unit:server:certifyHandler', function(targetServerId)
    GrantCertification(source, targetServerId)
end)

RegisterNetEvent('qbx_k9unit:server:revokeHandler', function(targetServerId)
    RevokeCertification(source, targetServerId)
end)

RegisterCommand('k9certify', function(source, args)
    -- TODO(coder-backend): parse/validate args[1] as a number before
    -- calling GrantCertification; reject non-numeric input with a usage
    -- message rather than letting a bad value reach the grant flow.
    GrantCertification(source, tonumber(args[1]))
end, false)

RegisterCommand('k9decertify', function(source, args)
    -- TODO(coder-backend): same arg validation as k9certify above.
    RevokeCertification(source, tonumber(args[1]))
end, false)

-- TODO(coder-backend): SPEC.md §4.3 "Server-side cache" — on player load,
-- query the active cert row for the player's CURRENT job and set
-- Certifications[citizenid] = true|false. On job change, re-run the same
-- lookup for the NEW job (a cert is job-scoped; SPEC.md §9.3 flags that
-- leaving and returning to a department does NOT auto-restore access —
-- ship that assumption as-is unless told otherwise). Use qbx_core's
-- player-loaded and job-change events (check qbx_core's actual event
-- names/payloads rather than assuming — e.g. `QBCore:Server:PlayerLoaded`
-- and a job-update event; qbx_core is a live dependency here, confirm
-- exact names against it rather than SPEC.md, which doesn't specify them).
-- AddEventHandler('QBCore:Server:PlayerLoaded', function(Player) end)
-- AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job) end)
