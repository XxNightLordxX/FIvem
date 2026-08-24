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
    HandlerPartnership   = false,

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
        -- §12.5.1). NOT YET WIRED: server/combat.lua does not exist in this
        -- codebase as of this pass (Phase 3 combat is being built
        -- separately/concurrently). Whoever lands it should call
        -- `AwardXP(citizenid, 'biteHoldSuccess')` (server/progression.lua,
        -- resource-global) from that success path — see
        -- server/progression.lua's own header for the exact call contract.
        biteHoldSuccess       = 20,
        -- server/combat.lua's requestTakedown success (PHASE3_SPEC.md
        -- §12.5.2) — same NOT YET WIRED note as biteHoldSuccess above.
        takedownSuccess       = 30,
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
--   - `HandlerDownDefense` is blocked on a DIFFERENT, separately open item
--     — PHASE3_SPEC.md §12.0 item 7 / phase2_notes/
--     phase3_handler_partnership_decision.md ("who is this K9's handler,
--     independent of momentary leash state" — genuinely unresolved, needs
--     a human product decision or a dedicated design pass, not a guess).
--     Now that `requestBiteHold`/`requestTakedown` exist for it to
--     pre-select a target into (§12.3's "pure consumer" framing), item 7 is
--     the ONLY remaining blocker for this feature specifically.
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
        enabled                = true,
        positionSampleWindowMs = 500,   -- how often the shared sampling thread re-reads every active hold/ragdoll's target position
        speedTolerance         = 1.0,   -- m/s of slack — GENERIC fallback only, not used by BiteAndHold (see biteHoldSpeedTolerance below, which item 8 explicitly recommends tightening for that specific check) — UNTUNED
        biteHoldIdleCeiling    = 0.3,   -- m/s -- a compliant BiteAndHold target is near-stationary (may turn in place); observed speed above (idleCeiling + biteHoldSpeedTolerance) is a candidate violation. UNTUNED placeholder, per item 8's own numbers.
        biteHoldSpeedTolerance = 0.5,   -- m/s -- item 8's own tightened recommendation for BiteAndHold specifically (the shipped generic speedTolerance=1.0 above was flagged as too loose stacked on a 0.3 m/s idle ceiling). UNTUNED.
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
        handlerHealthThreshold   = 100,   -- fallback-only signal; the override above is the real check
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
-- This registry is a FOUNDATION only, in this pass — it establishes/
-- persists/tears down a "who is my partner" relationship, with no combat
-- consequence wired to it yet. BiteAndHold's Recall actor and
-- HandlerDownDefense's trigger (the two features PHASE3_SPEC.md §12.0 item
-- 7 names as blocked on this registry existing) are OUT OF SCOPE for this
-- pass and remain unimplemented — see server/partnership.lua's own header
-- for the exact accessor functions (`GetActivePartnerCitizenId`,
-- `IsActivePartnerOf`) a future implementation of either should call rather
-- than re-deriving its own partner lookup.
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
        restRegenPerTick        = 4.0,  -- NOT WIRED THIS PASS -- see server/wellbeing.lua's open-question note; rest-source detection (PHASE4_SPEC.md §13.4.3.1 open question 1) is left unresolved, same as the spec itself leaves it, rather than inventing an unreviewed detection mechanism
        restRadius              = 5.0,
        restSources             = { 'water_bowl' }, -- PLACEHOLDER, not wired to any real detection this pass
        speedPenaltyThreshold   = 30,   -- fatigue below this value triggers the penalty
        speedPenaltyMultiplier  = 0.85, -- fed into RecomputeK9MoveRate() (client/movement.lua, K9MoveRateModifiers.fatigue), never a standalone SetPedMoveRateOverride call
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
        passiveRegenPerTick          = 0.2,
        performancePenaltyThreshold  = 25,
        performancePenaltyMultiplier = 0.9, -- fed into RecomputeK9MoveRate() (K9MoveRateModifiers.mood) -- resolves PHASE4_SPEC.md §13.4.3.2 open question 1 by taking reading (a), the document's own tentative recommendation (a movement-speed multiplier via the shared composer, not a success-chance penalty on a security-critical callback)
    },
    FearStress = {
        max                      = 100,
        gunfireRadius            = 20.0, -- meters -- reuses Phase 2's relayWeaponFire relay (server/tracking.lua also consumes it), new CONSUMER not new native
        gunfireLookbackSeconds   = 15,
        risePerNearbyShotPerTick = 5.0,
        passiveDecayPerTick      = 1.0,
        hesitationThreshold      = 70,
        hesitationDurationMs     = 8000,  -- how long a rejected Phase 3 combat-command attempt stays refused before the K9 may retry, absent a manual calm-down
        calmDownReduceAmount     = 40,    -- "Calm Down" command's effect (self-only, see server/wellbeing.lua)
        calmDownCooldownMs       = 15000,
    },
    Distraction = {
        flashbangImmune     = true, -- ASPIRATIONAL CONFIG ONLY -- NOT implemented this pass, genuinely integration-dependent (PHASE4_SPEC.md §13.4.3.4) on an unconfirmed third-party flashbang/stun resource's own event shape. Do not treat this as a shipped guarantee.
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
        speedPenaltyMultiplier  = 0.7, -- fed into RecomputeK9MoveRate() (K9MoveRateModifiers.injury)
        damageDecayAmount       = 10, -- flat decrement per logged damage event -- independent value from Mood's own damageDecayAmount, same detection source
        passiveRegenPerTick     = 0.1, -- deliberately very slow -- K9Medkit (Config.K9Medkit, via RestoreInjury) is the intended primary recovery path, not natural regen
    },
}
