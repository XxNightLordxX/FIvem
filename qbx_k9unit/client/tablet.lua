--[[
    qbx_k9unit/client/tablet.lua

    Config.Features.CommandTablet (config.lua). Client-side bridge for the
    K9 Command Tablet — the in-game NUI the owner asked for ("stuff also
    in a menu or tablet control"): a roster of handlers/K9s with their
    certifications, XP and granted permissions (Config.Permissions,
    server/permissions.lua), plus the controls to grant/revoke a
    permission. THIS FILE never renders anything itself — it opens/closes
    the NUI, routes its callbacks to the server, and pushes server
    responses back. All real UI is html/tablet.* (coder-ui).

    ======================================================================
    SECURITY NOTE — READ BEFORE CHANGING ANYTHING HERE. Restated verbatim
    from config.lua's own Config.CommandTablet header because a UI makes
    this easy to get wrong: THE TABLET IS A VIEW. IT DECIDES NOTHING. Every
    action it offers is re-authorized server-side from the caller's own
    live job/grants, exactly as if they had typed the command — a modified
    client can send any NUI callback it likes with any payload, so nothing
    in this file may ever be the thing that actually authorizes an action.
    The two client-side checks below (HasK9Access() before opening,
    per-field `type()` checks on an NUI payload before forwarding it) exist
    ONLY to hide controls the viewer cannot use and to fail fast on an
    obviously malformed payload — never as a substitute for the server's
    own re-check. See server/permissions.lua's own header for what it
    independently verifies on every grant/revoke.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT — PROPOSED BY THIS FILE, pending confirmation
    from coder-backend's server/permissions.lua (messaged directly; not
    yet confirmed as of this pass — see this pass's own report for the
    exact message sent). Built to these names now so this file is not
    blocked; a rename on either end is a one-line, mechanical fix, since
    every call site below funnels through AwaitServerCallback() and this
    file never interprets the deep shape of `rows`/`permissions` — it only
    ever passes them through opaque to/from the NUI (see FILE-TO-FILE
    CONTRACT below for why that's a deliberate design choice, not laziness).

    Callbacks (ox_lib lib.callback, client -> server, ALL pcall-wrapped via
    AwaitServerCallback() below and fail CLOSED — never opens the tablet,
    never grants/revokes anything — on a timeout or an unregistered
    callback, since `lib.callback.await` THROWS rather than returning nil
    on either of those (see client/main.lua's HasK9Access() doc comment for
    the full ox_lib/FiveM source citation this file relies on verbatim)):

    1. 'qbx_k9unit:server:tabletListRoster' () -> {
           ok: boolean,
           rows: table[]?,   -- opaque to this file; forwarded to the NUI as-is
           reason: string?,  -- present when ok=false: 'not_authorized' |
                              -- 'missing_item' | 'feature_disabled' | 'timeout'
       }
       MUST independently re-check: Config.Features.CommandTablet, the
       caller's own authorization to VIEW the roster at all (this file's
       own HasK9Access() pre-check is a convenience only — see SECURITY
       NOTE), and Config.CommandTablet.requiredItem via a SERVER-side
       ox_inventory count (server/wellbeing.lua's
       `exports.ox_inventory:GetItemCount(source, itemName)` is this
       resource's own established pattern for that exact check) if that
       config field is non-nil. Reports as 'missing_item' on failure. A nil
       requiredItem disables the requirement entirely (config.lua's own
       comment) — this file adds NO client-side item-count check of its
       own (no verified ox_inventory CLIENT export for this exists
       anywhere else in this codebase to reuse, and duplicating the
       server's own check client-side would only add a second place for
       the two to drift) — the server's `reason` is the sole source of
       truth for why opening failed.
       Rows are clamped to Config.CommandTablet.maxRosterRows SERVER-side
       (config.lua: "Clamped server-side; a non-positive or non-number
       value falls back to the default"). This file also passes
       Config.CommandTablet.maxRosterRows to the NUI as a display hint
       only (shared_scripts config, already available client-side with no
       round trip) — never as its own enforcement.
    2. 'qbx_k9unit:server:tabletGrantPermission' (targetCitizenid: string,
       permissionKey: string) -> { ok: boolean, reason: string? }
    3. 'qbx_k9unit:server:tabletRevokePermission' (targetCitizenid: string,
       permissionKey: string) -> { ok: boolean, reason: string? }
       Both MUST independently re-verify the caller is authorized to
       grant/revoke (config.lua's Config.Permissions header: high command,
       or a caller who already holds 'k9.certify', in some resolution
       order server/permissions.lua owns) — this file performs NO such
       check itself before sending; see SECURITY NOTE.

    Deliberately NOT requested as a callback: "list permissions" (the
    definitions/labels/descriptions in Config.Permissions). That table is
    shared_scripts, static, and identical on both sides already — asking
    the server for a copy of its own config would be a pure-latency round
    trip for data this client already has. This file reads
    Config.Permissions directly and forwards it in the 'tablet:open' NUI
    push below (see FILE-TO-FILE CONTRACT).
    ======================================================================

    ======================================================================
    NUI CONTRACT — PROPOSED BY THIS FILE, pending confirmation from
    coder-ui's html/tablet.* (messaged directly; not yet confirmed as of
    this pass — see this pass's own report). Mirrors client/hud.lua's own
    "CONTRACT (must match... byte-for-byte)" framing: a name mismatch on
    either side just hangs or drops silently, no error thrown anywhere.

    JS -> Lua (RegisterNUICallback, fetch(`https://${GetParentResourceName()}/<name>`)):
      'tablet:close' (data: {}) -> cb({ ok = true })
          Player-initiated close (e.g. a close button/X). ALSO reachable
          without the NUI's cooperation at all — see FOCUS/CLOSE
          DISCIPLINE below; this callback is never the ONLY way to close.
      'tablet:getRoster' (data: {}) -> cb({ ok, rows, reason })
          Re-fetches the roster (e.g. a manual refresh, or after a
          grant/revoke) via the SAME server callback OpenTablet() itself
          awaits — see AwaitServerCallback(). A failure here does NOT
          close the tablet or drop focus; it only means this one refresh
          came back empty/denied. The NUI decides how to render that.
      'tablet:grantPermission' (data: { citizenid: string, permissionKey: string })
          -> cb({ ok, reason })
      'tablet:revokePermission' (data: { citizenid: string, permissionKey: string })
          -> cb({ ok, reason })
          Both forward straight to the matching server callback above
          after a `type()` shape check ONLY (see SECURITY NOTE — this is
          not authorization, it's "don't bother the server with an
          obviously malformed payload"). cb({ ok = false, reason =
          'invalid_args' }) on a shape failure, no server round trip.

    Lua -> JS (SendNUIMessage):
      { action = 'tablet:open', data = {
          permissions = Config.Permissions,       -- shared config, see above
          maxRosterRows = Config.CommandTablet.maxRosterRows,
          rows = <opaque, from tabletListRoster>,
      } }
          Sent exactly once per successful open, right before
          SetNuiFocus(true, true) — see FOCUS/CLOSE DISCIPLINE.
      { action = 'tablet:close', data = {} }
          Sent on EVERY close, regardless of what initiated it (JS itself,
          ESC, death, resource stop) — see FOCUS/CLOSE DISCIPLINE for why
          this is unconditional rather than only firing for a
          Lua-initiated close.
    ======================================================================

    ======================================================================
    FOCUS/CLOSE DISCIPLINE — this is the first focus-taking surface in
    this resource (html/app.js's own header states outright it has never
    called SetNuiFocus; grepping this whole resource for SetNuiFocus
    before this file returns zero matches). A stuck focus locks a player
    out of their own character with no way back except a reconnect, so
    every path in this file that can OPEN the tablet has a corresponding
    path that can CLOSE it, and none of the close paths depend on the NUI
    page still being alive/cooperative:
      1. JS calls 'tablet:close' -> CloseTablet().
      2. ESC (INPUT_FRONTEND_PAUSE, control 200) -> handled ENTIRELY
         Lua-side, never routed through the NUI at all — see
         EnsureTabletWatchThreadRunning() below. This is deliberate: "the
         NUI tells Lua to close" is exactly the channel that goes silent
         if the page has errored, which is the whole reason this task
         calls out ESC by name as a MUST.
      3. Own death — same thread, same reasoning: FiveM's respawn REUSES
         the same ped handle (this resource has already been bitten by
         exactly this class of bug once — a K9 that died mid-vehicle-load
         respawned frozen/invisible/still-attached, per client/vehicle.lua's
         own header and PROJECT_STATUS.md), so a focus grab is exactly the
         kind of per-ped state that would otherwise survive a respawn with
         nothing to release it. Checked in the SAME thread as ESC (see
         that thread's own comment for why one thread suffices) rather
         than a slower, separate poll — closing the tablet is not
         performance-sensitive, but the thread already runs every frame
         for ESC regardless, so folding the death check in costs nothing
         extra.
      4. onResourceStop (this resource only) -> releases focus
         unconditionally if the tablet was open. NUI focus is game-engine
         input-routing state, not something torn down implicitly just
         because this resource's ui_page browser context goes away when
         the resource stops (unlike client/vision.lua's SetSeethrough/
         SetNightvision, which are a *rendering* post-effect with its own,
         separately-documented persistence story) — an unreleased
         SetNuiFocus(true, true) here would be the exact "no way back
         except reconnect" failure this task names explicitly.
    Every one of the four paths above funnels through the ONE CloseTablet()
    function — there is exactly one place in this file that ever calls
    SetNuiFocus(false, false), so "is focus actually released" can never
    drift between call sites the way it could if e.g. onResourceStop had
    its own separate copy of the teardown.
    CloseTablet() itself does NOT gate on CanShowK9UI()/HasK9Access() (or
    anything else) — the "no unbounded trap" rule this codebase applies
    everywhere a release/termination path exists (see e.g.
    client/recall.lua's header): a handler who loses K9 access, gets
    decertified, or changes departments WHILE the tablet is open must
    still be able to close it.
    ======================================================================

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE calls client/main.lua's HasK9Access() and DenyK9UIAccess().
      Deliberately HasK9Access() ALONE, NOT the full CanShowK9UI()
      combinator (IsOwnModelK9() AND HasK9Access()) client/radial.lua's
      Bark/Sit/Leash/Vehicle items and client/hud.lua both gate on. RESOLVED
      ACCESS-GATING DECISION, same "state it, don't silently guess" posture
      client/vision.lua's own header uses for its own opposite answer: the
      Command Tablet is departmental administrative tooling for handlers
      AND high command — reviewing a roster or granting a permission has
      nothing to do with whether the CALLER is currently playing a
      K9-modeled character. A human officer character checking the roster
      is the expected, common case, not an edge case; requiring
      IsOwnModelK9() would block exactly that. HasK9Access() alone already
      means "in a Config.Departments job AND (certified OR high command OR
      autoAccessGrade)" per server/certifications.lua's own contract
      (confirmed via server/highcommand.lua's header: high command gets
      HasK9Access()'s bypass WITHOUT holding a certification) — a
      reasonable baseline "plausibly departmental tooling" gate. This is a
      CLIENT-SIDE CONVENIENCE ONLY (see SECURITY NOTE); the server
      independently re-authorizes the specific view/grant/revoke action
      regardless of what this gate decided.
    - THIS FILE never inspects the deep shape of a roster row or a
      permission definition — `rows` (server) and `Config.Permissions`
      (shared) are forwarded to the NUI as opaque tables. This is a
      deliberate design choice, not an oversight: it means a change to the
      roster row shape, or to Config.Permissions' own fields, needs no
      corresponding change in THIS file at all, only in server/permissions.lua
      and html/tablet.* — the two ends that actually read those fields.
    - THIS FILE does not call into client/radial.lua (radial has a live
      owner this session) — see this pass's own report for the exact
      radial item requested instead of edited directly.
    - THIS FILE exposes ONE resource-global (no `local`) function:
        OpenTablet() -> nil
      for a future client/radial.lua entry to call, behind that file's own
      `type(OpenTablet) == 'function'` runtime-existence guard convention
      (this codebase's established soft-dependency idiom — see e.g.
      RequestOpenOwnK9Inventory/RequestTreatNearestK9's own call sites in
      client/radial.lua). CloseTablet() is intentionally NOT exposed
      globally: nothing outside this file has a legitimate reason to force
      the tablet closed, and every real close path (JS callback, ESC,
      death, resource stop) already lives inside this same file.
    ======================================================================

    GATING — "gate at registration, not just inside the handler," this
    codebase's stated convention (see client/vision.lua's/client/hud.lua's
    own identical framing): the single `if not Config.Features.CommandTablet
    then return end` immediately below means the command, every
    RegisterNUICallback, and OpenTablet()/CloseTablet() themselves do not
    exist at all while the flag is off — not merely inert behind an
    internal check. Config.CommandTablet.command has no dedicated keybind
    field in config.lua (unlike e.g. Config.Vision's toggleKey), so this
    file registers no RegisterKeyMapping — only the command itself, plus
    ESC-to-close while genuinely open (see FOCUS/CLOSE DISCIPLINE; that is
    a fixed engine keybind this resource temporarily claims while the
    tablet is visible, never a configurable one).
]]

if not Config.Features.CommandTablet then return end

-- ----------------------------------------------------------------------
-- Reason -> player-facing OPEN-failure message. Mirrors client/inventory.lua's
-- K9_INVENTORY_REASON_MESSAGES shape exactly: each reason is a genuinely
-- distinct cause, kept as separate locale() keys rather than one templated
-- string (locales/README.md's own non-collapsing discipline). This table
-- covers ONLY the "tablet failed to open at all" case (shown via
-- lib.notify, since the NUI is never shown for this failure) — grant/
-- revoke/getRoster failures AFTER the tablet is already open are handled
-- entirely inside the NUI from the raw `reason` string this file forwards
-- unmodified (see NUI CONTRACT above); this file has no locale copy for
-- those, by design (coder-ui owns NUI-side copy, per this codebase's
-- "route player-facing text through locale keys" convention applied to
-- its own surface).
-- ----------------------------------------------------------------------
local TABLET_OPEN_REASON_MESSAGES = {
    not_authorized   = locale('tablet.reason_not_authorized'),
    missing_item     = locale('tablet.reason_missing_item'),
    feature_disabled = locale('tablet.reason_feature_disabled'),
}

-- Whether the tablet is CURRENTLY visible/focused. The single source of
-- truth EnsureTabletWatchThreadRunning()'s loop condition, CloseTablet()'s
-- own no-op guard, and OpenTablet()'s "already open" guard all read.
local tabletOpen = false

-- IN-FLIGHT OPEN GUARD — separate from `tabletOpen` on purpose. OpenTablet()
-- yields on a server round trip (AwaitServerCallback) BEFORE it ever sets
-- `tabletOpen = true` or calls SetNuiFocus. Without this second flag, a
-- player mashing the open command/radial item twice in the split second
-- before the first request resolves would pass the `if tabletOpen then
-- return end` guard TWICE (it's still false during the await), starting two
-- concurrent 'qbx_k9unit:server:tabletListRoster' awaits that could each
-- independently try to open the tablet a second time once they resolve —
-- the exact double-registration/double-focus race client/tracking.lua's own
-- `startInFlight` guard exists to close for an unrelated feature. Reset to
-- false on EVERY exit path out of OpenTablet(), success or failure alike.
local tabletOpening = false

-- ----------------------------------------------------------------------
-- Pcall-wrapped, fail-closed wrapper around every server callback this
-- file awaits — see this file's header EVENT/CALLBACK CONTRACT for why
-- every one of these three callbacks fails closed the same way.
-- `lib.callback.await` THROWS (does not return nil) on a timeout or an
-- unregistered callback (client/main.lua's HasK9Access() doc comment cites
-- the exact ox_lib/FiveM source for this; duplicated as its own guard, not
-- shared, matching this codebase's established per-file-copy convention
-- for this exact check — see client/partnership.lua/client/wellbeing.lua/
-- client/medkit.lua/client/tracking.lua/client/inventory.lua for the same
-- pattern applied to their own callbacks). Every caller below funnels
-- through this ONE function, so a thrown callback always looks the same
-- to the rest of this file: `{ ok = false, reason = 'timeout' }`, a plain
-- table, never a propagating Lua error that could abort a
-- RegisterNUICallback handler mid-way and leave its `cb` never invoked
-- (client/hud.lua's own "an uninvoked NUI callback hangs the frontend's
-- fetch promise forever" warning applies doubly hard here, since an
-- uninvoked cb during OpenTablet() specifically would also leave
-- `tabletOpening` stuck true forever with nothing left to reset it — this
-- function existing is what guarantees that reset always runs regardless
-- of how the await resolves).
-- ----------------------------------------------------------------------
--- @param name string
--- @param ... any
--- @return table result -- always a table; never a raw propagated error
local function AwaitServerCallback(name, ...)
    local ok, result = pcall(lib.callback.await, name, false, ...)
    if not ok or type(result) ~= 'table' then
        return { ok = false, reason = 'timeout' }
    end
    return result
end

--- The ONE place this file ever calls SetNuiFocus(false, false) or pushes
--- 'tablet:close' — see this file's header FOCUS/CLOSE DISCIPLINE for the
--- full list of call sites that all funnel through here. Deliberately has
--- NO access/state check beyond "is it even open" — a close/termination
--- path must never be gated on anything else (this codebase's "no
--- unbounded trap" rule; see client/recall.lua's own header for the same
--- reasoning applied to a different feature).
function CloseTablet()
    if not tabletOpen then return end

    tabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'tablet:close', data = {} })
end

-- ----------------------------------------------------------------------
-- ESC-close + own-death watch thread — see this file's header FOCUS/CLOSE
-- DISCIPLINE points 2 and 3 for why both live in one thread. Lifecycle
-- guard mirrors client/vision.lua's own
-- `visionMaintenanceThreadRunning`/EnsureVisionMaintenanceThreadRunning()
-- pair exactly: started only from OpenTablet()'s "turning on" path, a
-- true no-op while already running, and self-resetting the instant the
-- loop condition (`tabletOpen`) goes false — so this resource pays for a
-- Wait(0) thread ONLY while the tablet is genuinely visible, never while
-- it's closed and never a second, redundant thread while one is already
-- watching.
--
-- Wait(0) IS THE RIGHT INTERVAL HERE, not a violation of this codebase's
-- "no tight Wait(0) loop" performance rule: DisableControlAction must be
-- re-asserted every single frame to actually suppress the native pause
-- menu while the tablet has focus (a native control disable does not
-- persist across frames on its own — this is the same reason every
-- FiveM ESC-closeable NUI menu in the wild reasserts it every tick), and
-- this thread's own lifetime is already bounded to "while the tablet is
-- open" — it is not a perpetually-idling background poll, it is a
-- bounded-duration input claim that ends the moment CloseTablet() runs.
-- ----------------------------------------------------------------------
local tabletWatchThreadRunning = false
local function EnsureTabletWatchThreadRunning()
    if tabletWatchThreadRunning then return end
    tabletWatchThreadRunning = true

    CreateThread(function()
        while tabletOpen do
            -- INPUT_FRONTEND_PAUSE (control 200) — standard, widely-used
            -- FiveM idiom for an ESC-closeable NUI menu: DisableControlAction
            -- suppresses the native pause menu from opening, and
            -- IsDisabledControlJustPressed (the DISABLED-control variant,
            -- not plain IsControlJustPressed, which stops reporting a press
            -- once the control is disabled) is what actually detects the
            -- keypress in the same frame it was suppressed. MEDIUM-HIGH
            -- confidence: the standard documented pattern, matching this
            -- codebase's own confidence-grading convention for a native
            -- combo not independently re-verified in-engine this pass (see
            -- e.g. client/main.lua's SOURCE-ORIGIN GUARD comment for the
            -- same grading applied to a different native-adjacent pattern).
            DisableControlAction(0, 200, true)

            if IsDisabledControlJustPressed(0, 200) then
                CloseTablet()
            elseif IsEntityDead(PlayerPedId()) then
                -- OWN-DEATH CLOSE (task requirement) — same
                -- IsEntityDead(PlayerPedId()) polling shape already
                -- established by client/vision.lua/client/screenfx.lua/
                -- client/propattachment.lua/client/fetch.lua/
                -- client/vehicle.lua for the identical "clean up per-ped
                -- state on death, since FiveM's respawn reuses the same
                -- ped handle" reasoning — applied here to a focus grab
                -- instead of a native ped-state toggle.
                CloseTablet()
            end

            Wait(0)
        end

        tabletWatchThreadRunning = false
    end)
end

--- Opens the K9 Command Tablet for the LOCAL player. Exposed globally —
--- see this file's header FILE-TO-FILE CONTRACT — for a future
--- client/radial.lua entry (this pass's own report names the exact item
--- requested).
--- @return nil
function OpenTablet()
    if tabletOpen or tabletOpening then return end

    -- CONVENIENCE GATE ONLY — see this file's header FILE-TO-FILE CONTRACT
    -- for why HasK9Access() alone, not CanShowK9UI(), and the SECURITY NOTE
    -- for why this can never be the real authorization.
    if not HasK9Access() then
        DenyK9UIAccess()
        return
    end

    tabletOpening = true
    local result = AwaitServerCallback('qbx_k9unit:server:tabletListRoster')
    tabletOpening = false

    -- DEATH-DURING-AWAIT GUARD: the round trip above yields for the
    -- duration of a real network round trip, during which the player can
    -- die. Silently abort rather than grabbing focus for a ped that is
    -- already dead when the response lands — no notify needed (a player
    -- who just died is not waiting on tablet-open feedback), just never
    -- open. Same class of race this file's own `tabletOpening` guard above
    -- closes for a double-open, applied here to a death that lands in the
    -- same window.
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
            -- Shared config, not a server round trip — see this file's
            -- header EVENT/CALLBACK CONTRACT closing note.
            permissions = Config.Permissions,
            maxRosterRows = Config.CommandTablet.maxRosterRows,
            -- Opaque passthrough — see FILE-TO-FILE CONTRACT.
            rows = type(result.rows) == 'table' and result.rows or {},
        },
    })
    SetNuiFocus(true, true)
    EnsureTabletWatchThreadRunning()
end

-- ----------------------------------------------------------------------
-- NUI callbacks (JS -> Lua) — see this file's header NUI CONTRACT for the
-- full name/payload/response contract. Every branch below calls `cb`
-- exactly once, unconditionally, on every path — an uninvoked NUI callback
-- hangs the frontend's fetch promise forever (client/hud.lua's own stated
-- reasoning for the same discipline).
-- ----------------------------------------------------------------------
RegisterNUICallback('tablet:close', function(_, cb)
    CloseTablet()
    cb({ ok = true })
end)

RegisterNUICallback('tablet:getRoster', function(_, cb)
    cb(AwaitServerCallback('qbx_k9unit:server:tabletListRoster'))
end)

--- Shared shape guard for the two mutation callbacks below — see SECURITY
--- NOTE: this is a "don't bother the server with an obviously malformed
--- payload" check, never an authorization decision.
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
-- Command registration — gated at file-load time by the early return at
-- the top of this file (Config.Features.CommandTablet), per this
-- resource's stated "gate at registration, not inside the handler"
-- convention. Defensive shape guard on Config.CommandTablet.command itself
-- (warn-and-skip, never crash resource start) — same "WARNING at start for
-- an operator-tunable value" posture as server/highcommand.lua's own
-- maxXpPerGrant guard, proportionate here since a missing/malformed
-- command name only leaves the tablet unreachable by command (the radial
-- entry point this pass separately requests is unaffected), not a
-- security gap.
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
-- keybind field (unlike Config.Vision's toggleKey), so none is invented;
-- see this file's header GATING section.

-- ----------------------------------------------------------------------
-- Resource-stop safety net — see this file's header FOCUS/CLOSE
-- DISCIPLINE point 4. Mirrors client/vision.lua's/client/propattachment.lua's
-- own onResourceStop pattern, applied here to a focus grab instead of a
-- native post-effect/attached prop.
-- ----------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CloseTablet()
end)
