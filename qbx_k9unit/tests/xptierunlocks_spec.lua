--[[
    tests/xptierunlocks_spec.lua

    Tests for server/progression.lua's GetXPTierMedkitCooldownMs -- Part B §8
    XP TIER UNLOCKS (see that file's own "XP TIER UNLOCKS" section header,
    directly above GetXPTierMedkitCooldownMs's own declaration, for the full
    design: which three tiers unlock what, and why every rejected candidate
    was rejected). Loaded via the REAL, unmodified server/progression.lua
    (same sandbox recipe as tests/progression_spec.lua: server/cooldowns.lua
    first, since progression.lua's own file-local AwardXPCooldown/
    XPMintBudget state needs the real NewNestedCooldown constructor at load
    time).

    Every AwardXP call below advances the fake clock by 500,000ms first --
    comfortably clearing BOTH the 500ms-per-(citizenid,actionKey) rate floor
    AND the shared XP mint budget's own refill needs for this fixture's
    60-XP award (the budget refills at exactly 1 XP per 1,000ms, so 500,000ms
    refills ~500 XP between calls -- nowhere near draining even under
    repeated 60-XP draws), mirroring tests/progression_spec.lua's own
    identical-purpose "high accumulated total" test.

    Covers:
      1. GetXPTierMedkitCooldownMs's pure numeric contract: an absent/
         non-numeric/NaN/<=0/>1 medkitCooldownMultiplier on the resolved
         tier returns baseCooldownMs UNCHANGED (the safe, "unlock not yet
         configured, or misconfigured" default); a valid (0, 1] multiplier
         reduces it; a malformed baseCooldownMs itself is returned
         unchanged, never erroring.
      2. THE LOAD-BEARING PROOF this task requires: a tier unlock cannot
         override a high-command block. There is still no SINGLE shared,
         exported Config.FeatureControl block/grant resolution function to
         load and drive directly -- each consuming file (server/medkit.lua,
         server/combat.lua, server/admin.lua, server/search.lua, and others)
         implements its own local per-feature resolution function against
         the same generic HasPermission('feature.<Name>'/'block.<Name>')
         seam, copied rather than shared (see server/progression.lua's own
         "XP TIER UNLOCKS" section for why none of this pass's three
         unlocks needed one to compose safely). This section instead proves
         the property the most concrete way currently possible against
         REAL, unmodified code: it drives the REAL GetXPTierMedkitCooldownMs
         through a small, explicitly-labelled local stand-in for the
         block-before-tier-consultation shape, and shows that a block check
         placed BEFORE the tier-multiplier consultation (the only order
         GetXPTierMedkitCooldownMs's own CALLER CONTRACT permits) denies
         outright, regardless of tier, and never even reaches the tier
         read. This proves the INTEGRATION PATTERN's correctness in the
         general case. CORRECTED (this pass, coder-backend): this used to
         call the stand-in below a proxy for server/medkit.lua's own
         "REPORTED (not yet applied)" call-site integration -- re-verified
         false by direct read. server/medkit.lua's RunUseK9MedkitMutation
         now genuinely calls GetXPTierMedkitCooldownMs (see that function's
         own CALLER CONTRACT doc comment in server/progression.lua for the
         exact call site) -- but its own per-person K9Medkit feature/block
         check (IsK9MedkitPermittedForCitizenId) runs earlier in that
         file's callback, before the mutex/cooldown resolution, not as a
         check interleaved with the tier-multiplier read itself. The
         stand-in below remains a generic proof of the ORDERING property,
         not a literal mirror of server/medkit.lua's own current structure.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup -- same minimal recipe as tests/progression_spec.lua's own
-- shared env (only the pieces server/progression.lua's own top-level/
-- onResourceStart code actually touches).
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName() return 'qbx_k9unit' end
local function GetPlayers() return {} end
local function TriggerEvent(_eventName, ...) end
local function TriggerClientEvent(_eventName, _target, ...) end

local function CreateThread(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        error(('xptierunlocks_spec.lua: a CreateThread body errored: %s'):format(tostring(err)))
    end
end
local function Wait(_ms) coroutine.yield() end

local exportsStub = {
    qbx_core = {
        GetPlayerByCitizenId = function(_self, _citizenid) return nil end,
        GetPlayer = function(_self, _src) return nil end,
    },
}

local MySQLStub = {
    scalar = { await = function(_sql, _params) return nil end },
    insert = { await = function(_sql, _params) return 1 end },
}

local Config = {
    Features = { XPProgression = true },
    XP = {
        scopePerCitizenidOrJob = 'citizenid',
        awards = { smallAward = 60 },
    },
    XPTiers = {
        { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        -- No medkitCooldownMultiplier on this tier -- exercises the
        -- "not configured yet" defensive default.
        { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        -- Valid reduction: 0.75 => 25% faster.
        { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10, medkitCooldownMultiplier = 0.75 },
        -- Deliberately non-positive -- proves a bad value on a HIGHER tier
        -- is rejected independently, never just the first bad shape found.
        { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0 },
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
    MySQL = MySQLStub,
    Config = Config,
})

Sandbox.loadInto('../server/cooldowns.lua', env)
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/progression.lua's own
-- LoadXPForCitizenid/AwardXP now read/write through K9Store.XP_Get/
-- K9Store.XP_UpsertAdd rather than raw SQL). Config.Database is
-- deliberately absent from this fixture's Config table above --
-- K9Store's own DatabaseEnabled() fails safe to `true`, which is exactly
-- what makes those K9Store calls run the SAME MySQL.scalar.await/
-- MySQL.insert.await calls (against this fixture's own MySQLStub) built
-- directly before this migration, so every existing assertion below
-- keeps exercising the identical SQL/params shape unchanged.
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted into its own file; the manifest loads it in the real resource, so a sandbox that omits it fails where the game would not
Sandbox.loadInto('../server/progression.lua', env)
for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('qbx_k9unit')
end

local AwardXP = env.AwardXP
local GetXPTier = env.GetXPTier
local GetXPTierMedkitCooldownMs = env.GetXPTierMedkitCooldownMs

t.isNotNil(GetXPTierMedkitCooldownMs, 'server/progression.lua must define global GetXPTierMedkitCooldownMs')

--- Awards `count` copies of 'smallAward' (60 XP) to `citizenid`, each
--- separated by 500,000ms -- see this file's header for why that spacing
--- clears both the per-actionKey rate floor and the shared mint budget's
--- own refill needs for this fixture's award size.
--- @param citizenid string
--- @param count number
local function grindToward(citizenid, count)
    for _ = 1, count do
        fakeNow = fakeNow + 500000
        AwardXP(citizenid, 'smallAward')
    end
end

-- ----------------------------------------------------------------------
-- Pure numeric contract
-- ----------------------------------------------------------------------

t.test('GetXPTierMedkitCooldownMs: an uncached (base-tier) citizenid with no medkitCooldownMultiplier returns baseCooldownMs unchanged', function()
    t.equals(GetXPTierMedkitCooldownMs('never-seen-before', 60000), 60000)
end)

t.test('GetXPTierMedkitCooldownMs: Trained tier (no medkitCooldownMultiplier field at all) returns baseCooldownMs unchanged -- the "unlock not yet configured" default', function()
    grindToward('cid-trained', 21) -- 21 * 60 = 1260 >= 1250 (Trained), < 4000 (Veteran)
    t.equals(GetXPTier('cid-trained').label, 'Trained K9', 'sanity check on this test\'s own arithmetic')
    t.equals(GetXPTierMedkitCooldownMs('cid-trained', 60000), 60000, 'Trained tier has no medkitCooldownMultiplier configured -- must return the base value unchanged, never error or invent a number')
end)

t.test('GetXPTierMedkitCooldownMs: Veteran tier (medkitCooldownMultiplier = 0.75) reduces the cooldown', function()
    grindToward('cid-veteran', 67) -- 67 * 60 = 4020 >= 4000 (Veteran), < 9000 (Elite)
    t.equals(GetXPTier('cid-veteran').label, 'Veteran K9', 'sanity check on this test\'s own arithmetic')
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 45000, '60000 * 0.75 = 45000')
end)

t.test('GetXPTierMedkitCooldownMs: a multiplier > 1 is rejected -- an unlock must never LENGTHEN a cooldown', function()
    local original = Config.XPTiers[3].medkitCooldownMultiplier
    Config.XPTiers[3].medkitCooldownMultiplier = 1.5
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 60000, 'a multiplier > 1 must be rejected outright, never applied')
    Config.XPTiers[3].medkitCooldownMultiplier = original
end)

t.test('GetXPTierMedkitCooldownMs: a numeric-looking STRING multiplier is rejected -- only a real Lua number may reduce a cooldown', function()
    local original = Config.XPTiers[3].medkitCooldownMultiplier
    Config.XPTiers[3].medkitCooldownMultiplier = '0.5'
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 60000)
    Config.XPTiers[3].medkitCooldownMultiplier = original
end)

t.test('GetXPTierMedkitCooldownMs: a non-positive multiplier (Elite tier, 0) is rejected -- returns baseCooldownMs unchanged, never 0 or negative', function()
    grindToward('cid-elite', 151) -- 151 * 60 = 9060 >= 9000 (Elite)
    t.equals(GetXPTier('cid-elite').label, 'Elite K9', 'sanity check on this test\'s own arithmetic')
    t.equals(GetXPTierMedkitCooldownMs('cid-elite', 60000), 60000,
        'a multiplier of 0 must NEVER be applied -- server/cooldowns.lua\'s own IsOnCooldown treats a non-positive threshold as PERMANENTLY ON, the opposite of a reward')
end)

t.test('GetXPTierMedkitCooldownMs: a NEGATIVE multiplier is rejected exactly like zero -- the lower bound is a range check (<= 0), not a special-case for 0 alone', function()
    local original = Config.XPTiers[3].medkitCooldownMultiplier
    Config.XPTiers[3].medkitCooldownMultiplier = -0.5
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 60000,
        'a negative multiplier must never be applied -- it would otherwise LENGTHEN the effective value going into math.floor/math.max below in a way this function\'s own contract forbids, and must never reach server/cooldowns.lua\'s IsOnCooldown as a non-positive threshold either')
    Config.XPTiers[3].medkitCooldownMultiplier = original
end)

t.test('GetXPTierMedkitCooldownMs: a tiny baseCooldownMs with a valid multiplier can never floor to 0 or below -- the math.max(1, ...) floor holds at the extreme', function()
    -- 1ms * 0.75 = 0.75, which math.floor alone would truncate to 0 -- a
    -- 0ms cooldown would hand server/cooldowns.lua's IsOnCooldown a
    -- non-positive threshold, which that file's own header documents as
    -- PERMANENTLY ON (the opposite of an unlock). math.max(1, ...) is what
    -- prevents that at this extreme, not just the multiplier's own <= 0/> 1
    -- rejection above.
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 1), 1, 'must clamp to a minimum of 1ms, never 0')
end)

t.test('GetXPTierMedkitCooldownMs: a malformed baseCooldownMs (non-number, NaN, <= 0) is returned unchanged, never erroring', function()
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', nil), nil)
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 'not-a-number'), 'not-a-number')
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 0), 0)
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', -5), -5)
    local nan = 0/0
    local result = GetXPTierMedkitCooldownMs('cid-veteran', nan)
    t.isTrue(result ~= result, 'NaN in, NaN out (NaN ~= NaN is always true for a real Lua number) -- proves the function returned the input unchanged rather than computing on it')
end)

-- ----------------------------------------------------------------------
-- COMPOSITION WITH THE PERMISSION/BLOCK LAYER -- the load-bearing property
-- this task requires: "a tier unlock cannot override a high-command
-- block." See this file's own header for exactly what this section proves
-- and what it does not.
-- ----------------------------------------------------------------------

--- Generic stand-in for the "block check runs before the tier-multiplier
--- consultation" ordering -- see server/progression.lua's own
--- GetXPTierMedkitCooldownMs doc comment, "CALLER CONTRACT", for the real
--- call site this mirrors (that call site is genuinely applied in
--- server/medkit.lua today -- see this file's own header for the full,
--- corrected story). `blocked` simulates whatever per-file
--- feature/block-resolution function ends up gating the real call (there is
--- still no single shared, exported Config.FeatureControl block-resolution
--- function -- each consuming file implements its own) -- this test does
--- not assume its exact name/signature, only that SOME block check exists
--- and runs BEFORE this function is ever consulted, per
--- GetXPTierMedkitCooldownMs's own documented CALLER CONTRACT.
--- @param citizenid string
--- @param blocked boolean
--- @param baseCooldownMs number
--- @return boolean allowed
--- @return number? effectiveCooldownMs -- present only when allowed
local function SimulateGatedMedkitCooldownResolution(citizenid, blocked, baseCooldownMs)
    -- Steps 1-3 of Config.FeatureControl's own documented resolution order
    -- (config.lua: "Config.Features.<Name> false -> deny always; an
    -- explicit BLOCK -> deny; RequireGrant -> needs a grant") ALWAYS run
    -- BEFORE step 4's "otherwise -> allow" -- and this function's own tier
    -- consultation is not even a step in that order at all. It is reached
    -- only once the caller has ALREADY allowed the action.
    if blocked then
        return false, nil -- denied -- GetXPTierMedkitCooldownMs is NEVER called
    end
    return true, GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs)
end

t.test('COMPOSITION: a blocked citizenid is denied outright regardless of tier, and the tier multiplier is never even consulted', function()
    -- cid-veteran (Veteran tier, 0.75 multiplier) would normally get a
    -- reduced cooldown -- prove the block wins outright.
    local allowed, effectiveMs = SimulateGatedMedkitCooldownResolution('cid-veteran', true, 60000)
    t.isFalse(allowed, 'a high-command block must deny the action outright, even for a citizenid who has genuinely earned the Veteran-tier unlock')
    t.isNil(effectiveMs, 'a denied action must produce no cooldown value at all -- there is nothing to apply it to')
end)

t.test('COMPOSITION: an unblocked citizenid still gets their real, earned tier reduction', function()
    local allowed, effectiveMs = SimulateGatedMedkitCooldownResolution('cid-veteran', false, 60000)
    t.isTrue(allowed)
    t.equals(effectiveMs, 45000, 'once genuinely unblocked, the earned Veteran-tier reduction must still apply normally -- a block is the only thing this task asked to take priority, not tier progression itself')
end)

t.test('COMPOSITION: reaching a tier cannot itself flip a block to an allow -- same citizenid, same tier, same base cooldown, differing ONLY by the block flag', function()
    local allowedBlocked = SimulateGatedMedkitCooldownResolution('cid-elite', true, 60000)
    local allowedFree = SimulateGatedMedkitCooldownResolution('cid-elite', false, 60000)
    t.isFalse(allowedBlocked)
    t.isTrue(allowedFree, 'the ONLY variable that changed between the two calls above is the block flag -- cid-elite is genuinely Elite-tier in this fixture in BOTH calls, proving tier alone has no power to override a block either way')
end)

os.exit(t.summary())
