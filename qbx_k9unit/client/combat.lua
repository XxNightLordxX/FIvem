--[[
    qbx_k9unit/client/combat.lua

    Phase 3 completion pass. server/combat.lua (coder-security,
    PHASE3_SPEC.md §12.5.1/§12.5.2, built under §12.0 item 8's resolution)
    was committed with no client half and was NOT registered in
    fxmanifest.lua — this file is that missing client half, written
    directly against server/combat.lua's own event contract (read in full
    before writing a line of this file) rather than re-derived from
    PHASE3_SPEC.md's prose alone, per that file's own status as the
    authority on what actually shipped.

    This file owns THREE genuinely different roles, per §12.3's file/module
    plan — kept in one file (not split) because §12.3 explicitly assigns
    all of them to `client/combat.lua`:

    1. SELF-INITIATED TRIGGERS (the K9 player's own action): RequestBiteHold,
       ReleaseBiteHold, RequestTakedown below. These are the "K9 player
       selects an action from the K9 Unit radial" half — this file finds a
       candidate target and fires the matching server event; it never
       decides whether the action is ALLOWED (that is entirely
       server/combat.lua's ValidateCombatRequest, re-run independently of
       anything this file claims).
    2. TARGET-SIDE CATEGORY B RELAY HANDLERS (player target): applyBiteHold,
       endBiteHold, forceRagdoll, endForceRagdoll below. These are
       registered UNCONDITIONALLY on every client, exactly as §12.3's "new
       trust-boundary note" requires (see that note, reproduced below) — a
       player who has never touched a K9 feature can still receive and
       execute these.
    3. NPC-TARGET RELAY HANDLERS (applyNpcBiteHold/endNpcBiteHold/
       applyNpcTakedown/endNpcTakedown below) — NEW, added during a
       native-api-assistant verification pass this session, superseding
       server/combat.lua's ORIGINAL "NPC target: server already fully
       commands this entity, no relay problem" design. See
       server/combat.lua's own header "NPC-TARGET NATIVE EXECUTION
       CONTEXT" section for the full finding (SetEntityCanBeDamaged
       confirmed CLIENT-ONLY — the original server-side call in the
       takedown NPC branch was a silent no-op and a real non-lethality
       bug; the other three NPC-branch natives could not be confirmed
       server-callable either way). These four are sent to the REQUESTING
       K9's own client, never broadcast/unconditional — a K9's own client
       is already this resource's trusted actor for its own action, so
       this role carries none of role 2's trust-boundary exposure.

    ======================================================================
    §12.3 TRUST-BOUNDARY NOTE, made concrete for THIS file (read together
    with PHASE3_SPEC.md §12.3's own "first for this codebase" paragraph,
    not a substitute for it): every other client-side gated action in this
    resource is initiated by, or applies an effect to, a player who is
    themselves attempting to use a K9 feature. The four `RegisterNetEvent`
    handlers in the "TARGET-SIDE" section below are different in kind: they
    fire on ANY connected player's client the instant server/combat.lua
    decides to send them, including a player who holds no K9 certification,
    is in no `Config.Departments`, and has never opened this resource's
    radial menu at all — because item 1's PvP reversal means any eligible
    player (item 5's RequireWantedStatus gate) can be a target. This file
    therefore has NO access-gate of its own on the receiving side, by
    design, matching server/combat.lua's own header framing exactly: the
    ONLY thing standing between "any connected player" and one of these
    natives firing against them is server/combat.lua's own request-time
    validation, which already ran BEFORE this file's event ever arrives.
    This file's job on the receiving side is narrow and mechanical —
    execute exactly what the server already decided, nothing more — never
    re-derive or second-guess eligibility here, and never add a client-side
    "should I really do this" check that could diverge from what the server
    already authorized.
    ======================================================================

    ======================================================================
    CLOCK-DOMAIN NOTE — why `expiresAt` (server/combat.lua's payload field)
    is NOT compared directly against this file's own `GetGameTimer()`,
    unlike client/wellbeing.lua's existing `lastStats.distractedUntil >
    GetGameTimer()` pattern (client/wellbeing.lua's ApplyWellbeingSnapshot):
    `GetGameTimer()` on the server and on any one client are two
    INDEPENDENT clocks (each process's own "ms since it started" counter) —
    comparing a server-stamped value against this file's own GetGameTimer()
    would compare unrelated numbers with an arbitrary, unbounded offset
    between them. client/wellbeing.lua's existing comparison already does
    this, but that call site is a COSMETIC notification only (whether to
    show a fear-stress toast) — a wrong comparison there degrades a message,
    nothing else. This file cannot accept the same degradation:
    PHASE3_SPEC.md §12.0 item 4's "no unbounded trap" guarantee is EXPLICITLY
    binding for BiteAndHold/NonLethalTakedown (server/combat.lua's own header
    guardrail list, item 4/5), and a target whose DisableControlAction loop
    or damage-immunity bracket never locally expires because of a clock
    mismatch would be exactly that trap. Instead: on receipt, this file
    computes its OWN local deadline as `GetGameTimer() + <the same
    Config.Combat.*.maxDurationMs/ragdollDurationMs constant
    server/combat.lua used to compute ITS OWN expiresAt>`, anchored to THIS
    client's own clock at receipt time. Both sides derive the identical
    nominal duration from the identical shared `config.lua` constant, just
    anchored a network round-trip apart (single-digit-to-low-double-digit ms
    in practice, negligible against a 4-15 SECOND window) — this is strictly
    more correct than a raw cross-process comparison, not a guess. The
    `expiresAt` field itself is still received and stored per the contract
    (never silently dropped from the payload), but only for defensive
    logging/parity — never for the actual local-expiry decision. Flagged
    explicitly for whoever next reviews this file, since it is a deliberate
    departure from client/wellbeing.lua's existing (lower-stakes) pattern,
    not an oversight.

    DEFENSE IN DEPTH, same guardrail: server/combat.lua's EndHold ALWAYS
    sends endBiteHold/endForceRagdoll to a player target regardless of end
    reason (including 'timeout') — so in the normal case this file's own
    local-deadline backstop below never actually fires, the server's own
    explicit end event always arrives first. The backstop exists purely for
    the case that message is lost in transit (a dropped/delayed network
    event) — without it, a lost endForceRagdoll would leave this client
    permanently unable to take damage (a target-side exploit, not merely a
    UX bug), and a lost endBiteHold would leave sprint/fire suppressed
    forever (the literal "unbounded trap" item 4 forbids). Both restore
    paths are idempotent (calling SetEntityCanBeDamaged(ped, true) or simply
    clearing a boolean twice is harmless), so no coordination between the
    two is needed.
    ======================================================================

    ======================================================================
    ANIMATION/ASSET STATUS — unchanged from server/combat.lua's own header:
    no anim-dictionary/TASK_PLAY_ANIM asset exists for BiteAndHold this
    pass. The HOLDING K9's own cosmetic stance (biteHoldStarted/Ended below)
    reuses the same already-confirmed `WORLD_DOG_BARKING_*` scenario table
    client/movement.lua's ScratchAtDoor already established for an
    unrelated feature (door-scratch), per that file's own reasoning: no
    "bite hold" scenario name has been confirmed to exist this session
    either, so this reuses a confirmed-real sibling rather than fabricate
    one. Duplicated here (not exported from client/movement.lua) — small
    lookup table, same "duplicate a small table rather than reach into
    another file's internals" convention this codebase already uses
    elsewhere (e.g. server/combat.lua's own duplicated
    ResolveConnectedPlayerFromPed). The TARGET side plays no reaction
    animation at all (applyBiteHold below only ever calls
    DisableControlAction) — server/combat.lua's header explicitly disclaims
    any target-side anim this pass; not silently dropped, just never
    promised.

    RAGDOLL FALL-DIRECTION — two different fidelity levels, disclosed
    rather than silently inconsistent: applyNpcTakedown below (NPC target,
    relayed to the K9's OWN client — see "NPC-TARGET RELAY HANDLERS" above)
    calls `SetPedToRagdollWithFall` using `GetEntityForwardVector(PlayerPedId())`
    — a REAL K9 reference direction, since this handler runs directly on
    the K9's own client. applyForceRagdoll (player target, relayed to the
    TARGET's own client instead) has no such reference available: that
    event's payload is deliberately just `expiresAt` (see
    server/combat.lua's own header EVENT/CALLBACK CONTRACT), carrying no K9
    netId at all, so this file falls back to the TARGET's OWN current
    forward vector there instead. This is a disclosed, honest
    simplification for the player-target path only (not a silent guess,
    and not a limitation of the NPC path) — a real ecosystem match to the
    K9's facing for a PLAYER target would need the holder's netId added to
    that event's payload, a server/combat.lua contract change outside a
    client-only completion pass.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls CanShowK9UI()/DenyK9UIAccess() (client/main.lua) before any
      self-initiated trigger acts — same "display gate only, server is the
      real boundary" posture as every other gated client action in this
      resource.
    - Reads Config.Combat.BiteAndHold/.NonLethalTakedown (config.lua,
      already present — this pass added no new config fields, since
      server/combat.lua's own committed code already reads a complete
      table).
    - Exposes RequestBiteHold(), ReleaseBiteHold(), IsBiteHoldEngaged(), and
      RequestTakedown() as bare globals (this resource's established
      "global helper, private per-file state" convention), ready for a
      client/radial.lua "Bite & Hold" / "Takedown" entry to call — NOT
      wired into client/radial.lua by this pass (out of scope: this pass's
      task was specifically client/combat.lua + fxmanifest.lua
      registration, and client/radial.lua is shared infrastructure every
      other feature also registers into). Both Config.Features flags stay
      `false` by default regardless, so this is a real, disclosed gap
      (these three actions currently have NO in-game entry point at all,
      self-initiated-trigger side) rather than a silent one — flagged for
      whoever adds the radial entries, mirroring client/radial.lua's own
      existing Config.Features-gated block shape (e.g. its
      LeashMechanics/VehicleEntryExit items) exactly.
    ======================================================================
]]

-- ======================================================================
-- TARGET-SIDE STATE (Category B relay) — file-local, never authoritative.
-- Both are nil when inactive. Neither table is ever read by the
-- self-initiated-trigger half below; they exist purely for the shared
-- maintenance thread and the two `end*` handlers to consult.
--
-- ActiveBiteHold = { holderNetId = number, localDeadline = number } | nil
-- ActiveForcedRagdoll = { localDeadline = number } | nil
-- ======================================================================
local ActiveBiteHold = nil
local ActiveForcedRagdoll = nil

-- NPC-TARGET relay state (see "NPC-TARGET RELAY HANDLERS" above) — this
-- K9's OWN client applying an effect to an NPC ped ON THE K9's OWN
-- request. Keyed by npcNetId (not a single flat var, unlike
-- ActiveBiteHold/ActiveForcedRagdoll above) purely for robustness:
-- server/combat.lua's own "one hold at a time per K9" rule
-- (K9ActiveEffect) already means this client will only ever have one entry
-- here in practice, but keying by npcNetId costs nothing and stays correct
-- even if that invariant ever changes.
-- ActiveNpcEffects[npcNetId] = { kind = 'bite' | 'takedown', localDeadline = number }
local ActiveNpcEffects = {}

-- HOLDER-SIDE state (cosmetic only) — which target's biteHoldStarted this
-- K9's own client is currently reflecting, so IsBiteHoldEngaged() can drive
-- the radial item's "Bite & Hold" vs. "Release" behavior (mirrors
-- client/radial.lua's existing IsLeashed()-driven Attach/Detach Leash
-- toggle exactly). Purely a UX convenience — server/combat.lua's own
-- K9ActiveEffect[src] is the real, authoritative "am I engaged" state;
-- releaseBiteHold is always sent regardless of what this file currently
-- believes, same "Detach never requires consent/access" posture
-- client/radial.lua's own Leash item already documents.
local MyEngagedTargetNetId = nil

-- Precomputed model-hash -> scenario lookup for the HOLDING K9's own
-- cosmetic stance during an active hold — see this file's header
-- "ANIMATION/ASSET STATUS" for why this duplicates
-- client/movement.lua's K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH table
-- rather than reuse it directly, and inherits that table's own confidence
-- grading verbatim (HIGH: the scenario strings themselves exist, per two
-- independently-maintained community scenario dumps; MEDIUM: the
-- breed-to-scenario mapping for a_c_chop/a_c_husky specifically, which
-- have no breed-specific scenario and reuse a plausible sibling).
local K9_BITE_HOLD_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_BARKING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_BARKING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_BARKING_ROTTWEILER',
    a_c_husky = 'WORLD_DOG_BARKING_RETRIEVER',
}) do
    K9_BITE_HOLD_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_BITE_HOLD_DEFAULT_SCENARIO = 'WORLD_DOG_BARKING_SHEPHERD'

-- Control indices — HIGH confidence, the same standard/well-established GTA
-- V control mapping already relied on throughout the FiveM ecosystem (same
-- confidence grade client/movement.lua's own header already applies to
-- INPUT_JUMP=22/INPUT_DUCK=36 for the identical reason: these exact IDs are
-- ubiquitous across FiveM resources/tutorials). Not independently
-- cross-checked against two live sources THIS session — flagged honestly
-- per this codebase's own confidence-grading convention (see
-- client/hud.lua's stamina-native note) rather than silently presented as
-- verified fresh.
local INPUT_SPRINT = 21
local INPUT_ATTACK = 24

-- ======================================================================
-- SELF-INITIATED TRIGGERS (the K9 player's own action)
-- ======================================================================

--- Finds the nearest OTHER live ped (NPC or player) within `rangeMeters` of
--- the local player, for BiteAndHold/NonLethalTakedown's self-initiated
--- radial trigger. Deliberately NOT restricted to players only —
--- PHASE3_SPEC.md §12.0 item 1 (Revision 3): "targets may be an NPC ped OR
--- a live player." This is a candidate-selection CONVENIENCE only, same
--- "canInteract/candidate search is a DISPLAY optimization, never the
--- security boundary" posture every ox_target option and
--- client/radial.lua's own FindNearestLeashCandidate already document —
--- server/combat.lua's ValidateCombatRequest independently re-resolves and
--- re-validates the target from the netId this function hands off, from
--- scratch, regardless of what this function picked.
--- @param rangeMeters number
--- @return number? targetPed
local function FindNearestCombatTarget(rangeMeters)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPed, nearestDist

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= myPed and DoesEntityExist(ped) and not IsEntityDead(ped) then
            local dist = #(myCoords - GetEntityCoords(ped))
            if dist <= rangeMeters and (not nearestDist or dist < nearestDist) then
                nearestPed, nearestDist = ped, dist
            end
        end
    end

    return nearestPed
end

--- Plays the HOLDING K9's own local cosmetic stance — a self-applied,
--- Category-A-equivalent effect per server/combat.lua's own header (the
--- K9's own ped, driven by its own client, no relay problem). Mirrors
--- client/movement.lua's ScratchAtDoor/K9Sit exactly: a one-shot
--- TaskStartScenarioInPlace call, no per-frame thread needed (the scenario
--- persists on its own until interrupted).
local function PlayBiteHoldStance()
    local ped = PlayerPedId()
    local scenarioName = K9_BITE_HOLD_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_BITE_HOLD_DEFAULT_SCENARIO
    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
end

--- Self-initiated BiteAndHold trigger — PHASE3_SPEC.md §12.5.1. Called from
--- client/radial.lua's "Bite & Hold / Release" item when not currently
--- engaged (see IsBiteHoldEngaged() below for the toggle).
function RequestBiteHold()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    local target = FindNearestCombatTarget(Config.Combat.BiteAndHold.range)
    if not target then
        lib.notify({ title = 'K9 Unit', description = 'No eligible target in range.', type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestBiteHold', NetworkGetNetworkIdFromEntity(target))
end

--- Always available while engaged, same "no consent/access gate on the way
--- out" posture as client/radial.lua's DetachLeash — mirrors
--- server/combat.lua's own releaseBiteHold handler, which likewise never
--- re-checks HasK9Access/feature-flag on the way out, only that THIS src
--- is the current holder.
function ReleaseBiteHold()
    TriggerServerEvent('qbx_k9unit:server:releaseBiteHold')
end

--- @return boolean
function IsBiteHoldEngaged()
    return MyEngagedTargetNetId ~= nil
end

--- Self-initiated NonLethalTakedown trigger — PHASE3_SPEC.md §12.5.2. No
--- local "is the target fleeing" check is attempted here — that is
--- EXCLUSIVELY a server-computed speed gate from live position samples
--- (server/combat.lua's own HandleTakedownRequest), never a client claim,
--- so this function does not try to pre-filter on it.
function RequestTakedown()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    local target = FindNearestCombatTarget(Config.Combat.NonLethalTakedown.range)
    if not target then
        lib.notify({ title = 'K9 Unit', description = 'No eligible target in range.', type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestTakedown', NetworkGetNetworkIdFromEntity(target))
end

-- HOLDER-SIDE receivers — server/combat.lua's own header: "Sent ONLY to the
-- HOLDING K9's own client — starts/ends its own local cosmetic stance."
RegisterNetEvent('qbx_k9unit:client:biteHoldStarted', function(targetNetId, expiresAt)
    MyEngagedTargetNetId = targetNetId
    PlayBiteHoldStance()
end)

RegisterNetEvent('qbx_k9unit:client:biteHoldEnded', function(targetNetId, reason)
    if MyEngagedTargetNetId ~= targetNetId then return end -- stale/foreign event, e.g. a race with a brand-new hold — never clear a DIFFERENT hold's state
    MyEngagedTargetNetId = nil
    ClearPedTasksImmediately(PlayerPedId())
end)

-- ======================================================================
-- TARGET-SIDE CATEGORY B RELAY HANDLERS — registered UNCONDITIONALLY for
-- EVERY client. See this file's header trust-boundary note before touching
-- anything below: no access-gate belongs here, by design.
-- ======================================================================

--- PHASE3_SPEC.md §12.0 item 8 / server/combat.lua's own header: applies
--- DisableControlAction on sprint/fire locally every frame until the
--- (locally-derived, see this file's header CLOCK-DOMAIN NOTE) deadline or
--- an endBiteHold arrives first, whichever is sooner. `holderNetId` is
--- accepted per the contract but not currently consumed by this file (no
--- target-side visual references the holder this pass — see the header's
--- ANIMATION/ASSET STATUS note); kept as a named parameter, not discarded
--- silently, so a future visual addition has it ready without a contract
--- change.
--- @param holderNetId number
--- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header
RegisterNetEvent('qbx_k9unit:client:applyBiteHold', function(holderNetId, expiresAt)
    ActiveBiteHold = {
        holderNetId = holderNetId,
        localDeadline = GetGameTimer() + Config.Combat.BiteAndHold.maxDurationMs,
    }
end)

--- @param reason string
RegisterNetEvent('qbx_k9unit:client:endBiteHold', function(reason)
    ActiveBiteHold = nil
end)

--- PHASE3_SPEC.md §12.0 item 8 / server/combat.lua's own header: applies
--- the ragdoll + damage-bracket locally, bracket-before-ragdoll ordering,
--- per phase2_notes/phase3_combat_natives.md §2 ("damage-bracket + health
--- floor BEFORE the ragdoll task, never after") — same ordering
--- applyNpcTakedown below uses for the NPC-target path. See this file's
--- header "RAGDOLL FALL-DIRECTION" note for why this uses the TARGET's own
--- forward vector rather than the K9's (the payload carries no K9
--- reference).
--- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header
RegisterNetEvent('qbx_k9unit:client:forceRagdoll', function(expiresAt)
    local ped = PlayerPedId()

    SetEntityCanBeDamaged(ped, false)

    local forward = GetEntityForwardVector(ped)
    -- SET_PED_TO_RAGDOLL_WITH_FALL(ped, minTime, maxTime, nFallType, dirX,
    -- dirY, dirZ, fGroundHeight, grab1[xyz], grab2[xyz]) — grab params
    -- documented unused, per phase2_notes/phase3_combat_natives.md §2.
    -- minTime/maxTime (1000, 1500) match applyNpcTakedown below exactly,
    -- for parity between the two paths — both are UNTUNED placeholders,
    -- not previously specified anywhere in this codebase's own config/spec.
    SetPedToRagdollWithFall(ped, 1000, 1500, 0, forward.x, forward.y, forward.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    ActiveForcedRagdoll = {
        localDeadline = GetGameTimer() + Config.Combat.NonLethalTakedown.ragdollDurationMs,
    }
end)

--- @param reason string
RegisterNetEvent('qbx_k9unit:client:endForceRagdoll', function(reason)
    if not ActiveForcedRagdoll then return end
    ActiveForcedRagdoll = nil
    SetEntityCanBeDamaged(PlayerPedId(), true)
end)

-- ======================================================================
-- NPC-TARGET RELAY HANDLERS — sent ONLY to the REQUESTING K9's own client
-- (never a broadcast, and never sent to the NPC's own "client," since an
-- NPC has none). See this file's header point 3 and server/combat.lua's
-- own header "NPC-TARGET NATIVE EXECUTION CONTEXT" for why these exist:
-- SetEntityCanBeDamaged was confirmed CLIENT-ONLY (the original server-side
-- call was a silent non-lethality bug), and SetPedFleeAttributes/
-- SetBlockingOfNonTemporaryEvents/SetPedToRagdollWithFall's server-side
-- validity could not be confirmed either way, so all four now run here
-- instead — an unambiguously valid execution context regardless of their
-- server-side status. Unlike the TARGET-side handlers above, these carry
-- NONE of the §12.3 trust-boundary exposure (the K9's own client is already
-- this resource's trusted actor for its own action) — they still perform
-- no validation of their own, simply because none is needed here, not
-- because it would be unsafe to add.
-- ======================================================================

--- @param npcNetId number
--- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header CLOCK-DOMAIN NOTE
RegisterNetEvent('qbx_k9unit:client:applyNpcBiteHold', function(npcNetId, expiresAt)
    local npcPed = NetworkGetEntityFromNetworkId(npcNetId)
    if npcPed == 0 or not DoesEntityExist(npcPed) then return end -- despawned/streamed-out between the server's grant and this event arriving — nothing to apply to

    -- flags=0/clear=false reproduced VERBATIM from server/combat.lua's
    -- ORIGINAL server-side call (unchanged by this session's client-relay
    -- restructure, which only moved WHERE this runs, not WHAT it passes).
    -- SET_PED_FLEE_ATTRIBUTES' exact flags-bitmask/clear-boolean semantics
    -- were NOT independently verified this session (native-api-assistant's
    -- fetch of the PED native-decl section was blocked) — flagged here,
    -- not silently trusted, for whoever next has real doc access: a
    -- flags value of 0 may mean this call does not meaningfully suppress
    -- fleeing at all, independent of the client-vs-server question this
    -- session did resolve.
    SetBlockingOfNonTemporaryEvents(npcPed, true)
    SetPedFleeAttributes(npcPed, 0, false)

    ActiveNpcEffects[npcNetId] = {
        kind = 'bite',
        localDeadline = GetGameTimer() + Config.Combat.BiteAndHold.maxDurationMs,
    }
end)

--- @param npcNetId number
--- @param reason string
RegisterNetEvent('qbx_k9unit:client:endNpcBiteHold', function(npcNetId, reason)
    ActiveNpcEffects[npcNetId] = nil
    local npcPed = NetworkGetEntityFromNetworkId(npcNetId)
    if npcPed ~= 0 and DoesEntityExist(npcPed) then
        SetBlockingOfNonTemporaryEvents(npcPed, false)
    end
end)

--- @param npcNetId number
--- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header CLOCK-DOMAIN NOTE
RegisterNetEvent('qbx_k9unit:client:applyNpcTakedown', function(npcNetId, expiresAt)
    local npcPed = NetworkGetEntityFromNetworkId(npcNetId)
    if npcPed == 0 or not DoesEntityExist(npcPed) then return end

    SetEntityCanBeDamaged(npcPed, false)

    -- Unlike forceRagdoll above (player target, falls back to the TARGET's
    -- own forward vector — see header "RAGDOLL FALL-DIRECTION"), this
    -- handler runs directly on the K9's OWN client, so the REAL K9 facing
    -- direction is simply this client's own PlayerPedId() — strictly
    -- better fidelity than the player-target path, not a fallback.
    local forward = GetEntityForwardVector(PlayerPedId())
    SetPedToRagdollWithFall(npcPed, 1000, 1500, 0, forward.x, forward.y, forward.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    ActiveNpcEffects[npcNetId] = {
        kind = 'takedown',
        localDeadline = GetGameTimer() + Config.Combat.NonLethalTakedown.ragdollDurationMs,
    }
end)

--- @param npcNetId number
--- @param reason string
RegisterNetEvent('qbx_k9unit:client:endNpcTakedown', function(npcNetId, reason)
    ActiveNpcEffects[npcNetId] = nil
    local npcPed = NetworkGetEntityFromNetworkId(npcNetId)
    if npcPed ~= 0 and DoesEntityExist(npcPed) then
        SetEntityCanBeDamaged(npcPed, true)
    end
end)

-- ======================================================================
-- SHARED MAINTENANCE THREAD — single shared thread (never one per active
-- effect), mirroring server/combat.lua's own "one shared maintenance
-- thread, not one thread per active effect" discipline (which itself
-- mirrors server/tracking.lua's PruneTrackableLogs precedent). Picks the
-- LARGEST Wait() the currently-active state actually needs:
--   - BiteAndHold (a Category B effect applied TO this client) demands
--     Wait(0) while active — DisableControlAction's own contract requires
--     reasserting it every single frame (same "must disable every frame
--     while active" discipline as client/movement.lua's AgilityBasicJump
--     suppression thread). This is the ONLY state in this file that needs
--     per-frame reassertion.
--   - Forced ragdoll (also applied TO this client) and every NPC-relay
--     effect (applied BY this client, to an NPC, on this K9's own request)
--     need no per-frame native call at all — SetEntityCanBeDamaged/
--     SetBlockingOfNonTemporaryEvents are persistent flags, not per-frame
--     ones, and SetPedToRagdollWithFall is a one-shot task call — only a
--     periodic deadline check is needed for either, so a coarser Wait
--     suffices while ActiveBiteHold isn't also active.
--   - Otherwise (nothing active, the overwhelming common case for any
--     player who is never targeted and isn't currently a K9 mid-action): a
--     cheap idle poll, never a tight loop spinning for a feature that
--     isn't currently doing anything on this client at all.
-- ======================================================================
CreateThread(function()
    while true do
        if ActiveBiteHold then
            DisableControlAction(0, INPUT_SPRINT, true)
            DisableControlAction(0, INPUT_ATTACK, true)

            if GetGameTimer() >= ActiveBiteHold.localDeadline then
                -- Backstop only — see header "DEFENSE IN DEPTH". In the
                -- normal case server/combat.lua's own maintenance thread
                -- already sent endBiteHold before this ever fires.
                ActiveBiteHold = nil
            end

            Wait(0)
        else
            local now = GetGameTimer()

            if ActiveForcedRagdoll and now >= ActiveForcedRagdoll.localDeadline then
                -- Backstop only — see header "DEFENSE IN DEPTH". Restoring
                -- damageability is the load-bearing half of this backstop
                -- (an un-restored bracket is a target-side exploit, not
                -- merely a UX bug), so this branch does it directly rather
                -- than waiting on a lost network event.
                ActiveForcedRagdoll = nil
                SetEntityCanBeDamaged(PlayerPedId(), true)
            end

            -- Same backstop reasoning as ActiveForcedRagdoll above, applied
            -- to every currently-active NPC relay effect — a lost
            -- endNpcBiteHold/endNpcTakedown network event must not leave an
            -- NPC permanently flee-suppressed or permanently undamageable.
            for npcNetId, effect in pairs(ActiveNpcEffects) do
                if now >= effect.localDeadline then
                    ActiveNpcEffects[npcNetId] = nil
                    local npcPed = NetworkGetEntityFromNetworkId(npcNetId)
                    if npcPed ~= 0 and DoesEntityExist(npcPed) then
                        if effect.kind == 'bite' then
                            SetBlockingOfNonTemporaryEvents(npcPed, false)
                        else
                            SetEntityCanBeDamaged(npcPed, true)
                        end
                    end
                end
            end

            Wait(ActiveForcedRagdoll and 100 or 500)
        end
    end
end)
