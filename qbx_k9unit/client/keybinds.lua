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
    client/vision.lua's two toggles), which each pair their own
    RegisterCommand/RegisterKeyMapping call inline next to the function
    they wrap. Those are NOT duplicated here -- they
    already have a working command + keybind pair and needed nothing from
    this pass; this file only fills the actual gap: BiteAndHold/
    NonLethalTakedown/PropDragging (client/combat.lua) had ZERO command or
    keybind entry point of any kind before this pass, reachable only by
    opening the ox_lib radial and clicking a "K9 Unit" submenu item -- the
    exact "third-eye" friction the owner named directly ("aiming a target
    menu at a fleeing suspect mid-pursuit").

    ======================================================================
    WHY THESE ACTIONS AND NOT MORE -- THE FULL INVENTORY IS IN THE
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

    ONE DELIBERATE EXCEPTION, ADDED THIS PASS: k9exitkennel. "Kennel
    actions" above are excluded as logistics -- but that exclusion was
    written about DEPLOY/PICK UP/PUT DOWN/ENTER, never about EXIT, and a
    trap-hunting pass found exactly why exit needed its own answer: "Rest
    in Kennel" attaches the occupant's own ped inside a small cage prop
    (config.lua's Config.DeployableKennel.restOffsetX/Y/Z = 0,0,0, on
    purpose, so the ped sits inside the model's own bounds) -- meaning the
    only PRE-EXISTING way out was re-selecting that same small, likely
    camera-occluding prop through ox_target, with no radial entry, no
    keybind, and (see client/kennel.lua's own corrected WANDER-OFF EXIT
    comment) no working "just walk away" fallback either, since an
    attached ped's position is engine-enforced every tick regardless of
    movement input. This is a genuine "player stuck in a game" mechanic --
    category "confining," not "logistics" -- and the owner's own separate
    instruction (this pass) is that confining mechanics belong on a
    rebindable keybind, not third-eye-only. See client/kennel.lua's own
    ExitKennelRest() doc comment for the full trap writeup.
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
      - k9exitkennel -> ExitKennelRest() (client/kennel.lua) -- THIS PASS.
        The SAME function the new "Exit Kennel" item in client/radial.lua
        calls, and the SAME function the pre-existing "Exit Kennel"
        ox_target option on the kennel prop itself now also calls (see
        client/kennel.lua's own doc comment on that global).
    Every one of the above is called through this resource's standard
    `type(fn) == 'function'` soft-dependency guard (not a load-order
    assumption -- by the time a player can actually press one of these
    keys, every client_scripts file has already finished loading; the
    guard exists so this file also degrades safely if ever loaded standalone,
    e.g. under a future test harness, matching client/radial.lua's own
    stated convention for the identical guard).

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
    "how does a player find out this exists at all." CORRECTED (this pass,
    coder-backend): this section used to say this file's five new
    RegisterCommand names (k9bitehold, k9takedown, k9dragtoggle, k9sit,
    k9bark) were not yet added to that page, and that
    tests/commandreferenceregistry_spec.lua's own CLIENT_LUA_FILES list did
    not yet include 'keybinds.lua' -- both re-verified false by direct read.
    All five now have COMMAND_REFERENCE entries in html/tablet.js (each
    with its own usageKey/doesKey/needsKey/gate/defaultKeybind), and
    'keybinds.lua' is now present in
    tests/commandreferenceregistry_spec.lua's CLIENT_LUA_FILES list, so that
    drift guard does scan this file for RegisterCommand names.
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
        -- NOW A TOGGLE, not a one-shot (completeness QA finding, this pass).
        -- ReleaseTakedown() has existed and been correct for some time --
        -- ungated on the way out, matching ReleaseBiteHold/ReleaseDrag, with
        -- a server handler that likewise never re-checks access -- and was
        -- reachable from NOTHING. Its own doc comment said so ("NOT YET
        -- WIRED into client/radial.lua's ... or client/keybinds.lua's ...
        -- flagged to the owner of those two files"), and this is that file.
        --
        -- WHY IT MATTERS, not just tidiness: RequestTakedown() picks the
        -- NEAREST eligible ped, which client/combat.lua's own comment admits
        -- is "not necessarily the intended one". Pick the wrong person in a
        -- crowd and they were force-ragdolled and damage-immune for the full
        -- ragdollDurationMs with no way to undo it, and no route out at
        -- all for a solo K9 (a documented, supported way to play).
        --
        -- RELEASE BRANCH FIRST, and ungated: this is the STOP half, so it
        -- asks no access question of its own, exactly like the drag toggle
        -- below and the bite-hold toggle above. Only the request branch
        -- underneath carries a gate.
        if type(IsTakedownEngaged) == 'function' and IsTakedownEngaged() then
            if type(ReleaseTakedown) == 'function' then
                ReleaseTakedown()
            end
            return
        end

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
        -- TWO release branches, not one. IsDragEngaged() asks "am I the dog
        -- doing the dragging"; IsDragTargetEngaged() asks "am I the one
        -- being dragged". The server has always accepted a release from
        -- either party, but only the first question was ever asked here --
        -- so the person being dragged pressed this key, fell through to the
        -- request branch below, and got RequestDrag()'s "you are not allowed
        -- to use K9 controls" denial instead of being let go. See
        -- client/combat.lua's IsDragTargetEngaged() for the full writeup.
        --
        -- Checked BEFORE the holder branch on purpose: the two states are
        -- mutually exclusive in practice (the holder is never also the
        -- target), so the order is not load-bearing for correctness, but
        -- putting the person with the least agency first matches this
        -- resource's "getting out is never gated" posture everywhere else.
        if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then
            if type(ReleaseDrag) == 'function' then
                ReleaseDrag()
            end
            return
        end

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

-- ======================================================================
-- EXIT KENNEL -- trap-hunt fix, THIS PASS. See this file's own header
-- "ONE DELIBERATE EXCEPTION, ADDED THIS PASS" for why this is a confining
-- mechanic, not a logistics one, and therefore belongs here even though
-- every other kennel action deliberately does not.
--
-- REGISTERED UNCONDITIONALLY -- NO Config.Features.DeployableKennel WRAPPER,
-- unlike every other conditionally-registered entry in this file. This is
-- deliberate, not an oversight: GATE THE START OF A THING, NEVER THE STOP
-- (this codebase's own standing doctrine, restated by server/kennel.lua's
-- own requestExitKennel handler and client/kennel.lua's own "Exit Kennel"
-- ox_target canInteract). client/kennel.lua's ExitKennelRest() is itself
-- ALREADY safe to call with the feature off, or the flag toggled off
-- mid-session, or no kennel ever having existed at all -- it is a thin
-- wrapper over ReleaseKennelRest(), whose own `if not restState then
-- return end` guard makes it a genuine no-op for a player who was never
-- resting. Gating the KEYBIND itself behind the feature flag would recreate
-- exactly the trap this pass exists to close: an occupant who entered while
-- the feature was on, then had it toggled off from under them (or whose
-- own ox_target canInteract just failed to resolve for any other reason),
-- would lose this exit path for no correctness reason at all. Mirrors
-- k9sit above (also unconditional, for the analogous "no dedicated
-- Config.Features flag gates this specific action" reasoning, though the
-- underlying rationale here is stronger: exits must never be gated,
-- period).
-- ======================================================================
RegisterCommand('k9exitkennel', function()
    if type(ExitKennelRest) == 'function' then
        ExitKennelRest()
    end
end, false)

RegisterKeyMapping('k9exitkennel', locale('kennel.exit_keybind_label'), 'keyboard', 'O')
