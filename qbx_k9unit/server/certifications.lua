--[[
    qbx_k9unit/server/certifications.lua

    Phase 1 scaffold only (coder-architect). This file IS the permission
    system (SPEC.md hard requirement 2) — grant/revoke/check, the
    server-side cert cache, and the automatic revoke-on-job-change path.
    Keep it scoped to "who is allowed to use K9 features" only; misc
    small gated K9 actions (e.g. bark relay) live in server/main.lua so
    this file doesn't balloon as later phases add more of those.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1, REWRITTEN after SPEC.md's post-draft
    correction (K9 is a player's own persistent character, no spawn/despawn/
    registry concept at all — see SPEC.md §1, §2 "Explicit non-goals").
    This block is identical in every stub file it's relevant to, so
    coder-backend and coder-frontend can work in parallel without live
    coordination.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [THIS FILE]
       job.name ∈ Config.Departments AND active cert cached for that exact
       job (OR autoAccessGrade bypass). Per SPEC.md §4.1/§4.5: this is the
       ONLY access check, and it does NOT consider ped model at all — model
       is checked exclusively at grant time (§4.2 condition 5, below), not
       on every access. A certified handler who later isn't K9-modeled
       still passes this check (client-side display logic hides the UI for
       them anyway, see client/main.lua's IsOwnModelK9(); this is a known,
       spec-confirmed tradeoff, not a bug — flagged for coder-security to
       be aware of, not to "fix" unprompted).

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [THIS FILE]
       Grant flow per SPEC.md §4.2/§4.3 — re-validate granter eligibility,
       target eligibility (job membership, model, per §4.2), and
       Config.CertifyProximityMeters proximity via live server-side
       coordinates, never client-claimed.
    3. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [THIS FILE]
       Same re-validation as certify MINUS the model check (§4.2.5 —
       "applies to grant only, not revoke").
    4. 'qbx_k9unit:server:relayBark' (barkType: string) [server/main.lua]

    Client events (RegisterNetEvent, server->client):
    5. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [client/main.lua]

    Commands (server-registered, call the same internal function as events 2/3):
    6. '/k9certify [targetServerId]' [THIS FILE]
    7. '/k9decertify [targetServerId]' [THIS FILE]

    Automatic, server-only path (no client entry point at all):
    8. AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job) ... end)
       [THIS FILE] — auto-revoke on leaving the department (§4.4).

    REMOVED from the original (pre-correction) scaffold — do not resurrect:
    'qbx_k9unit:server:requestSpawnK9' callback, 'qbx_k9unit:server:registerK9'
    / 'unregisterK9' events, 'qbx_k9unit:client:despawnK9' event, any
    "current K9" netId registry, Config.K9DespawnGraceSeconds. All were
    artifacts of the incorrect NPC-spawn model.

    Cross-cutting security rule (SPEC.md §3 + §4.3): every access point
    above must re-check server-side, independent of client claims. This is
    THE file coder-security should scrutinize hardest — see the explicit
    security note quoted from SPEC.md §4.3 below.
    ======================================================================

    SPEC.md §4.3 explicit security note (quoted): "every one of the
    mechanisms above (grant, manual revoke, check) must re-verify on the
    server, independent of what the requesting client claims about its own
    job, rank, proximity, or ped model. The client-side ox_target option
    visibility and command availability are UX conveniences only, not
    access control — a modified client calling the server event directly
    with an arbitrary target id must still be rejected by the server-side
    checks in §4.2 and §4.3. The automatic revoke path (§4.4) is
    server-triggered and has no client-reachable entry point at all."

    MINOR SPEC INCONSISTENCY FLAGGED (not fixed here — SPEC.md is not this
    file's to edit): §4.1's access-rule paragraph still says access is
    "checked server-side on every access point (menu open request *and*
    the actual spawn request — not just once)" — "the actual spawn
    request" is leftover text from the pre-correction draft; there is no
    spawn request anymore. Read the intent as "every access point, not
    just once" and disregard the stale "spawn request" clause. Flag this
    to whoever next revises SPEC.md rather than silently patching the spec
    from a coder-architect scaffold.

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes three resource-global (no `local`) functions:
        HasK9Access(source) -> boolean
            Called by server/main.lua's relayBark handler (and any future
            Phase 2+ gated action added there) and by the hasK9Access
            callback below. Keep this the SINGLE source of truth for "is
            this player allowed to use K9 features right now" — do not
            duplicate the job/cert logic anywhere else.
        RefreshCertificationCache(citizenid, jobName)
            Re-queries the active-cert row for (citizenid, jobName) and
            updates the in-memory cache. Called from: (a) this file's own
            player-loaded and job-update hooks, and (b) server/main.lua's
            onResourceStart backfill loop (see that file — a resource
            restart while players are already online needs to warm the
            cache for them too, since no fresh player-loaded event fires
            for already-connected players).
        IsConfiguredK9Model(modelHash) -> boolean
            Used here for the §4.2.5 grant-time model check, and reused by
            server/main.lua's leash-role determination (§6.1/§9 item 3b —
            leash roles are assigned by which party is actually K9-modeled,
            server-verified, never client-claimed) — one shared model
            check instead of two independent copies of Config.Peds logic.
    - THIS FILE owns `Certifications` (citizenid -> { active: boolean,
      job: string }) as a local table. STRUCTURAL NOTE: SPEC.md §4.3's
      prose describes this cache as a bare `Certifications[citizenid] =
      true|false`, but §4.4's auto-revoke handler needs to know WHICH job
      that boolean was scoped to (to tell "left the department" apart from
      "got promoted within it") — §4.3 and §4.4 are only reconcilable if
      the cache also tracks job. Decision: store `{ active, job }` instead
      of a bare boolean; it's a strict superset of what §4.3 asked for and
      avoids a second parallel cache that could drift out of sync.
]]

-- Certifications[citizenid] = { active = boolean, job = string }
-- `job` is whichever department this cached result was scoped to (the
-- player's job at the time of the last refresh). Local: nothing outside
-- this file should read it directly — always go through HasK9Access(source)
-- or RefreshCertificationCache(citizenid, jobName).
local Certifications = {}

--- Precomputed set of Config.Peds model hashes, built once at file load.
--- Used ONLY by the grant-time model check (§4.2 condition 5) — per
--- §4.1/§4.5, ordinary access checks (HasK9Access) never consult this.
--- TODO(coder-backend): build via GetHashKey(pedEntry.model) for each
--- entry in Config.Peds, e.g. K9ModelHashes[GetHashKey(model)] = true.
--- Keep this generic over Config.Peds — no hardcoded model name anywhere
--- (SPEC.md §3 acceptance bullet 3), including custom streamed entries.
local K9ModelHashes = {}

--- @param modelHash number
--- @return boolean
--- Exposed globally (no `local`) — server/main.lua's leash-role
--- determination (§6.1/§9 item 3b) reuses this same model check rather
--- than re-deriving its own copy from Config.Peds.
function IsConfiguredK9Model(modelHash)
    -- TODO(coder-backend): return K9ModelHashes[modelHash] == true
    return false
end

--- Server-authoritative check: is `source` currently allowed to use K9
--- features? SPEC.md §4.1 "Access rule": job.name in Config.Departments
--- AND (active cert cached for that job OR configured autoAccessGrade
--- bypass). Deliberately does NOT check ped model (§4.5) — see the
--- contract block above for why that's intentional, not an oversight.
--- Exposed globally (no `local`) — server/main.lua calls this directly.
--- @param source number
--- @return boolean
function HasK9Access(source)
    -- TODO(coder-backend): SPEC.md §4.1.
    --   1. Get the player's job (qbx_core player object: Player.PlayerData.job).
    --   2. If job.name is not a key in Config.Departments, return false.
    --   3. local cached = Certifications[citizenid]
    --      if cached and cached.active and cached.job == job.name then
    --          return true
    --      end
    --      (the `cached.job == job.name` re-check matters right around a
    --      job change, before RefreshCertificationCache has run for the
    --      new job — don't trust a stale cache entry scoped to an old job.)
    --   4. Else, if Config.Departments[job.name].autoAccessGrade is a
    --      number AND job.grade.level >= that number, return true (opt-in
    --      bypass, defaults to nil/disabled per shipped config — do not
    --      change the default).
    --   5. Otherwise return false.
    return false
end

--- Re-queries the active-cert row for (citizenid, jobName) and updates the
--- in-memory cache. Exposed globally (no `local`) — see FILE-TO-FILE
--- CONTRACT above for every call site.
--- @param citizenid string
--- @param jobName string
function RefreshCertificationCache(citizenid, jobName)
    -- TODO(coder-backend): SPEC.md §4.3 "Exact query patterns" hot-path check:
    --   SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1;
    -- Certifications[citizenid] = { active = (row found), job = jobName }
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

--- SPEC.md §4.2/§4.3 grant flow. Called by both event 2 and command 6.
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
    --      proximity.
    --   6. (New, §4.2.5) Target model check: IsConfiguredK9Model(
    --      GetEntityModel(GetPlayerPed(targetServerId))) must be true —
    --      read live server-side, NEVER a client-reported model. Applies
    --      UNIFORMLY whether or not this is a self-certification (granter
    --      == target) — do not skip it for the self-cert case; a
    --      certifier-grade officer bootstrapping their own cert must
    --      themselves be playing a K9-model character for this to pass.
    --      Grant-only per §4.2.5 — RevokeCertification must NOT run this
    --      check.
    --   7. Check for an existing active row for (targetCitizenid, job) —
    --      SPEC.md §4.3 invariant: at most one active=1 row per
    --      (citizenid, job), backstopped by the DB's
    --      `uq_one_active_cert_per_job` unique index. If a pre-check finds
    --      one, this is a no-op ("already certified" reply), not an error.
    --   8. INSERT INTO k9_certifications (citizenid, job, granted_by)
    --      VALUES (?, ?, ?); — MUST catch MySQL duplicate-key error 1062
    --      on this INSERT and treat it as the same "already certified"
    --      no-op (closes the check-then-act race the app-level pre-check
    --      alone leaves open — see SPEC.md §4.3 "DB-level backstop").
    --      See qbx_k9unit/sql/install.sql for the exact shipped column
    --      set (db-schema-reviewed) rather than re-deriving it from
    --      SPEC.md's copy in case of drift.
    --   9. RefreshCertificationCache(targetCitizenid, job.name) if target
    --      is online (keeps the cache authoritative rather than
    --      hand-rolling `Certifications[targetCitizenid] = {...}` here).
    --   10. Write the read-only metadata.k9certified = true mirror on the
    --      target's qbx_core metadata for client HUD display ONLY (§4.3 —
    --      "never read by any server-side authorization check"; add a code
    --      comment at the write site repeating that constraint).
    --   11. Notify both granter and (if online) target.
end

--- SPEC.md §4.2/§4.3 revoke flow (manual). Called by both event 3 and
--- command 7. Must work even when the target is offline (§4.3). Does NOT
--- run the model check (§4.2.5 applies to grant only).
--- @param granterSrc number
--- @param targetServerId number
local function RevokeCertification(granterSrc, targetServerId)
    -- TODO(coder-backend): SPEC.md §4.3 flow table ("Revoke (manual)" row).
    -- Same eligibility/self-cert/proximity rules as GrantCertification
    -- (minus the model check) EXCEPT: `targetServerId` here may need to
    -- resolve an OFFLINE citizen (the command form takes an id that "works
    -- offline" per the flow table — clarify whether offline revoke uses a
    -- server id, citizenid, or a name lookup, since a disconnected player
    -- has no live server id; this scaffold assumes targetServerId per the
    -- given contract signature, but if the target is offline there IS no
    -- server id to check proximity against — in that case the proximity
    -- check in §4.2 point 4 cannot apply, and revoking an offline target
    -- is presumably exempt from proximity by necessity. This is implied,
    -- not spelled out verbatim in SPEC.md — confirm this reading rather
    -- than silently assuming further than this note).
    --   1. IsEligibleCertifier(granterSrc).
    --   2. UPDATE k9_certifications SET active = 0, revoked_by = ?,
    --      revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ?
    --      AND active = 1; (no LIMIT needed — the unique constraint
    --      guarantees at most one row matches, per SPEC.md §4.3).
    --   3. RefreshCertificationCache(targetCitizenid, job) if target is
    --      online and their cache is scoped to that job.
    --   4. Update/clear metadata.k9certified mirror if target is online.
    --   5. Notify granter, and target if online.
end

--- SPEC.md §4.4 (NEW): automatic revoke when actually leaving the
--- department (not on a same-department grade change). Server-only path —
--- never exposed as a client-callable event.
--- @param source number
--- @param job table  -- new PlayerJob object, per qbx_core's event payload
AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job)
    -- TODO(coder-backend): SPEC.md §4.4 handler logic.
    --   1. Resolve citizenid for `source`.
    --   2. local cached = Certifications[citizenid] — this already tracks
    --      which job the cached cert was scoped to (see the STRUCTURAL
    --      NOTE at the top of this file for why the cache stores `.job`).
    --   3. Guard: if not (cached and cached.active) then return end — no
    --      active cert to revoke, nothing to do.
    --   4. Guard: if job.name == cached.job then return end — SAME
    --      department, this is a grade/promotion change, NOT a
    --      department change. Per §4.4 "Important consequences": a
    --      promotion/demotion must NOT revoke the certification. This
    --      guard is the entire point of storing `.job` on the cache —
    --      do not remove it or every promotion silently strips certs.
    --   5. UPDATE k9_certifications SET active = 0,
    --      revoked_by = 'system:job_change', revoked_at = CURRENT_TIMESTAMP
    --      WHERE citizenid = ? AND job = ? AND active = 1; (job = cached.job,
    --      the OLD department, not the new one).
    --   6. RefreshCertificationCache(citizenid, job.name) — repopulate the
    --      cache scoped to the NEW job (almost certainly `active = false`
    --      unless they happen to already hold a separate active cert for
    --      that new department from a prior stint — a fresh grant is
    --      required either way per §9 item 3, this just keeps the cache
    --      accurate for whatever the new job actually is).
    --   7. Notify the player if online: "Your K9 certification has been
    --      revoked — you are no longer employed by <department>."
end)

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
-- call RefreshCertificationCache(citizenid, job.name) for the player's
-- CURRENT job. Use qbx_core's actual player-loaded event/payload (confirm
-- the exact name against qbx_core itself rather than assuming — e.g.
-- `QBCore:Server:PlayerLoaded`).
-- AddEventHandler('QBCore:Server:PlayerLoaded', function(Player) end)
