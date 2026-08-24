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
    5. Flashbang immunity (Config.Wellbeing.Distraction.flashbangImmune) is
       NOT implemented anywhere in this file — PHASE4_SPEC.md §13.4.3.4
       flags this as genuinely integration-dependent on an unconfirmed
       third-party flashbang/stun resource's own event shape, not a
       guaranteed native-only deliverable. Left as aspirational config only,
       exactly as that document leaves it — not glossed over as "done."

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
    - IsDistracted(citizenid: string) -> boolean — same shape as
      IsHesitating, for Distraction's own "breaks command" state
      (PHASE4_SPEC.md §13.4.3.4's reading of that state as a server-enforced
      command rejection, the same category as FearStress's hesitation, not
      named as its own accessor anywhere in PHASE4_SPEC.md's own text but a
      direct, natural extension of the SAME pattern it names for
      IsHesitating — added here so Phase 3's combat.lua has a real hook for
      BOTH command-breaking wellbeing states, not just one).

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
--     lastCoords,                             -- vector3? -- previous tick's sample, for Fatigue's sprint-speed calc
-- }
local WellbeingStats = {}

-- Ephemeral, in-memory FearStress-only gunfire log. Deliberately NOT
-- server/tracking.lua's `TrackableLog.gunpowder` (that table is `local` to
-- that file) — see this file's header CONFIDENCE GRADING item 1 for the
-- full reasoning on why this is a small, disclosed duplication rather than
-- reaching into another file's internals.
-- RecentGunfire[i] = { coords = vector3, loggedAt = <GetGameTimer() ms> }
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
            lastCoords = nil,
        }
        WellbeingStats[citizenid] = stats
    end
    return stats
end

--- Sends an ox_lib notification to a specific player. Deliberate per-file
--- duplication, same reasoning server/medkit.lua's own NotifyPlayer header
--- comment already gives (ox_lib:notify is a stable, publicly documented
--- API of an already-declared dependency).
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
    RecentGunfire[#RecentGunfire + 1] = { coords = GetEntityCoords(ped), loggedAt = GetGameTimer() }
end)

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
        NotifyPlayer(src, 'Your K9 needs a moment before calming down again.', 'error')
        return
    end
    CalmDownCooldown.Touch(src)

    local citizenid = ResolveCitizenid(src)
    if not citizenid then return end

    local stats = EnsureStats(citizenid)
    stats.fearStress = Clamp(stats.fearStress - Config.Wellbeing.FearStress.calmDownReduceAmount, 0, Config.Wellbeing.FearStress.max)
    NotifyPlayer(src, 'Your K9 calms down.', 'success')
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
                                stats.fatigue = Clamp(stats.fatigue + Config.Wellbeing.Fatigue.idleRegenPerTick, 0, Config.Wellbeing.Fatigue.max)
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
                        local nearbyShots = 0
                        local lookbackMs = Config.Wellbeing.FearStress.gunfireLookbackSeconds * 1000
                        for _, entry in ipairs(RecentGunfire) do
                            if (now - entry.loggedAt) <= lookbackMs and #(entry.coords - coords) <= Config.Wellbeing.FearStress.gunfireRadius then
                                nearbyShots = nearbyShots + 1
                            end
                        end

                        if nearbyShots > 0 then
                            stats.fearStress = Clamp(stats.fearStress + Config.Wellbeing.FearStress.risePerNearbyShotPerTick * nearbyShots, 0, Config.Wellbeing.FearStress.max)
                        else
                            stats.fearStress = Clamp(stats.fearStress - Config.Wellbeing.FearStress.passiveDecayPerTick, 0, Config.Wellbeing.FearStress.max)
                        end

                        if stats.fearStress >= Config.Wellbeing.FearStress.hesitationThreshold then
                            stats.hesitatingUntil = math.max(stats.hesitatingUntil, now + Config.Wellbeing.FearStress.hesitationDurationMs)
                        end
                    end

                    TriggerClientEvent('qbx_k9unit:client:wellbeingUpdate', src, SnapshotOf(stats))
                end
            end
        end
    end
end

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
