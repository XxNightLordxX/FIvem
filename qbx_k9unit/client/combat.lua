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

    PHASE 3 ADDITION (this pass, coder-architect): PropDragging
    (PHASE3_SPEC.md §12.5.4), folded into the same three roles above rather
    than a fourth new role:
    1'. RequestDrag()/ReleaseDrag()/IsDragEngaged() — same self-initiated
        shape as RequestBiteHold/ReleaseBiteHold/IsBiteHoldEngaged, plus the
        HOLDER-side per-tick maintenance (ActiveDragAsHolder below) that
        actually calls AttachEntityToEntity every frame — see "PROP DRAGGING
        — HOLDER-SIDE ATTACH RE-ASSERTION" below for why this is NOT
        one-shot.
    2'. applyDragSpeedLimit/endDragSpeedLimit — the Category B relay half,
        registered unconditionally like role 2 above, same trust-boundary
        note applies verbatim.
    3'. dragStarted/dragEnded — sent only to the requesting K9's own client,
        same posture as role 3 above; ALSO carries the NPC-target move-rate
        re-assertion for a drag (no separate applyNpcDragSpeedLimit event
        exists — dragStarted's own isPlayerTarget field is all this client
        needs to know whether to also drive the NPC's move rate directly).

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

    ======================================================================
    PROP DRAGGING — HOLDER-SIDE ATTACH RE-ASSERTION (PHASE3_SPEC.md §12.0
    item 8's "new finding," binding guardrail 2): AttachEntityToEntity is
    documented (citizenfx/fivem issue #3726) to require no network
    ownership/authority over the target at all to take initial effect — but
    DetachEntity is the symmetric operation on the same entity, and by that
    same evidence there is no reason to expect the detach side is gated any
    differently. A hostile target's own client can call DetachEntity on
    itself at any moment to instantly break free. The ONLY defense this
    resource has is re-asserting AttachEntityToEntity EVERY TICK from the
    K9's own client (never one-shot) — implemented in the shared maintenance
    thread below (ActiveDragAsHolder branch), mirroring ActiveBiteHold's own
    existing "must reassert every frame" discipline for DisableControlAction.
    This is detection-adjacent, not prevention: even with per-tick
    reassertion, a brief window exists between a hostile target's
    self-detach and the K9's next frame — server/combat.lua's own
    drag_gap compliance signal (comparing target position against the K9's
    OWN live position) is what actually catches a target who exploited that
    window, per this file's honest "cannot prevent, only detect" posture
    throughout (§12.0 item 8, point 4's conclusion).

    NETWORK OWNERSHIP OF THE TARGET PED — same finding also applies to the
    NPC-target speed-limit half (SetPedMoveRateOverride on an NPC this K9's
    client doesn't necessarily own network control of) and, on the holder
    side, to the attach itself. Every native call against a target/NPC
    entity below is preceded by a best-effort NetworkRequestControlOfEntity
    call (phase2_notes/phase3_combat_natives.md's own §1/§4 confirm this
    native and explicitly name it as "needed before an NPC-target client can
    reliably drive SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes/
    AttachEntityToEntity on an entity it doesn't already own network control
    of" — a gap this file's PRE-EXISTING applyNpcBiteHold/applyNpcTakedown
    handlers had NOT been closing before this pass, a real correctness bug
    on a populated server where the K9 is very unlikely to already own a
    random ambient NPC's network control). This is requested EVERY TICK
    alongside the effect natives themselves, not once at grant time, for the
    same reason the attach/move-rate natives are re-asserted every tick —
    control can be lost again mid-effect. IMPORTANT, stated honestly rather
    than asserted as solved: NetworkRequestControlOfEntity is itself a
    best-effort ASK of the current owning client (PHASE3_SPEC.md §12.0 item
    8, point 3's own citation of citizenfx/fivem issue #3338), not a
    server-forceable guarantee. CORRECTION (native-api-assistant audit, this
    pass): an earlier version of this note claimed no success-check native
    exists for this — that was stale. NetworkHasControlOfEntity (hash
    0x01BF60A500E28887) DOES exist and would report whether the request in
    fact succeeded. It is still deliberately NOT called here: this file's
    only thread is the single shared maintenance CreateThread serving every
    active effect on this client (see "SHARED MAINTENANCE THREAD" below), and
    gating on NetworkHasControlOfEntity via a blocking-wait idiom (loop until
    it returns true, or Wait/retry before proceeding) would stall that one
    thread — and therefore every OTHER concurrently-active effect this same
    client is enforcing (e.g. its own ActiveBiteHold as a target, a
    completely unrelated role) — for as long as control is contested or never
    granted. The audit's conclusion: keep the existing fire-and-forget
    pattern (request, then proceed with the effect native regardless), and
    do not adopt a wait loop. Every call site below fires the request and
    proceeds with the effect native regardless of whether control was
    actually granted, exactly as before this correction — only the
    "no such native exists" claim was wrong, not the resulting design. In the
    common case (an ambient NPC with no other client actively contesting it)
    this converges to genuine control within a frame or two; it is not a
    guarantee, and is disclosed as such rather than presented as a fixed
    problem.

    MOVE-RATE COMPOSER SCOPE — client/movement.lua's RecomputeK9MoveRate()
    (PHASE4_SPEC.md §13.0 Decision 2) is HARD-GATED on IsOwnModelK9(): it
    resets to neutral and returns early for any ped that is not currently a
    recognized K9 model (see that function's own `if not IsOwnModelK9() then
    ... return end` branch). PropDragging's applyDragSpeedLimit handler
    below runs on the TARGET's own client, and the overwhelmingly common
    real case is a human suspect, NOT another K9 — unconditionally routing
    through the composer, as PHASE4_SPEC.md §13.0 Decision 2's own text
    would suggest at first read ("nothing should ever call
    SetPedMoveRateOverride directly except RecomputeK9MoveRate()"), would
    therefore silently no-op for the actual primary use case, since the
    composer would just reset-and-return every time it's called on a
    non-K9 ped. RESOLUTION (checked against every existing
    K9MoveRateModifiers writer before choosing this, and flagged to
    coder-frontend, who owns that composer, for awareness/veto): route
    through the composer ONLY when IsOwnModelK9() is true for the client
    currently applying the effect (the rarer case where the drag target
    genuinely is a K9 character, so the effect genuinely needs to compose
    with Fatigue/Injury/Mood/XPTier) — otherwise call SetPedMoveRateOverride
    directly. The direct call cannot "fight" the composer's other
    contributors in that branch, because every one of them
    (client/wellbeing.lua, client/progression.lua) is ITSELF scoped to a K9
    model only — nothing else in this codebase ever touches a non-K9 ped's
    move rate at all, so there is no last-caller-wins conflict to avoid for
    that ped. The reserved `K9MoveRateModifiers.dragging` slot is used
    exactly as documented, for the K9-target branch.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls CanShowK9UI()/DenyK9UIAccess() (client/main.lua) before any
      self-initiated trigger acts — same "display gate only, server is the
      real boundary" posture as every other gated client action in this
      resource.
    - Reads Config.Combat.BiteAndHold/.NonLethalTakedown/.PropDragging
      (config.lua — the PropDragging sub-table has since LANDED (confirmed
      present in config.lua as of this review pass, with range/
      maxDragDurationMs/dragSpeedMultiplier/maxDragDistance all populated);
      this note is kept only as a historical record that it was once a
      cross-file request, not a current gap).
    - Exposes RequestBiteHold(), ReleaseBiteHold(), IsBiteHoldEngaged(),
      RequestTakedown(), RequestDrag(), ReleaseDrag(), and IsDragEngaged()
      as bare globals (this resource's established "global helper, private
      per-file state" convention). UPDATE (confirmed present as of this
      review pass): client/radial.lua (coder-frontend) has since wired all
      three — "Bite & Hold" / "Takedown" / "Drag" radial entries calling
      RequestBiteHold()/ReleaseBiteHold()/IsBiteHoldEngaged(),
      RequestTakedown(), and RequestDrag()/ReleaseDrag()/IsDragEngaged()
      respectively — so this is no longer a dangling contract with zero
      caller; kept as historical context only. Every Config.Features flag
      involved still stays `false` by default regardless (see config.lua),
      so these actions remain genuinely inert in a default install even
      though an in-game entry point now exists.
    - Calls the resource-global NetworkRequestControlOfEntity native
      (landed in .luacheckrc's read_globals — confirmed present as of this
      review pass) before manipulating any NPC/target ped this
      client does not already control — see "NETWORK OWNERSHIP OF THE
      TARGET PED" above.
    ======================================================================
]]

-- ======================================================================
-- TOP-LEVEL FEATURE GATE — coordinator-flagged red-team finding (this
-- session), verified against this file's own code before fixing: every
-- RegisterNetEvent handler below (including the four NPC-relay handlers)
-- was previously registered UNCONDITIONALLY, regardless of
-- Config.Features.BiteAndHold/NonLethalTakedown/PropDragging. In FiveM, a
-- client's own local `TriggerEvent(name, ...)` invokes a RegisterNetEvent
-- handler exactly like a genuine server-sent TriggerClientEvent would —
-- there is no way for the handler itself to tell the two apart. That meant
-- a modified client could fire e.g. `applyNpcTakedown`/`applyBiteHold`
-- locally at any time, with ZERO server contact, and apply
-- SetEntityCanBeDamaged/SetPedToRagdollWithFall to any entity it could
-- resolve a netId for — live even with every flag above false, which
-- breaks this resource's own "flag off means genuinely inert" invariant
-- every OTHER feature in this codebase holds (client/hud.lua's
-- `if not Config.Features.HealthStaminaHUD then return end` /
-- client/vision.lua's per-native `if Config.Features.ThermalVision then
-- RegisterCommand(...) end` are the established "gate at registration, not
-- inside the handler" precedent this mirrors).
--
-- THIS GATE FIXES: "all three flags false" now means this file registers
-- NOTHING — no self-initiated trigger, no target-side relay handler, no
-- NPC-relay handler — restoring genuine inertness when the feature(s) are
-- off, exactly like every sibling file's own top-level gate.
--
-- THIS GATE DOES NOT FIX (on its own): the underlying trust-boundary gap
-- once at least one flag IS true — the per-mechanic gate only decides
-- whether a handler EXISTS on this server at all, not whether a given
-- invocation of it, once registered, genuinely came from the server. See
-- "SOURCE-ORIGIN GUARD" immediately below the per-mechanic gating section
-- for the dedicated fix for that half, landed separately (coder-security,
-- phase2_notes/client_event_trust_boundary.md). Do not read this comment
-- block's presence alone as "solved" — only "off is inert again"; the
-- origin guard below is what actually closes the self-triggering gap for
-- the "on" case.
-- ======================================================================
if not (Config.Features.BiteAndHold or Config.Features.NonLethalTakedown or Config.Features.PropDragging) then
    return
end

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

-- PROP DRAGGING — HOLDER-SIDE state (PHASE3_SPEC.md §12.5.4, this pass):
-- this K9's own client's own view of a drag IT is currently performing.
-- `isPlayerTarget` is carried here (not re-derived) because it decides,
-- every tick, whether this client ALSO drives the target's own move rate
-- directly (NPC target) or leaves that half to the target's own client via
-- applyDragSpeedLimit below (player target) — see the maintenance thread.
-- ActiveDragAsHolder = { targetNetId = number, isPlayerTarget = boolean, localDeadline = number } | nil
local ActiveDragAsHolder = nil

-- PROP DRAGGING — TARGET-SIDE state (Category B relay, player target only):
-- this client's own view of being dragged BY someone else. Never trusts
-- IsOwnModelK9() decided once at apply-time — re-checked fresh every tick
-- in the maintenance thread instead (see this file's header "MOVE-RATE
-- COMPOSER SCOPE" note), since the correct branch depends on THIS client's
-- CURRENT model, which this state does not need to remember.
-- ActiveDragSpeedLimit = { localDeadline = number } | nil
local ActiveDragSpeedLimit = nil

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
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.no_target_in_range'), type = 'error' })
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
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.no_target_in_range'), type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestTakedown', NetworkGetNetworkIdFromEntity(target))
end

--- Same nearest-ped-in-range convenience as FindNearestCombatTarget above,
--- but WITHOUT excluding a dead ped — PropDragging's whole premise is a
--- DOWNED target, and for an NPC that legitimately means IsEntityDead ==
--- true in the common case (a fully killed ped, not merely ragdolled).
--- Reusing FindNearestCombatTarget unmodified here (as originally drafted)
--- would have made a genuinely-dead NPC body impossible to ever select for
--- dragging via this convenience search — a real, disclosed collision
--- between this file's own pre-existing candidate-search helper and
--- PropDragging's actual target shape, found and fixed by this pass rather
--- than silently reused. Same "display optimization only, never the
--- security boundary" posture as FindNearestCombatTarget's own doc comment
--- — server/combat.lua's IsTargetDowned is the real, authoritative check
--- for BOTH target kinds regardless of what this function picks (no local
--- "is this target downed" pre-filter is attempted here at all: the native
--- IsPedDeadOrDying/IsPedRagdoll check would be reliable for an NPC but
--- categorically CANNOT answer this question for a player target,
--- PHASE3_SPEC.md §12.0 item 6 — attempting it here would just be a
--- misleading, inconsistent convenience).
--- @param rangeMeters number
--- @return number? targetPed
local function FindNearestDraggableCandidate(rangeMeters)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPed, nearestDist

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= myPed and DoesEntityExist(ped) then
            local dist = #(myCoords - GetEntityCoords(ped))
            if dist <= rangeMeters and (not nearestDist or dist < nearestDist) then
                nearestPed, nearestDist = ped, dist
            end
        end
    end

    return nearestPed
end

--- Self-initiated PropDragging trigger — PHASE3_SPEC.md §12.5.4.
function RequestDrag()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    local target = FindNearestDraggableCandidate(Config.Combat.PropDragging.range)
    if not target then
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.no_target_in_range'), type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestDrag', NetworkGetNetworkIdFromEntity(target))
end

--- Always available while dragging, same "no consent/access gate on the
--- way out" posture as client/radial.lua's DetachLeash / this file's own
--- ReleaseBiteHold above — mirrors server/combat.lua's own releaseDrag
--- handler, which likewise never re-checks HasK9Access/feature-flag on the
--- way out, only that THIS src is a legitimate party to the drag (holder OR
--- target).
function ReleaseDrag()
    TriggerServerEvent('qbx_k9unit:server:releaseDrag')
end

--- @return boolean
function IsDragEngaged()
    return ActiveDragAsHolder ~= nil
end

-- ======================================================================
-- PER-MECHANIC GATING — coordinator/QA follow-up on the top-level gate
-- above (this session): a single file-level OR correctly restores
-- inertness for the "all three flags off" case, but a server running e.g.
-- ONLY PropDragging (a plausible config — it's the newest, most
-- self-contained of the three) would otherwise still register
-- BiteAndHold/NonLethalTakedown's own handlers below, which QA confirmed
-- is a real, direct exploit even with those two flags off: forceRagdoll
-- calls SetEntityCanBeDamaged(PlayerPedId(), false) unconditionally on
-- receipt, so ANY connected player could locally
-- `TriggerEvent('qbx_k9unit:client:forceRagdoll', <anything>)` on a loop
-- for indefinite self-invincibility, with zero certification/proximity/
-- cooldown check and zero server contact. Each mechanic's own
-- RegisterNetEvent group below is now gated behind its OWN
-- Config.Features flag, not the shared top-level OR, restoring "this
-- mechanic's flag off means genuinely inert" per mechanic, not just
-- per file. The top-level gate above is KEPT as a cheap outer guard (skips
-- declaring per-tick maintenance work entirely when all three are off) —
-- it does not by itself make any individual mechanic's handlers inert
-- once a DIFFERENT flag is on, which is exactly the gap this restructure
-- closes.
-- ======================================================================

-- ======================================================================
-- SOURCE-ORIGIN GUARD (coder-security, this pass, per design assessment
-- phase2_notes/client_event_trust_boundary.md — read that document in full
-- before touching this block; this comment is a summary of it, not a
-- replacement for it). Fixes the specific gap the per-mechanic gate above
-- explicitly disclaimed: once a mechanic's flag is on, its handlers are
-- reachable, and nothing previously stopped a modified client from firing
-- one of them on itself via the public `TriggerEvent('qbx_k9unit:client:...',
-- ...)` Lua API — zero server contact required — for indefinite
-- self-invincibility/self-benefit, or (the NPC-relay handlers specifically)
-- for grief against a DIFFERENT K9's in-flight NPC effect by guessing/
-- observing that NPC's netId.
--
-- THE FIX: every `qbx_k9unit:client:*` handler below starts with
-- `if source ~= 65535 then return end`. 65535 is FiveM's documented sentinel
-- value for "this event's source is the server itself" inside a client-side
-- RegisterNetEvent handler (citizenfx/fivem-docs, "Secure your events" —
-- read directly from the docs' own GitHub source, not a summary/mirror).
--
-- CONFIDENCE — graded honestly, not asserted as settled:
--   - HIGH: the public `TriggerEvent` API a self-triggering client would
--     actually use cannot forge a custom origin for the dispatched event —
--     confirmed by reading `TRIGGER_EVENT_INTERNAL`'s own native
--     declaration (citizenfx/fivem, primary source), which takes no
--     origin/source parameter at all.
--   - MEDIUM-HIGH, not certain: that comparing client-side `source` against
--     the literal `65535` is what actually distinguishes a genuine
--     server-sent `TriggerClientEvent` from a local self-trigger on THIS
--     client. This is the official first-party pattern for exactly this
--     scenario, but the design pass backing this change could not fetch
--     `forum.cfx.re` (egress-blocked) for independent corroboration beyond
--     a WebSearch summary, and could not trace the raw engine code that
--     actually populates `source` on a networked event receive. It
--     explicitly recommends empirically confirming this against a live
--     client before leaning on it further: trigger one of these events
--     genuinely from the server, and separately via
--     `TriggerEvent('qbx_k9unit:client:forceRagdoll', 0)` from this same
--     client's own console/another local test resource, and confirm
--     `source`/`type(source)` actually differ the two ways (also worth
--     confirming `source` is a Lua number here, not a string, since a
--     `"65535" ~= 65535` mismatch would silently make this check
--     always-true — fail closed, not exploitable, but a confusing bug to
--     debug blind). That empirical check has NOT been performed as part of
--     this change; this guard ships on the strength of the official
--     documented pattern alone.
--
-- WHAT THIS DOES NOT CLOSE:
--   1. PHASE3_SPEC.md §12.0 item 8's own residual gap — a legitimately
--      TARGETED player's client honestly receiving a genuine server-sent
--      Category B event and then simply choosing not to execute it (skip
--      the DisableControlAction calls, run a patched build of this
--      resource, etc.). That is a different problem than this guard
--      addresses ("did this invocation come from the network at all," not
--      "did the receiving client honor it"), already resolved elsewhere as
--      an accepted, guardrailed risk (item 8's own detection-not-prevention
--      posture). Do not read this guard as further progress on that item.
--   2. A client operating below the public Lua API layer (raw network
--      packet forgery, a hooked/patched game process) — out of scope for
--      any client-side Lua-level mitigation, same as every other native-call
--      trust boundary already disclosed in this file's header.
-- ======================================================================

-- ======================================================================
-- SHARED PER-TICK ASSERTION HELPERS (QA FIX — prompt suppression on grant;
-- CANCELLABLE-WAIT FOLLOW-UP, this pass — see "CANCELLABLE MAINTENANCE
-- WAIT" immediately below for the second half of this fix). The shared
-- maintenance thread below (see "SHARED MAINTENANCE THREAD") picks its own
-- wait duration once per iteration, from whichever states were active AT
-- THE TOP of that iteration. A target going from fully idle (thread asleep
-- in its own coarse wait, the common case) to freshly bitten/dragged got,
-- before the QA fix below, NO enforcement native call at all until that
-- sleep happened to elapse on its own — up to ~500ms during which the
-- mechanic that just landed enforced nothing, long enough for an extra
-- sprint/attack/escape input the mechanic exists to prevent.
--
-- Each function below is the EXACT same native-call sequence the thread's
-- own per-tick branch for that effect already performs — extracted once,
-- not duplicated — and is invoked immediately, a single time, from the
-- RegisterNetEvent handler that turns the corresponding state on
-- (applyBiteHold / dragStarted / applyDragSpeedLimit below), in addition to
-- the thread's own per-tick call once it next wakes. A RegisterNetEvent
-- handler runs on receipt, independently of whatever the shared thread
-- happens to be doing — this bridge call alone only closes the ONSET delay
-- (enforcement begins the very tick the grant arrives); it does not, by
-- itself, make the thread itself wake up early for the frames after that.
-- That second half is CANCELLABLE MAINTENANCE WAIT below.
-- ======================================================================
local function AssertBiteHoldControlsOnTarget()
    DisableControlAction(0, INPUT_SPRINT, true)
    DisableControlAction(0, INPUT_ATTACK, true)
end

--- Mirrors the shared thread's own ActiveDragAsHolder per-tick block
--- (NetworkRequestControlOfEntity + AttachEntityToEntity, plus — NPC target
--- only — the direct move-rate override). Takes the same shape
--- ActiveDragAsHolder itself holds so both call sites (the thread's own
--- loop and dragStarted's immediate bridge call below) stay byte-for-byte
--- identical rather than risk drifting apart.
--- @param dragState { targetNetId: number, isPlayerTarget: boolean }
--- @return number? targetPed
local function AssertDragAsHolderTick(dragState)
    local targetPed = ResolveNetworkEntity(dragState.targetNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)

    if targetPed then
        NetworkRequestControlOfEntity(targetPed) -- best-effort, see header "NETWORK OWNERSHIP OF THE TARGET PED"

        -- PHASE3_SPEC.md §12.0 item 8's own "new finding": DetachEntity is
        -- very likely NOT ownership-gated either (citizenfx/fivem issue
        -- #3726), so a hostile target's own client can call it on itself at
        -- any moment. Re-asserting the attach EVERY TICK (never one-shot)
        -- is the ONLY thing that puts it back — binding guardrail 2.
        -- Offset/bone index are an UNREVIEWED placeholder, see header.
        AttachEntityToEntity(targetPed, PlayerPedId(), 0, 0.0, -0.6, 0.0, 0.0, 0.0, 0.0, true, false, false, false, 2, true)

        if not dragState.isPlayerTarget then
            -- NPC target: no relay problem for the speed-limit half either
            -- (this K9's own client already fully commands this entity) —
            -- re-asserted every tick, same discipline as the attach above.
            SetPedMoveRateOverride(targetPed, Config.Combat.PropDragging.dragSpeedMultiplier)
        end
    end

    return targetPed
end

--- Mirrors the shared thread's own ActiveDragSpeedLimit per-tick block —
--- see header "MOVE-RATE COMPOSER SCOPE" for the IsOwnModelK9() branch
--- reasoning, unchanged here; re-checked FRESH on every call (not decided
--- once at apply-time), since the correct branch depends on THIS client's
--- CURRENT model.
local function AssertDragSpeedLimitOnTarget()
    local ped = PlayerPedId()
    if IsOwnModelK9() and K9MoveRateModifiers then
        K9MoveRateModifiers.dragging = Config.Combat.PropDragging.dragSpeedMultiplier
        RecomputeK9MoveRate()
    else
        SetPedMoveRateOverride(ped, Config.Combat.PropDragging.dragSpeedMultiplier)
    end
end

-- ======================================================================
-- CANCELLABLE MAINTENANCE WAIT (this pass) — closes the residual gap the
-- previous pass's own header comment flagged: the shared maintenance
-- thread's coarse idle wait (100ms/500ms, "SHARED MAINTENANCE THREAD"
-- below) previously could not be aborted early, so a grant landing while
-- the thread was asleep in that wait got exactly ONE enforcement tick (the
-- bridge call above) and then nothing further until that sleep elapsed on
-- its own — up to ~500ms of unenforced window on top of the bridge call.
--
-- DESIGN NOTE, disclosed rather than silently substituted: the brief for
-- this fix named `promise.new()` + `SetTimeout()` + `Citizen.Await()` as
-- the standard Citizen-scripting cancellable-wait idiom. `promise` and
-- `SetTimeout` are now genuinely in .luacheckrc's read_globals (verified:
-- `grep -n promise .luacheckrc` shows both, with the primary-source
-- citation). `Citizen` (the table `Citizen.Await` hangs off) is NOT —
-- confirmed by actually running `luacheck` against a
-- `Citizen.Await(promise.new())` snippet, which reports "accessing
-- undefined variable Citizen" (Citizen is a genuine engine-provided global,
-- distinct from `promise`/`SetTimeout`, which are the two names
-- scheduler.lua/deferred.lua actually bind into `_G` — `Citizen` itself is
-- never re-bound as a bare global, only referenced via the table CFX's
-- runtime pre-seeds). Editing .luacheckrc to add "Citizen" is outside this
-- file's ownership boundary this pass (see HARD RULES), so this
-- implementation deliberately reaches the identical cancellable-wait
-- GUARANTEE (early-wake OR timeout, whichever first, whole-numbered
-- resolve-once semantics, no permanent park) without `Citizen.Await`:
-- instead of blocking the thread's own coroutine on the promise
-- (`Citizen.Await`'s job), `WaitCancellable` below registers its
-- CONTINUATION via the promise's own `:next()` callback (deferred.lua's
-- public, allowlist-clean API — no `Citizen` reference needed at all), and
-- the shared maintenance thread's `while true do` loop (below) is
-- restructured into a self-continuing local function so that callback can
-- actually drive the next tick. Functionally equivalent for this file's
-- purpose; flagged here as a deliberate substitution, not a silent
-- reinterpretation of the brief. If a later pass prefers a literal
-- `Citizen.Await`-blocking form, that only requires the owner of
-- .luacheckrc to add "Citizen" to read_globals — the design above does not
-- need to change to accommodate that, since `Citizen.Await(promise)` and
-- `promise:next(fn)` observe the exact same resolve() call identically.
--
-- SINGLE-RESOLUTION GUARANTEE (belt-and-suspenders, both independently
-- sufficient): (1) `WaitCancellable`/`WakeMaintenanceThread` both gate on
-- an identity check against `PendingMaintenanceWaitPromise`, clearing that
-- slot to nil in the SAME step as the check — since this resource's Lua
-- runs cooperatively (never two callbacks mid-execution at once), whichever
-- of "the SetTimeout fired" or "something called WakeMaintenanceThread"
-- runs first claims the promise; the other, running later, always finds
-- the slot already nil and does nothing. (2) Independently, deferred.lua's
-- own `resolve(deferred, state, value)` (this file's own read of the
-- primary source, not asserted from memory) only mutates `deferred.state`
-- `if deferred.state == 0` (PENDING) — a promise this file has already
-- resolved once is already past state 0, so even a hypothetical duplicate
-- `:resolve()` call would be a verified no-op at the library level, not
-- merely by this file's own convention.
--
-- NO PERMANENT PARK: `WaitCancellable` ALWAYS schedules the `SetTimeout`
-- side unconditionally, regardless of whether `WakeMaintenanceThread` is
-- ever called — so an "abandoned" wait (nothing ever wakes it) still
-- resolves, and therefore still continues the maintenance chain, at
-- exactly `ms` milliseconds, identical to a plain `Wait(ms)` would have. A
-- STALE `SetTimeout` from an already-superseded call (superseded by an
-- earlier `WakeMaintenanceThread()` call, or by a later `WaitCancellable`
-- call for the NEXT tick) is inert by the same identity check — it targets
-- a promise object `PendingMaintenanceWaitPromise` no longer references, so
-- it can never resolve, or otherwise affect, the wrong wait.
-- ======================================================================

--- Exactly one `WaitCancellable` call is ever outstanding at a time (the
--- shared maintenance thread is the only caller, and it never starts a new
--- one until the previous one's continuation has already fired) — a single
--- file-local slot, not a queue/set, is therefore sufficient. `nil` means
--- the thread is not currently parked in a cancellable wait at all (e.g.
--- it is mid-Wait(0) tick, or has not started yet).
local PendingMaintenanceWaitPromise = nil

--- Runs `onResume` once, either when `ms` milliseconds have elapsed (the
--- ordinary case — behaves exactly like `Wait(ms)` followed by continuing)
--- OR as soon as `WakeMaintenanceThread()` is called, WHICHEVER HAPPENS
--- FIRST. See header "CANCELLABLE MAINTENANCE WAIT" for the
--- single-resolution/no-permanent-park guarantees this relies on.
---
--- ERROR-VISIBILITY FIX, verified against the primary source before relying
--- on it (this file's own read of `deferred.lua`, and an empirical repro —
--- `p:next(function() error('boom') end); p:resolve()` prints nothing at
--- all and does not propagate): `:next()`'s own continuation runs inside
--- `deferred.lua`'s internal `pcall(deferred.success, ...)`, which SWALLOWS
--- an error raised in `onResume` completely — no console print, no
--- traceback, nothing — unlike the previous `while true do ... end` loop,
--- where an uncaught error inside the loop body propagated to FiveM's own
--- per-coroutine error boundary and printed a traceback (the thread still
--- died either way, but LOUDLY, not silently). `onResume` is therefore run
--- through an explicit `pcall` here with an explicit `print` on failure —
--- restoring that same "dies loudly, not silently" property this thread
--- already had before this pass, not a new guarantee invented for it. This
--- does not make the tick loop self-healing (an error still ends the
--- chain, exactly as an uncaught error in the old `while true do` loop
--- would have killed that thread too) — only VISIBLE again.
--- @param ms number
--- @param onResume fun()
local function WaitCancellable(ms, onResume)
    local waitPromise = promise.new()
    PendingMaintenanceWaitPromise = waitPromise

    waitPromise:next(function()
        local ok, err = pcall(onResume)
        if not ok then
            print(('[qbx_k9unit] combat.lua shared maintenance thread errored and has stopped: %s'):format(tostring(err)))
        end
    end)

    SetTimeout(ms, function()
        if PendingMaintenanceWaitPromise == waitPromise then
            PendingMaintenanceWaitPromise = nil
            waitPromise:resolve()
        end
    end)
end

--- Called from the RegisterNetEvent handlers that turn on a Wait(0)-class
--- state (applyBiteHold / dragStarted / applyDragSpeedLimit below) to cut
--- the shared maintenance thread's current coarse wait short, if it is
--- currently parked in one. A safe no-op when the thread is not currently
--- waiting on a cancellable promise at all (e.g. already mid-Wait(0)
--- because some OTHER Wait(0)-class state is already active — the thread
--- is already reasserting every frame in that case, nothing to wake).
---
--- Deliberately resolves via a fresh `SetTimeout(0, ...)` rather than
--- resolving `waitPromise` synchronously right here: this function is
--- called from INSIDE a RegisterNetEvent handler's own coroutine, and
--- resolving synchronously would run MaintenanceTick's entire continuation
--- (including its own subsequent Wait(0)/WaitCancellable calls) nested
--- inside that handler's call stack/coroutine instead of a fresh
--- SetTimeout-owned one — not incorrect (FiveM's scheduler tracks any
--- yielding coroutine generically), but an unnecessary coupling this
--- avoids for no behavioral cost: `SetTimeout(0, ...)` still resumes on
--- essentially the very next tick, the same order of magnitude as a
--- synchronous resolve. The identity re-check inside the deferred callback
--- (not just here) is what actually keeps this single-resolution-safe even
--- across that one-tick indirection.
local function WakeMaintenanceThread()
    if not PendingMaintenanceWaitPromise then return end -- nothing parked right now, nothing to wake

    SetTimeout(0, function()
        local waitPromise = PendingMaintenanceWaitPromise
        if waitPromise then
            PendingMaintenanceWaitPromise = nil
            waitPromise:resolve()
        end
    end)
end

if Config.Features.BiteAndHold then
    -- HOLDER-SIDE receivers — server/combat.lua's own header: "Sent ONLY to
    -- the HOLDING K9's own client — starts/ends its own local cosmetic
    -- stance."
    RegisterNetEvent('qbx_k9unit:client:biteHoldStarted', function(targetNetId, expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        MyEngagedTargetNetId = targetNetId
        PlayBiteHoldStance()
    end)

    RegisterNetEvent('qbx_k9unit:client:biteHoldEnded', function(targetNetId, reason)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        if MyEngagedTargetNetId ~= targetNetId then return end -- stale/foreign event, e.g. a race with a brand-new hold — never clear a DIFFERENT hold's state
        MyEngagedTargetNetId = nil
        ClearPedTasksImmediately(PlayerPedId())
    end)

    -- TARGET-SIDE CATEGORY B RELAY HANDLER — registered for EVERY client
    -- whenever BiteAndHold itself is on. See this file's header
    -- trust-boundary note: no PER-PLAYER access-gate belongs here, by
    -- design — the per-MECHANIC gate above is a different, narrower thing
    -- (whether this handler exists AT ALL on this server), not a
    -- per-invocation authorization check.
    --- PHASE3_SPEC.md §12.0 item 8 / server/combat.lua's own header: applies
    --- DisableControlAction on sprint/fire locally every frame until the
    --- (locally-derived, see this file's header CLOCK-DOMAIN NOTE) deadline
    --- or an endBiteHold arrives first, whichever is sooner. `holderNetId`
    --- is accepted per the contract but not currently consumed by this file
    --- (no target-side visual references the holder this pass — see the
    --- header's ANIMATION/ASSET STATUS note); kept as a named parameter,
    --- not discarded silently, so a future visual addition has it ready
    --- without a contract change.
    --- @param holderNetId number
    --- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header
    RegisterNetEvent('qbx_k9unit:client:applyBiteHold', function(holderNetId, expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        ActiveBiteHold = {
            holderNetId = holderNetId,
            localDeadline = GetGameTimer() + Config.Combat.BiteAndHold.maxDurationMs,
        }
        -- QA FIX (prompt suppression on grant) — see header "SHARED PER-TICK
        -- ASSERTION HELPERS": bridge the onset gap immediately rather than
        -- wait for the shared thread's own next wake.
        AssertBiteHoldControlsOnTarget()
        -- CANCELLABLE-WAIT FIX — see header "CANCELLABLE MAINTENANCE WAIT":
        -- cut the thread's own coarse wait short (if it is currently
        -- parked in one) so continuous per-frame reassertion resumes within
        -- about one tick, instead of up to ~500ms later.
        WakeMaintenanceThread()
    end)

    --- @param reason string
    RegisterNetEvent('qbx_k9unit:client:endBiteHold', function(reason)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        ActiveBiteHold = nil
    end)

    -- NPC-TARGET RELAY HANDLERS — sent ONLY to the REQUESTING K9's own
    -- client (never a broadcast, and never sent to the NPC's own "client,"
    -- since an NPC has none). See this file's header point 3 and
    -- server/combat.lua's own header "NPC-TARGET NATIVE EXECUTION CONTEXT"
    -- for why these exist. Unlike the TARGET-side handler above, these
    -- carry none of the §12.3 trust-boundary exposure (the K9's own client
    -- is already this resource's trusted actor for its own action).
    --
    -- HIGH-1 FIX (QA/coordinator finding, this session): NEITHER of these
    -- previously called NetworkRequestControlOfEntity before driving
    -- SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes on the NPC —
    -- this resource's OWN research note
    -- (phase2_notes/phase3_combat_natives.md §1/§4) explicitly names that
    -- native as the correct prerequisite for exactly this situation ("needed
    -- before an NPC-target client can reliably drive
    -- SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes/
    -- AttachEntityToEntity on an entity it doesn't already own network
    -- control of"), and on a populated server the requesting K9 is very
    -- unlikely to already own network control of a random ambient NPC —
    -- meaning this "REAL BUG FIX" pass's own fix could silently no-op in
    -- exactly the conditions it was written to correct. Requested here,
    -- best-effort (see this file's header "NETWORK OWNERSHIP OF THE TARGET
    -- PED" for the full, honest caveat, including this pass's correction of
    -- a stale claim there — NetworkHasControlOfEntity DOES exist, it is just
    -- deliberately not used as a gate here because doing so would require a
    -- blocking-wait idiom on this file's one shared thread, so this fires
    -- the request and proceeds regardless).
    --- @param npcNetId number
    --- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header CLOCK-DOMAIN NOTE
    RegisterNetEvent('qbx_k9unit:client:applyNpcBiteHold', function(npcNetId, expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        local npcPed = ResolveNetworkEntity(npcNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if not npcPed then return end -- despawned/streamed-out between the server's grant and this event arriving — nothing to apply to

        NetworkRequestControlOfEntity(npcPed)

        -- flags=0/clear=false reproduced VERBATIM from server/combat.lua's
        -- ORIGINAL server-side call (unchanged by this session's
        -- client-relay restructure, which only moved WHERE this runs, not
        -- WHAT it passes). SET_PED_FLEE_ATTRIBUTES' exact
        -- flags-bitmask/clear-boolean semantics were NOT independently
        -- verified this session (native-api-assistant's fetch of the PED
        -- native-decl section was blocked) — flagged here, not silently
        -- trusted, for whoever next has real doc access: a flags value of 0
        -- may mean this call does not meaningfully suppress fleeing at all,
        -- independent of the client-vs-server question this session did
        -- resolve.
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
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        ActiveNpcEffects[npcNetId] = nil
        local npcPed = ResolveNetworkEntity(npcNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if npcPed then
            NetworkRequestControlOfEntity(npcPed)
            SetBlockingOfNonTemporaryEvents(npcPed, false)
        end
    end)
end

if Config.Features.NonLethalTakedown then
    -- TARGET-SIDE CATEGORY B RELAY HANDLER — see BiteAndHold's own group
    -- above for the full trust-boundary/per-mechanic-gating reasoning,
    -- identical here.
    --- PHASE3_SPEC.md §12.0 item 8 / server/combat.lua's own header: applies
    --- the ragdoll + damage-bracket locally, bracket-before-ragdoll ordering,
    --- per phase2_notes/phase3_combat_natives.md §2 ("damage-bracket + health
    --- floor BEFORE the ragdoll task, never after") — same ordering
    --- applyNpcTakedown below uses for the NPC-target path. See this file's
    --- header "RAGDOLL FALL-DIRECTION" note for why this uses the TARGET's
    --- own forward vector rather than the K9's (the payload carries no K9
    --- reference).
    --- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header
    RegisterNetEvent('qbx_k9unit:client:forceRagdoll', function(expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
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
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        if not ActiveForcedRagdoll then return end
        ActiveForcedRagdoll = nil
        SetEntityCanBeDamaged(PlayerPedId(), true)
    end)

    -- NPC-TARGET RELAY HANDLERS — see BiteAndHold's own group above for the
    -- full reasoning (identical shape). HIGH-1 fix applied here too:
    -- NetworkRequestControlOfEntity before SetEntityCanBeDamaged/
    -- SetPedToRagdollWithFall — confidence note: this file's ORIGINAL
    -- native-api-assistant pass named SetEntityCanBeDamaged specifically
    -- (confirmed CLIENT-ONLY) but did NOT independently re-confirm
    -- NETWORK_REQUEST_CONTROL_OF_ENTITY's necessity for THIS specific
    -- native pairing the way phase2_notes/phase3_combat_natives.md's §1
    -- table does for SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes/
    -- AttachEntityToEntity by name — applying the SAME fix here on the
    -- strength of "any client-side ped-behavior/physics native aimed at an
    -- entity this client doesn't control is subject to the identical
    -- ownership question," which is a reasonable but NOT identically-sourced
    -- inference; graded lower confidence than the applyNpcBiteHold fix
    -- above for that reason, not silently presented as equally certain.
    --- @param npcNetId number
    --- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header CLOCK-DOMAIN NOTE
    RegisterNetEvent('qbx_k9unit:client:applyNpcTakedown', function(npcNetId, expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        local npcPed = ResolveNetworkEntity(npcNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if not npcPed then return end

        NetworkRequestControlOfEntity(npcPed)

        SetEntityCanBeDamaged(npcPed, false)

        -- HEALTH-FLOOR TOP-UP (this pass) — closes a gap the server/combat.lua
        -- owner found and removed the dead half of: `HandleTakedownRequest`'s
        -- NPC-branch server-side `SetEntityHealth(targetPed, healthFloor)`
        -- "backstop" was a silent no-op, because SET_ENTITY_HEALTH has NO
        -- FXServer server-side registration at all (confirmed: no
        -- ext/native-decls page for it — 404, checked directly — and
        -- `ServerGameState_Scripting.cpp`, the file that DOES register
        -- GET_ENTITY_HEALTH/GET_ENTITY_MAX_HEALTH as apiset:server, has no
        -- SET_ENTITY_HEALTH/SET_PED_HEALTH registration anywhere). That 404
        -- is expected and is NOT evidence against CLIENT-side validity —
        -- SET_ENTITY_HEALTH is a genuine base GTA native (verified against
        -- the primary CitizenFX native database at
        -- https://runtime.fivem.net/doc/natives.json, ENTITY namespace, hash
        -- 0x6B76DC1F3AE6E6A3, real params `(Entity entity, int health)`) —
        -- and this exact native is ALREADY called client-side elsewhere in
        -- this very codebase (client/medkit.lua's applyMedkitHeal, self-
        -- applied to the calling client's own ped) with no reported issue.
        -- This call differs from that precedent only in TARGET (an NPC this
        -- client doesn't inherently own, not its own ped) — the same
        -- ownership caveat as every other native in this handler, which is
        -- why NetworkRequestControlOfEntity above already precedes it,
        -- best-effort, same as it does for SetEntityCanBeDamaged/
        -- SetPedToRagdollWithFall below (see header "NETWORK OWNERSHIP OF
        -- THE TARGET PED" for the full, honest caveat — this call inherits
        -- it, not a new one).
        --
        -- ORDERING: BEFORE the ragdoll task below, matching this handler's
        -- own already-documented "damage-bracket + health floor BEFORE the
        -- ragdoll task, never after" convention (see this RegisterNetEvent
        -- group's own header comment above, and forceRagdoll's identical
        -- ordering for the player-target path — that path has no equivalent
        -- top-up because server/combat.lua never attempted a player-target
        -- SetEntityHealth call in the first place, only the NPC branch did).
        --
        -- SEVERITY: defense in depth, not the primary protection — the
        -- damage-bracket (SetEntityCanBeDamaged above) and the ragdoll
        -- (below) are what actually protect this NPC for the duration of
        -- the takedown window, and both are already live. This is a
        -- ONE-TIME top-up for an NPC that was ALREADY below the configured
        -- floor the instant the ragdoll opens (e.g. it took lethal damage
        -- getting here) — never a repeated/per-tick heal, and never raises
        -- an NPC above the floor if it's already at or above it.
        if GetEntityHealth(npcPed) < Config.Combat.NonLethalTakedown.healthFloor then
            SetEntityHealth(npcPed, Config.Combat.NonLethalTakedown.healthFloor)
        end

        -- Unlike forceRagdoll above (player target, falls back to the
        -- TARGET's own forward vector — see header "RAGDOLL FALL-DIRECTION"),
        -- this handler runs directly on the K9's OWN client, so the REAL K9
        -- facing direction is simply this client's own PlayerPedId() —
        -- strictly better fidelity than the player-target path, not a
        -- fallback.
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
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        ActiveNpcEffects[npcNetId] = nil
        local npcPed = ResolveNetworkEntity(npcNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if npcPed then
            NetworkRequestControlOfEntity(npcPed)
            SetEntityCanBeDamaged(npcPed, true)
        end
    end)
end

if Config.Features.PropDragging then
    -- HOLDER-SIDE receiver — sent ONLY to the K9's own client. Starts the
    -- maintenance thread's per-tick AttachEntityToEntity re-assertion
    -- (Category A, see header "PROP DRAGGING — HOLDER-SIDE ATTACH
    -- RE-ASSERTION") and, when the target is an NPC, that SAME per-tick
    -- block also drives its move rate directly — no separate NPC relay
    -- event exists for drag (unlike bite/takedown's applyNpc*/endNpc*
    -- pair), because this payload's own `isPlayerTarget` field is all this
    -- client needs.
    --- @param targetNetId number
    --- @param isPlayerTarget boolean
    --- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header CLOCK-DOMAIN NOTE
    RegisterNetEvent('qbx_k9unit:client:dragStarted', function(targetNetId, isPlayerTarget, expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        ActiveDragAsHolder = {
            targetNetId = targetNetId,
            isPlayerTarget = isPlayerTarget == true,
            localDeadline = GetGameTimer() + Config.Combat.PropDragging.maxDragDurationMs,
        }
        -- QA FIX (prompt suppression on grant) — see header "SHARED
        -- PER-TICK ASSERTION HELPERS": bridge the onset gap immediately
        -- rather than wait for the shared thread's own next wake.
        AssertDragAsHolderTick(ActiveDragAsHolder)
        -- CANCELLABLE-WAIT FIX — see header "CANCELLABLE MAINTENANCE WAIT".
        WakeMaintenanceThread()
    end)

    --- HOLDER-SIDE receiver — stops the re-assertion loop, calls
    --- DetachEntity once (best-effort — see header on DetachEntity's own
    --- lack of an ownership gate; if a hostile target already self-detached,
    --- this call is simply redundant, never harmful), and — NPC target
    --- only — restores that NPC's move rate to neutral (an NPC has no "own
    --- client" to have restored it for it, unlike the player-target case
    --- below, which restores itself via endDragSpeedLimit).
    --- @param targetNetId number
    --- @param reason string
    RegisterNetEvent('qbx_k9unit:client:dragEnded', function(targetNetId, reason)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        if not ActiveDragAsHolder or ActiveDragAsHolder.targetNetId ~= targetNetId then return end -- stale/foreign event, e.g. a race with a brand-new drag — never clear a DIFFERENT drag's state

        local wasNpcTarget = not ActiveDragAsHolder.isPlayerTarget
        local targetPed = ResolveNetworkEntity(targetNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if targetPed then
            NetworkRequestControlOfEntity(targetPed)
            DetachEntity(targetPed, true, false)
            if wasNpcTarget then
                SetPedMoveRateOverride(targetPed, 1.0)
            end
        end

        ActiveDragAsHolder = nil
    end)

    -- TARGET-SIDE CATEGORY B RELAY HANDLER (player target only — an NPC has
    -- no "own client" to relay to, see dragStarted above) — registered for
    -- EVERY client whenever PropDragging itself is on, same trust-boundary
    -- posture as BiteAndHold/NonLethalTakedown's own target-side handlers
    -- above.
    --- @param expiresAt number -- server GetGameTimer() timestamp; NOT compared directly against this client's own clock, see header CLOCK-DOMAIN NOTE
    RegisterNetEvent('qbx_k9unit:client:applyDragSpeedLimit', function(expiresAt)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        ActiveDragSpeedLimit = {
            localDeadline = GetGameTimer() + Config.Combat.PropDragging.maxDragDurationMs,
        }
        -- QA FIX (prompt suppression on grant) — see header "SHARED
        -- PER-TICK ASSERTION HELPERS": bridge the onset gap immediately
        -- rather than wait for the shared thread's own next wake.
        AssertDragSpeedLimitOnTarget()
        -- CANCELLABLE-WAIT FIX — see header "CANCELLABLE MAINTENANCE WAIT".
        WakeMaintenanceThread()
    end)

    --- @param reason string
    RegisterNetEvent('qbx_k9unit:client:endDragSpeedLimit', function(reason)
        if source ~= 65535 then return end -- server-origin guard, see header "SOURCE-ORIGIN GUARD"
        if not ActiveDragSpeedLimit then return end
        ActiveDragSpeedLimit = nil

        local ped = PlayerPedId()
        -- See header "MOVE-RATE COMPOSER SCOPE" for why this branches on
        -- IsOwnModelK9() rather than unconditionally going through the
        -- composer.
        if IsOwnModelK9() and K9MoveRateModifiers then
            K9MoveRateModifiers.dragging = 1.0
            RecomputeK9MoveRate()
        else
            SetPedMoveRateOverride(ped, 1.0)
        end

        -- Defense in depth, same posture as endForceRagdoll's own restore
        -- above: guarantee this client is not left attached even if the
        -- K9's own dragEnded-triggered DetachEntity call was lost in
        -- transit or never sent (e.g. the K9 disconnected before its own
        -- teardown event fired) — idempotent, harmless if already detached.
        DetachEntity(ped, true, false)
    end)
end

-- ======================================================================
-- SHARED MAINTENANCE THREAD — single shared thread (never one per active
-- effect), mirroring server/combat.lua's own "one shared maintenance
-- thread, not one thread per active effect" discipline (which itself
-- mirrors server/tracking.lua's PruneTrackableLogs precedent).
--
-- QA FIX (backstop starvation, this pass) — the ORIGINAL structure here was
-- a single `if <Wait(0)-class states> then ... else <Wait(0)-class states'
-- deadline checks skipped entirely, other states' deadline checks run>
-- end`, i.e. it treated "which native calls need Wait(0) this tick" and
-- "which effects' expiry backstops get checked at all this tick" as the SAME
-- decision. Those are not the same player, let alone the same role: a
-- player can simultaneously be a BiteAndHold TARGET (ActiveBiteHold) and an
-- NPC-effect HOLDER (ActiveNpcEffects, from that same player's own K9
-- separately biting/taking down an NPC) — the server does not treat these
-- roles as mutually exclusive, and PropDragging's own ActiveDragAsHolder/
-- ActiveDragSpeedLimit added since only widened the same combinable set.
-- While ANY Wait(0)-class state was truthy, the old code's `else` branch —
-- the ONLY place ActiveForcedRagdoll's and every ActiveNpcEffects entry's
-- deadline backstop were checked — never ran at all, for as long as the
-- Wait(0)-class state stayed active. A lost endNpcBiteHold/endNpcTakedown/
-- endForceRagdoll message could then leave that OTHER effect's
-- damage-immunity or flee-suppression window stuck past its own
-- Config.Combat.*.maxDurationMs/ragdollDurationMs bound for as long as the
-- unrelated Wait(0)-class effect kept running — up to that effect's own
-- ~11s window, on top of whatever the stuck effect's own bound already was.
-- FIXED below by decoupling the two questions entirely: every effect's own
-- per-tick native-reassertion AND its own expiry backstop are gated ONLY on
-- THAT effect's own state variable, every single loop iteration,
-- unconditionally of every other effect's state. Only the Wait() DURATION
-- at the bottom of the loop still depends on which states are active
-- (unchanged reasoning from before this fix — see below), since that
-- decision genuinely is "the largest wait every currently-active state can
-- tolerate," unlike "should this state's backstop run at all," which must
-- never depend on a different state.
--
--   - BiteAndHold (a Category B effect applied TO this client), an active
--     drag AS HOLDER (Category A attach re-assertion, PLUS — NPC target
--     only — the Category-A-equivalent direct move-rate override), and an
--     active drag AS TARGET (Category B move-rate relay) all demand
--     Wait(0) — DisableControlAction/AttachEntityToEntity/
--     SetPedMoveRateOverride's own contracts each independently require
--     reasserting every single frame (same "must reassert every frame"
--     discipline as client/movement.lua's AgilityBasicJump suppression
--     thread, and PHASE3_SPEC.md §12.0 item 8's own new finding on
--     DetachEntity's lack of an ownership gate for the attach specifically).
--   - Forced ragdoll (also applied TO this client) and every NPC-relay
--     bite/takedown effect (applied BY this client, to an NPC, on this K9's
--     own request) need no per-frame native call at all — SetEntityCanBeDamaged/
--     SetBlockingOfNonTemporaryEvents are persistent flags, not per-frame
--     ones, and SetPedToRagdollWithFall is a one-shot task call — only a
--     periodic deadline check is needed for either, so a coarser Wait
--     suffices while none of the three Wait(0)-class states above is
--     active.
--   - Otherwise (nothing active, the overwhelming common case for any
--     player who is never targeted and isn't currently a K9 mid-action): a
--     cheap idle poll, never a tight loop spinning for a feature that
--     isn't currently doing anything on this client at all.
--
-- QA FIX (target death, this pass) — see the ActiveBiteHold block below for
-- a second, unrelated fix landed in the same pass: BiteAndHold previously
-- had no 'target_died' end condition at all, so a target killed by
-- unrelated gunfire and respawned kept sprint/fire disabled on the NEW body
-- (DisableControlAction always targets whatever PlayerPedId() currently
-- returns, which after a resurrect is the same handle, healed) until the
-- ORIGINAL hold's timer elapsed. Bounded by maxDurationMs already (not an
-- unbounded trap), but undisclosed and needlessly slow. Fixed client-side by
-- treating this client's own death as an immediate local end for the
-- restriction; see that block's own comment for why this cannot fully close
-- the gap without a server-side end condition, and what server/combat.lua
-- would need to do so.
--
-- FOLLOW-UP (this pass) — ActiveForcedRagdoll had the IDENTICAL exposure
-- (SetEntityCanBeDamaged(ped, false) is a persistent flag surviving a
-- respawn on the same ped handle, exactly like DisableControlAction's own
-- exposure above) and was previously the ONE state here with no equivalent
-- handling. Given the same treatment below, same rationale, same bound
-- (ragdollDurationMs, not unbounded) — see that block's own comment. Unlike
-- ActiveBiteHold, no speculative TriggerServerEvent report is added for this
-- one: bite-hold's own reportBiteHoldTargetDied call is already disclosed
-- above as inert (no server-side listener exists yet either), and inventing
-- a second, differently-named event with the same "nothing listens yet"
-- status would just be a second copy of the same disclosed gap, not a step
-- toward closing it — left for whoever lands the server-side condition to
-- decide whether one shared event or two is the right shape.
--
-- CANCELLABLE-WAIT FOLLOW-UP (this pass) — the structure below is no longer
-- a literal `while true do ... end`; every "loop iteration" reference above
-- now means one call of the local `MaintenanceTick` function defined below,
-- self-continuing (via a tail call for the Wait(0) branch, or via
-- `WaitCancellable`'s own `:next()` continuation for the coarse-wait
-- branch) rather than looping. The decoupled-backstop/Wait(0)-class
-- reasoning above is otherwise unchanged by this restructure — only HOW the
-- thread reaches its next tick changed, not which native calls or backstop
-- checks run on it. See "CANCELLABLE MAINTENANCE WAIT" (above, near
-- WaitCancellable's own definition) for the actual fix this pass makes:
-- the coarse-wait branch can now be cut short the instant a Wait(0)-class
-- state turns on, instead of always running out its full 100/500ms.
-- ======================================================================
CreateThread(function()
    -- Recursive self-continuing tick (not a `while true do` loop) — see
    -- header "CANCELLABLE MAINTENANCE WAIT" for why: a plain `while true do
    -- ... Wait(ms) ... end` cannot be interrupted early without a
    -- coroutine-yield primitive (`Citizen.Await`, not currently
    -- allowlisted); a promise `:next()` callback, by contrast, can only
    -- drive a NEW function call, not resume an already-suspended loop body.
    -- Each call below is one "tick," equivalent to one previous loop
    -- iteration: the Wait(0)-class branch below tail-calls itself directly
    -- (`return MaintenanceTick()`, a genuine Lua 5.4 tail call — no stack
    -- growth even under a long run of continuous per-frame ticks), and the
    -- coarse-wait branch re-enters via WaitCancellable's own `:next()`
    -- continuation instead of a blocking `Wait(ms)`.
    local function MaintenanceTick()
        local now = GetGameTimer()

        if ActiveBiteHold then
            local myPed = PlayerPedId()

            if IsEntityDead(myPed) then
                -- TARGET DIED mid-hold (e.g. unrelated gunfire) — stop
                -- enforcing immediately rather than waiting for
                -- ActiveBiteHold.localDeadline. Without this, the
                -- DisableControlAction calls below would keep firing every
                -- tick against whatever PlayerPedId() returns, which after
                -- this ped is resurrected (same handle, healed — the
                -- standard FiveM respawn flow does not allocate a new ped)
                -- is the player's OWN restored body, wrongly still
                -- sprint/fire-suppressed until the original hold's timer
                -- ran out. Clearing here the moment death is observed (this
                -- thread already runs at Wait(0) while ActiveBiteHold is
                -- set, so this is detected within a frame or two of death,
                -- well before any respawn timer elapses) means no further
                -- DisableControlAction call ever lands on the resurrected
                -- ped.
                --
                -- CLIENT-SIDE HALF ONLY — this does not, and cannot, tell
                -- server/combat.lua the hold ended early: this file has no
                -- access-gate/authority to unilaterally end the server's own
                -- K9ActiveEffect bookkeeping, and the HOLDING K9's own
                -- client (MyEngagedTargetNetId / IsBiteHoldEngaged) is a
                -- completely different client that receives no signal from
                -- this block at all. Reporting the death is the best this
                -- half can do; it does NOT by itself free the holder's
                -- "Release" toggle or let the server stop counting this as
                -- an active hold — that still needs a server-side
                -- 'target_died' end condition (see below) to be complete.
                -- Best-effort notify so server/combat.lua CAN act on it once
                -- that handler exists — inert (no registered listener) until
                -- it does, same "client fires ahead of the server catching
                -- up" pattern already used elsewhere in this resource for a
                -- not-yet-landed contract.
                TriggerServerEvent('qbx_k9unit:server:reportBiteHoldTargetDied')
                ActiveBiteHold = nil
            else
                AssertBiteHoldControlsOnTarget() -- see header "SHARED PER-TICK ASSERTION HELPERS"

                if now >= ActiveBiteHold.localDeadline then
                    -- Backstop only — see header "DEFENSE IN DEPTH". In the
                    -- normal case server/combat.lua's own maintenance
                    -- thread already sent endBiteHold before this ever
                    -- fires.
                    ActiveBiteHold = nil
                end
            end
        end

        if ActiveDragAsHolder then
            -- See header "SHARED PER-TICK ASSERTION HELPERS" — this is the
            -- exact same NetworkRequestControlOfEntity/AttachEntityToEntity/
            -- (NPC-target) SetPedMoveRateOverride sequence dragStarted's own
            -- handler above already runs once, immediately, on grant; this
            -- is the CONTINUOUS every-tick reassertion of the same thing
            -- (PHASE3_SPEC.md §12.0 item 8's own "new finding": DetachEntity
            -- is very likely NOT ownership-gated either, citizenfx/fivem
            -- issue #3726, so a hostile target's own client can call it on
            -- itself at any moment — re-asserting the attach EVERY TICK,
            -- never one-shot, is the only thing that puts it back, binding
            -- guardrail 2).
            local targetPed = AssertDragAsHolderTick(ActiveDragAsHolder)

            if now >= ActiveDragAsHolder.localDeadline then
                -- Backstop only — see header "DEFENSE IN DEPTH". In the
                -- normal case server/combat.lua's own maintenance
                -- thread already sent dragEnded before this ever fires.
                if targetPed then
                    DetachEntity(targetPed, true, false)
                    if not ActiveDragAsHolder.isPlayerTarget then
                        SetPedMoveRateOverride(targetPed, 1.0)
                    end
                end
                ActiveDragAsHolder = nil
            end
        end

        if ActiveDragSpeedLimit then
            local myPed = PlayerPedId()

            -- CORRECTNESS FIX (this pass) — same shape and rationale as
            -- ActiveBiteHold's/ActiveForcedRagdoll's own IsEntityDead
            -- branches above (mirrored deliberately, not reinvented):
            -- SetPedMoveRateOverride is a PERSISTENT flag on this ped
            -- handle, exactly like DisableControlAction's per-frame
            -- reassertion and SetEntityCanBeDamaged's own persistent flag
            -- are for the other two states — FiveM respawn reuses this
            -- same handle, so without this branch a target killed by
            -- unrelated means mid-drag would come back RESURRECTED still
            -- speed-limited (and, worse, this file's own
            -- AttachEntityToEntity-adjacent DetachEntity backstop never ran
            -- either) until ActiveDragSpeedLimit.localDeadline elapsed.
            -- Bounded already by maxDragDurationMs (not an unbounded trap),
            -- but the exact same disclosed inconsistency class this
            -- resource already fixed once for the other two Category B
            -- target-side states — closed here too, for full consistency,
            -- rather than left as the one state that missed the fix.
            if IsEntityDead(myPed) then
                ActiveDragSpeedLimit = nil
                if IsOwnModelK9() and K9MoveRateModifiers then
                    K9MoveRateModifiers.dragging = 1.0
                    RecomputeK9MoveRate()
                else
                    SetPedMoveRateOverride(myPed, 1.0)
                end
                DetachEntity(myPed, true, false) -- defense in depth, same reasoning as endDragSpeedLimit's own restore
            else
                -- See header "SHARED PER-TICK ASSERTION HELPERS" — same
                -- IsOwnModelK9()-branched assertion applyDragSpeedLimit's own
                -- handler above already runs once, immediately, on grant; this
                -- is the CONTINUOUS every-tick reassertion of the same thing.
                AssertDragSpeedLimitOnTarget()

                if now >= ActiveDragSpeedLimit.localDeadline then
                    -- Backstop only — see header "DEFENSE IN DEPTH".
                    ActiveDragSpeedLimit = nil
                    if IsOwnModelK9() and K9MoveRateModifiers then
                        K9MoveRateModifiers.dragging = 1.0
                        RecomputeK9MoveRate()
                    else
                        SetPedMoveRateOverride(myPed, 1.0)
                    end
                    DetachEntity(myPed, true, false) -- defense in depth, same reasoning as endDragSpeedLimit's own restore
                end
            end
        end

        if ActiveForcedRagdoll then
            local myPed = PlayerPedId()

            -- QA FIX (target death, this pass) — same shape and rationale
            -- as ActiveBiteHold's own IsEntityDead branch above (mirrored
            -- deliberately rather than inventing a second one): FiveM
            -- respawn reuses this exact ped handle, so without this,
            -- SetEntityCanBeDamaged(ped, true) would not run until
            -- ActiveForcedRagdoll.localDeadline, leaving the RESURRECTED
            -- body briefly undamageable — bounded by ragdollDurationMs
            -- already (not an unbounded trap), but the same disclosed
            -- inconsistency class this resource has already had once (an
            -- invincibility window nobody intended). Clearing here restores
            -- damageability the moment death is observed (detected within a
            -- frame or two, same as ActiveBiteHold — this thread already
            -- runs at Wait(0) while ActiveForcedRagdoll is set).
            --
            -- CLIENT-SIDE HALF ONLY — see ActiveBiteHold's own IsEntityDead
            -- branch above for the identical caveat: this cannot by itself
            -- tell server/combat.lua the ragdoll ended early. See this
            -- thread's own header "QA FIX (target death, this pass)"
            -- FOLLOW-UP note for why no speculative TriggerServerEvent
            -- report is added here, unlike ActiveBiteHold's own block.
            if IsEntityDead(myPed) then
                ActiveForcedRagdoll = nil
                SetEntityCanBeDamaged(myPed, true)
            else
                if now >= ActiveForcedRagdoll.localDeadline then
                    -- Backstop only — see header "DEFENSE IN DEPTH".
                    -- Restoring damageability is the load-bearing half of
                    -- this backstop (an un-restored bracket is a
                    -- target-side exploit, not merely a UX bug), so this
                    -- branch does it directly rather than waiting on a lost
                    -- network event. Checked EVERY tick, independently of
                    -- every other state above — see this thread's own
                    -- header "QA FIX (backstop starvation)" for why this
                    -- must never be conditioned on ActiveBiteHold/
                    -- ActiveDragAsHolder/ActiveDragSpeedLimit's own
                    -- truthiness.
                    ActiveForcedRagdoll = nil
                    SetEntityCanBeDamaged(myPed, true)
                end
            end
        end

        -- Same backstop reasoning as ActiveForcedRagdoll above, applied
        -- to every currently-active NPC relay effect — a lost
        -- endNpcBiteHold/endNpcTakedown network event must not leave an
        -- NPC permanently flee-suppressed or permanently undamageable.
        -- Also checked EVERY tick unconditionally, same fix.
        for npcNetId, effect in pairs(ActiveNpcEffects) do
            if now >= effect.localDeadline then
                ActiveNpcEffects[npcNetId] = nil
                local npcPed = ResolveNetworkEntity(npcNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
                if npcPed then
                    NetworkRequestControlOfEntity(npcPed)
                    if effect.kind == 'bite' then
                        SetBlockingOfNonTemporaryEvents(npcPed, false)
                    else
                        SetEntityCanBeDamaged(npcPed, true)
                    end
                end
            end
        end

        -- Wait DURATION selection only — unlike the backstop checks above,
        -- this genuinely is a single "largest wait every currently-active
        -- state can tolerate" decision, so it stays a single if/elseif/else
        -- here (see this thread's own header for why this is NOT the same
        -- kind of decision as "should a backstop run at all").
        if ActiveBiteHold or ActiveDragAsHolder or ActiveDragSpeedLimit then
            Wait(0)
            return MaintenanceTick() -- tail call, see this function's own opening comment — no stack growth
        else
            -- CANCELLABLE — see header "CANCELLABLE MAINTENANCE WAIT". Behaves
            -- exactly like Wait(ms) followed by continuing, unless
            -- WakeMaintenanceThread() (called from applyBiteHold/dragStarted/
            -- applyDragSpeedLimit on grant) cuts it short.
            WaitCancellable(ActiveForcedRagdoll and 100 or 500, MaintenanceTick)
        end
    end

    MaintenanceTick()
end)

-- ======================================================================
-- onResourceStop RESTORE — HIGH-2 red-team/QA finding (this session): this
-- file previously had ZERO onResourceStop handler despite setting several
-- PERSISTENT native flags/relationships (SetEntityCanBeDamaged,
-- SetBlockingOfNonTemporaryEvents, SetPedMoveRateOverride, the
-- AttachEntityToEntity relationship itself) that outlive this resource's
-- own CreateThread loop — a resource restart mid-effect would otherwise
-- leave a live player permanently undamageable (ActiveForcedRagdoll) or
-- permanently move-rate-limited (ActiveDragSpeedLimit), or leave an NPC
-- permanently flee-suppressed/undamageable/slowed/attached
-- (ActiveNpcEffects / ActiveDragAsHolder), with no script left running to
-- ever undo it — the exact class of bug client/vision.lua's own
-- onResourceStop, and client/movement.lua's own two onResourceStop
-- handlers, already exist in this resource to close for its other
-- persistent-flag natives. Every branch below is defensive/idempotent —
-- safe to run even when the corresponding state was never active this
-- session (DoesEntityExist guards throughout, and restoring an
-- already-neutral flag is harmless). ActiveBiteHold needs NO entry here:
-- DisableControlAction is a per-frame-only effect with no persistent flag
-- of its own — it stops being reasserted the instant this resource's own
-- thread dies with it, same reasoning client/movement.lua's AgilityBasicJump
-- suppression thread already relies on.
-- ======================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if ActiveForcedRagdoll then
        SetEntityCanBeDamaged(PlayerPedId(), true)
    end

    for npcNetId, effect in pairs(ActiveNpcEffects) do
        local npcPed = ResolveNetworkEntity(npcNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if npcPed then
            NetworkRequestControlOfEntity(npcPed)
            if effect.kind == 'bite' then
                SetBlockingOfNonTemporaryEvents(npcPed, false)
            else
                SetEntityCanBeDamaged(npcPed, true)
            end
        end
    end

    if ActiveDragAsHolder then
        local targetPed = ResolveNetworkEntity(ActiveDragAsHolder.targetNetId) -- REFACTOR_ROADMAP.md item 2 (client/main.lua)
        if targetPed then
            NetworkRequestControlOfEntity(targetPed)
            DetachEntity(targetPed, true, false)
            if not ActiveDragAsHolder.isPlayerTarget then
                SetPedMoveRateOverride(targetPed, 1.0)
            end
        end
    end

    if ActiveDragSpeedLimit then
        local ped = PlayerPedId()
        if IsOwnModelK9() and K9MoveRateModifiers then
            K9MoveRateModifiers.dragging = 1.0
            RecomputeK9MoveRate()
        else
            SetPedMoveRateOverride(ped, 1.0)
        end
        DetachEntity(ped, true, false)
    end
end)
