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
    FEATURE GATE -- FIXED THIS PASS: client/scentlineup.lua used to have NO
    `if not Config.Features.<Name> then return end` gate at all, unlike
    EVERY sibling file in this same batch (client/scenttrail.lua,
    client/sarcalls.lua, client/pursuitsprint.lua, client/defense.lua all
    open with that exact line). It never read `Config` at all, so the
    'qbx_k9unit:client:scentLineupInvite' handler registered
    UNCONDITIONALLY, even when Config.Features.ScentLineup was explicitly
    false server-side. See client/scentlineup.lua's own header, "FEATURE
    GATE -- FIXED THIS PASS", for the full write-up. Section A below pins
    the FIXED behavior (Config.Features.ScentLineup = false registers
    NOTHING at all, matching every sibling file's own "flag off means
    inert, not merely unreachable" convention) -- this spec pins current,
    correct reality, not a bug.
    ======================================================================

    STUBBING EFFORT: minimal, proportionate to a genuinely tiny file. Only
    RegisterNetEvent (captured), lib.alertDialog (controllable response),
    GetPlayerFromServerId/GetPlayerName, and TriggerServerEvent are needed
    -- this file's own header states it calls "no other client file's
    global, at load time or call time" and that claim is exercised
    literally below (no CanShowK9UI/HasK9Access/model natives of any kind
    are provided anywhere in this fixture). `Config.Features.ScentLineup`
    is the one config value this file now reads (see "FEATURE GATE" above)
    -- every fixture below provides it, defaulting to `true` so the
    existing happy-path/edge-case sections keep exercising a live handler
    exactly as before.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { scentLineup: boolean?, config: table? }?
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
    -- See this file's header "FEATURE GATE -- FIXED THIS PASS": this file
    -- now reads Config.Features.ScentLineup before registering anything, so
    -- every fixture provides it -- defaulting to `true` (the feature is on)
    -- so every section below except section A keeps exercising a live
    -- handler exactly as before the fix.
    env.Config = opts.config or { Features = { ScentLineup = opts.scentLineup ~= false } }

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
        netEventCount = function()
            local n = 0
            for _ in pairs(netEventHandlers) do n = n + 1 end
            return n
        end,
        fireInvite = function(forged, fromServerId, inviteWindowMs)
            env.source = forged and 999 or 65535
            local handler = assert(netEventHandlers['qbx_k9unit:client:scentLineupInvite'],
                'client/scentlineup.lua did not register qbx_k9unit:client:scentLineupInvite')
            handler(fromServerId, inviteWindowMs)
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- THE FEATURE GATE, FIXED THIS PASS. See this file's header
-- "FEATURE GATE -- FIXED THIS PASS" for the full write-up this section
-- pins.
-- ----------------------------------------------------------------------

t.test('FIXED: Config.Features.ScentLineup = false registers NO net event at all -- the handler itself never comes into being, matching every sibling file', function()
    local f = newScentLineupFixture({ scentLineup = false })
    t.equals(f.netEventCount(), 0, 'a disabled feature must be inert, not merely unreachable -- no handler should exist to try to reach')
end)

t.test('FIXED: Config.Features.ScentLineup = true registers exactly the scentLineupInvite net event', function()
    local f = newScentLineupFixture()
    t.equals(f.netEventCount(), 1)
    f.registerPlayer(5, 0, 'K9 Officer')
    f.fireInvite(false, 5, 30000)
    t.equals(#f.alertDialogCalls, 1, 'a live, gated-on handler still works exactly as before the fix')
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
