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
    ScentTracking        = false,
    BloodTracking        = false,
    WaterTrackingDecay   = false,
    GunpowderSniffing    = false,
    SearchZones          = false,
    ContrabandAlerts     = false,
    ThermalVision        = false,
    NightVision          = false,
    DoorInteraction      = false, -- nudge-open / scratch-to-alert

    -- Phase 3 (combat & action)
    BiteAndHold          = false,
    NonLethalTakedown    = false,
    HandlerDownDefense   = false,
    PropDragging         = false,
    AgilityAdvanced      = false, -- fence/window vault approximation

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory          = false,
    XPProgression        = false,
    HealthStaminaHUD     = false,
    FatigueSystem        = false,
    MoodSystem           = false,
    FearStressSystem     = false,
    DistractionSystem    = false,
    InjuryLimping        = false,
    K9Medkit             = false,
    ContrabandScreenFX   = false,

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial   = false,
    ProximityAudioFX     = false,
    PropAttachments      = false,
    FetchMechanic        = false,
    DeployableKennel     = false,
    CameraFeedPiP        = false, -- experimental; native-only approximation, see §7
}

-- ======================================================================
-- PED ROSTER — extensible, no code changes needed to add a streamed model.
-- ======================================================================
Config.Peds = {
    { model = 'a_c_shepherd',   label = 'German Shepherd' },
    { model = 'a_c_rottweiler', label = 'Rottweiler' },
    { model = 'a_c_huskie',     label = 'Husky' },
    { model = 'a_c_chop',       label = 'Chop (K9 Unit)' },
    -- Example custom streamed model (requires the model to exist in a
    -- streamed resource elsewhere on the server; adding this line is the
    -- *only* change needed to make it selectable):
    -- { model = 'a_c_k9_malinois', label = 'Belgian Malinois' },
}

-- ======================================================================
-- DEPARTMENTS — admin-editable list of job names with K9 access, plus the
-- rank threshold required to grant/revoke certifications for that job.
-- ======================================================================
Config.Departments = {
    ['police'] = {
        label           = 'Los Santos Police Department',
        certifierGrade  = 4,    -- job.grade.level required to grant/revoke certs (job.isboss always qualifies too)
        autoAccessGrade = nil,  -- nil = no auto-bypass; set an integer to let that grade+ skip certification (see §4.1 assumption)
    },
    ['sheriff'] = {
        label           = 'Blaine County Sheriff',
        certifierGrade  = 3,
        autoAccessGrade = nil,
    },
    ['bcso'] = {
        label           = 'Blaine County Sheriff (legacy job name)',
        certifierGrade  = 3,
        autoAccessGrade = nil,
    },
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
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRange = 5.0  },
    { xp = 500,  label = 'Trained K9', speedMultiplier = 1.05, scentRange = 6.5  },
    { xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRange = 8.0  },
    { xp = 3500, label = 'Elite K9',   speedMultiplier = 1.15, scentRange = 10.0 },
}

-- ======================================================================
-- CONTRABAND ALERT THRESHOLDS — Phase 2, placeholder pending
-- economy-balance-agent review against actual ox_inventory item weights.
-- ======================================================================
Config.ContrabandAlertTiers = {
    { minWeight = 1,   alert = 'whine' },          -- small personal-use amount
    { minWeight = 250, alert = 'aggressive_bark' }, -- large stash
}
