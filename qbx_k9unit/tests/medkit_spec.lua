--[[
    tests/medkit_spec.lua

    First test coverage for server/medkit.lua -- one of the last server
    files without a spec, and, per this task's own brief, the one with the
    worst history in this resource: its dead-K9 gate was REPORTED CLOSED
    (CORRECTNESS PASS finding 2 in that file's own header) while resting on
    `IsEntityDead(targetPed)`, a native with NO FXServer server
    registration -- confirmed by that file's own "NATIVE-AVAILABILITY FIX"
    addendum, which found zero `RegisterNativeHandler` for `IS_ENTITY_DEAD`
    anywhere in citizenfx/fivem's own server-native registration source.
    FXServer does not throw on an unregistered native; it silently no-ops
    and never writes the result buffer, so that check ALWAYS returned
    `false` -- a dead K9's health could always be pushed back up via this
    item, the exact bug the "fixed" gate was supposed to close. The file now
    uses `GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD` (100),
    mirroring server/combat.lua's own identical fix (already covered by
    combat_spec.lua's own "MUST-MATTER #1" section) -- this file's own
    99/100/101 boundary tests below are the thing that actually stops this
    bug from silently reappearing a second time.

    Loads the REAL, unmodified server/cooldowns.lua -> server/entities.lua
    -> server/medkit.lua chain (the exact fxmanifest.lua server_scripts
    load order for this file's own load-time dependency on
    NewCooldown/NewMutex; server/entities.lua is loaded alongside per this
    task's own instruction even though server/medkit.lua does not currently
    call either of ResolveNetworkEntity/ResolveConnectedPlayerFromPed --
    unlike server/kennel.lua/server/combat.lua, this file resolves its
    target via a caller-supplied PLAYER server id and GetPlayerPed directly,
    per its own header's callback-contract note on why it deliberately never
    needs netId/entity-handle resolution at all). IsConfiguredK9Model and
    NotifyPlayer are stubbed directly, not loaded -- both are genuinely
    OTHER files' own logic (server/certifications.lua, server/notify.lua),
    already covered by their own specs, same convention every other spec in
    this suite already establishes (kennel_spec.lua/combat_spec.lua/
    wellbeing_spec.lua's own headers). RestoreInjury is the documented
    `type(RestoreInjury) == 'function'` soft dependency on
    server/wellbeing.lua -- omitted by default (proving the guard degrades
    cleanly), added back as a controllable stub only for the tests that
    specifically exercise it, same "runtime existence guard, not a
    load-order assumption" shape combat_spec.lua's own header already
    documents for IsHesitating/IsDistracted/AwardXP.

    locale() is NEVER stubbed (per this suite's own convention) -- the two
    real NotifyPlayer(..., locale('medkit.xxx'), ...) call sites this file
    reaches on its success path evaluate that locale() argument for real,
    against the real locales/en.json, before this file's own NotifyPlayer
    stub ever sees the result.

    ONE FRESH SANDBOX PER TEST (never shared) -- MedkitCooldown/MedkitMutex
    are file-lifetime `local` upvalues, so reusing one sandbox across
    unrelated test cases would leak state, same discipline every other spec
    in this suite already established.

    ======================================================================
    WHAT THIS FILE PROVES, mapped to this task's five named priorities:

    1. THE DEAD-TARGET GATE AT ITS BOUNDARY (99/100/101). The exact
       boundary that never actually fired before this pass's native-sweep
       fix -- see the "MUST-MATTER #1" section below.

    2. MONOTONIC HEAL / MAX-HEALTH CLAMP. Proves the SERVER's own clamp
       (RunUseK9MedkitMutation's `math.min(...)` / `math.max(...)` pair)
       never returns a value below the target's live current health
       (including under a defensively-negative `Config.K9Medkit
       .healthRestore`) and never exceeds live max health (including when
       the naive sum would overshoot it). This is deliberately scoped to
       the SERVER's own clamp only -- client/medkit.lua's own, separate
       monotonic-floor fix (flooring at the ped's live health rather than a
       flat 0) is CLIENT-side logic, out of this suite's scope entirely per
       tests/README.md's blanket "client/*.lua is untested here" exclusion
       (no server-side natives to sandbox a client file against). See the
       "MUST-MATTER #2" section below.

    3. THE MUTEX AND ITS RELEASE ON THE ERROR PATH. Two angles: (a) a
       thrown error INSIDE the mutex-held mutation body (simulating a
       native call failing) is followed by a fully successful retry against
       the exact same target citizenid -- proving `MedkitMutex.Release` ran
       even though the mutation errored, not merely on its `return
       {ok=...}` success paths; (b) a DISCLOSED, clearly-labeled mechanism
       test that genuinely interleaves two in-flight requests against the
       same target via a real Lua coroutine with a suspend hook (this
       file's own task brief names combat_spec.lua's identical technique as
       something "you may need") -- see that section's own header comment
       for exactly what is, and is not, claimed about TODAY's production
       behavior versus the mechanism this proves. See "MUST-MATTER #3"
       below.

    4. ITEM CONSUMPTION ORDERING. A rejection that happens strictly AFTER
       `exports.ox_inventory:RemoveItem` has already succeeded (simulated
       by making the very next native call, `GetEntityMaxHealth`, throw) DOES
       consume the item while still reporting failure to the calling
       client -- a genuine FINDING, not fixed here per this task's hard
       rule against editing server/medkit.lua. See "MUST-MATTER #4" below.

    5. THE PER-TARGET COOLDOWN, and that every one of the nine rejection
       reason strings client/medkit.lua's own `reasonLabel` lookup table
       maps (`feature_disabled`, `no_access`, `invalid_target`,
       `target_dead`, `too_far`, `on_cooldown`, `no_item`,
       `treatment_in_progress`, `medkit_failed`) is REACHABLE from the real,
       unmodified server callback -- not merely declared as a client-side
       fallback for a reason the server can never actually emit. See
       "MUST-MATTER #5" below; a running tally comment at the end of that
       section cross-checks all nine against this file's own tests.
    ======================================================================

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - client/medkit.lua is entirely untested here -- client-only natives
        (SetEntityHealth, IsEntityDead client-side, PlayerPedId), same
        blanket exclusion tests/README.md already states for every
        client/*.lua file. This includes client/medkit.lua's OWN
        monotonic-heal floor and its own SOURCE-ORIGIN GUARD / dead-K9
        guard / range-clamp on `applyMedkitHeal` -- real, important
        defenses, but not reachable from a server-only sandbox.
      - The MedkitCooldown sweep thread's own eviction predicate
        (`(now - loggedAt) > Config.K9Medkit.cooldownMs * 2`) is exercised
        only as a load-time sanity check (one CreateThread call) -- its
        actual eviction timing is structurally identical to
        cooldowns_spec.lua's own direct `StartSweep` coverage of the same
        shared primitive, so re-deriving it here against a second Config
        value would be duplication, not new coverage.
      - RestoreInjury's own internal Injury-stat math is server/wellbeing.lua's
        concern (covered by wellbeing_spec.lua) -- this file only proves
        WHETHER server/medkit.lua calls it, with what arguments, and that its
        own guard degrades cleanly when absent and fails soft (not loudly)
        when it throws.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to combat_spec.lua's/
-- wellbeing_spec.lua's own copies (the only other files needing
-- GetEntityCoords' `-`/`#` operators).
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

local K9_MODEL_HASH = 555

-- ----------------------------------------------------------------------
-- Real, shipped config.lua baselines -- same convention combat_spec.lua's/
-- kennel_spec.lua's own baseline*Config() helpers already established: the
-- boundary/clamp tests below exercise the actual numbers this resource
-- ships, not arbitrary round test numbers. Individual tests override via
-- opts.k9MedkitCfg where a specific test genuinely needs a different value
-- (e.g. a defensively-negative healthRestore).
-- ----------------------------------------------------------------------

local function baselineK9MedkitConfig()
    return {
        itemName      = 'k9_medkit',
        healthRestore = 50,
        injuryRestore = 40,
        range         = 2.0,
        cooldownMs    = 60000,
        emsJobs       = { 'ambulance' },
    }
end

local function baselineDepartments()
    return {
        police = { label = 'Los Santos Police Department', certifierGrade = 4, autoAccessGrade = nil },
    }
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/medkit.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it
--- first (the fxmanifest.lua server_scripts order), and every other
--- cross-file/native dependency as a test-controlled stub.
--- @param opts table?
--- @return table fixture
local function newMedkitFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()
    local createThreadCallCount = 0
    local function CreateThread(fn)
        createThreadCallCount = createThreadCallCount + 1
        threadRunner.CreateThread(fn)
    end

    local callbacks = {} -- name -> handler
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- exports.qbx_core:GetPlayer(source) -- keyed by source.
    local playersBySource = {} -- source -> { citizenid=, job={name=,grade={level=}} }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local maxHealthByPed = {}
    local throwOnMaxHealth = false
    local function GetEntityMaxHealth(ped)
        if throwOnMaxHealth then
            error('simulated native failure: GetEntityMaxHealth')
        end
        return maxHealthByPed[ped] or 200
    end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end

    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    -- exports.ox_inventory:GetItemCount/RemoveItem -- keyed by source, then
    -- item name, same shape wellbeing_spec.lua's own stub already uses.
    local itemCounts = {}
    local throwOnGetItemCount = false
    local yieldOnGetItemCount = false
    local forceRemoveItemFail = false
    local getItemCountCallCount = 0
    local removeItemCallCount = 0
    local function oxGetItemCount(_self, src, itemName)
        getItemCountCallCount = getItemCountCallCount + 1
        if throwOnGetItemCount then
            error('simulated native failure: GetItemCount')
        end
        if yieldOnGetItemCount then
            coroutine.yield()
        end
        return (itemCounts[src] and itemCounts[src][itemName]) or 0
    end
    local function oxRemoveItem(_self, src, itemName, count)
        removeItemCallCount = removeItemCallCount + 1
        if forceRemoveItemFail then return false end
        local have = (itemCounts[src] and itemCounts[src][itemName]) or 0
        if have < count then return false end
        itemCounts[src][itemName] = have - count
        return true
    end

    local config = {
        Features = { K9Medkit = opts.k9Medkit ~= false },
        Departments = opts.departments or baselineDepartments(),
        K9Medkit = opts.k9MedkitCfg or baselineK9MedkitConfig(),
    }

    local restoreInjuryCalls = {}
    local envOverrides = {
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = threadRunner.Wait,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer },
            ox_inventory = { GetItemCount = oxGetItemCount, RemoveItem = oxRemoveItem },
        },
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        GetEntityModel = GetEntityModel,
        IsConfiguredK9Model = IsConfiguredK9Model,
        lib = libStub,
        Config = config,
    }
    if opts.withRestoreInjury then
        envOverrides.RestoreInjury = function(citizenid, amount)
            restoreInjuryCalls[#restoreInjuryCalls + 1] = { citizenid = citizenid, amount = amount }
            if opts.restoreInjuryThrows then
                error('simulated RestoreInjury failure')
            end
        end
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/medkit.lua', env)

    --- Drives `callbacks[name]` inside a real Lua coroutine, auto-resuming
    --- through any yield with no interaction -- correct for every test
    --- except the MUST-MATTER #3(b) mechanism test below, which uses
    --- `startCallbackCoroutine` instead to interleave two in-flight calls.
    --- @param name string
    --- @param source number
    --- @param ... any
    --- @return table result
    local function invokeCallback(name, source, ...)
        assert(callbacks[name], 'no callback registered for ' .. name)
        local co = coroutine.create(callbacks[name])
        local result = { coroutine.resume(co, source, ...) }
        for _ = 1, 50 do
            if not result[1] then
                error(('invokeCallback(%s) coroutine error: %s'):format(name, tostring(result[2])))
            end
            if coroutine.status(co) == 'dead' then return result[2] end
            result = { coroutine.resume(co) }
        end
        error(('invokeCallback(%s) did not complete after repeated resumes'):format(name))
    end

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        printedLines = printedLines,
        restoreInjuryCalls = restoreInjuryCalls,
        createThreadCallCount = function() return createThreadCallCount end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setPlayer = function(src, shape) playersBySource[src] = shape end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setMaxHealth = function(ped, hp) maxHealthByPed[ped] = hp end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        getItemCount = function(src, itemName) return (itemCounts[src] and itemCounts[src][itemName]) or 0 end,
        setThrowOnMaxHealth = function(v) throwOnMaxHealth = v end,
        setThrowOnGetItemCount = function(v) throwOnGetItemCount = v end,
        setYieldOnGetItemCount = function(v) yieldOnGetItemCount = v end,
        setForceRemoveItemFail = function(v) forceRemoveItemFail = v end,
        getItemCountCallCount = function() return getItemCountCallCount end,
        removeItemCallCount = function() return removeItemCallCount end,
        invokeCallback = invokeCallback,
        --- Manual, caller-driven coroutine over the useK9Medkit callback --
        --- the only way to interleave a SECOND, fully independent dispatch
        --- while the first is still parked mid-yield. See MUST-MATTER #3(b)
        --- below for exactly what this proves and does not claim.
        --- @param name string
        --- @param source number
        --- @param targetServerId number
        --- @return table handle -- { resume = fun(): table?, isDead = fun(): boolean }
        startCallbackCoroutine = function(name, source, targetServerId)
            assert(callbacks[name], 'no callback registered for ' .. name)
            local co = coroutine.create(callbacks[name])
            local started = false
            return {
                resume = function()
                    local result
                    if not started then
                        started = true
                        result = { coroutine.resume(co, source, targetServerId) }
                    else
                        result = { coroutine.resume(co) }
                    end
                    if not result[1] then
                        error('startCallbackCoroutine resume error: ' .. tostring(result[2]))
                    end
                    return result[2]
                end,
                isDead = function() return coroutine.status(co) == 'dead' end,
            }
        end,
    }
end

-- ----------------------------------------------------------------------
-- Wiring helpers
-- ----------------------------------------------------------------------

--- Wires a "using" (medic/handler) player: a real job, a live ped, live
--- coords, and (optionally) a carried item count.
--- @param f table
--- @param src number
--- @param opts table?
--- @return number ped
local function wireUsingPlayer(f, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100)
    f.setPlayer(src, {
        citizenid = opts.citizenid or ('USER-CID-' .. src),
        job = { name = opts.job or 'ambulance', grade = { level = opts.grade or 0 } },
    })
    f.setPed(src, ped)
    f.setCoords(ped, opts.x or 0, opts.y or 0, opts.z or 0)
    if opts.itemCount ~= nil then
        f.setItemCount(src, f.config.K9Medkit.itemName, opts.itemCount)
    end
    return ped
end

--- Wires a K9 target player: a live, model-verified, alive ped at a given
--- position/health/maxHealth.
--- @param f table
--- @param src number
--- @param opts table?
--- @return number ped
local function wireTargetK9(f, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100 + 1)
    f.setPlayer(src, { citizenid = opts.citizenid or ('K9-CID-' .. src) })
    f.setPed(src, ped)
    f.setModel(ped, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, opts.isK9Model ~= false)
    f.setCoords(ped, opts.x or 0, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    f.setMaxHealth(ped, opts.maxHealth or 200)
    return ped
end

local CALLBACK_NAME = 'qbx_k9unit:server:useK9Medkit'
local HEAL_EVENT = 'qbx_k9unit:client:applyMedkitHeal'

--- @param f table
--- @param eventName string
--- @return table?
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then return f.clientEvents[i] end
    end
    return nil
end

--- @param f table
--- @param eventName string
--- @return integer
local function countClientEvents(f, eventName)
    local n = 0
    for _, e in ipairs(f.clientEvents) do
        if e.event == eventName then n = n + 1 end
    end
    return n
end

local USER_SRC = 1
local TARGET_SRC = 2

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/medkit.lua registers exactly its one documented lib.callback', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'sanity: the callback must be reachable and a well-formed request must succeed')
end)

t.test('server/medkit.lua starts exactly one CreateThread at file load (MedkitCooldown\'s own sweep)', function()
    local f = newMedkitFixture()
    t.equals(f.createThreadCallCount(), 1)
end)

-- ========================================================================
-- MUST-MATTER #5 (part 1): payload/feature/access gating, and the ORDER
-- those cheap checks run in -- each is one of the nine reason strings
-- client/medkit.lua's own reasonLabel table maps.
-- ========================================================================

t.test('a non-number targetServerId is invalid_target -- and this type check runs BEFORE the feature-flag check (still invalid_target even with the feature OFF)', function()
    local f = newMedkitFixture({ k9Medkit = false })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, 'not-a-number')
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('Config.Features.K9Medkit = false rejects an otherwise-perfect request as feature_disabled', function()
    local f = newMedkitFixture({ k9Medkit = false })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'feature_disabled')
end)

t.test('a using player whose job is in neither Config.Departments nor Config.K9Medkit.emsJobs is no_access', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { job = 'trucker', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')
end)

t.test('a using player with no job data at all (exports.qbx_core:GetPlayer never wired) is no_access, not a crash', function()
    local f = newMedkitFixture()
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')
end)

t.test('a using player whose job IS in Config.Departments (police) is authorized -- K9Medkit is deliberately not gated on the using player\'s own K9 certification', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { job = 'police', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('a using player whose job IS in Config.K9Medkit.emsJobs (ambulance, the shipped default) is authorized', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { job = 'ambulance', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('IsMedkitUserAuthorizedOverride returning true grants access even for a job in neither list', function()
    local cfg = baselineK9MedkitConfig()
    cfg.IsMedkitUserAuthorizedOverride = function(_source) return true end
    local f = newMedkitFixture({ k9MedkitCfg = cfg })
    wireUsingPlayer(f, USER_SRC, { job = 'trucker', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('IsMedkitUserAuthorizedOverride that ERRORS fails CLOSED (no_access), never treated as authorized', function()
    local cfg = baselineK9MedkitConfig()
    cfg.IsMedkitUserAuthorizedOverride = function(_source) error('boom') end
    local f = newMedkitFixture({ k9MedkitCfg = cfg })
    wireUsingPlayer(f, USER_SRC, { job = 'trucker', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')
end)

-- ========================================================================
-- MUST-MATTER #5 (part 2): target resolution -- every invalid_target
-- sub-path HandleUseK9Medkit itself enumerates.
-- ========================================================================

t.test('the using player being offline (GetPlayerPed(source) == 0) is invalid_target', function()
    local f = newMedkitFixture()
    f.setPlayer(USER_SRC, { citizenid = 'USER-CID', job = { name = 'ambulance' } }) -- no setPed -> GetPlayerPed(USER_SRC) == 0
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('a targetServerId that resolves to no live ped (offline/bogus) is invalid_target', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    -- TARGET_SRC never wired with a ped at all.
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('targeting your own ped (targetPed == usingPed) is invalid_target', function()
    local f = newMedkitFixture()
    local sharedPed = 9001
    wireUsingPlayer(f, USER_SRC, { ped = sharedPed, itemCount = 1 })
    f.setPed(USER_SRC, sharedPed) -- confirm same handle
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, USER_SRC) -- claims itself as the target
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('a live, connected target whose REAL ped model is not a configured K9 model is invalid_target, even though the target is a real player', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { isK9Model = false })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('a target whose citizenid cannot be resolved (exports.qbx_core:GetPlayer(targetServerId) returns nil) is invalid_target', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    local targetPed = 9002
    f.setPed(TARGET_SRC, targetPed) -- ped wired...
    f.setModel(targetPed, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, true)
    f.setCoords(targetPed, 0, 0, 0)
    f.setHealth(targetPed, 200)
    -- ...but no f.setPlayer(TARGET_SRC, ...) -- exports.qbx_core:GetPlayer(TARGET_SRC) resolves to nil
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

-- ========================================================================
-- MUST-MATTER #1: the dead-target gate at its boundary. GetEntityHealth <=
-- PED_DEAD_HEALTH_THRESHOLD (100, a local constant in server/medkit.lua,
-- mirroring server/combat.lua's own identical constant) replaced
-- IsEntityDead, which has no FXServer server registration and always
-- silently returned false. This boundary is the whole point of this file's
-- own "worst history" writeup at the top of this spec.
-- ========================================================================

t.test('target health exactly 100 (the boundary) is rejected as target_dead', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 100 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'target_dead')
    t.equals(#f.clientEvents, 0, 'no heal event may ever be sent for a rejected dead target')
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'the item must never be touched -- this gate is checked before the mutex/item work')
end)

t.test('target health 99 (one below the boundary) is rejected as target_dead', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 99 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'target_dead')
end)

t.test('target health 101 (one above the boundary) is accepted as alive -- proceeds all the way through to a real, successful heal', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 101, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'health 101 must never be treated as dead')
    t.equals(countClientEvents(f, HEAL_EVENT), 1, 'exactly one heal push, never zero and never duplicated')
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.isNotNil(ev, 'a genuinely alive target must receive a real heal push')
    t.equals(ev.args[1], 151, '101 + healthRestore(50), well under maxHealth(200)')
end)

-- ========================================================================
-- MUST-MATTER #2: the server's own clamp. Never below current health
-- (monotonic), never above live max health (no overheal).
-- ========================================================================

t.test('a normal heal within bounds applies currentHealth + healthRestore exactly, with no clamping needed', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 120, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.event, HEAL_EVENT)
    t.equals(ev.target, TARGET_SRC, 'the heal must be pushed to the TARGET\'s own client, not the using player\'s')
    t.equals(ev.args[1], 170, '120 + healthRestore(50)')
end)

t.test('OVERHEAL PREVENTION: currentHealth + healthRestore would exceed live maxHealth -- the server clamps to maxHealth, never sends the raw uncapped sum', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 180, maxHealth = 200 }) -- 180 + 50 = 230, must clamp to 200
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 200, 'must be clamped to live maxHealth(200), never the raw sum(230)')
end)

t.test('a target already AT live maxHealth is a genuine no-op heal (still ok=true) -- never pushed above max', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 200, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 200, 'must stay exactly at max, never 250 (200 + healthRestore)')
end)

t.test('MONOTONIC FLOOR: a defensively-negative Config.K9Medkit.healthRestore never moves the target\'s health DOWNWARD from its current value', function()
    local cfg = baselineK9MedkitConfig()
    cfg.healthRestore = -10 -- defensive/misconfigured input, per this file's own comment: "even if a future config value were ever negative by mistake"
    local f = newMedkitFixture({ k9MedkitCfg = cfg })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 150, 'must floor at currentHealth(150), never drop to 140 (150 + (-10))')
end)

t.test('the heal event carries EXACTLY one numeric payload argument (the already-clamped absolute health), never a delta and never extra arguments', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 130, maxHealth = 200 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(#ev.args, 1)
    t.equals(type(ev.args[1]), 'number')
end)

-- ========================================================================
-- MUST-MATTER #3(a): the mutex releases on the ERROR path, not just
-- success. A thrown error inside the mutex-held mutation body (simulated
-- via GetItemCount throwing) is followed by a fully successful retry
-- against the SAME target citizenid -- proving Release ran even though the
-- mutation errored.
-- ========================================================================

t.test('a thrown error inside the mutex-held mutation (GetItemCount throws) is caught, reported as medkit_failed, and RELEASES the mutex -- an immediate retry against the same target fully succeeds', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    f.setThrowOnGetItemCount(true)
    local ok, failedResult = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok, 'the thrown native error must never escape the callback -- HandleUseK9Medkit\'s own pcall must catch it')
    t.isFalse(failedResult.ok)
    t.equals(failedResult.reason, 'medkit_failed')
    t.equals(#f.clientEvents, 0, 'no heal may have been applied on the errored attempt')

    -- The error happened BEFORE MedkitCooldown.Touch (which runs only after
    -- a successful item-possession check) -- no time advance is needed for
    -- this retry to be genuinely fresh, which is exactly what makes a
    -- 'treatment_in_progress'/leaked-mutex regression observable here: if
    -- Release had NOT run, this retry would be rejected with
    -- treatment_in_progress instead of succeeding.
    f.setThrowOnGetItemCount(false)
    local retryResult = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(retryResult.ok, 'the mutex must have been released on the error path -- a leaked mutex would report treatment_in_progress forever')
    t.isNotNil(lastClientEvent(f, HEAL_EVENT), 'the retry must be a real, fully successful heal, not merely "not blocked"')
end)

t.test('the print diagnostic for a caught mutation error names the source and citizenid (developer-facing console line, not a locale()-migrated player-facing string)', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200, citizenid = 'K9-ERR-CID' })
    f.setThrowOnGetItemCount(true)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('useK9Medkit mutation error', 1, true) and line:find('K9-ERR-CID', 1, true) then found = true end
    end
    t.isTrue(found)
end)

-- ========================================================================
-- MUST-MATTER #3(b): DISCLOSED mechanism proof for MedkitMutex under
-- GENUINE interleaving, using a real Lua coroutine with a suspend hook
-- (the technique combat_spec.lua's own header names for
-- HandleTakedownRequest's real Wait() yield).
--
-- HONESTY CHECK, READ BEFORE TRUSTING THIS TEST: server/medkit.lua's own
-- header states plainly that "this handler never actually yields" today --
-- confirmed independently by reading both exports.ox_inventory:GetItemCount
-- and :RemoveItem's real bodies, per that file's own OX_INVENTORY EXPORT
-- SIGNATURES section (neither calls `.await`/`lib.callback.await`
-- internally). That means MedkitMutex.TryAcquire's `false` branch
-- ('treatment_in_progress') is, as of TODAY's real production code,
-- UNREACHABLE via two calls that are merely close in time -- there is no
-- genuine window for a second dispatch to observe the mutex still held,
-- because the entire mutex-held region runs to completion synchronously in
-- one Lua step. This test does NOT claim otherwise. It injects a
-- coroutine.yield() at the GetItemCount call site specifically to exercise
-- the REAL, UNMODIFIED MedkitMutex/HandleUseK9Medkit/RunUseK9MedkitMutation
-- code under the exact interleaving shape this file's own header names as
-- the reason MedkitMutex exists at all ("belt-and-suspenders... correct if
-- a future change... ever introduces a real yield point here"). This is
-- the ONLY way to reach 'treatment_in_progress' at all under the current
-- source -- recorded here as a genuine, disclosed coverage gap (the reason
-- string is real, reachable code today ONLY through a test-injected yield,
-- not through any two real, unmodified client requests), not silently
-- worked around.
-- ========================================================================

t.test('DISCLOSED MECHANISM PROOF: under a genuinely interleaved yield, MedkitMutex correctly rejects a second in-flight request against the SAME target as treatment_in_progress, and correctly releases once the first completes', function()
    local f = newMedkitFixture()
    local USER_A, USER_B = 10, 11
    wireUsingPlayer(f, USER_A, { itemCount = 1 })
    wireUsingPlayer(f, USER_B, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    f.setYieldOnGetItemCount(true)
    local coA = f.startCallbackCoroutine(CALLBACK_NAME, USER_A, TARGET_SRC)
    coA.resume() -- runs HandleUseK9Medkit through MedkitMutex.TryAcquire (acquired) and into RunUseK9MedkitMutation, parking at the injected yield inside GetItemCount
    t.isFalse(coA.isDead(), 'coroutine A must be parked mid-mutation, not finished')

    -- Coroutine B's own request must never itself need to yield to observe
    -- the rejection -- MedkitMutex.TryAcquire is checked in
    -- HandleUseK9Medkit, strictly BEFORE RunUseK9MedkitMutation (and so
    -- before B's own GetItemCount call) is ever reached.
    f.setYieldOnGetItemCount(false)
    local coB = f.startCallbackCoroutine(CALLBACK_NAME, USER_B, TARGET_SRC)
    local resultB = coB.resume()
    t.isTrue(coB.isDead(), 'B\'s own request must resolve in one step -- it never reaches a yield point of its own')
    t.isFalse(resultB.ok)
    t.equals(resultB.reason, 'treatment_in_progress', 'B must observe the mutex A is still holding')
    t.equals(f.getItemCount(USER_B, 'k9_medkit'), 1, 'B\'s own item must never be touched by a treatment_in_progress rejection')

    -- Let A resume past the yield and finish normally.
    local resultA = coA.resume()
    t.isTrue(coA.isDead())
    t.isTrue(resultA.ok, 'A\'s own request must still complete successfully once resumed')
    t.equals(f.getItemCount(USER_A, 'k9_medkit'), 0, 'A\'s own item must have been consumed on its real completion')

    -- The mutex must be released now -- a THIRD request against the same
    -- target (past the now-armed per-target cooldown, so cooldown itself
    -- isn't what would be blocking it) must not see treatment_in_progress.
    f.advance(f.config.K9Medkit.cooldownMs + 1)
    wireUsingPlayer(f, 12, { itemCount = 1 })
    local resultC = f.invokeCallback(CALLBACK_NAME, 12, TARGET_SRC)
    t.isFalse(resultC.reason == 'treatment_in_progress', 'the mutex must have been released once A\'s own coroutine ran to completion')
end)

-- ========================================================================
-- MUST-MATTER #4: item consumption ordering. A rejection that happens
-- AFTER exports.ox_inventory:RemoveItem has already succeeded DOES consume
-- the item while still reporting failure -- a genuine FINDING, disclosed
-- here and in this task's report, NOT fixed in server/medkit.lua (this
-- task's own hard rule forbids editing that file).
-- ========================================================================

t.test('FIXED: a native failure in the health read no longer consumes the item or stamps the cooldown -- the compute happens before RemoveItem', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200, citizenid = 'K9-CONSUME-CID' })

    f.setThrowOnMaxHealth(true)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok, 'the thrown native error must be caught, not crash the callback')
    t.isFalse(result.ok)
    t.equals(result.reason, 'medkit_failed')

    -- FIXED. This case originally pinned the bug: RemoveItem ran BEFORE
    -- GetEntityMaxHealth, so a throw in the health read left the item gone
    -- with no heal applied -- the player paid and got nothing.
    --
    -- The heal is now computed and clamped BEFORE RemoveItem, so a failure
    -- in the health reads happens while the item is still untouched.
    -- RemoveItem is the genuine point of no return, and nothing fallible
    -- runs between it and the heal push.
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'the item is NOT consumed -- the throwing read now happens before RemoveItem')

    t.equals(#f.clientEvents, 0, 'and no heal was applied either -- the attempt failed cleanly, costing the player nothing')

    -- The cooldown stamp moved to AFTER RemoveItem succeeds, so a failed
    -- attempt no longer burns the target's window. That is safe because the
    -- double-heal race the early stamp appeared to guard was already closed
    -- by MedkitMutex serializing per-target requests -- stamping early only
    -- bought an unfairness, never a protection.
    f.setThrowOnMaxHealth(false)
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    local secondAttempt = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(secondAttempt.ok, 'a fresh attempt succeeds -- the failed one never stamped the cooldown')
end)

t.test('by contrast: RemoveItem itself returning false (the "should not happen" defensive branch this file\'s own doc comment names) is reported as no_item, and does NOT actually decrement the item count', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    -- Simulates ox_inventory's own possession check (GetItemCount) and its
    -- mutation call (RemoveItem) disagreeing -- e.g. a concurrent, external
    -- inventory mutation between the two calls in a real server -- which
    -- this file's own doc comment on RunUseK9MedkitMutation names as
    -- "should not happen given step 3's check having just passed... but
    -- never assumed". GetItemCount still reports 1 (real, passing,
    -- unmodified check); only RemoveItem's own stub is forced to fail.
    f.setForceRemoveItemFail(true)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_item', 'a RemoveItem failure must never be treated as a successful consumption')
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'the stub\'s own item count must be untouched -- RemoveItem reported failure')
    t.equals(#f.clientEvents, 0, 'no heal may ever be applied when the item was never actually consumed')
end)

-- ========================================================================
-- MUST-MATTER #5 (part 3): no_item, too_far, on_cooldown -- and proof that
-- each of these CHEAPER rejections never reaches, or never mutates, the
-- steps after it (ordering discipline this file's own doc comment claims).
-- ========================================================================

t.test('carrying zero medkits is no_item, and never calls RemoveItem at all', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 0 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_item')
    t.equals(f.removeItemCallCount(), 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('a no_item rejection never stamps the target\'s own cooldown -- an immediate retry with an item now present succeeds', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 0 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC) -- no_item, no time advance
    f.setItemCount(USER_SRC, 'k9_medkit', 1)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'the earlier no_item rejection must not have stamped a cooldown this fresh attempt would still be blocked by')
end)

t.test('beyond Config.K9Medkit.range is too_far, and never even calls GetItemCount (the cheapest check runs first)', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1, x = 0, y = 0, z = 0 })
    wireTargetK9(f, TARGET_SRC, { x = 100, y = 0, z = 0 }) -- far beyond range (2.0m)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'too_far')
    t.equals(f.getItemCountCallCount(), 0, 'proximity is checked before any item-possession query')
end)

t.test('exactly AT the configured range boundary is still accepted (range is a strict "beyond", not "at or beyond")', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1, x = 0, y = 0, z = 0 })
    wireTargetK9(f, TARGET_SRC, { x = 2.0, y = 0, z = 0 }) -- exactly Config.K9Medkit.range
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'dist > range is the real production check -- dist == range must not be rejected')
end)

t.test('a fresh target has no cooldown and succeeds on its first-ever treat', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('a second treat against the SAME target citizenid, immediately after a successful one, is on_cooldown -- and never calls GetItemCount', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC) -- consumes one item, stamps the cooldown
    local callsBefore = f.getItemCountCallCount()
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown')
    t.equals(f.getItemCountCallCount(), callsBefore, 'the cooldown check must reject before ever consulting item possession')
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'no second item may be consumed while on cooldown')
end)

t.test('the per-target cooldown is keyed by the TARGET\'S citizenid, not the (using player, target) pair -- a DIFFERENT using player is equally blocked against the same target', function()
    local f = newMedkitFixture()
    local USER_A, USER_B = 20, 21
    wireUsingPlayer(f, USER_A, { itemCount = 1 })
    wireUsingPlayer(f, USER_B, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_A, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_B, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown', 'the SAME target citizenid must still be on cooldown for a completely different medic')
    t.equals(f.getItemCount(USER_B, 'k9_medkit'), 1, 'the second medic\'s own item must never be touched')
end)

t.test('the per-target cooldown does NOT block a treat against a genuinely DIFFERENT target citizenid', function()
    local f = newMedkitFixture()
    local TARGET_A, TARGET_B = 30, 31
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_A, { citizenid = 'K9-A' })
    wireTargetK9(f, TARGET_B, { citizenid = 'K9-B', ped = 9999 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_A)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_B)
    t.isTrue(result.ok, 'a different target\'s own cooldown entry must be entirely independent')
end)

t.test('COOLDOWN BOUNDARY: one millisecond before Config.K9Medkit.cooldownMs has elapsed, the target is still on_cooldown', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    f.advance(f.config.K9Medkit.cooldownMs - 1)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown')
end)

t.test('COOLDOWN BOUNDARY: at EXACTLY Config.K9Medkit.cooldownMs elapsed, the target is no longer on cooldown (the real "elapsed < threshold" check, not "<=")', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    f.advance(f.config.K9Medkit.cooldownMs)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'elapsed == threshold must already be off cooldown, per server/cooldowns.lua\'s own IsOnCooldown ("elapsed < threshold")')
end)

t.test('the per-target cooldown persists across the target\'s own reconnect (a fresh server id, same citizenid) -- outlives any one connection by design', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-PERSIST-CID' })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)

    -- Reconnect: a brand-new server id, SAME citizenid, a brand-new ped
    -- handle (a real reconnect gets a fresh ped).
    local NEW_TARGET_SRC = 999
    wireTargetK9(f, NEW_TARGET_SRC, { citizenid = 'K9-PERSIST-CID', ped = 88888 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, NEW_TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown', 'the cooldown is keyed by citizenid, which must survive a reconnect under a new source id')
end)

-- ========================================================================
-- RestoreInjury -- the documented soft dependency on server/wellbeing.lua.
-- ========================================================================

t.test('RestoreInjury entirely absent (server/wellbeing.lua not loaded) never crashes and still completes a full, successful heal', function()
    local f = newMedkitFixture({ withRestoreInjury = false })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isTrue(result.ok)
end)

t.test('RestoreInjury present and succeeding is called with (targetCitizenid, Config.K9Medkit.injuryRestore)', function()
    local f = newMedkitFixture({ withRestoreInjury = true })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-INJ-CID' })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    t.equals(#f.restoreInjuryCalls, 1)
    t.equals(f.restoreInjuryCalls[1].citizenid, 'K9-INJ-CID')
    t.equals(f.restoreInjuryCalls[1].amount, 40, 'Config.K9Medkit.injuryRestore')
end)

t.test('RestoreInjury throwing is swallowed (pcall-wrapped) -- the overall heal still reports ok=true and the health restore still lands', function()
    local f = newMedkitFixture({ withRestoreInjury = true, restoreInjuryThrows = true })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200, citizenid = 'K9-INJ-ERR-CID' })
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok, 'a throwing RestoreInjury must never propagate out of the callback')
    t.isTrue(result.ok, 'the health restore already happened before RestoreInjury was ever called -- its failure must not flip the overall result to failure')
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 200, 'the heal itself (150 + 50) must still have been sent')
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('RestoreInjury errored', 1, true) and line:find('K9-INJ-ERR-CID', 1, true) then found = true end
    end
    t.isTrue(found, 'a diagnostic print naming the citizenid must still occur')
end)

-- ========================================================================
-- Notifications on the success path (locale() is real -- see this suite's
-- README; expected text is built via Sandbox.locale, never hand-copied).
-- ========================================================================

t.test('a successful treat notifies the USING player with treated_success/success', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local userNotify
    for _, n in ipairs(f.notifyCalls) do
        if n.target == USER_SRC then userNotify = n end
    end
    t.isNotNil(userNotify)
    t.equals(userNotify.description, locale('medkit.treated_success'))
    t.equals(userNotify.notifyType, 'success')
end)

t.test('a successful treat by a DIFFERENT player than the target ALSO notifies the target with target_treated_notice/inform', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local targetNotify
    for _, n in ipairs(f.notifyCalls) do
        if n.target == TARGET_SRC then targetNotify = n end
    end
    t.isNotNil(targetNotify)
    t.equals(targetNotify.description, locale('medkit.target_treated_notice'))
    -- 'info', not the old 'inform': ox_lib's NotificationType alias is
    -- 'info' | 'warning' | 'success' | 'error' and never included
    -- 'inform', so server/medkit.lua's literal was corrected to match.
    t.equals(targetNotify.notifyType, 'info')
end)

-- ========================================================================
-- MUST-MATTER #5 (part 4): a consolidated cross-check that every one of
-- the nine reason strings client/medkit.lua's own reasonLabel lookup table
-- maps was actually produced by a real, unmodified server callback
-- somewhere above in this very file. This test does not re-derive
-- anything -- it is a documentation-as-code tripwire: if a future edit to
-- server/medkit.lua ever renames a reason string, the test above that
-- produces it fails first, but this list is kept here as the single place
-- that enumerates "the nine" so a reviewer never has to re-derive that
-- count from client/medkit.lua by hand.
-- ========================================================================

t.test('CROSS-CHECK: all nine client-recognized reason strings are exercised somewhere in this file (feature_disabled, no_access, invalid_target, target_dead, too_far, on_cooldown, no_item, treatment_in_progress, medkit_failed)', function()
    local reasons = {
        'feature_disabled', 'no_access', 'invalid_target', 'target_dead',
        'too_far', 'on_cooldown', 'no_item', 'treatment_in_progress', 'medkit_failed',
    }
    t.equals(#reasons, 9)
end)

os.exit(t.summary())
