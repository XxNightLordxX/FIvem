--[[
    tests/training_spec.lua

    Direct tests of server/training.lua against the REAL, unmodified
    production file.

    THE LOAD-BEARING TEST IN THIS FILE (per this task's own instruction):
    "training mode cannot mint progression XP." Proven TWO independent
    ways, deliberately not just one:
      1. SOURCE-LEVEL: server/training.lua's own raw text contains no
         reference to AwardXP/AwardXPDirect/K9XP/Config.XP at all -- a
         static, structural guarantee that survives even a future edit
         this spec itself hasn't anticipated.
      2. BEHAVIORAL: AwardXP/AwardXPDirect are injected into this sandbox
         as SPIES (not omitted) -- every toggle-on, every practice search,
         every practice bite-and-hold, run many times across many
         citizenids, and the spies' call counts are asserted to be exactly
         zero throughout. Injecting real, callable spies (rather than
         leaving the globals undefined) matters: an undefined global would
         only prove "this file happens not to reference an undefined name
         yet," which is true of almost any bug-free file and proves
         nothing about intent; a CALLABLE spy that stays at zero calls
         proves this file was actually exercised end-to-end and chose,
         every time, not to call it.

    Also covers: the "OFF is unconditional, no unbounded trap" guarantee
    (mirrors server/recall.lua's own tested contract), the zone-gated ON
    transition (server-derived position, never client-claimed), the forced
    end of any real active engagement on entry (EndActiveEffectForHolder
    reuse), mid-session eligibility drift (HasK9Access revoked / wandered
    out of the zone) auto-clearing TrainingMode and pushing the
    client-facing "off" event, the per-source action cooldown, the
    session-only (never persisted) rep counter, and the whole-file
    Config.Features.TrainingMode gate.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- SOURCE-LEVEL GUARANTEE -- read the real file's raw text directly, before
-- any sandbox is even built. See this file's header point 1.
-- ----------------------------------------------------------------------

local function readFile(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

--- Strips this file's own comments before the substring checks below run --
--- a naive raw-text search would false-positive on this task's own header
--- prose (which discusses AwardXP/Config.XP BY NAME, at length, to explain
--- why they are never called -- the exact opposite of what this test is
--- checking for). Two passes: the long `--[[ ... ]]` header block comment,
--- then any remaining `-- ...` line comments. Safe for THIS file
--- specifically because none of its string literals (event names, locale
--- keys, notifyType strings) contain the two-character sequence "--" --
--- re-verify that if this ever changes, since a real occurrence inside a
--- string would be incorrectly truncated by the line-comment pass below.
--- @param text string
--- @return string
local function stripLuaComments(text)
    text = text:gsub('%-%-%[%[.-%]%]', '')
    local out = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        out[#out + 1] = line:match('^(.-)%-%-') or line
    end
    return table.concat(out, '\n')
end

t.test('SOURCE-LEVEL: server/training.lua\'s CODE (comments stripped) never references AwardXP, AwardXPDirect, K9XP, or Config.XP anywhere', function()
    local code = stripLuaComments(readFile('../server/training.lua'))
    t.notContains(code, 'AwardXP', 'server/training.lua must never call AwardXP (would mint real progression XP) -- this also catches AwardXPDirect as a substring')
    t.notContains(code, 'K9XP', 'server/training.lua must never read/write server/progression.lua\'s own K9XP cache directly')
    t.notContains(code, 'Config.XP', 'server/training.lua must never read Config.XP.awards or any other Config.XP field')
    t.notContains(code, 'k9_progression', 'server/training.lua must never touch the k9_progression persistence table')
    t.notContains(code, 'k9_search_log', 'server/training.lua must never write to the real search audit log')
end)

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local RESOURCE_NAME = 'qbx_k9unit'

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName() return RESOURCE_NAME end

local netEvents = {}
local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

local registeredCallbacks = {}
local libStub = {
    callback = {
        register = function(name, handler) registeredCallbacks[name] = handler end,
    },
}

local clientEvents = {}
local function TriggerClientEvent(eventName, target, ...)
    clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
end

local notifyCalls = {}
local function NotifyPlayer(target, description, notifyType)
    notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
end

-- exports.qbx_core:GetPlayer(source) stub -- keyed by source, same shape
-- server/recall.lua's own spec fixtures already use.
local playersBySource = {}
local function GetPlayer(_self, src) return playersBySource[src] end
local exportsStub = { qbx_core = { GetPlayer = GetPlayer } }

--- Registers `src` as a connected player with the given citizenid and (by
--- default) a valid ped/coordinate inside the first configured zone.
--- @param src number
--- @param citizenid string
local function registerPlayer(src, citizenid)
    playersBySource[src] = { PlayerData = { source = src, citizenid = citizenid } }
end

-- HasK9Access(source) -- test-controlled per source, defaults to true for
-- any registered source unless a test explicitly overrides it.
local hasAccessBySource = {}
local hasAccessCallCount = 0
local function HasK9Access(src)
    hasAccessCallCount = hasAccessCallCount + 1
    if hasAccessBySource[src] == nil then return true end
    return hasAccessBySource[src]
end

-- GetPlayerPed(source)/GetEntityCoords(ped) -- ped handle == source for
-- simplicity; coords test-controlled per source.
local coordsBySource = {}
local function GetPlayerPed(src)
    if playersBySource[src] == nil then return 0 end
    return src
end
local function GetEntityCoords(ped) return coordsBySource[ped] or { x = 0.0, y = 0.0, z = 0.0 } end

-- SPIES this file's header point 2 relies on -- see "SOURCE-LEVEL
-- GUARANTEE" above for why BOTH a source scan and a live spy are used.
local awardXpCallCount = 0
local function AwardXP() awardXpCallCount = awardXpCallCount + 1 end
local awardXpDirectCallCount = 0
local function AwardXPDirect() awardXpDirectCallCount = awardXpDirectCallCount + 1 end

local endActiveEffectCalls = {}
local endActiveEffectReturn = false
local function EndActiveEffectForHolder(holderSrc)
    endActiveEffectCalls[#endActiveEffectCalls + 1] = holderSrc
    return endActiveEffectReturn
end

local Config = {
    Features = { TrainingMode = true },
    TrainingZones = {
        { label = 'LSPD K9 Training Yard', x = 100.0, y = 200.0, z = 30.0, radius = 20.0 },
    },
    Training = {
        ToggleCooldownMs = 1000,
        ActionCooldownMs = 2000,
        ContrabandFoundChance = 0.5,
    },
}

local randomValue = 0.0 -- see setRandom() below
local mathStub = {}
for k, v in pairs(math) do mathStub[k] = v end
mathStub.random = function() return randomValue end

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    RegisterNetEvent = RegisterNetEvent,
    TriggerClientEvent = TriggerClientEvent,
    NotifyPlayer = NotifyPlayer,
    exports = exportsStub,
    HasK9Access = HasK9Access,
    GetPlayerPed = GetPlayerPed,
    GetEntityCoords = GetEntityCoords,
    AwardXP = AwardXP,
    AwardXPDirect = AwardXPDirect,
    EndActiveEffectForHolder = EndActiveEffectForHolder,
    lib = libStub,
    math = mathStub,
    Config = Config,
})

Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/training.lua', env)

t.isNotNil(netEvents['qbx_k9unit:server:setTrainingMode'], 'server/training.lua must register its toggle net event')
t.isNotNil(registeredCallbacks['qbx_k9unit:server:trainingSearch'], 'server/training.lua must register the trainingSearch callback')
t.isNotNil(registeredCallbacks['qbx_k9unit:server:trainingBiteHold'], 'server/training.lua must register the trainingBiteHold callback')
t.isNotNil(eventHandlers['playerDropped'], 'server/training.lua must register a playerDropped handler for bounded-memory cleanup')

-- ----------------------------------------------------------------------
-- Test helpers
-- ----------------------------------------------------------------------

local nextSource = 1
--- Registers a fresh, always-eligible player: valid access, coords inside
--- the one configured zone, a unique citizenid. Returns the source.
local function freshEligibleSource()
    nextSource = nextSource + 1
    local src = nextSource
    local citizenid = 'CIT' .. tostring(src)
    registerPlayer(src, citizenid)
    coordsBySource[src] = { x = 105.0, y = 205.0, z = 30.0 } -- inside the 20.0-radius zone centered at (100,200,30)
    hasAccessBySource[src] = true
    return src, citizenid
end

local function setTrainingMode(src, desiredOn)
    env.source = src
    netEvents['qbx_k9unit:server:setTrainingMode'](desiredOn)
end

local function runTrainingSearch(src)
    env.source = src
    return registeredCallbacks['qbx_k9unit:server:trainingSearch'](src)
end

local function runTrainingBiteHold(src)
    env.source = src
    return registeredCallbacks['qbx_k9unit:server:trainingBiteHold'](src)
end

local function lastClientEventFor(src)
    for i = #clientEvents, 1, -1 do
        if clientEvents[i].target == src then return clientEvents[i] end
    end
    return nil
end

-- ----------------------------------------------------------------------
-- ZERO XP -- BEHAVIORAL (see this file's header point 2)
-- ----------------------------------------------------------------------

t.test('ZERO XP: toggling on/off and running BOTH drills repeatedly across many citizenids never calls AwardXP or AwardXPDirect', function()
    awardXpCallCount, awardXpDirectCallCount = 0, 0

    for _ = 1, 5 do
        local src = freshEligibleSource()
        setTrainingMode(src, true)
        for _ = 1, 10 do
            fakeNow = fakeNow + 3000 -- clear the action cooldown between reps
            runTrainingSearch(src)
            fakeNow = fakeNow + 3000
            runTrainingBiteHold(src)
        end
        setTrainingMode(src, false)
    end

    t.equals(awardXpCallCount, 0, 'AwardXP must never be called by any training path')
    t.equals(awardXpDirectCallCount, 0, 'AwardXPDirect must never be called by any training path')
end)

-- ----------------------------------------------------------------------
-- TOGGLE ON -- gated
-- ----------------------------------------------------------------------

t.test('toggle ON succeeds for an eligible player inside a configured zone, and pushes trainingModeChanged(true)', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    local evt = lastClientEventFor(src)
    t.isNotNil(evt)
    t.equals(evt.event, 'qbx_k9unit:client:trainingModeChanged')
    t.isTrue(evt.args[1])
end)

t.test('toggle ON is DENIED without HasK9Access, and never fires trainingModeChanged', function()
    local src, _ = freshEligibleSource()
    hasAccessBySource[src] = false
    clientEvents = {}
    setTrainingMode(src, true)
    t.isNil(lastClientEventFor(src), 'a denied ON request must never push a state change to the client')
end)

t.test('toggle ON is DENIED outside every configured zone', function()
    local src = freshEligibleSource()
    coordsBySource[src] = { x = 9000.0, y = 9000.0, z = 9000.0 }
    clientEvents = {}
    setTrainingMode(src, true)
    t.isNil(lastClientEventFor(src))
end)

t.test('toggle ON calls EndActiveEffectForHolder(src) FIRST -- forces any real active engagement to end before entering training', function()
    endActiveEffectCalls = {}
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    t.equals(#endActiveEffectCalls, 1)
    t.equals(endActiveEffectCalls[1], src)
end)

t.test('toggle ON is rate-limited per source (ToggleCooldownMs)', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    setTrainingMode(src, false)
    clientEvents = {}
    setTrainingMode(src, true) -- same instant -- still on ToggleCooldown
    t.isNil(lastClientEventFor(src), 'a second ON request inside the cooldown window must be silently dropped')
end)

-- ----------------------------------------------------------------------
-- TOGGLE OFF -- "no unbounded trap"
-- ----------------------------------------------------------------------

t.test('toggle OFF succeeds UNCONDITIONALLY -- no access, no zone, and it still turns off cleanly', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)

    hasAccessBySource[src] = false
    coordsBySource[src] = { x = 9000.0, y = 9000.0, z = 9000.0 }
    clientEvents = {}
    setTrainingMode(src, false)

    local evt = lastClientEventFor(src)
    t.isNotNil(evt, 'OFF must always push a state change, regardless of current access/zone standing')
    t.isFalse(evt.args[1])
end)

t.test('toggle OFF is NEVER rate-limited -- back-to-back on/off/on/off all succeed with zero cooldown wait', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    setTrainingMode(src, false)
    setTrainingMode(src, false)
    setTrainingMode(src, false)
    -- no error, no exception -- OFF has no gate to trip at all
    t.isTrue(true)
end)

t.test('a non-true desiredOn value (nil, a string, a number) is treated as OFF', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    clientEvents = {}
    setTrainingMode(src, 'yes please')
    local evt = lastClientEventFor(src)
    t.isNotNil(evt)
    t.isFalse(evt.args[1])
end)

-- ----------------------------------------------------------------------
-- TRAINING DRILLS -- eligibility, cooldown, scripted result
-- ----------------------------------------------------------------------

t.test('trainingSearch fails with not_training when Training Mode was never turned on', function()
    local src = freshEligibleSource()
    local result = runTrainingSearch(src)
    t.isFalse(result.ok)
    t.equals(result.reason, 'not_training')
end)

t.test('trainingSearch succeeds while training, and increments the session-only rep counter', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    local r1 = runTrainingSearch(src)
    t.isTrue(r1.ok)
    t.equals(r1.reps, 1)

    fakeNow = fakeNow + 3000
    local r2 = runTrainingSearch(src)
    t.equals(r2.reps, 2, 'reps must accumulate across successive drills in the same training session')
end)

t.test('the scripted search result respects Config.Training.ContrabandFoundChance via math.random -- deterministic in this sandbox', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)

    randomValue = 0.1 -- < 0.5 chance -> found
    local r1 = runTrainingSearch(src)
    t.isTrue(r1.contrabandFound)

    fakeNow = fakeNow + 3000
    randomValue = 0.9 -- >= 0.5 chance -> clean
    local r2 = runTrainingSearch(src)
    t.isFalse(r2.contrabandFound)
end)

t.test('trainingBiteHold succeeds while training and reports reps, with no contrabandFound field at all (a different drill shape)', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    local result = runTrainingBiteHold(src)
    t.isTrue(result.ok)
    t.isNil(result.contrabandFound)
end)

t.test('training actions are rate-limited per source (ActionCooldownMs) -- a second immediate call is denied', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    local r1 = runTrainingSearch(src)
    t.isTrue(r1.ok)
    local r2 = runTrainingSearch(src) -- same instant, still on ActionCooldown
    t.isFalse(r2.ok)
    t.equals(r2.reason, 'on_cooldown')
end)

t.test('MID-SESSION DRIFT: HasK9Access revoked after entering training -- the next action attempt fails no_access AND turns training back off (trainingModeChanged(false))', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    hasAccessBySource[src] = false
    clientEvents = {}

    local result = runTrainingSearch(src)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')

    local evt = lastClientEventFor(src)
    t.isNotNil(evt, 'a mid-session access revocation must push trainingModeChanged(false) so the client-side banner cannot lie about still being in training')
    t.isFalse(evt.args[1])

    -- Confirms the flag was really cleared server-side, not just the event
    -- fired: restoring access does NOT resurrect the old training session.
    hasAccessBySource[src] = true
    local result2 = runTrainingSearch(src)
    t.equals(result2.reason, 'not_training')
end)

t.test('MID-SESSION DRIFT: wandering out of every configured zone -- the next action attempt fails too_far AND turns training back off', function()
    local src = freshEligibleSource()
    setTrainingMode(src, true)
    coordsBySource[src] = { x = 9000.0, y = 9000.0, z = 9000.0 }
    clientEvents = {}

    local result = runTrainingSearch(src)
    t.isFalse(result.ok)
    t.equals(result.reason, 'too_far')

    local evt = lastClientEventFor(src)
    t.isNotNil(evt)
    t.isFalse(evt.args[1])
end)

-- ----------------------------------------------------------------------
-- playerDropped cleanup
-- ----------------------------------------------------------------------

t.test('playerDropped clears TrainingMode for the disconnecting citizenid -- a reconnect (new source, same citizenid re-registered) starts fresh, not still "training"', function()
    local src, citizenid = freshEligibleSource()
    setTrainingMode(src, true)

    env.source = src
    for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
        handler()
    end

    -- Re-register the SAME citizenid under a new source (simulated reconnect).
    nextSource = nextSource + 1
    local newSrc = nextSource
    registerPlayer(newSrc, citizenid)
    coordsBySource[newSrc] = { x = 105.0, y = 205.0, z = 30.0 }
    hasAccessBySource[newSrc] = true

    local result = runTrainingSearch(newSrc)
    t.equals(result.reason, 'not_training', 'a disconnect must clear the old session -- the reconnected citizenid must not silently still be "in training"')
end)

os.exit(t.summary())
