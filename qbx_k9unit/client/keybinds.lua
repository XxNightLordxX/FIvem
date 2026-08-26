--[[
    qbx_k9unit/client/keybinds.lua

    Owner-directed pass: "the combat mechanics should be smooth it shouldnt
    all be 3rd eye it should all be keybinds programmable in the pause menu
    etc." This file is the SINGLE, centralized place every new
    `RegisterCommand` + `RegisterKeyMapping` pair this pass adds lives, so
    the full list of what got a rebindable key is legible from one file
    instead of scattered across the resource -- unlike this codebase's
    OLDER precedent (client/movement.lua's camera toggle,
    client/agility.lua's vault, client/pursuitsprint.lua,
    client/vision.lua's two toggles, client/defense.lua's confirm), which
    each pair their own RegisterCommand/RegisterKeyMapping call inline next
    to the function they wrap. Those five are NOT duplicated here -- they
    already have a working command + keybind pair and needed nothing from
    this pass; this file only fills the actual gap: BiteAndHold/
    NonLethalTakedown/PropDragging (client/combat.lua) had ZERO command or
    keybind entry point of any kind before this pass, reachable only by
    opening the ox_lib radial and clicking a "K9 Unit" submenu item -- the
    exact "third-eye" friction the owner named directly ("aiming a target
    menu at a fleeing suspect mid-pursuit").

    ======================================================================
    WHY THESE SIX ACTIONS AND NOT MORE -- THE FULL INVENTORY IS IN THE
    ACCOMPANYING REPORT, NOT REPEATED HERE IN FULL. Short version: every
    K9 action in this resource (radial items, ox_target options, existing
    RegisterCommand entries) was inventoried and split into FAST
    (split-second, no aiming, the owner's own named examples: "combat,
    sprint, bark, sit, release a hold") vs. DELIBERATE (stationary,
    consent-based, or already a multi-step interaction: certify someone,
    open the shop, place a kennel, attach a leash, deploy a search trail).
    Only the FAST ones landed here:
      - Bite & Hold / Release  (toggle) -- combat, client/combat.lua
      - Non-Lethal Takedown              -- combat, client/combat.lua
      - Drag / Release          (toggle) -- combat, client/combat.lua
      - Sit                               -- the owner's own named example
      - Bark (basic)                      -- the owner's own named example
      - Recall                            -- the universal "call your K9
                                             off NOW" panic button for all
                                             three combat mechanics above;
                                             the "release a hold" example
                                             generalized to its most urgent
                                             case. RE-USES the EXISTING
                                             `k9recall` command
                                             (client/recall.lua) -- see its
                                             own section below, this file
                                             adds ONLY the keybind half.
    Pursuit Sprint is the owner's other named example ("sprint") and
    ALREADY has a keybind (client/pursuitsprint.lua, default 'N') -- no
    action needed, listed in the report as "already keybound."
    Deliberately NOT added here, even though each is individually fast to
    press once you're already there: Leash attach (consent-based, and
    requires picking a candidate the same way combat does -- but the
    ability itself is a companion/utility mechanic, not a suspect-control
    one, and Detach alone is not worth a dedicated key), Fetch throw/
    release, Partner Up/Break Partnership, tracking start/stop, SAR calls,
    training toggles, vehicle enter/exit, inventory/medkit/kennel/prop
    actions. Every one of those already has a working radial and/or
    ox_target entry point and is either consent-based, area-search-based,
    or logistics rather than "split-second, get hit or don't." The owner's
    own words are the reason more were not added here: "easier to
    understand where if someone is a idiot they can figure it out very
    quickly" -- a keybind list nobody can navigate is its own kind of
    unusable, so this stays a short, memorable set rather than fifty
    entries in the pause menu.
    ======================================================================

    ======================================================================
    SAME FUNCTION, NEVER A FORKED ENTRY POINT -- fxmanifest.lua:166 records
    this resource's own prior incident on exactly this point
    (ScratchAtDoor/NudgeDoor: two surfaces reimplemented the same action
    and drifted, one ending up guarded and the other not). Every command
    below calls the IDENTICAL resource-global function client/radial.lua's
    own "K9 Unit" submenu already calls for the same action -- never a
    second copy of the gating/targeting logic:
      - k9bitehold  -> IsBiteHoldEngaged()/ReleaseBiteHold()/RequestBiteHold()
        (client/combat.lua) -- byte-for-byte the same toggle shape
        client/radial.lua's own "Bite & Hold / Release" item already uses.
      - k9takedown  -> RequestTakedown() (client/combat.lua) -- same
        function client/radial.lua's "Non-Lethal Takedown" item calls.
      - k9dragtoggle -> IsDragEngaged()/ReleaseDrag()/RequestDrag()
        (client/combat.lua) -- same toggle shape as client/radial.lua's
        "Drag / Release" item.
      - k9sit       -> K9Sit() (client/movement.lua) -- same function
        client/radial.lua's "Sit" item calls. K9Sit() does its OWN
        CanShowK9UI()/DenyK9UIAccess() gate internally, so this file adds
        no second copy of that check.
      - k9recall    -> no new function at all; this file adds ONLY the
        RegisterKeyMapping half for the command client/recall.lua ALREADY
        registers (`k9recall` -> RequestRecall()). See that section below.
    Every one of the above is called through this resource's standard
    `type(fn) == 'function'` soft-dependency guard (not a load-order
    assumption -- by the time a player can actually press one of these
    keys, every client_scripts file has already finished loading; the
    guard exists so this file also degrades safely if ever loaded standalone,
    e.g. under a future test harness, matching client/defense.lua's and
    client/radial.lua's own stated convention for the identical guard).

    THE ONE DISCLOSED EXCEPTION: k9bark below has NO existing shared
    global to call into -- client/radial.lua's own flat "Bark" item (the
    non-AdvancedBarkRadial branch) and client/tablet.lua's own bark trigger
    both already call `TriggerServerEvent('qbx_k9unit:server:relayBark',
    'bark')` inline, each after its own `CanShowK9UI()`/`DenyK9UIAccess()`
    check, rather than through a shared function -- this file's own
    k9bark command is therefore a THIRD independently-written copy of that
    same two-line shape, not a fork of a function this file could have
    called instead. Flagged here rather than silently matched: the
    drift risk is low (there is no decision logic beyond one access check
    and one literal string, and the real authority -- server/main.lua's
    relayBark handler -- independently re-validates everything regardless
    of what any of these three call sites claim), but a future pass that
    opens a single `RequestBasicBark()` seam in client/radial.lua (the file
    that already owns two of the three copies) and has all three call it
    would close this properly. Not done here: client/radial.lua and
    client/tablet.lua are both owned by other agents this session and are
    out of this file's edit scope. Reported to the tablet UI owner
    alongside the Commands-page handoff below.
    ======================================================================

    ======================================================================
    REGISTERKEYMAPPING SETS A DEFAULT ONLY -- stated plainly per this
    pass's own instruction. Every default key below (and the three
    Config.Combat.*.keybind/toggleKeybind config fields it reads) is
    exactly that: a DEFAULT a fresh install starts with. Once a player has
    rebound one of these in Settings > Key Bindings > FiveM, changing the
    config value (or this file) in a later update does NOT move their
    existing binding -- FiveM has no mechanism for a resource update to
    retroactively edit a player's own saved keybind. It only changes what
    a BRAND NEW player, or one who never touched this specific binding,
    starts with. Verified against the primary source before shipping any
    of this (citizenfx/fivem ext/native-decls/RegisterKeyMapping.md,
    fetched this pass): `RegisterKeyMapping(commandString, description,
    defaultMapper, defaultParameter)` -- signature and the "default" framing
    both confirmed directly from that page, not assumed from prose
    elsewhere. Default keys chosen below avoid every OTHER RegisterKeyMapping
    default already shipped in this resource (L camera, X vault, N pursuit
    sprint, H camera feed, K thermal vision, J night vision, G handler-down
    confirm) and every core WASD movement key -- picked the same way this
    codebase's own existing choices were (a free, uncommonly-bound letter,
    not a forced mnemonic -- 'X' for vault and 'N' for pursuit sprint are
    the established precedent that a perfect mnemonic is not required).
    Like every other keybind in this resource, none of this is enforced --
    the SAME gated resource-global function runs whether the player typed
    the `/k9x` command, pressed the bound key, or (for Sit/Bite & Hold/
    Takedown/Drag) clicked the equivalent client/radial.lua item; the
    server independently re-validates every combat request regardless of
    which surface fired it (server/combat.lua's ValidateCombatRequest -- see
    client/combat.lua's own header, "this file never decides whether the
    action is ALLOWED").
    ======================================================================

    ======================================================================
    DISCOVERABILITY -- the K9 Command Tablet's Commands page
    (html/tablet.js's COMMAND_REFERENCE, guarded by
    tests/commandreferenceregistry_spec.lua) is this resource's answer to
    "how does a player find out this exists at all." This file's FIVE new
    RegisterCommand names (k9bitehold, k9takedown, k9dragtoggle, k9sit,
    k9bark -- k9recall already has an entry, see below) are NOT added to
    that page by this pass: html/tablet.js is owned by other agents this
    session and is out of this file's edit scope. The exact five-entry
    payload (command/category/usageKey/doesKey/needsKey/gate shape, plus
    each command's own default key for a NEW "default key" display this
    pass is proposing) was handed to the tablet UI owner directly (see this
    pass's own report for the verbatim message) rather than guessed at
    here. Until that lands, these five commands are real and working but
    NOT listed on the tablet's Commands page -- a genuine, disclosed gap,
    not a silent one. tests/commandreferenceregistry_spec.lua's own
    hand-maintained CLIENT_LUA_FILES list also does not yet include
    'keybinds.lua' (that spec is not owned by this file either), so that
    drift guard does not yet even scan this file for RegisterCommand names
    -- also reported, not fixed here.
    ======================================================================
]]

-- ======================================================================
-- BITE & HOLD / RELEASE -- single context-sensitive toggle, the SAME shape
-- client/radial.lua's own "Bite & Hold / Release" item already uses.
-- Gated at REGISTRATION on Config.Features.BiteAndHold specifically (not
-- client/combat.lua's own looser file-level "at least one of the three"
-- OR-gate) so this command/keybind never appears to exist when THIS
-- mechanic specifically is off, even in the edge case where a DIFFERENT
-- combat mechanic being on is what keeps client/combat.lua's globals
-- defined at all.
-- ======================================================================
if Config.Features.BiteAndHold then
    RegisterCommand('k9bitehold', function()
        if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
            if type(ReleaseBiteHold) == 'function' then
                ReleaseBiteHold()
            end
            return
        end

        if type(RequestBiteHold) == 'function' then
            RequestBiteHold()
        end
    end, false)

    RegisterKeyMapping('k9bitehold', locale('combat.bite_hold_keybind_label'), 'keyboard', Config.Combat.BiteAndHold.toggleKeybind)
end

-- ======================================================================
-- NON-LETHAL TAKEDOWN -- a single one-shot action, not a toggle:
-- client/combat.lua exposes only RequestTakedown(), with no
-- release/cancel counterpart (the forced ragdoll it triggers always ends
-- on its own -- see client/combat.lua's own comment on RequestTakedown()).
-- Same "gate on THIS mechanic's own flag" reasoning as Bite & Hold above.
-- ======================================================================
if Config.Features.NonLethalTakedown then
    RegisterCommand('k9takedown', function()
        if type(RequestTakedown) == 'function' then
            RequestTakedown()
        end
    end, false)

    RegisterKeyMapping('k9takedown', locale('combat.takedown_keybind_label'), 'keyboard', Config.Combat.NonLethalTakedown.keybind)
end

-- ======================================================================
-- DRAG / RELEASE -- single context-sensitive toggle, the SAME shape as
-- Bite & Hold above and client/radial.lua's own "Drag / Release" item.
-- Same "gate on THIS mechanic's own flag" reasoning as Bite & Hold above.
-- ======================================================================
if Config.Features.PropDragging then
    RegisterCommand('k9dragtoggle', function()
        if type(IsDragEngaged) == 'function' and IsDragEngaged() then
            if type(ReleaseDrag) == 'function' then
                ReleaseDrag()
            end
            return
        end

        if type(RequestDrag) == 'function' then
            RequestDrag()
        end
    end, false)

    RegisterKeyMapping('k9dragtoggle', locale('combat.drag_keybind_label'), 'keyboard', Config.Combat.PropDragging.toggleKeybind)
end

-- ======================================================================
-- SIT -- the owner's own named "fast" example. Registered UNCONDITIONALLY
-- (no Config.Features wrapper), mirroring client/movement.lua's own
-- ToggleK9Camera()/'qbx_k9unit:toggleCamera' precedent exactly: Sit has no
-- dedicated Config.Features flag of its own (client/radial.lua's own
-- comment on its "Sit" item: "bundled under the general RadialMenu flag +
-- access check, same as every other Phase 1 item here"), and K9Sit()
-- itself (client/movement.lua) already performs the real
-- CanShowK9UI()/DenyK9UIAccess() gate internally on every call -- adding a
-- second, independent RadialMenu check here would only make this
-- keybind's availability diverge from the radial's own ability to reach
-- it via other means (e.g. the tablet), for no correctness benefit.
-- ======================================================================
RegisterCommand('k9sit', function()
    if type(K9Sit) == 'function' then
        K9Sit()
    end
end, false)

RegisterKeyMapping('k9sit', locale('radial.sit_keybind_label'), 'keyboard', 'V')

-- ======================================================================
-- BARK (basic) -- the owner's own named "fast" example. Gated on
-- Config.Features.BasicBarkSounds, matching client/radial.lua's own gate
-- on its flat "Bark" item (the non-AdvancedBarkRadial branch this mirrors
-- -- the advanced VARIANT submenu stays radial-only on purpose: picking a
-- specific bark flavor from a list is a deliberate, stationary choice, not
-- a split-second one, so it is not duplicated here). See this file's
-- header "THE ONE DISCLOSED EXCEPTION" for why this is a third
-- independent copy of the same two-line gate-then-trigger shape rather
-- than a call into a shared function.
-- ======================================================================
if Config.Features.BasicBarkSounds then
    RegisterCommand('k9bark', function()
        if not CanShowK9UI() then
            DenyK9UIAccess()
            return
        end

        -- server/main.lua's relayBark handler re-validates
        -- Config.Features.BasicBarkSounds and HasK9Access independently
        -- regardless -- same posture as every other trigger in this file.
        TriggerServerEvent('qbx_k9unit:server:relayBark', 'bark')
    end, false)

    RegisterKeyMapping('k9bark', locale('radial.bark_keybind_label'), 'keyboard', 'C')
end

-- ======================================================================
-- RECALL -- the universal "call your K9 off NOW" panic button, generalizing
-- the owner's "release a hold" example to its most urgent case: it ends
-- WHATEVER engagement (bite/takedown/drag) the local player's partnered K9
-- currently has active, from either side of the partnership. NO NEW
-- COMMAND OR FUNCTION HERE -- client/recall.lua already registers
-- `k9recall` -> RequestRecall(), unconditionally available whenever
-- Config.Features.Recall is on (its own header: "TERMINATION MUST NEVER BE
-- GATED"). This file adds ONLY the missing RegisterKeyMapping half, gated
-- on the SAME Config.Features.Recall flag client/recall.lua's own
-- top-of-file gate already uses, so this file's registration and that
-- file's command registration can never disagree about whether `k9recall`
-- exists to bind a key to.
-- ======================================================================
if Config.Features.Recall then
    RegisterKeyMapping('k9recall', locale('recall.keybind_label'), 'keyboard', 'U')
end

-- ======================================================================
-- SCENT VISION -- owner-directed pass: "make scent tracking... a keybind
-- that makes a colour dot appear where players[' ] blood etc have walked".
-- A single toggle, the SAME shape as client/vision.lua's
-- ToggleThermalVision/ToggleNightVision (this file's own header note on
-- BiteHold/Takedown/Drag's shared-function convention applies here too —
-- calls the IDENTICAL client/tracking.lua global a future radial/tablet
-- entry would call, never a second copy of the toggle logic). Gated on
-- Config.Features.ScentVision specifically, matching every other
-- conditionally-registered entry in this file. Default key sourced from
-- config.lua (Config.Tracking.ScentVision.keybind), matching the
-- BiteAndHold/NonLethalTakedown/PropDragging precedent above (a config-owned
-- default, not a literal baked into this file) since the owner's own brief
-- for this specific feature asks for it to be "fully editable... in the
-- config" — a DEFAULT only, per this file's own header: a player who
-- rebinds this in Settings keeps their own choice regardless of a later
-- config edit.
-- ======================================================================
if Config.Features.ScentVision then
    RegisterCommand('k9scentvision', function()
        if type(ToggleScentVision) == 'function' then
            ToggleScentVision()
        end
    end, false)

    RegisterKeyMapping('k9scentvision', locale('tracking.scent_vision_keybind_label'), 'keyboard', Config.Tracking.ScentVision.keybind)
end
