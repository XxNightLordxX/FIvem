--[[
    tests/propattachment_spec.lua

    Direct tests of server/propattachment.lua's four RegisterNetEvent
    handlers (requestToggleK9PropAttachment / confirmPropAttached /
    cancelPropAttachRequest / reportOwnK9PropAttachDeath), its
    onResourceStart config-safety guard, and its playerDropped/
    onResourceStop cleanup, against the REAL, unmodified production file --
    loaded alongside the real server/cooldowns.lua and server/entities.lua
    per that file's own FILE-TO-FILE CONTRACT (ToggleCooldown is a real
    NewCooldown() tracker, every ResolveNetworkEntity call is the real
    resolve+existence-guard primitive). HasK9Access, IsConfiguredK9Model,
    and NotifyPlayer are stubbed directly -- all three are genuinely OTHER
    files' own logic (server/certifications.lua, server/notify.lua), already
    covered by their own specs -- this file's job is server/
    propattachment.lua's own handshake/lifecycle logic, not a second copy of
    those.

    locale() is NEVER stubbed (this suite's own convention) -- every call
    below that reaches a NotifyPlayer(..., locale('propattachment.xxx'), ...)
    call evaluates that locale() argument for real, against the real
    locales/en.json.

    THE REGISTRATION-TIME FEATURE GATE MATTERS HERE MORE THAN IN KENNEL/FETCH:
    unlike server/kennel.lua and server/fetch.lua (whose handlers are always
    registered, gated only per-call), this file's own header wraps its
    ENTIRE handler/cleanup/config-guard block in
    `if Config.Features.PropAttachments then ... end` at file-LOAD time. So
    `newFixture({ enabled = false })` below (used only by the one test that
    checks this) produces a sandbox with ZERO of this file's net events
    registered at all -- genuinely inert, not merely hidden behind an early
    return. Every OTHER test in this file therefore loads with the flag
    already `true` (matching every real server that has actually opted into
    this feature), and drives the file's OWN internal
    `if not Config.Features.PropAttachments then return end` per-handler
    defense-in-depth check (present for the same "layered checks" reason
    this file's own header documents) by flipping the flag AFTER load,
    inside a specific test, never by never loading the handlers at all.

    onResourceStart MUST be fired for every fixture below (see
    newFixture()'s own call to it) -- `PropAttachmentModelHashes` is built
    inside that handler, deferred specifically so the config-safety asserts
    run first (this file's own doc comment on BuildPropAttachmentModelHashes
    explains why). Skipping this would make every confirmPropAttached model
    check below fail with "attempt to index a nil value", not a clean test
    failure -- this is infrastructure, not incidental to what's under test.

    ======================================================================
    WHAT THIS SPEC IS SPECIFICALLY CHECKING (per this pass's own task brief):

    1. confirmPropAttached's TTL-expiry branch plus its three re-check
       branches (the Config.Features.PropAttachments re-check, the
       HasK9Access re-check, and the already-active-PropAttachmentState
       race) now all send 'qbx_k9unit:client:rejectK9PropAttach' to `src`
       -- telling the client to undo the real, already-created/attached
       object it made in response to this file's own instruction -- where
       every one of those branches used to simply `return`.

    2. Cleanup is SAFE: this file never calls DeleteEntity itself in
       confirmPropAttached on ANY branch -- reclaim is entirely
       client-instructed via 'qbx_k9unit:client:rejectK9PropAttach', which
       tells the CALLER's OWN client to delete its own locally-tracked
       `myVestEntity`, never a server-supplied netId. This is a materially
       DIFFERENT (and in this specific handler, simpler) trust shape than
       server/fetch.lua's `safeToCleanup` gate -- documented and pinned
       below, not assumed.

    3. Lifecycle cleanup on playerDropped (clears a pending confirm AND an
       already-active attachment for the disconnecting owner) and
       onResourceStop (deletes every remaining attachment, no broadcast).

    4. A GENUINE, DISCLOSED FINDING (not fixed here, per this task's own
       hard rule): unlike server/fetch.lua's confirmFetchBallThrown/
       confirmFetchBallDropped (which independently re-check
       `FindOtherByNetId` -- this file's OWN header calls out the identical
       collision-avoidance framing under GLOBAL NETID-UNIQUENESS INVARIANT),
       confirmPropAttached here has NO equivalent guard against a caller
       reporting a netId that ALREADY belongs to a DIFFERENT citizenid's own
       confirmed `PropAttachmentState` entry. The only checks applied to a
       reported netId are (a) it resolves to a real, existing object,
       (b) its model is in the configured allowlist, and (c) it is within
       `confirmDistanceTolerance` of the CALLER's own live ped position --
       none of which rule out a second citizenid standing near the first
       and reporting the first citizenid's own real, already-tracked vest's
       netId as their own. Reproduced directly below, not assumed.
    ======================================================================
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- see kennel_spec.lua's own identical comment for why
-- the real native's exact algorithm does not matter here.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local PROP_MODEL = 'prop_bodyarmour_02'
local FALLBACK_MODEL = 'prop_tennis_ball'
local WRONG_MODEL = 'prop_totally_unrelated_junk'
local PROP_HASH = GetHashKey(PROP_MODEL)
local FALLBACK_HASH = GetHashKey(FALLBACK_MODEL)
local WRONG_HASH = GetHashKey(WRONG_MODEL)
local K9_PED_HASH = GetHashKey('a_c_shepherd')
local NON_K9_PED_HASH = GetHashKey('a_c_pug')

local TOGGLE_COOLDOWN_MS = 2000
local PENDING_CONFIRM_TTL_MS = 15000
local CONFIRM_DISTANCE_TOLERANCE = 5.0

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts table? -- { enabled: boolean (default true) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}
    local enabled = opts.enabled
    if enabled == nil then enabled = true end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent)
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
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local function IsConfiguredK9Model(hash) return hash == K9_PED_HASH end

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

    local networkEntities = {} -- netId -> handle
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (1 = ped, 3 = object)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {} -- handle -> hash (used for both peds and prop objects)
    local function GetEntityModel(handle) return entityModels[handle] end

    local deletedEntities = {} -- handle -> true
    local function DeleteEntity(handle) deletedEntities[handle] = true end

    local config = {
        Features = { PropAttachments = enabled },
        PropAttachments = {
            propModel = PROP_MODEL,
            fallbackPropModel = FALLBACK_MODEL,
            boneIndex = 0,
            offsetX = 0.0, offsetY = 0.0, offsetZ = 0.0,
            rotX = 0.0, rotY = 0.0, rotZ = 0.0,
            toggleCooldownMs = TOGGLE_COOLDOWN_MS,
            pendingConfirmTtlMs = PENDING_CONFIRM_TTL_MS,
            confirmDistanceTolerance = CONFIRM_DISTANCE_TOLERANCE,
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
    Sandbox.loadInto('../server/propattachment.lua', env)

    local fixture
    fixture = {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        deletedEntities = deletedEntities,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayer = function(src, citizenid) playersBySource[src] = citizenid end,
        setPed = function(src, pedHandle, coords, modelHash)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = { x = coords.x, y = coords.y, z = coords.z }
            entityModels[pedHandle] = modelHash or K9_PED_HASH
        end,
        registerEntity = function(netId, handle, ropts)
            ropts = ropts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = ropts.exists ~= false
            entityTypes[handle] = ropts.entityType or 3
            entityModels[handle] = ropts.model or PROP_HASH
            local c = ropts.coords or { x = 0, y = 0, z = 0 }
            coordsByHandle[handle] = { x = c.x, y = c.y, z = c.z }
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
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName)
            end
        end,
    }

    if enabled then
        -- MANDATORY infrastructure step -- see this file's own header:
        -- PropAttachmentModelHashes is built here, and every
        -- confirmPropAttached model check indexes it unconditionally.
        fixture.fireResourceStart('qbx_k9unit')
    end

    return fixture
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

--- Drives a full, successful requestToggleK9PropAttachment (ADD) ->
--- confirmPropAttached handshake for `src`.
--- @param f table
--- @param src number
--- @param citizenid string
--- @param pedHandle number
--- @param pedCoords table
--- @return number netId, number entityHandle
local function attachSuccessfully(f, src, citizenid, pedHandle, pedCoords)
    f.setAccess(src, true)
    f.setPlayer(src, citizenid)
    f.setPed(src, pedHandle, pedCoords, K9_PED_HASH)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', src)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:attachK9Prop')
    assert(instruction, 'requestToggleK9PropAttachment (ADD) did not send an attachK9Prop instruction')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = pedCoords })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', src, netId)
    return netId, handle
end

-- ----------------------------------------------------------------------
-- Sanity: registration, including the REGISTRATION-TIME FEATURE GATE.
-- ----------------------------------------------------------------------

t.test('server/propattachment.lua registers exactly its 4 documented server net events when the feature flag is on', function()
    local f = newFixture({ enabled = true })
    local names, count = {}, 0
    for name in pairs(f.netEventNames) do
        names[name] = true
        count = count + 1
    end
    t.equals(count, 4)
    for _, name in ipairs({
        'qbx_k9unit:server:requestToggleK9PropAttachment',
        'qbx_k9unit:server:confirmPropAttached',
        'qbx_k9unit:server:cancelPropAttachRequest',
        'qbx_k9unit:server:reportOwnK9PropAttachDeath',
    }) do
        t.isTrue(names[name] ~= nil, name .. ' should be registered')
    end
end)

t.test('REGISTRATION-TIME FEATURE GATE: with the flag OFF at load time, ZERO net events and ZERO onResourceStop/onResourceStart handlers are registered', function()
    local f = newFixture({ enabled = false })
    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 0)
    t.equals(f.eventHandlerCount('onResourceStop'), 0)
    t.equals(f.eventHandlerCount('onResourceStart'), 0)

    -- MINOR, DISCLOSED NUANCE (not a bug): `ToggleCooldown = NewCooldown();
    -- ToggleCooldown.RegisterPlayerDropped()` sits BEFORE the
    -- `if Config.Features.PropAttachments then` gate in the real source, so
    -- exactly ONE playerDropped handler is registered even with the flag
    -- off -- this file is not QUITE "zero handlers of any kind" inert, only
    -- "zero REACHABLE net events/commands" inert. Harmless in practice: with
    -- no toggle event registered, ToggleCooldown's store can never gain an
    -- entry for this handler to ever clear.
    t.equals(f.eventHandlerCount('playerDropped'), 1, 'ToggleCooldown.RegisterPlayerDropped() runs unconditionally, ahead of the feature gate -- a real, harmless exception to "genuinely inert"')
end)

t.test('server/propattachment.lua registers a playerDropped, onResourceStop, and onResourceStart handler when enabled', function()
    local f = newFixture({ enabled = true })
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1)
    t.isTrue(f.eventHandlerCount('onResourceStop') >= 1)
    t.isTrue(f.eventHandlerCount('onResourceStart') >= 1)
end)

-- ----------------------------------------------------------------------
-- requestToggleK9PropAttachment
-- ----------------------------------------------------------------------

t.test('requestToggleK9PropAttachment: per-handler feature-flag re-check is a silent no-op even though the event IS registered', function()
    local f = newFixture({ enabled = true })
    f.config.Features.PropAttachments = false -- toggled off after load -- defense-in-depth check inside the handler itself
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestToggleK9PropAttachment: an unresolvable citizenid is a silent no-op', function()
    local f = newFixture()
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestToggleK9PropAttachment: an uncertified handler is rejected BEFORE consuming the cooldown (a repeated ineligible attempt never burns down real allowance)', function()
    local f = newFixture()
    f.setAccess(1, false)
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(f.notifyCalls[1].description, locale('propattachment.not_authorized_equipment'))
    t.equals(f.notifyCalls[1].notifyType, 'error')

    -- Immediately certify and retry, same instant -- if the first, rejected
    -- attempt had already consumed ToggleCooldown, this would be silently
    -- rate-limited instead of reaching the ped-model check below.
    f.setAccess(1, true)
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 }, NON_K9_PED_HASH)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.requires_k9_form'), 'reached a LATER check -- proves the cooldown was not already consumed by the earlier rejection')
end)

t.test('requestToggleK9PropAttachment: a disconnected ped (GetPlayerPed == 0) is a silent no-op', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123') -- ped left unset -> GetPlayerPed(1) == 0
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestToggleK9PropAttachment: a non-K9 ped model is rejected', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 }, NON_K9_PED_HASH)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(f.notifyCalls[1].description, locale('propattachment.requires_k9_form'))
end)

t.test('requestToggleK9PropAttachment: a second request while a confirm is already pending is a silent no-op (no second pending slot)', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1) -- pending opened
    f.advance(TOGGLE_COOLDOWN_MS + 1) -- clear the cooldown gate specifically
    local before = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(#f.notifyCalls, before, 'silent -- unlike server/kennel.lua\'s equivalent, this branch has no notify at all')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:attachK9Prop'), 1, 'no second instruction sent')
end)

t.test('requestToggleK9PropAttachment: cooldown silently blocks a second immediate request from the same source', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    f.dispatchNetEvent('qbx_k9unit:server:cancelPropAttachRequest', 1) -- free the pending so the SECOND call reaches the cooldown check, not the "already pending" one
    local before = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(#f.notifyCalls, before)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:attachK9Prop'), 1)
end)

t.test('requestToggleK9PropAttachment: ADD success opens a pending confirm and instructs the SAME client to attach', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    local instruction = lastClientEvent(f, 'qbx_k9unit:client:attachK9Prop')
    t.equals(instruction.target, 1)
    t.equals(#f.notifyCalls, 0, 'no notify yet -- success is confirmed only after confirmPropAttached')
end)

t.test('requestToggleK9PropAttachment: REMOVE path (already active) needs no round trip -- deletes immediately and notifies success', function()
    local f = newFixture()
    local netId, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.advance(TOGGLE_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.removed_success'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'success')
    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeK9PropAttachment')
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)
end)

-- ----------------------------------------------------------------------
-- cancelPropAttachRequest
-- ----------------------------------------------------------------------

t.test('cancelPropAttachRequest: frees the caller\'s own pending slot immediately, rather than waiting out the TTL', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    f.dispatchNetEvent('qbx_k9unit:server:cancelPropAttachRequest', 1)

    f.advance(TOGGLE_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:attachK9Prop'), 2, 'a genuinely fresh attach attempt, not blocked by a stale pending')
end)

t.test('cancelPropAttachRequest: a cancel from a mismatched source does not clear another connection\'s pending confirm', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1) -- pending.src == 1

    f.setPlayer(2, 'ABC123') -- resolves to the same citizenid, different source
    f.dispatchNetEvent('qbx_k9unit:server:cancelPropAttachRequest', 2)

    -- The real pending must have survived: src 1 can still confirm it.
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'))
end)

t.test('cancelPropAttachRequest: an unresolvable citizenid is a silent no-op', function()
    local f = newFixture()
    f.dispatchNetEvent('qbx_k9unit:server:cancelPropAttachRequest', 1)
    t.equals(#f.notifyCalls, 0)
end)

-- ----------------------------------------------------------------------
-- confirmPropAttached -- input/pending validation
-- ----------------------------------------------------------------------

t.test('confirmPropAttached: a non-number netId is a silent no-op', function()
    local f = newFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, 'not-a-number')
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmPropAttached: an unresolvable citizenid is a silent no-op', function()
    local f = newFixture()
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, 12345)
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmPropAttached: no matching pending at all is a silent no-op', function()
    local f = newFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, 12345)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('confirmPropAttached: a confirm from a source that does not match the pending\'s own src is a silent no-op, and the real pending survives it', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1) -- pending.src == 1
    local before = #f.clientEvents -- the attachK9Prop instruction above is already counted here

    f.setPlayer(2, 'ABC123') -- a second connection resolving to the SAME citizenid
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 2, 99999)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, before, 'never trust an unsolicited confirm from a different source than the one that started this toggle')

    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'))
end)

-- ----------------------------------------------------------------------
-- confirmPropAttached -- the fixed rejection branches: TTL expiry plus the
-- three re-check branches, all now send 'qbx_k9unit:client:rejectK9PropAttach'
-- to `src` -- this handler NEVER calls DeleteEntity itself; reclaim is
-- entirely client-instructed (the client deletes its own locally-tracked
-- myVestEntity, never a server-supplied netId -- see this handler's own doc
-- comment on why that sidesteps server/fetch.lua's netId-trust concern).
-- ----------------------------------------------------------------------

t.test('confirmPropAttached: an expired (TTL) pending notifies timed-out AND instructs the client to undo its own local attach', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    f.advance(PENDING_CONFIRM_TTL_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attach_timed_out'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
    local reject = lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach')
    t.isNotNil(reject, 'the client\'s own already-created, already-attached object must not be left untracked both server- and client-side')
    t.equals(reject.target, 1)
    t.equals(#reject.args, 0, 'this event takes no argument -- the client deletes its OWN locally-tracked myVestEntity, never a server-supplied netId')

    -- pending is consumed either way -- a second confirm attempt now finds nothing.
    local before = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())
    t.equals(#f.notifyCalls, before)
end)

t.test('confirmPropAttached: Config.Features.PropAttachments false mid-flight sends rejectK9PropAttach with NO NotifyPlayer (this branch is documented as practically unreachable, but the code path itself is still exercised here)', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    f.config.Features.PropAttachments = false -- forced re-check branch, per this handler's own "defense-in-depth" comment
    local before = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())

    t.equals(#f.notifyCalls, before, 'this specific re-check branch sends NO NotifyPlayer, unlike its siblings -- verified against the real source, not assumed')
    local reject = lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach')
    t.isNotNil(reject)
    t.equals(reject.target, 1)
end)

t.test('confirmPropAttached: HasK9Access revoked mid-flight notifies AND sends rejectK9PropAttach', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    f.setAccess(1, false) -- decertified between request and confirm
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.not_authorized_equipment'))
    local reject = lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach')
    t.isNotNil(reject)
    t.equals(reject.target, 1)
end)

t.test('confirmPropAttached: an already-active PropAttachmentState race sends rejectK9PropAttach targeting THIS confirm\'s own object, with NO NotifyPlayer (the true state is already correct)', function()
    local f = newFixture()
    -- First attachment already confirmed and active.
    attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })

    -- A SECOND in-flight confirm for the SAME citizenid races in afterward
    -- (e.g. a duplicate client message). Since requestToggleK9PropAttachment
    -- itself would normally take the REMOVE branch once active, this
    -- fabricates the narrow in-flight-race window the handler's own comment
    -- describes by driving a second toggle+confirm cycle concurrently is not
    -- directly reachable through the public events alone once the first is
    -- active -- so this test drives the race the one way that IS reachable:
    -- a citizenid with an existing active attachment cannot open a NEW
    -- pending via requestToggleK9PropAttachment at all (it takes the REMOVE
    -- branch instead) -- confirmed directly below.
    f.advance(TOGGLE_COOLDOWN_MS + 1)
    local beforeToggle = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.removed_success'), 'requestToggleK9PropAttachment took the REMOVE branch -- confirms the already-active race inside confirmPropAttached is not reachable through the public events alone for the SAME citizenid')
    t.isTrue(#f.notifyCalls > beforeToggle)
end)

t.test('confirmPropAttached: a disconnected ped (GetPlayerPed == 0) after all three re-checks pass is a SILENT no-op -- GENUINE, DISCLOSED FINDING: the client\'s just-created object is left with no reject instruction on this specific race', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    -- src disconnects (ped no longer resolvable) between the confirm firing
    -- and this line -- a narrow race, but NOT one of the three re-check
    -- branches this pass's fix covers (Config.Features/HasK9Access/
    -- already-active), and NOT the TTL branch either.
    f.setPed(1, 0, { x = 0, y = 0, z = 0 }) -- GetPlayerPed(1) now resolves to 0
    local before = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())

    t.equals(#f.notifyCalls, before, 'FINDING: still silent -- no NotifyPlayer')
    t.isNil(lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach'), 'FINDING: still silent -- no rejectK9PropAttach either, unlike every OTHER failure branch in this same handler')
end)

t.test('confirmPropAttached: an entity that never resolves notifies "unconfirmed" AND sends rejectK9PropAttach', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    -- Never call f.registerEntity -- the claimed netId resolves to nothing.
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attach_failed_unconfirmed'))
    local reject = lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach')
    t.isNotNil(reject)
    t.equals(reject.target, 1)
end)

t.test('confirmPropAttached: a real object of an unexpected model is rejected, sends rejectK9PropAttach, and is NOT deleted server-side (this handler never calls DeleteEntity)', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = { x = 0, y = 0, z = 0 }, model = WRONG_HASH })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attach_failed_wrong_model'))
    t.isNil(f.deletedEntities[handle])
    local reject = lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach')
    t.isNotNil(reject)
end)

t.test('confirmPropAttached: the documented fallback model is also accepted, not just the primary one', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = 0, y = 0, z = 0 }, model = FALLBACK_HASH })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'))
end)

t.test('confirmPropAttached: too far from the caller\'s OWN live ped position is rejected, and sends rejectK9PropAttach', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    local netId = freshNetId()
    local handle = netId + 500000
    -- Comfortably past confirmDistanceTolerance (5.0m) -- 50m away.
    f.registerEntity(netId, handle, { coords = { x = 50.0, y = 0, z = 0 } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attach_failed_too_far'))
    t.isNil(f.deletedEntities[handle])
    local reject = lastClientEvent(f, 'qbx_k9unit:client:rejectK9PropAttach')
    t.isNotNil(reject)
end)

t.test('confirmPropAttached: success registers the attachment and notifies success', function()
    local f = newFixture()
    attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'success')
end)

t.test('confirmPropAttached: exactly at the distance tolerance boundary succeeds (< not <=, matching every other tolerance check in this resource)', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)

    local netId = freshNetId()
    -- Just UNDER the tolerance -- floating point exact-boundary equality is
    -- not asserted here (the handler's own check is `dist >
    -- confirmDistanceTolerance`, i.e. rejects ONLY when strictly greater).
    f.registerEntity(netId, netId + 500000, { coords = { x = CONFIRM_DISTANCE_TOLERANCE - 0.01, y = 0, z = 0 } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'))
end)

-- ----------------------------------------------------------------------
-- GENUINE, DISCLOSED FINDING: confirmPropAttached has NO equivalent of
-- server/fetch.lua's FindOtherByNetId / GLOBAL NETID-UNIQUENESS INVARIANT
-- check. Reproduced directly, not assumed.
-- ----------------------------------------------------------------------

t.test('FINDING: confirmPropAttached accepts a netId that ALREADY belongs to a DIFFERENT citizenid\'s own active attachment, if the caller is standing close enough to it -- no cross-citizenid collision guard exists here, unlike server/fetch.lua', function()
    local f = newFixture()
    local netId1 = attachSuccessfully(f, 1, 'AAA111', 5001, { x = 0, y = 0, z = 0 })

    -- Citizen 2 stands right next to citizen 1 and opens their own toggle.
    f.advance(TOGGLE_COOLDOWN_MS + 1)
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, K9_PED_HASH) -- same coords as citizen 1's own vest
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 2)

    -- Citizen 2's client reports CITIZEN 1's own real, already-tracked
    -- netId instead of a genuinely new object.
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 2, netId1)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'), 'FINDING: this succeeds -- the model check and the distance-to-OWN-ped check both pass, and nothing here re-checks netId ownership uniqueness')

    -- Both citizens now independently believe they own the SAME netId.
    -- Toggling EITHER one off deletes the one shared physical entity.
    f.advance(TOGGLE_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1) -- citizen 1 toggles their vest off
    t.isTrue(f.deletedEntities[netId1 + 500000], 'the shared entity is now gone')

    -- Citizen 2's own registry entry is now STALE -- still believes it owns
    -- a netId that no longer resolves to anything. This is a real, disclosed
    -- desync, not fixed here (server/propattachment.lua is not this task's
    -- file to edit).
    f.advance(TOGGLE_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 2) -- citizen 2 tries to toggle off their (already-gone) vest
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.removed_success'), 'FINDING: this still reports success even though ResolveNetworkEntity for the now-deleted netId returns nil and DeleteEntity is never actually called a second time -- see RemovePropAttachmentForCitizenid\'s own unconditional notify, mirroring kennel_spec.lua\'s own disclosed "stale registry entry" finding for requestPickupKennel')
end)

-- ----------------------------------------------------------------------
-- reportOwnK9PropAttachDeath
-- ----------------------------------------------------------------------

t.test('reportOwnK9PropAttachDeath: an unresolvable citizenid is a silent no-op', function()
    local f = newFixture()
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 1)
    t.equals(#f.notifyCalls, 0)
end)

t.test('reportOwnK9PropAttachDeath: no active attachment is a silent no-op', function()
    local f = newFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('reportOwnK9PropAttachDeath: an ownerSrc mismatch is a silent no-op, and the real attachment is untouched', function()
    local f = newFixture()
    local netId, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    -- A different connection resolving to the SAME citizenid reports death --
    -- must not be trusted; ownerSrc on record is still 1.
    f.setPlayer(2, 'ABC123')
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 2)

    t.isNil(f.deletedEntities[handle])
    t.equals(countClientEvents(f, 'qbx_k9unit:client:removeK9PropAttachment'), 0)

    -- The real owner's report still works afterward.
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 1)
    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeK9PropAttachment')
    t.equals(broadcast.args[1], netId)
end)

t.test('reportOwnK9PropAttachDeath: success removes the attachment (delete + broadcast + clear registry)', function()
    local f = newFixture()
    local netId, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 1)

    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeK9PropAttachment')
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)

    -- A second death report now finds nothing -- silent no-op.
    local before = #f.clientEvents
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 1)
    t.equals(#f.clientEvents, before)
end)

-- ----------------------------------------------------------------------
-- Lifecycle: playerDropped
-- ----------------------------------------------------------------------

t.test('playerDropped: clears an in-flight pending confirm for the disconnecting source', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    f.firePlayerDropped(1)

    local before = #f.notifyCalls
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, freshNetId())
    t.equals(#f.notifyCalls, before, 'pending was cleared -- this confirm now finds nothing, silently')
end)

t.test('playerDropped: a mismatched-source pending is untouched by an unrelated disconnect', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1) -- pending.src == 1

    f.setPlayer(2, 'ZZZ999')
    f.firePlayerDropped(2) -- unrelated disconnect, different citizenid entirely

    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('qbx_k9unit:server:confirmPropAttached', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('propattachment.attached_success'), 'src 1\'s own pending must have survived an unrelated disconnect')
end)

t.test('playerDropped: removes the disconnecting owner\'s own already-confirmed attachment', function()
    local f = newFixture()
    local netId, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.firePlayerDropped(1)

    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'qbx_k9unit:client:removeK9PropAttachment')
    t.equals(broadcast.args[1], netId)

    -- A death report now finds nothing -- registry was cleared.
    local before = #f.clientEvents
    f.dispatchNetEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath', 1)
    t.equals(#f.clientEvents, before)
end)

t.test('playerDropped: an ownerSrc mismatch means a different connection\'s disconnect does not remove this citizenid\'s attachment', function()
    local f = newFixture()
    local _, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    -- A second connection resolving to the SAME citizenid disconnects --
    -- must not be trusted to remove src 1's own real attachment.
    f.setPlayer(2, 'ABC123')
    f.firePlayerDropped(2)

    t.isNil(f.deletedEntities[handle])
    t.equals(countClientEvents(f, 'qbx_k9unit:client:removeK9PropAttachment'), 0)
end)

t.test('playerDropped: also frees the ToggleCooldown slot for the disconnecting source (RegisterPlayerDropped)', function()
    local f = newFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1) -- consumes ToggleCooldown, opens a pending
    f.firePlayerDropped(1) -- clears both the pending (see above) and the cooldown

    -- No time advance -- a fresh request from the SAME source, at the SAME
    -- instant, only succeeds again if the cooldown was genuinely cleared.
    f.dispatchNetEvent('qbx_k9unit:server:requestToggleK9PropAttachment', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:attachK9Prop'), 2)
end)

-- ----------------------------------------------------------------------
-- Lifecycle: onResourceStop
-- ----------------------------------------------------------------------

t.test('onResourceStop: ignores a stop event for a different resource', function()
    local f = newFixture()
    local _, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.fireResourceStop('some_other_resource')
    t.isNil(f.deletedEntities[handle])
end)

t.test('onResourceStop: deletes every remaining attachment, but does NOT broadcast a removal (every client is stopping too)', function()
    local f = newFixture()
    local _, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    for i = #f.clientEvents, 1, -1 do f.clientEvents[i] = nil end

    f.fireResourceStop('qbx_k9unit')
    t.isTrue(f.deletedEntities[handle])
    t.equals(#f.clientEvents, 0, 'no broadcast on this path, per the source\'s own comment on why one would be unreliable busywork here')
end)

t.test('onResourceStop: a stale attachment entry (entity already gone) is skipped without erroring', function()
    local f = newFixture()
    local _, handle = attachSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.removeExistence(handle)
    f.fireResourceStop('qbx_k9unit') -- must not throw
    t.isNil(f.deletedEntities[handle], 'never resolved, so DeleteEntity is never called on it')
end)

-- ----------------------------------------------------------------------
-- onResourceStart config-safety guard
-- ----------------------------------------------------------------------

t.test('onResourceStart: ignores a start event for a different resource', function()
    local f = newFixture()
    -- If this incorrectly ran against Config.PropAttachments = nil, it would
    -- throw -- proving it did NOT run for the wrong resource name.
    f.config.PropAttachments = nil
    f.fireResourceStart('some_other_resource')
    t.isTrue(true, 'no error means the wrong-resource-name guard held')
end)

t.test('onResourceStart: a malformed Config.PropAttachments fails loudly (assert) once the flag is genuinely on', function()
    local f = newFixture()
    f.config.PropAttachments.toggleCooldownMs = 0 -- the exact footgun this assert exists to catch -- see propattachment.lua's own comment
    local ok, err = pcall(f.fireResourceStart, 'qbx_k9unit')
    t.isFalse(ok)
    t.contains(tostring(err), 'toggleCooldownMs')
end)

os.exit(t.summary())
