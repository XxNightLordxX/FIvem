--[[
    tests/compattarget_spec.lua

    Direct tests of shared/compat/target.lua against the REAL, unmodified
    production file -- every adapter factory it registers, driven through a
    fake `K9Compat.RegisterAdapter` capture (the same "stub the one thing
    under test doesn't own" convention every other spec in this folder
    uses) plus a per-resource `exports` stub.

    SCOPE, matching what makes this file "THE HARD PART" per the task this
    was written under -- ox_target and qb-target have genuinely different
    option shapes, and this suite exists to PROVE the translation, not just
    that a call happened:

      1. Every factory's realm/capability gating: `nil` when the backing
         resource isn't started, `nil` when ANY required export is missing
         (never a partial table that would silently no-op later), `{}` for
         `target.server` (no required methods for that realm), and a full
         6-method table for `target.client` when everything is present.
      2. ox_target (the reference adapter): pure pass-through of
         AddGlobalPlayer/AddGlobalVehicle/AddGlobalObject/AddModel/
         AddSphereZone to the matching real export, and Remove() correctly
         dispatching to the right typed remove* export by handle kind.
      3. qb-target's THREE real divergences, each proven independently:
         `canInteract` is re-signatured from qb-target's own
         `(entity, distance, optionTable)` call convention back to the
         `(entity, distance, coords, name)` shape this resource's own
         predicates are written against (coords re-derived via
         GetEntityCoords, name from the option); `onSelect`/`action` is
         bridged so the ORIGINAL onSelect still receives a `{ entity = }`
         table exactly like it would under real ox_target; `.groups` is
         renamed to `.job` with its shape untouched.
      4. qb-target's/qtarget's sphere-zone translation (AddCircleZone),
         including that an option missing its own `.distance` falls back
         to the zone's radius rather than silently losing range.
      5. qtarget's simpler translation (`.onSelect`->`.action` bare rename,
         `.groups`->`.job` rename, no canInteract re-signaturing).
      6. sleepless_interact's near-total pass-through, and its one real
         gap: AddSphereZone -> addCoords, where an option's own `.distance`
         is preserved and a missing one is backfilled from the zone radius.
      7. `interact`'s factory is UNCONFIRMED and always returns `nil` for
         both realms, never a guessed table.
      8. The K9Compat-not-yet-loaded guard: loading this file with no
         `K9Compat` global present never throws, and registers nothing.

    Per this suite's own convention (DEVELOPER_REFERENCE.md), production code is
    never re-implemented here -- every assertion drives the real
    shared/compat/target.lua through the real per-adapter factory function
    it registers.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fake K9Compat -- captures every K9Compat.RegisterAdapter(...) call the
-- real target.lua makes at load time, keyed the same way core.lua's own
-- RegisteredFactories table is (see shared/compat/core.lua), so a test can
-- fetch and directly call `registered.target['qb-target']('client')`.
-- ----------------------------------------------------------------------
--- @param registered table -- [system][resourceName] = factory, filled in by this stub
--- @return table fakeK9Compat
local function newFakeK9Compat(registered)
    return {
        RegisterAdapter = function(system, resourceName, factory)
            registered[system] = registered[system] or {}
            registered[system][resourceName] = factory
        end,
    }
end

--- Loads the REAL shared/compat/target.lua into a fresh sandbox.
--- @param opts table? -- { exportsStub table?, resourceStates table<string,string>? }
--- @return table registered -- [system][resourceName] = factory
--- @return table env
local function loadTargetCompat(opts)
    opts = opts or {}
    local registered = {}
    local resourceStates = opts.resourceStates or {}

    local function GetResourceState(resourceName)
        return resourceStates[resourceName] or 'missing'
    end

    local exportsStub = opts.exportsStub or {}

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- NOT `opts.omitK9Compat and nil or newFakeK9Compat(registered)` -- that
    -- classic Lua ternary idiom breaks the instant the "true" branch value
    -- is itself nil/false (`x and nil or y` always evaluates to `y`,
    -- regardless of `x`, since `nil or y` never short-circuits on `nil`).
    local fakeK9Compat = nil
    if not opts.omitK9Compat then
        fakeK9Compat = newFakeK9Compat(registered)
    end

    local env = Sandbox.newEnv({
        K9Compat = fakeK9Compat,
        GetResourceState = GetResourceState,
        exports = exportsStub,
        GetEntityCoords = opts.GetEntityCoords or function(entity) return { entity = entity, x = 1.0, y = 2.0, z = 3.0 } end,
        print = printStub,
    })

    Sandbox.loadInto('../shared/compat/target.lua', env)
    env.__printedLines = printedLines
    return registered, env
end

--- Builds a plain per-resource export table where every method just
--- records its call and returns `results[methodName]` (or true if unset).
--- @param methodNames string[]
--- @param results table<string, any>?
--- @return table exportsTable, table calls -- calls[methodName] = { args..., ... } (last call only, per method)
local function fakeResourceExports(methodNames, results)
    results = results or {}
    local calls = {}
    local exportsTable = {}
    for _, name in ipairs(methodNames) do
        exportsTable[name] = function(_self, ...)
            calls[name] = { ... }
            if results[name] ~= nil then return results[name] end
            return true
        end
    end
    return exportsTable, calls
end

local OX_TARGET_METHODS = {
    'addGlobalPlayer', 'addGlobalVehicle', 'addGlobalObject', 'addModel', 'addSphereZone',
    'removeGlobalPlayer', 'removeGlobalVehicle', 'removeGlobalObject', 'removeModel', 'removeZone',
}
local QB_TARGET_METHODS = {
    'AddGlobalPlayer', 'AddGlobalVehicle', 'AddGlobalObject', 'AddTargetModel', 'AddCircleZone',
    'RemoveGlobalPlayer', 'RemoveGlobalVehicle', 'RemoveGlobalObject', 'RemoveTargetModel', 'RemoveZone',
}
local QTARGET_METHODS = {
    'Player', 'Vehicle', 'Object', 'AddTargetModel', 'AddCircleZone',
    'RemovePlayer', 'RemoveVehicle', 'RemoveObject', 'RemoveTargetModel', 'RemoveZone',
}
local SLEEPLESS_METHODS = {
    'addGlobalPlayer', 'addGlobalVehicle', 'addGlobalObject', 'addModel', 'addCoords',
    'removeGlobalPlayer', 'removeGlobalVehicle', 'removeGlobalObject', 'removeModel', 'removeCoords',
}

-- ========================================================================
-- Gating: not started / missing export / server realm / full client table
-- ========================================================================

t.test('ox_target factory returns nil when the resource is not started', function()
    local registered = loadTargetCompat({ resourceStates = {} })
    local factory = registered.target.ox_target
    t.isNotNil(factory)
    t.isNil(factory('client'))
    t.isNil(factory('server'))
end)

t.test('ox_target factory returns {} for the server realm when started', function()
    local exportsTable = fakeResourceExports(OX_TARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { ox_target = 'started' },
        exportsStub = { ox_target = exportsTable },
    })
    local adapter = registered.target.ox_target('server')
    t.isNotNil(adapter)
    t.equals(next(adapter), nil, 'target.server has no required methods, so {} is a valid adapter table')
end)

t.test('ox_target factory returns nil on the client realm when a required export is missing', function()
    local partial = {}
    for _, name in ipairs(OX_TARGET_METHODS) do
        if name ~= 'addSphereZone' then
            partial[name] = function() return true end
        end
    end
    local registered = loadTargetCompat({
        resourceStates = { ox_target = 'started' },
        exportsStub = { ox_target = partial },
    })
    t.isNil(registered.target.ox_target('client'))
end)

t.test('ox_target factory returns a full 6-method client adapter when every export is present', function()
    local exportsTable = fakeResourceExports(OX_TARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { ox_target = 'started' },
        exportsStub = { ox_target = exportsTable },
    })
    local adapter = registered.target.ox_target('client')
    for _, methodName in ipairs({ 'AddGlobalPlayer', 'AddGlobalVehicle', 'AddGlobalObject', 'AddModel', 'AddSphereZone', 'Remove' }) do
        t.equals(type(adapter[methodName]), 'function', methodName .. ' must be a function')
    end
end)

t.test('interact factory always returns nil -- UNCONFIRMED, never a guessed table', function()
    -- Even claiming the resource is started must not change the outcome:
    -- this factory is unconditional per shared/compat/target.lua's own
    -- header ("returns nil unconditionally").
    local registered = loadTargetCompat({ resourceStates = { interact = 'started' } })
    local factory = registered.target.interact
    t.isNotNil(factory)
    t.isNil(factory('client'))
    t.isNil(factory('server'))
end)

t.test('loading target.lua with no K9Compat global present never throws and registers nothing', function()
    local ok, registeredOrErr = pcall(function()
        return loadTargetCompat({ omitK9Compat = true })
    end)
    t.isTrue(ok, 'must not throw merely because K9Compat is not yet loaded')
    t.equals(next(registeredOrErr), nil, 'nothing should have been registered anywhere')
end)

-- ========================================================================
-- ox_target: faithful pass-through + Remove() dispatch
-- ========================================================================

t.test('ox_target AddGlobalPlayer forwards options unchanged and Remove dispatches to removeGlobalPlayer', function()
    local exportsTable, calls = fakeResourceExports(OX_TARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { ox_target = 'started' },
        exportsStub = { ox_target = exportsTable },
    })
    local adapter = registered.target.ox_target('client')

    local options = { { name = 'qbx_k9unit:test', label = 'Test', distance = 2.5 } }
    local handle = adapter.AddGlobalPlayer(options)
    t.equals(calls.addGlobalPlayer[1], options, 'the exact same options table must reach ox_target, untranslated')

    adapter.Remove(handle)
    t.isNotNil(calls.removeGlobalPlayer, 'Remove() must call removeGlobalPlayer for a player handle')
    t.equals(calls.removeGlobalPlayer[1][1], 'qbx_k9unit:test')
end)

t.test('ox_target AddSphereZone returns a zone handle and Remove dispatches to removeZone', function()
    local exportsTable, calls = fakeResourceExports(OX_TARGET_METHODS, { addSphereZone = 42 })
    local registered = loadTargetCompat({
        resourceStates = { ox_target = 'started' },
        exportsStub = { ox_target = exportsTable },
    })
    local adapter = registered.target.ox_target('client')

    local data = { coords = { x = 1, y = 2, z = 3 }, radius = 1.5, options = {} }
    local handle = adapter.AddSphereZone(data)
    t.equals(calls.addSphereZone[1], data)
    t.equals(handle.id, 42)

    adapter.Remove(handle)
    t.equals(calls.removeZone[1], 42)
    t.isTrue(calls.removeZone[2], 'suppressWarning must be true so a routine cleanup never logs a warning')
end)

t.test('ox_target AddModel/Remove round-trips the model list', function()
    local exportsTable, calls = fakeResourceExports(OX_TARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { ox_target = 'started' },
        exportsStub = { ox_target = exportsTable },
    })
    local adapter = registered.target.ox_target('client')

    local models = { 'a_c_shepherd' }
    local options = { { name = 'qbx_k9unit:model', label = 'Model option' } }
    local handle = adapter.AddModel(models, options)
    t.equals(calls.addModel[1], models)
    t.equals(calls.addModel[2], options)

    adapter.Remove(handle)
    t.equals(calls.removeModel[1], models)
    t.equals(calls.removeModel[2][1], 'qbx_k9unit:model')
end)

-- ========================================================================
-- qb-target: the hard part -- canInteract re-signaturing, onSelect/action
-- bridging, .groups -> .job, and zone translation.
-- ========================================================================

--- @return table adapter, table calls
local function newQbTargetAdapter()
    local exportsTable, calls = fakeResourceExports(QB_TARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { ['qb-target'] = 'started' },
        exportsStub = { ['qb-target'] = exportsTable },
    })
    return registered.target['qb-target']('client'), calls
end

t.test('qb-target canInteract is re-signatured back to (entity, distance, coords, name)', function()
    local adapter, calls = newQbTargetAdapter()

    local seenArgs
    local options = {
        {
            name = 'qbx_k9unit:attachLeash',
            label = 'Attach Leash',
            distance = 4.0,
            canInteract = function(entity, distance, coords, name)
                seenArgs = { entity = entity, distance = distance, coords = coords, name = name }
                return true
            end,
        },
    }
    adapter.AddGlobalPlayer(options)

    local sentOptions = calls.AddGlobalPlayer[1].options
    t.equals(#sentOptions, 1)

    -- Simulate qb-target's OWN call convention (client.lua's CheckOptions):
    -- three arguments, the third being the qb-target OPTION TABLE, not a
    -- coords vector.
    local result = sentOptions[1].canInteract(999, 4.0, sentOptions[1])
    t.isTrue(result)
    t.equals(seenArgs.entity, 999, 'the original predicate must still see the real entity')
    t.equals(seenArgs.distance, 4.0)
    t.isNotNil(seenArgs.coords, 'coords must be re-derived via GetEntityCoords, never left nil')
    t.equals(seenArgs.name, 'qbx_k9unit:attachLeash', 'name must fall back to the option name, matching ox_target/sleepless_interact')
end)

t.test('qb-target canInteract failing safely returns false rather than throwing on a bad predicate', function()
    local adapter, calls = newQbTargetAdapter()
    local options = {
        {
            name = 'qbx_k9unit:broken',
            label = 'Broken',
            canInteract = function() error('boom') end,
        },
    }
    adapter.AddGlobalPlayer(options)
    local sentOptions = calls.AddGlobalPlayer[1].options
    local ok, result = pcall(sentOptions[1].canInteract, 1, 1, sentOptions[1])
    t.isTrue(ok, 'the translated canInteract itself must never throw even if the original predicate does')
    t.isFalse(result)
end)

t.test('qb-target onSelect/action bridging rebuilds a { entity = } table for the original onSelect', function()
    local adapter, calls = newQbTargetAdapter()

    local received
    local options = {
        {
            name = 'qbx_k9unit:certifyHandler',
            label = 'Certify',
            onSelect = function(data) received = data end,
        },
    }
    adapter.AddGlobalPlayer(options)
    local sentOptions = calls.AddGlobalPlayer[1].options
    t.isNil(sentOptions[1].onSelect, 'onSelect must be removed from the translated option -- qb-target only reads .action')
    t.equals(type(sentOptions[1].action), 'function')

    -- Simulate qb-target's OWN call convention (client.lua's selectTarget
    -- NUI callback): `data.action(data.entity)` -- entity ALONE.
    sentOptions[1].action(777)
    t.isNotNil(received)
    t.equals(received.entity, 777, 'the original onSelect must see the exact data.entity shape this resource already reads everywhere')
end)

t.test('qb-target renames .groups to .job with the same {jobName -> minGrade} shape untouched', function()
    local adapter, calls = newQbTargetAdapter()
    local groups = { police = 0, sheriff = 2 }
    adapter.AddGlobalObject({ { name = 'qbx_k9unit:shop', label = 'K9 Shop', groups = groups } })
    local sentOptions = calls.AddGlobalObject[1].options
    t.isNil(sentOptions[1].groups, '.groups must not survive translation -- qb-target does not read that field')
    t.equals(sentOptions[1].job, groups, '.job must be the exact same table, not a reshaped copy')
end)

t.test('qb-target keys options by label, defaulting to name only when label is absent', function()
    local adapter, calls = newQbTargetAdapter()
    adapter.AddGlobalPlayer({ { name = 'qbx_k9unit:x', label = 'Visible Label' } })
    t.equals(calls.AddGlobalPlayer[1].options[1].label, 'Visible Label')

    adapter.AddGlobalPlayer({ { name = 'qbx_k9unit:onlyname' } })
    t.equals(calls.AddGlobalPlayer[1].options[1].label, 'qbx_k9unit:onlyname', 'label must fall back to name when the option never set one')
end)

t.test('qb-target AddGlobalPlayer computes the outer distance as the MAX of the per-option distances', function()
    local adapter, calls = newQbTargetAdapter()
    adapter.AddGlobalPlayer({
        { name = 'a', label = 'A', distance = 2.0 },
        { name = 'b', label = 'B', distance = 5.0 },
        { name = 'c', label = 'C', distance = 3.0 },
    })
    t.equals(calls.AddGlobalPlayer[1].distance, 5.0, 'the outer wrapper distance must never clamp a larger per-option distance down')
end)

t.test('qb-target AddSphereZone translates to AddCircleZone, backfilling missing per-option distance from the zone radius', function()
    local adapter, calls = newQbTargetAdapter()
    local coords = { x = 100.0, y = 200.0, z = 30.0 }
    local handle = adapter.AddSphereZone({
        coords = coords,
        radius = 1.5,
        debug = false,
        options = { { label = 'K9 Shop', icon = 'fas fa-shopping-basket' } },
    })

    local args = calls.AddCircleZone
    t.isNotNil(args, 'AddCircleZone must have been called')
    t.equals(args[2], coords, 'center must be forwarded unchanged')
    t.equals(args[3], 1.5, 'radius must be forwarded unchanged')
    local targetOptions = args[5]
    t.equals(targetOptions.distance, 1.5, 'with no per-option distance at all, the outer distance must fall back to the zone radius')
    t.equals(targetOptions.options[1].label, 'K9 Shop')

    t.isTrue(handle.kind == 'zone')
    adapter.Remove(handle)
    t.equals(calls.RemoveZone[1], handle.id)
end)

-- ========================================================================
-- qtarget: simpler translation -- bare renames, no signature bridging
-- ========================================================================

t.test('qtarget renames onSelect to action (bare rename, no wrapper) and .groups to .job', function()
    local exportsTable, calls = fakeResourceExports(QTARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { qtarget = 'started' },
        exportsStub = { qtarget = exportsTable },
    })
    local adapter = registered.target.qtarget('client')

    local onSelectFn = function() end
    local groups = { police = 0 }
    adapter.AddGlobalVehicle({ { name = 'qbx_k9unit:v', label = 'V', onSelect = onSelectFn, groups = groups } })

    local sentOptions = calls.Vehicle[1].options
    t.isNil(sentOptions[1].onSelect)
    t.equals(sentOptions[1].action, onSelectFn, 'qtarget action must be the SAME function reference, not a wrapper, per the confirmed bare-rename shim behavior')
    t.isNil(sentOptions[1].groups)
    t.equals(sentOptions[1].job, groups)
end)

t.test('qtarget Remove dispatches by handle kind to the matching typed remove export', function()
    local exportsTable, calls = fakeResourceExports(QTARGET_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { qtarget = 'started' },
        exportsStub = { qtarget = exportsTable },
    })
    local adapter = registered.target.qtarget('client')

    local handle = adapter.AddGlobalObject({ { name = 'qbx_k9unit:o', label = 'O' } })
    adapter.Remove(handle)
    t.equals(calls.RemoveObject[1][1], 'qbx_k9unit:o')
end)

-- ========================================================================
-- sleepless_interact: near-total pass-through + addCoords zone bridging
-- ========================================================================

t.test('sleepless_interact AddGlobalPlayer/AddModel forward options completely unchanged', function()
    local exportsTable, calls = fakeResourceExports(SLEEPLESS_METHODS)
    local registered = loadTargetCompat({
        resourceStates = { sleepless_interact = 'started' },
        exportsStub = { sleepless_interact = exportsTable },
    })
    local adapter = registered.target.sleepless_interact('client')

    local options = { { name = 'qbx_k9unit:x', label = 'X', canInteract = function() return true end } }
    adapter.AddGlobalPlayer(options)
    t.equals(calls.addGlobalPlayer[1], options, 'sleepless_interact needs zero field translation for this method')

    local models = { 'a_c_shepherd' }
    adapter.AddModel(models, options)
    t.equals(calls.addModel[1], models)
    t.equals(calls.addModel[2], options)
end)

t.test('sleepless_interact AddSphereZone translates to addCoords, injecting the zone radius as each option\'s own distance when unset', function()
    local exportsTable, calls = fakeResourceExports(SLEEPLESS_METHODS, { addCoords = 'coordid-1' })
    local registered = loadTargetCompat({
        resourceStates = { sleepless_interact = 'started' },
        exportsStub = { sleepless_interact = exportsTable },
    })
    local adapter = registered.target.sleepless_interact('client')

    local coords = { x = 1, y = 2, z = 3 }
    local handle = adapter.AddSphereZone({
        coords = coords,
        radius = 1.5,
        options = {
            { label = 'No distance set' },
            { label = 'Has its own', distance = 6.0 },
        },
    })

    t.equals(calls.addCoords[1], coords)
    local translated = calls.addCoords[2]
    t.equals(translated[1].distance, 1.5, 'a per-option distance missing entirely must fall back to the zone radius, never sleepless_interact\'s own 2m default')
    t.equals(translated[2].distance, 6.0, 'an option that already set its own distance must keep it, not be overridden by the zone radius')
    t.equals(handle.id, 'coordid-1')

    adapter.Remove(handle)
    t.equals(calls.removeCoords[1], 'coordid-1')
end)

t.test('sleepless_interact factory returns nil when addCoords is missing (no sphere-zone equivalent available)', function()
    local partial = {}
    for _, name in ipairs(SLEEPLESS_METHODS) do
        if name ~= 'addCoords' then
            partial[name] = function() return true end
        end
    end
    local registered = loadTargetCompat({
        resourceStates = { sleepless_interact = 'started' },
        exportsStub = { sleepless_interact = partial },
    })
    t.isNil(registered.target.sleepless_interact('client'))
end)

os.exit(t.summary())
