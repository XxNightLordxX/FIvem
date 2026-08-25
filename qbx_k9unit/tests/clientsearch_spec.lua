--[[
    tests/clientsearch_spec.lua

    Client-side spec for client/search.lua (Search Vehicle / Search Person
    and the bystander contraband-alert broadcast receiver). Follows
    main_spec.lua's worked example: a real, unmodified client/search.lua
    loaded into a fresh sandbox per test, driven only through its real
    ox_target option definitions (captured via a stubbed
    exports.ox_target:addGlobalVehicle/addGlobalPlayer) and its one
    RegisterNetEvent handler -- never a reimplementation of PerformSearch's
    logic, which is a `local` this spec has no other way to reach (exactly
    the ox_target-onSelect-closure pattern tests/README.md's own sandbox
    doc describes as the correct way in).

    LIFECYCLE NOTE: client/search.lua's own "LIFECYCLE FIX" comment means
    its two ox_target options are NOT registered merely by loading the
    file -- they are only registered inside the captured
    AddEventHandler('onResourceStart', ...) handler. newSearchFixture()
    below fires that handler once with GetCurrentResourceName()'s own
    stubbed value immediately after loading, mirroring a real resource
    start, so every test below can go straight to `f.vehicleOption()` /
    `f.personOption()` without repeating that plumbing itself.

    THIS PASS'S PRIORITY, per this file's own task brief:
    1. The in-flight guard (`searchInProgress`) -- section B, driven via
       REENTRANCY (this sandbox's lib.progressBar is otherwise synchronous,
       so a reentrant onSelect call fired from INSIDE the pending
       progressBar callback models "a second click lands while the first
       search is still running").
    2. Every rejection `reason` the server can return has a client-side
       label, and none of them silently show nothing -- section C
       enumerates the FULL real reason set found by reading
       server/search.lua directly (not just this file's own header
       comment, which is stale by one value -- see that section's own
       DISCLOSED FINDING sub-test), including the two "no reason at all"
       degenerate cases (a nil round-trip result, and a lib.callback.await
       that throws outright, modeling ox_lib's real timeout/rejection
       behavior).
    3. netId capture BEFORE the sniff animation, so a target whose entity
       handle gets reassigned mid-animation cannot be misattributed --
       section D, proven by mutating the entity->netId mapping FROM INSIDE
       the (reentrant) progressBar stub, i.e. strictly between the capture
       point and the eventual server call.

    `source ~= 65535` origin guard: section F, on the ONE real
    RegisterNetEvent handler this file registers
    ('qbx_k9unit:client:playContrabandAlert'). Per this task's own
    instruction, wherever this guard is pinned below carries its own
    comment that a green test here proves what THE CODE does and does NOT
    settle whether the engine itself can be made to fail open -- see that
    section for the full, repeated caveat.

    STUBBING EFFORT, reported honestly: proportionate. The one native-ish
    surface unique to this file versus main_spec.lua/clientradial_spec.lua
    is `exports.ox_target:addGlobalVehicle/addGlobalPlayer` (colon-call
    syntax -- `self` is the stubbed ox_target table itself, discarded).
    Everything else is the same small recording/controllable stand-in
    shape already established (lib.progressBar/lib.callback.await/
    lib.notify, DoesEntityExist, NetworkGetNetworkIdFromEntity,
    NetworkGetPlayerIndexFromPed, PlayerId, AddEventHandler,
    RegisterNetEvent, GetCurrentResourceName, PlaySoundOnNetworkEntity as
    a call-recording stand-in for the already-covered client/main.lua
    function of that name). TriggerServerEvent is DELIBERATELY never
    stubbed at all (see section E) -- this file's own header states it
    triggers no server events beyond the one callback, and an unstubbed
    global call would fail loudly rather than silently, which is the
    stronger check.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Sentinel returned by `queueCallbackThrow()`/`queueProgressBarThrow()` --
--- see their own comments below for why a thrown lib.callback.await matters
--- here (ox_lib's real behavior on a timeout/rejection is to throw, not
--- return nil -- confirmed elsewhere in this codebase's own concurrent
--- FAIL-CLOSED GUARD comments in client/wellbeing.lua, added the same
--- session this spec was written).
local THROW = setmetatable({}, { __tostring = function() return 'THROW' end })

--- @param opts { canShowK9UI: boolean?, searchZones: boolean? }?
local function newSearchFixture(opts)
    opts = opts or {}

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local canShowK9UICallCount = 0
    local denyCalls = 0
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local existingEntities = {} -- entity -> boolean
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    local netIdByEntity = {} -- entity -> netId, mutable mid-test (section D)
    local function NetworkGetNetworkIdFromEntity(entity) return netIdByEntity[entity] end

    -- lib.progressBar -- a plain FIFO queue of canned `completed` booleans,
    -- PLUS an optional reentrant hook fired from INSIDE the stub (before it
    -- returns) so a test can simulate "something else happens while the
    -- sniff animation is still playing" (sections B and D both need this).
    local progressBarCalls = {}
    local progressBarQueue = {}
    local progressBarReentrant = nil
    local function progressBar(def)
        progressBarCalls[#progressBarCalls + 1] = def
        if progressBarReentrant then
            local fn = progressBarReentrant
            progressBarReentrant = nil
            fn()
        end
        local next = table.remove(progressBarQueue, 1)
        if next == nil then return true end -- default: completed normally
        return next
    end

    -- lib.callback.await -- a plain FIFO queue of canned responses. A
    -- queued THROW sentinel makes this stub error() instead of returning,
    -- modeling ox_lib's real timeout/rejection behavior (see section C's
    -- "an outright throw" test).
    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local next = table.remove(callbackResponses, 1)
        if next == THROW then
            error('simulated lib.callback.await failure (timeout/rejection)')
        end
        return next
    end

    local notifyCalls = {}
    local lib = {
        progressBar = progressBar,
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    -- exports.ox_target:addGlobalVehicle/addGlobalPlayer -- colon-call
    -- syntax means the FIRST argument received is the stub table itself
    -- (`self`), discarded here; the SECOND is the real definition list
    -- this file passes.
    local addGlobalVehicleCalls, addGlobalPlayerCalls = {}, {}
    local oxTargetStub = {}
    function oxTargetStub.addGlobalVehicle(_, defs) addGlobalVehicleCalls[#addGlobalVehicleCalls + 1] = defs end
    function oxTargetStub.addGlobalPlayer(_, defs) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = defs end

    -- AddEventHandler('onResourceStart', ...) -- capturing, per this
    -- file's own header LIFECYCLE NOTE.
    local resourceStartHandlers = {}
    local function AddEventHandler(eventName, handler)
        assert(eventName == 'onResourceStart',
            ('clientsearch_spec: unexpected AddEventHandler(%q, ...) -- this fixture only expects onResourceStart'):format(tostring(eventName)))
        resourceStartHandlers[#resourceStartHandlers + 1] = handler
    end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local playerIndexByPed = {}
    local function NetworkGetPlayerIndexFromPed(entity) return playerIndexByPed[entity] or -1 end
    local myPlayerId = 0
    local function PlayerId() return myPlayerId end

    local playSoundOnNetworkEntityCalls = {}
    local function PlaySoundOnNetworkEntity(netId, soundName)
        playSoundOnNetworkEntityCalls[#playSoundOnNetworkEntityCalls + 1] = { netId = netId, soundName = soundName }
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        DoesEntityExist = DoesEntityExist,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        lib = lib,
        exports = { ox_target = oxTargetStub },
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        PlayerId = PlayerId,
        PlaySoundOnNetworkEntity = PlaySoundOnNetworkEntity,
        -- TriggerServerEvent deliberately NOT stubbed -- see this file's
        -- own header on why an unstubbed call failing loudly is the
        -- stronger check for "this file sends no server events beyond the
        -- one callback."
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)
    -- Explicit, per this task's own instruction: never depend on
    -- config.lua's shipped default (currently true for every flag).
    env.Config.Features.SearchZones = opts.searchZones
    if opts.searchZones == nil then env.Config.Features.SearchZones = true end
    Sandbox.loadInto('../client/search.lua', env)

    -- Mirrors a real resource start -- see this file's own header
    -- LIFECYCLE NOTE.
    for _, fn in ipairs(resourceStartHandlers) do
        fn('qbx_k9unit')
    end

    local fixture
    fixture = {
        env = env,
        notifyCalls = notifyCalls,
        progressBarCalls = progressBarCalls,
        playSoundOnNetworkEntityCalls = playSoundOnNetworkEntityCalls,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        denyCallCount = function() return denyCalls end,

        setEntityExists = function(entity, v) existingEntities[entity] = v end,
        setNetIdForEntity = function(entity, netId) netIdByEntity[entity] = netId end,

        queueProgressBarResult = function(v) progressBarQueue[#progressBarQueue + 1] = v end,
        setProgressBarReentrant = function(fn) progressBarReentrant = fn end,

        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        queueCallbackThrow = function() callbackResponses[#callbackResponses + 1] = THROW end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,

        setPlayerIndexForPed = function(entity, idx) playerIndexByPed[entity] = idx end,
        setMyPlayerId = function(v) myPlayerId = v end,

        --- The single "Search Vehicle" ox_target option definition, as
        --- registered by the most recent onResourceStart trigger.
        vehicleOption = function()
            local defs = addGlobalVehicleCalls[#addGlobalVehicleCalls]
            return defs and defs[1]
        end,
        --- The single "Search Person" ox_target option definition.
        personOption = function()
            local defs = addGlobalPlayerCalls[#addGlobalPlayerCalls]
            return defs and defs[1]
        end,
        addGlobalVehicleCallCount = function() return #addGlobalVehicleCalls end,
        addGlobalPlayerCallCount = function() return #addGlobalPlayerCalls end,

        --- Re-fires onResourceStart -- used by the lifecycle re-registration test.
        fireResourceStart = function(resourceName)
            for _, fn in ipairs(resourceStartHandlers) do fn(resourceName) end
        end,

        triggerContrabandAlert = function(sourceValue, netId, alertTier)
            local handler = assert(netEventHandlers['qbx_k9unit:client:playContrabandAlert'],
                'client/search.lua did not register a qbx_k9unit:client:playContrabandAlert handler')
            env.source = sourceValue
            handler(netId, alertTier)
        end,
    }
    return fixture
end

-- ----------------------------------------------------------------------
-- Sanity: both ox_target options really got registered on resource start,
-- and the net event handler is really reachable.
-- ----------------------------------------------------------------------

t.test('resource start registers exactly one Search Vehicle and one Search Person ox_target option', function()
    local f = newSearchFixture()
    t.equals(f.addGlobalVehicleCallCount(), 1)
    t.equals(f.addGlobalPlayerCallCount(), 1)
    local vehicleOpt = f.vehicleOption()
    local personOpt = f.personOption()
    t.isNotNil(vehicleOpt)
    t.isNotNil(personOpt)
    t.equals(vehicleOpt.name, 'qbx_k9unit:searchVehicle')
    t.equals(personOpt.name, 'qbx_k9unit:searchPerson')
    t.equals(vehicleOpt.label, locale('search.vehicle_target_label'))
    t.equals(personOpt.label, locale('search.person_target_label'))
end)

t.test('LIFECYCLE FIX: onResourceStart firing again (e.g. a bare ox_target restart) re-registers both options', function()
    local f = newSearchFixture()
    f.fireResourceStart('ox_target')
    t.equals(f.addGlobalVehicleCallCount(), 2, 'must re-register on an ox_target restart, not just this resource\'s own start')
    t.equals(f.addGlobalPlayerCallCount(), 2)

    -- An unrelated resource starting must NOT trigger a re-registration.
    f.fireResourceStart('some_other_resource')
    t.equals(f.addGlobalVehicleCallCount(), 2)
end)

t.test('canInteract: both options respect Config.Features.SearchZones, and Search Person excludes the local player\'s own ped', function()
    local fOff = newSearchFixture({ searchZones = false })
    t.isFalse(fOff.vehicleOption().canInteract(500, 1.0, {}, 'x'))
    t.isFalse(fOff.personOption().canInteract(500, 1.0, {}, 'x'))

    local fOn = newSearchFixture({ searchZones = true })
    t.isTrue(fOn.vehicleOption().canInteract(500, 1.0, {}, 'x'))

    fOn.setPlayerIndexForPed(500, 3)
    fOn.setMyPlayerId(3)
    t.isFalse(fOn.personOption().canInteract(500, 1.0, {}, 'x'), 'a player must never be offered "Search Person" against their own ped')

    fOn.setPlayerIndexForPed(501, 7) -- a different player
    t.isTrue(fOn.personOption().canInteract(501, 1.0, {}, 'x'))
end)

-- ----------------------------------------------------------------------
-- SECTION A -- the defensive re-check + "nothing to search" guard, before
-- the in-flight/netId-capture sections that build on top of a successful
-- entry into PerformSearch.
-- ----------------------------------------------------------------------

t.test('onSelect: CanShowK9UI() false denies access and never starts the sniff animation at all', function()
    local f = newSearchFixture({ canShowK9UI = false })
    f.setEntityExists(500, true)
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.progressBarCalls, 0)
    t.equals(f.callbackCallCount(), 0)
end)

t.test('onSelect: a target entity that no longer exists notifies search.nothing_to_search and never starts the animation', function()
    local f = newSearchFixture()
    -- Never registered via setEntityExists -- DoesEntityExist defaults false.
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.progressBarCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.nothing_to_search'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('onSelect: player cancelling/moving away mid-sniff (progressBar returns false) makes no server call at all, and resets the in-flight flag', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueProgressBarResult(false)
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.callbackCallCount(), 0)

    -- The in-flight flag must have been released -- a fresh attempt right
    -- after must be able to proceed normally, not be silently swallowed.
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.callbackCallCount(), 1)
end)

-- ----------------------------------------------------------------------
-- SECTION B -- THE IN-FLIGHT GUARD (searchInProgress), THIS TASK'S TOP
-- PRIORITY. Driven via reentrancy: the reentrant onSelect call happens
-- from INSIDE the pending lib.progressBar call, i.e. strictly AFTER
-- `searchInProgress = true` has already been set by the outer call and
-- strictly BEFORE it is ever reset -- exactly the "double-click before the
-- sniff animation visually disables the option" window this flag exists
-- to close.
-- ----------------------------------------------------------------------

t.test('a second onSelect call made WHILE a search is already in flight (same option) is a silent no-op -- no second animation, no second server call', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.setProgressBarReentrant(function()
        f.vehicleOption().onSelect({ entity = 500 }) -- the "double-click"
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(#f.progressBarCalls, 1, 'the reentrant call must never have started a second sniff animation/progress bar')
    t.equals(f.callbackCallCount(), 1, 'and therefore never a second server round trip either')
    t.equals(#f.notifyCalls, 1, 'exactly the ONE real outcome notify -- the reentrant call is silent, per this file\'s own "routine double-click protection, not an error state" comment')
    t.equals(f.notifyCalls[1].description, locale('search.nothing_found'))
end)

t.test('the in-flight guard also blocks a concurrent attempt through the OTHER option (Search Person while Search Vehicle is mid-flight)', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setEntityExists(600, true)
    f.setNetIdForEntity(500, 111)
    f.setNetIdForEntity(600, 222)
    f.setProgressBarReentrant(function()
        f.personOption().onSelect({ entity = 600 })
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().args[1], 'vehicle', 'only the ORIGINAL (vehicle) search must have actually reached the server')
end)

t.test('searchInProgress is always released after a completed search, even one whose callback throws -- a fresh search right after must be able to proceed', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackThrow()
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.failed'))

    f.queueCallbackResponse({ ok = true, contrabandFound = true })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.callbackCallCount(), 2, 'the flag must have been released even after a throw -- this second, independent search must reach the server')
end)

-- ----------------------------------------------------------------------
-- SECTION C -- EVERY REJECTION REASON HAS A CLIENT-SIDE LABEL, AND NONE
-- OF THEM SILENTLY SHOW NOTHING. Full reason set below was found by
-- reading server/search.lua's searchTarget callback directly (grep
-- `reason = ` across that file), not copied from client/search.lua's own
-- header comment -- see the DISCLOSED FINDING sub-test at the end of this
-- section for the one place those two lists actually disagree.
-- ----------------------------------------------------------------------

--- Every reason string server/search.lua's searchTarget callback can
--- return, confirmed by reading that file directly this pass.
local SILENT_REASONS = { 'on_cooldown', 'search_in_progress' }
local GENERIC_DENIED_REASONS = {
    'invalid_target', 'feature_disabled', 'no_access', 'too_far',
    'access_revoked', -- see the DISCLOSED FINDING sub-test below
    'a_totally_unrecognized_future_reason', -- proves the catch-all, not a real server value
}

for _, reason in ipairs(SILENT_REASONS) do
    t.test(('reason %q: silent, no-notify rejection (routine traffic, not an error worth interrupting the player over)'):format(reason), function()
        local f = newSearchFixture()
        f.setEntityExists(500, true)
        f.setNetIdForEntity(500, 111)
        f.queueCallbackResponse({ ok = false, reason = reason })
        f.vehicleOption().onSelect({ entity = 500 })
        t.equals(#f.notifyCalls, 0, ('reason %q must produce zero notifications'):format(reason))

        -- "Silent" must still mean "handled," not "stuck": a fresh attempt
        -- right after must be able to proceed normally.
        f.queueCallbackResponse({ ok = true, contrabandFound = false })
        f.vehicleOption().onSelect({ entity = 500 })
        t.equals(f.callbackCallCount(), 2)
    end)
end

for _, reason in ipairs(GENERIC_DENIED_REASONS) do
    t.test(('reason %q: falls through to the generic error notify (search.generic_denied) -- never silent, never confused with a clean result'):format(reason), function()
        local f = newSearchFixture()
        f.setEntityExists(500, true)
        f.setNetIdForEntity(500, 111)
        f.queueCallbackResponse({ ok = false, reason = reason })
        f.vehicleOption().onSelect({ entity = 500 })
        t.equals(#f.notifyCalls, 1, ('reason %q must produce exactly one notification, never silence'):format(reason))
        t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
        t.equals(f.notifyCalls[1].type, 'error')
    end)
end

t.test('reason "search_failed": a DISTINCT message from generic_denied AND from a clean "nothing found" result -- never collapsed into either', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false, reason = 'search_failed' })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.failed'))
    t.notContains(f.notifyCalls[1].description, locale('search.generic_denied'))
    t.notContains(f.notifyCalls[1].description, locale('search.nothing_found'))
end)

t.test('a completely EMPTY round trip (result == nil, e.g. a dropped/absent response) is treated as a rejection with no reason -- falls to generic_denied, never silent, never a false "nothing found"', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    -- Nothing queued at all -- callbackAwait's table.remove on an empty queue returns nil.
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1, 'a nil result must not be silently swallowed')
    t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
end)

t.test('a result with ok == false and NO reason field at all also falls to generic_denied, never silent', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
end)

t.test('lib.callback.await THROWING outright (ox_lib\'s real timeout/rejection behavior) is caught and produces the SAME search.failed message as an explicit search_failed reason -- never an uncaught error, never silence', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackThrow()
    -- pcall this call site itself too: if client/search.lua's own internal
    -- pcall wrapper (see this file's own "everything ... is wrapped in
    -- pcall" comment) were ever removed, this would surface as an escaped
    -- error here rather than a clean assertion failure below.
    local ok = pcall(function() f.vehicleOption().onSelect({ entity = 500 }) end)
    t.isTrue(ok, 'a thrown lib.callback.await must never escape PerformSearch uncaught')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.failed'))
end)

t.test('DISCLOSED FINDING: server/search.lua can also return reason == "access_revoked" (a decertified-mid-search re-check), which is NOT in this file\'s own header comment\'s documented reason list -- but the client\'s catch-all already handles it correctly regardless, so this is a documentation drift, not a functional bug', function()
    -- server/search.lua's own header comment for this exact value states
    -- plainly: "client/search.lua's reason-handling `else` branch already
    -- treats any unrecognized reason as a plain error notify, so no
    -- client-side change is required for this new value." This test
    -- confirms that claim holds against the REAL client file, not just
    -- server/search.lua's own comment about it.
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false, reason = 'access_revoked' })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1, 'must not be silent')
    t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
end)

-- ----------------------------------------------------------------------
-- SECTION D -- netId CAPTURE BEFORE THE SNIFF ANIMATION. Proven by
-- mutating the entity->netId mapping FROM INSIDE the (reentrant)
-- progressBar stub -- i.e. strictly between capture and the eventual
-- server call, modeling a despawn/respawn that reassigns the same entity
-- handle to a different netId mid-animation.
-- ----------------------------------------------------------------------

t.test('netId is captured BEFORE the sniff animation runs -- a mid-animation handle reassignment must not retarget the eventual server call', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.setProgressBarReentrant(function()
        -- Simulates entity handle 500 being despawned and its slot reused
        -- by an unrelated entity with a different netId, strictly DURING
        -- the sniff animation.
        f.setNetIdForEntity(500, 222)
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().args[2], 111,
        'targetNetId must be the value captured BEFORE the animation (111), never the value the mapping was mutated to mid-animation (222)')
end)

-- ----------------------------------------------------------------------
-- SECTION E -- contraband found / nothing found rendering, and the
-- confirmation that THIS FILE never itself broadcasts anything -- the
-- bystander alert is server-initiated only (see this fixture's own
-- deliberate omission of a TriggerServerEvent stub, in its header).
-- ----------------------------------------------------------------------

t.test('a clean contrabandFound == true result notifies search.contraband_found as a success, and NEVER triggers any event itself', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = true, contrabandFound = true, totalWeight = 50, alertTier = 'whine' })
    f.vehicleOption().onSelect({ entity = 500 }) -- would throw if it ever called the unstubbed TriggerServerEvent
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.contraband_found'))
    t.equals(f.notifyCalls[1].type, 'success')
end)

t.test('a clean contrabandFound == false result is a NON-SILENT "nothing found" notify, distinct from every rejection message', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.personOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.nothing_found'))
    t.equals(f.notifyCalls[1].type, 'info')
end)

t.test('the sniff animation label differs between Search Vehicle and Search Person, and the real Config.SearchZones.sniffAnimDurationMs is used for both', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setEntityExists(600, true)
    f.setNetIdForEntity(500, 1)
    f.setNetIdForEntity(600, 2)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.progressBarCalls[1].label, locale('search.progress_vehicle_label'))
    t.equals(f.progressBarCalls[1].duration, f.env.Config.SearchZones.sniffAnimDurationMs)

    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.personOption().onSelect({ entity = 600 })
    t.equals(f.progressBarCalls[2].label, locale('search.progress_person_label'))
end)

-- ----------------------------------------------------------------------
-- SECTION F -- `source ~= 65535` origin guard on
-- 'qbx_k9unit:client:playContrabandAlert'.
--
-- SCOPE NOTE, repeated here rather than left only in this file's header
-- (per this task's own instruction): every test below pins what THIS
-- FILE'S CODE does when `source` holds a given value at call time. NONE
-- of them settle, and none should be read as settling, the underlying
-- engine question this project tracks as open decision D3
-- (PROJECT_STATUS.md) -- whether FiveM's real client runtime can ever be
-- made to deliver a forged local trigger with a stale/incorrect `source`
-- left over from an earlier genuine server-sent event landing on the
-- same connection. Independent attempts to settle D3 by reading the game
-- engine's own source code have repeatedly hit the same wall (four,
-- per PROJECT_STATUS.md's own count as of this session; this task's own
-- brief counts five -- whichever the exact number, neither this test file
-- nor any other Lua-level sandbox test can add or subtract from it).
-- PROJECT_STATUS.md's own words: "Do not settle this by reading more
-- code -- only the live test settles it." A green result below proves the
-- guard AS WRITTEN rejects a non-65535 source; it must never be mistaken
-- for having closed D3.
-- ----------------------------------------------------------------------

t.test('playContrabandAlert: source == 65535 (the documented genuine-server sentinel) is processed', function()
    local f = newSearchFixture()
    f.triggerContrabandAlert(65535, 200, 'whine')
    t.equals(#f.playSoundOnNetworkEntityCalls, 1, 'a genuinely server-sourced call must be processed -- see this section\'s own D3 scope note above')
    t.equals(f.playSoundOnNetworkEntityCalls[1].netId, 200)
    t.equals(f.playSoundOnNetworkEntityCalls[1].soundName, 'whine')
end)

t.test('playContrabandAlert: a forged local trigger with an arbitrary non-65535 numeric source is rejected -- pins the CODE\'s behavior only, D3 remains open regardless (see this section\'s header)', function()
    local f = newSearchFixture()
    f.triggerContrabandAlert(1, 200, 'aggressive_bark')
    t.equals(#f.playSoundOnNetworkEntityCalls, 0)
end)

t.test('playContrabandAlert: source left nil (a bare local TriggerEvent() carrying no origin at all) is also rejected -- same D3 scope caveat as above', function()
    local f = newSearchFixture()
    f.triggerContrabandAlert(nil, 200, 'whine')
    t.equals(#f.playSoundOnNetworkEntityCalls, 0)
end)

os.exit(t.summary())
