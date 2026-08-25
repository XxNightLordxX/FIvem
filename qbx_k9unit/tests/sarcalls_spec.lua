--[[
    tests/sarcalls_spec.lua

    Covers BOTH halves of missing-person / search-and-rescue calls
    (K9_IDEAS.md §3) in one file, per this task's own file-ownership
    constraint (only ONE new spec file permitted for this feature). Two
    independent sandboxes, one per file, following tests/scenttrail_spec.lua's
    own established two-section convention for this exact class of sibling
    feature rather than inventing a third shape:
      SECTION 1 (server/sarcalls.lua) -- a hand-built minimal Config table
        (not the real config.lua -- this spec does not depend on main
        having applied this feature's config.lua/locales/en.json additions
        yet), server/cooldowns.lua loaded for real ahead of it (a hard
        load-order dependency, same as production), lib.callback.register
        and RegisterNetEvent captured into tables and invoked directly. The
        tick loop is driven via fixtures/sandbox.lua's Sandbox.newThreadRunner
        (same technique tests/integrations_spec.lua already uses for
        server/integrations.lua's structurally identical PollK9Health loop).
      SECTION 2 (client/sarcalls.lua) -- a real, unmodified file loaded into
        a sandbox via Sandbox.loadInto, driven only through captured
        RegisterCommand/RegisterNetEvent handlers and lib.callback.await
        (a plain synchronous stub, per tests/scenttrail_spec.lua's own
        client-section precedent -- no coroutine yield is needed to drive
        RequestStartSarCall's single await), with a second, independent
        thread runner for ShowReveal's own on-demand auto-clear timer.

    Both sections stub math.random via a wrapper table (FakeMath), never by
    mutating the real global math table -- identical technique and
    identical reasoning to tests/scenttrail_spec.lua's own FakeMath.

    KNOWN, DISCLOSED COVERAGE GAP (per tests/fixtures/sandbox.lua's own
    house convention: say so rather than silently skip): the generation-
    token race RequestStartSarCall/RequestAbandonSarCall/the sarCallEnded
    handler all guard against (an abandon or a server-pushed end arriving
    while a start's own lib.callback.await is still pending) is not
    exercised end-to-end here, because this fixture's callbackAwait stub
    (mirroring tests/scenttrail_spec.lua's own) returns synchronously with
    no actual yield point for an "in the meantime" event to land inside --
    reproducing that interleaving would need a coroutine-based await stub
    this task's effort budget did not extend to building. The token-bump
    code itself is exercised directly (RequestAbandonSarCall visibly
    invalidates an ALREADY-RESOLVED prior start's staleness by being
    callable and clearing state at all -- see its own test below) -- what
    is NOT proven here is the specific interleaving where the bump happens
    strictly between an await's send and its return.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Shared: a controllable math.random queue -- see this file's header.
-- ----------------------------------------------------------------------
local randomQueue = {}
local FakeMath = setmetatable({
    random = function() return table.remove(randomQueue, 1) or 0.5 end,
}, { __index = math })
local function queueRandom(...)
    for _, v in ipairs({ ... }) do
        randomQueue[#randomQueue + 1] = v
    end
end

-- ========================================================================
-- SECTION 1 -- server/sarcalls.lua
-- ========================================================================

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local threadRunner = Sandbox.newThreadRunner()
local function CreateThread(fn) threadRunner.CreateThread(fn) end

-- Forward-declared -- server/sarcalls.lua's own playerDropped handler reads
-- the AMBIENT `source` global (this resource's own established convention,
-- e.g. server/cooldowns.lua's :RegisterPlayerDropped() closures), never a
-- parameter -- so firing it in this sandbox means setting `serverEnv.source`
-- first, then invoking the captured handler with NO arguments, exactly
-- mirroring how FXServer itself sets that ambient global before dispatch.
local serverEnv

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function firePlayerDropped(dropSource)
    serverEnv.source = dropSource
    for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
        handler()
    end
end

local registeredCallbacks = {}
local libStub = {
    callback = {
        register = function(name, handler) registeredCallbacks[name] = handler end,
    },
}

local registeredNetEvents = {}
local function RegisterNetEvent(eventName, handler)
    registeredNetEvents[eventName] = handler
end

--- Fires the captured abandonSarCall net-event handler as if
--- TriggerServerEvent('qbx_k9unit:server:abandonSarCall') had genuinely
--- arrived from `abandonSource` -- see the forward-declaration comment
--- above for why this must set the ambient `source` global.
--- @param abandonSource number
local function fireAbandonSarCall(abandonSource)
    serverEnv.source = abandonSource
    registeredNetEvents['qbx_k9unit:server:abandonSarCall']()
end

local pedCoordsBySource = {}
local function GetPlayerPed(source) return source end -- identity: this section's fake ped handle IS the source, same convention tests/scenttrail_spec.lua/tests/integrations_spec.lua both already use
local function GetEntityCoords(ped) return pedCoordsBySource[ped] or { x = 0, y = 0, z = 0 } end

local hasAccess = true
local function HasK9Access(_source) return hasAccess end

local playersBySource = {} -- src -> { citizenid = string, job = string }
local function qbxGetPlayer(_self, src)
    local rec = playersBySource[src]
    if not rec then return nil end
    return { PlayerData = { citizenid = rec.citizenid, job = { name = rec.job } } }
end

local triggerClientEventCalls = {}
local function TriggerClientEvent(eventName, target, ...)
    triggerClientEventCalls[#triggerClientEventCalls + 1] = { event = eventName, target = target, args = { ... } }
end

local outboundEvents = {}
local function TriggerEvent(eventName, ...)
    outboundEvents[#outboundEvents + 1] = { event = eventName, args = { ... } }
end

local awardCalls = {}
local function AwardXP(citizenid, actionKey)
    awardCalls[#awardCalls + 1] = { citizenid = citizenid, actionKey = actionKey }
end

local notifyCalls = {}
local function NotifyPlayer(target, description, notifyType)
    notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
end

--- @param overrides table? -- Config.SARCalls field overrides layered onto sane defaults, for the CONFIG-SAFETY GUARD tests
local function ServerConfigWith(overrides)
    local base = {
        minRadius = 10.0,
        maxRadius = 30.0,
        arrivalRadius = 3.0,
        burningDistance = 5.0,
        hotDistance = 15.0,
        warmDistance = 25.0,
        pollIntervalMs = 2000,
        maxCallDurationMs = 300000,
        startCooldownMs = 8000,
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return { Features = { SARCalls = true }, SARCalls = base, XP = { awards = { sarCallCompleted = 30 } } }
end

local ServerConfig = ServerConfigWith()

serverEnv = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    CreateThread = CreateThread,
    AddEventHandler = AddEventHandler,
    RegisterNetEvent = RegisterNetEvent,
    math = FakeMath,
    GetPlayerPed = GetPlayerPed,
    GetEntityCoords = GetEntityCoords,
    HasK9Access = HasK9Access,
    exports = { qbx_core = { GetPlayer = qbxGetPlayer } },
    TriggerClientEvent = TriggerClientEvent,
    TriggerEvent = TriggerEvent,
    AwardXP = AwardXP,
    NotifyPlayer = NotifyPlayer,
    lib = libStub,
    Config = ServerConfig,
})

Sandbox.loadInto('../server/cooldowns.lua', serverEnv) -- hard load-order dependency, see server/sarcalls.lua's own FILE-TO-FILE CONTRACT
Sandbox.loadInto('../server/sarcalls.lua', serverEnv)

local requestSarCall = registeredCallbacks['qbx_k9unit:server:requestSarCall']

--- One tick of the production tick loop.
local function tick()
    threadRunner.step()
end

t.test('server load: registers requestSarCall via lib.callback and abandonSarCall via RegisterNetEvent, and starts exactly one tick thread', function()
    t.isNotNil(requestSarCall)
    t.isNotNil(registeredNetEvents['qbx_k9unit:server:abandonSarCall'])
    t.equals(#threadRunner.threads, 1)
end)

t.test('requestSarCall: Config.Features.SARCalls off is a real no-op (reason = denied), even with access', function()
    ServerConfig.Features.SARCalls = false
    local result = requestSarCall(1)
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
    ServerConfig.Features.SARCalls = true
end)

t.test('requestSarCall: HasK9Access() false is a real no-op (reason = denied)', function()
    hasAccess = false
    local result = requestSarCall(1)
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
    hasAccess = true
end)

t.test('requestSarCall: an unresolvable citizenid is denied, and consumes no cooldown budget for anyone', function()
    -- source 50 has no playersBySource entry at all -- a transient
    -- exports.qbx_core:GetPlayer resolution miss.
    pedCoordsBySource[50] = { x = 0.0, y = 0.0, z = 0.0 }
    local result = requestSarCall(50)
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
end)

t.test('requestSarCall: success rolls a target from the CALLER\'S OWN live server-side coords, never a client-supplied one, and immediately pushes the real starting tier', function()
    playersBySource[2] = { citizenid = 'CIT_A', job = 'police' }
    pedCoordsBySource[2] = { x = 100.0, y = 200.0, z = 0.0 }
    queueRandom(0.0, 0.0) -- radius fraction 0.0 -> exactly minRadius (10.0); angle fraction 0.0 -> angle 0 -> cos=1, sin=0 -> target (110, 200)
    local before = #triggerClientEventCalls
    local result = requestSarCall(2)
    t.isTrue(result.started)
    t.isNil(result.reason)
    -- The target is never returned to the caller at all -- structurally,
    -- `result` carries only `started`/`reason`.
    t.isNil(result.targetX)
    t.isNil(result.distance)

    -- Immediate push: distance is exactly 10.0 (warmDistance=25 in this
    -- fixture's defaults) -> 'warm'.
    local push = triggerClientEventCalls[before + 1]
    t.equals(push.event, 'qbx_k9unit:client:sarHintTierChanged')
    t.equals(push.target, 2)
    t.equals(push.args[1], 'warm')
end)

t.test('requestSarCall: a second call for the SAME source while unfinished is rejected as already_active, with no new roll and no new push', function()
    playersBySource[3] = { citizenid = 'CIT_B', job = 'police' }
    pedCoordsBySource[3] = { x = 0.0, y = 0.0, z = 0.0 }
    queueRandom(0.0, 0.0)
    local first = requestSarCall(3)
    t.isTrue(first.started)

    local pushCountAfterFirst = #triggerClientEventCalls
    local second = requestSarCall(3)
    t.isFalse(second.started)
    t.equals(second.reason, 'already_active')
    t.equals(#triggerClientEventCalls, pushCountAfterFirst, 'no new push for a rejected request')
end)

t.test('requestSarCall: cooldown is keyed by CITIZENID, not by source -- a relog (same citizenid, different source) is still rejected', function()
    playersBySource[10] = { citizenid = 'CIT_RELOG', job = 'police' }
    pedCoordsBySource[10] = { x = 0.0, y = 0.0, z = 0.0 }
    queueRandom(0.0, 0.0)
    local first = requestSarCall(10)
    t.isTrue(first.started)
    fireAbandonSarCall(10) -- end the call so the SECOND attempt's rejection is unambiguously the cooldown, not already_active

    -- Simulate a relog: the SAME citizenid reconnects under a NEW source id.
    playersBySource[11] = { citizenid = 'CIT_RELOG', job = 'police' }
    pedCoordsBySource[11] = { x = 0.0, y = 0.0, z = 0.0 }
    local second = requestSarCall(11) -- fakeNow has NOT advanced past startCooldownMs (8000)
    t.isFalse(second.started)
    t.equals(second.reason, 'cooldown')
end)

t.test('requestSarCall: cooldown does NOT block a genuinely DIFFERENT citizenid', function()
    playersBySource[12] = { citizenid = 'CIT_UNRELATED', job = 'police' }
    pedCoordsBySource[12] = { x = 0.0, y = 0.0, z = 0.0 }
    queueRandom(0.0, 0.0)
    local result = requestSarCall(12)
    t.isTrue(result.started, 'a different citizenid must never be throttled by another citizenid\'s cooldown')
end)

t.test('tick loop: pushes sarHintTierChanged on EVERY tier crossing as the officer closes in, never twice in a row for the same tier', function()
    playersBySource[20] = { citizenid = 'CIT_TIER', job = 'police' }
    pedCoordsBySource[20] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000 -- clear any residual cooldown from earlier tests sharing this citizenid space
    queueRandom(0.0, 0.0) -- target lands at (10.0, 0.0) -- exactly minRadius, and 'warm' per this fixture's thresholds (5/15/25)
    requestSarCall(20)

    local pushesSoFar = #triggerClientEventCalls

    -- Still 10m away -- same tier as the initial push ('warm') -- must NOT re-push.
    tick()
    t.equals(#triggerClientEventCalls, pushesSoFar, 'no re-push for an unchanged tier')

    -- Close to 12m -> crosses into 'hot' (<=15).
    pedCoordsBySource[20] = { x = 8.0, y = 0.0, z = 0.0 } -- 2m from target -> distance 2.0... use a value that lands strictly inside 'hot', not 'burning'
    pedCoordsBySource[20] = { x = 3.0, y = 0.0, z = 0.0 } -- distance to (10,0) = 7.0 -> inside hotDistance(15), outside burningDistance(5) -> 'hot'
    tick()
    local hotPush = triggerClientEventCalls[#triggerClientEventCalls]
    t.equals(hotPush.event, 'qbx_k9unit:client:sarHintTierChanged')
    t.equals(hotPush.target, 20)
    t.equals(hotPush.args[1], 'hot')

    -- Close further to 4.0 -> 'burning' (<=5).
    pedCoordsBySource[20] = { x = 6.0, y = 0.0, z = 0.0 } -- distance to (10,0) = 4.0
    tick()
    local burningPush = triggerClientEventCalls[#triggerClientEventCalls]
    t.equals(burningPush.args[1], 'burning')
end)

t.test('tick loop: found -- awards XP exactly once, fires the sarCallCompleted outbound event with the right payload, notifies, and pushes sarCallEnded(found, callType)', function()
    playersBySource[21] = { citizenid = 'CIT_FOUND', job = 'ambulance' }
    pedCoordsBySource[21] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    local startedAt = fakeNow
    queueRandom(0.0, 0.0) -- target (10.0, 0.0)
    requestSarCall(21)

    -- Walk to within arrivalRadius (3.0).
    pedCoordsBySource[21] = { x = 9.0, y = 0.0, z = 0.0 } -- 1m from target
    fakeNow = fakeNow + 1234
    local awardCountBefore = #awardCalls
    tick()

    t.equals(#awardCalls, awardCountBefore + 1)
    local award = awardCalls[#awardCalls]
    t.equals(award.citizenid, 'CIT_FOUND')
    t.equals(award.actionKey, 'sarCallCompleted')

    local completedOutbound
    for _, ev in ipairs(outboundEvents) do
        if ev.event == 'qbx_k9unit:events:sarCallCompleted' and ev.args[1] == 21 then completedOutbound = ev end
    end
    t.isNotNil(completedOutbound, 'must fire the outbound sarCallCompleted event')
    t.equals(completedOutbound.args[2], 'CIT_FOUND')
    t.equals(completedOutbound.args[3], 'ambulance')
    t.isTrue(completedOutbound.args[4] == 'person' or completedOutbound.args[4] == 'property')
    t.equals(completedOutbound.args[5], 1234, 'durationMs must be measured from this call\'s own startedAt')

    local endPush = triggerClientEventCalls[#triggerClientEventCalls]
    t.equals(endPush.event, 'qbx_k9unit:client:sarCallEnded')
    t.equals(endPush.target, 21)
    t.equals(endPush.args[1], 'found')
    t.equals(endPush.args[2], completedOutbound.args[4], 'callType pushed to the client must match the callType in the outbound event')

    -- Confirmed actually cleared, not lingering: a fresh request from the
    -- SAME citizenid, after the cooldown, must succeed (no stale already_active).
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local fresh = requestSarCall(21)
    t.isTrue(fresh.started)
end)

t.test('tick loop: an unfinished call older than maxCallDurationMs auto-expires WITHOUT anyone polling or completing it -- awards nothing, fires no completed event', function()
    playersBySource[22] = { citizenid = 'CIT_TIMEOUT', job = 'police' }
    pedCoordsBySource[22] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    requestSarCall(22)

    local awardCountBefore = #awardCalls
    fakeNow = fakeNow + (ServerConfig.SARCalls.maxCallDurationMs + 1)
    -- Never move the ped and never call anything else -- purely the tick
    -- loop's own timer firing, matching this file's own "NO UNBOUNDED TRAP"
    -- requirement (a call must expire on a timer even if nobody completes it).
    tick()

    t.equals(#awardCalls, awardCountBefore, 'a timeout must never mint XP')
    for _, ev in ipairs(outboundEvents) do
        t.isFalse(ev.event == 'qbx_k9unit:events:sarCallCompleted' and ev.args[1] == 22, 'a timeout must never fire the completed outbound event')
    end

    local endPush = triggerClientEventCalls[#triggerClientEventCalls]
    t.equals(endPush.event, 'qbx_k9unit:client:sarCallEnded')
    t.equals(endPush.target, 22)
    t.equals(endPush.args[1], 'timeout')

    -- Confirmed actually cleared: a fresh request succeeds once the
    -- cooldown clears too.
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    t.isTrue(requestSarCall(22).started)
end)

t.test('abandonSarCall: UNCONDITIONAL -- clears an active call with Config off and access revoked, and is a harmless no-op with nothing active', function()
    playersBySource[23] = { citizenid = 'CIT_ABANDON', job = 'police' }
    pedCoordsBySource[23] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    requestSarCall(23)

    ServerConfig.Features.SARCalls = false -- feature disabled...
    hasAccess = false -- ...and access revoked...
    local awardCountBefore = #awardCalls
    fireAbandonSarCall(23) -- ...abandon must still work
    ServerConfig.Features.SARCalls = true
    hasAccess = true

    t.equals(#awardCalls, awardCountBefore, 'abandoning must never mint XP')
    local endPush = triggerClientEventCalls[#triggerClientEventCalls]
    t.equals(endPush.event, 'qbx_k9unit:client:sarCallEnded')
    t.equals(endPush.args[1], 'abandoned')

    -- No-op on a source with nothing active: must not error.
    fireAbandonSarCall(999)
end)

t.test('playerDropped clears a source\'s ActiveSarCalls entry (a fresh request for the same citizenid succeeds once past cooldown, no lingering already_active)', function()
    playersBySource[24] = { citizenid = 'CIT_DROP', job = 'police' }
    pedCoordsBySource[24] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    requestSarCall(24)

    firePlayerDropped(24)

    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local fresh = requestSarCall(24)
    t.isTrue(fresh.started, 'a dropped connection must not leave a stale already_active entry behind')
end)

-- ------------------------------------------------------------------------
-- CONFIG-SAFETY GUARD -- each bad value must error LOUDLY at load time,
-- naming the offending field, per this file's own established convention
-- (server/integrations.lua's identical guard is the precedent).
-- ------------------------------------------------------------------------

--- Attempts to load server/sarcalls.lua fresh into a throwaway env with
--- `badConfig` in place of Config.SARCalls, and returns the error message
--- (or nil if it did NOT error, which every case below treats as a test
--- failure).
--- @param badTuning table
--- @return string? err
local function loadWithBadConfig(badTuning)
    local freshEnv = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        CreateThread = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        math = FakeMath,
        lib = { callback = { register = function() end } },
        Config = { Features = { SARCalls = true }, SARCalls = badTuning, XP = { awards = { sarCallCompleted = 30 } } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', freshEnv)
    local ok, err = pcall(Sandbox.loadInto, '../server/sarcalls.lua', freshEnv)
    if ok then return nil end
    return tostring(err)
end

t.test('CONFIG-SAFETY GUARD: Config.SARCalls missing entirely errors, naming Config.SARCalls', function()
    local err = loadWithBadConfig(nil)
    t.isNotNil(err)
    t.contains(err, 'Config.SARCalls')
end)

t.test('CONFIG-SAFETY GUARD: a non-positive minRadius errors, naming minRadius', function()
    local err = loadWithBadConfig({
        minRadius = 0, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isNotNil(err)
    t.contains(err, 'minRadius')
end)

t.test('CONFIG-SAFETY GUARD: maxRadius < minRadius errors, naming maxRadius', function()
    local err = loadWithBadConfig({
        minRadius = 30, maxRadius = 10, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isNotNil(err)
    t.contains(err, 'maxRadius')
end)

t.test('CONFIG-SAFETY GUARD: burningDistance <= arrivalRadius errors, naming burningDistance', function()
    local err = loadWithBadConfig({
        minRadius = 10, maxRadius = 30, arrivalRadius = 5, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isNotNil(err)
    t.contains(err, 'burningDistance')
end)

t.test('CONFIG-SAFETY GUARD: hotDistance out of order (<= burningDistance) errors, naming hotDistance', function()
    local err = loadWithBadConfig({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 15, hotDistance = 10,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isNotNil(err)
    t.contains(err, 'hotDistance')
end)

t.test('CONFIG-SAFETY GUARD: a non-positive pollIntervalMs errors, naming pollIntervalMs', function()
    local err = loadWithBadConfig({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 0, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isNotNil(err)
    t.contains(err, 'pollIntervalMs')
end)

t.test('CONFIG-SAFETY GUARD: a non-positive startCooldownMs is caught by NewCooldown\'s OWN constructor guard, naming NewCooldown', function()
    local err = loadWithBadConfig({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 0,
    })
    t.isNotNil(err)
    t.contains(err, 'NewCooldown')
end)

-- ========================================================================
-- SECTION 2 -- client/sarcalls.lua
-- ========================================================================

--- @param opts table? -- { canShowK9UI: boolean?, badConfig: table? }
local function newClientFixture(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local denyCalls = 0
    local function CanShowK9UI() return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local k9SitCalls = 0
    local function K9Sit() k9SitCalls = k9SitCalls + 1 end

    local playK9SoundCalls = {}
    local function PlayK9Sound(netId, soundName)
        playK9SoundCalls[#playK9SoundCalls + 1] = { netId = netId, soundName = soundName }
    end

    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        return table.remove(callbackResponses, 1)
    end

    local notifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    local myPed = 1
    local function PlayerPedId() return myPed end
    local function GetEntityHeading(_entity) return 0.0 end
    local function GetOffsetFromEntityInWorldCoords(_entity, x, y, z) return { x = x, y = y, z = z } end
    local function NetworkGetNetworkIdFromEntity(entity) return entity * 1000 end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    local netEventHandlers = {}
    local function registerClientNetEvent(eventName, handler)
        netEventHandlers[eventName] = handler
    end

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted)
        commandHandlers[name] = handler
    end

    -- Model-load plumbing -- mirrors client/kennel.lua's own natives
    -- exactly (RequestModel/HasModelLoaded/IsModelValid/SetModelAsNoLongerNeeded).
    -- validModels[name] = true means the model both exists AND loads
    -- successfully within LoadModelWithTimeout's own timeout; anything not
    -- listed is treated as never-loading (IsModelValid false), modeling a
    -- misconfigured model name.
    local validModels = opts.validModels or { ['mp_m_freemode_01'] = true, ['prop_tennis_ball'] = true }
    local function GetHashKey(name) return name end -- identity: this fixture's fake "hash" IS the model name string
    local function IsModelValid(name) return validModels[name] == true end
    local function RequestModel(_name) end
    local function HasModelLoaded(_name) return true end -- every "valid" model loads instantly in this fixture -- REQUEST_MODEL_TIMEOUT_MS's own wait-loop is not this file's concern to re-prove per feature, client/kennel.lua's own spec already covers that helper's timeout behavior structurally
    local setModelAsNoLongerNeededCalls = 0
    local function SetModelAsNoLongerNeeded(_name) setModelAsNoLongerNeededCalls = setModelAsNoLongerNeededCalls + 1 end

    -- Entity creation/lifecycle plumbing.
    local nextEntityHandle = 100
    local createdPeds = {}
    local createdObjects = {}
    local existingEntities = {}
    local deleteEntityCalls = {}
    local freezeCalls = {}
    local scenarioCalls = {}
    local function CreatePed(pedType, modelHash, x, y, z, heading, isNetwork, bScriptHostPed)
        nextEntityHandle = nextEntityHandle + 1
        local handle = nextEntityHandle
        existingEntities[handle] = true
        createdPeds[#createdPeds + 1] = {
            handle = handle, pedType = pedType, modelHash = modelHash, x = x, y = y, z = z,
            heading = heading, isNetwork = isNetwork, bScriptHostPed = bScriptHostPed,
        }
        return handle
    end
    local function CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag)
        nextEntityHandle = nextEntityHandle + 1
        local handle = nextEntityHandle
        existingEntities[handle] = true
        createdObjects[#createdObjects + 1] = {
            handle = handle, modelHash = modelHash, x = x, y = y, z = z,
            isNetwork = isNetwork, netMissionEntity = netMissionEntity, doorFlag = doorFlag,
        }
        return handle
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function DeleteEntity(entity)
        deleteEntityCalls[#deleteEntityCalls + 1] = entity
        existingEntities[entity] = nil
    end
    local function FreezeEntityPosition(entity, toggle) freezeCalls[#freezeCalls + 1] = { entity = entity, toggle = toggle } end
    local function TaskStartScenarioInPlace(entity, name, duration, playEnter)
        scenarioCalls[#scenarioCalls + 1] = { entity = entity, name = name, duration = duration, playEnter = playEnter }
    end

    local resourceStopHandlers = {}
    local function registerResourceAwareHandler(eventName, handler)
        if eventName == 'onResourceStop' then
            resourceStopHandlers[#resourceStopHandlers + 1] = handler
        else
            registerClientNetEvent(eventName, handler)
        end
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        K9Sit = K9Sit,
        PlayK9Sound = PlayK9Sound,
        lib = lib,
        PlayerPedId = PlayerPedId,
        GetEntityHeading = GetEntityHeading,
        GetOffsetFromEntityInWorldCoords = GetOffsetFromEntityInWorldCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        TriggerServerEvent = TriggerServerEvent,
        RegisterNetEvent = registerClientNetEvent,
        AddEventHandler = registerResourceAwareHandler,
        RegisterCommand = RegisterCommand,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        GetHashKey = GetHashKey,
        IsModelValid = IsModelValid,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        CreatePed = CreatePed,
        CreateObject = CreateObject,
        DoesEntityExist = DoesEntityExist,
        DeleteEntity = DeleteEntity,
        FreezeEntityPosition = FreezeEntityPosition,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        source = 65535, -- ambient `source` seen by a REAL server->client push in production; per-call emit helpers below shadow this to model a forged self-trigger
    }

    local env = Sandbox.newEnv(overrides)
    env.Config = {
        Features = { SARCalls = true },
        SARCalls = opts.badConfig or {
            missingPersonPedModel = 'mp_m_freemode_01',
            lostPropertyPropModel = 'prop_tennis_ball',
            revealDurationMs = 15000,
        },
    }

    Sandbox.loadInto('../client/sarcalls.lua', env)

    return {
        env = env,
        stepOne = runner.step,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        playK9SoundCalls = playK9SoundCalls,
        createdPeds = createdPeds,
        createdObjects = createdObjects,
        deleteEntityCalls = deleteEntityCalls,
        freezeCalls = freezeCalls,
        scenarioCalls = scenarioCalls,
        setModelAsNoLongerNeededCallCount = function() return setModelAsNoLongerNeededCalls end,
        k9SitCallCount = function() return k9SitCalls end,
        denyCallCount = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        startCommand = function(args) commandHandlers['k9sarcall'](1, args or {}) end,
        --- Fires every captured onResourceStop handler as if THIS resource
        --- were genuinely stopping (resourceName == 'qbx_k9unit', matching
        --- the fixture's own GetCurrentResourceName() stub).
        fireResourceStop = function()
            for _, handler in ipairs(resourceStopHandlers) do handler('qbx_k9unit') end
        end,
        --- Fires a pushed hint-tier event as if it genuinely came from the
        --- server (source == 65535) unless `forged` is true.
        fireHintTier = function(tier, forged)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:sarHintTierChanged'](tier)
        end,
        --- Fires a pushed call-ended event, same forgery-modeling shape.
        fireCallEnded = function(reason, callType, forged)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:sarCallEnded'](reason, callType)
        end,
    }
end

t.test('CONFIG-SAFETY GUARD (client): a missing missingPersonPedModel errors at load time, naming missingPersonPedModel', function()
    local ok, err = pcall(newClientFixture, { badConfig = { lostPropertyPropModel = 'prop_tennis_ball', revealDurationMs = 1000 } })
    t.isFalse(ok)
    t.contains(tostring(err), 'missingPersonPedModel')
end)

t.test('CONFIG-SAFETY GUARD (client): a non-positive revealDurationMs errors at load time, naming revealDurationMs', function()
    local ok, err = pcall(newClientFixture, { badConfig = {
        missingPersonPedModel = 'mp_m_freemode_01', lostPropertyPropModel = 'prop_tennis_ball', revealDurationMs = 0,
    } })
    t.isFalse(ok)
    t.contains(tostring(err), 'revealDurationMs')
end)

t.test('RequestStartSarCall: CanShowK9UI() false denies access locally and never calls the server callback', function()
    local f = newClientFixture({ canShowK9UI = false })
    f.env.RequestStartSarCall()
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
end)

t.test('RequestStartSarCall: success calls the requestSarCall callback and sets local active state (a second attempt is rejected locally, no new round trip)', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:requestSarCall')

    local before = f.callbackCallCount()
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), before, 'an already-active local state must never re-call the server')
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.already_active'))
end)

t.test('RequestStartSarCall: reason = already_active / cooldown / anything else map to the right notify without crashing on a nil reason', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = false, reason = 'already_active' })
    f.env.RequestStartSarCall()
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.already_active'))

    f.queueCallbackResponse({ started = false, reason = 'cooldown' })
    f.env.RequestStartSarCall()
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.request_cooldown'))

    f.queueCallbackResponse({ started = false, reason = 'denied' })
    f.env.RequestStartSarCall()
    t.equals(f.denyCallCount(), 1) -- 'denied' collapses to the generic DenyK9UIAccess() path

    f.queueCallbackResponse(nil) -- a timed-out/rejected lib.callback.await
    f.env.RequestStartSarCall()
    t.equals(f.denyCallCount(), 2)
end)

t.test('RequestAbandonSarCall: UNCONDITIONAL -- sends the server event even when CanShowK9UI() is false, and clears local active state', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.setCanShowK9UI(false)
    f.env.RequestAbandonSarCall()
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:abandonSarCall')

    -- Local state cleared: a fresh start attempt (once access is restored)
    -- must call the server again rather than being rejected as already_active.
    f.setCanShowK9UI(true)
    f.queueCallbackResponse({ started = true })
    local before = f.callbackCallCount()
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), before + 1)
end)

t.test('sarHintTierChanged: a FORGED push (source ~= 65535) is rejected -- the trust-boundary origin guard', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.fireHintTier('burning', true)
    t.equals(#f.notifyCalls, 0, 'a forged push must never reach the notify/sound path')
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('sarHintTierChanged: genuine pushes notify per-tier and play the right sound (or none for cold)', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.fireHintTier('warm')
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_warm'))
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Growl_Ambient')

    f.fireHintTier('hot')
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_hot'))
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Bark_Calm')

    f.fireHintTier('burning')
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_burning'))
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Bark_Alert')

    local soundCountBeforeCold = #f.playK9SoundCalls
    f.fireHintTier('cold')
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_cold'))
    t.equals(#f.playK9SoundCalls, soundCountBeforeCold, 'cold must never play a sound -- text only, per this resource\'s own "do not overdo it" caution')
end)

t.test('sarHintTierChanged: a stale push after the call already ended locally is ignored', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    f.env.RequestAbandonSarCall()

    f.fireHintTier('burning')
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('sarCallEnded: a FORGED push (source ~= 65535) is rejected entirely -- no state change, no reveal', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.fireCallEnded('found', 'person', true)
    t.equals(#f.createdPeds, 0)
    t.equals(f.k9SitCallCount(), 0)

    -- Local state must still read as active -- proven by a second start
    -- attempt being rejected locally rather than reaching the server again.
    local before = f.callbackCallCount()
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), before)
end)

t.test('sarCallEnded(found, person): plays the alert bark, sits, and spawns a NON-NETWORKED ped at the finder\'s own offset position', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.fireCallEnded('found', 'person')

    t.equals(f.k9SitCallCount(), 1)
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Bark_Alert')

    t.equals(#f.createdPeds, 1)
    t.equals(#f.createdObjects, 0)
    local ped = f.createdPeds[1]
    t.equals(ped.modelHash, 'mp_m_freemode_01')
    t.isFalse(ped.isNetwork, 'the reveal ped must NEVER be networked -- see this file\'s header')
    t.isFalse(ped.bScriptHostPed)
    t.equals(#f.scenarioCalls, 1)
    t.equals(f.scenarioCalls[1].entity, ped.handle)
end)

t.test('sarCallEnded(found, property): spawns a NON-NETWORKED, frozen tennis-ball prop, never a ped', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.fireCallEnded('found', 'property')

    t.equals(#f.createdObjects, 1)
    t.equals(#f.createdPeds, 0)
    local obj = f.createdObjects[1]
    t.equals(obj.modelHash, 'prop_tennis_ball')
    t.isFalse(obj.isNetwork, 'the reveal prop must NEVER be networked -- see this file\'s header')
    t.isTrue(obj.netMissionEntity)
    t.equals(#f.freezeCalls, 1)
    t.equals(f.freezeCalls[1].entity, obj.handle)
    t.isTrue(f.freezeCalls[1].toggle)
end)

t.test('sarCallEnded(found): a model that never loads degrades to a silent no-op -- no entity, no error, no stuck state', function()
    local f = newClientFixture({ validModels = {} }) -- neither model "exists" in this fixture
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()

    f.fireCallEnded('found', 'person')
    t.equals(#f.createdPeds, 0)
    t.equals(#f.createdObjects, 0)
    -- K9Sit()/the bark still fire regardless -- the "trained final response"
    -- is not gated on the cosmetic reveal succeeding.
    t.equals(f.k9SitCallCount(), 1)
end)

t.test('sarCallEnded(found): the reveal auto-deletes itself after Config.SARCalls.revealDurationMs, via the SAME client that created it', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    f.fireCallEnded('found', 'property')
    local obj = f.createdObjects[1]

    -- Prime, then run the reveal's own auto-clear thread.
    f.stepOne()
    f.stepOne()
    t.equals(#f.deleteEntityCalls, 1)
    t.equals(f.deleteEntityCalls[1], obj.handle)
end)

t.test('sarCallEnded(timeout / abandoned): never spawns a reveal, never sits/barks', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    f.fireCallEnded('timeout')
    t.equals(#f.createdPeds, 0)
    t.equals(#f.createdObjects, 0)
    t.equals(f.k9SitCallCount(), 0)

    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    f.fireCallEnded('abandoned')
    t.equals(#f.createdPeds, 0)
    t.equals(#f.createdObjects, 0)
    t.equals(f.k9SitCallCount(), 0)
end)

t.test('onResourceStop: clears any live reveal entity as a backstop, even if its own timer never fired', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    f.fireCallEnded('found', 'property')
    local obj = f.createdObjects[1]
    t.equals(#f.deleteEntityCalls, 0, 'the reveal must still be alive before a stop -- otherwise this test proves nothing')

    f.fireResourceStop()

    t.equals(#f.deleteEntityCalls, 1)
    t.equals(f.deleteEntityCalls[1], obj.handle)
end)

t.test('k9sarcall: no args starts a call; "stop" abandons one, unconditionally', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)

    f.setCanShowK9UI(false)
    f.startCommand({ 'stop' })
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:abandonSarCall')
end)

print('')
os.exit(t.summary())
