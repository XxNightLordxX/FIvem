--[[
    tests/clientvision_spec.lua

    Third client-side spec in this suite (tests/main_spec.lua is the
    worked example; tests/clientradial_spec.lua is the second). Direct,
    black-box tests of client/vision.lua against the REAL, unmodified
    production file: thermal/night vision's mutual exclusivity, the
    maintenance/cleanup thread's start-on-real-transition and
    self-termination lifecycle, the own-death and lost-access cleanup
    guards inside that thread, and the onResourceStop safety net.

    IMPORTANT CORRECTION TO THIS SPEC'S OWN TASK BRIEF -- READ BEFORE
    TRUSTING ANYTHING ELSE IN THIS FILE ABOUT "D3":
    the task this file was written under asked for a test proving "the
    `source ~= 65535` origin guard rejects a forged local trigger" in this
    file, with a comment noting that a green test here does not settle
    open decision D3 (DEVELOPER_REFERENCE.md -- formerly DECISIONS_NEEDED.md,
    merged 2026-08-25 -- the resource-wide question of
    whether the client-event origin check can fail open at the engine
    level). That premise does not hold for THIS file, and no such test
    exists below -- fabricating one would mean asserting behavior this
    file does not have. Verified directly, not assumed:
      - client/vision.lua's own header states outright, in its "EVENT/
        CALLBACK CONTRACT" section: "Phase 2: NONE. This file registers or
        triggers no network event or callback of any kind."
      - A literal grep of this file for `RegisterNetEvent`, `source`, and
        `65535` returns zero matches. There is no event handler here at
        all for a forged trigger to reach -- no `source` global is ever
        read, so there is nothing for a 65535 check to guard.
      - DEVELOPER_REFERENCE.md's own D3 write-up names the actual affected
        surface: client/combat.lua, client/medkit.lua, client/wellbeing.lua,
        client/partnership.lua, client/kennel.lua, client/fetch.lua,
        client/propattachment.lua, client/bonetool.lua, client/screenfx.lua,
        and client/main.lua (already covered by tests/main_spec.lua's own
        playBark section). client/vision.lua is not on that list, and
        reading it confirms why: it has no network-facing entry point of
        any kind to forge a trigger against in the first place -- both
        Toggle*Vision() functions are called ONLY from a local
        RegisterCommand/RegisterKeyMapping binding (an internal client
        input, not a network event), and the maintenance thread and
        onResourceStop handler below take no event payload at all.
    This is reported as a finding in this pass's own report (a factual
    mismatch in the task brief, not a defect in client/vision.lua) rather
    than worked around silently. What this file DOES test instead, in
    full, is everything else the brief asked for: mutual exclusivity, the
    maintenance thread's lifecycle, the own-death/lost-access cleanup
    guards, and onResourceStop.

    THREAD SIMULATION: uses Sandbox.newThreadRunner() (tests/fixtures/
    sandbox.lua) to step the maintenance thread's coroutine one pass at a
    time, wrapped by this fixture's own CreateThread so a test can also
    assert HOW MANY threads were ever created (the "starts only on a real
    transition" / "self-terminates, and a later toggle starts a genuinely
    NEW thread" claims both need that count, not just the ability to step
    an already-known single thread). See newVisionFixture()'s own comment
    on the exact step-by-step semantics of THIS specific thread body --
    its first statement is a plain assignment before the `while` loop even
    starts, not a `Wait(...)` the way DEVELOPER_REFERENCE.md's own generic
    stepping note assumes, so this file works out the precise resume
    boundaries for itself rather than leaning on that note uncritically.

    STUBBING EFFORT, reported honestly per this task's own instruction:
    every native this file touches is a simple boolean-flag toggle/getter
    (IsSeethroughActive/SetSeethrough, IsNightvisionActive/SetNightvision,
    IsEntityDead, PlayerPedId, GetCurrentResourceName) plus
    CreateThread/Wait/RegisterCommand/RegisterKeyMapping/AddEventHandler/
    lib.notify/locale -- all either already-established capturing-stub
    shapes from this suite's server-side specs or the exact
    Sandbox.newThreadRunner() utility built for this purpose. Nothing here
    needed disproportionate stubbing; this file more than holds up the
    "client files needing outsized stubbing" audit being stale, alongside
    tests/main_spec.lua and tests/clientradial_spec.lua.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua (with
--- `opts.features` merged onto Config.Features BEFORE client/vision.lua
--- loads, since its RegisterCommand/RegisterKeyMapping calls are gated at
--- FILE-LOAD time -- same reasoning as clientradial_spec.lua's own
--- fixture) + the real client/vision.lua, plus a controllable/capturing
--- stand-in for every native it touches.
--- @param opts { features: table?, isOwnModelK9: boolean?, hasK9Access: boolean?, partnershipAvailable: boolean? }?
--- @return table fixture
local function newVisionFixture(opts)
    opts = opts or {}

    local isOwnModelK9 = opts.isOwnModelK9
    if isOwnModelK9 == nil then isOwnModelK9 = true end
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end
    local isEntityDead = false

    local function IsOwnModelK9() return isOwnModelK9 end
    local hasK9AccessCallCount = 0
    local function HasK9Access() hasK9AccessCallCount = hasK9AccessCallCount + 1; return hasK9Access end
    local function IsEntityDead(_ped) return isEntityDead end
    local function PlayerPedId() return 1 end

    -- ------------------------------------------------------------------
    -- CAMERA FEED fixture additions. Real client/vision.lua calls
    -- CanShowK9UI()/DenyK9UIAccess()/IsEntityModelK9() as bare resource-
    -- globals normally defined by client/main.lua -- this spec never loads
    -- that file (same reasoning IsOwnModelK9()/HasK9Access() above already
    -- establish: a controllable stand-in, not the real cross-file
    -- dependency), so they are stubbed here too, independently of the
    -- IsOwnModelK9()/HasK9Access() pair above (CanShowK9UI() is a DIFFERENT
    -- combinator in the real file, not derived from these two in THIS
    -- fixture -- tests that care about the real composition belong in
    -- tests/main_spec.lua, not here).
    -- ------------------------------------------------------------------
    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyK9UIAccessCallCount = 0
    local function DenyK9UIAccess() denyK9UIAccessCallCount = denyK9UIAccessCallCount + 1 end

    local isEntityModelK9 = false -- which role the PARTNER ped resolves as, for the eye-height-offset branch
    local function IsEntityModelK9(_entity) return isEntityModelK9 end

    -- Partnership soft dependency -- `refreshFn` being nil (the default)
    -- means client/partnership.lua's own top-of-file gate did not pass
    -- (Config.Features.HandlerPartnership false), so the resource-global
    -- is genuinely UNDEFINED, not a stub returning false -- this fixture
    -- reproduces that exact shape by simply never adding the key to `env`
    -- at all rather than adding a function that returns a "disabled"
    -- answer (see `refreshPartnershipStateFromServerAvailable` below).
    -- MUST be an `opts` input, not a post-construction setter: whether
    -- these two resource-globals are even ADDED to `env` is decided once,
    -- before Sandbox.loadInto('../client/vision.lua', env) runs -- a
    -- setter called AFTER newVisionFixture() has already returned would
    -- be too late to change what the production file's `type(...) ==
    -- 'function'` guard already saw at its own load time.
    local refreshPartnershipStateFromServerAvailable = opts.partnershipAvailable == true
    local isPartneredNowResult, partnerServerIdResult = false, nil
    local refreshCallCount = 0
    local function RefreshPartnershipStateFromServer()
        refreshCallCount = refreshCallCount + 1
        return isPartneredNowResult, partnerServerIdResult
    end
    local isPartnered = true
    local function IsPartnered() return isPartnered end

    local partnerPlayerIndex = 2 -- GetPlayerFromServerId's return; -1 simulates offline
    local function GetPlayerFromServerId(_serverId) return partnerPlayerIndex end
    local partnerPed = 999 -- GetPlayerPed's return; 0 simulates "not streamed in"
    local function GetPlayerPed(_player) return partnerPed end
    local partnerName = 'PartnerOfficer'
    local function GetPlayerName(_player) return partnerName end

    -- DoesEntityExist must answer for BOTH the local ped (id 1, always
    -- exists in this fixture -- StopCameraFeed()'s own unfreeze guard
    -- reads it) and the partner ped (configurable, id from `partnerPed`
    -- above) -- a single existence set, not two separate booleans, so a
    -- test cannot accidentally leave one stale relative to the other.
    local existingEntities = { [1] = true, [999] = true }
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    local createCamReturn = 42 -- 0 simulates CreateCam failure
    local createCamCalls = {}
    local function CreateCam(camName, active)
        createCamCalls[#createCamCalls + 1] = { camName = camName, active = active }
        return createCamReturn
    end
    local attachCamToEntityCalls = {}
    local function AttachCamToEntity(cam, entity, x, y, z, isRelative)
        attachCamToEntityCalls[#attachCamToEntityCalls + 1] = { cam = cam, entity = entity, x = x, y = y, z = z, isRelative = isRelative }
    end
    local setCamFovCalls = {}
    local function SetCamFov(cam, fov) setCamFovCalls[#setCamFovCalls + 1] = { cam = cam, fov = fov } end
    local entityRotation = { x = 11.0, y = 22.0, z = 33.0 }
    local function GetEntityRotation(_entity, _order) return entityRotation end
    local setCamRotCalls = {}
    local function SetCamRot(cam, x, y, z, order) setCamRotCalls[#setCamRotCalls + 1] = { cam = cam, x = x, y = y, z = z, order = order } end
    local setCamActiveCalls = {}
    local function SetCamActive(cam, active) setCamActiveCalls[#setCamActiveCalls + 1] = { cam = cam, active = active } end
    local renderScriptCamsCalls = {}
    local function RenderScriptCams(render, ease, easeTime, easeCoordsAnim, p4)
        renderScriptCamsCalls[#renderScriptCamsCalls + 1] = { render = render, ease = ease, easeTime = easeTime, easeCoordsAnim = easeCoordsAnim, p4 = p4 }
    end
    local camExists = true
    local function DoesCamExist(_cam) return camExists end
    local destroyCamCalls = {}
    local function DestroyCam(cam, bScriptHostCam) destroyCamCalls[#destroyCamCalls + 1] = { cam = cam, bScriptHostCam = bScriptHostCam } end
    local freezeEntityPositionCalls = {}
    local function FreezeEntityPosition(entity, toggle) freezeEntityPositionCalls[#freezeEntityPositionCalls + 1] = { entity = entity, toggle = toggle } end

    -- The two native toggle pairs -- state lives here, in the fixture, NOT
    -- re-implemented as a separate boolean the way this file's own header
    -- explicitly warns against for client/vision.lua ITSELF (its own
    -- comment: "the native's own getter is the source of truth, not a
    -- separately-tracked local boolean") -- this fixture plays the role of
    -- the REAL native/engine state, which the production file's getters
    -- read straight from.
    local seethrough, nightvision = false, false
    local setSeethroughCalls, setNightvisionCalls = {}, {}
    local function IsSeethroughActive() return seethrough end
    local function SetSeethrough(v) seethrough = v; setSeethroughCalls[#setSeethroughCalls + 1] = v end
    local function IsNightvisionActive() return nightvision end
    local function SetNightvision(v) nightvision = v; setNightvisionCalls[#setNightvisionCalls + 1] = v end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    -- CreateThread wraps Sandbox.newThreadRunner()'s own CreateThread so
    -- this fixture can ALSO count how many threads were ever created --
    -- needed to prove EnsureVisionMaintenanceThreadRunning()'s own
    -- "already running -> no-op" guard, and later, that a stopped
    -- thread's guard resets so a FRESH transition starts a genuinely NEW
    -- one. runner.step() is exposed directly; see this fixture's own
    -- return table for the exact stepping semantics of the ONE thread
    -- body this file ever creates.
    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        runner.CreateThread(fn)
    end
    local function Wait(ms) runner.Wait(ms) end

    local registerCommandCalls = {}
    local function RegisterCommand(name, handler, restricted)
        registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler, restricted = restricted }
    end
    local registerKeyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        registerKeyMappingCalls[#registerKeyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    local RESOURCE_NAME = 'qbx_k9unit'
    local function GetCurrentResourceName() return RESOURCE_NAME end
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local envTable = {
        IsOwnModelK9 = IsOwnModelK9,
        HasK9Access = HasK9Access,
        IsEntityDead = IsEntityDead,
        PlayerPedId = PlayerPedId,
        IsSeethroughActive = IsSeethroughActive,
        SetSeethrough = SetSeethrough,
        IsNightvisionActive = IsNightvisionActive,
        SetNightvision = SetNightvision,
        lib = { notify = lib_notify },
        CreateThread = CreateThread,
        Wait = Wait,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        IsEntityModelK9 = IsEntityModelK9,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerPed = GetPlayerPed,
        GetPlayerName = GetPlayerName,
        DoesEntityExist = DoesEntityExist,
        CreateCam = CreateCam,
        AttachCamToEntity = AttachCamToEntity,
        SetCamFov = SetCamFov,
        GetEntityRotation = GetEntityRotation,
        SetCamRot = SetCamRot,
        SetCamActive = SetCamActive,
        RenderScriptCams = RenderScriptCams,
        DoesCamExist = DoesCamExist,
        DestroyCam = DestroyCam,
        FreezeEntityPosition = FreezeEntityPosition,
    }
    -- SOFT DEPENDENCY SHAPE (see the declaration comment above): only
    -- added to the env at all when `opts.partnershipAvailable` is true --
    -- a MISSING key, not a "returns false" stub, is what reproduces
    -- client/partnership.lua's own top-of-file gate returning early
    -- without ever defining these two resource-globals.
    if refreshPartnershipStateFromServerAvailable then
        envTable.RefreshPartnershipStateFromServer = RefreshPartnershipStateFromServer
        envTable.IsPartnered = IsPartnered
    end

    local env = Sandbox.newEnv(envTable)

    Sandbox.loadInto('../config.lua', env)

    -- THIS SPEC'S OWN FIXED BASELINE -- same reasoning and same real
    -- concurrency incident as tests/clientradial_spec.lua's own baseline
    -- (see that file's header): config.lua is edited by other agents
    -- while this suite runs, so this fixture pins ThermalVision/
    -- NightVision/CameraFeedPiP to a known value BEFORE applying
    -- `opts.features`, rather than trusting whatever config.lua's live
    -- defaults happen to be at the moment a given test runs. Same
    -- reasoning for `Config.CameraFeed` -- pinned to a known table
    -- REGARDLESS of whether config.lua has been given that table yet (see
    -- client/vision.lua's own GetCameraFeedConfig() fallback for the
    -- production-side half of this same defensiveness), so this suite's
    -- own assertions about exact fov/eye-height/toggleKey values passed to
    -- the CAM natives stay meaningful and stable either way.
    env.Config.Features.ThermalVision = false
    env.Config.Features.NightVision = false
    env.Config.Features.CameraFeedPiP = false
    env.Config.CameraFeed = { toggleKey = 'H', fov = 45.0, k9EyeHeightOffset = 0.6, handlerEyeHeightOffset = 1.5 }
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end

    Sandbox.loadInto('../client/vision.lua', env)

    return {
        env = env,
        Config = env.Config,
        notifyCalls = notifyCalls,
        setSeethroughCalls = setSeethroughCalls,
        setNightvisionCalls = setNightvisionCalls,
        registerCommandCalls = registerCommandCalls,
        registerKeyMappingCalls = registerKeyMappingCalls,
        resourceName = RESOURCE_NAME,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setIsEntityDead = function(v) isEntityDead = v end,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        isSeethroughActive = function() return seethrough end,
        isNightvisionActive = function() return nightvision end,
        --- Steps the (at most one, in this file) captured maintenance
        --- thread once. See this file's header + inline comments at each
        --- call site below for exactly what a given step number reaches --
        --- this thread's FIRST statement is a plain assignment before its
        --- `while` loop, not a `Wait(...)` the way DEVELOPER_REFERENCE.md's own
        --- generic note assumes, so step-by-step semantics here are worked
        --- out per-call rather than quoted wholesale from that note.
        step = function() runner.step() end,
        threadCreateCount = function() return threadCreateCount end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,

        -- CAMERA FEED fixture controls/inspectors
        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyK9UIAccessCallCount = function() return denyK9UIAccessCallCount end,
        setIsEntityModelK9 = function(v) isEntityModelK9 = v end,
        setRefreshResult = function(isPartneredNow, partnerServerId) isPartneredNowResult = isPartneredNow; partnerServerIdResult = partnerServerId end,
        refreshCallCount = function() return refreshCallCount end,
        setIsPartnered = function(v) isPartnered = v end,
        setPartnerPlayerIndex = function(v) partnerPlayerIndex = v end,
        setPartnerPed = function(v) partnerPed = v end,
        setEntityExists = function(entity, exists) existingEntities[entity] = exists or nil end,
        setPartnerName = function(v) partnerName = v end,
        setCreateCamReturn = function(v) createCamReturn = v end,
        createCamCalls = createCamCalls,
        attachCamToEntityCalls = attachCamToEntityCalls,
        setCamFovCalls = setCamFovCalls,
        setEntityRotation = function(v) entityRotation = v end,
        setCamRotCalls = setCamRotCalls,
        setCamActiveCalls = setCamActiveCalls,
        renderScriptCamsCalls = renderScriptCamsCalls,
        setCamExists = function(v) camExists = v end,
        destroyCamCalls = destroyCamCalls,
        freezeEntityPositionCalls = freezeEntityPositionCalls,
    }
end

-- ----------------------------------------------------------------------
-- Sanity
-- ----------------------------------------------------------------------

t.test('client/vision.lua exposes all four documented resource-globals', function()
    local f = newVisionFixture()
    t.isNotNil(f.env.ToggleThermalVision)
    t.isNotNil(f.env.ToggleNightVision)
    t.isNotNil(f.env.IsThermalVisionActive)
    t.isNotNil(f.env.IsNightVisionActive)
end)

-- ----------------------------------------------------------------------
-- IsThermalVisionActive / IsNightVisionActive -- thin wrappers, but with a
-- real coercion contract (`== true`) worth pinning: a native returning
-- anything other than the exact boolean `true` (nil, 0, "true") must read
-- back as `false`, never as a truthy-but-wrong value.
-- ----------------------------------------------------------------------

t.test('IsThermalVisionActive: reflects the underlying native exactly (false by default)', function()
    local f = newVisionFixture()
    t.isFalse(f.env.IsThermalVisionActive())
end)

t.test('IsThermalVisionActive: coerces a non-boolean-true native return to false, not passed through as-is', function()
    local f = newVisionFixture()
    f.env.IsSeethroughActive = function() return 1 end -- truthy in Lua, but not the exact boolean `true`
    t.isFalse(f.env.IsThermalVisionActive(), 'must be `== true`, not a bare truthy check')
end)

t.test('IsNightVisionActive: reflects the underlying native exactly (false by default)', function()
    local f = newVisionFixture()
    t.isFalse(f.env.IsNightVisionActive())
end)

-- ----------------------------------------------------------------------
-- Access gate: IsOwnModelK9() ONLY -- per this file's own "RESOLVED
-- ACCESS-GATING DECISION," never CanShowK9UI().
-- ----------------------------------------------------------------------

t.test('ToggleThermalVision: not a K9 model -- denied with common.not_k9_model, native never touched', function()
    local f = newVisionFixture({ isOwnModelK9 = false })
    f.env.ToggleThermalVision()
    t.equals(#f.setSeethroughCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].title, locale('common.notify_title'))
    t.equals(f.notifyCalls[1].description, locale('common.not_k9_model'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('ToggleNightVision: not a K9 model -- denied with common.not_k9_model, native never touched', function()
    local f = newVisionFixture({ isOwnModelK9 = false })
    f.env.ToggleNightVision()
    t.equals(#f.setNightvisionCalls, 0)
    t.equals(f.notifyCalls[1].description, locale('common.not_k9_model'))
end)

t.test('ToggleThermalVision: a K9 model, currently off, turns ON -- SetSeethrough(true), an "on" notification, and the maintenance thread starts', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision()
    t.isTrue(f.isSeethroughActive())
    t.equals(f.notifyCalls[1].description, locale('vision.thermal_on'))
    -- 'info', not the old 'inform': ox_lib's REAL upstream
    -- `resource/interface/client/notify.lua` declares
    -- `---@alias NotificationType 'info' | 'warning' | 'success' | 'error'`
    -- -- 'inform' is not a member (it's a v3 leftover only remapped inside
    -- the deprecated `lib.defaultNotify` shim, which client/vision.lua's
    -- direct `lib.notify(...)` call never goes through).
    t.equals(f.notifyCalls[1].type, 'info')
    t.equals(f.threadCreateCount(), 1)
end)

t.test('ToggleThermalVision: a K9 model, currently ON, turns OFF -- SetSeethrough(false), an "off" notification, and NO new thread is created', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on (creates thread #1)
    f.env.ToggleThermalVision() -- off
    t.isFalse(f.isSeethroughActive())
    t.equals(f.notifyCalls[2].description, locale('vision.thermal_off'))
    t.equals(f.threadCreateCount(), 1, 'turning OFF must never call EnsureVisionMaintenanceThreadRunning at all')
end)

-- ----------------------------------------------------------------------
-- Mutual exclusivity -- DEVELOPER_REFERENCE.md §11.5's own confirmed judgment call:
-- turning one on forces the other off first.
-- ----------------------------------------------------------------------

t.test('mutual exclusivity: turning Thermal ON while Night is already active turns Night OFF first, then Thermal ON', function()
    local f = newVisionFixture()
    f.env.ToggleNightVision() -- night on
    t.isTrue(f.isNightvisionActive())

    f.env.ToggleThermalVision() -- thermal on -- must force night off first
    t.isTrue(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive(), 'thermal turning on must force night off -- the two are mutually exclusive')
end)

t.test('mutual exclusivity: turning Night ON while Thermal is already active turns Thermal OFF first, then Night ON', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- thermal on
    t.isTrue(f.isSeethroughActive())

    f.env.ToggleNightVision() -- night on -- must force thermal off first
    t.isTrue(f.isNightvisionActive())
    t.isFalse(f.isSeethroughActive())
end)

t.test('mutual exclusivity: turning Thermal ON when Night was never active never touches SetNightvision at all', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision()
    t.equals(#f.setNightvisionCalls, 0, 'EnsureOnlyOneVisionEffectActive must be a true no-op when the OTHER effect was never on')
end)

-- ----------------------------------------------------------------------
-- Maintenance thread lifecycle: starts only on a real ON transition,
-- self-terminates once both effects are off, and a LATER genuine
-- transition starts a fresh one (proving the guard actually reset).
--
-- STEPPING NOTES FOR THIS SPECIFIC THREAD BODY (see fixture header): the
-- thread's first statement is `local hadK9Access = HasK9Access()`, THEN
-- the `while` condition is checked, THEN (if true) the loop is entered
-- and `Wait(1000)` is the first statement INSIDE it. So:
--   step() call #1 -- resumes from the very start: runs the initial
--     HasK9Access() capture, evaluates the while-condition (true, since a
--     Toggle*Vision() call already turned an effect on before this
--     thread's body ever runs), enters the loop, and yields at Wait(1000).
--     This is the "prime" step -- it runs no branch logic yet.
--   step() call #2 (and onward, one per call) -- resumes AFTER Wait,
--     executes exactly one pass of the death/model/access-transition
--     branch, then re-checks the while-condition: if still true, it loops
--     back to Wait(1000) and yields again (ready for another step() to run
--     the NEXT pass); if now false (both effects were just cleared by
--     that same pass), it falls out of the loop, clears
--     visionMaintenanceThreadRunning, and the coroutine dies -- all within
--     that SAME step() call, with no further yield.
-- ----------------------------------------------------------------------

t.test('maintenance thread: does not exist at all before any vision effect is ever turned on', function()
    local f = newVisionFixture()
    t.equals(f.threadCreateCount(), 0)
end)

t.test('maintenance thread: own death clears BOTH effects, in a single pass, even though only one was on', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on; creates + primes reachable via step()
    f.step() -- step #1: prime (captures hadK9Access, enters loop, yields at Wait)

    f.setIsEntityDead(true)
    f.step() -- step #2: executes the death branch -> both natives forced false

    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive(), 'the death branch clears BOTH unconditionally, even though only thermal was ever on')
    t.equals(f.setSeethroughCalls[#f.setSeethroughCalls], false)
    t.equals(f.setNightvisionCalls[#f.setNightvisionCalls], false)
end)

t.test('maintenance thread: self-terminates once both effects are cleared -- a LATER toggle-on starts a genuinely NEW thread', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on -- thread #1
    t.equals(f.threadCreateCount(), 1)
    f.step() -- prime
    f.setIsEntityDead(true)
    f.step() -- clears both, while-condition now false -> thread exits, guard resets

    -- A fresh toggle-on AFTER the thread has exited must be able to start
    -- a SECOND, brand-new thread -- proving the
    -- `visionMaintenanceThreadRunning` guard actually reset to false when
    -- the old thread died, rather than staying stuck true forever.
    f.setIsEntityDead(false) -- alive again, so the new toggle actually sticks
    f.env.ToggleThermalVision() -- on again
    t.equals(f.threadCreateCount(), 2, 'a fresh ON transition after the previous thread self-terminated must start a NEW thread')
end)

t.test('maintenance thread: while an effect is still active (nothing cleared it), continuing to loop does NOT create a second thread -- EnsureVisionMaintenanceThreadRunning stays a no-op while the first thread is alive', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on -- thread #1
    f.env.ToggleNightVision() -- mutual exclusion turns thermal off, night on -- EnsureVisionMaintenanceThreadRunning() is called AGAIN here, but the thread is already running
    t.equals(f.threadCreateCount(), 1, 'the already-running guard must prevent a second thread from ever being created while the first is still alive')
end)

t.test('maintenance thread: model swap away from a K9 model (IsOwnModelK9 false) clears both effects, mirroring the death branch', function()
    local f = newVisionFixture()
    f.env.ToggleNightVision() -- on
    f.step() -- prime

    f.setIsOwnModelK9(false)
    f.step() -- executes the "not IsOwnModelK9()" branch

    t.isFalse(f.isNightvisionActive())
    t.isFalse(f.isSeethroughActive())
end)

t.test('maintenance thread: HasK9Access TRANSITION (true -> false) clears both effects', function()
    local f = newVisionFixture({ hasK9Access = true })
    f.env.ToggleThermalVision() -- on; hasK9Access is true at this moment
    f.step() -- prime: captures hadK9Access = true (HasK9Access() called once here)
    t.equals(f.hasK9AccessCallCount(), 1)

    f.setHasK9Access(false) -- access revoked between ticks
    f.step() -- executes the else-branch: hasK9Access now false, hadK9Access was true -> transition -> clear

    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
end)

t.test('maintenance thread: a player who NEVER had K9 access at all (false from the very start) is NOT force-cleared -- only a TRUE -> FALSE transition triggers the clear', function()
    local f = newVisionFixture({ hasK9Access = false })
    f.env.ToggleThermalVision() -- on; IsOwnModelK9 gate passes regardless of HasK9Access, per this file's own access-gating decision
    f.step() -- prime: captures hadK9Access = false
    f.step() -- pass #1 of the else-branch: hasK9Access still false, hadK9Access was false -> NOT a transition -> no clear
    f.step() -- pass #2, same result -- must remain stable, not clear on some later tick either

    t.isTrue(f.isSeethroughActive(), 'a player who never had access in the first place must keep their (IsOwnModelK9-gated) vision effect uncleared by this thread')
    t.equals(#f.setSeethroughCalls, 1, 'SetSeethrough must have been called exactly once (the original ToggleThermalVision turn-on) -- never again by the maintenance thread')
end)

-- ----------------------------------------------------------------------
-- onResourceStop -- forces both natives off unconditionally, matching
-- resourceName only.
-- ----------------------------------------------------------------------

t.test('onResourceStop: registers exactly one handler', function()
    local f = newVisionFixture()
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('onResourceStop: a stop event for a DIFFERENT resource is ignored -- neither native is touched', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on
    local callsBefore = #f.setSeethroughCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.setSeethroughCalls, callsBefore, 'a different resource stopping must not touch this resource\'s vision state at all')
end)

t.test('onResourceStop: this resource stopping forces BOTH natives off unconditionally, even if only one was ever on', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- only thermal on
    t.isTrue(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())

    f.fireResourceStop(f.resourceName)
    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
    t.equals(f.setNightvisionCalls[#f.setNightvisionCalls], false, 'SetNightvision(false) must still be called even though night vision was never on this session -- a harmless idempotent no-op, per this file\'s own comment')
end)

t.test('onResourceStop: a harmless no-op when NEITHER effect was ever turned on', function()
    local f = newVisionFixture()
    local ok = pcall(f.fireResourceStop, f.resourceName)
    t.isTrue(ok)
    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
end)

-- ----------------------------------------------------------------------
-- Config-gated command + keybind REGISTRATION (not just behavior) -- each
-- flag independently gates its OWN RegisterCommand/RegisterKeyMapping
-- pair, per this file's own "the two flags are fully independent" comment.
-- ----------------------------------------------------------------------

t.test('both ThermalVision and NightVision false: zero commands and zero key mappings are registered', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = false } })
    t.equals(#f.registerCommandCalls, 0)
    t.equals(#f.registerKeyMappingCalls, 0)
end)

t.test('ThermalVision true, NightVision false: only the thermal command/keybind is registered, with the real Config.Vision.Thermal.toggleKey', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = false } })
    t.equals(#f.registerCommandCalls, 1)
    t.equals(f.registerCommandCalls[1].name, 'qbx_k9unit:toggleThermalVision')
    t.equals(#f.registerKeyMappingCalls, 1)
    t.equals(f.registerKeyMappingCalls[1].commandName, 'qbx_k9unit:toggleThermalVision')
    t.equals(f.registerKeyMappingCalls[1].description, locale('vision.thermal_keybind_label'))
    t.equals(f.registerKeyMappingCalls[1].defaultKey, f.Config.Vision.Thermal.toggleKey)
end)

t.test('NightVision true, ThermalVision false: only the night command/keybind is registered, with the real Config.Vision.Night.toggleKey', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = true } })
    t.equals(#f.registerCommandCalls, 1)
    t.equals(f.registerCommandCalls[1].name, 'qbx_k9unit:toggleNightVision')
    t.equals(#f.registerKeyMappingCalls, 1)
    t.equals(f.registerKeyMappingCalls[1].defaultKey, f.Config.Vision.Night.toggleKey)
end)

t.test('both true: both commands are registered, and the captured command handler really calls through to the real Toggle*Vision function', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = true } })
    t.equals(#f.registerCommandCalls, 2)

    local thermalHandler, nightHandler
    for _, call in ipairs(f.registerCommandCalls) do
        if call.name == 'qbx_k9unit:toggleThermalVision' then thermalHandler = call.handler end
        if call.name == 'qbx_k9unit:toggleNightVision' then nightHandler = call.handler end
    end
    t.isNotNil(thermalHandler)
    t.isNotNil(nightHandler)

    thermalHandler()
    t.isTrue(f.isSeethroughActive(), 'the registered command handler must really call the production ToggleThermalVision(), not a copy')
end)

-- ========================================================================
-- CAMERA FEED (Config.Features.CameraFeedPiP) -- see client/vision.lua's
-- own header "CAMERA FEED" section for the full contract this section
-- tests against.
-- ========================================================================

t.test('CameraFeedPiP false: zero command/keybind registered, matching every other flag-gated registration in this file', function()
    local f = newVisionFixture({ features = { CameraFeedPiP = false } })
    t.equals(#f.registerCommandCalls, 0)
    t.equals(#f.registerKeyMappingCalls, 0)
end)

t.test('CameraFeedPiP true: exactly one command/keybind registered, using Config.CameraFeed.toggleKey', function()
    local f = newVisionFixture({ features = { CameraFeedPiP = true } })
    t.equals(#f.registerCommandCalls, 1)
    t.equals(f.registerCommandCalls[1].name, 'qbx_k9unit:toggleCameraFeed')
    t.equals(#f.registerKeyMappingCalls, 1)
    t.equals(f.registerKeyMappingCalls[1].commandName, 'qbx_k9unit:toggleCameraFeed')
    t.equals(f.registerKeyMappingCalls[1].description, locale('cameraFeed.toggle_keybind_label'))
    t.equals(f.registerKeyMappingCalls[1].defaultKey, f.Config.CameraFeed.toggleKey)
end)

t.test('CameraFeedPiP true but Config.CameraFeed is missing entirely: registration falls back to the hardcoded default key rather than erroring the whole file (defensive fallback -- this file does not own config.lua)', function()
    -- Simulate config.lua NOT having been updated yet, as if this pass's
    -- request to main never landed: overwrite the fixture's own baseline
    -- AFTER load is too late for the registration block (already ran at
    -- file-load time) -- so this specific test rebuilds the sandbox by
    -- hand with Config.CameraFeed deleted before client/vision.lua loads.
    -- (A second fixture variant, not a shared helper, because this is the
    -- one test in this file that needs to intervene BETWEEN config.lua
    -- loading and client/vision.lua loading.)
    local capturedKeyMappingCalls = {}
    local env = Sandbox.newEnv({
        RegisterCommand = function() end,
        RegisterKeyMapping = function(commandName, description, ioType, defaultKey)
            capturedKeyMappingCalls[#capturedKeyMappingCalls + 1] = { commandName = commandName, defaultKey = defaultKey }
        end,
        AddEventHandler = function() end,
        lib = { notify = function() end },
    })
    Sandbox.loadInto('../config.lua', env)
    -- Pinned for the same reason every other fixture in this file pins
    -- these two -- config.lua is edited by other agents while this suite
    -- runs, and this ad hoc env (unlike newVisionFixture()'s own) has no
    -- other reason to touch these, so pin them explicitly rather than
    -- relying on registration ORDER alone to keep this assertion honest.
    env.Config.Features.ThermalVision = false
    env.Config.Features.NightVision = false
    env.Config.Features.CameraFeedPiP = true
    env.Config.CameraFeed = nil
    local ok = pcall(Sandbox.loadInto, '../client/vision.lua', env)
    t.isTrue(ok, 'a missing Config.CameraFeed must never error client/vision.lua\'s top-level chunk (that would also silently disable ThermalVision/NightVision in the same file)')
    t.equals(#capturedKeyMappingCalls, 1)
    t.equals(capturedKeyMappingCalls[1].commandName, 'qbx_k9unit:toggleCameraFeed')
    t.equals(capturedKeyMappingCalls[1].defaultKey, 'H', 'falls back to CAMERA_FEED_DEFAULTS.toggleKey')
end)

t.test('ToggleCameraFeed: not a role-holder (CanShowK9UI false) -- denied, no cam created', function()
    local f = newVisionFixture()
    f.setCanShowK9UI(false)
    f.env.ToggleCameraFeed()
    t.equals(f.denyK9UIAccessCallCount(), 1)
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: HandlerPartnership feature is off (RefreshPartnershipStateFromServer genuinely undefined, not a stub) -- notifies partnership.feature_disabled, reusing that exact locale key, no cam created', function()
    local f = newVisionFixture({ partnershipAvailable = false })
    f.env.ToggleCameraFeed()
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('partnership.feature_disabled'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partnership enabled but not currently partnered -- notifies partnership.not_partnered_with_anyone, reused verbatim', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(false, nil)
    f.env.ToggleCameraFeed()
    t.equals(f.refreshCallCount(), 1, 'must call the FRESH server-authoritative refresh, not a cached synchronous read')
    t.equals(f.notifyCalls[1].description, locale('partnership.not_partnered_with_anyone'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partnered, but partner is offline (GetPlayerFromServerId -1) -- notifies common.target_no_longer_online, distinct from "not partnered at all"', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setPartnerPlayerIndex(-1)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('common.target_no_longer_online'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partner online but their ped is not streamed in (GetPlayerPed returns 0) -- notifies cameraFeed.partner_not_in_range', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setPartnerPed(0)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('cameraFeed.partner_not_in_range'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partner ped handle is nonzero but DoesEntityExist is false -- also treated as out of range, never assumed to exist from a handle alone', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setPartnerPed(999)
    f.setEntityExists(999, false)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('cameraFeed.partner_not_in_range'))
end)

t.test('ToggleCameraFeed: CreateCam fails (returns 0) -- notifies cameraFeed.camera_create_failed, no active state, no freeze', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setCreateCamReturn(0)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('cameraFeed.camera_create_failed'))
    t.equals(#f.freezeEntityPositionCalls, 0)
end)

t.test('ToggleCameraFeed: full success against a HANDLER partner (IsEntityModelK9 false) -- correct cam wiring, handlerEyeHeightOffset used, freeze applied, thread started, success notification names the partner', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setIsEntityModelK9(false)
    f.setPartnerName('Officer Rivera')
    f.setEntityRotation({ x = 1.0, y = 2.0, z = 3.0 })

    f.env.ToggleCameraFeed()

    t.equals(#f.createCamCalls, 1)
    t.equals(f.createCamCalls[1].camName, 'DEFAULT_SCRIPTED_CAMERA')
    t.equals(f.createCamCalls[1].active, false, 'created inactive -- SetCamActive(true) is a separate, explicit call below')

    t.equals(#f.attachCamToEntityCalls, 1)
    t.equals(f.attachCamToEntityCalls[1].entity, 999)
    t.equals(f.attachCamToEntityCalls[1].x, 0.0)
    t.equals(f.attachCamToEntityCalls[1].y, 0.0)
    t.equals(f.attachCamToEntityCalls[1].z, f.Config.CameraFeed.handlerEyeHeightOffset, 'handler role -> handlerEyeHeightOffset, not the K9 one')
    t.isTrue(f.attachCamToEntityCalls[1].isRelative)

    t.equals(#f.setCamFovCalls, 1)
    t.equals(f.setCamFovCalls[1].fov, f.Config.CameraFeed.fov)

    t.equals(#f.setCamRotCalls, 1)
    t.equals(f.setCamRotCalls[1].x, 1.0)
    t.equals(f.setCamRotCalls[1].y, 2.0)
    t.equals(f.setCamRotCalls[1].z, 3.0)
    t.equals(f.setCamRotCalls[1].order, 2)

    t.equals(#f.setCamActiveCalls, 1)
    t.isTrue(f.setCamActiveCalls[1].active)

    t.equals(#f.renderScriptCamsCalls, 1)
    t.isTrue(f.renderScriptCamsCalls[1].render)

    t.equals(#f.freezeEntityPositionCalls, 1)
    t.equals(f.freezeEntityPositionCalls[1].entity, 1, 'freezes the LOCAL player ped (id 1 in this fixture), never the partner')
    t.isTrue(f.freezeEntityPositionCalls[1].toggle)

    t.equals(f.notifyCalls[1].description, locale('cameraFeed.feed_started', 'Officer Rivera'))
    t.equals(f.notifyCalls[1].type, 'success')

    t.equals(f.threadCreateCount(), 1)
end)

t.test('ToggleCameraFeed: full success against a K9 partner (IsEntityModelK9 true) uses k9EyeHeightOffset, not handlerEyeHeightOffset', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setIsEntityModelK9(true)

    f.env.ToggleCameraFeed()

    t.equals(f.attachCamToEntityCalls[1].z, f.Config.CameraFeed.k9EyeHeightOffset)
end)

t.test('ToggleCameraFeed: calling it AGAIN while already active toggles OFF instead of starting a second feed', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    t.equals(#f.createCamCalls, 1)

    f.env.ToggleCameraFeed() -- off
    t.equals(#f.createCamCalls, 1, 'must not create a second cam -- this call is a toggle-off, not a fresh start')
    t.equals(#f.renderScriptCamsCalls, 2)
    t.isFalse(f.renderScriptCamsCalls[2].render)
    t.equals(#f.setCamActiveCalls, 2)
    t.isFalse(f.setCamActiveCalls[2].active)
    t.equals(#f.destroyCamCalls, 1)
    t.equals(#f.freezeEntityPositionCalls, 2)
    t.isFalse(f.freezeEntityPositionCalls[2].toggle, 'unfrozen on the way out')
    t.equals(f.notifyCalls[2].description, locale('cameraFeed.feed_ended_manual'))
end)

t.test('ToggleCameraFeed: toggle-off is UNCONDITIONAL -- works even with CanShowK9UI now false, mirroring this resource\'s "termination must never be gated" convention', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on

    f.setCanShowK9UI(false) -- access revoked mid-view
    f.env.ToggleCameraFeed() -- off -- must still succeed, not re-deny

    t.equals(f.denyK9UIAccessCallCount(), 0, 'toggling OFF must never re-check CanShowK9UI at all')
    t.equals(#f.destroyCamCalls, 1)
end)

t.test('ToggleCameraFeed: StopCameraFeed is idempotent against an already-destroyed cam (DoesCamExist false) -- SetCamActive/DestroyCam are skipped, not called on a dead handle', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    f.setCamExists(false) -- simulate the cam having already been destroyed by something else

    f.env.ToggleCameraFeed() -- off
    t.equals(#f.setCamActiveCalls, 1, 'only the turn-on SetCamActive(true) -- the turn-off one is skipped since DoesCamExist is false')
    t.equals(#f.destroyCamCalls, 0)
    t.equals(#f.freezeEntityPositionCalls, 2, 'the unfreeze itself is unconditional and still happens regardless of the cam\'s own existence')
end)

-- ------------------------------------------------------------------
-- Per-frame tracking/exit-condition thread. STEPPING NOTES FOR THIS
-- THREAD: its body is `while cameraFeedState.active do Wait(0) ... end`
-- -- the loop CONDITION is the very first thing evaluated (unlike this
-- file's OWN thermal/night thread, which runs a plain assignment before
-- its own while-check), so:
--   step() call #1 -- resumes from the start: evaluates the while-
--     condition (true, since ToggleCameraFeed() already set it before
--     this thread's body ever runs), enters the loop, and yields
--     immediately at Wait(0). A pure "prime" step, same as the thermal/
--     night thread's own step #1, for a different structural reason.
--   step() call #2 onward -- resumes after Wait(0), runs exactly one pass
--     of the exit-condition checks (and SetCamRot if none tripped), then
--     re-checks the while-condition: still true -> loops back to Wait(0)
--     and yields again; now false (a check just called StopCameraFeed())
--     -> falls out of the loop, clears cameraFeedThreadRunning, and the
--     coroutine dies within that SAME step() call.
-- ------------------------------------------------------------------

t.test('camera feed thread: does not exist at all before any feed is ever turned on', function()
    local f = newVisionFixture()
    t.equals(f.threadCreateCount(), 0)
end)

t.test('camera feed thread: while active and nothing has changed, each pass re-reads the partner\'s live rotation and re-applies SetCamRot -- the whole point of this thread', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on; SetCamRot already called once here
    f.step() -- prime

    f.setEntityRotation({ x = 9.0, y = 8.0, z = 7.0 })
    f.step() -- one real pass

    t.equals(#f.setCamRotCalls, 2, 'the onset call plus one thread pass')
    t.equals(f.setCamRotCalls[2].x, 9.0)
    t.equals(f.setCamRotCalls[2].y, 8.0)
    t.equals(f.setCamRotCalls[2].z, 7.0)
end)

t.test('camera feed thread: local player\'s own death ends the feed with feed_ended_own_death', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setIsEntityDead(true)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_own_death'))
end)

t.test('camera feed thread: losing CanShowK9UI mid-view ends the feed with feed_ended_access_lost', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setCanShowK9UI(false)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_access_lost'))
end)

t.test('camera feed thread: the partnership itself ending (IsPartnered turns false) ends the feed with feed_ended_partner_lost', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setIsPartnered(false)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_partner_lost'))
end)

t.test('camera feed thread: partner disconnecting mid-view (GetPlayerFromServerId now -1) ends the feed with feed_ended_partner_lost', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setPartnerPlayerIndex(-1)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_partner_lost'))
end)

t.test('camera feed thread: partner streaming out mid-view (their ped stops existing) ends the feed with feed_ended_partner_lost -- re-resolved fresh every tick, never a stale cached handle', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setEntityExists(999, false)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_partner_lost'))
end)

t.test('camera feed thread: self-terminates once the feed ends -- a LATER toggle-on starts a genuinely NEW thread', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on -- thread #1
    t.equals(f.threadCreateCount(), 1)
    f.step() -- prime
    f.setIsEntityDead(true)
    f.step() -- ends the feed, thread dies, guard resets

    f.setIsEntityDead(false)
    f.env.ToggleCameraFeed() -- on again
    t.equals(f.threadCreateCount(), 2, 'a fresh ON transition after the previous thread self-terminated must start a NEW thread')
end)

-- ------------------------------------------------------------------
-- onResourceStop -- extends the existing thermal/night handler; must also
-- silently (no notify) tear down an active camera feed.
-- ------------------------------------------------------------------

t.test('onResourceStop: an active camera feed is silently torn down (no notify) alongside the existing thermal/night reset', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    local notifyCountBefore = #f.notifyCalls

    f.fireResourceStop(f.resourceName)

    t.equals(#f.destroyCamCalls, 1)
    t.equals(#f.notifyCalls, notifyCountBefore, 'silent stop -- no player-facing message when the resource itself is stopping')
    t.equals(f.freezeEntityPositionCalls[#f.freezeEntityPositionCalls].toggle, false)
end)

t.test('onResourceStop: a harmless no-op when no camera feed was ever started', function()
    local f = newVisionFixture()
    local ok = pcall(f.fireResourceStop, f.resourceName)
    t.isTrue(ok)
    t.equals(#f.destroyCamCalls, 0)
end)

os.exit(t.summary())
