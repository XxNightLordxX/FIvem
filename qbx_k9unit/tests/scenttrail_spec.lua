--[[
    tests/scenttrail_spec.lua

    Covers BOTH halves of "Follow your nose" (K9_IDEAS.md §2) in one file,
    per this task's own file-ownership constraint (only ONE new spec file
    is permitted for this feature). Two independent sandboxes, one per
    file, following this suite's own established per-feature-file
    conventions rather than inventing a third shape:
      SECTION 1 (server/scenttrail.lua) -- mirrors search_spec.lua's own
        pattern: a hand-built minimal Config table (not the real
        config.lua), server/cooldowns.lua loaded for real ahead of it
        (a hard load-order dependency, same as production), lib.callback.register
        captured into a table and invoked directly.
      SECTION 2 (client/scenttrail.lua) -- mirrors clienttracking_spec.lua's
        own pattern: a real, unmodified file loaded into a sandbox via
        Sandbox.loadInto, driven only through captured RegisterCommand/
        RegisterNetEvent handlers and lib.callback.await, using an
        instrumented coroutine-based thread runner to step the poll loop
        one iteration at a time.

    Both sections stub math.random directly (a real, process-global table
    reference -- Sandbox.newEnv's shallow copy of _G shares the SAME `math`
    table object, so overriding math.random here affects both the
    production chunk under test and this spec file equally, for the
    lifetime of this one os.exit()-ing process; see tests/run.sh's own
    header for why that never leaks into another spec file's separate
    process) so RollHuntTarget's/IntervalForDistance's otherwise-random
    inputs become deterministic and assertable.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Shared: a controllable math.random queue, fed to server/scenttrail.lua's
-- RollHuntTarget via a WRAPPER table (FakeMath below), never by mutating
-- the real global `math` table directly -- Sandbox.newEnv's shallow copy of
-- _G shares that single table object with this spec's own process-global
-- `math`, so writing `math.random = ...` would silently patch the real
-- standard library for the rest of this file too (harmless in a single
-- os.exit()-ing process, per tests/run.sh's own per-file-process design,
-- but still a real global mutation luacheck rightly flags as a smell
-- worth avoiding when a same-shaped alternative costs nothing). FakeMath
-- delegates every OTHER math.* call (sqrt/cos/sin/pi/max/min, all used by
-- the two production files under test) straight through to the real
-- table via __index, so it is a drop-in replacement for `env.math`, not a
-- partial one.
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
-- SECTION 1 -- server/scenttrail.lua
-- ========================================================================

local fakeNow = 0
local function GetGameTimer() return fakeNow end

-- Forward-declared: server/scenttrail.lua's playerDropped/stopScentHunt
-- handlers both read the AMBIENT `source` global (this resource's own
-- established convention for these two FiveM event shapes, e.g.
-- server/cooldowns.lua's own :RegisterPlayerDropped() closures --
-- `function() tracker.Clear(source) end`, no parameter at all), never a
-- parameter -- so firing one of them in this sandbox means setting
-- `serverEnv.source` first, then invoking the captured handler with NO
-- arguments, exactly mirroring how FXServer itself sets that ambient
-- global before dispatching either event. Forward-declared because these
-- two helpers are defined before `serverEnv` itself (built further below).
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
local registeredNetEvents = {}
local function RegisterNetEvent(eventName, handler)
    registeredNetEvents[eventName] = handler
end

--- Fires the captured stopScentHunt net-event handler as if
--- TriggerServerEvent('qbx_k9unit:server:stopScentHunt') had genuinely
--- arrived from `stopSource` -- see the forward-declaration comment above
--- for why this must set the ambient `source` global rather than pass an
--- argument the real handler never reads.
--- @param stopSource number
local function fireStopScentHunt(stopSource)
    serverEnv.source = stopSource
    registeredNetEvents['qbx_k9unit:server:stopScentHunt']()
end
local libStub = {
    callback = {
        register = function(name, handler) registeredCallbacks[name] = handler end,
    },
}

local pedCoordsBySource = {}
local function GetPlayerPed(source) return source end -- identity: this section's fake ped handle IS the source
local function GetEntityCoords(ped) return pedCoordsBySource[ped] or { x = 0, y = 0, z = 0 } end

local hasAccess = true
local function HasK9Access(_source) return hasAccess end

local triggerClientEventCalls = {}
local function TriggerClientEvent(eventName, target, ...)
    triggerClientEventCalls[#triggerClientEventCalls + 1] = { event = eventName, target = target, args = { ... } }
end

local ServerConfig = {
    Features = { ScentTrailHunt = true },
    ScentTrailHunt = {
        minRadius = 10.0,
        maxRadius = 30.0,
        arrivalRadius = 3.0,
        startCooldownMs = 8000,
        maxHuntDurationMs = 300000,
    },
}

serverEnv = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    RegisterNetEvent = RegisterNetEvent, -- must be provided BEFORE loadInto -- server/scenttrail.lua calls this at file-load time for stopScentHunt, and the real global does not exist in this plain lua5.4 process
    math = FakeMath, -- see FakeMath's own declaration comment: RollHuntTarget's math.random() calls resolve against this wrapper, not the real global table
    GetPlayerPed = GetPlayerPed,
    GetEntityCoords = GetEntityCoords,
    HasK9Access = HasK9Access,
    TriggerClientEvent = TriggerClientEvent,
    lib = libStub,
    Config = ServerConfig,
})

Sandbox.loadInto('../server/cooldowns.lua', serverEnv) -- hard load-order dependency, see server/scenttrail.lua's own FILE-TO-FILE CONTRACT
Sandbox.loadInto('../server/scenttrail.lua', serverEnv)

local startScentHunt = registeredCallbacks['qbx_k9unit:server:startScentHunt']
local pollScentHunt = registeredCallbacks['qbx_k9unit:server:pollScentHunt']

t.test('server/scenttrail.lua registers both lib.callback handlers and the stopScentHunt net event at load time', function()
    t.isNotNil(startScentHunt)
    t.isNotNil(pollScentHunt)
    t.isNotNil(registeredNetEvents['qbx_k9unit:server:stopScentHunt'])
end)

t.test('startScentHunt: Config.Features.ScentTrailHunt off is a real no-op (reason = denied), even with access', function()
    ServerConfig.Features.ScentTrailHunt = false
    local result = startScentHunt(1)
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
    ServerConfig.Features.ScentTrailHunt = true
end)

t.test('startScentHunt: HasK9Access() false is a real no-op (reason = denied)', function()
    hasAccess = false
    local result = startScentHunt(1)
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
    hasAccess = true
end)

t.test('startScentHunt: success rolls a target from the CALLER\'S OWN live server-side coords, never a client-supplied one', function()
    pedCoordsBySource[2] = { x = 100.0, y = 200.0, z = 0.0 }
    queueRandom(0.0, 0.0) -- radius fraction 0.0 -> exactly minRadius (10.0); angle fraction 0.0 -> angle 0 -> cos=1, sin=0
    local result = startScentHunt(2)
    t.isTrue(result.started)
    t.isNil(result.reason)

    -- The target is never returned to the caller at all -- see this file's
    -- header "WHY THE COORDINATE NEVER LEAVES THIS FILE". Confirmed
    -- structurally: `result` carries only `started`/`reason`.
    t.isNil(result.distance)

    -- Poll immediately (fakeNow unchanged) to observe the distance the
    -- rolled target actually produces, proving it was derived from source
    -- 2's OWN coords (100, 200), not some other value.
    fakeNow = fakeNow + 1000 -- clear the poll-rate floor
    local poll = pollScentHunt(2)
    t.isTrue(poll.active)
    -- origin (100,200) + radius 10 at angle 0 -> target (110, 200); caller
    -- has not moved, so live distance back to that target is exactly 10.
    t.equals(poll.distance, 10.0)
end)

t.test('startScentHunt: a second call for the SAME source while unfinished is rejected as already_active, with no new roll', function()
    pedCoordsBySource[3] = { x = 0.0, y = 0.0, z = 0.0 }
    queueRandom(0.0, 0.0)
    local first = startScentHunt(3)
    t.isTrue(first.started)

    fakeNow = fakeNow + 20000 -- clear the start cooldown so this failure is ONLY the already_active check, not cooldown
    local second = startScentHunt(3)
    t.isFalse(second.started)
    t.equals(second.reason, 'already_active')
end)

t.test('startScentHunt: on cooldown (reason = cooldown) rejects a second start for a DIFFERENT source too soon after its first', function()
    pedCoordsBySource[4] = { x = 0.0, y = 0.0, z = 0.0 }
    queueRandom(0.0, 0.0)
    local first = startScentHunt(4)
    t.isTrue(first.started)

    -- Abandon the first hunt (stopScentHunt) so the SECOND call's rejection
    -- is unambiguously the cooldown, not already_active.
    fireStopScentHunt(4)

    local second = startScentHunt(4) -- fakeNow has NOT advanced past startCooldownMs (8000)
    t.isFalse(second.started)
    t.equals(second.reason, 'cooldown')
end)

t.test('stopScentHunt: unconditional -- clears an active hunt with no Config/HasK9Access check, and is a harmless no-op with nothing active', function()
    pedCoordsBySource[5] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    startScentHunt(5)

    ServerConfig.Features.ScentTrailHunt = false -- feature disabled...
    hasAccess = false -- ...and access revoked...
    fireStopScentHunt(5) -- ...stop must still work
    ServerConfig.Features.ScentTrailHunt = true
    hasAccess = true

    fakeNow = fakeNow + 1000
    local poll = pollScentHunt(5)
    t.isFalse(poll.active, 'the hunt must actually be gone -- stop was never gated')

    -- No-op on a source with nothing active: must not error.
    fireStopScentHunt(999)
end)

t.test('pollScentHunt: fires qbx_k9unit:client:scentHuntFound to THIS caller only, exactly once, the first time distance drops to/under arrivalRadius', function()
    pedCoordsBySource[6] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0) -- target lands at (10, 0) -- exactly minRadius away
    startScentHunt(6)

    fakeNow = fakeNow + 1000
    local farPoll = pollScentHunt(6)
    t.isFalse(farPoll.found, 'still 10m away, outside the 3.0 arrivalRadius')
    t.equals(#triggerClientEventCalls, 0)

    -- Walk to within arrivalRadius.
    pedCoordsBySource[6] = { x = 9.0, y = 0.0, z = 0.0 } -- 1m from the target, well under arrivalRadius (3.0)
    fakeNow = fakeNow + 1000
    local nearPoll = pollScentHunt(6)
    t.isTrue(nearPoll.found)
    t.equals(#triggerClientEventCalls, 1)
    t.equals(triggerClientEventCalls[1].event, 'qbx_k9unit:client:scentHuntFound')
    t.equals(triggerClientEventCalls[1].target, 6, 'must be sent to the finder alone, never broadcast')
    t.equals(#triggerClientEventCalls[1].args, 0, 'a trigger only -- never a claimed distance/coordinate')

    -- Still within radius on a later poll -- must NOT refire.
    fakeNow = fakeNow + 1000
    pollScentHunt(6)
    t.equals(#triggerClientEventCalls, 1)
end)

t.test('pollScentHunt: rate-limited by the local POLL_RATE_FLOOR_MS regardless of Config.ScentTrailHunt.pollIntervalMs -- returns the last snapshot instead of recomputing', function()
    pedCoordsBySource[7] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    startScentHunt(7)

    fakeNow = fakeNow + 1000
    local first = pollScentHunt(7)
    t.equals(first.distance, 10.0)

    -- Move, then poll again IMMEDIATELY (no time advance) -- must be
    -- rate-limited and echo the STALE distance, not recompute against the
    -- new position.
    pedCoordsBySource[7] = { x = 0.0, y = 0.0, z = 0.0 } -- unchanged on purpose; the point is the immediate re-poll itself
    local rateLimited = pollScentHunt(7)
    t.isTrue(rateLimited.active)
    t.equals(rateLimited.distance, 10.0)
end)

t.test('pollScentHunt: an unfinished hunt older than maxHuntDurationMs auto-expires and clears', function()
    pedCoordsBySource[8] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    startScentHunt(8)

    fakeNow = fakeNow + (ServerConfig.ScentTrailHunt.maxHuntDurationMs + 1)
    local poll = pollScentHunt(8)
    t.isFalse(poll.active)
    t.isTrue(poll.expired)

    -- Confirmed actually cleared, not just reported expired once: a
    -- fresh start must succeed immediately (no lingering already_active).
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local fresh = startScentHunt(8)
    t.isTrue(fresh.started)
end)

t.test('playerDropped clears a source\'s ActiveHunts entry', function()
    pedCoordsBySource[9] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    startScentHunt(9)

    firePlayerDropped(9)

    fakeNow = fakeNow + 1000
    local poll = pollScentHunt(9)
    t.isFalse(poll.active)
end)

-- ========================================================================
-- SECTION 2 -- client/scenttrail.lua
-- ========================================================================

--- Instrumented coroutine thread runner -- same shape/reasoning as
--- clienttracking_spec.lua's own newTrackedRunner(): client/scenttrail.lua's
--- single CreateThread body runs its real logic FIRST and calls Wait(...)
--- at the END of each pass (including the first), so a bare
--- Sandbox.newThreadRunner() "first call only primes" semantic does not
--- apply here either.
local function newTrackedRunner()
    local threads = {}
    local waitLog = {}
    local runner = {}

    function runner.CreateThread(fn) threads[#threads + 1] = coroutine.create(fn) end
    function runner.Wait(ms) coroutine.yield(ms) end

    function runner.stepOne(i)
        local co = threads[i]
        if not co or coroutine.status(co) == 'dead' then return end
        local ok, msOrErr = coroutine.resume(co)
        if not ok then
            error(('scenttrail_spec: client thread %d errored: %s'):format(i, tostring(msOrErr)))
        end
        waitLog[i] = msOrErr
    end

    return runner, threads, waitLog
end

--- @param opts { canShowK9UI: boolean?, basicBarkSounds: boolean? }?
local function newClientFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local denyCalls = 0
    local function CanShowK9UI() return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local k9SitCalls = 0
    local function K9Sit() k9SitCalls = k9SitCalls + 1 end

    -- PlayK9Sound only exists at all when Config.Features.BasicBarkSounds
    -- is on, per client/audio.lua's own file-scope gate -- mirrored here by
    -- only providing the override when opts.basicBarkSounds ~= false, so
    -- the "audio bridge absent" path is a genuine `type(PlayK9Sound) ==
    -- 'function'` miss, not a stub returning nil.
    local playK9SoundCalls = {}
    local providePlayK9Sound = opts.basicBarkSounds ~= false

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
    local pedDead = false
    local function PlayerPedId() return myPed end
    local function IsEntityDead(_entity) return pedDead end
    local function NetworkGetNetworkIdFromEntity(entity) return entity * 1000 end -- any nonzero, deterministic mapping

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    -- Named distinctly from SECTION 1's own `RegisterNetEvent` local
    -- (server/scenttrail.lua's stopScentHunt registration) purely to avoid
    -- shadowing it -- this closure is unrelated, scoped to this client
    -- fixture only, and assigned into `overrides.RegisterNetEvent` below.
    local netEventHandlers = {}
    local function registerClientNetEvent(eventName, handler)
        netEventHandlers[eventName] = handler
    end

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted)
        commandHandlers[name] = handler
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        K9Sit = K9Sit,
        lib = lib,
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        TriggerServerEvent = TriggerServerEvent,
        RegisterNetEvent = registerClientNetEvent,
        RegisterCommand = RegisterCommand,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        source = 65535, -- ambient `source` seen by a REAL server->client push in production; this fixture's own emitSource override below can shadow it per-call to model a forged self-trigger
    }
    if providePlayK9Sound then
        overrides.PlayK9Sound = function(netId, soundName)
            playK9SoundCalls[#playK9SoundCalls + 1] = { netId = netId, soundName = soundName }
        end
    end

    local env = Sandbox.newEnv(overrides)
    env.Config = {
        Features = { ScentTrailHunt = true, BasicBarkSounds = opts.basicBarkSounds ~= false },
        ScentTrailHunt = { pollIntervalMs = 2000, maxRadius = 30.0 },
    }

    Sandbox.loadInto('../client/scenttrail.lua', env)

    return {
        env = env,
        threads = threads,
        waitLog = waitLog,
        stepOne = runner.stepOne,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        playK9SoundCalls = playK9SoundCalls,
        k9SitCallCount = function() return k9SitCalls end,
        denyCallCount = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setPedDead = function(v) pedDead = v end,
        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        startCommand = function(args) commandHandlers['k9nosehunt'](1, args or {}) end,
        --- Fires the pushed found event as if it genuinely came from the
        --- server (source == 65535) unless `forged` is true, in which case
        --- it models a local self-TriggerEvent (any other source value).
        fireFoundEvent = function(forged)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:scentHuntFound']()
        end,
    }
end

t.test('k9nosehunt: CanShowK9UI() false denies access and never calls the server callback', function()
    local f = newClientFixture({ canShowK9UI = false })
    f.startCommand({})
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
end)

t.test('k9nosehunt: a successful start calls startScentHunt (not pollScentHunt) first, then begins polling', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:startScentHunt')

    f.queueCallbackResponse({ active = true, distance = 20.0, found = false })
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 2)
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:pollScentHunt')
end)

t.test('k9nosehunt: reason = already_active / cooldown / (anything else) map to the right notify without ever crashing on a nil reason', function()
    local fActive = newClientFixture()
    fActive.queueCallbackResponse({ started = false, reason = 'already_active' })
    fActive.startCommand({})
    t.equals(fActive.notifyCalls[1].description, locale('scenttrail.already_active'))

    local fCooldown = newClientFixture()
    fCooldown.queueCallbackResponse({ started = false, reason = 'cooldown' })
    fCooldown.startCommand({})
    t.equals(fCooldown.notifyCalls[1].description, locale('scenttrail.cooldown'))

    local fDenied = newClientFixture()
    fDenied.queueCallbackResponse({ started = false, reason = 'denied' })
    fDenied.startCommand({})
    t.equals(fDenied.denyCallCount(), 1)

    local fNil = newClientFixture()
    fNil.queueCallbackResponse(nil) -- a failed/timed-out round trip
    fNil.startCommand({})
    t.equals(fNil.denyCallCount(), 1, 'a nil result must collapse to the same generic denial, never error')
end)

t.test('pulse pacing: PlayPulse fires once per poll iteration while not yet found, using the already-shipped Growl_Ambient sound key', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.queueCallbackResponse({ active = true, distance = 0.0, found = false }) -- closest possible -> fastest pulse
    f.stepOne(1)
    t.equals(#f.playK9SoundCalls, 1)
    t.equals(f.playK9SoundCalls[1].soundName, 'Growl_Ambient')
    t.equals(f.waitLog[1], 500, 'at distance 0 the pulse must sit at PULSE_MIN_INTERVAL_MS (500ms)')

    f.queueCallbackResponse({ active = true, distance = 30.0, found = false }) -- at/beyond PULSE_MAX_DISTANCE_METERS -> slowest pulse
    f.stepOne(1)
    t.equals(#f.playK9SoundCalls, 2)
    t.equals(f.waitLog[1], 2000, 'at/beyond maxRadius the pulse must sit at PULSE_MAX_INTERVAL_MS (Config.ScentTrailHunt.pollIntervalMs, 2000ms)')
end)

t.test('pulse pacing: silently no-ops (never errors) when PlayK9Sound does not exist -- BasicBarkSounds off, same as production', function()
    local f = newClientFixture({ basicBarkSounds = false })
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.queueCallbackResponse({ active = true, distance = 5.0, found = false })
    f.stepOne(1) -- must not error even though no PlayK9Sound override was provided at all
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('found via the poll loop itself: sits, barks, tells the server to stop, and never plays a further pulse', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.queueCallbackResponse({ active = true, distance = 1.0, found = true })
    f.stepOne(1)

    t.equals(f.k9SitCallCount(), 1)
    t.equals(#f.playK9SoundCalls, 0, 'no pulse on the same tick a hunt resolves as found')

    local barkCall, stopCall
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:relayBark' then barkCall = call end
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopCall = call end
    end
    t.isNotNil(barkCall, 'the trained final response must relay a bark')
    t.equals(barkCall.args[1], 'alert')
    t.isNotNil(stopCall, 'completion must tell the server to clear its own record immediately, not wait for maxHuntDurationMs')

    -- The poll loop must have exited -- resuming it again must not error
    -- (the coroutine is dead) and must not produce a second sit/bark.
    f.stepOne(1)
    t.equals(f.k9SitCallCount(), 1)
end)

t.test('found via the pushed event: genuine (source == 65535) completes the hunt exactly once', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.fireFoundEvent(false)
    t.equals(f.k9SitCallCount(), 1)

    -- A duplicate push (e.g. the poll loop ALSO independently observed
    -- found on its own next tick) must not double-fire the response.
    f.fireFoundEvent(false)
    t.equals(f.k9SitCallCount(), 1)
end)

t.test('found via the pushed event: a FORGED push (source ~= 65535) is rejected -- the trust-boundary origin guard', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.fireFoundEvent(true)
    t.equals(f.k9SitCallCount(), 0, 'a forged self-trigger must never complete a hunt that never actually resolved server-side')
end)

t.test('own-death: the poll loop abandons the hunt (stopScentHunt) instead of continuing to poll from a stale position', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.setPedDead(true)
    f.stepOne(1)

    local stopCall
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopCall = call end
    end
    t.isNotNil(stopCall, 'death must trigger the same unconditional abandon path as a manual stop')
    t.equals(f.callbackCallCount(), 1, 'must never have polled from a dead ped\'s position')
end)

t.test('k9nosehunt stop: unconditional -- works even with CanShowK9UI() false, and is a harmless no-op when nothing is active', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.setCanShowK9UI(false)
    f.startCommand({ 'stop' })

    local stopCall
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopCall = call end
    end
    t.isNotNil(stopCall, 'abandon must never be gated on CanShowK9UI()')
    t.equals(f.denyCallCount(), 0, 'the stop path itself must not trigger a denial notify')

    -- Second stop with nothing active -- must not error.
    f.startCommand({ 'stop' })
end)

t.test('already-active: starting again while a hunt is in progress is rejected locally, with no new server round trip', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)

    f.startCommand({})
    t.equals(f.callbackCallCount(), 1, 'no new round trip -- rejected before ever calling the server again')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('scenttrail.already_active'))
end)

t.test('expired: an inactive-with-expired poll result notifies scenttrail.expired and stops polling', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true })
    f.startCommand({})

    f.queueCallbackResponse({ active = false, expired = true })
    f.stepOne(1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('scenttrail.expired'))

    -- A fresh start must now succeed again (not blocked as already_active).
    f.queueCallbackResponse({ started = true })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 3) -- start, poll, start again
end)

os.exit(t.summary())
