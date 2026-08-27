--[[
    qbx_k9unit/client/defense.lua

    Phase 3 implementation, DEVELOPER_REFERENCE.md §12.5.3
    (Handler-Down Defense) / §12.3's file-plan row for this exact file
    ("HandlerDownDefense's client-side presentation ONLY -- per §12.0 item 2's
    reading, this never applies any state to or takes control of the K9
    player's own ped"). Read server/defense.lua's own header in full before
    this file -- that file's REALITY-CHECK section documents two places
    DEVELOPER_REFERENCE.md's prose did not survive contact with the real,
    already-shipped code; this file is the client-side half of both fixes.

    ======================================================================
    §12.0 ITEM 2 ACCEPTANCE CRITERIA, made concrete for every line below:
    - The `handlerDownDefenseTrigger` handler NEVER calls a task/control/
      movement/animation native on this client's own ped. Its only effects
      are `lib.notify` (informational) and writing to the local
      `PendingDefensePrompt` table (a plain Lua value, not a game-state
      mutation).
    - `ConfirmHandlerDownDefense` below is the "manual confirmation" step --
      nothing in this file ever fires a bite/takedown request without an
      explicit call to it (a keypress or a future radial selection), and
      that call still runs through an access check first (permission audit
      follow-up, this pass: `HasK9Access()` alone, NOT the broader
      `CanShowK9UI()` this used to call -- see that function's own doc
      comment below for the full reasoning), matching the gate
      server/combat.lua's shared ValidateCombatRequest actually enforces on
      the requestBiteHold/requestTakedown events this file fires directly.
    - The K9 player's own movement/camera are never touched -- this file
      contains zero calls to SetEntityCoords/SetEntityHeading/
      SetFollowPedCamViewMode/TaskPlayAnim/DisableControlAction/etc.
    ======================================================================

    ======================================================================
    "PURE CONSUMER" OF client/combat.lua's ACTION PATHS -- WHY THIS FILE
    DOES NOT CALL RequestBiteHold()/RequestTakedown() DIRECTLY (read
    together with server/defense.lua's own REALITY-CHECK item 2, which
    documents the same finding from the server side):
    client/combat.lua's `RequestBiteHold()`/`RequestTakedown()` (read in
    full before writing this file) take ZERO parameters -- both always
    resolve their own "nearest ped within range" candidate locally via
    `FindNearestCombatTarget`, with no seam to inject a pre-selected target.
    Rather than duplicate `FindNearestCombatTarget`'s own local-scan logic
    here (which would silently IGNORE the whole point of this feature -- the
    pre-selected hostile from the server's own hint), or reach into
    client/combat.lua to add a parameter it doesn't currently have, this
    file fires the exact same underlying server EVENT
    (`qbx_k9unit:server:requestBiteHold`/`requestTakedown`) those two
    functions themselves fire, with the identical payload shape (a single
    `targetNetId: number`). server/combat.lua's `ValidateCombatRequest` runs
    byte-for-byte identically regardless of which client-side code path
    produced the request -- DEVELOPER_REFERENCE.md §12.0 item 2's "goes through the
    exact same requestBiteHold/requestTakedown server validation path"
    criterion is satisfied at the protocol level, which is the level that
    actually carries server authority; only the LOCAL convenience wrapper
    differs from a manually-radial-triggered attempt.
    NON-BLOCKING RECOMMENDATION: an optional `targetNetId` parameter on
    `RequestBiteHold`/`RequestTakedown` (falling back to
    `FindNearestCombatTarget` when nil) would let a future caller reuse
    those wrappers directly instead of re-deriving the CanShowK9UI() gate
    and event name here -- not required; this file's own gate below is a
    byte-for-byte copy of that check for exactly this reason, not an
    independent reinvention.
    ======================================================================

    ======================================================================
    ATTACKER-HINT CAPTURE -- WHY THIS IS A NEW, SELF-CONTAINED RELAY, NOT A
    REUSE OF client/tracking.lua's BLOOD-TRAIL `gameEventTriggered` HOOK
    (read together with server/defense.lua's REALITY-CHECK item 1):
    client/tracking.lua's own `CEventNetworkEntityDamage` handler (read
    before writing this one) fires `qbx_k9unit:server:relayDamageEvent`
    payload-LESS, on purpose -- that file's header explicitly warns against
    ever adding a coordinate/identity argument to that event. This file
    therefore registers its OWN, independent `gameEventTriggered` handler
    (FiveM dispatches every registered handler for a given event, so this
    coexists with client/tracking.lua's handler without conflict -- same
    "additional consumer, not a replacement" pattern server/wellbeing.lua's
    own header already documents for the identical relayDamageEvent/
    relayWeaponFire events) rather than touch that file at all.
    CONFIDENCE, restated from DEVELOPER_REFERENCE.md#tracking rather
    than re-derived: `data[1]` (victim) and `data[2]` (attacker, or -1/same-
    as-victim for a non-ped damage source) are the two `CEventNetworkEntityDamage`
    argument indices that note found corroborated across MULTIPLE
    INDEPENDENT secondary sources -- the SAME confidence tier
    client/tracking.lua's own victim filter already relies on for `data[1]`,
    not a new, weaker claim invented here for `data[2]`. Do not build logic
    depending on any OTHER index (that note's own explicit caveat).
    ======================================================================

    ======================================================================
    CLOCK-DOMAIN NOTE -- WHY `PendingDefensePrompt.expiresAt` IS COMPUTED
    LOCALLY, NOT RECEIVED FROM THE SERVER: mirrors client/combat.lua's own
    documented CLOCK-DOMAIN NOTE verbatim in spirit (that file's header,
    read before writing this one) -- server and client `GetGameTimer()`
    values are two independent per-process clocks with an arbitrary offset
    between them, so server/defense.lua deliberately sends NO `expiresAt`
    field at all. This file derives its own local deadline as
    `GetGameTimer() + Config.Combat.HandlerDownDefense.promptTtlMs`,
    anchored to THIS client's own clock at receipt time -- both sides
    derive the identical nominal duration from the identical shared
    config.lua constant, just anchored a network round-trip apart. LOWER
    STAKES than client/combat.lua's own use of this pattern (a stale prompt
    here just means a UI hint outlives its usefulness by a network
    round-trip, never an un-restored native side effect -- this file applies
    no native side effect at all, per the acceptance criteria above), so
    this is a courtesy correctness match, not a guardrail this file's own
    safety depends on the way client/combat.lua's does.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Client events (RegisterNetEvent, server->client), THIS FILE:
    - 'qbx_k9unit:client:handlerDownDefenseTrigger' (handlerNetId: number,
      suggestedTargetNetId: number?) [server/defense.lua]
      See "§12.0 ITEM 2 ACCEPTANCE CRITERIA" above for exactly what this
      handler is/isn't allowed to do.

    Server events (RegisterNetEvent, client->server), THIS FILE triggers:
    - 'qbx_k9unit:server:reportHandlerAttacker' (attackerNetId: number)
      [server/defense.lua] -- see ATTACKER-HINT CAPTURE above.
    - 'qbx_k9unit:server:requestBiteHold' (targetNetId: number)
      [server/combat.lua] -- see "PURE CONSUMER" above; NOT
      client/combat.lua's own RequestBiteHold() wrapper.
    - 'qbx_k9unit:server:requestTakedown' (targetNetId: number)
      [server/combat.lua] -- same as above, for RequestTakedown().

    Commands / keybinds (THIS FILE):
    - 'qbx_k9unit:confirmHandlerDownDefense' -- DEVELOPER_REFERENCE.md §12.0 item 2's
      "single simplified... input... instead of navigating the radial menu
      first," made concrete as a single default-bound key
      (Config.Combat.HandlerDownDefense.confirmKey, always rebindable
      client-side via FiveM's own keybind settings regardless of this
      default) calling `ConfirmHandlerDownDefense('bite')`. Bite-and-hold
      is the disclosed default action (see that function's own comment) --
      `ConfirmHandlerDownDefense('takedown')` is exposed as a resource-global
      for a future radial/second-keybind entry, not wired to a keybind of
      its own -- client/radial.lua's own 'k9unit_defense' submenu (see
      RADIAL CONTRACT below) calls it directly instead.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes three resource-global (no `local`) functions, same
      "expose for a future radial entry, do not wire radial.lua myself"
      convention client/partnership.lua's own header already established
      for BreakPartnership()/RequestPartnerUp():
        ConfirmHandlerDownDefense(actionType: 'bite'|'takedown')
        HasFreshDefensePrompt() -> boolean
        GetDefenseSuggestedTargetNetId() -> number?
    - Calls HasK9Access()/DenyK9UIAccess() (client/main.lua) before
      ConfirmHandlerDownDefense acts -- UPDATED, permission audit follow-up
      this pass: was CanShowK9UI(), widened to match server/combat.lua's
      shared ValidateCombatRequest (the validator behind requestBiteHold/
      requestTakedown, which this file fires directly -- see "PURE
      CONSUMER" above), which gates access on HasK9Access(src) alone -- same
      "display gate only, server is the real boundary" posture as every
      other gated client action in this resource.
    - Calls ResolveNetworkEntity(netId) (client/main.lua, ONE-argument
      client-side signature -- distinct from server/entities.lua's
      two-argument version, per that global's own documented "same name,
      mirrored API, two distinct VMs" convention) as a courtesy pre-check
      only -- never the real boundary, which is entirely server-side.
    - Reads `IsBiteHoldEngaged()` (client/combat.lua) behind a
      `type(...) == 'function'` runtime existence guard -- soft dependency,
      not a load-order assumption, this codebase's established convention.
    - Reads Config.Combat.HandlerDownDefense (config.lua; see that block
      for the exact fields, including four DEVELOPER_REFERENCE.md's own §12.2
      sketch did not anticipate: pollIntervalMs/retriggerCooldownMs/
      promptTtlMs/attackerReportCooldownMs/confirmKey -- see
      server/defense.lua's own header for
      pollIntervalMs/retriggerCooldownMs/attackerReportCooldownMs;
      promptTtlMs/confirmKey are consumed only here).
    - No onResourceStop handler -- disclosed omission, not an oversight:
      unlike client/combat.lua (which sets PERSISTENT native flags/
      relationships that must be restored on a resource restart mid-effect
      -- see that file's own header), this file applies NO native side
      effect to any entity, ever (see §12.0 ITEM 2 ACCEPTANCE CRITERIA
      above) -- `PendingDefensePrompt` is a plain in-memory Lua table with
      no game-state counterpart to restore, so there is nothing for a stop
      handler to clean up.
    ======================================================================
]]

if not Config.Features.HandlerDownDefense then return end

-- ======================================================================
-- CONFIG-SAFETY GUARD -- promptTtlMs
--
-- Every OTHER numeric field in Config.Combat.HandlerDownDefense goes
-- through server/defense.lua's ResolveConfiguredThresholdMs
-- (pollIntervalMs, retriggerCooldownMs, attackerReportCooldownMs). This
-- one did not, because it is genuinely client-only -- server/defense.lua
-- and this file each document that promptTtlMs is "consumed only here",
-- which meant each side assumed the other was not responsible for it and
-- neither validated it.
--
-- A non-positive value here is a SILENT, WHOLE-FEATURE failure. Line ~227
-- sets `expiresAt = GetGameTimer() + promptTtlMs`, so a 0 or negative
-- makes the prompt already expired the instant it is created:
-- ClearExpiredPrompt drops it immediately, HasFreshDefensePrompt reads
-- false forever, and every attempt to respond -- keybind or radial --
-- fails with "no active alert" for the whole session, with nothing
-- printed anywhere to explain it.
--
-- Zero is a plausible mistake to make rather than a far-fetched one:
-- this same resource documents 0 as a legitimate "disabled" idiom for a
-- similarly-shaped sibling field (server/integrations.lua's
-- minDurationMs), so an operator could reasonably expect it to mean
-- "no timeout" here. It means the opposite.
--
-- Clamped client-side, matching client/agility.lua's vaultCooldownMs
-- guard exactly rather than the server-only resolver. The `v == v` term
-- rejects NaN, which compares false against everything including itself.
-- ======================================================================
do
    local defenseCfg = Config.Combat and Config.Combat.HandlerDownDefense
    if type(defenseCfg) == 'table' then
        local ttl = defenseCfg.promptTtlMs
        if not (type(ttl) == 'number' and ttl == ttl and ttl > 0) then
            print(
                ('[qbx_k9unit] Config.Combat.HandlerDownDefense.promptTtlMs must be a positive number of ' ..
                 'milliseconds (found: %s). A non-positive value would silently make every handler-down ' ..
                 'alert expire the instant it appears, so the K9 could never respond to one. Using the ' ..
                 'built-in fallback of 10000 instead so this feature keeps working while the config is ' ..
                 'fixed.'):format(tostring(ttl))
            )
            defenseCfg.promptTtlMs = 10000
        end
    end
end

--- Local-only, ephemeral cache of the most recent still-fresh trigger --
--- @type { handlerNetId: number, suggestedTargetNetId: number?, expiresAt: number }|nil
local PendingDefensePrompt = nil

--- @return nil
local function ClearExpiredPrompt()
    if PendingDefensePrompt and GetGameTimer() >= PendingDefensePrompt.expiresAt then
        PendingDefensePrompt = nil
    end
end

--- @return boolean
function HasFreshDefensePrompt()
    ClearExpiredPrompt()
    return PendingDefensePrompt ~= nil
end

--- @return number?
function GetDefenseSuggestedTargetNetId()
    ClearExpiredPrompt()
    return PendingDefensePrompt and PendingDefensePrompt.suggestedTargetNetId or nil
end

--- Receives the server's own decision that this K9's partnered handler
--- just crossed the down-threshold, per server/defense.lua's own
--- TryNotifyPartnerK9. See this file's header "§12.0 ITEM 2 ACCEPTANCE
--- CRITERIA" -- this handler applies NOTHING beyond a notification and an
--- in-memory suggestion.
--- @param handlerNetId number
--- @param suggestedTargetNetId number?
RegisterNetEvent('qbx_k9unit:client:handlerDownDefenseTrigger', function(handlerNetId, suggestedTargetNetId)
    -- SOURCE-ORIGIN GUARD -- see client/combat.lua's own "SOURCE-ORIGIN
    -- GUARD" header block for the full sourced writeup/confidence grading,
    -- not re-derived here. Without this, a modified client could locally
    -- fire this event with an arbitrary `suggestedTargetNetId` to pre-seed
    -- its own PendingDefensePrompt (and the notification below) with zero
    -- server contact — low standalone payoff today
    -- (ConfirmHandlerDownDefense still re-validates everything
    -- server-side per this feature's own "manual confirm, server
    -- re-checks" design), but closes the same "arbitrary event, zero
    -- server contact" gap this resource's convention now expects for
    -- every client:* handler. Confidence: MEDIUM-HIGH, not certain — see
    -- client/combat.lua's header for the honest caveat.
    if source ~= 65535 then return end
    PendingDefensePrompt = {
        handlerNetId = handlerNetId,
        suggestedTargetNetId = (type(suggestedTargetNetId) == 'number') and suggestedTargetNetId or nil,
        -- CLOCK-DOMAIN NOTE (this file's header) -- local deadline, never a
        -- raw server-stamped timestamp.
        expiresAt = GetGameTimer() + Config.Combat.HandlerDownDefense.promptTtlMs,
    }

    -- RECONCILED WITH client/radial.lua: this notify mentions the radial
    -- menu because client/radial.lua's own 'k9unit_defense' submenu
    -- ("Handler-Down Response" -> "Bite & Hold Attacker" / "Non-Lethal
    -- Takedown Attacker") calls this exact ConfirmHandlerDownDefense
    -- ('bite'/'takedown') contract (see the RADIAL CONTRACT block below).
    -- If that submenu is ever removed, this line must be reverted to
    -- keybind-only wording in the SAME change, not left to drift out of
    -- sync (client/radial.lua is owned and edited separately from this
    -- file).
    lib.notify({
        title = locale('common.notify_title'),
        description = locale('defense.handler_under_attack', Config.Combat.HandlerDownDefense.confirmKey),
        type = 'error',
        duration = Config.Combat.HandlerDownDefense.promptTtlMs,
    })
end)

--- ======================================================================
--- RADIAL CONTRACT (this file is the producer; client/radial.lua -- owned
--- separately, never edited by this file -- is the consumer). Documented
--- here as the stable signature that file's own submenu ('k9unit_defense'
--- -- "Handler-Down Response" -> "Bite & Hold Attacker" / "Non-Lethal
--- Takedown Attacker", confirmed wired) is built against, so a future
--- change to either side has a single source of truth to check against:
--- `ConfirmHandlerDownDefense(actionType)` will not change shape without
--- updating this comment:
---   - `actionType`: pass the string literal `'bite'` or `'takedown'`.
---     Any other value (including nil) silently falls back to `'bite'`
---     (see this function's own DEFAULT ACTION TYPE comment below) -- a
---     radial entry does not need to guard against a bad value itself.
---   - Return value: none (fires a `lib.notify` on every rejection path
---     itself -- a radial entry does not need its own error handling).
---   - Side effects if called with no fresh prompt / no resolvable target /
---     already-engaged: a `lib.notify` only, never a thrown error -- safe
---     to call speculatively/optimistically from a radial menu at any time.
--- The notify text above in 'qbx_k9unit:client:handlerDownDefenseTrigger'
--- mentions the radial menu because the entry above is real, not
--- aspirational -- if that radial submenu is ever removed, that notify
--- text must be reverted to keybind-only wording in the SAME change, not
--- left to drift out of sync again.
--- ======================================================================
--- Manual confirmation step -- DEVELOPER_REFERENCE.md §12.0 item 2's own "the K9
--- player must still manually confirm before any bite-and-hold or takedown
--- action actually executes" acceptance criterion, made concrete. Exposed
--- as a resource-global for a future radial entry (see FILE-TO-FILE
--- CONTRACT above) and already wired to a default keybind below.
---
--- DEFAULT ACTION TYPE, disclosed judgment call: DEVELOPER_REFERENCE.md §12.5.3
--- names both `requestBiteHold`/`requestTakedown` as this feature's
--- downstream targets but does not specify which one a single "confirm"
--- input should prefer. Bite-and-hold is chosen as the default here
--- (`actionType` falls back to `'bite'` for any value other than the two
--- valid ones) because it has no additional precondition beyond the shared
--- validation prefix (unlike NonLethalTakedown, which additionally requires
--- server/combat.lua's own server-computed "is this target currently
--- fleeing" speed gate to pass) -- a K9 confirming defense-mode against a
--- hostile who is NOT currently fleeing would otherwise silently fail with
--- `not_fleeing` for no reason apparent from this feature's own UI.
--- `ConfirmHandlerDownDefense('takedown')` remains fully available for a
--- future radial/second-keybind entry that wants it explicitly.
---
--- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission audit
--- finding, this pass): this function's only downstream effect is firing
--- the raw 'qbx_k9unit:server:requestBiteHold'/'requestTakedown' events
--- directly (see this file's own "PURE CONSUMER" header section) -- the
--- SAME events client/combat.lua's own RequestBiteHold()/RequestTakedown()
--- fire, which land on the SAME shared server/combat.lua ValidateCombatRequest
--- (confirmed by reading it directly, ~line 1428: `if not HasK9Access(src)
--- then return false, ..., 'no_access' end`, with no model/role check
--- anywhere in that validator). This function used to gate on the broader
--- CanShowK9UI() combinator (IsOwnModelK9() AND HasK9Access(), or IsK9Role()
--- AND HasK9Access() depending on config -- either way, the model/role half
--- deliberately EXCLUDES the High Command/autoAccessGrade bypass, per
--- server/appearance.lua's own header), so a High Command officer whose
--- ONLY access came from that bypass could never confirm a handler-down
--- defense through ANY route (keybind, radial, or tablet) even though the
--- server would gladly have granted it -- exactly the emergency moment this
--- feature exists for. Matches the identical, already-shipped precedent
--- client/combat.lua's own RequestBiteHold()/RequestTakedown() (which fire
--- the very same two server events) already use on themselves -- not a new
--- idiom. NOTE FOR THE NEXT READER: client/radial.lua's 'k9unit_defense'
--- submenu (k9_defense_bite/k9_defense_takedown) and client/tablet.lua's
--- own HandlerDownDefense trigger BOTH used to carry their own separate,
--- redundant CanShowK9UI() pre-check ahead of calling this function,
--- written and justified at the time as "widening only here would be a
--- no-op because the callee re-gates anyway" -- that justification stopped
--- holding once THIS gate widened. Both call sites have SINCE been
--- corrected (verified by reading each directly): client/radial.lua's
--- 'k9unit_defense' submenu now calls ConfirmHandlerDownDefense() straight
--- through with no pre-check of its own (see that file's own "UPDATED
--- (three-surfaces-agree pass...)" note), and client/tablet.lua's
--- HandlerDownDefense wrapper likewise removed its pre-check (see that
--- file's own "NOT GATED HERE, AND THE HISTORY MATTERS" note) -- no
--- residual gap remains at either call site as of this comment.
--- @param actionType 'bite'|'takedown'
function ConfirmHandlerDownDefense(actionType)
    if not HasK9Access() then
        DenyK9UIAccess('combat.no_access')
        return
    end

    -- EXPIRED-VS-NEVER-TRIGGERED (this pass -- a refusal-clarity fix, not a
    -- gate change): read the RAW `PendingDefensePrompt` state BEFORE calling
    -- HasFreshDefensePrompt() below, which -- via ClearExpiredPrompt -- would
    -- otherwise nil out an actually-expired prompt in the very same call
    -- that checks it, making "it timed out" indistinguishable from "there
    -- was never one" by the time this function could tell the difference.
    -- Precise, not a time-window heuristic: this reads the exact internal
    -- state at the exact moment ConfirmHandlerDownDefense itself was
    -- invoked, so there is no race between "recently expired" and "long
    -- since expired" to get wrong.
    local hadPromptButExpired = PendingDefensePrompt ~= nil and GetGameTimer() >= PendingDefensePrompt.expiresAt
    if not HasFreshDefensePrompt() then
        local description = hadPromptButExpired and locale('defense.alert_expired') or locale('defense.no_active_alert')
        lib.notify({ title = locale('common.notify_title'), description = description, type = 'error' })
        return
    end

    if actionType ~= 'bite' and actionType ~= 'takedown' then
        actionType = 'bite' -- see this function's own doc comment above
    end

    -- Soft, courtesy pre-check ONLY -- server/combat.lua's own
    -- ValidateCombatRequest independently re-derives already_engaged
    -- regardless of what this client believes; this just avoids a doomed
    -- round trip and gives a clearer message than a generic server error
    -- would. Runtime existence guard: no load-order assumption on
    -- client/combat.lua, this codebase's established convention, even
    -- though fxmanifest.lua's own ordering is expected to load it first.
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
        lib.notify({ title = locale('common.notify_title'), description = locale('defense.already_engaged'), type = 'error' })
        return
    end

    local targetNetId = GetDefenseSuggestedTargetNetId()
    if targetNetId and not ResolveNetworkEntity(targetNetId) then
        -- The suggested hostile isn't even streamed in for THIS client
        -- right now (e.g. genuinely too far away for this client's own
        -- entity-streaming radius) -- fall back to "no pre-selected
        -- target" rather than fire a request this client already has
        -- reason to expect will fail server-side proximity anyway. Courtesy
        -- only -- server/combat.lua re-resolves independently regardless.
        targetNetId = nil
    end

    if not targetNetId then
        lib.notify({ title = locale('common.notify_title'), description = locale('defense.no_hostile_detected'), type = 'info' })
        return
    end

    -- "PURE CONSUMER" NOTE (this file's header) -- fires the underlying
    -- server event directly; NOT client/combat.lua's own RequestBiteHold()/
    -- RequestTakedown() wrappers, which take no target parameter.
    if actionType == 'takedown' then
        TriggerServerEvent('qbx_k9unit:server:requestTakedown', targetNetId)
    else
        TriggerServerEvent('qbx_k9unit:server:requestBiteHold', targetNetId)
    end

    PendingDefensePrompt = nil -- consumed -- a second press without a fresh trigger falls through to "no active alert" above, never re-fires the same request twice
end

RegisterCommand('qbx_k9unit:confirmHandlerDownDefense', function()
    ConfirmHandlerDownDefense('bite')
end, false)

RegisterKeyMapping('qbx_k9unit:confirmHandlerDownDefense', locale('defense.confirm_keybind_label'), 'keyboard', Config.Combat.HandlerDownDefense.confirmKey)

--- Attacker-hint capture -- see this file's header ATTACKER-HINT CAPTURE
--- section for why this is a new, independent `gameEventTriggered` handler
--- rather than a reuse/extension of client/tracking.lua's own hook.
AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end

    local victim = tonumber(data[1])
    if victim ~= PlayerPedId() then return end -- only relay when WE are the (potential handler) victim, mirrors client/tracking.lua's own confirmed filter

    -- data[2]: attacker entity handle, OR -1/same-as-victim for a non-ped
    -- damage source (falls, vehicle impacts, environmental) -- see this
    -- file's header for the confidence grading on this index.
    local attacker = tonumber(data[2])
    if not attacker or attacker == -1 or attacker == victim then return end
    if not DoesEntityExist(attacker) then return end
    if GetEntityType(attacker) ~= 1 then return end -- ped only -- cheap client-side pre-filter; server/defense.lua re-verifies regardless

    TriggerServerEvent('qbx_k9unit:server:reportHandlerAttacker', NetworkGetNetworkIdFromEntity(attacker))
end)
