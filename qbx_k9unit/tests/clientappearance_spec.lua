--[[
    tests/clientappearance_spec.lua

    Direct, black-box tests of client/appearance.lua against the REAL,
    unmodified production file -- the client half of the K9 role/ped-model
    decoupling (see server/appearance.lua's header for the full design).

    THREE of the FOUR load-bearing cases this task named live here (the
    fourth, "a human ped CAN hold the role", is a server-side/role-check
    concern and lives in tests/appearance_spec.lua):
      - "a client cannot self-assign" is reinforced here too: this file's
        ONLY entry point that changes a model, the 'qbx_k9unit:client:applyK9Ped'
        handler, is entirely SERVER-DRIVEN (RegisterNetEvent, source-origin
        guarded) -- there is no client-callable function anywhere in this
        file that a local script could invoke to assign itself the role.
      - "a failed model load leaves the player untouched" -- the TIMEOUT
        section below: SetPlayerModel is never called when HasModelLoaded
        never returns true within Config.K9Appearance.modelLoadTimeoutMs.
      - "revoke restores the original appearance" -- the REVERT section:
        the same handler accepts a raw numeric HASH (not just a model
        NAME) for exactly this path, and applies it identically.

    STUBBING EFFORT, reported honestly per this task's own instruction: the
    RequestModel/HasModelLoaded polling loop (LoadModelWithTimeout) is a
    plain, non-coroutine `while ... do Wait(50) end` loop that runs
    synchronously to completion inside ONE call to the captured
    'qbx_k9unit:client:applyK9Ped' handler -- unlike client/vision.lua's
    maintenance thread or a CreateThread-based sweep, this needs no
    coroutine/thread-runner simulation at all; Wait is a plain counting
    no-op stub, and the loop's own natural termination condition
    (HasModelLoaded flipping true, or the elapsed-time ceiling) drives the
    test directly.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param opts table? -- { modelLoadTimeoutMs: number? }
local function newFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    -- ox_lib lib.callback.await stub -- a FIFO queue of canned responses
    -- PLUS a call log, mirroring tests/main_spec.lua's own established
    -- HasK9Access fixture shape (the throw-modeling reasoning there is not
    -- re-derived here; see that file for the full citation against real
    -- ox_lib/FiveM source).
    local ThrowMarkerMT = {}
    local function callbackThrow(message) return setmetatable({ message = message }, ThrowMarkerMT) end
    local roleCallbackQueue = {}
    local roleCallbackCallCount = 0
    local roleForTargetCallbackQueue = {}
    local roleForTargetCallCount = 0

    local function lib_callback_await(name, ...)
        if name == 'qbx_k9unit:server:hasK9Role' then
            roleCallbackCallCount = roleCallbackCallCount + 1
            local response = table.remove(roleCallbackQueue, 1)
            if getmetatable(response) == ThrowMarkerMT then error(response.message, 0) end
            return response
        elseif name == 'qbx_k9unit:server:isK9RoleForTarget' then
            roleForTargetCallCount = roleForTargetCallCount + 1
            local response = table.remove(roleForTargetCallbackQueue, 1)
            if getmetatable(response) == ThrowMarkerMT then error(response.message, 0) end
            return response
        end
        error('unstubbed lib.callback.await in clientappearance_spec fixture: ' .. tostring(name))
    end

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local serverEvents = {} -- { {eventName, ...}, ... }
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { eventName, ... }
    end

    -- Engaged-state stubs -- each independently settable, to prove the OR
    -- across all six (see client/appearance.lua's own IsCurrentlyEngaged
    -- doc comment for the full list/reasoning). CORRECTED this pass: this
    -- fixture used to stub only five of the six predicates -- missing
    -- IsPropAttachmentEngaged entirely (added to production per that file's
    -- own "CLOSED GAP" header note, but never given fixture coverage here),
    -- silently leaving that sixth engagement source untested this whole
    -- time.
    local engaged = {}
    local function IsLeashed() return engaged.leashed == true end
    local function IsBiteHoldEngaged() return engaged.biteHold == true end
    local function IsDragEngaged() return engaged.drag == true end
    local function IsFetchCarryEngaged() return engaged.fetchCarry == true end
    local function IsInK9Vehicle() return engaged.vehicle == true end
    local function IsPropAttachmentEngaged() return engaged.propAttachment == true end

    -- RequestModel/HasModelLoaded/SetModelAsNoLongerNeeded/IsModelValid --
    -- same shape as tests covering client/kennel.lua's identical
    -- LoadModelWithTimeout pattern would need, but no existing spec in
    -- this suite happened to cover that pattern yet; built fresh here,
    -- following client/kennel.lua's own production shape exactly.
    local requestModelCalls = {}
    local releaseModelCalls = {}
    local modelLoadedHashes = {} -- [hash] = true once "loaded"
    local invalidHashes = {}     -- [hash] = true -- IsModelValid returns false for these
    local function RequestModel(hash) requestModelCalls[#requestModelCalls + 1] = hash end
    local function HasModelLoaded(hash) return modelLoadedHashes[hash] == true end
    local function SetModelAsNoLongerNeeded(hash) releaseModelCalls[#releaseModelCalls + 1] = hash end
    local function IsModelValid(hash) return invalidHashes[hash] ~= true end

    local waitCalls = 0
    local function Wait(_ms) waitCalls = waitCalls + 1 end

    -- The swapped ped, and what it currently looks like. SetPlayerModel
    -- moves `currentPedModel`, mirroring the real native's observable
    -- effect, so GetEntityModel below can answer honestly for the
    -- next-frame re-apply's own guard.
    local LOCAL_PED = 4242
    local currentPedModel = 'HASH(a_m_m_business_01)'
    local defaultComponentVariationCalls = {}

    local setPlayerModelCalls = {}
    local function SetPlayerModel(playerId, hash)
        setPlayerModelCalls[#setPlayerModelCalls + 1] = { playerId = playerId, hash = hash }
        currentPedModel = hash
    end
    local function PlayerPedId() return LOCAL_PED end
    local function GetEntityModel(ped) return ped == LOCAL_PED and currentPedModel or nil end
    local function SetPedDefaultComponentVariation(ped)
        defaultComponentVariationCalls[#defaultComponentVariationCalls + 1] = ped
    end

    -- Deferred bodies are collected rather than run, so a test decides when
    -- the "next frame" happens (f.runPendingThreads()) and can assert on
    -- what the world looked like before AND after it.
    local pendingThreads = {}
    local function CreateThread(fn) pendingThreads[#pendingThreads + 1] = fn end

    local function PlayerId() return 0 end -- FiveM's own local-player index; irrelevant which literal, only that it's passed through
    local function GetHashKey(name) return 'HASH(' .. name .. ')' end -- deliberately NOT a real hash algorithm -- only used to prove name-vs-number handling, never compared against a real game hash

    local Config = {
        K9Appearance = {
            modelLoadTimeoutMs = opts.modelLoadTimeoutMs or 5000,
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        lib = { callback = { await = lib_callback_await } },
        RegisterNetEvent = RegisterNetEvent,
        TriggerServerEvent = TriggerServerEvent,
        IsLeashed = IsLeashed,
        IsBiteHoldEngaged = IsBiteHoldEngaged,
        IsDragEngaged = IsDragEngaged,
        IsFetchCarryEngaged = IsFetchCarryEngaged,
        IsInK9Vehicle = IsInK9Vehicle,
        IsPropAttachmentEngaged = IsPropAttachmentEngaged,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        IsModelValid = IsModelValid,
        Wait = Wait,
        SetPlayerModel = SetPlayerModel,
        PlayerPedId = PlayerPedId,
        GetEntityModel = GetEntityModel,
        SetPedDefaultComponentVariation = SetPedDefaultComponentVariation,
        CreateThread = CreateThread,
        PlayerId = PlayerId,
        GetHashKey = GetHashKey,
        Config = Config,
    })

    Sandbox.loadInto('../client/appearance.lua', env)

    return {
        env = env,
        events = capturedEvents,
        serverEvents = serverEvents,
        defaultComponentVariationCalls = defaultComponentVariationCalls,
        runPendingThreads = function()
            local queued = pendingThreads
            pendingThreads = {}
            for _, fn in ipairs(queued) do fn() end
        end,
        pendingThreadCount = function() return #pendingThreads end,
        setPedModel = function(hash) currentPedModel = hash end,
        localPed = function() return LOCAL_PED end,
        setNow = function(ms) fakeNow = ms end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        queueRoleResponse = function(v) roleCallbackQueue[#roleCallbackQueue + 1] = v end,
        queueRoleThrow = function(msg) roleCallbackQueue[#roleCallbackQueue + 1] = callbackThrow(msg or 'thrown') end,
        roleCallCount = function() return roleCallbackCallCount end,
        queueRoleForTargetResponse = function(v) roleForTargetCallbackQueue[#roleForTargetCallbackQueue + 1] = v end,
        queueRoleForTargetThrow = function(msg) roleForTargetCallbackQueue[#roleForTargetCallbackQueue + 1] = callbackThrow(msg or 'thrown') end,
        roleForTargetCallCount = function() return roleForTargetCallCount end,
        setEngaged = function(key, v) engaged[key] = v end,
        markModelLoaded = function(hash) modelLoadedHashes[hash] = true end,
        markModelInvalid = function(hash) invalidHashes[hash] = true end,
        requestModelCalls = requestModelCalls,
        releaseModelCalls = releaseModelCalls,
        setPlayerModelCalls = setPlayerModelCalls,
        waitCallCount = function() return waitCalls end,
    }
end

-- ----------------------------------------------------------------------
-- IsK9Role() -- TTL debounce cache, same shape/TTL as client/main.lua's
-- own HasK9Access() -- see tests/main_spec.lua's own HasK9Access section
-- for the fuller worked example this mirrors.
-- ----------------------------------------------------------------------

local HAS_K9_ROLE_CACHE_TTL_MS = 1000 -- must match client/appearance.lua's own HAS_K9_ROLE_CACHE_TTL_MS

t.test('IsK9Role: a cold cache is a MISS -- awaits the real server callback', function()
    local f = newFixture()
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    t.equals(f.roleCallCount(), 1)
end)

t.test('IsK9Role: a second call at the SAME instant is a cache HIT -- no second round trip', function()
    local f = newFixture()
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    t.isTrue(f.env.IsK9Role())
    t.equals(f.roleCallCount(), 1, 'still cached -- the second call never touched the queue')
end)

t.test('IsK9Role: at exactly the TTL boundary the cache has EXPIRED -- a fresh round trip is made', function()
    local f = newFixture()
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    f.advance(HAS_K9_ROLE_CACHE_TTL_MS)
    f.queueRoleResponse(false)
    t.isFalse(f.env.IsK9Role(), 'the newly-queued response, proving a real re-check happened')
    t.equals(f.roleCallCount(), 2)
end)

t.test('IsK9Role: a callback THROW (timeout/unregistered) fails closed -- returns false, never lets the error escape, and does NOT poison the cache', function()
    local f = newFixture()
    f.queueRoleThrow()
    t.isFalse(f.env.IsK9Role())

    -- Immediately after, a SUCCEEDING call must re-attempt rather than
    -- serve a cached false for the full TTL -- see client/appearance.lua's
    -- own doc comment on why `checkedAt` is deliberately left untouched on
    -- the throw path.
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    t.equals(f.roleCallCount(), 2, 'the throw did not consume a cache window -- the very next call re-attempted immediately')
end)

-- ----------------------------------------------------------------------
-- IsK9RoleForPlayer(targetServerId) -- the "one real gap" primitive a peer
-- audit this pass flagged: per-TARGET TTL cache, same shape.
-- ----------------------------------------------------------------------

t.test('IsK9RoleForPlayer: awaits the server for a given target, caches per-target', function()
    local f = newFixture()
    f.queueRoleForTargetResponse(true)
    t.isTrue(f.env.IsK9RoleForPlayer(42))
    t.isTrue(f.env.IsK9RoleForPlayer(42))
    t.equals(f.roleForTargetCallCount(), 1, 'second call for the SAME target within the TTL is a cache hit')
end)

t.test('IsK9RoleForPlayer: a DIFFERENT target is not served from the first target\'s cache entry', function()
    local f = newFixture()
    f.queueRoleForTargetResponse(true)
    t.isTrue(f.env.IsK9RoleForPlayer(42))
    f.queueRoleForTargetResponse(false)
    t.isFalse(f.env.IsK9RoleForPlayer(99))
    t.equals(f.roleForTargetCallCount(), 2)
end)

t.test('IsK9RoleForPlayer: a non-number argument fails closed without ever touching the network', function()
    local f = newFixture()
    t.isFalse(f.env.IsK9RoleForPlayer('not-a-number'))
    t.equals(f.roleForTargetCallCount(), 0)
end)

t.test('IsK9RoleForPlayer: a resolved-nil response (not a throw) is treated as false, and IS cached like any other real answer', function()
    local f = newFixture()
    f.queueRoleForTargetResponse(nil)
    t.isFalse(f.env.IsK9RoleForPlayer(7))
    t.isFalse(f.env.IsK9RoleForPlayer(7))
    t.equals(f.roleForTargetCallCount(), 1, 'a genuine nil answer is cached exactly like `false` -- only a THROW skips caching')
end)

t.test('IsK9RoleForPlayer: a callback THROW fails closed, same as IsK9Role, and does NOT poison that target\'s cache', function()
    local f = newFixture()
    f.queueRoleForTargetThrow()
    t.isFalse(f.env.IsK9RoleForPlayer(7))

    f.queueRoleForTargetResponse(true)
    t.isTrue(f.env.IsK9RoleForPlayer(7), 'the throw did not consume a cache window -- the very next call re-attempted immediately')
    t.equals(f.roleForTargetCallCount(), 2)
end)

-- ----------------------------------------------------------------------
-- applyK9Ped -- SOURCE-ORIGIN GUARD. "A client cannot self-assign": this
-- handler is the ONLY place SetPlayerModel is ever called, and it is
-- entirely server-triggered.
-- ----------------------------------------------------------------------

t.test('applyK9Ped: a forged LOCAL trigger (source ~= 65535) is rejected outright -- no model requested, no confirm sent', function()
    local f = newFixture()
    f.env.source = 1 -- NOT the server sentinel
    f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.setPlayerModelCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('applyK9Ped: a genuine server-origin trigger (source == 65535) is processed', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_husky)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.setPlayerModelCalls, 1)
end)

-- ----------------------------------------------------------------------
-- "REFUSE, DON'T FORCE-CLEAR" -- engaged in ANY of the six tracked states
-- refuses the swap outright, before RequestModel is ever called.
-- ----------------------------------------------------------------------

local ENGAGED_KEYS = { 'leashed', 'biteHold', 'drag', 'fetchCarry', 'vehicle', 'propAttachment' }
for _, key in ipairs(ENGAGED_KEYS) do
    t.test(('applyK9Ped: refuses outright when engaged via %s -- no model ever requested, reports "engaged"'):format(key), function()
        local f = newFixture()
        f.env.source = 65535
        f.setEngaged(key, true)
        f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_husky')

        t.equals(#f.requestModelCalls, 0, 'never even attempted -- refuse, not force-clear')
        t.equals(#f.setPlayerModelCalls, 0)
        t.equals(#f.serverEvents, 1)
        t.equals(f.serverEvents[1][1], 'qbx_k9unit:server:confirmK9PedSwap')
        t.equals(f.serverEvents[1][3], false)
        t.equals(f.serverEvents[1][4], 'engaged')
    end)
end

t.test('applyK9Ped: not engaged in any tracked way -- proceeds normally', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_husky)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_husky')
    t.equals(#f.setPlayerModelCalls, 1)
end)

-- ----------------------------------------------------------------------
-- BUG (found + fixed this pass): the ORIGINAL IsCurrentlyEngaged() check
-- above only proves the ped was unengaged at the INSTANT this handler
-- started -- LoadModelWithTimeout's own Wait(50) polling loop can run for
-- however long the configured modelLoadTimeoutMs allows, and nothing
-- re-checked engagement after that wait before this pass's own fix. This
-- reproduces the race directly: the model loads successfully, but the
-- player becomes engaged (an independent action landing while this handler
-- was suspended, e.g. another player leashing this one) DURING the wait,
-- not before it.
-- ----------------------------------------------------------------------

t.test('BUG (found + fixed this pass): becoming engaged DURING the model-load wait (not before it started) still refuses the swap, releases the successfully-loaded model, and reports "engaged"', function()
    local f = newFixture()
    f.env.source = 65535

    -- Not engaged at dispatch time (the FIRST IsCurrentlyEngaged() check
    -- must pass, or this test would prove nothing about the SECOND,
    -- post-wait check this pass added). The model reports "still loading"
    -- for its first poll -- during which this fixture's own Wait stub flips
    -- the player LEASHED -- then "loaded" from the second poll onward.
    local pollCount = 0
    f.env.Wait = function(_ms)
        pollCount = pollCount + 1
        f.setEngaged('leashed', true) -- lands mid-wait, independent of this handler
        f.markModelLoaded('HASH(a_c_husky)')
    end

    f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.requestModelCalls, 1, 'the load was genuinely attempted -- this is not the "refused before RequestModel" path')
    t.equals(#f.setPlayerModelCalls, 0, 'FIXED: must NOT apply the swap -- the player became engaged during the wait, even though it started unengaged')
    t.equals(#f.releaseModelCalls, 1, 'the successfully-loaded model\'s streaming reference must still be released even though it ends up unused')
    t.equals(f.releaseModelCalls[1], 'HASH(a_c_husky)')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1][3], false)
    t.equals(f.serverEvents[1][4], 'engaged', 'reported the same way as the pre-existing "engaged at dispatch time" case, not "timeout" or a silent drop')
    t.isTrue(pollCount >= 1, 'sanity: the Wait stub above must have actually run for this test to prove anything')
end)

-- ----------------------------------------------------------------------
-- LOAD-BEARING CASE: a failed model load leaves the player untouched.
-- ----------------------------------------------------------------------

t.test('applyK9Ped: HasModelLoaded never flips true within modelLoadTimeoutMs -- ABANDONS the swap: SetPlayerModel is NEVER called, the model reference is released (leak fix), and the server is told "timeout"', function()
    local f = newFixture({ modelLoadTimeoutMs = 500 })
    f.env.source = 65535
    -- markModelLoaded is deliberately never called -- HasModelLoaded stays
    -- false for the entire polling window.
    f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.setPlayerModelCalls, 0, 'the player is exactly as they were -- never half-applied')
    t.equals(#f.requestModelCalls, 1, 'the load WAS attempted')
    t.equals(#f.releaseModelCalls, 1, 'LEAK FIX: the streaming reference RequestModel incremented is released on the timeout exit path too')
    t.equals(f.releaseModelCalls[1], 'HASH(a_c_husky)')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1][3], false)
    t.equals(f.serverEvents[1][4], 'timeout')
end)

t.test('applyK9Ped: an invalid/unrecognized model hash on THIS client is rejected immediately -- RequestModel is never even called (mirrors client/kennel.lua\'s identical guard)', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelInvalid('HASH(a_c_nonexistent)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-1', 'a_c_nonexistent')

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.setPlayerModelCalls, 0)
    t.equals(f.serverEvents[1][4], 'timeout', 'LoadModelWithTimeout returns false uniformly for "invalid" and "never loaded" -- both are reported the same way upstream')
end)

-- ----------------------------------------------------------------------
-- SUCCESS PATH -- and the LOAD-BEARING revert case: a raw numeric HASH
-- (not a name) is accepted identically, exactly as server/appearance.lua
-- sends for a revert-to-original-model request.
-- ----------------------------------------------------------------------

t.test('applyK9Ped: success -- RequestModel is called with the resolved hash, SetPlayerModel is called with PlayerId() and that hash, the model reference is released, and the server is told ok=true', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-42', 'a_c_shepherd')

    t.equals(f.requestModelCalls[1], 'HASH(a_c_shepherd)')
    t.equals(#f.setPlayerModelCalls, 1)
    t.equals(f.setPlayerModelCalls[1].hash, 'HASH(a_c_shepherd)')
    t.equals(f.releaseModelCalls[1], 'HASH(a_c_shepherd)')
    t.equals(f.serverEvents[1][1], 'qbx_k9unit:server:confirmK9PedSwap')
    t.equals(f.serverEvents[1][2], 'req-42')
    t.equals(f.serverEvents[1][3], true)
end)

-- ----------------------------------------------------------------------
-- INVISIBLE-PED FIX. Reported from a live server: certifying somebody with
-- /k9certify "changes me to air". The swap fired, the dog model was right,
-- and nothing rendered at all.
--
-- SET_PLAYER_MODEL builds the new ped with NO component variation set. A
-- human ped mostly survives that; an animal ped does not, because every
-- part of the dog IS a component -- so a ped with none set has nothing to
-- draw. The player stands there, collides, can be targeted, and is
-- invisible to everyone including themselves.
-- ----------------------------------------------------------------------

t.test('INVISIBLE-PED FIX: a successful swap applies the default component variation to the new ped -- without it the dog renders as nothing at all', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-42', 'a_c_shepherd')

    t.equals(#f.defaultComponentVariationCalls, 1, 'the swap is not finished until the ped has something to draw')
    t.equals(f.defaultComponentVariationCalls[1], f.localPed())
end)

t.test('INVISIBLE-PED FIX: it is applied AGAIN on the next frame, since on some builds a ped is not fully built until the frame after the swap', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-42', 'a_c_shepherd')

    t.equals(f.pendingThreadCount(), 1, 'a next-frame re-apply must actually be scheduled, not just intended')
    f.runPendingThreads()
    t.equals(#f.defaultComponentVariationCalls, 2,
        'a variation applied to a half-built ped is silently dropped -- an intermittent invisible dog is worse to diagnose than a consistent one')
end)

t.test('INVISIBLE-PED FIX: the next-frame re-apply is a NO-OP if something swapped the player again in the meantime -- it never stomps whatever they legitimately became', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-42', 'a_c_shepherd')
    t.equals(#f.defaultComponentVariationCalls, 1)

    -- Another resource, a revoke racing the certify, or a death and
    -- respawn -- anything that moves them off the model this handler applied.
    f.setPedModel('HASH(a_m_m_business_01)')
    f.runPendingThreads()

    t.equals(#f.defaultComponentVariationCalls, 1, 'still just the immediate one -- the deferred pass correctly declined to act')
end)

t.test('INVISIBLE-PED FIX: an ABANDONED swap (model never streamed in) applies no variation and schedules no re-apply -- there is no new ped to dress', function()
    local f = newFixture({ modelLoadTimeoutMs = 200 })
    f.env.source = 65535
    -- deliberately never markModelLoaded -- HasModelLoaded stays false
    f.events['qbx_k9unit:client:applyK9Ped']('req-timeout', 'a_c_shepherd')

    t.equals(#f.setPlayerModelCalls, 0, 'precondition: the swap really was abandoned')
    t.equals(#f.defaultComponentVariationCalls, 0)
    t.equals(f.pendingThreadCount(), 0)
end)

t.test('INVISIBLE-PED FIX: a swap REFUSED because the ped is engaged applies no variation either -- nothing was swapped', function()
    local f = newFixture()
    f.env.source = 65535
    f.setEngaged('leashed', true)
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['qbx_k9unit:client:applyK9Ped']('req-engaged', 'a_c_shepherd')

    t.equals(#f.setPlayerModelCalls, 0)
    t.equals(#f.defaultComponentVariationCalls, 0)
    t.equals(f.pendingThreadCount(), 0)
end)

t.test('REVERT CASE: a raw NUMERIC hash (not a string name) is applied directly -- GetHashKey is never called on it, since it is already a hash', function()
    local f = newFixture()
    f.env.source = 65535
    local originalHash = -123456789
    f.markModelLoaded(originalHash)
    f.events['qbx_k9unit:client:applyK9Ped']('req-revert', originalHash)

    t.equals(f.requestModelCalls[1], originalHash)
    t.equals(f.setPlayerModelCalls[1].hash, originalHash)
    t.isTrue(f.serverEvents[1][3])
end)

t.test('applyK9Ped: a malformed payload (neither string nor number) is ignored -- no crash, nothing requested', function()
    local f = newFixture()
    f.env.source = 65535
    f.events['qbx_k9unit:client:applyK9Ped']('req-1', { not_a = 'valid payload' })

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('applyK9Ped: an empty/non-string requestId is ignored -- no crash, nothing requested', function()
    local f = newFixture()
    f.env.source = 65535
    f.events['qbx_k9unit:client:applyK9Ped']('', 'a_c_husky')
    f.events['qbx_k9unit:client:applyK9Ped'](nil, 'a_c_husky')

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

os.exit(t.summary())
