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

    ======================================================================
    WELLBEING / XP TIER EXTENSION — added this pass. Same message action,
    same single combined push (`hud:updateVitals`) as above — no new
    action name, no second message, per the same "never split, so a
    dropped message can't desync fields" rationale the original four
    vitals already follow. The payload's `data` object gains two new keys,
    ALWAYS present as tables (possibly with some/all of their own keys
    absent), sent alongside `visible`/health/stamina/hunger/thirst on
    every push:

        data.wellbeing = {
          fatigue    = <number 0-100>,  -- KEY ABSENT unless Config.Features.FatigueSystem
          mood       = <number 0-100>,  -- KEY ABSENT unless Config.Features.MoodSystem
          fearStress = <number 0-100>,  -- KEY ABSENT unless Config.Features.FearStressSystem
          injury     = <number 0-100>,  -- KEY ABSENT unless Config.Features.InjuryLimping
          distracted = <boolean>,       -- KEY ABSENT unless Config.Features.DistractionSystem
        }
        data.xpTier = {
          label = <string>,  -- KEY ABSENT unless Config.Features.XPProgression AND a
                              -- tier snapshot has actually been received client-side
        }

    A key's ABSENCE (not a zeroed/false/empty-string value) is how a
    disabled feature — or, for xpTier.label, a not-yet-known tier — is
    signaled. html/app.js must render that element as genuinely gone from
    the DOM (its row hidden), never as a blank/zero placeholder, per this
    task's own "must be absent, not blank or zeroed" requirement. This
    mirrors the flag-gated inertness client/wellbeing.lua and
    client/progression.lua already both apply to their OWN gating (a
    disabled feature's section is inert, not merely quiet).

    DATA SOURCE — NO NEW SERVER ROUND TRIP, EITHER FOR WELLBEING OR XP:
      - Wellbeing (fatigue/mood/fearStress/injury/distracted): this file
        registers its OWN independent RegisterNetEvent handler on
        'qbx_k9unit:client:wellbeingUpdate' — the SAME event
        client/wellbeing.lua's own handler already consumes (FiveM allows
        multiple independent handlers per event name; RegisterNetEvent's
        two-argument form both (re-)registers the event name and attaches
        a NEW handler each time it's called, it does not replace a prior
        handler). This file's handler only mirrors the payload into a
        local read-only `wellbeingCache` for display — it never calls
        client/wellbeing.lua's ApplyWellbeingSnapshot, never touches
        K9MoveRateModifiers, and never itself calls the
        'qbx_k9unit:server:getWellbeingSnapshot' callback
        client/wellbeing.lua already owns. See `wellbeingCache`'s own
        comment below for the one disclosed consequence of this approach
        (bounded staleness right after a K9-model transition, before the
        first periodic tick broadcast lands — client/wellbeing.lua's own
        on-demand catch-up fetch for that moment is applied locally inside
        that file only, never re-broadcast as this same event).
      - XP tier (xpTier.label): read via `GetCurrentXPTier()`, the
        resource-global client/progression.lua already exposes for exactly
        this "future HUD/display need" (see that file's own header) —
        called behind a `type(GetCurrentXPTier) == 'function'` guard, this
        codebase's established soft-dependency convention (mirrors
        client/progression.lua's own guard on RecomputeK9MoveRate), even
        though the symbol is already declared in .luacheckrc's `globals`
        list — the guard covers the real runtime case where
        Config.Features.XPProgression is false and client/progression.lua
        returns at its own top-of-file gate before ever defining the
        function at all.

    CROSS-FILE COORDINATION NOTE FOR WHOEVER NEXT TOUCHES
    client/wellbeing.lua: this file deliberately does NOT ask that file for
    a new accessor — see the "NO NEW SERVER ROUND TRIP" note above for why
    the existing net-event is sufficient. No .luacheckrc change and no
    wellbeing.lua change are required for this HUD extension to work as
    written.

    PER-TICK COST of this extension (same 250ms/1000ms cadence as
    before — no new thread, no tightened interval): a handful of local
    table field reads (`wellbeingCache.*`, already up to date from the
    push-driven event listener above, not polled), up to 5 extra
    `math.abs`/equality comparisons in the existing change-detection check
    below (skipped entirely per-field when that field's owning flag is
    off, via short-circuited `and`), one optional resource-global function
    call (`GetCurrentXPTier()`, itself just a table field return — no
    network, no native call), and two small extra sub-tables added to the
    SAME SendNUIMessage payload this thread already constructs every push.
    No new native calls, no new network round trips, no new allocations
    beyond those two small sub-tables.
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
local HUD_CHANGE_EPSILON = 0.5 -- design note §5.2: per-field change threshold (0-100 scale) before re-pushing; reused unchanged for the wellbeing numeric fields below (same 0-100 contract)

-- Shared, reused (never mutated) metatable forcing dkjson (this runtime's
-- `json.encode`, which SendNUIMessage's table-argument path encodes
-- through) to serialize a table as a JSON object (`{}`/`{...}`) even when
-- it has zero keys, rather than defaulting an empty table to `[]` — see
-- PushVitals below, where this is applied to the `wellbeing`/`xpTier`
-- sub-tables every push, for the full reasoning. One shared table reused
-- via setmetatable on each push (never recreated per-push) so this costs
-- nothing beyond the two setmetatable calls already cheap on their own.
local JSON_FORCE_OBJECT_MT = { __jsontype = 'object' }

-- Which of the five wellbeing HUD elements are live, computed ONCE at
-- file-load time (see this file's header "GATING" note — the same
-- check-once-not-every-tick posture applies here) so the poll thread below
-- never re-reads Config.Features.* per field per tick. Independent of
-- Config.Features.HealthStaminaHUD itself (already guaranteed true, since
-- this whole file returned early above if it weren't) — these five flags
-- gate each wellbeing ROW independently, per this task's own "gated so
-- each element only appears when its own feature is enabled" requirement.
local WELLBEING_ELEMENT_ENABLED = {
    fatigue = Config.Features.FatigueSystem,
    mood = Config.Features.MoodSystem,
    fearStress = Config.Features.FearStressSystem,
    injury = Config.Features.InjuryLimping,
    distraction = Config.Features.DistractionSystem,
}
local ANY_WELLBEING_ELEMENT_ENABLED = WELLBEING_ELEMENT_ENABLED.fatigue
    or WELLBEING_ELEMENT_ENABLED.mood
    or WELLBEING_ELEMENT_ENABLED.fearStress
    or WELLBEING_ELEMENT_ENABLED.injury
    or WELLBEING_ELEMENT_ENABLED.distraction

-- Same "computed once, not every tick" posture for the XP tier row.
local XP_TIER_ELEMENT_ENABLED = Config.Features.XPProgression

-- Last-pushed snapshot, also doubling as the "last real known values" the
-- design note §3 requires be resent (never zeroed) alongside a
-- visible = false push. Seeded at 100 for every stat so an unlikely
-- push-before-any-real-read edge case (shouldn't happen — hud:ready
-- always reads fresh values first) never shows a false "empty" bar. The
-- wellbeing fields below follow the identical seeding posture (100/100/0/
-- 100 healthy defaults, matching client/wellbeing.lua's own `lastStats`
-- seed exactly) — a disabled wellbeing element's slot here simply never
-- moves off this seed and is never read or sent (see
-- WELLBEING_ELEMENT_ENABLED above), so it is harmless either way.
local hudState = {
    visible = false,
    health = 100.0,
    stamina = 100.0,
    hunger = 100.0,
    thirst = 100.0,
    fatigue = 100.0,
    mood = 100.0,
    fearStress = 0.0,
    injury = 100.0,
    distracted = false,
    xpTierLabel = nil, -- string|nil; nil means "no tier known yet" (XPProgression disabled, or no snapshot received this session yet) — rendered as an absent row in that case, per the header's "absence, not blank" rule
    lastPushAt = -HUD_HEARTBEAT_MS, -- forces the very first real push to count as heartbeat-due
}

-- Local read-only mirror of the server-pushed wellbeing snapshot,
-- populated ONLY by observing 'qbx_k9unit:client:wellbeingUpdate' below —
-- this file never calls the 'qbx_k9unit:server:getWellbeingSnapshot'
-- callback itself (see this file's header "WELLBEING / XP TIER EXTENSION"
-- section for why: client/wellbeing.lua already owns that on-demand
-- fetch, and this file must not add a second round trip for the same
-- data). Seeded at each stat's healthy default (mirrors
-- client/wellbeing.lua's own `lastStats` seed exactly), so a not-yet-
-- received snapshot never displays as empty/critical.
--
-- DISCLOSED LIMITATION: this cache only updates on the periodic server
-- tick broadcast (Config.Wellbeing.tickIntervalMs, 5000ms by default),
-- NOT on client/wellbeing.lua's own one-shot on-demand catch-up fetch for
-- the moment this client's ped first becomes K9-modeled (that fetch's
-- result is applied only LOCALLY inside client/wellbeing.lua via a direct
-- function call, never re-broadcast as this same event) — so these HUD
-- rows may lag up to one tick interval behind client/wellbeing.lua's own
-- already-applied state right after a K9 model change. Bounded and
-- self-healing (the same heartbeat philosophy the rest of this file
-- already relies on for the four core vitals), not a silent gap.
local wellbeingCache = {
    fatigue = 100.0,
    mood = 100.0,
    fearStress = 0.0,
    injury = 100.0,
    distractedUntil = 0,
}

if ANY_WELLBEING_ELEMENT_ENABLED then
    -- Deliberately a SEPARATE, independent listener on the SAME event
    -- client/wellbeing.lua's own RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', ...)
    -- already consumes — see this file's header for why this is not a new
    -- round trip. Gated at registration (not just in the loop body) so
    -- this file registers zero extra listeners when no wellbeing element
    -- is enabled, matching this file's own "GATING" convention.
    RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', function(stats)
        -- SOURCE-ORIGIN GUARD — same check, same reasoning, same
        -- confidence grading as client/wellbeing.lua's own identical guard
        -- on this exact event (see that file's header for the full
        -- writeup) — duplicated here rather than shared, matching this
        -- codebase's established per-file guard convention
        -- (client/combat.lua, client/progression.lua, client/wellbeing.lua
        -- each keep their own copy rather than sharing one).
        if source ~= 65535 then return end
        if type(stats) ~= 'table' then return end

        wellbeingCache.fatigue = tonumber(stats.fatigue) or wellbeingCache.fatigue
        wellbeingCache.mood = tonumber(stats.mood) or wellbeingCache.mood
        wellbeingCache.fearStress = tonumber(stats.fearStress) or wellbeingCache.fearStress
        wellbeingCache.injury = tonumber(stats.injury) or wellbeingCache.injury
        wellbeingCache.distractedUntil = tonumber(stats.distractedUntil) or wellbeingCache.distractedUntil
    end)
end

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

--- Reads the five wellbeing display fields fresh from `wellbeingCache`
--- (itself only ever updated by the push-driven event listener above —
--- see this file's header, no network read happens here), returning nil
--- for any field whose owning Config.Features flag is off. A nil return
--- here is what ultimately makes that field's KEY ABSENT from the
--- SendNUIMessage payload (see PushVitals below) — the mechanism behind
--- this task's "must be absent, not blank or zeroed" requirement.
--- @return number|nil fatigue, number|nil mood, number|nil fearStress, number|nil injury, boolean|nil distracted
local function ReadWellbeingForDisplay()
    local fatigue, mood, fearStress, injury, distracted = nil, nil, nil, nil, nil

    if WELLBEING_ELEMENT_ENABLED.fatigue then
        fatigue = clamp01to100(wellbeingCache.fatigue)
    end
    if WELLBEING_ELEMENT_ENABLED.mood then
        mood = clamp01to100(wellbeingCache.mood)
    end
    if WELLBEING_ELEMENT_ENABLED.fearStress then
        fearStress = clamp01to100(wellbeingCache.fearStress)
    end
    if WELLBEING_ELEMENT_ENABLED.injury then
        injury = clamp01to100(wellbeingCache.injury)
    end
    if WELLBEING_ELEMENT_ENABLED.distraction then
        distracted = wellbeingCache.distractedUntil > GetGameTimer()
    end

    return fatigue, mood, fearStress, injury, distracted
end

--- Reads the current XP tier's label, or nil if XPProgression is off, the
--- client/progression.lua accessor doesn't exist (soft-dependency guard —
--- see this file's header), or no tier snapshot has been received this
--- session yet (GetCurrentXPTier() itself returning nil, which is its own
--- documented behavior before the first 'qbx_k9unit:client:xpTierChanged'
--- event lands).
--- @return string|nil
local function ReadXPTierLabel()
    if not XP_TIER_ELEMENT_ENABLED then return nil end
    if type(GetCurrentXPTier) ~= 'function' then return nil end

    local tier = GetCurrentXPTier()
    if type(tier) ~= 'table' or type(tier.label) ~= 'string' then return nil end

    return tier.label
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
--- @param fatigue number|nil
--- @param mood number|nil
--- @param fearStress number|nil
--- @param injury number|nil
--- @param distracted boolean|nil
--- @param xpTierLabel string|nil
local function PushVitals(visible, health, stamina, hunger, thirst, fatigue, mood, fearStress, injury, distracted, xpTierLabel)
    -- See this file's header "WELLBEING / XP TIER EXTENSION" — any of
    -- these five keys being nil above means it is simply ABSENT here (a
    -- Lua table never stores a nil-valued key), which is exactly the
    -- "absent, not blank/zeroed" signal html/app.js keys its per-row
    -- show/hide off of.
    --
    -- WIRE-SHAPE FIX: with every wellbeing flag off and XPProgression off
    -- (the shipped default — see config.lua) every key in both sub-tables
    -- below is nil, leaving each an EMPTY Lua table. json.lua (dkjson,
    -- this runtime's actual `json.encode` backing SendNUIMessage's table
    -- argument — confirmed by reading
    -- data/shared/citizen/scripting/lua/json.lua directly) cannot tell an
    -- empty array from an empty object from table content alone and
    -- defaults an empty table to a JSON array (`isarray({})` returns true
    -- there since an empty `pairs` loop never trips its "not a
    -- sequential-integer key" bailout) — so without a hint, this file
    -- would silently send `wellbeing: []` / `xpTier: []` on the wire,
    -- contradicting both this header's "always present as tables" promise
    -- and html/app.js's own `{ ..., wellbeing?: object, xpTier?: object }`
    -- JSDoc contract. dkjson's own `__jsontype = 'object'` metatable hint
    -- (same file, checked right where it decides array-vs-object) exists
    -- for exactly this ambiguity — applied to both sub-tables below so
    -- they always encode as `{}`/`{...}`, never `[]`, regardless of how
    -- many of their keys end up populated this push. html/app.js's current
    -- bracket-property access (`wellbeing[stat]`, `wellbeing.distracted`)
    -- happens to tolerate either shape today (property access on a JS
    -- array works the same as on an object), so this was not an observed
    -- runtime failure — this closes the gap before a stricter downstream
    -- consumer (or a future app.js rewrite) could turn it into one.
    local wellbeing = {
        fatigue = fatigue,
        mood = mood,
        fearStress = fearStress,
        injury = injury,
        distracted = distracted,
    }
    local xpTier = {
        label = xpTierLabel,
    }
    setmetatable(wellbeing, JSON_FORCE_OBJECT_MT)
    setmetatable(xpTier, JSON_FORCE_OBJECT_MT)

    SendNUIMessage({
        action = 'hud:updateVitals',
        data = {
            visible = visible,
            health = health,
            stamina = stamina,
            hunger = hunger,
            thirst = thirst,
            wellbeing = wellbeing,
            xpTier = xpTier,
        },
    })

    hudState.visible = visible
    hudState.health = health
    hudState.stamina = stamina
    hudState.hunger = hunger
    hudState.thirst = thirst
    hudState.fatigue = fatigue
    hudState.mood = mood
    hudState.fearStress = fearStress
    hudState.injury = injury
    hudState.distracted = distracted
    hudState.xpTierLabel = xpTierLabel
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
    local fatigue, mood, fearStress, injury, distracted = ReadWellbeingForDisplay()
    local xpTierLabel = ReadXPTierLabel()
    PushVitals(CanShowK9UI(), health, stamina, hunger, thirst, fatigue, mood, fearStress, injury, distracted, xpTierLabel)
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
                -- §5.5), reusing the LAST KNOWN good vitals AND wellbeing/
                -- xpTier fields already sitting in hudState — never a
                -- fresh read, never zeroed — per design note §3's "so the
                -- JS doesn't have to wait out a stale-zero flash" rule,
                -- extended here to the wellbeing/xpTier fields for the
                -- identical reason.
                PushVitals(false, hudState.health, hudState.stamina, hudState.hunger, hudState.thirst,
                    hudState.fatigue, hudState.mood, hudState.fearStress, hudState.injury, hudState.distracted,
                    hudState.xpTierLabel)
            end

            Wait(HUD_IDLE_TICK_MS) -- design note §5.4: idle backoff while not currently relevant
        else
            local health, stamina, hunger, thirst = ReadVitals()
            local fatigue, mood, fearStress, injury, distracted = ReadWellbeingForDisplay()
            local xpTierLabel = ReadXPTierLabel()
            local becameVisible = not hudState.visible
            local now = GetGameTimer()

            local changedEnough = math.abs(health - hudState.health) > HUD_CHANGE_EPSILON
                or math.abs(stamina - hudState.stamina) > HUD_CHANGE_EPSILON
                or math.abs(hunger - hudState.hunger) > HUD_CHANGE_EPSILON
                or math.abs(thirst - hudState.thirst) > HUD_CHANGE_EPSILON
                -- Each wellbeing comparison below short-circuits on its own
                -- enabled flag BEFORE ever touching hudState's (possibly
                -- nil, if disabled) slot for that field — see
                -- WELLBEING_ELEMENT_ENABLED's own comment above.
                or (WELLBEING_ELEMENT_ENABLED.fatigue and math.abs(fatigue - hudState.fatigue) > HUD_CHANGE_EPSILON)
                or (WELLBEING_ELEMENT_ENABLED.mood and math.abs(mood - hudState.mood) > HUD_CHANGE_EPSILON)
                or (WELLBEING_ELEMENT_ENABLED.fearStress and math.abs(fearStress - hudState.fearStress) > HUD_CHANGE_EPSILON)
                or (WELLBEING_ELEMENT_ENABLED.injury and math.abs(injury - hudState.injury) > HUD_CHANGE_EPSILON)
                or (WELLBEING_ELEMENT_ENABLED.distraction and distracted ~= hudState.distracted)
                or xpTierLabel ~= hudState.xpTierLabel
            local heartbeatDue = (now - hudState.lastPushAt) >= HUD_HEARTBEAT_MS

            -- becameVisible short-circuits straight to a push (design note
            -- §5.5's false -> true immediate-push rule), independent of
            -- both the epsilon check and the heartbeat ceiling.
            if becameVisible or changedEnough or heartbeatDue then
                PushVitals(true, health, stamina, hunger, thirst, fatigue, mood, fearStress, injury, distracted, xpTierLabel)
            end

            Wait(HUD_POLL_TICK_MS) -- design note §5.1: active poll cadence while visible
        end
    end
end)
