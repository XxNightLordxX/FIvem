--[[
    tests/clienttracking_spec.lua

    Client-side spec for client/tracking.lua (Track Scent/Blood/Gunpowder,
    the water-crossing degrade modifier, and the blood/gunpowder capture
    threads). Follows main_spec.lua's worked example: a real, unmodified
    client/tracking.lua loaded into a fresh sandbox per test, driven only
    through its five documented resource-globals
    (StartScentTrack/StartBloodTrack/StartGunpowderTrack/StopTracking/
    IsTracking/GetActiveTrackType) plus its one captured AddEventHandler
    ('gameEventTriggered') callback -- never a reimplementation of its
    logic.

    THIS PASS'S PRIORITY, per this file's own task brief:
    1. The render thread's idle path -- a bug was fixed this session where
       an empty-but-present `currentTrailMarkers` table (`{}`) was treated
       as truthy by `if currentTrailMarkers then`, so the render thread
       spun at Wait(0) drawing nothing. Section D below drives the REAL
       water-break-at-zero-distance scenario that produces exactly that
       `{}` handoff, and proves the render thread idles (Wait(250), zero
       DrawMarker calls) for BOTH that case and the plain-nil case, not
       just one of them.
    2. The state/compute vs. render THREAD SPLIT: the compute thread only
       recomputes the trail every TRACK_TICK_MS (250ms), but the dedicated
       render thread must redraw the cached snapshot on EVERY frame it is
       resumed, independent of how often the compute thread ticks -- see
       section C's "redraws the SAME cached trail on repeated resumes
       without recomputing" test, which is the direct proof of the exact
       strobe bug this split was built to fix.
    3. A water break clears the trail -- section D/E, both the immediate
       "current tick still renders the partial line" case and the
       following tick's full clear.
    4. The `source ~= 65535` origin guard on this file's net handlers --
       see section F. THIS IS A GENUINE, DISCLOSED DEVIATION FROM THIS
       TASK'S OWN STATED SCOPE, not an oversight: client/tracking.lua
       registers NO RegisterNetEvent handler at all (confirmed by reading
       the whole file -- its own EVENT/CALLBACK CONTRACT header states
       "No other client events (server->client) for this file at all").
       Every event this file touches is either a `lib.callback.await`
       request/response pair (never a server-PUSHED event with a `source`
       to forge) or a client->server TriggerServerEvent this file only
       ever SENDS, never receives. There is therefore no `source ~= 65535`
       guard anywhere in this file to test -- section F proves this
       directly (by never stubbing RegisterNetEvent at all and confirming
       the file still loads and every other test in this suite still
       exercises it end to end) rather than fabricating a guard test
       against code that does not exist. Reported as a finding, not
       silently skipped.

    STUBBING EFFORT, reported honestly per this task's own instruction:
    proportionate. Every native this file touches is a small, cheap
    recording/controllable stand-in (PlayerPedId/GetEntityCoords/
    IsEntityDead/GetWaterHeightNoWaves/DrawMarker/TriggerServerEvent/
    IsPedShooting/AddEventHandler/CreateThread/Wait/lib.callback.await/
    lib.notify), plus one small local vector3-alike metatable (identical
    shape to clientradial_spec.lua's own copy, extended with `+`/`*`/`/`
    since this file's water-crossing/marker-spacing math needs all of
    those operators, not just `-`/`#`). Nothing here required
    disproportionate stubbing.

    INSTRUMENTED THREAD RUNNER -- DIFFERENT STEPPING SEMANTICS THAN
    fixtures/sandbox.lua's own Sandbox.newThreadRunner(), BY NECESSITY:
    that shared helper's own doc comment says the first step() call only
    "primes" a captured thread because "every sweep thread in this
    resource calls Wait(...) as its FIRST statement inside the loop." That
    is NOT true of any of this file's three CreateThread bodies -- each
    one runs its real per-tick logic FIRST and calls Wait(...) exactly
    once, at the END of its loop body, on every pass including the first.
    Reusing the shared helper here would silently misrepresent the first
    step() as a no-op when it is actually a full real pass. This file
    therefore builds its own tiny runner below (self-contained, per this
    suite's established "each spec owns its own tiny fixtures"
    convention) that ALSO captures the exact `ms` value each thread's
    Wait(...) call was made with, keyed by that thread's creation-order
    index (`threads[1]` = the state/compute thread, `threads[2]` = the
    render thread, `threads[3]` = the gunpowder capture thread -- this
    file's own CreateThread call order, verified by reading the file
    top-to-bottom) -- something Sandbox.newThreadRunner() does not expose
    at all. This is done via `coroutine.yield(ms)` / reading `ms` back off
    `coroutine.resume`'s second return value, not by guessing at Wait's
    argument some other way.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- same shape as clientradial_spec.lua's own copy,
-- extended with __add/__mul/__div: client/tracking.lua's water-crossing
-- sampling (`startCoords + dir * traveled`) and unit-direction math
-- (`(endCoords - startCoords) / total`) need all three, not just the
-- `-`/`#` clientradial_spec.lua's simpler onSelect-only math required.
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT) end
Vec3MT.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, Vec3MT) end
Vec3MT.__mul = function(a, b)
    if type(a) == 'number' then return setmetatable({ x = b.x * a, y = b.y * a, z = b.z * a }, Vec3MT) end
    return setmetatable({ x = a.x * b, y = a.y * b, z = a.z * b }, Vec3MT)
end
Vec3MT.__div = function(a, b) return setmetatable({ x = a.x / b, y = a.y / b, z = a.z / b }, Vec3MT) end
Vec3MT.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec3MT) end

-- ----------------------------------------------------------------------
-- Instrumented thread runner -- see this file's own header for why this
-- is a DIFFERENT shape than Sandbox.newThreadRunner().
-- ----------------------------------------------------------------------
local function newTrackedRunner()
    local threads = {}
    local waitLog = {} -- waitLog[i] = the ms value threads[i]'s Wait(...) was last called with
    local runner = {}

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(ms)
        coroutine.yield(ms)
    end

    --- Resumes ONLY threads[i] once (one full loop body pass, since every
    --- thread in this file calls Wait at the END of its loop, not the
    --- start -- see this file's header). Used both by step() below and
    --- directly by tests that need to advance the render thread several
    --- times WITHOUT re-running the compute thread in between (section C).
    function runner.stepOne(i)
        local co = threads[i]
        if not co or coroutine.status(co) == 'dead' then return end
        local ok, msOrErr = coroutine.resume(co)
        if not ok then
            error(('clienttracking_spec: thread %d errored: %s'):format(i, tostring(msOrErr)))
        end
        waitLog[i] = msOrErr
    end

    --- Resumes every captured thread once, in creation order.
    function runner.step()
        for i = 1, #threads do runner.stepOne(i) end
    end

    return runner, threads, waitLog
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { canShowK9UI: boolean?, waterTrackingDecay: boolean?, xpProgression: boolean?, gunpowderSniffing: boolean?, bloodTracking: boolean? }?
local function newTrackingFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local denyCalls = 0
    local function CanShowK9UI() return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local callbackResponses = {}
    local callbackCallLog = {}
    local reentrantFn = nil -- see section B: fired once, INSIDE the pending callbackAwait, to model true concurrency in a sandbox where lib.callback.await is otherwise synchronous
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
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
    local pedCoords = vec3(0, 0, 0)
    local pedDead = false
    local function PlayerPedId() return myPed end
    local function GetEntityCoords(entity) return pedCoords end
    local function IsEntityDead(entity) return pedDead end

    local waterHeightFn = opts.waterHeightFn -- function(x,y,z) -> boolean found; defaults to "never any water"
    local function GetWaterHeightNoWaves(x, y, z)
        if waterHeightFn then return waterHeightFn(x, y, z) end
        return false
    end

    local drawMarkerCalls = {}
    local function DrawMarker(...) drawMarkerCalls[#drawMarkerCalls + 1] = { ... } end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    -- Deliberately the ONLY AddEventHandler registration this fixture
    -- expects ('gameEventTriggered') -- see this file's header section 4
    -- on why RegisterNetEvent is never stubbed at all.
    local gameEventHandler = nil
    local function AddEventHandler(eventName, handler)
        assert(eventName == 'gameEventTriggered',
            ('clienttracking_spec: unexpected AddEventHandler(%q, ...) -- this fixture only expects gameEventTriggered; client/tracking.lua may have grown a new event this spec needs updating for'):format(tostring(eventName)))
        gameEventHandler = handler
    end

    local isPedShooting = false
    local function IsPedShooting(entity) return isPedShooting end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        IsEntityDead = IsEntityDead,
        GetWaterHeightNoWaves = GetWaterHeightNoWaves,
        DrawMarker = DrawMarker,
        TriggerServerEvent = TriggerServerEvent,
        AddEventHandler = AddEventHandler,
        IsPedShooting = IsPedShooting,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- Explicit per this task's own instruction: every flag this file reads
    -- is set here, per-fixture, never left to whatever config.lua ships
    -- with (all 40 feature flags are true in config.lua as of this pass --
    -- these tests must keep passing however that shipped default moves).
    env.Config.Features.WaterTrackingDecay = opts.waterTrackingDecay or false
    env.Config.Features.XPProgression = opts.xpProgression or false
    env.Config.Features.GunpowderSniffing = opts.gunpowderSniffing or false
    env.Config.Features.BloodTracking = opts.bloodTracking or false

    Sandbox.loadInto('../client/tracking.lua', env)

    return {
        env = env,
        threads = threads,
        waitLog = waitLog,
        step = runner.step,
        stepOne = runner.stepOne,
        drawMarkerCalls = drawMarkerCalls,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyCallCount = function() return denyCalls end,
        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        setReentrant = function(fn) reentrantFn = fn end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,

        setPedCoords = function(v) pedCoords = v end,
        setPedDead = function(v) pedDead = v end,
        setWaterHeightFn = function(fn) waterHeightFn = fn end,
        setPedShooting = function(v) isPedShooting = v end,

        triggerGameEvent = function(eventName, data)
            assert(gameEventHandler, 'client/tracking.lua did not register a gameEventTriggered handler')
            gameEventHandler(eventName, data)
        end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity: the five documented resource-globals exist, and this fixture's
-- own gameEventTriggered capture actually reaches the real handler.
-- ----------------------------------------------------------------------

t.test('client/tracking.lua exposes all five documented resource-globals', function()
    local f = newTrackingFixture()
    t.isNotNil(f.env.StartScentTrack)
    t.isNotNil(f.env.StartBloodTrack)
    t.isNotNil(f.env.StartGunpowderTrack)
    t.isNotNil(f.env.StopTracking)
    t.isNotNil(f.env.IsTracking)
    t.isNotNil(f.env.GetActiveTrackType)
    t.isFalse(f.env.IsTracking(), 'a fresh sandbox must start untracked')
    t.isNil(f.env.GetActiveTrackType())
end)

-- ----------------------------------------------------------------------
-- SECTION A -- StartTrack()'s own guards: CanShowK9UI, already-tracking,
-- not-found. These gate everything else below, so proven first.
-- ----------------------------------------------------------------------

t.test('StartScentTrack: CanShowK9UI() false denies access and never even calls the server callback', function()
    local f = newTrackingFixture({ canShowK9UI = false })
    f.env.StartScentTrack()
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
    t.isFalse(f.env.IsTracking())
end)

t.test('StartScentTrack: a successful resolve sets IsTracking()/GetActiveTrackType() and sends the real trackType to the real callback name', function()
    local f = newTrackingFixture()
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    t.isTrue(f.env.IsTracking())
    t.equals(f.env.GetActiveTrackType(), 'scent')
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:findTrackableSource')
    t.equals(f.lastCallbackCall().args[1], 'scent')
end)

t.test('StartBloodTrack / StartGunpowderTrack: each sends its OWN trackType, not a shared/hardcoded one', function()
    local fBlood = newTrackingFixture()
    fBlood.queueCallbackResponse({ found = true, coords = vec3(1, 0, 0) })
    fBlood.env.StartBloodTrack()
    t.equals(fBlood.env.GetActiveTrackType(), 'blood')
    t.equals(fBlood.lastCallbackCall().args[1], 'blood')

    local fGun = newTrackingFixture()
    fGun.queueCallbackResponse({ found = true, coords = vec3(1, 0, 0) })
    fGun.env.StartGunpowderTrack()
    t.equals(fGun.env.GetActiveTrackType(), 'gunpowder')
    t.equals(fGun.lastCallbackCall().args[1], 'gunpowder')
end)

t.test('StartScentTrack: result.found == false notifies tracking.nothing_to_track and leaves IsTracking() false', function()
    local f = newTrackingFixture()
    f.queueCallbackResponse({ found = false })
    f.env.StartScentTrack()
    t.isFalse(f.env.IsTracking())
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.nothing_to_track'))
end)

t.test('StartScentTrack: a nil callback result (failed/timed-out round trip) is treated the same as found == false, not an error', function()
    local f = newTrackingFixture()
    -- Nothing queued -- table.remove on an empty queue returns nil.
    f.env.StartScentTrack()
    t.isFalse(f.env.IsTracking())
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.nothing_to_track'))
end)

t.test('StartTrack: already tracking (and not water-broken) rejects a second call, even for a DIFFERENT track type, without a new round trip', function()
    local f = newTrackingFixture()
    f.queueCallbackResponse({ found = true, coords = vec3(1, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    t.equals(f.callbackCallCount(), 1)

    f.queueCallbackResponse({ found = true, coords = vec3(2, 0, 0) }) -- must never be consulted
    f.env.StartBloodTrack()
    t.equals(f.callbackCallCount(), 1, 'no new round trip -- rejected before ever calling the server')
    t.equals(f.env.GetActiveTrackType(), 'scent', 'the original session must be untouched')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.already_tracking'))
end)

t.test('StopTracking: no-op when not currently tracking (no error, no notify)', function()
    local f = newTrackingFixture()
    f.env.StopTracking()
    t.isFalse(f.env.IsTracking())
    t.equals(#f.notifyCalls, 0)
end)

t.test('StopTracking: clears an active session silently (no confirmation notify, per this file\'s own "cosmetic, low-stakes" framing)', function()
    local f = newTrackingFixture()
    f.queueCallbackResponse({ found = true, coords = vec3(1, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    t.isTrue(f.env.IsTracking())
    f.env.StopTracking()
    t.isFalse(f.env.IsTracking())
    t.isNil(f.env.GetActiveTrackType())
    t.equals(#f.notifyCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION B -- the in-flight guard (startInFlight) and the staleness
-- token (trackRequestGeneration), driven via REENTRANCY: this sandbox's
-- lib.callback.await is otherwise synchronous, so a reentrant call fired
-- from INSIDE the pending callbackAwait (before it returns) models "a
-- second action happens while the first is still awaiting the server" --
-- the exact race these two guards exist to close (see client/tracking.lua's
-- own declaration comment on `startInFlight`/`trackRequestGeneration`).
-- ----------------------------------------------------------------------

t.test('in-flight guard: a Start*Track() call made WHILE another is still awaiting the server is rejected outright -- no second round trip', function()
    local f = newTrackingFixture()
    f.setReentrant(function() f.env.StartBloodTrack() end)
    f.queueCallbackResponse({ found = true, coords = vec3(5, 0, 0), breaksAtWater = false })

    f.env.StartScentTrack()

    t.equals(f.callbackCallCount(), 1, 'the reentrant call must never have triggered a second server round trip')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.starting_in_progress'))
    t.isTrue(f.env.IsTracking())
    t.equals(f.env.GetActiveTrackType(), 'scent', 'the ORIGINAL call must win -- the rejected reentrant call must never overwrite it')
end)

t.test('staleness token: a StopTracking() that runs WHILE a Start*Track() call is still pending makes that call\'s eventual result a no-op, not a resurrection', function()
    local f = newTrackingFixture()
    f.setReentrant(function() f.env.StopTracking() end)
    f.queueCallbackResponse({ found = true, coords = vec3(5, 0, 0), breaksAtWater = false })

    f.env.StartScentTrack()

    t.isFalse(f.env.IsTracking(), 'the pending call\'s stale result must not resurrect a session the player already explicitly stopped')
    t.isNil(f.env.GetActiveTrackType())
end)

t.test('a fresh Start*Track() call succeeds again after a water break, even though trackingState is still non-nil (brokenByWater is NOT treated as "already tracking")', function()
    local f = newTrackingFixture({ waterTrackingDecay = true, waterHeightFn = function() return true end })
    f.env.Config.WaterTrackingDecay.breaksTrail = true
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()
    f.stepOne(1) -- compute thread: detects water immediately (traveled == 0), sets brokenByWater = true
    t.isTrue(f.env.IsTracking(), 'trackingState itself is still non-nil after a water break')

    f.queueCallbackResponse({ found = true, coords = vec3(20, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    t.equals(f.callbackCallCount(), 2, 'a fresh call after a water break must reach the server again, not be rejected as "already tracking"')
    t.equals(#f.notifyCalls, 1, 'only the original trail_lost_water notify -- no spurious already_tracking notify for the fresh call')
end)

-- ----------------------------------------------------------------------
-- SECTION C -- THE STATE/COMPUTE vs. RENDER THREAD SPLIT. The direct
-- proof that the render thread redraws the cached snapshot on EVERY
-- frame it is resumed, independent of the compute thread's own (much
-- slower) tick rate -- this is exactly what fixes the strobe bug this
-- file's own header describes (DrawMarker previously only fired once per
-- ~250ms compute tick, i.e. roughly 1 out of every 15 rendered frames).
-- ----------------------------------------------------------------------

t.test('happy path: the compute thread ticks at TRACK_TICK_MS while active; the render thread draws every marker and runs at Wait(0)', function()
    local f = newTrackingFixture({ waterTrackingDecay = false })
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()

    f.stepOne(1) -- compute thread: builds markers from (0,0,0) toward (10,0,0), spaced by Config.Tracking.Scent.markerSpacing
    local markerSpacing = f.env.Config.Tracking.Scent.markerSpacing
    local expectedMarkerCount = math.floor(10 / markerSpacing) + 1 -- traveled = 0, spacing, 2*spacing, ... while < 10
    t.equals(f.waitLog[1], 250, 'the compute thread must tick at the fast (active) rate, TRACK_TICK_MS, while a session is live')

    f.stepOne(2) -- render thread's first pass
    t.equals(#f.drawMarkerCalls, expectedMarkerCount, 'every cached marker must be drawn')
    t.equals(f.waitLog[2], 0, 'the render thread must run at Wait(0) while there is something to draw')
end)

t.test('REGRESSION LOCK-IN: the render thread redraws the SAME cached trail on repeated resumes WITHOUT the compute thread re-ticking -- this is the fix for the exact strobe bug this file\'s header describes', function()
    local f = newTrackingFixture({ waterTrackingDecay = false })
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()

    f.stepOne(1) -- ONE compute pass -- caches the trail
    local markerSpacing = f.env.Config.Tracking.Scent.markerSpacing
    local expectedMarkerCount = math.floor(10 / markerSpacing) + 1

    -- Three separate render-thread resumes modeling three separate
    -- rendered game frames landing inside the SAME ~250ms compute-tick
    -- window -- the compute thread (threads[1]) is never touched again in
    -- this test.
    f.stepOne(2)
    f.stepOne(2)
    f.stepOne(2)

    t.equals(#f.drawMarkerCalls, expectedMarkerCount * 3,
        'the render thread must redraw the full cached trail on EVERY frame it is resumed -- the old, buggy implementation only called DrawMarker once per compute tick, which is exactly the "1 out of ~15 rendered frames" strobe this split fixes')
end)

-- ----------------------------------------------------------------------
-- SECTION D -- THE RENDER-THREAD IDLE-PATH REGRESSION, THIS TASK'S TOP
-- PRIORITY: `if currentTrailMarkers and #currentTrailMarkers > 0 then`,
-- proven for BOTH the plain-nil case (untracked) and the empty-but-present
-- `{}` case (a hard water break detected at traveled == 0, the exact
-- scenario that produced the bug -- see currentTrailMarkers' own
-- declaration comment in client/tracking.lua).
-- ----------------------------------------------------------------------

t.test('render idle path, NIL case: never started tracking at all -- zero draws, render thread idles at TRACK_RENDER_IDLE_TICK_MS', function()
    local f = newTrackingFixture()
    f.step() -- one pass of every thread
    t.equals(#f.drawMarkerCalls, 0)
    t.equals(f.waitLog[2], 250, 'the render thread must idle (NOT Wait(0)) when there is nothing to draw')
end)

t.test('render idle path, EMPTY-TABLE case (the actual regression): a hard water break detected at traveled == 0 hands off `{}`, not nil -- the render thread must still idle, drawing nothing', function()
    local f = newTrackingFixture({ waterTrackingDecay = true, waterHeightFn = function() return true end }) -- water at EVERY sampled point, including the very first (traveled == 0)
    f.env.Config.WaterTrackingDecay.breaksTrail = true -- explicit, not relying on config.lua's shipped value
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1) -- compute thread: water found at traveled == 0 -> brokenByWater = true, currentTrailMarkers = {} (present, EMPTY)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.trail_lost_water'))

    f.stepOne(2) -- render thread's FIRST resume -- must treat `{}` as "nothing to draw", not as truthy
    t.equals(#f.drawMarkerCalls, 0, 'an empty-but-present markers table must never be drawn from')
    t.equals(f.waitLog[2], 250,
        'THE REGRESSION: the render thread must idle here. The old `if currentTrailMarkers then` check treated `{}` as truthy and spun this thread at Wait(0) despite the for-loop below it having nothing to iterate')
end)

t.test('water break clears the trail on the NEXT compute tick -- both the state (currentTrailMarkers -> nil) and the render idle path stay proven together', function()
    local f = newTrackingFixture({ waterTrackingDecay = true, waterHeightFn = function() return true end })
    f.env.Config.WaterTrackingDecay.breaksTrail = true
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1) -- tick 1: break detected, currentTrailMarkers = {} (see previous test)
    f.stepOne(2) -- render pass over the {} snapshot -- zero draws

    f.stepOne(1) -- tick 2: IsTracking() is still true, but brokenByWater is now true too -> the outer `and not brokenByWater` guard is false -> currentTrailMarkers = nil (the idle-cleanup branch)
    t.equals(f.waitLog[1], 1000, 'the compute thread itself must fall back to its slow/idle tick rate once broken -- it is no longer actively tracking')

    f.stepOne(2) -- render pass over nil -- still zero draws
    t.equals(#f.drawMarkerCalls, 0, 'across BOTH the empty-table tick and the following nil tick, the render thread must never have drawn anything -- the trail is genuinely gone, not just invisible by coincidence')
    t.equals(f.waitLog[2], 250)

    -- No auto-resume: a further compute tick with nothing changed must not
    -- resurrect the trail either -- a fresh Start*Track() call is required,
    -- per this file's own §11.5 "does not silently resume" framing.
    f.stepOne(1)
    f.stepOne(2)
    t.equals(#f.drawMarkerCalls, 0)
end)

t.test('a SOFT water break (breaksTrail == false) still renders the partial line up to the crossing, and fades (lower alpha) past it, WITHOUT ever hard-stopping the trail', function()
    local f = newTrackingFixture({
        waterTrackingDecay = true,
        waterHeightFn = function(x, y, z) return x >= 6.0 end, -- water starts at x == 6
    })
    f.env.Config.WaterTrackingDecay.breaksTrail = false
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(9, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1)
    t.equals(#f.notifyCalls, 0, 'a SOFT break must never fire the hard trail_lost_water notify')

    f.stepOne(2)
    t.isTrue(#f.drawMarkerCalls > 0, 'a soft break must keep rendering past the crossing, never hard-stop the trail')

    -- DrawMarker's alpha argument is position 17 in client/tracking.lua's
    -- own DrawTrailMarker call (type,x,y,z, dir x3, rot x3, scale x3, r,g,b,a, ...).
    -- Compared RELATIVE to each other (never a hardcoded literal copy of
    -- this file's own private TRAIL_MARKER_COLOR.a / _UNDERWATER_ALPHA
    -- constants, which this spec has no access to and must not guess at).
    local firstAlpha, lastAlpha = f.drawMarkerCalls[1][17], f.drawMarkerCalls[#f.drawMarkerCalls][17]
    t.isTrue(lastAlpha < firstAlpha, 'a marker past the water crossing must render at a visibly lower alpha than one before it')
end)

-- ----------------------------------------------------------------------
-- SECTION E -- OWN-DEATH EXIT PATH (compute thread). Distinct file, but
-- the SAME class of fix as client/wellbeing.lua's InjuryLimping own-death
-- guard: a dead K9 must not keep recomputing/rendering a trail from a
-- stale position, and must not silently resume on respawn.
-- ----------------------------------------------------------------------

t.test('own-death: the compute thread stops tracking (and the render thread goes idle) the instant the K9\'s own ped is dead', function()
    local f = newTrackingFixture({ waterTrackingDecay = false })
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    f.stepOne(1)
    t.isTrue(#f.drawMarkerCalls == 0, 'sanity: no render pass has run yet')

    f.setPedDead(true)
    f.stepOne(1) -- compute thread: IsEntityDead(myPed) is now true -> StopTracking()
    t.isFalse(f.env.IsTracking())
    t.equals(f.waitLog[1], 1000, 'must fall back to the idle tick rate, not keep ticking at TRACK_TICK_MS for a dead ped')

    f.stepOne(2)
    t.equals(#f.drawMarkerCalls, 0, 'the render thread must never have drawn a "trail" computed from a dead ped\'s position')
    t.equals(f.waitLog[2], 250)
end)

-- ----------------------------------------------------------------------
-- SECTION F -- THE `source ~= 65535` ORIGIN GUARD: DOES NOT APPLY TO
-- THIS FILE. See this file's own header, item 4, for the full writeup of
-- why this is a genuine scope deviation, disclosed rather than papered
-- over with a fabricated test.
-- ----------------------------------------------------------------------

t.test('DISCLOSED SCOPE FINDING: client/tracking.lua registers no server->client net event at all -- there is no source ~= 65535 guard anywhere in this file to test', function()
    local f = newTrackingFixture()
    -- This fixture never provides a RegisterNetEvent stub anywhere above.
    -- If client/tracking.lua tried to call it at load time, Sandbox.loadInto
    -- above (inside newTrackingFixture) would already have thrown "attempt
    -- to call a nil value (global 'RegisterNetEvent')" before this test
    -- body ever ran. Every other test in this file already loads this same
    -- file the same way and exercises it end to end (StartTrack, the
    -- compute/render threads, the gunpowder/blood capture threads below) --
    -- reaching this assertion at all, across this file's entire test run,
    -- IS the proof.
    t.isNil(f.env.RegisterNetEvent, 'this fixture deliberately never stubs RegisterNetEvent -- its absence, combined with every other test in this file successfully loading and exercising the real file, confirms no handler is ever registered')
end)

-- ----------------------------------------------------------------------
-- SECTION G -- Blood capture (gameEventTriggered) and Gunpowder capture
-- (IsPedShooting debounce) threads. Lower priority per this task's own
-- brief, but cheap given the fixture already built above, and real,
-- previously-uncovered logic.
-- ----------------------------------------------------------------------

t.test('blood capture: relays relayDamageEvent only when BloodTracking is on AND the local player is the victim', function()
    local f = newTrackingFixture({ bloodTracking = true })
    local myPed = 1

    f.triggerGameEvent('SomeUnrelatedEvent', { myPed })
    t.equals(#f.triggerServerEventCalls, 0, 'an unrelated game event must be ignored entirely')

    f.triggerGameEvent('CEventNetworkEntityDamage', { 999 }) -- someone ELSE is the victim
    t.equals(#f.triggerServerEventCalls, 0, 'must only relay when WE are the victim')

    f.triggerGameEvent('CEventNetworkEntityDamage', { myPed })
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:relayDamageEvent')
    t.equals(#f.triggerServerEventCalls[1].args, 0, 'no payload -- the server resolves the caller\'s own live coordinates itself')
end)

t.test('blood capture: BloodTracking == false is a real no-op even when we genuinely are the victim', function()
    local f = newTrackingFixture({ bloodTracking = false })
    f.triggerGameEvent('CEventNetworkEntityDamage', { 1 })
    t.equals(#f.triggerServerEventCalls, 0)
end)

t.test('gunpowder capture: relays relayWeaponFire on a false->true shooting transition, not on every tick while sustained', function()
    local f = newTrackingFixture({ gunpowderSniffing = true })
    f.stepOne(3) -- prime: not shooting yet
    t.equals(#f.triggerServerEventCalls, 0)

    f.setPedShooting(true)
    f.stepOne(3) -- transition false -> true
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:relayWeaponFire')

    f.stepOne(3) -- still shooting -- must NOT refire
    t.equals(#f.triggerServerEventCalls, 1)

    f.setPedShooting(false)
    f.stepOne(3)
    f.setPedShooting(true)
    f.stepOne(3) -- a SECOND false->true transition must fire again
    t.equals(#f.triggerServerEventCalls, 2)
end)

t.test('gunpowder capture: GunpowderSniffing == false never relays regardless of shooting state, and idles at the slow poll rate', function()
    local f = newTrackingFixture({ gunpowderSniffing = false })
    f.setPedShooting(true)
    f.stepOne(3)
    f.stepOne(3)
    t.equals(#f.triggerServerEventCalls, 0)
    t.equals(f.waitLog[3], 1000, 'must idle at GUNPOWDER_IDLE_POLL_MS while the feature is off')
end)

-- ----------------------------------------------------------------------
-- SECTION H -- PHASE 4 XP arrival trigger (Config.Features.XPProgression).
-- Bonus coverage: cheap given the existing fixture, real previously-
-- uncovered logic, and directly adjacent to the water-break tests above.
-- ----------------------------------------------------------------------

t.test('XP arrival trigger: fires reportTrackSourceArrival exactly once when live distance drops to/below Config.XP.trackArrivalRadius, never again while lingering there', function()
    local f = newTrackingFixture({ xpProgression = true, waterTrackingDecay = false })
    local arrivalRadius = f.env.Config.XP.trackArrivalRadius
    f.setPedCoords(vec3(0, 0, 0))
    -- Placed just inside the arrival radius from tick one.
    f.queueCallbackResponse({ found = true, coords = vec3(arrivalRadius - 0.1, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()

    f.stepOne(1)
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:reportTrackSourceArrival')
    t.equals(#f.triggerServerEventCalls[1].args, 0, 'a trigger only -- never a claimed distance/coordinate the server would have to trust')

    f.stepOne(1) -- still within radius, still tracking -- must not refire
    t.equals(#f.triggerServerEventCalls, 1)
end)

t.test('XP arrival trigger: never fires at all when XPProgression is off, even well within the arrival radius', function()
    local f = newTrackingFixture({ xpProgression = false, waterTrackingDecay = false })
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(0.05, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    f.stepOne(1)
    t.equals(#f.triggerServerEventCalls, 0)
end)

os.exit(t.summary())
