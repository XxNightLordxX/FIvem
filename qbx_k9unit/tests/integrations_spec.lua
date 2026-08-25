--[[
    tests/integrations_spec.lua

    Tests for server/integrations.lua (the external-system integration
    surface -- DEVELOPER_REFERENCE.md Part A §7 / Part B §2/§3, see that file's
    own header for the full design writeup) against the REAL, unmodified
    production file, loaded alongside the REAL server/cooldowns.lua (its
    K9DownFireCooldown is a genuine NewCooldown() instance, not a stub --
    exercising the real AssertValidDefaultThreshold guard matters here,
    since this file's own CONFIG-SAFETY GUARD explicitly relies on that
    guard rather than re-checking reFireCooldownMs itself).

    server/certifications.lua is DELIBERATELY NOT loaded -- HasK9Access and
    IsConfiguredK9Model are stubbed directly instead, same "stub, don't
    load, a function already covered by its own file's spec" convention
    wellbeing_spec.lua's own header already establishes for the identical
    pair. HasK9Access is covered by certifications_spec.lua;
    IsConfiguredK9Model likewise.

    Same coroutine thread-runner technique as wellbeing_spec.lua/
    defense_spec.lua/tenure_spec.lua: PollK9Health runs inside a
    `CreateThread(function() while true do Wait(...) ... end end)` loop,
    stepped one pass at a time via fixtures/sandbox.lua's
    Sandbox.newThreadRunner(). GetGameTimer is a test-controlled fake clock
    advanced explicitly between ticks -- Wait() itself does not advance it
    (it is a bare coroutine.yield in the sandbox), matching every other
    spec's own convention for this exact pattern.

    WHAT THIS FILE PROVES, mapped to the task's four required-coverage
    points:
      1. The one outbound event this file adds
         ('qbx_k9unit:events:k9Down') fires with the exact documented
         payload shape (source, citizenid, jobName, coords, health) --
         pinned field-by-field, not just "an event fired."
      2. "A missing/absent operator-configured target is a clean no-op" --
         read here as: a player who is not a qualifying, on-duty, certified
         K9 (not a K9 model, or not currently K9-access-eligible, or not
         even spawned yet) never produces an event, however low their raw
         health reads, and produces no error either.
      3. An operator's own listener THROWING (TriggerEvent's registered
         handler in another resource) is swallowed by FireOutboundEvent's
         own pcall and never aborts this file's poll pass -- proven by a
         later, independent qualifying episode still firing normally on a
         subsequent tick.
      4. No integration path -- no thread, no table allocation, no
         TriggerEvent call, ever -- is reachable when
         Config.Features.K9DownDispatch is false, even with an absent/
         garbage Config.K9DownDispatch tuning table that would otherwise
         fail every CONFIG-SAFETY GUARD assert.

    Beyond those four, also covers: every CONFIG-SAFETY GUARD assert firing
    loudly at load time for its own specific bad value (healthThreshold,
    minDurationMs, pollIntervalMs) plus reFireCooldownMs's guard being
    server/cooldowns.lua's OWN NewCooldown constructor guard (not
    reimplemented here -- see this file's header for why); the
    edge-triggered/debounced firing shape (never fires before
    minDurationMs elapses, fires exactly once per continuous qualifying
    episode, not once per poll tick); a health dip that recovers before
    minDurationMs elapses starting a fresh episode next time rather than
    carrying over stale progress; the per-source re-fire cooldown
    deferring (never dropping) a second episode's announcement; and
    playerDropped clearing a source's in-progress episode so a later
    reconnect starts clean.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture builder
-- ----------------------------------------------------------------------

--- @param opts table? -- { featureEnabled: boolean?, tuning: table? }
--- @return table fixture
local function newIntegrationsFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()
    local createThreadCallCount = 0
    local function CreateThread(fn)
        createThreadCallCount = createThreadCallCount + 1
        threadRunner.CreateThread(fn)
    end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Captures every TriggerEvent call this file makes (there is exactly
    -- one call site, FireOutboundEvent, but this stub does not assume
    -- that -- it just records whatever arrives). `throwForEvent`, when
    -- set, simulates "a registered handler in another resource errored"
    -- for that one event name, exactly the boundary FireOutboundEvent's
    -- own pcall exists to contain.
    local outboundEvents = {} -- { { name = string, args = { ... } }, ... }
    local throwForEvent = nil
    local function TriggerEvent(eventName, ...)
        outboundEvents[#outboundEvents + 1] = { name = eventName, args = { ... } }
        if throwForEvent == eventName then
            error('simulated listener error in another resource')
        end
    end

    local onlinePlayerIds = {}
    local function GetPlayers()
        local out = {}
        for i, id in ipairs(onlinePlayerIds) do out[i] = tostring(id) end
        return out
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end

    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    local accessBySource = {}
    local function HasK9Access(src) return accessBySource[src] == true end

    -- Every ped defaults to 200 (alive, native max health) -- matches
    -- combat_spec.lua's/wellbeing_spec.lua's own default so a fixture that
    -- never calls setHealth behaves as a healthy K9, never an
    -- accidentally-qualifying one.
    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or { x = 0, y = 0, z = 0 } end

    -- exports.qbx_core:GetPlayer(src) -- keyed by source, holds
    -- citizenid/job.name. A source with no entry here simulates a
    -- transient qbx_core resolution miss (see this file's own
    -- "else: a transient exports.qbx_core:GetPlayer resolution miss"
    -- comment) rather than an error.
    local playersBySource = {}
    local function qbxGetPlayer(_self, src)
        local rec = playersBySource[src]
        if not rec then return nil end
        return { PlayerData = { citizenid = rec.citizenid, job = { name = rec.job } } }
    end

    local config = {
        Features = { K9DownDispatch = opts.featureEnabled ~= false },
        K9DownDispatch = opts.tuning,
    }
    if config.K9DownDispatch == nil and opts.featureEnabled ~= false then
        config.K9DownDispatch = {
            healthThreshold  = 100,
            minDurationMs    = 3000,
            pollIntervalMs   = 2000,
            reFireCooldownMs = 30000,
        }
    end

    local env = Sandbox.newEnv({
        GetGameTimer           = GetGameTimer,
        CreateThread           = CreateThread,
        Wait                   = threadRunner.Wait,
        AddEventHandler        = AddEventHandler,
        TriggerEvent           = TriggerEvent,
        print                  = printStub,
        GetPlayers             = GetPlayers,
        GetPlayerPed           = GetPlayerPed,
        GetEntityModel         = GetEntityModel,
        IsConfiguredK9Model    = IsConfiguredK9Model,
        HasK9Access            = HasK9Access,
        GetEntityHealth        = GetEntityHealth,
        GetEntityCoords        = GetEntityCoords,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        exports                = { qbx_core = { GetPlayer = qbxGetPlayer } },
        Config                 = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    Sandbox.loadInto('../server/integrations.lua', env)

    return {
        env = env,
        advance = function(ms) fakeNow = fakeNow + ms end,
        tick = function() threadRunner.step() end,
        setOnline = function(src)
            for _, id in ipairs(onlinePlayerIds) do
                if id == src then return end
            end
            onlinePlayerIds[#onlinePlayerIds + 1] = src
        end,
        setOffline = function(src)
            for i, id in ipairs(onlinePlayerIds) do
                if id == src then
                    table.remove(onlinePlayerIds, i)
                    return
                end
            end
        end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        markK9Model = function(model) k9Models[model] = true end,
        setAccess = function(src, has) accessBySource[src] = has end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setCoords = function(ped, coords) coordsByPed[ped] = coords end,
        setPlayer = function(src, citizenid, job) playersBySource[src] = { citizenid = citizenid, job = job } end,
        clearPlayer = function(src) playersBySource[src] = nil end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers.playerDropped or {}) do
                handler()
            end
        end,
        setThrowForEvent = function(eventName) throwForEvent = eventName end,
        outboundEvents = outboundEvents,
        printedLines = printedLines,
        createThreadCallCount = function() return createThreadCallCount end,
    }
end

--- Convenience: registers one fully-qualifying online K9 (src/ped/model/
--- access/citizenid/job all wired), healthy by default (200).
--- @param f table -- fixture from newIntegrationsFixture
--- @param src number
--- @param ped number
local function registerQualifyingK9(f, src, ped)
    local model = 900000 + ped -- unique per ped, arbitrary
    f.setOnline(src)
    f.setPed(src, ped)
    f.markK9Model(model)
    f.setModel(ped, model)
    f.setAccess(src, true)
    f.setPlayer(src, 'CITIZEN_' .. src, 'police')
end

-- ----------------------------------------------------------------------
-- 1. Feature-flag-off: a clean no-op, even with garbage tuning
-- ----------------------------------------------------------------------

t.test('Config.Features.K9DownDispatch = false starts no thread and asserts nothing, even with a garbage/absent tuning table', function()
    local f = newIntegrationsFixture({ featureEnabled = false, tuning = 'not-a-table' })
    t.equals(f.createThreadCallCount(), 0, 'no thread should ever be created while the feature flag is off')

    registerQualifyingK9(f, 1, 101)
    f.setHealth(101, 0)
    -- No thread exists to step -- confirms stepping is harmless, not that
    -- it does anything.
    f.tick()
    f.advance(999999)
    f.tick()
    t.equals(#f.outboundEvents, 0, 'zero TriggerEvent calls with the feature off, no matter how low health reads')
end)

-- ----------------------------------------------------------------------
-- 2. CONFIG-SAFETY GUARD asserts -- one bad field at a time
-- ----------------------------------------------------------------------

t.test('Config.K9DownDispatch not a table (nil/false in production) while the flag is true fails loudly at load time', function()
    -- `tuning = false` here (never nil) is deliberate: this fixture helper
    -- fills in a valid default tuning table whenever `opts.tuning` is nil
    -- AND the feature is enabled, precisely so every OTHER test in this
    -- file gets a sane default without repeating it -- `false` is the way
    -- to reach this specific "the table itself is missing/wrong-typed"
    -- case instead (any non-table value, including a real nil in
    -- production, hits the exact same `type(tuning) == 'table'` assert).
    local ok, err = pcall(newIntegrationsFixture, { featureEnabled = true, tuning = false })
    t.isFalse(ok)
    t.contains(err, 'Config.K9DownDispatch must be a table')
end)

t.test('healthThreshold <= 0 fails loudly, naming the field', function()
    local ok, err = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 0, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 1000 },
    })
    t.isFalse(ok)
    t.contains(err, 'healthThreshold must be a positive number')
end)

t.test('minDurationMs < 0 fails loudly, naming the field', function()
    local ok, err = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = -1, pollIntervalMs = 1000, reFireCooldownMs = 1000 },
    })
    t.isFalse(ok)
    t.contains(err, 'minDurationMs must be a non-negative number')
end)

t.test('pollIntervalMs <= 0 fails loudly, naming the field', function()
    local ok, err = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 0, reFireCooldownMs = 1000 },
    })
    t.isFalse(ok)
    t.contains(err, 'pollIntervalMs must be a positive number')
end)

t.test('reFireCooldownMs <= 0 fails loudly via server/cooldowns.lua\'s OWN NewCooldown guard, not a reimplementation here', function()
    local ok, err = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 0 },
    })
    t.isFalse(ok)
    -- Exact message belongs to server/cooldowns.lua's AssertValidDefaultThreshold
    -- (see this file's own header for why that is deliberate) -- assert on
    -- its distinguishing substring, not integrations.lua's own wording.
    t.contains(err, 'NewCooldown called with a non-positive/invalid defaultThresholdMs')
end)

-- ----------------------------------------------------------------------
-- 3. Main fire path: exact documented payload
-- ----------------------------------------------------------------------

t.test('a qualifying K9 held at/below threshold for >= minDurationMs fires k9Down exactly once with the documented payload', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 42, 4242)
    f.setCoords(4242, { x = 100.0, y = 200.0, z = 30.0 })
    f.setHealth(4242, 200) -- healthy at first

    f.tick() -- prime (first Wait in the while loop; no pass runs yet)

    f.setHealth(4242, 50) -- drop below threshold (100)
    f.advance(2000)
    f.tick() -- pass 1: episode starts, elapsed 0 < minDurationMs(3000) -- no fire
    t.equals(#f.outboundEvents, 0)

    f.advance(2000)
    f.tick() -- pass 2: elapsed 2000 < 3000 -- still no fire
    t.equals(#f.outboundEvents, 0)

    f.advance(2000)
    f.tick() -- pass 3: elapsed 4000 >= 3000 -- fires now
    t.equals(#f.outboundEvents, 1)

    local ev = f.outboundEvents[1]
    t.equals(ev.name, 'qbx_k9unit:events:k9Down')
    t.equals(ev.args[1], 42, 'source')
    t.equals(ev.args[2], 'CITIZEN_42', 'citizenid')
    t.equals(ev.args[3], 'police', 'jobName')
    t.equals(ev.args[4].x, 100.0, 'coords.x')
    t.equals(ev.args[4].y, 200.0, 'coords.y')
    t.equals(ev.args[4].z, 30.0, 'coords.z')
    t.equals(ev.args[5], 50, 'health at the moment of firing')
end)

t.test('a fired episode never fires a second time while health stays continuously at/below threshold', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 7, 707)
    f.setHealth(707, 200)
    f.tick() -- prime

    f.setHealth(707, 10)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'fired exactly once by now')

    -- Keep polling for a good while longer, still down -- must stay at 1.
    for _ = 1, 5 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'still exactly one fire for the same continuous episode')
end)

-- ----------------------------------------------------------------------
-- 4. Debounce: a graze that recovers before minDurationMs never fires,
--    and does not leave stale progress for a later, real episode
-- ----------------------------------------------------------------------

t.test('a graze that recovers above threshold before minDurationMs elapses never fires', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 5, 505)
    f.setHealth(505, 200)
    f.tick() -- prime

    f.setHealth(505, 50) -- dip
    f.advance(1000)
    f.tick() -- elapsed 0 (episode start) -- no fire yet

    f.setHealth(505, 200) -- healed well before minDurationMs (3000) elapses
    f.advance(1000)
    f.tick() -- health above threshold -- episode resets

    f.advance(999999)
    f.tick() -- still healthy -- nothing to fire
    t.equals(#f.outboundEvents, 0, 'a healed graze must never fire a dispatch alert')
end)

t.test('after a healed graze, a later genuine episode starts its own fresh timer rather than reusing stale progress', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 6, 606)
    f.setHealth(606, 200)
    f.tick() -- prime

    f.setHealth(606, 50)
    f.advance(2000)
    f.tick() -- elapsed 0 this tick (episode just started) -- no fire

    f.setHealth(606, 200) -- healed
    f.advance(100)
    f.tick() -- resets

    -- A GENUINE new episode: must take the full minDurationMs again, not
    -- "finish" off the earlier partial progress.
    f.setHealth(606, 50)
    f.advance(2000)
    f.tick() -- elapsed 0 again (fresh episode) -- no fire
    t.equals(#f.outboundEvents, 0)

    f.advance(3000)
    f.tick() -- elapsed 3000 >= minDurationMs -- fires now
    t.equals(#f.outboundEvents, 1)
end)

-- ----------------------------------------------------------------------
-- 5. "A missing/absent target is a clean no-op" -- non-qualifying players
-- ----------------------------------------------------------------------

t.test('a non-K9-modeled player never fires, however low health reads', function()
    local f = newIntegrationsFixture()
    f.setOnline(8)
    f.setPed(8, 808)
    f.setModel(808, 55) -- never marked as a K9 model
    f.setAccess(8, true)
    f.setPlayer(8, 'NOTAK9', 'police')
    f.setHealth(808, 1)
    f.tick()
    for _ = 1, 5 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 0)
end)

t.test('a K9-modeled player without current K9 access never fires, however low health reads', function()
    local f = newIntegrationsFixture()
    f.setOnline(9)
    f.setPed(9, 909)
    f.markK9Model(77)
    f.setModel(909, 77)
    f.setAccess(9, false) -- decertified / not on duty
    f.setPlayer(9, 'DECERT', 'police')
    f.setHealth(909, 1)
    f.tick()
    for _ = 1, 5 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 0)
end)

t.test('a currently-connected player with no spawned ped (ped == 0) is skipped without error', function()
    local f = newIntegrationsFixture()
    f.setOnline(10) -- online per GetPlayers(), but GetPlayerPed returns 0 (default, never set)
    f.tick()
    local ok = pcall(function()
        f.advance(2000)
        f.tick()
    end)
    t.isTrue(ok, 'must not error when a listed player has no spawned ped yet')
    t.equals(#f.outboundEvents, 0)
end)

-- ----------------------------------------------------------------------
-- 6. Listener-throws containment
-- ----------------------------------------------------------------------

t.test('a registered listener throwing on TriggerEvent is swallowed and logged, never breaking the poll pass', function()
    local f = newIntegrationsFixture()
    f.setThrowForEvent('qbx_k9unit:events:k9Down')

    registerQualifyingK9(f, 11, 1111)
    f.setHealth(1111, 200)
    f.tick() -- prime

    f.setHealth(1111, 10)
    local ok = pcall(function()
        for _ = 1, 3 do
            f.advance(2000)
            f.tick()
        end
    end)
    t.isTrue(ok, 'a throwing listener must never propagate out of the poll thread')
    t.equals(#f.outboundEvents, 1, 'the event still fired (and was recorded) before the simulated listener threw')

    local sawLogLine = false
    for _, line in ipairs(f.printedLines) do
        if line:find('outbound event', 1, true) and line:find('qbx_k9unit:events:k9Down', 1, true) then
            sawLogLine = true
        end
    end
    t.isTrue(sawLogLine, 'the swallowed listener error should be logged, not silently dropped')
end)

t.test('after a listener throw, a later INDEPENDENT episode (different source) still fires normally -- the poll loop is not wedged', function()
    local f = newIntegrationsFixture()
    f.setThrowForEvent('qbx_k9unit:events:k9Down')

    registerQualifyingK9(f, 12, 1212)
    registerQualifyingK9(f, 13, 1313)
    f.setHealth(1212, 200)
    f.setHealth(1313, 200)
    f.tick() -- prime

    f.setHealth(1212, 5)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'first K9 fired once despite its own listener throwing')

    -- Second K9 goes down independently afterward -- must still be detected
    -- and fired for, proving the earlier throw did not wedge PollK9Health.
    f.setHealth(1313, 5)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 2, 'second, independent K9 also fired')
    t.equals(f.outboundEvents[2].args[1], 13, 'the second event is for the second source')
end)

-- ----------------------------------------------------------------------
-- 7. Per-source re-fire cooldown: defers, never silently drops
-- ----------------------------------------------------------------------

t.test('a second episode within reFireCooldownMs of the first fire is deferred, then fires as soon as the cooldown clears while still down', function()
    local f = newIntegrationsFixture({
        tuning = { healthThreshold = 100, minDurationMs = 1000, pollIntervalMs = 1000, reFireCooldownMs = 10000 },
    })
    registerQualifyingK9(f, 14, 1414)
    f.setHealth(1414, 200)
    f.tick() -- prime

    -- First episode: fires at elapsed >= 1000.
    f.setHealth(1414, 10)
    f.advance(1000)
    f.tick() -- elapsed 0 -- no fire
    f.advance(1000)
    f.tick() -- elapsed 1000 -- fires (t = 2000)
    t.equals(#f.outboundEvents, 1)

    -- Recover, then go down again quickly (well within the 10000ms
    -- reFireCooldownMs window) and STAY down.
    f.setHealth(1414, 200)
    f.advance(500)
    f.tick() -- healthy tick, episode resets (t = 2500)

    f.setHealth(1414, 10)
    f.advance(1000)
    f.tick() -- episode starts (t = 3500)
    f.advance(1000)
    f.tick() -- elapsed 1000 >= minDurationMs, but cooldown from the first fire (stamped at t=2000, 10000ms window) is still active -- deferred (t = 4500)
    t.equals(#f.outboundEvents, 1, 'second episode qualifies but must be deferred by the still-active re-fire cooldown')

    -- Keep polling, still continuously down, until the cooldown clears
    -- (t >= 2000 + 10000 = 12000).
    for _ = 1, 8 do
        f.advance(1000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 2, 'the deferred episode must still fire once the cooldown clears, not be lost forever')
    t.equals(f.outboundEvents[2].args[1], 14)
end)

-- ----------------------------------------------------------------------
-- 8. playerDropped clears in-progress episode state
-- ----------------------------------------------------------------------

t.test('playerDropped clears an in-progress episode -- a later reconnect must start a fresh timer, not resume stale progress', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 15, 1515)
    f.setHealth(1515, 200)
    f.tick() -- prime

    f.setHealth(1515, 10)
    f.advance(1000)
    f.tick() -- episode starts, elapsed 0 -- no fire (needs 3000)
    t.equals(#f.outboundEvents, 0)

    -- Disconnect mid-episode.
    f.firePlayerDropped(15)
    f.setOffline(15)
    f.clearPlayer(15)

    -- Reconnect as a fresh session for the same logical player/source,
    -- still unhealthy from the very first poll tick after reconnecting.
    registerQualifyingK9(f, 15, 1515)
    f.setHealth(1515, 10)
    f.advance(3000) -- would have been more than enough to fire on STALE progress
    f.tick()
    t.equals(#f.outboundEvents, 0, 'a cleared episode must not fire off progress from before the disconnect')

    -- But a genuinely full-length episode after reconnecting still works.
    f.advance(3000)
    f.tick()
    t.equals(#f.outboundEvents, 1, 'a real, full-length post-reconnect episode still fires')
end)

os.exit(t.summary())
