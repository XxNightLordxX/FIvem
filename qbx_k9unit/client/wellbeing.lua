--[[
    qbx_k9unit/client/wellbeing.lua

    Phase 4 implementation. Client-side half of Config.Features.FatigueSystem
    / MoodSystem / FearStressSystem / DistractionSystem / InjuryLimping
    (PHASE4_SPEC.md §13.0 Decision 1, §13.3, §13.4.3). Receives the server's
    pushed wellbeing snapshots, sets the shared `K9MoveRateModifiers` entries
    for Fatigue/Injury/Mood (PHASE4_SPEC.md §13.0 Decision 2) and calls
    `RecomputeK9MoveRate()` (client/movement.lua), enforces the client-local
    sprint/jump input blocks for low Injury (a disclosed, bounded, self-
    applied limitation — see server/wellbeing.lua's header and PHASE4_SPEC.md
    §13.0 Decision 3, not a security boundary), and owns the "Pet K9"/
    "Feed K9" ox_target interactions plus the meat-bait/whistle/calm-down
    self-actions.

    Every one of the five wellbeing Config.Features flags is checked at the
    point of use below, not just declared — matching this file's own
    "no code needed when disabled" posture wherever a whole block can be
    skipped at file-load time (mirrors client/movement.lua's
    AgilityBasicJump precedent).

    NOTHING BELOW IS A SECURITY BOUNDARY. Every mutating action
    (pet/feed/calm-down/distraction-item-use) is re-validated server-side in
    server/wellbeing.lua regardless of what this file's own UI/gating
    thinks — the standard "client hides the option, server is the real
    gate" split this codebase applies everywhere (SPEC.md §4.1).

    DELIBERATELY NOT WIRED INTO client/radial.lua THIS PASS: PHASE4_SPEC.md
    §13.4.3.3 frames "Calm Down" as a radial command, but client/radial.lua
    is being actively worked on by a concurrent agent (AdvancedBarkRadial,
    Phase 5) this session — touching it here risks a collision with that
    work. Instead, this file exposes a plain resource-global,
    `RequestK9CalmDown()`, and registers a working `/k9calmdown` command as
    a real, usable-today entry point. Whoever next touches client/radial.lua
    should add a menu entry that calls `RequestK9CalmDown()` (or triggers
    'qbx_k9unit:server:calmDownK9' directly) rather than duplicating this
    file's validation.

    ======================================================================
    OX_TARGET API — same `addGlobalPlayer` shape already confirmed HIGH
    confidence against real ox_target source by client/medkit.lua this
    session (see that file's header) — not re-verified independently here,
    reused unchanged.

    EVENT/CALLBACK CONTRACT — see server/wellbeing.lua's header for the full
    contract; this file is the client side of every entry listed there.

    Commands (RegisterCommand):
    - '/k9calmdown' — self-only, gated on CanShowK9UI() + Config.Features.FearStressSystem.
      Triggers 'qbx_k9unit:server:calmDownK9'.
    - '/k9meatbait' / '/k9whistle' — deliberately NOT gated on CanShowK9UI():
      PHASE4_SPEC.md §13.4.3.4 open question 2 reads this as intentionally
      open to any player (a fleeing suspect using a whistle/meat-bait
      against a pursuing K9 is explicitly in-scope per that document's own
      framing), gated only on Config.Features.DistractionSystem and, for
      real, on server-side item possession.

    FILE-TO-FILE CONTRACT:
    - Reads/writes `K9MoveRateModifiers` and calls `RecomputeK9MoveRate()`,
      both resource-globals from client/movement.lua (PHASE4_SPEC.md §13.0
      Decision 2) — never calls `SetPedMoveRateOverride` directly.
    - Calls `IsOwnModelK9()`/`CanShowK9UI()`/`DenyK9UIAccess()`/
      `IsEntityModelK9(entity)`/`ResolvePlayerServerIdFromPed(entity)`,
      resource-globals from client/main.lua — reused, never re-derived.
      `IsEntityModelK9` (REFACTOR_ROADMAP.md item 3) replaces this file's
      own former local `K9ModelHashes` set (used to mirror
      client/medkit.lua's own precomputation exactly — a client-side
      display filter only, server/wellbeing.lua re-derives every target's
      real model server-side regardless). `ResolvePlayerServerIdFromPed`
      (REFACTOR_ROADMAP.md item 2b) replaces this file's own former local
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
    distractedUntil = 0,
    hesitatingUntil = 0,
}
local wasDistracted = false
local wasHesitating = false

--- Recomputes this file's three owned `K9MoveRateModifiers` slots from
--- `lastStats` and asks client/movement.lua's composer to recompute the
--- single real `SetPedMoveRateOverride` call. Only touches the slot for a
--- stat whose OWNING flag is enabled — a disabled stat's modifier is left
--- at whatever it already was (never forced to 1.0 by a flag this file
--- doesn't own the meaning of, though in practice a disabled stat's
--- `lastStats` value never moves from its healthy default anyway).
local function ApplyMoveRateModifiers()
    if Config.Features.FatigueSystem then
        if lastStats.fatigue < Config.Wellbeing.Fatigue.speedPenaltyThreshold then
            K9MoveRateModifiers.fatigue = Config.Wellbeing.Fatigue.speedPenaltyMultiplier
        else
            K9MoveRateModifiers.fatigue = 1.0
        end
    end

    if Config.Features.InjuryLimping then
        local injuryPenaltyThreshold = math.max(Config.Wellbeing.Injury.sprintBlockThreshold, Config.Wellbeing.Injury.jumpBlockThreshold)
        if lastStats.injury < injuryPenaltyThreshold then
            K9MoveRateModifiers.injury = Config.Wellbeing.Injury.speedPenaltyMultiplier
        else
            K9MoveRateModifiers.injury = 1.0
        end
    end

    if Config.Features.MoodSystem then
        if lastStats.mood < Config.Wellbeing.Mood.performancePenaltyThreshold then
            K9MoveRateModifiers.mood = Config.Wellbeing.Mood.performancePenaltyMultiplier
        else
            K9MoveRateModifiers.mood = 1.0
        end
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

    lastStats.fatigue = tonumber(stats.fatigue) or lastStats.fatigue
    lastStats.mood = tonumber(stats.mood) or lastStats.mood
    lastStats.fearStress = tonumber(stats.fearStress) or lastStats.fearStress
    lastStats.injury = tonumber(stats.injury) or lastStats.injury
    lastStats.distractedUntil = tonumber(stats.distractedUntil) or lastStats.distractedUntil
    lastStats.hesitatingUntil = tonumber(stats.hesitatingUntil) or lastStats.hesitatingUntil

    ApplyMoveRateModifiers()

    if Config.Features.DistractionSystem then
        local isDistractedNow = lastStats.distractedUntil > GetGameTimer()
        if isDistractedNow and not wasDistracted then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.distracted'), type = 'error' })
        elseif wasDistracted and not isDistractedNow then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.refocused'), type = 'info' })
        end
        wasDistracted = isDistractedNow
    end

    if Config.Features.FearStressSystem then
        local isHesitatingNow = lastStats.hesitatingUntil > GetGameTimer()
        if isHesitatingNow and not wasHesitating then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.hesitating'), type = 'error' })
        elseif wasHesitating and not isHesitatingNow then
            lib.notify({ title = locale('common.notify_title'), description = locale('wellbeing.settled'), type = 'info' })
        end
        wasHesitating = isHesitatingNow
    end
end

--- PHASE4_SPEC.md §13.4.3.1. Pure tick-driven consumer — server/wellbeing.lua's
--- header EVENT/CALLBACK CONTRACT item 8.
--- @param stats table
RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', function(stats)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- phase2_notes/RESEARCH_ARCHIVE.md#trust-boundary for the full writeup;
    -- not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:wellbeingUpdate', { fatigue = 999,
    -- ... })` would feed straight into ApplyWellbeingSnapshot() ->
    -- ApplyMoveRateModifiers()'s move-rate composer with zero server
    -- contact. Confidence: MEDIUM-HIGH, the official documented pattern
    -- for distinguishing a genuine server-sent event from a local
    -- self-trigger, not independently verified in-engine this pass.
    if source ~= 65535 then return end

    ApplyWellbeingSnapshot(stats)
end)

-- On-demand snapshot fetch on the moment this client's OWN ped becomes
-- K9-modeled — avoids up to Config.Wellbeing.tickIntervalMs of stale
-- defaults before the server's next automatic tick push. Cheap idle poll
-- otherwise; only runs at all if at least one wellbeing flag is enabled.
if Config.Features.FatigueSystem or Config.Features.MoodSystem
    or Config.Features.FearStressSystem or Config.Features.DistractionSystem
    or Config.Features.InjuryLimping then
    CreateThread(function()
        local wasK9 = false
        while true do
            local isK9 = IsOwnModelK9()
            if isK9 and not wasK9 then
                -- FAIL-CLOSED GUARD (dependency-verification finding, this
                -- pass): `lib.callback.await` throws on a timeout/
                -- unregistered-callback rejection rather than returning
                -- nil (see client/main.lua's HasK9Access() doc comment for
                -- the full citation against ox_lib's/FiveM's real source).
                -- This is a `while true do` thread -- an uncaught throw
                -- here would kill this entire loop permanently (until a
                -- resource restart), silently ending the on-demand
                -- snapshot fetch feature for the rest of this client's
                -- session. pcall it; `type(snapshot) == 'table'` below
                -- already treats a nil snapshot as "nothing to apply."
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
-- INJURY — client-local sprint/jump input blocks. PHASE4_SPEC.md
-- §13.4.3.5's own disclosed limitation: self-applied, not a security
-- boundary, same category as the speed-penalty modifier above (§13.0
-- Decision 3). Only started at all if InjuryLimping is enabled (no thread,
-- no cost, when disabled).
--
-- Control indices reuse client/movement.lua's own AgilityBasicJump
-- constants (HIGH confidence, standard/well-established GTA V control
-- mapping): 22 = INPUT_JUMP. INPUT_SPRINT = 21 is the standard,
-- widely-documented FiveM/GTA V control id for the sprint action — HIGH
-- confidence per common ecosystem knowledge, not independently re-verified
-- against a live client this session.
-- ======================================================================
if Config.Features.InjuryLimping then
    local INPUT_SPRINT = 21
    local INPUT_JUMP = 22

    CreateThread(function()
        while true do
            -- OWN-DEATH GUARD (coder-frontend correctness pass, earlier
            -- session): mirrors this codebase's own established "own ped
            -- death forces an active perception/effect feature to end"
            -- precedent (client/vision.lua's maintenance thread,
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
            -- IDLE-SPIN FIX (performance audit, this pass): the branch below
            -- used to take Wait(0) for the ENTIRE "alive and K9-modeled"
            -- case unconditionally, regardless of whether either threshold
            -- was actually crossed. With the shipped defaults
            -- (sprintBlockThreshold=30, jumpBlockThreshold=20 out of
            -- Injury.max=100), a HEALTHY K9 — injury anywhere in (30, 100],
            -- the overwhelmingly common case for the entire time InjuryLimping
            -- has anything to do — spun this thread at full per-frame rate
            -- forever, calling PlayerPedId/IsOwnModelK9 (-> GetEntityModel)/
            -- IsEntityDead roughly 180 times/second per K9 player, for the
            -- rest of that session, for zero gameplay effect: this is the
            -- DEFAULT case, not an edge case, unlike the dead-ped guard
            -- above (which correctly idles only the much rarer "currently
            -- dead" state). FIXED the same way that guard already
            -- established: only take Wait(0) — the cadence
            -- DisableControlAction's own contract genuinely requires while
            -- actively re-asserting a block — when at least one threshold is
            -- ACTUALLY crossed this tick; idle at the same coarse 1000ms
            -- otherwise. A healthy-to-injured transition can therefore take
            -- up to 1000ms to start being enforced (the same latency the
            -- dead-ped guard above already accepts for resuming enforcement
            -- after a respawn) — negligible against Config.Wellbeing
            -- .tickIntervalMs's own 5000ms default cadence for Injury to
            -- change at all, and this was never a security boundary to
            -- begin with (this section's own header, and PHASE4_SPEC.md
            -- §13.0 Decision 3).
            if IsOwnModelK9() and not IsEntityDead(PlayerPedId()) then
                local sprintBlocked = lastStats.injury < Config.Wellbeing.Injury.sprintBlockThreshold
                local jumpBlocked = lastStats.injury < Config.Wellbeing.Injury.jumpBlockThreshold
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
-- MOOD — "Pet K9" / "Feed K9" ox_target world interactions.
-- ======================================================================
if Config.Features.MoodSystem then
    -- ResolvePlayerServerIdFromPed(entity) used to be defined here as a
    -- local copy of client/medkit.lua's own function (deliberate per-file
    -- duplication at the time). Extracted to client/main.lua as a
    -- resource-global per REFACTOR_ROADMAP.md item 2b once both copies
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

    -- LIFECYCLE FIX (this pass): extracted into a named function, sole
    -- call site the AddEventHandler('onResourceStart', ...) below, so both
    -- options come back after a bare `restart ox_target`, not just after
    -- this resource's own restart -- ox_target keeps addGlobalPlayer's
    -- registry in a plain file-local Lua table inside its own client
    -- chunk (confirmed by reading ox_target's client/api.lua directly),
    -- reloaded empty on ox_target's own restart with nothing else
    -- prompting a re-add. Mirrors server/tracking.lua's
    -- RegisterScentInventoryHook / server/inventory.lua's
    -- RegisterK9InventoryItemFilterHook fixes for the identical bug class
    -- against ox_inventory. DUPLICATE-VS-REPLACE: both options below
    -- always set `name`, and ox_target's own `addTarget` unconditionally
    -- removes any existing option with the same name+resource before
    -- appending, so re-running this never duplicates either entry.
    local function RegisterMoodOxTargetOptions()
        exports.ox_target:addGlobalPlayer({
            {
                name = 'qbx_k9unit:petK9',
                icon = 'fas fa-hand-holding-heart',
                label = locale('wellbeing.pet_target_label'),
                distance = 3.0,
                canInteract = function(entity)
                    if not Config.Features.MoodSystem then return false end
                    return IsEntityModelK9(entity)
                end,
                onSelect = function(data)
                    local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                    if not targetServerId then return end

                    -- FAIL-CLOSED GUARD (dependency-verification finding,
                    -- this pass): `lib.callback.await` throws rather than
                    -- returning nil on a timeout/unregistered-callback
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
                    if not Config.Features.MoodSystem then return false end
                    return IsEntityModelK9(entity)
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
    -- the identical class of gap against ox_inventory. Kept inside this
    -- `if Config.Features.MoodSystem then` gate (not just inside
    -- canInteract) so a disabled MoodSystem never even defines this
    -- handler, matching this block's original config-gated-at-registration
    -- shape exactly.
    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName == GetCurrentResourceName() or resourceName == 'ox_target' then
            RegisterMoodOxTargetOptions()
        end
    end)
end

-- ======================================================================
-- FEARSTRESS — "Calm Down" self-action. See this file's header for why
-- this is a plain command + exported global rather than a client/radial.lua
-- menu entry this pass.
-- ======================================================================

--- Resource-global (no `local`) — a future radial menu entry should call
--- this rather than re-deriving its own validation.
function RequestK9CalmDown()
    if not Config.Features.FearStressSystem then return end
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    TriggerServerEvent('qbx_k9unit:server:calmDownK9')
end

RegisterCommand('k9calmdown', RequestK9CalmDown, false)

-- ======================================================================
-- DISTRACTION — meat-bait / whistle self-use. Deliberately open to ANY
-- player, not gated on CanShowK9UI() — see this file's header.
-- ======================================================================
if Config.Features.DistractionSystem then
    local function UseDistractionItem(itemType, failDescription)
        -- FAIL-CLOSED GUARD (dependency-verification finding, this pass;
        -- this call site was not in the originally reported list --
        -- re-grepping `lib.callback.await` across client/ this pass turned
        -- it up too): `lib.callback.await` throws rather than returning
        -- nil on a timeout/unregistered-callback rejection (see
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
