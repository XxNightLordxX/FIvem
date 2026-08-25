--[[
    qbx_k9unit/server/combat.lua

    Phase 3 implementation (coder-security), PHASE3_SPEC.md §12.5.1
    (Bite-and-Hold) and §12.5.2 (Non-lethal takedown), built under §12.0
    item 8's ("the client-relay/non-cooperating-target-client architecture
    problem") own resolution and its five binding guardrails — this file
    IS that resolution's implementation, not a separate design pass.

    PHASE 3 ADDITION (this pass, coder-architect): also owns
    `PropDragging` (PHASE3_SPEC.md §12.5.4, §12.0 item 6's downed-check
    contract, §12.0 item 8's "mixed Category A/B" split for this
    specific mechanic). `HandlerDownDefense` remains OUT OF SCOPE for this
    file — still blocked on `server/partnership.lua` (§12.0 item 7) not
    existing yet, see config.lua's own Config.Combat header comment.
    PropDragging reuses this file's existing `ActiveHolds`/`K9ActiveEffect`/
    `EndHold`/`FlagNonCompliance`/shared-maintenance-thread machinery
    (`effectType = 'drag'`, a third variant alongside `'bite'`/`'takedown'`)
    rather than standing up a parallel table — see PROP DRAGGING section
    near the bottom of this file for the full writeup, and EndHold's own
    now-three-way branch for the teardown/relay differences per effectType.

    ======================================================================
    HOW THIS FILE SATISFIES ITEM 8'S FIVE BINDING GUARDRAILS (read together
    with PHASE3_SPEC.md §12.0 item 8's own text, not a substitute for it):

    1. "The detection layer ... exists in real, tested code in
       server/combat.lua — not merely the config placeholder table." See
       NON-COMPLIANCE DETECTION below — a real, single, shared sampling
       thread, not a sketch.
    2. "PropDragging's AttachEntityToEntity call is re-asserted every
       tick..." — TRUE of THIS PASS's implementation: the re-assertion
       itself is entirely client-side (client/combat.lua's ActiveDragAsHolder
       maintenance loop, which is what actually calls AttachEntityToEntity
       every frame) — this file's own contribution to guardrail 2 is that
       requestDrag/EndHold never assume the attach "worked" for anything
       server-authoritative (see guardrail 3 below), and that the
       maxDragDistance safety valve (job (a) in NON-COMPLIANCE DETECTION
       below) and the drag-specific compliance gap check (job (b)) are both
       BLIND to whether the client-side re-assertion is actually happening —
       they only ever look at live GetEntityCoords positions, never at
       "is AttachEntityToEntity still being called," which is exactly the
       right posture per item 8's own "regardless of cause" framing for this
       specific check.
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
    - 'qbx_k9unit:server:reportBiteHoldTargetDied' ()
      QA-fix completion (see this event's own handler doc comment for the
      full trust-boundary/verification writeup): sent by client/combat.lua's
      bite-hold TARGET death-detection thread, no arguments — `source` names
      the reporting (claimed-target) client. Re-verified against
      ActiveHolds/IsEntityDead server-side before acting, never trusted
      alone.
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
    - 'qbx_k9unit:client:applyNpcBiteHold' (npcNetId: number, expiresAt: number)
      Sent ONLY to the REQUESTING K9's own client — NEW, native-api-assistant
      verification pass (this session). See "NPC-TARGET NATIVE EXECUTION
      CONTEXT" below for why an NPC target's bite-suppression is relayed
      here rather than applied directly server-side as originally written.
    - 'qbx_k9unit:client:endNpcBiteHold' (npcNetId: number, reason: string)
      Sent ONLY to the requesting K9's own client — same relay, teardown
      side.
    - 'qbx_k9unit:client:applyNpcTakedown' (npcNetId: number, expiresAt: number)
      Sent ONLY to the requesting K9's own client — NEW, same session/reason
      as applyNpcBiteHold above, for NonLethalTakedown's NPC-target path.
    - 'qbx_k9unit:client:endNpcTakedown' (npcNetId: number, reason: string)
      Sent ONLY to the requesting K9's own client — same relay, teardown
      side.

    PROP DRAGGING (coder-architect, this pass, PHASE3_SPEC.md §12.5.4) —
    NEW server events (client->server), THIS FILE:
    - 'qbx_k9unit:server:requestDrag' (targetNetId: number)
    - 'qbx_k9unit:server:releaseDrag' () — either the HOLDING K9 or, when
      the target is a player, the TARGET can send this; server resolves
      which side `source` is and ends the drag either way. Zero consent
      needed from the other side either direction — mirrors leash's own
      "no consent needed to get free" rule, PHASE3_SPEC.md §12.0 item 4/
      §12.5.4, and is stronger than BiteAndHold/NonLethalTakedown's own
      target (who has NO self-release action at all — apprehension, not a
      cooperative mechanic).

    NEW client events (server->client), registered by client/combat.lua:
    - 'qbx_k9unit:client:dragStarted' (targetNetId: number, isPlayerTarget:
      boolean, expiresAt: number)
      Sent ONLY to the HOLDING K9's own client. Starts that client's own
      per-tick AttachEntityToEntity re-assertion loop (Category A, see this
      file's header "PROP DRAGGING — CATEGORY A/B SPLIT" section below) and,
      when `isPlayerTarget` is false, ALSO the direct
      SetPedMoveRateOverride(npcPed, ...) re-assertion on the NPC target
      every tick (no relay problem for an NPC — same posture as
      applyNpcBiteHold/applyNpcTakedown above, just for move-rate instead of
      flee-suppression/ragdoll).
    - 'qbx_k9unit:client:dragEnded' (targetNetId: number, reason: string)
      Sent ONLY to the holding K9's own client — stops the re-assertion
      loop, calls DetachEntity once, and (NPC target only) resets that
      NPC's move rate back to 1.0.
    - 'qbx_k9unit:client:applyDragSpeedLimit' (expiresAt: number)
      Sent ONLY to a PLAYER target's own client (never to an NPC — NPCs have
      no "own client," see dragStarted above) — the Category B half of
      dragging, PHASE3_SPEC.md §12.0 item 8. Re-asserted by that client
      every tick via SetPedMoveRateOverride, either directly or through
      client/movement.lua's shared move-rate composer depending on whether
      THAT client's own ped is currently a K9 model — see client/combat.lua's
      own header for why a blanket "always go through the composer" reading
      would silently no-op for the common (non-K9 target) case.
    - 'qbx_k9unit:client:endDragSpeedLimit' (reason: string)
      Sent ONLY to a player target's own client — restores move rate to 1.0
      and self-detaches as a defense-in-depth backstop (see client/combat.lua).

    ======================================================================
    NPC-TARGET NATIVE EXECUTION CONTEXT — RESTRUCTURED this session
    (native-api-assistant verification pass), superseding this file's own
    ORIGINAL "NPC target: this server already fully commands this entity,
    no relay problem" reasoning for BiteAndHold/NonLethalTakedown's
    NPC-target branches. That reasoning assumed
    SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes/SetEntityCanBeDamaged/
    SetPedToRagdollWithFall are all plainly callable server-side against a
    server-spawned NPC ped. Verified against the canonical
    citizenfx/fivem native declarations this session:
    - SetEntityCanBeDamaged (0x1760FFA8AB074D66, `ENTITY` namespace) is
      CONFIRMED CLIENT-ONLY — no `apiset` entry in the primary source,
      which per that same repo's own codegen convention means the native
      never lands in FXServer's compiled table at all. The original
      server-side call in HandleTakedownRequest's NPC branch was
      therefore a SILENT NO-OP, a real correctness/safety bug: the
      damage-bracket that is supposed to make a takedown non-lethal never
      actually applied to a server-spawned NPC target, and the health-floor
      backstop alone is a reactive one-time top-up, not a continuous damage
      block, so it cannot honestly cover sustained damage from another
      source during the ragdoll window on its own.
    - SetPedFleeAttributes, SetBlockingOfNonTemporaryEvents, and
      SetPedToRagdollWithFall (all `PED` namespace) could NOT be confirmed
      either way this session — the primary source's PED section and every
      mirror/doc host tried were unreachable. Indirect community
      corroboration is consistent with "client-only, same as
      SetEntityCanBeDamaged" but is NOT independent primary-source
      confirmation — graded MEDIUM confidence / single indirect source,
      honestly, not upgraded to match the one native that WAS confirmed.
    Rather than assert an unresolved server-side legitimacy for three
    natives just to keep one code shape, or leave one bug fixed and three
    others standing on an unverified assumption, ALL FOUR are relayed to
    the REQUESTING K9's OWN client instead — unambiguously a valid
    execution context for all four regardless of their server-side status
    (their CLIENT-side validity was never in question; SetPedToRagdollWithFall
    is already independently confirmed client-callable by this same file's
    own player-target relay, applied via client/combat.lua's forceRagdoll
    handler). This is not a weakening of server authority: the server has
    already independently completed every real check (feature flag,
    HasK9Access, live proximity, cooldowns, the speed gate for takedown)
    BEFORE ever sending one of these four relay events — only the
    MECHANICAL "make the NPC do X" step moves client-side, to the one actor
    already fully trusted for this action, mirroring the exact posture this
    file already uses for a PLAYER target (relay to the target's own
    client) just relayed to the K9 instead, since an NPC has no "own
    client" to relay to. See client/combat.lua's own header for the
    receiving-side implementation.
    ======================================================================

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
    - Calls HasK9Access(source) (server/certifications.lua),
      ResolveNetworkEntity(netId, expectedEntityType?) (server/entities.lua),
      and ResolveConnectedPlayerFromPed(entity) (server/entities.lua,
      REFACTOR_ROADMAP.md item 2b — see the PLAYER-VS-NPC RESOLUTION
      section below) — does not re-implement any of the three.
    - Calls NewCooldown()/NewMutex() (server/cooldowns.lua) — every
      cooldown/in-flight-guard below is one of these constructors, never a
      hand-rolled table, per REFACTOR_ROADMAP.md item 1's own standing
      convention for this resource.
    - Calls IsHesitating(citizenid)/IsDistracted(citizenid), resource-globals
      from server/wellbeing.lua, ONLY IF THOSE FUNCTIONS EXIST (`type(...) ==
      'function'` guard — same soft-dependency convention as
      server/medkit.lua's RestoreInjury/server/tracking.lua's AwardXP call
      sites, never a load-order assumption). server/wellbeing.lua's own
      header names THIS file's request-validation path as "THE genuine new
      cross-file dependency" it added these two accessors for — see
      ValidateCombatRequest below for the actual call site. A K9 whose own
      character is currently hesitating (FearStress) or distracted cannot
      have a bite-hold/takedown request granted; this is a check on the
      REQUESTING K9's own wellbeing state, never the target's.
      SECURITY (coder-security, config-audit follow-up pass — see
      ValidateCombatRequest's own inline comment below and
      server/wellbeing.lua's IsHesitating doc comment for the full
      writeup): IsHesitating()'s underlying signal (fearStress, driven by
      the payload-less/forgeable 'relayWeaponFire' event) is not something
      this file can independently verify — this call site is a hard reject
      on a value server/wellbeing.lua itself documents as forgeable by ANY
      connected player who gets physically near the TARGET K9 (not just by
      that K9's own actions). server/wellbeing.lua's own
      HESITATION_MAX_CONTINUOUS_MS bounds the worst case (a forged
      hesitation episode cannot renew forever — every episode is followed
      by a guaranteed window where this gate grants normally again), so
      this is a disclosed, bounded nuisance risk, not an indefinite
      denial-of-capability. If this call site's trust in IsHesitating() ever
      changes (e.g. a soft penalty replaces the hard reject, or a
      corroboration signal is added upstream), update wellbeing.lua's
      matching disclosure in the same pass — this is exactly the kind of
      cross-file disclosure that goes stale silently otherwise.
    - Calls AwardXP(citizenid, awardKey), resource-global from
      server/progression.lua, ONLY IF IT EXISTS (same runtime-existence-guard
      convention, mirroring server/tracking.lua's own trackSourceResolved
      call site exactly) — see EndHold (BiteAndHold) and
      HandleTakedownRequest (NonLethalTakedown) for the two award call
      sites and their own anti-farm reasoning. Config.XP.awards.biteHoldSuccess/
      .takedownSuccess (config.lua) are the two award keys this file owns;
      searchContrabandFound/trackSourceResolved belong to
      server/search.lua/server/tracking.lua respectively, not here.
    - Loaded in fxmanifest.lua's server_scripts after cooldowns.lua,
      entities.lua, and certifications.lua (all three are load-time
      dependencies of this file). No ordering dependency on
      server/wellbeing.lua or server/progression.lua either way (both are
      consumed through runtime existence guards, not a load-order
      assumption) — same posture server/medkit.lua's own fxmanifest.lua
      comment already documents for RestoreInjury.
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
    verified reliability.

    EXTRACTION UPDATE (REFACTOR_ROADMAP.md item 2b): this file's own copy
    was flagged above (when this comment was first written) as "worth
    flagging to coder-architect as an extraction candidate now that there
    are two" — that observation was already stale on arrival, since
    server/inventory.lua had independently hand-copied the identical
    function before this file landed, making three. `ResolveConnectedPlayerFromPed`
    is now a resource-global exposed by server/entities.lua (same file,
    same responsibility, as `ResolveNetworkEntity`); this file's own local
    copy is deleted and ValidateCombatRequest below calls the shared
    global instead, with no change to its own logic or call site.
    ======================================================================

    NON-COMPLIANCE DETECTION (PHASE3_SPEC.md §12.0 item 8, point 2) — real,
    implemented sampling, not a sketch. TWO shared maintenance threads (never
    one thread per active effect, mirroring server/tracking.lua's
    PruneTrackableLogs single-pass-over-a-shared-table discipline), each
    doing exactly one job, on two DELIBERATELY DECOUPLED intervals:
      (a) the expiry thread (MAINTENANCE_INTERVAL_MS below, hardcoded,
          NEVER Config.Combat.NonComplianceDetection.positionSampleWindowMs)
          enforces every active hold/ragdoll's hard expiresAt cap — ALWAYS,
          regardless of Config.Combat.NonComplianceDetection.enabled — this
          is item 4's "no unbounded trap" guarantee and must never be gated
          behind, or have its timing at the mercy of, the detection
          feature's own (separately configurable) sampling interval;
      (b) IF NonComplianceDetection.enabled, a second, independent thread
          runs on its own positionSampleWindowMs interval and samples the
          target's live, server-authoritative position (GetEntityCoords —
          NEVER a client-reported value), applying the PER-EFFECT heuristic
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
--     effectType   = 'bite' | 'takedown' | 'drag',
--     holderSrc    = number,           -- the K9 player's own source
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

-- Anti-farm floor for BiteAndHold's XP award (Config.XP.awards.biteHoldSuccess,
-- config.lua) — see EndHold's own award call site below for the full
-- reasoning. UNTUNED placeholder, same "flag the number, don't pretend it's
-- reviewed" convention as every other numeric constant in this file/this
-- codebase pending a config-validator pass. A hold that ends via 'timeout'
-- always clears this floor trivially (timeout cannot fire before
-- Config.Combat.BiteAndHold.maxDurationMs elapses); this constant only ever
-- actually gates the 'released' path, specifically to block an
-- accept-then-immediately-release macro from minting XP with no real
-- restraint ever having happened.
local MIN_BITE_HOLD_XP_DURATION_MS = 3000

local TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS = 60000
TakedownTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (Config.Combat.NonLethalTakedown.targetCooldownMs * 2)
end)

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by REFACTOR_ROADMAP.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

-- ResolveConnectedPlayerFromPed(entity) used to be defined here as a local
-- function (duplicated from server/search.lua's own copy). Extracted to
-- server/entities.lua as a resource-global per REFACTOR_ROADMAP.md item
-- 2b — see this file's header "PLAYER-VS-NPC RESOLUTION" section's
-- "EXTRACTION UPDATE" note for the full reasoning. ValidateCombatRequest
-- below now calls that shared global instead.

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

--- PHASE3_SPEC.md §12.0 item 6 / §12.5.4 — PropDragging's "is this target
--- actually downed" gate. NEVER reuses ValidateCombatRequest's own
--- IsEntityDead check (that check exists specifically to REJECT a dead
--- target for BiteAndHold/NonLethalTakedown, the exact opposite of what
--- dragging wants) — called as a SEPARATE step, after
--- ValidateCombatRequest({requireAlive = false}) has already succeeded.
---
--- NPC branch: fully native, exactly as §12.5.4 specifies
--- (`IsPedDeadOrDying(ped, true)` OR `IsPedRagdoll(ped)`) — no external
--- dependency, HIGH confidence per phase2_notes/phase3_combat_natives.md's
--- own confirmation of IsPedRagdoll and its explicit naming of this exact
--- pairing as PropDragging's "downed" approximation. IsPedDeadOrDying's own
--- server-side callability (a read-only ped-state getter, same class as
--- GetEntityHealth/IsEntityDead already called server-side elsewhere in
--- this file) was reasoned about by analogy rather than independently
--- re-verified against the primary native declarations this pass — flagged
--- honestly per this file's own established confidence-grading convention,
--- not silently asserted as confirmed.
---
--- Player branch: NEVER the native checks above (§12.0 item 6 — raw
--- physics/AI state is a category mismatch for a server's own scripted
--- laststand state, with concrete false-positive/false-negative modes) —
--- override function first, FAILS CLOSED on error (same discipline as
--- IsPlayerWantedEligible above — a broken override must never silently
--- widen who can be dragged), else the default best-effort
--- metadata.isdead/.inlaststand guess.
--- @param targetPed number
--- @param isPlayerTarget boolean
--- @param targetSrc number?
--- @return boolean downed
local function IsTargetDowned(targetPed, isPlayerTarget, targetSrc)
    if not isPlayerTarget then
        return IsPedDeadOrDying(targetPed, true) or IsPedRagdoll(targetPed)
    end

    local override = Config.Combat.PropDragging.IsPlayerDownedOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, targetSrc)
        if not ok then
            print(('[qbx_k9unit] Config.Combat.PropDragging.IsPlayerDownedOverride errored for source %s: %s -- failing closed (target treated as NOT downed)'):format(targetSrc, tostring(result)))
            return false
        end
        return result == true
    end

    -- Default best-effort check -- see config.lua's own comment on this
    -- field for the confidence note (HIGHER confidence than
    -- WantedStatusCheckOverride's equivalent default, per PHASE3_SPEC.md
    -- §12.0 item 6 vs. item 5).
    local player = exports.qbx_core:GetPlayer(targetSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) ~= 'table' then return false end
    return metadata.isdead == true or metadata.inlaststand == true
end

-- RED-TEAM FINDING (PropDragging), resource-start WARNING, not an assert.
-- Config.Combat.PropDragging.IsPlayerDownedOverride is nil by default --
-- IsTargetDowned's own doc comment above and config.lua's own comment on
-- this field both already disclose that the fallback
-- (metadata.isdead/.inlaststand) is a best-effort guess, not a verified
-- state machine. What neither previously spelled out this loudly: on most
-- QB/qbx ambulance integrations that metadata is set by a CLIENT-self-
-- reported event, not a server-verified one, so on a default install a
-- player can flip it true to become an always-eligible drag target (LOW
-- impact -- they can self-release at any time via releaseDrag below, and no
-- XP/reward is attached to being the drag TARGET), or flip it false while
-- genuinely downed to become permanently undraggable -- which defeats the
-- mechanic's entire purpose against an incapacitated player.
--
-- WARNING, NOT ASSERT -- deliberately a WEAKER guard than
-- server/inventory.lua's accessScope assert or server/main.lua's
-- nudgeRequiresUnlocked/server/search.lua's own onResourceStart asserts.
-- Those asserts exist because their misconfigured value provided NO real
-- access control at all (a total defeat). This default is different in
-- kind, not just degree: it is a documented, already-disclosed
-- "best-effort" default (the SAME framing config.lua already gives
-- WantedStatusCheckOverride's identical nil-default case), it still
-- functions in the mechanic's intended direction for the ordinary,
-- non-adversarial case, and Config.Features.PropDragging itself defaults to
-- `false` (this codebase's "ship disabled until acceptance criteria are
-- fully met" convention) -- hard-failing resource start over a
-- disabled-by-default, already-disclosed best-effort gap would block every
-- server that flips PropDragging on without also wiring a real override on
-- day one, for a risk this file already discloses rather than hides. A
-- loud, actionable, printed warning -- impossible to miss in server console
-- output, unlike a comment only read by whoever opens this file -- is the
-- proportionate response here, not a hard stop.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if Config.Features.PropDragging and Config.Combat.PropDragging.IsPlayerDownedOverride == nil then
        print('[qbx_k9unit] WARNING: Config.Features.PropDragging is enabled but ' ..
            'Config.Combat.PropDragging.IsPlayerDownedOverride is nil. The default fallback ' ..
            '(metadata.isdead/.inlaststand) is typically a CLIENT-self-reported flag on QB/qbx ' ..
            'ambulance integrations, not a server-verified state machine -- a player can spoof it ' ..
            'true to always qualify as a drag target, or spoof it false to become permanently ' ..
            'undraggable while genuinely downed. Supply a real IsPlayerDownedOverride tied to your ' ..
            "own ambulance/laststand resource for a server-authoritative check (see config.lua's " ..
            'own comment on this field).')
    end
end)

--- Best-effort, non-restraint-implying rejection copy (guardrail 4) —
--- shared between BiteAndHold, NonLethalTakedown, and PropDragging since
--- their reason vocabularies overlap almost entirely.
local COMBAT_REJECT_MESSAGES = {
    feature_disabled   = 'This feature is disabled on this server.',
    invalid_target     = 'Invalid target.',
    no_access          = 'You are not certified for K9 duty.',
    already_engaged    = 'You are already engaged with another target.',
    offline            = 'Unable to resolve your own K9.',
    self_target        = 'You cannot target yourself.',
    target_not_downed  = 'That target does not appear to be downed.',
    target_dead        = 'That target is down.',
    too_far            = 'You are too far from the target.',
    already_held       = 'That target is already held by another K9.',
    not_eligible_target = 'That target is not currently eligible.',
    not_fleeing        = 'The target does not appear to be fleeing.',
    on_cooldown        = 'You must wait before attempting that again.',
    -- server/wellbeing.lua-driven — these describe the REQUESTING K9's own
    -- state, never the target's (see this file's header FILE-TO-FILE
    -- CONTRACT entry for IsHesitating/IsDistracted).
    hesitating         = 'Your K9 is too stressed to comply right now.',
    distracted         = 'Your K9 is distracted and not responding to commands.',
}

--- @param reason string?
--- @return string
local function CombatRejectMessage(reason)
    return COMBAT_REJECT_MESSAGES[reason] or 'Unable to complete that action.'
end

--- Shared request-time validation for BiteAndHold, NonLethalTakedown, AND
--- (this pass) PropDragging — PHASE3_SPEC.md §12.5.1/§12.5.2/§12.5.4's own
--- contract blocks specify an identical validation prefix for all three
--- (`requestBiteHold`/`requestTakedown`/`requestDrag`'s own doc text:
--- "re-validates ... HasK9Access(source), live proximity ..., resolves
--- player-vs-NPC ..., and — if the target is a player — RequireWantedStatus").
--- Feature-flag and range are passed in since those differ per effect;
--- everything else here is identical.
---
--- @param opts table? -- OPTIONAL, PropDragging-only knob (added this pass,
---   never passed by requestBiteHold/requestTakedown, so their behavior is
---   byte-for-byte unchanged): `opts.requireAlive` (default true via
---   `opts.requireAlive ~= false`). PropDragging passes
---   `{ requireAlive = false }` because its ENTIRE premise is a DOWNED
---   target — the IsEntityDead rejection below exists specifically to
---   REJECT BiteAndHold/NonLethalTakedown's target when dead, the opposite
---   of what dragging wants. PropDragging's own IsTargetDowned (above) is
---   the real "is this specific target eligible" check for that mechanic,
---   run by the caller AFTER this function returns ok == true — it is
---   deliberately NOT folded into this shared function, to keep this
---   function's own contract (identical prefix, effect-agnostic) honest
---   rather than growing a per-effect branch inside a "shared" validator.
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
local function ValidateCombatRequest(src, targetNetId, featureEnabled, rangeMeters, opts)
    opts = opts or {}
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

    -- server/wellbeing.lua §13.5 cross-file dependency, wired here for real
    -- (this file's own header names the exact call site) — a K9 whose OWN
    -- character is currently hesitating (FearStress) or distracted cannot
    -- have a request granted at all, checked BEFORE any other state is
    -- resolved/mutated, same "read-only precondition first" discipline this
    -- function already documents above. Runtime existence guard: neither
    -- accessor is assumed to exist by load order (server/wellbeing.lua may
    -- be absent, or its features disabled) — see server/medkit.lua's
    -- RestoreInjury for the identical guard shape. pcall-wrapped: an error
    -- inside either accessor must fail this specific request closed (never
    -- granted), not bubble up and abort the whole event handler for an
    -- unrelated reason.
    if type(IsHesitating) == 'function' or type(IsDistracted) == 'function' then
        local k9Player = exports.qbx_core:GetPlayer(src)
        local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
        if k9Citizenid then
            if type(IsHesitating) == 'function' then
                local ok, hesitating = pcall(IsHesitating, k9Citizenid)
                if ok and hesitating then
                    return false, nil, nil, nil, nil, 'hesitating'
                end
            end
            if type(IsDistracted) == 'function' then
                local ok, distracted = pcall(IsDistracted, k9Citizenid)
                if ok and distracted then
                    return false, nil, nil, nil, nil, 'distracted'
                end
            end
        end
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

    if opts.requireAlive ~= false and IsEntityDead(targetPed) then
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

--- Shared teardown for ALL THREE effect types — release, timeout, or
--- disconnect all funnel through here so there is exactly one place that
--- mutates ActiveHolds/K9ActiveEffect on the way out (mirrors
--- server/main.lua's own doDetachLeash "there is exactly one place that
--- mutates LeashPairs on detach" discipline).
---
--- RESTRUCTURED this pass (PropDragging addition): the relay-selection
--- logic below used to be an implicit two-way "'bite' vs. else(=takedown)"
--- branch — adding a third effectType on top of that binary would have
--- silently sent 'drag' down the 'takedown' relay paths (endForceRagdoll/
--- endNpcTakedown), which is wrong (dragging has its own, differently-shaped
--- event contract — see this file's header EVENT/CALLBACK CONTRACT). Made
--- explicit as a real three-way `if/elseif/else` instead, with each of the
--- three branches' behavior for 'bite'/'takedown' kept byte-for-byte
--- identical to before this restructure.
--- @param targetNetId number
--- @param reason string
local function EndHold(targetNetId, reason)
    local hold = ActiveHolds[targetNetId]
    if not hold then return end

    ActiveHolds[targetNetId] = nil
    if K9ActiveEffect[hold.holderSrc] == targetNetId then
        K9ActiveEffect[hold.holderSrc] = nil
    end

    if hold.effectType == 'bite' then
        if hold.isPlayerTarget then
            -- Category B teardown relay -- best-effort, same posture as the
            -- apply side (PHASE3_SPEC.md §12.0 item 8). If the target's
            -- client ignored the apply event in the first place, it will
            -- almost certainly ignore this one too — that is an accepted,
            -- disclosed limitation (item 8's own guardrail 3 is exactly why
            -- nothing server-authoritative depends on this succeeding).
            TriggerClientEvent('qbx_k9unit:client:endBiteHold', hold.targetSrc, reason)
        else
            -- NPC target — RESTRUCTURED, native-api-assistant verification
            -- pass (an earlier session): see this file's header "NPC-TARGET
            -- NATIVE EXECUTION CONTEXT" note for the full finding. Relayed
            -- to the REQUESTING K9's OWN client (client/combat.lua), same
            -- as the apply side — never called directly server-side.
            TriggerClientEvent('qbx_k9unit:client:endNpcBiteHold', hold.holderSrc, targetNetId, reason)
        end

        TriggerClientEvent('qbx_k9unit:client:biteHoldEnded', hold.holderSrc, targetNetId, reason)

        -- Config.XP.awards.biteHoldSuccess (config.lua) — QA-flagged as dead
        -- code (configured, never granted) until an earlier pass.
        -- "Genuinely successful" is deliberately narrower than "a hold
        -- merely existed": excludes 'holder_disconnected'/
        -- 'target_disconnected' (incomplete, not an intentional outcome)
        -- outright, and further requires MIN_BITE_HOLD_XP_DURATION_MS to
        -- have elapsed for a 'released' end (never for 'timeout', which
        -- cannot fire early — see that constant's own declaration comment
        -- for the full anti-farm reasoning). Runtime existence guard, same
        -- convention as server/tracking.lua's own trackSourceResolved call
        -- site — no load-order assumption on server/progression.lua.
        if reason == 'released' or reason == 'timeout' then
            local heldDurationMs = GetGameTimer() - hold.startedAt
            if reason == 'timeout' or heldDurationMs >= MIN_BITE_HOLD_XP_DURATION_MS then
                if type(AwardXP) == 'function' then
                    local holderPlayer = exports.qbx_core:GetPlayer(hold.holderSrc)
                    local holderCitizenid = holderPlayer and holderPlayer.PlayerData and holderPlayer.PlayerData.citizenid
                    if holderCitizenid then
                        AwardXP(holderCitizenid, 'biteHoldSuccess')
                    end
                end
            end
        end
    elseif hold.effectType == 'takedown' then
        if hold.isPlayerTarget then
            TriggerClientEvent('qbx_k9unit:client:endForceRagdoll', hold.targetSrc, reason)
        else
            TriggerClientEvent('qbx_k9unit:client:endNpcTakedown', hold.holderSrc, targetNetId, reason)
        end

        if reason ~= 'timeout' then
            -- Takedown has no manual "release" action (PHASE3_SPEC.md
            -- §12.5.2 lists no release event) — only notify the K9 for a
            -- non-timeout reason (e.g. the target disconnecting mid-ragdoll);
            -- a plain timeout is the expected, silent end of a successful
            -- takedown.
            NotifyPlayer(hold.holderSrc, 'The takedown ended early.', 'inform')
        end
    else -- 'drag' (PHASE3_SPEC.md §12.5.4, this pass)
        -- Category A (attach) teardown ALWAYS goes to the HOLDING K9's own
        -- client regardless of target kind — that client is the one
        -- actually calling AttachEntityToEntity/DetachEntity, §12.0 item 8's
        -- new finding on DetachEntity's own lack of an ownership gate. The
        -- Category B speed-limit half ADDITIONALLY goes to the target's own
        -- client, but ONLY when that target is a player — an NPC's move
        -- rate is reset by this SAME dragEnded handler on the K9's own
        -- client instead (see client/combat.lua's own header) — there is no
        -- separate "NPC drag speed" relay event, unlike bite/takedown's own
        -- applyNpc*/endNpc* pair, because the K9's client already receives
        -- everything it needs via dragStarted's own isPlayerTarget field.
        TriggerClientEvent('qbx_k9unit:client:dragEnded', hold.holderSrc, targetNetId, reason)
        if hold.isPlayerTarget then
            TriggerClientEvent('qbx_k9unit:client:endDragSpeedLimit', hold.targetSrc, reason)
        end

        if reason ~= 'released_by_holder' and reason ~= 'released_by_target' then
            -- Only notify for a NON-manual end (timeout/disconnect/the
            -- maxDragDistance safety valve) -- a manual release from either
            -- side is self-evident to that side already (the
            -- button/keybind press itself is the feedback), mirroring
            -- takedown's own "only notify for a non-expected end" posture
            -- above.
            NotifyPlayer(hold.holderSrc, 'The drag ended.', 'inform')
        end
    end
end

--- Resource-global (no `local`) accessor exposed for OTHER files that need
--- to unconditionally end whatever engagement (bite/takedown/drag) a K9 is
--- CURRENTLY the HOLDER of, regardless of who is asking or that K9's own
--- current certification/access state. server/recall.lua's Recall actor
--- (PHASE3_SPEC.md §12.5.1, §12.0 item 7's "Recall actor" consumer) is this
--- function's one intended caller today -- resolved through the SAME
--- `type(...) == 'function'` runtime-existence-guard convention this file
--- already uses for IsHesitating/IsDistracted/AwardXP (see FILE-TO-FILE
--- CONTRACT above), never a load-order assumption, since server/recall.lua's
--- own position in fxmanifest.lua's server_scripts relative to THIS file is
--- not, and should not need to be, load-bearing.
---
--- DELIBERATELY NEVER CHECKS HasK9Access/Config.Features.* ITSELF -- this is
--- a TERMINATION path, and PHASE3_SPEC.md's own "no unbounded trap"
--- guarantee (§12.0 item 4, restated for Recall specifically at §12.5.1)
--- requires that a K9 whose certification is revoked, or whose feature flag
--- is toggled off, mid-engagement can still be called off; gating this
--- function on either would reintroduce exactly the trap that guarantee
--- forbids. The caller (server/recall.lua) is responsible for its OWN
--- authorization (verifying the requester is genuinely `holderSrc`'s
--- established partner, per server/partnership.lua) -- this function's own
--- contract is narrower and unconditional: "does this holder have an active
--- engagement, and if so, end it," nothing more.
---
--- pcall-wrapped internally (mirrors this file's own shared-maintenance-
--- thread precedent for EndHold above) so an unexpected error inside
--- EndHold/AwardXP/a TriggerClientEvent argument can never propagate into an
--- unrelated caller's own event handler and abort IT for a reason that has
--- nothing to do with that caller's own logic.
--- @param holderSrc number
--- @return boolean ended -- false if `holderSrc` has no active engagement (a genuine no-op, not an error)
function EndActiveEffectForHolder(holderSrc)
    local targetNetId = K9ActiveEffect[holderSrc]
    if not targetNetId then return false end

    local ok, err = pcall(EndHold, targetNetId, 'recalled')
    if not ok then
        print(('[qbx_k9unit] EndActiveEffectForHolder(recalled) errored for holderSrc %s, targetNetId %s: %s'):format(holderSrc, targetNetId, tostring(err)))
        return false
    end
    return true
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
    if not targetPed then return end -- DEFENSE IN DEPTH: the expiry thread's own resolvability check (RED-TEAM FINDING, see its own comment) ends an unresolvable hold on ITS OWN next tick, but this function now runs on a SEPARATE, independently-configurable sampling thread (positionSampleWindowMs) rather than sharing the expiry thread's tick — so a target can legitimately go unresolvable in the gap between the two threads' ticks. Silently returning here (never erroring) is the correct handling for that ordinary race, not just a "should not normally trigger" backstop.

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
    elseif hold.effectType == 'takedown' then
        -- Net displacement from the ragdoll-open baseline, NOT a
        -- continuous speed check — see this file's header for why, and for
        -- the disclosed "heading consistency not implemented" narrowing.
        local netDisplacement = #(currentPos - compliance.baselinePos)
        if not compliance.flagged and netDisplacement > cfg.takedownNetDisplacementMeters then
            compliance.flagged = true
            FlagNonCompliance(hold, targetNetId, 'takedown_displacement',
                ('netDisplacement=%.2fm threshold=%.2fm'):format(netDisplacement, cfg.takedownNetDisplacementMeters))
        end
    else -- 'drag' (PHASE3_SPEC.md §12.5.4/§12.0 item 8, this pass)
        -- Only meaningful for a PLAYER target -- an NPC target has no "own
        -- client" to ignore the speed-limit relay in the first place (the
        -- K9's own already-trusted client directly commands the NPC's move
        -- rate every tick, same posture as bite/takedown's NPC branches) --
        -- so there is no hostile party to detect here, unlike bite/takedown
        -- above which sample BOTH target kinds uniformly (a pre-existing
        -- choice this pass does not relitigate). Compares the target's live
        -- position against the K9's OWN live position (never an absolute
        -- speed ceiling) -- PHASE3_SPEC.md §12.0 item 8's own framing:
        -- "regardless of cause (self-detach, a bypassed move-rate override,
        -- or the K9's own client failing to re-assert the attach)" — this
        -- single geometric check catches all three failure modes at once
        -- without needing to distinguish which one occurred.
        if hold.isPlayerTarget then
            local k9Ped = GetPlayerPed(hold.holderSrc)
            if k9Ped ~= 0 then
                local gap = #(currentPos - GetEntityCoords(k9Ped))
                if not compliance.flagged and gap > cfg.dragComplianceSlackMeters then
                    compliance.flagged = true
                    FlagNonCompliance(hold, targetNetId, 'drag_gap',
                        ('gap=%.2fm slack=%.2fm'):format(gap, cfg.dragComplianceSlackMeters))
                end
            end
        end
    end

    compliance.lastPos = currentPos
    compliance.lastTime = now
end

--- PHASE3_SPEC.md §12.0 item 4's "no unbounded trap" guarantee for
--- PropDragging specifically — item 4's own text names `maxDragDistance`
--- (not a duration) as this mechanic's analog of BiteAndHold/
--- NonLethalTakedown's hard `maxDurationMs`/ragdoll-window caps. ALWAYS
--- enforced (see the maintenance thread's own call site below — checked
--- unconditionally, never gated behind `NonComplianceDetection.enabled`,
--- exactly like the `hold.expiresAt` check it sits alongside) — distinct
--- from the drag_gap NON-PUNITIVE detection signal above, which is a
--- smaller, log-only slack meant to catch a likely-hostile target sooner;
--- this is the hard, always-on safety valve that actually ends the drag.
--- @param hold table
--- @param targetNetId number
--- @return boolean exceeded
local function DragExceedsMaxDistance(hold, targetNetId)
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then return false end -- DEFENSE IN DEPTH ONLY, should not normally trigger: same "maintenance thread's own resolvability check already ends this hold first" reasoning as SampleCompliance's own identical guard above

    local k9Ped = GetPlayerPed(hold.holderSrc)
    if k9Ped == 0 then return false end -- holder already disconnected; the playerDropped handler tears this down independently

    local dist = #(GetEntityCoords(k9Ped) - GetEntityCoords(targetPed))
    return dist > Config.Combat.PropDragging.maxDragDistance
end

-- Shared EXPIRY maintenance thread — see this file's header for why this
-- is ALWAYS running (expiry enforcement, job (a)) regardless of whether
-- detection sampling (job (b), its own separate thread below) is enabled.
-- A fixed interval, deliberately NOT derived from
-- Config.Combat.NonComplianceDetection.positionSampleWindowMs — expiry
-- (the "no unbounded trap" guarantee) must never be delayed by a large/
-- misconfigured detection-sampling interval.
local MAINTENANCE_INTERVAL_MS = 500

-- PERFORMANCE FIX (QA pass), gated at thread-creation time ONLY — never
-- re-checked inside the loop, matching the sibling compliance-sampling
-- thread's own "Config is read once at resource start and never mutated at
-- runtime" precedent immediately below. Safe because `ActiveHolds` cannot
-- receive an entry from ANY path unless one of BiteAndHold/
-- NonLethalTakedown/PropDragging is on: every write site (requestBiteHold,
-- the takedown handler, requestDrag) routes through ValidateCombatRequest's
-- `featureEnabled` parameter, which returns 'feature_disabled' and writes
-- nothing before that write site is reached. HandlerDownDefense is included
-- even though it never itself writes an ActiveHolds entry (it only relays a
-- pre-selected-target NOTIFICATION to the K9's own client per this file's
-- header/server/defense.lua's own "UI/auto-targeting CONVENIENCE, never an
-- AI takeover" rule — the K9 must still separately trigger
-- requestBiteHold/requestTakedown, independently re-gated on their own
-- flags) — included here purely as defense-in-depth so this condition
-- never has to be revisited if that division of responsibility ever
-- changes. With all four false, `ActiveHolds` is provably always empty, so
-- not running this thread is behaviorally identical to running it forever
-- against an empty table — no hold can ever be stranded by this gate.
if Config.Features.BiteAndHold or Config.Features.NonLethalTakedown or Config.Features.PropDragging or Config.Features.HandlerDownDefense then
    CreateThread(function()
        while true do
            Wait(MAINTENANCE_INTERVAL_MS)
            local now = GetGameTimer()

            for targetNetId, hold in pairs(ActiveHolds) do
                if now >= hold.expiresAt then
                    -- MEDIUM, QA-flagged this session: EndHold reaches AwardXP
                    -- (guarded only by a `type(...) == 'function'` existence
                    -- check, no pcall of its own) and TriggerClientEvent calls
                    -- that could theoretically error on bad state — the
                    -- compliance-sampling thread's own SampleCompliance call
                    -- is already pcall-wrapped for exactly this reason; this
                    -- call was not, despite both being shared, resource-wide
                    -- maintenance coroutines. An uncaught
                    -- error here would kill this thread PERMANENTLY (Lua
                    -- coroutines/threads do not resume after an unhandled
                    -- error), silently disabling expiry enforcement — the "no
                    -- unbounded trap" guarantee itself — for every future hold/
                    -- takedown/drag for the rest of the resource's uptime, and
                    -- would wedge whatever ActiveHolds/K9ActiveEffect entries
                    -- existed at that moment into a permanent already_held/
                    -- already_engaged lockout with nothing left running to ever
                    -- clear them. Mirrored here, not left asymmetric.
                    local ok, err = pcall(EndHold, targetNetId, 'timeout')
                    if not ok then
                        print(('[qbx_k9unit] combat EndHold(timeout) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                    end
                elseif not ResolveNetworkEntity(targetNetId, 1) then
                    -- RED-TEAM FINDING (PropDragging), generalized to every
                    -- effectType: DragExceedsMaxDistance below (this thread)
                    -- and SampleCompliance (its own, separate compliance-
                    -- sampling thread) both used to bail out silently the
                    -- moment their own internal ResolveNetworkEntity(targetNetId, 1)
                    -- call returned nil, on the stated assumption that "the
                    -- maintenance loop's own expiry/disconnect cleanup handles
                    -- teardown" — but the ONLY disconnect cleanup that exists
                    -- (the playerDropped handler below) fires on a full
                    -- disconnect, never on ped destruction/recreation without
                    -- one. If a held/dragged player's ped is destroyed and
                    -- replaced with a new network id without disconnecting
                    -- (e.g. some ambulance/revive flows), the OLD targetNetId
                    -- becomes permanently unresolvable, silently skipped by
                    -- both checks forever — leaving nothing but the hard
                    -- `hold.expiresAt` timeout above to ever clear it, up to
                    -- Config.Combat.BiteAndHold.maxDurationMs/
                    -- Config.Combat.PropDragging.maxDragDurationMs later. This
                    -- check catches that gap directly, for every effectType at
                    -- once (bite/takedown/drag, player or NPC target alike) —
                    -- a target that has become permanently unresolvable is
                    -- ended immediately rather than left to the hard timeout,
                    -- the same class of fix as this file's own
                    -- reportBiteHoldTargetDied handler above (a target that
                    -- "went away without disconnecting"), applied generically
                    -- here instead of only for the client-reported-death case.
                    -- Server-side ResolveNetworkEntity reflects real global
                    -- entity existence (not "streamed to a particular client"),
                    -- so a nil result for an ALREADY-successfully-resolved
                    -- hold's target is a strong, not a transient, signal.
                    local ok, err = pcall(EndHold, targetNetId, 'target_unresolvable')
                    if not ok then
                        print(('[qbx_k9unit] combat EndHold(target_unresolvable) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                    end
                elseif hold.effectType == 'drag' and DragExceedsMaxDistance(hold, targetNetId) then
                    local ok, err = pcall(EndHold, targetNetId, 'max_distance_exceeded')
                    if not ok then
                        print(('[qbx_k9unit] combat EndHold(max_distance_exceeded) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                    end
                end
            end
        end
    end)
end

-- Shared COMPLIANCE-SAMPLING thread — job (b) from this file's header,
-- deliberately a SEPARATE thread from the expiry thread above rather than
-- a branch sharing its tick, on its own Config.Combat.NonComplianceDetection.
-- positionSampleWindowMs interval (this field's own doc comment in
-- config.lua already called it "the shared sampling thread", i.e. its own
-- thread, distinct from expiry — this wires that up for real). Sampling is
-- non-punitive and log-only (see FlagNonCompliance/this file's header), so
-- decoupling its cadence from the hard expiry/max-distance safety valves
-- above is safe: nothing here ever ends a hold or mutates authoritative
-- state, it only ever writes to a hold's own `compliance` sub-record.
-- Started only when NonComplianceDetection.enabled — Config is read once
-- at resource start and never mutated at runtime, so gating thread
-- creation itself (rather than looping forever just to no-op every tick)
-- costs nothing.
if Config.Combat.NonComplianceDetection.enabled then
    CreateThread(function()
        while true do
            Wait(Config.Combat.NonComplianceDetection.positionSampleWindowMs)
            local now = GetGameTimer()

            for targetNetId, hold in pairs(ActiveHolds) do
                -- pcall-wrapped for the same reason as every other call
                -- site in this shared coroutine's siblings: an error
                -- sampling ONE hold must never stop sampling for every
                -- OTHER active hold on this same tick, nor kill this
                -- thread permanently for the rest of the resource's
                -- uptime (Lua coroutines do not resume after an
                -- unhandled error).
                local ok, err = pcall(SampleCompliance, targetNetId, hold, now)
                if not ok then
                    print(('[qbx_k9unit] combat compliance sampling errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            end
        end
    end)
end

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
        -- NPC target — RESTRUCTURED, native-api-assistant verification
        -- pass (this session): see this file's header "NPC-TARGET NATIVE
        -- EXECUTION CONTEXT" note. PHASE3_SPEC.md §12.5.1's own prose calls
        -- this "no relay problem" on the theory the server can just call
        -- these natives directly — that theory did not survive
        -- verification (SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes'
        -- SERVER-side validity could not be confirmed either way this
        -- session; the sibling SetEntityCanBeDamaged call in
        -- HandleTakedownRequest below WAS independently confirmed
        -- CLIENT-ONLY). Relayed to the REQUESTING K9's OWN client instead
        -- — that client is already this resource's trusted actor for this
        -- action (server has already independently verified
        -- access/proximity/cooldowns above; only the mechanical
        -- "make the NPC stop fleeing/reacting" step moves client-side),
        -- and is unambiguously a valid execution context for both natives
        -- regardless of their unresolved server-side status.
        TriggerClientEvent('qbx_k9unit:client:applyNpcBiteHold', src, targetNetId, expiresAt)
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

--- QA-fix completion: client/combat.lua's bite-hold TARGET death-detection
--- thread reports its own death here so the HOLDER's side gets freed
--- properly. Without this, the holder's MyEngagedTargetNetId/
--- IsBiteHoldEngaged() state (client/combat.lua) only ever clears on a
--- 'qbx_k9unit:client:biteHoldEnded' relay, which EndHold below only ever
--- sends when THIS file ends the hold — until now, nothing did that for a
--- target who died mid-hold, so the holder stayed stuck on the
--- already_engaged lockout for up to Config.Combat.BiteAndHold.maxDurationMs
--- (15s default). client/combat.lua's own death-detection thread already
--- clears the TARGET's own local restriction on death; this closes the
--- remaining HOLDER-side half of that same finding.
---
--- TRUST BOUNDARY, not a convenience event: `source` here is the CLAIMED
--- TARGET reporting its own death, and a modified client could fire this
--- unprompted at any time. Two independent checks gate it, not one:
---   1. `source` must currently be the (player) TARGET of an active 'bite'
---      hold — reverse-scans ActiveHolds by hold.targetSrc rather than
---      trusting a client-supplied targetNetId, the same "never trust a
---      client-claimed id, only ever act on server-held state" posture
---      every other handler in this file already applies. A source that
---      isn't genuinely the target of anything is a silent no-op.
---   2. The claim itself ("I died") is independently RE-VERIFIED against
---      this player's own live server-side ped via IsEntityDead — a
---      DELIBERATE choice to verify, not the "can't verify, so don't
---      pretend to" call this codebase makes elsewhere for tracking's
---      forged-trail risk: unlike that case, IsEntityDead(targetPed) is
---      not a new or unverified native here — it is the SAME native
---      ValidateCombatRequest above already calls, server-side, on the
---      same kind of ped, for the identical "requireAlive" fact, so a
---      real, already-trusted verification mechanism exists and costs
---      nothing extra to use here too. A stale/false claim (target not
---      actually reported dead server-side) is rejected, not honored.
--- Even a successful lie has a low ceiling regardless: the worst outcome of
--- a false report is ending a hold `source` is already the target of —
--- something that player could otherwise only end by genuinely dying or
--- waiting out the timer, not a capability escalation against anyone else.
RegisterNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', function()
    local src = source

    local targetNetId = nil
    for netId, hold in pairs(ActiveHolds) do
        if hold.effectType == 'bite' and hold.isPlayerTarget and hold.targetSrc == src then
            targetNetId = netId
            break
        end
    end
    if not targetNetId then return end -- src is not the target of any active bite hold -- ignore

    local targetPed = GetPlayerPed(src)
    if targetPed == 0 or not IsEntityDead(targetPed) then
        return -- claim does not match this player's own live server-side state -- ignore, never trust the claim alone
    end

    EndHold(targetNetId, 'target_died')
end)

--[[ ================= NON-LETHAL TAKEDOWN ================= ]]

--- Core takedown logic, wrapped in pcall by the event handler below
--- (mirrors server/search.lua's HandleSearchTarget/searchTarget split) so
--- an unexpected runtime error can never leave TakedownMutex held or
--- K9ActiveEffect/ActiveHolds in an inconsistent state.
--- @param src number
--- @param targetNetId any
local function HandleTakedownRequest(src, targetNetId)
    -- k9Ped/isPlayerTarget/targetSrc from THIS pre-yield call are
    -- deliberately discarded (`_`), same "unused-by-design, not
    -- unfinished" pattern already established at server/main.lua:701
    -- (`local ok, _, _, reason = CheckLeashEligibility(...)`) — everything
    -- except targetPed (needed for basePos below) and reason (needed for
    -- the early-return message) is RE-DERIVED from scratch by the second
    -- ValidateCombatRequest call after the yield below ("RE-VALIDATE
    -- EVERYTHING after the yield" — see that call site's own comment), so
    -- carrying the pre-yield k9Ped/isPlayerTarget/targetSrc forward would
    -- only invite an accidental use of a value that may already be stale by
    -- the time this function's second half runs.
    local ok, _, targetPed, _, _, reason =
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
    -- k9Ped2 (the second, post-yield k9Ped) is deliberately discarded (`_`)
    -- this pass: it was previously only used to compute a k9NetId for the
    -- now-removed dead `ActiveHolds.holderNetId` field (QA-flagged this
    -- session, see this file's own header/report — server/combat.lua never
    -- read that field back; every relay payload that needs a K9 reference
    -- uses a LOCAL k9NetId computed at its own call site instead, and
    -- forceRagdoll/applyNpcTakedown need no K9 reference at all). Same
    -- "unused-by-design, not unfinished" pattern already established at
    -- this file's own pre-yield call above (`local ok, _, targetPed, _, _,
    -- reason = ValidateCombatRequest(...)`).
    local ok2, _, targetPed2, isPlayerTarget2, targetSrc2, reason2 =
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

    ActiveHolds[targetNetId] = {
        effectType     = 'takedown',
        holderSrc      = src,
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
        -- NPC target — RESTRUCTURED, native-api-assistant verification
        -- pass (this session), REAL BUG FIX not just a lint workaround: see
        -- this file's header "NPC-TARGET NATIVE EXECUTION CONTEXT" note for
        -- the full finding. SetEntityCanBeDamaged was CONFIRMED CLIENT-ONLY
        -- (0x1760FFA8AB074D66, ENTITY namespace, no apiset entry — FXServer
        -- never receives this native at all), which means the previous
        -- server-side call here was a silent no-op: the damage-bracket that
        -- is supposed to make this takedown non-lethal never actually
        -- applied to a server-spawned NPC target. The health floor below is
        -- NOT a sufficient substitute on its own — it is a REACTIVE
        -- top-up (fires only once, only if health has already dropped
        -- below the floor at the instant this line runs), not a continuous
        -- damage block, so it cannot honestly cover sustained damage from
        -- another source during the multi-second ragdoll window (e.g. a
        -- different player still shooting the downed NPC). Fixed by
        -- relaying BOTH the damage-bracket and the ragdoll to the
        -- REQUESTING K9's own client — SetPedToRagdollWithFall's
        -- server-side validity also could not be confirmed either way this
        -- session, so this sidesteps that open question entirely rather
        -- than resolve it by assertion, the same way the bite-hold NPC
        -- branch above does.
        if GetEntityHealth(targetPed2) < Config.Combat.NonLethalTakedown.healthFloor then
            -- Kept as a real, independently server-callable backstop
            -- (GetEntityHealth/SetEntityHealth's server-side validity is
            -- not in question — see .luacheckrc's own SetEntityHealth
            -- comment) even though the K9's client now also applies the
            -- damage bracket below — defense in depth costs nothing here.
            SetEntityHealth(targetPed2, Config.Combat.NonLethalTakedown.healthFloor)
        end

        TriggerClientEvent('qbx_k9unit:client:applyNpcTakedown', src, targetNetId, expiresAt)
    end

    -- Config.XP.awards.takedownSuccess (config.lua) — QA-flagged as dead
    -- code (configured, never granted) until this pass. Unlike BiteAndHold,
    -- no anti-farm floor is needed here: reaching this line already means
    -- the server-computed speed gate (genuinely fleeing, never a
    -- client-claimed flag), both cooldowns (per-K9 AND per-target), and the
    -- full ValidateCombatRequest re-check all passed — there is no
    -- "immediate release" farm vector to guard against since takedown has
    -- no manual release action at all (single atomic action, not a
    -- hold-then-release lifecycle). Runtime existence guard, same
    -- convention as server/tracking.lua's own trackSourceResolved call
    -- site — no load-order assumption on server/progression.lua.
    if type(AwardXP) == 'function' then
        local holderPlayer = exports.qbx_core:GetPlayer(src)
        local holderCitizenid = holderPlayer and holderPlayer.PlayerData and holderPlayer.PlayerData.citizenid
        if holderCitizenid then
            AwardXP(holderCitizenid, 'takedownSuccess')
        end
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

--[[ ================= PROP DRAGGING ================= ]]
--[[
    PHASE3_SPEC.md §12.5.4 / §12.0 items 1, 4, 5, 6, 8 (coder-architect,
    this pass). Reuses ActiveHolds/K9ActiveEffect/EndHold/FlagNonCompliance/
    the shared maintenance thread above wholesale (effectType = 'drag') —
    see this file's own header for why (avoids exactly the kind of
    unforced duplicate-table/duplicate-lifecycle problem PHASE3_SPEC.md
    §12.0 item 8 itself warns against for this class of state).

    CATEGORY A/B SPLIT FOR THIS MECHANIC, restated concretely against the
    code below (PHASE3_SPEC.md §12.0 item 8's own framing): the attach
    (AttachEntityToEntity, entirely client/combat.lua's responsibility —
    THIS file only ever grants/denies the request and tracks state, it
    never calls that native itself) is Category A and comparatively robust
    -- but ONLY under the "re-asserted every tick, never one-shot"
    discipline binding guardrail 2 requires, because DetachEntity is very
    likely NOT ownership-gated either (§12.0 item 8's own citation of
    citizenfx/fivem issue #3726) -- a hostile target's own client can call
    DetachEntity on itself at any moment, and the ONLY thing that puts the
    attach back is the K9's client calling AttachEntityToEntity again on
    its very next frame. THIS FILE'S OWN CONTRIBUTION to that guarantee is
    narrow and honest: it never assumes the attach "is holding" for any
    server-authoritative purpose (guardrail 3), and DragExceedsMaxDistance
    above / the drag_gap compliance signal above are BOTH blind to *why* the
    gap grew (self-detach, a bypassed move-rate override, or the K9 client
    simply failing to keep re-asserting) — by design, per item 8's own
    "regardless of cause" framing, since this file has no way to observe
    client-side attach state directly anyway. The speed-limit half is
    Category B in full, same posture as bite/takedown's own restrictive
    effects.

    "IS THIS TARGET DOWNED" — see IsTargetDowned (above, near
    IsPlayerWantedEligible) for the full two-branch contract (native-only
    for an NPC, override-or-metadata-guess for a player, PHASE3_SPEC.md
    §12.0 item 6). Called as an explicit SEPARATE step after
    ValidateCombatRequest({requireAlive = false}) succeeds — see that
    function's own updated header for why this could not simply reuse its
    built-in IsEntityDead check.

    NO XP AWARD for PropDragging in this pass — PHASE3_SPEC.md §12.2's own
    config sketch names no `Config.XP.awards.*` key for dragging (unlike
    biteHoldSuccess/takedownSuccess), so none is invented here; this is a
    disclosed omission, not an oversight, and a config-validator/product
    pass can add one later the same way biteHoldSuccess/takedownSuccess
    were wired up if a reward is wanted.
]]

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestDrag', function(targetNetId)
    local src = source

    -- requireAlive = false: PropDragging's ENTIRE premise is a DOWNED
    -- target -- ValidateCombatRequest's own IsEntityDead rejection exists
    -- to protect BiteAndHold/NonLethalTakedown from a target that is
    -- ALREADY dead/dying, the opposite of what this mechanic wants. The
    -- REAL "is this specific target downed" check is IsTargetDowned below,
    -- run only after every other shared precondition (access, proximity,
    -- already_held, wellbeing, RequireWantedStatus) has independently
    -- passed.
    -- k9Ped is deliberately discarded (`_`): dragStarted's payload carries
    -- no K9 netId (the K9's own client already knows its own PlayerPedId()
    -- locally for the attach), same "unused-by-design" pattern as
    -- HandleTakedownRequest's own discarded k9Ped2 above.
    local ok, _, targetPed, isPlayerTarget, targetSrc, reason =
        ValidateCombatRequest(src, targetNetId, Config.Features.PropDragging, Config.Combat.PropDragging.range, { requireAlive = false })
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason), 'error')
        return
    end

    if not IsTargetDowned(targetPed, isPlayerTarget, targetSrc) then
        NotifyPlayer(src, CombatRejectMessage('target_not_downed'), 'error')
        return
    end

    local now = GetGameTimer()
    -- maxDragDurationMs: a defensive hard-duration backstop ADDED beyond
    -- PHASE3_SPEC.md §12.2's literal sketch (which names only
    -- maxDragDistance as this mechanic's "no unbounded trap" cap, §12.0
    -- item 4) — see config.lua's own comment on this field (once added —
    -- this value is REQUESTED, not yet landed, see this pass's own report)
    -- for the full disclosed reasoning. Reuses the SAME `hold.expiresAt` /
    -- maintenance-thread-timeout mechanism bite/takedown already use, no
    -- new enforcement path.
    local expiresAt = now + Config.Combat.PropDragging.maxDragDurationMs

    ActiveHolds[targetNetId] = {
        effectType     = 'drag',
        holderSrc      = src,
        isPlayerTarget = isPlayerTarget,
        targetSrc      = targetSrc,
        startedAt      = now,
        expiresAt      = expiresAt,
        compliance = {
            -- lastPos/lastTime are stamped for parity with bite/takedown's
            -- own compliance records (SampleCompliance's shared tail always
            -- writes them) but are NOT read by the 'drag' branch itself —
            -- that branch compares LIVE positions each sample, it has no
            -- use for a historical baseline/rate the way bite/takedown do.
            lastPos  = GetEntityCoords(targetPed),
            lastTime = now,
            flagged  = false,
        },
    }
    K9ActiveEffect[src] = targetNetId

    -- Category A: tells the HOLDING K9's own client to start its per-tick
    -- AttachEntityToEntity re-assertion loop (client/combat.lua). isPlayerTarget
    -- is included so that SAME client also knows whether to ALSO drive the
    -- NPC's own move-rate directly (no relay needed for an NPC) or leave
    -- the speed-limit half to the target's own client (Category B, below).
    TriggerClientEvent('qbx_k9unit:client:dragStarted', src, targetNetId, isPlayerTarget, expiresAt)

    if isPlayerTarget then
        -- Category B relay -- PHASE3_SPEC.md §12.0 item 8.
        TriggerClientEvent('qbx_k9unit:client:applyDragSpeedLimit', targetSrc, expiresAt)
    end
    -- NPC target: no separate relay event needed -- dragStarted above
    -- already told the K9's own client isPlayerTarget = false, which is
    -- all that client needs to also drive SetPedMoveRateOverride on the
    -- NPC directly, every tick, alongside the attach re-assertion.

    -- BEST-EFFORT WORDING (guardrail 4) -- never claims the target cannot
    -- escape, mirrors requestBiteHold/HandleTakedownRequest's own copy.
    NotifyPlayer(src, 'Attempting to drag the target — this is not guaranteed against an uncooperative target.', 'inform')
end)

RegisterNetEvent('qbx_k9unit:server:releaseDrag', function()
    local src = source

    -- Either the HOLDING K9 or, when the target is a player, the TARGET
    -- itself may release at will -- PHASE3_SPEC.md §12.5.4 / §12.0 item 4:
    -- mirrors leash's own "no consent needed to get free" rule, and is
    -- STRONGER than bite/takedown's own target (who has no self-release
    -- action at all -- apprehension by design, not a cooperative
    -- mechanic). Checks the holder side first (cheap O(1) lookup via
    -- K9ActiveEffect) before falling back to the O(n) target-side scan.
    local targetNetId = K9ActiveEffect[src]
    if targetNetId then
        local hold = ActiveHolds[targetNetId]
        if hold and hold.effectType == 'drag' and hold.holderSrc == src then
            EndHold(targetNetId, 'released_by_holder')
            return
        end
    end

    for netId, hold in pairs(ActiveHolds) do
        if hold.effectType == 'drag' and hold.isPlayerTarget and hold.targetSrc == src then
            EndHold(netId, 'released_by_target')
            return
        end
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
