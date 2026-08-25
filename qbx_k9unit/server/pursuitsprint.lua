--[[
    qbx_k9unit/server/pursuitsprint.lua

    K9_IDEAS.md §5 ("Pursuit sprint -- a short burst of 'the dog is
    genuinely faster than you'"). Server half of a short, cooldown-gated
    speed burst for a certified K9 actively chasing a player this server's
    own system has already flagged wanted/suspect. Client half:
    client/pursuitsprint.lua (that file's own header is the authoritative
    contract for the client-side application/expiry of the effect itself --
    read it together with this one).

    Explicitly NOT building "crowd-control barking" (K9_IDEAS.md's own
    not-recommended section) -- nothing here or in client/pursuitsprint.lua
    touches any ped other than the requesting K9's own, and nothing here
    applies any effect to the target at all (see "WHAT THIS FILE DOES NOT
    DO" below).

    ======================================================================
    THE BALANCE PROBLEM -- STATED EXPLICITLY, PER THIS TASK'S OWN DEMAND.
    This is a PvP-affecting buff (it changes whether a K9 can catch a
    fleeing player), so the exact numbers matter more than the idea.

    Config.PursuitSprint.speedMultiplier / durationMs / cooldownMs are the
    three load-bearing numbers. With this pass's proposed defaults
    (speedMultiplier = 1.4, durationMs = 5000, cooldownMs = 45000):

      WORST CASE, STATED PRECISELY: for up to 5 seconds, once every 45
      seconds (a ~11% duty cycle -- this is NOT an infinite chase-ender),
      a certified K9 actively chasing a server-flagged suspect within
      Config.PursuitSprint.requestRangeMeters moves at up to its own
      BASELINE move rate multiplied by up to 2.0 -- not by
      speedMultiplier alone, however large a server operator sets it, and
      NOT scaled by however high a server operator sets ANY
      Config.Peds[n].speedMultiplier ("the fastest configured ped," per
      this task's own instruction).

      WHY 2.0 IS THE REAL CEILING, NOT 1.4: this feature contributes
      exactly ONE more multiplicative input
      (K9MoveRateModifiers.pursuitSprint) into client/movement.lua's
      ALREADY-SHIPPED, ALREADY-REVIEWED move-rate composer
      (RecomputeK9MoveRate), which clamps the PRODUCT of every active
      modifier (breed, XP tier, wellbeing, this feature, ...) to the
      range [0.1, 2.0] -- see that file's own "CLAMP RANGE [0.1, 2.0], AND
      WHY" header block. This feature does not raise, lower, or bypass
      that ceiling in any way; it is simply one more number multiplied
      into a product that was already bounded before this feature
      existed. That means the "fastest configured ped" concern this task
      named explicitly is ALREADY closed by infrastructure that predates
      this feature -- no matter how aggressively an operator sets a
      per-breed speedMultiplier, or how high XP tiers push their own
      multiplier, the applied result during a burst can never exceed
      2.0x the K9's own un-boosted baseline.

      REALISTIC (non-adversarial) CASE: with the shipped roster (no
      operator-configured Config.Peds[n].speedMultiplier, so breed = 1.0
      for every entry today) and an Elite-tier K9 (Config.XPTiers'
      highest shipped speedMultiplier, 1.15), one burst applies
      1.15 * 1.4 = 1.61x -- comfortably under the 2.0 ceiling, so the
      ceiling is a defensive backstop against a MISCONFIGURED server, not
      the number this feature is tuned to hit in the common case.

      NO UNBOUNDED TRAP: cooldownMs is validated at RESOURCE START (see
      "COOLDOWN FOOTGUN" below) so it can never silently become "always
      denied", and the burst itself always ends via a client-local timer
      that is NEVER gated on any access/certification re-check (see
      client/pursuitsprint.lua's own header) -- a K9 that loses
      certification, dies, or has this resource restart mid-burst still
      has the multiplier reset, deterministically, within
      Config.PursuitSprint.durationMs of grant.

    ANY PED: this file's only role/authorization check is HasK9Access(src)
    -- a certification/permission check with NO ped-model component at all
    (server/certifications.lua's own header: "ROLE/MODEL DECOUPLING" --
    HasK9Access never reads GetEntityModel). This file never calls
    GetEntityModel, IsEntityModelK9, or IsOwnModelK9 anywhere -- confirmed
    by re-reading this file before shipping it. A custom streamed ped, an
    unlisted model, or a human model all pass this gate identically, exactly
    as this task required.

    XP: ZERO, by construction, same decision and same reasoning
    server/training.lua's own "THE XP DECISION" header already applies to a
    much LOWER-friction action than this one. This file contains NO call to
    AwardXP or AwardXPDirect, and reads no field of Config.XP -- verifiable
    by grep. Arithmetic, stated explicitly per this task's own demand: even
    the SHORTEST defensible cooldown for this mechanic (cooldownMs, 45s)
    allows at most 3600000 / 45000 = 80 activations/hour per citizenid: at
    a mere 5 XP/activation that is +400 XP/hr on top of
    server/progression.lua's already-tuned, already-fought-for 3,600 XP/hr
    shared ceiling (server/progression.lua's own EIGHTH-XP-FARM-FIX
    section) -- for an action that requires nothing but standing near a
    single cooperating "wanted" player and pressing a key, dramatically
    LESS real police work than any of the four mechanics that ceiling was
    sized against. Zero is the only defensible answer.

    ======================================================================
    WHAT THIS FILE DOES NOT DO, stated explicitly per the two things this
    task named as out of scope:
      - Never applies any effect, speed-related or otherwise, to the
        TARGET's own ped or client. The only ped this feature ever changes
        the move rate of is the REQUESTING K9's own -- client/movement.lua's
        move-rate composer is explicitly, permanently hard-gated to
        `IsOwnModelK9()`, i.e. the calling client's OWN currently-controlled
        ped, never an arbitrary target (see that file's own "SCOPE,
        CONFIRMED" header block). This file only ever tells the REQUESTING
        K9's own client "you are cleared to boost yourself"; the target
        never receives any event, message, or effect from this file at all.
      - Not "crowd-control barking" (K9_IDEAS.md's not-recommended idea) --
        no bark, no lunge, no effect on a bystander, no effect on anyone who
        did not opt into being the one specific suspect being chased.

    ======================================================================
    EVENT CONTRACT (agreed with coder-backend before landing -- see this
    pass's own report for the exact message sent):
      Client -> Server:
        'qbx_k9unit:server:requestPursuitSprint' (targetNetId: number)
          -- targetNetId is the K9's own client's best-effort candidate
          -- pick (client/pursuitsprint.lua's FindNearestPursuitTarget),
          -- NEVER trusted beyond "which entity to re-resolve and
          -- re-validate from scratch" -- see ValidateAndConsumePursuitSprintRequest
          -- below for the full, independent, server-side re-derivation
          -- (role, block/grant, live proximity, player-vs-NPC, wanted
          -- status, cooldown).
      Server -> Client:
        'qbx_k9unit:client:pursuitSprintGranted' ()
          -- NO PAYLOAD. Config.PursuitSprint.speedMultiplier/durationMs are
          -- shared_scripts config, already identical on both sides -- this
          -- event is purely "you are cleared, right now", not a value
          -- carrier. See client/pursuitsprint.lua's own header for why a
          -- payload was deliberately not added here.
      Denial is NEVER a dedicated client event -- exactly like
      server/combat.lua's own ValidateCombatRequest callers, a rejected
      request gets a single NotifyPlayer(src, ..., 'error') call and
      nothing else. There is no 'qbx_k9unit:client:pursuitSprintDenied'
      event; do not add one without updating this comment and
      client/pursuitsprint.lua's own header together.

    ======================================================================
    COOLDOWN FOOTGUN (server/cooldowns.lua's own documented failure class)
    -- UPDATED a later pass (QA sandbox repro; see cooldowns.lua's header
    ADDENDUM for the full incident): this section used to say
    Config.PursuitSprint.cooldownMs was asserted positive BEFORE ever
    reaching NewCooldown below, specifically so a bad value would hard-ERROR
    at resource start with a clearer, field-naming message than
    cooldowns.lua's own generic AssertValidDefaultThreshold would give. That
    reasoning held for the SYMPTOM (a bad value must never silently mean
    "no cooldown") but missed the MECHANISM: `error()` thrown from either
    that assert OR from AssertValidDefaultThreshold aborts THIS FILE's own
    load from that line onward, same as QA proved concretely against
    server/combat.lua. This file has no termination path of its own to
    strand, but there is no reason to accept "the entire PursuitSprint
    feature silently stops registering its one net event" when "one
    cooldown falls back to a safe built-in value, loudly, and the feature
    keeps working" is available for free -- consistency with every other
    cooldown call site in this resource is itself worth having, not just
    this file's own narrower blast radius. The old assert immediately
    before NewCooldown below is REPLACED with
    ResolveConfiguredThresholdMs (server/cooldowns.lua) -- same exact-field
    naming in the printed message, clamp-and-warn instead of error-and-abort.
    A non-positive Config.PursuitSprint.cooldownMs value still can never
    mean "unlimited" -- IsOnCooldown's own fail-closed handling makes that
    structurally impossible regardless of how the threshold got here -- it
    now means "PursuitSprint uses its shipped default cooldown until the
    config is fixed" instead of "PursuitSprint's net event was never
    registered at all."

    ======================================================================
    PER-PERSON FEATURE CONTROL (Config.FeatureControl.RequireGrant --
    reported to main to add 'PursuitSprint = true' alongside the four
    existing entries, matching their exact shape). Implements the FULL
    4-step resolution config.lua's own header documents (step 1,
    Config.Features.PursuitSprint, is checked first, below, before this
    function is ever reached):
      2. an explicit block.PursuitSprint grant -> DENY
      3. PursuitSprint listed in RequireGrant -> ALLOW only with an active
         feature.PursuitSprint grant
      4. otherwise -> ALLOW
    HONEST DISCLOSURE, found while building this and reported separately to
    coder-security/coder-backend/main (not fixed here -- server/permissions.lua
    is not a file this pass owns): server/permissions.lua's own
    IsValidPermissionKey only accepts a key already present in
    Config.Permissions, and NEITHER Config.Permissions NOR any code path in
    server/combat.lua or server/admin.lua currently defines or consults a
    'feature.<Name>'/'block.<Name>' key for ANY of the four EXISTING
    RequireGrant entries (BiteAndHold/NonLethalTakedown/PropDragging/
    AdminAuditCommands) -- confirmed by reading both files; the grep for
    'feature.'/'block.' inside either returns nothing. This means, as of
    this pass, this exact 4-step resolution is not enforced anywhere else in
    this codebase for the features that document it, even though
    config.lua's own Config.FeatureControl header describes it as already
    real. This file's own implementation below is written to be CORRECT
    and to FAIL CLOSED against today's actual code (a citizenid with no
    valid 'feature.PursuitSprint' key can never pass HasPermission, since
    IsValidPermissionKey rejects the key shape entirely today -- so this
    resolves to permanently DENIED, not permanently allowed, until
    Config.Permissions gains 'feature.PursuitSprint'/'block.PursuitSprint'
    entries) rather than silently matching the other four's current
    (undocumented, unintended) "grant is never actually checked" behavior.
    Requested from main in the same pass as this file's own config
    additions: add 'feature.PursuitSprint'/'block.PursuitSprint' (and,
    optionally, the four pre-existing pairs this finding also applies to)
    to Config.Permissions with the same {label, description} shape as the
    four existing k9.* entries -- once that lands, high command's existing,
    already-wired tablet:grantFeature/blockFeature NUI callbacks
    (client/tablet.lua) start working for this feature with no further code
    change anywhere.
    ======================================================================
]]

if not Config.Features.PursuitSprint then return end

-- ======================================================================
-- CONFIG SHAPE ASSERTS -- fail loudly at resource start, never silently,
-- mirrors client/agility.lua's own Config.Combat.AgilityAdvanced.detectionMethod
-- assert precedent. Deliberately placed AFTER the feature-flag gate above
-- (same convention agility.lua follows): a server that never turns this
-- feature on is never affected by config.lua not yet having this block.
-- ======================================================================
assert(type(Config.PursuitSprint) == 'table',
    "qbx_k9unit: Config.Features.PursuitSprint is true but Config.PursuitSprint is missing from config.lua. " ..
    "Add the settings table (speedMultiplier/durationMs/cooldownMs/requestRangeMeters) before enabling this feature.")

assert(type(Config.PursuitSprint.speedMultiplier) == 'number' and Config.PursuitSprint.speedMultiplier > 0,
    "qbx_k9unit: Config.PursuitSprint.speedMultiplier must be a positive number.")

assert(type(Config.PursuitSprint.durationMs) == 'number' and Config.PursuitSprint.durationMs > 0,
    "qbx_k9unit: Config.PursuitSprint.durationMs must be a positive number of milliseconds.")

assert(type(Config.PursuitSprint.requestRangeMeters) == 'number' and Config.PursuitSprint.requestRangeMeters > 0,
    "qbx_k9unit: Config.PursuitSprint.requestRangeMeters must be a positive number of meters.")

-- See this file's own header "COOLDOWN FOOTGUN" -- REPLACED this pass (QA
-- sandbox repro): this used to be its own `assert`, hard-erroring on a
-- non-positive Config.PursuitSprint.cooldownMs with a field-specific
-- message. ResolveConfiguredThresholdMs (server/cooldowns.lua) below gives
-- the same exact-field-naming diagnostic without erroring -- see
-- cooldowns.lua's header ADDENDUM and this file's own header for the full
-- reasoning on why clamp-and-warn is preferred to error-and-abort here too,
-- not just at the call sites that risk stranding a termination path.

-- Per-K9 (keyed by src) cooldown -- hard file-load-time dependency on
-- server/cooldowns.lua (NewCooldown), same requirement every other
-- consumer in this resource's fxmanifest.lua already states. See this
-- file's report to main: server/pursuitsprint.lua must load AFTER
-- server/cooldowns.lua; no other load-order requirement (every other
-- cross-file call below is reached only from inside a deferred
-- RegisterNetEvent handler body, resolved at call time, after every
-- server_scripts file has already loaded -- same convention
-- server/combat.lua's own fxmanifest.lua comment documents for its own
-- soft dependencies).
local PursuitSprintCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.PursuitSprint.cooldownMs, 45000, 'Config.PursuitSprint.cooldownMs'))
PursuitSprintCooldown.RegisterPlayerDropped()

-- ======================================================================
-- REJECT MESSAGES -- mirrors server/combat.lua's own COMBAT_REJECT_MESSAGES
-- table shape exactly (a locale-backed map from an internal reason string
-- to player-facing copy), NOT reused directly from that file since
-- COMBAT_REJECT_MESSAGES is a file-local table there and its own reason
-- vocabulary (already_engaged/hesitating/distracted/target_dead/
-- already_held/...) mostly does not apply to this mechanic.
-- ======================================================================
local PURSUIT_SPRINT_REJECT_MESSAGES = {
    feature_disabled   = locale('pursuitsprint.denied_feature_disabled'),
    invalid_target     = locale('pursuitsprint.denied_invalid_target'),
    no_access          = locale('pursuitsprint.denied_no_access'),
    blocked            = locale('pursuitsprint.denied_blocked'),
    grant_required     = locale('pursuitsprint.denied_not_granted'),
    self_target        = locale('pursuitsprint.denied_self_target'),
    target_not_player  = locale('pursuitsprint.denied_target_not_player'),
    too_far            = locale('pursuitsprint.denied_too_far'),
    not_wanted         = locale('pursuitsprint.denied_not_wanted'),
    on_cooldown        = locale('pursuitsprint.denied_on_cooldown'),
}

--- @param reason string
--- @return string
local function PursuitSprintRejectMessage(reason)
    return PURSUIT_SPRINT_REJECT_MESSAGES[reason] or locale('pursuitsprint.denied_fallback')
end

-- ======================================================================
-- WANTED/SUSPECT ELIGIBILITY -- deliberately reuses the SAME config fields
-- server/combat.lua's own (file-local, unreachable from here)
-- IsPlayerWantedEligible already reads (Config.Combat.RequireWantedStatus /
-- Config.Combat.WantedStatusCheckOverride), so this feature's notion of
-- "a suspect this server's own system has already flagged" is byte-for-byte
-- the SAME flag combat already uses for BiteAndHold/NonLethalTakedown, not
-- a second, divergent "wanted" concept. Duplicated rather than shared
-- because server/combat.lua's own copy is a `local function` and this pass
-- does not own that file -- flagged to coder-backend/coder-architect as a
-- natural extraction (a resource-global IsPlayerWantedEligible in, say,
-- server/entities.lua or a new shared file) for a future consolidation
-- pass, same shape as this codebase's own precedent for
-- ResolveConnectedPlayerFromPed (REFACTOR_ROADMAP.md item 2b, "extracted
-- from three independent, byte-identical hand-written copies").
-- Defensively reads Config.Combat via `type(...) == 'table'` since that
-- table is owned by a concurrently-edited config.lua this pass does not
-- control.
--- @param targetSrc number
--- @return boolean eligible
local function IsPursuitTargetWantedEligible(targetSrc)
    local combatCfg = Config.Combat
    if type(combatCfg) ~= 'table' or not combatCfg.RequireWantedStatus then
        return true
    end

    local override = combatCfg.WantedStatusCheckOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, targetSrc)
        if not ok then
            print(('[qbx_k9unit] pursuitsprint.lua: Config.Combat.WantedStatusCheckOverride errored for source %s: %s -- failing closed (target treated as NOT eligible)'):format(targetSrc, tostring(result)))
            return false
        end
        return result == true
    end

    local player = exports.qbx_core:GetPlayer(targetSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) ~= 'table' then return false end
    return metadata.wanted == true or metadata.iswanted == true
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- see this file's own header
-- "PER-PERSON FEATURE CONTROL" block for the full disclosure of today's
-- Config.Permissions gap this depends on to become actually grantable.
-- Implements config.lua's documented 4-step resolution, steps 2-4 (step 1,
-- Config.Features.PursuitSprint, is already checked by this file's
-- top-of-file gate before this function can ever be reached).
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsPursuitSprintPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention
    -- (`type(...) == 'function'`) -- server/permissions.lua may be absent
    -- from an install, or Config.Features.PermissionGrants may be off;
    -- HasPermission itself already returns false in either case. When it
    -- is entirely absent, step 2 (below) simply cannot fire -- nobody could
    -- ever hold a block -- and step 3 further down still fails CLOSED on a
    -- grant this resource is structurally unable to check.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.PursuitSprint') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.PursuitSprint == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.PursuitSprint') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

-- ======================================================================
-- REQUEST HANDLER
-- ======================================================================
RegisterNetEvent('qbx_k9unit:server:requestPursuitSprint', function(targetNetId)
    local src = source

    if type(targetNetId) ~= 'number' then
        NotifyPlayer(src, PursuitSprintRejectMessage('invalid_target'), 'error')
        return
    end

    if not HasK9Access(src) then
        NotifyPlayer(src, PursuitSprintRejectMessage('no_access'), 'error')
        return
    end

    local k9Player = exports.qbx_core:GetPlayer(src)
    local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
    if not k9Citizenid or not IsPursuitSprintPermittedForCitizenId(k9Citizenid) then
        -- Distinguish "explicitly blocked" from "grant required but not
        -- held" in the log only (LogAuditInvocation-style detail is out of
        -- scope for this file -- server/admin.lua's own audit surface is
        -- the read side for k9_permissions activity); the PLAYER-FACING
        -- message is deliberately the SAME generic "not granted" copy
        -- either way, matching this resource's own "best-effort,
        -- non-restraint-implying rejection copy" posture
        -- (server/combat.lua's COMBAT_REJECT_MESSAGES header) -- a blocked
        -- handler does not need a message that reads differently from a
        -- never-granted one.
        NotifyPlayer(src, PursuitSprintRejectMessage('grant_required'), 'error')
        return
    end

    local k9Ped = GetPlayerPed(src)
    if k9Ped == 0 then
        return -- defensive: src disconnected between the event firing and this line -- nothing left to notify
    end

    -- expectedEntityType = 1 (ped) -- see server/entities.lua's
    -- ResolveNetworkEntity doc comment for the GetEntityType numbering,
    -- same magic number server/combat.lua's own ValidateCombatRequest uses
    -- for the identical purpose.
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then
        NotifyPlayer(src, PursuitSprintRejectMessage('invalid_target'), 'error')
        return
    end

    if targetPed == k9Ped then
        NotifyPlayer(src, PursuitSprintRejectMessage('self_target'), 'error')
        return
    end

    -- Player-vs-NPC resolution -- see server/entities.lua's
    -- ResolveConnectedPlayerFromPed doc comment. This feature is
    -- deliberately PLAYER-TARGET-ONLY (unlike server/combat.lua's
    -- BiteAndHold/NonLethalTakedown, which also permit an NPC target): a
    -- "wanted/suspect" flag is a player-only concept in this codebase
    -- (config.lua's own comment on Config.Combat.RequireWantedStatus:
    -- "Does NOT affect NPC targets... this resource has no reason to
    -- protect [an NPC] from griefing") and K9_IDEAS.md §5 itself frames
    -- this feature as "actually chasing someone your server's own system
    -- has already flagged as a suspect" -- an NPC pursuit target would
    -- have no such flag to ever check, and allowing one would reopen
    -- exactly the "provoke an ambient NPC for a free advantage" shape this
    -- codebase has already had to close for XP (server/progression.lua's
    -- own EIGHTH-XP-FARM-FIX), applied here to a movement buff instead of
    -- XP.
    local targetSrc = ResolveConnectedPlayerFromPed(targetPed)
    if not targetSrc then
        NotifyPlayer(src, PursuitSprintRejectMessage('target_not_player'), 'error')
        return
    end

    -- Live server-side proximity -- NEVER a client-claimed distance,
    -- matches server/combat.lua's ValidateCombatRequest exactly.
    local dist = #(GetEntityCoords(k9Ped) - GetEntityCoords(targetPed))
    if dist > Config.PursuitSprint.requestRangeMeters then
        NotifyPlayer(src, PursuitSprintRejectMessage('too_far'), 'error')
        return
    end

    if not IsPursuitTargetWantedEligible(targetSrc) then
        NotifyPlayer(src, PursuitSprintRejectMessage('not_wanted'), 'error')
        return
    end

    -- Cooldown is the LAST gate, consumed only once every other check has
    -- already passed -- an illegitimate request (wrong target, too far,
    -- not wanted) must never burn the K9's own cooldown, matching
    -- server/combat.lua's own "cheapest/no-side-effect checks first,
    -- mutation last" discipline.
    if not PursuitSprintCooldown.Consume(src) then
        NotifyPlayer(src, PursuitSprintRejectMessage('on_cooldown'), 'error')
        return
    end

    TriggerClientEvent('qbx_k9unit:client:pursuitSprintGranted', src)
end)
