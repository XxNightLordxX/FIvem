--[[
    qbx_k9unit/server/certifications.lua

    Phase 1 scaffold only (coder-architect). This file IS the permission
    system (DEVELOPER_REFERENCE.md hard requirement 2) — grant/revoke/check, the
    server-side cert cache, and the automatic revoke-on-job-change path.
    Keep it scoped to "who is allowed to use K9 features" only; misc
    small gated K9 actions (e.g. bark relay) live in server/main.lua so
    this file doesn't balloon as later phases add more of those.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1, REWRITTEN after DEVELOPER_REFERENCE.md's post-draft
    correction (K9 is a player's own persistent character, no spawn/despawn/
    registry concept at all — see DEVELOPER_REFERENCE.md §1, §2 "Explicit non-goals").
    This block is identical in every stub file it's relevant to, so
    coder-backend and coder-frontend can work in parallel without live
    coordination.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [THIS FILE]
       job.name ∈ Config.Departments AND active cert cached for that exact
       job (OR autoAccessGrade bypass). Per DEVELOPER_REFERENCE.md §4.1/§4.5: this is the
       ONLY access check, and it does NOT consider ped model at all — model
       is checked exclusively at grant time (§4.2 condition 5, below), not
       on every access. A certified handler who later isn't K9-modeled
       still passes this check (client-side display logic hides the UI for
       them anyway, see client/main.lua's IsOwnModelK9(); this is a known,
       spec-confirmed tradeoff, not a bug — flagged for coder-security to
       be aware of, not to "fix" unprompted).

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [THIS FILE]
       Grant flow per DEVELOPER_REFERENCE.md §4.2/§4.3 — re-validate granter eligibility,
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
        contract (DEVELOPER_REFERENCE.md §4.3 requires revocation to work on a target who
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

    Cross-cutting security rule (DEVELOPER_REFERENCE.md §3 + §4.3): every access point
    above must re-check server-side, independent of client claims. This is
    THE file coder-security should scrutinize hardest — see the explicit
    security note quoted from DEVELOPER_REFERENCE.md §4.3 below.
    ======================================================================

    DEVELOPER_REFERENCE.md §4.3 explicit security note (quoted): "every one of the
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
    request anymore. DEVELOPER_REFERENCE.md §4.1 has since been reworded ("checked
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
    - THIS FILE calls `ForceDetachLeashForSource(src, reason)` (server/main.lua),
      `EndActiveEffectForHolder(src)` (server/combat.lua, guarded), and
      `ForceBreakPartnershipForCitizenId(citizenid, reason)`
      (server/partnership.lua, Phase 3, DEVELOPER_REFERENCE.md §12.0 item
      7, guarded) — ALL THREE, ALWAYS TOGETHER — through this file's own
      LOCAL helper `EndK9AccessForCitizenId(citizenid, reason, knownSrc)`,
      defined once (above HasK9Access's own eligibility helpers) and
      called from every path that flips a citizenid's K9-role access to
      lost: RevokeCertification's online branch, RevokeCertificationOffline,
      and all THREE of the QBCore:Server:OnJobUpdate handler's branches —
      department-loss, the same-department autoAccessGrade-loss branch, and
      cert-revoke-due-to-job-change. CONSOLIDATION (this pass, cross-team
      "four doors, one bug" finding): this exact three-call sequence used
      to be reimplemented independently at each of those five call sites,
      which is why the "handler loses K9 access mid-incident and their dog
      keeps holding a suspect" bug kept being found and fixed one call site
      at a time — most recently the department-loss branch, which used to
      call ONLY ForceDetachOfficerLeashForSource (the officer/handler-role
      leash, a DIFFERENT invariant kept as its own direct call, never
      folded into this helper) and never this sequence at all, leaving a
      K9-role party whose only access route was autoAccessGrade or a
      server/permissions.lua 'k9.access' grant (no certification row) able
      to keep their leash/hold/partnership on leaving the department
      entirely — see that branch's own comment, and
      EndK9AccessForCitizenId's own doc comment, for the full writeup and
      why this is now the ONE place in this file meaning "citizenid has
      just, provably, lost K9-role access." server/permissions.lua's
      RevokePermission needs the identical sequence for its own
      'k9.access' de-assign path and keeps its OWN private, identically-
      shaped copy rather than sharing this one as a resource-global — see
      that file's own copy for why (in short: doing otherwise would need a
      new fxmanifest.lua server_scripts entry AND a new
      /home/user/FIvem/.luacheckrc globals entry, and this resource's own
      spec files load only the minimal file set each one's file-under-test
      needs). All three underlying calls stay guarded at
      `type(...) == 'function'` runtime existence checks (this resource's
      established "runtime existence guard, not a load-order assumption"
      convention — see fxmanifest.lua's own comment on server/medkit.lua's
      RestoreInjury reuse for the precedent), and are called UNCONDITIONALLY
      of Config.Features.HandlerPartnership's current value — a partnership
      row established while the feature was on must still be torn down by
      a cert revoke/department change even if the flag was later flipped
      off, since ForceBreakPartnershipForCitizenId is itself already a
      cheap, safe no-op when `citizenid` has no active partnership row to
      tear down.
    - THIS FILE owns `Certifications` (citizenid -> { active: boolean,
      job: string }) as a local table. STRUCTURAL NOTE: DEVELOPER_REFERENCE.md §4.3's
      prose describes this cache as a bare `Certifications[citizenid] =
      true|false`, but §4.4's auto-revoke handler needs to know WHICH job
      that boolean was scoped to (to tell "left the department" apart from
      "got promoted within it") — §4.3 and §4.4 are only reconcilable if
      the cache also tracks job. Decision: store `{ active, job }` instead
      of a bare boolean; it's a strict superset of what §4.3 asked for and
      avoids a second parallel cache that could drift out of sync.

    ======================================================================
    CERTIFICATION DEPTH (this pass) — DEVELOPER_REFERENCE.md Part A §2 (revoke
    reason), §5 (tiered certification), §9 (expiry/recertification), and
    Part B §11 (specializations). These four are ONE coherent change: they
    all reshape "certified" from a boolean into something with a level
    (tier), a scope (specializations), and a lifetime (expiry), on top of
    an unchanged deeper audit trail (revoke_reason). Schema: migration
    0006 (sql/migrations/0006_add_k9_certification_lifecycle.sql) adds
    `tier`/`revoke_reason`/`expires_at` to `k9_certifications` and a new
    sibling table `k9_certification_specializations` — see that file's own
    header for the full compatibility story; summarized here for anyone
    reading only this file.

    COMPATIBILITY (the hard requirement this pass is built around): an
    existing certified handler stays certified and fully functional with
    NO operator action. `tier` defaults to 'certified' for every existing
    row (the migration's DEFAULT, not code here) — 'certified' is chosen,
    not 'trainee', because it is the ordinal tier that preserves today's
    actual capability (everything Phase 1/2/3 already gates behind plain
    HasK9Access). `expires_at` stays NULL for every pre-existing row
    forever unless a certifier explicitly renews it — a certification
    never silently starts a countdown it didn't have before. The whole
    expiry mechanism is additionally gated behind
    `Config.Features.CertificationExpiry` (default false, off until an
    operator opts in).

    TIER (§5): a fixed, HARDCODED 3-step ordinal — trainee < certified <
    senior (TIER_RANK below) — deliberately NOT a Config table. Real K9
    tiering is a small, fixed vocabulary; making it configurable would let
    an operator invent tier names no future Phase 2/3 gate could rank
    against, for no real benefit — "an operator can hold the model in
    their head" (this task's own instruction) argued directly against an
    open-ended list here. HasK9Access (base access — leash/radial/basic
    locomotion) is UNCHANGED by tier: every tier, including 'trainee',
    passes it, matching §5's own framing ("trainee gets... basic
    locomotion only" — i.e. still has *some* K9 access). Tier only gates
    which HIGHER capability a future Phase 2/3 file chooses to check via
    the new `GetCertificationTier`/`MeetsTierRequirement` accessors below
    — this file does not itself gate any Phase 2/3 mechanic on tier; that
    wiring belongs to whichever file owns that mechanic (search.lua,
    combat.lua, defense.lua), reported separately rather than reached into
    here. Tier is changed via the new `SetCertificationTier` action, kept
    DELIBERATELY SEPARATE from GrantCertification (which still always
    creates a plain 'certified' row exactly as before, so its own,
    extensively tested INSERT/signature never changes) — a certifier who
    wants a different initial tier calls SetCertificationTier immediately
    after granting.

    SUPERSEDED, 2026-08-25 (owner-directed reversal — see
    server/certtiers.lua's own header for the full writeup; THIS PARAGRAPH
    IS KEPT, NOT DELETED, per that pass's own instruction to record why
    the reasoning above no longer applies rather than erase it): the
    "deliberately NOT a Config table" argument two paragraphs up was
    correct for a small, permanently-fixed vocabulary nobody would ever
    need to extend. It stops applying the moment the owner asks for the
    opposite — "Allow high command to edit the tiers trainee certified
    senior etc add more roles edit permissions for those roles etc." The
    tier catalog (key/label/ordinal/capabilities) is now data, owned by
    server/certtiers.lua — Config.CertificationTiers for the DEFAULTS
    (which preserve these exact three keys/ordinals, so an operator who
    never opens the tablet sees zero behavior change), the
    `k9_certification_tiers`/`k9_certification_tier_capabilities`
    database tables for high command's runtime edits (the DB wins). The
    literal `TIER_RANK` table immediately below is UNCHANGED and STILL
    LIVE — not vestigial — as the explicit LEGACY FALLBACK every tier
    accessor in this file now degrades to only if server/certtiers.lua's
    own accessors are unavailable (see IsKnownTierKeyOrLegacyFallback/
    GetTierOrdinalOrLegacyFallback below). `SetCertificationTier`'s own
    signature and every call site are UNCHANGED by this — it still takes
    a plain tier-key string; it now simply accepts any key the live
    catalog currently recognizes instead of only these original three.

    REVOKE REASON (§2): an OPTIONAL third argument on RevokeCertification/
    RevokeCertificationOffline and their net-event/command entry points —
    fully backward compatible (nil/omitted behaves exactly as before: a
    NULL `revoke_reason`, same as every historical row). Validated against
    a fixed vocabulary (VALID_REVOKE_REASONS below: retired, reassigned,
    disciplinary, performance, other) — a small fixed set was chosen over
    free text for the same "tablet can render it, operator can hold it in
    their head" reason tier used a fixed set. The automatic
    QBCore:Server:OnJobUpdate auto-revoke path always records
    'reassigned' — an accurate, non-punitive category for "this handler
    changed department," distinct from the mechanism tag ('job_changed')
    already carried on the outbound event.

    EXPIRY (§9) — LIVE-BEHAVIOUR DESIGN CHOICES, STATED EXPLICITLY per
    this task's own instruction:
      1. A certification does NOT force-detach an active leash / interrupt
         an in-progress ability the instant it lapses. Manual revoke keeps
         its existing "immediately" teardown (a human made a deliberate
         right-now decision) — passive time-based expiry is a paperwork
         lapse, not a disciplinary action, and forcibly ripping a K9 off
         an active pairing over an expired form is exactly the harsh
         "silently lapsing mid-shift" experience this task warned against.
         HasK9Access simply stops granting NEW access once expired; an
         already-formed leash/partnership/in-progress action is untouched
         by this file.
      2. Warned ahead of time. An online handler within
         Config.CertificationExpiryWarningDays of their expiry gets a
         one-per-session ox_lib notice (`certifications.expiry_warning`).
         The moment expiry is actually crossed, an online handler gets a
         second, one-time notice (`certifications.expiry_lapsed_notice`)
         PROACTIVELY — not left to discover it only when an ability stops
         working. Both are driven by TickCertificationExpiryWarnings, a
         background sweep (Config.CertificationExpiryCheckIntervalMs,
         same config-driven-interval + fallback-on-misconfiguration
         pattern as server/tenure.lua's own tick loop) over currently
         connected players' cached state — never a live per-access SQL
         query.
      3. Wall-clock arithmetic happens IN SQL, never in Lua. Consistent
         with this resource's own established convention
         (server/tenure.lua's `TIMESTAMPDIFF(SECOND, established_at,
         NOW())`) — RefreshCertificationCache reads
         `UNIX_TIMESTAMP(expires_at)` as a plain number once, at refresh
         time; GrantCertification/RenewCertification write
         `DATE_ADD(NOW(), INTERVAL ? DAY)`. The ONLY Lua-side wall-clock
         read is the global `os.time()` (NOT a FiveM native — ordinary
         Lua 5.4 stdlib; FXServer's server runtime is understood to expose
         it, same MEDIUM-HIGH-confidence, not-independently-verified-live
         posture this file's own PlayerLoaded-event-name note already
         discloses), used only to compare against that one cached number.
         If `os.time` were ever unavailable, this file FAILS TOWARD
         AVAILABILITY, not toward lockout — see IsExpiredUnix's own doc
         comment: an optional, off-by-default feature's primitive going
         missing should make that feature silently inert, never lock out
         every certified handler server-wide.

    SPECIALIZATIONS (Part B §11): a SIBLING TABLE
    (`k9_certification_specializations`), not a column, because a
    citizenid may hold MULTIPLE simultaneously-active specializations for
    the same (citizenid, job) — narcotics AND explosives at once is a
    real, ordinary case, which a single column/CSV/JSON convention this
    table's own append-mostly-audit-log design deliberately avoids
    elsewhere. AUTHORIZATION: reuses IsEligibleCertifier UNCHANGED (the
    exact same rank/high-command/`k9.certify`-permission gate as the base
    certification) rather than a new permission key — see "WHY THIS DOES
    NOT REUSE k9_permissions" below for the full reasoning either way.
    Requires an ACTIVE base certification for the same (citizenid, job) to
    already exist (checked against the live Certifications cache, since
    grant requires the target online exactly like GrantCertification) —
    a specialization with no underlying certification is meaningless.
    Revoking/lapsing the BASE certification cascades: every active
    specialization for that (citizenid, job) is bulk-revoked at every one
    of the THREE existing base-revoke call sites (RevokeCertification's
    online branch, RevokeCertificationOffline, and the
    QBCore:Server:OnJobUpdate auto-revoke handler's both branches) via
    RevokeAllSpecializationsForCitizenJob below — mirrors the leash/
    partnership teardown call sites already at each of those exact three
    places.

    WHY THIS DOES NOT REUSE server/permissions.lua's k9_permissions FOR
    SPECIALIZATIONS (argued, not defaulted, per this task's own
    instruction): k9_permissions grants a named capability GLOBALLY per
    citizenid, callable ONLY by high command (IsHighCommand, unconditionally
    — GrantPermission has no lower rank tier at all), with no per-department
    scoping. A specialization is the opposite shape on every one of those
    three axes: it is scoped to one (citizenid, job) pair (a narcotics K9
    in the police department is not automatically narcotics-cleared if
    they later move to sheriff), it should be grantable by an ORDINARY
    certifying officer (the same rank that already grants the base cert —
    requiring every specialization grant to go all the way up to high
    command would make specializations far less usable than the base
    certification they extend), and it is meaningless without an existing
    base certification row to attach to (k9_permissions grants are
    standalone; nothing in that file requires a citizenid to hold anything
    else first). Building specializations on k9_permissions would therefore
    mean either (a) loosening k9_permissions' own high-command-only
    authorization model specifically to accommodate this one new use
    (widening a file this task does not own, for a fit that's still wrong
    on the other two axes), or (b) keeping it high-command-gated and
    shipping a materially less useful feature than the one asked for. Both
    are worse than extending the SAME certifier-grade mechanism the base
    certification itself already uses. `IsEligibleCertifier` is reused
    UNCHANGED (not duplicated) specifically so a citizenid holding the
    'k9.certify' permission grant already gets specialization-granting
    power for free, with no new permission key and no edit to
    permissions.lua at all — this is the one place the two systems DO
    compose, without either becoming a parallel copy of the other.

    CACHE SHAPE, EXTENDED: `Certifications[citizenid]` is now
    `{ active, job, tier, expiresAtUnix, expired }` — see
    RefreshCertificationCache's own doc comment for exactly how/when each
    field is populated. `expiresAtUnix`/`expired` are nil/false
    respectively for a citizenid whose row has no expiry set, which is
    every row on a server that has never turned
    `Config.Features.CertificationExpiry` on, and every pre-existing row
    everywhere else — the identical "additive, does nothing until
    explicitly used" posture as every other extension in this section.
    Specializations get their OWN small cache, `Specializations[citizenid]
    = { [job] = { [specializationKey] = true, ... } }`, populated
    alongside Certifications at the same refresh points (grant/revoke/
    PlayerLoaded/OnJobUpdate) and evicted on `playerDropped` identically.

    CONFIG THIS FILE ASSUMES MAY EXIST (reported to whoever owns
    config.lua for this pass; every read below is defensive — a missing
    key degrades the relevant feature to a clean no-op, never a crash,
    matching this whole section's "must not break an install with none of
    this configured yet" posture):
      Config.Features.CertificationExpiry : boolean (default false)
      Config.CertificationExpiryDays : number (default 90)
      Config.CertificationExpiryWarningDays : number (default 7)
      Config.CertificationExpiryCheckIntervalMs : number (default 300000)
      Config.K9Specializations : table<string, { label: string }>
        (default catalog: narcotics / explosives / patrol)
]]

-- Certifications[citizenid] = { active = boolean, job = string,
--   tier = string ('trainee'|'certified'|'senior'),
--   expiresAtUnix = number? (epoch seconds; nil = never expires),
--   expired = boolean (true once now >= expiresAtUnix; always false when
--     expiresAtUnix is nil) }
-- `job` is whichever department this cached result was scoped to (the
-- player's job at the time of the last refresh). Local: nothing outside
-- this file should read it directly — always go through HasK9Access(source),
-- RefreshCertificationCache(citizenid, jobName), or the read-only
-- GetCertificationTier/MeetsTierRequirement accessors below.
local Certifications = {}

-- Specializations[citizenid] = { [job] = { [specializationKey] = true, ... } }
-- Mirrors Certifications' own lifecycle (refreshed at the same points,
-- evicted on playerDropped) — see "SPECIALIZATIONS" above. Local: go
-- through HasSpecialization/QueryActiveSpecializations below.
local Specializations = {}

-- ExpiryWarned[citizenid] = true once the warn-ahead-of-expiry notice has
-- been sent THIS SESSION (cleared on playerDropped, and on an explicit
-- RenewCertification). ExpiryLapsedNotified[citizenid] = true once the
-- "just expired" notice has been sent THIS SESSION. Both are ephemeral,
-- one-per-session flags, NOT persisted — see header "EXPIRY" item 2 and
-- TickCertificationExpiryWarnings' own doc comment below for the full
-- warning-cadence design.
local ExpiryWarned = {}
local ExpiryLapsedNotified = {}

-- LEGACY FALLBACK ONLY as of the owner-directed tier-editing pass (see
-- header "SUPERSEDED" note above server/certtiers.lua now owns the LIVE
-- tier catalog, config-defaults-plus-database-overrides, EXTENSIBLE at
-- runtime. This table is kept, byte-identical to its original form, as
-- what IsKnownTierKeyOrLegacyFallback/GetTierOrdinalOrLegacyFallback
-- below degrade to ONLY if server/certtiers.lua's own accessors
-- (IsKnownCertificationTierKey/GetCertificationTierOrdinal) are not
-- available — the same "runtime existence guard, not a load-order
-- assumption" soft-dependency convention this file already applies to
-- IsHighCommand/HasPermission. Every normal-operation code path in this
-- file (server/certtiers.lua is an unconditional, always-loaded file in
-- this resource, not a feature-flagged one) defers to the live catalog
-- instead.
local TIER_RANK = { trainee = 1, certified = 2, senior = 3 }

--- @param key any
--- @return boolean
local function IsKnownTierKeyOrLegacyFallback(key)
    if type(key) ~= 'string' then return false end
    if type(IsKnownCertificationTierKey) == 'function' then
        return IsKnownCertificationTierKey(key)
    end
    return TIER_RANK[key] ~= nil
end

--- @param key any
--- @return number?
local function GetTierOrdinalOrLegacyFallback(key)
    if type(key) ~= 'string' then return nil end
    if type(GetCertificationTierOrdinal) == 'function' then
        return GetCertificationTierOrdinal(key)
    end
    return TIER_RANK[key]
end

-- The tier every row had, implicitly, before this pass — migration 0006's
-- own DEFAULT for existing rows, and GrantCertification's own INSERT
-- column list still relies on this same DB default for every NEW grant
-- too (GrantCertification is deliberately NOT changed to accept a tier
-- argument — see "TIER" above). Referenced here only for the defensive
-- fallback in RefreshCertificationCache below (an unreadable/unexpected
-- tier value defaults to this, never to the least-privileged 'trainee' —
-- consistent with this whole section's "never silently reduce an existing
-- grant's capability" posture).
local DEFAULT_TIER = 'certified'

-- Fixed revoke-reason vocabulary — see "REVOKE REASON" above.
local VALID_REVOKE_REASONS = { retired = true, reassigned = true, disciplinary = true, performance = true, other = true }

--- Real, current Unix time in whole seconds, or nil if unavailable. See
--- "EXPIRY" item 3 above for the full CONFIDENCE NOTE on `os.time`.
--- @return number?
local function NowUnix()
    if type(os) == 'table' and type(os.time) == 'function' then
        return os.time()
    end
    return nil
end

--- @param expiresAtUnix number?
--- @return boolean
--- FAILS TOWARD AVAILABILITY, not toward lockout — deliberately the
--- OPPOSITE failure direction from this file's own authorization-root
--- "fail closed" doctrine (HasK9Access/RefreshCertificationCache on a
--- genuine DB read failure). Those fail closed because an unreadable cert
--- row IS the real, unknown authorization state. A missing `os.time` is
--- not that: it is an environment anomaly unrelated to whether this
--- citizenid's certification is genuinely still valid, and this whole
--- expiry mechanism is opt-in (Config.Features.CertificationExpiry). The
--- safe failure mode for an optional feature's own primitive going
--- missing is "the feature silently does nothing," never "every
--- certified handler on the server loses access."
local function IsExpiredUnix(expiresAtUnix)
    if expiresAtUnix == nil then return false end
    local now = NowUnix()
    if now == nil then return false end
    return now >= expiresAtUnix
end

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
--
-- CLAMP-AND-WARN, NOT ASSERT, FOR Config.Peds / Config.CertifyProximityMeters
-- (this pass) — same incident/reasoning as server/cooldowns.lua's own
-- header ADDENDUM: a bare top-level `assert` that throws aborts THIS
-- ENTIRE FILE from that line onward the instant an operator's config.lua
-- edit reaches it — every function definition (HasK9Access,
-- RefreshCertificationCache, IsConfiguredK9Model), RegisterNetEvent/
-- RegisterCommand, and the QBCore:Server:OnJobUpdate auto-revoke handler
-- textually BELOW the failing line silently never exist, for the rest of
-- the resource's uptime, with nothing but one script-error line at boot to
-- explain why. That is already the worst failure class this resource
-- forbids ("the unbounded trap") anywhere; it is WORSE here specifically
-- because THIS file is the one HasK9Access/GrantCertification/
-- RevokeCertification live in — nearly every other feature in this
-- resource calls into one of those three, so a single config typo on
-- EITHER of these two fields would currently take every gated K9 feature
-- down resource-wide, not just certification. See
-- ResolveConfiguredPositiveNumber below and the Config.Peds build loop
-- immediately after it for the actual clamp-and-warn behavior each is
-- replaced with.
--
-- Config.Departments' own asserts immediately below are DELIBERATELY LEFT
-- AS BARE ASSERTS, not converted — narrower in scope than the two above
-- (this task's own instruction names only Config.Peds/
-- Config.CertifyProximityMeters) and structurally a poor fit for the same
-- treatment regardless: unlike a single positive number with one obvious,
-- already-shipped fallback value, there is no single sensible substitute
-- for a malformed per-department `certifierGrade`/`autoAccessGrade` that
-- would not itself silently misrepresent a real operator department
-- definition (clamping an unreadable rank requirement to some guessed
-- number is a correctness risk of its own, not obviously safer than
-- failing loudly). Left exactly as originally written and reported here
-- for whoever owns config.lua/DEVELOPER_REFERENCE.md's broader
-- config-safety pass to weigh in on, rather than decided unilaterally in
-- this one.
-- ======================================================================
assert(type(Config.Departments) == 'table',
    '[qbx_k9unit] Config.Departments must be a table -- HasK9Access, IsEligibleCertifier, and every ' ..
    'certify/revoke path index it by job.name to decide K9 access and certifier eligibility; a missing ' ..
    'table would make every job fail K9 access outright, with the failure surfacing only as "nobody can ' ..
    'ever use K9 features," never as a clear config error.')
for jobName, dept in pairs(Config.Departments) do
    assert(type(dept) == 'table',
        ('[qbx_k9unit] Config.Departments[%s] must be a table with certifierGrade/autoAccessGrade fields -- ' ..
        'IsEligibleCertifier and HasK9Access both index straight into it (dept.certifierGrade, dept.autoAccessGrade) ' ..
        'with no type guard of their own. NOTE: dept.label is NOT validated here (unlike the two fields above) -- ' ..
        'every real consumer (server/tablet.lua, this file\'s own OnJobUpdate department-loss notice) already ' ..
        'falls back to the job key itself when label is missing or not a string, so an absent/malformed label ' ..
        'degrades gracefully rather than crashing; asserted only if that ever stops being true everywhere.'):format(tostring(jobName)))
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

--- CLAMP-AND-WARN (this pass) — see the CONFIG-SAFETY GUARD block above
--- for the full "why not a bare assert here" reasoning. Resolves a raw
--- Config number to a safe, positive value: unchanged if already valid,
--- otherwise a loud PRINT (never an aborting error) naming the exact key,
--- the bad value found, and the fallback substituted, so this file keeps
--- loading — and every OTHER K9 feature that has nothing to do with the
--- one field that was wrong keeps working — while an operator fixes the
--- real config.lua typo. Mirrors server/cooldowns.lua's own
--- ResolveConfiguredThresholdMs shape exactly (see that function's doc
--- comment for the original incident this responds to), reimplemented
--- locally rather than called directly: that function's own printed
--- wording is cooldown-specific ("does NOT mean 'no cooldown'... would
--- otherwise permanently block the guarded action") and would be actively
--- misleading for the proximity-meters value this is used for below.
--- @param configuredValue any
--- @param fallback number -- a positive, hardcoded call-site literal (this file's own shipped default for the field), never itself read from Config
--- @param configKeyName string
--- @return number
local function ResolveConfiguredPositiveNumber(configuredValue, fallback, configKeyName)
    if type(configuredValue) == 'number' and configuredValue == configuredValue and configuredValue > 0 then
        return configuredValue
    end
    print(
        ('[qbx_k9unit] certifications.lua: %s must be a positive number (found: %s). Using the built-in ' ..
         'fallback of %s instead so this file keeps loading and every OTHER K9 feature keeps working -- find ' ..
         '%s in config.lua and fix it.'):format(configKeyName, tostring(configuredValue), tostring(fallback), configKeyName)
    )
    return fallback
end

-- CLAMP-AND-WARN (this pass): unchanged if valid; otherwise every online
-- grant/revoke's proximity check (§4.2.4) falls back to the shipped
-- 5.0-meter default rather than this whole file aborting. See
-- ResolveConfiguredPositiveNumber's own doc comment above.
Config.CertifyProximityMeters = ResolveConfiguredPositiveNumber(Config.CertifyProximityMeters, 5.0, 'Config.CertifyProximityMeters')

-- CLAMP-AND-WARN (this pass, found while tracing the CertificationExpiry
-- chain end-to-end) -- Config.CertificationExpiryCheckIntervalMs already
-- got this treatment (see the CreateThread loop far below); Config.
-- CertificationExpiryDays and Config.CertificationExpiryWarningDays did
-- not, despite being exactly the class of "silently degrades to a
-- DIFFERENT, unannounced behavior" footgun this file's own CONFIG-SAFETY
-- GUARD section above exists to close: an operator who sets
-- Config.Features.CertificationExpiry = true but leaves
-- Config.CertificationExpiryDays misconfigured (a typo'd string, 0, a
-- negative number) gets EVERY certification granted or renewed from that
-- point on with NO expiry at all -- identical, byte-for-byte, to the
-- feature being off -- with nothing printed anywhere to say why. That is
-- the worst possible outcome for a feature an operator just deliberately
-- opted into: it looks enabled and does nothing. One-shot printed
-- warnings (WarnedBadExpiryDays/WarnedBadExpiryWarningDays below), not a
-- per-call print, since both are read from hot, per-action call sites
-- (every grant/renew, every sweep tick) rather than once at file load
-- like Config.CertifyProximityMeters above -- mirrors
-- WarnedBadExpiryCheckIntervalMs's own established one-shot-flag idiom
-- later in this file.
local WarnedBadExpiryDays = false
local WarnedBadExpiryWarningDays = false

--- Resolves Config.CertificationExpiryDays into the expiry window (in
--- days) a fresh grant/renewal should use, or nil if either expiry is
--- genuinely off (Config.Features.CertificationExpiry ~= true -- silent,
--- not a misconfiguration) or misconfigured while expiry IS on (warned
--- once, then silent for the rest of this session -- see CLAMP-AND-WARN
--- above). Shared by GrantCertification and RenewCertification so the one
--- validation/warning lives in one place instead of two independent
--- copies of the same boolean expression free to drift apart.
--- @return number?
local function ResolveConfiguredExpiryDays()
    if not (Config.Features and Config.Features.CertificationExpiry == true) then return nil end
    local raw = Config.CertificationExpiryDays
    if type(raw) == 'number' and raw == raw and raw > 0 then return raw end
    if not WarnedBadExpiryDays then
        WarnedBadExpiryDays = true
        print(
            ('[qbx_k9unit] certifications.lua: Config.CertificationExpiryDays must be a positive number now that ' ..
             'Config.Features.CertificationExpiry is true (found: %s). Every certification granted or renewed ' ..
             'while this stays misconfigured gets NO expiry at all -- identical to the feature being off -- not ' ..
             'the expiry window you just enabled. Find Config.CertificationExpiryDays in config.lua and fix it.'
            ):format(tostring(raw))
        )
    end
    return nil
end

--- Resolves Config.CertificationExpiryWarningDays into the warn-ahead
--- window (in days) CheckAndNotifyExpiry should use, falling back to the
--- shipped default of 7 on any invalid value -- see CLAMP-AND-WARN above.
--- Unlike ResolveConfiguredExpiryDays, this is NOT itself gated on
--- Config.Features.CertificationExpiry: CheckAndNotifyExpiry's only
--- callers already never reach this line unless `cached.expiresAtUnix` is
--- non-nil, which cannot happen unless a grant/renewal already ran with
--- expiry on -- by that point a warn-ahead window is always relevant
--- regardless of the flag's CURRENT value (e.g. an operator who disabled
--- the feature again after some certifications already picked up a real
--- expiry date).
--- @return number
local function ResolveConfiguredExpiryWarningDays()
    local raw = Config.CertificationExpiryWarningDays
    if type(raw) == 'number' and raw == raw and raw > 0 then return raw end
    if not WarnedBadExpiryWarningDays then
        WarnedBadExpiryWarningDays = true
        print(
            ('[qbx_k9unit] certifications.lua: Config.CertificationExpiryWarningDays must be a positive number ' ..
             '(found: %s). Using the built-in fallback of 7 instead -- find Config.CertificationExpiryWarningDays ' ..
             'in config.lua and fix it.'):format(tostring(raw))
        )
    end
    return 7
end

--- Precomputed set of Config.Peds model hashes, built once at file load.
--- Used ONLY by the grant-time model check (§4.2 condition 5) — per
--- §4.1/§4.5, ordinary access checks (HasK9Access) never consult this.
--- Generic over Config.Peds — no hardcoded model name anywhere (DEVELOPER_REFERENCE.md §3
--- acceptance bullet 3), including custom streamed entries.
---
--- CLAMP-AND-WARN (this pass) — see the CONFIG-SAFETY GUARD block above
--- for the full "why not a bare assert here" reasoning. A missing/empty/
--- malformed Config.Peds (or an individual malformed entry within it)
--- degrades to a loud PRINT plus K9ModelHashes simply having no entry for
--- the affected model(s) — IsConfiguredK9Model then correctly rejects
--- every ped it's asked about (every certification GRANT attempt fails
--- with "target not K9 model", exactly as the original assert's own
--- message already described), but HasK9Access/GrantCertification/
--- RevokeCertification/every net event and command this file registers
--- keep working normally — unlike an aborting assert, this is a bounded,
--- single-feature degradation, never a resource-wide one. An individual
--- malformed entry (e.g. Config.Peds[3] missing `.model`) is skipped on
--- its own, by index, without discarding every OTHER valid entry in the
--- same array.
local K9ModelHashes = {}
if type(Config.Peds) ~= 'table' or #Config.Peds == 0 then
    print(
        '[qbx_k9unit] certifications.lua: Config.Peds must be a non-empty array (found: ' ..
        tostring(Config.Peds) .. '). No model will ever be recognized as a K9 model -- every certification ' ..
        'GRANT attempt will fail with "target not K9 model" until this is fixed in config.lua -- but ' ..
        'HasK9Access and every other K9 feature in this file are unaffected. Find Config.Peds in config.lua ' ..
        'and fix it.'
    )
else
    for i, pedEntry in ipairs(Config.Peds) do
        if type(pedEntry) == 'table' and type(pedEntry.model) == 'string' and pedEntry.model ~= '' then
            K9ModelHashes[GetHashKey(pedEntry.model)] = true
        else
            print(
                ('[qbx_k9unit] certifications.lua: Config.Peds[%d].model must be a non-empty string (found: %s). ' ..
                 'Skipping this ONE entry -- it can never be matched by IsConfiguredK9Model -- rather than ' ..
                 'discarding every other valid entry or aborting this file. Find Config.Peds[%d] in config.lua ' ..
                 'and fix it.'):format(i, tostring(pedEntry and pedEntry.model), i)
            )
        end
    end
end

--- @param modelHash number
--- @return boolean
--- Exposed globally (no `local`) — server/main.lua's leash-role
--- determination (§6.1/§9 item 3b) reuses this same model check rather
--- than re-deriving its own copy from Config.Peds.
function IsConfiguredK9Model(modelHash)
    return K9ModelHashes[modelHash] == true
end

--- Re-queries every ACTIVE specialization row for (citizenid, jobName) and
--- replaces that job's slice of `Specializations[citizenid]` wholesale.
--- Fails CLOSED on a thrown read (an unreadable citizenid/job's
--- specialization set is treated as empty, never as "whatever it was
--- before") — same posture as RefreshCertificationCache. Declared BEFORE
--- RefreshCertificationCache (which calls it) since both are in this same
--- file/chunk and this is a `local` — Lua resolves a `local` reference
--- lexically, by textual position, not by call order at runtime. Called
--- from RefreshCertificationCache itself (every point that already
--- refreshes the base cert cache also keeps this in sync) — never called
--- standalone from outside this file.
--- @param citizenid string
--- @param jobName string
local function RefreshSpecializationCache(citizenid, jobName)
    local ok, rowsOrErr = pcall(K9Store.Spec_GetActiveKeys, citizenid, jobName)
    Specializations[citizenid] = Specializations[citizenid] or {}
    if not ok then
        print(('[qbx_k9unit] RefreshSpecializationCache query failed for %s/%s: %s'):format(citizenid, jobName, tostring(rowsOrErr)))
        Specializations[citizenid][jobName] = {}
        return
    end
    local set = {}
    for _, row in ipairs(rowsOrErr or {}) do
        set[row.specialization] = true
    end
    Specializations[citizenid][jobName] = set
end

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
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
--- features? DEVELOPER_REFERENCE.md §4.1 "Access rule": job.name in Config.Departments
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
    --
    -- CERTIFICATION DEPTH (this pass, Part A §9): `not cached.expired` is
    -- the ONLY change to this branch. An expired cert does not hard-fail
    -- this whole function — it simply does not satisfy THIS branch, so
    -- control falls through to the autoAccessGrade bypass below exactly
    -- as it already does for `cached.active == false`; an expired
    -- handler who separately qualifies via autoAccessGrade (or the
    -- permission-grant/high-command bypasses already checked above this
    -- branch) is unaffected. Deliberately does NOT force-detach anything
    -- or mutate `active` in the DB — see this file's header "EXPIRY" item
    -- 1 for why a passive, time-based lapse gets a softer landing than a
    -- manual revoke's "immediately" teardown.
    local cached = Certifications[Player.PlayerData.citizenid]
    if cached and cached.active and cached.job == job.name and not cached.expired then
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
    local queryOk, activeIdOrErr = pcall(K9Store.Cert_GetActiveId, citizenid, jobName)

    if not queryOk then
        print(('[qbx_k9unit] RefreshCertificationCache query failed for %s/%s: %s'):format(citizenid, jobName, tostring(activeIdOrErr)))
        -- FAIL CLOSED: an unreadable cert row must never be treated as an
        -- active grant — see doc comment above.
        Certifications[citizenid] = { active = false, job = jobName }
        Specializations[citizenid] = nil
        return false
    end

    local active = activeIdOrErr ~= nil
    if not active then
        Certifications[citizenid] = { active = false, job = jobName }
        Specializations[citizenid] = nil
        return false
    end

    -- CERTIFICATION DEPTH (this pass, Part A §5/§9) — tier/expiry
    -- metadata, read via a SEPARATE query from the existence check above,
    -- DELIBERATELY: this file's own regression tests sequence exact call
    -- counts against the existence-check call's underlying
    -- `MySQL.scalar.await` invocation (e.g. the GrantInFlight concurrency
    -- test's `scalarCallCount == 2` assertion) — changing that call's own
    -- SQL/shape would be a needless, high-blast-radius edit to already
    -- passing coverage for no behavioral gain. DATASTORE MIGRATION NOTE:
    -- this file now calls K9Store.Cert_GetActiveId instead of
    -- MySQL.scalar.await directly, but K9Store.Cert_GetActiveId forwards
    -- to that exact same MySQL.scalar.await call with the identical SQL/
    -- params when Config.Database.enabled is not literally false, so the
    -- scalarCallCount assertion still counts the same underlying calls
    -- unchanged (see tests/certifications_spec.lua's own fixture, which
    -- loads the real server/datastore.lua alongside this file for exactly
    -- this reason). Only run once an active row is already confirmed to
    -- exist above.
    --
    -- `UNIX_TIMESTAMP(expires_at)` does the date arithmetic in SQL, never
    -- in Lua — see this file's header "EXPIRY" item 3. Returns NULL
    -- (-> Lua nil) when `expires_at` itself is NULL, i.e. "never expires".
    local tier, expiresAtUnix = DEFAULT_TIER, nil
    local metaOk, metaRowOrErr = pcall(K9Store.Cert_GetActiveMeta, citizenid, jobName)
    if not metaOk then
        -- Degrades to the DEFAULT_TIER / never-expires fallback, never to
        -- a hard error and never to a MORE restrictive state than the
        -- existence check above already confirmed — this file's "never
        -- silently reduce an existing grant's capability" posture (see
        -- header) applies to a query failure exactly like it applies to a
        -- pre-migration database that has the base columns but not yet
        -- these new ones.
        print(('[qbx_k9unit] RefreshCertificationCache tier/expiry metadata query failed for %s/%s: %s -- defaulting to tier=%s, no expiry'):format(citizenid, jobName, tostring(metaRowOrErr), DEFAULT_TIER))
    elseif metaRowOrErr then
        -- OWNER-DIRECTED TIER-EDITING PASS: was `TIER_RANK[metaRowOrErr.tier]`
        -- (only the original three hardcoded keys could ever validate) —
        -- now defers to the live, operator-extensible catalog via
        -- IsKnownTierKeyOrLegacyFallback, so a row holding an
        -- operator-ADDED tier key validates too. Falls back to
        -- DEFAULT_TIER exactly as before for anything unrecognized
        -- (including a stale/corrupted string) — this branch's own
        -- "never silently reduce an existing grant's capability" posture
        -- (see header) is unchanged.
        if IsKnownTierKeyOrLegacyFallback(metaRowOrErr.tier) then
            tier = metaRowOrErr.tier
        end
        expiresAtUnix = tonumber(metaRowOrErr.expires_at_unix)
    end

    Certifications[citizenid] = {
        active = true,
        job = jobName,
        tier = tier,
        expiresAtUnix = expiresAtUnix,
        expired = IsExpiredUnix(expiresAtUnix),
    }
    RefreshSpecializationCache(citizenid, jobName)
    return true
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
    local ok, activeIdOrErr = pcall(K9Store.Cert_GetActiveId, citizenid, jobName)
    if not ok then
        print(('[qbx_k9unit] cert-row reconciliation read failed for %s/%s: %s'):format(citizenid, jobName, tostring(activeIdOrErr)))
        return nil
    end
    return activeIdOrErr ~= nil
end

--- DEVELOPER_REFERENCE.md §4.2 certifier eligibility check (granter side only — does not
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
    -- eligibility for a boss regardless of grade shape, matching DEVELOPER_REFERENCE.md's
    -- documented "isboss always qualifies" rule.
    local dept = Config.Departments[job.name]
    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.certifierGrade
end

--- CONSOLIDATION (this pass, cross-team "four doors, one bug" finding):
--- losing K9 access must end an already-formed leash pairing, an
--- in-progress bite-hold/takedown/drag, and any active partnership
--- "immediately" per DEVELOPER_REFERENCE.md §1/§4.4, not just block future
--- attach/certify attempts — CheckLeashEligibility in server/main.lua is
--- only consulted at attach time, so a K9-role party who loses access
--- mid-session while actively leashed/holding/partnered would otherwise
--- stay that way until someone manually intervenes or a safety-valve
--- trips. This exact three-call sequence (ForceDetachLeashForSource +
--- EndActiveEffectForHolder + ForceBreakPartnershipForCitizenId) used to
--- be reimplemented independently at every one of THIS FILE's own call
--- sites that flips a citizenid's K9 access to lost — which is exactly why
--- the bug kept being found and fixed one call site at a time instead of
--- once (most recently: the department-loss branch of the
--- QBCore:Server:OnJobUpdate handler below only called
--- ForceDetachOfficerLeashForSource, never this function, so a
--- non-certified K9-role party — access via autoAccessGrade or a
--- server/permissions.lua 'k9.access' grant only — kept their leash on
--- leaving the department entirely; see that branch's own comment for the
--- fix). This is now the ONE place in this file that means "citizenid has
--- just, provably, lost K9-role access — tear down every ephemeral/
--- session consequence of that."
---
--- Callable from a site with a live, already-resolved `source` for
--- `citizenid` (pass it as `knownSrc` — RevokeCertification's online
--- branch and all three OnJobUpdate branches always have one) or from a
--- site with only a `citizenid` (RevokeCertificationOffline — omit
--- `knownSrc` and this resolves it itself via
--- exports.qbx_core:GetPlayerByCitizenId, exactly like the
--- ForceDetachLeashIfOnline wrapper this function replaces already did).
--- Naturally a no-op for the leash/hold half on a genuinely offline
--- target: LeashPairs and any bite-hold/takedown/drag are in-memory/
--- ephemeral only (never persisted, per server/main.lua's and
--- server/combat.lua's own headers), so an offline citizenid cannot have
--- either to tear down in the first place. ForceBreakPartnershipForCitizenId
--- runs UNCONDITIONALLY of whether a live `src` was found at all — a
--- partnership row is DB-backed and works identically online or offline
--- (see that function's own "OFFLINE-CAPABLE BY DESIGN" doc comment).
---
--- Runs NO confirmation/reconciliation check of its own, and must never be
--- changed to add one: every call site below already runs its OWN "is
--- this loss actually confirmed" gate (a DB-write reconcile dance for the
--- certification-revoke paths, a plain boolean expression for the
--- autoAccessGrade-loss branch, an unconditional department-loss check)
--- BEFORE ever reaching this function — this is the unconditional, "no
--- unbounded trap" teardown for an ALREADY-CONFIRMED loss, not a second
--- gate that could itself block it. Two of this file's own regression
--- tests (tests/certifications_spec.lua, "a throwing UPDATE that genuinely
--- never committed") assert ZERO side effects — including zero calls into
--- this function — when that confirmation fails; that guarantee lives
--- entirely in each CALLER's own gating and must stay that way.
---
--- Deliberately does NOT call ForceDetachOfficerLeashForSource — that is a
--- DIFFERENT invariant (officer/handler-role department eligibility, not
--- K9-role access) that only the department-loss branch below needs, and
--- it keeps its own direct call for that reason.
---
--- NOT a resource-global, despite server/permissions.lua's own
--- RevokePermission needing this identical sequence for its 'k9.access'
--- de-assign path: doing that would need a new entry in BOTH
--- fxmanifest.lua's server_scripts list AND
--- /home/user/FIvem/.luacheckrc's `globals` table (verified: an
--- unregistered bare `function Foo()` is flagged by this repo's real
--- luacheck config as "setting a non-standard global variable"), and this
--- task has neither file assignable to it. tests/certifications_spec.lua
--- and tests/permissions_spec.lua also each load only the minimal file set
--- their own file under test needs, so a shared implementation would force
--- one spec to load a file it otherwise has no reason to (and inherit that
--- file's own file-load-time Config assertions as an unwanted side
--- effect). server/permissions.lua therefore keeps its OWN small, private,
--- identically-shaped copy of this function (see that file's own doc
--- comment on its copy for the full writeup) — one real duplicate between
--- two files, down from six independent inline copies before this pass.
--- @param citizenid string
--- @param reason string
--- @param knownSrc number? -- pass this file's own already-resolved live server id when known; omit for a citizenid-only caller to have this resolve it.
local function EndK9AccessForCitizenId(citizenid, reason, knownSrc)
    local src = knownSrc
    if type(src) ~= 'number' then
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        src = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    end

    if type(src) == 'number' then
        ForceDetachLeashForSource(src, reason)

        if type(EndActiveEffectForHolder) == 'function' then
            pcall(EndActiveEffectForHolder, src)
        end
    end

    if type(ForceBreakPartnershipForCitizenId) == 'function' then
        ForceBreakPartnershipForCitizenId(citizenid, reason)
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

--- MOVED to server/events.lua (2026-08-25 cross-file cleanup pass): this
--- file's own `FireOutboundEvent` copy — byte-for-byte identical to the
--- five other copies that existed alongside it — is now the single shared
--- resource-global implementation in that file. See server/events.lua's
--- header for the full extraction writeup. Every call site below is
--- unchanged: same event names, arguments, order, and firing conditions.

--- CERTIFICATION DEPTH (this pass, Part B §11): a specialization cannot
--- outlive the base certification it requires. Bulk-revokes EVERY active
--- specialization row for (citizenid, job) in one UPDATE (no need to
--- enumerate individual specialization keys first) and refreshes the
--- specialization cache so a still-online target's cache reflects the
--- loss immediately. Called from all THREE existing base-revoke call
--- sites (RevokeCertification's online branch, RevokeCertificationOffline,
--- and the QBCore:Server:OnJobUpdate auto-revoke handler's own
--- cert-revocation branch) — mirrors the leash/partnership teardown call
--- sites already at each of those exact three places.
---
--- BEST-EFFORT, DELIBERATELY: pcall-wrapped and logged on failure, never
--- allowed to turn an already-confirmed, already-committed base
--- certification revoke into a reported failure — the base revoke is the
--- security-critical action; this cascade is a consistency cleanup on top
--- of it. A failure here leaves a specialization row stranded active
--- under a now-inactive base certification.
---
--- DB-AUTHORITATIVE, NOT CACHE-BASED: reads the active specialization set
--- fresh from `k9_certification_specializations` rather than from the
--- in-memory `Specializations` cache, DELIBERATELY — this function is
--- called from RevokeCertificationOffline (a genuinely offline citizenid
--- whose cache entry has already been evicted by `playerDropped`, per
--- this file's own cache-lifecycle convention) just as often as from the
--- online revoke path, and a cache-based read would silently cascade
--- nothing for exactly that offline case.
--- @param citizenid string
--- @param jobName string
--- @param revokedByCitizenidOrSentinel string -- citizenid, or 'system:job_change'
--- @param reason string -- passed straight through to the outbound event, matching this file's existing certificationRevoked reason tagging ('certification_revoked' | 'department_changed' | 'job_changed')
local function RevokeAllSpecializationsForCitizenJob(citizenid, jobName, revokedByCitizenidOrSentinel, reason)
    local selectOk, rowsOrErr = pcall(K9Store.Spec_GetActiveKeys, citizenid, jobName)
    if not selectOk then
        print(('[qbx_k9unit] RevokeAllSpecializationsForCitizenJob pre-read failed for %s/%s: %s -- base certification revoke already committed; specialization rows may be stranded active'):format(citizenid, jobName, tostring(rowsOrErr)))
        return
    end

    local revokedKeys = {}
    for _, row in ipairs(rowsOrErr or {}) do
        revokedKeys[#revokedKeys + 1] = row.specialization
    end
    if #revokedKeys == 0 then return end -- nothing active to cascade -- common case, avoid a needless UPDATE

    local updateOk, updateErr = pcall(K9Store.Spec_RevokeAllForJob, citizenid, jobName, revokedByCitizenidOrSentinel)

    if not updateOk then
        print(('[qbx_k9unit] RevokeAllSpecializationsForCitizenJob UPDATE failed for %s/%s: %s -- base certification revoke already committed; specialization rows may be stranded active until the next refresh'):format(citizenid, jobName, tostring(updateErr)))
        return
    end

    if Specializations[citizenid] then
        Specializations[citizenid][jobName] = {}
    end

    for _, key in ipairs(revokedKeys) do
        FireOutboundEvent('qbx_k9unit:events:specializationRevoked', citizenid, jobName, key, reason)
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

-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastCertifyActionAt`
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

--- DEVELOPER_REFERENCE.md §4.2/§4.3 grant flow. Called by both event 2 and command 6, and
--- (this pass) the K9 Command Tablet's server-side aggregation layer
--- (server/tablet.lua -- see GrantCertificationForTablet below) via its
--- own resolved, online-only server id.
---
--- RETURN VALUE, ADDED THIS PASS (purely additive -- every pre-existing
--- caller (the RegisterNetEvent/RegisterCommand handlers near the bottom
--- of this file) discards both return values today, exactly as it
--- discarded the previous bare `return`/no-value return, so this changes
--- NO observable behavior for either of them; tests/certifications_spec.lua's
--- 47+ GrantCertification cases assert on NotifyPlayer/MySQL/cache side
--- effects only, never on a return value that did not exist before).
--- Mirrors server/permissions.lua's GrantPermission `(ok, outcome)` shape
--- exactly, and the same `local outcome` + doGrantInsert-closure-sets-it
--- convention that file's own header credits to this function in the
--- first place -- brought back here now that a second caller (the tablet)
--- actually needs a real result instead of only a fire-and-forget toast.
--- @param granterSrc number
--- @param targetServerId number
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'not_eligible' | 'rate_limited' | 'self_certification_disabled' | 'target_must_be_online' | 'target_not_in_department' | 'target_too_far' | 'target_not_k9_model' | 'already_certified' | 'invalid_granter' | 'db_error' | 'ok'
local function GrantCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return false, 'invalid_target'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'rate_limited' -- silent no-op (no NotifyPlayer): rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    -- §4.1: self-certification only allowed if the flag is enabled.
    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
        return false, 'self_certification_disabled'
    end

    -- Grant requires an online target — unlike revoke, which DEVELOPER_REFERENCE.md
    -- §4.3's flow table explicitly documents as working offline.
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.target_must_be_online'), 'error')
        return false, 'target_must_be_online'
    end

    -- §4.2.3: cross-department granting IS currently allowed (open
    -- question §9.2 in DEVELOPER_REFERENCE.md, not resolved here) — this only requires
    -- the target be in *some* configured department, not the SAME one as
    -- the granter. Do not silently restrict to same-department.
    local targetJob = targetPlayer.PlayerData.job
    if not targetJob or not Config.Departments[targetJob.name] then
        NotifyPlayer(granterSrc, locale('certifications.target_not_in_department'), 'error')
        return false, 'target_not_in_department'
    end

    -- §4.2.4 proximity — skipped only for self-cert (nothing to measure
    -- distance to). Live server-side coordinates only, never client-claimed.
    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.target_too_far_to_certify'), 'error')
            return false, 'target_too_far'
        end
    end

    -- §4.2.5 (grant-only, applies UNIFORMLY even to self-certification):
    -- target's LIVE server-side ped model must be a configured K9 model --
    -- but ONLY when Config.K9Appearance.requireK9ModelForRole is explicitly
    -- true (coder-architect, K9 role/model decoupling pass,
    -- server/appearance.lua). At the false default the K9 ROLE is an
    -- assignment held against a citizenid, independent of what they
    -- currently look like (a human, an unlisted custom model, whatever) --
    -- see server/appearance.lua's header for the full decoupling writeup.
    -- Guarded with `Config.K9Appearance and` for a defensive read: this
    -- file does not itself assert that table's shape (server/appearance.lua
    -- does, at ITS OWN load time), so a config predating this feature or a
    -- config.lua edited out from under this table would otherwise throw
    -- here instead of falling back to the pre-decoupling behavior.
    if Config.K9Appearance and Config.K9Appearance.requireK9ModelForRole == true then
        local targetModel = GetEntityModel(GetPlayerPed(targetServerId))
        if not IsConfiguredK9Model(targetModel) then
            NotifyPlayer(granterSrc, locale('certifications.target_not_k9_model'), 'error')
            return false, 'target_not_k9_model'
        end
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
        return false, 'already_certified'
    end
    GrantInFlight[lockKey] = true

    -- RETURN VALUE, ADDED THIS PASS: `outcome` is set by doGrantInsert below
    -- (an upvalue, since doGrantInsert's own `return` exits the closure, not
    -- this outer function) and read back after the pcall -- identical shape
    -- to server/permissions.lua's GrantPermission, which this function's own
    -- doc comment already credits as the precedent for this exact pattern.
    local outcome
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
        local existingId = K9Store.Cert_GetActiveId(targetCitizenid, jobName)
        if existingId then
            NotifyPlayer(granterSrc, locale('certifications.target_already_certified'), 'inform')
            outcome = 'already_certified'
            return
        end

        local granterCitizenid = ResolveGranterCitizenId(granterSrc)
        if not granterCitizenid then
            outcome = 'invalid_granter'
            return
        end

        -- CERTIFICATION DEPTH (this pass, Part A §9): a brand-new grant
        -- starts its own expiry clock immediately, but ONLY when an
        -- operator has explicitly opted in — see this file's header
        -- "COMPATIBILITY"/"EXPIRY" sections. `tier` is deliberately NOT
        -- part of this INSERT at all (see header "TIER") — every new row
        -- still gets the DB's own DEFAULT 'certified', byte-identical to
        -- this INSERT's shape before this pass, for the "else" branch
        -- below (which is exactly what every existing test already
        -- exercises). Date arithmetic happens in SQL
        -- (`DATE_ADD(NOW(), INTERVAL ? DAY)`), never in Lua — see header
        -- "EXPIRY" item 3. CLAMP-AND-WARN on a misconfigured
        -- CertificationExpiryDays lives in ResolveConfiguredExpiryDays
        -- (shared with RenewCertification below) — see its own doc comment.
        local expiryDays = ResolveConfiguredExpiryDays()

        -- K9Store.Cert_Insert owns the with-expiry/without-expiry SQL
        -- branch internally now (byte-identical to the two insertSql
        -- shapes this used to build here) -- see its own doc comment.
        local insertOk, insertResultOrErr = pcall(K9Store.Cert_Insert, targetCitizenid, jobName, granterCitizenid, expiryDays)

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
                outcome = 'already_certified'
                return
            end

            print(('[qbx_k9unit] GrantCertification INSERT failed for %s/%s: %s'):format(targetCitizenid, jobName, tostring(insertResultOrErr)))
            NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
            outcome = 'db_error'
            return
        end

        RefreshCertificationCache(targetCitizenid, jobName)

        -- BUGFIX (this pass, found while tracing the EXPIRY chain
        -- end-to-end): a brand-new grant re-arms the one-per-session
        -- warn/lapsed flags -- mirrors RenewCertification's own identical
        -- reset a few functions below (see that call site's comment).
        -- Without this, a citizenid whose PREVIOUS certification already
        -- triggered ExpiryWarned/ExpiryLapsedNotified this session (they
        -- were warned, or their cert fully lapsed), then got revoked and
        -- certified again — a real, ordinary sequence, not a corner case:
        -- exactly the citizenid who just lived through a lapse is the one
        -- most likely to be re-certified afterward — would keep those
        -- stale flags set against their CITIZENID (not their old cert row),
        -- so CheckAndNotifyExpiry would silently refuse to warn/announce
        -- for the NEW certification's own, entirely separate expiry clock
        -- until they disconnect and reconnect (playerDropped is the only
        -- other place these are cleared). That silently breaks this file's
        -- own header promise ("nobody should find out by an ability
        -- silently refusing to work") for the one citizenid it matters most
        -- for. Harmless no-op the overwhelmingly common way this runs: a
        -- citizenid's first-ever certification, or a re-grant that never
        -- triggered either notice, already has both flags nil/false.
        ExpiryWarned[targetCitizenid] = nil
        ExpiryLapsedNotified[targetCitizenid] = nil

        -- Outbound integration event (server/exports.lua's EVENT CONTRACT §1) —
        -- fired here, after the cache refresh that itself follows the committed
        -- INSERT, so any consumer reacting to this has already-committed,
        -- server-authoritative state to query back against (HasK9Access/
        -- GetActivePartnerCitizenId/etc.) if it wants to. Not gated on any
        -- Config.Features flag: certification is this resource's core access
        -- gate (DEVELOPER_REFERENCE.md §4.1), not a phase-numbered toggle, matching this same
        -- reasoning already applied to HasK9Access itself in server/exports.lua's
        -- header.
        FireOutboundEvent('qbx_k9unit:events:certificationGranted', targetCitizenid, jobName, granterCitizenid)

        -- Read-only mirror for client HUD display ONLY (DEVELOPER_REFERENCE.md §4.3) — NEVER
        -- read by any server-side authorization check. Do not add a read of
        -- this field to HasK9Access or any other gate.
        targetPlayer.Functions.SetMetaData('k9certified', true)

        NotifyPlayer(granterSrc, locale('certifications.grant_success_granter'), 'success')
        NotifyPlayer(targetServerId, locale('certifications.grant_success_target'), 'success')
        outcome = 'ok'
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    if not grantOk then
        print(('[qbx_k9unit] GrantCertification unexpected error for %s/%s: %s'):format(targetCitizenid, jobName, tostring(grantErr)))
        NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
        return false, 'db_error'
    end

    return outcome == 'ok', outcome
end

--- ======================================================================
--- TABLET CERTIFY -- THE OFFLINE-GRANT ASYMMETRY (server/tablet.lua's own
--- `qbx_k9unit:server:tabletCertify` callback, registered at the bottom of
--- this file). RevokeCertificationOffline above closes the identical gap
--- for REVOKE (a genuinely offline target, reached by citizenid). GRANT
--- cannot get the same treatment: §4.2.5's model check
--- (`IsConfiguredK9Model(GetEntityModel(GetPlayerPed(targetServerId)))`)
--- reads a LIVE ped's model, and this resource's schema has no persisted
--- "this citizenid plays a K9 model" fact to substitute for a disconnected
--- target -- there is nothing else in `k9_certifications`, qbx_core's
--- player table, or anywhere else this file can query, to stand in for it.
--- Building an "offline grant" that simply skipped that check would let
--- ANY citizenid -- a human character, not just an unlucky K9 who happens
--- to be logged off -- be certified as a K9 handler with nothing having
--- ever verified they can even be one; that is not a smaller version of
--- the real feature, it is a different, materially weaker one that quietly
--- drops the entire point of condition 5. DECISION: no offline grant path
--- exists. `GrantCertificationForTablet` below resolves `citizenid` to a
--- currently-connected server id and, if (and only if) that succeeds,
--- delegates to GrantCertification UNCHANGED -- the exact same eligibility,
--- cooldown, self-cert, proximity, model-check, INSERT, cache-refresh,
--- notification and outbound-event sequence a live '/k9certify [server id]'
--- would run, one code path, no duplicated authority. A disconnected
--- target fails closed with 'target_must_be_online', the SAME outcome (and
--- the SAME locale('certifications.target_must_be_online') message) a live
--- attempt against a since-disconnected target already produces today --
--- an honest, distinguishable, non-silent failure, never a weaker grant.
--- ======================================================================

--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string -- validated against Config.Departments as an
--- input-sanity/UX check only; NOT used to override the target's actual
--- live job -- GrantCertification (per its own §4.2.3 comment) always
--- certifies into whatever department the target's LIVE, server-read job
--- actually is, exactly as a live '/k9certify [server id]' attempt would.
--- A live job that does not match `departmentKey` is reported as
--- 'department_mismatch' rather than silently certifying into the
--- mismatched real department -- a stale tablet view (the target changed
--- department since the operator's roster/summary was last fetched) must
--- surface as an error the UI can react to, never a silent substitution of
--- what the operator actually clicked.
--- @return boolean ok
--- @return string outcome -- every GrantCertification outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'target_must_be_online' | 'department_mismatch'
local function GrantCertificationForTablet(granterSrc, citizenid, departmentKey)
    if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == '' then
        return false, 'invalid_target'
    end
    if not Config.Departments[departmentKey] then
        return false, 'invalid_department'
    end

    local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
    if not onlineTargetSrc then
        return false, 'target_must_be_online'
    end

    local liveJob = onlineTarget.PlayerData.job
    if not liveJob or liveJob.name ~= departmentKey then
        return false, 'department_mismatch'
    end

    return GrantCertification(granterSrc, onlineTargetSrc)
end

--- DEVELOPER_REFERENCE.md §4.2/§4.3 revoke flow (manual). Called by both event 3 and
--- command 7. Must work even when the target is offline (§4.3). Does NOT
--- run the model check (§4.2.5 applies to grant only).
--- CERTIFICATION DEPTH (this pass, Part A §2): `reason` is a NEW, OPTIONAL
--- third argument — nil/omitted (every pre-existing caller) behaves
--- exactly as before, recording a NULL `revoke_reason`. See this file's
--- header "REVOKE REASON" for the fixed vocabulary and why a mismatch is
--- rejected outright rather than silently stored as free text.
--- @param granterSrc number
--- @param targetServerId number
--- @param reason string? -- 'retired'|'reassigned'|'disciplinary'|'performance'|'other', or nil
local function RevokeCertification(granterSrc, targetServerId, reason)
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

    if reason ~= nil and not VALID_REVOKE_REASONS[reason] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_revoke_reason'), 'error')
        return
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
        -- so it cannot itself serve a genuinely offline target — DEVELOPER_REFERENCE.md
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
    -- row matches (DEVELOPER_REFERENCE.md §4.3).
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
    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` added to
    -- the SET clause — this SHIFTS the WHERE-clause params from
    -- positions [2]/[3] to [3]/[4] (SET-clause placeholders bind before
    -- WHERE-clause ones, left-to-right in the SQL text). Every existing
    -- test asserting on `updateParams[1..3]` for THIS call site was
    -- updated to match (tests/certifications_spec.lua) — a deliberate,
    -- reviewed shape change, not an accidental break.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_RevokeActive, targetCitizenid, targetJobName, granterCitizenid, reason)

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
        -- HUD display mirror only (DEVELOPER_REFERENCE.md §4.3) — never read for authorization.
        targetPlayer.Functions.SetMetaData('k9certified', false)
        NotifyPlayer(targetServerId, locale('certifications.revoked_notice_online'), 'error')

        -- QA finding fix, CONSOLIDATED (this pass) onto EndK9AccessForCitizenId
        -- above: an active leash pairing, an in-progress bite-hold/
        -- takedown/drag, and any partnership must not outlive the K9-role
        -- party's certification (DEVELOPER_REFERENCE.md §1/§4.4
        -- "immediately") — see that function's own doc comment for the
        -- full three-call writeup. `targetServerId` is already a live,
        -- currently-connected server id here (we're inside the
        -- `targetIsOnline` branch), so pass it as `knownSrc` rather than
        -- having the helper re-resolve it by citizenid.
        EndK9AccessForCitizenId(targetCitizenid, 'certification_revoked', targetServerId)
    end

    -- CERTIFICATION DEPTH (this pass, Part B §11): a specialization cannot
    -- outlive the base certification it requires — see this file's header
    -- "SPECIALIZATIONS". Called unconditionally of targetIsOnline (a
    -- specialization row is DB-backed, not in-memory-only, so this must
    -- run for an online OR offline target identically) — best-effort:
    -- logged on failure, never allowed to turn an already-confirmed base
    -- revoke back into a reported failure.
    RevokeAllSpecializationsForCitizenJob(targetCitizenid, targetJobName, granterCitizenid, 'certification_revoked')

    NotifyPlayer(granterSrc, locale('certifications.revoke_success'), 'success')
end

--- DEVELOPER_REFERENCE.md §4.3 offline-capable revoke flow (manual). Called only by the
--- '/k9decertifyoffline [citizenid] [job]' command — see that command's
--- registration below and this file's header (item 7b) for why there is
--- no client-triggerable event equivalent (a disconnected target has no
--- client to trigger anything from). Closes the gap RevokeCertification
--- above cannot: that function's numeric targetServerId contract can only
--- ever resolve a currently-connected player, but DEVELOPER_REFERENCE.md §4.3 requires
--- manual revoke to work on a genuinely offline target (this is the
--- explicit stated rationale for choosing a dedicated DB table as the
--- source of truth over qbx_core metadata in the first place — an
--- admin/chief must be able to pull a cert from someone who isn't logged
--- in right now). Same eligibility rule as the online path. Deliberately
--- has NO proximity check (impossible against a disconnected target — the
--- entire point of this path) and NO model check (revoke never runs the
--- model check regardless of online/offline status, per §4.2.5 being
--- grant-only).
--- CERTIFICATION DEPTH (this pass, Part A §2): `reason` is a NEW, OPTIONAL
--- fourth argument — see RevokeCertification's own identical doc comment.
--- @param granterSrc number
--- @param citizenid string
--- @param job string
--- @param reason string? -- 'retired'|'reassigned'|'disciplinary'|'performance'|'other', or nil
local function RevokeCertificationOffline(granterSrc, citizenid, job, reason)
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

    if reason ~= nil and not VALID_REVOKE_REASONS[reason] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_revoke_reason'), 'error')
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
    -- and DEVELOPER_REFERENCE.md §4.3) — that's the entire justification for skipping
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
    -- row matches (DEVELOPER_REFERENCE.md §4.3). Same UPDATE pattern as the online path —
    -- including the same pcall + reconcile-on-throw discipline; see
    -- RevokeCertification's own doc comment above for the full reasoning
    -- (a thrown DB error must degrade this offline-capable command, not
    -- raise an uncaught script error, and a SQL transaction would not
    -- resolve the one genuine ambiguity a thrown error can leave behind
    -- here either).
    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` added,
    -- same positional shift as RevokeCertification's own UPDATE above —
    -- this call site's own test assertion was updated to match.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_RevokeActive, citizenid, job, granterCitizenid, reason)

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
    -- than leaving a drifted entry around. Matches DEVELOPER_REFERENCE.md §4.3's
    -- "invalidated/updated immediately on grant/revoke events".
    RefreshCertificationCache(citizenid, job)

    -- Regression-test fix: keep the read-only `k9certified` HUD mirror
    -- (DEVELOPER_REFERENCE.md §4.3 — never read for authorization, see GrantCertification's
    -- comment on the same field) from drifting stale. The online guard
    -- above already refused this whole path if the citizenid resolved to a
    -- connected player at the time it was checked, so this is normally a
    -- no-op; it only matters for the narrow TOCTOU window where the target
    -- reconnects between that guard and this UPDATE completing — same
    -- window EndK9AccessForCitizenId below is already written to cover.
    local nowOnlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if nowOnlinePlayer and nowOnlinePlayer.PlayerData and nowOnlinePlayer.PlayerData.source then
        nowOnlinePlayer.Functions.SetMetaData('k9certified', false)
    end

    -- QA finding fix, CONSOLIDATED (this pass) onto EndK9AccessForCitizenId
    -- above: tear down an active leash pairing, an in-progress bite-hold/
    -- takedown/drag, and any partnership for this citizenid, per
    -- DEVELOPER_REFERENCE.md §1/§4.4. In the overwhelmingly common case the
    -- leash/hold half is a genuine no-op — the online guard earlier in this
    -- function already refused this whole path if the citizenid resolved
    -- to a connected player at that point, and both are in-memory-only, so
    -- a genuinely offline target cannot have either to begin with. Still
    -- called unconditionally (rather than assumed unreachable) to close
    -- the narrow TOCTOU window where the target reconnects between that
    -- guard and this UPDATE completing — see EndK9AccessForCitizenId's own
    -- doc comment for the full writeup. Passes `nowOnlinePlayer`'s
    -- already-resolved source (reused from the `k9certified` mirror write
    -- immediately above, no synchronous state change possible in between)
    -- as `knownSrc`, exactly like this function's own prior separate
    -- lookups for leash-detach and hold-end used to do independently — a
    -- behavior-preserving simplification to one lookup, not a change in
    -- what gets resolved. ForceBreakPartnershipForCitizenId, unlike the
    -- leash/hold half, runs even when `knownSrc` resolves to nothing: a K9
    -- partnership is DB-backed and DOES persist across a disconnect
    -- (server/partnership.lua's own "OFFLINE-CAPABLE BY DESIGN" header
    -- section) — this is in fact THE call site that design decision exists
    -- for, since a genuinely offline K9-role citizenid revoked while
    -- off-shift must still have any real, active partnership row torn
    -- down, or it would otherwise stand indefinitely.
    EndK9AccessForCitizenId(citizenid, 'certification_revoked',
        nowOnlinePlayer and nowOnlinePlayer.PlayerData and nowOnlinePlayer.PlayerData.source)

    -- CERTIFICATION DEPTH (this pass, Part B §11): same cascade as
    -- RevokeCertification's online branch — DB-authoritative, so this
    -- works correctly for this genuinely-offline citizenid (see
    -- RevokeAllSpecializationsForCitizenJob's own doc comment for why it
    -- deliberately does not rely on the in-memory cache here).
    RevokeAllSpecializationsForCitizenJob(citizenid, job, granterCitizenid, 'certification_revoked')

    NotifyPlayer(granterSrc, locale('certifications.revoke_success'), 'success')
end

-- ======================================================================
-- CERTIFICATION DEPTH (this pass) — TIER / RENEWAL / SPECIALIZATION
-- ACTIONS. See this file's header for the full design writeup. All FIVE
-- functions below share the same shape: IsEligibleCertifier + the SAME
-- CertifyActionCooldown instance grant/revoke already use (this file's
-- own established "one shared cooldown per related-action group"
-- convention) + the SAME self-action/proximity rules GrantCertification
-- uses. DELIBERATE SCOPE REDUCTION vs. RevokeCertification's own
-- reconcile-on-throw dance: these five are secondary-capability actions
-- that never flip base access on their own (a thrown UPDATE here reports
-- a plain error and changes nothing, rather than reconciling against an
-- independent read) — the elaborate reconciliation RevokeCertification
-- performs exists specifically because a WRONGLY-reported outcome on the
-- primary access gate is a real security/trust problem; these five are
-- not that, and treating them identically would be needless complexity
-- for a much lower-stakes mutation. Stated explicitly here, not silently
-- decided, per this task's own instruction to keep the model something
-- an operator (and a reviewer) can hold in their head.
-- ======================================================================

--- Changes `targetServerId`'s certification tier for their OWN currently
--- active department certification. Deliberately SEPARATE from
--- GrantCertification (see header "TIER") — every grant still always
--- creates a 'certified' row; this is the only way to move a citizenid to
--- 'trainee' or 'senior'.
--- @param granterSrc number
--- @param targetServerId number
--- @param newTier string -- 'trainee'|'certified'|'senior'
local function SetCertificationTier(granterSrc, targetServerId, newTier)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return
    end

    -- OWNER-DIRECTED TIER-EDITING PASS: was `not TIER_RANK[newTier]`
    -- (only trainee/certified/senior could ever be assigned) — now
    -- accepts any tier key the live, operator-extensible catalog
    -- currently recognizes. See IsKnownTierKeyOrLegacyFallback above.
    if type(newTier) ~= 'string' or not IsKnownTierKeyOrLegacyFallback(newTier) then
        NotifyPlayer(granterSrc, locale('certifications.invalid_tier'), 'error')
        return
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
        return
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.action_target_must_be_online'), 'error')
        return
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far'), 'error')
            return
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    local cached = jobName and Certifications[targetCitizenid]
    if not (cached and cached.active and cached.job == jobName) then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified'), 'error')
        return
    end

    if cached.tier == newTier then
        NotifyPlayer(granterSrc, locale('certifications.tier_already_set'), 'inform')
        return
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return end

    local oldTier = cached.tier

    -- TIER CATALOG RACE GUARD (owner-directed tier-editing pass,
    -- server/certtiers.lua) — see that file's own header "HAZARD 4",
    -- "THE DELETE-VS-ASSIGN RACE" for the full writeup. Acquires the SAME
    -- cross-file TierEditMutex, keyed by `newTier`, that
    -- server/certtiers.lua's DeleteTier acquires before its own
    -- reference-count check + tombstone write — this closes the window
    -- where a concurrent delete of `newTier` could otherwise land between
    -- "this key is currently known" (already checked above) and this
    -- UPDATE actually committing, which would leave this row referencing
    -- a tier that no longer exists (exactly the outcome this feature's
    -- own hazard list forbids). Guarded by a `type(...) == 'table'`
    -- runtime existence check, this resource's established soft-
    -- dependency convention — this function still works exactly as
    -- before (accepting only the previously-undocumented, now-disclosed,
    -- narrow race) if server/certtiers.lua is ever removed.
    local haveTierMutex = type(TierEditMutex) == 'table'
    if haveTierMutex and not TierEditMutex.TryAcquire(newTier) then
        NotifyPlayer(granterSrc, locale('certifications.tier_change_error'), 'error')
        return
    end

    -- Re-check AFTER acquiring the lock, in case `newTier` was deleted by
    -- a concurrent DeleteTier call in the gap between the earlier check
    -- and acquiring this lock — refuse now rather than write a reference
    -- to a tier that no longer exists.
    if haveTierMutex and not IsKnownTierKeyOrLegacyFallback(newTier) then
        TierEditMutex.Release(newTier)
        NotifyPlayer(granterSrc, locale('certifications.invalid_tier'), 'error')
        return
    end

    local updateOk, err = pcall(K9Store.Cert_SetTier, targetCitizenid, jobName, newTier)

    if haveTierMutex then TierEditMutex.Release(newTier) end

    if not updateOk then
        print(('[qbx_k9unit] SetCertificationTier UPDATE failed for %s/%s: %s'):format(targetCitizenid, jobName, tostring(err)))
        NotifyPlayer(granterSrc, locale('certifications.tier_change_error'), 'error')
        return
    end

    RefreshCertificationCache(targetCitizenid, jobName)
    FireOutboundEvent('qbx_k9unit:events:certificationTierChanged', targetCitizenid, jobName, oldTier, newTier, granterCitizenid)

    NotifyPlayer(granterSrc, locale('certifications.tier_change_success_granter', newTier), 'success')
    NotifyPlayer(targetServerId, locale('certifications.tier_change_success_target', newTier), 'success')
end

--- Extends `targetServerId`'s certification expiry by
--- `Config.CertificationExpiryDays` from now, WITHOUT touching
--- `granted_at`/`granted_by` (the original grant lineage is preserved —
--- this is a renewal, not a re-grant). See header "EXPIRY" — date
--- arithmetic happens in SQL (`DATE_ADD(NOW(), INTERVAL ? DAY)`), never in
--- Lua. Does NOT re-run the K9-model check (mirrors RevokeCertification's
--- own "model check is grant-only" precedent — a renewal is re-affirming
--- paperwork, not re-verifying identity).
--- @param granterSrc number
--- @param targetServerId number
local function RenewCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return
    end

    -- CLAMP-AND-WARN on a misconfigured CertificationExpiryDays lives in
    -- ResolveConfiguredExpiryDays (shared with GrantCertification above) —
    -- see its own doc comment. Returns nil identically whether the feature
    -- is genuinely off or misconfigured while on; either way there is
    -- nothing to renew, so this notice stays accurate for both cases (a
    -- misconfiguration ALSO prints its own, separate, operator-facing
    -- console warning naming the exact bad value).
    local expiryDays = ResolveConfiguredExpiryDays()
    if not expiryDays then
        NotifyPlayer(granterSrc, locale('certifications.renew_feature_disabled'), 'error')
        return
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
        return
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.action_target_must_be_online'), 'error')
        return
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far'), 'error')
            return
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    local cached = jobName and Certifications[targetCitizenid]
    if not (cached and cached.active and cached.job == jobName) then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified'), 'error')
        return
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return end

    local updateOk, err = pcall(K9Store.Cert_RenewExpiry, targetCitizenid, jobName, expiryDays)

    if not updateOk then
        print(('[qbx_k9unit] RenewCertification UPDATE failed for %s/%s: %s'):format(targetCitizenid, jobName, tostring(err)))
        NotifyPlayer(granterSrc, locale('certifications.renew_error'), 'error')
        return
    end

    RefreshCertificationCache(targetCitizenid, jobName)
    local newCached = Certifications[targetCitizenid]
    FireOutboundEvent('qbx_k9unit:events:certificationRenewed', targetCitizenid, jobName, newCached and newCached.expiresAtUnix, granterCitizenid)

    -- A successful, explicit renewal clears the one-per-session warning/
    -- lapsed flags — see the sweep thread below for why these exist; a
    -- fresh renewal genuinely un-lapses a certification, so the next
    -- sweep pass should be able to warn/announce again on its own future
    -- merits, not stay silenced by a flag set before this renewal.
    ExpiryWarned[targetCitizenid] = nil
    ExpiryLapsedNotified[targetCitizenid] = nil

    NotifyPlayer(granterSrc, locale('certifications.renew_success_granter'), 'success')
    NotifyPlayer(targetServerId, locale('certifications.renew_success_target'), 'success')
end

--- Grants `specializationKey` (a `Config.K9Specializations` key) to
--- `targetServerId` for their OWN currently active department
--- certification. See header "SPECIALIZATIONS" / "WHY THIS DOES NOT REUSE
--- k9_permissions" for the full authorization/design writeup. Mirrors
--- GrantCertification's own online+proximity requirement and TOCTOU
--- lock shape (reusing the SAME `GrantInFlight` table under a distinct,
--- 'spec:'-prefixed key namespace so it can never collide with a base
--- certification's own lock key).
--- @param granterSrc number
--- @param targetServerId number
--- @param specializationKey string
local function GrantSpecialization(granterSrc, targetServerId, specializationKey)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return
    end

    local catalog = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    if type(specializationKey) ~= 'string' or not catalog[specializationKey] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_specialization'), 'error')
        return
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
        return
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.action_target_must_be_online'), 'error')
        return
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far'), 'error')
            return
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    local cached = jobName and Certifications[targetCitizenid]
    -- SECURITY FIX (coder-security, tier-bypass-on-expiry review): this
    -- precondition used to omit `not cached.expired`, unlike
    -- GetCertificationTier a few hundred lines below (which this same
    -- file's own header already documents as requiring it). An
    -- EXPIRED-but-still-`active`-in-the-DB row (see RefreshCertificationCache's
    -- doc comment: `active` tracks "not manually revoked", `expired` is a
    -- SEPARATE, independent time-based flag) used to pass this check, so a
    -- certifier could hand a target a brand-new specialization at the exact
    -- moment enforcement should be STRICTER than normal -- the target's base
    -- certification has already lapsed -- not absent. Matches
    -- GetCertificationTier's own `not cached.expired` term exactly, so a
    -- target whose tier is unresolvable for this reason is refused here for
    -- the same, pre-existing "requires an active certification" reason,
    -- not a new one.
    if not (cached and cached.active and cached.job == jobName and not cached.expired) then
        NotifyPlayer(granterSrc, locale('certifications.specialization_requires_active_cert'), 'error')
        return
    end

    -- CERTIFICATION TIER CAPABILITIES (this pass, coordinator-assigned --
    -- server/certtiers.lua's TierCapabilityPermits had zero real consumers
    -- anywhere in this resource until now). This is a SECOND, INDEPENDENT
    -- gate from the active-cert check directly above: `cached.active` and
    -- `cached.job == jobName` only prove the target holds SOME active
    -- certification for the right department, not that their CURRENT tier
    -- is one an operator has actually opted into allowing specializations
    -- for. Placed immediately after that check, never before it, so a
    -- target who fails the active-cert check gets that (more fundamental)
    -- reason, not this one.
    --
    -- Guarded with `type(...) == 'function'`, this resource's established
    -- soft-dependency convention -- server/certtiers.lua loads AFTER this
    -- file in fxmanifest.lua's server_scripts list, so this cannot be
    -- assumed present by load order (same reasoning as every other
    -- guarded cross-file call in this file). Fails OPEN (falls through to
    -- the grant path) when the global is absent -- matching
    -- TierCapabilityPermits' own documented fail-permissive contract, not
    -- a separate decision made here: every existing install predates tier
    -- capabilities entirely, and this call site failing closed on a
    -- missing/older server/certtiers.lua would silently strip a working
    -- specialization-grant flow for every operator who hasn't touched a
    -- single tier capability from the tablet.
    --
    -- GATES GRANTING ONLY, never holding: this is the ONE call site in
    -- this file that consults TierCapabilityPermits for specializations,
    -- and it runs only inside the grant flow above. HasSpecialization
    -- (this file, the read-only accessor every other feature actually
    -- calls to check whether a citizenid currently holds a specialization)
    -- does NOT call TierCapabilityPermits and must not be changed to --
    -- see that function's own doc comment. Nothing in this file cascades
    -- a tier change into stripping an already-granted specialization
    -- either (SetCertificationTier above never touches Specializations/
    -- the specialization DB rows at all), so a handler who already holds
    -- a specialization and whose tier later loses this capability (an
    -- operator un-ticks it from the tablet, or the handler is demoted)
    -- keeps that specialization exactly as HandlerPartnership/leash/etc.
    -- keep working after a permission source changes -- this gate only
    -- ever blocks a NEW grant, never revokes an existing one. If a future
    -- pass ever wants "losing the capability revokes the specialization
    -- too", that is a deliberate new decision belonging next to
    -- RevokeAllSpecializationsForCitizenJob, not an accidental side effect
    -- of this check.
    if type(TierCapabilityPermits) == 'function'
        and not TierCapabilityPermits(targetCitizenid, jobName, 'specializations_eligible') then
        NotifyPlayer(granterSrc, locale('certifications.specialization_requires_tier_capability'), 'error')
        return
    end

    local lockKey = 'spec:' .. targetCitizenid .. ':' .. jobName .. ':' .. specializationKey
    if GrantInFlight[lockKey] then
        NotifyPlayer(granterSrc, locale('certifications.specialization_already_granted'), 'inform')
        return
    end
    GrantInFlight[lockKey] = true

    local function doGrantInsert()
        local existingId = K9Store.Spec_GetActiveId(targetCitizenid, jobName, specializationKey)
        if existingId then
            NotifyPlayer(granterSrc, locale('certifications.specialization_already_granted'), 'inform')
            return
        end

        local granterCitizenid = ResolveGranterCitizenId(granterSrc)
        if not granterCitizenid then return end

        local insertOk, insertErr = pcall(K9Store.Spec_Insert, targetCitizenid, jobName, specializationKey, granterCitizenid)

        if not insertOk then
            if IsDuplicateKeyError(insertErr) then
                RefreshSpecializationCache(targetCitizenid, jobName)
                NotifyPlayer(granterSrc, locale('certifications.specialization_already_granted'), 'inform')
                return
            end
            print(('[qbx_k9unit] GrantSpecialization INSERT failed for %s/%s/%s: %s'):format(targetCitizenid, jobName, specializationKey, tostring(insertErr)))
            NotifyPlayer(granterSrc, locale('certifications.specialization_grant_error'), 'error')
            return
        end

        RefreshSpecializationCache(targetCitizenid, jobName)
        FireOutboundEvent('qbx_k9unit:events:specializationGranted', targetCitizenid, jobName, specializationKey, granterCitizenid)

        NotifyPlayer(granterSrc, locale('certifications.specialization_grant_success_granter', specializationKey), 'success')
        NotifyPlayer(targetServerId, locale('certifications.specialization_grant_success_target', specializationKey), 'success')
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    if not grantOk then
        print(('[qbx_k9unit] GrantSpecialization unexpected error for %s/%s/%s: %s'):format(targetCitizenid, jobName, specializationKey, tostring(grantErr)))
        NotifyPlayer(granterSrc, locale('certifications.specialization_grant_error'), 'error')
    end
end

--- Revokes `specializationKey` from `targetServerId` (online-capable
--- path — see RevokeSpecializationOffline below for a genuinely
--- disconnected target). Mirrors RevokeCertification's own online
--- proximity rule; does NOT require the base certification to still be
--- active (a specialization can legitimately be pulled independently of
--- the base cert, e.g. a narcotics-specific disciplinary issue that
--- doesn't warrant a full decertification).
--- @param granterSrc number
--- @param targetServerId number
--- @param specializationKey string
local function RevokeSpecialization(granterSrc, targetServerId, specializationKey)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target'), 'error')
        return
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return
    end

    if type(specializationKey) ~= 'string' or specializationKey == '' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_specialization'), 'error')
        return
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled'), 'error')
        return
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.specialization_target_offline_use_offline_command'), 'error')
        return
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far'), 'error')
            return
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    if not jobName or not Config.Departments[jobName] then
        NotifyPlayer(granterSrc, locale('certifications.target_no_department_cert'), 'error')
        return
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return end

    local updateOk, affectedRowsOrErr = pcall(K9Store.Spec_RevokeOne, targetCitizenid, jobName, specializationKey, granterCitizenid)

    if not updateOk then
        print(('[qbx_k9unit] RevokeSpecialization UPDATE failed for %s/%s/%s: %s'):format(targetCitizenid, jobName, specializationKey, tostring(affectedRowsOrErr)))
        NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_error'), 'error')
        return
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        NotifyPlayer(granterSrc, locale('certifications.specialization_not_granted'), 'inform')
        return
    end

    RefreshSpecializationCache(targetCitizenid, jobName)
    FireOutboundEvent('qbx_k9unit:events:specializationRevoked', targetCitizenid, jobName, specializationKey, 'manual')

    NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_success_granter', specializationKey), 'success')
    NotifyPlayer(targetServerId, locale('certifications.specialization_revoke_success_target', specializationKey), 'error')
end

--- Offline-capable counterpart to RevokeSpecialization, mirroring
--- RevokeCertificationOffline's exact shape (own online-check guard,
--- deliberately no proximity check — impossible against a disconnected
--- target).
--- @param granterSrc number
--- @param citizenid string
--- @param job string
--- @param specializationKey string
local function RevokeSpecializationOffline(granterSrc, citizenid, job, specializationKey)
    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke'), 'error')
        return
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == ''
        or type(specializationKey) ~= 'string' or specializationKey == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_unspecialize_offline'), 'error')
        return
    end

    if not Config.Departments[job] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department', job), 'error')
        return
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return end

    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, locale('certifications.specialization_target_online_use_online_command', onlineCheckTarget.PlayerData.source), 'error')
        return
    end

    local updateOk, affectedRowsOrErr = pcall(K9Store.Spec_RevokeOne, citizenid, job, specializationKey, granterCitizenid)

    if not updateOk then
        print(('[qbx_k9unit] RevokeSpecializationOffline UPDATE failed for %s/%s/%s: %s'):format(citizenid, job, specializationKey, tostring(affectedRowsOrErr)))
        NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_error'), 'error')
        return
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        NotifyPlayer(granterSrc, locale('certifications.specialization_not_granted'), 'inform')
        return
    end

    RefreshSpecializationCache(citizenid, job)
    FireOutboundEvent('qbx_k9unit:events:specializationRevoked', citizenid, job, specializationKey, 'manual_offline')

    NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_success_granter', specializationKey), 'success')
end

-- ======================================================================
-- READ-ONLY ACCESSORS (this pass) — exposed globally (no `local`) for
-- future Phase 2/3 gates (search.lua/combat.lua/defense.lua-style files,
-- none of which this pass reaches into — see header "TIER") and for
-- whichever file ends up owning the tablet's roster aggregation (see
-- header "CACHE SHAPE" / server/permissions.lua's own
-- ListActivePermissionsForCitizenId precedent for the identical
-- "expose an accessor, let another file aggregate" pattern).
-- ======================================================================

--- Cache-based, hot-path-safe: `citizenid`'s current tier for `jobName`,
--- or nil if not actively/matchingly certified (regardless of whether
--- that's because they were never certified, were revoked, or their
--- certification has lapsed — same "just say no capability" shape
--- HasK9Access already uses, not a 3-way distinction, for every caller that
--- omits `includeExpired`).
---
--- SECURITY FIX (coder-security, tier-bypass-on-expiry review) — added the
--- optional 3rd parameter `includeExpired` (does NOT change this function's
--- name or its existing 2-argument callers' behavior at all — every one of
--- them keeps getting exactly the collapsed "expired counts as no tier"
--- answer above): server/certtiers.lua's TierCapabilityPermits needs a
--- DIFFERENT answer than every other consumer. That function's own contract
--- is fail-PERMISSIVE when a citizenid's tier "cannot be resolved" —
--- deliberately, because HasK9Access grants access through THREE routes
--- this file cannot express as a tier at all (a 'k9.access' permission
--- grant, an autoAccessGrade job grade, or high command), and none of those
--- citizenids should ever be denied a capability just because this file has
--- no tier to name them by. But the 2-argument form ALSO returns nil for a
--- citizenid who very much DOES have a tier assignment — one whose
--- certification has simply EXPIRED — and folding that case into
--- "unresolvable" let an expired handler who still holds K9 access via one
--- of the other three routes silently regain any capability an operator
--- explicitly withheld from their assigned tier, on every ordinary
--- certification lapse, with no action from anyone. That is a STALE tier,
--- not an absent one — the underlying cache can tell the two apart because
--- `active` (a real, non-revoked k9_certifications row exists) and
--- `expired` (that row's expires_at has passed) are independent flags (see
--- RefreshCertificationCache's own doc comment). `includeExpired = true`
--- returns that real, assigned tier EVEN IF it has expired; nil, even with
--- `includeExpired = true`, means there truly is no active/job-matching row
--- at all (never certified for this job, or a manually revoked one) — the
--- ONLY population TierCapabilityPermits should still treat as
--- unresolvable-and-allowed. A non-nil result — stale or not — is what
--- TierCapabilityPermits must evaluate for real, never skip.
--- @param citizenid string
--- @param jobName string
--- @param includeExpired boolean? -- default false/nil: unchanged, original
--- behavior. true: also return an EXPIRED tier rather than folding it into
--- nil (see SECURITY FIX above).
--- @return string?
function GetCertificationTier(citizenid, jobName, includeExpired)
    local cached = Certifications[citizenid]
    if cached and cached.active and cached.job == jobName and (includeExpired or not cached.expired) then
        return cached.tier
    end
    return nil
end

--- Cache-based, hot-path-safe: does `citizenid` currently hold AT LEAST
--- `minTier` for `jobName`? Ordinal comparison via TIER_RANK — a future
--- Phase 2/3 gate calls this instead of duplicating the tier-ranking
--- logic itself. Fails closed on a nil actual tier (not certified) or an
--- unrecognized `minTier` (a typo'd tier name must never accidentally
--- open a gate; a malformed argument is a bug, not a low bar to clear).
--- @param citizenid string
--- @param jobName string
--- @param minTier string
--- @return boolean
function MeetsTierRequirement(citizenid, jobName, minTier)
    -- OWNER-DIRECTED TIER-EDITING PASS: ordinal comparison now defers to
    -- the live, operator-extensible catalog (server/certtiers.lua) via
    -- GetTierOrdinalOrLegacyFallback, so a future gate can compare
    -- against an operator-ADDED tier, not just the original three.
    if not IsKnownTierKeyOrLegacyFallback(minTier) then return false end
    local actualTier = GetCertificationTier(citizenid, jobName)
    if not IsKnownTierKeyOrLegacyFallback(actualTier) then return false end
    local actualOrdinal = GetTierOrdinalOrLegacyFallback(actualTier)
    local minOrdinal = GetTierOrdinalOrLegacyFallback(minTier)
    if not actualOrdinal or not minOrdinal then return false end
    return actualOrdinal >= minOrdinal
end

--- Cache-based, hot-path-safe: does `citizenid` currently hold
--- `specializationKey` for `jobName`? Also requires the BASE certification
--- to currently be active/matching/unexpired — see header "SPECIALIZATIONS":
--- an expired base certification softly disables its specializations too,
--- the same "stop granting NEW access, never force-detach" posture
--- HasK9Access already applies one level up.
--- @param citizenid string
--- @param jobName string
--- @param specializationKey string
--- @return boolean
function HasSpecialization(citizenid, jobName, specializationKey)
    local cached = Certifications[citizenid]
    if not (cached and cached.active and cached.job == jobName and not cached.expired) then return false end
    local jobSpecs = Specializations[citizenid] and Specializations[citizenid][jobName]
    return jobSpecs ~= nil and jobSpecs[specializationKey] == true
end

--- DB-authoritative (works for an OFFLINE citizenid too, unlike the
--- cache-based accessors above — for tablet/roster/admin reads, mirroring
--- server/permissions.lua's own ListActivePermissionsForCitizenId
--- precedent). Fails closed (returns nil) on a query error or an
--- unreadable citizenid, matching this file's own established SafeQuery
--- posture.
--- @param citizenid string
--- @param jobName string
--- @return table? record -- { tier, grantedBy, grantedAt, revokedBy, revokedAt, revokeReason, expiresAtUnix, specializations: string[] } for the active row, or nil if none
function QueryCertificationRecord(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then return nil end

    local ok, row = pcall(K9Store.Cert_GetActiveRecord, citizenid, jobName)
    if not ok or not row then
        if not ok then
            print(('[qbx_k9unit] QueryCertificationRecord query failed for %s/%s: %s'):format(citizenid, jobName, tostring(row)))
        end
        return nil
    end

    return {
        tier = row.tier,
        grantedBy = row.granted_by,
        grantedAt = row.granted_at,
        revokedBy = row.revoked_by,
        revokedAt = row.revoked_at,
        revokeReason = row.revoke_reason,
        expiresAtUnix = tonumber(row.expires_at_unix),
        specializations = QueryActiveSpecializations(citizenid, jobName),
    }
end

--- DB-authoritative list of every specialization key `citizenid` currently
--- holds for `jobName` — see QueryCertificationRecord's own doc comment
--- for the "works offline, fails closed" contract this shares.
--- @param citizenid string
--- @param jobName string
--- @return string[]
function QueryActiveSpecializations(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then return {} end

    local ok, rows = pcall(K9Store.Spec_GetActiveKeys, citizenid, jobName)
    if not ok then
        print(('[qbx_k9unit] QueryActiveSpecializations query failed for %s/%s: %s'):format(citizenid, jobName, tostring(rows)))
        return {}
    end

    local out = {}
    for i, row in ipairs(rows or {}) do
        out[i] = row.specialization
    end
    return out
end

--- DEVELOPER_REFERENCE.md §4.4 (NEW): automatic revoke when actually leaving the
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
    -- to a K9 never holds a K9 certification of their own (DEVELOPER_REFERENCE.md §9 item
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

        -- FIFTH-GAP FIX (this pass -- "four doors, one bug", closing the
        -- fifth): this branch used to stop at the ForceDetachOfficerLeashForSource
        -- call above, which only ever detaches `source` when they are
        -- currently the OFFICER/handler-role party of a pairing. It never
        -- checked the OTHER role: `source` currently being the K9-ROLE
        -- party. HasK9Access(source) (this file, above) hard-gates on
        -- `Config.Departments[job.name]` as its VERY FIRST check, before
        -- the permission-grant bypass, the high-command bypass, the
        -- cert-cache read, or the autoAccessGrade bypass are ever
        -- consulted -- so losing department membership entirely means
        -- HasK9Access is now unconditionally false for `source`, REGARDLESS
        -- of which route (an active certification, a server/permissions.lua
        -- 'k9.access' grant, or an autoAccessGrade rank) used to grant it.
        -- A K9-role party whose ONLY route was a certification is already
        -- covered further below (the cert-revoke-due-to-job-change branch,
        -- gated on `cached.active`) -- but a K9-role party with NO
        -- certification row at all (autoAccessGrade- or permission-grant-
        -- only access) has no active row in `Certifications` for that
        -- branch to ever observe, so it never fires for them, and until
        -- this fix nothing else in this handler did either: they kept
        -- their leash, an in-progress bite-hold/takedown/drag, and any
        -- partnership indefinitely on leaving the department entirely --
        -- the exact "handler loses K9 access mid-incident and their dog
        -- keeps holding a suspect" shape this file already closes for a
        -- certification loss, reached through the one door that was still
        -- open. EndK9AccessForCitizenId (this file, above) is UNCONDITIONAL
        -- here, never re-gated on "does source currently hold K9-role
        -- access via some other route" -- there is no other route left to
        -- check: department membership loss alone already makes
        -- HasK9Access false for every route at once (see the hard gate
        -- described above), so this cannot collide with the SEPARATE
        -- same-department autoAccessGrade-demotion branch below (which
        -- DOES need its own "does the new job still grant non-cert access"
        -- computation, because THAT branch's job still passes
        -- Config.Departments membership) or with the job-name-change
        -- cert-revoke branch's own DB-write reconciliation dance (this
        -- branch performs no DB write of its own at all -- it is pure,
        -- unconditional teardown of ephemeral/session state, same as the
        -- officer-role call directly above it always has been). `source`
        -- is already live here (OnJobUpdate fired for it), so passed
        -- directly as `knownSrc`. See EndK9AccessForCitizenId's own doc
        -- comment for the full three-call (leash/hold/partnership)
        -- writeup, and this file's header FILE-TO-FILE CONTRACT section
        -- for this branch's place in the "five known call sites, one
        -- fixed this pass" history.
        EndK9AccessForCitizenId(citizenid, 'department_changed', source)
    end

    local cached = Certifications[citizenid]

    -- SECOND, INDEPENDENT gap in the "loses K9 access" family (distinct
    -- from leaving the department above and from losing an active
    -- certification below): HasK9Access grants K9-role access via THREE
    -- routes and keeps no record of which one applied -- an active
    -- certification (this file's own Certifications cache), an active
    -- `k9.access` permission grant (server/permissions.lua), or a job
    -- grade at/above Config.Departments[job].autoAccessGrade. A citizenid
    -- whose ONLY route is autoAccessGrade has no active row in
    -- Certifications at all, so the job-name-change branch below (gated
    -- on `cached.active`) returns before it ever looks at the grade. Left
    -- unhandled, an ordinary SAME-department demotion below
    -- autoAccessGrade left an already-formed K9-role leash pairing,
    -- partnership row, and any in-progress bite-hold/takedown/drag
    -- completely untouched -- identical in shape to the
    -- leash-holding-a-suspect-for-twenty-seconds incident this file
    -- already closed for the certification-revoke path, just reached
    -- through a different door, and reachable with NO admin action at all
    -- -- an ordinary promotion/demotion does it.
    --
    -- SCOPED DELIBERATELY NARROW to avoid any interaction with the
    -- job-name-change reconciliation logic below (which owns its own
    -- DB-write confirm/reconcile dance end to end): this only fires when
    -- `cached` already exists AND is scoped to this EXACT job name --
    -- i.e. this is provably a grade-only change within the department
    -- this citizenid was already known to be in as of their last cache
    -- refresh (PlayerLoaded, the onResourceStart backfill, or their own
    -- prior grant/revoke/OnJobUpdate touch), never a cross-department
    -- move (which the branch below already owns). `cached` being ABSENT
    -- (never refreshed this session) or scoped to a DIFFERENT job name (a
    -- genuine department change, however recent) both intentionally skip
    -- this branch -- neither can be told apart from a same-department
    -- demotion without a second job-tracking cache this fix does not
    -- introduce. DISCLOSED, NARROW RESIDUAL WINDOW: a non-cert citizenid
    -- who changes department more than once without an intervening
    -- PlayerLoaded/backfill keeps a stale `cached.job` from before their
    -- most recent move, so a LATER same-department demotion in their NEW
    -- department would not be caught by this branch either -- accepted
    -- rather than adding a second cache purely to close it, since
    -- HasK9Access itself (the actual authorization gate) is never wrong
    -- either way; only this best-effort teardown trigger can miss it.
    if job and Config.Departments[job.name] and cached and cached.job == job.name and not cached.active then
        local dept = Config.Departments[job.name]
        local stillHasNonCertAccess =
            (type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access'))
            or (type(IsHighCommand) == 'function' and IsHighCommand(source))
            or (type(dept.autoAccessGrade) == 'number' and job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.autoAccessGrade)

        if not stillHasNonCertAccess then
            -- Mirrors RevokeCertification's online branch exactly, via the
            -- same EndK9AccessForCitizenId helper (CONSOLIDATED this pass)
            -- -- called UNCONDITIONALLY once this specific access route is
            -- confirmed lost, never re-gated on whether some OTHER route
            -- might independently justify keeping the pairing: the
            -- leash/partnership/hold that exist right now were formed
            -- under eligibility that no longer holds, and a fresh
            -- HasK9Access re-check on the next real access attempt is
            -- what re-establishes anything, not a stale pairing carried
            -- over from before this demotion. `source` is already live
            -- here, passed as `knownSrc`.
            EndK9AccessForCitizenId(citizenid, 'k9_access_lost', source)
        end
    end

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
    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` is
    -- always 'reassigned' for this automatic path — an accurate,
    -- non-punitive category for "this handler changed department,"
    -- distinct from the mechanism tag ('job_changed') the outbound event
    -- below already carries. Same positional shift as the two manual
    -- revoke paths above; this call site's own test assertion was
    -- updated to match.
    local updateOk, updateErr = pcall(K9Store.Cert_RevokeActive, citizenid, oldJob, 'system:job_change', 'reassigned')

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
    -- either way per DEVELOPER_REFERENCE.md §9 item 3).
    RefreshCertificationCache(citizenid, job.name)

    -- Regression-test fix: keep the read-only `k9certified` HUD mirror
    -- (DEVELOPER_REFERENCE.md §4.3) in sync here too — this player is online by
    -- definition (OnJobUpdate fired for their live Player object), so this
    -- is a plain, unconditional write, no online-check needed.
    Player.Functions.SetMetaData('k9certified', false)

    local deptLabel = (Config.Departments[oldJob] and Config.Departments[oldJob].label) or oldJob
    NotifyPlayer(source, locale('certifications.revoked_notice_job_change', deptLabel), 'error')

    -- QA finding fix (DEVELOPER_REFERENCE.md §1/§4.4 "immediately"),
    -- CONSOLIDATED (this pass) onto EndK9AccessForCitizenId above: this
    -- player is online by definition (OnJobUpdate fired for their live
    -- `source`), so pass it as `knownSrc` rather than having the helper
    -- re-resolve it by citizenid — same reasoning as the online branch of
    -- RevokeCertification above. This branch is only reached for a
    -- K9-role citizenid — the department-membership-only handler/officer
    -- role never holds a certification of its own (see this handler's own
    -- comment near its top on that exact asymmetry) — so `citizenid` here
    -- is always the K9-role party of any active leash/hold/partnership it
    -- might hold. See EndK9AccessForCitizenId's own doc comment for the
    -- full three-call (leash/hold/partnership) writeup.
    EndK9AccessForCitizenId(citizenid, 'certification_revoked', source)

    -- CERTIFICATION DEPTH (this pass, Part B §11): same cascade as both
    -- manual revoke paths above.
    RevokeAllSpecializationsForCitizenJob(citizenid, oldJob, 'system:job_change', 'certification_revoked')
end)

lib.callback.register('qbx_k9unit:server:hasK9Access', function(source)
    return HasK9Access(source)
end)

-- ======================================================================
-- TABLET CALLBACK -- see GrantCertificationForTablet's own doc comment
-- above for the full "offline-grant asymmetry" writeup. Gated on
-- Config.Features.CommandTablet AT REGISTRATION TIME, mirroring
-- server/permissions.lua's identical "TABLET CALLBACKS" gate (that file's
-- own header: "gate at registration, not just inside the handler")
-- -- independent of whether this file's own underlying feature checks
-- (Config.AllowSelfCertification, IsEligibleCertifier's own rank/grant/
-- high-command resolution) would themselves allow anything; registering
-- this callback regardless of THOSE lets the tablet render a real,
-- specific denial reason instead of the callback not existing at all.
-- `source` is ox_lib's own callback dispatch value (server-verified, never
-- a client-supplied one) and is passed straight through as `granterSrc` --
-- GrantCertificationForTablet/GrantCertification already independently
-- re-verify eligibility from that source's own live job, so this wrapper
-- adds no authorization logic of its own, only the return-shape
-- translation client/tablet.lua's AwaitServerCallback expects.
-- ======================================================================
if Config.Features and Config.Features.CommandTablet == true then
    lib.callback.register('qbx_k9unit:server:tabletCertify', function(source, targetCitizenid, departmentKey)
        local ok, outcome = GrantCertificationForTablet(source, targetCitizenid, departmentKey)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)
end

RegisterNetEvent('qbx_k9unit:server:certifyHandler', function(targetServerId)
    GrantCertification(source, targetServerId)
end)

-- CERTIFICATION DEPTH (this pass, Part A §2): `reason` is a new, optional
-- second argument — an existing client that only ever sends one argument
-- (e.g. client/movement.lua's `TriggerServerEvent('qbx_k9unit:server:revokeHandler',
-- GetPlayerServerId(targetPlayer))`) is unaffected: `reason` is simply nil.
RegisterNetEvent('qbx_k9unit:server:revokeHandler', function(targetServerId, reason)
    RevokeCertification(source, targetServerId, reason)
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
    -- CERTIFICATION DEPTH (this pass, Part A §2): args[2], an optional
    -- reason code — nil if omitted, exactly like before this pass.
    RevokeCertification(source, targetServerId, args[2])
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
    -- CERTIFICATION DEPTH (this pass, Part A §2): args[3], an optional
    -- reason code — nil if omitted, exactly like before this pass.
    RevokeCertificationOffline(source, citizenid, job, args[3])
end, false)

-- ======================================================================
-- CERTIFICATION DEPTH (this pass) — net events + commands for tier/
-- renewal/specialization, mirroring the exact "command and event both
-- call the same internal function" convention every action above already
-- uses.
-- ======================================================================

RegisterNetEvent('qbx_k9unit:server:setCertificationTier', function(targetServerId, newTier)
    SetCertificationTier(source, targetServerId, newTier)
end)

RegisterCommand('k9settier', function(source, args)
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, locale('certifications.usage_settier'), 'error')
        return
    end
    SetCertificationTier(source, targetServerId, args[2])
end, false)

RegisterNetEvent('qbx_k9unit:server:renewCertification', function(targetServerId)
    RenewCertification(source, targetServerId)
end)

RegisterCommand('k9recertify', function(source, args)
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, locale('certifications.usage_recertify'), 'error')
        return
    end
    RenewCertification(source, targetServerId)
end, false)

RegisterNetEvent('qbx_k9unit:server:grantSpecialization', function(targetServerId, specializationKey)
    GrantSpecialization(source, targetServerId, specializationKey)
end)

RegisterCommand('k9specialize', function(source, args)
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, locale('certifications.usage_specialize'), 'error')
        return
    end
    GrantSpecialization(source, targetServerId, args[2])
end, false)

RegisterNetEvent('qbx_k9unit:server:revokeSpecialization', function(targetServerId, specializationKey)
    RevokeSpecialization(source, targetServerId, specializationKey)
end)

RegisterCommand('k9unspecialize', function(source, args)
    local targetServerId = tonumber(args[1])
    if not targetServerId then
        NotifyPlayer(source, locale('certifications.usage_unspecialize'), 'error')
        return
    end
    RevokeSpecialization(source, targetServerId, args[2])
end, false)

-- Offline-capable counterpart to /k9unspecialize — see
-- RevokeSpecializationOffline above and RevokeCertificationOffline's own
-- header note (item 7b) for why this exists as a separate, citizenid-keyed
-- command rather than extending the numeric targetServerId contract.
RegisterCommand('k9unspecializeoffline', function(source, args)
    local citizenid = args[1]
    local job = args[2]
    local specializationKey = args[3]
    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == ''
        or type(specializationKey) ~= 'string' or specializationKey == '' then
        NotifyPlayer(source, locale('certifications.usage_unspecialize_offline'), 'error')
        return
    end
    RevokeSpecializationOffline(source, citizenid, job, specializationKey)
end, false)

--- CERTIFICATION DEPTH (this pass, Part A §9) — see header "EXPIRY" item
--- 2 for the full design. Sends AT MOST one warn-ahead notice and one
--- just-lapsed notice per (citizenid) per session — never re-sent on
--- every call, so this is safe to call both from PlayerLoaded (once, at
--- login) and from the periodic sweep (repeatedly, for every currently
--- online certified handler) without spamming either one.
--- @param onlineSrc number -- a LIVE, currently-connected server id (never a client claim — resolved by the caller from qbx_core, exactly like every other NotifyPlayer target in this file)
--- @param citizenid string
--- @param cached table -- a Certifications[citizenid] entry (active, job, tier, expiresAtUnix, expired)
local function CheckAndNotifyExpiry(onlineSrc, citizenid, cached)
    if not cached.expiresAtUnix then return end -- no expiry set -- nothing to warn about, ever

    if cached.expired then
        if not ExpiryLapsedNotified[citizenid] then
            ExpiryLapsedNotified[citizenid] = true
            NotifyPlayer(onlineSrc, locale('certifications.expiry_lapsed_notice'), 'error')
        end
        return
    end

    local now = NowUnix()
    if now == nil then return end -- see NowUnix's own doc comment -- fail toward silence, not toward a wrong day-count

    -- CLAMP-AND-WARN on a misconfigured CertificationExpiryWarningDays —
    -- see ResolveConfiguredExpiryWarningDays' own doc comment.
    local warningDays = ResolveConfiguredExpiryWarningDays()
    local secondsRemaining = cached.expiresAtUnix - now
    if secondsRemaining <= (warningDays * 86400) and not ExpiryWarned[citizenid] then
        ExpiryWarned[citizenid] = true
        local daysRemaining = math.max(1, math.ceil(secondsRemaining / 86400))
        NotifyPlayer(onlineSrc, locale('certifications.expiry_warning', tostring(daysRemaining)), 'inform')
    end
end

-- CONFIDENCE NOTE (not silently asserted as verified fact): no qbx_core
-- install was reachable in this sandbox to inspect its actual
-- exports/events against (the filesystem was searched; only this
-- resource's own files exist here). DEVELOPER_REFERENCE.md §4.4 already confirms
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
    -- (DEVELOPER_REFERENCE.md §4.3 — never read for authorization) from whatever value
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

    -- CERTIFICATION DEPTH (this pass, Part A §9): a handler logging in
    -- already near or past their own expiry gets the same proactive
    -- notice an already-online handler would get from the periodic
    -- sweep — no need to wait for the next sweep pass just because they
    -- happened to log in between two of them. Gated the same way the
    -- sweep itself is (Player.PlayerData.source is always this login's
    -- own live source, never a client claim).
    if Config.Features and Config.Features.CertificationExpiry == true and cached.active then
        CheckAndNotifyExpiry(Player.PlayerData.source, citizenid, cached)
    end
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

        -- CERTIFICATION DEPTH (this pass): same unbounded-growth reasoning
        -- as Certifications above, applied to the three new per-citizenid
        -- tables this pass adds. All three are harmlessly rebuilt/re-armed
        -- on the citizenid's next PlayerLoaded/RefreshCertificationCache
        -- touch, exactly like Certifications itself.
        Specializations[citizenid] = nil
        ExpiryWarned[citizenid] = nil
        ExpiryLapsedNotified[citizenid] = nil
    end

    -- DEVELOPER_REFERENCE.md item 1: CertifyActionCooldown already registered
    -- its OWN `playerDropped` handler via :RegisterPlayerDropped() above
    -- (same unbounded-growth reasoning as Certifications above — keyed by
    -- server id (src) rather than citizenid since CERTIFY_ACTION_COOLDOWN_MS
    -- throttles the CERTIFIER's connection, not any particular citizenid),
    -- so nothing needs to happen here for it anymore.
end)

-- ======================================================================
-- CERTIFICATION DEPTH (this pass, Part A §9) — background expiry sweep.
-- See header "EXPIRY" item 2 for the full design. Mirrors
-- server/tenure.lua's own CreateThread/Wait tick-loop shape exactly,
-- including its config-driven-interval + fallback-on-misconfiguration
-- convention (a non-positive/NaN/non-number interval fed straight to
-- Wait() can busy-loop or silently kill this thread forever — same
-- footgun that file's own PollIntervalMs-adjacent comment documents).
--
-- GATED AT THE CreateThread REGISTRATION ITSELF, not just inside the loop
-- body: on a server that has never turned Config.Features.CertificationExpiry
-- on, this thread is never even created — a total, zero-cost no-op,
-- matching this task's own "a server with none of this configured must
-- see a clean no-op" requirement literally, not just "does nothing when
-- it runs."
-- ======================================================================

--- One sweep pass: for every currently-connected player, if their cached
--- certification carries an expiry, warn ahead of it or announce a lapse
--- (at most once per session each — see CheckAndNotifyExpiry). Walks
--- `GetPlayers()`/cache reads only — NEVER a live SQL query — matching
--- this file's header "EXPIRY" item 2 ("never a live per-access SQL
--- query").
local function TickCertificationExpiryWarnings()
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
            local cached = citizenid and Certifications[citizenid]
            if cached and cached.active then
                CheckAndNotifyExpiry(src, citizenid, cached)
            end
        end
    end
end

local WarnedBadExpiryCheckIntervalMs = false
local EXPIRY_CHECK_INTERVAL_FALLBACK_MS = 300000

if Config.Features and Config.Features.CertificationExpiry == true then
    CreateThread(function()
        while true do
            local rawIntervalMs = Config.CertificationExpiryCheckIntervalMs
            local intervalMs = EXPIRY_CHECK_INTERVAL_FALLBACK_MS
            if type(rawIntervalMs) == 'number' and rawIntervalMs == rawIntervalMs and rawIntervalMs > 0 then
                intervalMs = rawIntervalMs
            elseif rawIntervalMs ~= nil and not WarnedBadExpiryCheckIntervalMs then
                WarnedBadExpiryCheckIntervalMs = true
                print(('[qbx_k9unit] certifications: Config.CertificationExpiryCheckIntervalMs (%s) is not a positive number -- using the built-in %dms interval instead.'):format(tostring(rawIntervalMs), EXPIRY_CHECK_INTERVAL_FALLBACK_MS))
            end
            Wait(intervalMs)
            local ok, err = pcall(TickCertificationExpiryWarnings)
            if not ok then
                print(('[qbx_k9unit] certification expiry sweep tick error: %s'):format(tostring(err)))
            end
        end
    end)
end
