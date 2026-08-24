/*
    qbx_k9unit/html/app.js

    ======================================================================
    WIRED, BUT STILL FEATURE-FLAGGED OFF — this file is no longer unwired
    scaffolding. As of this commit:

      1. fxmanifest.lua has a `ui_page 'html/index.html'` entry and a
         `files { 'html/index.html', 'html/style.css', 'html/app.js' }`
         block — this page loads for real in-game now.
      2. `client/hud.lua` exists — it registers the `hud:ready`
         RegisterNUICallback handler this file's fetch() calls into, and
         runs the ~250ms poll/push thread (design note §5) that calls
         SendNUIMessage with the `hud:updateVitals` action below.
      3. `Config.Features.HealthStaminaHUD` is STILL `false` in
         config.lua (its shipped default, deliberately left untouched) —
         client/hud.lua gates its own NUI callback registration and poll
         thread on this flag at file-load time (its own header's "GATING"
         note), so with the flag off, `hud:ready` has nothing registered
         to call into and no `hud:updateVitals` push ever arrives. This
         page loading is not the same thing as the feature being live —
         flip Config.Features.HealthStaminaHUD to actually activate it.

    This page and client/hud.lua were built directly off
    phase2_notes/phase4_hud_bridge_design.md (naming/payload/focus/cadence
    — authoritative) and phase2_notes/phase4_hud_early_design.md (earlier
    exploratory pass, superseded on those points). See
    phase4_hud_bridge_design.md §6 for the resolved visibility-gate
    predicate (`CanShowK9UI()`) client/hud.lua now actually implements.
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

    ======================================================================
    AUDIO BRIDGE CONTRACT (added this pass — must match client/audio.lua
    exactly, byte-for-byte, same "a name that doesn't match on both sides
    just hangs or drops silently" risk as the HUD contract above). See
    client/audio.lua's own header for the full authoritative background
    (phase2_notes/dependency_and_audio_status.md,
    phase2_notes/phase5_remaining_features_research.md §1) — short version:
    this resource's bark audio has always been a placeholder RAGE soundset
    name that resolves to a harmless no-op; this bridge is the plumbing
    that plays a REAL sound once a server operator drops one in, using
    Web Audio (a GainNode) for distance-based volume instead of a RAGE
    audio bank.

    Lua -> JS (SendNUIMessage), one-directional only — THERE IS NO
    JS -> Lua callback anywhere in this audio bridge (contrast 'hud:ready'
    above): every message below is fire-and-forget from client/audio.lua,
    and this file never calls back into Lua about whether a sound existed,
    played, or failed. That is a deliberate design choice (see
    client/audio.lua's header "WHAT THIS FILE DELIBERATELY DOES NOT DO"),
    not an oversight — this file's own job is to make every one of the
    three cases below (missing file, decode failure, Web Audio
    unavailable) degrade completely silently, with zero console output
    and zero thrown error, since a server that has not supplied any
    .ogg assets is the expected, normal state for every install of this
    resource today.

        { action: 'audio:play', data: { id: <number>, sound: <string>, gain: <number 0-1>, loop: <boolean> } }
            Starts (or attempts to start) playback of html/sounds/<sound>.ogg
            at the given initial gain. `sound` is a bare key with no
            extension and no path separators (sanitized on this side
            regardless of what Lua sends — see sanitizeSoundKey() below);
            the actual file, if any, must live at html/sounds/<sound>.ogg
            for a `files{}` glob entry to have bundled it. `id` is an
            opaque number this page never interprets, only echoes back via
            onended bookkeeping and uses to route a later `audio:setGain`/
            `audio:stop` to the right in-flight sound.

        { action: 'audio:setGain', data: { id: <number>, gain: <number 0-1> } }
            Smoothly ramps an ALREADY-PLAYING sound's gain toward a new
            value over AUDIO_GAIN_RAMP_SECONDS, via GainNode's own
            `linearRampToValueAtTime` — the concrete Web Audio capability
            this whole bridge exists to use (continuous, click-free volume
            scripting with no dependency on any FiveM native or authored
            RTPC variable). A no-op if `id` doesn't currently refer to an
            active sound (already ended, never started, or a typo'd id) —
            never an error.

        { action: 'audio:stop', data: { id: <number> } }
            Stops an active sound immediately. Also a no-op if `id`
            doesn't refer to an active sound, EXCEPT for one specific race:
            if `id`'s own 'audio:play' is still asynchronously
            fetching/decoding its file when this arrives, this records
            that fact so playback never starts at all once the load
            finishes — see stoppedBeforeStart below and handleAudioStop's
            own comment for why this is needed (loading is async; a stop
            can legitimately arrive before there is anything yet to stop).

    CONFIDENCE NOTE — HONEST, NOT INDEPENDENTLY VERIFIED IN-ENGINE THIS
    PASS: this bridge assumes FiveM's NUI (CEF-based) browser context lets
    a Web Audio `AudioContext` actually produce sound without requiring the
    same "user gesture to unlock audio" step a normal desktop Chrome tab
    enforces under its autoplay policy. This is a REASONABLE, but not a
    FIRST-PARTY-CONFIRMED, assumption: it rests on community precedent —
    multiple independent, real, in-use FiveM NUI-audio resources
    (plunkettscott/interact-sound, Xogy/xsound, QBus-xyz/xyz-3dsound,
    Virgildev/v-k9's own use of interact-sound for bark playback — see
    phase2_notes/dependency_and_audio_status.md and
    phase2_notes/phase5_remaining_features_research.md §1 for the direct
    reads backing each of these) freely playing audio from NUI pages with
    no documented unlock/gesture workaround anywhere in any of them — but
    no FiveM client was available in this environment to actually load
    this page in-engine and confirm sound is audible this pass. If it
    turns out CEF's NUI runtime DOES enforce an autoplay-gesture policy
    after all, ensureAudioContext()'s best-effort `.resume()` call below
    would not be sufficient on its own, and this would need a real fix
    (e.g. some deliberate, non-audio user interaction to unlock — if even
    that is possible on a page with pointer-events: none throughout, which
    is itself a real open question this pass could not close). Flagging
    this plainly rather than presenting it as verified.

    GRACEFUL DEGRADATION — the other hard requirement this bridge is built
    around: a missing/absent .ogg file must NEVER throw, log an error, or
    warn to the console, because "no assets supplied yet" is the actual
    shipped state of every install of this resource today, not an edge
    case. Every function below that can fail (fetch, decodeAudioData,
    AudioContext construction, node construction/start/stop) is wrapped so
    its failure path is identical in observable effect to "the sound
    simply didn't play" — nothing more. See sanitizeSoundKey/
    loadSoundBuffer/handleAudioPlay's own comments for exactly which
    failure maps to which no-op.

    NO SetNuiFocus HERE EITHER — same rule as the HUD contract above,
    unchanged by this addition: audio playback has no DOM element, no
    visual affordance, and nothing to click — there is no reason this
    would ever need focus, and none is requested anywhere in this file.
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

    // ------------------------------------------------------------------
    // AUDIO BRIDGE — see this file's header "AUDIO BRIDGE CONTRACT" block
    // for the full payload/behavior contract this section implements, and
    // client/audio.lua for the Lua-side counterpart. Everything below is
    // additive to the HUD code above/below it — no HUD behavior changes.
    // ------------------------------------------------------------------

    /** Seconds a GainNode ramp (audio:setGain) takes to reach its target —
     * long enough to avoid an audible "step"/zipper artifact, short enough
     * that a fast-changing distance still feels responsive. Code-local
     * tuning constant, same posture as client/audio.lua's own
     * AUDIO_MAX_DISTANCE/AUDIO_GAIN_POLL_MS (file-local, not exposed via
     * the message payload — every 'audio:setGain' message uses this same
     * ramp length). */
    var AUDIO_GAIN_RAMP_SECONDS = 0.3;

    /** Lazily-constructed singleton — this page's `ui_page` is loaded once
     * for the entire client session (never re-opened like a modal), so one
     * AudioContext for the page's whole lifetime is correct, not a leak.
     * @type {AudioContext|null} */
    var audioCtx = null;

    /** Sticky failure flag — if constructing an AudioContext ever fails
     * once (e.g. Web Audio genuinely unavailable in this runtime), don't
     * retry the constructor on every subsequent 'audio:play' message; just
     * keep degrading silently. */
    var audioCtxConstructionFailed = false;

    /** key (sanitized sound name, no extension) -> Promise<AudioBuffer|null>.
     * Cached INCLUDING failed/negative results, so a repeatedly-triggered
     * missing sound (the expected common case on a server with no assets
     * yet) never re-fetches or re-decodes more than once per key for this
     * page's whole lifetime.
     * @type {Record<string, Promise<AudioBuffer|null>>} */
    var soundBufferCache = {};

    /** id -> { source: AudioBufferSourceNode, gain: GainNode } for every
     * currently-playing sound this page knows about.
     * @type {Record<number, { source: AudioBufferSourceNode, gain: GainNode }>} */
    var activeSounds = {};

    /** ids that received an 'audio:stop' while their matching 'audio:play'
     * was still asynchronously loading/decoding — checked (and cleared)
     * the moment that load settles, so playback never starts for an id
     * that was already told to stop. Without this, a play/stop pair that
     * arrives in quick succession could still audibly start playing,
     * because the buffer fetch/decode that 'audio:play' kicks off is
     * asynchronous and may not have resolved yet when 'audio:stop' for the
     * SAME id arrives moments later.
     * @type {Record<number, boolean>} */
    var stoppedBeforeStart = {};

    /**
     * Sanitizes a sound key defensively, independent of whatever
     * client/audio.lua sends — this page never trusts the other side of
     * an NUI bridge to have already validated its own payload (same
     * standing convention this file's clampPercent already follows for
     * the HUD payload). Strips everything but lowercase alphanumerics/
     * underscore/hyphen, so this can never be used to request a path
     * outside html/sounds/ (no '/', no '..', no query string) even though
     * nothing reaching this function today originates from untrusted
     * player input (see client/audio.lua's header on soundName's actual
     * provenance) — defense in depth, not a response to a live gap.
     * @param {*} raw
     * @returns {string|null} sanitized key, or null if nothing usable remains
     */
    function sanitizeSoundKey(raw) {
        if (typeof raw !== 'string') return null;
        var key = raw.toLowerCase().replace(/[^a-z0-9_-]/g, '');
        return key.length > 0 ? key : null;
    }

    /**
     * Clamps a gain value into Web Audio's meaningful 0-1 range, coercing
     * anything non-numeric to 0 (silent) rather than letting a malformed
     * payload reach a GainNode as NaN, which would otherwise throw.
     * @param {*} raw
     * @returns {number}
     */
    function clampGain(raw) {
        var n = Number(raw);
        if (!isFinite(n)) return 0;
        if (n < 0) return 0;
        if (n > 1) return 1;
        return n;
    }

    /**
     * Returns this page's singleton AudioContext, constructing it on first
     * use. Returns null (never throws) if Web Audio isn't available in
     * this runtime at all, or if construction failed once already — every
     * caller below already treats a null return as "silently do nothing,"
     * which is the correct behavior for both cases.
     * @returns {AudioContext|null}
     */
    function ensureAudioContext() {
        if (audioCtx) return audioCtx;
        if (audioCtxConstructionFailed) return null;

        try {
            var Ctor = window.AudioContext || window.webkitAudioContext;
            if (!Ctor) {
                audioCtxConstructionFailed = true;
                return null;
            }
            audioCtx = new Ctor();
        } catch (err) {
            audioCtxConstructionFailed = true;
            return null;
        }

        // Best-effort resume for a context that starts life 'suspended'
        // pending a user-gesture unlock — a real desktop-browser autoplay
        // policy behavior. See this file's header "CONFIDENCE NOTE" for
        // this bridge's honest, NOT independently in-engine-verified
        // assumption that FiveM's own NUI/CEF runtime does not enforce
        // this same restriction. This call is harmless either way:
        // resume() on an already-running context is a documented no-op
        // success, and a refused/failed resume() degrades to exactly the
        // same "no audible sound, no error" outcome a missing file already
        // produces below.
        if (audioCtx.state === 'suspended') {
            audioCtx.resume().catch(function () {
                // Swallowed deliberately — see comment above.
            });
        }

        return audioCtx;
    }

    /**
     * Fetches + decodes html/sounds/<key>.ogg, caching the resulting
     * promise (including a resolved-to-null failure) so this is attempted
     * at most once per key for this page's lifetime. Every failure mode —
     * a 404 (the expected, normal case on a server with no assets
     * supplied yet), a network error, or a decode failure on a corrupt/
     * unsupported file — resolves to `null` rather than rejecting, and
     * produces zero console output, per this file's header "GRACEFUL
     * DEGRADATION" requirement.
     * @param {AudioContext} ctx
     * @param {string} key already-sanitized via sanitizeSoundKey
     * @returns {Promise<AudioBuffer|null>}
     */
    function loadSoundBuffer(ctx, key) {
        if (Object.prototype.hasOwnProperty.call(soundBufferCache, key)) {
            return soundBufferCache[key];
        }

        var promise = fetch('sounds/' + key + '.ogg')
            .then(function (resp) {
                if (!resp.ok) return null; // e.g. 404 — the expected, normal case until real assets are supplied
                return resp.arrayBuffer();
            })
            .then(function (buf) {
                if (!buf) return null;
                return ctx.decodeAudioData(buf);
            })
            .catch(function () {
                // Any failure anywhere in the chain above (network error,
                // malformed/corrupt/unsupported file, decode failure)
                // degrades to the same "no sound" outcome as a plain 404 —
                // deliberately no console output here.
                return null;
            });

        soundBufferCache[key] = promise;
        return promise;
    }

    /**
     * Handles one `audio:play` payload — see this file's header "AUDIO
     * BRIDGE CONTRACT" for the full shape. Starts playback once (and only
     * if) the requested file both exists and decodes successfully; every
     * other outcome (bad payload, Web Audio unavailable, missing/corrupt
     * file, a matching 'audio:stop' that raced ahead of this async load)
     * is a silent no-op.
     * @param {{ id: number, sound: string, gain: number, loop: boolean }} data
     */
    function handleAudioPlay(data) {
        if (!data || data.id === undefined || data.id === null) return;

        var id = data.id;
        var key = sanitizeSoundKey(data.sound);
        if (!key) return;

        var ctx = ensureAudioContext();
        if (!ctx) return; // Web Audio unavailable in this runtime — silent degrade

        var gainValue = clampGain(data.gain);
        var loop = data.loop === true;

        loadSoundBuffer(ctx, key).then(function (buffer) {
            var wasStoppedEarly = !!stoppedBeforeStart[id];
            delete stoppedBeforeStart[id];

            if (!buffer || wasStoppedEarly) return;

            try {
                var gainNode = ctx.createGain();
                gainNode.gain.value = gainValue;
                gainNode.connect(ctx.destination);

                var source = ctx.createBufferSource();
                source.buffer = buffer;
                source.loop = loop;
                source.connect(gainNode);

                source.onended = function () {
                    // Fires both for a natural end (non-looping playback
                    // finishing) AND for an explicit .stop() call
                    // (handleAudioStop below already deletes this entry
                    // itself too — deleting an already-absent key here is
                    // a harmless no-op, so there is no double-cleanup bug
                    // either order this fires in).
                    delete activeSounds[id];
                };

                activeSounds[id] = { source: source, gain: gainNode };
                source.start(0);
            } catch (err) {
                // Playback construction/start failing (e.g. an exhausted
                // or closed AudioContext) degrades the same way a missing
                // file does — no sound, no console output, no error
                // visible anywhere a player would see it.
                delete activeSounds[id];
            }
        });
    }

    /**
     * Handles one `audio:setGain` payload — smoothly ramps an
     * already-playing sound's gain via GainNode.gain.linearRampToValueAtTime,
     * the concrete Web Audio capability this whole bridge exists to use
     * (see this file's header). A no-op if `id` isn't currently active.
     * @param {{ id: number, gain: number }} data
     */
    function handleAudioSetGain(data) {
        if (!data || !audioCtx) return;

        var active = activeSounds[data.id];
        if (!active) return; // already ended, never started, or a stale/unknown id — silent no-op

        var target = clampGain(data.gain);

        try {
            var now = audioCtx.currentTime;
            active.gain.gain.cancelScheduledValues(now);
            active.gain.gain.setValueAtTime(active.gain.gain.value, now);
            active.gain.gain.linearRampToValueAtTime(target, now + AUDIO_GAIN_RAMP_SECONDS);
        } catch (err) {
            // Same silent-degrade posture as everywhere else in this bridge.
        }
    }

    /**
     * Handles one `audio:stop` payload. See this file's header contract
     * note on the one real race this guards: 'audio:play' triggers an
     * ASYNC fetch/decode before anything actually starts playing, so a
     * fast-following 'audio:stop' for the same id can legitimately arrive
     * before there is an active sound to stop yet — recorded in
     * stoppedBeforeStart so handleAudioPlay's own async continuation
     * checks it before ever calling start().
     * @param {{ id: number }} data
     */
    function handleAudioStop(data) {
        if (!data) return;

        var id = data.id;
        var active = activeSounds[id];

        if (!active) {
            stoppedBeforeStart[id] = true;
            return;
        }

        delete activeSounds[id];

        try {
            active.source.stop();
        } catch (err) {
            // Already stopped/ended — harmless; onended (above) is the
            // normal-path cleanup, this catch only guards the double-stop
            // edge.
        }
        try {
            active.source.disconnect();
            active.gain.disconnect();
        } catch (err) {
            // Already disconnected — harmless.
        }
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
                case 'audio:play':
                    handleAudioPlay(msg.data);
                    break;
                case 'audio:setGain':
                    handleAudioSetGain(msg.data);
                    break;
                case 'audio:stop':
                    handleAudioStop(msg.data);
                    break;
                default:
                    // Unknown action: ignore rather than throw. Every NUI
                    // surface this page listens for uses its own
                    // `<surface>:<verbNoun>` prefix per
                    // phase4_hud_bridge_design.md §1 ('hud:'/'audio:' so
                    // far) — this default branch is what a THIRD, not-yet-
                    // built surface's messages would silently fall into
                    // until it adds its own case here.
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
