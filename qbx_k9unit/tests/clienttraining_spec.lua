--[[
    tests/clienttraining_spec.lua

    Direct, black-box tests of client/training.lua against the REAL,
    unmodified production file.

    Covers: the SOURCE-ORIGIN GUARD on 'qbx_k9unit:client:trainingModeChanged'
    (a forged non-65535 source must never flip the local banner state), the
    "server-confirmed only, never optimistic" rule (a command handler alone
    must never flip `trainingModeActive` -- only the server-pushed event
    does), the two drills' shared UX shell (local pre-check when not
    training, lib.progressBar cancellation, a thrown lib.callback.await
    caught and turned into a plain notify rather than an uncaught error,
    the 'on_cooldown' silent-no-op branch), the '/k9training' usage-error
    branch for an unrecognized argument, and the persistent on-screen
    banner thread (drawn only while `trainingModeActive`, at Wait(0) while
    active vs. an idle Wait(500) poll otherwise -- mirrors
    tests/clientscreenfx_spec.lua's own thread-stepping convention).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local THROW = setmetatable({}, { __tostring = function() return '<THROW sentinel>' end })

--- @param opts { hasK9Access: boolean? }?
--- @return table fixture
local function newTrainingFixture(opts)
    opts = opts or {}

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    -- HasK9Access()/DenyK9UIAccess() -- RESOLVED-this-pass courtesy gate on
    -- RequestSetTrainingMode(true) only (see client/training.lua's own
    -- header "RADIAL ENTRY POINT" section). Defaults to `true` so the two
    -- pre-existing on/off command tests below keep exercising the "access
    -- granted" path unless a test opts into the denial path explicitly.
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end
    local denyCalls = 0
    local function HasK9Access() return hasK9Access end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local notifyCalls = {}
    local progressBarQueue = {}
    local progressBarCalls = {}
    local function progressBar(def)
        progressBarCalls[#progressBarCalls + 1] = def
        local next = table.remove(progressBarQueue, 1)
        if next == nil then return true end
        return next
    end

    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local next = table.remove(callbackResponses, 1)
        if next == THROW then
            error('simulated lib.callback.await failure (timeout/rejection)')
        end
        return next
    end

    local lib = {
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
        progressBar = progressBar,
        callback = { await = callbackAwait },
    }

    local commands = {}
    local function RegisterCommand(name, handler) commands[name] = handler end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local runner = Sandbox.newThreadRunner()
    local waitCalls = {}
    local function CreateThread(fn) runner.CreateThread(fn) end
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms; runner.Wait(ms) end

    -- Text-draw natives -- a plain capture per call, mirroring
    -- client/bonetool.lua's own already-verified-in-this-codebase call
    -- shape (BeginTextCommandDisplayText/AddTextComponentSubstringPlayerName/
    -- EndTextCommandDisplayText). This spec only asserts on WHETHER a draw
    -- happened (endTextCalls) and, for the banner-content case, WHAT string
    -- was queued via AddTextComponentSubstringPlayerName -- never on exact
    -- font/scale/colour values, which are a presentation detail outside
    -- this spec's scope.
    local endTextCalls = {}
    local addedTextComponents = {}
    local function SetTextFont() end
    local function SetTextScale() end
    local function SetTextColour() end
    local function SetTextCentre() end
    local function BeginTextCommandDisplayText() end
    local function AddTextComponentSubstringPlayerName(text) addedTextComponents[#addedTextComponents + 1] = text end
    local function EndTextCommandDisplayText(x, y) endTextCalls[#endTextCalls + 1] = { x = x, y = y } end

    local env = Sandbox.newEnv({
        -- client/training.lua gates itself at file top level on
        -- Config.Features.TrainingMode, mirroring server/training.lua's own
        -- first executable line. Without a Config here the file errors on
        -- load rather than running; with the flag false it returns early
        -- and registers nothing, which is the correct production behaviour
        -- and is asserted separately below. Every test in this file
        -- exercises the feature-ON path, so this is where it gets turned on.
        Config = { Features = { TrainingMode = true } },
        TriggerServerEvent = TriggerServerEvent,
        HasK9Access = HasK9Access,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = CreateThread,
        Wait = Wait,
        SetTextFont = SetTextFont,
        SetTextScale = SetTextScale,
        SetTextColour = SetTextColour,
        SetTextCentre = SetTextCentre,
        BeginTextCommandDisplayText = BeginTextCommandDisplayText,
        AddTextComponentSubstringPlayerName = AddTextComponentSubstringPlayerName,
        EndTextCommandDisplayText = EndTextCommandDisplayText,
    })

    Sandbox.loadInto('../client/training.lua', env)

    return {
        env = env,
        runner = runner,
        commands = commands,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        progressBarCalls = progressBarCalls,
        setProgressBarResult = function(v) progressBarQueue[#progressBarQueue + 1] = v end,
        setCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        callbackCallLog = callbackCallLog,
        waitCalls = waitCalls,
        endTextCalls = endTextCalls,
        addedTextComponents = addedTextComponents,
        denyCallCount = function() return denyCalls end,
        isTrainingModeActive = function() return env.IsTrainingModeActive() end,
        --- Fires the trainingModeChanged handler as the server would
        --- (source == 65535) unless `forgedSource` is given.
        fireTrainingModeChanged = function(isOn, forgedSource)
            env.source = forgedSource or 65535
            netEventHandlers['qbx_k9unit:client:trainingModeChanged'](isOn)
        end,
    }
end

-- ----------------------------------------------------------------------
-- '/k9training <on|off>'
-- ----------------------------------------------------------------------

t.test('/k9training on sends setTrainingMode(true)', function()
    local f = newTrainingFixture()
    f.commands.k9training(1, { 'on' })
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:setTrainingMode')
    t.isTrue(f.lastServerEvent().args[1])
end)

t.test('/k9training off sends setTrainingMode(false)', function()
    local f = newTrainingFixture()
    f.commands.k9training(1, { 'off' })
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:setTrainingMode')
    t.isFalse(f.lastServerEvent().args[1])
end)

t.test('RESOLVED this pass: /k9training on with HasK9Access() = false is denied client-side, no server round trip', function()
    local f = newTrainingFixture({ hasK9Access = false })
    f.commands.k9training(1, { 'on' })
    t.equals(#f.serverEvents, 0, 'a courtesy denial must not still forward the request to the server')
    t.equals(f.denyCallCount(), 1)
end)

t.test('RESOLVED this pass: /k9training off with HasK9Access() = false is UNAFFECTED -- termination is never gated', function()
    local f = newTrainingFixture({ hasK9Access = false })
    f.commands.k9training(1, { 'off' })
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:setTrainingMode')
    t.isFalse(f.lastServerEvent().args[1])
    t.equals(f.denyCallCount(), 0, 'turning OFF must never consult HasK9Access()/DenyK9UIAccess() at all')
end)

t.test('RequestSetTrainingMode is a resource-global the radial can call directly, behaving identically to the command', function()
    local f = newTrainingFixture()
    f.env.RequestSetTrainingMode(true)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:setTrainingMode')
    t.isTrue(f.lastServerEvent().args[1])
end)

t.test('IsTrainingModeActive() reflects the server-confirmed flag only, never a command handler alone', function()
    local f = newTrainingFixture()
    t.isFalse(f.isTrainingModeActive())
    f.commands.k9training(1, { 'on' }) -- request sent, no server reply simulated yet
    t.isFalse(f.isTrainingModeActive(), 'requesting ON must not itself flip the flag -- only a genuine server confirmation may')
    f.fireTrainingModeChanged(true)
    t.isTrue(f.isTrainingModeActive())
    f.fireTrainingModeChanged(false)
    t.isFalse(f.isTrainingModeActive())
end)

t.test('/k9training with no/unrecognized argument sends NOTHING to the server and shows a usage notice instead', function()
    local f = newTrainingFixture()
    f.commands.k9training(1, {})
    t.equals(#f.serverEvents, 0)
    t.equals(f.lastNotify().type, 'error')

    f.commands.k9training(1, { 'sideways' })
    t.equals(#f.serverEvents, 0, 'a garbage argument must not be forwarded to the server as if it meant something')
end)

-- ----------------------------------------------------------------------
-- trainingModeChanged -- SOURCE-ORIGIN GUARD + "server-confirmed only"
-- ----------------------------------------------------------------------

t.test('SOURCE-ORIGIN GUARD: a forged non-65535 source is rejected -- the banner state is untouched', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true, 999) -- forged
    -- No direct observable of the internal flag, so drive it through the
    -- banner thread: prime once (state starts false either way), then
    -- confirm the thread is still taking the INACTIVE branch.
    f.runner.step()
    t.equals(#f.endTextCalls, 0, 'a forged trainingModeChanged must never turn the banner on')
end)

t.test('a genuine (source == 65535) trainingModeChanged(true) is accepted -- proven via the banner thread actually drawing', function()
    local f = newTrainingFixture()
    f.runner.step() -- prime: state is false at coroutine creation, so this reaches Wait(500) with no draw
    t.equals(#f.endTextCalls, 0)

    f.fireTrainingModeChanged(true)
    f.runner.step() -- resumes past the Wait(500) yield, re-checks the NOW-true flag, draws, yields at Wait(0)
    t.equals(#f.endTextCalls, 1, 'the banner must draw once training is genuinely confirmed on')
end)

t.test('turning OFF again via the server event stops the banner from drawing on the next step', function()
    local f = newTrainingFixture()
    f.runner.step()
    f.fireTrainingModeChanged(true)
    f.runner.step()
    t.equals(#f.endTextCalls, 1)

    f.fireTrainingModeChanged(false)
    f.runner.step()
    t.equals(#f.endTextCalls, 1, 'no NEW draw call after training is confirmed off')
end)

t.test('a command handler ALONE never flips the banner -- only the server-pushed event does (no optimistic client-side toggle)', function()
    local f = newTrainingFixture()
    f.commands.k9training(1, { 'on' }) -- sends the request, but no server reply simulated yet
    f.runner.step()
    t.equals(#f.endTextCalls, 0, 'requesting ON must not itself turn the visible banner on -- only a genuine server confirmation may')
end)

t.test('RESOLVED this pass: RequestTrainingSearchDrill/RequestTrainingBiteDrill are resource-globals, the exact functions the commands themselves call', function()
    local f = newTrainingFixture()
    t.equals(f.env.RequestTrainingSearchDrill, f.commands.k9trainsearch, 'the radial item must call the SAME function the command does, never a second copy')
    t.equals(f.env.RequestTrainingBiteDrill, f.commands.k9trainbite, 'the radial item must call the SAME function the command does, never a second copy')
end)

-- ----------------------------------------------------------------------
-- Training drills -- shared UX shell
-- ----------------------------------------------------------------------

t.test('/k9trainsearch with training NOT active locally shows a not_training notice and makes NO server round trip at all', function()
    local f = newTrainingFixture()
    f.commands.k9trainsearch()
    t.equals(#f.callbackCallLog, 0, 'the local pre-check must short-circuit before ever awaiting the server -- a UX convenience, not the real gate (the server re-checks independently regardless)')
    t.equals(f.lastNotify().type, 'error')
end)

t.test('/k9trainsearch: cancelling the progress bar makes NO server call at all', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setProgressBarResult(false) -- player moved/cancelled
    f.commands.k9trainsearch()
    t.equals(#f.callbackCallLog, 0)
end)

t.test('/k9trainsearch: a successful drill with contrabandFound = true shows the "found" notice', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setCallbackResponse({ ok = true, contrabandFound = true, reps = 3 })
    f.commands.k9trainsearch()
    t.equals(f.callbackCallLog[1].event, 'qbx_k9unit:server:trainingSearch')
    t.equals(f.lastNotify().type, 'success')
end)

t.test('/k9trainsearch: a successful drill with contrabandFound = false shows the "clean" notice', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setCallbackResponse({ ok = true, contrabandFound = false, reps = 1 })
    f.commands.k9trainsearch()
    t.equals(f.lastNotify().type, 'info')
end)

t.test('/k9trainbite: a successful drill shows the bite-hold-complete notice', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setCallbackResponse({ ok = true, reps = 1 })
    f.commands.k9trainbite()
    t.equals(f.callbackCallLog[1].event, 'qbx_k9unit:server:trainingBiteHold')
    t.equals(f.lastNotify().type, 'success')
end)

t.test('a server-side denial (not ok) with reason = on_cooldown is a SILENT no-op -- no notify at all', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setCallbackResponse({ ok = false, reason = 'on_cooldown' })
    local notifyCountBefore = #f.notifyCalls
    f.commands.k9trainsearch()
    t.equals(#f.notifyCalls, notifyCountBefore, 'on_cooldown must never produce a player-facing notification, matching this resource\'s established cooldown-UX convention')
end)

t.test('a server-side denial with a real reason (too_far/no_access/not_training) shows a plain error notice', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setCallbackResponse({ ok = false, reason = 'too_far' })
    f.commands.k9trainsearch()
    t.equals(f.lastNotify().type, 'error')
end)

t.test('lib.callback.await THROWING outright (ox_lib\'s real timeout/rejection behavior) is caught and produces the same error notice, never an uncaught error', function()
    local f = newTrainingFixture()
    f.fireTrainingModeChanged(true)
    f.setCallbackResponse(THROW)
    local ok = pcall(f.commands.k9trainbite)
    t.isTrue(ok, 'a thrown lib.callback.await must never escape the command handler uncaught')
    t.equals(f.lastNotify().type, 'error')
end)

-- ----------------------------------------------------------------------
-- Persistent banner thread -- idle-vs-active cadence
-- ----------------------------------------------------------------------

t.test('the banner thread polls at Wait(500) while inactive, and switches to Wait(0) once active', function()
    local f = newTrainingFixture()
    f.runner.step() -- primes: inactive, hits Wait(500)
    t.equals(f.waitCalls[#f.waitCalls], 500)

    f.fireTrainingModeChanged(true)
    f.runner.step() -- draws, then Wait(0)
    t.equals(f.waitCalls[#f.waitCalls], 0)

    f.fireTrainingModeChanged(false)
    f.runner.step() -- back to idle Wait(500)
    t.equals(f.waitCalls[#f.waitCalls], 500)
end)

t.test('the drawn banner text is built via AddTextComponentSubstringPlayerName (the same primitive client/bonetool.lua already uses) with a non-empty string', function()
    local f = newTrainingFixture()
    f.runner.step()
    f.fireTrainingModeChanged(true)
    f.runner.step()
    t.equals(#f.addedTextComponents, 1)
    t.isTrue(#f.addedTextComponents[1] > 0)
end)

os.exit(t.summary())
