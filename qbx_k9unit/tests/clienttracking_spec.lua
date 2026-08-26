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
    5. WaterTrackingDecay's PER-PERSON BLOCK (client/featureblocks.lua
       hand-off item 1, added a LATER pass) -- section D2. The check was
       folded directly into the compute thread's own ALREADY-existing
       per-tick condition, so these tests prove the fold's correctness
       (blocked suppresses even a hard, water-everywhere break; unblocked
       doesn't; a block arriving/clearing mid-session takes effect within
       one tick either way; fails open when client/featureblocks.lua isn't
       loaded) rather than any new thread/event machinery -- there isn't
       any. See section D2's own header for what does NOT apply here
       (no body/model exemption, no new onResourceStop surface).

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

--- @param opts { hasK9Access: boolean?, canShowK9UI: boolean?, omitLegacyUIGlobals: boolean?, waterTrackingDecay: boolean?, xpProgression: boolean?, gunpowderSniffing: boolean?, bloodTracking: boolean?, featureBlocksAvailable: boolean?, blockedFeatures: table? }?
local function newTrackingFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    -- HasK9Access() (ANY-PED SWEEP FIX, this pass) -- the REAL gate
    -- StartTrack() now calls, stubbed independently as its own raw boolean
    -- rather than derived from CanShowK9UI() below, since StartTrack() no
    -- longer calls (or transitively depends on) CanShowK9UI()/IsK9Role()/
    -- IsOwnModelK9() at all -- see "must not call the composed UI gate"
    -- regression test below, which deliberately leaves ALL THREE of those
    -- undefined to prove it.
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end
    local function HasK9Access() return hasK9Access end

    -- CanShowK9UI() -- kept as a SEPARATE, independently-controllable stub
    -- purely for the gunpowder-capture-thread tests further below (section
    -- G), which pin it to prove that thread is population-wide and does
    -- NOT gate on it. StartTrack() itself no longer calls this at all (see
    -- HasK9Access() above) -- do not reuse this value as a stand-in for the
    -- StartTrack() gate again; that exact substitution (a single stubbed
    -- CanShowK9UI() boolean standing in for what the real client/main.lua
    -- computes as `IsK9Role() and HasK9Access()` / `IsOwnModelK9() and
    -- HasK9Access()`) is what hid the original "server allows it, client's
    -- own gate refuses it" bug this fixture now exists to catch.
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

    -- PER-PERSON BLOCK (client/featureblocks.lua hand-off item 1,
    -- WaterTrackingDecay, added this pass) -- same "controllable stand-in,
    -- soft dependency" convention clientagility_spec.lua/
    -- clientradial_spec.lua/clientmovement_spec.lua already use for the
    -- identical global. `featureBlocksAvailable` defaults to true (this
    -- global is injected); set opts.featureBlocksAvailable = false to prove
    -- the fail-open path never calls a nil function.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end

    local overrides = {
        HasK9Access = HasK9Access,
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
    if featureBlocksAvailable then
        overrides.IsK9FeatureBlocked = IsK9FeatureBlocked
    end

    -- `omitLegacyUIGlobals` (default false): when true, CanShowK9UI is
    -- deliberately left OUT of the sandbox entirely (env.CanShowK9UI stays
    -- nil, same as the never-injected IsK9Role/IsOwnModelK9) -- used by the
    -- one regression test below that proves StartTrack() genuinely never
    -- calls any of the three: if a future edit reintroduces such a call,
    -- that test fails LOUDLY (an "attempt to call a nil value" error), not
    -- silently via a stubbed boolean that happens to agree.
    if not opts.omitLegacyUIGlobals then
        overrides.CanShowK9UI = CanShowK9UI
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- Explicit per this task's own instruction: every flag this file reads
    -- is set here, per-fixture, never left to whatever config.lua ships
    -- with (config.lua's Config.Features table currently defaults nearly
    -- every flag to true, with rare individual exceptions -- these tests
    -- must keep passing however that shipped default moves, and this
    -- comment deliberately does not cite the current flag count, which
    -- changes as features are added).
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
        setHasK9Access = function(v) hasK9Access = v end,
        denyCallCount = function() return denyCalls end,
        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        setReentrant = function(fn) reentrantFn = fn end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,

        setPedCoords = function(v) pedCoords = v end,
        setPedDead = function(v) pedDead = v end,
        setWaterHeightFn = function(fn) waterHeightFn = fn end,
        setPedShooting = function(v) isPedShooting = v end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,

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
-- SECTION A -- StartTrack()'s own guards: HasK9Access, already-tracking,
-- not-found. These gate everything else below, so proven first.
--
-- ANY-PED SWEEP FIX (coder-frontend, this pass): StartTrack() used to gate
-- on CanShowK9UI() -- strictly narrower than server/tracking.lua's own
-- findTrackableSource, which checks HasK9Access(source) alone -- so a
-- role-holder the server would allow (e.g. K9 access via High Command/
-- autoAccessGrade, on a non-K9 body) could be refused by their own client.
-- Fixed to gate on HasK9Access() alone; see StartTrack()'s own doc comment
-- in client/tracking.lua for the full writeup.
-- ----------------------------------------------------------------------

t.test('StartScentTrack: HasK9Access() false denies access and never even calls the server callback', function()
    local f = newTrackingFixture({ hasK9Access = false })
    f.env.StartScentTrack()
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
    t.isFalse(f.env.IsTracking())
end)

-- REGRESSION -- pins the exact bug this pass fixed: a role-holder whose
-- K9 access comes via server/certifications.lua's HasK9Access() High
-- Command/autoAccessGrade bypass is NOT a member of IsK9Role()'s
-- deliberately-narrower set (server/appearance.lua's own header), and is
-- not necessarily on a recognized K9 model either -- so the OLD
-- CanShowK9UI() gate (`IsK9Role() and HasK9Access()` at the
-- requireK9ModelForRole default, or `IsOwnModelK9() and HasK9Access()`
-- otherwise) would have answered false for this exact caller even though
-- HasK9Access() itself, and therefore server/tracking.lua's own
-- findTrackableSource, both answer true. `omitLegacyUIGlobals = true`
-- deliberately leaves CanShowK9UI/IsK9Role/IsOwnModelK9 completely
-- undefined in this sandbox (not merely stubbed false) -- exercising the
-- REAL path, not a fixture standing in for it: if StartTrack() ever again
-- called any of those three, this test would fail with "attempt to call a
-- nil value", not silently pass on a coincidentally-agreeing stub.
t.test('StartScentTrack: a HasK9Access()-true caller succeeds even with CanShowK9UI()/IsK9Role()/IsOwnModelK9() entirely undefined (never called)', function()
    local f = newTrackingFixture({ hasK9Access = true, omitLegacyUIGlobals = true })
    t.isNil(f.env.CanShowK9UI, 'sanity: CanShowK9UI must be genuinely absent from this sandbox, not merely false')
    t.isNil(f.env.IsK9Role)
    t.isNil(f.env.IsOwnModelK9)

    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()

    t.equals(f.denyCallCount(), 0)
    t.equals(f.callbackCallCount(), 1, 'the request must have reached the real findTrackableSource callback')
    t.isTrue(f.env.IsTracking())
    t.equals(f.env.GetActiveTrackType(), 'scent')
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
-- SECTION D2 -- PER-PERSON BLOCK (client/featureblocks.lua hand-off item
-- 1, WaterTrackingDecay), added THIS pass. This is the trivial hand-off
-- item: the check was folded directly into the compute thread's ALREADY
-- existing per-tick condition (see client/tracking.lua's own comment right
-- above the edited `if`), so every test below simply proves that fold
-- behaves correctly -- no new thread, no new event, nothing else to wire.
--
-- NOT APPLICABLE HERE, stated plainly rather than silently omitted:
--   - "the human-body exemption still holds" -- there is no body/model
--     concept anywhere in the water-crossing check at all (it's pure
--     coordinate/water-height geometry along the resolved trail, unrelated
--     to which ped model is doing the tracking) -- nothing to test.
--   - "onResourceStop releases" -- this fold adds no new thread, no new
--     persistent native state, and no new cleanup surface of any kind; the
--     existing compute thread's own lifecycle (and this file's own
--     "SECTION F" note on why no source-origin guard applies here either)
--     is entirely unchanged by this edit.
-- ----------------------------------------------------------------------

t.test('BLOCKED FROM THE START: WaterTrackingDecay blocked for this person -- a hard water-break condition (water covers the ENTIRE remaining path) never fires at all; the full trail renders exactly as if the global flag were disabled', function()
    local f = newTrackingFixture({
        waterTrackingDecay = true,
        waterHeightFn = function() return true end, -- water everywhere, including traveled == 0
        blockedFeatures = { WaterTrackingDecay = true },
    })
    f.env.Config.WaterTrackingDecay.breaksTrail = true
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1)
    t.equals(#f.notifyCalls, 0, 'blocked: no trail_lost_water notify even though water genuinely covers the whole path')
    t.isTrue(f.env.IsTracking(), 'blocked: the session stays genuinely live, never marked broken')

    f.stepOne(2)
    local markerSpacing = f.env.Config.Tracking.Scent.markerSpacing
    local expectedMarkerCount = math.floor(10 / markerSpacing) + 1
    t.equals(#f.drawMarkerCalls, expectedMarkerCount, 'the FULL trail renders -- water is fully invisible to this trail while blocked')
end)

t.test('UNBLOCKED BASELINE (direct comparison with the blocked test above): the SAME hard water-break condition, with no block at all, breaks the trail exactly as section D already proves', function()
    local f = newTrackingFixture({
        waterTrackingDecay = true,
        waterHeightFn = function() return true end,
    })
    f.env.Config.WaterTrackingDecay.breaksTrail = true
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.trail_lost_water'))
end)

t.test('A BLOCK ARRIVING MID-SESSION TAKES EFFECT: an already-live SOFT water break (fading alpha past the crossing) reverts to full, uniform alpha on the VERY NEXT compute tick once WaterTrackingDecay is blocked for this person', function()
    local f = newTrackingFixture({
        waterTrackingDecay = true,
        waterHeightFn = function(x, y, z) return x >= 6.0 end, -- water starts at x == 6
    })
    f.env.Config.WaterTrackingDecay.breaksTrail = false
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(9, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1) -- unblocked compute tick: crossing detected at x=6
    f.stepOne(2) -- render pass over the faded trail
    local beforeFirstAlpha, beforeLastAlpha = f.drawMarkerCalls[1][17], f.drawMarkerCalls[#f.drawMarkerCalls][17]
    t.isTrue(beforeLastAlpha < beforeFirstAlpha, 'sanity: the fade is genuinely present before the block, matching the plain SOFT-break test above')

    f.setBlocked('WaterTrackingDecay', true)
    f.stepOne(1) -- the SAME tick a real featureBlocksSync would have arrived on -- water is now fully invisible to this trail
    local countBeforeSecondRender = #f.drawMarkerCalls
    f.stepOne(2)
    local newFirstAlpha, newLastAlpha = f.drawMarkerCalls[countBeforeSecondRender + 1][17], f.drawMarkerCalls[#f.drawMarkerCalls][17]
    t.equals(newFirstAlpha, newLastAlpha, 'once blocked, the whole line renders at the SAME alpha -- no fade at all, exactly as if WaterTrackingDecay were globally disabled')
end)

t.test('A BLOCK CLEARING MID-SESSION RELEASES: a per-person block suppresses a hard water break for as long as it is live, and the break fires on the VERY NEXT tick once the block clears', function()
    local f = newTrackingFixture({
        waterTrackingDecay = true,
        waterHeightFn = function() return true end, -- water everywhere, including traveled == 0
        blockedFeatures = { WaterTrackingDecay = true },
    })
    f.env.Config.WaterTrackingDecay.breaksTrail = true
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1) -- blocked: the hard-break condition is real (water everywhere) but must never fire
    t.equals(#f.notifyCalls, 0)
    t.isTrue(f.env.IsTracking())

    f.setBlocked('WaterTrackingDecay', false)
    f.stepOne(1) -- unblocked now -- the SAME real water condition must break the trail on this very next tick
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('tracking.trail_lost_water'))
end)

t.test('FAILS OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- the hard water break still fires normally, never silently suppressed', function()
    local f = newTrackingFixture({
        waterTrackingDecay = true,
        waterHeightFn = function() return true end,
        featureBlocksAvailable = false,
    })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.env.Config.WaterTrackingDecay.breaksTrail = true
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(10, 0, 0) })
    f.env.StartScentTrack()

    f.stepOne(1)
    t.equals(#f.notifyCalls, 1, 'must behave exactly as before this pass -- unblockable, never an error')
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

-- PERF-AUDIT FINDING (coder-frontend, this pass) -- see client/tracking.lua's
-- own comment directly above its gunpowder CreateThread for the full
-- writeup. A role/model gate on this thread's poll (CanShowK9UI() or
-- IsOwnModelK9()) was considered and REJECTED: server/tracking.lua's
-- relayWeaponFire handler has NO HasK9Access(source) check on the sender --
-- ANY connected player, not just a K9 handler, is expected to relay their
-- own shot so a K9 handler can LATER search for it via findTrackableSource
-- (the ONLY point in this mechanic actually gated on K9 status). The two
-- tests below exercise the REAL condition this thread branches on
-- (Config.Features.GunpowderSniffing only) with CanShowK9UI() pinned to
-- FALSE for the whole test -- per this task's own instruction not to stub
-- away the very thing under test -- proving the poll/relay path keeps
-- working for a non-handler. A fixture that only ever ran this thread with
-- the fixture's canShowK9UI default (true) would not catch a future
-- regression that wrongly wires this thread's population to that check.
t.test('gunpowder capture: CanShowK9UI() == false does NOT gate this thread -- still polls at the active rate (population-wide capture by design, not a role/access check)', function()
    local f = newTrackingFixture({ gunpowderSniffing = true, canShowK9UI = false })
    f.stepOne(3) -- prime: not shooting yet
    t.equals(f.waitLog[3], 200, 'must poll at GUNPOWDER_POLL_MS for a non-handler too -- Config.Features.GunpowderSniffing alone gates this thread')
    t.equals(#f.triggerServerEventCalls, 0)
end)

t.test('gunpowder capture: CanShowK9UI() == false still relays a non-handler\'s own false->true shooting transition', function()
    local f = newTrackingFixture({ gunpowderSniffing = true, canShowK9UI = false })
    f.stepOne(3) -- prime: not shooting yet
    t.equals(#f.triggerServerEventCalls, 0)

    f.setPedShooting(true)
    f.stepOne(3) -- false -> true transition
    t.equals(#f.triggerServerEventCalls, 1, 'a non-handler\'s own shot must still be relayed -- this is exactly the population the mechanic exists to make trackable')
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:relayWeaponFire')
    t.equals(#f.triggerServerEventCalls[1].args, 0, 'no payload, same as the handler-eligible case')
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

-- ASSERTION INVERTED, deliberately. This used to assert the arrival event
-- "never fires at all when XPProgression is off", which pinned a real bug
-- rather than a requirement. That event began life as this file's own XP
-- trigger, so gating the SEND on the XP flag looked reasonable -- until it
-- gained a second consumer. server/findalert.lua listens to the same event
-- for its trail-arrival bark-and-sit reaction, so an operator who turned XP
-- off silently lost that reaction while find alerts kept working for
-- searches. It presented as "find alerts work for searches but not for
-- tracking", with nothing connecting it to an XP setting.
--
-- The send is now unconditional and the gate lives where it belongs: on the
-- thing being gated. server/tracking.lua's own handler returns early on
-- Config.Features.XPProgression, so no XP is minted with the flag off --
-- see tests/tracking_spec.lua for that half. The client's job is to report
-- arrival; deciding what arrival is worth is the server's.
t.test('XP arrival trigger: still fires with XPProgression off, because a second consumer (find alerts) needs it -- the XP decision belongs to the server, not to whether the event is sent', function()
    local f = newTrackingFixture({ xpProgression = false, waterTrackingDecay = false })
    f.setPedCoords(vec3(0, 0, 0))
    f.queueCallbackResponse({ found = true, coords = vec3(0.05, 0, 0), breaksAtWater = false })
    f.env.StartScentTrack()
    f.stepOne(1)
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:reportTrackSourceArrival')
    t.equals(#f.triggerServerEventCalls[1].args, 0, 'still a bare trigger -- never a claimed distance the server would have to trust')

    f.stepOne(1) -- lingering inside the radius must still not refire
    t.equals(#f.triggerServerEventCalls, 1)
end)

os.exit(t.summary())
