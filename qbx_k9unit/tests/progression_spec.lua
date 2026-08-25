--[[
    tests/progression_spec.lua

    Indirect tests of server/progression.lua's local ResolveTier against the
    REAL, unmodified production file, via the two resource-global entry
    points that actually call it: AwardXP (the only write path to the
    K9XP cache) and GetXPTier (the only tier-lookup accessor). Both are
    exposed globals (no `local`) per that file's own FILE-TO-FILE CONTRACT,
    so this spec never needs to reach into a local directly -- it drives the
    real cache through the real public API, exactly as server/search.lua and
    server/tracking.lua do.

    Loads server/cooldowns.lua into the SAME sandbox env FIRST: progression.lua
    now declares its own file-local `AwardXPCooldown = NewNestedCooldown(500)`
    rate floor (citizenid+actionKey, 500ms) -- same load-order requirement
    fxmanifest.lua's own server_scripts list already documents for every
    other consumer of server/cooldowns.lua. Because of that floor, any test
    below that calls AwardXP more than once for the SAME (citizenid,
    actionKey) pair must advance the fake clock by > 500ms between calls, or
    the 2nd+ call is a silent, by-design no-op -- see each such test's own
    comment.

    Covers: Config.XPTiers boundary resolution (>= vs. just-under a
    threshold), the "unknown/uncached citizenid defaults to the base tier"
    fail-safe, the unknown-actionKey guard, the XPProgression feature-flag
    gate, malformed-citizenid rejection, the tier-crossing outbound event's
    defensive CopyTier (never leaking a live Config.XPTiers[n] reference),
    and the playerDropped cache-eviction fix.

    EIGHTH XP-FARM FIX (this pass, red-team-flagged compound-farm follow-up)
    -- a dedicated section near the bottom of this file covers the NEW
    shared cross-mechanic XP mint budget: the compound-farm ceiling itself
    (round-robining the four REAL shipped mechanics for a full simulated
    hour must not exceed the shared budget, even though their four
    independent per-mechanic ceilings sum higher), the non-positive-
    threshold footgun (IsValidXpMintBudgetParam, a resource-global test seam
    -- see server/progression.lua's own doc comment on it for why a `local`
    validity function needed one), the memory-bounding sweep thread's own
    eviction behavior, and the reconnect-does-not-reset-the-budget property.
    That section uses its own FRESH, independent sandbox (newProgressionFixture,
    with the REAL Config.XP.awards values from config.lua) rather than the
    ONE shared env/Config every test above it already depends on, so it can
    use real production numbers without perturbing any existing test's own
    fictional Config.XP.awards-derived arithmetic (this file's shared
    XP_MINT_BUDGET_STARTER_TOKENS is itself derived from whatever
    Config.XP.awards happens to contain at load time -- see that constant's
    own declaration comment in server/progression.lua).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer()
    return fakeNow
end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName()
    return 'qbx_k9unit'
end

local function GetPlayers()
    return {} -- no online players to backfill in this spec
end

local capturedTriggerEvents = {}
local function TriggerEvent(eventName, ...)
    capturedTriggerEvents[#capturedTriggerEvents + 1] = { eventName, ... }
end

local function TriggerClientEvent(_eventName, _target, ...) end

-- AwardXP's DB write runs inside its own CreateThread(...) (silent-failure
-- fix: MySQL.insert.await instead of a callback-less MySQL.insert). The
-- stubbed MySQL.insert.await below never yields, so that thread still runs
-- to completion the instant CreateThread is called (resuming a coroutine
-- whose body never hits a Wait() runs it to completion in that one resume,
-- exactly like a plain `fn()` call would) -- no behavior change for any
-- existing test below that relies on the DB write happening synchronously
-- inline.
--
-- EIGHTH-XP-FARM-FIX ADDITION: server/progression.lua's new shared XP mint
-- budget also starts a SECOND, RECURRING
-- `CreateThread(function() while true do Wait(...) ... end end)` sweep
-- thread (memory-bounding -- see that file's own declaration comment) -- the
-- first genuine "while true do Wait(...) ... end" shaped thread this spec
-- has ever needed to sandbox. A plain `fn()` call would infinite-loop
-- forever the instant this spec loads server/progression.lua (Wait() never
-- returns inside a real while-true loop with no real clock). Handled the
-- same way tests/fixtures/sandbox.lua's own newThreadRunner is documented
-- to work, but inlined here (not that shared helper) specifically so the
-- ONE-SHOT DB-write thread keeps running immediately/synchronously at
-- CreateThread-call time, exactly as before: `CreateThread` creates a
-- coroutine and resumes it ONCE right away -- a one-shot body (no Wait())
-- runs to completion on that single resume and is never captured; a
-- recurring body yields at its first Wait() and IS captured, so a later
-- test can advance it deterministically via stepMintBudgetSweep() (no
-- wall-clock delay) to exercise the sweep's own eviction logic directly.
local capturedRecurringThreads = {}
local waitCalls = {} -- every ms value passed to Wait() -- lets a test assert on the sweep's own cadence, not just its effect
local function CreateThread(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        error(('progression_spec.lua: a captured CreateThread body errored: %s'):format(tostring(err)))
    end
    if coroutine.status(co) ~= 'dead' then
        capturedRecurringThreads[#capturedRecurringThreads + 1] = co
    end
end
local function Wait(ms)
    waitCalls[#waitCalls + 1] = ms
    coroutine.yield()
end

--- Resumes every still-alive recurring thread once -- one full sweep pass
--- per call (each thread is already parked at its own Wait(), either from
--- CreateThread's own initial resume or this function's previous call),
--- matching tests/fixtures/sandbox.lua's own newThreadRunner stepping
--- semantics.
local function stepMintBudgetSweep()
    for _, co in ipairs(capturedRecurringThreads) do
        if coroutine.status(co) ~= 'dead' then
            local ok, err = coroutine.resume(co)
            if not ok then
                error(('progression_spec.lua: stepMintBudgetSweep: a captured thread errored: %s'):format(tostring(err)))
            end
        end
    end
end

local playerByCitizenId = {}
local exportsStub = {
    qbx_core = {
        GetPlayerByCitizenId = function(_self, citizenid)
            return playerByCitizenId[citizenid]
        end,
        GetPlayer = function(_self, src)
            for _, p in pairs(playerByCitizenId) do
                if p.PlayerData.source == src then return p end
            end
            return nil
        end,
    },
}

local capturedPrints = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
    capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
end

local MySQLStub = {
    scalar = { await = function(_sql, _params) return nil end }, -- "no row yet" path
    insert = { await = function(_sql, _params) return 1 end },
}

local Config = {
    Features = { XPProgression = true },
    XP = {
        scopePerCitizenidOrJob = 'citizenid',
        awards = {
            smallAward = 60,   -- two of these cross the 100-xp tier boundary
            exact100 = 100,    -- lands exactly ON a tier boundary
            ninetynine = 99,   -- lands exactly one below a tier boundary
            zeroAward = 0,
        },
    },
    XPTiers = {
        { xp = 0,   label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        { xp = 100, label = 'Trained', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        { xp = 500, label = 'Veteran', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
    },
}

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    GetPlayers = GetPlayers,
    TriggerEvent = TriggerEvent,
    TriggerClientEvent = TriggerClientEvent,
    CreateThread = CreateThread,
    Wait = Wait,
    exports = exportsStub,
    print = printStub,
    MySQL = MySQLStub,
    Config = Config,
})

-- progression.lua's own file-local AwardXPCooldown = NewNestedCooldown(500)
-- needs the real constructor in scope at progression.lua's own load time --
-- same load-order requirement as server/admin.lua.
Sandbox.loadInto('../server/cooldowns.lua', env)
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/progression.lua's own
-- LoadXPForCitizenid/AwardXP/AwardXPDirect now read/write through
-- K9Store.XP_Get/K9Store.XP_UpsertAdd rather than raw SQL). Config.Database
-- is deliberately absent from this fixture's Config table above --
-- K9Store's own DatabaseEnabled() fails safe to `true` (real-DB mode) on a
-- missing Config.Database, which is exactly what makes those K9Store
-- calls run the SAME MySQL.scalar.await/MySQL.insert.await calls (against
-- this fixture's own MySQLStub) built directly before this migration, so
-- every existing assertion below keeps exercising the identical
-- SQL/params shape unchanged. See tests/admin_spec.lua for the precedent
-- this comment mirrors.
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
Sandbox.loadInto('../server/progression.lua', env)

for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('qbx_k9unit')
end

local AwardXP = env.AwardXP
local GetXPTier = env.GetXPTier
local GetXP = env.GetXP

t.isNotNil(AwardXP, 'server/progression.lua must define global AwardXP')
t.isNotNil(GetXPTier, 'server/progression.lua must define global GetXPTier')
t.isNotNil(GetXP, 'server/progression.lua must define global GetXP')

--- Advances the fake clock past AwardXPCooldown's 500ms per-(citizenid,
--- actionKey) rate floor -- see this file's header. Needed between any two
--- AwardXP calls in the same test that reuse the same citizenid+actionKey
--- pair and are meant to BOTH actually apply.
local function advancePastRateFloor()
    fakeNow = fakeNow + 501
end

-- ----------------------------------------------------------------------
-- ResolveTier via GetXPTier: uncached / baseline behavior
-- ----------------------------------------------------------------------

t.test('GetXPTier: an uncached citizenid defaults to the base tier (xp=0), never nil', function()
    local tier = GetXPTier('never-seen-before')
    t.isNotNil(tier)
    t.equals(tier.label, 'Recruit')
end)

t.test('GetXP: an uncached citizenid reads back as 0', function()
    t.equals(GetXP('never-seen-before-2'), 0)
end)

-- ----------------------------------------------------------------------
-- ResolveTier boundary behavior via AwardXP-driven accumulation
-- ----------------------------------------------------------------------

t.test('ResolveTier: exactly AT a tier boundary (xp >= tier.xp) resolves to that tier, not the one below', function()
    AwardXP('cid-exact-100', 'exact100')
    t.equals(GetXP('cid-exact-100'), 100)
    t.equals(GetXPTier('cid-exact-100').label, 'Trained', 'xp == 100 must resolve to Trained (>=), not Recruit')
end)

t.test('ResolveTier: one XP below a tier boundary stays on the lower tier', function()
    AwardXP('cid-ninetynine', 'ninetynine')
    t.equals(GetXP('cid-ninetynine'), 99)
    t.equals(GetXPTier('cid-ninetynine').label, 'Recruit', 'xp == 99 must NOT reach Trained (threshold is 100)')
end)

t.test('ResolveTier: accumulation across multiple AwardXP calls crosses a tier boundary', function()
    AwardXP('cid-accum', 'smallAward') -- 60
    t.equals(GetXPTier('cid-accum').label, 'Recruit')
    advancePastRateFloor() -- same citizenid+actionKey pair -- must clear the 500ms rate floor
    AwardXP('cid-accum', 'smallAward') -- 120
    t.equals(GetXP('cid-accum'), 120)
    t.equals(GetXPTier('cid-accum').label, 'Trained', '60+60=120 must cross the 100-xp boundary into Trained')
end)

t.test('ResolveTier: a high accumulated total resolves to the top tier, not the first match', function()
    -- EIGHTH-XP-FARM-FIX INTERACTION: the shared cross-mechanic XP mint
    -- budget (server/progression.lua) now also gates this loop's 10 calls
    -- for the SAME citizenid -- unrelated to what THIS test actually checks
    -- (ResolveTier's ascending tier walk), but real and unconditional (the
    -- budget has no per-test/per-Config opt-out, by design -- see that
    -- section's own "FILE-LOCAL CONSTANTS, NOT CONFIG KEYS" comment).
    -- Advances the clock by far more than advancePastRateFloor()'s own
    -- 501ms between each award specifically so the real
    -- XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS refill rate (1 XP per
    -- 1000ms, hardcoded in server/progression.lua, independent of this
    -- spec's own Config.XP.awards values) keeps pace with this loop's
    -- 100-XP-per-call demand, isolating ResolveTier's own tier-walk logic
    -- from the separate budget concern (covered on its own, with the REAL
    -- shipped award table and cadence, in the EIGHTH-XP-FARM-FIX section
    -- below).
    for _ = 1, 10 do
        AwardXP('cid-veteran', 'exact100') -- 10 * 100 = 1000
        fakeNow = fakeNow + 500000 -- comfortably clears both the 500ms rate floor and the shared mint budget's own refill needs
    end
    t.equals(GetXP('cid-veteran'), 1000)
    t.equals(GetXPTier('cid-veteran').label, 'Veteran', 'must keep walking to the LAST tier whose xp threshold is met')
end)

-- ----------------------------------------------------------------------
-- AwardXP guard rails
-- ----------------------------------------------------------------------

t.test('AwardXP: an unknown actionKey is a safe no-op (logged, never crashes, never grants XP)', function()
    AwardXP('cid-unknown-action', 'thisActionKeyDoesNotExist')
    t.equals(GetXP('cid-unknown-action'), 0)
    local found = false
    for _, line in ipairs(capturedPrints) do
        if line:find('unknown actionKey', 1, true) then found = true end
    end
    t.isTrue(found, 'an unknown actionKey must be logged to console, not silently swallowed')
end)

t.test('AwardXP: a non-string citizenid is a safe no-op', function()
    AwardXP(12345, 'smallAward')
    -- Nothing to assert by key (no string key was ever touched) -- the real
    -- assertion is that this line does not throw.
    t.isTrue(true)
end)

t.test('AwardXP: an empty-string citizenid is a safe no-op', function()
    AwardXP('', 'smallAward')
    t.equals(GetXP(''), 0)
end)

t.test('AwardXP: is a hard no-op while Config.Features.XPProgression is false', function()
    Config.Features.XPProgression = false
    AwardXP('cid-flag-off', 'smallAward')
    t.equals(GetXP('cid-flag-off'), 0, 'no XP may be granted while the feature flag is off')
    Config.Features.XPProgression = true
    -- The flag-off call above returned before ever touching AwardXPCooldown
    -- (the flag check runs first), so this second call is NOT rate-floored
    -- by it -- it is a genuinely fresh first attempt for this citizenid.
    AwardXP('cid-flag-off', 'smallAward')
    t.equals(GetXP('cid-flag-off'), 60, 'once re-enabled, the SAME citizenid must be able to earn XP normally')
end)

t.test('AwardXP: the per-(citizenid, actionKey) rate floor silently no-ops an immediate repeat', function()
    AwardXP('cid-ratefloor', 'smallAward')
    t.equals(GetXP('cid-ratefloor'), 60)
    AwardXP('cid-ratefloor', 'smallAward') -- same citizenid+actionKey, no clock advance
    t.equals(GetXP('cid-ratefloor'), 60, 'an immediate repeat of the same (citizenid, actionKey) must be rate-floored, not double-applied')
    local found = false
    for _, line in ipairs(capturedPrints) do
        if line:find('rate floor tripped', 1, true) then found = true end
    end
    t.isTrue(found, 'a rate-floor trip must be logged to console')
end)

t.test('AwardXP: the rate floor is per-actionKey, not a blanket per-citizenid floor', function()
    -- Mirrors server/tenure.lua's own documented legitimate case: several
    -- DIFFERENT actionKeys for the same citizenid in the same instant must
    -- all still apply.
    AwardXP('cid-multikey', 'smallAward')
    AwardXP('cid-multikey', 'exact100') -- different actionKey, same instant -- must NOT be floored
    t.equals(GetXP('cid-multikey'), 160, 'a different actionKey for the same citizenid must not share the floor')
end)

-- ----------------------------------------------------------------------
-- CopyTier defensive copy: a tier-crossing event must never leak a live
-- reference to the shared Config.XPTiers[n] table.
-- ----------------------------------------------------------------------

t.test('AwardXP: a tier crossing fires the outbound event with COPIES, never the live Config.XPTiers[n] reference', function()
    capturedTriggerEvents = {}
    AwardXP('cid-copytier', 'exact100') -- crosses 0 -> 100, Recruit -> Trained
    t.equals(GetXPTier('cid-copytier').label, 'Trained')

    local firedEvent = nil
    for _, event in ipairs(capturedTriggerEvents) do
        if event[1] == 'qbx_k9unit:events:xpTierReached' then firedEvent = event end
    end
    t.isNotNil(firedEvent, 'a real tier crossing must fire qbx_k9unit:events:xpTierReached')

    local newTierArg = firedEvent[3]
    t.equals(newTierArg.label, 'Trained')
    t.isTrue(newTierArg ~= Config.XPTiers[2],
        'the event payload must be a COPY -- handing out the live Config.XPTiers[2] table would let an external ' ..
        'resource mutate speedMultiplier/scentRangeMultiplier for every K9 in that tier, server-wide')

    -- Mutating the copy must never affect the real config table.
    newTierArg.speedMultiplier = 999
    t.equals(Config.XPTiers[2].speedMultiplier, 1.05, 'mutating the event payload copy must not corrupt the real Config.XPTiers entry')
end)

-- ----------------------------------------------------------------------
-- playerDropped cache eviction (bounded-memory-growth fix)
-- ----------------------------------------------------------------------

t.test('playerDropped: evicts the disconnecting source\'s K9XP cache entry', function()
    AwardXP('cid-dropper', 'exact100')
    t.equals(GetXP('cid-dropper'), 100)

    playerByCitizenId['cid-dropper'] = { PlayerData = { citizenid = 'cid-dropper', source = 777 } }
    env.source = 777
    for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
        handler('some reason')
    end

    t.equals(GetXP('cid-dropper'), 0, 'K9XP cache entry must be evicted on disconnect, resetting to the uncached baseline')
end)

t.test('EIGHTH XP-FARM FIX: the shared env\'s own mint-budget sweep thread (created at server/progression.lua\'s own load time, captured by this file\'s CreateThread stub above) can be stepped without erroring', function()
    -- Distinct from the fresh, independently-constructed fixtures the
    -- dedicated EIGHTH-XP-FARM-FIX section below uses -- this is the ONE
    -- sweep thread tied to the SAME env every other test in this file
    -- shares, exercised here at least once so it is not merely
    -- load-and-forget. Advances the shared clock well past a full
    -- XP_MINT_BUDGET_WINDOW_MS of total inactivity for every citizenid this
    -- shared env has touched so far, then steps the sweep once.
    fakeNow = fakeNow + 3600001
    local ok = pcall(stepMintBudgetSweep)
    t.isTrue(ok, 'the shared env\'s own mint-budget sweep thread must run a pass without erroring')
end)

-- ============================================================================
-- EIGHTH XP-FARM FIX: shared cross-mechanic XP mint budget
-- (server/progression.lua's XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS/
-- XP_MINT_BUDGET_STARTER_TOKENS, consulted inside AwardXP). See this file's
-- own header for why this section builds its own FRESH sandbox instead of
-- reusing the shared `env` above.
-- ============================================================================

--- Builds a fresh, independent sandbox for server/progression.lua -- its own
--- Config (with the REAL shipped Config.XP.awards/Config.XPTiers values from
--- config.lua, not this file's shared toy award table), its own K9XP/
--- XPMintBudget/AwardXPCooldown state, its own fake clock, and its own
--- CreateThread/Wait capture for the mint-budget sweep thread (identical
--- coroutine-capture technique to the one this file's shared `CreateThread`
--- above already uses, and for the exact same reason -- see that one's own
--- declaration comment for the full writeup: a plain `fn()` call would
--- infinite-loop on the sweep thread's `while true do Wait(...) ... end`).
--- @return table fixture
local function newProgressionFixture()
    local fakeNow2 = 0
    local function GetGameTimer2() return fakeNow2 end

    local eventHandlers2 = {}
    local function AddEventHandler2(eventName, handler)
        eventHandlers2[eventName] = eventHandlers2[eventName] or {}
        eventHandlers2[eventName][#eventHandlers2[eventName] + 1] = handler
    end

    local function GetCurrentResourceName2() return 'qbx_k9unit' end
    local function GetPlayers2() return {} end
    local function TriggerEvent2(_eventName, ...) end
    local function TriggerClientEvent2(_eventName, _target, ...) end

    local capturedRecurringThreads2 = {}
    local function CreateThread2(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newProgressionFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
        if coroutine.status(co) ~= 'dead' then
            capturedRecurringThreads2[#capturedRecurringThreads2 + 1] = co
        end
    end
    local function Wait2(_ms) coroutine.yield() end
    local function stepSweep2()
        for _, co in ipairs(capturedRecurringThreads2) do
            if coroutine.status(co) ~= 'dead' then
                local ok, err = coroutine.resume(co)
                if not ok then
                    error(('newProgressionFixture: stepSweep: a captured thread errored: %s'):format(tostring(err)))
                end
            end
        end
    end

    local printedLines2 = {}
    local function printStub2(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines2[#printedLines2 + 1] = table.concat(parts, '\t')
    end

    local playerByCitizenId2 = {}
    local exportsStub2 = {
        qbx_core = {
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId2[citizenid] end,
            GetPlayer = function(_self, src)
                for _, p in pairs(playerByCitizenId2) do
                    if p.PlayerData.source == src then return p end
                end
                return nil
            end,
        },
    }

    local MySQLStub2 = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    -- REAL shipped values (config.lua) -- not this file's shared toy table.
    -- awards match Config.XP.awards exactly, INCLUDING the three
    -- partnershipTenure milestone keys -- not just the four mechanics this
    -- pass's own red-team finding named -- because
    -- XP_MINT_BUDGET_STARTER_TOKENS (server/progression.lua) sums EVERY
    -- Config.XP.awards value, and this section's own numbers must match
    -- that real 240-XP sum (25+10+20+30+15+40+100), not a partial one.
    -- XPTiers match Config.XPTiers exactly (0/1250/4000/9000) so this
    -- section's own Elite-tier assertions are directly comparable to the
    -- real economy, not an analogy.
    local Config2 = {
        Features = { XPProgression = true },
        XP = {
            scopePerCitizenidOrJob = 'citizenid',
            awards = {
                searchContrabandFound  = 25,
                trackSourceResolved    = 10,
                biteHoldSuccess        = 20,
                takedownSuccess        = 30,
                partnershipTenure1Day  = 15,
                partnershipTenure7Day  = 40,
                partnershipTenure30Day = 100,
            },
        },
        XPTiers = {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
            { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20 },
        },
    }

    local env2 = Sandbox.newEnv({
        GetGameTimer = GetGameTimer2,
        AddEventHandler = AddEventHandler2,
        GetCurrentResourceName = GetCurrentResourceName2,
        GetPlayers = GetPlayers2,
        TriggerEvent = TriggerEvent2,
        TriggerClientEvent = TriggerClientEvent2,
        CreateThread = CreateThread2,
        Wait = Wait2,
        exports = exportsStub2,
        print = printStub2,
        MySQL = MySQLStub2,
        Config = Config2,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env2)
    -- server/datastore.lua -- REAL, unmodified, loaded alongside (see this
    -- file's own top-of-file loadInto comment above for the full
    -- reasoning). Config2.Database is deliberately absent, so
    -- DatabaseEnabled() fails safe to `true` and every K9Store.XP_* call
    -- forwards straight through to MySQLStub2 exactly as before this
    -- migration.
    Sandbox.loadInto('../server/datastore.lua', env2)
    Sandbox.loadInto('../server/events.lua', env2) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    Sandbox.loadInto('../server/progression.lua', env2)
    for _, handler in ipairs(eventHandlers2['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    return {
        AwardXP = env2.AwardXP,
        GetXP = env2.GetXP,
        GetXPTier = env2.GetXPTier,
        printedLines = printedLines2,
        setNow = function(ms) fakeNow2 = ms end,
        now = function() return fakeNow2 end,
        stepSweep = stepSweep2,
        firePlayerDropped = function(citizenid, src)
            playerByCitizenId2[citizenid] = { PlayerData = { citizenid = citizenid, source = src } }
            env2.source = src
            for _, handler in ipairs(eventHandlers2['playerDropped'] or {}) do
                handler('some reason')
            end
        end,
    }
end

--- Drives AwardXP for a single citizenid using the four REAL shipped mint
--- cadences (server/combat.lua's BiteHoldXpMintCooldown/
--- TakedownXpMintCooldown, server/search.lua's ContrabandXpMintCooldown --
--- all 60000ms -- and server/tracking.lua's TrackTicketMintCooldown --
--- 30000ms) round-robined together from t=0 up to `toMs` -- the exact
--- compound-farm shape the red-team finding described. This spec calls
--- AwardXP directly (server/combat.lua/search.lua/tracking.lua are not
--- loaded here) -- the shared budget lives entirely inside AwardXP itself,
--- so driving it directly exercises the REAL production gate with no
--- re-implementation. Always starts a FRESH simulation from t=0 for
--- whichever citizenid is passed in (never resumes a prior partial run),
--- so two different `toMs` checkpoints are driven as two independent calls
--- with two different citizenids, never as one paused-and-resumed run.
---
--- BUILDS ONE TIME-SORTED EVENT LIST, deliberately NOT two separate
--- sequential `for` loops (an earlier draft of this helper did exactly
--- that, and it produced a real, subtle bug: the SECOND loop's `f.setNow`
--- calls "rewind" fakeNow backward relative to the first loop's final
--- timestamp before climbing again, and RefillMintBudget's own `elapsed <=
--- 0` guard -- correct, deliberate wraparound-safety behavior, matching
--- server/cooldowns.lua's own documented caveat -- then skips EVERY refill
--- for nearly the entire second loop, since `now` never exceeds the frozen
--- `lastRefillAt` from the end of the first loop until the very last
--- iteration. That silently starved the track-mechanic half of this
--- round-robin of almost all its real refill share). A single event list,
--- sorted once by timestamp, keeps fakeNow genuinely monotonic across the
--- whole simulated hour, exactly like a real server's clock.
--- @param f table
--- @param citizenid string
--- @param toMs number
--- @return number uncappedTotal -- what the four independent per-mechanic ceilings would have summed to, ignoring the shared budget entirely
local function roundRobinRealMechanics(f, citizenid, toMs)
    local events = {}
    for tms = 60000, toMs, 60000 do
        events[#events + 1] = { tms, 'biteHoldSuccess',       20 }
        events[#events + 1] = { tms, 'takedownSuccess',       30 }
        events[#events + 1] = { tms, 'searchContrabandFound', 25 }
    end
    for tms = 30000, toMs, 30000 do
        events[#events + 1] = { tms, 'trackSourceResolved', 10 }
    end
    for i, ev in ipairs(events) do ev[4] = i end -- stable tie-break: preserve insertion order for same-timestamp events
    table.sort(events, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[4] < b[4]
    end)

    local uncappedTotal = 0
    for _, ev in ipairs(events) do
        f.setNow(ev[1])
        f.AwardXP(citizenid, ev[2])
        uncappedTotal = uncappedTotal + ev[3]
    end
    return uncappedTotal
end

t.test('EIGHTH XP-FARM FIX: round-robining all four REAL award mechanics (biteHoldSuccess/takedownSuccess/searchContrabandFound/trackSourceResolved) at their real shipped cadence for one full simulated hour is capped at the shared budget, NOT the four independent per-mechanic ceilings\' uncapped sum', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-compound-farm'

    local uncappedTotal = roundRobinRealMechanics(f, citizenid, 3600000)

    t.equals(uncappedTotal, 5700, 'sanity check on this test\'s own arithmetic -- the four independent per-mechanic ceilings really do sum to 5,700 XP/hr uncapped, matching this pass\'s own report')
    t.equals(f.GetXP(citizenid), 3810, 'the shared budget (3,600 XP/hr cap + a 240-XP one-time starter allowance -- see XP_MINT_BUDGET_STARTER_TOKENS\'s own comment) is the binding constraint, not the uncapped 5,700 XP/hr sum -- exact value re-verified by direct simulation before asserting it here, not guessed')
    t.isTrue(f.GetXP(citizenid) < uncappedTotal, 'the compound farm must be measurably closed, not merely renamed')
end)

t.test('EIGHTH XP-FARM FIX: the REAL combined ceiling still comfortably clears config.lua\'s own ">2 hours to Elite" retuning goal', function()
    -- Two INDEPENDENT fixtures/citizenids, each a fresh from-t=0 simulation
    -- to its own checkpoint -- see roundRobinRealMechanics's own doc comment
    -- for why this is simpler and less error-prone than pausing one
    -- simulation partway through to check an interim state.
    local fAt2h = newProgressionFixture()
    roundRobinRealMechanics(fAt2h, 'cid-elite-at-2h', 7200000)
    t.isTrue(fAt2h.GetXP('cid-elite-at-2h') < 9000, 'at exactly 2 hours of maximal round-robin farming, Elite (9,000 XP) must NOT yet be reached -- this is the floor this whole fix exists to restore')
    t.equals(fAt2h.GetXPTier('cid-elite-at-2h').label, 'Veteran K9', 'still Veteran, not Elite, at the 2-hour mark')

    local fAt25h = newProgressionFixture()
    roundRobinRealMechanics(fAt25h, 'cid-elite-at-2.5h', 9000000)
    t.isTrue(fAt25h.GetXP('cid-elite-at-2.5h') >= 9000, 'by 2.5 simulated hours of maximal four-mechanic round-robin farming, Elite (9,000 XP) must be reached -- matching this pass\'s own report of ~2.44h as the real worst-case time')
    t.equals(fAt25h.GetXPTier('cid-elite-at-2.5h').label, 'Elite K9')
end)

t.test('EIGHTH XP-FARM FIX FOOTGUN: IsValidXpMintBudgetParam (the exact validity check the shared budget\'s fail-OPEN decision is built on) rejects 0/negative/nil/NaN and accepts a real positive number', function()
    -- Resource-global test seam (server/progression.lua's own doc comment on
    -- IsValidXpMintBudgetParam explains why one was needed here) -- this
    -- file's shared `env` from the top of this file already has it, no new
    -- sandbox required. See server/progression.lua's own XPMintBudgetEnabled
    -- comment for why this section cannot ALSO drive AwardXP's actual
    -- disabled/fail-open code path from here: XP_MINT_BUDGET_CAP_XP/
    -- XP_MINT_BUDGET_WINDOW_MS are file-local Lua literals (deliberately not
    -- Config-driven -- same "FILE-LOCAL CONSTANT, NOT A CONFIG KEY" posture
    -- as every per-mechanic mint cooldown), so no test, real config, or
    -- runtime input can ever inject a bad value into them the way
    -- server/cooldowns.lua's own Config-driven thresholds can be tested end
    -- to end -- pinning the validity function itself (the ONLY moving part
    -- this fail-open decision actually depends on) is the most direct
    -- coverage structurally possible for this footgun without adding a
    -- production behavior change purely to make it more testable.
    local IsValidXpMintBudgetParam = env.IsValidXpMintBudgetParam
    t.isNotNil(IsValidXpMintBudgetParam, 'server/progression.lua must define global IsValidXpMintBudgetParam')

    t.isFalse(IsValidXpMintBudgetParam(0), '0 must never mean "no budget enforced" -- see server/cooldowns.lua\'s own identical rejection for the historical reason why')
    t.isFalse(IsValidXpMintBudgetParam(-1))
    t.isFalse(IsValidXpMintBudgetParam(-3600))
    t.isFalse(IsValidXpMintBudgetParam(nil))
    t.isFalse(IsValidXpMintBudgetParam('3600'), 'a numeric-looking STRING must not silently pass -- only a real Lua number')
    t.isFalse(IsValidXpMintBudgetParam(0/0), 'NaN must be rejected -- `value > 0` alone does NOT catch it (every comparison against NaN is false), which would otherwise fail OPEN by accident')
    t.isTrue(IsValidXpMintBudgetParam(3600), 'the real shipped XP_MINT_BUDGET_CAP_XP value must pass')
    t.isTrue(IsValidXpMintBudgetParam(3600000), 'the real shipped XP_MINT_BUDGET_WINDOW_MS value must pass')
    t.isTrue(IsValidXpMintBudgetParam(0.5), 'any finite positive number is valid, not just integers')
end)

--- Drains a fresh citizenid's shared-budget bucket to exactly 0 tokens by
--- t=3,600,000ms, reusing the SAME proven-correct round-robin pattern (and
--- the SAME exact numbers) as the 1-hour compound-farm test above -- that
--- test already establishes (and asserts) this leaves 0 tokens remaining at
--- that instant. Reusing it here rather than a new hand-rolled drain loop
--- avoids re-deriving timing math that is easy to get subtly wrong (an
--- earlier draft of this section did exactly that, repeatedly calling the
--- SAME actionKey with no time advance between calls and tripping
--- AwardXPCooldown's own pre-existing 500ms-per-actionKey floor instead of
--- draining the budget at all).
--- @param f table -- from newProgressionFixture()
--- @param citizenid string
local function drainToZeroOverOneHour(f, citizenid)
    roundRobinRealMechanics(f, citizenid, 3600000)
end

--- Fires exactly 10 takedownSuccess (30 XP each) awards at the CURRENT
--- fixture time, spaced 501ms apart (just past AwardXPCooldown's own
--- PRE-EXISTING 500ms-per-(citizenid,actionKey) floor -- an earlier draft of
--- this helper called the SAME actionKey back-to-back with zero elapsed
--- time and got every call after the first blocked by that floor instead of
--- by the mint budget it meant to probe). 501ms * 9 gaps = 4,509ms of
--- additional real time during the whole probe -- refills a negligible
--- ~4.5 XP at this section's own 3,600-XP/hr rate, nowhere near enough to
--- blur the distinction this probe exists to draw: "bucket refilled to
--- ~1,800 XP over a real 30-minute idle gap" -- all 10 succeed, 300 XP
--- total -- vs. "bucket was evicted and recreated at the 240-XP starter
--- allowance" -- only 8 of 10 fit (240 XP), 2 are denied.
--- @param f table
--- @param citizenid string
--- @return number grantedCount
local function burstProbe10Takedowns(f, citizenid)
    local before = f.GetXP(citizenid)
    for _ = 1, 10 do
        f.AwardXP(citizenid, 'takedownSuccess')
        f.setNow(f.now() + 501)
    end
    return (f.GetXP(citizenid) - before) / 30
end

t.test('EIGHTH XP-FARM FIX: the memory-bounding sweep does NOT evict a citizenid\'s bucket before a full XP_MINT_BUDGET_WINDOW_MS of inactivity has elapsed', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-sweep-early'
    drainToZeroOverOneHour(f, citizenid) -- ends at fakeNow=3,600,000, 0 tokens remaining

    -- 30 more minutes of inactivity -- well UNDER the 1-hour window. The
    -- bucket should have refilled to ~1,800 XP (30min * 3,600 XP/hr) via
    -- lazy RefillMintBudget, NOT been evicted -- a sweep pass here must not
    -- touch it early.
    f.setNow(f.now() + 1800000)
    f.stepSweep()

    local grantedCount = burstProbe10Takedowns(f, citizenid)
    t.equals(grantedCount, 10, 'a bucket refilled to ~1,800 XP over 30 real minutes must afford all 10 probe takedowns (300 XP) -- if the sweep had evicted it early, only 8 of 10 (240 XP, the fresh starter allowance) would have fit')
end)

t.test('EIGHTH XP-FARM FIX: the memory-bounding sweep DOES safely evict a citizenid\'s bucket once a full XP_MINT_BUDGET_WINDOW_MS of inactivity has elapsed, recreating it at the small starter allowance (not full capacity) on next use', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-sweep-late'
    drainToZeroOverOneHour(f, citizenid) -- ends at fakeNow=3,600,000, 0 tokens remaining

    -- A full hour plus one ms of further inactivity -- now stale by this
    -- section's own eviction rule (RefillMintBudget would already have
    -- clamped this bucket to full capacity, 3,600 XP, had anyone looked).
    -- Eviction here is the DESIGNED-CONSERVATIVE path -- see XPMintBudget's
    -- sweep-thread comment for why recreating at the small starter
    -- allowance afterward, rather than resuming from what would have been a
    -- full 3,600-XP bucket, is deliberate and safe (strictly less budget,
    -- never more).
    f.setNow(f.now() + 3600001)
    f.stepSweep()

    local grantedCount = burstProbe10Takedowns(f, citizenid)
    t.equals(grantedCount, 8, 'a swept-and-recreated bucket starts at the 240-XP starter allowance, not the 3,600-XP full capacity a non-evicted bucket would have held -- only 8 of 10 probe takedowns (240 XP) fit')
end)

t.test('EIGHTH XP-FARM FIX: reconnecting with a fresh player source never resets the shared budget (it is keyed by citizenid, not source)', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-reconnect'
    drainToZeroOverOneHour(f, citizenid) -- ends at fakeNow=3,600,000, 0 tokens remaining

    -- Disconnect (source 111), "reconnect" as a DIFFERENT source (222) --
    -- exactly what a real player reconnecting produces (a fresh FiveM
    -- server-id each session; the citizenid is the only stable identity).
    -- No further time advance -- the budget should still read as fully
    -- spent (0 tokens, nothing has refilled).
    f.firePlayerDropped(citizenid, 111)

    -- K9XP's own in-memory cache IS intentionally evicted by playerDropped
    -- (pre-existing, unrelated behavior -- the real total is reloaded from
    -- k9_progression on the next PlayerLoaded in production, not simulated
    -- by this fixture) -- GetXP reading 0 here is expected and is NOT what
    -- this test is checking.
    t.equals(f.GetXP(citizenid), 0, 'sanity check: K9XP cache eviction on disconnect is pre-existing, unrelated behavior -- not this test\'s own concern')

    -- The real check: if XPMintBudget had been incorrectly reset by the
    -- reconnect, this citizenid would behave like a brand-new one (240-XP
    -- starter allowance) and this single takedownSuccess (30 XP) would be
    -- granted. Since the real budget correctly survived (still at 0 tokens,
    -- no time has passed to refill any), it must be denied.
    f.AwardXP(citizenid, 'takedownSuccess')
    t.equals(f.GetXP(citizenid), 0, 'a reconnect must never grant a fresh starter allowance on top of an already-fully-spent budget -- XPMintBudget is deliberately never cleared on playerDropped')
end)

os.exit(t.summary())
