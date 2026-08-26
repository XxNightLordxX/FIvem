--[[
    tests/clientradial_spec.lua

    Second client-side spec in this suite (tests/main_spec.lua is the
    first and the worked example this file follows -- same fresh-sandbox-
    per-test discipline, same "drive the real registered thing, never a
    reimplementation" rule).

    SCOPE, per this pass's own task brief: client/radial.lua is almost
    pure table construction -- it builds a set of ox_lib radial menu items
    behind Config.Features flags, then hands them to
    lib.registerRadial/lib.addRadialItem. What matters most, and what this
    file is built to catch, is exactly the class of bug that "looks fine"
    at a glance: an item that appears when its flag is false, one that's
    missing when its flag is true, a duplicate id silently shadowing
    another item in ox_lib's own registry, or an onSelect closure that
    calls a nil global and throws the instant a player clicks it.

    LOAD-TIME TABLE CONSTRUCTION, NOT RUNTIME -- IMPORTANT FOR THIS FIXTURE:
    every `if Config.Features.X then k9SubmenuItems[#k9SubmenuItems+1] =
    {...} end` branch in client/radial.lua runs ONCE, when the file is
    loaded, not on every call. There is no live re-evaluation the way
    ox_target's canInteract predicate works (see that file's own "OPEN
    STRUCTURAL QUESTION" comment). That means testing "does flag X being
    true/false change which items appear" REQUIRES loading a fresh copy of
    client/radial.lua per flag combination -- toggling a field on an
    already-loaded env's Config table after load does nothing, since the
    branches already ran. newRadialFixture() below therefore takes a
    `features` table of overrides, applies them to the REAL config.lua's
    Config.Features BEFORE loading client/radial.lua, and is called fresh
    (a brand new env, a brand new Config table -- config.lua's own `Config
    = {}` literal is freshly constructed every time it's loaded into a new
    env, so mutating one fixture's Config.Features can never leak into
    another fixture) for every single test in this file, exactly like
    main_spec.lua's own newMainFixture() discipline.

    FIXED BASELINE, NOT "config.lua's live shipped defaults" -- confirmed
    the hard way while writing this file: config.lua is edited
    concurrently by other agents in this repo, and several flags this spec
    treats as a stable reference point (ScentTracking, BiteAndHold, and
    others) were briefly flipped to `true` mid-session by someone else's
    unrelated pass, which made a batch of "absent under the default" tests
    below flap to FAIL for a reason with nothing to do with
    client/radial.lua. newRadialFixture() therefore applies ITS OWN fixed
    baseline table to Config.Features (RadialMenu/LeashMechanics/
    VehicleEntryExit/BasicBarkSounds on, every later-phase flag off --
    matching the Phase 1 vertical slice's own intended shape) immediately
    after loading the real config.lua, BEFORE applying whatever
    `opts.features` a given test asks for. See that baseline's own comment,
    right where it's built, for the full reasoning. This file makes NO
    assertion anywhere about what config.lua's real values happen to be at
    any given moment -- every presence/absence test below sets the ONE flag
    it cares about explicitly, and everything else comes from this spec's
    own stable baseline, not from the live file.

    STUBBING EFFORT, reported honestly per this task's own instruction:
    every native this file's LOAD-TIME table construction touches is
    trivial (locale(), Config, lib.registerRadial, lib.addRadialItem -- four
    stand-ins, none of them a real game native). The natives only start
    mattering once a test actually INVOKES an onSelect closure (candidate-
    search helpers use PlayerPedId/GetEntityCoords/GetActivePlayers/
    PlayerId/GetPlayerPed/DoesEntityExist/GetPlayerServerId; individual
    items call ~30 more cross-file globals, none of them real client
    natives at all -- they are this resource's OWN globals, defined in
    other files this spec never loads). None of that required
    "disproportionate" stubbing in the sense DEVELOPER_REFERENCE.md's stale
    pre-main_spec.lua audit worried about: every one of those ~30 globals
    is a simple call-recording stand-in (record a call, optionally return a
    canned value), the same shape already used throughout this suite's
    server-side specs for RegisterCommand/TriggerClientEvent/etc. See this
    file's own closing comment (bottom) for the one genuine, disclosed
    finding this pass turned up while building this fixture.

    VECTOR STUB: identical shape to combat_spec.lua/certifications_spec.lua/
    tenure_spec.lua's own copies (a real FiveM vector3 supports `-`
    (component-wise) and `#` (magnitude) via operator metamethods;
    FindNearestLeashCandidate/FindNearestPartnerCandidate below do
    `#(myCoords - GetEntityCoords(targetPed))`, so both must be real
    operators here, not plain tables).

    OX_LIB RESTART LIFECYCLE COVERAGE (added this pass, dependency-
    verification finding): client/radial.lua's own registration calls used
    to run as bare top-level statements at file-load time; they now live
    inside one idempotent RegisterK9RadialMenu() function, invoked by an
    `AddEventHandler('onResourceStart', ...)` dispatcher that fires on
    EITHER this resource's own start OR ox_lib's (see that function's own
    doc comment in client/radial.lua for the full writeup). This fixture
    therefore now ALSO stubs `AddEventHandler`/`GetCurrentResourceName` --
    same idiom as tests/inventory_spec.lua's own `fireResourceStart` /
    `wipeHookRegistrations` pair, which covers the identical "does the
    dependency's own restart re-trigger our registration" bug class against
    ox_inventory instead of ox_lib -- and auto-fires this resource's OWN
    start once, right after loading client/radial.lua, so every ALREADY
    EXISTING test below (all written against the OLD "registration runs
    immediately at load" behavior) keeps working completely unchanged: real
    FXServer reliably fires `onResourceStart` for a resource's own boot
    (see client/movement.lua's/client/fetch.lua's own established
    `AddEventHandler('onResourceStart', ...)` idiom, already relied on
    elsewhere in this codebase), so auto-firing it here is a faithful
    representation of real startup, not a shortcut that hides behavior.
    Only the NEW tests near the bottom of this file (search "OX_LIB RESTART
    LIFECYCLE") explicitly drive `f.wipeOxLibRadialState()` +
    `f.fireResourceStart(...)` to prove the fix.

    LIVE-STATE MODELING, NOT JUST A RAW CALL LOG (needed for the new tests
    to have real teeth): `lib.registerRadial`/`lib.addRadialItem` below now
    maintain a small keyed model -- `liveMenus` (id -> items, exactly
    mirroring ox_lib's real `menus[radial.id] = radial` key-based
    overwrite) and `liveRootItems` (an id-deduped array, exactly mirroring
    ox_lib's real `lib.addRadialItem` scan-and-replace-or-append algorithm,
    verified against ox_lib's own source this pass) -- IN ADDITION to the
    original flat `registerRadialCalls`/`addRadialItemCalls` audit-trail
    arrays (kept, unchanged, for the one existing test that still reads
    `addRadialItemCalls` directly). `findMenu`/`findRootItem`/`findInMenu`/
    `allIds` below now read from the live model instead of the raw log --
    for every EXISTING test (which only ever registers once per fixture)
    this is byte-identical behavior to before, since "first match in the
    log" and "current value in the live model" are the same thing when
    there is only one registration; it only starts to matter, correctly,
    once a test re-registers and needs "what does ox_lib actually think is
    registered RIGHT NOW" rather than "every call ever made."
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- PENDING LOCALE KEYS -- TEMPORARY, see this pass's own report for the
-- exact addition needed to locales/en.json (five new keys under the
-- existing "radial" group, English text below). This file's own hard rule
-- is "never edit locales/en.json" -- Sandbox.locale (fixtures/sandbox.lua)
-- deliberately RAISES on a key that genuinely doesn't exist there yet
-- (exactly the drift-detection behaviour this suite wants), which would
-- otherwise turn every test in this file red the instant
-- client/radial.lua's own load-time table construction reaches the new
-- Search & Rescue Call / Training items below (both flags ship `true` in
-- the real config.lua, so they run on every fixture that doesn't
-- explicitly turn them off).
--
-- pendingLocale(key, ...) tries the REAL Sandbox.locale FIRST and only
-- substitutes the placeholder text below when that genuinely raises --
-- the moment the real keys land in locales/en.json, this table becomes
-- silently unused (Sandbox.locale succeeds on its own, this fallback never
-- triggers) with no follow-up edit required here, and any OTHER, unrelated
-- missing key still raises exactly as before (never silently swallowed).
-- REMOVE this table and pendingLocale, and switch every call site below
-- back to plain `locale(...)`, once the real keys land.
local PENDING_LOCALE_KEYS = {
    ['radial.sar_call_toggle_label'] = 'Search & Rescue Call',
    ['radial.training_menu_label'] = 'Training',
    ['radial.training_toggle_label'] = 'Start/Stop Training',
    ['radial.training_search_label'] = 'Practice Search',
    ['radial.training_bite_label'] = 'Practice Bite & Hold',
}
local function pendingLocale(key, ...)
    local ok, value = pcall(Sandbox.locale, key, ...)
    if ok then return value end
    local pending = PENDING_LOCALE_KEYS[key]
    if pending then return pending end
    error(value, 0) -- a genuinely unrelated missing key -- never silently swallow it
end

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- see header comment above.
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
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua (with
--- `opts.features` merged onto its Config.Features table BEFORE
--- client/radial.lua loads -- see this file's header on why load order
--- matters here) + the real client/radial.lua, plus a capturing/
--- controllable stand-in for every global either file's load-time or
--- exercised-onSelect call paths touch.
---
--- `opts.omit` is a list of cross-file global NAMES to leave entirely
--- undefined in the sandbox (so `env.<Name>` reads back nil) -- used only
--- by the "does this onSelect's target carry a type()=='function' guard"
--- tests below, to prove the guarded ones degrade cleanly and the
--- unguarded ones do not.
--- @param opts { features: table?, omit: string[]?, canShowK9UI: boolean?, hasK9Access: boolean? }?
--- @return table fixture
local function newRadialFixture(opts)
    opts = opts or {}
    local omitSet = {}
    for _, name in ipairs(opts.omit or {}) do omitSet[name] = true end

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end

    local canShowK9UICalls, denyCalls, hasK9AccessCalls = 0, 0, 0
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end
    local function HasK9Access() hasK9AccessCalls = hasK9AccessCalls + 1; return hasK9Access end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as CanShowK9UI/DenyK9UIAccess
    -- above. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false. Only
    -- RadialMenu/AdvancedBarkRadial are meaningful here -- see
    -- client/radial.lua's own "K9 UNIT RADIAL -- PER-PERSON BLOCK" header
    -- for why this file checks those two at REGISTRATION time, unlike
    -- every other feature this pass touches.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end
    local denyK9FeatureBlockedCallCount = 0
    local function DenyK9FeatureBlocked() denyK9FeatureBlockedCallCount = denyK9FeatureBlockedCallCount + 1 end

    -- Generic call log: calls[name] is a list of arg-tuples, one per
    -- invocation, for every plain "do a thing" cross-file global below.
    local calls = {}
    local function record(name)
        return function(...)
            calls[name] = calls[name] or {}
            calls[name][#calls[name] + 1] = { ... }
        end
    end

    -- Controllable "current state" query stubs (IsLeashed/IsInK9Vehicle/
    -- GetActiveTrackType/IsBiteHoldEngaged/IsDragEngaged/
    -- IsFetchCarryEngaged) -- each ALSO logs its own call into `calls` so a
    -- test can assert a release branch never re-derives state it doesn't
    -- need (e.g. Detach Leash never calling CanShowK9UI at all).
    local queryState = {
        isLeashed = false, isInK9Vehicle = false, activeTrackType = nil,
        isBiteHoldEngaged = false, isDragEngaged = false, isFetchCarryEngaged = false,
        isSarCallActive = false, isTrainingModeActive = false,
    }
    local function queryFn(name, field)
        return function(...)
            calls[name] = calls[name] or {}
            calls[name][#calls[name] + 1] = { ... }
            return queryState[field]
        end
    end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    -- LIVE ox_lib STATE MODEL -- see this file's header ("LIVE-STATE
    -- MODELING") for why this exists alongside the raw call-log arrays
    -- below. `liveMenus[id]` mirrors ox_lib's real `menus[radial.id] =
    -- radial` (a plain keyed overwrite -- a second registerRadial call for
    -- the same id REPLACES, never duplicates). `liveRootItems` mirrors
    -- ox_lib's real `lib.addRadialItem` id-scan-then-replace-or-append
    -- algorithm for the (nil parentMenuId) root wheel -- the only shape our
    -- own code ever calls it with.
    local liveMenus = {}
    local liveRootItems = {}

    local registerRadialCalls = {}
    local function lib_registerRadial(def)
        registerRadialCalls[#registerRadialCalls + 1] = def
        liveMenus[def.id] = def.items
    end

    local addRadialItemCalls = {}
    local function lib_addRadialItem(items, parentMenuId)
        addRadialItemCalls[#addRadialItemCalls + 1] = items
        -- Our own code never calls this with a parentMenuId (every
        -- k9SubmenuItems-style submenu is built as a plain local table and
        -- registered wholesale via lib.registerRadial instead -- see
        -- client/radial.lua's own header on why `menu` is navigation, not
        -- grouping) -- only the root-wheel (nil parentMenuId) case needs a
        -- faithful id-dedup model here.
        local target = parentMenuId and (liveMenus[parentMenuId] or {}) or liveRootItems
        for _, item in ipairs(items) do
            local replacedExisting = false
            for i, existing in ipairs(target) do
                if existing.id == item.id then
                    target[i] = item
                    replacedExisting = true
                    break
                end
            end
            if not replacedExisting then
                target[#target + 1] = item
            end
        end
    end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    -- OX_LIB RESTART LIFECYCLE stubs -- same `AddEventHandler`/
    -- `GetCurrentResourceName` idiom as tests/inventory_spec.lua,
    -- tests/kennel_spec.lua, tests/fetch_spec.lua, etc. `eventHandlers` is
    -- exposed (indirectly, via `fireResourceStart` below) so this file can
    -- drive client/radial.lua's RegisterK9RadialMenu() dispatcher exactly
    -- the way real FXServer would -- once for this resource's own start,
    -- and again for a later, independent ox_lib restart.
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function GetCurrentResourceName() return 'qbx_k9unit' end
    local function fireResourceStart(resourceName)
        for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
            handler(resourceName)
        end
    end
    --- Fires client/featureblocks.lua's own local
    --- `qbx_k9unit:client:featureBlocksApplied` re-broadcast (REQUESTED --
    --- this spec drives it directly rather than loading that file for
    --- real, same "stub the cross-file dependency" convention as
    --- everything else in this fixture) -- proves RegisterK9RadialMenu()
    --- genuinely re-runs (and re-evaluates the two block checks) on this
    --- event, not just on a resource/ox_lib restart.
    local function fireFeatureBlocksApplied()
        for _, handler in ipairs(eventHandlers['qbx_k9unit:client:featureBlocksApplied'] or {}) do
            handler()
        end
    end

    -- FindNearestLeashCandidate/FindNearestPartnerCandidate's natives.
    local myPed = 1
    local pedCoords = { [1] = vec3(0, 0, 0) }
    local activePlayers = {}
    local playerPeds = {}
    local playerServerIds = {}
    local function PlayerPedId() return myPed end
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end
    local function GetActivePlayers() return activePlayers end
    local function PlayerId() return 0 end -- local player's own playerId; test setup never puts 0 into activePlayers
    local function GetPlayerPed(playerId) return playerPeds[playerId] or 0 end
    local function DoesEntityExist(entity) return entity ~= 0 and entity ~= nil end
    local function GetPlayerServerId(playerId) return playerServerIds[playerId] end

    local allStubs = {
        K9Sit = record('K9Sit'),
        IsLeashed = queryFn('IsLeashed', 'isLeashed'),
        DetachLeash = record('DetachLeash'),
        RequestLeashAttach = record('RequestLeashAttach'),
        IsInK9Vehicle = queryFn('IsInK9Vehicle', 'isInK9Vehicle'),
        EnterNearestK9Vehicle = record('EnterNearestK9Vehicle'),
        ExitK9Vehicle = record('ExitK9Vehicle'),
        GetActiveTrackType = queryFn('GetActiveTrackType', 'activeTrackType'),
        StopTracking = record('StopTracking'),
        StartScentTrack = record('StartScentTrack'),
        StartBloodTrack = record('StartBloodTrack'),
        StartGunpowderTrack = record('StartGunpowderTrack'),
        IsBiteHoldEngaged = queryFn('IsBiteHoldEngaged', 'isBiteHoldEngaged'),
        ReleaseBiteHold = record('ReleaseBiteHold'),
        RequestBiteHold = record('RequestBiteHold'),
        RequestTakedown = record('RequestTakedown'),
        IsDragEngaged = queryFn('IsDragEngaged', 'isDragEngaged'),
        ReleaseDrag = record('ReleaseDrag'),
        RequestDrag = record('RequestDrag'),
        BreakPartnership = record('BreakPartnership'),
        RequestPartnerUp = record('RequestPartnerUp'),
        RequestRecall = record('RequestRecall'),
        ConfirmHandlerDownDefense = record('ConfirmHandlerDownDefense'),
        IsFetchCarryEngaged = queryFn('IsFetchCarryEngaged', 'isFetchCarryEngaged'),
        ReleaseFetchBall = record('ReleaseFetchBall'),
        RequestThrowFetchBall = record('RequestThrowFetchBall'),
        RequestRecallFetchBall = record('RequestRecallFetchBall'),
        RequestToggleK9PropAttachment = record('RequestToggleK9PropAttachment'),
        RequestDeployKennel = record('RequestDeployKennel'),
        ExitKennelRest = record('ExitKennelRest'),
        RequestOpenOwnK9Inventory = record('RequestOpenOwnK9Inventory'),
        RequestTreatNearestK9 = record('RequestTreatNearestK9'),
        IsSarCallActive = queryFn('IsSarCallActive', 'isSarCallActive'),
        RequestStartSarCall = record('RequestStartSarCall'),
        RequestAbandonSarCall = record('RequestAbandonSarCall'),
        IsTrainingModeActive = queryFn('IsTrainingModeActive', 'isTrainingModeActive'),
        RequestSetTrainingMode = record('RequestSetTrainingMode'),
        RequestTrainingSearchDrill = record('RequestTrainingSearchDrill'),
        RequestTrainingBiteDrill = record('RequestTrainingBiteDrill'),
    }

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        TriggerServerEvent = TriggerServerEvent,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        GetActivePlayers = GetActivePlayers,
        PlayerId = PlayerId,
        GetPlayerPed = GetPlayerPed,
        DoesEntityExist = DoesEntityExist,
        GetPlayerServerId = GetPlayerServerId,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        lib = { registerRadial = lib_registerRadial, addRadialItem = lib_addRadialItem, notify = lib_notify },
        -- TEMPORARY -- see this file's own "PENDING LOCALE KEYS" header
        -- comment. Overrides Sandbox.newEnv's own default `env.locale =
        -- Sandbox.locale` assignment (the overrides loop in
        -- fixtures/sandbox.lua's newEnv runs AFTER that default, so this
        -- wins) with a wrapper that only ever differs from the real thing
        -- for the five keys named there.
        locale = pendingLocale,
    }
    for name, fn in pairs(allStubs) do
        if not omitSet[name] then overrides[name] = fn end
    end
    if featureBlocksAvailable then
        overrides.IsK9FeatureBlocked = IsK9FeatureBlocked
        overrides.DenyK9FeatureBlocked = DenyK9FeatureBlocked
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- THIS SPEC'S OWN FIXED BASELINE -- deliberately NOT "whatever
    -- config.lua currently ships." config.lua is a live file other agents
    -- edit concurrently in this repo (confirmed mid-session: ScentTracking/
    -- BiteAndHold/etc. were briefly flipped to `true` by someone else's
    -- pass while this spec was being written, which made several
    -- "absent under the shipped default" assertions below flap to FAIL for
    -- a reason that had nothing to do with client/radial.lua). Every test
    -- in this file that cares about a SPECIFIC flag combination sets that
    -- combination explicitly via `opts.features`; this baseline just gives
    -- every other, unrelated flag a known, stable value first so a test
    -- that only means to exercise ONE flag doesn't silently inherit
    -- whatever value a dozen OTHER flags happen to carry in the real file
    -- at the moment this spec happens to run. This baseline mirrors the
    -- Phase 1 vertical slice's own intended shape (RadialMenu/
    -- LeashMechanics/VehicleEntryExit/BasicBarkSounds on, everything later
    -- off) but is NOT itself an assertion about config.lua's real, current
    -- defaults -- this file makes no claim about those at all.
    local baseline = {
        RadialMenu = true, LeashMechanics = true, VehicleEntryExit = true, BasicBarkSounds = true,
        AdvancedBarkRadial = false, ScentTracking = false, BloodTracking = false, GunpowderSniffing = false,
        BiteAndHold = false, NonLethalTakedown = false, PropDragging = false, HandlerPartnership = false,
        Recall = false, HandlerDownDefense = false, FetchMechanic = false, PropAttachments = false,
        DeployableKennel = false, K9Inventory = false, K9Medkit = false,
        -- SARCalls/TrainingMode -- ADDED THIS PASS, closing the exact gap
        -- this baseline's own header comment already worries about: both
        -- flags landed in the real config.lua (shipping `true`) AFTER this
        -- baseline table was first written, and neither was added here at
        -- the time -- so every test in this file that doesn't explicitly
        -- request one of them was silently inheriting `true` from the real,
        -- live file instead of a stable, spec-owned value, exactly the
        -- "flap for a reason that has nothing to do with client/radial.lua"
        -- failure mode this baseline exists to prevent.
        SARCalls = false, TrainingMode = false,
    }
    for key, value in pairs(baseline) do
        env.Config.Features[key] = value
    end
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end
    Sandbox.loadInto('../client/radial.lua', env)

    -- Auto-fire THIS resource's own start, exactly once, immediately after
    -- loading -- see this file's header ("OX_LIB RESTART LIFECYCLE
    -- COVERAGE") for why: client/radial.lua's registration calls now only
    -- run when RegisterK9RadialMenu() is invoked by its own
    -- `AddEventHandler('onResourceStart', ...)` dispatcher, and real
    -- FXServer reliably fires that event for a resource's own boot. Doing
    -- it here, transparently, means every test below that predates this
    -- lifecycle fix keeps working completely unchanged.
    fireResourceStart('qbx_k9unit')

    return {
        env = env,
        Config = env.Config,
        registerRadialCalls = registerRadialCalls,
        addRadialItemCalls = addRadialItemCalls,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        calls = calls,

        --- @param id string -- a lib.registerRadial menu id (e.g. 'k9unit')
        --- @return table? items
        findMenu = function(id)
            return liveMenus[id]
        end,

        --- @param id string -- a root-wheel item id (added via lib.addRadialItem)
        findRootItem = function(id)
            for _, item in ipairs(liveRootItems) do
                if item.id == id then return item end
            end
            return nil
        end,

        --- @param menuId string
        --- @param itemId string
        findInMenu = function(menuId, itemId)
            local items = liveMenus[menuId]
            if not items then return nil end
            for _, item in ipairs(items) do
                if item.id == itemId then return item end
            end
            return nil
        end,

        --- Every id CURRENTLY registered (every live menu's items, plus
        --- every live root item) -- for the no-duplicate-ids check. Reads
        --- the live keyed model, not the raw call log, so this reflects
        --- what ox_lib would actually show right now, even after a
        --- re-registration -- see this file's header ("LIVE-STATE
        --- MODELING") for why that distinction matters.
        allIds = function()
            local ids = {}
            for _, items in pairs(liveMenus) do
                for _, item in ipairs(items) do ids[#ids + 1] = item.id end
            end
            for _, item in ipairs(liveRootItems) do ids[#ids + 1] = item.id end
            return ids
        end,

        -- OX_LIB RESTART LIFECYCLE test helpers -- see this file's header.
        fireResourceStart = fireResourceStart,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        --- Simulates ox_lib's OWN restart reconstructing its two file-local
        --- registries (`menus`/`menuItems` in the real ox_lib source) empty
        --- -- the real mechanism client/radial.lua's onResourceStart
        --- dispatcher exists to recover from. Wipes both the live keyed
        --- model AND the raw call-log arrays (the latter purely so the
        --- NEXT registration pass's own call order can be inspected in
        --- isolation, uncontaminated by calls made before the simulated
        --- restart).
        wipeOxLibRadialState = function()
            for k in pairs(liveMenus) do liveMenus[k] = nil end
            for i = #liveRootItems, 1, -1 do liveRootItems[i] = nil end
            for i = #registerRadialCalls, 1, -1 do registerRadialCalls[i] = nil end
            for i = #addRadialItemCalls, 1, -1 do addRadialItemCalls[i] = nil end
        end,
        --- Order ids were passed to lib.registerRadial, since the last wipe
        --- (or since fixture construction, if never wiped) -- for the
        --- "submenus registered before the items that reference them"
        --- ordering assertions.
        registerRadialOrder = function()
            local order = {}
            for _, def in ipairs(registerRadialCalls) do order[#order + 1] = def.id end
            return order
        end,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        canShowK9UICallCount = function() return canShowK9UICalls end,
        denyCallCount = function() return denyCalls end,
        hasK9AccessCallCount = function() return hasK9AccessCalls end,
        setState = function(field, value) queryState[field] = value end,
        setMyPed = function(handle) myPed = handle end,
        setPedCoords = function(entity, coords) pedCoords[entity] = coords end,
        setActivePlayers = function(list) activePlayers = list end,
        setPlayerPed = function(playerId, ped) playerPeds[playerId] = ped end,
        setPlayerServerId = function(playerId, serverId) playerServerIds[playerId] = serverId end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        denyK9FeatureBlockedCallCount = function() return denyK9FeatureBlockedCallCount end,
        fireFeatureBlocksApplied = fireFeatureBlocksApplied,
        featureBlocksAppliedHandlerCount = function() return #(eventHandlers['qbx_k9unit:client:featureBlocksApplied'] or {}) end,
    }
end

--- @param item table
local function assertGuardDoesNotThrow(item)
    local ok, err = pcall(item.onSelect)
    t.isTrue(ok, ('%s onSelect must not throw when its cross-file target global is entirely absent -- %s'):format(item.id, tostring(err)))
end

-- ----------------------------------------------------------------------
-- Sanity: default (unmodified) real config.lua flags -- the exact shape a
-- freshly-installed server sees.
-- ----------------------------------------------------------------------

t.test('this spec\'s baseline flags: the k9unit submenu is registered and linked from a single root opener item', function()
    local f = newRadialFixture()
    local items = f.findMenu('k9unit')
    t.isNotNil(items, 'lib.registerRadial must be called with id="k9unit"')
    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'lib.addRadialItem must add the single k9unit_open opener to the root wheel')
    t.equals(opener.menu, 'k9unit', 'the opener must navigate into the k9unit submenu just registered')
    t.isNil(opener.onSelect, 'the opener is a pure navigation link, per this file\'s own header on menu-vs-navigation semantics -- it must carry no onSelect of its own')
end)

t.test('this spec\'s baseline flags: Sit, Bark, Leash, Vehicle (Phase 1) are present; every later-phase item stays absent', function()
    local f = newRadialFixture()
    local items = f.findMenu('k9unit')
    local presentIds = {}
    for _, item in ipairs(items) do presentIds[item.id] = true end

    t.isTrue(presentIds.k9_sit)
    t.isTrue(presentIds.k9_bark)
    t.isTrue(presentIds.k9_leash)
    t.isTrue(presentIds.k9_vehicle)
    t.isTrue(presentIds.k9_exit_kennel, 'k9_exit_kennel has no dedicated Config.Features flag of its own -- see this file own header comment on why an exit-adjacent item is registered unconditionally')

    local shouldBeAbsent = {
        'k9_track_scent', 'k9_track_blood', 'k9_track_gunpowder',
        'k9_bite_hold', 'k9_takedown', 'k9_drag',
        'k9_break_partnership', 'k9_partner_up', 'k9_recall', 'k9_defense',
        'k9_fetch', 'k9_prop_attachment', 'k9_deploy_kennel',
        'k9_open_inventory', 'k9_treat_nearest',
        'k9_sar_call', 'k9_training',
    }
    for _, id in ipairs(shouldBeAbsent) do
        t.isFalse(presentIds[id] == true, ('%s must be absent under default (still-false) feature flags'):format(id))
    end
end)

-- ----------------------------------------------------------------------
-- Per-flag presence: flags that ship FALSE and gate exactly one item each
-- in the k9unit submenu.
-- ----------------------------------------------------------------------

local FALSE_BY_DEFAULT_SINGLE_ITEM_CASES = {
    { flag = 'ScentTracking', itemId = 'k9_track_scent' },
    { flag = 'BloodTracking', itemId = 'k9_track_blood' },
    { flag = 'GunpowderSniffing', itemId = 'k9_track_gunpowder' },
    { flag = 'BiteAndHold', itemId = 'k9_bite_hold' },
    { flag = 'NonLethalTakedown', itemId = 'k9_takedown' },
    { flag = 'PropDragging', itemId = 'k9_drag' },
    { flag = 'Recall', itemId = 'k9_recall' },
    { flag = 'PropAttachments', itemId = 'k9_prop_attachment' },
    { flag = 'DeployableKennel', itemId = 'k9_deploy_kennel' },
    -- The two items this task explicitly called out as "wired only
    -- recently, both behind flags that ship false" -- proven here by the
    -- SAME generic mechanism as every other flag/item pair, not a special
    -- case, precisely because nothing about them IS special-cased in the
    -- source.
    { flag = 'K9Inventory', itemId = 'k9_open_inventory' },
    { flag = 'K9Medkit', itemId = 'k9_treat_nearest' },
    -- RESOLVED this pass: closed the exact disclosed gap
    -- client/sarcalls.lua's own header used to name ("not wired into
    -- client/radial.lua by this pass") -- same generic mechanism, nothing
    -- special-cased.
    { flag = 'SARCalls', itemId = 'k9_sar_call' },
}

for _, case in ipairs(FALSE_BY_DEFAULT_SINGLE_ITEM_CASES) do
    t.test(('%s: absent when Config.Features.%s is explicitly false'):format(case.itemId, case.flag), function()
        local f = newRadialFixture()
        t.isNil(f.findInMenu('k9unit', case.itemId))
    end)

    t.test(('%s: appears ONLY when Config.Features.%s is explicitly true'):format(case.itemId, case.flag), function()
        local f = newRadialFixture({ features = { [case.flag] = true } })
        t.isNotNil(f.findInMenu('k9unit', case.itemId), ('%s must appear once %s is true'):format(case.itemId, case.flag))
    end)
end

-- ----------------------------------------------------------------------
-- Per-flag presence: flags that ship TRUE (Phase 1) -- prove the item
-- disappears when explicitly turned off, the mirror image of the cases
-- above.
-- ----------------------------------------------------------------------

local TRUE_BY_DEFAULT_SINGLE_ITEM_CASES = {
    { flag = 'LeashMechanics', itemId = 'k9_leash' },
    { flag = 'VehicleEntryExit', itemId = 'k9_vehicle' },
}

for _, case in ipairs(TRUE_BY_DEFAULT_SINGLE_ITEM_CASES) do
    t.test(('%s: present under this spec\'s baseline (Config.Features.%s = true)'):format(case.itemId, case.flag), function()
        local f = newRadialFixture()
        t.isNotNil(f.findInMenu('k9unit', case.itemId))
    end)

    t.test(('%s: absent when Config.Features.%s is explicitly turned off'):format(case.itemId, case.flag), function()
        local f = newRadialFixture({ features = { [case.flag] = false } })
        t.isNil(f.findInMenu('k9unit', case.itemId))
    end)
end

-- k9_sit has NO dedicated Config.Features flag at all (bundled under the
-- general RadialMenu flag + per-onSelect access check only, per its own
-- comment) -- prove it stays present even with every OTHER flag off.
t.test('k9_sit: present regardless of every other feature flag, since it has no dedicated flag of its own', function()
    local f = newRadialFixture({ features = {
        LeashMechanics = false, VehicleEntryExit = false, BasicBarkSounds = false,
    } })
    t.isNotNil(f.findInMenu('k9unit', 'k9_sit'))
end)

-- ----------------------------------------------------------------------
-- HandlerPartnership -- ONE flag gates TWO items (Break Partnership AND
-- Partner Up), both flat in the k9unit submenu.
-- ----------------------------------------------------------------------

t.test('HandlerPartnership explicitly false: neither k9_break_partnership nor k9_partner_up appears', function()
    local f = newRadialFixture()
    t.isNil(f.findInMenu('k9unit', 'k9_break_partnership'))
    t.isNil(f.findInMenu('k9unit', 'k9_partner_up'))
end)

t.test('HandlerPartnership true: both k9_break_partnership and k9_partner_up appear', function()
    local f = newRadialFixture({ features = { HandlerPartnership = true } })
    t.isNotNil(f.findInMenu('k9unit', 'k9_break_partnership'))
    t.isNotNil(f.findInMenu('k9unit', 'k9_partner_up'))
end)

-- ----------------------------------------------------------------------
-- HandlerDownDefense -- gates a whole SEPARATE registerRadial('k9unit_defense')
-- submenu (two terminal actions) PLUS the k9_defense link item inside k9unit.
-- ----------------------------------------------------------------------

t.test('HandlerDownDefense explicitly false: neither the k9unit_defense submenu nor its k9unit link item exists', function()
    local f = newRadialFixture()
    t.isNil(f.findMenu('k9unit_defense'))
    t.isNil(f.findInMenu('k9unit', 'k9_defense'))
end)

t.test('HandlerDownDefense true: registers k9unit_defense with exactly k9_defense_bite and k9_defense_takedown, linked from k9unit', function()
    local f = newRadialFixture({ features = { HandlerDownDefense = true } })
    local link = f.findInMenu('k9unit', 'k9_defense')
    t.isNotNil(link)
    t.equals(link.menu, 'k9unit_defense')
    t.isNil(link.onSelect, 'a pure navigation link must carry no onSelect')

    local items = f.findMenu('k9unit_defense')
    t.isNotNil(items)
    t.equals(#items, 2)
    t.isNotNil(f.findInMenu('k9unit_defense', 'k9_defense_bite'))
    t.isNotNil(f.findInMenu('k9unit_defense', 'k9_defense_takedown'))
end)

-- ----------------------------------------------------------------------
-- FetchMechanic -- same nested-submenu shape as HandlerDownDefense above.
-- ----------------------------------------------------------------------

t.test('FetchMechanic explicitly false: neither the k9unit_fetch submenu nor its k9unit link item exists', function()
    local f = newRadialFixture()
    t.isNil(f.findMenu('k9unit_fetch'))
    t.isNil(f.findInMenu('k9unit', 'k9_fetch'))
end)

t.test('FetchMechanic true: registers k9unit_fetch with exactly k9_fetch_throw and k9_fetch_recall, linked from k9unit', function()
    local f = newRadialFixture({ features = { FetchMechanic = true } })
    local link = f.findInMenu('k9unit', 'k9_fetch')
    t.isNotNil(link)
    t.equals(link.menu, 'k9unit_fetch')

    local items = f.findMenu('k9unit_fetch')
    t.isNotNil(items)
    t.equals(#items, 2)
    t.isNotNil(f.findInMenu('k9unit_fetch', 'k9_fetch_throw'))
    t.isNotNil(f.findInMenu('k9unit_fetch', 'k9_fetch_recall'))
end)

-- ----------------------------------------------------------------------
-- BasicBarkSounds / AdvancedBarkRadial -- the one item whose SHAPE (not
-- just presence) changes with a second, layered flag.
-- ----------------------------------------------------------------------

t.test('BasicBarkSounds false: k9_bark is entirely absent, even though AdvancedBarkRadial defaults to false too (nothing to layer onto)', function()
    local f = newRadialFixture({ features = { BasicBarkSounds = false } })
    t.isNil(f.findInMenu('k9unit', 'k9_bark'))
    t.isNil(f.findMenu('k9unit_bark'))
end)

t.test('BasicBarkSounds false: staying off even with AdvancedBarkRadial forced true still yields no k9_bark item at all (Bark requires BasicBarkSounds underneath it)', function()
    local f = newRadialFixture({ features = { BasicBarkSounds = false, AdvancedBarkRadial = true } })
    t.isNil(f.findInMenu('k9unit', 'k9_bark'))
    t.isNil(f.findMenu('k9unit_bark'), 'the nested variant submenu must not be built at all when the prerequisite flag is off')
end)

t.test('BasicBarkSounds true, AdvancedBarkRadial false: a single k9_bark item with its own onSelect, sending the literal barkType "bark"', function()
    local f = newRadialFixture()
    local item = f.findInMenu('k9unit', 'k9_bark')
    t.isNotNil(item)
    t.isNil(item.menu, 'without AdvancedBarkRadial this must be a terminal action, not a submenu link')
    t.isNotNil(item.onSelect)
    t.equals(item.label, locale('radial.bark_label'))

    item.onSelect()
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'qbx_k9unit:server:relayBark')
    t.equals(f.triggerServerEventCalls[1].args[1], 'bark')
end)

t.test('BasicBarkSounds true + AdvancedBarkRadial true: k9_bark becomes a pure navigation link into k9unit_bark, carrying no onSelect of its own', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })
    local item = f.findInMenu('k9unit', 'k9_bark')
    t.isNotNil(item)
    t.equals(item.menu, 'k9unit_bark')
    t.isNil(item.onSelect)
end)

t.test('AdvancedBarkRadial true: k9unit_bark contains exactly one item per REAL config.lua Config.AdvancedBarkRadial entry, with matching id/label/icon, each sending its own barkType', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })
    local variants = f.Config.AdvancedBarkRadial
    local items = f.findMenu('k9unit_bark')
    t.isNotNil(items)
    t.equals(#items, #variants, 'one submenu item per REAL config.lua variant -- not a hardcoded count')

    for _, variant in ipairs(variants) do
        local item = f.findInMenu('k9unit_bark', 'k9_bark_' .. variant.barkType)
        t.isNotNil(item, ('missing submenu item for real config.lua variant %s'):format(variant.barkType))
        t.equals(item.label, variant.label)
        t.equals(item.icon, variant.icon)
        t.isNil(item.menu, 'each variant is a terminal action, not a further navigation link')

        item.onSelect()
    end

    t.equals(#f.triggerServerEventCalls, #variants)
    for i, variant in ipairs(variants) do
        t.equals(f.triggerServerEventCalls[i].event, 'qbx_k9unit:server:relayBark')
        t.equals(f.triggerServerEventCalls[i].args[1], variant.barkType, 'each variant must send ITS OWN barkType, not a shared/last-iteration one (the exact Lua closure-capture bug this file\'s own header warns a naive loop could introduce)')
    end
end)

-- ----------------------------------------------------------------------
-- RadialMenu=false suppresses the entire feature, REGARDLESS of every
-- other flag -- the task's own explicitly-named priority case.
-- ----------------------------------------------------------------------

t.test('RadialMenu=false: the k9unit submenu and its root opener never get registered, even with every OTHER feature flag turned on', function()
    local f = newRadialFixture({ features = {
        RadialMenu = false,
        LeashMechanics = true, VehicleEntryExit = true, BasicBarkSounds = true,
        AdvancedBarkRadial = true, ScentTracking = true, BloodTracking = true,
        GunpowderSniffing = true, BiteAndHold = true, NonLethalTakedown = true,
        PropDragging = true, HandlerPartnership = true, Recall = true,
        HandlerDownDefense = true, FetchMechanic = true, PropAttachments = true,
        DeployableKennel = true, K9Inventory = true, K9Medkit = true,
        SARCalls = true, TrainingMode = true,
    } })

    t.isNil(f.findMenu('k9unit'), 'the k9unit submenu itself must never be registered when RadialMenu is false')
    t.isNil(f.findRootItem('k9unit_open'), 'no opener can reach a menu that was never registered')
    t.equals(#f.addRadialItemCalls, 0, 'lib.addRadialItem must never be called at all when RadialMenu is false')

    -- DISCLOSED NUANCE, not a bug this spec is asked to fix: the source's
    -- own `if Config.Features.RadialMenu then ... end` wrapper is the LAST
    -- block in the file and only guards the k9unit registerRadial + its
    -- root opener addRadialItem call. The k9unit_bark/k9unit_defense/
    -- k9unit_fetch nested submenus are each registered independently,
    -- earlier in the file, gated ONLY on their OWN sub-feature flag -- NOT
    -- on RadialMenu at all. With RadialMenu=false they still get
    -- registered in ox_lib's own menu registry, just as ORPHANS nothing
    -- links to (the only item that would link to them, k9_bark/k9_defense/
    -- k9_fetch, lives inside k9SubmenuItems, which is never itself
    -- registered as 'k9unit' in this scenario). Practically inert --
    -- nothing in the actual radial WHEEL is reachable -- but not literally
    -- "lib.registerRadial is never called again after RadialMenu is
    -- false," which is why this test asserts on 'k9unit' specifically and
    -- the opener, not on registerRadialCalls being empty outright.
    t.isNotNil(f.findMenu('k9unit_bark'), 'orphaned, but genuinely still registered -- see comment above')
end)

-- ----------------------------------------------------------------------
-- No two items share an id, across a fixture with EVERY flag enabled.
-- ----------------------------------------------------------------------

t.test('no two registered items (across every submenu and the root wheel) share the same id, with every feature flag turned on', function()
    local f = newRadialFixture({ features = {
        RadialMenu = true, LeashMechanics = true, VehicleEntryExit = true,
        BasicBarkSounds = true, AdvancedBarkRadial = true, ScentTracking = true,
        BloodTracking = true, GunpowderSniffing = true, BiteAndHold = true,
        NonLethalTakedown = true, PropDragging = true, HandlerPartnership = true,
        Recall = true, HandlerDownDefense = true, FetchMechanic = true,
        PropAttachments = true, DeployableKennel = true, K9Inventory = true,
        K9Medkit = true, SARCalls = true, TrainingMode = true,
    } })

    local ids = f.allIds()
    t.isTrue(#ids > 20, 'sanity: this fixture should have produced a large number of items, or this test is not exercising what it claims to')

    local seen = {}
    for _, id in ipairs(ids) do
        t.isNil(seen[id], ('duplicate radial item id found: %s'):format(tostring(id)))
        seen[id] = true
    end
end)

-- ----------------------------------------------------------------------
-- onSelect targets: the `type(fn) == 'function'` guard -- present for
-- every item wired to client/partnership.lua, client/recall.lua,
-- client/defense.lua, client/fetch.lua, client/propattachment.lua,
-- client/kennel.lua, client/inventory.lua, client/medkit.lua (per this
-- file's own header: "Every cross-file global added after this file's own
-- initial Phase 1 pass is called behind a type(fn) == 'function' runtime
-- existence guard"). Each case below proves the guard actually holds --
-- onSelect must not throw even when the target global is entirely absent
-- from the sandbox -- and that a PRESENT target really does get called
-- with the right arguments once access is granted.
-- ----------------------------------------------------------------------

t.test('k9_break_partnership: guarded -- absent BreakPartnership does not throw; present BreakPartnership is called, UNGATED (no CanShowK9UI check at all)', function()
    local fAbsent = newRadialFixture({ features = { HandlerPartnership = true }, omit = { 'BreakPartnership' }, canShowK9UI = false })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_break_partnership'))
    t.equals(fAbsent.denyCallCount(), 0, 'Break Partnership is a TERMINATION action and must never be gated on CanShowK9UI at all, per this file\'s own "no unbounded trap" comment')

    local fPresent = newRadialFixture({ features = { HandlerPartnership = true }, canShowK9UI = false })
    fPresent.findInMenu('k9unit', 'k9_break_partnership').onSelect()
    t.equals(#fPresent.calls.BreakPartnership, 1)
    t.equals(fPresent.canShowK9UICallCount(), 0, 'must never even ask CanShowK9UI -- termination action')
end)

t.test('k9_recall: guarded -- absent RequestRecall does not throw; present RequestRecall is called, UNGATED', function()
    local fAbsent = newRadialFixture({ features = { Recall = true }, omit = { 'RequestRecall' }, canShowK9UI = false })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_recall'))

    local fPresent = newRadialFixture({ features = { Recall = true }, canShowK9UI = false })
    fPresent.findInMenu('k9unit', 'k9_recall').onSelect()
    t.equals(#fPresent.calls.RequestRecall, 1)
    t.equals(fPresent.canShowK9UICallCount(), 0, 'Recall is a TERMINATION action -- must never be gated, per client/recall.lua\'s own header quoted in this file')
end)

t.test('k9_partner_up: guarded -- absent RequestPartnerUp does not throw when a candidate is found; present RequestPartnerUp is called with the found candidate serverId, GATED on CanShowK9UI', function()
    local function withOneCandidateInRange(f)
        f.setActivePlayers({ 7 })
        f.setPlayerPed(7, 500)
        f.setPedCoords(500, vec3(1, 0, 0))
        f.setPlayerServerId(7, 999)
    end

    local fAbsent = newRadialFixture({ features = { HandlerPartnership = true }, omit = { 'RequestPartnerUp' } })
    withOneCandidateInRange(fAbsent)
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_partner_up'))

    local fDenied = newRadialFixture({ features = { HandlerPartnership = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit', 'k9_partner_up').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.RequestPartnerUp, 'must never even search for a candidate once access is denied')

    local fGranted = newRadialFixture({ features = { HandlerPartnership = true } })
    withOneCandidateInRange(fGranted)
    fGranted.findInMenu('k9unit', 'k9_partner_up').onSelect()
    t.equals(#fGranted.calls.RequestPartnerUp, 1)
    t.equals(fGranted.calls.RequestPartnerUp[1][1], 999)
end)

t.test('k9_partner_up: no candidate in range notifies radial.no_partner_candidate and never calls RequestPartnerUp', function()
    local f = newRadialFixture({ features = { HandlerPartnership = true } })
    f.setActivePlayers({}) -- nobody nearby
    f.findInMenu('k9unit', 'k9_partner_up').onSelect()
    t.isNil(f.calls.RequestPartnerUp)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('radial.no_partner_candidate'))
end)

t.test('k9_defense_bite / k9_defense_takedown: guarded -- absent ConfirmHandlerDownDefense does not throw; present, each sends its OWN actionType, GATED on CanShowK9UI', function()
    local fAbsent = newRadialFixture({ features = { HandlerDownDefense = true }, omit = { 'ConfirmHandlerDownDefense' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_defense', 'k9_defense_bite'))
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_defense', 'k9_defense_takedown'))

    local fDenied = newRadialFixture({ features = { HandlerDownDefense = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit_defense', 'k9_defense_bite').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.ConfirmHandlerDownDefense)

    local fGranted = newRadialFixture({ features = { HandlerDownDefense = true } })
    fGranted.findInMenu('k9unit_defense', 'k9_defense_bite').onSelect()
    fGranted.findInMenu('k9unit_defense', 'k9_defense_takedown').onSelect()
    t.equals(#fGranted.calls.ConfirmHandlerDownDefense, 2)
    t.equals(fGranted.calls.ConfirmHandlerDownDefense[1][1], 'bite')
    t.equals(fGranted.calls.ConfirmHandlerDownDefense[2][1], 'takedown')
end)

t.test('k9_prop_attachment / k9_deploy_kennel: guarded -- absent target does not throw; present target called only once access is granted', function()
    local fAbsent = newRadialFixture({ features = { PropAttachments = true, DeployableKennel = true }, omit = { 'RequestToggleK9PropAttachment', 'RequestDeployKennel' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_prop_attachment'))
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_deploy_kennel'))

    local fDenied = newRadialFixture({ features = { PropAttachments = true, DeployableKennel = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit', 'k9_prop_attachment').onSelect()
    fDenied.findInMenu('k9unit', 'k9_deploy_kennel').onSelect()
    t.equals(fDenied.denyCallCount(), 2)
    t.isNil(fDenied.calls.RequestToggleK9PropAttachment)
    t.isNil(fDenied.calls.RequestDeployKennel)

    local fGranted = newRadialFixture({ features = { PropAttachments = true, DeployableKennel = true } })
    fGranted.findInMenu('k9unit', 'k9_prop_attachment').onSelect()
    fGranted.findInMenu('k9unit', 'k9_deploy_kennel').onSelect()
    t.equals(#fGranted.calls.RequestToggleK9PropAttachment, 1)
    t.equals(#fGranted.calls.RequestDeployKennel, 1)
end)

-- THE TWO ITEMS THIS TASK EXPLICITLY PRIORITISED: "Open My Gear" and
-- "Treat K9" -- both recently wired, both behind flags that ship false.
-- Full treatment (presence already proven above): guard + access gate +
-- happy-path call.
t.test('k9_open_inventory ("Open My Gear"): guarded -- absent RequestOpenOwnK9Inventory does not throw; denied access never calls it; granted access calls it', function()
    local fAbsent = newRadialFixture({ features = { K9Inventory = true }, omit = { 'RequestOpenOwnK9Inventory' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_open_inventory'))

    local fDenied = newRadialFixture({ features = { K9Inventory = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit', 'k9_open_inventory').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.RequestOpenOwnK9Inventory)

    local fGranted = newRadialFixture({ features = { K9Inventory = true } })
    fGranted.findInMenu('k9unit', 'k9_open_inventory').onSelect()
    t.equals(#fGranted.calls.RequestOpenOwnK9Inventory, 1)
    t.equals(fGranted.findInMenu('k9unit', 'k9_open_inventory').label, locale('radial.open_inventory_label'))
end)

t.test('k9_treat_nearest ("Treat K9"): guarded -- absent RequestTreatNearestK9 does not throw; denied access never calls it; granted access calls it', function()
    local fAbsent = newRadialFixture({ features = { K9Medkit = true }, omit = { 'RequestTreatNearestK9' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_treat_nearest'))

    local fDenied = newRadialFixture({ features = { K9Medkit = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit', 'k9_treat_nearest').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.RequestTreatNearestK9)

    local fGranted = newRadialFixture({ features = { K9Medkit = true } })
    fGranted.findInMenu('k9unit', 'k9_treat_nearest').onSelect()
    t.equals(#fGranted.calls.RequestTreatNearestK9, 1)
    -- Reuses medkit.treat_target_label rather than minting a duplicate key,
    -- per this item's own comment -- confirmed against the real label.
    t.equals(fGranted.findInMenu('k9unit', 'k9_treat_nearest').label, locale('medkit.treat_target_label'))
end)

t.test('k9_fetch_recall: guarded -- absent RequestRecallFetchBall does not throw; present, UNGATED (a termination action)', function()
    local fAbsent = newRadialFixture({ features = { FetchMechanic = true }, omit = { 'RequestRecallFetchBall' }, canShowK9UI = false })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_fetch', 'k9_fetch_recall'))

    local fPresent = newRadialFixture({ features = { FetchMechanic = true }, canShowK9UI = false })
    fPresent.findInMenu('k9unit_fetch', 'k9_fetch_recall').onSelect()
    t.equals(#fPresent.calls.RequestRecallFetchBall, 1)
    t.equals(fPresent.canShowK9UICallCount(), 0)
end)

t.test('k9_fetch_throw: guarded triple (IsFetchCarryEngaged/ReleaseFetchBall/RequestThrowFetchBall) -- all three absent does not throw either branch', function()
    local fAbsent = newRadialFixture({ features = { FetchMechanic = true }, omit = { 'IsFetchCarryEngaged', 'ReleaseFetchBall', 'RequestThrowFetchBall' } })
    -- IsFetchCarryEngaged absent -> `type(...) == 'function' and ...()` short-circuits to false without calling it -- falls through to the HasK9Access branch.
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_fetch', 'k9_fetch_throw'))
end)

t.test('k9_fetch_throw: gated on HasK9Access() DIRECTLY, NOT CanShowK9UI() -- the one item this file\'s own header documents as deliberately different', function()
    local fDenied = newRadialFixture({ features = { FetchMechanic = true }, hasK9Access = false, canShowK9UI = true })
    fDenied.findInMenu('k9unit_fetch', 'k9_fetch_throw').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.RequestThrowFetchBall)

    local fGranted = newRadialFixture({ features = { FetchMechanic = true }, hasK9Access = true, canShowK9UI = false })
    fGranted.findInMenu('k9unit_fetch', 'k9_fetch_throw').onSelect()
    t.equals(#fGranted.calls.RequestThrowFetchBall, 1, 'HasK9Access() alone must be enough to proceed, even with CanShowK9UI() forced false')
    t.equals(fGranted.canShowK9UICallCount(), 0, 'this item must never even ask CanShowK9UI -- see this file\'s own "Fetch\'s Throw branch" carve-out comment')
end)

t.test('k9_fetch_throw: while already carrying, selecting it releases instead of throwing again -- UNGATED, and RequestThrowFetchBall is never even attempted', function()
    local f = newRadialFixture({ features = { FetchMechanic = true }, hasK9Access = false })
    f.setState('isFetchCarryEngaged', true)
    f.findInMenu('k9unit_fetch', 'k9_fetch_throw').onSelect()
    t.equals(#f.calls.ReleaseFetchBall, 1)
    t.isNil(f.calls.RequestThrowFetchBall)
    t.equals(f.hasK9AccessCallCount(), 0, 'the release branch must return before ever consulting HasK9Access')
end)

-- ----------------------------------------------------------------------
-- RESOLVED this pass: Search & Rescue Call -- closes the exact disclosed
-- gap client/sarcalls.lua's own header used to name. Same context-sensitive
-- toggle shape as Leash/Bite & Hold/Drag -- full treatment mirrors those.
-- ----------------------------------------------------------------------

t.test('k9_sar_call: guarded triple (IsSarCallActive/RequestAbandonSarCall/RequestStartSarCall) -- all three absent does not throw either branch', function()
    local fAbsent = newRadialFixture({ features = { SARCalls = true }, omit = { 'IsSarCallActive', 'RequestAbandonSarCall', 'RequestStartSarCall' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit', 'k9_sar_call'))
end)

t.test('k9_sar_call: while a call is active, selecting it abandons -- UNGATED, never consults CanShowK9UI', function()
    local f = newRadialFixture({ features = { SARCalls = true }, canShowK9UI = false })
    f.setState('isSarCallActive', true)
    f.findInMenu('k9unit', 'k9_sar_call').onSelect()
    t.equals(#f.calls.RequestAbandonSarCall, 1)
    t.isNil(f.calls.RequestStartSarCall)
    t.equals(f.canShowK9UICallCount(), 0, 'abandoning a call must never even ask CanShowK9UI -- see client/sarcalls.lua\'s own "UNCONDITIONAL, never gated" doc comment')
end)

t.test('k9_sar_call: while no call is active, denied access never calls RequestStartSarCall; granted access does', function()
    local fDenied = newRadialFixture({ features = { SARCalls = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit', 'k9_sar_call').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.RequestStartSarCall)

    local fGranted = newRadialFixture({ features = { SARCalls = true } })
    fGranted.findInMenu('k9unit', 'k9_sar_call').onSelect()
    t.equals(#fGranted.calls.RequestStartSarCall, 1)
    t.equals(fGranted.findInMenu('k9unit', 'k9_sar_call').label, pendingLocale('radial.sar_call_toggle_label'))
end)

-- ----------------------------------------------------------------------
-- RESOLVED this pass: Training -- closes the exact disclosed gap that used
-- to leave Training Mode and its two drills reachable only via
-- '/k9training <on|off>'/'/k9trainsearch'/'/k9trainbite'. Nested submenu,
-- same treatment shape as FetchMechanic above (presence/absence of the
-- whole submenu, then guard + gating + happy-path per item).
-- ----------------------------------------------------------------------

t.test('TrainingMode explicitly false: neither the k9unit_training submenu nor its k9unit link item exists', function()
    local f = newRadialFixture()
    t.isNil(f.findMenu('k9unit_training'))
    t.isNil(f.findInMenu('k9unit', 'k9_training'))
end)

t.test('TrainingMode true: registers k9unit_training with exactly the toggle + both drills, linked from k9unit', function()
    local f = newRadialFixture({ features = { TrainingMode = true } })
    local link = f.findInMenu('k9unit', 'k9_training')
    t.isNotNil(link)
    t.equals(link.menu, 'k9unit_training')
    t.equals(link.label, pendingLocale('radial.training_menu_label'))

    local items = f.findMenu('k9unit_training')
    t.equals(#items, 3)
    t.isNotNil(f.findInMenu('k9unit_training', 'k9_training_toggle'))
    t.isNotNil(f.findInMenu('k9unit_training', 'k9_training_search'))
    t.isNotNil(f.findInMenu('k9unit_training', 'k9_training_bite'))
end)

t.test('k9_training_toggle: guarded triple (IsTrainingModeActive/RequestSetTrainingMode) -- both absent does not throw either branch', function()
    local fAbsent = newRadialFixture({ features = { TrainingMode = true }, omit = { 'IsTrainingModeActive', 'RequestSetTrainingMode' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_training', 'k9_training_toggle'))
end)

t.test('k9_training_toggle: while training, selecting it requests OFF -- UNGATED, never consults HasK9Access', function()
    local f = newRadialFixture({ features = { TrainingMode = true }, hasK9Access = false })
    f.setState('isTrainingModeActive', true)
    f.findInMenu('k9unit_training', 'k9_training_toggle').onSelect()
    t.equals(#f.calls.RequestSetTrainingMode, 1)
    t.equals(f.calls.RequestSetTrainingMode[1][1], false)
    t.equals(f.hasK9AccessCallCount(), 0, 'stopping training must never even ask HasK9Access -- "no unbounded trap"')
    t.equals(f.denyCallCount(), 0)
end)

t.test('k9_training_toggle: while NOT training, gated on HasK9Access() DIRECTLY, NOT CanShowK9UI() -- mirrors the Fetch Throw branch\'s own carve-out', function()
    local fDenied = newRadialFixture({ features = { TrainingMode = true }, hasK9Access = false, canShowK9UI = true })
    fDenied.findInMenu('k9unit_training', 'k9_training_toggle').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.RequestSetTrainingMode)

    local fGranted = newRadialFixture({ features = { TrainingMode = true }, hasK9Access = true, canShowK9UI = false })
    fGranted.findInMenu('k9unit_training', 'k9_training_toggle').onSelect()
    t.equals(#fGranted.calls.RequestSetTrainingMode, 1)
    t.equals(fGranted.calls.RequestSetTrainingMode[1][1], true)
    t.equals(fGranted.canShowK9UICallCount(), 0, 'this item must never even ask CanShowK9UI')
end)

t.test('k9_training_search / k9_training_bite: guarded -- absent RequestTrainingSearchDrill/RequestTrainingBiteDrill does not throw', function()
    local fAbsent = newRadialFixture({ features = { TrainingMode = true }, omit = { 'RequestTrainingSearchDrill', 'RequestTrainingBiteDrill' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_training', 'k9_training_search'))
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_training', 'k9_training_bite'))
end)

t.test('k9_training_search / k9_training_bite: carry NO access gate of their own -- call straight through even with CanShowK9UI/HasK9Access both forced false, matching the command path', function()
    local f = newRadialFixture({ features = { TrainingMode = true }, canShowK9UI = false, hasK9Access = false })
    f.findInMenu('k9unit_training', 'k9_training_search').onSelect()
    f.findInMenu('k9unit_training', 'k9_training_bite').onSelect()
    t.equals(#f.calls.RequestTrainingSearchDrill, 1)
    t.equals(#f.calls.RequestTrainingBiteDrill, 1)
    t.equals(f.canShowK9UICallCount(), 0)
    t.equals(f.hasK9AccessCallCount(), 0)
    t.equals(f.denyCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- HEADER/CODE DRIFT FIX (dependency-verification pass): Sit, Leash,
-- Vehicle, the three Track items, and Bite&Hold/Takedown/Drag used to call
-- their cross-file target DIRECTLY, with no type()=='function' guard --
-- contradicting this file's own header, which claims a BLANKET "every
-- cross-file global added after this file's own initial Phase 1 pass is
-- called behind a type(fn)=='function' guard" policy. That was never
-- reachable with a genuinely nil target in a real session
-- (fxmanifest.lua loads client/movement.lua/client/vehicle.lua/
-- client/tracking.lua/client/combat.lua as part of the SAME resource
-- start, always complete before any player action can fire an onSelect
-- closure), so this was a documentation/implementation drift, not a live
-- safety bug -- but per this pass's own instruction to make the header and
-- the code agree, client/radial.lua now wraps every one of these nine call
-- sites in the exact same guard every other post-Phase-1 item already
-- uses. The header's blanket claim is therefore no longer false for any
-- item in this file. Every case below now proves the FIXED (guarded,
-- non-throwing) behavior, same `assertGuardDoesNotThrow` shape already
-- used for every other guarded item above -- not that a throw was merely
-- possible in theory.
--
-- CROSS-FLAG GAP CHECK (the substantive question a guard-vs-header choice
-- actually turns on, not just "does the header technically say guard
-- everything"): every item this fix touches calls a global from the SAME
-- feature area gated by the SAME Config.Features flag the item itself is
-- registered under (k9_leash + LeashMechanics both live in
-- client/movement.lua's own gate; k9_vehicle + VehicleEntryExit both in
-- client/vehicle.lua's; k9_track_* + its own Scent/Blood/GunpowderSniffing
-- flag in client/tracking.lua's; k9_bite_hold/k9_takedown/k9_drag each
-- paired with client/combat.lua's matching BiteAndHold/NonLethalTakedown/
-- PropDragging flag) -- so there is no real combination of flags where one
-- of these items is registered but its OWN target file never defines the
-- matching global at all; k9_sit is the sole exception (no dedicated flag
-- of its own), but K9Sit() is defined unconditionally in
-- client/movement.lua regardless of any feature flag. This is a narrower,
-- same-flag correspondence than client/vehicle.lua's own newly-added
-- IsDragEngaged()/IsBiteHoldEngaged() guard (a genuine CROSS-flag case:
-- VehicleEntryExit can be enabled on a server running NONE of
-- BiteAndHold/NonLethalTakedown/PropDragging, in which case
-- client/combat.lua's globals are never declared at all) -- so unlike that
-- one, every guard added here is defensive/redundant given the real
-- feature-flag graph, not load-bearing against an actual reachable gap.
-- Added anyway, for the same reason this file already gives for every
-- other redundant guard it carries (BreakPartnership's own comment: "kept
-- anyway... it costs nothing to honor that against, say, a future
-- load-order change") -- and because it is what makes the header's own
-- blanket claim true rather than false.
-- ----------------------------------------------------------------------

t.test('FIXED: k9_sit is now guarded -- absent K9Sit does not throw', function()
    local f = newRadialFixture({ omit = { 'K9Sit' } })
    assertGuardDoesNotThrow(f.findInMenu('k9unit', 'k9_sit'))
end)

t.test('FIXED: k9_vehicle is now guarded -- absent IsInK9Vehicle/EnterNearestK9Vehicle/ExitK9Vehicle does not throw in either direction', function()
    local fEnter = newRadialFixture({ features = { VehicleEntryExit = true }, omit = { 'IsInK9Vehicle', 'EnterNearestK9Vehicle' } })
    assertGuardDoesNotThrow(fEnter.findInMenu('k9unit', 'k9_vehicle'))

    local fExit = newRadialFixture({ features = { VehicleEntryExit = true }, omit = { 'IsInK9Vehicle', 'ExitK9Vehicle' } })
    fExit.setState('isInK9Vehicle', true)
    assertGuardDoesNotThrow(fExit.findInMenu('k9unit', 'k9_vehicle'))
end)

t.test('FIXED: k9_track_scent/blood/gunpowder are now guarded -- absent GetActiveTrackType/StopTracking/Start*Track does not throw in either branch', function()
    local fStart = newRadialFixture({ features = { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true }, omit = { 'GetActiveTrackType', 'StartScentTrack', 'StartBloodTrack', 'StartGunpowderTrack' } })
    assertGuardDoesNotThrow(fStart.findInMenu('k9unit', 'k9_track_scent'))
    assertGuardDoesNotThrow(fStart.findInMenu('k9unit', 'k9_track_blood'))
    assertGuardDoesNotThrow(fStart.findInMenu('k9unit', 'k9_track_gunpowder'))

    local fStop = newRadialFixture({ features = { ScentTracking = true }, omit = { 'StopTracking' } })
    fStop.setState('activeTrackType', 'scent')
    assertGuardDoesNotThrow(fStop.findInMenu('k9unit', 'k9_track_scent'))
end)

t.test('FIXED: k9_bite_hold/k9_takedown/k9_drag are now guarded -- absent targets do not throw in either branch', function()
    local fStart = newRadialFixture({ features = { BiteAndHold = true, NonLethalTakedown = true, PropDragging = true }, omit = { 'IsBiteHoldEngaged', 'RequestBiteHold', 'RequestTakedown', 'IsDragEngaged', 'RequestDrag' } })
    assertGuardDoesNotThrow(fStart.findInMenu('k9unit', 'k9_bite_hold'))
    assertGuardDoesNotThrow(fStart.findInMenu('k9unit', 'k9_takedown'))
    assertGuardDoesNotThrow(fStart.findInMenu('k9unit', 'k9_drag'))

    local fRelease = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, omit = { 'ReleaseBiteHold', 'ReleaseDrag' } })
    fRelease.setState('isBiteHoldEngaged', true)
    fRelease.setState('isDragEngaged', true)
    assertGuardDoesNotThrow(fRelease.findInMenu('k9unit', 'k9_bite_hold'))
    assertGuardDoesNotThrow(fRelease.findInMenu('k9unit', 'k9_drag'))
end)

t.test('k9_takedown: present RequestTakedown is called once access is granted (the one call-through this file had not yet pinned)', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true } })
    f.findInMenu('k9unit', 'k9_takedown').onSelect()
    t.equals(#f.calls.RequestTakedown, 1)
end)

-- ----------------------------------------------------------------------
-- Access gating correctness for the UNGUARDED items above -- this matters
-- MORE than the guard nuance: proving the right branch is chosen and
-- CanShowK9UI/DenyK9UIAccess fire (or deliberately don't) exactly where
-- this file's own comments say they should.
-- ----------------------------------------------------------------------

t.test('k9_sit: denied access never calls K9Sit; granted access calls it', function()
    local fDenied = newRadialFixture({ canShowK9UI = false })
    fDenied.findInMenu('k9unit', 'k9_sit').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.K9Sit)

    local fGranted = newRadialFixture({ canShowK9UI = true })
    fGranted.findInMenu('k9unit', 'k9_sit').onSelect()
    t.equals(#fGranted.calls.K9Sit, 1)
end)

t.test('k9_leash: while leashed, Detach fires UNGATED (CanShowK9UI never even asked); while not leashed, Attach is GATED', function()
    local fDetach = newRadialFixture({ features = { LeashMechanics = true }, canShowK9UI = false })
    fDetach.setState('isLeashed', true)
    fDetach.findInMenu('k9unit', 'k9_leash').onSelect()
    t.equals(#fDetach.calls.DetachLeash, 1)
    t.equals(fDetach.canShowK9UICallCount(), 0, 'Detach must never consult CanShowK9UI at all, per the "no unbounded trap" comment')
    t.equals(fDetach.denyCallCount(), 0)

    local fAttachDenied = newRadialFixture({ features = { LeashMechanics = true }, canShowK9UI = false })
    fAttachDenied.setState('isLeashed', false)
    fAttachDenied.findInMenu('k9unit', 'k9_leash').onSelect()
    t.equals(fAttachDenied.denyCallCount(), 1)
    t.isNil(fAttachDenied.calls.RequestLeashAttach)
end)

t.test('k9_leash: Attach finds the nearest in-range candidate and calls RequestLeashAttach with their server id; out of Config.LeashMaxDistance range is treated as no candidate', function()
    local f = newRadialFixture({ features = { LeashMechanics = true } })
    f.setState('isLeashed', false)
    f.setActivePlayers({ 4, 5 })
    f.setPlayerPed(4, 100)
    f.setPedCoords(100, vec3(f.Config.LeashMaxDistance + 1, 0, 0)) -- just OUT of range
    f.setPlayerServerId(4, 111)
    f.setPlayerPed(5, 101)
    f.setPedCoords(101, vec3(2, 0, 0)) -- in range
    f.setPlayerServerId(5, 222)

    f.findInMenu('k9unit', 'k9_leash').onSelect()
    t.equals(#f.calls.RequestLeashAttach, 1)
    t.equals(f.calls.RequestLeashAttach[1][1], 222, 'must pick the in-range candidate, never the out-of-range one, and pass their real server id')
end)

t.test('k9_leash: Attach with nobody in range notifies radial.no_leash_candidate and never calls RequestLeashAttach', function()
    local f = newRadialFixture({ features = { LeashMechanics = true } })
    f.setState('isLeashed', false)
    f.setActivePlayers({})
    f.findInMenu('k9unit', 'k9_leash').onSelect()
    t.isNil(f.calls.RequestLeashAttach)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('radial.no_leash_candidate'))
end)

t.test('k9_exit_kennel: UNCONDITIONAL REGISTRATION (trap-hunt fix) -- present with EVERY Config.Features flag off, including DeployableKennel, unlike Deploy Kennel immediately above it. See this item\'s own source comment for why a widened-but-not-actually-live gate (the shape k9_leash uses) was deliberately rejected here', function()
    local f = newRadialFixture({ features = {
        DeployableKennel = false, LeashMechanics = false, VehicleEntryExit = false, BasicBarkSounds = false,
    } })
    t.isNotNil(f.findInMenu('k9unit', 'k9_exit_kennel'), 'must be present regardless of every feature flag -- a confining-mechanic escape hatch must never be hideable')
end)

t.test('k9_exit_kennel: onSelect fires UNGATED -- CanShowK9UI/DenyK9UIAccess are never even consulted, unlike Deploy Kennel immediately above it', function()
    local f = newRadialFixture({ features = { DeployableKennel = false }, canShowK9UI = false })
    f.findInMenu('k9unit', 'k9_exit_kennel').onSelect()
    t.equals(#f.calls.ExitKennelRest, 1, 'must call ExitKennelRest() regardless of CanShowK9UI()')
    t.equals(f.canShowK9UICallCount(), 0, 'an exit path must never even ask CanShowK9UI() -- gate the START of a thing, never the STOP')
    t.equals(f.denyCallCount(), 0)
end)

t.test('k9_exit_kennel: onSelect tolerates ExitKennelRest being entirely absent (soft dependency) -- must not throw', function()
    local f = newRadialFixture({ omit = { 'ExitKennelRest' } })
    assertGuardDoesNotThrow(f.findInMenu('k9unit', 'k9_exit_kennel'))
end)

-- INVERTED, THIS PASS (coordinator review) -- an earlier version of THIS
-- test asserted the OPPOSITE: that k9_exit_kennel is ABSENT when
-- DeployableKennel=false and this client is not currently resting. That
-- assertion was wrong, not the production code: a gate evaluated at
-- RegisterK9RadialMenu() time is a one-shot, boot-time snapshot (see the
-- item's own client/radial.lua comment) -- if DeployableKennel happened to
-- be false the LAST time that function ran, a widened, "present only while
-- resting" gate would leave the item permanently absent for the rest of
-- this resource's uptime regardless of what IsRestingInKennel() answers
-- LATER, which is the exact "hidden right when someone actually needs it"
-- failure this whole pass exists to close -- worse here than for the leash
-- item this pattern was copied from, since this occupant is physically
-- attached to a prop, not merely leashed. UNCONDITIONAL registration (this
-- test) is therefore the correct fix, matching Sit/Detach Leash's own
-- established "an exit-adjacent action must not be gated" precedent.
--
-- THE REAL QUESTION THIS RAISES, ANSWERED DIRECTLY BELOW: does registering
-- the item unconditionally grant ANY kennel capability on a server with
-- DeployableKennel off? NO. ExitKennelRest() is a thin wrapper over
-- ReleaseKennelRest(), which can only ever RELEASE an EXISTING restState --
-- it never deploys, never creates a kennel object, never attaches anyone TO
-- one, and (see server/kennel.lua's own requestExitKennel handler) the one
-- server event it fires only ever CLEARS a KennelOccupants entry that
-- already names this exact src, never grants one. A player on a
-- DeployableKennel=false server who was never resting gets nothing from
-- this item but a harmless no-op (proven below) -- there is no capability
-- to gate here, only a release path, so "gate the START of a thing, never
-- the STOP" applies cleanly. Before reverting this test back to asserting
-- absence, first prove ExitKennelRest() (or something it calls) has grown
-- a code path that creates/authorizes state rather than only clearing it --
-- if that ever becomes true, the gate question is real again and this test
-- (and client/radial.lua's own comment above the item) both need another
-- look.
t.test('k9_exit_kennel: UNCONDITIONAL REGISTRATION GRANTS NOTHING OF ITS OWN -- this ITEM adds no notify/server-event/native call beyond the single ExitKennelRest() call itself; the real "no-op while not resting" guarantee lives in, and is proven against the REAL implementation by, tests/clientkennel_spec.lua\'s own "ExitKennelRest(): calling it while not resting is a genuine, harmless no-op" test (this file stubs ExitKennelRest as a bare recorder, so it cannot re-prove that guarantee itself -- it only proves THIS file does not add a second, independent side effect on top)', function()
    local f = newRadialFixture({ features = { DeployableKennel = false } })
    f.findInMenu('k9unit', 'k9_exit_kennel').onSelect()

    t.equals(#f.calls.ExitKennelRest, 1, 'exactly one call, straight through -- no branching/gating logic of this item\'s own')
    t.equals(#f.notifyCalls, 0, 'this ITEM never notifies directly -- any notification is ExitKennelRest\'s own responsibility, proven elsewhere')
    t.equals(#f.triggerServerEventCalls, 0, 'this ITEM never talks to the network directly -- any server event is ExitKennelRest\'s own responsibility, proven elsewhere')
end)

t.test('k9_vehicle: BOTH directions (enter and exit) are gated on CanShowK9UI -- unlike Leash/Bite/Drag, there is no ungated "release" branch here', function()
    local fEnterDenied = newRadialFixture({ features = { VehicleEntryExit = true }, canShowK9UI = false })
    fEnterDenied.setState('isInK9Vehicle', false)
    fEnterDenied.findInMenu('k9unit', 'k9_vehicle').onSelect()
    t.equals(fEnterDenied.denyCallCount(), 1)
    t.isNil(fEnterDenied.calls.EnterNearestK9Vehicle)

    local fExitDenied = newRadialFixture({ features = { VehicleEntryExit = true }, canShowK9UI = false })
    fExitDenied.setState('isInK9Vehicle', true)
    fExitDenied.findInMenu('k9unit', 'k9_vehicle').onSelect()
    t.equals(fExitDenied.denyCallCount(), 1)
    t.isNil(fExitDenied.calls.ExitK9Vehicle, 'unlike Detach Leash, exiting a vehicle is STILL gated -- must be denied too')
end)

t.test('k9_vehicle: granted access chooses Enter or Exit based on IsInK9Vehicle()', function()
    local fEnter = newRadialFixture({ features = { VehicleEntryExit = true } })
    fEnter.setState('isInK9Vehicle', false)
    fEnter.findInMenu('k9unit', 'k9_vehicle').onSelect()
    t.equals(#fEnter.calls.EnterNearestK9Vehicle, 1)
    t.isNil(fEnter.calls.ExitK9Vehicle)

    local fExit = newRadialFixture({ features = { VehicleEntryExit = true } })
    fExit.setState('isInK9Vehicle', true)
    fExit.findInMenu('k9unit', 'k9_vehicle').onSelect()
    t.equals(#fExit.calls.ExitK9Vehicle, 1)
    t.isNil(fExit.calls.EnterNearestK9Vehicle)
end)

t.test('k9_bite_hold / k9_drag: the Release branch is UNGATED; the Start branch is GATED', function()
    local fRelease = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, canShowK9UI = false })
    fRelease.setState('isBiteHoldEngaged', true)
    fRelease.setState('isDragEngaged', true)
    fRelease.findInMenu('k9unit', 'k9_bite_hold').onSelect()
    fRelease.findInMenu('k9unit', 'k9_drag').onSelect()
    t.equals(#fRelease.calls.ReleaseBiteHold, 1)
    t.equals(#fRelease.calls.ReleaseDrag, 1)
    t.equals(fRelease.denyCallCount(), 0, 'neither release branch may ever call DenyK9UIAccess')

    local fStartDenied = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, canShowK9UI = false })
    fStartDenied.setState('isBiteHoldEngaged', false)
    fStartDenied.setState('isDragEngaged', false)
    fStartDenied.findInMenu('k9unit', 'k9_bite_hold').onSelect()
    fStartDenied.findInMenu('k9unit', 'k9_drag').onSelect()
    t.equals(fStartDenied.denyCallCount(), 2)
    t.isNil(fStartDenied.calls.RequestBiteHold)
    t.isNil(fStartDenied.calls.RequestDrag)
end)

-- ----------------------------------------------------------------------
-- Track Scent/Blood/Gunpowder -- the regression this file's own comment
-- names by name: clicking a DIFFERENT track type while one is already
-- active must NOT silently cancel the active trail; it must fall through
-- to that OTHER type's own Start*Track()/access-gate path instead.
-- ----------------------------------------------------------------------

t.test('REGRESSION LOCK-IN: clicking Track Gunpowder while Blood is the active type does NOT call StopTracking -- starts Gunpowder instead (each item only self-toggles its OWN type)', function()
    local f = newRadialFixture({ features = { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true } })
    f.setState('activeTrackType', 'blood')
    f.findInMenu('k9unit', 'k9_track_gunpowder').onSelect()
    t.isNil(f.calls.StopTracking, 'must never stop the OTHER active type')
    t.equals(#f.calls.StartGunpowderTrack, 1)
end)

t.test('Track Scent/Blood/Gunpowder: clicking the CURRENTLY active type\'s own item stops it, UNGATED', function()
    local f = newRadialFixture({ features = { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true }, canShowK9UI = false })
    f.setState('activeTrackType', 'scent')
    f.findInMenu('k9unit', 'k9_track_scent').onSelect()
    t.equals(#f.calls.StopTracking, 1)
    t.equals(f.denyCallCount(), 0, 'stopping your own active trail must never be gated')
end)

t.test('Track Scent/Blood/Gunpowder: starting a trail (nothing active) is GATED on CanShowK9UI', function()
    local f = newRadialFixture({ features = { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true }, canShowK9UI = false })
    f.setState('activeTrackType', nil)
    f.findInMenu('k9unit', 'k9_track_scent').onSelect()
    t.equals(f.denyCallCount(), 1)
    t.isNil(f.calls.StartScentTrack)
end)

-- ----------------------------------------------------------------------
-- OX_LIB RESTART LIFECYCLE -- dependency-verification finding: ox_lib
-- keeps `menus`/`menuItems` as plain file-local Lua tables in its own
-- client chunk (verified directly against overextended/ox_lib
-- resource/interface/client/radial.lua's own source this pass), so an
-- independent `restart ox_lib` reconstructs both empty with nothing
-- prompting a re-add -- silently wiping this resource's ENTIRE radial
-- menu with no error. client/radial.lua's RegisterK9RadialMenu() +
-- `AddEventHandler('onResourceStart', ...)` dispatcher (see that
-- function's own doc comment) fixes this; the cases below prove it,
-- mirroring tests/inventory_spec.lua's own `fireResourceStart`/
-- `wipeHookRegistrations` pair for the identical bug class against
-- ox_inventory instead. See this file's header ("OX_LIB RESTART
-- LIFECYCLE COVERAGE" / "LIVE-STATE MODELING") for the fixture mechanics
-- these tests rely on.
-- ----------------------------------------------------------------------

t.test('client/radial.lua registers exactly one onResourceStart handler', function()
    local f = newRadialFixture()
    t.equals(f.eventHandlerCount('onResourceStart'), 1)
end)

t.test('An unrelated resource starting neither registers nor re-registers anything', function()
    local f = newRadialFixture()
    t.isNotNil(f.findMenu('k9unit'))

    f.wipeOxLibRadialState()
    local ok = pcall(f.fireResourceStart, 'some_other_resource')
    t.isTrue(ok, "an unrelated resource's own start must never touch this file's registration at all")
    t.isNil(f.findMenu('k9unit'), 'confirms the wipe really took effect and the unrelated start did not silently re-populate it')
end)

t.test('ox_lib restarting (simulated: its own file-local menus/menuItems wiped, then its OWN onResourceStart fires) re-registers every menu this resource owns', function()
    local f = newRadialFixture({ features = {
        HandlerDownDefense = true, FetchMechanic = true, AdvancedBarkRadial = true, TrainingMode = true,
    } })

    -- Sanity: everything is present before the simulated restart.
    t.isNotNil(f.findMenu('k9unit'))
    t.isNotNil(f.findMenu('k9unit_bark'))
    t.isNotNil(f.findMenu('k9unit_defense'))
    t.isNotNil(f.findMenu('k9unit_fetch'))
    t.isNotNil(f.findMenu('k9unit_training'))
    t.isNotNil(f.findRootItem('k9unit_open'))

    -- Simulates ox_lib's OWN restart: its file-local `menus`/`menuItems`
    -- tables get reconstructed from scratch, empty -- nothing else in
    -- ox_lib re-populates them.
    f.wipeOxLibRadialState()
    t.isNil(f.findMenu('k9unit'), 'sanity: the wipe genuinely cleared the live model')
    t.isNil(f.findRootItem('k9unit_open'))

    -- ox_lib's OWN start firing is what client/radial.lua's dispatcher
    -- listens for (in addition to this resource's own start) -- this is
    -- the actual fix under test.
    f.fireResourceStart('ox_lib')

    t.isNotNil(f.findMenu('k9unit'), 'the top-level k9unit submenu must be re-registered')
    t.isNotNil(f.findMenu('k9unit_bark'), 'the nested bark variants submenu must be re-registered')
    t.isNotNil(f.findMenu('k9unit_defense'), 'the nested defense submenu must be re-registered')
    t.isNotNil(f.findMenu('k9unit_fetch'), 'the nested fetch submenu must be re-registered')
    t.isNotNil(f.findMenu('k9unit_training'), 'the nested training submenu must be re-registered')
    t.isNotNil(f.findRootItem('k9unit_open'), 'the single root opener must be re-registered')
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'the re-registered opener must still navigate into the re-registered k9unit submenu')
end)

t.test('ox_lib restart re-registration preserves ORDERING: every submenu is registered before the item that navigates into it via `menu`, even on the re-registration pass, not just the first', function()
    local f = newRadialFixture({ features = { HandlerDownDefense = true, FetchMechanic = true, TrainingMode = true } })

    f.wipeOxLibRadialState()
    f.fireResourceStart('ox_lib')

    local order = f.registerRadialOrder()
    local indexOf = {}
    for i, id in ipairs(order) do indexOf[id] = i end

    t.isNotNil(indexOf.k9unit_defense, 'k9unit_defense must have been (re-)registered')
    t.isNotNil(indexOf.k9unit_fetch, 'k9unit_fetch must have been (re-)registered')
    t.isNotNil(indexOf.k9unit_training, 'k9unit_training must have been (re-)registered')
    t.isNotNil(indexOf.k9unit, 'k9unit must have been (re-)registered')
    t.isTrue(indexOf.k9unit_defense < indexOf.k9unit, 'k9unit_defense (referenced via a `menu` field from inside k9unit) must be registered BEFORE k9unit itself, on the re-registration pass too -- violating this order is exactly what makes ox_lib\'s showRadial hard-error on an unregistered id')
    t.isTrue(indexOf.k9unit_fetch < indexOf.k9unit, 'k9unit_fetch must likewise be registered before k9unit on the re-registration pass')
    t.isTrue(indexOf.k9unit_training < indexOf.k9unit, 'k9unit_training must likewise be registered before k9unit on the re-registration pass')

    -- The link items themselves must still correctly point at those
    -- already-registered ids after the re-registration.
    t.equals(f.findInMenu('k9unit', 'k9_defense').menu, 'k9unit_defense')
    t.equals(f.findInMenu('k9unit', 'k9_fetch').menu, 'k9unit_fetch')
    t.equals(f.findInMenu('k9unit', 'k9_training').menu, 'k9unit_training')
end)

t.test('Re-registering with NO wipe in between (this resource\'s own start firing twice, or ox_lib\'s restart happening twice back to back) does not duplicate any item -- verified against ox_lib\'s own real dedup semantics (registerRadial is a keyed table write; addRadialItem replaces an existing id in place)', function()
    local f = newRadialFixture({ features = { HandlerDownDefense = true, FetchMechanic = true, AdvancedBarkRadial = true, TrainingMode = true } })

    local idsBefore = f.allIds()
    local countBefore = #idsBefore

    -- Fire the SAME trigger again with no wipe in between -- exactly what
    -- ox_lib's real registerRadial/addRadialItem are idempotent against
    -- (unlike, e.g., ox_inventory's registerHook, which has no such
    -- built-in dedup -- see tests/inventory_spec.lua's own "CONTRACT
    -- DEPENDENCY" test for that contrasting case).
    f.fireResourceStart('qbx_k9unit')

    local idsAfter = f.allIds()
    t.equals(#idsAfter, countBefore, 'no new ids should have appeared, and none should have vanished')

    local seen = {}
    for _, id in ipairs(idsAfter) do
        t.isNil(seen[id], ('duplicate radial item id found after a redundant re-registration: %s'):format(tostring(id)))
        seen[id] = true
    end

    -- Also confirm the ROOT opener specifically stayed a single entry --
    -- the one item registered via lib.addRadialItem (registerRadial's
    -- dedup is structural/by-construction via a keyed table write, but
    -- addRadialItem's dedup is an explicit id-scan this pass verified
    -- against ox_lib's real source, so it deserves its own direct check).
    local openerCount = 0
    for _, id in ipairs(idsAfter) do
        if id == 'k9unit_open' then openerCount = openerCount + 1 end
    end
    t.equals(openerCount, 1, 'the root opener must appear exactly once, never duplicated by a redundant re-registration')
end)

t.test('Re-registering (via a simulated ox_lib restart) rebuilds fresh onSelect closures that still function correctly -- not stale/broken references into a torn-down state', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true } })

    f.wipeOxLibRadialState()
    f.fireResourceStart('ox_lib')

    f.findInMenu('k9unit', 'k9_takedown').onSelect()
    t.equals(#f.calls.RequestTakedown, 1, 'a freshly re-registered item\'s onSelect must still genuinely call through once access is granted')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- RadialMenu and
-- AdvancedBarkRadial. See client/radial.lua's own "K9 UNIT RADIAL --
-- PER-PERSON BLOCK" header for the full design: both are checked at
-- REGISTRATION time (unlike every other feature this pass touches, which
-- check at the point an ability acts) because both features ARE this
-- file's own registration structure. This relies on the SAME
-- REPLACE-in-place ox_lib semantics the "no wipe in between" test above
-- already verifies -- re-registering after a block change is safe, not a
-- new risk.
-- ----------------------------------------------------------------------

t.test('RadialMenu blocked for this specific client: the opener STAYS present (REPLACED, not removed -- see production code\'s own "DUPLICATE-VS-REPLACE" note) but no longer navigates anywhere, and denies via DenyK9FeatureBlocked (a distinct, honest reason from DenyK9UIAccess) instead', function()
    local f = newRadialFixture({ features = { RadialMenu = true } })
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'sanity: unblocked, the opener navigates into k9unit')

    f.setBlocked('RadialMenu', true)
    f.fireFeatureBlocksApplied()

    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'the opener stays visible rather than silently vanishing (no verified ox_lib removal call exists for this codebase to rely on)')
    t.isNil(opener.menu, 'it must no longer navigate into k9unit -- there is nothing useful behind it while blocked')
    t.isNotNil(opener.onSelect)

    opener.onSelect()
    t.equals(f.denyK9FeatureBlockedCallCount(), 1, 'must deny via the distinct, honest DenyK9FeatureBlocked reason')
    t.equals(f.denyCallCount(), 0, 'never the generic "not certified" DenyK9UIAccess -- this is a block, not an access denial')
end)

t.test('RadialMenu block is LIVE: registered at load, blocked afterward via the featureBlocksApplied event, unblocked again -- the opener re-links to k9unit without a resource restart', function()
    local f = newRadialFixture({ features = { RadialMenu = true } })

    f.setBlocked('RadialMenu', true)
    f.fireFeatureBlocksApplied()
    t.isNil(f.findRootItem('k9unit_open').menu)

    f.setBlocked('RadialMenu', false)
    f.fireFeatureBlocksApplied()
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'unblocking must restore real navigation on the very next rebuild, no restart required')
    t.isNotNil(f.findMenu('k9unit'), 'and the submenu itself must be registered again too')
end)

t.test('RadialMenu block never touches OTHER abilities\' own resource-global functions -- K9Sit() itself keeps working when called directly (a block only removes ONE entry point\'s usefulness, never an ability)', function()
    local f = newRadialFixture({ features = { RadialMenu = true } })

    f.setBlocked('RadialMenu', true)
    f.fireFeatureBlocksApplied()
    t.isNil(f.findRootItem('k9unit_open').menu, 'sanity: the radial entry point no longer navigates anywhere')

    -- The resource-global K9Sit() itself (the SAME function every other
    -- surface -- keybind, command, tablet trigger, export -- would call)
    -- is completely untouched by this file's own registration logic --
    -- proving a RadialMenu block only ever removes the ONE entry point
    -- this file owns, never the ability.
    f.env.K9Sit()
    t.equals(#f.calls.K9Sit, 1, 'the underlying ability keeps working via any OTHER surface regardless of a RadialMenu block')
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- RadialMenu registers exactly as before this pass', function()
    local f = newRadialFixture({ features = { RadialMenu = true }, featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'an unknown block state must never disable the whole radial surface -- it must fail OPEN')
end)

t.test('AdvancedBarkRadial blocked for this specific client: Bark degrades to the SAME single, flat, generic item this file ships when the GLOBAL flag is false -- basic barking is unaffected', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })
    t.isNotNil(f.findMenu('k9unit_bark'), 'sanity: unblocked, the variant submenu IS registered')
    t.equals(f.findInMenu('k9unit', 'k9_bark').menu, 'k9unit_bark')

    f.setBlocked('AdvancedBarkRadial', true)
    f.fireFeatureBlocksApplied()

    local bark = f.findInMenu('k9unit', 'k9_bark')
    t.isNotNil(bark, 'Bark itself must still be offered -- only the ADVANCED variant submenu is withheld')
    t.isNil(bark.menu, 'must be a terminal action again, not a navigation link into the (now unreachable) variant submenu')
    t.isNotNil(bark.onSelect)

    bark.onSelect()
    t.equals(f.triggerServerEventCalls[#f.triggerServerEventCalls].args[1], 'bark', 'a blocked AdvancedBarkRadial must still send the plain generic bark type -- BasicBarkSounds has its own, separate, server-enforced block key this pass does not touch')
end)

t.test('AdvancedBarkRadial block is LIVE and reversible via the featureBlocksApplied event, same as RadialMenu', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })

    f.setBlocked('AdvancedBarkRadial', true)
    f.fireFeatureBlocksApplied()
    -- NOTE: k9unit_bark itself may still exist as an ORPHAN in ox_lib's own
    -- registry while blocked -- same disclosed, accepted nuance as the
    -- GLOBAL RadialMenu=false path above ("orphaned, but genuinely still
    -- registered"); this file only ever ADDS/REPLACES a menu id, it never
    -- calls an unverified removal API (see production code's own comment).
    -- What actually matters -- and what this test checks -- is that
    -- NOTHING REACHABLE from 'k9unit' still links to it.
    t.isNil(f.findInMenu('k9unit', 'k9_bark').menu, 'k9_bark must not navigate into the (possibly orphaned) k9unit_bark while blocked')

    f.setBlocked('AdvancedBarkRadial', false)
    f.fireFeatureBlocksApplied()
    t.isNotNil(f.findMenu('k9unit_bark'), 'unblocking must restore the variant submenu on the next rebuild')
    t.equals(f.findInMenu('k9unit', 'k9_bark').menu, 'k9unit_bark')
end)

t.test('a block on a DIFFERENT feature name never affects RadialMenu or AdvancedBarkRadial', function()
    local f = newRadialFixture({ features = { RadialMenu = true, AdvancedBarkRadial = true } })
    f.setBlocked('NightVision', true)
    f.fireFeatureBlocksApplied()
    t.isNotNil(f.findRootItem('k9unit_open'))
    t.isNotNil(f.findMenu('k9unit_bark'))
end)

t.test('the qbx_k9unit:client:featureBlocksApplied listener is registered exactly once per fixture, alongside the existing onResourceStart dispatcher', function()
    local f = newRadialFixture()
    t.equals(f.featureBlocksAppliedHandlerCount(), 1)
end)

os.exit(t.summary())
