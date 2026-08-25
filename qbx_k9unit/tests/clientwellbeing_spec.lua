--[[
    tests/clientwellbeing_spec.lua

    Client-side spec for client/wellbeing.lua (the unified Fatigue/Mood/
    FearStress/Distraction/Injury subsystem's client half). Follows
    main_spec.lua's worked example: a real, unmodified client/wellbeing.lua
    loaded into a fresh sandbox per test, driven through its documented
    resource-global (RequestK9CalmDown), its two RegisterNetEvent/
    RegisterCommand-captured handlers, its ox_target option definitions,
    and its two CreateThread bodies -- never a reimplementation of any
    `local` (ApplyMoveRateModifiers/ApplyWellbeingSnapshot/NotifyResult/
    UseDistractionItem) this spec has no other way to reach.

    LOAD-TIME GATING, IMPORTANT FOR THIS FIXTURE: unlike client/tracking.lua
    (whose Config.Features reads all happen at RUNTIME, inside thread
    bodies), client/wellbeing.lua's five feature gates
    (`if Config.Features.InjuryLimping then ... end`,
    `if Config.Features.MoodSystem then ... end`,
    `if Config.Features.DistractionSystem then ... end`, and the on-demand
    snapshot thread's own five-flag OR) are bare top-level `if` blocks --
    they run ONCE, at file-load time, deciding whether to even CREATE the
    relevant thread/register the relevant command/ox_target option at all.
    Exactly like clientradial_spec.lua's own newRadialFixture(), every flag
    this spec needs MUST be set on the real config.lua's Config.Features
    table BEFORE client/wellbeing.lua is loaded -- newWellbeingFixture()
    below defaults every one of the five wellbeing flags to `false` and
    requires each test to opt in exactly what it needs, per this task's own
    instruction to never depend on config.lua's shipped defaults (currently
    all 40 flags `true`).

    THIS PASS'S PRIORITY, per this file's own task brief:
    1. The InjuryLimping control-block thread's own-death guard, added this
       session after it was found spinning at Wait(0) while dead -- section
       B, using the same instrumented coroutine-yield thread runner
       clienttracking_spec.lua's own header documents in full (built fresh
       here too, per this suite's "each spec owns its own tiny fixtures"
       convention -- not shared, since the two files' CreateThread bodies
       differ).
    2. Every wellbeing stat has a defined (non-crashing, side-effect-free)
       path when its OWNING feature flag is off -- section C, covering all
       five flags individually plus the "every flag off at once, with
       extreme stat values that would trip every branch if the flags were
       on" case.
    3. The `source ~= 65535` guard on the wellbeingUpdate handler -- section
       D, with the same D3-scope caveat clientsearch_spec.lua's own section
       F carries, repeated here per this task's own instruction never to
       leave that caveat findable only in one file.

    STUBBING EFFORT, reported honestly: proportionate, though this is the
    widest-surface of the three files in this task (five independently
    gated blocks, two CreateThread bodies, one ox_target pair, three
    RegisterCommand handlers, one RegisterNetEvent handler). Every stub is
    still the same small recording/controllable shape already established
    across this suite -- nothing here required disproportionate stubbing.
    Two stubs are unique to this file versus the other two specs in this
    task: K9MoveRateModifiers/RecomputeK9MoveRate (client/movement.lua
    resource-globals this file writes to/calls but never defines itself --
    a plain table plus a call-counting function is sufficient, since this
    spec only needs to prove WHAT this file writes into that table, never
    RecomputeK9MoveRate's own real composition math, which belongs to
    client/movement.lua's own spec if one exists) and GetGameTimer (a
    controllable fake clock, for the distractedUntil/hesitatingUntil
    comparisons -- identical `fakeNow`/`advance()` shape to main_spec.lua's
    own HasK9Access TTL fixture).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

--- Sentinel returned by `queueCallbackThrow()` -- see clientsearch_spec.lua's
--- own identical THROW sentinel for the same rationale (ox_lib's real
--- lib.callback.await throws on a timeout/rejection rather than returning
--- nil; client/wellbeing.lua's own FAIL-CLOSED GUARD comments, added the
--- same session this spec was written, pcall every call site for exactly
--- this reason).
local THROW = setmetatable({}, { __tostring = function() return 'THROW' end })

-- ----------------------------------------------------------------------
-- Instrumented thread runner -- see clienttracking_spec.lua's own header
-- for the full rationale (every thread in this codebase's convention
-- calls Wait(...) at the END of its loop body, not the start, so the
-- FIRST resume already performs one real pass; Sandbox.newThreadRunner()'s
-- own "first step() only primes" semantics do not apply here). Built
-- fresh in this file too, per this suite's "each spec owns its own tiny
-- fixtures" convention -- not extracted to a shared helper, since sharing
-- one two-file-specific runner is a smaller win than keeping each spec
-- self-contained and independently readable.
-- ----------------------------------------------------------------------
local function newTrackedRunner()
    local threads = {}
    local waitLog = {}
    local runner = {}

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(ms)
        coroutine.yield(ms)
    end

    function runner.stepOne(i)
        local co = threads[i]
        if not co or coroutine.status(co) == 'dead' then return end
        local ok, msOrErr = coroutine.resume(co)
        if not ok then
            error(('clientwellbeing_spec: thread %d errored: %s'):format(i, tostring(msOrErr)))
        end
        waitLog[i] = msOrErr
    end

    function runner.step()
        for i = 1, #threads do runner.stepOne(i) end
    end

    return runner, threads, waitLog
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { features: table?, canShowK9UI: boolean? }?
local function newWellbeingFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local canShowK9UICallCount = 0
    local denyCalls = 0
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local isOwnModelK9 = false
    local function IsOwnModelK9() return isOwnModelK9 end

    local modelK9ByEntity = {} -- entity -> boolean
    local function IsEntityModelK9(entity) return modelK9ByEntity[entity] == true end

    local serverIdByPed = {} -- entity -> serverId or nil
    local function ResolvePlayerServerIdFromPed(entity) return serverIdByPed[entity] end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local myPed = 1
    local pedDead = false
    local function PlayerPedId() return myPed end
    local function IsEntityDead(entity) return pedDead end

    local disableControlActionCalls = {}
    local function DisableControlAction(inputGroup, control, disable)
        disableControlActionCalls[#disableControlActionCalls + 1] = { inputGroup = inputGroup, control = control, disable = disable }
    end

    -- lib.callback.await -- one shared FIFO queue, sufficient because every
    -- test below only ever has ONE callback-awaiting action in flight at a
    -- time (the on-demand snapshot thread, or exactly one Pet/Feed/
    -- distraction-item onSelect/command call). A queued THROW sentinel
    -- errors instead of returning, modeling ox_lib's real timeout/rejection
    -- behavior (see this file's own header on the FAIL-CLOSED GUARD).
    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local next = table.remove(callbackResponses, 1)
        if next == THROW then
            error('simulated lib.callback.await failure (timeout/rejection)')
        end
        return next
    end

    local notifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    -- client/movement.lua resource-globals this file writes to/calls but
    -- never defines -- see this file's own header on why a plain table
    -- plus a call counter is sufficient here.
    local k9MoveRateModifiers = { fatigue = 42, injury = 42, mood = 42 } -- sentinel 42s: any test that must prove a slot was NEVER touched checks for exactly this value surviving
    local recomputeCallCount = 0
    local function RecomputeK9MoveRate() recomputeCallCount = recomputeCallCount + 1 end

    -- client/wellbeing.lua now routes its "Pet K9"/"Feed K9" options
    -- through K9Compat.Get('target') (shared/compat/target.lua) rather than
    -- calling `exports.ox_target` directly -- see that file's own header.
    -- This fixture loads the REAL shared/compat/core.lua +
    -- shared/compat/target.lua (never a hand-written fake translation
    -- layer, which would just assert against itself) so K9Compat.Get
    -- ('target') resolves to the REAL ox_target adapter, which is a
    -- byte-for-byte pass-through of the options table -- captured below via
    -- the exact same colon-call `exports.ox_target:addGlobalPlayer` stub as
    -- before. ox_target is the ONLY candidate this fixture makes
    -- `GetResourceState` report as 'started', so detection deterministically
    -- resolves to it. Every REQUIRED_EXPORTS name (shared/compat/
    -- target.lua's OxTargetFactory) must exist as a callable function or the
    -- whole adapter is rejected as unverified and silently falls back to
    -- the no-op stub -- the exports this file never actually exercises are
    -- still stubbed as harmless no-ops so verification passes.
    local addGlobalPlayerCalls = {}
    local oxTargetStub = {}
    function oxTargetStub.addGlobalPlayer(_, defs) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = defs end
    function oxTargetStub.addGlobalVehicle() end
    function oxTargetStub.addGlobalObject() end
    function oxTargetStub.addModel() end
    function oxTargetStub.addSphereZone() end
    function oxTargetStub.removeGlobalPlayer() end
    function oxTargetStub.removeGlobalVehicle() end
    function oxTargetStub.removeGlobalObject() end
    function oxTargetStub.removeModel() end
    function oxTargetStub.removeZone() end
    function oxTargetStub.addLocalEntity() end
    function oxTargetStub.removeLocalEntity() end

    local function IsDuplicityVersion() return false end -- client realm, for shared/compat/core.lua
    local function GetResourceState(resourceName)
        return resourceName == 'ox_target' and 'started' or 'missing'
    end

    -- AddEventHandler -- captures EVERY event name (not just
    -- 'onResourceStart'): shared/compat/core.lua also registers
    -- 'onClientResourceStart'/'onClientResourceStop' handlers at load time
    -- (client realm) that this fixture never fires, but must not reject.
    -- `resourceStartHandlers` stays scoped to 'onResourceStart'
    -- specifically, exactly as before.
    local resourceStartHandlers = {}
    local otherEventHandlers = {}
    local function AddEventHandler(eventName, handler)
        if eventName == 'onResourceStart' then
            resourceStartHandlers[#resourceStartHandlers + 1] = handler
        else
            otherEventHandlers[eventName] = otherEventHandlers[eventName] or {}
            otherEventHandlers[eventName][#otherEventHandlers[eventName] + 1] = handler
        end
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local commands = {}
    local function RegisterCommand(name, handler, restricted) commands[name] = handler end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        IsOwnModelK9 = IsOwnModelK9,
        IsEntityModelK9 = IsEntityModelK9,
        ResolvePlayerServerIdFromPed = ResolvePlayerServerIdFromPed,
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        DisableControlAction = DisableControlAction,
        lib = lib,
        K9MoveRateModifiers = k9MoveRateModifiers,
        RecomputeK9MoveRate = RecomputeK9MoveRate,
        exports = { ox_target = oxTargetStub },
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        TriggerServerEvent = TriggerServerEvent,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        IsDuplicityVersion = IsDuplicityVersion,
        GetResourceState = GetResourceState,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- Explicit, per this task's own instruction: every one of the five
    -- wellbeing feature flags defaults to false here, regardless of
    -- config.lua's own shipped value (currently true for all 40 flags) --
    -- each test opts in exactly what it needs.
    env.Config.Features.FatigueSystem = false
    env.Config.Features.MoodSystem = false
    env.Config.Features.FearStressSystem = false
    env.Config.Features.DistractionSystem = false
    env.Config.Features.InjuryLimping = false
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end

    -- Real K9Compat, real ox_target adapter -- see the oxTargetStub comment
    -- above for why. Must load before client/wellbeing.lua, which reads the
    -- `K9Compat` global inside RegisterMoodOxTargetOptions() (fired below
    -- via the captured onResourceStart handler, when MoodSystem is on).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/target.lua', env)

    -- IsK9RoleForPlayer lives here. client/wellbeing.lua's ox_target
    -- predicates ask "is that OTHER player a K9", which the any-ped work
    -- moved from a model check to a role check -- and the role answer is
    -- defined in client/appearance.lua. The manifest loads both, so the
    -- game is fine; a sandbox that loads only the file under test is not.
    Sandbox.loadInto('../client/appearance.lua', env)
    Sandbox.loadInto('../client/wellbeing.lua', env)

    for _, fn in ipairs(resourceStartHandlers) do
        fn('qbx_k9unit')
    end

    return {
        env = env,
        threads = threads,
        waitLog = waitLog,
        step = runner.step,
        stepOne = runner.stepOne,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        disableControlActionCalls = disableControlActionCalls,
        k9MoveRateModifiers = k9MoveRateModifiers,
        recomputeCallCount = function() return recomputeCallCount end,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        denyCallCount = function() return denyCalls end,
        -- Sets BOTH halves of the same underlying fact, deliberately.
        -- In production IsOwnModelK9() is `IsEntityModelK9(PlayerPedId())
        -- or role`, so "my own model is a K9" and "the player ped is a K9
        -- model" are not two independent knobs -- the first implies the
        -- second. They were separate here only because nothing read the
        -- entity form for the local ped until the injury block moved to
        -- IsEntityModelK9(PlayerPedId()) (owner's decision: a role-holder on
        -- a human body keeps sprint and jump). Keeping them in step here is
        -- what stops a test asserting a state a real client cannot be in.
        setIsOwnModelK9 = function(v)
            isOwnModelK9 = v
            modelK9ByEntity[myPed] = v or nil
        end,
        setEntityIsK9Model = function(entity, v) modelK9ByEntity[entity] = v end,
        setServerIdForPed = function(entity, serverId) serverIdByPed[entity] = serverId end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setPedDead = function(v) pedDead = v end,

        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        queueCallbackThrow = function() callbackResponses[#callbackResponses + 1] = THROW end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,

        petOption = function()
            for _, defs in ipairs(addGlobalPlayerCalls) do
                for _, def in ipairs(defs) do
                    if def.name == 'qbx_k9unit:petK9' then return def end
                end
            end
        end,
        feedOption = function()
            for _, defs in ipairs(addGlobalPlayerCalls) do
                for _, def in ipairs(defs) do
                    if def.name == 'qbx_k9unit:feedK9' then return def end
                end
            end
        end,
        addGlobalPlayerCallCount = function() return #addGlobalPlayerCalls end,

        command = function(name) return commands[name] end,
        commandCount = function() local n = 0; for _ in pairs(commands) do n = n + 1 end; return n end,

        --- Invokes the REAL captured wellbeingUpdate handler with `source`
        --- set immediately beforehand -- same convention main_spec.lua's
        --- own triggerPlayBark uses.
        triggerWellbeingUpdate = function(sourceValue, stats)
            local handler = assert(netEventHandlers['qbx_k9unit:client:wellbeingUpdate'],
                'client/wellbeing.lua did not register a qbx_k9unit:client:wellbeingUpdate handler')
            env.source = sourceValue
            handler(stats)
        end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity
-- ----------------------------------------------------------------------

t.test('client/wellbeing.lua exposes RequestK9CalmDown and registers the wellbeingUpdate handler', function()
    local f = newWellbeingFixture()
    t.isNotNil(f.env.RequestK9CalmDown)
    f.triggerWellbeingUpdate(65535, { fatigue = 100 }) -- must not throw "handler not registered"
end)

-- ----------------------------------------------------------------------
-- SECTION A -- no thread/command/ox_target option exists at all when its
-- owning flag is off ("no code needed when disabled", per this file's own
-- header). Proven first since sections B/C build on top of this.
-- ----------------------------------------------------------------------

t.test('every wellbeing flag off: zero threads created, zero ox_target options registered, zero commands beyond none of this file\'s conditional ones', function()
    local f = newWellbeingFixture() -- all five flags false by default
    t.equals(#f.threads, 0, 'neither the on-demand snapshot thread nor the InjuryLimping thread may exist when every flag is off')
    t.equals(f.addGlobalPlayerCallCount(), 0, 'Pet K9/Feed K9 must never be registered when MoodSystem is off')
    t.isNil(f.command('k9meatbait'))
    t.isNil(f.command('k9whistle'))
    -- k9calmdown IS always registered (RequestK9CalmDown itself checks the
    -- flag at call time, not at registration time -- see section E).
    t.isNotNil(f.command('k9calmdown'))
end)

-- ----------------------------------------------------------------------
-- SECTION B -- THE INJURYLIMPING OWN-DEATH GUARD, THIS TASK'S TOP
-- PRIORITY. Thread order at file-load time with InjuryLimping=true (and
-- every other flag false): the on-demand snapshot thread is created FIRST
-- (its own gate ORs in InjuryLimping), the InjuryLimping control-block
-- thread SECOND -- threads[1] / threads[2] respectively, verified by
-- reading the file top-to-bottom.
-- ----------------------------------------------------------------------

t.test('InjuryLimping thread: below-threshold injury blocks sprint+jump every frame (Wait(0)) while alive and K9-modeled', function()
    local f = newWellbeingFixture({ features = { InjuryLimping = true } })
    t.equals(#f.threads, 2, 'sanity: the on-demand snapshot thread (InjuryLimping ORs into its own gate) plus the InjuryLimping thread itself')

    local sprintThreshold = f.env.Config.Wellbeing.Injury.sprintBlockThreshold
    local jumpThreshold = f.env.Config.Wellbeing.Injury.jumpBlockThreshold
    local belowBoth = math.min(sprintThreshold, jumpThreshold) - 1
    f.triggerWellbeingUpdate(65535, { injury = belowBoth })

    f.setIsOwnModelK9(true)
    f.setPedDead(false)
    f.step() -- one pass of both threads

    t.equals(f.waitLog[2], 0, 'must run at full per-frame rate while actively blocking input, per DisableControlAction\'s own contract')
    local sawSprint, sawJump = false, false
    for _, call in ipairs(f.disableControlActionCalls) do
        if call.control == 21 then sawSprint = true end
        if call.control == 22 then sawJump = true end
    end
    t.isTrue(sawSprint, 'INPUT_SPRINT (21) must be disabled when injury is below sprintBlockThreshold')
    t.isTrue(sawJump, 'INPUT_JUMP (22) must be disabled when injury is below jumpBlockThreshold')
end)

t.test('REGRESSION LOCK-IN: the InjuryLimping thread idles (Wait(1000), zero DisableControlAction calls) the instant the K9\'s own ped is dead -- it must NOT keep spinning at Wait(0) while dead', function()
    local f = newWellbeingFixture({ features = { InjuryLimping = true } })
    local belowBoth = math.min(f.env.Config.Wellbeing.Injury.sprintBlockThreshold, f.env.Config.Wellbeing.Injury.jumpBlockThreshold) - 1
    f.triggerWellbeingUpdate(65535, { injury = belowBoth })
    f.setIsOwnModelK9(true)

    f.setPedDead(true)
    f.step()

    t.equals(#f.disableControlActionCalls, 0, 'THE REGRESSION: a dead ped must never have DisableControlAction called against it -- it can neither sprint nor jump anyway')
    t.equals(f.waitLog[2], 1000, 'THE REGRESSION: must idle at the same 1000ms as the "not currently K9" branch, not spin at Wait(0) while dead')
end)

t.test('the InjuryLimping thread resumes real per-frame blocking the instant the ped is alive again, no separate respawn hook needed', function()
    local f = newWellbeingFixture({ features = { InjuryLimping = true } })
    local belowBoth = math.min(f.env.Config.Wellbeing.Injury.sprintBlockThreshold, f.env.Config.Wellbeing.Injury.jumpBlockThreshold) - 1
    f.triggerWellbeingUpdate(65535, { injury = belowBoth })
    f.setIsOwnModelK9(true)

    f.setPedDead(true)
    f.step()
    t.equals(#f.disableControlActionCalls, 0)

    f.setPedDead(false) -- respawned
    f.step()
    t.isTrue(#f.disableControlActionCalls > 0, 'must resume blocking on the very next pass once alive again -- IsEntityDead() is polled fresh every iteration')
    t.equals(f.waitLog[2], 0)
end)

t.test('IDLE-SPIN FIX (performance audit, this pass): InjuryLimping thread: healthy injury (above both thresholds) never blocks any control, and now idles at 1000ms -- NOT Wait(0) -- the same coarse cadence as being dead/not-a-K9', function()
    -- CORRECTED, this pass -- this test used to assert `f.waitLog[2] == 0`
    -- ("still runs at Wait(0) -- 'alive and K9-modeled' is the branch
    -- condition, independent of whether either threshold currently
    -- applies") and locked that in as the EXPECTED behavior. It was not: a
    -- performance audit found this was a real, live idle-spin bug, and the
    -- one that mattered most of the three found in this resource this
    -- session, because it hit the DEFAULT case rather than an edge case --
    -- with the shipped thresholds (sprintBlockThreshold=30,
    -- jumpBlockThreshold=20 out of Injury.max=100), a HEALTHY K9 (injury
    -- anywhere in (30, 100], the overwhelmingly common state) spun this
    -- thread at full per-frame rate forever -- roughly 180 native calls/sec
    -- sustained (PlayerPedId, IsOwnModelK9 -> GetEntityModel, IsEntityDead),
    -- for every K9 player, for the entire time they played, for zero
    -- gameplay effect, since DisableControlAction was never even being
    -- called that tick. FIXED in client/wellbeing.lua: Wait(0) is now taken
    -- ONLY when at least one threshold is ACTUALLY crossed this tick (i.e.
    -- there is a real DisableControlAction call to re-assert); a healthy K9
    -- idles at the same 1000ms as the dead/not-a-K9 branches, mirroring the
    -- OWN-DEATH GUARD's own already-established cadence for the identical
    -- "nothing to do this tick" reasoning. DO NOT revert this back to
    -- Wait(0) believing the spin was deliberate -- it was the bug this
    -- comment exists to prevent from quietly reappearing.
    local f = newWellbeingFixture({ features = { InjuryLimping = true } })
    -- lastStats.injury starts at its safe default (100, per this file's own
    -- header) -- never pushed below any threshold in this test.
    f.setIsOwnModelK9(true)
    f.setPedDead(false)
    f.step()
    t.equals(#f.disableControlActionCalls, 0, 'a healthy K9 must never have any control disabled')
    t.equals(f.waitLog[2], 1000, 'THE FIX: a healthy K9 (injury at/above BOTH thresholds, nothing to enforce this tick) must idle coarsely, not spin at full frame rate for zero effect')
end)

t.test('InjuryLimping thread: not currently K9-modeled at all also idles at 1000ms, the same branch as own-death', function()
    local f = newWellbeingFixture({ features = { InjuryLimping = true } })
    f.setIsOwnModelK9(false)
    f.setPedDead(false)
    f.step()
    t.equals(#f.disableControlActionCalls, 0)
    t.equals(f.waitLog[2], 1000)
end)

-- ----------------------------------------------------------------------
-- SECTION C -- EVERY WELLBEING STAT HAS A DEFINED PATH WHEN ITS OWNING
-- FEATURE FLAG IS OFF. Extreme values that WOULD trip every branch if the
-- flags were on, pushed with every flag off first, then individually
-- turned on one at a time to prove the contrast is real (not just "the
-- values happened to be healthy").
-- ----------------------------------------------------------------------

t.test('every wellbeing flag off: extreme stat values touch NOTHING -- K9MoveRateModifiers untouched, zero notifies, yet RecomputeK9MoveRate is STILL called unconditionally', function()
    local f = newWellbeingFixture() -- all five flags false
    f.triggerWellbeingUpdate(65535, {
        fatigue = 0, mood = 0, injury = 0, fearStress = 100,
        distractedUntil = 999999, hesitatingUntil = 999999,
    })
    t.equals(f.k9MoveRateModifiers.fatigue, 42, 'a disabled stat\'s modifier slot must be left exactly as it was -- never forced by a flag this file doesn\'t own the meaning of')
    t.equals(f.k9MoveRateModifiers.injury, 42)
    t.equals(f.k9MoveRateModifiers.mood, 42)
    t.equals(f.recomputeCallCount(), 1, 'RecomputeK9MoveRate is called unconditionally on every applied snapshot, regardless of which (if any) flags are on')
    t.equals(#f.notifyCalls, 0, 'no distraction/hesitation notify may fire while both owning flags are off, however extreme the pushed values are')
end)

t.test('FatigueSystem alone on: low fatigue updates ONLY K9MoveRateModifiers.fatigue; injury/mood stay untouched', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    local belowThreshold = f.env.Config.Wellbeing.Fatigue.speedPenaltyThreshold - 1
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold, injury = 0, mood = 0 })
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier)
    t.equals(f.k9MoveRateModifiers.injury, 42, 'InjuryLimping is off -- injury slot must stay untouched even though injury = 0 would trip its own penalty if that flag were on')
    t.equals(f.k9MoveRateModifiers.mood, 42)
end)

t.test('InjuryLimping alone on (move-rate path, distinct from section B\'s input-block thread): low injury updates ONLY K9MoveRateModifiers.injury', function()
    local f = newWellbeingFixture({ features = { InjuryLimping = true } })
    local injuryThreshold = math.max(f.env.Config.Wellbeing.Injury.sprintBlockThreshold, f.env.Config.Wellbeing.Injury.jumpBlockThreshold)
    f.triggerWellbeingUpdate(65535, { injury = injuryThreshold - 1, fatigue = 0, mood = 0 })
    t.equals(f.k9MoveRateModifiers.injury, f.env.Config.Wellbeing.Injury.speedPenaltyMultiplier)
    t.equals(f.k9MoveRateModifiers.fatigue, 42)
    t.equals(f.k9MoveRateModifiers.mood, 42)
end)

t.test('MoodSystem alone on: low mood updates ONLY K9MoveRateModifiers.mood', function()
    local f = newWellbeingFixture({ features = { MoodSystem = true } })
    local belowThreshold = f.env.Config.Wellbeing.Mood.performancePenaltyThreshold - 1
    f.triggerWellbeingUpdate(65535, { mood = belowThreshold, fatigue = 0, injury = 0 })
    t.equals(f.k9MoveRateModifiers.mood, f.env.Config.Wellbeing.Mood.performancePenaltyMultiplier)
    t.equals(f.k9MoveRateModifiers.fatigue, 42)
    t.equals(f.k9MoveRateModifiers.injury, 42)
end)

t.test('DistractionSystem OFF: a distractedUntil far in the future never notifies, and toggling it back and forth still never notifies -- a fully defined, silent no-op path', function()
    local f = newWellbeingFixture() -- DistractionSystem false
    f.triggerWellbeingUpdate(65535, { distractedUntil = 999999 })
    t.equals(#f.notifyCalls, 0)
    f.advance(1000000)
    f.triggerWellbeingUpdate(65535, { distractedUntil = 0 })
    t.equals(#f.notifyCalls, 0, 'still zero -- the transition-tracking logic itself must never run at all while the flag is off')
end)

t.test('DistractionSystem ON: notifies on the false->true transition and again on true->false, exactly once each', function()
    local f = newWellbeingFixture({ features = { DistractionSystem = true } })
    f.triggerWellbeingUpdate(65535, { distractedUntil = 999999 }) -- now < distractedUntil -> distracted
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('wellbeing.distracted'))
    t.equals(f.notifyCalls[1].type, 'error')

    f.triggerWellbeingUpdate(65535, { distractedUntil = 999999 }) -- still distracted -- must not re-notify
    t.equals(#f.notifyCalls, 1)

    f.advance(1000000)
    f.triggerWellbeingUpdate(65535, { distractedUntil = 999999 }) -- now stale -- no longer distracted
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('wellbeing.refocused'))
    t.equals(f.notifyCalls[2].type, 'info')
end)

t.test('FearStressSystem OFF: an extreme hesitatingUntil never notifies -- a fully defined, silent no-op path', function()
    local f = newWellbeingFixture() -- FearStressSystem false
    f.triggerWellbeingUpdate(65535, { hesitatingUntil = 999999 })
    t.equals(#f.notifyCalls, 0)
end)

t.test('FearStressSystem ON: notifies hesitating then settled on the matching transitions', function()
    local f = newWellbeingFixture({ features = { FearStressSystem = true } })
    f.triggerWellbeingUpdate(65535, { hesitatingUntil = 999999 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('wellbeing.hesitating'))

    f.advance(1000000)
    f.triggerWellbeingUpdate(65535, { hesitatingUntil = 999999 })
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('wellbeing.settled'))
end)

t.test('a non-table stats payload is a clean no-op, never an error, regardless of which flags are on', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true, MoodSystem = true, InjuryLimping = true, DistractionSystem = true, FearStressSystem = true } })
    f.triggerWellbeingUpdate(65535, 'not a table')
    t.equals(f.recomputeCallCount(), 0, 'ApplyWellbeingSnapshot must return before touching anything when stats is not a table')
    t.equals(#f.notifyCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- `source ~= 65535` GUARD on the wellbeingUpdate handler.
--
-- SCOPE NOTE (repeated here per this task's own instruction, not left
-- findable only in clientsearch_spec.lua/main_spec.lua): every test below
-- pins what THIS FILE'S CODE does for a given `source` value. None of
-- them settle, and none should be read as settling, this project's open
-- decision D3 (DEVELOPER_REFERENCE.md) -- whether FiveM's real client runtime
-- can ever be made to deliver a forged local trigger carrying a stale or
-- incorrect `source` left over from an earlier genuine server-sent event
-- on the same connection. Independent attempts to close D3 by reading the
-- engine's own source code have repeatedly hit the same wall (four, per
-- DEVELOPER_REFERENCE.md's own count as of this session; five per this task's
-- own brief -- neither count is something a Lua-level sandbox test can
-- move). DEVELOPER_REFERENCE.md's own words: "Do not settle this by reading
-- more code -- only the live test settles it." A green result below is
-- necessary, not sufficient, evidence that the mitigation works.
-- ----------------------------------------------------------------------

t.test('wellbeingUpdate: source == 65535 (the documented genuine-server sentinel) is processed', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    local belowThreshold = f.env.Config.Wellbeing.Fatigue.speedPenaltyThreshold - 1
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold })
    t.equals(f.recomputeCallCount(), 1, 'a genuinely server-sourced push must be applied -- see this section\'s own D3 scope note above')
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier)
end)

t.test('wellbeingUpdate: a forged local trigger with an arbitrary non-65535 numeric source is rejected outright -- pins the CODE\'s behavior only, D3 remains open regardless (see this section\'s header)', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(1, { fatigue = 0 })
    t.equals(f.recomputeCallCount(), 0, 'must be rejected before ApplyWellbeingSnapshot ever runs -- fatigue = 0 would otherwise trip the penalty')
    t.equals(f.k9MoveRateModifiers.fatigue, 42, 'sentinel must survive untouched')
end)

t.test('wellbeingUpdate: source left nil (a bare local TriggerEvent() carrying no origin at all) is also rejected -- same D3 scope caveat as above', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(nil, { fatigue = 0 })
    t.equals(f.recomputeCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- SECTION E -- "Pet K9" / "Feed K9" (MoodSystem), including the
-- FAIL-CLOSED GUARD around lib.callback.await added the same session this
-- spec was written, and the full NotifyResult reason-label coverage.
-- ----------------------------------------------------------------------

t.test('MoodSystem on: Pet K9/Feed K9 are registered, gated on IsEntityModelK9, and resolve to a real target server id before ever awaiting the server', function()
    local f = newWellbeingFixture({ features = { MoodSystem = true } })
    t.isNotNil(f.petOption())
    t.isNotNil(f.feedOption())

    t.isFalse(f.petOption().canInteract(500), 'canInteract must consult IsEntityModelK9, not just the flag')
    f.setEntityIsK9Model(500, true)
    t.isTrue(f.petOption().canInteract(500))

    -- ResolvePlayerServerIdFromPed returning nil (e.g. a non-player ped)
    -- must abort before ever touching the server.
    f.petOption().onSelect({ entity = 501 })
    t.equals(f.callbackCallCount(), 0)
end)

t.test('Pet K9: success notifies wellbeing.pet_success; every documented rejection reason gets its OWN distinct label, and an unrecognized reason falls back to reason_generic', function()
    local REASON_LABELS = {
        feature_disabled = locale('wellbeing.reason_feature_disabled'),
        invalid_target = locale('wellbeing.reason_invalid_target'),
        too_far = locale('common.too_far_from_k9'),
        on_cooldown = locale('wellbeing.reason_on_cooldown'),
        no_item = locale('wellbeing.reason_no_item'),
    }

    for reason, expectedLabel in pairs(REASON_LABELS) do
        local f = newWellbeingFixture({ features = { MoodSystem = true } })
        f.setEntityIsK9Model(500, true)
        f.setServerIdForPed(500, 42)
        f.queueCallbackResponse({ ok = false, reason = reason })
        f.petOption().onSelect({ entity = 500 })
        t.equals(#f.notifyCalls, 1, ('reason %q must produce exactly one notification'):format(reason))
        t.equals(f.notifyCalls[1].description, expectedLabel, ('reason %q must map to its own documented label'):format(reason))
        t.equals(f.notifyCalls[1].type, 'error')
    end

    local fUnknown = newWellbeingFixture({ features = { MoodSystem = true } })
    fUnknown.setEntityIsK9Model(500, true)
    fUnknown.setServerIdForPed(500, 42)
    fUnknown.queueCallbackResponse({ ok = false, reason = 'a_totally_unrecognized_future_reason' })
    fUnknown.petOption().onSelect({ entity = 500 })
    t.equals(fUnknown.notifyCalls[1].description, locale('wellbeing.reason_generic'))

    local fOk = newWellbeingFixture({ features = { MoodSystem = true } })
    fOk.setEntityIsK9Model(500, true)
    fOk.setServerIdForPed(500, 42)
    fOk.queueCallbackResponse({ ok = true })
    fOk.petOption().onSelect({ entity = 500 })
    t.equals(fOk.notifyCalls[1].description, locale('wellbeing.pet_success'))
    t.equals(fOk.notifyCalls[1].type, 'success')
end)

t.test('Feed K9: shares the SAME reason table as Pet K9, but its own success label (wellbeing.feed_success)', function()
    local f = newWellbeingFixture({ features = { MoodSystem = true } })
    f.setEntityIsK9Model(500, true)
    f.setServerIdForPed(500, 42)
    f.queueCallbackResponse({ ok = true })
    f.feedOption().onSelect({ entity = 500 })
    t.equals(f.notifyCalls[1].description, locale('wellbeing.feed_success'))

    local fDenied = newWellbeingFixture({ features = { MoodSystem = true } })
    fDenied.setEntityIsK9Model(500, true)
    fDenied.setServerIdForPed(500, 42)
    fDenied.queueCallbackResponse({ ok = false, reason = 'no_item' })
    fDenied.feedOption().onSelect({ entity = 500 })
    t.equals(fDenied.notifyCalls[1].description, locale('wellbeing.reason_no_item'))
end)

t.test('FAIL-CLOSED GUARD: lib.callback.await throwing on Pet K9 is caught and degrades to a silent no-op (NotifyResult\'s own "if not result then return" path), never an uncaught error', function()
    local f = newWellbeingFixture({ features = { MoodSystem = true } })
    f.setEntityIsK9Model(500, true)
    f.setServerIdForPed(500, 42)
    f.queueCallbackThrow()
    local ok = pcall(function() f.petOption().onSelect({ entity = 500 }) end)
    t.isTrue(ok, 'a thrown lib.callback.await must never escape the onSelect handler uncaught')
    t.equals(#f.notifyCalls, 0, 'DISCLOSED, DELIBERATE ASYMMETRY vs. client/search.lua: a failed pet/feed round trip degrades SILENTLY here (NotifyResult\'s own `if not result then return end`), unlike client/search.lua\'s catch-all error notify for the same class of failure -- both are defined, non-crashing paths, just different UX choices by design')
end)

-- ----------------------------------------------------------------------
-- SECTION F -- RequestK9CalmDown / k9calmdown (FearStressSystem). A plain
-- resource-global, always registered as a command regardless of the flag
-- (see section A) -- the flag is checked INSIDE the function, at call
-- time.
-- ----------------------------------------------------------------------

t.test('RequestK9CalmDown: FearStressSystem off is a silent no-op -- never even consults CanShowK9UI', function()
    local f = newWellbeingFixture({ canShowK9UI = false }) -- FearStressSystem false
    f.env.RequestK9CalmDown()
    t.equals(f.canShowK9UICallCount(), 0)
    t.equals(f.denyCallCount(), 0)
    t.equals(#f.triggerServerEventCalls, 0)
end)

t.test('RequestK9CalmDown: FearStressSystem on, access denied -> DenyK9UIAccess fires, no server event', function()
    local f = newWellbeingFixture({ features = { FearStressSystem = true }, canShowK9UI = false })
    f.env.RequestK9CalmDown()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.triggerServerEventCalls, 0)
end)

t.test('RequestK9CalmDown: FearStressSystem on, access granted -> triggers calmDownK9 exactly once, and the registered /k9calmdown command IS this same function', function()
    local f = newWellbeingFixture({ features = { FearStressSystem = true } })
    f.env.RequestK9CalmDown()
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:calmDownK9')
    t.equals(#f.triggerServerEventCalls[1].args, 0)

    t.equals(f.command('k9calmdown'), f.env.RequestK9CalmDown, 'the command handler must be the exact same function, not a re-derived copy')
end)

-- ----------------------------------------------------------------------
-- SECTION G -- meat-bait / whistle (DistractionSystem). Deliberately NEVER
-- gated on CanShowK9UI, per this file's own header -- open to any player.
-- ----------------------------------------------------------------------

t.test('DistractionSystem off: neither /k9meatbait nor /k9whistle is registered at all', function()
    local f = newWellbeingFixture() -- DistractionSystem false
    t.isNil(f.command('k9meatbait'))
    t.isNil(f.command('k9whistle'))
end)

t.test('meat-bait/whistle: deliberately UNGATED -- CanShowK9UI is never even consulted, success case notifies distraction_used', function()
    local f = newWellbeingFixture({ features = { DistractionSystem = true }, canShowK9UI = false })
    f.queueCallbackResponse({ ok = true })
    f.command('k9meatbait')()
    t.equals(f.canShowK9UICallCount(), 0, 'this feature is deliberately open to any player, including one CanShowK9UI would deny')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('wellbeing.distraction_used'))
    t.equals(f.notifyCalls[1].type, 'success')
end)

t.test('meat-bait vs. whistle: each item\'s OWN no_item fallback text is distinct, never a shared/hardcoded copy', function()
    local fBait = newWellbeingFixture({ features = { DistractionSystem = true } })
    fBait.queueCallbackResponse({ ok = false, reason = 'no_item' })
    fBait.command('k9meatbait')()
    t.equals(fBait.notifyCalls[1].description, locale('wellbeing.reason_no_meat_bait'))

    local fWhistle = newWellbeingFixture({ features = { DistractionSystem = true } })
    fWhistle.queueCallbackResponse({ ok = false, reason = 'no_item' })
    fWhistle.command('k9whistle')()
    t.equals(fWhistle.notifyCalls[1].description, locale('wellbeing.reason_no_whistle'))
end)

t.test('distraction item use: every documented rejection reason gets a label, and an unrecognized reason falls back to reason_use_generic (never silent)', function()
    local REASON_LABELS = {
        feature_disabled = locale('wellbeing.reason_feature_disabled'),
        invalid_item = locale('wellbeing.reason_invalid_item'),
        invalid_target = locale('wellbeing.reason_use_generic'), -- deliberately shares this file's own generic key, per its own comment
    }
    for reason, expectedLabel in pairs(REASON_LABELS) do
        local f = newWellbeingFixture({ features = { DistractionSystem = true } })
        f.queueCallbackResponse({ ok = false, reason = reason })
        f.command('k9whistle')()
        t.equals(f.notifyCalls[1].description, expectedLabel, ('reason %q'):format(reason))
    end

    local fUnknown = newWellbeingFixture({ features = { DistractionSystem = true } })
    fUnknown.queueCallbackResponse({ ok = false, reason = 'a_totally_unrecognized_future_reason' })
    fUnknown.command('k9whistle')()
    t.equals(fUnknown.notifyCalls[1].description, locale('wellbeing.reason_use_generic'))
end)

t.test('FAIL-CLOSED GUARD: lib.callback.await throwing on a distraction item use is caught and degrades to a silent no-op, never an uncaught error', function()
    local f = newWellbeingFixture({ features = { DistractionSystem = true } })
    f.queueCallbackThrow()
    local ok = pcall(function() f.command('k9meatbait')() end)
    t.isTrue(ok, 'a thrown lib.callback.await must never escape the command handler uncaught')
    t.equals(#f.notifyCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION H -- the on-demand snapshot thread (bonus: cheap given the
-- fixture already built above, exercises the SAME FAIL-CLOSED GUARD
-- pattern from a second, independent call site).
-- ----------------------------------------------------------------------

t.test('on-demand snapshot thread: fetches exactly once on the false->true IsOwnModelK9 transition, not on every idle tick while it stays true', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.stepOne(1) -- prime/first pass: not yet K9
    t.equals(f.callbackCallCount(), 0)

    f.setIsOwnModelK9(true)
    f.queueCallbackResponse({ fatigue = 5 })
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'the fetched snapshot must actually be applied via ApplyWellbeingSnapshot')

    f.stepOne(1) -- still K9 -- must not refetch
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.waitLog[1], 2000)
end)

t.test('on-demand snapshot thread: a thrown lib.callback.await (timeout) is caught -- the thread survives and can fetch again on a later transition', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.setIsOwnModelK9(true)
    f.queueCallbackThrow()
    f.stepOne(1) -- must not kill the coroutine
    t.equals(f.k9MoveRateModifiers.fatigue, 42, 'a thrown/failed fetch must apply nothing')

    f.setIsOwnModelK9(false)
    f.stepOne(1)
    f.setIsOwnModelK9(true)
    f.queueCallbackResponse({ fatigue = 5 })
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 2)
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'the thread must still be alive and able to fetch successfully after the earlier throw')
end)

os.exit(t.summary())
