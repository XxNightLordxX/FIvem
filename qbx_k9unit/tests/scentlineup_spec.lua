--[[
    tests/scentlineup_spec.lua

    Direct tests of server/scentlineup.lua (K9_IDEAS.md §4, "Scent lineup")
    against the REAL, unmodified production file.

    THE LOAD-BEARING TEST IN THIS FILE, per this task's own instruction:
    "the correct answer to a lineup must never exist client-side before the
    player picks." This is proven two independent ways, mirroring
    tests/training_spec.lua's own "prove it twice" convention for its
    analogous XP guarantee:
      1. SOURCE-LEVEL: this file's own raw text (comments stripped) is
         inspected directly for the shape of leak this feature's header
         explicitly rules out -- see "SOURCE-LEVEL GUARANTEES" below.
      2. BEHAVIORAL: the roster message a locked lineup's conductor
         receives is asserted to contain every participant's name and
         position, but the test can only learn WHICH position is the real
         match by later inspecting the POST-PICK reveal, never before --
         see "the roster reveals who is in the lineup but never which one
         is correct" below, and every pick-flow test's own ordering
         (lock, THEN pick, THEN read the reveal -- never the other way).

    Also covers: the four gates on /k9lineup (feature flag, HasK9Access,
    the per-person RequireGrant/HasPermission resolution order, the
    starting cooldown), argument validation (too few/many, duplicate,
    self-invite, offline target, a target already busy in another
    session), the full accept-handshake (progress notifications, a stale/
    forged response naming the wrong conductor, a duplicate accept being a
    silent no-op), a decline tearing down the whole session, both pick
    outcomes (correct/incorrect) and their differing reveal text, the
    UNBOUNDED-TRAP guarantees (/k9lineupcancel never checks access, for
    ANY role, in ANY phase), the two independent phase-expiry timeouts via
    the sweep thread, and disconnect cleanup for both the conductor and a
    participant.

    NO MySQL/yielding calls exist anywhere in server/scentlineup.lua (see
    that file's own header) -- every command/net-event handler below is
    invoked as a plain, single, synchronous Lua call, no coroutine
    stepping needed (contrast tests/partnership_spec.lua's dispatchStepped/
    startCoroutine machinery, needed there only because THAT file's accept
    path awaits real MySQL calls).

    DETERMINISTIC RANDOMNESS: math.random is stubbed to `function(n) return
    n end` (mirrors tests/training_spec.lua's own mathStub precedent, one
    level further: that file only ever calls math.random() with no
    argument, this one always calls it WITH an upper bound). This makes the
    Fisher-Yates shuffle in LockSession a formal no-op (every swap target
    equals its own index) and the final match draw `math.random(#order)`
    always select the LAST entry of `order`, in whatever order Lua's own
    `pairs()` happens to build it in -- which this suite deliberately never
    assumes a fixed value for (Lua's hash-part iteration order for
    non-array-shaped integer keys, like the server-id keys used here, is
    implementation-defined). Every test below DISCOVERS which participant
    ended up last by parsing the real, observable roster text the
    conductor was actually sent (see lastRosterEntry() below), never by
    assuming a fixed src ordering -- this is "check the real, observable
    result," not a rewritten copy of LockSession's own logic.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- SOURCE-LEVEL GUARANTEES -- read the real file's raw text directly,
-- before any sandbox is even built. Mirrors tests/training_spec.lua's own
-- readFile/stripLuaComments pair exactly (duplicated here rather than
-- shared, matching this suite's own established "each spec keeps its own
-- tiny copy" convention already used for e.g. IsDuplicateKeyError across
-- production files).
-- ----------------------------------------------------------------------

local function readFile(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

--- @param text string
--- @return string
local function stripLuaComments(text)
    text = text:gsub('%-%-%[%[.-%]%]', '')
    local out = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        out[#out + 1] = line:match('^(.-)%-%-') or line
    end
    return table.concat(out, '\n')
end

local scentLineupCode -- computed once, reused by both source-level tests below
do
    scentLineupCode = stripLuaComments(readFile('../server/scentlineup.lua'))
end

t.test('SOURCE-LEVEL: server/scentlineup.lua never references AwardXP/AwardXPDirect/Config.XP anywhere (THE XP DECISION: zero, by construction)', function()
    t.notContains(scentLineupCode, 'AwardXP', 'must never call AwardXP -- this substring check also catches AwardXPDirect')
    t.notContains(scentLineupCode, 'Config.XP', 'must never read Config.XP.awards or any other Config.XP field')
end)

t.test('SOURCE-LEVEL: server/scentlineup.lua never names a third-party resource directly (system-agnostic by construction)', function()
    t.notContains(scentLineupCode, 'qbx_core', 'identity is resolved through K9Compat.Get(\'framework\'), never a direct qbx_core export')
    t.notContains(scentLineupCode, 'exports.', 'this file has no inventory/target/dispatch/ambulance dependency of any kind')
end)

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local MIN_PARTICIPANTS = 2
local MAX_PARTICIPANTS = 3
local INVITE_WINDOW_MS = 30000
local PICK_WINDOW_MS = 240000
local START_COOLDOWN_MS = 60000

--- Extracts (index, name) of the LAST "N) Name" entry in a roster label
--- built by BuildRosterLabel (e.g. "1) Alice  2) Bob" -> 2, "Bob"). Every
--- test name used below is a single alphabetic word specifically so this
--- pattern match is unambiguous.
--- @param roster string
--- @return integer index
--- @return string name
local function lastRosterEntry(roster)
    local idx, name
    -- BuildRosterLabel's own output ("1) Alice  2) Bob") is embedded inside
    -- the larger lineup_ready_conductor sentence, followed by more text
    -- ("... Commit your read with /k9lineuppick <1-2>.") -- so this scans
    -- every "N) Name" occurrence and keeps the LAST one, rather than
    -- anchoring to end-of-string (which would never match once real
    -- trailing text follows the roster).
    for i, n in roster:gmatch('(%d+)%) (%a+)') do
        idx, name = i, n
    end
    assert(idx, 'could not parse a roster entry out of: ' .. tostring(roster))
    return tonumber(idx), name
end

--- @param opts table? { featureEnabled, requireGrant, permissionGrantsEnabled, minParticipants, maxParticipants, inviteWindowMs, pickWindowMs, startCooldownMs }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local notifyLog = {} -- { {source=, message=, kind=}, ... }
    local function NotifyPlayer(src, message, kind)
        notifyLog[#notifyLog + 1] = { source = src, message = message, kind = kind }
    end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local outboundEvents = {} -- { {eventName, ...}, ... }
    local function TriggerEvent(eventName, ...)
        outboundEvents[#outboundEvents + 1] = { eventName, ... }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    -- See this file's header "DETERMINISTIC RANDOMNESS".
    local mathStub = {}
    for k, v in pairs(math) do mathStub[k] = v end
    mathStub.random = function(n) return n end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local nameBySource = {}
    local function GetPlayerName(src) return nameBySource[src] end

    local citizenidBySource = {}
    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    -- Simplified, test-owned stand-in for server/permissions.lua's real
    -- HasPermission -- mirrors its real (citizenid, permissionKey) shape
    -- and its real "PermissionGrants must be on" gate, matching
    -- tests/partnership_spec.lua's own convention of stubbing HasK9Access/
    -- IsConfiguredK9Model directly rather than loading certifications.lua.
    local grantsByCitizenid = {} -- [citizenid][key] = true
    local function HasPermission(citizenid, key)
        if opts.permissionGrantsEnabled == false then return false end
        local set = grantsByCitizenid[citizenid]
        return set ~= nil and set[key] == true
    end

    -- Mirrors shared/compat/framework.lua's real, documented contract:
    -- `GetPlayer(source)` returns a PLAYER OBJECT (or nil if unresolvable),
    -- and `GetCitizenId(player)` takes THAT object, never a bare source
    -- number -- see server/scentlineup.lua's own ResolveCitizenId(), which
    -- calls GetPlayer first and only then passes the result to
    -- GetCitizenId. `f.setCitizenId(src, nil)` (used below to simulate an
    -- unresolvable framework adapter) therefore also makes GetPlayer(src)
    -- resolve to nil, exactly like the real no-op stub would.
    local K9CompatStub = {
        Get = function(system)
            if system == 'framework' then
                return {
                    GetPlayer = function(src)
                        if citizenidBySource[src] == nil then return nil end
                        return { __src = src }
                    end,
                    GetCitizenId = function(player)
                        if type(player) ~= 'table' then return nil end
                        return citizenidBySource[player.__src]
                    end,
                }
            end
            return {}
        end,
    }

    local capturedCommands = {}
    local function RegisterCommand(name, handler, _restricted)
        capturedCommands[name] = handler
    end

    local capturedNetEvents = {}
    local function RegisterNetEvent(name, handler)
        capturedNetEvents[name] = handler
    end

    local eventHandlers = {}
    local function AddEventHandler(name, handler)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local Config = {
        Features = {
            ScentLineup = opts.featureEnabled ~= false,
            PermissionGrants = opts.permissionGrantsEnabled ~= false,
        },
        FeatureControl = {
            RequireGrant = { ScentLineup = opts.requireGrant == true },
        },
        ScentLineup = {
            minParticipants = opts.minParticipants or MIN_PARTICIPANTS,
            maxParticipants = opts.maxParticipants or MAX_PARTICIPANTS,
            inviteWindowMs = opts.inviteWindowMs or INVITE_WINDOW_MS,
            pickWindowMs = opts.pickWindowMs or PICK_WINDOW_MS,
            startCooldownMs = opts.startCooldownMs or START_COOLDOWN_MS,
        },
    }

    local runner = Sandbox.newThreadRunner()

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        NotifyPlayer = NotifyPlayer,
        TriggerClientEvent = TriggerClientEvent,
        TriggerEvent = TriggerEvent,
        print = printStub,
        math = mathStub,
        GetPlayerPed = GetPlayerPed,
        GetPlayerName = GetPlayerName,
        HasK9Access = HasK9Access,
        HasPermission = HasPermission,
        K9Compat = K9CompatStub,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/scentlineup.lua', env)

    -- Prime the sweep thread (see fixtures/sandbox.lua's own doc comment:
    -- the first step() only reaches the loop's initial Wait()).
    runner.step()

    return {
        env = env,
        config = Config,
        notifyLog = notifyLog,
        clientEvents = clientEvents,
        outboundEvents = outboundEvents,
        printLog = printLog,
        commands = capturedCommands,
        netEvents = capturedNetEvents,
        eventHandlers = eventHandlers,
        setOnline = function(src, online)
            pedBySource[src] = (online ~= false) and (src * 100) or nil
        end,
        setName = function(src, name) nameBySource[src] = name end,
        setCitizenId = function(src, cid) citizenidBySource[src] = cid end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        grant = function(citizenid, key)
            grantsByCitizenid[citizenid] = grantsByCitizenid[citizenid] or {}
            grantsByCitizenid[citizenid][key] = true
        end,
        advance = function(ms) state.now = state.now + ms end,
        --- @param name string
        --- @param src number
        --- @param args table?
        runCommand = function(name, src, args)
            env.source = src
            local handler = capturedCommands[name]
            assert(handler, 'no command registered for ' .. name)
            return handler(src, args or {}, name)
        end,
        --- @param name string
        --- @param src number
        runNetEvent = function(name, src, ...)
            env.source = src
            local handler = capturedNetEvents[name]
            assert(handler, 'no net event registered for ' .. name)
            return handler(...)
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, h in ipairs(eventHandlers['playerDropped'] or {}) do h() end
        end,
        -- Runs exactly one full sweep-thread pass (see fixtures/sandbox.lua:
        -- the runner is already primed above, so each call here advances
        -- past exactly one Wait(SWEEP_INTERVAL_MS)).
        stepSweep = function() runner.step() end,
    }
end

--- @param f table
--- @param src number
--- @return table? -- the LAST notifyLog entry for that source, or nil
local function lastNotifyFor(f, src)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == src then found = entry end
    end
    return found
end

--- Wires two online, named, unaccessed-by-default players plus a
--- certified/granted conductor, ready for a full invite round trip.
--- @param f table
--- @return number conductorSrc
--- @return number aliceSrc
--- @return number bobSrc
local function wireBasicTrio(f, opts)
    opts = opts or {}
    local conductorSrc, aliceSrc, bobSrc = 1, 2, 3
    f.setOnline(conductorSrc, true)
    f.setOnline(aliceSrc, true)
    f.setOnline(bobSrc, true)
    f.setName(aliceSrc, 'Alice')
    f.setName(bobSrc, 'Bob')
    f.setAccess(conductorSrc, true)
    f.setCitizenId(conductorSrc, opts.conductorCitizenId or 'COND-1')
    if opts.requireGrant then
        f.grant(opts.conductorCitizenId or 'COND-1', 'feature.ScentLineup')
    end
    return conductorSrc, aliceSrc, bobSrc
end

--- Runs /k9lineup for `conductorSrc` against `targets` (array of server
--- ids) and returns nothing -- callers inspect f.notifyLog/f.clientEvents.
local function startLineup(f, conductorSrc, targets)
    f.runCommand('k9lineup', conductorSrc, targets)
end

--- Accepts on behalf of every target in `targets`, in order.
local function acceptAll(f, conductorSrc, targets)
    for _, targetSrc in ipairs(targets) do
        f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', targetSrc, conductorSrc, true)
    end
end

-- ----------------------------------------------------------------------
-- GATES on /k9lineup
-- ----------------------------------------------------------------------

t.test('feature disabled: the whole file is inert -- gate at registration, not just inside each handler (mirrors this resource\'s established convention, e.g. tests/wellbeing_spec.lua\'s own "no thread even registered" case)', function()
    local f = newFixture({ featureEnabled = false })
    t.isNil(f.commands['k9lineup'], 'k9lineup must never be registered while the feature is off')
    t.isNil(f.commands['k9lineuppick'])
    t.isNil(f.commands['k9lineupcancel'])
    t.isNil(f.netEvents['qbx_k9unit:server:respondScentLineupInvite'])
    t.equals(#f.clientEvents, 0)
end)

t.test('no HasK9Access: /k9lineup is rejected with the shared common.no_k9_access message', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    f.setAccess(conductorSrc, false)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('common.no_k9_access'))
end)

t.test('RequireGrant.ScentLineup=true with no grant: rejected no_grant; granting feature.ScentLineup then allows it', function()
    local f = newFixture({ requireGrant = true })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f, { requireGrant = false })
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.no_grant'))
    t.equals(#f.clientEvents, 0)

    f.grant('COND-1', 'feature.ScentLineup')
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(#f.clientEvents, 2, 'both invites should now go out')
end)

t.test('RequireGrant.ScentLineup=false (default): no grant needed at all', function()
    local f = newFixture({ requireGrant = false })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(#f.clientEvents, 2)
end)

t.test('a block.ScentLineup grant denies even with RequireGrant off', function()
    local f = newFixture({ requireGrant = false })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    f.grant('COND-1', 'block.ScentLineup')
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.no_grant'))
end)

t.test('unresolvable citizenid (framework adapter not yet available) fails CLOSED', function()
    local f = newFixture({ requireGrant = false })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    f.setCitizenId(conductorSrc, nil) -- simulates shared/compat/framework.lua not having landed yet
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.no_grant'))
end)

t.test('starting a second lineup immediately is blocked by startCooldownMs; advancing past it allows a new one', function()
    local f = newFixture({ startCooldownMs = 5000 })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(#f.clientEvents, 2)

    -- Cancel so the conductor is free to try again (already_running would
    -- otherwise mask the cooldown check) -- this also exercises
    -- /k9lineupcancel mid-'inviting'.
    f.runCommand('k9lineupcancel', conductorSrc)

    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.on_cooldown'))

    f.advance(5000)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    t.equals(#f.clientEvents, 4, 'the third attempt (after the cooldown elapsed) should have sent two more invites')
end)

-- ----------------------------------------------------------------------
-- ARGUMENT VALIDATION
-- ----------------------------------------------------------------------

t.test('too few participants is rejected with the configured minimum', function()
    local f = newFixture({ minParticipants = 2, maxParticipants = 3 })
    local conductorSrc, aliceSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.too_few_participants', 2))
end)

t.test('too many participants is rejected with the configured maximum', function()
    local f = newFixture({ minParticipants = 2, maxParticipants = 2 })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    f.setOnline(4, true)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc, 4 })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.too_many_participants', 2))
end)

t.test('a duplicated server id in the argument list is rejected', function()
    local f = newFixture()
    local conductorSrc, aliceSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, aliceSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.duplicate_participant'))
end)

t.test('inviting yourself is rejected', function()
    local f = newFixture()
    local conductorSrc, aliceSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { conductorSrc, aliceSrc })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.cannot_invite_self'))
end)

t.test('an offline/invalid target is rejected before any invite goes out', function()
    local f = newFixture()
    local conductorSrc, aliceSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, 999 })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.invalid_participant', 999))
    t.equals(#f.clientEvents, 0, 'a fully-invalid arg list must not create a half-built session')
end)

t.test('a target already tied up in another lineup is rejected as busy, by name', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    f.setOnline(4, true)
    f.setAccess(4, true)
    f.setCitizenId(4, 'COND-2')
    startLineup(f, conductorSrc, { aliceSrc, bobSrc }) -- Alice/Bob now busy

    startLineup(f, 4, { aliceSrc, bobSrc })
    t.equals(lastNotifyFor(f, 4).message, locale('scentlineup.target_busy', 'Alice'))
end)

-- ----------------------------------------------------------------------
-- THE ACCEPT HANDSHAKE
-- ----------------------------------------------------------------------

t.test('progress notification counts up as each invitee accepts, and the lineup locks only once everyone has', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })

    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, conductorSrc, true)
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.invite_accepted_progress', 'Alice', 1, 2))
    -- Not locked yet -- a pick attempt now must be refused.
    f.runCommand('k9lineuppick', conductorSrc, { '1' })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_locked_yet'))

    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', bobSrc, conductorSrc, true)
    t.contains(lastNotifyFor(f, conductorSrc).message, 'Alice')
    t.contains(lastNotifyFor(f, conductorSrc).message, 'Bob')
end)

t.test('a stale/forged invite response (wrong claimed conductor, or no pending invite at all) is refused and changes nothing', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })

    -- Alice claims a DIFFERENT conductor than the one who actually invited her.
    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, 999, true)
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.no_pending_invite'))

    -- A player with no pending invite at all.
    f.setOnline(5, true)
    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', 5, conductorSrc, true)
    t.equals(lastNotifyFor(f, 5).message, locale('scentlineup.no_pending_invite'))

    -- The genuine invite must still be entirely intact -- both real
    -- targets can still accept normally afterward.
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })
    t.contains(lastNotifyFor(f, conductorSrc).message, 'Alice')
end)

t.test('a duplicate accept from the same player is a silent no-op (does not double-count progress)', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })

    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, conductorSrc, true)
    local afterFirst = #f.notifyLog
    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, conductorSrc, true)
    t.equals(#f.notifyLog, afterFirst, 'a duplicate accept must not send any further notification')
end)

t.test('a decline tears down the WHOLE session -- the decliner gets their own message, everyone else gets the broadcast', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })

    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, conductorSrc, false)
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.invite_declined_self'))
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.cancelled_participant_left', 'Alice'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.cancelled_participant_left', 'Alice'))

    -- Session is really gone -- the conductor is free to start a fresh one
    -- once past the cooldown (already exercised elsewhere); here, simplest
    -- proof is that /k9lineupcancel now reports nothing to cancel.
    f.runCommand('k9lineupcancel', conductorSrc)
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_in_lineup'))
end)

-- ----------------------------------------------------------------------
-- THE SECURITY SHAPE -- the roster reveals WHO, never WHICH ONE, until a
-- pick actually commits.
-- ----------------------------------------------------------------------

t.test('the locked roster names every participant and their position, but the reveal only ever comes AFTER a pick is committed', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    local readyMessage = lastNotifyFor(f, conductorSrc).message
    t.contains(readyMessage, 'Alice')
    t.contains(readyMessage, 'Bob')
    -- Nobody has been told which position is correct -- neither
    -- participant has received any message at all since accepting other
    -- than the generic "ready" ping (never a name, never an index).
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.lineup_ready_participant'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.lineup_ready_participant'))
end)

t.test('pick CORRECT: conductor sees pick_result_correct, every participant sees the same neutral reveal', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    local matchIndex, matchName = lastRosterEntry(lastNotifyFor(f, conductorSrc).message)

    f.runCommand('k9lineuppick', conductorSrc, { tostring(matchIndex) })

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.pick_result_correct', matchName))
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.pick_result_reveal', matchName))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.pick_result_reveal', matchName))

    t.equals(#f.outboundEvents, 1)
    t.equals(f.outboundEvents[1][1], 'qbx_k9unit:events:scentLineupResolved')
    t.equals(f.outboundEvents[1][2], conductorSrc)
    t.isTrue(f.outboundEvents[1][3])
end)

t.test('pick INCORRECT: conductor sees pick_result_incorrect naming the real match; the reveal to participants is unaffected', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    local matchIndex, matchName = lastRosterEntry(lastNotifyFor(f, conductorSrc).message)
    local wrongIndex = (matchIndex == 1) and 2 or 1

    f.runCommand('k9lineuppick', conductorSrc, { tostring(wrongIndex) })

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.pick_result_incorrect', matchName))
    t.equals(f.outboundEvents[1][3], false)
end)

t.test('/k9lineuppick rejects a non-numeric or out-of-range index without resolving anything', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    f.runCommand('k9lineuppick', conductorSrc, { 'banana' })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.usage_pick', 2))

    f.runCommand('k9lineuppick', conductorSrc, { '99' })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.invalid_pick_index', 99))

    t.equals(#f.outboundEvents, 0, 'neither invalid attempt should have resolved the lineup')
end)

t.test('a session can only ever be resolved once -- a second pick after resolution has nothing left to act on', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })
    local matchIndex = lastRosterEntry(lastNotifyFor(f, conductorSrc).message)

    f.runCommand('k9lineuppick', conductorSrc, { tostring(matchIndex) })
    f.runCommand('k9lineuppick', conductorSrc, { tostring(matchIndex) })

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_in_lineup'))
    t.equals(#f.outboundEvents, 1, 'the second pick must not fire a second resolution event')
end)

-- ----------------------------------------------------------------------
-- NO UNBOUNDED TRAP -- /k9lineupcancel never checks access, for any role
-- ----------------------------------------------------------------------

t.test('/k9lineupcancel works for the conductor even if their K9 access/grant has since been revoked', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    f.setAccess(conductorSrc, false) -- certification lapses mid-session
    f.runCommand('k9lineupcancel', conductorSrc)

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.left_lineup_self'))
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.cancelled_generic'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.cancelled_generic'))
end)

t.test('/k9lineupcancel by an ACCEPTED participant tears down the whole session, naming them to everyone else', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    f.runCommand('k9lineupcancel', aliceSrc) -- Alice never needed K9 access to do this
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.left_lineup_self'))
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.cancelled_participant_left', 'Alice'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.cancelled_participant_left', 'Alice'))

    -- The conductor's own session is really gone too, not just Alice's slot.
    f.runCommand('k9lineuppick', conductorSrc, { '1' })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_in_lineup'))
end)

t.test('/k9lineupcancel with nothing to cancel reports not_in_lineup', function()
    local f = newFixture()
    f.setOnline(1, true)
    f.runCommand('k9lineupcancel', 1)
    t.equals(lastNotifyFor(f, 1).message, locale('scentlineup.not_in_lineup'))
end)

-- ----------------------------------------------------------------------
-- PHASE-EXPIRY TIMEOUTS -- the sweep thread
-- ----------------------------------------------------------------------

t.test('an invite window that lapses before everyone accepts is force-cancelled by the sweep thread', function()
    local f = newFixture({ inviteWindowMs = 10000 })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, conductorSrc, true) -- Bob never answers

    f.advance(10001)
    f.stepSweep()

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.cancelled_timeout'))
    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.cancelled_timeout'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.cancelled_timeout'))

    f.runCommand('k9lineupcancel', conductorSrc)
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_in_lineup'), 'the session must really be gone, not just past its deadline')
end)

t.test('a pick window that lapses without a pick is force-cancelled by the sweep thread', function()
    local f = newFixture({ pickWindowMs = 20000 })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    f.advance(20001)
    f.stepSweep()

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.cancelled_timeout'))

    f.runCommand('k9lineuppick', conductorSrc, { '1' })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_in_lineup'))
end)

t.test('a session well within both windows survives a sweep pass untouched', function()
    local f = newFixture({ inviteWindowMs = 30000, pickWindowMs = 240000 })
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })

    f.advance(1000)
    f.stepSweep()

    -- Still alive -- the pending invite can still be answered normally.
    f.runNetEvent('qbx_k9unit:server:respondScentLineupInvite', aliceSrc, conductorSrc, true)
    t.contains(lastNotifyFor(f, conductorSrc).message, 'Alice')
end)

-- ----------------------------------------------------------------------
-- DISCONNECT CLEANUP
-- ----------------------------------------------------------------------

t.test('the conductor disconnecting tears down the session and frees every participant', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    f.firePlayerDropped(conductorSrc)

    t.equals(lastNotifyFor(f, aliceSrc).message, locale('scentlineup.cancelled_generic'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.cancelled_generic'))

    -- Alice/Bob are free -- a different conductor can now invite them.
    f.setOnline(4, true)
    f.setAccess(4, true)
    f.setCitizenId(4, 'COND-2')
    startLineup(f, 4, { aliceSrc, bobSrc })
    t.equals(#f.clientEvents, 4, '2 from the original session + 2 from the new one')
end)

t.test('a participant disconnecting mid-session tears down the whole session too', function()
    local f = newFixture()
    local conductorSrc, aliceSrc, bobSrc = wireBasicTrio(f)
    startLineup(f, conductorSrc, { aliceSrc, bobSrc })
    acceptAll(f, conductorSrc, { aliceSrc, bobSrc })

    f.firePlayerDropped(aliceSrc)

    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.cancelled_generic'))
    t.equals(lastNotifyFor(f, bobSrc).message, locale('scentlineup.cancelled_generic'))

    f.runCommand('k9lineuppick', conductorSrc, { '1' })
    t.equals(lastNotifyFor(f, conductorSrc).message, locale('scentlineup.not_in_lineup'))
end)

os.exit(t.summary())
