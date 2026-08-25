--[[
    tests/appearance_spec.lua

    Direct tests of server/appearance.lua -- the K9 role/ped-model
    decoupling this pass introduces (see that file's own header) -- against
    the REAL, unmodified production file, loaded alongside the REAL
    server/cooldowns.lua, server/highcommand.lua and server/permissions.lua
    (ApplyK9PedRole calls GrantPermission directly; MaybeRevertK9Appearance's
    reconciliation calls HasPermission; HasK9Role calls HasPermission too --
    a fake/duplicated permissions layer here would risk silently drifting
    from the real authorization rules it is supposed to be exercising).
    Deliberately does NOT load server/certifications.lua: it is under heavy,
    fast-moving concurrent development this same session (a certification
    tier/expiry/specialization system landed mid-session, more than
    doubling that file's length) and server/appearance.lua's own
    IsCertifiedK9ForJob/IsCertifiedK9ForAnyJob read `k9_certifications`
    directly via MySQL rather than reaching into that file's private
    `Certifications` cache (see server/appearance.lua's own FILE-TO-FILE
    CONTRACT for why) -- so every cert-path assertion below drives the
    MySQL stub's own fake `k9_certifications` table directly, exactly the
    way the real query would see it, with zero dependency on
    certifications.lua's current internal shape.

    LOCALE: stubbed to a plain passthrough, NOT Sandbox.locale. The seven
    `appearance.*` keys this file's production code calls (see this pass's
    hand-off report for the exact key list/English text) are PROPOSED, not
    yet landed in locales/en.json (this file may not edit that file) --
    using the real locale() reader here would make this spec red until an
    orchestrator applies that request, which is exactly backwards for a
    suite that must stay green throughout. permissions.lua's own two
    (already-real, already-landed) locale calls go through this same stub
    too; this spec never asserts on exact notification text, only on
    outcomes/side effects, so the substitution costs nothing here.

    THE FOUR LOAD-BEARING CASES THIS TASK NAMED, and where each lives:
      1. "a human ped CAN hold the role with requireK9ModelForRole false" --
         section 2 below (ApplyK9PedRole never reads or cares about the
         target's ped model at all; HasK9Role reflects the grant
         immediately after).
      2. "a client cannot self-assign" -- section 3 below (ApplyK9PedRole
         is server-authoritative top to bottom via GrantPermission's own
         IsHighCommand check; a non-high-command source is denied outright,
         no DB write, no swap ever requested).
      3. "a failed model load leaves the player untouched" -- the SERVER
         half lives here (section 5: confirmK9PedSwap(ok=false) never
         writes k9_ped_assignments); the CLIENT half (SetPlayerModel is
         never actually called) is tests/clientappearance_spec.lua's job.
      4. "revoke restores the original appearance" -- section 6 below
         (MaybeRevertK9Appearance sends a 'revert' swap request carrying
         the captured original_model_hash, or Config.K9Appearance
         .fallbackHumanModel when none was ever captured).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture builder -- one fresh env + fresh load of cooldowns/highcommand/
-- permissions/appearance per top-level scenario, same "never leak state
-- between unrelated test cases" discipline as certifications_spec.lua's
-- own newFixture().
-- ----------------------------------------------------------------------

--- @param opts table? -- { requireK9ModelForRole: boolean (default false), applyPedModelOnCertify: boolean (default true), restoreOriginalPedOnRevoke: boolean (default true), fallbackHumanModel: string?, modelLoadTimeoutMs: number? }
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    -- appearance.lua's own file-load-time CreateThread(...) (the
    -- forced-timeout sweep -- see that file's own header on the
    -- confirmK9PedSwap section) creates a coroutine via
    -- Sandbox.newThreadRunner(), left dormant until a test explicitly
    -- calls f.stepSweepThread().
    local threadRunner = Sandbox.newThreadRunner()

    -- ONE Wait global has to correctly serve TWO call sites with opposite
    -- needs: the sweep thread's `while true do Wait(...) ... end` body
    -- (runs INSIDE the coroutine above -- must genuinely yield, or
    -- .step()ping it would free-spin forever the first time it's resumed,
    -- exactly the hang this comment's own test run once produced before
    -- this fix) and PlayerLoaded's short original-model-capture retry loop
    -- (called directly, synchronously, from a plain top-level test
    -- assertion -- NOT inside any coroutine, where `coroutine.yield()`
    -- would error outright with "attempt to yield from outside a
    -- coroutine"). `coroutine.isyieldable()` tells the two apart at
    -- runtime: yield (via the thread runner) only when actually running
    -- inside a resumable coroutine, no-op otherwise.
    local function Wait(ms)
        if coroutine.isyieldable() then
            threadRunner.Wait(ms)
        end
    end

    -- ---- exports.qbx_core -------------------------------------------------
    local playersBySource = {}
    local playersByCitizenId = {}

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return p
    end

    local function disconnectPlayer(source)
        local p = playersBySource[source]
        if not p then return end
        playersBySource[source] = nil
        playersByCitizenId[p.PlayerData.citizenid] = nil
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    -- ---- fake k9_certifications / k9_permissions / k9_ped_assignments -----
    -- Real SQL text is never parsed -- every MySQL.*.await stub below
    -- pattern-matches on which TABLE the real production query names, then
    -- reads/writes ONE shared Lua table per fake table, mirroring the exact
    -- shape a real row would have. This is deliberately not a full SQL
    -- engine: server/appearance.lua's own queries are simple enough
    -- (single-table, no joins) that this is a faithful, low-risk stand-in.
    local fakeCerts = {}       -- fakeCerts[citizenid][jobName] = true (active only; inactive rows aren't modeled, nothing here reads them)
    local fakePermissions = {} -- fakePermissions[citizenid][permissionKey] = true (active only)
    local fakeAssignments = {} -- fakeAssignments[citizenid] = { model, original_model_hash, active }

    local function mysqlScalarAwait(sql, params)
        if sql:find('FROM k9_certifications', 1, true) then
            local citizenid, jobName = params[1], params[2]
            if fakeCerts[citizenid] and fakeCerts[citizenid][jobName] then return 1 end
            return nil
        end
        if sql:find('FROM k9_permissions', 1, true) then
            local citizenid, permissionKey = params[1], params[2]
            if fakePermissions[citizenid] and fakePermissions[citizenid][permissionKey] then return 1 end
            return nil
        end
        error('unstubbed MySQL.scalar.await query in appearance_spec fixture: ' .. sql)
    end

    -- IsCertifiedK9ForAnyJob's query has no job param -- a citizenid-only
    -- scan across every department's fake row.
    local function mysqlScalarAwaitAnyJob(sql, params)
        local citizenid = params[1]
        if sql:find('WHERE citizenid = %? AND active = 1 LIMIT 1', 1) and not sql:find('AND job', 1, true) then
            if fakeCerts[citizenid] then
                for _, active in pairs(fakeCerts[citizenid]) do
                    if active then return 1 end
                end
            end
            return nil
        end
        return mysqlScalarAwait(sql, params)
    end

    local function mysqlQueryAwait(sql, params)
        -- RefreshPermissionCache's read (permissions.lua) -- an ARRAY of
        -- { permission = ... } rows, not a scalar. Must be handled here
        -- (not just in mysqlScalarAwait's pre-check SELECT) or GrantPermission's
        -- own post-write cache warm sees an empty result and PermissionCache
        -- never reflects a grant this fixture or the real INSERT below made.
        if sql:find('SELECT permission FROM k9_permissions', 1, true) then
            local citizenid = params[1]
            local out = {}
            if fakePermissions[citizenid] then
                for permissionKey, active in pairs(fakePermissions[citizenid]) do
                    if active then out[#out + 1] = { permission = permissionKey } end
                end
            end
            return out
        end
        if sql:find('INSERT INTO k9_permissions', 1, true) then
            local citizenid, permissionKey = params[1], params[2]
            fakePermissions[citizenid] = fakePermissions[citizenid] or {}
            fakePermissions[citizenid][permissionKey] = true
            return { insertId = 1, affectedRows = 1 }
        end
        if sql:find('UPDATE k9_permissions SET active = 0', 1, true) then
            local citizenid, permissionKey = params[2], params[3]
            local hadIt = fakePermissions[citizenid] and fakePermissions[citizenid][permissionKey]
            if hadIt then fakePermissions[citizenid][permissionKey] = nil; return { affectedRows = 1 } end
            return { affectedRows = 0 }
        end
        if sql:find('FROM k9_ped_assignments', 1, true) then
            local citizenid = params[1]
            local row = fakeAssignments[citizenid]
            if not row then return {} end
            return { { model = row.model, original_model_hash = row.original_model_hash, active = row.active and 1 or 0 } }
        end
        if sql:find('INSERT INTO k9_ped_assignments', 1, true) then
            local citizenid, model, originalHash, appliedBy = params[1], params[2], params[3], params[4]
            local existing = fakeAssignments[citizenid]
            local keepOriginal = existing and existing.active and existing.original_model_hash or nil
            fakeAssignments[citizenid] = {
                model = model,
                original_model_hash = keepOriginal or originalHash,
                active = true,
                applied_by = appliedBy,
            }
            return { insertId = 1, affectedRows = 1 }
        end
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            local citizenid = params[1]
            local row = fakeAssignments[citizenid]
            if row and row.active then row.active = false; return { affectedRows = 1 } end
            return { affectedRows = 0 }
        end
        if sql:find('UPDATE k9_ped_assignments SET original_model_hash', 1, true) then
            local hash, citizenid = params[1], params[2]
            local row = fakeAssignments[citizenid]
            if row and row.active and not row.original_model_hash then row.original_model_hash = hash end
            return { affectedRows = 1 }
        end
        error('unstubbed MySQL.query.await query in appearance_spec fixture: ' .. sql)
    end

    local mysql = {
        scalar = { await = function(sql, params)
            if sql:find('FROM k9_certifications', 1, true) and not sql:find('AND job', 1, true) then
                return mysqlScalarAwaitAnyJob(sql, params)
            end
            return mysqlScalarAwait(sql, params)
        end },
        query = { await = mysqlQueryAwait },
        update = { await = function(sql, params) local r = mysqlQueryAwait(sql, params); return r and r.affectedRows or 0 end },
        insert = { await = function(sql, params) local r = mysqlQueryAwait(sql, params); return r and r.insertId or 0 end },
    }

    -- ---- captured event/callback plumbing ---------------------------------
    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local clientEvents = {} -- { {targetSrc, eventName, ...}, ... }
    local function TriggerClientEvent(eventName, targetSrc, ...)
        clientEvents[#clientEvents + 1] = { targetSrc = targetSrc, eventName = eventName, ... }
    end
    --- Clears IN PLACE. `f.clearClientEvents()` from a test body would only
    --- repoint the RETURNED fixture's own field at a fresh table -- it
    --- can't reach (and therefore can't clear) THIS closure's own
    --- `clientEvents` upvalue, which is what TriggerClientEvent actually
    --- keeps appending to; every subsequent event would then land in the
    --- original table while `f.clientEvents` silently stops updating.
    --- Found by this file's own test run (four failures with a plausible
    --- but wrong "the production code returned early" explanation, until
    --- traced to this aliasing bug instead) -- exactly the kind of mistake
    --- worth leaving this comment in place to prevent a repeat of.
    local function clearClientEvents()
        for i = #clientEvents, 1, -1 do clientEvents[i] = nil end
    end

    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    -- Plain passthrough -- see this file's header for why the real
    -- Sandbox.locale is not used here.
    local function localeStub(key, ...)
        if select('#', ...) > 0 then
            local args = { ... }
            for i, v in ipairs(args) do args[i] = tostring(v) end
            return key .. ':' .. table.concat(args, ',')
        end
        return key
    end

    local function GetPlayerPed(source) return playersBySource[source] and 1 or 0 end
    local function GetEntityModel(_ped) return 55555 end -- arbitrary "current live model" hash for PlayerLoaded's capture path

    -- Minimal, HONEST stand-in for server/certifications.lua's real
    -- HasK9Access -- NOT loaded in this fixture (see this file's header),
    -- but server/permissions.lua's own LegacyOrHighCommandStillQualifies
    -- calls the real one by name for the 'k9.access' reconciliation branch
    -- (RevokePermission's `stillHasAccess` result). This stub answers
    -- ONLY from this fixture's OWN fakeCerts table (an active cert for the
    -- source's CURRENT job) -- sufficient for the one reconciliation path
    -- this file's tests exercise, not a re-implementation of
    -- autoAccessGrade/permission-bypass/high-command, none of which any
    -- test below needs.
    local function HasK9Access(source)
        local p = playersBySource[source]
        local citizenid = p and p.PlayerData and p.PlayerData.citizenid
        local job = p and p.PlayerData and p.PlayerData.job
        return citizenid ~= nil and job ~= nil and fakeCerts[citizenid] ~= nil and fakeCerts[citizenid][job.name] == true
    end

    local Config = {
        Features = { HighCommand = true, PermissionGrants = true },
        Departments = {
            police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 8 },
        },
        Permissions = {
            ['k9.access'] = { label = 'K9 Access' },
        },
        Peds = {
            { model = 'a_c_shepherd' },
            { model = 'a_c_husky' },
        },
        K9Appearance = {
            applyPedModelOnCertify = opts.applyPedModelOnCertify ~= false,
            requireK9ModelForRole = opts.requireK9ModelForRole == true, -- default false, THE decoupling
            persistAcrossSessions = true,
            restoreOriginalPedOnRevoke = opts.restoreOriginalPedOnRevoke ~= false,
            fallbackHumanModel = opts.fallbackHumanModel, -- default nil (opt-in per test)
            modelLoadTimeoutMs = opts.modelLoadTimeoutMs or 8000,
        },
    }

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        Wait = Wait,
        CreateThread = threadRunner.CreateThread,
        exports = exportsStub,
        MySQL = mysql,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        lib = libStub,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        locale = localeStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityModel = GetEntityModel,
        HasK9Access = HasK9Access,
    }

    local env = Sandbox.newEnv(overrides)

    -- server/datastore.lua -- REAL, unmodified, loaded first (fxmanifest.lua's
    -- own load order: the only file allowed to call MySQL.* directly).
    -- server/appearance.lua's own k9_certifications/k9_ped_assignments reads
    -- and writes now go through K9Store.* rather than a local MySQL.*.await
    -- call -- Config.Database is deliberately absent from this fixture's
    -- Config table above, so K9Store's own DatabaseEnabled() fails safe to
    -- `true` (real-DB mode), routing every K9Store.* call straight through
    -- to this fixture's own `mysql` stub above, unchanged.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/highcommand.lua', env)
    Sandbox.loadInto('../server/permissions.lua', env)
    Sandbox.loadInto('../server/appearance.lua', env)

    return {
        env = env,
        state = state,
        Config = Config,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        fakeCerts = fakeCerts,
        fakePermissions = fakePermissions,
        fakeAssignments = fakeAssignments,
        clientEvents = clientEvents,
        clearClientEvents = clearClientEvents,
        notifyLog = notifyLog,
        printLog = printLog,
        callbacks = capturedCallbacks,
        events = capturedEvents,
        eventHandlers = eventHandlers,
        advanceTime = function(ms) state.now = state.now + ms end,
        --- Grants `citizenid` an active k9.access permission directly in the
        --- fake table, bypassing GrantPermission's own cooldown/audit/self-grant
        --- machinery -- used to set up "already holds the role via the OTHER
        --- path" scenarios. HasPermission (permissions.lua) reads a
        --- CACHE (`PermissionCache`, scoped to online citizenids only, per that
        --- file's own header "SCOPE" section), not the DB directly, and that
        --- cache is `local` -- unreachable from here except by making it warm
        --- itself the SAME way a real connect would: re-firing the real
        --- captured 'QBCore:Server:PlayerLoaded' handler for this citizenid,
        --- which internally calls the real (private) RefreshPermissionCache
        --- against this fixture's own fake k9_permissions table.
        grantPermissionDirect = function(citizenid, permissionKey)
            fakePermissions[citizenid] = fakePermissions[citizenid] or {}
            fakePermissions[citizenid][permissionKey] = true
            local player = playersByCitizenId[citizenid]
            -- Deliberately fires ONLY the FIRST-registered PlayerLoaded
            -- handler -- permissions.lua's own, guaranteed first by this
            -- fixture's own fixed Sandbox.loadInto order above
            -- (cooldowns -> highcommand -> permissions -> appearance).
            -- Firing EVERY registered handler here (an earlier draft did)
            -- also fires server/appearance.lua's OWN PlayerLoaded handler,
            -- which lazily captures original_model_hash from a "live" ped
            -- the moment ANY connect-shaped event reaches it -- correct
            -- production behavior, but it silently gives a fallback-model
            -- test a captured original it was specifically trying to NOT
            -- have, since this helper's whole point is warming
            -- PermissionCache, not simulating a real reconnect.
            if player and eventHandlers['QBCore:Server:PlayerLoaded'] then
                eventHandlers['QBCore:Server:PlayerLoaded'][1](player)
            end
        end,
        grantCertDirect = function(citizenid, jobName)
            fakeCerts[citizenid] = fakeCerts[citizenid] or {}
            fakeCerts[citizenid][jobName] = true
        end,
        --- Fires ONLY server/appearance.lua's OWN PlayerLoaded handler
        --- (the second one registered, per this fixture's fixed load
        --- order) -- the deliberate counterpart to grantPermissionDirect/
        --- revokePermissionDirect above firing ONLY the first
        --- (permissions.lua's). Used by the PlayerLoaded/HasK9Role
        --- backstop tests, which need EXACTLY this file's reconnect logic
        --- to run, not permissions.lua's cache warm.
        firePlayerLoadedAppearanceHandler = function(player)
            local handler = eventHandlers['QBCore:Server:PlayerLoaded'] and eventHandlers['QBCore:Server:PlayerLoaded'][2]
            if handler then handler(player) end
        end,
        --- Steps this fixture's own thread runner once -- the ONLY caller
        --- of appearance.lua's forced-timeout sweep thread. See that
        --- thread's own header for why a cooperating client's answer gets
        --- a full grace period but cannot veto a revert forever.
        stepSweepThread = function() threadRunner.step() end,
        --- Inverse of grantPermissionDirect -- removes the fake row AND
        --- re-warms PermissionCache the same way, so HasPermission
        --- genuinely reflects the removal (not just the underlying fake
        --- table) for tests that need to simulate "no longer qualifies via
        --- ANY path" WITHOUT going through the real, audited RevokePermission
        --- (which itself already calls MaybeRevertK9Appearance as a side
        --- effect -- using it here would revert BEFORE this fixture's own
        --- explicit MaybeRevertK9Appearance call under test ever ran).
        revokePermissionDirect = function(citizenid, permissionKey)
            if fakePermissions[citizenid] then fakePermissions[citizenid][permissionKey] = nil end
            local player = playersByCitizenId[citizenid]
            -- Deliberately fires ONLY the FIRST-registered PlayerLoaded
            -- handler -- permissions.lua's own, guaranteed first by this
            -- fixture's own fixed Sandbox.loadInto order above
            -- (cooldowns -> highcommand -> permissions -> appearance).
            -- Firing EVERY registered handler here (an earlier draft did)
            -- also fires server/appearance.lua's OWN PlayerLoaded handler,
            -- which lazily captures original_model_hash from a "live" ped
            -- the moment ANY connect-shaped event reaches it -- correct
            -- production behavior, but it silently gives a fallback-model
            -- test a captured original it was specifically trying to NOT
            -- have, since this helper's whole point is warming
            -- PermissionCache, not simulating a real reconnect.
            if player and eventHandlers['QBCore:Server:PlayerLoaded'] then
                eventHandlers['QBCore:Server:PlayerLoaded'][1](player)
            end
        end,
    }
end

-- Test high-command source: police job, isboss so it clears every rank
-- gate unconditionally (IsHighCommand/IsEligibleCertifier-shaped checks
-- alike) -- this spec is about appearance/role logic, not re-litigating
-- rank-threshold math already covered by highcommand_spec.lua/
-- permissions_spec.lua.
local HIGH_COMMAND_SRC = 1
local NON_HIGH_COMMAND_SRC = 2
local TARGET_SRC = 3

local function setupGranterAndTarget(f, targetJob)
    f.registerPlayer(HIGH_COMMAND_SRC, 'CITIZEN_HC', { name = 'police', isboss = true, grade = { level = 10 } })
    f.registerPlayer(NON_HIGH_COMMAND_SRC, 'CITIZEN_PLAIN', { name = 'police', isboss = false, grade = { level = 0 } })
    f.registerPlayer(TARGET_SRC, 'CITIZEN_TARGET', targetJob or { name = 'police', isboss = false, grade = { level = 0 } })
end

-- ----------------------------------------------------------------------
-- 1. HasK9Role -- the decoupled role check itself.
-- ----------------------------------------------------------------------

t.test('HasK9Role: false for a citizenid with neither an active cert nor an active k9.access permission', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: true via an active k9.access PERMISSION alone (no certification at all)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantPermissionDirect('CITIZEN_TARGET', 'k9.access')
    t.isTrue(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: true via an active CERTIFICATION for the target\'s current job alone (no permission grant at all)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    t.isTrue(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: a cert for a DIFFERENT job than the target\'s CURRENT job does not count', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'sheriff') -- target's live job is 'police'
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

-- ----------------------------------------------------------------------
-- 2. LOAD-BEARING CASE: a human ped CAN hold the role with
--    requireK9ModelForRole false -- ApplyK9PedRole never reads the
--    target's ped model at all (no GetEntityModel/GetPlayerPed call on the
--    grant path whatsoever), so it is model-independent BY CONSTRUCTION,
--    not merely "happens to pass" for a human target.
-- ----------------------------------------------------------------------

t.test('ApplyK9PedRole: grants the K9 role to an ONLINE target and HasK9Role reflects it immediately -- the target\'s ped model is never consulted (requireK9ModelForRole false, the default)', function()
    local f = newFixture({ requireK9ModelForRole = false })
    setupGranterAndTarget(f)
    t.isFalse(f.env.HasK9Role(TARGET_SRC), 'sanity: not yet a K9')

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.isTrue(f.env.HasK9Role(TARGET_SRC), 'the target now holds the K9 role, purely as a server-side assignment -- nothing here ever asked what they currently look like')
end)

t.test('ApplyK9PedRole: sends the ped swap to the ONLINE target client with the exact chosen model', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1].targetSrc, TARGET_SRC)
    t.equals(f.clientEvents[1].eventName, 'qbx_k9unit:client:applyK9Ped')
    t.equals(f.clientEvents[1][2], 'a_c_husky') -- payload: modelNameOrHash
end)

t.test('ApplyK9PedRole: an unconfigured model name is rejected outright -- no permission grant attempted, no swap ever requested', function()
    local f = newFixture()
    setupGranterAndTarget(f)

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_totally_made_up')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_model')
    t.equals(#f.clientEvents, 0)
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

t.test('ApplyK9PedRole: re-applying a DIFFERENT model to a citizenid who already holds the role is NOT blocked by "already_granted" -- the swap still goes out', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantPermissionDirect('CITIZEN_TARGET', 'k9.access') -- already holds the role, e.g. via an earlier grant

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1][2], 'a_c_husky')
end)

t.test('ApplyK9PedRole: an OFFLINE target persists the assignment directly (no swap to send) and reports persisted_offline', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.disconnectPlayer(TARGET_SRC)
    -- GrantPermission itself requires the caller to be resolvable, but not
    -- the TARGET -- targetCitizenid is a bare string throughout that flow,
    -- matching server/permissions.lua's own citizenid-keyed, offline-capable
    -- design (see that file's header).

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'persisted_offline')
    t.equals(#f.clientEvents, 0, 'nobody is online to receive a swap request')
    t.equals(f.fakeAssignments['CITIZEN_TARGET'].model, 'a_c_husky')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'].original_model_hash, 'not yet known -- captured lazily on their next PlayerLoaded')
end)

-- ----------------------------------------------------------------------
-- 3. LOAD-BEARING CASE: a client cannot self-assign. ApplyK9PedRole is
--    server-authoritative end to end via GrantPermission's own
--    IsHighCommand(granterSrc) check -- there is no code path here that
--    ever trusts a client's own claim about its rank or authority.
-- ----------------------------------------------------------------------

t.test('ApplyK9PedRole: a NON-high-command source is denied outright -- no DB write, no swap ever requested, HasK9Role stays false', function()
    local f = newFixture()
    setupGranterAndTarget(f)

    local ok, outcome = f.env.ApplyK9PedRole(NON_HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isFalse(ok)
    t.equals(outcome, 'denied')
    t.equals(#f.clientEvents, 0)
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'])
end)

t.test('ApplyK9PedRole: a target attempting to grant the role TO THEMSELVES is blocked by GrantPermission\'s own self-grant guard, even if they somehow held high command', function()
    local f = newFixture()
    f.registerPlayer(HIGH_COMMAND_SRC, 'CITIZEN_HC', { name = 'police', isboss = true, grade = { level = 10 } })

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_HC', 'a_c_husky')
    t.isFalse(ok)
    t.equals(outcome, 'self_grant_blocked')
    t.equals(#f.clientEvents, 0)
end)

-- ----------------------------------------------------------------------
-- 5. LOAD-BEARING CASE (server half): a failed model load leaves the
--    player untouched -- confirmK9PedSwap(ok=false) never writes
--    k9_ped_assignments, regardless of the reason. The client half (proving
--    SetPlayerModel itself is never called) lives in
--    tests/clientappearance_spec.lua.
-- ----------------------------------------------------------------------

t.test('confirmK9PedSwap: ok=false ("timeout") -- k9_ped_assignments is NEVER written, matching the "abandon, never half-apply" contract', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](requestId, false, 'timeout')

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'no row was ever written for a swap that never actually landed')
end)

t.test('confirmK9PedSwap: ok=false ("engaged") -- same "never half-applied" guarantee', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](requestId, false, 'engaged')

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'])
end)

t.test('confirmK9PedSwap: ok=true -- NOW the row is written, with the model actually confirmed applied', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](requestId, true, nil)

    t.equals(f.fakeAssignments['CITIZEN_TARGET'].model, 'a_c_husky')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
end)

t.test('confirmK9PedSwap: a forged/stale requestId (does not match the real pending one) is ignored -- no write, no crash', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')

    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap']('not-the-real-request-id', true, nil)

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'])
end)

-- ----------------------------------------------------------------------
-- 6. LOAD-BEARING CASE: revoke restores the original appearance.
-- ----------------------------------------------------------------------

t.test('MaybeRevertK9Appearance: no-op when the citizenid has no active k9_ped_assignments row at all (cheap common case)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')
    t.equals(#f.clientEvents, 0)
end)

t.test('MaybeRevertK9Appearance: reverts to the captured ORIGINAL model hash when the citizenid no longer qualifies via ANY path', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.fakeAssignments['CITIZEN_TARGET'].original_model_hash = -999888777 -- simulate a captured original
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- no longer qualifies via ANY path
    f.clearClientEvents() -- reset so the revert's own swap request is the only one asserted below
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1].eventName, 'qbx_k9unit:client:applyK9Ped')
    t.equals(f.clientEvents[1][2], -999888777, 'the exact original hash, restored -- not a default')
end)

t.test('MaybeRevertK9Appearance: falls back to Config.K9Appearance.fallbackHumanModel when no original was ever captured', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    -- original_model_hash is nil here (never captured) -- exactly the
    -- "install had an existing K9 before this feature shipped" case.
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- no longer qualifies via ANY path
    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1][2], 'mp_m_freemode_01', 'a NAME this time, not a hash -- fallbackHumanModel is configured by string')
end)

t.test('MaybeRevertK9Appearance: REFUSES to guess when no original was captured AND no fallbackHumanModel is configured -- never strands, never invents a model', function()
    local f = newFixture({ fallbackHumanModel = nil })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')

    t.equals(#f.clientEvents, 0)
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'left exactly as they were rather than guessing -- an operator must configure fallbackHumanModel to close this gap')
end)

t.test('MaybeRevertK9Appearance: does NOT revert when the citizenid still independently qualifies via a SEPARATE active certification', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky') -- grants via k9.access permission
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.grantCertDirect('CITIZEN_TARGET', 'police') -- ALSO independently certified

    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET') -- e.g. their k9.access permission alone was revoked
    t.equals(#f.clientEvents, 0, 'still certified -- appearance must not be reverted out from under a citizenid who genuinely still holds the role')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
end)

t.test('MaybeRevertK9Appearance: disabled outright when Config.K9Appearance.restoreOriginalPedOnRevoke is false', function()
    local f = newFixture({ restoreOriginalPedOnRevoke = false })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)

    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')
    t.equals(#f.clientEvents, 0)
end)

t.test('RevokePermission: revoking a target\'s ONLY active k9.access grant (fully removed) triggers a revert', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    -- ApplyK9PedRole already consumed PermissionActionCooldown for
    -- HIGH_COMMAND_SRC (it calls GrantPermission internally, and that
    -- cooldown is shared with RevokePermission -- same instance, same key,
    -- per permissions.lua's own header) -- advance past
    -- PERMISSION_ACTION_COOLDOWN_MS (1500) or this revoke is silently rate-limited.
    f.advanceTime(2000)

    local ok, outcome, stillHasAccess = f.env.RevokePermission(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'k9.access')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.isNil(stillHasAccess, 'fully removed -- nothing else grants them k9.access')
    t.equals(#f.clientEvents, 1, 'MaybeRevertK9Appearance fired as a direct consequence of the revoke')
    t.equals(f.clientEvents[1].eventName, 'qbx_k9unit:client:applyK9Ped')
end)

t.test('RevokePermission: revoking k9.access while a SEPARATE certification still qualifies them (stillHasAccess) does NOT revert appearance', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    f.clearClientEvents()
    f.advanceTime(2000) -- see the previous test's identical comment on PermissionActionCooldown

    local ok, _, stillHasAccess = f.env.RevokePermission(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'k9.access')
    t.isTrue(ok)
    t.equals(stillHasAccess, 'rank_or_high_command')
    t.equals(#f.clientEvents, 0, 'still genuinely a K9 by certification -- must not be reverted')
end)

-- ----------------------------------------------------------------------
-- 7. ForceRevertK9Appearance -- the tablet's explicit, credential-BLIND
--    "remove K9 ped, revert to human" action (server/tablet.lua). See
--    that function's own doc comment: authorization is the GRANTER alone
--    (high command), NEVER the target's own credential state -- both
--    directions of the "no unbounded trap" rule apply here.
-- ----------------------------------------------------------------------

t.test('ForceRevertK9Appearance: a NON-high-command source is denied outright', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()

    local ok, outcome = f.env.ForceRevertK9Appearance(NON_HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isFalse(ok)
    t.equals(outcome, 'denied')
    t.equals(#f.clientEvents, 0)
end)

t.test('ForceRevertK9Appearance: succeeds EVEN WHILE the target still holds an active certification -- deliberately credential-blind, unlike MaybeRevertK9Appearance', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.grantCertDirect('CITIZEN_TARGET', 'police') -- still, on paper, certified
    f.clearClientEvents()
    f.advanceTime(2000) -- past AppearanceActionCooldown from the ApplyK9PedRole call above

    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#f.clientEvents, 1, 'reverted anyway -- the role and the appearance are being deliberately decoupled by this action')
    t.isTrue(f.env.HasK9Role(TARGET_SRC), 'the CERTIFICATION itself is untouched by this action -- only the appearance changed, exactly as the owner specified')
end)

t.test('ForceRevertK9Appearance: NO UNBOUNDED TRAP -- succeeds on a target who has ALREADY lost every credential (the exact case an automatic revert would already have handled, but this must not depend on that having happened)', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- simulate: credential already gone, e.g. by some other path
    f.clearClientEvents()
    f.advanceTime(2000)

    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#f.clientEvents, 1)
end)

t.test('ForceRevertK9Appearance: no active assignment at all is reported honestly, not as a false success', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isFalse(ok)
    t.equals(outcome, 'no_active_assignment')
end)

-- ----------------------------------------------------------------------
-- 8. SECURITY: a revert must complete with the client silent, hostile, or
--    gone -- it may never be vetoable by the party it terminates.
-- ----------------------------------------------------------------------

t.test('SECURITY: disconnecting mid-revert COMMITS the revert immediately -- does NOT leave the stale active=1 row for a future reconnect to resurrect', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000)

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET') -- sends the revert; NEVER confirmed below
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'not yet committed -- still awaiting the client\'s own confirm, exactly as an APPLY would be')

    -- The target disconnects before ever replying. Real FXServer's own
    -- 'playerDropped' fires BEFORE the framework fully tears down the
    -- player object (server/certifications.lua's own playerDropped
    -- handler comment already establishes this for this exact fixture
    -- shape) -- so the handler runs FIRST, exports.qbx_core:GetPlayer(src)
    -- still resolves, and ONLY THEN is the player actually removed from
    -- this fixture's own registry.
    f.env.source = TARGET_SRC
    for _, handler in ipairs(f.eventHandlers['playerDropped'] or {}) do handler('testing') end
    f.disconnectPlayer(TARGET_SRC)

    t.isFalse(f.fakeAssignments['CITIZEN_TARGET'].active, 'committed on disconnect -- the decision was already made server-side; only the visual confirm was missing')
end)

t.test('SECURITY: disconnecting mid-APPLY does NOT write anything -- the apply/revert asymmetry is preserved (an apply with no pre-existing state stays a clean no-op)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'not yet confirmed by the client at all')

    f.env.source = TARGET_SRC
    for _, handler in ipairs(f.eventHandlers['playerDropped'] or {}) do handler('testing') end
    f.disconnectPlayer(TARGET_SRC)

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'still nothing written -- a dropped pending APPLY is a genuine no-op, unlike a dropped REVERT')
end)

t.test('SECURITY: a hostile client that never confirms a revert cannot hold it open forever -- the sweep thread forces it through once the grace period elapses', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000)

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET') -- the target simply never replies from here on
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'still pending -- the grace period has not elapsed yet')

    f.stepSweepThread() -- primes the coroutine (its first statement is Wait(...)) -- no pass yet, per Sandbox.newThreadRunner's own documented stepping semantics
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'still nothing -- this step only reached the sweep loop\'s own Wait()')

    f.advanceTime(14000) -- past ApplyRequestTtlMs (modelLoadTimeoutMs 8000 default + 5000ms margin = 13000)
    f.stepSweepThread() -- NOW runs one real sweep pass
    t.isFalse(f.fakeAssignments['CITIZEN_TARGET'].active, 'forced through -- a hostile or unresponsive client cannot veto a revert past its own grace period')
end)

t.test('SECURITY BACKSTOP: PlayerLoaded refuses to re-apply a persisted active row for a citizenid who no longer holds the K9 role by any path -- clears the stale row instead', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    -- Credential lost through some OTHER path, without going through
    -- RevokePermission/MaybeRevertK9Appearance at all -- exactly the
    -- "any other way a stale active row could occur" this backstop exists
    -- for, independent of the disconnect-during-revert fix above.
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access')
    f.clearClientEvents()

    f.firePlayerLoadedAppearanceHandler({ PlayerData = { citizenid = 'CITIZEN_TARGET', source = TARGET_SRC } })

    t.isFalse(f.fakeAssignments['CITIZEN_TARGET'].active, 'the stale row was cleared, not re-applied')
    t.equals(#f.clientEvents, 0, 'no K9 model was pushed to a citizenid who no longer holds the role')
end)

t.test('PlayerLoaded: a citizenid who STILL holds the role gets the normal re-apply-on-reconnect behavior, unaffected by the HasK9Role backstop', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['qbx_k9unit:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()

    f.firePlayerLoadedAppearanceHandler({ PlayerData = { citizenid = 'CITIZEN_TARGET', source = TARGET_SRC } })

    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
    t.equals(#f.clientEvents, 1, 'still certified -- the K9 model is re-pushed on reconnect, exactly as before this backstop existed')
end)

os.exit(t.summary())
