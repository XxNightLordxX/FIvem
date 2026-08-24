--[[
    qbx_k9unit/server/combat.lua

    Phase 3 implementation (coder-security), PHASE3_SPEC.md §12.5.1
    (Bite-and-Hold) and §12.5.2 (Non-lethal takedown), built under §12.0
    item 8's ("the client-relay/non-cooperating-target-client architecture
    problem") own resolution and its five binding guardrails — this file
    IS that resolution's implementation, not a separate design pass.
    `PropDragging` and `HandlerDownDefense` are OUT OF SCOPE for this file
    — see config.lua's own Config.Combat header comment for exactly why
    each is still blocked/deferred.

    ======================================================================
    HOW THIS FILE SATISFIES ITEM 8'S FIVE BINDING GUARDRAILS (read together
    with PHASE3_SPEC.md §12.0 item 8's own text, not a substitute for it):

    1. "The detection layer ... exists in real, tested code in
       server/combat.lua — not merely the config placeholder table." See
       NON-COMPLIANCE DETECTION below — a real, single, shared sampling
       thread, not a sketch.
    2. "PropDragging's AttachEntityToEntity call is re-asserted every
       tick..." — N/A, PropDragging is not implemented in this file.
    3. "No server-authoritative consequence of any kind may ever be
       conditioned on a Category B effect having been applied successfully
       to a player target." Confirmed true of every code path below: the
       compliance sampling loop below NEVER calls EndHold early, never
       denies a cooldown refund, never blocks a future request, and never
       feeds back into HasK9Access/RequireWantedStatus/any grant — it only
       logs/notifies via Config.Combat.NonComplianceDetection.action. The
       ONLY things gating whether a hold/takedown is granted at all are
       things this server independently verifies BEFORE ever applying a
       Category B effect (feature flag, HasK9Access, live proximity,
       RequireWantedStatus, cooldowns) — see ValidateCombatRequest below.
    4. "Every player-facing string... is worded as best-effort." See
       COMBAT_REJECT_MESSAGES and every NotifyPlayer call below — none
       claim the target "cannot escape" or "is restrained."
    5. "Config.Combat.RequireWantedStatus stays true by default... and
       Config.Combat.NonComplianceDetection.action stays 'log'/
       'notify_staff' by default" — see config.lua; this file only ever
       reads those values, it never overrides them.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT (client<->server, PHASE3_SPEC.md §12.5.1/
    §12.5.2/§12.0 item 8):

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:requestBiteHold' (targetNetId: number)
    - 'qbx_k9unit:server:releaseBiteHold' ()
    - 'qbx_k9unit:server:requestTakedown' (targetNetId: number)

    Client events (server->client), registered by client/combat.lua:
    - 'qbx_k9unit:client:applyBiteHold' (holderNetId: number, expiresAt: number)
      Sent ONLY to the target's own client (never a broadcast) — the
      Category B relay itself. See client/combat.lua's own header for why
      this is registered UNCONDITIONALLY on every client, and why it is
      honestly best-effort against a hostile client (§12.0 item 8).
    - 'qbx_k9unit:client:endBiteHold' (reason: string)
      Sent ONLY to the target's own client — early release/timeout signal
      so DisableControlAction stops before its own local expiresAt.
    - 'qbx_k9unit:client:biteHoldStarted' (targetNetId: number, expiresAt: number)
      Sent ONLY to the HOLDING K9's own client — starts its own local
      cosmetic stance. This is a self-applied, Category-A-equivalent
      effect (the K9's own ped, driven by its own client — no relay
      problem), unrelated to item 8's Category B concern.
    - 'qbx_k9unit:client:biteHoldEnded' (targetNetId: number, reason: string)
      Sent ONLY to the holding K9's own client.
    - 'qbx_k9unit:client:forceRagdoll' (expiresAt: number)
      Sent ONLY to the target's own client — Category B relay for
      NonLethalTakedown, same posture as applyBiteHold above.
    - 'qbx_k9unit:client:endForceRagdoll' (reason: string)
      Sent ONLY to the target's own client — restores
      SetEntityCanBeDamaged(true) on that client's own ped before/at
      expiresAt.

    No anim-dictionary/TASK_PLAY_ANIM asset is used for BiteAndHold in this
    pass — phase2_notes/phase3_combat_natives.md's own §1 write-up flags
    the one candidate clip (`creatures@rottweiler@melee@streamed_core@` /
    `takedown_from_back`) as MEDIUM confidence, one-shot (not a sustained
    hold loop), model-specific to the Rottweiler only, and explicitly
    "needs actual in-engine testing... a design/asset call for
    coder-frontend once someone has direct game access." Resolving that
    asset question is out of scope for a security-lens implementation pass
    — client/combat.lua instead reuses the ALREADY-CONFIRMED
    `WORLD_DOG_BARKING_*` aggressive-stance scenario (per that same note's
    own option (a)) as a safe, already-shipped-elsewhere placeholder for
    the K9's own visual during a hold. Flagged here, not silently decided:
    revisit once coder-frontend has previewed the takedown clip in-engine.
    NonLethalTakedown needs no new asset at all (fully native-only per that
    same note's §2).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls HasK9Access(source) (server/certifications.lua) and
      ResolveNetworkEntity(netId, expectedEntityType?) (server/entities.lua)
      — does not re-implement either.
    - Calls NewCooldown()/NewMutex() (server/cooldowns.lua) — every
      cooldown/in-flight-guard below is one of these constructors, never a
      hand-rolled table, per REFACTOR_ROADMAP.md item 1's own standing
      convention for this resource.
    - Loaded in fxmanifest.lua's server_scripts after cooldowns.lua,
      entities.lua, and certifications.lua (all three are load-time
      dependencies of this file).
    ======================================================================

    PLAYER-VS-NPC RESOLUTION — DELIBERATE DEVIATION FROM PHASE3_SPEC.md'S
    OWN INFORMAL PROSE, flagged explicitly rather than silently diverging:
    §12.5.1/§12.5.2/§12.0 item 8's prose names `IsPedAPlayer(targetPed)` as
    the resolution mechanism. This file instead reuses
    `ResolveConnectedPlayerFromPed(entity)` — the SAME pattern
    server/search.lua's own security-reviewed
    `contraband_search_security_review.md`-driven implementation already
    uses for the identical fact ("does this entity belong to a real,
    currently-connected player?"), for the SAME reason that file's own
    header gives: `IsPedAPlayer`/`NetworkGetPlayerIndexFromPed` combos were
    never independently confirmed reliable SERVER-side in this codebase's
    own native-verification passes (phase2_notes/phase3_combat_natives.md
    does not list `IS_PED_A_PLAYER` in its confirmed-natives table for
    either feature at all), whereas the `GetPlayers()`/`GetPlayerPed(id)`
    scan is already proven reliable server-side elsewhere in this exact
    codebase. This is a strictly more conservative choice (it can only
    ever resolve to an entity that IS some connected player's own ped) and
    gets both facts (is-a-player, AND that player's own server id) from
    one already-trusted mechanism instead of two natives of differing
    verified reliability. Duplicated here (not extracted to
    server/entities.lua) since this is the SECOND independent call site for
    this exact helper — worth flagging to coder-architect as a
    REFACTOR_ROADMAP-style extraction candidate now that there are two, not
    mandated by this pass.
    ======================================================================

    NON-COMPLIANCE DETECTION (PHASE3_SPEC.md §12.0 item 8, point 2) — real,
    implemented sampling, not a sketch. One shared maintenance thread (never
    one thread per active effect, mirroring server/tracking.lua's
    PruneTrackableLogs single-pass-over-a-shared-table discipline) does TWO
    jobs on every tick of MAINTENANCE_INTERVAL_MS below:
      (a) enforces every active hold/ragdoll's hard expiresAt cap —
          ALWAYS, regardless of Config.Combat.NonComplianceDetection.enabled
          — this is item 4's "no unbounded trap" guarantee and must never
          be gated behind the detection feature flag;
      (b) IF NonComplianceDetection.enabled, samples the target's live,
          server-authoritative position (GetEntityCoords — NEVER a
          client-reported value) and applies the PER-EFFECT heuristic
          PHASE3_SPEC.md §12.0 item 8 specifies:
            - BiteAndHold: near-stationary check, flagged only after
              `biteHoldViolationSamples` CONSECUTIVE over-threshold
              samples (never a single noisy sample — server/tracking.lua's
              own FORGED TRAIL DECISION reasoning against auto-punishing on
              one noisy signal applies here too).
            - NonLethalTakedown: net displacement from the ragdoll-open
              baseline position, NOT a continuous speed check (a genuine
              ragdoll produces noisy, non-directional per-tick velocity a
              speed check would false-positive on).
      DISCLOSED SIMPLIFICATION vs. item 8's fuller text: item 8's own
      writeup additionally asks for "a sustained consistent heading rather
      than random tumbling drift" as the stronger tell for takedown. This
      pass implements the simpler, honestly-weaker "net displacement past a
      flat threshold" half of that only — full heading-consistency
      discrimination (distinguishing a directed walk-away from a scripted
      knockdown from random tumbling scatter) is NOT implemented here.
      This is a disclosed narrowing of a NON-PUNITIVE, log-only heuristic,
      not a silent gap — flagged for whoever next tunes this table to
      decide whether the added complexity is worth it before this feature
      is ever enabled on a live server.
    On a flagged violation: always printed (the 'log' baseline, per
    Config.Combat.NonComplianceDetection.action's own doc comment — 'log'
    cannot mean "don't log"); ADDITIONALLY alerts any currently-connected
    player holding the 'command' ACE permission via an ox_lib notify when
    action == 'notify_staff' (a generic, ecosystem-standard staff-permission
    convention — this resource assumes no particular admin resource exists,
    per SPEC.md §2's "exports/events exposed so integration is possible, no
    particular external resource assumed" posture, same as
    WantedStatusCheckOverride/IsPlayerDownedOverride elsewhere in this
    codebase). Config.Combat.NonComplianceDetection.OnViolationOverride, if
    supplied, is ALWAYS invoked on a flagged violation (pcall-wrapped,
    logged-not-thrown on error) regardless of `action`'s value — it is an
    independent, additive opt-in hook, not a gate on the built-in log/
    notify_staff behavior.
    NEVER auto-kick/auto-ban, never any effect on this resource's own
    server-authoritative state (guardrail 3 above) — detection only.
    ======================================================================
]]

-- Ephemeral, in-memory only (mirrors server/main.lua's LeashPairs and
-- server/tracking.lua's own precedent — live-session data, not account
-- data, does not survive a resource restart, and does not need to).
-- Keyed by the TARGET'S network id (stable regardless of whether the
-- target is an NPC ped or a live player's own ped) — one entry per
-- currently-held/ragdolled target, never more than one at a time per
-- target (enforced by the 'already_held' check below).
--
-- ActiveHolds[targetNetId] = {
--     effectType   = 'bite' | 'takedown',
--     holderSrc    = number,           -- the K9 player's own source
--     holderNetId  = number,           -- the K9 ped's own netId, for the Category B relay payload
--     isPlayerTarget = boolean,        -- resolved server-side via ResolveConnectedPlayerFromPed, NEVER client-claimed
--     targetSrc    = number?,          -- present only when isPlayerTarget
--     startedAt    = number,           -- GetGameTimer() at open
--     expiresAt    = number,           -- GetGameTimer() hard cap -- PHASE3_SPEC.md §12.0 item 4's "no unbounded trap" guarantee
--     compliance   = { ... },          -- see NON-COMPLIANCE DETECTION above; shape differs slightly per effectType, see the two sampling branches below
-- }
local ActiveHolds = {}

-- K9ActiveEffect[holderSrc] = targetNetId -- "one hold at a time per K9"
-- (PHASE3_SPEC.md §12.5.1: "One hold at a time per K9"), enforced across
-- BOTH BiteAndHold and NonLethalTakedown (a single K9 engaging one target
-- at a time, not one slot per effect type) -- also lets releaseBiteHold
-- resolve its own target without a linear scan of ActiveHolds.
local K9ActiveEffect = {}

local BiteHoldCooldown = NewCooldown(Config.Combat.BiteAndHold.cooldownMs)
BiteHoldCooldown.RegisterPlayerDropped()

local TakedownCooldown = NewCooldown(Config.Combat.NonLethalTakedown.cooldownMs)
TakedownCooldown.RegisterPlayerDropped()

-- Keyed by targetNetId, NOT a player source -- no per-connection cleanup
-- hook exists for this key domain (mirrors server/search.lua's
-- TargetSearchCooldown, keyed by a resolved plate/citizenid string for the
-- exact same reason). Swept periodically below rather than relying on
-- RegisterPlayerDropped.
local TakedownTargetCooldown = NewCooldown(Config.Combat.NonLethalTakedown.targetCooldownMs)

-- Guards the SHORT yield inside HandleTakedownRequest (the server-computed
-- speed-sample window) against the SAME K9 firing a second overlapping
-- requestTakedown before the first one's wait resolves -- mirrors
-- server/search.lua's SearchMutex exactly (same "reject outright, never
-- queue/race a concurrent call from the same source" rationale), needed
-- here specifically because, unlike requestBiteHold, requestTakedown's
-- handler yields (Wait(...)) before completing.
local TakedownMutex = NewMutex()
TakedownMutex.RegisterPlayerDropped()

local TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS = 60000
TakedownTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (Config.Combat.NonLethalTakedown.targetCooldownMs * 2)
end)

--- Sends an ox_lib notification to a specific player. Duplicated (not
--- shared) per server/main.lua's own NotifyPlayer precedent — a tiny,
--- generic UI-plumbing helper, not logic that must stay a single source of
--- truth.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    TriggerClientEvent('ox_lib:notify', target, {
        title = 'K9 Unit',
        description = description,
        type = notifyType or 'inform',
    })
end

--- Resolves a ped entity to the currently-connected player's server id it
--- belongs to, or nil if it doesn't belong to any currently-connected
--- player (an NPC, or a stale/despawned handle). See this file's header
--- "PLAYER-VS-NPC RESOLUTION" block for why this exact pattern (not
--- IsPedAPlayer) was chosen — duplicated from server/search.lua's own
--- ResolveConnectedPlayerFromPed, same implementation, same reasoning.
--- @param entity number
--- @return number? targetServerId
local function ResolveConnectedPlayerFromPed(entity)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if playerId and GetPlayerPed(playerId) == entity then
            return playerId
        end
    end
    return nil
end

--- PHASE3_SPEC.md §12.0 item 5. Never trusts a client-supplied "I am
--- wanted" (or "that target is wanted") claim — always reads server-side
--- state for `targetSrc` itself. FAILS CLOSED (returns false) if
--- Config.Combat.WantedStatusCheckOverride is supplied but errors — a
--- broken override must never silently widen who can be targeted.
--- @param targetSrc number
--- @return boolean eligible
local function IsPlayerWantedEligible(targetSrc)
    if not Config.Combat.RequireWantedStatus then return true end

    local override = Config.Combat.WantedStatusCheckOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, targetSrc)
        if not ok then
            print(('[qbx_k9unit] Config.Combat.WantedStatusCheckOverride errored for source %s: %s -- failing closed (target treated as NOT eligible)'):format(targetSrc, tostring(result)))
            return false
        end
        return result == true
    end

    -- Default best-effort check -- see config.lua's own comment on this
    -- field for the confidence caveat (LOWER confidence than
    -- PropDragging's equivalent default, per PHASE3_SPEC.md §12.0 item 5).
    local player = exports.qbx_core:GetPlayer(targetSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) ~= 'table' then return false end
    return metadata.wanted == true or metadata.iswanted == true
end

--- Best-effort, non-restraint-implying rejection copy (guardrail 4) —
--- shared between BiteAndHold and NonLethalTakedown since their reason
--- vocabularies overlap almost entirely.
local COMBAT_REJECT_MESSAGES = {
    feature_disabled   = 'This feature is disabled on this server.',
    invalid_target     = 'Invalid target.',
    no_access          = 'You are not certified for K9 duty.',
    already_engaged    = 'You are already engaged with another target.',
    offline            = 'Unable to resolve your own K9.',
    self_target        = 'You cannot target yourself.',
    target_dead        = 'That target is down.',
    too_far            = 'You are too far from the target.',
    already_held       = 'That target is already held by another K9.',
    not_eligible_target = 'That target is not currently eligible.',
    not_fleeing        = 'The target does not appear to be fleeing.',
    on_cooldown        = 'You must wait before attempting that again.',
}

--- @param reason string?
--- @return string
local function CombatRejectMessage(reason)
    return COMBAT_REJECT_MESSAGES[reason] or 'Unable to complete that action.'
end

--- Shared request-time validation for BOTH BiteAndHold and
--- NonLethalTakedown — PHASE3_SPEC.md §12.5.1/§12.5.2's own contract
--- blocks specify an identical validation prefix for both
--- (`requestBiteHold`/`requestTakedown`'s own doc text: "re-validates ...
--- HasK9Access(source), live proximity ..., resolves player-vs-NPC ...,
--- and — if the target is a player — RequireWantedStatus"). Feature-flag
--- and range are passed in since those two differ per effect; everything
--- else here is identical.
---
--- PROXIMITY-BEFORE-MUTATION: this function performs ZERO mutation
--- (no cooldown Touch/Consume, no ActiveHolds write) — every check here is
--- read-only, matching this codebase's established bar (server/main.lua's
--- CheckLeashEligibility, server/search.lua's HandleSearchTarget) of
--- resolving every read-only precondition before a single state mutation
--- happens. Cooldown consumption and ActiveHolds mutation both happen at
--- the call site, strictly after this returns ok == true.
--- @param src number
--- @param targetNetId any
--- @param featureEnabled boolean
--- @param rangeMeters number
--- @return boolean ok
--- @return number? k9Ped
--- @return number? targetPed
--- @return boolean? isPlayerTarget
--- @return number? targetSrc
--- @return string? reason
local function ValidateCombatRequest(src, targetNetId, featureEnabled, rangeMeters)
    if not featureEnabled then
        return false, nil, nil, nil, nil, 'feature_disabled'
    end

    if type(targetNetId) ~= 'number' then
        return false, nil, nil, nil, nil, 'invalid_target'
    end

    if not HasK9Access(src) then
        return false, nil, nil, nil, nil, 'no_access'
    end

    if K9ActiveEffect[src] then
        return false, nil, nil, nil, nil, 'already_engaged'
    end

    local k9Ped = GetPlayerPed(src)
    if k9Ped == 0 then
        return false, nil, nil, nil, nil, 'offline' -- defensive: src disconnected between the event firing and this line
    end

    -- expectedEntityType = 1 (ped) -- see server/entities.lua's
    -- ResolveNetworkEntity doc comment for the GetEntityType numbering.
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then
        return false, nil, nil, nil, nil, 'invalid_target'
    end

    if targetPed == k9Ped then
        return false, nil, nil, nil, nil, 'self_target'
    end

    if IsEntityDead(targetPed) then
        return false, nil, nil, nil, nil, 'target_dead'
    end

    -- Live server-side proximity — NEVER a client-claimed distance.
    local dist = #(GetEntityCoords(k9Ped) - GetEntityCoords(targetPed))
    if dist > rangeMeters then
        return false, nil, nil, nil, nil, 'too_far'
    end

    if ActiveHolds[targetNetId] then
        return false, nil, nil, nil, nil, 'already_held'
    end

    -- Player-vs-NPC resolution — see this file's header for why this is
    -- ResolveConnectedPlayerFromPed, not IsPedAPlayer.
    local targetSrc = ResolveConnectedPlayerFromPed(targetPed)
    local isPlayerTarget = targetSrc ~= nil

    if isPlayerTarget and not IsPlayerWantedEligible(targetSrc) then
        return false, nil, nil, nil, nil, 'not_eligible_target'
    end

    return true, k9Ped, targetPed, isPlayerTarget, targetSrc
end

--- Shared teardown for BOTH effect types — release, timeout, or
--- disconnect all funnel through here so there is exactly one place that
--- mutates ActiveHolds/K9ActiveEffect on the way out (mirrors
--- server/main.lua's own doDetachLeash "there is exactly one place that
--- mutates LeashPairs on detach" discipline).
--- @param targetNetId number
--- @param reason string
local function EndHold(targetNetId, reason)
    local hold = ActiveHolds[targetNetId]
    if not hold then return end

    ActiveHolds[targetNetId] = nil
    if K9ActiveEffect[hold.holderSrc] == targetNetId then
        K9ActiveEffect[hold.holderSrc] = nil
    end

    if hold.isPlayerTarget then
        -- Category B teardown relay -- best-effort, same posture as the
        -- apply side (PHASE3_SPEC.md §12.0 item 8). If the target's client
        -- ignored the apply event in the first place, it will almost
        -- certainly ignore this one too — that is an accepted, disclosed
        -- limitation (item 8's own guardrail 3 is exactly why nothing
        -- server-authoritative depends on this succeeding).
        if hold.effectType == 'bite' then
            TriggerClientEvent('qbx_k9unit:client:endBiteHold', hold.targetSrc, reason)
        else
            TriggerClientEvent('qbx_k9unit:client:endForceRagdoll', hold.targetSrc, reason)
        end
    else
        -- NPC target: this server (or the K9's own client, per the file
        -- plan) already fully commands this entity — restore directly,
        -- no relay problem.
        local targetPed = ResolveNetworkEntity(targetNetId, 1)
        if targetPed then
            if hold.effectType == 'bite' then
                SetBlockingOfNonTemporaryEvents(targetPed, false)
            else
                SetEntityCanBeDamaged(targetPed, true)
            end
        end
    end

    if hold.effectType == 'bite' then
        TriggerClientEvent('qbx_k9unit:client:biteHoldEnded', hold.holderSrc, targetNetId, reason)
    elseif reason ~= 'timeout' then
        -- Takedown has no manual "release" action (PHASE3_SPEC.md §12.5.2
        -- lists no release event) — only notify the K9 for a non-timeout
        -- reason (e.g. the target disconnecting mid-ragdoll); a plain
        -- timeout is the expected, silent end of a successful takedown.
        NotifyPlayer(hold.holderSrc, 'The takedown ended early.', 'inform')
    end
end

--[[ ================= NON-COMPLIANCE DETECTION ================= ]]

--- @param hold table -- an ActiveHolds entry
--- @param targetNetId number
--- @param kind string
--- @param detail string -- already human-formatted; see call sites
local function FlagNonCompliance(hold, targetNetId, kind, detail)
    local cfg = Config.Combat.NonComplianceDetection
    local targetLabel = hold.isPlayerTarget
        and ('player source ' .. tostring(hold.targetSrc))
        or ('NPC netId ' .. tostring(targetNetId))

    -- 'log' is the BASELINE, always-on behavior -- 'log' cannot mean
    -- "don't log." This print is the forensic record regardless of
    -- `action`'s value.
    print(('[qbx_k9unit] NON-COMPLIANCE (detection-only, NEVER punitive) kind=%s effect=%s target=%s holderSrc=%s detail=%s')
        :format(kind, hold.effectType, targetLabel, tostring(hold.holderSrc), detail))

    if cfg.action == 'notify_staff' then
        local message = ('K9 non-compliance: %s (%s) — %s'):format(kind, targetLabel, detail)
        for _, playerIdStr in ipairs(GetPlayers()) do
            local playerId = tonumber(playerIdStr)
            if playerId and IsPlayerAceAllowed(tostring(playerId), 'command') then
                TriggerClientEvent('ox_lib:notify', playerId, {
                    title = 'K9 Unit — Non-Compliance',
                    description = message,
                    type = 'warning',
                    duration = 8000,
                })
            end
        end
    end

    if type(cfg.OnViolationOverride) == 'function' then
        -- Independent, additive opt-in hook -- invoked regardless of
        -- `action`'s own value (see this file's header). pcall-wrapped:
        -- an error in a server owner's own override must never interrupt
        -- sampling for OTHER active holds in the same maintenance tick.
        local ok, err = pcall(cfg.OnViolationOverride, hold.targetSrc, hold.effectType, {
            kind = kind,
            detail = detail,
            targetNetId = targetNetId,
            isPlayerTarget = hold.isPlayerTarget,
        })
        if not ok then
            print(('[qbx_k9unit] Config.Combat.NonComplianceDetection.OnViolationOverride errored: %s'):format(tostring(err)))
        end
    end
end

--- One sampling pass for a single active hold. Never mutates ActiveHolds
--- itself beyond the hold's own `compliance` sub-record — see this file's
--- header for the full per-effect heuristic writeup.
--- @param targetNetId number
--- @param hold table
--- @param now number
local function SampleCompliance(targetNetId, hold, now)
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then return end -- gone/despawned; the maintenance loop's own expiry/disconnect cleanup handles teardown, not this function

    local cfg = Config.Combat.NonComplianceDetection
    local compliance = hold.compliance
    local currentPos = GetEntityCoords(targetPed)

    if hold.effectType == 'bite' then
        local dtSeconds = (now - compliance.lastTime) / 1000.0
        if dtSeconds > 0 then
            local observedSpeed = #(currentPos - compliance.lastPos) / dtSeconds
            local ceiling = cfg.biteHoldIdleCeiling + cfg.biteHoldSpeedTolerance
            if observedSpeed > ceiling then
                compliance.consecutiveViolations = compliance.consecutiveViolations + 1
            else
                compliance.consecutiveViolations = 0
            end

            if not compliance.flagged and compliance.consecutiveViolations >= cfg.biteHoldViolationSamples then
                compliance.flagged = true -- single-shot per hold -- do not re-flag every sample for the rest of the same window
                FlagNonCompliance(hold, targetNetId, 'bite_hold_movement',
                    ('observedSpeed=%.2fm/s ceiling=%.2fm/s consecutiveSamples=%d'):format(observedSpeed, ceiling, compliance.consecutiveViolations))
            end
        end
    else -- 'takedown'
        -- Net displacement from the ragdoll-open baseline, NOT a
        -- continuous speed check — see this file's header for why, and for
        -- the disclosed "heading consistency not implemented" narrowing.
        local netDisplacement = #(currentPos - compliance.baselinePos)
        if not compliance.flagged and netDisplacement > cfg.takedownNetDisplacementMeters then
            compliance.flagged = true
            FlagNonCompliance(hold, targetNetId, 'takedown_displacement',
                ('netDisplacement=%.2fm threshold=%.2fm'):format(netDisplacement, cfg.takedownNetDisplacementMeters))
        end
    end

    compliance.lastPos = currentPos
    compliance.lastTime = now
end

-- Single shared maintenance thread — see this file's header for why this
-- is ALWAYS running (expiry enforcement, job (a)) regardless of whether
-- detection sampling (job (b)) is enabled. A fixed interval, deliberately
-- NOT derived from Config.Combat.NonComplianceDetection.positionSampleWindowMs
-- — expiry (the "no unbounded trap" guarantee) must never be delayed by a
-- large/misconfigured detection-sampling interval.
local MAINTENANCE_INTERVAL_MS = 500

CreateThread(function()
    while true do
        Wait(MAINTENANCE_INTERVAL_MS)
        local now = GetGameTimer()

        for targetNetId, hold in pairs(ActiveHolds) do
            if now >= hold.expiresAt then
                EndHold(targetNetId, 'timeout')
            elseif Config.Combat.NonComplianceDetection.enabled then
                local ok, err = pcall(SampleCompliance, targetNetId, hold, now)
                if not ok then
                    print(('[qbx_k9unit] combat compliance sampling errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            end
        end
    end
end)

--[[ ================= BITE-AND-HOLD ================= ]]

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestBiteHold', function(targetNetId)
    local src = source

    local ok, k9Ped, targetPed, isPlayerTarget, targetSrc, reason =
        ValidateCombatRequest(src, targetNetId, Config.Features.BiteAndHold, Config.Combat.BiteAndHold.range)
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason), 'error')
        return
    end

    if not BiteHoldCooldown.Consume(src, Config.Combat.BiteAndHold.cooldownMs) then
        NotifyPlayer(src, CombatRejectMessage('on_cooldown'), 'error')
        return
    end

    local now = GetGameTimer()
    local expiresAt = now + Config.Combat.BiteAndHold.maxDurationMs
    local k9NetId = NetworkGetNetworkIdFromEntity(k9Ped)

    ActiveHolds[targetNetId] = {
        effectType     = 'bite',
        holderSrc      = src,
        holderNetId    = k9NetId,
        isPlayerTarget = isPlayerTarget,
        targetSrc      = targetSrc,
        startedAt      = now,
        expiresAt      = expiresAt,
        compliance = {
            lastPos               = GetEntityCoords(targetPed),
            lastTime              = now,
            consecutiveViolations = 0,
            flagged               = false,
        },
    }
    K9ActiveEffect[src] = targetNetId

    if isPlayerTarget then
        -- Category B relay -- PHASE3_SPEC.md §12.0 item 8. Sent ONLY to
        -- the target's own client, never a broadcast.
        TriggerClientEvent('qbx_k9unit:client:applyBiteHold', targetSrc, k9NetId, expiresAt)
    else
        -- NPC target: this server already fully commands this entity, no
        -- relay problem — PHASE3_SPEC.md §12.5.1.
        SetBlockingOfNonTemporaryEvents(targetPed, true)
        SetPedFleeAttributes(targetPed, 0, false)
    end

    TriggerClientEvent('qbx_k9unit:client:biteHoldStarted', src, targetNetId, expiresAt)
    -- BEST-EFFORT WORDING (guardrail 4) -- never claims the target cannot
    -- escape.
    NotifyPlayer(src, 'Bite and hold attempted — restraint is not guaranteed against an uncooperative target.', 'inform')
end)

RegisterNetEvent('qbx_k9unit:server:releaseBiteHold', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if not targetNetId then return end

    local hold = ActiveHolds[targetNetId]
    if not hold or hold.effectType ~= 'bite' or hold.holderSrc ~= src then return end

    EndHold(targetNetId, 'released')
end)

--[[ ================= NON-LETHAL TAKEDOWN ================= ]]

--- Core takedown logic, wrapped in pcall by the event handler below
--- (mirrors server/search.lua's HandleSearchTarget/searchTarget split) so
--- an unexpected runtime error can never leave TakedownMutex held or
--- K9ActiveEffect/ActiveHolds in an inconsistent state.
--- @param src number
--- @param targetNetId any
local function HandleTakedownRequest(src, targetNetId)
    local ok, k9Ped, targetPed, isPlayerTarget, targetSrc, reason =
        ValidateCombatRequest(src, targetNetId, Config.Features.NonLethalTakedown, Config.Combat.NonLethalTakedown.range)
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason), 'error')
        return
    end

    -- Cooldowns CHECKED (not yet consumed) before the yield below — actual
    -- Consume happens only after re-validation post-yield, so a request
    -- that ultimately fails the speed gate never burns either cooldown.
    if TakedownCooldown.IsOnCooldown(src, Config.Combat.NonLethalTakedown.cooldownMs)
        or TakedownTargetCooldown.IsOnCooldown(targetNetId, Config.Combat.NonLethalTakedown.targetCooldownMs) then
        NotifyPlayer(src, CombatRejectMessage('on_cooldown'), 'error')
        return
    end

    -- SERVER-COMPUTED SPEED GATE — PHASE3_SPEC.md §12.5.2 / §12.0 item 8's
    -- "rolling speed history per targetable entity" open item, resolved
    -- NARROWLY this pass: a short, bounded, two-sample measurement window
    -- taken at request time, rather than a continuously-running per-ped
    -- tracker scanning every pool ped every tick. See
    -- config.lua's own Config.Combat.NonLethalTakedown.speedSampleWindowMs
    -- comment for the full rationale and the explicit "revisit if a fuller
    -- continuous tracker is wanted" note. NEVER a client-claimed "I am
    -- sprinting" flag.
    local basePos = GetEntityCoords(targetPed)
    Wait(Config.Combat.NonLethalTakedown.speedSampleWindowMs)

    -- RE-VALIDATE EVERYTHING after the yield — TOCTOU discipline already
    -- established elsewhere in this resource (server/search.lua's own
    -- "RE-CHECK HasK9Access(source) NOW, immediately after the awaited
    -- ox_inventory call" precedent). Anything could have changed during
    -- the wait: the K9's own access, proximity, the target already being
    -- held by someone else, or the target's own eligibility.
    local ok2, k9Ped2, targetPed2, isPlayerTarget2, targetSrc2, reason2 =
        ValidateCombatRequest(src, targetNetId, Config.Features.NonLethalTakedown, Config.Combat.NonLethalTakedown.range)
    if not ok2 then
        NotifyPlayer(src, CombatRejectMessage(reason2), 'error')
        return
    end

    local afterPos = GetEntityCoords(targetPed2)
    local dtSeconds = Config.Combat.NonLethalTakedown.speedSampleWindowMs / 1000.0
    local observedSpeed = dtSeconds > 0 and (#(afterPos - basePos) / dtSeconds) or 0.0
    if observedSpeed < Config.Combat.NonLethalTakedown.minTargetSpeed then
        NotifyPlayer(src, CombatRejectMessage('not_fleeing'), 'error')
        return
    end

    if not TakedownCooldown.Consume(src, Config.Combat.NonLethalTakedown.cooldownMs)
        or not TakedownTargetCooldown.Consume(targetNetId, Config.Combat.NonLethalTakedown.targetCooldownMs) then
        -- Extremely narrow race: something else consumed one of these
        -- cooldowns during the wait above despite the pre-check. Fail
        -- closed rather than apply a takedown with an inconsistent
        -- cooldown state.
        NotifyPlayer(src, CombatRejectMessage('on_cooldown'), 'error')
        return
    end

    local now = GetGameTimer()
    local expiresAt = now + Config.Combat.NonLethalTakedown.ragdollDurationMs
    local k9NetId = NetworkGetNetworkIdFromEntity(k9Ped2)

    ActiveHolds[targetNetId] = {
        effectType     = 'takedown',
        holderSrc      = src,
        holderNetId    = k9NetId,
        isPlayerTarget = isPlayerTarget2,
        targetSrc      = targetSrc2,
        startedAt      = now,
        expiresAt      = expiresAt,
        compliance = {
            baselinePos = afterPos,
            lastPos     = afterPos,
            lastTime    = now,
            flagged     = false,
        },
    }
    K9ActiveEffect[src] = targetNetId

    if isPlayerTarget2 then
        -- Category B relay -- PHASE3_SPEC.md §12.0 item 8.
        TriggerClientEvent('qbx_k9unit:client:forceRagdoll', targetSrc2, expiresAt)
    else
        -- NPC target: applied directly, ordering per
        -- phase2_notes/phase3_combat_natives.md §2 (damage-bracket +
        -- health floor BEFORE the ragdoll task, never after).
        SetEntityCanBeDamaged(targetPed2, false)
        if GetEntityHealth(targetPed2) < Config.Combat.NonLethalTakedown.healthFloor then
            -- Backstop only, NOT the primary non-lethal mechanism (that's
            -- the damage-bracket above) — see config.lua's own comment.
            SetEntityHealth(targetPed2, Config.Combat.NonLethalTakedown.healthFloor)
        end

        local forward = GetEntityForwardVector(k9Ped2)
        -- SET_PED_TO_RAGDOLL_WITH_FALL(ped, minTime, maxTime, nFallType,
        -- dirX, dirY, dirZ, fGroundHeight, grab1[xyz], grab2[xyz]) — grab
        -- params documented unused, per phase2_notes/phase3_combat_natives.md §2.
        -- minTime/maxTime below are UNTUNED placeholders (not previously
        -- specified anywhere in this codebase's own config/spec).
        SetPedToRagdollWithFall(targetPed2, 1000, 1500, 0, forward.x, forward.y, forward.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    end

    -- BEST-EFFORT WORDING (guardrail 4).
    NotifyPlayer(src, 'Takedown attempted — the target may recover and flee again.', 'inform')
end

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestTakedown', function(targetNetId)
    local src = source

    -- Guards the yield inside HandleTakedownRequest against a second
    -- overlapping call from the SAME K9 — see TakedownMutex's own
    -- declaration comment above.
    if not TakedownMutex.TryAcquire(src) then
        NotifyPlayer(src, 'A takedown attempt is already in progress.', 'error')
        return
    end

    local ok, err = pcall(HandleTakedownRequest, src, targetNetId)

    TakedownMutex.Release(src) -- ALWAYS clear, success or error

    if not ok then
        print(('[qbx_k9unit] requestTakedown error for source %s: %s'):format(src, tostring(err)))
    end
end)

--[[ ================= DISCONNECT CLEANUP ================= ]]

--- If the HOLDING K9 disconnects mid-hold/mid-takedown, tear it down
--- immediately rather than leaving a target's client-side relay (or, for
--- an NPC, the direct suppression/damage-bracket) active until the hard
--- expiresAt cap. If the TARGET disconnects instead, there is no client
--- left to relay a teardown to — just drop the bookkeeping.
AddEventHandler('playerDropped', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if targetNetId then
        EndHold(targetNetId, 'holder_disconnected')
    end

    for netId, hold in pairs(ActiveHolds) do
        if hold.isPlayerTarget and hold.targetSrc == src then
            EndHold(netId, 'target_disconnected')
        end
    end
end)
