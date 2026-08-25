--[[
    qbx_k9unit/server/appearance.lua

    coder-architect. Decouples the K9 ROLE from the K9 PED MODEL, per the
    project owner's three requirements this pass:
      1. High command, from the tablet, can either certify a handler (the
         existing server/certifications.lua flow) OR directly "apply K9" to
         any citizenid, and either path PERMANENTLY changes that player's
         own character to a configured ped.
      2. Any Config.Peds entry works, including a custom/non-dog model —
         nothing here ever assumes a dog, or even an animal.
      3. A player on an unlisted model, INCLUDING AN ORDINARY HUMAN PED, can
         still hold the K9 role and use every K9 ability — the role is now
         an assignment this file holds against a citizenid
         (`k9_ped_assignments`, sql/migrations/0006), not an inference from
         whatever the player currently looks like.

    ======================================================================
    THE DECOUPLING, IN ONE PLACE (read this before touching anything else
    that gates on "is this player the K9"):

    "HOLDS THE K9 ROLE" now means, precisely: an active
    `k9_certifications` row for the citizenid's CURRENT job (the traditional
    credential this resource already calls "K9 certification" — see
    server/certifications.lua's own OnJobUpdate comment: "the cert is
    specifically the 'I am a working K9' credential, not 'I am allowed near
    one'" — that sentence is the whole finding this file is built on), OR an
    active `k9.access` grant in server/permissions.lua's k9_permissions
    table. Both are EXISTING credentials this file adds no third copy of —
    see HasK9Role() below, which is nothing more than that OR, spelled out.
    Deliberately EXCLUDES the autoAccessGrade/high-command BYPASSES inside
    HasK9Access(): those grant broad, blanket access to K9 *features*
    (so a chief can test/oversee them) without making that officer's own
    character *be* the K9 — see CanShowK9UI()'s own updated doc comment in
    client/main.lua for why that distinction matters for UI gating.

    "WHAT THE ROLE-HOLDER LOOKS LIKE" is wholly separate, tracked in
    `k9_ped_assignments` (citizenid -> currently-applied model name, plus
    the ORIGINAL model hash captured before the very first swap so a revoke
    can put it back). Config.K9Appearance.requireK9ModelForRole (default
    false) controls ONLY whether server/certifications.lua's grant-time
    model check still runs — it never touches HasK9Role() above, which was
    already model-independent by construction before this file existed.

    ======================================================================
    EVENT/CALLBACK CONTRACT:
    Callbacks (ox_lib lib.callback):
      'qbx_k9unit:server:hasK9Role' () -> boolean [THIS FILE]
    Client events (RegisterNetEvent, server->client):
      'qbx_k9unit:client:applyK9Ped' (requestId: string, modelNameOrHash: string|number) [client/appearance.lua]
    Server events (RegisterNetEvent, client->server):
      'qbx_k9unit:server:confirmK9PedSwap' (requestId: string, ok: boolean, reason: string?) [THIS FILE]

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes four resource-global (no `local`) functions:
        HasK9Role(source) -> boolean
        ApplyK9PedRole(granterSrc, targetCitizenid, modelName) -> ok, outcome
            The explicit tablet "apply K9" action (requirement 1's second
            verb). modelName is REQUIRED and must be a Config.Peds entry —
            this is how requirement 2 (any configured ped, including
            custom/non-dog) is satisfied: the tablet reads Config.Peds
            (with its new optional `.label`) and this function accepts
            whichever `.model` string the operator picked.
        ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, modelName?)
            The AUTOMATIC side effect Config.K9Appearance's own header
            documents ("certifying someone (or granting them k9.access)
            actually turns their character into the ped") — called ONLY
            from server/certifications.lua's GrantCertification and
            server/permissions.lua's GrantPermission, each already gated on
            Config.K9Appearance.applyPedModelOnCertify at the call site.
            modelName defaults to Config.Peds[1].model when omitted, since
            neither caller carries a model choice of its own.
        MaybeRevertK9Appearance(citizenid)
            Called from every path in server/certifications.lua and
            server/permissions.lua that just confirmed a K9 credential is
            GONE (RevokeCertification, RevokeCertificationOffline,
            OnJobUpdate's auto-revoke, and RevokePermission's
            stillHasAccess == nil case). Reconciles against the OTHER
            credential before reverting anything — see its own doc comment.
      Each is guarded at its call site with the established
      `type(...) == 'function'` soft-dependency convention (this file loads
      after server/permissions.lua/server/highcommand.lua/server/cooldowns.lua
      and before server/certifications.lua in fxmanifest.lua — see the
      fxmanifest report in this pass's hand-off for the exact lines).
    - THIS FILE calls `HasPermission`/`GrantPermission`/`RevokePermission`
      (server/permissions.lua), `IsHighCommand` (server/highcommand.lua) and
      `NewCooldown` (server/cooldowns.lua, at THIS file's own load time — a
      hard load-order requirement, same as every other consumer), and
      `NotifyPlayer` (server/notify.lua). All guarded except NewCooldown,
      which every consumer in this resource calls unconditionally at load
      time.
    - THIS FILE does NOT call into server/certifications.lua's `local`
      Certifications cache directly (it is private to that file) —
      IsCertifiedK9ForCurrentJob below reads `k9_certifications` itself,
      the same table certifications.lua reads, rather than requiring a new
      exposed accessor there. This keeps certifications.lua's surgical edit
      surface to the two call-outs above plus the two items in its own
      header note, nothing more.

    ======================================================================
    PER-PED STATE ACROSS A MODEL SWAP — SPEC-LEVEL DECISION (client-side
    enforcement lives in client/appearance.lua, documented in full there):
    REFUSE the swap, don't force-clear, whenever the target is in ANY
    resource-tracked "busy" state (leashed, mid drag as either party, mid
    bite-hold, mid fetch-carry, inside a K9 vehicle) — this file only
    reasons about server-authoritative role/DB state, so it cannot itself
    know these; the client-side pre-flight check owns that decision.

    ======================================================================
    STREAMING FAILURE CONTRACT: a model that never finishes loading within
    Config.K9Appearance.modelLoadTimeoutMs is an ABANDONED swap — this file
    NEVER writes `model`/`active` to `k9_ped_assignments` until the
    client's own confirmation event says the swap actually landed. A
    still-offline target is the one exception: there the row is written
    immediately with no swap attempted at all yet (nothing to confirm), and
    the real swap — with its own real timeout/abandon handling — runs the
    first time PlayerLoaded fires for them.
]]

-- ======================================================================
-- CONFIG-SAFETY GUARD — run unconditionally at load time, same convention
-- server/certifications.lua and server/permissions.lua already established
-- for their own authorization-adjacent configs. config.lua is a
-- shared_script, already fully loaded by the time any server_scripts file
-- (this one included) starts executing.
-- ======================================================================
assert(type(Config.K9Appearance) == 'table',
    '[qbx_k9unit] Config.K9Appearance must be a table -- ApplyK9PedRole/ApplyK9AppearanceOnGrant/' ..
    'MaybeRevertK9Appearance all read its fields directly with no type guard of their own.')
assert(type(Config.Peds) == 'table' and #Config.Peds > 0,
    '[qbx_k9unit] Config.Peds must be a non-empty array -- ApplyK9PedRole validates every caller-supplied ' ..
    'model name against it, and ApplyK9AppearanceOnGrant defaults to Config.Peds[1].model when no explicit ' ..
    'model is given; an empty/malformed table means no K9 ped could ever be applied, silently.')
for i, pedEntry in ipairs(Config.Peds) do
    assert(type(pedEntry) == 'table' and type(pedEntry.model) == 'string' and pedEntry.model ~= '',
        ('[qbx_k9unit] Config.Peds[%d].model must be a non-empty string.'):format(i))
end

--- @param name any
--- @return boolean
local function IsValidPedModelName(name)
    if type(name) ~= 'string' or name == '' then return false end
    for _, pedEntry in ipairs(Config.Peds) do
        if pedEntry.model == name then return true end
    end
    return false
end

-- Anti-fat-finger cooldown, same shape/threshold as
-- server/certifications.lua's CertifyActionCooldown and
-- server/permissions.lua's PermissionActionCooldown (1500ms, a plain
-- literal, not a Config field -- this file cannot edit config.lua either).
-- Keyed by the GRANTER's own source, mirroring both of those exactly.
local APPEARANCE_ACTION_COOLDOWN_MS = 1500
local AppearanceActionCooldown = NewCooldown(APPEARANCE_ACTION_COOLDOWN_MS)
AppearanceActionCooldown.RegisterPlayerDropped()

-- PendingSwap[citizenid] = { requestId, kind = 'apply'|'revert',
--   granterLabel, modelName (string, apply only), modelHash (number,
--   revert only, or apply's resolved hash for audit), expiresAt }
-- In-memory / ephemeral only, same posture as server/main.lua's
-- PendingLeashRequests and server/kennel.lua's PendingKennelPlacements.
--
-- CORRECTED (coder-architect, adversarial-pass finding, this pass -- the
-- ORIGINAL version of this comment claimed "nothing was ever written ...
-- no DB state to clean up" for BOTH kinds; that is only true for 'apply'):
-- a pending 'apply' that never confirms (crash/disconnect/timeout
-- mid-flight) really is a clean no-op -- no pre-existing DB row it could
-- leave dangling, see "STREAMING FAILURE CONTRACT" below. A pending
-- 'revert', by contrast, starts from a PRE-EXISTING `active = 1` row that
-- must not survive the swap being abandoned -- both the sweep thread
-- (below, timeout) and the playerDropped handler (below, disconnect)
-- COMMIT the revert unconditionally in that case, precisely because
-- leaving that row untouched would let a decertified citizenid come back
-- as a K9 on their very next reconnect.
local PendingSwap = {}

-- Generous margin over the client's own load timeout, so a legitimate
-- slow-but-successful load is never mistaken here for an abandoned one —
-- the client is always the one that decides "abandoned", this is only a
-- backstop against a confirm that never arrives at all (disconnect).
local function ApplyRequestTtlMs()
    local timeout = (Config.K9Appearance and Config.K9Appearance.modelLoadTimeoutMs) or 10000
    if type(timeout) ~= 'number' or timeout <= 0 then timeout = 10000 end
    return timeout + 5000
end

local requestCounter = 0
local function NextRequestId()
    requestCounter = requestCounter + 1
    return ('%d:%d'):format(GetGameTimer(), requestCounter)
end

--- @param source number
--- @return string
local function WhoLabelForSource(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    return citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
end

--- Matches server/admin.lua's LogAuditInvocation / server/permissions.lua's
--- LogAuditInvocation "%s ran %s(%s) -> %s" format EXACTLY (this task's own
--- explicit instruction — item E, "same format as server/admin.lua's
--- LogAuditInvocation"). `whoLabel` is pre-resolved by the caller so this
--- works uniformly whether the actor is a live source (tablet action) or a
--- system-triggered path (auto-revert on decertify/job-change), matching
--- server/certifications.lua's own 'system:job_change' sentinel precedent
--- for the latter.
--- @param whoLabel string
--- @param action string
--- @param detail string
--- @param outcome string
local function LogAppearanceAudit(whoLabel, action, detail, outcome)
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

--- Server-authoritative: does `citizenid` hold an active k9_certifications
--- row for THEIR CURRENT job? Deliberately re-derives this from the DB
--- directly rather than reaching into server/certifications.lua's private
--- `Certifications` cache (not exposed, and this file's header explains why
--- it stays that way) -- this call is never on a hot path (role
--- reconciliation on revoke, and the HasK9Role callback, itself cached
--- client-side on the same 1s TTL as HasK9Access), so a direct read is
--- simpler and cannot drift from a second in-memory copy.
--- FAILS CLOSED on a read error (an unreadable row is never treated as an
--- active credential), matching every other cert-table read in this
--- resource.
--- @param citizenid string
--- @param jobName string?
--- @return boolean
local function IsCertifiedK9ForJob(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then
        return false
    end
    local ok, idOrErr = pcall(K9Store.Cert_GetActiveId, citizenid, jobName)
    if not ok then
        print(('[qbx_k9unit] appearance.lua IsCertifiedK9ForJob query failed for %s/%s: %s'):format(citizenid, jobName, tostring(idOrErr)))
        return false
    end
    return idOrErr ~= nil
end

--- Same as IsCertifiedK9ForJob, but across EVERY department at once — used
--- ONLY by MaybeRevertK9Appearance's reconciliation (a citizenid can hold a
--- separate active cert for a DIFFERENT department than the one that just
--- got revoked -- SPEC.md's own "cross-department granting IS currently
--- allowed" -- and losing one must not revert an appearance still backed
--- by the other). FAILS OPEN here deliberately (an unreadable row is
--- treated as "assume still qualified, don't revert") -- unlike every
--- ACCESS check in this resource, this is a REVERT guard: reverting a
--- player's character on a transient DB hiccup would itself be the
--- destructive mistake, whereas skipping a revert that should have
--- happened just leaves them as a K9 a little longer, correctable the next
--- time this runs cleanly.
--- @param citizenid string
--- @return boolean
local function IsCertifiedK9ForAnyJob(citizenid)
    local ok, idOrErr = pcall(MySQL.scalar.await,
        'SELECT id FROM k9_certifications WHERE citizenid = ? AND active = 1 LIMIT 1', { citizenid })
    if not ok then
        print(('[qbx_k9unit] appearance.lua IsCertifiedK9ForAnyJob query failed for %s: %s'):format(citizenid, tostring(idOrErr)))
        return true -- fail OPEN -- see doc comment above
    end
    return idOrErr ~= nil
end

--- THE decoupled role check (see this file's header). Server-authoritative,
--- model-independent by construction. Exposed globally.
--- @param source number
--- @return boolean
function HasK9Role(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local citizenid = Player.PlayerData.citizenid
    if type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access') then
        return true
    end

    local job = Player.PlayerData.job
    return job ~= nil and IsCertifiedK9ForJob(citizenid, job.name)
end

lib.callback.register('qbx_k9unit:server:hasK9Role', function(source)
    return HasK9Role(source)
end)

--- THE "one real gap in the primitives" a peer audit (this pass) correctly
--- flagged: HasK9Role/IsK9Role both answer about the CALLER only. Several
--- ox_target canInteract predicates in files this pass does not own
--- (client/movement.lua's "Certify K9 Handler"/"Revoke Certification"/
--- "Attach Leash", client/partnership.lua's "Partner Up",
--- client/medkit.lua's "Treat K9", client/wellbeing.lua's "Pet K9"/
--- "Feed K9") need to ask "is THAT OTHER player, right now, a K9-role
--- holder" to correctly show their option to/for a role-holder on an
--- unlisted or human model — see this pass's hand-off report. Not
--- security-sensitive to expose (same class of fact as the existing
--- `k9certified` metadata mirror, already broadcast client-side) — this is
--- a CONVENIENCE gate only, same posture as every other canInteract
--- predicate in this resource; every real action still re-verifies
--- server-side via HasK9Role/HasK9Access regardless of what this answers.
--- @param source number -- the ASKING client (unused; the query is about targetServerId, not the caller)
--- @param targetServerId number
lib.callback.register('qbx_k9unit:server:isK9RoleForTarget', function(_source, targetServerId)
    if type(targetServerId) ~= 'number' then return false end
    return HasK9Role(targetServerId)
end)

-- ======================================================================
-- k9_ped_assignments READ/WRITE HELPERS (sql/migrations/0006). See that
-- file for the exact schema this reads/writes.
-- ======================================================================

--- @param citizenid string
--- @return table? row -- { model, original_model_hash, active } or nil (not found, or the read failed)
local function GetAppearanceRow(citizenid)
    local ok, rows = pcall(MySQL.query.await,
        'SELECT model, original_model_hash, active FROM k9_ped_assignments WHERE citizenid = ? LIMIT 1',
        { citizenid })
    if not ok then
        print(('[qbx_k9unit] appearance.lua GetAppearanceRow query failed for %s: %s'):format(citizenid, tostring(rows)))
        return nil
    end
    return rows and rows[1] or nil
end

--- Writes the "a swap for `model` was just confirmed applied" state.
--- Preserves an existing `original_model_hash` ONLY when the existing row
--- is still `active` (a fresh assignment after a genuine revert must
--- capture a NEW original, not reuse a stale one from a prior stint -- see
--- this file's header "STREAMING FAILURE CONTRACT" neighbor note on
--- revert). `originalHash` may be nil (not yet known -- an offline-target
--- persisted assignment that hasn't had its first swap attempt yet).
--- @param citizenid string
--- @param model string
--- @param originalHash number?
--- @param appliedByLabel string
local function WriteAppearanceApplied(citizenid, model, originalHash, appliedByLabel)
    local existing = GetAppearanceRow(citizenid)
    local keepOriginal = existing and existing.active == 1 and existing.original_model_hash or nil
    local finalOriginal = keepOriginal or originalHash

    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO k9_ped_assignments (citizenid, model, original_model_hash, active, applied_by, applied_at, revoked_at)
        VALUES (?, ?, ?, 1, ?, CURRENT_TIMESTAMP, NULL)
        ON DUPLICATE KEY UPDATE
            model = VALUES(model),
            original_model_hash = COALESCE(VALUES(original_model_hash), original_model_hash),
            active = 1,
            applied_by = VALUES(applied_by),
            applied_at = CURRENT_TIMESTAMP,
            revoked_at = NULL
    ]], { citizenid, model, finalOriginal, appliedByLabel })

    if not ok then
        print(('[qbx_k9unit] appearance.lua WriteAppearanceApplied UPSERT failed for %s: %s'):format(citizenid, tostring(err)))
        return false
    end
    return true
end

--- @param citizenid string
--- @return boolean ok
local function WriteAppearanceReverted(citizenid)
    local ok, err = pcall(MySQL.query.await,
        'UPDATE k9_ped_assignments SET active = 0, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND active = 1',
        { citizenid })
    if not ok then
        print(('[qbx_k9unit] appearance.lua WriteAppearanceReverted UPDATE failed for %s: %s'):format(citizenid, tostring(err)))
        return false
    end
    return true
end

--- Read-only convenience accessor (no known caller in this resource today,
--- exposed for a future consumer / the tablet's own display needs, same
--- "expose the accessor, let a later file decide it wants it" reasoning
--- server/certifications.lua's IsConfiguredK9Model already documents).
--- @param citizenid string
--- @return string? model -- nil if no active assignment
function GetAssignedK9Model(citizenid)
    local row = GetAppearanceRow(citizenid)
    if row and row.active == 1 then return row.model end
    return nil
end

-- ======================================================================
-- CLIENT ROUND TRIP -- see this file's header "STREAMING FAILURE CONTRACT"
-- and client/appearance.lua's own header for the full client-side half
-- (engaged-check, RequestModel/HasModelLoaded polling with the leak fix,
-- abandon-on-timeout).
-- ======================================================================

--- @param targetCitizenid string
--- @param kind 'apply'|'revert'
--- @param payload string|number -- modelName (apply) or modelHash (revert)
--- @param granterLabel string
--- @return boolean sent -- false if the target isn't currently online (caller decides what that means for its own flow)
local function SendSwapRequest(targetCitizenid, kind, payload, granterLabel)
    local targetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
    local targetSrc = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.source
    if not targetSrc then return false end

    local requestId = NextRequestId()
    PendingSwap[targetCitizenid] = {
        requestId = requestId,
        kind = kind,
        granterLabel = granterLabel,
        payload = payload,
        expiresAt = GetGameTimer() + ApplyRequestTtlMs(),
    }
    TriggerClientEvent('qbx_k9unit:client:applyK9Ped', targetSrc, requestId, payload)
    return true
end

--- @param citizenid string
--- @return table? pending -- nil if none, or it already expired (also clears it)
local function TakePendingSwap(citizenid)
    local pending = PendingSwap[citizenid]
    if not pending then return nil end
    if GetGameTimer() > pending.expiresAt then
        PendingSwap[citizenid] = nil
        return nil
    end
    return pending
end

-- SECURITY FIX (coder-architect, adversarial-pass finding, this pass):
-- confirmK9PedSwap below only ever writes `k9_ped_assignments` when the
-- CLIENT reports `ok = true` -- correct and necessary for an APPLY (never
-- half-apply a model that may not have actually loaded), but wrong for a
-- REVERT: client/appearance.lua's IsCurrentlyEngaged() is entirely
-- self-reported (IsLeashed/IsBiteHoldEngaged/IsDragEngaged/
-- IsFetchCarryEngaged/IsInK9Vehicle are all local client-side booleans), so
-- a modified client could reply `false, 'engaged'` forever, or simply never
-- reply at all, and a revert -- including
-- server/tablet.lua's own ForceRevertK9Appearance, high command's explicit
-- "remove K9 ped, revert to human" action -- would never complete. That is
-- exactly the "no unbounded trap" rule from the other direction: a
-- TERMINATION path must not be vetoable by the party it terminates.
--
-- This sweep is the fix: any PENDING 'revert' whose grace period
-- (ApplyRequestTtlMs -- the same generous modelLoadTimeoutMs + margin
-- window a cooperating client's own RequestModel/HasModelLoaded polling
-- gets) has elapsed with no valid confirm is completed HERE,
-- server-side, unconditionally -- HasK9Role/HasK9Access were already
-- false from the moment the underlying credential was revoked (this
-- table only ever tracks cosmetic state), so this sweep closes the
-- "permanently stuck showing as a K9" gap without ever touching a live,
-- possibly mid-action ped without that ped's own client-side engaged
-- check having had a fair, bounded chance to run first. A cooperating
-- player who is genuinely mid-bite-hold gets that full grace window to
-- finish and reply; a hostile or unresponsive one cannot hold it open
-- longer than that.
--
-- 'apply' entries are NOT forced the other way (never grant an unconfirmed
-- appearance) -- a stale one past its own grace period is simply dropped,
-- which also bounds PendingSwap's memory (same "add a sweep" precedent as
-- every other per-citizenid/per-source table in this resource that isn't
-- already cleared on playerDropped alone).
local APPEARANCE_SWEEP_INTERVAL_MS = 2000
CreateThread(function()
    while true do
        Wait(APPEARANCE_SWEEP_INTERVAL_MS)

        local now = GetGameTimer()
        for citizenid, pending in pairs(PendingSwap) do
            if now > pending.expiresAt then
                PendingSwap[citizenid] = nil
                if pending.kind == 'revert' then
                    WriteAppearanceReverted(citizenid)
                    LogAppearanceAudit(pending.granterLabel, 'k9AppearanceRevert', ('citizenid=%s'):format(citizenid), 'forced_timeout')
                    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
                    local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
                    if onlineSrc then
                        NotifyPlayer(onlineSrc, locale('appearance.revert_success_target'), 'success')
                    end
                else
                    LogAppearanceAudit(pending.granterLabel, 'k9AppearanceApply', ('citizenid=%s'):format(citizenid), 'abandoned:no_confirm_received')
                end
            end
        end
    end
end)

RegisterNetEvent('qbx_k9unit:server:confirmK9PedSwap', function(requestId, ok, reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end

    local pending = TakePendingSwap(citizenid)
    -- Stale/forged confirm (wrong requestId, expired, or none in flight at
    -- all) -- ignore rather than trust a client-claimed requestId blindly.
    if not pending or pending.requestId ~= requestId then return end
    PendingSwap[citizenid] = nil

    if ok then
        if pending.kind == 'apply' then
            WriteAppearanceApplied(citizenid, pending.payload, nil, pending.granterLabel)
            NotifyPlayer(src, locale('appearance.apply_success_target'), 'success')
        else
            WriteAppearanceReverted(citizenid)
            NotifyPlayer(src, locale('appearance.revert_success_target'), 'success')
        end
        LogAppearanceAudit(pending.granterLabel, 'k9Appearance' .. (pending.kind == 'apply' and 'Apply' or 'Revert'),
            ('citizenid=%s'):format(citizenid), 'ok')
    else
        -- ABANDONED, per this file's header contract: no DB write at all --
        -- the player is exactly as they were. `reason` is a client-supplied
        -- opaque tag ('engaged' | 'timeout') for the audit line only, never
        -- passed to locale() -- see client/appearance.lua for the exact set.
        LogAppearanceAudit(pending.granterLabel, 'k9Appearance' .. (pending.kind == 'apply' and 'Apply' or 'Revert'),
            ('citizenid=%s'):format(citizenid), 'abandoned:' .. tostring(reason))
    end
end)

-- ======================================================================
-- GRANT-SIDE ENTRY POINTS
-- ======================================================================

--- The explicit tablet "apply K9" action (requirement 1's second verb).
--- Reuses server/permissions.lua's GrantPermission wholesale for
--- authorization (high command only, self-grant blocked, cooldown, audit,
--- DB persistence of the 'k9.access' credential) rather than re-deriving
--- any of that here -- see this file's header FILE-TO-FILE CONTRACT.
--- `modelName` is REQUIRED (unlike ApplyK9AppearanceOnGrant's default) --
--- this is the one entry point where the operator is explicitly choosing a
--- ped, including a custom/non-dog one (requirement 2).
--- @param granterSrc number
--- @param targetCitizenid string
--- @param modelName string
--- @return boolean ok
--- @return string outcome -- every GrantPermission outcome, plus 'invalid_model'
function ApplyK9PedRole(granterSrc, targetCitizenid, modelName)
    if not IsValidPedModelName(modelName) then
        LogAppearanceAudit(WhoLabelForSource(granterSrc), 'applyK9PedRole',
            ('model=%s target=%s'):format(tostring(modelName), tostring(targetCitizenid)), 'invalid_model')
        return false, 'invalid_model'
    end

    if not AppearanceActionCooldown.Consume(granterSrc) then
        return false, 'rate_limited'
    end

    -- DOUBLE-APPLY GUARD, THIS PASS (found by this file's own test suite,
    -- not merely reasoned about): GrantPermission's own hook
    -- (ApplyK9AppearanceOnGrant, wired in server/permissions.lua's
    -- GrantPermission) fires automatically for a BRAND NEW grant when
    -- Config.K9Appearance.applyPedModelOnCertify is on -- passing
    -- `modelName` straight through as GrantPermission's 4th
    -- (appearanceModelOverride) parameter means that hook applies the
    -- EXACT model this tablet action chose, not the automatic-grant
    -- default (Config.Peds[1].model). A first draft of this function
    -- called SendSwapRequest itself UNCONDITIONALLY after GrantPermission
    -- returned -- for a brand-new grant that sent a SECOND, redundant swap
    -- request (the hook's + this function's own), racing each other for
    -- no reason. Below, this function only performs its OWN swap for the
    -- 'already_granted' outcome, where GrantPermission's hook correctly
    -- does NOT fire (nothing NEW was granted) but the operator may still
    -- be choosing a DIFFERENT ped for a citizenid who already holds the
    -- role (Shepherd -> Husky, requirement 2).
    local grantOk, grantOutcome = GrantPermission(granterSrc, targetCitizenid, 'k9.access', modelName)

    -- Every OTHER GrantPermission failure (denied/rate_limited/
    -- invalid_target/self_grant_blocked/db_error/feature_disabled) is a
    -- real stop -- GrantPermission has already logged/audited/notified it
    -- itself.
    if not grantOk and grantOutcome ~= 'already_granted' then
        return false, grantOutcome
    end

    local granterLabel = WhoLabelForSource(granterSrc)

    if grantOutcome == 'ok' then
        -- Brand-new grant -- GrantPermission's own hook already applied
        -- (or persisted-offline) exactly this modelName; this is a
        -- read-only re-check of online status purely to pick the right
        -- granter-facing message, not a second attempt at anything.
        local targetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
        if targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.source then
            NotifyPlayer(granterSrc, locale('appearance.apply_success_granter'), 'success')
            return true, 'ok'
        end
        NotifyPlayer(granterSrc, locale('appearance.apply_pending_offline'), 'inform')
        return true, 'persisted_offline'
    end

    -- grantOutcome == 'already_granted': apply THIS explicit model
    -- ourselves, since nothing else will for a re-apply.
    local sent = SendSwapRequest(targetCitizenid, 'apply', modelName, granterLabel)
    if sent then
        NotifyPlayer(granterSrc, locale('appearance.apply_success_granter'), 'success')
        return true, 'ok'
    end

    -- Offline target: persist the assignment now (no swap to attempt yet;
    -- original_model_hash captured lazily on their next PlayerLoaded,
    -- below, before the real swap runs against them for the first time).
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    WriteAppearanceApplied(targetCitizenid, modelName, nil, granterCitizenid or granterLabel)
    LogAppearanceAudit(granterLabel, 'applyK9PedRole', ('model=%s target=%s'):format(modelName, targetCitizenid), 'persisted_offline')
    NotifyPlayer(granterSrc, locale('appearance.apply_pending_offline'), 'inform')
    return true, 'persisted_offline'
end

--- The AUTOMATIC side effect of a successful certify or 'k9.access'
--- permission grant, per Config.K9Appearance's own header — called ONLY
--- when the caller has already checked
--- Config.K9Appearance.applyPedModelOnCertify itself. Neither caller
--- (server/certifications.lua's GrantCertification, server/permissions.lua's
--- GrantPermission) carries a model choice, so this defaults to
--- Config.Peds[1].model when `modelName` is omitted or invalid.
--- @param targetCitizenid string
--- @param granterCitizenid string?
--- @param modelName string?
function ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, modelName)
    local resolvedModel = IsValidPedModelName(modelName) and modelName or Config.Peds[1].model
    local granterLabel = granterCitizenid and ('citizenid=' .. granterCitizenid) or 'system'

    local sent = SendSwapRequest(targetCitizenid, 'apply', resolvedModel, granterLabel)
    if not sent then
        WriteAppearanceApplied(targetCitizenid, resolvedModel, nil, granterCitizenid or 'system')
        LogAppearanceAudit(granterLabel, 'applyK9AppearanceOnGrant',
            ('model=%s target=%s'):format(resolvedModel, targetCitizenid), 'persisted_offline')
    end
end

--- Reverts `citizenid`'s appearance IFF Config.K9Appearance.restoreOriginalPedOnRevoke
--- is on AND they no longer qualify for the K9 role through ANY path (see
--- IsCertifiedK9ForAnyJob's own doc comment for why this fails OPEN on a
--- read error, unlike every access check elsewhere in this resource).
--- Safe to call unconditionally from every revoke path in
--- server/certifications.lua / server/permissions.lua — a citizenid with no
--- active k9_ped_assignments row is a cheap no-op (mirrors
--- ForceDetachLeashIfOnline/ForceBreakPartnershipForCitizenId's own
--- "harmless no-op for the common case" convention).
--- @param citizenid string
--- Shared core for both MaybeRevertK9Appearance (automatic, credential-
--- reconciled) and ForceRevertK9Appearance (explicit, high-command,
--- credential-blind by design -- see that function's own doc comment).
--- Neither pre-check belongs here: by the time this runs, the caller has
--- already decided the revert should happen.
--- @param citizenid string
--- @param granterLabel string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'no_active_assignment' | 'no_fallback_configured'
local function PerformRevert(citizenid, granterLabel)
    local row = GetAppearanceRow(citizenid)
    if not row or row.active ~= 1 then return false, 'no_active_assignment' end -- nothing currently applied for this citizenid

    local originalHash = row.original_model_hash
    if not originalHash then
        -- No original was ever captured (this install had an existing K9
        -- before this feature shipped, or the citizenid's very first swap
        -- is still pending on a currently-offline target) -- fall back
        -- per Config.K9Appearance.fallbackHumanModel's own documented
        -- purpose, rather than leaving them stranded as whatever they
        -- currently are. Resolved by NAME here (client resolves the hash
        -- itself via GetHashKey), matching Config.Peds' own string
        -- convention.
        local fallback = Config.K9Appearance and Config.K9Appearance.fallbackHumanModel
        if type(fallback) ~= 'string' or fallback == '' then
            print(('[qbx_k9unit] appearance.lua PerformRevert: no original_model_hash and no ' ..
                'Config.K9Appearance.fallbackHumanModel configured for %s -- refusing to revert rather than guess.'):format(citizenid))
            return false, 'no_fallback_configured'
        end
        local sent = SendSwapRequest(citizenid, 'revert', fallback, granterLabel)
        if not sent then WriteAppearanceReverted(citizenid) end
        return true, 'ok'
    end

    local sent = SendSwapRequest(citizenid, 'revert', originalHash, granterLabel)
    if not sent then
        -- Offline: nothing to visually revert right now -- just clear the
        -- row so PlayerLoaded below doesn't re-apply the K9 model on their
        -- next connect. They reconnect looking like whatever they logged
        -- out as, which is correct: the swap, if any was ever live, has
        -- already been undone from server-authoritative state.
        WriteAppearanceReverted(citizenid)
    end
    return true, 'ok'
end

--- Automatic reconciliation -- called from every path in
--- server/certifications.lua and server/permissions.lua that just
--- confirmed a K9 credential is GONE. Reverts ONLY when the citizenid no
--- longer qualifies via ANY path -- see its own credential checks below.
--- For the DELIBERATE, high-command-initiated "remove K9 ped" action that
--- must work regardless of credentials, see ForceRevertK9Appearance below.
--- @param citizenid string
function MaybeRevertK9Appearance(citizenid)
    if not (Config.K9Appearance and Config.K9Appearance.restoreOriginalPedOnRevoke) then return end
    if type(citizenid) ~= 'string' or citizenid == '' then return end

    if type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access') then return end
    if IsCertifiedK9ForAnyJob(citizenid) then return end

    PerformRevert(citizenid, 'system')
end

--- The tablet's explicit, high-command-initiated "remove K9 ped, revert to
--- human" action (server/tablet.lua's ForceRevertK9Appearance call site --
--- coder-backend, this pass). Deliberately does NOT run
--- MaybeRevertK9Appearance's credential checks: those exist so an
--- AUTOMATIC reconciliation never undoes an appearance still legitimately
--- backed by a separate credential. This is the opposite case -- a direct
--- command from high command that must succeed EVEN IF the target still
--- holds an active certification/permission on paper (the role and the
--- appearance are being deliberately decoupled by this action, not
--- reconciled) -- and, per the NO UNBOUNDED TRAP rule applied to a
--- TERMINATION path, must ALSO succeed on a target who has ALREADY lost
--- every credential, or revoking someone first would strand them
--- permanently. Authorization is therefore keyed on the GRANTER alone
--- (IsHighCommand), never on anything about the target.
--- @param granterSrc number
--- @param targetCitizenid string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'denied' | 'rate_limited' | 'invalid_target' | 'no_active_assignment' | 'no_fallback_configured'
function ForceRevertK9Appearance(granterSrc, targetCitizenid)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogAppearanceAudit(WhoLabelForSource(granterSrc), 'forceRevertK9Appearance', ('target=%s'):format(tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not AppearanceActionCooldown.Consume(granterSrc) then
        return false, 'rate_limited'
    end

    if type(targetCitizenid) ~= 'string' or targetCitizenid == '' then
        return false, 'invalid_target'
    end

    local granterLabel = WhoLabelForSource(granterSrc)
    local ok, outcome = PerformRevert(targetCitizenid, granterLabel)

    LogAppearanceAudit(granterLabel, 'forceRevertK9Appearance', ('target=%s'):format(targetCitizenid), outcome)
    if ok then
        NotifyPlayer(granterSrc, locale('appearance.revert_success_granter'), 'success')
    end
    return ok, outcome
end

-- ======================================================================
-- PERSISTENCE ACROSS RELOG/CRASH/RESTART (item B) -- Config.K9Appearance
-- .persistAcrossSessions. A resource restart alone never changes a
-- connected player's actual ped (SetPlayerModel is a game-engine-level
-- change, untouched by this resource stopping/starting), so the only real
-- re-application point is a fresh connection.
-- ======================================================================
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not (Config.K9Appearance and Config.K9Appearance.persistAcrossSessions) then return end
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    local src = Player.PlayerData.source

    local row = GetAppearanceRow(citizenid)
    if not row or row.active ~= 1 then return end

    -- SECURITY FIX (coder-architect, adversarial-pass finding, this pass):
    -- BACKSTOP, independent of the playerDropped fix below -- a persisted
    -- `active = 1` row must never be trusted blindly on reconnect. Without
    -- this, ANY way a stale active row could survive past a real
    -- credential loss (the disconnect-during-revert window the
    -- playerDropped fix below closes, or any other future path that
    -- writes this table without going through HasK9Role first) would
    -- silently re-apply a K9 model to a citizenid who no longer holds the
    -- role at all. HasK9Role(src) is the SAME server-authoritative check
    -- CanShowK9UI()/every gate ultimately reduces to -- if it says no,
    -- clear the stale row here and now rather than re-apply it.
    if type(HasK9Role) == 'function' and not HasK9Role(src) then
        WriteAppearanceReverted(citizenid)
        LogAppearanceAudit('system', 'k9AppearancePlayerLoaded', ('citizenid=%s'):format(citizenid), 'stale_row_cleared_no_role')
        return
    end

    if not row.original_model_hash then
        -- First-ever swap for this citizenid and they were offline when it
        -- was requested -- capture their CURRENT (pre-swap) live model now,
        -- before pushing the swap below, so a later revert has something
        -- real to restore. A few short retries: the server-side ped can
        -- lag slightly behind PlayerLoaded firing.
        local attempts = 0
        local ped = 0
        while attempts < 10 do
            ped = GetPlayerPed(src)
            if ped ~= 0 then break end
            Wait(500)
            attempts = attempts + 1
        end
        if ped ~= 0 then
            local ok, err = pcall(MySQL.update.await,
                'UPDATE k9_ped_assignments SET original_model_hash = ? WHERE citizenid = ? AND active = 1 AND original_model_hash IS NULL',
                { GetEntityModel(ped), citizenid })
            if not ok then
                print(('[qbx_k9unit] appearance.lua PlayerLoaded original-model capture failed for %s: %s'):format(citizenid, tostring(err)))
            end
        else
            print(('[qbx_k9unit] appearance.lua PlayerLoaded: could not resolve a live ped for %s to capture ' ..
                'their pre-swap original model -- a later revert will use Config.K9Appearance.fallbackHumanModel instead.'):format(citizenid))
        end
    end

    SendSwapRequest(citizenid, 'apply', row.model, 'system')
end)

-- SECURITY FIX (coder-architect, adversarial-pass finding, this pass):
-- ASYMMETRIC ON PURPOSE, unlike this file's own earlier (WRONG, since
-- corrected) header claim that a dropped pending swap always means
-- "nothing was ever written -- no DB state to clean up": that is true for
-- 'apply' (no pre-existing DB state a drop could leave dangling -- a
-- pending apply that never confirmed correctly stays un-applied) but NOT
-- for 'revert', which starts from a PRE-EXISTING `active = 1` row. A
-- target who disconnects mid-revert (deliberately -- an alt-F4 the moment
-- a suspicious model swap arrives, or simply after seeing it -- or by
-- pure chance) previously left that stale active row untouched, and
-- PlayerLoaded (above) would have re-applied it on their very next
-- reconnect with NO re-check of anything, permanently defeating a
-- decertification. The server already MADE this decision before ever
-- sending the swap (this is what distinguishes a revert from an apply,
-- which is not yet a decision to keep, only a request that might fail to
-- load); only the client's own visual confirmation is missing, and that
-- stops mattering the instant the player is gone. Commit it here,
-- unconditionally, for a dropped 'revert' only -- the PlayerLoaded
-- HasK9Role backstop above is a second, independent line of defense for
-- any OTHER way a stale active row could ever occur.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        local pending = PendingSwap[citizenid]
        PendingSwap[citizenid] = nil
        if pending and pending.kind == 'revert' then
            WriteAppearanceReverted(citizenid)
            LogAppearanceAudit(pending.granterLabel, 'k9AppearanceRevert', ('citizenid=%s'):format(citizenid), 'committed_on_disconnect')
        end
    end
end)
