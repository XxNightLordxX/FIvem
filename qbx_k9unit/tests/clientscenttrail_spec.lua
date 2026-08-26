--[[
    tests/clientscenttrail_spec.lua

    Direct, black-box tests of client/scenttrail.lua against the REAL,
    unmodified production file -- the client half of the "Follow your nose"
    Scent Trail Hunt (server/scenttrail.lua's own contract). Follows
    clientcombat_spec.lua/clientmovement_spec.lua's worked example: a real
    file loaded into a fresh sandbox per test, driven only through its one
    documented external surface (the '/k9nosehunt [stop]' command handler)
    and its one server->client push ('qbx_k9unit:client:scentHuntFound').

    client/scenttrail.lua exposes NO resource-global functions at all (its
    own header, "FILE-TO-FILE CONTRACT") -- StartScentHunt/StopScentHunt/
    CompleteHunt are all `local`, only reachable the same way a real caller
    reaches them: through the captured '/k9nosehunt' RegisterCommand handler
    and the captured scentHuntFound RegisterNetEvent handler. This spec
    never reimplements or reaches around either seam.

    THIS PASS'S PRIORITY, per the task brief that produced this file:
      1. THE STALE-SESSION RACE FIX (this file's own header section of the
         same name) -- currentHuntId/IsForCurrentHunt. Section E below pins
         the exact race described there: a stale 'found' push for an
         already-abandoned hunt arriving AFTER a brand-new hunt has started
         must NOT complete the new, unsolved hunt early; a push carrying NO
         id at all must still always be accepted (a deliberate, disclosed
         design choice, not a bug to "fix").
      2. THE STOP PATH IS NEVER GATED -- section F proves StopScentHunt()
         reaches the server even with CanShowK9UI() entirely UNDEFINED in
         the sandbox (not merely false), the same "omit the global outright"
         technique tests/clienttracking_spec.lua uses to prove a claimed
         "never calls X" statement, because a stubbed `false` could not
         distinguish "never calls it" from "calls it and correctly denies".
      3. FEATURE-OFF INERTNESS -- section A proves the flag-off file
         registers NOTHING (no command, no net event, no thread), not
         merely a function that early-returns when called.
      4. FAIL-CLOSED lib.callback.await handling -- both awaited calls in
         this file are pcall-wrapped (a throwing await must degrade to "no
         usable result", never crash the caller) -- section D.
      5. RESOURCE-STOP HYGIENE, FIXED THIS PASS (this file's own header
         section of the same name) -- section H below pins the fix: an
         onResourceStop handler now reaches the server with
         'qbx_k9unit:server:stopScentHunt' via StopScentHunt() itself,
         closing the gap this spec used to document (in its own "WHAT THIS
         FILE DOES NOT COVER" note) as merely low-severity/self-healing --
         see that section's own corrected text below for why it was worse
         than first described for THIS file specifically (no periodic
         server-side sweep, unlike server/sarcalls.lua's own).

    STUBBING EFFORT: proportionate. Every native/cross-file global this
    file's exercised paths touch is a small, cheap recording/controllable
    stand-in (CanShowK9UI/DenyK9UIAccess/K9Sit/PlayK9Sound,
    PlayerPedId/IsEntityDead/NetworkGetNetworkIdFromEntity,
    TriggerServerEvent/RegisterNetEvent/RegisterCommand, lib.callback.await/
    lib.notify, CreateThread/Wait). Nothing here required disproportionate
    stubbing.

    INSTRUMENTED THREAD RUNNER, own copy (per this suite's "each spec owns
    its own tiny fixtures" convention -- see clienttracking_spec.lua's own
    header for why it does not reuse fixtures/sandbox.lua's
    Sandbox.newThreadRunner()): EnsureHuntPollThreadRunning's own poll loop
    calls Wait(...) as the LAST statement of its loop body (not the first),
    so -- exactly like clienttracking_spec.lua's compute/render threads --
    the FIRST resume of a freshly-created thread already runs one full real
    pass, not merely a "prime". stepOne(i) resumes threads[i] once and
    records the ms value its own Wait(...) call was made with.

    ONE FRESH SANDBOX PER TEST -- client/scenttrail.lua's own file-load-time
    locals (huntActive, huntCompleted, startInFlight, huntGeneration,
    currentHuntId) are exactly the kind of module-lifetime state that must
    never leak between two unrelated test cases.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale


-- ----------------------------------------------------------------------
-- Instrumented thread runner -- see this file's header for why this is a
-- DIFFERENT shape than Sandbox.newThreadRunner() (Wait is this loop's LAST
-- statement, not its first).
-- ----------------------------------------------------------------------
local function newTrackedRunner()
    local threads = {}
    local waitLog = {}
    local runner = {}

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(ms)
        coroutine.yield(ms)
    end

    function runner.stepOne(i)
        local co = threads[i]
        if not co or coroutine.status(co) == 'dead' then return end
        local ok, msOrErr = coroutine.resume(co)
        if not ok then
            error(('clientscenttrail_spec: poll thread %d errored: %s'):format(i, tostring(msOrErr)))
        end
        waitLog[i] = msOrErr
    end

    return runner, threads, waitLog
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { scentTrailHunt: boolean?, canShowK9UI: boolean?, basicBarkSounds: boolean?, provideK9Sit: boolean?, scentTrailHuntConfig: table?|false }?
local function newScentTrailFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local denyCalls = 0
    local function CanShowK9UI() return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local k9SitCalls = 0
    local function K9Sit() k9SitCalls = k9SitCalls + 1 end

    local playK9SoundCalls = {}
    local providePlayK9Sound = opts.basicBarkSounds ~= false
    local function PlayK9Sound(netId, soundName)
        playK9SoundCalls[#playK9SoundCalls + 1] = { netId = netId, soundName = soundName }
    end

    local shouldThrowNext = false
    local callbackResponses = {}
    local callbackCallLog = {}
    -- Reentrant hook -- fired from INSIDE callbackAwait, BEFORE it returns
    -- its own queued response, modelling "a second action happens while the
    -- first is still awaiting the server" the same way
    -- clienttracking_spec.lua's own `reentrantFn` does (this sandbox's
    -- lib.callback.await is otherwise synchronous, so this is the only way
    -- to model true in-flight concurrency without a second coroutine).
    local reentrantFn = nil
    local function callbackAwait(eventName, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        if shouldThrowNext then
            shouldThrowNext = false
            error('simulated lib.callback.await timeout/rejection')
        end
        if reentrantFn then
            local fn = reentrantFn
            reentrantFn = nil
            fn()
        end
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
    local function NetworkGetNetworkIdFromEntity(entity) return entity * 1000 end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted) commandHandlers[name] = handler end

    -- Resource-stop capture -- see this file's header "RESOURCE-STOP
    -- HYGIENE, FIXED THIS PASS" and section H below. Same shape as
    -- tests/clientsarcalls_spec.lua's own AddEventHandler/fireResourceStop
    -- pair.
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        K9Sit = (opts.provideK9Sit ~= false) and K9Sit or nil,
        lib = lib,
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        TriggerServerEvent = TriggerServerEvent,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        source = 65535,
    }
    if providePlayK9Sound then
        overrides.PlayK9Sound = PlayK9Sound
    end

    local env = Sandbox.newEnv(overrides)
    env.Config = {
        Features = { ScentTrailHunt = opts.scentTrailHunt ~= false, BasicBarkSounds = providePlayK9Sound },
    }
    if opts.scentTrailHuntConfig ~= false then
        env.Config.ScentTrailHunt = opts.scentTrailHuntConfig or { pollIntervalMs = 2000, maxRadius = 30.0 }
    end

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
        setThrowNext = function() shouldThrowNext = true end,
        setReentrant = function(fn) reentrantFn = fn end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        commandCount = function()
            local n = 0
            for _ in pairs(commandHandlers) do n = n + 1 end
            return n
        end,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEventHandlers) do n = n + 1 end
            return n
        end,
        threadCount = function() return #threads end,
        startCommand = function(args) commandHandlers['k9nosehunt'](1, args or {}) end,
        stopCommand = function() commandHandlers['k9nosehunt'](1, { 'stop' }) end,
        --- Fires the pushed found event. `forged` (default false) models a
        --- local self-TriggerEvent (any source other than 65535). `huntId`
        --- defaults to nil (no id), matching the design's own "no id at all
        --- is always accepted" rule.
        fireFoundEvent = function(forged, huntId)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:scentHuntFound'](huntId)
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, h in ipairs(eventHandlers['onResourceStop'] or {}) do h(resourceName or 'qbx_k9unit') end
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- feature flag off: GENUINELY inert, not merely early-return.
-- ----------------------------------------------------------------------

t.test('Config.Features.ScentTrailHunt = false: registers NO command, NO net event, NO onResourceStop handler, and creates NO thread', function()
    local f = newScentTrailFixture({ scentTrailHunt = false })
    t.equals(f.commandCount(), 0, 'no RegisterCommand call at all when the feature is off')
    t.equals(f.netEventCount(), 0, 'no RegisterNetEvent call at all when the feature is off')
    t.equals(f.onResourceStopHandlerCount(), 0, 'no AddEventHandler(onResourceStop, ...) call at all when the feature is off')
    t.equals(f.threadCount(), 0, 'no CreateThread call at all when the feature is off')
end)

t.test('Config.Features.ScentTrailHunt = true: registers exactly the k9nosehunt command and the scentHuntFound net event', function()
    local f = newScentTrailFixture()
    t.equals(f.commandCount(), 1)
    t.equals(f.netEventCount(), 1)
    t.equals(f.threadCount(), 0, 'no thread until a hunt actually starts')
end)

-- ----------------------------------------------------------------------
-- SECTION B -- StartScentHunt() gating and reason mapping.
-- ----------------------------------------------------------------------

t.test('k9nosehunt: CanShowK9UI() false denies access and never calls the server at all', function()
    local f = newScentTrailFixture({ canShowK9UI = false })
    f.startCommand({})
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
    t.equals(f.threadCount(), 0)
end)

t.test('k9nosehunt: a successful start calls startScentHunt (not pollScentHunt) first, then begins polling on its own thread', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:startScentHunt')
    t.equals(f.threadCount(), 1)

    f.queueCallbackResponse({ active = true, distance = 20.0, found = false })
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 2)
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:pollScentHunt')
end)

t.test('k9nosehunt: reason = already_active / cooldown / anything-else map to the right notify, never crashing on a nil reason or nil result', function()
    local fActive = newScentTrailFixture()
    fActive.queueCallbackResponse({ started = false, reason = 'already_active' })
    fActive.startCommand({})
    t.equals(fActive.notifyCalls[1].description, locale('scenttrail.already_active'))

    local fCooldown = newScentTrailFixture()
    fCooldown.queueCallbackResponse({ started = false, reason = 'cooldown' })
    fCooldown.startCommand({})
    t.equals(fCooldown.notifyCalls[1].description, locale('scenttrail.cooldown'))

    local fDenied = newScentTrailFixture()
    fDenied.queueCallbackResponse({ started = false, reason = 'denied' })
    fDenied.startCommand({})
    t.equals(fDenied.denyCallCount(), 1)

    local fNil = newScentTrailFixture()
    fNil.startCommand({}) -- nothing queued -- a failed/timed-out round trip
    t.equals(fNil.denyCallCount(), 1, 'a nil result must collapse to the same generic denial, never error')
end)

t.test('k9nosehunt: already hunting rejects a second start outright, without a new round trip', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)

    f.queueCallbackResponse({ started = true, huntId = 2 }) -- must never be consulted
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1, 'no new round trip -- rejected before ever calling the server again')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('scenttrail.already_active'))
end)

-- ----------------------------------------------------------------------
-- SECTION C -- pulse pacing and the found-via-poll path.
-- ----------------------------------------------------------------------

t.test('pulse pacing: distance 0 sits at PULSE_MIN_INTERVAL_MS (500ms); at/beyond maxRadius sits at PULSE_MAX_INTERVAL_MS (pollIntervalMs)', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})

    f.queueCallbackResponse({ active = true, distance = 0.0, found = false })
    f.stepOne(1)
    t.equals(#f.playK9SoundCalls, 1)
    t.equals(f.playK9SoundCalls[1].soundName, 'Growl_Ambient')
    t.equals(f.waitLog[1], 500)

    f.queueCallbackResponse({ active = true, distance = 30.0, found = false })
    f.stepOne(1)
    t.equals(#f.playK9SoundCalls, 2)
    t.equals(f.waitLog[1], 2000)
end)

t.test('pulse pacing: a missing Config.ScentTrailHunt table falls back to the documented defaults (30m / 2000ms) without erroring', function()
    local f = newScentTrailFixture({ scentTrailHuntConfig = false })
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.queueCallbackResponse({ active = true, distance = 30.0, found = false })
    f.stepOne(1)
    t.equals(f.waitLog[1], 2000)
end)

t.test('pulse pacing: silently no-ops (never errors) when PlayK9Sound does not exist -- BasicBarkSounds off, matching production degrade', function()
    local f = newScentTrailFixture({ basicBarkSounds = false })
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.queueCallbackResponse({ active = true, distance = 5.0, found = false })
    f.stepOne(1)
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('found via the poll loop itself: sits, tells the server to stop, relays a bark, and never plays a further pulse', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})

    f.queueCallbackResponse({ active = true, distance = 1.0, found = true })
    f.stepOne(1)

    t.equals(f.k9SitCallCount(), 1)
    t.equals(#f.playK9SoundCalls, 0, 'the found branch never plays a pulse itself')
    local stopEvents = 0
    local barkEvents = 0
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopEvents = stopEvents + 1 end
        if call.event == 'qbx_k9unit:server:relayBark' then barkEvents = barkEvents + 1; t.equals(call.args[1], 'alert') end
    end
    t.equals(stopEvents, 1)
    t.equals(barkEvents, 1)
end)

t.test('found via the poll loop: silently no-ops K9Sit call when K9Sit does not exist (soft dependency), everything else still happens', function()
    local f = newScentTrailFixture({ provideK9Sit = false })
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.queueCallbackResponse({ active = true, distance = 1.0, found = true })
    f.stepOne(1) -- must not error even with K9Sit entirely absent
    t.equals(#f.triggerServerEventCalls, 2, 'stopScentHunt + relayBark still fire')
end)

t.test('poll result inactive (server-side expiry): notifies scenttrail.expired, ends the hunt locally, no extra TriggerServerEvent', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.queueCallbackResponse({ active = false, expired = true })
    f.stepOne(1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('scenttrail.expired'))
    t.equals(#f.triggerServerEventCalls, 0, 'an expiry the server already recorded needs no further client -> server call')
end)

t.test('poll result inactive, no expired flag (e.g. stopped some other way server-side): silent, no notify, no crash', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.queueCallbackResponse({ active = false })
    f.stepOne(1)
    t.equals(#f.notifyCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- FAIL-CLOSED lib.callback.await handling (both call sites).
-- ----------------------------------------------------------------------

t.test('FAIL-CLOSED: startScentHunt throwing is caught and treated as a generic denial, never crashes the command handler', function()
    local f = newScentTrailFixture()
    f.setThrowNext()
    f.startCommand({})
    t.equals(f.denyCallCount(), 1)
    t.equals(f.threadCount(), 0, 'a failed start must never begin polling')
end)

t.test('FAIL-CLOSED: pollScentHunt throwing mid-hunt is caught, ends the hunt locally (no notify), never crashes the poll thread', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.setThrowNext()
    f.stepOne(1) -- must not raise out of the coroutine
    t.equals(#f.notifyCalls, 0)
end)

t.test('death mid-poll: IsEntityDead true stops the hunt BEFORE ever calling the server again, via the unconditional stop path', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)

    f.setPedDead(true)
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 1, 'the death check runs before the poll callback -- no second round trip')
    local stopEvents = 0
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopEvents = stopEvents + 1 end
    end
    t.equals(stopEvents, 1)
end)

-- ----------------------------------------------------------------------
-- SECTION E -- THE STALE-SESSION RACE FIX (currentHuntId/IsForCurrentHunt).
-- See this file's own header "STALE-SESSION RACE" for the full writeup this
-- section pins.
-- ----------------------------------------------------------------------

t.test('STALE-SESSION RACE: a scentHuntFound push carrying the OLD hunt id, arriving AFTER a new hunt has started, is rejected -- does not complete the new hunt early', function()
    local f = newScentTrailFixture()

    -- Hunt A starts (id 1), then is abandoned.
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.stopCommand()
    t.equals(#f.triggerServerEventCalls, 1, 'the abandon itself is one stopScentHunt call')

    -- Hunt B starts (id 2) -- a fresh, still-unsolved hunt.
    f.queueCallbackResponse({ started = true, huntId = 2 })
    f.startCommand({})

    -- A stale push for hunt A's own id arrives late.
    f.fireFoundEvent(false, 1)

    t.equals(f.k9SitCallCount(), 0, 'hunt B must NOT be completed by a push meant for hunt A')
    t.equals(#f.triggerServerEventCalls, 1, 'no extra stopScentHunt/relayBark from the rejected stale push -- still just the earlier abandon')

    -- The genuinely current push (id 2) still works.
    f.fireFoundEvent(false, 2)
    t.equals(f.k9SitCallCount(), 1)
end)

t.test('STALE-SESSION RACE: a push with NO id at all is ALWAYS accepted -- this is a deliberate design choice, not something to "fix" to be stricter', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 42 })
    f.startCommand({})

    f.fireFoundEvent(false, nil) -- no id on the push at all
    t.equals(f.k9SitCallCount(), 1, 'an unlabeled push must still complete the hunt, matching production intent')
end)

t.test('IN-FLIGHT GUARD: a second k9nosehunt start made WHILE the first is still awaiting the server is rejected outright -- no second round trip', function()
    local f = newScentTrailFixture()
    f.setReentrant(function() f.startCommand({}) end)
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1, 'the reentrant second call must not have reached the server at all')
    t.equals(f.threadCount(), 1)
end)

t.test('STALENESS TOKEN: an abandon that runs WHILE a start is still awaiting the server discards that pending start attempts eventual grant as stale', function()
    local f = newScentTrailFixture()
    f.setReentrant(function() f.stopCommand() end)
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    -- The grant resolved AFTER the reentrant stop already bumped
    -- huntGeneration -- it must be discarded, never resurrecting a hunt the
    -- player already walked away from.
    t.equals(f.threadCount(), 0, 'a stale grant must never start polling')
end)

-- ----------------------------------------------------------------------
-- SECTION F -- THE STOP PATH IS NEVER GATED (per-person feature control).
-- CanShowK9UI is entirely OMITTED from this fixture's own sandbox (not
-- merely stubbed false) -- if StopScentHunt() ever called it, this would
-- fail with "attempt to call a nil value", not silently pass on an
-- agreeing stub. This is the concrete proof that someone blocked mid-hunt
-- (per-person feature control denying them) can still always stop.
-- ----------------------------------------------------------------------

t.test('k9nosehunt stop: reaches the server EVEN WITH CanShowK9UI entirely undefined -- proves the abandon path never checks access of any kind', function()
    local f = newScentTrailFixture()
    f.env.CanShowK9UI = nil
    f.env.DenyK9UIAccess = nil
    t.isNil(f.env.CanShowK9UI, 'sanity: CanShowK9UI must be genuinely absent, not merely false')

    f.stopCommand() -- must not error, must still reach the server
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:stopScentHunt')
end)

t.test('k9nosehunt stop: safe no-op when nothing is active (no error, still forwards the unconditional stop event)', function()
    local f = newScentTrailFixture()
    f.stopCommand()
    t.equals(#f.triggerServerEventCalls, 1)
end)

-- ----------------------------------------------------------------------
-- SECTION G -- source-origin guard on the server->client push.
-- ----------------------------------------------------------------------

t.test('scentHuntFound: a forged (non-65535 source) push is rejected outright, even for the current hunt id', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.fireFoundEvent(true, 1)
    t.equals(f.k9SitCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- SECTION H -- RESOURCE-STOP HYGIENE, FIXED THIS PASS. See this file's own
-- header section of the same name for the full write-up this section pins.
-- ----------------------------------------------------------------------

t.test('FIXED: Config.Features.ScentTrailHunt = true registers exactly one onResourceStop handler', function()
    local f = newScentTrailFixture()
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('FIXED: an onResourceStop for a DIFFERENT resource is ignored -- no stopScentHunt call', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    f.fireResourceStop('some_other_resource')
    t.equals(#f.triggerServerEventCalls, 0, 'only THIS resource stopping should trigger the abandon')
end)

t.test('FIXED: onResourceStop for THIS resource, mid-hunt, sends stopScentHunt -- closing the "orphaned ActiveHunts[source] until disconnect" gap this spec used to pin as a bug', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({})
    t.equals(#f.triggerServerEventCalls, 0, 'sanity: nothing sent yet, only a start')

    f.fireResourceStop('qbx_k9unit')
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:stopScentHunt')
end)

t.test('FIXED: onResourceStop reaches the server EVEN WITH CanShowK9UI entirely undefined -- the cleanup path is never gated on access, same as k9nosehunt stop', function()
    local f = newScentTrailFixture()
    f.queueCallbackResponse({ started = true, huntId = 1 })
    f.startCommand({}) -- start while CanShowK9UI is still available; access is only checked on the START path

    -- Certification/access revoked (or the whole global removed) AFTER the
    -- hunt is already live -- StartScentHunt() is not re-entered by
    -- onResourceStop, so this must not matter to the cleanup path at all.
    f.env.CanShowK9UI = nil
    f.env.DenyK9UIAccess = nil
    t.isNil(f.env.CanShowK9UI, 'sanity: CanShowK9UI must be genuinely absent, not merely false')

    f.fireResourceStop('qbx_k9unit') -- must not error
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:stopScentHunt')
end)

t.test('FIXED: onResourceStop with nothing active is a safe no-op that still forwards the unconditional stop event, same as k9nosehunt stop', function()
    local f = newScentTrailFixture()
    f.fireResourceStop('qbx_k9unit')
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:stopScentHunt')
end)

-- ----------------------------------------------------------------------
-- WHAT THIS FILE DOES NOT COVER, AND WHY:
--
-- 1. "ANY PED" model-gating: unlike client/pursuitsprint.lua (whose own
--    header devotes a full section to deliberately NEVER calling
--    CanShowK9UI(), precisely so a role-holder on a non-K9 body is not
--    silently narrowed by that composed check's own optional model
--    dependency), client/scenttrail.lua's access story is entirely
--    "call CanShowK9UI(), trust its answer" -- a client-side COURTESY only,
--    per this file's own doc comment, since server/scenttrail.lua
--    independently re-validates HasK9Access(source) regardless. This
--    spec's CanShowK9UI stub is an independent boolean, never derived from
--    a model check, and IsOwnModelK9/GetEntityModel are never provided
--    anywhere in this fixture at all -- proving (the same "omit the
--    global" technique as section F) that this file never separately
--    consults a ped model directly itself. Whether CanShowK9UI() itself
--    narrows on model in a given server config is client/main.lua's own
--    concern, out of scope for this file's spec.
-- 2. onResourceStop: FIXED THIS PASS, see section H above. This spec used
--    to note here that client/scenttrail.lua registered no onResourceStop
--    handler at all, calling the gap "low severity (self-heals, not
--    exploitable)". That framing was WRONG for this file specifically, and
--    is corrected here rather than silently deleted, so nobody re-derives
--    the same mistaken assumption from an old copy of this comment:
--    server/scenttrail.lua's own expiry check is LAZY, run only inside
--    pollScentHunt (see that file's own header) -- there is no separate,
--    always-running sweep thread there, unlike server/sarcalls.lua's own
--    unconditional periodic tick loop (see tests/clientsarcalls_spec.lua's
--    own equivalent note for that file's genuinely lower-severity version
--    of this same gap). A source that starts a hunt and then never polls
--    again -- exactly what a dead/restarted client script produces, since
--    its own poll thread dies with the rest of this resource's Lua state
--    and sends nothing further -- left ActiveHunts[source] with NOTHING
--    left to ever trigger that lazy expiry check, so the record did NOT
--    reliably self-heal within maxHuntDurationMs; it could persist until
--    this player's next genuine disconnect. Section H above pins the fix:
--    an eager, unconditional onResourceStop -> StopScentHunt() call,
--    closing the gap instead of merely documenting it.
-- 3. Exact pulse-curve tuning (linear interpolation shape) beyond the two
--    boundary values (0m / maxRadius) already pinned above -- this file's
--    own header explicitly disclaims the curve as "a first-pass judgment
--    call, not something verified to feel good in-game", so this spec pins
--    the two load-bearing endpoints and the config-driven ceiling, not
--    every point along the curve.
-- ----------------------------------------------------------------------

os.exit(t.summary())
