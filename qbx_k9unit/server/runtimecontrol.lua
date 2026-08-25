--[[
    qbx_k9unit/server/runtimecontrol.lua

    Config.Features.RuntimeFeatureControl / Config.Features.TabletTheming.
    The owner's own words: "I want the high command to have even more
    control over all the features and sub features" / "Or even able to edit
    the tablet look." Two independent surfaces, both tablet-callback-driven,
    both high-command-only, both persisted:

      PART 1 -- runtime feature control: switch a Config.Features.* flag on
      or off, and tune a small allowlisted set of numeric Config values,
      without editing config.lua or restarting -- where that is honestly
      possible (see "THE ENGINE CONSTRAINT" below; it is NOT always
      possible, and this file says so instead of pretending).

      PART 2 -- tablet theming: a handful of colour slots, a density
      setting, and one header-title string, saved server-side and applied
      for every viewer. COSMETIC ONLY -- see "PART 2" below for the exact
      boundary.

    ======================================================================
    THE ENGINE CONSTRAINT -- READ THIS BEFORE TRUSTING ANY TOGGLE THIS FILE
    OFFERS. Every feature in this resource gates its RegisterCommand/
    RegisterNetEvent/lib.callback.register calls ONCE, at file-load or
    onResourceStart time -- config.lua's own header on this exact flag
    quotes this as deliberate: "that is what makes a disabled feature
    genuinely inert instead of merely hidden." The consequence, worked out
    file-by-file below rather than assumed:
      - A feature whose HANDLER re-checks Config.Features.<Name> itself,
        live, on every invocation (not a value captured once at load) can
        be switched OFF at runtime and it genuinely, immediately stops --
        AND can be switched back ON just as immediately, because nothing
        about its registration ever depended on the flag in the first
        place. These are marked `tier = 'live'` below.
      - A feature gated ONLY at registration time, whose handler body does
        NOT re-check the flag, cannot be turned off by mutating the flag
        alone -- the handler stays reachable regardless, because it was
        already registered. Two different sub-cases, found by reading every
        registration site in this resource, not assumed from the pattern's
        name alone:
          * `tier = 'onstart'` -- the registration itself lives inside
            `AddEventHandler('onResourceStart', ...)`. THIS FILE is loaded
            before every one of these (see FXMANIFEST PLACEMENT below), so
            it registers ITS OWN 'onResourceStart' handler first -- when the
            server actually fires that event, handlers run in the order
            they were added, so this file's override re-application runs
            BEFORE theirs. That means a persisted override genuinely takes
            effect on the NEXT restart (never on the current one -- nothing
            can retroactively call RegisterCommand for a session already
            running), which is enough to satisfy "an override must survive
            a restart" for these.
          * `tier = 'rawtoplevel'` -- the registration is gated by a bare
            `if not Config.Features.X then return end` at the very top of
            the file, executed the instant that file's turn comes up during
            this resource's own sequential server_scripts load -- which
            happens BEFORE FXServer ever fires 'onResourceStart' for this
            resource at all. No onResourceStart handler, however early it
            is registered, can run before that. A persisted override for
            one of these CANNOT take effect through a restart of this
            resource alone, on any restart, ever, through this mechanism --
            the operator has to edit config.lua's own value directly and
            restart. This file still records the override (for the tablet
            to show what high command asked for, and for forward
            compatibility if that file is ever refactored to check the flag
            live), but every response for one of these says so plainly
            (`configEditRequired = true`, not merely `restartRequired`).
      - A feature with NO server-side registration point at all (a pure
        client-rendered cosmetic/HUD toggle) has nothing this file could
        ever flip regardless of restart -- `tier = 'clientonly'`. Mutating
        Config.Features.X server-side changes nothing for an already-
        connected client, which loaded its own independent copy of
        config.lua at ITS OWN resource start and never re-reads this
        server's in-memory table. Making these genuinely live would need a
        client-side listener this file does not own (see "WHAT THIS FILE
        DOES NOT DO" below) -- reported, not built here.
      - Two features are `tier = 'protected'` and cannot be toggled through
        this system AT ALL, regardless of caller: `HighCommand` and
        `PermissionGrants`. Both gate the very authorization check this
        file's own callbacks depend on (IsHighCommand/HasPermission). Both
        also happen to be genuinely `live` internally (IsHighCommand/
        HasPermission both re-check their own flag on every call, by their
        own files' explicit design) -- but a high-command officer using a
        high-command-gated tool to switch off the high-command gate itself,
        mid-session, is a self-lockout with a MUCH wider blast radius than
        any other entry in this table (every OTHER high-command bypass in
        this resource stops working in the same instant, not just this
        tablet). An operator who genuinely wants either off does so in
        config.lua, on purpose, with a restart -- not from inside the
        system that bypass itself protects.

    THE FULL AUDIT, tier by tier (every entry below was confirmed by
    directly reading the file that registers it, not inferred from its
    name or from this resource's own general "read the flag at the point of
    use" convention alone -- that convention is real and is SPEC.md §3's own
    acceptance criterion, restated at config.lua's Config.Features header,
    but is not universally followed to the letter every file claims; several
    files say so themselves, e.g. server/fetch.lua's own "GATE AT
    REGISTRATION, NOT INSIDE THE HANDLER" comment):

      live       -- XPProgression (server/progression.lua's AwardXP),
                    HandlerPartnership (server/partnership.lua's
                    CheckPartnershipEligibility), BiteAndHold /
                    NonLethalTakedown / PropDragging (server/combat.lua's
                    ValidateCombatRequest, passed the live flag at every
                    request), DeployableKennel (server/kennel.lua, checked
                    inside both RegisterNetEvent handlers), ScentTracking /
                    BloodTracking / GunpowderSniffing (server/tracking.lua;
                    the QUERY side -- findTrackableSource -- re-checks the
                    right flag per trackType on every call; ScentTracking's
                    INPUT side, the ox_inventory drop hook, is registered
                    once at resource-start and is NOT reopened by flipping
                    this back on mid-session -- disclosed per-feature below,
                    not silently folded into "live"), ContrabandAlerts /
                    SearchZones (server/search.lua's searchTarget callback
                    and HandleSearchTarget), K9Inventory
                    (server/inventory.lua's openK9Inventory callback),
                    K9Medkit (server/medkit.lua's useK9Medkit callback),
                    LeashMechanics (server/main.lua's
                    CheckLeashEligibility), BasicBarkSounds /
                    DoorInteraction (server/main.lua's relayBark /
                    relayDoorScratch handlers), CertificationExpiry
                    (server/certifications.lua's GrantCertification checks
                    it live for the primary "does a new grant get an
                    expiry" effect; the courtesy-warning SWEEP THREAD is
                    only started if the flag was already true when
                    certifications.lua loaded -- disclosed per-feature,
                    same reasoning as ScentTracking above), FatigueSystem /
                    MoodSystem / FearStressSystem / DistractionSystem /
                    InjuryLimping (server/wellbeing.lua, each re-checked
                    inside the functions its own tick/relay handlers call),
                    PartnershipTenureBonus (server/tenure.lua's
                    TickPartnershipTenure re-checks all three of
                    HandlerPartnership/XPProgression/PartnershipTenureBonus
                    on every tick, per that file's own "SPEC.md §3... point
                    of use" comment -- but the TICK THREAD ITSELF only
                    starts if all three were already true when tenure.lua
                    loaded, so turning this on when it was off at boot has
                    the same "nothing is polling to notice" gap as
                    ScentTracking's drop hook -- disclosed per-feature).
      onstart    -- AdminAuditCommands (server/admin.lua), BoneSweepDevTool
                    (server/bonetool.lua) -- both register every command
                    inside their own `onResourceStart` handler, and neither
                    handler re-checks the flag inside itself afterward.
      rawtoplevel -- FetchMechanic (server/fetch.lua: "the entire file is
                    inert... while the flag is off", its own words),
                    HandlerDownDefense (server/defense.lua: "this file must
                    never flip it", config.lua's own words, referring to
                    exactly this file-top gate), Recall (server/recall.lua
                    -- the one termination path in this resource, see "A
                    NOTE ON Recall" below), PropAttachments
                    (server/propattachment.lua wraps its entire back half
                    in `if Config.Features.PropAttachments then ... end`),
                    CommandTablet (server/permissions.lua's own two tablet
                    callbacks are registered inside a bare
                    `if Config.Features.CommandTablet == true then ...
                    end` at that file's own top level -- other files may
                    register their own tablet-only surfaces the same way;
                    this file does not attempt to enumerate every one).
      clientonly -- RadialMenu, VehicleEntryExit, AgilityBasicJump,
                    AgilityAdvanced, ThermalVision, NightVision,
                    HealthStaminaHUD, ContrabandScreenFX, AdvancedBarkRadial,
                    ProximityAudioFX, WaterTrackingDecay -- zero occurrences
                    in any server/*.lua file (confirmed by grep before
                    writing this list, not assumed from the name), so there
                    is no server-side enforcement point for this file to
                    touch at all. Listed in ListFeatures' response as
                    `tier = 'clientonly'` so the tablet can grey these out
                    rather than silently omit them.
      protected  -- HighCommand, PermissionGrants -- see above.

    A NOTE ON Recall, specifically, because it is this resource's one
    termination/escape-hatch path and this file's own "no unbounded trap"
    review habit applies to it directly: Recall being `rawtoplevel` does
    NOT make toggling it dangerous in the "traps someone" direction -- if
    it was ON at boot (the shipped default), it stays reachable all session
    regardless of what this file's override says, so a handler can always
    call their K9 off. The risk this file actually guards against is the
    OPPOSITE and much smaller one: an operator who deliberately shipped
    Recall OFF and expects a runtime toggle to turn it on mid-session would
    otherwise be told "done" while nothing changed. SetFeature refuses to
    imply that -- see `configEditRequired` below.

    ======================================================================
    PART 1B -- TUNING. Config.Features.RuntimeFeatureControl.
    An EXPLICIT ALLOWLIST (TUNABLE_REGISTRY below), not "every number in
    config.lua" -- deliberately. Each entry carries a hard [min, max] this
    file refuses to go outside of (never silently clamped to the boundary --
    an out-of-range request is REJECTED with the bounds told back to the
    caller, so a typo'd extra zero is loud, not silently rewritten to
    something else the caller didn't ask for). Three exclusion rules,
    applied while building this list, stated here so the exclusion is a
    decision and not an oversight:
      1. ECONOMY-AFFECTING VALUES ARE NOT TUNABLE AT ALL, UP OR DOWN, FROM
         THIS SURFACE. Every key under Config.XP (award amounts, the
         mint-budget cap referenced by server/progression.lua) and every
         key under Config.HighCommand (maxXpPerGrant, grantCooldownMs) is
         excluded outright -- config.lua's own Config.XPTiers header
         documents eight independent XP-farm shapes this resource has
         already had to close; a UI path that can raise any of those
         numbers is exactly the ninth. This is the "exclude entirely"
         choice the task's own brief offered as an alternative to "cap
         tightly" -- taken here because there is no legitimate high-command
         use case for LOWERING these live either that is worth the
         surface area of also allowing raising them from the same control.
      2. ACCESS-CONTROL-SEMANTIC VALUES ARE EXCLUDED, not because they are
         economy but because live-changing them has a retroactive-feeling
         side effect on real people's access: Config.CertificationExpiryDays
         and Config.CertificationExpiryWarningDays are left out (an
         instant policy change to how long every future grant's clock runs
         is a real decision an operator should make in config.lua, not a
         live dial) -- Config.CertificationExpiryCheckIntervalMs (merely
         how often a courtesy reminder sweep polls, not a policy value) IS
         included.
      3. EVERYTHING INCLUDED BELOW WAS INDIVIDUALLY CONFIRMED READ FRESH AT
         THE POINT OF USE, not captured once as some other file's
         constructor default, by direct code read (server/tracking.lua's
         Config.Tracking.*.searchCooldownMs/relayCooldownMs/maxRange/
         maxAgeSeconds are all read inside a live callback/handler body per
         request, matching that Config block's own header quoting SPEC.md
         §3 verbatim; server/admin.lua's Config.AdminAudit.CommandCooldownMs
         and Config.AdminAudit.MaxResults.* are both read fresh inside each
         command's own handler on every invocation, never captured as a
         NewCooldown constructor default; server/certifications.lua's
         Config.CertificationExpiryCheckIntervalMs is re-read at the top of
         every sweep-thread loop iteration, confirmed by direct read of
         that exact loop). A tunable this file could not confirm this way
         is not on the list -- "restart required" is the safe direction of
         error for a FEATURE toggle this file cannot verify; for a TUNABLE,
         the safe direction is simply not exposing it at all until it is
         confirmed, since a wrong "applied live" claim here is a silent
         no-op with no distinguishing observable symptom the way a feature
         toggle at least prints once (see server/cooldowns.lua's own
         warnedBadCallTimeThreshold backstop) -- there is no equivalent
         backstop for a tuning value quietly not being re-read.

    THE cooldowns.lua FOOTGUN, why this file exists to specifically defend
    against it here: server/cooldowns.lua's IsOnCooldown treats a
    non-positive threshold as PERMANENTLY on, never "no cooldown" (see that
    file's own header). Every *_ms tunable's `min` below is a real positive
    floor for exactly this reason -- 0 is never in range for any of them,
    so SetTunable's own range check (never a bare `> 0`, always the
    registry's own min/max) already refuses it before it could ever reach a
    cooldown tracker. Tested explicitly in tests/runtimecontrol_spec.lua.

    ======================================================================
    PART 2 -- TABLET THEMING. Config.Features.TabletTheming.
    COSMETIC ONLY, STATED PLAINLY: nothing in k9_tablet_theme, nothing this
    file reads from it, and nothing GetTheme/SetTheme/ResetTheme below ever
    return is consulted by any authorization check anywhere in this
    resource. A theme value can change what the tablet LOOKS like; it can
    never change what pressing a button in it actually DOES -- every action
    the tablet offers is, and remains, re-authorized server-side from the
    caller's own live job/grants at the point that action's own callback
    runs, exactly as it was before this file existed. GetTheme deliberately
    has NO authorization check beyond "you are a connected player" -- it is
    read by, and applied for, EVERY viewer, not just high command, matching
    the owner's own "applied for everyone" framing; only SetTheme/ResetTheme
    require the same high-command check as Part 1.

    A SIX-FIELD SURFACE, not a CSS field, because "free-form CSS injection
    from a UI is not a feature worth having" (this task's own words, and
    this file agrees): four named colour slots (primaryColor/accentColor/
    backgroundColor/textColor, each validated as EXACTLY `#RRGGBB` -- see
    IsValidHexColor below, a strict pattern match, not a permissive "looks
    colour-ish" heuristic), one density enum (`comfortable` | `compact` --
    a fixed lookup table, never free text), and one header-title string
    (<=40 chars, VARCHAR(40)-backed, additionally rejected outright if it
    contains any of `< > & " ' \` or a control/CR/LF/TAB byte -- see
    IsSafeHeaderTitle below). That last check is DEFENSE IN DEPTH, not the
    primary control: html/tablet.js's own test suite
    (html/tests/tablet_xss_spec.js, read before writing this file) already
    proves that file renders every dynamic string via `textContent`, never
    `innerHTML` -- html/tests/tablet-dom-stub.js's own innerHTML setter is
    deliberately "trapped" specifically to catch a regression on that
    point. This file's own character-level rejection exists so that a
    theme value which somehow reached a DIFFERENT, less careful renderer
    later (a future companion app, a log viewer, anything else that might
    one day read k9_tablet_theme) still could not carry markup -- belt AND
    suspenders, not one instead of the other.

    BROADCAST ON CHANGE: SetTheme/ResetTheme, on success, additionally
    TriggerClientEvent('qbx_k9unit:client:themeUpdated', -1, theme) so an
    already-open tablet updates without the viewer having to close and
    reopen it -- "applied for everyone" means everyone currently looking at
    one too, not just the next person to open one. THIS FILE DOES NOT
    REGISTER A CLIENT-SIDE HANDLER FOR THAT EVENT -- see "WHAT THIS FILE
    DOES NOT DO" below; that is client/tablet.lua's own owner's call to
    wire up, reported in full in this pass's hand-off note with the exact
    payload shape.

    ======================================================================
    WHAT THIS FILE DOES NOT DO, ON PURPOSE:
      - It does not attempt a synchronous database read at this file's own
        raw top-level (before any AddEventHandler/CreateThread). Every
        existing DB-dependent startup path in this resource
        (server/admin.lua, server/highcommand.lua, server/certifications.lua's
        backfill, server/permissions.lua's backfill) defers its first real
        query into `AddEventHandler('onResourceStart', ...)` -- none of
        them do it at bare file scope. This file follows that same,
        already-proven convention rather than introducing an unprecedented
        pattern this resource has never actually exercised, even though a
        successful raw-top-level read would have let this file's override
        reach `rawtoplevel`-tier files too. The honest, disclosed cost of
        that caution is exactly the `rawtoplevel` tier documented above --
        a real limitation, not hidden by this design choice.
      - It does not push a live Config update to already-connected
        CLIENTS for anything other than the theme broadcast above. A
        client's own copy of config.lua is independent, per-connection,
        Lua state loaded at that client's own resource start; this
        resource has never had a "push a config value to every client"
        mechanism before this file, and inventing a generic one is a
        client/coder-frontend decision, not a server-lens one. Reported as
        a follow-up, not built here.
      - It does not add a new Config.Permissions capability key to
        config.lua (owned by the config owner this pass, not edited here).
        Every authorization check below tries `HasPermission(citizenid,
        'k9.runtimecontrol')` / `HasPermission(citizenid, 'k9.tablettheme')`
        behind the usual `type(HasPermission) == 'function'` guard, which
        today always returns `false` for either key (HasPermission fails
        closed on any key not present in Config.Permissions) -- so
        IsHighCommand alone is what actually authorizes every call right
        now, exactly matching this task's own "high command only" brief,
        with the permission-grant escape hatch activating automatically,
        with zero code change here, the moment those two keys are added.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `NewCooldown` (server/cooldowns.lua) at this file's
      own file-load time -- MUST load after server/cooldowns.lua.
    - THIS FILE calls `IsHighCommand` (server/highcommand.lua) and
      `HasPermission` (server/permissions.lua) at CALLBACK-CALL time only,
      both behind `type(...) == 'function'` guards -- genuine soft
      dependencies; this file may load before either.
    - THIS FILE MUST load before every `onstart`/`rawtoplevel`-tier file
      named above (server/admin.lua, server/bonetool.lua,
      server/fetch.lua, server/defense.lua, server/recall.lua,
      server/propattachment.lua, server/permissions.lua, and in practice
      every other server/*.lua feature file) for the "persisted override
      survives a restart" property described above to hold for the
      `onstart` tier at all. See FXMANIFEST PLACEMENT below for the exact
      request.
    - THIS FILE exposes no resource-global functions -- nothing else in
      this resource needs to call into it; every effect it has on another
      file is via mutating the shared `Config` table those files already
      read, never via a direct function call in either direction.
    - THIS FILE owns four new tables: k9_runtime_feature_overrides,
      k9_runtime_override_audit, k9_tablet_theme, k9_tablet_theme_audit --
      see sql/migrations/0007_create_k9_runtime_control.sql for the exact
      shape and sql/rollback/0007_down.sql for why none of the four are
      ever dropped by this resource's own rollback tooling.

    FXMANIFEST PLACEMENT REQUESTED (server_scripts, not edited here --
    the manifest owner owns this file): insert
    `'server/runtimecontrol.lua',` immediately after `'server/cooldowns.lua',`
    -- i.e. BEFORE `'server/entities.lua'`, `'server/notify.lua'`,
    `'server/highcommand.lua'`, `'server/permissions.lua'`, and every
    other server/*.lua file. This satisfies the one hard load-order
    requirement (after cooldowns.lua, for NewCooldown at this file's own
    load time) and the "loads before every onstart/rawtoplevel file"
    requirement above in one placement -- this file needs nothing from
    entities.lua/notify.lua, so their relative order versus this file does
    not matter.

    LOCALE KEYS THIS FILE NEEDS: none. Every callback below returns a
    structured `{ ok, reason, ... }` table -- outcome tags, never
    player-facing prose -- matching server/permissions.lua's own
    established "no granter-facing toast, the tablet renders its own
    inline feedback from `reason`" precedent (see that file's header). No
    RegisterCommand exists here for a usage string to need translating
    either -- this surface is tablet-only, per the owner's own framing.
]]

-- ======================================================================
-- BASELINE CAPTURE -- must run before ANYTHING below mutates Config.
-- CONFIG_LUA_DEFAULT_FEATURES/_TUNABLES are the exact values config.lua
-- shipped with, on THIS boot, before any override is re-applied -- the
-- "obvious way back to the config.lua default" the task asked for reads
-- from these, never from a second copy of config.lua or a guess.
-- ======================================================================
local CONFIG_LUA_DEFAULT_FEATURES = {}
for name, value in pairs(Config.Features or {}) do
    CONFIG_LUA_DEFAULT_FEATURES[name] = value
end

-- ======================================================================
-- FEATURE REGISTRY -- tier metadata for every Config.Features key this
-- file knows how to reason about. A name present in Config.Features but
-- NOT in this table (a future feature this file's own audit has not yet
-- covered) is treated as tier = 'unaudited' by GetFeatureTier below --
-- refused for SetFeature (fails closed: never toggle what has not been
-- read), but still listed by ListFeatures so the gap is visible rather
-- than silently absent.
-- ======================================================================
local FEATURE_TIERS = {
    -- tier = 'live' -- see header "THE FULL AUDIT" for the exact evidence per entry.
    XPProgression          = { tier = 'live' },
    HandlerPartnership     = { tier = 'live' },
    BiteAndHold            = { tier = 'live' },
    NonLethalTakedown      = { tier = 'live' },
    PropDragging           = { tier = 'live' },
    DeployableKennel       = { tier = 'live' },
    ScentTracking          = { tier = 'live', note = 'Query side (findTrackableSource) is fully live. The ox_inventory drop hook that logs NEW scent sources is only (re-)registered at server start -- turning this on mid-session re-enables searching existing/already-logged sources immediately, but new drops will not be logged as scent sources until this resource restarts.' },
    BloodTracking          = { tier = 'live' },
    GunpowderSniffing      = { tier = 'live' },
    ContrabandAlerts       = { tier = 'live' },
    SearchZones            = { tier = 'live' },
    K9Inventory            = { tier = 'live' },
    K9Medkit               = { tier = 'live' },
    LeashMechanics         = { tier = 'live' },
    BasicBarkSounds        = { tier = 'live' },
    DoorInteraction        = { tier = 'live' },
    CertificationExpiry    = { tier = 'live', note = 'New/renewed grants getting an expiry date works immediately either way. The courtesy expiry-warning sweep thread only starts if this was already true when server/certifications.lua loaded -- turning it on mid-session does not start a sweep that never began; a restart is needed for the warning sweep specifically (grants themselves are unaffected).' },
    FatigueSystem          = { tier = 'live' },
    MoodSystem             = { tier = 'live' },
    FearStressSystem       = { tier = 'live' },
    DistractionSystem      = { tier = 'live' },
    InjuryLimping          = { tier = 'live' },
    PartnershipTenureBonus = { tier = 'live', note = 'The milestone check itself re-verifies HandlerPartnership/XPProgression/PartnershipTenureBonus fresh every tick. The tick thread only starts if all three were already true when server/tenure.lua loaded -- if it was off at boot, turning it on mid-session has nothing polling to notice a milestone until this resource restarts.' },

    -- tier = 'onstart' -- registered inside AddEventHandler('onResourceStart', ...); this file's own override re-application runs first (see FXMANIFEST PLACEMENT), so a persisted override reliably applies on the NEXT restart, never within the current session.
    AdminAuditCommands     = { tier = 'onstart' },
    BoneSweepDevTool       = { tier = 'onstart', note = 'Also requires the qbx_k9unit_enable_bone_dev_tool convar and a boss-rank caller regardless of this flag -- see config.lua\'s own comment on this feature.' },

    -- tier = 'rawtoplevel' -- gated before this resource\'s own onResourceStart ever fires; no restart of THIS resource alone can apply an override -- config.lua itself must be edited.
    FetchMechanic          = { tier = 'rawtoplevel' },
    HandlerDownDefense     = { tier = 'rawtoplevel' },
    Recall                 = { tier = 'rawtoplevel', note = 'This resource\'s one termination/escape-hatch path. If it shipped ON, it stays reachable all session regardless of this file\'s override -- toggling it here can only ever fail to silently turn it ON when it was off, never trap anyone who could already call their K9 off.' },
    PropAttachments        = { tier = 'rawtoplevel' },
    CommandTablet          = { tier = 'rawtoplevel', note = 'Multiple files register their own CommandTablet-gated tablet callbacks this same way (server/permissions.lua confirmed by direct read; others may exist). Turning this off here does not close an already-registered tablet callback anywhere in this resource.' },

    -- tier = 'clientonly' -- zero occurrences in any server/*.lua file (grepped before writing this list); nothing server-side to toggle.
    RadialMenu             = { tier = 'clientonly' },
    VehicleEntryExit       = { tier = 'clientonly' },
    AgilityBasicJump       = { tier = 'clientonly' },
    AgilityAdvanced        = { tier = 'clientonly' },
    ThermalVision          = { tier = 'clientonly' },
    NightVision            = { tier = 'clientonly' },
    HealthStaminaHUD       = { tier = 'clientonly' },
    ContrabandScreenFX     = { tier = 'clientonly' },
    AdvancedBarkRadial     = { tier = 'clientonly' },
    ProximityAudioFX       = { tier = 'clientonly' },
    WaterTrackingDecay     = { tier = 'clientonly' },

    -- tier = 'protected' -- see header for why these two cannot be toggled through this system at all.
    HighCommand            = { tier = 'protected' },
    PermissionGrants       = { tier = 'protected' },

    -- This file's own two flags are deliberately NOT protected -- see
    -- header "THE ENGINE CONSTRAINT" bullet on `protected` for why the
    -- blast radius here is self-contained (losing tablet control over
    -- features/theming, recoverable by a config.lua edit + restart) and
    -- not comparable to losing IsHighCommand/HasPermission resource-wide.
    -- Both are internally self-hosting (this file's own callbacks are
    -- ALWAYS registered, unconditionally, and re-check their own flag
    -- live on every call -- see "SELF-HOSTING" below), so both are `live`.
    RuntimeFeatureControl  = { tier = 'live' },
    TabletTheming          = { tier = 'live' },
}

--- @param name string
--- @return string tier -- 'live' | 'onstart' | 'rawtoplevel' | 'clientonly' | 'protected' | 'unaudited'
local function GetFeatureTier(name)
    local entry = FEATURE_TIERS[name]
    return entry and entry.tier or 'unaudited'
end

--- @param name string
--- @return string? note
local function GetFeatureNote(name)
    local entry = FEATURE_TIERS[name]
    return entry and entry.note or nil
end

-- ======================================================================
-- TUNABLE REGISTRY -- explicit allowlist. See header "PART 1B" for the
-- three exclusion rules this list was built under. `path` navigates the
-- global `Config` table; `integer = true` additionally requires a whole
-- number (never accepted with a fractional part, matching
-- server/highcommand.lua's own IsValidGrantAmount discipline for a
-- different value).
-- ======================================================================
local TUNABLE_REGISTRY = {
    ['LeashMaxDistance']                       = { path = { 'LeashMaxDistance' },                             min = 3.0,   max = 20.0,      integer = false },
    ['CertifyProximityMeters']                 = { path = { 'CertifyProximityMeters' },                       min = 1.0,   max = 15.0,      integer = false },
    ['VehicleInteractMeters']                  = { path = { 'VehicleInteractMeters' },                        min = 1.0,   max = 8.0,       integer = false },

    ['Tracking.Scent.searchCooldownMs']        = { path = { 'Tracking', 'Scent', 'searchCooldownMs' },        min = 1000,  max = 60000,     integer = true },
    ['Tracking.Scent.relayCooldownMs']         = { path = { 'Tracking', 'Scent', 'relayCooldownMs' },         min = 100,   max = 10000,     integer = true },
    ['Tracking.Scent.maxRange']                = { path = { 'Tracking', 'Scent', 'maxRange' },                min = 5.0,   max = 100.0,     integer = false },
    ['Tracking.Scent.maxAgeSeconds']           = { path = { 'Tracking', 'Scent', 'maxAgeSeconds' },           min = 30,    max = 3600,      integer = true },

    ['Tracking.Blood.searchCooldownMs']        = { path = { 'Tracking', 'Blood', 'searchCooldownMs' },        min = 1000,  max = 60000,     integer = true },
    ['Tracking.Blood.relayCooldownMs']         = { path = { 'Tracking', 'Blood', 'relayCooldownMs' },         min = 100,   max = 10000,     integer = true },
    ['Tracking.Blood.maxRange']                = { path = { 'Tracking', 'Blood', 'maxRange' },                min = 5.0,   max = 100.0,     integer = false },
    ['Tracking.Blood.maxAgeSeconds']           = { path = { 'Tracking', 'Blood', 'maxAgeSeconds' },           min = 30,    max = 3600,      integer = true },

    ['Tracking.Gunpowder.searchCooldownMs']    = { path = { 'Tracking', 'Gunpowder', 'searchCooldownMs' },    min = 1000,  max = 60000,     integer = true },
    ['Tracking.Gunpowder.relayCooldownMs']     = { path = { 'Tracking', 'Gunpowder', 'relayCooldownMs' },     min = 100,   max = 10000,     integer = true },
    ['Tracking.Gunpowder.maxRange']            = { path = { 'Tracking', 'Gunpowder', 'maxRange' },            min = 5.0,   max = 100.0,     integer = false },
    ['Tracking.Gunpowder.maxAgeSeconds']       = { path = { 'Tracking', 'Gunpowder', 'maxAgeSeconds' },       min = 30,    max = 3600,      integer = true },

    ['AdminAudit.CommandCooldownMs']           = { path = { 'AdminAudit', 'CommandCooldownMs' },              min = 250,   max = 60000,     integer = true },
    ['AdminAudit.MaxResults.Certifications']   = { path = { 'AdminAudit', 'MaxResults', 'Certifications' },   min = 1,     max = 100,       integer = true },
    ['AdminAudit.MaxResults.Partnerships']     = { path = { 'AdminAudit', 'MaxResults', 'Partnerships' },     min = 1,     max = 100,       integer = true },
    ['AdminAudit.MaxResults.SearchLog']        = { path = { 'AdminAudit', 'MaxResults', 'SearchLog' },        min = 1,     max = 100,       integer = true },

    ['CertificationExpiryCheckIntervalMs']     = { path = { 'CertificationExpiryCheckIntervalMs' },           min = 30000, max = 3600000,   integer = true },
}

--- Navigates a dotted registry `path` against the live `Config` table.
--- @param path table -- array of string keys
--- @return any value, boolean resolvable -- resolvable is false if some intermediate node is missing/not a table
local function GetConfigByPath(path)
    local node = Config
    for i = 1, #path do
        if type(node) ~= 'table' then return nil, false end
        node = node[path[i]]
    end
    return node, true
end

--- @param path table
--- @param value any
--- @return boolean ok
local function SetConfigByPath(path, value)
    local node = Config
    for i = 1, #path - 1 do
        if type(node[path[i]]) ~= 'table' then return false end
        node = node[path[i]]
    end
    node[path[#path]] = value
    return true
end

-- Snapshot of every tunable's config.lua-shipped default, captured before
-- any override below is re-applied -- same "obvious way back" contract as
-- CONFIG_LUA_DEFAULT_FEATURES above.
local CONFIG_LUA_DEFAULT_TUNABLES = {}
for key, entry in pairs(TUNABLE_REGISTRY) do
    local value = GetConfigByPath(entry.path)
    CONFIG_LUA_DEFAULT_TUNABLES[key] = value
end

-- ======================================================================
-- THEME -- see header PART 2. DEFAULT_THEME's four COLOUR fields seed from
-- Config.CommandTablet.branding.theme (the operator's own "starting
-- colours, matched to the shipped logo" -- config.lua's own comment) so a
-- FRESH install with no k9_tablet_theme row yet, and no override ever
-- saved, shows the operator's actual branding immediately rather than a
-- generic placeholder blue that would only ever be replaced once someone
-- opened the tablet's theme tab and pressed Save at least once.
-- CROSS-FILE GAP THIS CLOSES: this file's four colour literals were
-- previously hardcoded independently of config.lua's own
-- branding.theme -- shipped config.lua sets branding.theme to a crimson
-- palette, but a fresh install (no DB row) rendered the OLD placeholder
-- blue below until the real tabletGetTheme response replaced it, since
-- THIS default (not branding.theme) is what CurrentTheme seeds from at
-- boot. The old literals are kept as the FALLBACK-of-fallback (an
-- invalid/missing/malformed branding.theme entry, or no
-- Config.CommandTablet table at all e.g. CommandTablet disabled) --
-- never silently propagating a bad config value into CurrentTheme, same
-- "never trust blindly" posture ValidateFullTheme already applies to a
-- loaded DB row. `density`/`headerTitle` are NOT part of branding.theme
-- (config.lua's own comment: branding.theme is "starting colours" only)
-- and keep their own literal defaults, matching
-- sql/migrations/0007_create_k9_runtime_control.sql's own k9_tablet_theme
-- column DEFAULTs exactly, so "never configured yet" and "explicitly
-- reset" always converge on the same non-colour values.
-- ======================================================================
local FALLBACK_THEME_COLORS = {
    primaryColor    = '#2563eb',
    accentColor     = '#f59e0b',
    backgroundColor = '#111827',
    textColor       = '#f9fafb',
}

--- Narrow, standalone `#RRGGBB` check -- duplicated from IsValidHexColor's
--- own pattern (defined further below in this file) rather than reordered
--- ahead of it, so a config-authored branding colour is validated with the
--- exact same rule a runtime-submitted one is, without restructuring this
--- file's existing top-to-bottom section order for one early call site.
--- @param value any
--- @return boolean
local function IsPlausibleHexColorForBrandingSeed(value)
    return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil
end

--- @param field string -- one of the four DEFAULT_THEME colour keys
--- @return string
local function ResolveBrandingSeedColor(field)
    local branding = type(Config.CommandTablet) == 'table' and Config.CommandTablet.branding
    local brandingTheme = type(branding) == 'table' and branding.theme
    local candidate = type(brandingTheme) == 'table' and brandingTheme[field]
    if IsPlausibleHexColorForBrandingSeed(candidate) then return candidate end
    return FALLBACK_THEME_COLORS[field]
end

local DEFAULT_THEME = {
    primaryColor    = ResolveBrandingSeedColor('primaryColor'),
    accentColor     = ResolveBrandingSeedColor('accentColor'),
    backgroundColor = ResolveBrandingSeedColor('backgroundColor'),
    textColor       = ResolveBrandingSeedColor('textColor'),
    density         = 'comfortable',
    headerTitle     = 'K9 Command Tablet',
}

local VALID_DENSITIES = { comfortable = true, compact = true }

--- Strict `#RRGGBB` match only -- a colour must actually be a colour, per
--- this task's own instruction, not merely "a short string". Rejects a
--- 3-digit shorthand, an `rgb(...)` function, a named colour ('red'), and
--- anything with whitespace -- deliberately narrow.
--- @param value any
--- @return boolean
local function IsValidHexColor(value)
    return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil
end

--- @param value any
--- @return boolean
local function IsValidDensity(value)
    return type(value) == 'string' and VALID_DENSITIES[value] == true
end

--- <=40 chars (matches k9_tablet_theme.header_title's own VARCHAR(40)),
--- non-empty, and rejects every byte that could ever look like markup or a
--- control sequence -- see header PART 2 "A SIX-FIELD SURFACE" for why
--- this is defense-in-depth on top of html/tablet.js's own textContent-only
--- rendering discipline, not a substitute for it.
--- @param value any
--- @return boolean
local function IsSafeHeaderTitle(value)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > 40 then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        -- Reject C0 control bytes and DEL. Bytes >= 0x80 (UTF-8 multibyte
        -- continuation/lead bytes for non-ASCII text) are accepted --
        -- this is a markup/control-character filter, not an ASCII-only
        -- filter.
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

--- Validates a FULL theme table (every field required) against the four
--- checks above. Used by both SetTheme (after merging a partial request
--- onto the current theme -- see that callback) and the boot-time DB
--- read (defense in depth: even a row this file itself wrote is
--- re-validated on read, never trusted blindly).
--- @param theme table
--- @return boolean ok
--- @return string? badField
local function ValidateFullTheme(theme)
    if type(theme) ~= 'table' then return false, 'theme' end
    if not IsValidHexColor(theme.primaryColor) then return false, 'primaryColor' end
    if not IsValidHexColor(theme.accentColor) then return false, 'accentColor' end
    if not IsValidHexColor(theme.backgroundColor) then return false, 'backgroundColor' end
    if not IsValidHexColor(theme.textColor) then return false, 'textColor' end
    if not IsValidDensity(theme.density) then return false, 'density' end
    if not IsSafeHeaderTitle(theme.headerTitle) then return false, 'headerTitle' end
    return true
end

-- Current in-memory theme -- always a FULL, already-validated table.
-- Populated from the DB (or DEFAULT_THEME on a fresh install / failed
-- read) inside the onResourceStart handler below. GetTheme reads this
-- directly -- never a fresh query per viewer, matching this file's own
-- "cosmetic, read-mostly" scope.
local CurrentTheme = {}
for k, v in pairs(DEFAULT_THEME) do CurrentTheme[k] = v end

-- Current in-memory override state -- ActiveOverrides['feature:HighCommand']
-- = { kind = 'feature', value = 'false', updatedBy = '...', updatedAt =
-- '...' }, mirroring k9_runtime_feature_overrides. Populated at boot,
-- kept in sync by SetFeature/SetTunable/ResetFeature/ResetTunable below --
-- ListFeatures/ListTunables read this rather than re-querying the DB on
-- every tablet open.
local ActiveOverrides = {}

-- ======================================================================
-- SHARED HELPERS -- rate limiting, authorization, audit, safe DB access.
-- ======================================================================

-- One shared cooldown instance, keyed by the calling officer's own source,
-- covering every mutating callback in this file (Set/Reset for features,
-- tunables, and theme) -- mirrors server/permissions.lua's
-- PermissionActionCooldown / server/highcommand.lua's
-- HighCommandGrantCooldown shape exactly: one instance per related-action
-- group, anti-fat-finger only (every caller here is already high command
-- or an explicit permission holder, i.e. already trusted -- this guards
-- against a held key or a double-submitted click, not abuse).
local RUNTIME_CONTROL_ACTION_COOLDOWN_MS = 1000
local RuntimeControlActionCooldown = NewCooldown(RUNTIME_CONTROL_ACTION_COOLDOWN_MS)
RuntimeControlActionCooldown.RegisterPlayerDropped()

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- Server-authoritative: may `source` manage runtime feature/tuning
--- overrides right now? Re-resolved fresh on every call, per this task's
--- explicit "high command only, re-resolved server-side per call"
--- instruction -- never cached, never trusts a client claim of authority.
--- @param source number
--- @return boolean, string? citizenid -- citizenid is returned when known, for the caller to use as the audit `changed_by`
local function CanManageRuntimeControl(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.runtimecontrol') == true then
        return true, citizenid
    end
    return false, citizenid
end

--- Same shape as CanManageRuntimeControl, for the theming surface's own
--- capability key -- kept SEPARATE (not reused) so a server could one day
--- grant "may restyle the tablet" without also granting "may switch
--- features on and off", or vice versa, the moment the config owner adds
--- either key to Config.Permissions.
--- @param source number
--- @return boolean, string? citizenid
local function CanManageTabletTheme(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.tablettheme') == true then
        return true, citizenid
    end
    return false, citizenid
end

--- Console log line for EVERY mutating call in this file -- matches
--- server/admin.lua's/server/permissions.lua's own "%s ran %s(%s) -> %s"
--- audit format exactly, per this task's own "AUDITED: who changed what,
--- from what, to what" requirement.
--- @param source number
--- @param action string
--- @param detail string
--- @param outcome string
local function LogAuditInvocation(source, action, detail, outcome)
    local citizenid = ResolveCitizenId(source)
    local whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

--- Fail-closed query wrapper -- pcall around MySQL.query.await, matching
--- server/admin.lua's/server/permissions.lua's own SafeQuery. A failed
--- read returns an empty table, never a raw Lua error.
--- @param sql string
--- @param params table
--- @return table rows
local function SafeQuery(sql, params)
    local ok, rowsOrErr = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] runtimecontrol.lua query failed: %s'):format(tostring(rowsOrErr)))
        return {}
    end
    return rowsOrErr or {}
end

--- pcall-wrapped write helper shared by every mutation below -- returns
--- true/false rather than throwing, and prints on failure. Every write in
--- this file is a plain INSERT/UPDATE/DELETE with `?`-bound parameters
--- only, never a caller-controlled fragment.
--- @param sql string
--- @param params table
--- @return boolean ok
local function SafeWrite(sql, params)
    local ok, err = pcall(MySQL.query.await, sql, params)
    if not ok then
        print(('[qbx_k9unit] runtimecontrol.lua write failed: %s'):format(tostring(err)))
        return false
    end
    return true
end

-- ======================================================================
-- APPLYING AN OVERRIDE TO THE LIVE Config TABLE
-- ======================================================================

--- @param name string
--- @param value boolean
local function ApplyFeatureOverride(name, value)
    if type(Config.Features) == 'table' and Config.Features[name] ~= nil then
        Config.Features[name] = value
    end
end

--- @param key string -- TUNABLE_REGISTRY key
--- @param value number
local function ApplyTunableOverride(key, value)
    local entry = TUNABLE_REGISTRY[key]
    if entry then
        SetConfigByPath(entry.path, value)
    end
end

-- ======================================================================
-- BOOT -- re-apply every persisted override and the persisted theme on
-- top of config.lua's own shipped defaults. Deferred to onResourceStart
-- (not this file's own raw top-level -- see header "WHAT THIS FILE DOES
-- NOT DO") -- registered here, FIRST among this resource's own files
-- (see FXMANIFEST PLACEMENT), so it runs before every onstart-tier
-- file's own onResourceStart handler.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    local overrideRows = SafeQuery('SELECT override_key, kind, value, updated_by, updated_at FROM k9_runtime_feature_overrides', {})
    local appliedCount, skippedCount = 0, 0

    for _, row in ipairs(overrideRows) do
        local applied = false

        if row.kind == 'feature' then
            local name = row.override_key:match('^feature:(.+)$')
            if name and Config.Features and Config.Features[name] ~= nil and GetFeatureTier(name) ~= 'protected' then
                ApplyFeatureOverride(name, row.value == 'true')
                applied = true
            end
        elseif row.kind == 'tuning' then
            local key = row.override_key:match('^tuning:(.+)$')
            local entry = key and TUNABLE_REGISTRY[key]
            if entry then
                local numberValue = tonumber(row.value)
                if numberValue and numberValue >= entry.min and numberValue <= entry.max then
                    ApplyTunableOverride(key, numberValue)
                    applied = true
                end
            end
        end

        if applied then
            appliedCount = appliedCount + 1
            ActiveOverrides[row.override_key] = { kind = row.kind, value = row.value, updatedBy = row.updated_by, updatedAt = row.updated_at }
        else
            skippedCount = skippedCount + 1
            print(('[qbx_k9unit] runtimecontrol.lua: skipped stale/unrecognized override %s (kind=%s, value=%s) -- the underlying feature/tuning key no longer exists or is out of its currently configured range.'):format(tostring(row.override_key), tostring(row.kind), tostring(row.value)))
        end
    end

    local themeRows = SafeQuery('SELECT primary_color, accent_color, background_color, text_color, density, header_title FROM k9_tablet_theme WHERE id = 1', {})
    if themeRows[1] then
        local loaded = {
            primaryColor    = themeRows[1].primary_color,
            accentColor     = themeRows[1].accent_color,
            backgroundColor = themeRows[1].background_color,
            textColor       = themeRows[1].text_color,
            density         = themeRows[1].density,
            headerTitle     = themeRows[1].header_title,
        }
        if ValidateFullTheme(loaded) then
            CurrentTheme = loaded
        else
            print('[qbx_k9unit] runtimecontrol.lua: k9_tablet_theme row failed validation on read -- keeping the built-in default theme this session. Check for a manual/foreign edit to that table.')
        end
    end

    print(('[qbx_k9unit] runtimecontrol.lua: %d override(s) re-applied, %d skipped, at resource start.'):format(appliedCount, skippedCount))
end)

-- ======================================================================
-- PART 1 CALLBACKS -- feature toggles. ALWAYS registered, unconditionally
-- (this file's own "SELF-HOSTING" design -- see header): each re-checks
-- Config.Features.RuntimeFeatureControl live, on every call, exactly like
-- server/highcommand.lua's IsHighCommand re-checks Config.Features.HighCommand.
-- This is deliberate, not an inconsistency with "gate at registration" --
-- a meta-control surface that could lock itself out by being toggled off
-- would be the single worst instance of the failure mode this whole file
-- exists to avoid.
-- ======================================================================

lib.callback.register('qbx_k9unit:server:runtimeListFeatures', function(source)
    local authorized = CanManageRuntimeControl(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    local rows = {}
    for name, currentValue in pairs(Config.Features or {}) do
        local tier = GetFeatureTier(name)
        local overrideKey = 'feature:' .. name
        local override = ActiveOverrides[overrideKey]
        rows[#rows + 1] = {
            name = name,
            currentValue = currentValue,
            configLuaDefault = CONFIG_LUA_DEFAULT_FEATURES[name],
            tier = tier,
            note = GetFeatureNote(name),
            overridden = override ~= nil,
            overriddenBy = override and override.updatedBy or nil,
            overriddenAt = override and override.updatedAt or nil,
            protected = tier == 'protected',
        }
    end
    return { ok = true, features = rows }
end)

lib.callback.register('qbx_k9unit:server:runtimeSetFeature', function(source, name, newValue)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(tostring(name)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(name) ~= 'string' or Config.Features == nil or Config.Features[name] == nil then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(tostring(name)), 'invalid_feature')
        return { ok = false, reason = 'invalid_feature' }
    end

    if type(newValue) ~= 'boolean' then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s value=%s'):format(name, tostring(newValue)), 'invalid_value')
        return { ok = false, reason = 'invalid_value' }
    end

    local tier = GetFeatureTier(name)
    if tier == 'protected' then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(name), 'protected_feature')
        return { ok = false, reason = 'protected_feature' }
    end

    local oldValue = Config.Features[name]
    local overrideKey = 'feature:' .. name
    local valueStr = newValue and 'true' or 'false'

    local wrote = SafeWrite(
        'INSERT INTO k9_runtime_feature_overrides (override_key, kind, value, updated_by) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
        { overrideKey, 'feature', valueStr, citizenid or 'unknown' }
    )
    if not wrote then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s value=%s'):format(name, valueStr), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    SafeWrite(
        'INSERT INTO k9_runtime_override_audit (override_key, kind, old_value, new_value, changed_by) VALUES (?, ?, ?, ?, ?)',
        { overrideKey, 'feature', tostring(oldValue), valueStr, citizenid or 'unknown' }
    )

    ApplyFeatureOverride(name, newValue)
    ActiveOverrides[overrideKey] = { kind = 'feature', value = valueStr, updatedBy = citizenid, updatedAt = os.date('%Y-%m-%d %H:%M:%S') }

    LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s old=%s new=%s tier=%s'):format(name, tostring(oldValue), valueStr, tier), 'ok')

    if tier == 'live' then
        return { ok = true, appliedLive = true, restartRequired = false, tier = tier }
    elseif tier == 'onstart' then
        return { ok = true, appliedLive = false, restartRequired = true, tier = tier, note = 'This feature only re-checks this flag at server start. Saved -- it will take effect after the next resource restart, but nothing has changed for players on this session.' }
    elseif tier == 'rawtoplevel' then
        return { ok = true, appliedLive = false, restartRequired = true, configEditRequired = true, tier = tier, note = 'This feature is gated before this resource finishes starting. A restart of THIS resource alone is not enough -- Config.Features.' .. name .. ' must also be changed in config.lua for this to take effect.' }
    else -- 'clientonly' or 'unaudited'
        return { ok = true, appliedLive = false, restartRequired = true, tier = tier, note = 'No confirmed server-side enforcement point for this feature -- this value is saved, but this file cannot confirm it will have any live effect.' }
    end
end)

lib.callback.register('qbx_k9unit:server:runtimeResetFeature', function(source, name)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeResetFeature', ('name=%s'):format(tostring(name)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(name) ~= 'string' or CONFIG_LUA_DEFAULT_FEATURES[name] == nil then
        return { ok = false, reason = 'invalid_feature' }
    end

    local overrideKey = 'feature:' .. name
    local oldValue = Config.Features[name]
    local defaultValue = CONFIG_LUA_DEFAULT_FEATURES[name]

    SafeWrite('DELETE FROM k9_runtime_feature_overrides WHERE override_key = ?', { overrideKey })
    SafeWrite(
        'INSERT INTO k9_runtime_override_audit (override_key, kind, old_value, new_value, changed_by) VALUES (?, ?, ?, NULL, ?)',
        { overrideKey, 'feature', tostring(oldValue), citizenid or 'unknown' }
    )

    ApplyFeatureOverride(name, defaultValue)
    ActiveOverrides[overrideKey] = nil

    LogAuditInvocation(source, 'runtimeResetFeature', ('name=%s restored=%s'):format(name, tostring(defaultValue)), 'ok')
    return { ok = true, value = defaultValue, restartRequired = false }
end)

-- ======================================================================
-- PART 1B CALLBACKS -- tuning. Same self-hosting/always-registered design
-- as the feature callbacks above.
-- ======================================================================

lib.callback.register('qbx_k9unit:server:runtimeListTunables', function(source)
    if not CanManageRuntimeControl(source) then return { ok = false, reason = 'denied' } end

    local rows = {}
    for key, entry in pairs(TUNABLE_REGISTRY) do
        local currentValue = GetConfigByPath(entry.path)
        local overrideKey = 'tuning:' .. key
        local override = ActiveOverrides[overrideKey]
        rows[#rows + 1] = {
            key = key,
            currentValue = currentValue,
            configLuaDefault = CONFIG_LUA_DEFAULT_TUNABLES[key],
            min = entry.min,
            max = entry.max,
            integer = entry.integer,
            overridden = override ~= nil,
            overriddenBy = override and override.updatedBy or nil,
            overriddenAt = override and override.updatedAt or nil,
        }
    end
    return { ok = true, tunables = rows }
end)

lib.callback.register('qbx_k9unit:server:runtimeSetTunable', function(source, key, newValue)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s'):format(tostring(key)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    local entry = type(key) == 'string' and TUNABLE_REGISTRY[key] or nil
    if not entry then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s'):format(tostring(key)), 'invalid_key')
        return { ok = false, reason = 'invalid_key' }
    end

    -- FAIL CLOSED, exhaustively -- never a bare `> 0`. Rejects nil,
    -- non-number, NaN (`newValue == newValue` is Lua's standard NaN test --
    -- see server/cooldowns.lua's own IsValidThreshold for why `> 0` alone
    -- does not catch NaN), and infinities, on top of the actual
    -- [min, max] range this task asked for. This is the "refuse anything
    -- outside a sane range" requirement -- values outside [min, max] are
    -- REJECTED, never silently coerced to the nearest boundary; the
    -- caller is told the exact bounds so a typo is loud, not silently
    -- rewritten into a different, unrequested number.
    local isFiniteNumber = type(newValue) == 'number' and newValue == newValue and newValue > -math.huge and newValue < math.huge
    if not isFiniteNumber or newValue < entry.min or newValue > entry.max then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s value=%s'):format(key, tostring(newValue)), 'out_of_range')
        return { ok = false, reason = 'out_of_range', min = entry.min, max = entry.max }
    end

    if entry.integer and newValue ~= math.floor(newValue) then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s value=%s'):format(key, tostring(newValue)), 'not_integer')
        return { ok = false, reason = 'not_integer' }
    end

    local oldValue = GetConfigByPath(entry.path)
    local overrideKey = 'tuning:' .. key
    local valueStr = tostring(newValue)

    local wrote = SafeWrite(
        'INSERT INTO k9_runtime_feature_overrides (override_key, kind, value, updated_by) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
        { overrideKey, 'tuning', valueStr, citizenid or 'unknown' }
    )
    if not wrote then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s value=%s'):format(key, valueStr), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    SafeWrite(
        'INSERT INTO k9_runtime_override_audit (override_key, kind, old_value, new_value, changed_by) VALUES (?, ?, ?, ?, ?)',
        { overrideKey, 'tuning', tostring(oldValue), valueStr, citizenid or 'unknown' }
    )

    ApplyTunableOverride(key, newValue)
    ActiveOverrides[overrideKey] = { kind = 'tuning', value = valueStr, updatedBy = citizenid, updatedAt = os.date('%Y-%m-%d %H:%M:%S') }

    LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s old=%s new=%s'):format(key, tostring(oldValue), valueStr), 'ok')
    return { ok = true, appliedLive = true, restartRequired = false, value = newValue }
end)

lib.callback.register('qbx_k9unit:server:runtimeResetTunable', function(source, key)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeResetTunable', ('key=%s'):format(tostring(key)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    local entry = type(key) == 'string' and TUNABLE_REGISTRY[key] or nil
    if not entry then
        return { ok = false, reason = 'invalid_key' }
    end

    local overrideKey = 'tuning:' .. key
    local oldValue = GetConfigByPath(entry.path)
    local defaultValue = CONFIG_LUA_DEFAULT_TUNABLES[key]

    SafeWrite('DELETE FROM k9_runtime_feature_overrides WHERE override_key = ?', { overrideKey })
    SafeWrite(
        'INSERT INTO k9_runtime_override_audit (override_key, kind, old_value, new_value, changed_by) VALUES (?, ?, ?, NULL, ?)',
        { overrideKey, 'tuning', tostring(oldValue), citizenid or 'unknown' }
    )

    ApplyTunableOverride(key, defaultValue)
    ActiveOverrides[overrideKey] = nil

    LogAuditInvocation(source, 'runtimeResetTunable', ('key=%s restored=%s'):format(key, tostring(defaultValue)), 'ok')
    return { ok = true, value = defaultValue, restartRequired = false }
end)

-- ======================================================================
-- PART 2 CALLBACKS -- tablet theming. GetTheme is intentionally open to
-- ANY connected caller (no CanManageTabletTheme check) -- see header
-- PART 2 for why: this is read-and-applied for every viewer, not just
-- high command. Set/Reset require CanManageTabletTheme, exactly like
-- Part 1's mutations require CanManageRuntimeControl.
-- ======================================================================

lib.callback.register('qbx_k9unit:server:tabletGetTheme', function(source)
    if type(source) ~= 'number' or source <= 0 then
        return { ok = false, reason = 'invalid_source' }
    end
    local theme = {}
    for k, v in pairs(CurrentTheme) do theme[k] = v end
    return { ok = true, theme = theme }
end)

lib.callback.register('qbx_k9unit:server:tabletSetTheme', function(source, partialTheme)
    if not (Config.Features and Config.Features.TabletTheming == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageTabletTheme(source)
    if not authorized then
        LogAuditInvocation(source, 'tabletSetTheme', 'n/a', 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(partialTheme) ~= 'table' then
        LogAuditInvocation(source, 'tabletSetTheme', 'n/a', 'invalid_payload')
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Merge the caller-supplied partial theme onto the CURRENT theme (never
    -- onto an empty table -- an admin changing only headerTitle must not
    -- accidentally blank every colour slot back to Lua's `nil`), THEN
    -- validate the full, merged result as one unit -- every field is
    -- re-validated even if unchanged this call, so a field that was
    -- somehow already invalid (should not be reachable, since every write
    -- path validates before persisting) can never silently persist through
    -- an unrelated edit.
    local merged = {}
    for k, v in pairs(CurrentTheme) do merged[k] = v end
    for _, field in ipairs({ 'primaryColor', 'accentColor', 'backgroundColor', 'textColor', 'density', 'headerTitle' }) do
        if partialTheme[field] ~= nil then merged[field] = partialTheme[field] end
    end

    local valid, badField = ValidateFullTheme(merged)
    if not valid then
        LogAuditInvocation(source, 'tabletSetTheme', ('field=%s'):format(tostring(badField)), 'invalid_field')
        return { ok = false, reason = 'invalid_field', field = badField }
    end

    local wrote = SafeWrite(
        'INSERT INTO k9_tablet_theme (id, primary_color, accent_color, background_color, text_color, density, header_title, updated_by) ' ..
        'VALUES (1, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE primary_color = VALUES(primary_color), accent_color = VALUES(accent_color), ' ..
        'background_color = VALUES(background_color), text_color = VALUES(text_color), density = VALUES(density), ' ..
        'header_title = VALUES(header_title), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
        { merged.primaryColor, merged.accentColor, merged.backgroundColor, merged.textColor, merged.density, merged.headerTitle, citizenid or 'unknown' }
    )
    if not wrote then
        LogAuditInvocation(source, 'tabletSetTheme', 'n/a', 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    SafeWrite(
        'INSERT INTO k9_tablet_theme_audit (primary_color, accent_color, background_color, text_color, density, header_title, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { merged.primaryColor, merged.accentColor, merged.backgroundColor, merged.textColor, merged.density, merged.headerTitle, citizenid or 'unknown' }
    )

    CurrentTheme = merged
    LogAuditInvocation(source, 'tabletSetTheme', ('primary=%s accent=%s background=%s text=%s density=%s header=%q'):format(
        merged.primaryColor, merged.accentColor, merged.backgroundColor, merged.textColor, merged.density, merged.headerTitle
    ), 'ok')

    local broadcastTheme = {}
    for k, v in pairs(merged) do broadcastTheme[k] = v end
    TriggerClientEvent('qbx_k9unit:client:themeUpdated', -1, broadcastTheme)

    return { ok = true, theme = broadcastTheme }
end)

lib.callback.register('qbx_k9unit:server:tabletResetTheme', function(source)
    if not (Config.Features and Config.Features.TabletTheming == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageTabletTheme(source)
    if not authorized then
        LogAuditInvocation(source, 'tabletResetTheme', 'n/a', 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    local reset = {}
    for k, v in pairs(DEFAULT_THEME) do reset[k] = v end

    local wrote = SafeWrite(
        'INSERT INTO k9_tablet_theme (id, primary_color, accent_color, background_color, text_color, density, header_title, updated_by) ' ..
        'VALUES (1, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE primary_color = VALUES(primary_color), accent_color = VALUES(accent_color), ' ..
        'background_color = VALUES(background_color), text_color = VALUES(text_color), density = VALUES(density), ' ..
        'header_title = VALUES(header_title), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
        { reset.primaryColor, reset.accentColor, reset.backgroundColor, reset.textColor, reset.density, reset.headerTitle, citizenid or 'unknown' }
    )
    if not wrote then
        LogAuditInvocation(source, 'tabletResetTheme', 'n/a', 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    SafeWrite(
        'INSERT INTO k9_tablet_theme_audit (primary_color, accent_color, background_color, text_color, density, header_title, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { reset.primaryColor, reset.accentColor, reset.backgroundColor, reset.textColor, reset.density, reset.headerTitle, citizenid or 'unknown' }
    )

    CurrentTheme = reset
    LogAuditInvocation(source, 'tabletResetTheme', 'n/a', 'ok')

    local broadcastTheme = {}
    for k, v in pairs(reset) do broadcastTheme[k] = v end
    TriggerClientEvent('qbx_k9unit:client:themeUpdated', -1, broadcastTheme)

    return { ok = true, theme = broadcastTheme }
end)
