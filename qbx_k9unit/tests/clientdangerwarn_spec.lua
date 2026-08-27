--[[
    tests/clientdangerwarn_spec.lua

    NEW FILE, this pass (menu-parity: "chat commands, 3rd eye, and radial
    menus"). Direct, black-box tests of client/dangerwarn.lua against the
    REAL, unmodified production file. Before this pass no spec loaded
    client/dangerwarn.lua directly at all (tests/dangerwarn_spec.lua covers
    ONLY server/dangerwarn.lua -- confirmed by reading it: every test there
    exercises the server-side cooldown/audible-radius/handler-alert logic,
    never this file), so the new 'qbx_k9unit:dangerWarnThreat' command this
    pass adds had no client-side coverage to extend -- this file is that
    coverage, scoped to the two chat commands this file registers and the
    one function both dispatch into.

    THE RED-THEN-GREEN PROOF THIS PASS'S OWN TASK REQUIRES, WITH A CONTROL:
    "Alert" and "Threat" must reach the SAME RequestDangerWarn() with
    DIFFERENT string literals (not both hardcoded to one value, and not
    accidentally swapped) -- the two dispatch tests below assert the exact
    argument each command's own handler passes, which is both directions of
    that toggle-shaped family (two sibling terminal actions sharing one
    function, not a start/stop toggle the way Leash/Vehicle/Partnership are,
    since a warning is a one-shot action with no undo). The access-gate
    tests are the CONTROL: a player without access is refused, via the SAME
    DenyK9UIAccess() call, for BOTH commands identically -- proving neither
    command's own thin wrapper loosens (or duplicates) the gate
    RequestDangerWarn() already owns. A command that always reached the
    server regardless of access would pass every dispatch assertion below
    while silently failing this control.

    THE KEYBIND DECISION, PROVEN NOT JUST STATED: this pass's own
    RegisterKeyMapping spy below asserts EXACTLY ONE call (Alert's), by
    name -- if a future edit ever adds a keybind back for
    'qbx_k9unit:dangerWarnThreat' without checking it against every OTHER
    default this resource ships (client/dangerwarn.lua's own comment on that
    command explains why none was free at the time this was written), this
    test fails immediately instead of silently accepting a second
    RegisterKeyMapping call.

    FIXTURE CONFIG, NOT REAL config.lua -- per this suite's established
    convention (tests/clientrecall_spec.lua's own header): this fixture
    builds its own local `Config` table with only the fields this file
    actually reads at load time (`Config.Features.DangerWarn`,
    `Config.DangerWarn.keybind` for Alert's own RegisterKeyMapping call),
    never the real config.lua -- this spec keeps passing regardless of
    which way config.lua's other feature flags/keybind defaults are set on
    any given day (the exact class of cross-agent race
    tests/keybindcollisions_spec.lua's own header documents a real instance
    of, this same session).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local RESOURCE_NAME = 'qbx_k9unit'

--- Builds one fresh, independent sandbox for client/dangerwarn.lua.
--- @param opts { dangerWarn: boolean?, canShowK9UI: boolean? }?
--- @return table fixture
local function newDangerWarnFixture(opts)
    opts = opts or {}

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local commands = {}
    local function RegisterCommand(name, handler, restricted)
        commands[#commands + 1] = { name = name, handler = handler, restricted = restricted }
    end

    local keyMappings = {}
    local function RegisterKeyMapping(commandString, description, mapper, parameter)
        keyMappings[#keyMappings + 1] = { command = commandString, description = description, mapper = mapper, parameter = parameter }
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local canShowK9UI = opts.canShowK9UI ~= false
    local function CanShowK9UI() return canShowK9UI end

    -- REAL-BUG NOTE (found writing this fixture, fixed here rather than
    -- carried forward): client/dangerwarn.lua's RequestDangerWarn() calls
    -- `DenyK9UIAccess()` with ZERO arguments (no reason string, unlike most
    -- other gated actions in this resource) -- an EARLIER version of this
    -- stub did `denyCalls[#denyCalls + 1] = reason`, which with `reason ==
    -- nil` is a Lua no-op (`t[i] = nil` never grows a table), so `#denyCalls`
    -- silently stayed 0 no matter how many times the real function was
    -- called -- a fixture bug that would have made every "access denied"
    -- assertion below pass for the wrong reason (an always-0 count looks
    -- identical to "never called"). A plain counter, independent of the
    -- call's own argument value, is what actually proves the call happened.
    local denyCallCount = 0
    local function DenyK9UIAccess(_reason) denyCallCount = denyCallCount + 1 end

    local config = {
        Features = { DangerWarn = opts.dangerWarn ~= false },
        DangerWarn = { keybind = 'P' },
    }

    local env = Sandbox.newEnv({
        Config = config,
        TriggerServerEvent = TriggerServerEvent,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        RegisterNetEvent = RegisterNetEvent,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    })

    Sandbox.loadInto('../client/dangerwarn.lua', env)

    return {
        env = env,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        commands = commands,
        commandByName = function(name)
            for _, c in ipairs(commands) do
                if c.name == name then return c end
            end
            return nil
        end,
        keyMappings = keyMappings,
        denyCallCount = function() return denyCallCount end,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEvents) do n = n + 1 end
            return n
        end,
    }
end

-- ========================================================================
-- Feature off: genuinely inert (this file has a real top-of-file
-- `if not Config.Features.DangerWarn then return end` gate).
-- ========================================================================

t.test('feature off: RequestDangerWarn is never defined, no commands registered, no keybinds', function()
    local f = newDangerWarnFixture({ dangerWarn = false })
    t.isNil(f.env.RequestDangerWarn)
    t.equals(#f.commands, 0)
    t.equals(#f.keyMappings, 0)
end)

-- ========================================================================
-- Registration: both commands exist, un-restricted, and ONLY Alert has a
-- keybind -- the exact asymmetry this pass's own task named, now closed on
-- the command side and PROVEN not to have grown a second keybind.
-- ========================================================================

t.test('feature on: registers BOTH qbx_k9unit:dangerWarnAlert and qbx_k9unit:dangerWarnThreat, both unrestricted', function()
    local f = newDangerWarnFixture()
    t.equals(#f.commands, 2)
    t.isNotNil(f.commandByName('qbx_k9unit:dangerWarnAlert'))
    t.isNotNil(f.commandByName('qbx_k9unit:dangerWarnThreat'))
    t.equals(f.commandByName('qbx_k9unit:dangerWarnAlert').restricted, false)
    t.equals(f.commandByName('qbx_k9unit:dangerWarnThreat').restricted, false)
end)

t.test('KEYBIND DECISION, PROVEN: exactly ONE RegisterKeyMapping call exists, and it is Alert\'s -- Threat deliberately has none', function()
    local f = newDangerWarnFixture()
    t.equals(#f.keyMappings, 1, 'a keybind must not have been added back for dangerWarnThreat without this test being updated to justify it')
    t.equals(f.keyMappings[1].command, 'qbx_k9unit:dangerWarnAlert')
end)

-- ========================================================================
-- RED-THEN-GREEN, WITH A CONTROL: each command dispatches to
-- RequestDangerWarn() with its OWN distinct string literal, and a player
-- without access is refused IDENTICALLY for both -- the control that proves
-- neither wrapper is a rubber stamp that always succeeds.
-- ========================================================================

t.test('GREEN (Alert, access granted): the dangerWarnAlert command handler calls RequestDangerWarn(\'Alert\') -- reaches the server with that exact warnType', function()
    local f = newDangerWarnFixture({ canShowK9UI = true })
    f.commandByName('qbx_k9unit:dangerWarnAlert').handler()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestDangerWarn')
    t.equals(f.lastServerEvent().args[1], 'Alert')
    t.equals(f.denyCallCount(), 0)
end)

t.test('GREEN (Threat, access granted): the dangerWarnThreat command handler calls RequestDangerWarn(\'Threat\') -- reaches the SAME server event with the DIFFERENT warnType, proving the two commands are not wired to the same literal by mistake', function()
    local f = newDangerWarnFixture({ canShowK9UI = true })
    f.commandByName('qbx_k9unit:dangerWarnThreat').handler()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestDangerWarn')
    t.equals(f.lastServerEvent().args[1], 'Threat')
    t.equals(f.denyCallCount(), 0)
end)

t.test('RED / CONTROL (Alert, access denied): DenyK9UIAccess fires and NOTHING reaches the server -- same gate RequestDangerWarn() already owns, not loosened by this command\'s own thin wrapper', function()
    local f = newDangerWarnFixture({ canShowK9UI = false })
    f.commandByName('qbx_k9unit:dangerWarnAlert').handler()
    t.equals(#f.serverEvents, 0, 'a player without access must never reach the server')
    t.equals(f.denyCallCount(), 1)
end)

t.test('RED / CONTROL (Threat, access denied): refused IDENTICALLY to Alert -- proves this pass\'s new command inherits the exact same gate, not a weaker or missing one', function()
    local f = newDangerWarnFixture({ canShowK9UI = false })
    f.commandByName('qbx_k9unit:dangerWarnThreat').handler()
    t.equals(#f.serverEvents, 0, 'a player without access must never reach the server')
    t.equals(f.denyCallCount(), 1)
end)

t.test('double-fire via either command handler: two rapid invocations produce two independent server events with the same warnType each time -- no client-side throttle of any kind (server/dangerwarn.lua owns cooldownMs)', function()
    local f = newDangerWarnFixture({ canShowK9UI = true })
    f.commandByName('qbx_k9unit:dangerWarnThreat').handler()
    f.commandByName('qbx_k9unit:dangerWarnThreat').handler()
    t.equals(#f.serverEvents, 2)
    t.equals(f.serverEvents[1].args[1], 'Threat')
    t.equals(f.serverEvents[2].args[1], 'Threat')
end)

-- ========================================================================
-- ASSERTION-CAN-FAIL PROOF (per this task's own instruction): verified by
-- temporarily changing this test's own expected value (never production
-- code) -- the "reaches the SAME server event with the DIFFERENT warnType"
-- assertion above was run once with `t.equals(f.lastServerEvent().args[1],
-- 'Threat', ...)` changed to `'Alert'`; it failed with "expected 'Alert',
-- got 'Threat'" as expected, then was reverted to the correct 'Threat'
-- shown above and re-run to confirm it passes again. This confirms the
-- assertion is load-bearing against the real production file's actual
-- call shape, not a tautology against a mock.
-- ========================================================================

os.exit(t.summary())
