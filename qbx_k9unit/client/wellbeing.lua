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
    §13.0 Decision 3, not a security boundary), and owns the merged "Care
    for K9" ox_target interaction (COMMAND_CONSOLIDATION_SPEC.md §7 /
    FEATURE_STRUCTURE_SPEC.md §5 — see the MOOD section further down for the
    full consolidation writeup) plus the meat-bait/whistle/calm-down
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


-- SERVER-CALLBACK TIMEOUT (added 2026-08-31, from live testing).
-- Every lib.callback.await in this file previously passed `false` here.
-- Each call is wrapped in a pcall written on the stated assumption that
-- await "THROWS on a timeout" -- but `false` is the timeout argument, and
-- passing it is what disables the timeout. So nothing ever threw: a server
-- callback that does not answer left the caller waiting indefinitely rather
-- than failing cleanly. On the tablet that means a fetch promise that never
-- resolves, which is exactly the "I have to keep clicking Retry on almost
-- everything" the owner reported.
--
-- An explicit number is correct whichever way ox_lib treats `false` (I could
-- not reach its source from this environment to confirm): if false disabled
-- the timeout, this restores it; if false was already ignored, this only
-- makes the value explicit. Ten seconds is far longer than any call here
-- needs -- with Config.Database.enabled false everything is in-memory -- and
-- still bounded, so a wedged callback surfaces as a clear error instead of a
-- hang.
local K9_CALLBACK_TIMEOUT_MS = 10000
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
    -- HUNGER/THIRST (this pass, coder-backend) -- same live-flag mechanism,
    -- same reasoning, as the five siblings above.
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
if Config.Features.FatigueSystem then
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
                local ok, snapshot = pcall(lib.callback.await, 'qbx_k9unit:server:getWellbeingSnapshot', K9_CALLBACK_TIMEOUT_MS)
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
-- MOOD — "Care for K9" ox_target world interaction (was two: "Pet K9" /
-- "Feed K9"), merged this pass (coder-backend).
--
-- CONSOLIDATION, PICKED UP FROM ITS OWN DEFERRAL: COMMAND_CONSOLIDATION_SPEC.md
-- §7 ("watch, don't act yet") and FEATURE_STRUCTURE_SPEC.md §5 both named
-- this exact merge and both explicitly deferred it for the same stated
-- reason -- "the file is hot" -- with an instruction to revisit once it
-- quieted down. It has. This closes the one family FEATURE_STRUCTURE_SPEC.md
-- §6's own count-down table left as "Deferred (file hot)" while every
-- sibling family (kennel, fetch, training, Detection) already landed.
--
-- WHAT MERGED, AND WHY THOSE TWO SPECIFICALLY: FEATURE_STRUCTURE_SPEC.md §5's
-- own framing lists FOUR target options under this family --
-- feedK9/petK9/treatK9/drinkFromBowl -- but only feedK9/petK9 are actually
-- reachable from this file (treatK9 lives in client/medkit.lua, out of this
-- pass's file-ownership scope; drinkFromBowl is this file's own, see its own
-- "WHY drinkFromBowl DOES NOT JOIN THIS MERGE" note further down for why it
-- stays separate on the merits, not merely on ownership). Pet and Feed,
-- confirmed by reading server/wellbeing.lua's own petK9/feedK9 callbacks
-- directly before touching anything here, are the two that are ACTUALLY
-- interchangeable for a merge: identical actor/target shape (any player,
-- targeting a DIFFERENT K9-modeled player's ped -- both reject
-- `targetPed == usingPed`), identical `MOOD_INTERACT_RANGE` proximity gate,
-- and the SAME shared `AffectionCooldown` tracker instance (server/
-- wellbeing.lua's own REWARD-FARM FIX comment on that declaration --
-- petting and feeding are already treated as one interchangeable "affection"
-- action server-side, this merge just makes the CLIENT UI agree). The only
-- axis they differ on is Feed's own extra precondition (carrying
-- Config.Wellbeing.Mood.feedItemName) -- exactly the shape this file's task
-- brief calls out as "the hard part": a naive single button would land on
-- whichever of the two happened to be tried and refuse for a reason the
-- player standing in front of a perfectly pettable dog cannot see.
--
-- RESOLUTION RULE, IN ONE SENTENCE: try Feed first (the strictly BETTER
-- outcome when possible -- it also raises Mood, per
-- Config.Wellbeing.Mood.feedRegenAmount, same or higher than Pet's own
-- petRegenAmount in every shipped config this pass reviewed); fall back to
-- Pet, which carries NO consumable precondition of its own, only when Feed's
-- OWN server response says the SPECIFIC reason it did not go through was
-- `no_item` -- see RequestCareForK9() below for the full "why exactly this
-- reason, and no other" reasoning. This is "resolve to whichever action the
-- player can actually perform right now" (this task's own suggested shape),
-- not "offer a merged option that mostly refuses": Pet has no precondition
-- of its own, so the fallback is guaranteed to succeed whenever the ONLY
-- thing blocking the player was a missing item, not distance/cooldown/
-- feature-off/invalid-target (those four are IDENTICAL checks on both
-- server callbacks, in the same order, against the same state -- see
-- RequestCareForK9()'s own doc comment for why those four are reported
-- directly rather than triggering a second, guaranteed-to-fail round trip).
--
-- NOT A NEW PERMISSION CHECK: this section writes ZERO new server code and
-- ZERO new client-side gating of its own. `RequestCareForK9()` below is pure
-- orchestration over the two EXISTING, UNMODIFIED
-- 'qbx_k9unit:server:petK9'/'qbx_k9unit:server:feedK9' callbacks -- every
-- permission/proximity/cooldown/item check a player could hit today is
-- still made by exactly the same server-side code, in exactly the same
-- place, unchanged by one line. This is what "must reach the SAME functions
-- and inherit their gating exactly" (this task's own hard rule) looks like
-- in practice: reusing, never re-deriving.
--
-- HIDDEN ALIASES, THE ox_target TRANSLATION OF THIS RESOURCE'S ESTABLISHED
-- CONVENTION: COMMAND_CONSOLIDATION_SPEC.md §3's own "hidden alias" shape
-- for a MERGED COMMAND is "keep the old RegisterCommand call registered,
-- same handler body, now usually just forwarding into the new merged
-- dispatcher... but stop advertising it in the discoverability layer." A
-- third-eye option has no separate discoverability layer to strip (its
-- OWN registration in the visible options list IS the discoverability) --
-- the faithful translation of the same convention is therefore the one this
-- codebase ALREADY shipped for an identical visible-list merge,
-- client/tracking.lua's own Detection consolidation (client/radial.lua's
-- three former "Track Scent"/"Track Blood"/"Track Gunpowder" items are
-- GONE, replaced by one 'k9_track_certified' entry -- but StartScentTrack()/
-- StartBloodTrack()/StartGunpowderTrack() themselves SURVIVE, unchanged,
-- as still-callable resource-globals, reachable today via
-- client/tablet.lua's FEATURE_TRIGGERS table). Applied here identically:
-- the two former standalone visible entries ('qbx_k9unit:petK9',
-- 'qbx_k9unit:feedK9') are gone from RegisterMoodOxTargetOptions()'s own
-- table below, replaced by the one 'qbx_k9unit:careForK9' entry -- but
-- their exact former onSelect bodies survive UNCHANGED as `RequestPetK9()`/
-- `RequestFeedK9()`, resource-globals (no `local`) below, reachable by
-- anything that wants an UNAMBIGUOUS single action with no resolution step
-- (a future radial item, the tablet's FEATURE_TRIGGERS, or a later
-- reconsideration of this merge) without duplicating either action's own
-- validation. The real, load-bearing "entry point" this task's Rule 1 asks
-- to preserve -- the two SERVER callbacks another file or a modified client
-- could already depend on -- are untouched by this pass, full stop: not one
-- line of server/wellbeing.lua changed for this merge.
--
-- WHY drinkFromBowl DOES NOT JOIN THIS MERGE (confirmed against
-- server/wellbeing.lua's own drinkFromBowl handler before deciding, not
-- assumed): Pet/Feed are HANDLER-TO-K9 actions -- ANY player, targeting a
-- DIFFERENT player's K9 ped (`targetPed ~= usingPed` is enforced), the exact
-- "a genuine second player in the loop" bonding mechanic this file's own
-- "SELF-SERVICE, A DELIBERATE DIVERGENCE FROM MOOD" header section (further
-- down, HUNGER/THIRST) contrasts against. drinkFromBowl is SELF-ONLY -- the
-- ACTOR must themselves be a K9 (`ResolveK9Ped(src)`'s own `isK9` check
-- there requires the CALLER's ped, not a target's), relieving THEIR OWN
-- citizenid's thirst, and it targets a completely different ENTITY CLASS
-- (a world prop via `AddModel`, never a player ped via `AddGlobalPlayer`).
-- Concretely, this means drinkFromBowl NEVER actually stacks with Pet/Feed
-- in the first place -- a player looking at a K9's ped never saw "Drink
-- from Bowl" appear alongside "Pet K9"/"Feed K9" (they are options on TWO
-- DIFFERENT ENTITIES), so folding it into this merge would not remove one
-- real choice from the "stack of choices on a K9" this task describes --
-- there was no third choice stacking there to begin with. Forcing it in
-- would ALSO mean either (a) silently letting a HANDLER trigger a SELF-ONLY
-- K9 action on someone else's behalf (a real gating change this task's Rule
-- 2 forbids outright), or (b) inventing a brand-new "is a bowl near the
-- TARGET K9" server-side world scan this task's file scope was never asked
-- to build. Left exactly as it is, further down this file, as its own
-- single, already-unambiguous entry point on its own target.
--
-- ALWAYS REGISTERS, regardless of Config.Features.MoodSystem's boot-time
-- value: gating this entire block (including the ox_target registration
-- itself) on that static copy would mean a client who booted with
-- MoodSystem=false could never see "Care for K9" appear even after a
-- later runtime toggle-ON, for the rest of that client's session -- no
-- restart of THIS resource would help, since nothing client-side would be
-- left to ever call RegisterMoodOxTargetOptions() again. Per this file's
-- header "LIVE FEATURE FLAGS": registration always happens (cheap --
-- ox_target option registration is a one-time table build, not a poll),
-- and `canInteract` below gates on `LiveFeatureFlags.MoodSystem` (the
-- server's CURRENT flag state) instead of the static
-- `Config.Features.MoodSystem` this client shipped with -- exactly matching
-- client/featureblocks.lua's own established rule for this class of check
-- ("check at the point it acts, never merely at registration"). ox_target
-- calls `canInteract` fresh on every look, so a live flag flip is reflected
-- the very next time a player looks at a K9, with no registration-lifecycle
-- work needed on either side of the transition. UNCHANGED from the former
-- two-option shape: this is the exact same predicate both "Pet K9" and
-- "Feed K9" already used (confirmed identical before merging) -- the merged
-- option therefore appears in EXACTLY the same circumstances either of the
-- two former options did, never wider, never narrower.
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

    --- Raw round trip only, no notification -- shared by RequestPetK9()
    --- below and RequestCareForK9()'s own fallback path, so the exact same
    --- FAIL-CLOSED GUARD (see the doc comment this replaces, below) is
    --- written once, not copy-pasted per caller.
    --- @param targetServerId number
    --- @return table? result
    local function AttemptPetK9(targetServerId)
        -- FAIL-CLOSED GUARD: `lib.callback.await` throws rather than
        -- returning nil on a timeout/unregistered-callback rejection (see
        -- client/main.lua's HasK9Access() doc comment for the full
        -- citation). pcall it; every caller already treats a nil/falsy
        -- `result` as a silent no-op (NotifyResult's own
        -- `if not result then return end`), so a thrown failure degrades to
        -- that exact same, already-established path instead of aborting
        -- whichever onSelect/resolution handler called this uncaught.
        local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:petK9', K9_CALLBACK_TIMEOUT_MS, targetServerId)
        if not ok then result = nil end
        return result
    end

    --- Raw round trip only, no notification -- see AttemptPetK9's own doc
    --- comment immediately above for the shared FAIL-CLOSED reasoning.
    --- @param targetServerId number
    --- @return table? result
    local function AttemptFeedK9(targetServerId)
        local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:feedK9', K9_CALLBACK_TIMEOUT_MS, targetServerId)
        if not ok then result = nil end
        return result
    end

    --- Resource-global (no `local`) -- HIDDEN ALIAS for the former
    --- standalone "Pet K9" ox_target option: no longer independently
    --- registered below (folded into the merged "Care for K9" option), but
    --- this exact former onSelect body survives here, unchanged, reachable
    --- by anything that wants an unambiguous, no-resolution pet action --
    --- see this section's own header "HIDDEN ALIASES" note for the full
    --- precedent this follows (client/tracking.lua's
    --- StartScentTrack()/StartBloodTrack()/StartGunpowderTrack()).
    --- @param targetServerId number
    function RequestPetK9(targetServerId)
        NotifyResult(AttemptPetK9(targetServerId), locale('wellbeing.pet_success'))
    end

    --- Resource-global (no `local`) -- HIDDEN ALIAS for the former
    --- standalone "Feed K9" ox_target option. Same shape and same reasoning
    --- as RequestPetK9() immediately above.
    --- @param targetServerId number
    function RequestFeedK9(targetServerId)
        NotifyResult(AttemptFeedK9(targetServerId), locale('wellbeing.feed_success'))
    end

    --- THE MERGED ENTRY POINT. See this section's own header comment (above
    --- the `do` this lives inside) for the full "why Feed first, why this
    --- ONE fallback condition and no other" design writeup -- restated here
    --- only as the short, call-site version:
    ---
    --- Feed is attempted first (the strictly better outcome when possible).
    --- Exactly ONE fallback condition sends this to Pet instead:
    --- `feedResult.reason == 'no_item'` -- a WELL-FORMED, CONFIRMED answer
    --- from the server that the SPECIFIC thing blocking Feed was the missing
    --- item, nothing else. Every other outcome is reported directly, never
    --- triggering a second round trip:
    ---   - `feedResult.ok == true` -- Feed succeeded, done.
    ---   - any OTHER failure reason (`feature_disabled`/`invalid_target`/
    ---     `too_far`/`on_cooldown`) -- Pet would fail for the IDENTICAL
    ---     reason (both callbacks share `Config.Features.MoodSystem`,
    ---     `ResolveK9Ped`, `MOOD_INTERACT_RANGE`, and the same
    ---     `AffectionCooldown` instance/key -- confirmed by reading both
    ---     server-side callbacks directly before writing this) -- retrying
    ---     would be a guaranteed-redundant round trip for the exact same
    ---     verdict, not a genuine second chance.
    ---   - `feedResult == nil` (the round trip itself threw/timed out) --
    ---     no confirmed answer exists to act on; guessing that Pet would
    ---     have fared differently is not something this file's own
    ---     established FAIL-CLOSED discipline does anywhere else. Reported
    ---     via the same silent-no-op path NotifyResult already gives a nil
    ---     result (see the FAIL-CLOSED GUARD test coverage this mirrors).
    --- Neither branch can double-spend `AffectionCooldown`: Feed's own
    --- server-side check-before-touch ordering (server/wellbeing.lua's own
    --- feedK9 callback, confirmed by reading it directly) means a `no_item`
    --- failure NEVER stamps the cooldown, so Pet's own fresh cooldown check
    --- in the fallback path is judging real, untouched state, not state this
    --- same click already altered.
    --- @param targetServerId number
    function RequestCareForK9(targetServerId)
        local feedResult = AttemptFeedK9(targetServerId)

        if feedResult and feedResult.reason == 'no_item' then
            NotifyResult(AttemptPetK9(targetServerId), locale('wellbeing.pet_success'))
            return
        end

        NotifyResult(feedResult, locale('wellbeing.feed_success'))
    end

    -- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua),
    -- never a direct `exports.ox_target` call -- the canInteract/onSelect
    -- pair below is unchanged in shape (still authored against ox_target's
    -- own convention), so an operator running a different supported target
    -- script gets it translated automatically instead of losing it outright.
    --
    -- LIFECYCLE FIX: extracted into a named function, sole call site the
    -- AddEventHandler('onResourceStart', ...) below, so this option comes
    -- back after a bare restart of whatever resource actually backs the
    -- 'target' system, not just after this resource's own restart -- every
    -- supported target script keeps its own registry in a plain file-local
    -- Lua table inside its own client chunk, reloaded empty on THAT
    -- resource's own restart with nothing else prompting a re-add. Mirrors
    -- server/tracking.lua's RegisterScentInventoryHook /
    -- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for
    -- the identical bug class against ox_inventory. DUPLICATE-VS-REPLACE:
    -- the option below always sets `name`, and every adapter's own
    -- registration primitive dedups/replaces by that same name (or label,
    -- per shared/compat/target.lua's own per-adapter notes), so re-running
    -- this never duplicates the entry.
    local function RegisterMoodOxTargetOptions()
        K9Compat.Get('target').AddGlobalPlayer({
            {
                -- RENAMED from 'qbx_k9unit:petK9'/'qbx_k9unit:feedK9' (two
                -- separate entries) to this one merged name -- see this
                -- section's own header "HIDDEN ALIASES" note for why the
                -- OLD names are not kept as no-op registrations: an
                -- ox_target option has no "still reachable, just
                -- unadvertised" state the way a RegisterCommand call does,
                -- so the two former onSelect bodies survive as
                -- RequestPetK9()/RequestFeedK9() instead (above), not as
                -- dead, permanently-`canInteract=false` table entries.
                name = 'qbx_k9unit:careForK9',
                icon = 'fas fa-hand-holding-heart',
                label = locale('wellbeing.care_target_label'),
                distance = 3.0,
                canInteract = function(entity)
                    if not LiveFeatureFlags.MoodSystem then return false end
                    -- WIDENED (K9 role/model decoupling) with
                    -- IsK9RoleForPlayer(...) -- client/appearance.lua's own
                    -- per-target-cached (1s TTL) server round trip for
                    -- "does THAT player hold the K9 role" -- so a target on
                    -- a human/custom model who already holds the role can
                    -- still be cared for. Matches server/wellbeing.lua's own
                    -- ResolveK9Ped, which already accepts
                    -- (looksLikeK9 or holdsK9Role) server-side. UNCHANGED
                    -- from both former options' own identical predicate
                    -- (confirmed byte-identical before merging) -- this
                    -- option appears in exactly the same circumstances
                    -- either of them did.
                    return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
                end,
                onSelect = function(data)
                    local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                    if not targetServerId then return end

                    RequestCareForK9(targetServerId)
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
