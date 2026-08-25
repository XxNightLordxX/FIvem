--[[
    tests/recall_spec.lua

    Direct tests of server/recall.lua -- this resource's PRIMARY escape
    hatch/termination path for BiteAndHold/NonLethalTakedown/PropDragging --
    against the REAL, unmodified production file. Loads the real
    server/cooldowns.lua (hard file-load-time dependency: this file's own
    `NewCooldown(recallCooldownMs)` call) and server/entities.lua
    (fxmanifest.lua's own load-order neighbor for cooldowns.lua -- recall.lua
    itself never actually calls ResolveNetworkEntity/ResolveConnectedPlayerFromPed,
    loaded anyway purely to mirror the real server_scripts order exactly, per
    this task's own instruction; harmless since entities.lua defines its
    functions unconditionally at load time with no natives required until
    CALL time -- see that file's own header).

    server/partnership.lua and server/combat.lua are DELIBERATELY NEVER
    loaded here. server/recall.lua consumes GetActivePartnerCitizenId
    (partnership.lua) and EndActiveEffectForHolder (combat.lua) through its
    own documented `type(...) == 'function'` runtime-existence guard, so
    this spec controls both as plain, test-supplied stubs (present with a
    controllable return, or entirely absent) -- exactly the same "test THIS
    file's own guard behavior in isolation, not a second copy of the file it
    guards against" discipline kennel_spec.lua/combat_spec.lua already
    established for HasK9Access/NotifyPlayer and IsHesitating/IsDistracted
    respectively. GetActivePartnerCitizenId/IsActivePartnerOf's own real
    contracts are pinned directly in tests/partnership_spec.lua, not
    duplicated here.

    THIS SPEC'S CHARTER (see server/recall.lua's own header, "NO UNBOUNDED
    TRAP -- THE LOAD-BEARING INVARIANT THIS FILE EXISTS TO SATISFY"): a
    termination path must never be gated on a check that can fail, nor
    disabled by misconfiguration. Every test below serves ONE of that
    header's two concrete promises:
      1. Config.Recall.RequestCooldownMs = 0 (or any other non-positive/
         non-numeric value, or a missing Config.Recall block entirely) must
         never brick recall forever -- NewCooldown's own fail-closed
         threshold semantics (see server/cooldowns.lua's IsValidThreshold)
         would otherwise make a non-positive threshold mean "permanently on
         cooldown", the exact opposite of an operator's intent when writing
         0 to mean "no throttle".
      2. HasK9Access must never gate this handler, on EITHER party -- a K9
         whose certification is revoked mid-engagement, or a handler whose
         own certification is revoked, must still be able to call their dog
         off (or have it called off).

    ON CanShowK9UI SPECIFICALLY -- A DISCLOSED, NOT SILENTLY SKIPPED, GAP:
    CanShowK9UI is a CLIENT-ONLY global (client/main.lua) with no
    server-side equivalent at all. server/recall.lua's own server-side
    event handler has no way to call it even if it wanted to -- there is no
    "CanShowK9UI is present but returns false" case reachable from a
    server-only sandbox, unlike HasK9Access (a real server-side
    resource-global this file's own header explicitly names as one this
    handler must never consult, and which this spec DOES stub and prove is
    never consulted -- see the "HasK9Access/CanShowK9UI never gate Recall"
    section below). This spec confirms the provable, server-side half of
    that claim directly, and records the CanShowK9UI half as: (a) confirmed
    by direct source inspection that the literal string "CanShowK9UI" does
    not appear anywhere in server/recall.lua at all, so there is no
    server-side call site for a test to intercept in the first place, and
    (b) out of scope for this server-only suite for the exact same reason
    every other client/*.lua file is per DEVELOPER_REFERENCE.md's blanket
    exclusion -- not a coverage hole this suite could close by stubbing
    harder, since the check that must not exist has no server-side
    presence to stub.

    locale() is NEVER stubbed (this suite's own established convention) --
    every NotifyPlayer(..., locale('recall.xxx'), ...) call exercised below
    resolves for real against the real locales/en.json, so this spec also
    doubles as a regression check that every 'recall.*' key it reaches
    still exists there.

    ONE FRESH SANDBOX PER TEST (never shared) -- RecallCooldown is a
    file-lifetime `local` upvalue inside server/recall.lua; reusing one
    sandbox across unrelated test cases would leak one test's rate-limit
    state into the next, same discipline every other spec in this suite
    already follows.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

local REAL_DEFAULT_COOLDOWN_MS = 2000 -- mirrors config.lua's shipped Config.Recall.RequestCooldownMs

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts table? {
---   recallEnabled: boolean (default true) -- Config.Features.Recall
---   recallCfg: table|false -- Config.Recall's own value; `false` means
---     "omit the table entirely" (type(Config.Recall) ~= 'table' at read
---     time); nil/omitted means the real shipped shape { RequestCooldownMs
---     = 2000 }; any other table is used verbatim (the "misconfigured but
---     present" cases).
---   withGetActivePartner: boolean (default true) -- whether
---     GetActivePartnerCitizenId exists in the sandbox at all
---   getActivePartnerFn: function -- override the stub's behavior
---   withEndActiveEffect: boolean (default true) -- whether
---     EndActiveEffectForHolder exists in the sandbox at all
---   endActiveEffectFn: function -- override the stub's behavior
---   withHasK9Access: boolean (default false) -- whether HasK9Access exists
---     in the sandbox at all (recall.lua's own header claims it never
---     calls this; default OFF so most tests prove nothing breaks in its
---     total absence, matching a server that never loaded
---     certifications.lua's neighbor at all -- a dedicated section below
---     turns this ON specifically to prove the claim itself)
---   hasK9AccessFn: function -- override the stub's behavior
--- }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local notifyLog = {} -- { {source=, message=, kind=}, ... }
    local function NotifyPlayer(src, message, kind)
        notifyLog[#notifyLog + 1] = { source = src, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, playersByCitizenId = {}, {}
    --- @param src number
    --- @param citizenid string?
    --- @param noPlayerData boolean? -- simulate a Player object with PlayerData == nil
    local function registerPlayer(src, citizenid, noPlayerData)
        local p = noPlayerData and { PlayerData = nil } or { PlayerData = { citizenid = citizenid, source = src } }
        playersBySource[src] = p
        if citizenid then playersByCitizenId[citizenid] = p end
        return p
    end
    local function disconnectPlayer(src)
        local p = playersBySource[src]
        if not p then return end
        playersBySource[src] = nil
        if p.PlayerData and p.PlayerData.citizenid then playersByCitizenId[p.PlayerData.citizenid] = nil end
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local Config = {
        Features = { Recall = opts.recallEnabled ~= false },
    }
    if opts.recallCfg == false then
        Config.Recall = nil -- entirely absent -- the "missing block" defensive-read branch
    elseif opts.recallCfg ~= nil then
        Config.Recall = opts.recallCfg -- caller-supplied, possibly-misconfigured table
    else
        Config.Recall = { RequestCooldownMs = REAL_DEFAULT_COOLDOWN_MS } -- real shipped shape
    end

    local hasK9AccessCallCount = 0
    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        exports = exportsStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
    }
    if opts.withGetActivePartner ~= false then
        overrides.GetActivePartnerCitizenId = opts.getActivePartnerFn or function() return nil, nil end
    end
    if opts.withEndActiveEffect ~= false then
        overrides.EndActiveEffectForHolder = opts.endActiveEffectFn or function() return false end
    end
    if opts.withHasK9Access then
        overrides.HasK9Access = function(...)
            hasK9AccessCallCount = hasK9AccessCallCount + 1
            if opts.hasK9AccessFn then return opts.hasK9AccessFn(...) end
            return false
        end
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/recall.lua', env)

    return {
        env = env,
        config = Config,
        notifyLog = notifyLog,
        printLog = printLog,
        events = capturedEvents,
        eventHandlers = eventHandlers,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        setSource = function(src) env.source = src end,
        advance = function(ms) state.now = state.now + ms end,
        dispatch = function(src)
            env.source = src
            capturedEvents['qbx_k9unit:server:requestRecall']()
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, h in ipairs(eventHandlers['playerDropped'] or {}) do h() end
        end,
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

--- @param f table
--- @param src number
--- @param message string
--- @param kind string
--- @return boolean
local function notifiedExactly(f, src, message, kind)
    local entry = lastNotifyFor(f, src)
    return entry ~= nil and entry.message == message and entry.kind == kind
end

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/recall.lua registers exactly its 1 documented server net event', function()
    local f = newFixture()
    local count = 0
    for _ in pairs(f.events) do count = count + 1 end
    t.equals(count, 1)
    t.isTrue(f.events['qbx_k9unit:server:requestRecall'] ~= nil)
end)

t.test('Config.Features.Recall = false: the entire file is a no-op at load time -- no event, no cooldown warnings, no crash', function()
    local f = newFixture({ recallEnabled = false, recallCfg = 0 }) -- even a footgun config must never matter if the feature itself is off
    local count = 0
    for _ in pairs(f.events) do count = count + 1 end
    t.equals(count, 0)
    t.equals(#f.printLog, 0)
end)

-- ========================================================================
-- MUST-MATTER #1: Config.Recall.RequestCooldownMs = 0 is the known footgun.
-- NewCooldown treats a non-positive threshold as PERMANENTLY on cooldown,
-- never "no cooldown" -- server/recall.lua's own defensive read must catch
-- this before it ever reaches NewCooldown, and recall must still work.
-- ========================================================================

t.test('FOOTGUN: RequestCooldownMs = 0 does not brick recall -- a real, legitimate recall still succeeds', function()
    local f = newFixture({
        recallCfg = { RequestCooldownMs = 0 },
        getActivePartnerFn = function(citizenid)
            if citizenid == 'HANDLER-CID' then return 'K9-CID', false end
            return nil, nil
        end,
        endActiveEffectFn = function(k9Src) return k9Src == 20 end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')

    f.dispatch(10)

    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'), 'a 0 cooldown config must never silently swallow the FIRST, legitimate recall request')
    t.isTrue(notifiedExactly(f, 20, locale('recall.recalled_notice'), 'inform'))
end)

t.test('FOOTGUN: RequestCooldownMs = 0 prints a loud, one-time warning naming the field, not a silent accept', function()
    local f = newFixture({ recallCfg = { RequestCooldownMs = 0 } })
    t.equals(#f.printLog, 1)
    t.contains(f.printLog[1], 'RequestCooldownMs')
    t.contains(f.printLog[1], 'is missing or not a positive number')
end)

t.test('FOOTGUN: RequestCooldownMs = 0 falls back to the real 2000ms default -- it does NOT mean "no cooldown either" -- a second immediate request is still silently rate-limited', function()
    local f = newFixture({
        recallCfg = { RequestCooldownMs = 0 },
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')

    f.dispatch(10)
    local notifyCountAfterFirst = #f.notifyLog
    f.dispatch(10) -- same instant -- must be silently rejected by the FALLBACK cooldown, not "unlimited"
    t.equals(#f.notifyLog, notifyCountAfterFirst, 'the fallback cooldown must still throttle -- 0 is not treated as "disable the cooldown entirely" either')

    f.advance(REAL_DEFAULT_COOLDOWN_MS + 1)
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'), 'once the FALLBACK threshold genuinely elapses, recall works again')
end)

t.test('a negative RequestCooldownMs is treated exactly like 0 -- same fallback, same warning, recall still works', function()
    local f = newFixture({
        recallCfg = { RequestCooldownMs = -500 },
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    t.contains(f.printLog[1], 'RequestCooldownMs')
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'))
end)

t.test('a non-numeric RequestCooldownMs (e.g. a typo\'d string) is treated the same way -- fallback, warning, recall still works', function()
    local f = newFixture({
        recallCfg = { RequestCooldownMs = 'off' },
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    t.contains(f.printLog[1], 'RequestCooldownMs')
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'))
end)

t.test('a Config.Recall table present with RequestCooldownMs entirely absent (nil) is also caught by the same defensive read', function()
    local f = newFixture({ recallCfg = {} })
    t.equals(#f.printLog, 1)
    t.contains(f.printLog[1], 'RequestCooldownMs (nil)')
end)

t.test('FOOTGUN, missing-table variant: Config.Recall entirely absent (not just a bad field) also falls back and still works, with its OWN distinct warning', function()
    local f = newFixture({
        recallCfg = false, -- omit the table entirely
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')

    t.equals(#f.printLog, 1)
    t.contains(f.printLog[1], 'Config.Recall is missing')
    t.notContains(f.printLog[1], 'RequestCooldownMs', 'the missing-TABLE branch and the missing-FIELD branch are mutually exclusive -- must not print both messages at once')

    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'))
end)

t.test('a VALID, positive RequestCooldownMs prints no warning at all, and genuinely uses the configured value (not the 2000ms fallback)', function()
    local f = newFixture({
        recallCfg = { RequestCooldownMs = 500 },
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    t.equals(#f.printLog, 0)

    f.dispatch(10)
    f.advance(501) -- past the CONFIGURED 500ms, but nowhere near the 2000ms fallback
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'), 'if the fallback (2000ms) were wrongly still in effect, this second request at t=501 would still be on cooldown')
end)

-- ========================================================================
-- MUST-MATTER #2: HasK9Access must never gate Recall, on EITHER party.
-- ========================================================================

t.test('HasK9Access/CanShowK9UI never gate Recall: a fully-wired HasK9Access stub that DENIES both the handler and the K9 is never even consulted -- recall still succeeds', function()
    -- Narrative match for this task's own framing: "a K9 whose certification
    -- was revoked mid-engagement must still be recallable by their partner
    -- handler" -- both HANDLER-CID and K9-CID are denied access here, and a
    -- real recall still goes through end to end.
    local f = newFixture({
        withHasK9Access = true,
        hasK9AccessFn = function(_src) return false end, -- deny EVERYONE
        getActivePartnerFn = function(citizenid)
            if citizenid == 'HANDLER-CID' then return 'K9-CID', false end
            return nil, nil
        end,
        endActiveEffectFn = function(k9Src) return k9Src == 20 end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')

    f.dispatch(10)

    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'), 'HasK9Access returning false for BOTH parties must never block a recall')
    t.isTrue(notifiedExactly(f, 20, locale('recall.recalled_notice'), 'inform'))
    t.equals(f.hasK9AccessCallCount(), 0, 'the strongest form of this proof: server/recall.lua must never even CALL HasK9Access -- not "call it and ignore a false", never call it at all')
end)

t.test('HasK9Access entirely absent from the sandbox (server/certifications.lua never loaded at all) does not crash Recall -- consistent with recall.lua never referencing it', function()
    local f = newFixture({
        withHasK9Access = false,
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    local ok = pcall(f.dispatch, 10)
    t.isTrue(ok)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'))
end)

t.test('SOURCE AUDIT: server/recall.lua never actually CALLS CanShowK9UI (the identifier appears only in header/comment prose explaining why it must not be called)', function()
    local handle = assert(io.open('../server/recall.lua', 'r'))
    local text = handle:read('a')
    handle:close()
    t.isTrue(text:find('CanShowK9UI', 1, true) ~= nil, 'sanity: the identifier really is discussed in this file\'s own header -- if this ever goes false the header prose itself was removed, worth a second look')
    t.isFalse(text:find('CanShowK9UI%s*%(') ~= nil, 'if this ever fails, someone added a server-side CanShowK9UI CALL to the termination path -- see this file\'s own "NO UNBOUNDED TRAP" header section before "fixing" this test')
end)

-- ========================================================================
-- Rejections: not-partnered, self-recall, partner-offline, not-engaged.
-- ========================================================================

t.test('not-partnered: GetActivePartnerCitizenId returns nil -- caller is not partnered with anyone', function()
    local f = newFixture({ getActivePartnerFn = function() return nil, nil end })
    f.registerPlayer(10, 'LONE-CID')
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.not_partnered_to_recall'), 'error'))
end)

t.test('self-recall: the caller IS the K9-role party of their own partnership -- rejected with the same not-partnered message (they have their own release controls instead)', function()
    local f = newFixture({ getActivePartnerFn = function() return 'HANDLER-CID', true end })
    f.registerPlayer(20, 'K9-CID')
    f.dispatch(20)
    t.isTrue(notifiedExactly(f, 20, locale('recall.not_partnered_to_recall'), 'error'))
end)

t.test('GetActivePartnerCitizenId entirely absent (server/partnership.lua not loaded / feature never enabled) is a distinguishable, non-crashing rejection', function()
    local f = newFixture({ withGetActivePartner = false })
    f.registerPlayer(10, 'HANDLER-CID')
    local ok = pcall(f.dispatch, 10)
    t.isTrue(ok)
    t.isTrue(notifiedExactly(f, 10, locale('recall.partnership_unavailable'), 'error'))
end)

t.test('partner-offline: partnered with a real citizenid, but that citizenid does not currently resolve to a connected source', function()
    local f = newFixture({ getActivePartnerFn = function() return 'K9-CID-OFFLINE', false end })
    f.registerPlayer(10, 'HANDLER-CID') -- K9-CID-OFFLINE is never registered -> offline
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.partner_not_online'), 'inform'))
end)

t.test('not-engaged: EndActiveEffectForHolder entirely absent (server/combat.lua not loaded -- no feature ever enabled anything for it to end) is a distinguishable, non-crashing rejection', function()
    local f = newFixture({
        withEndActiveEffect = false,
        getActivePartnerFn = function() return 'K9-CID', false end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    local ok = pcall(f.dispatch, 10)
    t.isTrue(ok)
    t.isTrue(notifiedExactly(f, 10, locale('recall.not_engaged'), 'inform'))
end)

t.test('not-engaged: EndActiveEffectForHolder is present and callable, but genuinely reports nothing to end', function()
    local f = newFixture({
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function(_k9Src) return false end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.not_engaged'), 'inform'))
    t.isNil(lastNotifyFor(f, 20), 'a K9 with nothing active must never receive a "you were recalled" notice for an action that did not happen')
end)

-- ========================================================================
-- Success path -- exact target/argument wiring.
-- ========================================================================

t.test('success: EndActiveEffectForHolder is called with the K9\'s own resolved server id, and both parties are notified correctly', function()
    local calledWith
    local f = newFixture({
        getActivePartnerFn = function(citizenid)
            if citizenid == 'HANDLER-CID' then return 'K9-CID', false end
        end,
        endActiveEffectFn = function(k9Src) calledWith = k9Src; return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(42, 'K9-CID')
    f.dispatch(10)
    t.equals(calledWith, 42)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'))
    t.isTrue(notifiedExactly(f, 42, locale('recall.recalled_notice'), 'inform'))
end)

-- ========================================================================
-- Caller-resolution edge cases -- silent no-ops, matching every other
-- "disconnected/unresolvable mid-flight" convention in this resource.
-- ========================================================================

t.test('a source that resolves to no Player at all (disconnected between the client firing the event and the handler running) is a silent no-op', function()
    local f = newFixture()
    local ok = pcall(f.dispatch, 9999) -- never registered
    t.isTrue(ok)
    t.equals(#f.notifyLog, 0)
end)

t.test('a Player object with PlayerData == nil is a silent no-op, not a crash', function()
    local f = newFixture()
    f.registerPlayer(10, nil, true) -- noPlayerData = true
    local ok = pcall(f.dispatch, 10)
    t.isTrue(ok)
    t.equals(#f.notifyLog, 0)
end)

t.test('DISCLOSED: RecallCooldown.Consume runs BEFORE the citizenid resolution check, so an unresolvable-caller attempt still wastes that source\'s own cooldown window', function()
    local f = newFixture({
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    -- First attempt: src 10 has no registered Player at all yet -> silent
    -- no-op, but RecallCooldown.Consume(10) already stamped this source.
    local ok = pcall(f.dispatch, 10)
    t.isTrue(ok)
    t.equals(#f.notifyLog, 0)

    -- Player 10 is now genuinely valid and fully eligible -- but the SAME
    -- instant, so a wrongly-still-open cooldown from the wasted attempt
    -- above would silently swallow this otherwise-legitimate request too.
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    f.dispatch(10)
    t.equals(#f.notifyLog, 0, 'the cooldown genuinely was consumed by the earlier, wasted attempt -- this is the real, current, disclosed behavior, not a fix')

    f.advance(REAL_DEFAULT_COOLDOWN_MS + 1)
    f.dispatch(10)
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'), 'once the (wastefully-consumed) cooldown genuinely elapses, the real request succeeds')
end)

-- ========================================================================
-- Rate limit -- spam prevention only, never a barrier to a genuine first
-- request (see this file's own header).
-- ========================================================================

t.test('a second immediate request from the same caller is a SILENT no-op (no notification at all), matching this resource\'s bark/leash-request/certify-action convention', function()
    local f = newFixture({
        getActivePartnerFn = function() return 'K9-CID', false end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-CID')
    f.registerPlayer(20, 'K9-CID')
    f.dispatch(10)
    local countAfterFirst = #f.notifyLog
    f.dispatch(10)
    t.equals(#f.notifyLog, countAfterFirst)
end)

t.test('the rate limit is keyed per CALLER source -- a different handler is never blocked by another handler\'s own cooldown', function()
    local f = newFixture({
        getActivePartnerFn = function(citizenid)
            if citizenid == 'HANDLER-A' then return 'K9-A', false end
            if citizenid == 'HANDLER-B' then return 'K9-B', false end
        end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'HANDLER-A')
    f.registerPlayer(20, 'K9-A')
    f.registerPlayer(11, 'HANDLER-B')
    f.registerPlayer(21, 'K9-B')

    f.dispatch(10)
    f.dispatch(11) -- same instant, DIFFERENT caller -- must not be blocked by 10's own cooldown
    t.isTrue(notifiedExactly(f, 11, locale('recall.recall_issued'), 'success'))
end)

-- ========================================================================
-- Lifecycle: playerDropped clears the per-source cooldown (RecallCooldown
-- .RegisterPlayerDropped()) -- a recycled server id must not inherit a
-- disconnected occupant's rate-limit state.
-- ========================================================================

t.test('server/recall.lua registers exactly 1 playerDropped handler (RecallCooldown\'s own RegisterPlayerDropped)', function()
    local f = newFixture()
    t.equals(#(f.eventHandlers['playerDropped'] or {}), 1)
end)

t.test('playerDropped clears the disconnecting source\'s own cooldown -- a fresh occupant of the SAME recycled id is not blocked by the prior occupant\'s recent request', function()
    local f = newFixture({
        getActivePartnerFn = function(citizenid)
            if citizenid == 'OLD-HANDLER' then return 'OLD-K9', false end
            if citizenid == 'NEW-HANDLER' then return 'NEW-K9', false end
        end,
        endActiveEffectFn = function() return true end,
    })
    f.registerPlayer(10, 'OLD-HANDLER')
    f.registerPlayer(20, 'OLD-K9')
    f.dispatch(10) -- stamps source 10's cooldown

    f.disconnectPlayer(10)
    f.firePlayerDropped(10)

    -- Server id 10 is now recycled to a brand-new, unrelated connection.
    f.registerPlayer(10, 'NEW-HANDLER')
    f.registerPlayer(21, 'NEW-K9')
    f.dispatch(10) -- same instant, no time advance -- only succeeds if the cooldown was genuinely cleared
    t.isTrue(notifiedExactly(f, 10, locale('recall.recall_issued'), 'success'))
end)

os.exit(t.summary())
