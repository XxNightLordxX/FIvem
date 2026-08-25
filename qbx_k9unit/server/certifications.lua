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

    MINOR SPEC INCONSISTENCY, PREVIOUSLY FLAGGED, NOW CORRECTED (issue-closer
    sweep): §4.1's access-rule paragraph used to say access is "checked
    server-side on every access point (menu open request *and* the actual
    spawn request — not just once)" — "the actual spawn request" was
    leftover text from the pre-correction draft, since there is no spawn
    request anymore. SPEC.md §4.1 has since been reworded ("checked
    server-side on every gated action that grants a real capability ...
    not cached client-side as a one-time pass") and no longer contains the
    stale clause — nothing left to flag here.

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
    - THIS FILE also calls `ForceBreakPartnershipForCitizenId(citizenid,
      reason)`, exposed by server/partnership.lua (Phase 3, PHASE3_SPEC.md
      §12.0 item 7), alongside all FOUR existing leash-teardown call sites
      in this file: RevokeCertification's online branch
      (ForceDetachLeashForSource), RevokeCertificationOffline
      (ForceDetachLeashIfOnline), and the QBCore:Server:OnJobUpdate
      handler's TWO branches — department-loss
      (ForceDetachOfficerLeashForSource) and cert-revoke-due-to-job-change
      (ForceDetachLeashForSource) — a K9 partnership must not outlive
      either party's cert revocation or department loss any more than a
      leash pairing may. Guarded at each call site by a
      `type(...) == 'function'` runtime existence check (this resource's
      established "runtime existence guard, not a load-order assumption"
      convention — see fxmanifest.lua's own comment on server/medkit.lua's
      RestoreInjury reuse for the precedent), since server/partnership.lua
      is loaded AFTER this file in fxmanifest.lua's server_scripts and its
      Config.Features.HandlerPartnership feature flag may be off entirely
      on a given server. Called UNCONDITIONALLY of that flag's current
      value at each site (not gated on `Config.Features.HandlerPartnership`
      here) — a partnership row established while the feature was on must
      still be torn down by a cert revoke/department change even if the
      flag was later flipped off, since ForceBreakPartnershipForCitizenId
      is itself already a cheap, safe no-op when `citizenid` has no active
      partnership row to tear down.
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

-- ======================================================================
-- CONFIG-SAFETY GUARD (coder-backend, this pass) — every sibling server
-- file (propattachment.lua, bonetool.lua, progression.lua, admin.lua,
-- search.lua) asserts its own config's shape loudly, failing resource
-- start on a genuine misconfiguration; THIS file — the authorization root
-- HasK9Access gates nearly every other feature behind — had none (found
-- and reported by the agent that wrote tests/certifications_spec.lua's 47
-- cases, which deliberately did not fabricate startup-assert tests for
-- asserts that did not exist).
--
-- Run UNCONDITIONALLY, at this file's own LOAD time — NOT deferred into an
-- onResourceStart handler the way every sibling file above does it. That
-- matters here specifically: the K9ModelHashes block immediately below
-- this guard already reads Config.Peds and calls GetHashKey on every
-- entry's model field the instant this file itself loads, at file scope —
-- by the time any onResourceStart handler could run, that read has
-- already happened. config.lua is a shared_script, loaded in full before
-- any server_scripts file (this one included) starts executing, so Config
-- already holds its real, final values by the time this line runs — not a
-- load-order gamble, the same reasoning server/search.lua's own
-- file-load-time ContrabandItemSet precomputation comment already gives
-- for the identical structural point ("config.lua is a shared_script,
-- loaded before this file").
--
-- CHECKED AGAINST THE ACTUAL SHIPPED config.lua before writing every
-- assert below (Config.Departments.police/sheriff/bcso — certifierGrade
-- 4/3/3, autoAccessGrade nil for all three; Config.Peds' four real a_c_*
-- models; Config.CertifyProximityMeters = 5.0): every one of them passes
-- against the real shipped config. Also re-run against
-- tests/certifications_spec.lua's own newFixture() default Config shape
-- (2-department Config.Departments, 2-entry Config.Peds, proximityMeters
-- default 5.0) and its explicit autoAccessGrade-bypass fixtures (10, an
-- integer) — none of the spec's 47 cases construct a Config shape any of
-- these asserts would reject.
-- ======================================================================
assert(type(Config.Departments) == 'table',
    '[qbx_k9unit] Config.Departments must be a table -- HasK9Access, IsEligibleCertifier, and every ' ..
    'certify/revoke path index it by job.name to decide K9 access and certifier eligibility; a missing ' ..
    'table would make every job fail K9 access outright, with the failure surfacing only as "nobody can ' ..
    'ever use K9 features," never as a clear config error.')
for jobName, dept in pairs(Config.Departments) do
    assert(type(dept) == 'table',
        ('[qbx_k9unit] Config.Departments[%s] must be a table with certifierGrade/autoAccessGrade/label fields -- ' ..
        'IsEligibleCertifier and HasK9Access both index straight into it (dept.certifierGrade, dept.autoAccessGrade) ' ..
        'with no type guard of their own.'):format(tostring(jobName)))
    assert(type(dept.certifierGrade) == 'number',
        ('[qbx_k9unit] Config.Departments[%s].certifierGrade must be a number -- IsEligibleCertifier compares ' ..
        'job.grade.level >= dept.certifierGrade directly for every non-boss officer in this department. A ' ..
        'malformed value here (nil, a string, a boolean) surfaces as a certifier who can silently never certify ' ..
        'or revoke anyone in this department, with no error and nothing logged -- exactly the failure mode this ' ..
        'assert exists to catch at start instead.'):format(jobName))
    assert(dept.autoAccessGrade == nil or type(dept.autoAccessGrade) == 'number',
        ('[qbx_k9unit] Config.Departments[%s].autoAccessGrade must be nil (no auto-bypass -- the shipped default, ' ..
        'and a legitimate, MUST-stay-valid value) or a number -- HasK9Access only ever treats it as a bypass ' ..
        'threshold when `type(dept.autoAccessGrade) == \'number\'` holds; any other non-nil value (a string, a ' ..
        'boolean, a table) silently disables the bypass with no error, which looks identical to a deliberate nil ' ..
        'to whoever configured it.'):format(jobName))
end

--- Precomputed set of Config.Peds model hashes, built once at file load.
--- Used ONLY by the grant-time model check (§4.2 condition 5) — per
--- §4.1/§4.5, ordinary access checks (HasK9Access) never consult this.
--- Generic over Config.Peds — no hardcoded model name anywhere (SPEC.md §3
--- acceptance bullet 3), including custom streamed entries.
--
-- CONFIG-SAFETY GUARD (coder-backend, this pass) — see the block above
-- this comment for the full "why load time, not onResourceStart"
-- reasoning; this specific assert must run BEFORE the `for` loop three
-- lines below it, since that loop is what actually calls GetHashKey on
-- every entry.
assert(type(Config.Peds) == 'table' and #Config.Peds > 0,
    '[qbx_k9unit] Config.Peds must be a non-empty array -- K9ModelHashes (built immediately below, at this ' ..
    'file\'s own load time) is derived entirely from it, and IsConfiguredK9Model (the grant-time model check, ' ..
    'SPEC.md §4.2.5) could never accept ANY model if this were empty or malformed -- every certification grant ' ..
    'attempt would fail with "target not K9 model" regardless of the target\'s actual ped.')
for i, pedEntry in ipairs(Config.Peds) do
    assert(type(pedEntry) == 'table' and type(pedEntry.model) == 'string' and pedEntry.model ~= '',
        ('[qbx_k9unit] Config.Peds[%d].model must be a non-empty string -- GetHashKey(pedEntry.model) is called ' ..
        'on it at this file\'s own load time to build K9ModelHashes; a missing/empty/non-string model here means ' ..
        'that entry can never be matched by IsConfiguredK9Model, silently and permanently, with nothing logged ' ..
        'to explain why a real K9 model never passes the grant-time check.'):format(i))
end

assert(type(Config.CertifyProximityMeters) == 'number' and Config.CertifyProximityMeters > 0,
    '[qbx_k9unit] Config.CertifyProximityMeters must be a positive number -- GrantCertification and ' ..
    'RevokeCertification both compare a live, server-measured distance against it (SPEC.md §4.2.4) before ' ..
    'allowing an online grant/revoke. Zero or negative would make every such attempt fail as "too far" ' ..
    'regardless of actual proximity, and a non-number would throw at the very first certify/revoke attempt ' ..
    'instead of failing loudly here at resource start.')

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

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by REFACTOR_ROADMAP.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- ox_lib's `ox_lib:notify` client event was chosen there
-- over exports.qbx_core:Notify for the same reason this file's own original
-- comment gave (a stable, publicly documented API of an already-declared
-- dependency; qbx_core's own Notify export name/signature could not be
-- independently confirmed in this sandbox -- see the CONFIDENCE NOTE near
-- the bottom of this file for the same caveat applied to the player-loaded
-- event name). Every call site below is unchanged: this file's own calls
-- always passed a `notifyType` and never a custom title, which is exactly
-- server/notify.lua's default title, so nothing here needed editing beyond
-- deleting this local copy.

--- Server-authoritative check: is `source` currently allowed to use K9
--- features? SPEC.md §4.1 "Access rule": job.name in Config.Departments
--- AND (active cert cached for that job OR configured autoAccessGrade
--- bypass OR High Command — server/highcommand.lua's IsHighCommand,
--- project-owner-directed this pass, see that file's own header for the
--- full "run any command" contract). Deliberately does NOT check ped model
--- (§4.5) — see the contract block above for why that's intentional, not
--- an oversight. Exposed globally (no `local`) — server/main.lua calls this directly.
--- @param source number
--- @return boolean
function HasK9Access(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- PERMISSION GRANT BYPASS (server/permissions.lua, Config.Features.PermissionGrants,
    -- resolution-order STEP 1 -- see that file's own header for the full
    -- 4-step contract: "an active granted 'k9.access' permission -> ALLOW",
    -- checked before the high-command bypass and the legacy cert-cache/
    -- autoAccessGrade gate below, matching config.lua's own documented
    -- "first match wins" order). Guarded by a `type(...) == 'function'`
    -- runtime existence check, this resource's established soft-dependency
    -- convention -- this function still works exactly as before if
    -- server/permissions.lua is ever removed or Config.Features.PermissionGrants
    -- is false (HasPermission re-checks that flag itself and returns false).
    if type(HasPermission) == 'function' and HasPermission(Player.PlayerData.citizenid, 'k9.access') then return true end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- project-owner-directed this pass) -- "the certification requirement
    -- itself" is explicitly one of the gates a High Command officer must
    -- bypass (see that file's own header PART 1 for the full contract).
    -- Guarded by a `type(...) == 'function'` runtime existence check, this
    -- resource's established soft-dependency convention (see
    -- fxmanifest.lua's comment on server/medkit.lua's RestoreInjury reuse
    -- for the precedent) -- this function still works exactly as before if
    -- server/highcommand.lua is ever removed or Config.Features.HighCommand
    -- is false (IsHighCommand re-checks that flag itself and returns false).
    -- Checked BEFORE the cert-cache read below so a high-command officer
    -- with no active cert of their own is granted access without needing
    -- one -- this is a genuine bypass, not merely an alternate cache hit.
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    -- The `cached.job == job.name` re-check matters right around a job
    -- change, before RefreshCertificationCache has run for the new job —
    -- don't trust a stale cache entry scoped to an old job.
    local cached = Certifications[Player.PlayerData.citizenid]
    if cached and cached.active and cached.job == job.name then
        return true
    end

    -- Opt-in bypass, defaults to nil/disabled per shipped config — do not
    -- change the default.
    --
    -- SECURITY FIX (coder-security, authorization-root runtime-nil review):
    -- `job.grade.level` was previously only checked for truthiness, not
    -- type — a non-nil, non-number `level` (a job object shaped
    -- differently than qbx_core's documented `{ name, level: number }`
    -- schema, e.g. a legacy/foreign job source) would reach
    -- `job.grade.level >= dept.autoAccessGrade` and throw an UNCAUGHT
    -- "attempt to compare number with <type>" error instead of failing
    -- closed. `dept.autoAccessGrade`'s own type is already guaranteed by
    -- the file-load-time assert above (`type(dept.autoAccessGrade) ==
    -- 'number'`, checked first via short-circuit `and`), so `type(job.grade
    -- .level) == 'number'` is the only remaining guard this comparison
    -- needs. An explicit type check, not a pcall: a pcall around this would
    -- convert a loud bug (a job object with the wrong shape reaching the
    -- access gate) into exactly the silent no-op this authorization path
    -- must never produce for the wrong reason. FAILS CLOSED — a
    -- non-number `level` makes this bypass evaluate to false (no access
    -- granted via this branch), never true; it does not touch the
    -- cert-cache branch above, so a real cached cert still grants access
    -- through that path regardless.
    local dept = Config.Departments[job.name]
    if type(dept.autoAccessGrade) == 'number' and job.grade and type(job.grade.level) == 'number' and job.grade.level >= dept.autoAccessGrade then
        return true
    end

    return false
end

--- Re-queries the active-cert row for (citizenid, jobName) and updates the
--- in-memory cache. Exposed globally (no `local`) — see FILE-TO-FILE
--- CONTRACT above for every call site.
---
--- Regression-test fix: this is the single most-called function in the
--- cert system (grant, both revoke paths, PlayerLoaded, OnJobUpdate, and
--- server/main.lua's onResourceStart backfill loop — which iterates every
--- connected player in one handler invocation — all call it), yet unlike
--- GrantCertification's INSERT (pcall-wrapped specifically because MySQL
--- errors are expected there) this read was previously unguarded. Per the
--- backfill loop's own comment in server/main.lua, an uncaught error here
--- would abort processing for every subsequent player in that loop — the
--- exact class of ship-blocking bug already found and fixed once in this
--- file for a different root cause. Wrap the read in pcall and, on
--- failure, log it and fail CLOSED (cache `active = false`) rather than
--- leaving stale/wrong cache state — matches this file's own access-gating
--- posture of never treating an unreadable cert row as an active grant.
--- @param citizenid string
--- @param jobName string
--- @return boolean active — the freshly-cached value, so callers (e.g.
--- server/main.lua's onResourceStart backfill, which has no access to the
--- local Certifications table below) don't need their own accessor just
--- to resync a dependent value like the k9certified metadata mirror.
function RefreshCertificationCache(citizenid, jobName)
    local queryOk, activeIdOrErr = pcall(MySQL.scalar.await, 'SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', {
        citizenid, jobName,
    })

    if not queryOk then
        print(('[qbx_k9unit] RefreshCertificationCache query failed for %s/%s: %s'):format(citizenid, jobName, tostring(activeIdOrErr)))
        -- FAIL CLOSED: an unreadable cert row must never be treated as an
        -- active grant — see doc comment above.
        Certifications[citizenid] = { active = false, job = jobName }
        return false
    end

    local active = activeIdOrErr ~= nil
    Certifications[citizenid] = { active = active, job = jobName }
    return active
end

--- Re-checks a SPECIFIC (citizenid, job) row's `active` column directly
--- against the DB, independent of and deliberately NOT via
--- RefreshCertificationCache's own return value -- see the three call
--- sites below (RevokeCertification, RevokeCertificationOffline, and the
--- QBCore:Server:OnJobUpdate auto-revoke branch) for why: that function's
--- fail-closed contract collapses "confirmed inactive" and "the read
--- itself failed" into the same `false`, which is the right call for an
--- ACCESS-checking consumer but the wrong one for a caller that just had
--- its OWN revoke UPDATE throw and needs to tell "the UPDATE genuinely
--- never committed" apart from "unreadable, true outcome unknown" before
--- deciding whether to report success or run any further side effects.
--- @param citizenid string
--- @param jobName string
--- @return boolean? active -- true/false if confirmed against the DB, nil if the read itself failed
local function IsCertRowConfirmedActive(citizenid, jobName)
    local ok, activeIdOrErr = pcall(MySQL.scalar.await, 'SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', {
        citizenid, jobName,
    })
    if not ok then
        print(('[qbx_k9unit] cert-row reconciliation read failed for %s/%s: %s'):format(citizenid, jobName, tostring(activeIdOrErr)))
        return nil
    end
    return activeIdOrErr ~= nil
end

--- SPEC.md §4.2 certifier eligibility check (granter side only — does not
--- check the target or proximity, see GrantCertification/RevokeCertification).
--- Also qualifies unconditionally for a High Command officer
--- (server/highcommand.lua's IsHighCommand, project-owner-directed this
--- pass — see that file's own header for the full "run any command"
--- contract), guarded by a `type(...) == 'function'` runtime existence
--- check inside the function body below.
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

    -- PERMISSION GRANT BYPASS (server/permissions.lua, Config.Features.PermissionGrants,
    -- resolution-order STEP 1) -- an active granted 'k9.certify' permission
    -- ALLOWS outright, checked before the high-command bypass and the
    -- certifierGrade comparison below, matching config.lua's own documented
    -- "first match wins" order. Guarded by a `type(...) == 'function'`
    -- runtime existence check -- this function still works exactly as
    -- before if server/permissions.lua is ever removed or
    -- Config.Features.PermissionGrants is false.
    if type(HasPermission) == 'function' and HasPermission(Player.PlayerData.citizenid, 'k9.certify') then return true end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- project-owner-directed this pass) -- certifierGrade is explicitly one
    -- of the gates a High Command officer must bypass (see that file's own
    -- header PART 1 for the full contract). Guarded by a
    -- `type(...) == 'function'` runtime existence check, this resource's
    -- established soft-dependency convention -- this function still works
    -- exactly as before if server/highcommand.lua is ever removed or
    -- Config.Features.HighCommand is false (IsHighCommand re-checks that
    -- flag itself and returns false). Placed here, right after the
    -- job.isboss short-circuit and before the certifierGrade comparison,
    -- mirroring the identical placement in server/admin.lua's
    -- IsAuthorizedAdmin and server/bonetool.lua's
    -- IsAuthorizedBoneSweepDevTool.
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    -- SECURITY FIX (coder-security, authorization-root runtime-nil review):
    -- verified against tests/certifications_spec.lua's own file-header
    -- note (which assumed a nil/non-number `dept.certifierGrade` makes this
    -- comparison "simply always false") — that assumption held for a nil
    -- `certifierGrade` only by accident of Lua's `>=` on two nils never
    -- being reached (the old code never got that far without erroring
    -- first for a NUMBER `job.grade.level` compared against a nil/string
    -- `certifierGrade`). `dept.certifierGrade` itself is now guaranteed to
    -- be a number by the file-load-time assert above and is never mutated
    -- after load (Config is a shared_script, read-only from every file in
    -- this resource — grepped, nothing writes Config.Departments[...] at
    -- runtime), so that operand can no longer be the problem. The
    -- remaining, still-open gap is the OTHER operand: `job.grade.level` was
    -- only ever checked for nil-ness, not type — a job object shaped
    -- differently than qbx_core's documented `{ name, level: number }`
    -- schema (a non-number `level`) reaches the `>=` below and throws an
    -- UNCAUGHT comparison error instead of failing closed. Explicit type
    -- check, not a pcall, for the same reason given on the autoAccessGrade
    -- branch in HasK9Access above: a pcall here would swallow a real
    -- shape-mismatch bug and turn it into exactly the silent "certifier who
    -- can never certify anyone" no-op this file's own asserts above exist
    -- to stop happening quietly. FAILS CLOSED — a non-number `level` makes
    -- this whole function return false (not eligible), never true; the
    -- `job.isboss` early-return above is unaffected and still grants
    -- eligibility for a boss regardless of grade shape, matching SPEC.md's
    -- documented "isboss always qualifies" rule.
    local dept = Config.Departments[job.name]
    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.certifierGrade
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

--- Fires a stable `qbx_k9unit:events:*` outbound event for other resources
--- (dispatch/MDT/evidence integrations — see server/exports.lua's header
--- "EVENT CONTRACT" section for the full documented contract this
--- implements). Every call site below fires this ONLY after its own DB
--- write has already committed and every eligibility check has already
--- passed — never optimistically, never inside a branch that can still
--- fail/roll back — so by the time this runs, this resource's own state
--- already reflects the change being announced.
---
--- `TriggerEvent` runs every `AddEventHandler` registered by every OTHER
--- resource on this server, SYNCHRONOUSLY, on this same call stack. A
--- misbehaving/buggy consumer resource's handler throwing must never be
--- able to unwind back into (and abort the remainder of) the certification/
--- partnership/search flow that triggered it — pcall-wrapped so a
--- consumer's exception is swallowed and logged here, never propagated.
--- Because this is only ever called AFTER the real state change already
--- committed, a pcall failure here can only ever mean "a consumer's own
--- handler broke," never "this resource's own DB/cache state disagrees
--- with what it just announced" — nothing above this call is undone or
--- retried based on whether the fire succeeds.
--- @param eventName string
--- @param ... any
local function FireOutboundEvent(eventName, ...)
    local ok, err = pcall(TriggerEvent, eventName, ...)
    if not ok then
        print(('[qbx_k9unit] outbound event %s: a registered handler in another resource errored: %s'):format(eventName, tostring(err)))
    end
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

-- SECURITY FIX (dedicated K9 pass, 2026-08-25): closes GrantCertification's
-- check-then-act TOCTOU on ITS OWN TERMS, independent of whether
-- `uq_one_active_cert_per_job` (SQL migration 0004) has actually been
-- applied to this install. GrantCertification's existingId-pre-check-then-
-- INSERT sequence awaits two separate MySQL round trips; each `.await`
-- yields this handler's coroutine and lets FXServer resume/process other
-- queued server events — including another GrantCertification call — before
-- it comes back. On an install that HAS run migration 0004, a second
-- concurrent grant for the SAME (citizenid, job) landing in that window is
-- still caught, by the DB's own unique index (see IsDuplicateKeyError
-- below). On an install that has NOT run it, there is neither that index
-- nor the `active_cert_key` column, and nothing previously stopped two
-- concurrent certify actions for the same target/department (e.g. two
-- different certifier-grade officers certifying the same target within the
-- same network round trip) from both observing `existingId == nil` and both
-- successfully INSERTing an active row — silently violating the "at most
-- one active row per (citizenid, job)" invariant this file's revoke paths
-- rely on ("No LIMIT needed -- uq_one_active_cert_per_job guarantees at
-- most one row matches"). This in-memory lock, keyed "citizenid:job" (the
-- invariant is scoped per department), makes that invariant hold at the
-- application level UNCONDITIONALLY. It is not a substitute for running
-- migration 0004 (which also backfills `active_cert_key` for unrelated
-- reasons) -- it is defense-in-depth that does not depend on the DB
-- constraint's presence. Always released in GrantCertification, even if an
-- unexpected error is thrown mid-flight (pcall-wrapped there), so a thrown
-- error can never leave a target permanently stuck un-grantable.
local GrantInFlight = {}

--- @param granterSrc number
--- @return boolean onCooldown
local function IsCertifyActionOnCooldown(granterSrc)
    return not CertifyActionCooldown.Consume(granterSrc)
end

--- Regression-test fix (extract at the 3rd occurrence — this codebase's own
--- established convention, see server/cooldowns.lua's own extraction
--- precedent): GrantCertification, RevokeCertification, and
--- RevokeCertificationOffline each independently re-resolved the granter's
--- OWN citizenid via exports.qbx_core:GetPlayer(granterSrc) and notified on
--- failure with byte-identical logic. Single source of truth now — calls
--- NotifyPlayer itself on failure so every call site can just early-return
--- on a nil result.
--- @param granterSrc number
--- @return string? citizenid — nil if unresolvable (NotifyPlayer already sent)
local function ResolveGranterCitizenId(granterSrc)
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        NotifyPlayer(granterSrc, locale('common.unable_to_resolve_citizenid'), 'error')
        return nil
    end
    return granterCitizenid
end

--- SPEC.md §4.2/§4.3 grant flow. Called by both event 2 and command 6.
--- @param granterSrc number
--- @param targetServerId number
local function GrantCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    -- §4.1: self-certification only allowed if the flag is enabled.
    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
        return
    end

    -- Grant requires an online target — unlike revoke, which SPEC.md
    -- §4.3's flow table explicitly documents as working offline.
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.target_must_be_online'), 'error')
        return
    end

    -- §4.2.3: cross-department granting IS currently allowed (open
    -- question §9.2 in SPEC.md, not resolved here) — this only requires
    -- the target be in *some* configured department, not the SAME one as
    -- the granter. Do not silently restrict to same-department.
    local targetJob = targetPlayer.PlayerData.job
    if not targetJob or not Config.Departments[targetJob.name] then
        NotifyPlayer(granterSrc, locale('certifications.target_not_in_department'), 'error')
        return
    end

    -- §4.2.4 proximity — skipped only for self-cert (nothing to measure
    -- distance to). Live server-side coordinates only, never client-claimed.
    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.target_too_far_to_certify'), 'error')
            return
        end
    end

    -- §4.2.5 (grant-only, applies UNIFORMLY even to self-certification):
    -- target's LIVE server-side ped model must be a configured K9 model.
    local targetModel = GetEntityModel(GetPlayerPed(targetServerId))
    if not IsConfiguredK9Model(targetModel) then
        NotifyPlayer(granterSrc, locale('certifications.target_not_k9_model'), 'error')
        return
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetJob.name

    -- SECURITY FIX (dedicated K9 pass, 2026-08-25): see GrantInFlight's own
    -- doc comment above for the full writeup. Reject outright (rather than
    -- queue/retry) if a grant for this exact (citizenid, job) is already in
    -- flight on this server — the in-flight attempt will resolve to success
    -- or failure on its own, and this caller's own click can simply be
    -- retried if it turns out to have lost the race.
    local lockKey = targetCitizenid .. ':' .. jobName
    if GrantInFlight[lockKey] then
        NotifyPlayer(granterSrc, locale('certifications.target_already_certified'), 'inform')
        return
    end
    GrantInFlight[lockKey] = true

    -- Everything from here down is the actual DB critical section this lock
    -- protects — wrapped in its own closure so it can be pcall'd as a unit
    -- below, guaranteeing GrantInFlight[lockKey] is released on EVERY exit
    -- path, including an unexpected thrown error, not just the normal
    -- early-return paths.
    local function doGrantInsert()
        -- App-level pre-check (§4.3 invariant: at most one active row per
        -- (citizenid, job)) — now protected at the application level
        -- unconditionally by GrantInFlight above, and further backstopped
        -- below by the DB's unique index in case that constraint is present
        -- on this install (see IsDuplicateKeyError).
        local existingId = MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', {
            targetCitizenid, jobName,
        })
        if existingId then
            NotifyPlayer(granterSrc, locale('certifications.target_already_certified'), 'inform')
            return
        end

        local granterCitizenid = ResolveGranterCitizenId(granterSrc)
        if not granterCitizenid then return end

        local insertOk, insertResultOrErr = pcall(MySQL.insert.await, 'INSERT INTO k9_certifications (citizenid, job, granted_by) VALUES (?, ?, ?)', {
            targetCitizenid, jobName, granterCitizenid,
        })

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                -- Another request won the check-then-act race between the
                -- pre-check above and this INSERT DESPITE GrantInFlight above
                -- — only possible if this install predates GrantInFlight ever
                -- having been held for the other request too (e.g. a very
                -- unlucky reload) or the DB already held a pre-existing
                -- duplicate from before this lock existed; the DB's own
                -- unique index (`uq_one_active_cert_per_job`, if present on
                -- this install) is what actually caught it here. Treat
                -- identically to the normal "already certified" no-op, not as
                -- an unhandled error.
                RefreshCertificationCache(targetCitizenid, jobName)
                NotifyPlayer(granterSrc, locale('certifications.target_already_certified'), 'inform')
                return
            end

            print(('[qbx_k9unit] GrantCertification INSERT failed for %s/%s: %s'):format(targetCitizenid, jobName, tostring(insertResultOrErr)))
            NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
            return
        end

        RefreshCertificationCache(targetCitizenid, jobName)

        -- Outbound integration event (server/exports.lua's EVENT CONTRACT §1) —
        -- fired here, after the cache refresh that itself follows the committed
        -- INSERT, so any consumer reacting to this has already-committed,
        -- server-authoritative state to query back against (HasK9Access/
        -- GetActivePartnerCitizenId/etc.) if it wants to. Not gated on any
        -- Config.Features flag: certification is this resource's core access
        -- gate (SPEC.md §4.1), not a phase-numbered toggle, matching this same
        -- reasoning already applied to HasK9Access itself in server/exports.lua's
        -- header.
        FireOutboundEvent('qbx_k9unit:events:certificationGranted', targetCitizenid, jobName, granterCitizenid)

        -- Read-only mirror for client HUD display ONLY (SPEC.md §4.3) — NEVER
        -- read by any server-side authorization check. Do not add a read of
        -- this field to HasK9Access or any other gate.
        targetPlayer.Functions.SetMetaData('k9certified', true)

        NotifyPlayer(granterSrc, locale('certifications.grant_success_granter'), 'success')
        NotifyPlayer(targetServerId, locale('certifications.grant_success_target'), 'success')
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    if not grantOk then
        print(('[qbx_k9unit] GrantCertification unexpected error for %s/%s: %s'):format(targetCitizenid, jobName, tostring(grantErr)))
        NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
    end
end

--- SPEC.md §4.2/§4.3 revoke flow (manual). Called by both event 3 and
--- command 7. Must work even when the target is offline (§4.3). Does NOT
--- run the model check (§4.2.5 applies to grant only).
--- @param granterSrc number
--- @param targetServerId number
local function RevokeCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
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
                NotifyPlayer(granterSrc, locale('certifications.target_too_far_to_revoke'), 'error')
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
        NotifyPlayer(granterSrc, locale('certifications.target_offline_use_decertify_offline'), 'error')
        return
    end

    if not targetJobName or not Config.Departments[targetJobName] then
        NotifyPlayer(granterSrc, locale('certifications.target_no_department_cert'), 'error')
        return
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return end

    -- No LIMIT needed — uq_one_active_cert_per_job guarantees at most one
    -- row matches (SPEC.md §4.3).
    --
    -- Wrapped in pcall (this file's own RefreshCertificationCache/
    -- GrantCertification precedent): a real DB error (bad connection,
    -- deadlock, schema drift) otherwise raises an uncaught script error
    -- straight out of this event/command handler instead of degrading —
    -- see IsCertRowConfirmedActive's own doc comment for why the failure
    -- branch below reconciles against a fresh, independent read rather
    -- than just assuming the UPDATE failed outright. A SQL transaction is
    -- deliberately NOT used here either: this is the only write in this
    -- function, and a single UPDATE is already atomic at the
    -- storage-engine level — the only real ambiguity a thrown error can
    -- leave behind is whether THIS callback ever saw the server's own
    -- commit acknowledgment, which a transaction's own COMMIT step would
    -- share identically.
    local updateOk, affectedRowsOrErr = pcall(
        MySQL.update.await,
        'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
        { granterCitizenid, targetCitizenid, targetJobName }
    )

    if not updateOk then
        print(('[qbx_k9unit] RevokeCertification UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(targetCitizenid, targetJobName, tostring(affectedRowsOrErr)))

        local stillActive = IsCertRowConfirmedActive(targetCitizenid, targetJobName)
        if stillActive ~= false then
            -- Either confirmed still active (the UPDATE genuinely never
            -- committed — an honest failure, the target keeps their
            -- current, correct certification) or unreadable (nil, true
            -- outcome unknown) — in BOTH cases, never claim a revoke
            -- succeeded that this code cannot confirm, and never run the
            -- side effects below (leash/partnership teardown, HUD
            -- metadata, the target-facing notice) against a guess.
            NotifyPlayer(granterSrc, locale('certifications.revoke_error'), 'error')
            return
        end

        -- Confirmed inactive despite the client-side error (e.g. a
        -- success acknowledgment lost after a real commit) — fall through
        -- to the normal success path below against this now-confirmed
        -- truth; RefreshCertificationCache below will pick up the correct
        -- state.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified'), 'inform')
        return
    end

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §2) —
    -- fired immediately once `affectedRows` confirms a real row actually
    -- flipped (never optimistically before this check), same "not gated on
    -- a feature flag" reasoning as the grant event above.
    FireOutboundEvent('qbx_k9unit:events:certificationRevoked', targetCitizenid, targetJobName, 'manual')

    if targetIsOnline then
        RefreshCertificationCache(targetCitizenid, targetJobName)
        -- HUD display mirror only (SPEC.md §4.3) — never read for authorization.
        targetPlayer.Functions.SetMetaData('k9certified', false)
        NotifyPlayer(targetServerId, locale('certifications.revoked_notice_online'), 'error')

        -- QA finding fix: an active leash pairing must not outlive the
        -- K9-role party's certification (SPEC.md §1/§4.4 "immediately") —
        -- see ForceDetachLeashIfOnline's doc comment above. `targetServerId`
        -- is already a live, currently-connected server id here (we're
        -- inside the `targetIsOnline` branch), so force-detach directly
        -- rather than re-resolving by citizenid.
        ForceDetachLeashForSource(targetServerId, 'certification_revoked')

        -- Phase 3 (PHASE3_SPEC.md §12.0 item 7): a K9 partnership must not
        -- outlive its K9-role party's certification either — same
        -- "immediately" requirement as leash directly above, now extended
        -- to the persistent partnership registry (server/partnership.lua).
        -- CITIZENID-keyed (not source-keyed), unlike the leash call above,
        -- because ForceBreakPartnershipForCitizenId operates on the DB row
        -- directly and works identically online or offline — see that
        -- function's own "OFFLINE-CAPABLE BY DESIGN" doc comment; using
        -- `targetCitizenid` here rather than `targetServerId` is not an
        -- inconsistency with the leash call above, it's this callee's own
        -- documented, intentional shape. Guarded by a `type(...) ==
        -- 'function'` runtime existence check, not a load-order assumption,
        -- since server/partnership.lua loads AFTER this file (see this
        -- file's own header and fxmanifest.lua's matching comment) — called
        -- unconditionally of Config.Features.HandlerPartnership's current
        -- value, see this file's header for why.
        if type(ForceBreakPartnershipForCitizenId) == 'function' then
            ForceBreakPartnershipForCitizenId(targetCitizenid, 'certification_revoked')
        end
    end

    NotifyPlayer(granterSrc, locale('certifications.revoke_success'), 'success')
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
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_decertify_offline'), 'error')
        return
    end

    -- Reject a typo'd/unconfigured job outright rather than silently
    -- no-opping against a job name that could never have an active row.
    if not Config.Departments[job] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department', job), 'error')
        return
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return end

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
        NotifyPlayer(granterSrc, locale('certifications.target_online_use_decertify_command', onlineCheckTarget.PlayerData.source), 'error')
        return
    end

    -- No LIMIT needed — uq_one_active_cert_per_job guarantees at most one
    -- row matches (SPEC.md §4.3). Same UPDATE pattern as the online path —
    -- including the same pcall + reconcile-on-throw discipline; see
    -- RevokeCertification's own doc comment above for the full reasoning
    -- (a thrown DB error must degrade this offline-capable command, not
    -- raise an uncaught script error, and a SQL transaction would not
    -- resolve the one genuine ambiguity a thrown error can leave behind
    -- here either).
    local updateOk, affectedRowsOrErr = pcall(
        MySQL.update.await,
        'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
        { granterCitizenid, citizenid, job }
    )

    if not updateOk then
        print(('[qbx_k9unit] RevokeCertificationOffline UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(citizenid, job, tostring(affectedRowsOrErr)))

        local stillActive = IsCertRowConfirmedActive(citizenid, job)
        if stillActive ~= false then
            -- Confirmed still active, or unreadable (true outcome
            -- unknown) — never claim a revoke succeeded that this code
            -- cannot confirm; see RevokeCertification's identical branch
            -- above for the full reasoning.
            NotifyPlayer(granterSrc, locale('certifications.revoke_error'), 'error')
            return
        end

        -- Confirmed inactive despite the client-side error — fall through
        -- to the normal success path below against this now-confirmed
        -- truth.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        -- Distinguish "no matching active cert" from success — a granter
        -- typo'ing a citizenid should not look identical to a real revoke.
        NotifyPlayer(granterSrc, locale('certifications.offline_target_not_certified'), 'inform')
        return
    end

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §2) —
    -- same "fire only once affectedRows confirms a real row flipped"
    -- discipline as RevokeCertification's online branch above; reason is
    -- 'manual_offline' to distinguish this path from that one.
    FireOutboundEvent('qbx_k9unit:events:certificationRevoked', citizenid, job, 'manual_offline')

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

    -- Phase 3 (PHASE3_SPEC.md §12.0 item 7): unlike leash immediately
    -- above (a genuine, in-memory-only no-op for a truly offline citizenid
    -- — see ForceDetachLeashIfOnline's own doc comment), a K9 partnership
    -- is DB-backed and DOES persist across a disconnect
    -- (server/partnership.lua's own "OFFLINE-CAPABLE BY DESIGN" header
    -- section). This is in fact THE call site that design decision exists
    -- for: a genuinely offline K9-role citizenid revoked while off-shift
    -- must still have any real, active partnership row torn down, or it
    -- would otherwise stand indefinitely — exactly the gap the partnership
    -- registry was built to not have. ForceBreakPartnershipForCitizenId is
    -- citizenid-keyed for exactly this reason and works identically online
    -- or offline. Same runtime existence guard / unconditional-of-
    -- feature-flag reasoning as RevokeCertification's online branch's
    -- identical call above in this file.
    if type(ForceBreakPartnershipForCitizenId) == 'function' then
        ForceBreakPartnershipForCitizenId(citizenid, 'certification_revoked')
    end

    NotifyPlayer(granterSrc, locale('certifications.revoke_success'), 'success')
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

        -- Phase 3 (PHASE3_SPEC.md §12.0 item 7): department loss ends an
        -- active partnership the same way it ends an active leash pairing
        -- directly above — a partnership's handler-role party who no
        -- longer passes department membership is exactly as invalid a
        -- handler-role party as one who no longer has a leash-eligible
        -- department. ForceBreakPartnershipForCitizenId covers `citizenid`
        -- regardless of which role (K9 or handler) they currently hold in
        -- their active row (see that function's own doc comment), so
        -- unlike ForceDetachOfficerLeashForSource above, no separate
        -- role-specific counterpart is needed here. Same runtime existence
        -- guard / unconditional-of-feature-flag reasoning as
        -- RevokeCertification's online branch's identical call, above in
        -- this file.
        if type(ForceBreakPartnershipForCitizenId) == 'function' then
            ForceBreakPartnershipForCitizenId(citizenid, 'department_changed')
        end
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

    -- Wrapped in pcall — this fires directly out of an AddEventHandler
    -- with nothing above it to catch a thrown error, so a real DB error
    -- (bad connection, deadlock, schema drift) would otherwise raise an
    -- uncaught script error out of this handler instead of degrading,
    -- silently skipping every side effect below (leash/partnership
    -- teardown) with no controlled log line explaining why. Same "a
    -- transaction would not resolve the one genuine ambiguity a thrown
    -- error can leave behind" reasoning as RevokeCertification above —
    -- this is this function's only write.
    local updateOk, updateErr = pcall(
        MySQL.update.await,
        'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
        { 'system:job_change', citizenid, oldJob }
    )

    if not updateOk then
        print(('[qbx_k9unit] OnJobUpdate auto-revoke UPDATE failed for %s/%s: %s -- reconciling before applying any side effects'):format(citizenid, oldJob, tostring(updateErr)))

        -- Reconcile against an independent, fresh read before running ANY
        -- of the side effects below — see IsCertRowConfirmedActive's own
        -- doc comment for why this can't just trust
        -- RefreshCertificationCache's collapsed return value here. Those
        -- side effects (leash detach, partnership teardown, the
        -- player-facing "your cert was revoked" notice) must only fire on
        -- a CONFIRMED loss, never a merely-unknown one.
        local stillActive = IsCertRowConfirmedActive(citizenid, oldJob)
        if stillActive ~= false then
            -- Confirmed still certified for the old job (the UPDATE
            -- genuinely never committed), or unreadable (true outcome
            -- unknown) — in BOTH cases nothing was confirmed lost, so
            -- there is nothing accurate to tell this player beyond the
            -- console log above for an operator to investigate. `cached`
            -- above is still accurate either way (never touched by this
            -- branch), so the in-memory cache is not at risk of diverging
            -- from the DB here.
            return
        end

        -- Confirmed inactive despite the client-side error (e.g. a
        -- success acknowledgment lost after a real commit) — fall through
        -- to the normal "certification just ended" side effects below
        -- against this now-confirmed truth.
    end

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §2) —
    -- fired once the UPDATE above is confirmed to have taken effect
    -- (either it returned normally, or the pcall failure branch above
    -- already independently confirmed the row is inactive before falling
    -- through here). This branch is only reached once `cached.active` and
    -- a real job-name change have already been confirmed (see the guards
    -- above), so — unlike the two manual revoke paths — there is no
    -- separate `affectedRows` result to gate on here.
    FireOutboundEvent('qbx_k9unit:events:certificationRevoked', citizenid, oldJob, 'job_changed')

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
    NotifyPlayer(source, locale('certifications.revoked_notice_job_change', deptLabel), 'error')

    -- QA finding fix (SPEC.md §1/§4.4 "immediately"): this player is
    -- online by definition (OnJobUpdate fired for their live `source`), so
    -- force-detach directly rather than re-resolving by citizenid — same
    -- reasoning as the online branch of RevokeCertification above.
    ForceDetachLeashForSource(source, 'certification_revoked')

    -- Phase 3 (PHASE3_SPEC.md §12.0 item 7): same "must not outlive
    -- certification loss" requirement as leash immediately above, applied
    -- to the partnership registry. This branch is only reached for a
    -- K9-role citizenid — the department-membership-only handler/officer
    -- role never holds a certification of its own (see this handler's own
    -- comment near its top on that exact asymmetry) — so `citizenid` here
    -- is always the K9-role party of any active partnership it might hold.
    -- Same runtime existence guard / unconditional-of-feature-flag
    -- reasoning as RevokeCertification's online branch's identical call.
    if type(ForceBreakPartnershipForCitizenId) == 'function' then
        ForceBreakPartnershipForCitizenId(citizenid, 'certification_revoked')
    end
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
        NotifyPlayer(source, locale('certifications.usage_certify'), 'error')
        return
    end
    GrantCertification(source, targetServerId)
end, false)

RegisterCommand('k9decertify', function(source, args)
    -- Same arg validation as k9certify above.
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, locale('certifications.usage_decertify'), 'error')
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
        NotifyPlayer(source, locale('certifications.usage_decertify_offline'), 'error')
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
