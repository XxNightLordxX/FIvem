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
        -- HUNGER/THIRST (this pass, coder-backend) -- shipped defaults, same
        -- arithmetic as this task's own report: decayPerTick tuned so a
        -- full-to-empty drain takes ~90 minutes (Hunger) / ~60 minutes
        -- (Thirst) at tickIntervalMs=5000 if never fed/watered.
        Hunger = {
            max                    = 100,
            decayPerTick           = 0.093,
            lowThreshold           = 30,
            speedPenaltyMultiplier = 0.95,
            feedItemName           = 'k9_food',
            feedRegenAmount        = 35,
            feedCooldownMs         = 120000,
        },
        Thirst = {
            max                    = 100,
            decayPerTick           = 0.139,
            lowThreshold           = 30,
            speedPenaltyMultiplier = 0.95,
            drinkItemName          = 'k9_water',
            drinkRegenAmount       = 35,
            drinkCooldownMs        = 90000,
            -- Shipped default is {'water_bowl'} -- emptied here by default,
            -- same "not exercised unless a test opts in" convention this
            -- file's own header already establishes for Fatigue.restSources;
            -- the dedicated drinkFromBowl tests further down override this
            -- per-fixture via wellbeingCfg.
            bowlSources            = {},
            bowlRegenAmount        = 15,
            bowlCooldownMs         = 60000,
            bowlInteractRange      = 2.0,
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
        HungerThirstSystem = false,
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
        local line = table.concat(parts, '\t')
        -- COMPAT-LAYER MIGRATION (this pass): shared/compat/core.lua's own
        -- onResourceStart handler (loaded below, since server/wellbeing.lua
        -- now routes GetItemCount/RemoveItem through K9Compat) fires on
        -- every fireResourceStart('qbx_k9unit') call and prints its OWN
        -- diagnostic-command line every time regardless of config (see
        -- equipmentshop_spec.lua's identical comment for the full "every
        -- branch of that handler prints something" writeup) -- filtered
        -- here since every assertion in this suite is about
        -- server/wellbeing.lua's own warning surface, several of which
        -- assert EXACTLY ZERO lines for a disabled feature.
        if line:find('[qbx_k9unit] K9Compat:', 1, true) then return end
        printedLines[#printedLines + 1] = line
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

    -- HANDLER CONDITION BADGE (this pass) -- exports.qbx_core:GetPlayerByCitizenId(citizenid),
    -- the reverse-direction lookup server/wellbeing.lua's own
    -- ResolveOnlineSourceForCitizenid needs. Derived from the SAME
    -- `citizenidBySource` table setPlayer/clearPlayer already maintain
    -- (mirrors tests/defense_spec.lua's/tests/recall_spec.lua's own
    -- identical fixture pattern for this exact export) -- never a second,
    -- independently-maintained table that could drift out of sync with it.
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        for src, cid in pairs(citizenidBySource) do
            if cid == citizenid then return { PlayerData = { citizenid = cid, source = src } } end
        end
        return nil
    end

    -- HANDLER CONDITION BADGE (this pass) -- server/partnership.lua's real
    -- GetActivePartnerCitizenId accessor, stubbed. ABSENT from `env` by
    -- default (mirrors tests/recall_spec.lua's/tests/defense_spec.lua's own
    -- "server/partnership.lua module absent" soft-dependency convention) --
    -- every PRE-EXISTING test in this file never wires this fixture up at
    -- all, so `type(GetActivePartnerCitizenId) == 'function'` stays false
    -- for every one of them, exactly reproducing today's real "no
    -- partnership module loaded" behavior with zero risk of an accidental
    -- behavior change. Only tests that explicitly call setPartner(...) (or
    -- setActivePartnerResolver(...) directly) below ever populate this.
    local partnerByCitizenid = {} -- citizenid -> { partner = citizenid, isK9 = bool }
    local function getActivePartnerCitizenIdStub(citizenid)
        local entry = partnerByCitizenid[citizenid]
        if not entry then return nil, nil end
        return entry.partner, entry.isK9
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

    -- SECURITY FIX FOLLOW-UP (coder-architect, adversarial-pass finding,
    -- this pass): ResolveK9Ped now ALSO requires HasK9Access(source), not
    -- just a matching model -- see that function's own doc comment in
    -- server/wellbeing.lua for the full writeup. Defaults every source to
    -- `true` so every PRE-EXISTING test in this file (none of which were
    -- ever testing an access-denial scenario -- that is squarely this
    -- fixture's own owner's territory to add, not invented here) keeps
    -- behaving exactly as it did before this stub existed. `setHasK9Access`
    -- exposed below for a future test that wants to exercise the new gate
    -- directly.
    local hasK9AccessBySource = {}
    local defaultHasK9Access = true
    local function HasK9Access(source)
        local v = hasK9AccessBySource[source]
        if v == nil then return defaultHasK9Access end
        return v
    end

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

    -- GetSelectedPedWeapon: server/wellbeing.lua's relayWeaponFire handler
    -- requires the reporter to actually be holding a weapon before it will
    -- log nearby gunfire -- a red-team finding, since that event carries no
    -- payload and was otherwise reportable by anyone who could send it.
    -- GetHashKey above is identity, so a weapon "hash" here is just its
    -- name string. Defaults to armed, because every pre-existing test in
    -- this file was written when any reporter was accepted and is about
    -- something else entirely; the unarmed case gets its own explicit
    -- tests. Set weaponBySource[src] = 'WEAPON_UNARMED' (or 0) to make a
    -- specific reporter unarmed.
    local weaponBySource = {}
    local function GetSelectedPedWeapon(ped)
        for src, p in pairs(pedBySource) do
            if p == ped then return weaponBySource[src] or 'WEAPON_PISTOL' end
        end
        return 'WEAPON_PISTOL'
    end

    -- HUNGER/THIRST -- drinkFromBowl's own netId -> entity resolution goes
    -- through the REAL, unmodified server/entities.lua's ResolveNetworkEntity
    -- (loaded below), which itself calls these three raw natives. Keyed by
    -- a plain opaque netId/entity number this fixture controls entirely via
    -- setNetworkEntity below -- no relationship to pedBySource/coordsByPed's
    -- own numbering, exactly like every other entity-handle table in this
    -- fixture.
    local entityByNetId = {}
    local existingEntities = {}
    local entityTypeByEntity = {}
    local function NetworkGetEntityFromNetworkId(netId) return entityByNetId[netId] or 0 end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityType(entity) return entityTypeByEntity[entity] or 0 end

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
        -- COMPAT-LAYER MIGRATION (coder-backend, this pass): pins the
        -- 'inventory' system straight to 'ox_inventory' via `override`
        -- (shared/compat/core.lua's TIER 1, skipping the candidate-scanning
        -- walk). The other four systems get empty-but-present tables so
        -- DetectSystem's own "missing or malformed" warning never fires.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
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
        -- COMPAT-LAYER MIGRATION (this pass): server/wellbeing.lua's
        -- GetItemCount/RemoveItem calls (Mood petK9/feedK9, Distraction
        -- meatBait/whistle) are now routed through `K9Compat.Get('inventory')`
        -- -- shared/compat/inventory.lua's BuildOxInventoryServer requires
        -- ALL SEVEN server-realm methods present as callable exports before
        -- it returns ANYTHING. `Items` stays a direct, un-routed
        -- `exports.ox_inventory:Items` call (see server/wellbeing.lua's own
        -- COMPAT-LAYER FINDING comment -- no server-realm ItemExists exists
        -- in the contract). GetInventoryItems/GetContainerFromSlot/
        -- RegisterStash/RegisterShop/registerHook (never called by
        -- server/wellbeing.lua at all) are harmless no-ops purely so
        -- capability verification passes.
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer, GetPlayerByCitizenId = qbxGetPlayerByCitizenId },
            ox_inventory = {
                GetItemCount = oxGetItemCount,
                RemoveItem = oxRemoveItem,
                Items = oxItems,
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        GetPlayers           = GetPlayers,
        GetPlayerPed         = GetPlayerPed,
        GetEntityModel       = GetEntityModel,
        IsConfiguredK9Model  = IsConfiguredK9Model,
        HasK9Access          = HasK9Access,
        GetEntityCoords      = GetEntityCoords,
        GetEntityHealth      = GetEntityHealth,
        GetAllObjects        = GetAllObjects,
        GetAllVehicles       = GetAllVehicles,
        GetHashKey           = GetHashKey,
        GetSelectedPedWeapon = GetSelectedPedWeapon,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist      = DoesEntityExist,
        GetEntityType        = GetEntityType,
        GetCurrentResourceName = GetCurrentResourceName,
        Config               = config,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
        -- always reports 'started' (this file never tests an
        -- undetected-inventory scenario -- covered by shared/compat/
        -- inventory.lua's own dedicated spec and this task's own per-file
        -- stub-degrade writeup in server/wellbeing.lua's header).
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- COMPAT-LAYER MIGRATION (this pass): load the REAL, unmodified
    -- shared/compat/core.lua + shared/compat/inventory.lua before the file
    -- under test (never a hand-written fake translation layer).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/wellbeing.lua', env)

    -- HANDLER CONDITION BADGE (this pass) -- env.GetActivePartnerCitizenId
    -- is only ever assigned when a test opts in via setPartner/
    -- setActivePartnerResolver below (never at fixture-construction time),
    -- so every PRE-EXISTING test in this file -- none of which ever calls
    -- either -- keeps observing `type(GetActivePartnerCitizenId) ==
    -- 'function'` as false, exactly reproducing "server/partnership.lua
    -- not loaded" with zero behavior change. Safe to assign AFTER
    -- Sandbox.loadInto above: server/wellbeing.lua's own functions resolve
    -- this name fresh, by upvalue into `env`, at CALL time (inside
    -- TickWellbeing, always reached later via threadRunner.step()), never
    -- at this file's own load time.
    local function setPartner(k9Citizenid, handlerCitizenid)
        partnerByCitizenid[k9Citizenid] = { partner = handlerCitizenid, isK9 = true }
        partnerByCitizenid[handlerCitizenid] = { partner = k9Citizenid, isK9 = false }
        env.GetActivePartnerCitizenId = getActivePartnerCitizenIdStub
    end
    local function clearPartner(citizenid)
        local entry = partnerByCitizenid[citizenid]
        if entry then
            partnerByCitizenid[entry.partner] = nil
        end
        partnerByCitizenid[citizenid] = nil
    end

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
        -- Makes a reporting source unarmed (or arms them with a specific
        -- weapon). server/wellbeing.lua's relayWeaponFire ignores an
        -- unarmed reporter -- see the GetSelectedPedWeapon stub above.
        setWeapon = function(src, weapon) weaponBySource[src] = weapon end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setHasK9Access = function(source, v) hasK9AccessBySource[source] = v end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        -- HUNGER/THIRST -- registers a fake world object entity behind a
        -- netId, for drinkFromBowl's own ResolveNetworkEntity(netId, 3) call.
        -- `entityType` defaults to 3 (object), matching a real bowl prop;
        -- pass 1/2 to exercise ResolveNetworkEntity's own ped/vehicle
        -- type-mismatch reject. Model/coords for `entity` are set the
        -- ordinary way (setModel/setCoords above), since GetEntityModel/
        -- GetEntityCoords read the exact same generic tables regardless of
        -- whether the handle is a ped or a plain object.
        setNetworkEntity = function(netId, entity, entityType)
            entityByNetId[netId] = entity
            existingEntities[entity] = true
            entityTypeByEntity[entity] = entityType or 3
        end,
        removeNetworkEntity = function(netId)
            local entity = entityByNetId[netId]
            entityByNetId[netId] = nil
            if entity then existingEntities[entity] = nil end
        end,
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
        -- HANDLER CONDITION BADGE (this pass) helpers --------------------
        setPartner = setPartner,
        clearPartner = clearPartner,
        -- Simulates server/partnership.lua never having loaded at all,
        -- even after a prior setPartner() call in the SAME test -- see
        -- PushHandlerConditionUpdate's own soft-dependency guard.
        setNoPartnershipModule = function() env.GetActivePartnerCitizenId = nil end,
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

t.test('server/wellbeing.lua registers exactly its six documented server net events (UPDATED this pass: three Hunger/Thirst additions -- feedK9Hunger/giveK9Water/drinkFromBowl -- alongside the original three)', function()
    local f = newWellbeingFixture()
    local count = 0
    for _ in pairs(f.registeredNetEvents) do count = count + 1 end
    t.equals(count, 6)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:relayDamageEvent'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:relayWeaponFire'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:calmDownK9'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:feedK9Hunger'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:giveK9Water'] ~= nil)
    t.isTrue(f.registeredNetEvents['qbx_k9unit:server:drinkFromBowl'] ~= nil)
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

t.test("RESOLVED: the shared TickWellbeing thread now starts unconditionally at file load, even when every one of the six wellbeing feature flags is false -- exactly four threads always exist now, and idling over an all-off Config.Features costs nothing observable", function()
    -- INVERTED ON PURPOSE (this pass, coder-backend). This test used to be
    -- titled "DISCREPANCY: ..." and asserted exactly ONE CreateThread call
    -- with every flag off, pinning server/wellbeing.lua's OWN then-true
    -- header claim ("this file starts NO thread at all if all five flags
    -- are false") as a real, deliberately-tested invariant -- but that
    -- invariant was also a real, confirmed live-toggle-ON bug: a server
    -- booting with all five wellbeing flags off and later flipping ONE on
    -- live from the tablet (every one of them is `tier = 'live'` in
    -- server/runtimecontrol.lua's own FEATURE_TIERS) had nothing polling to
    -- ever start ticking that stat or pushing a single wellbeingUpdate,
    -- until this resource restarted -- an already-connected client's stat
    -- snapshot going stale with NO upper bound, not merely one tick
    -- interval. That gap is fixed now (see server/wellbeing.lua's
    -- CreateThread call and its own resolution comment for the full
    -- writeup, and the LIVE-FLIP FIX test immediately below for the real
    -- regression coverage) -- the tick thread starts unconditionally and
    -- re-checks all five flags fresh every tick. A test that kept asserting
    -- "exactly one CreateThread call with everything off" would now be
    -- asserting the BUG's own premise, not this file's real behavior --
    -- inverted here on purpose, mirroring tests/combat_spec.lua's own
    -- corrected "with every combat feature flag off..." test and
    -- tests/runtimefeaturetiers_spec.lua's "RESOLVED PARTIAL LIVENESS" test
    -- for the identical shape. Re-reverting this back to asserting ONE
    -- thread would need server/wellbeing.lua's own fix undone first, and
    -- would reopen the exact unbounded-staleness gap the LIVE-FLIP FIX test
    -- below exists to prove closed.
    local f = newWellbeingFixture() -- all features false
    -- UPDATED THIS PASS (coder-backend, Hunger/Thirst): the count moved from
    -- 2 to 4. Named exhaustively, so nobody has to re-derive this later:
    -- (1) DistractionCooldown's own always-on sweep (pre-existing),
    -- (2) the now-unconditional TickWellbeing loop (pre-existing),
    -- (3) HungerFeedCooldown's own always-on sweep (NEW, this pass -- keyed
    --     by citizenid, exactly DistractionCooldown's own shape, so it needs
    --     the identical always-on :StartSweep cleanup strategy),
    -- (4) ThirstReliefCooldown's own always-on sweep (NEW, this pass --
    --     shared between giveK9Water and drinkFromBowl, same reasoning).
    -- Both new sweeps run unconditionally regardless of HungerThirstSystem's
    -- own flag, same as DistractionCooldown's sweep already does regardless
    -- of DistractionSystem -- see server/wellbeing.lua's own HungerFeedCooldown/
    -- ThirstReliefCooldown declarations for why an empty store costs nothing
    -- observable while the feature is off.
    t.equals(f.createThreadCallCount(), 4, "four CreateThread calls happen at file-load time even with every feature off -- DistractionCooldown/HungerFeedCooldown/ThirstReliefCooldown's own always-on sweeps, AND the now-unconditional TickWellbeing loop")
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, "the now-unconditional tick thread must idle cleanly with every flag off, no error")
    t.equals(#f.clientEvents, 0, "no wellbeingUpdate is ever pushed while every flag is off, even though the thread is now genuinely running")
end)

t.test('With any one wellbeing feature on, exactly four threads are created: the (now-unconditional) TickWellbeing loop, plus the three always-on cooldown sweeps (DistractionCooldown, HungerFeedCooldown, ThirstReliefCooldown)', function()
    local f = newWellbeingFixture({ featuresOverride = { MoodSystem = true } })
    t.equals(f.createThreadCallCount(), 4)
end)

-- ========================================================================
-- CONFIRMED LIVE-FLIP BUG, FIXED (this pass, coder-backend): the shared
-- TickWellbeing thread -- the ONLY place any wellbeing stat is ever
-- ticked/decayed/regenerated or pushed to a client -- used to only ever
-- start if one of FatigueSystem/MoodSystem/FearStressSystem/
-- DistractionSystem/InjuryLimping was ALREADY true at this file's own load
-- time. server/runtimecontrol.lua's FEATURE_TIERS registers all five as
-- `tier = 'live'` (ApplyFeatureOverride mutates Config.Features.*
-- immediately, no restart), so an operator could boot with all five off,
-- flip ONE on live from the tablet, and get a fully live petK9/feedK9/
-- applyK9Distraction/calmDownK9/relayDamageEvent/relayWeaponFire (each
-- re-checks its own flag fresh) writing real WellbeingStats mutations, with
-- the one thread that would ever tick/push any of it never having started
-- -- an already-connected client's stat snapshot stuck stale forever, not
-- merely one tick interval. This is the exact property this section proves
-- now holds: a flag flipped on live is picked up by the already-running
-- thread within one tick, regardless of what the flags were when this file
-- loaded.
-- ========================================================================

t.test('LIVE-FLIP FIX: flipping MoodSystem on LIVE (booted with every wellbeing flag off) is picked up by the already-running tick thread within one tick -- no restart of this resource required', function()
    local f = newWellbeingFixture() -- all features false at boot
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick() -- primes, then executes pass 1 -- every flag off at boot
    t.equals(#f.clientEvents, 0, 'still nothing while every flag is off at boot')

    -- High command flips MoodSystem on LIVE, mid-session -- exactly the
    -- scenario server/runtimecontrol.lua's own FEATURE_TIERS entry for this
    -- flag documents (`tier = 'live'`, `restartRequired = false`).
    f.config.Features.MoodSystem = true

    -- THE ACTUAL BUG, pre-fix: the tick thread never started (it was never
    -- true that any of the five flags were on when this file loaded in this
    -- fixture), so nothing would ever have picked this up, for the rest of
    -- this server's uptime. Prove the opposite now holds -- the SAME thread
    -- that has been idling over an all-off Config.Features since load time
    -- reads the flag fresh on its very next tick.
    f.runOneTick()
    t.equals(#f.clientEvents, 1, 'a live flag flip must be picked up by the already-running thread on its next tick -- no restart required')
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

t.test('playerDropped resets the TRANSIENT, ped-instance-scoped observations (lastCoords here; injuryDeathEpisodeStartedAt is proved separately in the DEATH/RESPAWN section below) -- a disconnect-and-reconnect-elsewhere must not manufacture a bogus sprint-fatigue hit', function()
    -- RETITLED (this task, regression follow-up): this test's ORIGINAL title
    -- claimed playerDropped resets "ONLY lastCoords". That was true when
    -- written and stopped being true the moment this file's death/respawn
    -- reset field (originally a plain boolean, `injuryDiedWhileTracked`,
    -- later redesigned into the timestamp `injuryDeathEpisodeStartedAt`)
    -- shipped WITHOUT the same reset -- a regression pass caught, live
    -- against this resource, that a K9 could disconnect while dead and
    -- reconnect to a fresh, genuinely-alive ped, which the stale value then
    -- misread as a real revival and paid a free deathRespawnRestoreAmount
    -- for. server/wellbeing.lua's own WellbeingStats struct comment now
    -- names the real distinction this test's old title glossed over: TWO
    -- different categories of field live in that table (persisted
    -- fatigue/mood/fearStress/injury + timestamp fields, vs. TRANSIENT
    -- ped-instance-scoped observations like lastCoords AND
    -- injuryDeathEpisodeStartedAt), and playerDropped resets every field in
    -- the SECOND category, not just this one. This test still only
    -- exercises the lastCoords/Fatigue half directly (that's what it was
    -- built to prove, and duplicating the injuryDeathEpisodeStartedAt proof
    -- here would just be a worse-fixtured copy of the dedicated regression
    -- test below) -- but its TITLE must never again claim "ONLY lastCoords",
    -- so the next editor does not read this test passing as license to
    -- "fix" a future transient field's own missing reset back out.
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

t.test('relayWeaponFire: an UNARMED reporter is ignored entirely -- the payload-less griefing path that could switch off a K9\'s bite/takedown/drag on demand', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    f.setOnline({ 1, 2 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    -- The attacker: standing right next to the K9, carrying nothing.
    f.setPlayer(2, 'GRIEFER-CID')
    f.setPed(2, 9002)
    f.setCoords(9002, 1, 0, 0)
    f.setWeapon(2, 'WEAPON_UNARMED')

    -- Spam it. Every one of these must be discarded before it is logged.
    for _ = 1, 40 do
        f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 2)
        f.runOneTick()
    end

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fearStress, 0, 'an unarmed reporter can never raise a nearby K9 fearStress at all, however many times they fire the event')
end)

t.test('relayWeaponFire: an ARMED reporter at the same spot IS counted -- proving the unarmed rejection is the weapon check and not the fixture failing to reach the handler', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    f.setOnline({ 1, 2 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPlayer(2, 'SHOOTER-CID')
    f.setPed(2, 9002)
    f.setCoords(9002, 1, 0, 0)
    f.setWeapon(2, 'WEAPON_PISTOL')

    for _ = 1, 40 do
        f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 2)
        f.runOneTick()
    end

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.isTrue(snap.fearStress > 0, 'a genuinely armed reporter at the identical position still raises fearStress -- the unarmed case above is rejected by the weapon check specifically, not by the fixture never reaching the handler')
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
-- is the death SAMPLE -- IsEntityDead has no FXServer server registration
-- (see server/wellbeing.lua's own header for the citation), so this
-- fixture's GetEntityHealth stub (default 200, set via f.setHealth) is what
-- actually drives this behavior, not a separate IsEntityDead stub.
--
-- THIS IS A HEURISTIC, NOT AN EVENT -- read server/wellbeing.lua's own
-- header (STUCK-K9 SOFTLOCK FIX item 2) before "simplifying" any of this
-- section's arithmetic. A single observed health crossing of the threshold
-- is NOT sufficient to qualify for a restore (a red-team pass found this
-- paid out on an ORDINARY COMBAT HEAL, not just a genuine death) -- a
-- candidate episode (a continuous stretch observed at/below the threshold)
-- must span at least MIN_DEATH_EPISODE_DURATION_MS
-- (`math.max(Config.Wellbeing.tickIntervalMs * 3, 60000)`, a LOCAL constant
-- in server/wellbeing.lua) between the tick it starts and the tick it ends
-- before it qualifies. At this fixture's own shipped tickIntervalMs(5000),
-- that evaluates to 60000ms -- exactly 12 tick intervals.
-- ------------------------------------------------------------------------

--- Advances fixture time by exactly one tickIntervalMs (5000ms, this
--- fixture's own shipped default) and runs one TickWellbeing pass, `n`
--- times in a row, without touching health -- used to hold a ped
--- continuously observed in whatever state it is currently set to across a
--- controlled number of samples.
--- @param f table
--- @param n integer
local function advanceTicks(f, n)
    for _ = 1, n do
        f.advance(5000)
        f.runOneTick()
    end
end

-- MIN_DEATH_EPISODE_DURATION_MS = math.max(tickIntervalMs * 3, 60000) --
-- at this fixture's own shipped tickIntervalMs (5000), the 60000 floor
-- dominates: math.max(15000, 60000) = 60000. In ticks: a candidate episode
-- must span at least 12 tick intervals (12 * 5000 = 60000) between the
-- tick it is FIRST observed dead and the tick it is next observed alive
-- for a restore to qualify.
local QUALIFYING_DEAD_TICKS = 12    -- 12 * 5000 = 60000ms -- exactly the boundary
local DISQUALIFYING_DEAD_TICKS = 11 -- 11 * 5000 = 55000ms -- one tick short

--- Sets `ped`'s health to 50 (dead) and runs `deadTicks` consecutive
--- TickWellbeing passes while it stays dead (the candidate episode's start
--- timestamp is recorded on the FIRST of these and never moves), then sets
--- it back to 200 (alive) and runs ONE MORE tick to observe the ending
--- transition. The episode's measured span AT that final tick is exactly
--- `deadTicks * 5000` ms.
--- @param f table
--- @param ped number
--- @param deadTicks integer
local function dieForTicksThenRevive(f, ped, deadTicks)
    f.setHealth(ped, 50)
    advanceTicks(f, deadTicks)
    f.setHealth(ped, 200)
    advanceTicks(f, 1)
end

t.test('MIN_DEATH_EPISODE_DURATION_MS BOUNDARY: an episode spanning EXACTLY the qualifying duration (12 ticks * 5000ms = 60000ms) restores Injury by deathRespawnRestoreAmount, clamped to max, with ordinary passive regen resuming the SAME tick', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 50) -- Injury: 100 -> 50

    f.setHealth(ped, 50) -- dead
    advanceTicks(f, QUALIFYING_DEAD_TICKS) -- 12 ticks continuously dead
    local snapStillDead = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapStillDead.injury, 50, 'no passive regen across any of the 12 dead ticks -- Injury must not have moved')

    f.setHealth(ped, 200) -- alive again
    advanceTicks(f, 1) -- 13th tick: elapsed since episode start = 12 * 5000 = 60000ms, exactly at the boundary
    local snapRevived = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapRevived.injury, 100, '50 + deathRespawnRestoreAmount(100), clamped to max(100), THEN +passiveRegenPerTick(1.0) also clamped to 100 the same tick -- the boundary itself (>=) must count as qualifying')
end)

t.test('MIN_DEATH_EPISODE_DURATION_MS BOUNDARY: an episode spanning ONE TICK SHORT of the qualifying duration (11 ticks * 5000ms = 55000ms) does NOT restore -- only ordinary passive regen applies once alive again', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 50) -- Injury: 100 -> 50

    f.setHealth(ped, 50)
    advanceTicks(f, DISQUALIFYING_DEAD_TICKS) -- 11 ticks dead
    f.setHealth(ped, 200)
    advanceTicks(f, 1) -- elapsed = 11 * 5000 = 55000, below the 60000 boundary
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 51, '50 + ordinary passiveRegenPerTick(1.0) ONLY -- 55000ms falls short of MIN_DEATH_EPISODE_DURATION_MS(60000), so no restore fires')
end)

t.test('RED-TEAM FIX (FOLLOW-UP FIX #2): an ORDINARY COMBAT DIP -- health grazed to 90 (a real wound, not a death) and healed back above 100 within a single tick interval -- must NOT trigger a restore. This is the exact exploit a red-team pass found: the naive crossing-based version paid a full deathRespawnRestoreAmount for the price of an ordinary bandage', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 10) -- Injury: 100 -> 90, a real hit taken -- this is what makes the K9's real health dip in the first place

    f.setHealth(ped, 90) -- grazed to 90 -- at/below PED_DEAD_HEALTH_THRESHOLD(100), but a live, active combat participant, not dead in any gameplay sense
    f.advance(5000)
    f.runOneTick() -- injuryDeathEpisodeStartedAt is set, candidate episode begins
    local snapGrazed = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapGrazed.injury, 90, 'no passive regen this one tick while sampled at/below the threshold -- unchanged so far')

    f.setHealth(ped, 150) -- an ordinary heal (bandage/food/armor/vanilla regen) -- no revive, no ambulance, no death of any kind
    f.advance(5000)
    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 91, '90 + ordinary passiveRegenPerTick(1.0) ONLY. Before FOLLOW-UP FIX #2 this would have read 100 (90 + deathRespawnRestoreAmount(100), clamped) -- a full, free Injury reset for one ordinary bandage, cheaper than K9Medkit itself (injuryRestore = 40) and repeatable roughly every tick interval')
end)

t.test('OSCILLATION: health flickering above/below the threshold several times during one real laststand, with each individual dip too short to qualify on its own, never collects a restore -- each candidate episode is judged independently, never summed', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 40) -- Injury: 100 -> 60

    -- Three short dips, each well under the 60000ms floor, separated by
    -- brief alive ticks -- simulates health flickering near the threshold
    -- rather than one clean continuous down.
    for _ = 1, 3 do
        f.setHealth(ped, 90) -- dip
        f.advance(5000)
        f.runOneTick()
        f.setHealth(ped, 150) -- brief recovery
        f.advance(5000)
        f.runOneTick()
    end

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    -- 3 dip ticks: no passive regen. 3 recovery ticks: +1.0 each.
    t.equals(snap.injury, 63, '60 + 3 * passiveRegenPerTick(1.0) (the three brief "alive" ticks) -- no restore ever qualified, since each individual dip (one tick, 5000ms) never reached MIN_DEATH_EPISODE_DURATION_MS(60000) on its own')
end)

t.test('DEATH/RESPAWN: staying observed-dead well past the qualifying duration does not repeat the restore -- it fires exactly once, on the genuine episode-ending transition', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 70) -- Injury: 100 -> 30

    f.setHealth(ped, 50)
    advanceTicks(f, 20) -- 20 dead ticks (100000ms), well past the 60000ms floor -- still just ONE continuous episode
    local snapStillDead = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapStillDead.injury, 30, 'no passive regen across any dead tick, however long the episode runs -- Injury must not have moved')

    f.setHealth(ped, 200) -- alive again, once
    f.advance(5000)
    f.runOneTick()
    local snapRevived = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapRevived.injury, 100, '30 + 100 (deathRespawnRestoreAmount), clamped to max -- restored exactly once on the real transition, regardless of how long the qualifying episode ran')

    -- Continuing to stay alive must not re-apply the restore a second time.
    f.advance(5000)
    f.runOneTick()
    local snapStillAlive = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapStillAlive.injury, 100, 'still clamped to max via ordinary passive regen -- the restore itself must not re-fire without a fresh qualifying episode')
end)

t.test('DEATH/RESPAWN: a SECOND qualifying death-then-revival cycle restores again -- this is a genuine per-episode mechanism, not a one-time-ever flag', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10

    dieForTicksThenRevive(f, ped, 15) -- comfortably past the 60000ms floor
    local snapAfterFirst = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapAfterFirst.injury, 100, '10 + 100, clamped, +1.0 passive regen (already at max) -- first restore landed')

    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10 again, a second real firefight
    dieForTicksThenRevive(f, ped, 15) -- a second, independent qualifying episode
    local snapAfterSecond = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapAfterSecond.injury, 100, 'a second, independent qualifying episode must restore again -- not suppressed by the first one already having fired')
end)

t.test('DEATH/RESPAWN: Config.Wellbeing.Injury.deathRespawnRestoreAmount respects a PARTIAL (non-max) configured value -- proves the amount itself is applied, not just "snap to max"', function()
    local cfg = baselineWellbeingConfig()
    cfg.Injury.deathRespawnRestoreAmount = 25
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true }, wellbeingCfg = cfg })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10

    dieForTicksThenRevive(f, ped, 15)
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 36, '10 + 25 (the configured partial amount) + 1.0 (passive regen, same tick) = 36 -- never snaps straight to max')
end)

t.test('DEATH/RESPAWN: Config.Wellbeing.Injury.deathRespawnRestoreAmount = 0 is a genuine, supported "disabled" -- an operator preferring lingering post-respawn injury for realism', function()
    local cfg = baselineWellbeingConfig()
    cfg.Injury.deathRespawnRestoreAmount = 0
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true }, wellbeingCfg = cfg })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 90) -- Injury: 100 -> 10

    dieForTicksThenRevive(f, ped, 15)
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 11, '10 + 0 (restore disabled) + 1.0 (ordinary passive regen resuming) = 11 -- respawn grants NO special relief, exactly as configured, even for a genuinely qualifying long episode')
end)

t.test('DEATH/RESPAWN: a K9 that never dies at all is entirely unaffected -- no candidate episode is ever started, so no restore ever fires', function()
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
-- REGRESSION (found empirically against the live resource, fixed this
-- pass, FOLLOW-UP FIX #1): injuryDeathEpisodeStartedAt (originally a plain
-- boolean, `injuryDiedWhileTracked`, before FOLLOW-UP FIX #2 redesigned it
-- into a timestamp) is a TRANSIENT, ped-instance-scoped observation ("was
-- THIS ped last seen dead, and since when"), not a persisted value -- but
-- it shipped living in the same table this file's own header documents as
-- deliberately surviving a disconnect, and was NOT reset by either of the
-- two places that already reset lastCoords (the model-switch-away branch
-- inside TickWellbeing, and playerDropped). That let a K9 disconnect WHILE
-- DEAD and reconnect to a fresh, always-alive ped -- misread by the very
-- next tick as a genuine revival, paying a full deathRespawnRestoreAmount
-- for free, no revive/ambulance/medkit/delay required, repeatably. See
-- server/wellbeing.lua's own header, STUCK-K9 SOFTLOCK FIX item 2's
-- FOLLOW-UP FIX #1 note, and the WellbeingStats struct comment's
-- category-1-vs-2 split, for the full writeup this section's two tests
-- below prove against. Both tests below use a deliberately LONG
-- (10-minute) real-world gap while offline/non-K9-modeled, specifically
-- because a longer gap makes the bug WORSE, not better, under the
-- duration-gated design FOLLOW-UP FIX #2 introduced -- an un-reset
-- timestamp read against a much-later `now` looks even MORE like a
-- genuine long down episode, so the fix must make the gap's length
-- irrelevant entirely, not merely short enough to accidentally miss the
-- boundary.
-- ------------------------------------------------------------------------

t.test('DEATH/RESPAWN REGRESSION (FIXED): a K9 that dies, DISCONNECTS while still dead (no revive of any kind), and reconnects to a fresh always-alive ped must NOT receive a free restore, no matter how long the real-world gap -- playerDropped must clear the stale injuryDeathEpisodeStartedAt timestamp, not just lastCoords', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local oldPed = wireOnlineInjuryK9(f, src) -- ped 100, default health 200 (alive)
    dropInjuryBy(f, src, 10) -- Injury: 100 -> 90 (a real hit taken)

    f.setHealth(oldPed, 50) -- dead
    f.advance(5000)
    f.runOneTick() -- injuryDeathEpisodeStartedAt is set to this tick's timestamp
    local snapDead = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapDead.injury, 90, 'still dead, no transition observed yet -- Injury unchanged')

    -- DISCONNECT while still dead. No revive/ambulance/medkit flow of any
    -- kind ever runs in this sequence.
    f.setOnline({})
    f.firePlayerDropped(src)

    -- A LONG real-world gap passes while offline (10 real minutes) -- long
    -- enough that, WITHOUT the fix, the stale timestamp would trivially
    -- exceed MIN_DEATH_EPISODE_DURATION_MS(60000) and read as an obviously
    -- "genuine" long down episode.
    f.advance(600000)

    -- RECONNECT to a genuinely fresh ped handle (a real reconnect always
    -- gets one) -- its default health (this fixture's own alive default,
    -- 200) is exactly what a fresh spawn's real native health would be.
    local newPed = 101
    f.setPed(src, newPed)
    f.setModel(newPed, 555)
    f.setCoords(newPed, 0, 0, 0)
    f.setOnline({ src })

    f.advance(5000)
    f.runOneTick()
    local snapReconnected = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapReconnected.injury, 91, '90 + ordinary passive regen(1.0) ONLY. THE FIX: playerDropped clearing the stale timestamp means this always-alive fresh ped starts with NO candidate episode at all, regardless of how long the real-world gap was. Before FOLLOW-UP FIX #1 this would have read 100 (90 + deathRespawnRestoreAmount(100), clamped) -- and the 10-minute gap here would have made it look EVEN MORE like a genuine down episode, not less')
end)

t.test('DEATH/RESPAWN REGRESSION (FIXED): the SAME stale-timestamp bug via the OTHER reset site -- a K9 that dies, switches to a non-K9 model while STILL CONNECTED and dead, is revived by unrelated means while non-K9-modeled for a long real stretch, then switches back to a K9 model must NOT receive a free restore', function()
    local f = newWellbeingFixture({ featuresOverride = { InjuryLimping = true } })
    local src = 1
    local ped = wireOnlineInjuryK9(f, src)
    dropInjuryBy(f, src, 20) -- Injury: 100 -> 80

    f.setHealth(ped, 50) -- dead
    f.advance(5000)
    f.runOneTick() -- injuryDeathEpisodeStartedAt is set
    local snapDead = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snapDead.injury, 80, 'still dead -- unchanged')

    -- Switches away from the K9 model while STILL CONNECTED and still dead
    -- -- the `elseif ped ~= 0` branch inside TickWellbeing, not a
    -- disconnect. This branch already resets lastCoords for the identical
    -- "stale ped-instance-scoped observation" reason; it must now ALSO
    -- reset injuryDeathEpisodeStartedAt.
    f.setModel(ped, 777) -- no longer a configured K9 model
    f.setIsK9Model(777, false)
    f.advance(5000)
    f.runOneTick()

    -- Revived by some entirely unrelated means (this resource's own real
    -- laststand/EMS flow, outside this file's concern) WHILE non-K9-modeled,
    -- and stays non-K9-modeled for a long real stretch (10 minutes) before
    -- ever switching back.
    f.setHealth(ped, 200)
    f.advance(600000)

    -- Switches back to a K9 model, already alive.
    f.setModel(ped, 555)
    f.setIsK9Model(555, true)
    f.advance(5000)
    f.runOneTick()

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.injury, 81, '80 + ordinary passive regen(1.0) ONLY -- the model-switch-away branch must have cleared the stale timestamp too, so switching back to a K9 model while already alive (after any real stretch of time) is never misread as a qualifying episode this file actually observed')
end)

t.test('AUDIT (this task\'s own item c -- checking the WHOLE struct, not just injuryDeathEpisodeStartedAt): the ABSOLUTE-TIMESTAMP fields (hesitatingUntil) are correctly LEFT ALONE by playerDropped -- GetGameTimer() keeps advancing while a player is offline, so a stored future timestamp is still a meaningful comparison after reconnect, which is why this field does NOT belong in the same "must reset on disconnect" category as injuryDeathEpisodeStartedAt', function()
    local f = newWellbeingFixture({ featuresOverride = { FearStressSystem = true } })
    local src = 1
    f.setOnline({ src })
    f.setPlayer(src, 'K9-CID')
    f.setPed(src, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.setPed(99, 9099)
    f.setCoords(9099, 0, 0, 0)

    -- Same derivation as this file's own HESITATION_MAX_CONTINUOUS_MS test:
    -- risePerNearbyShotPerTick(3.0) first reaches hesitationThreshold(85) at
    -- tick 29 (29*3=87), arming hesitatingUntil = now(145000) +
    -- hesitationDurationMs(8000) = 153000.
    for _ = 1, 29 do
        f.dispatchNetEvent('qbx_k9unit:server:relayWeaponFire', 99)
        f.advance(5000)
        f.runOneTick()
    end
    t.isTrue(f.isHesitating('K9-CID'), 'sanity: hesitation must be active before disconnecting')

    -- Disconnect WHILE hesitating.
    f.setOnline({})
    f.firePlayerDropped(src)

    -- A short reconnect gap, still well inside the armed window -- must
    -- STILL read as hesitating: the timestamp was correctly left alone.
    f.advance(2000) -- now = 147000, hesitatingUntil(153000) still in the future
    t.isTrue(f.isHesitating('K9-CID'), 'hesitatingUntil must survive the disconnect completely untouched -- this is CORRECT, unlike injuryDeathEpisodeStartedAt')

    -- Enough real server uptime elapses (while the player was offline) for
    -- the SAME absolute timestamp to genuinely lapse on its own -- proving
    -- this is a real, live clock comparison across a disconnect, never a
    -- stale value frozen at disconnect-time.
    f.advance(10000) -- now = 157000, past hesitatingUntil(153000)
    t.isFalse(f.isHesitating('K9-CID'), 'hesitatingUntil must lapse on its own real-world schedule regardless of connection state -- exactly why this field needs NO playerDropped reset at all')
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

-- ========================================================================
-- STAMINA DURATION TUNABLE (owner directive, this pass: "make sure high
-- command can edit the ability to make stamina last longer or even
-- permanently"). Config.Wellbeing.Fatigue.sprintDecayPerTick is now exposed
-- via server/runtimecontrol.lua's TUNABLE_REGISTRY (min = 0, max = 20.0--
-- see that entry's own comment for the full "why 0, why no client push"
-- writeup). This section proves the GAMEPLAY claim that registration alone
-- cannot: that a live edit genuinely changes how long a sprinting K9's
-- fatigue lasts, that 0 specifically means EXACTLY permanent (not merely a
-- very slow drain), and that a live edit back to a finite value takes
-- effect on the very next tick with no restart -- all driven through the
-- exact same `Config.Wellbeing.Fatigue.sprintDecayPerTick` field
-- server/runtimecontrol.lua's ApplyTunableOverride mutates in production
-- (SetConfigByPath writes into this SAME table object; mutating
-- f.config.Wellbeing.Fatigue.sprintDecayPerTick directly below is
-- byte-for-byte what that call does).
-- ========================================================================

--- Moves the given ped `distanceMeters` further along +X than its current
--- fixture coords and returns the new coords, so a caller can drive several
--- consecutive "sprinting" ticks without hand-computing absolute positions
--- each time. `distanceMeters` must exceed sprintSpeedThreshold(4.0) *
--- dtSeconds(TICK_INTERVAL_MS/1000 = 5) = 20.0 meters for TickWellbeing to
--- classify the tick as sprinting -- 30 meters (6 m/s) is used throughout
--- this section, comfortably over that line.
--- @param f table fixture returned by newWellbeingFixture
--- @param ped number
--- @param fromX number
--- @param distanceMeters number
--- @return number newX
local function sprintTick(f, ped, fromX, distanceMeters)
    local newX = fromX + distanceMeters
    f.setCoords(ped, newX, 0, 0)
    f.runOneTick()
    return newX
end

t.test('SnapshotOf pushes nativeStaminaRestorePercent to the client, read fresh, alongside the other six wellbeingTunables fields -- this is the field client/wellbeing.lua actually calls RestorePlayerStamina with', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.config.Wellbeing.Fatigue.nativeStaminaRestorePercent = 0.75
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.wellbeingTunables.fatigueNativeStaminaRestorePercent, 0.75)

    -- Read fresh, not captured once -- a live tablet edit reaches the very
    -- next snapshot with no restart, same as every sibling field in this
    -- table.
    f.config.Wellbeing.Fatigue.nativeStaminaRestorePercent = 0
    snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.wellbeingTunables.fatigueNativeStaminaRestorePercent, 0)
end)

t.test('PERMANENT STAMINA: sprintDecayPerTick = 0 (the tablet\'s "permanent" setting) means fatigue never drops below its starting value, even across many ticks of continuous sustained sprinting', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.sprintDecayPerTick = 0
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick() -- first sample: no prior lastCoords yet
    local x = 0
    for _ = 1, 50 do
        x = sprintTick(f, 9001, x, 30) -- 30m/tick = 6 m/s, comfortably over the 4.0 m/s sprint threshold
    end

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 100, 'fatigue must still be at max after 50 straight ticks of sustained sprinting -- not merely high, EXACTLY unchanged, proving this is a real zero-decay no-op rather than a very slow drain that would eventually cross the threshold')
end)

t.test('PROPORTIONALITY: halving sprintDecayPerTick exactly halves the fatigue lost over the same number of sustained-sprint ticks -- "last longer" is a real, graduated dial, not just an on/off switch', function()
    local defaultCfg = baselineWellbeingConfig() -- sprintDecayPerTick = 2.0, the shipped default
    local fDefault = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = defaultCfg })
    fDefault.setOnline({ 1 }); fDefault.setPlayer(1, 'K9-CID'); fDefault.setPed(1, 9001)
    fDefault.setModel(9001, 555); fDefault.setIsK9Model(555, true); fDefault.setCoords(9001, 0, 0, 0)
    fDefault.runOneTick()
    local xd = 0
    for _ = 1, 10 do xd = sprintTick(fDefault, 9001, xd, 30) end
    local snapDefault = fDefault.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snapDefault.fatigue, 80, 'sanity: shipped default (2.0/tick) loses 20 fatigue over 10 sprinting ticks')

    local halvedCfg = baselineWellbeingConfig()
    halvedCfg.Fatigue.sprintDecayPerTick = 1.0 -- a live "lasts longer" tablet edit -- half the shipped rate
    local fHalved = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = halvedCfg })
    fHalved.setOnline({ 1 }); fHalved.setPlayer(1, 'K9-CID'); fHalved.setPed(1, 9001)
    fHalved.setModel(9001, 555); fHalved.setIsK9Model(555, true); fHalved.setCoords(9001, 0, 0, 0)
    fHalved.runOneTick()
    local xh = 0
    for _ = 1, 10 do xh = sprintTick(fHalved, 9001, xh, 30) end
    local snapHalved = fHalved.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snapHalved.fatigue, 90, 'halving the decay rate must exactly halve the fatigue lost over the identical 10-tick sprint (10 lost, not 20) -- a genuinely proportional "lasts longer", not a step change')
end)

t.test('LIVE CHANGE TAKES EFFECT: a tablet edit from permanent (0) back to a finite decay rate resumes real decay on the very next tick, mid-session, with no restart -- the "gate the start, never strand the stop" rule applies in reverse here too: raising the drain back up must actually reach an already-running K9', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.sprintDecayPerTick = 0 -- starts "permanent"
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick()
    local x = 0
    for _ = 1, 5 do x = sprintTick(f, 9001, x, 30) end
    local snapBefore = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snapBefore.fatigue, 100, 'sanity: still permanent after 5 sprinting ticks')

    -- Mutates the SAME Config.Wellbeing.Fatigue table server/runtimecontrol.lua's
    -- ApplyTunableOverride/SetConfigByPath writes into in production -- this
    -- IS what a live 'qbx_k9unit:server:runtimeSetTunable' call does to this
    -- exact field.
    f.config.Wellbeing.Fatigue.sprintDecayPerTick = 2.0

    sprintTick(f, 9001, x, 30)
    local snapAfter = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snapAfter.fatigue, 98, 'decay must resume IMMEDIATELY on the very next tick after the live edit -- TickWellbeing reads Config.Wellbeing.Fatigue.sprintDecayPerTick fresh every pass, never a value captured once at file-load time')
end)

t.test('NO NEGATIVE/WRAPPED FATIGUE: even at the tunable\'s own maximum (20.0/tick), repeated sustained sprinting clamps at 0 and never goes negative', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.sprintDecayPerTick = 20.0 -- the registry's own declared max
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick()
    local x = 0
    for i = 1, 8 do
        x = sprintTick(f, 9001, x, 30)
        local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
        t.isTrue(snap.fatigue >= 0, ('fatigue must never go negative (tick %d): got %s'):format(i, tostring(snap.fatigue)))
    end
    local final = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(final.fatigue, 0, 'after enough ticks at the maximum decay rate, fatigue settles at exactly 0, clamped -- never negative')
end)

-- ========================================================================
-- PER-CITIZENID STAMINA OVERRIDE WIRING (this pass, coder-backend, Part B
-- of the owner's "keep the speed and stamina editing where i can edit it
-- to as high as i want" request). server/k9profiles.lua's
-- GetK9EffectiveMultipliers is an accessor nothing calls unless it is
-- actually wired somewhere real -- these tests prove TickWellbeing's own
-- Fatigue sprint-decay branch genuinely consults it (soft-guarded,
-- pcall-wrapped, exactly the idiom server/tracking.lua's own
-- ResolveMaxRangeForCitizenId already established for the sibling
-- scent-range field), not merely that the accessor exists in isolation.
-- ========================================================================

t.test('STAMINA OVERRIDE WIRING: when GetK9EffectiveMultipliers is available and returns a per-citizenid sprintDecayPerTick, TickWellbeing uses THAT value, not the raw Config.Wellbeing.Fatigue.sprintDecayPerTick global', function()
    local cfg = baselineWellbeingConfig() -- Fatigue.sprintDecayPerTick = 2.0 (the global default)
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    -- Simulates a high-command individual override of 0.5/tick for this
    -- exact citizenid -- a real server/k9profiles.lua would resolve this
    -- from its own OverrideByCitizenId/StaminaOverrideByCitizenId tables;
    -- this fixture never loads that file, so it stubs the ONE seam
    -- TickWellbeing actually calls, exactly like tests/tracking_spec.lua's
    -- own fixture stubs GetK9EffectiveMultipliers for the sibling
    -- scent-range wiring.
    local calls = {}
    f.env.GetK9EffectiveMultipliers = function(citizenid)
        calls[#calls + 1] = citizenid
        return { sprintDecayPerTick = 0.5 }
    end

    f.runOneTick()
    local x = 0
    for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 95, '10 sprinting ticks at an OVERRIDDEN 0.5/tick must lose exactly 5 fatigue, not 20 (the raw global 2.0/tick would have produced)')
    t.isTrue(#calls > 0, 'GetK9EffectiveMultipliers must actually have been called, not merely be available and unused')
    t.equals(calls[1], 'K9-CID', 'must be called with THIS citizenid, never a different one or a raw source id')
end)

t.test('STAMINA OVERRIDE WIRING: sprintDecayPerTick = 0 from the override is a genuine "permanent stamina" no-op, exactly like the global-default 0 case above', function()
    local cfg = baselineWellbeingConfig() -- Fatigue.sprintDecayPerTick = 2.0 (the global default, deliberately NON-zero here)
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.env.GetK9EffectiveMultipliers = function() return { sprintDecayPerTick = 0 } end

    f.runOneTick()
    local x = 0
    for _ = 1, 50 do x = sprintTick(f, 9001, x, 30) end

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 100, 'an OVERRIDDEN 0/tick must behave exactly like the global-default 0 case: fatigue never drops, even after 50 sustained-sprint ticks, even though the raw Config default here is a non-zero 2.0')
end)

t.test('STAMINA OVERRIDE WIRING: GetK9EffectiveMultipliers ABSENT (an install predating server/k9profiles.lua) falls back to the raw Config.Wellbeing.Fatigue.sprintDecayPerTick global -- exactly today\'s behavior, unaffected', function()
    local cfg = baselineWellbeingConfig()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    -- Deliberately never setting f.env.GetK9EffectiveMultipliers -- this
    -- fixture's own Sandbox.newEnv seeds every global from the REAL _G,
    -- which has no such function either, so `type(GetK9EffectiveMultipliers)
    -- == 'function'` is false here, exactly modelling an install that
    -- predates that file.
    t.isNil(f.env.GetK9EffectiveMultipliers)
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick()
    local x = 0
    for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 80, 'must fall back to the raw global (2.0/tick * 10 ticks = 20 lost), exactly matching this section\'s own earlier "shipped default" sanity check')
end)

t.test('STAMINA OVERRIDE WIRING: a THROWING GetK9EffectiveMultipliers is caught (pcall) and falls back to the raw Config global -- never crashes TickWellbeing for every other online K9', function()
    local cfg = baselineWellbeingConfig()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.env.GetK9EffectiveMultipliers = function() error('simulated failure in server/k9profiles.lua') end

    f.runOneTick()
    local x = 0
    local ok = pcall(function()
        for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end
    end)
    t.isTrue(ok, 'a throwing GetK9EffectiveMultipliers must never crash TickWellbeing itself')
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 80, 'must fall back to the raw global exactly as if the function were absent')
end)

t.test('STAMINA OVERRIDE WIRING: a malformed return value (not a table, or a non-number sprintDecayPerTick) is ignored -- falls back to the raw Config global, never a crash or a nonsense subtraction', function()
    local cfg = baselineWellbeingConfig()
    for _, badReturn in ipairs({ nil, false, 'not a table', {}, { sprintDecayPerTick = 'not a number' }, { sprintDecayPerTick = false } }) do
        local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
        f.setOnline({ 1 })
        f.setPlayer(1, 'K9-CID')
        f.setPed(1, 9001)
        f.setModel(9001, 555)
        f.setIsK9Model(555, true)
        f.setCoords(9001, 0, 0, 0)

        f.env.GetK9EffectiveMultipliers = function() return badReturn end

        f.runOneTick()
        local x = 0
        local ok = pcall(function()
            for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end
        end)
        t.isTrue(ok, ('must never crash for a malformed return value: %s'):format(tostring(badReturn)))
        local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', 1)
        t.equals(snap.fatigue, 80, ('must fall back to the raw global for a malformed return value: %s'):format(tostring(badReturn)))
    end
end)

-- ========================================================================
-- HUNGER/THIRST (this pass, coder-backend). Config.Features.HungerThirstSystem.
-- See server/wellbeing.lua's header "HUNGER/THIRST" section for the full
-- design writeup this section proves.
-- ========================================================================

t.test('EVERY tracker in server/wellbeing.lua has a cleanup strategy -- source-keyed ones register a playerDropped hook, citizenid-keyed ones sweep, and none has neither', function()
    -- Same "read the file's own text, not a runtime accessor" technique
    -- tests/mainserver_spec.lua/tests/combat_spec.lua/tests/recall_spec.lua/
    -- tests/partnership_spec.lua already established for the identical
    -- invariant in their own files -- extended to server/wellbeing.lua for
    -- the first time this pass, specifically because this task added THREE
    -- new NewCooldown()/NewNestedCooldown() declarations
    -- (HungerFeedCooldown/ThirstReliefCooldown; AffectionCooldown already
    -- existed) and the task's own instructions call out this exact defect
    -- class by name. A tracker with NEITHER strategy leaks for the whole
    -- uptime of the server.
    local handle = assert(io.open('../server/wellbeing.lua', 'r'))
    local text = handle:read('*a')
    handle:close()

    local declared = {}
    for name in text:gmatch('local%s+([%w_]+)%s*=%s*New[CN]') do
        declared[#declared + 1] = name
    end
    t.isTrue(#declared >= 5,
        ('sanity: only found %d tracker declaration(s) in server/wellbeing.lua -- the pattern has probably drifted; fix it rather than lowering this floor'):format(#declared))

    for _, name in ipairs(declared) do
        local hasPlayerDropped = text:find(name .. '.RegisterPlayerDropped(', 1, true) ~= nil
        local hasSweep = text:find(name .. '.StartSweep(', 1, true) ~= nil
        t.isTrue(hasPlayerDropped or hasSweep,
            name .. ' has neither .RegisterPlayerDropped() nor .StartSweep() -- whatever it is keyed by, its table grows for the whole uptime of the server with nothing to bound it')
    end
end)

--- Wires a single online, K9-modeled, HungerThirstSystem-eligible player.
--- @param f table
--- @param opts table?
--- @return number src, number ped
local function wireHungerThirstK9(f, opts)
    opts = opts or {}
    local src = opts.src or 1
    local ped = opts.ped or 9001
    f.setPlayer(src, opts.citizenid or 'K9-CID')
    f.setOnline({ src })
    f.setPed(src, ped)
    f.setModel(ped, 555)
    f.setIsK9Model(555, true)
    f.setCoords(ped, 0, 0, 0)
    return src, ped
end

-- ------------------------------------------------------------------------
-- PASSIVE DECAY
-- ------------------------------------------------------------------------

t.test('HungerThirstSystem off: TickWellbeing never touches hunger/thirst -- both stay at their default max forever', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = false } })
    local src = wireHungerThirstK9(f)
    f.runOneTick()
    f.advance(5000)
    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    -- getWellbeingSnapshot itself returns nil when EVERY flag is off (this
    -- file's own established contract) -- confirm that first, then re-fetch
    -- with a sibling flag on so EnsureStats' own hunger/thirst DEFAULT (not
    -- yet touched by any tick, since HungerThirstSystem is off) is visible.
    t.isNil(snap, 'every wellbeing flag is off in this fixture -- getWellbeingSnapshot must return nil, not a snapshot of an inert stat')
end)

t.test('Passive decay: hunger and thirst each drop by exactly their own decayPerTick, once per tick, clamped at 0 and never negative', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)

    f.runOneTick() -- primes, then one real pass
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.hunger, 100 - 0.093, 'hungerDecayPerTick applied exactly once')
    t.equals(snap.thirst, 100 - 0.139, 'thirstDecayPerTick applied exactly once, a DIFFERENT (faster) rate than hunger')

    -- Enough ticks to drive both stats to (and past) 0 -- confirm the clamp,
    -- not merely the arithmetic.
    for _ = 1, 2000 do
        f.advance(5000)
        f.runOneTick()
    end
    local final = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(final.hunger, 0, 'hunger clamps at 0, never negative, no matter how many ticks elapse with no feeding')
    t.equals(final.thirst, 0, 'thirst clamps at 0, never negative, no matter how many ticks elapse with no watering')
end)

t.test('CONSEQUENCE STAYS MILD: even at hunger=thirst=0, this file never blocks anything -- it only ever feeds K9MoveRateModifiers via the pushed snapshot; TickWellbeing itself has no sprint/jump block for either stat (unlike Injury)', function()
    -- Server-side proof that this file's own TickWellbeing contains no
    -- Hunger/Thirst-driven DisableControlAction-equivalent or hard refusal
    -- anywhere -- the actual client-local move-rate multiplier is
    -- client/wellbeing.lua's job (see tests/clientwellbeing_spec.lua for
    -- that half). This test proves the SERVER never computes or pushes
    -- anything resembling a boolean "blocked" state for these two stats --
    -- only the plain numeric hunger/thirst values themselves, exactly like
    -- Fatigue/Mood (a multiplier-only consequence), never like Injury
    -- (which separately pushes sprintBlockThreshold/jumpBlockThreshold for
    -- a REAL client-side hard block).
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    for _ = 1, 2000 do
        f.advance(5000)
        f.runOneTick()
    end
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.hunger, 0)
    t.equals(snap.thirst, 0)
    t.isNil(snap.hungerBlocked, 'no such field exists -- this file never computes a hard block for Hunger')
    t.isNil(snap.thirstBlocked, 'no such field exists -- this file never computes a hard block for Thirst')
    -- The only Hunger/Thirst-derived values ever pushed are the plain
    -- numbers and the two MILD tunables consumed by client-side
    -- move-rate composition -- both present, both plain multipliers.
    t.equals(snap.wellbeingTunables.hungerSpeedPenaltyMultiplier, 0.95)
    t.equals(snap.wellbeingTunables.thirstSpeedPenaltyMultiplier, 0.95)
end)

t.test('PER-PERSON FEATURE CONTROL: a citizenid explicitly blocked from HungerThirstSystem never decays either stat, but is never frozen from being fed/watered -- same "immunity from harm, never gate relief" design as every sibling stat', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    f.env.HasPermission = function(citizenid, key) return citizenid == 'K9-CID' and key == 'block.HungerThirstSystem' end

    f.runOneTick()
    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.hunger, 100, 'blocked citizenid never decays')
    t.equals(snap.thirst, 100, 'blocked citizenid never decays')

    -- Relief still works normally despite the block -- see feedK9Hunger's
    -- own tests below for the full flow; this just confirms the gate is
    -- absent from that path too.
    f.setItemCount(src, 'k9_food', 1)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    local afterFeed = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(afterFeed.hunger, 100, 'already at max, but the point is the call was never refused by the block -- see the exact regen-amount test below for a non-clamped case')
end)

-- ------------------------------------------------------------------------
-- feedK9Hunger — self-only, item-based
-- ------------------------------------------------------------------------

t.test('feedK9Hunger: feature disabled is a silent no-op -- no item consumed, no stat change, no notify', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = false } })
    local src = wireHungerThirstK9(f)
    f.setItemCount(src, 'k9_food', 5)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 5)
    t.equals(#f.notifyCalls, 0)
end)

t.test('feedK9Hunger: not currently K9-modeled is a silent no-op', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = 1
    f.setPlayer(src, 'K9-CID')
    f.setOnline({ src })
    f.setPed(src, 9001)
    f.setModel(9001, 999) -- NOT a configured K9 model
    f.setCoords(9001, 0, 0, 0)
    f.setItemCount(src, 'k9_food', 5)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 5)
    t.equals(#f.notifyCalls, 0)
end)

t.test('feedK9Hunger: no item carried -- refused with reason_no_food, no cooldown stamped (a real retry with the item in hand must still succeed)', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, Sandbox.locale('wellbeing.reason_no_food'))
    t.equals(f.notifyCalls[1].notifyType, 'error')

    f.setItemCount(src, 'k9_food', 1)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].notifyType, 'success', 'the earlier failed attempt (no item) must not have stamped the cooldown -- a real retry succeeds immediately')
end)

t.test('feedK9Hunger: real success -- consumes exactly one item, restores hunger by feedRegenAmount, clamped at max, and notifies success', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    f.setItemCount(src, 'k9_food', 2)

    -- Lower hunger below max first so the regen is observable rather than
    -- masked by the clamp.
    for _ = 1, 500 do
        f.advance(5000)
        f.runOneTick()
    end
    local before = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(before.hunger < 100 and before.hunger > 0)

    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 1, 'exactly one k9_food consumed')
    local after = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(after.hunger, math.min(100, before.hunger + 35), 'feedRegenAmount(35) applied, clamped to max')
    t.equals(f.notifyCalls[1].description, Sandbox.locale('wellbeing.eat_success'))
end)

t.test('feedK9Hunger: SELF-SERVICE, a deliberate divergence from Mood -- a K9 with no partner online can feed itself repeatedly (subject only to the cooldown and real item cost), never refused for "no target"', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f) -- the ONLY online player
    f.setItemCount(src, 'k9_food', 1)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.notifyCalls[1].notifyType, 'success', 'no second player was ever needed -- this is the deliberate divergence from Mood\'s feedK9/petK9')
end)

t.test('feedK9Hunger: cooldown blocks a second feed inside feedCooldownMs, even with items still in hand, and releases exactly on schedule', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    f.setItemCount(src, 'k9_food', 5)

    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 4)

    f.advance(119999) -- feedCooldownMs(120000) - 1ms
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 4, 'still on cooldown -- no item consumed')
    t.equals(f.notifyCalls[2].description, Sandbox.locale('wellbeing.reason_on_cooldown'))

    f.advance(1) -- exactly feedCooldownMs elapsed now
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 3, 'cooldown genuinely released -- a real feed succeeds')
end)

t.test('feedK9Hunger: cooldown is keyed by CITIZENID, not raw source -- reconnecting under a NEW source id with the SAME citizenid is still on cooldown (cannot be bypassed by disconnect/reconnect)', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f, { src = 1, citizenid = 'K9-CID' })
    f.setItemCount(src, 'k9_food', 5)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.getItemCount(src, 'k9_food'), 4)

    -- Same citizenid, brand-new connection id.
    f.firePlayerDropped(src)
    local newSrc = 2
    f.setPlayer(newSrc, 'K9-CID')
    f.setOnline({ newSrc })
    f.setPed(newSrc, 9050)
    f.setModel(9050, 555)
    f.setCoords(9050, 0, 0, 0)
    f.setItemCount(newSrc, 'k9_food', 5)
    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', newSrc)
    t.equals(f.getItemCount(newSrc, 'k9_food'), 5, 'still blocked -- the cooldown followed the citizenid across a reconnect under a different source id')
end)

-- ------------------------------------------------------------------------
-- giveK9Water — self-only, item-based (same shape as feedK9Hunger)
-- ------------------------------------------------------------------------

t.test('giveK9Water: real success -- consumes exactly one item, restores thirst by drinkRegenAmount, clamped at max', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    f.setItemCount(src, 'k9_water', 2)
    for _ = 1, 500 do
        f.advance(5000)
        f.runOneTick()
    end
    local before = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    f.dispatchNetEvent('qbx_k9unit:server:giveK9Water', src)
    t.equals(f.getItemCount(src, 'k9_water'), 1)
    local after = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(after.thirst, math.min(100, before.thirst + 35))
    t.equals(f.notifyCalls[1].description, Sandbox.locale('wellbeing.drink_success'))
end)

t.test('giveK9Water: no item -- reason_no_water, and feedK9Hunger\'s own cooldown is completely independent (feeding does not block watering)', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } })
    local src = wireHungerThirstK9(f)
    f.setItemCount(src, 'k9_food', 1)
    f.setItemCount(src, 'k9_water', 0)

    f.dispatchNetEvent('qbx_k9unit:server:feedK9Hunger', src)
    t.equals(f.notifyCalls[1].notifyType, 'success')

    f.dispatchNetEvent('qbx_k9unit:server:giveK9Water', src)
    t.equals(f.notifyCalls[2].description, Sandbox.locale('wellbeing.reason_no_water'), 'Hunger\'s own cooldown/success has no bearing on Thirst\'s independent tracker')
end)

-- ------------------------------------------------------------------------
-- drinkFromBowl — self-only, world-prop, NO item consumed
-- ------------------------------------------------------------------------

t.test('drinkFromBowl: SERVER-AUTHORITATIVE -- a client-claimed netId that resolves to a real object of the WRONG model is rejected outright, no matter how close it is', function()
    local cfg = baselineWellbeingConfig()
    cfg.Thirst.bowlSources = { 'test_water_bowl' }
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true }, wellbeingCfg = cfg })
    local src = wireHungerThirstK9(f)

    f.setNetworkEntity(555, 8001, 3)
    f.setModel(8001, 'NOT_a_bowl')
    f.setCoords(8001, 0, 0, 0) -- right on top of the K9 -- distance is not the reason this fails
    f.dispatchNetEvent('qbx_k9unit:server:drinkFromBowl', src, 555)

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.thirst, 100, 'never trusts the client\'s claim about which entity this netId is -- the model is re-derived server-side and rejected')
    t.equals(#f.notifyCalls, 0)
end)

t.test('drinkFromBowl: SERVER-AUTHORITATIVE -- the right model but TOO FAR from the caller\'s own live position is rejected, never a client-claimed distance', function()
    local cfg = baselineWellbeingConfig()
    cfg.Thirst.bowlSources = { 'test_water_bowl' }
    cfg.Thirst.bowlInteractRange = 2.0
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true }, wellbeingCfg = cfg })
    local src = wireHungerThirstK9(f)

    f.setNetworkEntity(555, 8001, 3)
    f.setModel(8001, 'test_water_bowl')
    f.setCoords(8001, 50, 0, 0) -- 50m away, well past bowlInteractRange
    f.dispatchNetEvent('qbx_k9unit:server:drinkFromBowl', src, 555)

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(snap.thirst, 100)
    t.equals(#f.notifyCalls, 0)
end)

t.test('drinkFromBowl: a netId that does not resolve to any real, existing entity (never spawned, or already despawned) is a safe no-op, never an error', function()
    local cfg = baselineWellbeingConfig()
    cfg.Thirst.bowlSources = { 'test_water_bowl' }
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true }, wellbeingCfg = cfg })
    local src = wireHungerThirstK9(f)

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:drinkFromBowl', src, 99999)
    t.isTrue(ok)
    t.equals(#f.notifyCalls, 0)
end)

t.test('drinkFromBowl: a non-number payload (a forged/malformed netId) is a safe no-op, never an error -- never trusts the client payload\'s own type', function()
    local cfg = baselineWellbeingConfig()
    cfg.Thirst.bowlSources = { 'test_water_bowl' }
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true }, wellbeingCfg = cfg })
    local src = wireHungerThirstK9(f)

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:drinkFromBowl', src, { evil = true })
    t.isTrue(ok)
    t.equals(#f.notifyCalls, 0)
end)

t.test('drinkFromBowl: real success -- correct model, within range, no item consumed at all, restores thirst by bowlRegenAmount', function()
    local cfg = baselineWellbeingConfig()
    cfg.Thirst.bowlSources = { 'test_water_bowl' }
    cfg.Thirst.bowlInteractRange = 2.0
    cfg.Thirst.bowlRegenAmount = 15
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true }, wellbeingCfg = cfg })
    local src, ped = wireHungerThirstK9(f)
    f.setNetworkEntity(555, 8001, 3)
    f.setModel(8001, 'test_water_bowl')
    f.setCoords(8001, 1.0, 0, 0) -- 1.0m, within the 2.0m range
    f.setCoords(ped, 0, 0, 0)

    for _ = 1, 500 do
        f.advance(5000)
        f.runOneTick()
    end
    local before = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)

    f.dispatchNetEvent('qbx_k9unit:server:drinkFromBowl', src, 555)
    local after = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.equals(after.thirst, math.min(100, before.thirst + 15))
    t.equals(f.notifyCalls[1].description, Sandbox.locale('wellbeing.drink_success'))
end)

t.test('WATER BOWL MODEL RISK, DEGRADES GRACEFULLY: bowlSources = {} (the shipped default, since \'water_bowl\' is unverified) makes drinkFromBowl a total, silent no-op -- never an error -- even with a perfectly positioned, correctly-modeled real entity, and Thirst still works fully via giveK9Water regardless', function()
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true } }) -- baselineWellbeingConfig's Thirst.bowlSources = {}
    local src, ped = wireHungerThirstK9(f)
    f.setNetworkEntity(555, 8001, 3)
    f.setModel(8001, 'water_bowl')
    f.setCoords(8001, 0, 0, 0)
    f.setCoords(ped, 0, 0, 0)

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:drinkFromBowl', src, 555)
    t.isTrue(ok, 'no bowl model configured at all -- must degrade to a safe no-op, never throw')
    t.equals(#f.notifyCalls, 0)

    -- The item-based path has no model dependency at all -- it still works.
    f.setItemCount(src, 'k9_water', 1)
    f.dispatchNetEvent('qbx_k9unit:server:giveK9Water', src)
    t.equals(f.notifyCalls[1].notifyType, 'success', 'Thirst is never fully broken by an unresolved bowl model -- giveK9Water has no model dependency')
end)

t.test('ANTI-FARM: giveK9Water (item) and drinkFromBowl (world prop) SHARE one cooldown tracker -- alternating the two on yourself cannot double the effective thirst-regen rate inside one cooldown window', function()
    local cfg = baselineWellbeingConfig()
    cfg.Thirst.bowlSources = { 'test_water_bowl' }
    cfg.Thirst.drinkCooldownMs = 90000
    cfg.Thirst.bowlCooldownMs = 60000
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true }, wellbeingCfg = cfg })
    local src = wireHungerThirstK9(f)
    f.setNetworkEntity(555, 8001, 3)
    f.setModel(8001, 'test_water_bowl')
    f.setCoords(8001, 0, 0, 0)
    f.setItemCount(src, 'k9_water', 5)

    -- Item-drink first, stamping the shared tracker.
    f.dispatchNetEvent('qbx_k9unit:server:giveK9Water', src)
    t.equals(f.getItemCount(src, 'k9_water'), 4)
    t.equals(f.notifyCalls[1].notifyType, 'success')

    -- Bowl-drink immediately after: bowlCooldownMs(60000) has not elapsed
    -- since the SAME shared stamp -- blocked, exactly like re-using the
    -- same action would be.
    f.dispatchNetEvent('qbx_k9unit:server:drinkFromBowl', src, 555)
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, Sandbox.locale('wellbeing.reason_on_cooldown'), 'the bowl path must be blocked by the SAME stamp the item path just made -- proves one shared tracker instance, not two independent ones')

    -- Once bowlCooldownMs(60000) has elapsed, the bowl path is free again --
    -- proves this is a real, releasing cooldown, not a permanent lockout.
    f.advance(60000)
    f.dispatchNetEvent('qbx_k9unit:server:drinkFromBowl', src, 555)
    t.equals(#f.notifyCalls, 3)
    t.equals(f.notifyCalls[3].notifyType, 'success')
end)

-- ------------------------------------------------------------------------
-- CONFIG-DEFENSIVENESS -- this file does not own config.lua; Config.Wellbeing
-- .Hunger/.Thirst may not exist yet on a server whose config.lua has not
-- landed them.
-- ------------------------------------------------------------------------

t.test('CONFIG-DEFENSIVE: Config.Wellbeing.Hunger/.Thirst entirely ABSENT (an old config.lua, HungerThirstSystem flipped on anyway) never crashes EnsureStats/SnapshotOf/TickWellbeing/WarnIfItemMissing -- degrades to safe hardcoded fallbacks instead', function()
    local cfg = baselineWellbeingConfig()
    cfg.Hunger = nil
    cfg.Thirst = nil
    local f = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true, MoodSystem = true }, wellbeingCfg = cfg })
    local src = wireHungerThirstK9(f)

    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'TickWellbeing must never crash just because Config.Wellbeing.Hunger/.Thirst are missing entirely')

    local snap = f.invokeCallback('qbx_k9unit:server:getWellbeingSnapshot', src)
    t.isTrue(snap ~= nil, 'MoodSystem is on -- a snapshot must still be produced')
    t.isTrue(type(snap.hunger) == 'number' and snap.hunger <= 100, 'hunger falls back to a safe hardcoded default (100, then decayed once) rather than erroring')
    t.isTrue(type(snap.thirst) == 'number' and snap.thirst <= 100)

    local okStart = pcall(f.fireResourceStart)
    t.isTrue(okStart, 'the onResourceStart item-warning sweep must also survive a missing Config.Wellbeing.Hunger/.Thirst')
end)

-- ========================================================================
-- HANDLER CONDITION BADGE (this pass) -- see server/wellbeing.lua's own
-- "HANDLER CONDITION BADGE" header section for the full design these
-- tests pin. Every test below uses the REAL, unmodified
-- PushHandlerConditionUpdate/ComputeHandlerConditionTags/
-- ClearHandlerConditionBadge/ClearAllHandlerConditionBadges — none of
-- them are `local` to this SPEC, only to server/wellbeing.lua itself —
-- reached exclusively through the real TickWellbeing tick, the real
-- playerDropped handler, and the real CreateThread loop's own `else`
-- branch, exactly as production reaches them.
-- ========================================================================

local HANDLER_CONDITION_EVENT = 'qbx_k9unit:client:partnerConditionUpdate'

--- @param f table
--- @return table[] -- every captured partnerConditionUpdate client event, in order
local function partnerConditionEvents(f)
    local out = {}
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == HANDLER_CONDITION_EVENT then
            out[#out + 1] = ev
        end
    end
    return out
end

--- Wires ONE online, K9-modeled player plus ONE registered (not
--- necessarily "online" in the GetPlayers() sense -- see this section's
--- own note below on why that distinction does not matter here) handler
--- citizenid, partners them, and puts the K9 online. Does NOT run a tick
--- -- callers do that themselves so they can inspect state at whichever
--- point in the sequence they care about.
--- @param f table
--- @param opts table? -- { k9Src, k9Citizenid, handlerSrc, handlerCitizenid }
--- @return number k9Src, number ped, number handlerSrc
local function wirePartneredK9(f, opts)
    opts = opts or {}
    local k9Src = opts.k9Src or 1
    local k9Citizenid = opts.k9Citizenid or 'K9-CID'
    local handlerSrc = opts.handlerSrc or 10
    local handlerCitizenid = opts.handlerCitizenid or 'HANDLER-CID'
    local ped = k9Src * 100

    f.setPlayer(k9Src, k9Citizenid)
    f.setPed(k9Src, ped)
    f.setModel(ped, 555)
    f.setIsK9Model(555, true)
    f.setCoords(ped, 0, 0, 0)
    f.setPlayer(handlerSrc, handlerCitizenid)
    f.setPartner(k9Citizenid, handlerCitizenid)
    f.setOnline({ k9Src })

    return k9Src, ped, handlerSrc
end

t.test('HANDLER CONDITION BADGE: a genuinely partnered, online handler receives exactly one condition push per changed tick', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrc = wirePartneredK9(f)

    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 1)
    t.equals(events[1].target, handlerSrc)
    t.isTrue(events[1].args[1].visible)
end)

t.test('HANDLER CONDITION BADGE: an UNPARTNERED K9 sends no condition update to anyone, ever, even across many ticks -- with the partnership MODULE genuinely loaded (a real resolver wired in for an unrelated pair), just no ROW for this citizenid', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    f.setPlayer(1, 'K9-LONELY')
    f.setPed(1, 100)
    f.setModel(100, 555)
    f.setIsK9Model(555, true)
    f.setCoords(100, 0, 0, 0)
    f.setOnline({ 1 })
    -- setPartner for a COMPLETELY UNRELATED pair -- this wires the real
    -- GetActivePartnerCitizenId resolver function into env (module
    -- genuinely "loaded"), while 'K9-LONELY' itself is left with no row
    -- at all -- distinct from the dedicated module-ABSENT test below,
    -- which exercises the OTHER absence shape (GetActivePartnerCitizenId
    -- not a function at all).
    f.setPlayer(2, 'SOME-OTHER-K9')
    f.setPlayer(20, 'SOME-OTHER-HANDLER')
    f.setPartner('SOME-OTHER-K9', 'SOME-OTHER-HANDLER')

    f.runOneTick()
    f.runOneTick()
    f.runOneTick()

    t.equals(#partnerConditionEvents(f), 0)
end)

t.test('HANDLER CONDITION BADGE: server/partnership.lua module absent (GetActivePartnerCitizenId not a function at all) is a silent no-op, never a crash', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    f.setPlayer(1, 'K9-NOMOD')
    f.setPed(1, 100)
    f.setModel(100, 555)
    f.setIsK9Model(555, true)
    f.setCoords(100, 0, 0, 0)
    f.setOnline({ 1 })
    f.setNoPartnershipModule()

    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'TickWellbeing must never crash just because server/partnership.lua never loaded')
    t.equals(#partnerConditionEvents(f), 0)
end)

t.test('HANDLER CONDITION BADGE: Config.Features.HandlerPartnership = false is treated exactly like "no partnership" -- gated even when GetActivePartnerCitizenId WOULD have resolved a real partner', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = false } })
    wirePartneredK9(f)

    f.runOneTick()

    t.equals(#partnerConditionEvents(f), 0, 'the feature flag must be checked even though this K9 genuinely has an active partnership')
end)

t.test('HANDLER CONDITION BADGE: a handler receives condition updates ONLY for their OWN bonded K9 partner, never for an unrelated K9 -- two independent pairs, cross-checked both ways', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrcA = wirePartneredK9(f, { k9Src = 1, k9Citizenid = 'K9-A', handlerSrc = 10, handlerCitizenid = 'HANDLER-A' })

    -- A second, completely independent pair -- different K9, different
    -- handler, no relationship to the first pair at all.
    f.setPlayer(2, 'K9-B')
    f.setPed(2, 200)
    f.setModel(200, 555)
    f.setIsK9Model(555, true)
    f.setCoords(200, 5000, 5000, 0) -- far away -- irrelevant, this feature never uses position at all
    f.setPlayer(20, 'HANDLER-B')
    f.setPartner('K9-B', 'HANDLER-B')
    f.setOnline({ 1, 2 })

    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'exactly one push per genuinely partnered, online K9 this tick')

    local sawA, sawB = false, false
    for _, ev in ipairs(events) do
        t.isTrue(ev.target == handlerSrcA or ev.target == 20, 'no target outside the two genuine handlers in this test ever receives this event')
        if ev.target == handlerSrcA then sawA = true end
        if ev.target == 20 then sawB = true end
    end
    t.isTrue(sawA, "K9-A's real partner (HANDLER-A) received their own push")
    t.isTrue(sawB, "K9-B's real partner (HANDLER-B) received their own push, for THEIR OWN K9, never K9-A's")
end)

t.test('HANDLER CONDITION BADGE: send-only-on-change -- an unchanged tick for an already-seen, still-Fine K9 sends nothing new', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, MoodSystem = true, HandlerPartnership = true } })
    wirePartneredK9(f)

    f.runOneTick() -- first tick: always a push (cache starts empty)
    t.equals(#partnerConditionEvents(f), 1)

    f.runOneTick()
    f.runOneTick()
    f.runOneTick()

    t.equals(#partnerConditionEvents(f), 1, 'three more ticks with nothing about this K9 having changed must add zero further pushes')
end)

-- ------------------------------------------------------------------
-- THRESHOLD-TO-WORD PINS -- "coarse, not numeric," derived from the
-- EXISTING per-stat threshold, never a new number. Each test sets its
-- OWN stat's threshold to EXACTLY the stat's known starting value (see
-- EnsureStats above -- Fatigue/Mood/Injury/Hunger/Thirst all start at
-- their own `.max`; FearStress starts at 0) so the tag's own boundary
-- comparison (`<=`/`>=`) is pinned on ONE deterministic real tick, with
-- every OTHER stat's owning flag left off so only the one tag under test
-- can ever appear. Hunger/Thirst additionally zero their own
-- decayPerTick for this one fixture so passive decay cannot move the
-- stat off its known starting value before the tag is evaluated --
-- every other stat's own first-tick arithmetic already lands back on
-- its exact starting value with no override needed (Fatigue: lastCoords
-- is nil on tick 1, so no sprint/rest branch runs at all; Mood/Injury:
-- passive REGEN clamps at max, a no-op starting already at max;
-- FearStress: passive DECAY clamps at its own floor, 0, a no-op starting
-- already at 0).
-- ------------------------------------------------------------------

--- @param f table
--- @return string[]? tags -- nil if no partnerConditionUpdate was ever sent
local function lastHandlerTags(f)
    local events = partnerConditionEvents(f)
    local last = events[#events]
    return last and last.args[1].tags
end

--- @param tags string[]?
--- @param tag string
--- @return boolean
local function tagsContain(tags, tag)
    if not tags then return false end
    for _, v in ipairs(tags) do
        if v == tag then return true end
    end
    return false
end

t.test('THRESHOLD PIN: Fatigue <= speedPenaltyThreshold reports "tired" -- absent one unit above it, present exactly at it', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.Fatigue.speedPenaltyThreshold = 99 -- starting fatigue (max=100) is one unit ABOVE this
    local fAbsent = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'tired'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.Fatigue.speedPenaltyThreshold = 100 -- starting fatigue is EXACTLY this
    local fPresent = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'tired'))
end)

t.test('THRESHOLD PIN: Mood <= performancePenaltyThreshold reports "unhappy" -- absent one unit above it, present exactly at it', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.Mood.performancePenaltyThreshold = 99
    local fAbsent = newWellbeingFixture({ featuresOverride = { MoodSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'unhappy'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.Mood.performancePenaltyThreshold = 100
    local fPresent = newWellbeingFixture({ featuresOverride = { MoodSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'unhappy'))
end)

t.test('THRESHOLD PIN: FearStress >= hesitationThreshold reports "stressed" -- absent one unit above it, present exactly at it (starting fearStress is 0)', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.FearStress.hesitationThreshold = 1 -- starting fearStress (0) is one unit BELOW this
    local fAbsent = newWellbeingFixture({ featuresOverride = { FearStressSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'stressed'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.FearStress.hesitationThreshold = 0 -- starting fearStress is EXACTLY this
    local fPresent = newWellbeingFixture({ featuresOverride = { FearStressSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'stressed'))
end)

t.test('THRESHOLD PIN: Injury <= sprintBlockThreshold reports "injured" -- absent one unit above it, present exactly at it', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.Injury.sprintBlockThreshold = 99
    local fAbsent = newWellbeingFixture({ featuresOverride = { InjuryLimping = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'injured'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.Injury.sprintBlockThreshold = 100
    local fPresent = newWellbeingFixture({ featuresOverride = { InjuryLimping = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'injured'))
end)

t.test('THRESHOLD PIN: Hunger <= lowThreshold reports "hungry" -- absent one unit above it, present exactly at it', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.Hunger.decayPerTick = 0 -- pin the starting value exactly at max across the one tick this test runs
    cfgAbsent.Hunger.lowThreshold = 99
    local fAbsent = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'hungry'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.Hunger.decayPerTick = 0
    cfgPresent.Hunger.lowThreshold = 100
    local fPresent = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'hungry'))
end)

t.test('THRESHOLD PIN: Thirst <= lowThreshold reports "thirsty" -- absent one unit above it, present exactly at it', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.Thirst.decayPerTick = 0
    cfgAbsent.Thirst.lowThreshold = 99
    local fAbsent = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'thirsty'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.Thirst.decayPerTick = 0
    cfgPresent.Thirst.lowThreshold = 100
    local fPresent = newWellbeingFixture({ featuresOverride = { HungerThirstSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'thirsty'))
end)

t.test('THRESHOLD PIN: a healthy K9 (every real shipped default, every one of the six flags on) reports an EMPTY tags array -- "Fine"', function()
    local f = newWellbeingFixture({
        featuresOverride = {
            FatigueSystem = true, MoodSystem = true, FearStressSystem = true,
            InjuryLimping = true, HungerThirstSystem = true, HandlerPartnership = true,
        },
    })
    wirePartneredK9(f)
    f.runOneTick()

    local tags = lastHandlerTags(f)
    t.isTrue(tags ~= nil)
    t.equals(#tags, 0)
end)

t.test('THRESHOLD PIN: a tag is gated on its OWN owning Config.Features flag -- Fatigue at/below threshold reports NOTHING while FatigueSystem itself is off', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.speedPenaltyThreshold = 100 -- would report 'tired' if FatigueSystem were on
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = false, MoodSystem = true, HandlerPartnership = true }, wellbeingCfg = cfg })
    wirePartneredK9(f)
    f.runOneTick()

    t.isFalse(tagsContain(lastHandlerTags(f), 'tired'))
end)

-- ------------------------------------------------------------------
-- NEVER A TRACKER -- assert on the REAL payload shape, not on intent.
-- ------------------------------------------------------------------

t.test('NEVER A TRACKER: the payload sent to a handler is EXACTLY { visible, tags } -- no position, no raw stat value, no third key, across a battery of scenarios including near-threshold and every flag on at once', function()
    local scenarios = {
        { features = { FatigueSystem = true, HandlerPartnership = true } },
        { features = { FatigueSystem = true, MoodSystem = true, FearStressSystem = true, InjuryLimping = true, HungerThirstSystem = true, HandlerPartnership = true } },
    }

    local allowedTags = { tired = true, unhappy = true, stressed = true, injured = true, hungry = true, thirsty = true }

    for _, scenario in ipairs(scenarios) do
        local f = newWellbeingFixture({ featuresOverride = scenario.features })
        wirePartneredK9(f)
        f.setCoords(100, 12345.6, -9876.5, 42.0) -- a real, distinctive position this payload must NEVER leak
        f.setHealth(100, 200) -- a real, distinctive raw health value this payload must NEVER leak

        for _ = 1, 3 do f.runOneTick() end

        for _, ev in ipairs(partnerConditionEvents(f)) do
            local payload = ev.args[1]
            local keyCount = 0
            for _ in pairs(payload) do keyCount = keyCount + 1 end
            t.equals(keyCount, 2, 'payload must have EXACTLY two keys: visible, tags')
            t.isTrue(type(payload.visible) == 'boolean')
            t.isTrue(type(payload.tags) == 'table')

            for _, tag in ipairs(payload.tags) do
                t.isTrue(type(tag) == 'string' and allowedTags[tag] == true, 'every tag must be one of the six fixed, coarse, non-numeric codes -- got ' .. tostring(tag))
                -- Never a number rendered as a string, never a coordinate
                -- component, never anything resembling a raw stat value.
                t.isTrue(tonumber(tag) == nil, 'a tag must never be numeric')
            end
        end
    end
end)

-- ------------------------------------------------------------------
-- "GATE THE START, NEVER THE STOP" -- the display must stop cleanly.
-- ------------------------------------------------------------------

t.test('STOPS CLEANLY: partnership ending sends an explicit visible=false clear on the very next tick -- self-healing, not stranded', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrc = wirePartneredK9(f)
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1, 'sanity: the handler really did get an initial visible push')

    f.clearPartner('K9-CID') -- partnership ends -- GetActivePartnerCitizenId now resolves nil for both parties
    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2)
    local clearEvent = events[2]
    t.equals(clearEvent.target, handlerSrc)
    t.isFalse(clearEvent.args[1].visible)
    t.equals(#clearEvent.args[1].tags, 0)

    -- And it stays cleared -- no further stray pushes once there is
    -- nothing left to report.
    f.runOneTick()
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 2)
end)

t.test('STOPS CLEANLY: the K9 (not the handler) disconnecting clears the badge IMMEDIATELY, via playerDropped -- never waits for a future tick that will never come for this citizenid again', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local k9Src, _, handlerSrc = wirePartneredK9(f)
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1)

    f.firePlayerDropped(k9Src)

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'the clear must be sent synchronously from playerDropped, with no further tick needed')
    t.equals(events[2].target, handlerSrc)
    t.isFalse(events[2].args[1].visible)

    -- GetPlayers() no longer includes the disconnected K9 -- proves this
    -- citizenid would otherwise never be revisited by TickWellbeing again,
    -- which is exactly why the immediate clear above matters.
    f.setOnline({})
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 2, 'no further pushes for a citizenid TickWellbeing will never iterate again')
end)

t.test('STOPS CLEANLY: the HANDLER (not the K9) disconnecting needs no explicit push (nobody to receive one), and a later RECONNECT under a new source id forces a fresh push rather than being suppressed as "unchanged"', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    wirePartneredK9(f, { handlerSrc = 10, handlerCitizenid = 'HANDLER-RECONNECT' })
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1)

    f.clearPlayer(10) -- handler goes offline -- GetPlayerByCitizenId('HANDLER-RECONNECT') now resolves nil
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'an offline handler must never crash the tick')
    t.equals(#partnerConditionEvents(f), 1, 'nothing to push to -- no event, but no error either')

    -- Handler reconnects under a DIFFERENT server id (a real, common case --
    -- FiveM does not guarantee the same id back).
    f.setPlayer(11, 'HANDLER-RECONNECT')
    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'the reconnect must force a fresh push, not be suppressed by an unchanged tagsKey against the OLD source id')
    t.equals(events[2].target, 11)
    t.isTrue(events[2].args[1].visible)
end)

t.test('STOPS CLEANLY: every wellbeing stat system switched off at once clears every currently-visible badge from the CreateThread loop\'s own else-branch -- the one iteration TickWellbeing itself never runs', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrc = wirePartneredK9(f)
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1)

    f.config.Features.FatigueSystem = false -- the ONLY flag that was on -- now every one of the six is off

    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'the else-branch must clear the stranded badge on this very next tick, even though TickWellbeing itself never runs')
    t.equals(events[2].target, handlerSrc)
    t.isFalse(events[2].args[1].visible)

    -- Idempotent -- repeatedly idling with everything off must never
    -- resend the clear over and over.
    f.runOneTick()
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 2)
end)

os.exit(t.summary())
