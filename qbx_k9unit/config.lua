--[[
    qbx_k9unit/config.lua

    Transcribed verbatim from SPEC.md §5 ("Config schema (concrete shape)"),
    which is unchanged by the post-draft correction (§1/§2/§4.4/§4.5) — no
    additions or removals beyond what's noted inline below. If SPEC.md §5
    is revised again, re-diff this file against it before trusting it as
    still in sync.

    HISTORY: an earlier draft of this file added a Config.K9DespawnGraceSeconds
    field for a handler->K9 spawn-registry grace timer. That concept was
    removed entirely once SPEC.md's post-draft correction established the
    K9 is a player's own persistent character with no spawn/despawn/registry
    at all (see the NOTE further down where that field used to live).
]]

Config = {}

-- ======================================================================
-- FEATURE TOGGLES — every leaf feature independently switchable.
-- The code must gate on these at the point of activation, not just declare
-- them (see §3 acceptance criteria).
-- ======================================================================
Config.Features = {
    -- Phase 1 (vertical slice)
    LeashMechanics       = true,
    RadialMenu           = true,
    VehicleEntryExit     = true,
    BasicBarkSounds      = true,
    AgilityBasicJump     = true,  -- native jump/crouch only, no fence-vault logic yet

    -- Phase 2 (tracking & vision)
    ScentTracking        = true,
    BloodTracking        = true,
    WaterTrackingDecay   = true,
    GunpowderSniffing    = true,
    SearchZones          = true,
    ContrabandAlerts     = true,
    ThermalVision        = true,
    NightVision          = true,
    DoorInteraction      = true, -- nudge-open / scratch-to-alert

    -- Phase 3 (combat & action)
    BiteAndHold          = true,
    NonLethalTakedown    = true,
    HandlerDownDefense   = true,
    PropDragging         = true,
    AgilityAdvanced      = true, -- fence/window vault approximation

    -- server/recall.lua + client/recall.lua (PHASE3_SPEC.md §12.5.1's
    -- "Recall actor"). The handler's escape hatch: ends whatever active
    -- effect their partnered K9 currently holds (bite/takedown/drag alike --
    -- deliberately generalised beyond §12.5.1's bite-only text, since
    -- narrowing it would leave a handler unable to call off a mid-drag K9,
    -- a strictly worse unbounded-trap posture). The TERMINATION path is
    -- never gated on HasK9Access/CanShowK9UI on either party, by design --
    -- a decertified handler must still be able to call their dog off.
    Recall               = true,

    -- PHASE3_SPEC.md §12.0 item 7 (Revision 5, coder-architect) /
    -- server/partnership.lua (coder-backend, this pass). Gates the
    -- mutually-consented "Partner Up" registry ONLY -- HandlerDownDefense
    -- and BiteAndHold's Recall actor (the two features this registry
    -- unblocks) are each STILL independently gated by their OWN flags
    -- above and remain unimplemented as of this pass regardless of this
    -- flag's value; flipping this on by itself does not enable either.
    -- DEFAULT DIVERGES FROM PHASE3_SPEC.md §12.0 item 7 point 5's OWN
    -- "recommended default true" text -- deliberate, not an oversight: that
    -- recommendation predates any real code existing, and this resource's
    -- actual shipped convention for every other Phase 3 mechanic (see the
    -- Config.Combat header comment above: BiteAndHold/NonLethalTakedown
    -- ship fully implemented but still `false`) is that a newly-landed
    -- Phase 3+ mechanic stays off by default until its own balance/security
    -- go-live review, independent of implementation completeness. This flag
    -- was directed to default `false` for exactly that reason -- flip only
    -- after reviewing server/partnership.lua's own header for what is and
    -- isn't independently verified.
    HandlerPartnership   = true,

    -- server/tenure.lua (FEATURE_IDEAS.md Part B §7). Grants a one-time,
    -- flat XP bonus to the K9-role party when a partnership's CONTINUOUS
    -- tenure crosses a configured threshold -- the first gameplay
    -- consequence wired to the HandlerPartnership registry, which landed as
    -- a foundation with none. Has NO effect unless HandlerPartnership AND
    -- XPProgression are ALSO true (server/tenure.lua re-checks both at point
    -- of use). REQUIRES the k9_partnerships.tenure_bonus_tier_granted
    -- column -- present in sql/install.sql for fresh installs, and in
    -- sql/migrations/0003_*.sql for existing databases. Without that column
    -- the milestone bonus would re-grant on every restart; tenure.lua's
    -- queries are pcall-wrapped and degrade to a silent no-op until it
    -- exists, so an un-migrated database is inert rather than exploitable.
    PartnershipTenureBonus = true,

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory          = true,
    XPProgression        = true,
    HealthStaminaHUD     = true,
    FatigueSystem        = true,
    MoodSystem           = true,
    FearStressSystem     = true,
    DistractionSystem    = true,
    InjuryLimping        = true,
    K9Medkit             = true,
    ContrabandScreenFX   = true,

    -- server/admin.lua. A read-only, JOB-RANK-gated in-game audit surface
    -- over the three tables this resource already writes (k9_certifications,
    -- k9_partnerships, k9_search_log) -- five commands, nine hardcoded SQL
    -- templates, zero mutation paths of any kind. Replaces "documented raw
    -- SQL an admin runs by hand" (FEATURE_IDEAS.md Part B item 2). This one
    -- exposes WHO SEARCHED WHOM, so it is a privacy boundary as well as a
    -- security one: set `auditGrade` on each Config.Departments entry below
    -- deliberately. There is no ACE permission to grant -- that gate was
    -- removed on 2026-08-25.
    AdminAuditCommands   = true,

    -- server/highcommand.lua. A senior-rank tier, defined per department by
    -- `highCommandGrade` in Config.Departments, that is exempt from EVERY
    -- other rank check in this resource and can mint XP directly via
    -- /k9givexp. See the Config.HighCommand block below for what it
    -- deliberately does NOT do (run arbitrary server commands) and why.
    -- This is the most powerful switch in this file: it is the only one
    -- that grants an in-game job rank write access to the XP economy.
    HighCommand          = true,

    -- server/permissions.lua. Lets high command grant a NAMED capability
    -- to one specific handler or K9, instead of everything being gated on
    -- job rank alone. Purely additive: grants widen access, never narrow
    -- it, so nothing that works on rank today stops working. See the
    -- Config.Permissions block below for the capability list and the
    -- exact resolution order.
    PermissionGrants     = true,

    -- client/tablet.lua + html/tablet.*. The in-game roster and control
    -- UI for certifications, XP and permission grants. It is a VIEW only
    -- -- every action is re-authorized server-side, so the tablet showing
    -- a button never makes an action allowed.
    CommandTablet        = true,

    -- server/bonetool.lua + client/bonetool.lua. A DEV-SERVER-ONLY sweep that
    -- attaches a marker prop to bone indices in sequence so a human can
    -- visually identify the right one for a quadruped skeleton -- the
    -- question that blocked PropAttachments and FetchMechanic through three
    -- research passes. This flag ALONE does not make the tool reachable: as
    -- of 2026-08-25 it also requires a replicated convar an operator must
    -- set on purpose (`setr qbx_k9unit_enable_bone_dev_tool 1`), and the
    -- caller must be a boss of a configured Config.Departments job. That
    -- second opt-in exists precisely because this flag was once flipped true
    -- alongside 39 others with nothing to distinguish it.
    -- Its real blast radius is narrow -- every effect is local to the
    -- caller's own client (a debug marker, and one non-networked prop on
    -- their own ped), and the server never accepts an entity or netId from
    -- the client -- but it is still a dev tool. Leave the convar unset on a
    -- production server.
    BoneSweepDevTool     = true,
    -- OPERATIONAL CAVEAT, and it matters most for THIS flag specifically.
    -- Nothing in this resource flips a Config.Features.* flag while running:
    -- every feature gates its RegisterCommand/RegisterNetEvent calls ONCE, at
    -- file-load or onResourceStart time. That is deliberate ("gate at
    -- registration, not inside the handler") and it is what makes a disabled
    -- feature genuinely inert rather than merely hidden.
    -- The consequence: turning this flag ON, restarting, then turning it back
    -- OFF does NOT unregister /k9bonetool. It stays reachable until the NEXT
    -- restart. For most features that is harmless. For this one it is not --
    -- it spawns and attaches props on command. RESTART AFTER DISABLING IT.
    -- (The ACE check still applies in that window; this is about not leaving
    -- a dev tool registered on a production server at all.)

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial   = true,
    ProximityAudioFX     = true,
    PropAttachments      = true,
    FetchMechanic        = true,
    DeployableKennel     = true,
    -- NOT EXPERIMENTAL -- IMPOSSIBLE, and re-confirmed 2026-08-25 rather than
    -- carried forward on an old note. This is the only flag in this table with
    -- no implementing code, and it should stay that way until the specific
    -- things below change.
    --   * citizenfx/fivem#3835 is OPEN, labelled documentation+triage, no PR,
    --     no maintainer response. It ASKS for a camera-to-texture API; it does
    --     not report an undocumented one.
    --   * No native exists. CreateRuntimeTextureFromDuiHandle goes the OPPOSITE
    --     direction (an HTML page onto a world texture). The entire CAM
    --     namespace is camera STATE -- position, FOV, shake, interpolation --
    --     with nothing touching a render target or pixel buffer. Candidate
    --     render-target names 404. No open natives PR mentions camera or
    --     texture work.
    --   * Nobody in the ecosystem has solved it either. Published bodycam
    --     resources are either cosmetic overlays on the player's OWN view, or
    --     a full camera switch with a decoy ped -- never two feeds at once.
    -- CONCRETE RE-CHECK, so the next pass diffs rather than re-researches:
    -- has #3835 closed, or has a file matching ext/native-decls/*RenderTarget*
    -- appeared? If neither, nothing has changed.
    -- DELIBERATELY FALSE, and the only flag in this table that is.
    -- The 2026-08-25 pass enabled every other feature at the owner's
    -- request; this one is excluded because there is NO IMPLEMENTING CODE
    -- ANYWHERE IN THIS RESOURCE for it -- grep the tree, it is referenced
    -- only here. It is not an unfinished feature, it is a placeholder for
    -- one the engine cannot currently support (see the research notes
    -- above). Setting it true would not switch anything on; it would only
    -- tell an operator reading this file that a picture-in-picture camera
    -- feed exists, which it does not. Flip it to true only in the same
    -- change that adds the code, never before.
    CameraFeedPiP        = false,
}

-- ======================================================================
-- PED ROSTER — extensible, no code changes needed to add a streamed model.
-- ======================================================================
Config.Peds = {
    { model = 'a_c_shepherd' },
    { model = 'a_c_rottweiler' },
    { model = 'a_c_husky' },
    { model = 'a_c_chop' },
    -- Example custom streamed model (requires the model to exist in a
    -- streamed resource elsewhere on the server; adding this line is the
    -- *only* change needed to make it selectable):
    -- { model = 'a_c_k9_malinois' },
}

-- ======================================================================
-- DEPARTMENTS — admin-editable list of job names with K9 access, plus the
-- rank threshold required to grant/revoke certifications for that job.
-- ======================================================================
Config.Departments = {
    ['police'] = {
        label           = 'Los Santos Police Department',
        certifierGrade  = 4,    -- job.grade.level required to grant/revoke certs (job.isboss always qualifies too)
        -- job.grade.level required to run the read-only /k9audit* commands.
        -- These were ACE-gated until 2026-08-25 and are now gated on police
        -- rank instead, at the project owner's request: auditing K9
        -- certifications is a senior-officer function, not a server-admin
        -- one. Set at or above certifierGrade -- someone trusted to grant a
        -- certification should be able to see who holds one. job.isboss
        -- always qualifies, same as certifierGrade.
        auditGrade      = 4,
        -- HIGH COMMAND. A caller at or above this grade -- job.isboss also
        -- always qualifies -- BYPASSES EVERY OTHER RANK GATE IN THIS
        -- RESOURCE: certifierGrade, auditGrade, the bone dev tool's
        -- boss-only check, and the K9 certification requirement itself. It
        -- is the single "senior command can do anything this resource
        -- offers" switch, and it is what unlocks /k9givexp.
        --
        -- SET THIS DELIBERATELY, AND HIGHER THAN auditGrade. Unlike every
        -- other threshold here it grants WRITE power over the economy: a
        -- high command officer can mint XP out of nothing. Every use is
        -- logged to the server console with who granted what to whom.
        --
        -- nil disables the tier entirely for this department. nil means
        -- "no such rank exists here", NEVER "everybody qualifies" -- the
        -- check fails closed on a nil, a non-number, or a malformed grade.
        highCommandGrade = 6,
        -- job.grade.level required to RECEIVE non-compliance alerts (a K9's
        -- target resisting or fleeing). Deliberately a separate, much lower
        -- bar than auditGrade: an audit pull exposes who searched whom and
        -- is a privacy boundary, whereas this alert carries no
        -- citizen-identifying data at all -- just a source id and a speed or
        -- displacement number. It is closer to a dispatch broadcast than to
        -- a records lookup, so it defaults to 0, meaning every sworn member
        -- of a configured department sees them. job.isboss always qualifies.
        -- nil disables the alerts entirely for this department; it never
        -- means "everybody".
        nonComplianceAlertGrade = 0,
        autoAccessGrade = nil,  -- nil = no auto-bypass; set an integer to let that grade+ skip certification (see §4.1 assumption)
    },
    ['sheriff'] = {
        label           = 'Blaine County Sheriff',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 5, -- see police.highCommandGrade above for what this unlocks
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },
    ['bcso'] = {
        label           = 'Blaine County Sheriff (legacy job name)',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 5, -- see police.highCommandGrade above for what this unlocks
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },
}

-- ======================================================================
-- HIGH COMMAND (Config.Features.HighCommand) -- server/highcommand.lua.
--
-- What it is: a single senior-rank tier, defined per department by
-- `highCommandGrade` above, that is exempt from every other rank check in
-- this resource and can additionally mint XP directly.
--
-- WHAT IT DELIBERATELY IS **NOT**: a way to run arbitrary server commands.
-- "High command can run any command" was requested, and within this
-- resource that is exactly what this delivers -- every qbx_k9unit command
-- and every gated action becomes available. It stops at this resource's
-- boundary on purpose. A generic passthrough that let an in-game job rank
-- execute arbitrary server commands would turn a promotion into full
-- server control across EVERY resource installed, including ACE and
-- permission management -- so one social-engineered promotion, or one
-- compromised officer account, would own the server with no way to walk
-- it back. That is a server-admin capability (txAdmin, ACE) and it should
-- stay one. If you want it anyway it is your server and your call -- say
-- so and it can be added, but it should be a deliberate decision rather
-- than a side effect of a rank number.
-- ======================================================================
Config.HighCommand = {
    -- Max XP a single /k9givexp invocation may grant. This is a typo
    -- guard, not a trust boundary -- high command is already trusted, but
    -- an accidental extra zero should not silently mint a fortune. Raise
    -- it if your progression curve is larger; a non-positive or
    -- non-number value here disables the command rather than meaning
    -- "unlimited", matching this resource's fail-closed convention.
    maxXpPerGrant = 5000,

    -- Anti-fat-finger cooldown between grants from the same officer, in ms.
    -- Deliberately short: this is not a rate limit against abuse (high
    -- command is trusted by definition), it is protection against a held
    -- key or a double-submitted chat line.
    grantCooldownMs = 1500,

    -- Whether high command may grant XP to THEMSELVES. Defaults false --
    -- not because it is exploitable (they could trivially ask a peer), but
    -- because a self-grant is the one case with no second person in the
    -- audit trail, and keeping it off makes the log meaningful.
    allowSelfGrant = false,
}

-- ======================================================================
-- GRANTABLE PERMISSIONS (Config.Features.PermissionGrants) --
-- server/permissions.lua.
--
-- The problem this solves: until now every capability in this resource
-- was gated on JOB RANK alone. That works for "all sergeants may certify"
-- but not for "this one officer may certify, and nobody else at their
-- rank may". High command can now grant a named permission to a specific
-- person -- a handler OR a K9, since both are just citizenids -- and
-- revoke it later, with the whole history recorded.
--
-- HOW A CAPABILITY CHECK RESOLVES, in order. First match wins:
--   1. an active, explicitly granted permission for that citizenid  -> ALLOW
--   2. the caller is high command (Config.Departments highCommandGrade) -> ALLOW
--   3. the caller meets the legacy rank gate (certifierGrade etc.)   -> ALLOW
--   4. otherwise                                                     -> DENY
-- This is purely ADDITIVE. Nothing that works on rank today stops
-- working; grants only ever widen access, never narrow it. If you want
-- to take a capability away from someone who qualifies by RANK, change
-- their rank -- revoking a grant they never had does nothing, and the
-- UI says so rather than pretending it worked.
--
-- Keys are the capability names. Do not rename one after granting it:
-- the grant rows store this string, so a rename silently orphans every
-- existing grant. Add a new key and migrate instead.
-- ======================================================================
Config.Permissions = {
    -- The label is what a non-technical officer sees in the tablet, so
    -- write it as a sentence about what the person can DO.
    ['k9.access']  = { label = 'Use K9 abilities',              description = 'Equivalent to holding a K9 certification. Grant this to let someone work as a K9 without going through a certifying officer.' },
    ['k9.certify'] = { label = 'Certify and decertify others',  description = 'Grant and revoke K9 certifications. Normally requires a senior rank; this hands it to one specific person.' },
    ['k9.audit']   = { label = 'View the audit records',        description = 'Run the read-only audit commands. PRIVACY-SENSITIVE: this reveals who searched whom, and when.' },
    ['k9.givexp']  = { label = 'Grant XP',                      description = 'Award XP directly to a K9 or handler. This mints economy value -- every use is logged.' },
}

-- ======================================================================
-- K9 COMMAND TABLET (Config.Features.CommandTablet) --
-- client/tablet.lua + html/tablet.*. The in-game UI for everything
-- above: a roster of handlers and K9s with their certifications, XP and
-- granted permissions, and the controls to grant or revoke.
--
-- SECURITY NOTE, because a UI makes this easy to get wrong: the tablet
-- is a VIEW. It decides nothing. Every action it offers is re-authorized
-- server-side from the caller's own live job and grants, exactly as if
-- they had typed the command -- a modified client can send any NUI
-- callback it likes, so the tablet showing a button must never be what
-- makes the action allowed. It only hides what you cannot do, as a
-- convenience.
-- ======================================================================
Config.CommandTablet = {
    -- Command that opens it. Also reachable from the K9 radial menu.
    command = 'k9tablet',

    -- Optional ox_inventory item that must be carried to open it. nil
    -- disables the requirement entirely. If you set this, the item must
    -- exist in YOUR ox_inventory items table -- this resource cannot
    -- create it, and an unregistered name resolves to a count of zero
    -- forever, which reads to a player as the tablet being broken. A
    -- startup warning fires if it cannot be resolved.
    requiredItem = nil,

    -- Max roster rows returned in one query. Clamped server-side; a
    -- non-positive or non-number value falls back to the default rather
    -- than meaning "unlimited".
    maxRosterRows = 100,
}

Config.AllowSelfCertification = true   -- see §4.1
Config.CertifyProximityMeters = 5.0    -- server-enforced max distance for grant/revoke (§4.2.4)

-- ======================================================================
-- VEHICLES — which vehicle models expose the "Load K9" / "Release K9"
-- ox_target option on their trunk/rear door.
-- ======================================================================
Config.K9Vehicles = {
    'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2',
}
Config.VehicleInteractMeters = 3.0

-- ======================================================================
-- LEASH — Phase 1
-- ======================================================================
-- Base/reference leash range in meters (§6.1 — two-player leash, not a
-- recall; see server/main.lua and client/movement.lua headers for the
-- corrected model). NOT itself the auto-detach threshold — that's a
-- common misreading of this field's old comment. Three different
-- call sites derive or reuse this single value for three distinct
-- purposes, each documented in full where it's used:
--   - client/movement.lua derives the elastic pull-back START (75% of
--     this value, LEASH_PULL_ZONE_FACTOR) and the actual hard-cap
--     safety-valve auto-detach (150% of this value, LEASH_HARD_CAP_FACTOR)
--     from it — for the default below, real auto-detach fires around 12m,
--     not 8m.
--   - server/main.lua's CheckLeashEligibility reuses this raw value
--     directly as the max range to even INITIATE a leash request (a
--     separate "too far to request" check, distinct from auto-detach).
--   - client/radial.lua's FindNearestLeashCandidate reuses this raw value
--     directly as its nearby-partner search radius.
-- Reusing the raw value (rather than dedicated constants) for the latter
-- two is a deliberate Phase 1 default, not an oversight — see server/
-- main.lua's header for the open question on whether a separate,
-- smaller "attach range" constant would be worth adding later.
Config.LeashMaxDistance = 8.0

-- ======================================================================
-- NOTE (coder-architect, Phase 1 rewrite): Config.K9DespawnGraceSeconds
-- was added in the first scaffolding pass for a handler->K9 netId
-- registry that no longer exists — SPEC.md's post-draft correction
-- established the K9 is a player's own persistent character (§1, §4.5),
-- with no spawn/despawn/registry concept at all. Removed; do not re-add
-- without a new documented reason, since nothing currently consumes it.
-- ======================================================================

-- ======================================================================
-- XP TIERS — Phase 4, placeholder numbers pending economy-balance-agent review
-- ======================================================================
Config.XPTiers = {
    -- scentRangeMultiplier REPLACED the old absolute `scentRange` field, and
    -- the unit changed, which is why the name had to change with it. The old
    -- values (5.0/6.5/8.0/10.0) were applied as a math.max FLOOR against each
    -- track type's own maxRange -- and every maxRange defaults to 40.0. Even
    -- the Elite tier's 10.0 could never exceed 40.0, so the floor could never
    -- raise anything, for any tier. "Scent range grows with XP" was numerically
    -- dead from the day it shipped.
    -- Now a multiplier over each track type's own maxRange, so it scales with
    -- whatever that type is tuned to instead of fighting an absolute ceiling.
    -- Base tier is 1.00 = no bonus, so a base-tier K9's range is byte-identical
    -- to today's behaviour. Only a value > 1.0 does anything.
    -- Pure balance placeholders -- tune freely.
    -- RETUNED 2026-08-25 from 500/1500/3500, on measured extraction rates
    -- rather than feel. The old top tier was reachable in about 49 minutes
    -- of nonstop optimal play once the combat awards ship, and in roughly
    -- 2.3 hours using only what is closest to shippable today -- an
    -- evening, not the weeks of K9 duty the progression is meant to
    -- represent.
    --
    -- New thresholds keep the old proportions (14% / 44% / 100% of top).
    -- At a realistic legitimate rate of ~500 XP/hr, Elite takes about 18
    -- hours total, or roughly 2 to 2.5 weeks at an hour or so a day. At the
    -- worst-case farmable ceiling of 4320 XP/hr -- both combat awards
    -- enabled, two NPC targets, perfect cooldown cycling, no real police
    -- work -- Elite still costs over 2 hours of deliberate grinding rather
    -- than happening by accident.
    --
    -- Deliberately NOT the order-of-magnitude raise floated earlier. That
    -- figure was anchored to the ~9000 XP/hr contraband farm, which is now
    -- closed; reapplying it against the corrected ceiling would overshoot.
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
    { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
    { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
    { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20 },
}

-- ======================================================================
-- PHASE 4 — XP PROGRESSION (Config.Features.XPProgression, server/progression.lua).
-- Per-action award VALUES that accumulate toward Config.XPTiers' thresholds
-- above (that table was drafted early and sat unused until this pass).
-- PHASE4_SPEC.md §13.4.1 — the exact award-action list (searchContrabandFound/
-- trackSourceResolved/biteHoldSuccess/takedownSuccess) is taken verbatim from
-- that section, not invented here. Every value below is an unreviewed
-- placeholder pending economy-balance-agent/config-validator review
-- (SPEC.md §9 item 4), same status Config.XPTiers itself already carries.
-- ======================================================================
Config.XP = {
    awards = {
        -- server/search.lua's HandleSearchTarget, at the point
        -- `contrabandFound == true` is already known (existing Phase 2
        -- success path — this is a new CONSUMER of that outcome, no change
        -- to search.lua's own validation order/cooldowns).
        searchContrabandFound = 25,
        -- server/tracking.lua's findTrackableSource resolving `found = true`
        -- is NOT, by itself, the award trigger — see trackArrivalRadius/
        -- trackArrivalTTLMs below. PHASE4_SPEC.md §13.4.1 open question 3
        -- explicitly flags that awarding on `found = true` alone lets a K9
        -- farm XP by repeatedly triggering a search without ever completing
        -- it; this implementation closes that by requiring the K9's own
        -- client to subsequently arrive within trackArrivalRadius of the
        -- SERVER's resolved coordinate before this amount is granted.
        trackSourceResolved   = 10,
        -- server/combat.lua's requestBiteHold success (PHASE3_SPEC.md
        -- §12.5.1). WIRED. The note that stood here -- "NOT YET WIRED:
        -- server/combat.lua does not exist in this codebase" -- predated
        -- Phase 3 combat landing and had gone stale; that file exists and
        -- calls AwardXP(citizenid, 'biteHoldSuccess') from its success
        -- path. See server/progression.lua's header for the call contract.
        biteHoldSuccess       = 20,
        -- server/combat.lua's requestTakedown success (PHASE3_SPEC.md
        -- §12.5.2) -- same stale-note correction as biteHoldSuccess above;
        -- this one is wired too.
        takedownSuccess       = 30,

        -- server/tenure.lua's partnership-tenure milestones. Each is a
        -- ONE-TIME award per partnership row -- never repeating, never
        -- per-tick. That distinction is the whole safety argument: this is
        -- the only award in this table driven by a WALL CLOCK rather than a
        -- player action, so a recurring trickle would be a pure idle-XP
        -- farm. The hard cap (15+40+100 = 155 XP ever, per partnership) is
        -- what makes awarding from a non-activity-gated clock safe at all.
        -- UNTUNED PLACEHOLDERS, same review status as every other value
        -- here. For scale: the top XP tier is reached at 3500.
        partnershipTenure1Day  = 15,  -- 24 real-world hours of continuous active partnership
        partnershipTenure7Day  = 40,  -- 7 days
        partnershipTenure30Day = 100, -- 30 days
    },

    -- 'citizenid' (default, per PHASE4_SPEC.md §13.2's own default and
    -- phase2_notes/phase4_xp_schema_notes.md §4's schema sketch, which
    -- assumes this): XP belongs to the K9 character itself and is portable
    -- across a department change (k9_progression is keyed by citizenid
    -- alone, no job column). 'job' would need a composite (citizenid, job)
    -- primary key instead, mirroring k9_certifications — NOT implemented by
    -- this pass; PHASE4_SPEC.md §13.6 item 2 flags this as a genuinely open
    -- product call still needing explicit sign-off. Left at the documented
    -- default rather than silently guessed differently.
    scopePerCitizenidOrJob = 'citizenid',

    -- EXTENSION beyond PHASE4_SPEC.md §13.2's own sketch (that section only
    -- specified `awards`/`scopePerCitizenidOrJob`) — added to actually
    -- resolve open question 3 above rather than leave the farm exploit it
    -- flags unresolved. The `findTrackableSource` reveal itself stays
    -- purely client-cosmetic (no XP consequence at that point, per §11.6);
    -- `trackSourceResolved` XP is only granted once the K9's own client
    -- reports arrival within this radius of the coordinate the SERVER
    -- resolved — server/tracking.lua re-measures live distance itself
    -- against its own server-held pending-arrival state, never a
    -- client-supplied coordinate or distance claim.
    trackArrivalRadius = 3.0,    -- meters
    trackArrivalTTLMs  = 60000,  -- how long a resolved-but-unreached source stays eligible for a late arrival report before expiring — prevents a stale pending-arrival slot from awarding XP for a long-abandoned search
}

-- ======================================================================
-- CONTRABAND ALERT THRESHOLDS — Phase 2, placeholder pending
-- config-validator/economy review against actual ox_inventory item weights.
-- Order matters: server/search.lua walks this list and keeps the LAST tier
-- whose minWeight the total contraband weight meets or exceeds, so entries
-- must stay sorted ascending by minWeight. The 'clean' baseline is
-- mandatory (SPEC.md §11.4) so a zero-contraband result always resolves to
-- a real tier instead of falling through unhandled.
-- ======================================================================
Config.ContrabandAlertTiers = {
    { minWeight = 0,   alert = 'clean' },           -- nothing found / below any threshold
    { minWeight = 1,   alert = 'whine' },           -- small personal-use amount
    { minWeight = 250, alert = 'aggressive_bark' }, -- large stash
}

-- ======================================================================
-- PHASE 2 — TRACKING (scent / blood / gunpowder). Ranges in meters, ages/
-- time windows in seconds. Each trail TYPE is independently gated by its
-- own Config.Features flag (ScentTracking / BloodTracking /
-- GunpowderSniffing) — these tuning tables only take effect for whichever
-- types are enabled; read at the point of use (search command execution),
-- not cached at resource start, per §3's acceptance criteria applied here.
-- ======================================================================
Config.Tracking = {
    Scent = {
        maxRange         = 40.0,  -- max distance from the K9's current position to a valid scent source at search time
        maxAgeSeconds    = 900,   -- how long a dropped item stays trackable as a scent source (§9 item 17 close-out, 2026-08-23). Deliberately longer than Blood/Gunpowder's 300s/120s -- a physical dropped item sitting on the ground doesn't decay the way a damage/gunfire event does. Judgment call, not independently confirmed against real gameplay balance -- phase2_notes/scent_source_resolution.md §4 flags this as worth a product-manager/config-validator/economy-balance-agent pass; revisit if playtesting says otherwise.
        markerSpacing    = 3.0,   -- meters between rendered trail markers/checkpoints
        searchCooldownMs = 5000,  -- per-player cooldown on re-issuing a "search" command of this type
        relayCooldownMs  = 1000,  -- per-dropping-player cap on how often the ox_inventory 'swapItems' hook (server/tracking.lua) logs a new scent-source entry. UNLIKE Blood/Gunpowder's field of the same name, this is NOT closing an anti-forgery gap -- the hook is server-to-server, so `payload.source` cannot be spoofed to claim a drop that didn't happen. It's defense-in-depth against a rapid drop/pickup/drop loop growing the server-side scent log unbounded between prune passes. Placeholder pending tuning.
    },
    Blood = {
        maxRange         = 40.0,
        maxAgeSeconds    = 300,   -- damage events older than this are no longer trackable (pruned from the server-side log, §11.4)
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
        relayCooldownMs  = 500,   -- per-victim cap on how often relayDamageEvent may log a new entry — distinct from searchCooldownMs (a query-side cooldown); guards the ingest side against a flood of legitimate rapid hits (multiple pellets/DoT ticks) or a modified client bypassing the client-side debounce. Placeholder pending an economy/perf tuning pass.
    },
    Gunpowder = {
        maxRange         = 40.0,
        maxAgeSeconds    = 120,   -- shorter window than blood -- residue is time-sensitive
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
        relayCooldownMs  = 300,   -- per-shooter cap on how often relayWeaponFire may log a new entry, same rationale as Blood.relayCooldownMs above. Placeholder pending tuning.
    },
}

-- Water crossing degrades/breaks a visible trail (§6.3, §11.5). Applied by
-- client/tracking.lua while rendering ANY active trail (scent, blood, or
-- gunpowder) -- not a separate trackable type of its own, which is why it
-- has no maxRange/searchCooldownMs of its own above.
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0,  -- how often the rendered path is sampled for water while drawing it. Use GetWaterHeightNoWaves (0x8EE6B53CE13A9794), NOT plain GetWaterHeight -- confirmed by two independent native-verification passes that the wave-motion jitter in plain GetWaterHeight can cause inconsistent water/no-water reads between adjacent samples on calm shorelines; NoWaves gives a frame-stable read appropriate for a fixed-step poll like this.
    breaksTrail          = true, -- true: water fully breaks the trail, handler must re-search on the far bank (§6.3's stated behavior); false: only fades marker opacity near/in water instead of a hard break -- a softer alternative flagged here as a one-line config choice, not a spec mandate either way
}

-- ======================================================================
-- PHASE 2 — SEARCH ZONES & CONTRABAND. Item names below must match real
-- ox_inventory item names on the target server -- PLACEHOLDER list, needs
-- a config-validator/economy review before this ships for real. Item
-- WEIGHT for tier computation is read live from ox_inventory's own item
-- registry at search time, never duplicated into this config, so there is
-- exactly one source of truth for item weight and it can never drift out
-- of sync with a server's real items.lua.
-- ======================================================================
Config.SearchContrabandItems = {
    'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol', -- placeholder examples only
}

Config.SearchZones = {
    vehicleSearchDistance = 2.0,   -- ox_target zone radius for "Search Vehicle"
    personSearchDistance  = 2.0,   -- ox_target zone radius for "Search Person"
    sniffAnimDurationMs   = 4000,  -- how long the sniff interaction takes before the result is revealed
    -- CORRECTED: this is a per-TARGET cooldown, SHARED ACROSS EVERY
    -- SEARCHER. It has no K9/searcher dimension at all -- see
    -- server/search.lua's TargetSearchCooldown, which keys only on the
    -- resolved plate or citizenid. The old comment here claimed
    -- "per-(K9, target)", which is what made the contraband XP farm look
    -- bounded when it was not: two officers alternating never wait, and one
    -- officer toggling a stash they control was throttled only by this.
    -- The XP award is now separately gated by a per-searcher mint cooldown
    -- in server/search.lua. Contrast Config.Wellbeing.Mood.petCooldownMs,
    -- whose "per-(interactor, target)" claim IS accurate.
    searchCooldownMs      = 10000, -- prevents repeat-search spam against the same vehicle/person to fish for a different roll or just to harass
    alertBroadcastRadius  = 15.0,  -- max distance from the searched target's own live coordinates for a bystander to receive the ContrabandAlerts sound/reaction broadcast. Deliberately NOT a global TriggerClientEvent(-1, ...) like relayBark -- unlike a bark, this payload identifies a specific vehicle/person just flagged for contraband, so broadcasting it map-wide would leak that fact to an accomplice anywhere on the server. server/search.lua must iterate connected players and filter by this radius before sending.
}

-- ======================================================================
-- PHASE 2 — DOOR INTERACTION (nudge-open / scratch-to-alert). See §11.6
-- for why "nudge-open" is conditioned on the target server having a
-- separate door-lock resource, and why it's scoped client-only (mirrors
-- the vehicle-entry-exit "no real capability granted" exception in §4.1).
-- ======================================================================
Config.DoorInteraction = {
    interactDistance      = 1.5,  -- max distance to a door entity to show either option
    nudgeRequiresUnlocked = true, -- hard requirement, not a toggle: nudge-open must never function as a lockpick bypass -- see §11.6
    scratchCooldownMs     = 3000, -- per-player cooldown on the scratch-to-alert sound cue, same rationale as Config.Features.BasicBarkSounds' server-side cooldown in server/main.lua
}

-- ======================================================================
-- PHASE 2 — VISION (thermal / night). Both are native-toggle keybinds, no
-- custom shader/asset -- see §11.6 for the exact natives confirmed/refined
-- against SPEC.md §7's original claim.
-- ======================================================================
Config.Vision = {
    Thermal = { toggleKey = 'K' }, -- drives SetSeethrough(true/false) -- see §11.6
    Night   = { toggleKey = 'J' }, -- drives SetNightvision(true/false) -- see §11.6
}

-- ======================================================================
-- PHASE 3 — COMBAT & ADVANCED AGILITY (PHASE3_SPEC.md §12.2).
--
-- UPDATE (coder-security, this pass): PHASE3_SPEC.md §12.0 item 8 (the
-- client-relay/non-cooperating-target-client architecture question) is now
-- RESOLVED (Revision 4) — see that item's own "ship it, with binding
-- guardrails" verdict. `BiteAndHold` and `NonLethalTakedown` (including
-- their PLAYER-target paths, gated by `RequireWantedStatus` below) are
-- implemented this pass in `server/combat.lua` / `client/combat.lua`,
-- under item 8's five binding guardrails. `Config.Features.BiteAndHold`/
-- `NonLethalTakedown` STAY `false` above regardless — shipping the code
-- gated-off-by-default is not the same decision as flipping either flag on
-- a live server, which still wants its own separate go/no-go (balance
-- review, anim preview for BiteAndHold — see server/combat.lua's header).
--
-- STILL DELIBERATELY NOT ADDED — genuinely different, still-open blockers:
--   - `PropDragging` is OUT OF SCOPE for this pass (not requested, not
--     implemented) — its config entries stay absent rather than added as
--     dead placeholders. It shares item 8's Category B relay exposure for
--     its drag-speed-limit half (see item 8's own write-up) and ADDITIONALLY
--     needs PHASE3_SPEC.md §12.0 item 6's downed-check contract for a
--     player target, so it is not simply "the same pattern, one more
--     feature" — left for whoever picks it up next to design/implement
--     against item 8's already-resolved guardrails directly.
--   - `HandlerDownDefense` NO LONGER BLOCKED, AND NEITHER IS PropDragging.
--     Both of the "blocked" write-ups above and here are superseded and are
--     kept only so the reasoning that unblocked them is legible:
--       * PropDragging shipped -- see Config.Combat.PropDragging below,
--         plus client/combat.lua and server/combat.lua.
--       * HandlerDownDefense shipped -- see Config.Combat.HandlerDownDefense
--         below, plus server/defense.lua and client/defense.lua. Its stated
--         blocker (PHASE3_SPEC.md §12.0 item 7, "who is this K9's handler")
--         was resolved by the HandlerPartnership registry landing.
--         NOTE, because the spec was WRONG about this and a future editor
--         will otherwise re-derive it: §12.3 assumed HandlerDownDefense
--         could reuse an attacker identity from `relayDamageEvent`. That
--         event is deliberately PAYLOAD-LESS -- there is no attacker field
--         to reuse. server/defense.lua therefore carries its own, explicitly
--         low-trust hint channel, and no server-authoritative consequence
--         depends on that hint; the K9's confirmation is re-validated from
--         scratch by ValidateCombatRequest.
--     Both features still ship `false`, per this resource's convention that
--     a newly-landed mechanic stays off until its own go-live review.
-- Re-diff this block against PHASE3_SPEC.md §12.2 in full if either of the
-- above is picked up later, rather than assuming this copy stays in sync.
-- ======================================================================
Config.Combat = {
    -- Applies to BiteAndHold and NonLethalTakedown's player-target paths
    -- below (and would apply to PropDragging's, if/when that's built).
    -- PHASE3_SPEC.md §12.0 item 5 — RESOLVED, secure-by-default.
    RequireWantedStatus = true, -- a K9 may only target a PLAYER who is flagged wanted/suspect. Does NOT affect NPC targets (a "wanted" concept doesn't apply to an NPC this resource has no reason to protect from griefing).

    -- function(playerId: number) -> boolean, OPTIONAL, nil by default.
    -- Expected to be the NORMAL path for a real server, not the exceptional
    -- one — PHASE3_SPEC.md §12.0 item 5's own fragmentation note flags the
    -- default metadata guess below as LOWER CONFIDENCE than
    -- PropDragging's equivalent (`IsPlayerDownedOverride`, not yet added —
    -- see this file's PropDragging note above), because there is no single
    -- ecosystem-dominant convention for exposing a networked player's
    -- "wanted" state the way there is for a downed/laststand flag. Wire
    -- this directly to your dispatch resource's own export/state
    -- (cd_dispatch/ps-dispatch/qs-dispatch/in-house all differ). If this
    -- errors when called, server/combat.lua FAILS CLOSED (treats the
    -- target as NOT eligible) rather than falling back to the default
    -- metadata guess below — a broken override must never silently widen
    -- who can be targeted.
    WantedStatusCheckOverride = nil,
    -- Default best-effort check used ONLY when the override above is nil:
    -- reads `metadata.wanted` / `metadata.iswanted` off the target's own
    -- qbx_core PlayerData if present. See the confidence note above before
    -- relying on this in production — most real servers are expected to
    -- supply the override instead.

    -- PHASE3_SPEC.md §12.0 item 8 — DETECTION ONLY, NEVER ENFORCEMENT (see
    -- that item's guardrail 3: no server-authoritative consequence may ever
    -- be conditioned on one of these signals firing). Real, implemented
    -- sampling in `server/combat.lua`, not a sketch — see that file's own
    -- "NON-COMPLIANCE DETECTION" section for the full design writeup this
    -- table's fields map onto.
    NonComplianceDetection = {
        -- DEFAULT CHANGED true -> false. This flag is independent of
        -- BiteAndHold/NonLethalTakedown/PropDragging/HandlerDownDefense, which
        -- all default false -- so at `true` it span up a 500ms sampling thread
        -- on every default install, forever, sweeping a table that stays empty
        -- until a combat feature is actually enabled. The cost was negligible
        -- and the principle is not: nobody should pay a thread for a feature
        -- they have not switched on. Turn this on together with whichever
        -- combat mechanic you enable.
        enabled                = false,
        positionSampleWindowMs = 500,   -- how often the shared sampling thread re-reads every active hold/ragdoll's target position
        biteHoldIdleCeiling    = 0.3,   -- m/s -- a compliant BiteAndHold target is near-stationary (may turn in place); observed speed above (idleCeiling + biteHoldSpeedTolerance) is a candidate violation. UNTUNED placeholder, per item 8's own numbers.
        biteHoldSpeedTolerance = 0.5,   -- m/s -- item 8's own tightened recommendation for BiteAndHold specifically. Item 8's generic speedTolerance=1.0 baseline was flagged as too loose stacked on a 0.3 m/s idle ceiling, and has been deleted from this table entirely -- an audit confirmed it had no reader anywhere in the resource, under any feature flag; every effect type carries its own dedicated threshold instead. UNTUNED.
        biteHoldViolationSamples = 2,   -- consecutive over-threshold samples required before flagging — never a single noisy sample, per item 8's "never auto-punish/flag on one sample" instinct (mirrors server/tracking.lua's own FORGED TRAIL DECISION reasoning).
        takedownNetDisplacementMeters = 3.0, -- meters -- NonLethalTakedown uses NET DISPLACEMENT from the ragdoll-start position over the whole window as its primary signal instead of a continuous speed check (a genuine ragdoll produces noisy per-tick velocity from falling/sliding that a speed check would false-positive on) — see server/combat.lua's own comment for the disclosed simplification versus item 8's fuller "sustained consistent heading, not random tumbling drift" framing. UNTUNED.
        action                 = 'log', -- 'log' | 'notify_staff' -- deliberately NEVER 'auto_kick'/'auto_ban': a false positive from lag/desync must not itself become a punitive action without human review.
        -- function(playerId: number, effectType: string, evidence: table) -> nil, OPTIONAL, nil by default.
        -- A server that wants automated response beyond log/notify_staff
        -- builds it here, on top of real evidence — this resource never
        -- takes a punitive action on its own initiative. Any error raised
        -- by this callback is caught and logged; it never interrupts the
        -- sampling thread for other active holds.
        OnViolationOverride    = nil,
        -- PropDragging's own compliance slack, in METERS. Distinct from the
        -- speed-based thresholds above BY DESIGN: a drag's compliance
        -- signal compares the target's live position against the DRAGGING
        -- K9's own live position, not against an absolute speed ceiling,
        -- because PHASE3_SPEC.md §12.0 item 8's corollary is that a hostile
        -- target can simply self-detach (DetachEntity is very likely not
        -- ownership-gated). A target that has broken free reads as a
        -- growing gap, which an absolute speed ceiling would miss entirely.
        -- Log-only like every other field here — the ACTUAL enforcement for
        -- a runaway drag is Config.Combat.PropDragging.maxDragDistance
        -- below, which is checked unconditionally and is never gated behind
        -- `enabled`.
        dragComplianceSlackMeters = 4.0,
    },

    -- PHASE3_SPEC.md §12.5.4. MIXED Category A/B per §12.0 item 8, and the
    -- only Phase 3 mechanic that is: the ATTACH is Category A (server-side
    -- authoritative, robust against a hostile target client) while the
    -- SPEED LIMIT is Category B (SetPedMoveRateOverride is local-only, so a
    -- modified target client can ignore it). client/combat.lua re-asserts
    -- the attach EVERY TICK rather than once, specifically because a target
    -- can self-detach — see that file's own guardrail comments.
    -- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
    -- balance pass, same status as every other Phase 3 tuning number here.
    PropDragging = {
        range              = 2.5,    -- meters, self-initiated trigger range (matches BiteAndHold's)
        maxDragDistance    = 30.0,   -- meters from the drag's start point before the server force-ends it. THIS is the real "no unbounded trap" enforcement — checked unconditionally in the maintenance loop, never gated behind NonComplianceDetection.enabled.
        maxDragDurationMs  = 20000,  -- hard timeout if never manually released, same role as BiteAndHold's maxDurationMs
        dragSpeedMultiplier = 0.4,   -- Category B: applied to the TARGET's move rate while dragged. A modified client may ignore this; that is disclosed, not solved.
        -- function(targetServerId: number) -> boolean|nil, OPTIONAL.
        -- PHASE3_SPEC.md §12.0 item 6 made this a REQUIRED active config
        -- surface rather than a commented-out placeholder, because the
        -- native-only fallback is genuinely unreliable for players:
        -- IsPedDeadOrDying/IsPedRagdoll measure raw physics state, not a
        -- server's scripted laststand, so they both false-positive (a
        -- ragdolling but conscious player) and false-negative (a player in
        -- a scripted laststand that keeps the ped "alive"). Point this at
        -- your own ambulance/laststand resource. server/combat.lua FAILS
        -- CLOSED if this errors — treats the target as NOT downed — and
        -- only falls back to a best-effort metadata.isdead/.inlaststand
        -- guess when this is nil, exactly like WantedStatusCheckOverride
        -- above.
        IsPlayerDownedOverride = nil,
    },

    -- PHASE3_SPEC.md §12.5.3, implemented in server/defense.lua +
    -- client/defense.lua. Per §12.0 item 2 this is a UI/auto-targeting
    -- CONVENIENCE, never an AI takeover — the K9 never acts on its own; a
    -- prompt is surfaced faster and the player still confirms.
    --
    -- Reuses Config.Combat.PropDragging.IsPlayerDownedOverride rather than
    -- adding its own: "is this player down per the server's own scripted
    -- laststand" is the same question for a drag target and a handler, and
    -- the same native-unreliability caveat applies (IsPedDeadOrDying /
    -- IsPedRagdoll read raw physics, not laststand state).
    --
    -- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
    -- balance pass, same status as every other Phase 3 tuning number here.
    HandlerDownDefense = {
        -- RAISED 100 -> 140. 100 is GTA's own player-ped "already dying"
        -- boundary -- this resource documents it as exactly that where
        -- NonLethalTakedown uses it as a health FLOOR, which is correct there.
        -- As a TRIGGER for "alert my partner K9, my handler is in trouble" it
        -- meant the alert only fired once the handler was already at the death
        -- line, leaving no lead time for the K9 to actually respond -- the
        -- number was right for its original use and wrong for this one.
        handlerHealthThreshold   = 140,   -- fallback-only signal; the override above is the real check
        triggerRadius            = 15.0,  -- how close the partner K9 must be to be prompted
        hostileLookbackSeconds   = 10,    -- how far back an attacker hint stays relevant
        pollIntervalMs           = 1000,
        retriggerCooldownMs      = 30000, -- anti-spam; stamped at send, not at retry (see server/defense.lua)
        promptTtlMs              = 10000, -- client-local clock, see that file's CLOCK-DOMAIN note
        attackerReportCooldownMs = 500,
        confirmKey               = 'G',   -- always rebindable client-side
    },

    BiteAndHold = {
        range         = 2.5,    -- meters, self-initiated trigger range
        maxDurationMs = 15000,  -- hard timeout if never manually released — THIS IS the "no unbounded trap" guarantee for a non-consensual mechanic, PHASE3_SPEC.md §12.0 item 4. Never remove without an equally-hard replacement cap.
        cooldownMs    = 20000,  -- per-K9 cooldown between attempts
        -- Per-target cooldown, mirroring NonLethalTakedown.targetCooldownMs
        -- below. Without it the per-K9 cooldown is the only bound, and the
        -- `already_held` check does not help -- that only blocks a second
        -- CONCURRENT hold by a DIFFERENT K9, not the same K9 re-taking the
        -- same target once its own cooldown clears. A compliant or AFK
        -- target could therefore be bite-held every 20s indefinitely, each
        -- hold over MIN_BITE_HOLD_XP_DURATION_MS paying biteHoldSuccess --
        -- roughly 60 XP/min against one stationary target with no travel
        -- and no variety. Set slightly above NonLethalTakedown's 30000 on
        -- purpose: a bite hold can pay out every 3s of a 15s window,
        -- whereas a takedown is a single discrete event.
        --
        -- What this bounds, precisely: 35000 exceeds the 20000 per-K9
        -- cooldown, so against ONE target the per-target gate binds and the
        -- ceiling is about 2057 XP/hr. With two or more targets available
        -- the per-K9 cooldown binds instead and the ceiling rises to about
        -- 3600 XP/hr. That second number is the honest one for a populated
        -- server -- the per-target gate closes the degenerate
        -- single-stationary-target farm, it does not cap the mechanic
        -- overall, and the per-K9 cooldown was always the intended throttle
        -- for legitimate repeated use.
        targetCooldownMs = 35000,
    },
    NonLethalTakedown = {
        range               = 3.0,
        minTargetSpeed      = 4.0,   -- m/s, SERVER-COMPUTED from a short position-sample window at request time (see server/combat.lua's own note on why this is a bounded two-sample measurement, not a continuously-running per-ped tracker) — never a client-claimed "I am sprinting" flag. Applies identically whether the target is an NPC or a player.
        speedSampleWindowMs = 250,   -- how long the server waits between its two position samples to compute the target's speed for the check above — UNTUNED, and itself re-validates everything (existence, proximity, already-held, eligibility) again after the wait, same TOCTOU discipline as this resource's other yielding server calls.
        ragdollDurationMs   = 4000,  -- hard cap on BOTH the forced-ragdoll hold and the SetEntityCanBeDamaged(false) bracket — THIS IS the "no unbounded trap" guarantee for this mechanic, PHASE3_SPEC.md §12.0 item 4 (named there explicitly as "the ragdoll/damage-suppression window in NonLethalTakedown"). UNTUNED.
        cooldownMs          = 25000, -- per-K9 cooldown
        targetCooldownMs    = 30000, -- per-target cooldown -- stops repeat takedowns of the same already-downed target by multiple K9s in quick succession
        healthFloor         = 100,   -- backstop only, NOT the primary non-lethal mechanism -- primary mechanism is the SetEntityCanBeDamaged bracket above
    },

    AgilityAdvanced = {
        -- DECIDED (PHASE3_SPEC.md §12.0 item 3, Revision 2, unaffected by
        -- the Revision 3 PvP reversal): multi-height capsule-sweep raycast
        -- is the Phase 3 default. 'taggedProp' remains a documented,
        -- theoretical per-server override shape but has NO implementation
        -- in this codebase — client/movement.lua asserts loudly at
        -- resource start if this is ever set to anything other than
        -- 'raycast', rather than silently no-op'ing.
        detectionMethod = 'raycast',
        maxVaultHeight  = 1.2,   -- meters -- PHASE3_SPEC.md §12.2 sketch value, UNTUNED (see client/movement.lua's own tuning-constants note: PHASE3_SPEC.md §12.5.5 lists exact height bands/capsule radius/forward distance as in-engine tuning work, not a design fork)
        vaultCooldownMs = 2000,  -- ms, UNTUNED placeholder, same status as above
    },
}

-- ======================================================================
-- PHASE 3 — HANDLER/K9 PARTNERSHIP REGISTRY (Config.Features.HandlerPartnership,
-- server/partnership.lua + client/partnership.lua). PHASE3_SPEC.md §12.0
-- item 7 (Revision 5, coder-architect) / §12.3's file-plan entry.
--
-- OWN TOP-LEVEL BLOCK, DELIBERATELY NOT NESTED UNDER Config.Combat: this
-- mechanic has its OWN file, its OWN feature flag (independent of
-- BiteAndHold/HandlerDownDefense per the resolved design's explicit
-- "one-flag-per-mechanic" reasoning), and its own owner (server/
-- partnership.lua, not server/combat.lua) — nesting its tuning knobs inside
-- Config.Combat (a different file's config namespace) would blur that
-- ownership split for no benefit. Mirrors this file's own established
-- convention of one dedicated top-level table per Phase 2/3 feature
-- (Config.Tracking, Config.SearchZones, Config.DoorInteraction, Config.Vision,
-- Config.Combat above) rather than a single everything-table.
--
-- This registry started as a FOUNDATION ONLY, with no combat consequence
-- wired to it. That is no longer true, and this note is kept only so the
-- progression is legible: both mechanics PHASE3_SPEC.md 12.0 item 7 named as
-- blocked on this registry existing are now built and consuming it --
-- HandlerDownDefense's trigger (server/defense.lua) and the Recall actor
-- (server/recall.lua, Config.Recall below). Both call
-- `GetActivePartnerCitizenId`/`IsActivePartnerOf` directly rather than
-- re-deriving their own partner lookup, per this registry's accessor
-- contract (see server/partnership.lua's header). A third consumer,
-- server/tenure.lua, reads the same registry for the tenure bonus.
-- ======================================================================
Config.Partnership = {
    -- PHASE3_SPEC.md §12.0 item 7 point 1 explicitly leaves "reuse
    -- Config.CertifyProximityMeters or a dedicated
    -- Config.Combat.PartnerProximityMeters" as an implementer's call, not a
    -- design fork. A DEDICATED constant is used here (not a direct reuse of
    -- Config.CertifyProximityMeters, and not nested under Config.Combat --
    -- see this block's own header above) so this mechanic's own proximity
    -- rule can be tuned independently of certification's without an
    -- unrelated cross-feature edit. Same 5.0m default as
    -- Config.CertifyProximityMeters purely because it's a reasonable
    -- starting point for the same class of "stand near each other and
    -- confirm" interaction, not because the two are meant to stay coupled.
    ProximityMeters   = 5.0,

    -- Mirrors server/main.lua's LEASH_REQUEST_TTL_MS / LEASH_REQUEST_COOLDOWN_MS
    -- exactly (same "a request nobody answers shouldn't linger indefinitely
    -- available for a stale accept" / "stop UI-harassment via repeat
    -- prompts" reasoning as the leash consent handshake this mechanic
    -- deliberately mirrors — PHASE3_SPEC.md §12.0 item 7 point 1).
    RequestTTLMs      = 30000,
    RequestCooldownMs = 1000,

    -- server/tenure.lua (Config.Features.PartnershipTenureBonus). Nested
    -- here rather than given its own top-level block because it tunes THIS
    -- mechanic's payoff, not a subsystem of its own.
    TenureBonus = {
        -- server/tenure.lua's poll cadence, independent of
        -- Config.Wellbeing.tickIntervalMs (an unrelated subsystem).
        -- Milestones are hours-to-days away, so a coarse interval costs
        -- nothing in perceived responsiveness and keeps the one indexed
        -- SELECT this adds per online, actively-partnered K9 effectively
        -- free.
        checkIntervalMs = 300000, -- 5 minutes

        -- MUST stay sorted ascending by afterSeconds -- server/tenure.lua's
        -- tier walk breaks on the first unmet threshold, mirroring
        -- Config.ContrabandAlertTiers' identical documented ordering
        -- requirement. Each actionKey must have a matching entry in
        -- Config.XP.awards above, or the award silently resolves to nothing.
        milestones = {
            { afterSeconds = 86400,   actionKey = 'partnershipTenure1Day'  },
            { afterSeconds = 604800,  actionKey = 'partnershipTenure7Day'  },
            { afterSeconds = 2592000, actionKey = 'partnershipTenure30Day' },
        },
    },
}

-- ======================================================================
-- RECALL (Config.Features.Recall) -- server/recall.lua, client/recall.lua.
-- PHASE3_SPEC.md 12.5.1's "Recall actor": the handler's escape hatch for
-- ending whatever active effect their partnered K9 is holding.
--
-- READ THIS BEFORE TUNING: Recall is this resource's PRIMARY TERMINATION
-- PATH, and the cooldown below is the only throttle on it. It exists to
-- stop request spam, never to delay a legitimate first recall -- keep it
-- small. Do NOT add an access check, a proximity requirement, or a
-- feature-flag dependency on the combat mechanics to this path: a handler
-- whose certification is revoked mid-bite must still be able to call their
-- dog off, and every gate added here is a step toward the unbounded trap
-- this resource forbids outright.
-- ======================================================================
Config.Recall = {
    -- Per-CALLER (the handler issuing the recall) rate limit.
    RequestCooldownMs = 2000,
}

-- ======================================================================
-- CONTRABAND SCREEN FX (Config.Features.ContrabandScreenFX) --
-- client/screenfx.lua. A brief timecycle effect on the SEARCHING K9 player's
-- own screen when their search turns up contraband -- sensory feedback for the
-- dog, not a penalty applied to the suspect.
--
-- An earlier version of THIS COMMENT said "the SEARCHED player's own screen",
-- which never matched the code: server/search.lua fires this at `source`, the
-- searcher. The code is the intended behaviour and the comment was wrong.
-- Worth stating rather than silently editing, because a future maintainer
-- reading only the old comment would have "fixed" the code to match it and
-- turned a cosmetic self-effect into something applied to another player.
-- ======================================================================
Config.ContrabandScreenFX = {
    -- Which Config.ContrabandAlertTiers tier(s) trigger the effect. Only
    -- the most severe by default -- firing on every tier would make this
    -- constant rather than notable.
    triggerTiers = { 'aggressive_bark' },

    -- VERIFIED. The candidate that shipped here first, 'drug_wobbly_shroom',
    -- DOES NOT EXIST -- a native audit checked every `drug_`-prefixed entry in
    -- a real game-data extraction of 2806+ timecycle modifiers and found only
    -- 'drug_wobbly' (56 modifications, "Drug" category, base game). The wrong
    -- name would have been a silent no-op forever: the feature would have
    -- shipped, been enabled, and simply never shown anything, with nothing in
    -- the logs to say why.
    modifierName = 'drug_wobbly',

    -- Deliberately well below PHASE4_SPEC.md 13.2's 8000ms sketch: this is
    -- meant to be feedback, not a screen-blocking penalty, and the
    -- modifier family is a disorienting one. client/screenfx.lua clamps its
    -- own effective ceiling to 4000ms regardless of what is set here.
    durationMs = 3000,
}

-- ======================================================================
-- ADMIN AUDIT SURFACE (Config.Features.AdminAuditCommands) --
-- server/admin.lua. Read-only SELECTs over the three tables this resource
-- writes. No mutation path exists in that file at all.
-- ======================================================================
Config.AdminAudit = {
    -- WHO CAN RUN THESE: police job rank, not an ACE permission. A caller
    -- must hold a job listed in Config.Departments below, and either be a
    -- boss of that job (job.isboss) or sit at or above that department's
    -- own `auditGrade`. There is no ACE grant to configure -- the old
    -- AcePermission key was removed on 2026-08-25 when server/admin.lua
    -- switched to job rank. SET auditGrade DELIBERATELY: these commands
    -- expose who searched whom and when, so it is a privacy boundary as
    -- well as an admin one.

    -- Whether a `source == 0` caller bypasses the rank check. DEFAULTS OFF,
    -- and think before turning it on: in FiveM `source == 0` is not only the
    -- server console. It is also an RCON client (authenticated by
    -- rcon_password alone) and ANY other resource on this server calling
    -- ExecuteCommand -- these commands are registered unrestricted, so a
    -- compromised or buggy co-located resource could otherwise read the whole
    -- audit trail with no rank at all. Turning this on accepts all three.
    -- A genuine console operator can instead be given a job grade at or
    -- above auditGrade, or simply query the database directly.
    TrustConsole = false,

    -- Shared across all three commands, keyed by caller.
    CommandCooldownMs = 3000,

    -- Per-command result caps. server/admin.lua additionally clamps every
    -- one of these into [1, 100] in code regardless of what is set here, so
    -- a careless edit cannot turn an audit command into a table dump.
    MaxResults = {
        Certifications = 25,
        Partnerships   = 25,
        SearchLog      = 25,
    },
}

-- ======================================================================
-- PHASE 5 (R&D) — DEPLOYABLE KENNEL (Config.Features.DeployableKennel,
-- still `false` by default — see this block's own note on that below).
-- phase2_notes/phase5_features_research.md §5: "handler places a world...
-- kennel object... server-authoritative validation (proximity,
-- certification, one-per-handler limit), with cleanup on resource stop/
-- handler disconnect." See client/kennel.lua and server/kennel.lua for the
-- full implementation and their own file-header contracts.
--
-- PROP MODEL CONFIDENCE — read before changing `propModel` below:
-- `phase5_features_research.md` §5 found exactly ONE lead for a real
-- vanilla GTA doghouse/kennel prop name (`prop_doghouse_01`, sourced from
-- a DIFFERENT, unrelated FiveM resource's config default —
-- `fruitmob/murderface-pets`), and explicitly could NOT cross-verify it
-- against a second independent source this session (gtax.dev/gtahash.com/
-- a GTA Wiki "Doghouse" page were all blocked by this environment's
-- egress proxy). Per this project's established two-independent-source
-- confidence convention (see client/hud.lua's own stamina-native
-- confidence note for the same discipline applied to a native, applied
-- here to an asset name instead): PLAUSIBLE, NOT VERIFIED. Confirm it
-- actually streams/loads in-engine before treating it as settled — do not
-- silently upgrade this comment's confidence just because the feature
-- shipped without incident in one test session.
-- ======================================================================
Config.DeployableKennel = {
    -- Try this first. Single-source, unconfirmed lead — see the note
    -- above. client/kennel.lua's LoadModelWithTimeout() falls back to
    -- `fallbackPropModel` below if this model hash never loads within
    -- REQUEST_MODEL_TIMEOUT_MS, rather than silently placing nothing or
    -- erroring the whole feature out.
    -- REFUTED AND REPLACED 2026-08-25. `prop_doghouse_01` was carried on a
    -- single unverified source and does NOT appear in a 5,171-entry live
    -- object database that has an in-engine rendered screenshot per entry --
    -- its screenshot URL 404s. The two places the old name did appear both
    -- trace to author assumptions, and the "second" source turned out to be
    -- the same author reusing his own earlier config value, so it was never
    -- independent corroboration at all.
    -- `prop_dog_cage_01` (hash 379820688) IS in that database with a real
    -- rendered screenshot. Not exhaustive proof the old name is fake, but it
    -- is checkable evidence that affirmatively did not contain it while
    -- containing a real themed substitute.
    propModel = 'prop_dog_cage_01',

    -- Deliberately NOT a second guess at a "kennel-shaped" model name — a
    -- second unverified guess would carry the exact same single-source
    -- risk this fallback exists to avoid. Reuses `prop_tennis_ball`, the
    -- ONE prop name this same research pass (§4, FetchMechanic) rated
    -- highest-confidence "confirmed real and available" of any prop
    -- mentioned anywhere in that document — it traces to a real, working,
    -- source-read community script's shipped config default, not just a
    -- bare name reference. It is NOT thematically a kennel; it exists
    -- purely as a safe, visible, definitely-real placeholder so a bad
    -- `propModel` lead degrades to "an oddly-shaped but real object
    -- appears" rather than a silent failure or a broken/invisible entity.
    -- Swap for a real doghouse/kennel asset (custom-modeled or a
    -- confirmed vanilla prop) once one is verified in-engine.
    fallbackPropModel = 'prop_tennis_ball',

    -- Meters in front of the handler's own live server-side position
    -- (server/kennel.lua computes this from GetEntityForwardVector, never
    -- a client-claimed coordinate — see that file's header) where the
    -- kennel spawns before PlaceObjectOnGroundProperly snaps it to the
    -- ground. UNTUNED placeholder, same status as PHASE3_SPEC.md's own
    -- vault-tuning constants (client/movement.lua) — a reasonable-looking
    -- default, not a playtested value.
    placementForwardOffsetMeters = 2.0,

    -- ox_target interaction range for the "Pick Up Kennel" option
    -- (client/kennel.lua). Reuses the same order of magnitude as
    -- Config.VehicleInteractMeters's role for vehicle entry/exit rather
    -- than inventing an unrelated scale.
    interactDistanceMeters = 2.5,

    -- Per-source rate limit on *requesting* a new placement (server/
    -- kennel.lua's DeployCooldown) — spam defense only, distinct from the
    -- one-active-kennel-per-handler limit below (a handler who already has
    -- an active kennel is refused regardless of this cooldown; this only
    -- throttles how fast repeated requests can even reach that check).
    deployCooldownMs = 5000,

    -- How long server/kennel.lua holds a "waiting for the client to
    -- confirm it actually created the object" slot open before it expires
    -- and frees up for a new attempt — mirrors LEASH_REQUEST_TTL_MS's exact
    -- reasoning in server/main.lua (a request nobody ever answers must not
    -- linger indefinitely).
    pendingPlacementTtlMs = 15000,
}
-- ONE-KENNEL-PER-HANDLER LIMIT (not a config knob — see server/kennel.lua's
-- header for the full "your call, documented" reasoning): the server-side
-- registry is a single-slot `Kennels[citizenid]`, not an array, so this is
-- a hardcoded invariant, not something a `maxActivePerHandler` field here
-- could raise without a real code change to the registry shape itself.
-- Deliberately NOT modeled as a per-area/spatial limit — see that file's
-- header for why.

-- ======================================================================
-- PHASE 5 (R&D) — ADVANCED BARK RADIAL (Config.Features.AdvancedBarkRadial,
-- still `false` by default — layered on top of Config.Features.BasicBarkSounds
-- per this resource's existing Phase-5-on-Phase-1 convention, see
-- client/radial.lua's Bark item for the enforcement of that layering).
-- SPEC.md §6.7 names the variant set explicitly: "Radial bark options
-- (aggressive/alert/calm) each play a distinct sound asset attached to the
-- K9 entity" — that's the exact set shipped here, not an arbitrary pick
-- (phase2_notes/phase5_features_research.md §1 confirms no other count is
-- named anywhere in the spec).
--
-- `sound` is still the SAME placeholder posture as client/main.lua's
-- BARK_SOUND_NAME/K9_SOUND_SET (see that file's header comment in full) —
-- none of these resolve to real, distinct authored audio yet.
-- phase5_features_research.md §1 confirms a real per-variant soundset needs
-- authored `.awc`/`dat151`/`dat54` RAGE-audio-bank assets, not just a
-- different string here — this table only carries the plumbing (which
-- placeholder name maps to which radial item/barkType), not the asset
-- itself. PlaySoundFromEntity with an unrecognized name/set combination is
-- a harmless no-op, so this ships safely with zero real audio, same as
-- Phase 1's single bark.
--
-- `barkType` is the exact string sent over the EXISTING
-- 'qbx_k9unit:server:relayBark' event (client/radial.lua) and echoed back
-- opaquely by server/main.lua's handler, which enforces
-- `BARK_TYPE_MAX_LENGTH = 16` — keep every `barkType` value below at or
-- under that length. server/main.lua itself is NOT modified for this
-- feature; it already accepts any opaque, length-capped string with no
-- enum validation.
-- ======================================================================
Config.AdvancedBarkRadial = {
    { barkType = 'bark_alert',      label = 'Alert Bark',      icon = 'triangle-exclamation', sound = 'Bark_Alert' },
    { barkType = 'bark_aggressive', label = 'Aggressive Bark', icon = 'skull',                sound = 'Bark_Aggressive' },
    { barkType = 'bark_calm',       label = 'Calm Bark',       icon = 'moon',                 sound = 'Bark_Calm' },
}

-- ======================================================================
-- PHASE 4 — K9 INVENTORY (ox_inventory stash). Backs
-- Config.Features.K9Inventory (still `false` above, per this resource's
-- "ship disabled until acceptance criteria are fully met" convention).
-- See PHASE4_SPEC.md §13.4.2 for the full security-critical integration
-- writeup this table backs, and server/inventory.lua's own header for the
-- concrete implementation (RegisterStash owner/groups derivation,
-- confidence-graded ox_inventory export notes). Transcribed from
-- PHASE4_SPEC.md §13.2's sketch, with `accessScope`'s Open Question (§13.4.2
-- item 1 / §13.6 item 3) RESOLVED below rather than left as a placeholder.
-- Every numeric value is still an unreviewed placeholder pending a
-- config-validator/economy-balance-agent pass (SPEC.md §9 item 4,
-- PHASE4_SPEC.md §13.5), same status every other Phase 3/4 sketch table in
-- this file carries — do not default Config.Features.K9Inventory to `true`
-- before that pass happens.
-- ======================================================================
Config.K9Inventory = {
    slots         = 5,
    maxWeight     = 8000,  -- grams-equivalent, same units ox_inventory's own item .weight fields use (unit convention confirmed: phase2_notes/contraband_search_contract.md §1)
    interactRange = 2.0,

    -- 'department' is the ONLY supported value (coder-security finding,
    -- this pass — see server/inventory.lua's header "RESOLVED DESIGN
    -- DECISION" section for the full reasoning): any player whose job is a
    -- key in Config.Departments (any grade) may open a given K9's gear
    -- stash, shared-field-equipment framing, the same posture
    -- Config.K9Vehicles already gives patrol-vehicle trunk access.
    -- 'ownerOnly' was previously documented here as an equally-supported
    -- alternative -- it was NOT: ox_inventory's RegisterStash `owner`
    -- argument is never checked against the calling player's identity
    -- anywhere in ox_inventory's own open-inventory path (only `groups`
    -- is), so 'ownerOnly' provided no real access control at all and is
    -- HARD-ENFORCED OUT at resource start (assert, server/inventory.lua) --
    -- changing this value away from 'department' will crash the resource
    -- on startup by design.
    accessScope   = 'department',

    -- nil = no item whitelist enforced (ox_inventory's own slot/weight
    -- limits are the only restriction).
    --
    -- NOW ENFORCED. The note that stood here said this was deliberately not
    -- built, and warned an owner not to assume setting it did anything. That
    -- warning was correct when written and is now obsolete:
    -- server/inventory.lua enforces the list through ox_inventory's own
    -- `swapItems` hook.
    --
    -- Expects a plain array of item-name strings (same convention as
    -- Config.SearchContrabandItems). `nil` means no filtering, which stays the
    -- default -- an empty table would mean "allow nothing", a very different
    -- and much worse default to ship by accident.
    --
    -- Filters only what goes IN. Nothing is ever filtered on the way OUT, so a
    -- tightened list can never strand an item already in a stash -- that would
    -- be the unbounded trap this resource forbids.
    --
    -- The enforcement point was verified against ox_inventory's real source
    -- rather than assumed, because this resource has already shipped one
    -- illusory access control (an `accessScope` setting documented as
    -- restricting access that provided none). A hook returning false genuinely
    -- aborts before any mutation. If `registerHook` is unavailable on a given
    -- install, the stash still works unfiltered and logs one warning rather
    -- than silently pretending to filter.
    allowedItems  = nil,
}

-- ======================================================================
-- PHASE 4 — K9 MEDKIT (Config.Features.K9Medkit, still `false` by default).
-- PHASE4_SPEC.md §13.4.4/§13.2. Item consumption + heal validation live in
-- server/medkit.lua; see that file's header for the full security-critical
-- writeup (mirrors server/search.lua's contraband-search trust boundary,
-- per that document's own explicit direction to reuse it as the template).
-- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
-- config-validator/economy-balance-agent pass (SPEC.md §9 item 4's scope,
-- widened by PHASE4_SPEC.md §13.5) — do not flip Config.Features.K9Medkit
-- to `true` on a live server before that review happens.
-- ======================================================================
Config.K9Medkit = {
    itemName      = 'k9_medkit', -- PLACEHOLDER item name — must exist in the target server's ox_inventory items table; NOT registered as a hotbar-"useable" item by this resource, see server/medkit.lua's header for why
    healthRestore = 50,          -- native health units restored to the K9's REAL ped health, clamped to GetEntityMaxHealth server-side, never allowed to overheal
    injuryRestore = 40,          -- restores Config.Wellbeing.Injury's tracked value once server/wellbeing.lua (PHASE4_SPEC.md §13.1 sub-phase 4c/4d) exists — a no-op today, see server/medkit.lua's header
    range         = 2.0,         -- meters — server-enforced max distance between the using player and the target K9's own live positions, checked BEFORE any item consumption or health mutation
    cooldownMs    = 60000,       -- per-target (K9 citizenid) cooldown, prevents repeated instant-heal spam against the same K9
    -- Job names, in addition to any job ∈ Config.Departments, allowed to use
    -- this item on a K9 — mirrors PHASE3_SPEC.md §12.0 item 4's resolved
    -- "default metadata/job convention + override hook" pattern for the
    -- identical class of external-EMS-integration problem.
    emsJobs       = { 'ambulance' },
    -- IsMedkitUserAuthorizedOverride: function(usingPlayerServerId) -> boolean,
    -- OPTIONAL. Forward-looking override hook for a server whose EMS/
    -- qualification system isn't captured by a flat job-name list — left
    -- commented out until a server actually needs it, so it isn't mistaken
    -- for an active default. See server/medkit.lua's IsMedkitUserAuthorized.
    -- IsMedkitUserAuthorizedOverride = function(usingPlayerServerId) return false end,
}

-- ======================================================================
-- PHASE 4 — K9 WELLBEING (Config.Features.FatigueSystem / MoodSystem /
-- FearStressSystem / DistractionSystem / InjuryLimping — ALL still `false`
-- by default). PHASE4_SPEC.md §13.0 Decision 1 / §13.2 / §13.4.3: ONE
-- shared config table, ONE shared server/wellbeing.lua + client/wellbeing.lua
-- pair, ONE shared per-citizenid stat store and tick loop backing all five
-- independently-gated stats — mirrors Config.Tracking's existing
-- Scent/Blood/Gunpowder precedent (three independently-toggleable flags,
-- one shared file pair). ALL NUMERIC VALUES BELOW ARE UNREVIEWED
-- PLACEHOLDERS pending a config-validator/economy-balance-agent pass
-- (SPEC.md §9 item 4's scope, widened by PHASE4_SPEC.md §13.5) — do not
-- flip any of the five owning Config.Features flags to `true` on a live
-- server before that review happens.
-- ======================================================================
Config.Wellbeing = {
    tickIntervalMs = 5000, -- ONE shared server-side decay/regen tick for all five stats -- see server/wellbeing.lua's header for why this beats five independent timers

    Fatigue = {
        max                     = 100,
        sprintDecayPerTick      = 2.0,  -- applied per tick while server-computed speed indicates sprinting
        idleRegenPerTick        = 1.0,  -- per tick while not sprinting
        restRegenPerTick        = 4.0,  -- WIRED. server/wellbeing.lua scans GetAllObjects()/GetAllVehicles() once per tick (shared across all K9s, not per-K9) for restSources models and applies this instead of idleRegenPerTick when a K9 is within restRadius and not sprinting. Positions are resolved server-side; a client can never claim to be resting. The "NOT WIRED THIS PASS" note that stood here was true when written.
        restRadius              = 5.0,
        -- The DETECTION is wired (see restRegenPerTick above -- the scan,
        -- the radius check and the server-side position resolution are all
        -- real). What is unverified is this MODEL NAME: 'water_bowl' is a
        -- guess that never got the two-independent-sources treatment
        -- prop_dog_cage_01 and prop_bodyarmour_02 got elsewhere in this
        -- file, so it may match nothing in the world. Confirm it on a dev
        -- server before enabling FatigueSystem, or the rest bonus simply
        -- never triggers -- silently, since a scan that matches nothing is
        -- indistinguishable from a K9 that is never near a rest source.
        restSources             = { 'water_bowl' },
        speedPenaltyThreshold   = 30,   -- fatigue below this value triggers the penalty
        -- RAISED 0.85 -> 0.90. These three wellbeing penalties MULTIPLY:
        -- client/movement.lua's own comment computes the worst case as
        -- Injury 0.7 * Fatigue 0.85 * Mood 0.9 ~= 0.535. That is the ordinary
        -- aftermath of one bad gunfight, and at those values an Elite K9
        -- (1.15x tier bonus) nets 0.615x -- SLOWER than a healthy Recruit.
        -- Three independently-reviewed "mild" penalties compounded into half
        -- speed because nobody reviewed them together. New worst case ~0.684.
        speedPenaltyMultiplier  = 0.90, -- fed into RecomputeK9MoveRate() (client/movement.lua, K9MoveRateModifiers.fatigue), never a standalone SetPedMoveRateOverride call
        -- NOT in PHASE4_SPEC.md §13.2's sketch verbatim -- added here
        -- because "sprinting" needs a concrete speed cutoff to classify
        -- from a server-side rolling position-sample (meters travelled per
        -- tick / tickIntervalMs). This file's own independent
        -- implementation of the general technique PHASE3_SPEC.md §12.5.2
        -- describes for NonLethalTakedown's speed gate (that document was
        -- not re-read this pass, per this session's file-scope boundary --
        -- reconcile against server/combat.lua's real implementation once
        -- Phase 3 lands, if the two ever need to agree exactly). Unreviewed
        -- placeholder like every other numeric value in this table.
        sprintSpeedThreshold    = 4.0,  -- meters/second, averaged over one tick interval
    },
    Mood = {
        max                          = 100,
        damageDecayAmount            = 15,  -- flat decrement per logged damage event where the K9 itself is the victim (server/wellbeing.lua's own independent consumer of the relayDamageEvent relay server/tracking.lua also consumes)
        petRegenAmount               = 10,  -- per "Pet K9" ox_target interaction
        petCooldownMs                = 30000, -- per (interactor, target) pair -- stops repeat-pet spam
        feedRegenAmount              = 20,  -- per configured food item use
        feedItemName                 = 'k9_treat', -- PLACEHOLDER item name, needs to exist in the target server's ox_inventory items table
        -- RAISED 0.2 -> 1.0. This is the ONLY recovery path for a solo
        -- handler: server/wellbeing.lua rejects targetPed == usingPed for both
        -- Pet and Feed, so a K9 can never pet or feed itself. At 0.2 per 5s
        -- tick, Mood 0 -> full took ~42 minutes with nobody else online --
        -- long enough that most players would never see it move and would
        -- read the meter as broken. Now ~8.3 minutes, still leaving Pet/Feed
        -- (instant 10/20) clearly worth doing.
        passiveRegenPerTick          = 1.0,
        performancePenaltyThreshold  = 25,
        performancePenaltyMultiplier = 0.95, -- RAISED 0.9 -> 0.95, see Fatigue.speedPenaltyMultiplier's note on compounding. Fed into RecomputeK9MoveRate() (K9MoveRateModifiers.mood) -- resolves PHASE4_SPEC.md §13.4.3.2 open question 1 by taking reading (a), the document's own tentative recommendation (a movement-speed multiplier via the shared composer, not a success-chance penalty on a security-critical callback)
    },
    FearStress = {
        max                      = 100,
        gunfireRadius            = 20.0, -- meters -- reuses Phase 2's relayWeaponFire relay (server/tracking.lua also consumes it), new CONSUMER not new native
        gunfireLookbackSeconds   = 15,
        -- LOWERED 5.0 -> 3.0. At 5.0 with a 5s tick, continuous fire from ONE
        -- shooter crossed hesitationThreshold in ~70 seconds -- i.e. one
        -- ordinary firefight, which is precisely the situation BiteAndHold and
        -- NonLethalTakedown exist for. passiveDecayPerTick then needed ~6 more
        -- minutes to clear. See also the forgeability note on hesitationThreshold.
        risePerNearbyShotPerTick = 3.0,
        passiveDecayPerTick      = 1.0,
        -- RAISED 70 -> 85, alongside the rise-rate cut above.
        -- SECURITY, READ BEFORE ENABLING FearStressSystem TOGETHER WITH
        -- BiteAndHold OR NonLethalTakedown: server/combat.lua's
        -- ValidateCombatRequest rejects a bite/takedown while the K9
        -- IsHesitating(). Hesitation is driven by relayWeaponFire, which
        -- server/wellbeing.lua documents as deliberately payload-less and
        -- therefore FORGEABLE. That disclosure was written when nothing
        -- consumed IsHesitating(); combat.lua does now. So a hostile client
        -- can re-touch that event to lock out a specific K9's combat actions.
        -- CLOSED, and the wording here has been corrected: this comment used
        -- to say "indefinitely", which was true when written and is no longer.
        -- server/wellbeing.lua's HESITATION_MAX_CONTINUOUS_MS now caps any
        -- single continuous hesitation episode, forcing a real window in which
        -- ValidateCombatRequest is guaranteed to grant. What remains, and is
        -- disclosed rather than claimed closed, is that a forger who stays
        -- nearby can still cause repeated BOUNDED disruption.
        -- Two things worth carrying forward. First, the exploit was worse than
        -- its own original disclosure: once fearStress is primed, the renewal
        -- check re-extends hesitation every tick regardless of new input, so
        -- sustaining the lock cost roughly one forged event per minute, not
        -- the continuous spam the note assumed. Second, a forger targets
        -- ANOTHER player's K9 simply by standing within gunfireRadius of it --
        -- proximity to the victim, no relationship to the attacker required.
        -- Two correct reviews, one emergent hole in the seam between them.
        -- Tuning these numbers does NOT close it; the cap does.
        hesitationThreshold      = 85,
        hesitationDurationMs     = 8000,  -- how long a rejected Phase 3 combat-command attempt stays refused before the K9 may retry, absent a manual calm-down
        calmDownReduceAmount     = 40,    -- "Calm Down" command's effect (self-only, see server/wellbeing.lua)
        calmDownCooldownMs       = 15000,
    },
    Distraction = {
        flashbangImmune     = true, -- HALF IMPLEMENTED DELIBERATELY, AND SETTLED 2026-08-25 -- the missing half should stay missing; see the note below. server/wellbeing.lua exposes IsFlashbangImmune(citizenid) as a real callable accessor. What is deliberately NOT built is the consumer side: honouring immunity means listening to some third-party stun resource's event, whose name and payload shape are unknown, and fabricating a listener for an unnamed resource would look implemented and never fire. So a companion resource has something real to check, and this is still not a
        -- shipped guarantee on its own.
        -- RESEARCHED AND CLOSED, so this stops being reopened: the ecosystem has
        -- no dominant flashbang or stun resource to target. The popular ones are
        -- closed-source paid scripts -- unverifiable in principle, not merely
        -- unresearched -- and Qbox's own qbx_police ships no flashbang or taser
        -- at all, so there is no house implementation to piggyback on either.
        -- Of the two open-source candidates whose source was actually read, one
        -- reacts to a native game event AFTER the stun has landed (useless for
        -- prevention), and the other has a pre-effect gate that is an internal
        -- stub, not an export -- and FiveM resources do not share Lua global
        -- scope, so it cannot be overridden from outside regardless. Neither
        -- offers anything like ox_inventory's registerHook veto.
        -- Building a listener now would either never fire on a server not
        -- running that exact resource, or require maintaining a patch on
        -- someone else's niche script. Revisit only if a specific operator
        -- names the resource they actually run -- verifying one real contract
        -- is small and concrete; guessing generically is not.
        meatBaitItemName    = 'k9_meat_bait',      -- PLACEHOLDER
        meatBaitDurationMs  = 6000,
        meatBaitRadius      = 8.0,
        whistleItemName     = 'k9_ultrasonic_whistle', -- PLACEHOLDER
        whistleDurationMs   = 4000,
        whistleRadius       = 15.0,
        perTargetCooldownMs = 20000, -- stops the same K9 being re-distracted back-to-back
    },
    Injury = {
        max                     = 100,
        sprintBlockThreshold    = 30, -- below this, sprint input is blocked (client-local, see PHASE4_SPEC.md §13.0 Decision 3's disclosed bounded limitation)
        jumpBlockThreshold      = 20, -- below this, jump input is blocked
        speedPenaltyMultiplier  = 0.80, -- RAISED 0.7 -> 0.80, see Fatigue.speedPenaltyMultiplier's note on compounding. Fed into RecomputeK9MoveRate() (K9MoveRateModifiers.injury)
        damageDecayAmount       = 10, -- flat decrement per logged damage event -- independent value from Mood's own damageDecayAmount, same detection source
        -- RAISED 0.1 -> 1.0. K9Medkit was documented as "the intended
        -- primary recovery path," but at 0.1/tick a K9 dropped to 0 Injury
        -- (a handful of hits in one firefight, at damageDecayAmount 10 each)
        -- took ~16.7 real minutes to clear jumpBlockThreshold and ~25
        -- minutes to clear sprintBlockThreshold -- and client/wellbeing.lua
        -- HARD-BLOCKS sprint and jump input the entire time, with no server
        -- override. The medkit escape hatch also depends on an operator
        -- having actually registered Config.K9Medkit.itemName in their own
        -- ox_inventory, which this resource cannot guarantee (hence the new
        -- startup warning in server/wellbeing.lua). That combination is a
        -- stuck player, not a tuning choice. Same precedent and reasoning as
        -- Mood.passiveRegenPerTick's own 0.2 -> 1.0 raise above -- applied
        -- here because Injury's penalty is a hard INPUT BLOCK, a stronger
        -- case for parity than Mood's soft speed multiplier, not a weaker
        -- one. Now: jump clears in ~1.67 min, sprint in ~2.5 min, a full
        -- 0->100 climb in ~8.33 min, identical to Mood's adopted rate.
        passiveRegenPerTick     = 1.0,

        -- DEATH/RESPAWN RESTORE. Added to Injury the tick
        -- server/wellbeing.lua first observes a tracked K9's native health
        -- recover above its dead-health threshold after having been at or
        -- below it -- i.e. the K9 died and was revived. 100 = Injury.max, a
        -- FULL reset: the ped's real health is already restored to full by
        -- whatever laststand/ambulance system handles revival, so a virtual
        -- Injury value surviving that same event untouched was the real
        -- inconsistency.
        -- CONFIGURABLE: set to 0 to disable entirely (a supported no-op, for
        -- an operator who wants "still limping after respawn" for realism),
        -- or any value in [0, Injury.max] for a partial restore.
        -- DISCLOSED RESIDUAL RISK, restated 2026-08-25 after a red-team
        -- pass found the original wording understated it. What remains is:
        -- a player deliberately holding their K9's health at or below the
        -- dead-health threshold for at least MIN_DEATH_EPISODE_DURATION_MS
        -- (server/wellbeing.lua, ~60s at shipped defaults) and then healing
        -- normally, with no real ambulance or laststand flow required.
        -- That is bounded to a real minimum time cost per attempt and to
        -- ONE payout per episode -- never free, never unbounded.
        --
        -- What this fix already closed, and why the earlier wording here
        -- was wrong: the restore originally fired on ANY observed health
        -- crossing of the threshold, so an ordinary bandage after an
        -- ordinary hit paid a full Injury reset, and health oscillating
        -- during one genuine laststand could pay out several times. Both
        -- are now gated behind the minimum-duration check. The health
        -- transition itself is read SERVER-side and cannot be spoofed.
        --
        -- Note the duration gate is a code constant, not a config value,
        -- on purpose -- an operator-tunable minimum could simply be set
        -- low enough to reopen the exploit. Same reasoning as
        -- HESITATION_MAX_CONTINUOUS_MS elsewhere in that file.
        deathRespawnRestoreAmount = 100,
    },
}

-- ======================================================================
-- PROP ATTACHMENTS (Config.Features.PropAttachments) --
-- client/propattachment.lua, server/propattachment.lua. A visible prop
-- (vest/harness) attached to the K9 ped.
--
-- ABOUT boneIndex, because this is the part everyone gets wrong:
-- AttachEntityToEntity takes a bone INDEX, not a bone NAME, and the docs note
-- the index is "different to boneID". Three earlier research passes stalled
-- searching for a quadruped bone NAME, which does not exist to be found.
-- GetWorldPositionOfEntityBone is declared over a generic Entity (ENTITY
-- namespace, not PED), so it works against a dog ped -- but a dog skeleton's
-- layout differs from a human's, so the specific index has to be found by
-- looking. That is what Config.Features.BoneSweepDevTool exists for.
-- Default 0 is the root bone: always valid, never crashes, looks wrong.
-- ======================================================================
Config.PropAttachments = {
    -- UNVERIFIED. No confirmed lead for a K9 vest/harness prop was found, so
    -- this is a placeholder that will very likely not load. That is survivable
    -- by design: the fallback below is the one this actually degrades to.
    propModel         = 'prop_bodyarmour_02',
    -- The SAME model Config.DeployableKennel already falls back to, chosen for
    -- exactly that reason -- it is the one prop in this resource with a
    -- confirmed-safe track record rather than a second unverified guess. It
    -- will look wrong (a K9 wearing a tennis ball), which is the point: an
    -- obviously-wrong visible prop tells an operator to go find a real vest
    -- model, where a silent no-op would just look like the feature is broken.
    fallbackPropModel = 'prop_tennis_ball',
    boneIndex         = 0,                    -- root; replace after a dev-server sweep
    offsetX = 0.0, offsetY = 0.0, offsetZ = 0.0,
    rotX    = 0.0, rotY    = 0.0, rotZ    = 0.0,
    toggleCooldownMs         = 2000,
    pendingConfirmTtlMs      = 15000,
    confirmDistanceTolerance = 5.0,
}

-- ======================================================================
-- BONE SWEEP DEV TOOL (Config.Features.BoneSweepDevTool) -- see that flag's
-- own comment. Dev servers only.
-- ======================================================================
Config.BoneSweepTool = {
    -- Authorization is deliberately a SEPARATE, stricter principal from the
    -- audit commands' own `auditGrade`: granting someone read-only audit
    -- access must not also hand them a tool that spawns and attaches props.
    -- server/bonetool.lua therefore grants on `job.isboss` ONLY -- no numeric
    -- grade branch -- so there is no key to set here. The former
    -- `AcePermission = 'k9unit.bonesweep'` was removed on 2026-08-25 when
    -- that file dropped IsPlayerAceAllowed.
    TestPropModel     = 'prop_tennis_ball',
    MaxBoneIndex      = 200,
    TestOffsetX = 0.0, TestOffsetY = 0.0, TestOffsetZ = 0.0,
    CommandCooldownMs = 500,
}

-- ======================================================================
-- FETCH (Config.Features.FetchMechanic) -- client/fetch.lua, server/fetch.lua.
--
-- Note what this feature is NOT: the K9 does not walk the ball back on its
-- own. It cannot -- the K9 is a connected player's own character, and nothing
-- in this resource's architecture scripts a player's ped movement. The return
-- leg is a real player action ("Deliver to Handler", server-validated for
-- identity and live proximity) instead of a scripted walk.
-- ======================================================================
Config.FetchMechanic = {
    ballPropModel                = 'prop_tennis_ball',
    throwForwardOffsetMeters     = 1.0,
    throwUpOffsetMeters          = 1.2,
    throwForceForward            = 12.0,
    throwForceUp                 = 6.0,
    throwCooldownMs              = 5000,
    pendingThrowTtlMs            = 15000,
    maxBallLifetimeMs            = 300000, -- absolute ceiling; no ball outlives this
    -- ENFORCED SERVER-SIDE, not just as an ox_target radius. A red-team pass
    -- found this value was previously only the client's ox_target `distance`
    -- field -- pure UI -- so requestPickupFetchBall accepted a pickup from
    -- anywhere on the map. Any player with K9 access could take another
    -- player's ball remotely and then re-drop it at their own position.
    -- server/fetch.lua now re-measures live distance against this, the way
    -- requestDeliverFetchBall always did.
    pickupInteractDistanceMeters = 2.0,

    -- Pickup had NO rate limit before; only the initial throw did, which is
    -- what made the remote-steal loop freely repeatable. server/fetch.lua
    -- falls back to 500 if this is absent, so removing it degrades safely
    -- rather than removing the throttle.
    -- There is deliberately no releaseCooldownMs counterpart: voluntary
    -- release is an escape hatch, and NewCooldown treats a non-positive
    -- threshold as permanently-on rather than off, so a `0` here meant to
    -- disable the throttle would instead disable releasing. See
    -- server/fetch.lua's releaseFetchBall doc comment.
    pickupCooldownMs             = 500,
    deliverProximityMeters       = 3.0,
    maintenanceIntervalMs        = 2000,

    -- 'fake' (delete + animate) or 'attach' (real mouth-carried prop).
    -- Ships 'fake' deliberately: 'attach' is only honest once a dev-server
    -- sweep has found a real mouth/jaw index AND confirmed it does not clip
    -- during the bark/pant carry pose. The feature is fully playable in
    -- 'fake' mode without that step.
    mouthCarryMode = 'fake',
    mouthBoneIndex = 0, -- root; replace from a sweep, then set mouthCarryMode
    mouthOffsetX = 0.0, mouthOffsetY = 0.4, mouthOffsetZ = 0.15,
}

-- ======================================================================
-- PROXIMITY AUDIO (Config.Features.ProximityAudioFX) -- client/proximityaudio.lua.
-- Distance-scaled K9 audio over the NUI bridge's Web Audio gain node.
-- REMEMBER: no audio files ship with this resource. Until an operator supplies
-- html/sounds/<key>.ogg this is silent by design, not broken.
-- ======================================================================
Config.ProximityAudioFX = {
    scanIntervalMs  = 2500,  -- discovery cadence; never a per-frame loop
    triggerDistance = 25.0,  -- meters; must stay <= client/audio.lua's own 30.0 ceiling
    soundName       = 'Growl_Ambient', -- resolves to html/sounds/growl_ambient.ogg
}
