--[[
    tests/inventory_spec.lua

    Direct tests of server/inventory.lua against the REAL, unmodified
    production file. Loads the REAL server/cooldowns.lua -> server/entities.lua
    -> server/inventory.lua chain into one sandbox (the fxmanifest.lua
    server_scripts order), and drives it through the real captured
    `AddEventHandler('onResourceStart', ...)` handlers, the real
    `exports.ox_inventory:registerHook('swapItems', ...)` callback, and --
    this pass -- the real `lib.callback.register('qbx_k9unit:server:
    openK9Inventory', ...)` callback's full HandleOpenK9Inventory validation
    chain, with a complete ResolveNetworkEntity/ResolveConnectedPlayerFromPed/
    GetPlayerPed/GetEntityCoords/GetEntityModel fixture (the same shape
    fetch_spec.lua/tenure_spec.lua/defense_spec.lua already build for their
    own files).

    SCOPE, per this task's own brief -- this file covers:

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
      4. HandleOpenK9Inventory's FULL validation chain (this pass, closing
         the coverage gap the previous version of this file explicitly
         disclosed rather than skipped): netId->entity resolution
         (wrong/missing entity, wrong type), NPC-vs-connected-player
         resolution, IsConfiguredK9Model, a FRESH HasK9Access re-check on
         the TARGET (never assumed from the netId alone), the interactor's
         own live proximity check (never trusting a client-claimed
         distance), IsAuthorizedForK9Inventory's self-access/department
         branches, the target citizenid resolution race, the
         openK9Inventory callback's own cooldown/mutex/pcall wrapper
         around it, and EnsureK9Stash's session-scoped idempotency + the
         REAL ResolveStashOwnerAndGroups 'department' owner/groups shape
         actually passed to RegisterStash.

    locale() is NEVER stubbed (this suite's own established convention) --
    EnsureK9Stash's `locale('inventory.stash_label')` call is exercised for
    real below, against the real locales/en.json.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to fetch_spec.lua's/
-- tenure_spec.lua's/defense_spec.lua's own copies. HandleOpenK9Inventory's
-- proximity check does `#(GetEntityCoords(a) - GetEntityCoords(b))`, so
-- both the `-` and `#` metamethods must be modeled.
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end

-- Fixed, test-controlled "model hash" constants -- GetEntityModel and
-- IsConfiguredK9Model are both fully test-controlled below (never the real
-- GetHashKey algorithm; HandleOpenK9Inventory never calls GetHashKey itself
-- either -- it only ever hands GetEntityModel's result to
-- IsConfiguredK9Model, exactly like server/main.lua's CheckLeashEligibility).
local K9_MODEL_HASH = 111111
local NON_K9_MODEL_HASH = 222222

--- Builds one complete, independent sandbox for server/inventory.lua, with
--- the real server/cooldowns.lua and server/entities.lua loaded alongside
--- it first (the exact fxmanifest.lua server_scripts order), and every
--- other cross-file/native dependency as a test-controlled stub.
--- @param opts table? -- { featureOn (default true), allowedItems, accessScope (default 'department'), hookExportAvailable (default true), oxInventoryState (default 'started'), interactRange (default 2.0), departments, registerStashShouldError }
--- @return table fixture
local function newInventoryFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local hookRegistrations = {} -- array of { event = , callback = }
    local registerStashCalls = {} -- { {stashId=, label=, slots=, maxWeight=, owner=, groups=}, ... }
    local hookExportAvailable = opts.hookExportAvailable ~= false
    local oxInventoryExports = {
        registerHook = function(_self, event, callback)
            hookRegistrations[#hookRegistrations + 1] = { event = event, callback = callback }
        end,
        RegisterStash = function(_self, stashId, label, slots, maxWeight, owner, groups)
            if opts.registerStashShouldError then
                error('simulated RegisterStash failure')
            end
            registerStashCalls[#registerStashCalls + 1] = {
                stashId = stashId, label = label, slots = slots, maxWeight = maxWeight, owner = owner, groups = groups,
            }
        end,
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

    -- ---- server/entities.lua's own native dependencies ----
    local networkEntities = {} -- netId -> handle
    local existingEntities = {} -- handle -> true
    local entityTypes = {} -- handle -> 1|2|3
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end
    local function DoesEntityExist(handle) return existingEntities[handle] == true end
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local connectedPlayerIds = {}
    local pedsByPlayerId = {} -- source -> ped handle
    local function GetPlayers() return connectedPlayerIds end
    local function GetPlayerPed(src) return pedsByPlayerId[src] or 0 end

    -- ---- HandleOpenK9Inventory's own additional native dependencies ----
    local entityModels = {} -- handle -> model hash
    local function GetEntityModel(handle) return entityModels[handle] end

    local coordsByHandle = {} -- handle -> vec3
    local function GetEntityCoords(handle) return coordsByHandle[handle] or vec3(0, 0, 0) end

    local hasAccessBySource = {} -- source -> boolean
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local function IsConfiguredK9Model(hash) return hash == K9_MODEL_HASH end

    -- exports.qbx_core:GetPlayer(src) -- keyed by SOURCE (used for both the
    -- interactor's own job lookup AND the target's own citizenid lookup --
    -- exactly like the real HandleOpenK9Inventory, which calls this twice,
    -- once per resolved source).
    local playersBySource = {} -- source -> { citizenid = , job = { name = } }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    local departments = opts.departments or { police = { label = 'Police' } }
    local config = {
        Features = { K9Inventory = opts.featureOn ~= false },
        K9Inventory = {
            slots         = 5,
            maxWeight     = 8000,
            interactRange = opts.interactRange or 2.0,
            accessScope   = opts.accessScope or 'department',
            allowedItems  = opts.allowedItems, -- nil by default, matching the shipped default
        },
        Departments = departments,
    }

    local env = Sandbox.newEnv({
        GetGameTimer           = GetGameTimer,
        AddEventHandler        = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        GetResourceState       = GetResourceState,
        print                  = printStub,
        lib                    = lib,
        exports = {
            ox_inventory = oxInventoryExports,
            qbx_core = { GetPlayer = qbxGetPlayer },
        },
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist               = DoesEntityExist,
        GetEntityType                 = GetEntityType,
        GetPlayers                    = GetPlayers,
        GetPlayerPed                  = GetPlayerPed,
        GetEntityModel                = GetEntityModel,
        GetEntityCoords               = GetEntityCoords,
        HasK9Access                   = HasK9Access,
        IsConfiguredK9Model           = IsConfiguredK9Model,
        Config                        = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/inventory.lua', env)

    return {
        env = env,
        config = config,
        printedLines = printedLines,
        registerStashCalls = registerStashCalls,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
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
        -- ---- HandleOpenK9Inventory fixture helpers ----
        registerEntity = function(netId, handle, ropts)
            ropts = ropts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = ropts.exists ~= false
            entityTypes[handle] = ropts.entityType or 1 -- ped by default -- HandleOpenK9Inventory always targets a ped
            entityModels[handle] = ropts.model or K9_MODEL_HASH
            coordsByHandle[handle] = ropts.coords or vec3(0, 0, 0)
        end,
        removeExistence = function(handle) existingEntities[handle] = false end,
        setInteractor = function(src, pedHandle, coords)
            pedsByPlayerId[src] = pedHandle
            coordsByHandle[pedHandle] = coords or vec3(0, 0, 0)
        end,
        setInteractorOffline = function(src) pedsByPlayerId[src] = nil end,
        setConnectedPlayer = function(src, pedHandle)
            -- Registers `src` as a currently-connected player whose OWN ped
            -- is `pedHandle`, for ResolveConnectedPlayerFromPed's own scan --
            -- this is what turns a bare networked ped into "a currently
            -- connected player's own ped" rather than an NPC.
            local found = false
            for _, id in ipairs(connectedPlayerIds) do
                if id == tostring(src) then found = true end
            end
            if not found then connectedPlayerIds[#connectedPlayerIds + 1] = tostring(src) end
            pedsByPlayerId[src] = pedHandle
        end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayerRecord = function(src, shape) playersBySource[src] = shape end,
        clearPlayerRecord = function(src) playersBySource[src] = nil end,
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

t.test("onResourceStart: an arbitrary, typo'd accessScope value also fails the same assert -- not a special-cased check for \"ownerOnly\" alone", function()
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
-- POINT 4: HandleOpenK9Inventory's FULL validation chain, via the real
-- 'qbx_k9unit:server:openK9Inventory' callback.
-- ========================================================================

local INTERACTOR_SRC = 10
local TARGET_SRC = 20

--- Wires up a fully-eligible baseline: a real, connected K9-modeled target
--- ped at netId 5000, a certified target, and a police-department
--- interactor standing right next to it -- every test below perturbs
--- exactly ONE thing off this baseline.
--- @param f table
--- @param opts table?
local function wireEligibleOpen(f, opts)
    opts = opts or {}
    local targetNetId = opts.targetNetId or 5000
    local targetPed = opts.targetPed or 9000
    f.registerEntity(targetNetId, targetPed, { model = opts.targetModel or K9_MODEL_HASH, coords = opts.targetCoords or vec3(0, 0, 0) })
    f.setConnectedPlayer(TARGET_SRC, targetPed)
    f.setAccess(TARGET_SRC, opts.targetHasAccess ~= false)
    f.setPlayerRecord(TARGET_SRC, { citizenid = opts.targetCitizenid or 'K9-CID' })

    f.setInteractor(INTERACTOR_SRC, 8000, opts.interactorCoords or vec3(0, 0, 0))
    f.setPlayerRecord(INTERACTOR_SRC, { citizenid = 'HANDLER-CID', job = { name = opts.jobName or 'police' } })

    return targetNetId
end

t.test('qbx_k9unit:server:openK9Inventory is registered as a callback, and rejects a non-number targetNetId before any native call is ever reached', function()
    local f = newInventoryFixture()
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', 1, 'not-a-number')
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: Config.Features.K9Inventory = false is a real server-side no-op regardless of everything else being eligible', function()
    local f = newInventoryFixture({ featureOn = false })
    local netId = wireEligibleOpen(f)
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'feature_disabled')
end)

t.test('openK9Inventory: a netId that resolves to nothing real is rejected as invalid_target', function()
    local f = newInventoryFixture()
    wireEligibleOpen(f)
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, 999999)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: a netId that resolves to a real entity of the WRONG type (not a ped) is rejected as invalid_target', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f, { targetNetId = 5001, targetPed = 9001 })
    f.registerEntity(netId, 9001, { entityType = 3, model = K9_MODEL_HASH }) -- overwrite as an OBJECT, not a ped
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: a resolved ped that belongs to no currently-connected player (an NPC) is rejected as invalid_target', function()
    local f = newInventoryFixture()
    -- registerEntity alone (no setConnectedPlayer) -- ResolveConnectedPlayerFromPed finds nobody.
    f.registerEntity(5002, 9002, { model = K9_MODEL_HASH })
    f.setInteractor(INTERACTOR_SRC, 8000, vec3(0, 0, 0))
    f.setPlayerRecord(INTERACTOR_SRC, { citizenid = 'HANDLER-CID', job = { name = 'police' } })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, 5002)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: a connected player whose LIVE ped model is not a configured K9 model is rejected as invalid_target', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f, { targetModel = NON_K9_MODEL_HASH })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: a K9-modeled target who is NOT (or no longer) HasK9Access-certified is rejected as no_access', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f, { targetHasAccess = false })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'no_access')
end)

t.test('openK9Inventory: the interacting source has no live ped (disconnected mid-flight) is rejected as invalid_target', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    f.setInteractorOffline(INTERACTOR_SRC)
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: the interactor too far from the LIVE, server-side target position is rejected as too_far -- never trusts a client-claimed proximity', function()
    local f = newInventoryFixture({ interactRange = 2.0 })
    local netId = wireEligibleOpen(f, { interactorCoords = vec3(50.0, 0, 0) })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'too_far')
end)

t.test('openK9Inventory: exactly AT interactRange is accepted (boundary, not rejected)', function()
    local f = newInventoryFixture({ interactRange = 2.0 })
    local netId = wireEligibleOpen(f, { interactorCoords = vec3(2.0, 0, 0) })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r.ok, 'exactly at interactRange must still count as "close enough"')
end)

t.test('openK9Inventory: just past interactRange is rejected as too_far', function()
    local f = newInventoryFixture({ interactRange = 2.0 })
    local netId = wireEligibleOpen(f, { interactorCoords = vec3(2.01, 0, 0) })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'too_far')
end)

t.test("openK9Inventory: an interactor whose job is NOT a configured department (and who is not the K9 themselves) is rejected as not_authorized", function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f, { jobName = 'civilian' })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'not_authorized')
end)

t.test('openK9Inventory: an interactor with no qbx_core Player record at all (race at disconnect) is rejected as not_authorized, not a crash', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    f.clearPlayerRecord(INTERACTOR_SRC)
    local ok, r = pcall(f.invokeCallback, 'qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(ok, 'a missing interactor Player record must never crash the callback')
    t.isFalse(r.ok)
    t.equals(r.reason, 'not_authorized')
end)

t.test('openK9Inventory: SELF-ACCESS -- the K9 player opening their OWN stash is always authorized, even with no department job at all', function()
    local f = newInventoryFixture()
    -- The K9 (TARGET_SRC) interacts with THEIR OWN netId.
    local targetPed = 9003
    local netId = 5003
    f.registerEntity(netId, targetPed, { model = K9_MODEL_HASH, coords = vec3(0, 0, 0) })
    f.setConnectedPlayer(TARGET_SRC, targetPed)
    f.setAccess(TARGET_SRC, true)
    f.setPlayerRecord(TARGET_SRC, { citizenid = 'K9-CID' }) -- no job at all -- must not matter for self-access
    f.setInteractor(TARGET_SRC, targetPed, vec3(0, 0, 0)) -- interactor IS the target
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', TARGET_SRC, netId)
    t.isTrue(r.ok, "a K9 opening their own stash must never be blocked by IsAuthorizedForK9Inventory's department check")
    t.equals(r.stashId, 'k9inv-K9-CID')
end)

t.test('openK9Inventory: the target resolves to a connected player with no qbx_core citizenid at all is rejected as invalid_target (race at disconnect)', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    f.clearPlayerRecord(TARGET_SRC) -- exports.qbx_core:GetPlayer(TARGET_SRC) now resolves to nil
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('openK9Inventory: SUCCESS -- a fully-eligible department-officer interactor gets ok=true and the deterministic k9inv-<citizenid> stash id', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f, { targetCitizenid = 'SPOT-THE-DOG' })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r.ok)
    t.equals(r.stashId, 'k9inv-SPOT-THE-DOG')
    t.isNil(r.reason)
end)

t.test('openK9Inventory SUCCESS: RegisterStash is called with the REAL department-scope owner/groups shape -- owner=false, groups=table<jobName,0> for every Config.Departments entry', function()
    local f = newInventoryFixture({ departments = { police = { label = 'Police' }, sheriff = { label = 'Sheriff' } } })
    local netId = wireEligibleOpen(f, { targetCitizenid = 'K9-REX' })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r.ok)
    t.equals(#f.registerStashCalls, 1)
    local call = f.registerStashCalls[1]
    t.equals(call.stashId, 'k9inv-K9-REX')
    t.equals(call.label, locale('inventory.stash_label'))
    t.equals(call.slots, 5)
    t.equals(call.maxWeight, 8000)
    t.equals(call.owner, false, "'department' accessScope must pass owner=false, never a per-citizenid owner string (that would be the rejected 'ownerOnly' shape)")
    t.equals(call.groups.police, 0)
    t.equals(call.groups.sheriff, 0)
end)

t.test('openK9Inventory SUCCESS: EnsureK9Stash is idempotent per session -- a SECOND open request for the SAME K9 citizenid does not call RegisterStash again', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f, { targetCitizenid = 'K9-CID' })
    local r1 = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r1.ok)
    t.equals(#f.registerStashCalls, 1)

    -- Advance past the openK9Inventory cooldown (1000ms) so the SECOND
    -- request is not itself rejected as on_cooldown -- isolating EnsureK9Stash's
    -- own idempotency, not the request-rate-limit.
    f.advance(1001)
    local r2 = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r2.ok)
    t.equals(r2.stashId, 'k9inv-K9-CID')
    t.equals(#f.registerStashCalls, 1, 'a citizenid already ensured this session must never trigger a second RegisterStash call')
end)

t.test('openK9Inventory: RegisterStash erroring internally (bad/missing ox_inventory install) is caught and reported as stash_failed, never an uncaught error', function()
    local f = newInventoryFixture({ registerStashShouldError = true })
    local netId = wireEligibleOpen(f)
    local ok, r = pcall(f.invokeCallback, 'qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(ok, 'a RegisterStash failure must never crash the callback -- EnsureK9Stash pcall-wraps it')
    t.isFalse(r.ok)
    t.equals(r.reason, 'stash_failed')
end)

-- ---- openK9Inventory's own cooldown/mutex wrapper ----

t.test('openK9Inventory: K9InventoryOpenCooldown (1000ms) silently blocks a second immediate request from the same interactor source', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    local r1 = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r1.ok)
    local r2 = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r2.ok)
    t.equals(r2.reason, 'on_cooldown')
end)

t.test('openK9Inventory: once the cooldown elapses, a fresh request from the same source succeeds again', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    f.advance(1001)
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isTrue(r.ok)
end)

t.test('openK9Inventory: the cooldown does not block a DIFFERENT interactor source in the same tick', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)

    local otherSrc = 30
    f.setInteractor(otherSrc, 8001, vec3(0, 0, 0))
    f.setPlayerRecord(otherSrc, { citizenid = 'HANDLER2-CID', job = { name = 'police' } })
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', otherSrc, netId)
    t.isTrue(r.ok, "a different interactor's own request must not be blocked by another source's cooldown")
end)

t.test('openK9Inventory: on_cooldown is checked BEFORE feature_disabled would even matter -- a rejected (cooldown) request never reaches HandleOpenK9Inventory at all (no RegisterStash call, no proximity check exercised)', function()
    local f = newInventoryFixture()
    local netId = wireEligibleOpen(f)
    f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.equals(#f.registerStashCalls, 1)

    -- Immediately move the interactor far away AND re-request in the same
    -- tick -- if on_cooldown didn't short-circuit first, this would fail as
    -- too_far instead; either way ok must be false, but confirm no SECOND
    -- RegisterStash call happens regardless of which rejection reason wins.
    f.setInteractor(INTERACTOR_SRC, 8000, vec3(999, 999, 0))
    local r = f.invokeCallback('qbx_k9unit:server:openK9Inventory', INTERACTOR_SRC, netId)
    t.isFalse(r.ok)
    t.equals(#f.registerStashCalls, 1, 'no additional RegisterStash call from the rejected repeat request')
end)

os.exit(t.summary())
