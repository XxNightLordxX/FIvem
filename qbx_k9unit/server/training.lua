--[[
    qbx_k9unit/server/training.lua

    Training-mode / practice sandbox, distinct from live duty --
    DEVELOPER_REFERENCE.md Part A Tier B §6. A certified handler/K9 who is
    PHYSICALLY inside a configured `Config.TrainingZones` entry can turn on
    Training Mode and rehearse the search / bite-and-hold interaction FLOW
    against a scripted, fake server response -- never a real target, never
    real ox_inventory contents, never a real live-duty effect on another
    player.

    ======================================================================
    THE XP DECISION -- ZERO, BY CONSTRUCTION, NOT A CONFIGURABLE AMOUNT.
    Read this before ever adding a call to AwardXP/AwardXPDirect anywhere
    in this file.

    server/progression.lua's own EIGHTH-XP-FARM-FIX section (read in full
    before writing this file) already derives, from the REAL shipped
    Config.XP.awards table, that round-robining all four existing
    mechanics (bite-hold/takedown/search/track) uncapped comes to 5,700
    XP/hr, and that this codebase has already found and closed EIGHT
    separate XP farms -- the most recent a COMPOUND farm across exactly
    that shape, closed specifically because it required "close to zero
    real police work" to reach the top tier in ~1h35m against a >2-hour
    design floor. The shared cross-mechanic mint budget that fix installed
    (XP_MINT_BUDGET_CAP_XP = 3,600 XP per rolling hour, server/progression.lua)
    is the current real, live ceiling for ALL FOUR of those mechanics
    COMBINED, regardless of how a player round-robins between them.

    A training dummy has LESS real-world friction than any of those four
    mechanics, not the same amount: no vehicle or person needs to exist to
    search, no wanted/fleeing target needs to exist to bite-hold, nothing
    can ever fail, flee, escape, or run out. If training paid ANY XP at
    all -- even the exact same per-action amounts as the real mechanics,
    even gated through the exact same shared mint-budget chokepoint this
    file could trivially call into (AwardXP is resource-global specifically
    so any caller can) -- a "trainee" standing alone in an empty yard could
    hit the ENTIRE 3,600 XP/hr shared ceiling faster and more reliably than
    the compound farm that fix was written to close, because it would not
    even need the eighth farm's own minimal setup (a vehicle, a provoked
    NPC, a stash). Reusing the shared budget does not raise the numeric
    ceiling, but it makes reaching it a strictly EASIER, lower-effort action
    than every real mechanic the budget was sized against -- training would
    become the path of least resistance to the top tier, not a supplement
    to it. That is a NINTH farm, and a cheaper one to run than any of the
    eight already found and closed.

    DECISION: Training Mode awards ZERO XP into K9XP, full stop. Not a
    small amount, not a separate slower-refilling budget, not a fraction of
    the real award -- this file contains NO call to AwardXP, NO call to
    AwardXPDirect, and reads no field of Config.XP.awards. THE CEILING IS
    0 XP/HOUR, BY CONSTRUCTION -- verifiable by grep, not merely by
    argument (see tests/training_spec.lua's own "no AwardXP reference
    anywhere in this file's source text" case, in addition to its
    behavioral cases). This is precisely what makes it safe to leave
    genuinely UNLIMITED for practice, per the owner's own stated
    preference: a mechanism that cannot mint progression XP under any
    input has no farm-rate to bound in the first place, so it never needs
    its own cooldown-vs-throughput tuning pass the way every real award
    already required (this file's OWN per-action cooldown below exists
    only to bound DB-free, CPU-free spam against this resource's own event
    bus, not to protect an economy that isn't there).

    A SEPARATE, NON-PROGRESSION COUNTER DOES EXIST -- `TrainingReps` below,
    purely informational ("you completed N practice reps this session"),
    kept ONLY in memory, NEVER written to any database table, NEVER
    exported, NEVER read by any other file, and cleared on both
    Training-Mode-OFF and disconnect. It cannot leak into progression by
    any code path because no code path connects it to one -- this is a
    stronger guarantee than "gated," which is why it is safe to expose
    even though this file's whole point is being usable without limit.
    ======================================================================

    ======================================================================
    "UNMISTAKABLY DISTINCT FROM LIVE DUTY" -- WHAT IS DISABLED, AND HOW.

    1. NO REAL TARGET IS EVER REACHABLE THROUGH THIS FILE'S OWN SURFACE.
       trainingSearch/trainingBiteHold below take NO target argument at
       all (contrast server/search.lua's searchTarget callback, which
       takes targetNetId) -- there is no netId, player, or vehicle for a
       trainee to name, so this file's own two actions cannot be pointed
       at anything real even by a maliciously modified client. The
       "result" is generated from Config.Training.ContrabandFoundChance
       alone, with no entity resolution step anywhere in this file.

    2. ZONE-GATED, SERVER-DERIVED, NEVER CLIENT-CLAIMED. Every transition
       into Training Mode, and every training action while already in it,
       independently re-reads the caller's OWN live server-side position
       (GetEntityCoords(GetPlayerPed(source))) against Config.TrainingZones
       -- never a client-supplied "I'm in the zone" flag. Wandering out of
       every configured zone silently turns Training Mode back off on the
       very next action attempt (and pushes the client-side banner off
       with it -- see IsWithinAnyTrainingZone's call sites below).

    3. FORCED CLEANUP OF ANY REAL ACTIVE ENGAGEMENT ON ENTRY. Turning
       Training Mode ON calls server/combat.lua's own
       EndActiveEffectForHolder(source) first (the exact same termination
       primitive server/recall.lua's handler-issued Recall already reuses)
       -- so a K9 who is mid-real-bite-hold/takedown/drag and switches to
       Training Mode has that real engagement ended immediately, the same
       way a Recall would, rather than leaving it running "underneath" a
       now-active Training Mode flag. Runtime existence guard
       (`type(EndActiveEffectForHolder) == 'function'`), not a load-order
       assumption -- this file's own FILE-TO-FILE CONTRACT section below
       documents the soft dependency in full.

    4. VISIBLE STATE, SERVER-CONFIRMED. `qbx_k9unit:client:trainingModeChanged`
       is fired ONLY by this file, ONLY after a transition this file itself
       validated -- client/training.lua's persistent on-screen banner
       reflects that push, never an optimistic client-side toggle. A
       rejected "turn on" request (no access, too far, no zones configured)
       never fires the event at all, so the banner never lies about a
       transition that did not actually happen.

    5. HONEST, DISCLOSED RESIDUAL GAP -- read before assuming this closes
       the loop completely. This file does NOT, and CANNOT from inside
       itself, prevent a K9 who is standing in a training zone with
       Training Mode ON from ALSO using the REAL search/bite-and-hold
       commands (server/search.lua / server/combat.lua) against a REAL
       nearby player -- those two files are owned by a different,
       concurrently-active pass this session (see
       scratchpad/COORDINATION.md's ownership map) and this file does not
       edit them. The real commands remain completely unaware of
       TrainingMode below and keep working exactly as before, everywhere,
       including inside a training zone. Two structural properties keep
       this gap narrow rather than open: (a) this file's own training
       actions can NEVER touch a real target regardless (see point 1
       above), so the only failure direction is "a real action still works
       while training is flagged on," never "a training action secretly
       does something real"; (b) a training zone is expected to be an
       out-of-the-way yard, not a place real suspects are searched, so the
       practical exposure is low. A precise, minimal, additive one-line
       guard for each of server/search.lua's and server/combat.lua's own
       success paths (an early return when `IsCitizenIdInTrainingMode`,
       exposed resource-global by this file for exactly this purpose,
       returns true for the acting citizenid) has been reported to that
       pass's owner rather than applied here -- see this pass's own report
       for the exact proposed diff.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Server events (client->server):
    - 'qbx_k9unit:server:setTrainingMode' (desiredOn: boolean) -- toggles
      Training Mode for the calling source. Turning OFF is UNCONDITIONAL --
      no cooldown, no HasK9Access check, no zone check -- per this
      resource's own "no unbounded trap" rule (server/recall.lua,
      client/movement.lua's DetachLeash() carry the identical rule for
      their own termination paths). Turning ON requires, in order: not
      currently on ToggleCooldown, HasK9Access(source), at least one
      Config.TrainingZones entry configured, and the caller's live
      server-side position resolving inside one of them.

    Client events (server->client):
    - 'qbx_k9unit:client:trainingModeChanged' (isOn: boolean) -- fired ONLY
      after a transition THIS file validated; see point 4 above.

    Callbacks (ox_lib lib.callback, client->server):
    - 'qbx_k9unit:server:trainingSearch' () -> { ok, reason?, contrabandFound?, reps? }
    - 'qbx_k9unit:server:trainingBiteHold' () -> { ok, reason?, reps? }
      Both take NO arguments (see point 1 above), both re-derive
      eligibility fully server-side on every call via
      CheckTrainingActionEligibility below, both are rate-limited per
      caller (Config.Training.ActionCooldownMs, `on_cooldown` reason,
      silent client-side per this resource's established convention), and
      NEITHER calls AwardXP/AwardXPDirect, touches ox_inventory, or writes
      to k9_search_log -- see "THE XP DECISION" above.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls `HasK9Access(source)` (server/certifications.lua) and
      `EndActiveEffectForHolder(holderSrc)` (server/combat.lua), both via a
      `type(...) == 'function'` runtime existence guard -- this
      resource's established soft-dependency convention, not a load-order
      assumption. HasK9Access missing/false is a hard deny (fail closed);
      EndActiveEffectForHolder missing is a silent skip (nothing to end).
    - Calls `NewCooldown()` (server/cooldowns.lua) at THIS file's own
      file-load time -- must load after server/cooldowns.lua in
      fxmanifest.lua's server_scripts, same requirement every other
      consumer already states.
    - Calls `NotifyPlayer` (server/notify.lua) -- must load after that
      file, same as every other consumer.
    - THIS FILE exposes NO resource-global function of its own today (see
      point 5 above for the one PROPOSED-but-not-yet-added export,
      `IsCitizenIdInTrainingMode`, which is intentionally not added until
      a real consumer -- server/search.lua/server/combat.lua's owner --
      confirms they will call it; an unused export is dead surface, not a
      readiness signal).
    - Never calls AwardXP/AwardXPDirect/GetXP/GetXPTier, never reads
      Config.XP, never inserts into k9_search_log or k9_progression -- see
      "THE XP DECISION" above.
    ======================================================================

    CONFIG THIS FILE ASSUMES EXISTS -- NOT owned by this file for this
    task (coder-backend does not own config.lua here; reported separately
    to whoever does). A missing `Config.Features.TrainingMode` is treated
    as `false` (whole file inert, matching server/recall.lua's own
    top-of-file gate) -- but every OTHER field below degrades to a safe,
    loudly-logged built-in default rather than erroring, mirroring
    server/recall.lua's own "a termination-adjacent feature must never
    fail closed on a missing config block" posture (turning Training Mode
    ON is not itself a termination path, but a broken config here has no
    security/economy consequence either way -- see "THE XP DECISION" --
    so the softer, always-degrades-gracefully convention is the right one,
    not admin.lua's harder assert-at-startup posture, which this task
    reserves for genuinely security-relevant thresholds):
      Config.Features.TrainingMode      : boolean (new; default false)
      Config.TrainingZones              : array of { label: string, x: number, y: number, z: number, radius: number } (new)
      Config.Training.ToggleCooldownMs  : number  (new; built-in fallback 3000 if missing/invalid)
      Config.Training.ActionCooldownMs  : number  (new; built-in fallback 4000 if missing/invalid)
      Config.Training.ContrabandFoundChance : number in [0,1] (new; built-in fallback 0.5 if missing/invalid)
]]

if not Config.Features.TrainingMode then return end

-- ----------------------------------------------------------------------
-- DEFENSIVE CONFIG READS -- mirrors server/recall.lua's own pattern
-- exactly (a missing/malformed block degrades to a safe built-in default
-- with a loud console print, never an error at file-load time, never a
-- silent wrong value). See this file's header "CONFIG THIS FILE ASSUMES
-- EXISTS" for why this softer posture, not admin.lua's assert-at-startup
-- one, is the right choice here.
-- ----------------------------------------------------------------------
local TOGGLE_COOLDOWN_FALLBACK_MS = 3000
local ACTION_COOLDOWN_FALLBACK_MS = 4000
local CONTRABAND_CHANCE_FALLBACK = 0.5

--- @param value any
--- @param fallback number
--- @param fieldName string
--- @return number
local function ReadPositiveMsOrFallback(value, fallback, fieldName)
    if type(value) == 'number' and value > 0 then return value end
    print(('[qbx_k9unit] training: Config.Training.%s is missing or not a positive number; using a built-in %dms default instead.'):format(fieldName, fallback))
    return fallback
end

local trainingCfg = Config.Training
local toggleCooldownMs = TOGGLE_COOLDOWN_FALLBACK_MS
local actionCooldownMs = ACTION_COOLDOWN_FALLBACK_MS
local contrabandFoundChance = CONTRABAND_CHANCE_FALLBACK

if type(trainingCfg) == 'table' then
    toggleCooldownMs = ReadPositiveMsOrFallback(trainingCfg.ToggleCooldownMs, TOGGLE_COOLDOWN_FALLBACK_MS, 'ToggleCooldownMs')
    actionCooldownMs = ReadPositiveMsOrFallback(trainingCfg.ActionCooldownMs, ACTION_COOLDOWN_FALLBACK_MS, 'ActionCooldownMs')

    local chance = trainingCfg.ContrabandFoundChance
    if type(chance) == 'number' and chance >= 0 and chance <= 1 then
        contrabandFoundChance = chance
    else
        print(('[qbx_k9unit] training: Config.Training.ContrabandFoundChance is missing or not in [0,1]; using a built-in %.2f default instead.'):format(CONTRABAND_CHANCE_FALLBACK))
    end
else
    print('[qbx_k9unit] training: Config.Training is missing entirely; using built-in cooldown/chance defaults. Add the Config.Training block from config.lua to configure these.')
end

-- Config.TrainingZones -- see this file's header for the exact shape. A
-- missing/empty table is NOT a load-time error: Training Mode simply can
-- never be turned ON anywhere on this server (every "on" request fails
-- with a clear, non-silent notice below) until at least one zone is
-- configured -- the safe direction for a feature with no economy/security
-- stake either way.
local TrainingZones = (type(Config.TrainingZones) == 'table') and Config.TrainingZones or {}
if #TrainingZones == 0 then
    print('[qbx_k9unit] training: Config.TrainingZones is missing or empty -- Training Mode cannot be turned ON anywhere on this server until at least one zone is configured.')
end

-- TrainingMode[citizenid] = true. In-memory ONLY -- never persisted, never
-- exported, never read outside this file. This is deliberate: Training
-- Mode is live SESSION state, not progression, and has no reason to
-- survive a restart the way real progression (k9_progression) does.
local TrainingMode = {}

-- TrainingReps[citizenid] = number. Session-only, informational counter --
-- see this file's header "THE XP DECISION" for why this is safe to leave
-- genuinely unbounded. Never written to any table, never exported.
local TrainingReps = {}

local ToggleCooldown = NewCooldown(toggleCooldownMs)
ToggleCooldown.RegisterPlayerDropped()

local ActionCooldown = NewCooldown(actionCooldownMs)
ActionCooldown.RegisterPlayerDropped()

--- Is `coords` (an {x,y,z}-shaped table -- a real FiveM vector3 already
--- exposes those three fields, and so does this suite's own test stub)
--- inside at least one configured Config.TrainingZones entry? Every
--- malformed zone entry (missing/non-numeric x/y/z/radius, a
--- non-positive radius) is skipped defensively rather than throwing --
--- one bad entry must never take down every OTHER, well-formed zone.
--- @param coords table
--- @return boolean
local function IsWithinAnyTrainingZone(coords)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' then return false end

    for _, zone in ipairs(TrainingZones) do
        if type(zone) == 'table'
            and type(zone.x) == 'number' and type(zone.y) == 'number' and type(zone.z) == 'number'
            and type(zone.radius) == 'number' and zone.radius > 0
        then
            local dx, dy, dz = coords.x - zone.x, coords.y - zone.y, coords.z - zone.z
            if (dx * dx + dy * dy + dz * dz) <= (zone.radius * zone.radius) then
                return true
            end
        end
    end

    return false
end

--- Shared server-authoritative eligibility re-check for BOTH training
--- drills below. NEVER trusts the client's own belief that it is "in
--- training" -- re-derives everything from server-held state on every
--- single call, the same discipline every real mechanic in this resource
--- already applies to itself (client/search.lua's own header: "this file
--- only ever CONSUMES... every field is 100% server-computed"). A caller
--- who has drifted out of eligibility (cert revoked, wandered out of the
--- zone) has their TrainingMode flag cleared HERE, and the client-side
--- banner is told to turn off with it -- so the visible state can never
--- silently drift from what this file actually believes.
--- @param src number
--- @return boolean ok
--- @return string citizenidOrReason -- the resolved citizenid on success; a reason string on failure
local function CheckTrainingActionEligibility(src)
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return false, 'no_access' end

    if not TrainingMode[citizenid] then return false, 'not_training' end

    if type(HasK9Access) ~= 'function' or not HasK9Access(src) then
        TrainingMode[citizenid] = nil
        TriggerClientEvent('qbx_k9unit:client:trainingModeChanged', src, false)
        return false, 'no_access'
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return false, 'no_access' end

    if not IsWithinAnyTrainingZone(GetEntityCoords(ped)) then
        TrainingMode[citizenid] = nil
        TriggerClientEvent('qbx_k9unit:client:trainingModeChanged', src, false)
        return false, 'too_far'
    end

    if not ActionCooldown.Consume(src) then
        return false, 'on_cooldown'
    end

    return true, citizenid
end

--- Step 1: toggle Training Mode. See this file's header "EVENT/CALLBACK
--- CONTRACT" and point 4 ("UNMISTAKABLY DISTINCT") for the full contract.
--- `desiredOn` is coerced to a strict boolean -- ANY non-`true` value
--- (nil, a stray string, garbage) is treated as an OFF request, per this
--- resource's "the safe direction for a malformed input on a termination-
--- adjacent path is the one that always succeeds" convention.
RegisterNetEvent('qbx_k9unit:server:setTrainingMode', function(desiredOn)
    local src = source
    desiredOn = desiredOn == true

    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end -- defensive: src disconnected between the event firing and this line, or not yet loaded

    if not desiredOn then
        -- OFF IS UNCONDITIONAL -- no cooldown, no access check, no zone
        -- check. See this file's header point 4 and the "no unbounded
        -- trap" precedent this mirrors (server/recall.lua,
        -- client/movement.lua's DetachLeash()).
        local wasOn = TrainingMode[citizenid] == true
        local reps = TrainingReps[citizenid] or 0
        TrainingMode[citizenid] = nil
        TrainingReps[citizenid] = nil
        TriggerClientEvent('qbx_k9unit:client:trainingModeChanged', src, false)
        if wasOn then
            NotifyPlayer(src, locale('training.off', reps), 'success')
        end
        return
    end

    -- ON is a real, gated transition -- see this file's header point 2.
    if not ToggleCooldown.Consume(src) then
        return -- silent no-op: rate-limited, matches this resource's established spam-guard convention
    end

    if type(HasK9Access) ~= 'function' or not HasK9Access(src) then
        NotifyPlayer(src, locale('training.no_access'), 'error')
        return
    end

    if #TrainingZones == 0 then
        NotifyPlayer(src, locale('training.no_zones_configured'), 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    if not IsWithinAnyTrainingZone(GetEntityCoords(ped)) then
        NotifyPlayer(src, locale('training.too_far'), 'error')
        return
    end

    -- FORCED CLEANUP -- see this file's header point 3 for the full
    -- reasoning. pcall-wrapped defensively even though
    -- EndActiveEffectForHolder is already internally pcall-safe (this
    -- file's own belt-and-suspenders, not a sign that function is
    -- believed to be unsafe).
    if type(EndActiveEffectForHolder) == 'function' then
        pcall(EndActiveEffectForHolder, src)
    end

    TrainingMode[citizenid] = true
    TrainingReps[citizenid] = TrainingReps[citizenid] or 0
    TriggerClientEvent('qbx_k9unit:client:trainingModeChanged', src, true)
    NotifyPlayer(src, locale('training.on'), 'success')
end)

--- Practice search drill -- see this file's header "THE XP DECISION" and
--- point 1 ("NO REAL TARGET IS EVER REACHABLE"). Takes NO target argument
--- -- there is nothing here for a caller, modified or not, to point at a
--- real vehicle/person.
--- @param source number (ox_lib supplies this as the callback's first argument)
--- @return table { ok: boolean, reason: string?, contrabandFound: boolean?, reps: number? }
lib.callback.register('qbx_k9unit:server:trainingSearch', function(source)
    local ok, citizenidOrReason = CheckTrainingActionEligibility(source)
    if not ok then return { ok = false, reason = citizenidOrReason } end
    local citizenid = citizenidOrReason

    TrainingReps[citizenid] = (TrainingReps[citizenid] or 0) + 1

    -- SCRIPTED, FAKE result -- math.random() only, NEVER ox_inventory,
    -- NEVER k9_search_log, NEVER AwardXP. See "THE XP DECISION" above.
    local found = math.random() < contrabandFoundChance
    return { ok = true, contrabandFound = found, reps = TrainingReps[citizenid] }
end)

--- Practice bite-and-hold drill -- same contract/guarantees as
--- trainingSearch above, adapted for the other mechanic this task named
--- explicitly. A pure scripted acknowledgement: no target argument, no
--- entity resolution, no ragdoll/control-disable/damage-immunity applied
--- to anything, no AwardXP.
--- @param source number
--- @return table { ok: boolean, reason: string?, reps: number? }
lib.callback.register('qbx_k9unit:server:trainingBiteHold', function(source)
    local ok, citizenidOrReason = CheckTrainingActionEligibility(source)
    if not ok then return { ok = false, reason = citizenidOrReason } end
    local citizenid = citizenidOrReason

    TrainingReps[citizenid] = (TrainingReps[citizenid] or 0) + 1

    return { ok = true, reps = TrainingReps[citizenid] }
end)

-- Bounded-memory cleanup, mirroring server/progression.lua's own
-- playerDropped handler for its citizenid-keyed K9XP cache exactly. Not a
-- correctness requirement (a stale TrainingMode/TrainingReps entry for a
-- now-offline citizenid is simply never read again until they reconnect
-- and turn Training Mode on again fresh), just bounded memory growth on a
-- long-running server.
AddEventHandler('playerDropped', function()
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        TrainingMode[citizenid] = nil
        TrainingReps[citizenid] = nil
    end
end)
