--[[
    qbx_k9unit/server/combat.lua

    Phase 3 implementation (coder-security), DEVELOPER_REFERENCE.md §12.5.1
    (Bite-and-Hold) and §12.5.2 (Non-lethal takedown), built under §12.0
    item 8's ("the client-relay/non-cooperating-target-client architecture
    problem") own resolution and its five binding guardrails — this file
    IS that resolution's implementation, not a separate design pass.

    PHASE 3 ADDITION (this pass, coder-architect): also owns
    `PropDragging` (DEVELOPER_REFERENCE.md §12.5.4, §12.0 item 6's downed-check
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
    with DEVELOPER_REFERENCE.md §12.0 item 8's own text, not a substitute for it):

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
    EVENT/CALLBACK CONTRACT (client<->server, DEVELOPER_REFERENCE.md §12.5.1/
    §12.5.2/§12.0 item 8):

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:requestBiteHold' (targetNetId: number)
    - 'qbx_k9unit:server:releaseBiteHold' ()
    - 'qbx_k9unit:server:reportBiteHoldTargetDied' ()
      QA-fix completion (see this event's own handler doc comment for the
      full trust-boundary/verification writeup): sent by client/combat.lua's
      bite-hold TARGET death-detection thread, no arguments — `source` names
      the reporting (claimed-target) client. Re-verified against
      ActiveHolds/live server-side health (GetEntityHealth, see
      PED_DEAD_HEALTH_THRESHOLD below) before acting, never trusted alone.
    - 'qbx_k9unit:server:requestTakedown' (targetNetId: number)
    - 'qbx_k9unit:server:reportHolderDied' ()
      LIFECYCLE QA FIX (this pass — see this event's own handler doc comment,
      near EndActiveEffectForHolder, for the full trust-boundary/
      verification writeup): mirrors reportBiteHoldTargetDied immediately
      above, for the HOLDING K9's own death instead of a target's. Sent by
      client/combat.lua's ActiveDragAsHolder/ActiveNpcEffects per-tick
      blocks, no arguments — `source` names the reporting (claimed-holder)
      client. Re-verified against K9ActiveEffect/live server-side health
      (GetEntityHealth, PED_DEAD_HEALTH_THRESHOLD below) before acting,
      never trusted alone — this is a FASTER-PATH optimization only; the
      shared maintenance thread's own HolderPedIsDead check (also this pass)
      is the always-on backstop that does not depend on this event ever
      arriving (a bite-hold/takedown on a PLAYER target has no client-side
      holder state to self-report from at all).

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

    PROP DRAGGING (coder-architect, this pass, DEVELOPER_REFERENCE.md §12.5.4) —
    NEW server events (client->server), THIS FILE:
    - 'qbx_k9unit:server:requestDrag' (targetNetId: number)
    - 'qbx_k9unit:server:releaseDrag' () — either the HOLDING K9 or, when
      the target is a player, the TARGET can send this; server resolves
      which side `source` is and ends the drag either way. Zero consent
      needed from the other side either direction — mirrors leash's own
      "no consent needed to get free" rule, DEVELOPER_REFERENCE.md §12.0 item 4/
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
      dragging, DEVELOPER_REFERENCE.md §12.0 item 8. Re-asserted by that client
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
      CONFIRMED CLIENT-ONLY. CORRECTION (later verification pass, folded in
      here rather than left in a separate note): this was originally
      justified as "no `apiset` entry in the primary source", but that test
      is invalid on its own — GetEntityCoords, definitely server-callable
      (this file calls it server-side directly), has byte-for-byte
      identical apiset-less frontmatter, so absence of the field doesn't
      distinguish the two. The client-only conclusion still holds, just on
      a different, valid basis: a docs.fivem.net search-index snippet
      quoting that native's own page badge verbatim, "this native is part
      of the 'client' API set" (MEDIUM-HIGH confidence — a search-index
      snippet of the real page, not a direct fetch, but a specific,
      unambiguous quote, not an inference). The original
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
    - SetEntityHealth (`ENTITY` namespace) — NEW FINDING, native-sweep
      follow-up pass, coder-backend: the health-floor backstop below
      (`if GetEntityHealth(targetPed2) < healthFloor then
      SetEntityHealth(targetPed2, healthFloor) end`) was, until this pass,
      the ONE remaining native in this exact NPC branch still called
      directly server-side, on the strength of a claim (this file's own
      prior comment, and .luacheckrc's) that "GetEntityHealth/SetEntityHealth's
      server-side validity is not in question." That claim did not survive
      the SAME verification method already applied to
      IsEntityDead/IsPedDeadOrDying elsewhere in this file (see
      PED_DEAD_HEALTH_THRESHOLD's own doc comment): `ext/native-decls` has
      NO doc page for SetEntityHealth at all (unlike GetEntityHealth/
      GetEntityMaxHealth, both of which have one with `apiset: server`),
      and a full-text search of every native-registering file in
      citizen-server-impl/src/state (the exact component that registers
      GET_ENTITY_HEALTH/GET_ENTITY_MAX_HEALTH via `makeEntityFunction` +
      `syncTree->GetPedHealth()/GetVehicleHealth()` reads) contains ZERO
      occurrence of `SET_ENTITY_HEALTH`/`SET_PED_HEALTH`, or of the
      substring `HEALTH` in any context other than a `GET_*` native.
      Architecturally consistent with that absence, not just coincidental:
      every health value this server reads comes from a sync-tree node
      populated by the entity's OWNING CLIENT and ACKed to the server — the
      server has a read path for that data but, unlike a getter, a "set"
      would require injecting a value into a client-owned sync node from
      the server side, a fundamentally different capability the getters'
      own implementation gives no evidence of existing. GRADED THE SAME AS
      SetEntityCanBeDamaged above: no confirmed server registration, so
      this call is a SUSPECTED silent no-op — the health-floor top-up for
      an already-low-health NPC target never actually applied. Fixed the
      same way as the other three: moved to the REQUESTING K9's OWN client,
      alongside the damage-bracket/ragdoll relay immediately below it in
      HandleTakedownRequest — no new payload field needed on
      `applyNpcTakedown` since `Config.Combat.NonLethalTakedown.healthFloor`
      is already a `shared_scripts`-loaded config value client/combat.lua
      can read directly. THIS FILE'S OWN HALF of that fix (stop calling the
      suspect native server-side) is complete below. STALE-COMMENT FIX
      (this pass, cross-change regression review — re-verified against the
      actual current client/combat.lua before rewriting this paragraph, not
      taken on the report alone): the CLIENT half has SINCE LANDED —
      client/combat.lua's `applyNpcTakedown` handler now calls
      `SetEntityHealth(npcPed, Config.Combat.NonLethalTakedown.healthFloor)`,
      guarded the same `< healthFloor` way, ordered between the
      damage-bracket and the ragdoll task, exactly matching what this
      paragraph originally asked for. This comment used to say that call
      was "OUT OF SCOPE for this file... until that lands, [the gap] widens
      slightly further" as though still pending — that framing is what went
      stale, not the underlying fix. The one-time top-up is therefore no
      longer unapplied; the damage-bracket/ragdoll relay (both independently
      confirmed working, see above) remain the primary, continuous
      protection during the window regardless — the health-floor call was
      always disclosed as a one-time supplement on top of them, never a
      replacement for either.
    Rather than assert an unresolved server-side legitimacy for these
    natives just to keep one code shape, or leave one bug fixed and the
    rest standing on an unverified assumption, ALL FIVE are relayed to
    the REQUESTING K9's OWN client instead — unambiguously a valid
    execution context for all five regardless of their server-side status
    (their CLIENT-side validity was never in question; SetPedToRagdollWithFall
    is already independently confirmed client-callable by this same file's
    own player-target relay, applied via client/combat.lua's forceRagdoll
    handler, and SetEntityHealth is already independently confirmed
    client-callable by server/medkit.lua's own applyMedkitHeal relay,
    the identical "server decides the number, the entity's own client
    writes it" pattern). This is not a weakening of server authority: the
    server has already independently completed every real check (feature
    flag, HasK9Access, live proximity, cooldowns, the speed gate for
    takedown) BEFORE ever sending one of these five relay events — only the
    MECHANICAL "make the NPC do X" step moves client-side, to the one actor
    already fully trusted for this action, mirroring the exact posture this
    file already uses for a PLAYER target (relay to the target's own
    client) just relayed to the K9 instead, since an NPC has no "own
    client" to relay to. See client/combat.lua's own header for the
    receiving-side implementation.
    ======================================================================

    No anim-dictionary/TASK_PLAY_ANIM asset is used for BiteAndHold in this
    pass — phase2_notes/DEVELOPER_REFERENCE.md#phase-3-combat's own §1 write-up flags
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
      DEVELOPER_REFERENCE.md item 2b — see the PLAYER-VS-NPC RESOLUTION
      section below) — does not re-implement any of the three.
    - Calls NewCooldown()/NewMutex() (server/cooldowns.lua) — every
      cooldown/in-flight-guard below is one of these constructors, never a
      hand-rolled table, per DEVELOPER_REFERENCE.md item 1's own standing
      convention for this resource. The four cooldowns constructed straight
      from a Config.Combat.*.cooldownMs/targetCooldownMs field are each
      first passed through ResolveConfiguredThresholdMs (also
      server/cooldowns.lua) — see that call's own comment block and
      cooldowns.lua's header ADDENDUM for why a raw Config read must never
      reach NewCooldown's constructor unguarded in this file specifically.
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

    PLAYER-VS-NPC RESOLUTION — DELIBERATE DEVIATION FROM DEVELOPER_REFERENCE.md'S
    OWN INFORMAL PROSE, flagged explicitly rather than silently diverging:
    §12.5.1/§12.5.2/§12.0 item 8's prose names `IsPedAPlayer(targetPed)` as
    the resolution mechanism. This file instead reuses
    `ResolveConnectedPlayerFromPed(entity)` — the SAME pattern
    server/search.lua's own security-reviewed
    `DEVELOPER_REFERENCE.md#contraband-search`-driven implementation already
    uses for the identical fact ("does this entity belong to a real,
    currently-connected player?"), for the SAME reason that file's own
    header gives: `IsPedAPlayer`/`NetworkGetPlayerIndexFromPed` combos were
    never independently confirmed reliable SERVER-side in this codebase's
    own native-verification passes (phase2_notes/DEVELOPER_REFERENCE.md#phase-3-combat
    does not list `IS_PED_A_PLAYER` in its confirmed-natives table for
    either feature at all), whereas the `GetPlayers()`/`GetPlayerPed(id)`
    scan is already proven reliable server-side elsewhere in this exact
    codebase. This is a strictly more conservative choice (it can only
    ever resolve to an entity that IS some connected player's own ped) and
    gets both facts (is-a-player, AND that player's own server id) from
    one already-trusted mechanism instead of two natives of differing
    verified reliability.

    EXTRACTION UPDATE (DEVELOPER_REFERENCE.md item 2b): this file's own copy
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

    NON-COMPLIANCE DETECTION (DEVELOPER_REFERENCE.md §12.0 item 8, point 2) — real,
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
          DEVELOPER_REFERENCE.md §12.0 item 8 specifies:
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
    per DEVELOPER_REFERENCE.md §2's "exports/events exposed so integration is possible, no
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
--     expiresAt    = number,           -- GetGameTimer() hard cap -- DEVELOPER_REFERENCE.md §12.0 item 4's "no unbounded trap" guarantee
--     compliance   = { ... },          -- see NON-COMPLIANCE DETECTION above; shape differs slightly per effectType, see the two sampling branches below
-- }
local ActiveHolds = {}

-- K9ActiveEffect[holderSrc] = targetNetId -- "one hold at a time per K9"
-- (DEVELOPER_REFERENCE.md §12.5.1: "One hold at a time per K9"), enforced across
-- BOTH BiteAndHold and NonLethalTakedown (a single K9 engaging one target
-- at a time, not one slot per effect type) -- also lets releaseBiteHold
-- resolve its own target without a linear scan of ActiveHolds.
local K9ActiveEffect = {}

-- ALL FOUR ResolveConfiguredThresholdMs CALLS BELOW (this pass, coder-backend
-- -- QA sandbox repro): these four constructors used to hand a raw
-- Config.Combat.*.cooldownMs value straight to NewCooldown. A single
-- non-positive one of them (e.g. an operator setting cooldownMs = 0 meaning
-- "no cooldown", this resource's own repeatedly-documented FOOTGUN) threw
-- inside NewCooldown's own AssertValidDefaultThreshold at THIS file's
-- top-level load time -- which does not just disable that one cooldown, it
-- aborts this entire file's execution from that line onward, silently
-- un-defining EndActiveEffectForHolder (near the bottom of this file, this
-- codebase's own termination primitive server/recall.lua and
-- server/training.lua both depend on) along with every
-- BiteAndHold/NonLethalTakedown/PropDragging RegisterNetEvent below it.
-- ResolveConfiguredThresholdMs (server/cooldowns.lua, see that file's header
-- ADDENDUM for the full incident) resolves each value to something always
-- valid BEFORE NewCooldown ever sees it -- printing one unmissable warning
-- naming the exact key/found value/substituted fallback instead of erroring
-- -- so a bad Config number degrades to "this one cooldown uses a safe
-- built-in value" rather than "this file, and everything depending on it,
-- stops existing." Fallback literals below match config.lua's own shipped
-- defaults for each field exactly.
local BiteHoldCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.BiteAndHold.cooldownMs, 20000, 'Config.Combat.BiteAndHold.cooldownMs'))
BiteHoldCooldown.RegisterPlayerDropped()

local TakedownCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.NonLethalTakedown.cooldownMs, 25000, 'Config.Combat.NonLethalTakedown.cooldownMs'))
TakedownCooldown.RegisterPlayerDropped()

-- Keyed by targetNetId, NOT a player source -- no per-connection cleanup
-- hook exists for this key domain (mirrors server/search.lua's
-- TargetSearchCooldown, keyed by a resolved plate/citizenid string for the
-- exact same reason). Swept periodically below rather than relying on
-- RegisterPlayerDropped.
local TakedownTargetCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.NonLethalTakedown.targetCooldownMs, 30000, 'Config.Combat.NonLethalTakedown.targetCooldownMs'))

-- XP-FARM FIX (this pass, coder-backend -- coordinator-flagged, independently
-- re-verified by re-reading requestBiteHold/HandleTakedownRequest side by
-- side, not taken on the report alone): BiteAndHold, UNLIKE NonLethalTakedown
-- immediately above, had ONLY a per-K9 cooldown (BiteHoldCooldown, keyed by
-- `src`) and no per-TARGET cooldown at all. `ActiveHolds[targetNetId]`
-- ('already_held' in ValidateCombatRequest) only blocks a DIFFERENT K9 from
-- concurrently holding the same target while a hold is active -- it does
-- NOT stop the SAME K9 from re-targeting the SAME already-released target
-- again the instant its own per-K9 cooldown clears. Against one fixed,
-- non-fleeing target (an NPC, or a wanted-but-stationary player), that meant
-- an unlimited "hold >= MIN_BITE_HOLD_XP_DURATION_MS, release, wait
-- BiteAndHold.cooldownMs, repeat" loop, each cycle minting
-- Config.XP.awards.biteHoldSuccess XP for a few seconds of standing still --
-- exactly the per-target throttle TakedownTargetCooldown already exists to
-- prevent for the sibling mechanic, just never applied here. Mirrors
-- TakedownTargetCooldown exactly: keyed by targetNetId (NOT a player
-- source -- an NPC target has none, and a player target's own cooldown must
-- outlive any one connection the same way TakedownTargetCooldown's already
-- does), swept periodically below rather than RegisterPlayerDropped.
-- Config.Combat.BiteAndHold.targetCooldownMs (config.lua) landed this pass
-- at the coordinator's request -- see that key's own comment in config.lua
-- for why it is set slightly above NonLethalTakedown's 30000 rather than
-- copied verbatim (a bite hold can pay out repeatedly inside its 15s
-- window; a takedown is one discrete event).
local BiteHoldTargetCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.BiteAndHold.targetCooldownMs, 35000, 'Config.Combat.BiteAndHold.targetCooldownMs'))

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

--- NATIVE-AVAILABILITY FIX (this pass, coder-backend, native-sweep
--- follow-up): `IsEntityDead`/`IsPedDeadOrDying` have NO server
--- implementation in FXServer at all -- confirmed against the primary
--- source, not just the 404 on their `ext/native-decls` doc pages. Traced
--- `citizenfx/fivem`'s own C++ native-registration list
--- (code/components/citizen-server-impl/src/state/ServerGameState_Scripting.cpp,
--- the exact file that implements every entity/ped-related native FXServer
--- DOES expose server-side): it contains zero `RegisterNativeHandler` call
--- for `IS_ENTITY_DEAD` or `IS_PED_DEAD_OR_DYING` anywhere -- while
--- `IS_PED_RAGDOLL` and `GET_ENTITY_HEALTH` (both already relied on
--- elsewhere in this file) ARE registered there. Confirmed a second way:
--- a full-repo source search for the literal registration strings
--- `"IS_ENTITY_DEAD"` / `"IS_PED_DEAD_OR_DYING"` returns zero matches
--- anywhere in the citizenfx/fivem monorepo. FXServer does not throw on an
--- unregistered native -- it silently no-ops and the result buffer is
--- never written, so every prior `IsEntityDead(...)`/`IsPedDeadOrDying(...)`
--- call in THIS file always returned `false`, forever, regardless of the
--- target's actual state. Every server-side call site below is rewritten
--- to use `GetEntityHealth`, which IS confirmed registered
--- (`GET_ENTITY_HEALTH` in that same file) and already used elsewhere here.
---
--- THRESHOLD, CHOSEN DELIBERATELY, NOT COPIED NAIVELY:
--- `GetEntityHealth(ped) <= 0` is NOT what the game engine means by "dead."
--- GTA peds are conventionally declared dead once health drops to (or
--- below) 100, not 0 -- the well-documented CPed convention behind why a
--- ped's default max health is 200 rather than 100: the bottom 100 points
--- are the "already dead" floor, not usable HP. Using `<= 0` here would
--- silently make this check an near-permanent no-op again (a ped's health
--- essentially never reaches literal 0 before the engine already considers
--- it dead at 100), reproducing the exact fail-open bug this pass exists to
--- fix while LOOKING fixed -- exactly the "subtler fail-closed [substitution
--- gone wrong]" trap flagged for this pass. `<= 100` is used instead:
---   1. It matches the actual engine death threshold `IsEntityDead`/
---      `IsPedDeadOrDying` were themselves querying, for both NPC and
---      player peds alike (this is an engine-wide ped mechanic, not a
---      scripted one).
---   2. It is INTERNALLY CORROBORATED by this exact file's own
---      `Config.Combat.NonLethalTakedown.healthFloor = 100` (config.lua) --
---      NonLethalTakedown's own health-floor backstop is already using 100
---      as "the line a target must stay above to not actually die," the
---      same convention from the other direction.
---   3. It does NOT falsely flag a genuine laststand/downed PLAYER as dead:
---      every laststand/EMS framework this codebase already reasons about
---      (see IsTargetDowned's player branch and config.lua's own comments
---      on IsPlayerDownedOverride/WantedStatusCheckOverride) deliberately
---      keeps a downed player's REAL ped health well above the engine's
---      death floor specifically so the engine itself never auto-kills
---      them -- so a laststand player's raw health legitimately stays
---      `> 100`, and this check correctly does not reject them as dead
---      here, matching the intended (and previously, accidentally,
---      achieved-via-no-op) behavior for that case. This is confirmed
---      server-side data (GetEntityHealth reads the live synced ped health
---      value, same field the client itself reads), never a client claim.
--- This is a targeted, minimal substitution -- it restores the ORIGINAL
--- intended behavior (reject an actually-dead ped) without narrowing it to
--- also reject a merely-downed/laststand one, which is exactly the failure
--- mode flagged for a naive `<= 0` (or worse, `== 0`) substitution.
local PED_DEAD_HEALTH_THRESHOLD = 100

local TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS = 60000
TakedownTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (Config.Combat.NonLethalTakedown.targetCooldownMs * 2)
end)

-- Same sweep shape, for the new BiteHoldTargetCooldown above (XP-farm fix,
-- this pass) -- keyed by targetNetId, no per-connection cleanup hook, so it
-- needs its own independent TTL sweep exactly like TakedownTargetCooldown's
-- does immediately above.
BiteHoldTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (Config.Combat.BiteAndHold.targetCooldownMs * 2)
end)

-- SEVENTH XP-FARM FIX (this pass, coder-security, economy-audit follow-up --
-- independently re-verified against ValidateCombatRequest and both AwardXP
-- call sites below before acting, not taken on the report alone): every
-- cooldown declared above (BiteHoldCooldown/TakedownCooldown per-K9,
-- BiteHoldTargetCooldown/TakedownTargetCooldown per-target) gates the
-- ACTION -- none of them gate the XP MINT itself, independent of how cheaply
-- the action can be repeated. That gap is exploitable on its own (switch
-- between two targets and each one's own per-target cooldown never binds,
-- leaving only the per-K9 cooldown standing), and is made trivially
-- reachable with zero risk/collusion by ValidateCombatRequest's own NPC
-- branch a few lines up (`isPlayerTarget and not
-- IsPlayerWantedEligible(targetSrc)` -- an NPC target never runs the
-- eligibility check at all): two ambient, non-hostile NPC pedestrians in
-- range are a fully qualifying farm pair. Measured ceilings, from this
-- file's own shipped config.lua numbers: biteHoldSuccess (20 XP @
-- BiteAndHold.cooldownMs=20000) = 3,600 XP/hr; takedownSuccess (30 XP @
-- NonLethalTakedown.cooldownMs=25000) = 4,320 XP/hr -- both against a fixed
-- target this resource never required to actually be fleeing, wanted, or
-- carrying any risk to pay out. This is the same shape server/tracking.lua's
-- TrackTicketMintCooldown and server/search.lua's ContrabandXpMintCooldown
-- already closed for trackSourceResolved/searchContrabandFound respectively
-- -- ported here verbatim rather than reinvented: a flat, per-HOLDER (never
-- per-target -- that dimension is exactly what BiteHoldTargetCooldown/
-- TakedownTargetCooldown above already cover, and exactly the dimension
-- switching targets already defeats), cross-target cooldown on the MINT,
-- CONSUMED only at the exact instant a real award is about to happen -- see
-- both AwardXP call sites below (EndHold's 'bite' branch, HandleTakedownRequest's
-- own award block) for the gate itself, deliberately the LAST condition
-- checked in both places, mirroring TrackTicketMintCooldown.Consume/
-- ContrabandXpMintCooldown.Consume's own "ordered after every other
-- would-never-have-paid-anyway check" placement, so a hold/takedown that
-- was never going to pay out regardless (wrong end reason, under the
-- duration floor, a failed speed gate, no citizenid resolved) never burns
-- this budget for nothing, and a denied mint never stamps any other
-- "already paid" state -- neither AwardXP call site below writes anything
-- to ActiveHolds/K9ActiveEffect/any other table on this path, so a denial
-- can only ever cost this ONE award, never anything permanent (unlike the
-- near-miss this exact ordering exists to prevent in ContrabandXpState's own
-- history: stamping a permanent "already accounted for" record BEFORE
-- confirming the mint actually succeeded would turn a rate limit into a
-- standing denial).
--
-- 60000ms for both (recommended, not derived from a formula) lands in the
-- SAME ORDER OF MAGNITUDE the two prior fixes already established
-- (TrackTicketMintCooldown: 30s @ 10 XP = 1,200 XP/hr; ContrabandXpMintCooldown:
-- 60s @ 25 XP = 1,500 XP/hr) rather than inventing a new economy tier for
-- this mechanic: biteHoldSuccess becomes 60s @ 20 XP = 1,200 XP/hr,
-- takedownSuccess becomes 60s @ 30 XP = 1,800 XP/hr.
--
-- FILE-LOCAL CONSTANTS, NOT CONFIG KEYS -- same call TrackTicketMintCooldown's
-- own declaration comment already made for the identical reasoning,
-- re-verified here rather than assumed to still hold: this is an ANTI-FARM
-- FLOOR, not an operator-tunable balance knob. Config.Combat.BiteAndHold.
-- cooldownMs/targetCooldownMs and Config.Combat.NonLethalTakedown.cooldownMs/
-- targetCooldownMs are already the legitimate, operator-facing dials for how
-- often this mechanic can be used; these two constants exist ONLY to close
-- the "switch targets to dodge the per-target gate" mint farm, a security
-- floor rather than a balance decision. Exposing this as a Config field
-- would reopen exactly the footgun server/cooldowns.lua's own
-- IsValidThreshold/AssertValidDefaultThreshold pass exists to catch for
-- OTHER thresholds but structurally cannot catch for this one: an
-- operator-set value that is merely TOO LOW (as opposed to non-positive,
-- which NewCooldown's fail-closed handling already protects against) still
-- reads as a perfectly valid positive threshold, passes every existing
-- assert/guard in this codebase without complaint, and silently reopens
-- this exact farm at whatever cadence was chosen -- there is no validation
-- this file or cooldowns.lua could add that would catch "500ms is a valid
-- but useless value here" the way it already catches "0 means permanently
-- blocked, not disabled". Keeping this a file-local constant means the only
-- way to weaken it is to edit this file's own source under code review, not
-- a config edit.
local BiteHoldXpMintCooldown = NewCooldown()
BiteHoldXpMintCooldown.RegisterPlayerDropped()
local BITE_HOLD_XP_MINT_COOLDOWN_MS = 60000

local TakedownXpMintCooldown = NewCooldown()
TakedownXpMintCooldown.RegisterPlayerDropped()
local TAKEDOWN_XP_MINT_COOLDOWN_MS = 60000

-- EIGHTH XP-FARM FIX, CROSS-FILE POINTER (this pass, red-team-flagged
-- compound-farm follow-up to the SEVENTH fix immediately above): the two
-- per-holder mint cooldowns declared above, server/search.lua's
-- ContrabandXpMintCooldown, and server/tracking.lua's TrackTicketMintCooldown
-- are each keyed by the SAME acting player but were never summed -- a
-- player round-robining all four mechanics was blocked by none of them
-- (1,200 + 1,800 + 1,500 + 1,200 = 5,700 XP/hr combined, uncapped, reaching
-- the 9,000-XP Elite tier in ~1h 35m -- BELOW config.lua's own "over 2
-- hours" retuning goal). CLOSED by server/progression.lua's new SHARED,
-- cross-mechanic XP mint budget (XP_MINT_BUDGET_CAP_XP/
-- XP_MINT_BUDGET_WINDOW_MS, consulted inside AwardXP itself) -- see that
-- file's own declaration comment for the full derivation. Nothing in THIS
-- file needed to change for that half of the fix: AwardXP is the single
-- chokepoint both of this file's award call sites already went through, so
-- the shared budget applies to them automatically. BiteHoldXpMintCooldown/
-- TakedownXpMintCooldown above are KEPT, unchanged -- they still shape
-- WHICH mechanic can mint and at what per-mechanic cadence; the shared
-- budget in server/progression.lua caps the TOTAL across mechanics. This
-- file's OWN half of the compound-farm fix is the NPC-eligibility gate at
-- both AwardXP call sites below (Config.XP.mintXpForNpcCombatTargets) --
-- see each call site's own comment.

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

-- ResolveConnectedPlayerFromPed(entity) used to be defined here as a local
-- function (duplicated from server/search.lua's own copy). Extracted to
-- server/entities.lua as a resource-global per DEVELOPER_REFERENCE.md item
-- 2b — see this file's header "PLAYER-VS-NPC RESOLUTION" section's
-- "EXTRACTION UPDATE" note for the full reasoning. ValidateCombatRequest
-- below now calls that shared global instead.

--- DEVELOPER_REFERENCE.md §12.0 item 5. Never trusts a client-supplied "I am
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
    -- PropDragging's equivalent default, per DEVELOPER_REFERENCE.md §12.0 item 5).
    local player = exports.qbx_core:GetPlayer(targetSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) ~= 'table' then return false end
    return metadata.wanted == true or metadata.iswanted == true
end

--- DEVELOPER_REFERENCE.md §12.0 item 6 / §12.5.4 — PropDragging's "is this target
--- actually downed" gate. NEVER reuses ValidateCombatRequest's own
--- dead-target check (that check exists specifically to REJECT a dead
--- target for BiteAndHold/NonLethalTakedown, the exact opposite of what
--- dragging wants) — called as a SEPARATE step, after
--- ValidateCombatRequest({requireAlive = false}) has already succeeded.
---
--- NPC branch: RESTRUCTURED (native-sweep follow-up pass, coder-backend) —
--- §12.5.4's original prose named `IsPedDeadOrDying(ped, true) OR
--- IsPedRagdoll(ped)`; the earlier version of this comment graded
--- IsPedDeadOrDying's server-side callability as "reasoned about by
--- analogy, not independently re-verified." That analogy has since been
--- independently checked against the primary source AND FOUND WRONG:
--- IsPedDeadOrDying, unlike GetEntityHealth/IsPedRagdoll, has NO FXServer
--- server implementation at all (traced citizenfx/fivem's own C++
--- native-registration list — see PED_DEAD_HEALTH_THRESHOLD's own doc
--- comment above for the full finding) and always silently returned
--- `false` here, degrading this OR into just `IsPedRagdoll` (a
--- dead-but-not-yet-ragdolled NPC was never recognised as downed). Now
--- `GetEntityHealth(ped) <= PED_DEAD_HEALTH_THRESHOLD OR IsPedRagdoll(ped)`
--- — both halves confirmed server-callable, and the NPC-only nature of
--- this branch means the player-branch laststand caveat below does not
--- apply (an NPC has no scripted laststand state to false-positive
--- against).
---
--- Player branch: NEVER the native checks above (§12.0 item 6 — raw
--- physics/AI state is a category mismatch for a server's own scripted
--- laststand state, with concrete false-positive/false-negative modes) —
--- override function first, FAILS CLOSED on error (same discipline as
--- IsPlayerWantedEligible above — a broken override must never silently
--- widen who can be dragged); else, if no override is configured, the
--- detected K9Compat ambulance adapter's `true`/`false` answer (COMPAT-
--- LAYER, this pass — see shared/compat/ambulance.lua's header for the
--- three-valued contract this step honours); else (adapter `nil`/
--- UNKNOWN, or nothing detected) the default best-effort
--- metadata.isdead/.inlaststand guess, exactly as before this pass.
--- @param targetPed number
--- @param isPlayerTarget boolean
--- @param targetSrc number?
--- @return boolean downed
local function IsTargetDowned(targetPed, isPlayerTarget, targetSrc)
    if not isPlayerTarget then
        -- NATIVE-AVAILABILITY FIX (see PED_DEAD_HEALTH_THRESHOLD's own doc
        -- comment above for the full finding): was `IsPedDeadOrDying(ped,
        -- true) or IsPedRagdoll(ped)`. `IsPedDeadOrDying` has no FXServer
        -- server implementation (confirmed against the same primary source
        -- as the ValidateCombatRequest fix above) and always returned
        -- false here, silently degrading this OR to just `IsPedRagdoll` --
        -- a dead-but-not-yet-ragdolled NPC was never recognised as downed
        -- (fails CLOSED: blocks a legitimate drag rather than allowing an
        -- illegitimate one, lower severity than the two fail-open sites,
        -- but still wrong). `IsPedRagdoll` is confirmed registered
        -- server-side and untouched below. The NPC-only nature of this
        -- branch means none of the player-branch laststand caveats above
        -- apply -- an NPC has no scripted laststand state, so a raw
        -- engine-death-floor health check is unambiguously the right
        -- signal here, not merely an approximation.
        return GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD or IsPedRagdoll(targetPed)
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

    -- COMPAT-LAYER (this pass): only reached when no override is
    -- configured -- consult the detected ambulance adapter (shared/compat/
    -- ambulance.lua) as a FALLBACK, never a replacement, for the
    -- best-effort metadata guess below, exactly the resolution order that
    -- file's own header PRECEDENCE section requires: override (already
    -- handled above) wins unconditionally; only if absent, the adapter's
    -- `true`/`false` are trusted directly (a real, positive signal from
    -- whichever ambulance resource this server actually runs); its `nil`
    -- (UNKNOWN -- nothing detected, the resource isn't started, or it
    -- genuinely has no answer yet for this src) falls through to the SAME
    -- metadata guess this file already used before this pass, unchanged.
    -- `K9Compat.Get` is NEVER nil and its methods never throw (shared/
    -- compat/core.lua's own BuildSafeAdapter/BuildNoOpStub contract) -- no
    -- extra pcall/type guard needed here, matching every other
    -- K9Compat.Get call site in this resource (server/search.lua,
    -- server/medkit.lua, server/inventory.lua, etc. all call it bare; a
    -- couple of call sites add a defensive `type(K9Compat) == 'table'`
    -- belt-and-suspenders check on top for other reasons -- see server/
    -- integrations.lua's/server/scentlineup.lua's own comments on THAT --
    -- but none of them add a pcall around the call itself, because none
    -- need one). This function's own boolean contract (no third "unknown"
    -- state) is exactly why `true`/`false` short-circuit here but `nil`
    -- does not -- see shared/compat/ambulance.lua's header for why
    -- flattening `nil` into either boolean at a call site would be wrong.
    local ambulanceDowned = K9Compat.Get('ambulance').IsDowned(targetSrc)
    if ambulanceDowned == true then return true end
    if ambulanceDowned == false then return false end

    -- Default best-effort check -- see config.lua's own comment on this
    -- field for the confidence note (HIGHER confidence than
    -- WantedStatusCheckOverride's equivalent default, per DEVELOPER_REFERENCE.md
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
    feature_disabled   = locale('combat.feature_disabled'),
    -- Byte-identical to certifications.lua's own `type(targetServerId) ~=
    -- 'number'` rejection ("Invalid target.") -- same generic "the supplied
    -- target id failed basic type validation" concept, confirmed by reading
    -- that file's GrantCertification/RevokeCertification call sites before
    -- reusing, not a coincidental short-string collision. Reused rather
    -- than minted as a new combat.invalid_target duplicate.
    invalid_target     = locale('certifications.invalid_target'),
    no_access          = locale('combat.no_access'),
    -- Byte-identical to client/defense.lua's own already_engaged rejection
    -- (confirmed by reading both texts before reusing) — reused rather than
    -- minted as a new combat.already_engaged duplicate.
    already_engaged    = locale('defense.already_engaged'),
    offline            = locale('combat.offline'),
    self_target        = locale('combat.self_target'),
    target_not_downed  = locale('combat.target_not_downed'),
    target_dead        = locale('combat.target_dead'),
    too_far            = locale('combat.too_far'),
    already_held       = locale('combat.already_held'),
    not_eligible_target = locale('combat.not_eligible_target'),
    not_fleeing        = locale('combat.not_fleeing'),
    on_cooldown        = locale('combat.on_cooldown'),
    -- server/wellbeing.lua-driven — these describe the REQUESTING K9's own
    -- state, never the target's (see this file's header FILE-TO-FILE
    -- CONTRACT entry for IsHesitating/IsDistracted).
    hesitating         = locale('combat.hesitating'),
    distracted         = locale('combat.distracted'),
    -- PER-PERSON FEATURE CONTROL denial (config.lua's Config.FeatureControl
    -- -- an explicit 'block.<Name>' row OR 'RequireGrant' listed without an
    -- active 'feature.<Name>' grant; see IsCombatFeaturePermittedForCitizenId
    -- below). Collapsed into the SAME generic copy either way, deliberately
    -- -- matches server/pursuitsprint.lua's own IsPursuitSprintPermittedForCitizenId
    -- call site: "the player-facing message is deliberately the same...
    -- a blocked handler does not need a message that reads differently from
    -- a never-granted one." Reuses the EXISTING combat.reject_fallback
    -- locale key rather than adding a new one -- this file may not edit
    -- locales/en.json this pass; an explicit mapping is kept here (rather
    -- than left to CombatRejectMessage's own fallback-on-miss) so a reader
    -- of this table sees the reason was deliberately handled, not merely
    -- unmapped.
    permission_denied  = locale('combat.reject_fallback'),
    -- CERTIFICATION TIER CAPABILITY denial (server/certtiers.lua's
    -- TierCapabilityPermits, wired into ValidateCombatRequest's
    -- BiteAndHold/NonLethalTakedown branch this pass -- see that call
    -- site's own comment for the full reasoning, including why this is
    -- kept a DISTINCT reason rather than collapsed into 'permission_denied'
    -- immediately above). The real key landed in locales/en.json on
    -- 2026-08-26 and this now uses it. Worth knowing why it was briefly
    -- mapped to reject_fallback instead: this table is a top-level literal
    -- evaluated at file-load time, and the test sandbox's locale() hard-
    -- asserts on a missing key -- so naming a key before it exists breaks
    -- every spec that loads this file, not just the ones exercising this
    -- reason. If you add another reason here, land its key first.
    tier_capability_denied = locale('combat.tier_capability_denied'),
}

--- @param reason string?
--- @return string
local function CombatRejectMessage(reason)
    return COMBAT_REJECT_MESSAGES[reason] or locale('combat.reject_fallback')
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- 4-step "first match wins" resolution, steps 2-4 (step 1 -- the feature's
-- own Config.Features.<Name> flag -- is already the `featureEnabled`
-- parameter ValidateCombatRequest below checks before this can ever run).
-- Mirrors server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId
-- byte-for-byte in SHAPE (read that function's own doc comment for the
-- full reasoning this does not repeat) -- generalised here to accept a
-- `featureKey` parameter since THIS file shares one validator across
-- THREE RequireGrant-listed features (BiteAndHold, NonLethalTakedown,
-- PropDragging) rather than pursuitsprint.lua's single hardcoded key. Kept
-- as this file's own tiny local copy rather than a shared export, matching
-- this resource's established "each file keeps its own tiny copy of a
-- genuinely small, self-contained check" convention (see e.g.
-- server/permissions.lua's IsDuplicateKeyError doc comment for the same
-- precedent named explicitly).
--
-- PRECEDENCE, PRESERVED EXACTLY per config.lua's own header: global off
-- (step 1, checked by the caller) beats everything; a block (step 2) beats
-- an active grant; RequireGrant (step 3) is checked ONLY once step 2 has
-- already passed; nothing here can ever WIDEN access -- both dynamic
-- lookups below (`RequireGrant[featureKey]`, `HasPermission`) fail CLOSED
-- on every unresolvable shape (missing Config.FeatureControl, missing
-- RequireGrant table, HasPermission entirely absent), matching
-- server/pursuitsprint.lua's identical fail-closed posture. NEVER called
-- for a termination/cleanup path (EndHold, releaseDrag, the maintenance
-- threads' own expiry sweep) -- only for the REQUEST that OPENS a new
-- effect -- so a mid-effect block/revoke can never strand an already-open
-- hold/drag; see EndHold's own header for why teardown is unconditional.
-- ======================================================================
--- @param citizenid string
--- @param featureKey string -- 'BiteAndHold' | 'NonLethalTakedown' | 'PropDragging' -- always a literal passed by this file's own call sites, never derived from anything client-supplied
--- @return boolean allowed
local function IsCombatFeaturePermittedForCitizenId(citizenid, featureKey)
    -- Soft dependency, this resource's established convention
    -- (`type(...) == 'function'`) -- server/permissions.lua may be absent
    -- from an install, or Config.Features.PermissionGrants may be off;
    -- HasPermission itself already returns false in either case. When it
    -- is entirely absent, step 2 (below) simply cannot fire -- nobody could
    -- ever hold a block -- and step 3 further down still fails CLOSED on a
    -- grant this resource is structurally unable to check.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.' .. featureKey) == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant[featureKey] == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.' .. featureKey) == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Shared request-time validation for BiteAndHold, NonLethalTakedown, AND
--- (this pass) PropDragging — DEVELOPER_REFERENCE.md §12.5.1/§12.5.2/§12.5.4's own
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
---   target — the dead-target rejection below (GetEntityHealth-based -- see PED_DEAD_HEALTH_THRESHOLD above) exists specifically to
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
--- @param featureKey string -- 'BiteAndHold' | 'NonLethalTakedown' | 'PropDragging' -- passed to IsCombatFeaturePermittedForCitizenId below for the PER-PERSON FEATURE CONTROL check (config.lua's Config.FeatureControl), a REQUIRED parameter (not folded into `opts`, unlike PropDragging's own `requireAlive` knob) because all three call sites need it identically -- there is no effect-agnostic default that would make sense to omit.
--- @param opts table?
--- @return boolean ok
--- @return number? k9Ped
--- @return number? targetPed
--- @return boolean? isPlayerTarget
--- @return number? targetSrc
--- @return string? reason
local function ValidateCombatRequest(src, targetNetId, featureEnabled, rangeMeters, featureKey, opts)
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

    -- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl, steps
    -- 2-4 of its documented "first match wins" resolution -- step 1,
    -- `featureEnabled`, is already checked above). Placed here, immediately
    -- after HasK9Access and before every other state read below, mirroring
    -- server/pursuitsprint.lua's requestPursuitSprint call-site placement of
    -- its own identically-shaped check exactly. See
    -- IsCombatFeaturePermittedForCitizenId's own doc comment for the full
    -- fail-closed/precedence contract this implements.
    do
        local k9Player = exports.qbx_core:GetPlayer(src)
        local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
        if not k9Citizenid or not IsCombatFeaturePermittedForCitizenId(k9Citizenid, featureKey) then
            return false, nil, nil, nil, nil, 'permission_denied'
        end
    end

    -- CERTIFICATION TIER CAPABILITY (this pass -- server/certtiers.lua's
    -- TierCapabilityPermits, wired here per that file's own "CAPABILITY
    -- COMPOSITION" header section, which names THIS exact call site as one
    -- of its two identified-but-not-yet-wired consumers). A FLOOR laid
    -- UNDERNEATH HasK9Access and the PER-PERSON FEATURE CONTROL block
    -- immediately above -- checked only AFTER both have already said
    -- "allowed", and only able to NARROW that population further, never
    -- widen it: see TierCapabilityPermits' own doc comment (and this
    -- resource's .luacheckrc entry for it) for the fail-PERMISSIVE
    -- contract this relies on (allow unless the capability is actively
    -- granted by >=1 tier AND this citizenid's own resolved tier is not
    -- among them; every unresolvable case -- no tier, no lookup function,
    -- bad arguments -- is an allow, never a deny).
    --
    -- BiteAndHold/NonLethalTakedown ONLY -- deliberately NOT PropDragging,
    -- which shares this same validator for an unrelated mechanic. Checked
    -- against CAPABILITY_CATALOG (server/certtiers.lua): the ONE capability
    -- key that exists for this validator's mechanics is
    -- 'bite_hold_and_takedown', whose own label names bite-and-hold and
    -- non-lethal takedown explicitly and nothing else -- dragging is a
    -- separately-gated feature (its own Config.Features.PropDragging flag,
    -- its own range/cooldown config, and a target precondition -- already
    -- downed -- that is the OPPOSITE of what BiteAndHold/NonLethalTakedown
    -- require) with no capability key of its own in that closed, code-owned
    -- catalog. Folding dragging into 'bite_hold_and_takedown' here would
    -- silently widen what an operator ticking that ONE checkbox on the
    -- tablet actually controls, past what its own label says -- not this
    -- pass's call to make. If a future pass wants dragging gated by tier
    -- too, that needs its own reviewed CAPABILITY_CATALOG entry in
    -- server/certtiers.lua, not a silent piggyback here.
    --
    -- 'tier_capability_denied' is a NEW, deliberately DISTINCT reason --
    -- not collapsed into 'permission_denied' (or 'no_access') above, even
    -- though this file's own sarcalls.lua/scenttrail.lua siblings establish
    -- a real "don't invent a distinction the server doesn't give data for"
    -- precedent elsewhere. That precedent does not apply here: it covers
    -- cases where two failure causes are genuinely INDISTINGUISHABLE in
    -- their consequence for the player (server/combat.lua's OWN
    -- 'permission_denied' above is exactly such a case -- "blocked" and
    -- "never granted" read identically to whoever is denied, per that
    -- entry's own comment). A tier-capability denial is a DIFFERENT fact:
    -- this handler already has real K9 access and no admin-set
    -- block/missing-grant against them -- reusing 'no_access' would be
    -- FACTUALLY WRONG (HasK9Access already passed), and collapsing into
    -- 'permission_denied' would misreport which of two different remedies
    -- applies (ask an admin for a feature grant, vs. ask high command to
    -- either promote this handler's tier or grant the tier the
    -- capability). Mirrors the sibling call site landed this same pass,
    -- server/certifications.lua's GrantSpecialization, which minted its own
    -- distinct 'certifications.specialization_requires_tier_capability' key
    -- rather than reusing 'specialization_requires_active_cert' for the
    -- identical reason.
    --
    -- LOCALE KEY, NOT YET LANDED: locales/en.json is off-limits to this
    -- file's own pass. Proposed key/wording sent to main directly:
    -- combat.tier_capability_denied = "Your certification tier does not
    -- permit bite-and-hold or non-lethal takedown." NOT mapped into
    -- COMBAT_REJECT_MESSAGES below yet, deliberately -- that table is a
    -- top-level literal evaluated at THIS FILE'S OWN LOAD TIME, so a
    -- locale() call there for a key that does not exist yet would hard-fail
    -- loading this file for every test that loads it, not just the ones
    -- exercising this one reason (confirmed against tests/fixtures/
    -- sandbox.lua's own locale() implementation, which asserts on a missing
    -- key rather than degrading). Until main lands that key,
    -- CombatRejectMessage('tier_capability_denied') falls through to its
    -- own existing generic fallback (locale('combat.reject_fallback'),
    -- "Unable to complete that action.") automatically -- not factually
    -- wrong, just less specific than intended; swap this comment's mapping
    -- into COMBAT_REJECT_MESSAGES once the real key exists.
    --
    -- REQUEST-TIME ONLY: this is ValidateCombatRequest, called only from
    -- requestBiteHold/requestTakedown's own opening checks -- never from
    -- EndHold, EndActiveEffectForHolder, the maintenance expiry sweep, or
    -- releaseBiteHold/releaseDrag. A handler whose tier loses this
    -- capability mid-hold must still be able to end that hold -- see this
    -- function's own doc comment and server/certtiers.lua's "NO UNBOUNDED
    -- TRAP" section for why a termination path may never gate on this.
    if featureKey == 'BiteAndHold' or featureKey == 'NonLethalTakedown' then
        local k9Player = exports.qbx_core:GetPlayer(src)
        local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
        local k9JobName = k9Player and k9Player.PlayerData and k9Player.PlayerData.job and k9Player.PlayerData.job.name
        if type(TierCapabilityPermits) == 'function' and k9Citizenid and k9JobName
            and not TierCapabilityPermits(k9Citizenid, k9JobName, 'bite_hold_and_takedown') then
            return false, nil, nil, nil, nil, 'tier_capability_denied'
        end
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
    --
    -- SECURITY, READ BEFORE CHANGING THIS BLOCK (coder-security, config-audit
    -- follow-up pass): this is a HARD reject driven by IsHesitating(), and
    -- IsHesitating() is driven by a payload-less, forgeable client event
    -- (server/wellbeing.lua's own header, 'relayWeaponFire') — CONFIRMED
    -- this pass to be forgeable by ANY connected player who is merely
    -- physically near the K9 whose hesitation they want to force, not just
    -- by that K9's own client or by a real combat participant. That was
    -- true, and disclosed, before this call site existed; it became a real
    -- targeted denial-of-capability (not a self-only nuisance) the moment
    -- this hard reject started consuming it, because a forged report here
    -- blocks THIS specific K9's bite-hold/takedown, not the forger's own.
    -- server/wellbeing.lua's TickWellbeing now caps how long any one
    -- hesitation episode can keep renewing (HESITATION_MAX_CONTINUOUS_MS)
    -- specifically so this reject can never become an indefinite lock —
    -- every episode is guaranteed to be followed by a window where this
    -- check passes again. That bound lives entirely in server/wellbeing.lua;
    -- this file does not need its own copy of that logic, only needs to
    -- keep trusting IsHesitating()'s return value at face value, same as
    -- today. If this reject is ever softened into a penalty instead of an
    -- outright denial, or IsHesitating() gains real corroboration, update
    -- server/wellbeing.lua's own IsHesitating doc comment in the same pass.
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

    -- NATIVE-AVAILABILITY FIX (see PED_DEAD_HEALTH_THRESHOLD's own doc
    -- comment above for the full finding/reasoning): was `IsEntityDead
    -- (targetPed)`, which has no FXServer implementation and always
    -- returned false server-side, silently never rejecting an
    -- already-dead target here.
    if opts.requireAlive ~= false and GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD then
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
            -- apply side (DEVELOPER_REFERENCE.md §12.0 item 8). If the target's
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
                -- SEVENTH XP-FARM FIX (this pass) -- see
                -- BiteHoldXpMintCooldown's own declaration comment above for
                -- the full writeup. Gates ONLY this AwardXP call, checked
                -- LAST (after the reason exclusion and the duration floor
                -- above), so a hold that was never going to pay out anyway
                -- never burns this per-holder mint budget for nothing.
                -- Everything else in this branch (both relay
                -- TriggerClientEvent calls above, ActiveHolds/K9ActiveEffect
                -- already having been cleared at the top of EndHold) is
                -- entirely unaffected by whether this Consume succeeds -- a
                -- K9 out of mint budget still gets its hold/release/relay
                -- exactly as before, it just is not paid for this one.
                --
                -- EIGHTH XP-FARM FIX, NPC-ELIGIBILITY HALF (this pass,
                -- red-team-flagged compounding factor -- server/progression.lua
                -- owns the OTHER half, the shared cross-mechanic budget):
                -- ValidateCombatRequest's NPC branch (this file, above) never
                -- calls IsPlayerWantedEligible at all -- Config.Combat.
                -- RequireWantedStatus's own comment already documents that
                -- field as NOT affecting NPC targets. An ambient, non-wanted,
                -- non-dangerous NPC pedestrian was therefore a fully
                -- qualifying biteHoldSuccess source requiring zero real
                -- police work. Config.XP.mintXpForNpcCombatTargets
                -- (config.lua; boolean; default false/unset) gates the MINT
                -- ONLY -- it does NOT gate whether NPC bite-hold itself is
                -- ALLOWED (Config.Features.BiteAndHold, unaffected; the
                -- owner's standing decision that K9 combat targets players
                -- AND NPCs is not re-litigated here). Checked FIRST in this
                -- `and` chain, before BiteHoldXpMintCooldown.Consume, for the
                -- same "never burn the mint budget on something that was
                -- never going to pay anyway" reasoning this comment already
                -- states for the duration floor above it -- a K9 that only
                -- ever engages ineligible NPCs must not find its OWN mint
                -- budget spent when a genuinely eligible target later comes
                -- along. `Config.XP and ...` guards a fixture/test sandbox
                -- that never sets up Config.XP at all; production's real
                -- config.lua always defines Config.XP, so this is a pure
                -- defensive no-op there. `nil == true` is false in Lua, so
                -- this already defaults to the recommended "off" behavior
                -- even before config.lua adds the key.
                if (hold.isPlayerTarget or (Config.XP and Config.XP.mintXpForNpcCombatTargets == true))
                    and type(AwardXP) == 'function'
                    and BiteHoldXpMintCooldown.Consume(hold.holderSrc, BITE_HOLD_XP_MINT_COOLDOWN_MS) then
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
            -- Takedown has no manual "release" action (DEVELOPER_REFERENCE.md
            -- §12.5.2 lists no release event) — only notify the K9 for a
            -- non-timeout reason (e.g. the target disconnecting mid-ragdoll);
            -- a plain timeout is the expected, silent end of a successful
            -- takedown.
            NotifyPlayer(hold.holderSrc, locale('combat.takedown_ended_early'), 'inform')
        end
    else -- 'drag' (DEVELOPER_REFERENCE.md §12.5.4, this pass)
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
            NotifyPlayer(hold.holderSrc, locale('combat.drag_ended'), 'inform')
        end
    end
end

--- Resource-global (no `local`) accessor exposed for OTHER files that need
--- to unconditionally end whatever engagement (bite/takedown/drag) a K9 is
--- CURRENTLY the HOLDER of, regardless of who is asking or that K9's own
--- current certification/access state. server/recall.lua's Recall actor
--- (DEVELOPER_REFERENCE.md §12.5.1, §12.0 item 7's "Recall actor" consumer) is this
--- function's one intended caller today -- resolved through the SAME
--- `type(...) == 'function'` runtime-existence-guard convention this file
--- already uses for IsHesitating/IsDistracted/AwardXP (see FILE-TO-FILE
--- CONTRACT above), never a load-order assumption, since server/recall.lua's
--- own position in fxmanifest.lua's server_scripts relative to THIS file is
--- not, and should not need to be, load-bearing.
---
--- DELIBERATELY NEVER CHECKS HasK9Access/Config.Features.* ITSELF -- this is
--- a TERMINATION path, and DEVELOPER_REFERENCE.md's own "no unbounded trap"
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

--- LIFECYCLE QA FIX (this pass) — closes the gap a lifecycle QA pass found:
--- when the K9 HOLDER dies mid-hold or mid-drag while remaining connected
--- (the DISCONNECT case is already handled correctly by playerDropped
--- below, via 'holder_disconnected'), nothing previously noticed. Before
--- this pass, the shared maintenance thread below checked hold.expiresAt,
--- target resolvability, and (for drags) DragExceedsMaxDistance — never the
--- HOLDER's own health — so a target stayed flee-suppressed/damage-immune/
--- move-rate-limited (or, for a drag, physically attached to a corpse)
--- until that hold's own hard timeout. Mirrors
--- 'qbx_k9unit:server:reportBiteHoldTargetDied' above EXACTLY, just for the
--- HOLDER's own death instead of a (player) TARGET's — client/combat.lua's
--- ActiveDragAsHolder/ActiveNpcEffects per-tick blocks self-report here the
--- instant THAT client observes its own ped has died. This report is a
--- FASTER-PATH optimization only, not the only closer of the gap — see
--- HolderPedIsDead's own doc comment (near DragExceedsMaxDistance above)
--- for the ALWAYS-ON backstop half that does not depend on this event ever
--- arriving at all (a bite-hold/takedown on a PLAYER target has no
--- client-side holder state to self-report from in the first place).
---
--- TRUST BOUNDARY, not a convenience event — same two-part discipline as
--- reportBiteHoldTargetDied above, mirrored exactly rather than
--- reinvented:
---   1. `source` must currently be the HOLDER of an active hold of ANY
---      effectType — resolved via K9ActiveEffect[src], the SAME O(1)
---      lookup releaseBiteHold/releaseDrag already use to resolve their own
---      caller's target, never a client-supplied targetNetId. A source that
---      is not genuinely the holder of anything is a silent no-op.
---   2. The claim itself ("I died") is independently RE-VERIFIED against
---      this player's own live server-side ped via the same
---      GetEntityHealth <= PED_DEAD_HEALTH_THRESHOLD check
---      reportBiteHoldTargetDied and ValidateCombatRequest already use —
---      never trusted alone.
--- THIS IS A TERMINATION PATH (DEVELOPER_REFERENCE.md §12.0 item 4's "no unbounded
--- trap" guarantee, restated for EndActiveEffectForHolder immediately
--- above): it must never be gated on HasK9Access/Config.Features.*/a
--- cooldown/mutex/any check that can fail closed, same discipline
--- EndActiveEffectForHolder's own doc comment already establishes for
--- Recall. The two checks above are read-only facts about server-held
--- state, neither of which can ever "deny" a genuine claim the way an
--- access/cooldown check could strand one — a holder who is not actually
--- dead simply gets a no-op, never a rejection.
--- Even a successful lie has a low ceiling regardless: the worst outcome of
--- a false report is ending a hold `source` is already the HOLDER of —
--- something releaseBiteHold/releaseDrag/EndActiveEffectForHolder already
--- let this same holder do unconditionally (or near-unconditionally)
--- anyway, not a capability escalation against anyone else.
---
--- AWARD-FARM CHECK (explicitly verified, not assumed): EndHold's own
--- BiteAndHold XP-award branch only pays out for reason == 'released' or
--- 'timeout' — 'holder_died' (used below) is neither, so this termination
--- path can never mint biteHoldSuccess XP, the same exclusion
--- 'target_died' already relies on for the sibling report above.
RegisterNetEvent('qbx_k9unit:server:reportHolderDied', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if not targetNetId then return end -- src is not currently the holder of anything -- ignore

    local holderPed = GetPlayerPed(src)
    if holderPed == 0 or GetEntityHealth(holderPed) > PED_DEAD_HEALTH_THRESHOLD then
        return -- claim does not match this player's own live server-side state -- ignore, never trust the claim alone
    end

    EndHold(targetNetId, 'holder_died')
end)

--[[ ================= NON-COMPLIANCE DETECTION ================= ]]

--- ACE->JOB-RANK REWRITE (this pass, project-owner-directed, mirroring
--- server/admin.lua's IsAuthorizedAdmin -- same shape, deliberately not
--- reinvented): the notify_staff fan-out below used to gate on
--- `IsPlayerAceAllowed(tostring(playerId), 'command')`. Config.AdminAudit.
--- AcePermission is now dead config (removed from config.lua per that
--- file's own admin-audit ACE->job-rank pass), and this call site was a
--- second, independent ACE check this file still owned on top of it.
---
--- Same Config.Departments[job.name] membership requirement, same
--- job.isboss short-circuit, same explicit `type(job.grade.level) ==
--- 'number'` guard before ever comparing it, as IsAuthorizedAdmin -- applied
--- against a NEW, SEPARATE threshold, Config.Departments[job.name].
--- nonComplianceAlertGrade, deliberately NOT Config.Departments[job.name].
--- auditGrade. These two concerns are not the same principal: auditGrade
--- gates the k9_search_log/k9_progression AUDIT TRAIL (who searched whom,
--- and when) -- a genuine privacy boundary, appropriately set to a senior
--- rank. A non-compliance alert carries no citizen-identifying search
--- history at all (`targetLabel` below is only ever a raw player source
--- number or NPC netId, never a citizenid or search result) and is
--- operational, real-time situational awareness about a K9 UNIT's own
--- conduct during an active bite-hold/takedown/drag -- closer in kind to a
--- dispatch/BOLO broadcast than to pulling someone's audit history. Reusing
--- auditGrade would gate it behind the SAME high bar as full audit-log
--- access for no privacy reason, and would mean on-duty officers below that
--- rank never see a live "this K9 interaction might not be compliant"
--- signal that could matter in the moment. Recommended (to whoever owns
--- config.lua -- not added here): Config.Departments[job].
--- nonComplianceAlertGrade, a new NUMBER field per department, same
--- semantics as auditGrade/certifierGrade (job.isboss always qualifies;
--- otherwise job.grade.level >= this value). Suggested default: 0 (any
--- sworn member of a configured department sees these -- operational, not
--- privacy-sensitive, per the reasoning above); raise it per-department if
--- a server wants this restricted to supervisors instead. This is a product
--- call, disclosed rather than silently decided -- the operator may prefer
--- a higher default.
---
--- FAILS CLOSED on every path where a job cannot be fully resolved: no
--- Player, no PlayerData, no job, job.name not a configured department, no
--- dept.nonComplianceAlertGrade (or a non-number one), no job.grade, or a
--- non-number job.grade.level all return false -- none of them ever reach
--- the `>=` comparison, so none of them can throw. Matches IsAuthorizedAdmin
--- exactly on this point.
---
--- PERFORMANCE (coordinator-flagged, this pass): this resolves one
--- exports.qbx_core:GetPlayer(...) call per online player, same as the ACE
--- check it replaces did per online player (that one paid GetPlayers()
--- itself, unchanged here). NOT cached/memoized -- measured against how
--- often this loop can actually run before adding that complexity: every
--- FlagNonCompliance call site (SampleCompliance, below) guards on
--- `hold.compliance.flagged`, a single boolean set true on the FIRST
--- violation of ANY kind for a given hold and never reset -- so this
--- notify_staff loop fires AT MOST ONCE per ActiveHolds entry for its
--- entire lifetime, not once per sampling tick. A per-tick cost concern
--- does not apply; a cache would add real complexity (staleness on
--- job/grade change, eviction on disconnect) for a code path that already
--- cannot repeat for the same hold.
--- @param playerId number
--- @return boolean
local function IsAuthorizedForNonComplianceAlert(playerId)
    local player = exports.qbx_core:GetPlayer(playerId)
    if not player or not player.PlayerData then return false end

    local job = player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    if job.isboss then return true end

    local dept = Config.Departments[job.name]
    if type(dept.nonComplianceAlertGrade) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.nonComplianceAlertGrade
end

--- @param hold table -- an ActiveHolds entry
--- @param targetNetId number
--- @param kind string
--- @param detail string -- already human-formatted; see call sites
local function FlagNonCompliance(hold, targetNetId, kind, detail)
    local cfg = Config.Combat.NonComplianceDetection
    -- LOCALE FIX (locale-migration pass, coder-backend): was two `..`
    -- string-concatenated variants ('player source ' .. tostring(...) /
    -- 'NPC netId ' .. tostring(...)) — the exact "glue a literal prefix onto
    -- a dynamic value with `..`" shape this migration's own README already
    -- flagged and fixed four times elsewhere (this is the fifth). Fixed the
    -- same way: two independent, complete `%s`-templated locale keys
    -- selected by a plain if/else, not one template with a conditional
    -- prefix. This value is ALSO consumed by the print() line immediately
    -- below (console diagnostics, out of migration scope on its own) — that
    -- is fine and expected, same as client/bonetool.lua's own
    -- known_sweep console print consuming already-locale()-sourced text.
    local targetLabel = hold.isPlayerTarget
        and locale('combat.noncompliance_target_player', tostring(hold.targetSrc))
        or locale('combat.noncompliance_target_npc', tostring(targetNetId))

    -- 'log' is the BASELINE, always-on behavior -- 'log' cannot mean
    -- "don't log." This print is the forensic record regardless of
    -- `action`'s value.
    print(('[qbx_k9unit] NON-COMPLIANCE (detection-only, NEVER punitive) kind=%s effect=%s target=%s holderSrc=%s detail=%s')
        :format(kind, hold.effectType, targetLabel, tostring(hold.holderSrc), detail))

    if cfg.action == 'notify_staff' then
        local message = locale('combat.noncompliance_message', kind, targetLabel, detail)
        for _, playerIdStr in ipairs(GetPlayers()) do
            local playerId = tonumber(playerIdStr)
            if playerId and IsAuthorizedForNonComplianceAlert(playerId) then
                TriggerClientEvent('ox_lib:notify', playerId, {
                    title = locale('combat.noncompliance_notify_title'),
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
    else -- 'drag' (DEVELOPER_REFERENCE.md §12.5.4/§12.0 item 8, this pass)
        -- Only meaningful for a PLAYER target -- an NPC target has no "own
        -- client" to ignore the speed-limit relay in the first place (the
        -- K9's own already-trusted client directly commands the NPC's move
        -- rate every tick, same posture as bite/takedown's NPC branches) --
        -- so there is no hostile party to detect here, unlike bite/takedown
        -- above which sample BOTH target kinds uniformly (a pre-existing
        -- choice this pass does not relitigate). Compares the target's live
        -- position against the K9's OWN live position (never an absolute
        -- speed ceiling) -- DEVELOPER_REFERENCE.md §12.0 item 8's own framing:
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

--- DEVELOPER_REFERENCE.md §12.0 item 4's "no unbounded trap" guarantee for
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

--- LIFECYCLE QA FIX (this pass): the shared maintenance thread below used to
--- check hold.expiresAt, target resolvability, and (for drags)
--- DragExceedsMaxDistance above -- but never the HOLDER's own health. If the
--- HOLDING K9 died mid-hold/mid-drag while remaining connected (never
--- disconnecting -- the DISCONNECT case is already handled correctly, see
--- playerDropped below), nothing noticed: the target stayed
--- flee-suppressed/damage-immune/move-rate-limited (or, for a drag,
--- physically attached to a corpse) until that hold's own hard timeout, up
--- to Config.Combat.BiteAndHold.maxDurationMs/
--- Config.Combat.NonLethalTakedown.ragdollDurationMs/
--- Config.Combat.PropDragging.maxDragDurationMs later -- bounded (never an
--- unbounded trap), but the effect visibly outlived its cause. This
--- function is the ALWAYS-ON backstop half of the fix (see the maintenance
--- thread's own call site below); 'qbx_k9unit:server:reportHolderDied'
--- above (near EndActiveEffectForHolder) is the faster, client-reported
--- half for the two cases (drag-as-holder, NPC-effect-as-holder) where the
--- holder's own client already tracks enough state to self-detect its own
--- death within a frame -- this function is what closes the gap
--- UNCONDITIONALLY even if that report is lost, never sent (a
--- bite-hold/takedown on a PLAYER target has no client-side holder state to
--- self-report from at all -- see reportHolderDied's own doc comment), or
--- sent by a hostile/frozen/crashed client that never runs its own
--- self-check.
---
--- Deliberately narrow, mirroring HolderPedIsDead's sibling
--- DragExceedsMaxDistance's own "holder already disconnected" early-return
--- immediately above: only reports a HOLDER who is genuinely still
--- connected (GetPlayerPed ~= 0) AND whose own live health has crossed
--- PED_DEAD_HEALTH_THRESHOLD. A DISCONNECTED holder is a different,
--- already-handled case (the playerDropped handler below ends the hold
--- immediately with 'holder_disconnected') -- this function deliberately
--- does not re-label that same, already-correct case with a different
--- reason string for what would otherwise only ever be a benign, momentary
--- race between the two (this thread's own tick landing in the brief
--- window before playerDropped fires for the same disconnect).
--- @param hold table -- an ActiveHolds entry
--- @return boolean dead
local function HolderPedIsDead(hold)
    local holderPed = GetPlayerPed(hold.holderSrc)
    return holderPed ~= 0 and GetEntityHealth(holderPed) <= PED_DEAD_HEALTH_THRESHOLD
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
                elseif HolderPedIsDead(hold) then
                    -- LIFECYCLE QA FIX (this pass) — see HolderPedIsDead's
                    -- own doc comment above for the full writeup: this is
                    -- the ALWAYS-ON backstop half of the holder-death fix,
                    -- never gated behind NonComplianceDetection.enabled or
                    -- any other feature flag/access/cooldown check — this is
                    -- a TERMINATION path (DEVELOPER_REFERENCE.md §12.0 item 4's own
                    -- "no unbounded trap" guarantee, same discipline
                    -- EndActiveEffectForHolder's own doc comment above
                    -- already establishes for Recall) and must never be
                    -- blockable. Catches the case within one
                    -- MAINTENANCE_INTERVAL_MS tick (500ms) even if the
                    -- client-reported 'qbx_k9unit:server:reportHolderDied'
                    -- event is lost, never sent (a bite-hold/takedown on a
                    -- PLAYER target has no client-side holder state to
                    -- self-report from at all), or sent by a client that
                    -- never runs its own self-check.
                    local ok, err = pcall(EndHold, targetNetId, 'holder_died')
                    if not ok then
                        print(('[qbx_k9unit] combat EndHold(holder_died) errored for netId %s: %s'):format(targetNetId, tostring(err)))
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
--
-- POLL-INTERVAL VALIDATION (audit follow-up, same shape server/defense.lua's
-- own pollIntervalMs fix just addressed there, see that file's own comment
-- and server/cooldowns.lua's header ADDENDUM): positionSampleWindowMs feeds
-- a bare `Wait()` directly, never NewCooldown/ResolveConfiguredThresholdMs,
-- so it was validated by neither of this file's other backstops. A
-- non-numeric/non-positive value here would throw inside `Wait()` on this
-- thread's very first iteration, killing THIS thread permanently (Lua
-- coroutines do not resume after an unhandled error) and silently
-- disabling non-compliance sampling for the rest of the resource's
-- uptime — quieter than the expiry-thread failure modes above only because
-- this feature is itself "non-punitive and log-only," never because a
-- config typo here is somehow safe. Resolved the same way, not with a hard
-- `assert` — an `error()` thrown from this file's own top-level chunk (this
-- `if` block runs at file-load time) would abort server/combat.lua's own
-- load from this line onward, taking EndActiveEffectForHolder and every
-- BiteAndHold/NonLethalTakedown/PropDragging event down with it, exactly
-- the failure cooldowns.lua's header ADDENDUM used THIS file as its own
-- worked example of. Same fallback (500ms) as config.lua's own shipped
-- default for this field.
local PositionSampleWindowMs = ResolveConfiguredThresholdMs(
    Config.Combat.NonComplianceDetection.positionSampleWindowMs, 500, 'Config.Combat.NonComplianceDetection.positionSampleWindowMs')

if Config.Combat.NonComplianceDetection.enabled then
    CreateThread(function()
        while true do
            Wait(PositionSampleWindowMs)
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
        ValidateCombatRequest(src, targetNetId, Config.Features.BiteAndHold, Config.Combat.BiteAndHold.range, 'BiteAndHold')
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason), 'error')
        return
    end

    -- XP-FARM FIX (this pass) -- BOTH cooldowns are CHECKED first (read-only,
    -- neither one stamped yet) before EITHER is consumed, same "cheapest
    -- checks first, mutation last" discipline this file's own
    -- ValidateCombatRequest doc comment already establishes, and the same
    -- shape HandleTakedownRequest below already uses for its own per-K9 +
    -- per-target cooldown pair. This matters here specifically because a
    -- request that is ultimately rejected for being on ONE of the two
    -- cooldowns must never consume the OTHER -- burning BiteHoldTargetCooldown
    -- (a per-TARGET cooldown) for a request that never actually happened
    -- would incorrectly penalize the NEXT K9 who tries this same target,
    -- and burning BiteHoldCooldown (per-K9) here for nothing would cost this
    -- K9 20s for a request that was never granted.
    --
    -- NO EXPLICIT thresholdMs ARGUMENT BELOW (this pass, QA sandbox repro --
    -- see server/cooldowns.lua's header ADDENDUM): this used to re-read
    -- Config.Combat.BiteAndHold.cooldownMs/targetCooldownMs RAW, directly
    -- from Config, as a per-call override -- completely redundant with (and,
    -- worse, silently SHADOWING) each tracker's own constructor default a
    -- few lines above, which is now the SAFE, ResolveConfiguredThresholdMs-
    -- resolved value. Since `local threshold = thresholdMs or
    -- defaultThresholdMs` treats a non-nil override as authoritative and 0
    -- is truthy in Lua, that raw re-read would have silently REOPENED this
    -- exact footgun at the one place that actually enforces it at runtime,
    -- even after the constructor-level fix: a misconfigured
    -- Config.Combat.BiteAndHold.cooldownMs = 0 would still have permanently
    -- fail-closed this ONE mechanic, ignoring the safe fallback the
    -- constructor already computed. Config.Combat.BiteAndHold.cooldownMs/
    -- targetCooldownMs are never mutated at runtime anywhere in this
    -- codebase (grep-verified), so omitting them here changes nothing for a
    -- valid config and gets the safe fallback for an invalid one, for free.
    if BiteHoldCooldown.IsOnCooldown(src)
        or BiteHoldTargetCooldown.IsOnCooldown(targetNetId) then
        NotifyPlayer(src, CombatRejectMessage('on_cooldown'), 'error')
        return
    end

    BiteHoldCooldown.Touch(src)
    BiteHoldTargetCooldown.Touch(targetNetId)

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
        -- Category B relay -- DEVELOPER_REFERENCE.md §12.0 item 8. Sent ONLY to
        -- the target's own client, never a broadcast.
        TriggerClientEvent('qbx_k9unit:client:applyBiteHold', targetSrc, k9NetId, expiresAt)
    else
        -- NPC target — RESTRUCTURED, native-api-assistant verification
        -- pass (this session): see this file's header "NPC-TARGET NATIVE
        -- EXECUTION CONTEXT" note. DEVELOPER_REFERENCE.md §12.5.1's own prose calls
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
    NotifyPlayer(src, locale('combat.bite_hold_attempted'), 'inform')
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
---      this player's own live server-side ped via a GetEntityHealth <=
---      PED_DEAD_HEALTH_THRESHOLD check — a DELIBERATE choice to verify,
---      not the "can't verify, so don't pretend to" call this codebase
---      makes elsewhere for tracking's forged-trail risk. UPDATED, native-
---      sweep follow-up pass: this comment previously named IsEntityDead as
---      "the SAME native ValidateCombatRequest above already calls" and
---      framed that as reassurance that "a real, already-trusted
---      verification mechanism exists." That reassurance was backwards —
---      IsEntityDead has NO FXServer server implementation (see
---      PED_DEAD_HEALTH_THRESHOLD's own doc comment above for the primary-
---      source finding) and always silently returned false, so THIS
---      handler unconditionally rejected every claim, genuine or not, and
---      the holder-side fix this handler exists to provide never actually
---      worked. Both this site and ValidateCombatRequest now share the same
---      GetEntityHealth-based check instead — the "same mechanism, reused"
---      property this comment always intended is now actually true.
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

    -- NATIVE-AVAILABILITY FIX (found this pass, same native-sweep as
    -- PED_DEAD_HEALTH_THRESHOLD's own doc comment above): this handler's
    -- own doc comment above claims this re-verification is "not a new or
    -- unverified native here -- it is the SAME native ValidateCombatRequest
    -- above already calls" -- true, but that native (IsEntityDead) has NO
    -- FXServer server implementation and always returned false, meaning
    -- `not IsEntityDead(targetPed)` was always `true` and this handler
    -- UNCONDITIONALLY returned early on every single call, regardless of
    -- whether the claim was genuine. The holder-side stuck-lockout bug this
    -- handler exists to fix (see this handler's own doc comment above) was
    -- therefore NEVER actually fixed by this code path -- a target who
    -- genuinely died mid-hold could never get their holder released via
    -- this report, only ever via the maxDurationMs timeout. Rewritten to
    -- use GetEntityHealth against the same PED_DEAD_HEALTH_THRESHOLD as
    -- every other server-side "is this ped dead" check in this file.
    local targetPed = GetPlayerPed(src)
    if targetPed == 0 or GetEntityHealth(targetPed) > PED_DEAD_HEALTH_THRESHOLD then
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
        ValidateCombatRequest(src, targetNetId, Config.Features.NonLethalTakedown, Config.Combat.NonLethalTakedown.range, 'NonLethalTakedown')
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason), 'error')
        return
    end

    -- Cooldowns CHECKED (not yet consumed) before the yield below — actual
    -- Consume happens only after re-validation post-yield, so a request
    -- that ultimately fails the speed gate never burns either cooldown.
    --
    -- NO EXPLICIT thresholdMs ARGUMENT BELOW (this pass, QA sandbox repro --
    -- same reasoning as requestBiteHold's identical fix above, see that
    -- comment / server/cooldowns.lua's header ADDENDUM for the full
    -- writeup): relies on TakedownCooldown/TakedownTargetCooldown's own
    -- ResolveConfiguredThresholdMs-resolved constructor default instead of
    -- re-reading Config.Combat.NonLethalTakedown.cooldownMs/targetCooldownMs
    -- raw, which would silently shadow that safe default with an invalid
    -- Config value again at the one place this actually gates a real
    -- request.
    if TakedownCooldown.IsOnCooldown(src)
        or TakedownTargetCooldown.IsOnCooldown(targetNetId) then
        NotifyPlayer(src, CombatRejectMessage('on_cooldown'), 'error')
        return
    end

    -- SERVER-COMPUTED SPEED GATE — DEVELOPER_REFERENCE.md §12.5.2 / §12.0 item 8's
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
        ValidateCombatRequest(src, targetNetId, Config.Features.NonLethalTakedown, Config.Combat.NonLethalTakedown.range, 'NonLethalTakedown')
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

    -- NO EXPLICIT thresholdMs ARGUMENT BELOW either -- same reasoning as the
    -- pre-yield IsOnCooldown check above; both must resolve the SAME
    -- threshold the pre-yield check just used, which is only guaranteed by
    -- both reading the tracker's own constructor default rather than each
    -- independently re-reading (and each independently risking shadowing)
    -- raw Config.
    if not TakedownCooldown.Consume(src)
        or not TakedownTargetCooldown.Consume(targetNetId) then
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
        -- Category B relay -- DEVELOPER_REFERENCE.md §12.0 item 8.
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
        --
        -- NATIVE-AVAILABILITY FIX (this pass, coder-backend, native-sweep
        -- follow-up -- see this file's header "NPC-TARGET NATIVE EXECUTION
        -- CONTEXT" section, SetEntityHealth bullet, for the full finding):
        -- this branch used to ALSO call `SetEntityHealth(targetPed2, ...)`
        -- directly, server-side, as a "real, independently server-callable
        -- backstop" -- that claim did not survive verification. No
        -- `ext/native-decls` doc page exists for SetEntityHealth at all
        -- (unlike GetEntityHealth/GetEntityMaxHealth, both confirmed
        -- `apiset: server`), and citizen-server-impl's own
        -- ServerGameState_Scripting.cpp -- the exact file that registers
        -- GET_ENTITY_HEALTH/GET_ENTITY_MAX_HEALTH -- registers no
        -- SET_ENTITY_HEALTH/SET_PED_HEALTH handler anywhere. That call was
        -- therefore a SUSPECTED silent no-op, the same class of bug already
        -- fixed for SetEntityCanBeDamaged in this same branch above --
        -- kept, it would have quietly done nothing while this comment
        -- claimed otherwise. REMOVED here rather than left in as a harmless
        -- guess: the health-floor top-up now belongs entirely to
        -- client/combat.lua's own `applyNpcTakedown` handler, which already
        -- receives this same NPC target and can read
        -- `Config.Combat.NonLethalTakedown.healthFloor` directly (a
        -- `shared_scripts`-loaded config value, no new payload field
        -- needed on the TriggerClientEvent below) and self-apply
        -- `SetEntityHealth` the same already-client-confirmed way
        -- server/medkit.lua's applyMedkitHeal relay already does for a
        -- player target. THIS FILE'S HALF of the fix is complete (no
        -- longer calling a suspect native, no longer documenting it as
        -- trustworthy). STALE-COMMENT FIX (this pass, cross-change
        -- regression review, re-verified against the actual current
        -- client/combat.lua before rewriting this paragraph, not taken on
        -- the report alone): the CLIENT HALF has SINCE LANDED --
        -- client/combat.lua's `applyNpcTakedown` handler now calls
        -- `SetEntityHealth(npcPed, Config.Combat.NonLethalTakedown.healthFloor)`
        -- guarded the same `< healthFloor` way, ordered between the
        -- damage-bracket and the ragdoll task below, exactly matching this
        -- paragraph's own original ask. The one-time top-up is therefore no
        -- longer unapplied for an NPC target whose health was already below
        -- the floor at ragdoll-open time -- the damage-bracket
        -- (SetEntityCanBeDamaged) and the ragdoll itself, both relayed
        -- below, remain the primary, continuous protection during the
        -- window regardless; the health-floor call was always disclosed as
        -- a one-time supplement on top of them, not a replacement for
        -- either.
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
    -- SEVENTH XP-FARM FIX (this pass) -- see TakedownXpMintCooldown's own
    -- declaration comment (near BiteHoldXpMintCooldown, above) for the full
    -- writeup. Gates ONLY this AwardXP call, checked LAST -- reaching this
    -- line already means the feature flag, HasK9Access, live proximity, the
    -- full ValidateCombatRequest re-check, the server-computed speed gate,
    -- AND both TakedownCooldown/TakedownTargetCooldown.Consume calls above
    -- all already succeeded, so this is the very last thing that can still
    -- gate whether this specific takedown pays out. The relay
    -- (applyNpcTakedown/forceRagdoll above), ActiveHolds/K9ActiveEffect
    -- (already written above), and the notify call below are all entirely
    -- unaffected by whether this Consume succeeds -- a K9 out of mint budget
    -- still performs a fully normal takedown, it just is not paid for this
    -- one.
    --
    -- EIGHTH XP-FARM FIX, NPC-ELIGIBILITY HALF -- see EndHold's own bite-hold
    -- branch (above in this file) for the full writeup; identical reasoning
    -- applied to takedownSuccess. Checked FIRST in this `and` chain, before
    -- TakedownXpMintCooldown.Consume, for the same reason every other
    -- condition on this line is already ordered this way: a target that was
    -- never going to pay out anyway must never burn this per-holder mint
    -- budget, or a K9 that only ever gets ambient NPCs could exhaust its own
    -- real budget on takedowns that were never eligible to pay, then find
    -- itself falsely "out of budget" the next time a genuinely eligible
    -- wanted player comes along.
    if (isPlayerTarget2 or (Config.XP and Config.XP.mintXpForNpcCombatTargets == true))
        and type(AwardXP) == 'function'
        and TakedownXpMintCooldown.Consume(src, TAKEDOWN_XP_MINT_COOLDOWN_MS) then
        local holderPlayer = exports.qbx_core:GetPlayer(src)
        local holderCitizenid = holderPlayer and holderPlayer.PlayerData and holderPlayer.PlayerData.citizenid
        if holderCitizenid then
            AwardXP(holderCitizenid, 'takedownSuccess')
        end
    end

    -- BEST-EFFORT WORDING (guardrail 4).
    NotifyPlayer(src, locale('combat.takedown_attempted'), 'inform')
end

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestTakedown', function(targetNetId)
    local src = source

    -- Guards the yield inside HandleTakedownRequest against a second
    -- overlapping call from the SAME K9 — see TakedownMutex's own
    -- declaration comment above.
    if not TakedownMutex.TryAcquire(src) then
        NotifyPlayer(src, locale('combat.takedown_already_in_progress'), 'error')
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
    DEVELOPER_REFERENCE.md §12.5.4 / §12.0 items 1, 4, 5, 6, 8 (coder-architect,
    this pass). Reuses ActiveHolds/K9ActiveEffect/EndHold/FlagNonCompliance/
    the shared maintenance thread above wholesale (effectType = 'drag') —
    see this file's own header for why (avoids exactly the kind of
    unforced duplicate-table/duplicate-lifecycle problem DEVELOPER_REFERENCE.md
    §12.0 item 8 itself warns against for this class of state).

    CATEGORY A/B SPLIT FOR THIS MECHANIC, restated concretely against the
    code below (DEVELOPER_REFERENCE.md §12.0 item 8's own framing): the attach
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
    for an NPC, override-or-metadata-guess for a player, DEVELOPER_REFERENCE.md
    §12.0 item 6). Called as an explicit SEPARATE step after
    ValidateCombatRequest({requireAlive = false}) succeeds — see that
    function's own updated header for why this could not simply reuse its
    built-in dead-target check (GetEntityHealth-based -- see PED_DEAD_HEALTH_THRESHOLD above).

    NO XP AWARD for PropDragging in this pass — DEVELOPER_REFERENCE.md §12.2's own
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
    -- target -- ValidateCombatRequest's own dead-target rejection exists
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
        ValidateCombatRequest(src, targetNetId, Config.Features.PropDragging, Config.Combat.PropDragging.range, 'PropDragging', { requireAlive = false })
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
    -- DEVELOPER_REFERENCE.md §12.2's literal sketch (which names only
    -- maxDragDistance as this mechanic's "no unbounded trap" cap, §12.0
    -- item 4) — LANDED in config.lua (Config.Combat.PropDragging.maxDragDurationMs
    -- = 20000; see that field's own comment there for the full disclosed
    -- reasoning). Reuses the SAME `hold.expiresAt` / maintenance-thread-timeout
    -- mechanism bite/takedown already use, no new enforcement path. NOTE:
    -- unlike the cooldown fields above, this value is read directly with
    -- no positive-number validation anywhere in this file — a misconfigured
    -- non-positive/non-numeric value here would either error at this line
    -- or silently expire a drag hold instantly, not fail loudly the way
    -- cooldowns.lua's own guarded fields do; flagged, not fixed, since no
    -- Config.Combat.* field in this file is validated this way today.
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
        -- Category B relay -- DEVELOPER_REFERENCE.md §12.0 item 8.
        TriggerClientEvent('qbx_k9unit:client:applyDragSpeedLimit', targetSrc, expiresAt)
    end
    -- NPC target: no separate relay event needed -- dragStarted above
    -- already told the K9's own client isPlayerTarget = false, which is
    -- all that client needs to also drive SetPedMoveRateOverride on the
    -- NPC directly, every tick, alongside the attach re-assertion.

    -- BEST-EFFORT WORDING (guardrail 4) -- never claims the target cannot
    -- escape, mirrors requestBiteHold/HandleTakedownRequest's own copy.
    NotifyPlayer(src, locale('combat.drag_attempted'), 'inform')
end)

RegisterNetEvent('qbx_k9unit:server:releaseDrag', function()
    local src = source

    -- Either the HOLDING K9 or, when the target is a player, the TARGET
    -- itself may release at will -- DEVELOPER_REFERENCE.md §12.5.4 / §12.0 item 4:
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
