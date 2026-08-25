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

-- AwardXP's DB write now runs inside its own CreateThread(...) (silent-
-- failure fix: MySQL.insert.await instead of a callback-less MySQL.insert).
-- The stubbed MySQL.insert.await below never yields, so it's safe to run
-- the thread body synchronously/immediately rather than via a coroutine.
local function CreateThread(fn)
    fn()
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
    exports = exportsStub,
    print = printStub,
    MySQL = MySQLStub,
    Config = Config,
})

-- progression.lua's own file-local AwardXPCooldown = NewNestedCooldown(500)
-- needs the real constructor in scope at progression.lua's own load time --
-- same load-order requirement as server/admin.lua.
Sandbox.loadInto('../server/cooldowns.lua', env)
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
    for _ = 1, 10 do
        AwardXP('cid-veteran', 'exact100') -- 10 * 100 = 1000
        advancePastRateFloor()
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

os.exit(t.summary())
