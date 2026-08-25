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

    -- NETWORK-OWNERSHIP GUARD mock (coder-architect, this pass -- mirrors
    -- tests/propattachment_spec.lua's own identical mock, added there
    -- first). handle -> src of whichever connection currently, per this
    -- mock's own OneSync stand-in, "owns" that networked object. Defaults
    -- to nil (no known owner) for any handle registerEntity's caller
    -- doesn't explicitly assign one to -- deliberately FAIL CLOSED, matching
    -- the real NetworkGetEntityOwner check's own `~= src` comparison (nil
    -- never equals a real numeric src), so a test that wants a confirm to
    -- reach PAST this guard must say so explicitly via registerEntity's own
    -- `owner` field rather than relying on an implicit default.
    local entityOwners = {} -- handle -> src
    local function NetworkGetEntityOwner(handle) return entityOwners[handle] end

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
        NetworkGetEntityOwner = NetworkGetEntityOwner,
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
            entityOwners[handle] = opts.owner -- nil (no owner) unless the caller says otherwise -- see entityOwners' own declaration comment above
            coordsByHandle[handle] = opts.coords or { x = 0, y = 0, z = 0 }
        end,
        setEntityOwner = function(handle, src) entityOwners[handle] = src end,
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
    -- owner = src: an honest client's confirm always names the object IT
    -- ITSELF just created (client/kennel.lua's own myKennelNetId pairing) --
    -- see the NETWORK-OWNERSHIP GUARD mock's own declaration comment for why
    -- this must be explicit rather than an implicit default.
    f.registerEntity(netId, objectHandle, { coords = { x = x, y = y, z = z }, owner = src })
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
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })
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
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })

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
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })

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
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })

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
        owner = 1,
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
        owner = 1, -- genuinely THIS citizenid's own object -- safeToCleanup's deletion still depends on this even though the too-far REJECTION itself does not
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

    -- DISCLOSED MESSAGE CHANGE (coder-architect, this pass, urgent
    -- PRE-CONFIRMATION-WINDOW fix): this used to reject via the
    -- already_claimed pre-write check reached further down. The new
    -- NETWORK-OWNERSHIP GUARD (mirrors server/propattachment.lua's own)
    -- runs BEFORE that check and now catches this exact scenario first --
    -- citizenid 2 is never netId1's real OneSync owner (citizenid 1's own
    -- client created it) -- so the message is now the more generic
    -- placement_failed_unconfirmed. The SECURITY OUTCOME this test actually
    -- verifies (rejected, never deleted, the real owner keeps it) is
    -- unchanged; only which specific check catches it first changed.
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'))
    t.isNil(f.deletedEntities[handle1], 'the entity legitimately belongs to citizenid AAA111 -- this branch must never delete it out from under them')

    -- Player 1's own kennel is provably still intact and pickable.
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

-- ----------------------------------------------------------------------
-- RED-TEAM FIX: confirmKennelPlaced's rejection branches must never delete
-- an entity the confirming citizenid does not own (server/kennel.lua's
-- `safeToCleanup`, mirroring server/fetch.lua's `safeToCleanup` pattern).
-- Each test below drives a VICTIM to a real, confirmed kennel first, then
-- has a SEPARATE, independently-certified ATTACKER land on one of the four
-- reachable rejection branches (too-far, TTL-expiry, feature-flag toggle,
-- certification revoke) while reporting the VICTIM's real netId instead of
-- a genuine placement of their own -- the exact "open a pending slot,
-- create nothing, name someone else's real kennel" shape the red-team
-- finding described. Every test asserts (a) the victim's entity survives,
-- (b) no removal is ever broadcast for the victim's netId, and (c) the
-- victim's kennel is still genuinely theirs to pick up afterward -- proving
-- the fix closes the exploit without stranding the victim's own kennel.
-- ----------------------------------------------------------------------

--- @param f table
--- @param netId number
--- @return boolean
local function removalWasBroadcastFor(f, netId)
    for _, e in ipairs(f.clientEvents) do
        if e.event == 'qbx_k9unit:client:removeKennel' and e.args[1] == netId then
            return true
        end
    end
    return false
end

t.test('confirmKennelPlaced: RED-TEAM FIX -- the too-far-from-spawn branch naming a DIFFERENT citizenid\'s real kennel does NOT delete it (the primary reported griefing primitive, no proximity to the victim required)', function()
    local f = newKennelFixture()
    local victimNetId, victimHandle = deploySuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })
    f.advance(DEPLOY_COOLDOWN_MS + 1)

    -- Attacker: opens their own pending placement far away on the map,
    -- creates nothing client-side, then reports the VICTIM's real,
    -- already-confirmed kennel netId. The victim's kennel is nowhere near
    -- the attacker's own server-assigned spawn point, so this trips the
    -- too-far branch -- repeatable roughly every DeployCooldown, with zero
    -- proximity to the victim ever required.
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 5000, y = 5000, z = 500 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_too_far'), 'the attacker still gets a genuine rejection, just never a destructive one')
    t.isNil(f.deletedEntities[victimHandle], 'the victim\'s real, active kennel must survive an attacker naming it from a branch that used to unconditionally delete')
    t.isTrue(not removalWasBroadcastFor(f, victimNetId), 'no removal may ever be broadcast for an entity the confirming citizenid does not own')

    -- Repeatable: a second attempt after the cooldown clears still fails to
    -- delete the victim's kennel.
    f.advance(DEPLOY_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimNetId)
    t.isNil(f.deletedEntities[victimHandle], 'still not deleted on a second attempt')

    -- The victim's kennel is provably still intact and pickup-able.
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, victimNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('confirmKennelPlaced: RED-TEAM FIX -- letting the TTL expire while naming a DIFFERENT citizenid\'s real kennel does NOT delete it', function()
    local f = newKennelFixture()
    local victimNetId, victimHandle = deploySuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })
    f.advance(DEPLOY_COOLDOWN_MS + 1)

    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 5000, y = 5000, z = 500 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)

    f.advance(PENDING_TTL_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_timed_out'))
    t.isNil(f.deletedEntities[victimHandle], 'the victim\'s real kennel must never be deleted by an unrelated citizenid\'s own TTL-expiry rejection')
    t.isTrue(not removalWasBroadcastFor(f, victimNetId), 'no removal may ever be broadcast for an entity the confirming citizenid does not own')

    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, victimNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('confirmKennelPlaced: RED-TEAM FIX -- a feature-flag toggle mid-flight while naming a DIFFERENT citizenid\'s real kennel does NOT delete it', function()
    local f = newKennelFixture()
    local victimNetId, victimHandle = deploySuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })
    f.advance(DEPLOY_COOLDOWN_MS + 1)

    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 5000, y = 5000, z = 500 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)

    f.config.Features.DeployableKennel = false
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'))
    t.isNil(f.deletedEntities[victimHandle], 'the victim\'s real kennel must never be deleted by an unrelated citizenid\'s own feature-flag rejection')
    t.isTrue(not removalWasBroadcastFor(f, victimNetId), 'no removal may ever be broadcast for an entity the confirming citizenid does not own')

    -- requestPickupKennel does not itself gate on the feature flag (see its
    -- own handler) -- the victim's kennel is provably still intact.
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, victimNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('confirmKennelPlaced: RED-TEAM FIX -- a certification revoke mid-flight while naming a DIFFERENT citizenid\'s real kennel does NOT delete it', function()
    local f = newKennelFixture()
    local victimNetId, victimHandle = deploySuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })
    f.advance(DEPLOY_COOLDOWN_MS + 1)

    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 5000, y = 5000, z = 500 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)

    f.setAccess(2, false) -- decertified between request and confirm
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_unconfirmed'))
    t.isNil(f.deletedEntities[victimHandle], 'the victim\'s real kennel must never be deleted by an unrelated citizenid\'s own certification-revoke rejection')
    t.isTrue(not removalWasBroadcastFor(f, victimNetId), 'no removal may ever be broadcast for an entity the confirming citizenid does not own')

    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, victimNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('confirmKennelPlaced: RED-TEAM FIX -- a legitimate owner\'s own too-far cleanup still works (safeToCleanup does not strand a genuinely-owned kennel)', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, {
        coords = { x = instruction.args[1] + 10.0, y = instruction.args[2], z = instruction.args[3] },
        owner = 1, -- genuinely THIS citizenid's own object
    })
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_too_far'))
    t.isTrue(f.deletedEntities[handle], 'safeToCleanup must still allow reclaiming a citizenid\'s OWN real, unclaimed-by-anyone-else object -- the fix must not create a new unbounded trap')
    t.isTrue(removalWasBroadcastFor(f, netId))
end)

t.test('confirmKennelPlaced: RED-TEAM FIX -- a legitimate owner\'s own TTL-expiry cleanup still works', function()
    local f = newKennelFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:deployKennelAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })

    f.advance(PENDING_TTL_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_timed_out'))
    t.isTrue(f.deletedEntities[handle], 'safeToCleanup must still reclaim a citizenid\'s OWN genuinely-orphaned object on TTL expiry')
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
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })
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

-- ----------------------------------------------------------------------
-- CROSS-FEATURE NETID GAP (coder-architect, this pass) -- server/kennel.lua
-- and server/fetch.lua each already guard their OWN registry
-- (FindKennelOwnerByNetId / FindOtherBallByNetId) against a same-feature
-- collision, but neither could see the other's. config.lua configures
-- Config.DeployableKennel.fallbackPropModel and Config.FetchMechanic.ballPropModel
-- to the IDENTICAL 'prop_tennis_ball' model, so a netId naming another
-- citizen's real, live FETCH BALL is a real object of the right type,
-- wearing kennel's own accepted (fallback) model, that is simply absent
-- from `Kennels` -- this section proves confirmKennelPlaced can no longer
-- be used to (a) delete a victim's live fetch ball via a rejection branch,
-- or (b) the more severe shape found auditing this pass: silently WRITE the
-- victim's fetch ball into `Kennels[attacker]` on the plain SUCCESS path,
-- reachable for deletion by the attacker's own subsequent
-- requestPickupKennel.
--
-- newCombinedFixture() below loads the REAL, unmodified server/kennel.lua
-- AND server/fetch.lua into ONE shared env (same load order fxmanifest.lua
-- requires) so both genuinely share ONE server/entities.lua
-- ClaimedNetworkEntities instance -- a fixture loading kennel.lua alone
-- could never prove the cross-file sharing this fix depends on.
-- ----------------------------------------------------------------------

--- @return table fixture -- same shape as newKennelFixture()'s own return,
--- so lastClientEvent/countClientEvents/deploySuccessfully/freshNetId/
--- removalWasBroadcastFor above are all reusable unchanged.
local function newCombinedFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    -- fetch.lua's own requestPickupFetchBall model check -- not exercised by
    -- any test in this section (no pickup is driven here), but must exist so
    -- server/fetch.lua loads without erroring.
    local function IsConfiguredK9Model(_hash) return false end

    local playersBySource = {}
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = playersBySource[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid } }
            end,
        },
    }

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {}
    local function GetEntityCoords(handle) return coordsByHandle[handle] or { x = 0, y = 0, z = 0 } end

    local headingByHandle = {}
    local function GetEntityHeading(handle) return headingByHandle[handle] or 0.0 end

    local networkEntities = {}
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {}
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {}
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {}
    local function GetEntityModel(handle) return entityModels[handle] end

    -- NETWORK-OWNERSHIP GUARD mock -- see newKennelFixture()'s own identical
    -- declaration comment above (mirrors tests/propattachment_spec.lua's
    -- original). Fail-closed default (nil): a test must explicitly say
    -- `owner = <src>` for a confirm to reach past either kennel.lua's or
    -- fetch.lua's own NetworkGetEntityOwner guard.
    local entityOwners = {}
    local function NetworkGetEntityOwner(handle) return entityOwners[handle] end

    local deletedEntities = {}
    local function DeleteEntity(handle) deletedEntities[handle] = true end

    -- fetch.lua's maintenance thread is never stepped in this section (no
    -- test here needs it) -- a genuine no-op CreateThread, never calling its
    -- argument, is simpler than wiring fetch_spec.lua's own coroutine-based
    -- thread runner for a thread this section has no use for.
    local function CreateThread(_fn) end

    -- SHARED MODEL, DELIBERATELY: mirrors config.lua's own real
    -- configuration exactly -- kennel's fallbackPropModel and fetch's
    -- ballPropModel are the IDENTICAL 'prop_tennis_ball', which is the
    -- entire precondition for the cross-feature gap this section proves
    -- closed.
    local config = {
        Features = { DeployableKennel = true, FetchMechanic = true },
        DeployableKennel = {
            propModel = PROP_MODEL,
            fallbackPropModel = FALLBACK_MODEL, -- 'prop_tennis_ball'
            placementForwardOffsetMeters = 2.0,
            deployCooldownMs = DEPLOY_COOLDOWN_MS,
            pendingPlacementTtlMs = PENDING_TTL_MS,
        },
        FetchMechanic = {
            ballPropModel = FALLBACK_MODEL, -- 'prop_tennis_ball' -- SAME string as kennel's fallback, on purpose
            throwForwardOffsetMeters = 1.0,
            throwUpOffsetMeters = 1.2,
            throwForceForward = 12.0,
            throwForceUp = 6.0,
            throwCooldownMs = 5000,
            pendingThrowTtlMs = 15000,
            maxBallLifetimeMs = 300000,
            pickupInteractDistanceMeters = 2.0,
            deliverProximityMeters = 3.0,
            maintenanceIntervalMs = 2000,
            mouthCarryMode = 'fake',
            mouthBoneIndex = 0,
            mouthOffsetX = 0.0, mouthOffsetY = 0.0, mouthOffsetZ = 0.0,
            pickupCooldownMs = 500,
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
        IsConfiguredK9Model = IsConfiguredK9Model,
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
        CreateThread = CreateThread,
        Config = config,
    })

    -- Same load order fxmanifest.lua's server_scripts list requires:
    -- cooldowns.lua, entities.lua, THEN kennel.lua and fetch.lua -- both
    -- feature files sharing the ONE server/entities.lua instance loaded here
    -- is the entire point of this fixture.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/kennel.lua', env)
    Sandbox.loadInto('../server/fetch.lua', env)

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

--- Drives a full, successful requestThrowFetchBall -> confirmFetchBallThrown
--- handshake against the REAL server/fetch.lua loaded into the SAME
--- combined fixture, producing a genuine, live victim fetch ball this
--- section's kennel-confirm attacks can then target by netId.
--- @param f table
--- @param src number
--- @param citizenid string
--- @param pedHandle number
--- @param pedCoords table
--- @return number netId, number entityHandle
local function throwFetchBallSuccessfully(f, src, citizenid, pedHandle, pedCoords)
    f.setAccess(src, true)
    f.setPlayer(src, citizenid)
    f.setPed(src, pedHandle, pedCoords, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestThrowFetchBall', src)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:throwFetchBallAt')
    assert(instruction, 'requestThrowFetchBall did not send a throwFetchBallAt instruction')
    local x, y, z = instruction.args[1], instruction.args[2], instruction.args[3]
    local netId = freshNetId()
    local objectHandle = netId + 900000 -- distinct offset from deploySuccessfully's own +500000, so a kennel and a fetch ball in the same test never collide on entity handle
    f.registerEntity(netId, objectHandle, { coords = { x = x, y = y, z = z } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmFetchBallThrown', src, netId)
    return netId, objectHandle
end

t.test('CROSS-FEATURE: confirmKennelPlaced\'s too-far rejection naming a DIFFERENT citizenid\'s real, live FETCH BALL does NOT delete it (the exact case neither file\'s own same-feature fix covers)', function()
    local f = newCombinedFixture()
    local victimBallNetId, victimBallHandle = throwFetchBallSuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })

    -- Attacker: opens their own kennel placement far away, creates nothing
    -- client-side, then reports the VICTIM's real, live fetch ball's netId.
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 5000, y = 5000, z = 500 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimBallNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_too_far'), 'the attacker still gets a genuine rejection, just never a destructive one')
    t.isNil(f.deletedEntities[victimBallHandle], 'the victim\'s real, live fetch ball must survive an attacker naming it from a KENNEL confirm')
    t.isTrue(not removalWasBroadcastFor(f, victimBallNetId), 'no removeKennel broadcast may ever be sent for an entity server/kennel.lua does not own')

    -- The victim's ball is provably still intact and recallable through
    -- server/fetch.lua's own, completely independent code path.
    f.dispatchNetEvent('qbx_k9unit:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

t.test('CROSS-FEATURE, THE MORE SEVERE SHAPE: confirmKennelPlaced\'s plain SUCCESS PATH must not silently register a victim\'s real, live FETCH BALL as the attacker\'s own kennel', function()
    local f = newCombinedFixture()
    local victimBallNetId, victimBallHandle = throwFetchBallSuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })

    -- Attacker places their OWN kennel request at coords that happen to
    -- match where the (unrelated) victim's ball physically sits -- passing
    -- the distance-tolerance check too, so NO rejection branch fires at all;
    -- this is the plain success path.
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0)
    f.dispatchNetEvent('qbx_k9unit:server:requestDeployKennel', 2)
    f.dispatchNetEvent('qbx_k9unit:server:confirmKennelPlaced', 2, victimBallNetId)

    -- Must be REJECTED (the shared IsNetworkEntityClaimedByOther check), not
    -- silently written into Kennels as the attacker's own.
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.placement_failed_already_claimed'), 'must be rejected, not silently registered as a genuine new kennel')
    t.isNil(f.deletedEntities[victimBallHandle])

    -- PROOF the write never happened: the attacker's own requestPickupKennel
    -- against this exact netId must say "not owner", never actually succeed
    -- and delete the victim's real ball.
    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 2, victimBallNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.not_owner'))
    t.isNil(f.deletedEntities[victimBallHandle], 'the attacker must never be able to delete the victim\'s ball via a bogus "pickup" of their own non-existent kennel')

    -- The victim's ball remains genuinely theirs, through server/fetch.lua's
    -- own independent code path.
    f.dispatchNetEvent('qbx_k9unit:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

t.test('CROSS-FEATURE: a legitimate kennel confirm is entirely unaffected by an UNRELATED citizen\'s own live fetch ball existing elsewhere', function()
    local f = newCombinedFixture()
    throwFetchBallSuccessfully(f, 9, 'BYSTANDER9', 5009, { x = 9000, y = 9000, z = 0 })

    -- An honest handler's own, genuine kennel placement must succeed exactly
    -- as it does with no fetch ball in play at all -- the new cross-feature
    -- check must never produce a false positive against a citizen's OWN,
    -- correctly-claimed object.
    local netId, handle = deploySuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.deployed_success'))

    f.dispatchNetEvent('qbx_k9unit:server:requestPickupKennel', 1, netId)
    t.isTrue(f.deletedEntities[handle])
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

os.exit(t.summary())
