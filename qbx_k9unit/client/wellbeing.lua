--[[
    qbx_k9unit/client/wellbeing.lua

    Client-side half of Config.Features.FatigueSystem / MoodSystem /
    FearStressSystem / DistractionSystem / InjuryLimping
    (DEVELOPER_REFERENCE.md §13.0 Decision 1, §13.3, §13.4.3). Receives the server's
    pushed wellbeing snapshots, sets the shared `K9MoveRateModifiers` entries
    for Fatigue/Injury/Mood (DEVELOPER_REFERENCE.md §13.0 Decision 2) and calls
    `RecomputeK9MoveRate()` (client/movement.lua), enforces the client-local
    sprint/jump input blocks for low Injury (a disclosed, bounded, self-
    applied limitation — see server/wellbeing.lua's header and DEVELOPER_REFERENCE.md
    §13.0 Decision 3, not a security boundary), and owns the "Pet K9"/
    "Feed K9" ox_target interactions plus the meat-bait/whistle/calm-down
    self-actions.

    Every one of the five wellbeing flags is checked at the point of use
    below, not just declared: see "LIVE FEATURE FLAGS" below. Every check
    reads `LiveFeatureFlags.<Name>` — the server's CURRENT flag state, kept
    fresh by every `wellbeingUpdate` push/`getWellbeingSnapshot` fetch —
    rather than this client's own static `Config.Features.<Name>` copy,
    fixed at this client's own resource start and never updated by a
    runtime tablet toggle (server/runtimecontrol.lua). Registration
    (CreateThread/RegisterCommand/ox_target option registration) always
    happens regardless of that static value too — a live-OFF flag is
    enforced at the point each ability ACTS, never by skipping registration
    entirely, matching client/featureblocks.lua's own established rule for
    this exact class of check ("check at the point it acts, never merely at
    registration") — see each section's own "ALWAYS STARTS/REGISTERS"
    comment for the specific gap this closes. The one remaining exception,
    left as a disclosed, genuinely bounded staleness rather than a
    correctness bug: the on-demand "just became K9-modeled" snapshot-fetch
    thread below still only starts if this client's OWN static config had
    at least one flag true at boot — a client that shipped fully
    wellbeing-disabled misses that one optimization and instead waits for
    the server's own periodic tick push (bounded to
    `Config.Wellbeing.tickIntervalMs`).

    RESOLVED (server-side fix landed this pass, coder-backend — see
    server/wellbeing.lua's own header and its CreateThread call's resolution
    comment for the full writeup): that periodic tick used to carry the
    IDENTICAL one-time boot-flag gate server-side, and this paragraph used
    to say so, naming an earlier reverted attempt to fix it and warning that
    a deployment where BOTH the server and this client booted with every
    wellbeing flag false could go genuinely unbounded, not merely one tick
    interval, before either side noticed a later runtime toggle-ON. That is
    no longer true. server/wellbeing.lua's shared tick thread now ALWAYS
    starts at that file's own load time, re-checking all five
    Config.Features flags fresh inside the loop before ever calling
    TickWellbeing — a server booted with every flag off and later flipped
    live from the tablet is picked up by that already-running thread within
    one `Config.Wellbeing.tickIntervalMs`, never "until this resource
    restarts." The one gap left is the narrower one stated in the paragraph
    above (this client's own on-demand-fetch optimization, not the server's
    periodic push), and it is genuinely bounded on its own: even a client
    that shipped fully wellbeing-disabled still receives the server's own
    periodic push once the server-side flag is live, within one
    `tickIntervalMs`. This file's "bounded" framing above now holds
    unconditionally — it no longer depends on a flag having already been
    true at boot on the server.

    NOTHING BELOW IS A SECURITY BOUNDARY. Every mutating action
    (pet/feed/calm-down/distraction-item-use) is re-validated server-side in
    server/wellbeing.lua regardless of what this file's own UI/gating
    thinks — the standard "client hides the option, server is the real
    gate" split this codebase applies everywhere (DEVELOPER_REFERENCE.md §4.1).

    NOT CURRENTLY WIRED INTO client/radial.lua: DEVELOPER_REFERENCE.md
    §13.4.3.3 frames "Calm Down" as a radial command. Instead, this file
    exposes a plain resource-global, `RequestK9CalmDown()`, and registers a
    working `/k9calmdown` command as a real, usable-today entry point. A
    future client/radial.lua menu entry should call `RequestK9CalmDown()`
    (or trigger 'qbx_k9unit:server:calmDownK9' directly) rather than
    duplicating this file's validation.

    ======================================================================
    OX_TARGET API — same `addGlobalPlayer` shape already confirmed HIGH
    confidence against real ox_target source by client/medkit.lua (see that
    file's header) — not re-verified independently here, reused unchanged.

    EVENT/CALLBACK CONTRACT — see server/wellbeing.lua's header for the full
    contract; this file is the client side of every entry listed there.

    Commands (RegisterCommand):
    - '/k9calmdown' — always registered; self-only, gated on CanShowK9UI() +
      LiveFeatureFlags.FearStressSystem (the server's CURRENT
      Config.Features.FearStressSystem value, not this client's static
      copy — see "LIVE FEATURE FLAGS" above). Triggers
      'qbx_k9unit:server:calmDownK9'.
    - '/k9meatbait' / '/k9whistle' — always registered; deliberately NOT
      gated on CanShowK9UI(): DEVELOPER_REFERENCE.md §13.4.3.4 open question 2
      reads this as intentionally open to any player (a fleeing suspect
      using a whistle/meat-bait against a pursuing K9 is explicitly
      in-scope per that document's own framing), gated only on
      LiveFeatureFlags.DistractionSystem and, for real, on server-side item
      possession.

    FILE-TO-FILE CONTRACT:
    - Reads/writes `K9MoveRateModifiers` and calls `RecomputeK9MoveRate()`,
      both resource-globals from client/movement.lua (DEVELOPER_REFERENCE.md §13.0
      Decision 2) — never calls `SetPedMoveRateOverride` directly.
    - Calls `IsOwnModelK9()`/`CanShowK9UI()`/`DenyK9UIAccess()`/
      `IsEntityModelK9(entity)`/`ResolvePlayerServerIdFromPed(entity)`,
      resource-globals from client/main.lua — reused, never re-derived.
      `IsEntityModelK9` (DEVELOPER_REFERENCE.md item 3) replaces this file's
      own former local `K9ModelHashes` set (used to mirror
      client/medkit.lua's own precomputation exactly — a client-side
      display filter only, server/wellbeing.lua re-derives every target's
      real model server-side regardless). `ResolvePlayerServerIdFromPed`
      (DEVELOPER_REFERENCE.md item 2b) replaces this file's own former local
      copy of the same function (used to mirror client/medkit.lua's own
      copy exactly).
]]

-- Local mirror of the server's last-pushed snapshot. Safe defaults (fully
-- healthy/calm) so that, before the first real push ever arrives, nothing
-- below throttles or notifies anything — matches every other "disabled/
-- not-yet-known state must be a no-op" default in this codebase.
local lastStats = {
    fatigue = 100,
    mood = 100,
    fearStress = 0,
    injury = 100,
    -- HUNGER/THIRST (this pass, coder-backend) -- same "safe default" reasoning
    -- as every other field here: fully-fed/fully-hydrated until the first
    -- real snapshot arrives.
    hunger = 100,
    thirst = 100,
    distractedUntil = 0,
    hesitatingUntil = 0,
}
local wasDistracted = false
local wasHesitating = false
local wasHungry = false
local wasThirsty = false

-- ======================================================================
-- LIVE FEATURE FLAGS -- closes a real, confirmed gap: every check below
-- USED TO read `Config.Features.<Name>` directly -- this CLIENT's own copy
-- of config.lua, fixed at THIS client's own resource start and never
-- updated by a runtime tablet toggle (server/runtimecontrol.lua's
-- runtimeSetFeature/runtimeResetFeature only ever mutate the SERVER's own
-- in-memory Config table; that file discloses it does not push a live
-- Config update to already-connected clients, since doing so is a
-- client-side decision it does not own). Concretely, that meant: an
-- operator switching e.g. FatigueSystem off mid-session via the tablet
-- left every already-connected, already-penalized K9 stuck at its
-- last-applied K9MoveRateModifiers.fatigue penalty FOREVER --
-- server/wellbeing.lua's own TickWellbeing stops decaying/regenerating
-- that stat the instant its flag is false, so nothing was ever going to
-- carry lastStats.fatigue back across the threshold that would have
-- cleared the modifier, and this file had no way to learn the flag had
-- changed at all. A control that reports "done" to the operator while
-- silently doing nothing for an already-connected player -- worse than one
-- that honestly requires a restart.
--
-- THE FIX: server/wellbeing.lua's SnapshotOf (see that file's own header
-- comment on this exact change) piggybacks a `featureFlags` table onto the
-- ALREADY-EXISTING `wellbeingUpdate` push / `getWellbeingSnapshot`
-- on-demand fetch -- no new event, no new poll, reusing the exact channel
-- this file already listens to every tick. `ApplyWellbeingSnapshot` below
-- copies any recognised boolean field from that table into this mirror;
-- every check in this file that used to read `Config.Features.<Name>`
-- directly now reads `LiveFeatureFlags.<Name>` instead.
--
-- DEFAULT VALUE, DELIBERATE: seeded from this client's own
-- `Config.Features.<Name>` copy -- i.e. IDENTICAL behaviour to before this
-- fix -- until the very first snapshot arrives (the on-demand fetch on
-- becoming K9-modeled, or the first automatic tick push, whichever comes
-- first). Safe to default this way because NOTHING in this file is a
-- security boundary (this file's own header, restated at every call site
-- below) -- unlike client/featureblocks.lua's per-person blocks (which must
-- fail OPEN on unknown state to avoid falsely freezing an ability that was
-- never actually blocked), a briefly-stale-toward-the-shipped-config value
-- here has no access-control consequence either way, only a cosmetic/
-- gameplay one bounded to at most one wellbeing tick interval.
-- ======================================================================
local LiveFeatureFlags = {
    FatigueSystem = Config.Features.FatigueSystem == true,
    MoodSystem = Config.Features.MoodSystem == true,
    FearStressSystem = Config.Features.FearStressSystem == true,
    DistractionSystem = Config.Features.DistractionSystem == true,
    InjuryLimping = Config.Features.InjuryLimping == true,
    -- HUNGER/THIRST (this pass, coder-backend) -- same live-flag mechanism,
    -- same reasoning, as the five siblings above.
    HungerThirstSystem = Config.Features.HungerThirstSystem == true,
}

-- ======================================================================
-- LIVE WELLBEING TUNABLES -- originally "make the speed boost and stamina
-- numbers genuinely editable," extended by the owner to every K9 stat.
-- SAME MECHANISM, SAME CHANNEL AS "LIVE FEATURE FLAGS" ABOVE, NOT A
-- SECOND ONE -- server/wellbeing.lua's SnapshotOf piggybacks a SECOND
-- table, `wellbeingTunables`, onto the identical `wellbeingUpdate` push /
-- `getWellbeingSnapshot` fetch this section's own comment already
-- describes in full; read that comment first, it is not repeated here.
--
-- WHAT THIS REPLACES: every one of the seven fields below used to be read
-- directly off THIS CLIENT's own static `Config.Wellbeing.<Stat>.<Field>`
-- copy at the exact point of use (`ApplyMoveRateModifiers` and the Injury
-- sprint/jump block thread further down) -- fixed at THIS client's own
-- resource start, never updated by a runtime tablet edit
-- (server/runtimecontrol.lua's runtimeSetTunable/runtimeResetTunable only
-- ever mutate the SERVER's own in-memory Config table). server/wellbeing.lua
-- used to document this exact gap as the reason those seven fields were
-- EXCLUDED from TUNABLE_REGISTRY outright -- "a live dial this file cannot
-- even confirm reaches the client" (that exclusion comment's own words).
-- That gap is now closed the same way LiveFeatureFlags closed it for the
-- five boolean flags: mirror the server's CURRENT value here, read FRESH by
-- every call site below, kept fresh by every wellbeingUpdate push.
--
-- MID-EFFECT DECISION, STATED PLAINLY (deliberately DIFFERENT from
-- server/pursuitsprint.lua's "a running burst keeps its granted value"
-- choice -- not an inconsistency, a different value class): a live tablet
-- edit to any of these seven fields takes effect on THIS K9's very next
-- `ApplyMoveRateModifiers()` recompute (within one
-- `Config.Wellbeing.tickIntervalMs` of the edit for an already-connected K9)
-- -- including retroactively re-judging a PENALTY/BLOCK ALREADY IN EFFECT
-- right now against the new threshold/multiplier. This is the right choice
-- for THIS class of value, for a reason PursuitSprint's grant does not
-- share: these are not one-shot grants with a natural start/end a client
-- privately owns -- they are CONTINUOUS, per-tick judgments
-- (`lastStats.<stat> < threshold`) that server/wellbeing.lua's own tick loop
-- already re-evaluates from scratch every single tick regardless of this
-- fix. Freezing a stale threshold for the remainder of "whatever effect was
-- already applied" has no natural boundary to freeze it UNTIL (unlike a
-- bounded few-second sprint burst) -- it would mean an operator's edit
-- never reaches a K9 who happened to already be penalized at the moment of
-- the edit, for as long as they stay penalized, which could be indefinite.
-- Updating immediately is also what makes the "no unbounded trap" rule
-- actually hold for this fix: a threshold raised (or a multiplier
-- loosened) so an already-blocked/penalized K9 no longer qualifies must
-- lift that block/penalty on the very next recompute, not merely stop it
-- from being reapplied at whatever number it started under -- exactly
-- ApplyMoveRateModifiers' own existing "LIVE FEATURE FLAGS" precedent for a
-- flag switched off mid-effect, applied here to a threshold/multiplier
-- edited mid-effect instead.
--
-- DEFAULT VALUE, DELIBERATE: seeded from this client's own
-- `Config.Wellbeing.<Stat>.<Field>` copy -- i.e. IDENTICAL behaviour to
-- before this fix -- until the very first snapshot arrives, same reasoning
-- and same safety argument as LiveFeatureFlags' own default-value comment
-- above (nothing here is a security boundary either).
-- ======================================================================
local LiveWellbeingTunables = {
    fatigueSpeedPenaltyThreshold     = Config.Wellbeing.Fatigue.speedPenaltyThreshold,
    fatigueSpeedPenaltyMultiplier    = Config.Wellbeing.Fatigue.speedPenaltyMultiplier,
    moodPerformancePenaltyThreshold  = Config.Wellbeing.Mood.performancePenaltyThreshold,
    moodPerformancePenaltyMultiplier = Config.Wellbeing.Mood.performancePenaltyMultiplier,
    injurySprintBlockThreshold       = Config.Wellbeing.Injury.sprintBlockThreshold,
    injuryJumpBlockThreshold         = Config.Wellbeing.Injury.jumpBlockThreshold,
    injurySpeedPenaltyMultiplier     = Config.Wellbeing.Injury.speedPenaltyMultiplier,
    -- NATIVE SPRINT STAMINA ASSIST -- see the "NATIVE SPRINT STAMINA ASSIST"
    -- section further below (right after the Injury sprint/jump block) for
    -- the consumer of this field. Same ingest/default-value rules as the
    -- seven fields above -- read fresh by that section every check, seeded
    -- from this client's own static config copy until the first snapshot
    -- arrives, same safety argument (nothing here is a security boundary).
    fatigueNativeStaminaRestorePercent = Config.Wellbeing.Fatigue.nativeStaminaRestorePercent,
    -- HUNGER/THIRST (this pass, coder-backend). CONFIG-DEFENSIVE (see
    -- server/wellbeing.lua's header for the full reasoning): this CLIENT's
    -- own static `Config.Wellbeing.Hunger`/`.Thirst` copy may not exist yet
    -- either (this file does not own config.lua), so this seed is guarded
    -- the same way server/wellbeing.lua's SnapshotOf guards its own
    -- equivalent read -- a client that boots against an old config.lua
    -- simply seeds these two at a safe default instead of erroring out of
    -- this entire file's load (which would take every OTHER wellbeing
    -- feature's client-side half down with it).
    hungerSpeedPenaltyThreshold  = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger.lowThreshold or 30,
    hungerSpeedPenaltyMultiplier = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger.speedPenaltyMultiplier or 0.95,
    thirstSpeedPenaltyThreshold  = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst.lowThreshold or 30,
    thirstSpeedPenaltyMultiplier = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst.speedPenaltyMultiplier or 0.95,
}

--- Recomputes this file's three owned `K9MoveRateModifiers` slots from
--- `lastStats` and asks client/movement.lua's composer to recompute the
--- single real `SetPedMoveRateOverride` call. A stat whose OWNING flag is
--- currently OFF (per `LiveFeatureFlags`, not the static `Config.Features`
--- copy -- see "LIVE FEATURE FLAGS" above) has its slot explicitly RESET to
--- 1.0 every call, never merely left at whatever it already was: leaving a
--- modifier untouched is exactly what would let a flag switched off
--- mid-effect leave that modifier frozen forever, since nothing else in
--- this file would ever move it back to neutral on its own.
local function ApplyMoveRateModifiers()
    -- Every branch below now gates on `LiveFeatureFlags.<Name>` (the
    -- server's CURRENT flag state, kept fresh by ApplyWellbeingSnapshot
    -- below) rather than the static `Config.Features.<Name>` this client
    -- shipped with. Each `else` explicitly RESETS its own modifier to 1.0
    -- rather than leaving it untouched -- see this file's header, "LIVE
    -- FEATURE FLAGS", for the confirmed "unbounded trap" this closes: a
    -- flag switched off mid-effect must REMOVE that effect, not merely stop
    -- re-applying it (server/wellbeing.lua stops updating the underlying
    -- stat the instant its own flag is false, so nothing else was ever
    -- going to clear this on its own).
    if LiveFeatureFlags.FatigueSystem then
        if lastStats.fatigue < LiveWellbeingTunables.fatigueSpeedPenaltyThreshold then
            K9MoveRateModifiers.fatigue = LiveWellbeingTunables.fatigueSpeedPenaltyMultiplier
        else
            K9MoveRateModifiers.fatigue = 1.0
        end
    else
        K9MoveRateModifiers.fatigue = 1.0
    end

    if LiveFeatureFlags.InjuryLimping then
        local injuryPenaltyThreshold = math.max(LiveWellbeingTunables.injurySprintBlockThreshold, LiveWellbeingTunables.injuryJumpBlockThreshold)
        if lastStats.injury < injuryPenaltyThreshold then
            K9MoveRateModifiers.injury = LiveWellbeingTunables.injurySpeedPenaltyMultiplier
        else
            K9MoveRateModifiers.injury = 1.0
        end
    else
        K9MoveRateModifiers.injury = 1.0
    end

    if LiveFeatureFlags.MoodSystem then
        if lastStats.mood < LiveWellbeingTunables.moodPerformancePenaltyThreshold then
            K9MoveRateModifiers.mood = LiveWellbeingTunables.moodPerformancePenaltyMultiplier
        else
            K9MoveRateModifiers.mood = 1.0
        end
    else
        K9MoveRateModifiers.mood = 1.0
    end

    -- HUNGER/THIRST (this pass, coder-backend). Two NEW named entries on the
    -- SAME shared K9MoveRateModifiers table -- client/movement.lua's own
    -- RecomputeK9MoveRate composer is a generic `for _, modifier in
    -- pairs(K9MoveRateModifiers) do effective = effective * modifier end`
    -- (confirmed by reading that function directly before adding these two
    -- lines), so no change is needed there at all. DELIBERATELY MILD and
    -- DELIBERATELY NOT a hard input block (unlike Injury's sprint/jump
    -- block below) -- see server/wellbeing.lua's header for the full
    -- "consequences must stay mild, never cannot-work-at-all" reasoning.
    -- Same "reset to 1.0 in the else branch, never merely left untouched"
    -- discipline as every modifier above, for the identical "flag switched
    -- off mid-effect must remove the effect" reason.
    if LiveFeatureFlags.HungerThirstSystem then
        if lastStats.hunger < LiveWellbeingTunables.hungerSpeedPenaltyThreshold then
            K9MoveRateModifiers.hunger = LiveWellbeingTunables.hungerSpeedPenaltyMultiplier
        else
            K9MoveRateModifiers.hunger = 1.0
        end

        if lastStats.thirst < LiveWellbeingTunables.thirstSpeedPenaltyThreshold then
            K9MoveRateModifiers.thirst = LiveWellbeingTunables.thirstSpeedPenaltyMultiplier
        else
            K9MoveRateModifiers.thirst = 1.0
        end
    else
        K9MoveRateModifiers.hunger = 1.0
        K9MoveRateModifiers.thirst = 1.0
    end

    RecomputeK9MoveRate()
end

--- Applies a freshly-received stats table to `lastStats`, recomputes move
--- rate, and fires cosmetic notifications on state transitions only (never
--- spammed every tick). Shared by both the pushed event handler and the
--- one-shot on-demand snapshot fetch below.
--- @param stats table
local function ApplyWellbeingSnapshot(stats)
    if type(stats) ~= 'table' then return end

    -- LIVE FEATURE FLAG INGEST -- see this file's header "LIVE FEATURE
    -- FLAGS". Done BEFORE anything below reads LiveFeatureFlags, and before
    -- lastStats itself is updated, so ApplyMoveRateModifiers() always acts
    -- on the freshest known flag state for THIS same snapshot. Every entry
    -- is type-checked individually and only overwrites a name this table
    -- already tracks -- a malformed/missing `featureFlags` field (an older
    -- server, or a snapshot from before the very first push) leaves every
    -- flag at its current (or shipped-default) value, never errors, and
    -- never invents a new key.
    if type(stats.featureFlags) == 'table' then
        for flagName in pairs(LiveFeatureFlags) do
            local incoming = stats.featureFlags[flagName]
            if type(incoming) == 'boolean' then
                LiveFeatureFlags[flagName] = incoming
            end
        end
    end

    -- LIVE WELLBEING TUNABLE INGEST -- see this file's header "LIVE
    -- WELLBEING TUNABLES". Same defensive shape as the featureFlags ingest
    -- immediately above: every entry is type-checked individually (a real
    -- number, never NaN -- `incoming == incoming` is Lua's standard NaN
    -- test, matching every other numeric-payload guard in this codebase)
    -- and only overwrites a name this table already tracks -- a malformed/
    -- missing `wellbeingTunables` field (an older server, or a snapshot from
    -- before the very first push) leaves every tunable at its current (or
    -- shipped-default) value, never errors, and never invents a new key.
    if type(stats.wellbeingTunables) == 'table' then
        for tunableName in pairs(LiveWellbeingTunables) do
            local incoming = stats.wellbeingTunables[tunableName]
            if type(incoming) == 'number' and incoming == incoming then
                LiveWellbeingTunables[tunableName] = incoming
            end
        end
    end

    lastStats.fatigue = tonumber(stats.fatigue) or lastStats.fatigue
    lastStats.mood = tonumber(stats.mood) or lastStats.mood
    lastStats.fearStress = tonumber(stats.fearStress) or lastStats.fearStress
    lastStats.injury = tonumber(stats.injury) or lastStats.injury
    -- HUNGER/THIRST (this pass, coder-backend) -- same tonumber-or-keep-last
    -- ingest as every other stat above.
    lastStats.hunger = tonumber(stats.hunger) or lastStats.hunger
    lastStats.thirst = tonumber(stats.thirst) or lastStats.thirst
    lastStats.distractedUntil = tonumber(stats.distractedUntil) or lastStats.distractedUntil
    lastStats.hesitatingUntil = tonumber(stats.hesitatingUntil) or lastStats.hesitatingUntil

    ApplyMoveRateModifiers()

    -- HUNGER/THIRST -- cosmetic, one-shot notifications on a threshold
    -- CROSSING only (never spammed every tick), same shape as the
    -- Distraction/FearStress transition notifies below. Uses the SAME
    -- threshold this tick's ApplyMoveRateModifiers() call just judged the
    -- move-rate penalty against, so the notification and the actual
    -- gameplay effect can never disagree about when the K9 became "hungry"/
    -- "thirsty".
    if LiveFeatureFlags.HungerThirstSystem then
        local isHungryNow = lastStats.hunger < LiveWellbeingTunables.hungerSpeedPenaltyThreshold
        if isHungryNow and not wasHungry then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.hunger_low'), type = 'error' })
        elseif wasHungry and not isHungryNow then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.hunger_satisfied'), type = 'info' })
        end
        wasHungry = isHungryNow

        local isThirstyNow = lastStats.thirst < LiveWellbeingTunables.thirstSpeedPenaltyThreshold
        if isThirstyNow and not wasThirsty then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.thirst_low'), type = 'error' })
        elseif wasThirsty and not isThirstyNow then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.thirst_satisfied'), type = 'info' })
        end
        wasThirsty = isThirstyNow
    end

    if LiveFeatureFlags.DistractionSystem then
        local isDistractedNow = lastStats.distractedUntil > GetGameTimer()
        if isDistractedNow and not wasDistracted then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.distracted'), type = 'error' })
        elseif wasDistracted and not isDistractedNow then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.refocused'), type = 'info' })
        end
        wasDistracted = isDistractedNow
    end

    if LiveFeatureFlags.FearStressSystem then
        local isHesitatingNow = lastStats.hesitatingUntil > GetGameTimer()
        if isHesitatingNow and not wasHesitating then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.hesitating'), type = 'error' })
        elseif wasHesitating and not isHesitatingNow then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.settled'), type = 'info' })
        end
        wasHesitating = isHesitatingNow
    end
end

--- DEVELOPER_REFERENCE.md §13.4.3.1. Pure tick-driven consumer — server/wellbeing.lua's
--- header EVENT/CALLBACK CONTRACT item 8.
--- @param stats table
RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', function(stats)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup; not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:wellbeingUpdate', { fatigue = 999,
    -- ... })` would feed straight into ApplyWellbeingSnapshot() ->
    -- ApplyMoveRateModifiers()'s move-rate composer with zero server
    -- contact. Confidence: MEDIUM-HIGH, the official documented pattern
    -- for distinguishing a genuine server-sent event from a local
    -- self-trigger, not independently verified in-engine.
    if source ~= 65535 then return end

    ApplyWellbeingSnapshot(stats)
end)

-- On-demand snapshot fetch on the moment this client's OWN ped becomes
-- K9-modeled — avoids up to Config.Wellbeing.tickIntervalMs of stale
-- defaults before the server's next automatic tick push. Cheap idle poll
-- otherwise; only runs at all if at least one wellbeing flag is enabled.
if Config.Features.FatigueSystem or Config.Features.MoodSystem
    or Config.Features.FearStressSystem or Config.Features.DistractionSystem
    or Config.Features.InjuryLimping or Config.Features.HungerThirstSystem then
    CreateThread(function()
        local wasK9 = false
        while true do
            local isK9 = IsOwnModelK9()
            if isK9 and not wasK9 then
                -- FAIL-CLOSED GUARD: `lib.callback.await` throws on a
                -- timeout/unregistered-callback rejection rather than
                -- returning nil (see client/main.lua's HasK9Access() doc
                -- comment for the full citation against ox_lib's/FiveM's
                -- real source). This is a `while true do` thread -- an
                -- uncaught throw here would kill this entire loop
                -- permanently (until a resource restart), silently ending
                -- the on-demand snapshot fetch feature for the rest of this
                -- client's session. pcall it; `type(snapshot) == 'table'`
                -- below already treats a nil snapshot as "nothing to
                -- apply."
                local ok, snapshot = pcall(lib.callback.await, 'qbx_k9unit:server:getWellbeingSnapshot', false)
                if not ok then snapshot = nil end
                if type(snapshot) == 'table' then
                    ApplyWellbeingSnapshot(snapshot)
                end
            end
            wasK9 = isK9
            Wait(2000)
        end
    end)
end

-- ======================================================================
-- INJURY — client-local sprint/jump input blocks. DEVELOPER_REFERENCE.md
-- §13.4.3.5's own disclosed limitation: self-applied, not a security
-- boundary, same category as the speed-penalty modifier above (§13.0
-- Decision 3).
--
-- ALWAYS STARTS, regardless of Config.Features.InjuryLimping's boot-time
-- value: gating thread creation on that static copy would create the SAME
-- "unbounded trap" class of bug this file's header "LIVE FEATURE FLAGS"
-- section describes, in BOTH directions --
--   (a) OFF while active: a client that booted with InjuryLimping=true
--       (so this thread started) would keep calling DisableControlAction
--       forever against a `lastStats.injury` value server/wellbeing.lua
--       PERMANENTLY FREEZES the instant the server-side flag goes false (no
--       more decay, no more regen for that stat) -- an already-blocked K9
--       would stay sprint/jump-blocked forever, with no server push and no
--       code path left anywhere that would ever clear it.
--   (b) ON while never started: a client that booted with
--       InjuryLimping=false would never start this thread at all -- a
--       later runtime toggle-ON would have nothing left running
--       client-side to ever begin enforcing the block, for the rest of
--       that client's session.
-- Fixed the same way client/movement.lua's own MOVE-RATE WATCHDOG closes
-- the identical class of gap (see that file's header for the general
-- pattern this mirrors): the thread always exists, and checks the CHEAP,
-- purely-local `LiveFeatureFlags.InjuryLimping` boolean FIRST, every
-- iteration, before paying for a single native call
-- (IsEntityModelK9/IsEntityDead) -- idling at the same coarse 1000ms this
-- section already uses for its "not currently K9"/"dead" branches whenever
-- the live flag is false. Calling DisableControlAction has no state that
-- outlives the current frame it was called in, so simply not calling it
-- starting the very next iteration IS the removal this file's header
-- requires -- no separate "undo" step is needed the way a persisted
-- SetPedMoveRateOverride value needs an explicit reset back to 1.0 (see
-- ApplyMoveRateModifiers above).
--
-- Control indices reuse client/movement.lua's own AgilityBasicJump
-- constants (HIGH confidence, standard/well-established GTA V control
-- mapping): 22 = INPUT_JUMP. INPUT_SPRINT = 21 is the standard,
-- widely-documented FiveM/GTA V control id for the sprint action — HIGH
-- confidence per common ecosystem knowledge, not independently re-verified
-- against a live client.
-- ======================================================================
do
    local INPUT_SPRINT = 21
    local INPUT_JUMP = 22

    CreateThread(function()
        while true do
            -- OWN-DEATH GUARD: mirrors this codebase's own established
            -- "own ped death forces an active perception/effect feature to
            -- end" precedent (client/vision.lua's maintenance thread,
            -- client/propattachment.lua's "OWN-DEATH AUTO-DETACH",
            -- client/tracking.lua's own equivalent guard on its
            -- state/compute thread). A dead ped can neither sprint nor
            -- jump anyway, so spinning at Wait(0) and re-issuing
            -- DisableControlAction every single frame while the K9 lay dead
            -- was pure wasted per-frame native-call cost with zero gameplay
            -- effect. Idles at the same 1000ms as the "not currently K9"
            -- branch below while dead, and resumes real per-frame checking
            -- the instant the ped is alive again (no separate respawn hook
            -- needed — IsEntityDead() is polled fresh every loop iteration
            -- here).
            --
            -- IDLE-SPIN FIX: the branch below used to take Wait(0) for the
            -- ENTIRE "alive and K9-modeled" case unconditionally, regardless
            -- of whether either threshold was actually crossed. With the
            -- shipped defaults (sprintBlockThreshold=30,
            -- jumpBlockThreshold=20 out of Injury.max=100), a HEALTHY K9 —
            -- injury anywhere in (30, 100], the overwhelmingly common case
            -- for the entire time InjuryLimping has anything to do — spun
            -- this thread at full per-frame rate forever, calling
            -- PlayerPedId/IsOwnModelK9 (-> GetEntityModel)/IsEntityDead
            -- roughly 180 times/second per K9 player, for the rest of that
            -- session, for zero gameplay effect: this is the DEFAULT case,
            -- not an edge case, unlike the dead-ped guard above (which
            -- correctly idles only the much rarer "currently dead" state).
            -- Fixed the same way that guard already established: only take
            -- Wait(0) — the cadence DisableControlAction's own contract
            -- genuinely requires while actively re-asserting a block — when
            -- at least one threshold is ACTUALLY crossed this tick; idle at
            -- the same coarse 1000ms otherwise. A healthy-to-injured
            -- transition can therefore take up to 1000ms to start being
            -- enforced (the same latency the dead-ped guard above already
            -- accepts for resuming enforcement after a respawn) —
            -- negligible against Config.Wellbeing
            -- .tickIntervalMs's own 5000ms default cadence for Injury to
            -- change at all, and this was never a security boundary to
            -- begin with (this section's own header, and DEVELOPER_REFERENCE.md
            -- §13.0 Decision 3).
            --
            -- OWNER'S DECISION: MODEL, not role (K9 role/model decoupling)
            -- -- same call and same reasoning as client/movement.lua's
            -- jump/crouch suppression. IsEntityModelK9(PlayerPedId()) below
            -- is a RESTRICTION gate, not an access grant -- it TAKES
            -- sprint/jump AWAY from whoever it applies to. The injury
            -- sprint/jump block restricts quadruped locomotion; a
            -- role-holder on a human body never had that locomotion to
            -- restrict, so this deliberately checks the model alone, not
            -- IsOwnModelK9() (which would also match a role-holder on a
            -- human body). Do not "fix" this to IsOwnModelK9() in a future
            -- any-ped sweep.
            -- LIVE FLAG GATE, CHECKED FIRST (see this section's own header,
            -- "ALWAYS STARTS"): a plain local boolean read, zero
            -- native-call cost, ahead of
            -- IsEntityModelK9()/IsEntityDead() below -- exactly the
            -- "cheap local flag first, real work only while there is
            -- something to do" shape client/movement.lua's own MOVE-RATE
            -- WATCHDOG already established. While the live flag is false,
            -- NOTHING below it ever runs -- no native calls, no
            -- DisableControlAction -- which is also what makes turning this
            -- OFF mid-block an immediate, real removal: the block has no
            -- state beyond "was DisableControlAction called this frame",
            -- so simply not calling it starting next iteration undoes it
            -- completely, not merely "stops it from getting worse".
            if not LiveFeatureFlags.InjuryLimping then
                Wait(1000)
            elseif IsEntityModelK9(PlayerPedId()) and not IsEntityDead(PlayerPedId()) then
                -- LIVE TUNABLE READ (see this file's header "LIVE
                -- WELLBEING TUNABLES"): reads the server's CURRENT
                -- threshold, not this client's static config copy, so a
                -- tablet edit that raises a threshold lifts an existing
                -- block on this very next 1000ms-or-sooner iteration, never
                -- stranding a K9 at a stale value for the rest of the
                -- session.
                local sprintBlocked = lastStats.injury < LiveWellbeingTunables.injurySprintBlockThreshold
                local jumpBlocked = lastStats.injury < LiveWellbeingTunables.injuryJumpBlockThreshold
                if sprintBlocked or jumpBlocked then
                    if sprintBlocked then
                        DisableControlAction(0, INPUT_SPRINT, true)
                    end
                    if jumpBlocked then
                        DisableControlAction(0, INPUT_JUMP, true)
                    end
                    Wait(0) -- must disable every frame while ACTUALLY blocking something this tick, per DisableControlAction's own contract
                else
                    Wait(1000) -- healthy (injury at/above BOTH thresholds) -- nothing to disable this tick; idle coarsely instead of spinning at full frame rate for zero effect, same cadence as the dead/non-K9 branch below
                end
            else
                Wait(1000)
            end
        end
    end)
end

-- ======================================================================
-- NATIVE SPRINT STAMINA ASSIST (owner directive, this pass: "make sure high
-- command can edit the ability to make stamina last longer or even
-- permanently"). DELIBERATELY SEPARATE from this file's own Fatigue
-- move-rate modifier above -- see config.lua's own comment on
-- Config.Wellbeing.Fatigue.nativeStaminaRestorePercent for the full "two
-- different things called stamina" writeup. This section is the client-side
-- half of the SECOND one: GTA/FiveM's own built-in player sprint-stamina
-- limit (the same value client/hud.lua's "Stamina" HUD row displays via
-- GetPlayerSprintStaminaRemaining), a real engine limit this resource
-- previously never touched at all -- confirmed by reading client/hud.lua in
-- full: that file only ever READS the native, never restores it.
--
-- MECHANISM: PLAYER::RESTORE_PLAYER_STAMINA(player, percentage) -- confirmed
-- against FiveM's own natives.json (runtime.fivem.net/doc/natives.json),
-- documented as "Adds a percentage to a players stamina", `percentage`
-- documented as "a percentage that ranges from 0.0 to 1.0 (1.0 being
-- 100%)", with an OFFICIAL example that calls it on a plain repeating timer
-- for exactly this "keep it topped up" purpose
-- (`RestorePlayerStamina(PlayerId(), 0.3)` every 15s). Same `Player`-typed
-- first argument client/hud.lua's own GetPlayerSprintStaminaRemaining(PlayerId())
-- already calls unguarded a few files up this exact same call chain --
-- CONFIDENCE: MEDIUM-HIGH that this is the correct, working native for this
-- purpose (an official, documented example matching this exact use case,
-- not merely community folklore); MEDIUM, honestly, on "restoring on a
-- 1-second cadence reads as literally, continuously full rather than a
-- very-fast-but-still-real sawtooth" -- this codebase has no live FiveM
-- client available to verify the exact depletion-vs-restore timing against,
-- and unlike this file's own Fatigue decay (a plain server-side number this
-- resource fully owns and can subtract exactly zero from), the underlying
-- engine's own depletion rate is not something this file controls or has
-- documented numbers for. At the tunable's max (1.0), this section
-- unconditionally restores to 100% every single check -- the strongest,
-- most frequent assist this native's own contract allows -- which is the
-- honest, provable claim tests/clientwellbeing_spec.lua makes for this
-- section: "every check calls RestorePlayerStamina with exactly the
-- configured percentage", not "the HUD bar visually never moves in a live
-- game" (untestable here).
--
-- GATE: CanShowK9UI() (client/main.lua's own IsOwnModelK9() AND
-- HasK9Access() combinator) -- the SAME self-only-ability gate this exact
-- file already uses for RequestK9CalmDown above, reused rather than
-- inventing a second one. LiveFeatureFlags.FatigueSystem is checked FIRST,
-- cheap and local, before CanShowK9UI()'s own native calls -- same "cheap
-- local flag first" discipline the Injury block above already established.
-- FatigueSystem off means this resource makes NO claim about managing a
-- K9's stamina at all (this file's own established "read at the point of
-- activation" discipline, applied here to a second stamina system, not just
-- the first) -- vanilla behaviour, unmodified, exactly as if this section
-- did not exist.
--
-- ZERO IS THE SAFE, INTENDED DEFAULT, NOT A FOOTGUN: at
-- LiveWellbeingTunables.fatigueNativeStaminaRestorePercent == 0 (the shipped
-- config.lua default), this loop never calls RestorePlayerStamina at all --
-- a server that never raises this tunable sees byte-identical vanilla
-- stamina behaviour to before this pass, no regression by default.
--
-- ALWAYS STARTS, regardless of Config.Features.FatigueSystem's boot-time
-- value -- same "gate at the point it acts, never merely at registration"
-- rule this file's header states for every other section, so a live
-- tablet toggle-ON reaches an already-connected client with no restart.
-- ======================================================================
CreateThread(function()
    while true do
        if LiveFeatureFlags.FatigueSystem
            and LiveWellbeingTunables.fatigueNativeStaminaRestorePercent > 0
            and CanShowK9UI() then
            RestorePlayerStamina(PlayerId(), LiveWellbeingTunables.fatigueNativeStaminaRestorePercent)
        end
        Wait(1000) -- coarse, cheap cadence -- see this section's own header for why 1s is frequent enough for this native's own documented purpose
    end
end)

-- ======================================================================
-- MOOD — "Pet K9" / "Feed K9" ox_target world interactions.
--
-- ALWAYS REGISTERS, regardless of Config.Features.MoodSystem's boot-time
-- value: gating this entire block (including the ox_target registration
-- itself) on that static copy would mean a client who booted with
-- MoodSystem=false could never see "Pet K9"/"Feed K9" appear even after a
-- later runtime toggle-ON, for the rest of that client's session -- no
-- restart of THIS resource would help, since nothing client-side would be
-- left to ever call RegisterMoodOxTargetOptions() again. Per this file's
-- header "LIVE FEATURE FLAGS": registration always happens (cheap --
-- ox_target option registration is a one-time table build, not a poll),
-- and both `canInteract` closures below gate on
-- `LiveFeatureFlags.MoodSystem` (the server's CURRENT flag state) instead
-- of the static `Config.Features.MoodSystem` this client shipped with --
-- exactly matching client/featureblocks.lua's own established rule for
-- this class of check ("check at the point it acts, never merely at
-- registration"). ox_target calls `canInteract` fresh on every look, so a
-- live flag flip is reflected the very next time a player looks at a K9,
-- with no registration-lifecycle work needed on either side of the
-- transition.
-- ======================================================================
do
    -- ResolvePlayerServerIdFromPed(entity) used to be defined here as a
    -- local copy of client/medkit.lua's own function (deliberate per-file
    -- duplication at the time). Extracted to client/main.lua as a
    -- resource-global per DEVELOPER_REFERENCE.md item 2b once both copies
    -- were confirmed byte-identical — see that file's own doc comment.
    -- The "Pet K9"/"Feed K9" onSelect handlers below now call the shared
    -- global instead.

    local function NotifyResult(result, okDescription)
        if not result then return end
        if result.ok then
            lib.notify({ title = locale('common.notify_title'), description = okDescription, type = 'success' })
            return
        end

        local reasonLabel = ({
            feature_disabled = locale('wellbeing.reason_feature_disabled'),
            invalid_target   = locale('wellbeing.reason_invalid_target'),
            too_far          = locale('common.too_far_from_k9'),
            on_cooldown      = locale('wellbeing.reason_on_cooldown'),
            no_item          = locale('wellbeing.reason_no_item'),
        })[result.reason] or locale('wellbeing.reason_generic')

        lib.notify({ title = locale('common.notify_title'), description = reasonLabel, type = 'error' })
    end

    -- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua),
    -- never a direct `exports.ox_target` call -- both canInteract/onSelect
    -- pairs below are unchanged (still authored against ox_target's own
    -- convention), so an operator running a different supported target
    -- script gets both options translated automatically instead of losing
    -- them outright.
    --
    -- LIFECYCLE FIX: extracted into a named function, sole call site the
    -- AddEventHandler('onResourceStart', ...) below, so both options come
    -- back after a bare restart of whatever resource actually backs the
    -- 'target' system, not just after this resource's own restart -- every
    -- supported target script keeps its own registry in a plain file-local
    -- Lua table inside its own client chunk, reloaded empty on THAT
    -- resource's own restart with nothing else prompting a re-add. Mirrors
    -- server/tracking.lua's RegisterScentInventoryHook /
    -- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for
    -- the identical bug class against ox_inventory. DUPLICATE-VS-REPLACE:
    -- both options below always set `name`, and every adapter's own
    -- registration primitive dedups/replaces by that same name (or label,
    -- per shared/compat/target.lua's own per-adapter notes), so re-running
    -- this never duplicates either entry.
    local function RegisterMoodOxTargetOptions()
        K9Compat.Get('target').AddGlobalPlayer({
            {
                name = 'qbx_k9unit:petK9',
                icon = 'fas fa-hand-holding-heart',
                label = locale('wellbeing.pet_target_label'),
                distance = 3.0,
                canInteract = function(entity)
                    if not LiveFeatureFlags.MoodSystem then return false end
                    -- WIDENED (K9 role/model decoupling) with
                    -- IsK9RoleForPlayer(...) -- client/appearance.lua's own
                    -- per-target-cached (1s TTL) server round trip for
                    -- "does THAT player hold the K9 role" -- so a target on
                    -- a human/custom model who already holds the role can
                    -- still be petted. Matches server/wellbeing.lua's own
                    -- ResolveK9Ped, which already accepts
                    -- (looksLikeK9 or holdsK9Role) server-side.
                    return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
                end,
                onSelect = function(data)
                    local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                    if not targetServerId then return end

                    -- FAIL-CLOSED GUARD: `lib.callback.await` throws rather
                    -- than returning nil on a timeout/unregistered-callback
                    -- rejection (see client/main.lua's HasK9Access() doc
                    -- comment for the full citation). pcall it; NotifyResult
                    -- already treats a nil/falsy `result` as a silent no-op
                    -- (`if not result then return end`), so a thrown
                    -- failure now degrades to that exact same, already-
                    -- established path instead of aborting the onSelect
                    -- handler uncaught.
                    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:petK9', false, targetServerId)
                    if not ok then result = nil end
                    NotifyResult(result, locale('wellbeing.pet_success'))
                end,
            },
            {
                name = 'qbx_k9unit:feedK9',
                icon = 'fas fa-bone',
                label = locale('wellbeing.feed_target_label'),
                distance = 3.0,
                canInteract = function(entity)
                    if not LiveFeatureFlags.MoodSystem then return false end
                    -- WIDENED (K9 role/model decoupling) -- same
                    -- IsK9RoleForPlayer(...) reasoning as "Pet K9" above.
                    return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
                end,
                onSelect = function(data)
                    local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                    if not targetServerId then return end

                    -- FAIL-CLOSED GUARD -- same reasoning as the "Pet K9"
                    -- onSelect handler above (see its comment for the
                    -- ox_lib/FiveM source citation); NotifyResult's own
                    -- `if not result then return end` already covers a
                    -- pcall-caught nil `result`.
                    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:feedK9', false, targetServerId)
                    if not ok then result = nil end
                    NotifyResult(result, locale('wellbeing.feed_success'))
                end,
            },
        })
    end

    -- Sole call site for RegisterMoodOxTargetOptions() above: this
    -- resource's own start, or ox_target's own start -- mirrors
    -- server/tracking.lua's RegisterScentInventoryHook /
    -- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for
    -- the identical class of gap against ox_inventory. Registration is
    -- unconditional here -- see this section's own header "ALWAYS
    -- REGISTERS" for why registering regardless of MoodSystem's STATIC
    -- boot-time value is the fix, not a regression: the actual gate a
    -- disabled feature needs lives in `canInteract`
    -- (`LiveFeatureFlags.MoodSystem`), checked fresh on every look, not at
    -- registration.
    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName == GetCurrentResourceName() then
            RegisterMoodOxTargetOptions()
            return
        end

        -- This file never names a third-party target resource directly
        -- (see shared/compat/target.lua) -- whichever one actually backs
        -- the 'target' system is asked of K9Compat itself. Redetect() is
        -- forced here rather than relying on shared/compat/core.lua's own
        -- onResourceStart/onClientResourceStart redetect hook having
        -- already run for this SAME event, so this check is correct
        -- regardless of relative handler-registration order between the
        -- two files.
        K9Compat.Redetect()
        if resourceName == K9Compat.Which('target') then
            RegisterMoodOxTargetOptions()
        end
    end)
end

-- ======================================================================
-- FEARSTRESS — "Calm Down" self-action. See this file's header for why
-- this is a plain command + exported global rather than a
-- client/radial.lua menu entry.
-- ======================================================================

--- Resource-global (no `local`) — a future radial menu entry should call
--- this rather than re-deriving its own validation.
--- Already unconditionally registered (RegisterCommand below is never
--- gated by a `Config.Features.FearStressSystem` wrapper) -- this function
--- itself is the only gate, so reading
--- `LiveFeatureFlags.FearStressSystem` here (see this file's header "LIVE
--- FEATURE FLAGS") rather than the static
--- `Config.Features.FearStressSystem` is enough on its own to make a
--- runtime toggle reach an already-connected client in BOTH directions,
--- with no registration-lifecycle change needed.
function RequestK9CalmDown()
    if not LiveFeatureFlags.FearStressSystem then return end
    -- REASON ROUTING (ease-of-use audit, this pass): CanShowK9UI() is the
    -- broad role-AND-access combinator, so this call site cannot tell which
    -- half failed -- 'common.no_k9_role_or_access' is the most specific
    -- reason it can honestly claim (see DenyK9UIAccess's own doc comment in
    -- client/main.lua for the full routing policy).
    if not CanShowK9UI() then
        DenyK9UIAccess('common.no_k9_role_or_access')
        return
    end

    TriggerServerEvent('qbx_k9unit:server:calmDownK9')
end

RegisterCommand('k9calmdown', RequestK9CalmDown, false)

-- ======================================================================
-- DISTRACTION — meat-bait / whistle self-use. Deliberately open to ANY
-- player, not gated on CanShowK9UI() — see this file's header.
--
-- COMMANDS ALWAYS REGISTER, regardless of
-- Config.Features.DistractionSystem's boot-time value: gating BOTH
-- RegisterCommand calls on that static copy would mean a client who
-- booted with DistractionSystem=false could never even attempt
-- `/k9meatbait`/`/k9whistle` after a later runtime toggle-ON, for the rest
-- of that session (an unrecognised command, not a refused one). Per this
-- file's header "LIVE FEATURE FLAGS" and matching RequestK9CalmDown's own
-- already-correct shape immediately above: both commands always register,
-- and `UseDistractionItem` below checks `LiveFeatureFlags.DistractionSystem`
-- FIRST -- a plain local read, avoiding a wasted round trip to the
-- server's own (unchanged, still live-checked) `applyK9Distraction`
-- callback for a flag this client already knows is off.
-- ======================================================================
do
    local function UseDistractionItem(itemType, failDescription)
        if not LiveFeatureFlags.DistractionSystem then return end

        -- FAIL-CLOSED GUARD: `lib.callback.await` throws rather than
        -- returning nil on a timeout/unregistered-callback rejection (see
        -- client/main.lua's HasK9Access() doc comment for the full
        -- ox_lib/FiveM source citation). pcall it; the very next line's
        -- `if not result then return end` already treats a nil result as
        -- a silent no-op, so a thrown failure now degrades to that exact
        -- same path instead of aborting this command handler uncaught.
        local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:applyK9Distraction', false, itemType)
        if not ok then result = nil end
        if not result then return end

        if result.ok then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.distraction_used'), type = 'success' })
            return
        end

        -- 'invalid_target' and the unrecognized-reason fallback below share
        -- the identical English sentence in this table (confirmed before
        -- minting) -- both point at the same wellbeing.reason_use_generic
        -- key rather than duplicating it under a second name.
        local reasonLabel = ({
            feature_disabled = locale('wellbeing.reason_feature_disabled'),
            invalid_item     = locale('wellbeing.reason_invalid_item'),
            invalid_target   = locale('wellbeing.reason_use_generic'),
            no_item          = failDescription,
        })[result.reason] or locale('wellbeing.reason_use_generic')

        lib.notify({ title = locale('common.notify_title'), description = reasonLabel, type = 'error' })
    end

    RegisterCommand('k9meatbait', function()
        UseDistractionItem('meatBait', locale('wellbeing.reason_no_meat_bait'))
    end, false)

    RegisterCommand('k9whistle', function()
        UseDistractionItem('whistle', locale('wellbeing.reason_no_whistle'))
    end, false)
end

-- ======================================================================
-- HUNGER/THIRST (this pass, coder-backend). See server/wellbeing.lua's
-- header "SELF-SERVICE, A DELIBERATE DIVERGENCE FROM MOOD" for why these
-- are plain self-only commands (mirroring RequestK9CalmDown's own shape
-- exactly) rather than an ox_target option on another player's ped, and
-- "WATER BOWL MODEL RISK" for the world-prop bowl option below.
--
-- COMMANDS ALWAYS REGISTER, regardless of Config.Features.HungerThirstSystem's
-- boot-time value -- identical reasoning to every other command in this
-- file (RequestK9CalmDown/k9meatbait/k9whistle): gating registration on the
-- static boot-time copy would mean a client who booted with the feature off
-- could never even attempt `/k9eat`/`/k9drink` after a later runtime
-- toggle-ON, for the rest of that session. Gated instead at the point of
-- use, on `LiveFeatureFlags.HungerThirstSystem`, then re-validated for real
-- server-side regardless (server/wellbeing.lua's own feedK9Hunger/
-- giveK9Water -- this file's own checks are display/UX only).
-- ======================================================================
RegisterCommand('k9eat', function()
    if not LiveFeatureFlags.HungerThirstSystem then return end
    -- REASON ROUTING (ease-of-use audit, this pass) -- see RequestK9CalmDown's
    -- identical comment above for the full policy this follows.
    if not CanShowK9UI() then
        DenyK9UIAccess('common.no_k9_role_or_access')
        return
    end
    TriggerServerEvent('qbx_k9unit:server:feedK9Hunger')
end, false)

RegisterCommand('k9drink', function()
    if not LiveFeatureFlags.HungerThirstSystem then return end
    -- REASON ROUTING (ease-of-use audit, this pass) -- see RequestK9CalmDown's
    -- identical comment above for the full policy this follows.
    if not CanShowK9UI() then
        DenyK9UIAccess('common.no_k9_role_or_access')
        return
    end
    TriggerServerEvent('qbx_k9unit:server:giveK9Water')
end, false)

-- ======================================================================
-- THIRST — "Drink from Bowl" world-object ox_target option. Targets
-- Config.Wellbeing.Thirst.bowlSources by MODEL, the same
-- K9Compat.Get('target').AddModel primitive client/fetch.lua's own
-- "Pick Up Ball" option and client/kennel.lua already use to target a
-- world prop by model rather than a specific spawned instance -- confirmed
-- against the SAME ox_target addModel API those two files already
-- established, not re-derived here.
--
-- DEGRADES GRACEFULLY if `bowlSources` never resolves to a real model in
-- this world (see server/wellbeing.lua's header "WATER BOWL MODEL RISK"):
-- AddModel simply never matches any entity, so this option never appears
-- for anyone -- Thirst still fully works via `/k9drink` above, which has no
-- model dependency at all.
--
-- ALWAYS REGISTERS, regardless of Config.Features.HungerThirstSystem's
-- boot-time value -- same "registration always happens, LiveFeatureFlags
-- gates canInteract" rule as every other ox_target option in this file
-- (see the MOOD section's own header above for the full reasoning), and the
-- SAME onResourceStart/target-resource-restart re-registration fix that
-- section's own RegisterMoodOxTargetOptions() already established (a
-- restart of whichever resource actually backs ox_target/qb-target/etc.
-- would otherwise silently drop this option forever without it).
-- ======================================================================
do
    local function RegisterBowlOxTargetOptions()
        local bowlSources = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst.bowlSources or nil
        if type(bowlSources) ~= 'table' or #bowlSources == 0 then return end

        local models = {}
        for _, modelName in ipairs(bowlSources) do
            if type(modelName) == 'string' and modelName ~= '' then
                models[#models + 1] = GetHashKey(modelName)
            end
        end
        if #models == 0 then return end

        K9Compat.Get('target').AddModel(models, {
            {
                name = 'qbx_k9unit:drinkFromBowl',
                icon = 'fas fa-dog',
                label = locale('wellbeing.bowl_target_label'),
                distance = 2.0,
                canInteract = function()
                    if not LiveFeatureFlags.HungerThirstSystem then return false end
                    return CanShowK9UI()
                end,
                onSelect = function(data)
                    if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                    local netId = NetworkGetNetworkIdFromEntity(data.entity)
                    TriggerServerEvent('qbx_k9unit:server:drinkFromBowl', netId)
                end,
            },
        })
    end

    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName == GetCurrentResourceName() then
            RegisterBowlOxTargetOptions()
            return
        end

        K9Compat.Redetect()
        if resourceName == K9Compat.Which('target') then
            RegisterBowlOxTargetOptions()
        end
    end)
end
