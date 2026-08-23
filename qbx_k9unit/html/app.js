/*
    qbx_k9unit/html/app.js

    ======================================================================
    UNWIRED SCAFFOLDING — DO NOT MISTAKE THIS FILE'S EXISTENCE FOR THE
    FEATURE BEING LIVE.

    This is Phase 4's passive vitality HUD (health/stamina/hunger/thirst
    for the active K9), scaffolded ahead of its Lua-side wiring per
    phase2_notes/phase4_hud_bridge_design.md and
    phase2_notes/phase4_hud_early_design.md. As of this commit, NONE of
    the following exist yet, and this page cannot actually load or
    receive anything in-game until they do:

      1. fxmanifest.lua has no `ui_page 'html/index.html'` entry and no
         `files { 'html/index.html', 'html/style.css', 'html/app.js' }`
         block — this resource has zero NUI wiring in its manifest today.
      2. `client/hud.lua` (the Lua-side ~250ms poll/push thread that would
         call SendNUIMessage with the `hud:updateVitals` action below)
         does not exist yet.
      3. `Config.Features.HealthStaminaHUD` is `false` in config.lua —
         even once #1/#2 land, the feature stays off until this flips.

    Do NOT wire this into fxmanifest.lua, and do NOT write
    `client/hud.lua`, as part of whatever task references this file,
    unless explicitly asked to move past scaffolding — this file exists
    "in the tree, not yet activated," mirroring how Phase 2's own Lua
    files were scaffolded ahead of their config/manifest wiring landing.
    ======================================================================

    CONTRACT (must match client/hud.lua exactly, byte-for-byte, once it's
    written — this is the single most common silent-failure point in NUI
    code: a name that doesn't match on both sides just hangs or drops
    silently, no error thrown on either side):

    JS -> Lua (RegisterNUICallback), fire-and-forget, no meaningful
    response body expected:
        fetch(`https://${GetParentResourceName()}/hud:ready`, ...)

    Lua -> JS (SendNUIMessage), the one and only ongoing push, delivered
    as a `message` event on `window`:
        {
          action: 'hud:updateVitals',
          data: {
            visible: <boolean>,
            health:  <number>,  // 0-100, normalized percent
            stamina: <number>,  // 0-100
            hunger:  <number>,  // 0-100
            thirst:  <number>,  // 0-100
          }
        }

    Naming note (see phase4_hud_bridge_design.md §1): these do NOT use the
    `qbx_k9unit:client:`/`qbx_k9unit:server:` prefix convention the rest
    of this codebase's RegisterNetEvent/TriggerServerEvent names use.
    That prefix exists to avoid colliding in FiveM's GLOBAL net-event
    namespace across every resource on the server — a concern that does
    not apply here: `hud:ready` is only ever reached via
    `GetParentResourceName()` in the fetch URL (already resource-scoped),
    and `hud:updateVitals` is a `message` event delivered only inside this
    resource's own NUI page (nothing outside qbx_k9unit can send into it,
    and this page never listens for any other resource's messages). Do
    not "fix" these names to add a qbx_k9unit: prefix — that would be
    redundant, not a bug fix.

    NO SetNuiFocus, ANYWHERE, EVER, for this surface (see
    phase4_hud_bridge_design.md §4 / phase4_hud_early_design.md §3): this
    is a passive, always-visible-while-relevant overlay with zero
    player-driven interaction — no buttons, no dismiss, nothing to click
    or type into. There is therefore no escape/close-path handling here
    either (no Escape keylistener, no close callback) — that entire bug
    class structurally cannot occur on a surface that never grabs focus in
    the first place. If a future revision adds an actual interactive
    element to this page, that is a signal to STOP and re-decide the
    whole focus question, not to bolt SetNuiFocus onto this file's
    existing focus-free lifecycle.

    Push cadence (owned entirely by client/hud.lua, nothing for this file
    to implement): ~250ms poll with a per-field change-threshold so
    near-identical pushes are skipped, plus a ~1s heartbeat ceiling so a
    missed/dropped message self-heals within one second. This file only
    ever renders whatever `hud:updateVitals` payload it is handed — no
    client-side throttling/debouncing of incoming messages is needed or
    should be added here.
    ======================================================================
*/

(function () {
    'use strict';

    /** @type {Record<'health'|'stamina'|'hunger'|'thirst', { fill: HTMLElement, value: HTMLElement }>} */
    var statEls = {};
    var rootEl = null;

    /**
     * Clamp a value into the 0-100 range and coerce anything non-numeric
     * to 0 — defensive against a malformed/partial payload rather than
     * assuming the Lua side always sends well-formed numbers. UI-side
     * defensiveness only (this page never sends these values anywhere,
     * so there is no security concern here to defer to coder-security
     * about — see phase4_hud_bridge_design.md §3's "no server-authoritative
     * check anywhere in this specific bridge" note).
     * @param {*} raw
     * @returns {number}
     */
    function clampPercent(raw) {
        var n = Number(raw);
        if (!isFinite(n)) return 0;
        if (n < 0) return 0;
        if (n > 100) return 100;
        return n;
    }

    /**
     * Applies one stat's value to its bar fill width + numeric readout.
     * @param {'health'|'stamina'|'hunger'|'thirst'} stat
     * @param {*} rawValue
     */
    function applyStat(stat, rawValue) {
        var els = statEls[stat];
        if (!els) return; // TODO: should not happen once markup/JS agree; defensive no-op if it does

        var pct = clampPercent(rawValue);
        els.fill.style.width = pct + '%';
        els.value.textContent = Math.round(pct);
    }

    /**
     * Handles one `hud:updateVitals` payload. Per
     * phase4_hud_bridge_design.md §3: `visible` and the four numeric
     * fields always arrive together in one message (never split), and
     * when `visible === false` the four numbers are ignored for
     * rendering (Lua still sends the last real known values alongside
     * `visible: false`, not zeroed out, specifically so a later
     * false->true flip doesn't show a stale-zero flash — but that's only
     * meaningful if this function actually skips rendering them while
     * hidden, so it does).
     * @param {{ visible: boolean, health: number, stamina: number, hunger: number, thirst: number }} data
     */
    function handleUpdateVitals(data) {
        if (!data || !rootEl) return;

        var visible = data.visible === true;
        rootEl.classList.toggle('hidden', !visible);
        rootEl.setAttribute('aria-hidden', visible ? 'false' : 'true');

        if (!visible) return; // don't bother touching bar DOM while hidden

        applyStat('health', data.health);
        applyStat('stamina', data.stamina);
        applyStat('hunger', data.hunger);
        applyStat('thirst', data.thirst);
    }

    /**
     * Sends the one-time `hud:ready` ack. This exists to solve the
     * classic NUI race: SendNUIMessage delivery is not queued or
     * retried — a message sent before this page's JS has attached its
     * `message` listener is simply lost, not buffered. Firing this
     * immediately after the listener below is attached (not before,
     * see init() ordering) lets client/hud.lua safely wait for this ack
     * before its first push, and push one immediate snapshot the moment
     * it arrives, instead of the HUD showing nothing until the next
     * scheduled ~1s heartbeat tick.
     *
     * cb({}) equivalent server-side (client/hud.lua's
     * RegisterNUICallback('hud:ready', ...) handler) MUST call its
     * callback even though this fetch's response body is never read here
     * — an uninvoked NUI callback leaves this fetch's promise hanging
     * forever, which is harmless here only because nothing below awaits
     * it, but is exactly the failure mode to avoid on the Lua side
     * regardless.
     */
    function sendReadyAck() {
        try {
            fetch('https://' + GetParentResourceName() + '/hud:ready', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify({}),
            }).catch(function () {
                // Swallowed deliberately: this page has no retry/backoff
                // story for a failed ack (nothing else in this scaffold
                // depends on the fetch's own success/failure locally —
                // client/hud.lua not existing yet is the expected reason
                // this fails during scaffolding). Once client/hud.lua
                // exists, a missing ack just means the HUD stays hidden
                // until its ~1s heartbeat (still bounded, not silently
                // broken forever).
            });
        } catch (err) {
            // GetParentResourceName() is only defined inside FiveM's NUI
            // (CEF) runtime. Swallow here so this file doesn't throw when
            // opened directly in a plain browser for local layout/CSS
            // preview during scaffolding — this is NOT a production
            // fallback path, just a dev-preview convenience.
        }
    }

    function init() {
        rootEl = document.getElementById('k9hud');
        statEls = {
            health: {
                fill: document.querySelector('[data-fill="health"]'),
                value: document.querySelector('[data-value="health"]'),
            },
            stamina: {
                fill: document.querySelector('[data-fill="stamina"]'),
                value: document.querySelector('[data-value="stamina"]'),
            },
            hunger: {
                fill: document.querySelector('[data-fill="hunger"]'),
                value: document.querySelector('[data-value="hunger"]'),
            },
            thirst: {
                fill: document.querySelector('[data-fill="thirst"]'),
                value: document.querySelector('[data-value="thirst"]'),
            },
        };

        // Attach the message listener FIRST, only THEN send the ready
        // ack — this ordering is the entire point of the handshake (see
        // sendReadyAck's own comment). Reversing this order would
        // reintroduce the exact race hud:ready exists to close.
        window.addEventListener('message', function (event) {
            var msg = event.data;
            if (!msg || typeof msg.action !== 'string') return;

            switch (msg.action) {
                case 'hud:updateVitals':
                    handleUpdateVitals(msg.data);
                    break;
                default:
                    // Unknown action: ignore rather than throw. Other NUI
                    // surfaces in this resource (none exist yet) would
                    // use their own `<surface>:<verbNoun>` prefix per
                    // phase4_hud_bridge_design.md §1, so this page simply
                    // has nothing else to listen for today.
                    break;
            }
        });

        sendReadyAck();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
