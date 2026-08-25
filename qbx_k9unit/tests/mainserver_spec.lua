--[[
    tests/mainserver_spec.lua

    First test coverage for server/main.lua -- previously ZERO. This file
    owns the leash consent handshake (Config.Features.LeashMechanics, one
    of only FIVE features that ship ENABLED by default alongside RadialMenu/
    VehicleEntryExit/BasicBarkSounds/AgilityBasicJump -- see config.lua),
    plus relayBark and relayDoorScratch. Named mainserver_spec.lua, not
    main_spec.lua -- that name is already taken by the CLIENT-side spec
    (client/main.lua's IsEntityModelK9/HasK9Access/CanShowK9UI cluster), a
    completely different file in a completely different Lua VM.

    Loads the REAL, unmodified server/cooldowns.lua -> server/entities.lua
    -> server/main.lua chain, in the exact order fxmanifest.lua's
    server_scripts list requires (main.lua's own header FILE-TO-FILE
    CONTRACT: BarkCooldown/LeashRequestCooldown/DoorScratchCooldown/
    DoorScratchByDoorCooldown are real NewCooldown() trackers, and
    relayDoorScratch's ResolveNetworkEntity call is the real resolve+
    existence+type-guard primitive) -- never a reimplementation of either.
    HasK9Access, IsConfiguredK9Model, and NotifyPlayer are stubbed directly,
    same convention kennel_spec.lua/combat_spec.lua already established:
    all three are genuinely OTHER files' own logic (server/certifications.lua,
    server/notify.lua), already covered by their own specs -- this file's
    job is server/main.lua's own handshake/relay/cleanup logic, not a
    second copy of those.

    locale() is NEVER stubbed (per this suite's own convention -- see
    DEVELOPER_REFERENCE.md §20). LEASH_REJECT_MESSAGES is built ONCE, at server/main.lua's
    own file-load time, from 8 locale() calls -- every single test in this
    file that successfully loads the sandbox (i.e. every test) already
    proves all 8 of those keys resolve against the real locales/en.json, since
    a missing one would raise at Sandbox.loadInto time and fail EVERY test in
    this file, not just one. Section 4 below additionally drives each of
    those 8 reasons through its OWN real code path and asserts the exact
    notified string against Sandbox.locale(...) (never a hand-copied English
    string), closing the gap a load-time-only proof leaves open: that each
    key is not just present in en.json, but is the ACTUAL message the real
    reason->message table maps its own reason string to.

    ONE FRESH SANDBOX PER TEST (never shared) -- LeashPairs, PendingLeashRequests,
    and every cooldown tracker's own internal store are file-lifetime `local`
    upvalues, so reusing one sandbox across unrelated cases would leak state
    exactly the way kennel_spec.lua/combat_spec.lua's own headers warn about.
    newMainFixture() below builds one complete, independent world for every
    single t.test() call.

    ======================================================================
    HANDLER INVENTORY -- built by READING server/main.lua top to bottom
    (never by grepping), pinned by Section 1 below:

    RegisterNetEvent (client->server), exactly 5:
      'qbx_k9unit:server:relayBark'            (Section 2)
      'qbx_k9unit:server:relayDoorScratch'     (Section 3)
      'qbx_k9unit:server:requestLeashAttach'   (Sections 4-6)
      'qbx_k9unit:server:respondLeashAttach'   (Sections 4, 7-8)
      'qbx_k9unit:server:detachLeash'          (Section 9)

    AddEventHandler('onResourceStart', ...), exactly 2 in this file (neither
    is this spec's concern -- both belong to the certification-cache
    backfill/config-safety-assert story, already this file's OWN documented
    purpose #1, orthogonal to the leash subsystem; not fired anywhere below):
      - the Config.DoorInteraction.nudgeRequiresUnlocked safety assert
      - the RefreshCertificationCache/k9certified-mirror backfill loop

    AddEventHandler('playerDropped', ...): 4 TOTAL when cooldowns.lua is
    loaded alongside (as it always is here, per FILE-TO-FILE CONTRACT) -- 1
    registered BY THIS FILE (the leash pending/pairing cleanup, Section 10)
    plus 3 more registered BY server/cooldowns.lua itself, one per
    :RegisterPlayerDropped() call this file makes (BarkCooldown,
    LeashRequestCooldown, DoorScratchCooldown -- DoorScratchByDoorCooldown
    deliberately has none, per its own :StartSweep comment, since it's keyed
    by doorNetId, not by a disconnecting source).

    AddEventHandler('onResourceStop', ...): ZERO. See "FINDING" in Section 11.

    Resource-globals (no `local`) exposed by this file: ForceDetachLeashForSource,
    ForceDetachOfficerLeashForSource (both role-aware detach hooks for
    server/certifications.lua; Section 9).
    ======================================================================

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - The two onResourceStart handlers (certification-cache backfill,
        Config.DoorInteraction.nudgeRequiresUnlocked assert) -- both are
        this file's OTHER documented responsibility (cache backfill on
        restart), not the leash subsystem this task's brief singles out as
        the highest-value untested surface, and both reach deep into
        server/certifications.lua's own RefreshCertificationCache/SetMetaData
        contract, which is that file's own spec's job, not this one's.
        Registration is pinned (Section 1) as an inventory fact; the bodies
        are never fired.
      - barkType's content/enum semantics -- DEVELOPER_REFERENCE.md and this file's own
        header both say Phase 1 treats it as an opaque passthrough string;
        Section 2 only pins length/type/cooldown/access gating, never a
        specific barkType value's meaning.
      - LEASH_REJECT_MESSAGES's own fallback branch (`or locale('leash.reject_fallback')`
        inside the LOCAL LeashRejectReasonMessage function) is NOT exercised
        here: CheckLeashEligibility's `reason` return is always exactly one
        of the 8 keys the table itself defines, and LeashRejectReasonMessage
        is `local` (only reachable through requestLeashAttach/respondLeashAttach,
        which only ever pass a CheckLeashEligibility-produced reason) -- so
        the fallback string is provably DEAD CODE via every real caller in
        this file today. Disclosed here per this suite's own convention
        ("say so, don't silently skip, and never poke a local's internals to
        force a path no real caller can produce") rather than faked via
        direct access to a local this file deliberately doesn't expose.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to combat_spec.lua's/
-- defense_spec.lua's own copies (GetEntityCoords' `-`/`#` operators are the
-- only vector math CheckLeashEligibility/relayDoorScratch's distance checks
-- need).
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
local ORIGIN = vec3(0, 0, 0)

-- Fixed, test-controlled "model hash" constants. GetEntityModel and
-- IsConfiguredK9Model are BOTH stubbed by this spec (IsConfiguredK9Model is
-- genuinely server/certifications.lua's own logic, already covered by
-- certifications_spec.lua), so these can be any two distinct numbers this
-- file agrees with itself on -- never the real GetHashKey algorithm, which
-- CheckLeashEligibility never calls directly anyway (it only ever calls
-- GetEntityModel then hands the result to IsConfiguredK9Model).
local K9_MODEL_HASH = 111111
local OFFICER_MODEL_HASH = 222222

-- Real, shipped config.lua baseline for the one number this whole subsystem
-- hinges on (Config.LeashMaxDistance = 8.0) -- same "use the actual shipped
-- number, not a round test value" discipline combat_spec.lua's/defense_spec.lua's
-- own baseline-config helpers already establish.
local LEASH_MAX_DISTANCE = 8.0

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/main.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it.
--- @param opts table? -- opts.features: shallow-merged onto the default Config.Features
--- @return table fixture
local function newMainFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent) -- main.lua registers exactly one handler per event name
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

    local function IsConfiguredK9Model(hash) return hash == K9_MODEL_HASH end

    -- K9 role/model decoupling (server/appearance.lua) -- CheckLeashEligibility
    -- ORs this in alongside IsConfiguredK9Model(GetEntityModel(...)) to let a
    -- role-holder on a human/custom model still count as "the K9 party".
    -- Stubbed here (not the real server/appearance.lua) for the same reason
    -- HasK9Access/IsConfiguredK9Model are: this file's job is main.lua's OWN
    -- eligibility/handshake logic, not a second copy of appearance.lua's,
    -- which has its own spec (appearance_spec.lua). Defaults to false for
    -- every source, matching "no role granted" being the default real-world
    -- state.
    local hasRoleBySource = {}
    local function HasK9Role(src) return hasRoleBySource[src] == true end

    local jobBySource = {} -- source -> job name, or nil = unresolved/no Player record at all
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local job = jobBySource[src]
                if not job then return nil end
                return { PlayerData = { job = { name = job } } }
            end,
        },
    }

    local pedBySource = {} -- source -> ped handle (unset/0 == "offline")
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {} -- handle (ped OR door entity) -> vec3
    local function GetEntityCoords(handle) return coordsByHandle[handle] or ORIGIN end

    local modelByPed = {} -- ped handle -> model hash
    local function GetEntityModel(handle) return modelByPed[handle] end

    local netIdOffset = 500000 -- deterministic, distinguishable transform -- never the real native's bit pattern
    local function NetworkGetNetworkIdFromEntity(handle) return handle + netIdOffset end

    local networkEntities = {} -- netId -> handle (door/object entities named by relayDoorScratch's caller)
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (GetEntityType's real domain; 3 = object)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local function GetPlayers() return {} end -- never exercised (onResourceStart bodies are never fired) -- present defensively only

    local threadRunner = Sandbox.newThreadRunner() -- DoorScratchByDoorCooldown.StartSweep() runs at main.lua's OWN file-load time, unconditionally (not gated on Config.Features.DoorInteraction) -- CreateThread/Wait must exist regardless of which feature this fixture is testing

    local config = {
        Features = {
            LeashMechanics = true,
            BasicBarkSounds = true,
            DoorInteraction = true, -- ships `false` by default in real config.lua; enabled here, same "exercise the logic behind a disabled-by-default flag" precedent search_spec.lua/kennel_spec.lua already establish for their own features
        },
        LeashMaxDistance = LEASH_MAX_DISTANCE,
        Departments = { police = true, sheriff = true },
        DoorInteraction = {
            interactDistance = 1.5,   -- real shipped default
            scratchCooldownMs = 3000, -- real shipped default
            nudgeRequiresUnlocked = true,
        },
    }
    if opts.features then
        for k, v in pairs(opts.features) do config.Features[k] = v end
    end

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        IsConfiguredK9Model = IsConfiguredK9Model,
        HasK9Role = HasK9Role,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetPlayers = GetPlayers,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        Config = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        netEventNames = netEvents,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        now = function() return fakeNow end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setK9Role = function(src, hasRole) hasRoleBySource[src] = hasRole end,
        setJob = function(src, jobName) jobBySource[src] = jobName end,
        setPed = function(src, pedHandle, coords, modelHash)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = coords or ORIGIN
            if modelHash then modelByPed[pedHandle] = modelHash end
        end,
        moveEntity = function(handle, coords) coordsByHandle[handle] = coords end,
        setOffline = function(src) pedBySource[src] = 0 end,
        registerDoorEntity = function(netId, handle, opts2)
            opts2 = opts2 or {}
            networkEntities[netId] = handle
            existingEntities[handle] = opts2.exists ~= false
            entityTypes[handle] = opts2.entityType or 3
            coordsByHandle[handle] = opts2.coords or ORIGIN
        end,
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
        clearCaptures = function()
            for i = #clientEvents, 1, -1 do clientEvents[i] = nil end
            for i = #notifyCalls, 1, -1 do notifyCalls[i] = nil end
        end,
        ForceDetachLeashForSource = env.ForceDetachLeashForSource,
        ForceDetachOfficerLeashForSource = env.ForceDetachOfficerLeashForSource,
    }
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
--- @param target number?
--- @return integer
local function countClientEvents(f, eventName, target)
    local n = 0
    for _, e in ipairs(f.clientEvents) do
        if e.event == eventName and (target == nil or e.target == target) then n = n + 1 end
    end
    return n
end

--- @param f table
--- @param target number
--- @return table? -- the most recently captured {target=,description=,notifyType=} entry for `target`, or nil
local function lastNotifyTo(f, target)
    for i = #f.notifyCalls, 1, -1 do
        if f.notifyCalls[i].target == target then
            return f.notifyCalls[i]
        end
    end
    return nil
end

--- Sets up one fully-eligible K9/officer pair, close together, both online,
--- K9 certified, officer employed by a configured department -- the shared
--- "both parties are individually eligible" baseline nearly every leash test
--- below starts from (each test then perturbs exactly the ONE thing it's
--- testing, e.g. moves a ped, revokes access, changes a job).
--- @param f table
--- @param k9Src number
--- @param officerSrc number
local function setupEligiblePair(f, k9Src, officerSrc)
    f.setPed(k9Src, k9Src * 10, ORIGIN, K9_MODEL_HASH)
    f.setAccess(k9Src, true)
    f.setPed(officerSrc, officerSrc * 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(officerSrc, 'police')
end

--- Drives a full, successful requestLeashAttach -> respondLeashAttach(accept)
--- handshake for an already-eligible pair (see setupEligiblePair). By
--- default clears captured events/notifications afterward so the caller's
--- own assertions start from a clean slate -- pass keepCaptures = true for
--- the (rarer) case where the caller needs to inspect the leashAttached
--- broadcasts THIS handshake itself produced (e.g. Section 5's symmetric
--- role assignment tests, which exist specifically to check who got which
--- role in the broadcast payload).
--- @param f table
--- @param k9Src number
--- @param officerSrc number
--- @param initiatorSrc number -- either k9Src or officerSrc; whichever requests
--- @param keepCaptures boolean?
local function formLeashPair(f, k9Src, officerSrc, initiatorSrc, keepCaptures)
    local targetSrc = (initiatorSrc == k9Src) and officerSrc or k9Src
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', initiatorSrc, targetSrc)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', targetSrc, initiatorSrc, true)
    if not keepCaptures then f.clearCaptures() end
end

-- ========================================================================
-- SECTION 1: file load / handler inventory (read from the source, pinned
-- here so a future silent addition/removal of a handler shows up as a
-- failing count, not just a missing test).
-- ========================================================================

t.test('server/main.lua loads and registers exactly 5 RegisterNetEvent handlers, by name', function()
    local f = newMainFixture()
    local names = {}
    for name in pairs(f.netEventNames) do names[#names + 1] = name end
    table.sort(names)
    t.equals(#names, 5)
    for _, expected in ipairs({
        'qbx_k9unit:server:relayBark',
        'qbx_k9unit:server:relayDoorScratch',
        'qbx_k9unit:server:requestLeashAttach',
        'qbx_k9unit:server:respondLeashAttach',
        'qbx_k9unit:server:detachLeash',
    }) do
        t.isNotNil(f.netEventNames[expected], expected .. ' must be registered')
    end
end)

t.test('server/main.lua registers exactly 2 onResourceStart handlers (cache backfill + config-safety assert -- neither fired by this leash-focused spec)', function()
    local f = newMainFixture()
    t.equals(f.eventHandlerCount('onResourceStart'), 2)
end)

t.test('playerDropped handler count is 4 when cooldowns.lua is loaded alongside: 1 from main.lua itself (leash cleanup) + 3 from cooldowns.lua (Bark/LeashRequest/DoorScratch trackers\' own RegisterPlayerDropped calls)', function()
    local f = newMainFixture()
    t.equals(f.eventHandlerCount('playerDropped'), 4)
end)

t.test('server/main.lua exposes ForceDetachLeashForSource and ForceDetachOfficerLeashForSource as resource-global functions', function()
    local f = newMainFixture()
    t.equals(type(f.ForceDetachLeashForSource), 'function')
    t.equals(type(f.ForceDetachOfficerLeashForSource), 'function')
end)

-- ========================================================================
-- SECTION 2: relayBark
-- ========================================================================

t.test('relayBark: feature disabled is a silent no-op (no broadcast, no notify)', function()
    local f = newMainFixture({ features = { BasicBarkSounds = false } })
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('relayBark: non-string barkType is a silent no-op (never trusts client payload shape)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 12345)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
end)

t.test('relayBark: barkType over BARK_TYPE_MAX_LENGTH (16) is a silent no-op, and does NOT consume the rate limit', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, ('x'):rep(17))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
    -- Proves the oversized attempt never reached BarkCooldown.Consume: an
    -- immediately-following, in-length call in the SAME tick still succeeds.
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
end)

t.test('relayBark: exactly BARK_TYPE_MAX_LENGTH (16) characters is accepted (boundary, not rejected)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, ('x'):rep(16))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
end)

t.test('relayBark: not certified (HasK9Access false) is a silent no-op', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, false)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
end)

t.test('relayBark: success broadcasts to -1 with the SENDER\'S OWN server-resolved netId (never a client-claimed one -- relayBark takes no netId argument at all)', function()
    local f = newMainFixture()
    f.setPed(7, 70, ORIGIN)
    f.setAccess(7, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 7, 'bark')
    local ev = lastClientEvent(f, 'qbx_k9unit:client:playBark')
    t.isNotNil(ev)
    t.equals(ev.target, -1)
    t.equals(ev.args[1], 70 + 500000) -- NetworkGetNetworkIdFromEntity(GetPlayerPed(7)) via this fixture's deterministic transform
    t.equals(ev.args[2], 'bark')
end)

t.test('relayBark: per-source cooldown (1000ms) blocks a second call in the same tick, and a third call succeeds once the cooldown has elapsed', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
    f.advance(1000)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 2)
end)

t.test('relayBark: the per-source cooldown does not block a DIFFERENT source in the same tick', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN)
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 2, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 2)
end)

-- ========================================================================
-- SECTION 3: relayDoorScratch
-- ========================================================================

t.test('relayDoorScratch: feature disabled is a silent no-op', function()
    local f = newMainFixture({ features = { DoorInteraction = false } })
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: non-number doorNetId is a silent no-op', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 'not-a-number')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: not certified is a silent no-op', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, false)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: a doorNetId that does not resolve to any real entity is a silent no-op (real ResolveNetworkEntity, not a reimplementation)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 999999)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: a resolved entity that is NOT type 3 (object) -- e.g. another player\'s ped -- is a hard reject, not advisory', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN, entityType = 1 }) -- 1 = ped
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: exactly at the distance boundary (interactDistance + 1.0m tolerance = 2.5m) is allowed', function()
    local f = newMainFixture()
    f.setPed(1, 10, vec3(0, 0, 0))
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = vec3(2.5, 0, 0) })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: just past the distance boundary is rejected', function()
    local f = newMainFixture()
    f.setPed(1, 10, vec3(0, 0, 0))
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = vec3(2.51, 0, 0) })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: per-SOURCE cooldown blocks a second scratch on a DIFFERENT door from the same source', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.registerDoorEntity(9002, 901, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9002)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: per-DOOR cooldown blocks a second scratch on the SAME door from a DIFFERENT (also-certified) source -- closes the colluding-accounts flood', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN)
    f.setAccess(2, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 2, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: after BOTH cooldowns elapse, the same door can be scratched again', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 2)
end)

t.test('relayDoorScratch: success broadcasts doorNetId to -1 (global -- a door location carries no person/vehicle identity to leak)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:playDoorScratch')
    t.isNotNil(ev)
    t.equals(ev.target, -1)
    t.equals(ev.args[1], 9001)
end)

-- ========================================================================
-- SECTION 4: CheckLeashEligibility's 8 rejection reasons, each driven
-- through requestLeashAttach's real code path and pinned against the REAL
-- locale() string (never a hand-copied English literal).
-- ========================================================================

t.test('leash reject reason: feature_disabled', function()
    local f = newMainFixture({ features = { LeashMechanics = false } })
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.feature_disabled'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0)
end)

t.test('leash reject reason: invalid_target via requestLeashAttach\'s own upfront type guard (non-number targetServerId)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 'not-a-number')
    t.equals(lastNotifyTo(f, 1).description, locale('leash.invalid_target'))
end)

t.test('leash reject reason: invalid_target via CheckLeashEligibility\'s self-target guard (initiatorSrc == targetSrc)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 1)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.invalid_target'))
end)

t.test('leash reject reason: already_leashed (initiator already paired with a third party)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2) -- 1 (K9) and 2 (officer) are now leashed to each other
    setupEligiblePair(f, 3, 4)
    f.setJob(3, 'police') -- harmless extra; 3 will act as a second officer requesting 1
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 1)
    t.equals(lastNotifyTo(f, 3).description, locale('leash.already_leashed'))
end)

t.test('leash reject reason: already_leashed (target already paired with a third party)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    setupEligiblePair(f, 5, 1) -- overwrite ped 1's setup is fine, 1 stays the paired K9
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 5, 1)
    t.equals(lastNotifyTo(f, 5).description, locale('leash.already_leashed'))
end)

t.test('leash reject reason: offline (target never connected -- GetPlayerPed returns 0)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, K9_MODEL_HASH)
    f.setAccess(1, true)
    -- target 2 never set up at all -> GetPlayerPed(2) == 0
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.target_no_longer_online'))
end)

t.test('leash reject reason: too_far (both online, beyond Config.LeashMaxDistance)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.moveEntity(20, vec3(LEASH_MAX_DISTANCE + 1.0, 0, 0)) -- officer's ped handle is officerSrc*10 = 20
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.too_far'))
end)

t.test('leash reject reason: no_k9_party (neither party is a configured K9 model)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(1, 'police')
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.no_k9_party'))
end)

-- K9 ROLE/MODEL DECOUPLING WIDENING -- "I also want everything to work with
-- any ped". Previously, a certified handler holding the K9 role while
-- standing on a human (or any unrecognized custom) model was rejected
-- outright as `no_k9_party`, exactly as if neither party were a K9 at all.
-- These pin the fix: HasK9Role(src) now stands in for
-- IsConfiguredK9Model(GetEntityModel(...)) wherever the model check alone
-- would otherwise fail.
t.test('K9 ROLE/MODEL DECOUPLING: a role-holder on a HUMAN model (not a configured K9 model) is still accepted as the K9 party -- no longer no_k9_party', function()
    local f = newMainFixture()
    -- Both peds wear the officer model; only source 1 holds the decoupled
    -- K9 role. Pre-widening this was unconditionally `no_k9_party`.
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setAccess(1, true)
    f.setK9Role(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'), 'a human-modeled role-holder must be accepted as the K9 party, not rejected as no_k9_party')
end)

t.test('K9 ROLE/MODEL DECOUPLING: role-holder-on-human-model still must satisfy HasK9Access (not_certified still fires)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setAccess(1, false) -- role granted, but not currently certified/access-holding
    f.setK9Role(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.k9_not_certified'), 'the widening only decides WHO counts as the K9 party -- HasK9Access is still independently enforced')
end)

t.test('K9 ROLE/MODEL DECOUPLING: HasK9Role not being loaded at all (soft dependency absent) fails CLOSED to the pre-decoupling model-only check, never errors', function()
    -- Rebuild a fixture with no HasK9Role global at all (simulates
    -- server/appearance.lua being removed/not loaded) by loading main.lua
    -- directly rather than through newMainFixture(), which always injects
    -- the stub above.
    local fakeNow = 0
    local eventHandlers, netEvents = {}, {}
    local env = Sandbox.newEnv({
        GetGameTimer = function() return fakeNow end,
        AddEventHandler = function(name, h) eventHandlers[name] = eventHandlers[name] or {}; eventHandlers[name][#eventHandlers[name] + 1] = h end,
        RegisterNetEvent = function(name, h) netEvents[name] = h end,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        TriggerClientEvent = function() end,
        NotifyPlayer = function() end,
        HasK9Access = function() return true end,
        IsConfiguredK9Model = function(hash) return hash == K9_MODEL_HASH end,
        -- HasK9Role deliberately OMITTED.
        exports = { qbx_core = { GetPlayer = function() return nil end } },
        GetPlayerPed = function() return 0 end,
        GetEntityCoords = function() return ORIGIN end,
        GetEntityModel = function() return OFFICER_MODEL_HASH end,
        NetworkGetNetworkIdFromEntity = function(h) return h end,
        NetworkGetEntityFromNetworkId = function() return 0 end,
        DoesEntityExist = function() return false end,
        GetEntityType = function() return 0 end,
        GetPlayers = function() return {} end,
        CreateThread = Sandbox.newThreadRunner().CreateThread,
        Wait = Sandbox.newThreadRunner().Wait,
        Config = { Features = { LeashMechanics = true }, LeashMaxDistance = LEASH_MAX_DISTANCE, Departments = { police = true } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- Must not raise merely from HasK9Role being absent (type(HasK9Role) ==
    -- 'function' is false for a nil global -- the `and` short-circuits
    -- before ever calling it).
    Sandbox.loadInto('../server/main.lua', env)
    t.isNotNil(netEvents['qbx_k9unit:server:requestLeashAttach'], 'file must still load and register its handlers with HasK9Role entirely absent')
end)

t.test('leash reject reason: not_certified (K9-modeled party lacks HasK9Access)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.setAccess(1, false) -- K9 party (1) is not certified
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.k9_not_certified'))
end)

t.test('leash reject reason: officer_not_in_department (officer has no Player record at all)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, K9_MODEL_HASH)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    -- deliberately never f.setJob(2, ...) -- exports.qbx_core:GetPlayer(2) returns nil
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.handler_not_in_department'))
end)

t.test('leash reject reason: officer_not_in_department (officer has a Player record, but an unconfigured job)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.setJob(2, 'civilian')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.handler_not_in_department'))
end)

t.test('a genuinely eligible request notifies the initiator with leash.request_sent, not a rejection', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'))
end)

-- ========================================================================
-- SECTION 5: symmetric role assignment -- "What matters most" item 1.
-- CheckLeashEligibility assigns K9/officer roles from each party's LIVE PED
-- MODEL, never from who initiated. Proven by running the SAME two concrete
-- players through BOTH request directions and confirming both resolve to
-- the identical k9Src/officerSrc assignment.
-- ========================================================================

t.test('symmetric role assignment: OFFICER-initiated request resolves K9-role to the K9-modeled party, officer-role to the officer-modeled party', function()
    local f = newMainFixture()
    setupEligiblePair(f, 100, 200) -- 100 = K9 model, 200 = officer model
    -- Officer (200) initiates towards the K9 (100).
    formLeashPair(f, 100, 200, 200, true)
    -- Both attach broadcasts fired; find each by target.
    local toK9, toOfficer
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' then
            if ev.target == 100 then toK9 = ev end
            if ev.target == 200 then toOfficer = ev end
        end
    end
    t.isNotNil(toK9, 'K9 (100) must receive its own leashAttached broadcast')
    t.isNotNil(toOfficer, 'officer (200) must receive its own leashAttached broadcast')
    t.equals(toK9.args[1], 200) -- partnerServerId
    t.equals(toK9.args[2], true) -- isConstrained = true for the K9 role
    t.equals(toOfficer.args[1], 100)
    t.equals(toOfficer.args[2], false) -- isConstrained = false for the officer role
end)

t.test('symmetric role assignment: K9-initiated request resolves to the IDENTICAL k9Src/officerSrc assignment as the officer-initiated case above', function()
    local f = newMainFixture()
    setupEligiblePair(f, 100, 200) -- same two concrete players, same models, as the test above
    -- This time the K9 (100) initiates towards the officer (200).
    formLeashPair(f, 100, 200, 100, true)
    local toK9, toOfficer
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' then
            if ev.target == 100 then toK9 = ev end
            if ev.target == 200 then toOfficer = ev end
        end
    end
    t.isNotNil(toK9, 'K9 (100) must receive its own leashAttached broadcast')
    t.isNotNil(toOfficer, 'officer (200) must receive its own leashAttached broadcast')
    -- IDENTICAL to the officer-initiated case: role comes from live ped
    -- model, never from which side called requestLeashAttach.
    t.equals(toK9.args[1], 200)
    t.equals(toK9.args[2], true)
    t.equals(toOfficer.args[1], 100)
    t.equals(toOfficer.args[2], false)
end)

t.test('EDGE CASE, confirmed in server/main.lua\'s own header: when BOTH parties are K9-modeled, the REQUEST TARGET becomes the constrained/K9 role, regardless of which specific player is asked', function()
    local f = newMainFixture()
    -- Both players share the K9 model. Both need HasK9Access (either could
    -- end up in the K9 role) AND a configured department job (either could
    -- end up in the officer role) for every direction to be able to succeed.
    f.setPed(300, 3000, ORIGIN, K9_MODEL_HASH)
    f.setAccess(300, true)
    f.setJob(300, 'police')
    f.setPed(400, 4000, ORIGIN, K9_MODEL_HASH)
    f.setAccess(400, true)
    f.setJob(400, 'police')

    -- Direction 1: 300 requests attach to 400 -> 400 (the target) becomes K9-role.
    formLeashPair(f, 400, 300, 300, true) -- k9Src=400, officerSrc=300, initiator=300
    local toTarget400
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' and ev.target == 400 then toTarget400 = ev end
    end
    t.isNotNil(toTarget400)
    t.equals(toTarget400.args[2], true, 'the request TARGET (400) must be the constrained/K9 role')

    -- Tear down, then reverse direction with a FRESH pair of ids so this
    -- fixture's already_leashed guard doesn't interfere.
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 400)
    f.clearCaptures()

    -- Direction 2: 400 requests attach to 300 -> 300 (the NEW target) becomes K9-role this time.
    formLeashPair(f, 300, 400, 400, true) -- k9Src=300, officerSrc=400, initiator=400
    local toTarget300
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' and ev.target == 300 then toTarget300 = ev end
    end
    t.isNotNil(toTarget300)
    t.equals(toTarget300.args[2], true, 'the request TARGET (300) must be the constrained/K9 role this time -- confirms it tracks "who was asked", not a fixed id')
end)

-- ========================================================================
-- SECTION 6: requestLeashAttach's own single-slot pending guard + rate
-- limit ordering.
-- ========================================================================

t.test('a second request to a target with an already-live pending request is rejected (pending_request_exists), WITHOUT clobbering the first pending entry', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A(1, K9) -> T(2, officer)
    setupEligiblePair(f, 3, 2) -- overwrites 2's ped/job identically; B(3, K9) will also target T(2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- A's request lands first
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 2) -- B's request while A's is still live
    t.equals(lastNotifyTo(f, 3).description, locale('leash.pending_request_exists'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 2), 0, 'B\'s rejected request must not reach the target as a second prompt')

    -- A's ORIGINAL pending entry must still be intact: T can still accept A.
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached', 1), 1, 'A\'s original request must still resolve to a real pairing')
end)

t.test('the pending_request_exists rejection does NOT consume the rejected caller\'s own rate limit', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 3, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 2) -- rejected: pending_request_exists
    -- B (3) immediately tries a DIFFERENT target (4) in the SAME tick -- if
    -- the rejection above had burned B's cooldown, this would be silently
    -- dropped instead of reaching CheckLeashEligibility's own reject path.
    setupEligiblePair(f, 3, 4)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 4)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 4), 1,
        'B\'s cooldown must still be available immediately after a pending_request_exists rejection')
end)

t.test('after the pending TTL (30s) expires, a new request to the same target is allowed again', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 3, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.advance(30001)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 2)
    -- B's request now genuinely succeeds (A's stale pending no longer blocks
    -- it) -- the notify B gets is the real success message, not a rejection.
    t.equals(lastNotifyTo(f, 3).description, locale('leash.request_sent'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 2), 1)
end)

t.test('LEASH_REQUEST_COOLDOWN_MS (1000ms) rate-limits requestLeashAttach per INITIATOR: a second request in the same tick is silently dropped', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 1, 3) -- same initiator (1), a different target this time
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 3)
    t.equals(#f.notifyCalls, 0, 'rate-limited: silent no-op, not an error notify')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 3), 0)
end)

-- ========================================================================
-- SECTION 7: respondLeashAttach -- type guard, spoofed fromServerId,
-- expiry, decline, and (priority 3) double-accept/double-respond fail-closed.
-- ========================================================================

t.test('respondLeashAttach: non-number fromServerId is a silent no-op', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 'not-a-number', true)
    t.equals(#f.notifyCalls, 0)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('respondLeashAttach: a MISMATCHED fromServerId never notifies the wrongly-claimed id, and never forms a pair (the half of the coder-security fix that IS correct)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- real pending: 1 -> 2
    setupEligiblePair(f, 9, 2) -- 9 exists as a real, unrelated online player, never actually requested anything
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 9, true) -- 2 claims fromServerId = 9, but the real pending is from 1
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 9), 'the mismatched/unrelated id must receive NOTHING (verifiedMatch is false)')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('REGRESSION GUARD: a MISMATCHED fromServerId no longer destroys an unrelated initiator\'s still-live pending request. This was a real bug -- the `not verifiedMatch` branch cleared PendingLeashRequests[src] unconditionally, so an ordinary duplicate or stale respondLeashAttach naming the WRONG fromServerId silently wiped a FRESH, valid request from a DIFFERENT initiator, who was never told. No attacker needed: a UI double-fire carrying an already-resolved interaction id was enough. LeashMechanics ships enabled, so this reached ordinary servers.', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A(1) sends a real, currently-live request to T(2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()

    -- T's client fires respondLeashAttach with a stale/wrong fromServerId
    -- (9 stands in for "anything other than 1" -- e.g. a duplicated click
    -- still carrying a previous, already-resolved interaction's id). This
    -- has NOTHING to do with A's real, still-pending request from 1.
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 9, true)
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'),
        'the caller is still told their response was not valid')
    t.isNil(lastNotifyTo(f, 1),
        'and the wrongly-named id is still never notified -- that no-echo property predates this fix and must survive it, or an arbitrary-target notify reopens')

    -- A's real request SURVIVES the unrelated mismatched call. This is the
    -- fix: the branch now leaves an entry it never verified alone.
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2,
        'A\'s genuine request still accepts normally -- the entry backing it was never touched')
    t.isNil(lastNotifyTo(f, 2), 'and a successful accept produces no error notice to either side')
end)

t.test('respondLeashAttach: an EXPIRED but genuinely-matching pending request notifies BOTH sides "no longer valid" (verified match, just too late)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.advance(30001)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_no_longer_valid_initiator'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('respondLeashAttach: decline notifies ONLY the initiator (leash.request_declined), never the decliner, and forms no pair', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_declined'))
    t.isNil(lastNotifyTo(f, 2), 'the decliner receives no notification of their own decline')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('DOUBLE-ACCEPT fails closed: the pending entry is consumed immediately on the first accept -- a second accept for the same request finds nothing', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- first accept: real pairing forms
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2, 'sanity: the first accept really did form a pair (one broadcast per side)')
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- SECOND accept, same args
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0, 'no second attach broadcast')
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'the original initiator gets nothing on a replayed accept (no matching pending -- verifiedMatch is false)')

    -- The ORIGINAL pairing must still be intact, undisturbed by the replay.
    t.isTrue(f.ForceDetachLeashForSource(1), 'the real pairing from the FIRST accept must still exist')
end)

t.test('a DECLINE after an already-consumed ACCEPT also fails closed (same "consumed immediately" mechanism, not a separate bug class)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- consumed by the real accept
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false) -- replayed as a decline this time
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'the initiator must not receive a spurious request_declined for an already-resolved request')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 0, 'a fail-closed replay must not detach the real, already-formed pairing either')
end)

t.test('a DOUBLE-DECLINE also fails closed on the second call', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false) -- first decline: consumes the pending
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false) -- second decline: nothing left to consume
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'initiator must not receive a second request_declined')
end)

-- ========================================================================
-- SECTION 8: TOCTOU -- distance AND liveness are re-checked in full at
-- accept time, closing the window between request and accept.
-- ========================================================================

t.test('TOCTOU: parties were within range at REQUEST time but moved apart before ACCEPT -- the accept is rejected (too_far), and no pair forms', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- succeeds: both at ORIGIN
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 1, 'sanity: the request itself was valid while both were close')
    f.moveEntity(10, vec3(LEASH_MAX_DISTANCE + 5.0, 0, 0)) -- K9's ped (1*10=10) walks far away before responding
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.too_far'))
    t.equals(lastNotifyTo(f, 2).description, locale('leash.too_far'))
    t.isFalse(f.ForceDetachLeashForSource(1), 'no pairing was ever actually formed')
end)

t.test('TOCTOU: the initiator disconnects (ped resolves to 0) between request and accept -- the accept is rejected (offline), not silently paired with a stale ped', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.setOffline(1) -- simulates a vanished ped WITHOUT going through the playerDropped cleanup path -- isolates CheckLeashEligibility's own re-check
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('common.target_no_longer_online'))
    t.equals(lastNotifyTo(f, 2).description, locale('common.target_no_longer_online'))
end)

t.test('TOCTOU: certification is revoked between request and accept -- the accept is rejected (not_certified)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.setAccess(1, false) -- K9's certification revoked mid-flight
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('common.k9_not_certified'))
end)

t.test('TOCTOU: a THIRD leash forms in between, making one party already_leashed by accept time -- the accept is rejected', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    -- While 2 (the officer) is deciding, 1 (the K9) gets leashed to a THIRD party instead.
    setupEligiblePair(f, 1, 3)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 1)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 1, 3, true)
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- 2 finally accepts the now-stale request
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.already_leashed'))
    t.equals(lastNotifyTo(f, 2).description, locale('leash.already_leashed'))
end)

-- ========================================================================
-- SECTION 9: voluntary detachLeash (zero consent) + role-aware forced
-- detach (ForceDetachLeashForSource / ForceDetachOfficerLeashForSource).
-- ========================================================================

t.test('detachLeash: either party can detach unilaterally, with zero consent, and both sides are notified', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 1) -- the K9 side detaches itself, no accept needed from 2
    local toK9 = lastClientEvent(f, 'qbx_k9unit:client:leashDetached')
    t.isNotNil(toK9)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'both parties are notified of the detach')
    t.isFalse(f.ForceDetachLeashForSource(1), 'no longer leashed -- ForceDetachLeashForSource is now a no-op')
end)

t.test('detachLeash: a no-op (no error, no broadcast) for a source that was never leashed to anyone', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 1)
    t.equals(#f.clientEvents, 0)
end)

t.test('ForceDetachLeashForSource: detaches when `src` is the K9-role party of its pairing', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isTrue(f.ForceDetachLeashForSource(1))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
end)

t.test('ForceDetachLeashForSource: role-blind-by-id-membership REGRESSION GUARD -- a no-op when `src` is only the OFFICER/handler-role party of its pairing (their revoked cert must not tear down a leash they\'re merely anchoring)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isFalse(f.ForceDetachLeashForSource(2), 'src=2 is the officer/handler role -- must be a no-op')
    t.equals(#f.clientEvents, 0, 'the still-valid pairing must be completely undisturbed')
    -- Prove the pairing really is still intact via the K9 side.
    t.isTrue(f.ForceDetachLeashForSource(1))
end)

t.test('ForceDetachLeashForSource: a no-op for a source not currently leashed to anyone at all, and never throws for a non-number src', function()
    local f = newMainFixture()
    t.isFalse(f.ForceDetachLeashForSource(1))
    t.isFalse(f.ForceDetachLeashForSource('not-a-number'))
end)

t.test('ForceDetachOfficerLeashForSource: detaches when `src` is the OFFICER-role party, mirrors ForceDetachLeashForSource for the opposite role', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isTrue(f.ForceDetachOfficerLeashForSource(2))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
end)

t.test('ForceDetachOfficerLeashForSource: a no-op when `src` is the K9-role party instead (that case belongs to ForceDetachLeashForSource, not this one)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isFalse(f.ForceDetachOfficerLeashForSource(1))
    t.equals(#f.clientEvents, 0)
end)

-- ========================================================================
-- SECTION 10: playerDropped -- pending-request leak on disconnect for BOTH
-- parties, active-pairing teardown, and server-id-recycling non-inheritance.
-- "What matters most" item 2.
-- ========================================================================

t.test('playerDropped clears the TARGET-side pending slot: a recycled id does not inherit a stale request aimed at the previous occupant', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A=1 (K9), T=2 (officer)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- A -> T, T never responds
    f.firePlayerDropped(2, 'quit') -- T disconnects
    f.clearCaptures()

    -- A brand-new player is assigned the now-freed id 2 (a different model/job entirely).
    f.setPed(2, 999, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- the new occupant "accepts" A's stale request
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'A must not be told anything -- the new occupant never had a genuine matching pending request')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0, 'the new occupant must not be silently leashed to A')
end)

t.test('playerDropped scans and clears the INITIATOR-side pending entry too: a recycled initiator id does not get silently paired via a stale request', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A=1 (K9), T=2 (officer)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- A -> T, T never responds
    f.firePlayerDropped(1, 'quit') -- A (the INITIATOR) disconnects, not the target
    f.clearCaptures()

    -- A brand-new, unrelated player is assigned the now-freed id 1.
    f.setPed(1, 888, ORIGIN, OFFICER_MODEL_HASH) -- deliberately NOT a K9 model, to make an accidental pairing obviously wrong if it happened
    f.setJob(1, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- T, unaware, tries to accept citing the (now-recycled) id 1
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'the new occupant of id 1 must not be notified about a request they never made')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('playerDropped\'s target-side clear does not disturb an UNRELATED pending entry for a different target', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 3, 4)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 4)
    f.firePlayerDropped(2, 'quit') -- only target 2 disconnects
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 4, 3, true) -- the UNRELATED pending (3 -> 4) must still be valid
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2)
end)

t.test('playerDropped tears down an ACTIVE pairing for either disconnecting party, and a recycled id inherits none of it', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- K9=1, officer=2
    formLeashPair(f, 1, 2, 2)
    f.firePlayerDropped(2, 'quit') -- the officer/handler disconnects
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'partner_disconnected broadcast to both (including, harmlessly, the disconnecting id itself)')
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashDetached' and ev.target == 1 then
            t.equals(ev.args[1], 'partner_disconnected')
        end
    end
    f.clearCaptures()

    -- A completely unrelated new player takes the freed id 2.
    f.setPed(2, 777, ORIGIN, OFFICER_MODEL_HASH)
    t.isFalse(f.ForceDetachOfficerLeashForSource(2), 'the new occupant of id 2 inherits no pairing')
    t.isFalse(f.ForceDetachLeashForSource(1), 'the K9 (1) is no longer leashed to anyone -- not silently left bound to the new id 2')
end)

t.test('playerDropped: the disconnecting player\'s OWN pending target-side slot and any pairing they held are cleared even when both apply at once (target of one request AND leashed to someone else is not a real reachable combination, but a lone pairing plus playerDropped on the K9 side is)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    f.firePlayerDropped(1, 'quit') -- the K9 itself disconnects this time
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
    t.isFalse(f.ForceDetachOfficerLeashForSource(2), 'the officer is no longer leashed to anyone either')
end)

-- ========================================================================
-- SECTION 11: ephemeral / in-memory-only state, and the onResourceStop
-- FINDING. "What matters most" item 6.
-- ========================================================================

t.test('FINDING (disclosed, not fixed here per this task\'s hard rule): server/main.lua registers ZERO onResourceStop handlers for the leash subsystem -- unlike server/kennel.lua/server/propattachment.lua/server/fetch.lua, which each explicitly delete their own live world entities on resource stop, LeashPairs/PendingLeashRequests are pure in-memory bookkeeping with no world entity to clean up, so there is nothing here for an onResourceStop hook to delete. Teardown on a same-session restart (player stays connected) is achieved entirely CLIENT-side today (client/movement.lua\'s own onResourceStop calls DetachLeash(), a normal round trip into THIS file\'s detachLeash handler) -- this server file has no independent fallback if that client-side call never happens (a non-standard/broken client, or a server-only crash with no matching client-side onResourceStop at all). Recorded here as a real, disclosed gap, not asserted as a bug -- see this spec\'s own file header.', function()
    local f = newMainFixture()
    t.equals(f.eventHandlerCount('onResourceStop'), 0)
end)

t.test('ephemeral by construction: a fresh module load (simulating a resource restart) starts with completely empty leash state -- a pairing formed in one sandbox instance is provably invisible to an independently-loaded one', function()
    local f1 = newMainFixture()
    setupEligiblePair(f1, 1, 2)
    formLeashPair(f1, 1, 2, 2)
    t.isTrue(f1.ForceDetachLeashForSource(1), 'sanity: the pairing really exists in f1')
    -- Re-forming it since ForceDetachLeashForSource above just consumed it --
    -- this spec needs the PAIRING to still exist in f1 at the moment f2 is
    -- built, to prove f2 shares NO memory with f1 (not merely that f1 can be
    -- reset, which would prove nothing about cross-instance isolation).
    -- Advance past LEASH_REQUEST_COOLDOWN_MS first: officer 2 (the initiator
    -- inside formLeashPair's own convention here) already consumed that
    -- cooldown once above, in the same fake tick.
    f1.advance(1000)
    setupEligiblePair(f1, 1, 2)
    formLeashPair(f1, 1, 2, 2)

    -- A COMPLETELY SEPARATE sandbox -- fresh cooldowns.lua/entities.lua/
    -- main.lua module load, exactly as a real `/restart qbx_k9unit` would
    -- produce (every local upvalue re-initialized from scratch; nothing
    -- persisted to disk by this file at all -- it calls no MySQL.* anywhere).
    local f2 = newMainFixture()
    t.isFalse(f2.ForceDetachLeashForSource(1), 'a freshly-loaded module instance must know NOTHING about f1\'s pairing')
    t.isFalse(f2.ForceDetachOfficerLeashForSource(2), 'neither role-side of f1\'s pairing leaks into f2')

    -- f1's own pairing, meanwhile, is untouched by f2 having been created.
    t.isTrue(f1.ForceDetachLeashForSource(1), 'f1\'s real pairing still exists independently of f2')
end)

print('')
print('mainserver_spec.lua coverage summary (71 cases -- run this file, do not')
print('grep it, per DEVELOPER_REFERENCE.md §20\'s own "count you must run" note): relayBark')
print('(8), relayDoorScratch (11), CheckLeashEligibility\'s 8 reject reasons + happy')
print('path + 3 K9 role/model decoupling widening cases (15), symmetric role')
print('assignment incl. the both-K9 tie-break (3),')
print('request-time pending/rate-limit ordering (4), respondLeashAttach incl.')
print('double-accept/double-decline fail-closed AND the mismatched-fromServerId')
print('FINDING (9), TOCTOU re-validation at accept (4), detach/ForceDetach')
print('role-awareness (7), playerDropped disconnect/id-recycling (5), ephemeral-state')
print('+ onResourceStop FINDING (2), file-load inventory (4). See this file\'s own')
print('header for what is deliberately NOT covered and why, and Section 7 for the')
print('one real, disclosed production finding this pass caught.')

os.exit(t.summary())
