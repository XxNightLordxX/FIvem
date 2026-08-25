--[[
    qbx_k9unit/client/movement.lua

    Phase 1 scaffold (coder-architect). Owns everything about the K9
    player's own body: the camera toggle, the "Sit" self-emote, and the
    two-player leash mechanic in full (consent handshake, the elastic
    movement restriction while attached, and zero-consent detach). Native
    run/jump/crouch locomotion needs no wrapper code — it's inherent to
    the ped model — so it isn't stubbed here beyond the AgilityBasicJump
    note near the bottom.

    PHASE 3 ADDITION (that pass, coder-architect): also owned
    Config.Features.AgilityAdvanced (fence/window vault approximation) —
    PHASE3_SPEC.md §12.5.5, §12.1 sub-phase 3a. Entirely client-local,
    self-body movement only, no target ped/player involved anywhere,
    unaffected by PHASE3_SPEC.md §12.0 item 8's still-open (as of that
    pass) client-relay question, which only concerns effects applied to a
    DIFFERENT entity. Every other Phase 3 sub-feature (BiteAndHold/
    NonLethalTakedown/PropDragging/HandlerDownDefense) is deliberately NOT
    touched here — see config.lua's own Config.Combat header comment for
    exactly why each one is still blocked.

    EXTRACTED (this pass): the ADVANCED AGILITY block above has moved out
    to its own file, client/agility.lua — see that file's own header for
    the full "why this one, not the rest of this file" reasoning. Short
    version: it was the one concern in this file that shared no local
    state with anything else here and had no other file depending on its
    locals, confirmed by reading this whole file and grepping the tree
    before moving it. Every OTHER concern this file still owns (camera
    toggle, Sit self-emote, the leash mechanic, the move-rate composer,
    AgilityBasicJump's suppression thread, door interaction) was
    deliberately left in place — none of them stand alone the same way
    (the move-rate composer alone is read by three other files, and the
    leash pull-back thread/door-interaction canInteract checks/vault all
    shared the exact same IsInK9Vehicle()-tucked-K9 exclusion, evidence
    they're one connected "own-body movement gating" concern, not several
    independent ones). "This file is the largest client file" was
    deliberately NOT treated as its own reason to split further — a prior
    refactor pass already advised against cosmetic restructuring of this
    codebase's long files, and every remaining section here earns its
    place through real cross-references to the others, not just proximity.

    ======================================================================
    EVENT/CALLBACK CONTRACT — certification events are documented in full
    in server/certifications.lua / client/main.lua (kept in sync manually,
    not re-duplicated here). THIS FILE owns the client side of the leash
    subsystem, documented in full in server/main.lua's header — read that
    file together with this one for the complete picture. Summary of what
    THIS FILE registers/triggers:

    Server events (client->server):
    - 'qbx_k9unit:server:requestLeashAttach' (targetServerId: number)
    - 'qbx_k9unit:server:respondLeashAttach' (fromServerId: number, accepted: boolean)
    - 'qbx_k9unit:server:detachLeash' ()

    Client events (server->client):
    - 'qbx_k9unit:client:leashAttachRequest' (fromServerId: number) [THIS FILE]
    - 'qbx_k9unit:client:leashAttached' (partnerServerId: number, isConstrained: boolean) [THIS FILE]
    - 'qbx_k9unit:client:leashDetached' (reason: string) [THIS FILE]
    ======================================================================

    PHASE 4 ADDITION (this pass, coder-frontend, real-bug fix): also owns
    the shared K9 move-rate composer, `K9MoveRateModifiers` (table) +
    `RecomputeK9MoveRate()` (function) — PHASE4_SPEC.md §13.0 Decision 2.
    QA had found client/wellbeing.lua unconditionally writing
    `K9MoveRateModifiers.fatigue`/`.injury`/`.mood` and calling
    `RecomputeK9MoveRate()` with neither symbol defined anywhere in this
    codebase — latent only because every wellbeing feature flag defaults to
    `false` in config.lua, and a real bug (hard error, "attempt to index a
    nil value") the instant one is enabled. This is the real fix: the
    composer itself, not a guard added to wellbeing.lua that would have
    silently swallowed every wellbeing speed-penalty write instead. See the
    "MOVE-RATE COMPOSER" block below (near AgilityBasicJump) for the full
    writeup: composition rule, clamp range and why, the check that this
    doesn't fight AgilityBasicJump/the leash pull-back/client/agility.lua's
    AgilityAdvanced vault, and an honest confidence grading on
    `SetPedMoveRateOverride` itself.

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        ToggleK9Camera()
        K9Sit()
        RequestLeashAttach(targetPlayerServerId: number)  -- was named
            AttachLeash() in the earlier (pre-consent) scaffold draft;
            renamed because it no longer attaches anything by itself, it
            only sends a request.
        DetachLeash()
        IsLeashed() -> boolean
    - THIS FILE exposes the resource-global move-rate composer consumed by
      client/wellbeing.lua and client/progression.lua (PHASE4_SPEC.md §13.0
      Decision 2), and reserves a slot for Phase 3's PropDragging
      (client/combat.lua) to use once that lands:
        K9MoveRateModifiers (table)  -- named multiplier contributions, one
            key per contributing system (`fatigue`, `injury`, `mood`,
            `xpTier`, `dragging`), each defaulting to 1.0 (no effect).
            Callers set their OWN key directly (e.g.
            `K9MoveRateModifiers.fatigue = 0.85`) and then call
            RecomputeK9MoveRate() — never call SetPedMoveRateOverride
            directly from any other file.
        RecomputeK9MoveRate() -- composes every present modifier
            multiplicatively, clamps to [0.1, 2.0], and makes the single
            real SetPedMoveRateOverride call for the K9's own ped. Safe to
            call with no valid/K9 ped (no-op/neutral-reset, never an error).
    - THIS FILE calls client/main.lua's global CanShowK9UI() before
      initiating a request (radial.lua is also expected to gate
      visibility, but per SPEC.md §3's "must not be triggerable by a
      modified client" spirit, don't rely solely on the caller having
      already checked — and the server re-validates independently anyway,
      see server/main.lua's CheckLeashEligibility).
    - THIS FILE registers the "Attach Leash" ox_target option on nearby
      player peds (the SPEC.md §6.1 leash bullet's "either the K9 or a
      nearby officer initiates 'Attach Leash' (ox_target) on the other").
      client/vehicle.lua owns the vehicle ox_target option instead; keep
      that split — this file should never touch vehicles, vehicle.lua
      should never touch leash/ox_target-on-peds.
    - client/radial.lua's "Attach/Detach Leash" item is a context-sensitive
      SELF-initiated alternative entry point: if not IsLeashed(), it finds
      a nearby candidate and calls RequestLeashAttach(candidateServerId);
      if IsLeashed(), it calls DetachLeash(). Both surfaces (ox_target and
      radial) end up calling the SAME two functions — don't let a second,
      divergent leash-request code path grow in radial.lua.
    - THIS FILE also registers the "Certify K9 Handler" / "Revoke K9
      Certification" ox_target options on nearby player peds (SPEC.md
      §4.3's flow table, §8 step 3 — the previously-missing entry point;
      the events themselves were always reachable via /k9certify /
      /k9decertify). These directly TriggerServerEvent the two events
      documented in full in server/certifications.lua's header
      ('qbx_k9unit:server:certifyHandler' / '...:revokeHandler', both
      (targetServerId: number)) — no new client-side contract of THIS
      FILE's own is introduced, just another entry point into that
      existing, unchanged server contract. Mirrors the "Attach Leash"
      option's structure directly (display-only plausibility gate via
      IsEntityModelK9, server re-validates everything authoritatively).
    - THIS FILE also registers the "Scratch to Alert" ox_target option on
      nearby door-shaped objects (Phase 2, SPEC.md §11.3's file/module plan
      row for this file) and the 'qbx_k9unit:client:playDoorScratch'
      broadcast receiver — see the DOOR INTERACTION block near the header
      above and the implementation near the bottom of this file. Exposes NO
      new resource-global function of its own (ox_target-only entry point,
      same shape as client/search.lua's search options — nothing else in
      this resource needs to call into door interaction directly).
    - THIS FILE also registers a SEPARATE "Nudge Door" ox_target option
      alongside "Scratch to Alert" on the same door-like objects (the
      previously-deferred nudge-open sub-feature, now implemented — see the
      DOOR INTERACTION block below for the full safety reasoning). Unlike
      every other ox_target option in this file, NudgeDoor() has ZERO server
      involvement of any kind: no TriggerServerEvent, no callback, nothing
      server-authoritative at stake — the entire feature is a local
      self-impulse on the K9's own ped, never touching the door entity's
      state in any way. Exposes no new resource-global function either
      (same ox_target-only entry point shape as ScratchAtDoor above it).

    LEASH SUBSYSTEM DESIGN (per requester's confirmation, resolving
    SPEC.md §9 item 3b — see server/main.lua's header for the full
    rationale, repeated here only as it affects THIS file):
    1. Attach requires consent — RequestLeashAttach() only ever sends a
       request; the actual pairing is formed server-side after the OTHER
       player accepts via the ox_lib prompt this file shows them.
    2. While attached, the CONSTRAINED party (always the K9-role side,
       server-assigned — see leashAttached's `isConstrained` flag) runs an
       elastic pull-back on THEIR OWN ped as they approach
       Config.LeashMaxDistance from their partner. This must run on the
       constrained player's own client because a client can only reliably
       control its own ped's position — you cannot dependably force
       another client's ped to a position from here, their own game
       instance keeps simulating and re-networking their own movement.
    3. DetachLeash() must work at ANY time for EITHER role, no
       confirmation/consent step of its own — hard requirement, no trapped
       state.
    4. If the elastic pull-back still can't keep distance under control
       (disconnect, teleport, desync) and a hard cap is exceeded, the
       CONSTRAINED client calls DetachLeash() itself as a safety valve —
       reuse this exact function, don't build a second detach code path.

    ======================================================================
    DOOR INTERACTION — Phase 2, SCRATCH-TO-ALERT + NUDGE-OPEN. SPEC.md
    §11.1 sub-phase 2a/2b, §11.3's file/module plan (this file's row), §11.4
    items 5/6, §11.5's door-interaction acceptance criteria;
    phase2_notes/door_interaction.md, phase2_notes/door_interaction_natives.md,
    and phase2_notes/door_interaction_security_review.md (all read in full
    before this section was written — the security review in particular was
    written pre-implementation against server/main.lua's ALREADY-SHIPPED
    relayDoorScratch handler, so this file is built to that handler's exact,
    fixed contract rather than re-deriving it).

    "Nudge-open" is now implemented — see the "NUDGE-OPEN" comment further
    down, immediately above the door-interaction code itself, for the full
    reasoning, the hard safety constraint it follows (never consults GTA's
    native door-lock/CDoor system, by design), and which of the two
    design-note-flagged implementation paths was actually taken (the
    zero-gating cosmetic-only fallback, since a real "already passable"
    detection method was never confirmed to exist in any of the three
    phase2_notes documents).

    Nudge-open has NO server event of its own — it is 100% client-local
    (ZERO TriggerServerEvent, ZERO callback, nothing server-authoritative
    touched at all), unlike scratch-to-alert below. Do not add one; that
    would be a structural deviation from SPEC.md §11.3/§11.5/§11.6's
    explicit, repeated framing, not a judgment call left open by this file.

    Server events (client->server):
    - 'qbx_k9unit:server:relayDoorScratch' (doorNetId: number)
      [server/main.lua, already implemented — THIS FILE only triggers it].
      Structurally mirrors 'qbx_k9unit:server:relayBark' above, EXCEPT the
      payload names a DIFFERENT entity (the door) than the sender's own ped
      — the server independently resolves/existence-checks/proximity-checks
      doorNetId before ever broadcasting it (closes SPEC.md §9 item 16, per
      server/main.lua's own header comment on that handler). This file's own
      pre-send checks (CanShowK9UI(), DoesEntityExist(entity)) are UX only,
      never the security boundary — the server re-validates everything
      regardless of what this client claims.

    Client events (server->client):
    - 'qbx_k9unit:client:playDoorScratch' (doorNetId: number) [THIS FILE]
      Mirrors client/main.lua's existing playBark handler exactly (resolve
      the network entity, no-op if not streamed in/nonexistent, play a
      sound) — per SPEC.md §11.4 item 6. The resolve step calls
      client/main.lua's global ResolveNetworkEntity(netId)
      (REFACTOR_ROADMAP.md near-term item 2) rather than re-implementing
      it locally.
    ======================================================================
]]

-- Local-only view-mode state for the camera toggle below. Not exposed —
-- ToggleK9Camera() is the only entry point.
local isFirstPersonK9View = false

--- Toggles first/third-person camera at the K9's eye height while playing
--- a K9 character. See client/main.lua's OPEN QUESTION about whether this
--- needs to be gated by CanShowK9UI() at all — per this scaffold's lean
--- (and the top-level task's explicit direction) this does NOT gate on
--- CanShowK9UI() (a QoL toggle, not a granted capability); it DOES gate on
--- the cheap, local, free IsOwnModelK9() check, since "while playing their
--- K9 character" (SPEC.md §6.1 bullet 2) implies it's meaningless for a
--- human-model character, not that it requires job/cert.
--- SPEC.md §6.1 bullet 2, §8 step 5. Bound to a rebindable keymapping
--- (FiveM's own Settings > Key Bindings screen lets a player/server change
--- the default) rather than a radial item — camera toggle isn't in the
--- Phase 1 radial item list (Bark/Sit/Leash/Vehicle only, see
--- client/radial.lua), so it needs its own input path.
--- SetFollowPedCamViewMode drives the game's OWN built-in first/third
--- person camera system, which already derives eye/vantage height from
--- the CURRENT ped model's actual skeleton (including quadruped models)
--- generically — this is why no manual CreateCam/AttachCamToEntity rig is
--- needed to satisfy "camera at the dog's eye height": the native camera
--- modes already do that for any ped model without per-model tuning.
function ToggleK9Camera()
    if not IsOwnModelK9() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.not_k9_model'), type = 'error' })
        return
    end

    isFirstPersonK9View = not isFirstPersonK9View
    SetFollowPedCamViewMode(isFirstPersonK9View and 4 or 1)
    lib.notify({
        title = locale('common.notify_title'),
        description = isFirstPersonK9View and locale('movement.camera_first_person') or locale('movement.camera_third_person'),
        type = 'inform',
    })
end

RegisterCommand('qbx_k9unit:toggleCamera', function()
    ToggleK9Camera()
end, false)

RegisterKeyMapping('qbx_k9unit:toggleCamera', locale('movement.toggle_camera_keybind_label'), 'keyboard', 'L')

-- qa-tester finding: a resource restart while isFirstPersonK9View is true
-- previously left the game's follow-cam stuck in mode 4 (first-person)
-- with no code left running to ever set it back — the same "sticky native
-- state must be reversed on stop" class of bug client/vehicle.lua's own
-- onResourceStop handler already exists to prevent. Only reset when this
-- resource actually changed the mode, so a player's own unrelated camera
-- preference is never clobbered by a restart of this resource.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if isFirstPersonK9View then
        SetFollowPedCamViewMode(1)
        isFirstPersonK9View = false
    end
end)

--- Self-emote "Sit" action triggered from the radial menu. SPEC.md §6.1
--- radial bullet, §8 step 7. Gated with CanShowK9UI() at the top (per
--- radial.lua's own contract, every Phase 1 radial item is a real granted
--- capability check, unlike camera/locomotion above) — return early (and
--- notify) if false, don't just rely on radial.lua having already hidden
--- the item.
--- VERIFIED (native-api-assistant pass, 2026-08-23): "WORLD_DOG_SIT" (the
--- earlier scaffold's guess) is NOT a real scenario — there is no generic
--- dog-sit scenario name at all. Cross-checked against two independently
--- maintained community scenario dumps (DioneB/GTAV-Scenarios and
--- kibook/spooner's scenarios.lua, both decompiled-game-data-derived lists
--- that agree exactly on the dog entries), the real names are PER-BREED:
---   WORLD_DOG_SITTING_SHEPHERD / _ROTTWEILER / _RETRIEVER / _SMALL
--- (plus WORLD_DOG_BARKING_* siblings, not used here). Confidence: HIGH on
--- these exact strings existing (two independent authoritative-for-FiveM-
--- purposes sources agree); MEDIUM on the breed-to-scenario mapping below
--- for a_c_chop/a_c_husky specifically, since neither has an exact-name
--- match and dog scenario anims are shared across the generic quadruped
--- skeleton rather than being model-locked — untested in-engine this
--- session, so if a mapped breed looks visibly off, that's the first
--- place to revisit. TaskStartScenarioInPlace on a PLAYER-controlled ped
--- (vs. an AI ped) is expected/normal here: same native, it plays the pose
--- and exits automatically the moment the player provides movement input,
--- which is the desired "self-emote until you move" behavior for this
--- radial item, not a bug — no anim-dict/TaskPlayAnim fallback is needed
--- since a real scripted scenario exists for every configured breed.
--- Precomputed model-hash -> scenario lookup, built once at file load.
--- Mirrors the precomputed-hash-table convention already used elsewhere
--- in this codebase (client/main.lua's K9ModelHashes, which also backs
--- IsEntityModelK9 per REFACTOR_ROADMAP.md item 3) rather than calling
--- GetHashKey per lookup.
local K9_SIT_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists
    a_c_husky = 'WORLD_DOG_SITTING_RETRIEVER', -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit
}) do
    K9_SIT_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_SIT_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD' -- fallback if playing an unmapped/future Config.Peds model

function K9Sit()
    if not CanShowK9UI() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
        return
    end

    local ped = PlayerPedId()
    local scenarioName = K9_SIT_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_SIT_DEFAULT_SCENARIO

    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
end

--- Local-only UI/role bookkeeping for the CURRENT leash pairing, if any.
--- The pairing's existence is server-authoritative (server/main.lua's
--- LeashPairs); this is just this client's cached view of it, refreshed
--- by the leashAttached/leashDetached handlers below. Not exposed
--- directly — always go through IsLeashed()/DetachLeash().
--- @type { partnerServerId: number, isConstrained: boolean }|nil
local leashState = nil

--- Guards the hard-cap safety-valve branch below from firing more than
--- once per attach: the pull-back thread ticks every LEASH_TICK_MS, so
--- under latency the server's detach round-trip can take longer than one
--- tick, and without this flag the branch would re-fire and duplicate the
--- notification/DetachLeash() call every tick until leashState actually
--- clears. Reset in the leashAttached/leashDetached handlers below.
local detachRequestedForSafety = false

--- @return boolean
function IsLeashed()
    return leashState ~= nil
end

--- Sends a leash request to `targetPlayerServerId`. Does NOT attach
--- anything by itself — see leashAttached event handler below for where
--- the pairing actually activates, after the target accepts.
--- @param targetPlayerServerId number
function RequestLeashAttach(targetPlayerServerId)
    -- Re-check, don't trust that the caller (ox_target predicate or
    -- radial item) already verified this — cheap client-side sanity check
    -- before bothering the server (which re-validates authoritatively
    -- regardless, see server/main.lua's CheckLeashEligibility).
    if not CanShowK9UI() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
        return
    end

    if IsLeashed() then
        lib.notify({ title = locale('common.notify_title'), description = locale('movement.already_leashed'), type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestLeashAttach', targetPlayerServerId)
    -- The target's client is the one that shows the actual accept/decline
    -- prompt (see leashAttachRequest below), not this one.
    lib.notify({ title = locale('common.notify_title'), description = locale('movement.leash_request_sent'), type = 'inform' })
end

--- Detaches the current leash, if any, with ZERO consent required from
--- the other party. No-op (locally and server-side) if not currently
--- leashed. This is the SAME function the elastic-restriction safety
--- valve calls automatically — see the CreateThread below.
function DetachLeash()
    if not IsLeashed() then return end

    -- Let the server-authoritative leashDetached broadcast (handled
    -- below) be what actually clears leashState/stops the thread, rather
    -- than clearing local state immediately here, so this client's view
    -- stays in sync with whatever the server decides.
    TriggerServerEvent('qbx_k9unit:server:detachLeash')
end

--- Step 1 of the consent handshake, received on the TARGET's client.
--- @param fromServerId number
RegisterNetEvent('qbx_k9unit:client:leashAttachRequest', function(fromServerId)
    -- SOURCE-ORIGIN GUARD (coder-security pass, applied uniformly across
    -- this file's `qbx_k9unit:client:*` handlers here — see
    -- client/combat.lua's own "SOURCE-ORIGIN GUARD" header block for the
    -- full sourced writeup/confidence grading, not re-derived per file).
    -- Without this, a locally-forged `fromServerId` would pop a fake
    -- accept/decline prompt for a leash request that was never actually
    -- sent — a real-server response is still required to do anything, but
    -- this closes the "arbitrary event with zero server contact" gap this
    -- resource's own convention now expects for every client:* handler.
    -- Confidence: MEDIUM-HIGH, not certain — see client/combat.lua's
    -- header for the honest caveat (official documented pattern, not
    -- empirically verified in-engine as part of this change).
    if source ~= 65535 then return end
    local fromPlayer = GetPlayerFromServerId(fromServerId)
    local fromName = (fromPlayer ~= -1 and GetPlayerName(fromPlayer)) or locale('movement.officer_fallback_name', fromServerId)

    -- If the local player leashes/unleashes/disconnects mid-prompt, or
    -- either side is no longer eligible by the time they answer, the
    -- server re-validates everything at accept time regardless (see
    -- server/main.lua's CheckLeashEligibility TOCTOU note) — this client
    -- just needs to send the response and handle a later rejection
    -- gracefully, not assume acceptance always succeeds.
    local response = lib.alertDialog({
        header = locale('movement.leash_request_header'),
        content = locale('movement.leash_request_content', fromName),
        centered = true,
        cancel = true,
        labels = { confirm = locale('movement.accept_label'), cancel = locale('movement.decline_label') },
    })

    TriggerServerEvent('qbx_k9unit:server:respondLeashAttach', fromServerId, response == 'confirm')
end)

--- Step 2 of the consent handshake: the server has confirmed the pairing
--- and told THIS client its role. Sent individually to each party with
--- their own `isConstrained` value — do not assume both clients receive
--- the same boolean.
--- @param partnerServerId number
--- @param isConstrained boolean  -- true only on the K9-role party's client
RegisterNetEvent('qbx_k9unit:client:leashAttached', function(partnerServerId, isConstrained)
    -- SOURCE-ORIGIN GUARD — see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. Forging this
    -- locally would set this client's OWN leashState directly (no
    -- server-side pairing exists to back it) — low real-world payoff either
    -- way (the elastic-restriction thread only constrains THIS client, and
    -- a hostile client could already ignore that thread's DisableControlAction-
    -- equivalent restrictions by other means), but applied for the same
    -- resource-wide consistency reasoning as every other handler here.
    if source ~= 65535 then return end
    leashState = { partnerServerId = partnerServerId, isConstrained = isConstrained }
    detachRequestedForSafety = false
    lib.notify({
        title = locale('common.notify_title'),
        description = isConstrained and locale('movement.leash_now_leashed') or locale('movement.leash_now_anchoring'),
        type = 'success',
    })
    -- The elastic-restriction thread below is a perpetual loop that reads
    -- `leashState` fresh every iteration, so simply setting it here is
    -- sufficient to "wake" the tighter-interval pulling behavior on the
    -- constrained client — no separate thread-start call needed.
end)

--- The pairing has ended — manual detach by either side, the constrained
--- client's own safety valve, or a partner disconnect (server/main.lua's
--- playerDropped cleanup). Sent to whichever client(s) are still around.
--- @param reason string  -- e.g. 'detached' | 'partner_disconnected'
RegisterNetEvent('qbx_k9unit:client:leashDetached', function(reason)
    -- SOURCE-ORIGIN GUARD — see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. This one has a real
    -- self-benefit shape, not merely cosmetic: a CONSTRAINED party forging
    -- this locally clears `leashState` on THIS client only, which silences
    -- the elastic-restriction thread's pull-back enforcement below —
    -- functionally the same as escaping the leash — while server/main.lua's
    -- own leash bookkeeping (and the other party's client) still believes
    -- the pairing is active, since no real `qbx_k9unit:server:detachLeash`
    -- was ever sent.
    if source ~= 65535 then return end
    leashState = nil
    detachRequestedForSafety = false

    local description = locale('movement.leash_detached')
    if reason == 'partner_disconnected' then
        description = locale('movement.leash_detached_partner_disconnected')
    end
    lib.notify({ title = locale('common.notify_title'), description = description, type = 'inform' })
    -- The elastic-restriction thread below naturally stops doing anything
    -- once IsLeashed() is false — nothing else to tear down here.
end)

-- Elastic movement-restriction thread — the part of the leash mechanic
-- that must be an actual constraint, not a passive monitor. Only does
-- anything while IsLeashed() AND leashState.isConstrained is true (the
-- anchor/officer side does nothing here beyond having already received
-- its own notify above). Re-resolves the partner ped from
-- leashState.partnerServerId every tick rather than caching the handle,
-- since a cached ped handle can go stale across a respawn/reconnect.
local LEASH_TICK_MS = 250
local LEASH_IDLE_TICK_MS = 1000
local LEASH_PULL_ZONE_FACTOR = 0.75 -- start elastic pull-back at 75% of Config.LeashMaxDistance
local LEASH_HARD_CAP_FACTOR = 1.5   -- safety-valve auto-detach threshold, relative to Config.LeashMaxDistance
local LEASH_PULL_EASE = 0.20        -- fraction of the excess distance corrected per tick (feel/tuning knob)

CreateThread(function()
    while true do
        local sleepMs = LEASH_IDLE_TICK_MS

        if leashState and leashState.isConstrained then
            sleepMs = LEASH_TICK_MS

            local partnerPlayer = GetPlayerFromServerId(leashState.partnerServerId)
            local partnerPed = partnerPlayer ~= -1 and GetPlayerPed(partnerPlayer) or 0

            if partnerPed ~= 0 and DoesEntityExist(partnerPed) then
                local myPed = PlayerPedId()
                local myCoords = GetEntityCoords(myPed)
                local partnerCoords = GetEntityCoords(partnerPed)
                local dist = #(myCoords - partnerCoords)

                local softLimit = Config.LeashMaxDistance
                local hardCap = softLimit * LEASH_HARD_CAP_FACTOR
                local pullZoneStart = softLimit * LEASH_PULL_ZONE_FACTOR

                if dist >= hardCap then
                    -- Safety-valve fallback (point 4 in this file's
                    -- header): the elastic pull-back below couldn't keep
                    -- distance under control (disconnect/teleport/desync).
                    -- Reuse the exact same detach path, don't build a
                    -- second one. Guarded so this only fires once per
                    -- attach — the server round-trip can outlast one tick
                    -- under latency, and leashState doesn't clear until
                    -- the server confirms via leashDetached.
                    if not detachRequestedForSafety then
                        detachRequestedForSafety = true
                        lib.notify({ title = locale('common.notify_title'), description = locale('movement.leash_snapped_too_far'), type = 'error' })
                        DetachLeash()
                    end
                elseif dist > pullZoneStart and not IsPedInAnyVehicle(myPed, false) and not (IsInK9Vehicle and IsInK9Vehicle()) then
                    -- Proportional soft pull-back, not a hard snap at the
                    -- exact threshold: the closer to hardCap, the stronger
                    -- the correction applied this tick. Skipped while in a
                    -- vehicle (IsPedInAnyVehicle) or "tucked" into a K9
                    -- cruiser via client/vehicle.lua's attach-based load-in
                    -- (IsInK9Vehicle) to avoid fighting the AttachEntityToEntity
                    -- that's holding the ped in place — a defensive edge
                    -- case, not spelled out in SPEC.md. The IsInK9Vehicle
                    -- existence check guards load order between these two
                    -- client scripts within the resource.
                    local excess = dist - pullZoneStart
                    local zoneSize = math.max(hardCap - pullZoneStart, 0.1)
                    local pullFactor = math.min(excess / zoneSize, 1.0)
                    local pullAmount = excess * pullFactor * LEASH_PULL_EASE
                    local dir = (partnerCoords - myCoords) / dist
                    local newCoords = myCoords + dir * pullAmount
                    SetEntityCoords(myPed, newCoords.x, newCoords.y, newCoords.z, false, false, false, true)
                end
            end
            -- If the partner ped isn't resolvable this tick (streamed
            -- out/not yet loaded), just skip pulling for now — a real
            -- disconnect is independently handled by server/main.lua's
            -- playerDropped cleanup broadcasting leashDetached.
        end

        Wait(sleepMs)
    end
end)

-- Bug fix (this pass): a resource restart (not a disconnect -- the
-- player stays connected, this resource just stops and restarts on
-- their client) while IsLeashed() is true used to leave a real orphaned
-- pairing: the thread above (this resource's ONLY enforcement of the
-- elastic pull-back / hard-cap safety valve) dies along with the rest of
-- this resource on stop, but leashState lives on server-side
-- (server/main.lua's LeashPairs) with nothing left client-side to ever
-- correct drift or auto-detach on a runaway distance -- the constrained
-- party could end up leashed-in-name-only, with zero of the restriction
-- this feature exists to provide, until either party manually detaches.
-- Same "don't leave sticky cross-resource state behind on stop" class of
-- bug this file's isFirstPersonK9View/lastAppliedMoveRate onResourceStop
-- handlers above already guard against, and the exact convention
-- client/vehicle.lua's own onResourceStop (ReleasePedFromVehicleState)
-- follows for its own stranding case. DetachLeash() is a no-op if not
-- leashed, and reuses the SAME server round-trip DetachLeash() always
-- uses -- no second detach path introduced. Only meaningful on the
-- CONSTRAINED party's client (the anchor/officer side has no local
-- enforcement to lose either way), but calling it unconditionally on
-- both is harmless and keeps this one code path in charge of every
-- detach, per this file's own header point 4.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if IsLeashed() then
        DetachLeash()
    end
end)

-- IsEntityModelK9(entity) used to be defined here as a small local copy
-- (with its own private k9ModelHashesForTargeting hash set) of the same
-- generic Config.Peds-driven display-only check, since client/main.lua only
-- exposed IsOwnModelK9() (not its private model-hash table) at the time
-- this file was written. Promoted to a client/main.lua resource-global per
-- REFACTOR_ROADMAP.md item 3 — this file's own signature was the one
-- promoted verbatim (see client/main.lua's own doc comment on
-- IsEntityModelK9 for the full "5 independent copies" finding this
-- consolidation closes). Every call site below now calls that shared
-- global instead.

-- config-validator finding: this option's `distance` used to be a bare
-- 2.5 with no relationship to any Config value at all, even though the
-- REAL server-side range check for initiating a leash attach is
-- Config.LeashMaxDistance (server/main.lua's CheckLeashEligibility, which
-- reuses that same raw value directly per config.lua's own comment on it
-- — see the "too far to request" check there). Deriving from it here means
-- an installer who edits Config.LeashMaxDistance now sees this option's
-- visible range move with it, instead of it silently staying frozen at an
-- unrelated magic number.
--
-- Kept at HALF Config.LeashMaxDistance rather than the full value: this is
-- a DISPLAY-ONLY UI gate (the server re-validates authoritatively
-- regardless — see below), so it's deliberately tighter than the server
-- bound on purpose, not because it needs to match exactly. An ox_target
-- option that only appears right at the exact edge of what the server
-- would accept is a bad experience — a half-step of player movement
-- between opening the ox_target menu and the server actually processing
-- the resulting 'qbx_k9unit:server:requestLeashAttach' event can flip a
-- borderline case from accepted to rejected. Halving the server bound
-- gives comfortable margin against that without being so tight the option
-- feels unreasonably hard to find.
--
-- NOTE for reviewers: with the current default (Config.LeashMaxDistance =
-- 8.0), this evaluates to 4.0m, WIDER than the previous hardcoded 2.5m —
-- this is an intentional, documented widening (not an incidental
-- side-effect of this change), and remains well inside
-- Config.LeashMaxDistance, so the server's own authoritative check is
-- still what actually gates the action either way.
local LEASH_TARGET_DISTANCE_FACTOR = 0.5

-- Register the "Attach Leash" ox_target option on nearby player peds
-- (SPEC.md §6.1 leash bullet's "either the K9 or a nearby officer
-- initiates 'Attach Leash' (ox_target) on the other"). This is a DISPLAY
-- optimization only — the server independently re-validates everything
-- for real in CheckLeashEligibility (server/main.lua), so this predicate
-- doesn't need to be perfect.
exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:attachLeash',
        icon = 'fas fa-link',
        label = locale('movement.attach_leash_target_label'),
        distance = LEASH_TARGET_DISTANCE_FACTOR * Config.LeashMaxDistance,
        canInteract = function(entity, distance, coords, name)
            if not Config.Features.LeashMechanics then return false end
            if IsLeashed() then return false end
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't target self

            -- At least one side should plausibly be a K9 (either us, or
            -- the target's live model) — cheap client-side plausibility
            -- only, per this file's header note not to over-invest here.
            return IsOwnModelK9() or IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            RequestLeashAttach(GetPlayerServerId(targetPlayer))
        end,
    },
})

-- Register the "Certify K9 Handler" / "Revoke K9 Certification" ox_target
-- options on nearby player peds (SPEC.md §4.3's flow table, §8 step 3 —
-- this is the gap integration-verifier flagged: the server-side grant/
-- revoke system in server/certifications.lua was fully implemented and
-- correct, but was only reachable via /k9certify [id] / /k9decertify [id],
-- never through any in-world interaction). Mirrors the "Attach Leash"
-- option's structure immediately above: DISPLAY-ONLY plausibility gates
-- here, the server independently re-validates granter eligibility
-- (IsEligibleCertifier), proximity (Config.CertifyProximityMeters), and
-- (grant-only) the target's live model in GrantCertification /
-- RevokeCertification — see server/certifications.lua's header for the
-- full contract and its quoted SPEC.md §4.3 security note. Deliberately
-- does NOT attempt to check "is the local player an eligible certifier"
-- client-side: IsEligibleCertifier is a server-only check with no cheap
-- client-side equivalent (it reads qbx_core job/grade data this client
-- doesn't have), and a new callback purely to gate visibility isn't worth
-- adding here — showing the option broadly (to any player near a
-- K9-modeled ped) and letting the server accept-or-reject-with-notification
-- is the exact same tradeoff the leash option above already makes.
--
-- No Config.Features flag gates this pair, unlike every other ox_target
-- option in this resource (LeashMechanics above, VehicleEntryExit in
-- client/vehicle.lua, etc.): certify/revoke IS the access-control system
-- itself (SPEC.md hard requirement 2), not a togglable *feature area* sitting
-- behind that system the way Phase 1+'s other leaf features are framed in
-- §3's acceptance criteria ("every leaf feature... has a corresponding
-- Config.Features.X"). config.lua has no Certifications/CertifyHandler
-- entry in Config.Features, and the existing /k9certify, /k9decertify,
-- /k9decertifyoffline commands are likewise registered unconditionally —
-- this follows that same, already-established convention rather than
-- inventing a new toggle for it.
--
-- config-validator finding: both options below used to have a bare 2.5
-- `distance` with no relationship to any Config value, even though the
-- REAL server-side proximity check for both grant and revoke is
-- Config.CertifyProximityMeters (server/certifications.lua's
-- GrantCertification and RevokeCertification, both of which reject past
-- that value — see the header comment above and server/certifications.lua
-- itself for the exact call sites). Deriving from it here means an
-- installer who edits Config.CertifyProximityMeters now sees these
-- options' visible range move with it, instead of it silently staying
-- frozen at an unrelated magic number — exactly the drift the finding
-- flagged.
--
-- Kept at HALF Config.CertifyProximityMeters, same "don't vanish right at
-- the server's exact edge" reasoning as LEASH_TARGET_DISTANCE_FACTOR
-- above: this is a DISPLAY-ONLY UI gate (the server re-validates
-- authoritatively regardless), so being deliberately tighter than the
-- server bound is intentional, giving margin against a player drifting a
-- few centimetres between opening ox_target and the server processing the
-- resulting certifyHandler/revokeHandler event.
--
-- NOTE for reviewers: with the current default (Config.CertifyProximityMeters
-- = 5.0), this evaluates to 2.5m — the SAME value as the previous
-- hardcoded constant. That match is coincidental (this file's original
-- 2.5 was never actually derived from Config.CertifyProximityMeters), not
-- load-bearing: this now tracks any future change to that config value
-- instead of staying frozen.
local CERTIFY_TARGET_DISTANCE_FACTOR = 0.5

exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:certifyHandler',
        icon = 'fas fa-id-badge',
        label = locale('movement.certify_handler_target_label'),
        distance = CERTIFY_TARGET_DISTANCE_FACTOR * Config.CertifyProximityMeters,
        canInteract = function(entity, distance, coords, name)
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- self-cert stays command-only (/k9certify [own id]), matches the leash option's self-exclusion above

            -- SPEC.md §4.2 condition 5: grant requires the TARGET's live
            -- ped model to be a configured K9 model. Cheap client-side
            -- plausibility check only — the server independently
            -- re-verifies via GetEntityModel(GetPlayerPed(targetServerId))
            -- regardless, see GrantCertification.
            return IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            TriggerServerEvent('qbx_k9unit:server:certifyHandler', GetPlayerServerId(targetPlayer))
        end,
    },
    {
        name = 'qbx_k9unit:revokeHandler',
        icon = 'fas fa-id-badge',
        label = locale('movement.revoke_certification_target_label'),
        distance = CERTIFY_TARGET_DISTANCE_FACTOR * Config.CertifyProximityMeters,
        canInteract = function(entity, distance, coords, name)
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- self-decert stays command-only, matches certify above

            -- SPEC.md §4.2.5: the model check applies to GRANT only, not
            -- revoke (revoking must remain possible even if the target has
            -- already left K9 form) — but this predicate still reuses
            -- IsEntityModelK9 as the display-only plausibility gate rather
            -- than showing this option on every nearby player regardless
            -- of appearance, per this block's header note above (no new
            -- eligibility-check callback added this pass). A handler who
            -- has already left K9 form and needs their cert pulled remains
            -- reachable via /k9decertify [id] (or /k9decertifyoffline if
            -- they've since disconnected), neither of which has any model
            -- restriction at all — this ox_target option is a convenience
            -- entry point, not the only way to revoke.
            return IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            TriggerServerEvent('qbx_k9unit:server:revokeHandler', GetPlayerServerId(targetPlayer))
        end,
    },
})

-- ======================================================================
-- MOVE-RATE COMPOSER (PHASE4_SPEC.md §13.0 Decision 2) -- REAL BUG FIX,
-- qa-tester finding: client/wellbeing.lua (Phase 4) writes
-- K9MoveRateModifiers.fatigue/.injury/.mood and calls RecomputeK9MoveRate()
-- unconditionally (no existence guard, unlike client/progression.lua's own
-- defensive `if K9MoveRateModifiers then`/`type(RecomputeK9MoveRate) ==
-- 'function'` checks) on the assumption that THIS FILE defines both --
-- which, until this pass, it did not: neither symbol existed anywhere in
-- this codebase (confirmed by grep before this pass). The moment any
-- wellbeing feature flag flips true, client/wellbeing.lua's own
-- ApplyMoveRateModifiers() would hard-error on its very first write
-- ("attempt to index a nil value") -- latent only because every wellbeing
-- flag defaults to false in config.lua. This section is the real fix:
-- implementing the composer for real, not bolting a guard onto
-- wellbeing.lua that would have silently swallowed every wellbeing
-- speed-penalty write instead (a worse failure -- it would look like it
-- works while doing nothing).
--
-- WHY THIS LIVES HERE: this file already owns every other "own body,
-- native locomotion" concern (camera mode, AgilityBasicJump's suppression
-- below, the leash elastic pull-back above) -- PHASE4_SPEC.md §13.3's
-- file/module plan names this file as the composer's home for exactly
-- that reason, not a new module.
--
-- WHY MULTIPLICATIVE COMPOSITION: each contributing system (Fatigue,
-- Injury, Mood, XPProgression's tier bonus, and the reserved slot for
-- Phase 3's PropDragging) expresses its own effect as an independent
-- fractional scale of NORMAL speed (e.g. "0.85x while fatigued", "1.15x at
-- Elite tier") -- these are proportions of the base rate, not independent
-- absolute deltas meant to be summed. Proportional penalties should
-- compound proportionally: 0.85 * 0.85 (a fatigued AND injured K9 running
-- two independent 15% penalties) is the mathematically correct combined
-- effect; an additive model (1 - (0.15 + 0.15)) would need a different
-- unit entirely and doesn't generalize past two simultaneous penalties
-- without going negative. Multiplying every active modifier together is
-- the standard way to combine several independent fractional-scale
-- effects, and it has the convenient property that any modifier left at
-- its neutral default of 1.0 (an inactive/disabled system) is a true no-op
-- in the product -- nothing below has to special-case "this system isn't
-- contributing right now."
--
-- CLAMP RANGE [0.1, 2.0], AND WHY: mirrors this codebase's own established
-- defensive-clamping precedent for exactly this failure class -- the
-- `math.max(_, 0.1)` floor this file's own leash pull-back thread already
-- uses above (zoneSize guard) and client/tracking.lua uses twice
-- (sampleIntervalMeters/markerSpacing guards) against a
-- misconfigured-to-zero-or-negative value. 0.1 as the floor: the lowest
-- realistic legitimate combination shipped today (Injury 0.7 * Fatigue
-- 0.85 * Mood 0.9 ~= 0.535, config.lua's Config.Wellbeing) sits
-- comfortably above it, so this floor is a defensive backstop against a
-- MISCONFIGURED multiplier (a config typo, or a future PropDragging value
-- near 0) freezing the K9 solid, not a value any correct combination of
-- today's shipped systems is expected to reach. 2.0 as the ceiling:
-- today's highest shipped multiplier (XPProgression's Elite tier, 1.15,
-- config.lua's Config.XPTiers) is well under it, so 2.0 exists purely to
-- stop a misconfigured or unreviewed-future-system multiplier from
-- launching the K9 to an unreasonable speed, while leaving generous
-- headroom for a legitimate future stacked-bonus design without needing
-- this clamp revisited.
--
-- INTERACTION CHECK WITH THIS FILE'S OTHER MOVEMENT LOGIC (done before
-- writing this, per this task's explicit instruction):
--   - AgilityBasicJump's suppression thread below calls
--     DisableControlAction(0, INPUT_JUMP/INPUT_DUCK, true) every frame --
--     a different native entirely (blocks an input action, doesn't touch
--     move rate) -- no interaction with SetPedMoveRateOverride below.
--   - The leash elastic pull-back thread above corrects position directly
--     via SetEntityCoords, never via a move-rate override -- again no
--     shared native, no interaction. A leashed K9's move RATE (as opposed
--     to how far it's allowed to drift from its partner) is unaffected by
--     leash state and is expected to keep responding normally to whatever
--     this composer computes.
--   - client/agility.lua's AgilityAdvanced vault (extracted from this file,
--     this pass — see this file's own "EXTRACTED" header note) drives an
--     instantaneous velocity impulse via SetEntityVelocity, a one-shot
--     native distinct from the persistent move-rate override this
--     composer maintains -- no interaction (a vault's brief arc is an
--     externally-applied velocity kick, not ground-locomotion animation
--     speed, which is the documented scope of SetPedMoveRateOverride).
--   - This resource's ONLY call site for SetPedMoveRateOverride, anywhere,
--     is RecomputeK9MoveRate() below (confirmed by grep before writing
--     this) -- exactly PHASE4_SPEC.md §13.0 Decision 2's "one and only
--     call" requirement.
--
-- CONFIDENCE NOTE ON SetPedMoveRateOverride ITSELF, stated honestly per
-- this codebase's own convention (see client/hud.lua's "STAMINA NATIVE --
-- CONFIDENCE NOTE" for the standard this follows): the native's
-- NAME/existence as a real, callable FiveM ped native is HIGH confidence
-- (linked from phase2_notes/phase3_combat_natives.md's own
-- natives-to-verify list, and independently named by both
-- PHASE3_SPEC.md §12.5.4 and PHASE4_SPEC.md §13.0 as the intended
-- mechanism for exactly this class of effect -- multiple independent
-- planning passes converge on the same native). Its PRECISE runtime
-- semantics -- specifically (a) whether a set value persists indefinitely
-- until explicitly changed vs. decaying/resetting on its own, and (b)
-- whether it needs to be re-asserted every tick to keep affecting a live
-- player ped, the way DisableControlAction's own contract explicitly
-- requires -- were NOT independently re-verified against
-- raw.githubusercontent.com/citizenfx/natives or a live client this
-- session. PHASE3_SPEC.md §12.5.4 already flags an expectation that
-- PropDragging will need to "re-assert every tick" for this same native.
-- This composer is written to be SAFE either way regardless of which is
-- true: every real caller (client/wellbeing.lua on each pushed snapshot,
-- client/progression.lua on each tier change, and this file's own
-- onResourceStop reset below) re-invokes RecomputeK9MoveRate() on its own
-- change events rather than assuming one set-and-forget call is
-- sufficient, so if the native DOES require periodic re-assertion, the
-- overall system degrades to "correct within one state-change event," not
-- "silently wrong forever." A native-api-assistant pass to independently
-- confirm exact persistence semantics is recommended before this ships to
-- a live server, same standard this file already applies to its own
-- door-interaction natives (and client/agility.lua applies to its own
-- AgilityAdvanced natives).
-- ======================================================================

--- Named multiplier contributions toward the K9's own single effective
--- move-rate override (PHASE4_SPEC.md §13.0 Decision 2). Every contributing
--- system sets its OWN named key here and then calls RecomputeK9MoveRate()
--- -- nothing should ever call SetPedMoveRateOverride directly except
--- RecomputeK9MoveRate() itself, below. An absent/nil key is treated
--- identically to 1.0 (no effect) by the compose loop below, so a
--- contributing system whose owning Config.Features flag is disabled
--- simply never touches its key and never affects the product.
---
--- SCOPE, CONFIRMED (re-checked this pass, still true): RecomputeK9MoveRate()
--- below is HARD-GATED on IsOwnModelK9() -- it resets to neutral and returns
--- early for any ped that is not currently a recognized K9 model (see that
--- function's own `if not IsOwnModelK9() then ... return end` branch). This
--- is BY DESIGN, not a bug to fix here, for two reasons taken together: (1)
--- RecomputeK9MoveRate() takes no ped argument at all -- it only ever reads
--- PlayerPedId(), the CALLING CLIENT's own currently-controlled ped, never
--- an arbitrary target entity; (2) every modifier key in this table is
--- itself only ever written by a caller when THAT SAME client is playing a
--- K9 character (client/wellbeing.lua and client/progression.lua both scope
--- their writes to a K9 model first) -- there is no modifier here that
--- would ever mean anything on a human ped in the first place. A caller
--- that genuinely needs to set a DIFFERENT (non-K9, or not-necessarily-K9)
--- ped's move rate cannot route through this composer at all -- it must
--- call SetPedMoveRateOverride directly on that ped instead. This already
--- happened once: client/combat.lua's PropDragging runs its speed-limit
--- handler on the dragged TARGET's own client (each client only reliably
--- controls its own ped, same reasoning this file's leash pull-back thread
--- above documents), and the overwhelmingly common target is a human
--- suspect, not another K9 -- see that file's own "MOVE-RATE COMPOSER
--- SCOPE" header comment for the full resolution it shipped (route through
--- this composer only when IsOwnModelK9() is true for the applying client,
--- call SetPedMoveRateOverride directly otherwise). Restated here, at the
--- source, so a FUTURE caller doesn't have to independently re-derive that
--- from combat.lua's comment the way this one did: don't widen this gate to
--- accept an arbitrary ped, and don't remove it -- it exists because every
--- modifier this table can ever hold is meaningless off a K9 model.
--- @type table<string, number>
K9MoveRateModifiers = {
    fatigue = 1.0,  -- client/wellbeing.lua, Config.Features.FatigueSystem
    injury = 1.0,   -- client/wellbeing.lua, Config.Features.InjuryLimping
    mood = 1.0,     -- client/wellbeing.lua, Config.Features.MoodSystem
    xpTier = 1.0,   -- client/progression.lua, Config.Features.XPProgression
    dragging = 1.0, -- RESERVED for Phase 3's PropDragging (client/combat.lua, PHASE3_SPEC.md §12.5.4) -- not yet a real contributor; present so that file's eventual composer write has a ready slot without needing to edit this table.
}

local MOVE_RATE_MIN = 0.1 -- see this section's header comment for the full clamp-range justification
local MOVE_RATE_MAX = 2.0

-- Tracks the last value THIS resource actually applied via
-- SetPedMoveRateOverride, so onResourceStop below only resets the native
-- when this resource actually changed it away from neutral -- same "don't
-- clobber state we never touched" discipline as this file's existing
-- isFirstPersonK9View onResourceStop handler above.
local lastAppliedMoveRate = 1.0

--- The single, only call site for SetPedMoveRateOverride in this resource
--- (PHASE4_SPEC.md §13.0 Decision 2). Composes every entry currently in
--- K9MoveRateModifiers multiplicatively (see this section's header comment
--- for why multiplicative, not additive), clamps the result defensively,
--- and applies it once. Safe to call at any time, from any file, whether
--- or not the local player currently has a valid/K9 ped -- every early
--- return below is a deliberate no-op, never an error.
function RecomputeK9MoveRate()
    local ped = PlayerPedId()
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return -- no valid ped to apply anything to yet (e.g. between spawns) -- nothing to do, not an error
    end

    if not IsOwnModelK9() then
        -- Not currently playing a K9 character -- none of the wellbeing/XP/
        -- dragging modifiers above are meaningful for a human character's
        -- move speed. Reset to neutral rather than silently no-op-ing:
        -- FiveM's SetPlayerModel keeps the SAME ped index across a model
        -- swap, so a stale non-1.0 override applied while this ped was
        -- last a K9 could otherwise persist onto the human character after
        -- a K9-to-human model change, permanently speeding up or slowing
        -- down a player who is no longer even playing K9 content.
        if lastAppliedMoveRate ~= 1.0 then
            SetPedMoveRateOverride(ped, 1.0)
            lastAppliedMoveRate = 1.0
        end
        return
    end

    local effective = 1.0
    for _, modifier in pairs(K9MoveRateModifiers) do
        if type(modifier) == 'number' then
            effective = effective * modifier
        end
        -- non-number entries are ignored defensively rather than erroring
        -- -- should never happen with every documented caller, but a
        -- composer this many independent systems write into is exactly the
        -- kind of shared state worth being defensive about.
    end

    effective = math.max(MOVE_RATE_MIN, math.min(MOVE_RATE_MAX, effective))

    SetPedMoveRateOverride(ped, effective)
    lastAppliedMoveRate = effective
end

-- qa-tester-class hygiene, same reasoning as isFirstPersonK9View's own
-- onResourceStop handler above: a resource restart while a non-neutral
-- move-rate override is active would otherwise leave the K9 permanently
-- sped up/slowed down with no code left running to ever reverse it. Only
-- resets when THIS resource actually applied a non-1.0 value, so an
-- unrelated resource's own independent SetPedMoveRateOverride call (the
-- disclosed, pre-existing FiveM limitation PHASE4_SPEC.md §13.0 Decision 2
-- itself flags -- a single global-per-entity native this resource cannot
-- fully own) is never clobbered by this handler.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if lastAppliedMoveRate ~= 1.0 then
        local ped = PlayerPedId()
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            SetPedMoveRateOverride(ped, 1.0)
        end
        lastAppliedMoveRate = 1.0
    end
end)

-- AgilityBasicJump (Config.Features.AgilityBasicJump): SPEC.md §6.1 bullet
-- 3 bundles jump AND crouch together ("The K9 player can run, jump, and
-- crouch using the native quadruped locomotion..."), matching this flag's
-- own inline comment ("native jump/crouch only, no fence-vault logic
-- yet") — so both controls are gated together here, not just jump.
--
-- When the flag is true (the Phase 1 default), native jump/crouch just
-- works via the ped model's own locomotion — no code needed, so no thread
-- is started at all in that case (avoiding an unnecessary always-on loop
-- for the common/default case).
--
-- When the flag is false, jump/crouch must be actively suppressed for a
-- K9-modeled player, otherwise the flag is a no-op (the gap
-- correctness-overseer flagged: setting this to false previously changed
-- nothing, since jump/crouch are inherent to any ped's native locomotion
-- and nothing gated them). DisableControlAction(0, <control>, true) every
-- frame is the standard FiveM pattern for suppressing a specific native
-- control action.
--
-- Control indices (HIGH confidence, standard/well-established GTA V
-- control mapping used throughout the FiveM ecosystem):
--   22 = INPUT_JUMP
--   36 = INPUT_DUCK (crouch)
if not Config.Features.AgilityBasicJump then
    local INPUT_JUMP = 22
    local INPUT_DUCK = 36

    CreateThread(function()
        while true do
            if IsOwnModelK9() then
                DisableControlAction(0, INPUT_JUMP, true)
                DisableControlAction(0, INPUT_DUCK, true)
                Wait(0) -- must disable every frame while active, per DisableControlAction's own contract
            else
                Wait(1000) -- cheap idle poll while not currently a K9-modeled ped
            end
        end
    end)
end

-- ======================================================================
-- DOOR INTERACTION — Phase 2, SCRATCH-TO-ALERT + NUDGE-OPEN
-- (Config.Features.DoorInteraction). See this file's header DOOR
-- INTERACTION block for the full event contract and source-document list.
-- Scratch-to-alert is built directly against server/main.lua's
-- ALREADY-SHIPPED 'qbx_k9unit:server:relayDoorScratch' handler (search that
-- file for "relayDoorScratch" for the exact, currently-live contract this
-- code targets) rather than re-deriving the server side from the design
-- notes alone — the design notes and the shipped handler agree, but the
-- handler is the actual source of truth.
--
-- NUDGE-OPEN — DESIGN PATH TAKEN (read this before touching NudgeDoor()):
--
-- The hard, non-negotiable constraint (SPEC.md §11.5/§11.6,
-- phase2_notes/door_interaction_natives.md §0.5/§4,
-- phase2_notes/door_interaction_security_review.md Finding 3): nudge-open
-- must NEVER consult GTA's native door-lock/CDoor system
-- (DoorSystemGetDoorState / IsDoorClosed / GetStateOfClosestDoorOfType /
-- etc.) as a safety check. An unregistered door — the common case, since
-- most real FiveM door-lock resources (ox_doorlock-style, custom MLOs)
-- manage their own lock flag entirely outside GTA's CDoor system — reads as
-- "nothing to say" to every one of those natives, which risks being
-- misread as "unlocked." Treating "not registered" as license to nudge
-- would make this a concrete lockpick-equivalent bypass, not a theoretical
-- one (native_natives.md §0.5 spells out exactly this failure mode). This
-- file does not call ANY door-system native anywhere, for any purpose —
-- not even the read-only ones — full stop.
--
-- Given that constraint, the only structurally safe design is purely
-- cosmetic: something that can NEVER open a door a lock resource considers
-- closed, because it never touches door state (position, heading, freeze
-- flag, CDoor registration, anything) at all. This mirrors
-- client/vehicle.lua's documented "no real capability granted" exception
-- (vehicle entry/exit grants nothing a modified client couldn't already do
-- to itself) — same reasoning, applied to a door instead of a vehicle seat.
--
-- WHICH FALLBACK WAS ACTUALLY TAKEN — flagged explicitly per this task's
-- own instruction, for exploit-tester to verify against: none of the three
-- phase2_notes documents ever settled on a confirmed "is this door already
-- passable" detection method beyond distance.
--   - door_interaction.md §7/§8 explicitly leaves "the exact model-hash
--     list (or alternative detection method)" as "a real implementation
--     task, not a design-note-level decision" — i.e. still open, not
--     resolved.
--   - door_interaction_natives.md §7 explicitly flags "whether there's any
--     lighter-weight way to detect 'this CObject is currently a
--     swinging/hinged door' (vs. a static prop)... Not verified."
--   - door_interaction_natives.md §4's own "Practical recommendation" (the
--     most concrete guidance that exists) describes the walk-through-able
--     framing at a CONCEPTUAL level only ("play the K9's push animation as
--     it passes through a door the player can already physically walk
--     through") — it does not supply a concrete native/algorithm for
--     confirming that a specific, arbitrary door object is in that state
--     ahead of time, only for the (separately unavailable, CDoor-only)
--     registered-door subset this design deliberately avoids relying on.
-- Since no confirmed "already passable" detection method exists to gate
-- on, this implements the SIMPLEST SAFE VERSION explicitly named as the
-- fallback: NudgeDoor() plays a push impulse/animation ONLY, gated by
-- nothing beyond distance (Config.DoorInteraction.interactDistance, via
-- ox_target's own `distance` option) and CanShowK9UI() — see NudgeDoor()'s
-- own header comment below for exactly why zero additional gating is safe
-- here regardless of the target door's real state.
--
-- Config.DoorInteraction.nudgeRequiresUnlocked (Finding 3): this field's own
-- inline comment says "hard requirement, not a toggle" — but per the hard
-- constraint above, there is no real lock-state read anywhere in this file
-- for that flag to gate. Building a branch off it that behaves differently
-- based on its value would require somehow determining real lock state,
-- which is exactly the thing this design must never do. Rather than leave
-- it as a silent, unenforced no-op that could look load-bearing to a server
-- owner (the exact risk Finding 3 raises) or invent a fake lock check just
-- to give it something to gate, this ships the review's recommended
-- Option A: a resource-start assertion (see below, immediately before the
-- ox_target registration) that fails loudly if the field is ever set to
-- anything other than `true`. That is the full extent to which this flag is
-- "applied as a config gate" — it gates whether this ENTIRE RESOURCE starts
-- at all, not a runtime branch inside NudgeDoor() — which is the only way to
-- honor both "this field must do something real" and "nudge-open must never
-- branch on believed lock state."
-- ======================================================================

--- Best-effort "is this object entity plausibly a door" heuristic, used
--- ONLY to decide whether to offer the "Scratch to Alert" ox_target option
--- on a given nearby object — NOT a security check of any kind. The server
--- (server/main.lua's relayDoorScratch handler) independently resolves,
--- existence-checks, and proximity-checks whatever netId this file ends up
--- sending regardless of what this predicate decided, so a wrong answer
--- here is a UX miss (option doesn't appear on a real door, or appears on
--- something that isn't one), never a security gap — this is the same
--- "display-only plausibility gate" framing this file's header already
--- applies to IsEntityModelK9() for the leash/certify options above.
---
--- No generic "is this entity a door" native/predicate exists (confirmed by
--- phase2_notes/door_interaction_natives.md — GTA's native door SYSTEM only
--- covers doors explicitly registered via AddDoorToSystem/IPL data, a small
--- fraction of visible door props on a typical interior-heavy server, and
--- is unsuitable here anyway since Scratch-to-alert must work "on any door
--- ... regardless of lock state" per SPEC.md §11.5, i.e. registered or not).
--- Rather than hand-maintain a model-hash allow-list of specific door prop
--- names (phase2_notes/door_interaction.md §3.1's "Option 1" — flagged
--- there as LOW-MEDIUM confidence and something that would need updating
--- for every interior/MLO a server adds), this checks the entity's own
--- model name STRING for the substring "door", via GetEntityArchetypeName —
--- the same naming-pattern observation that design note makes
--- ("v_ilev_*door*, prop_*_door_*, plyr_dlc_gengarage_door" all contain the
--- literal word "door") applied generically instead of enumerated exactly.
--- CONFIDENCE: MEDIUM that GetEntityArchetypeName behaves as documented
--- (a FiveM-added native returning the entity's model/archetype name as a
--- string) — not independently re-confirmed against a live client this
--- session; LOW-MEDIUM that the substring check covers "most doors a player
--- would expect this to work on" for the same reason
--- phase2_notes/door_interaction.md §3.1 grades its own model-list approach
--- LOW-MEDIUM (door prop naming isn't fully standardized across the base
--- map). If this predicate turns out to under/over-match badly in
--- real-world testing, that's the first place to revisit — ideally with
--- native-api-assistant confirming GetEntityArchetypeName's exact behavior,
--- same verification standard this file's own K9Sit() scenario-name comment
--- already applies to itself.
--- @param entity number
--- @return boolean
local function IsLikelyDoorEntity(entity)
    local archetypeName = GetEntityArchetypeName(entity)
    return type(archetypeName) == 'string' and archetypeName:lower():find('door', 1, true) ~= nil
end

--- Precomputed model-hash -> scenario lookup for the scratch-to-alert
--- action's local visual cue on the K9 itself, built the exact same way
--- K9_SIT_SCENARIO_BY_MODEL_HASH is above. No "dog scratches at a door"
--- scenario has been confirmed to exist anywhere this session —
--- phase2_notes/door_interaction.md §4.2/§7 flags this explicitly ("no ...
--- scenario/clipset name ... has been confirmed to exist at all this
--- session — treat as unconfirmed, not assumed absent, same caveat
--- movement.lua's Sit-action header already applies to its own scenario
--- names"). Rather than fabricate an unverified "scratch" scenario name,
--- this reuses the SAME confirmed-real WORLD_DOG_BARKING_* scenarios
--- K9_SIT_SCENARIO_BY_MODEL_HASH's own comment above already names as
--- existing siblings of the sitting scenarios ("plus WORLD_DOG_BARKING_*
--- siblings, not used here" — now used here instead of an unverified
--- scratch anim). Thematically apt for an "alert" action (drawing
--- attention, per the feature's own name), and inherits that comment's
--- exact confidence grading: HIGH the scenario strings themselves exist
--- (two independently-maintained community scenario dumps agree), MEDIUM on
--- the breed-to-scenario mapping for a_c_chop/a_c_husky specifically
--- (shared substitutions, same reasoning as K9_SIT_SCENARIO_BY_MODEL_HASH).
local K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_BARKING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_BARKING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_BARKING_ROTTWEILER', -- Chop is Rottweiler-framed, same substitution as K9_SIT_SCENARIO_BY_MODEL_HASH
    a_c_husky = 'WORLD_DOG_BARKING_RETRIEVER', -- no husky-specific scenario, same substitution as K9_SIT_SCENARIO_BY_MODEL_HASH
}) do
    K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_DOOR_SCRATCH_DEFAULT_SCENARIO = 'WORLD_DOG_BARKING_SHEPHERD' -- fallback for an unmapped/future Config.Peds model, mirrors K9_SIT_DEFAULT_SCENARIO

-- Placeholder sound reference for the ACTING player's own local cue, played
-- immediately on the K9 itself (distinct from the shared/broadcast alert
-- cue played on the DOOR via the playDoorScratch receiver further below).
-- Same "harmless no-op until a real asset exists" reasoning as
-- client/main.lua's BARK_SOUND_NAME/BARK_SOUND_SET — reuses the SAME
-- placeholder soundset name ('qbx_k9unit_sounds') client/search.lua's
-- contraband-alert sound already uses, rather than inventing a second
-- placeholder soundset, since neither is a real shipped audio bank yet
-- either way (SPEC.md §7's bark-sounds asset-gap note applies identically
-- here — this is not a zero-asset feature in the end, just not a scripting
-- blocker).
local DOOR_SCRATCH_SOUND_NAME = 'DoorScratch'
local DOOR_SCRATCH_SOUND_SET = 'qbx_k9unit_sounds'

--- Shared implementation behind the "Scratch to Alert" ox_target option's
--- onSelect below.
--- @param entity number  -- resolved live entity handle from the ox_target callback's own `data.entity`
local function ScratchAtDoor(entity)
    -- Defensive re-check, same posture as every other gated action in this
    -- file (RequestLeashAttach, K9Sit, etc.) — canInteract below is a
    -- DISPLAY optimization only; server/main.lua's relayDoorScratch handler
    -- independently re-verifies Config.Features.DoorInteraction AND
    -- HasK9Access(source) regardless of what this client claims.
    if not CanShowK9UI() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
        return
    end

    if not DoesEntityExist(entity) then
        lib.notify({ title = locale('common.notify_title'), description = locale('movement.nothing_to_scratch'), type = 'error' })
        return
    end

    -- Resolve the netId NOW, before doing anything else — same
    -- handle-can-go-stale reasoning client/search.lua's PerformSearch()
    -- documents for its own identical capture-up-front pattern (entity
    -- handles get recycled once an entity is deleted/streamed out).
    local doorNetId = NetworkGetNetworkIdFromEntity(entity)

    -- Local visual/audio feedback cue on the ACTING player's own K9,
    -- per phase2_notes/door_interaction.md §4.2 ("Play a scratch/paw
    -- animation + sound cue locally on the K9 ... TriggerServerEvent(...)").
    -- This plays immediately and unconditionally (unlike client/radial.lua's
    -- Bark item, which plays no local cue at all and relies entirely on the
    -- eventual broadcast) — deliberately different from Bark's shape here,
    -- per this feature's own design note, not an inconsistency to "fix"
    -- later. The shared/broadcast alert cue (anchored to the DOOR, for
    -- every client that has it streamed in, including this one) is a
    -- SEPARATE sound played by the playDoorScratch receiver below once the
    -- server round-trips it back — this call does not substitute for that.
    local ped = PlayerPedId()
    local scenarioName = K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_DOOR_SCRATCH_DEFAULT_SCENARIO
    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
    PlaySoundFromEntity(-1, DOOR_SCRATCH_SOUND_NAME, ped, DOOR_SCRATCH_SOUND_SET, false, 0)

    TriggerServerEvent('qbx_k9unit:server:relayDoorScratch', doorNetId)
end

-- Placeholder sound reference for the nudge-open cosmetic cue, played
-- locally on the ACTING player's own K9 ONLY — there is no broadcast/relay
-- of any kind for nudge (unlike DOOR_SCRATCH_SOUND_NAME above, which is
-- also played on the door itself for every OTHER client once the server
-- round-trips it back). Same "harmless no-op until a real asset exists" /
-- shared-placeholder-soundset reasoning as DOOR_SCRATCH_SOUND_NAME.
local DOOR_NUDGE_SOUND_NAME = 'DoorNudge'

-- Feel/tuning knob for the cosmetic push impulse below — NOT a structural
-- decision (phase2_notes/door_interaction.md §8 explicitly lists "the exact
-- push-force magnitude/direction tuning for a convincing nudge animation"
-- as a tuning knob, not a design-level choice) and has zero bearing on this
-- function's safety properties either way, since it only ever scales a
-- force applied to the K9's OWN ped (see NudgeDoor()'s header comment).
local NUDGE_IMPULSE_FORCE = 2.0

--- Shared implementation behind the "Nudge Door" ox_target option's
--- onSelect below.
---
--- SAFETY DESIGN — read this file's "NUDGE-OPEN — DESIGN PATH TAKEN" header
--- comment above the door-interaction registration block further down for
--- the full writeup; summarized here at the actual point of implementation:
--- - This function NEVER calls any door-lock/CDoor native
---   (DoorSystemGetDoorState, IsDoorClosed, GetStateOfClosestDoorOfType, or
---   any sibling) and NEVER reads/writes/freezes/moves/rotates the door
---   `entity` argument in any way. The ONLY thing this function does with
---   `entity` at all is read its CURRENT POSITION (GetEntityCoords), purely
---   to compute which direction the K9's own cosmetic push impulse should
---   face — reading a position is not a lock-state check and cannot itself
---   reveal or change lock state.
--- - The impulse below is applied to the K9's OWN PED, never to `entity` —
---   deliberately more conservative than "push the door and trust a
---   door-lock resource's freeze flag to make that push a no-op when
---   locked," since that would still depend on an assumption about how some
---   unknown, unintegrated door-lock resource happens to implement its lock
---   (freezing the object is common but not guaranteed for every such
---   resource). Never touching the door object at all removes that
---   assumption entirely — there is structurally nothing for a locked door
---   to "defend against" here, regardless of how any given server's
---   door-lock resource works internally.
--- - Gating is ONLY distance (via the ox_target option's own `distance`
---   field below, Config.DoorInteraction.interactDistance) and
---   CanShowK9UI() — no reachability/"already passable" check of any kind.
---   This is the explicit fallback this file's header comment names: none
---   of the three phase2_notes documents (door_interaction.md §7/§8,
---   door_interaction_natives.md §7) ever settled on a confirmed method for
---   detecting "is this specific door object already passable" beyond the
---   conceptual framing itself, so there is nothing concrete to gate on
---   instead — and a self-only cosmetic impulse cannot grant any capability
---   regardless of the target door's real state, so skipping that gate adds
---   no risk.
--- - ZERO server involvement: no TriggerServerEvent, no callback, nothing
---   server-authoritative touched anywhere in this function — confirmed by
---   inspection (there is no TriggerServerEvent call below at all, unlike
---   ScratchAtDoor above it).
---
--- CONFIDENCE NOTE on ApplyForceToEntity's exact parameter semantics: MEDIUM
--- (a very commonly used FiveM native with a well-established call shape in
--- community scripts, but not independently re-verified against
--- raw.githubusercontent.com/citizenfx/natives this session the way
--- phase2_notes/door_interaction_natives.md verified the door-system
--- natives) — worth a native-api-assistant pass before shipping if the feel
--- is off in testing, same standard this file's own K9Sit()/ScratchAtDoor()
--- scenario-name comments already apply to themselves. This has NO bearing
--- on the safety properties above either way, since the target of the force
--- is always the K9's own ped, never the door.
--- @param entity number -- resolved live entity handle from the ox_target callback's own `data.entity`
local function NudgeDoor(entity)
    -- Defensive re-check, same posture as ScratchAtDoor/every other gated
    -- action in this file — canInteract below is a DISPLAY optimization
    -- only. Unlike ScratchAtDoor there is no server round-trip afterward to
    -- ALSO independently re-validate anything (nudge is fully client-local
    -- by design, see this file's header comment) — so this local check is
    -- the only gate that will ever run for this action, which is fine
    -- precisely because nothing below grants any real capability regardless
    -- (see the SAFETY DESIGN notes above).
    if not CanShowK9UI() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
        return
    end

    if not DoesEntityExist(entity) then
        lib.notify({ title = locale('common.notify_title'), description = locale('movement.nothing_to_nudge'), type = 'error' })
        return
    end

    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    local doorCoords = GetEntityCoords(entity) -- POSITION ONLY -- never lock/open state, see header comment above
    local toDoor = doorCoords - pedCoords
    local dist = #toDoor

    -- Degenerate-distance guard (ped and door coordinates coincide almost
    -- exactly — a bugged/zero-size prop, or the door entity resolving to
    -- the same spot as the ped) -- fall back to the ped's own current
    -- facing direction rather than dividing by ~0.
    local dir
    if dist > 0.05 then
        dir = toDoor / dist
    else
        dir = GetEntityForwardVector(ped)
    end

    -- Cosmetic forward impulse on the K9's OWN body only (never on
    -- `entity`, per the SAFETY DESIGN notes above). forceType 3 =
    -- APPLY_TYPE_IMPULSE (a single instantaneous push, not a continuous
    -- force); offset (0,0,0)/component 0 = applied at the ped's own center
    -- of mass, not an off-center torque.
    ApplyForceToEntity(ped, 3, dir.x * NUDGE_IMPULSE_FORCE, dir.y * NUDGE_IMPULSE_FORCE, 0.0, 0.0, 0.0, 0.0, 0, false, true, true, false, true)
    PlaySoundFromEntity(-1, DOOR_NUDGE_SOUND_NAME, ped, DOOR_SCRATCH_SOUND_SET, false, 0)
end

-- Register the "Scratch to Alert" ox_target option on nearby door-like
-- objects (SPEC.md §11.5: "available on any door within
-- Config.DoorInteraction.interactDistance regardless of lock state").
-- Config-gated AT REGISTRATION (the whole exports.ox_target:addGlobalObject
-- call below is wrapped in `if Config.Features.DoorInteraction`), not just
-- inside canInteract/onSelect — mirrors client/vision.lua's "config-gated
-- registration, not just config-gated behavior" precedent
-- (Config.Features.ThermalVision/NightVision gating RegisterCommand/
-- RegisterKeyMapping directly), a stricter pattern than this file's OWN
-- earlier convention of registering unconditionally and checking the flag
-- only inside canInteract (see the "Attach Leash" option above, gated by
-- Config.Features.LeashMechanics only inside canInteract). Both patterns
-- already coexist in this codebase; this option follows the stricter one on
-- purpose, per this task's explicit direction for this specific feature.
if Config.Features.DoorInteraction then
    -- Config.DoorInteraction.nudgeRequiresUnlocked "applied as a config
    -- gate" (Finding 3, phase2_notes/door_interaction_security_review.md):
    -- per this file's "NUDGE-OPEN — DESIGN PATH TAKEN" header comment
    -- above, NudgeDoor() has no real lock-state read anywhere to build a
    -- runtime branch off this flag with — doing so would require exactly
    -- the kind of believed-lock-state check this design must never perform.
    -- Instead of leaving the flag as a silent, unenforced no-op (Finding
    -- 3's core complaint — a field whose own comment claims "hard
    -- requirement, not a toggle" but that no code anywhere reads), this
    -- ships the review's recommended Option A: fail resource start LOUDLY
    -- if it's ever set to anything other than `true`, converting it from
    -- "looks load-bearing but isn't" into an active guardrail against a
    -- FUTURE implementer wiring a real (dangerous) lock-state branch off it
    -- without deliberately, reviewedly removing this assertion first.
    assert(Config.DoorInteraction.nudgeRequiresUnlocked == true,
        'Config.DoorInteraction.nudgeRequiresUnlocked must remain true -- ' ..
        'nudge-open (client/movement.lua NudgeDoor) has no lock-state check ' ..
        'of any kind, by design (it never consults GTA\'s door-lock/CDoor ' ..
        'system, see this file\'s "NUDGE-OPEN" header comment) -- this ' ..
        'assertion exists solely to fail loudly if this field is ever ' ..
        'repurposed as a real gate without a reviewed code change. See ' ..
        'phase2_notes/door_interaction_security_review.md Finding 3.')

    exports.ox_target:addGlobalObject({
        {
            name = 'qbx_k9unit:scratchDoor',
            icon = 'fas fa-paw',
            label = locale('movement.scratch_door_target_label'),
            distance = Config.DoorInteraction.interactDistance,
            canInteract = function(entity, distance, coords, name)
                if not CanShowK9UI() then return false end
                -- qa-tester finding: a vehicle-tucked K9 (frozen/invisible/
                -- attached, client/vehicle.lua's EnterNearestK9Vehicle) is
                -- nowhere near this door in any way that should let it play
                -- a scratch scenario and broadcast an alert — mirrors the
                -- leash pull-back thread's own `IsInK9Vehicle and
                -- IsInK9Vehicle()` exclusion for the identical state
                -- (client/vehicle.lua loads after this file, hence the
                -- existence guard, same reason that thread uses it).
                if IsInK9Vehicle and IsInK9Vehicle() then return false end
                return IsLikelyDoorEntity(entity)
            end,
            onSelect = function(data)
                ScratchAtDoor(data.entity)
            end,
        },
        {
            -- SEPARATE ox_target option from "Scratch to Alert" above (per
            -- this task's explicit direction), registered on the SAME
            -- door-like objects, gated behind the same
            -- Config.Features.DoorInteraction check at registration (this
            -- whole block). See NudgeDoor()'s own header comment for the
            -- full safety design this option's canInteract/onSelect below
            -- are deliberately minimal because of.
            name = 'qbx_k9unit:nudgeDoor',
            icon = 'fas fa-hand-paper',
            label = locale('movement.nudge_door_target_label'),
            distance = Config.DoorInteraction.interactDistance,
            canInteract = function(entity, distance, coords, name)
                if not CanShowK9UI() then return false end
                -- Same vehicle-tucked-K9 exclusion as "Scratch to Alert"
                -- above, same reasoning — a tucked K9 is nowhere near this
                -- door in any way that should let it play a push impulse.
                if IsInK9Vehicle and IsInK9Vehicle() then return false end
                return IsLikelyDoorEntity(entity)
            end,
            onSelect = function(data)
                NudgeDoor(data.entity)
            end,
        },
    })
end

--- Broadcast receiver for the shared "door was scratched" alert cue —
--- mirrors client/main.lua's existing playBark handler EXACTLY per SPEC.md
--- §11.4 item 6 (resolve the network entity, no-op if not streamed in, play
--- a sound), including the same defensive "0 or nonexistent" guard
--- server/main.lua's own relayDoorScratch handler already applies to this
--- SAME netId server-side before ever broadcasting it — belt-and-suspenders
--- here, since a client should never assume a netId it receives over the
--- network still resolves to something real by the time this fires
--- (streamed out between broadcast and receipt is a normal, expected race,
--- not an error worth logging/notifying about). The resolve-and-guard
--- sequence itself is now client/main.lua's shared ResolveNetworkEntity()
--- (REFACTOR_ROADMAP.md near-term item 2) — this was previously this
--- file's own independent copy of the identical sequence.
--- @param doorNetId number
RegisterNetEvent('qbx_k9unit:client:playDoorScratch', function(doorNetId)
    -- SOURCE-ORIGIN GUARD — see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. Cosmetic-only
    -- payoff here (a forged call just plays a sound at an arbitrary
    -- resolvable netId), applied for the same resource-wide consistency as
    -- every other handler in this file, not because this one carries real
    -- exploit severity on its own.
    if source ~= 65535 then return end
    local entity = ResolveNetworkEntity(doorNetId)
    if not entity then return end

    PlaySoundFromEntity(-1, DOOR_SCRATCH_SOUND_NAME, entity, DOOR_SCRATCH_SOUND_SET, false, 0)
end)

-- The ADVANCED AGILITY block (Config.Features.AgilityAdvanced's fence/
-- window vault approximation) used to live here. EXTRACTED (this pass) to
-- its own file, client/agility.lua, since it shares no local state with
-- anything above and nothing else in this resource depends on its locals
-- (confirmed by grep before moving it) -- see this file's own header
-- "EXTRACTED" note and client/agility.lua's own header for the full
-- reasoning. No behavior change: same feature flag, same command/keybind
-- name, same natives, same constants.
