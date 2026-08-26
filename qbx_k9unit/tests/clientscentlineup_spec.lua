--[[
    tests/clientscentlineup_spec.lua

    Direct, black-box tests of client/scentlineup.lua against the REAL,
    unmodified production file -- the client half of Scent Lineup
    (server/scentlineup.lua's own contract). This file's own header
    explains "WHY THIS FILE IS SO SMALL": it registers exactly ONE
    RegisterNetEvent handler ('qbx_k9unit:client:scentLineupInvite') and
    exposes NO resource-global functions at all. This spec drives that one
    handler directly, never reimplementing its dialog logic.

    ======================================================================
    A REAL, DISCLOSED DEFECT THIS SPEC PINS RATHER THAN HIDES (reported to
    main -- see this pass's own report): unlike EVERY sibling file in this
    same batch (client/scenttrail.lua, client/sarcalls.lua,
    client/pursuitsprint.lua, client/defense.lua all open with
    `if not Config.Features.<Name> then return end`), client/scentlineup.lua
    has NO SUCH GATE. It never reads `Config` at all (confirmed by reading
    the whole file). This means the 'qbx_k9unit:client:scentLineupInvite'
    handler is registered UNCONDITIONALLY, even when
    Config.Features.ScentLineup is explicitly false server-side. In
    practice the blast radius is small (server/scentlineup.lua's own
    /k9lineup command independently gates on the same flag before ever
    sending this event, and the handler's own source-origin guard still
    applies), but it is a genuine inconsistency with this resource's
    otherwise-universal "gate at the top of the file" convention, and it
    means a modified client could still pop this dialog to themselves (and
    round-trip a response to the server) even on a server that has the
    feature fully disabled. Section A below pins the file's ACTUAL,
    current behavior (registers regardless of the flag) rather than the
    behavior a reader would expect by analogy with its four siblings --
    this is a spec documenting reality, not a claim that the reality is
    correct. See this suite's own final report for the full write-up.
    ======================================================================

    STUBBING EFFORT: minimal, proportionate to a genuinely tiny file. Only
    RegisterNetEvent (captured), lib.alertDialog (controllable response),
    GetPlayerFromServerId/GetPlayerName, and TriggerServerEvent are needed
    -- this file's own header states it calls "no other client file's
    global, at load time or call time" and that claim is exercised
    literally below (no CanShowK9UI/HasK9Access/model natives of any kind
    are provided anywhere in this fixture).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { config: table?|false }?
local function newScentLineupFixture(opts)
    opts = opts or {}

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local threadCount = 0
    local function CreateThread(_fn) threadCount = threadCount + 1 end

    local playerIndexByServerId = {}
    local playerNameByIndex = {}
    local function GetPlayerFromServerId(serverId) return playerIndexByServerId[serverId] or -1 end
    local function GetPlayerName(playerIndex) return playerNameByIndex[playerIndex] end

    local alertDialogCalls = {}
    local alertDialogResponse = 'confirm'
    local lib = {
        alertDialog = function(payload)
            alertDialogCalls[#alertDialogCalls + 1] = payload
            return alertDialogResponse
        end,
    }

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local overrides = {
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CreateThread,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerName = GetPlayerName,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        source = 65535,
    }

    local env = Sandbox.newEnv(overrides)
    if opts.config ~= false then
        -- Deliberately provided (even set to a hostile `false`) to prove
        -- section A's finding: this file never even LOOKS at it.
        env.Config = opts.config or { Features = { ScentLineup = false } }
    end

    Sandbox.loadInto('../client/scentlineup.lua', env)

    return {
        env = env,
        threadCount = function() return threadCount end,
        alertDialogCalls = alertDialogCalls,
        setAlertDialogResponse = function(v) alertDialogResponse = v end,
        serverEvents = serverEvents,
        registerPlayer = function(serverId, playerIndex, name)
            playerIndexByServerId[serverId] = playerIndex
            playerNameByIndex[playerIndex] = name
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireInvite = function(forged, fromServerId, inviteWindowMs)
            env.source = forged and 999 or 65535
            local handler = assert(netEventHandlers['qbx_k9unit:client:scentLineupInvite'],
                'client/scentlineup.lua did not register qbx_k9unit:client:scentLineupInvite')
            handler(fromServerId, inviteWindowMs)
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- THE DISCLOSED DEFECT: no Config.Features gate at all.
-- ----------------------------------------------------------------------

t.test('DEFECT, PINNED NOT HIDDEN: the invite handler registers even with Config.Features.ScentLineup explicitly false -- unlike every sibling file in this batch', function()
    local f = newScentLineupFixture({ config = { Features = { ScentLineup = false } } })
    f.registerPlayer(5, 0, 'K9 Officer')
    f.fireInvite(false, 5, 30000)
    t.equals(#f.alertDialogCalls, 1, 'the handler ran fully despite the feature flag being false -- this file never reads Config at all')
end)

t.test('DEFECT, PINNED NOT HIDDEN: the invite handler registers even with Config entirely ABSENT from the sandbox -- this file has no load-order dependency on Config whatsoever', function()
    local f = newScentLineupFixture({ config = false })
    t.isNil(f.env.Config)
    f.registerPlayer(5, 0, 'K9 Officer')
    f.fireInvite(false, 5, 30000)
    t.equals(#f.alertDialogCalls, 1)
end)

t.test('lifecycle: no thread, and no onResourceStop handler, is ever registered by this file -- matches its own "WHY THIS FILE IS SO SMALL" header claim', function()
    local f = newScentLineupFixture()
    t.equals(f.threadCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

-- ----------------------------------------------------------------------
-- SECTION B -- source-origin guard and input validation.
-- ----------------------------------------------------------------------

t.test('a forged (non-65535 source) invite push is rejected outright -- no dialog, no server round trip', function()
    local f = newScentLineupFixture()
    f.registerPlayer(5, 0, 'K9 Officer')
    f.fireInvite(true, 5, 30000)
    t.equals(#f.alertDialogCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('a non-number fromServerId is rejected before ever showing a dialog (input edge case)', function()
    local f = newScentLineupFixture()
    f.fireInvite(false, 'not-a-number', 30000)
    t.equals(#f.alertDialogCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('a nil fromServerId is rejected the same way', function()
    local f = newScentLineupFixture()
    f.fireInvite(false, nil, 30000)
    t.equals(#f.alertDialogCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION C -- happy path: name resolution, countdown formatting, and
-- both possible answers.
-- ----------------------------------------------------------------------

t.test('a resolvable fromServerId shows the real player name and the correct floor(inviteWindowMs/1000) countdown in the dialog content', function()
    local f = newScentLineupFixture()
    f.registerPlayer(7, 2, 'Officer Rex')
    f.fireInvite(false, 7, 45500) -- floor(45500/1000) = 45
    t.equals(#f.alertDialogCalls, 1)
    t.equals(f.alertDialogCalls[1].header, locale('scentlineup.invite_header'))
    t.equals(f.alertDialogCalls[1].content, locale('scentlineup.invite_received', 'Officer Rex', 45))
end)

t.test('an UNRESOLVABLE fromServerId (GetPlayerFromServerId returns -1) falls back to the shared officer_fallback_name locale key, formatted with the numeric id', function()
    local f = newScentLineupFixture()
    -- Deliberately never registered -- GetPlayerFromServerId returns -1.
    f.fireInvite(false, 99, 30000)
    t.equals(f.alertDialogCalls[1].content, locale('scentlineup.invite_received', locale('movement.officer_fallback_name', 99), 30))
end)

t.test('a missing inviteWindowMs defaults to 30 seconds in the shown countdown (production own tonumber(...) or 30000 fallback)', function()
    local f = newScentLineupFixture()
    f.registerPlayer(5, 0, 'K9 Officer')
    f.fireInvite(false, 5, nil)
    t.equals(f.alertDialogCalls[1].content, locale('scentlineup.invite_received', 'K9 Officer', 30))
end)

t.test('ACCEPT: a confirm response sends respondScentLineupInvite with accepted = true and the original fromServerId', function()
    local f = newScentLineupFixture()
    f.registerPlayer(5, 0, 'K9 Officer')
    f.setAlertDialogResponse('confirm')
    f.fireInvite(false, 5, 30000)
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:respondScentLineupInvite')
    t.equals(f.serverEvents[1].args[1], 5)
    t.equals(f.serverEvents[1].args[2], true)
end)

t.test('DECLINE: any non-confirm response (e.g. cancel) sends respondScentLineupInvite with accepted = false', function()
    local f = newScentLineupFixture()
    f.registerPlayer(5, 0, 'K9 Officer')
    f.setAlertDialogResponse('cancel')
    f.fireInvite(false, 5, 30000)
    t.equals(f.serverEvents[1].args[2], false)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- double-fire / independence: no shared mutable session state
-- to leak between two separate, back-to-back invites.
-- ----------------------------------------------------------------------

t.test('two rapid, independent invites from DIFFERENT senders each produce their own correctly-addressed dialog and response, never cross-contaminated', function()
    local f = newScentLineupFixture()
    f.registerPlayer(1, 0, 'Officer One')
    f.registerPlayer(2, 1, 'Officer Two')

    f.setAlertDialogResponse('confirm')
    f.fireInvite(false, 1, 10000)
    f.setAlertDialogResponse('cancel')
    f.fireInvite(false, 2, 10000)

    t.equals(#f.serverEvents, 2)
    t.equals(f.serverEvents[1].args[1], 1)
    t.equals(f.serverEvents[1].args[2], true)
    t.equals(f.serverEvents[2].args[1], 2)
    t.equals(f.serverEvents[2].args[2], false)
    t.equals(f.alertDialogCalls[1].content, locale('scentlineup.invite_received', 'Officer One', 10))
    t.equals(f.alertDialogCalls[2].content, locale('scentlineup.invite_received', 'Officer Two', 10))
end)

t.test('the SAME sender inviting twice in a row (e.g. a re-sent invite after a first was ignored) is handled independently each time, not deduplicated or merged', function()
    local f = newScentLineupFixture()
    f.registerPlayer(5, 0, 'K9 Officer')
    f.setAlertDialogResponse('confirm')
    f.fireInvite(false, 5, 10000)
    f.fireInvite(false, 5, 10000)
    t.equals(#f.alertDialogCalls, 2)
    t.equals(#f.serverEvents, 2)
end)

-- ----------------------------------------------------------------------
-- WHAT THIS FILE DOES NOT COVER, AND WHY:
--
-- 1. "ANY PED" gating: this file has NO gating of any kind beyond the
--    source-origin guard -- it is the INVITEE side of the interaction, not
--    the conductor side, and the conductor's own eligibility
--    (CanShowK9UI/HasK9Access) is entirely server/scentlineup.lua's
--    concern (that file's own /k9lineup command handler, not this one).
--    There is no model/role check here to widen or narrow, so no "any
--    ped" test applies to this file -- disclosed here rather than silently
--    omitted.
-- 2. Termination/cleanup: this file has no session state, no thread, and
--    no onResourceStop handler at all (confirmed above) -- there is
--    nothing for a disconnect, resource restart, or the inviting player
--    vanishing to clean up on THIS side. A disconnect mid-dialog is
--    handled entirely by FiveM's own NUI/dialog teardown on player
--    disconnect, outside this file's own code.
-- 3. Re-entrancy/concurrency of a SINGLE invite's own lib.alertDialog call
--    (e.g. what happens if the SAME invite's dialog is somehow shown
--    twice concurrently) is not modelled -- lib.alertDialog is a real
--    ox_lib primitive this resource does not own, and this file's own
--    logic around one call is a single, straight-line request/response
--    with no state that could meaningfully race against itself.
-- ----------------------------------------------------------------------

os.exit(t.summary())
