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
      (append-only array) as file-local state. Ephemeral/in-memory only,
      deliberately not persisted — mirrors server/tracking.lua's
      `TrackableLog` / server/main.lua's `LeashPairs` precedent. Grows one
      entry per distinct citizenid ever seen while the server is up, same
      accepted growth profile as server/certifications.lua's `Certifications`
      cache — never cleared on disconnect (a K9 who logs off tired should
      still be tired on reconnect within the same server session).
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

-- Ephemeral, in-memory FearStress-only gunfire log. Deliberately NOT
-- server/tracking.lua's `TrackableLog.gunpowder` (that table is `local` to
-- that file) — see this file's header CONFIDENCE GRADING item 1 for the
-- full reasoning on why this is a small, disclosed duplication rather than
-- reaching into another file's internals.
-- RecentGunfire[i] = { coords = vector3, loggedAt = <GetGameTimer() ms>, source = number }
-- `source` added this pass (coder-security finding B) so nearbyShots below
-- can dedupe by reporting source rather than counting raw log entries — see
-- the relayWeaponFire AddEventHandler's own header comment for the full
-- exploit/fix writeup.
local RecentGunfire = {}

--- DEATH/RESPAWN DETECTION for Injury's own reset (this pass, coder-backend
--- softlock fix — see this file's header, STUCK-K9 SOFTLOCK FIX item 2, for
--- the full writeup). Mirrors server/combat.lua's and server/medkit.lua's
--- own identical `PED_DEAD_HEALTH_THRESHOLD` constant and reasoning
--- verbatim, not re-derived here: `IsEntityDead` has NO FXServer server-side
--- registration (confirmed independently by both of those files against
--- citizenfx/fivem's own native-registration source) and always silently
--- returns `false` server-side, so `GetEntityHealth(ped) <=
--- PED_DEAD_HEALTH_THRESHOLD` is the correct, native-availability-confirmed
--- substitute — a GTA ped is conventionally declared dead at 100 health,
--- not 0 (the reason a ped's default max health is 200, not 100).
local PED_DEAD_HEALTH_THRESHOLD = 100

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

--- MINIMUM QUALIFYING DEATH-EPISODE DURATION (red-team fix, this pass —
--- see this file's header, STUCK-K9 SOFTLOCK FIX item 2's FOLLOW-UP FIX #2,
--- for the full exploit this closes). `PED_DEAD_HEALTH_THRESHOLD` alone
--- cannot distinguish a genuine down/revive from an ordinary combat dip
--- ("grazed to ~90, bandaged back above 100 a few seconds later" is a
--- completely mundane firefight event, not a death) — TickWellbeing below
--- now requires a candidate episode (continuous observed time at/below the
--- threshold) to span AT LEAST this many milliseconds, measured between the
--- tick it was first observed and the tick it was next observed alive,
--- before `Config.Wellbeing.Injury.deathRespawnRestoreAmount` is paid.
--- DELIBERATELY a LOCAL constant, not a new Config field: this is a
--- security/exploit-boundary value, not a balance dial, same reasoning
--- HESITATION_MAX_CONTINUOUS_MS below already established for this file --
--- an operator-tunable value here could simply be set low enough to reopen
--- the exact exploit this closes, and this file's own established
--- convention for that class of value is to keep it in code rather than
--- expose a footgun.
---
--- DERIVATION: `math.max(tickIntervalMs * 3, 60000)` -- at least 3 sample
--- intervals (so a single unlucky one-tick sampling of an otherwise
--- instantaneous dip can never alone qualify) AND at least a real 60
--- seconds regardless of how short `Config.Wellbeing.tickIntervalMs` is
--- configured. At the shipped default (5000ms), this evaluates to 60000ms
--- (the 60s floor dominates). Chosen against real-world reference points,
--- not arbitrarily: 60s comfortably exceeds any plausible ordinary-combat
--- heal (a bandage/food/armor application is a matter of seconds), while
--- staying well under "every real QB/qbx laststand/ambulance flow this
--- resource is aware of takes minutes, not single-digit seconds" (this
--- file's own already-established observation) -- so a genuine down/revive
--- always qualifies, and an ordinary graze essentially never does.
---
--- HONEST LIMITS, STATED PLAINLY RATHER THAN CLAIMED AWAY (same "a 5-second
--- poll against a health threshold is a heuristic for death, not a death
--- event" framing this file's header now uses): (1) this does NOT make the
--- restore free of gaming entirely -- a player who deliberately holds their
--- K9 at/below 100 health for a real 60+ seconds and then heals normally
--- still receives it, with no actual ambulance/laststand flow required; it
--- is bounded to a real minimum time cost and to one payout per episode
--- (see TickWellbeing's own unconditional-clear-on-alive-observation logic
--- below), never free or unbounded, but not literally impossible either.
--- (2) A GENUINE revive completed faster than this floor (unusual, but not
--- impossible for an instant-revive item/command some servers run) would
--- NOT trigger the restore -- accepted as the safer failure direction: a
--- false negative here costs a K9 nothing it wasn't already going to
--- recover from via ordinary passive regen; a false positive is the actual
--- exploit this constant exists to close.
local MIN_DEATH_EPISODE_DURATION_MS = math.max(TICK_INTERVAL_MS * 3, 60000)

--- @param value number
--- @param min number
--- @param max number
--- @return number
local function Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- CLAMP AND WARN for a plain numeric Config value that is NOT a
--- millisecond threshold (ResolveConfiguredThresholdMs, server/cooldowns.lua,
--- already covers that shape -- reused as-is for Hunger/Thirst's own
--- *CooldownMs fields below). Covers decay/regen rates, thresholds out of
--- 100, and multipliers -- exactly the shape Hunger/Thirst's own config
--- introduces. Same "CLAMP AND WARN, never abort" reasoning as
--- ResolveConfiguredThresholdMs's own header: called only from inside
--- GetResolvedHungerThirstConfig() below, itself only ever reached from
--- inside an `if Config.Features.HungerThirstSystem then` branch, but a
--- bad value there must still degrade to a safe default with a loud
--- warning rather than silently misbehave or throw.
--- @param value any
--- @param fallback number -- a positive, hardcoded call-site literal, never itself read from Config
--- @param min number
--- @param max number
--- @param configKeyName string -- exact dotted Config path, for the printed warning only
--- @return number
local function ClampConfiguredNumber(value, fallback, min, max, configKeyName)
    local n = tonumber(value)
    if n == nil or n ~= n then -- n ~= n is Lua's own NaN test, same idiom client/wellbeing.lua's snapshot ingest already uses
        print(('[qbx_k9unit] wellbeing.lua: %s is missing or not a number (found: %s). Using the built-in fallback of %s instead -- find %s in config.lua and set it to a number.'):format(configKeyName, tostring(value), tostring(fallback), configKeyName))
        return fallback
    end
    if n < min or n > max then
        local clamped = Clamp(n, min, max)
        print(('[qbx_k9unit] wellbeing.lua: %s (%s) is outside its valid range [%s, %s]. Clamped to %s -- find %s in config.lua and set it within range.'):format(configKeyName, tostring(n), tostring(min), tostring(max), tostring(clamped), configKeyName))
        return clamped
    end
    return n
end

-- ======================================================================
-- HUNGER/THIRST — config resolution (this pass, coder-backend). See this
-- file's header for the full design writeup. Memoized (like
-- GetRestSourceModelHashes further below) so CLAMP-AND-WARN only ever
-- prints once per resource lifetime, not once per tick -- resolved lazily,
-- on first actual use from inside an `if Config.Features.HungerThirstSystem
-- then` branch, never at this file's own unconditional top-level load
-- (unlike TICK_INTERVAL_MS/HESITATION_DURATION_MS above, whose OWN
-- subtables are long-shipped and safe to assume present --
-- Config.Wellbeing.Hunger/.Thirst are brand new and this file does not own
-- config.lua, so they may not exist yet on a given server; see this file's
-- header for the full reasoning). Placed here, ahead of every event
-- handler in this file, specifically so every one of them can call it
-- unconditionally without a forward-reference problem.
-- ======================================================================
local ResolvedHungerThirstConfig = nil

--- @return table
local function GetResolvedHungerThirstConfig()
    if ResolvedHungerThirstConfig then return ResolvedHungerThirstConfig end

    local hungerCfg = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger or {}
    local thirstCfg = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst or {}

    ResolvedHungerThirstConfig = {
        hungerMax                    = ClampConfiguredNumber(hungerCfg.max, 100, 1, 1000, 'Config.Wellbeing.Hunger.max'),
        hungerDecayPerTick           = ClampConfiguredNumber(hungerCfg.decayPerTick, 0.093, 0, 100, 'Config.Wellbeing.Hunger.decayPerTick'),
        hungerSpeedPenaltyThreshold  = ClampConfiguredNumber(hungerCfg.lowThreshold, 30, 0, 100, 'Config.Wellbeing.Hunger.lowThreshold'),
        hungerSpeedPenaltyMultiplier = ClampConfiguredNumber(hungerCfg.speedPenaltyMultiplier, 0.95, 0.5, 1.0, 'Config.Wellbeing.Hunger.speedPenaltyMultiplier'),
        hungerFeedRegenAmount        = ClampConfiguredNumber(hungerCfg.feedRegenAmount, 35, 0, 1000, 'Config.Wellbeing.Hunger.feedRegenAmount'),
        hungerFeedItemName           = (type(hungerCfg.feedItemName) == 'string' and hungerCfg.feedItemName ~= '') and hungerCfg.feedItemName or 'k9_food',
        hungerFeedCooldownMs         = ResolveConfiguredThresholdMs(hungerCfg.feedCooldownMs, 120000, 'Config.Wellbeing.Hunger.feedCooldownMs'),

        thirstMax                    = ClampConfiguredNumber(thirstCfg.max, 100, 1, 1000, 'Config.Wellbeing.Thirst.max'),
        thirstDecayPerTick           = ClampConfiguredNumber(thirstCfg.decayPerTick, 0.139, 0, 100, 'Config.Wellbeing.Thirst.decayPerTick'),
        thirstSpeedPenaltyThreshold  = ClampConfiguredNumber(thirstCfg.lowThreshold, 30, 0, 100, 'Config.Wellbeing.Thirst.lowThreshold'),
        thirstSpeedPenaltyMultiplier = ClampConfiguredNumber(thirstCfg.speedPenaltyMultiplier, 0.95, 0.5, 1.0, 'Config.Wellbeing.Thirst.speedPenaltyMultiplier'),
        thirstDrinkRegenAmount       = ClampConfiguredNumber(thirstCfg.drinkRegenAmount, 35, 0, 1000, 'Config.Wellbeing.Thirst.drinkRegenAmount'),
        thirstDrinkItemName          = (type(thirstCfg.drinkItemName) == 'string' and thirstCfg.drinkItemName ~= '') and thirstCfg.drinkItemName or 'k9_water',
        thirstDrinkCooldownMs        = ResolveConfiguredThresholdMs(thirstCfg.drinkCooldownMs, 90000, 'Config.Wellbeing.Thirst.drinkCooldownMs'),
        thirstBowlRegenAmount        = ClampConfiguredNumber(thirstCfg.bowlRegenAmount, 15, 0, 1000, 'Config.Wellbeing.Thirst.bowlRegenAmount'),
        thirstBowlCooldownMs         = ResolveConfiguredThresholdMs(thirstCfg.bowlCooldownMs, 60000, 'Config.Wellbeing.Thirst.bowlCooldownMs'),
        thirstBowlInteractRange      = ClampConfiguredNumber(thirstCfg.bowlInteractRange, 2.0, 0.5, 20.0, 'Config.Wellbeing.Thirst.bowlInteractRange'),
        thirstBowlSources            = type(thirstCfg.bowlSources) == 'table' and thirstCfg.bowlSources or {},
    }
    return ResolvedHungerThirstConfig
end

-- Memoized model-hash set for Thirst's own bowlSources -- same pattern as
-- Fatigue's GetRestSourceModelHashes further below, deliberately a SEPARATE
-- list (not a re-read of Fatigue's own restSources) so a confirmed
-- replacement model can be set here without touching Fatigue's field. See
-- this file's header "WATER BOWL MODEL RISK" for the full disclosed-risk
-- writeup this inherits. GetHashKey is a server-side native (this file's
-- header CONFIDENCE GRADING item 6 already confirmed it directly against
-- citizenfx/fivem's own native-decls for Fatigue's identical use) -- safe to
-- call from here, well ahead of that confirmation's own call site.
local ThirstBowlModelHashes = nil

--- @return table<number, boolean>
local function GetThirstBowlModelHashes()
    if ThirstBowlModelHashes then return ThirstBowlModelHashes end

    ThirstBowlModelHashes = {}
    for _, modelName in ipairs(GetResolvedHungerThirstConfig().thirstBowlSources) do
        if type(modelName) == 'string' and modelName ~= '' then
            ThirstBowlModelHashes[GetHashKey(modelName)] = true
        end
    end
    return ThirstBowlModelHashes
end

--- Returns the citizenid's stat entry, creating a fresh default one on
--- first reference. Fatigue/Mood/Injury default to their own `max` (a K9
--- starts fresh, not exhausted/miserable/injured); FearStress defaults to 0
--- (calm); distractedUntil/hesitatingUntil default to 0 (inactive).
--- @param citizenid string
--- @return table stats
local function EnsureStats(citizenid)
    local stats = WellbeingStats[citizenid]
    if not stats then
        stats = {
            fatigue = Config.Wellbeing.Fatigue.max,
            mood = Config.Wellbeing.Mood.max,
            fearStress = 0,
            injury = Config.Wellbeing.Injury.max,
            distractedUntil = 0,
            hesitatingUntil = 0,
            hesitationEpisodeStartedAt = 0,
            lastCoords = nil,
            -- DEATH/RESPAWN RESET (this pass, coder-backend softlock fix,
            -- since redesigned by two FOLLOW-UP fixes): GetGameTimer() ms
            -- of the tick a tracked K9's native health is FIRST observed
            -- continuously at/below PED_DEAD_HEALTH_THRESHOLD; 0 = not
            -- currently in a candidate episode. See this file's header,
            -- STUCK-K9 SOFTLOCK FIX item 2 (both FOLLOW-UP notes), and
            -- TickWellbeing's own Injury branch below for the full
            -- read/qualify/reset cycle, and MIN_DEATH_EPISODE_DURATION_MS
            -- for the minimum episode span a restore requires. Starts 0: a
            -- freshly-referenced citizenid has never been observed dead by
            -- this tracker. TRANSIENT, PED-INSTANCE-SCOPED, NOT a persisted
            -- value — see the WellbeingStats struct comment above
            -- (category 2) for why this MUST be reset (to 0, not `false` —
            -- this is a timestamp) wherever lastCoords is reset.
            injuryDeathEpisodeStartedAt = 0,
            -- HUNGER/THIRST (this pass, coder-backend): PERSISTED, same
            -- category as fatigue/mood/fearStress/injury above -- "a K9 who
            -- logs off hungry should still be hungry on reconnect." Default
            -- to each stat's own max (a K9 starts fresh, not already
            -- starving), same convention as every other stat here.
            -- CONFIG-DEFENSIVE: `Config.Wellbeing.Hunger`/`.Thirst` may not
            -- exist yet on a server whose config.lua has not added them
            -- (this file does not own config.lua) -- EnsureStats runs
            -- unconditionally for EVERY stat regardless of which Features
            -- flag is on, so an unguarded `Config.Wellbeing.Hunger.max`
            -- read here would crash this function, and therefore every
            -- OTHER wellbeing feature, the instant anything referenced this
            -- citizenid -- not merely a HungerThirstSystem-gated failure.
            -- Guarded, not warned: this is an inert default, never an
            -- "activation" (see this file's header for that distinction) --
            -- the loud warning lives in GetResolvedHungerThirstConfig()
            -- below, reached only once the feature is actually gated on.
            hunger = (type(Config.Wellbeing.Hunger) == 'table' and tonumber(Config.Wellbeing.Hunger.max)) or 100,
            thirst = (type(Config.Wellbeing.Thirst) == 'table' and tonumber(Config.Wellbeing.Thirst.max)) or 100,
        }
        WellbeingStats[citizenid] = stats
    end
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
            MoodSystem = Config.Features.MoodSystem == true,
            FearStressSystem = Config.Features.FearStressSystem == true,
            DistractionSystem = Config.Features.DistractionSystem == true,
            InjuryLimping = Config.Features.InjuryLimping == true,
            HungerThirstSystem = Config.Features.HungerThirstSystem == true,
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
-- MOOD / INJURY — damage-event decay. Reuses server/tracking.lua's
-- ALREADY-REGISTERED 'qbx_k9unit:server:relayDamageEvent' (see this file's
-- header, EVENT/CALLBACK CONTRACT item 6). RegisterNetEvent is idempotent —
-- calling it again here makes this file's own dependency explicit rather
-- than implicit on load order.
-- ======================================================================
RegisterNetEvent('qbx_k9unit:server:relayDamageEvent')

local DamageRelayIngestCooldown = NewCooldown()
DamageRelayIngestCooldown.RegisterPlayerDropped()

AddEventHandler('qbx_k9unit:server:relayDamageEvent', function()
    if not (Config.Features.MoodSystem or Config.Features.InjuryLimping) then return end

    local src = source
    -- Reuses Config.Tracking.Blood.relayCooldownMs as the ingest-rate
    -- threshold — same numeric rate server/tracking.lua already applies to
    -- this identical event, via an independent tracker instance (see this
    -- file's header for why).
    if DamageRelayIngestCooldown.IsOnCooldown(src, Config.Tracking.Blood.relayCooldownMs) then return end
    DamageRelayIngestCooldown.Touch(src)

    local ped, isK9 = ResolveK9Ped(src)
    if ped == 0 or not isK9 then return end

    local citizenid = ResolveCitizenid(src)
    if not citizenid then return end

    local stats = EnsureStats(citizenid)
    -- PER-PERSON FEATURE CONTROL -- see IsWellbeingFeaturePermittedForCitizenId's
    -- own header for the full "immunity from harm, never a freeze" design.
    -- Gates ONLY the decrement (the harmful direction) -- passive regen in
    -- TickWellbeing below is never gated, so a blocked K9's mood/injury can
    -- only ever recover, never worsen, from this event.
    if Config.Features.MoodSystem and IsWellbeingFeaturePermittedForCitizenId(citizenid, 'MoodSystem') then
        stats.mood = Clamp(stats.mood - Config.Wellbeing.Mood.damageDecayAmount, 0, Config.Wellbeing.Mood.max)
    end
    if Config.Features.InjuryLimping and IsWellbeingFeaturePermittedForCitizenId(citizenid, 'InjuryLimping') then
        stats.injury = Clamp(stats.injury - Config.Wellbeing.Injury.damageDecayAmount, 0, Config.Wellbeing.Injury.max)
    end
end)

-- ======================================================================
-- FEARSTRESS — gunfire-proximity rise. Reuses server/tracking.lua's
-- ALREADY-REGISTERED 'qbx_k9unit:server:relayWeaponFire' event. Only logs
-- into RecentGunfire while FearStressSystem is enabled — per this file's
-- own "never gate/track anything a disabled flag hasn't activated" rule.
--
-- SECURITY FINDING B (coder-security, this pass), DISCLOSED, NOT FULLY
-- CLOSED — read before extending this section or wiring server/combat.lua's
-- IsHesitating() gate against it:
-- 'relayWeaponFire' is payload-less and forgeable BY DESIGN
-- (server/tracking.lua's own header "FORGED TRAIL DECISION" already accepts
-- this for ITS OWN gunpowder-tracking consumer, on the grounds that a
-- forged entry there only ever plants a harmless phantom trail location —
-- no real capability hinges on it). That acceptance does NOT automatically
-- extend to THIS consumer: unlike Mood/Injury's relayDamageEvent handler
-- above (self-only — it can only ever decrement the REPORTING player's own
-- citizenid), this handler deliberately affects OTHER connected K9s within
-- Config.Wellbeing.FearStress.gunfireRadius, with no wanted-status or
-- K9-model requirement on the reporter — required by the feature's own
-- design (a K9 near a firefight it isn't itself part of should still get
-- stressed, DEVELOPER_REFERENCE.md §13.4.3.3), but it means ANY connected player,
-- K9 or not, can call this repeatedly to affect a bystander K9 they have no
-- other interaction with. Today this is inert (nothing reads
-- IsHesitating() yet); once server/combat.lua gates bite-hold/takedown on
-- it, a sustained forged report becomes a real, renewable denial of a K9's
-- combat commands, not merely a cosmetic nuisance — the same category of
-- "accepted-risk invalidated by a later phase" server/tracking.lua's header
-- already flags as the ONE condition that would require revisiting ITS OWN
-- acceptance ("revisit ONLY if a later phase ever conditions something
-- server-authoritative on a resolved trail source").
--
-- FIXED THIS PASS (real, not just disclosed): `RecentGunfire` entries now
-- record the reporting `source`, and TickWellbeing's own nearbyShots
-- computation below counts DISTINCT reporting sources within range/lookback
-- (not raw log-entry count) — this closes the primary AMPLIFICATION vector
-- (one attacker's client bypassing its own local debounce and hammering
-- this event at the ingest cooldown's own rate limit, 300ms as configured,
-- previously let ONE source's spam pile up arbitrarily many log entries
-- within one Config.Wellbeing.FearStress.gunfireLookbackSeconds window,
-- multiplying fearStress's rise far beyond what one shooter's real,
-- continuous automatic fire should ever cause). Deduping by source bounds
-- one reporter's contribution to exactly what one continuously-firing real
-- shooter would also cause — which is the intended mechanic, not a gap.
--
-- STILL NOT FULLY CLOSED, BUT NO LONGER "INDEFINITE" (coder-security,
-- config-audit follow-up pass): deduping by source does not, and
-- structurally cannot without a real corroboration signal (this event
-- carries no payload to corroborate against, by design — see
-- server/tracking.lua's header for why adding one is a real can of worms,
-- not a cheap fix), prevent a SINGLE determined attacker from re-touching
-- this event to sustain elevated fearStress/hesitation on a nearby K9 with
-- zero real gunfire ever happening — mechanically indistinguishable,
-- server-side, from that one attacker genuinely firing continuously nearby.
--
-- THE SHAPE OF WHAT WENT WRONG, FOR THE NEXT EDITOR: this exact paragraph,
-- before this pass, called that residual risk "indefinite" and left it at
-- that — an accurate statement THE DAY IT WAS WRITTEN, because at that time
-- nothing anywhere read IsHesitating(). It silently stopped being accurate
-- the moment server/combat.lua's ValidateCombatRequest started calling
-- IsHesitating() as a hard reject (see that file's own header/
-- ValidateCombatRequest comments) — a second file began CONSUMING this
-- file's disclosed-but-accepted risk without this file's own disclosure
-- being re-checked against that new consumer. Neither file's own review
-- would have caught it in isolation: this file's review correctly says "the
-- signal is forgeable, but nothing acts on it yet"; combat.lua's review
-- correctly says "IsHesitating() is a real function I'm calling correctly,
-- per its own documented contract." The hole only exists in the SEAM
-- between the two — a disclosure whose truth depended on a fact (no
-- consumer exists) that a change in a different file quietly invalidated.
-- Anyone editing either file's hesitation-related code should re-check the
-- OTHER file's own disclosure before assuming it still holds.
--
-- THE FIX, THIS PASS: TickWellbeing below now caps how long ANY single
-- continuous at/above-hesitationThreshold episode may keep renewing
-- hesitatingUntil (see HESITATION_MAX_CONTINUOUS_MS's own comment at that
-- call site) before forcing fearStress back down and requiring a fresh
-- climb past the threshold. This does not, and cannot, tell a forged report
-- apart from a real one (same structural limit as above) — it bounds the
-- CONSEQUENCE instead: a forger can still force a K9 into repeated
-- hesitation episodes for as long as they keep re-touching this event, but
-- each episode is capped, and every episode is followed by a real,
-- enforced window in which the K9 is guaranteed NOT to be hesitating and
-- server/combat.lua's gate will grant requests normally again. "Indefinite,
-- renewable denial of a specific K9's combat commands" is closed; "a
-- forger who stays near one K9 can repeatedly force short disruptions" is
-- the disclosed, accepted, BOUNDED risk that replaces it. Revisit if live
-- abuse ever shows this bounded version is still disruptive enough to
-- matter, mirroring the exact "revisit if a later phase changes the
-- stakes"/"revisit if live abuse confirms this is a real problem in
-- practice" framing server/tracking.lua's and this section's own prior
-- text already used.
-- ======================================================================
RegisterNetEvent('qbx_k9unit:server:relayWeaponFire')

local GunfireRelayIngestCooldown = NewCooldown()
GunfireRelayIngestCooldown.RegisterPlayerDropped()

AddEventHandler('qbx_k9unit:server:relayWeaponFire', function()
    if not Config.Features.FearStressSystem then return end

    local src = source
    -- Reuses Config.Tracking.Gunpowder.relayCooldownMs — same reasoning as
    -- the damage-relay ingest cooldown above.
    if GunfireRelayIngestCooldown.IsOnCooldown(src, Config.Tracking.Gunpowder.relayCooldownMs) then return end
    GunfireRelayIngestCooldown.Touch(src)

    local ped = GetPlayerPed(src)
    if ped == 0 then return end

    -- Deliberately NOT restricted to a K9-modeled shooter — FearStress
    -- reacts to ANY nearby gunfire (DEVELOPER_REFERENCE.md §13.4.3.3's own
    -- "gunfire happened nearby" framing), not just gunfire a K9 itself
    -- caused.
    -- `source = src` added this pass (coder-security finding B) so
    -- TickWellbeing's nearbyShots computation below can dedupe by reporting
    -- source instead of counting raw log entries — see this section's own
    -- header comment above for the full exploit/fix writeup.
    RecentGunfire[#RecentGunfire + 1] = { coords = GetEntityCoords(ped), loggedAt = GetGameTimer(), source = src }
end)

-- SECURITY FIX (coder-security, config-audit follow-up pass): bounds how
-- long a SINGLE continuous at/above-hesitationThreshold episode may keep
-- renewing `hesitatingUntil` in TickWellbeing below. The structural problem
-- (see the relayWeaponFire AddEventHandler's own header above and
-- IsHesitating's doc comment) is that the server cannot tell a forged
-- reporter apart from one real, continuously-firing shooter — both look
-- identical as "at least one nearby source reporting fire within the
-- lookback window." Rather than chase that unsolvable signal problem, this
-- caps the CONSEQUENCE: once an episode has been continuously renewing for
-- HESITATION_MAX_CONTINUOUS_MS, TickWellbeing force-resets fearStress to 0
-- and requires a fresh climb back past hesitationThreshold before
-- hesitatingUntil can be extended again — guaranteeing every episode is
-- followed by a real window (at minimum, however long that fresh climb
-- takes) in which server/combat.lua's ValidateCombatRequest is guaranteed
-- to grant, not reject, a bite-hold/takedown request for this K9.
-- Deliberately derived from Config.Wellbeing.FearStress.hesitationDurationMs
-- (8 renewal-cycles' worth) rather than a bare magic number, so it scales
-- automatically if that value is retuned later, and deliberately a LOCAL
-- constant rather than a new Config.Wellbeing.FearStress field: this file's
-- own MOOD_INTERACT_RANGE/DISTRACTION_COOLDOWN_PRUNE_INTERVAL_MS above are
-- the established precedent for a small, disclosed, non-spec value living
-- here rather than in config.lua.
--
-- VALIDATED (audit follow-up, same TICK_INTERVAL_MS shape/reasoning above):
-- `Config.Wellbeing.FearStress.hesitationDurationMs` was previously read raw
-- here, in a top-level, unconditional multiplication reached at this file's
-- own load time — a non-numeric/non-positive value would have thrown
-- immediately and aborted server/wellbeing.lua's load from this line
-- onward, the exact same class of failure TICK_INTERVAL_MS above was just
-- fixed for. Resolved once into HESITATION_DURATION_MS (CLAMP AND WARN,
-- never abort) and reused below at this file's other raw read of the same
-- field (the hesitatingUntil extension further down), so both stay
-- consistent with each other. Same fallback (8000ms) as config.lua's own
-- shipped default for this field.
local HESITATION_DURATION_MS = ResolveConfiguredThresholdMs(
    Config.Wellbeing.FearStress.hesitationDurationMs, 8000, 'Config.Wellbeing.FearStress.hesitationDurationMs')
local HESITATION_MAX_CONTINUOUS_MS = HESITATION_DURATION_MS * 8

-- ======================================================================
-- MOOD — "Pet K9" / "Feed K9" ox_target interactions (client/wellbeing.lua).
-- ======================================================================

-- Live-proximity radius for both interactions below. NOT in
-- DEVELOPER_REFERENCE.md §13.2's sketch (that document names ox_target interactions
-- but no explicit interact-range value for them) — a small, disclosed
-- addition needed to satisfy the spec's own "server-enforced live proximity,
-- never a client-claimed distance" mandate (§13.4.3.2's server-authority
-- point). Same order of magnitude as Config.K9Inventory.interactRange/
-- Config.K9Medkit.range.
local MOOD_INTERACT_RANGE = 3.0

-- Shared by BOTH petK9 and feedK9 below (feedK9's own cooldown check
-- reuses this SAME tracker instance, not a second independent one -- see
-- that call site's own comment for why this instance identity is the whole
-- point, not just the threshold value).
local AffectionCooldown = NewNestedCooldown()
AffectionCooldown.RegisterPlayerDropped()

--- DEVELOPER_REFERENCE.md §13.4.3.2. Server-authoritative "Pet K9" interaction.
lib.callback.register('qbx_k9unit:server:petK9', function(source, targetServerId)
    if type(targetServerId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' }
    end
    if not Config.Features.MoodSystem then
        return { ok = false, reason = 'feature_disabled' }
    end

    local usingPed = GetPlayerPed(source)
    if usingPed == 0 then return { ok = false, reason = 'invalid_target' } end

    local targetPed, targetIsK9 = ResolveK9Ped(targetServerId)
    if targetPed == 0 or targetPed == usingPed or not targetIsK9 then
        return { ok = false, reason = 'invalid_target' }
    end

    local dist = #(GetEntityCoords(usingPed) - GetEntityCoords(targetPed))
    if dist > MOOD_INTERACT_RANGE then
        return { ok = false, reason = 'too_far' }
    end

    local targetCitizenid = ResolveCitizenid(targetServerId)
    if not targetCitizenid then return { ok = false, reason = 'invalid_target' } end

    if AffectionCooldown.IsOnCooldown(source, targetCitizenid, Config.Wellbeing.Mood.petCooldownMs) then
        return { ok = false, reason = 'on_cooldown' }
    end
    AffectionCooldown.Touch(source, targetCitizenid)

    local stats = EnsureStats(targetCitizenid)
    stats.mood = Clamp(stats.mood + Config.Wellbeing.Mood.petRegenAmount, 0, Config.Wellbeing.Mood.max)

    return { ok = true }
end)

-- REWARD-FARM FIX (this pass, coder-backend): deliberately reuses
-- petK9's AffectionCooldown TRACKER INSTANCE (not merely petCooldownMs's
-- threshold VALUE) for the same (source, targetCitizenid) pair — feeding
-- and petting are the same class of "affection" interaction DEVELOPER_REFERENCE.md
-- §13.4.3.2 groups together, and only sharing the actual instance stops a
-- player alternating pet/feed calls to double their effective mood-regen
-- rate. This file previously declared a SECOND, independent
-- NewNestedCooldown() here (same threshold value, separate store) while its
-- own comment claimed the two calls "shared a single cooldown" — they did
-- not: a player could petK9 then immediately feedK9 (or vice versa) on the
-- same target, since each tracked its own (source, targetCitizenid) key in
-- its own private table, getting two mood-regen ticks inside one
-- petCooldownMs window instead of one. Fixed by having feedK9 below check/
-- stamp the SAME `AffectionCooldown` instance petK9 uses, not a
-- same-threshold-but-different-table lookalike.

--- DEVELOPER_REFERENCE.md §13.4.3.2. Server-authoritative "Feed K9" interaction.
--- Mirrors server/medkit.lua's item-consumption discipline exactly:
--- possession check (cheap, non-mutating) before the cooldown is stamped,
--- cooldown stamped BEFORE removal (TOCTOU-safe ordering), state mutated
--- only after a real item was actually removed.
lib.callback.register('qbx_k9unit:server:feedK9', function(source, targetServerId)
    if type(targetServerId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' }
    end
    if not Config.Features.MoodSystem then
        return { ok = false, reason = 'feature_disabled' }
    end

    local usingPed = GetPlayerPed(source)
    if usingPed == 0 then return { ok = false, reason = 'invalid_target' } end

    local targetPed, targetIsK9 = ResolveK9Ped(targetServerId)
    if targetPed == 0 or targetPed == usingPed or not targetIsK9 then
        return { ok = false, reason = 'invalid_target' }
    end

    local dist = #(GetEntityCoords(usingPed) - GetEntityCoords(targetPed))
    if dist > MOOD_INTERACT_RANGE then
        return { ok = false, reason = 'too_far' }
    end

    local targetCitizenid = ResolveCitizenid(targetServerId)
    if not targetCitizenid then return { ok = false, reason = 'invalid_target' } end

    if AffectionCooldown.IsOnCooldown(source, targetCitizenid, Config.Wellbeing.Mood.petCooldownMs) then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- ROUTED THROUGH K9Compat.Get('inventory') (this pass, coder-backend) --
    -- shared/compat/core.lua's RequiredMethods.inventory.server -- never a
    -- direct `exports.ox_inventory:...` call. STUB-DEGRADE: on the no-op
    -- stub, GetItemCount fails closed to `0` (never a fabricated count),
    -- so this reads as `no_item` -- a clean, disclosed "feature switched
    -- off" degrade, same reason string this file already used for a real
    -- missing-item case. RemoveItem fails closed to `false` the same way.
    -- On qb-inventory (the other CONFIRMED backend), both are REAL
    -- (composed onto that backend's own confirmed GetItemCount/RemoveItem
    -- exports) with no disclosed gap for this plain single-item usage.
    local carriedCount = K9Compat.Get('inventory').GetItemCount(source, Config.Wellbeing.Mood.feedItemName)
    if not carriedCount or carriedCount < 1 then
        return { ok = false, reason = 'no_item' }
    end

    AffectionCooldown.Touch(source, targetCitizenid)

    local removed = K9Compat.Get('inventory').RemoveItem(source, Config.Wellbeing.Mood.feedItemName, 1)
    if not removed then
        return { ok = false, reason = 'no_item' }
    end

    local stats = EnsureStats(targetCitizenid)
    stats.mood = Clamp(stats.mood + Config.Wellbeing.Mood.feedRegenAmount, 0, Config.Wellbeing.Mood.max)

    return { ok = true }
end)

-- ======================================================================
-- FEARSTRESS — "Calm Down" self-only action. DEVELOPER_REFERENCE.md §13.4.3.3 open
-- question 2's own tentative reading (self-only, mirrors K9Sit) is taken
-- here — no target parameter exists at all, so there is no "force another
-- player's K9 to calm down" vector to guard against.
-- ======================================================================
local CalmDownCooldown = NewCooldown()
CalmDownCooldown.RegisterPlayerDropped()

RegisterNetEvent('qbx_k9unit:server:calmDownK9', function()
    local src = source
    if not Config.Features.FearStressSystem then return end

    local ped, isK9 = ResolveK9Ped(src)
    if ped == 0 or not isK9 then return end

    if CalmDownCooldown.IsOnCooldown(src, Config.Wellbeing.FearStress.calmDownCooldownMs) then
        NotifyPlayer(src, locale('wellbeing.calm_down_on_cooldown'), 'error')
        return
    end
    CalmDownCooldown.Touch(src)

    local citizenid = ResolveCitizenid(src)
    if not citizenid then return end

    local stats = EnsureStats(citizenid)
    stats.fearStress = Clamp(stats.fearStress - Config.Wellbeing.FearStress.calmDownReduceAmount, 0, Config.Wellbeing.FearStress.max)
    NotifyPlayer(src, locale('wellbeing.calm_down_success'), 'success')
end)

-- ======================================================================
-- DISTRACTION — item-triggered ("meat bait" / "ultrasonic whistle").
-- DEVELOPER_REFERENCE.md §13.4.3.4. Deliberately open to ANY player, not gated on
-- Config.Departments/HasK9Access — see this file's header EVENT/CALLBACK
-- CONTRACT item 4 for why (this document's own tentative reading of the
-- open question).
-- ======================================================================

-- Per-target (K9 citizenid) cooldown, outlives any single connection —
-- needs its own TTL sweep, mirroring server/medkit.lua's MedkitCooldown
-- exactly (same "resolved identity, not a raw session id" discipline, same
-- sweep-based cleanup for a tracker with no natural per-connection hook).
local DistractionCooldown = NewCooldown()
local DISTRACTION_COOLDOWN_PRUNE_INTERVAL_MS = 60000
DistractionCooldown.StartSweep(DISTRACTION_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    local staleAfterMs = Config.Wellbeing.Distraction.perTargetCooldownMs * 2
    return (now - loggedAt) > staleAfterMs
end)

--- DEVELOPER_REFERENCE.md §13.4.3.4. Server-authoritative distraction-item use.
lib.callback.register('qbx_k9unit:server:applyK9Distraction', function(source, itemType)
    if itemType ~= 'meatBait' and itemType ~= 'whistle' then
        return { ok = false, reason = 'invalid_item' }
    end
    if not Config.Features.DistractionSystem then
        return { ok = false, reason = 'feature_disabled' }
    end

    local usingPed = GetPlayerPed(source)
    if usingPed == 0 then return { ok = false, reason = 'invalid_target' } end

    local D = Config.Wellbeing.Distraction
    local itemName, radius, durationMs
    if itemType == 'meatBait' then
        itemName, radius, durationMs = D.meatBaitItemName, D.meatBaitRadius, D.meatBaitDurationMs
    else
        itemName, radius, durationMs = D.whistleItemName, D.whistleRadius, D.whistleDurationMs
    end

    -- ROUTED THROUGH K9Compat.Get('inventory') -- see the Mood/petK9 callback
    -- above (this same file) for the full stub-degrade writeup; identical
    -- shape and identical degrade here (fails closed to `no_item`, never a
    -- crash or a fabricated success).
    local carriedCount = K9Compat.Get('inventory').GetItemCount(source, itemName)
    if not carriedCount or carriedCount < 1 then
        return { ok = false, reason = 'no_item' }
    end

    local removed = K9Compat.Get('inventory').RemoveItem(source, itemName, 1)
    if not removed then
        return { ok = false, reason = 'no_item' }
    end

    -- Resolves affected K9s from the USING PLAYER'S OWN live position —
    -- never a client-claimed coordinate (mirrors server/tracking.lua's own
    -- "resolve the reporting party's own position" rule).
    local originCoords = GetEntityCoords(usingPed)
    local now = GetGameTimer()
    local affected = 0

    for _, playerId in ipairs(GetPlayers()) do
        local targetSrc = tonumber(playerId)
        if targetSrc then
            local targetPed, targetIsK9 = ResolveK9Ped(targetSrc)
            if targetPed ~= 0 and targetIsK9 then
                local dist = #(GetEntityCoords(targetPed) - originCoords)
                if dist <= radius then
                    local targetCitizenid = ResolveCitizenid(targetSrc)
                    -- PER-PERSON FEATURE CONTROL -- checked BEFORE the
                    -- per-target cooldown below, so a blocked K9's own
                    -- cooldown slot is never spent on an attempt that was
                    -- always going to be refused (matches this file's own
                    -- "immunity from harm" design -- see
                    -- IsWellbeingFeaturePermittedForCitizenId's header).
                    if targetCitizenid and IsWellbeingFeaturePermittedForCitizenId(targetCitizenid, 'DistractionSystem')
                        and not DistractionCooldown.IsOnCooldown(targetCitizenid, D.perTargetCooldownMs, now) then
                        DistractionCooldown.Touch(targetCitizenid, now)
                        local stats = EnsureStats(targetCitizenid)
                        stats.distractedUntil = now + durationMs
                        affected = affected + 1
                    end
                end
            end
        end
    end

    return { ok = true, affected = affected }
end)

-- ======================================================================
-- HUNGER/THIRST — self-only relief actions (this pass, coder-backend). See
-- this file's header "SELF-SERVICE, A DELIBERATE DIVERGENCE FROM MOOD" for
-- why these are plain, targetless RegisterNetEvent handlers (exactly
-- calmDownK9's shape above) rather than an ox_target option on another
-- player's ped. Client-side triggers: `/k9eat` (feedK9Hunger), `/k9drink`
-- (giveK9Water), and the "Drink from Bowl" ox_target world-object option
-- (drinkFromBowl) -- all three in client/wellbeing.lua.
--
-- ANTI-FARM: each tracker below is keyed by CITIZENID (the stat owner, not
-- the raw connection `source`) -- a citizenid, not a session, is what a
-- cooldown against "how often can THIS K9 be fed" needs to bound, matching
-- DistractionCooldown's own established per-citizenid shape above (not
-- AffectionCooldown's per-(interactor,target) shape, since these are
-- self-only -- there is no separate interactor identity to key on). Every
-- possession check happens BEFORE the cooldown is stamped, and the cooldown
-- is stamped BEFORE item removal -- the exact TOCTOU-safe ordering
-- feedK9/K9Medkit already established. None of these three checks
-- IsWellbeingFeaturePermittedForCitizenId -- exactly like petK9/feedK9/
-- RestoreInjury above, a RELIEF action is never gated by a per-person harm
-- block (see that function's own header for the full "immunity from harm,
-- never gate relief" design).
-- ======================================================================

-- Shared by feedK9Hunger only (Hunger has no world-prop path).
local HungerFeedCooldown = NewCooldown()
local HUNGER_FEED_COOLDOWN_PRUNE_INTERVAL_MS = 60000
HungerFeedCooldown.StartSweep(HUNGER_FEED_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    local staleAfterMs = GetResolvedHungerThirstConfig().hungerFeedCooldownMs * 2
    return (now - loggedAt) > staleAfterMs
end)

-- SHARED by BOTH giveK9Water (item) and drinkFromBowl (world prop) --
-- deliberately the SAME tracker instance, not merely the same threshold
-- shape, mirroring AffectionCooldown's own established "one shared instance
-- for two actions that restore the same stat" fix above (see that
-- declaration's own comment for the exploit this closes): alternating
-- "drink from bowl" then "use water item" on yourself must not double the
-- effective thirst-regen rate within one cooldown window. The two actions
-- use DIFFERENT thresholds (thirstDrinkCooldownMs vs. thirstBowlCooldownMs)
-- at their own :IsOnCooldown/:Touch call sites — NewCooldown's per-call
-- threshold override (the same mechanism DistractionCooldown's own
-- per-target cooldown above already relies on) makes that safe: whichever
-- action fires first stamps `now`, and the OTHER action's own (possibly
-- different) threshold is what decides whether that stamp still blocks it.
local ThirstReliefCooldown = NewCooldown()
local THIRST_RELIEF_COOLDOWN_PRUNE_INTERVAL_MS = 60000
ThirstReliefCooldown.StartSweep(THIRST_RELIEF_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    local hc = GetResolvedHungerThirstConfig()
    local staleAfterMs = math.max(hc.thirstDrinkCooldownMs, hc.thirstBowlCooldownMs) * 2
    return (now - loggedAt) > staleAfterMs
end)

RegisterNetEvent('qbx_k9unit:server:feedK9Hunger')
AddEventHandler('qbx_k9unit:server:feedK9Hunger', function()
    local src = source
    if not Config.Features.HungerThirstSystem then return end

    local ped, isK9 = ResolveK9Ped(src)
    if ped == 0 or not isK9 then return end

    local citizenid = ResolveCitizenid(src)
    if not citizenid then return end

    local hc = GetResolvedHungerThirstConfig()
    if HungerFeedCooldown.IsOnCooldown(citizenid, hc.hungerFeedCooldownMs) then
        NotifyPlayer(src, locale('wellbeing.reason_on_cooldown'), 'error')
        return
    end

    -- ROUTED THROUGH K9Compat.Get('inventory') -- same stub-degrade writeup
    -- as Mood's feedK9/Distraction's applyK9Distraction above: fails closed
    -- to 0/false on the no-op stub, never a fabricated success.
    local carriedCount = K9Compat.Get('inventory').GetItemCount(src, hc.hungerFeedItemName)
    if not carriedCount or carriedCount < 1 then
        NotifyPlayer(src, locale('wellbeing.reason_no_food'), 'error')
        return
    end

    -- Cooldown stamped BEFORE removal — TOCTOU-safe ordering, matches
    -- feedK9/K9Medkit exactly.
    HungerFeedCooldown.Touch(citizenid)

    local removed = K9Compat.Get('inventory').RemoveItem(src, hc.hungerFeedItemName, 1)
    if not removed then
        NotifyPlayer(src, locale('wellbeing.reason_no_food'), 'error')
        return
    end

    local stats = EnsureStats(citizenid)
    stats.hunger = Clamp(stats.hunger + hc.hungerFeedRegenAmount, 0, hc.hungerMax)
    NotifyPlayer(src, locale('wellbeing.eat_success'), 'success')
end)

RegisterNetEvent('qbx_k9unit:server:giveK9Water')
AddEventHandler('qbx_k9unit:server:giveK9Water', function()
    local src = source
    if not Config.Features.HungerThirstSystem then return end

    local ped, isK9 = ResolveK9Ped(src)
    if ped == 0 or not isK9 then return end

    local citizenid = ResolveCitizenid(src)
    if not citizenid then return end

    local hc = GetResolvedHungerThirstConfig()
    if ThirstReliefCooldown.IsOnCooldown(citizenid, hc.thirstDrinkCooldownMs) then
        NotifyPlayer(src, locale('wellbeing.reason_on_cooldown'), 'error')
        return
    end

    local carriedCount = K9Compat.Get('inventory').GetItemCount(src, hc.thirstDrinkItemName)
    if not carriedCount or carriedCount < 1 then
        NotifyPlayer(src, locale('wellbeing.reason_no_water'), 'error')
        return
    end

    ThirstReliefCooldown.Touch(citizenid)

    local removed = K9Compat.Get('inventory').RemoveItem(src, hc.thirstDrinkItemName, 1)
    if not removed then
        NotifyPlayer(src, locale('wellbeing.reason_no_water'), 'error')
        return
    end

    local stats = EnsureStats(citizenid)
    stats.thirst = Clamp(stats.thirst + hc.thirstDrinkRegenAmount, 0, hc.thirstMax)
    NotifyPlayer(src, locale('wellbeing.drink_success'), 'success')
end)

--- @param netId number -- the world bowl object's own network id, resolved client-side from the ox_target `data.entity` the player actually clicked
RegisterNetEvent('qbx_k9unit:server:drinkFromBowl')
AddEventHandler('qbx_k9unit:server:drinkFromBowl', function(netId)
    local src = source
    if not Config.Features.HungerThirstSystem then return end

    local ped, isK9 = ResolveK9Ped(src)
    if ped == 0 or not isK9 then return end

    local hc = GetResolvedHungerThirstConfig()
    if #hc.thirstBowlSources == 0 then return end -- no bowl model configured at all -- see this file's header "WATER BOWL MODEL RISK"

    -- SERVER-AUTHORITATIVE ENTITY RESOLUTION — reuses server/entities.lua's
    -- shared ResolveNetworkEntity (netId -> live entity, existence-checked,
    -- type-checked) rather than a hand-rolled NetworkGetEntityFromNetworkId/
    -- DoesEntityExist pair, per that file's own "extracted from independent
    -- hand-written copies" header. expectedEntityType = 3 (object) — a
    -- client cannot claim a bowl netId that actually resolves to a ped or
    -- vehicle.
    local bowlEntity = ResolveNetworkEntity(netId, 3)
    if not bowlEntity then return end

    -- Never trusts the client's claim about WHICH object this is — the
    -- model is re-derived server-side against Thirst's own bowlSources
    -- hash set, exactly like Fatigue's rest-source scan re-derives model
    -- identity above.
    if not GetThirstBowlModelHashes()[GetEntityModel(bowlEntity)] then return end

    -- Never trusts a client-claimed distance — both positions are resolved
    -- server-side (the caller's own live ped, and the bowl entity just
    -- proven to exist).
    local dist = #(GetEntityCoords(ped) - GetEntityCoords(bowlEntity))
    if dist > hc.thirstBowlInteractRange then return end

    local citizenid = ResolveCitizenid(src)
    if not citizenid then return end

    if ThirstReliefCooldown.IsOnCooldown(citizenid, hc.thirstBowlCooldownMs) then
        NotifyPlayer(src, locale('wellbeing.reason_on_cooldown'), 'error')
        return
    end
    ThirstReliefCooldown.Touch(citizenid)

    local stats = EnsureStats(citizenid)
    stats.thirst = Clamp(stats.thirst + hc.thirstBowlRegenAmount, 0, hc.thirstMax)
    NotifyPlayer(src, locale('wellbeing.drink_success'), 'success')
end)

-- ======================================================================
-- RESOURCE-GLOBALS — see this file's header for the full contract on each.
-- ======================================================================

--- @param citizenid string
--- @param amount number
function RestoreInjury(citizenid, amount)
    if not Config.Features.InjuryLimping then return end
    if type(citizenid) ~= 'string' or citizenid == '' or type(amount) ~= 'number' then return end

    -- Never move the value downward via this accessor, mirroring
    -- server/medkit.lua's own "never move health downward" health-restore
    -- discipline.
    amount = math.max(amount, 0)

    local stats = EnsureStats(citizenid)
    stats.injury = Clamp(stats.injury + amount, 0, Config.Wellbeing.Injury.max)
end

--- @param citizenid string
--- @return boolean
function IsHesitating(citizenid)
    if not Config.Features.FearStressSystem then return false end
    if type(citizenid) ~= 'string' then return false end

    -- PER-PERSON FEATURE CONTROL, belt-and-suspenders on top of the
    -- escalation gate at this file's own relayWeaponFire/TickWellbeing call
    -- sites: fails closed to "not hesitating" for a blocked citizenid
    -- regardless of whatever `hesitatingUntil` currently holds -- see
    -- IsWellbeingFeaturePermittedForCitizenId's own header for why this also
    -- gives high command a real, immediate tool against the disclosed
    -- forged-gunfire hesitation risk (SECURITY FINDING B, this file's
    -- header) for one specific victim.
    if not IsWellbeingFeaturePermittedForCitizenId(citizenid, 'FearStressSystem') then return false end

    local stats = WellbeingStats[citizenid]
    return stats ~= nil and stats.hesitatingUntil > GetGameTimer()
end

--- @param citizenid string
--- @return boolean
function IsDistracted(citizenid)
    if not Config.Features.DistractionSystem then return false end
    if type(citizenid) ~= 'string' then return false end

    -- PER-PERSON FEATURE CONTROL, belt-and-suspenders on top of the
    -- per-target gate in applyK9Distraction above -- same reasoning as
    -- IsHesitating's identical guard just above.
    if not IsWellbeingFeaturePermittedForCitizenId(citizenid, 'DistractionSystem') then return false end

    local stats = WellbeingStats[citizenid]
    return stats ~= nil and stats.distractedUntil > GetGameTimer()
end

--- Config.Wellbeing.Distraction.flashbangImmune's real, callable half — see
--- this file's header CONFIDENCE GRADING item 5 for the full writeup on
--- what is and isn't solved by this accessor existing. Deliberately reads
--- NO per-citizenid state (unlike IsHesitating/IsDistracted above) — a
--- flashbang-immune K9 is immune because of static config, not because of
--- anything that has happened to it, so there is nothing to look up. The
--- `citizenid` parameter exists only to match the established accessor
--- shape/type-guard convention, not because this function's answer can
--- ever differ per citizenid today.
--- SELF-DETERMINED, NOT INFLUENCEABLE: this function's return value can
--- NEVER be changed by another player's action, another player's
--- proximity, or any forgeable client-triggered signal — it is a pure
--- function of static server config. It is not, and cannot become, the
--- same class of lever `relayWeaponFire`/`IsHesitating` were before this
--- pass's HESITATION_MAX_CONTINUOUS_MS cap.
--- @param citizenid string
--- @return boolean
function IsFlashbangImmune(citizenid)
    if not Config.Features.DistractionSystem then return false end
    if type(citizenid) ~= 'string' then return false end

    return Config.Wellbeing.Distraction.flashbangImmune == true
end

-- ======================================================================
-- ON-DEMAND SNAPSHOT — see this file's header EVENT/CALLBACK CONTRACT
-- item 1.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:getWellbeingSnapshot', function(source)
    if not (Config.Features.FatigueSystem or Config.Features.MoodSystem
        or Config.Features.FearStressSystem or Config.Features.DistractionSystem
        or Config.Features.InjuryLimping or Config.Features.HungerThirstSystem) then
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

    -- Prune gunfire entries FearStress could no longer care about — once
    -- per tick, before the per-player pass below reads RecentGunfire.
    if Config.Features.FearStressSystem then
        local lookbackMs = Config.Wellbeing.FearStress.gunfireLookbackSeconds * 1000
        local fresh = {}
        for _, entry in ipairs(RecentGunfire) do
            if (now - entry.loggedAt) <= lookbackMs then
                fresh[#fresh + 1] = entry
            end
        end
        RecentGunfire = fresh
    end

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
                                stats.fatigue = Clamp(stats.fatigue - Config.Wellbeing.Fatigue.sprintDecayPerTick, 0, Config.Wellbeing.Fatigue.max)
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

                    if Config.Features.MoodSystem then
                        stats.mood = Clamp(stats.mood + Config.Wellbeing.Mood.passiveRegenPerTick, 0, Config.Wellbeing.Mood.max)
                    end

                    if Config.Features.HungerThirstSystem then
                        -- HUNGER/THIRST (this pass, coder-backend). Passive
                        -- DECAY only -- see this file's header for why there
                        -- is no passive regen path for either stat (eating/
                        -- drinking is the only intended recovery, matching
                        -- every mainstream hunger/thirst framework this
                        -- resource's own task brief researched). PER-PERSON
                        -- FEATURE CONTROL gates ONLY this decrement (the
                        -- harmful direction) -- exactly the "immunity from
                        -- harm, never a freeze" design
                        -- IsWellbeingFeaturePermittedForCitizenId's own
                        -- header establishes for every other stat above; a
                        -- blocked citizenid simply never decays, and can
                        -- still be fed/watered normally regardless (feedK9Hunger/
                        -- giveK9Water/drinkFromBowl below never check this
                        -- gate at all, same as petK9/feedK9/RestoreInjury).
                        if IsWellbeingFeaturePermittedForCitizenId(citizenid, 'HungerThirstSystem') then
                            local hc = GetResolvedHungerThirstConfig()
                            stats.hunger = Clamp(stats.hunger - hc.hungerDecayPerTick, 0, hc.hungerMax)
                            stats.thirst = Clamp(stats.thirst - hc.thirstDecayPerTick, 0, hc.thirstMax)
                        end
                    end

                    if Config.Features.InjuryLimping then
                        -- DEATH/RESPAWN RESET — see this file's header,
                        -- STUCK-K9 SOFTLOCK FIX item 2 (read BOTH FOLLOW-UP
                        -- notes before touching this block), and
                        -- MIN_DEATH_EPISODE_DURATION_MS's own doc comment,
                        -- for the full decision writeup and exactly what
                        -- this heuristic does and does not detect.
                        -- `coords`/`ped` above already resolve this K9's own
                        -- live, server-held state this tick; the one extra
                        -- native call here (GetEntityHealth) is gated behind
                        -- InjuryLimping specifically, per this file's own
                        -- "never call/track anything a disabled flag hasn't
                        -- activated" discipline.
                        local isDeadNow = GetEntityHealth(ped) <= PED_DEAD_HEALTH_THRESHOLD
                        if isDeadNow then
                            -- Mark the START of a candidate episode only
                            -- once — a continuing dead stretch must not keep
                            -- pushing this timestamp forward, or its
                            -- measured span would never grow and could never
                            -- qualify.
                            if stats.injuryDeathEpisodeStartedAt == 0 then
                                stats.injuryDeathEpisodeStartedAt = now
                            end
                        elseif stats.injuryDeathEpisodeStartedAt ~= 0 then
                            -- Alive again: this candidate episode is OVER
                            -- either way, and is cleared UNCONDITIONALLY
                            -- below regardless of whether it qualifies — a
                            -- disqualified short episode must never be
                            -- "topped up" by a later, separate one; each
                            -- candidate is judged exactly once, at the
                            -- instant it ends. Only a genuinely long-enough
                            -- span (see MIN_DEATH_EPISODE_DURATION_MS) pays
                            -- out — this is what stops an ordinary combat
                            -- dip (grazed to ~90, healed a moment later)
                            -- from reading as a real down-and-revive.
                            if (now - stats.injuryDeathEpisodeStartedAt) >= MIN_DEATH_EPISODE_DURATION_MS then
                                local restoreAmount = tonumber(Config.Wellbeing.Injury.deathRespawnRestoreAmount)
                                if restoreAmount and restoreAmount > 0 then
                                    stats.injury = Clamp(stats.injury + restoreAmount, 0, Config.Wellbeing.Injury.max)
                                end
                            end
                            stats.injuryDeathEpisodeStartedAt = 0
                        end

                        -- Passive regen is deliberately SKIPPED for a tick
                        -- where the K9 is observed at/below
                        -- PED_DEAD_HEALTH_THRESHOLD (isDeadNow) — a K9 in
                        -- that state does not passively recover from its
                        -- injuries; the restore above (when a QUALIFYING
                        -- episode ends) is the intended recovery moment for
                        -- a genuine down/revive, and normal passive regen
                        -- resumes from the very same tick a disqualified
                        -- (too-short) episode ends, same as any other alive
                        -- tick.
                        if not isDeadNow then
                            stats.injury = Clamp(stats.injury + Config.Wellbeing.Injury.passiveRegenPerTick, 0, Config.Wellbeing.Injury.max)
                        end
                    end

                    if Config.Features.FearStressSystem then
                        -- SECURITY FIX (coder-security finding B, this
                        -- pass): count DISTINCT reporting sources within
                        -- range/lookback, not raw log-entry count — see the
                        -- relayWeaponFire AddEventHandler's own header
                        -- comment above for the full exploit/fix writeup.
                        -- One source's repeated reports (whether genuine
                        -- sustained automatic fire or a spammed forged
                        -- event) now contributes AT MOST ONE toward
                        -- nearbyShots per tick, same as one real,
                        -- continuously-firing shooter should.
                        local nearbyShots = 0
                        local seenSources = {}
                        local lookbackMs = Config.Wellbeing.FearStress.gunfireLookbackSeconds * 1000
                        for _, entry in ipairs(RecentGunfire) do
                            if (now - entry.loggedAt) <= lookbackMs and #(entry.coords - coords) <= Config.Wellbeing.FearStress.gunfireRadius then
                                if not seenSources[entry.source] then
                                    seenSources[entry.source] = true
                                    nearbyShots = nearbyShots + 1
                                end
                            end
                        end

                        -- PER-PERSON FEATURE CONTROL -- see
                        -- IsWellbeingFeaturePermittedForCitizenId's own
                        -- header. A blocked citizenid never accumulates
                        -- fearStress from nearby gunfire (real or forged --
                        -- see this section's own SECURITY FINDING B writeup
                        -- above), and therefore always takes the passive
                        -- DECAY branch instead -- IsHesitating() below
                        -- additionally fails closed for a blocked citizenid
                        -- regardless of this stat's current value, so a
                        -- block takes effect immediately even before
                        -- fearStress has had time to decay back down.
                        if nearbyShots > 0 and IsWellbeingFeaturePermittedForCitizenId(citizenid, 'FearStressSystem') then
                            stats.fearStress = Clamp(stats.fearStress + Config.Wellbeing.FearStress.risePerNearbyShotPerTick * nearbyShots, 0, Config.Wellbeing.FearStress.max)
                        else
                            stats.fearStress = Clamp(stats.fearStress - Config.Wellbeing.FearStress.passiveDecayPerTick, 0, Config.Wellbeing.FearStress.max)
                        end

                        if stats.fearStress >= Config.Wellbeing.FearStress.hesitationThreshold then
                            if stats.hesitationEpisodeStartedAt == 0 then
                                stats.hesitationEpisodeStartedAt = now
                            end

                            -- SECURITY FIX (coder-security, config-audit
                            -- follow-up pass): see HESITATION_MAX_CONTINUOUS_MS's
                            -- own comment above the relayWeaponFire
                            -- AddEventHandler for the full writeup. This is
                            -- the enforcement half of that cap — the
                            -- accessor's own comment and this section's own
                            -- header above describe WHY it exists.
                            if (now - stats.hesitationEpisodeStartedAt) < HESITATION_MAX_CONTINUOUS_MS then
                                stats.hesitatingUntil = math.max(stats.hesitatingUntil, now + HESITATION_DURATION_MS)
                            else
                                -- Forced recovery: fearStress must climb back
                                -- past hesitationThreshold from zero before
                                -- hesitatingUntil can be extended again.
                                -- `hesitatingUntil` itself is left untouched
                                -- here — it already carries an absolute
                                -- timestamp from the last legitimate renewal
                                -- (at most hesitationDurationMs in the
                                -- future) and is allowed to elapse on its
                                -- own, exactly like a real, ordinary
                                -- hesitation window would.
                                stats.fearStress = 0
                                stats.hesitationEpisodeStartedAt = 0
                            end
                        elseif stats.hesitatingUntil <= now then
                            -- Only clear the episode's start timestamp once
                            -- hesitation has ACTUALLY lapsed (IsHesitating()
                            -- genuinely false, i.e. the last renewal's
                            -- absolute `hesitatingUntil` is in the past) —
                            -- NOT merely because this one tick's fearStress
                            -- sample dipped below threshold. `hesitatingUntil`
                            -- is a several-second-wide absolute timestamp,
                            -- not re-evaluated between ticks, so a fearStress
                            -- value that dips below threshold for a single
                            -- tick and climbs back above it on the next does
                            -- NOT give the K9 a real window to act — the
                            -- earlier renewal is still in effect the whole
                            -- time. Resetting the episode clock on that
                            -- dip alone would let a forger engineer exactly
                            -- that one-tick wobble once per
                            -- HESITATION_MAX_CONTINUOUS_MS to keep resetting
                            -- the cap while hesitatingUntil itself never
                            -- actually lapses — silently recreating the
                            -- indefinite lock this cap exists to close.
                            -- Keying the reset off `hesitatingUntil` instead
                            -- ties "episode over" to the same real-world
                            -- condition server/combat.lua's ValidateCombatRequest
                            -- itself checks (IsHesitating() returning false).
                            stats.hesitationEpisodeStartedAt = 0
                        end
                    end

                    TriggerClientEvent('qbx_k9unit:client:wellbeingUpdate', src, SnapshotOf(stats))
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
        if Config.Features.FatigueSystem or Config.Features.MoodSystem
            or Config.Features.FearStressSystem or Config.Features.DistractionSystem
            or Config.Features.InjuryLimping or Config.Features.HungerThirstSystem then
            local ok, err = pcall(TickWellbeing)
            if not ok then
                print(('[qbx_k9unit] wellbeing tick error: %s'):format(tostring(err)))
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

    if Config.Features.MoodSystem then
        WarnIfItemMissing(Config.Wellbeing.Mood.feedItemName, 'Config.Wellbeing.Mood.feedItemName', 'Config.Features.MoodSystem')
    end

    if Config.Features.DistractionSystem then
        WarnIfItemMissing(Config.Wellbeing.Distraction.meatBaitItemName, 'Config.Wellbeing.Distraction.meatBaitItemName', 'Config.Features.DistractionSystem')
        WarnIfItemMissing(Config.Wellbeing.Distraction.whistleItemName, 'Config.Wellbeing.Distraction.whistleItemName', 'Config.Features.DistractionSystem')
    end

    -- HUNGER/THIRST (this pass, coder-backend). CONFIG-DEFENSIVE, same
    -- reasoning as every other Config.Wellbeing.Hunger/.Thirst read in this
    -- file: guarded with `type(...) == 'table'` since this file does not
    -- own config.lua and these subtables may not exist yet.
    if Config.Features.HungerThirstSystem then
        local hungerCfg = type(Config.Wellbeing.Hunger) == 'table' and Config.Wellbeing.Hunger or {}
        local thirstCfg = type(Config.Wellbeing.Thirst) == 'table' and Config.Wellbeing.Thirst or {}
        WarnIfItemMissing(hungerCfg.feedItemName, 'Config.Wellbeing.Hunger.feedItemName', 'Config.Features.HungerThirstSystem')
        WarnIfItemMissing(thirstCfg.drinkItemName, 'Config.Wellbeing.Thirst.drinkItemName', 'Config.Features.HungerThirstSystem')
    end
end)
