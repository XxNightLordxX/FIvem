--[[
    qbx_k9unit/server/wellbeing.lua

    Phase 4 implementation. Owns Config.Features.FatigueSystem / MoodSystem /
    FearStressSystem / DistractionSystem / InjuryLimping (PHASE4_SPEC.md
    §13.0 Decision 1, §13.2, §13.4.3) — ONE shared per-citizenid stat store,
    ONE shared Config.Wellbeing.tickIntervalMs decay/regen tick, each of the
    five Config.Features flags independently gating only its OWN stat's tick
    logic / gameplay-facing effects, exactly mirroring server/tracking.lua's
    existing Scent/Blood/Gunpowder precedent (three independently-toggleable
    flags, one shared file pair, one shared prune loop) rather than five
    near-duplicate files.

    "READ AT THE POINT OF ACTIVATION" DISCIPLINE (SPEC.md §3): every branch
    below is gated on its OWN Config.Features flag, not just declared —
    disabling e.g. FatigueSystem while MoodSystem stays on means fatigue is
    never ticked, never read, and never pushed to a meaningful value; it
    simply idles at its default. This file starts NO thread at all if all
    five flags are false (see the CreateThread guard near the bottom).

    ======================================================================
    CONFIDENCE GRADING — read before extending this file:

    1. Event relay reuse (Mood/Injury damage decay, FearStress gunfire rise)
       — HIGH confidence on the EVENT NAMES/TRIGGER SEMANTICS themselves:
       server/tracking.lua's own header (read directly this session, not
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
       out of this pass's scope). This is a deliberate, disclosed design
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
       independently verified working end-to-end this session (no live
       server available to test against).
    2. Fatigue's "sprinting" detection (a server-side rolling
       position-sample: distance travelled between ticks / tickIntervalMs)
       is THIS FILE'S OWN implementation of the general technique
       PHASE3_SPEC.md §12.5.2 is understood to describe for
       NonLethalTakedown's speed gate — that document was NOT re-read this
       pass (out of this session's file-scope boundary; another agent owns
       Phase 3 combat). MEDIUM confidence: the technique is sound and
       self-contained, but its exact shape may not match Phase 3's real
       implementation once that lands — flagged for reconciliation then,
       not assumed identical now.
    3. `SetPedMoveRateOverride` itself is not called from this file at all
       (that's client/movement.lua's `RecomputeK9MoveRate()`, PHASE4_SPEC.md
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
       reads only static config plus its own string argument). PHASE4_SPEC.md
       §13.4.3.4's reality check still stands UNCHANGED for the other half:
       nothing in this codebase, and no confirmed third-party flashbang/stun
       resource's event name/payload shape, exists for this file to listen
       for and suppress — inventing one here would be exactly the kind of
       guess SPEC.md §11.6 already refused for the door-lock nudge-open
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
       using PHASE4_SPEC.md §13.4.3.1 open question 1's own "a world-object
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
       MEDIUM-HIGH, not independently verified in-engine this pass —
       `GetAllObjects`/`GetAllVehicles`/`GetEntityModel`/`GetEntityCoords`
       are documented, widely-used, cross-side (client AND server) CFX
       natives per common ecosystem knowledge (the same category of
       confidence this codebase's own convention, e.g. client/hud.lua's
       stamina-native note, treats as "plausible, flag for a
       native-api-assistant pass" rather than "settled"), not re-confirmed
       against a live server this session. Loop in native-api-assistant
       before enabling FatigueSystem with a non-empty restSources on a live
       server.

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
       the USING player (open question, PHASE4_SPEC.md §13.4.3.4 item 2,
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

    Client events (RegisterNetEvent, server->client):
    8. 'qbx_k9unit:client:wellbeingUpdate' (stats: table) [server->client,
       requester only, client/wellbeing.lua] — one combined push per tick
       carrying all five wellbeing values together (mirrors
       phase2_notes/phase4_hud_bridge_design.md's own "one combined message
       beats a split one" reasoning, PHASE4_SPEC.md §13.4.3.1).

    Resource-globals (no `local` — other files call these directly):
    - RestoreInjury(citizenid: string, amount: number) — the accessor
      server/medkit.lua ALREADY CALLS via a `type(RestoreInjury) == 'function'`
      guard (PHASE4_SPEC.md §13.4.3.5/§13.4.4). Signature matches that
      call site exactly: `RestoreInjury(targetCitizenid, Config.K9Medkit.injuryRestore)`.
      No-op if Config.Features.InjuryLimping is false (never gates/mutates
      anything the feature flag hasn't activated, per this file's own
      "read at the point of activation" discipline above) or if the
      arguments are the wrong type. Clamped to Config.Wellbeing.Injury.max,
      never allowed to move the value downward.
    - IsHesitating(citizenid: string) -> boolean — true while a FearStress-
      driven hesitation window (Config.Wellbeing.FearStress.hesitationDurationMs)
      is active. THE genuine new cross-file dependency PHASE4_SPEC.md §13.5
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
      accessor (PHASE4_SPEC.md §13.5 still requires it) — just an accurate,
      current statement of what calling it exposes you to, kept up to date
      here specifically because the LAST version of this note went stale
      the moment a second file started consuming it without this note being
      re-checked. Whoever next changes either this accessor's contract or
      its call site in server/combat.lua should update BOTH this note and
      that file's own comment together, not just one.
    - IsDistracted(citizenid: string) -> boolean — same shape as
      IsHesitating, for Distraction's own "breaks command" state
      (PHASE4_SPEC.md §13.4.3.4's reading of that state as a server-enforced
      command rejection, the same category as FearStress's hesitation, not
      named as its own accessor anywhere in PHASE4_SPEC.md's own text but a
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
    - Does NOT call `HasK9Access` — wellbeing tracks the K9 CHARACTER's own
      body state, gated on CURRENT ped model, not on job/certification
      (mirrors how AgilityBasicJump/AgilityAdvanced in client/movement.lua
      gate on IsOwnModelK9, not HasK9Access).
    - Uses server/cooldowns.lua's NewCooldown/NewNestedCooldown constructors
      exclusively (REFACTOR_ROADMAP.md item 1's established convention) —
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
]]

-- WellbeingStats[citizenid] = {
--     fatigue, mood, fearStress, injury,     -- 0..Config.Wellbeing.<Stat>.max
--     distractedUntil, hesitatingUntil,       -- GetGameTimer() ms timestamps, 0 = inactive
--     hesitationEpisodeStartedAt,             -- GetGameTimer() ms, 0 = not currently in a
--                                              -- continuous at/above-threshold episode -- see
--                                              -- HESITATION_MAX_CONTINUOUS_MS below (coder-security,
--                                              -- this pass) for why this exists.
--     lastCoords,                             -- vector3? -- previous tick's sample, for Fatigue's sprint-speed calc
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

--- @param value number
--- @param min number
--- @param max number
--- @return number
local function Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
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
        }
        WellbeingStats[citizenid] = stats
    end
    return stats
end

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by REFACTOR_ROADMAP.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

--- @param stats table
--- @return table snapshot -- a plain copy safe to hand to TriggerClientEvent/lib.callback
local function SnapshotOf(stats)
    return {
        fatigue = stats.fatigue,
        mood = stats.mood,
        fearStress = stats.fearStress,
        injury = stats.injury,
        distractedUntil = stats.distractedUntil,
        hesitatingUntil = stats.hesitatingUntil,
    }
end

--- @param source number
--- @return string? citizenid
local function ResolveCitizenid(source)
    local Player = exports.qbx_core:GetPlayer(source)
    return Player and Player.PlayerData and Player.PlayerData.citizenid or nil
end

--- @param source number
--- @return number ped, boolean isK9 -- ped is 0 if the source isn't a currently-connected player
local function ResolveK9Ped(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then return 0, false end
    return ped, IsConfiguredK9Model(GetEntityModel(ped))
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
    if Config.Features.MoodSystem then
        stats.mood = Clamp(stats.mood - Config.Wellbeing.Mood.damageDecayAmount, 0, Config.Wellbeing.Mood.max)
    end
    if Config.Features.InjuryLimping then
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
-- stressed, PHASE4_SPEC.md §13.4.3.3), but it means ANY connected player,
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
    -- reacts to ANY nearby gunfire (PHASE4_SPEC.md §13.4.3.3's own
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
local HESITATION_MAX_CONTINUOUS_MS = Config.Wellbeing.FearStress.hesitationDurationMs * 8

-- ======================================================================
-- MOOD — "Pet K9" / "Feed K9" ox_target interactions (client/wellbeing.lua).
-- ======================================================================

-- Live-proximity radius for both interactions below. NOT in
-- PHASE4_SPEC.md §13.2's sketch (that document names ox_target interactions
-- but no explicit interact-range value for them) — a small, disclosed
-- addition needed to satisfy the spec's own "server-enforced live proximity,
-- never a client-claimed distance" mandate (§13.4.3.2's server-authority
-- point). Same order of magnitude as Config.K9Inventory.interactRange/
-- Config.K9Medkit.range.
local MOOD_INTERACT_RANGE = 3.0

local PetCooldown = NewNestedCooldown()
PetCooldown.RegisterPlayerDropped()

--- PHASE4_SPEC.md §13.4.3.2. Server-authoritative "Pet K9" interaction.
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

    if PetCooldown.IsOnCooldown(source, targetCitizenid, Config.Wellbeing.Mood.petCooldownMs) then
        return { ok = false, reason = 'on_cooldown' }
    end
    PetCooldown.Touch(source, targetCitizenid)

    local stats = EnsureStats(targetCitizenid)
    stats.mood = Clamp(stats.mood + Config.Wellbeing.Mood.petRegenAmount, 0, Config.Wellbeing.Mood.max)

    return { ok = true }
end)

-- Deliberately reuses petCooldownMs's threshold value for the same
-- (interactor, target) pair shape rather than introducing a dedicated
-- config field — feeding and petting are the same class of "affection"
-- interaction PHASE4_SPEC.md §13.4.3.2 groups together, and this stops a
-- player alternating pet/feed calls to bypass a single shared cooldown.
local FeedCooldown = NewNestedCooldown()
FeedCooldown.RegisterPlayerDropped()

--- PHASE4_SPEC.md §13.4.3.2. Server-authoritative "Feed K9" interaction.
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

    if FeedCooldown.IsOnCooldown(source, targetCitizenid, Config.Wellbeing.Mood.petCooldownMs) then
        return { ok = false, reason = 'on_cooldown' }
    end

    local carriedCount = exports.ox_inventory:GetItemCount(source, Config.Wellbeing.Mood.feedItemName)
    if not carriedCount or carriedCount < 1 then
        return { ok = false, reason = 'no_item' }
    end

    FeedCooldown.Touch(source, targetCitizenid)

    local removed = exports.ox_inventory:RemoveItem(source, Config.Wellbeing.Mood.feedItemName, 1)
    if not removed then
        return { ok = false, reason = 'no_item' }
    end

    local stats = EnsureStats(targetCitizenid)
    stats.mood = Clamp(stats.mood + Config.Wellbeing.Mood.feedRegenAmount, 0, Config.Wellbeing.Mood.max)

    return { ok = true }
end)

-- ======================================================================
-- FEARSTRESS — "Calm Down" self-only action. PHASE4_SPEC.md §13.4.3.3 open
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
-- PHASE4_SPEC.md §13.4.3.4. Deliberately open to ANY player, not gated on
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

--- PHASE4_SPEC.md §13.4.3.4. Server-authoritative distraction-item use.
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

    local carriedCount = exports.ox_inventory:GetItemCount(source, itemName)
    if not carriedCount or carriedCount < 1 then
        return { ok = false, reason = 'no_item' }
    end

    local removed = exports.ox_inventory:RemoveItem(source, itemName, 1)
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
                    if targetCitizenid and not DistractionCooldown.IsOnCooldown(targetCitizenid, D.perTargetCooldownMs, now) then
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

    local stats = WellbeingStats[citizenid]
    return stats ~= nil and stats.hesitatingUntil > GetGameTimer()
end

--- @param citizenid string
--- @return boolean
function IsDistracted(citizenid)
    if not Config.Features.DistractionSystem then return false end
    if type(citizenid) ~= 'string' then return false end

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
        or Config.Features.InjuryLimping) then
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
-- entries) treated as a "rest point" — PHASE4_SPEC.md §13.4.3.1 open
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
-- SHARED TICK LOOP — PHASE4_SPEC.md §13.0 Decision 1. ONE loop for all
-- five stats, one pass over currently-connected players per tick. Started
-- ONLY if at least one of the five flags is enabled — a fully-disabled
-- subsystem runs no thread at all, per this file's own "no code needed
-- when disabled" default posture (mirrors client/movement.lua's
-- AgilityBasicJump == true default branch).
-- ======================================================================
local function TickWellbeing()
    local now = GetGameTimer()
    local dtSeconds = Config.Wellbeing.tickIntervalMs / 1000

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
                            if speed >= Config.Wellbeing.Fatigue.sprintSpeedThreshold then
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

                    if Config.Features.InjuryLimping then
                        stats.injury = Clamp(stats.injury + Config.Wellbeing.Injury.passiveRegenPerTick, 0, Config.Wellbeing.Injury.max)
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

                        if nearbyShots > 0 then
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
                                stats.hesitatingUntil = math.max(stats.hesitatingUntil, now + Config.Wellbeing.FearStress.hesitationDurationMs)
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
                -- sprintDecayPerTick hit. Only touches `lastCoords` — never
                -- the rest of `stats` (fatigue/mood/fearStress/injury
                -- deliberately persist across a model switch or
                -- disconnect/reconnect within the same server session, per
                -- this file's own header). Reads `WellbeingStats` directly
                -- rather than `EnsureStats` so this never creates a fresh
                -- entry for a citizenid that has never actually been
                -- K9-modeled this session.
                local citizenid = ResolveCitizenid(src)
                local stats = citizenid and WellbeingStats[citizenid]
                if stats then
                    stats.lastCoords = nil
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
--- server session") — only `lastCoords` is nulled, mirroring the reset
--- above exactly. `exports.qbx_core:GetPlayer(source)` is still resolvable
--- here — `playerDropped` fires before the framework fully tears down the
--- player object, same timing server/progression.lua's own `K9XP` eviction
--- handler and server/certifications.lua's own playerDropped handler
--- already rely on.
AddEventHandler('playerDropped', function(_reason)
    local citizenid = ResolveCitizenid(source)
    local stats = citizenid and WellbeingStats[citizenid]
    if stats then
        stats.lastCoords = nil
    end
end)

if Config.Features.FatigueSystem or Config.Features.MoodSystem
    or Config.Features.FearStressSystem or Config.Features.DistractionSystem
    or Config.Features.InjuryLimping then
    CreateThread(function()
        while true do
            Wait(Config.Wellbeing.tickIntervalMs)
            local ok, err = pcall(TickWellbeing)
            if not ok then
                print(('[qbx_k9unit] wellbeing tick error: %s'):format(tostring(err)))
            end
        end
    end)
end
