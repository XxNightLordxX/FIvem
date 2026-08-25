--[[
    qbx_k9unit/server/permissions.lua

    Config.Features.PermissionGrants / Config.Permissions. The grantable-
    permissions layer the project owner asked for: PD high command grants a
    NAMED capability (a Config.Permissions key -- 'k9.access', 'k9.certify',
    'k9.audit', 'k9.givexp') to one specific citizenid -- a handler OR a K9,
    since both are just citizenids to this resource -- and can revoke it
    later. See config.lua's own Config.Permissions block for the capability
    catalog and for the resolution order this file implements exactly.

    ======================================================================
    RESOLUTION ORDER (config.lua's own words, copied here so this file's
    behavior and its own documentation of that behavior cannot drift apart).
    FIRST MATCH WINS:
      1. an active, explicitly granted permission for that citizenid  -> ALLOW
      2. the caller is high command (server/highcommand.lua's IsHighCommand) -> ALLOW
      3. the caller meets the legacy rank gate (certifierGrade/auditGrade/etc.) -> ALLOW
      4. otherwise                                                     -> DENY
    PURELY ADDITIVE. Nothing gated on rank today may stop working -- a grant
    only ever WIDENS access, never narrows it.

    HOW STEP 1 IS WIRED IN, PER CAPABILITY (this task's own "prefer adding a
    permission check alongside the existing one over rewriting it"): each
    consuming gate already implements steps 2+3 itself (server/certifications.lua's
    HasK9Access/IsEligibleCertifier, server/admin.lua's IsAuthorizedAdmin, and
    server/highcommand.lua's '/k9givexp' handler). This file's OWN job is
    step 1 alone -- HasPermission(citizenid, key) below -- inserted at each of
    those four call sites, guarded by `type(HasPermission) == 'function'`
    (this resource's established soft-dependency convention), BEFORE their
    existing high-command/rank checks so step 1 is genuinely evaluated first,
    even though for a plain boolean OR the evaluation order does not change
    the final answer -- it is kept in this order anyway so the documented
    "first match wins" story matches the code's own physical layout, not just
    its truth table. Three of those four edits are in THIS pass (certifications.lua
    x2, admin.lua x1, both files explicitly UNOWNED for this task); the
    fourth (highcommand.lua's '/k9givexp') is REPORTED, not edited, because
    that file has a live owner this pass -- see this file's own hand-off
    report for the exact snippet.

    ======================================================================
    THE "REVOKED BUT STILL HAS IT BY RANK" CASE -- the single most likely
    place this feature could mislead an officer, and the reason
    RevokePermission below never just returns a bare boolean. Revoking a
    grant from a citizenid who ALSO independently qualifies via high command
    or the legacy rank gate for that SAME capability does NOT remove their
    access -- step 3 (or step 2) still allows them. RevokePermission's own
    reconciliation, once the revoke UPDATE itself is confirmed to have
    committed, is:
      - if the target citizenid is CURRENTLY ONLINE: re-check, using their
        own LIVE job, whether they would still pass steps 2/3 for this exact
        capability RIGHT NOW (see LegacyOrHighCommandStillQualifies below --
        this reuses the already-global HasK9Access for 'k9.access', a small
        internal duplicate of the certifierGrade/auditGrade comparison shape
        for 'k9.certify'/'k9.audit' -- deliberately NOT achieved by exporting
        certifications.lua's IsEligibleCertifier / admin.lua's
        IsAuthorizedAdmin as new resource-globals purely for this one
        reconciliation read, which would have required a .luacheckrc globals
        entry this file cannot add for itself -- and IsHighCommand directly
        for 'k9.givexp', which has no legacy tier below high command at all).
        Because RefreshPermissionCache has ALREADY run by this point (see
        CACHING below), step 1 correctly reads as false for the
        just-revoked grant, so calling the real gate function here answers
        exactly "steps 2+3, and 2+3 alone" -- no double-counting risk.
      - if the target citizenid is currently OFFLINE: their live job cannot
        be read at all (every rank/high-command check in this resource
        requires a connected Player object -- there is no secondary source
        of truth this file queries for an offline citizenid's current job).
        This is reported as a THIRD, HONEST outcome
        ('unknown_target_offline'), never silently folded into either
        "fully revoked" or "still has it" -- claiming either one without
        being able to check it would be exactly the kind of lie this task
        warned against, just aimed the other direction.
    RevokePermission's return is therefore a 3-way `stillHasAccess` result
    (nil | 'rank_or_high_command' | 'unknown_target_offline'), meaningful
    only when the revoke itself succeeded (`ok == true`) -- see that
    function's own doc comment below for the exact contract. The tablet is
    expected to render THREE distinct messages, not two.

    ======================================================================
    CACHING -- read before changing anything below.

    PermissionCache[citizenid] = { [permissionKey] = true, ... } -- presence
    of a key means "this citizenid currently holds an ACTIVE grant of this
    permission", absence means either "no grant" or "not currently cached at
    all" (see scope below); there is no separate boolean, a missing key IS
    the false case.

    SCOPE, DELIBERATELY NARROWER than server/certifications.lua's own
    Certifications cache: this table is populated ONLY for citizenids that
    are (or very recently were) ONLINE -- warmed on
    'QBCore:Server:PlayerLoaded', on this file's own 'onResourceStart'
    backfill loop for players already connected across a resource restart
    (mirrors server/main.lua's identical backfill for
    RefreshCertificationCache), and refreshed by GrantPermission/
    RevokePermission immediately after their own DB write commits -- but,
    UNLIKE certifications.lua's cache, ONLY when the target citizenid is
    confirmed online AT THAT MOMENT (RefreshPermissionCacheIfOnline below).
    Granting/revoking a permission for a citizenid who is offline right now
    deliberately does NOT create a cache entry for them -- there is nothing
    to keep in sync for a citizenid with no live session, and populating one
    anyway would grow this table forever for every citizenid ever granted a
    permission, whether or not they ever log in again this session (the
    exact unbounded-growth class server/certifications.lua's own Certifications
    table was found to have, and fixed reactively, for cert grants). Cleared
    entirely on 'playerDropped'.

    Every consumer (HasPermission) additionally re-checks
    `Config.Features.PermissionGrants` on every single call, mirroring
    server/highcommand.lua's IsHighCommand: this bypass is consulted from
    ALWAYS-LIVE gates with no registration step of their own to hide behind,
    so turning the feature off must genuinely disable it immediately, with
    no restart required -- caching "is the feature on" would defeat that.

    STALENESS WINDOW, STATED EXACTLY (this task's own explicit requirement):
      - For a grant/revoke made THROUGH this file's own GrantPermission/
        RevokePermission: at most the width of one MySQL round trip --
        specifically, the coroutine-yield gap between the INSERT/UPDATE
        itself committing and RefreshPermissionCache's own follow-up SELECT
        returning. HasPermission can theoretically observe a stale answer
        for a citizenid whose OWN action is what changed their own grant
        (vanishingly rare in practice, since a player is never the one
        calling GrantPermission/RevokePermission about themselves -- only
        high command can call these, and self-grant is blocked outright, see
        SELF-GRANT below) -- this is the SAME narrow, previously-disclosed
        window server/certifications.lua's own Certifications cache has
        always had relative to RefreshCertificationCache; not a new class of
        risk this file introduces.
      - For a grant/revoke made by ANY OTHER means (a hand-run SQL
        statement against k9_permissions, a different resource, a restored
        backup): NOT observed until that citizenid's next
        'QBCore:Server:PlayerLoaded' (reconnect) or this resource's next
        restart (onResourceStart backfill). This file has no polling or
        pub/sub mechanism watching the table for external writes -- matching
        every other cache in this resource (Certifications, K9XP, etc).
      - A citizenid who is offline right now has NO cache entry at all
        (see SCOPE above) -- there is nothing to be stale, by construction;
        the correct, current answer is computed fresh from the DB the moment
        they next connect.

    ======================================================================
    SELF-GRANT -- unconditionally blocked, no config escape hatch (unlike
    Config.HighCommand.allowSelfGrant, which the project owner deliberately
    made a toggle). config.lua's own Config.Permissions header does not
    define one for this feature, and this task's own brief gives the exact
    reasoning already settled for the XP-grant case: "a self-grant is the
    one case with no second person in the audit trail." GrantPermission
    below rejects outright if `targetCitizenid == granterCitizenid`, checked
    against the GRANTER'S OWN server-resolved citizenid (exports.qbx_core:
    GetPlayer(granterSrc).PlayerData.citizenid), never a client claim.
    Deliberately NOT extended to RevokePermission -- a high-command officer
    revoking a grant THEY THEMSELVES previously issued to their own
    citizenid (the only way they could ever hold one, since self-grant is
    blocked at the source) is removing their own power, not adding it; there
    is no "no second person in the audit trail" concern in that direction.

    ======================================================================
    DB ERRORS THROW, NOT NIL -- every MySQL.*.await call below is
    pcall-guarded, matching server/certifications.lua's own established
    discipline. GrantPermission's INSERT mirrors GrantCertification's
    GrantInFlight in-memory TOCTOU lock (keyed `citizenid .. ':' .. permission`)
    plus IsDuplicateKeyError handling for the DB's own
    `uq_one_active_permission_per_citizen` unique-key backstop (a race two
    concurrent grants can hit is NOT a real failure, it means another
    request already won -- same as certifications.lua's own documented
    reasoning, and the exact instruction the db-schema agent's own report
    on this table repeats). RevokePermission's UPDATE mirrors
    RevokeCertification's reconciliation-on-throw: a thrown UPDATE is NEVER
    reported as a success or a failure by guesswork -- an independent,
    fresh read (IsPermissionRowConfirmedActive below) decides which one
    actually happened before anything else (cache refresh, notifications,
    the "still has it by rank" reconciliation) runs.

    ======================================================================
    COOLDOWN -- PERMISSION_ACTION_COOLDOWN_MS below, via server/cooldowns.lua's
    NewCooldown, ONE shared instance covering both GrantPermission and
    RevokePermission, keyed by the GRANTER'S own source (mirrors
    server/certifications.lua's CertifyActionCooldown / server/admin.lua's
    AuditCooldown / server/highcommand.lua's HighCommandGrantCooldown shape
    exactly -- one instance per related-action group, not one per action).
    A plain positive LITERAL (1500ms, matching CERTIFY_ACTION_COOLDOWN_MS's
    own value), NOT a new Config field -- this file is told not to edit
    config.lua, and certifications.lua's own CERTIFY_ACTION_COOLDOWN_MS
    already establishes "a hardcoded local constant, not a Config value, is
    fine for an anti-fat-finger throttle on an already-trusted actor" as
    this resource's own precedent for exactly this situation.

    THE NewCooldown FOOTGUN, EXPLICITLY TESTED (this task's own instruction):
    server/cooldowns.lua's IsOnCooldown treats a non-positive/nil/NaN
    threshold as PERMANENTLY ON, never "no cooldown" -- 1500 is a plain
    positive literal here, never a Config read that could be 0/negative/nil,
    so AssertValidDefaultThreshold's constructor-time guard passes and this
    footgun cannot manifest for this file's own cooldown. Covered anyway by
    tests/permissions_spec.lua ("cooldown: a second grant/revoke from the
    same source inside the window is rejected, recovers once elapsed").

    ======================================================================
    AUDIT -- every GrantPermission/RevokePermission invocation (denied,
    rate-limited, invalid args, self-grant blocked, already-granted,
    not-granted, db error, or ok) is printed via LogAuditInvocation below,
    matching server/admin.lua's own "%s ran %s(%s) -> %s" print format
    EXACTLY (this task's explicit instruction) -- granter citizenid (via
    `whoLabel`, same resolution as admin.lua's own), action name, and a
    `detail` string packing the permission key and target citizenid
    together, then the outcome.

    ======================================================================
    NOTIFICATIONS -- deliberately narrow. This file sends an ox_lib toast to
    the TARGET only (if currently online), and only when the action ACTUALLY
    changed something for them:
      - grant success: always notified (a grant is always a real change,
        even if they already had equivalent access via rank -- it persists
        independently of any future rank change).
      - revoke success: notified ONLY when `stillHasAccess == nil` (fully
        removed). Deliberately SUPPRESSED when `stillHasAccess ==
        'rank_or_high_command'` -- telling a player "a capability you held
        has been revoked" when nothing actually changed for them would be
        exactly the kind of misleading message this task warned against,
        just aimed at the target instead of the admin. (The
        'unknown_target_offline' case has no online client to notify at
        all, by definition.)
    The GRANTER is deliberately NOT sent a toast by this file -- GrantPermission/
    RevokePermission return a structured `(ok, outcome, stillHasAccess)`
    synchronously to their caller (the tablet's own server-side glue,
    per the FILE-TO-FILE CONTRACT below), which is expected to render its
    own inline UI feedback rather than depend on an ox_lib toast the tablet
    might not even be the right place to show. This is a disclosed,
    deliberate asymmetry, not an oversight -- flagged for coder-ui/coder-frontend
    to confirm or override once the tablet's own UX is designed.

    LOCALE KEYS THIS FILE NEEDS -- only TWO new keys, kept deliberately
    minimal per the "no granter-facing toast" decision above; ALREADY
    LANDED in locales/en.json (confirmed by direct read, not assumed) with
    this exact English text -- documented here for reference, not as an
    open request:
      permissions.grant_notify_target  = "High command granted you: %s"
      permissions.revoke_notify_target = "High command revoked: %s"
      (reused, already present) common.unable_to_resolve_citizenid
      (reused, already present) common.target_no_longer_online -- NOT currently reachable by any path in this file (GrantPermission/RevokePermission take a citizenid, never a server id, so there is no "target must be online" failure mode to report) -- listed only because ListActivePermissionsForCitizenId/ListPermissionRoster's callers may want it for their own UI; this file itself never calls locale() with it.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes FIVE resource-global (no `local`) functions -- see
      each one's own doc comment below for the exact signature/outcome
      strings:
        HasPermission(citizenid, permissionKey) -> boolean
        GrantPermission(granterSrc, targetCitizenid, permissionKey) -> ok, outcome
        RevokePermission(granterSrc, targetCitizenid, permissionKey) -> ok, outcome, stillHasAccess
        ListActivePermissionsForCitizenId(callerSrc, targetCitizenid) -> ok, rowsOrOutcome
        ListPermissionRoster(callerSrc, permissionKey) -> ok, rowsOrOutcome
      HasPermission is consulted by server/certifications.lua (HasK9Access,
      IsEligibleCertifier) and server/admin.lua (IsAuthorizedAdmin), each
      behind a `type(HasPermission) == 'function'` guard, and SHOULD be
      consulted the same way by server/highcommand.lua's '/k9givexp' handler
      (reported, not yet wired -- live-owned file). The other four are for
      the tablet's own server-side glue (coder-ui/coder-frontend) to call
      directly from THEIR OWN event/callback handler, using THAT handler's
      own real `source` -- never a client-supplied one -- for `granterSrc`/
      `callerSrc`. GrantPermission/RevokePermission/ListActivePermissionsForCitizenId/
      ListPermissionRoster all independently re-verify high-command
      authorization THEMSELVES (never trust a caller to have already
      checked it) -- see each one's own doc comment.
    - THIS FILE calls `NewCooldown` (server/cooldowns.lua) at this file's own
      file-load time -- MUST load after server/cooldowns.lua.
    - THIS FILE calls `NotifyPlayer` (server/notify.lua) at run time only.
    - THIS FILE calls `IsHighCommand` (server/highcommand.lua) and
      `HasK9Access` (server/certifications.lua) at run time only, both
      behind `type(...) == 'function'` guards -- genuine soft dependencies,
      no load-order requirement either way.
    - THIS FILE is consulted BY server/certifications.lua and
      server/admin.lua (see above) -- this file does NOT call into either of
      those two, so there is no load-order cycle.
    - THIS FILE does NOT edit server/highcommand.lua, server/kennel.lua,
      server/fetch.lua, server/propattachment.lua, server/entities.lua,
      server/progression.lua, or server/wellbeing.lua -- all have live
      owners this pass. The one integration those files would otherwise
      need (highcommand.lua's '/k9givexp') is reported, not performed.

    CONFIG THIS FILE ASSUMES EXISTS (already added by the config owner):
      Config.Features.PermissionGrants : boolean
      Config.Permissions : table<string, { label: string, description: string? }>
      -- asserted in full at THIS FILE'S OWN LOAD TIME, unconditionally (not
      -- deferred to onResourceStart, and not gated on the feature flag) --
      -- same "authorization-root file, fail loudly on a genuine
      -- misconfiguration instantly rather than only as an inexplicable
      -- 'nobody can ever get any permission'" reasoning
      -- server/certifications.lua's own HasK9Access config-safety guard
      -- already documents for itself, applied here because HasPermission is
      -- consulted from those same always-live gates regardless of whether
      -- PermissionGrants is on.

    ======================================================================
    TABLET NETWORK CONTRACT -- client/tablet.lua (coder-frontend) already
    proposed and built against these exact two callback names (confirmed by
    direct read of that file, not re-negotiated from scratch):
      lib.callback 'qbx_k9unit:server:tabletGrantPermission'
          (targetCitizenid: string, permissionKey: string) -> { ok: boolean, reason: string? }
      lib.callback 'qbx_k9unit:server:tabletRevokePermission'
          (targetCitizenid: string, permissionKey: string) -> { ok: boolean, reason: string? }
    Both are thin wrappers over GrantPermission/RevokePermission, registered
    ONLY when Config.Features.CommandTablet is true (checked at this file's
    own load time, matching client/tablet.lua's own "gate at registration,
    not just inside the handler" convention -- config.lua is a
    shared_script, already loaded in full by the time this file's own
    server_scripts entry runs). `source` comes from ox_lib's own callback
    dispatch (server-verified, never a client-supplied value) and is passed
    straight through as `granterSrc`/`callerSrc` -- these two functions
    already independently re-verify high-command authorization from that
    source's own live job, so this wrapper adds no authorization logic of
    its own, only the return-shape translation:
      - grant success            -> { ok = true }
      - grant/revoke failure     -> { ok = false, reason = <outcome string> }
      - revoke success, fully removed          -> { ok = true }
      - revoke success, target still qualifies -> { ok = true, reason = 'rank_or_high_command' }
      - revoke success, target offline         -> { ok = true, reason = 'unknown_target_offline' }
    The last two are successes (the revoke itself committed) carrying a
    `reason` anyway -- this is deliberate, not a misuse of the field: it is
    the ONLY channel available in a plain `{ ok, reason }` shape to keep the
    "revoked, but they still have this by rank" case from reading as a
    silent, unqualified success. client/tablet.lua forwards `reason`
    opaque/unmodified to the NUI in every case (its own header: "coder-ui
    owns NUI-side copy") -- no locale key is needed for either of these
    reason strings on the SERVER side either, since neither ever reaches
    locale() -- they are internal outcome tags, not player-facing text.

    NOT IMPLEMENTED HERE, AND DELIBERATELY SO: `qbx_k9unit:server:tabletListRoster`.
    client/tablet.lua's own header describes this as returning "a roster of
    handlers/K9s with their certifications, XP and granted permissions" --
    that is a THREE-WAY aggregation across server/certifications.lua's
    k9_certifications, server/progression.lua's k9_progression, and this
    file's own k9_permissions, none of which this file has any business
    reaching across into on its own initiative (certifications.lua is
    UNOWNED and editable surgically for this task, but progression.lua is
    LIVE-OWNED by the XP agent this session -- see COORDINATION.md). This is
    a genuine cross-file architecture question (does a fourth file own the
    merge, does the client make three separate round trips instead, does
    ListActivePermissionsForCitizenId get reused per-row by whichever file
    does own it), not a permissions-layer implementation detail -- reported
    to coder-frontend/coder-ui/coder-architect rather than decided
    unilaterally here. This file's own two roster-shaped exports
    (ListActivePermissionsForCitizenId, ListPermissionRoster) are ready to
    be called by whichever file ends up owning that aggregation.
    ======================================================================

    FXMANIFEST.LUA PLACEMENT REQUESTED (server_scripts, not edited here):
    insert `'server/permissions.lua',` immediately after
    `'server/highcommand.lua',` and before `'server/main.lua',` -- satisfies
    the one hard load-order requirement (after server/cooldowns.lua) and
    groups this file with the other authority-tier file it most directly
    complements, though (per the FILE-TO-FILE CONTRACT above) nothing here
    actually requires that exact position -- every cross-file call in either
    direction is guarded by `type(...) == 'function'`.

    SQL / MIGRATION: `k9_permissions` (columns, indexes, and all three query
    shapes this file uses) already landed -- sql/install.sql's own header
    comment on that table, and sql/migrations/0005_create_k9_permissions.sql
    for an existing database. This file was written directly against that
    real, final schema, not a placeholder guess.
]]

-- ======================================================================
-- CONFIG-SAFETY GUARD -- run UNCONDITIONALLY, at this file's own LOAD
-- time, same reasoning as server/certifications.lua's own guard for
-- Config.Departments/Config.Peds: HasPermission below is consulted from
-- always-live gates regardless of Config.Features.PermissionGrants'
-- current value, so a malformed Config.Permissions must fail loudly at
-- resource start, not silently as "nobody can ever hold any permission".
-- ======================================================================
assert(type(Config.Permissions) == 'table',
    '[qbx_k9unit] Config.Permissions must be a table -- HasPermission, GrantPermission and RevokePermission ' ..
    'all validate a caller-supplied permission key against it; a missing table would make every permission ' ..
    'check fail closed with nothing logged to explain why.')
for key, def in pairs(Config.Permissions) do
    assert(type(key) == 'string' and key ~= '',
        '[qbx_k9unit] every Config.Permissions key must be a non-empty string.')
    assert(type(def) == 'table' and type(def.label) == 'string' and def.label ~= '',
        ('[qbx_k9unit] Config.Permissions[%s].label must be a non-empty string -- the tablet renders this as ' ..
         'the human-readable capability name.'):format(tostring(key)))
    assert(def.description == nil or type(def.description) == 'string',
        ('[qbx_k9unit] Config.Permissions[%s].description must be a string if present.'):format(tostring(key)))
end

-- PermissionCache[citizenid] = { [permissionKey] = true, ... } -- see this
-- file's header "CACHING" section for scope (online citizenids only) and
-- the exact staleness window. Local: nothing outside this file should read
-- it directly -- always go through HasPermission(citizenid, permissionKey).
local PermissionCache = {}

-- Anti-fat-finger cooldown shared by GrantPermission/RevokePermission --
-- see header "COOLDOWN" section for why this is a plain positive literal,
-- not a Config field.
local PERMISSION_ACTION_COOLDOWN_MS = 1500
local PermissionActionCooldown = NewCooldown(PERMISSION_ACTION_COOLDOWN_MS)
PermissionActionCooldown.RegisterPlayerDropped()

-- SECURITY (mirrors server/certifications.lua's GrantInFlight EXACTLY --
-- see that file's own doc comment for the full TOCTOU writeup, not
-- repeated here): closes GrantPermission's check-then-insert race on its
-- own terms, independent of whether `uq_one_active_permission_per_citizen`
-- is actually present on this install. Keyed "citizenid:permission" (the
-- invariant is scoped per capability). Always released, even on an
-- unexpected thrown error (pcall-wrapped in GrantPermission below).
local GrantInFlight = {}

--- @param value any
--- @return boolean
local function IsValidCitizenId(value)
    -- VARCHAR(50), matching every citizenid column in k9_permissions.
    -- Not an injection backstop (this value only ever reaches a bound `?`
    -- placeholder) -- a plain sanity/DoS-lite bound, matching
    -- server/admin.lua's own IsValidCitizenId.
    return type(value) == 'string' and value ~= '' and #value <= 50
end

--- SECURITY FIX (coder-security, this pass -- the headline finding this
--- pass exists to close): until now this function accepted ONLY an exact
--- key already present in Config.Permissions (the four admin capabilities:
--- k9.access/k9.certify/k9.audit/k9.givexp). It had NO case at all for the
--- 'feature.<Name>'/'block.<Name>' namespace client/tablet.lua's own
--- grantFeature/revokeFeature/blockFeature/unblockFeature (and this file's
--- own header/config.lua's own Config.FeatureControl doc block) already
--- describe as the real storage shape for a per-person feature grant/
--- block -- meaning GrantPermission/RevokePermission rejected EVERY such
--- call with 'invalid_permission' before ever reaching the DB, so
--- Config.FeatureControl.RequireGrant and per-person blocks were
--- unimplementable regardless of what any consuming gate (server/combat.lua's
--- IsCombatFeaturePermittedForCitizenId, server/pursuitsprint.lua's
--- IsPursuitSprintPermittedForCitizenId, server/admin.lua's
--- IsAdminFeaturePermittedForCitizenId, all of which already read
--- HasPermission(citizenid, 'feature.'/'block.' .. Name) correctly) was
--- prepared to check. See server/tablet.lua's own header "A REAL,
--- PRE-EXISTING GAP FOUND WHILE BUILDING THIS" for that file's own
--- independent discovery of the same bug.
---
--- FIXED WITHOUT SIMPLY LOOSENING THE CHECK: `feature.<Name>`/
--- `block.<Name>` are now accepted ONLY when `<Name>` is a REAL key of
--- Config.Features -- the exact same table every one of this resource's
--- feature flags already lives in, so `Config.Features[Name] ~= nil` is a
--- referential check against real, existing resource state, never a
--- free-form pattern match. `feature.NotARealFeature`,
--- `block.'; DROP TABLE k9_permissions;--`, or a >50-char payload are all
--- still rejected exactly as before an unvalidated key would have been --
--- an unvalidated permission key is a new hole, not a fix. Deliberately
--- does NOT additionally require `<Name>` to appear in
--- Config.FeatureControl.RequireGrant: a BLOCK is documented (config.lua's
--- own Config.FeatureControl header) to work against ANY feature, not only
--- ones already listed there ("high command can turn an individual
--- feature on or off for ONE specific K9 or handler"), and a GRANT for a
--- feature that is not in RequireGrant is simply inert rather than unsafe
--- (every consuming gate's own step-3 RequireGrant check only ever reads a
--- 'feature.<Name>' grant when RequireGrant[Name] is true) -- narrowing
--- this further than Config.Features itself would reject a legitimate
--- block with no corresponding safety benefit.
--- @param value any
--- @return boolean
local function IsValidPermissionKey(value)
    if type(value) ~= 'string' or value == '' or #value > 50 then return false end

    if type(Config.Permissions) == 'table' and Config.Permissions[value] ~= nil then
        return true
    end

    if type(Config.Features) ~= 'table' then return false end

    local featureName = value:match('^feature%.(.+)$') or value:match('^block%.(.+)$')
    return featureName ~= nil and Config.Features[featureName] ~= nil
end

--- Returns true if `err` (the value pcall caught around the grant INSERT)
--- represents a MySQL/MariaDB duplicate-key error (1062) on
--- `uq_one_active_permission_per_citizen`. Same shape-agnostic detection as
--- server/certifications.lua's own IsDuplicateKeyError (duplicated here
--- rather than shared, matching this resource's own established "each file
--- keeps its own tiny copy of a genuinely small, self-contained check"
--- convention -- see server/highcommand.lua's IsValidPositiveFiniteNumber
--- doc comment for the same reasoning applied to a different check).
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

--- Console log line for EVERY GrantPermission/RevokePermission invocation --
--- allowed, denied, rate-limited, or malformed. Matches
--- server/admin.lua's own LogAuditInvocation "%s ran %s(%s) -> %s" format
--- EXACTLY (this task's explicit instruction).
--- @param granterSrc number
--- @param action string -- 'grantPermission' | 'revokePermission'
--- @param detail string
--- @param outcome string
local function LogAuditInvocation(granterSrc, action, detail, outcome)
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    local whoLabel = granterCitizenid and ('citizenid=' .. granterCitizenid) or ('unresolved-source=' .. tostring(granterSrc))
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

--- Fail-closed SELECT wrapper -- pcall around MySQL.query.await, matching
--- server/admin.lua's own SafeQuery: a failed read returns zero rows to the
--- caller, never a raw Lua error.
--- @param sql string
--- @param params table
--- @return table rows
local function SafeQuery(sql, params)
    local ok, rowsOrErr = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] permissions.lua query failed: %s'):format(tostring(rowsOrErr)))
        return {}
    end
    return rowsOrErr or {}
end

--- Re-queries every ACTIVE permission row for `citizenid` and replaces its
--- cache entry wholesale. Fails CLOSED on a thrown read (an unreadable
--- citizenid's permission set is treated as empty, never as "whatever it
--- was before" or "everything") -- same posture as
--- server/certifications.lua's RefreshCertificationCache.
--- @param citizenid string
local function RefreshPermissionCache(citizenid)
    local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT permission FROM k9_permissions WHERE citizenid = ? AND active = 1', { citizenid })
    if not ok then
        print(('[qbx_k9unit] permissions.lua RefreshPermissionCache query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
        PermissionCache[citizenid] = {}
        return
    end
    local set = {}
    for _, row in ipairs(rowsOrErr or {}) do
        set[row.permission] = true
    end
    PermissionCache[citizenid] = set
end

--- Refreshes `citizenid`'s cache entry ONLY if they are currently online --
--- see this file's header "CACHING" / "SCOPE" section for why an offline
--- citizenid deliberately gets no cache entry at all.
--- @param citizenid string
local function RefreshPermissionCacheIfOnline(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source then
        RefreshPermissionCache(citizenid)
    end
end

--- Re-checks a SPECIFIC (citizenid, permission) row's `active` column
--- directly against the DB, independent of RefreshPermissionCache's own
--- collapsed fail-closed return -- same reasoning as
--- server/certifications.lua's IsCertRowConfirmedActive: RevokePermission
--- needs to tell "the UPDATE genuinely never committed" apart from
--- "unreadable, true outcome unknown" before deciding whether to report
--- success.
--- @param citizenid string
--- @param permissionKey string
--- @return boolean? active -- true/false if confirmed against the DB, nil if the read itself failed
local function IsPermissionRowConfirmedActive(citizenid, permissionKey)
    local ok, activeIdOrErr = pcall(MySQL.scalar.await, 'SELECT id FROM k9_permissions WHERE citizenid = ? AND permission = ? AND active = 1 LIMIT 1', {
        citizenid, permissionKey,
    })
    if not ok then
        print(('[qbx_k9unit] permissions.lua row-reconciliation read failed for %s/%s: %s'):format(citizenid, permissionKey, tostring(activeIdOrErr)))
        return nil
    end
    return activeIdOrErr ~= nil
end

--- Server-authoritative check: is `source` currently allowed to grant/revoke
--- given the LEGACY (high-command-or-rank) rules that would apply to
--- `permissionKey`'s own capability, WITHOUT consulting any permission
--- grant at all -- used ONLY by RevokePermission's post-revoke
--- reconciliation (see this file's header "THE REVOKED BUT STILL HAS IT BY
--- RANK CASE"). Deliberately duplicates the certifierGrade/auditGrade
--- comparison SHAPE already established in server/certifications.lua's
--- IsEligibleCertifier and server/admin.lua's IsAuthorizedAdmin, rather
--- than exporting either of those (both `local`, both in files this task
--- says to edit surgically, not to widen) as new resource-globals purely
--- for this one reconciliation read -- see header for the full reasoning.
--- Fails CLOSED on every unresolvable shape, identical to every other rank
--- gate in this resource: no Player, no job, job.name not a configured
--- department, no numeric grade field for this department, no job.grade,
--- or a non-number job.grade.level all return false; `job.isboss` and
--- IsHighCommand both still short-circuit true, matching every other gate.
--- @param source number
--- @param gradeField string -- 'certifierGrade' | 'auditGrade'
--- @return boolean
local function MeetsDepartmentGradeOrHighCommand(source, gradeField)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or type(Config.Departments) ~= 'table' or not Config.Departments[job.name] then return false end

    if job.isboss then return true end
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    local dept = Config.Departments[job.name]
    if type(dept[gradeField]) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept[gradeField]
end

--- Dispatches to the right "steps 2+3 only" check for `permissionKey`. See
--- MeetsDepartmentGradeOrHighCommand's own doc comment above for why this
--- is a small local duplicate rather than a call into another file's
--- `local` function. 'k9.access' reuses the real, already-global
--- HasK9Access directly -- safe here specifically because
--- RevokePermission always calls RefreshPermissionCache BEFORE this,
--- so HasK9Access's own step-1 permission read is already correctly false
--- for the grant just revoked (see header for why this cannot double-count).
--- 'k9.givexp' has no legacy tier below high command at all, per
--- config.lua's Config.Permissions catalog -- IsHighCommand alone is
--- steps 2+3 collapsed into one for that capability.
--- @param source number
--- @param permissionKey string
--- @return boolean
local function LegacyOrHighCommandStillQualifies(source, permissionKey)
    if permissionKey == 'k9.access' then
        return type(HasK9Access) == 'function' and HasK9Access(source)
    elseif permissionKey == 'k9.certify' then
        return MeetsDepartmentGradeOrHighCommand(source, 'certifierGrade')
    elseif permissionKey == 'k9.audit' then
        return MeetsDepartmentGradeOrHighCommand(source, 'auditGrade')
    elseif permissionKey == 'k9.givexp' then
        return type(IsHighCommand) == 'function' and IsHighCommand(source)
    end
    -- Unknown key: cannot happen through GrantPermission/RevokePermission
    -- (both validate permissionKey against Config.Permissions before ever
    -- reaching this point) -- fail closed regardless, never guess true.
    return false
end

-- ======================================================================
-- STEP 1 OF THE RESOLUTION ORDER -- the hot-path check every OTHER gate in
-- this resource consults. See this file's header "CACHING" section for the
-- exact staleness window.
-- ======================================================================

--- Server-authoritative: does `citizenid` currently hold an ACTIVE grant of
--- `permissionKey`? THIS IS STEP 1 ONLY -- it does not consult high command
--- or any rank gate; callers that want the full 4-step resolution order
--- call this FIRST, then fall through to their own existing high-command/
--- rank checks (see header "HOW STEP 1 IS WIRED IN").
---
--- Re-checks Config.Features.PermissionGrants on EVERY call (never cached),
--- matching server/highcommand.lua's IsHighCommand -- see header for why.
--- Fails CLOSED on every unresolvable shape: feature off, a non-string/
--- empty citizenid, or a permissionKey not in Config.Permissions.
--- @param citizenid string
--- @param permissionKey string
--- @return boolean
function HasPermission(citizenid, permissionKey)
    if not (Config.Features and Config.Features.PermissionGrants == true) then return false end
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if not IsValidPermissionKey(permissionKey) then return false end

    local set = PermissionCache[citizenid]
    return set ~= nil and set[permissionKey] == true
end

-- ======================================================================
-- GRANT / REVOKE -- only high command may call either. See header
-- "SELF-GRANT" / "DB ERRORS" / "COOLDOWN" / "AUDIT" / "NOTIFICATIONS"
-- sections for the full contract each of these implements.
-- ======================================================================

--- Grants `permissionKey` to `targetCitizenid`. Only callable by high
--- command (re-verified here, server-side, from `granterSrc`'s OWN live
--- job -- never trusts a client claim of authority). Self-grant is blocked
--- unconditionally. Idempotent in effect: granting an already-active
--- permission reports 'already_granted' rather than creating a second row
--- or erroring.
--- @param granterSrc number
--- @param targetCitizenid string
--- @param permissionKey string
--- @param appearanceModelOverride string? -- K9 ROLE/MODEL DECOUPLING (coder-architect, server/appearance.lua): ONLY consulted when permissionKey == 'k9.access' and Config.K9Appearance.applyPedModelOnCertify is on -- the explicit ped model server/appearance.lua's ApplyK9PedRole (the tablet's direct "apply K9" action) wants applied instead of the automatic-grant default (Config.Peds[1].model). Every OTHER caller of GrantPermission simply omits this and gets the default, exactly as before this parameter existed.
--- @return boolean ok
--- @return string outcome -- 'ok' | 'feature_disabled' | 'denied' | 'invalid_permission' | 'invalid_target' | 'invalid_granter' | 'self_grant_blocked' | 'rate_limited' | 'already_granted' | 'db_error'
function GrantPermission(granterSrc, targetCitizenid, permissionKey, appearanceModelOverride)
    if not (Config.Features and Config.Features.PermissionGrants == true) then
        return false, 'feature_disabled'
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not PermissionActionCooldown.Consume(granterSrc, PERMISSION_ACTION_COOLDOWN_MS) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'rate_limited')
        return false, 'rate_limited'
    end

    if not IsValidPermissionKey(permissionKey) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'invalid_permission')
        return false, 'invalid_permission'
    end

    if not IsValidCitizenId(targetCitizenid) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, tostring(targetCitizenid)), 'invalid_target')
        return false, 'invalid_target'
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        -- Should not be reachable in practice -- IsHighCommand(granterSrc)
        -- above already required a resolvable Player -- but never assume
        -- that guarantee holds forever; fail closed and report rather than
        -- index into a nil below.
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'invalid_granter')
        NotifyPlayer(granterSrc, locale('common.unable_to_resolve_citizenid'), 'error')
        return false, 'invalid_granter'
    end

    if targetCitizenid == granterCitizenid then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'self_grant_blocked')
        return false, 'self_grant_blocked'
    end

    local lockKey = targetCitizenid .. ':' .. permissionKey
    if GrantInFlight[lockKey] then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'already_granted')
        return false, 'already_granted'
    end
    GrantInFlight[lockKey] = true

    -- Everything from here down is the DB critical section GrantInFlight
    -- protects -- wrapped in its own closure so it can be pcall'd as a
    -- unit, guaranteeing GrantInFlight[lockKey] is released on every exit
    -- path, including an unexpected thrown error. Mirrors
    -- server/certifications.lua's GrantCertification/doGrantInsert shape
    -- exactly.
    local outcome
    local function doGrantInsert()
        local existingId = MySQL.scalar.await('SELECT id FROM k9_permissions WHERE citizenid = ? AND permission = ? AND active = 1 LIMIT 1', {
            targetCitizenid, permissionKey,
        })
        if existingId then
            outcome = 'already_granted'
            return
        end

        local insertOk, insertResultOrErr = pcall(MySQL.insert.await, 'INSERT INTO k9_permissions (citizenid, permission, granted_by) VALUES (?, ?, ?)', {
            targetCitizenid, permissionKey, granterCitizenid,
        })

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                -- Another request won the race between the pre-check above
                -- and this INSERT -- the DB's own unique index caught it;
                -- treat identically to the normal "already granted" no-op.
                RefreshPermissionCacheIfOnline(targetCitizenid)
                outcome = 'already_granted'
                return
            end
            print(('[qbx_k9unit] permissions.lua GrantPermission INSERT failed for %s/%s: %s'):format(targetCitizenid, permissionKey, tostring(insertResultOrErr)))
            outcome = 'db_error'
            return
        end

        outcome = 'ok'
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil

    if not grantOk then
        print(('[qbx_k9unit] permissions.lua GrantPermission unexpected error for %s/%s: %s'):format(targetCitizenid, permissionKey, tostring(grantErr)))
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'db_error')
        return false, 'db_error'
    end

    if outcome ~= 'ok' then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), outcome)
        return false, outcome
    end

    RefreshPermissionCacheIfOnline(targetCitizenid)
    LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'ok')

    -- NOTIFICATIONS: target only, see header. Always sent on a real grant.
    local onlineTargetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
    local onlineTargetSrc = onlineTargetPlayer and onlineTargetPlayer.PlayerData and onlineTargetPlayer.PlayerData.source
    if onlineTargetSrc then
        NotifyPlayer(onlineTargetSrc, locale('permissions.grant_notify_target', Config.Permissions[permissionKey].label), 'success')
    end

    -- K9 ROLE/MODEL DECOUPLING (coder-architect, server/appearance.lua) --
    -- config.lua's own Config.K9Appearance header is explicit that granting
    -- 'k9.access' is one of the two actions that "actually turns their
    -- character into the ped" when applyPedModelOnCertify is on. Guarded
    -- with `type(...) == 'function'` (this file loads before
    -- server/appearance.lua in fxmanifest.lua's server_scripts, per that
    -- file's own requested placement -- see its header -- so this is a
    -- genuine soft dependency, not a load-order assumption: by the time a
    -- real grant can fire, every server_scripts file has already loaded).
    if permissionKey == 'k9.access' and Config.K9Appearance and Config.K9Appearance.applyPedModelOnCertify
        and type(ApplyK9AppearanceOnGrant) == 'function' then
        ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, appearanceModelOverride)
    end

    return true, 'ok'
end

--- Revokes `permissionKey` from `targetCitizenid`. Only callable by high
--- command. See this file's header "THE REVOKED BUT STILL HAS IT BY RANK
--- CASE" for the full `stillHasAccess` contract -- this is the return value
--- the tablet MUST surface distinctly, per this task's own explicit
--- requirement.
--- @param granterSrc number
--- @param targetCitizenid string
--- @param permissionKey string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'feature_disabled' | 'denied' | 'invalid_permission' | 'invalid_target' | 'invalid_granter' | 'rate_limited' | 'not_granted' | 'db_error'
--- @return string? stillHasAccess -- meaningful ONLY when ok == true: nil (fully removed -- target has no other path to this capability), 'rank_or_high_command' (target is online and independently still qualifies -- revoking THIS grant did not remove their access), 'unknown_target_offline' (target is not connected -- their current rank/high-command status cannot be verified right now)
function RevokePermission(granterSrc, targetCitizenid, permissionKey)
    if not (Config.Features and Config.Features.PermissionGrants == true) then
        return false, 'feature_disabled'
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not PermissionActionCooldown.Consume(granterSrc, PERMISSION_ACTION_COOLDOWN_MS) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'rate_limited')
        return false, 'rate_limited'
    end

    if not IsValidPermissionKey(permissionKey) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'invalid_permission')
        return false, 'invalid_permission'
    end

    if not IsValidCitizenId(targetCitizenid) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(permissionKey, tostring(targetCitizenid)), 'invalid_target')
        return false, 'invalid_target'
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'invalid_granter')
        NotifyPlayer(granterSrc, locale('common.unable_to_resolve_citizenid'), 'error')
        return false, 'invalid_granter'
    end

    -- DB ERRORS THROW, NOT NIL -- pcall-guarded, reconciled on throw exactly
    -- like server/certifications.lua's RevokeCertification. A SQL
    -- transaction would not resolve the one genuine ambiguity a thrown
    -- error can leave behind here either (this is the only write in this
    -- function) -- same reasoning that file's own comment already gives.
    local updateOk, affectedRowsOrErr = pcall(
        MySQL.update.await,
        'UPDATE k9_permissions SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND permission = ? AND active = 1',
        { granterCitizenid, targetCitizenid, permissionKey }
    )

    if not updateOk then
        print(('[qbx_k9unit] permissions.lua RevokePermission UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(targetCitizenid, permissionKey, tostring(affectedRowsOrErr)))

        local stillActive = IsPermissionRowConfirmedActive(targetCitizenid, permissionKey)
        if stillActive ~= false then
            -- Either confirmed still active (the UPDATE genuinely never
            -- committed) or unreadable (nil, true outcome unknown) -- in
            -- BOTH cases, never claim a revoke succeeded that this code
            -- cannot confirm, and never run the side effects below (cache
            -- refresh, notification, rank reconciliation) against a guess.
            LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'db_error')
            return false, 'db_error'
        end
        -- Confirmed inactive despite the thrown error (e.g. a success
        -- acknowledgment lost after a real commit) -- fall through to the
        -- normal success path below against this now-confirmed truth.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'not_granted')
        return false, 'not_granted'
    end

    -- The revoke is CONFIRMED at this point (either the UPDATE returned
    -- normally with affectedRows > 0, or the reconciliation read above
    -- independently confirmed the row is now inactive). Refresh the cache
    -- BEFORE the rank reconciliation below -- LegacyOrHighCommandStillQualifies
    -- (for 'k9.access') calls the real HasK9Access, which itself re-reads
    -- this same cache; it must see the grant as already gone.
    RefreshPermissionCacheIfOnline(targetCitizenid)

    local stillHasAccess = nil
    local onlineTargetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
    local onlineTargetSrc = onlineTargetPlayer and onlineTargetPlayer.PlayerData and onlineTargetPlayer.PlayerData.source
    if onlineTargetSrc then
        if LegacyOrHighCommandStillQualifies(onlineTargetSrc, permissionKey) then
            stillHasAccess = 'rank_or_high_command'
        end
    else
        stillHasAccess = 'unknown_target_offline'
    end

    LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s still_has_access=%s'):format(permissionKey, targetCitizenid, tostring(stillHasAccess)), 'ok')

    -- NOTIFICATIONS: target only, and only when something actually changed
    -- for them -- see header "NOTIFICATIONS" for why this is suppressed
    -- when stillHasAccess == 'rank_or_high_command'.
    if onlineTargetSrc and stillHasAccess == nil then
        NotifyPlayer(onlineTargetSrc, locale('permissions.revoke_notify_target', Config.Permissions[permissionKey].label), 'error')
    end

    -- K9 ROLE/MODEL DECOUPLING (coder-architect, server/appearance.lua) --
    -- only when 'k9.access' is FULLY gone (stillHasAccess == nil): if the
    -- target still qualifies via rank/high-command or is offline (unknown),
    -- MaybeRevertK9Appearance does its OWN independent reconciliation
    -- anyway (it also checks for a separate active k9_certifications row),
    -- so this is a cheap pre-filter, not a correctness dependency. Guarded
    -- with `type(...) == 'function'`, same soft-dependency reasoning as the
    -- grant-side call above.
    if permissionKey == 'k9.access' and stillHasAccess == nil and type(MaybeRevertK9Appearance) == 'function' then
        MaybeRevertK9Appearance(targetCitizenid)
    end

    return true, 'ok', stillHasAccess
end

-- ======================================================================
-- TABLET QUERIES -- read-only, DB-authoritative (never served from
-- PermissionCache, which is scoped to online citizenids only -- these two
-- must work for an offline target/roster too). Each independently
-- re-verifies high-command authorization from `callerSrc`'s own live job,
-- exactly like GrantPermission/RevokePermission -- never trust a caller to
-- have already checked this themselves.
-- ======================================================================

--- Lists every ACTIVE permission `targetCitizenid` currently holds (the
--- tablet's per-person view). Uses idx_citizen_permission_active as a
--- citizenid-prefix scan -- the exact query shape that index's own
--- sql/install.sql comment documents.
--- @param callerSrc number
--- @param targetCitizenid string
--- @return boolean ok
--- @return table|string rowsOrOutcome -- on success: array of { permission: string, grantedBy: string, grantedAt: string }; on failure: 'denied' | 'invalid_target'
function ListActivePermissionsForCitizenId(callerSrc, targetCitizenid)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(callerSrc)) then
        return false, 'denied'
    end
    if not IsValidCitizenId(targetCitizenid) then
        return false, 'invalid_target'
    end

    local rows = SafeQuery(
        'SELECT permission, granted_by, granted_at FROM k9_permissions WHERE citizenid = ? AND active = 1 ORDER BY granted_at DESC',
        { targetCitizenid }
    )
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { permission = row.permission, grantedBy = row.granted_by, grantedAt = row.granted_at }
    end
    return true, out
end

--- Lists every citizenid currently holding `permissionKey` (the tablet's
--- roster view for one capability). Uses idx_permission_active -- the exact
--- query shape that index's own sql/install.sql comment documents.
--- @param callerSrc number
--- @param permissionKey string
--- @return boolean ok
--- @return table|string rowsOrOutcome -- on success: array of { citizenid: string, grantedBy: string, grantedAt: string }; on failure: 'denied' | 'invalid_permission'
function ListPermissionRoster(callerSrc, permissionKey)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(callerSrc)) then
        return false, 'denied'
    end
    if not IsValidPermissionKey(permissionKey) then
        return false, 'invalid_permission'
    end

    local rows = SafeQuery(
        'SELECT citizenid, granted_by, granted_at FROM k9_permissions WHERE permission = ? AND active = 1 ORDER BY granted_at DESC',
        { permissionKey }
    )
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { citizenid = row.citizenid, grantedBy = row.granted_by, grantedAt = row.granted_at }
    end
    return true, out
end

-- ======================================================================
-- TABLET CALLBACKS -- see this file's header "TABLET NETWORK CONTRACT" for
-- the full writeup. Gated on Config.Features.CommandTablet AT REGISTRATION
-- TIME (this resource's "gate at registration, not just inside the
-- handler" convention, mirrored from client/tablet.lua's own identical
-- top-of-file gate): if that flag is not `true`, neither callback below is
-- ever registered at all, not merely a runtime no-op. Independent of
-- Config.Features.PermissionGrants -- GrantPermission/RevokePermission
-- themselves already re-check that flag and fail closed with
-- 'feature_disabled' if it is off, so registering these callbacks
-- regardless of PermissionGrants' value is safe and lets the tablet render
-- a clear "feature disabled" reason rather than the callback not existing
-- at all.
-- ======================================================================
if Config.Features and Config.Features.CommandTablet == true then
    lib.callback.register('qbx_k9unit:server:tabletGrantPermission', function(source, targetCitizenid, permissionKey)
        local ok, outcome = GrantPermission(source, targetCitizenid, permissionKey)
        if ok then return { ok = true } end
        return { ok = false, reason = outcome }
    end)

    lib.callback.register('qbx_k9unit:server:tabletRevokePermission', function(source, targetCitizenid, permissionKey)
        local ok, outcome, stillHasAccess = RevokePermission(source, targetCitizenid, permissionKey)
        if ok then
            if stillHasAccess then
                return { ok = true, reason = stillHasAccess }
            end
            return { ok = true }
        end
        return { ok = false, reason = outcome }
    end)
end

-- ======================================================================
-- CACHE LIFECYCLE -- warm on load/reconnect, evict on disconnect. Mirrors
-- server/certifications.lua's own PlayerLoaded/playerDropped handlers and
-- server/main.lua's onResourceStart backfill loop exactly.
-- ======================================================================

--- Warms PermissionCache for a freshly-loaded (or freshly-connected, across
--- a resource restart -- see the onResourceStart backfill below) player.
--- CONFIDENCE NOTE carried over from server/certifications.lua: this event
--- name is used with medium-high confidence based on established Qbox/
--- QBCore convention, not independently verified against live qbx_core
--- source in this sandbox.
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if citizenid then
        RefreshPermissionCache(citizenid)
    end
end)

--- Evicts `citizenid`'s cache entry on disconnect -- see this file's header
--- "CACHING" section: an entry for a now-offline citizenid is never read
--- again until PlayerLoaded repopulates it fresh, so dropping it here is
--- purely a bounded-memory concern, same reasoning
--- server/certifications.lua's own playerDropped handler gives for
--- Certifications.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        PermissionCache[citizenid] = nil
    end
end)

--- Backfill for players already connected across a resource restart --
--- mirrors server/main.lua's identical backfill loop for
--- RefreshCertificationCache verbatim (same GetPlayers()/tonumber/
--- exports.qbx_core:GetPlayer shape), since no fresh PlayerLoaded event
--- fires for a player who was already online before this resource
--- (re)started.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                RefreshPermissionCache(Player.PlayerData.citizenid)
            end
        end
    end
end)
