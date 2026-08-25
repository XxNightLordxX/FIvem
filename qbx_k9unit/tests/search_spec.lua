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

-- server/search.lua's k9_search_log audit write runs inside its own ONE-SHOT
-- CreateThread(...) (silent-failure fix: MySQL.insert.await instead of a
-- callback-less MySQL.insert -- see that function's own SILENT-FAILURE FIX
-- comment). Sandbox.newThreadRunner's own CreateThread only CAPTURES a thread
-- for a later runner.step(), and this spec never calls step() -- so handing
-- that one-shot write to it would leave it never resumed and the audit row
-- never written, failing the assertions below for a pure harness reason
-- rather than a real one. Mirror tests/progression_spec.lua's own inlined
-- CreateThread instead: create the coroutine and resume it ONCE right away,
-- so a one-shot body (no Wait()) runs to completion on that single resume,
-- exactly as FXServer's real CreateThread would. A recurring
-- `while true do Wait(...) end` body (server/cooldowns.lua's load-time sweep)
-- still yields at its first Wait and is simply left parked there -- the same
-- place threadRunner.CreateThread left it before, since step() is never
-- called here either way. Wait still comes from threadRunner.
local function CreateThread(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        error(('search_spec.lua: a CreateThread body errored: %s'):format(tostring(err)))
    end
end

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
    -- COMPAT-LAYER MIGRATION (coder-backend, this pass): pins the
    -- 'inventory' system straight to 'ox_inventory' via `override`
    -- (shared/compat/core.lua's TIER 1, skipping the candidate-scanning
    -- walk). The other four systems get empty-but-present tables so
    -- DetectSystem's own "missing or malformed" warning never fires.
    Compat = {
        diagnosticCommand = false,
        Systems = {
            inventory = { override = 'ox_inventory' },
            target = {}, framework = {}, dispatch = {}, ambulance = {},
        },
    },
}

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    CreateThread = CreateThread,
    Wait = threadRunner.Wait,
    lib = libStub,
    -- COMPAT-LAYER MIGRATION (this pass): server/search.lua's
    -- GetContainerFromSlot/GetInventoryItems calls are now routed through
    -- `K9Compat.Get('inventory')` -- shared/compat/inventory.lua's
    -- BuildOxInventoryServer requires ALL SEVEN server-realm methods
    -- present as callable exports before it returns ANYTHING.
    -- GetInventoryItems is reassigned to a real recording stub further
    -- below (this section's own tests populate it); the other five
    -- (GetContainerFromSlot/GetItemCount/RemoveItem/RegisterStash/
    -- RegisterShop -- never called by server/search.lua at all, except
    -- GetContainerFromSlot which this section's own tests never populate a
    -- nested container for) are harmless no-ops purely so capability
    -- verification passes.
    exports = {
        ox_inventory = {
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            RegisterShop = function() return true end,
            registerHook = function() return 1 end,
        },
    },
    Config = Config,
    -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
    -- always reports 'started'.
    IsDuplicityVersion = function() return true end,
    GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
})

Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/entities.lua', env) -- ResolveNetworkEntity/ResolveConnectedPlayerFromPed, read by search.lua per its own FILE-TO-FILE CONTRACT
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/search.lua's own audit-log
-- write now reads through K9Store.SearchLog_Insert rather than a raw
-- `MySQL.insert.await` call). Config.Database is deliberately absent from
-- this fixture's Config table above -- K9Store's own DatabaseEnabled()
-- fails safe to `true` (real-DB mode) on a missing Config.Database, which
-- is exactly what makes SearchLog_Insert below run the SAME
-- MySQL.insert.await call (against `env.MySQL`, assigned further down
-- this file) that the audit write built directly before this migration,
-- so every existing assertion below keeps exercising the identical
-- SQL/params shape unchanged. See tests/admin_spec.lua for the precedent
-- this comment mirrors.
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
-- COMPAT-LAYER MIGRATION (this pass): server/search.lua's
-- GetContainerFromSlot/GetInventoryItems calls are now routed through
-- `K9Compat.Get('inventory')` -- load the REAL, unmodified
-- shared/compat/core.lua + shared/compat/inventory.lua first (never a
-- hand-written fake translation layer).
Sandbox.loadInto('../shared/compat/core.lua', env)
Sandbox.loadInto('../shared/compat/inventory.lua', env)
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

-- ----------------------------------------------------------------------
-- HandleSearchTarget / searchTarget callback -- full end-to-end drive,
-- ContrabandXpMintCooldown gate (coder-backend, XP-farm-audit pass).
--
-- Everything above this point only ever exercised the pure
-- GetContrabandAlertTier seam. This section additionally stubs every
-- native/export HandleSearchTarget's own VEHICLE branch touches
-- (ResolveNetworkEntity's own natives via server/entities.lua, already
-- loaded above; GetVehicleNumberPlateText; GetPlayerPed/GetEntityCoords,
-- backed by a minimal vector3-with-metatables so `#(a - b)` behaves exactly
-- like the real FXServer vector3 type for the purposes of the proximity
-- check; exports.ox_inventory.GetInventoryItems; exports.qbx_core.GetPlayer;
-- MySQL.insert; TriggerEvent/TriggerClientEvent; AwardXP) so the REAL
-- 'qbx_k9unit:server:searchTarget' callback captured above can be invoked
-- end-to-end, never a re-implementation of its logic. Only the 'vehicle'
-- targetType is driven (the 'person' branch's extra
-- ResolveConnectedPlayerFromPed step is orthogonal to the XP-mint gate this
-- section tests and adds no coverage value here).
-- ----------------------------------------------------------------------

local function vec3(x, y, z)
    local v = { x = x, y = y, z = z }
    return setmetatable(v, {
        __sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __len = function(self) return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end,
    })
end
local ZERO_VEC = vec3(0, 0, 0)

local awardCalls = {}
local mysqlInsertCount = 0
local triggerEventCount = 0
local triggerClientEventCount = 0
local currentItemsByInvId = {}

env.HasK9Access = function() return true end
env.NetworkGetEntityFromNetworkId = function(netId) return netId end -- identity mapping: this section's fake "entity handle" IS the netId
env.DoesEntityExist = function(entity) return entity ~= 0 end
env.GetEntityType = function(_entity) return 2 end -- every entity in this section is a vehicle
env.GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end
env.GetPlayerPed = function(_source) return 42 end -- fixed nonzero ped handle for every source; irrelevant to the proximity math below since GetEntityCoords is constant for every handle
env.GetEntityCoords = function(_entity) return ZERO_VEC end -- every entity (requester ped AND searched vehicle) reports the same coords -- proximity distance is always 0, well under any maxDistance/alertBroadcastRadius configured below
env.GetPlayers = function() return { '501' } end -- one fixed bystander id for BroadcastContrabandAlert's own loop, resolved via the same fixed GetPlayerPed stub above
env.TriggerEvent = function(_eventName, ...) triggerEventCount = triggerEventCount + 1 end -- FireOutboundEvent's outbound 'qbx_k9unit:events:searchCompleted'
env.TriggerClientEvent = function(eventName, _playerId, ...)
    if eventName == 'qbx_k9unit:client:playContrabandAlert' then
        triggerClientEventCount = triggerClientEventCount + 1
    end
end
env.MySQL = { insert = { await = function(_sql, _params) mysqlInsertCount = mysqlInsertCount + 1; return 1 end } } -- .await shape: search.lua's audit write is now CreateThread + MySQL.insert.await (silent-failure fix), not a callback-less MySQL.insert
env.AwardXP = function(citizenid, actionKey) awardCalls[#awardCalls + 1] = { citizenid = citizenid, actionKey = actionKey } end

local exportsStub = env.exports
exportsStub.ox_inventory.GetInventoryItems = function(_self, invOrId)
    local invId = type(invOrId) == 'table' and invOrId.id or invOrId
    return currentItemsByInvId[invId] or {}
end
exportsStub.qbx_core = {
    GetPlayer = function(_self, source)
        return { PlayerData = { citizenid = 'CITIZEN' .. tostring(source), job = { name = 'police' } } }
    end,
}

-- Config for this section only -- overrides/extends the shared Config table
-- above. Values chosen to make TargetSearchCooldown/SearchCooldown (both
-- 10ms) trivially clearable by advancing `fakeNow` a little, so the ONLY
-- meaningful throttle left in play across this section's test timeline is
-- CONTRABAND_XP_MINT_COOLDOWN_MS (60000ms, a server/search.lua file-local
-- constant, never read from Config -- see that constant's own declaration
-- comment for why).
Config.Features.SearchZones = true
Config.Features.XPProgression = true
Config.Features.ContrabandAlerts = true -- so this section can also assert the alert broadcast keeps firing independently of the XP-mint gate below
Config.SearchZones.sniffAnimDurationMs = 10
Config.SearchZones.searchCooldownMs = 10 -- overrides the 5000 set above -- this section's own per-target cooldown, not the XP mint gate
Config.SearchZones.vehicleSearchDistance = 100.0
Config.SearchZones.personSearchDistance = 100.0
Config.XP = { awards = { searchContrabandFound = 25 } }

local searchTargetCallback = registeredCallbacks['qbx_k9unit:server:searchTarget']

--- Drives one full 'vehicle' searchTarget call. `netId` doubles as this
--- section's fake resolved entity handle (see NetworkGetEntityFromNetworkId
--- stub above) and feeds GetVehicleNumberPlateText's stub, so each distinct
--- netId is a distinct, independently-cooldown-tracked vehicle identity.
--- @param source number
--- @param netId number
--- @param weight number -- 0/nil = an empty trunk (contrabandFound = false); > 0 = one 'weed_baggy' slot of exactly this weight
--- @return table result -- the real HandleSearchTarget return value
local function searchVehicle(source, netId, weight)
    local invId = 'trunkPLATE' .. tostring(netId)
    if weight and weight > 0 then
        currentItemsByInvId[invId] = { { name = 'weed_baggy', weight = weight, slot = 1 } }
    else
        currentItemsByInvId[invId] = {}
    end
    return searchTargetCallback(source, 'vehicle', netId)
end

t.test('a fresh target always pays on its first find, and the search/audit/alert side effects all fire', function()
    fakeNow = 0
    local mysqlBefore, triggerBefore, alertBefore = mysqlInsertCount, triggerEventCount, triggerClientEventCount
    local result = searchVehicle(501, 1001, 10)
    t.isTrue(result.ok, 'a valid, in-range, first-ever search of this target must succeed')
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 10, 'the requester must see the real, current weight')
    t.equals(#awardCalls, 1)
    t.equals(awardCalls[1].actionKey, 'searchContrabandFound')
    t.equals(mysqlInsertCount, mysqlBefore + 1, 'k9_search_log audit row must be written')
    t.equals(triggerEventCount, triggerBefore + 1, 'the qbx_k9unit:events:searchCompleted outbound event must fire')
    t.equals(triggerClientEventCount, alertBefore + 1, 'the contraband alert broadcast must fire for a non-clean tier')
end)

t.test('CONSTRAINT CHECK: toggling the weight while the mint cooldown is still active still returns a fully normal search/alert/audit -- only the XP mint is withheld', function()
    fakeNow = 1000 -- clears the 10ms sniff/target cooldowns; nowhere near the 60000ms mint cooldown armed at fakeNow=0 by the previous test
    local mysqlBefore, triggerBefore, alertBefore, awardsBefore = mysqlInsertCount, triggerEventCount, triggerClientEventCount, #awardCalls
    local result = searchVehicle(501, 1001, 20) -- toggled: weight changed 10 -> 20, exactly the solo-farm exploit shape this gate closes
    t.isTrue(result.ok, 'search itself must keep succeeding while the XP mint is on cooldown')
    t.isTrue(result.contrabandFound, 'contraband must still be reported to the requester')
    t.equals(result.totalWeight, 20, 'the requester must still see the real, current (changed) weight -- never withheld alongside the XP')
    t.equals(#awardCalls, awardsBefore, 'no additional AwardXP call: the per-searcher mint cooldown blocks a second real weight-changed find inside its window')
    t.equals(mysqlInsertCount, mysqlBefore + 1, 'the k9_search_log audit row must still be written for this attempt even though XP was withheld')
    t.equals(triggerEventCount, triggerBefore + 1, 'the outbound searchCompleted event must still fire')
    t.equals(triggerClientEventCount, alertBefore + 1, 'the contraband alert broadcast must still fire -- this gate must never touch it')
end)

t.test('past the mint cooldown window, the still-differing weight now pays -- the earlier skipped attempt was never silently treated as paid', function()
    fakeNow = 61000 -- 61s after the FIRST award at fakeNow=0, past CONTRABAND_XP_MINT_COOLDOWN_MS (60000ms)
    local awardsBefore = #awardCalls
    local result = searchVehicle(501, 1001, 20) -- same weight as the BLOCKED attempt above (20), but still differs from the last PAID weight (10)
    t.isTrue(result.ok)
    t.equals(result.totalWeight, 20)
    t.equals(#awardCalls, awardsBefore + 1, 'ContrabandXpState was correctly left unupdated by the skipped attempt, so this still reads as "changed since last PAID weight" and pays once the mint cooldown allows')
end)

t.test('immediately toggling again right after that payout is blocked by the freshly re-armed mint cooldown', function()
    fakeNow = 61010
    local awardsBefore = #awardCalls
    local result = searchVehicle(501, 1001, 30)
    t.isTrue(result.ok)
    t.equals(result.totalWeight, 30)
    t.equals(#awardCalls, awardsBefore, 'freshly re-armed at fakeNow=61000 by the previous payout; another payout this soon must be blocked again')
end)

t.test('an unchanged-weight repeat never spends the mint budget: a later real change still pays at exactly the ORIGINAL cooldown expiry, not a later one', function()
    fakeNow = 0
    local netId = 2002
    local awardsBefore = #awardCalls
    local first = searchVehicle(502, netId, 5)
    t.isTrue(first.ok)
    t.equals(#awardCalls, awardsBefore + 1, 'first-ever find on this fresh target pays')

    -- Three unchanged-weight re-searches at various points inside the mint
    -- cooldown window the award above just opened. None of these should pay
    -- (weight never changed since the last PAID weight) -- and, if the
    -- ordering in server/search.lua's AwardXP block is correct (weight-
    -- changed check BEFORE ContrabandXpMintCooldown.Consume), none of them
    -- should re-arm/extend that cooldown either.
    fakeNow = 50
    searchVehicle(502, netId, 5)
    fakeNow = 100
    searchVehicle(502, netId, 5)
    fakeNow = 59000
    searchVehicle(502, netId, 5)
    t.equals(#awardCalls, awardsBefore + 1, 'no unchanged-weight repeat may ever pay')

    -- Exactly one tick past the ORIGINAL mint cooldown (armed at fakeNow=0,
    -- +60000ms), a real weight change arrives. If any of the three no-op
    -- searches above had incorrectly re-touched the mint cooldown, this
    -- would still read as blocked (not expiring until 59000+60000=119000).
    -- It must instead have expired at exactly fakeNow=60000.
    fakeNow = 60001
    local changed = searchVehicle(502, netId, 15)
    t.isTrue(changed.ok)
    t.equals(changed.totalWeight, 15)
    t.equals(#awardCalls, awardsBefore + 2,
        'a real weight change must pay exactly when the cooldown opened by the FIRST award expires -- proves the unchanged-weight repeats above never extended it')
end)

t.test("the mint cooldown is keyed by the SEARCHER, not the target: a second, different officer is never blocked by the first officer's own budget", function()
    fakeNow = 0
    local netId = 5005
    local awardsBefore = #awardCalls
    local resultA = searchVehicle(701, netId, 8) -- officer 701's first paid find on this fresh target
    t.isTrue(resultA.ok)
    t.equals(#awardCalls, awardsBefore + 1)

    fakeNow = 20 -- clears the 10ms target/sniff cooldowns; nowhere near officer 701's own 60000ms mint cooldown
    local resultB = searchVehicle(702, netId, 9) -- a DIFFERENT officer, weight genuinely changed since the last PAID weight (8 -> 9)
    t.isTrue(resultB.ok)
    t.equals(#awardCalls, awardsBefore + 2, "a second, different officer must not be blocked by the first officer's own per-searcher mint cooldown")
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

t.test('SILENT-FAILURE FIX: a k9_search_log audit INSERT that genuinely FAILS is caught and logged, never propagated into the search result', function()
    -- Pins server/search.lua's LogSearchAttempt silent-failure fix. That write
    -- moved from a decorative `pcall(MySQL.insert, ...)` (fire-and-forget: the
    -- pcall returns before the query runs, so a real SQL failure could never
    -- reach it) to `CreateThread(function() pcall(MySQL.insert.await, ...) end)`,
    -- which DOES surface a genuine query error. This test drives that newly-real
    -- error path with the four failure shapes a live MySQL/MariaDB actually
    -- returns for this INSERT -- 1146 (k9_search_log missing: install.sql or a
    -- migration never applied), 1265 (an ENUM value drift on result/target_type),
    -- and 1406 (an over-length target_plate/alert_tier) -- and asserts the fix
    -- kept its OTHER half of the contract: a logging failure must still never
    -- surface as, or cause, a search failure for the requesting officer. Without
    -- the pcall this raises straight out of the callback and result.ok is nil.
    fakeNow = 10000000 -- far past every cooldown window any test above armed; this test runs LAST so it never moves the clock backwards for another test
    local realInsert = env.MySQL.insert
    for _, sqlError in ipairs({
        "ERROR 1146 (42S02): Table 'k9.k9_search_log' doesn't exist",
        "ERROR 1265 (01000): Data truncated for column 'result' at row 1",
        "ERROR 1406 (22001): Data too long for column 'target_plate' at row 1",
        "ERROR 1406 (22001): Data too long for column 'alert_tier' at row 1",
    }) do
        env.MySQL.insert = { await = function(_sql, _params) error(sqlError, 0) end }
        local triggerBefore = triggerEventCount
        local ok, result = pcall(searchVehicle, 501, 3003, 15)
        t.isTrue(ok, 'a failing audit INSERT must never raise out of the searchTarget callback: ' .. sqlError)
        t.isTrue(result.ok, 'the search itself must still succeed and report normally despite the audit write failing: ' .. sqlError)
        t.equals(result.totalWeight, 15, 'the requester must still get the real weight even though the audit row was lost')
        t.equals(triggerEventCount, triggerBefore + 1, 'the outbound searchCompleted event must still fire after a failed audit write')
        fakeNow = fakeNow + 100000 -- fresh window for the next iteration's own search
    end
    env.MySQL.insert = realInsert
end)

-- ============================================================================
-- EIGHTH XP-FARM FIX: cross-file integration -- proves server/progression.lua's
-- new SHARED cross-mechanic XP mint budget genuinely binds through THIS
-- file's own real, unmodified 'qbx_k9unit:server:searchTarget' callback, not
-- just via a directly-called AwardXP the way tests/progression_spec.lua's
-- own coverage already does. Everything above this point in this file stubs
-- AwardXP directly (see this file's own header) -- this section is the one
-- place that loads the REAL server/progression.lua alongside the REAL
-- server/search.lua in the SAME sandbox, so a contraband find that goes
-- through search.lua's OWN validation/cooldown/weight-changed logic still
-- has its XP withheld by the budget when that budget is already spent,
-- while every other side effect (the search result itself, the audit log,
-- the alert broadcast) keeps firing normally -- exactly the "gate the mint,
-- never the mechanic" property this pass's own report documents for every
-- other mechanic. Deliberately a FRESH, independent sandbox (own Config, own
-- fake clock) rather than reusing this file's shared `env` above, so it
-- cannot perturb any of the 13 tests already passing against that shared
-- state.
-- ============================================================================

local function newSearchPlusProgressionFixture()
    local fakeNow2 = 0
    local function GetGameTimer2() return fakeNow2 end

    local eventHandlers2 = {}
    local function AddEventHandler2(eventName, handler)
        eventHandlers2[eventName] = eventHandlers2[eventName] or {}
        eventHandlers2[eventName][#eventHandlers2[eventName] + 1] = handler
    end

    local function GetCurrentResourceName2() return 'qbx_k9unit' end

    local threadRunner2 = Sandbox.newThreadRunner()

    local registeredCallbacks2 = {}
    local libStub2 = { callback = { register = function(name, handler) registeredCallbacks2[name] = handler end } }

    local playerByCitizenId2 = {}
    local playersBySource2 = {}
    -- COMPAT-LAYER MIGRATION (this pass): see this file's shared `env`
    -- section above for the full "why all seven server-realm methods" writeup.
    local exportsStub2 = {
        ox_inventory = {
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            RegisterShop = function() return true end,
            registerHook = function() return 1 end,
        },
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource2[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId2[citizenid] end,
        },
    }

    local MySQLStub2 = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    local onlineIds2 = {}
    local function GetPlayers2()
        local out = {}
        for id in pairs(onlineIds2) do out[#out + 1] = tostring(id) end
        return out
    end

    -- REAL Config.XP.awards -- just the one mechanic this integration test
    -- needs (searchContrabandFound = 25, matching config.lua exactly) --
    -- XP_MINT_BUDGET_STARTER_TOKENS (server/progression.lua) will compute as
    -- exactly 25 from this table, so a single 25-XP award drains it to
    -- precisely 0 in one call -- see the test below for why that is useful.
    local Config2 = {
        Features = { SearchZones = true, XPProgression = true, ContrabandAlerts = false },
        SearchZones = {
            alertBroadcastRadius = 50.0, searchCooldownMs = 10, sniffAnimDurationMs = 10,
            vehicleSearchDistance = 100.0, personSearchDistance = 100.0,
        },
        SearchContrabandItems = { 'weed_baggy' },
        ContrabandAlertTiers = {
            { minWeight = 0, alert = 'clean' },
            { minWeight = 1, alert = 'whine' },
        },
        XP = {
            scopePerCitizenidOrJob = 'citizenid',
            awards = { searchContrabandFound = 25 },
        },
        XPTiers = {
            { xp = 0, label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        },
        -- COMPAT-LAYER MIGRATION (this pass): see this file's shared Config
        -- section above for the full writeup.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env2 = Sandbox.newEnv({
        GetGameTimer = GetGameTimer2,
        AddEventHandler = AddEventHandler2,
        GetCurrentResourceName = GetCurrentResourceName2,
        GetPlayers = GetPlayers2,
        CreateThread = threadRunner2.CreateThread,
        Wait = threadRunner2.Wait,
        lib = libStub2,
        exports = exportsStub2,
        MySQL = MySQLStub2,
        TriggerEvent = function(_eventName, ...) end,
        TriggerClientEvent = function(_eventName, _target, ...) end,
        HasK9Access = function() return true end,
        NetworkGetEntityFromNetworkId = function(netId) return netId end,
        DoesEntityExist = function(entity) return entity ~= 0 end,
        GetEntityType = function(_entity) return 2 end, -- vehicle, same convention as this file's shared section above
        GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end,
        GetPlayerPed = function(_source) return 42 end,
        GetEntityCoords = function(_entity) return ZERO_VEC end,
        Config = Config2,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
        -- always reports 'started'.
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env2)
    Sandbox.loadInto('../server/entities.lua', env2)
    -- server/datastore.lua -- REAL, unmodified, loaded alongside (see this
    -- file's own top-of-file loadInto comment above for the full
    -- reasoning). server/progression.lua's own AwardXP/LoadXPForCitizenid
    -- now read/write through K9Store.XP_Get/K9Store.XP_UpsertAdd rather
    -- than raw SQL; Config2.Database is deliberately absent, so
    -- DatabaseEnabled() fails safe to `true` and those calls forward
    -- straight through to MySQLStub2 exactly as before this migration.
    Sandbox.loadInto('../server/datastore.lua', env2)
    Sandbox.loadInto('../server/progression.lua', env2)
    Sandbox.loadInto('../server/events.lua', env2) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    -- COMPAT-LAYER MIGRATION (this pass): see this file's shared `env`
    -- section above for the full writeup.
    Sandbox.loadInto('../shared/compat/core.lua', env2)
    Sandbox.loadInto('../shared/compat/inventory.lua', env2)
    Sandbox.loadInto('../server/search.lua', env2)
    for _, handler in ipairs(eventHandlers2['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    local searchCallback2 = registeredCallbacks2['qbx_k9unit:server:searchTarget']
    local itemsByInvId2 = {}
    exportsStub2.ox_inventory.GetInventoryItems = function(_self, invOrId)
        local invId = type(invOrId) == 'table' and invOrId.id or invOrId
        return itemsByInvId2[invId] or {}
    end

    return {
        AwardXP = env2.AwardXP,
        GetXP = env2.GetXP,
        setNow = function(ms) fakeNow2 = ms end,
        now = function() return fakeNow2 end,
        runOneTick = function()
            if not threadRunner2.primed then threadRunner2.step(); threadRunner2.primed = true end
            threadRunner2.step()
        end,
        setPlayer = function(source, citizenid)
            playersBySource2[source] = { PlayerData = { citizenid = citizenid, job = { name = 'police' } } }
            playerByCitizenId2[citizenid] = { PlayerData = { citizenid = citizenid, source = source } }
            onlineIds2[source] = true
        end,
        --- Drives one full REAL 'vehicle' searchTarget call, exactly mirroring
        --- this file's own top-level searchVehicle helper, against THIS
        --- fixture's own fresh callback/state instead of the shared one.
        --- @param source number
        --- @param netId number
        --- @param weight number
        searchVehicle = function(source, netId, weight)
            local invId = 'trunkPLATE' .. tostring(netId)
            itemsByInvId2[invId] = weight and weight > 0 and { { name = 'weed_baggy', weight = weight, slot = 1 } } or {}
            return searchCallback2(source, 'vehicle', netId)
        end,
    }
end

t.test('EIGHTH XP-FARM FIX (cross-file integration): a real search find through the REAL, unmodified searchTarget callback still succeeds normally when the shared XP mint budget is already spent -- only the XP is withheld', function()
    local f = newSearchPlusProgressionFixture()
    local citizenid = 'CITIZEN-COMPOUND-FARM'
    f.setPlayer(501, citizenid)

    -- Drain the shared budget directly via the REAL AwardXP (standing in for
    -- "this citizenid already spent it via bite-hold/takedown/tracking
    -- elsewhere this hour" -- server/combat.lua/tracking.lua are not loaded
    -- in this sandbox, but AwardXP is the SAME single chokepoint every one
    -- of them goes through, so calling it directly here is calling the real
    -- gate, not a re-implementation of it). XP_MINT_BUDGET_STARTER_TOKENS
    -- computes to exactly 25 from this fixture's own Config.XP.awards (see
    -- newSearchPlusProgressionFixture's own comment), so one 25-XP award
    -- drains it to precisely 0 with negligible elapsed time.
    f.setNow(0)
    f.AwardXP(citizenid, 'searchContrabandFound')
    t.equals(f.GetXP(citizenid), 25, 'sanity check: the direct drain call itself must pay (this citizenid has never earned anything before it)')

    -- Advance past AwardXPCooldown's OWN pre-existing 500ms-per-
    -- (citizenid,actionKey) floor (server/progression.lua) before the real
    -- search below -- NOT the mechanism this test means to isolate. Without
    -- this, the search callback's own internal AwardXP('searchContrabandFound')
    -- call would be blocked by THAT floor instead of by the shared budget,
    -- making this test pass for the wrong reason. 600ms leaves the shared
    -- budget's own refill at a negligible ~0.6 XP -- nowhere near enough to
    -- cover the 25-XP find below, so the shared budget is still the thing
    -- actually being exercised.
    f.setNow(600)

    -- Now drive a GENUINE, fresh, first-ever find through the REAL
    -- searchTarget callback -- a different target, a real weight, every one
    -- of server/search.lua's own gates (HasK9Access, proximity, cooldowns,
    -- the weight-changed check, ContrabandXpMintCooldown) passes on its own
    -- terms. The shared budget is still, for all practical purposes, at 0
    -- tokens.
    local result = f.searchVehicle(501, 9001, 20)
    t.isTrue(result.ok, 'the search request itself must still succeed -- the shared budget must never block the MECHANIC, only the mint')
    t.isTrue(result.contrabandFound, 'contraband must still be reported to the requester')
    t.equals(result.totalWeight, 20, 'the requester must still see the real, current weight')
    t.equals(f.GetXP(citizenid), 25, 'no additional XP may be granted -- the shared budget (server/progression.lua) correctly withheld this genuine find\'s XP because it is already fully spent, even though search.lua\'s OWN per-mechanic gates (ContrabandXpMintCooldown, the weight-changed check) all independently passed')
end)

t.test('EIGHTH XP-FARM FIX (cross-file integration): once the shared budget has refilled, the SAME kind of real search find pays normally again', function()
    local f = newSearchPlusProgressionFixture()
    local citizenid = 'CITIZEN-COMPOUND-FARM-2'
    f.setPlayer(501, citizenid)

    f.setNow(0)
    f.AwardXP(citizenid, 'searchContrabandFound') -- drains to exactly 0, same as above
    t.equals(f.GetXP(citizenid), 25)

    -- A full hour later (XP_MINT_BUDGET_WINDOW_MS, server/progression.lua) --
    -- the bucket has fully refilled to XP_MINT_BUDGET_CAP_XP (3,600 XP) --
    -- comfortably enough for one more 25-XP find.
    f.setNow(3600000)
    local result = f.searchVehicle(501, 9002, 20)
    t.isTrue(result.ok)
    t.equals(f.GetXP(citizenid), 50, 'a real search find must pay normally again once the shared budget has genuinely refilled -- this gate is a temporary throttle, never a permanent lockout')
end)

os.exit(t.summary())
