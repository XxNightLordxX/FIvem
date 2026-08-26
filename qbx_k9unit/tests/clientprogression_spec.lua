--[[
    tests/clientprogression_spec.lua

    Direct, black-box tests of client/progression.lua (the CLIENT half of
    XPProgression -- see tests/progression_spec.lua for the SERVER half,
    server/progression.lua's ResolveTier/AwardXP/GetXPTier, a completely
    different file this spec never touches) against the REAL, unmodified
    production file: the Config.Features.XPProgression file-scope gate, the
    `source ~= 65535` origin guard on 'qbx_k9unit:client:xpTierChanged', the
    payload shape guard (type(newTier) == 'table' and
    type(newTier.speedMultiplier) == 'number'), GetCurrentXPTier()'s
    nil-before-first-snapshot behavior, the "never notify on the very first
    snapshot, only on a REAL later tier change" rule
    (hasReceivedInitialTier), and ApplyXPTierMoveRateEffect()'s soft
    dependency on the shared move-rate composer (K9MoveRateModifiers/
    RecomputeK9MoveRate) -- reached only indirectly through the event
    handler, since it is a `local`.

    NO THREAD/CreateThread IN THIS FILE AT ALL -- purely event-driven (one
    RegisterNetEvent handler, no polling, no maintenance loop) -- confirmed
    by reading the whole file before writing this fixture, so this spec
    needs no Sandbox.newThreadRunner() at all, unlike every OTHER client
    spec in this suite.

    K9MoveRateModifiers/RecomputeK9MoveRate -- WHY THIS FILE STUBS THEM
    DIRECTLY RATHER THAN LOADING THE REAL client/movement.lua: this file's
    own header notes these two symbols are read behind a runtime-existence
    guard rather than a load-order assumption, and (per client/movement.lua's
    own current state, verified before writing this fixture) both now really
    exist there as a plain resource-global table and function respectively.
    Loading the real, 2000+-line client/movement.lua into this sandbox just
    to reach two symbols would need a large, unrelated stubbing effort for
    everything else that file touches at load time -- exactly the
    "disproportionate stubbing" this suite's specs avoid. This file's own
    tests instead exercise BOTH the "composer exists" and "composer does not
    exist yet" shapes directly via a small, controllable stand-in table/
    function, which the guard is explicitly designed to make possible.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { xpProgression: boolean?, withComposer: boolean? }?
---   `withComposer` (default true) controls whether K9MoveRateModifiers/
---   RecomputeK9MoveRate exist in the sandbox at all.
--- @return table fixture
local function newProgressionFixture(opts)
    opts = opts or {}
    local withComposer = opts.withComposer
    if withComposer == nil then withComposer = true end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local recomputeCallCount = 0
    local k9MoveRateModifiers, recomputeK9MoveRate
    if withComposer then
        k9MoveRateModifiers = { fatigue = 1.0, injury = 1.0, mood = 1.0, xpTier = 1.0, dragging = 1.0 }
        recomputeK9MoveRate = function() recomputeCallCount = recomputeCallCount + 1 end
    end

    local overrides = {
        lib = { notify = lib_notify },
        RegisterNetEvent = RegisterNetEvent,
    }
    if withComposer then
        overrides.K9MoveRateModifiers = k9MoveRateModifiers
        overrides.RecomputeK9MoveRate = recomputeK9MoveRate
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    if opts.xpProgression == false then
        env.Config.Features.XPProgression = false
    end

    Sandbox.loadInto('../client/progression.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        recomputeCallCount = function() return recomputeCallCount end,
        k9MoveRateModifiers = k9MoveRateModifiers,
        fireTierChanged = function(sourceValue, newTier)
            local handler = assert(netEventHandlers['qbx_k9unit:client:xpTierChanged'],
                'client/progression.lua did not register a qbx_k9unit:client:xpTierChanged handler')
            env.source = sourceValue
            handler(newTier)
        end,
        hasEventHandler = function() return netEventHandlers['qbx_k9unit:client:xpTierChanged'] ~= nil end,
    }
end

-- ----------------------------------------------------------------------
-- Gating
-- ----------------------------------------------------------------------

t.test('gating: XPProgression = false -- GetCurrentXPTier does not exist, and the event handler is never registered at all', function()
    local f = newProgressionFixture({ xpProgression = false })
    t.isNil(f.env.GetCurrentXPTier)
    t.isFalse(f.hasEventHandler())
end)

t.test('gating: XPProgression = true (real shipped default) -- GetCurrentXPTier exists, event handler is registered', function()
    local f = newProgressionFixture()
    t.equals(type(f.env.GetCurrentXPTier), 'function')
    t.isTrue(f.hasEventHandler())
end)

-- ----------------------------------------------------------------------
-- GetCurrentXPTier -- nil before any snapshot, then reflects the latest one
-- ----------------------------------------------------------------------

t.test('GetCurrentXPTier: nil before the first xpTierChanged event ever arrives this session', function()
    local f = newProgressionFixture()
    t.isNil(f.env.GetCurrentXPTier())
end)

t.test('GetCurrentXPTier: reflects the exact table from the most recent VALID xpTierChanged event', function()
    local f = newProgressionFixture()
    local tier = { xp = 100, label = 'Trainee', speedMultiplier = 1.05, scentRangeMultiplier = 1.1 }
    f.fireTierChanged(65535, tier)
    t.equals(f.env.GetCurrentXPTier(), tier)
end)

-- ----------------------------------------------------------------------
-- Origin guard + shape validation
-- ----------------------------------------------------------------------

t.test('origin guard: source ~= 65535 (a forged local self-trigger) is rejected -- GetCurrentXPTier stays nil, no notify, composer untouched', function()
    local f = newProgressionFixture()
    f.fireTierChanged(1234, { xp = 100, label = 'Trainee', speedMultiplier = 999.0 })
    t.isNil(f.env.GetCurrentXPTier())
    t.equals(#f.notifyCalls, 0)
    t.equals(f.k9MoveRateModifiers.xpTier, 1.0, 'a forged event\'s uncapped speedMultiplier must never reach the shared move-rate composer')
    t.equals(f.recomputeCallCount(), 0)
end)

t.test('shape guard: type(newTier) ~= table is rejected', function()
    local f = newProgressionFixture()
    local ok = pcall(f.fireTierChanged, 65535, 'not-a-table')
    t.isTrue(ok)
    t.isNil(f.env.GetCurrentXPTier())
end)

t.test('shape guard: a table missing a numeric speedMultiplier is rejected', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 100, label = 'Trainee' })
    t.isNil(f.env.GetCurrentXPTier())
end)

t.test('shape guard: a non-number speedMultiplier is rejected', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 100, label = 'Trainee', speedMultiplier = 'fast' })
    t.isNil(f.env.GetCurrentXPTier())
end)

-- ----------------------------------------------------------------------
-- "Never notify on the very first snapshot" rule
-- ----------------------------------------------------------------------

t.test('the very first snapshot this session (PlayerLoaded/resource-start backfill) never notifies, even though it IS a "real" tier being received for the first time', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 })
    t.equals(#f.notifyCalls, 0)
end)

t.test('a SECOND snapshot with a DIFFERENT label after the first DOES notify, using the real locale strings', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 })
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].title, locale('common.notify_title'))
    t.equals(f.notifyCalls[1].description, locale('progression.tier_up', 'Veteran'))
    t.equals(f.notifyCalls[1].type, 'success')
end)

t.test('a repeat push of the SAME label (a no-op re-broadcast) does not notify a second time', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 })
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 }) -- real tier-up, notify #1
    f.fireTierChanged(65535, { xp = 501, label = 'Veteran', speedMultiplier = 1.1 }) -- same label, different table -- must NOT notify again
    t.equals(#f.notifyCalls, 1, 'a defensive re-push of the same label must never notify twice')
end)

t.test('a THIRD, later real tier change (after an already-non-first snapshot) notifies again, with the new label', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 })
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    f.fireTierChanged(65535, { xp = 2000, label = 'Elite', speedMultiplier = 1.25 })
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('progression.tier_up', 'Elite'))
end)

-- ----------------------------------------------------------------------
-- ApplyXPTierMoveRateEffect -- soft dependency on the shared composer
-- ----------------------------------------------------------------------

t.test('composer PRESENT: every valid xpTierChanged event writes K9MoveRateModifiers.xpTier and calls RecomputeK9MoveRate -- including the first (silent-notify) snapshot', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.05 })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.05)
    t.equals(f.recomputeCallCount(), 1)
end)

t.test('composer PRESENT: a later real tier change updates the composer slot again, without disturbing other named slots', function()
    local f = newProgressionFixture()
    f.k9MoveRateModifiers.fatigue = 0.8 -- simulate another system's own contribution already present
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 })
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.2 })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.2)
    t.equals(f.k9MoveRateModifiers.fatigue, 0.8, 'writing this file\'s own named slot must never clobber a different system\'s slot in the same shared table')
    t.equals(f.recomputeCallCount(), 2)
end)

t.test('composer ABSENT (K9MoveRateModifiers/RecomputeK9MoveRate do not exist at all): a valid event is still accepted -- GetCurrentXPTier and the notify rule both keep working, with no error', function()
    local f = newProgressionFixture({ withComposer = false })
    local ok = pcall(f.fireTierChanged, 65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 })
    t.isTrue(ok, 'ApplyXPTierMoveRateEffect must degrade to a harmless no-op, never an error, when the composer has not shipped')
    t.equals(f.env.GetCurrentXPTier().label, 'Trainee')

    local ok2 = pcall(f.fireTierChanged, 65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    t.isTrue(ok2)
    t.equals(#f.notifyCalls, 1)
end)

-- ----------------------------------------------------------------------
-- PRIORITY 1 FIX -- LIVE FEATURE FLAG (`.live`) -- the confirmed unbounded
-- trap this file's own header documents in full: a runtime tablet toggle of
-- Config.Features.XPProgression never reaches an already-connected client's
-- own static copy, and server/progression.lua's ONLY push (PushTierSnapshot)
-- stops sending anything at all the instant the flag goes off server-side --
-- so, without this fix, a previously-applied K9MoveRateModifiers.xpTier
-- value would be stuck forever. These tests exercise the CLIENT half of the
-- fix directly (the optional `.live` field ingest and the forced reset to
-- neutral), independent of whether the server-side patch this depends on to
-- ever be INVOKED while the feature is off has landed yet.
-- ----------------------------------------------------------------------

t.test('LIVE FLAG: a payload with no `.live` field at all behaves exactly as before this fix (backward compatible with an unpatched server)', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.1)
    t.equals(f.env.GetCurrentXPTier().label, 'Veteran')
end)

t.test('LIVE FLAG: `.live = true` behaves identically to an absent field -- the real speedMultiplier is applied', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = true })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.1)
end)

t.test('THE FIX: `.live = false` force-resets K9MoveRateModifiers.xpTier to neutral (1.0), regardless of the payload\'s own speedMultiplier', function()
    local f = newProgressionFixture()
    -- Establish a real, non-neutral tier first, exactly like a K9 who
    -- legitimately earned it while the feature was on.
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.1)

    -- High command disables XPProgression at runtime; the (patched) server
    -- pushes a live-off signal on the SAME channel.
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = false })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.0, 'a live-off push must reset the modifier to neutral even though speedMultiplier itself still reads 1.1')
end)

t.test('THE FIX: the reset is NOT gated on the feature being on -- it fires from the same always-registered handler, and a later live=true push re-applies the real value', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = false })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.0)

    -- Re-enabled later -- the real value comes back without a relog.
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = true })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.1)
end)

t.test('THE FIX: once `.live = false` is received, a SUBSEQUENT payload with no `.live` field at all keeps the reset in effect (sticky, not a one-shot)', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = false })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.0)

    -- A hypothetical future push that omits `.live` must not be treated as
    -- "back on" by default -- LiveXPProgressionEnabled must stay at its last
    -- known value, never reset to a bare true on a missing field.
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1 })
    t.equals(f.k9MoveRateModifiers.xpTier, 1.0, 'a payload silent on `.live` must not be interpreted as re-enabling the feature')
end)

t.test('THE FIX: a live-off push never fires a "tier up" notification, even across a genuine label change', function()
    local f = newProgressionFixture()
    f.fireTierChanged(65535, { xp = 0, label = 'Trainee', speedMultiplier = 1.0 }) -- initial snapshot, never notifies
    f.fireTierChanged(65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = false })
    t.equals(#f.notifyCalls, 0, 'a live-off push exists to reset the modifier, never to announce a level-up the player did not actually just earn')
end)

t.test('THE FIX: composer ABSENT -- a live=false payload is still accepted with no error (defensive soft-dependency preserved)', function()
    local f = newProgressionFixture({ withComposer = false })
    local ok = pcall(f.fireTierChanged, 65535, { xp = 500, label = 'Veteran', speedMultiplier = 1.1, live = false })
    t.isTrue(ok)
end)

os.exit(t.summary())
