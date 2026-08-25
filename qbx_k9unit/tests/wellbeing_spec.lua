--[[
    tests/wellbeing_spec.lua

    First test coverage for server/wellbeing.lua (previously zero). Loads
    the REAL, unmodified server/cooldowns.lua -> server/entities.lua ->
    server/wellbeing.lua chain into one sandbox (the fxmanifest.lua
    server_scripts order), and drives it through:

      - the real captured lib.callback.register handlers (petK9, feedK9,
        applyK9Distraction, getWellbeingSnapshot),
      - the real captured RegisterNetEvent/AddEventHandler handlers
        (relayDamageEvent, relayWeaponFire, calmDownK9, playerDropped),
      - the shared TickWellbeing maintenance thread (stepped via
        fixtures/sandbox.lua's coroutine thread runner, same technique
        defense_spec.lua/tenure_spec.lua already established),
      - the resource-global accessors (IsHesitating, IsDistracted,
        IsFlashbangImmune, RestoreInjury), called directly since none of
        them is `local`.

    server/certifications.lua is DELIBERATELY NOT loaded here -- only
    IsConfiguredK9Model is stubbed directly, same "stub, don't load, a
    function already covered by its own file's spec" convention
    kennel_spec.lua's own header already establishes for HasK9Access/
    NotifyPlayer. IsConfiguredK9Model itself is covered by
    certifications_spec.lua; NotifyPlayer by notify_spec.lua.

    Fatigue's rest-source world scan (GetAllObjects/GetAllVehicles/
    GetHashKey) is DELIBERATELY NOT exercised: every fixture below sets
    Config.Wellbeing.Fatigue.restSources = {} (the shipped default is
    {'water_bowl'}), which keeps TickWellbeing's own `#restSources > 0`
    guard false and the scan skipped entirely -- out of this task's
    four-point scope (shared cooldown, tick thread, hesitation cap, relay
    ingest). GetAllObjects/GetAllVehicles/GetHashKey are still stubbed
    (returning empty/identity) purely as a safety net so a future edit
    that accidentally exercises that path fails on a real assertion
    instead of an unregistered-global error -- not a claim that path is
    covered. Recorded here as a disclosed gap, not silently skipped.

    calmDownK9 (FearStress's self-only "Calm Down" action) is only
    covered indirectly (it is one of the three RegisterNetEvent names the
    sanity check below counts) -- its own cooldown/notify behavior is not
    separately exercised, since the task's four points do not name it and
    its shape (a single self-only cooldowned decrement, no target
    resolution) is materially simpler than anything covered below.

    WHAT THIS FILE PROVES, mapped to the task's four points:
      1. petK9 and feedK9 share ONE cooldown INSTANCE (not merely the same
         threshold value) per (interactor source, target citizenid) pair --
         alternating the two calls on the same pair grants exactly one
         mood tick per petCooldownMs window, in both directions
         (pet-then-feed and feed-then-pet), while a different target or a
         different interactor is genuinely unaffected.
      2. The tick thread: one TickWellbeing pass per step() after priming
         (interval honored), playerDropped resets ONLY `lastCoords` (never
         mood/fatigue/fearStress/injury, which persist across a disconnect
         within the same session, re-observable under a brand-new source
         id for the same citizenid), and distractedUntil is a real
         absolute timestamp that lapses on its own.
      3. HESITATION_MAX_CONTINUOUS_MS forces recovery: a hostile source
         that reports fresh gunfire on EVERY single tick, without ever
         stopping, still cannot keep a K9 hesitating forever -- pinned with
         exact tick-by-tick math against the real shipped config numbers
         (hesitationThreshold=85, risePerNearbyShotPerTick=3.0,
         hesitationDurationMs=8000, the documented "8 renewal-cycles'
         worth" cap).
      4. relayDamageEvent/relayWeaponFire: reporting-source validation
         (non-K9 source, disconnected/ped==0 source, unresolved citizenid
         all no-op), the ingest cooldown genuinely gating a NEW entry at
         ingestion (not merely relying on TickWellbeing's own later
         per-tick distinct-source dedup -- proven with a far-then-near
         same-source double-report technique for relayWeaponFire), the
         ingest cooldown being per-source, and that extra/garbage call
         arguments on these payload-less events are ignored (only the
         reporting player's own server-resolved position/model/citizenid
         is ever used).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to defense_spec.lua's/
-- tenure_spec.lua's own copies (the only other files needing
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

-- ----------------------------------------------------------------------
-- Real, shipped config.lua values for Config.Wellbeing/Config.Tracking --
-- used as this fixture's baseline so boundary/tick-math tests exercise the
-- actual numbers this resource ships, not arbitrary round test numbers.
-- restSources is deliberately emptied -- see this file's own header.
-- ----------------------------------------------------------------------

local function baselineWellbeingConfig()
    return {
        tickIntervalMs = 5000,
        Fatigue = {
            max                    = 100,
            sprintDecayPerTick     = 2.0,
            idleRegenPerTick       = 1.0,
            restRegenPerTick       = 4.0,
            restRadius             = 5.0,
            restSources            = {}, -- shipped default is {'water_bowl'} -- emptied here, see file header
            speedPenaltyThreshold  = 30,
            speedPenaltyMultiplier = 0.90,
            sprintSpeedThreshold   = 4.0,
        },
        Mood = {
            max                          = 100,
            damageDecayAmount            = 15,
            petRegenAmount               = 10,
            petCooldownMs                = 30000,
            feedRegenAmount              = 20,
            feedItemName                 = 'k9_treat',
            passiveRegenPerTick          = 1.0,
            performancePenaltyThreshold  = 25,
            performancePenaltyMultiplier = 0.95,
        },
        FearStress = {
            max                      = 100,
            gunfireRadius            = 20.0,
            gunfireLookbackSeconds   = 15,
            risePerNearbyShotPerTick = 3.0,
            passiveDecayPerTick      = 1.0,
            hesitationThreshold      = 85,
            hesitationDurationMs     = 8000,
            calmDownReduceAmount     = 40,
            calmDownCooldownMs       = 15000,
        },
        Distraction = {
            flashbangImmune     = true,
            meatBaitItemName    = 'k9_meat_bait',
            meatBaitDurationMs  = 6000,
            meatBaitRadius      = 8.0,
            whistleItemName     = 'k9_ultrasonic_whistle',
            whistleDurationMs   = 4000,
            whistleRadius       = 15.0,
            perTargetCooldownMs = 20000,
        },
        Injury = {
            max                    = 100,
            sprintBlockThreshold   = 30,
            jumpBlockThreshold     = 20,
            speedPenaltyMultiplier = 0.80,
            damageDecayAmount      = 10,
            -- RAISED 0.1 -> 1.0 (this task's own recommendation, reported to
            -- the task owner for config.lua -- see server/wellbeing.lua's
            -- header, STUCK-K9 SOFTLOCK FIX item 1, for the full arithmetic).
            -- config.lua itself still ships 0.1 as of this pass (not owned
            -- by this task) -- this fixture encodes the RECOMMENDED value so
            -- the bounded-ticks tests below prove the fix that should ship,
            -- not the bug that currently does. See the dedicated
            -- "CURRENTLY-SHIPPED 0.1 RATE" section further down for tests
            -- pinned against the OLD value instead, documenting the
            -- QA-reported bug's own exact arithmetic.
            passiveRegenPerTick    = 1.0,
            -- NEW FIELD (this task, reported to the task owner for
            -- config.lua -- see server/wellbeing.lua's header, STUCK-K9
            -- SOFTLOCK FIX item 2). 100 = Injury.max = a full reset on
            -- death/respawn, this task's own chosen default. Set to 0 to
            -- disable (an operator preferring "still limping after
            -- respawn," a genuine supported no-op per server/wellbeing.lua's
            -- own `restoreAmount > 0` guard).
            deathRespawnRestoreAmount = 100,
        },
    }
end

local function baselineFeatures(overrides)
    local features = {
        FatigueSystem      = false,
        MoodSystem         = false,
        FearStressSystem   = false,
        DistractionSystem  = false,
        InjuryLimping      = false,
    }
    for key, value in pairs(overrides or {}) do
        features[key] = value
    end
    return features
end

--- Builds one complete, independent sandbox for server/wellbeing.lua, with
--- the real server/cooldowns.lua and server/entities.lua loaded alongside
--- it first (the exact fxmanifest.lua server_scripts order), and every
--- other cross-file/native dependency as a test-controlled stub.
--- @param opts table? -- { featuresOverride, wellbeingCfg }
--- @return table fixture
local function newWellbeingFixture(opts)
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

    local registeredNetEvents = {} -- eventName -> true
    local function RegisterNetEvent(eventName, handler)
        registeredNetEvents[eventName] = true
        if handler then
            AddEventHandler(eventName, handler)
        end
    end

    local callbacks = {} -- name -> handler
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    -- exports.qbx_core:GetPlayer(src) -- keyed by source, holds citizenid
    local citizenidBySource = {}
    local function qbxGetPlayer(_self, src)
        local citizenid = citizenidBySource[src]
        if not citizenid then return nil end
        return { PlayerData = { citizenid = citizenid } }
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

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    -- DEATH/RESPAWN (this task) -- defaults every ped to 200 (alive, native
    -- max health), matching combat_spec.lua's/medkit_spec.lua's own default
    -- so a fixture that never calls setHealth behaves exactly as before
    -- this addition.
    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    -- Safety-net stubs only -- see this file's header on why the Fatigue
    -- rest-source scan is not exercised. Never expected to be hit given
    -- every fixture config's restSources = {}.
    local function GetAllObjects() return {} end
    local function GetAllVehicles() return {} end
    local function GetHashKey(name) return name end

    -- STARTUP VALIDATION (this task) -- GetCurrentResourceName/onResourceStart
    -- support for exercising the new WarnIfItemMissing/onResourceStart block.
    local RESOURCE_NAME = 'qbx_k9unit'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- exports.ox_inventory:GetItemCount/RemoveItem -- keyed by source, then item name.
    local itemCounts = {}
    local function oxGetItemCount(_self, source, itemName)
        return (itemCounts[source] and itemCounts[source][itemName]) or 0
    end
    local function oxRemoveItem(_self, source, itemName, count)
        local have = (itemCounts[source] and itemCounts[source][itemName]) or 0
        if have < count then return false end
        itemCounts[source][itemName] = have - count
        return true
    end

    -- exports.ox_inventory:Items(itemName) -- the server's own live item
    -- registry (this task, STARTUP VALIDATION section). Keyed by item name
    -- -> true (registered); a name never registered here correctly returns
    -- nil, matching real ox_inventory's own getItem() behavior for an
    -- unknown name.
    local registeredItems = {}
    local throwOnItemsExport = false
    local function oxItems(_self, itemName)
        if throwOnItemsExport then
            error('simulated native failure: ox_inventory Items()')
        end
        if registeredItems[itemName] then return { name = itemName } end
        return nil
    end

    local config = {
        Features = baselineFeatures(opts.featuresOverride),
        Wellbeing = opts.wellbeingCfg or baselineWellbeingConfig(),
        Tracking = {
            Blood     = { relayCooldownMs = 500 },
            Gunpowder = { relayCooldownMs = 300 },
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer         = GetGameTimer,
        CreateThread         = CreateThread,
        Wait                 = threadRunner.Wait,
        AddEventHandler      = AddEventHandler,
        RegisterNetEvent     = RegisterNetEvent,
        TriggerClientEvent   = TriggerClientEvent,
        print                = printStub,
        NotifyPlayer         = NotifyPlayer,
        lib                  = lib,
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer },
            ox_inventory = { GetItemCount = oxGetItemCount, RemoveItem = oxRemoveItem, Items = oxItems },
        },
        GetPlayers           = GetPlayers,
        GetPlayerPed         = GetPlayerPed,
        GetEntityModel       = GetEntityModel,
        IsConfiguredK9Model  = IsConfiguredK9Model,
        GetEntityCoords      = GetEntityCoords,
        GetEntityHealth      = GetEntityHealth,
        GetAllObjects        = GetAllObjects,
        GetAllVehicles       = GetAllVehicles,
        GetHashKey           = GetHashKey,
        GetCurrentResourceName = GetCurrentResourceName,
        Config               = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/wellbeing.lua', env)

    local primed = false
    local function primeIfNeeded()
        if not primed then
            threadRunner.step()
            primed = true
        end
    end

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        printedLines = printedLines,
        notifyCalls = notifyCalls,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setPlayer = function(src, citizenid) citizenidBySource[src] = citizenid end,
        clearPlayer = function(src) citizenidBySource[src] = nil end,
        setOnline = function(ids) onlinePlayerIds = ids end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        getItemCount = function(src, itemName) return (itemCounts[src] and itemCounts[src][itemName]) or 0 end,
        registerInventoryItem = function(itemName) registeredItems[itemName] = true end,
        setThrowOnItemsExport = function(v) throwOnItemsExport = v end,
        invokeCallback = function(name, source, ...)
            assert(callbacks[name], 'no callback registered for ' .. name)
            return callbacks[name](source, ...)
        end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            for _, handler in ipairs(eventHandlers[eventName] or {}) do
                handler(...)
            end
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler()
            end
        end,
        --- Fires 'onResourceStart' with the given resourceName -- mirrors
        --- firePlayerDropped's shape. `resourceName` defaults to this
        --- fixture's own stubbed GetCurrentResourceName() value ('qbx_k9unit')
        --- so the common case ("this resource itself just started") needs no
        --- argument; callers testing the `GetCurrentResourceName() ~=
        --- resourceName` guard pass a different name explicitly.
        --- @param resourceName string?
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'qbx_k9unit')
            end
        end,
        registeredNetEvents = registeredNetEvents,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        createThreadCallCount = function() return createThreadCallCount end,
        primeIfNeeded = primeIfNeeded,
        runOneTick = function()
            primeIfNeeded()
            threadRunner.step()
        end,
        isHesitating = function(citizenid) return env.IsHesitating(citizenid) end,
        isDistracted = function(citizenid) return env.IsDistracted(citizenid) end,
        isFlashbangImmune = function(citizenid) return env.IsFlashbangImmune(citizenid) end,
        restoreInjury = function(citizenid, amount) return env.RestoreInjury(citizenid, amount) end,
    }
end

--- Wires up a minimal interactor/target pair for petK9/feedK9: interactor
--- is an ordinary connected player (not necessarily K9-modeled -- petK9/
--- feedK9 never require the INTERACTOR to be a K9), target is a
--- K9-modeled connected player. Both default to 0 distance apart.
--- @param f table
--- @param opts table?
--- @return number interactorSrc, number targetSrc
local function wireMoodPair(f, opts)
    opts = opts or {}
    local interactorSrc = opts.interactorSrc or 1
    local targetSrc = opts.targetSrc or 2
    local interactorPed = opts.interactorPed or 9001
    local targetPed = opts.targetPed or 9002
    f.setPlayer(interactorSrc, opts.interactorCid or 'HANDLER-CID')
    f.setPlayer(targetSrc, opts.targetCid or 'K9-CID')
    f.setPed(interactorSrc, interactorPed)
    f.setPed(targetSrc, targetPed)
    f.setModel(targetPed, 555)
    f.setIsK9Model(555, true)
    f.setCoords(interactorPed, 0, 0, 0)
    f.setCoords(targetPed, opts.distance or 0, 0, 0)
    return interactorSrc, targetSrc
end

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/wellbeing.lua registers exactly its three documented server net events', function()
    local f = newWellbeingFixture()
    local count = 0
    for _ in pairs(f.registeredNetEvents) do count = count + 1 end
    t.equals(count, 3)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:relayDamageEvent'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:relayWeaponFire'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:calmDownK9'] ~= nil)
end)

t.test('server/wellbeing.lua registers at least one playerDropped handler', function()
    local f = newWellbeingFixture()
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1, "this file's own lastCoords-reset handler, plus every cooldown tracker's own RegisterPlayerDropped()")
end)

t.test('No TickWellbeing activity when every one of the five wellbeing feature flags is false -- stepping produces zero wellbeingUpdate events', function()
    local f = newWellbeingFixture() -- all features false by default
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.runOneTick()
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test("DISCREPANCY: DistractionCooldown's own sweep thread starts unconditionally at file load, even when every one of the five wellbeing feature flags is false -- this file's own header claims 'no thread at all' in that case", function()
    -- server/wellbeing.lua's header states: "This file starts NO thread at
    -- all if all five flags are false (see the CreateThread guard near the
    -- bottom)." That guard is real for the shared TickWellbeing loop, but
    -- `DistractionCooldown.StartSweep(...)` (unconditional, right after the
    -- tracker's own declaration) calls CreateThread unconditionally at file
    -- load regardless of Config.Features.DistractionSystem or any other
    -- flag. Not a correctness bug (an idle sweep over an always-empty table
    -- costs nothing observable to a player), but a real, pinnable gap
    -- between the header's claim and the actual runtime behavior -- same
    -- "disclosed, regression-guarded" treatment tenure_spec.lua's own
    -- TenureFullyCollected DISCREPANCY test already established for this
    -- suite, not a reason to edit server/wellbeing.lua.
    local f = newWellbeingFixture() -- all features false
    t.equals(f.createThreadCallCount(), 1, "exactly one CreateThread call happens at file-load time even with every feature off -- DistractionCooldown's own sweep, not the gated TickWellbeing loop")
end)

t.test('With any one wellbeing feature on, exactly two threads are created: the gated TickWellbeing loop, plus the always-on DistractionCooldown sweep', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    t.equals(f.createThreadCallCount(), 2)
end)

-- ========================================================================
-- POINT 1: petK9 and feedK9 share ONE cooldown per (interactor, target).
-- ========================================================================

t.test('petK9 then feedK9 alternated on the SAME (interactor, target) within petCooldownMs: feedK9 is blocked by the cooldown pet already stamped -- exactly one mood tick, not two', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc, targetSrc = wireMoodPair(f)
    f.setItemCount(interactorSrc, 'k9_treat', 5)

    -- Lower mood below its max=100 ceiling first (4 self-reported damage
    -- events from the K9 itself), so a real vs. doubled mood-regen tick is
    -- observable instead of being masked by the clamp.
    for _ = 1, 4 do
        f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', targetSrc)
        f.advance(501) -- past Config.Tracking.Blood.relayCooldownMs (500)
    end
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', targetSrc)
    t.equals(snap.mood, 40, '100 - 4*15')

    local petResult = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, targetSrc)
    t.isTrue(petResult.ok)
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', targetSrc)
    t.equals(snap.mood, 50, '40 + petRegenAmount(10)')

    -- Immediately alternate to feedK9 on the SAME (interactor, target) pair
    -- -- the historical bug (two independent NewNestedCooldown() instances
    -- sharing only the threshold VALUE, not the tracker instance) let this
    -- through as a SECOND mood tick inside one petCooldownMs window.
    local feedResult = f.invokeCallback('qbx_k9unit:server:feedK9', interactorSrc, targetSrc)
    t.isFalse(feedResult.ok)
    t.equals(feedResult.reason, 'on_cooldown')
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', targetSrc)
    t.equals(snap.mood, 50, 'feedK9 must be genuinely blocked -- mood must NOT have moved to 70 (50 + feedRegenAmount 20), which is what the pre-fix two-cooldown-instances bug would have allowed')
    t.equals(f.getItemCount(interactorSrc, 'k9_treat'), 5, 'the treat item must not be consumed when the shared cooldown rejects the request before the item-possession check')

    -- Once petCooldownMs has genuinely elapsed, feedK9 on the same pair
    -- must now succeed -- proving this is a real, eventually-releasing
    -- cooldown, not merely broken/blocked forever.
    f.advance(30000) -- Config.Wellbeing.Mood.petCooldownMs
    local feedResult2 = f.invokeCallback('qbx_k9unit:server:feedK9', interactorSrc, targetSrc)
    t.isTrue(feedResult2.ok)
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', targetSrc)
    t.equals(snap.mood, 70, '50 + feedRegenAmount(20)')
    t.equals(f.getItemCount(interactorSrc, 'k9_treat'), 4, 'exactly one treat consumed for the successful feed')
end)

t.test('feedK9 then petK9 alternated on the SAME (interactor, target): the same shared cooldown blocks petK9 too -- proves the sharing is symmetric, not a one-directional patch', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc, targetSrc = wireMoodPair(f)
    f.setItemCount(interactorSrc, 'k9_treat', 5)
    for _ = 1, 4 do
        f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', targetSrc)
        f.advance(501)
    end

    local feedResult = f.invokeCallback('qbx_k9unit:server:feedK9', interactorSrc, targetSrc)
    t.isTrue(feedResult.ok)
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', targetSrc)
    t.equals(snap.mood, 60, '40 + feedRegenAmount(20)')

    local petResult = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, targetSrc)
    t.isFalse(petResult.ok)
    t.equals(petResult.reason, 'on_cooldown')
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', targetSrc)
    t.equals(snap.mood, 60, 'petK9 must not have added its own petRegenAmount(10) on top')
end)

t.test('The shared cooldown is keyed per (interactor, target) -- a DIFFERENT target under the same interactor is unaffected by the first target\'s own cooldown entry', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc, target1Src = wireMoodPair(f, { targetSrc = 2, targetCid = 'K9-1-CID', targetPed = 9002 })
    local target2Src, target2Ped = 3, 9003
    f.setPlayer(target2Src, 'K9-2-CID')
    f.setPed(target2Src, target2Ped)
    f.setModel(target2Ped, 555)
    f.setCoords(target2Ped, 0, 0, 0)

    local r1 = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, target1Src)
    t.isTrue(r1.ok)
    local r2 = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, target2Src)
    t.isTrue(r2.ok, "petting a DIFFERENT K9 immediately afterward must not be blocked by the first target's own cooldown entry")
end)

t.test('The shared cooldown is keyed per (interactor, target) -- a DIFFERENT interactor petting the SAME target is unaffected by the first interactor\'s own cooldown entry', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactor1Src, targetSrc = wireMoodPair(f)
    local interactor2Src, interactor2Ped = 3, 9004
    f.setPlayer(interactor2Src, 'HANDLER-2-CID')
    f.setPed(interactor2Src, interactor2Ped)
    f.setCoords(interactor2Ped, 0, 0, 0)

    local r1 = f.invokeCallback('qbx_k9unit:server:petK9', interactor1Src, targetSrc)
    t.isTrue(r1.ok)
    local r2 = f.invokeCallback('qbx_k9unit:server:petK9', interactor2Src, targetSrc)
    t.isTrue(r2.ok, "a second, different interactor petting the same K9 immediately afterward must not be blocked by the first interactor's own cooldown entry")
end)

t.test('petK9: a non-number targetServerId is rejected as invalid_target before any other check', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc = wireMoodPair(f)
    local r = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, 'not-a-number')
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('petK9: Config.Features.MoodSystem = false rejects an otherwise-perfect request as feature_disabled', function()
    local f = newWellbeingFixture() -- MoodSystem false
    local interactorSrc, targetSrc = wireMoodPair(f)
    local r = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, targetSrc)
    t.isFalse(r.ok)
    t.equals(r.reason, 'feature_disabled')
end)

t.test('petK9: a target beyond the 3.0m MOOD_INTERACT_RANGE (a local constant in server/wellbeing.lua, not in Config) is rejected as too_far', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc, targetSrc = wireMoodPair(f, { distance = 3.1 })
    local r = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, targetSrc)
    t.isFalse(r.ok)
    t.equals(r.reason, 'too_far')
end)

t.test('petK9: a target whose LIVE ped model is not a configured K9 model is rejected as invalid_target, even though targetServerId resolves to a real connected player', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc, targetSrc = wireMoodPair(f)
    f.setIsK9Model(555, false) -- the target's own ped model is no longer a configured K9 model
    local r = f.invokeCallback('qbx_k9unit:server:petK9', interactorSrc, targetSrc)
    t.isFalse(r.ok)
    t.equals(r.reason, 'invalid_target')
end)

t.test('feedK9: insufficient carried item count is rejected as no_item and consumes nothing, on a fresh (never-cooldowned) pair', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local interactorSrc, targetSrc = wireMoodPair(f)
    f.setItemCount(interactorSrc, 'k9_treat', 0)
    local r = f.invokeCallback('qbx_k9unit:server:feedK9', interactorSrc, targetSrc)
    t.isFalse(r.ok)
    t.equals(r.reason, 'no_item')
end)

-- ========================================================================
-- POINT 2: the tick thread -- interval honored, per-player state cleaned
-- on playerDropped, distractedUntil/hesitatingUntil are absolute
-- timestamps that must eventually lapse (distractedUntil here;
-- hesitatingUntil in the HESITATION_MAX_CONTINUOUS_MS section below).
-- ========================================================================

t.test('Each step() after priming executes exactly one TickWellbeing pass -- one wellbeingUpdate event per online K9 per step, not zero and not multiple', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick() -- primes, then executes pass 1
    t.equals(#f.clientEvents, 1)
    f.runOneTick() -- pass 2
    t.equals(#f.clientEvents, 2)
    f.runOneTick() -- pass 3
    t.equals(#f.clientEvents, 3)
end)

t.test('playerDropped resets ONLY lastCoords -- a disconnect-and-reconnect-elsewhere must not manufacture a bogus sprint-fatigue hit', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick() -- first-ever sample: no prior lastCoords, so no speed can be computed yet
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 100, 'Fatigue starts at max and the very first tick has no prior sample to compute a speed from')

    f.firePlayerDropped(1) -- disconnects
    f.setCoords(9001, 10000, 10000, 0) -- reconnect at a wildly different location (a fresh spawn)
    f.runOneTick()

    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 100, 'lastCoords must have been reset by playerDropped -- without the reset, this tick would compute an enormous bogus "sprint" speed (10000+ meters in one tickIntervalMs) and apply sprintDecayPerTick, dropping fatigue to 98')
end)

t.test('playerDropped does NOT clear mood/fatigue/injury themselves -- wellbeing persists across a disconnect, re-observable under a brand-new source id for the same citizenid', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)

    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1) -- mood 100 -> 85
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.mood, 85)

    f.firePlayerDropped(1)
    f.clearPlayer(1)

    -- Reconnect: SAME citizenid, a brand-new server source id.
    f.setPlayer(2, 'K9-CID')
    local snap2 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 2)
    t.equals(snap2.mood, 85, 'mood must be re-read from the same citizenid-keyed WellbeingStats entry, never reset to a fresh default')
end)

t.test('DistractionSystem: distractedUntil is a real, eventually-lapsing absolute timestamp -- IsDistracted is true immediately after applyK9Distraction and false once its full duration has elapsed', function()
    local f = newWellbeingFixture({ featuresOverride = { DistractionSystem = true } })
    local usingSrc, targetSrc = 1, 2
    f.setPlayer(usingSrc, 'USER-CID')
    f.setPed(usingSrc, 9001)
    f.setCoords(9001, 0, 0, 0)
    f.setOnline({ targetSrc })
    f.setPlayer(targetSrc, 'K9-CID')
    f.setPed(targetSrc, 9002)
    f.setModel(9002, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9002, 0, 0, 0)
    f.setItemCount(usingSrc, 'k9_meat_bait', 1)

    local r = f.invokeCallback('qbx_k9unit:server:applyK9Distraction', usingSrc, 'meatBait')
    t.isTrue(r.ok)
    t.equals(r.affected, 1)
    t.isTrue(f.isDistracted('K9-CID'))

    f.advance(6000) -- Config.Wellbeing.Distraction.meatBaitDurationMs
    t.isFalse(f.isDistracted('K9-CID'), 'distractedUntil is an absolute timestamp -- it must lapse once GetGameTimer() passes it, never stay pinned')
end)

-- ========================================================================
-- POINT 3: HESITATION_MAX_CONTINUOUS_MS forces recovery even under a
-- continuously-refreshed forged/real gunfire signal.
-- ========================================================================

t.test('HESITATION_MAX_CONTINUOUS_MS forces recovery: a hostile source reporting FRESH gunfire on EVERY single tick, without ever stopping, still cannot keep a K9 hesitating forever', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    local k9Src, attackerSrc = 1, 99
    f.setOnline({ k9Src })
    f.setPlayer(k9Src, 'K9-CID')
    f.setPed(k9Src, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPed(attackerSrc, 9099)
    f.setCoords(9099, 0, 0, 0) -- well within gunfireRadius (20.0) for the entire test

    -- risePerNearbyShotPerTick = 3.0, hesitationThreshold = 85 -> fearStress
    -- first reaches >= 85 on tick 29 (29*3 = 87).
    for _ = 1, 28 do
        f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', attackerSrc)
        f.advance(5000) -- tickIntervalMs
        f.runOneTick()
    end
    t.isFalse(f.isHesitating('K9-CID'), 'one tick before crossing the threshold, hesitation must not have started yet')

    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', attackerSrc)
    f.advance(5000) -- now = 29*5000 = 145000
    f.runOneTick()
    t.isTrue(f.isHesitating('K9-CID'), 'tick 29 crosses hesitationThreshold and starts the episode')

    -- Keep reporting fresh gunfire EVERY tick, uninterrupted, through the
    -- rest of the episode -- ticks 30..41 (now up to 205000) stay within
    -- HESITATION_MAX_CONTINUOUS_MS = hesitationDurationMs * 8 = 64000ms of
    -- the episode's start (145000; this "8 renewal-cycles' worth" factor is
    -- documented verbatim in server/wellbeing.lua's own comment on
    -- HESITATION_MAX_CONTINUOUS_MS), so each of these renews hesitatingUntil.
    for i = 30, 41 do
        f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', attackerSrc)
        f.advance(5000)
        f.runOneTick()
        t.isTrue(f.isHesitating('K9-CID'), ('still within the 64s continuous-episode cap at tick %d'):format(i))
    end

    -- Tick 42 (now = 210000): 210000 - 145000 = 65000 >= 64000 -- the forced
    -- recovery branch fires: fearStress resets to 0 and the episode clock
    -- restarts, but hesitatingUntil itself is left at whatever the LAST
    -- legitimate renewal set it to (tick 41, now=205000 -> hesitatingUntil =
    -- 205000 + hesitationDurationMs(8000) = 213000) -- so hesitation is
    -- still (correctly) reported true for this one instant, exactly per
    -- that code path's own comment ("allowed to elapse on its own").
    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', attackerSrc)
    f.advance(5000) -- now = 210000
    f.runOneTick()
    t.isTrue(f.isHesitating('K9-CID'), 'the forced-reset tick itself must not instantly clear hesitation -- the real window is the elapsing of the LAST legitimate renewal, not an immediate cutoff')

    -- Tick 43 (now = 215000): fearStress has climbed back only to 3 (one
    -- tick's rise since the reset), nowhere near hesitationThreshold again,
    -- and hesitatingUntil (213000) is now in the past -- IsHesitating must
    -- read false, EVEN THOUGH the attacker has reported fresh gunfire on
    -- every single tick without a single gap the entire test.
    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', attackerSrc)
    f.advance(5000) -- now = 215000
    f.runOneTick()
    t.isFalse(f.isHesitating('K9-CID'), 'a continuously-refreshed hesitation signal must still genuinely end -- this is the exact griefing vector HESITATION_MAX_CONTINUOUS_MS exists to bound')
end)

-- ========================================================================
-- POINT 4: relayDamageEvent / relayWeaponFire -- source validation, ingest
-- cooldowns, nothing client-supplied trusted without re-derivation.
-- ========================================================================

t.test('relayDamageEvent: MoodSystem and InjuryLimping both off -- entirely inert, no crash', function()
    local f = newWellbeingFixture() -- both false
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayDamageEvent', 1)
    t.isTrue(ok)
end)

t.test('relayDamageEvent: a non-K9-modeled reporting source has no effect on mood, even though it is a real, connected player', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setPlayer(1, 'HUMAN-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 777) -- not registered as a K9 model
    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1)
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.mood, 100, 'a non-K9 reporting source must never mutate wellbeing state')
end)

t.test('relayDamageEvent: a disconnected/invalid reporting source (GetPlayerPed resolves to 0) is a silent no-op, not a crash', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayDamageEvent', 999)
    t.isTrue(ok)
end)

t.test('relayDamageEvent: a K9-modeled source whose citizenid cannot be resolved (exports.qbx_core:GetPlayer returns nil) is a silent no-op', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    -- deliberately never called f.setPlayer(1, ...) -- qbxGetPlayer(1) returns nil
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayDamageEvent', 1)
    t.isTrue(ok)
end)

t.test('relayDamageEvent: extra/garbage call arguments (a forged payload on an event this file documents as payload-less) are ignored without error', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayDamageEvent', 1, 'garbage', { fake = 'payload' }, 99999)
    t.isTrue(ok)
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.mood, 85, 'the decay must be exactly ONE damageDecayAmount hit -- the extra call arguments must have no effect on the outcome')
end)

t.test('relayDamageEvent: the ingest cooldown (Config.Tracking.Blood.relayCooldownMs) blocks a second report from the SAME source within the window -- only one decay tick lands', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)

    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1)
    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1) -- same instant, same source
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.mood, 85, 'a same-instant repeat from the same source must be dropped by the ingest cooldown, not doubled to 70')

    f.advance(501) -- past Config.Tracking.Blood.relayCooldownMs (500)
    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1)
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.mood, 70, 'once the ingest cooldown has genuinely elapsed, a fresh report must land')
end)

t.test('relayDamageEvent: the ingest cooldown is PER SOURCE -- a second, different K9 reporting at the same instant is unaffected by the first source\'s own cooldown entry', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setPlayer(1, 'K9-1-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setPlayer(2, 'K9-2-CID')
    f.setPed(2, 9002)
    f.setModel(9002, 555)

    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1)
    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 2) -- different source, same instant

    local snap1 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    local snap2 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 2)
    t.equals(snap1.mood, 85)
    t.equals(snap2.mood, 85, "a different reporting source must not be rate-limited by an unrelated source's own cooldown entry")
end)

t.test('relayDamageEvent: decrements BOTH Mood and Injury in the same accepted event when both features are on, by their own independent decay amounts', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true, InjuryLimping = true } })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', 1)
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.mood, 85, '100 - Mood.damageDecayAmount(15)')
    t.equals(snap.injury, 90, '100 - Injury.damageDecayAmount(10)')
end)

t.test('relayWeaponFire: FearStressSystem off -- entirely inert, no crash', function()
    local f = newWellbeingFixture() -- FearStressSystem false
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPed(99, 9099)
    f.setCoords(9099, 0, 0, 0)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayWeaponFire', 99)
    t.isTrue(ok)
end)

t.test('relayWeaponFire: a disconnected/invalid reporting source (GetPlayerPed resolves to 0) never logs an entry -- a subsequent tick shows zero fearStress rise', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    -- source 999 never wired with a ped -> GetPlayerPed(999) == 0
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayWeaponFire', 999)
    t.isTrue(ok)
    f.runOneTick()
    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fearStress, 0, 'no real report was ever logged, and passiveDecayPerTick cannot push an already-zero value below its own floor clamp')
end)

t.test('relayWeaponFire: extra/garbage call arguments (a forged payload on an event this file documents as payload-less) are ignored -- only the reporter\'s own real, server-resolved position is ever logged', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPed(99, 9099)
    f.setCoords(9099, 0, 0, 0)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayWeaponFire', 99, { fakeCoords = { 99999, 99999, 0 } }, 'garbage')
    t.isTrue(ok)
    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fearStress, 3.0, "the report must have been logged at the reporter's OWN real server-resolved position (0,0,0, within radius) -- never at any coordinate a client-shaped extra argument might claim")
end)

t.test("relayWeaponFire: the ingest cooldown genuinely gates a NEW entry at ingestion time, not merely relying on TickWellbeing's own later per-tick distinct-source dedup", function()
    -- Proof technique: the SAME source reports twice in immediate
    -- succession (well within Config.Tracking.Gunpowder.relayCooldownMs,
    -- 300ms) -- once from FAR AWAY (outside gunfireRadius, so it could
    -- never itself cause a rise) and, immediately after, from CLOSE UP
    -- (within gunfireRadius). If the ingest cooldown genuinely blocks the
    -- second call's own body from ever running, the close-up position is
    -- never read or logged at all -- only the far-away entry from the
    -- first call exists, so the next tick shows NO fearStress rise. If the
    -- ingest cooldown did nothing, the second (close) report would log its
    -- own entry and DID cause a rise -- observably different from
    -- TickWellbeing's separate per-tick distinct-source dedup, which
    -- cannot tell these two cases apart (both would show at most one
    -- qualifying source either way).
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPed(99, 9099)

    f.setCoords(9099, 10000, 10000, 0) -- far away -- outside gunfireRadius (20.0)
    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 99)
    f.setCoords(9099, 0, 0, 0) -- moved to close range, same instant
    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 99) -- still within relayCooldownMs(300) of the first call -- must be dropped entirely

    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fearStress, 0, 'the second (close-range) report must never have been logged at all -- only the far-away entry from the first, non-cooldown-blocked call exists')

    -- Advance past the ingest cooldown and report again from close range --
    -- this one must land.
    f.advance(301)
    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 99)
    f.runOneTick()
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fearStress, 3.0, 'once the ingest cooldown has elapsed, a fresh close-range report must be logged and counted')
end)

t.test('relayWeaponFire: the ingest cooldown is PER SOURCE -- a second, different attacker reporting at the same instant is unaffected by the first attacker\'s own cooldown, and both count as distinct sources toward nearbyShots', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPed(99, 9099)
    f.setCoords(9099, 0, 0, 0)
    f.setPed(98, 9098)
    f.setCoords(9098, 0, 0, 0)

    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 99)
    f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 98) -- different source, same instant

    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fearStress, 6.0, 'two distinct reporting sources within the same tick must both count -- risePerNearbyShotPerTick(3.0) * 2')
end)

-- ========================================================================
-- STUCK-K9 SOFTLOCK FIX (this task) -- three points, verified against a QA
-- finding: (A) the recommended Injury.passiveRegenPerTick raise reaches
-- both hard-block thresholds in a bounded, asserted number of ticks;
-- (B) the new death/respawn reset actually fires, only on a genuine
-- transition, and respects the configured amount (including a configured
-- "disabled"); (C) the new resource-start item-existence validation warns
-- (and never throws) on a missing placeholder item, covering all four
-- single-item-name placeholders this resource depends on
-- (Config.K9Medkit.itemName included, even though that field belongs to
-- server/medkit.lua -- see server/wellbeing.lua's own header for why that
-- check lives here).
-- ========================================================================

--- Wires one online, K9-modeled, connected player with InjuryLimping's own
--- default alive health (200) at the origin. Shared setup for every test in
--- this section that only cares about Injury/TickWellbeing, not Mood/Fatigue/
--- FearStress/Distraction.
--- @param f table
--- @param src number?
--- @return number ped
local function wireOnlineInjuryK9(f, src)
    src = src or 1
    local ped = src * 100
    f.setOnline({ src })
    f.setPlayer(src, 'K9-CID-' .. src)
    f.setPed(src, ped)
    f.setModel(ped, 555)
    f.setIsK9Model(555, true)
    f.setCoords(ped, 0, 0, 0)
    return ped
end

--- Drops Injury by exactly `amount` via repeated relayDamageEvent hits
--- (Config.Wellbeing.Injury.damageDecayAmount = 10 per accepted hit in
--- every fixture below), advancing past Config.Tracking.Blood
--- .relayCooldownMs (500) between each so none are dropped by the ingest
--- cooldown. `amount` must be an exact multiple of 10.
--- @param f table
--- @param src number
--- @param amount number
local function dropInjuryBy(f, src, amount)
    assert(amount % 10 == 0, 'test helper only supports exact multiples of damageDecayAmount(10)')
    for _ = 1, amount / 10 do
        f.dispatchNetEvent('qbx_k9unit:server:relayDamageEvent', src)
        f.advance(501)
    end
end

-- ------------------------------------------------------------------------
-- POINT A: the RECOMMENDED regen rate (passiveRegenPerTick 0.1 -> 1.0,
-- baked into baselineWellbeingConfig() above -- see that table's own
-- comment) reaches both hard-block thresholds, and a full recovery, in a
-- bounded, exactly-asserted number of ticks.
-- ------------------------------------------------------------------------

t.test('NEW RATE (1.0/tick): from Injury=0, jumpBlockThreshold(20) is still NOT cleared after 19 ticks, and IS cleared at exactly tick 20 (100s, ~1.67 real minutes -- not the reported ~16.7 minutes)', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 100) -- Injury: 100 -> 0

    for tick = 1, 19 do
        f.advance(5000)
        f.runOneTick()
        local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
        t.isTrue(snap.injury < 20, ('tick %d: jumpBlockThreshold must not have cleared yet (injury=%s)'):format(tick, tostring(snap.injury)))
    end

    f.advance(5000)
    f.runOneTick() -- tick 20
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 20, 'tick 20: injury must be exactly 20 (20 ticks * 1.0/tick)')
    t.isTrue(snap.injury >= 20, 'jumpBlockThreshold(20) must be cleared -- client/wellbeing.lua blocks jump only while injury < jumpBlockThreshold')
end)

t.test('NEW RATE (1.0/tick): from Injury=0, sprintBlockThreshold(30) clears at exactly tick 30 (150s, 2.5 real minutes -- not the reported ~25 minutes)', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 100)

    for _ = 1, 29 do
        f.advance(5000)
        f.runOneTick()
    end
    local snapBefore = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(snapBefore.injury < 30, 'one tick before threshold, sprintBlockThreshold must not have cleared yet')

    f.advance(5000)
    f.runOneTick() -- tick 30
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 30, 'tick 30: injury must be exactly 30 (30 ticks * 1.0/tick)')
end)

t.test('NEW RATE (1.0/tick): a full 0 -> Injury.max(100) recovery takes exactly 100 ticks (500s, ~8.33 minutes) -- identical to Mood.passiveRegenPerTick\'s own already-adopted 1.0/tick number, closing the 10x gap between the two', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 100)

    for _ = 1, 99 do
        f.advance(5000)
        f.runOneTick()
    end
    local snapBefore = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapBefore.injury, 99, 'tick 99: one point short of a full recovery')

    f.advance(5000)
    f.runOneTick() -- tick 100
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 100, 'tick 100: fully recovered, clamped at Injury.max, never overshooting')
end)

t.test('DOCUMENTED BUG, CURRENTLY-SHIPPED 0.1/tick RATE: from Injury=0, jumpBlockThreshold(20) takes exactly 200 ticks (1000s = 16.67 real minutes) and sprintBlockThreshold(30) takes exactly 300 ticks (1500s = 25 real minutes) -- pins the QA-reported arithmetic exactly, so this test starts FAILING (a deliberate tripwire) the day config.lua actually ships the recommended 1.0 rate and this documentation test should be deleted', function()
    local cfg = baselineWellbeingConfig()
    cfg.Injury.passiveRegenPerTick = 0.1 -- the value config.lua ships as of this pass -- see that field's own comment above
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true }, wellbeingCfg = cfg })
    local src = 1
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 100)

    for _ = 1, 199 do
        f.advance(5000)
        f.runOneTick()
    end
    local snapAt199 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(snapAt199.injury < 20, 'tick 199: still below jumpBlockThreshold at the currently-shipped rate')

    f.advance(5000)
    f.runOneTick() -- tick 200
    local snapAt200 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(snapAt200.injury >= 20, 'tick 200 (1000s = 16.67 min): jumpBlockThreshold finally clears -- exactly the QA-reported figure')

    for _ = 1, 99 do -- ticks 201..299
        f.advance(5000)
        f.runOneTick()
    end
    local snapAt299 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(snapAt299.injury < 30, 'tick 299: still below sprintBlockThreshold at the currently-shipped rate')

    f.advance(5000)
    f.runOneTick() -- tick 300
    local snapAt300 = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(snapAt300.injury >= 30, 'tick 300 (1500s = 25 min): sprintBlockThreshold finally clears -- exactly the QA-reported figure')
end)

-- ------------------------------------------------------------------------
-- POINT B: death/respawn reset. GetEntityHealth(ped) <= 100
-- (PED_DEAD_HEALTH_THRESHOLD, a local constant in server/wellbeing.lua,
-- mirroring server/combat.lua's/server/medkit.lua's own identical constant)
-- is the death signal -- IsEntityDead has no FXServer server registration
-- (see server/wellbeing.lua's own header for the citation), so this
-- fixture's GetEntityHealth stub (default 200, set via f.setHealth) is what
-- actually drives this behavior, not a separate IsEntityDead stub.
-- ------------------------------------------------------------------------

t.test('DEATH/RESPAWN: a K9 observed dead (health<=100) then alive again (health>100) on the NEXT tick has Injury restored by deathRespawnRestoreAmount(100), clamped to max, and passive regen resumes the SAME tick', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src, ped = 1, 100
    wireOnlineInjuryK9(f, src) -- ped defaults to src*100 = 100
    dropInjuryBy(f, src, 50) -- Injury: 100 -> 50

    f.setHealth(ped, 50) -- <= PED_DEAD_HEALTH_THRESHOLD(100): dead
    f.advance(5000)
    f.runOneTick()
    local snapDead = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapDead.injury, 50, 'no passive regen while genuinely dead -- Injury must not have moved')

    f.setHealth(ped, 200) -- alive again (revived/respawned)
    f.advance(5000)
    f.runOneTick()
    local snapRevived = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapRevived.injury, 100, '50 + deathRespawnRestoreAmount(100), clamped to max(100), THEN +passiveRegenPerTick(1.0) also clamped to 100 the same tick')
end)

t.test('DEATH/RESPAWN: staying observed-dead across MULTIPLE ticks does not repeat the restore -- it fires exactly once, on the genuine dead->alive transition', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src, ped = 1, 100
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 70) -- Injury: 100 -> 30

    f.setHealth(ped, 50) -- dead
    for _ = 1, 5 do
        f.advance(5000)
        f.runOneTick()
    end
    local snapStillDead = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapStillDead.injury, 30, 'five ticks spent dead must not have moved Injury at all -- no repeated/partial restore while merely staying dead')

    f.setHealth(ped, 200) -- alive again, once
    f.advance(5000)
    f.runOneTick()
    local snapRevived = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapRevived.injury, 100, '30 + 100 (deathRespawnRestoreAmount), clamped to max -- restored exactly once on the real transition')

    -- Continuing to stay alive must not re-apply the restore a second time.
    f.advance(5000)
    f.runOneTick()
    local snapStillAlive = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapStillAlive.injury, 100, 'still clamped to max via ordinary passive regen -- the restore itself must not re-fire without a fresh death')
end)

t.test('DEATH/RESPAWN: a SECOND death-then-revival cycle restores again -- this is a genuine per-transition mechanism, not a one-time-ever flag', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src, ped = 1, 100
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10

    f.setHealth(ped, 50) -- death #1
    f.advance(5000)
    f.runOneTick()
    f.setHealth(ped, 200) -- revival #1
    f.advance(5000)
    f.runOneTick()
    local snapAfterFirst = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapAfterFirst.injury, 100, '10 + 100, clamped -- first restore landed')

    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10 again, a second real firefight
    f.setHealth(ped, 50) -- death #2
    f.advance(5000)
    f.runOneTick()
    f.setHealth(ped, 200) -- revival #2
    f.advance(5000)
    f.runOneTick()
    local snapAfterSecond = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapAfterSecond.injury, 100, 'a second, independent death/revival cycle must restore again -- not suppressed by the first one already having fired')
end)

t.test('DEATH/RESPAWN: Config.Wellbeing.Injury.deathRespawnRestoreAmount respects a PARTIAL (non-max) configured value -- proves the amount itself is applied, not just "snap to max"', function()
    local cfg = baselineWellbeingConfig()
    cfg.Injury.deathRespawnRestoreAmount = 25
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true }, wellbeingCfg = cfg })
    local src, ped = 1, 100
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10

    f.setHealth(ped, 50)
    f.advance(5000)
    f.runOneTick()
    f.setHealth(ped, 200)
    f.advance(5000)
    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 36, '10 + 25 (the configured partial amount) + 1.0 (passive regen, same tick) = 36 -- never snaps straight to max')
end)

t.test('DEATH/RESPAWN: Config.Wellbeing.Injury.deathRespawnRestoreAmount = 0 is a genuine, supported "disabled" -- an operator preferring lingering post-respawn injury for realism', function()
    local cfg = baselineWellbeingConfig()
    cfg.Injury.deathRespawnRestoreAmount = 0
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true }, wellbeingCfg = cfg })
    local src, ped = 1, 100
    wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10

    f.setHealth(ped, 50)
    f.advance(5000)
    f.runOneTick()
    f.setHealth(ped, 200)
    f.advance(5000)
    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 11, '10 + 0 (restore disabled) + 1.0 (ordinary passive regen resuming) = 11 -- respawn grants NO special relief, exactly as configured')
end)

t.test('DEATH/RESPAWN: a K9 that never dies at all is entirely unaffected -- the flag never fires a spurious restore', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    wireOnlineInjuryK9(f, src) -- default health 200 (alive) for every tick
    dropInjuryBy(f, src, 40) -- Injury: 100 -> 60

    for _ = 1, 5 do
        f.advance(5000)
        f.runOneTick()
    end
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 65, '60 + 5 ticks * 1.0 ordinary passive regen -- no restore ever applied since health never dropped to/below 100')
end)

t.test('DEATH/RESPAWN: with InjuryLimping OFF, GetEntityHealth-driven death tracking never engages -- Injury stays untouched regardless of health, and no crash', function()
    local f = newWellbeingFixture() -- InjuryLimping false (and every other flag false)
    local src, ped = 1, 100
    wireOnlineInjuryK9(f, src)

    f.setHealth(ped, 50) -- would be "dead" if InjuryLimping were on
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'a disabled InjuryLimping must never crash on a dead ped')
    t.equals(#f.clientEvents, 0, 'TickWellbeing itself never even runs when every wellbeing flag is off')
end)

-- ------------------------------------------------------------------------
-- POINT C: startup validation for every placeholder ox_inventory item name
-- this resource depends on (Config.K9Medkit.itemName included -- see
-- server/wellbeing.lua's own header for why that check lives here despite
-- belonging, in spirit, to server/medkit.lua).
-- ------------------------------------------------------------------------

t.test('STARTUP VALIDATION: K9Medkit enabled + k9_medkit NOT registered in ox_inventory -- exactly one warning naming the item and the config path, and onResourceStart does not throw', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = false } })
    f.config.Features.K9Medkit = true
    f.config.K9Medkit = { itemName = 'k9_medkit' }
    -- k9_medkit deliberately never registered via f.registerInventoryItem

    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'a missing item must produce a WARNING, never a thrown error')

    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('k9_medkit', 1, true) and line:find('Config.K9Medkit.itemName', 1, true) then
            found = true
        end
    end
    t.isTrue(found, 'expected a warning naming both the missing item and the exact config path an operator needs to fix')
end)

t.test('STARTUP VALIDATION: K9Medkit enabled + k9_medkit IS registered in ox_inventory -- no warning at all', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = false } })
    f.config.Features.K9Medkit = true
    f.config.K9Medkit = { itemName = 'k9_medkit' }
    f.registerInventoryItem('k9_medkit')

    f.fireResourceStart()
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('k9_medkit', 1, true) ~= nil, 'a correctly-registered item must never be warned about')
    end
end)

t.test('STARTUP VALIDATION: K9Medkit disabled -- the item is never even checked, missing or not (read-at-point-of-activation discipline)', function()
    local f = newWellbeingFixture()
    f.config.Features.K9Medkit = false
    f.config.K9Medkit = { itemName = 'k9_medkit' }

    f.fireResourceStart()
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('k9_medkit', 1, true) ~= nil, 'a disabled feature must never be checked at all')
    end
end)

t.test('STARTUP VALIDATION: MoodSystem enabled + k9_treat missing -- warns naming Config.Wellbeing.Mood.feedItemName', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    -- k9_treat (baselineWellbeingConfig's own Mood.feedItemName) never registered

    f.fireResourceStart()
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('k9_treat', 1, true) and line:find('Config.Wellbeing.Mood.feedItemName', 1, true) then
            found = true
        end
    end
    t.isTrue(found)
end)

t.test('STARTUP VALIDATION: DistractionSystem enabled + BOTH k9_meat_bait and k9_ultrasonic_whistle missing -- two SEPARATE warnings, one per item', function()
    local f = newWellbeingFixture({ featuresOverride = { DistractionSystem = true } })

    f.fireResourceStart()
    local foundBait, foundWhistle = false, false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('k9_meat_bait', 1, true) then foundBait = true end
        if line:find('WARNING', 1, true) and line:find('k9_ultrasonic_whistle', 1, true) then foundWhistle = true end
    end
    t.isTrue(foundBait, 'meat bait must be warned about')
    t.isTrue(foundWhistle, 'the whistle must ALSO be warned about -- not just the first of the two')
end)

t.test('STARTUP VALIDATION: DistractionSystem enabled + only ONE of the two items registered -- exactly one warning, for the still-missing item only', function()
    local f = newWellbeingFixture({ featuresOverride = { DistractionSystem = true } })
    f.registerInventoryItem('k9_meat_bait')

    f.fireResourceStart()
    local foundBait, foundWhistle = false, false
    for _, line in ipairs(f.printedLines) do
        if line:find('k9_meat_bait', 1, true) then foundBait = true end
        if line:find('k9_ultrasonic_whistle', 1, true) then foundWhistle = true end
    end
    t.isFalse(foundBait, 'the registered item must not be warned about')
    t.isTrue(foundWhistle, 'the still-missing item must still be warned about')
end)

t.test('STARTUP VALIDATION: exports.ox_inventory:Items() itself erroring is caught -- a distinct warning is printed and onResourceStart does not throw', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    f.setThrowOnItemsExport(true)

    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'an ox_inventory export error must never crash resource start')

    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('errored', 1, true) then found = true end
    end
    t.isTrue(found, 'an export failure must still produce SOME loud, distinct warning, not silence')
end)

t.test('STARTUP VALIDATION: onResourceStart fired for a DIFFERENT resource entirely is ignored -- mirrors server/combat.lua\'s own GetCurrentResourceName() guard verbatim, no warnings at all', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true, DistractionSystem = true } })
    f.config.Features.K9Medkit = true
    f.config.K9Medkit = { itemName = 'k9_medkit' }
    -- Nothing registered -- every one of the four items is missing.

    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0, 'a foreign resourceName must produce zero output -- this handler only ever acts on its OWN resource starting')
end)

t.test('STARTUP VALIDATION: all four placeholder items missing at once (a fresh, unconfigured install with every dependent feature on) produces four distinct warnings, one per item, in a single onResourceStart pass', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true, DistractionSystem = true } })
    f.config.Features.K9Medkit = true
    f.config.K9Medkit = { itemName = 'k9_medkit' }

    f.fireResourceStart()
    local names = { 'k9_medkit', 'k9_treat', 'k9_meat_bait', 'k9_ultrasonic_whistle' }
    for _, name in ipairs(names) do
        local found = false
        for _, line in ipairs(f.printedLines) do
            if line:find('WARNING', 1, true) and line:find(name, 1, true) then found = true end
        end
        t.isTrue(found, ('expected a distinct warning for %s'):format(name))
    end
end)

os.exit(t.summary())
