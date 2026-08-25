--[[
    tests/kennel_spec.lua

    Direct tests of server/kennel.lua's four RegisterNetEvent handlers
    (requestDeployKennel / confirmKennelPlaced / cancelKennelPlacement /
    requestPickupKennel) plus its playerDropped/onResourceStop cleanup,
    against the REAL, unmodified production file -- loaded alongside the
    real server/cooldowns.lua and server/entities.lua per that file's own
    FILE-TO-FILE CONTRACT (DeployCooldown is a real NewCooldown() tracker,
    every ResolveNetworkEntity call is the real resolve+existence-guard
    primitive, not a reimplementation of either). HasK9Access and
    NotifyPlayer are stubbed directly -- both are genuinely OTHER files'
    own logic, already covered by their own specs
    (server/certifications.lua, server/notify.lua/notify_spec.lua) -- this
    file's job is server/kennel.lua's own handshake/lifecycle logic, not a
    second copy of those.

    locale() is NEVER stubbed (per this suite's own convention) -- every
    call below that reaches a NotifyPlayer(..., locale('kennel.xxx'), ...)
    call evaluates that locale() argument for real, against the real
    locales/en.json, before this file's own NotifyPlayer stub ever sees the
    result. A locale key server/kennel.lua references that went missing
    from en.json would raise loudly here, exactly like every other spec in
    this suite.

    ONE FRESH SANDBOX PER TEST (never shared) -- unlike entities_spec.lua's
    stateless ResolveNetworkEntity, `Kennels` and `PendingKennelPlacements`
    are `local` upvalues alive for this whole loaded file's lifetime, so
    reusing one sandbox across unrelated test cases would let one test's
    pending/active-kennel state leak into the next. newKennelFixture()
    below builds one complete, independent world (its own Config, its own
    captured net-event/AddEventHandler tables, its own entity/ped/coords
    registries) for every single t.test() call.

    ======================================================================
    HISTORY -- A REAL, LIVE-CAUGHT CONCURRENT EDIT DURING THIS SPEC'S OWN
    AUTHORING, RECORDED HONESTLY RATHER THAN SILENTLY REWRITTEN:

    server/kennel.lua was being edited by another agent WHILE this spec was
    written, per this task's own warning. The FIRST read of that file (this
    spec's initial draft) showed confirmKennelPlaced with exactly the class
    of bug a sibling audit had just flagged in server/fetch.lua and
    server/propattachment.lua: THREE re-validation rejections deep inside
    confirmKennelPlaced (a feature-flag toggle, a certification revoke, and
    the "shouldn't be reachable" Kennels[citizenid]-race guard, all landing
    strictly AFTER the client had already created a real networked object
    in response to event 5) returned completely SILENTLY, with no
    NotifyPlayer call and no attempt to resolve/delete that object --
    permanently stranding it (it never enters `Kennels`, so
    RemoveKennelForCitizenid / playerDropped / onResourceStop never see it
    either). The TTL-expiry branch was a fourth, related but non-silent
    case: it DID notify, but still never reclaimed the object.

    Three of the tests below were written against that first read and
    FAILED on this file's very first `lua5.4 kennel_spec.lua` run -- not
    because the tests were wrong, but because a re-read of the file (done
    per this task's own "read it fresh again before you finish" instruction)
    showed the concurrent edit had landed in between: a new
    CleanupUnclaimedKennelEntity helper, called from all four of the
    branches above, which now resolves+model-verifies+deletes+broadcasts
    the orphaned object and (for the three that were silent) now also
    calls NotifyPlayer before returning. See that function's own doc
    comment and confirmKennelPlaced's own "CLEANUP FIX, ADDED THIS PASS"
    comments in the current server/kennel.lua for the fix itself.

    Per this task's own instruction ("if the source genuinely changed
    behavior, say so in your report rather than forcing the spec to
    match"): the three tests below were updated to assert the NEW,
    now-fixed, currently-observed behavior (not weakened to fit the old
    one) -- this is a real regression FIX landing on the file this spec
    covers, not a case of "make the assertion pass no matter what." The
    `Kennels[citizenid] then ...` branch remains genuinely unreachable
    through the two public net events alone (see the comment at that
    branch's own call site in server/kennel.lua, and the note in this
    file's own "confirmKennelPlaced: a confirm from a source that does not
    match..." section) -- still not exercised here, for the same reason as
    before: reaching it would require writing directly into this file's
    private `Kennels`/`PendingKennelPlacements` locals to fabricate a state
    no real caller can produce, which this suite's own convention says to
    disclose rather than force.
    ======================================================================
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in. The real native's exact algorithm (a Jenkins
-- one-at-a-time hash, per FiveM's own documented GET_HASH_KEY) does not
-- matter here -- this spec only needs a stable, deterministic function of
-- the model NAME so KennelModelHashes (built once, at kennel.lua's own
-- file-load time, from Config.DeployableKennel.propModel/fallbackPropModel)
-- and this spec's own GetEntityModel stub agree on what hash a given model
-- name maps to.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local PROP_MODEL = 'prop_dog_cage_01'
local FALLBACK_MODEL = 'prop_tennis_ball'
local WRONG_MODEL = 'prop_totally_unrelated_junk'
local PROP_HASH = GetHashKey(PROP_MODEL)
local FALLBACK_HASH = GetHashKey(FALLBACK_MODEL)
local WRONG_HASH = GetHashKey(WRONG_MODEL)

local DEPLOY_COOLDOWN_MS = 5000
local PENDING_TTL_MS = 15000

--- @param a number
--- @param b number
--- @param message string?
local function approxEquals(a, b, message)
    t.isTrue(math.abs(a - b) < 1e-6, (message and (message .. ': ') or '') ..
        ('expected ~%s, got %s'):format(tostring(b), tostring(a)))
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/kennel.lua, with
--- the real server/cooldowns.lua and server/entities.lua loaded alongside
--- it (same load order fxmanifest.lua's server_scripts list requires), and
--- every other cross-file/native dependency as a test-controlled stub.
--- @return table fixture
local function newKennelFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent) -- kennel.lua registers exactly one handler per event name
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {} -- { {target=, description=, notifyType=}, ... }
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local hasAccessBySource = {}
    local function HasK9Access(source) return hasAccessBySource[source] == true end

    local playersBySource = {} -- source -> citizenid string, or nil = unresolved
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = playersBySource[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid } }
            end,
        },
    }

    local pedBySource = {} -- source -> ped handle (unset/0 == "disconnected mid-flight")
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {} -- handle -> {x=,y=,z=}
    local function GetEntityCoords(handle) return coordsByHandle[handle] or { x = 0, y = 0, z = 0 } end

    local headingByHandle = {}
    local function GetEntityHeading(handle) return headingByHandle[handle] or 0.0 end

    local networkEntities = {} -- netId -> handle
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (GetEntityType's real domain; 3 = object)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {} -- handle -> hash
    local function GetEntityModel(handle) return entityModels[handle] end

    local deletedEntities = {} -- handle -> true
    local function DeleteEntity(handle) deletedEntities[handle] = true end

    local config = {
        Features = { DeployableKennel = true },
        DeployableKennel = {
            propModel = PROP_MODEL,
            fallbackPropModel = FALLBACK_MODEL,
            placementForwardOffsetMeters = 2.0,
            deployCooldownMs = DEPLOY_COOLDOWN_MS,
            pendingPlacementTtlMs = PENDING_TTL_MS,
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHeading = GetEntityHeading,
        GetHashKey = GetHashKey,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityModel = GetEntityModel,
        DeleteEntity = DeleteEntity,
        Config = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/kennel.lua', env)

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        deletedEntities = deletedEntities,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayer = function(src, citizenid) playersBySource[src] = citizenid end,
        setPed = function(src, pedHandle, coords, heading)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = coords
            headingByHandle[pedHandle] = heading or 0.0
        end,
        registerEntity = function(netId, handle, opts)
            opts = opts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = opts.exists ~= false
            entityTypes[handle] = opts.entityType or 3
            entityModels[handle] = opts.model or PROP_HASH
            coordsByHandle[handle] = opts.coords or { x = 0, y = 0, z = 0 }
        end,
        removeExistence = function(handle) existingEntities[handle] = false end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            return handler(...)
        end,
        firePlayerDropped = function(src, reason)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler(reason)
            end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
    }
end

local nextNetId = 1000
local function freshNetId()
    nextNetId = nextNetId + 1
    return nextNetId
end

--- @param f table
--- @param eventName string
--- @return table? -- the most recently captured {event=,target=,args=} entry for eventName, or nil
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then
            return f.clientEvents[i]
        end
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

--- Drives a full, successful requestDeployKennel -> confirmKennelPlaced
--- handshake for one handler, returning the resulting netId/entity handle
--- -- shared setup for every scenario that needs an already-deployed
--- kennel (the active-limit checks, pickup, playerDropped/onResourceStop
--- cleanup) so each doesn't hand-roll the same two-step dance.
--- @param f table
--- @param src number
--- @param citizenid string
--- @param pedHandle number
--- @param pedCoords table
--- @return number netId, number entityHandle
local function deploySuccessfully(f, src, citizenid, pedHandle, pedCoords)
    f.setAccess(src, true)
    f.setPlayer(src, citizenid)
    f.setPed(src, pedHandle, pedCoords, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', src)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    assert(instruction, 'requestDeployKennel did not send a deployKennelAt instruction')
    local x, y, z = instruction.args[1], instruction.args[2], instruction.args[3]
    local netId = freshNetId()
    local objectHandle = netId + 500000 -- arbitrary, distinct from any ped handle used in this file's tests
    f.registerEntity(netId, objectHandle, { coords = { x = x, y = y, z = z } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', src, netId)
    return netId, objectHandle
end

-- ----------------------------------------------------------------------
-- Sanity: the whole file loaded and registered what its own header
-- documents, before trusting any test below that depends on it.
-- ----------------------------------------------------------------------

t.test('server/kennel.lua registers exactly its 4 documented server net events', function()
    local f = newKennelFixture()
    local names = {}
    local count = 0
    for name in pairs(f.netEventNames) do
        names[name] = true
        count = count + 1
    end
    t.equals(count, 4)
    t.isTrue(names['qbx_k9unit:server:requestDeployKennel'] ~= nil)
    t.isTrue(names['qbx_k9unit:server:confirmKennelPlaced'] ~= nil)
    t.isTrue(names['qbx_k9unit:server:cancelKennelPlacement'] ~= nil)
    t.isTrue(names['qbx_k9unit:server:requestPickupKennel'] ~= nil)
end)

t.test('server/kennel.lua registers a playerDropped and an onResourceStop handler', function()
    local f = newKennelFixture()
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1, 'kennel.lua\'s own handler, plus DeployCooldown\'s own via RegisterPlayerDropped()')
    t.isTrue(f.eventHandlerCount('onResourceStop') >= 1)
end)

-- ----------------------------------------------------------------------
-- requestDeployKennel
-- ----------------------------------------------------------------------

t.test('requestDeployKennel: feature flag off is a silent no-op', function()
    local f = newKennelFixture()
    f.config.Features.DeployableKennel = false
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestDeployKennel: an uncertified handler is rejected with a real notification', function()
    local f = newKennelFixture()
    f.setAccess(1, false)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[1].description, locale('kennel.not_authorized_to_deploy'))
    t.equals(f.notifyCalls[1].notifyType, 'error')
end)

t.test('requestDeployKennel: cooldown silently blocks a second immediate request from the same source', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1) -- same instant, no advance
    t.equals(#f.notifyCalls, 0, 'rate-limited rejection is silent, matching every other cooldown gate in this resource')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), 1, 'no second instruction sent')
end)

t.test('requestDeployKennel: an unresolvable citizenid is rejected with a real notification and no pending state', function()
    local f = newKennelFixture()
    f.setAccess(1, true) -- no setPlayer -- exports.qbx_core:GetPlayer(1) resolves to nil
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[1].description, locale('common.unable_to_resolve_citizenid'))
    t.equals(f.notifyCalls[1].notifyType, 'error')
end)

t.test('requestDeployKennel: a second request while a kennel is already active (confirmed) is rejected, not queued', function()
    local f = newKennelFixture()
    deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.advance(DEPLOY_COOLDOWN_MS + 1) -- clear the per-source cooldown so THIS check, not the cooldown gate, is what's exercised
    local eventsBefore = countClientEvents(f, 'qbx_k9unit:client:deployKennelAt')
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.already_active_deployed'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), eventsBefore, 'no new placement started')
end)

t.test('requestDeployKennel: a second request while a placement is pending (unconfirmed) is rejected', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1) -- pending created, never confirmed
    f.advance(DEPLOY_COOLDOWN_MS + 1) -- clear the cooldown gate specifically
    local eventsBefore = countClientEvents(f, 'qbx_k9unit:client:deployKennelAt')
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_already_in_progress'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), eventsBefore)
end)

t.test('requestDeployKennel: a disconnected ped (GetPlayerPed == 0) is a silent no-op that leaves no pending state behind', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123') -- ped left unset -> GetPlayerPed(1) == 0
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)

    -- OBSERVED BEHAVIOR, DISCLOSED, NOT FIXED HERE: DeployCooldown.Consume(src)
    -- runs BEFORE this ped == 0 check, so the attempt above already stamped
    -- src 1's cooldown even though it went nowhere -- a wasted cooldown
    -- window on a request that could never have succeeded. Advancing past
    -- it here proves the ped == 0 branch itself did NOT also leave a
    -- dangling PendingKennelPlacements entry (a genuinely fresh request
    -- afterward succeeds, not "already in progress").
    f.advance(DEPLOY_COOLDOWN_MS + 1)
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), 1)
    t.equals(#f.notifyCalls, 0, 'the second, valid attempt must not see a stale "already in progress" rejection')
end)

t.test('requestDeployKennel: spawn coords at heading 0 are pedCoords + offset directly ahead on +Y', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 100.0, y = 200.0, z = 30.0 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    t.equals(instruction.target, 1)
    approxEquals(instruction.args[1], 100.0, 'spawnX')
    approxEquals(instruction.args[2], 202.0, 'spawnY (pedY + 2.0m offset)')
    approxEquals(instruction.args[3], 30.0, 'spawnZ (same level as ped)')
end)

t.test('requestDeployKennel: spawn coords at heading 90 use the heading-derived forward vector, not GetEntityForwardVector', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 100.0, y = 200.0, z = 30.0 }, 90.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    approxEquals(instruction.args[1], 98.0, 'spawnX (pedX - 2.0m at heading 90)')
    approxEquals(instruction.args[2], 200.0, 'spawnY (unchanged at heading 90)')
end)

-- ----------------------------------------------------------------------
-- confirmKennelPlaced -- input/pending validation
-- ----------------------------------------------------------------------

t.test('confirmKennelPlaced: a non-number netId is a silent no-op', function()
    local f = newKennelFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, 'not-a-number')
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmKennelPlaced: an unresolvable citizenid is a silent no-op', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, 12345)
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmKennelPlaced: no matching pending placement at all is a silent no-op', function()
    local f = newKennelFixture()
    f.setPlayer(1, 'ABC123') -- never called requestDeployKennel
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, 12345)
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmKennelPlaced: a confirm from a source that does not match the pending\'s own src is a silent no-op, and the real pending survives it', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1) -- pending.src == 1

    -- A second connection resolving to the SAME citizenid (e.g. a stale/
    -- duplicate session) tries to confirm instead of the real requester.
    f.setPlayer(2, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, 99999)
    t.equals(#f.notifyCalls, 0, 'never trust an unsolicited confirm from a different source than the one that started this placement')

    -- The legitimate src can still confirm afterward -- proves the
    -- mismatched attempt above did NOT consume the real pending entry.
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.deployed_success'))
end)

t.test('confirmKennelPlaced: an expired (TTL) placement notifies timed-out AND reclaims the real object (CleanupUnclaimedKennelEntity)', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] } })

    f.advance(PENDING_TTL_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_timed_out'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
    t.isTrue(f.deletedEntities[handle], 'CleanupUnclaimedKennelEntity must reclaim the real object the client already created, not leave it stranded')
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeKennel')
    t.equals(broadcast.args[1], netId)

    -- pending is consumed either way -- a second confirm attempt (even
    -- with the real, correct netId) now silently finds nothing.
    local notifyCountBefore = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(#f.notifyCalls, notifyCountBefore)
end)

-- ----------------------------------------------------------------------
-- confirmKennelPlaced -- late re-validation rejections (now non-silent,
-- and now reclaim the real object -- see this file's own HISTORY comment
-- above for the mid-session fix these three tests were updated to match)
-- ----------------------------------------------------------------------

t.test('confirmKennelPlaced: a feature flag toggled off mid-flight notifies AND reclaims the real object', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] } })

    -- The feature is disabled between the request and the client's confirm
    -- arriving -- a real, plausible race (an operator flips the flag, or a
    -- future onResourceStart-driven toggle), not a contrived edge case.
    f.config.Features.DeployableKennel = false
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'), 'the handler must tell the client its placement was rejected')
    t.isTrue(f.deletedEntities[handle], 'the real, already-created object must be reclaimed, not stranded')
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeKennel')
    t.equals(broadcast.args[1], netId)
end)

t.test('confirmKennelPlaced: a certification revoked mid-flight notifies AND reclaims the real object', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] } })

    f.setAccess(1, false) -- decertified between request and confirm
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'), 'the handler must tell the client its placement was rejected')
    t.isTrue(f.deletedEntities[handle], 'the real, already-created object must be reclaimed, not stranded')
end)

-- ----------------------------------------------------------------------
-- confirmKennelPlaced -- entity-side defense in depth (all notify)
-- ----------------------------------------------------------------------

t.test('confirmKennelPlaced: an entity that never resolves (never created, or already gone) notifies "unconfirmed"', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    -- Never call f.registerEntity -- the claimed netId resolves to nothing.
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, freshNetId())
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'))
end)

t.test('confirmKennelPlaced: an entity of the wrong GetEntityType also folds into "unconfirmed" (documented message consolidation)', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, {
        coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] },
        entityType = 1, -- ped, not object (3)
    })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'))
end)

t.test('confirmKennelPlaced: a real object of an unexpected model is rejected, and NOT deleted (see source comment: might not be the real kennel at all)', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, {
        coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] },
        model = WRONG_HASH,
    })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_wrong_model'))
    t.isNil(f.deletedEntities[handle])
end)

t.test('confirmKennelPlaced: the documented fallback model is also accepted, not just the primary one', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, {
        coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] },
        model = FALLBACK_HASH,
    })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.deployed_success'))
end)

t.test('confirmKennelPlaced: placed too far from the assigned spot is rejected, the real entity IS deleted, and a removal is broadcast', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, {
        -- Comfortably past KENNEL_CONFIRM_DISTANCE_TOLERANCE (3.0m, local to
        -- server/kennel.lua) -- 10m off on X alone.
        coords = { x = instruction.args[1] + 10.0, y = instruction.args[2], z = instruction.args[3] },
    })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_too_far'))
    t.isTrue(f.deletedEntities[handle], 'a credibly-real kennel placed too far is cleaned up server-side, unlike the wrong-model branch')
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeKennel')
    t.isNotNil(broadcast)
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)
end)

t.test('confirmKennelPlaced: a netId already claimed by a DIFFERENT citizenid\'s active kennel is rejected, and the original owner\'s kennel is untouched', function()
    local f = newKennelFixture()
    local netId1, handle1 = deploySuccessfully(f, 1, 'AAA111', 5001, { x = 0, y = 0, z = 0 })
    f.advance(DEPLOY_COOLDOWN_MS + 1)

    -- A second handler, at the SAME base position, requests their own
    -- placement (their own computed spawn point lands on the exact same
    -- coords as player 1's did) then reports player 1's ALREADY-CLAIMED
    -- netId instead of a genuine new object -- the exact hijack path this
    -- check's own source comment describes.
    f.setAccess(2, true)
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, netId1)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_already_claimed'))
    t.isNil(f.deletedEntities[handle1], 'the entity legitimately belongs to citizenid AAA111 -- this branch must never delete it out from under them')

    -- Player 1's own kennel is provably still intact and pickable.
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('confirmKennelPlaced: success registers the kennel and notifies success', function()
    local f = newKennelFixture()
    deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.deployed_success'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'success')
end)

-- ----------------------------------------------------------------------
-- cancelKennelPlacement
-- ----------------------------------------------------------------------

t.test('cancelKennelPlacement: frees the caller\'s own pending slot immediately, rather than waiting out the TTL', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    f.dispatchNetEvent('qbx_k9unit:server:cancelKennelPlacement', 1)

    f.advance(DEPLOY_COOLDOWN_MS + 1) -- clear the cooldown gate only
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), 2, 'a genuinely fresh placement, not blocked by "already in progress"')
    for _, call in ipairs(f.notifyCalls) do
        t.isTrue(call.description ~= locale('kennel.placement_already_in_progress'))
    end
end)

t.test('cancelKennelPlacement: a cancel from a mismatched source does not clear another connection\'s pending placement', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1) -- pending.src == 1

    f.setPlayer(2, 'ABC123') -- resolves to the same citizenid, different source
    f.dispatchNetEvent('qbx_k9unit:server:cancelKennelPlacement', 2)

    -- The real pending must have survived: src 1 can still confirm it.
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.deployed_success'))
end)

-- ----------------------------------------------------------------------
-- requestPickupKennel
-- ----------------------------------------------------------------------

t.test('requestPickupKennel: a non-number netId is a silent no-op', function()
    local f = newKennelFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, 'not-a-number')
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestPickupKennel: an unresolvable citizenid is a silent no-op', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, 123)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestPickupKennel: no active kennel at all notifies not-owner', function()
    local f = newKennelFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, 123)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.not_owner'))
end)

t.test('requestPickupKennel: a netId that does not match the citizenid\'s own active kennel notifies not-owner, and leaves the real kennel untouched', function()
    local f = newKennelFixture()
    local netId, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId + 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.not_owner'))
    t.isNil(f.deletedEntities[handle])
end)

t.test('requestPickupKennel: the real owner succeeds, deletes the entity, broadcasts removal, and clears the registry', function()
    local f = newKennelFixture()
    local netId, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'success')
    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeKennel')
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)

    -- Registry cleared -- a second pickup of the same netId is now "not owner".
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.not_owner'))
end)

t.test('requestPickupKennel: a stale registry entry (entity already gone) is still cleanly cleared, without erroring', function()
    local f = newKennelFixture()
    local netId, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.removeExistence(handle) -- simulate the object having despawned/streamed out before pickup
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId)
    -- OBSERVED BEHAVIOR, DISCLOSED: RemoveKennelForCitizenid's own
    -- ResolveNetworkEntity guard means DeleteEntity is never called for an
    -- already-gone entity, but requestPickupKennel's own success notify
    -- fires unconditionally afterward regardless -- the player is told
    -- "Kennel picked up" even though there was nothing real left to delete.
    -- Harmless (the registry genuinely IS cleared either way), just worth
    -- pinning as the real current behavior.
    t.isNil(f.deletedEntities[handle])
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeKennel')
    t.equals(broadcast.args[1], netId, 'the backstop broadcast still fires even for a stale entry')
end)

-- ----------------------------------------------------------------------
-- Lifecycle: playerDropped
-- ----------------------------------------------------------------------

t.test('playerDropped: clears an in-flight pending placement for the disconnecting source', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    f.firePlayerDropped(1)

    local notifyCountBefore = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, 12345)
    t.equals(#f.notifyCalls, notifyCountBefore, 'pending was cleared -- this confirm now finds nothing, silently')
end)

t.test('playerDropped: removes the disconnecting handler\'s own already-confirmed kennel', function()
    local f = newKennelFixture()
    local netId, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.firePlayerDropped(1)
    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeKennel')
    t.equals(broadcast.args[1], netId)

    -- Registry is cleared -- a pickup attempt against the same netId
    -- afterward (e.g. a stray late client message) reports not-owner.
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.not_owner'))
end)

t.test('playerDropped: also frees the DeployCooldown slot for the disconnecting source (RegisterPlayerDropped)', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1) -- consumes the cooldown, creates a pending
    f.firePlayerDropped(1) -- clears both the pending (see above) and the cooldown

    -- No time advance -- a request from the SAME source, at the SAME
    -- instant, only succeeds again if the cooldown was genuinely cleared.
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:deployKennelAt'), 2)
end)

-- ----------------------------------------------------------------------
-- Lifecycle: onResourceStop
-- ----------------------------------------------------------------------

t.test('onResourceStop: ignores a stop event for a different resource', function()
    local f = newKennelFixture()
    local _, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.fireResourceStop('some_other_resource')
    t.isNil(f.deletedEntities[handle])
end)

t.test('onResourceStop: deletes every remaining kennel entity, but does NOT broadcast a removal (every client is stopping too)', function()
    local f = newKennelFixture()
    local _, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    -- Isolate what THIS handler does from the deploy/confirm calls above.
    for i = #f.clientEvents, 1, -1 do f.clientEvents[i] = nil end

    f.fireResourceStop('qbx_k9unit')
    t.isTrue(f.deletedEntities[handle])
    t.equals(#f.clientEvents, 0, 'no broadcast on this path, per the source\'s own comment on why one would be unreliable busywork here')
end)

t.test('onResourceStop: a stale kennel entry (entity already gone) is skipped without erroring', function()
    local f = newKennelFixture()
    local _, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.removeExistence(handle)
    f.fireResourceStop('qbx_k9unit') -- must not throw
    t.isNil(f.deletedEntities[handle], 'never resolved, so DeleteEntity is never called on it')
end)

os.exit(t.summary())
