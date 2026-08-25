--[[
    tests/compatdispatch_spec.lua

    Tests for shared/compat/dispatch.lua AND shared/compat/ambulance.lua,
    both loaded here despite the "one spec file per production file"
    convention every other spec in this folder follows (see tests/README.md
    "Adding a new spec") -- deliberate, not an oversight: the task this pair
    of production files was built under grants exactly one new spec
    filename (`tests/compatdispatch_spec.lua`) alongside the two production
    files, as part of a strict per-agent file-ownership pass with sixteen
    agents editing this repo concurrently. Splitting ambulance coverage into
    a second, unauthorized spec file was not an option; leaving
    shared/compat/ambulance.lua completely untested to keep a clean 1:1
    filename mapping would have been a worse trade. Both production files
    are exercised through their REAL, unmodified source, loaded via
    fixtures/sandbox.lua exactly like every other spec here -- this file
    just contains two clearly-separated sections instead of one.

    NEITHER shared/compat/core.lua's OWN detection engine (custom/override/
    candidates resolution order, the no-op stub, BuildSafeAdapter's pcall
    wrapping, /k9compat) NOR anything about resource-start ordering is
    tested here -- that is core.lua's own file and, per this same
    ownership split, someone else's spec to write. What IS tested here is
    the actual CONTRACT core.lua depends on: that each `K9Compat.
    RegisterAdapter(system, resourceName, factory)` call in these two files
    registers a `factory(realm) -> table | nil` that behaves exactly as
    documented -- `nil` for the client realm (neither dispatch nor
    ambulance requires anything client-side), a real table exposing the
    required method for the server realm on every CONFIRMED adapter, `nil`
    unconditionally on every UNCONFIRMED adapter (see each production
    file's own header for the CONFIRMED/UNCONFIRMED verdicts and the
    primary sources behind them) -- and that each CONFIRMED adapter's
    method actually does what its own header claims: translates this
    file's normalised payload into the real, cited third-party shape,
    never leaks that third-party shape back to a caller, fails closed
    (never throws) on a missing export/resource/throwing call, and -- for
    `IsDowned` specifically -- preserves the three-valued true/false/nil
    contract (nil is checked here as a DISTINCT case from false throughout,
    never conflated).

    Rather than loading the real shared/compat/core.lua (which would pull
    in Config.Compat/Config.Features resolution, resource-start event
    wiring, and the /k9compat command -- none of which either production
    file under test here depends on), each section below builds a MINIMAL
    stand-in `K9Compat` exposing only `RegisterAdapter`, capturing every
    registered factory into a plain table this file inspects directly.
    This is the same "stub, don't load, a function already covered by its
    own file's spec" convention tests/integrations_spec.lua's own header
    already establishes for HasK9Access/IsConfiguredK9Model (covered by
    certifications_spec.lua) -- core.lua's own detection engine is that
    file's own spec's job, not this one's.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Shared stub-building helpers
-- ----------------------------------------------------------------------

--- A minimal stand-in for the real K9Compat.RegisterAdapter -- captures
--- every (system, resourceName, factory) triple exactly as core.lua's own
--- RegisterFactories table would, with none of core.lua's own detection
--- logic. See this file's header for why the real core.lua is not loaded.
--- @return table k9CompatStub, table registered -- registered[system][resourceName] = factory
local function newK9CompatStub()
    local registered = {}
    local stub = {
        RegisterAdapter = function(system, resourceName, factory)
            registered[system] = registered[system] or {}
            registered[system][resourceName] = factory
            return true
        end,
    }
    return stub, registered
end

--- A minimal `exports` stand-in. `resources` is a plain table:
--- `{ ['some-resource'] = { MethodName = function(self, ...) ... end } }`.
--- Mirrors real FiveM export-proxy semantics closely enough for this
--- file's purposes: `exports['x'].Method` (dot access) returns the
--- function for an existence check without calling it, and
--- `exports['x']:Method(...)` (colon call) invokes it with the resource's
--- own method table as the implicit first argument -- exactly the two-step
--- access-then-call shape both production files under test use.
--- A resource name with no entry in `resources` returns an empty table
--- (so a `type(x) == 'function'` existence check on any of its methods
--- correctly fails), never nil and never throws on plain indexing --
--- matching how a real started-but-export-missing resource behaves (a
--- resource that is NOT started at all is instead modelled via
--- `resourceStates` below, checked BEFORE `exports` is ever touched,
--- exactly like the real production code).
--- @param resources table
--- @return table exportsStub
local function newExportsStub(resources)
    return setmetatable({}, {
        __index = function(_, resourceName)
            return resources[resourceName] or {}
        end,
    })
end

-- ======================================================================
-- SECTION 1: shared/compat/dispatch.lua
-- ======================================================================

--- @param opts table? -- { resourceStates: table?, exportsResources: table?, triggerEventImpl: function? }
--- @return table registered, table calls, table env
local function newDispatchFixture(opts)
    opts = opts or {}

    local resourceStates = opts.resourceStates or {}
    local function GetResourceState(name)
        return resourceStates[name] or 'missing'
    end

    local triggerEventCalls = {}
    local function TriggerEvent(eventName, ...)
        triggerEventCalls[#triggerEventCalls + 1] = { name = eventName, args = { ... } }
        if opts.triggerEventImpl then
            return opts.triggerEventImpl(eventName, ...)
        end
    end

    local k9CompatStub, registered = newK9CompatStub()

    local env = Sandbox.newEnv({
        K9Compat = k9CompatStub,
        GetResourceState = GetResourceState,
        exports = newExportsStub(opts.exportsResources or {}),
        TriggerEvent = TriggerEvent,
    })
    Sandbox.loadInto('../shared/compat/dispatch.lua', env)

    return registered, { triggerEvent = triggerEventCalls }, env
end

local DISPATCH_CANDIDATES = { 'ps-dispatch', 'cd_dispatch', 'qs-dispatch', 'rcore_dispatch', 'core_dispatch', 'linden_outlawalert' }
local DISPATCH_CONFIRMED = { ['ps-dispatch'] = true, ['linden_outlawalert'] = true }

t.test('dispatch.lua registers every Config.Compat candidate exactly once, in the "dispatch" system', function()
    local registered = newDispatchFixture()
    t.isNotNil(registered.dispatch, 'expected K9Compat.RegisterAdapter to have been called for system "dispatch"')
    for _, name in ipairs(DISPATCH_CANDIDATES) do
        t.equals(type(registered.dispatch[name]), 'function', ('expected a registered factory for %s'):format(name))
    end
end)

t.test('dispatch.lua: every candidate factory returns nil for the client realm (dispatch.client requires nothing)', function()
    local registered = newDispatchFixture()
    for _, name in ipairs(DISPATCH_CANDIDATES) do
        t.isNil(registered.dispatch[name]('client'), ('expected %s factory("client") to be nil'):format(name))
    end
end)

t.test('dispatch.lua: every UNCONFIRMED candidate factory returns nil for the server realm too (never a guessed signature)', function()
    local registered = newDispatchFixture()
    for _, name in ipairs(DISPATCH_CANDIDATES) do
        if not DISPATCH_CONFIRMED[name] then
            t.isNil(registered.dispatch[name]('server'), ('expected UNCONFIRMED %s factory("server") to be nil'):format(name))
        end
    end
end)

t.test('dispatch.lua: every CONFIRMED candidate factory returns a table exposing a callable Alert for the server realm', function()
    local registered = newDispatchFixture()
    for name in pairs(DISPATCH_CONFIRMED) do
        local adapter = registered.dispatch[name]('server')
        t.equals(type(adapter), 'table', ('expected %s factory("server") to return a table'):format(name))
        t.equals(type(adapter.Alert), 'function', ('expected %s adapter.Alert to be callable'):format(name))
    end
end)

-- ---- ps-dispatch ------------------------------------------------------

t.test('ps-dispatch Alert: rejects a payload with no usable coords, never touches exports', function()
    local exportCalled = false
    local registered = newDispatchFixture({
        resourceStates = { ['ps-dispatch'] = 'started' },
        exportsResources = {
            ['ps-dispatch'] = { CustomAlert = function(_self, _payload) exportCalled = true end },
        },
    })
    local adapter = registered.dispatch['ps-dispatch']('server')
    local sent = adapter.Alert({ code = 'k9_down', title = 't', message = 'm', jobs = { 'police' }, priority = 0 })
    t.isFalse(sent)
    t.isFalse(exportCalled, 'Alert must not call the export at all for an invalid payload')
end)

t.test('ps-dispatch Alert: returns false and does not throw when ps-dispatch is not started', function()
    local registered = newDispatchFixture({
        resourceStates = {}, -- ps-dispatch not started
        exportsResources = {
            ['ps-dispatch'] = { CustomAlert = function(_self, _payload) error('should never be called') end },
        },
    })
    local adapter = registered.dispatch['ps-dispatch']('server')
    local ok, sent = pcall(adapter.Alert, { title = 't', message = 'm', coords = vector3(1, 2, 3), jobs = { 'police' } })
    t.isTrue(ok, 'Alert itself must never throw')
    t.isFalse(sent)
end)

t.test('ps-dispatch Alert: translates the normalised payload into CustomAlert\'s real documented field names', function()
    local captured
    local registered = newDispatchFixture({
        resourceStates = { ['ps-dispatch'] = 'started' },
        exportsResources = {
            ['ps-dispatch'] = { CustomAlert = function(_self, payload) captured = payload end },
        },
    })
    local adapter = registered.dispatch['ps-dispatch']('server')
    local sent = adapter.Alert({
        code = 'k9_down', code10 = '10-99', title = 'K9 Officer Down',
        message = 'Immediate assistance required.', coords = vector3(100, 200, 30),
        jobs = { 'police', 'sheriff' }, priority = 0,
    })
    t.isTrue(sent)
    t.isNotNil(captured, 'expected CustomAlert to have been called')
    t.equals(captured.message, 'K9 Officer Down', 'message must carry the headline (title)')
    t.equals(captured.information, 'Immediate assistance required.', 'information must carry the free-text detail (message)')
    t.equals(captured.codeName, 'k9_down')
    t.equals(captured.code, '10-99')
    t.equals(captured.priority, 0, 'priority 0 must pass through unchanged (identical scale)')
    t.equals(captured.coords.x, 100)
    t.equals(#captured.jobs, 2)
    t.equals(captured.jobs[1], 'police')
end)

t.test('ps-dispatch Alert: priority is clamped/defaulted (NaN/out-of-range/missing), never passed through raw', function()
    local captured
    local registered = newDispatchFixture({
        resourceStates = { ['ps-dispatch'] = 'started' },
        exportsResources = {
            ['ps-dispatch'] = { CustomAlert = function(_self, payload) captured = payload end },
        },
    })
    local adapter = registered.dispatch['ps-dispatch']('server')

    adapter.Alert({ title = 't', coords = vector3(0, 0, 0), priority = -5 })
    t.equals(captured.priority, 0, 'below range clamps to 0')

    adapter.Alert({ title = 't', coords = vector3(0, 0, 0), priority = 99 })
    t.equals(captured.priority, 3, 'above range clamps to 3')

    adapter.Alert({ title = 't', coords = vector3(0, 0, 0) })
    t.equals(captured.priority, 2, 'missing priority defaults to 2 (routine)')

    adapter.Alert({ title = 't', coords = vector3(0, 0, 0), priority = 'urgent' })
    t.equals(captured.priority, 2, 'a non-number priority defaults to 2 (routine), never errors')
end)

t.test('ps-dispatch Alert: returns false, never throws, when CustomAlert export is missing', function()
    local registered = newDispatchFixture({
        resourceStates = { ['ps-dispatch'] = 'started' },
        exportsResources = { ['ps-dispatch'] = {} }, -- no CustomAlert at all
    })
    local adapter = registered.dispatch['ps-dispatch']('server')
    local ok, sent = pcall(adapter.Alert, { title = 't', coords = vector3(1, 1, 1) })
    t.isTrue(ok)
    t.isFalse(sent)
end)

t.test('ps-dispatch Alert: a throwing CustomAlert export is caught -- Alert returns false, never propagates the error', function()
    local registered = newDispatchFixture({
        resourceStates = { ['ps-dispatch'] = 'started' },
        exportsResources = {
            ['ps-dispatch'] = { CustomAlert = function(_self, _payload) error('simulated third-party crash') end },
        },
    })
    local adapter = registered.dispatch['ps-dispatch']('server')
    local ok, sent = pcall(adapter.Alert, { title = 't', coords = vector3(1, 1, 1) })
    t.isTrue(ok, 'a throwing export must never propagate out of Alert')
    t.isFalse(sent)
end)

-- ---- linden_outlawalert ------------------------------------------------

t.test('linden_outlawalert Alert: fires the REAL confirmed event name (wf-alerts:svNotify), not a guessed linden_outlawalert:* name', function()
    local registered, calls = newDispatchFixture({
        resourceStates = { ['linden_outlawalert'] = 'started' },
    })
    local adapter = registered.dispatch['linden_outlawalert']('server')
    local sent = adapter.Alert({ title = 'K9 Officer Down', message = 'Assist now.', coords = vector3(1, 2, 3), jobs = { 'police' }, priority = 0 })
    t.isTrue(sent)
    t.equals(#calls.triggerEvent, 1)
    t.equals(calls.triggerEvent[1].name, 'wf-alerts:svNotify')
end)

t.test('linden_outlawalert Alert: exact payload shape and isImportant priority mapping', function()
    local registered, calls = newDispatchFixture({
        resourceStates = { ['linden_outlawalert'] = 'started' },
    })
    local adapter = registered.dispatch['linden_outlawalert']('server')

    adapter.Alert({ code = 'k9_down', code10 = '10-99', title = 'K9 Officer Down', message = 'Assist now.', coords = vector3(5, 6, 7), jobs = { 'police', 'ambulance' }, priority = 0 })
    t.equals(#calls.triggerEvent, 1)
    local firstCall = calls.triggerEvent[1]
    t.equals(firstCall.name, 'wf-alerts:svNotify')
    local sentPayload = firstCall.args[1]
    t.equals(sentPayload.dispatchData.displayCode, '10-99')
    t.equals(sentPayload.dispatchData.description, 'K9 Officer Down')
    t.equals(sentPayload.dispatchData.info, 'Assist now.')
    t.equals(sentPayload.dispatchData.isImportant, 1, 'priority 0 (critical) must map to isImportant = 1')
    t.equals(#sentPayload.dispatchData.recipientList, 2)
    t.equals(sentPayload.coords.x, 5)
    t.isNotNil(sentPayload.caller)

    adapter.Alert({ title = 'Routine', coords = vector3(0, 0, 0), priority = 3 })
    local secondCall = calls.triggerEvent[2]
    t.equals(secondCall.args[1].dispatchData.isImportant, 0, 'priority 3 (low) must map to isImportant = 0')
end)

t.test('linden_outlawalert Alert: rejects a payload with no usable coords', function()
    local registered, calls = newDispatchFixture({
        resourceStates = { ['linden_outlawalert'] = 'started' },
    })
    local adapter = registered.dispatch['linden_outlawalert']('server')
    local sent = adapter.Alert({ title = 't', message = 'm' })
    t.isFalse(sent)
    t.equals(#calls.triggerEvent, 0, 'must never fire the event for an invalid payload')
end)

t.test('linden_outlawalert Alert: returns false and does not throw when the resource is not started', function()
    local registered, calls = newDispatchFixture({ resourceStates = {} })
    local adapter = registered.dispatch['linden_outlawalert']('server')
    local ok, sent = pcall(adapter.Alert, { title = 't', coords = vector3(1, 1, 1) })
    t.isTrue(ok)
    t.isFalse(sent)
    t.equals(#calls.triggerEvent, 0)
end)

t.test('linden_outlawalert Alert: a throwing downstream handler is caught -- Alert returns false, never propagates', function()
    local registered = newDispatchFixture({
        resourceStates = { ['linden_outlawalert'] = 'started' },
        triggerEventImpl = function(_eventName, _payload) error('simulated handler crash in another resource') end,
    })
    local adapter = registered.dispatch['linden_outlawalert']('server')
    local ok, sent = pcall(adapter.Alert, { title = 't', coords = vector3(1, 1, 1) })
    t.isTrue(ok, 'a throwing downstream handler must never propagate out of Alert')
    t.isFalse(sent)
end)

-- ======================================================================
-- SECTION 2: shared/compat/ambulance.lua
-- ======================================================================

--- @param opts table? -- { resourceStates: table?, players: table? } -- players[src] = playerTable|nil|'throw'
--- @return table registered, table env
local function newAmbulanceFixture(opts)
    opts = opts or {}

    local resourceStates = opts.resourceStates or {}
    local function GetResourceState(name)
        return resourceStates[name] or 'missing'
    end

    local players = opts.players or {}
    local qbxCoreMethods = {
        GetPlayer = function(_self, src)
            local entry = players[src]
            if entry == 'throw' then
                error('simulated qbx_core crash resolving player ' .. tostring(src))
            end
            return entry
        end,
    }

    local k9CompatStub, registered = newK9CompatStub()

    local env = Sandbox.newEnv({
        K9Compat = k9CompatStub,
        GetResourceState = GetResourceState,
        exports = newExportsStub({ ['qbx_core'] = qbxCoreMethods }),
    })
    Sandbox.loadInto('../shared/compat/ambulance.lua', env)

    return registered, env
end

local AMBULANCE_CANDIDATES = { 'qbx_medical', 'qb-ambulancejob', 'ps-ambulancejob', 'wasabi_ambulance', 'esx_ambulancejob' }
local AMBULANCE_CONFIRMED = { ['qbx_medical'] = true, ['qb-ambulancejob'] = true }

t.test('ambulance.lua registers every Config.Compat candidate exactly once, in the "ambulance" system', function()
    local registered = newAmbulanceFixture()
    t.isNotNil(registered.ambulance, 'expected K9Compat.RegisterAdapter to have been called for system "ambulance"')
    for _, name in ipairs(AMBULANCE_CANDIDATES) do
        t.equals(type(registered.ambulance[name]), 'function', ('expected a registered factory for %s'):format(name))
    end
end)

t.test('ambulance.lua: every candidate factory returns nil for the client realm (ambulance.client requires nothing)', function()
    local registered = newAmbulanceFixture()
    for _, name in ipairs(AMBULANCE_CANDIDATES) do
        t.isNil(registered.ambulance[name]('client'), ('expected %s factory("client") to be nil'):format(name))
    end
end)

t.test('ambulance.lua: every UNCONFIRMED candidate factory returns nil for the server realm too (never a guessed signature)', function()
    local registered = newAmbulanceFixture()
    for _, name in ipairs(AMBULANCE_CANDIDATES) do
        if not AMBULANCE_CONFIRMED[name] then
            t.isNil(registered.ambulance[name]('server'), ('expected UNCONFIRMED %s factory("server") to be nil'):format(name))
        end
    end
end)

t.test('ambulance.lua: every CONFIRMED candidate factory returns a table exposing a callable IsDowned for the server realm', function()
    local registered = newAmbulanceFixture()
    for name in pairs(AMBULANCE_CONFIRMED) do
        local adapter = registered.ambulance[name]('server')
        t.equals(type(adapter), 'table', ('expected %s factory("server") to return a table'):format(name))
        t.equals(type(adapter.IsDowned), 'function', ('expected %s adapter.IsDowned to be callable'):format(name))
    end
end)

for _, resourceName in ipairs({ 'qbx_medical', 'qb-ambulancejob' }) do
    t.test(('%s IsDowned: returns nil (UNKNOWN) when the resource is not started'):format(resourceName), function()
        local registered = newAmbulanceFixture({ resourceStates = {} })
        local adapter = registered.ambulance[resourceName]('server')
        local ok, result = pcall(adapter.IsDowned, 1)
        t.isTrue(ok)
        t.isNil(result)
    end)

    t.test(('%s IsDowned: returns nil (UNKNOWN), not false, when qbx_core cannot resolve the player'):format(resourceName), function()
        local registered = newAmbulanceFixture({
            resourceStates = { [resourceName] = 'started' },
            players = { [1] = nil },
        })
        local adapter = registered.ambulance[resourceName]('server')
        t.isNil(adapter.IsDowned(1))
    end)

    t.test(('%s IsDowned: returns nil (UNKNOWN), never throws, when qbx_core:GetPlayer itself throws'):format(resourceName), function()
        local registered = newAmbulanceFixture({
            resourceStates = { [resourceName] = 'started' },
            players = { [1] = 'throw' },
        })
        local adapter = registered.ambulance[resourceName]('server')
        local ok, result = pcall(adapter.IsDowned, 1)
        t.isTrue(ok, 'IsDowned itself must never throw')
        t.isNil(result)
    end)

    t.test(('%s IsDowned: returns nil (UNKNOWN) when metadata has neither isdead nor inlaststand set yet'):format(resourceName), function()
        local registered = newAmbulanceFixture({
            resourceStates = { [resourceName] = 'started' },
            players = { [1] = { PlayerData = { metadata = {} } } },
        })
        local adapter = registered.ambulance[resourceName]('server')
        t.isNil(adapter.IsDowned(1), 'an unset field must read as UNKNOWN, never as "confirmed up"')
    end)

    t.test(('%s IsDowned: returns true when metadata.isdead is true'):format(resourceName), function()
        local registered = newAmbulanceFixture({
            resourceStates = { [resourceName] = 'started' },
            players = { [1] = { PlayerData = { metadata = { isdead = true } } } },
        })
        local adapter = registered.ambulance[resourceName]('server')
        t.isTrue(adapter.IsDowned(1))
    end)

    t.test(('%s IsDowned: returns true when metadata.inlaststand is true (even if isdead is not true)'):format(resourceName), function()
        local registered = newAmbulanceFixture({
            resourceStates = { [resourceName] = 'started' },
            players = { [1] = { PlayerData = { metadata = { isdead = false, inlaststand = true } } } },
        })
        local adapter = registered.ambulance[resourceName]('server')
        t.isTrue(adapter.IsDowned(1))
    end)

    t.test(('%s IsDowned: returns false (confirmed up), distinct from nil, when metadata.isdead is explicitly false'):format(resourceName), function()
        local registered = newAmbulanceFixture({
            resourceStates = { [resourceName] = 'started' },
            players = { [1] = { PlayerData = { metadata = { isdead = false } } } },
        })
        local adapter = registered.ambulance[resourceName]('server')
        local result = adapter.IsDowned(1)
        t.isFalse(result)
        t.isTrue(result ~= nil, 'false must be a distinct value from nil, not merely falsy')
    end)
end

os.exit(t.summary())
