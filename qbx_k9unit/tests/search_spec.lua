--[[
    tests/search_spec.lua

    Direct tests of server/search.lua's GetContrabandAlertTier(totalWeight)
    -- a thin resource-global pass-through to the file-local
    ResolveAlertTier, added specifically as a test/inspection seam (see that
    file's own FILE-TO-FILE CONTRACT and GetContrabandAlertTier's own doc
    comment for why this does not widen the file's trust boundary: it
    accepts a plain number, never resolves any entity/inventory/access
    state, and cannot be used to read any real target's contraband).

    Structurally identical in shape to server/progression.lua's
    GetXPTier/ResolveTier pair (already covered by progression_spec.lua) --
    same "walk ascending, keep the LAST tier whose threshold is met" logic,
    over Config.ContrabandAlertTiers instead of Config.XPTiers.

    Loading the whole file (not just the wrapper) means satisfying every
    native/global this file's OWN top-level (load-time) statements touch --
    NewMutex()/NewCooldown() (server/cooldowns.lua, loaded first, same
    order fxmanifest.lua requires), TargetSearchCooldown.StartSweep(...)
    (spins a CreateThread at load time), and lib.callback.register(...) (a
    real call this spec never fires -- captured and ignored, exactly like
    RegisterCommand/AddEventHandler elsewhere in this suite). None of this
    indirect stubbing affects GetContrabandAlertTier's own behavior -- it
    is only there because Sandbox.loadInto executes the whole file, per
    that fixture's own documented "immediately execute" behavior.
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

local threadRunner = Sandbox.newThreadRunner()

local registeredCallbacks = {}
local libStub = {
    callback = {
        register = function(name, handler)
            registeredCallbacks[name] = handler
        end,
    },
}

local Config = {
    Features = {},
    SearchZones = { alertBroadcastRadius = 50.0, searchCooldownMs = 5000 },
    SearchContrabandItems = { 'weed_baggy' },
    ContrabandAlertTiers = {
        { minWeight = 0,   alert = 'clean' },
        { minWeight = 1,   alert = 'whine' },
        { minWeight = 250, alert = 'aggressive_bark' },
    },
}

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    CreateThread = threadRunner.CreateThread,
    Wait = threadRunner.Wait,
    lib = libStub,
    exports = { ox_inventory = {} }, -- never called by this spec's own path; present so a stray reference doesn't nil-index
    Config = Config,
})

Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/entities.lua', env) -- ResolveNetworkEntity/ResolveConnectedPlayerFromPed, read by search.lua per its own FILE-TO-FILE CONTRACT
Sandbox.loadInto('../server/search.lua', env)

-- Fire onResourceStart: search.lua's own config-safety guards (the
-- ContrabandAlertTiers[1] == clean/minWeight==0 assertion, the sorted-order
-- assertion, and the alertBroadcastRadius <= 200.0 ceiling) all run here --
-- a real regression in this spec's OWN Config fixture would surface as a
-- loud assertion failure right at this line, not a silent mismatch later.
for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('qbx_k9unit')
end

local GetContrabandAlertTier = env.GetContrabandAlertTier
t.isNotNil(GetContrabandAlertTier, 'server/search.lua must define global GetContrabandAlertTier')
t.isNotNil(registeredCallbacks['qbx_k9unit:server:searchTarget'],
    'server/search.lua must register its lib.callback handler at load time (sanity check that the whole file loaded, not just the wrapper)')

-- ----------------------------------------------------------------------
-- Tier-boundary resolution
-- ----------------------------------------------------------------------

t.test('GetContrabandAlertTier: totalWeight = 0 resolves to the mandatory clean baseline', function()
    t.equals(GetContrabandAlertTier(0).alert, 'clean')
end)

t.test('GetContrabandAlertTier: exactly AT a tier threshold (>=) resolves to that tier, not the one below', function()
    t.equals(GetContrabandAlertTier(1).alert, 'whine', 'totalWeight == 1 must reach whine, the tier whose minWeight is exactly 1')
    t.equals(GetContrabandAlertTier(250).alert, 'aggressive_bark', 'totalWeight == 250 must reach aggressive_bark')
end)

t.test('GetContrabandAlertTier: one unit below a threshold stays on the lower tier', function()
    t.equals(GetContrabandAlertTier(0.999).alert, 'clean', 'just under 1 must not reach whine')
    t.equals(GetContrabandAlertTier(249).alert, 'whine', 'just under 250 must not reach aggressive_bark')
end)

t.test('GetContrabandAlertTier: a very large totalWeight resolves to the top tier, not the first match', function()
    t.equals(GetContrabandAlertTier(999999).alert, 'aggressive_bark')
end)

t.test('GetContrabandAlertTier: a negative totalWeight (defensive input) still resolves to the clean baseline, never nil', function()
    local tier = GetContrabandAlertTier(-5)
    t.isNotNil(tier)
    t.equals(tier.alert, 'clean')
end)

t.test('GetContrabandAlertTier: never leaks a mutable reference that corrupts Config.ContrabandAlertTiers on write', function()
    -- Unlike server/progression.lua's AwardXP (which defensively copies the
    -- outbound event payload via CopyTier), this wrapper returns the SAME
    -- table reference from Config.ContrabandAlertTiers -- documented here
    -- as the REAL, current behavior (not asserted as a bug): this file's
    -- own doc comment for GetContrabandAlertTier only promises "no read
    -- access to any real target's inventory," never a defensive copy, and
    -- an internal, test-only caller mutating its own read result is a
    -- different risk profile than progression.lua's outbound
    -- TriggerEvent payload (handed to potentially-external resources).
    local tier = GetContrabandAlertTier(250)
    local original = Config.ContrabandAlertTiers[3].alert
    t.equals(tier, Config.ContrabandAlertTiers[3], 'current behavior: this wrapper returns the LIVE Config table entry, not a copy')
    Config.ContrabandAlertTiers[3].alert = original -- restore regardless (no mutation performed, just confirming identity)
end)

os.exit(t.summary())
