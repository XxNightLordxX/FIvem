--[[
    qbx_k9unit/client/dangerwarn.lua

    DANGER WARN -- client half. See server/dangerwarn.lua's own header in
    full before this file for the complete design (why deliberate not
    automatic, exactly what information is sent and why it is not a
    wallhack, who hears what, and the rate limit). This file is
    deliberately thin: it exposes ONE self-initiated trigger and ONE
    audio-only listener, and trusts the server for every real decision.

    ======================================================================
    WHAT THIS FILE DOES NOT DO: no local threat detection, no automatic
    triggering of any kind, no game-state mutation, no task/control/
    animation native on any ped. `RequestDangerWarn` below only ever fires
    a server event; every actual outcome (whether a handler exists, is
    online, is permitted, and what they are told) is decided entirely by
    server/dangerwarn.lua.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Server events (RegisterNetEvent, client->server), THIS FILE triggers:
    - 'qbx_k9unit:server:requestDangerWarn' (warnType: string)
      [server/dangerwarn.lua]

    Client events (RegisterNetEvent, server->client), THIS FILE:
    - 'qbx_k9unit:client:dangerWarnAudible' (k9NetId: number, soundName:
      string) [server/dangerwarn.lua] -- audio only, see "SOURCE-ORIGIN
      GUARD" below.

    Commands / keybinds (THIS FILE):
    - 'qbx_k9unit:dangerWarnAlert' -- command + keybind. Calls
      RequestDangerWarn('Alert'), the lower-urgency default (mirrors
      client/defense.lua's ConfirmHandlerDownDefense choosing 'bite' as its
      single-keybind default for the identical reason: it is the option
      with no additional precondition, so a single keypress cannot silently
      fail for a reason the UI never explained).
    - 'qbx_k9unit:dangerWarnThreat' -- command ONLY, no keybind (menu-parity
      pass -- see this command's own RegisterCommand comment below for the
      full "every letter is taken" writeup). Calls
      RequestDangerWarn('Threat') -- the SAME function as Alert, same gate,
      different string literal. Also reachable via the
      'k9unit_dangerwarn' radial submenu, unchanged.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        RequestDangerWarn(warnType: string?) -- same "expose for a future
      radial entry, do not wire radial.lua myself" convention
      client/partnership.lua's and client/defense.lua's own headers already
      established for their own self-initiated triggers.
    - Calls CanShowK9UI()/DenyK9UIAccess() (client/main.lua) before acting
      -- display gate only, server is the real boundary, same posture as
      every other gated client action in this resource.
    - Calls PlayK9Sound(netId, soundName) (client/audio.lua) behind a
      `type(...) == 'function'` runtime existence guard -- soft dependency,
      this resource's established convention, in case
      Config.Features.BasicBarkSounds is off (that flag gates whether
      client/audio.lua defines PlayK9Sound at all).
    - No onResourceStop handler -- disclosed, not an oversight, same
      reasoning as client/defense.lua's own identical disclosure: this file
      applies no native side effect to any entity, ever, so there is
      nothing for a stop handler to restore.

    RADIAL/KEYBIND CONTRACT (client/radial.lua and client/keybinds.lua are
    NOT owned by this file -- this is the exact, stable hookup either one
    needs, so a future change to either side has one source of truth to
    check against):
      - `RequestDangerWarn(warnType)`: pass the string literal `'Alert'` or
        `'Threat'` (or any future Config.DangerWarn.Types key an operator
        adds -- this file does not validate the value at all, the server
        does). Any other value, including nil, falls back to `'Alert'`.
      - Return value: none. Every rejection path is reported to the K9's
        own client via the server's own NotifyPlayer call (a plain
        `ox_lib:notify`, not a custom event this file listens for) -- safe
        to call speculatively/optimistically from a radial menu or a
        second keybind at any time, exactly like
        client/defense.lua's ConfirmHandlerDownDefense.
      - A radial submenu offering BOTH `RequestDangerWarn('Alert')` and
        `RequestDangerWarn('Threat')` as two separate entries is the
        natural fit here -- client/defense.lua's own
        'k9unit_defense' submenu (Bite & Hold / Non-Lethal Takedown) is the
        precedent for exposing a keybind's default action plus its
        sibling(s) as one radial group.
    ======================================================================
]]

if not Config.Features.DangerWarn then return end

--- @param key string
--- @param fallback string
--- @return string
local function SafeLocale(key, fallback)
    local ok, text = pcall(locale, key)
    if ok and type(text) == 'string' and text ~= '' then return text end
    return fallback
end

--- Self-initiated trigger -- fires the server request directly; the server
--- (server/dangerwarn.lua) makes every real decision (partner lookup,
--- permission, rate limit, wording) and reports the outcome back via its
--- own NotifyPlayer calls, not a return value or a second event this file
--- would need to listen for.
--- @param warnType string? -- 'Alert' | 'Threat' (or any operator-added
---   Config.DangerWarn.Types key); any other value, including nil, falls
---   back to 'Alert' -- see this file's header "RADIAL/KEYBIND CONTRACT".
function RequestDangerWarn(warnType)
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if type(warnType) ~= 'string' or warnType == '' then
        warnType = 'Alert'
    end

    TriggerServerEvent('qbx_k9unit:server:requestDangerWarn', warnType)
end

RegisterCommand('qbx_k9unit:dangerWarnAlert', function()
    RequestDangerWarn('Alert')
end, false)

RegisterKeyMapping('qbx_k9unit:dangerWarnAlert',
    SafeLocale('dangerwarn.keybind_label', 'K9: Danger Warning (Alert)'),
    'keyboard', (type(Config.DangerWarn) == 'table' and Config.DangerWarn.keybind) or 'N')

-- ======================================================================
-- CHAT COMMAND ONLY, DELIBERATELY NO KEYBIND -- Danger Warn "Threat"
-- (menu-parity pass). Its sibling "Alert" immediately above already has
-- both a command and a keybind -- "Threat" had neither, even though
-- RequestDangerWarn('Threat') is the exact same function, with the exact
-- same gating, just a different string literal. The COMMAND half of that
-- asymmetry is what this closes.
--
-- THE KEYBIND HALF WAS ATTEMPTED AND REVERTED, THIS SAME PASS: a first
-- version of this block also shipped `RegisterKeyMapping(...,
-- 'keyboard', 'P')`. At the moment that was written, 'P' was verified free
-- by grepping every client/*.lua literal and config.lua default. It did
-- not stay free: Config.DangerWarn.keybind (Alert's own default) was
-- independently changed from 'N' to 'P' later in this same session --
-- 'N' collided with client/pursuitsprint.lua's own hardcoded default,
-- a real bug tests/keybindcollisions_spec.lua (new, this session) was
-- written specifically to catch, and that fix landed on 'P' without this
-- file's own addition having happened yet. Net result, caught by that same
-- new test: Alert and Threat would have shared one default key, so a
-- single keypress would have fired BOTH danger-warn types at once --
-- exactly the "one press, two actions the player never asked for" failure
-- that guard exists to prevent, not a cosmetic clash.
--
-- Re-checked properly this time (config.lua's own DangerWarn header now
-- lists every taken letter): every single-letter key this resource's own
-- convention would reach for is already a shipped default somewhere in
-- this codebase, and the remaining unused letters (A, D, E, F, Q, R, S, W)
-- are core GTA movement/interact/vehicle/cover/reload controls this
-- resource's own convention says never to bind over. There is no letter
-- left to give this a keybind without either colliding with something
-- real or fighting the base game.
--
-- DECISION: skip the keybind. The gap this pass was actually asked to
-- close is DISCOVERABILITY (Alert had two entry points and Threat had
-- zero) -- a chat command already fixes that in full; Threat also remains
-- reachable via the 'k9unit_dangerwarn' radial submenu, unchanged. A
-- keybind is a convenience on top of an already-reachable action, and
-- this resource's own stated direction is LESS clutter, not a forced
-- keybind purchased at the cost of a real double-fire bug or a
-- non-letter/function-key default with no precedent anywhere else in this
-- resource. If a future pass frees a letter (a feature removed, a keybind
-- retired), Threat is the natural candidate to receive it.
-- ======================================================================
RegisterCommand('qbx_k9unit:dangerWarnThreat', function()
    RequestDangerWarn('Threat')
end, false)

--- Audio-only bystander/handler-in-range bark relay -- see
--- server/dangerwarn.lua's header "WHO HEARS WHAT". Applies nothing beyond
--- a locally-played sound: no notification, no state, no native applied to
--- any ped.
--- @param k9NetId number
--- @param soundName string
RegisterNetEvent('qbx_k9unit:client:dangerWarnAudible', function(k9NetId, soundName)
    -- SOURCE-ORIGIN GUARD -- same convention and confidence grading as
    -- client/defense.lua's own identical guard on
    -- 'qbx_k9unit:client:handlerDownDefenseTrigger': without this, a
    -- modified client could locally fire this event with an arbitrary
    -- netId/soundName to make its OWN client attempt to play a sound at an
    -- arbitrary streamed-in entity -- a purely local, purely cosmetic
    -- effect (this event applies no state, no notification, and reaches no
    -- other player), but closing the same "arbitrary event, zero server
    -- contact" gap this resource's convention now expects for every
    -- client:* handler regardless of how low the payoff is.
    if source ~= 65535 then return end
    if type(k9NetId) ~= 'number' then return end
    if type(soundName) ~= 'string' or soundName == '' then return end
    if type(PlayK9Sound) ~= 'function' then return end -- BasicBarkSounds off / client/audio.lua absent -- silent no-op, matches every other soft dependency on this global

    PlayK9Sound(k9NetId, soundName)
end)
