--[[
    qbx_k9unit/client/hud.lua

    Phase 4 (coder-ui/coder-backend handoff). Config.Features.HealthStaminaHUD
    gate (currently `false` in config.lua — this file registers NOTHING at
    all while that stays false, see the gating note below). SPEC.md §6.6
    first bullet: "NUI HUD displays health, stamina, hunger, and thirst for
    the active K9... only if Config.Features.HealthStaminaHUD is true."

    Authoritative contract for everything in this file:
    phase2_notes/phase4_hud_bridge_design.md (read that in full before
    touching the callback/message names, payload shape, focus policy, or
    push-cadence constants below — this file is a direct implementation of
    that note's §2/§3/§4/§5/§6, not an independent design pass). The NUI
    frontend (html/index.html, html/style.css, html/app.js) already exists
    and its own header comments encode the identical contract in JS-side
    terms — the two sides must match byte-for-byte on action/callback
    names and payload keys; this is the single most common silent-failure
    point in NUI code (a name that doesn't match on both sides just hangs
    or drops silently, no error thrown on either side).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4 (NUI, not net events — see the design
    note §1 for why this deliberately does NOT use the
    qbx_k9unit:client:/qbx_k9unit:server: net-event prefix convention the
    rest of this codebase's RegisterNetEvent/TriggerServerEvent names use):

    1. 'hud:ready' [RegisterNUICallback, JS -> Lua, THIS FILE]
       Fired once by html/app.js immediately after it attaches its
       `message` listener (see that file's init()/sendReadyAck() ordering
       comment). Fire-and-forget from the JS side — cb({}) is called
       unconditionally and immediately, since there is nothing meaningful
       to return, but ALSO used here as the trigger to push one immediate
       vitals snapshot (design note §5 point 6) rather than making a
       freshly-loaded HUD wait out the ~1s heartbeat ceiling for its first
       paint.
    2. 'hud:updateVitals' [SendNUIMessage, Lua -> JS, THIS FILE]
       The one and only ongoing push. Payload shape (design note §3):
           {
             action = 'hud:updateVitals',
             data = {
               visible = <boolean>,
               health  = <number>,  -- 0-100
               stamina = <number>,  -- 0-100
               hunger  = <number>,  -- 0-100
               thirst  = <number>,  -- 0-100
             },
           }
       `visible` and all four numbers are ALWAYS sent together, never
       split into separate messages (design note §3's rationale: a split
       design can desync if one message is dropped). When visibility
       transitions to false, the last REAL known values are sent alongside
       `visible = false` — never zeroed out — so a quick false->true flip
       doesn't show a stale-zero flash on the JS side before the next real
       poll tick lands.
    ======================================================================

    GATING — "gate at registration, not just inside the loop":
    mirrors client/movement.lua's AgilityBasicJump thread
    (`if not Config.Features.AgilityBasicJump then CreateThread(...) end`)
    and client/vision.lua's `if Config.Features.ThermalVision then
    RegisterCommand(...)/RegisterKeyMapping(...) end` — the flag is
    checked ONCE at file-load time to decide whether to register the NUI
    callback / start the poll thread AT ALL, not read once at the top of
    an always-running loop body. While Config.Features.HealthStaminaHUD is
    `false` (the shipped default), this file registers zero NUI callbacks
    and starts zero threads — not merely "renders nothing," genuinely
    inert.

    VISIBILITY GATE — RESOLVED per design note §6: `CanShowK9UI()`
    (IsOwnModelK9() AND HasK9Access()), the SAME combinator
    client/radial.lua's Bark/Sit/Leash/Vehicle items and client/vehicle.lua
    already gate on — deliberately NOT `IsOwnModelK9()` alone (that would
    be client/vision.lua's thermal/night-vision precedent, which does not
    apply here: this HUD is a department-issued monitoring instrument per
    SPEC.md §6.1's own acceptance criterion grouping it with the radial
    menu, not the K9's innate perception). Do not regress this to
    IsOwnModelK9() alone — see design note §6 for the full "innate
    perception vs. granted privilege" reasoning on both sides of this call.

    "...or nearby" (a handler seeing their PARTNER K9's vitals) is
    explicitly OUT OF SCOPE here per design note §6 — this file only ever
    reads/pushes the LOCAL player's own vitals, gated on the LOCAL
    player's own CanShowK9UI(). Flagged for coder-ui/coder-architect to
    resolve separately, not decided or half-built here.

    FOCUS POLICY — NO SetNuiFocus, ANYWHERE, EVER, IN THIS FILE. This is a
    passive, always-visible-while-relevant overlay with zero player-driven
    interaction (design note §4) — no buttons, no dismiss, nothing to
    click or type into, so there is no escape/close-path handling either
    (no Escape keylistener, no close callback) — that entire "stuck open
    with focus grabbed" bug class structurally cannot occur on a surface
    that never grabs focus in the first place. If a future revision adds
    an actual interactive element to html/index.html, that is a signal to
    STOP and re-decide the whole focus question, not to bolt SetNuiFocus
    onto this file's existing focus-free lifecycle.

    STAMINA NATIVE — CONFIDENCE NOTE, RESOLVED (final native-correctness
    sweep, this session): this file calls
    GetPlayerSprintStaminaRemaining(PlayerId()), which the design note §3
    correctly identifies as existing with range [0.0-100.0], but the
    NAME is misleading — the native tracks sprint EXERTION, rising toward
    100 as the player tires, not stamina remaining. Multiple independent,
    widely-used community HUD resources (status-hud, ps-hud, qz-hud,
    apx_hud) and Cfx forum threads consistently confirm this and compute
    displayed stamina as `100 - GetPlayerSprintStaminaRemaining(...)`. The
    ReadVitals() code below now does the same subtraction so "stamina" on
    the HUD bar means what it says (full when fresh, draining as the K9
    tires) — see the sweep's own report for the corroborating sources.

    HUNGER/THIRST SOURCE — MEDIUM confidence per design note §3: read from
    the already-live `QBX.PlayerData.metadata` client-side cache
    (fxmanifest.lua already pulls in `@qbx_core/modules/playerdata.lua` for
    exactly this, the same source `metadata.k9certified` already reuses —
    see client/main.lua's header for that precedent). The exact field
    names (`hunger`/`thirst`) and 0-100 scale are NOT independently
    verified against a live qbx_core install this session — confirm with
    whoever owns the qbx_core integration (coder-architect/coder-backend)
    before this flag ships enabled. No new server event/callback is added
    here for this — if the real field names differ, that's a QBX.PlayerData
    schema fix, not a reason to invent a redundant network round trip for
    data the client already caches locally.

    ONRESOURCESTOP — deliberately NOT added. Contrast client/vision.lua's
    onResourceStop handler, which exists because SetSeethrough/
    SetNightvision are REAL ENGINE STATE that persists across a resource
    restart independent of script state (a native post-effect toggle left
    on with no script left alive to turn it off). This file has no
    equivalent sticky state to clean up: it never calls SetNuiFocus, never
    toggles any native/engine-persistent effect, and its only two side
    effects are (a) a `while true` CreateThread loop, which FiveM already
    tears down automatically the instant this resource stops, and (b)
    SendNUIMessage pushes into html/index.html's own browser context,
    which is unloaded/destroyed by FiveM the moment this resource (the
    `ui_page` owner) stops — there is no "HUD left stuck visible after
    resource stop" failure mode possible, since the page rendering it stops
    existing at the same moment. Revisit only if a future revision of this
    file adds state that genuinely outlives the resource (it should not,
    for a passive display-only overlay).
]]

if not Config.Features.HealthStaminaHUD then return end

-- ----------------------------------------------------------------------
-- Tuning constants — code-local, not Config.* entries, matching how
-- client/movement.lua's LEASH_TICK_MS/LEASH_IDLE_TICK_MS and
-- LEASH_PULL_ZONE_FACTOR/LEASH_HARD_CAP_FACTOR are file-local tuning
-- knobs rather than exposed config (design note §5's closing note: "None
-- of the above needs a config addition").
-- ----------------------------------------------------------------------
local HUD_POLL_TICK_MS = 250   -- design note §5.1: active poll cadence while visible
local HUD_IDLE_TICK_MS = 1000  -- design note §5.4: idle backoff while not visible
local HUD_HEARTBEAT_MS = 1000  -- design note §5.3: forced re-push ceiling even with no real change
local HUD_CHANGE_EPSILON = 0.5 -- design note §5.2: per-field change threshold (0-100 scale) before re-pushing

-- Last-pushed snapshot, also doubling as the "last real known values" the
-- design note §3 requires be resent (never zeroed) alongside a
-- visible = false push. Seeded at 100 for every stat so an unlikely
-- push-before-any-real-read edge case (shouldn't happen — hud:ready
-- always reads fresh values first) never shows a false "empty" bar.
local hudState = {
    visible = false,
    health = 100.0,
    stamina = 100.0,
    hunger = 100.0,
    thirst = 100.0,
    lastPushAt = -HUD_HEARTBEAT_MS, -- forces the very first real push to count as heartbeat-due
}

--- Clamps a single stat value to the 0-100 range this HUD's payload
--- contract uses for all four fields (design note §3). Refactor pass
--- (dedup/consistency): the four fields below previously clamped via two
--- different idioms (a two-statement if/if pair vs. a single if/elseif) —
--- unified on this one helper so every field clamps identically.
--- @param v number
--- @return number
local function clamp01to100(v)
    if v < 0 then return 0.0 end
    if v > 100 then return 100.0 end
    return v
end

--- Reads all four vitals fresh from their real client-local sources. Pure
--- reads, no network round trip (design note §3: "structurally simpler
--- bridge... all four source values are already known to the client with
--- zero network latency").
--- @return number health, number stamina, number hunger, number thirst
local function ReadVitals()
    local ped = PlayerPedId()

    -- health — GetEntityHealth normalized against GetEntityMaxHealth, per
    -- design note §3, so the JS side never has to know GTA-specific health
    -- semantics (default max 200, "dead" threshold at 0 not 100).
    local maxHealth = GetEntityMaxHealth(ped)
    local health = 100.0
    if maxHealth > 0 then
        health = (GetEntityHealth(ped) / maxHealth) * 100.0
    end
    health = clamp01to100(health)

    -- stamina — see this file's header "STAMINA NATIVE — CONFIDENCE NOTE,
    -- RESOLVED" for why this is inverted from the raw native's own value
    -- (the native tracks exertion, rising as the K9 tires, not stamina
    -- remaining).
    -- qa-tester finding: default to 100.0 (full stamina) when the native
    -- doesn't return a number, matching the same "never paints as
    -- starving/depleted" fallback philosophy health/hunger/thirst already
    -- follow above/below — a malformed read should never look like an
    -- empty stamina bar.
    local staminaRemaining = GetPlayerSprintStaminaRemaining(PlayerId())
    local stamina = type(staminaRemaining) == 'number' and (100.0 - staminaRemaining) or 100.0
    stamina = clamp01to100(stamina)

    -- hunger/thirst — see this file's header "HUNGER/THIRST SOURCE" note
    -- on field-name/scale confidence. Defensive nil-chained read since
    -- QBX.PlayerData.metadata may not be populated yet this early in a
    -- session (e.g. hud:ready firing before qbx_core's own playerdata
    -- event has landed) — default to 100 (full) rather than 0 (empty) so
    -- a not-yet-loaded metadata table never paints as "starving."
    local metadata = QBX.PlayerData and QBX.PlayerData.metadata
    local hunger = (metadata and type(metadata.hunger) == 'number') and metadata.hunger or 100.0
    local thirst = (metadata and type(metadata.thirst) == 'number') and metadata.thirst or 100.0
    hunger = clamp01to100(hunger)
    thirst = clamp01to100(thirst)

    return health, stamina, hunger, thirst
end

--- Sends one hud:updateVitals push and updates hudState to match — the
--- single choke point every call site below routes through, so
--- "what did we last actually send" (used both for the epsilon comparison
--- and for the visible=false "resend last known values" rule) can never
--- drift from what was truly pushed.
--- @param visible boolean
--- @param health number
--- @param stamina number
--- @param hunger number
--- @param thirst number
local function PushVitals(visible, health, stamina, hunger, thirst)
    SendNUIMessage({
        action = 'hud:updateVitals',
        data = {
            visible = visible,
            health = health,
            stamina = stamina,
            hunger = hunger,
            thirst = thirst,
        },
    })

    hudState.visible = visible
    hudState.health = health
    hudState.stamina = stamina
    hudState.hunger = hunger
    hudState.thirst = thirst
    hudState.lastPushAt = GetGameTimer()
end

-- ----------------------------------------------------------------------
-- 'hud:ready' — design note §5 point 6. SendNUIMessage delivery is not
-- queued/retried: a message sent before html/app.js has attached its
-- `message` listener is simply lost. This handler is the other half of
-- that handshake — cb({}) fires immediately and unconditionally (an
-- uninvoked NUI callback hangs the frontend's fetch promise forever, the
-- most common silent-failure point in NUI code), and an immediate
-- snapshot push follows so a freshly-loaded HUD paints right away instead
-- of waiting out the ~1s heartbeat ceiling.
-- ----------------------------------------------------------------------
RegisterNUICallback('hud:ready', function(_, cb)
    cb({})

    local health, stamina, hunger, thirst = ReadVitals()
    PushVitals(CanShowK9UI(), health, stamina, hunger, thirst)
end)

-- ----------------------------------------------------------------------
-- Poll/push thread — design note §5. Only ever started because the whole
-- file already returned early above when Config.Features.HealthStaminaHUD
-- is false, so there is no redundant flag re-check needed in the loop body
-- itself (see this file's header "GATING" note).
-- ----------------------------------------------------------------------
CreateThread(function()
    while true do
        -- CanShowK9UI() itself is cheap to call every tick here: it's
        -- IsOwnModelK9() (pure local) ANDed with HasK9Access(), and
        -- HasK9Access() is already debounced by client/main.lua's own
        -- HAS_K9_ACCESS_CACHE_TTL_MS = 1000 TTL cache — so evaluating this
        -- once per 250ms poll tick triggers at most one fresh
        -- lib.callback.await per second, not one per tick (design note
        -- §5.1's footnote). This is the same cache every other
        -- CanShowK9UI()/HasK9Access() call site in this codebase already
        -- relies on for exactly this reason (every radial item's
        -- onSelect, client/vehicle.lua's canInteract).
        local canShow = CanShowK9UI()

        if not canShow then
            if hudState.visible then
                -- true -> false transition: push immediately (design note
                -- §5.5), reusing the LAST KNOWN good vitals already sitting
                -- in hudState — never a fresh read, never zeroed — per
                -- design note §3's "so the JS doesn't have to wait out a
                -- stale-zero flash" rule.
                PushVitals(false, hudState.health, hudState.stamina, hudState.hunger, hudState.thirst)
            end

            Wait(HUD_IDLE_TICK_MS) -- design note §5.4: idle backoff while not currently relevant
        else
            local health, stamina, hunger, thirst = ReadVitals()
            local becameVisible = not hudState.visible
            local now = GetGameTimer()

            local changedEnough = math.abs(health - hudState.health) > HUD_CHANGE_EPSILON
                or math.abs(stamina - hudState.stamina) > HUD_CHANGE_EPSILON
                or math.abs(hunger - hudState.hunger) > HUD_CHANGE_EPSILON
                or math.abs(thirst - hudState.thirst) > HUD_CHANGE_EPSILON
            local heartbeatDue = (now - hudState.lastPushAt) >= HUD_HEARTBEAT_MS

            -- becameVisible short-circuits straight to a push (design note
            -- §5.5's false -> true immediate-push rule), independent of
            -- both the epsilon check and the heartbeat ceiling.
            if becameVisible or changedEnough or heartbeatDue then
                PushVitals(true, health, stamina, hunger, thirst)
            end

            Wait(HUD_POLL_TICK_MS) -- design note §5.1: active poll cadence while visible
        end
    end
end)
