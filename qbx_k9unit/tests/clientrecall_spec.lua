--[[
    tests/clientrecall_spec.lua

    Direct, black-box tests of client/recall.lua against the REAL,
    unmodified production file -- the client half of Config.Features.Recall
    (server/recall.lua's own "Recall actor", DEVELOPER_REFERENCE.md §12.5.1).
    This is the smallest of the six client files this pass writes a spec
    for (see tests/vehiclecombatguard_spec.lua's own header, whose disclosed
    gap this pass exists to close): one resource-global (`RequestRecall`),
    one `RegisterCommand`, zero `RegisterNetEvent` handlers, zero
    `CreateThread` calls, zero `AddEventHandler` calls, and zero locally
    tracked state of any kind.

    THE ONE THING WORTH BELABORING, per this file's own header ("TERMINATION
    MUST NEVER BE GATED"): `RequestRecall()` calls NEITHER `CanShowK9UI()`
    NOR `DenyK9UIAccess()` NOR any local plausibility check -- unlike every
    other spec in this batch, this fixture does not even DEFINE those two
    globals, so a future regression that added a gate check would fail this
    spec LOUDLY with "attempt to call a nil value" rather than silently
    passing a fixture that happened to stub the gate open. That absence is
    deliberate, not an oversight -- see the "any ped / no gate at all"
    section below.

    FIXTURE CONFIG, NOT REAL config.lua -- per this suite's established
    convention (tests/clientcombat_spec.lua's own header), this fixture
    builds its own local `Config` table with only the one field this file
    reads at load time (`Config.Features.Recall`), never the real
    config.lua -- this spec keeps passing regardless of which way
    config.lua's other feature flags are set on any given day.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local RESOURCE_NAME = 'qbx_k9unit'

--- Builds one fresh, independent sandbox for client/recall.lua.
--- @param opts { recall: boolean? }?
--- @return table fixture
local function newRecallFixture(opts)
    opts = opts or {}

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local commands = {}
    local function RegisterCommand(name, handler, restricted)
        commands[#commands + 1] = { name = name, handler = handler, restricted = restricted }
    end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local threadCount = 0
    local function CreateThread(_fn) threadCount = threadCount + 1 end

    local config = { Features = { Recall = opts.recall ~= false } }

    -- Deliberately NO CanShowK9UI/DenyK9UIAccess/IsOwnModelK9/HasK9Access
    -- entries here at all -- see this file's own header. If client/recall.lua
    -- is ever changed to call any of those, every test below that calls
    -- RequestRecall() will fail with a loud "attempt to call a nil value"
    -- rather than silently passing against an accidentally-permissive stub.
    local env = Sandbox.newEnv({
        Config = config,
        TriggerServerEvent = TriggerServerEvent,
        RegisterCommand = RegisterCommand,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = CreateThread,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    })

    Sandbox.loadInto('../client/recall.lua', env)

    return {
        env = env,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        commands = commands,
        threadCount = function() return threadCount end,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEvents) do n = n + 1 end
            return n
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
    }
end

-- ========================================================================
-- Feature off: genuinely inert. This file HAS a real top-of-file
-- `if not Config.Features.Recall then return end` gate (unlike this pass's
-- kennel.lua/vehicle.lua findings -- see tests/clientkennel_spec.lua and
-- tests/clientvehicle_spec.lua for those disclosed defects), so this is
-- the one file in this batch where "genuinely inert" is provably true, not
-- just claimed.
-- ========================================================================

t.test('feature off: RequestRecall is never defined, no command registered, no thread, no onResourceStop handler', function()
    local f = newRecallFixture({ recall = false })
    t.isNil(f.env.RequestRecall)
    t.equals(#f.commands, 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.netEventCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

-- ========================================================================
-- Sanity + happy path
-- ========================================================================

t.test('feature on: registers exactly the one k9recall command, and RequestRecall is exposed', function()
    local f = newRecallFixture()
    t.isNotNil(f.env.RequestRecall)
    t.equals(#f.commands, 1)
    t.equals(f.commands[1].name, 'k9recall')
    t.equals(f.commands[1].restricted, false)
end)

t.test('RequestRecall: sends the real requestRecall event with ZERO arguments -- server/recall.lua resolves everything from `source`', function()
    local f = newRecallFixture()
    f.env.RequestRecall()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestRecall')
    t.equals(#f.lastServerEvent().args, 0, 'must send no client-claimed identifier of any kind')
end)

t.test('the k9recall command handler genuinely calls RequestRecall(), not a dead registration', function()
    local f = newRecallFixture()
    f.commands[1].handler()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestRecall')
end)

-- ========================================================================
-- TERMINATION MUST NEVER BE GATED / any ped: no access gate of any kind,
-- proven both by omission (the fixture never defines CanShowK9UI/
-- DenyK9UIAccess/IsOwnModelK9/HasK9Access at all -- see this file's header)
-- and by exercising the one real, documented "gate" this file has: none.
-- ========================================================================

t.test('RequestRecall never consults any access/model global -- works with none of CanShowK9UI/DenyK9UIAccess/IsOwnModelK9/HasK9Access even defined', function()
    local f = newRecallFixture()
    local ok, err = pcall(f.env.RequestRecall)
    t.isTrue(ok, 'RequestRecall must never reach for an access gate this file does not define: ' .. tostring(err))
    t.equals(#f.serverEvents, 1, 'a genuinely gate-free call must still reach the server')
end)

t.test('ANY PED: calling RequestRecall() a second time in a row (no debounce at the client level) sends a second, independent event -- the only throttle is server-side (Config.Recall.RequestCooldownMs), never a client-side block', function()
    local f = newRecallFixture()
    f.env.RequestRecall()
    f.env.RequestRecall()
    t.equals(#f.serverEvents, 2, 'the client must never itself withhold a repeat recall -- see this file\'s header: gating a termination path is how the unbounded trap this resource forbids gets built')
end)

-- ========================================================================
-- Double-fire / re-entrancy: firing the command handler directly, twice in
-- a row, behaves identically to calling RequestRecall() twice -- no hidden
-- per-invocation state anywhere in this file to get out of sync.
-- ========================================================================

t.test('double-fire via the command handler itself: two rapid invocations produce two independent server events, in order', function()
    local f = newRecallFixture()
    f.commands[1].handler()
    f.commands[1].handler()
    t.equals(#f.serverEvents, 2)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:requestRecall')
    t.equals(f.serverEvents[2].event, 'qbx_k9unit:server:requestRecall')
end)

-- ========================================================================
-- Lifecycle: this file has NOTHING to clean up. Proven, not assumed --
-- zero onResourceStop handlers, zero CreateThread calls, and RequestRecall
-- itself never mutates any local variable (there is none to mutate), so a
-- resource restart, a disconnect, or the K9's own death mid-flight all have
-- literally no client-side state left behind by this file, unlike every
-- other file in this batch (kennel/fetch/propattachment/vehicle all track
-- at least one netId/entity that needs an onResourceStop safety net).
-- ========================================================================

t.test('lifecycle: zero onResourceStop handlers and zero threads -- this file holds no state that could ever leak across a restart', function()
    local f = newRecallFixture()
    t.equals(f.onResourceStopHandlerCount(), 0)
    t.equals(f.threadCount(), 0)
end)

-- ========================================================================
-- ASSERTION-CAN-FAIL PROOF (per this task's own instruction): verified by
-- temporarily changing this test's own expected value (never production
-- code, which this task's brief explicitly forbids editing) -- specifically,
-- the "sends the real requestRecall event with ZERO arguments" test above
-- was run once with `t.equals(#f.lastServerEvent().args, 0, ...)` changed to
-- `t.equals(#f.lastServerEvent().args, 1, ...)`; it failed with "expected 1,
-- got 0" as expected, then was reverted to the correct `0` shown above and
-- re-run to confirm it passes again. This confirms the assertion is
-- load-bearing against the real production file's actual call shape, not a
-- tautology against a mock.
-- ========================================================================

os.exit(t.summary())
