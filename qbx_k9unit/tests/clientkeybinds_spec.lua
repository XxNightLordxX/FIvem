--[[
    tests/clientkeybinds_spec.lua

    Direct, black-box tests of client/keybinds.lua against the REAL,
    unmodified production file -- the owner-directed "combat should be
    keybinds, not third-eye" pass. This file registers five NEW
    RegisterCommand/RegisterKeyMapping pairs (k9bitehold, k9takedown,
    k9dragtoggle, k9sit, k9bark) plus ONE keybind-only addition for the
    PRE-EXISTING `k9recall` command (the removed recall client file). A trap-hunt pass
    later added a SEVENTH pair, k9exitkennel (client/kennel.lua's
    ExitKennelRest()) -- registered UNCONDITIONALLY, unlike every
    conditionally-gated command above, since it is a confining-mechanic
    escape hatch that must never be gated (see client/keybinds.lua's own
    header "ONE DELIBERATE EXCEPTION" section). Every commandCount()/
    keyMappingCalls assertion below accounts for it being present
    regardless of which Config.Features flags this fixture sets.

    THE THREE THINGS THIS SPEC EXISTS TO PIN:
      1. SAME FUNCTION, NEVER A FORKED ENTRY POINT -- every command calls
         the IDENTICAL resource-global function client/radial.lua's own
         "K9 Unit" submenu already calls (IsBiteHoldEngaged/ReleaseBiteHold/
         RequestBiteHold, RequestTakedown, IsDragEngaged/ReleaseDrag/
         RequestDrag, K9Sit). Proven the same way this suite proves a "same
         function" claim elsewhere: the fixture below supplies each of
         those as a small recording stub and asserts on WHICH ONE was
         called for a given toggle state, never re-deriving the
         gating/targeting logic itself (that already belongs to
         client/combat.lua's own spec).
      2. PER-MECHANIC REGISTRATION GATING -- each of the three combat
         commands/keybinds exists ONLY when its OWN Config.Features flag is
         true, independent of the other two (client/combat.lua's own
         looser file-level OR-gate is deliberately NOT mirrored here -- see
         client/keybinds.lua's header). Sit is registered
         UNCONDITIONALLY (no Config.Features flag governs it at all, same
         as client/movement.lua's own ToggleK9Camera() precedent). Bark and
         the k9recall KEYBIND both follow their own single dedicated flag.
      3. k9recall gets ONLY a RegisterKeyMapping call from this file, never
         a second RegisterCommand -- proven by loading client/keybinds.lua
         ALONE (never the removed recall client file) and confirming no `k9recall`
         command handler exists in this fixture at all, only a keyMapping
         entry.

    STUBBING EFFORT: proportionate. Every native/global this file could
    possibly call is either a small recording stub or DELIBERATELY ABSENT
    (RegisterNetEvent, CreateThread, Wait, TaskPlayAnim, and every other
    movement/task native) -- if this file ever grew a per-frame thread or a
    direct native call, the relevant "absence" test below would fail with
    "attempt to call a nil value", not silently pass. locale() is the REAL
    Sandbox.locale reading the real locales/en.json, so every test that
    reaches a locale() call also proves that key actually exists in the
    shipped locale file.

    ONE FRESH SANDBOX PER TEST.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts {
---     biteAndHold: boolean?, nonLethalTakedown: boolean?, propDragging: boolean?,
---     basicBarkSounds: boolean?, recall: boolean?,
---     provideBiteHoldGlobals: boolean?, provideDragGlobals: boolean?,
---     provideTakedown: boolean?, provideK9Sit: boolean?,
---     canShowK9UI: boolean?,
---     toggleKeybindBite: string?, keybindTakedown: string?, toggleKeybindDrag: string?,
--- }?
local function newKeybindsFixture(opts)
    opts = opts or {}

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted) commandHandlers[name] = handler end

    local keyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        keyMappingCalls[#keyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    local biteHoldEngaged = false
    local releaseBiteHoldCalls = 0
    local requestBiteHoldCalls = 0
    local function IsBiteHoldEngaged() return biteHoldEngaged end
    local function ReleaseBiteHold() releaseBiteHoldCalls = releaseBiteHoldCalls + 1 end
    local function RequestBiteHold() requestBiteHoldCalls = requestBiteHoldCalls + 1 end

    local dragEngaged = false
    local dragTargetEngaged = false
    local releaseDragCalls = 0
    local requestDragCalls = 0
    local function IsDragEngaged() return dragEngaged end
    local function IsDragTargetEngaged() return dragTargetEngaged end
    local function ReleaseDrag() releaseDragCalls = releaseDragCalls + 1 end
    local function RequestDrag() requestDragCalls = requestDragCalls + 1 end

    local requestTakedownCalls = 0
    local function RequestTakedown() requestTakedownCalls = requestTakedownCalls + 1 end
    -- Takedown became a TOGGLE this pass -- see the k9takedown tests below.
    -- Supplied under the SAME opts.provideTakedown flag as RequestTakedown,
    -- so the "tolerates the whole takedown surface being undefined" test
    -- covers these two as well rather than leaving new soft dependencies
    -- untested, exactly as the drag surface already does for its own four.
    local takedownEngaged = false
    local releaseTakedownCalls = 0
    local function IsTakedownEngaged() return takedownEngaged end
    local function ReleaseTakedown() releaseTakedownCalls = releaseTakedownCalls + 1 end

    local k9SitCalls = 0
    local function K9Sit() k9SitCalls = k9SitCalls + 1 end

    local exitKennelRestCalls = 0
    local function ExitKennelRest() exitKennelRestCalls = exitKennelRestCalls + 1 end

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local denyCalls = 0
    local function CanShowK9UI() return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local toggleScentVisionCalls = 0
    local function ToggleScentVision() toggleScentVisionCalls = toggleScentVisionCalls + 1 end

    local Config = {
        Features = {
            BiteAndHold = opts.biteAndHold ~= false,
            NonLethalTakedown = opts.nonLethalTakedown ~= false,
            PropDragging = opts.propDragging ~= false,
            BasicBarkSounds = opts.basicBarkSounds ~= false,
            Recall = opts.recall ~= false,
            -- DELIBERATELY THE ONE FLAG IN THIS TABLE THAT DEFAULTS FALSE,
            -- unlike its four siblings above (`~= false`, i.e. "on unless
            -- explicitly turned off"): this fixture's own pre-existing
            -- "all five feature flags on" test (Section A below) asserts an
            -- exact commandCount()/#keyMappingCalls total that predates
            -- ScentVision. Defaulting this flag OFF here keeps every
            -- existing test in this file passing unchanged; a NEW test that
            -- wants ScentVision registered passes `{ scentVision = true }`
            -- explicitly (see the ScentVision section further below).
            ScentVision = opts.scentVision == true,
        },
        Combat = {
            BiteAndHold = { toggleKeybind = opts.toggleKeybindBite or 'B' },
            NonLethalTakedown = { keybind = opts.keybindTakedown or 'T' },
            PropDragging = { toggleKeybind = opts.toggleKeybindDrag or 'Y' },
        },
        Tracking = {
            -- 'Z' matches config.lua's own real shipped default (changed
            -- from an earlier 'B', which collided with
            -- Config.Combat.BiteAndHold.toggleKeybind -- see that field's
            -- own comment in config.lua) -- this fixture builds its own
            -- independent Config table (never loads real config.lua), so
            -- this value has no correctness dependency on the real one, but
            -- matching it avoids a future reader assuming otherwise.
            ScentVision = { keybind = opts.keybindScentVision or 'Z' },
        },
    }

    local overrides = {
        Config = Config,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        TriggerServerEvent = TriggerServerEvent,
    }
    if opts.provideToggleScentVision ~= false then
        overrides.ToggleScentVision = ToggleScentVision
    end
    if opts.provideBiteHoldGlobals ~= false then
        overrides.IsBiteHoldEngaged = IsBiteHoldEngaged
        overrides.ReleaseBiteHold = ReleaseBiteHold
        overrides.RequestBiteHold = RequestBiteHold
    end
    if opts.provideDragGlobals ~= false then
        overrides.IsDragEngaged = IsDragEngaged
        overrides.ReleaseDrag = ReleaseDrag
        overrides.RequestDrag = RequestDrag
        -- Deliberately supplied under the SAME opts flag as its three
        -- siblings, so the "tolerates the whole drag surface being
        -- undefined" test below covers this one too rather than leaving a
        -- brand-new soft dependency untested.
        overrides.IsDragTargetEngaged = IsDragTargetEngaged
    end
    if opts.provideTakedown ~= false then
        overrides.RequestTakedown = RequestTakedown
        overrides.IsTakedownEngaged = IsTakedownEngaged
        overrides.ReleaseTakedown = ReleaseTakedown
    end
    if opts.provideK9Sit ~= false then
        overrides.K9Sit = K9Sit
    end
    if opts.provideExitKennelRest ~= false then
        overrides.ExitKennelRest = ExitKennelRest
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../client/keybinds.lua', env)

    return {
        env = env,
        commandHandlers = commandHandlers,
        keyMappingCalls = keyMappingCalls,
        serverEvents = serverEvents,
        denyCallCount = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setBiteHoldEngaged = function(v) biteHoldEngaged = v end,
        setDragEngaged = function(v) dragEngaged = v end,
        setDragTargetEngaged = function(v) dragTargetEngaged = v end,
        releaseBiteHoldCallCount = function() return releaseBiteHoldCalls end,
        requestBiteHoldCallCount = function() return requestBiteHoldCalls end,
        releaseDragCallCount = function() return releaseDragCalls end,
        requestDragCallCount = function() return requestDragCalls end,
        requestTakedownCallCount = function() return requestTakedownCalls end,
        releaseTakedownCallCount = function() return releaseTakedownCalls end,
        setTakedownEngaged = function(v) takedownEngaged = v end,
        k9SitCallCount = function() return k9SitCalls end,
        exitKennelRestCallCount = function() return exitKennelRestCalls end,
        toggleScentVisionCallCount = function() return toggleScentVisionCalls end,
        commandCount = function()
            local n = 0
            for _ in pairs(commandHandlers) do n = n + 1 end
            return n
        end,
        findKeyMapping = function(commandName)
            for _, call in ipairs(keyMappingCalls) do
                if call.commandName == commandName then return call end
            end
            return nil
        end,
        runCommand = function(name)
            local handler = assert(commandHandlers[name], 'client/keybinds.lua did not register ' .. name)
            handler()
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- per-mechanic registration gating.
-- ----------------------------------------------------------------------

t.test('Config.Features.BiteAndHold = false: no k9bitehold command, no keybind for it -- the other four (plus the always-on k9exitkennel) are unaffected', function()
    local f = newKeybindsFixture({ biteAndHold = false })
    t.isNil(f.commandHandlers['k9bitehold'])
    t.isNil(f.findKeyMapping('k9bitehold'))
    t.equals(f.commandCount(), 5)
    t.isNotNil(f.commandHandlers['k9takedown'])
    t.isNotNil(f.commandHandlers['k9dragtoggle'])
    t.isNotNil(f.commandHandlers['k9exitkennel'])
end)

t.test('Config.Features.NonLethalTakedown = false: no k9takedown command, no keybind for it', function()
    local f = newKeybindsFixture({ nonLethalTakedown = false })
    t.isNil(f.commandHandlers['k9takedown'])
    t.isNil(f.findKeyMapping('k9takedown'))
    t.equals(f.commandCount(), 5)
end)

t.test('Config.Features.PropDragging = false: no k9dragtoggle command, no keybind for it', function()
    local f = newKeybindsFixture({ propDragging = false })
    t.isNil(f.commandHandlers['k9dragtoggle'])
    t.isNil(f.findKeyMapping('k9dragtoggle'))
    t.equals(f.commandCount(), 5)
end)

t.test('Config.Features.BasicBarkSounds = false: no k9bark command, no keybind for it', function()
    local f = newKeybindsFixture({ basicBarkSounds = false })
    t.isNil(f.commandHandlers['k9bark'])
    t.isNil(f.findKeyMapping('k9bark'))
    t.equals(f.commandCount(), 5)
end)

t.test('all combat/bark flags off: k9sit and k9exitkennel are STILL registered -- neither has a dedicated Config.Features flag of its own (k9sit mirrors client/movement.lua ToggleK9Camera(); k9exitkennel must never be gated at all, see this file own header)', function()
    local f = newKeybindsFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = false, basicBarkSounds = false, recall = false })
    t.equals(f.commandCount(), 2)
    t.isNotNil(f.commandHandlers['k9sit'])
    t.isNotNil(f.commandHandlers['k9exitkennel'])
    t.equals(#f.keyMappingCalls, 2)
    t.equals(f.keyMappingCalls[1].commandName, 'k9sit')
    t.equals(f.keyMappingCalls[2].commandName, 'k9exitkennel')
end)

-- ----------------------------------------------------------------------
-- SECTION B -- k9recall: keybind-only, never a second command.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- SECTION C -- default keys come from config, and match the locale labels.
-- ----------------------------------------------------------------------

t.test('k9bitehold keybind default reads Config.Combat.BiteAndHold.toggleKeybind, not a hardcoded literal', function()
    local f = newKeybindsFixture({ toggleKeybindBite = 'Z' })
    t.equals(f.findKeyMapping('k9bitehold').defaultKey, 'Z')
    t.equals(f.findKeyMapping('k9bitehold').description, locale('combat.bite_hold_keybind_label'))
end)

t.test('k9takedown keybind default reads Config.Combat.NonLethalTakedown.keybind, not a hardcoded literal', function()
    local f = newKeybindsFixture({ keybindTakedown = 'Z' })
    t.equals(f.findKeyMapping('k9takedown').defaultKey, 'Z')
    t.equals(f.findKeyMapping('k9takedown').description, locale('combat.takedown_keybind_label'))
end)

t.test('k9dragtoggle keybind default reads Config.Combat.PropDragging.toggleKeybind, not a hardcoded literal', function()
    local f = newKeybindsFixture({ toggleKeybindDrag = 'Z' })
    t.equals(f.findKeyMapping('k9dragtoggle').defaultKey, 'Z')
    t.equals(f.findKeyMapping('k9dragtoggle').description, locale('combat.drag_keybind_label'))
end)

t.test('k9sit / k9bark keybind descriptions match their locale labels (defaults are literal, not config-driven -- see this file own header)', function()
    local f = newKeybindsFixture()
    local sit = f.findKeyMapping('k9sit')
    t.equals(sit.defaultKey, 'V')
    t.equals(sit.description, locale('radial.sit_keybind_label'))

    local bark = f.findKeyMapping('k9bark')
    t.equals(bark.defaultKey, 'C')
    t.equals(bark.description, locale('radial.bark_keybind_label'))
end)

t.test('no two of this file own default keys collide with each other', function()
    local f = newKeybindsFixture()
    local seen = {}
    for _, call in ipairs(f.keyMappingCalls) do
        t.isNil(seen[call.defaultKey], ('default key %s used more than once in client/keybinds.lua'):format(tostring(call.defaultKey)))
        seen[call.defaultKey] = call.commandName
    end
end)

-- ----------------------------------------------------------------------
-- SECTION D -- SAME FUNCTION: each command calls the identical global
-- client/radial.lua's own item already calls, chosen by the identical
-- toggle predicate.
-- ----------------------------------------------------------------------

t.test('k9bitehold: not engaged -> calls RequestBiteHold(), never ReleaseBiteHold()', function()
    local f = newKeybindsFixture()
    f.setBiteHoldEngaged(false)
    f.runCommand('k9bitehold')
    t.equals(f.requestBiteHoldCallCount(), 1)
    t.equals(f.releaseBiteHoldCallCount(), 0)
end)

t.test('k9bitehold: engaged -> calls ReleaseBiteHold(), never RequestBiteHold()', function()
    local f = newKeybindsFixture()
    f.setBiteHoldEngaged(true)
    f.runCommand('k9bitehold')
    t.equals(f.releaseBiteHoldCallCount(), 1)
    t.equals(f.requestBiteHoldCallCount(), 0)
end)

t.test('k9bitehold: tolerates IsBiteHoldEngaged/ReleaseBiteHold/RequestBiteHold being entirely undefined (soft dependency) -- must not error', function()
    local f = newKeybindsFixture({ provideBiteHoldGlobals = false })
    t.isNil(f.env.IsBiteHoldEngaged)
    f.runCommand('k9bitehold') -- must not error
end)

t.test('k9dragtoggle: not engaged -> calls RequestDrag(), never ReleaseDrag()', function()
    local f = newKeybindsFixture()
    f.setDragEngaged(false)
    f.runCommand('k9dragtoggle')
    t.equals(f.requestDragCallCount(), 1)
    t.equals(f.releaseDragCallCount(), 0)
end)

t.test('k9dragtoggle: engaged -> calls ReleaseDrag(), never RequestDrag()', function()
    local f = newKeybindsFixture()
    f.setDragEngaged(true)
    f.runCommand('k9dragtoggle')
    t.equals(f.releaseDragCallCount(), 1)
    t.equals(f.requestDragCallCount(), 0)
end)

t.test('k9dragtoggle: tolerates IsDragEngaged/IsDragTargetEngaged/ReleaseDrag/RequestDrag being entirely undefined (soft dependency) -- must not error', function()
    local f = newKeybindsFixture({ provideDragGlobals = false })
    t.isNil(f.env.IsDragEngaged)
    t.isNil(f.env.IsDragTargetEngaged)
    f.runCommand('k9dragtoggle') -- must not error
end)

-- ------------------------------------------------------------------
-- UNREACHABLE-SELF-RELEASE FIX. server/combat.lua's releaseDrag handler
-- has always accepted a release from the TARGET as well as the holder --
-- deliberately, and unlike bite and takedown, whose targets have no
-- self-release at all. Nothing on the target's side could ever reach it:
-- this command asked IsDragEngaged() (holder-only), got false for a
-- target, and fell through to RequestDrag(), which denies anyone who is
-- not a K9. So the person being dragged pressed their Drag / Release key
-- and were told they may not use K9 controls.
-- ------------------------------------------------------------------

t.test('k9dragtoggle: UNREACHABLE-SELF-RELEASE FIX -- the person BEING dragged releases themselves, and never falls through to the request path', function()
    local f = newKeybindsFixture()
    f.setDragEngaged(false)       -- not the holder...
    f.setDragTargetEngaged(true)  -- ...the one being dragged
    f.setCanShowK9UI(false)       -- a dragged suspect is not a K9, and never was

    f.runCommand('k9dragtoggle')
    t.equals(f.releaseDragCallCount(), 1, 'the key they were told frees them must actually free them')
    t.equals(f.requestDragCallCount(), 0, 'never the request path -- that is what used to deny them')
    t.equals(f.denyCallCount(), 0, 'and never the "you are not allowed to use K9 controls" denial')
end)

t.test('k9dragtoggle: UNREACHABLE-SELF-RELEASE FIX -- neither dragging nor being dragged still falls through to RequestDrag() as before', function()
    local f = newKeybindsFixture()
    f.setDragEngaged(false)
    f.setDragTargetEngaged(false)
    f.runCommand('k9dragtoggle')
    t.equals(f.requestDragCallCount(), 1, 'the ordinary "start a drag" path must be untouched by the fix')
    t.equals(f.releaseDragCallCount(), 0)
end)

t.test('k9dragtoggle: UNREACHABLE-SELF-RELEASE FIX -- a holder is still a holder: one release, not two', function()
    local f = newKeybindsFixture()
    f.setDragEngaged(true)
    f.setDragTargetEngaged(false)
    f.runCommand('k9dragtoggle')
    t.equals(f.releaseDragCallCount(), 1, 'two release branches must never mean two server events for one keypress')
    t.equals(f.requestDragCallCount(), 0)
end)

t.test('k9takedown: calls RequestTakedown() exactly once, unconditionally (no toggle -- see client/combat.lua own header on why this mechanic has no release counterpart)', function()
    local f = newKeybindsFixture()
    f.runCommand('k9takedown')
    t.equals(f.requestTakedownCallCount(), 1)
end)

t.test('k9takedown: tolerates RequestTakedown being entirely undefined (soft dependency) -- must not error', function()
    local f = newKeybindsFixture({ provideTakedown = false })
    t.isNil(f.env.RequestTakedown)
    f.runCommand('k9takedown') -- must not error
end)

t.test('k9sit: calls K9Sit() exactly once -- this file adds NO second CanShowK9UI() check of its own (K9Sit() already gates internally)', function()
    local f = newKeybindsFixture()
    f.runCommand('k9sit')
    t.equals(f.k9SitCallCount(), 1)
    t.equals(f.denyCallCount(), 0, 'k9sit must not call DenyK9UIAccess() itself -- that is K9Sit() own job')
end)

t.test('k9sit: tolerates K9Sit being entirely undefined (soft dependency) -- must not error', function()
    local f = newKeybindsFixture({ provideK9Sit = false })
    t.isNil(f.env.K9Sit)
    f.runCommand('k9sit') -- must not error
end)

-- ----------------------------------------------------------------------
-- SECTION E -- k9bark: the one command with its own inline gate (no
-- shared global exists to call into -- see this file own header "THE ONE
-- DISCLOSED EXCEPTION").
-- ----------------------------------------------------------------------

t.test('k9bark: CanShowK9UI() true -> fires the RAW relayBark server event with the literal bark type, exactly once', function()
    local f = newKeybindsFixture()
    f.runCommand('k9bark')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:relayBark')
    t.equals(f.serverEvents[1].args[1], 'bark')
    t.equals(f.denyCallCount(), 0)
end)

t.test('k9bark: CanShowK9UI() false -> DenyK9UIAccess() called, NO server event fired', function()
    local f = newKeybindsFixture({ canShowK9UI = false })
    f.runCommand('k9bark')
    t.equals(#f.serverEvents, 0)
    t.equals(f.denyCallCount(), 1)
end)

-- ----------------------------------------------------------------------
-- SECTION F -- no per-frame cost: this file starts zero threads and calls
-- zero natives outside a command handler's own on-press body.
-- ----------------------------------------------------------------------

t.test('NO CONTINUOUS THREAD: this file registers zero CreateThread calls of any kind -- every action here is purely on-press, never a polling loop', function()
    local threadCalls = 0
    local env = Sandbox.newEnv({
        Config = {
            Features = { BiteAndHold = true, NonLethalTakedown = true, PropDragging = true, BasicBarkSounds = true, Recall = true },
            Combat = {
                BiteAndHold = { toggleKeybind = 'B' },
                NonLethalTakedown = { keybind = 'T' },
                PropDragging = { toggleKeybind = 'Y' },
            },
        },
        RegisterCommand = function() end,
        RegisterKeyMapping = function() end,
        CanShowK9UI = function() return true end,
        DenyK9UIAccess = function() end,
        TriggerServerEvent = function() end,
        CreateThread = function(_fn) threadCalls = threadCalls + 1 end,
    })
    Sandbox.loadInto('../client/keybinds.lua', env)
    t.equals(threadCalls, 0)
end)

t.test('k9bitehold/k9dragtoggle/k9takedown/k9sit/k9bark handlers never touch any movement/task/animation native directly -- proven by their total absence from the sandbox', function()
    local f = newKeybindsFixture()
    for _, name in ipairs({
        'SetEntityCoords', 'SetEntityHeading', 'TaskPlayAnim', 'TaskCombatPed',
        'TaskGoToEntity', 'ClearPedTasks', 'ClearPedTasksImmediately',
        'DisableControlAction', 'SetPedMoveRateOverride', 'AttachEntityToEntity',
        'PlayerPedId', 'GetEntityCoords',
    }) do
        t.isNil(f.env[name], name .. ' must be genuinely absent from this sandbox for this test to prove anything')
    end

    f.runCommand('k9bitehold')
    f.runCommand('k9dragtoggle')
    f.runCommand('k9takedown')
    f.runCommand('k9sit')
    f.runCommand('k9bark')
    -- Reaching here at all (no "attempt to call a nil value" error) is the assertion.
end)

-- ----------------------------------------------------------------------
-- SCENT VISION -- owner-directed pass. Same "gate on THIS mechanic's own
-- flag" convention as BiteAndHold/NonLethalTakedown/PropDragging above;
-- calls the IDENTICAL client/tracking.lua global a future radial/tablet
-- entry would call, never a second copy of the toggle logic (this file's
-- own header "SAME FUNCTION, NEVER A FORKED ENTRY POINT" section).
-- ----------------------------------------------------------------------

t.test('Config.Features.ScentVision = true: registers k9scentvision, keybound to Config.Tracking.ScentVision.keybind', function()
    local f = newKeybindsFixture({ scentVision = true, keybindScentVision = 'Z' })

    t.isNotNil(f.commandHandlers['k9scentvision'])
    local mapping = f.findKeyMapping('k9scentvision')
    t.isNotNil(mapping, 'k9scentvision must get a RegisterKeyMapping call')
    t.equals(mapping.defaultKey, 'Z', 'the DEFAULT key must come from config.lua (Config.Tracking.ScentVision.keybind), not a literal baked into this file')

    f.runCommand('k9scentvision')
    t.equals(f.toggleScentVisionCallCount(), 1, 'k9scentvision must call the SAME client/tracking.lua global a future radial/tablet entry would call')
end)

t.test('Config.Features.ScentVision = false (the default in this fixture): no k9scentvision command, no keybind for it', function()
    local f = newKeybindsFixture()
    t.isNil(f.commandHandlers['k9scentvision'])
    t.isNil(f.findKeyMapping('k9scentvision'))
end)

t.test('k9scentvision never errors even if client/tracking.lua (and therefore ToggleScentVision) is not loaded -- soft dependency, not a load-order assumption', function()
    local f = newKeybindsFixture({ scentVision = true, provideToggleScentVision = false })
    t.isNil(f.env.ToggleScentVision, 'ToggleScentVision must be genuinely absent from this sandbox for this test to prove anything')
    f.runCommand('k9scentvision') -- must not throw "attempt to call a nil value"
end)

t.test('k9scentvision does not touch any movement/task/animation native directly, matching the other five commands in this file', function()
    local f = newKeybindsFixture({ scentVision = true })
    f.runCommand('k9scentvision')
    -- Reaching here at all (no "attempt to call a nil value" error, since
    -- this fixture never provides any movement/task native) is the assertion.
end)

-- ----------------------------------------------------------------------
-- EXIT KENNEL -- trap-hunt fix. UNCONDITIONAL registration (no
-- Config.Features.DeployableKennel wrapper, unlike every combat/bark/
-- scent-vision command above) is the one thing this section exists to
-- pin down, alongside the usual SAME FUNCTION / soft-dependency coverage.
-- ----------------------------------------------------------------------

t.test('k9exitkennel: registered with EVERY Config.Features flag off, including DeployableKennel not even existing on this fixture Config at all', function()
    local f = newKeybindsFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = false, basicBarkSounds = false, recall = false, scentVision = false })
    t.isNotNil(f.commandHandlers['k9exitkennel'], 'k9exitkennel must never be gated behind any Config.Features flag -- it is a confining-mechanic escape hatch')
    local mapping = f.findKeyMapping('k9exitkennel')
    t.isNotNil(mapping)
    t.equals(mapping.defaultKey, 'O')
    t.equals(mapping.ioType, 'keyboard')
    t.equals(mapping.description, locale('kennel.exit_keybind_label'))
end)

t.test('k9exitkennel: calls the SAME ExitKennelRest() global client/radial.lua\'s new "Exit Kennel" item and client/kennel.lua\'s own ox_target option call -- never a second, forked release', function()
    local f = newKeybindsFixture()
    f.runCommand('k9exitkennel')
    t.equals(f.exitKennelRestCallCount(), 1)
end)

t.test('k9exitkennel: tolerates ExitKennelRest being entirely undefined (soft dependency, e.g. client/kennel.lua not loaded) -- must not error', function()
    local f = newKeybindsFixture({ provideExitKennelRest = false })
    t.isNil(f.env.ExitKennelRest, 'ExitKennelRest must be genuinely absent from this sandbox for this test to prove anything')
    f.runCommand('k9exitkennel') -- must not throw "attempt to call a nil value"
end)

t.test('k9exitkennel: does not touch CanShowK9UI()/DenyK9UIAccess() at all -- this exit must never be gated, not even by the usual "check here too" redundant convention every other item in this file uses', function()
    local f = newKeybindsFixture({ canShowK9UI = false })
    f.runCommand('k9exitkennel')
    t.equals(f.exitKennelRestCallCount(), 1, 'must still call through even with CanShowK9UI() false')
    t.equals(f.denyCallCount(), 0, 'must never call DenyK9UIAccess() -- an exit path is never denied')
end)


-- ========================================================================
-- TAKEDOWN IS NOW A TOGGLE (completeness QA finding, this pass).
-- ReleaseTakedown() had existed and been correct for some time -- ungated
-- on the way out, with a server handler that likewise never re-checks
-- access -- and was reachable from NOTHING but a unit test. Its own doc
-- comment said as much and named this file as one of the two that needed
-- to wire it.
--
-- Why it is not merely tidiness: RequestTakedown() picks the NEAREST
-- eligible ped, which client/combat.lua's own comment admits is "not
-- necessarily the intended one". Take down the wrong person in a crowd and
-- they stayed ragdolled and damage-immune for the full configured duration
-- with no undo. The only other early end is /k9recall -- a handler-side
-- action needing an active partnership -- so a solo K9 had no route at all.
-- ========================================================================
t.test('k9takedown: NOT engaged -> requests a takedown, exactly as before', function()
    local f = newKeybindsFixture()
    f.runCommand('k9takedown')
    t.equals(f.requestTakedownCallCount(), 1)
    t.equals(f.releaseTakedownCallCount(), 0)
end)

t.test('k9takedown: ENGAGED -> releases instead, and never falls through to the request path', function()
    local f = newKeybindsFixture()
    f.setTakedownEngaged(true)
    f.runCommand('k9takedown')
    t.equals(f.releaseTakedownCallCount(), 1, 'the wrongly-taken-down target must be releasable')
    t.equals(f.requestTakedownCallCount(), 0, 'falling through would fire a SECOND takedown request while one is already live')
end)

t.test('k9takedown: the release branch is UNGATED -- pressing the key while engaged releases even with no K9 access at all, because that is the STOP half', function()
    local f = newKeybindsFixture()
    f.setCanShowK9UI(false)  -- decertified mid-takedown; the STOP half must not care
    f.setTakedownEngaged(true)
    f.runCommand('k9takedown')
    t.equals(f.releaseTakedownCallCount(), 1, 'a K9 decertified mid-takedown must still be able to let go -- gate the start, never the stop')
end)

t.test('k9takedown: tolerates IsTakedownEngaged/ReleaseTakedown being entirely undefined (soft dependency) -- must not error', function()
    local f = newKeybindsFixture({ provideTakedown = false })
    t.isNil(f.env.IsTakedownEngaged)
    t.isNil(f.env.ReleaseTakedown)
    local ok = pcall(f.runCommand, 'k9takedown')
    t.isTrue(ok)
end)

os.exit(t.summary())
