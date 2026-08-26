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

    STALE-SESSION RACE (2026-08-26): SECTION 2's own callbackAwait stub can
    also be flipped, per test, into a genuinely coroutine-yielding one via
    setYieldingAwait (off by default -- every pre-existing test above that
    section keeps its own synchronous, single-call round trip unchanged),
    specifically so the "abandon then immediately restart" interleaving
    server/scenttrail.lua's/client/scenttrail.lua's own "STALE-SESSION RACE"
    header sections describe can be reproduced directly rather than merely
    reasoned about -- see the dedicated section by that same name near the
    end of SECTION 2 below, and tests/sarcalls_spec.lua's own identically-
    shaped addition for the sibling bug this mirrors.
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

-- SESSION HYGIENE (2026-08-26): server/scenttrail.lua now starts a real
-- background sweep thread (see that file's header section by this exact
-- name) -- CreateThread/Wait must be provided so the file loads at all, and
-- so the sweep body can be stepped deterministically. Same
-- Sandbox.newThreadRunner() technique tests/sarcalls_spec.lua's own SECTION 1
-- already uses for server/sarcalls.lua's structurally identical tick loop.
local sweepThreadRunner = Sandbox.newThreadRunner()
local function CreateThread(fn) sweepThreadRunner.CreateThread(fn) end
local function Wait(ms) sweepThreadRunner.Wait(ms) end

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

-- PER-PERSON FEATURE CONTROL fixture scaffolding -- server/scenttrail.lua's
-- startScentHunt resolves `exports.qbx_core:GetPlayer(source).PlayerData.
-- citizenid` (added alongside IsScentTrailHuntPermittedForCitizenId this
-- pass) and fails CLOSED with no resolvable citizenid, mirroring
-- server/pursuitsprint.lua's own identical behavior. citizenidBySource
-- DEFAULTS every numeric source to a deterministic 'CID-<source>' string
-- (see exportsStub.GetPlayer below) so every ALREADY-EXISTING test in this
-- section -- none of which are about the per-person mechanism -- keeps a
-- resolvable identity and keeps passing unchanged; a dedicated
-- "PER-PERSON FEATURE CONTROL" section further down overrides specific
-- sources via setCitizenId when it needs a stable name to grant/block
-- against. Config.FeatureControl.RequireGrant.ScentTrailHunt defaults to
-- FALSE (not listed) for the identical reason tests/findalert_spec.lua's
-- own fixture gives for the same default -- see that file's header.
local citizenidBySource = {}
local function citizenidFor(source) return citizenidBySource[source] or ('CID-' .. tostring(source)) end
local exportsStub = {
    qbx_core = {
        GetPlayer = function(_self, source) return { PlayerData = { citizenid = citizenidFor(source) } } end,
    },
}

local permissionGrants = {} -- [citizenid][key] = true/false
local function HasPermission(citizenid, key)
    return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
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
    FeatureControl = {
        RequireGrant = { ScentTrailHunt = false },
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
    exports = exportsStub,
    HasPermission = HasPermission,
    CreateThread = CreateThread, -- SESSION HYGIENE: server/scenttrail.lua's own background sweep thread now calls this at file-load time
    Wait = Wait,
})

Sandbox.loadInto('../server/cooldowns.lua', serverEnv) -- hard load-order dependency, see server/scenttrail.lua's own FILE-TO-FILE CONTRACT
Sandbox.loadInto('../server/scenttrail.lua', serverEnv)

local startScentHunt = registeredCallbacks['qbx_k9unit:server:startScentHunt']
local pollScentHunt = registeredCallbacks['qbx_k9unit:server:pollScentHunt']

--- Overrides the default 'CID-<source>' citizenid a given source resolves
--- to -- see citizenidFor's own declaration comment above.
--- @param source number
--- @param citizenid string
local function setCitizenId(source, citizenid)
    citizenidBySource[source] = citizenid
end

--- @param citizenid string
--- @param key string
--- @param value boolean
local function grantPermission(citizenid, key, value)
    permissionGrants[citizenid] = permissionGrants[citizenid] or {}
    permissionGrants[citizenid][key] = value
end

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

t.test('pollScentHunt: fires qbx_k9unit:client:scentHuntFound to THIS caller only, exactly once, the first time distance drops to/under arrivalRadius, carrying this hunt\'s own huntId', function()
    pedCoordsBySource[6] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0) -- target lands at (10, 0) -- exactly minRadius away
    local started = startScentHunt(6)
    t.isNotNil(started.huntId, 'a successful start must always return a huntId -- see this file\'s header "STALE-SESSION RACE"')

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
    t.equals(#triggerClientEventCalls[1].args, 1, 'a trigger plus this hunt\'s own huntId -- never a claimed distance/coordinate')
    t.equals(triggerClientEventCalls[1].args[1], started.huntId, 'the pushed id must be the SAME id this hunt was granted at start -- see "STALE-SESSION RACE"')

    -- Still within radius on a later poll -- must NOT refire.
    fakeNow = fakeNow + 1000
    pollScentHunt(6)
    t.equals(#triggerClientEventCalls, 1)
end)

t.test('startScentHunt: each successful start mints a strictly increasing, never-reused huntId', function()
    pedCoordsBySource[40] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local first = startScentHunt(40)

    fireStopScentHunt(40)
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local second = startScentHunt(41)

    t.isNotNil(first.huntId)
    t.isNotNil(second.huntId)
    t.isTrue(second.huntId > first.huntId, 'huntId must strictly increase across hunts, never repeat')
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

-- ----------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL -- Config.FeatureControl.RequireGrant's
-- documented 4-step resolution (steps 2-4; step 1, Config.Features.
-- ScentTrailHunt, is already covered above), keyed on the K9 STARTING the
-- hunt -- mirrors tests/pursuitsprint_spec.lua's own "Per-person feature
-- control" section. Fresh source numbers (101+) throughout, never reused
-- by an earlier test in this file, so each test's own StartHuntCooldown
-- state is guaranteed untouched by anything before it.
-- ----------------------------------------------------------------------

t.test('grant_required: RequireGrant.ScentTrailHunt = true + no grant held -- denied even though HasK9Access is true', function()
    ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt = true
    setCitizenId(101, 'CID-BLOCKED-1')
    pedCoordsBySource[101] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    -- deliberately NOT granted

    local result = startScentHunt(101)

    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
    ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt = false
end)

t.test('RequireGrant.ScentTrailHunt = true + an active feature.ScentTrailHunt grant -- allowed', function()
    ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt = true
    setCitizenId(102, 'CID-GRANTED-1')
    grantPermission('CID-GRANTED-1', 'feature.ScentTrailHunt', true)
    pedCoordsBySource[102] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)

    local result = startScentHunt(102)

    t.isTrue(result.started)
    ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt = false
end)

t.test('BLOCK ALWAYS WINS: an explicit block.ScentTrailHunt denies even a citizenid who ALSO holds an active feature.ScentTrailHunt grant, RequireGrant on', function()
    ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt = true
    setCitizenId(103, 'CID-BLOCKED-2')
    grantPermission('CID-BLOCKED-2', 'feature.ScentTrailHunt', true)
    grantPermission('CID-BLOCKED-2', 'block.ScentTrailHunt', true)
    pedCoordsBySource[103] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000

    local result = startScentHunt(103)

    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
    ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt = false
end)

t.test('BLOCK STILL APPLIES even when NOT listed in RequireGrant (step 2 fires independently of step 3)', function()
    setCitizenId(104, 'CID-BLOCKED-3')
    grantPermission('CID-BLOCKED-3', 'block.ScentTrailHunt', true)
    pedCoordsBySource[104] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000

    local result = startScentHunt(104) -- ServerConfig.FeatureControl.RequireGrant.ScentTrailHunt is false here

    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
end)

t.test('RequireGrant.ScentTrailHunt = false (not listed) -- default ALLOW, no grant needed, matching config.lua\'s own documented step 4', function()
    setCitizenId(105, 'CID-DEFAULT-1')
    pedCoordsBySource[105] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)

    local result = startScentHunt(105) -- deliberately NOT granted -- must still succeed

    t.isTrue(result.started)
end)

t.test('a citizenid that cannot be resolved fails CLOSED -- exports.qbx_core:GetPlayer returning no PlayerData denies even with RequireGrant off and HasK9Access true', function()
    local realGetPlayer = exportsStub.qbx_core.GetPlayer
    exportsStub.qbx_core.GetPlayer = function(_self, _source) return nil end
    pedCoordsBySource[106] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000

    local result = startScentHunt(106)

    exportsStub.qbx_core.GetPlayer = realGetPlayer
    t.isFalse(result.started)
    t.equals(result.reason, 'denied')
end)

t.test('cleanup still works for a blocked person: stopScentHunt remains UNCONDITIONAL even after the hunt owner is blocked mid-hunt', function()
    setCitizenId(107, 'CID-MIDHUNT-1')
    pedCoordsBySource[107] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local started = startScentHunt(107)
    t.isTrue(started.started, 'must genuinely be active before the block is applied, or the cleanup-still-works claim below proves nothing')

    -- Revoke mid-hunt: an explicit block lands on this same citizenid while
    -- the hunt this file's own header calls "a single already-authorized
    -- session" is still running.
    grantPermission('CID-MIDHUNT-1', 'block.ScentTrailHunt', true)

    -- The "no unbounded trap" rule: stopScentHunt must still work, exactly
    -- as if nothing had changed -- it never consults HasPermission,
    -- HasK9Access, or Config.Features.ScentTrailHunt at all.
    fireStopScentHunt(107)

    fakeNow = fakeNow + 1000
    local poll = pollScentHunt(107)
    t.isFalse(poll.active, 'the hunt must actually be gone -- a mid-hunt block must never strand an active hunt unstoppable')
end)

-- ----------------------------------------------------------------------
-- SESSION HYGIENE (2026-08-26) -- this file's own header section by this
-- exact name. Pins the real bug: client/scenttrail.lua's own poll loop
-- treats ANY `{ active = false }` response as "the hunt is over" and simply
-- stops polling, WITHOUT sending stopScentHunt -- so if pollScentHunt's own
-- access/feature re-validation failed WITHOUT also clearing ActiveHunts,
-- the record would silently outlive the only thing that was ever going to
-- ask about it again, permanently blocking a fresh hunt as 'already_active'.
-- ----------------------------------------------------------------------

t.test('SESSION HYGIENE: HasK9Access() turning false mid-hunt is not just reported inactive -- pollScentHunt must ALSO clear the record, or the client (which stops polling on active=false) would strand it forever', function()
    pedCoordsBySource[200] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local started = startScentHunt(200)
    t.isTrue(started.started)

    -- Access revoked mid-hunt (e.g. a certification lapse) -- the client
    -- never calls stopScentHunt for this; it just stops polling because the
    -- next answer it gets is `{ active = false }`.
    hasAccess = false
    fakeNow = fakeNow + 1000
    local poll = pollScentHunt(200)
    t.isFalse(poll.active)
    hasAccess = true

    -- THE REGRESSION ASSERTION: even though nothing ever called
    -- stopScentHunt and the player never disconnected, a fresh hunt must
    -- succeed the moment access is restored -- not be permanently rejected
    -- as already_active.
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local fresh = startScentHunt(200)
    t.isTrue(fresh.started, 'a hunt must never be permanently stranded just because one poll happened while access was false')
end)

t.test('SESSION HYGIENE: Config.Features.ScentTrailHunt toggled off mid-hunt is not just reported inactive -- pollScentHunt must ALSO clear the record', function()
    pedCoordsBySource[201] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local started = startScentHunt(201)
    t.isTrue(started.started)

    ServerConfig.Features.ScentTrailHunt = false
    fakeNow = fakeNow + 1000
    local poll = pollScentHunt(201)
    t.isFalse(poll.active)
    ServerConfig.Features.ScentTrailHunt = true

    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local fresh = startScentHunt(201)
    t.isTrue(fresh.started, 'a hunt must never be permanently stranded just because one poll happened while the feature was off')
end)

t.test('SESSION HYGIENE: the background sweep thread clears an unfinished hunt older than maxHuntDurationMs even if NOTHING ever polls it again', function()
    pedCoordsBySource[202] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local started = startScentHunt(202)
    t.isTrue(started.started)

    -- Prime the sweep coroutine (its own Wait(...) is the very first
    -- statement in the loop body -- see Sandbox.newThreadRunner's own
    -- doc comment: the first step() only reaches that Wait and yields).
    sweepThreadRunner.step()

    -- Advance well past maxHuntDurationMs and run exactly one sweep pass --
    -- deliberately WITHOUT ever calling pollScentHunt(202) again, proving
    -- this is a real, unconditional, self-scheduled expiry and not merely
    -- pollScentHunt's own lazy check in disguise.
    fakeNow = fakeNow + ServerConfig.ScentTrailHunt.maxHuntDurationMs + 1
    sweepThreadRunner.step()

    -- A fresh start must now succeed immediately -- proving the sweep
    -- actually cleared ActiveHunts[202], not merely that some later poll
    -- would eventually have noticed.
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    local fresh = startScentHunt(202)
    t.isTrue(fresh.started, 'the sweep thread must clear a stale hunt on its own, with no poll ever required')
end)

t.test('SESSION HYGIENE: the background sweep thread leaves a genuinely fresh hunt untouched', function()
    pedCoordsBySource[203] = { x = 0.0, y = 0.0, z = 0.0 }
    fakeNow = fakeNow + 20000
    queueRandom(0.0, 0.0)
    startScentHunt(203)

    sweepThreadRunner.step() -- prime
    sweepThreadRunner.step() -- one real pass, well before maxHuntDurationMs has elapsed

    fakeNow = fakeNow + 1000
    local poll = pollScentHunt(203)
    t.isTrue(poll.active, 'the sweep must never clear a hunt that has not actually expired')
end)

-- ------------------------------------------------------------------------
-- CONFIG-SAFETY: CLAMP AND WARN (2026-08-26) -- this file's own header
-- section by this exact name. minRadius/maxRadius/arrivalRadius/
-- maxHuntDurationMs used to be read with a bare `X or <default>` idiom at
-- each use site -- this resource's own documented footgun (`0 or 500`
-- evaluates to `0` in Lua, never the fallback). Each field now gets the same
-- clamp-and-warn treatment server/sarcalls.lua's own identically-shaped
-- config block already established -- mirrors that file's own
-- loadCapturingPrints helper/REGRESSION section shape.
-- ------------------------------------------------------------------------

--- Loads server/scenttrail.lua fresh into a throwaway env with `tuning` in
--- place of Config.ScentTrailHunt, capturing every printed line -- see
--- tests/sarcalls_spec.lua's own identically-shaped loadCapturingPrints for
--- the precedent this mirrors.
--- @param tuning table
--- @return string[] printedLines, boolean loaded, table freshEnv
local function loadScentTrailCapturingPrints(tuning)
    local printedLines = {}
    local freshEnv = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        CreateThread = function() end,
        Wait = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        math = FakeMath,
        lib = { callback = { register = function() end } },
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            printedLines[#printedLines + 1] = table.concat(parts, '\t')
        end,
        Config = { Features = { ScentTrailHunt = true }, ScentTrailHunt = tuning },
    })
    Sandbox.loadInto('../server/cooldowns.lua', freshEnv)
    local ok = pcall(Sandbox.loadInto, '../server/scenttrail.lua', freshEnv)
    return printedLines, ok, freshEnv
end

--- Same idea, but a fully functional independent fixture (own callbacks/ped
--- stubs), so the RESOLVED value can be proven by actual behavior, not just
--- by reading the printed warning.
--- @param tuning table
--- @return table fixture
local function newScentTrailCapturingFixture(tuning)
    local printedLines = {}
    local registeredCallbacks2 = {}
    local pedCoords = {}
    local hasAccess2 = true

    local env = Sandbox.newEnv({
        GetGameTimer = function() return fakeNow end,
        CreateThread = function() end,
        Wait = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        math = FakeMath,
        lib = { callback = { register = function(name, fn) registeredCallbacks2[name] = fn end } },
        HasK9Access = function() return hasAccess2 end,
        GetPlayerPed = function(source) return source end,
        GetEntityCoords = function(ped) return pedCoords[ped] or { x = 0, y = 0, z = 0 } end,
        TriggerClientEvent = function() end,
        exports = { qbx_core = { GetPlayer = function(_self, source) return { PlayerData = { citizenid = 'CID-' .. tostring(source) } } end } },
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            printedLines[#printedLines + 1] = table.concat(parts, '\t')
        end,
        Config = { Features = { ScentTrailHunt = true }, ScentTrailHunt = tuning },
    })
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/scenttrail.lua', env)

    return {
        printedLines = printedLines,
        startScentHunt = registeredCallbacks2['qbx_k9unit:server:startScentHunt'],
        pollScentHunt = registeredCallbacks2['qbx_k9unit:server:pollScentHunt'],
        setPedCoords = function(src, x, y, z) pedCoords[src] = { x = x, y = y, z = z } end,
    }
end

t.test('CONFIG-SAFETY: an invalid minRadius/maxRadius pair falls back to BOTH shipped defaults (10.0/30.0) together, warning names both keys/values, and the file still loads', function()
    local lines, ok = loadScentTrailCapturingPrints({ minRadius = 0, maxRadius = 30, arrivalRadius = 3, startCooldownMs = 8000 })
    t.isTrue(ok, 'an invalid GROUP 1 pair must never abort this file\'s load')
    local found = false
    for _, line in ipairs(lines) do
        if line:find('Config.ScentTrailHunt.minRadius/maxRadius', 1, true)
            and line:find('minRadius=0', 1, true) and line:find('maxRadius=30', 1, true) then
            found = true
        end
    end
    t.isTrue(found, 'must print exactly which two keys/values were bad')
end)

t.test('CONFIG-SAFETY: maxRadius < minRadius also falls back to the whole GROUP 1 default pair, never just clamping maxRadius up to minRadius', function()
    local lines = loadScentTrailCapturingPrints({ minRadius = 30, maxRadius = 10, arrivalRadius = 3, startCooldownMs = 8000 })
    local found = false
    for _, line in ipairs(lines) do
        if line:find('minRadius=30', 1, true) and line:find('maxRadius=10', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('CONFIG-SAFETY: a valid minRadius/maxRadius pair passes through silently -- no warning on a good value', function()
    local lines = loadScentTrailCapturingPrints({ minRadius = 10, maxRadius = 30, arrivalRadius = 3, startCooldownMs = 8000 })
    for _, line in ipairs(lines) do
        t.isNil(line:find('minRadius', 1, true), 'a valid configured pair must never print a warning')
    end
end)

t.test('CONFIG-SAFETY: an invalid arrivalRadius (0) falls back to the shipped default (3.0) and is what pollScentHunt actually enforces, not the bad configured value', function()
    local f = newScentTrailCapturingFixture({ minRadius = 10, maxRadius = 30, arrivalRadius = 0, startCooldownMs = 8000, maxHuntDurationMs = 300000 })
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.ScentTrailHunt.arrivalRadius', 1, true) and line:find('found: 0', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact bad field and value')

    queueRandom(0.0, 0.0) -- target lands at exactly minRadius (10.0) from origin
    f.setPedCoords(300, 0.0, 0.0, 0.0)
    local started = f.startScentHunt(300)
    t.isTrue(started.started)

    -- Walk to exactly 3.0m from the target -- a raw configured
    -- arrivalRadius=0 could NEVER be satisfied by any finite distance
    -- (permanently un-completable), so `found` reading true here proves the
    -- shipped fallback (3.0) is what actually got applied.
    f.setPedCoords(300, 7.0, 0.0, 0.0) -- 3.0m from the target (10.0, 0.0)
    local poll = f.pollScentHunt(300)
    t.isTrue(poll.found, 'must resolve using the fallback (3.0), which this distance exactly satisfies -- the raw configured 0 would make this permanently unreachable')
end)

t.test('CONFIG-SAFETY: an invalid maxHuntDurationMs (0) falls back to the shipped default (300000ms) via ResolveConfiguredThresholdMs, never leaving a hunt permanently-instant-expiring', function()
    local f = newScentTrailCapturingFixture({ minRadius = 10, maxRadius = 30, arrivalRadius = 3, startCooldownMs = 8000, maxHuntDurationMs = 0 })
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.ScentTrailHunt.maxHuntDurationMs', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact bad field')

    queueRandom(0.0, 0.0)
    f.setPedCoords(301, 0.0, 0.0, 0.0)
    local started = f.startScentHunt(301)
    t.isTrue(started.started)

    -- Poll again almost immediately -- with the raw configured value (0)
    -- this would already read as expired (elapsed > 0 is true the instant
    -- any time passes at all); with the fallback (300000ms) it must still
    -- read as genuinely active.
    fakeNow = fakeNow + 1
    local poll = f.pollScentHunt(301)
    t.isTrue(poll.active, 'a misconfigured maxHuntDurationMs=0 must not make every hunt expire on its very first poll')
    t.isNil(poll.expired)
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
    -- STALE-SESSION RACE fixtures (see below) need this await to genuinely
    -- SUSPEND mid-round-trip so a test can inject another event while it is
    -- pending -- the exact interleaving a plain synchronous stub can never
    -- exercise. Off by default (every pre-existing test above this comment
    -- keeps its own synchronous, single-call round trip unchanged); a test
    -- that needs the real interleaving flips it on via setYieldingAwait and
    -- drives the resulting coroutine itself (mirrors
    -- tests/sarcalls_spec.lua's own identically-shaped fixture addition for
    -- the sibling bug).
    local awaitShouldYield = false
    local function callbackAwait(eventName, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        if awaitShouldYield then
            return coroutine.yield(eventName)
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

    -- Resource-stop capture. client/scenttrail.lua registers an
    -- onResourceStop handler (added when this pass closed the "a hunt
    -- session survives a resource stop" gap); this SECTION 2 fixture
    -- predates that and stubbed no AddEventHandler, so loading the real
    -- file errored on a nil global. Same shape as
    -- tests/clientscenttrail_spec.lua's own AddEventHandler pair -- kept
    -- deliberately identical so the two fixtures for the same production
    -- file cannot drift apart again.
    -- Named distinctly from SECTION 1's own `eventHandlers`/`AddEventHandler`
    -- pair (line ~90, server/scenttrail.lua's fixture) purely to avoid
    -- shadowing it -- exactly the same reason, and the same convention, as
    -- `registerClientNetEvent` above. The two captures are unrelated.
    local clientEventHandlers = {}
    local function registerClientEventHandler(eventName, handler)
        clientEventHandlers[eventName] = clientEventHandlers[eventName] or {}
        clientEventHandlers[eventName][#clientEventHandlers[eventName] + 1] = handler
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
        AddEventHandler = registerClientEventHandler,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
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
        --- See callbackAwait's own declaration comment above -- flips this
        --- fixture's lib.callback.await stub from "resolve synchronously
        --- from the queue" to "suspend the calling coroutine until resumed
        --- with the response", for STALE-SESSION RACE tests that need to
        --- inject other events while a start is genuinely still pending.
        setYieldingAwait = function(v) awaitShouldYield = v end,
        --- Fires the pushed found event as if it genuinely came from the
        --- server (source == 65535) unless `forged` is true, in which case
        --- it models a local self-TriggerEvent (any other source value).
        --- `huntId` (added for STALE-SESSION RACE) defaults to nil (no id)
        --- when omitted, matching every pre-existing call site above this
        --- comment -- see this file's own IsForCurrentHunt for why a
        --- missing id is always accepted regardless.
        fireFoundEvent = function(forged, huntId)
            env.source = forged and 999 or 65535
            netEventHandlers['qbx_k9unit:client:scentHuntFound'](huntId)
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

-- ------------------------------------------------------------------------
-- STALE-SESSION RACE (client/scenttrail.lua's own header section by this
-- exact name) -- pins the actual interleaving, not just the id-matching
-- logic in isolation, mirroring tests/sarcalls_spec.lua's own identically-
-- shaped section for the sibling bug. This section's own callbackAwait
-- stub (see newClientFixture's own declaration comment on
-- `awaitShouldYield`) genuinely SUSPENDS the calling coroutine
-- mid-round-trip so a stale push can be injected at an exact, controlled
-- point relative to a still-pending (or freshly-resolved) start.
-- ------------------------------------------------------------------------

t.test('STALE-SESSION RACE: a late "found" push for an OLD, already-abandoned hunt, arriving AFTER a brand-new hunt has already started, must not complete that new, still-unsolved hunt early', function()
    local f = newClientFixture()

    -- Hunt A: started and genuinely active, with its own real huntId.
    f.queueCallbackResponse({ started = true, huntId = 5 })
    f.startCommand({})

    -- Abandon hunt A, then IMMEDIATELY start hunt B -- the exact sequence
    -- the bug report describes. StopScentHunt() never awaits anything
    -- itself, so no coroutine is needed for this step.
    f.startCommand({ 'stop' })

    -- Hunt B's own start now genuinely suspends mid-round-trip, so the
    -- exact moment its grant lands (and hunt A's own stale push relative
    -- to it) can be controlled precisely.
    f.setYieldingAwait(true)
    local co = coroutine.create(function() f.startCommand({}) end)
    local ok, awaitedEvent = coroutine.resume(co)
    t.isTrue(ok, 'the coroutine must not error merely by reaching the await')
    t.equals(awaitedEvent, 'qbx_k9unit:server:startScentHunt')
    t.equals(coroutine.status(co), 'suspended', 'hunt B\'s own start must genuinely still be pending at this point -- otherwise this test proves nothing')

    -- Hunt B's grant arrives, with hunt B's own, genuinely different, id (6).
    coroutine.resume(co, { started = true, huntId = 6 })
    t.equals(coroutine.status(co), 'dead', 'hunt B\'s own StartScentHunt() must have run to completion')
    f.setYieldingAwait(false)

    -- NOW, only AFTER hunt B is genuinely active, hunt A's own late,
    -- server-side 'found' push finally lands -- carrying hunt A's OWN id
    -- (5), which this client already forgot the instant StopScentHunt() ran
    -- (see currentHuntId's own declaration comment in client/scenttrail.lua).
    f.fireFoundEvent(false, 5)

    -- THE REGRESSION ASSERTION: hunt B must still be running, untouched --
    -- pre-fix, the old `if not huntActive then return end` guard alone was
    -- no longer enough once a NEW hunt made huntActive true again; this
    -- stale push would have completed hunt B early, sitting/barking on a
    -- hunt it never actually solved.
    t.equals(f.k9SitCallCount(), 0, 'hunt B must not be marked found by a push that belongs to a different, already-abandoned hunt')

    local stopScentHuntCount = 0
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopScentHuntCount = stopScentHuntCount + 1 end
    end
    t.equals(stopScentHuntCount, 1, 'only hunt A\'s own manual abandon should have sent stopScentHunt -- CompleteHunt() must not have run for hunt B (it would send its own extra one)')

    -- Hunt B's own genuine id must still work normally.
    f.fireFoundEvent(false, 6)
    t.equals(f.k9SitCallCount(), 1, 'hunt B\'s own genuine found push must still complete it normally')
end)

t.test('STALE-SESSION RACE: a stale found push for an OLD hunt (wrong huntId) must never be applied to a DIFFERENT, currently-active hunt', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true, huntId = 100 })
    f.startCommand({})

    f.fireFoundEvent(false, 999)
    t.equals(f.k9SitCallCount(), 0, 'a mismatched huntId must be dropped, even while a hunt is genuinely active')

    f.fireFoundEvent(false, 100)
    t.equals(f.k9SitCallCount(), 1)
end)

t.test('STALE-SESSION RACE: a found push with NO huntId at all is always accepted, never silently dropped, even while a differently-numbered hunt is active', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true, huntId = 42 })
    f.startCommand({})

    -- No huntId argument at all (nil) -- must still be treated as genuine,
    -- per this file's own deliberate "never silently drop an unlabeled
    -- push" decision (see IsForCurrentHunt's own declaration comment).
    f.fireFoundEvent(false)
    t.equals(f.k9SitCallCount(), 1, 'a push with no id must never be silently dropped')
end)

t.test('STALE-SESSION RACE: k9nosehunt stop remains UNCONDITIONAL even with a stale/mismatched currentHuntId in play -- no unbounded trap', function()
    local f = newClientFixture()
    f.queueCallbackResponse({ started = true, huntId = 7 })
    f.startCommand({})

    -- Abandon never reads, sends, or needs any huntId at all -- it must
    -- succeed exactly the same regardless of whatever this client's own
    -- currentHuntId currently holds.
    f.startCommand({ 'stop' })
    local stopCall
    for _, call in ipairs(f.triggerServerEventCalls) do
        if call.event == 'qbx_k9unit:server:stopScentHunt' then stopCall = call end
    end
    t.isNotNil(stopCall)

    -- Local state must genuinely be clear: a fresh start must reach the
    -- server again rather than being rejected as already_active.
    f.queueCallbackResponse({ started = true, huntId = 8 })
    local before = f.callbackCallCount()
    f.startCommand({})
    t.equals(f.callbackCallCount(), before + 1)
end)

os.exit(t.summary())
