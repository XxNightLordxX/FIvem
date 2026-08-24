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
    { model = 'a_c_husky',      label = 'Husky' },
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

-- ======================================================================
-- PHASE 3 — COMBAT & ADVANCED AGILITY (PHASE3_SPEC.md §12.2).
--
-- IMPORTANT — this is a DELIBERATELY PARTIAL extraction of PHASE3_SPEC.md
-- §12.2's full `Config.Combat` sketch, not the whole table. Only the
-- `AgilityAdvanced` sub-table is added here, because it is the ONLY Phase 3
-- combat/agility sub-feature actually implemented in this pass (see
-- client/movement.lua's own ADVANCED AGILITY block). `BiteAndHold`,
-- `NonLethalTakedown`, `PropDragging`, `HandlerDownDefense`, and the
-- cross-cutting `RequireWantedStatus`/`WantedStatusCheckOverride`/
-- `NonComplianceDetection` knobs are DELIBERATELY NOT added yet:
--   - `BiteAndHold`/`NonLethalTakedown`/`PropDragging`'s player-target
--     paths are blocked on PHASE3_SPEC.md §12.0 item 8 (the client-relay/
--     non-cooperating-target-client architecture question), explicitly
--     unresolved and being worked by coder-security as of this pass — do
--     not add their config entries as if they were ready to be wired up.
--   - `HandlerDownDefense` is blocked on a DIFFERENT, separately open item
--     — PHASE3_SPEC.md §12.0 item 7 / phase2_notes/
--     phase3_handler_partnership_decision.md ("who is this K9's handler,
--     independent of momentary leash state" — genuinely unresolved,
--     needs a human product decision or a dedicated design pass, not a
--     guess). Its own mechanics never touch a target ped's state (per
--     §12.0 item 2's UI/auto-targeting-convenience reading), so it is NOT
--     blocked by item 8 — but it cannot be meaningfully implemented yet
--     regardless, since (a) resolving "who is the handler" is exactly
--     item 7's open question, and (b) it is a "pure consumer" of the
--     `requestBiteHold`/`requestTakedown` action paths (§12.3), which do
--     not exist in this codebase yet and are themselves blocked. Adding
--     numeric placeholders for it here with nothing real to wire them to
--     would be misleading, not helpful groundwork.
-- Re-diff this block against PHASE3_SPEC.md §12.2 in full once those items
-- are resolved, rather than assuming this partial copy stays in sync.
-- ======================================================================
Config.Combat = {
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
    propModel = 'prop_doghouse_01',

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

    -- RESOLVED (coder-backend, this pass — see server/inventory.lua's header
    -- "RESOLVED DESIGN DECISION" section for the full reasoning, including
    -- why an 'ownerOnly' server is fully supported too, and why an
    -- unrecognized value here fails CLOSED to 'ownerOnly', not
    -- 'department'): 'department' (default) — any player whose job is a
    -- key in Config.Departments (any grade) may open a given K9's gear
    -- stash, shared-field-equipment framing, the same posture
    -- Config.K9Vehicles already gives patrol-vehicle trunk access. Set to
    -- 'ownerOnly' to instead restrict access to only the K9 player's own
    -- citizenid (a personal-locker framing) — both values are fully
    -- implemented, this is a real per-deployment product choice, not a
    -- placeholder pending code.
    accessScope   = 'department',

    -- nil = no item whitelist enforced (ox_inventory's own slot/weight
    -- limits are the only restriction). NOTE: as of this pass, setting this
    -- to a non-nil list has NO EFFECT — see server/inventory.lua's header
    -- CONFIDENCE NOTE for why item-whitelist enforcement (a
    -- registerHook-style mechanism, PHASE4_SPEC.md §13.4.2's own genuinely
    -- unresolved implementation question) was deliberately not built this
    -- pass rather than half-implemented. Left nil, not a placeholder list,
    -- so a server owner who sets this doesn't mistakenly believe it's
    -- already enforced.
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
