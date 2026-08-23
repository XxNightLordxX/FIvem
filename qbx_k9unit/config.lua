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
        markerSpacing    = 3.0,   -- meters between rendered trail markers/checkpoints
        searchCooldownMs = 5000,  -- per-player cooldown on re-issuing a "search" command of this type
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
    searchCooldownMs      = 10000, -- per-(K9, target) cooldown -- prevents repeat-search spam against the same vehicle/person to fish for a different roll or just to harass
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
