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
    7b. '/k9decertifyoffline [citizenid] [job]' [THIS FILE] — closes the
        online-only gap in event 3/command 7's numeric targetServerId
        contract (SPEC.md §4.3 requires revocation to work on a target who
        is genuinely disconnected, and a disconnected player has no live
        server id at all — see RevokeCertificationOffline below). No
        client-reachable event equivalent exists, nor should one: a
        disconnected target has no client to trigger anything from, so
        this is command-only, unlike certify/revoke which also expose net
        events 2/3. SECURITY: this path skips the proximity check only
        because it's the ONLY way to reach a genuinely disconnected
        target — RevokeCertificationOffline therefore verifies the
        citizenid actually resolves to no currently-connected player
        before doing anything, and refuses (pointing the caller at
        /k9decertify instead) if the "offline" target turns out to be
        online right now. Without that guard this command would be a
        drop-in proximity-check bypass for revoking an online target from
        anywhere on the map — found and fixed in this pass.

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
    - THIS FILE calls `ForceDetachLeashForSource(src, reason)`, exposed by
      server/main.lua, from every path that flips an active cert to
      revoked for a K9-role party (RevokeCertification's online branch,
      RevokeCertificationOffline via the ForceDetachLeashIfOnline wrapper
      below, and the QBCore:Server:OnJobUpdate auto-revoke handler) — see
      ForceDetachLeashIfOnline's own doc comment and server/main.lua's
      header for the full rationale (SPEC.md §1/§4.4 "immediately").
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
--- Generic over Config.Peds — no hardcoded model name anywhere (SPEC.md §3
--- acceptance bullet 3), including custom streamed entries.
local K9ModelHashes = {}
for _, pedEntry in ipairs(Config.Peds) do
    K9ModelHashes[GetHashKey(pedEntry.model)] = true
end

--- @param modelHash number
--- @return boolean
--- Exposed globally (no `local`) — server/main.lua's leash-role
--- determination (§6.1/§9 item 3b) reuses this same model check rather
--- than re-deriving its own copy from Config.Peds.
function IsConfiguredK9Model(modelHash)
    return K9ModelHashes[modelHash] == true
end

--- Sends an ox_lib notification to a specific player. Chosen over
--- exports.qbx_core:Notify because ox_lib's `ox_lib:notify` client event
--- is a stable, publicly documented API of an already-declared dependency
--- (ox_lib) — qbx_core's own Notify export name/signature could not be
--- independently confirmed in this sandbox (no qbx_core install was
--- reachable here to inspect; see the CONFIDENCE NOTE near the bottom of
--- this file for the same caveat applied to the player-loaded event name).
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

--- Server-authoritative check: is `source` currently allowed to use K9
--- features? SPEC.md §4.1 "Access rule": job.name in Config.Departments
--- AND (active cert cached for that job OR configured autoAccessGrade
--- bypass). Deliberately does NOT check ped model (§4.5) — see the
--- contract block above for why that's intentional, not an oversight.
--- Exposed globally (no `local`) — server/main.lua calls this directly.
--- @param source number
--- @return boolean
function HasK9Access(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- The `cached.job == job.name` re-check matters right around a job
    -- change, before RefreshCertificationCache has run for the new job —
    -- don't trust a stale cache entry scoped to an old job.
    local cached = Certifications[Player.PlayerData.citizenid]
    if cached and cached.active and cached.job == job.name then
        return true
    end

    -- Opt-in bypass, defaults to nil/disabled per shipped config — do not
    -- change the default.
    local dept = Config.Departments[job.name]
    if type(dept.autoAccessGrade) == 'number' and job.grade and job.grade.level and job.grade.level >= dept.autoAccessGrade then
        return true
    end

    return false
end

--- Re-queries the active-cert row for (citizenid, jobName) and updates the
--- in-memory cache. Exposed globally (no `local`) — see FILE-TO-FILE
--- CONTRACT above for every call site.
--- @param citizenid string
--- @param jobName string
--- @return boolean active — the freshly-cached value, so callers (e.g.
--- server/main.lua's onResourceStart backfill, which has no access to the
--- local Certifications table below) don't need their own accessor just
--- to resync a dependent value like the k9certified metadata mirror.
function RefreshCertificationCache(citizenid, jobName)
    local activeId = MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', {
        citizenid, jobName,
    })
    local active = activeId ~= nil
    Certifications[citizenid] = { active = active, job = jobName }
    return active
end

--- SPEC.md §4.2 certifier eligibility check (granter side only — does not
--- check the target or proximity, see GrantCertification/RevokeCertification).
--- @param source number
--- @return boolean
local function IsEligibleCertifier(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- job.isboss always qualifies regardless of the configured numeric
    -- threshold.
    if job.isboss then return true end

    local dept = Config.Departments[job.name]
    return job.grade ~= nil and job.grade.level ~= nil and job.grade.level >= dept.certifierGrade
end

--- QA/coder-security finding (leash subsystem gap): losing K9 certification
--- must end an already-formed leash pairing "immediately" per SPEC.md
--- §1/§4.4, not just block future attach attempts — CheckLeashEligibility
--- in server/main.lua is only consulted at attach time, so a K9-role party
--- who gets decertified mid-session while actively leashed would otherwise
--- stay paired until someone manually detaches or the distance
--- safety-valve trips. Called from every path that actually flips an
--- active cert to revoked for a K9-role party: RevokeCertification (online),
--- RevokeCertificationOffline, and the QBCore:Server:OnJobUpdate
--- auto-revoke handler.
---
--- Resolves citizenid -> current server id via
--- exports.qbx_core:GetPlayerByCitizenId and calls
--- server/main.lua's exposed ForceDetachLeashForSource. Naturally a no-op
--- for a genuinely offline target: LeashPairs is in-memory/ephemeral only
--- (never persisted, per server/main.lua's header), so an offline citizenid
--- cannot have an active pairing to tear down in the first place — this
--- function only does anything when the citizenid resolves to a currently
--- connected server id.
--- @param citizenid string
--- @param reason string
local function ForceDetachLeashIfOnline(citizenid, reason)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    if onlineSrc then
        ForceDetachLeashForSource(onlineSrc, reason)
    end
end

--- Returns true if `err` (the value pcall caught around the grant INSERT)
--- represents a MySQL/MariaDB duplicate-key error (1062) on
--- `uq_one_active_cert_per_job`. The exact shape of an error surfaced
--- through oxmysql's `.await` wrapper could not be confirmed against a
--- live oxmysql install in this sandbox, so this checks every shape the
--- underlying mysql2 driver is documented to use (a table with an
--- `.errno`/`.code` field, or a plain string containing the code) rather
--- than assuming one specific shape.
--- @param err any
--- @return boolean
local function IsDuplicateKeyError(err)
    if type(err) == 'table' then
        if err.errno == 1062 or err.code == 1062 then return true end
        local message = err.message or err.sqlMessage
        if type(message) == 'string' and (message:find('1062', 1, true) or message:find('ER_DUP_ENTRY', 1, true)) then
            return true
        end
    elseif type(err) == 'string' then
        if err:find('1062', 1, true) or err:find('ER_DUP_ENTRY', 1, true) or err:find('Duplicate entry', 1, true) then
            return true
        end
    end
    return false
end

-- SECURITY FIX (coder-security, final pass): grant/revoke are the single
-- most sensitive server-authoritative actions this resource exposes (they
-- ARE the permission system, per this file's header) — yet, unlike
-- server/main.lua's bark relay (BARK_COOLDOWN_MS) and leash-request
-- (LEASH_REQUEST_COOLDOWN_MS), nothing rate-limited them at all. An already
-- eligible certifier-grade officer (or one who self-certifies, per
-- Config.AllowSelfCertification) could otherwise script a tight
-- grant/revoke toggle loop against a nearby target — each iteration costs
-- at least one DB round trip, and on a real state flip, an INSERT/UPDATE
-- plus notifications to two players plus a leash force-detach check. Mirror
-- the exact same per-source cooldown pattern already established elsewhere
-- in this resource. Keyed by the CERTIFIER's own source (granterSrc), not
-- the target, so it throttles how often a given officer can issue ANY
-- certify/revoke action (online, offline, or self), independent of which
-- target/department is named.
local CERTIFY_ACTION_COOLDOWN_MS = 1500

-- REFACTOR_ROADMAP.md item 1: was its own hand-rolled `lastCertifyActionAt`
-- table, now a NewCooldown() instance (server/cooldowns.lua) — same
-- threshold, same per-granter-source key, same playerDropped-based cleanup
-- (see CertifyActionCooldown.RegisterPlayerDropped() below), behavior
-- unchanged. IsCertifyActionOnCooldown below keeps its original name/
-- boolean-sense ("true" = on cooldown) so its three call sites don't need
-- to change at all — it's a thin wrapper around
-- `not CertifyActionCooldown.Consume(...)`, preserving the exact original
-- "check, and stamp iff not on cooldown" ordering.
local CertifyActionCooldown = NewCooldown(CERTIFY_ACTION_COOLDOWN_MS)
CertifyActionCooldown.RegisterPlayerDropped()

--- @param granterSrc number
--- @return boolean onCooldown
local function IsCertifyActionOnCooldown(granterSrc)
    return not CertifyActionCooldown.Consume(granterSrc)
end

--- SPEC.md §4.2/§4.3 grant flow. Called by both event 2 and command 6.
--- @param granterSrc number
--- @param targetServerId number
local function GrantCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, 'Invalid target.', 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, 'You are not authorized to certify K9 handlers.', 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    -- §4.1: self-certification only allowed if the flag is enabled.
    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, 'Self-certification is disabled on this server.', 'error')
        return
    end

    -- Grant requires an online target — unlike revoke, which SPEC.md
    -- §4.3's flow table explicitly documents as working offline.
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, 'Target must be online to be certified.', 'error')
        return
    end

    -- §4.2.3: cross-department granting IS currently allowed (open
    -- question §9.2 in SPEC.md, not resolved here) — this only requires
    -- the target be in *some* configured department, not the SAME one as
    -- the granter. Do not silently restrict to same-department.
    local targetJob = targetPlayer.PlayerData.job
    if not targetJob or not Config.Departments[targetJob.name] then
        NotifyPlayer(granterSrc, 'Target is not employed by an eligible department.', 'error')
        return
    end

    -- §4.2.4 proximity — skipped only for self-cert (nothing to measure
    -- distance to). Live server-side coordinates only, never client-claimed.
    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, 'Target is too far away to certify.', 'error')
            return
        end
    end

    -- §4.2.5 (grant-only, applies UNIFORMLY even to self-certification):
    -- target's LIVE server-side ped model must be a configured K9 model.
    local targetModel = GetEntityModel(GetPlayerPed(targetServerId))
    if not IsConfiguredK9Model(targetModel) then
        NotifyPlayer(granterSrc, 'Target is not playing a recognized K9 model.', 'error')
        return
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetJob.name

    -- App-level pre-check (§4.3 invariant: at most one active row per
    -- (citizenid, job)) — backstopped below by the DB's unique index in
    -- case of a check-then-act race.
    local existingId = MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', {
        targetCitizenid, jobName,
    })
    if existingId then
        NotifyPlayer(granterSrc, 'Target already holds an active certification for this department.', 'inform')
        return
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        NotifyPlayer(granterSrc, 'Unable to resolve your own citizen ID.', 'error')
        return
    end

    local insertOk, insertResultOrErr = pcall(MySQL.insert.await, 'INSERT INTO k9_certifications (citizenid, job, granted_by) VALUES (?, ?, ?)', {
        targetCitizenid, jobName, granterCitizenid,
    })

    if not insertOk then
        if IsDuplicateKeyError(insertResultOrErr) then
            -- Another request won the check-then-act race between the
            -- pre-check above and this INSERT (SPEC.md §4.3 DB-level
            -- backstop, `uq_one_active_cert_per_job`) — treat identically
            -- to the normal "already certified" no-op, not as an
            -- unhandled error.
            RefreshCertificationCache(targetCitizenid, jobName)
            NotifyPlayer(granterSrc, 'Target already holds an active certification for this department.', 'inform')
            return
        end

        print(('[qbx_k9unit] GrantCertification INSERT failed for %s/%s: %s'):format(targetCitizenid, jobName, tostring(insertResultOrErr)))
        NotifyPlayer(granterSrc, 'An error occurred while certifying the target.', 'error')
        return
    end

    RefreshCertificationCache(targetCitizenid, jobName)

    -- Read-only mirror for client HUD display ONLY (SPEC.md §4.3) — NEVER
    -- read by any server-side authorization check. Do not add a read of
    -- this field to HasK9Access or any other gate.
    targetPlayer.Functions.SetMetaData('k9certified', true)

    NotifyPlayer(granterSrc, 'Target has been certified as a K9 handler.', 'success')
    NotifyPlayer(targetServerId, 'You have been certified as a K9 handler.', 'success')
end

--- SPEC.md §4.2/§4.3 revoke flow (manual). Called by both event 3 and
--- command 7. Must work even when the target is offline (§4.3). Does NOT
--- run the model check (§4.2.5 applies to grant only).
--- @param granterSrc number
--- @param targetServerId number
local function RevokeCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, 'Invalid target.', 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, 'You are not authorized to revoke K9 certifications.', 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, 'Self-certification is disabled on this server.', 'error')
        return
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid, targetJobName, targetIsOnline

    if targetPlayer and targetPlayer.PlayerData then
        targetIsOnline = true
        targetCitizenid = targetPlayer.PlayerData.citizenid
        targetJobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name

        -- Online target: same proximity rule as grant (§4.2.4), skipped
        -- only for self-cert (nothing to measure distance to).
        if not isSelfCert then
            local granterPed = GetPlayerPed(granterSrc)
            local targetPed = GetPlayerPed(targetServerId)
            local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
            if dist > Config.CertifyProximityMeters then
                NotifyPlayer(granterSrc, 'Target is too far away to revoke their certification.', 'error')
                return
            end
        end
    else
        -- CONFIRMED READING: a disconnected player has no live server id /
        -- ped at all — GetPlayer(source) only ever resolves a CURRENTLY
        -- CONNECTED player, and FiveM invalidates/recycles numeric source
        -- ids on disconnect. §4.2 point 4's proximity check is inherently
        -- a comparison of two LIVE ped coordinates; with no live target
        -- ped to read a position from, that check cannot apply and is
        -- skipped by necessity for a genuinely offline target.
        --
        -- This function's numeric targetServerId contract still can't
        -- translate a stale/disconnected id back into a citizenid + job,
        -- so it cannot itself serve a genuinely offline target — SPEC.md
        -- §4.3 requires manual revoke to work offline regardless (it's the
        -- explicit rationale for a DB table over metadata in the first
        -- place), so that gap is closed separately by
        -- RevokeCertificationOffline / the `/k9decertifyoffline [citizenid]
        -- [job]` command below, which takes a citizenid directly instead of
        -- a server id for exactly this reason. This function simply
        -- reports the mismatch back to the granter so they know to use
        -- that command instead of assuming this one silently worked.
        NotifyPlayer(granterSrc, 'That player is not currently connected; use /k9decertifyoffline [citizenid] [job] to revoke an offline handler.', 'error')
        return
    end

    if not targetJobName or not Config.Departments[targetJobName] then
        NotifyPlayer(granterSrc, 'Target does not hold a certification for an eligible department.', 'error')
        return
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        NotifyPlayer(granterSrc, 'Unable to resolve your own citizen ID.', 'error')
        return
    end

    -- No LIMIT needed — uq_one_active_cert_per_job guarantees at most one
    -- row matches (SPEC.md §4.3).
    local affectedRows = MySQL.update.await(
        'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
        { granterCitizenid, targetCitizenid, targetJobName }
    )

    if not affectedRows or affectedRows == 0 then
        NotifyPlayer(granterSrc, 'Target does not hold an active certification for this department.', 'inform')
        return
    end

    if targetIsOnline then
        RefreshCertificationCache(targetCitizenid, targetJobName)
        -- HUD display mirror only (SPEC.md §4.3) — never read for authorization.
        targetPlayer.Functions.SetMetaData('k9certified', false)
        NotifyPlayer(targetServerId, 'Your K9 certification has been revoked.', 'error')

        -- QA finding fix: an active leash pairing must not outlive the
        -- K9-role party's certification (SPEC.md §1/§4.4 "immediately") —
        -- see ForceDetachLeashIfOnline's doc comment above. `targetServerId`
        -- is already a live, currently-connected server id here (we're
        -- inside the `targetIsOnline` branch), so force-detach directly
        -- rather than re-resolving by citizenid.
        ForceDetachLeashForSource(targetServerId, 'certification_revoked')
    end

    NotifyPlayer(granterSrc, 'K9 certification revoked.', 'success')
end

--- SPEC.md §4.3 offline-capable revoke flow (manual). Called only by the
--- '/k9decertifyoffline [citizenid] [job]' command — see that command's
--- registration below and this file's header (item 7b) for why there is
--- no client-triggerable event equivalent (a disconnected target has no
--- client to trigger anything from). Closes the gap RevokeCertification
--- above cannot: that function's numeric targetServerId contract can only
--- ever resolve a currently-connected player, but SPEC.md §4.3 requires
--- manual revoke to work on a genuinely offline target (this is the
--- explicit stated rationale for choosing a dedicated DB table as the
--- source of truth over qbx_core metadata in the first place — an
--- admin/chief must be able to pull a cert from someone who isn't logged
--- in right now). Same eligibility rule as the online path. Deliberately
--- has NO proximity check (impossible against a disconnected target — the
--- entire point of this path) and NO model check (revoke never runs the
--- model check regardless of online/offline status, per §4.2.5 being
--- grant-only).
--- @param granterSrc number
--- @param citizenid string
--- @param job string
local function RevokeCertificationOffline(granterSrc, citizenid, job)
    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, 'You are not authorized to revoke K9 certifications.', 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        NotifyPlayer(granterSrc, 'Usage: /k9decertifyoffline [citizenid] [job]', 'error')
        return
    end

    -- Reject a typo'd/unconfigured job outright rather than silently
    -- no-opping against a job name that could never have an active row.
    if not Config.Departments[job] then
        NotifyPlayer(granterSrc, ("'%s' is not a configured department."):format(job), 'error')
        return
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        NotifyPlayer(granterSrc, 'Unable to resolve your own citizen ID.', 'error')
        return
    end

    -- SECURITY FIX (coder-security review): this command exists ONLY to
    -- reach a genuinely disconnected target (see this function's header
    -- and SPEC.md §4.3) — that's the entire justification for skipping
    -- §4.2 condition 4's proximity check. But nothing previously verified
    -- the target was actually offline before running the update: an
    -- eligible certifier could call `/k9decertifyoffline [citizenid] [job]`
    -- against a target who is CURRENTLY ONLINE and standing anywhere on
    -- the map (or the other side of it), silently bypassing
    -- Config.CertifyProximityMeters — the exact "remote/cross-map
    -- certifying via a spoofed command" scenario §4.2 condition 4 is
    -- meant to prevent for "both the ox_target flow and the slash-command
    -- flow." Close that gap: if the citizenid resolves to a currently
    -- connected player, refuse this path and point the caller at
    -- `/k9decertify [server id]`, which enforces the real proximity check.
    -- CONFIDENCE NOTE: exports.qbx_core:GetPlayerByCitizenId(citizenid) is
    -- used here per established QBCore/Qbox convention (the standard
    -- citizenid-keyed counterpart to GetPlayer); not independently
    -- verified against a live qbx_core install in this sandbox — same
    -- caveat as this file's other qbx_core-export notes.
    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, ('That citizen is currently online (server id %d) — use /k9decertify [server id] instead, which enforces the proximity check.'):format(onlineCheckTarget.PlayerData.source), 'error')
        return
    end

    -- No LIMIT needed — uq_one_active_cert_per_job guarantees at most one
    -- row matches (SPEC.md §4.3). Same UPDATE pattern as the online path.
    local affectedRows = MySQL.update.await(
        'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
        { granterCitizenid, citizenid, job }
    )

    if not affectedRows or affectedRows == 0 then
        -- Distinguish "no matching active cert" from success — a granter
        -- typo'ing a citizenid should not look identical to a real revoke.
        NotifyPlayer(granterSrc, 'That citizen does not hold an active certification for that department.', 'inform')
        return
    end

    -- Regression-test fix: unlike RevokeCertification's online branch and
    -- the QBCore:Server:OnJobUpdate auto-revoke handler (both of which call
    -- RefreshCertificationCache immediately after their UPDATE), this path
    -- previously left a stale `active = true` in-memory cache entry behind
    -- for a citizenid who was online, disconnected, and then got
    -- offline-revoked — until their next PlayerLoaded fires and re-queries
    -- fresh. RefreshCertificationCache is a plain DB-query-and-cache-write
    -- function with no live-source requirement, so it's safe to call
    -- unconditionally here even for a genuinely offline citizenid: it will
    -- simply cache `active = false` for whenever they next connect, rather
    -- than leaving a drifted entry around. Matches SPEC.md §4.3's
    -- "invalidated/updated immediately on grant/revoke events".
    RefreshCertificationCache(citizenid, job)

    -- Regression-test fix: keep the read-only `k9certified` HUD mirror
    -- (SPEC.md §4.3 — never read for authorization, see GrantCertification's
    -- comment on the same field) from drifting stale. The online guard
    -- above already refused this whole path if the citizenid resolved to a
    -- connected player at the time it was checked, so this is normally a
    -- no-op; it only matters for the narrow TOCTOU window where the target
    -- reconnects between that guard and this UPDATE completing — same
    -- window ForceDetachLeashIfOnline below is already written to cover.
    local nowOnlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if nowOnlinePlayer and nowOnlinePlayer.PlayerData and nowOnlinePlayer.PlayerData.source then
        nowOnlinePlayer.Functions.SetMetaData('k9certified', false)
    end

    -- QA finding fix (SPEC.md §1/§4.4): tear down an active leash pairing
    -- for this citizenid if one exists. In the overwhelmingly common case
    -- this is a genuine no-op — the online guard above already refused
    -- this path if the citizenid resolved to a connected player at that
    -- point, and LeashPairs is in-memory-only so a genuinely offline
    -- target cannot have an active pairing to begin with. It's still
    -- called here (rather than assumed unreachable) to close the narrow
    -- TOCTOU window where the target reconnects between the online guard
    -- above and this UPDATE completing — see ForceDetachLeashIfOnline's
    -- doc comment.
    ForceDetachLeashIfOnline(citizenid, 'certification_revoked')

    NotifyPlayer(granterSrc, 'K9 certification revoked.', 'success')
end

--- SPEC.md §4.4 (NEW): automatic revoke when actually leaving the
--- department (not on a same-department grade change). Server-only path —
--- never exposed as a client-callable event.
--- @param source number
--- @param job table  -- new PlayerJob object, per qbx_core's event payload
AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return end

    local citizenid = Player.PlayerData.citizenid

    -- Regression-test fix: SECOND, INDEPENDENT check from the
    -- certification-revocation branch below — an officer/handler leashed
    -- to a K9 never holds a K9 certification of their own (SPEC.md §9 item
    -- 9: their access is pure Config.Departments membership, not a cert),
    -- so the cert-revocation branch below (gated on `cached.active`) can
    -- never observe them losing eligibility. If this citizenid's NEW job no
    -- longer satisfies Config.Departments membership, force-detach any
    -- leash where `source` is currently the officer-role party — this is
    -- not a variant of the cert-revoke path, it's a wholly separate
    -- eligibility loss (department membership, not certification) that
    -- CheckLeashEligibility in server/main.lua already refuses on
    -- re-attach, so an already-formed pairing must not be allowed to
    -- outlive it either. See server/main.lua's ForceDetachOfficerLeashForSource
    -- for the role check (only actually detaches if `source` is the
    -- officer/handler-role, not K9-role, party of its pairing).
    if not job or not Config.Departments[job.name] then
        ForceDetachOfficerLeashForSource(source, 'department_changed')
    end

    local cached = Certifications[citizenid]

    -- No active cert to revoke, nothing to do.
    if not (cached and cached.active) then return end

    -- SAME department, this is a grade/promotion change, NOT a department
    -- change (§4.4 "Important consequences": a promotion/demotion must
    -- NOT revoke the certification). This guard is the entire point of
    -- storing `.job` on the cache — do not remove it or every promotion
    -- silently strips certs.
    if not job or job.name == cached.job then return end

    local oldJob = cached.job

    MySQL.update.await(
        'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
        { 'system:job_change', citizenid, oldJob }
    )

    -- Repopulate the cache scoped to the NEW job (almost certainly
    -- active = false unless they already hold a separate active cert for
    -- that new department from a prior stint — a fresh grant is required
    -- either way per SPEC.md §9 item 3).
    RefreshCertificationCache(citizenid, job.name)

    -- Regression-test fix: keep the read-only `k9certified` HUD mirror
    -- (SPEC.md §4.3) in sync here too — this player is online by
    -- definition (OnJobUpdate fired for their live Player object), so this
    -- is a plain, unconditional write, no online-check needed.
    Player.Functions.SetMetaData('k9certified', false)

    local deptLabel = (Config.Departments[oldJob] and Config.Departments[oldJob].label) or oldJob
    NotifyPlayer(source, ('Your K9 certification has been revoked — you are no longer employed by %s.'):format(deptLabel), 'error')

    -- QA finding fix (SPEC.md §1/§4.4 "immediately"): this player is
    -- online by definition (OnJobUpdate fired for their live `source`), so
    -- force-detach directly rather than re-resolving by citizenid — same
    -- reasoning as the online branch of RevokeCertification above.
    ForceDetachLeashForSource(source, 'certification_revoked')
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
    -- Validate args[1] is actually numeric before calling into the grant
    -- flow — a modified/careless caller could hand this a non-numeric
    -- string, and GrantCertification's own `type(targetServerId) ~=
    -- 'number'` guard exists for the net-event path, but the command path
    -- should reject with a clear usage message instead of silently
    -- forwarding nil.
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, 'Usage: /k9certify [server id]', 'error')
        return
    end
    GrantCertification(source, targetServerId)
end, false)

RegisterCommand('k9decertify', function(source, args)
    -- Same arg validation as k9certify above.
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, 'Usage: /k9decertify [server id]', 'error')
        return
    end
    RevokeCertification(source, targetServerId)
end, false)

-- Offline-capable counterpart to /k9decertify — see RevokeCertificationOffline
-- above and this file's header (command 7b) for why this exists as a
-- separate, citizenid-keyed command rather than extending the numeric
-- targetServerId contract used everywhere else.
RegisterCommand('k9decertifyoffline', function(source, args)
    local citizenid = args[1]
    local job = args[2]
    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        NotifyPlayer(source, 'Usage: /k9decertifyoffline [citizenid] [job]', 'error')
        return
    end
    RevokeCertificationOffline(source, citizenid, job)
end, false)

-- CONFIDENCE NOTE (not silently asserted as verified fact): no qbx_core
-- install was reachable in this sandbox to inspect its actual
-- exports/events against (the filesystem was searched; only this
-- resource's own files exist here). SPEC.md §4.4 already confirms
-- 'QBCore:Server:OnJobUpdate' as a real, current qbx_core
-- compatibility-bridge event. The player-load equivalent below,
-- 'QBCore:Server:PlayerLoaded', is used here with MEDIUM-HIGH confidence
-- based on established Qbox/QBCore convention — it is the same
-- foundational legacy event name every pre-existing QB job/feature
-- resource depends on, and the same compatibility bridge confirmed to
-- preserve OnJobUpdate is documented (docs.qbox.re) to preserve this one
-- too — but it is NOT independently verified against live qbx_core source
-- in this session. If the cache silently stays empty for freshly-loaded
-- players (they show as uncertified despite holding a real active row),
-- check this event name against the actual installed qbx_core version
-- first.
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local job = Player.PlayerData.job
    if not job then return end
    local citizenid = Player.PlayerData.citizenid
    RefreshCertificationCache(citizenid, job.name)

    -- Regression-test fix: resync the read-only `k9certified` HUD mirror
    -- (SPEC.md §4.3 — never read for authorization) from whatever value
    -- RefreshCertificationCache just determined. The mirror can drift
    -- while a player is offline (e.g. RevokeCertificationOffline revoking
    -- their cert while disconnected) since it's only otherwise written by
    -- GrantCertification, RevokeCertification's online branch, and
    -- OnJobUpdate's auto-revoke — this self-corrects it on every login
    -- regardless of which path (or no path) caused the drift.
    -- RefreshCertificationCache always populates Certifications[citizenid],
    -- so `cached` is guaranteed non-nil immediately after the call above.
    local cached = Certifications[citizenid]
    Player.Functions.SetMetaData('k9certified', cached.active)
end)

-- Regression-test fix: `Certifications` is keyed by citizenid and
-- accumulates one entry per distinct citizenid ever loaded this session —
-- unlike LeashPairs/PendingLeashRequests/lastBarkAt in server/main.lua
-- (all cleared per-source in that file's playerDropped handler), nothing
-- ever evicted an entry here, so a long-running server slowly grows this
-- table forever. Not a correctness bug (a stale entry for a now-offline
-- citizenid is simply never read again until PlayerLoaded repopulates it
-- fresh), just unbounded memory growth. Resolve the citizenid for the
-- disconnecting source via qbx_core (still resolvable here — playerDropped
-- fires before the framework fully tears down the player object) and drop
-- its cache entry; it's harmlessly rebuilt from a fresh DB query on their
-- next PlayerLoaded/OnJobUpdate/certify/revoke touch.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        Certifications[citizenid] = nil
    end

    -- REFACTOR_ROADMAP.md item 1: CertifyActionCooldown already registered
    -- its OWN `playerDropped` handler via :RegisterPlayerDropped() above
    -- (same unbounded-growth reasoning as Certifications above — keyed by
    -- server id (src) rather than citizenid since CERTIFY_ACTION_COOLDOWN_MS
    -- throttles the CERTIFIER's connection, not any particular citizenid),
    -- so nothing needs to happen here for it anymore.
end)
