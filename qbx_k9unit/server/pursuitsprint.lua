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
        'qbx_k9unit:client:pursuitSprintGranted' (speedMultiplier: number, durationMs: number)
          -- CARRIES A PAYLOAD NOW -- CHANGED THIS PASS, closing a real
          -- tablet-tunable sync gap (see server/runtimecontrol.lua's own
          -- TUNABLE_REGISTRY entries for 'PursuitSprint.speedMultiplier'/
          -- 'PursuitSprint.durationMs'). This USED TO be a payload-less
          -- event on the theory that "Config.PursuitSprint.speedMultiplier/
          -- durationMs are shared_scripts config, already identical on both
          -- sides" -- true only as long as neither side's copy could ever
          -- change independently. server/runtimecontrol.lua's own tablet
          -- can now mutate THIS SERVER's in-memory Config.PursuitSprint
          -- live, with no mechanism that ever reaches an already-connected
          -- client's own independent copy of config.lua -- so a payload-less
          -- grant would have made a live tablet edit a SILENT NO-OP for the
          -- one thing an operator would actually be trying to change,
          -- exactly the failure class this resource keeps finding and
          -- closing. Both values are read fresh off `Config.PursuitSprint`
          -- at the exact moment a grant is decided (see the request handler
          -- below) and sent as this event's own payload; the client applies
          -- WHAT IT WAS SENT, never re-reading its own local config copy for
          -- these two fields again (client/pursuitsprint.lua's own header
          -- has the client-side half of this fix).
          -- LIVE EDIT MID-SPRINT, THE DECISION: a burst ALREADY GRANTED
          -- keeps the exact multiplier/duration it was granted with for its
          -- entire lifetime -- these two values are captured ONCE, right
          -- here, at grant time, never re-read by the client's own end-timer
          -- or re-pushed mid-burst. A live tablet edit therefore always
          -- takes effect on the K9's NEXT grant, never retroactively
          -- reaching over into a burst already in flight. Chosen over
          -- "update a running burst live" for two concrete reasons: (1) this
          -- is a short (single-digit seconds), self-terminating grant, not a
          -- continuous per-tick recomputation like server/wellbeing.lua's
          -- penalties below -- there is no natural "next tick" moment to
          -- re-apply a changed value against without inventing a second
          -- mid-flight message this event's own one-shot "you are cleared,
          -- right now" semantics were never designed to carry; (2) a boost
          -- that could change value while already applied would make the
          -- exact number a K9 is currently benefiting from a moving target
          -- an operator could shift mid-chase, which is a strictly harder
          -- thing to reason about fairly than "every grant uses whatever was
          -- configured at the moment it was granted." requestRangeMeters
          -- (the ELIGIBILITY gate, decided before a grant ever happens) is
          -- unaffected by this choice either way -- it was already, and
          -- remains, re-read fresh on every single request.
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
-- CONFIG SHAPE -- CLAMP AND WARN for every individual number inside it
-- (this pass -- see server/cooldowns.lua's header ADDENDUM: "does an
-- operator's config.lua edit alone... reach this value? If yes it must be
-- clamped and warned about, never asserted and aborted"). speedMultiplier/
-- durationMs/requestRangeMeters below USED TO be three separate hard
-- `assert`s here, mirroring client/agility.lua's own
-- Config.Combat.AgilityAdvanced.detectionMethod assert precedent -- correct
-- for THAT file's shape (a deferred onResourceStart callback, see
-- server/cooldowns.lua's header ADDENDUM for why that shape is safe) but
-- wrong here: an uncaught error thrown from THIS FILE's own top-level chunk
-- aborts server/pursuitsprint.lua's load from that line onward, silently
-- un-registering 'qbx_k9unit:server:requestPursuitSprint' -- the entire
-- feature, not just one bad number. cooldownMs (a few lines below) was
-- already migrated to ResolveConfiguredThresholdMs in an earlier pass (see
-- this file's own header "COOLDOWN FOOTGUN") -- these three siblings were
-- missed only because none of them feed NewCooldown, not because the risk
-- was any different. Deliberately placed AFTER the feature-flag gate above
-- (same convention agility.lua follows): a server that never turns this
-- feature on is never affected by config.lua not yet having this block.
--
-- The "whole table is missing" case below USED TO be its own hard `assert`
-- too, on the theory that there was "nothing sensible to clamp/substitute
-- for the whole table missing" -- that theory doesn't hold up: substituting
-- an empty table lets every one of the per-field resolvers immediately
-- below fall back to its own already-established default, exactly as if
-- an operator had left each field individually blank. Closing this out
-- removes the last top-level assert in this file.
-- ======================================================================
if type(Config.PursuitSprint) ~= 'table' then
    print(
        '[qbx_k9unit] WARNING: Config.Features.PursuitSprint is true but Config.PursuitSprint is missing or ' ..
        'not a table -- using this file\'s own built-in defaults (speedMultiplier=1.4, durationMs=5000, ' ..
        'cooldownMs=45000, requestRangeMeters=20.0) for every field it would have set. Add the settings table ' ..
        'back to config.lua.'
    )
    Config.PursuitSprint = {}
end

--- Same clamp-and-warn shape as server/cooldowns.lua's
--- ResolveConfiguredThresholdMs, for the two fields below that are not
--- themselves a cooldown/duration threshold -- IsValidThreshold's own
--- validity rule (positive, non-NaN) is numerically the right fit for both
--- speedMultiplier and requestRangeMeters, but that function's own printed
--- warning text is written specifically for a cooldown ("0/negative/nil
--- here does NOT mean 'no cooldown'... permanently block the guarded
--- action"), which would mislead an operator reading a speedMultiplier/
--- requestRangeMeters warning. Never errors; prints one warning naming the
--- exact key, the bad value found, and the fallback substituted.
--- @param value any
--- @param fallback number
--- @param keyName string
--- @param requirementText string
--- @return number
local function ResolveConfiguredPositiveNumber(value, fallback, keyName, requirementText)
    if type(value) == 'number' and value == value and value > 0 then
        return value
    end
    print(('[qbx_k9unit] %s must be %s (found: %s). Using the built-in fallback of %s instead so this feature ' ..
        'keeps working while the config is fixed -- find %s in config.lua and correct it.')
            :format(keyName, requirementText, tostring(value), tostring(fallback), keyName))
    return fallback
end

-- speedMultiplier and requestRangeMeters have no relationship to any other
-- field here (unlike server/sarcalls.lua's radius/distance groups) -- each
-- is resolved independently. Resolved values are written BACK into
-- Config.PursuitSprint so every later read in this file (requestRangeMeters
-- is re-read directly off Config, not captured to a local, in the request
-- handler below) sees the same corrected value, not just this one.
Config.PursuitSprint.speedMultiplier = ResolveConfiguredPositiveNumber(
    Config.PursuitSprint.speedMultiplier, 1.4, 'Config.PursuitSprint.speedMultiplier', 'a positive number')

Config.PursuitSprint.requestRangeMeters = ResolveConfiguredPositiveNumber(
    Config.PursuitSprint.requestRangeMeters, 20.0, 'Config.PursuitSprint.requestRangeMeters',
    'a positive number of meters')

-- durationMs IS a genuine duration (client/pursuitsprint.lua's own end-timer
-- reads it directly, no legitimate non-positive meaning) -- an exact fit for
-- ResolveConfiguredThresholdMs's own validity rule, unlike the two fields
-- above.
Config.PursuitSprint.durationMs = ResolveConfiguredThresholdMs(
    Config.PursuitSprint.durationMs, 5000, 'Config.PursuitSprint.durationMs')

-- See this file's own header "COOLDOWN FOOTGUN" -- REPLACED an earlier pass
-- (QA sandbox repro): this used to be its own `assert`, hard-erroring on a
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
-- ResolveConnectedPlayerFromPed (DEVELOPER_REFERENCE.md item 2b, "extracted
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

    -- Read fresh, at the exact moment this grant is decided -- see this
    -- file's own header "EVENT CONTRACT" for the full "why a payload now,
    -- and why a running burst keeps its granted value" writeup. A live
    -- tablet edit (server/runtimecontrol.lua's runtimeSetTunable) to either
    -- field always reaches the NEXT grant this way, since both are read off
    -- live `Config.PursuitSprint` here, never a value captured once at this
    -- file's own load time.
    TriggerClientEvent('qbx_k9unit:client:pursuitSprintGranted', src,
        Config.PursuitSprint.speedMultiplier, Config.PursuitSprint.durationMs)
end)
