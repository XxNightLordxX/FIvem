--[[
    qbx_k9unit/server/defense.lua

    Phase 3 implementation (coder-backend), PHASE3_SPEC.md §12.5.3
    (Handler-Down Defense) / §12.3's file-plan row for this exact file.
    Was blocked all session on `server/partnership.lua` (PHASE3_SPEC.md
    §12.0 item 7) not existing -- that blocker is gone as of commit 52a58a1
    (`server/partnership.lua`/`client/partnership.lua` landed) and commit
    94fbc4e (`server/certifications.lua` wired to tear partnerships down on
    cert revoke / department change). This file is a PURE CONSUMER of both
    `server/partnership.lua` (read-only accessors, never re-derives
    partnership state) and `server/combat.lua`'s existing
    `requestBiteHold`/`requestTakedown` event contract (never duplicates
    their validation) -- see FILE-TO-FILE CONTRACT below.

    ======================================================================
    §12.0 ITEM 2 -- THE ONE RULE EVERYTHING BELOW IS SUBORDINATE TO:
    HandlerDownDefense is a UI/auto-targeting CONVENIENCE, never an AI
    takeover. Nothing in this file ever moves a K9's own ped, fires a
    weapon, plays an animation, or applies any task/control to a K9
    player's own character -- its only effect is a `TriggerClientEvent`
    carrying a notification + an OPTIONAL pre-selected target netId, which
    the K9's OWN client (client/defense.lua) only ever uses to pre-fill a
    manually-confirmed `requestBiteHold`/`requestTakedown` call. This file
    does not, and must never, gate any server-authoritative consequence on
    that notification having been sent, received, or acted on.
    ======================================================================

    ======================================================================
    REALITY-CHECK: TWO PLACES THIS FEATURE'S SPEC PROSE DID NOT SURVIVE
    CONTACT WITH THE REAL, ALREADY-SHIPPED CODE (disclosed here rather than
    silently worked around, per this codebase's own established practice --
    compare server/combat.lua's own "NPC-TARGET NATIVE EXECUTION CONTEXT"
    section for the same kind of honest deviation writeup):

    1. "Reuses Phase 2's server/tracking.lua damage-event log" (PHASE3_SPEC.md
       §12.1's 3e row, §12.2's `hostileLookbackSeconds` comment) is WRONG
       about what that log actually contains. Read server/tracking.lua in
       full before writing this file: `relayDamageEvent` is payload-less BY
       DESIGN (that file's own header, quoting phase2_notes/
       scent_blood_tracking.md §3 item 2's explicit warning against ever
       adding a payload) -- it logs ONLY the victim's own coordinates, for
       blood-trail purposes, with NO attacker/source-of-damage field
       anywhere in `TrackableLog`. There is no "who damaged this player"
       data anywhere in this codebase to reuse. Server-side, there is also
       no substitute: `gameEventTriggered`/`CEventNetworkEntityDamage` is
       CLIENT-ONLY (confirmed, phase2_notes/scent_blood_natives.md's own
       "Client-side only... FiveM's server process does not run game-event
       simulation at all" finding, already relied on by server/tracking.lua
       itself) -- there is no server-side native or event that answers "who
       last hit this player" independent of a client relay.
       RESOLUTION: this file does NOT touch server/tracking.lua (off-limits,
       owned by another agent, and repurposing `relayDamageEvent`'s payload
       shape would violate that file's own explicit "do not add a
       coordinate/payload later" contract). Instead it owns a NEW,
       self-contained, low-trust hint channel
       (`qbx_k9unit:server:reportHandlerAttacker`, below) fed by a NEW
       client-side `gameEventTriggered` hook in client/defense.lua --
       structurally the same PATTERN tracking.lua's own relayDamageEvent
       uses (client observes a real local game event, relays the fact,
       server never trusts a coordinate/identity claim beyond what it
       independently re-verifies), just a second, independent instance of
       that pattern for a different payload (attacker identity, not
       location). See `LastHostile`/`reportHandlerAttacker` below.
    2. §12.5.3's "notify that K9's client... goes through the exact same
       requestBiteHold/requestTakedown server validation path" is correct
       about the SERVER side (this file never re-implements
       ValidateCombatRequest), but client/combat.lua's actual
       `RequestBiteHold()`/`RequestTakedown()` functions take ZERO
       arguments -- they always resolve their OWN "nearest ped in range"
       candidate locally (`FindNearestCombatTarget`) and have no parameter
       to accept a pre-selected target at all. There is no seam in the
       existing client-side wrapper functions for a pre-selection to flow
       through. This is a client/defense.lua concern (see that file's own
       header for how it's resolved -- it fires the underlying
       `qbx_k9unit:server:requestBiteHold`/`requestTakedown` EVENTS directly
       with the pre-selected netId, which still runs through THIS exact
       validation path server-side), documented here too since it is the
       other half of why this file can honestly call itself a "pure
       consumer" of server/combat.lua's contract at the PROTOCOL level
       (same event name, same payload shape, same ValidateCombatRequest)
       without ever importing or duplicating a single line of that file's
       logic.
    ======================================================================

    ======================================================================
    "IS THE HANDLER DOWN" -- SAME NATIVE-RELIABILITY PROBLEM AS
    PROPDRAGGING'S DOWNED-CHECK (PHASE3_SPEC.md §12.0 item 6), RESOLVED THE
    SAME WAY: a raw `Config.Combat.HandlerDownDefense.handlerHealthThreshold`
    comparison against `GetEntityHealth` has the identical false-positive/
    false-negative shape item 6 documents for PropDragging's target ("most
    QBCore/Qbox laststand implementations deliberately keep the player's ped
    alive... while a custom animation and EMS-job-gated input restriction run
    entirely in script" -- health alone would false-negative on exactly that
    common case; a player merely ragdolled/knocked down for an unrelated
    reason would false-positive on a naive health-only read too, if that
    server's laststand system also drops health hard). `IsHandlerDown` below
    REUSES `Config.Combat.PropDragging.IsPlayerDownedOverride` DIRECTLY --
    NO SEPARATE FIELD is requested for this file. Rationale for sharing
    rather than duplicating: the question an override answers
    ("is THIS player currently down per this server's own scripted
    laststand/EMS system") is identical for a drag target and for a
    handler -- it is the same fact about the same kind of entity, just
    consumed by a second feature. A server that wires the override once
    (pointing it at its real ambulance/laststand resource) gets correct
    behavior for BOTH PropDragging and HandlerDownDefense automatically,
    which is the entire point of a single per-server integration point
    (mirrors this codebase's own "one shared cooldown/mutex helper" and "one
    shared netId resolver" extraction precedents -- REFACTOR_ROADMAP.md
    items 1/2 -- applied here to a config surface instead of a function).
    If a future maintainer would rather this field live at a shared
    top-level `Config.Combat.IsPlayerDownedOverride` instead of nested under
    `PropDragging`, that is a clean, non-blocking rename this file's own
    single call site below would not need to change in shape, only in
    lookup path -- flagged as a coder-architect judgment call, not decided
    here. When no override is configured, the fallback below mirrors
    server/combat.lua's own `IsTargetDowned` default (a
    `metadata.isdead`/`.inlaststand` guess) OR'd with the literal
    `handlerHealthThreshold` the original spec sketch named -- see
    `IsHandlerDown`'s own comment for why OR (not the override-or-guess
    EITHER/OR shape `IsTargetDowned` uses) is the right combinator here: this
    is a best-effort convenience TRIGGER, not a hard authorization gate, so
    a false positive here costs nothing more than an unwanted notification
    (never a granted capability -- see item 2 restatement above), which
    makes being slightly more eager to fire an acceptable, disclosed
    trade-off that would NOT be acceptable for PropDragging's own gate.
    ======================================================================

    ======================================================================
    KNOWN HAZARD FROM client/partnership.lua's QA PASS, AND WHY IT DOES NOT
    APPLY HERE: that file's header discloses that a reconnecting/restarted
    client's OWN local `PartnershipState` cache can under-report ("no
    server-side callback lets a client learn its partnership state after a
    reconnect"). This file never reads that client-side cache, or trusts
    any client claim about who its partner is, at all -- every partnership
    fact this file uses comes from `GetActivePartnerCitizenId`
    (server/partnership.lua), which is populated SERVER-SIDE via
    `RefreshPartnershipCache`'s own `PlayerLoaded`/`onResourceStart`
    backfill (that file's own header) independent of anything any client
    ever reports. The hazard is real for a FUTURE client-side consumer of
    `IsPartnered()`/`GetPartnerServerId()` (client/partnership.lua's own
    globals) -- this file is not that consumer and does not touch those
    globals, so it is structurally unaffected rather than merely lucky.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:reportHandlerAttacker' (attackerNetId: number)
      Fired by client/defense.lua's own `gameEventTriggered` hook when the
      LOCAL player (a potential handler) is the `CEventNetworkEntityDamage`
      victim. This is a LOW-TRUST HINT ONLY -- see REALITY-CHECK item 1
      above -- never itself authorizing anything; stored purely as a
      candidate pre-selection for a LATER `handlerDownDefenseTrigger`
      notification, which is itself only ever a pre-fill for a manually
      confirmed action that re-derives everything from scratch server-side
      (guardrail from §12.0 item 2/item 8's own "no server-authoritative
      consequence conditioned on an unverified client signal" posture,
      applied here even though this isn't a Category B combat effect).
      Rate-limited per source; the reported entity is re-resolved (never
      trusted as-is) both at storage time here and again at read time in
      `TryNotifyPartnerK9` below.

    Client events (server->client), registered by client/defense.lua:
    - 'qbx_k9unit:client:handlerDownDefenseTrigger' (handlerNetId: number,
      suggestedTargetNetId: number?)
      Sent ONLY to the partnered K9's own client, ONLY after
      GetActivePartnerCitizenId has resolved a real, currently-online
      partner and the triggerRadius/retrigger-cooldown checks below have
      passed. `suggestedTargetNetId` is nil when no fresh, still-resolvable
      hostile hint exists -- the receiving client must treat this as "no
      pre-selection available," never as an error. No `expiresAt` field is
      sent (see client/combat.lua's own CLOCK-DOMAIN NOTE, which this file
      follows rather than repeats the mistake of comparing raw
      cross-process `GetGameTimer()` values) -- the receiving client derives
      its own local deadline from the shared `Config.Combat.
      HandlerDownDefense.promptTtlMs` constant instead.

    Automatic path: a single shared maintenance thread (mirrors
    server/combat.lua's own single-thread-over-a-shared-table discipline,
    applied here to "every connected player" instead of "every active
    hold") polls every connected player's live health every
    `Config.Combat.HandlerDownDefense.pollIntervalMs` via `IsHandlerDown`,
    and -- for every player currently reading as down, EVERY tick, not only
    on the first not-down -> down transition (see `TryNotifyPartnerK9`'s own
    RETRY-WHILE-DOWN doc comment for why an edge-only design was drafted
    and rejected) -- looks up that citizenid's active partnership, subject
    to its own cheapest-first anti-spam cooldown check.
    No native/event exists in this codebase's own verified surface for a
    server-side "health changed" push notification (the same "no native
    equivalent" conclusion server/combat.lua's own NonComplianceDetection
    sampling design already reached for position-based signals applies
    here to health) -- polling a cheap, non-yielding read
    (`GetEntityHealth`) over the connected-player set is the same
    pragmatic answer this codebase already ships elsewhere.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls `GetActivePartnerCitizenId(citizenid)` (server/partnership.lua)
      -- READ-ONLY, never re-derives `Partnerships` state, exactly as that
      file's own "FUTURE CONSUMERS" header section names this file's role.
      Guarded by `type(GetActivePartnerCitizenId) == 'function'` -- runtime
      existence guard, not a load-order assumption, this codebase's
      established convention (server/medkit.lua's RestoreInjury precedent)
      -- server/partnership.lua may be absent, or `HandlerPartnership` may
      be disabled on a given server (in which case the accessor, if
      defined at all, simply never has anything cached to return -- a
      silent no-op either way, per PHASE3_SPEC.md §12.0 item 7's own
      framing).
    - Calls `ResolveNetworkEntity(netId, expectedEntityType)`
      (server/entities.lua) for EVERY netId resolution below -- never a
      hand-rolled `NetworkGetEntityFromNetworkId`/`DoesEntityExist` pair.
    - Calls `NewCooldown()` (server/cooldowns.lua) for both rate limits
      below -- never a hand-rolled `lastTouchedAt` table.
    - Does NOT call `HasK9Access` -- HandlerDownDefense's trigger concerns
      the HANDLER/officer-role party of a partnership, who (per
      server/partnership.lua's own documented AUTHORIZATION MODEL) is
      gated on department membership only, never K9 certification. This
      file relies on server/certifications.lua's `ForceBreakPartnershipForCitizenId`
      wiring (commit 94fbc4e) to keep an active partnership consistent
      with the K9-role party's certification status -- it does not
      independently re-verify certification here.
    - Does NOT call anything in server/combat.lua -- this file only fires
      the exact same event NAMES that file's own client-side callers use
      (see REALITY-CHECK item 2 above); there is no Lua-level dependency in
      either direction, only a shared network-protocol contract.
    - Loaded in fxmanifest.lua's server_scripts after server/cooldowns.lua
      (NewCooldown at this file's own file-load time -- hard requirement)
      and server/entities.lua (ResolveNetworkEntity, called at runtime).
      Recommended (not load-order-required, since GetActivePartnerCitizenId
      is consumed behind a runtime existence guard) immediately after
      server/partnership.lua for readability, matching this manifest's own
      established "place a soft consumer near its producer" convention.
    ======================================================================

    Config surface REQUESTED (not yet landed as of this file -- see this
    pass's own report for the exact block): `Config.Combat.HandlerDownDefense`
    with `handlerHealthThreshold`/`triggerRadius`/`hostileLookbackSeconds`
    (PHASE3_SPEC.md §12.2's original sketch values, still unreviewed
    placeholders) plus four NEW fields this implementation needs
    (`pollIntervalMs`, `retriggerCooldownMs`, `promptTtlMs`,
    `attackerReportCooldownMs`) that PHASE3_SPEC.md's own sketch did not
    anticipate, since it did not work out the polling/hint-relay mechanics
    this file had to design to make the feature buildable at all.
    `Config.Features.HandlerDownDefense` stays `false` -- this file must
    never flip it.
]]

if not Config.Features.HandlerDownDefense then return end

-- Ephemeral, in-memory only -- mirrors server/main.lua's `LeashPairs` /
-- server/combat.lua's `ActiveHolds` precedent (live-session data, not
-- account data). LastHostile[handlerSrc] = { attackerNetId = number,
-- at = <GetGameTimer() ms> } -- single slot per potential-handler source,
-- most-recent-report-wins (a fresh report simply overwrites any earlier
-- one -- there is no reason to keep more than the latest hint, and no
-- reason to require it be "consumed" the way a one-shot ticket would,
-- since this is read-many, never mutated-on-read).
local LastHostile = {}

-- Per-source rate limit on the reportHandlerAttacker relay below -- same
-- "never leave a per-source ingest path fully unbounded" posture as
-- server/tracking.lua's DamageRelayCooldown, for the same reason (a client
-- can call TriggerServerEvent directly, bypassing any local debounce in
-- client/defense.lua's own gameEventTriggered hook).
local AttackerReportCooldown = NewCooldown(Config.Combat.HandlerDownDefense.attackerReportCooldownMs)
AttackerReportCooldown.RegisterPlayerDropped()

-- Per-handler rate limit on actually SENDING a handlerDownDefenseTrigger
-- notification -- distinct from AttackerReportCooldown above (that one
-- throttles hint INGESTION; this one throttles the eventual K9-facing
-- NOTIFICATION), so a handler whose health oscillates around
-- handlerHealthThreshold (repeated damage/regen ticks, or a laststand
-- system that briefly toggles the override's result) does not spam their
-- partner K9 with repeated prompts for what is, from the K9's perspective,
-- the same ongoing incident.
local DefenseTriggerCooldown = NewCooldown(Config.Combat.HandlerDownDefense.retriggerCooldownMs)
DefenseTriggerCooldown.RegisterPlayerDropped()

--- Combined "is this specific connected player currently down" signal --
--- see this file's header for the full reasoning on reusing
--- `Config.Combat.PropDragging.IsPlayerDownedOverride` rather than adding a
--- dedicated field, and on why OR (not override-or-nothing) is the right
--- shape for a convenience trigger's fallback.
--- FAILS CLOSED (returns false) on an override error -- an errored override
--- must never itself manufacture a defense-mode trigger; this mirrors the
--- FAIL-CLOSED DIRECTION server/combat.lua's IsPlayerWantedEligible/
--- IsTargetDowned already use, applied here even though the STAKES differ
--- (this file's false-closed case merely skips a helpful notification,
--- never denies or grants a real capability).
--- @param handlerSrc number
--- @param handlerPed number
--- @return boolean
local function IsHandlerDown(handlerSrc, handlerPed)
    local override = Config.Combat.PropDragging.IsPlayerDownedOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, handlerSrc)
        if not ok then
            print(('[qbx_k9unit] defense.lua: Config.Combat.PropDragging.IsPlayerDownedOverride errored for source %s: %s -- treating as NOT down this tick'):format(handlerSrc, tostring(result)))
            return false
        end
        return result == true
    end

    -- No override configured: best-effort metadata guess (same
    -- metadata.isdead/.inlaststand convention as server/combat.lua's own
    -- IsTargetDowned default) OR'd with the literal handlerHealthThreshold
    -- PHASE3_SPEC.md §12.2's original sketch named -- either signal alone
    -- can miss a real "handler needs help" moment on a server with neither
    -- convention wired the way the other expects; combining them costs
    -- nothing given this is a non-authoritative trigger (see header).
    local player = exports.qbx_core:GetPlayer(handlerSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) == 'table' and (metadata.isdead == true or metadata.inlaststand == true) then
        return true
    end

    return GetEntityHealth(handlerPed) <= Config.Combat.HandlerDownDefense.handlerHealthThreshold
end

--- Resolves `handlerSrc`'s active partnership (if any), checks the
--- partner K9 is online and within triggerRadius, resolves a fresh
--- pre-selected hostile if one is on record, and -- if every check
--- passes -- sends the notification. Silent no-op at every step per
--- PHASE3_SPEC.md §12.0 item 7's own "never partnered, or partnership
--- broken: silent no-op" framing, extended here to every OTHER reason this
--- convenience feature might not apply right now (K9 offline, K9 too far,
--- already notified recently).
---
--- RETRY-WHILE-DOWN, NOT EDGE-TRIGGERED-ONCE -- a deliberate correction
--- made while writing this file, not the original design: the maintenance
--- thread below calls this EVERY poll tick the handler reads as down, not
--- only on the first not-down -> down transition. An edge-only design was
--- drafted first and rejected: if the partner K9 happened to be outside
--- `triggerRadius` (or briefly offline, or the partnership lookup raced
--- something) at the EXACT tick health first crossed the threshold, an
--- edge-only trigger would miss the whole "down" episode permanently --
--- nothing re-fires until health rises back above the threshold and drops
--- again, which may never happen for that specific incident. Anti-spam for
--- the (now-common) repeated-call case is handled below by consuming
--- DefenseTriggerCooldown ONLY once every other check has already passed
--- and this function is about to actually send the notification -- a
--- "still out of range" or "still no active partnership" tick is
--- deliberately NOT rate-limited, since those are already naturally
--- infrequent state changes, not a spam source, and gating them on the same
--- cooldown as a successful send would reintroduce this exact missed-window
--- bug for the "K9 was out of range for the first `retriggerCooldownMs`
--- after crossing, then walked into range" case.
--- @param handlerSrc number
--- @param handlerPed number
local function TryNotifyPartnerK9(handlerSrc, handlerPed)
    -- Cheapest-first, check-only (never stamps) -- if a notification was
    -- already sent for this handler within retriggerCooldownMs, skip every
    -- other lookup below entirely. Stamped (via .Consume() below) only once
    -- every other check has ALSO passed -- see this function's own
    -- RETRY-WHILE-DOWN doc comment above for why an early .Consume() here
    -- would reintroduce the exact missed-window bug that comment describes.
    if DefenseTriggerCooldown.IsOnCooldown(handlerSrc) then return end

    -- Runtime existence guard, not a load-order assumption -- see this
    -- file's own FILE-TO-FILE CONTRACT above.
    if type(GetActivePartnerCitizenId) ~= 'function' then return end

    local handlerPlayer = exports.qbx_core:GetPlayer(handlerSrc)
    local handlerCitizenid = handlerPlayer and handlerPlayer.PlayerData and handlerPlayer.PlayerData.citizenid
    if not handlerCitizenid then return end

    local partnerCitizenid, partnerIsK9 = GetActivePartnerCitizenId(handlerCitizenid)
    -- Silent no-op: never partnered / partnership broken (PHASE3_SPEC.md
    -- §12.0 item 7), OR the citizenid whose health crossed the threshold
    -- is itself the K9-role party, not the handler-role party --
    -- HandlerDownDefense is specifically "a certified handler's health
    -- crossing the threshold" (§12.5.3); a K9 going down defends nobody
    -- and is out of this feature's scope entirely.
    if not partnerCitizenid or partnerIsK9 == true then return end

    -- server/partnership.lua's own "FUTURE CONSUMERS" instruction: "the
    -- caller is still responsible for separately checking the resolved K9
    -- citizenid is CURRENTLY ONLINE... before notifying." Same
    -- exports.qbx_core:GetPlayerByCitizenId confidence note already
    -- disclosed in server/certifications.lua/server/partnership.lua --
    -- not re-derived, reused with the same caveat.
    local k9Player = exports.qbx_core:GetPlayerByCitizenId(partnerCitizenid)
    local k9Src = k9Player and k9Player.PlayerData and k9Player.PlayerData.source
    if not k9Src then return end

    local k9Ped = GetPlayerPed(k9Src)
    if k9Ped == 0 then return end

    local dist = #(GetEntityCoords(handlerPed) - GetEntityCoords(k9Ped))
    if dist > Config.Combat.HandlerDownDefense.triggerRadius then return end

    -- Resolve a fresh pre-selected hostile, if any -- NEVER trust the
    -- stored netId is still valid; re-resolve now regardless of whether it
    -- resolved when it was first reported (see reportHandlerAttacker
    -- below). nil (no pre-selection) is an entirely normal, expected
    -- outcome, not an error -- the notification still fires either way,
    -- per §12.0 item 2's "presenting a prompt AND/OR pre-selecting a
    -- target" wording (the prompt alone is a complete, valid outcome).
    local suggestedTargetNetId = nil
    local hostile = LastHostile[handlerSrc]
    if hostile and (GetGameTimer() - hostile.at) <= (Config.Combat.HandlerDownDefense.hostileLookbackSeconds * 1000) then
        if ResolveNetworkEntity(hostile.attackerNetId, 1) then
            suggestedTargetNetId = hostile.attackerNetId
        end
    end

    -- Every real precondition has now passed -- stamp the anti-spam
    -- cooldown ONLY here, immediately before the send, per this function's
    -- own RETRY-WHILE-DOWN doc comment above.
    DefenseTriggerCooldown.Touch(handlerSrc)

    local handlerNetId = NetworkGetNetworkIdFromEntity(handlerPed)
    TriggerClientEvent('qbx_k9unit:client:handlerDownDefenseTrigger', k9Src, handlerNetId, suggestedTargetNetId)
end

-- Single shared maintenance thread -- see this file's header for why this
-- is a poll (no server-side "health changed" push exists in this
-- codebase's own verified native/event surface) and why it mirrors
-- server/combat.lua's own single-thread-over-a-shared-set discipline
-- rather than one thread per connected player.
CreateThread(function()
    while true do
        Wait(Config.Combat.HandlerDownDefense.pollIntervalMs)

        for _, playerIdStr in ipairs(GetPlayers()) do
            local src = tonumber(playerIdStr)
            if src then
                local ped = GetPlayerPed(src)
                -- ped == 0 is a defensive no-op (src reported by GetPlayers()
                -- but no live ped resolves yet, e.g. mid-connect) -- nothing
                -- to sample this tick.
                if ped ~= 0 and IsHandlerDown(src, ped) then
                    -- Called every tick this handler reads as down -- see
                    -- TryNotifyPartnerK9's own RETRY-WHILE-DOWN doc comment
                    -- for why this is deliberately NOT edge-triggered-once,
                    -- and for how that function's own cheapest-first
                    -- DefenseTriggerCooldown.IsOnCooldown check keeps this
                    -- cheap in the common "already notified recently" case.
                    -- pcall-wrapped -- an uncaught error here must never kill
                    -- this shared thread (mirrors server/combat.lua's own
                    -- maintenance-thread pcall discipline around
                    -- EndHold/SampleCompliance for the identical reason: a
                    -- dead thread silently disables this feature for every
                    -- player for the rest of this resource's uptime, not
                    -- just the one player that errored).
                    local ok, err = pcall(TryNotifyPartnerK9, src, ped)
                    if not ok then
                        print(('[qbx_k9unit] defense.lua TryNotifyPartnerK9 errored for source %s: %s'):format(src, tostring(err)))
                    end
                end
            end
        end
    end
end)

--- Low-trust hint ingestion -- see this file's header REALITY-CHECK item 1
--- for why this exists as its own event rather than reusing/extending
--- server/tracking.lua's relayDamageEvent. Never itself authorizing
--- anything: a forged/wrong report can, at worst, cause a later
--- handlerDownDefenseTrigger notification to pre-select an incorrect
--- target, which the K9 player still has to manually confirm and which
--- still goes through requestBiteHold/requestTakedown's own full
--- server-side re-validation (proximity, RequireWantedStatus for a player
--- target, cooldowns, already_held/already_engaged) regardless -- carries
--- no more capability than the K9 manually radial-selecting the same
--- (possibly wrong) target already would today.
--- @param attackerNetId any
RegisterNetEvent('qbx_k9unit:server:reportHandlerAttacker', function(attackerNetId)
    local src = source

    if type(attackerNetId) ~= 'number' then return end

    if not AttackerReportCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches server/tracking.lua's own relayDamageEvent/relayWeaponFire convention)
    end

    -- Never store a hint that doesn't currently resolve to a real ped --
    -- re-resolved AGAIN at read time in TryNotifyPartnerK9 above (an
    -- entity that resolves now can still go stale, disconnect, or despawn
    -- by the time a handler's health actually crosses the threshold).
    local attackerPed = ResolveNetworkEntity(attackerNetId, 1)
    if not attackerPed then return end

    local reporterPed = GetPlayerPed(src)
    if reporterPed ~= 0 and attackerPed == reporterPed then
        return -- defensive: never record the reporter as their own attacker (e.g. self-inflicted/environmental damage where the game event's attacker field degenerates to the victim itself, per phase2_notes/scent_blood_natives.md's own documented args[2] caveat)
    end

    LastHostile[src] = { attackerNetId = attackerNetId, at = GetGameTimer() }
end)

-- Cleans up this file's per-source ephemeral state on disconnect --
-- AttackerReportCooldown/DefenseTriggerCooldown already registered their
-- OWN playerDropped handlers via :RegisterPlayerDropped() above; this
-- covers the one plain table this file owns directly (LastHostile has no
-- per-connection hook of its own -- it is not one of server/cooldowns.lua's
-- three tracker shapes, same "plain table, manual handler" reasoning as
-- server/tracking.lua's PendingTrackArrival).
AddEventHandler('playerDropped', function()
    local src = source
    LastHostile[src] = nil
end)
