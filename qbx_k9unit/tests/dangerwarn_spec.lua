--[[
    tests/dangerwarn_spec.lua

    First test coverage for server/dangerwarn.lua (the reverse direction of
    HandlerDownDefense -- a K9's own player, not an automatic detector,
    deliberately warning their partnered handler). Loads the REAL,
    unmodified server/cooldowns.lua -> server/dangerwarn.lua chain into one
    sandbox (the fxmanifest.lua server_scripts order this pass proposes),
    and drives it entirely through its one real entry point: the captured
    'qbx_k9unit:server:requestDangerWarn' RegisterNetEvent handler. Nothing
    here reimplements that file's own decision logic; every assertion is
    against an OBSERVABLE side effect (a captured NotifyPlayer call, a
    captured TriggerClientEvent call, a printed warning line) of the real
    production code running for real -- same discipline
    tests/defense_spec.lua and tests/pursuitsprint_spec.lua already
    established for their own files.

    LOCALE: server/dangerwarn.lua may not edit locales/en.json directly, so
    every new player-facing string it introduces is resolved through
    `pcall(locale, 'dangerwarn.<key>', ...)` with a hardcoded, byte-identical
    English fallback (see that file's own header closing section). This
    spec therefore asserts against those exact fallback strings directly --
    NOT via Sandbox.locale, since none of these keys exist in locales/en.json
    yet -- and separately proves (see "LOCALE UPGRADE PATH" below) that a
    landed key is preferred over the fallback the moment it exists, without
    needing any further code change.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to tests/defense_spec.lua's
-- own copy (the only other file needing GetEntityCoords' `-`/`#` operators
-- plus direct x/y field access for this file's own bearing calculation).
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
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @return table
local function baselineDangerWarnConfig()
    return {
        cooldownMs = 15000,
        audibleRadius = 30.0,
        distanceBuckets = { close = 15.0, nearby = 50.0, far = 150.0 },
        Types = {
            Alert  = { soundName = 'Bark_Alert', notifyType = 'warning' },
            Threat = { soundName = 'Bark_Aggressive', notifyType = 'error' },
        },
        keybind = 'N',
    }
end

--- Builds one complete, independent sandbox for server/dangerwarn.lua, with
--- the real server/cooldowns.lua loaded alongside it first (the exact
--- fxmanifest.lua server_scripts order this pass proposes), and every
--- other cross-file/native dependency as a test-controlled stub.
--- @param opts table? -- { featureOn (default true), dangerWarnCfg, hasK9Access, noPartnershipModule, noPermissionModule, noForEachNearbyPlayer, featureControlCfg }
--- @return table fixture
local function newDangerWarnFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local netEvents = {} -- eventName -> handler
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {} -- { {target=, description=, notifyType=}, ... }
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- HasK9Access(src) -- test-controlled, mirrors this file's own bare,
    -- unguarded call convention (server/certifications.lua is a hard,
    -- always-loaded dependency, per this file's own header).
    local accessBySource = {}
    local function HasK9Access(src) return accessBySource[src] == true end
    if opts.hasK9Access then
        for src, allowed in pairs(opts.hasK9Access) do accessBySource[src] = allowed end
    end

    -- exports.qbx_core:GetPlayer(src) / GetPlayerByCitizenId(citizenid)
    local playersBySource = {} -- src -> { citizenid = }
    local sourceByCitizenid = {}
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        local src = sourceByCitizenid[citizenid]
        if not src then return nil end
        return { PlayerData = { source = src } }
    end

    -- server/partnership.lua's real accessor, stubbed
    local partnerByCitizenid = {} -- citizenid -> { partner = citizenid, isK9 = bool }
    local function GetActivePartnerCitizenId(citizenid)
        local entry = partnerByCitizenid[citizenid]
        if not entry then return nil, false end
        return entry.partner, entry.isK9
    end

    -- server/permissions.lua's real accessor, stubbed
    local permissionsByCitizenidAndKey = {} -- citizenid -> key -> true|false
    local function HasPermission(citizenid, key)
        local byKey = permissionsByCitizenidAndKey[citizenid]
        return byKey ~= nil and byKey[key] == true
    end

    -- server/search.lua's real accessor, stubbed -- pure, read-only
    -- "who is near this point right now" fan-out. Faithfully mirrors that
    -- file's real implementation shape (distance-filtered over a
    -- test-controlled set of connected players), so this fixture's
    -- audible-radius tests exercise real distance-filtering logic, not a
    -- pass-through.
    local nearbyPlayers = {} -- { { id = , coords = vec3 }, ... }
    local function ForEachNearbyPlayer(coords, radius, callback)
        for _, entry in ipairs(nearbyPlayers) do
            if #(entry.coords - coords) <= radius then
                callback(entry.id)
            end
        end
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 900000) end

    local dangerWarnCfg = opts.dangerWarnCfg
    if dangerWarnCfg == nil then dangerWarnCfg = baselineDangerWarnConfig() end
    -- opts.dangerWarnCfg == false means "Config.DangerWarn is entirely
    -- absent" -- see the dedicated "MISSING Config.DangerWarn block" tests
    -- below. A plain table (including {}) is passed through as-is.
    local config = {
        Features = { DangerWarn = opts.featureOn ~= false },
        DangerWarn = (dangerWarnCfg == false) and nil or dangerWarnCfg,
        FeatureControl = opts.featureControlCfg,
    }

    -- DangerWarnCooldown.RegisterPlayerDropped() (server/cooldowns.lua)
    -- calls AddEventHandler('playerDropped', ...) at THIS FILE's own
    -- file-load time -- a real, working stub is required here even though
    -- most tests in this file never fire it directly (the dedicated
    -- 'CLEANUP -- playerDropped' section below builds its OWN inline env
    -- to inspect it) -- without one, EVERY fixture in this file would fail
    -- to load server/dangerwarn.lua at all.
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        HasK9Access = HasK9Access,
        exports = {
            qbx_core = {
                GetPlayer = qbxGetPlayer,
                GetPlayerByCitizenId = qbxGetPlayerByCitizenId,
            },
        },
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        Config = config,
    }
    if not opts.noPartnershipModule then
        envOverrides.GetActivePartnerCitizenId = GetActivePartnerCitizenId
    end
    if not opts.noPermissionModule then
        envOverrides.HasPermission = HasPermission
    end
    if not opts.noForEachNearbyPlayer then
        envOverrides.ForEachNearbyPlayer = ForEachNearbyPlayer
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/dangerwarn.lua', env)

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        printedLines = printedLines,
        netEventNames = netEvents,
        requestDangerWarn = function(src, warnType)
            local handler = netEvents['qbx_k9unit:server:requestDangerWarn']
            assert(handler, 'qbx_k9unit:server:requestDangerWarn was never registered')
            env.source = src
            handler(warnType)
            env.source = nil
        end,
        setAccess = function(src, allowed) accessBySource[src] = allowed end,
        setPlayer = function(src, citizenid)
            playersBySource[src] = { citizenid = citizenid }
            if citizenid then sourceByCitizenid[citizenid] = src end
        end,
        clearPlayerSource = function(citizenid) sourceByCitizenid[citizenid] = nil end,
        setPartner = function(citizenid, partnerCitizenid, isK9)
            partnerByCitizenid[citizenid] = { partner = partnerCitizenid, isK9 = isK9 }
        end,
        setPermission = function(citizenid, key, value)
            permissionsByCitizenidAndKey[citizenid] = permissionsByCitizenidAndKey[citizenid] or {}
            permissionsByCitizenidAndKey[citizenid][key] = value
        end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        addNearbyPlayer = function(id, x, y, z) nearbyPlayers[#nearbyPlayers + 1] = { id = id, coords = vec3(x, y, z) } end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do handler() end
            env.source = nil
        end,
        env = env,
    }
end

-- ----------------------------------------------------------------------
-- CommonHappyPath -- wires a valid K9(src=1)/handler(src=2) pair with a
-- resolvable citizenid on both sides, K9 access granted, and both peds
-- positioned so callers can control the resulting bearing/distance by
-- overriding coords afterward.
-- ----------------------------------------------------------------------
local function wireHappyPath(f)
    f.setAccess(1, true)
    f.setPlayer(1, 'K9-CID')
    f.setPlayer(2, 'HANDLER-CID')
    f.setPartner('K9-CID', 'HANDLER-CID', true)
    f.setPed(1, 101) -- K9's own ped handle
    f.setPed(2, 201) -- handler's own ped handle
    f.setCoords(101, 0, 0, 0)
    f.setCoords(201, 0, 0, 0)
end

-- ========================================================================
-- GATING
-- ========================================================================

t.test('Config.Features.DangerWarn = false: the net event is never registered at all', function()
    local f = newDangerWarnFixture({ featureOn = false })
    t.isNil(f.netEventNames['qbx_k9unit:server:requestDangerWarn'])
end)

-- ========================================================================
-- ACCESS / PARTNER RESOLUTION DENIALS
-- ========================================================================

t.test('no K9 access: denied, no NotifyPlayer beyond the one denial to the caller', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)
    f.setAccess(1, false)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 1)
    t.equals(f.notifyCalls[1].notifyType, 'error')
    t.contains(f.notifyCalls[1].description, 'not certified')
    t.equals(#f.clientEvents, 0)
end)

t.test('no active partnership at all: no_partner denial', function()
    local f = newDangerWarnFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'K9-CID')

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.contains(f.notifyCalls[1].description, 'no partnered handler')
end)

t.test('the querying citizenid is the HANDLER-role party, not the K9-role party: treated as no_partner, same as server/defense.lua\'s identical check in the opposite direction', function()
    local f = newDangerWarnFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'HANDLER-CID')
    f.setPlayer(2, 'K9-CID')
    -- GetActivePartnerCitizenId('HANDLER-CID') resolves a real partnership,
    -- but isK9 (the QUERIED party's own role) is false here -- the querying
    -- source (1) is itself the handler, not the K9, so this must not fire.
    f.setPartner('HANDLER-CID', 'K9-CID', false)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.contains(f.notifyCalls[1].description, 'no partnered handler')
end)

t.test('partner citizenid resolved but not currently online: handler_offline denial', function()
    local f = newDangerWarnFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'K9-CID')
    f.setPartner('K9-CID', 'HANDLER-CID', true)
    -- Deliberately no f.setPlayer(2, 'HANDLER-CID') -- HANDLER-CID resolves
    -- to no online source at all.

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.contains(f.notifyCalls[1].description, 'not currently online')
end)

t.test('GetActivePartnerCitizenId entirely absent (HandlerPartnership disabled/module missing): no_partner denial, never an error', function()
    local f = newDangerWarnFixture({ noPartnershipModule = true })
    f.setAccess(1, true)
    f.setPlayer(1, 'K9-CID')

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.contains(f.notifyCalls[1].description, 'no partnered handler')
end)

-- ========================================================================
-- PER-PERSON FEATURE CONTROL
-- ========================================================================

t.test('K9 explicitly blocked (block.DangerWarn): denied_blocked, handler never notified', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)
    f.setPermission('K9-CID', 'block.DangerWarn', true)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 1)
    t.contains(f.notifyCalls[1].description, 'blocked')
    t.equals(#f.clientEvents, 0)
end)

t.test('RequireGrant listed for DangerWarn, K9 holds no grant: denied_not_granted', function()
    local f = newDangerWarnFixture({ featureControlCfg = { RequireGrant = { DangerWarn = true } } })
    wireHappyPath(f)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.contains(f.notifyCalls[1].description, 'not been granted')
end)

t.test('RequireGrant listed for DangerWarn, BOTH parties hold the grant: allowed through', function()
    local f = newDangerWarnFixture({ featureControlCfg = { RequireGrant = { DangerWarn = true } } })
    wireHappyPath(f)
    f.setPermission('K9-CID', 'feature.DangerWarn', true)
    f.setPermission('HANDLER-CID', 'feature.DangerWarn', true)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2, 'the handler, not the K9, is the one notified on success')
end)

t.test('RequireGrant listed for DangerWarn, K9 holds the grant but the HANDLER does not: SILENT no-op, same "checked against BOTH parties" convention as server/defense.lua', function()
    local f = newDangerWarnFixture({ featureControlCfg = { RequireGrant = { DangerWarn = true } } })
    wireHappyPath(f)
    f.setPermission('K9-CID', 'feature.DangerWarn', true)
    -- Deliberately no grant for HANDLER-CID.

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('handler explicitly blocked: SILENT no-op -- no notification to EITHER party, not this K9\'s business to be told', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)
    f.setPermission('HANDLER-CID', 'block.DangerWarn', true)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('HasPermission entirely absent (PermissionGrants disabled/module missing): default-allow, same as every other feature\'s step-4 fallback', function()
    local f = newDangerWarnFixture({ noPermissionModule = true })
    wireHappyPath(f)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2)
end)

-- ========================================================================
-- HAPPY PATH -- CONTENT
-- ========================================================================

t.test('Alert: handler notified with type=warning and the configured Bark_Alert sound relayed to nearby players', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)
    f.addNearbyPlayer(1, 0, 0, 0) -- the K9's own connection, well within audibleRadius of its own coords

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2)
    t.equals(f.notifyCalls[1].notifyType, 'warning')
    t.contains(f.notifyCalls[1].description, 'alerting')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1].event, 'qbx_k9unit:client:dangerWarnAudible')
    t.equals(f.clientEvents[1].target, 1)
    t.equals(f.clientEvents[1].args[2], 'Bark_Alert')
end)

t.test('Threat: handler notified with type=error and the configured Bark_Aggressive sound relayed', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)

    f.requestDangerWarn(1, 'Threat')

    t.equals(f.notifyCalls[1].notifyType, 'error')
    t.contains(f.notifyCalls[1].description, 'real threat')
end)

t.test('unrecognized warnType silently falls back to Alert -- never rejected, no differential capability to protect', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)

    f.requestDangerWarn(1, 'not_a_real_type')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].notifyType, 'warning', 'Alert\'s notifyType, proving the fallback resolved to Alert specifically')
end)

t.test('non-string warnType (nil) silently falls back to Alert', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)

    f.requestDangerWarn(1, nil)

    t.equals(f.notifyCalls[1].notifyType, 'warning')
end)

-- ========================================================================
-- BEARING -- all 8 compass sectors, handler fixed at the origin
-- ========================================================================

local BEARING_CASES = {
    { dx = 0,   dy = 1,   label = 'north' },
    { dx = 1,   dy = 1,   label = 'north-east' },
    { dx = 1,   dy = 0,   label = 'east' },
    { dx = 1,   dy = -1,  label = 'south-east' },
    { dx = 0,   dy = -1,  label = 'south' },
    { dx = -1,  dy = -1,  label = 'south-west' },
    { dx = -1,  dy = 0,   label = 'west' },
    { dx = -1,  dy = 1,   label = 'north-west' },
}

for _, case in ipairs(BEARING_CASES) do
    t.test(('bearing: K9 offset (dx=%d, dy=%d) from the handler reads as "%s"'):format(case.dx, case.dy, case.label), function()
        local f = newDangerWarnFixture()
        wireHappyPath(f)
        f.setCoords(201, 0, 0, 0) -- handler at the origin
        f.setCoords(101, case.dx, case.dy, 0) -- K9 offset from the handler

        f.requestDangerWarn(1, 'Alert')

        t.contains(f.notifyCalls[1].description, case.label)
    end)
end

-- ========================================================================
-- DISTANCE BUCKETS -- all 4 bands, using the baseline config's own
-- { close = 15.0, nearby = 50.0, far = 150.0 } thresholds
-- ========================================================================

local DISTANCE_CASES = {
    { distance = 5,   label = 'very close' },
    { distance = 15,  label = 'very close' }, -- exactly at the close boundary -- inclusive
    { distance = 16,  label = 'nearby' },
    { distance = 50,  label = 'nearby' },     -- exactly at the nearby boundary -- inclusive
    { distance = 51,  label = 'some distance away' },
    { distance = 150, label = 'some distance away' }, -- exactly at the far boundary -- inclusive
    { distance = 151, label = 'far away' },
}

for _, case in ipairs(DISTANCE_CASES) do
    t.test(('distance bucket: %sm apart reads as "%s"'):format(tostring(case.distance), case.label), function()
        local f = newDangerWarnFixture()
        wireHappyPath(f)
        f.setCoords(201, 0, 0, 0)
        f.setCoords(101, case.distance, 0, 0) -- due east, exactly `distance` meters away

        f.requestDangerWarn(1, 'Alert')

        t.contains(f.notifyCalls[1].description, case.label)
    end)
end

-- ========================================================================
-- WHO HEARS THE BARK -- audibleRadius distance filtering
-- ========================================================================

t.test('a bystander within audibleRadius of the K9 hears the bark; one outside it does not', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)
    f.setCoords(101, 0, 0, 0) -- K9 at the origin
    f.addNearbyPlayer(50, 10, 0, 0)  -- 10m away -- inside the default 30m audibleRadius
    f.addNearbyPlayer(60, 100, 0, 0) -- 100m away -- outside it

    f.requestDangerWarn(1, 'Alert')

    local heardBy = {}
    for _, evt in ipairs(f.clientEvents) do heardBy[evt.target] = true end
    t.isTrue(heardBy[50] == true, 'the nearby bystander must hear the bark')
    t.isNil(heardBy[60], 'the far bystander must not')
end)

t.test('ForEachNearbyPlayer entirely absent: the handler\'s own text alert is unaffected -- soft dependency', function()
    local f = newDangerWarnFixture({ noForEachNearbyPlayer = true })
    wireHappyPath(f)

    f.requestDangerWarn(1, 'Alert')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2)
    t.equals(#f.clientEvents, 0)
end)

-- ========================================================================
-- RATE LIMIT
-- ========================================================================

t.test('a second trigger inside cooldownMs is refused with on_cooldown, and does NOT re-notify the handler', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)

    f.requestDangerWarn(1, 'Alert')
    t.equals(#f.notifyCalls, 1)

    f.requestDangerWarn(1, 'Alert')
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].target, 1)
    t.contains(f.notifyCalls[2].description, 'needs a moment')
end)

t.test('a BLOCKED request never consumes the cooldown -- a K9 who was blocked, then unblocked, can still warn immediately', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)
    f.setPermission('K9-CID', 'block.DangerWarn', true)

    f.requestDangerWarn(1, 'Alert') -- blocked, refused
    t.contains(f.notifyCalls[1].description, 'blocked')

    f.setPermission('K9-CID', 'block.DangerWarn', false)
    f.requestDangerWarn(1, 'Alert') -- unblocked -- must succeed, not read as still-on-cooldown

    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].target, 2)
end)

t.test('playerDropped clears DangerWarnCooldown for that source -- a reconnecting K9 is not left permanently stuck reading as still-on-cooldown', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)

    f.requestDangerWarn(1, 'Alert')
    t.equals(#f.notifyCalls, 1)

    f.requestDangerWarn(1, 'Alert') -- still on cooldown
    t.contains(f.notifyCalls[2].description, 'needs a moment')

    f.firePlayerDropped(1)

    f.requestDangerWarn(1, 'Alert') -- must succeed immediately post-disconnect, not still read as on cooldown
    t.equals(#f.notifyCalls, 3)
    t.equals(f.notifyCalls[3].target, 2)
end)

-- ========================================================================
-- CONFIG SAFETY -- never let a bad/missing Config.DangerWarn abort this
-- file's own load (server/cooldowns.lua's header ADDENDUM is the reason
-- this matters -- see this file's own header "CONFIG-SAFETY").
-- ========================================================================

t.test('Config.DangerWarn entirely missing: built-in fallbacks used throughout, a NOTE is printed, and the feature still works end to end', function()
    local f = newDangerWarnFixture({ dangerWarnCfg = false })
    wireHappyPath(f)
    f.addNearbyPlayer(1, 0, 0, 0) -- the K9's own connection, well within the built-in 30.0 fallback of its own coords

    local sawNote = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.DangerWarn is missing', 1, true) then sawNote = true end
    end
    t.isTrue(sawNote)

    f.requestDangerWarn(1, 'Alert')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2)
    t.equals(f.clientEvents[1].args[2], 'Bark_Alert', 'built-in DEFAULT_TYPES must still resolve Alert -> Bark_Alert with no Config.DangerWarn.Types at all')
end)

t.test('Config.DangerWarn.audibleRadius malformed (negative): warns and falls back to the built-in 30.0', function()
    local cfg = baselineDangerWarnConfig()
    cfg.audibleRadius = -5
    local f = newDangerWarnFixture({ dangerWarnCfg = cfg })
    wireHappyPath(f)
    f.addNearbyPlayer(50, 25, 0, 0) -- 25m away -- inside the 30.0 fallback, outside the bad -5 value

    local sawWarning = false
    for _, line in ipairs(f.printedLines) do
        if line:find('audibleRadius', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning)

    f.requestDangerWarn(1, 'Alert')
    local heardBy = {}
    for _, evt in ipairs(f.clientEvents) do heardBy[evt.target] = true end
    t.isTrue(heardBy[50] == true)
end)

t.test('Config.DangerWarn.distanceBuckets malformed (out of order): warns and falls back to the built-in { 15, 50, 150 }', function()
    local cfg = baselineDangerWarnConfig()
    cfg.distanceBuckets = { close = 50.0, nearby = 15.0, far = 150.0 } -- nearby < close -- invalid order
    local f = newDangerWarnFixture({ dangerWarnCfg = cfg })
    wireHappyPath(f)
    f.setCoords(201, 0, 0, 0)
    f.setCoords(101, 20, 0, 0) -- 20m -- 'nearby' under the built-in fallback, would be 'close' under the bad (invalid) config if it had been used

    local sawWarning = false
    for _, line in ipairs(f.printedLines) do
        if line:find('distanceBuckets', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning)

    f.requestDangerWarn(1, 'Alert')
    t.contains(f.notifyCalls[1].description, 'nearby')
end)

t.test('Config.DangerWarn.cooldownMs = 0: clamped by ResolveConfiguredThresholdMs to the shipped 15000ms fallback, never aborts this file\'s load, and the net event stays registered', function()
    local cfg = baselineDangerWarnConfig()
    cfg.cooldownMs = 0
    local f = newDangerWarnFixture({ dangerWarnCfg = cfg })
    t.isNotNil(f.netEventNames['qbx_k9unit:server:requestDangerWarn'])

    wireHappyPath(f)
    f.requestDangerWarn(1, 'Alert')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2)

    f.requestDangerWarn(1, 'Alert') -- immediately again -- must be refused, proving the clamp landed on a real positive fallback rather than 0 ("no cooldown")
    t.contains(f.notifyCalls[2].description, 'needs a moment')
end)

t.test('Config.DangerWarn.Types missing an entry for the requested type\'s own default: last-resort DEFAULT_TYPES used directly, never nil', function()
    local cfg = baselineDangerWarnConfig()
    cfg.Types = { Threat = { soundName = 'Bark_Aggressive', notifyType = 'error' } } -- no 'Alert' entry at all
    local f = newDangerWarnFixture({ dangerWarnCfg = cfg })
    wireHappyPath(f)
    f.addNearbyPlayer(1, 0, 0, 0)

    f.requestDangerWarn(1, 'Alert') -- requests the entry that is missing from this Config.DangerWarn.Types

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 2)
    t.equals(f.clientEvents[1].args[2], 'Bark_Alert', 'the built-in DEFAULT_TYPES.Alert entry must be used as the last resort')
end)

-- ========================================================================
-- LOCALE UPGRADE PATH -- proves the pcall(locale, ...) branch is genuinely
-- live code, not dead, and prefers a landed key the instant one exists,
-- with no further code change -- same technique
-- tests/tenure_spec.lua's own 'localeHidingNewKeys' fixture (in reverse)
-- already established for this exact pattern.
-- ========================================================================

t.test('once locales/en.json lands dangerwarn.handler_alert_Alert for real, that text is used instead of the hardcoded fallback', function()
    local f = newDangerWarnFixture()
    wireHappyPath(f)

    local landedText = 'TEST-LANDED: your dog says something is up %s, %s.'
    f.env.locale = function(key, ...)
        if key == 'dangerwarn.handler_alert_Alert' then
            return landedText:format(...)
        end
        error('locale key missing from locales/en.json: ' .. key)
    end

    f.requestDangerWarn(1, 'Alert')

    t.contains(f.notifyCalls[1].description, 'TEST-LANDED')
end)

-- ========================================================================
-- CLEANUP -- playerDropped
-- ========================================================================

t.test('server/dangerwarn.lua registers exactly the ONE playerDropped handler that DangerWarnCooldown.RegisterPlayerDropped() itself installs', function()
    local addedHandlers = {}
    local realAddEventHandler
    -- This fixture needs to intercept AddEventHandler BEFORE loading the
    -- production files, unlike newDangerWarnFixture's own default (which
    -- never overrides it) -- built inline here rather than adding a new
    -- opt to the shared builder, since this is the one test in this file
    -- that needs it.
    local env = Sandbox.newEnv({
        AddEventHandler = function(name, handler)
            addedHandlers[#addedHandlers + 1] = name
            if name == 'playerDropped' then realAddEventHandler = handler end
        end,
        RegisterNetEvent = function() end,
        Config = { Features = { DangerWarn = true }, DangerWarn = baselineDangerWarnConfig() },
    })
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/dangerwarn.lua', env)

    local count = 0
    for _, name in ipairs(addedHandlers) do
        if name == 'playerDropped' then count = count + 1 end
    end
    t.equals(count, 1)
    t.isNotNil(realAddEventHandler, 'DangerWarnCooldown.RegisterPlayerDropped() must have installed a real handler')
end)

t.test('EVERY tracker in server/dangerwarn.lua has a cleanup strategy -- source-keyed ones register a playerDropped hook, key-keyed ones start a sweep, and none has neither', function()
    -- Reads the file's own text rather than the loaded chunk, same
    -- established technique as tests/combat_spec.lua's identical test for
    -- server/combat.lua (that file's own header names
    -- tests/customizationregistry_spec.lua's source scans as the
    -- precedent for this style of test).
    local handle = assert(io.open('../server/dangerwarn.lua', 'r'))
    local text = handle:read('*a')
    handle:close()

    local declared = {}
    for name in text:gmatch('local%s+([%w_]+)%s*=%s*New[CM]') do
        declared[#declared + 1] = name
    end
    t.isTrue(#declared >= 1,
        ('sanity: found %d tracker declaration(s) in server/dangerwarn.lua -- expected at least DangerWarnCooldown'):format(#declared))

    for _, name in ipairs(declared) do
        local hasPlayerDropped = text:find(name .. '.RegisterPlayerDropped(', 1, true) ~= nil
        local hasSweep = text:find(name .. '.StartSweep(', 1, true) ~= nil
        t.isTrue(hasPlayerDropped or hasSweep,
            name .. ' has neither .RegisterPlayerDropped() nor .StartSweep() -- its table grows for the whole uptime of the server with nothing to bound it')
    end
end)

os.exit(t.summary())
