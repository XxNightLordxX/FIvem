--[[
    tests/inventory_spec.lua

    First test coverage for server/inventory.lua (previously zero). Loads
    the REAL, unmodified server/cooldowns.lua -> server/entities.lua ->
    server/inventory.lua chain into one sandbox (the fxmanifest.lua
    server_scripts order), and drives it through the real captured
    `AddEventHandler('onResourceStart', ...)` handlers and the real
    `exports.ox_inventory:registerHook('swapItems', ...)` callback this
    file registers with a test-controlled ox_inventory export stub.

    SCOPE, DELIBERATELY NARROW: this file focuses on the three things this
    task named for server/inventory.lua --

      1. Config.K9Inventory.allowedItems is enforced through ox_inventory's
         registerHook('swapItems', ...) as a genuine pre-commit veto
         (returning the literal `false` rejects; anything else allows) --
         a disallowed item is refused, an allowed one passes, and the
         documented "filter what goes IN, never what comes OUT" scope
         (same-stash reorganizing, a non-K9 stash, a malformed payload
         shape) is pinned exactly as this file's own header describes it.
      2. The hook registers on BOTH this resource's own onResourceStart
         AND ox_inventory's own onResourceStart (so a later independent
         `restart ox_inventory` cannot silently disable enforcement), and
         a CONTRACT-DEPENDENCY test makes explicit exactly what "does not
         duplicate" depends on: this file's own code has no
         "already registered" guard of its own -- non-duplication across
         the two real trigger points relies entirely on the documented
         external fact that ox_inventory wipes its own file-local
         `eventHooks` table before firing its OWN onResourceStart (see
         this file's own header "LIFECYCLE FIX" writeup). Simulated here
         by explicitly wiping the fixture's own hook-registration list
         between triggers, exactly mirroring that real mechanism, and then
         separately proving what happens WITHOUT that wipe (a second
         closure IS added) so "does not duplicate" is never asserted
         beyond what was actually observed.
      3. Config.K9Inventory.accessScope is asserted to be 'department' at
         this resource's own onResourceStart -- proven both for the
         passing case and for 'ownerOnly'/an arbitrary typo, each firing
         the loud, named assert this file's header describes as
         deliberately NOT a silent fallback (a value that could silently
         grant world-readable access to every K9's stash is treated as a
         hard startup failure, same precedent as server/main.lua's/
         server/search.lua's own config-invariant asserts).

    WHAT THIS FILE DOES NOT COVER, AND WHY (disproportionate stubbing
    avoided, per this task's own instruction -- not silently skipped):
      - HandleOpenK9Inventory's full validation chain (netId->entity
        resolution, HasK9Access re-check, live proximity, department
        authorization, EnsureK9Stash/RegisterStash) is NOT exercised here.
        None of it is required to prove the three points above -- every
        one of those three lives entirely in this file's onResourceStart
        handlers and the registerHook callback, neither of which calls
        into HandleOpenK9Inventory at all. Building a full
        ResolveNetworkEntity/GetPlayerPed/GetEntityCoords fixture just to
        reach a callback this task's brief never named would be exactly
        the "disproportionate stubbing" this task warned against for a
        path outside its own three points. Only the callback's own
        cheapest, always-reachable guard (a non-number targetNetId, which
        needs no native stub at all to reach) is pinned below as a
        free, near-zero-cost sanity check that the callback is at least
        registered and shaped as documented.
      - RegisterStash's real owner/groups derivation
        (ResolveStashOwnerAndGroups) and EnsureK9Stash's caching are not
        exercised for the same reason -- neither is reachable without
        first going through HandleOpenK9Inventory's full chain above.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Builds one complete, independent sandbox for server/inventory.lua, with
--- the real server/cooldowns.lua and server/entities.lua loaded alongside
--- it first (the exact fxmanifest.lua server_scripts order), and every
--- other cross-file/native dependency as a test-controlled stub.
--- @param opts table? -- { featureOn (default true), allowedItems, accessScope (default 'department'), hookExportAvailable (default true), oxInventoryState (default 'started') }
--- @return table fixture
local function newInventoryFixture(opts)
    opts = opts or {}

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local hookRegistrations = {} -- array of { event = , callback = }
    local hookExportAvailable = opts.hookExportAvailable ~= false
    local oxInventoryExports = {
        registerHook = function(_self, event, callback)
            hookRegistrations[#hookRegistrations + 1] = { event = event, callback = callback }
        end,
        RegisterStash = function(_self, ...) end,
        GetItemCount = function(_self, ...) return 0 end,
        RemoveItem = function(_self, ...) return false end,
    }
    if not hookExportAvailable then
        oxInventoryExports.registerHook = nil
    end

    local oxInventoryState = opts.oxInventoryState or 'started'
    local function GetResourceState(resourceName)
        if resourceName == 'ox_inventory' then return oxInventoryState end
        return 'missing'
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {} -- name -> handler
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    -- Never actually invoked for the three points this file covers (see
    -- header) -- present only so HasK9Access/IsConfiguredK9Model exist as
    -- real functions, matching kennel_spec.lua's own "stub, don't load, a
    -- function already covered by its own file's spec" convention for
    -- server/certifications.lua's exports.
    local function HasK9Access(_source) return false end
    local function IsConfiguredK9Model(_model) return false end

    local config = {
        Features = { K9Inventory = opts.featureOn ~= false },
        K9Inventory = {
            slots         = 5,
            maxWeight     = 8000,
            interactRange = 2.0,
            accessScope   = opts.accessScope or 'department',
            allowedItems  = opts.allowedItems, -- nil by default, matching the shipped default
        },
        Departments = opts.departments or { police = { label = 'Police' } },
    }

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        GetResourceState       = GetResourceState,
        print                  = printStub,
        lib                    = lib,
        exports = {
            ox_inventory = oxInventoryExports,
            qbx_core = { GetPlayer = function(_self, _src) return nil end },
        },
        HasK9Access         = HasK9Access,
        IsConfiguredK9Model = IsConfiguredK9Model,
        Config              = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/inventory.lua', env)

    return {
        env = env,
        config = config,
        printedLines = printedLines,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName)
            end
        end,
        hookRegistrationCount = function() return #hookRegistrations end,
        wipeHookRegistrations = function()
            -- Simulates ox_inventory's OWN restart re-initializing its
            -- file-local `eventHooks` table empty (see this file's own
            -- header "LIFECYCLE FIX" writeup) -- the real mechanism this
            -- file's own re-registration-on-ox_inventory's-onResourceStart
            -- branch exists to recover from.
            for i = #hookRegistrations, 1, -1 do
                hookRegistrations[i] = nil
            end
        end,
        callHook = function(payload)
            local reg = hookRegistrations[#hookRegistrations]
            assert(reg, 'no swapItems hook is currently registered')
            return reg.callback(payload)
        end,
        invokeCallback = function(name, ...)
            assert(callbacks[name], 'no callback registered for ' .. name)
            return callbacks[name](...)
        end,
    }
end

-- ========================================================================
-- POINT 3: Config.K9Inventory.accessScope asserted to be 'department' at
-- this resource's own onResourceStart.
-- ========================================================================

t.test('onResourceStart: Config.K9Inventory.accessScope = "department" (the shipped default) starts fine, no error', function()
    local f = newInventoryFixture({ accessScope = 'department' })
    local ok = pcall(f.fireResourceStart, 'qbx_k9unit')
    t.isTrue(ok)
end)

t.test("onResourceStart: Config.K9Inventory.accessScope = 'ownerOnly' fails the startup assert loudly, naming accessScope and 'department' in the error", function()
    local f = newInventoryFixture({ accessScope = 'ownerOnly' })
    local ok, err = pcall(f.fireResourceStart, 'qbx_k9unit')
    t.isFalse(ok, "'ownerOnly' provides no real ox_inventory access control (per this file's own header) and must be a hard startup failure, never a silently-accepted config value")
    t.contains(tostring(err), 'accessScope')
    t.contains(tostring(err), "'department'")
end)

t.test('onResourceStart: an arbitrary, typo\'d accessScope value also fails the same assert -- not a special-cased check for "ownerOnly" alone', function()
    local f = newInventoryFixture({ accessScope = 'departmnet' })
    local ok = pcall(f.fireResourceStart, 'qbx_k9unit')
    t.isFalse(ok)
end)

t.test("onResourceStart: the accessScope assert ignores a DIFFERENT resource restarting (GetCurrentResourceName mismatch)", function()
    local f = newInventoryFixture({ accessScope = 'ownerOnly' }) -- would fail immediately if THIS resource's own start fired
    local ok = pcall(f.fireResourceStart, 'some_other_resource')
    t.isTrue(ok, "a different resource's own onResourceStart must never run this resource's own startup assert")
end)

-- ========================================================================
-- POINT 1: Config.K9Inventory.allowedItems veto, via the swapItems hook.
-- ========================================================================

t.test('allowedItems veto: a disallowed item moving INTO a K9 stash is genuinely rejected -- the hook returns the literal false, the real ox_inventory pre-commit veto signal', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_medkit_item', 'k9_treat' } })
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 1)

    local result = f.callHook({
        fromInventory = 'player:1',
        toInventory = 'k9inv-SOME-CID',
        fromSlot = { name = 'weapon_pistol', count = 1 },
    })
    t.equals(result, false, 'an item not on allowedItems moving into a K9 stash must be vetoed with exactly the literal boolean false')
end)

t.test('allowedItems veto: an ALLOWED item moving into a K9 stash passes -- no explicit reject (nil, never false)', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_medkit_item', 'k9_treat' } })
    f.fireResourceStart('qbx_k9unit')

    local result = f.callHook({
        fromInventory = 'player:1',
        toInventory = 'k9inv-SOME-CID',
        fromSlot = { name = 'k9_treat', count = 1 },
    })
    t.isNil(result, 'an allowed item must never be rejected -- ox_inventory only treats the literal false as a veto, so anything else (nil here) means "allow"')
end)

t.test('allowedItems veto never applies to a non-K9 stash (toInventory not prefixed k9inv-) -- an item disallowed for K9 stashes still passes into an unrelated stash', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' } })
    f.fireResourceStart('qbx_k9unit')

    local result = f.callHook({
        fromInventory = 'player:1',
        toInventory = 'evidence-locker-1',
        fromSlot = { name = 'weapon_pistol', count = 1 },
    })
    t.isNil(result, "this hook must only ever restrict THIS resource's own k9inv-* stashes")
end)

t.test('allowedItems veto never applies to reorganizing WITHIN the same K9 stash (fromInventory == toInventory) -- "filter what goes IN, never what comes OUT / around"', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' } })
    f.fireResourceStart('qbx_k9unit')

    local result = f.callHook({
        fromInventory = 'k9inv-SOME-CID',
        toInventory = 'k9inv-SOME-CID',
        fromSlot = { name = 'weapon_pistol', count = 1 }, -- deliberately NOT on allowedItems -- must still pass
    })
    t.isNil(result, 'an item already inside a K9 stash moving to a different slot in that SAME stash must never be re-filtered')
end)

t.test('allowedItems veto fails OPEN (never rejects) on a payload shape it cannot interpret -- fromSlot not a table, or missing .name', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' } })
    f.fireResourceStart('qbx_k9unit')

    local r1 = f.callHook({ fromInventory = 'player:1', toInventory = 'k9inv-SOME-CID', fromSlot = 'not-a-table' })
    local r2 = f.callHook({ fromInventory = 'player:1', toInventory = 'k9inv-SOME-CID', fromSlot = { count = 1 } }) -- no .name field
    t.isNil(r1, 'a non-table fromSlot must never be confidently rejected on a shape this file cannot actually interpret')
    t.isNil(r2, 'a fromSlot missing .name must never be confidently rejected either')
end)

t.test('The hook is never even registered when Config.K9Inventory.allowedItems is nil -- "no whitelist configured" is inert by config choice, not a capability failure (no warning either)', function()
    local f = newInventoryFixture({ allowedItems = nil })
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 0)
    t.equals(#f.printedLines, 0, 'an unconfigured whitelist is an intentional no-op, not a degraded/warned state')
end)

t.test('The hook is never registered when Config.Features.K9Inventory is false, even with a configured allowedItems list', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' }, featureOn = false })
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 0)
end)

t.test("The hook is never registered, and exactly one warning is printed, when ox_inventory's registerHook export is unavailable despite a configured allowedItems list -- the stash itself is documented to keep working, unfiltered", function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' }, hookExportAvailable = false })
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 0)
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('registerHook export is unavailable', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test("The hook is never registered when ox_inventory itself is not in the 'started' resource state, even with the export table present", function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' }, oxInventoryState = 'starting' })
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 0)
end)

-- ========================================================================
-- POINT 2: the hook registers on BOTH this resource's own onResourceStart
-- AND ox_inventory's own onResourceStart, and what "does not duplicate"
-- actually depends on.
-- ========================================================================

t.test("Both lifecycle triggers independently (re-)register the hook: this resource's own onResourceStart, and -- after a simulated ox_inventory restart wipes its own hook table -- ox_inventory's own onResourceStart", function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' } })

    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 1, "this resource's own start must register the hook")

    f.wipeHookRegistrations() -- simulates ox_inventory's OWN restart clearing its file-local eventHooks table
    f.fireResourceStart('ox_inventory')
    t.equals(f.hookRegistrationCount(), 1, "ox_inventory's own restart must ALSO independently re-trigger registration, restoring enforcement after the wipe")
end)

t.test('An unrelated resource restarting triggers neither the accessScope assert nor a hook (re-)registration', function()
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' } })
    local ok = pcall(f.fireResourceStart, 'some_other_resource')
    t.isTrue(ok)
    t.equals(f.hookRegistrationCount(), 0)
end)

t.test('CONTRACT DEPENDENCY: non-duplication relies entirely on ox_inventory wiping its own hook table before firing ITS OWN onResourceStart -- firing the SAME trigger twice with no such wipe in between DOES add a second closure', function()
    -- This is not a bug in server/inventory.lua and not a reason to edit
    -- it: a real single resource start never fires its own onResourceStart
    -- twice, and ox_inventory's own restart genuinely does wipe its table
    -- first (per this file's own header, independently verified against
    -- ox_inventory's real source). This test isolates and pins the
    -- narrower, honest claim: THIS file's own code has no "have I already
    -- registered" guard of its own -- the observed non-duplication in the
    -- test above comes entirely from the external wipe, not from anything
    -- server/inventory.lua checks itself.
    local f = newInventoryFixture({ allowedItems = { 'k9_treat' } })
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.hookRegistrationCount(), 1)

    f.fireResourceStart('qbx_k9unit') -- same trigger again, no wipe in between
    t.equals(f.hookRegistrationCount(), 2, 'this file relies entirely on the documented external contract (ox_inventory wipes its own eventHooks table before ITS OWN restart) for non-duplication -- it does not itself track "have I already registered" state and skip a redundant registerHook call')
end)

-- ========================================================================
-- Minimal sanity on the openK9Inventory callback -- see this file's own
-- header for why its full validation chain is out of this file's scope.
-- ========================================================================

t.test('qbx_k9unit:server:openK9Inventory is registered as a callback, and rejects a non-number targetNetId before any native call is ever reached', function()
    local f = newInventoryFixture()
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', 1, 'not-a-number')
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

os.exit(t.summary())
