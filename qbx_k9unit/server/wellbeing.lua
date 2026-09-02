--[[
    qbx_k9unit/server/wellbeing.lua

    Phase 4 implementation. Owns Config.Features.FatigueSystem / MoodSystem /
    FearStressSystem / DistractionSystem / InjuryLimping / HungerThirstSystem
    (DEVELOPER_REFERENCE.md §13.0 Decision 1, §13.2, §13.4.3 — HungerThirstSystem
    added this pass, coder-backend, as a SIXTH sibling stat pair; see this
    header's own "HUNGER/THIRST" section further down for its full design)
    — ONE shared per-citizenid stat store, ONE shared
    Config.Wellbeing.tickIntervalMs decay/regen tick, each of the six
    Config.Features flags independently gating only its OWN stat's tick
    logic / gameplay-facing effects, exactly mirroring server/tracking.lua's
    existing Scent/Blood/Gunpowder precedent (three independently-toggleable
    flags, one shared file pair, one shared prune loop) rather than six
    near-duplicate files. Every "five flags" reference further down this
    header predates HungerThirstSystem and describes THOSE five accurately
    for what was true when written; not exhaustively rewritten to "six"
    throughout, since most of that prose narrates a specific historical
    fix (a security finding, a regression, a softlock) whose own five-flag
    scope was, and remains, exactly correct as stated.

    "READ AT THE POINT OF ACTIVATION" DISCIPLINE (DEVELOPER_REFERENCE.md §3): every branch
    below is gated on its OWN Config.Features flag, not just declared —
    disabling e.g. FatigueSystem while MoodSystem stays on means fatigue is
    never ticked, never read, and never pushed to a meaningful value; it
    simply idles at its default. RESOLVED (see
    the CreateThread call near the bottom, and its own resolution comment,
    for the full writeup): the shared tick thread now ALWAYS starts at this
    file's own load time regardless of whether any of the five flags is on
    yet, re-checking all five fresh inside the loop before ever calling
    TickWellbeing — a server booted with every flag off and later flipped
    live from the tablet is picked up within one
    Config.Wellbeing.tickIntervalMs, never "not until this resource
    restarts." This paragraph used to read the opposite ("this file starts
    NO thread at all if all five flags are false") and pointed at a
    "DISCLOSED, NOT FIXED HERE" comment naming a live-toggle-ON gap plus a
    reverted attempt to close it — both are gone now; see the CreateThread
    call's own comment for exactly why that first attempt was the wrong
    shape to copy, and what this fix copies instead.

    ======================================================================
    CONFIDENCE GRADING — read before extending this file:

    1. Event relay reuse (Mood/Injury damage decay, FearStress gunfire rise)
       — HIGH confidence on the EVENT NAMES/TRIGGER SEMANTICS themselves:
       server/tracking.lua's own header (read directly, not
       assumed) documents 'qbx_k9unit:server:relayDamageEvent' and
       'qbx_k9unit:server:relayWeaponFire' as already-shipped, real,
       client-triggered events fired only when the reporting client is
       genuinely the victim / genuinely shooting. This file adds its OWN
       independent `AddEventHandler` for each of those two ALREADY-
       REGISTERED event names (RegisterNetEvent is idempotent — calling it
       again here is harmless and makes this file's own dependency on the
       event being network-triggerable explicit, not implicit on
       server/tracking.lua having run first) rather than reaching into
       server/tracking.lua's `TrackableLog` (a `local`, file-scoped table —
       genuinely inaccessible from here without editing that file, which is
       out of scope here). This is a deliberate, disclosed design
       choice: MOOD/INJURY read the `source` of their own independent
       handler invocation directly (no log needed — a flat decrement per
       qualifying event is enough), while FEARSTRESS keeps its OWN small
       `RecentGunfire` array (same `{coords, loggedAt}` shape as
       `TrackableLog.gunpowder`, but wellbeing-local) fed by that same
       independent handler, since FearStress needs a short-lived spatial
       log (gunfire NEAR the K9, not necessarily ITS OWN gunfire) that
       `TrackableLog` structurally already provides but does not expose.
       MEDIUM-HIGH confidence overall: the relay mechanism is proven; the
       "two independent consumers of one client-triggered event, one small
       duplicate log" shape is this file's own new pattern, not something
       independently verified working end-to-end (no live
       server available to test against).
    2. Fatigue's "sprinting" detection (a server-side rolling
       position-sample: distance travelled between ticks / tickIntervalMs)
       is THIS FILE'S OWN implementation of the general technique
       DEVELOPER_REFERENCE.md §12.5.2 is understood to describe for
       NonLethalTakedown's speed gate. RECONCILED (checked directly against
       the now-landed server/combat.lua): NonLethalTakedown's own speed gate
       samples the TARGET's displacement over a short, bounded
       `Config.Combat.NonLethalTakedown.speedSampleWindowMs` window taken at
       request time (two GetEntityCoords calls around a single `Wait`), to
       decide whether the TARGET is fleeing — it never measures the
       requesting K9's own movement, has no notion of "the K9 is
       sprinting," and shares no config key, threshold, or state with this
       file's `Config.Wellbeing.Fatigue.sprintSpeedThreshold` continuous
       per-tick sample of the K9's OWN position. Same general
       distance/time technique, two independent measurements of two
       different entities for two different purposes — there is nothing
       here for the two files to actually diverge on, and no reconciliation
       work remains.
    3. `SetPedMoveRateOverride` itself is not called from this file at all
       (that's client/movement.lua's `RecomputeK9MoveRate()`, DEVELOPER_REFERENCE.md
       §13.0 Decision 2) — this file only ever sets named entries in the
       stats snapshot pushed to the owning client; HIGH confidence, this
       file has no native-call uncertainty of its own.
    4. ox_inventory `GetItemCount`/`RemoveItem` (feed/distraction item
       consumption) reuse the exact same two exports server/medkit.lua
       already confirmed HIGH confidence against real ox_inventory source
       this session (see that file's header) — not re-verified independently
       here, but the same confirmed signatures apply unchanged.
    5. Flashbang immunity (Config.Wellbeing.Distraction.flashbangImmune) —
       THIS PASS (coder-backend) implements the one half achievable without
       guessing a third-party resource's own event shape:
       `IsFlashbangImmune(citizenid)`, a resource-global accessor mirroring
       `IsHesitating`/`IsDistracted`'s exact established contract (self-only
       citizenid lookup, type-checked, gated on
       Config.Features.DistractionSystem, zero cross-player influence — it
       reads only static config plus its own string argument). DEVELOPER_REFERENCE.md
       §13.4.3.4's reality check still stands UNCHANGED for the other half:
       nothing in this codebase, and no confirmed third-party flashbang/stun
       resource's event name/payload shape, exists for this file to listen
       for and suppress — inventing one here would be exactly the kind of
       guess DEVELOPER_REFERENCE.md §11.6 already refused for the door-lock nudge-open
       dependency. A companion flashbang/stun resource (or a future addition
       to THIS resource, once one exists) that wants to honor immunity calls
       `IsFlashbangImmune(citizenid)` before applying its own stun effect,
       guarded with the same `type(IsFlashbangImmune) == 'function'` pattern
       RestoreInjury's own call site already establishes for exactly this
       "genuine new cross-file/cross-resource dependency, no consumer exists
       yet" shape. That is the real, callable half now shipped; the event-
       side hookup remains genuinely integration-dependent, not glossed over
       as solved.
    6. Fatigue rest-source regen (Config.Wellbeing.Fatigue.restRegenPerTick /
       .restRadius / .restSources) — THIS PASS (coder-backend) wires this
       using DEVELOPER_REFERENCE.md §13.4.3.1 open question 1's own "a world-object
       proximity check" reading (not an item-name check — no dropped-item
       log exists for this purpose, and inventing one would duplicate
       server/tracking.lua's own scent-log machinery for no disclosed
       benefit). `restSources` entries are treated as model names, hashed
       once via `GetHashKey`, and matched every tick against
       `GetAllObjects()`/`GetAllVehicles()` — server-side natives that
       enumerate every currently-networked entity regardless of any one
       client's own streaming radius, which is why they're the right choice
       here over a client-reported "I am near a kennel" claim or a
       client-supplied coordinate, per this document's own "never trust a
       client-claimed position" rule (see TickWellbeing's own comment at
       that call site for the full server-authority note). This satisfies
       the open question's own explicit "extensible rather than hardcoded to
       water bowl alone" requirement: adding Phase 5's deployable kennel
       prop model or a K9 vehicle model to `restSources` needs no code
       change here, only a config edit. COST, DISCLOSED: the
       `GetAllObjects()`/`GetAllVehicles()` scan runs ONCE per tick, shared
       across every online K9 (not once per K9) — see TickWellbeing's own
       comment at that call site for the exact bound. NATIVE CONFIDENCE:
       CONFIRMED this pass (coder-backend defect-sweep) — every native this
       section depends on was checked directly against a fresh clone of
       citizenfx/fivem's own `ext/native-decls/*.md` (200 response, not
       assumed from ecosystem knowledge): `GetAllObjects` (apiset: server),
       `GetAllVehicles` (apiset: server), `GetEntityModel` (apiset: server),
       `GetEntityCoords` (apiset: server), `GetHashKey` (apiset: server),
       `GetGameTimer` (apiset: server), `GetPlayerPed` (apiset: server) all
       resolved with a genuine server-side declaration — none of the "silent
       zero/nil forever" failure mode this codebase has been burned by
       elsewhere (four unregistered-native gates on IsEntityDead/
       IsPedDeadOrDying found and fixed in a sibling pass) applies to any
       native this Fatigue rest-source path calls. `GetPlayers()` (used
       throughout `TickWellbeing` and `applyK9Distraction` below) is
       DELIBERATELY not in that list — it has no `native-decls` page at all
       (confirmed 404) because it is not a raw native, it is the standard
       FXServer Lua-runtime helper wrapping
       `GetNumPlayerIndices`/`GetPlayerFromIndex`, the same idiom already
       used elsewhere in this resource (server/certifications.lua,
       server/tracking.lua) — its absence from native-decls is expected, not
       a gap. The open item this confidence grading previously left for
       native-api-assistant is CLOSED: no further native-verification pass
       is needed before enabling FatigueSystem with a non-empty
       restSources.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4, wellbeing subsystem.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:getWellbeingSnapshot' () -> table? stats
       [THIS FILE] On-demand snapshot for a client that just became
       K9-modeled (client/wellbeing.lua calls this once on that transition,
       rather than waiting up to tickIntervalMs for the next automatic push)
       or when the whole subsystem is disabled (returns nil). Resolves the
       CALLER'S OWN citizenid server-side — no target parameter, no way to
       ask about another citizenid.
    2. 'qbx_k9unit:server:petK9' (targetServerId: number) -> { ok, reason? }
       [THIS FILE] Re-validates Config.Features.MoodSystem, live proximity
       between the interactor's and target's own live positions, target
       re-verified as a real connected K9-model player server-side, and a
       per-(interactor, target) cooldown (Config.Wellbeing.Mood.petCooldownMs)
       — never a client-claimed "I petted my K9."
    3. 'qbx_k9unit:server:feedK9' (targetServerId: number) -> { ok, reason? }
       [THIS FILE] Same validation shape as petK9, plus real ox_inventory
       item possession/consumption (Config.Wellbeing.Mood.feedItemName),
       mirroring server/medkit.lua's item-consumption discipline exactly
       (possession check, stamp cooldown BEFORE removal, remove, only then
       mutate state).
    4. 'qbx_k9unit:server:applyK9Distraction' (itemType: 'meatBait'|'whistle')
       -> { ok, reason?, affected? } [THIS FILE] Re-validates
       Config.Features.DistractionSystem, consumes the configured item from
       the USING player (open question, DEVELOPER_REFERENCE.md §13.4.3.4 item 2,
       resolved here as OPEN to any player, not gated on Config.Departments —
       this document's own tentative reading, "a trainer's tool that also
       works as a suspect's countermeasure"), then resolves affected K9s by
       querying the USING PLAYER'S OWN live position (never a client-claimed
       coordinate) against every currently-connected K9-model player's own
       live position within the configured radius, subject to
       Config.Wellbeing.Distraction.perTargetCooldownMs per affected K9.

    Server events (RegisterNetEvent, client->server):
    5. 'qbx_k9unit:server:calmDownK9' () [THIS FILE] Self-only radial-style
       action (mirrors K9Sit — no target). Re-validates
       Config.Features.FearStressSystem, the caller's own K9 model, and
       Config.Wellbeing.FearStress.calmDownCooldownMs.
    6. 'qbx_k9unit:server:relayDamageEvent' () [ALREADY REGISTERED BY
       server/tracking.lua — THIS FILE adds an ADDITIONAL, independent
       AddEventHandler] Decrements Mood/Injury for the reporting client's
       OWN citizenid if it's currently K9-modeled, subject to this file's
       OWN ingest cooldown (reuses Config.Tracking.Blood.relayCooldownMs as
       the threshold value — same numeric rate server/tracking.lua already
       applies to the identical event, applied here via an independent
       tracker instance, not shared state).
    7. 'qbx_k9unit:server:relayWeaponFire' () [ALREADY REGISTERED BY
       server/tracking.lua — THIS FILE adds an ADDITIONAL, independent
       AddEventHandler] Appends the reporting client's own live position to
       this file's OWN `RecentGunfire` log (only if FearStressSystem is
       enabled), subject to this file's OWN ingest cooldown (reuses
       Config.Tracking.Gunpowder.relayCooldownMs).
    8. 'qbx_k9unit:server:feedK9Hunger' () [THIS FILE, this pass] Self-only,
       no target (mirrors calmDownK9 above). Re-validates
       Config.Features.HungerThirstSystem, the caller's own K9 model/access,
       Config.Wellbeing.Hunger.feedItemName possession, and
       HungerFeedCooldown (per-citizenid).
    9. 'qbx_k9unit:server:giveK9Water' () [THIS FILE, this pass] Same shape
       as feedK9Hunger, for Thirst — Config.Wellbeing.Thirst.drinkItemName,
       ThirstReliefCooldown (per-citizenid, SHARED with drinkFromBowl below).
    10. 'qbx_k9unit:server:drinkFromBowl' (bowlNetId: number) [THIS FILE,
       this pass] Self-only. `bowlNetId` is the world bowl OBJECT's own
       network id (client/wellbeing.lua's ox_target `data.entity`, converted
       client-side via NetworkGetNetworkIdFromEntity) — re-resolved
       server-side via server/entities.lua's ResolveNetworkEntity
       (expectedEntityType = 3), re-checked against
       Config.Wellbeing.Thirst.bowlSources' own model-hash set, and
       re-checked for live proximity to the caller's own ped — never a
       client-claimed "I am near a bowl." No item is consumed.

    Client events (RegisterNetEvent, server->client):
    11. 'qbx_k9unit:client:wellbeingUpdate' (stats: table) [server->client,
       requester only, client/wellbeing.lua] — one combined push per tick
       carrying all six wellbeing values together (mirrors
       DEVELOPER_REFERENCE.md#hud-bridge's own "one combined message
       beats a split one" reasoning, DEVELOPER_REFERENCE.md §13.4.3.1).
       UPDATED (LIVE FEATURE FLAG PUSH, this pass): `stats.featureFlags` is
       now also included (see `SnapshotOf`'s own header comment above for
       the full "why piggyback here, not a new event" writeup) — the LIVE,
       fresh-read state of all six Config.Features flags this file owns,
       so client/wellbeing.lua's move-rate composer and Injury sprint/jump
       block can react to a runtime tablet toggle within one tick instead of
       only ever seeing the value this client's OWN copy of config.lua
       shipped with at that client's own resource start. Same shape from
       `getWellbeingSnapshot` (item 1 above) for the on-demand fetch path.
    12. 'qbx_k9unit:client:partnerConditionUpdate' (payload: { visible:
       boolean, tags: string[] }) [server->client, THE BONDED HANDLER
       ONLY, client/hud.lua] — THIS PASS. Closes the production-readiness
       audit's own "a handler cannot tell how their own dog is doing" gap.
       Every tick this file already runs for a tracked K9 (no second
       thread — see PushHandlerConditionUpdate below, called from the
       exact same per-K9 loop that already builds/sends item 11 above),
       the K9's CURRENT PARTNER is resolved SERVER-SIDE via
       server/partnership.lua's GetActivePartnerCitizenId(k9Citizenid) —
       never from anything a client claims — and, only if that partner is
       currently online, sent a small set of COARSE condition tags derived
       from this file's OWN existing per-stat thresholds, never a new
       number and never the raw 0-100 value: 'tired' (Fatigue <=
       speedPenaltyThreshold), 'unhappy' (Mood <=
       performancePenaltyThreshold), 'stressed' (FearStress >=
       hesitationThreshold), 'injured' (Injury <= sprintBlockThreshold),
       'hungry'/'thirsty' (Hunger/Thirst <= lowThreshold). `tags` is empty
       (not omitted) when every enabled stat is currently in its healthy
       band — client/hud.lua renders that as "Fine." Each tag is gated on
       its OWN Config.Features flag (a disabled stat contributes no tag,
       ever — see ComputeHandlerConditionTags), and the whole feature is
       additionally gated on Config.Features.HandlerPartnership. Sent ONLY
       on change (a new tagsKey, a partner change, or the resolved
       handler reconnecting under a new source id — see
       PushHandlerConditionUpdate's own comment), never every tick
       regardless of whether anything moved. `visible = false` (`tags`
       always `{}` alongside it) is this feature's explicit CLEAR signal,
       sent whenever there is nothing left to report: no active
       partnership, the partner just disconnected, the partnership just
       ended, or every wellbeing stat system is off — see
       ClearHandlerConditionBadge/ClearAllHandlerConditionBadges below for
       the distinct stop paths this covers. NEVER carries a position, a
       raw stat value, or
       anything else that could be used to locate the K9 — see
       ComputeHandlerConditionTags' own doc comment for the exact, closed
       list of everything this payload can ever contain. Full design
       writeup: this file's own "HANDLER CONDITION BADGE" header section,
       further down.

    Resource-globals (no `local` — other files call these directly):
    - RestoreInjury(citizenid: string, amount: number) — the accessor
      server/medkit.lua ALREADY CALLS via a `type(RestoreInjury) == 'function'`
      guard (DEVELOPER_REFERENCE.md §13.4.3.5/§13.4.4). Signature matches that
      call site exactly: `RestoreInjury(targetCitizenid, Config.K9Medkit.injuryRestore)`.
      No-op if Config.Features.InjuryLimping is false (never gates/mutates
      anything the feature flag hasn't activated, per this file's own
      "read at the point of activation" discipline above) or if the
      arguments are the wrong type. Clamped to Config.Wellbeing.Injury.max,
      never allowed to move the value downward.
    - IsHesitating(citizenid: string) -> boolean — true while a FearStress-
      driven hesitation window (Config.Wellbeing.FearStress.hesitationDurationMs)
      is active. THE genuine new cross-file dependency DEVELOPER_REFERENCE.md §13.5
      flags: server/combat.lua (Phase 3, not yet built as of this pass) must
      call this as part of its own bite-hold/takedown/drag request
      validation once it exists — guard with
      `type(IsHesitating) == 'function'`, the same forward-compatible
      pattern server/medkit.lua already uses for RestoreInjury.
      DISCLOSED RESIDUAL RISK (coder-security finding B, config-audit
      follow-up pass — full writeup on the relayWeaponFire AddEventHandler
      below): the fearStress input this accessor's return value is derived
      from is fed by a payload-less, forgeable event, deduped by reporting
      source to close the primary amplification vector. server/combat.lua
      DOES now call this accessor as a hard reject in ValidateCombatRequest
      — that is no longer a hypothetical "whoever wires this up next"
      concern, it is real, live code today. CONFIRMED (this pass): because
      the reporting event carries no target and the affected-K9 loop below
      matches by RADIUS around the reporter's own live position, a forger
      does not merely hesitate their own K9 — physical proximity to ANY
      other connected K9 is sufficient to target that specific K9, whether
      or not the forger is a K9, a combat participant, or has any other
      interaction with that player at all. That made this a real, targeted
      denial-of-capability once combat.lua shipped as a consumer, not a
      near-harmless self-only quirk. TickWellbeing's HESITATION_MAX_CONTINUOUS_MS
      cap (this pass) bounds it: a forger can still force repeated
      hesitation episodes on a specific K9 by staying nearby and
      re-touching the event, but each episode is capped and is always
      followed by an enforced window where that K9 is guaranteed not to be
      hesitating — "indefinite" is closed, "repeatable but bounded" is the
      disclosed, accepted remainder. Not a reason to skip calling this
      accessor (DEVELOPER_REFERENCE.md §13.5 still requires it) — just an accurate,
      current statement of what calling it exposes you to, kept up to date
      here specifically because the LAST version of this note went stale
      the moment a second file started consuming it without this note being
      re-checked. Whoever next changes either this accessor's contract or
      its call site in server/combat.lua should update BOTH this note and
      that file's own comment together, not just one.
    - IsDistracted(citizenid: string) -> boolean — same shape as
      IsHesitating, for Distraction's own "breaks command" state
      (DEVELOPER_REFERENCE.md §13.4.3.4's reading of that state as a server-enforced
      command rejection, the same category as FearStress's hesitation, not
      named as its own accessor anywhere in DEVELOPER_REFERENCE.md's own text but a
      direct, natural extension of the SAME pattern it names for
      IsHesitating — added here so Phase 3's combat.lua has a real hook for
      BOTH command-breaking wellbeing states, not just one).
    - IsFlashbangImmune(citizenid: string) -> boolean — THIS PASS
      (coder-backend). See CONFIDENCE GRADING item 5 above for the full
      "what this does and does not solve" writeup. Unlike IsHesitating/
      IsDistracted, this reads NO per-citizenid state at all — it is a pure
      config check (Config.Features.DistractionSystem AND
      Config.Wellbeing.Distraction.flashbangImmune), the `citizenid`
      argument existing only to match the established accessor shape and to
      type-guard against a non-string caller mistake, exactly like every
      other accessor here. Self-only by construction: nothing about this
      function's result can be influenced by another player, ever — it
      cannot be used as a lever against anyone else's K9, unlike
      IsHesitating's disclosed residual risk above.

    FILE-TO-FILE CONTRACT:
    - Calls `IsConfiguredK9Model(modelHash)`, resource-global from
      server/certifications.lua — reused, never re-derived, to verify a
      target/reporting player's ped is really a configured K9 model.
    - SUPERSEDED (coder-architect, adversarial-pass security finding +
      owner directive "I also want everything to work with any ped", this
      pass): this used to read "does NOT call HasK9Access — wellbeing
      tracks the K9 CHARACTER's own body state, gated on CURRENT ped
      model, not on job/certification (mirrors how AgilityBasicJump/
      AgilityAdvanced in client/movement.lua gate on IsOwnModelK9, not
      HasK9Access)." That rationale predated two things that now override
      it: (1) a real access-bypass finding — gating on the model ALONE
      let a never-certified player who simply set their own ped model
      client-side (no server round trip) pass every check below and
      manipulate mood/fatigue/fear-stress/injury for free; (2) the owner's
      explicit instruction that a K9-role holder must get every feature of
      this resource regardless of what ped they wear, including an
      unlisted or human one. ResolveK9Ped below now answers "(actually
      dog-modeled OR holds the K9 role, server/appearance.lua's HasK9Role)
      AND HasK9Access" — every one of the six gates that read its `isK9`
      result (damage decay, petK9, feedK9, calmDownK9, applyK9Distraction,
      the main TickWellbeing loop) inherits both fixes from that one
      function, with no other change needed in this file. The
      AgilityBasicJump/AgilityAdvanced comparison above no longer applies:
      those gate a MOVEMENT RESTRICTION tied to the ped's actual current
      skeleton (suppressing free quadruped locomotion a human-shaped ped
      never had to begin with), a genuinely different, still-unresolved
      question — see this pass's own hand-off report.
    - Uses server/cooldowns.lua's NewCooldown/NewNestedCooldown constructors
      exclusively (DEVELOPER_REFERENCE.md item 1's established convention) —
      no hand-rolled cooldown table anywhere in this file.
    - Owns `WellbeingStats` (citizenid -> stat table) and `RecentGunfire`
      (append-only array) as file-local state. `RecentGunfire` remains
      ephemeral/in-memory only (a short-lived spatial log, meaningless
      across a restart) — mirrors server/tracking.lua's `TrackableLog` /
      server/main.lua's `LeashPairs` precedent. `WellbeingStats` ITSELF IS
      NOW DATABASE-BACKED (this pass, coder-backend — see this file's own
      "DATABASE PERSISTENCE" header section further down for the full
      design). The line that used to stand here ("ephemeral/in-memory
      only, deliberately not persisted") was true when written and had
      become actively wrong: a server restart wiped every K9's fatigue/
      mood/fearStress/injury/hunger/thirst with no database write of any
      kind ever having existed for this table, directly contradicting this
      header's own very next sentence ("a K9 who logs off tired should
      still be tired"), which was only ever true WITHIN one continuously-
      running server process. Corrected, not merely re-worded: writes now
      go through `K9Store.Wellbeing_Get`/`K9Store.Wellbeing_Upsert`
      (server/datastore.lua — "THE ONLY PLACE IN THIS RESOURCE THAT MAY
      NAME A `k9_*` TABLE OR CALL `MySQL.*` DIRECTLY," this file's own
      established convention, reused rather than bypassed), softly guarded
      (`type(K9Store) == 'table' and type(K9Store.Wellbeing_Get) ==
      'function'`, this file's own established "genuine new cross-file
      dependency, no consumer exists yet" idiom already used for
      RestoreInjury/IsHesitating's OWN callers) so this file degrades to
      EXACTLY today's memory-only behaviour, never an error, the moment
      `K9Store.Wellbeing_Get`/`K9Store.Wellbeing_Upsert` are ever absent —
      STATUS, CORRECTED (a follow-up change closed this the same day):
      server/datastore.lua now DOES carry both accessors (this pass's own
      migration, sql/migrations/0022_create_k9_wellbeing.sql, is also now
      folded into sql/install.sql directly), so this guard's immediate
      trigger — "server/datastore.lua has not grown these accessors yet" —
      no longer describes this resource's own real state. The guard itself
      is kept regardless, as permanent defense-in-depth (the same posture
      RestoreInjury's own `type(...) == 'function'` check keeps
      indefinitely after server/combat.lua actually landed as a real
      caller — see that accessor's own doc comment), not removed just
      because its original trigger closed.
      `WellbeingStats` STILL grows one entry per distinct citizenid seen
      this session (same accepted growth profile as server/
      certifications.lua's `Certifications` cache) BUT is now bounded
      going forward: once an entry's persisted stats are confirmed written
      (`dirty == false`) and its owning citizenid has been offline longer
      than `Config.Wellbeing.Persistence.evictAfterMs`, that entry is
      dropped from memory (never before either condition holds — evicting
      an unflushed change would be the exact "reset a player's dog" bug
      this whole feature exists to avoid) and reloaded from the database
      on the next reference. Still never cleared on a mere disconnect
      within the eviction window (a K9 who logs off tired should still be
      tired on reconnect — now true across a RESTART too, not merely
      within one server session).
    ======================================================================

    ======================================================================
    STUCK-K9 SOFTLOCK FIX (this pass, coder-backend) — a QA finding, VERIFIED
    against this file/client/wellbeing.lua/server/medkit.lua/config.lua as
    they actually stood before touching anything, not assumed. The chain
    QA reported was accurate on every link: `Config.Wellbeing.Injury
    .passiveRegenPerTick = 0.1` per 5000ms tick regenerates Injury at
    0.02/s, so a K9 dropped to 0 (a handful of `relayDamageEvent` hits at
    `damageDecayAmount = 10` each, trivial in one firefight) took ~16.7 real
    minutes to clear `jumpBlockThreshold` (20) and ~25 minutes to clear
    `sprintBlockThreshold` (30) — client/wellbeing.lua's INPUT_SPRINT/
    INPUT_JUMP thread `DisableControlAction`-blocks both, unconditionally,
    below those thresholds, with no server override (DEVELOPER_REFERENCE.md §13.0
    Decision 3's own disclosed, deliberate limitation — never a security
    boundary, but a real gameplay one). This file had NO death/respawn
    handling anywhere before this pass (confirmed: no `IsEntityDead`/
    `GetEntityHealth` call of any kind existed here), and wellbeing state is
    deliberately persisted across disconnect (this header, FILE-TO-FILE
    CONTRACT, above) — so neither dying nor reconnecting ever cleared a
    depleted Injury value. K9Medkit is the only fast remedy, and
    `Config.K9Medkit.itemName` ships as an explicitly-documented PLACEHOLDER
    that must exist in the target server's own ox_inventory items table —
    unregistered, `GetItemCount` resolves 0 forever and every heal fails
    closed as a generic `no_item`, indistinguishable from a player simply
    not carrying one, with nothing anywhere explaining why. Three
    independent, separable fixes, all landed this pass:

    1. REGEN RATE — NOT fixed in this file (this file does not own
       config.lua). `Config.Wellbeing.Injury.passiveRegenPerTick` should be
       raised 0.1 -> 1.0, matching the EXACT precedent already set for
       `Config.Wellbeing.Mood.passiveRegenPerTick` (0.2 -> 1.0, that field's
       own comment: "This is the ONLY recovery path for a solo handler").
       Injury's own hard sprint/jump BLOCK makes this an even stronger case
       for parity than Mood's speed-multiplier-only penalty, not a weaker
       one. At 1.0/tick: jumpBlockThreshold(20) clears in 100s (~1.67 min),
       sprintBlockThreshold(30) in 150s (~2.5 min), a full 0->100 climb in
       500s (~8.33 min, identical to Mood's own already-adopted number).
       Reported to the task owner for config.lua; NOT applied here.

    2. DEATH/RESPAWN RESET — fixed below (`PED_DEAD_HEALTH_THRESHOLD`,
       `MIN_DEATH_EPISODE_DURATION_MS`, `injuryDeathEpisodeStartedAt`, and
       the death-episode block inside TickWellbeing's
       `Config.Features.InjuryLimping` branch). DECISION: a K9 that dies and
       is later revived/respawned is treated the same way this resource
       already treats every OTHER measure of that ped's condition across the
       exact same event — its REAL native health is already reset to full by
       whatever laststand/ambulance system handles revival/respawn (nothing
       in this resource, or in the game engine, makes a fresh life inherit
       the previous one's wounds); a virtual Injury value surviving that
       same event completely unmodified is the actual inconsistency, not a
       deliberate design. `Config.Wellbeing.Injury.deathRespawnRestoreAmount`
       (new field, reported to the task owner for config.lua — recommended
       default 100, i.e. Injury.max, a FULL reset) is added to Injury once a
       qualifying death EPISODE ends with the K9 observed alive again.
       CONFIGURABLE, per this task's own instruction: an operator who wants
       "still limping after respawn" for realism sets it to 0 (a genuine,
       supported no-op) or any partial value between 0 and Injury.max.

       READ THIS BEFORE TOUCHING THE DETECTION LOGIC — IT IS A HEURISTIC,
       NOT AN EVENT. This resource has no server-authoritative "this ped
       just died" or "this ped was just revived" signal of its own, and this
       file's own established convention (CONFIDENCE GRADING item 5 above,
       for flashbang immunity) is to refuse to guess at a third-party
       ambulance/laststand resource's event name or payload shape rather
       than invent one that would only ever fire on servers running that
       exact resource. What this actually measures, honestly: has this K9's
       native health been observed continuously at/below
       `PED_DEAD_HEALTH_THRESHOLD` for at least
       `MIN_DEATH_EPISODE_DURATION_MS`, sampled once per
       `Config.Wellbeing.tickIntervalMs`. That is a real, if imperfect,
       proxy for "was genuinely downed for a meaningful stretch" — it is NOT
       a death event, cannot be made into one without a dependency this file
       has already refused to guess at, and both KNOWN failure directions
       are disclosed rather than hidden: it can miss a genuine, very fast
       revive (rare — see the timing note below), and it can very rarely
       credit a bizarre non-death cause of prolonged sub-threshold health
       (also see below). `IsEntityDead` is deliberately NOT used for this
       detection — that native has NO FXServer server-side registration at
       all (server/combat.lua's and server/medkit.lua's own, independently
       confirmed "NATIVE-AVAILABILITY FIX" findings, both citing a direct
       search of citizenfx/fivem's own native-registration source; not
       re-verified a third time here, reused as already-established fact)
       and always silently returns `false` server-side. `PED_DEAD_HEALTH_
       THRESHOLD = 100` mirrors server/combat.lua's/server/medkit.lua's own
       identical constant and reasoning (a GTA ped is conventionally
       declared dead at 100 health, not 0 — the reason default max health
       is 200).

       FOLLOW-UP FIX #1 (regression pass, caught empirically against the
       live resource): the first version of this detection used a plain
       boolean ("was this ped observed dead as of the last tick") living in
       the same per-citizenid `WellbeingStats` table this file's OWN header
       documents as deliberately surviving a disconnect ("a K9 who logs off
       tired should still be tired on reconnect") — but that persistence
       rule was written for the four PERSISTED stats, and this boolean was
       not one of them; it was a transient snapshot of "was THIS SPECIFIC
       ped handle observed dead," meaningless the instant a reconnect hands
       the citizenid a brand-new ped. A K9 could take damage, die,
       DISCONNECT while dead (before any revive completed), and reconnect to
       a fresh, genuinely-alive ped that never went through any revive/
       ambulance flow at all — the next tick misread that as a real
       transition and paid the full restore for free, repeatably. FIXED:
       both places that already reset the OTHER field in this exact same
       transient category (`lastCoords` — the `elseif ped ~= 0` branch
       inside TickWellbeing, and the `playerDropped` handler) now ALSO reset
       `injuryDeathEpisodeStartedAt` to 0 alongside it. See the
       `WellbeingStats` struct comment (above `EnsureStats`) for the
       now-explicit "persisted vs. transient ped-instance-scoped" category
       split this bug fell through the seam of.

       FOLLOW-UP FIX #2 (red-team pass, independently found, WORSE than #1):
       the same boolean design paid out on ANY observed crossing of
       `PED_DEAD_HEALTH_THRESHOLD`, not a genuine death-and-revival — no
       disconnect, no ambulance flow, no delay of any kind required. A K9
       grazed down to ~90 health (a serious wound by this codebase's own
       health-threshold convention, but very much still an ordinary, ACTIVE
       combat participant, not "dead" in any gameplay sense) that healed
       back above 100 within the next `tickIntervalMs` — an ordinary
       bandage, food, armor, or even vanilla passive regen, all well under
       the 5s default poll interval — had that single boundary crossing read
       as "died and was revived," paying the FULL `deathRespawnRestoreAmount`
       (100 by default) for the cost of a bandage: strictly cheaper than
       both recovery paths this whole fix was built around (the deliberately
       slow `passiveRegenPerTick`, and K9Medkit's own `injuryRestore` of 40 —
       this exploit was worth more than the item it was meant to sit
       alongside). It also paid out ONCE PER CROSSING rather than once per
       down episode, so a genuinely downed K9 whose health merely oscillated
       near the threshold during one real laststand could collect several
       full resets from a single down. FIXED by replacing the boolean with
       `injuryDeathEpisodeStartedAt`, a `GetGameTimer()` timestamp (0 =
       not currently in a candidate episode): set on the FIRST tick a
       continuous sub-threshold stretch begins, left untouched while it
       continues, and read — then unconditionally cleared to 0, whether or
       not it qualifies — the moment the K9 is next observed alive. The
       restore fires only if that episode's measured span reached
       `MIN_DEATH_EPISODE_DURATION_MS`; an ordinary combat dip healed within
       a tick or two never does, and clearing the timestamp unconditionally
       on every alive-observation means each candidate episode is judged
       exactly once, closing the oscillation/multi-payout case as a natural
       consequence of the same fix rather than a second, separate patch.
       `MIN_DEATH_EPISODE_DURATION_MS` is deliberately a LOCAL constant, not
       a new Config field — same "small, disclosed, security-relevant value
       lives in code, not an operator-tunable knob that could be set low
       enough to reopen the exploit" reasoning this file's own
       HESITATION_MAX_CONTINUOUS_MS below already established. See that
       constant's own doc comment for the exact derivation and the residual
       limitations this heuristic still, honestly, cannot close.

       NOTE FOR CONFIG.LUA'S OWN disclosed-residual-risk COMMENT (task
       owner, this is the update the coordinator asked for): the OLD text
       covered only a player choosing to fully die and be revived through a
       real ambulance system with real cost. It did not cover, and after
       FOLLOW-UP FIX #2 no longer needs to worry about, ordinary combat
       healing near the threshold (that path is now gated on
       MIN_DEATH_EPISODE_DURATION_MS, ~60s minimum by default — see that
       constant's own comment) or multiple payouts from one oscillating down
       episode (now impossible — at most one payout per episode, by
       construction). The residual risk that DOES remain, honestly: a player
       who deliberately manufactures a real ≥60-second stretch at/below 100
       health and then heals up still receives a full restore with no real
       ambulance/laststand system involved at all — cheaper than a genuine
       downed state in most real deployments (which typically run minutes,
       not the ~60s floor here), but not free in the way the crossing-based
       version was, and bounded to at most one payout per attempt rather
       than one per graze. Recommended config.lua wording: replace the
       existing disclosed-risk paragraph's scope from "a player choosing to
       die and be revived" to "a player deliberately holding their K9's
       health at or below 100 for at least MIN_DEATH_EPISODE_DURATION_MS
       (server/wellbeing.lua, ~60s by default) and then healing normally,
       with no real ambulance/laststand flow required" — same underlying
       risk category, now bounded to a real minimum time cost per attempt
       and to one payout per episode rather than unbounded/free.

    3. SILENT PLACEHOLDER-ITEM FAILURE — fixed below (`WarnIfItemMissing`,
       the trailing `AddEventHandler('onResourceStart', ...)` block).
       Mirrors server/combat.lua's own established "resource-start WARNING,
       never an assert" pattern for `Config.Combat.PropDragging
       .IsPlayerDownedOverride` verbatim (same reasoning: a misconfigured
       placeholder here degrades one feature's usefulness, it does not
       defeat this resource's own access control the way inventory.lua's
       `accessScope`/search.lua's assert-guarded fields do, so a hard stop
       at resource start would be a disproportionate response). Checks
       EVERY single-item-name placeholder config value this resource
       depends on against ox_inventory's own live item registry
       (`exports.ox_inventory:Items(name)`, confirmed against a fresh read
       of ox_inventory's own `modules/items/server.lua` this pass — returns
       the item's registered data table, or nil if that name was never
       registered), not just `Config.K9Medkit.itemName`:
       `Config.Wellbeing.Mood.feedItemName`, `Config.Wellbeing.Distraction
       .meatBaitItemName`, and `.whistleItemName` are this file's own three;
       `Config.K9Medkit.itemName` is ALSO checked HERE, even though
       server/medkit.lua is the file that actually consumes it — a
       deliberate exception to this resource's usual "each file validates
       its own config" convention, forced by this task's own file-ownership
       boundary (editing server/medkit.lua was explicitly out of scope for
       this pass). Config is a plain global table already read from every
       file in this resource; reading `Config.K9Medkit.itemName` from here
       introduces no new cross-file coupling that didn't already exist
       (server/medkit.lua remains the ONLY file that ever mutates
       ox_inventory on this item's behalf). If server/medkit.lua is ever
       edited by someone with standing to do so, moving that one check
       there and deleting it here is a reasonable, low-risk follow-up —
       until then, one consolidated warning beats a silently-missing one.
       Every check is gated on its OWNING `Config.Features.*` flag (never
       warns about an item a disabled feature will never touch) and every
       `exports.ox_inventory:Items(...)` call is `pcall`-wrapped (an
       unexpected export error becomes its own loud warning, never a thrown
       resource-start failure) — a WARNING, never an assert, per this
       task's own explicit instruction never to block resource start over
       an operator's inventory configuration.

       NOTED, NOT FIXED (out of this pass's scope — a different file, a
       different failure shape): `Config.SearchContrabandItems` (server/
       search.lua) is also a "placeholder item name" list per its own
       config.lua comment, but a missing entry there silently under-detects
       contraband weight rather than making a single action fail closed
       every time — a materially different, lower-severity failure mode,
       on a LIST rather than a single critical dependency, in a file this
       pass does not own. Left to whoever next touches server/search.lua.
    ======================================================================

    ======================================================================
    HUNGER/THIRST (this pass, coder-backend) -- Config.Features.HungerThirstSystem.
    A SIXTH sibling stat pair added to the SAME shared file/tick/store this
    header already establishes -- not a parallel subsystem. Full reasoning
    (rates, consequences, persistence, anti-farm) is in this task's own
    hand-off report, not repeated in full here; this is the short version
    for anyone reading only this file.

    CONSEQUENCE, DELIBERATELY MILD: both stats feed a single MILD move-rate
    multiplier each (Config.Wellbeing.Hunger/Thirst.speedPenaltyMultiplier,
    via K9MoveRateModifiers.hunger/.thirst -- client/movement.lua's composer
    is a generic `for _, modifier in pairs(K9MoveRateModifiers) do effective
    = effective * modifier end`, so a new named key needs no change there).
    Deliberately NOT a hard input block (unlike Injury) -- a starving/
    dehydrated K9 must stay usable, just slower, per this task's own
    instruction that this "should never be able to reach cannot work at
    all." Clamped server-side to [0.5, 1.0] (see ClampConfiguredNumber call
    sites below) so a bad config edit cannot turn "mild" into "frozen."

    RATES: decayPerTick is tuned so Hunger empties in ~90 minutes (one
    on-duty K9 shift) and Thirst in ~60 minutes (dogs need water more often
    than food) if never fed/watered, at the shipped tickIntervalMs (5000ms).
    See config.lua's own comment on each field for the exact arithmetic.

    PERSISTENCE: hunger/thirst are added to the SAME persisted category as
    fatigue/mood/fearStress/injury (see the WellbeingStats struct comment
    below, category 1) -- "a K9 who logs off hungry should still be hungry
    on reconnect within the same server session," same rule, same reason,
    no new transient/category-2 field needed (there is no per-ped-instance
    observation for these two stats the way lastCoords/
    injuryDeathEpisodeStartedAt are for Fatigue/Injury).

    NO DEATH/RESPAWN INTERACTION, DELIBERATELY: unlike Injury, dying and
    being revived does not refill a K9's stomach -- no restore is wired for
    either stat on that transition, and none should be added without
    re-deriving Injury's own MIN_DEATH_EPISODE_DURATION_MS-style defenses
    first (a full restore-on-revive for a stat with no real connection to
    combat health would just be a second, needless exploit surface).

    ANTI-FARM: passive decay is the ONLY thing that ever lowers either stat,
    driven purely by TICK_INTERVAL_MS/GetGameTimer() -- no client input
    (e.g. "am I sprinting") accelerates it, unlike Fatigue's sprint-decay,
    specifically so a client cannot grief its OWN K9's hunger/thirst by
    forging activity. Every RELIEF action below (feedK9Hunger/giveK9Water/
    drinkFromBowl) is cooldowned per CITIZENID (the stat owner), stamped
    BEFORE any item removal (TOCTOU-safe ordering, mirrors Mood/K9Medkit),
    and real item consumption is a real, non-recoverable resource cost --
    between the cooldown and the item cost, neither stat can be pushed to
    max and held there for free or arbitrarily often.

    SELF-SERVICE, A DELIBERATE DIVERGENCE FROM MOOD's petK9/feedK9: Mood's
    `targetPed == usingPed` reject exists to force a genuine second player
    into the loop (a bonding mechanic). Hunger/Thirst are framed here as
    PERSONAL upkeep (matching both named competitors' own "food/water items
    you carry for your own K9" framing, DEVELOPER_REFERENCE task's own WHY
    section) -- so feedK9Hunger/giveK9Water are plain self-only actions (no
    target parameter at all, exactly RequestK9CalmDown/calmDownK9's shape),
    triggered by `/k9eat` and `/k9drink` (client/wellbeing.lua), not an
    ox_target option on another player. A K9 with no partner online is never
    locked out of feeding itself, unlike Mood.

    WATER BOWL MODEL RISK, INHERITED AND DISCLOSED: drinkFromBowl (the free,
    no-item world-prop path, Thirst only -- Hunger has no bowl equivalent,
    see the report for why) targets Config.Wellbeing.Thirst.bowlSources,
    shipped as `{ 'water_bowl' }` -- the SAME unverified model name
    Config.Wellbeing.Fatigue.restSources already carries a disclosed risk
    for. Kept as an INDEPENDENT list (not a re-read of Fatigue's own field)
    so a confirmed replacement can be set here without touching Fatigue.
    DEGRADES GRACEFULLY if it never resolves to a real model: ox_target's
    AddModel (client/wellbeing.lua) simply never matches anything in the
    world, so the option never appears -- Thirst still fully works via
    giveK9Water (the item path), which has no model dependency at all.

    CONFIG DEFENSIVENESS, A REAL CONSTRAINT OF THIS TASK'S OWN FILE-OWNERSHIP
    BOUNDARY: this file does NOT own config.lua, so `Config.Wellbeing.Hunger`/
    `.Thirst` may not exist yet on a server whose config.lua has not been
    updated to add them. Every unconditional read (EnsureStats' defaults,
    SnapshotOf's wellbeingTunables entries) guards with
    `type(Config.Wellbeing.Hunger) == 'table'` before indexing into it, so a
    server missing these tables entirely degrades to safe hardcoded
    defaults rather than erroring out of THIS FILE'S OWN LOAD (which would
    take Fatigue/Mood/FearStress/Distraction/Injury down with it -- the
    exact "one Config typo takes five unrelated features down" failure this
    file's own TICK_INTERVAL_MS validation above already refuses to repeat).
    GetResolvedHungerThirstConfig() (CLAMP AND WARN, below) is the one place
    that reads every field individually and is ONLY ever called from inside
    an `if Config.Features.HungerThirstSystem then` branch -- "read at the
    point of activation," restated for a config SECTION that may not exist
    at all, not just a bad VALUE inside one that does.
    ======================================================================

    ======================================================================
    HANDLER CONDITION BADGE (this pass, coder-backend) -- closes a
    production-readiness audit's own "the single best remaining thing to
    build" finding: a handler (the human officer at the other end of a
    partnership -- NEVER the player controlling the dog) had no way to
    learn their own bonded K9 partner's wellbeing short of the other
    player typing it out of character. See this file's EVENT/CALLBACK
    CONTRACT item 12 above for the exact wire contract, and
    client/hud.lua's own header for the client-side rendering half.

    SERVER-AUTHORITATIVE PARTNER RESOLUTION, NEVER A CLIENT CLAIM: the
    receiving handler is resolved via server/partnership.lua's
    GetActivePartnerCitizenId(k9Citizenid) -- the SAME accessor
    server/recall.lua's Recall actor and server/defense.lua's
    HandlerDownDefense trigger already trust for the identical "who is
    this K9's bonded partner, right now" question. A citizenid never
    appears as a target here because a client asked for it; it appears
    because THIS FILE's own TickWellbeing loop already knows, from
    server-held state, that citizenid is a currently-connected,
    currently-tracked K9.

    COARSE, NEVER NUMERIC: ComputeHandlerConditionTags below returns a
    small set of STRING TAGS ('tired'/'unhappy'/'stressed'/'injured'/
    'hungry'/'thirsty'), never a 0-100 value, and derives every one of
    them from a threshold this file's OWN Config.Wellbeing tables already
    define for a real mechanical consequence (Fatigue's
    speedPenaltyThreshold, Mood's performancePenaltyThreshold,
    FearStress's hesitationThreshold, Injury's sprintBlockThreshold,
    Hunger/Thirst's lowThreshold) -- never a new number invented for this
    feature. The words a handler reads always agree with the mechanics
    already governing their own dog's behavior; retuning one of those
    existing thresholds in config.lua automatically retunes when the
    matching word appears, with no second place to keep in sync.

    NEVER A TRACKER: the only payload this feature ever sends is
    `{ visible, tags }` -- no position, no distance, no direction, no raw
    stat value, nothing that narrows where the K9 is. Contrast
    Config.Features.DangerWarn (client/combat.lua), which deliberately
    sends a COARSE direction+distance BAND for a genuine tactical-warning
    use case -- this feature has no comparable need and sends no
    positional information at all, not even a coarse one.

    FEATURE-FLAG RESPECTING: gated on Config.Features.HandlerPartnership
    (no partnership feature, nothing to resolve a handler from) AND, tag
    by tag, on each stat's own OWNING Config.Features.* flag inside
    ComputeHandlerConditionTags -- a disabled stat contributes no tag,
    ever, exactly mirroring this file's own established "read at the point
    of activation" discipline (this header's opening section) for every
    other consumer of these six flags. Every one of these flags is already
    correctly narrowed by config.lua's own Config.FeatureGroups
    parent/child resolution (ResolveFeatureGroups) before this file ever
    sees it, and server/runtimecontrol.lua's own IsFeatureGroupParentEnabled
    gate already refuses to let a runtime tablet toggle turn a child flag
    on while its parent family is off -- so reading Config.Features.<Name>
    fresh (as every branch below already does) is already family-aware;
    no second, redundant IsFeatureGroupParentEnabled call is needed here
    on top of it.

    CHEAP, ON THE EXISTING TICK, ON CHANGE ONLY: no second CreateThread --
    PushHandlerConditionUpdate is called from the exact same per-K9 pass
    inside TickWellbeing that already builds and sends item 11's
    wellbeingUpdate payload, reusing the SAME `stats` table already in
    hand. HandlerConditionCache (below) remembers, per TRACKED K9
    CITIZENID (never per handler, never per source -- server ids are
    recycled), the last tags actually pushed and to whom, so an unchanged
    tick for an already-fine, already-seen K9 costs one table lookup and a
    handful of comparisons -- no network message at all.

    "GATE THE START, NEVER THE STOP": every path that can make this badge
    go stale sends an explicit, unconditional CLEAR (`{ visible = false,
    tags = {} }`), never merely "stops sending updates" and hopes the
    client infers the rest:
      1. Partnership ends (self-break, decertification, department
         change) -- self-healing: PushHandlerConditionUpdate's own "no
         active partnership" branch (below) re-resolves
         GetActivePartnerCitizenId(k9Citizenid) fresh on this K9's very
         next tick and clears the stale badge itself, bounded to one
         Config.Wellbeing.tickIntervalMs (default 5000ms). NOT a direct
         call from server/partnership.lua's DoBreakPartnership -- see that
         file's own FILE-TO-FILE CONTRACT note on why (a real reverse
         dependency would need a new name added to the repo-root
         .luacheckrc, a shared file this pass does not own).
      2. The K9 (not the handler) disconnects -- handled in the
         playerDropped handler below: TickWellbeing's own GetPlayers()
         loop will simply never visit that citizenid again this session,
         so nothing else would ever fire the clear for them.
      3. The handler disconnects -- no explicit push needed (nobody there
         to receive one); PushHandlerConditionUpdate's own "handler not
         currently online" branch leaves the cache alone so a LATER
         reconnect (a new resolved source id) forces a fresh push rather
         than silently relying on a tagsKey match that could otherwise
         suppress the very first update a returning handler was ever meant
         to see.
      4. Every wellbeing stat system switched off at once -- the one shape
         TickWellbeing itself is never even called for (see the
         CreateThread loop below). ClearAllHandlerConditionBadges covers
         this from that loop's own `else` branch, the one iteration that
         would otherwise do nothing at all.
    ======================================================================

    ======================================================================
    DATABASE PERSISTENCE (this pass, coder-backend) -- closes a real,
    confirmed production gap: this file's own header, for as long as this
    file has existed, claimed a K9 who logs off tired stays tired "on
    reconnect within the same server session" -- true, but nothing ever
    made it true ACROSS a restart, because `WellbeingStats` had genuinely
    never been written to a database at all. A nightly restart (or a
    crash) silently reset every online K9's fatigue/mood/fearStress/
    injury/hunger/thirst to fresh-and-uninjured, every time, with no
    config flag, no log line and no player-visible warning that this was
    happening. Fixed here by routing through server/datastore.lua's
    `K9Store` (this file's own established convention already requires --
    "THE ONLY PLACE IN THIS RESOURCE THAT MAY NAME A `k9_*` TABLE OR CALL
    `MySQL.*` DIRECTLY" -- see that file's own header), never a direct SQL
    call from this file.

    FOUR DESIGN DECISIONS, IN THE ORDER THEY HAD TO BE MADE:

    1. WHEN TO WRITE. Every-tick (every `TICK_INTERVAL_MS`, per online K9)
       was rejected outright -- this file's own tick already fires for
       every online K9 every 5 real seconds by default; a real UPDATE per
       K9 per tick is a write rate this resource has never asked a
       database to sustain anywhere else. Write-on-disconnect-only was
       ALSO rejected -- it loses every single stat change since the last
       clean disconnect the moment this resource crashes or the host
       power-cycles, which is exactly the scenario persistence exists to
       protect against; a design that only survives a graceful stop is not
       meaningfully better than not persisting at all. THE SHAPE CHOSEN
       mirrors this resource's own two already-established, materially
       different precedents, picked apart rather than copied wholesale:
       server/progression.lua's AwardXP persists a DELTA immediately, on
       every discrete XP-earning EVENT (a real, comparatively rare
       occurrence, cheap to persist eagerly) -- wellbeing's six stats have
       no equivalent "event," they drift continuously every tick, so
       eager-persist-every-change would mean eager-persist-every-tick,
       the exact rate already rejected above. server/webhook.lua's own
       FlushQueue is the closer precedent: a small, cheap, PERIODIC
       `CreateThread(function() while true do Wait(batchIntervalMs) ...
       end end)` flush loop, decoupled from whatever cadence actually
       produces the data. Applied here as a DIRTY FLAG (`stats.dirty`,
       set true the instant any of the six persisted values changes --
       every tick a feature is on, AND at each of the eight explicit
       action handlers: petK9/feedK9/calmDownK9/feedK9Hunger/giveK9Water/
       drinkFromBowl/RestoreInjury/the relayDamageEvent Mood+Injury decay)
       plus a PERIODIC FLUSH (`Config.Wellbeing.Persistence.flushIntervalMs`,
       default 60000ms -- twelve ticks' worth of drift batched into one
       write, not one write per drift) plus a WRITE ON DISCONNECT
       (`FlushWellbeingEntryNow`, called from the `playerDropped` handler
       below, for exactly the reason write-on-disconnect-only was
       rejected as the ONLY mechanism, not as a WORTHLESS one: it closes
       the specific, common "logged off normally, resource restarted
       before the next periodic flush" gap the periodic flush alone would
       otherwise leave up to `flushIntervalMs` wide). Together: a crash
       loses at most `flushIntervalMs` of drift for a K9 who never
       disconnected cleanly, and effectively nothing for one who did --
       never the whole session, and never a write rate this file's own
       tick cadence would make expensive.

       A FAILED WRITE NEVER LOSES THE CHANGE SILENTLY: `dirty` is cleared
       ONLY on a confirmed-successful `K9Store.Wellbeing_Upsert` call
       (pcall-wrapped; a thrown error OR an explicit `false` return both
       count as failure) -- a failing write leaves `dirty` untouched, so
       the NEXT periodic flush (or a later disconnect) retries the exact
       same row rather than the change being silently dropped the moment
       one write attempt fails.

    2. WHAT HAPPENS ON LOAD -- FREEZE, NEVER A CATCH-UP DECAY. A returning
       player's row comes back with whatever was last flushed; real time
       has passed since then, and TickWellbeing has NO concept of
       "elapsed wall-clock time since last tick" to begin with -- its own
       `dtSeconds` is a FIXED `TICK_INTERVAL_MS / 1000`, never a measured
       gap, because every existing per-tick decay/regen amount is already
       defined as "this much per tick," not "this much per second," and
       every tick this file has ever run assumes the K9 it is ticking was
       online for the whole preceding interval. An offline K9 is, and
       always has been, simply never ticked at all -- `TickWellbeing`'s
       own loop only ever iterates `GetPlayers()`, so a citizenid with no
       corresponding connected player accrues zero decay for however long
       it stays offline, restart or no restart. APPLYING a catch-up decay
       proportional to real elapsed offline time on load would not be
       "more accurate," it would be a NEW behaviour this file has never
       had and directly the trap this task named: a K9 left offline for
       two real weeks would come back to `decayPerTick * (two weeks worth
       of ticks)` of accumulated Hunger/Thirst loss -- arithmetically
       enough to blow through 0 and clamp there many times over, i.e. a
       guaranteed-starving dog on every single return from a long break,
       with no way for the returning player to have prevented it. FREEZE
       is therefore not a compromise made to dodge that trap -- it is the
       ONLY choice that keeps "an offline K9 does not decay" true in the
       one new case (offline-across-a-restart) this pass adds, exactly as
       it was already true in the case that already existed (offline-
       within-a-session). No new code enforces this; it falls out
       naturally from loading the six numbers as-is and never touching
       them again until the next real tick this citizenid is actually
       online for.

       THE FOUR TIMER-WINDOW FIELDS ARE DELIBERATELY NEVER PERSISTED.
       `distractedUntil`/`hesitatingUntil`/`hesitationEpisodeStartedAt`/
       `injuryDeathEpisodeStartedAt` are `GetGameTimer()`-relative
       (process-uptime) timestamps, not wall-clock ones -- correct for
       surviving an ordinary disconnect/reconnect WITHIN one continuously-
       running process (this header's own category-1 note above already
       explains why: the clock itself never stops just because a player
       disconnects), but meaningless the instant the PROCESS restarts,
       since `GetGameTimer()` resets to a small value near zero on a fresh
       boot. Persisting one of these verbatim and reloading it after a
       restart would compare a large, stale, OLD-process timestamp against
       a freshly-small NEW-process `GetGameTimer()` read -- `hesitatingUntil
       > now` could then read `true` for what would appear, in real time,
       to be an absurdly long stretch after the restart, i.e. exactly the
       "comes back frozen in a state they cannot recover from" trap this
       task separately warned about, just for a different stat than
       Hunger/Thirst. All four are short, already-bounded windows (seconds
       to low minutes -- `HESITATION_MAX_CONTINUOUS_MS` bounds the longest
       of them), never a magnitude a player accumulates and keeps -- so a
       returning row always reloads all four as `0` (inactive), the exact
       same "category 2, transient, ped-instance-scoped" treatment this
       header already established for `lastCoords`/
       `injuryDeathEpisodeStartedAt` on an ordinary reconnect, now extended
       to a restart for the same reason: correctly clearing a short window
       early is never worse than what a same-process reconnect already
       does today, and is strictly safer than carrying a stale value
       forward.

    3. WHAT HAPPENS WHEN THE ROW DOES NOT EXIST -- first-ever login for
       this citizenid, or a genuinely fresh install. `K9Store.Wellbeing_Get`
       mirrors `MySQL.single.await`'s own contract (nil = no row), and
       `EnsureStats` treats that nil exactly the same as
       `WellbeingPersistenceAvailable()` being false: it falls through to
       the SAME hardcoded-default construction this function has always
       used (fatigue/mood/injury/hunger/thirst at each stat's own `max`,
       fearStress at 0, every timer field at 0). This is not merely
       "similar" to the pre-this-pass behaviour -- it is the IDENTICAL code
       path, unchanged, so a player can never observe any difference
       between "no database at all," "database on, but no row yet," and
       "this pass never shipped" -- the three cases that must all look the
       same per this task's own explicit instruction.

    4. EVICTION, ONLY AFTER PERSISTENCE WORKS. A `WellbeingStats` entry is
       dropped from memory only when BOTH `stats.dirty == false` (every
       change is confirmed safely on disk -- or there was never a change
       to lose in the first place) AND its citizenid has been offline for
       at least `Config.Wellbeing.Persistence.evictAfterMs`. Reuses
       server/cooldowns.lua's proven `NewCooldown()`/`:StartSweep()`
       machinery (16 existing trackers, not a new mechanism) for the
       actual "has this been offline long enough" bookkeeping via a
       dedicated `WellbeingLastSeenOnline` tracker, touched once per tick
       per online tracked citizenid (and once at `EnsureStats` creation/
       load time, so a citizenid that logs off before its very first tick
       still has a real baseline to measure "offline since" against,
       rather than reading as "never touched, therefore immediately
       stale"). ONE HONEST LIMITATION, WORTH STATING PLAINLY: `StartSweep`'s
       own `isStaleFn` contract is `fun(now, loggedAt): boolean` -- by
       design, matching every one of its other 16 call sites, none of
       which ever needed the KEY being evaluated, only the elapsed time --
       so it cannot itself reach into a SIBLING table (`WellbeingStats`) to
       delete a specific citizenid's entry; `StartSweep` bounds
       `WellbeingLastSeenOnline`'s OWN table directly and exactly as
       documented, while `WellbeingStats`'s own eviction is driven by a
       lightweight check folded into the ALREADY-EXISTING tick thread
       (`EvictStaleWellbeingEntries`, gated to run only once every
       `evictSweepIntervalMs` via a plain "next-due" timestamp, never a
       second `CreateThread`), using `WellbeingLastSeenOnline.IsOnCooldown`
       as the single shared staleness oracle so the two tables' eviction
       decisions can never independently drift out of agreement about what
       "stale" means.

    FAIL DIRECTION, STATED EXPLICITLY: every `K9Store.Wellbeing_*` call
    site in this file is soft-guarded (`WellbeingPersistenceAvailable()`)
    and pcall-wrapped. A database that is unavailable, a query that fails,
    or (kept as permanent defense-in-depth, not because it currently
    describes this resource — server/datastore.lua carries both accessors
    as of the follow-up change that closed the FILE-TO-FILE CONTRACT note
    above) a server/datastore.lua missing one or both of these accessors
    all degrade to EXACTLY today's memory-only behaviour (every gameplay
    action still works; nothing crashes; nothing is evicted while
    unconfirmed) -- never a broken wellbeing system, and never a crashed
    tick. This mirrors `Config.Database.enabled = false`'s own resource-
    wide promise (config.lua's own header on that flag) applied to this
    one file's own new dependency.
    ======================================================================
]]

-- WellbeingStats[citizenid] = {
--     fatigue, mood, fearStress, injury,     -- 0..Config.Wellbeing.<Stat>.max
--     hunger, thirst,                         -- 0..Config.Wellbeing.<Stat>.max -- PERSISTED, same category as the four above (this pass, coder-backend)
--     distractedUntil, hesitatingUntil,       -- GetGameTimer() ms timestamps, 0 = inactive
--     hesitationEpisodeStartedAt,             -- GetGameTimer() ms, 0 = not currently in a
--                                              -- continuous at/above-threshold episode -- see
--                                              -- HESITATION_MAX_CONTINUOUS_MS below (coder-security,
--                                              -- this pass) for why this exists.
--     lastCoords,                             -- vector3? -- previous tick's sample, for Fatigue's sprint-speed calc
--     injuryDeathEpisodeStartedAt,            -- GetGameTimer() ms, 0 = not currently in a candidate
--                                              -- continuous at/below-PED_DEAD_HEALTH_THRESHOLD episode --
--                                              -- see this file's header, STUCK-K9 SOFTLOCK FIX item 2
--                                              -- (both FOLLOW-UP notes) for the full history, and
--                                              -- MIN_DEATH_EPISODE_DURATION_MS below for the qualifying
--                                              -- duration this field's episode length is judged against.
--     dirty,                                  -- boolean -- PERSISTENCE (this pass, coder-backend). true
--                                              -- whenever any of the six persisted stats above has
--                                              -- changed since the last CONFIRMED-successful
--                                              -- K9Store.Wellbeing_Upsert write; cleared only on that
--                                              -- confirmation, never merely on attempting one. See this
--                                              -- file's header "DATABASE PERSISTENCE" section for the
--                                              -- full write/eviction design this field drives. A THIRD
--                                              -- category, not #1 or #2 below -- it is never itself
--                                              -- persisted (there is no column for it; it exists only to
--                                              -- decide WHETHER to persist the others) and never reset on
--                                              -- disconnect/model-switch the way category 2 is (an
--                                              -- unflushed change must survive both).
--
-- TWO DIFFERENT CATEGORIES OF FIELD LIVE IN THIS SAME TABLE -- read this
-- before adding a new one, since conflating them is exactly the bug class a
-- regression pass found here once already:
--   1. PERSISTED VALUES (fatigue/mood/fearStress/injury, and the absolute
--      GetGameTimer()-timestamp fields distractedUntil/hesitatingUntil/
--      hesitationEpisodeStartedAt): meant to survive a disconnect --
--      "a K9 who logs off tired should still be tired on reconnect" is this
--      file's own established rule, and the timestamp fields specifically
--      stay correct across a disconnect for a different, non-obvious reason
--      -- GetGameTimer() is a process-uptime clock that keeps advancing
--      while a player is offline, so a stored absolute future timestamp is
--      still a meaningful comparison against a LATER GetGameTimer() read
--      after they reconnect, exactly as if they had stayed connected the
--      whole time. Never reset these on playerDropped/a model switch.
--   2. TRANSIENT, SESSION/PED-INSTANCE-SCOPED OBSERVATIONS (lastCoords,
--      injuryDeathEpisodeStartedAt): a snapshot of something true about
--      THIS SPECIFIC, CURRENTLY-LIVE ped handle as of the last tick this
--      file actually observed it -- meaningless the instant that ped handle
--      stops being the one backing this citizenid (a disconnect, or a
--      switch away from a K9 model while still connected), because the
--      NEXT ped handle this citizenid is ever attached to (a reconnect's
--      fresh spawn, or a switch back to a K9 model) carries no relationship
--      to whatever the old one's last-observed state was. lastCoords was
--      already reset on both paths from this file's very first version of
--      this logic (the "bogus sprint-speed on reconnect/model-swap" fix).
--      injuryDeathEpisodeStartedAt's PREDECESSOR (a plain boolean,
--      `injuryDiedWhileTracked`) was NOT reset on either path when it was
--      first added -- a regression pass found this let a K9 disconnect
--      while dead and reconnect to a fresh, genuinely-alive ped, which this
--      file's own tick loop then misread as a real dead-to-alive TRANSITION
--      and paid out a full deathRespawnRestoreAmount for free, no revive/
--      ambulance/medkit/delay required, repeatably. FIXED: both reset sites
--      below (the model-switch-away branch inside TickWellbeing, and the
--      playerDropped handler) now clear injuryDeathEpisodeStartedAt back to
--      0 alongside lastCoords -- same category, same fix shape, applied
--      consistently rather than only at the one site a regression test
--      happened to exercise first. NOTE THIS IS A TIMESTAMP, NOT A BOOLEAN,
--      unlike its predecessor -- "reset" for this field specifically means
--      set to 0 (its own "inactive" sentinel), never `false`/`nil`; see
--      MIN_DEATH_EPISODE_DURATION_MS's own doc comment for why a second,
--      independent bug (paying out on ANY brief health crossing, not a
--      genuine down episode) required this field to become a duration
--      measurement rather than stay a plain flag. A future field belongs in
--      category 2, and needs the SAME reset at BOTH sites, if it is ever a
--      snapshot of "what did I last see this ped doing" rather than an
--      absolute clock comparison or one of the four genuinely-persisted
--      stats themselves.
-- }
local WellbeingStats = {}

-- HandlerConditionCache[k9Citizenid] = { handlerCitizenid, lastHandlerSrc,
-- tagsKey } -- see this file's own "HANDLER CONDITION BADGE" header
-- section for the full design. ONE entry per K9 citizenid that currently
-- has a VISIBLE (non-cleared) condition badge showing on some handler's
-- screen; deleted the instant that badge is cleared for any reason.
-- Bounded by however many online K9s currently have an online, partnered
-- handler watching a non-default condition -- never "every player ever
-- seen," unlike WellbeingStats above.
local HandlerConditionCache = {}



--- VALIDATED TICK INTERVAL (audit follow-up — same shape server/defense.lua's
--- pollIntervalMs fix and server/combat.lua's positionSampleWindowMs fix
--- both address in their own files; see server/cooldowns.lua's header
--- ADDENDUM for the general writeup). `Config.Wellbeing.tickIntervalMs` is a
--- raw, operator-editable Config field consumed in THREE places in this
--- file: this line's own MIN_DEATH_EPISODE_DURATION_MS arithmetic
--- immediately below (unconditional, top-level, file-load time), the
--- `Wait(...)` call at the top of the shared tick thread further down (a
--- bare `Wait()` that never goes through NewCooldown), and TickWellbeing's
--- own `dtSeconds` calculation. None of the three previously validated it.
--- A non-numeric/non-positive value here would throw immediately at THIS
--- line — a top-level arithmetic op reached unconditionally at file-load
--- time, before a single Config.Features flag is even checked — aborting
--- server/wellbeing.lua's own load from this line onward and taking
--- RestoreInjury/IsHesitating/IsDistracted/IsFlashbangImmune (every one of
--- this file's resource-global exports, all defined below this point) down
--- with it, silently disabling Fatigue/Mood/FearStress/Distraction/Injury
--- resource-wide over one operator typo. Resolved with
--- ResolveConfiguredThresholdMs (CLAMP AND WARN, never abort) rather than a
--- hard `assert`, for the identical reason cooldowns.lua's own header
--- ADDENDUM gives: this value is reached unconditionally at this file's own
--- top-level load, so an `error()` here would be the exact "single mis-set
--- Config number reaches into an unrelated termination/cleanup path"
--- disaster that ADDENDUM already found once in server/combat.lua. Same
--- fallback (5000ms) as config.lua's own shipped default for this field.
--- All three consumers below now read this SAME resolved local, so they can
--- never disagree with each other about what interval is actually in
--- effect.
local TICK_INTERVAL_MS = ResolveConfiguredThresholdMs(Config.Wellbeing.tickIntervalMs, 5000, 'Config.Wellbeing.tickIntervalMs')


--- @param value number
--- @param min number
--- @param max number
--- @return number
local function Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end


-- ======================================================================
-- DATABASE PERSISTENCE (this pass, coder-backend) -- see this file's own
-- header section of the same name for the full design writeup (when to
-- write, what happens on load, the missing-row case, and eviction). What
-- follows is the mechanism; the header has the reasoning.
-- ======================================================================

--- true only when server/datastore.lua has ACTUALLY grown the two
--- accessors this file needs -- never assumed from `K9Store` merely
--- existing (every OTHER K9Store consumer in this resource loads before a
--- resource-start race could matter; this file makes no such assumption
--- and re-checks fresh on every call, cheaply, rather than caching a
--- boot-time snapshot). Mirrors this file's own already-established
--- `type(RestoreInjury) == 'function'`-style guard for "a genuine new
--- cross-file dependency, no consumer exists yet" -- applied here to a
--- PRODUCER (K9Store) this file depends on, rather than a consumer that
--- depends on this file.
--- @return boolean
local function WellbeingPersistenceAvailable()
    return type(K9Store) == 'table'
        and type(K9Store.Wellbeing_Get) == 'function'
        and type(K9Store.Wellbeing_Upsert) == 'function'
end

--- Resolved ONCE at this file's own load time -- same timing/reasoning as
--- TICK_INTERVAL_MS/MIN_DEATH_EPISODE_DURATION_MS above: every consumer
--- below (the flush thread, the eviction sweep, EnsureStats' own load
--- path) must agree on the same numbers, never independently re-derive
--- them. CONFIG-DEFENSIVE, and SILENT when the whole sub-block is simply
--- ABSENT -- exactly GetResolvedHungerThirstConfig's own "an inert
--- default is never an activation" convention (this file's header), not
--- TICK_INTERVAL_MS's own "always warn, this field has shipped for a long
--- time" one: `Config.Wellbeing.Persistence` is BRAND NEW, like
--- Config.Wellbeing.Hunger/.Thirst, and this file does not own adding it
--- to every server's config.lua. A server whose config.lua has not yet
--- picked it up must not print three loud warnings on every single boot
--- about a sub-block nobody has had the chance to add yet -- that is
--- precisely the "one Config typo/absence takes an unrelated feature's
--- console output down with it" outcome this file's own established
--- convention refuses to repeat. CLAMP-AND-WARN only applies once the
--- sub-block genuinely EXISTS (a real operator edit with a bad individual
--- field) -- ResolveConfiguredThresholdMs is only ever reached in that
--- branch, never against a synthesized empty table.
local PersistenceCfg = (function()
    if type(Config.Wellbeing.Persistence) ~= 'table' then
        return { enabled = true, flushIntervalMs = 60000, evictAfterMs = 900000, evictSweepIntervalMs = 300000 }
    end
    local raw = Config.Wellbeing.Persistence
    return {
        -- Only a literal `false` opts out -- a missing/unrecognized value
        -- means "on," the same fail-safe-to-today's-behaviour default
        -- Config.Database.enabled's own doc comment establishes.
        enabled              = raw.enabled ~= false,
        flushIntervalMs      = ResolveConfiguredThresholdMs(raw.flushIntervalMs, 60000, 'Config.Wellbeing.Persistence.flushIntervalMs'),
        evictAfterMs         = ResolveConfiguredThresholdMs(raw.evictAfterMs, 900000, 'Config.Wellbeing.Persistence.evictAfterMs'),
        evictSweepIntervalMs = ResolveConfiguredThresholdMs(raw.evictSweepIntervalMs, 300000, 'Config.Wellbeing.Persistence.evictSweepIntervalMs'),
    }
end)()

--- citizenid -> GetGameTimer() ms of the last time this citizenid was
--- confirmed online/tracked -- touched once at EnsureStats' own
--- creation/load time (so a citizenid that disconnects before its very
--- first tick still has a real baseline, never reading as "never touched,
--- therefore immediately stale") and once per tick thereafter from
--- TickWellbeing's own per-K9 loop, for as long as that citizenid stays
--- online. Deliberately NOT `:RegisterPlayerDropped()` -- keyed by
--- CITIZENID, a durable identity, never a raw/recycled server id (this
--- file's own established rule); StartSweep is the correct cleanup
--- mechanism for exactly that shape, per server/cooldowns.lua's own doc
--- comment on when to use one over the other. See this file's header
--- "DATABASE PERSISTENCE" section, point 4, for why `WellbeingStats`
--- ITSELF cannot be evicted directly from inside `:StartSweep` (its own
--- `isStaleFn` contract never receives the key) and instead uses this
--- tracker's own `IsOnCooldown` as the shared staleness oracle from
--- EvictStaleWellbeingEntries below.
local WellbeingLastSeenOnline = NewCooldown()
WellbeingLastSeenOnline.StartSweep(PersistenceCfg.evictSweepIntervalMs, function(now, loggedAt)
    return (now - loggedAt) >= PersistenceCfg.evictAfterMs
end)

--- The exact row shape K9Store.Wellbeing_Upsert expects -- the six
--- PERSISTED magnitude stats ONLY. See this file's header "DATABASE
--- PERSISTENCE" point 2 for why the four timer-window fields
--- (distractedUntil/hesitatingUntil/hesitationEpisodeStartedAt/
--- injuryDeathEpisodeStartedAt) are deliberately excluded -- they are
--- GetGameTimer()-relative (process-uptime), not wall-clock, and
--- meaningless (worse: actively misleading) across a restart.
--- @param stats table
--- @return table row
local function PersistableRowOf(stats)
    return {
        fatigue = stats.fatigue,
        mood = stats.mood,
        fearStress = stats.fearStress,
        injury = stats.injury,
        hunger = stats.hunger,
        thirst = stats.thirst,
    }
end

--- One flush pass: UPSERTs every currently-dirty citizenid's row and
--- clears its `dirty` flag ONLY on a confirmed-successful write -- a
--- failed write (a thrown error, or an explicit `false` return) leaves
--- `dirty` untouched so the NEXT flush (or a later disconnect) retries it
--- rather than the change being silently lost. A no-op entirely when
--- persistence is unavailable -- see WellbeingPersistenceAvailable's own
--- doc comment; this file's tick/action-handler logic never depends on
--- this function having done anything.
local function FlushDirtyWellbeingStats()
    if not PersistenceCfg.enabled or not WellbeingPersistenceAvailable() then return end
    for citizenid, stats in pairs(WellbeingStats) do
        if stats.dirty then
            local ok, resultOrErr = pcall(K9Store.Wellbeing_Upsert, citizenid, PersistableRowOf(stats))
            if ok and resultOrErr ~= false then
                stats.dirty = false
            else
                print(('[qbx_k9unit] wellbeing.lua: persistence write failed for citizenid %s -- will retry on the next flush (%s)'):format(citizenid, tostring(resultOrErr)))
            end
        end
    end
end

--- Immediate, single-citizenid flush -- called from the `playerDropped`
--- handler below so a clean disconnect does not have to wait up to
--- `Config.Wellbeing.Persistence.flushIntervalMs` for its last change to
--- reach disk (see this file's header "DATABASE PERSISTENCE" point 1 for
--- the full "why both a periodic flush AND a write on disconnect"
--- writeup). Also what makes eviction of a just-disconnected citizenid
--- possible as soon as `evictAfterMs` elapses, rather than only after the
--- next periodic flush happens to catch it.
--- @param citizenid string
local function FlushWellbeingEntryNow(citizenid)
    local stats = WellbeingStats[citizenid]
    if not stats or not stats.dirty then return end
    if not PersistenceCfg.enabled or not WellbeingPersistenceAvailable() then return end
    local ok, resultOrErr = pcall(K9Store.Wellbeing_Upsert, citizenid, PersistableRowOf(stats))
    if ok and resultOrErr ~= false then
        stats.dirty = false
    else
        print(('[qbx_k9unit] wellbeing.lua: persistence write failed on disconnect for citizenid %s -- kept in memory (never evicted while dirty) so a later flush/reconnect can still save it (%s)'):format(citizenid, tostring(resultOrErr)))
    end
end

--- Bounds `WellbeingStats`' own size, called from the ALREADY-EXISTING
--- tick thread below (no second CreateThread) but internally gated to
--- actually scan at most once every `evictSweepIntervalMs`, via a plain
--- "next-due" timestamp -- an unconditional `pairs(WellbeingStats)` walk
--- every single `TICK_INTERVAL_MS` would be needless work on every tick
--- for a table that, by design, only ever changes slowly (an entry is
--- only ever added by EnsureStats or removed here). Never evicts a
--- citizenid with an unconfirmed change (`stats.dirty`) or one
--- `WellbeingLastSeenOnline` still considers recently online -- see this
--- file's header "DATABASE PERSISTENCE" point 4 for why `IsOnCooldown` is
--- the correct, shared oracle for "stale" here. This also correctly
--- handles a key `:StartSweep` on that SAME tracker has ALREADY deleted
--- for exceeding this SAME threshold: `IsOnCooldown` reads a missing key
--- as "never touched" (not on cooldown, i.e. stale), which is the same
--- eviction verdict this function needs -- reached via a different,
--- already-correct code path, never a false "not stale, keep."
--- @param now number
local nextEvictionSweepAt = 0
local function EvictStaleWellbeingEntries(now)
    if now < nextEvictionSweepAt then return end
    nextEvictionSweepAt = now + PersistenceCfg.evictSweepIntervalMs

    -- Never evicts without confirmed persistence, AND respects an
    -- operator's explicit `Persistence.enabled = false` (a citizenid whose
    -- last change was never flushable in the first place must not be
    -- dropped from memory either -- "administratively disabled" means
    -- behave as if this whole feature does not exist, not "still evict,
    -- just never flush").
    if not PersistenceCfg.enabled or not WellbeingPersistenceAvailable() then return end
    for citizenid, stats in pairs(WellbeingStats) do
        if not stats.dirty and not WellbeingLastSeenOnline.IsOnCooldown(citizenid, PersistenceCfg.evictAfterMs) then
            WellbeingStats[citizenid] = nil
        end
    end
end

--- Returns the citizenid's stat entry, creating one on first reference
--- THIS SESSION. A citizenid not yet cached in `WellbeingStats` (a
--- returning player, or one whose entry was evicted -- see
--- EvictStaleWellbeingEntries above) first tries a real database load
--- (`WellbeingPersistenceAvailable()`-guarded); only when that is
--- unavailable OR genuinely returns no row does this fall back to the
--- SAME hardcoded-default construction this function has always used:
--- Fatigue/Mood/Injury default to their own `max` (a K9 starts fresh, not
--- exhausted/miserable/injured); FearStress defaults to 0 (calm);
--- distractedUntil/hesitatingUntil/hesitationEpisodeStartedAt/
--- injuryDeathEpisodeStartedAt default to 0 (inactive) -- see this file's
--- header "DATABASE PERSISTENCE" point 3 for why the two branches below
--- must, and do, produce an identical result for the "no row" case, with
--- no special case a player could ever notice.
--- @param citizenid string
--- @return table stats
local function EnsureStats(citizenid)
    local stats = WellbeingStats[citizenid]
    if stats then return stats end

    -- CONFIG-DEFENSIVE, same reasoning as every other Config.Wellbeing.Hunger/
    -- .Thirst read in this file: this file does not own config.lua and
    -- these subtables may not exist yet on a given server.
    local hungerMax = (type(Config.Wellbeing.Hunger) == 'table' and tonumber(Config.Wellbeing.Hunger.max)) or 100
    local thirstMax = (type(Config.Wellbeing.Thirst) == 'table' and tonumber(Config.Wellbeing.Thirst.max)) or 100

    -- PERSISTENCE LOAD (this pass) -- see this file's header "DATABASE
    -- PERSISTENCE" point 3. A throw here (an unexpected K9Store/DB error)
    -- degrades to `loadedRow = nil` (the fresh-default branch below),
    -- never propagates out of EnsureStats -- a load failure must never
    -- break every OTHER wellbeing feature for this citizenid.
    --
    -- BOOT-ORDER SETTLEMENT (boot-order-race audit, this pass -- the same
    -- fix already shipped for server/main.lua/server/certtiers.lua/
    -- server/partnership.lua/server/progression.lua/server/xptiers.lua/
    -- server/k9profiles.lua/server/permissions.lua/
    -- server/permissionkeycatalog.lua/server/equipmentshop.lua; this file
    -- was the one real gap left in server/datastore.lua's own authoritative
    -- caller list -- see K9Store.WaitForSchemaCheckToSettle's own doc
    -- comment there, now updated to name this file too). The SELECT inside
    -- K9Store.Wellbeing_Get names only six columns -- narrower than the
    -- full column set server/datastore.lua's own EXPECTED_TABLE_COLUMNS
    -- checks k9_wellbeing against -- so without this, a citizenid's FIRST
    -- reference this session could run that narrower SELECT against a
    -- foreign `k9_wellbeing` table the full probe would correctly reject as
    -- a collision, during the one window before that probe's own yielding
    -- query has returned. THE CONCRETE TRIGGER, traced end to end: a K9
    -- handler's own ped model is world state, not Lua state -- it survives
    -- a `restart qbx_k9unit` untouched. client/wellbeing.lua's own
    -- on-demand-snapshot thread checks `IsOwnModelK9()` on its very FIRST
    -- iteration, with no leading Wait, and calls
    -- 'qbx_k9unit:server:getWellbeingSnapshot' immediately the instant that
    -- first check reads true -- which it does, immediately, for every
    -- player who was already K9-modeled at the moment this resource
    -- restarted. That callback reaches this exact line, well before
    -- TickWellbeing's own shared thread has even taken its first
    -- `Wait(TICK_INTERVAL_MS)`. Silently trusting a stranger's row here
    -- would mean displaying (and, once dirtied, persisting over) another
    -- resource's own data as this citizenid's real wellbeing stats --
    -- wrong data, not a crash, and the harder of the two failure modes to
    -- notice. PAID AT MOST ONCE PER CITIZENID PER SESSION (this whole
    -- branch only runs on a genuine cache miss -- see this function's own
    -- guard at its own top) and AT MOST ONCE, EVER, PER BOOT
    -- (K9Store.WaitForSchemaCheckToSettle's own SCHEMA_CHECK_SETTLED latch
    -- -- every reference after this boot's determination is final returns
    -- instantly, true, paying no real wait at all). SOFT-GUARDED
    -- (`type(K9Store.WaitForSchemaCheckToSettle) == 'function'`), matching
    -- this exact function's own already-established "genuine cross-file
    -- dependency, no consumer exists yet" idiom for
    -- K9Store.Wellbeing_Get/Wellbeing_Upsert just above -- an older
    -- server/datastore.lua that predates this accessor simply behaves
    -- exactly as this file already did before this pass, never a new hang.
    -- On a `false` return (the probe genuinely had not settled within the
    -- wait budget), this skips the query entirely and falls straight
    -- through to the SAME fresh-default branch below already used for "no
    -- row"/"a thrown error"/"database off by config" -- per this function's
    -- own header "FREEZE, NEVER A CATCH-UP DECAY" and this whole file's
    -- fail-closed convention, an unsettled/unknown schema state must
    -- collapse to that identical fresh-default outcome, never a new fourth
    -- one. This can never be used to reset an ALREADY-LOADED citizenid's
    -- stats: WellbeingStats[citizenid] is set once, immediately below, and
    -- every later EnsureStats call for the same citizenid this session
    -- short-circuits at this function's own top, long before this branch --
    -- a relog/character-switch/reconnect that lands on a recycled server id
    -- reaches this branch again only via a genuine eviction-and-reload (see
    -- EvictStaleWellbeingEntries above), never merely by disconnecting.
    local loadedRow = nil
    if WellbeingPersistenceAvailable() then
        local schemaSettled = type(K9Store.WaitForSchemaCheckToSettle) ~= 'function' or K9Store.WaitForSchemaCheckToSettle()
        if schemaSettled then
            local ok, rowOrErr = pcall(K9Store.Wellbeing_Get, citizenid)
            if ok then
                loadedRow = rowOrErr
            else
                print(('[qbx_k9unit] wellbeing.lua: K9Store.Wellbeing_Get threw for citizenid %s -- degrading to a fresh in-memory default for this session (%s)'):format(citizenid, tostring(rowOrErr)))
            end
        else
            print(('[qbx_k9unit] wellbeing.lua: the schema-collision check had not finished within its wait budget -- creating a fresh in-memory default for citizenid %s (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. This citizenid\'s next reference after the check settles (or after this in-memory entry is evicted and reloaded) will pick up any real persisted row.'):format(citizenid))
        end
    end

    if loadedRow then
        -- FREEZE, NEVER A CATCH-UP DECAY (this file's header point 2) --
        -- every value below is the exact number last flushed, clamped
        -- defensively against this server's CURRENT config maxima (in
        -- case a max was lowered, or a row is corrupt) but never adjusted
        -- for elapsed offline time. The four timer-window fields are
        -- deliberately NOT read from `loadedRow` at all (PersistableRowOf
        -- never wrote them) -- always 0/inactive on a load, same as a
        -- fresh citizenid, for the GetGameTimer()-is-process-uptime reason
        -- this file's header point 2 explains in full.
        stats = {
            fatigue = Clamp(tonumber(loadedRow.fatigue) or Config.Wellbeing.Fatigue.max, 0, Config.Wellbeing.Fatigue.max),
            mood = Clamp(tonumber(loadedRow.mood) or Config.Wellbeing.Mood.max, 0, Config.Wellbeing.Mood.max),
            fearStress = Clamp(tonumber(loadedRow.fearStress) or 0, 0, Config.Wellbeing.FearStress.max),
            injury = Clamp(tonumber(loadedRow.injury) or Config.Wellbeing.Injury.max, 0, Config.Wellbeing.Injury.max),
            hunger = Clamp(tonumber(loadedRow.hunger) or hungerMax, 0, hungerMax),
            thirst = Clamp(tonumber(loadedRow.thirst) or thirstMax, 0, thirstMax),
            distractedUntil = 0,
            hesitatingUntil = 0,
            hesitationEpisodeStartedAt = 0,
            lastCoords = nil,
            injuryDeathEpisodeStartedAt = 0,
            dirty = false, -- matches what is on disk right now -- nothing to flush yet
        }
    else
        -- IDENTICAL to this function's own pre-persistence default
        -- construction -- see this file's header point 3 for why this
        -- must never visibly differ from "no database at all."
        stats = {
            fatigue = Config.Wellbeing.Fatigue.max,
            mood = Config.Wellbeing.Mood.max,
            fearStress = 0,
            injury = Config.Wellbeing.Injury.max,
            distractedUntil = 0,
            hesitatingUntil = 0,
            hesitationEpisodeStartedAt = 0,
            lastCoords = nil,
            injuryDeathEpisodeStartedAt = 0,
            hunger = hungerMax,
            thirst = thirstMax,
            dirty = false,
        }
    end

    WellbeingStats[citizenid] = stats
    -- PERSISTENCE (this pass) -- gives this citizenid a real "last seen
    -- online" baseline from the moment it exists in memory, so a
    -- disconnect before this citizenid's very first TickWellbeing pass
    -- still measures "offline since" from something real, never reading
    -- as "never touched, therefore immediately eligible for eviction."
    WellbeingLastSeenOnline.Touch(citizenid)
    return stats
end

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

-- ======================================================================
-- LIVE FEATURE FLAG PUSH (this pass -- closes a real, confirmed gap traced
-- from server/runtimecontrol.lua's own disclosed limitation, "It does not
-- push a live Config update to already-connected CLIENTS... reported as a
-- follow-up, not built here"). All five of this file's own Config.Features
-- flags are tiered `live` in that file specifically BECAUSE this file
-- re-checks each one fresh at the point of use, tick to tick -- but
-- client/wellbeing.lua's own move-rate composer (K9MoveRateModifiers.fatigue/
-- .injury/.mood) and its Injury sprint/jump block used to read ONLY that
-- CLIENT's own static Config.Features.<Name> copy, fixed at that client's
-- own resource start and never updated by a runtime tablet toggle -- so an
-- operator switching e.g. FatigueSystem off mid-session left every
-- already-connected, already-penalized K9 stuck at its last-applied
-- move-rate penalty forever (this file stops decaying/regenerating that
-- stat the instant the flag is false, so nothing was ever going to carry
-- it back across the threshold that would have cleared the modifier, and
-- the client had no way to learn the flag had changed at all) -- a control
-- that reports success while silently doing nothing, worse than one that
-- honestly requires a restart.
--
-- THE FIX, REUSING THE EXISTING CHANNEL RATHER THAN BUILDING A SECOND ONE
-- (client/featureblocks.lua's own header states this exact principle for
-- its unrelated per-person block channel; applied here to this file's own
-- already-existing per-tick push instead): `featureFlags` is piggybacked
-- onto the SAME `wellbeingUpdate` push / `getWellbeingSnapshot` on-demand
-- fetch this file already sends every tick to every connected K9 -- no new
-- event, no new network round trip, no new poll. Read FRESH off the live
-- `Config.Features` table at the exact moment each snapshot is built (never
-- captured once), so a runtime toggle is reflected on this K9's very next
-- snapshot -- within one `TICK_INTERVAL_MS` of a SetFeature/ResetFeature
-- call for an already-connected client, or immediately for a client whose
-- ped only just became K9-modeled (the on-demand fetch path). See
-- client/wellbeing.lua's own `LiveFeatureFlags` mirror and the explicit
-- reset branches in `ApplyMoveRateModifiers` for the client-side half of
-- this fix -- a flag reported here as false now REMOVES an in-flight
-- modifier immediately, rather than merely stopping it from being
-- reapplied.
--
-- LIVE WELLBEING TUNABLE PUSH (this pass -- "make the speed boost and
-- stamina numbers genuinely editable" task, extended by the owner to every
-- K9 stat). server/runtimecontrol.lua's TUNABLE_REGISTRY used to EXCLUDE
-- Fatigue.speedPenaltyThreshold/speedPenaltyMultiplier,
-- Mood.performancePenaltyThreshold/performancePenaltyMultiplier, and
-- Injury.sprintBlockThreshold/jumpBlockThreshold/speedPenaltyMultiplier for
-- the EXACT same reason `featureFlags` used to be missing: "every one of
-- these move-rate/input-block values is applied entirely by
-- client/movement.lua and client/wellbeing.lua reading their own
-- shared_scripts copy... a live dial this file cannot even confirm reaches
-- the client" (that exclusion comment's own words, now corrected). SAME FIX,
-- SAME CHANNEL, EXTENDED rather than duplicated: `wellbeingTunables` is a
-- second piggybacked table alongside `featureFlags` on this identical
-- push/fetch pair -- still no new event, no new round trip. Every field
-- below is read FRESH off the live `Config.Wellbeing.*` table at snapshot
-- time, so a server/runtimecontrol.lua SetTunable/ResetTunable call reaches
-- an already-connected K9 within one TICK_INTERVAL_MS, exactly like
-- featureFlags above. See client/wellbeing.lua's own `LiveWellbeingTunables`
-- mirror for the client-side half, and this file's own report for the
-- MID-EFFECT decision made for this class of value (deliberately DIFFERENT
-- from PursuitSprint's "keep the granted value" choice, and why that is
-- still not an inconsistency).
--- @param stats table
--- @return table snapshot -- a plain copy safe to hand to TriggerClientEvent/lib.callback
local function SnapshotOf(stats)
    return {
        fatigue = stats.fatigue,
        mood = stats.mood,
        fearStress = stats.fearStress,
        injury = stats.injury,
        -- HUNGER/THIRST (this pass, coder-backend) -- plain persisted
        -- numbers, already resolved by EnsureStats/TickWellbeing; nothing
        -- here reads raw Config, so no config-defensiveness guard is needed
        -- on these two lines specifically (see the wellbeingTunables entries
        -- further down for the ones that DO read raw Config).
        hunger = stats.hunger,
        thirst = stats.thirst,
        distractedUntil = stats.distractedUntil,
        hesitatingUntil = stats.hesitatingUntil,
        featureFlags = {
            FatigueSystem = Config.Features.FatigueSystem == true,
        },
        wellbeingTunables = {
            fatigueSpeedPenaltyThreshold     = Config.Wellbeing.Fatigue.speedPenaltyThreshold,
            fatigueSpeedPenaltyMultiplier    = Config.Wellbeing.Fatigue.speedPenaltyMultiplier,
            moodPerformancePenaltyThreshold  = Config.Wellbeing.Mood.performancePenaltyThreshold,
            moodPerformancePenaltyMultiplier = Config.Wellbeing.Mood.performancePenaltyMultiplier,
            injurySprintBlockThreshold       = Config.Wellbeing.Injury.sprintBlockThreshold,
            injuryJumpBlockThreshold         = Config.Wellbeing.Injury.jumpBlockThreshold,
            injurySpeedPenaltyMultiplier     = Config.Wellbeing.Injury.speedPenaltyMultiplier,
            -- NATIVE SPRINT STAMINA ASSIST -- see server/runtimecontrol.lua's
            -- TUNABLE_REGISTRY entry of the same config path for the full
            -- "why this is separate from sprintDecayPerTick" writeup.
            -- sprintDecayPerTick is deliberately NOT in this table (it is a
            -- pure server-internal decay rate TickWellbeing already reads
            -- fresh -- it never needs to reach a client at all); this field
            -- DOES, since client/wellbeing.lua is the one that actually
            -- calls RestorePlayerStamina.
            fatigueNativeStaminaRestorePercent = Config.Wellbeing.Fatigue.nativeStaminaRestorePercent,
            -- HUNGER/THIRST (this pass, coder-backend). CONFIG-DEFENSIVE,
            -- unlike every other line in this table: `Config.Wellbeing.Hunger`/
            -- `.Thirst` may not exist yet on a server whose config.lua has
            -- not landed them (this file's header explains why) --
            -- SnapshotOf is built every tick for ANY of the six flags being
            -- on, not just HungerThirstSystem, so an unguarded read here
            -- would crash a snapshot push for e.g. a MoodSystem-only server.
            -- Deliberately a light inline guard, NOT a
            -- GetResolvedHungerThirstConfig() call -- that function's own
            -- CLAMP-AND-WARN belongs strictly behind the
            -- Config.Features.HungerThirstSystem gate ("read at the point of
            -- activation"); this fallback is silent on purpose so a fully
            -- disabled/unconfigured HungerThirstSystem never prints a
            -- warning about a feature nobody has turned on.
            hungerSpeedPenaltyThreshold  = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger.lowThreshold or 30,
            hungerSpeedPenaltyMultiplier = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger.speedPenaltyMultiplier or 0.95,
            thirstSpeedPenaltyThreshold  = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst.lowThreshold or 30,
            thirstSpeedPenaltyMultiplier = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst.speedPenaltyMultiplier or 0.95,
        },
    }
end

--- @param source number
--- @return string? citizenid
local function ResolveCitizenid(source)
    local Player = exports.qbx_core:GetPlayer(source)
    return Player and Player.PlayerData and Player.PlayerData.citizenid or nil
end

-- SECURITY FIX (coder-architect, adversarial-pass finding routed by
-- orchestrator, this pass): this used to answer `isK9` from
-- IsConfiguredK9Model(GetEntityModel(ped)) ALONE -- a networked ped
-- property the CLIENT fully controls (RequestModel + SetPlayerModel
-- locally, no server round trip). A never-certified player could set
-- their own model to a configured K9 model and immediately pass every
-- gate below (petK9/feedK9/calmDownK9/relayDamageEvent/the main tick),
-- manipulating mood/fatigue/fear-stress/injury -- which, via
-- K9MoveRateModifiers, is a real, working way to hold a live client-side
-- movement-speed effect with no certification at all. Every OTHER
-- consumer of the same model check in this resource already pairs it
-- with a real access check (server/main.lua's CheckLeashEligibility,
-- server/partnership.lua's CheckPartnershipEligibility, server/fetch.lua,
-- server/inventory.lua, server/propattachment.lua) -- this file was the
-- one outlier.
--
-- ROLE/MODEL DECOUPLING, folded into the SAME fix (coder-architect,
-- server/appearance.lua, Config.K9Appearance.requireK9ModelForRole):
-- `isK9` is now `(actually dog-modeled OR holds the K9 role) AND has
-- access` -- a certified/permitted K9-role holder on an unlisted or human
-- ped (the owner's explicit "I also want everything to work with any
-- ped") is no longer excluded from Fatigue/Mood/FearStress/Injury just
-- because they don't currently look like a dog, but nobody -- modeled or
-- not -- gets through without `HasK9Access` also being true.
-- `type(HasK9Role) == 'function'` is a genuine soft dependency (this
-- resource's established convention), not a load-order assumption:
-- server/appearance.lua loads well before this file in
-- fxmanifest.lua's server_scripts, but this still degrades to the
-- pure-model half if that file is ever absent.
--- @param source number
--- @return number ped, boolean isK9 -- ped is 0 if the source isn't a currently-connected player
local function ResolveK9Ped(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then return 0, false end
    local looksLikeK9 = IsConfiguredK9Model(GetEntityModel(ped))
    local holdsK9Role = type(HasK9Role) == 'function' and HasK9Role(source)
    return ped, (looksLikeK9 or holdsK9Role) and HasK9Access(source)
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL (Config.FeatureControl -- config.lua's own
-- header documents the 4-step resolution; step 1, Config.Features.<Name>,
-- is checked separately by each call site below before this function is
-- ever reached). Mirrors server/pursuitsprint.lua's
-- IsPursuitSprintPermittedForCitizenId shape verbatim (that file's own
-- header says to read it before writing another variant) -- parameterized
-- by featureName here since this file gates FIVE independent
-- Config.Features flags (FatigueSystem/MoodSystem/FearStressSystem/
-- DistractionSystem/InjuryLimping) through the identical shape.
--
-- THE CALL MADE HERE, STATED PLAINLY (this pass's own explicit instruction
-- to be careful in this file, and to say what was decided): a block on a
-- wellbeing sub-feature for a specific citizenid is implemented as IMMUNITY
-- FROM THAT STAT'S NEGATIVE EFFECTS, never as a freeze of the stat itself.
-- Concretely, every call site below gates only the HARMFUL direction (sprint
-- fatigue decay, damage-triggered mood/injury decay, gunfire-triggered
-- fear-stress rise and the hesitation it can force, being distracted by
-- another player's item) -- it never gates passive regen, the
-- death/respawn injury restore, or any of the self-service/other-initiated
-- RELIEF actions below (calmDownK9, petK9, feedK9, RestoreInjury). This is
-- the one available design that satisfies BOTH halves of what "turn this
-- feature off for one person" has to mean at once: a K9 who is blocked
-- experiences no NEW harm from that stat, and a K9 who was ALREADY
-- exhausted/miserable/stressed/injured at the moment they got blocked keeps
-- recovering normally rather than being frozen at whatever value the block
-- happened to catch them at -- freezing the stat outright (the more literal
-- "the feature no longer exists for them" reading) was rejected specifically
-- because it would strand an already-injured/already-exhausted K9 exactly at
-- their worst moment, the "stuck in a bad state" trap this task named
-- explicitly. IsHesitating/IsDistracted below additionally fail closed on a
-- block directly (belt-and-suspenders on top of the escalation gate at each
-- stat's own tick/event site), which also means high command can use a block
-- to immediately neutralize the disclosed forged-gunfire hesitation-griefing
-- risk (this file's own header, "SECURITY FINDING B") against one specific
-- victim, without needing to wait for that K9's own fearStress to decay.
--- @param citizenid string
--- @param featureName string -- exact Config.Features key: 'FatigueSystem' | 'MoodSystem' | 'FearStressSystem' | 'DistractionSystem' | 'InjuryLimping'
--- @return boolean allowed
local function IsWellbeingFeaturePermittedForCitizenId(citizenid, featureName)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.' .. featureName) == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant[featureName] == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.' .. featureName) == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

-- ======================================================================
-- RESOURCE-GLOBALS — see this file's header for the full contract on each.
-- ======================================================================





-- ======================================================================
-- ON-DEMAND SNAPSHOT — see this file's header EVENT/CALLBACK CONTRACT
-- item 1.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:getWellbeingSnapshot', function(source)
    if not Config.Features.FatigueSystem then
        return nil
    end

    local citizenid = ResolveCitizenid(source)
    if not citizenid then return nil end

    return SnapshotOf(EnsureStats(citizenid))
end)

-- ======================================================================
-- FATIGUE — rest-source model resolution. THIS PASS (coder-backend).
-- Config.Wellbeing.Fatigue.restSources is a list of MODEL NAMES (an object
-- prop like a kennel, or a vehicle model like one of Config.K9Vehicles'
-- entries) treated as a "rest point" — DEVELOPER_REFERENCE.md §13.4.3.1 open
-- question 1's own "a world-object proximity check" reading (see this
-- file's header CONFIDENCE GRADING item 6 for the full writeup on why this
-- reading was chosen over an item-name check). Hashed ONCE here
-- (restSources is static config, never mutated at runtime) rather than
-- re-hashing the same handful of strings every tick.
-- ======================================================================
local RestSourceModelHashes = nil

--- @return table<number, boolean> hashes -- memoized, built on first call
local function GetRestSourceModelHashes()
    if RestSourceModelHashes then return RestSourceModelHashes end

    RestSourceModelHashes = {}
    for _, modelName in ipairs(Config.Wellbeing.Fatigue.restSources) do
        if type(modelName) == 'string' and modelName ~= '' then
            RestSourceModelHashes[GetHashKey(modelName)] = true
        end
    end
    return RestSourceModelHashes
end

-- ======================================================================
-- HANDLER CONDITION BADGE — implementation. See this file's own header
-- section of the same name for the full design writeup this code follows.
-- ======================================================================
local HANDLER_CONDITION_EVENT = 'qbx_k9unit:client:partnerConditionUpdate'

--- Resolves the live server id currently backing `citizenid`, or nil if
--- they are offline right now. Kept as its own tiny function purely so
--- every call site below reads identically to
--- server/partnership.lua's own TellCitizenIdPartnershipEnded shape — not
--- because the logic itself is complex.
--- @param citizenid string
--- @return number? src
local function ResolveOnlineSourceForCitizenid(citizenid)
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    return player and player.PlayerData and player.PlayerData.source or nil
end

--- Derives the small set of COARSE condition tags a bonded handler is
--- allowed to see for `stats` — see this file's "HANDLER CONDITION BADGE"
--- header section for the full "coarse, never numeric" / "feature-flag
--- respecting" reasoning. Fixed, deterministic emission order (also what
--- table.concat below turns into this feature's own change-detection
--- key) — NOT a severity ranking, just a stable order matching this
--- file's own six-stat documentation order throughout (Fatigue, Mood,
--- FearStress, Injury, Hunger, Thirst).
---
--- THE CLOSED LIST OF EVERYTHING THIS FUNCTION CAN EVER RETURN: exactly
--- zero or more of 'tired'/'unhappy'/'stressed'/'injured'/'hungry'/
--- 'thirsty' — six fixed strings, nothing derived from a raw stat value,
--- a position, or anything else that could narrow where this K9 is.
--- @param stats table -- the SAME per-citizenid stats table TickWellbeing already has in hand
--- @return string[] tags
local function ComputeHandlerConditionTags(stats)
    local tags = {}

    if Config.Features.FatigueSystem and stats.fatigue <= Config.Wellbeing.Fatigue.speedPenaltyThreshold then
        tags[#tags + 1] = 'tired'
    end

    return tags
end

--- Sends the explicit CLEAR signal (`visible = false`, `tags = {}`) to
--- `handlerCitizenid`, if — and only if — they currently resolve to a
--- connected server id. Silent no-op otherwise (an offline handler has no
--- client to tell, and a genuinely absent partnership/feature already
--- means there is nothing to show them the next time they DO connect —
--- see PushHandlerConditionUpdate's own "no active partnership" branch).
--- @param handlerCitizenid string
local function ClearHandlerConditionBadge(handlerCitizenid)
    local src = ResolveOnlineSourceForCitizenid(handlerCitizenid)
    if src then
        TriggerClientEvent(HANDLER_CONDITION_EVENT, src, { visible = false, tags = {} })
    end
end

--- Explicit cleanup for the one shape TickWellbeing's own per-K9 loop can
--- never reach on its own: every wellbeing stat system switched off at
--- once, which is also the one case TickWellbeing itself is never even
--- called for (see the CreateThread loop below) — so nothing would
--- otherwise ever push this feature's own CLEAR signal. Called from that
--- SAME existing thread's own `else` branch — the one iteration that
--- would otherwise do nothing observable at all — never a second thread.
--- Cheap: bounded by however many K9s currently have a visible badge
--- (typically zero), not by server population.
local function ClearAllHandlerConditionBadges()
    for k9Citizenid, cached in pairs(HandlerConditionCache) do
        ClearHandlerConditionBadge(cached.handlerCitizenid)
        HandlerConditionCache[k9Citizenid] = nil
    end
end

--- Called once per tick, per currently-tracked K9 citizenid, from the SAME
--- TickWellbeing per-K9 pass that already builds/sends item 11's
--- wellbeingUpdate — see this file's "HANDLER CONDITION BADGE" header
--- section for the full design.
--- @param k9Citizenid string
--- @param stats table
local function PushHandlerConditionUpdate(k9Citizenid, stats)
    -- FEATURE FLAG: no Partnership feature, nothing to resolve a handler
    -- from — treated exactly like "no active partnership" below: clear
    -- any badge this K9 might have left showing from before the flag was
    -- switched off, then stop. See this file's "HANDLER CONDITION BADGE"
    -- header, "gate the start, never the stop," reason 4's sibling case.
    if not Config.Features.HandlerPartnership then
        local cachedOff = HandlerConditionCache[k9Citizenid]
        if cachedOff then
            ClearHandlerConditionBadge(cachedOff.handlerCitizenid)
            HandlerConditionCache[k9Citizenid] = nil
        end
        return
    end

    -- SOFT DEPENDENCY, this resource's established convention for a
    -- cross-file resource-global consumed at RUNTIME (server/recall.lua's
    -- Recall actor and server/defense.lua's HandlerDownDefense trigger
    -- both guard this exact accessor identically) — never a load-order
    -- assumption, even though server/partnership.lua does load before
    -- this file in fxmanifest.lua's server_scripts.
    if type(GetActivePartnerCitizenId) ~= 'function' then return end

    local cached = HandlerConditionCache[k9Citizenid]

    -- SERVER-AUTHORITATIVE PARTNER RESOLUTION — `k9Citizenid` is never
    -- anything a client supplied; it is the citizenid TickWellbeing's own
    -- loop already resolved for a currently-connected, currently
    -- K9-modeled player (see ResolveCitizenid/ResolveK9Ped's own call
    -- sites). `isK9` confirms `k9Citizenid` is genuinely the K9-role party
    -- of its own active row — true by construction every time this is
    -- reached from TickWellbeing below, checked anyway since this
    -- function has no other way to fail closed against a future,
    -- differently-shaped caller.
    local handlerCitizenid, isK9 = GetActivePartnerCitizenId(k9Citizenid)

    if not handlerCitizenid or not isK9 then
        -- No active partnership for this K9 right now. If a PREVIOUS tick
        -- DID push a visible condition to some handler for this exact K9,
        -- that handler's badge must not be left stranded now that the
        -- partnership backing it is gone — explicit clear, not silence.
        if cached then
            ClearHandlerConditionBadge(cached.handlerCitizenid)
            HandlerConditionCache[k9Citizenid] = nil
        end
        return
    end

    if cached and cached.handlerCitizenid ~= handlerCitizenid then
        -- Partner CHANGED since the last push this K9 ever sent (broke
        -- and repartnered with someone else) without ever passing through
        -- the "no partner" branch above. The OLD handler's badge is now
        -- showing data about a partnership that no longer includes them —
        -- clear it before considering the new handler at all.
        ClearHandlerConditionBadge(cached.handlerCitizenid)
        HandlerConditionCache[k9Citizenid] = nil
        cached = nil
    end

    local handlerSrc = ResolveOnlineSourceForCitizenid(handlerCitizenid)
    if not handlerSrc then
        -- Partnership active, but the handler is not currently connected —
        -- nobody to push to right now. `cached` (if any) is deliberately
        -- left untouched: see this file's "HANDLER CONDITION BADGE"
        -- header, "gate the start, never the stop," reason 3.
        return
    end

    local tags = ComputeHandlerConditionTags(stats)
    local tagsKey = table.concat(tags, ',')

    local changed = not cached
        or cached.lastHandlerSrc ~= handlerSrc
        or cached.tagsKey ~= tagsKey

    if changed then
        TriggerClientEvent(HANDLER_CONDITION_EVENT, handlerSrc, { visible = true, tags = tags })
        HandlerConditionCache[k9Citizenid] = { handlerCitizenid = handlerCitizenid, lastHandlerSrc = handlerSrc, tagsKey = tagsKey }
    end
end

-- ======================================================================
-- SHARED TICK LOOP — DEVELOPER_REFERENCE.md §13.0 Decision 1. ONE loop for all
-- five stats, one pass over currently-connected players per tick. Started
-- ONLY if at least one of the five flags is enabled — a fully-disabled
-- subsystem runs no thread at all, per this file's own "no code needed
-- when disabled" default posture (mirrors client/movement.lua's
-- AgilityBasicJump == true default branch).
-- ======================================================================
local function TickWellbeing()
    local now = GetGameTimer()
    local dtSeconds = TICK_INTERVAL_MS / 1000


    -- FATIGUE — resolve every currently-networked rest-source entity's
    -- position ONCE per tick, SHARED across every K9 checked below (NOT
    -- once per K9 — this is the whole cost-control point: the expensive
    -- part, enumerating world entities, is paid at most once per tick
    -- regardless of how many K9s are online; each K9's own check below is
    -- then just a distance compare against however many rest sources this
    -- scan actually found, typically small). `GetAllObjects()`/
    -- `GetAllVehicles()` are server-side natives that enumerate every
    -- currently-networked entity server-wide, regardless of any one
    -- client's own streaming radius — the correct, server-authoritative
    -- source for "is there really a rest source near this K9's own live
    -- position," never a client-claimed "I am resting" report or a
    -- client-supplied coordinate. DISCLOSED COST: this scan's own runtime
    -- is O(total networked objects + total networked vehicles) once per
    -- tick, independent of K9 count — on a server with very many world
    -- objects/vehicles this is the single most expensive line in this
    -- file's tick; skipped entirely (nil, not an empty table) whenever
    -- FatigueSystem is off or restSources is empty, so a server that never
    -- configures a rest source pays nothing beyond the length check below.
    local restSourcePositions = nil
    if Config.Features.FatigueSystem and #Config.Wellbeing.Fatigue.restSources > 0 then
        restSourcePositions = {}
        local modelHashes = GetRestSourceModelHashes()
        for _, obj in ipairs(GetAllObjects()) do
            if modelHashes[GetEntityModel(obj)] then
                restSourcePositions[#restSourcePositions + 1] = GetEntityCoords(obj)
            end
        end
        for _, veh in ipairs(GetAllVehicles()) do
            if modelHashes[GetEntityModel(veh)] then
                restSourcePositions[#restSourcePositions + 1] = GetEntityCoords(veh)
            end
        end
    end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local ped, isK9 = ResolveK9Ped(src)
            if ped ~= 0 and isK9 then
                local citizenid = ResolveCitizenid(src)
                if citizenid then
                    local stats = EnsureStats(citizenid)
                    local coords = GetEntityCoords(ped)

                    if Config.Features.FatigueSystem then
                        if stats.lastCoords then
                            local speed = #(coords - stats.lastCoords) / dtSeconds
                            -- PER-PERSON FEATURE CONTROL -- see
                            -- IsWellbeingFeaturePermittedForCitizenId's own
                            -- header for the "immunity from harm" design. A
                            -- blocked citizenid is treated as never-sprinting
                            -- here (falls through to the regen branch below
                            -- unconditionally, regardless of their real
                            -- speed this tick) -- sprint decay is the only
                            -- harmful direction Fatigue has; rest/idle regen
                            -- is never gated.
                            if speed >= Config.Wellbeing.Fatigue.sprintSpeedThreshold
                                and IsWellbeingFeaturePermittedForCitizenId(citizenid, 'FatigueSystem') then
                                -- PER-CITIZENID STAMINA OVERRIDE (this pass,
                                -- coder-backend) -- owner's own words: "be
                                -- able to make the stamina as high as i want
                                -- and be able to make the stamina ...
                                -- permanant". Resolved through
                                -- server/k9profiles.lua's own
                                -- GetK9EffectiveMultipliers, the SAME seam
                                -- server/tracking.lua's own
                                -- ResolveMaxRangeForCitizenId already copies
                                -- for the sibling scent-range field: soft-
                                -- guarded (`type(...) == 'function'`),
                                -- pcall-wrapped, falls back to the raw
                                -- Config.Wellbeing.Fatigue.sprintDecayPerTick
                                -- global read on any failure/absence. 0 is a
                                -- valid effective value here (the "permanent
                                -- stamina" sentinel) -- Clamp below simply
                                -- subtracts 0, a genuine no-op tick, never a
                                -- special case.
                                local sprintDecayPerTick = Config.Wellbeing.Fatigue.sprintDecayPerTick
                                if type(GetK9EffectiveMultipliers) == 'function' then
                                    local ok, effective = pcall(GetK9EffectiveMultipliers, citizenid)
                                    if ok and type(effective) == 'table' and type(effective.sprintDecayPerTick) == 'number' then
                                        sprintDecayPerTick = effective.sprintDecayPerTick
                                    end
                                end
                                stats.fatigue = Clamp(stats.fatigue - sprintDecayPerTick, 0, Config.Wellbeing.Fatigue.max)
                            else
                                -- REST-SOURCE REGEN, THIS PASS: a stationary/
                                -- non-sprinting K9 within restRadius of any
                                -- rest-source position resolved above
                                -- regenerates at restRegenPerTick instead of
                                -- idleRegenPerTick. `coords` is this K9's OWN
                                -- server-resolved live position (the same
                                -- value already used for the sprint-speed
                                -- sample above) — never a client-claimed "I
                                -- am near a rest point." Per-K9 cost here is
                                -- O(#restSourcePositions), not O(1) in the
                                -- strict sense, but bounded by however many
                                -- matching rest-source entities actually
                                -- exist server-wide this tick (see the scan
                                -- above for the shared, once-per-tick cost
                                -- this amortizes against).
                                local nearRestSource = false
                                if restSourcePositions then
                                    for _, restCoords in ipairs(restSourcePositions) do
                                        if #(coords - restCoords) <= Config.Wellbeing.Fatigue.restRadius then
                                            nearRestSource = true
                                            break
                                        end
                                    end
                                end

                                if nearRestSource then
                                    stats.fatigue = Clamp(stats.fatigue + Config.Wellbeing.Fatigue.restRegenPerTick, 0, Config.Wellbeing.Fatigue.max)
                                else
                                    stats.fatigue = Clamp(stats.fatigue + Config.Wellbeing.Fatigue.idleRegenPerTick, 0, Config.Wellbeing.Fatigue.max)
                                end
                            end
                        end
                    end
                    stats.lastCoords = coords





                    -- PERSISTENCE (this pass) -- see this file's header
                    -- "DATABASE PERSISTENCE" point 1/4. Marked dirty
                    -- unconditionally for every online, tracked K9 this
                    -- tick (simpler and strictly safer than tracking exact
                    -- per-field dirtiness at each of the six branches
                    -- above -- a periodic flush rewriting an occasionally-
                    -- unchanged value is harmless; a future mutation site
                    -- added above without remembering to flag it would not
                    -- be). `WellbeingLastSeenOnline.Touch` is this
                    -- citizenid's OWN "still online" heartbeat -- see
                    -- EvictStaleWellbeingEntries' own doc comment for how
                    -- this is used to decide eviction eligibility.
                    stats.dirty = true
                    WellbeingLastSeenOnline.Touch(citizenid, now)

                    TriggerClientEvent('qbx_k9unit:client:wellbeingUpdate', src, SnapshotOf(stats))

                    -- HANDLER CONDITION BADGE (this pass) — same per-K9
                    -- pass, same `stats` table, no second loop. See this
                    -- file's own header section of the same name.
                    PushHandlerConditionUpdate(citizenid, stats)
                end
            elseif ped ~= 0 then
                -- QA FIX (this pass): a currently-connected player who is
                -- NOT (or no longer) K9-modeled must not leave a stale
                -- `stats.lastCoords` sample sitting around from the last
                -- tick they WERE K9-modeled. Left unreset, the very next
                -- tick after they switch back to a K9 model (possibly at a
                -- completely different location — a ped-swap, a teleport, a
                -- fresh spawn) would compute Fatigue's sprint-speed sample
                -- as the distance between that stale position and their new
                -- one divided by a SINGLE tickIntervalMs, producing a huge
                -- bogus "sprint" speed and applying one wrong
                -- sprintDecayPerTick hit. Only touches the TRANSIENT,
                -- ped-instance-scoped observations (`lastCoords`,
                -- `injuryDeathEpisodeStartedAt`) — never the four persisted
                -- stats themselves (fatigue/mood/fearStress/injury
                -- deliberately persist across a model switch or
                -- disconnect/reconnect within the same server session, per
                -- this file's own header). Reads `WellbeingStats` directly
                -- rather than `EnsureStats` so this never creates a fresh
                -- entry for a citizenid that has never actually been
                -- K9-modeled this session.
                --
                -- `injuryDeathEpisodeStartedAt` RESET (FOLLOW-UP FIX #1,
                -- this pass): see the WellbeingStats struct comment above
                -- (category 2) for why this belongs in the SAME category as
                -- `lastCoords` and needs the identical reset (to 0, its own
                -- "inactive" sentinel — this field is a timestamp, not a
                -- boolean) — a K9 that dies, switches away from its K9
                -- model while still connected (the same rare
                -- appearance-swap edge case this comment already names for
                -- the sprint-speed bug), and is later revived by whatever
                -- unrelated means while non-K9-modeled would otherwise
                -- carry a stale non-zero episode-start timestamp back into
                -- the K9 branch the moment it switches back — read there as
                -- a real, and by then very LONG, candidate episode (easily
                -- exceeding MIN_DEATH_EPISODE_DURATION_MS) that this file
                -- never actually observed, and pay out a free
                -- deathRespawnRestoreAmount. This mirrors the playerDropped
                -- handler's own identical reset immediately below, for the
                -- disconnect-shaped version of the exact same bug (that one
                -- was the one a regression pass actually caught first —
                -- this branch is fixed alongside it rather than left as a
                -- second, narrower instance of the same root cause).
                local citizenid = ResolveCitizenid(src)
                local stats = citizenid and WellbeingStats[citizenid]
                if stats then
                    stats.lastCoords = nil
                    stats.injuryDeathEpisodeStartedAt = 0
                end
            end
        end
    end
end

--- QA FIX (this pass): the reset above only covers a player who stays
--- CONNECTED after leaving a K9 model — it can never run for a player who
--- disconnects outright (they no longer appear in `GetPlayers()` on the
--- very next tick, so the `elseif ped ~= 0` branch above never sees them).
--- Left unhandled, a K9 who logs off mid-session and reconnects later
--- (possibly to a completely different spawn location, per qbx_core's own
--- spawn-selection logic) would hit the exact same bogus-sprint-speed bug
--- the reset above closes for the stay-connected case. `WellbeingStats`
--- itself deliberately is NOT cleared here (this file's header: "a K9 who
--- logs off tired should still be tired on reconnect within the same
--- server session") — the PERSISTED stats (fatigue/mood/fearStress/injury,
--- distractedUntil/hesitatingUntil/hesitationEpisodeStartedAt) are
--- untouched; only the TRANSIENT, ped-instance-scoped observations
--- (`lastCoords`, `injuryDeathEpisodeStartedAt`) are reset here, mirroring
--- the `elseif ped ~= 0` branch above exactly — see the WellbeingStats
--- struct comment for the full category-1-vs-category-2 writeup.
---
--- `injuryDeathEpisodeStartedAt` RESET (FOLLOW-UP FIX #1, this pass — a
--- regression pass caught this one for real, empirically, against the live
--- resource): this field's PREDECESSOR, a plain boolean
--- (`injuryDiedWhileTracked`), was NOT reset here when it first shipped,
--- and this was the one of the two reset sites that actually mattered in
--- practice — a K9 could take damage, drop to/below
--- PED_DEAD_HEALTH_THRESHOLD (the flag set `true`), disconnect WHILE STILL
--- DEAD before any revive completed (`lastCoords` was reset here, but the
--- flag was not), and reconnect to a brand-new, genuinely-alive ped that
--- had never been through any revive/ambulance flow at all. The very next
--- TickWellbeing pass then read `isDeadNow == false` against the stale
--- `true` flag as a real dead-to-alive TRANSITION and paid out a full
--- `Config.Wellbeing.Injury.deathRespawnRestoreAmount` for free — cheaper
--- than the passive regen climb this fix deliberately left in place, no
--- medkit/ambulance/delay required, and trivially repeatable (disconnect
--- while dead, reconnect, repeat). This is exactly the scenario that field's
--- own config.lua comment's disclosed-residual-risk paragraph named and
--- assumed a real revive flow's own friction would bound — the friction
--- never applied, because no revive ever actually happened. `WellbeingStats`
--- itself is still NOT cleared (same "a K9 who logs off tired should still
--- be tired" rule) — only this one field, which was always meant to be
--- reset alongside `lastCoords` as the same class of "meaningless the
--- instant the underlying ped handle is gone" observation, not alongside
--- the four genuinely-persisted stats it happened to be typo-adjacent to in
--- this table. NOW A TIMESTAMP, NOT A BOOLEAN (FOLLOW-UP FIX #2 — see this
--- file's header for the separate, worse bug that redesign closed): reset
--- here means set to 0, its own "inactive" sentinel, exactly like every
--- other candidate-episode timestamp this file uses.
--- `exports.qbx_core:GetPlayer(source)` is still resolvable here —
--- `playerDropped` fires before the framework fully tears down the player
--- object, same timing server/progression.lua's own `K9XP` eviction handler
--- and server/certifications.lua's own playerDropped handler already rely
--- on.
AddEventHandler('playerDropped', function(_reason)
    local citizenid = ResolveCitizenid(source)
    local stats = citizenid and WellbeingStats[citizenid]
    if stats then
        stats.lastCoords = nil
        stats.injuryDeathEpisodeStartedAt = 0
    end

    -- PERSISTENCE (this pass) -- write-on-disconnect, so this citizenid's
    -- last change does not have to wait for the next periodic flush to
    -- reach disk, and so it becomes eligible for eviction as soon as
    -- Config.Wellbeing.Persistence.evictAfterMs elapses rather than only
    -- after a periodic flush happens to catch it. See this file's header
    -- "DATABASE PERSISTENCE" point 1 for the full writeup; no-op if this
    -- citizenid has nothing unflushed or persistence is unavailable.
    if citizenid then
        FlushWellbeingEntryNow(citizenid)
    end

    -- HANDLER CONDITION BADGE CLEANUP (this pass) — if this disconnecting
    -- player IS a K9 with a cached, currently-visible condition badge
    -- showing on some handler's screen, that badge has no way to
    -- self-heal via the next TickWellbeing pass: GetPlayers() will simply
    -- never include this citizenid again this session, so
    -- PushHandlerConditionUpdate's own "no partner online"/"no active
    -- partnership" cleanup paths (used for every OTHER stop condition)
    -- can never run for them again. Cleared explicitly, right here, the
    -- one place this resource is ever told this K9 just went offline —
    -- see this file's "HANDLER CONDITION BADGE" header, "gate the start,
    -- never the stop," reason 2.
    if citizenid and HandlerConditionCache[citizenid] then
        ClearHandlerConditionBadge(HandlerConditionCache[citizenid].handlerCitizenid)
        HandlerConditionCache[citizenid] = nil
    end
end)

-- CONFIRMED LIVE-FLIP BUG, FIXED (this pass, coder-backend) -- this thread
-- used to be wrapped in `if Config.Features.FatigueSystem or
-- Config.Features.MoodSystem or Config.Features.FearStressSystem or
-- Config.Features.DistractionSystem or Config.Features.InjuryLimping then
-- CreateThread(...) end`, a boot-time snapshot of five flags read exactly
-- once, at this file's own load time. server/runtimecontrol.lua's own
-- FEATURE_TIERS registers all five as `tier = 'live'` (ApplyFeatureOverride
-- mutates Config.Features.* immediately, no restart), so an operator could
-- boot with all five off and flip ONE on live from the tablet in one click:
-- every client-facing entry point (petK9/feedK9/applyK9Distraction/
-- calmDownK9/relayDamageEvent/relayWeaponFire) re-checks its OWN flag fresh
-- and would start mutating WellbeingStats for real immediately, but the
-- ONLY thread that ever ticks decay/regen or pushes a `wellbeingUpdate`
-- would never have started, for the rest of that server's uptime -- an
-- already-connected client's last-received snapshot (and any move-rate/
-- input-block effect client/wellbeing.lua derived from it) would then go
-- stale with NO upper bound at all, not merely one `TICK_INTERVAL_MS`,
-- until this resource restarts. Exactly the same bug SHAPE as
-- server/combat.lua's own two threads (commit 0aeff52, "CONFIRMED LIVE-FLIP
-- BUG, FIXED" -- read both of that file's comments in full before touching
-- this one), and this fix copies that file's OWN precedent.
--
-- AN EARLIER ATTEMPT THIS PASS WAS WRONG, NOT THE TEST SUITE -- recorded
-- here so nobody re-tries the same shape. The first attempt mirrored
-- client/movement.lua's own MOVE-RATE WATCHDOG instead
-- (`if condition then act(); Wait(activeMs) else Wait(idleMs) end` --
-- ACT-THEN-WAIT, with a SHORT idle poll interval while nothing is enabled)
-- rather than combat.lua's own fixed-thread shape (a bare, unconditional
-- `Wait(interval)` as the loop's literal FIRST statement, every iteration,
-- with the flag check moved to AFTER that Wait). That broke this file's own
-- tests/wellbeing_spec.lua on two counts, and only one of them was a reason
-- to touch the spec rather than the code:
--   1. The DISCREPANCY test pinning exactly ONE CreateThread call at file
--      load with every flag off (DistractionCooldown's own always-on
--      sweep, the only thread that existed pre-fix) went red. This one WAS
--      a reason to update the test, not revert the code -- a test that
--      keeps asserting "exactly one CreateThread call with everything off"
--      is asserting the BUG's own premise once the bug is fixed. See that
--      test's replacement in tests/wellbeing_spec.lua, mirroring
--      tests/combat_spec.lua's own corrected "with every combat feature
--      flag off..." test and tests/runtimefeaturetiers_spec.lua's
--      "RESOLVED PARTIAL LIVENESS" test for the identical shape.
--   2. tests/fixtures/sandbox.lua's coroutine thread runner (`runOneTick`/
--      `primeIfNeeded` here, used identically by every other spec in this
--      suite) is built on one load-bearing assumption, stated in that
--      file's own header: "every sweep thread in this resource calls
--      Wait(...) as its FIRST statement inside the loop" -- the FIRST
--      step() primes (reaches that Wait and yields, having done no real
--      work yet), and each step() after that runs exactly one full loop
--      body. An act-before-Wait structure breaks that on the very first
--      (priming) step -- the prime call would already have executed a real
--      TickWellbeing() pass, silently double-counting one pass against
--      every existing assertion in this file that counts wellbeingUpdate
--      events per step() (POINT 2's own tests especially). THIS was a real
--      bug in the ATTEMPT, not a wrong assumption in the test -- a
--      production thread whose own first statement is conditional,
--      variable-duration work rather than a plain Wait is also a strictly
--      worse shape on its own merits (a harder-to-reason-about interval
--      that depends on which branch fired last), not merely
--      test-incompatible.
--
-- FIXED, this time, by keeping this thread's shape IDENTICAL to what it
-- was before, other than removing the outer `if`: `Wait(TICK_INTERVAL_MS)`
-- remains the loop's literal first statement, unconditionally, every
-- iteration, and the five-flag check moves to immediately after it, gating
-- only whether TickWellbeing() itself runs THIS iteration -- exactly
-- server/combat.lua's own K9-POSITION-HISTORY thread shape, not its expiry
-- thread's shape: TickWellbeing's own body is NOT free the way combat.lua's
-- ActiveHolds-iterating expiry-thread body is with its flags off (a `pairs`
-- over a table provably empty with those flags off) -- TickWellbeing
-- unconditionally calls GetPlayers() and resolves GetPlayerPed/
-- GetEntityModel/HasK9Access/GetEntityCoords/ResolveCitizenid for every
-- online player BEFORE any of the five per-stat branches ever run, real
-- per-player native calls an all-off server has no business paying for
-- every TICK_INTERVAL_MS. So the flag check stays INSIDE the loop, read
-- fresh every tick (never captured once), the same choice combat.lua's own
-- K9-position-history thread made for the identical "body is real work,
-- not a free walk" reason -- a live flip takes effect within at most one
-- TICK_INTERVAL_MS, never "not until this resource restarts."
--
-- THE HONEST STATE, FOR THE TIER TABLE: checked directly against
-- server/runtimecontrol.lua as it stands right now (coordinated with the
-- agent actively editing that file for an unrelated feature, before
-- touching this comment) -- FatigueSystem/MoodSystem/FearStressSystem/
-- DistractionSystem/InjuryLimping's own FEATURE_TIERS entries are still
-- bare `{ tier = 'live' }`, no `note` field, and no test anywhere requires
-- one to exist. The disclosure this file's OLD text above said had been
-- "reported to server/runtimecontrol.lua's owner... as a FEATURE_TIERS
-- documentation gap" never actually landed as a note there -- so there is
-- nothing to remove in that file and no test to invert, unlike
-- server/combat.lua's BiteAndHold/NonLethalTakedown/PropDragging (which DID
-- carry a note, since removed -- see tests/runtimefeaturetiers_spec.lua's
-- "RESOLVED PARTIAL LIVENESS" test). `tier = 'live'` was, and remains, the
-- correct classification either way: the gap this comment used to disclose
-- is closed now, not merely left undocumented.
CreateThread(function()
    while true do
        Wait(TICK_INTERVAL_MS)

        -- PERSISTENCE (this pass, coder-backend) -- eviction rides this
        -- ALREADY-EXISTING tick (no second CreateThread), unconditionally,
        -- regardless of the six-flag check just below: a dirty entry
        -- created while a feature was on must still be flushed/evicted
        -- correctly after that feature is later turned off, and
        -- EvictStaleWellbeingEntries' own internal "next-due" gate already
        -- keeps this cheap (a plain timestamp compare) on every tick where
        -- it isn't actually due to scan. See that function's own doc
        -- comment above for the full design.
        local evictOk, evictErr = pcall(EvictStaleWellbeingEntries, GetGameTimer())
        if not evictOk then
            print(('[qbx_k9unit] wellbeing.lua: eviction sweep error: %s'):format(tostring(evictErr)))
        end

        if Config.Features.FatigueSystem then
            local ok, err = pcall(TickWellbeing)
            if not ok then
                print(('[qbx_k9unit] wellbeing tick error: %s'):format(tostring(err)))
            end
        else
            -- HANDLER CONDITION BADGE (this pass) — the one shape
            -- TickWellbeing itself is never even called for: every
            -- wellbeing stat system off at once. See this file's "HANDLER
            -- CONDITION BADGE" header, "gate the start, never the stop,"
            -- reason 4. Cheap: a no-op scan whenever nothing is currently
            -- showing (the common case), never a second thread.
            local ok, err = pcall(ClearAllHandlerConditionBadges)
            if not ok then
                print(('[qbx_k9unit] wellbeing handler-condition clear error: %s'):format(tostring(err)))
            end
        end
    end
end)

-- PERSISTENCE (this pass, coder-backend) -- periodic flush thread. See
-- this file's header "DATABASE PERSISTENCE" point 1 for the full "why a
-- separate, coarser thread rather than flushing on TickWellbeing's own
-- 5-second-default cadence" writeup. Same defensive shape as every other
-- periodic thread in this file (and mirrors server/webhook.lua's own
-- FlushQueue thread): `Wait` first, every iteration, unconditionally --
-- see the main tick thread's own header comment (further up this file)
-- for why that shape, not an act-then-Wait one, is load-bearing for this
-- file's own test suite, not merely a style preference.
CreateThread(function()
    while true do
        Wait(PersistenceCfg.flushIntervalMs)
        if PersistenceCfg.enabled then
            local ok, err = pcall(FlushDirtyWellbeingStats)
            if not ok then
                print(('[qbx_k9unit] wellbeing.lua: persistence flush error: %s'):format(tostring(err)))
            end
        end
    end
end)

-- ======================================================================
-- STARTUP VALIDATION — PLACEHOLDER ox_inventory ITEM NAMES (this pass,
-- coder-backend softlock fix). See this file's header, STUCK-K9 SOFTLOCK
-- FIX item 3, for the full writeup on scope/reasoning, including WHY
-- Config.K9Medkit.itemName is checked from this file rather than
-- server/medkit.lua. Mirrors server/combat.lua's own established
-- "resource-start WARNING, never an assert" pattern for
-- Config.Combat.PropDragging.IsPlayerDownedOverride verbatim.
--
-- COMPAT-LAYER FINDING (coder-backend, this pass), DELIBERATELY NOT ROUTED:
-- `exports.ox_inventory:Items(itemName)` below is left as a direct call,
-- NOT `K9Compat.Get('inventory')...` -- shared/compat/core.lua's
-- RequiredMethods.inventory table only lists `ItemExists` under the CLIENT
-- realm, never under `server`, and this function runs entirely server-side.
-- There is no server-side accessor in the current contract this could route
-- through on ANY backend. Reported per this task's own explicit instruction
-- ("if a call site has no clean accessor, that is a finding, not a licence
-- to improvise") rather than worked around -- see server/equipmentshop.lua's
-- own WarnIfItemMissing for the identical finding, reported once there in
-- full and not re-derived here. Consequence: on a non-ox_inventory backend
-- this one operator-facing sanity warning simply never fires true (its own
-- `GetResourceState('ox_inventory')` check inside the export access below
-- fails closed) -- the STASH/DISTRACTION/MOOD mutation paths themselves are
-- now correctly backend-agnostic (see this file's GetItemCount/RemoveItem
-- call sites above), only this one pre-flight existence check stays
-- ox_inventory-specific until the contract gains a server-side ItemExists.
-- ======================================================================

--- Warns (loudly, to server console) if `itemName` does not resolve in
--- this server's own live ox_inventory item registry. A WARNING ONLY —
--- never throws, never prevents resource start, per this task's explicit
--- instruction not to fail a resource over an operator's own inventory
--- configuration. `exports.ox_inventory:Items(name)` (confirmed this pass
--- against a fresh read of ox_inventory's own modules/items/server.lua —
--- `exports('Items', function(item) return getItem(nil, item) end)`,
--- returning the item's own registered data table or nil) is wrapped in
--- `pcall` so an unexpected export error (e.g. a very old ox_inventory
--- build without this export) becomes its own loud, distinct warning
--- instead of ever propagating out of `onResourceStart`.
--- @param itemName any
--- @param configPath string -- e.g. 'Config.K9Medkit.itemName', for the printed message only
--- @param featureFlagName string -- e.g. 'Config.Features.K9Medkit', for the printed message only
local function WarnIfItemMissing(itemName, configPath, featureFlagName)
    if type(itemName) ~= 'string' or itemName == '' then
        print(('[qbx_k9unit] WARNING: %s is enabled but %s is not a valid item name (%s) -- cannot verify it against ox_inventory at all.'):format(featureFlagName, configPath, tostring(itemName)))
        return
    end

    local ok, item = pcall(function() return exports.ox_inventory:Items(itemName) end)
    if not ok then
        print(('[qbx_k9unit] WARNING: could not verify %s (%q) against ox_inventory for %s -- the Items() export itself errored: %s. Confirm ox_inventory is installed and up to date.'):format(configPath, itemName, featureFlagName, tostring(item)))
        return
    end

    if not item then
        print(('[qbx_k9unit] WARNING: %s is enabled but %s (%q) does not exist in this server\'s ox_inventory item registry. Every attempt to use this feature will silently fail as a generic "you do not have that item" error -- indistinguishable from a player simply not carrying one, with nothing else explaining why. Add %q to your ox_inventory data/items.lua (or point %s at a real, existing item name) before relying on this feature.'):format(featureFlagName, configPath, itemName, itemName, configPath))
    end
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if Config.Features.K9Medkit then
        -- Checked HERE, not in server/medkit.lua -- see this file's header
        -- for why.
        WarnIfItemMissing(Config.K9Medkit.itemName, 'Config.K9Medkit.itemName', 'Config.Features.K9Medkit')
    end



end)

-- ======================================================================
-- FLUSH ON RESOURCE STOP (lifecycle QA finding, this pass).
--
-- THE BUG: this file had NO onResourceStop handler at all -- the one
-- stateful subsystem in this resource that was missed, while kennel,
-- combat, vehicle, propattachment, fetch, bonetool, equipmentshop, hud and
-- tablet all gained one (several of them as explicitly-logged red-team/QA
-- fixes). Persistence rested on exactly two writes: the periodic flush
-- thread, and FlushWellbeingEntryNow on a clean disconnect. Neither fires
-- when the resource stops.
--
-- WHAT THAT COST: `restart qbx_k9unit` -- an ordinary thing an operator
-- does while configuring a server -- discarded WellbeingStats wholesale,
-- and the next boot reloaded each citizenid's last-flushed row from
-- k9_wellbeing. Up to Config.Wellbeing.Persistence.flushIntervalMs of
-- drift (60 seconds by default) in Fatigue, Mood, FearStress, Injury,
-- Hunger and Thirst, for every online K9 and handler, silently reverted to
-- an older but entirely plausible-looking value. No error, no warning, and
-- nothing on screen to distinguish it from the stats simply not having
-- changed. A graceful full server shutdown lost the same.
--
-- This file's own header already argued the periodic-flush window was an
-- acceptable exposure, and for a CRASH it is -- nothing can be done about
-- power loss. A deliberate restart is not a crash: the process is still
-- alive, the data is still in memory, and FlushDirtyWellbeingStats() was
-- sitting right there, already written, already iterating exactly the set
-- that needs writing. The header's reasoning was right about the case it
-- was reasoning about and simply never covered this one.
--
-- SAFE TO CALL FROM HERE: Wellbeing_Upsert bottoms out in a synchronous
-- MySQL.query.await (server/datastore.lua), and server/appearance.lua
-- already proves that shape works from inside a disconnect/stop handler.
-- FlushDirtyWellbeingStats is additionally already pcall-wrapped per
-- citizenid internally, so one failing row cannot abandon the rest of the
-- sweep on the way out -- which matters more here than anywhere else,
-- since there is no next flush to retry on.
--
-- NO NEW CONDITION OF ITS OWN beyond the resource-name check every
-- onResourceStop in this codebase carries. FlushDirtyWellbeingStats
-- already returns immediately when persistence is disabled or the database
-- is unavailable, so this is a clean no-op on a memory-only server rather
-- than something that needed a second gate here.
-- ======================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    FlushDirtyWellbeingStats()
end)
