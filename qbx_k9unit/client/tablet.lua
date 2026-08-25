--[[
    qbx_k9unit/client/tablet.lua

    Config.Features.CommandTablet (config.lua). Client-side bridge for the
    K9 Command Tablet — the in-game NUI the owner asked for ("stuff also
    in a menu or tablet control"), SCOPE-EXPANDED mid-pass (owner's own
    words, relayed by the coordinator): "I want high command in the
    tablet to have full control over pretty much all the features and sub
    features of this script to enable disable per k9 or handler, have
    certifying stuff with all command abilitys able to be in there, and
    every k9 or handler can open the tablet and see whatever they been
    certified in and use whatever they been certified in if they do not
    want to use hot keys or commands."

    Three things this file now does, in order of how much of it they take up:
      PART 0 — open/close + NUI focus lifecycle (the original brief).
      PART 1 — VIEW: everyone gets their own record (certs/XP/grants/
        per-action availability); high command additionally gets the
        full roster (server/permissions.lua's tabletListRoster).
      PART 2 — ACTION ROUTER (the scope expansion): every ability this
        resource has a keybind/command/radial item for can ALSO be
        triggered from the tablet, and every admin command (certify/
        decertify/audit/givexp) can be run from it too. See SECTION 2/3
        below for exactly how, and READ THE RIGHT-VS-WRONG NOTE first —
        it is the single most important design constraint in this file.

    ======================================================================
    RIGHT-VS-WRONG (coordinator's own framing, verbatim, because this
    resource has already been bitten by the wrong one): "route each
    tablet action to the SAME client function the keybind and command
    already call. One code path, one set of guards, one place to fix a
    bug... find the existing entry points, call them, and if one is a
    local rather than a global, report exactly which file and function
    needs a seam opened rather than duplicating its body." The named
    precedent is real: ScratchAtDoor/NudgeDoor checked vehicle state in
    ox_target's canInteract but not inside the function itself, so one
    entry point was guarded and the other was not.

    Applied here: SECTION 2's ABILITY_ACTIONS table below calls the exact
    same resource-global every keybind/radial item already calls
    (K9Sit(), RequestBiteHold(), ToggleThermalVision(), ...), and mirrors
    client/radial.lua's own per-item gate CHOICE for that same action
    byte-for-byte (see each entry's own comment citing the radial.lua
    line it mirrors) rather than inventing a new, possibly-divergent
    check. Two actions (Leash toggle, Partner toggle) need a nearest-
    candidate lookup that today lives as a `local` inside client/radial.lua
    (FindNearestLeashCandidate/FindNearestPartnerCandidate) — NOT
    duplicated here; see SECTION 2's own note for the exact seam requested
    from radial.lua's owner instead, and the soft-dependency guard this
    file uses in the meantime.
    SECTION 3 (admin commands) applies the identical principle a different
    way: rather than re-implementing certify/decertify/audit/givexp's
    server-side logic a second time behind a new callback, it calls
    `ExecuteCommand` — the same native the chat box itself uses to submit
    a typed command — so a tablet-triggered `/k9certify 5` is, from the
    server's perspective, LITERALLY THE SAME EVENT as the officer typing
    it. There is no second code path to drift.
    ======================================================================

    ======================================================================
    SECURITY NOTE — UNCHANGED BY THE SCOPE EXPANSION, AND MORE IMPORTANT
    NOW THAN BEFORE. Restated from config.lua's Config.CommandTablet
    header: THE TABLET IS A VIEW. IT DECIDES NOTHING. Every action it
    offers — viewing a record, granting a permission, triggering an
    ability, running an admin command — is re-authorized server-side from
    the caller's own live job/grants/blocks, exactly as if they had typed
    the command or pressed the keybind. A modified client can send any NUI
    callback with any payload, so nothing in this file may ever be the
    thing that actually authorizes an action. With the tablet now able to
    TRIGGER abilities and run admin commands, this is the line between a
    UI and an exploit surface: every dispatch table entry in SECTION 2/3
    below still routes through a real, already-server-validated entry
    point — this file adds no new authority, only a new way to reach
    authority that already existed.

    Per-person feature grants/BLOCKS (config.lua's new Config.FeatureControl,
    resolution: (1) Config.Features.<Name> false -> deny always; (2) an
    explicit block -> deny; (3) listed in RequireGrant -> needs a grant;
    (4) otherwise allow) are resolved ENTIRELY server-side, inside whatever
    already validates each action today (server/permissions.lua and each
    feature's own server file) — this file has no local copy of that
    resolution and does not need one. `Config.FeatureControl.
    allowActionsFromTablet` is the one FeatureControl field this file DOES
    read directly (see SECTION 2/3) — it is a pure UX toggle, not an
    authorization boundary: turning it off only removes the TABLET's
    trigger buttons, it cannot and does not change what a keybind/command/
    radial item can still do, and a modified client bypassing it would
    just be calling the same already-exposed global directly instead.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT — PROPOSED BY THIS FILE, pending confirmation
    from coder-backend's server/permissions.lua (messaged directly — see
    this pass's own report). Every call funnels through AwaitServerCallback()
    (pcall-wrapped, fails closed — see client/main.lua's HasK9Access() doc
    comment for the `lib.callback.await` throws-not-nil citation this file
    relies on verbatim) and this file never interprets the deep shape of
    `record`/`rows`/`permissions` — opaque passthrough to/from the NUI.

    1. 'qbx_k9unit:server:tabletGetMyRecord' () -> {
           ok: boolean, reason: string?,  -- 'not_authorized'|'missing_item'|'feature_disabled'|'timeout'
           record: {                       -- opaque; forwarded as-is
             citizenid, name, job, jobLabel, certified, isHighCommand,
             xp, xpTierLabel, grants: string[],
             actions: { [actionKey: string] = { available: boolean, reason: string? } },
               -- reason present only when available=false, one of
               -- 'not_certified' | 'blocked' | 'feature_disabled' | 'no_grant'
               -- so the NUI can show WHY, per the coordinator's own
               -- "not certified, blocked, and globally disabled are three
               -- different situations" requirement — computed entirely
               -- server-side (Config.Features/Config.FeatureControl/the
               -- caller's own certs+grants+blocks), never by this file.
           },
       }
       Gated server-side on Config.FeatureControl.everyoneCanViewOwnRecord
       and Config.CommandTablet.requiredItem (server-side ox_inventory
       count — server/wellbeing.lua's `exports.ox_inventory:GetItemCount`
       is this resource's own established pattern for that exact check).
       This file adds NO client-side item-count check of its own (no
       verified ox_inventory CLIENT export for this exists anywhere else
       in this codebase to reuse) — the server's `reason` is authoritative.
       THE sole callback OpenTablet() awaits — see PART 1.
    2. 'qbx_k9unit:server:tabletListRoster' () -> { ok, reason?, rows: table[]? }
       HIGH-COMMAND / CONTROL-CONSOLE AUDIENCE ONLY — the server decides
       who qualifies, not this file. Fetched lazily by the NUI (via
       'tablet:getRoster' below) only when/if the console view is opened,
       never as part of OpenTablet() itself.
    3. 'qbx_k9unit:server:tabletGrantPermission' (targetCitizenid: string,
       permissionKey: string) -> { ok, reason? }
    4. 'qbx_k9unit:server:tabletRevokePermission' (same shape)
       `permissionKey` is an OPAQUE string this file never parses or
       validates the format of, matching config.lua's own three key
       namespaces verbatim: the four capabilities ('k9.access', 'k9.certify',
       'k9.audit', 'k9.givexp'), a per-person feature grant ('feature.<Name>'),
       or a per-person BLOCK ('block.<Name>') — config.lua's own header
       confirms grants and blocks share the same table/same revoke
       semantics, so revokePermission on a 'block.<Name>' key is how a
       block is LIFTED; no separate block/unblock callback is requested.

    Deliberately NOT requested: "list permission definitions" as a
    callback — Config.Permissions is shared_scripts, static, and already
    identical on both sides; this file reads it directly (see PART 1).
    ======================================================================

    ======================================================================
    NUI CONTRACT — PROPOSED BY THIS FILE, pending confirmation from
    coder-ui's html/tablet.* (messaged directly — see this pass's report).

    JS -> Lua (RegisterNUICallback):
      'tablet:close' (data: {}) -> cb({ ok = true })
      'tablet:getMyRecord' (data: {}) -> cb(<tabletGetMyRecord result>)
          Re-fetch (e.g. after triggering an action, to refresh which
          actions now show available).
      'tablet:getRoster' (data: {}) -> cb(<tabletListRoster result>)
          Console-view-only fetch — see contract item 2 above.
      'tablet:grantPermission' / 'tablet:revokePermission'
          (data: { citizenid: string, permissionKey: string }) -> cb({ ok, reason })
      'tablet:triggerAction' (data: { action: string, args: table? })
          -> cb({ ok: boolean, reason: string? })
          SECTION 2. `ok` means "dispatched," never "the server approved
          it" — most underlying globals are fire-and-forget with their own
          notify. `reason`, when ok=false: 'actions_disabled' (Config.
          FeatureControl.allowActionsFromTablet is off), 'unknown_action',
          or 'not_available' (the local pre-check failed — the same
          DenyK9UIAccess()/no-candidate notify a radial click would have
          produced already fired).
      'tablet:runCommand' (data: { command: string, args: string[]? })
          -> cb({ ok: boolean, reason: string? })
          SECTION 3, high-command control console only (the underlying
          command's own authorization check is what actually enforces
          that — this file's own allowlist is a "don't submit garbage,"
          not an authorization, gate). Same `ok`/`reason` semantics as
          triggerAction.

    Lua -> JS (SendNUIMessage):
      { action = 'tablet:open', data = {
          permissions = Config.Permissions,             -- shared config
          barkTypes = Config.Features.AdvancedBarkRadial and Config.AdvancedBarkRadial or nil,
          maxRosterRows = Config.CommandTablet.maxRosterRows,
          record = <opaque, from tabletGetMyRecord>,     -- includes whatever
              -- field (e.g. isHighCommand) the NUI needs to decide whether
              -- to show the control-console view at all — this file does
              -- not read or branch on that field itself.
      } }
      { action = 'tablet:close', data = {} }
    ======================================================================

    ======================================================================
    FOCUS/CLOSE DISCIPLINE — UNCHANGED BY THE SCOPE EXPANSION, restated in
    full because it is this task's own named top concern. First focus-
    taking surface in this resource (html/app.js's own header states it
    has never called SetNuiFocus; a grep of this whole resource for
    SetNuiFocus before this file returns zero matches). A stuck focus
    locks a player out of their own character with no way back except a
    reconnect. Four independent close paths, ALL funneling through the one
    CloseTablet() function (the only place SetNuiFocus(false, false) is
    ever called), so "is focus actually released" can never drift between
    call sites:
      1. JS calls 'tablet:close'.
      2. ESC (INPUT_FRONTEND_PAUSE, control 200) — handled ENTIRELY
         Lua-side, never routed through the NUI (a silent/errored page
         must not be the only thing standing between a player and their
         own input). See EnsureTabletWatchThreadRunning().
      3. Own death — same thread as ESC. FiveM's respawn REUSES the same
         ped handle (this resource has already been bitten by exactly this
         bug class once — a K9 that died mid-vehicle-load respawned
         frozen/invisible/still-attached, per client/vehicle.lua's header),
         so a focus grab is exactly the kind of per-ped state that would
         otherwise survive a respawn with nothing to release it.
      4. onResourceStop (this resource only) — NUI focus is engine
         input-routing state, not torn down implicitly just because this
         resource's ui_page browser context goes away.
    CloseTablet() itself has NO access/state gate beyond "is it even
    open" — the "no unbounded trap" rule this codebase applies to every
    release/termination path (see client/recall.lua's header): losing K9
    access, certification, or department mid-session must never strand a
    player unable to close their own tablet.
    ======================================================================

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - Calls client/main.lua's HasK9Access()/CanShowK9UI()/DenyK9UIAccess()
      — per-action, mirroring client/radial.lua's own gate choice for that
      SAME action (see SECTION 2). No single blanket gate for the whole
      file: unlike this file's pre-scope-expansion draft, OPENING the
      tablet is no longer gated by a local check at all — see PART 1 for
      why (everyone-can-view-their-own-record is now a real requirement,
      and "not certified" must be a VISIBLE reason inside an opened
      tablet, not a reason it never opens).
    - Never inspects the deep shape of `record`/`rows`/Config.Permissions
      beyond what's documented above — forwarded to the NUI opaque, so a
      shape change on either end needs no corresponding change here.
    - Does not edit client/radial.lua (live owner) — SECTION 2 documents
      the exact seam requested instead (FindNearestLeashCandidate/
      FindNearestPartnerCandidate becoming resource-globals) and the
      soft-dependency guard used until it lands.
    - Exposes ONE resource-global: OpenTablet() -> nil, for a future
      client/radial.lua entry (this pass's report names the exact item).
      CloseTablet() is intentionally NOT exposed globally — every real
      close path already lives inside this file.
    ======================================================================

    GATING — "gate at registration, not just inside the handler": the
    single `if not Config.Features.CommandTablet then return end` below
    means the command, every RegisterNUICallback, and OpenTablet()/
    CloseTablet() do not exist at all while the flag is off.
]]

if not Config.Features.CommandTablet then return end

-- ----------------------------------------------------------------------
-- PART 0 — open/close + focus lifecycle
-- ----------------------------------------------------------------------

--- Reason -> player-facing OPEN-failure message (shown via lib.notify,
--- since the NUI is never shown for this failure). Mirrors
--- client/inventory.lua's K9_INVENTORY_REASON_MESSAGES non-collapsing
--- shape. Every OTHER `reason` this file forwards (grant/revoke/
--- triggerAction/runCommand failures, and per-action `actions[key].reason`
--- inside an already-open tablet) is handled entirely by the NUI from the
--- raw string — coder-ui owns that copy, per this codebase's "route
--- player-facing text through locale keys" convention applied to its own
--- surface.
local TABLET_OPEN_REASON_MESSAGES = {
    not_authorized   = locale('tablet.reason_not_authorized'),
    missing_item     = locale('tablet.reason_missing_item'),
    feature_disabled = locale('tablet.reason_feature_disabled'),
}

local tabletOpen = false     -- single source of truth: is the NUI currently visible/focused
local tabletOpening = false  -- in-flight guard — see OpenTablet()'s own comment

--- Pcall-wrapped, fail-closed wrapper around every server callback this
--- file awaits. `lib.callback.await` THROWS (never returns nil) on a
--- timeout or an unregistered callback — see client/main.lua's
--- HasK9Access() doc comment for the exact ox_lib/FiveM source citation;
--- duplicated here rather than shared, matching this codebase's per-file
--- convention for this exact guard (client/partnership.lua/wellbeing.lua/
--- medkit.lua/tracking.lua/inventory.lua each keep their own copy too).
--- Every caller below gets back a plain table either way, never a
--- propagating error that could abort a RegisterNUICallback mid-way and
--- leave its `cb` uninvoked (client/hud.lua: "an uninvoked NUI callback
--- hangs the frontend's fetch promise forever" — doubly true here, since
--- an uninvoked cb during OpenTablet() would also leave `tabletOpening`
--- stuck true forever with nothing left to reset it).
--- @param name string
--- @return table result -- always a table
local function AwaitServerCallback(name, ...)
    local ok, result = pcall(lib.callback.await, name, false, ...)
    if not ok or type(result) ~= 'table' then
        return { ok = false, reason = 'timeout' }
    end
    return result
end

--- The ONE place this file ever calls SetNuiFocus(false, false) — see
--- FOCUS/CLOSE DISCIPLINE. No access/state check beyond "is it open."
function CloseTablet()
    if not tabletOpen then return end

    tabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'tablet:close', data = {} })
end

--- ESC-close + own-death watch — one thread for both, mirrors
--- client/vision.lua's visionMaintenanceThreadRunning lifecycle guard
--- exactly: started only from OpenTablet(), a no-op while already
--- running, self-resetting the instant `tabletOpen` goes false.
---
--- Wait(0) is correct here, not a "no tight loop" violation:
--- DisableControlAction must be re-asserted every frame to suppress the
--- native pause menu (it does not persist across frames on its own — the
--- standard reason every FiveM ESC-closeable NUI menu reasserts it every
--- tick), and this thread's lifetime is already bounded to "while the
--- tablet is open," not a perpetual idle poll.
local tabletWatchThreadRunning = false
local function EnsureTabletWatchThreadRunning()
    if tabletWatchThreadRunning then return end
    tabletWatchThreadRunning = true

    CreateThread(function()
        while tabletOpen do
            -- INPUT_FRONTEND_PAUSE (200) — standard FiveM ESC-closeable-NUI
            -- idiom: DisableControlAction suppresses the native pause menu;
            -- IsDisabledControlJustPressed (the DISABLED variant — plain
            -- IsControlJustPressed stops reporting a press once a control
            -- is disabled) is what detects the keypress in that same frame.
            DisableControlAction(0, 200, true)

            if IsDisabledControlJustPressed(0, 200) then
                CloseTablet()
            elseif IsEntityDead(PlayerPedId()) then
                -- Same IsEntityDead(PlayerPedId()) polling shape already
                -- established by client/vision.lua/screenfx.lua/
                -- propattachment.lua/fetch.lua/vehicle.lua for "clean up
                -- per-ped state on death, since respawn reuses the ped
                -- handle" — applied here to a focus grab.
                CloseTablet()
            end

            Wait(0)
        end

        tabletWatchThreadRunning = false
    end)
end

--- Opens the K9 Command Tablet for the LOCAL player. Exposed globally for
--- a future client/radial.lua entry (this pass's report names it).
---
--- NO local access pre-check before the round trip (a deliberate change
--- from this file's pre-scope-expansion draft): "every k9 or handler can
--- open the tablet and see whatever they been certified in" means a
--- handler who is NOT (yet) certified must still be able to OPEN it and
--- see that — gating the open itself on HasK9Access()/CanShowK9UI() would
--- lock out exactly the player this feature is now meant to serve. The
--- single 'qbx_k9unit:server:tabletGetMyRecord' round trip below is the
--- entire gate: it independently re-checks Config.FeatureControl.
--- everyoneCanViewOwnRecord, Config.CommandTablet.requiredItem, and
--- whether the caller is even in a configured department at all
--- (server-side, per that callback's own EVENT/CALLBACK CONTRACT entry).
--- @return nil
function OpenTablet()
    if tabletOpen or tabletOpening then return end

    -- IN-FLIGHT GUARD, separate from `tabletOpen`: this function yields on
    -- a server round trip BEFORE tabletOpen is ever set true. Without this,
    -- mashing the open command/radial item twice before the first request
    -- resolves would start two concurrent awaits, each independently
    -- trying to open a second time once they land — the same race
    -- client/tracking.lua's own `startInFlight` guard closes for an
    -- unrelated feature.
    tabletOpening = true
    local result = AwaitServerCallback('qbx_k9unit:server:tabletGetMyRecord')
    tabletOpening = false

    -- DEATH-DURING-AWAIT GUARD: the round trip yields for a real network
    -- round trip, during which the player can die. Never grab focus for a
    -- ped that is already dead when the response lands.
    if IsEntityDead(PlayerPedId()) then return end

    if result.ok ~= true then
        lib.notify({
            title = locale('common.notify_title'),
            description = TABLET_OPEN_REASON_MESSAGES[result.reason] or locale('tablet.open_failed_generic'),
            type = 'error',
        })
        return
    end

    tabletOpen = true
    SendNUIMessage({
        action = 'tablet:open',
        data = {
            -- Shared config, not a round trip — see EVENT/CALLBACK CONTRACT.
            permissions = Config.Permissions,
            barkTypes = (Config.Features.AdvancedBarkRadial and Config.AdvancedBarkRadial) or nil,
            maxRosterRows = Config.CommandTablet.maxRosterRows,
            -- Opaque passthrough — see FILE-TO-FILE CONTRACT.
            record = result.record,
        },
    })
    SetNuiFocus(true, true)
    EnsureTabletWatchThreadRunning()
end

-- ----------------------------------------------------------------------
-- PART 1 — VIEW callbacks (getMyRecord / getRoster / grant / revoke)
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:close', function(_, cb)
    CloseTablet()
    cb({ ok = true })
end)

RegisterNUICallback('tablet:getMyRecord', function(_, cb)
    cb(AwaitServerCallback('qbx_k9unit:server:tabletGetMyRecord'))
end)

RegisterNUICallback('tablet:getRoster', function(_, cb)
    cb(AwaitServerCallback('qbx_k9unit:server:tabletListRoster'))
end)

--- Shared shape guard for the two mutation callbacks below — a "don't
--- bother the server with an obviously malformed payload" check, never an
--- authorization decision (see SECURITY NOTE).
--- @param data any
--- @return boolean
local function IsValidGrantPayload(data)
    return type(data) == 'table'
        and type(data.citizenid) == 'string' and data.citizenid ~= ''
        and type(data.permissionKey) == 'string' and data.permissionKey ~= ''
end

RegisterNUICallback('tablet:grantPermission', function(data, cb)
    if not IsValidGrantPayload(data) then
        cb({ ok = false, reason = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.citizenid, data.permissionKey))
end)

RegisterNUICallback('tablet:revokePermission', function(data, cb)
    if not IsValidGrantPayload(data) then
        cb({ ok = false, reason = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.citizenid, data.permissionKey))
end)

-- ----------------------------------------------------------------------
-- SECTION 2 — ABILITY ACTION ROUTER. Every entry below calls the EXACT
-- SAME resource-global client/radial.lua's own onSelect for that action
-- calls, and mirrors that SAME onSelect's gate choice line-for-line (cited
-- per entry) — see this file's header RIGHT-VS-WRONG note for why that
-- precision matters. `run(args)` returns `true` on dispatch, or
-- `false, 'not_available'` when a local pre-check declined (the user-
-- facing DenyK9UIAccess()/no-candidate notify, if any, has already fired
-- by the time it returns false — same as a real radial click).
--
-- SEAM REQUESTED, NOT DUPLICATED (leashToggle/partnerUp): client/radial.lua's
-- FindNearestLeashCandidate()/FindNearestPartnerCandidate() are today
-- `local function`s, unreachable from here. Reported to radial.lua's
-- owner: drop the `local` on both (pure, side-effect-free helpers; no
-- other change needed) so both this file and radial.lua call the SAME
-- function instead of this file re-deriving its own nearest-candidate
-- search — a second implementation is exactly the fork this section
-- exists to avoid. Until that lands, both actions below soft-guard on
-- `type(FindNearestLeashCandidate) == 'function'` (this codebase's
-- established convention) and report 'not_available' rather than error.
-- ----------------------------------------------------------------------
local ABILITY_ACTIONS = {
    -- radial.lua 'k9_sit'.
    sit = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(K9Sit) == 'function' then K9Sit() end
            return true
        end,
    },
    -- radial.lua 'k9_bark' / the AdvancedBarkRadial submenu. `args.barkType`
    -- optional; only honored if it matches a configured
    -- Config.AdvancedBarkRadial variant, else falls back to the Phase 1
    -- literal 'bark' — same fallback client/main.lua's playBark handler
    -- already applies for an unrecognized barkType.
    bark = {
        run = function(args)
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            local barkType = 'bark'
            if Config.Features.AdvancedBarkRadial and type(args) == 'table' and type(args.barkType) == 'string' then
                for _, variant in ipairs(Config.AdvancedBarkRadial) do
                    if variant.barkType == args.barkType then
                        barkType = args.barkType
                        break
                    end
                end
            end
            TriggerServerEvent('qbx_k9unit:server:relayBark', barkType)
            return true
        end,
    },
    -- radial.lua 'k9_leash': Detach is UNGATED (termination); Attach is
    -- gated + needs a nearest candidate — see SEAM note above.
    leashToggle = {
        run = function()
            if type(IsLeashed) == 'function' and IsLeashed() then
                if type(DetachLeash) == 'function' then DetachLeash() end
                return true
            end
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(FindNearestLeashCandidate) ~= 'function' then return false, 'not_available' end
            local candidateServerId = FindNearestLeashCandidate()
            if not candidateServerId then
                lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_leash_candidate'), type = 'error' })
                return false, 'not_available'
            end
            if type(RequestLeashAttach) == 'function' then RequestLeashAttach(candidateServerId) end
            return true
        end,
    },
    -- radial.lua 'k9_vehicle': BOTH directions gated (unlike leash detach).
    vehicleToggle = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
                if type(ExitK9Vehicle) == 'function' then ExitK9Vehicle() end
            elseif type(EnterNearestK9Vehicle) == 'function' then
                EnterNearestK9Vehicle()
            end
            return true
        end,
    },
    -- radial.lua 'k9_track_scent'/'k9_track_blood'/'k9_track_gunpowder':
    -- each stops itself if it's the currently-active type, else starts.
    trackScent = {
        run = function()
            if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'scent' then
                if type(StopTracking) == 'function' then StopTracking() end
                return true
            end
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(StartScentTrack) == 'function' then StartScentTrack() end
            return true
        end,
    },
    trackBlood = {
        run = function()
            if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'blood' then
                if type(StopTracking) == 'function' then StopTracking() end
                return true
            end
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(StartBloodTrack) == 'function' then StartBloodTrack() end
            return true
        end,
    },
    trackGunpowder = {
        run = function()
            if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'gunpowder' then
                if type(StopTracking) == 'function' then StopTracking() end
                return true
            end
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(StartGunpowderTrack) == 'function' then StartGunpowderTrack() end
            return true
        end,
    },
    -- Vision toggles: NOT in radial.lua at all (§11.3: keybind-only by
    -- design). Both Toggle*Vision() functions already gate + notify
    -- internally (IsOwnModelK9() only, per client/vision.lua's own
    -- RESOLVED ACCESS-GATING DECISION) — call straight through, no local
    -- pre-check to duplicate.
    thermalVision = {
        run = function()
            if type(ToggleThermalVision) == 'function' then ToggleThermalVision(); return true end
            return false, 'not_available'
        end,
    },
    nightVision = {
        run = function()
            if type(ToggleNightVision) == 'function' then ToggleNightVision(); return true end
            return false, 'not_available'
        end,
    },
    -- radial.lua 'k9_bite_hold': Release UNGATED, Attempt gated.
    biteHoldToggle = {
        run = function()
            if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
                if type(ReleaseBiteHold) == 'function' then ReleaseBiteHold() end
                return true
            end
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestBiteHold) == 'function' then RequestBiteHold() end
            return true
        end,
    },
    -- radial.lua 'k9_takedown': one-shot, gated, no release counterpart.
    takedown = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestTakedown) == 'function' then RequestTakedown() end
            return true
        end,
    },
    -- radial.lua 'k9_drag': Release UNGATED, Attempt gated.
    dragToggle = {
        run = function()
            if type(IsDragEngaged) == 'function' and IsDragEngaged() then
                if type(ReleaseDrag) == 'function' then ReleaseDrag() end
                return true
            end
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestDrag) == 'function' then RequestDrag() end
            return true
        end,
    },
    -- radial.lua 'k9_break_partnership': UNGATED (termination), unconditional.
    breakPartnership = {
        run = function()
            if type(BreakPartnership) == 'function' then BreakPartnership() end
            return true
        end,
    },
    -- radial.lua 'k9_partner_up': gated + needs a nearest candidate — see
    -- SEAM note above.
    partnerUp = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(FindNearestPartnerCandidate) ~= 'function' then return false, 'not_available' end
            local candidateServerId = FindNearestPartnerCandidate()
            if not candidateServerId then
                lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_partner_candidate'), type = 'error' })
                return false, 'not_available'
            end
            if type(RequestPartnerUp) == 'function' then RequestPartnerUp(candidateServerId) end
            return true
        end,
    },
    -- radial.lua 'k9_recall': UNGATED (termination), unconditional.
    recall = {
        run = function()
            if type(RequestRecall) == 'function' then RequestRecall() end
            return true
        end,
    },
    -- radial.lua 'k9_defense_bite'/'k9_defense_takedown': both gated
    -- (initiation), even though ConfirmHandlerDownDefense() self-gates too
    -- — matching radial's own redundant "check here too" posture.
    defenseBite = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(ConfirmHandlerDownDefense) == 'function' then ConfirmHandlerDownDefense('bite') end
            return true
        end,
    },
    defenseTakedown = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(ConfirmHandlerDownDefense) == 'function' then ConfirmHandlerDownDefense('takedown') end
            return true
        end,
    },
    -- radial.lua 'k9_fetch_throw': Release branch UNGATED; Throw branch
    -- gated on HasK9Access() ONLY (not CanShowK9UI()) — a human-handler
    -- action per RequestThrowFetchBall()'s own doc comment, verbatim.
    fetchThrowToggle = {
        run = function()
            if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then
                if type(ReleaseFetchBall) == 'function' then ReleaseFetchBall() end
                return true
            end
            if not HasK9Access() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestThrowFetchBall) == 'function' then RequestThrowFetchBall() end
            return true
        end,
    },
    -- radial.lua 'k9_fetch_recall': UNGATED, unconditional, no type() guard
    -- even (matches radial's own code exactly).
    fetchRecall = {
        run = function()
            if type(RequestRecallFetchBall) == 'function' then RequestRecallFetchBall() end
            return true
        end,
    },
    -- radial.lua 'k9_prop_attachment': gated (redundant with the callee, kept for consistency).
    propAttachToggle = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestToggleK9PropAttachment) == 'function' then RequestToggleK9PropAttachment() end
            return true
        end,
    },
    -- radial.lua 'k9_deploy_kennel': gated (redundant with the callee, kept for consistency).
    deployKennel = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestDeployKennel) == 'function' then RequestDeployKennel() end
            return true
        end,
    },
    -- radial.lua 'k9_open_inventory': gated (redundant with the callee, kept for consistency).
    openInventory = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestOpenOwnK9Inventory) == 'function' then RequestOpenOwnK9Inventory() end
            return true
        end,
    },
    -- radial.lua 'k9_treat_nearest': gated (redundant with the callee, kept for consistency).
    treatNearest = {
        run = function()
            if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
            if type(RequestTreatNearestK9) == 'function' then RequestTreatNearestK9() end
            return true
        end,
    },
    -- NOT YET in client/radial.lua (client/wellbeing.lua's own header:
    -- "a future radial menu entry should call this"). RequestK9CalmDown()
    -- is FULLY self-gating (Config.Features.FearStressSystem +
    -- CanShowK9UI()/DenyK9UIAccess() internally) — call straight through.
    calmDown = {
        run = function()
            if type(RequestK9CalmDown) == 'function' then RequestK9CalmDown() end
            return true
        end,
    },
}

RegisterNUICallback('tablet:triggerAction', function(data, cb)
    -- Config.FeatureControl.allowActionsFromTablet — pure UX toggle, not
    -- an authorization boundary. See SECURITY NOTE.
    if not (Config.FeatureControl and Config.FeatureControl.allowActionsFromTablet == true) then
        cb({ ok = false, reason = 'actions_disabled' })
        return
    end

    if type(data) ~= 'table' or type(data.action) ~= 'string' then
        cb({ ok = false, reason = 'invalid_args' })
        return
    end

    local entry = ABILITY_ACTIONS[data.action]
    if not entry then
        cb({ ok = false, reason = 'unknown_action' })
        return
    end

    local ok, reason = entry.run(data.args)
    cb({ ok = ok == true, reason = (ok ~= true) and (reason or 'not_available') or nil })
end)

-- ----------------------------------------------------------------------
-- SECTION 3 — ADMIN COMMAND BRIDGE. "Certifying stuff with all command
-- abilitys" — rather than a new callback per command (a second code path
-- for logic server/certifications.lua and server/admin.lua already own),
-- this submits the EXACT SAME command string the chat box would, via
-- `ExecuteCommand` (verified this pass: ext/native-decls/ExecuteCommand.md
-- returns HTTP 200, `apiset: shared` — client-callable, submits a command
-- exactly as if typed). The command's own RegisterCommand handler is the
-- one and only place that authorizes anything here (IsAuthorizedAdmin /
-- IsEligibleCertifier / IsHighCommand) — this bridge adds no authority.
--
-- ALLOWLISTED BY NAME, not "run anything": server/highcommand.lua's own
-- header already rejected a generic passthrough for the identical reason
-- ("a generic passthrough... would turn a promotion into full server
-- control"). This file applies that same discipline to itself — only
-- this resource's own already-registered, non-ACE-restricted commands
-- (every RegisterCommand below passes `restricted = false`, confirmed by
-- reading each file) are reachable, and every arg token is checked for
-- whitespace/control characters before being concatenated into a command
-- string, so a malformed NUI payload can't inject a second command or
-- shift argument positions.
-- ----------------------------------------------------------------------
local ALLOWLISTED_TABLET_COMMANDS = {
    k9certify          = true, -- server/certifications.lua
    k9decertify        = true,
    k9decertifyoffline = true,
    k9givexp           = true, -- server/highcommand.lua
    k9auditcert        = true, -- server/admin.lua
    k9auditpartner     = true,
    k9auditsearch      = true,
    k9auditxp          = true,
    k9auditdept        = true,
}
local MAX_TABLET_COMMAND_ARGS = 4 -- k9auditsearch's widest shape ('officer'|'person'|'plate'|'recent', value, limit) plus headroom

--- @param token any
--- @return boolean
local function IsSafeCommandArgToken(token)
    token = tostring(token)
    return token ~= '' and #token <= 64 and not token:find('[%s;]')
end

RegisterNUICallback('tablet:runCommand', function(data, cb)
    if not (Config.FeatureControl and Config.FeatureControl.allowActionsFromTablet == true) then
        cb({ ok = false, reason = 'actions_disabled' })
        return
    end

    if type(data) ~= 'table' or type(data.command) ~= 'string' or not ALLOWLISTED_TABLET_COMMANDS[data.command] then
        cb({ ok = false, reason = 'invalid_args' })
        return
    end

    local args = type(data.args) == 'table' and data.args or {}
    if #args > MAX_TABLET_COMMAND_ARGS then
        cb({ ok = false, reason = 'invalid_args' })
        return
    end

    local parts = { data.command }
    for i = 1, #args do
        if not IsSafeCommandArgToken(args[i]) then
            cb({ ok = false, reason = 'invalid_args' })
            return
        end
        parts[#parts + 1] = tostring(args[i])
    end

    -- Fire-and-forget, same as a player typing this command themselves —
    -- the command's OWN handler notifies success/failure/authorization
    -- outcome (NotifyPlayer/PresentRows), exactly as it already does for
    -- chat-typed usage. `ok = true` means only "submitted," never
    -- "succeeded" — a RegisterCommand handler has no synchronous return
    -- value to relay here.
    ExecuteCommand(table.concat(parts, ' '))
    cb({ ok = true })
end)

-- ----------------------------------------------------------------------
-- Command registration — gated at file-load time by the early return at
-- the top of this file. Defensive shape guard on Config.CommandTablet.command
-- itself (warn-and-skip, never crash resource start), same posture as
-- server/highcommand.lua's own maxXpPerGrant guard.
-- ----------------------------------------------------------------------
local tabletCommand = type(Config.CommandTablet) == 'table' and Config.CommandTablet.command or nil
if type(tabletCommand) == 'string' and tabletCommand ~= '' then
    RegisterCommand(tabletCommand, function()
        OpenTablet()
    end, false)
else
    print('[qbx_k9unit] WARNING: Config.CommandTablet.command is missing or not a valid string -- the K9 Command Tablet will not be reachable by command this session (a radial entry point, if wired, is unaffected).')
end

-- No RegisterKeyMapping here — Config.CommandTablet has no dedicated
-- keybind field (unlike Config.Vision's toggleKey), so none is invented.

-- ----------------------------------------------------------------------
-- Resource-stop safety net — see FOCUS/CLOSE DISCIPLINE point 4.
-- ----------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CloseTablet()
end)
