--[[
    qbx_k9unit/config.lua

    Transcribed verbatim from SPEC.md §5 ("Config schema (concrete shape)"),
    with one addition flagged below (Config.K9DespawnGraceSeconds) that the
    Phase 1 event/callback contract needs but SPEC.md §5 did not yet define.
    If SPEC.md is later revised, re-diff this file against §5 before trusting
    it as still in sync.
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
Config.LeashMaxDistance = 8.0   -- meters before auto-recall-to-heel triggers

-- ======================================================================
-- HANDLER-K9 REGISTRY — Phase 1 scaffolding addition, NOT in SPEC.md §5.
--
-- Added by coder-architect to satisfy the event/callback contract's
-- "player disconnect" clause (see server/main.lua): on `playerDropped`,
-- the server should not instantly wipe a handler's K9 registry entry
-- (netId -> citizenid link), since a quick reconnect should be able to
-- reclaim the same K9 rather than being forced to spawn a new one. This
-- is the grace window before that registry entry is cleared.
-- ======================================================================
Config.K9DespawnGraceSeconds = 60

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
