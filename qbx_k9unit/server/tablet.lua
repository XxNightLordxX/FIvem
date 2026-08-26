--[[
    qbx_k9unit/server/tablet.lua

    Config.Features.CommandTablet. THE SERVER AGGREGATION LAYER for the K9
    Command Tablet -- html/tablet.js (coder-ui) and client/tablet.lua
    (coder-frontend) are both complete and shipped; this file is what
    unblocks them by implementing the server side of their already-agreed
    NUI contract (see html/tablet.js's own header for the byte-exact
    payload shapes this file must match).

    ======================================================================
    ARCHITECTURE DECISION, STATED UP FRONT: this file registers FOUR of the
    six callbacks the tablet needs -- the genuinely CROSS-FILE aggregations
    that don't belong to any single owning subsystem:
      qbx_k9unit:server:tabletRequestMyRecord
      qbx_k9unit:server:tabletRequestRoster
      qbx_k9unit:server:tabletRequestPersonSummary
      qbx_k9unit:server:tabletRequestPersonFeatures
    The other two are registered INSIDE the file that already owns the
    logic they wrap, mirroring server/permissions.lua's own established
    precedent (that file's "TABLET CALLBACKS" section registers
    tabletGrantPermission/tabletRevokePermission directly alongside
    GrantPermission/RevokePermission, rather than here):
      qbx_k9unit:server:tabletCertify  -- server/certifications.lua,
        GrantCertificationForTablet (see that function's own doc comment
        for the full "offline-grant asymmetry" writeup -- the headline
        finding of this pass).
      qbx_k9unit:server:tabletGiveXp   -- server/highcommand.lua,
        GrantHighCommandXp / IsAuthorizedForXpGrant (factored out of
        '/k9givexp's own command handler so neither file duplicates the
        other's authorization/clamp/self-grant/cooldown/audit logic).
    Reasoning: a mutation that maps cleanly onto ONE file's existing
    write-path (grant/revoke/certify/givexp) belongs next to that write
    path, where its authorization checks already live and where a future
    change to that authorization is made exactly once. A READ that must
    join k9_permissions + k9_certifications + k9_progression together --
    something no single owning file can produce from its own table alone --
    belongs here. server/permissions.lua's own header names this precise
    split explicitly and defers the read side to "whichever file ends up
    owning that aggregation" -- this file is that answer.
    ======================================================================

    ======================================================================
    THE OFFLINE-GRANT ASYMMETRY (headline finding this pass) -- see
    server/certifications.lua's GrantCertificationForTablet for the full
    writeup; summarized here since it shaped this file's own design too.
    RevokeCertificationOffline already lets an officer revoke a
    disconnected citizenid's certification (DEVELOPER_REFERENCE.md §4.3 requires it).
    GrantCertification cannot get the same treatment: DEVELOPER_REFERENCE.md §4.2.5's
    model check reads a LIVE ped's model, and this resource's schema has NO
    persisted "this citizenid plays a K9 model" fact to substitute for a
    disconnected target. DECISION: no offline grant path was added.
    tabletCertify resolves the target to a currently-connected server id
    and, only if that succeeds, delegates to the EXACT SAME GrantCertification
    a live '/k9certify [server id]' would run -- one code path, the real
    model/proximity/eligibility checks intact. A disconnected target fails
    closed with 'target_must_be_online', an honest, distinguishable
    failure, never a weaker grant. tabletGiveXp is the opposite case:
    AwardXPDirect has no live-session precondition at all, so it IS fully
    offline-capable, and is built that way (citizenid-keyed, works for a
    disconnected target) -- these two "six callbacks" siblings deliberately
    resolve the identical-looking "online/offline" question in opposite
    directions, for a real, disclosed, security-driven reason each time.
    ======================================================================

    ======================================================================
    SECURITY RULE (client/tablet.lua's own words, repeated here because
    this is the file a modified client actually talks to): THE TABLET IS A
    VIEW. IT DECIDES NOTHING. Every one of the four callbacks below
    re-resolves the CALLER's own identity from `source` (ox_lib's callback
    dispatch value, server-verified, never a client-supplied one) and
    re-derives every permission/certification/XP fact from this resource's
    own server-held state (k9_permissions, k9_certifications, the
    progression cache) -- never from a client-supplied citizenid, job, or
    boolean. A `targetCitizenId` argument selects WHOSE record to read; it
    is NEVER treated as an assertion about the CALLER's own identity or
    authority. tabletRequestRoster/tabletRequestPersonSummary require the
    caller to hold real "console" access (an effective admin capability, or
    high command); tabletRequestPersonFeatures requires high command
    specifically -- both re-verified here on every call, never trusted from
    a client's own cached copy of `viewer.isHighCommand`.
    ======================================================================

    ======================================================================
    STATE RESOLUTION (myFeatures[].state / features[].state) -- config.lua's
    Config.FeatureControl documents this as a 4-step "first match wins"
    order for whether a feature is USABLE for a given person; html/tablet.js's
    own header extends it with one more step (an underlying-certification
    gate) for what the TABLET specifically should render:
      1. Config.Features.<key> is not `true`                    -> 'global_off'
      2. an explicit per-person BLOCK row ('block.<key>')       -> 'blocked'
      3. the caller/target lacks K9 access (HasK9Access)        -> 'not_certified'
      4. <key> is in RequireGrant and no 'feature.<key>' grant  -> 'requires_grant_missing'
      5. otherwise                                              -> 'available'
    Computed fresh on every call from k9_permissions rows this file reads
    itself (never cached, never trusted from a prior response) -- see
    ResolveFeatureState below. NOTE, DISCLOSED: config.lua's own base
    4-step order for Config.FeatureControl has no high-command bypass at
    step 3 ("<Name> is listed in RequireGrant -> ALLOW ONLY IF THEY HOLD A
    GRANT", no stated exception) -- unlike the SEPARATE Config.Permissions
    4-step order, which explicitly bypasses at step 2. This file follows
    that literal distinction: a high-command officer who wants to TRIGGER a
    RequireGrant-listed feature THEMSELVES still needs their own
    'feature.<key>' grant, same as anyone else. If that reading is wrong,
    it is a one-line change to ResolveFeatureState below, not a redesign.

    RESOLVED, PREVIOUSLY A REAL GAP (coder-security, follow-up pass):
    server/permissions.lua's IsValidPermissionKey originally only accepted
    an EXACT key already present in Config.Permissions (the four admin
    capabilities), with no case for the 'feature.<Name>'/'block.<Name>'
    namespace -- meaning tablet:grantFeature/revokeFeature/blockFeature/
    unblockFeature failed with 'invalid_permission' on every attempt. Now
    fixed there: IsValidPermissionKey accepts 'feature.<Name>'/'block.<Name>'
    when <Name> is validated against the real Config.Features table (never a
    free-form string). This file's OWN reads (QueryActivePermissionSet
    below) were never affected by that bug either way -- they read
    k9_permissions directly, bypassing the write-path validator, the same
    way server/permissions.lua's own ListActivePermissionsForCitizenId/
    ListPermissionRoster already do -- so 'blocked'/'requires_grant_missing'
    now reflect REAL, storable grant/block rows end to end, not merely "never
    blocked, never granted by construction" as before this fix landed. See
    the ROUND TRIP test in tests/tabletserver_spec.lua (added this pass, at
    coder-security's own request) for proof of the full path: a grant made
    through tabletGrantPermission is visible in this file's own
    ResolveFeatureState output afterward.
    ======================================================================

    ======================================================================
    ROSTER QUERY -- PERFORMANCE. A real EXPLAIN pass this session (against
    live MySQL 5.7 and 8.0 containers, seeded with 12,000 k9_certifications
    rows across 3 departments) confirmed:
      SELECT citizenid, granted_by FROM k9_certifications
      WHERE job = ? AND active = 1 LIMIT <n>
    uses `idx_job_active` as a `ref` index seek (`type: ref`, `Extra: NULL`
    -- no filesort, no temporary table) on BOTH versions. The SAME query
    with `ORDER BY granted_at DESC` added -- server/admin.lua's own existing
    dept-roster query shape -- adds `Using filesort` on the exact same seed,
    which is almost certainly the concrete instance of the "existing admin
    query filesorting 8,572 rows to return 50" finding flagged for this
    session; NOT fixed here (server/admin.lua has no owner flagged for this
    task and this file does not touch it), but independently reconfirmed
    and deliberately NOT repeated below: this file's own per-department
    fetch has NO ORDER BY at all -- any deterministic ordering the roster
    wants is applied AFTER fetch, in Lua, over the already-bounded result.
    Bounded per Config.CommandTablet.maxRosterRows (clamped -- see
    ClampedMaxRosterRows: non-positive/nil/NaN/infinite falls back to the
    default, never "unlimited", this resource's standing footgun-avoidance
    convention), fetched per CONFIGURED DEPARTMENT (a small, fixed set --
    2-4 in every shipped config) rather than as one unindexed table scan,
    with a hard multiplier-plus-absolute ceiling (ROSTER_FETCH_MULTIPLIER /
    ROSTER_FETCH_ABSOLUTE_CAP below) so a misconfigured maxRosterRows can
    never blow the query up regardless. The free-text `query` substring
    match (name/citizenid/department, case-insensitive) is applied ENTIRELY
    IN LUA over this already-bounded candidate set, not pushed into a SQL
    LIKE -- a leading-wildcard LIKE cannot use a B-tree index anyway, and a
    citizenid's NAME is not a queryable SQL column in this schema at all
    (see NAME RESOLUTION below), so there is no meaningful SQL-side filter
    to push down beyond the already-applied `job = ? AND active = 1` seek.
    ======================================================================

    ======================================================================
    NAME RESOLUTION -- DISCLOSED GAP, ORIGINALLY reported in full this pass,
    NOW ANSWERED (2026-08-25, native-api-assistant): an ONLINE citizenid's
    display name resolves via qbx_core's own PlayerData.charinfo
    (firstname/lastname), falling back to the GetPlayerName native (a
    real, VERIFIED server-callable native -- ext/native-decls/GetPlayerName.md
    returns HTTP 200, apiset: server) if charinfo is absent/malformed.

    For an OFFLINE citizenid, this question is now closed: confirmed
    directly against qbx_core's live server/player.lua that
    `exports.qbx_core:GetOfflinePlayer(citizenid)` IS a real export --
    returns a Player-shaped object (`.PlayerData`, `.Offline = true`) for a
    known citizenid, or nil if not found. `GetOfflinePlayerByCitizenId`
    does NOT exist as a separate export -- that half of the name floated in
    this file's original draft was never real; `GetOfflinePlayer` alone is
    the one and only offline accessor, already keyed by citizenid (no
    separate ByCitizenId variant needed).

    NOT YET WIRED INTO ResolveDisplayName BELOW -- that is a genuine
    behavior change (a new resource-global call, a new nil/malformed-
    PlayerData guard, a real player-visible improvement to every offline
    roster/summary row) that belongs to whoever next owns this file's
    runtime logic, not to the structural pass that closed this question.
    ResolveDisplayName still falls back to the citizenid ITSELF for an
    offline target in the meantime -- always present, never wrong, just
    less friendly than a real name; that fallback remains correct and safe
    to keep exactly as-is until the wiring lands.
    ======================================================================

    ======================================================================
    myFeatures / features KEY LIST -- DYNAMIC, NOT HARDCODED (owner's own
    mid-pass instruction, verbatim: "Do not hardcode a feature list in the
    tablet UI... render the roster from whatever Config.FeatureControl.RequireGrant
    and Config.Features actually contain at runtime, so a feature added
    after you finish appears without a UI change"). Five new feature files
    (findalert/scenttrail/sarcalls/scentlineup/pursuitsprint) plus training
    mode/equipment shop/a leaderboard are landing in parallel this same
    session, each adding its own Config.Features entry and, where relevant,
    its own Config.FeatureControl.RequireGrant entry -- a list this file
    captured once at load/write time would already be stale by the time
    this pass finishes. ListMyFeaturesKeys below therefore iterates
    `pairs(Config.Features)` FRESH on every call (Config is a shared table
    this file never copies), sorted for a stable, deterministic output
    order -- no per-file registry, no coordination needed with whichever
    agent adds the next feature. `requiresGrant` is read the same way, from
    `Config.FeatureControl.RequireGrant[key]` at resolution time. This
    necessarily includes every OTHER Config.Features flag too (HighCommand,
    CommandTablet, RuntimeFeatureControl, ...), not just K9-ability ones --
    a deliberate breadth-over-curation tradeoff per the owner's own explicit
    instruction; each row's `state` is still computed correctly and
    honestly for whatever the key actually is (an administrative flag with
    no RequireGrant entry simply always resolves 'global_off'/'available',
    which is accurate, just not necessarily a row coder-ui chooses to
    surface with a trigger button -- that display-level filtering, if
    wanted, is a UI-scope decision, not a correctness concern for this
    file's own resolution logic).
    ======================================================================

    ======================================================================
    K9 ROLE ASSIGN / DE-ASSIGN / REVERT-TO-HUMAN -- the owner's expanded,
    mid-pass ask ("assign and de-assign the K9 role... remove the K9 ped
    and revert that player to a human... I want high command to have
    pretty much absolute control"). THREE distinct actions, each mapped to
    the narrowest EXISTING (or newly-added, clearly-scoped) primitive
    rather than a new parallel mechanism:
      ASSIGN -- qbx_k9unit:server:tabletAssignK9Role (targetCitizenId,
        modelName) -> {ok, error?, message?}, registered below. Thin
        wrapper over server/appearance.lua's ApplyK9PedRole(granterSrc,
        targetCitizenid, modelName) -- ALREADY high-command-gated
        internally (it delegates to GrantPermission's own IsHighCommand
        check), ALREADY works for any Config.Peds entry (requirement:
        "everything work with any ped" -- ApplyK9PedRole validates against
        the operator's OWN Config.Peds list, which can include a custom/
        non-dog streamed model, never a hardcoded name). This file adds NO
        second authorization check and NO second appearance-mutation path
        -- see this function's own doc comment.
      DE-ASSIGN -- NO NEW CALLBACK. Mapped onto the tablet's EXISTING
        tablet:revokePermission {targetCitizenId, permission:'k9.access'}
        action (server/permissions.lua's already-registered
        tabletRevokePermission), since 'k9.access' is precisely the
        credential ApplyK9PedRole/HasK9Role treat as "holds the role."
        Revoking it already triggers server/permissions.lua's own
        RevokePermission -> MaybeRevertK9Appearance reconciliation
        automatically once the citizenid no longer qualifies through ANY
        other path (see appearance.lua's own FILE-TO-FILE CONTRACT). No
        server/tablet.lua code needed for this one at all -- reported here
        so it isn't mistaken for a gap.
      REVERT-TO-HUMAN (unconditional) -- qbx_k9unit:server:tabletRevertK9Ped
        (targetCitizenId) -> {ok, error?, message?}, registered below.
        THE NO-UNBOUNDED-TRAP REQUIREMENT, STATED EXPLICITLY BY THE OWNER:
        this action must NEVER be gated on the target still holding K9
        access, still being certified, or still passing any feature check
        -- MaybeRevertK9Appearance is therefore NOT reused here (it
        deliberately refuses to revert a citizenid who still qualifies
        through k9.access or an active certification -- correct for ITS
        OWN auto-revert-on-credential-loss call sites, wrong for a direct,
        forceful "make them human right now" tablet button). Calls a NEW
        primitive, ForceRevertK9Appearance(granterSrc, targetCitizenid),
        requested from server/appearance.lua's own owner this pass (message
        sent; not yet landed at the time this file was written) rather than
        hand-rolled here -- "coordinate with it, do not build a second
        revert path" was the owner's own explicit instruction. Guarded with
        `type(ForceRevertK9Appearance) == 'function'`, this resource's
        standard soft-dependency convention: the callback is registered
        (so the tablet gets a clear, honest 'not_available' rather than a
        hung fetch) and activates automatically the moment that function
        lands, with zero further edits to this file.
    ======================================================================

    ======================================================================
    "ANY PED" / GATE ON ROLE, NEVER MODEL -- every check in this file
    (HasK9Access for feature-state resolution, IsHighCommand/HasPermission
    for authorization) is already model-independent by construction --
    grepped this file end to end to confirm NOTHING here reads
    GetEntityModel/IsConfiguredK9Model/an entity's ped model at all. The
    live bug named for this pass (client/movement.lua:822's certify
    predicate demanding a K9 model client-side while the server-side
    GrantCertification does not) lives entirely in a file this pass does
    not own and is NOT reproduced here: tabletCertify (server/certifications.lua)
    and tabletAssignK9Role/tabletRevertK9Ped below all gate purely on
    CALLER authorization (IsHighCommand / IsEligibleCertifier) and
    TARGET identity (citizenid, online-resolution where needed) -- never on
    what the target currently looks like.
    ======================================================================

    ======================================================================
    FILE-TO-FILE CONTRACT -- reads only except the two K9-role actions below:
      HasPermission, IsHighCommand, HasK9Access, GetXP, GetXPTier -- every
      one guarded by `type(fn) == 'function'` (this resource's established
      soft-dependency convention: this file degrades to "nobody qualifies
      for anything" / "no XP data" rather than erroring if any of those
      four owning files is ever removed, exactly like every other consumer
      of these four).
      Runs its own direct, parameterized SELECTs against k9_permissions and
      k9_certifications for the read shapes no existing accessor already
      covers (a citizenid's full active-permission SET, a citizenid's
      per-department certification row, and the bounded per-department
      roster scan) -- the same "read-only aggregation reaches into another
      subsystem's own table directly" pattern server/admin.lua's own audit
      commands and server/permissions.lua's own ListActivePermissionsForCitizenId/
      ListPermissionRoster already establish for an identical need.
    ======================================================================

    LOCALE KEYS THIS FILE NEEDS (requested this pass, NOT invented inline).
    `tablet.roster_truncated_notice` has LANDED (locales/en.json, worded by
    the locale owner as "Showing the first %d entries -- narrow your search
    to see the rest.") and is wired into tabletRequestRoster's
    `truncatedMessage` below. Still outstanding, used only as an OPTIONAL
    `message` alongside an `error` code the tablet can already render
    generically without it:
      tablet.console_not_authorized = "You don't have access to the Command Console."

    FXMANIFEST.LUA PLACEMENT REQUESTED (server_scripts, not edited here):
    insert `'server/tablet.lua',` immediately after `'server/progression.lua',`
    and before `'server/combat.lua',` -- satisfies every soft load-order
    preference this file has (after cooldowns/notify/highcommand/permissions/
    certifications/progression, all five of which it may call at runtime),
    though nothing here is strictly load-order-dependent: every cross-file
    call is behind its own `type(fn) == 'function'` guard, matching this
    resource's "runtime existence guard, not a load-order assumption"
    convention.
]]

if not (Config.Features and Config.Features.CommandTablet == true) then return end

-- ======================================================================
-- CONSTANTS
-- ======================================================================

local DEFAULT_MAX_ROSTER_ROWS = 100 -- mirrors config.lua's own Config.CommandTablet.maxRosterRows default
local ROSTER_FETCH_MULTIPLIER = 5   -- headroom so the in-Lua text filter still has real candidates to search among
local ROSTER_FETCH_ABSOLUTE_CAP = 1000 -- hard ceiling per department, regardless of a misconfigured maxRosterRows
local MAX_ROSTER_QUERY_LENGTH = 100  -- defensive bound on the free-text search box, matching this resource's
                                      -- established "plain sanity/DoS-lite bound" convention (server/permissions.lua's
                                      -- own IsValidCitizenId is the same idea applied to a citizenid)
local MAX_CITIZENID_LENGTH = 50      -- VARCHAR(50), matching every citizenid column in this resource's schema

--- DYNAMIC feature key list -- see this file's header "myFeatures /
--- features KEY LIST -- DYNAMIC, NOT HARDCODED" for the full reasoning.
--- Reads `Config.Features` FRESH on every call (never cached at file-load
--- time, and never a Lua-literal list of names) so a feature landed by any
--- other agent after this file was written appears automatically, with no
--- edit here. Sorted for a stable, deterministic output order only --
--- `pairs` iteration order over a plain Lua table is not guaranteed.
--- @return table -- sorted array of Config.Features key strings
local function ListFeatureKeys()
    local keys = {}
    if type(Config.Features) == 'table' then
        for key in pairs(Config.Features) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
    end
    return keys
end

-- ======================================================================
-- SMALL, GENERAL HELPERS
-- ======================================================================

--- Fail-closed K9Store-accessor wrapper -- pcall around a K9Store.* function
--- (a failed read returns zero rows/false, never a raw Lua error out of a
--- lib.callback handler). server/datastore.lua's own K9Store.* functions
--- that mirror a RAW oxmysql method (MySQL.scalar/single/query.await) do so
--- un-pcalled in their DB-mode branch, by design (see that file's header
--- "CONTRACT DISCIPLINE") -- this file still needs "never throws" for its
--- own callback handlers regardless of which backend K9Store is running
--- against, so the pcall stays here, at every one of this file's own
--- K9Store call sites, even the ones (like Cert_GetActiveJobsForCitizen/
--- Cert_GetActiveRosterByJobUnordered below) that already never throw on
--- their own -- consistent double-wrapping over a call-site-by-call-site
--- judgment call about which K9Store functions "need" it.
--- @param fn function -- a K9Store.* accessor
--- @return any result -- rowsOrErr on success, or the caller's own documented
--- fallback (nil/false/{}) on failure -- see each call site.
local function SafeStoreCall(fn, ...)
    local ok, resultOrErr = pcall(fn, ...)
    if not ok then
        print(('[qbx_k9unit] tablet.lua K9Store call failed: %s'):format(tostring(resultOrErr)))
        return nil
    end
    return resultOrErr
end

--- DB-authoritative: does `citizenid` hold an active row in ANY configured
--- department? Used ONLY as the offline fallback inside
--- ResolveTargetHasK9Access below (an online target's access is read from
--- the real, live HasK9Access(source) instead -- this is strictly a
--- substitute for when no live source exists). Migrated onto
--- K9Store.Cert_GetActiveIdAnyJob this pass (identical SQL/index, now behind
--- the DatabaseEnabled() switch -- Config.Database.enabled = false answers
--- this from K9Store's own in-memory certification rows instead of a live
--- MySQL connection).
--- @param citizenid string
--- @return boolean
local function QueryHasAnyActiveCertification(citizenid)
    return SafeStoreCall(K9Store.Cert_GetActiveIdAnyJob, citizenid) ~= nil
end

--- Every ACTIVE k9_permissions row for `citizenid`, as a set (presence of a
--- key means "currently holds this permission string"). Covers all three
--- shapes this file needs to check (the four admin capabilities,
--- 'feature.<Name>', 'block.<Name>') in ONE query -- reads the table
--- directly rather than going through server/permissions.lua's HasPermission,
--- which is scoped to ONLINE citizenids only (see that file's own "CACHING"
--- header section) -- this file needs the SAME read to work for an offline
--- target too (tabletRequestPersonSummary/tabletRequestPersonFeatures), so a
--- direct, DB-authoritative read is correct here regardless of
--- IsValidPermissionKey's own now-fixed namespace acceptance (see this
--- file's header "RESOLVED, PREVIOUSLY A REAL GAP"). Migrated onto
--- K9Store.Perm_GetActiveForCitizen this pass (identical SQL, same row
--- shape `{ permission = ... }`) -- now works correctly under
--- Config.Database.enabled = false too.
--- @param citizenid string
--- @return table<string, boolean>
local function QueryActivePermissionSet(citizenid)
    local rows = SafeStoreCall(K9Store.Perm_GetActiveForCitizen, citizenid) or {}
    local set = {}
    for _, row in ipairs(rows) do
        set[row.permission] = true
    end
    return set
end

--- Real, current Unix time in whole seconds, or nil if unavailable --
--- mirrors server/certifications.lua's own NowUnix "fails toward
--- availability" posture (see that file's IsExpiredUnix doc comment): an
--- unreadable `os.time` must make `expired` resolve to false, never crash
--- this read entirely, since a broken clock says nothing about whether a
--- real certification has actually lapsed. Not itself a cross-file call --
--- os.time is plain Lua 5.4 stdlib, not a resource-global -- so this is a
--- small local duplicate of that file's own guard, not a new dependency.
--- @return number?
local function NowUnixOrNil()
    if type(os) == 'table' and type(os.time) == 'function' then
        return os.time()
    end
    return nil
end

--- ONE ROW PER CONFIGURED DEPARTMENT for `citizenid` -- including
--- departments they have never held (active = false, grantedBy = nil), so
--- the tablet can offer "Certify" for a brand-new department per
--- PersonSummaryResult's own documented contract. Uses idx_citizen_job_active
--- as a citizenid-prefix scan (no LIMIT needed: bounded by the number of
--- configured departments, a small fixed set -- at most one active row per
--- department per this schema's own uq_one_active_cert_per_job invariant).
--- Migrated onto K9Store.Cert_GetActiveJobsForCitizen this pass (identical
--- SQL/index, now behind the DatabaseEnabled() switch) -- see that
--- accessor's own doc comment in server/datastore.lua for why it needed to
--- be added rather than reused from an existing one.
---
--- CERTIFICATION DEPTH READ-SIDE (this pass) -- tier/expiry/specializations
--- were entirely absent from this array until now: a handler's tier and
--- specializations did not display anywhere on the tablet, not even
--- read-only, for the handler themselves or for high command looking them
--- up. For each department this citizenid ACTUALLY holds (active == true
--- only -- a department they've never held has no tier/expiry/specializations
--- to report, matching this row's own existing active=false/grantedBy=nil
--- shape for that case), this now calls server/certifications.lua's
--- DB-authoritative, already-exposed QueryCertificationRecord(citizenid,
--- jobKey) -- the SAME accessor that file's own header names as built "for
--- tablet/roster/admin reads" and already used by an OFFLINE-safe caller
--- (works for a disconnected citizenid too, exactly what
--- tabletRequestPersonSummary needs for someone who is not online right
--- now). One extra pair of queries (QueryCertificationRecord's own
--- Cert_GetActiveRecord + Spec_GetActiveKeys reads) PER DEPARTMENT THIS
--- CITIZENID ACTUALLY HOLDS -- bounded by the same small, fixed
--- Config.Departments count this function's own existing loop is already
--- bounded by (2-4 in every shipped config), not by roster size: this
--- function runs once per tabletRequestMyRecord/tabletRequestPersonSummary
--- call, never once per roster row. `expired` is computed HERE, in Lua,
--- rather than by calling into server/certifications.lua's own (local,
--- unexported) IsExpiredUnix -- see NowUnixOrNil above for why that is a
--- small, deliberate, same-logic local duplicate rather than a new
--- cross-file call. Guarded with `type(QueryCertificationRecord) ==
--- 'function'`, this resource's established soft-dependency convention --
--- degrades to no tier/expiry/specializations data (never a crash) if
--- server/certifications.lua is ever unavailable, exactly like every other
--- guarded cross-file read in this file.
--- @param citizenid string
--- @return table -- array of { departmentKey, departmentLabel, active, grantedBy, tier, expiresAtUnix, expired, specializations }
local function BuildCertificationsArray(citizenid)
    local rows = SafeStoreCall(K9Store.Cert_GetActiveJobsForCitizen, citizenid) or {}
    local grantedByJob = {}
    for _, row in ipairs(rows) do
        grantedByJob[row.job] = row.granted_by
    end

    local now = NowUnixOrNil()

    local out = {}
    if type(Config.Departments) == 'table' then
        -- Deterministic order -- `pairs` over Config.Departments has no
        -- guaranteed order, and a stable per-request shape is worth a
        -- cheap sort over a small, fixed-size table.
        local jobKeys = {}
        for jobKey in pairs(Config.Departments) do
            jobKeys[#jobKeys + 1] = jobKey
        end
        table.sort(jobKeys)

        for _, jobKey in ipairs(jobKeys) do
            local dept = Config.Departments[jobKey]
            local isActive = grantedByJob[jobKey] ~= nil

            -- Only an ACTIVE department has a tier/expiry/specializations to
            -- report at all -- see this function's own doc comment above.
            local tier, expiresAtUnix, specializations = nil, nil, {}
            if isActive and type(QueryCertificationRecord) == 'function' then
                local record = QueryCertificationRecord(citizenid, jobKey)
                if record then
                    tier = record.tier
                    expiresAtUnix = record.expiresAtUnix
                    specializations = record.specializations or {}
                end
            end

            local expired = false
            if type(expiresAtUnix) == 'number' and type(now) == 'number' and now >= expiresAtUnix then
                expired = true
            end

            out[#out + 1] = {
                departmentKey = jobKey,
                departmentLabel = (type(dept) == 'table' and type(dept.label) == 'string') and dept.label or jobKey,
                active = isActive,
                grantedBy = grantedByJob[jobKey],
                tier = tier,
                expiresAtUnix = expiresAtUnix,
                expired = expired,
                specializations = specializations,
            }
        end
    end
    return out
end

--- Best-effort display name -- see this file's header "NAME RESOLUTION"
--- for the full, disclosed gap this documents rather than guesses around.
--- @param citizenid string
--- @return string
local function ResolveDisplayName(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData then
        local charinfo = onlinePlayer.PlayerData.charinfo
        if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
            local full = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
            if type(full) == 'string' and full ~= '' then return full end
        end

        local onlineSrc = onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            local ok, viaNative = pcall(GetPlayerName, onlineSrc)
            if ok and type(viaNative) == 'string' and viaNative ~= '' then return viaNative end
        end
    end

    -- OFFLINE (or online with neither a usable charinfo nor a resolvable
    -- native name) -- fall back to the citizenid itself. Never blank,
    -- never a guess at an unverified schema.
    return citizenid
end

--- @param configured any
--- @return number
local function ClampedMaxRosterRows()
    local configuredValue = type(Config.CommandTablet) == 'table' and Config.CommandTablet.maxRosterRows
    if type(configuredValue) ~= 'number' or configuredValue ~= configuredValue
        or configuredValue <= 0 or configuredValue == math.huge then
        return DEFAULT_MAX_ROSTER_ROWS
    end
    return math.floor(configuredValue)
end

-- ======================================================================
-- AUTHORIZATION-SHAPED HELPERS -- each mirrors an existing rank-gate SHAPE
-- already established elsewhere in this resource (server/certifications.lua's
-- IsEligibleCertifier, server/admin.lua's IsAuthorizedAdmin,
-- server/permissions.lua's own MeetsDepartmentGradeOrHighCommand), rather
-- than exporting any of those `local` functions as new resource-globals
-- purely for this one read -- see server/permissions.lua's own doc comment
-- on MeetsDepartmentGradeOrHighCommand for the established reasoning this
-- follows: "a small internal duplicate of the ... comparison shape ...
-- deliberately NOT achieved by exporting ... as new resource-globals ...
-- which would have required a .luacheckrc globals entry this file cannot
-- add for itself." This file is in the identical position.
-- ======================================================================

--- Rank-only comparison (no grant, no high-command re-check -- both are
--- already checked by every call site BEFORE falling through to this).
--- Fails closed on every unresolvable shape, identical to every other rank
--- gate in this resource.
--- @param source number
--- @param gradeField string -- 'certifierGrade' | 'auditGrade'
--- @return boolean
local function MeetsDepartmentRank(source, gradeField)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or type(Config.Departments) ~= 'table' or not Config.Departments[job.name] then return false end

    if job.isboss then return true end

    local dept = Config.Departments[job.name]
    if type(dept[gradeField]) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept[gradeField]
end

--- Full 4-step resolution (config.lua's own documented order) for EVERY
--- Config.Permissions key, from `source`'s own perspective. Used for
--- viewer.effectivePermissions (MyRecordResult) and the "console access"
--- gate (roster / person summary). `activePermSet` is the CALLER's own
--- active k9_permissions rows (QueryActivePermissionSet(callerCitizenid)).
--- @param source number
--- @param activePermSet table<string, boolean>
--- @param isHighCommandCaller boolean
--- @return table -- sorted array of qualifying Config.Permissions keys
local function ResolveEffectivePermissions(source, activePermSet, isHighCommandCaller)
    local out = {}
    if type(Config.Permissions) ~= 'table' then return out end

    for key in pairs(Config.Permissions) do
        local qualifies = false
        if isHighCommandCaller or activePermSet[key] == true then
            qualifies = true
        elseif key == 'k9.access' then
            -- HasK9Access already resolves grant + high-command + cert-cache
            -- + autoAccessGrade internally -- reused whole, not re-derived.
            qualifies = type(HasK9Access) == 'function' and HasK9Access(source) == true
        elseif key == 'k9.certify' then
            qualifies = MeetsDepartmentRank(source, 'certifierGrade')
        elseif key == 'k9.audit' then
            qualifies = MeetsDepartmentRank(source, 'auditGrade')
        end
        -- 'k9.givexp' has no legacy tier below high command/grant (both
        -- already checked above) -- no further branch needed.
        if qualifies then out[#out + 1] = key end
    end

    table.sort(out)
    return out
end

--- "Console audience" gate for tabletRequestRoster / tabletRequestPersonSummary
--- -- per html/tablet.js's own contract: "a caller with at least one of
--- effectivePermissions non-empty, or isHighCommand." Re-verified here on
--- every call, from `source`'s own live job -- never trusts a client's
--- cached copy of viewer.isHighCommand/effectivePermissions.
--- @param source number
--- @param callerCitizenid string
--- @param isHighCommandCaller boolean
--- @return boolean
local function CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller)
    if isHighCommandCaller then return true end

    -- OWNER'S DECISION, 2026-08-25: NARROWED to high command, or an explicit
    -- 'k9.audit' grant. This used to admit any caller with ANY non-empty
    -- effective permission, and 'k9.access' resolves true for every ordinary
    -- certified handler -- so a base-rank officer could look up any citizen
    -- id and read that person's certification history, their XP, and, worst,
    -- WHICH PEOPLE HOLD 'k9.certify'/'k9.audit'/'k9.givexp'. Read-only, so
    -- never an escalation, but it let rank-and-file enumerate who the
    -- powerful people in the department were.
    --
    -- 'k9.audit' is kept alongside high command deliberately, and this is
    -- not a loophole in "restrict it to high command": that capability is
    -- granted BY high command, to one named person, for exactly this
    -- purpose. Dropping it would leave the permission defined, grantable,
    -- documented -- and inert, which is its own bug class. What is closed is
    -- the 'k9.access' path, which was never a decision anyone made; it was a
    -- side effect of asking "do they have ANY permission at all".
    --
    -- Not affected: tabletRequestMyRecord. Every handler can still see their
    -- OWN record, which is a different question from looking up someone else.
    local activePermSet = QueryActivePermissionSet(callerCitizenid)
    for _, key in ipairs(ResolveEffectivePermissions(source, activePermSet, false)) do
        if key == 'k9.audit' then return true end
    end
    return false
end

--- Does `citizenid` currently have K9 access, for a target that may be
--- ONLINE (reuses the real HasK9Access(source), fully accurate) or OFFLINE
--- (no live source exists -- falls back to the two PERSISTENT sources of
--- access: an explicit 'k9.access' grant, or an active certification row
--- in ANY department). The offline fallback deliberately does NOT attempt
--- to reconstruct autoAccessGrade/high-command bypass eligibility -- both
--- are inherently properties of a LIVE job, which a disconnected citizenid
--- does not have one of right now; this mirrors how every other part of
--- this resource treats an offline citizenid's rank-dependent state as
--- simply unknowable, never guessed.
--- @param citizenid string
--- @param activePermSet table<string, boolean>
--- @return boolean
local function ResolveTargetHasK9Access(citizenid, activePermSet)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    if onlineSrc then
        return type(HasK9Access) == 'function' and HasK9Access(onlineSrc) == true
    end
    if activePermSet['k9.access'] == true then return true end
    return QueryHasAnyActiveCertification(citizenid)
end

-- ======================================================================
-- BLOCK ENFORCEMENT CLASSIFICATION -- html/tablet.js's PersonFeaturesResult
-- doc comment (its own `blockEnforcement?` field, immediately above
-- featureBlockEnforcement()) is the canonical four-state contract this
-- section implements: THE TABLET MUST NEVER TELL AN OPERATOR A BLOCK DOES
-- MORE, OR LESS, THAN IT ACTUALLY DOES. Every key below was placed by
-- directly reading the feature-owning file's own per-person gate (or
-- confirming, by grep, that none exists) -- never guessed from the
-- feature's name. See each table's own comment for the exact evidence.
-- ======================================================================

--- The twelve features client/featureblocks.lua's own header names as
--- purely client-rendered/client-local, with NO server-side registration
--- point a `block.<Name>` check could ever be wired into (that file's own
--- header: confirmed by a grep across every server/*.lua file before it
--- was written, not assumed from the name). Kept BYTE-FOR-BYTE identical
--- to that file's own CLIENT_ENFORCED_FEATURES set -- if either table is
--- ever edited, update the other in the same pass.
---
--- These twelve DO now have a real, working per-person block --
--- client/featureblocks.lua's IsK9FeatureBlocked(), fed by a server push
--- -- but it is enforced BY THE PLAYER'S OWN CLIENT, which is a strictly
--- WEAKER guarantee than every other entry in this file's `features`
--- array: a modified client can always choose to skip its own check,
--- exactly as it could already fake this resource's model/access checks
--- (IsOwnModelK9/CanShowK9UI). Calling this 'enforced' would falsely claim
--- server-side parity; calling it 'not_enforceable' would falsely claim
--- the block does nothing. 'client_enforced' is the honest third answer --
--- see locales/en.json's tablet.block_client_enforced_badge/_hint for the
--- operator-facing "best-effort, not a guarantee" wording.
local CLIENT_ENFORCED_FEATURES = {
    RadialMenu = true,
    VehicleEntryExit = true,
    AgilityBasicJump = true,
    AgilityAdvanced = true,
    ThermalVision = true,
    NightVision = true,
    HealthStaminaHUD = true,
    ContrabandScreenFX = true,
    AdvancedBarkRadial = true,
    ProximityAudioFX = true,
    WaterTrackingDecay = true,
    CameraFeedPiP = true,
}

--- Every OTHER Config.Features key confirmed, by direct code read this
--- pass (a grep for `block.<Name>` -- literal and the dynamic
--- `'block.' .. featureName` shape several files share -- across every
--- server/*.lua file), to have NO server-side point that would EVER
--- consult `block.<Name>`, for a reason that is NOT "nobody has wired it
--- in yet" (that case is the safe 'not_yet_enforced' fallback this
--- function deliberately does not return for these):
---
---   RECALL -- see server/recall.lua's own header "NO UNBOUNDED TRAP":
---   THIS IS A DELIBERATE, LOAD-BEARING DESIGN DECISION, NOT A GAP. DO NOT
---   "FIX" THIS BY WIRING A block.Recall CHECK INTO server/recall.lua.
---   Recall is this resource's escape hatch for every non-consensual
---   engagement (bite-and-hold, takedown, drag) -- the path that lets a
---   handler call their K9 off even if their OWN certification, or their
---   K9's, was just revoked mid-bite. Gating it on block.Recall would let
---   a single block row strand someone in an active engagement with no
---   way out -- reopening the exact "termination path silently gated
---   behind the same check that gates initiating the thing being escaped"
---   bug class this resource has already shipped and fixed once.
---   server/recall.lua's event handler applies exactly three gates
---   (Config.Features.Recall itself, a per-caller rate limit, and "is the
---   caller genuinely this K9's established partner") and NEVER
---   HasPermission/block.Recall, on either party, by design. Grouped here
---   by RESULT ('not_enforceable', same as the entries below) -- never by
---   REASON, which is entirely different from theirs; this comment exists
---   specifically so nobody reading only this table mistakes Recall for
---   an ordinary unimplemented case.
---
---   K9EQUIPMENTSHOP -- REMOVED FROM THIS TABLE, this pass. A PRIOR
---   version of this comment (and of server/equipmentshop.lua's own
---   header) concluded K9EquipmentShop was structurally exempt, reasoning
---   that the buy/sell transaction never reaches this resource's own
---   code. That reasoning was WRONG, not merely superseded: re-reading
---   ox_inventory's own real source found it fires a genuine, per-attempt,
---   server-side `registerHook('openShop', ...)` / `registerHook('buyItem',
---   ...)` pair this resource's own K9Compat inventory adapter can already
---   register against (a fully generic `RegisterHook` pass-through,
---   shared/compat/inventory.lua). server/equipmentshop.lua now registers
---   both -- IsEquipmentShopPermittedForCitizenId there implements the
---   SAME four-step Config.FeatureControl resolution every other
---   blockable feature uses, and a genuine `HasPermission(citizenid,
---   'block.K9EquipmentShop')` call site now exists (see that file's own
---   "PER-PERSON FEATURE CONTROL" sections for the full writeup). This key
---   therefore now falls through to the ordinary 'enforced' classification
---   below, exactly like any other server-gated ability.
---
---   RESOURCEAUTODETECT / HIGHCOMMAND / PERMISSIONGRANTS / COMMANDTABLET /
---   CERTIFICATIONEXPIRY / RUNTIMEFEATURECONTROL / TABLETTHEMING -- these
---   are administrative/infrastructure switches, not a K9 ability any
---   single citizenid "does" -- grepped end to end this pass for
---   `block.<Name>` (literal and dynamic) across every server/*.lua file:
---   zero matches for any of these seven keys, in sharp contrast to
---   ordinary abilities like BasicBarkSounds/LeashMechanics/etc. (which
---   ARE something a person does, and DO have their own `block.<Name>`
---   check -- see their omission from this table). config.lua's own
---   Config.FeatureControl per-person-block contract ("high command can
---   turn an individual feature on or off for ONE specific K9 or
---   handler") only makes sense for a feature that is something a
---   specific person does; these seven structurally are not that.
---
--- DISCLOSED: server/permissions.lua's IsValidPermissionKey still lets a
--- high-command operator WRITE a `block.<Name>` row for any of these eight
--- keys (it validates only `Config.Features[Name] ~= nil`, never whether
--- anything actually reads that row) -- this table exists specifically so
--- the tablet tells that operator, honestly, that doing so would have no
--- effect at all, rather than implying either that it works ('enforced')
--- or that it merely hasn't been wired up yet ('not_yet_enforced').
local NOT_ENFORCEABLE_FEATURES = {
    Recall = true,
    ResourceAutoDetect = true,
    HighCommand = true,
    PermissionGrants = true,
    CommandTablet = true,
    CertificationExpiry = true,
    RuntimeFeatureControl = true,
    TabletTheming = true,
}

--- @param key string -- a Config.Features key
--- @return string -- 'client_enforced' | 'not_enforceable' | 'enforced'
--- NEVER returns 'not_yet_enforced' -- that value exists purely as
--- html/tablet.js's own client-side fallback for a `blockEnforcement`
--- field this function did not send at all (an older server build, or a
--- key this function has genuinely never heard of -- structurally
--- impossible today, since ListFeatureKeys() and this function iterate
--- the exact same, real-time Config.Features table). Every key this
--- function DOES resolve for lands in EXACTLY one of the two explicit
--- tables above, by a direct, disclosed code read; 'enforced' is the
--- DEFAULT for every remaining key precisely because every ordinary
--- K9-ability feature file in this resource follows the same "PER-PERSON
--- FEATURE CONTROL" convention (HasPermission(citizenid, 'block.' .. key)
--- checked, static or via a shared `featureName`/`featureKey` parameter,
--- before the ability's own effect runs) -- confirmed, not assumed, for
--- every key currently in Config.Features (see this pass's own report for
--- the full per-key evidence list: server/main.lua, server/search.lua,
--- server/tracking.lua, server/wellbeing.lua, server/combat.lua and
--- eighteen further single-feature files each their own `block.<Name>`
--- check). A FUTURE feature added to Config.Features without being placed
--- in either table above will default to 'enforced' here -- whoever adds
--- it is expected to add it to one of the two tables above in the SAME
--- pass it lands its own `block.<Name>` check (or its own reason not to),
--- mirroring this file's existing Config.CommandTablet.ActionableFeatures
--- convention for exactly this "a small, explicit, code-owner-maintained
--- registry, never silently stale" reason.
local function ResolveBlockEnforcement(key)
    if NOT_ENFORCEABLE_FEATURES[key] == true then return 'not_enforceable' end
    if CLIENT_ENFORCED_FEATURES[key] == true then return 'client_enforced' end
    return 'enforced'
end

-- ======================================================================
-- FEATURE STATE RESOLUTION -- see this file's header "STATE RESOLUTION".
-- ======================================================================

--- @param key string -- a Config.Features key
--- @param hasK9Access boolean -- already resolved for the relevant person (caller or target)
--- @param activePermSet table<string, boolean> -- that SAME person's active k9_permissions rows
--- @return string -- 'global_off' | 'blocked' | 'not_certified' | 'requires_grant_missing' | 'available'
local function ResolveFeatureState(key, hasK9Access, activePermSet)
    if not (Config.Features and Config.Features[key] == true) then return 'global_off' end
    if activePermSet['block.' .. key] == true then return 'blocked' end
    if not hasK9Access then return 'not_certified' end

    local requireGrant = type(Config.FeatureControl) == 'table' and type(Config.FeatureControl.RequireGrant) == 'table'
        and Config.FeatureControl.RequireGrant[key] == true
    if requireGrant and activePermSet['feature.' .. key] ~= true then return 'requires_grant_missing' end

    return 'available'
end

--- Is `key` known to have a client/tablet.lua single-button trigger?
--- DATA-DRIVEN, not hardcoded here -- see this file's header "myFeatures /
--- features KEY LIST -- DYNAMIC, NOT HARDCODED": reads the OPTIONAL,
--- REQUESTED `Config.CommandTablet.ActionableFeatures` allowlist (same
--- shape/spirit as the already-established Config.FeatureControl.RequireGrant
--- -- a small, explicit, config-owned table any agent adding a new
--- triggerable feature extends alongside its own client/tablet.lua wiring,
--- never a list this file would need editing to keep in sync). Defaults to
--- `false` when that table does not exist yet (requested, not yet landed
--- as of this pass) -- the safe default is "no trigger shown" (a missing
--- button), never a phantom one that would click and do nothing.
--- @param key string
--- @return boolean
local function IsKnownActionableFeature(key)
    return type(Config.CommandTablet) == 'table'
        and type(Config.CommandTablet.ActionableFeatures) == 'table'
        and Config.CommandTablet.ActionableFeatures[key] == true
end

--- MyRecordResult's own `myFeatures` shape.
--- @param hasK9Access boolean
--- @param activePermSet table<string, boolean>
--- @return table
local function BuildMyFeaturesArray(hasK9Access, activePermSet)
    local out = {}
    for i, key in ipairs(ListFeatureKeys()) do
        out[i] = {
            key = key,
            label = nil,     -- html/tablet.js's own DEFAULT_STRINGS humanizes an absent label client-side
            category = nil,
            actionable = IsKnownActionableFeature(key),
            state = ResolveFeatureState(key, hasK9Access, activePermSet),
        }
    end
    return out
end

--- PersonFeaturesResult's own `features` shape -- HIGH COMMAND ONLY, richer
--- per-row detail than myFeatures (globallyEnabled/requiresGrant/granted/
--- blocked, alongside the same resolved `state`).
--- @param hasK9Access boolean
--- @param activePermSet table<string, boolean>
--- @return table
local function BuildPersonFeaturesArray(hasK9Access, activePermSet)
    local requireGrantTable = (type(Config.FeatureControl) == 'table' and type(Config.FeatureControl.RequireGrant) == 'table')
        and Config.FeatureControl.RequireGrant or {}

    local out = {}
    for i, key in ipairs(ListFeatureKeys()) do
        out[i] = {
            key = key,
            label = nil,
            category = nil,
            globallyEnabled = Config.Features and Config.Features[key] == true or false,
            requiresGrant = requireGrantTable[key] == true,
            granted = activePermSet['feature.' .. key] == true,
            blocked = activePermSet['block.' .. key] == true,
            state = ResolveFeatureState(key, hasK9Access, activePermSet),
            blockEnforcement = ResolveBlockEnforcement(key), -- see this file's own "BLOCK ENFORCEMENT CLASSIFICATION" section above
        }
    end
    return out
end

--- Shared XP/tier read -- nil/nil when XPProgression is off, matching
--- MyRecordResult/PersonSummaryResult's own documented `xp: number|null`
--- contract. GetXP/GetXPTier are guarded by `type(fn) == 'function'`
--- (this resource's soft-dependency convention) even though
--- server/progression.lua always defines both once loaded -- see that
--- file's own header for why the guard is kept regardless of load order.
--- @param citizenid string
--- @return number? xp
--- @return string? tierLabel
local function ResolveXpAndTierLabel(citizenid)
    if not (Config.Features and Config.Features.XPProgression == true) then
        return nil, nil
    end

    local xp = type(GetXP) == 'function' and GetXP(citizenid) or nil
    local tierLabel = nil
    if type(GetXPTier) == 'function' then
        local tier = GetXPTier(citizenid)
        tierLabel = type(tier) == 'table' and type(tier.label) == 'string' and tier.label or nil
    end
    return xp, tierLabel
end

-- ======================================================================
-- CALLBACK 1 -- tabletRequestMyRecord. Every certified handler/K9 gets
-- this, not just high command (Config.FeatureControl.everyoneCanViewOwnRecord).
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestMyRecord', function(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true

    -- config.lua's own words: "Turning this off leaves the tablet as a
    -- high-command-only tool" -- a non-high-command caller is denied
    -- outright when the flag is off; high command is unaffected (they
    -- already have the console view regardless).
    if not isHighCommandCaller then
        local everyoneCanView = type(Config.FeatureControl) == 'table' and Config.FeatureControl.everyoneCanViewOwnRecord == true
        if not everyoneCanView then
            return { ok = false, error = 'not_authorized' }
        end
    end

    local activePermSet = QueryActivePermissionSet(citizenid)
    local effectivePermissions = ResolveEffectivePermissions(source, activePermSet, isHighCommandCaller)
    local xp, tierLabel = ResolveXpAndTierLabel(citizenid)
    local hasK9Access = type(HasK9Access) == 'function' and HasK9Access(source) == true

    return {
        ok = true,
        viewer = {
            citizenid = citizenid,
            name = ResolveDisplayName(citizenid),
            isHighCommand = isHighCommandCaller,
            effectivePermissions = effectivePermissions,
            allowSelfGrant = type(Config.HighCommand) == 'table' and Config.HighCommand.allowSelfGrant == true,
        },
        certifications = BuildCertificationsArray(citizenid),
        xp = xp,
        tierLabel = tierLabel,
        myFeatures = BuildMyFeaturesArray(hasK9Access, activePermSet),
    }
end)

-- ======================================================================
-- CALLBACK 2 -- tabletRequestRoster. Console audience only. See this
-- file's header "ROSTER QUERY -- PERFORMANCE" for the full bound/index
-- writeup.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestRoster', function(source, query)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller) then
        -- 'tablet.console_not_authorized' has now landed in locales/en.json,
        -- so `message` is populated as this file's header always intended.
        -- It stays optional per the JS contract: its absence would still be
        -- a clean fallback, never a broken path.
        return { ok = false, error = 'not_authorized', message = locale('tablet.console_not_authorized') }
    end

    if type(query) ~= 'string' then query = '' end
    if #query > MAX_ROSTER_QUERY_LENGTH then query = query:sub(1, MAX_ROSTER_QUERY_LENGTH) end
    local needle = query:lower()

    local maxRows = ClampedMaxRosterRows()
    local fetchCapPerDept = math.min(maxRows * ROSTER_FETCH_MULTIPLIER, ROSTER_FETCH_ABSOLUTE_CAP)

    -- BOUNDED, INDEXED fetch -- one query PER CONFIGURED DEPARTMENT (a
    -- small, fixed set), each an idx_job_active index seek with a hard,
    -- server-produced integer LIMIT (never a client-influenced one). NO
    -- ORDER BY -- see this file's header for the filesort this
    -- deliberately avoids repeating. Migrated onto
    -- K9Store.Cert_GetActiveRosterByJobUnordered this pass -- a NEW
    -- accessor added specifically for this call site: the existing
    -- K9Store.Cert_GetActiveRosterByJob (server/datastore.lua) mirrors
    -- server/admin.lua's ORDERED shape (`ORDER BY granted_at DESC`), and
    -- swapping onto it would silently reintroduce the exact filesort this
    -- loop exists to avoid -- see that new accessor's own doc comment for
    -- the full reasoning. The LIMIT integer itself is still an
    -- already-clamped, server-computed Lua integer embedded via
    -- string.format inside that accessor's own DB-mode branch, never a
    -- client-influenced value.
    local candidates = {}
    local hitFetchCap = false
    if type(Config.Departments) == 'table' then
        for jobKey, dept in pairs(Config.Departments) do
            local rows = SafeStoreCall(K9Store.Cert_GetActiveRosterByJobUnordered, jobKey, fetchCapPerDept) or {}
            if #rows >= fetchCapPerDept then hitFetchCap = true end
            local departmentLabel = (type(dept) == 'table' and type(dept.label) == 'string') and dept.label or jobKey
            for _, row in ipairs(rows) do
                candidates[#candidates + 1] = {
                    citizenid = row.citizenid,
                    departmentLabel = departmentLabel,
                    grantedBy = row.granted_by,
                }
            end
        end
    end

    -- Resolve name/xp/tier and apply the free-text filter over the
    -- already-bounded candidate set -- all in-memory reads from here
    -- (ResolveDisplayName/GetXP/GetXPTier), no further DB round trips.
    local filtered = {}
    for _, candidate in ipairs(candidates) do
        local name = ResolveDisplayName(candidate.citizenid)
        local matches = needle == ''
            or candidate.citizenid:lower():find(needle, 1, true) ~= nil
            or name:lower():find(needle, 1, true) ~= nil
            or candidate.departmentLabel:lower():find(needle, 1, true) ~= nil
        if matches then
            local xp, tierLabel = ResolveXpAndTierLabel(candidate.citizenid)
            filtered[#filtered + 1] = {
                citizenid = candidate.citizenid,
                name = name,
                departmentLabel = candidate.departmentLabel,
                certified = true,
                xp = xp,
                tierLabel = tierLabel,
            }
        end
    end

    table.sort(filtered, function(a, b) return a.citizenid < b.citizenid end)

    local truncated = hitFetchCap
    local rows = filtered
    if #filtered > maxRows then
        truncated = true
        rows = {}
        for i = 1, maxRows do rows[i] = filtered[i] end
    end

    -- 'tablet.roster_truncated_notice' has now landed in locales/en.json, so
    -- this sets `truncatedMessage` as this file's own header always intended.
    -- html/tablet.js's contract documents it as optional and PREFERRED over a
    -- client-built count text when present; its absence with `truncated = true`
    -- remains a safe fallback, so nothing breaks if the key is ever removed.
    local result = { ok = true, rows = rows, truncated = truncated }
    if truncated then
        result.truncatedMessage = locale('tablet.roster_truncated_notice', #rows)
    end
    return result
end)

-- ======================================================================
-- CALLBACK 3 -- tabletRequestPersonSummary. Console audience only. Works
-- for ANY citizenid, online or offline (every read below is DB-authoritative,
-- never the online-only in-memory caches other files keep).
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestPersonSummary', function(source, targetCitizenId)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller) then
        -- 'tablet.console_not_authorized' has now landed in locales/en.json,
        -- so `message` is populated as this file's header always intended.
        -- It stays optional per the JS contract: its absence would still be
        -- a clean fallback, never a broken path.
        return { ok = false, error = 'not_authorized', message = locale('tablet.console_not_authorized') }
    end

    local activePermSet = QueryActivePermissionSet(targetCitizenId)
    local xp, tierLabel = ResolveXpAndTierLabel(targetCitizenId)

    local permissions = {}
    if type(Config.Permissions) == 'table' then
        for key in pairs(Config.Permissions) do
            if activePermSet[key] == true then permissions[#permissions + 1] = key end
        end
        table.sort(permissions)
    end

    return {
        ok = true,
        target = { citizenid = targetCitizenId, name = ResolveDisplayName(targetCitizenId) },
        certifications = BuildCertificationsArray(targetCitizenId),
        xp = xp,
        tierLabel = tierLabel,
        permissions = permissions,
    }
end)

-- ======================================================================
-- CALLBACK 4 -- tabletRequestPersonFeatures. HIGH COMMAND ONLY -- re-
-- verified here regardless of what a client believes viewer.isHighCommand
-- to be.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestPersonFeatures', function(source, targetCitizenId)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end

    local activePermSet = QueryActivePermissionSet(targetCitizenId)
    local hasK9Access = ResolveTargetHasK9Access(targetCitizenId, activePermSet)

    return {
        ok = true,
        target = { citizenid = targetCitizenId, name = ResolveDisplayName(targetCitizenId) },
        features = BuildPersonFeaturesArray(hasK9Access, activePermSet),
    }
end)

-- ======================================================================
-- CALLBACK 5 (owner's mid-pass expansion) -- tabletAssignK9Role. Thin
-- wrapper over server/appearance.lua's ApplyK9PedRole -- see this file's
-- header "K9 ROLE ASSIGN / DE-ASSIGN / REVERT-TO-HUMAN" for the full
-- mapping. ApplyK9PedRole already re-verifies IsHighCommand internally
-- (via GrantPermission) and already accepts ANY Config.Peds entry -- this
-- wrapper adds no authorization logic and no appearance-mutation logic of
-- its own, only the return-shape translation client/tablet.lua's
-- AwaitServerCallback expects. Guarded with `type(fn) == 'function'` --
-- server/appearance.lua may not be present on every install (its own
-- feature surface is separate from CommandTablet's), so this degrades to
-- a clear 'not_available' rather than an uncaught error if it is ever
-- removed.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletAssignK9Role', function(source, targetCitizenId, modelName)
    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH
        or type(modelName) ~= 'string' or modelName == '' then
        return { ok = false, error = 'invalid_args' }
    end

    if type(ApplyK9PedRole) ~= 'function' then
        return { ok = false, error = 'not_available' }
    end

    local ok, outcome = ApplyK9PedRole(source, targetCitizenId, modelName)
    if ok then
        if outcome == 'persisted_offline' then
            return { ok = true, message = locale('appearance.apply_pending_offline') }
        end
        return { ok = true }
    end
    return { ok = false, error = outcome }
end)

-- ======================================================================
-- CALLBACK 6 (owner's mid-pass expansion) -- tabletRevertK9Ped. See this
-- file's header "K9 ROLE ASSIGN / DE-ASSIGN / REVERT-TO-HUMAN" for the
-- full "no unbounded trap" writeup: this is a TERMINATION path and must
-- NEVER be gated on the target still holding K9 access/certification --
-- the only gate here is the CALLER's own authorization (high command),
-- re-verified from `source` on every call, never a client-supplied flag.
-- ForceRevertK9Appearance is requested from server/appearance.lua's owner
-- this pass (not yet landed as of this file being written) -- guarded with
-- `type(fn) == 'function'` so this callback is registered (a real,
-- honest 'not_available' response) rather than absent entirely, and
-- activates automatically the moment that function ships, with zero
-- further edits needed here.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRevertK9Ped', function(source, targetCitizenId)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end

    if type(ForceRevertK9Appearance) ~= 'function' then
        return { ok = false, error = 'not_available' }
    end

    local ok, outcome = ForceRevertK9Appearance(source, targetCitizenId)
    if ok then return { ok = true } end
    return { ok = false, error = outcome }
end)
