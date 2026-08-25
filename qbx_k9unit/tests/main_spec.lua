--[[
    tests/main_spec.lua

    First client-side spec in this suite (REFACTOR_ROADMAP_2.md item 3).
    Direct tests of client/main.lua's small pure-logic cluster against the
    REAL, unmodified production file: IsEntityModelK9, IsOwnModelK9,
    HasK9Access (and its TTL debounce cache -- SPEC.md's own "checked... on
    every access point... not just once" requirement, balanced against a
    hot ox_target canInteract predicate not flooding the server), the
    CanShowK9UI combinator, DenyK9UIAccess, and ResolveNetworkEntity's
    client-side counterpart to server/entities.lua's function of the same
    name (already covered by entities_spec.lua -- this is a DIFFERENT
    function, same name by design, different Lua VM/signature: the client
    version here takes only `netId`, no `expectedEntityType`).

    All five are resource-globals (no `local`) per that file's own
    FILE-TO-FILE CONTRACT, so -- exactly like entities_spec.lua -- no
    RegisterCommand/callback indirection is needed to reach them.

    LOAD ORDER: the real config.lua (for the REAL Config.Peds model list --
    the task this spec was written for explicitly asked for this, not a
    fabricated stand-in) is loaded into the sandbox FIRST, then the real
    client/main.lua on top -- matching fxmanifest.lua's own
    shared_scripts { ..., 'config.lua' } before client_scripts { 'client/main.lua', ... }
    order. config.lua itself calls no natives at load time (verified: it is
    pure Lua table literals), so it needs no extra stub beyond the ones
    client/main.lua itself requires.

    ONE FRESH SANDBOX PER TEST (never shared) -- same rule kennel_spec.lua
    documents for its own file-load-time locals. client/main.lua's
    `hasK9AccessCache` table is exactly this kind of module-load-time local
    state (declared once, at the top of the file, above HasK9Access): a
    shared sandbox would let one test's cached access decision leak into an
    unrelated test's assertions about a fresh miss. newMainFixture() below
    builds one complete, independent world for every single t.test() call.

    GetHashKey stand-in: same deterministic, non-native approach
    kennel_spec.lua already uses (a stable hash of the model NAME, not the
    real Jenkins one-at-a-time GET_HASH_KEY algorithm) -- this spec only
    needs client/main.lua's own K9ModelHashes table (built from
    Config.Peds via GetHashKey at file-load time) and this file's
    GetEntityModel stub to agree on what hash a given model name maps to,
    never the real native's exact bit pattern.

    NATIVES DELIBERATELY NOT STUBBED, AND WHY (scope, not a stubbing
    hardship -- see this spec's own report for the same disclosure):
    client/main.lua also defines ResolvePlayerServerIdFromPed,
    PlaySoundOnNetworkEntity, and a RegisterNetEvent('qbx_k9unit:client:playBark', ...)
    handler below the functions this spec targets. None of their natives
    (NetworkGetPlayerIndexFromPed, GetPlayerServerId, PlaySoundFromEntity,
    PlayK9Sound) are stubbed here, and none of those three are exercised --
    the task this spec was written for explicitly scoped it to
    IsEntityModelK9/HasK9Access/CanShowK9UI/DenyK9UIAccess plus
    ResolveNetworkEntity "if you can reach it" (reached below), and
    explicitly kept movement.lua/combat.lua-style heavy native surfaces out
    of scope. Because Lua only executes a function's BODY when it's
    called -- never at definition time -- loading the whole file with only
    the target functions' own natives stubbed does not error: RegisterNetEvent
    itself (a load-time CALL, not a deferred one) is the one exception, and
    IS stubbed below (a trivial capturing stub, not "disproportionate"
    stubbing) purely so the file finishes loading at all.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- see header comment above. Identical formula to
-- kennel_spec.lua's own, kept local here rather than shared, matching this
-- suite's existing convention of each spec owning its own tiny fixtures.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

-- config.lua's REAL Config.Peds list, as of this spec's authoring (see
-- config.lua:169-178) -- transcribed here ONLY for readable test names/
-- comments below; every assertion in this file drives the REAL
-- Config.Peds table loaded from the real config.lua, never a copy of it.
local REAL_K9_MODELS = { 'a_c_shepherd', 'a_c_rottweiler', 'a_c_husky', 'a_c_chop' }

-- Deliberately NOT one of the four models above (verified: config.lua has
-- no 'a_c_pug' entry) -- this spec's one "not a recognized K9 model" case.
local NON_K9_MODEL = 'a_c_pug'

local HAS_K9_ACCESS_CACHE_TTL_MS = 1000 -- must match client/main.lua's own HAS_K9_ACCESS_CACHE_TTL_MS

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua + the real
--- client/main.lua loaded into it, plus every native/global stub either
--- file's LOAD-TIME execution or this spec's exercised call paths need.
--- @return table fixture
local function newMainFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local pedHandle = 1
    local entityModels = {} -- entity handle -> model hash (GetEntityModel's stub backing store)
    local function GetEntityModel(entity) return entityModels[entity] end
    local function PlayerPedId() return pedHandle end

    -- ox_lib lib.callback.await stub: a FIFO queue of canned responses PLUS
    -- a call log, so a test can assert both WHAT HasK9Access() returned and
    -- exactly HOW MANY real round trips it caused -- the only way to prove
    -- the TTL cache is actually suppressing calls, not just returning a
    -- plausible value. table.remove() on an empty queue returns nil, which
    -- models a server round trip that failed/timed out/came back empty --
    -- exactly the case this spec's own report is asked to characterize.
    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, timeout = timeout, args = { ... } }
        return table.remove(callbackResponses, 1)
    end

    local notifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    local networkEntities = {} -- netId -> entity handle, present only once "registered" (models NetworkDoesEntityExistWithNetworkId's real true/false contract, not just a 0-vs-nonzero return)
    local function NetworkDoesEntityExistWithNetworkId(netId) return networkEntities[netId] ~= nil end
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end
    local existingEntities = {} -- entity handle -> true
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    -- RegisterNetEvent is called once at client/main.lua's own load time
    -- (the playBark handler, out of this spec's scope -- see header) --
    -- stubbed as a pure no-op only so the file finishes loading; nothing
    -- below ever needs to invoke the handler it would otherwise capture.
    local function RegisterNetEvent(_eventName, _handler) end

    local env = Sandbox.newEnv({
        GetHashKey = GetHashKey,
        GetEntityModel = GetEntityModel,
        PlayerPedId = PlayerPedId,
        GetGameTimer = GetGameTimer,
        lib = lib,
        NetworkDoesEntityExistWithNetworkId = NetworkDoesEntityExistWithNetworkId,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        RegisterNetEvent = RegisterNetEvent,
    })

    -- Real config.lua FIRST (shared_scripts order), real client/main.lua on
    -- top (client_scripts order) -- see this file's own header.
    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../client/main.lua', env)

    return {
        env = env,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setPed = function(handle) pedHandle = handle end,
        setModel = function(entity, hash) entityModels[entity] = hash end,
        queueCallbackResponse = function(value) callbackResponses[#callbackResponses + 1] = value end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        notifyCalls = notifyCalls,
        registerEntity = function(netId, handle, exists)
            networkEntities[netId] = handle
            existingEntities[handle] = exists ~= false
        end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity: the whole file loaded and exposed exactly what its own
-- FILE-TO-FILE CONTRACT documents, before trusting any test below.
-- ----------------------------------------------------------------------

t.test('client/main.lua exposes all five documented resource-globals', function()
    local f = newMainFixture()
    t.isNotNil(f.env.IsEntityModelK9)
    t.isNotNil(f.env.IsOwnModelK9)
    t.isNotNil(f.env.HasK9Access)
    t.isNotNil(f.env.CanShowK9UI)
    t.isNotNil(f.env.DenyK9UIAccess)
    t.isNotNil(f.env.ResolveNetworkEntity, 'the client-side ResolveNetworkEntity, distinct from server/entities.lua\'s function of the same name')
end)

-- ----------------------------------------------------------------------
-- IsEntityModelK9 -- against the REAL Config.Peds list from the real
-- config.lua, not a fabricated stand-in list.
-- ----------------------------------------------------------------------

for _, modelName in ipairs(REAL_K9_MODELS) do
    t.test(('IsEntityModelK9: recognizes the real config.lua Config.Peds entry %q'):format(modelName), function()
        local f = newMainFixture()
        local entity = 500
        f.setModel(entity, GetHashKey(modelName))
        t.isTrue(f.env.IsEntityModelK9(entity))
    end)
end

t.test('IsEntityModelK9: a model not present in Config.Peds returns false', function()
    local f = newMainFixture()
    local entity = 500
    f.setModel(entity, GetHashKey(NON_K9_MODEL))
    t.isFalse(f.env.IsEntityModelK9(entity))
end)

t.test('IsEntityModelK9: an entity with no resolvable model (GetEntityModel returns nil) is false, not an error', function()
    local f = newMainFixture()
    -- Never registered in entityModels -- GetEntityModel(entity) returns
    -- nil. K9ModelHashes[nil] is a safe table READ (only a nil-keyed WRITE
    -- errors in Lua), so this must resolve to false cleanly, never throw.
    t.isFalse(f.env.IsEntityModelK9(0))
end)

t.test('IsEntityModelK9: an entity whose model hash is the literal sentinel 0 is false (never coincides with a real Config.Peds hash)', function()
    local f = newMainFixture()
    local entity = 0
    f.setModel(entity, 0)
    t.isFalse(f.env.IsEntityModelK9(entity))
end)

-- ----------------------------------------------------------------------
-- IsOwnModelK9 -- IsEntityModelK9(PlayerPedId())
-- ----------------------------------------------------------------------

t.test('IsOwnModelK9: true when the local player\'s own ped model is a recognized K9 model', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey('a_c_husky'))
    t.isTrue(f.env.IsOwnModelK9())
end)

t.test('IsOwnModelK9: false when the local player\'s own ped is a human/other model', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey(NON_K9_MODEL))
    t.isFalse(f.env.IsOwnModelK9())
end)

-- ----------------------------------------------------------------------
-- HasK9Access -- THE TTL DEBOUNCE CACHE. This is the section the task this
-- spec was written for called out as "what matters most": a cache that
-- fails OPEN here would show K9 UI to an uncertified player.
-- ----------------------------------------------------------------------

t.test('HasK9Access: a cold cache is a MISS -- awaits the real server callback', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().event, 'qbx_k9unit:server:hasK9Access')
end)

t.test('HasK9Access: a second call at the SAME instant is a cache HIT -- no second round trip', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 1)

    -- Queue a DIFFERENT response the cache must never consult if it's
    -- really serving from cache rather than re-awaiting.
    f.queueCallbackResponse(false)
    t.isTrue(f.env.HasK9Access(), 'still the cached true, not the freshly-queued false')
    t.equals(f.callbackCallCount(), 1, 'no new round trip was made -- the cache, not a second live check, answered this call')
end)

t.test('HasK9Access: just under the TTL boundary is still a cache HIT', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    f.advance(HAS_K9_ACCESS_CACHE_TTL_MS - 1)
    f.queueCallbackResponse(false)
    t.isTrue(f.env.HasK9Access(), 'still cached -- one millisecond short of the TTL')
    t.equals(f.callbackCallCount(), 1)
end)

t.test('HasK9Access: at exactly the TTL boundary the cache has EXPIRED -- a fresh round trip is made', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    -- client/main.lua's own check is `(now - checkedAt) < TTL` -- strictly
    -- less-than, so `now - checkedAt == TTL` must already be a miss, not
    -- one more instant of grace.
    f.advance(HAS_K9_ACCESS_CACHE_TTL_MS)
    f.queueCallbackResponse(false)
    t.isFalse(f.env.HasK9Access(), 'the newly-queued response, proving a real re-check happened')
    t.equals(f.callbackCallCount(), 2)
end)

t.test('HasK9Access: comfortably past the TTL is a MISS -- re-awaits and reflects a revoked access', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    f.advance(HAS_K9_ACCESS_CACHE_TTL_MS + 500)
    f.queueCallbackResponse(false) -- certification revoked in between
    t.isFalse(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 2)
end)

t.test('HasK9Access: the server explicitly denying access (false) is returned and cached as false, not re-queried within the TTL', function()
    local f = newMainFixture()
    f.queueCallbackResponse(false)
    t.isFalse(f.env.HasK9Access())
    f.queueCallbackResponse(true) -- must not be consulted -- still within the TTL
    t.isFalse(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 1)
end)

-- THE load-bearing case this spec was specifically asked to prove: which
-- way a FAILED round trip (no response at all -- ox_lib's lib.callback.await
-- returns nil on a timeout/failure, never throws) resolves.
t.test('HasK9Access: a FAILED round trip (lib.callback.await returns nil) FAILS CLOSED -- returns false, never true', function()
    local f = newMainFixture()
    -- Deliberately queue NOTHING -- callbackAwait's table.remove() on an
    -- empty queue returns nil, modeling exactly this failure/timeout case.
    local result = f.env.HasK9Access()
    t.isFalse(result, 'HasK9Access must fail closed on a failed/absent server response -- a cache that fails OPEN here would show K9 UI to an uncertified player')
    t.equals(f.callbackCallCount(), 1, 'the round trip really was attempted, not skipped')
end)

t.test('HasK9Access: a failed round trip is ALSO cached as false -- the failure-closed result is not silently retried every call within the TTL', function()
    local f = newMainFixture()
    t.isFalse(f.env.HasK9Access(), 'first call: failed round trip (no response queued), fails closed')
    t.equals(f.callbackCallCount(), 1)

    -- A genuinely-true response is queued now. If the cache had NOT stored
    -- the earlier failure as `false` (e.g. left checkedAt stale so every
    -- call re-queries), this second call would consume it and return true
    -- -- which would still be safe-ish (a real check ran) but would
    -- contradict client/main.lua's own documented ~1000ms debounce
    -- contract. The CURRENTLY OBSERVED, correct behavior is that the
    -- failure is cached exactly like a real `false` would be: no second
    -- round trip inside the TTL at all.
    f.queueCallbackResponse(true)
    t.isFalse(f.env.HasK9Access(), 'still the cached false from the earlier failed round trip')
    t.equals(f.callbackCallCount(), 1, 'no second round trip within the TTL, even though this call could have "used" the freshly-queued true')
end)

-- ----------------------------------------------------------------------
-- CanShowK9UI -- IsOwnModelK9() and HasK9Access()
-- ----------------------------------------------------------------------

t.test('CanShowK9UI: true only when both the own-model check and the server access check pass', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey('a_c_chop'))
    f.queueCallbackResponse(true)
    t.isTrue(f.env.CanShowK9UI())
end)

t.test('CanShowK9UI: false when the own model is not a K9 model, even if the server would grant access -- and the server is never even asked (short-circuit)', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey(NON_K9_MODEL))
    f.queueCallbackResponse(true) -- would grant access, but must never be consulted
    t.isFalse(f.env.CanShowK9UI())
    t.equals(f.callbackCallCount(), 0, 'Lua\'s `and` short-circuits: IsOwnModelK9() being false means HasK9Access() -- a real network round trip -- must never even run')
end)

t.test('CanShowK9UI: false when the own model IS a K9 model but the server denies access', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey('a_c_shepherd'))
    f.queueCallbackResponse(false)
    t.isFalse(f.env.CanShowK9UI())
end)

-- ----------------------------------------------------------------------
-- DenyK9UIAccess -- the shared denial notification. Exercising this also
-- doubles as a check that both locale keys it references genuinely exist
-- in locales/en.json, per this suite's own convention (Sandbox.locale
-- RAISES on a missing key, and is never stubbed away).
-- ----------------------------------------------------------------------

t.test('DenyK9UIAccess: notifies with the real common.notify_title / common.no_k9_access locale keys, as an error', function()
    local f = newMainFixture()
    f.env.DenyK9UIAccess()
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].title, locale('common.notify_title'))
    t.equals(f.notifyCalls[1].description, locale('common.no_k9_access'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

-- ----------------------------------------------------------------------
-- ResolveNetworkEntity -- client/main.lua's OWN function of this name (see
-- header comment: distinct from, and simpler than, server/entities.lua's
-- function of the same name already covered by entities_spec.lua -- no
-- expectedEntityType parameter here at all).
-- ----------------------------------------------------------------------

t.test('ResolveNetworkEntity: a netId this client has never seen streamed in resolves to nil', function()
    local f = newMainFixture()
    t.isNil(f.env.ResolveNetworkEntity(999999))
end)

t.test('ResolveNetworkEntity: a netId that exists on the network but whose local entity no longer exists (stale) resolves to nil', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, false) -- NetworkDoesEntityExistWithNetworkId(100) is true, but DoesEntityExist(5000) is false
    t.isNil(f.env.ResolveNetworkEntity(100), 'a stale/despawned entity must never be returned, even once the netId itself is recognized')
end)

t.test('ResolveNetworkEntity: a live, currently-streamed-in entity resolves successfully to its real handle', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, true)
    t.equals(f.env.ResolveNetworkEntity(100), 5000)
end)

os.exit(t.summary())
