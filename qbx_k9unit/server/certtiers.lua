--[[
    qbx_k9unit/server/certtiers.lua

    OWNER-DIRECTED REVERSAL of a design decision already shipped in this
    codebase. Owner's own words, verbatim, for THIS pass: "Allow high
    command to edit the tiers trainee certified senior etc add more roles
    edit permissions for those roles etc."

    server/certifications.lua's own header ("TIER (§5)") argues, at
    length, for the OPPOSITE of what this file builds:

        "TIER (§5): a fixed, HARDCODED 3-step ordinal — trainee <
        certified < senior (TIER_RANK below) — deliberately NOT a Config
        table. Real K9 tiering is a small, fixed vocabulary; making it
        configurable would let an operator invent tier names no future
        Phase 2/3 gate could rank against, for no real benefit — 'an
        operator can hold the model in their head' ... argued directly
        against an open-ended list here."

    THAT ARGUMENT IS NOT DELETED. It is preserved verbatim, in place, in
    that file's own header, and even preserved as a literal, still-live
    DATA STRUCTURE — the original `TIER_RANK = { trainee = 1,
    certified = 2, senior = 3 }` table is kept, unchanged, as the LAST-
    RESORT FALLBACK this file's own accessors degrade to if THIS file is
    ever unavailable (see server/certifications.lua's own
    `IsKnownTierKeyOrLegacyFallback`/`GetTierOrdinalOrLegacyFallback`,
    added alongside this file). The reasoning was sound for the world it
    described — a small, permanently-fixed vocabulary nobody would ever
    need to extend — and stops applying, in full, the instant an owner
    with actual authority over this resource asks for the opposite: an
    operator-EXTENSIBLE list, editable at runtime, with per-tier granted
    capabilities. This is not a case of the earlier author being wrong;
    it is a requirement changing underneath a decision that was correct
    for the requirement it was made against. This file is that new
    requirement, built without pretending the old one was a mistake.

    ======================================================================
    WHAT THIS FILE OWNS
    ======================================================================

    THE TIER CATALOG: an ORDERED list of { key, label, ordinal,
    capabilities }, merged from two sources every time it is (re)built —
    Config.CertificationTiers (the DEFAULTS; owned by whoever owns
    config.lua) and the `k9_certification_tiers` /
    `k9_certification_tier_capabilities` database tables (the operator's
    RUNTIME EDITS, made from the K9 Command Tablet). THE DATABASE WINS —
    a DB row for a given `tier_key` completely overrides that key's
    config-supplied label/ordinal; a DB `deleted = 1` row (a TOMBSTONE,
    not a real row DELETE — see migration 0010's own header for exactly
    why a delete cannot be a real DELETE for a config-sourced key)
    excludes that key from the live catalog entirely, whether it
    originated in Config.CertificationTiers or was itself created
    entirely at runtime. See RefreshCertificationTierCatalog below for
    the exact merge algorithm.

    THE ACCESSORS THIS PASS EXTENDS server/certifications.lua's SEAM WITH
    (per this task's own explicit instruction to extend, not replace,
    GetCertificationTier/MeetsTierRequirement/HasSpecialization/
    QueryCertificationRecord/QueryActiveSpecializations): this file adds
    IsKnownCertificationTierKey/GetCertificationTierOrdinal/
    ListCertificationTiers/GetCertificationTierCapabilities/
    TierHasCapability. server/certifications.lua's own five accessors are
    UNCHANGED in name and signature; only their internal ordinal/
    known-key lookups now defer to this file's live catalog instead of a
    hardcoded table, behind a soft-dependency existence guard exactly
    like every other cross-file dependency in this resource.

    ======================================================================
    HAZARD 1 — EXISTING ROWS (compatibility with every already-deployed
    database)
    ======================================================================

    Migration 0006 shipped `k9_certifications.tier` as
    `VARCHAR(20) NOT NULL DEFAULT 'certified'`. Every real, already-
    running installation of this resource already has rows holding the
    literal strings 'trainee', 'certified', or 'senior' in that column,
    RIGHT NOW, with 'certified' specifically chosen at the time (per
    migration 0006's own header) to be the tier that "PRESERVES today's
    actual capability" for every pre-existing single-boolean-cert row.

    This file's default Config.CertificationTiers block (sent separately
    to whoever owns config.lua — see this pass's own hand-off note) keeps
    all three keys, at ordinals 1/2/3 respectively, with EMPTY default
    capability sets for all three. Empty is not a placeholder oversight —
    it is load-bearing: nothing anywhere in this resource, before or
    after this pass, gates any mechanic on a tier CAPABILITY (tier
    remains, exactly as server/certifications.lua's own header already
    stated, "an ordinal a future search.lua/combat.lua/defense.lua gate
    may opt into" — this pass does not add that gate). Shipping a
    non-empty default capability set here would be inventing new default
    BEHAVIOR no version of this resource has ever had. Net effect: an
    operator who never opens the tablet, on a brand-new install or an
    existing one, sees ZERO behavior change — the merged catalog is
    byte-for-byte the same three keys/ordinals/empty-capabilities either
    way.

    Defensively (not merely by convention): BuildCatalogFromConfigDefaults
    below REJECTS a Config.CertificationTiers that is missing, malformed,
    or missing a 'certified' entry, and falls back to LEGACY_TIER_DEFAULTS
    (the same three keys/ordinals, hardcoded in THIS file) rather than
    letting a config mistake strand every existing certified handler.
    RefreshCertificationTierCatalog additionally re-injects a hardcoded
    'certified' entry if it is ever somehow still missing after the full
    merge (should be unreachable given DeleteTier's own unconditional
    'certified' protection below, but this file does not assume its own
    other safeguards never fail).

    ======================================================================
    HAZARD 2 — A DELETED TIER WITH ROWS STILL POINTING AT IT
    ======================================================================

    DECISION: REFUSE the deletion outright while ANY k9_certifications row
    (active OR historical/inactive — checked with no `active = 1` filter,
    since an inactive row still holds a real, audit-trail-relevant tier
    value that must not start pointing at nothing) references the tier
    key. This resource does NOT fail such rows closed to the lowest tier
    as the alternative the owner's brief also offered — refusing is
    chosen because silently rewriting a historical row's tier value would
    corrupt an audit trail this resource treats as append-only/immutable
    everywhere else (k9_certifications' own revoke history, this file's
    own k9_certification_tier_audit), for a problem refusal already
    solves with no data mutation at all.

    Consequence of "refuse while referenced": a tier key that has EVER
    been assigned to even one citizenid, ever, can never be deleted again
    — permanently. Documented, not hidden: DeleteTier's own doc comment
    states this plainly. An operator who wants a tier gone from FUTURE
    grants without deleting it has no such "retire but don't delete"
    concept in this pass — SetCertificationTier itself simply won't
    accept an already-deleted key as a NEW target (IsKnownCertificationTierKey
    returns false for a tombstoned key), so the only way to make a
    referenced tier fully disappear is to first move every citizenid off
    it (via SetCertificationTier) and then delete it — the same
    two-step an operator would need under a "reassign, then remove"
    model, without this file inventing bulk-reassignment machinery no one
    asked for.

    ADDITIONALLY, UNCONDITIONALLY, REGARDLESS OF REFERENCE COUNT: the
    literal key 'certified' can never be deleted through this surface, at
    all, ever — see PROTECTED_TIER_KEYS below. This is NOT the same
    protection as the reference-count check: 'certified' is the literal
    string baked into migration 0006's `DEFAULT 'certified'` clause AND
    into server/certifications.lua's own GrantCertification INSERT
    (which relies on that same DB default and is deliberately never
    edited to accept a tier argument — see that file's own header
    "TIER"). Even a 'certified' tier with ZERO current references could
    be deleted by reference-count alone, yet the very next
    GrantCertification call would silently create a BRAND NEW row
    referencing a tier that no longer exists — the exact hazard this
    whole feature must never produce, arising from a place the reference
    count could never see coming. Hardcoded, not merely reference-
    checked, for exactly that reason.

    Net result: no live, reachable k9_certifications row can ever
    reference a tier key absent from the merged catalog, under any
    ordering of operations this file allows.

    ======================================================================
    HAZARD 3 — REORDERING CHANGES HISTORY RETROACTIVELY
    ======================================================================

    ReorderTiers below REFUSES a partial reorder outright (the submitted
    key list must be an EXACT permutation of every currently-known,
    non-tombstoned tier key — no missing key, no extra key, no
    duplicate) rather than guessing what to do with an omitted tier's
    ordinal. Every successful reorder response includes a non-optional
    `warning` string, in the actual server response (not merely logged),
    stating plainly that every citizenid already holding one of the
    reordered tiers is now ranked at its NEW position immediately —
    GetCertificationTierOrdinal/MeetsTierRequirement/TierHasCapability all
    read the LIVE catalog on every call; none of them pin to whatever
    ordinal was in effect at the moment a citizenid was actually granted
    that tier. The tablet is expected to surface this warning prominently
    (coordinated with the tablet-UI owner separately) — this file
    guarantees the warning text exists and is accurate; it does not
    control how loudly the NUI displays it. Every reorder is additionally
    written to k9_certification_tier_audit as one row (`action =
    'tier_reorder'`, `tier_key = 'ALL'`) with the full before/after
    ordinal listing in `detail` — "say what you did", permanently, not
    just in the moment.

    ======================================================================
    HAZARD 4 — PRIVILEGE ESCALATION (THE ONE THAT MATTERS MOST)
    ======================================================================

    THREAT MODEL, STATED EXPLICITLY: the adversary is an authenticated
    in-game player who currently qualifies as IsHighCommand (a real,
    intended trust level in this resource — see server/highcommand.lua),
    attempting to use the tier-editing surface to grant a tier (their own
    current one, or one they could move themselves or an ally to via
    SetCertificationTier) a capability that exceeds what high command
    itself is unconditionally allowed to do, OR to have that capability
    interpreted, now or by some future consumer, as equivalent to
    granting a PERMISSION (server/permissions.lua's k9_permissions layer)
    or to BECOMING high command. A secondary adversary is a compromised/
    malicious NUI or client sending a forged `source`/authorization claim
    directly to one of this file's lib.callback endpoints, bypassing the
    tablet UI entirely.

    DEFENSE AGAINST THE SECOND ADVERSARY: every one of this file's FOUR
    mutating-or-listing callbacks calls CanManageCertTiers(source) as its
    OWN first action, which itself calls the real, live
    IsHighCommand(source) — server-side, against `source`'s CURRENT
    PlayerData/job/grade at the moment of the call, every single call, no
    caching, no trusting any flag/value the NUI payload itself carries.
    There is no code path in this file that reads an authorization
    decision from the CLIENT rather than re-deriving it server-side. A
    forged callback invocation with an arbitrary `source` still resolves
    through the real qbx_core player object for THAT connection, which an
    attacker does not control — this is the same "the client only offers
    a convenience, the server is the only authority" posture this
    resource enforces everywhere else (see server/certifications.lua's
    own SPEC.md §4.3 quote).

    DEFENSE AGAINST THE FIRST ADVERSARY (the actual privilege-escalation
    surface, structurally, not merely procedurally): CAPABILITY_CATALOG
    below is a FIXED, CODE-OWNED, CLOSED vocabulary — five capability
    keys, none of them editable at runtime, none of them addable via
    config.lua either (this catalog is a `local` Lua table in THIS file,
    not a Config.* value at all, deliberately — an operator with server
    file access could edit config.lua, but even that operator cannot
    invent a new capability key without a real code change to this file).
    High command's editing power over capabilities is SCOPED, BY
    CONSTRUCTION, to toggling MEMBERSHIP in this already-fixed,
    already-code-reviewed set — never to inventing a new capability
    string, and never to associating a tier with anything outside this
    list. The actual safety property this buys: NONE of the five entries
    in CAPABILITY_CATALOG, as shipped in this pass, map to "grant a
    permission", "become high command", "bypass IsHighCommand", or "edit
    the tier system itself" — those remain governed EXCLUSIVELY by their
    own separate, pre-existing, non-tier-based checks
    (server/permissions.lua's own Config.Permissions catalog +
    HasPermission/GrantPermission, and server/highcommand.lua's own
    grade-based IsHighCommand) which this file does not touch, does not
    read, and does not make tier-editable in any way. Concretely, as of
    this pass, EVERY capability in the catalog is INERT — no gate
    anywhere in this codebase currently calls TierHasCapability at all
    (mirrors server/certifications.lua's own pre-existing "tier is an
    ordinal a future file may opt into" posture for MeetsTierRequirement)
    — so today, granting or revoking any of them changes precisely
    nothing observable. This is deliberate, not a placeholder to be
    embarrassed about: it means the WORST CASE of every single edit this
    surface currently allows is "the tablet displays a different set of
    checkboxes for a tier" — there is no path, today, from this file's
    own code to a real capability change of any kind, let alone an
    escalating one.

    THE HONEST BOUNDARY OF WHAT THIS PASS CAN GUARANTEE, STATED
    EXPLICITLY: this file cannot retroactively guarantee the safety of a
    FUTURE consumer that chooses to wire a real gate to
    TierHasCapability(key, 'some_future_capability') — that responsibility
    belongs to whoever adds that consumer, and to CAPABILITY_CATALOG's own
    reviewers at the point a new entry is proposed for it (a genuine code
    change, reviewed like any other, never an in-game action). What this
    file DOES guarantee, permanently, by construction: the SET of
    capability strings that can ever be associated with a tier is closed
    and code-owned, never open-ended/free-text, so no future consumer can
    ever be surprised by an capability key nobody wrote code to define.

    THE DELETE-VS-ASSIGN RACE (found and closed this pass, not merely
    disclosed): a naive "check reference count, then tombstone" DeleteTier
    and a naive "check known-key, then UPDATE" SetCertificationTier (in
    server/certifications.lua) can interleave across their own
    MySQL.await yield points — DeleteTier's reference-count read could
    observe zero references an instant before a concurrent
    SetCertificationTier commits a BRAND NEW reference to that exact key,
    after which DeleteTier's own tombstone write would still proceed,
    producing exactly the "row referencing a tier that no longer exists"
    outcome this feature must never produce. Closed with `TierEditMutex`
    (NewMutex(), keyed by tier_key, exposed as a bare global specifically
    so server/certifications.lua's SetCertificationTier can acquire the
    SAME lock before its own UPDATE — see that function's own updated
    comment) — DeleteTier and SetCertificationTier now serialize on the
    same tier_key, so whichever acquires first completes its ENTIRE
    check-then-write critical section before the other can begin.
    UpsertTier/ReorderTiers acquire the same per-key mutex around their
    own writes for the identical reason (a concurrent rename/capability
    edit or reorder-write racing a delete/restore for the same key).
    Guarded everywhere it is CONSUMED (server/certifications.lua) with a
    `type(TierEditMutex) == 'table'` runtime existence check, this
    resource's established soft-dependency convention — SetCertificationTier
    still functions, accepting only the narrow, now-explicitly-disclosed
    pre-existing race, if this file is ever removed.

    "MUST NEVER GRANT ITSELF MORE": high command's OWN effective
    authority (IsHighCommand's own grade-based check) is never read from,
    written to, or influenced by anything in this file — there is no
    mechanic anywhere in this file, or in the capability catalog it
    exposes, that can raise a citizenid's OWN job grade, grant them the
    'k9.certify'/'k9.access'/any other k9_permissions key, or otherwise
    widen what IsHighCommand or HasPermission would independently decide
    about them. Editing a tier's label/ordinal/capability set never
    touches any player's job/grade/permission-grant row.

    ======================================================================
    HAZARD 5 — NO UNBOUNDED TRAP
    ======================================================================

    Nothing in this file gates, and nothing in this pass's edit to
    server/certifications.lua's SetCertificationTier gates, any
    termination/cleanup path (EndActiveEffectForHolder, leash detach,
    Recall, partnership break, etc.) — this file introduces no new gate
    on any of those at all. This is not merely a "we were careful" claim:
    it follows structurally from the fact that tier itself STILL gates
    NOTHING in this codebase's own action paths (see "DEFENSE AGAINST THE
    FIRST ADVERSARY" above — every capability is inert), and
    SetCertificationTier's pre-existing behavior (confirmed unchanged by
    this pass, re-read before writing this file) never force-detaches
    anything even on an ordinary tier CHANGE, let alone a tier DELETION —
    server/certifications.lua's own EXPIRY design note already establishes
    the precedent this follows: "an already-formed leash/partnership/
    in-progress action is untouched" by a passive/administrative tier
    change. Deleting or downgrading the tier out from under someone
    mid-action therefore cannot interrupt that action, because nothing in
    this resource ever wired tier into an action's continuation check in
    the first place — there is no trap to build here, and this pass does
    not add one.

    ======================================================================
    CONCURRENT-ADD ORDINAL TIE (disclosed, non-security-relevant, minor
    limitation left in place)
    ======================================================================

    UpsertTier assigns a brand-new (or being-restored) tier's ordinal as
    "current max ordinal across the live catalog, plus one", computed
    from the in-memory TierByKey snapshot at the moment of the call, NOT
    inside the same atomic statement as the write. Two DIFFERENT new tier
    keys created in the same instant by two concurrent high-command
    sessions could therefore both compute the same "next" ordinal and end
    up tied. A tie is a fully safe, non-crashing, non-escalating outcome
    (GetCertificationTierOrdinal's `>=` comparison simply treats the two
    as equal rank) — resolved the next time anyone runs ReorderTiers, or
    by re-upserting one of the two tiers. Not mitigated further: closing
    this fully would need a single atomic "compute-next-and-insert" SQL
    statement across a catalog that is PARTLY sourced from config.lua
    (which has no row in this database at all) — disproportionate
    engineering for a display-ordering nicety, unlike the delete-vs-assign
    race above, which risked a real invariant (no dangling tier
    reference), not merely a display tie.
]]

-- ======================================================================
-- LEGACY FALLBACK — the ORIGINAL server/certifications.lua TIER_RANK
-- table, preserved here (not merely in a comment) as LEGACY_TIER_DEFAULTS,
-- the built-in floor BuildCatalogFromConfigDefaults falls back to if
-- Config.CertificationTiers is ever missing/malformed. See header
-- "HAZARD 1" above.
-- ======================================================================
local LEGACY_TIER_DEFAULTS = {
    { key = 'trainee',   label = 'Trainee',   ordinal = 1, capabilities = {} },
    { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} },
    { key = 'senior',    label = 'Senior',    ordinal = 3, capabilities = {} },
}

-- ======================================================================
-- CAPABILITY_CATALOG — fixed, code-owned, CLOSED vocabulary. See header
-- "HAZARD 4" for the full threat-model writeup this table's own existence
-- depends on. NOT a Config.* value, deliberately — adding a new entry
-- here is a real code change, reviewed like any other, never an in-game
-- or config.lua action. Every entry is currently INERT (no gate anywhere
-- in this codebase reads TierHasCapability yet) — see header for why
-- that is deliberate, not an oversight.
-- ======================================================================
local CAPABILITY_CATALOG = {
    specializations_eligible = {
        label = 'Eligible to hold K9 specializations (narcotics/explosives/patrol)',
    },
    advanced_tracking = {
        label = 'Advanced tracking (reserved -- no gate in this resource currently checks this)',
    },
    bite_hold_and_takedown = {
        label = 'Bite & Hold / Non-Lethal Takedown (reserved -- no gate in this resource currently checks this)',
    },
    mentor_trainees = {
        label = 'May mentor/supervise trainee-tier handlers (reserved -- no gate in this resource currently checks this)',
    },
    specialized_equipment_access = {
        label = 'Access to specialized K9 equipment shop items (reserved -- no gate in this resource currently checks this)',
    },
}

-- Hardcoded, unconditional -- see header "HAZARD 2". Deletable status is
-- NOT determined by reference count alone for this one key; see
-- DeleteTier below for exactly why.
local PROTECTED_TIER_KEYS = { certified = true }

-- Defensive cap on total live (non-tombstoned) tier count -- an
-- already-authenticated high-command account is a highly trusted actor,
-- but an unbounded catalog is still an unforced footgun (e.g. a stuck
-- tablet retry loop hammering create with a new key each time). Well
-- above any real operator's plausible tier count.
local MAX_TIERS = 40

-- Live, in-memory catalog state -- rebuilt wholesale by
-- RefreshCertificationTierCatalog below, never partially mutated in
-- place. Declared here (before every function that closes over them) so
-- every reference below is a proper upvalue, not an accidental global --
-- same discipline server/certifications.lua's own `local Certifications`/
-- `local Specializations` tables already establish.
-- Not initialized to `{}` here -- both are populated for real a few
-- lines down (the "Initial SYNCHRONOUS population" block) before
-- anything ever reads either one, so an intermediate `{}` here would
-- just be dead-written-over state (flagged, correctly, by luacheck).
local TierByKey
local TierOrder

--- @param list any
--- @return boolean
local function IsValidStaticTierDefaultsList(list)
    if type(list) ~= 'table' then return false end
    local seenKeys, seenCertified = {}, false
    for _, entry in ipairs(list) do
        if type(entry) ~= 'table'
            or type(entry.key) ~= 'string' or entry.key == ''
            or type(entry.label) ~= 'string' or entry.label == ''
            or type(entry.ordinal) ~= 'number' then
            return false
        end
        if seenKeys[entry.key] then return false end
        seenKeys[entry.key] = true
        if entry.key == 'certified' then seenCertified = true end
    end
    -- 'certified' MUST be present -- see header "HAZARD 1".
    return seenCertified
end

--- Builds a fresh key -> {label, ordinal, capabilities} map from
--- Config.CertificationTiers, falling back to LEGACY_TIER_DEFAULTS on any
--- shape problem. Does NOT consult the database -- see
--- RefreshCertificationTierCatalog for the merge step that layers runtime
--- overrides on top of this.
--- @return table<string, table>
local function BuildCatalogFromConfigDefaults()
    local source = Config.CertificationTiers
    if not IsValidStaticTierDefaultsList(source) then
        print('[qbx_k9unit] certtiers: Config.CertificationTiers is missing, malformed, or missing a ' ..
            '\'certified\' entry -- falling back to the built-in legacy defaults (trainee=1/certified=2/' ..
            'senior=3) so every existing k9_certifications row (which may hold any of those three literal ' ..
            'strings, per migration 0006\'s own DEFAULT) keeps resolving to a real tier. Fix ' ..
            'Config.CertificationTiers in config.lua.')
        source = LEGACY_TIER_DEFAULTS
    end

    local map = {}
    for _, entry in ipairs(source) do
        local capabilities = {}
        if type(entry.capabilities) == 'table' then
            for capKey, granted in pairs(entry.capabilities) do
                if granted == true and CAPABILITY_CATALOG[capKey] then
                    capabilities[capKey] = true
                end
            end
        end
        map[entry.key] = { label = entry.label, ordinal = entry.ordinal, capabilities = capabilities }
    end
    return map
end

--- Fail-closed query wrapper -- pcall around MySQL.query.await, matching
--- server/runtimecontrol.lua's/server/admin.lua's own SafeQuery. A failed
--- read returns an empty table, never a raw Lua error.
--- @param sql string
--- @param params table
--- @return table rows
local function SafeQuery(sql, params)
    local ok, rowsOrErr = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] certtiers.lua query failed: %s'):format(tostring(rowsOrErr)))
        return {}
    end
    return rowsOrErr or {}
end

--- pcall-wrapped write helper -- returns true/false rather than throwing,
--- prints on failure. Every write in this file is a plain
--- INSERT/UPDATE/DELETE with `?`-bound parameters only, never a
--- caller-controlled fragment.
--- @param sql string
--- @param params table
--- @return boolean ok
local function SafeWrite(sql, params)
    local ok, err = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] certtiers.lua write failed: %s'):format(tostring(err)))
        return false
    end
    return true
end

--- Rebuilds `TierByKey`/`TierOrder` from Config.CertificationTiers merged
--- with the current `k9_certification_tiers` /
--- `k9_certification_tier_capabilities` database state -- THE DATABASE
--- WINS per key (see header). Called once at this file's own
--- onResourceStart (see bottom of this file) and again after every
--- successful mutation (Upsert/Reorder/Delete) so a caller's own response
--- (and any other in-flight reader) sees the true new state immediately,
--- never a stale one.
local function RefreshCertificationTierCatalog()
    local merged = BuildCatalogFromConfigDefaults()

    local overrideRows = SafeQuery('SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers', {})
    for _, row in ipairs(overrideRows) do
        if row.deleted == 1 or row.deleted == true then
            -- TOMBSTONE: exclude entirely, whether this key originated in
            -- Config.CertificationTiers or was created purely at runtime.
            -- See migration 0010's own header "WHY A TOMBSTONE" for why
            -- this is the ONE code path handling both cases.
            merged[row.tier_key] = nil
        else
            merged[row.tier_key] = {
                label = row.label,
                ordinal = tonumber(row.ordinal) or 0,
                capabilities = {}, -- filled in below
            }
        end
    end

    -- Capability rows for an already-excluded (tombstoned) tier_key are
    -- simply never attached to anything here -- inert dead weight, not
    -- cleaned up, per migration 0010's own header.
    local capRows = SafeQuery('SELECT tier_key, capability_key FROM k9_certification_tier_capabilities', {})
    for _, row in ipairs(capRows) do
        local entry = merged[row.tier_key]
        if entry and CAPABILITY_CATALOG[row.capability_key] then
            entry.capabilities[row.capability_key] = true
        end
    end

    -- FAIL-SAFE (header "HAZARD 1"): should be unreachable through this
    -- file's own DeleteTier (PROTECTED_TIER_KEYS unconditionally refuses
    -- 'certified'), reachable only via a hand-edited database. Never let
    -- that silently strand every existing k9_certifications row with
    -- tier='certified' pointing at nothing.
    if not merged['certified'] then
        print('[qbx_k9unit] certtiers: \'certified\' tier missing from the merged catalog after refresh -- ' ..
            'reinstating the built-in default. This resource\'s own DeleteTier unconditionally refuses to ' ..
            'ever tombstone \'certified\' -- seeing this means k9_certification_tiers was edited outside this ' ..
            'resource\'s own code path.')
        merged['certified'] = { label = 'Certified', ordinal = 2, capabilities = {} }
    end

    local order = {}
    for key in pairs(merged) do order[#order + 1] = key end
    table.sort(order, function(a, b)
        if merged[a].ordinal ~= merged[b].ordinal then return merged[a].ordinal < merged[b].ordinal end
        return a < b -- stable, deterministic tie-break -- see header "CONCURRENT-ADD ORDINAL TIE"
    end)

    TierByKey = merged
    TierOrder = order
end

-- Initial SYNCHRONOUS population from config defaults ONLY, at this
-- file's own load time -- config.lua is a shared_script, loaded in full
-- before any server_scripts file (this one included) starts executing,
-- so Config already holds its real, final values by the time this line
-- runs (same reasoning server/certifications.lua's own K9ModelHashes
-- precomputation gives for the identical structural point). This makes
-- every accessor below safe to call even before onResourceStart fires
-- for this resource, at the cost of not yet reflecting any DB override --
-- the onResourceStart handler at the bottom of this file layers the
-- database on top a moment later, before any player action could
-- plausibly reach a tier check.
TierByKey = BuildCatalogFromConfigDefaults()
do
    local order = {}
    for key in pairs(TierByKey) do order[#order + 1] = key end
    table.sort(order, function(a, b) return TierByKey[a].ordinal < TierByKey[b].ordinal end)
    TierOrder = order
end

-- ======================================================================
-- PUBLIC READ ACCESSORS -- exposed globally (no `local`), extending the
-- SAME seam server/certifications.lua's own GetCertificationTier/
-- MeetsTierRequirement/HasSpecialization/QueryCertificationRecord/
-- QueryActiveSpecializations already established, per this task's own
-- explicit "extend, not replace" instruction. Every one of these is a
-- read, never a write, and every one is hot-path-safe (cache-based, no
-- query) except where noted.
-- ======================================================================

--- @param key any
--- @return boolean
function IsKnownCertificationTierKey(key)
    return type(key) == 'string' and TierByKey[key] ~= nil
end

--- @param key any
--- @return number?
function GetCertificationTierOrdinal(key)
    local entry = type(key) == 'string' and TierByKey[key]
    return entry and entry.ordinal or nil
end

--- Ordered (by ordinal ascending) snapshot of the live catalog -- a COPY,
--- not the live tables, so a caller (the tablet aggregation layer, or any
--- future consumer) cannot mutate this file's own authoritative state by
--- editing the returned value.
--- @return table[] -- { { key, label, ordinal, capabilities: table<string,true> }, ... }
function ListCertificationTiers()
    local list = {}
    for _, key in ipairs(TierOrder) do
        local entry = TierByKey[key]
        local capsCopy = {}
        for capKey in pairs(entry.capabilities) do capsCopy[capKey] = true end
        list[#list + 1] = { key = key, label = entry.label, ordinal = entry.ordinal, capabilities = capsCopy }
    end
    return list
end

--- @param key any
--- @return table<string, true> -- a COPY; {} for an unknown key, never nil
function GetCertificationTierCapabilities(key)
    local entry = type(key) == 'string' and TierByKey[key]
    local copy = {}
    if entry then
        for capKey in pairs(entry.capabilities) do copy[capKey] = true end
    end
    return copy
end

--- @param key any
--- @param capabilityKey any
--- @return boolean
function TierHasCapability(key, capabilityKey)
    if type(capabilityKey) ~= 'string' then return false end
    local entry = type(key) == 'string' and TierByKey[key]
    return entry ~= nil and entry.capabilities[capabilityKey] == true
end

-- ======================================================================
-- AUTHORIZATION -- re-verified on EVERY call, never cached. See header
-- "HAZARD 4".
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- Server-authoritative, re-resolved fresh on every call -- never cached,
--- never trusts a client-supplied flag. Deliberately IsHighCommand ONLY
--- -- no HasPermission-based delegation, unlike
--- server/runtimecontrol.lua's CanManageRuntimeControl/CanManageTabletTheme
--- (which also accept a granted 'k9.runtimecontrol'/'k9.tablettheme'
--- permission). This is a deliberate, disclosed scope decision: the
--- owner's own words for THIS feature name "high command" specifically, a
--- plain rank check, and adding a new delegable Config.Permissions key
--- would need config.lua owner sign-off this pass did not request. A
--- follow-up pass can widen this to also accept a 'k9.certtiers' grant
--- the same way runtime control does, if the team wants that -- tracked
--- here, not silently done.
--- @param source number
--- @return boolean authorized, string? citizenid
local function CanManageCertTiers(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    return false, citizenid
end

-- Cross-file critical-section lock, keyed by tier_key -- NOT a player
-- source, so deliberately no :RegisterPlayerDropped() call (same
-- reasoning server/cooldowns.lua's own header gives for MedkitMutex/
-- PartnershipEstablishMutex, both keyed by something other than a player
-- source). Exposed as a bare global (no `local`) specifically so
-- server/certifications.lua's SetCertificationTier can acquire the SAME
-- lock before writing a tier assignment -- see header "HAZARD 4", "THE
-- DELETE-VS-ASSIGN RACE" for exactly which race this closes.
TierEditMutex = NewMutex()

-- Anti-fat-finger/double-submit rate limit, keyed by the ACTING officer's
-- own source -- mirrors server/runtimecontrol.lua's
-- RuntimeControlActionCooldown exactly. Every caller reaching this point
-- is already confirmed high command by CanManageCertTiers above; this
-- guards against a held key or a double-submitted click, not abuse.
local CERT_TIER_ACTION_COOLDOWN_MS = 1000
local CertTierActionCooldown = NewCooldown(CERT_TIER_ACTION_COOLDOWN_MS)
CertTierActionCooldown.RegisterPlayerDropped()

--- @param action string
--- @param tierKey string
--- @param detail string
--- @param changedBy string
local function WriteTierAudit(action, tierKey, detail, changedBy)
    SafeWrite(
        'INSERT INTO k9_certification_tier_audit (action, tier_key, detail, changed_by) VALUES (?, ?, ?, ?)',
        { action, tierKey, detail, changedBy or 'unknown' }
    )
end

-- ======================================================================
-- VALIDATION -- every field a tablet payload can influence is validated
-- server-side before it ever reaches a query, matching this resource's
-- established "treat every inbound payload as adversarial" posture.
-- ======================================================================

--- 2-30 chars, lowercase-start, lowercase/digit/underscore only --
--- comfortably inside k9_certification_tiers.tier_key's VARCHAR(32) and
--- k9_certifications.tier's VARCHAR(20) (migration 0006) alike, so a
--- valid new key can always actually be written to BOTH tables. Lua
--- patterns have no `{n,m}` quantifier -- length is checked separately,
--- not via the pattern itself.
--- @param key any
--- @return boolean
local function IsValidTierKey(key)
    if type(key) ~= 'string' then return false end
    local len = #key
    if len < 2 or len > 20 then return false end
    return key:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- Character filter mirroring server/runtimecontrol.lua's own
--- IsSafeHeaderTitle -- defense in depth on top of the tablet's own
--- textContent-only rendering discipline, not a substitute for it. <=60
--- chars (matches k9_certification_tiers.label's own VARCHAR(60)).
--- @param value any
--- @return boolean
local function IsValidTierLabel(value)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > 60 then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

--- Accepts an ARRAY of capability-key strings (the shape a tablet
--- checkbox list naturally serializes to) or nil (-> no capabilities).
--- Rejects the WHOLE input on ANY unrecognized capability key or wrong
--- shape, rather than silently dropping the bad entries -- a
--- partially-applied edit the caller might misread as fully applied is
--- worse than an outright, explicit refusal. See header "HAZARD 4" for
--- why CAPABILITY_CATALOG is the only vocabulary this can ever produce
--- membership in.
--- @param input any
--- @return boolean ok, table<string, true>? set
local function NormalizeCapabilitiesInput(input)
    if input == nil then return true, {} end
    if type(input) ~= 'table' or #input > 32 then return false, nil end
    local set = {}
    for _, capKey in ipairs(input) do
        if type(capKey) ~= 'string' or not CAPABILITY_CATALOG[capKey] then
            return false, nil
        end
        set[capKey] = true
    end
    return true, set
end

--- @return table<string, table> -- { [capabilityKey] = { label = string } }
local function PublicCapabilityCatalog()
    local copy = {}
    for key, def in pairs(CAPABILITY_CATALOG) do
        copy[key] = { label = def.label }
    end
    return copy
end

-- ======================================================================
-- CALLBACKS -- all four re-verify CanManageCertTiers(source) as their own
-- first action (see header "HAZARD 4"). Response shape mirrors
-- server/runtimecontrol.lua's own `{ ok, reason, ... }` convention
-- exactly, for consistency across this resource's tablet-facing surfaces.
-- ======================================================================

lib.callback.register('qbx_k9unit:server:certTiersList', function(source)
    local authorized = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end
    return { ok = true, tiers = ListCertificationTiers(), capabilityCatalog = PublicCapabilityCatalog() }
end)

lib.callback.register('qbx_k9unit:server:certTiersUpsert', function(source, payload)
    local authorized, citizenid = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not CertTierActionCooldown.Consume(source, CERT_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(payload) ~= 'table' or type(payload.key) ~= 'string' then
        return { ok = false, reason = 'invalid_payload' }
    end

    local key = payload.key
    if not IsValidTierKey(key) then
        return { ok = false, reason = 'invalid_key' }
    end
    if not IsValidTierLabel(payload.label) then
        return { ok = false, reason = 'invalid_label' }
    end

    local capsOk, capsSet = NormalizeCapabilitiesInput(payload.capabilities)
    if not capsOk then
        return { ok = false, reason = 'invalid_capabilities' }
    end

    if not TierEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    -- `existing` is nil both for a genuinely brand-new key AND for one
    -- currently tombstoned (TierByKey excludes tombstoned keys entirely)
    -- -- `priorRow` below (a direct DB read, ignoring the tombstone
    -- filter) is what actually distinguishes "create" from "restore" for
    -- the audit trail.
    local existing = TierByKey[key]
    local isNewOrRestoring = existing == nil

    if isNewOrRestoring then
        local liveCount = 0
        for _ in pairs(TierByKey) do liveCount = liveCount + 1 end
        if liveCount >= MAX_TIERS then
            TierEditMutex.Release(key)
            return { ok = false, reason = 'too_many_tiers' }
        end
    end

    local ordinal
    if isNewOrRestoring then
        -- Append at the end -- both for a genuinely new key and for one
        -- being restored from a tombstone (a restore does not attempt to
        -- reclaim its old position -- see header "WHY A TOMBSTONE" in
        -- migration 0010).
        local maxOrdinal = 0
        for _, entry in pairs(TierByKey) do
            if entry.ordinal > maxOrdinal then maxOrdinal = entry.ordinal end
        end
        ordinal = maxOrdinal + 1
    else
        -- Editing an already-live tier: ordinal is untouched here. The
        -- ONLY way to change an existing tier's ordinal is ReorderTiers
        -- below -- see header "HAZARD 3".
        ordinal = existing.ordinal
    end

    local priorRow = SafeQuery('SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?', { key })[1]

    local wrote = SafeWrite(
        'INSERT INTO k9_certification_tiers (tier_key, label, ordinal, deleted, updated_by) VALUES (?, ?, ?, 0, ?) ' ..
        'ON DUPLICATE KEY UPDATE label = VALUES(label), ordinal = VALUES(ordinal), deleted = 0, ' ..
        'updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
        { key, payload.label, ordinal, citizenid or 'unknown' }
    )
    if not wrote then
        TierEditMutex.Release(key)
        return { ok = false, reason = 'db_error' }
    end

    -- Reconcile capability grants to EXACTLY the requested set. Safe to
    -- read the DB fresh here (rather than trust the in-memory cache):
    -- TierEditMutex is held for this key for this entire critical
    -- section, so nothing else touching THIS key's capability rows can
    -- have interleaved since this callback started.
    local currentCapRows = SafeQuery('SELECT capability_key FROM k9_certification_tier_capabilities WHERE tier_key = ?', { key })
    local currentCapSet = {}
    for _, row in ipairs(currentCapRows) do currentCapSet[row.capability_key] = true end

    local added, removed = {}, {}
    for capKey in pairs(capsSet) do
        if not currentCapSet[capKey] then
            added[#added + 1] = capKey
            SafeWrite('INSERT INTO k9_certification_tier_capabilities (tier_key, capability_key, granted_by) VALUES (?, ?, ?)',
                { key, capKey, citizenid or 'unknown' })
        end
    end
    for capKey in pairs(currentCapSet) do
        if not capsSet[capKey] then
            removed[#removed + 1] = capKey
            SafeWrite('DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND capability_key = ?', { key, capKey })
        end
    end

    TierEditMutex.Release(key)

    local action
    if not isNewOrRestoring then
        action = 'tier_update'
    elseif priorRow ~= nil and (priorRow.deleted == 1 or priorRow.deleted == true) then
        action = 'tier_restore'
    else
        action = 'tier_create'
    end

    WriteTierAudit(action, key,
        ('label=%q ordinal=%d capabilities_added=[%s] capabilities_removed=[%s]'):format(
            payload.label, ordinal, table.concat(added, ','), table.concat(removed, ',')),
        citizenid or 'unknown')

    RefreshCertificationTierCatalog()

    return { ok = true, tiers = ListCertificationTiers(), capabilityCatalog = PublicCapabilityCatalog() }
end)

lib.callback.register('qbx_k9unit:server:certTiersReorder', function(source, orderedKeys)
    local authorized, citizenid = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not CertTierActionCooldown.Consume(source, CERT_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(orderedKeys) ~= 'table' or #orderedKeys > MAX_TIERS then
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Must be EXACTLY a permutation of every currently-known
    -- (non-tombstoned) tier key -- see header "HAZARD 3": no partial
    -- reorder, ever.
    local currentKeys, expectedCount = {}, 0
    for key in pairs(TierByKey) do
        currentKeys[key] = true
        expectedCount = expectedCount + 1
    end

    local seen, cleanOrder = {}, {}
    for _, key in ipairs(orderedKeys) do
        if type(key) ~= 'string' or not currentKeys[key] or seen[key] then
            return { ok = false, reason = 'invalid_key_set' }
        end
        seen[key] = true
        cleanOrder[#cleanOrder + 1] = key
    end
    if #cleanOrder ~= expectedCount then
        return { ok = false, reason = 'must_include_every_tier' }
    end

    local beforeParts = {}
    for _, key in ipairs(cleanOrder) do
        beforeParts[#beforeParts + 1] = ('%s=%d'):format(key, TierByKey[key].ordinal)
    end

    local afterParts = {}
    for index, key in ipairs(cleanOrder) do
        -- Per-key mutex, held only for THIS key's own write (not across
        -- the whole loop, to avoid serializing an entire reorder behind
        -- one held lock) -- see header "CONCURRENT-ADD ORDINAL TIE" /
        -- "THE DELETE-VS-ASSIGN RACE" for why this narrows (without fully
        -- eliminating) a concurrent single-tier edit racing this
        -- specific key's ordinal write. A busy key is skipped THIS pass
        -- (its ordinal is left unchanged) rather than blocking the rest
        -- of the reorder.
        if TierEditMutex.TryAcquire(key) then
            SafeWrite(
                'INSERT INTO k9_certification_tiers (tier_key, label, ordinal, deleted, updated_by) VALUES (?, ?, ?, 0, ?) ' ..
                'ON DUPLICATE KEY UPDATE ordinal = VALUES(ordinal), deleted = 0, updated_by = VALUES(updated_by), ' ..
                'updated_at = CURRENT_TIMESTAMP',
                { key, TierByKey[key].label, index, citizenid or 'unknown' }
            )
            TierEditMutex.Release(key)
        else
            print(('[qbx_k9unit] certtiers ReorderTiers: tier %s busy (concurrent edit) -- its ordinal was left unchanged this pass'):format(key))
        end
        afterParts[#afterParts + 1] = ('%s=%d'):format(key, index)
    end

    WriteTierAudit('tier_reorder', 'ALL',
        ('before=[%s] after=[%s]'):format(table.concat(beforeParts, ', '), table.concat(afterParts, ', ')),
        citizenid or 'unknown')

    RefreshCertificationTierCatalog()

    return {
        ok = true,
        tiers = ListCertificationTiers(),
        warning = 'Reordering tiers changes rank comparisons RETROACTIVELY: every citizenid already holding one ' ..
            'of these tiers is now ranked at its NEW position immediately. Tier-based checks read the current ' ..
            'catalog live -- they do not pin to the ordinal that was in effect when a certification was granted.',
    }
end)

lib.callback.register('qbx_k9unit:server:certTiersDelete', function(source, key)
    local authorized, citizenid = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not CertTierActionCooldown.Consume(source, CERT_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(key) ~= 'string' or not IsKnownCertificationTierKey(key) then
        return { ok = false, reason = 'unknown_tier' }
    end

    -- UNCONDITIONAL, checked BEFORE the reference-count read -- see header
    -- "HAZARD 2" for why 'certified' cannot rely on reference-count
    -- protection alone.
    if PROTECTED_TIER_KEYS[key] then
        return { ok = false, reason = 'protected_tier' }
    end

    if not TierEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    local countOk, refCountOrErr = pcall(MySQL.scalar.await, 'SELECT COUNT(*) FROM k9_certifications WHERE tier = ?', { key })
    if not countOk then
        TierEditMutex.Release(key)
        print(('[qbx_k9unit] certtiers DeleteTier reference-count read failed for %s: %s'):format(key, tostring(refCountOrErr)))
        return { ok = false, reason = 'db_error' }
    end

    local refCount = tonumber(refCountOrErr) or 0
    if refCount > 0 then
        TierEditMutex.Release(key)
        return { ok = false, reason = 'tier_in_use', referenceCount = refCount }
    end

    local entry = TierByKey[key]
    local wrote = SafeWrite(
        'INSERT INTO k9_certification_tiers (tier_key, label, ordinal, deleted, updated_by) VALUES (?, ?, ?, 1, ?) ' ..
        'ON DUPLICATE KEY UPDATE deleted = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
        { key, entry.label, entry.ordinal, citizenid or 'unknown' }
    )
    TierEditMutex.Release(key)

    if not wrote then
        return { ok = false, reason = 'db_error' }
    end

    WriteTierAudit('tier_delete', key,
        ('tier %s deleted (tombstoned) -- confirmed zero k9_certifications rows referenced it at the moment of deletion'):format(key),
        citizenid or 'unknown')

    RefreshCertificationTierCatalog()

    return { ok = true, tiers = ListCertificationTiers() }
end)

-- ======================================================================
-- BOOT -- layer the persisted DB overrides on top of config.lua's own
-- shipped defaults. Deferred to onResourceStart (not raw top-level --
-- MySQL/oxmysql readiness is not guaranteed at raw server_scripts
-- load-time), mirroring server/runtimecontrol.lua's own identical
-- "config-only defaults at file-load, DB layered on top at
-- onResourceStart" pattern exactly.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    RefreshCertificationTierCatalog()
end)
