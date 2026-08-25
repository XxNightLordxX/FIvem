--[[
    tests/tenure_spec.lua

    Indirect tests of server/tenure.lua's local CheckTenureMilestonesForK9 /
    TickPartnershipTenure against the REAL, unmodified production file --
    the only wall-clock-driven milestone award in this resource. Both
    functions are `local` (no resource-global entry point, per this file's
    own "NO NETWORK-FACING SURFACE" header), so they're reached the same way
    the real FXServer would: this file's own CreateThread loop, registered
    only when Config.Features.HandlerPartnership/XPProgression/
    PartnershipTenureBonus are all true at file-load time, stepped one pass
    at a time via fixtures/sandbox.lua's coroutine thread runner (each pass
    runs pcall(TickPartnershipTenure) exactly as the real `while true do
    Wait(...) ... end` body does).

    DB MODEL: MySQL.single.await / MySQL.update.await are backed by a tiny
    in-memory `k9_partnerships`-shaped row store (dbRows below) that
    actually mutates on a successful UPDATE and is re-read on the next
    SELECT -- this is what lets the "cannot double-grant" tests below be a
    real regression guard on the production file's own optimistic
    concurrency guard (`WHERE tenure_bonus_tier_granted = ?`), not a
    reimplementation of "should only grant once" asserted independently of
    the real UPDATE's WHERE clause.

    Covers: tier-boundary resolution (exactly at / one second below an
    afterSeconds threshold), multi-milestone catch-up in a single tick, the
    persisted-column race guard actually preventing a double grant across
    repeated ticks, the activity gate (offline handler / too far / missing
    certification / handler not in a configured department), and two
    no-schema-degradation paths: a missing/empty milestones config (zero
    queries attempted at all) and a MySQL.single.await that errors outright
    (simulating a database that hasn't run migration 0003 yet -- pcall-caught,
    logged, never a hard crash).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub: real FiveM vector3 supports `-` (component-wise) and
-- `#` (magnitude) via operator metamethods; GetEntityCoords returns one of
-- these. server/tenure.lua's activity gate does
-- `#(GetEntityCoords(k9Ped) - GetEntityCoords(handlerPed))`, so both
-- metamethods must be modeled for that line to even run under plain lua5.4.
-- ----------------------------------------------------------------------

local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end

-- ----------------------------------------------------------------------
-- Sandbox setup: one fresh env per top-level scenario, so Config/dbRows
-- mutations in one scenario never leak into another (unlike cooldowns_spec/
-- admin_spec's single shared env, this file needs several DISTINCT
-- Config.Features/Config.Partnership shapes across its scenarios).
-- ----------------------------------------------------------------------

--- Builds one full sandbox for server/tenure.lua, with a controllable
--- k9_partnerships-shaped in-memory row store and every cross-file
--- dependency it reads (GetActivePartnerCitizenId, HasK9Access, AwardXP,
--- NotifyPlayer) as a test-controlled stub.
--- @param opts table? -- { featuresOverride, partnershipCfgOverride }
local function newTenureFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local threadRunner = Sandbox.newThreadRunner()

    local dbRows = {} -- id -> { id, k9_citizenid, handler_citizenid, tenure_bonus_tier_granted, establishedAt }
    local singleAwaitCallCount = 0
    local updateAwaitCallCount = 0
    local singleAwaitShouldError = false

    local MySQLStub = {
        single = {
            await = function(sql, params)
                singleAwaitCallCount = singleAwaitCallCount + 1
                if singleAwaitShouldError then
                    error('unknown column \'tenure_bonus_tier_granted\' in field list (simulated pre-migration schema)')
                end
                if not sql:find('FROM k9_partnerships', 1, true) then return nil end
                local citizenid = params[1]
                for _, row in pairs(dbRows) do
                    if row.k9_citizenid == citizenid then
                        return {
                            id = row.id,
                            k9_citizenid = row.k9_citizenid,
                            handler_citizenid = row.handler_citizenid,
                            tenure_bonus_tier_granted = row.tenure_bonus_tier_granted,
                            tenure_seconds = fakeNow - row.establishedAt,
                        }
                    end
                end
                return nil
            end,
        },
        update = {
            await = function(sql, params)
                updateAwaitCallCount = updateAwaitCallCount + 1
                local newTier, id, oldTier = params[1], params[2], params[3]
                local row = dbRows[id]
                if row and row.tenure_bonus_tier_granted == oldTier then
                    row.tenure_bonus_tier_granted = newTier
                    return 1
                end
                return 0 -- lost the optimistic-concurrency race, or row moved on
            end,
        },
    }

    local partnerCitizenIdByCitizenId = {} -- citizenid -> { partner = citizenid, isK9 = bool }
    local function GetActivePartnerCitizenId(citizenid)
        local entry = partnerCitizenIdByCitizenId[citizenid]
        if not entry then return nil, false end
        return entry.partner, entry.isK9
    end

    local hasK9AccessBySource = {}
    local function HasK9Access(source)
        return hasK9AccessBySource[source] == true
    end

    local awardXPCalls = {}
    local function AwardXP(citizenid, actionKey)
        awardXPCalls[#awardXPCalls + 1] = { citizenid = citizenid, actionKey = actionKey }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local onlinePlayerIds = {} -- list of server ids currently "connected"
    local function GetPlayers()
        local out = {}
        for i, id in ipairs(onlinePlayerIds) do out[i] = tostring(id) end
        return out
    end

    local citizenidBySource = {}
    local function qbxGetPlayer(_self, src)
        local citizenid = citizenidBySource[src]
        if not citizenid then return nil end
        return { PlayerData = { citizenid = citizenid, source = src } }
    end

    local playerRecordByCitizenId = {} -- citizenid -> { source = n, job = { name = 'x' } } or nil (offline)
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        local rec = playerRecordByCitizenId[citizenid]
        if not rec then return nil end
        return { PlayerData = { source = rec.source, job = rec.job } }
    end

    local pedBySource = {}
    local function GetPlayerPed(src)
        return pedBySource[src] or 0
    end

    local coordsByPed = {}
    local function GetEntityCoords(ped)
        return coordsByPed[ped] or vec3(0, 0, 0)
    end

    local Config = {
        Features = opts.featuresOverride or {
            HandlerPartnership = true,
            XPProgression = true,
            PartnershipTenureBonus = true,
        },
        Departments = { police = { label = 'Police' } },
        Partnership = opts.partnershipCfgOverride ~= nil and opts.partnershipCfgOverride or {
            ProximityMeters = 5.0,
            TenureBonus = {
                checkIntervalMs = 300000,
                milestones = {
                    { afterSeconds = 86400,   actionKey = 'partnershipTenure1Day' },
                    { afterSeconds = 604800,  actionKey = 'partnershipTenure7Day' },
                    { afterSeconds = 2592000, actionKey = 'partnershipTenure30Day' },
                },
            },
        },
    }

    local env = Sandbox.newEnv({
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        GetPlayers = GetPlayers,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        MySQL = MySQLStub,
        GetActivePartnerCitizenId = GetActivePartnerCitizenId,
        HasK9Access = HasK9Access,
        AwardXP = AwardXP,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        exports = {
            qbx_core = {
                GetPlayer = qbxGetPlayer,
                GetPlayerByCitizenId = qbxGetPlayerByCitizenId,
            },
        },
        Config = Config,
    })

    Sandbox.loadInto('../server/tenure.lua', env)

    return {
        env = env,
        threadRunner = threadRunner,
        setNow = function(ms) fakeNow = ms end,
        setSingleAwaitError = function(v) singleAwaitShouldError = v end,
        singleAwaitCallCount = function() return singleAwaitCallCount end,
        updateAwaitCallCount = function() return updateAwaitCallCount end,
        addRow = function(id, k9Cid, handlerCid, alreadyGranted, establishedAt)
            dbRows[id] = { id = id, k9_citizenid = k9Cid, handler_citizenid = handlerCid, tenure_bonus_tier_granted = alreadyGranted, establishedAt = establishedAt }
        end,
        rowTierGranted = function(id) return dbRows[id].tenure_bonus_tier_granted end,
        setOnline = function(ids) onlinePlayerIds = ids end,
        setCitizenidForSource = function(src, cid) citizenidBySource[src] = cid end,
        setPartner = function(citizenid, partnerCid, isK9) partnerCitizenIdByCitizenId[citizenid] = { partner = partnerCid, isK9 = isK9 } end,
        setHasK9Access = function(src, v) hasK9AccessBySource[src] = v end,
        setHandlerOnline = function(handlerCid, src, jobName) playerRecordByCitizenId[handlerCid] = { source = src, job = jobName and { name = jobName } or nil } end,
        setHandlerOffline = function(handlerCid) playerRecordByCitizenId[handlerCid] = nil end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        awardXPCalls = awardXPCalls,
        notifyCalls = notifyCalls,
        printedLines = printedLines,
    }
end

--- Runs one full sweep pass: prime (reach the initial Wait) then step
--- (execute pcall(TickPartnershipTenure) once). See fixtures/sandbox.lua's
--- own newThreadRunner header for why priming is a separate first call.
local function primeIfNeeded(fx)
    if not fx.primed then
        fx.threadRunner.step()
        fx.primed = true
    end
end
local function runOneTick(fx)
    primeIfNeeded(fx)
    fx.threadRunner.step()
end

--- Wires up the common "one online K9-role citizen, partnered, handler
--- online and adjacent, both certified/departmented" happy path, up to (but
--- not including) actually running a tick -- every test below tweaks
--- exactly one thing off this baseline.
local function wireHappyPath(fx, opts)
    opts = opts or {}
    local k9Src = opts.k9Src or 1
    local handlerSrc = opts.handlerSrc or 2
    fx.setOnline({ k9Src })
    fx.setCitizenidForSource(k9Src, 'K9-CID')
    fx.setPartner('K9-CID', 'HANDLER-CID', true)
    fx.setHandlerOnline('HANDLER-CID', handlerSrc, opts.jobName or 'police')
    fx.setHasK9Access(k9Src, opts.hasK9Access ~= false)
    fx.setPed(k9Src, 9001)
    fx.setPed(handlerSrc, 9002)
    fx.setCoords(9001, 0, 0, 0)
    fx.setCoords(9002, opts.distance or 0, 0, 0)
    return k9Src, handlerSrc
end

-- ----------------------------------------------------------------------
-- Tier-boundary resolution
-- ----------------------------------------------------------------------

t.test('CheckTenureMilestonesForK9: exactly AT the first milestone threshold (>=) grants it', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    -- NOTE: the stub computes tenure_seconds = fakeNow - establishedAt directly
    -- (no unit conversion) -- fakeNow here is used AS seconds, matching
    -- afterSeconds' own unit, not milliseconds. See the next test for the
    -- one-second-below case using the same convention.
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 1, 'exactly at the 1-day threshold must grant milestone 1')
    t.equals(fx.awardXPCalls[1].actionKey, 'partnershipTenure1Day')
    t.equals(fx.rowTierGranted(1), 1)
end)

t.test('CheckTenureMilestonesForK9: one second BELOW the threshold does not grant it', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86399)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 0, 'one second under the threshold must not grant anything')
    t.equals(fx.rowTierGranted(1), 0)
end)

t.test('CheckTenureMilestonesForK9: a long absence crossing multiple milestones grants ALL newly-crossed tiers in one tick', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(2592000) -- past all three thresholds at once
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 3, 'crossing all three milestones in one tick must grant all three, not just the highest')
    t.equals(fx.awardXPCalls[1].actionKey, 'partnershipTenure1Day')
    t.equals(fx.awardXPCalls[2].actionKey, 'partnershipTenure7Day')
    t.equals(fx.awardXPCalls[3].actionKey, 'partnershipTenure30Day')
    t.equals(fx.rowTierGranted(1), 3)
end)

-- ----------------------------------------------------------------------
-- Cannot double-grant: the persisted tenure_bonus_tier_granted column,
-- via the real optimistic-concurrency UPDATE ... WHERE clause.
-- ----------------------------------------------------------------------

t.test('CheckTenureMilestonesForK9: a repeated tick at the SAME tenure never re-grants the same milestone', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 1)

    -- Same DB state, same tenure -- a second tick (e.g. the next 5-minute
    -- poll before tenure has advanced further) must not re-grant.
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 1, 'a second tick at unchanged tenure must not double-grant milestone 1')
    t.equals(fx.rowTierGranted(1), 1)
end)

t.test('CheckTenureMilestonesForK9: after fully collecting every milestone, further ticks grant nothing more', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(2592000)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 3)

    fx.setNow(2592000 + 999999) -- arbitrarily further in the future -- no more configured milestones to cross
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 3, 'once every configured milestone is collected, no further AwardXP calls are ever made')
end)

t.test('CheckTenureMilestonesForK9: the DB-persisted column, not an in-memory flag alone, is what prevents a double grant across a fresh check', function()
    -- Regression guard for the double-grant class of bug this task flagged:
    -- re-run the EXACT SAME scenario as a brand-new fixture (simulating a
    -- resource restart -- TenureFullyCollected's in-memory cache is emptied
    -- by construction here) but seed the DB row as ALREADY having granted
    -- tier 1 -- the real production code must derive "already granted" from
    -- the ROW, not from any in-memory state, since a fresh fixture has none.
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 1, 0) -- tier 1 ALREADY granted, per a prior (simulated pre-restart) run
    fx.setNow(86400) -- still only past the 1-day threshold
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 0, 'a restart must never re-grant a milestone the persisted column already recorded as paid')
end)

-- ----------------------------------------------------------------------
-- Activity gate: both parties online AND within ProximityMeters, AND
-- currently certified/departmented -- re-derived fresh, never assumed from
-- the partnership row alone.
-- ----------------------------------------------------------------------

t.test('Activity gate: handler offline defers the grant (no error, no AwardXP, retried next tick)', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.setHandlerOffline('HANDLER-CID')
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 0, 'an offline handler must defer the grant, never crash or grant anyway')
    t.equals(fx.updateAwaitCallCount(), 0, 'the UPDATE must never even be attempted while the handler is offline')
end)

t.test('Activity gate: handler online but beyond ProximityMeters defers the grant', function()
    local fx = newTenureFixture()
    wireHappyPath(fx, { distance = 5.1 }) -- Config.Partnership.ProximityMeters is 5.0
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 0, 'a handler outside the configured proximity radius must defer the grant')
end)

t.test('Activity gate: handler exactly AT the proximity boundary still grants (<=, not strictly <)', function()
    local fx = newTenureFixture()
    wireHappyPath(fx, { distance = 5.0 })
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 1, 'exactly at ProximityMeters must still count as "close enough"')
end)

t.test('Activity gate: the K9-role party failing a FRESH HasK9Access re-check defers the grant, even with an active partnership row', function()
    local fx = newTenureFixture()
    wireHappyPath(fx, { hasK9Access = false })
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 0, 'a decertified K9 must not collect a tenure bonus merely because the partnership row is still active=1')
end)

t.test('Activity gate: the handler not currently belonging to a Config.Departments job defers the grant', function()
    local fx = newTenureFixture()
    wireHappyPath(fx, { jobName = 'unemployed' }) -- not a key in Config.Departments
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.awardXPCalls, 0, 'a handler who left the department must not keep collecting tenure bonuses')
end)

t.test('Both parties confirmed online: a real grant notifies BOTH the K9 and the handler', function()
    local fx = newTenureFixture()
    local k9Src, handlerSrc = wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(#fx.notifyCalls, 2)
    local targets = { fx.notifyCalls[1].target, fx.notifyCalls[2].target }
    table.sort(targets)
    local expected = { k9Src, handlerSrc }
    table.sort(expected)
    t.equals(targets[1], expected[1])
    t.equals(targets[2], expected[2])
end)

-- ----------------------------------------------------------------------
-- Pre-filter: only the K9-role party's own tick drives a check; a
-- handler-role citizenid online by itself never triggers one directly.
-- ----------------------------------------------------------------------

t.test('TickPartnershipTenure: a handler-role citizenid (isK9 == false) never triggers a milestone check by itself', function()
    local fx = newTenureFixture()
    local handlerSrc = 2
    fx.setOnline({ handlerSrc })
    fx.setCitizenidForSource(handlerSrc, 'HANDLER-CID')
    fx.setPartner('HANDLER-CID', 'K9-CID', false) -- this citizenid is the HANDLER role
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(fx.singleAwaitCallCount(), 0, 'only the K9-role party\'s presence should ever trigger the SELECT')
end)

t.test('TickPartnershipTenure: an unpartnered online player triggers no query at all', function()
    local fx = newTenureFixture()
    fx.setOnline({ 1 })
    fx.setCitizenidForSource(1, 'SOLO-CID')
    -- no GetActivePartnerCitizenId entry seeded for 'SOLO-CID' -> defaults to (nil, false)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(fx.singleAwaitCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- No-schema / no-config degradation: must be a silent no-op, never a crash.
-- ----------------------------------------------------------------------

t.test('Degrades to a no-op when Config.Partnership.TenureBonus.milestones is missing entirely -- zero queries attempted', function()
    local fx = newTenureFixture({ partnershipCfgOverride = { ProximityMeters = 5.0 } }) -- no TenureBonus key at all
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(fx.singleAwaitCallCount(), 0, 'a missing milestones config must short-circuit before ever touching the database')
    t.equals(#fx.awardXPCalls, 0)
end)

t.test('Degrades to a no-op when Config.Partnership.TenureBonus.milestones is an empty table -- zero queries attempted', function()
    local fx = newTenureFixture({ partnershipCfgOverride = { ProximityMeters = 5.0, TenureBonus = { checkIntervalMs = 300000, milestones = {} } } })
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    runOneTick(fx)
    t.equals(fx.singleAwaitCallCount(), 0)
    t.equals(#fx.awardXPCalls, 0)
end)

t.test('Degrades to a logged no-op, never a crash, when the SELECT itself errors (simulated pre-migration schema)', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    fx.setSingleAwaitError(true)
    runOneTick(fx) -- must not throw out of the coroutine (thread runner would error() the test if it did)
    t.equals(#fx.awardXPCalls, 0)
    local found = false
    for _, line in ipairs(fx.printedLines) do
        if line:find('milestone query failed', 1, true) then found = true end
    end
    t.isTrue(found, 'a query failure must be logged, not silently swallowed with no trace')
end)

t.test('No thread is even registered when Config.Features.PartnershipTenureBonus is false', function()
    local fx = newTenureFixture({ featuresOverride = { HandlerPartnership = true, XPProgression = true, PartnershipTenureBonus = false } })
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(86400)
    -- No thread was ever created at file-load time -- step() has nothing to
    -- resume, so this must be a true no-op with zero queries, not merely a
    -- gate inside a tick that never fires here.
    fx.threadRunner.step()
    fx.threadRunner.step()
    t.equals(fx.singleAwaitCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- Documentation/behavior discrepancy, pinned as a regression guard:
-- TenureFullyCollected is documented (this file's own header comment on
-- that local) as existing "to avoid re-running the SELECT below every
-- tick" once a partnership has collected every milestone -- but the SELECT
-- runs BEFORE that cache is ever consulted (the cache is keyed by row.id,
-- which is only known AFTER the SELECT returns it), so the claimed query
-- savings do not actually happen. This is not a correctness bug -- the
-- persisted column's optimistic UPDATE is what actually prevents a double
-- grant, and this test confirms that stays true -- but it IS a real,
-- disclosable gap between the header's documented intent and the actual
-- runtime behavior, flagged here rather than silently assumed to work as
-- described.
-- ----------------------------------------------------------------------

t.test('DISCREPANCY: TenureFullyCollected does NOT skip the SELECT on a fully-collected partnership (still runs every tick)', function()
    local fx = newTenureFixture()
    wireHappyPath(fx)
    fx.addRow(1, 'K9-CID', 'HANDLER-CID', 0, 0)
    fx.setNow(2592000)
    runOneTick(fx) -- collects all 3 milestones, sets TenureFullyCollected[1] = true
    t.equals(#fx.awardXPCalls, 3)
    local queriesSoFar = fx.singleAwaitCallCount()

    runOneTick(fx) -- steady-state tick, should be a total no-op for AwardXP...
    t.equals(#fx.awardXPCalls, 3, 'no further grants once fully collected')
    -- ...but the SELECT itself is NOT skipped, contrary to the header
    -- comment's "avoid re-running the SELECT below every tick" claim --
    -- locking in the REAL observed behavior here, not the documented intent.
    t.equals(fx.singleAwaitCallCount(), queriesSoFar + 1,
        'current behavior: the SELECT still runs once more even though every milestone is already collected -- see this test\'s own header note')
end)

os.exit(t.summary())
