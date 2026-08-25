--[[
    qbx_k9unit/server/datastore.lua

    THE ONLY PLACE IN THIS RESOURCE THAT MAY NAME A `k9_*` TABLE OR CALL
    `MySQL.*` DIRECTLY. Every other server file reads/writes this
    resource's persistent state through the `K9Store` table this file
    exposes -- never through its own `MySQL.scalar/single/query/insert/
    update` call, and never through its own `if Config.Database.enabled
    then ... else ... end` branch. That is the whole point of this file.

    Owner's own words for the request this answers: "setup in the config
    if i dont want to do a sql injection i just say false in the section
    and it will disable all those features that rely on it but still try
    to make sure we can use as many of those features even if its off."

    THE READING THAT MAKES THAT TRACTABLE (verified against every real
    query this resource makes before writing a line of this file, not
    assumed): almost nothing here needs a database to FUNCTION. What the
    database provides is PERSISTENCE. Certifications, XP, partnerships,
    permissions, runtime feature overrides, tablet theming and K9 ped
    assignments can all live in memory for the life of the server process
    -- every access/authorization CHECK this resource makes is answerable
    from whatever this process currently holds, online or not, exactly as
    it is today. The honest story for `Config.Database.enabled = false` is
    therefore not "these features turn off" -- it is "everything keeps
    working, nothing is remembered past a restart," plus the audit tables
    (k9_search_log, k9_runtime_override_audit, k9_tablet_theme_audit)
    simply never getting a row written. See config.lua's own
    `Config.Database` block for the plain-language version of this
    promise aimed at a non-programmer operator.

    ======================================================================
    ARCHITECTURE -- ONE CODE PATH, TWO BACKENDS

    Every public `K9Store.*` function below has EXACTLY ONE `if
    DatabaseEnabled() then ... else ... end` branch, at the very top of its
    own body, and nowhere else. The `true` branch runs the real,
    byte-identical SQL this resource has always run (copied verbatim from
    the production call sites this file replaces -- see the per-table
    section headers below for exactly which file/line each one came from).
    The `false` branch answers the identical question from a plain Lua
    table this file owns, enforcing the identical invariants (at most one
    active row per key, fail-closed on a miss, bounded growth for the one
    table designed to grow without limit). No caller of `K9Store` ever
    branches on `Config.Database.enabled` itself -- that flag is read in
    exactly the places listed in this file, full stop. That is what makes
    "which backend is live" a single fact instead of something that can
    drift file by file, the exact bug class this resource has already
    shipped once for fresh-install-vs-upgraded-install schema drift.

    CONTRACT DISCIPLINE, so every call site elsewhere in this resource can
    swap `MySQL.xxx.await(sql, params)` for `K9Store.SomeFunction(args)`
    with NO other change to its own surrounding logic (no change to how it
    pcalls, no change to how it reads the result): each function below
    mirrors the exact return/throw contract of the ONE oxmysql method it
    replaces, table for table --
      * mirrors `MySQL.scalar.await`  -> returns a scalar value, or nil.
      * mirrors `MySQL.single.await`  -> returns one row (a table), or nil.
      * mirrors `MySQL.query.await`   -> returns an array of rows (never nil).
      * mirrors `MySQL.insert.await`  -> returns the new row's id, or
        THROWS (via Lua `error()`) on failure -- callers already `pcall()`
        this exactly like they pcall a real insert today.
      * mirrors `MySQL.update.await`  -> returns the affected-row count.
      * a few mirror this resource's own existing `SafeQuery`/`SafeWrite`
        bespoke wrappers instead (admin.lua, permissions.lua,
        runtimecontrol.lua, tablet.lua all independently hand-rolled the
        same "pcall around a query, log and degrade on failure" pattern --
        those call sites already expect a boolean/empty-table return, never
        a thrown error, so the functions replacing THEM keep that contract
        instead of oxmysql's raw one).
    A DUPLICATE-ACTIVE-ROW CONDITION in memory mode raises the SAME SHAPE
    of error object oxmysql's mysql2 driver raises for a real MySQL error
    1062 (`{ errno = 1062, message = 'ER_DUP_ENTRY: ...' }`) -- every
    `IsDuplicateKeyError(err)` helper already hand-rolled independently in
    certifications.lua/permissions.lua/partnership.lua checks `err.errno ==
    1062` FIRST, before ever inspecting a message string, so this needs
    ZERO changes to that existing duplicate-detection logic at any call
    site. Documented here once rather than re-derived at each table below.

    WHY THIS NEVER ACTUALLY RACES IN MEMORY MODE, worth being explicit
    about rather than leaving implicit: every one of this resource's real
    check-then-insert sequences (GrantCertification's `GrantInFlight` lock,
    permissions.lua's identically-shaped lock, partnership.lua's
    `PartnershipEstablishMutex`) exists to close a race that can only occur
    because a REAL `.await` call yields this coroutine and lets FXServer
    resume a second, concurrent request in the gap. A memory-mode
    `K9Store` call never yields at all -- it is a synchronous Lua table
    scan -- so on FXServer's single-threaded/cooperatively-scheduled Lua
    VM, two calls for the same key can never interleave in memory mode in
    the first place. Those application-level locks stay exactly as they
    are (this file does not touch them, and should not) -- they simply
    have nothing left to close when the backend beneath them cannot yield;
    the duplicate-row throw below is pure defense-in-depth, mirroring what
    the DB-level UNIQUE KEY backstops on the real backend.

    FAIL-CLOSED, BY CONSTRUCTION, NOT BY DISCIPLINE: a fresh server process
    in memory mode starts with EVERY table in this file completely empty.
    Nobody is pre-certified, pre-permitted, or pre-partnered -- a citizenid
    only appears in any of these tables after a real, server-authorized
    grant happens during THIS session. That is what makes "a session-only
    grant can only be easier to LOSE than a saved one, never easier to
    get" true structurally, not just as a design intention: there is no
    code path in this file that invents a row nobody granted.

    BOUNDED GROWTH: `k9_search_log` is the one table in this schema
    designed to grow without limit -- sql/install.sql's own header calls
    it "append-mostly" for the other audit tables but genuinely unbounded
    for this one. Its memory-mode mirror below is a fixed-capacity ring
    buffer (`SEARCH_LOG_MEMORY_CAP`), never a table that grows for the
    life of the process -- see that section for the exact number and
    reasoning. `k9_runtime_override_audit` / `k9_tablet_theme_audit` are
    also unbounded on the real backend (nothing ever prunes them there
    either) but are driven by rare, high-command-gated administrative
    actions rather than ordinary gameplay, so their memory-mode mirrors
    use a smaller, separate cap for the same reason -- see their own
    section.

    WHAT THIS FILE DELIBERATELY DOES NOT DO: it does not change what any
    caller is AUTHORIZED to do. Every eligibility check, cooldown, mutex,
    proximity check, and rank/permission gate in every file this
    accessor layer serves stays exactly where it is, in that file, running
    exactly as before -- this file only changes where the READ or WRITE at
    the bottom of an already-authorized action goes.

    LOAD ORDER: this file calls no natives and reads no other resource
    file's globals at its own load time (only inside function bodies,
    called later, at runtime) -- so its only real requirement is loading
    BEFORE every file that calls `K9Store.*`, i.e. before every other
    resource-owned file in `server_scripts`. See fxmanifest.lua's own
    placement comment for this file.
]]

K9Store = {}

-- ======================================================================
-- BACKEND SELECTION -- the ONE flag read in this whole resource.
-- ======================================================================

--- @return boolean
--- Anything other than a literal `false` on `Config.Database.enabled`
--- means "on" -- including `Config.Database` not existing at all yet (an
--- older config.lua that predates this feature). That is a deliberate
--- fail-safe default: a config that has never heard of this flag gets
--- today's behavior (a real database), never a silent, unrequested
--- switch to memory-only mode.
local function DatabaseEnabled()
    return not (type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database.enabled == false)
end

K9Store.IsDatabaseEnabled = DatabaseEnabled

-- ======================================================================
-- SHARED MEMORY-BACKEND HELPERS
-- ======================================================================

--- @return number
local function NowUnix()
    return os.time()
end

--- Formats a Lua epoch as the same "YYYY-MM-DD HH:MM:SS" shape oxmysql
--- hands back for a DATETIME column, so a caller that does `tostring(row.
--- granted_at)` (this resource's admin/tablet formatting convention)
--- prints something sane in memory mode too.
--- @param unixTime number?
--- @return string?
local function FormatDateTime(unixTime)
    if not unixTime then return nil end
    return os.date('%Y-%m-%d %H:%M:%S', unixTime)
end

--- Raises the SAME SHAPE of error oxmysql's mysql2 driver raises for a
--- real MySQL/MariaDB error 1062 (duplicate entry against a UNIQUE KEY) --
--- see this file's header for why every existing `IsDuplicateKeyError`
--- helper elsewhere in this resource already recognizes this without any
--- change on its part.
--- @param context string -- for the console line only, never parsed by a caller
local function ThrowDuplicateActiveRow(context)
    error({ errno = 1062, message = ('ER_DUP_ENTRY: duplicate active row for %s (qbx_k9unit in-memory backend)'):format(context) }, 0)
end

-- ======================================================================
-- k9_certifications
--
-- Real queries mirrored below, copied from server/certifications.lua
-- (RefreshCertificationCache, IsCertRowConfirmedActive, GrantCertification/
-- doGrantInsert, RevokeCertification/RevokeCertificationOffline/
-- QBCore:Server:OnJobUpdate, SetCertificationTier, RenewCertification,
-- QueryCertificationRecord), server/appearance.lua (IsCertifiedK9ForJob/
-- IsCertifiedK9ForAnyJob), server/tablet.lua (QueryHasAnyActiveCertification)
-- and server/admin.lua (QueryCertificationHistory, QueryDepartmentRoster).
-- ======================================================================
local CertRows = {}
local CertNextId = 0

--- @param citizenid string
--- @param job string? -- nil matches ANY job (IsCertifiedK9ForAnyJob's shape)
--- @return table? row
local function CertFindActive(citizenid, job)
    for _, row in ipairs(CertRows) do
        if row.active == 1 and row.citizenid == citizenid and (job == nil or row.job == job) then
            return row
        end
    end
    return nil
end

--- Mirrors MySQL.scalar.await. Replaces server/certifications.lua's
--- RefreshCertificationCache/IsCertRowConfirmedActive/GrantCertification
--- existence-check queries.
function K9Store.Cert_GetActiveId(citizenid, job)
    if DatabaseEnabled() then
        return MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', { citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    return row and row.id or nil
end

--- Mirrors MySQL.scalar.await. Replaces server/appearance.lua's
--- IsCertifiedK9ForAnyJob and server/tablet.lua's
--- QueryHasAnyActiveCertification (identical "any department" query).
function K9Store.Cert_GetActiveIdAnyJob(citizenid)
    if DatabaseEnabled() then
        return MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND active = 1 LIMIT 1', { citizenid })
    end
    local row = CertFindActive(citizenid, nil)
    return row and row.id or nil
end

--- Mirrors MySQL.single.await. Replaces RefreshCertificationCache's own
--- tier/expiry metadata read.
--- @return table? { tier: string, expires_at_unix: number? }
function K9Store.Cert_GetActiveMeta(citizenid, job)
    if DatabaseEnabled() then
        return MySQL.single.await(
            'SELECT tier, UNIX_TIMESTAMP(expires_at) AS expires_at_unix FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1',
            { citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return nil end
    return { tier = row.tier, expires_at_unix = row.expires_at_unix }
end

--- Mirrors MySQL.insert.await -- returns the new row's id, or THROWS
--- (a duplicate-active-row error in memory mode, a real thrown oxmysql
--- error in DB mode) exactly like the real INSERT this replaces.
--- @param expiryDays number? -- nil = no expiry (DEFAULT NULL, matches the real schema)
--- @return number id
function K9Store.Cert_Insert(citizenid, job, grantedBy, expiryDays)
    if DatabaseEnabled() then
        if expiryDays then
            return MySQL.insert.await(
                'INSERT INTO k9_certifications (citizenid, job, granted_by, expires_at) VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL ? DAY))',
                { citizenid, job, grantedBy, expiryDays })
        end
        return MySQL.insert.await('INSERT INTO k9_certifications (citizenid, job, granted_by) VALUES (?, ?, ?)', { citizenid, job, grantedBy })
    end
    if CertFindActive(citizenid, job) then ThrowDuplicateActiveRow('k9_certifications ' .. citizenid .. '::' .. job) end
    CertNextId = CertNextId + 1
    CertRows[#CertRows + 1] = {
        id = CertNextId, citizenid = citizenid, job = job, granted_by = grantedBy,
        granted_at = FormatDateTime(NowUnix()), revoked_by = nil, revoked_at = nil, revoke_reason = nil,
        expires_at_unix = expiryDays and (NowUnix() + expiryDays * 86400) or nil,
        active = 1, tier = 'certified',
    }
    return CertNextId
end

--- Mirrors MySQL.update.await. Replaces the (byte-identical) UPDATE used
--- by RevokeCertification, RevokeCertificationOffline, and the
--- QBCore:Server:OnJobUpdate auto-revoke branch.
--- @return number affectedRows
function K9Store.Cert_RevokeActive(citizenid, job, revokedBy, reason)
    if DatabaseEnabled() then
        return MySQL.update.await(
            'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP, revoke_reason = ? WHERE citizenid = ? AND job = ? AND active = 1',
            { revokedBy, reason, citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return 0 end
    row.active, row.revoked_by, row.revoked_at, row.revoke_reason = 0, revokedBy, FormatDateTime(NowUnix()), reason
    return 1
end

--- Mirrors MySQL.update.await. Replaces SetCertificationTier's UPDATE.
function K9Store.Cert_SetTier(citizenid, job, tier)
    if DatabaseEnabled() then
        return MySQL.update.await('UPDATE k9_certifications SET tier = ? WHERE citizenid = ? AND job = ? AND active = 1', { tier, citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return 0 end
    row.tier = tier
    return 1
end

--- Mirrors MySQL.update.await. Replaces RenewCertification's UPDATE.
function K9Store.Cert_RenewExpiry(citizenid, job, expiryDays)
    if DatabaseEnabled() then
        return MySQL.update.await('UPDATE k9_certifications SET expires_at = DATE_ADD(NOW(), INTERVAL ? DAY) WHERE citizenid = ? AND job = ? AND active = 1', { expiryDays, citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return 0 end
    row.expires_at_unix = NowUnix() + expiryDays * 86400
    return 1
end

--- Mirrors MySQL.single.await. Replaces QueryCertificationRecord's own
--- row read (that function still layers QueryActiveSpecializations on
--- top itself -- unchanged, that is a separate table/call below).
function K9Store.Cert_GetActiveRecord(citizenid, job)
    if DatabaseEnabled() then
        return MySQL.single.await(
            'SELECT tier, granted_by, granted_at, revoked_by, revoked_at, revoke_reason, UNIX_TIMESTAMP(expires_at) AS expires_at_unix ' ..
            'FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', { citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return nil end
    return {
        tier = row.tier, granted_by = row.granted_by, granted_at = row.granted_at,
        revoked_by = row.revoked_by, revoked_at = row.revoked_at, revoke_reason = row.revoke_reason,
        expires_at_unix = row.expires_at_unix,
    }
end

--- Mirrors MySQL.query.await. Replaces server/admin.lua's
--- QueryCertificationHistory ('/k9auditcert'). MEMORY-MODE SCOPE NOTE:
--- only rows created THIS SESSION exist to return -- a restart already
--- erased anything older, per this file's header. Not a bug to fix here;
--- it is the documented cost of Config.Database.enabled = false.
--- @return table rows -- newest first
function K9Store.Cert_GetHistory(citizenid, limit)
    if DatabaseEnabled() then
        local sql = ('SELECT job, granted_by, granted_at, revoked_by, revoked_at, active FROM k9_certifications WHERE citizenid = ? ORDER BY granted_at DESC LIMIT %d'):format(limit)
        return MySQL.query.await(sql, { citizenid })
    end
    local out = {}
    for i = #CertRows, 1, -1 do
        local row = CertRows[i]
        if row.citizenid == citizenid then
            out[#out + 1] = { job = row.job, granted_by = row.granted_by, granted_at = row.granted_at, revoked_by = row.revoked_by, revoked_at = row.revoked_at, active = row.active }
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors MySQL.query.await. Replaces server/admin.lua's
--- QueryDepartmentRoster ('/k9auditdept') -- CURRENT roster only.
function K9Store.Cert_GetActiveRosterByJob(job, limit)
    if DatabaseEnabled() then
        local sql = ('SELECT citizenid, granted_by, granted_at FROM k9_certifications WHERE job = ? AND active = 1 ORDER BY granted_at DESC LIMIT %d'):format(limit)
        return MySQL.query.await(sql, { job })
    end
    local out = {}
    for i = #CertRows, 1, -1 do
        local row = CertRows[i]
        if row.job == job and row.active == 1 then
            out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = row.granted_at }
            if #out >= limit then break end
        end
    end
    return out
end

-- ======================================================================
-- k9_certification_specializations
--
-- Mirrored from server/certifications.lua (RefreshSpecializationCache,
-- RevokeAllSpecializationsForCitizenJob, GrantSpecialization/
-- doGrantInsert, RevokeSpecialization/RevokeSpecializationOffline,
-- QueryActiveSpecializations).
-- ======================================================================
local SpecRows = {}
local SpecNextId = 0

local function SpecFindActive(citizenid, job, specialization)
    for _, row in ipairs(SpecRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job and row.specialization == specialization then
            return row
        end
    end
    return nil
end

--- Mirrors MySQL.query.await. Row shape (`{ specialization = ... }`)
--- matches the real column list exactly, since both call sites this
--- replaces (RefreshSpecializationCache, RevokeAllSpecializationsForCitizenJob)
--- iterate `row.specialization` directly.
function K9Store.Spec_GetActiveKeys(citizenid, job)
    if DatabaseEnabled() then
        return MySQL.query.await('SELECT specialization FROM k9_certification_specializations WHERE citizenid = ? AND job = ? AND active = 1', { citizenid, job })
    end
    local out = {}
    for _, row in ipairs(SpecRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job then
            out[#out + 1] = { specialization = row.specialization }
        end
    end
    return out
end

--- Mirrors MySQL.scalar.await. Replaces GrantSpecialization's existence check.
function K9Store.Spec_GetActiveId(citizenid, job, specialization)
    if DatabaseEnabled() then
        return MySQL.scalar.await(
            'SELECT id FROM k9_certification_specializations WHERE citizenid = ? AND job = ? AND specialization = ? AND active = 1 LIMIT 1',
            { citizenid, job, specialization })
    end
    local row = SpecFindActive(citizenid, job, specialization)
    return row and row.id or nil
end

--- Mirrors MySQL.insert.await.
function K9Store.Spec_Insert(citizenid, job, specialization, grantedBy)
    if DatabaseEnabled() then
        return MySQL.insert.await(
            'INSERT INTO k9_certification_specializations (citizenid, job, specialization, granted_by) VALUES (?, ?, ?, ?)',
            { citizenid, job, specialization, grantedBy })
    end
    if SpecFindActive(citizenid, job, specialization) then
        ThrowDuplicateActiveRow('k9_certification_specializations ' .. citizenid .. '::' .. job .. '::' .. specialization)
    end
    SpecNextId = SpecNextId + 1
    SpecRows[#SpecRows + 1] = {
        id = SpecNextId, citizenid = citizenid, job = job, specialization = specialization, granted_by = grantedBy,
        granted_at = FormatDateTime(NowUnix()), revoked_by = nil, revoked_at = nil, active = 1,
    }
    return SpecNextId
end

--- Mirrors MySQL.update.await. Replaces RevokeSpecialization/
--- RevokeSpecializationOffline's (byte-identical) UPDATE.
function K9Store.Spec_RevokeOne(citizenid, job, specialization, revokedBy)
    if DatabaseEnabled() then
        return MySQL.update.await(
            'UPDATE k9_certification_specializations SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND specialization = ? AND active = 1',
            { revokedBy, citizenid, job, specialization })
    end
    local row = SpecFindActive(citizenid, job, specialization)
    if not row then return 0 end
    row.active, row.revoked_by, row.revoked_at = 0, revokedBy, FormatDateTime(NowUnix())
    return 1
end

--- Mirrors MySQL.update.await. Replaces
--- RevokeAllSpecializationsForCitizenJob's bulk UPDATE (cascades every
--- active specialization for one (citizenid, job) pair at once).
function K9Store.Spec_RevokeAllForJob(citizenid, job, revokedBy)
    if DatabaseEnabled() then
        return MySQL.update.await(
            'UPDATE k9_certification_specializations SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
            { revokedBy, citizenid, job })
    end
    local count = 0
    for _, row in ipairs(SpecRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job then
            row.active, row.revoked_by, row.revoked_at = 0, revokedBy, FormatDateTime(NowUnix())
            count = count + 1
        end
    end
    return count
end

-- ======================================================================
-- k9_partnerships
--
-- Mirrored from server/partnership.lua (RefreshPartnershipCache, the
-- establish critical section's two pre-checks + INSERT, DoBreakPartnership's
-- SELECT/UPDATE/reconciliation), server/tenure.lua (CheckTenureMilestonesForK9)
-- and server/admin.lua (QueryPartnershipHistory, both roles).
--
-- TWO INDEPENDENT UNIQUENESS DIMENSIONS, exactly like the real schema's
-- two separate UNIQUE KEYs: a citizenid may not appear as an ACTIVE party
-- in more than one row, whether as the K9 or as the handler. Enforced
-- below the same way the real INSERT's two DB-level UNIQUE KEYs do --
-- reject on EITHER party already being active in any row.
-- ======================================================================
local PartnerRows = {}
local PartnerNextId = 0

--- @return table? row -- the FULL internal row (includes established_at_unix)
local function PartnerFindActiveRowByParty(citizenid)
    for _, row in ipairs(PartnerRows) do
        if row.active == 1 and (row.k9_citizenid == citizenid or row.handler_citizenid == citizenid) then
            return row
        end
    end
    return nil
end

local function PartnerFindById(id)
    for _, row in ipairs(PartnerRows) do
        if row.id == id then return row end
    end
    return nil
end

--- Mirrors MySQL.single.await. Replaces RefreshPartnershipCache's own
--- read and DoBreakPartnership's initial SELECT (both select `id,
--- k9_citizenid, handler_citizenid` for either-role lookup).
function K9Store.Partner_GetActiveRowByParty(citizenid)
    if DatabaseEnabled() then
        return MySQL.single.await(
            'SELECT id, k9_citizenid, handler_citizenid FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
            { citizenid, citizenid })
    end
    local row = PartnerFindActiveRowByParty(citizenid)
    if not row then return nil end
    return { id = row.id, k9_citizenid = row.k9_citizenid, handler_citizenid = row.handler_citizenid }
end

--- Mirrors MySQL.scalar.await. Replaces the establish critical section's
--- two identical pre-INSERT existence checks (one per party).
function K9Store.Partner_GetActiveIdByParty(citizenid)
    if DatabaseEnabled() then
        return MySQL.scalar.await(
            'SELECT id FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
            { citizenid, citizenid })
    end
    local row = PartnerFindActiveRowByParty(citizenid)
    return row and row.id or nil
end

--- Mirrors MySQL.insert.await. THROWS a duplicate-active-row error (memory
--- mode) if EITHER party already has an active row -- mirrors the real
--- schema's two independent UNIQUE KEYs backstopping the same INSERT.
function K9Store.Partner_Insert(k9Citizenid, handlerCitizenid, establishedBy)
    if DatabaseEnabled() then
        return MySQL.insert.await('INSERT INTO k9_partnerships (k9_citizenid, handler_citizenid, established_by) VALUES (?, ?, ?)', { k9Citizenid, handlerCitizenid, establishedBy })
    end
    if PartnerFindActiveRowByParty(k9Citizenid) then ThrowDuplicateActiveRow('k9_partnerships k9=' .. k9Citizenid) end
    if PartnerFindActiveRowByParty(handlerCitizenid) then ThrowDuplicateActiveRow('k9_partnerships handler=' .. handlerCitizenid) end
    PartnerNextId = PartnerNextId + 1
    PartnerRows[#PartnerRows + 1] = {
        id = PartnerNextId, k9_citizenid = k9Citizenid, handler_citizenid = handlerCitizenid, established_by = establishedBy,
        established_at_unix = NowUnix(), established_at = FormatDateTime(NowUnix()),
        ended_by = nil, ended_at = nil, active = 1, tenure_bonus_tier_granted = 0,
    }
    return PartnerNextId
end

--- Mirrors MySQL.update.await. Replaces DoBreakPartnership's UPDATE
--- (`WHERE id = ? AND active = 1`).
function K9Store.Partner_EndById(id, endedBy)
    if DatabaseEnabled() then
        return MySQL.update.await('UPDATE k9_partnerships SET active = 0, ended_by = ?, ended_at = CURRENT_TIMESTAMP WHERE id = ? AND active = 1', { endedBy, id })
    end
    local row = PartnerFindById(id)
    if not row or row.active ~= 1 then return 0 end
    row.active, row.ended_by, row.ended_at = 0, endedBy, FormatDateTime(NowUnix())
    return 1
end

--- Mirrors MySQL.scalar.await. Replaces DoBreakPartnership's
--- reconciliation read (`SELECT active FROM k9_partnerships WHERE id = ?
--- LIMIT 1`) -- deliberately looks up by id ALONE, regardless of current
--- `active` value, matching the real query's own unfiltered WHERE clause.
function K9Store.Partner_GetActiveFlagById(id)
    if DatabaseEnabled() then
        return MySQL.scalar.await('SELECT active FROM k9_partnerships WHERE id = ? LIMIT 1', { id })
    end
    local row = PartnerFindById(id)
    return row and row.active or nil
end

local function PartnerHistoryColumns(row)
    return {
        id = row.id, k9_citizenid = row.k9_citizenid, handler_citizenid = row.handler_citizenid,
        established_by = row.established_by, established_at = row.established_at,
        ended_by = row.ended_by, ended_at = row.ended_at, active = row.active,
    }
end

--- Mirrors MySQL.query.await. Replaces server/admin.lua's
--- QueryPartnershipHistory K9-side sub-query.
function K9Store.Partner_GetHistoryByK9(citizenid, limit)
    if DatabaseEnabled() then
        local columns = 'id, k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active'
        local sql = ('SELECT %s FROM k9_partnerships WHERE k9_citizenid = ? ORDER BY id DESC LIMIT %d'):format(columns, limit)
        return MySQL.query.await(sql, { citizenid })
    end
    local out = {}
    for i = #PartnerRows, 1, -1 do
        if PartnerRows[i].k9_citizenid == citizenid then
            out[#out + 1] = PartnerHistoryColumns(PartnerRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors MySQL.query.await. Replaces server/admin.lua's
--- QueryPartnershipHistory handler-side sub-query.
function K9Store.Partner_GetHistoryByHandler(citizenid, limit)
    if DatabaseEnabled() then
        local columns = 'id, k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active'
        local sql = ('SELECT %s FROM k9_partnerships WHERE handler_citizenid = ? ORDER BY id DESC LIMIT %d'):format(columns, limit)
        return MySQL.query.await(sql, { citizenid })
    end
    local out = {}
    for i = #PartnerRows, 1, -1 do
        if PartnerRows[i].handler_citizenid == citizenid then
            out[#out + 1] = PartnerHistoryColumns(PartnerRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors MySQL.single.await. Replaces server/tenure.lua's
--- CheckTenureMilestonesForK9 read. `tenure_seconds` is computed the same
--- way SQL's TIMESTAMPDIFF(SECOND, established_at, NOW()) would (both
--- measured against real wall-clock time; in memory mode a restart resets
--- tenure to zero along with everything else in this table).
function K9Store.Partner_GetTenureRow(k9Citizenid)
    if DatabaseEnabled() then
        return MySQL.single.await(
            'SELECT id, k9_citizenid, handler_citizenid, tenure_bonus_tier_granted, TIMESTAMPDIFF(SECOND, established_at, NOW()) AS tenure_seconds FROM k9_partnerships WHERE active = 1 AND k9_citizenid = ? LIMIT 1',
            { k9Citizenid })
    end
    for _, row in ipairs(PartnerRows) do
        if row.active == 1 and row.k9_citizenid == k9Citizenid then
            return {
                id = row.id, k9_citizenid = row.k9_citizenid, handler_citizenid = row.handler_citizenid,
                tenure_bonus_tier_granted = row.tenure_bonus_tier_granted,
                tenure_seconds = NowUnix() - row.established_at_unix,
            }
        end
    end
    return nil
end

--- Mirrors MySQL.update.await. Replaces CheckTenureMilestonesForK9's
--- optimistic CAS UPDATE -- only applies `newTier` if the row is still
--- active AND its `tenure_bonus_tier_granted` still equals
--- `expectedOldTier` (a lost race returns 0, exactly like the real
--- UPDATE's affected-row count would).
function K9Store.Partner_SetTenureTierCAS(id, newTier, expectedOldTier)
    if DatabaseEnabled() then
        return MySQL.update.await(
            'UPDATE k9_partnerships SET tenure_bonus_tier_granted = ? WHERE id = ? AND active = 1 AND tenure_bonus_tier_granted = ?',
            { newTier, id, expectedOldTier })
    end
    local row = PartnerFindById(id)
    if not row or row.active ~= 1 or row.tenure_bonus_tier_granted ~= expectedOldTier then return 0 end
    row.tenure_bonus_tier_granted = newTier
    return 1
end

-- ======================================================================
-- k9_permissions
--
-- Mirrored from server/permissions.lua (RefreshPermissionCache,
-- IsPermissionRowConfirmedActive, GrantPermission/doGrantInsert,
-- RevokePermission) and server/tablet.lua (QueryActivePermissionSet).
-- ======================================================================
local PermRows = {}
local PermNextId = 0

local function PermFindActive(citizenid, permission)
    for _, row in ipairs(PermRows) do
        if row.active == 1 and row.citizenid == citizenid and row.permission == permission then
            return row
        end
    end
    return nil
end

--- Mirrors MySQL.scalar.await. Replaces IsPermissionRowConfirmedActive's
--- read and GrantPermission's own pre-check.
function K9Store.Perm_GetActiveId(citizenid, permission)
    if DatabaseEnabled() then
        return MySQL.scalar.await('SELECT id FROM k9_permissions WHERE citizenid = ? AND permission = ? AND active = 1 LIMIT 1', { citizenid, permission })
    end
    local row = PermFindActive(citizenid, permission)
    return row and row.id or nil
end

--- Mirrors MySQL.query.await. Row shape (`{ permission = ... }`) matches
--- the real single-column SELECT -- both RefreshPermissionCache and
--- server/tablet.lua's QueryActivePermissionSet iterate `row.permission`
--- directly.
function K9Store.Perm_GetActiveForCitizen(citizenid)
    if DatabaseEnabled() then
        return MySQL.query.await('SELECT permission FROM k9_permissions WHERE citizenid = ? AND active = 1', { citizenid })
    end
    local out = {}
    for _, row in ipairs(PermRows) do
        if row.active == 1 and row.citizenid == citizenid then
            out[#out + 1] = { permission = row.permission }
        end
    end
    return out
end

--- Mirrors MySQL.insert.await.
function K9Store.Perm_Insert(citizenid, permission, grantedBy)
    if DatabaseEnabled() then
        return MySQL.insert.await('INSERT INTO k9_permissions (citizenid, permission, granted_by) VALUES (?, ?, ?)', { citizenid, permission, grantedBy })
    end
    if PermFindActive(citizenid, permission) then ThrowDuplicateActiveRow('k9_permissions ' .. citizenid .. '::' .. permission) end
    PermNextId = PermNextId + 1
    PermRows[#PermRows + 1] = {
        id = PermNextId, citizenid = citizenid, permission = permission, granted_by = grantedBy,
        granted_at = FormatDateTime(NowUnix()), revoked_by = nil, revoked_at = nil, active = 1,
    }
    return PermNextId
end

--- Mirrors MySQL.update.await. Replaces RevokePermission's UPDATE.
function K9Store.Perm_RevokeActive(citizenid, permission, revokedBy)
    if DatabaseEnabled() then
        return MySQL.update.await('UPDATE k9_permissions SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND permission = ? AND active = 1', { revokedBy, citizenid, permission })
    end
    local row = PermFindActive(citizenid, permission)
    if not row then return 0 end
    row.active, row.revoked_by, row.revoked_at = 0, revokedBy, FormatDateTime(NowUnix())
    return 1
end

-- ======================================================================
-- k9_progression
--
-- Mirrored from server/progression.lua (LoadXPForCitizenid, AwardXP's/
-- AwardXPDirect's UPSERT) and server/admin.lua/server/leaderboard.lua's
-- own read queries. UNLIKE the four "active-row" tables above, this one
-- is a live profile row (one per citizenid, upserted in place) -- see
-- sql/install.sql's own k9_progression header for why.
-- ======================================================================
local ProgressionRows = {} -- citizenid -> { xp = number, created_at_unix, updated_at_unix }

--- Mirrors MySQL.scalar.await. Replaces LoadXPForCitizenid's read.
--- @return number? xp -- nil if this citizenid has no row yet (matches the
--- real query's own nil-on-no-row shape; every existing caller already
--- treats nil as "0 XP", see LoadXPForCitizenid's own `xpOrErr or 0`).
function K9Store.XP_Get(citizenid)
    if DatabaseEnabled() then
        return MySQL.scalar.await('SELECT xp FROM k9_progression WHERE citizenid = ? LIMIT 1', { citizenid })
    end
    local row = ProgressionRows[citizenid]
    return row and row.xp or nil
end

--- Mirrors MySQL.insert.await -- an UPSERT that always "succeeds" (throws
--- only on a genuine DB-mode error; there is no uniqueness conflict to
--- reject in an atomic add-or-create). Callers keep their own
--- CreateThread/pcall wrapping around this call UNCHANGED (see this
--- file's header "CONTRACT DISCIPLINE") -- this function does not spawn
--- a thread itself, so the non-blocking behavior server/progression.lua's
--- AwardXP/AwardXPDirect already implement is preserved exactly as-is,
--- memory mode included (a plain table write here is already instant,
--- never a reason to defer it).
--- @param delta number -- the per-award DELTA, never the new running total
--- @return number insertId -- unused by every real caller today; returned only for parity with MySQL.insert.await's own contract
function K9Store.XP_UpsertAdd(citizenid, delta)
    if DatabaseEnabled() then
        return MySQL.insert.await(
            'INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?) ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP',
            { citizenid, delta })
    end
    local row = ProgressionRows[citizenid]
    if not row then
        row = { xp = 0, created_at_unix = NowUnix() }
        ProgressionRows[citizenid] = row
    end
    row.xp = row.xp + delta
    row.updated_at_unix = NowUnix()
    return 1
end

--- Mirrors MySQL.query.await. Replaces server/leaderboard.lua's
--- QueryTopXp. MEMORY-MODE SCOPE NOTE: ranks only citizenids this PROCESS
--- has actually touched via XP_Get/XP_UpsertAdd this session (typically:
--- everyone who has connected, or been queried, since the last restart)
--- -- there is no durable roster to rank an offline citizenid nobody has
--- interacted with yet against, which is the expected shape of a
--- session-only leaderboard, not a bug.
function K9Store.XP_GetTop(limit)
    if DatabaseEnabled() then
        local sql = ('SELECT citizenid, xp FROM k9_progression ORDER BY xp DESC LIMIT %d'):format(limit)
        return MySQL.query.await(sql, {})
    end
    local list = {}
    for citizenid, row in pairs(ProgressionRows) do
        list[#list + 1] = { citizenid = citizenid, xp = row.xp }
    end
    table.sort(list, function(a, b) return a.xp > b.xp end)
    local out = {}
    for i = 1, math.min(limit, #list) do out[i] = list[i] end
    return out
end

--- Mirrors the SafeQuery contract server/admin.lua's own
--- QueryProgressionSnapshot ('/k9auditxp') uses -- an array of 0 or 1 rows.
function K9Store.XP_GetSnapshotRows(citizenid)
    if DatabaseEnabled() then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT xp, updated_at FROM k9_progression WHERE citizenid = ? LIMIT 1', { citizenid })
        if not ok then
            print(('[qbx_k9unit] datastore: XP_GetSnapshotRows query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local row = ProgressionRows[citizenid]
    if not row then return {} end
    return { { xp = row.xp, updated_at = FormatDateTime(row.updated_at_unix or row.created_at_unix) } }
end

-- ======================================================================
-- k9_search_log
--
-- Mirrored from server/search.lua (LogSearchAttempt's INSERT) and
-- server/admin.lua's four read shapes (QuerySearchLogByOfficer/ByPlate/
-- ByPerson/Recent). THE ONE TABLE THIS SCHEMA DESIGNS TO GROW WITHOUT
-- LIMIT (sql/install.sql's own header) -- its memory mirror is therefore
-- a FIXED-CAPACITY RING BUFFER, never an ever-growing Lua table, so
-- Config.Database.enabled = false cannot become a slow memory leak on a
-- long-uptime server. `id` still increases monotonically even as old
-- rows are evicted, so 'ORDER BY id DESC' (QuerySearchLogRecent's own
-- sort key) stays meaningful throughout.
-- ======================================================================
local SEARCH_LOG_MEMORY_CAP = 500
local SearchLogRows = {}
local SearchLogNextId = 0

--- Mirrors MySQL.insert.await.
function K9Store.SearchLog_Insert(searcherCitizenid, searcherJob, targetType, targetPlate, targetCitizenid, result, totalWeight, alertTier)
    if DatabaseEnabled() then
        return MySQL.insert.await([[
            INSERT INTO k9_search_log
                (searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ]], { searcherCitizenid, searcherJob, targetType, targetPlate, targetCitizenid, result, totalWeight, alertTier })
    end
    SearchLogNextId = SearchLogNextId + 1
    SearchLogRows[#SearchLogRows + 1] = {
        id = SearchLogNextId, searcher_citizenid = searcherCitizenid, searcher_job = searcherJob,
        target_type = targetType, target_plate = targetPlate, target_citizenid = targetCitizenid,
        result = result, total_weight = totalWeight, alert_tier = alertTier, searched_at = FormatDateTime(NowUnix()),
    }
    -- RING BUFFER: drop the oldest row once over capacity -- see header.
    while #SearchLogRows > SEARCH_LOG_MEMORY_CAP do
        table.remove(SearchLogRows, 1)
    end
    return SearchLogNextId
end

local function SearchLogColumns(row)
    return {
        searcher_citizenid = row.searcher_citizenid, searcher_job = row.searcher_job, target_type = row.target_type,
        target_plate = row.target_plate, target_citizenid = row.target_citizenid, result = row.result,
        total_weight = row.total_weight, alert_tier = row.alert_tier, searched_at = row.searched_at, id = row.id,
    }
end

--- Mirrors the SafeQuery contract server/admin.lua's SafeQuery uses.
--- Replaces QuerySearchLogByOfficer ('/k9auditsearch officer').
function K9Store.SearchLog_GetByOfficer(citizenid, limit)
    if DatabaseEnabled() then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log WHERE searcher_citizenid = ? ORDER BY searched_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[qbx_k9unit] datastore: SearchLog_GetByOfficer query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        if SearchLogRows[i].searcher_citizenid == citizenid then
            out[#out + 1] = SearchLogColumns(SearchLogRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Replaces QuerySearchLogByPlate ('/k9auditsearch plate').
function K9Store.SearchLog_GetByPlate(plate, limit)
    if DatabaseEnabled() then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log WHERE target_plate = ? ORDER BY searched_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { plate })
        if not ok then
            print(('[qbx_k9unit] datastore: SearchLog_GetByPlate query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        if SearchLogRows[i].target_plate == plate then
            out[#out + 1] = SearchLogColumns(SearchLogRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Replaces QuerySearchLogByPerson ('/k9auditsearch person').
function K9Store.SearchLog_GetByPerson(citizenid, limit)
    if DatabaseEnabled() then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log WHERE target_citizenid = ? ORDER BY searched_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[qbx_k9unit] datastore: SearchLog_GetByPerson query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        if SearchLogRows[i].target_citizenid == citizenid then
            out[#out + 1] = SearchLogColumns(SearchLogRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Replaces QuerySearchLogRecent ('/k9auditsearch recent') -- ordered by
--- `id DESC`, not `searched_at`, matching the real query exactly (see
--- that function's own doc comment for why).
function K9Store.SearchLog_GetRecent(limit)
    if DatabaseEnabled() then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[qbx_k9unit] datastore: SearchLog_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        out[#out + 1] = SearchLogColumns(SearchLogRows[i])
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_runtime_feature_overrides / k9_runtime_override_audit
--
-- Mirrored from server/runtimecontrol.lua. The override table is a plain
-- key-value store (PRIMARY KEY on override_key, one row per key, upserted
-- in place) -- NOT an "active-row" table, so no generated-key uniqueness
-- engine is needed here. The audit table is a pure append-only log, same
-- "bounded in memory mode" treatment as k9_search_log above, but with a
-- smaller cap: these rows come from rare, high-command-gated admin
-- actions, not ordinary gameplay, so real-world volume is tiny -- the cap
-- exists as a hygiene backstop, not because this table is expected to
-- ever approach it.
-- ======================================================================
local OverrideRows = {} -- override_key -> { override_key, kind, value, updated_by, updated_at }
local OVERRIDE_AUDIT_MEMORY_CAP = 200
local OverrideAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces runtimecontrol.lua's
--- onResourceStart boot read (re-applying persisted overrides on top of
--- config.lua's defaults) -- IN MEMORY MODE THIS IS ALWAYS EMPTY ON A
--- FRESH PROCESS, by construction (there is nothing to have persisted
--- across the restart that just happened), so runtimecontrol.lua's own
--- boot loop naturally applies zero overrides and leaves config.lua's
--- shipped defaults in effect -- exactly the documented behavior.
function K9Store.Override_GetAll()
    if DatabaseEnabled() then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT override_key, kind, value, updated_by, updated_at FROM k9_runtime_feature_overrides', {})
        if not ok then
            print(('[qbx_k9unit] datastore: Override_GetAll query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for _, row in pairs(OverrideRows) do
        out[#out + 1] = { override_key = row.override_key, kind = row.kind, value = row.value, updated_by = row.updated_by, updated_at = row.updated_at }
    end
    return out
end

--- Mirrors the SafeWrite contract (boolean, never throws). Replaces every
--- `INSERT ... ON DUPLICATE KEY UPDATE` write against
--- k9_runtime_feature_overrides.
function K9Store.Override_Upsert(overrideKey, kind, value, updatedBy)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_runtime_feature_overrides (override_key, kind, value, updated_by) VALUES (?, ?, ?, ?) ' ..
            'ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { overrideKey, kind, value, updatedBy })
        if not ok then
            print(('[qbx_k9unit] datastore: Override_Upsert write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    OverrideRows[overrideKey] = { override_key = overrideKey, kind = kind, value = value, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()) }
    return true
end

--- Mirrors the SafeWrite contract. Replaces the `DELETE FROM
--- k9_runtime_feature_overrides WHERE override_key = ?` reset path.
function K9Store.Override_Delete(overrideKey)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await, 'DELETE FROM k9_runtime_feature_overrides WHERE override_key = ?', { overrideKey })
        if not ok then
            print(('[qbx_k9unit] datastore: Override_Delete write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    OverrideRows[overrideKey] = nil
    return true
end

--- Mirrors the SafeWrite contract. `newValue` may be nil (the "reset back
--- to default" shape the real INSERT already allows via a NULL column).
function K9Store.OverrideAudit_Append(overrideKey, kind, oldValue, newValue, changedBy)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_runtime_override_audit (override_key, kind, old_value, new_value, changed_by) VALUES (?, ?, ?, ?, ?)',
            { overrideKey, kind, oldValue, newValue, changedBy })
        if not ok then
            print(('[qbx_k9unit] datastore: OverrideAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    OverrideAuditRows[#OverrideAuditRows + 1] = { override_key = overrideKey, kind = kind, old_value = oldValue, new_value = newValue, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #OverrideAuditRows > OVERRIDE_AUDIT_MEMORY_CAP do
        table.remove(OverrideAuditRows, 1)
    end
    return true
end

-- ======================================================================
-- k9_tablet_theme / k9_tablet_theme_audit
--
-- Mirrored from server/runtimecontrol.lua. k9_tablet_theme is a SINGLETON
-- (always exactly one row, id = 1, per that table's own sql/install.sql
-- header) -- the memory mirror is simply one Lua table or nil, never a
-- keyed store. k9_tablet_theme_audit is append-only, same bounded
-- treatment as the runtime-override audit log above and for the same
-- reason (rare, high-command-gated admin action, not gameplay volume).
-- ======================================================================
local ThemeRow = nil
local THEME_AUDIT_MEMORY_CAP = 200
local ThemeAuditRows = {}

--- Mirrors the SafeQuery contract -- an array of 0 or 1 rows, matching
--- runtimecontrol.lua's own onResourceStart read exactly.
function K9Store.Theme_GetRows()
    if DatabaseEnabled() then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT primary_color, accent_color, background_color, text_color, density, header_title FROM k9_tablet_theme WHERE id = 1', {})
        if not ok then
            print(('[qbx_k9unit] datastore: Theme_GetRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    if not ThemeRow then return {} end
    return { { primary_color = ThemeRow.primary_color, accent_color = ThemeRow.accent_color, background_color = ThemeRow.background_color, text_color = ThemeRow.text_color, density = ThemeRow.density, header_title = ThemeRow.header_title } }
end

--- Mirrors the SafeWrite contract. Replaces both tabletSetTheme's and
--- tabletResetTheme's identical `INSERT ... ON DUPLICATE KEY UPDATE`
--- against the id=1 singleton row.
function K9Store.Theme_Upsert(primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, updatedBy)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_tablet_theme (id, primary_color, accent_color, background_color, text_color, density, header_title, updated_by) ' ..
            'VALUES (1, ?, ?, ?, ?, ?, ?, ?) ' ..
            'ON DUPLICATE KEY UPDATE primary_color = VALUES(primary_color), accent_color = VALUES(accent_color), ' ..
            'background_color = VALUES(background_color), text_color = VALUES(text_color), density = VALUES(density), ' ..
            'header_title = VALUES(header_title), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, updatedBy })
        if not ok then
            print(('[qbx_k9unit] datastore: Theme_Upsert write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ThemeRow = {
        primary_color = primaryColor, accent_color = accentColor, background_color = backgroundColor,
        text_color = textColor, density = density, header_title = headerTitle,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
    }
    return true
end

--- Mirrors the SafeWrite contract.
function K9Store.ThemeAudit_Append(primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, changedBy)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_tablet_theme_audit (primary_color, accent_color, background_color, text_color, density, header_title, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, changedBy })
        if not ok then
            print(('[qbx_k9unit] datastore: ThemeAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ThemeAuditRows[#ThemeAuditRows + 1] = {
        primary_color = primaryColor, accent_color = accentColor, background_color = backgroundColor,
        text_color = textColor, density = density, header_title = headerTitle,
        changed_by = changedBy, changed_at = FormatDateTime(NowUnix()),
    }
    while #ThemeAuditRows > THEME_AUDIT_MEMORY_CAP do
        table.remove(ThemeAuditRows, 1)
    end
    return true
end

-- ======================================================================
-- k9_ped_assignments
--
-- Mirrored from server/appearance.lua (GetAppearanceRow,
-- WriteAppearanceApplied, WriteAppearanceReverted, and the
-- original_model_hash backfill UPDATE). PRIMARY KEY is `citizenid` alone
-- on the real schema (current-state bookkeeping, not an audit log, per
-- sql/migrations/0008's own header) -- the memory mirror is a plain
-- citizenid-keyed map for the same reason.
-- ======================================================================
local AssignmentRows = {} -- citizenid -> { model, original_model_hash, active }

--- Mirrors GetAppearanceRow's own contract (single row or nil, already
--- pcall-wrapped internally on the DB side).
function K9Store.Appearance_GetRow(citizenid)
    if DatabaseEnabled() then
        local ok, rows = pcall(MySQL.query.await, 'SELECT model, original_model_hash, active FROM k9_ped_assignments WHERE citizenid = ? LIMIT 1', { citizenid })
        if not ok then
            print(('[qbx_k9unit] datastore: Appearance_GetRow query failed for %s: %s'):format(citizenid, tostring(rows)))
            return nil
        end
        return rows and rows[1] or nil
    end
    local row = AssignmentRows[citizenid]
    if not row then return nil end
    return { model = row.model, original_model_hash = row.original_model_hash, active = row.active }
end

--- Mirrors WriteAppearanceApplied's own boolean contract, INCLUDING its
--- exact "preserve the existing original_model_hash if the current row is
--- still active" COALESCE semantics -- the real SQL's
--- `COALESCE(VALUES(original_model_hash), original_model_hash)` is
--- reproduced here verbatim so this still behaves correctly even if a
--- caller migrated to this function without also carrying over
--- appearance.lua's own pre-read `keepOriginal` computation.
function K9Store.Appearance_UpsertApplied(citizenid, model, originalHash, appliedByLabel)
    if DatabaseEnabled() then
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
        ]], { citizenid, model, originalHash, appliedByLabel })
        if not ok then
            print(('[qbx_k9unit] datastore: Appearance_UpsertApplied write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local existing = AssignmentRows[citizenid]
    local coalescedHash = originalHash
    if coalescedHash == nil and existing then coalescedHash = existing.original_model_hash end
    AssignmentRows[citizenid] = {
        model = model, original_model_hash = coalescedHash, active = 1,
        applied_by = appliedByLabel, applied_at_unix = NowUnix(), revoked_at = nil,
    }
    return true
end

--- Mirrors WriteAppearanceReverted's own boolean contract.
function K9Store.Appearance_MarkReverted(citizenid)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await, 'UPDATE k9_ped_assignments SET active = 0, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND active = 1', { citizenid })
        if not ok then
            print(('[qbx_k9unit] datastore: Appearance_MarkReverted write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local row = AssignmentRows[citizenid]
    if row and row.active == 1 then
        row.active = 0
        row.revoked_at = FormatDateTime(NowUnix())
    end
    return true
end

--- Mirrors the conditional backfill UPDATE
--- (`WHERE citizenid = ? AND active = 1 AND original_model_hash IS NULL`)
--- used when a persisted, offline-created assignment never had its first
--- swap attempt's original hash captured.
function K9Store.Appearance_SetOriginalHashIfMissing(citizenid, hash)
    if DatabaseEnabled() then
        local ok, err = pcall(MySQL.query.await, 'UPDATE k9_ped_assignments SET original_model_hash = ? WHERE citizenid = ? AND active = 1 AND original_model_hash IS NULL', { hash, citizenid })
        if not ok then
            print(('[qbx_k9unit] datastore: Appearance_SetOriginalHashIfMissing write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local row = AssignmentRows[citizenid]
    if row and row.active == 1 and row.original_model_hash == nil then
        row.original_model_hash = hash
    end
    return true
end

-- ======================================================================
-- BOOT LINE -- one console line stating which backend is live, so an
-- operator (or QA) can confirm Config.Database.enabled took effect
-- without reading code.
-- ======================================================================
if DatabaseEnabled() then
    print('[qbx_k9unit] datastore: Config.Database.enabled -- persisting to MySQL/MariaDB. This is the recommended way to run this resource.')
else
    print('[qbx_k9unit] datastore: Config.Database.enabled = false -- running IN MEMORY ONLY. Every certification, XP total, partnership, permission grant, runtime override and tablet theme change will be forgotten on the next restart, and no audit trail is being written. See config.lua\'s Config.Database comment for the full, plain-language explanation.')
end
