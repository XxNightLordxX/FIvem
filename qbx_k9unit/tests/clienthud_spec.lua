--[[
    tests/clienthud_spec.lua

    Direct, black-box tests of client/hud.lua against the REAL, unmodified
    production file: the Config.Features.HealthStaminaHUD file-scope gate,
    ReadVitals()'s health/stamina/hunger/thirst derivation (all `local`,
    reached only through the 'hud:ready' NUI callback and the poll thread's
    own pushes -- both real, resource-visible entry points), the five
    independently-gated wellbeing rows (fatigue/mood/fearStress/injury/
    distracted, each absent-not-zeroed when its own flag is off), the
    XPProgression-gated xpTier row and its soft dependency on
    GetCurrentXPTier(), the dkjson array-vs-object `__jsontype` fix on the
    wellbeing/xpTier sub-tables, and the poll thread's own becameVisible/
    epsilon/heartbeat push-decision logic including the "resend LAST KNOWN
    values, never a fresh read, on a true->false visibility transition" rule.

    THREAD STEPPING NOTE FOR THIS FILE'S ONE THREAD BODY -- DIFFERENT FROM
    EVERY OTHER CLIENT SPEC IN THIS SUITE, READ BEFORE TRUSTING A GENERIC
    "step() #1 just primes" ASSUMPTION HERE: client/hud.lua's poll thread
    puts its `Wait(...)` call at the END of each branch (idle or active),
    not at the top of the loop or right after a leading assignment the way
    every other thread in this suite's client specs is shaped (see
    tests/clientvision_spec.lua's and tests/clientaudio_spec.lua's own
    headers for THEIR respective deviations from the generic note -- this
    file is a THIRD, different shape again). Concretely:
        while true do
            local canShow = CanShowK9UI()
            if not canShow then
                if hudState.visible then PushVitals(false, ...) end
                Wait(HUD_IDLE_TICK_MS)
            else
                ... compute + maybe PushVitals(true, ...) ...
                Wait(HUD_POLL_TICK_MS)
            end
        end
    Every step() call -- INCLUDING THE FIRST -- therefore runs one COMPLETE
    evaluate-and-maybe-push pass BEFORE yielding at that pass's own Wait().
    There is no "priming-only" step here. `f.advance(ms)` (a fake
    GetGameTimer() clock) must be called between step()s to simulate real
    elapsed wait time for the heartbeat tests below, since the sandbox's
    Wait() stub does not itself consume any time.

    STUBBING EFFORT: every native here is a simple capturing/controllable
    stub (PlayerPedId, GetEntityHealth/GetEntityMaxHealth,
    GetPlayerSprintStaminaRemaining, PlayerId, GetGameTimer,
    RegisterNUICallback, SendNUIMessage, RegisterNetEvent). QBX is modeled
    as a plain Lua table this fixture constructs and mutates directly (the
    real global qbx_core's own `@qbx_core/modules/playerdata.lua` shared_script
    populates before ANY of this resource's own client scripts run, per
    fxmanifest.lua's dependency ordering -- this fixture always defines at
    least `QBX = { PlayerData = {} }`, matching that guarantee, rather than
    testing a "QBX itself is nil" case this file's own code does not defend
    against and that load order makes unreachable in practice).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { healthStaminaHUD: boolean?, features: table?, canShowK9UI: boolean? }?
--- @return table fixture
local function newHudFixture(opts)
    opts = opts or {}

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local function CanShowK9UI() return canShowK9UI end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local myPed = 1
    local function PlayerPedId() return myPed end

    local entityHealth, entityMaxHealth = 200.0, 200.0
    local function GetEntityHealth(_ped) return entityHealth end
    local function GetEntityMaxHealth(_ped) return entityMaxHealth end

    local staminaRemaining = 0.0 -- 0 exertion == full stamina, per ReadVitals' own inversion
    local function GetPlayerSprintStaminaRemaining(_playerId) return staminaRemaining end
    local function PlayerId() return 0 end

    local qbx = { PlayerData = { metadata = {} } }

    local registerNUICallbacks = {}
    local function RegisterNUICallback(name, handler) registerNUICallbacks[name] = handler end
    local sendNUIMessageCalls = {}
    local function SendNUIMessage(payload) sendNUIMessageCalls[#sendNUIMessageCalls + 1] = payload end

    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local env = Sandbox.newEnv({
        CanShowK9UI = CanShowK9UI,
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        GetPlayerSprintStaminaRemaining = GetPlayerSprintStaminaRemaining,
        PlayerId = PlayerId,
        QBX = qbx,
        RegisterNUICallback = RegisterNUICallback,
        SendNUIMessage = SendNUIMessage,
        CreateThread = CreateThread,
        Wait = Wait,
        RegisterNetEvent = RegisterNetEvent,
    })

    Sandbox.loadInto('../config.lua', env)

    if opts.healthStaminaHUD == false then
        env.Config.Features.HealthStaminaHUD = false
    end
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end

    Sandbox.loadInto('../client/hud.lua', env)

    return {
        env = env,
        Config = env.Config,
        sendNUIMessageCalls = sendNUIMessageCalls,
        threadCreateCount = function() return threadCreateCount end,
        step = function() runner.step() end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHealth = function(current, max) entityHealth = current; entityMaxHealth = max end,
        setStaminaRemaining = function(v) staminaRemaining = v end,
        setMetadata = function(field, v) qbx.PlayerData.metadata[field] = v end,
        clearPlayerData = function() qbx.PlayerData = nil end,
        fireHudReady = function()
            local handler = assert(registerNUICallbacks['hud:ready'], 'client/hud.lua did not register a hud:ready NUI callback')
            local cbCalls = {}
            handler({}, function(response) cbCalls[#cbCalls + 1] = response end)
            return cbCalls
        end,
        fireWellbeingUpdate = function(sourceValue, stats)
            local handler = netEventHandlers['qbx_k9unit:client:wellbeingUpdate']
            assert(handler, 'no wellbeingUpdate handler registered')
            env.source = sourceValue
            handler(stats)
        end,
        hasWellbeingHandler = function() return netEventHandlers['qbx_k9unit:client:wellbeingUpdate'] ~= nil end,
        lastMessage = function() return sendNUIMessageCalls[#sendNUIMessageCalls] end,
    }
end

-- ----------------------------------------------------------------------
-- Gating
-- ----------------------------------------------------------------------

t.test('gating: HealthStaminaHUD = false -- zero NUI callbacks, zero threads, and the wellbeingUpdate listener is not registered even if a wellbeing flag is on', function()
    local f = newHudFixture({ healthStaminaHUD = false, features = { FatigueSystem = true } })
    t.equals(f.threadCreateCount(), 0)
    t.isFalse(f.hasWellbeingHandler())
end)

t.test('gating: HealthStaminaHUD = true (real shipped default) -- one poll thread', function()
    local f = newHudFixture()
    t.equals(f.threadCreateCount(), 1)
end)

t.test('gating: no wellbeing flag on at all -- the wellbeingUpdate listener is never registered (ANY_WELLBEING_ELEMENT_ENABLED false)', function()
    local f = newHudFixture({ features = {
        FatigueSystem = false, MoodSystem = false, FearStressSystem = false,
        InjuryLimping = false, DistractionSystem = false,
    } })
    t.isFalse(f.hasWellbeingHandler())
end)

t.test('gating: exactly one wellbeing flag on -- the wellbeingUpdate listener IS registered', function()
    local f = newHudFixture({ features = { FatigueSystem = true, MoodSystem = false, FearStressSystem = false, InjuryLimping = false, DistractionSystem = false } })
    t.isTrue(f.hasWellbeingHandler())
end)

-- ----------------------------------------------------------------------
-- ReadVitals -- health/stamina/hunger/thirst, reached via 'hud:ready'
-- ----------------------------------------------------------------------

t.test('hud:ready: calls back with an empty table, unconditionally and immediately', function()
    local f = newHudFixture()
    local cbCalls = f.fireHudReady()
    t.equals(#cbCalls, 1)
    t.equals(type(cbCalls[1]), 'table')
end)

t.test('hud:ready: pushes exactly one immediate snapshot with visible = CanShowK9UI()', function()
    local f = newHudFixture({ canShowK9UI = false })
    f.fireHudReady()
    t.equals(#f.sendNUIMessageCalls, 1)
    t.equals(f.lastMessage().action, 'hud:updateVitals')
    t.isFalse(f.lastMessage().data.visible)
end)

t.test('health: normalized against GetEntityMaxHealth, 0-100 scale', function()
    local f = newHudFixture()
    f.setHealth(150, 200) -- 75%
    f.fireHudReady()
    t.equals(f.lastMessage().data.health, 75.0)
end)

t.test('health: GetEntityMaxHealth <= 0 defensively defaults to 100.0 rather than dividing by zero', function()
    local f = newHudFixture()
    f.setHealth(50, 0)
    local ok = pcall(f.fireHudReady)
    t.isTrue(ok)
    t.equals(f.lastMessage().data.health, 100.0)
end)

t.test('stamina: inverted from the raw exertion native -- 30 exertion reads as 70 stamina', function()
    local f = newHudFixture()
    f.setStaminaRemaining(30.0)
    f.fireHudReady()
    t.equals(f.lastMessage().data.stamina, 70.0)
end)

t.test('stamina: a non-number native return defaults to 100.0 (full), never an empty bar', function()
    local f = newHudFixture()
    local env = f.env
    env.GetPlayerSprintStaminaRemaining = function() return nil end
    f.fireHudReady()
    t.equals(f.lastMessage().data.stamina, 100.0)
end)

t.test('hunger/thirst: read from QBX.PlayerData.metadata, clamped 0-100', function()
    local f = newHudFixture()
    f.setMetadata('hunger', 40)
    f.setMetadata('thirst', 60)
    f.fireHudReady()
    t.equals(f.lastMessage().data.hunger, 40.0)
    t.equals(f.lastMessage().data.thirst, 60.0)
end)

t.test('hunger/thirst: QBX.PlayerData itself nil (not yet populated this early in a session) -- defaults to 100/100, not a crash', function()
    local f = newHudFixture()
    f.clearPlayerData()
    local ok = pcall(f.fireHudReady)
    t.isTrue(ok)
    t.equals(f.lastMessage().data.hunger, 100.0)
    t.equals(f.lastMessage().data.thirst, 100.0)
end)

t.test('hunger/thirst: a non-number metadata field defaults to 100, not 0', function()
    local f = newHudFixture()
    f.setMetadata('hunger', 'not-a-number')
    f.fireHudReady()
    t.equals(f.lastMessage().data.hunger, 100.0)
end)

t.test('clamp01to100: values above 100 clamp to 100, values below 0 clamp to 0', function()
    local f = newHudFixture()
    f.setMetadata('hunger', 250)
    f.setMetadata('thirst', -30)
    f.fireHudReady()
    t.equals(f.lastMessage().data.hunger, 100.0)
    t.equals(f.lastMessage().data.thirst, 0.0)
end)

-- ----------------------------------------------------------------------
-- Wellbeing rows -- per-flag absence (not zero), and the wellbeingUpdate
-- listener's own source-origin guard + shape validation.
-- ----------------------------------------------------------------------

t.test('wellbeing: with ONLY FatigueSystem on, the pushed wellbeing table has ONLY fatigue -- mood/fearStress/injury/distracted are all ABSENT keys, not zeroed', function()
    local f = newHudFixture({ features = { FatigueSystem = true, MoodSystem = false, FearStressSystem = false, InjuryLimping = false, DistractionSystem = false } })
    f.fireHudReady()
    local wellbeing = f.lastMessage().data.wellbeing
    t.isNotNil(wellbeing.fatigue)
    t.isNil(wellbeing.mood)
    t.isNil(wellbeing.fearStress)
    t.isNil(wellbeing.injury)
    t.isNil(wellbeing.distracted)
end)

t.test('wellbeing: with EVERY flag off, the pushed wellbeing table is completely empty, but still a table (not nil, not an array-coerced []) -- __jsontype forces it to encode as an object', function()
    local f = newHudFixture({ features = { FatigueSystem = false, MoodSystem = false, FearStressSystem = false, InjuryLimping = false, DistractionSystem = false, XPProgression = false } })
    f.fireHudReady()
    local msg = f.lastMessage()
    t.equals(type(msg.data.wellbeing), 'table')
    t.isNil(next(msg.data.wellbeing))
    t.equals(getmetatable(msg.data.wellbeing).__jsontype, 'object')
    t.equals(type(msg.data.xpTier), 'table')
    t.isNil(next(msg.data.xpTier))
    t.equals(getmetatable(msg.data.xpTier).__jsontype, 'object')
end)

t.test('wellbeingUpdate: source ~= 65535 is rejected -- the cache is untouched, and a subsequent push still reflects the OLD (seeded) values', function()
    local f = newHudFixture({ features = { FatigueSystem = true } })
    f.fireWellbeingUpdate(1234, { fatigue = 10 })
    f.fireHudReady()
    t.equals(f.lastMessage().data.wellbeing.fatigue, 100.0, 'a forged (non-65535-sourced) wellbeingUpdate must never move the cache')
end)

t.test('wellbeingUpdate: a real (65535-sourced), well-formed payload updates the cache, reflected on the next push', function()
    local f = newHudFixture({ features = { FatigueSystem = true, MoodSystem = true } })
    f.fireWellbeingUpdate(65535, { fatigue = 55, mood = 20 })
    f.fireHudReady()
    local wellbeing = f.lastMessage().data.wellbeing
    t.equals(wellbeing.fatigue, 55.0)
    t.equals(wellbeing.mood, 20.0)
end)

t.test('wellbeingUpdate: type(stats) ~= table is rejected -- no crash, cache untouched', function()
    local f = newHudFixture({ features = { FatigueSystem = true } })
    local ok = pcall(f.fireWellbeingUpdate, 65535, 'not-a-table')
    t.isTrue(ok)
    f.fireHudReady()
    t.equals(f.lastMessage().data.wellbeing.fatigue, 100.0)
end)

t.test('wellbeingUpdate: a PARTIAL payload leaves unmentioned fields at their prior cached value, not zeroed', function()
    local f = newHudFixture({ features = { FatigueSystem = true, MoodSystem = true } })
    f.fireWellbeingUpdate(65535, { fatigue = 55, mood = 20 })
    f.fireWellbeingUpdate(65535, { fatigue = 30 }) -- mood omitted this time
    f.fireHudReady()
    local wellbeing = f.lastMessage().data.wellbeing
    t.equals(wellbeing.fatigue, 30.0)
    t.equals(wellbeing.mood, 20.0, 'an omitted field in a later update must not reset to a default -- it must keep the last real value')
end)

t.test('distracted: true while distractedUntil is still in the future, false once GetGameTimer() passes it', function()
    local f = newHudFixture({ features = { DistractionSystem = true } })
    f.fireWellbeingUpdate(65535, { distractedUntil = 5000 })
    f.advance(1000)
    f.fireHudReady()
    t.isTrue(f.lastMessage().data.wellbeing.distracted)

    f.advance(10000) -- now well past 5000
    f.fireHudReady()
    t.isFalse(f.lastMessage().data.wellbeing.distracted)
end)

t.test('distracted: the key is absent entirely when DistractionSystem is off, no matter what distractedUntil holds', function()
    local f = newHudFixture({ features = { DistractionSystem = false } })
    f.fireHudReady()
    t.isNil(f.lastMessage().data.wellbeing.distracted)
end)

-- ----------------------------------------------------------------------
-- xpTier row -- soft dependency on GetCurrentXPTier()
-- ----------------------------------------------------------------------

t.test('xpTier: XPProgression = false -- label always absent, GetCurrentXPTier never even needs to exist', function()
    local f = newHudFixture({ features = { XPProgression = false } })
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true but GetCurrentXPTier does not exist (soft dependency absent) -- label absent, no crash', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    local ok = pcall(f.fireHudReady)
    t.isTrue(ok)
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true, GetCurrentXPTier returns nil (no snapshot received yet this session) -- label absent', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return nil end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true, GetCurrentXPTier returns a malformed (non-table, or missing .label) value -- label absent, defensively', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return 'not-a-table' end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true, GetCurrentXPTier returns a real tier -- label is present and correct', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Rookie', xp = 0 } end
    f.fireHudReady()
    t.equals(f.lastMessage().data.xpTier.label, 'Rookie')
end)

-- ----------------------------------------------------------------------
-- Poll thread -- becameVisible / epsilon / heartbeat push decisions, and
-- the true->false "resend last known values" rule. See this file's header
-- for this thread's own, unique stepping semantics.
-- ----------------------------------------------------------------------

t.test('poll thread: invisible throughout (CanShowK9UI always false) -- never pushes at all, idles at HUD_IDLE_TICK_MS (1000ms)', function()
    local f = newHudFixture({ canShowK9UI = false })
    f.step()
    f.step()
    f.step()
    t.equals(#f.sendNUIMessageCalls, 0)
end)

t.test('poll thread: becameVisible forces an immediate push with FRESH values, regardless of epsilon/heartbeat', function()
    local f = newHudFixture({ canShowK9UI = false })
    f.step() -- invisible pass, no push
    t.equals(#f.sendNUIMessageCalls, 0)

    f.setCanShowK9UI(true)
    f.setHealth(160, 200) -- 80%
    f.step() -- becameVisible pass -- must push immediately
    t.equals(#f.sendNUIMessageCalls, 1)
    t.isTrue(f.lastMessage().data.visible)
    t.equals(f.lastMessage().data.health, 80.0)
end)

t.test('poll thread: true->false transition resends the LAST KNOWN vitals, never a fresh read', function()
    local f = newHudFixture()
    f.setHealth(160, 200) -- 80%
    f.step() -- becameVisible push, health = 80

    f.setCanShowK9UI(false)
    f.setHealth(20, 200) -- change AFTER the transition -- must NOT be what gets pushed
    f.step()
    t.equals(f.lastMessage().data.visible, false)
    t.equals(f.lastMessage().data.health, 80.0, 'a false-transition push must resend the LAST KNOWN good value, never a fresh read')
end)

t.test('poll thread: staying invisible after the transition push does not push again', function()
    local f = newHudFixture()
    f.step() -- becomes visible, pushes
    f.setCanShowK9UI(false)
    f.step() -- transition push
    local countAfterTransition = #f.sendNUIMessageCalls
    f.step() -- still invisible, nothing changed
    f.step()
    t.equals(#f.sendNUIMessageCalls, countAfterTransition, 'no repeat push while genuinely, continuously hidden')
end)

t.test('poll thread: a change below HUD_CHANGE_EPSILON (0.5) does not trigger a re-push', function()
    local f = newHudFixture()
    f.setHealth(160, 200) -- 80.0
    f.step()
    local countBefore = #f.sendNUIMessageCalls

    f.setHealth(160.6, 200) -- 80.3 -- diff 0.3 < epsilon
    f.step()
    t.equals(#f.sendNUIMessageCalls, countBefore, 'a sub-epsilon change must not trigger a re-push before the heartbeat is due')
end)

t.test('poll thread: a change ABOVE HUD_CHANGE_EPSILON triggers an immediate re-push', function()
    local f = newHudFixture()
    f.setHealth(160, 200) -- 80.0
    f.step()
    local countBefore = #f.sendNUIMessageCalls

    f.setHealth(161.2, 200) -- 80.6 -- diff 0.6 > epsilon
    f.step()
    t.equals(#f.sendNUIMessageCalls, countBefore + 1)
    t.equals(f.lastMessage().data.health, 80.6)
end)

t.test('poll thread: HUD_HEARTBEAT_MS (1000ms) forces a re-push even with ZERO real change', function()
    local f = newHudFixture()
    f.step() -- becameVisible push at fakeNow=0
    local countAfterFirst = #f.sendNUIMessageCalls

    f.advance(250)
    f.step() -- 250ms elapsed -- no change, heartbeat not due
    t.equals(#f.sendNUIMessageCalls, countAfterFirst)

    f.advance(250)
    f.step() -- 500ms elapsed
    t.equals(#f.sendNUIMessageCalls, countAfterFirst)

    f.advance(250)
    f.step() -- 750ms elapsed
    t.equals(#f.sendNUIMessageCalls, countAfterFirst)

    f.advance(250)
    f.step() -- 1000ms elapsed -- heartbeat due, even though nothing changed
    t.equals(#f.sendNUIMessageCalls, countAfterFirst + 1, 'the heartbeat ceiling must force a re-push even with zero real change')
end)

os.exit(t.summary())
