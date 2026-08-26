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
        RegisterCommand/RegisterNetEvent handlers and lib.callback.await.
        Synchronous (resolve-from-a-queue) by default, per
        tests/scenttrail_spec.lua's own client-section precedent -- but see
        "STALE-SESSION RACE" below: the fixture's callbackAwait stub can
        also be flipped, per test, into a genuinely coroutine-yielding one
        via setYieldingAwait, specifically so the interleaving that bug
        needed can be reproduced rather than merely asserted about in
        isolation. A second, independent thread runner drives ShowReveal's
        own on-demand auto-clear timer.

    Both sections stub math.random via a wrapper table (FakeMath), never by
    mutating the real global math table -- identical technique and
    identical reasoning to tests/scenttrail_spec.lua's own FakeMath.

    STALE-SESSION RACE (2026-08-26): this section used to carry a KNOWN,
    DISCLOSED COVERAGE GAP here admitting that the generation-token race
    RequestStartSarCall/RequestAbandonSarCall/the sarCallEnded handler guard
    against (an abandon or a server-pushed end arriving while a start's own
    lib.callback.await is still pending) was not exercised end-to-end,
    because the callbackAwait stub returned synchronously with no yield
    point for an "in the meantime" event to land inside. That gap is what
    let the actual bug through: the sarCallEnded handler bumped
    requestGeneration UNCONDITIONALLY on every push, with no way to tell a
    late echo of an already-abandoned call from a newer start already in
    flight -- exactly the interleaving a synchronous stub can never trigger.
    Closed by giving callbackAwait a genuine yielding mode (see its own
    declaration comment in SECTION 2's fixture, and the "STALE-SESSION RACE"
    tests near the end of this file, which drive it via a real
    coroutine.resume/coroutine.yield pair) plus the server-issued callId
    fix itself (client/sarcalls.lua's own header, same name) -- the race is
    now reproduced and pinned directly, not merely reasoned about.
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
local createThreadCallCount = 0
local function CreateThread(fn)
    createThreadCallCount = createThreadCallCount + 1
    threadRunner.CreateThread(fn)
end

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

-- PER-PERSON FEATURE CONTROL (IsSarCallsPermittedForCitizenId, added
-- alongside this file's own CONFIG-SAFETY GUARD rewrite) -- mirrors
-- tests/findalert_spec.lua's own permissionGrants/defaultHasPermission
-- shape, adapted to this section's SHARED-fixture convention (one
-- module-level serverEnv/ServerConfig reused and toggled across every test
-- in this section, rather than a per-test factory): `serverEnv.HasPermission`
-- is a live table field that can be set to this function or to nil between
-- tests to simulate "server/permissions.lua present" vs. "entirely absent",
-- exactly like `hasAccess` above already toggles HasK9Access's return value.
local permissionGrants = {} -- [citizenid][key] = true/false
local function HasPermission(citizenid, key)
    return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
end
local function grantPermission(citizenid, key, value)
    permissionGrants[citizenid] = permissionGrants[citizenid] or {}
    permissionGrants[citizenid][key] = value
end

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
        arrivalRadius = 2.0,
        burningDistance = 5.0,
        hotDistance = 8.0,
        warmDistance = 15.0,
        pollIntervalMs = 2000,
        maxCallDurationMs = 300000,
        startCooldownMs = 8000,
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return {
        Features = { SARCalls = true },
        SARCalls = base,
        XP = { awards = { sarCallCompleted = 30 } },
        -- Defaults OFF so every pre-existing test above keeps testing
        -- exactly what it was written to test (the config-abort/clamp
        -- behavior, the tick loop, cooldowns, ...) without also having to
        -- thread a grant through each one -- see the dedicated "PER-PERSON
        -- FEATURE CONTROL" section below for where this gets flipped true.
        FeatureControl = { RequireGrant = { SARCalls = false } },
    }
end

local ServerConfig = ServerConfigWith()

serverEnv = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    CreateThread = CreateThread,
    Wait = threadRunner.Wait,
    AddEventHandler = AddEventHandler,
    RegisterNetEvent = RegisterNetEvent,
    math = FakeMath,
    GetPlayerPed = GetPlayerPed,
    GetEntityCoords = GetEntityCoords,
    HasK9Access = HasK9Access,
    HasPermission = HasPermission,
    exports = { qbx_core = { GetPlayer = qbxGetPlayer } },
    TriggerClientEvent = TriggerClientEvent,
    TriggerEvent = TriggerEvent,
    AwardXP = AwardXP,
    NotifyPlayer = NotifyPlayer,
    lib = libStub,
    Config = ServerConfig,
})

Sandbox.loadInto('../server/cooldowns.lua', serverEnv) -- hard load-order dependency, see server/sarcalls.lua's own FILE-TO-FILE CONTRACT
Sandbox.loadInto('../server/events.lua', serverEnv) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
Sandbox.loadInto('../server/sarcalls.lua', serverEnv)

local requestSarCall = registeredCallbacks['qbx_k9unit:server:requestSarCall']

--- One tick of the production tick loop.
local function tick()
    threadRunner.step()
end

--- The LAST TriggerClientEvent call recorded for `target`, regardless of
--- what else the SAME tick may have also pushed for a different, still-
--- lingering source from an earlier test (ActiveSarCalls is one shared
--- table across this whole section, by design, matching production; a
--- test that intentionally leaves a call active -- e.g. the tier-crossing
--- test below never drives its own call to completion -- is a legitimate
--- fixture state, not a bug, so assertions key off the SOURCE they care
--- about rather than assume their own push was the globally-last one).
--- @param target number
--- @return table? call
local function lastEventFor(target)
    for i = #triggerClientEventCalls, 1, -1 do
        if triggerClientEventCalls[i].target == target then return triggerClientEventCalls[i] end
    end
    return nil
end

t.test('server load: registers requestSarCall via lib.callback and abandonSarCall via RegisterNetEvent, and starts exactly one tick thread', function()
    t.isNotNil(requestSarCall)
    t.isNotNil(registeredNetEvents['qbx_k9unit:server:abandonSarCall'])
    t.equals(createThreadCallCount, 1)
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
    -- `result` carries only `started`/`reason`/`callId`.
    t.isNil(result.targetX)
    t.isNil(result.distance)
    t.isNotNil(result.callId, 'a successful start must always return a callId -- see this file\'s header "STALE-SESSION RACE"')

    -- Immediate push: distance is exactly 10.0 (warmDistance=25 in this
    -- fixture's defaults) -> 'warm'. Also carries this call's own callId.
    local push = triggerClientEventCalls[before + 1]
    t.equals(push.event, 'qbx_k9unit:client:sarHintTierChanged')
    t.equals(push.target, 2)
    t.equals(push.args[1], 'warm')
    t.equals(push.args[2], result.callId, 'the pushed id must be the SAME id this call was granted at start')
end)

t.test('requestSarCall: each successful start mints a strictly increasing, never-reused callId', function()
    playersBySource[60] = { citizenid = 'CIT_CALLID_A', job = 'police' }
    pedCoordsBySource[60] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local first = requestSarCall(60)

    fireAbandonSarCall(60)
    playersBySource[61] = { citizenid = 'CIT_CALLID_B', job = 'police' }
    pedCoordsBySource[61] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local second = requestSarCall(61)

    t.isNotNil(first.callId)
    t.isNotNil(second.callId)
    t.isTrue(second.callId > first.callId, 'callId must strictly increase across calls, never repeat')
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
    local started = requestSarCall(20)

    local pushesSoFar = #triggerClientEventCalls

    -- Still 10m away -- same tier as the initial push ('warm') -- must NOT re-push.
    tick()
    t.equals(#triggerClientEventCalls, pushesSoFar, 'no re-push for an unchanged tier')

    -- Close in to distance 7.0 -> inside hotDistance(8), outside burningDistance(5) -> 'hot'.
    pedCoordsBySource[20] = { x = 3.0, y = 0.0, z = 0.0 } -- distance to (10,0) = 7.0
    tick()
    local hotPush = lastEventFor(20)
    t.equals(hotPush.event, 'qbx_k9unit:client:sarHintTierChanged')
    t.equals(hotPush.args[1], 'hot')
    t.equals(hotPush.args[2], started.callId, 'every hint push across the SAME call must carry that call\'s own, unchanging callId')

    -- Close further to 4.0 -> 'burning' (<=5).
    pedCoordsBySource[20] = { x = 6.0, y = 0.0, z = 0.0 } -- distance to (10,0) = 4.0
    tick()
    local burningPush = lastEventFor(20)
    t.equals(burningPush.args[1], 'burning')

    -- Clean up -- this test deliberately never drives source 20's call to
    -- completion; abandon it explicitly so it does not linger into every
    -- later test's own tick() calls once fakeNow eventually crosses this
    -- call's own maxCallDurationMs.
    fireAbandonSarCall(20)
end)

t.test('tick loop: found -- awards XP exactly once, fires the sarCallCompleted outbound event with the right payload, notifies, and pushes sarCallEnded(found, callType)', function()
    playersBySource[21] = { citizenid = 'CIT_FOUND', job = 'ambulance' }
    pedCoordsBySource[21] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0) -- target (10.0, 0.0)
    local started = requestSarCall(21)

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

    local endPush = lastEventFor(21)
    t.equals(endPush.event, 'qbx_k9unit:client:sarCallEnded')
    t.equals(endPush.args[1], 'found')
    t.equals(endPush.args[2], completedOutbound.args[4], 'callType pushed to the client must match the callType in the outbound event')
    t.equals(endPush.args[3], started.callId, 'the found push must carry THIS call\'s own callId, in its fixed 3rd position -- see this file\'s header "STALE-SESSION RACE"')

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
    local started = requestSarCall(22)

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

    local endPush = lastEventFor(22)
    t.equals(endPush.event, 'qbx_k9unit:client:sarCallEnded')
    t.equals(endPush.args[1], 'timeout')
    t.isNil(endPush.args[2], 'callType is unused for a timeout -- must be an explicit nil, not silently absent, so callId still lands in its own fixed 3rd position')
    t.equals(endPush.args[3], started.callId, 'a timeout push must still carry THIS call\'s own callId')

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
    local started = requestSarCall(23)

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
    t.equals(endPush.args[3], started.callId, 'an abandoned push must still carry THIS call\'s own callId')

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
-- PER-PERSON FEATURE CONTROL (IsSarCallsPermittedForCitizenId) --
-- config.lua's own Config.FeatureControl.RequireGrant.SARCalls entry,
-- previously dead (see server/sarcalls.lua's own header "PER-PERSON FEATURE
-- CONTROL" section for the gap this closes). Every test above this comment
-- ran (and every test below it that doesn't touch these two knobs still
-- runs) with ServerConfig.FeatureControl.RequireGrant.SARCalls defaulted to
-- false and no grants held -- see ServerConfigWith's own comment -- so this
-- is the only section that turns RequireGrant on and exercises the gate
-- explicitly. Mirrors tests/pursuitsprint_spec.lua's/tests/findalert_spec.lua's
-- own equivalent sections for the identical steps 2-4.
-- ------------------------------------------------------------------------

t.test('grant_required: RequireGrant.SARCalls = true + no grant held -- denied even though HasK9Access is true, before the cooldown is ever consumed', function()
    playersBySource[30] = { citizenid = 'CIT_GRANTREQ', job = 'police' }
    pedCoordsBySource[30] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true
    local result = requestSarCall(30)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')

    -- Cooldown must NOT have been consumed by the denied attempt -- an
    -- immediately-following request (still under startCooldownMs) for the
    -- SAME citizenid, now granted, must still succeed.
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true
    grantPermission('CIT_GRANTREQ', 'feature.SARCalls', true)
    queueRandom(0.0, 0.0)
    local retried = requestSarCall(30)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false
    t.isTrue(retried.started, 'the earlier denial must not have burned the cooldown budget')
end)

t.test('RequireGrant.SARCalls = true + an active feature.SARCalls grant -- allowed', function()
    playersBySource[31] = { citizenid = 'CIT_GRANTED', job = 'police' }
    pedCoordsBySource[31] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    grantPermission('CIT_GRANTED', 'feature.SARCalls', true)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true
    queueRandom(0.0, 0.0)
    local result = requestSarCall(31)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false
    t.isTrue(result.started)
end)

t.test('BLOCK ALWAYS WINS: an explicit block.SARCalls denies even a citizenid who ALSO holds an active feature.SARCalls grant', function()
    playersBySource[32] = { citizenid = 'CIT_BLOCKED', job = 'police' }
    pedCoordsBySource[32] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    grantPermission('CIT_BLOCKED', 'feature.SARCalls', true)
    grantPermission('CIT_BLOCKED', 'block.SARCalls', true)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true
    local result = requestSarCall(32)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
end)

t.test('BLOCK STILL APPLIES even when NOT listed in RequireGrant (step 2 fires independently of step 3)', function()
    playersBySource[33] = { citizenid = 'CIT_BLOCKED_NOGRANT', job = 'police' }
    pedCoordsBySource[33] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    grantPermission('CIT_BLOCKED_NOGRANT', 'block.SARCalls', true)
    -- RequireGrant.SARCalls is false (the shared fixture's own default) here.
    local result = requestSarCall(33)
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
end)

t.test('RequireGrant.SARCalls = false (not listed) -- default ALLOW, no grant needed, matching config.lua\'s own documented step 4', function()
    playersBySource[34] = { citizenid = 'CIT_DEFAULTALLOW', job = 'police' }
    pedCoordsBySource[34] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    -- No grant, no block, RequireGrant.SARCalls false (default) -- must
    -- still be allowed to start.
    local result = requestSarCall(34)
    t.isTrue(result.started)
end)

t.test('server/permissions.lua entirely absent (HasPermission not even defined): RequireGrant-listed feature fails CLOSED (deny), never open', function()
    playersBySource[35] = { citizenid = 'CIT_NOPERMS', job = 'police' }
    pedCoordsBySource[35] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true
    serverEnv.HasPermission = nil -- simulate server/permissions.lua not being loaded at all
    local result = requestSarCall(35)
    serverEnv.HasPermission = HasPermission
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false
    t.isFalse(result.started, 'a missing HasPermission must never fail open')
    t.equals(result.reason, 'denied')
end)

t.test('server/permissions.lua entirely absent + feature NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    playersBySource[36] = { citizenid = 'CIT_NOPERMS_ALLOW', job = 'police' }
    pedCoordsBySource[36] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    serverEnv.HasPermission = nil
    queueRandom(0.0, 0.0)
    local result = requestSarCall(36)
    serverEnv.HasPermission = HasPermission
    t.isTrue(result.started)
end)

t.test('an unresolvable citizenid is STILL denied before the permission gate is ever reached, even with RequireGrant on and access true', function()
    -- source 37 has no playersBySource entry at all -- same "transient
    -- exports.qbx_core:GetPlayer resolution miss" shape as the earlier,
    -- pre-existing unresolvable-citizenid test above, re-proven here with
    -- the permission gate active to confirm the gate did not move ahead of
    -- (or replace) the citizenid-resolution check.
    pedCoordsBySource[37] = { x = 0.0, y = 0.0, z = 0.0 }
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true
    local result = requestSarCall(37)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
end)

t.test('NO UNBOUNDED TRAP: abandonSarCall still works UNCONDITIONALLY for a caller who is currently BLOCKED -- the gate exists on the call-START path only', function()
    playersBySource[38] = { citizenid = 'CIT_BLOCKED_ABANDON', job = 'police' }
    pedCoordsBySource[38] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    -- Start the call while still allowed...
    local started = requestSarCall(38)
    t.isTrue(started.started)

    -- ...then get blocked mid-call...
    grantPermission('CIT_BLOCKED_ABANDON', 'block.SARCalls', true)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = true

    -- ...abandon must STILL succeed, exactly like the pre-existing
    -- feature-off/access-revoked abandon test above.
    local awardCountBefore = #awardCalls
    fireAbandonSarCall(38)
    ServerConfig.FeatureControl.RequireGrant.SARCalls = false

    t.equals(#awardCalls, awardCountBefore, 'abandoning must never mint XP')
    local endPush = triggerClientEventCalls[#triggerClientEventCalls]
    t.equals(endPush.event, 'qbx_k9unit:client:sarCallEnded')
    t.equals(endPush.args[1], 'abandoned')
end)

t.test('FEATURE GATE: Config.Features.SARCalls = false is a genuine no-op at load time -- no assert, no NewCooldown, no thread, no registration -- even with a garbage/absent Config.SARCalls', function()
    local registeredAnyCallback, registeredAnyNetEvent, createdAnyThread = false, false, false
    local freshEnv = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        CreateThread = function() createdAnyThread = true end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() registeredAnyNetEvent = true end,
        math = FakeMath,
        lib = { callback = { register = function() registeredAnyCallback = true end } },
        -- No Config.SARCalls at all -- exactly the "operator disabled the
        -- feature and removed the now-unused block" case this file's own
        -- FEATURE GATE comment documents finding as a real bug this pass.
        Config = { Features = { SARCalls = false } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', freshEnv)
    local ok = pcall(Sandbox.loadInto, '../server/sarcalls.lua', freshEnv)
    t.isTrue(ok, 'must not crash merely because the feature is off, even with Config.SARCalls entirely absent')
    t.isFalse(registeredAnyCallback, 'requestSarCall must never be registered while the feature is off')
    t.isFalse(registeredAnyNetEvent, 'abandonSarCall must never be registered while the feature is off')
    t.isFalse(createdAnyThread, 'the tick loop must never start while the feature is off')
end)

-- ------------------------------------------------------------------------
-- CONFIG-SAFETY GUARD -- Config.SARCalls itself missing/wrong-shaped must
-- still error LOUDLY at load time (nothing sensible to substitute for "the
-- whole block is missing"); every NUMBER inside it, once the block itself
-- is a real table, is now CLAMP AND WARN, never assert-and-abort -- see
-- the REGRESSION section below for why.
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

--- Same as loadWithBadConfig, but for the values that are meant to SURVIVE
--- rather than abort -- returns the lines the file printed while loading, so
--- a clamp-and-warn can be asserted on rather than just "it didn't crash".
--- @return string[] printedLines, boolean loaded
local function loadCapturingPrints(tuning)
    local printedLines = {}
    local freshEnv = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        CreateThread = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        math = FakeMath,
        lib = { callback = { register = function() end } },
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            printedLines[#printedLines + 1] = table.concat(parts, '\t')
        end,
        Config = { Features = { SARCalls = true }, SARCalls = tuning, XP = { awards = { sarCallCompleted = 30 } } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', freshEnv)
    local ok = pcall(Sandbox.loadInto, '../server/sarcalls.lua', freshEnv)
    return printedLines, ok
end

--- Same idea as loadCapturingPrints, but building a FULLY FUNCTIONAL,
--- independent sandbox (own tick thread, own captured requestSarCall
--- callback/abandonSarCall net event, own player/ped/coords stubs) -- so a
--- clamp-and-warn can be proven both at the REGISTRATION level ("every
--- entry point the old assert used to strand still exists") and, for at
--- least one field per group, at the FUNCTIONAL level ("the resolved,
--- possibly-clamped values are what the real running feature actually
--- enforces", not merely printed in a warning).
--- @param tuning table
--- @return table fixture
local function newCapturingFixture(tuning)
    local printedLines = {}
    local threadCreated = false
    local runner = Sandbox.newThreadRunner()
    local registeredCallback, registeredNetEvent
    local pedCoords, players = {}, {}
    local clientEvents = {}
    local env

    -- Named distinctly from this file's own SECTION 1 module-level
    -- GetPlayerPed/GetEntityCoords/qbxGetPlayer (declared far above, around
    -- line 123) to avoid shadowing them -- this fixture is fully
    -- self-contained (its own pedCoords/players tables), never reads or
    -- writes SECTION 1's state, but a shadowed name in the same file is a
    -- needless luacheck warning and a trap for a future reader skimming for
    -- "which stub does this actually use".
    local function fixtureGetPlayerPed(source) return source end -- identity, same convention as this file's own SECTION 1 fixture
    local function fixtureGetEntityCoords(ped) return pedCoords[ped] or { x = 0, y = 0, z = 0 } end
    local function fixtureQbxGetPlayer(_self, src)
        local rec = players[src]
        if not rec then return nil end
        return { PlayerData = { citizenid = rec.citizenid, job = { name = rec.job } } }
    end

    env = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        CreateThread = function(fn) threadCreated = true; runner.CreateThread(fn) end,
        Wait = runner.Wait,
        AddEventHandler = function() end,
        RegisterNetEvent = function(_name, fn) registeredNetEvent = fn end,
        math = FakeMath,
        lib = { callback = { register = function(_name, fn) registeredCallback = fn end } },
        HasK9Access = function() return true end,
        GetPlayerPed = fixtureGetPlayerPed,
        GetEntityCoords = fixtureGetEntityCoords,
        exports = { qbx_core = { GetPlayer = fixtureQbxGetPlayer } },
        TriggerClientEvent = function(eventName, target, ...)
            clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
        end,
        TriggerEvent = function() end,
        AwardXP = function() end,
        NotifyPlayer = function() end,
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            printedLines[#printedLines + 1] = table.concat(parts, '\t')
        end,
        Config = { Features = { SARCalls = true }, SARCalls = tuning, XP = { awards = { sarCallCompleted = 30 } } },
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, needed once requestSarCall is actually dispatched below
    local ok = pcall(Sandbox.loadInto, '../server/sarcalls.lua', env)

    return {
        printedLines = printedLines,
        loaded = ok,
        threadCreated = threadCreated,
        hasRequestCallback = registeredCallback ~= nil,
        hasAbandonNetEvent = registeredNetEvent ~= nil,
        requestSarCall = function(src) return registeredCallback(src) end,
        tick = runner.step,
        setPedCoords = function(src, x, y, z) pedCoords[src] = { x = x, y = y, z = z } end,
        registerPlayer = function(src, citizenid, job) players[src] = { citizenid = citizenid, job = job } end,
        lastClientEventFor = function(target)
            for i = #clientEvents, 1, -1 do
                if clientEvents[i].target == target then return clientEvents[i] end
            end
            return nil
        end,
    }
end

t.test('CONFIG-SAFETY GUARD: Config.SARCalls missing entirely errors, naming Config.SARCalls', function()
    local err = loadWithBadConfig(nil)
    t.isNotNil(err)
    t.contains(err, 'Config.SARCalls')
end)

-- ------------------------------------------------------------------
-- REGRESSION (2026-08-26): every test below this comment, through the
-- pre-existing startCooldownMs REGRESSION section, used to assert the
-- OPPOSITE for minRadius/maxRadius/arrivalRadius/burningDistance/
-- hotDistance/warmDistance/pollIntervalMs/maxCallDurationMs -- that a bad
-- value aborted this file's load via a hard `assert`, naming the offending
-- field. They were pinning the bug: an uncaught error thrown from THIS
-- FILE's own top-level chunk aborts server/sarcalls.lua's load from that
-- line onward -- silently un-registering the playerDropped handler, the
-- tick loop, the requestSarCall callback, and the UNCONDITIONAL
-- abandonSarCall event this file's own header calls a "NO UNBOUNDED TRAP"
-- guarantee, over one operator typo. startCooldownMs was migrated first
-- (see below); these eight siblings sat right above it, unmigrated, only
-- because none of them feed NewCooldown -- not because the risk differed.
--
-- minRadius/maxRadius and arrivalRadius/burningDistance/hotDistance/
-- warmDistance are RELATIONSHIPS, not independent values (see server/
-- sarcalls.lua's own updated CONFIG-SAFETY GUARD comment) -- an invalid
-- group falls back to its WHOLE shipped default set together, never a mix
-- of kept-and-substituted values that could still be incoherent.
-- pollIntervalMs/maxCallDurationMs have no relationship to any other field
-- and are resolved independently via ResolveConfiguredThresholdMs.
-- ------------------------------------------------------------------

t.test('REGRESSION: an invalid minRadius/maxRadius pair no longer aborts this file\'s load -- BOTH fields fall back to the shipped defaults (40.0/90.0) together, warning names both keys/values, and every registration below the old assert survives', function()
    local f = newCapturingFixture({
        minRadius = 0, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded, 'the file must still load -- an abort here kills the whole SAR-calls feature')
    t.isTrue(f.threadCreated, 'the tick loop must still be created')
    t.isTrue(f.hasRequestCallback, 'requestSarCall must still be registered')
    t.isTrue(f.hasAbandonNetEvent, 'the UNCONDITIONAL abandonSarCall event must still be registered')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.SARCalls.minRadius/maxRadius', 1, true)
            and line:find('minRadius=0', 1, true) and line:find('maxRadius=30', 1, true)
            and line:find('40.0', 1, true) and line:find('90.0', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name both keys, the bad values found, and both fallbacks substituted -- clamping only one field into an incoherent pair is exactly what this must NOT do')

    -- Prove it at the level the bug lives: dispatch a real requestSarCall
    -- and confirm the feature is genuinely functional on the substituted
    -- (coherent) default pair, not merely that loading survived.
    f.registerPlayer(1, 'CIT_1', 'police')
    f.setPedCoords(1, 0.0, 0.0, 0.0)
    queueRandom(0.0, 0.0) -- radius fraction 0.0 -> exactly the fallback minRadius (40.0)
    local result = f.requestSarCall(1)
    t.isTrue(result.started, 'the feature must still be able to start a call on the substituted default pair')
    local push = f.lastClientEventFor(1)
    t.equals(push.event, 'qbx_k9unit:client:sarHintTierChanged', 'the immediate hint push must still fire')
end)

t.test('REGRESSION: maxRadius < minRadius also falls back to the whole GROUP 1 default pair, never just clamping maxRadius up to minRadius (which would still be an operator-unintended number)', function()
    local f = newCapturingFixture({
        minRadius = 30, maxRadius = 10, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('minRadius=30', 1, true) and line:find('maxRadius=10', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)
    t.isTrue(f.hasRequestCallback)
end)

t.test('REGRESSION: a VALID minRadius/maxRadius pair is still used, not silently replaced by the group fallback', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('minRadius', 1, true), 'a valid configured minRadius/maxRadius pair must pass through silently -- warning on a good value trains operators to ignore the warning')
    end
end)

t.test('REGRESSION: an invalid arrivalRadius no longer aborts this file\'s load -- ALL FOUR of GROUP 2 fall back together (6.0/8.0/20.0/45.0), warning names every key/value, and every registration survives', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 0, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    t.isTrue(f.threadCreated)
    t.isTrue(f.hasRequestCallback)
    t.isTrue(f.hasAbandonNetEvent)
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('arrivalRadius=0', 1, true) and line:find('6.0', 1, true) and line:find('8.0', 1, true)
            and line:find('20.0', 1, true) and line:find('45.0', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)
end)

t.test('REGRESSION: burningDistance <= arrivalRadius no longer aborts this file\'s load -- falls back to the whole GROUP 2 default chain together', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 5, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('burningDistance=5', 1, true) then warned = true end
    end
    t.isTrue(warned)
    t.isTrue(f.hasRequestCallback)
end)

t.test('REGRESSION: hotDistance out of order (<= burningDistance) also falls back to the whole GROUP 2 default chain', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 15, hotDistance = 10,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('hotDistance=10', 1, true) then warned = true end
    end
    t.isTrue(warned)
    t.isTrue(f.hasRequestCallback)
end)

t.test('REGRESSION: warmDistance out of order (<= hotDistance) also falls back to the whole GROUP 2 default chain', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 10, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('warmDistance=10', 1, true) then warned = true end
    end
    t.isTrue(warned)
    t.isTrue(f.hasRequestCallback)
end)

t.test('REGRESSION: a VALID arrivalRadius/burningDistance/hotDistance/warmDistance chain is still used, not silently replaced by the group fallback', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('arrivalRadius', 1, true), 'a valid configured GROUP 2 chain must pass through silently')
    end
end)

t.test('REGRESSION: pollIntervalMs = 0 no longer aborts this file\'s load -- clamps to the shipped 2000ms fallback, warns loudly, and the tick loop keeps genuinely running', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 0, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded, 'the file must still load -- an abort here kills the whole SAR-calls feature')
    t.isTrue(f.threadCreated)

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.SARCalls.pollIntervalMs', 1, true) and line:find('found: 0', 1, true) and line:find('2000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')

    -- Prove the tick loop still genuinely runs: start a call, walk to
    -- within arrivalRadius, tick, and confirm 'found' fires end-to-end.
    f.registerPlayer(2, 'CIT_2', 'police')
    f.setPedCoords(2, 0.0, 0.0, 0.0)
    queueRandom(0.0, 0.0) -- target lands at (minRadius, 0) = (10, 0)
    f.requestSarCall(2)
    f.setPedCoords(2, 10.0, 0.0, 0.0) -- walk exactly onto the target, well within arrivalRadius (3.0)
    f.tick() -- prime
    f.tick() -- one real pass
    local ev = f.lastClientEventFor(2)
    t.equals(ev.event, 'qbx_k9unit:client:sarCallEnded', 'the tick loop must still detect arrival and end the call after pollIntervalMs was clamped')
    t.equals(ev.args[1], 'found')
end)

t.test('REGRESSION: maxCallDurationMs = 0 no longer aborts this file\'s load -- clamps to the shipped 480000ms fallback and warns loudly', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 0, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded, 'the file must still load -- an abort here kills the whole SAR-calls feature')
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.SARCalls.maxCallDurationMs', 1, true) and line:find('found: 0', 1, true) and line:find('480000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)
    t.isTrue(f.hasRequestCallback)
end)

t.test('REGRESSION: a VALID pollIntervalMs/maxCallDurationMs are each still used, not silently replaced by their fallbacks', function()
    local f = newCapturingFixture({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 8000,
    })
    t.isTrue(f.loaded)
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('pollIntervalMs', 1, true), 'a valid configured pollIntervalMs must pass through silently')
        t.isNil(line:find('maxCallDurationMs', 1, true), 'a valid configured maxCallDurationMs must pass through silently')
    end
end)

-- ------------------------------------------------------------------
-- REGRESSION (2026-08-26): this test used to assert the OPPOSITE -- that
-- startCooldownMs = 0 aborts this file's load via NewCooldown's own
-- constructor guard. It was pinning the bug.
--
-- The CONFIG-SAFETY GUARD block above deliberately validates only the
-- fields it names, and startCooldownMs was never one of them, so the raw
-- value reached NewCooldown(0), which errors at file-load time and takes
-- the whole SAR-calls feature down with it. 0 is the single most natural
-- thing an operator types for "no cooldown".
--
-- Now routed through ResolveConfiguredThresholdMs like every other
-- configured-threshold site: clamp, warn loudly, stay alive.
-- ------------------------------------------------------------------

t.test('REGRESSION: startCooldownMs = 0 no longer aborts this file\'s load -- clamps to the shipped 600000ms fallback and warns loudly, naming the exact key', function()
    local printedLines, loaded = loadCapturingPrints({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 0,
    })
    t.isTrue(loaded, 'the file must still load -- an abort here kills the whole SAR-calls feature')

    local warned = false
    for _, line in ipairs(printedLines) do
        if line:find('Config.SARCalls.startCooldownMs', 1, true) and line:find('600000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key and the fallback substituted -- the operator still has to find out')
end)

t.test('REGRESSION: startCooldownMs = NaN also no longer aborts this file\'s load', function()
    local _, loaded = loadCapturingPrints({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 0 / 0,
    })
    t.isTrue(loaded)
end)

t.test('REGRESSION: a VALID startCooldownMs is still used, not silently replaced by the fallback', function()
    local printedLines, loaded = loadCapturingPrints({
        minRadius = 10, maxRadius = 30, arrivalRadius = 3, burningDistance = 5, hotDistance = 15,
        warmDistance = 25, pollIntervalMs = 2000, maxCallDurationMs = 300000, startCooldownMs = 777,
    })
    t.isTrue(loaded)
    for _, line in ipairs(printedLines) do
        t.isNil(line:find('startCooldownMs', 1, true),
            'a valid configured value must pass through silently -- warning on a good value trains operators to ignore the warning')
    end
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
    -- STALE-SESSION RACE fixtures (see below) need this await to genuinely
    -- SUSPEND mid-round-trip so a test can inject other events while it is
    -- pending, exactly the interleaving a plain synchronous stub can never
    -- exercise -- see this file's own header KNOWN, DISCLOSED COVERAGE GAP
    -- for why that gap existed, and the race tests below for how this
    -- closes it. Off by default (every pre-existing test above keeps its
    -- own synchronous, single-call round trip unchanged); a test that needs
    -- the real interleaving flips it on via setYieldingAwait and drives the
    -- resulting coroutine itself.
    local awaitShouldYield = false
    local function callbackAwait(eventName, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        if awaitShouldYield then
            return coroutine.yield(eventName)
        end
        return table.remove(callbackResponses, 1)
    end

    local clientNotifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) clientNotifyCalls[#clientNotifyCalls + 1] = payload end,
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

    -- CLAMP-AND-WARN CAPTURE -- proves the guard actually warns (not just
    -- "doesn't crash") without spamming real stdout during the test run.
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local overrides = {
        print = printStub,
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
        printLog = printLog,
        stepOne = runner.step,
        notifyCalls = clientNotifyCalls,
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
        --- See callbackAwait's own declaration comment above -- flips this
        --- fixture's lib.callback.await stub from "resolve synchronously
        --- from the queue" to "suspend the calling coroutine until resumed
        --- with the response", for STALE-SESSION RACE tests that need to
        --- inject other events while a start is genuinely still pending.
        setYieldingAwait = function(v) awaitShouldYield = v end,
        --- Fires every captured onResourceStop handler as if THIS resource
        --- were genuinely stopping (resourceName == 'qbx_k9unit', matching
        --- the fixture's own GetCurrentResourceName() stub).
        fireResourceStop = function()
            for _, handler in ipairs(resourceStopHandlers) do handler('qbx_k9unit') end
        end,
        --- Fires a pushed hint-tier event as if it genuinely came from the
        --- server (source == 65535) unless `forged` is true. `callId`
        --- (added for STALE-SESSION RACE) defaults to nil (no id) when
        --- omitted, matching every pre-existing call site above this
        --- comment -- see this file's own IsForCurrentSarCall for why a
        --- missing id is always accepted regardless.
        fireHintTier = function(tier, forged, callId)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:sarHintTierChanged'](tier, callId)
        end,
        --- Fires a pushed call-ended event, same forgery-modeling shape.
        --- `callId` (added for STALE-SESSION RACE) is the LAST parameter,
        --- deliberately, so every pre-existing 2- and 3-argument call site
        --- above this comment (`forged` as the 3rd positional argument)
        --- keeps meaning exactly what it always meant.
        fireCallEnded = function(reason, callType, forged, callId)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:sarCallEnded'](reason, callType, callId)
        end,
    }
end

-- REGRESSION (this pass): these two tests used to assert the OPPOSITE --
-- that a missing/invalid field on the CLIENT side FAILED THE ENTIRE FILE'S
-- LOAD via a hard `assert` sitting directly after client/sarcalls.lua's
-- feature-flag early-return, with no deferring onResourceStart/
-- RegisterNetEvent wrapper. See server/cooldowns.lua's header ADDENDUM:
-- an uncaught error there would silently un-register every SAR-call net
-- event/callback handler this file defines, over one operator typo in a
-- cosmetic model name or a duration. Now CLAMP AND WARN.
t.test('CLAMP AND WARN (client): a missing missingPersonPedModel no longer errors at load time -- warns loudly and falls back to the shipped default', function()
    local f = newClientFixture({ badConfig = { lostPropertyPropModel = 'prop_tennis_ball', revealDurationMs = 1000 } })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.SARCalls.missingPersonPedModel', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact key')
    t.equals(f.env.Config.SARCalls.missingPersonPedModel, 'mp_m_freemode_01')
end)

t.test('CLAMP AND WARN (client): a non-positive revealDurationMs no longer errors at load time -- warns loudly and falls back to the shipped 15000ms default', function()
    local f = newClientFixture({ badConfig = {
        missingPersonPedModel = 'mp_m_freemode_01', lostPropertyPropModel = 'prop_tennis_ball', revealDurationMs = 0,
    } })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.SARCalls.revealDurationMs', 1, true) and line:find('found: 0', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact key and the value found')
    t.equals(f.env.Config.SARCalls.revealDurationMs, 15000)
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

-- ------------------------------------------------------------------
-- STALE-REVEAL GUARD -- BUG (found + fixed this pass): ShowReveal()'s own
-- LoadModelWithTimeout call can YIELD (its Wait(50) polling loop) before
-- CreatePed/CreateObject ever runs. If a SECOND, genuinely NEWER
-- sarCallEnded('found') push (this client finishing one call, immediately
-- starting and completing another before the FIRST reveal's own model ever
-- finished loading) ran its own ClearReveal() + creation sequence to
-- completion WHILE the first attempt was still stuck waiting on its model,
-- the first attempt's own unconditional `revealEntity = newEntity`
-- assignment (once its model finally loaded) would silently overwrite the
-- second, now-current attempt's entity -- orphaned, since nothing would
-- hold its handle again. Same bug class, and the same fix (a generation
-- check before the assignment, reusing this function's own pre-existing
-- generation counter), as client/vision.lua's own "STALE-CAM GUARD" on
-- ToggleCameraFeed and client/kennel.lua's own "STALE-KENNEL GUARD" on
-- deployKennelAt.
-- ------------------------------------------------------------------

t.test('BUG (found + fixed this pass): a second sarCallEnded("found") for a genuinely NEWER call, completing while the FIRST reveal\'s own model load is still in flight, does not overwrite/orphan the second reveal once the first finally resolves', function()
    local f = newClientFixture()

    -- HasModelLoaded reports "still loading" on its very first ever poll
    -- (forcing exactly one Wait(50) yield inside call A's own
    -- LoadModelWithTimeout), then "loaded" for every poll after that --
    -- including every poll call B ever makes, so B resolves synchronously.
    local pollCount = 0
    f.env.HasModelLoaded = function(_modelHash)
        pollCount = pollCount + 1
        return pollCount > 1
    end

    -- Call A: starts and "finds" a person. Suspends mid-flight inside its
    -- own model-load wait, BEFORE it has created anything (CreatePed only
    -- runs after LoadModelWithTimeout returns).
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    local coA = coroutine.create(function() f.fireCallEnded('found', 'person') end)
    local okA, errA = coroutine.resume(coA)
    assert(okA, 'coroutine A errored before its first yield: ' .. tostring(errA))
    assert(coroutine.status(coA) == 'suspended', 'expected A to be mid-flight inside its own LoadModelWithTimeout Wait(50) poll, not already finished -- if this fails, the HasModelLoaded stub above is wrong, not the production code')
    t.equals(#f.createdPeds, 0, 'A must not have created its reveal ped yet -- it is still waiting on its own model')

    -- Call B: a genuinely NEWER, independent call this SAME client starts
    -- and finishes completely (property found) WHILE A is still stuck --
    -- sarCallActive/currentSarCallId are already reset by A's own handler
    -- (both assignments happen BEFORE ShowReveal() is ever called), so this
    -- is a legitimate second call, not a rejected re-entrant one.
    f.queueCallbackResponse({ started = true })
    f.env.RequestStartSarCall()
    f.fireCallEnded('found', 'property')
    t.equals(#f.createdObjects, 1, 'B must have created its own reveal object, fully synchronously')
    local bEntity = f.createdObjects[1].handle

    -- Drain A to completion -- its own model has "loaded" by now (every
    -- poll from the second one onward reports true).
    while coroutine.status(coA) ~= 'dead' do
        local ok, err = coroutine.resume(coA)
        assert(ok, 'coroutine A errored mid-flight: ' .. tostring(err))
    end
    t.equals(#f.createdPeds, 1, 'A did eventually create its own (now-stale) reveal ped')
    local aEntity = f.createdPeds[1].handle

    t.equals(#f.deleteEntityCalls, 1, 'FIXED: the STALE-REVEAL GUARD deletes A\'s own now-stale ped the instant it finishes, rather than assigning it into revealEntity and orphaning B\'s still-live object')
    t.equals(f.deleteEntityCalls[1], aEntity, 'the entity deleted by the guard is A\'s OWN stale ped, not B\'s object')

    -- Proves revealEntity still correctly tracks B's object, not A's stale
    -- ped: onResourceStop's own ClearReveal() must delete B's entity next,
    -- and must never re-touch A's already-deleted one.
    f.fireResourceStop()
    t.equals(#f.deleteEntityCalls, 2, 'onResourceStop cleans up B\'s still-live reveal object too')
    t.equals(f.deleteEntityCalls[2], bEntity, 'the second delete call targets B\'s object, confirming revealEntity correctly tracked the current (newer) reveal throughout, not the orphaned first one')
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

-- ------------------------------------------------------------------------
-- STALE-SESSION RACE (client/sarcalls.lua's own header section by this
-- exact name) -- pins the actual interleaving, not just the id-matching
-- logic in isolation: this section's own callbackAwait stub (see
-- newClientFixture's own declaration comment on `awaitShouldYield`)
-- genuinely SUSPENDS the calling coroutine mid-round-trip so a stale push
-- can be injected while a start is still pending, the exact ordering the
-- real bug required and this file's own header KNOWN, DISCLOSED COVERAGE
-- GAP used to admit this suite could not exercise.
-- ------------------------------------------------------------------------

t.test('STALE-SESSION RACE: an old call\'s late "abandoned" echo arriving WHILE a new start is still pending must not swallow that new start\'s own grant -- the new call must still receive hint tiers', function()
    local f = newClientFixture()

    -- Call A: started and genuinely active, with its own real callId.
    f.queueCallbackResponse({ started = true, callId = 5 })
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), 1)

    -- Abandon call A, then IMMEDIATELY start call B -- the exact sequence
    -- the bug report describes. RequestAbandonSarCall() never awaits
    -- anything itself, so no coroutine is needed for this step.
    f.env.RequestAbandonSarCall()

    -- Call B's own start now genuinely suspends mid-round-trip.
    f.setYieldingAwait(true)
    local co = coroutine.create(function() f.env.RequestStartSarCall() end)
    local ok, awaitedEvent = coroutine.resume(co)
    t.isTrue(ok, 'the coroutine must not error merely by reaching the await')
    t.equals(awaitedEvent, 'qbx_k9unit:server:requestSarCall')
    t.equals(coroutine.status(co), 'suspended', 'call B\'s own start must genuinely still be pending at this point -- otherwise this test proves nothing')
    t.equals(f.callbackCallCount(), 2, 'call B must have already sent its own requestSarCall round trip')

    -- NOW, while call B's own grant is still in flight, call A's late
    -- server-side echo of the abandon finally lands -- carrying call A's
    -- OWN id (5), which this client already forgot the instant it called
    -- RequestAbandonSarCall() above (see currentSarCallId's own declaration
    -- comment in client/sarcalls.lua).
    f.fireCallEnded('abandoned', nil, false, 5)

    -- Call B's grant finally arrives, with call B's own, genuinely
    -- different, id (6).
    coroutine.resume(co, { started = true, callId = 6 })
    t.equals(coroutine.status(co), 'dead', 'call B\'s own RequestStartSarCall() must have run to completion')

    -- THE REGRESSION ASSERTION: call B must be genuinely active and must
    -- still receive its own hint-tier pushes -- pre-fix, call A's stale
    -- echo would have bumped requestGeneration while call B's await was
    -- pending, so call B's own successful grant would have been discarded
    -- as stale and sarCallActive would have stuck false, silently dropping
    -- every hint notification below.
    f.fireHintTier('warm', false, 6)
    t.equals(#f.notifyCalls, 1, 'call B must still receive its own hint-tier notifications -- this is exactly what the bug silently dropped')
    t.contains(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_warm'))

    -- A second start attempt must be rejected as already_active (no new
    -- round trip) -- proving sarCallActive is genuinely true for call B,
    -- not merely that one notify slipped through by coincidence.
    local callbackCountBefore = f.callbackCallCount()
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), callbackCountBefore, 'call B must read as active locally -- no new server round trip')
end)

t.test('STALE-SESSION RACE: a stale hint-tier push for an OLD call (wrong callId) must never be applied to a DIFFERENT, currently-active call', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true, callId = 100 })
    f.env.RequestStartSarCall()

    -- A push carrying a DIFFERENT, non-matching id must be ignored entirely.
    f.fireHintTier('burning', false, 999)
    t.equals(#f.notifyCalls, 0, 'a mismatched callId must be dropped, even while a call is genuinely active')
    t.equals(#f.playK9SoundCalls, 0)

    -- The genuinely-current call's own id must still work normally.
    f.fireHintTier('burning', false, 100)
    t.equals(#f.notifyCalls, 1)
end)

t.test('STALE-SESSION RACE: a push with NO callId at all is always accepted, never silently dropped, even while a differently-numbered call is active', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true, callId = 42 })
    f.env.RequestStartSarCall()

    -- No callId argument at all (nil) -- must still be treated as genuine,
    -- per this file's own deliberate "never silently drop an unlabeled
    -- push" decision (see IsForCurrentSarCall's own declaration comment).
    f.fireHintTier('hot')
    t.equals(#f.notifyCalls, 1, 'a push with no id must never be silently dropped')
end)

t.test('STALE-SESSION RACE: RequestAbandonSarCall remains UNCONDITIONAL even with a stale/mismatched currentSarCallId in play -- no unbounded trap', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true, callId = 7 })
    f.env.RequestStartSarCall()

    -- Abandon never reads, sends, or needs any callId at all -- it must
    -- succeed exactly the same regardless of whatever this client's own
    -- currentSarCallId currently holds.
    f.env.RequestAbandonSarCall()
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:abandonSarCall')

    -- Local state must genuinely be clear: a fresh start must reach the
    -- server again rather than being rejected as already_active.
    f.queueCallbackResponse({ started = true, callId = 8 })
    local before = f.callbackCallCount()
    f.env.RequestStartSarCall()
    t.equals(f.callbackCallCount(), before + 1)
end)

print('')
os.exit(t.summary())
