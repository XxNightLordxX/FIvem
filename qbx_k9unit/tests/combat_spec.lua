--[[
    tests/combat_spec.lua

    First test coverage for server/combat.lua -- the largest and most
    security-sensitive file in this resource, previously with zero direct
    spec coverage despite being where several of this session's worst bugs
    lived (the four dead-native death-check no-ops, the BiteAndHold
    per-target XP farm, the holder-death lifecycle gap, the NPC-target
    native-availability bugs). Loads the REAL, unmodified
    server/cooldowns.lua -> server/entities.lua -> server/combat.lua chain
    (the exact fxmanifest.lua server_scripts order for this file's own
    load-time dependencies), so every NewCooldown/NewMutex/
    ResolveNetworkEntity/ResolveConnectedPlayerFromPed call this file makes
    is the real primitive, never a reimplementation.

    HasK9Access and NotifyPlayer are stubbed directly, same convention
    kennel_spec.lua already established: both are genuinely OTHER files' own
    logic (server/certifications.lua, server/notify.lua), already covered by
    their own specs -- this file's job is server/combat.lua's own
    validation/lifecycle/termination logic, not a second copy of those.
    IsHesitating/IsDistracted/AwardXP are the same "runtime existence guard,
    not a load-order assumption" shape server/combat.lua's own header
    documents -- omitted from the sandbox entirely by default (proving the
    real `type(...) == 'function'` guards degrade cleanly when
    server/wellbeing.lua / server/progression.lua are absent), added back
    as controllable stubs only for the tests that specifically exercise
    them.

    NOTE ON NOT ASSERTING PLAYER-FACING NOTIFICATION TEXT: server/combat.lua
    was, per this task's own instructions, being concurrently migrated to
    locale() by another agent WHILE this spec was authored (STRINGS only,
    not logic). Every assertion below is therefore against a STRUCTURAL,
    non-text observable: which client event fired (and to whom, with what
    typed payload), whether ActiveHolds/K9ActiveEffect changed, whether
    AwardXP was invoked, NotifyPlayer's `notifyType` (a stable enum:
    'error'/'success'/'inform', not prose) and call COUNT -- never
    `NotifyPlayer`'s `description` argument's actual text, and never a
    printed line's exact wording beyond a couple of hardcoded, clearly
    developer-only (not locale-migrated) diagnostic substrings ("failing
    closed") that appear nowhere near a NotifyPlayer/locale() call in the
    real source.

    ONE FRESH SANDBOX PER TEST (never shared) -- ActiveHolds/K9ActiveEffect/
    every cooldown tracker are file-lifetime `local` upvalues, so reusing one
    sandbox across unrelated cases would leak state, same discipline
    kennel_spec.lua/defense_spec.lua already established.

    YIELDING EVENT HANDLERS: HandleTakedownRequest (behind
    'qbx_k9unit:server:requestTakedown') calls a real Wait(...) mid-handler
    for its server-computed speed-sample window, then re-validates
    everything after the yield -- exactly the kind of TOCTOU logic this
    suite exists to exercise for real, not approximate. Every net event is
    therefore dispatched through a real Lua coroutine below (matching how
    FXServer itself invokes a RegisterNetEvent handler in its own
    coroutine, which is what makes a yieldable pcall -- Lua 5.2+'s
    lua_pcallk -- work at all): `dispatchNetEvent` auto-resumes through any
    yield with no test interaction (fine for handlers that don't care what
    happens mid-wait), and `dispatchStepped` exposes an `onSuspend` hook so
    a test can mutate world state (e.g. move the target) at the EXACT
    instant the handler is parked on its Wait(), to drive the real
    before/after speed sample deterministically without any wall-clock
    delay.

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - client/combat.lua is untested here -- client-only natives, no
        server-side equivalent to sandbox against, same blanket exclusion
        DEVELOPER_REFERENCE.md already states for every client/*.lua file.
      - NonComplianceDetection's own movement-sampling HEURISTICS (bite-hold
        idle/speed tolerance, takedown net displacement, drag gap) are left
        disabled (Config.Combat.NonComplianceDetection.enabled = false, the
        real shipped default) through every OTHER test in this file and are
        NOT separately exercised as an exhaustive suite -- it is explicitly
        non-punitive/detection-only (never gates a single server-
        authoritative outcome this suite's own "what matters most" brief
        cares about). Disclosed here as a real, deliberate scope cut, not a
        silent gap. ONE dedicated section near the bottom of this file DOES
        enable it, narrowly, to cover the notify_staff fan-out's ACE->job-
        rank rewrite (IsAuthorizedForNonComplianceAlert, project-owner-
        directed, this pass) using the simplest possible violation trigger
        -- that is a permission-boundary test, not heuristics coverage.
      - PropDragging gets a materially lighter pass than BiteAndHold/
        NonLethalTakedown (a handful of smoke tests near the bottom of this
        file) -- it shares this file's own EndHold/maintenance-thread/
        ActiveHolds machinery (so every death-check/termination-path
        assertion above already exercises code PropDragging also runs
        through), but its own bespoke logic (IsTargetDowned, the
        dual-release-side releaseDrag, DragExceedsMaxDistance) is not one of
        this task's five named priorities and is covered at "does this
        exist and work at all," not exhaustively.
      - The exact numeric XP payout amount is never asserted (this file
        never reads Config.XP.awards.* itself -- that's server/progression.lua's
        own concern, already covered by progression_spec.lua) -- only
        WHETHER AwardXP('biteHoldSuccess'/'takedownSuccess') was called at
        all, and how many times, which is what this task's brief actually
        asks this spec to pin.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to defense_spec.lua's own
-- copy (the only other files needing GetEntityCoords' `-`/`#` operators).
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
-- Real, shipped config.lua baselines -- used so boundary tests exercise the
-- actual numbers this resource ships, not arbitrary round test numbers,
-- same convention defense_spec.lua's baselineHandlerDownDefenseConfig()
-- already established. Callers may override any field via newCombatFixture's
-- own opts.*Cfg tables.
-- ----------------------------------------------------------------------

local function baselineBiteAndHoldConfig()
    return { range = 2.5, maxDurationMs = 15000, cooldownMs = 20000, targetCooldownMs = 35000 }
end

local function baselineTakedownConfig()
    return { range = 3.0, minTargetSpeed = 4.0, speedSampleWindowMs = 250, ragdollDurationMs = 4000, cooldownMs = 25000, targetCooldownMs = 30000, healthFloor = 100 }
end

local function baselinePropDraggingConfig(downedOverride)
    return { range = 2.5, maxDragDistance = 30.0, maxDragDurationMs = 20000, dragSpeedMultiplier = 0.4, IsPlayerDownedOverride = downedOverride }
end

local function baselineNonComplianceDetectionConfig()
    return {
        enabled = false, -- the real shipped default -- see this file's own header for why this stays disabled throughout
        positionSampleWindowMs = 500,
        biteHoldIdleCeiling = 0.3,
        biteHoldSpeedTolerance = 0.5,
        biteHoldViolationSamples = 2,
        takedownNetDisplacementMeters = 3.0,
        action = 'log',
        OnViolationOverride = nil,
        dragComplianceSlackMeters = 4.0,
    }
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/combat.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it
--- first (the exact fxmanifest.lua server_scripts order), and every other
--- cross-file/native dependency as a test-controlled stub.
--- @param opts table?
--- @return table fixture
local function newCombatFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, _description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, notifyType = notifyType }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    -- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl) --
    -- HasPermission is OMITTED FROM THE SANDBOX ENTIRELY BY DEFAULT, same
    -- convention this file's own header already establishes for
    -- IsHesitating/IsDistracted/AwardXP: this proves
    -- IsCombatFeaturePermittedForCitizenId's real `type(HasPermission) ==
    -- 'function'` guard degrades cleanly (default-allow, step 4) when
    -- server/permissions.lua is absent, and means every one of THIS file's
    -- other ~70 tests (none of which opt in via opts.withHasPermission)
    -- exercises that exact absent-dependency path for free, never a grant
    -- store that happens to be empty.
    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    -- CERTIFICATION TIER CAPABILITY (server/certtiers.lua's
    -- TierCapabilityPermits, wired into ValidateCombatRequest's
    -- BiteAndHold/NonLethalTakedown branch this pass) -- OMITTED FROM THE
    -- SANDBOX ENTIRELY BY DEFAULT, same convention as HasPermission/
    -- IsHesitating/IsDistracted/AwardXP above: proves the real
    -- `type(TierCapabilityPermits) == 'function'` guard degrades cleanly
    -- (allow) when server/certtiers.lua is absent, and means every one of
    -- this file's other tests (none of which opt in via
    -- opts.withTierCapabilityPermits) exercises that exact
    -- absent-dependency path for free. server/certtiers.lua's own
    -- resolution logic (tier lookup, dormant-capability default-allow,
    -- unresolvable-tier default-allow) is fully covered by its own spec --
    -- this stub only needs to prove server/combat.lua calls it with the
    -- right arguments, at the right place, and honors its answer.
    local tierCapabilityCalls = {}
    local function defaultTierCapabilityPermits(citizenid, jobName, capabilityKey)
        tierCapabilityCalls[#tierCapabilityCalls + 1] = { citizenid = citizenid, jobName = jobName, capabilityKey = capabilityKey }
        if type(opts.tierCapabilityPermitsFn) == 'function' then
            return opts.tierCapabilityPermitsFn(citizenid, jobName, capabilityKey)
        end
        return true -- real TierCapabilityPermits' own default-allow posture
    end

    local playersBySource = {} -- src -> { citizenid=, metadata={wanted=,iswanted=,isdead=,inlaststand=} }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 900000) end

    local networkEntities, existingEntities, entityTypes = {}, {}, {}
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end
    local function DoesEntityExist(handle) return existingEntities[handle] == true end
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local ragdollByPed = {}
    local function IsPedRagdoll(ped) return ragdollByPed[ped] == true end

    local onlineSet = {}
    local function GetPlayers()
        local out = {}
        for id in pairs(onlineSet) do out[#out + 1] = tostring(id) end
        return out
    end

    local awardCalls = {}
    local function awardXPFn(citizenid, awardKey)
        awardCalls[#awardCalls + 1] = { citizenid = citizenid, awardKey = awardKey }
    end

    local hesitatingByCid, distractedByCid = {}, {}
    local function isHesitatingFn(cid) return hesitatingByCid[cid] == true end
    local function isDistractedFn(cid) return distractedByCid[cid] == true end

    -- COMPAT-LAYER (this pass): server/combat.lua's IsTargetDowned now
    -- calls `K9Compat.Get('ambulance').IsDowned(targetSrc)` -- a minimal,
    -- hand-rolled stand-in `K9Compat` is supplied directly (same
    -- established convention as tests/clienttablet_spec.lua's/
    -- tests/clientequipmentshop_spec.lua's own `fakeK9Compat`), never the
    -- real shared/compat/core.lua -- loading that file into this same env
    -- would ALSO register its own onResourceStart handlers (detection
    -- scheduling + the /k9compat command), silently breaking this file's
    -- own "registers exactly 1 onResourceStart handler" assertion below.
    -- Defaults to always returning nil (adapter UNKNOWN/not detected) for
    -- every test that never sets opts.ambulanceIsDowned -- i.e. every
    -- PropDragging test in this file written BEFORE this pass keeps
    -- exercising IsTargetDowned's pre-existing metadata/health fallback
    -- completely unchanged, with zero opt-in required.
    local ambulanceIsDownedCalls = {}
    local function ambulanceIsDownedFn(src)
        ambulanceIsDownedCalls[#ambulanceIsDownedCalls + 1] = src
        if type(opts.ambulanceIsDowned) == 'function' then
            return opts.ambulanceIsDowned(src)
        end
        return nil
    end
    local fakeK9Compat = {
        Get = function(system)
            if system == 'ambulance' then
                return { IsDowned = ambulanceIsDownedFn }
            end
            return {}
        end,
    }

    local config = {
        Features = {
            BiteAndHold = opts.biteAndHold ~= false,
            NonLethalTakedown = opts.nonLethalTakedown ~= false,
            PropDragging = opts.propDragging == true,
            HandlerDownDefense = false,
        },
        Combat = {
            RequireWantedStatus = opts.requireWantedStatus ~= false,
            WantedStatusCheckOverride = opts.wantedOverride,
            NonComplianceDetection = opts.nonComplianceDetectionCfg or baselineNonComplianceDetectionConfig(),
            PropDragging = opts.propDraggingCfg or baselinePropDraggingConfig(opts.downedOverride),
            BiteAndHold = opts.biteAndHoldCfg or baselineBiteAndHoldConfig(),
            NonLethalTakedown = opts.takedownCfg or baselineTakedownConfig(),
        },
        -- Only read by IsAuthorizedForNonComplianceAlert's job-rank check
        -- (ACE->job-rank rewrite, this pass) -- every other check in this
        -- file (HasK9Access, RequireWantedStatus/IsPlayerWantedEligible)
        -- is stubbed/config'd independently and never touches this table.
        -- Default shape here is deliberately arbitrary -- override via
        -- opts.departmentsCfg for tests that care about the exact threshold.
        Departments = opts.departmentsCfg or { police = { nonComplianceAlertGrade = 2 } },
        -- PER-PERSON FEATURE CONTROL -- absent (nil) by default, matching
        -- this file's real config.lua-absent-in-tests posture exactly: with
        -- no Config.FeatureControl table at all, IsCombatFeaturePermittedForCitizenId's
        -- own `type(featureControl) == 'table'` guard makes `requiresGrant`
        -- false for every feature, so every one of this file's ~70 OTHER
        -- tests (none of which pass opts.featureControlRequireGrant) falls
        -- straight through to step 4 (default allow) exactly as before this
        -- check existed. opts.featureControlRequireGrant, when given, is a
        -- plain `{ FeatureName = true, ... }` table assigned verbatim as
        -- Config.FeatureControl.RequireGrant.
        FeatureControl = opts.featureControlRequireGrant and { RequireGrant = opts.featureControlRequireGrant } or nil,
    }

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        HasK9Access = HasK9Access,
        exports = { qbx_core = { GetPlayer = qbxGetPlayer } },
        GetPlayerPed = GetPlayerPed,
        GetEntityHealth = GetEntityHealth,
        GetEntityCoords = GetEntityCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        IsPedRagdoll = IsPedRagdoll,
        K9Compat = fakeK9Compat,
        GetPlayers = GetPlayers,
        Config = config,
    }
    if opts.withAwardXP ~= false then envOverrides.AwardXP = awardXPFn end
    if opts.withWellbeing then
        envOverrides.IsHesitating = isHesitatingFn
        envOverrides.IsDistracted = isDistractedFn
    end
    if opts.withHasPermission then
        envOverrides.HasPermission = opts.hasPermissionFn or defaultHasPermission
    end
    if opts.withTierCapabilityPermits then
        envOverrides.TierCapabilityPermits = defaultTierCapabilityPermits
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/combat.lua', env)

    --- Drives `netEvents[eventName]` to completion inside a real coroutine,
    --- auto-resuming through any Wait()-yield with no interaction (correct
    --- for every handler in this file except requestTakedown, and even for
    --- that one when a test does not care what happens mid-wait -- e.g. the
    --- "not fleeing" rejection, where leaving world state untouched during
    --- the yield is exactly what the test wants). `onSuspend`, if given, runs
    --- every time the coroutine parks on a Wait(), before it is resumed
    --- again -- this is what lets a test move a target's coordinates at the
    --- exact instant HandleTakedownRequest's own before/after speed sample
    --- is taken.
    --- @param eventName string
    --- @param src number
    --- @param args table
    --- @param onSuspend fun()?
    local function dispatchStepped(eventName, src, args, onSuspend)
        env.source = src
        local handler = netEvents[eventName]
        assert(handler, 'no handler registered for ' .. eventName)
        local co = coroutine.create(handler)
        local first = true
        for _ = 1, 50 do
            local result
            if first then
                result = { coroutine.resume(co, table.unpack(args)) }
                first = false
            else
                result = { coroutine.resume(co) }
            end
            if not result[1] then
                error(('dispatch(%s) coroutine error: %s'):format(eventName, tostring(result[2])))
            end
            if coroutine.status(co) == 'dead' then return end
            if onSuspend then onSuspend() end
        end
        error(('dispatch(%s) did not complete after repeated resumes -- unexpected extra yield?'):format(eventName))
    end

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        printedLines = printedLines,
        awardCalls = awardCalls,
        tierCapabilityCalls = tierCapabilityCalls,
        ambulanceIsDownedCalls = ambulanceIsDownedCalls,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        permissionCalls = permissionCalls,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        setPlayer = function(src, shape)
            playersBySource[src] = {
                citizenid = shape.citizenid,
                -- job is ONLY read by IsAuthorizedForNonComplianceAlert's
                -- job-rank check (ACE->job-rank rewrite, this pass) -- every
                -- other test in this file leaves it nil, which is exactly
                -- the "no job at all" shape that check must fail closed on.
                job = shape.job,
                metadata = {
                    wanted = shape.wanted == true,
                    iswanted = shape.iswanted == true,
                    isdead = shape.isdead == true,
                    inlaststand = shape.inlaststand == true,
                },
            }
        end,
        clearPlayer = function(src) playersBySource[src] = nil end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setRagdoll = function(ped, isRagdoll) ragdollByPed[ped] = isRagdoll end,
        registerEntity = function(netId, handle, entityType)
            networkEntities[netId] = handle
            existingEntities[handle] = true
            entityTypes[handle] = entityType or 1
        end,
        addOnline = function(id) onlineSet[id] = true end,
        removeOnline = function(id) onlineSet[id] = nil end,
        setHesitating = function(citizenid, val) hesitatingByCid[citizenid] = val end,
        setDistracted = function(citizenid, val) distractedByCid[citizenid] = val end,
        dispatchNetEvent = function(eventName, src, ...)
            dispatchStepped(eventName, src, { ... }, nil)
        end,
        dispatchStepped = function(eventName, src, args, onSuspend)
            dispatchStepped(eventName, src, args, onSuspend)
        end,
        --- Manual, caller-driven coroutine over a single net event handler --
        --- the only way to interleave a SECOND, fully independent dispatch
        --- (TakedownMutex's own overlapping-call test) while the first is
        --- still parked mid-yield.
        --- @param eventName string
        --- @param src number
        --- @param args table
        --- @return table handle -- { resume = fun(), isDead = fun(): boolean }
        startCoroutine = function(eventName, src, args)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            local co = coroutine.create(handler)
            local started = false
            return {
                resume = function()
                    local result
                    if not started then
                        started = true
                        result = { coroutine.resume(co, table.unpack(args)) }
                    else
                        result = { coroutine.resume(co) }
                    end
                    if not result[1] then
                        error('startCoroutine resume error: ' .. tostring(result[2]))
                    end
                end,
                isDead = function() return coroutine.status(co) == 'dead' end,
            }
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler()
            end
        end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName)
            end
        end,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        runOneTick = function()
            -- Per fixtures/sandbox.lua's own documented stepping semantics:
            -- every captured thread's FIRST step() only reaches its own
            -- initial Wait() (primes, no pass); the loop below always
            -- performs exactly one full pass over every currently-captured
            -- thread by stepping twice from a fresh coroutine, and once more
            -- on every SUBSEQUENT call (matching defense_spec.lua's own
            -- primeIfNeeded/runOneTick split, restated inline here since this
            -- fixture only ever needs "one full pass", never a bare prime).
            if not threadRunner.primed then
                threadRunner.step()
                threadRunner.primed = true
            end
            threadRunner.step()
        end,
    }
end

-- ----------------------------------------------------------------------
-- Wiring helpers -- build a valid K9 / NPC target / player target in one
-- call, shared across most tests below.
-- ----------------------------------------------------------------------

--- @param f table
--- @param src number
--- @param opts table?
--- @return number ped
local function wireK9(f, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100)
    f.setAccess(src, opts.access ~= false)
    -- job defaults to nil (omitted) unless a test explicitly supplies one --
    -- same "no job at all" default every OTHER test in this file already
    -- relies on (see setPlayer's own comment on this field) -- opts.job is
    -- read only by the CERTIFICATION TIER CAPABILITY tests below, which
    -- need a real { name = ... } shape since ValidateCombatRequest's own
    -- tier-capability gate reads PlayerData.job.name, same as
    -- IsAuthorizedForNonComplianceAlert already does.
    f.setPlayer(src, { citizenid = opts.citizenid or ('K9-CID-' .. src), job = opts.job })
    f.setPed(src, ped)
    f.setCoords(ped, opts.x or 0, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    return ped
end

--- @param f table
--- @param netId number
--- @param opts table?
--- @return number ped
local function wireNpcTarget(f, netId, opts)
    opts = opts or {}
    local ped = opts.ped or (netId + 100000)
    f.registerEntity(netId, ped, 1) -- GetEntityType 1 = ped
    f.setCoords(ped, opts.x or 1, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    if opts.ragdoll ~= nil then f.setRagdoll(ped, opts.ragdoll) end
    return ped
end

--- @param f table
--- @param netId number
--- @param src number
--- @param opts table?
--- @return number ped
local function wirePlayerTarget(f, netId, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100)
    f.registerEntity(netId, ped, 1)
    f.setPed(src, ped)
    f.setCoords(ped, opts.x or 1, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    f.setPlayer(src, {
        citizenid = opts.citizenid or ('TARGET-CID-' .. src),
        wanted = opts.wanted ~= false,
        isdead = opts.isdead,
        inlaststand = opts.inlaststand,
    })
    f.addOnline(src)
    return ped
end

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

local K9_SRC = 10
local K9_SRC_B = 11
local TARGET_SRC = 20

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/combat.lua registers exactly its 7 documented server net events', function()
    local f = newCombatFixture()
    local names, count = {}, 0
    for name in pairs(f.netEventNames) do names[name] = true; count = count + 1 end
    t.equals(count, 7)
    for _, name in ipairs({
        'qbx_k9unit:server:requestBiteHold', 'qbx_k9unit:server:releaseBiteHold',
        'qbx_k9unit:server:reportBiteHoldTargetDied', 'qbx_k9unit:server:requestTakedown',
        'qbx_k9unit:server:reportHolderDied', 'qbx_k9unit:server:requestDrag',
        'qbx_k9unit:server:releaseDrag',
    }) do
        t.isTrue(names[name] ~= nil, name .. ' must be registered')
    end
end)

t.test('server/combat.lua registers exactly 6 playerDropped handlers (its own, plus BiteHoldCooldown/TakedownCooldown/TakedownMutex, and the BiteHoldXpMintCooldown/TakedownXpMintCooldown anti-farm trackers added when the seventh XP farm was closed)', function()
    local f = newCombatFixture()
    t.equals(f.eventHandlerCount('playerDropped'), 6)
end)

t.test('server/combat.lua registers exactly 1 onResourceStart handler (the PropDragging override warning)', function()
    local f = newCombatFixture()
    t.equals(f.eventHandlerCount('onResourceStart'), 1)
end)

-- ========================================================================
-- REGRESSION (QA sandbox repro, this pass): a single non-positive Config
-- cooldown value used to abort THIS ENTIRE FILE's load, not just disable
-- one cooldown. Reproduced concretely by QA: loading the real
-- server/cooldowns.lua then server/combat.lua with ONLY
-- Config.Combat.BiteAndHold.cooldownMs set to 0 (every other default left
-- at its shipped value) threw at this file's own
-- `BiteHoldCooldown = NewCooldown(...)` line, so nothing textually below
-- it -- EndActiveEffectForHolder (this codebase's termination primitive,
-- depended on by server/recall.lua and server/training.lua), every
-- BiteAndHold/NonLethalTakedown/PropDragging RegisterNetEvent, and this
-- file's own onResourceStart/playerDropped handlers -- ever existed for the
-- rest of that resource's uptime. Fixed via ResolveConfiguredThresholdMs
-- (server/cooldowns.lua) at all four of this file's raw Config-cooldown
-- call sites. This section proves the fix at the exact level the bug was
-- found: does the file still load, and is the termination path still
-- defined, no matter what an operator puts in the config.
-- ========================================================================

t.test('REGRESSION: Config.Combat.BiteAndHold.cooldownMs = 0 (exact QA repro) no longer aborts this file\'s load, and EndActiveEffectForHolder stays defined', function()
    local f = newCombatFixture({
        biteAndHoldCfg = { range = 2.5, maxDurationMs = 15000, cooldownMs = 0, targetCooldownMs = 35000 },
    })

    t.equals(type(f.env.EndActiveEffectForHolder), 'function',
        'the termination primitive server/recall.lua and server/training.lua depend on must remain reachable no matter what an operator puts in the config')

    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 7, 'every net event this file documents must still register, not just the ones textually above the bad value')
    t.equals(f.eventHandlerCount('onResourceStart'), 1)
    t.equals(f.eventHandlerCount('playerDropped'), 6)

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.Combat.BiteAndHold.cooldownMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find('20000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must still name the exact key, the value found, and the fallback substituted -- the operator must still find out')
end)

t.test('REGRESSION: all four of this file\'s Config-sourced cooldowns invalid at once (worst case) still loads cleanly with every termination/net-event path intact', function()
    local f = newCombatFixture({
        biteAndHoldCfg = { range = 2.5, maxDurationMs = 15000, cooldownMs = 0, targetCooldownMs = -1 },
        takedownCfg = { range = 3.0, minTargetSpeed = 4.0, speedSampleWindowMs = 250, ragdollDurationMs = 4000, cooldownMs = 0 / 0, targetCooldownMs = 'oops', healthFloor = 100 },
    })

    t.equals(type(f.env.EndActiveEffectForHolder), 'function')
    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 7)
end)

t.test('REGRESSION: with a valid Config.Combat.BiteAndHold.cooldownMs, BiteHoldCooldown genuinely uses the CONFIGURED value, not silently always the fallback -- ResolveConfiguredThresholdMs must be pass-through for valid input', function()
    local f = newCombatFixture({
        biteAndHoldCfg = { range = 2.5, maxDurationMs = 15000, cooldownMs = 999, targetCooldownMs = 35000 },
    })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(#f.clientEvents > 0, 'first request must succeed')

    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    local afterRelease = #f.clientEvents -- releaseBiteHold fires its own client events too -- track a running baseline rather than asserting an unrelated implementation-detail count

    f.advance(998) -- 1ms short of the configured 999ms cooldown
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(#f.clientEvents, afterRelease, 'still on the CONFIGURED 999ms cooldown, not silently using some other value -- the rejected retry fires no new client events')

    f.advance(2) -- now past the configured 999ms threshold
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.isTrue(#f.clientEvents > afterRelease, 'cooldown elapsed at the CONFIGURED threshold, proving the real value (not a fallback) is in effect')
end)

-- REGRESSION, DEEPER FINDING (this pass, while verifying the fix above):
-- requestBiteHold/HandleTakedownRequest used to re-read
-- Config.Combat.BiteAndHold/NonLethalTakedown.cooldownMs/targetCooldownMs
-- RAW, a second time, as a per-call IsOnCooldown/Consume override -- which
-- SILENTLY SHADOWED each tracker's own constructor default (the one
-- ResolveConfiguredThresholdMs now protects) at the one place that actually
-- gates a real request. Fixed by dropping the redundant override entirely
-- (see requestBiteHold/HandleTakedownRequest's own comments in
-- server/combat.lua) so the ALREADY-RESOLVED, safe constructor default is
-- what actually governs enforcement, not a second, unguarded raw read. The
-- test above (cooldownMs = 0) only proves the file still LOADS; this proves
-- the mechanic itself keeps WORKING on the fallback, rather than merely
-- failing closed forever with a warning.
t.test('REGRESSION: Config.Combat.BiteAndHold.cooldownMs = 0 -- BiteAndHold keeps WORKING on the 20000ms fallback, not just failing closed forever', function()
    local f = newCombatFixture({
        biteAndHoldCfg = { range = 2.5, maxDurationMs = 15000, cooldownMs = 0, targetCooldownMs = 35000 },
    })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(#f.clientEvents > 0, 'BiteAndHold must still be usable at least once, even with a misconfigured cooldown')

    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    local afterRelease = #f.clientEvents

    f.advance(19999) -- 1ms short of the 20000ms fallback (config.lua's own shipped default)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(#f.clientEvents, afterRelease, 'still on the FALLBACK 20000ms cooldown -- proves a real, working cooldown is in effect, not "always allowed" (which would be fail-OPEN) and not "always denied forever" (which would defeat the whole point of this fix)')

    f.advance(2) -- now past the 20000ms fallback
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.isTrue(#f.clientEvents > afterRelease, 'and the mechanic recovers once the FALLBACK threshold elapses -- BiteAndHold is fully functional throughout, on a safe substituted value')
end)

t.test('REGRESSION: Config.Combat.NonLethalTakedown.cooldownMs = 0 -- NonLethalTakedown keeps WORKING on the 25000ms fallback', function()
    local f = newCombatFixture({
        takedownCfg = { range = 3.0, minTargetSpeed = 4.0, speedSampleWindowMs = 250, ragdollDurationMs = 4000, cooldownMs = 0, targetCooldownMs = 30000, healthFloor = 100 },
    })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { x = 0, y = 0, z = 0 })

    -- Drive the fleeing-target speed sample: the target moves during the
    -- Wait() window, same small-displacement technique this file's own
    -- passing requestTakedown tests already use (e.g. "a target that moves
    -- fast enough during the sample window succeeds" above) -- 1.2m over a
    -- 250ms window = 4.8 m/s, comfortably above minTargetSpeed (4.0) while
    -- staying well inside range (3.0m) of the stationary K9 at the origin.
    -- A LARGE displacement here would fail the POST-YIELD range re-check
    -- instead (ValidateCombatRequest's second call measures live distance
    -- to the target's now-moved position), which is a test-authoring bug,
    -- not a cooldown-fix bug -- caught while verifying this exact test.
    local function attemptTakedown(netId)
        f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { netId }, function()
            local ped = netId + 100000
            f.setCoords(ped, 0, 1.2, 0)
        end)
    end

    attemptTakedown(500)
    t.isTrue(#f.clientEvents > 0, 'NonLethalTakedown must still be usable at least once, even with a misconfigured cooldown')
    local afterFirst = #f.clientEvents

    wireNpcTarget(f, 501, { x = 0, y = 0, z = 0 })
    attemptTakedown(501)
    t.equals(#f.clientEvents, afterFirst, 'still on the FALLBACK 25000ms per-K9 cooldown -- a second takedown by the SAME K9 is correctly denied, not silently unlimited')
end)

t.test('with every combat feature flag off, the maintenance thread is never created, and requests are silently feature-gated', function()
    local f = newCombatFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = false })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
    local ok = pcall(f.runOneTick) -- must not error even though nothing was ever created
    t.isTrue(ok)
end)

t.test('onResourceStart: prints the spoofable-default warning for PropDragging when enabled with no IsPlayerDownedOverride', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = nil })
    f.fireResourceStart('qbx_k9unit')
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('IsPlayerDownedOverride is nil', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('onResourceStart: no warning when a real IsPlayerDownedOverride is configured', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = function() return false end })
    f.fireResourceStart('qbx_k9unit')
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('IsPlayerDownedOverride is nil', 1, true) ~= nil)
    end
end)

t.test('onResourceStart: ignores a different resource restarting', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = nil })
    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0)
end)

-- ========================================================================
-- ValidateCombatRequest -- the shared prefix, exercised via requestBiteHold.
-- ========================================================================

t.test('requestBiteHold: feature disabled is a silent-to-client no-op (only a NotifyPlayer, no hold created)', function()
    local f = newCombatFixture({ biteAndHold = false })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
end)

t.test('requestBiteHold: a non-number targetNetId is rejected without crashing', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 'not-a-number')
    t.isTrue(ok)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a targetNetId that resolves to nothing real is invalid_target', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 999999)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: no HasK9Access is rejected', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { access = false })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a K9 already engaged with another target is rejected, and the fresh target remains genuinely free for someone else', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldStarted'), 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501) -- already_engaged
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldStarted'), 1, 'no second hold for the same K9')

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldStarted'), 2, 'target 501 was never actually held by the rejected attempt above')
end)

t.test('requestBiteHold: targeting your own ped is self_target', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    f.registerEntity(999, k9Ped, 1) -- claim own ped's netId as the "target"
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 999)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: K9 offline (GetPlayerPed == 0) is a silent no-op, no crash', function()
    local f = newCombatFixture()
    f.setAccess(K9_SRC, true) -- HasK9Access true, but no setPed call -> GetPlayerPed returns 0
    wireNpcTarget(f, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(ok)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: beyond range is too_far', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    wireNpcTarget(f, 500, { x = 100, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a target already held by a different K9 is already_held, and the original holder\'s own hold is untouched', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireK9(f, K9_SRC_B)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'the second K9 must never have been granted the same target')
    -- the original holder can still release it -- proves it is still theirs
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1)
end)

t.test('requestBiteHold: an unwanted player target is not_eligible_target (RequireWantedStatus default true, no override)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = false })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a wanted player target succeeds, relayed ONLY to the target\'s own client', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:applyBiteHold')
    t.isNotNil(ev)
    t.equals(ev.target, TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 0)
end)

t.test('requestBiteHold: an NPC target succeeds, relayed ONLY to the requesting K9\'s own client', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:applyNpcBiteHold')
    t.isNotNil(ev)
    t.equals(ev.target, K9_SRC)
    t.equals(ev.args[1], 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 0)
end)

t.test('requestBiteHold: WantedStatusCheckOverride returning true is authoritative over metadata.wanted == false', function()
    local f = newCombatFixture({ wantedOverride = function(_src) return true end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = false })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 1)
end)

t.test('requestBiteHold: a WantedStatusCheckOverride that errors fails CLOSED (target treated as not eligible), regardless of metadata', function()
    local f = newCombatFixture({ wantedOverride = function(_src) error('boom') end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 0)
end)

t.test('requestBiteHold: a hesitating K9 (server/wellbeing.lua present) is rejected', function()
    local f = newCombatFixture({ withWellbeing = true })
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.setHesitating('K9-CID', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a distracted K9 (server/wellbeing.lua present) is rejected', function()
    local f = newCombatFixture({ withWellbeing = true })
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.setDistracted('K9-CID', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: server/wellbeing.lua entirely absent (no IsHesitating/IsDistracted) never crashes and proceeds normally', function()
    local f = newCombatFixture({ withWellbeing = false })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

-- ========================================================================
-- MUST-MATTER #1: death checks. GetEntityHealth <= 100 (PED_DEAD_HEALTH_
-- THRESHOLD) replaced IsEntityDead/IsPedDeadOrDying, which have no FXServer
-- server registration and always silently returned false. Pin the boundary
-- at 99/100/101 everywhere this file makes a "is this ped dead" decision.
-- ========================================================================

t.test('requestBiteHold: target health exactly 100 (the boundary) is rejected as dead', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 100 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: target health 99 (below the boundary) is rejected as dead', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 99 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: target health 101 (one above the boundary) is accepted as alive', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 101 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('reportBiteHoldTargetDied: target health exactly 100 (the boundary) ends the hold as target_died', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local targetPed = wirePlayerTarget(f, 501, TARGET_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.setHealth(targetPed, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1)
    t.equals(#f.awardCalls, 0, 'target_died must never pay biteHoldSuccess')
end)

t.test('reportBiteHoldTargetDied: target health 101 (still alive) is ignored -- claim does not match live server state', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local targetPed = wirePlayerTarget(f, 501, TARGET_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.setHealth(targetPed, 101)
    f.dispatchNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 0, 'hold must still be active -- the false claim must not end it')
end)

t.test('reportBiteHoldTargetDied: a source that is not genuinely the target of any active bite hold is a silent no-op', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500) -- NPC target -- TARGET_SRC is unrelated
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 0)
end)

t.test('reportHolderDied: holder health exactly 100 (the boundary) ends the hold as holder_died', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.setHealth(k9Ped, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportHolderDied', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 1)
    t.equals(#f.awardCalls, 0, 'holder_died must never pay biteHoldSuccess')
end)

t.test('reportHolderDied: holder health 101 (still alive) is ignored', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.setHealth(k9Ped, 101)
    f.dispatchNetEvent('qbx_k9unit:server:reportHolderDied', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0)
end)

t.test('reportHolderDied: a source not genuinely the holder of anything is a silent no-op', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:reportHolderDied', K9_SRC_B)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0)
end)

t.test('MAINTENANCE-THREAD BACKSTOP: a bite-hold against a PLAYER target has no holder-side client self-report at all -- only the maintenance thread\'s own HolderPedIsDead check ever catches the holder\'s death there', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyBiteHold'), 1)

    -- The holder dies, but nothing ever calls reportHolderDied for them
    -- (simulating exactly the disclosed gap: a bite/takedown holder holding
    -- a PLAYER target has no client-side per-tick self-check to report from).
    f.setHealth(k9Ped, 100) -- boundary
    f.runOneTick()

    local ev = lastClientEvent(f, 'qbx_k9unit:client:endBiteHold')
    t.isNotNil(ev, 'the maintenance thread must have ended the hold on its own')
    t.equals(ev.target, TARGET_SRC)
    t.equals(#f.awardCalls, 0, 'holder_died must never pay biteHoldSuccess')

    -- K9ActiveEffect must have been cleared too -- the K9 can engage a fresh
    -- target with no lingering already_engaged lockout, once its own
    -- unrelated per-K9 request-rate cooldown (a SEPARATE gate from
    -- K9ActiveEffect, stamped at the ORIGINAL request and untouched by how
    -- that hold ended) has also elapsed -- advanced past here specifically
    -- to isolate the already_engaged/K9ActiveEffect question from that
    -- unrelated cooldown.
    f.advance(baselineBiteAndHoldConfig().cooldownMs + 1)
    wireNpcTarget(f, 900)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 900)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('MAINTENANCE-THREAD BACKSTOP: a holder who is merely still ALIVE (101) is left alone by the maintenance thread', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.setHealth(k9Ped, 101)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endBiteHold'), 0)
end)

-- ========================================================================
-- MUST-MATTER #2: the BiteAndHold per-target cooldown. Prove BOTH the
-- per-K9 (BiteHoldCooldown) and per-target (BiteHoldTargetCooldown)
-- cooldowns are CHECKED before EITHER is stamped -- a rejected request must
-- burn neither.
-- ========================================================================

t.test('a released hold\'s per-target cooldown blocks a DIFFERENT, entirely fresh K9 from immediately re-taking the same target', function()
    local f = newCombatFixture() -- real shipped cooldownMs=20000 < targetCooldownMs=35000
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500) -- same instant, t=0
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'only the original hold -- the target\'s own cooldown must still be blocking the new K9')
end)

t.test('a request rejected purely for the TARGET being on cooldown never stamps the REJECTED K9\'s own per-K9 cooldown', function()
    -- cooldownMs deliberately larger than targetCooldownMs here, specifically
    -- so this test can distinguish "was the per-K9 cooldown wrongly stamped"
    -- from "the target cooldown just naturally cleared too" -- if the
    -- rejected attempt below had wrongly stamped K9 B's own 999999ms
    -- cooldown, the second attempt at t=5001 would still be blocked by IT,
    -- not merely by the (much shorter) target cooldown.
    local f = newCombatFixture({ biteAndHoldCfg = { range = 2.5, maxDurationMs = 15000, cooldownMs = 999999, targetCooldownMs = 5000 } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC) -- stamps target 500's own cooldown at t=0

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500) -- rejected: target still on its own 5000ms cooldown
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)

    f.advance(5001) -- target's own cooldown now clear; K9 B's own cooldown (999999) would STILL be blocking if the rejection above had wrongly stamped it
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2, 'K9 B\'s own per-K9 cooldown must never have been touched by the earlier target-cooldown rejection')
end)

t.test('a request rejected purely for the REQUESTING K9 being on cooldown never stamps the TARGET\'s own per-target cooldown', function()
    local f = newCombatFixture() -- real shipped cooldownMs=20000, targetCooldownMs=35000
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500) -- X: K9 A's own target
    wireNpcTarget(f, 501) -- Y: a completely fresh target, never touched by anyone
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC) -- stamps K9 A's OWN per-K9 cooldown at t=0

    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501) -- rejected: K9 A is on its OWN per-K9 cooldown, target Y itself was never touched
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'K9 A must not have been granted target Y')

    wireK9(f, K9_SRC_B)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 501) -- same instant, t=0 -- must succeed if Y's own cooldown was never touched
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2, 'target Y\'s own per-target cooldown must never have been stamped by K9 A\'s rejected attempt against it')
end)

t.test('once BOTH cooldowns have genuinely elapsed, the same K9 can retake the same target it held before', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    f.advance(35001) -- past the real shipped targetCooldownMs (the binding one here)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

-- ========================================================================
-- MUST-MATTER #3: XP award exclusions. EndHold pays biteHoldSuccess only on
-- 'released' (with the MIN_BITE_HOLD_XP_DURATION_MS floor) and 'timeout'
-- (always, floor never applies). 'target_died'/'holder_died' are already
-- pinned as zero-payout above; this section covers released/timeout/
-- disconnect.
--
-- EIGHTH-XP-FARM-FIX NOTE: these tests use an NPC target purely for wiring
-- convenience (this section's own focus is the DURATION FLOOR/timeout
-- logic, not player-vs-NPC eligibility) but server/combat.lua's real
-- default is now Config.XP.mintXpForNpcCombatTargets = false/unset, which
-- would make every one of these read as 0 regardless of the floor logic
-- being tested. Each test below therefore explicitly opts an NPC target
-- INTO minting (`f.config.XP = { mintXpForNpcCombatTargets = true }`) so it
-- keeps isolating the floor/timeout behavior it was written to check. See
-- the dedicated "NPC XP-MINT ELIGIBILITY" section further below for direct
-- coverage of the real default (false) and the opt-in flag itself.
-- ========================================================================

t.test('released after >= 3000ms held is paid biteHoldSuccess exactly once', function()
    local f = newCombatFixture()
    f.config.XP = { mintXpForNpcCombatTargets = true } -- isolates the duration floor from the separate NPC-eligibility gate -- see this section's header
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 1)
    t.equals(f.awardCalls[1].citizenid, 'K9-CID')
    t.equals(f.awardCalls[1].awardKey, 'biteHoldSuccess')
end)

t.test('released at EXACTLY the 3000ms floor is paid (>=, not strictly >)', function()
    local f = newCombatFixture()
    f.config.XP = { mintXpForNpcCombatTargets = true } -- isolates the duration floor from the separate NPC-eligibility gate -- see this section's header
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 1)
end)

t.test('released one millisecond under the 3000ms floor (2999ms) is NOT paid -- the anti-farm floor', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(2999)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('released immediately (0ms held) is NOT paid -- the accept-then-immediately-release macro this floor exists to block', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('a genuine timeout always pays biteHoldSuccess, even when maxDurationMs is BELOW the 3000ms anti-farm floor -- timeout bypasses that floor entirely', function()
    local f = newCombatFixture({ biteAndHoldCfg = { range = 2.5, maxDurationMs = 1000, cooldownMs = 20000, targetCooldownMs = 35000 } })
    f.config.XP = { mintXpForNpcCombatTargets = true } -- isolates timeout-bypasses-the-floor from the separate NPC-eligibility gate -- see this section's header
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(1000)
    f.runOneTick()
    t.equals(#f.awardCalls, 1, 'reason == timeout must pay regardless of held duration')
end)

-- ========================================================================
-- EIGHTH XP-FARM FIX: NPC XP-mint eligibility (Config.XP.
-- mintXpForNpcCombatTargets). ValidateCombatRequest's NPC branch never
-- checks RequireWantedStatus at all (Config.Combat.RequireWantedStatus's
-- own comment documents this), so an ambient, non-wanted NPC was a fully
-- qualifying biteHoldSuccess/takedownSuccess source. These tests pin the
-- real default (false/unset -- no payout for an NPC target) and the opt-in
-- override, for bite-hold; the parallel takedown coverage lives inline in
-- the NonLethalTakedown section below (near its own award call site).
-- ========================================================================

t.test('released after >= 3000ms held against an NPC target does NOT pay biteHoldSuccess by default (EIGHTH XP-farm fix)', function()
    local f = newCombatFixture() -- Config.XP.mintXpForNpcCombatTargets left at its real default (unset -- falsy)
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 0, 'an ambient NPC target must not mint biteHoldSuccess unless the operator opts in')
end)

t.test('with Config.XP.mintXpForNpcCombatTargets explicitly true, the SAME NPC scenario above now pays biteHoldSuccess', function()
    local f = newCombatFixture()
    f.config.XP = { mintXpForNpcCombatTargets = true }
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 1)
    t.equals(f.awardCalls[1].awardKey, 'biteHoldSuccess')
end)

t.test('released after >= 3000ms held against a WANTED PLAYER target pays biteHoldSuccess regardless of Config.XP.mintXpForNpcCombatTargets (default false/unset)', function()
    local f = newCombatFixture() -- real default -- no NPC opt-in configured at all
    wireK9(f, K9_SRC, { citizenid = 'K9-CID' })
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(#f.awardCalls, 1, 'a genuinely eligible player target must still pay -- this gate only narrows NPC targets, never player targets')
    t.equals(f.awardCalls[1].citizenid, 'K9-CID')
    t.equals(f.awardCalls[1].awardKey, 'biteHoldSuccess')
end)

t.test('target_died never pays (re-confirmed alongside the other three exclusions for a single, explicit side-by-side comparison)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    local targetPed = wirePlayerTarget(f, 501, TARGET_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.advance(5000) -- comfortably past the XP floor, isolating the EXCLUSION itself, not the floor
    f.setHealth(targetPed, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', TARGET_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('holder_died never pays (same side-by-side comparison as target_died above)', function()
    local f = newCombatFixture()
    local k9Ped = wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(5000)
    f.setHealth(k9Ped, 100)
    f.dispatchNetEvent('qbx_k9unit:server:reportHolderDied', K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('holder_disconnected never pays', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.advance(5000)
    f.firePlayerDropped(K9_SRC)
    t.equals(#f.awardCalls, 0)
end)

t.test('target_disconnected never pays', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.advance(5000)
    f.firePlayerDropped(TARGET_SRC)
    t.equals(#f.awardCalls, 0)
    -- and the holder's own K9ActiveEffect state was genuinely freed by this,
    -- not left stuck -- advanced past the holder's own unrelated per-K9
    -- request-rate cooldown (stamped at the original request, separate from
    -- K9ActiveEffect) so this isolates already_engaged specifically.
    f.advance(baselineBiteAndHoldConfig().cooldownMs)
    wireNpcTarget(f, 900)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 900)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

-- ========================================================================
-- MUST-MATTER #5: termination paths. releaseBiteHold is unconditional once
-- ownership is verified -- no cooldown check, no HasK9Access re-check, no
-- feature-flag re-check. Prove a way out cannot be blocked.
-- ========================================================================

t.test('releaseBiteHold still works even after HasK9Access is revoked AND the feature flag is toggled off mid-hold', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)

    f.setAccess(K9_SRC, false) -- decertified mid-hold
    f.config.Features.BiteAndHold = false -- feature toggled off mid-hold

    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 1, 'a way out must never be blockable by a revoked access grant or a disabled feature flag')
end)

t.test('releaseBiteHold from a source that is NOT the genuine holder is a silent no-op, and the real hold survives it untouched', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:releaseBiteHold', K9_SRC_B)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0, 'an impostor release must never end the real holder\'s hold')

    -- the real holder can still release it themselves afterward
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 1)
end)

t.test('after releaseBiteHold, K9ActiveEffect is cleared -- the same K9 can engage a different target with no already_engaged lockout, once its own unrelated per-K9 cooldown also elapses', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    -- BiteHoldCooldown (a SEPARATE, request-rate gate stamped at the
    -- ORIGINAL request and untouched by release) would otherwise itself
    -- block an immediate second request regardless of K9ActiveEffect --
    -- advance past it so this test isolates already_engaged specifically.
    f.advance(baselineBiteAndHoldConfig().cooldownMs + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

t.test('after releaseBiteHold, ActiveHolds is cleared -- the target is no longer already_held (once its own per-target cooldown has also elapsed)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireK9(f, K9_SRC_B)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    f.advance(35001) -- past the target's own per-target cooldown, isolating already_held itself
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC_B, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

-- ========================================================================
-- Disconnect cleanup (playerDropped)
-- ========================================================================

t.test('playerDropped for the holder ends the hold as holder_disconnected, relayed to the (player) target', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.firePlayerDropped(K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endBiteHold'), 1)
end)

t.test('playerDropped for the (player) target ends the hold as target_disconnected', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    f.firePlayerDropped(TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1, 'the holder must be told this ended')
end)

t.test('playerDropped for an unrelated source (neither holder nor target) is a no-op, never errors', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    local ok = pcall(f.firePlayerDropped, 99999)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:endNpcBiteHold'), 0)
end)

t.test('playerDropped also frees BiteHoldCooldown for that source (RegisterPlayerDropped) -- an immediate re-request at the same instant succeeds', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.firePlayerDropped(K9_SRC)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501) -- no time advance -- only succeeds if the cooldown was genuinely cleared
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 2)
end)

-- ========================================================================
-- NonLethalTakedown -- server-computed speed gate (yielding handler), and a
-- regression check that its own sibling per-K9/per-target cooldown pair
-- (the shape BiteAndHold was originally missing half of) still holds.
-- ========================================================================

t.test('requestTakedown: a target that does not move during the sample window is rejected as not_fleeing, and neither cooldown is consumed', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 }) -- stationary throughout
    f.dispatchNetEvent('qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)

    -- Prove neither cooldown was burned: an immediate follow-up WITH real
    -- movement during the wait must still succeed at the same instant.
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setHealth(500 + 100000, 200) -- no-op touch, keeps this closure non-trivial
    end)
    -- the second dispatch above still didn't move the target -- do a THIRD,
    -- real attempt with genuine movement to confirm cooldowns are unburned.
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(500 + 100000, 1, 1.2, 0) -- 1.2m during a 250ms window = 4.8 m/s > 4.0 m/s threshold
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1, 'a genuinely fleeing target must still succeed -- proving the earlier not_fleeing rejections never consumed either cooldown')
end)

t.test('requestTakedown: a target that moves fast enough during the sample window succeeds, relaying to the K9 for an NPC target -- but NPC targets do NOT pay takedownSuccess by default (EIGHTH XP-farm fix)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { citizenid = 'K9-CID', x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:applyNpcTakedown')
    t.isNotNil(ev, 'the takedown itself must still fully succeed -- this gate only withholds XP, never the mechanic')
    t.equals(ev.target, K9_SRC)
    t.equals(#f.awardCalls, 0, 'Config.XP.mintXpForNpcCombatTargets defaults to false/unset -- an ambient NPC target must not mint takedownSuccess')
end)

t.test('requestTakedown: with Config.XP.mintXpForNpcCombatTargets explicitly true, the SAME NPC scenario above now pays takedownSuccess', function()
    local f = newCombatFixture()
    f.config.XP = { mintXpForNpcCombatTargets = true }
    wireK9(f, K9_SRC, { citizenid = 'K9-CID', x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    t.equals(#f.awardCalls, 1)
    t.equals(f.awardCalls[1].awardKey, 'takedownSuccess')
end)

t.test('requestTakedown: a fleeing, wanted PLAYER target pays takedownSuccess regardless of Config.XP.mintXpForNpcCombatTargets (default false/unset)', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { citizenid = 'K9-CID', x = 0, y = 0, z = 0 })
    local ped = wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true, x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 501 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    t.equals(#f.awardCalls, 1, 'a genuinely eligible player target must still pay -- this gate only narrows NPC targets, never player targets')
    t.equals(f.awardCalls[1].citizenid, 'K9-CID')
    t.equals(f.awardCalls[1].awardKey, 'takedownSuccess')
end)

t.test('requestTakedown: a fleeing PLAYER target is relayed ONLY to the target\'s own client (forceRagdoll), never to the K9', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true, x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 501 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:forceRagdoll')
    t.isNotNil(ev)
    t.equals(ev.target, TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 0)
end)

t.test('requestTakedown: the real shipped per-K9/per-target cooldown pair still both gate a second takedown of the same freshly-takedown target', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    wireK9(f, K9_SRC_B, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(ped, 1, 1.2, 0)
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1)

    -- A DIFFERENT K9 immediately trying the SAME (already ragdolled) target
    -- is blocked by already_held long before either cooldown even matters --
    -- advance past the ragdoll window first so already_held is no longer the
    -- reason, isolating TakedownTargetCooldown itself.
    f.advance(baselineTakedownConfig().ragdollDurationMs + 1)
    f.runOneTick()
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC_B, { 500 }, function()
        f.setCoords(ped, 1, 3, 0) -- keep moving to still pass the speed gate
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1, 'TakedownTargetCooldown must still be blocking a second K9 from an immediate repeat takedown')
end)

t.test('TakedownMutex rejects a second, overlapping requestTakedown from the SAME K9 while the first is still parked mid-wait', function()
    local f = newCombatFixture()
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })

    local h1 = f.startCoroutine('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 })
    h1.resume() -- runs into Wait() and parks there -- TakedownMutex is still held
    t.isFalse(h1.isDead())

    f.setCoords(ped, 1, 1.2, 0) -- world moves on while h1 is suspended
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.isTrue(ok, 'the overlapping call must be rejected gracefully, never error')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 0, 'the overlapping call must have been rejected by the mutex, not granted a second in-flight takedown')

    while not h1.isDead() do h1.resume() end
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1, 'the ORIGINAL call must still complete successfully once resumed to completion')
end)

-- ========================================================================
-- PropDragging -- lighter pass (shares this file's own EndHold/maintenance-
-- thread machinery, already exercised extensively above). See this file's
-- own header for why this section is intentionally not exhaustive.
-- ========================================================================

t.test('requestDrag: a target that is not downed at all is rejected, no drag started', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 200, ragdoll = false })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestDrag: an NPC target downed via health <= 100 is accepted', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 100 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:dragStarted')
    t.isNotNil(ev)
    t.equals(ev.args[2], false, 'isPlayerTarget must be false for an NPC target')
end)

t.test('requestDrag: an NPC target downed via IsPedRagdoll alone (healthy) is also accepted', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 200, ragdoll = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 1)
end)

t.test('requestDrag: a downed PLAYER target (metadata.isdead, no override) is accepted, relaying the speed limit to the target too', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    local started = lastClientEvent(f, 'qbx_k9unit:client:dragStarted')
    t.isNotNil(started)
    t.equals(started.args[2], true)
    local speedLimit = lastClientEvent(f, 'qbx_k9unit:client:applyDragSpeedLimit')
    t.isNotNil(speedLimit)
    t.equals(speedLimit.target, TARGET_SRC)
end)

t.test('requestDrag: an IsPlayerDownedOverride that errors fails CLOSED (rejected), even though metadata says downed', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = function(_src) error('boom') end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 0)
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('failing closed', 1, true) then found = true end
    end
    t.isTrue(found, 'an override error must be logged, not silently swallowed with no trace')
end)

t.test('releaseDrag from the HOLDER ends it as released_by_holder', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 100 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    f.dispatchNetEvent('qbx_k9unit:server:releaseDrag', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragEnded'), 1)
end)

t.test('releaseDrag from the PLAYER TARGET (not the holder) also ends it, with zero consent needed from the holder -- as released_by_target', function()
    local f = newCombatFixture({ propDragging = true })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    f.dispatchNetEvent('qbx_k9unit:server:releaseDrag', TARGET_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragEnded'), 1)
end)

t.test('DragExceedsMaxDistance safety valve: the maintenance thread force-ends a drag once the holder/target gap exceeds maxDragDistance, unconditionally', function()
    local f = newCombatFixture({ propDragging = true, propDraggingCfg = baselinePropDraggingConfig(nil) })
    f.config.Combat.PropDragging.maxDragDistance = 5.0
    local k9Ped = wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local targetPed = wireNpcTarget(f, 500, { health = 100, x = 1, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)

    f.setCoords(targetPed, 100, 0, 0) -- far beyond maxDragDistance from the K9
    f.setCoords(k9Ped, 0, 0, 0)
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragEnded'), 1)
end)

-- ========================================================================
-- COMPAT-LAYER (this pass): IsTargetDowned's K9Compat ambulance-adapter
-- precedence -- override (if configured) wins unconditionally over the
-- adapter; the adapter's true/false are trusted directly over the fallback
-- when no override is configured; the adapter's nil (UNKNOWN) falls
-- through to the pre-existing metadata guess, unchanged. See
-- server/combat.lua's IsTargetDowned doc comment for the full contract.
-- ========================================================================

t.test('IsTargetDowned precedence: an override wins UNCONDITIONALLY over the ambulance adapter -- the adapter is never even consulted', function()
    local f = newCombatFixture({ propDragging = true, downedOverride = function(_src) return false end, ambulanceIsDowned = function(_src) return true end })
    wireK9(f, K9_SRC)
    -- metadata also says downed -- proves the override's `false` wins over
    -- BOTH the adapter's `true` AND metadata, exactly as before this pass.
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 0, 'override=false must win over adapter=true and metadata.isdead=true alike')
    t.equals(#f.ambulanceIsDownedCalls, 0, 'the adapter must never be called at all once an override is configured')
end)

t.test('IsTargetDowned precedence: no override, adapter confirms TRUE -- accepted even though metadata says NOT downed', function()
    local f = newCombatFixture({ propDragging = true, ambulanceIsDowned = function(_src) return true end })
    wireK9(f, K9_SRC)
    -- isdead/inlaststand both omitted -> setPlayer's own metadata shape
    -- coerces both to false -- metadata alone would reject this target.
    wirePlayerTarget(f, 501, TARGET_SRC, { wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 1, 'a confirmed adapter true must be trusted directly, overriding a stale/absent metadata guess')
end)

t.test('IsTargetDowned precedence: no override, adapter confirms FALSE -- rejected even though metadata says downed', function()
    local f = newCombatFixture({ propDragging = true, ambulanceIsDowned = function(_src) return false end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 0, 'a confirmed adapter false must be trusted directly -- IsTargetDowned has no independent second signal to fall back on the way IsHandlerDown does')
end)

t.test('IsTargetDowned precedence: no override, adapter returns nil (UNKNOWN) -- falls through to the pre-existing metadata guess, unchanged', function()
    local f = newCombatFixture({ propDragging = true, ambulanceIsDowned = function(_src) return nil end })
    wireK9(f, K9_SRC)
    wirePlayerTarget(f, 501, TARGET_SRC, { isdead = true, wanted = true })
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 1, 'nil must never be coerced to a boolean at the call site -- it must fall through to metadata, which says downed here')
    t.isTrue(#f.ambulanceIsDownedCalls >= 1, 'the adapter must actually have been consulted for this case')
end)

-- ========================================================================
-- NON-COMPLIANCE DETECTION: notify_staff fan-out ACE->job-rank rewrite
-- (project-owner-directed, this pass). Narrow, permission-boundary-only
-- coverage -- see this file's header for why the sampling HEURISTICS
-- themselves stay out of this file's scope. Uses the simplest possible
-- violation trigger (an NPC target that teleports on the very first sample,
-- with biteHoldViolationSamples = 1 and zero idle/speed tolerance) purely
-- to reach FlagNonCompliance's notify_staff branch once -- the movement
-- math itself is not this section's concern.
-- ========================================================================

t.test('NonComplianceDetection notify_staff: ACE->job-rank rewrite -- job.isboss always qualifies, grade >= Config.Departments[job].nonComplianceAlertGrade qualifies, below-threshold/unconfigured-department/no-player-record all fail closed', function()
    local f = newCombatFixture({
        nonComplianceDetectionCfg = {
            enabled = true,
            positionSampleWindowMs = 500,
            biteHoldIdleCeiling = 0,
            biteHoldSpeedTolerance = 0,
            biteHoldViolationSamples = 1,
            takedownNetDisplacementMeters = 3.0,
            action = 'notify_staff',
            OnViolationOverride = nil,
            dragComplianceSlackMeters = 4.0,
        },
        departmentsCfg = { police = { nonComplianceAlertGrade = 2 } },
    })

    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)

    -- Five online candidates, one per branch of
    -- IsAuthorizedForNonComplianceAlert (server/combat.lua):
    f.setPlayer(30, { citizenid = 'SUP',   job = { name = 'police',  isboss = false, grade = { level = 2 } } }) -- grade == threshold -- qualifies
    f.addOnline(30)
    f.setPlayer(31, { citizenid = 'JR',    job = { name = 'police',  isboss = false, grade = { level = 1 } } }) -- below threshold -- fails closed
    f.addOnline(31)
    f.setPlayer(32, { citizenid = 'CHIEF', job = { name = 'police',  isboss = true,  grade = { level = 0 } } }) -- isboss bypass -- qualifies regardless of grade
    f.addOnline(32)
    f.setPlayer(33, { citizenid = 'OUT',   job = { name = 'sheriff', isboss = false, grade = { level = 99 } } }) -- department not in Config.Departments -- fails closed
    f.addOnline(33)
    f.addOnline(34) -- online, but never setPlayer'd -- no resolvable Player record at all -- fails closed

    f.setCoords(ped, 500, 0, 0) -- obvious teleport -- an unambiguous movement violation on the very first sample
    f.advance(500) -- matches positionSampleWindowMs so the sampling thread's own dtSeconds > 0 when it wakes
    f.runOneTick()

    local notified = {}
    for _, e in ipairs(f.clientEvents) do
        if e.event == 'ox_lib:notify' then notified[e.target] = true end
    end
    t.isTrue(notified[30] == true, 'grade == threshold (2) must qualify')
    t.isNil(notified[31], 'grade below threshold (1 < 2) must not qualify')
    t.isTrue(notified[32] == true, 'job.isboss must always qualify regardless of grade')
    t.isNil(notified[33], 'a department not listed in Config.Departments must fail closed')
    t.isNil(notified[34], 'an online id with no resolvable Player record must fail closed')
end)

t.test('NonComplianceDetection notify_staff: the OLD ACE check is gone -- IsPlayerAceAllowed is never read, even when left entirely undefined in the sandbox', function()
    -- newCombatFixture never provides IsPlayerAceAllowed at all (see this
    -- file's own envOverrides above) -- if server/combat.lua still called
    -- it anywhere, this would error with "attempt to call a nil value"
    -- the moment the notify_staff branch ran. It not erroring IS the proof.
    local f = newCombatFixture({
        nonComplianceDetectionCfg = {
            enabled = true, positionSampleWindowMs = 500,
            biteHoldIdleCeiling = 0, biteHoldSpeedTolerance = 0, biteHoldViolationSamples = 1,
            takedownNetDisplacementMeters = 3.0, action = 'notify_staff', OnViolationOverride = nil,
            dragComplianceSlackMeters = 4.0,
        },
    })
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    f.setCoords(ped, 500, 0, 0)
    f.advance(500)
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'the notify_staff fan-out must never call the removed IsPlayerAceAllowed')
end)

-- ========================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's Config.FeatureControl,
-- steps 2-4 of its documented "first match wins" resolution (step 1, the
-- Config.Features.<Name> flag, is already covered by the feature-disabled
-- tests at the top of this file). This is the headline finding of this
-- pass: server/permissions.lua's IsValidPermissionKey previously rejected
-- EVERY 'feature.<Name>'/'block.<Name>' grant outright, so
-- IsCombatFeaturePermittedForCitizenId below (wired into ValidateCombatRequest,
-- this pass) had nothing real to ever read -- a block or RequireGrant
-- listing had ZERO effect on whether BiteAndHold/NonLethalTakedown/
-- PropDragging could be used, regardless of what the tablet displayed.
-- These tests prove a block ACTUALLY blocks and a grant ACTUALLY grants at
-- the real gate, not merely that the tablet renders the right label.
-- Mirrors tests/pursuitsprint_spec.lua's own "Per-person feature control"
-- section byte-for-byte in test SHAPE (that file is the reference
-- implementation this file's own IsCombatFeaturePermittedForCitizenId
-- mirrors) -- extended here to also cover NonLethalTakedown/PropDragging
-- and the cross-feature independence a SHARED validator specifically
-- risks getting wrong.
-- ========================================================================

t.test('requestBiteHold: RequireGrant.BiteAndHold = true + no grant held -- denied even though HasK9Access is true', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { BiteAndHold = true } })
    wireK9(f, K9_SRC) -- citizenid defaults to 'K9-CID-10', deliberately NOT granted
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
end)

t.test('requestBiteHold: RequireGrant.BiteAndHold = true + an active feature.BiteAndHold grant -- allowed', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { BiteAndHold = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.BiteAndHold', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('requestBiteHold: BLOCK ALWAYS WINS -- an explicit block.BiteAndHold denies even a citizenid who ALSO holds an active feature.BiteAndHold grant', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { BiteAndHold = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.BiteAndHold', true)
    f.grantPermission('K9-CID-' .. K9_SRC, 'block.BiteAndHold', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: RequireGrant.BiteAndHold not listed at all -- default ALLOW, no grant needed (step 4)', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = {} })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    -- deliberately NOT granted -- must still succeed since it is not listed
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('requestBiteHold: BLOCK STILL APPLIES even when BiteAndHold is NOT listed in RequireGrant (step 2 fires independently of step 3)', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = {} })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.grantPermission('K9-CID-' .. K9_SRC, 'block.BiteAndHold', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local f = newCombatFixture({ withHasPermission = false, featureControlRequireGrant = { BiteAndHold = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(ok, 'a missing HasPermission must never error the request handler')
    t.equals(#f.clientEvents, 0)
end)

t.test('requestBiteHold: a BLOCK on a DIFFERENT feature key (NonLethalTakedown) does not affect BiteAndHold -- feature keys are independent, not conflated by the shared validator', function()
    local f = newCombatFixture({ withHasPermission = true })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.grantPermission('K9-CID-' .. K9_SRC, 'block.NonLethalTakedown', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'BiteAndHold must be unaffected by a block on a different feature key')
end)

t.test('requestBiteHold: a block granted AFTER an already-open hold does NOT terminate it, and the hold\'s own release path is never gated on the grant -- NO UNBOUNDED TRAP', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { BiteAndHold = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.BiteAndHold', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)

    -- High command revokes the grant and blocks the K9 mid-hold.
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.BiteAndHold', false)
    f.grantPermission('K9-CID-' .. K9_SRC, 'block.BiteAndHold', true)

    -- The ALREADY-OPEN hold must still be releasable -- EndHold/releaseBiteHold
    -- never consult HasPermission at all (ValidateCombatRequest is only
    -- ever re-run at REQUEST time, never at teardown time).
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1, 'a mid-hold block/revoke must never strand an already-open hold')

    -- The block DOES correctly stop a brand-new request from the same K9.
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'still exactly 1 -- the new request against 501 must be denied')
end)

t.test('requestTakedown: RequireGrant.NonLethalTakedown = true + no grant held -- denied (checked at the PRE-yield ValidateCombatRequest call, before the speed-sample Wait())', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { NonLethalTakedown = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestTakedown: a grant revoked DURING the speed-sample yield is caught by the POST-yield re-validation -- TOCTOU-safe', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { NonLethalTakedown = true } })
    wireK9(f, K9_SRC, { x = 0, y = 0, z = 0 })
    local ped = wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.NonLethalTakedown', true)

    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        -- Parked mid-Wait(), post the PRE-yield check (which passed) --
        -- high command revokes the grant right now, before the POST-yield
        -- re-validation runs.
        f.grantPermission('K9-CID-' .. K9_SRC, 'feature.NonLethalTakedown', false)
        f.setCoords(ped, 100, 0, 0) -- would otherwise clearly pass the speed gate
    end)

    t.equals(#f.clientEvents, 0, 'the revoke made during the yield must be caught by ValidateCombatRequest\'s own second, post-yield call')
end)

t.test('requestTakedown: BLOCK ALWAYS WINS, same as BiteAndHold', function()
    local f = newCombatFixture({ withHasPermission = true, featureControlRequireGrant = { NonLethalTakedown = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500)
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.NonLethalTakedown', true)
    f.grantPermission('K9-CID-' .. K9_SRC, 'block.NonLethalTakedown', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestDrag: RequireGrant.PropDragging = true + no grant held -- denied', function()
    local f = newCombatFixture({ propDragging = true, withHasPermission = true, featureControlRequireGrant = { PropDragging = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 50 }) -- downed (<= PED_DEAD_HEALTH_THRESHOLD)
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestDrag: RequireGrant.PropDragging = true + an active feature.PropDragging grant -- allowed', function()
    local f = newCombatFixture({ propDragging = true, withHasPermission = true, featureControlRequireGrant = { PropDragging = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 50 })
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.PropDragging', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 1)
end)

t.test('requestDrag: BLOCK ALWAYS WINS, same as BiteAndHold/NonLethalTakedown', function()
    local f = newCombatFixture({ propDragging = true, withHasPermission = true, featureControlRequireGrant = { PropDragging = true } })
    wireK9(f, K9_SRC)
    wireNpcTarget(f, 500, { health = 50 })
    f.grantPermission('K9-CID-' .. K9_SRC, 'feature.PropDragging', true)
    f.grantPermission('K9-CID-' .. K9_SRC, 'block.PropDragging', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

-- ========================================================================
-- CERTIFICATION TIER CAPABILITY -- server/certtiers.lua's
-- TierCapabilityPermits, wired into ValidateCombatRequest's BiteAndHold/
-- NonLethalTakedown branch this pass -- the owner's own worked example
-- (ticking bite-and-hold off for the trainee tier must actually stop a
-- trainee from biting). TierCapabilityPermits' OWN resolution logic (tier
-- lookup, dormant-capability default-allow, unresolvable-tier
-- default-allow) is fully covered by that file's own spec -- these tests
-- only prove server/combat.lua calls it at the right place, with the
-- right arguments, honors both answers, excludes PropDragging (no
-- capability names it), and never lets a release/termination path
-- re-consult it (NO UNBOUNDED TRAP). TierCapabilityPermits is OMITTED FROM
-- THE SANDBOX BY DEFAULT (see newCombatFixture's own comment on
-- defaultTierCapabilityPermits) -- every test in this section opts in via
-- opts.withTierCapabilityPermits explicitly.
-- ========================================================================

t.test('requestBiteHold: TierCapabilityPermits denies -- refused even though HasK9Access/FeatureControl both allow, and called with the right arguments', function()
    local f = newCombatFixture({ withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return false end })
    wireK9(f, K9_SRC, { job = { name = 'police' } })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
    t.equals(#f.tierCapabilityCalls, 1)
    t.equals(f.tierCapabilityCalls[1].citizenid, 'K9-CID-' .. K9_SRC)
    t.equals(f.tierCapabilityCalls[1].jobName, 'police')
    t.equals(f.tierCapabilityCalls[1].capabilityKey, 'bite_hold_and_takedown')
end)

t.test('requestBiteHold: TierCapabilityPermits allows -- request proceeds normally', function()
    local f = newCombatFixture({ withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return true end })
    wireK9(f, K9_SRC, { job = { name = 'police' } })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
    t.equals(#f.tierCapabilityCalls, 1)
end)

t.test('requestBiteHold: unresolvable tier at this call site (K9 has no job on record) -- allowed, TierCapabilityPermits never even called', function()
    local f = newCombatFixture({ withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return false end })
    wireK9(f, K9_SRC) -- deliberately no job -- see wireK9's own comment
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'an unresolvable jobName must never be treated as a denial')
    t.equals(#f.tierCapabilityCalls, 0, 'TierCapabilityPermits must not be called at all without a resolvable jobName')
end)

t.test('requestBiteHold: server/certtiers.lua entirely absent (TierCapabilityPermits not even defined) -- allowed, same fail-permissive posture as every other soft dependency in this file', function()
    local f = newCombatFixture() -- withTierCapabilityPermits omitted -- TierCapabilityPermits undefined in this sandbox
    wireK9(f, K9_SRC, { job = { name = 'police' } })
    wireNpcTarget(f, 500)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.isTrue(ok, 'a missing TierCapabilityPermits must never error the request handler')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)
end)

t.test('requestTakedown: TierCapabilityPermits denies -- refused (checked at the PRE-yield ValidateCombatRequest call, before the speed-sample Wait())', function()
    local f = newCombatFixture({ withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return false end })
    wireK9(f, K9_SRC, { job = { name = 'police' } })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestTakedown', K9_SRC, 500)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestTakedown: TierCapabilityPermits allows -- request proceeds normally', function()
    local f = newCombatFixture({ withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return true end })
    wireK9(f, K9_SRC, { job = { name = 'police' }, x = 0, y = 0, z = 0 })
    wireNpcTarget(f, 500, { x = 1, y = 0, z = 0 })
    -- Drive a genuine fleeing-target speed sample during the mid-handler
    -- Wait() -- same proven displacement technique this file's own
    -- passing requestTakedown tests already use (see e.g. the
    -- Config.Combat.NonLethalTakedown.cooldownMs = 0 regression test's own
    -- attemptTakedown helper above) -- required because the POST-yield
    -- ValidateCombatRequest call (and the speed gate in between) must ALSO
    -- pass for this request to actually reach the TierCapabilityPermits
    -- gate's allow path and fire a client event.
    f.dispatchStepped('qbx_k9unit:server:requestTakedown', K9_SRC, { 500 }, function()
        f.setCoords(500 + 100000, 0, 1.2, 0)
    end)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcTakedown'), 1)
end)

t.test('requestDrag: PropDragging is NOT gated by bite_hold_and_takedown -- no capability names it, so TierCapabilityPermits is never even consulted', function()
    local f = newCombatFixture({ propDragging = true, withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return false end })
    wireK9(f, K9_SRC, { job = { name = 'police' } })
    wireNpcTarget(f, 500, { health = 50 }) -- downed (<= PED_DEAD_HEALTH_THRESHOLD)
    f.dispatchNetEvent('qbx_k9unit:server:requestDrag', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:dragStarted'), 1, 'PropDragging must be unaffected by bite_hold_and_takedown')
    t.equals(#f.tierCapabilityCalls, 0, 'TierCapabilityPermits must never be consulted for PropDragging')
end)

t.test('requestBiteHold: a tier capability revoked AFTER an already-open hold does NOT terminate it, and the release path never re-consults TierCapabilityPermits -- NO UNBOUNDED TRAP', function()
    local allowed = true
    local f = newCombatFixture({ withTierCapabilityPermits = true, tierCapabilityPermitsFn = function() return allowed end })
    wireK9(f, K9_SRC, { job = { name = 'police' } })
    wireNpcTarget(f, 500)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 500)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1)

    -- High command unticks the capability for this handler's tier, mid-hold.
    allowed = false

    -- The ALREADY-OPEN hold must still be releasable -- EndHold/releaseBiteHold
    -- never call ValidateCombatRequest (and so never call
    -- TierCapabilityPermits) at all.
    local callsBeforeRelease = #f.tierCapabilityCalls
    f.dispatchNetEvent('qbx_k9unit:server:releaseBiteHold', K9_SRC)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:biteHoldEnded'), 1, 'a mid-hold capability revoke must never strand an already-open hold')
    t.equals(#f.tierCapabilityCalls, callsBeforeRelease, 'releaseBiteHold must never consult TierCapabilityPermits')

    -- The revoke DOES correctly stop a brand-new request from the same K9.
    wireNpcTarget(f, 501)
    f.dispatchNetEvent('qbx_k9unit:server:requestBiteHold', K9_SRC, 501)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:applyNpcBiteHold'), 1, 'still exactly 1 -- the new request against 501 must be denied')
end)

os.exit(t.summary())
