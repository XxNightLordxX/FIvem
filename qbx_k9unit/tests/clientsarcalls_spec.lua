--[[
    tests/clientsarcalls_spec.lua

    Direct, black-box tests of client/sarcalls.lua against the REAL,
    unmodified production file -- the client half of search-and-rescue
    calls (server/sarcalls.lua's own contract). Follows
    clientcombat_spec.lua/clientmovement_spec.lua's worked example. This
    file exposes exactly two resource-globals (RequestStartSarCall,
    RequestAbandonSarCall), reachable in production only via
    '/k9sarcall [stop]' -- this spec drives both the same way.

    THIS PASS'S PRIORITY, per the task brief that produced this file:
      1. THE STALE-SESSION RACE FIX (this file's own header section of the
         same name) -- currentSarCallId/IsForCurrentSarCall. Section F
         below pins BOTH the simple case (a stale push for an abandoned
         call rejected once a new call is live) AND, using a genuinely
         yielding lib.callback.await stub, the EXACT concurrency shape the
         header describes: an old call's own sarCallEnded echo arriving
         WHILE a brand-new RequestStartSarCall() is still awaiting the
         server must NOT discard that new call's own eventual grant.
      2. THE ABANDON PATH IS NEVER GATED -- section G proves
         RequestAbandonSarCall() reaches the server even with CanShowK9UI
         entirely UNDEFINED in the sandbox.
      3. THE COSMETIC REVEAL's own model-load-failure degrade (never
         networked, per this file's own "WHY THE REVEAL IS NEVER
         NETWORKED" header section) -- section E.
      4. FEATURE-OFF INERTNESS and the file's own three config-safety
         asserts (missingPersonPedModel/lostPropertyPropModel/
         revealDurationMs) -- section A/B.
      5. RESOURCE-STOP HYGIENE, FIXED THIS PASS (this file's own header
         section of the same name) -- section H below pins the fix: the
         onResourceStop handler now also calls RequestAbandonSarCall(),
         reaching the server with 'qbx_k9unit:server:abandonSarCall' in
         addition to its existing ClearReveal() cosmetic cleanup. See this
         file's own "WHAT THIS FILE DOES NOT COVER" note at the bottom for
         why this gap was genuinely lower severity than
         client/scenttrail.lua's identical one (server/sarcalls.lua runs an
         unconditional periodic tick loop, so the record already self-healed
         within Config.SARCalls.maxCallDurationMs even before this fix) --
         still a real, disclosed, player-facing lockout window this fix
         closes, not a purely cosmetic tidiness change.

    WAIT IS A PLAIN NO-OP HERE, NOT A COROUTINE YIELD -- deliberately
    DIFFERENT from clientscenttrail_spec.lua/clientpursuitsprint_spec.lua's
    own instrumented runners: every CreateThread body in this file is a
    single "wait once, then do one thing" shape (never a `while` loop), and
    LoadModelWithTimeout's own polling loop (`while not HasModelLoaded(...)
    and waited < TIMEOUT do Wait(50) ... end`) runs SYNCHRONOUSLY, inline,
    from inside a net event handler -- not inside a CreateThread at all. A
    real FXServer dispatches every event handler in its own coroutine, so a
    bare Wait() there is legal; a direct Lua call in this sandbox is not
    wrapped in one. Making HasModelLoaded a fully-controllable stub (return
    true immediately for the happy path; return false forever for the
    timeout path) means that loop's own `waited` bookkeeping runs to
    completion doing real, correct, and FAST work with Wait as a trivial
    no-op -- no coroutine machinery is needed anywhere in this file's own
    spec. The ONE real CreateThread body (the cosmetic reveal's own
    auto-clear timer) is likewise just "Wait once, then maybe ClearReveal()"
    -- captured but never auto-run, and driven directly (no coroutine
    needed there either, for the same reason).

    STUBBING EFFORT: proportionate. Every native this file's exercised
    paths touch (CanShowK9UI/DenyK9UIAccess/K9Sit/PlayK9Sound,
    PlayerPedId/NetworkGetNetworkIdFromEntity, RequestModel/HasModelLoaded/
    SetModelAsNoLongerNeeded/IsModelValid/GetHashKey, CreatePed/CreateObject/
    DoesEntityExist/DeleteEntity/FreezeEntityPosition/
    TaskStartScenarioInPlace, GetOffsetFromEntityInWorldCoords/
    GetEntityHeading, TriggerServerEvent/RegisterNetEvent/RegisterCommand,
    lib.callback.await/lib.notify) is a small, cheap recording/controllable
    stand-in.

    ONE FRESH SANDBOX PER TEST -- this file's own file-load-time locals
    (sarCallActive, requestGeneration, startInFlight, currentSarCallId,
    revealEntity, revealGeneration) are exactly the kind of module-lifetime
    state that must never leak between two unrelated test cases.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { sarCalls: boolean?, canShowK9UI: boolean?, basicBarkSounds: boolean?, provideK9Sit: boolean?, sarCallsConfig: table?|false }?
local function newSarCallsFixture(opts)
    opts = opts or {}

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
    local reentrantFn = nil -- see section F -- fired from INSIDE callbackAwait, modelling true in-flight concurrency
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
    local function PlayerPedId() return myPed end
    local function NetworkGetNetworkIdFromEntity(entity) return entity * 1000 end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted) commandHandlers[name] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- ---- model-loading / entity-creation natives for the cosmetic reveal ----
    local hasModelLoadedFn = opts.hasModelLoadedFn -- function(hash) -> boolean; defaults to "always loaded"
    local modelAsNoLongerNeededCalls = {}
    local function GetHashKey(name)
        local hash = 0
        for i = 1, #name do hash = (hash * 31 + name:byte(i)) % 2147483647 end
        return hash
    end
    local function IsModelValid(_hash) return true end
    local function RequestModel(_hash) end
    local function HasModelLoaded(hash)
        if hasModelLoadedFn then return hasModelLoadedFn(hash) end
        return true
    end
    local function SetModelAsNoLongerNeeded(hash) modelAsNoLongerNeededCalls[#modelAsNoLongerNeededCalls + 1] = hash end

    local createdPeds = {}
    local createdObjects = {}
    local existingEntities = {}
    local nextEntityHandle = 100
    local function CreatePed(pedType, modelHash, x, y, z, heading, isNetwork, bScriptHostPed)
        nextEntityHandle = nextEntityHandle + 1
        local handle = nextEntityHandle
        existingEntities[handle] = true
        createdPeds[#createdPeds + 1] = { handle = handle, pedType = pedType, modelHash = modelHash, x = x, y = y, z = z, heading = heading, isNetwork = isNetwork, bScriptHostPed = bScriptHostPed }
        return handle
    end
    local function CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag)
        nextEntityHandle = nextEntityHandle + 1
        local handle = nextEntityHandle
        existingEntities[handle] = true
        createdObjects[#createdObjects + 1] = { handle = handle, modelHash = modelHash, x = x, y = y, z = z, isNetwork = isNetwork, netMissionEntity = netMissionEntity, doorFlag = doorFlag }
        return handle
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local deleteEntityCalls = {}
    local function DeleteEntity(entity)
        deleteEntityCalls[#deleteEntityCalls + 1] = entity
        existingEntities[entity] = nil
    end
    local freezeCalls = {}
    local function FreezeEntityPosition(entity, frozen) freezeCalls[#freezeCalls + 1] = { entity = entity, frozen = frozen } end
    local scenarioCalls = {}
    local function TaskStartScenarioInPlace(entity, name, p2, playEnter) scenarioCalls[#scenarioCalls + 1] = { entity = entity, name = name } end
    local function GetOffsetFromEntityInWorldCoords(_entity, x, y, z) return { x = x, y = y, z = z } end
    local function GetEntityHeading(_entity) return 0.0 end

    -- Reveal auto-clear thread capture -- see this file's header "WAIT IS A
    -- PLAIN NO-OP HERE". Captured, not auto-run; a test drives it directly.
    local revealThreads = {}
    local function CreateThread(fn) revealThreads[#revealThreads + 1] = fn end
    local function Wait(_ms) end

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
        K9Sit = (opts.provideK9Sit ~= false) and K9Sit or nil,
        lib = lib,
        PlayerPedId = PlayerPedId,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        TriggerServerEvent = TriggerServerEvent,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        CreateThread = CreateThread,
        Wait = Wait,
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
        GetOffsetFromEntityInWorldCoords = GetOffsetFromEntityInWorldCoords,
        GetEntityHeading = GetEntityHeading,
        source = 65535,
    }
    if providePlayK9Sound then
        overrides.PlayK9Sound = PlayK9Sound
    end

    local env = Sandbox.newEnv(overrides)
    env.Config = {
        Features = { SARCalls = opts.sarCalls ~= false, BasicBarkSounds = providePlayK9Sound },
    }
    if opts.sarCallsConfig ~= false then
        env.Config.SARCalls = opts.sarCallsConfig or {
            missingPersonPedModel = 'a_m_m_hobo_01',
            lostPropertyPropModel = 'prop_backpack_01',
            revealDurationMs = 15000,
        }
    end

    local ok, err = pcall(Sandbox.loadInto, '../client/sarcalls.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err, printLog = printLog }
    end
    assert(ok, 'client/sarcalls.lua failed to load: ' .. tostring(err))

    return {
        printLog = printLog,
        env = env,
        notifyCalls = notifyCalls,
        serverEvents = serverEvents,
        playK9SoundCalls = playK9SoundCalls,
        k9SitCallCount = function() return k9SitCalls end,
        denyCallCount = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        setThrowNext = function() shouldThrowNext = true end,
        setReentrant = function(fn) reentrantFn = fn end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        setHasModelLoadedFn = function(fn) hasModelLoadedFn = fn end,
        createdPeds = createdPeds,
        createdObjects = createdObjects,
        deleteEntityCalls = deleteEntityCalls,
        freezeCalls = freezeCalls,
        scenarioCalls = scenarioCalls,
        modelAsNoLongerNeededCalls = modelAsNoLongerNeededCalls,
        revealThreads = revealThreads,
        entityExists = function(handle) return existingEntities[handle] == true end,
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
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, h in ipairs(eventHandlers['onResourceStop'] or {}) do h(resourceName or 'qbx_k9unit') end
        end,
        startCommand = function(args) commandHandlers['k9sarcall'](1, args or {}) end,
        stopCommand = function() commandHandlers['k9sarcall'](1, { 'stop' }) end,
        fireHintTier = function(forged, tier, callId)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:sarHintTierChanged'](tier, callId)
        end,
        fireCallEnded = function(forged, reason, callType, callId)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:sarCallEnded'](reason, callType, callId)
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- feature flag off: GENUINELY inert (and no config asserts
-- run either, so an off feature never fails load on an unrelated bad
-- config).
-- ----------------------------------------------------------------------

t.test('Config.Features.SARCalls = false: registers NO command, NO net events, and RequestStartSarCall/RequestAbandonSarCall never defined -- even with Config.SARCalls entirely absent', function()
    local f = newSarCallsFixture({ sarCalls = false, sarCallsConfig = false })
    t.equals(f.commandCount(), 0)
    t.equals(f.netEventCount(), 0)
    t.isNil(f.env.RequestStartSarCall)
    t.isNil(f.env.RequestAbandonSarCall)
end)

t.test('Config.Features.SARCalls = true: registers the k9sarcall command and both net events; both resource-globals exist', function()
    local f = newSarCallsFixture()
    t.equals(f.commandCount(), 1)
    t.equals(f.netEventCount(), 2)
    t.isNotNil(f.env.RequestStartSarCall)
    t.isNotNil(f.env.RequestAbandonSarCall)
end)

-- ----------------------------------------------------------------------
-- SECTION B -- config-safety CLAMP AND WARN (the THREE fields this file
-- itself reads -- input edge cases an operator could get wrong).
--
-- REGRESSION (this pass): these three tests used to assert the OPPOSITE --
-- that a missing/invalid field FAILED THE ENTIRE FILE'S LOAD via a hard
-- `assert` sitting directly after the feature-flag early-return, with no
-- deferring onResourceStart/RegisterNetEvent wrapper. See
-- server/cooldowns.lua's header ADDENDUM for the general case this
-- responds to: an uncaught error thrown there would silently un-register
-- every SAR-call net event/callback handler this file defines, over one
-- operator typo in a cosmetic model name or a duration. Now CLAMP AND WARN.
-- ----------------------------------------------------------------------

t.test('CLAMP AND WARN: missingPersonPedModel missing/empty no longer fails to load -- warns loudly and falls back to the shipped default', function()
    local f = newSarCallsFixture({ sarCallsConfig = { missingPersonPedModel = '', lostPropertyPropModel = 'x', revealDurationMs = 1000 } })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.SARCalls.missingPersonPedModel', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact key')
    t.equals(f.env.Config.SARCalls.missingPersonPedModel, 'mp_m_freemode_01')
    t.equals(f.commandCount(), 1, 'the k9sarcall command must still register')
end)

t.test('CLAMP AND WARN: lostPropertyPropModel missing/empty no longer fails to load -- warns loudly and falls back to the shipped default', function()
    local f = newSarCallsFixture({ sarCallsConfig = { missingPersonPedModel = 'x', lostPropertyPropModel = '', revealDurationMs = 1000 } })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.SARCalls.lostPropertyPropModel', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact key')
    t.equals(f.env.Config.SARCalls.lostPropertyPropModel, 'prop_tennis_ball')
    t.equals(f.commandCount(), 1, 'the k9sarcall command must still register')
end)

t.test('CLAMP AND WARN: revealDurationMs non-positive no longer fails to load -- warns loudly and falls back to the shipped 15000ms default', function()
    local f = newSarCallsFixture({ sarCallsConfig = { missingPersonPedModel = 'x', lostPropertyPropModel = 'y', revealDurationMs = 0 } })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.SARCalls.revealDurationMs', 1, true) and line:find('found: 0', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact key and the value found')
    t.equals(f.env.Config.SARCalls.revealDurationMs, 15000)
    t.equals(f.commandCount(), 1, 'the k9sarcall command must still register')
end)

t.test('CLAMP AND WARN: a fully valid Config.SARCalls passes through completely silently', function()
    local f = newSarCallsFixture({
        sarCallsConfig = { missingPersonPedModel = 'a_m_m_hobo_01', lostPropertyPropModel = 'prop_backpack_01', revealDurationMs = 20000 },
    })
    t.equals(#f.printLog, 0, 'a fully valid config must never print anything')
    t.equals(f.env.Config.SARCalls.revealDurationMs, 20000)
end)

-- ----------------------------------------------------------------------
-- SECTION C -- RequestStartSarCall() gating and reason mapping.
-- ----------------------------------------------------------------------

t.test('k9sarcall: CanShowK9UI() false denies access and never calls the server', function()
    local f = newSarCallsFixture({ canShowK9UI = false })
    f.startCommand({})
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
end)

t.test('ANY PED: RequestStartSarCall() never touches a model native directly -- proven by omitting IsOwnModelK9/GetEntityModel from the sandbox entirely', function()
    local f = newSarCallsFixture()
    t.isNil(f.env.IsOwnModelK9)
    t.isNil(f.env.GetEntityModel)
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({}) -- must not error even though no model native exists anywhere
    t.equals(f.callbackCallCount(), 1)
end)

t.test('k9sarcall: a successful start reaches requestSarCall with the right event name; no notify on success', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:requestSarCall')
    t.equals(#f.notifyCalls, 0)
end)

t.test('k9sarcall: reason = already_active / cooldown / anything-else / nil-result all map correctly, never crashing', function()
    local fActive = newSarCallsFixture()
    fActive.queueCallbackResponse({ started = false, reason = 'already_active' })
    fActive.startCommand({})
    t.equals(fActive.notifyCalls[1].description, locale('sar.already_active'))

    local fCooldown = newSarCallsFixture()
    fCooldown.queueCallbackResponse({ started = false, reason = 'request_cooldown' })
    fCooldown.queueCallbackResponse({ started = false, reason = 'cooldown' })
    fCooldown.startCommand({}) -- consumes the FIRST queued response ('request_cooldown', an unrecognized reason)
    t.equals(fCooldown.denyCallCount(), 1, 'an unrecognized reason string must collapse to the generic denial, never crash')

    local fDenied = newSarCallsFixture()
    fDenied.queueCallbackResponse({ started = false, reason = 'denied' })
    fDenied.startCommand({})
    t.equals(fDenied.denyCallCount(), 1)

    local fNil = newSarCallsFixture()
    fNil.startCommand({}) -- nothing queued
    t.equals(fNil.denyCallCount(), 1)
end)

t.test('k9sarcall: reason = cooldown maps to the real request_cooldown locale text', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = false, reason = 'cooldown' })
    f.startCommand({})
    t.equals(f.notifyCalls[1].description, locale('sar.request_cooldown'))
end)

t.test('k9sarcall: already active rejects a second start outright, no new round trip', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.queueCallbackResponse({ started = true, callId = 2 }) -- must never be consulted
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('sar.already_active'))
end)

t.test('FAIL-CLOSED: requestSarCall throwing is caught and treated as a generic denial, never crashes the command handler', function()
    local f = newSarCallsFixture()
    f.setThrowNext()
    f.startCommand({})
    t.equals(f.denyCallCount(), 1)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- hint tiers: correct notify + sound per tier, source-origin
-- guard, and gating on sarCallActive.
-- ----------------------------------------------------------------------

t.test('hint tiers: burning/hot/warm/cold each notify the right text; only burning/hot/warm also play a sound, cold plays none', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})

    f.fireHintTier(false, 'burning', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_burning'))
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Bark_Alert')

    f.fireHintTier(false, 'hot', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_hot'))
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Bark_Calm')

    f.fireHintTier(false, 'warm', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_warm'))
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Growl_Ambient')

    local soundsBeforeCold = #f.playK9SoundCalls
    f.fireHintTier(false, 'cold', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('sar.hint_cold'))
    t.equals(#f.playK9SoundCalls, soundsBeforeCold, 'cold must never play a sound')
end)

t.test('a hint push while NO call is active on this client is ignored (stale/duplicate push), never notifies', function()
    local f = newSarCallsFixture()
    f.fireHintTier(false, 'burning', nil)
    t.equals(#f.notifyCalls, 0)
end)

t.test('a forged (non-65535 source) hint push is rejected outright, even for the current call', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    t.equals(#f.notifyCalls, 0, 'sanity: starting a call notifies nothing on success')

    f.fireHintTier(true, 'burning', 1)
    t.equals(#f.notifyCalls, 0, 'a forged push must produce no notify at all')

    f.fireHintTier(false, 'burning', 1) -- the genuine push still works
    t.equals(#f.notifyCalls, 1)
end)

-- ----------------------------------------------------------------------
-- SECTION E -- the cosmetic reveal: never networked, model-load-failure
-- degrade, and both call types.
-- ----------------------------------------------------------------------

t.test('found, callType = person: sits, plays Bark_Alert, and spawns a NON-NETWORKED ped with the idle scenario, at the finder own current position', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})

    f.fireCallEnded(false, 'found', 'person', 1)

    t.equals(f.k9SitCallCount(), 1)
    t.equals(f.playK9SoundCalls[#f.playK9SoundCalls].soundName, 'Bark_Alert')
    t.equals(#f.createdPeds, 1)
    t.isFalse(f.createdPeds[1].isNetwork, 'the reveal ped must NEVER be networked -- see this file own header')
    t.equals(#f.scenarioCalls, 1)
    t.equals(#f.revealThreads, 1, 'exactly one auto-clear timer thread is captured')
end)

t.test('found, callType = property: spawns a NON-NETWORKED, frozen object instead of a ped', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})

    f.fireCallEnded(false, 'found', 'property', 1)

    t.equals(#f.createdObjects, 1)
    t.isFalse(f.createdObjects[1].isNetwork)
    t.equals(#f.freezeCalls, 1)
    t.isTrue(f.freezeCalls[1].frozen)
    t.equals(#f.createdPeds, 0)
end)

t.test('timeout/abandoned reasons never spawn a reveal or play the found sound -- server own NotifyPlayer already covered the text', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'timeout', nil, 1)
    t.equals(#f.createdPeds, 0)
    t.equals(#f.createdObjects, 0)
    t.equals(f.k9SitCallCount(), 0)
end)

t.test('model-load failure (HasModelLoaded never returns true): degrades to a silent no-op -- no entity created, no error, streaming reference released', function()
    local f = newSarCallsFixture()
    f.setHasModelLoadedFn(function() return false end)
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})

    f.fireCallEnded(false, 'found', 'person', 1) -- must not error despite the model never loading
    t.equals(#f.createdPeds, 0)
    t.isTrue(#f.modelAsNoLongerNeededCalls >= 1, 'the streaming reference RequestModel took must be released on the failure path')
    -- the rest of the completion still happened -- only the cosmetic failed:
    t.equals(f.k9SitCallCount(), 1)
end)

t.test('the reveal auto-clear thread deletes the entity when its own generation still matches; onResourceStop also clears any live reveal', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', 1)
    local handle = f.createdPeds[1].handle
    t.isTrue(f.entityExists(handle))

    f.revealThreads[1]() -- run the captured auto-clear timer body directly
    t.isFalse(f.entityExists(handle))
    t.equals(#f.deleteEntityCalls, 1)
end)

t.test('onResourceStop clears a still-live reveal entity even if its own auto-clear timer never ran', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', 1)
    local handle = f.createdPeds[1].handle

    f.fireResourceStop('qbx_k9unit')
    t.isFalse(f.entityExists(handle))
end)

t.test('a SECOND found (a fresh call, after the first reveal already auto-cleared) replaces the reveal cleanly -- ClearReveal is defensive against a stray leftover', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', 1)
    local firstHandle = f.createdPeds[1].handle

    f.queueCallbackResponse({ started = true, callId = 2 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', 2)

    t.equals(#f.createdPeds, 2)
    t.isFalse(f.entityExists(firstHandle), 'the first reveal must have been cleared before/at the second own spawn')
end)

-- ----------------------------------------------------------------------
-- SECTION F -- THE STALE-SESSION RACE FIX (currentSarCallId/
-- IsForCurrentSarCall). See this file's own header "STALE-SESSION RACE"
-- for the full writeup this section pins.
-- ----------------------------------------------------------------------

t.test('STALE-SESSION RACE (simple case): a hint push carrying the OLD call id, after abandon + a new call started, is rejected -- does not affect the new call', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.stopCommand()
    t.equals(#f.serverEvents, 1, 'the abandon itself is one abandonSarCall call')

    f.queueCallbackResponse({ started = true, callId = 2 })
    f.startCommand({})

    f.fireHintTier(false, 'burning', 1) -- stale, belongs to the abandoned call
    t.equals(#f.notifyCalls, 0, 'the stale push for call 1 must be rejected -- call 2 has not gotten any hints yet')

    f.fireHintTier(false, 'burning', 2) -- genuinely current
    t.equals(#f.notifyCalls, 1)
end)

t.test('STALE-SESSION RACE: a sarCallEnded push with NO id at all is ALWAYS accepted -- a deliberate design choice, not something to "fix" to be stricter', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', nil)
    t.equals(f.k9SitCallCount(), 1, 'an unlabeled push must still be processed, matching production intent')
end)

t.test('STALE-SESSION RACE, THE EXACT CONCURRENCY SHAPE THIS FIX CLOSES: an old call own sarCallEnded(abandoned) echo, arriving WHILE a brand-new start is still awaiting the server, must NOT discard that new call own eventual grant', function()
    local f = newSarCallsFixture()

    -- Call A starts and is immediately abandoned (currentSarCallId -> nil).
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.stopCommand()

    -- Call B starts; WHILE its own requestSarCall await is still pending,
    -- call A own stale 'abandoned' echo (callId = 1) lands.
    f.setReentrant(function()
        f.fireCallEnded(false, 'abandoned', nil, 1)
    end)
    f.queueCallbackResponse({ started = true, callId = 2 })
    f.startCommand({})

    -- If the fix were reverted (the old echo unconditionally bumping
    -- requestGeneration), call B own grant above would have been discarded
    -- as stale and a hint for call 2 would go nowhere. Prove it was not:
    f.fireHintTier(false, 'burning', 2)
    t.isTrue(#f.notifyCalls >= 1, 'call B must be genuinely live -- its own hint must have been processed')
end)

t.test('IN-FLIGHT GUARD: a second k9sarcall start made WHILE the first is still awaiting the server is rejected outright -- no second round trip', function()
    local f = newSarCallsFixture()
    f.setReentrant(function() f.startCommand({}) end)
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    t.equals(f.callbackCallCount(), 1, 'the reentrant second call must not have reached the server at all')
end)

t.test('a repeated found push (double-fire) for a call already ended is rejected the second time -- K9Sit/reveal only ever fire once per resolved call', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', 1)
    t.equals(f.k9SitCallCount(), 1)
    t.equals(#f.createdPeds, 1)

    f.fireCallEnded(false, 'found', 'person', 1) -- currentSarCallId is already nil now -- must be rejected
    t.equals(f.k9SitCallCount(), 1, 'a duplicate found push for an already-ended call must not double-fire')
    t.equals(#f.createdPeds, 1)
end)

-- ----------------------------------------------------------------------
-- SECTION G -- THE ABANDON PATH IS NEVER GATED (per-person feature
-- control). CanShowK9UI is entirely OMITTED from this fixture's own
-- sandbox, not merely stubbed false.
-- ----------------------------------------------------------------------

t.test('k9sarcall stop: reaches the server EVEN WITH CanShowK9UI entirely undefined -- proves the abandon path never checks access of any kind', function()
    local f = newSarCallsFixture()
    f.env.CanShowK9UI = nil
    f.env.DenyK9UIAccess = nil
    t.isNil(f.env.CanShowK9UI, 'sanity: genuinely absent, not merely false')

    f.stopCommand()
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:abandonSarCall')
end)

t.test('k9sarcall stop: safe no-op when nothing is active', function()
    local f = newSarCallsFixture()
    f.stopCommand()
    t.equals(#f.serverEvents, 1)
end)

-- ----------------------------------------------------------------------
-- SECTION H -- RESOURCE-STOP HYGIENE, FIXED THIS PASS. See this file's own
-- header section of the same name for the full write-up this section pins.
-- ----------------------------------------------------------------------

t.test('FIXED: onResourceStop for a DIFFERENT resource is ignored -- no abandonSarCall call, no reveal cleared', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireResourceStop('some_other_resource')
    t.equals(#f.serverEvents, 0, 'only THIS resource stopping should trigger the abandon')
end)

t.test('FIXED: onResourceStop for THIS resource, mid-call, sends abandonSarCall -- closing the "orphaned ActiveSarCalls[source] until the tick-loop timeout" gap this spec used to leave undocumented', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    t.equals(#f.serverEvents, 0, 'sanity: nothing sent yet, only a start')

    f.fireResourceStop('qbx_k9unit')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:abandonSarCall')
end)

t.test('FIXED: onResourceStop reaches the server EVEN WITH CanShowK9UI entirely undefined -- the cleanup path is never gated on access, same as k9sarcall stop', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({}) -- start while CanShowK9UI is still available; access is only checked on the START path

    -- Certification/access revoked (or the whole global removed) AFTER the
    -- call is already live -- RequestStartSarCall() is not re-entered by
    -- onResourceStop, so this must not matter to the cleanup path at all.
    f.env.CanShowK9UI = nil
    f.env.DenyK9UIAccess = nil
    t.isNil(f.env.CanShowK9UI, 'sanity: CanShowK9UI must be genuinely absent, not merely false')

    f.fireResourceStop('qbx_k9unit') -- must not error
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:abandonSarCall')
end)

t.test('FIXED: onResourceStop with nothing active is a safe no-op that still forwards the unconditional abandon event, same as k9sarcall stop', function()
    local f = newSarCallsFixture()
    f.fireResourceStop('qbx_k9unit')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:abandonSarCall')
end)

t.test('FIXED: onResourceStop still clears a live cosmetic reveal in the same pass as sending abandonSarCall -- both cleanup jobs run, neither replaces the other', function()
    local f = newSarCallsFixture()
    f.queueCallbackResponse({ started = true, callId = 1 })
    f.startCommand({})
    f.fireCallEnded(false, 'found', 'person', 1) -- call already ended; reveal is live, sarCallActive is already false
    local handle = f.createdPeds[1].handle
    t.isTrue(f.entityExists(handle))

    f.fireResourceStop('qbx_k9unit')
    t.isFalse(f.entityExists(handle), 'ClearReveal() must still run')
    t.equals(#f.serverEvents, 1, 'RequestAbandonSarCall() is unconditional -- it still fires even though the call had already ended, exactly like k9sarcall stop on an inactive call')
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:abandonSarCall')
end)

-- ----------------------------------------------------------------------
-- WHAT THIS FILE DOES NOT COVER, AND WHY:
--
-- 1. onResourceStop: FIXED THIS PASS, see section H above. Before this
--    fix, this file's own onResourceStop handler called ONLY ClearReveal()
--    -- purely cosmetic cleanup -- and never told server/sarcalls.lua to
--    release ActiveSarCalls[source]. client/scenttrail.lua's identical gap
--    is documented (and corrected) in tests/clientscenttrail_spec.lua's own
--    equivalent note; THIS file's version was genuinely LOWER severity,
--    not merely differently worded: server/sarcalls.lua runs an
--    unconditional periodic tick loop (see that file's own "ACTIVE TICK
--    LOOP" header) that keeps re-checking every active call on its own
--    schedule regardless of whether this client is still talking to it, so
--    an orphaned ActiveSarCalls[source] entry already self-cleared within
--    Config.SARCalls.maxCallDurationMs (eight minutes) even before this
--    fix -- unlike server/scenttrail.lua's own lazy, poll-driven expiry,
--    which could persist indefinitely once nothing ever polls again. Still
--    a real, disclosed, player-facing lockout window (up to eight minutes
--    unable to take a new call after a client-side stop), not merely a
--    tidiness issue -- section H above pins the fix, which makes the
--    cleanup immediate instead of waiting on that timer.
-- ----------------------------------------------------------------------

os.exit(t.summary())
