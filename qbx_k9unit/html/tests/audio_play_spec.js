/*
    html/tests/audio_play_spec.js

    Covers `audio:play` (handleAudioPlay/loadSoundBuffer/ensureAudioContext/
    sanitizeSoundKey/clampGain in html/app.js) against the REAL
    html/sounds/ directory contents, not a synthetic always-ok/always-404
    stand-in -- see sandbox.js's realSoundsFetch(). As of this task:

        html/sounds/bark.ogg            EXISTS  -> the 200/decode-success path
        html/sounds/bark_alert.ogg      MISSING -> the 404 path (client/audio.lua's SOUND_NAME_TO_FILE_KEY)
        html/sounds/bark_aggressive.ogg MISSING -> the 404 path
        html/sounds/bark_calm.ogg       MISSING -> the 404 path
        html/sounds/growl_ambient.ogg   MISSING -> the 404 path (client/proximityaudio.lua's PROXIMITY_SOUND_NAME)

    i.e. exactly "one real file, four missing" per this task's own
    framing -- the degrade-to-silence path is the NORMAL, common-case
    outcome for 4 of this resource's 5 known sound keys today, not a rare
    edge case.
*/
'use strict';

const fs = require('fs');
const t = require('./testkit');
const { createHarness, waitFor, SOUNDS_DIR } = require('./sandbox');

t.test('sanity: html/sounds/ actually has exactly the "one real file, four missing" shape this spec assumes', () => {
    t.isTrue(fs.existsSync(`${SOUNDS_DIR}/bark.ogg`), 'bark.ogg must exist for the 200/decode-success tests below to be meaningful');
    for (const missing of ['bark_alert', 'bark_aggressive', 'bark_calm', 'growl_ambient']) {
        t.isFalse(fs.existsSync(`${SOUNDS_DIR}/${missing}.ogg`), `${missing}.ogg must NOT exist for the 404-path tests below to be meaningful`);
    }
});

t.test('audio:play against a real, existing file (bark.ogg) actually starts playback', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 0.6, loop: false });

    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: 'bark.ogg to start playing' });

    const ctx = h.getAudioContextInstance();
    t.isTrue(ctx._lastCreatedSource._started);
    t.isFalse(ctx._lastCreatedSource.loop, 'loop:false passed through');
    t.near(ctx._lastCreatedGain.gain.value, 0.6, 0.0001, 'initial gain applied to the GainNode');
});

t.test('audio:play against a missing file (bark_alert.ogg, the live 404 path) degrades to silence -- no source ever created, no throw', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 2, sound: 'bark_alert', gain: 1, loop: false });

    // Let the real (async) fetch/404 round-trip fully settle.
    await new Promise((r) => setTimeout(r, 200));

    const ctx = h.getAudioContextInstance();
    t.isDefined(ctx, 'AudioContext IS still constructed (ensureAudioContext runs before the fetch resolves)');
    t.isUndefined(ctx._lastCreatedSource, 'no BufferSourceNode is ever created for a 404\'d sound');
});

t.test('every one of the four currently-missing sound keys independently 404s and stays silent', async () => {
    const h = createHarness();
    let id = 100;
    for (const sound of ['bark_alert', 'bark_aggressive', 'bark_calm', 'growl_ambient']) {
        h.postMessage('audio:play', { id: id++, sound, gain: 1, loop: false });
    }
    await new Promise((r) => setTimeout(r, 200));

    const ctx = h.getAudioContextInstance();
    t.isUndefined(ctx._lastCreatedSource, 'none of the four missing files ever produced a playing source');
});

t.test('repeated plays of the SAME missing sound key only fetch once (soundBufferCache caches the negative result too)', async () => {
    const fetchUrls = [];
    const h = createHarness({
        fetchImpl: (url) => {
            fetchUrls.push(url);
            return Promise.resolve({ ok: false, status: 404, arrayBuffer: () => Promise.reject(new Error('must not be called')) });
        },
    });

    h.postMessage('audio:play', { id: 1, sound: 'bark_alert', gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: 'bark_alert', gain: 1, loop: false });
    h.postMessage('audio:play', { id: 3, sound: 'bark_alert', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    t.equals(fetchUrls.filter((u) => u === 'sounds/bark_alert.ogg').length, 1, 'exactly one fetch for three plays of the same missing key');
});

t.test('a decode failure (corrupt/unsupported file) also degrades silently, distinct from a 404, same observable outcome', async () => {
    const h = createHarness({
        audioBehavior: { decodeRejects: true },
        fetchImpl: () => Promise.resolve({ ok: true, status: 200, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) }),
    });

    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const ctx = h.getAudioContextInstance();
    t.isUndefined(ctx._lastCreatedSource, 'a decode failure never reaches source creation');
});

t.test('Web Audio unavailable in this runtime (no window.AudioContext/webkitAudioContext) -- silent no-op, and never even attempts the fetch', async () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0, 'ensureAudioContext() returning null must short-circuit BEFORE loadSoundBuffer/fetch is ever reached');
});

t.test('AudioContext construction throwing degrades silently AND is sticky (never retried on a later audio:play)', async () => {
    const h = createHarness({ audioBehavior: { throwOnConstruct: true } });

    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    t.equals(h.AudioContextCtor._constructCount(), 1, 'construction is attempted once, then the sticky failure flag prevents any retry');
    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0);
});

t.test('id undefined/null is rejected before any Web Audio work happens at all', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: undefined, sound: 'bark', gain: 1, loop: false });
    h.postMessage('audio:play', { id: null, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    t.isUndefined(h.getAudioContextInstance(), 'ensureAudioContext() must never even be called for a payload with no usable id');
});

t.test('id:0 (falsy but valid) IS accepted -- the guard must check `undefined`/`null` specifically, not general falsiness', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 0, sound: 'bark', gain: 1, loop: false });

    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: 'id:0 to still start playback' });
});

t.test('a non-string `sound` (missing/number/object) is rejected with no fetch attempted', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: undefined, gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: 42, gain: 1, loop: false });
    h.postMessage('audio:play', { id: 3, sound: {}, gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0);
});

t.test('an empty or whitespace-only sound key sanitizes to nothing and is rejected (no fetch)', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: '', gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: '!!!///...', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0, '"!!!///..." sanitizes to an empty string (every char stripped), same as sound:\'\'');
});

t.test('SANITIZATION: a path-traversal-shaped sound value can never escape html/sounds/ -- non [a-z0-9_-] characters are stripped, not encoded/escaped', async () => {
    const h = createHarness({
        // Note: this fetchImpl also serves the automatic hud:ready ack
        // fired at init -- filter to 'sounds/' below rather than asserting
        // on the raw call count, same posture as the other specs in this
        // file that check `.filter((c) => c.url.startsWith('sounds/'))`.
        fetchImpl: () => Promise.resolve({ ok: false, status: 404, arrayBuffer: () => Promise.reject(new Error('unused')) }),
    });

    h.postMessage('audio:play', { id: 1, sound: '../../etc/passwd', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundUrls = h.fetchCalls.map((c) => c.url).filter((u) => u.startsWith('sounds/'));
    t.equals(soundUrls.length, 1);
    t.equals(soundUrls[0], 'sounds/etcpasswd.ogg', 'every "." and "/" character is stripped entirely, never percent-decoded/traversed');
    t.notContains(soundUrls[0], '..');
    t.notContains(soundUrls[0], '/etc/');
});

t.test('SANITIZATION: uppercase/mixed-case sound names are lowercased to match the on-disk file (case-sensitive filesystems)', async () => {
    const h = createHarness({
        fetchImpl: () => Promise.resolve({ ok: true, status: 200, arrayBuffer: () => Promise.resolve(new ArrayBuffer(4)) }),
    });

    h.postMessage('audio:play', { id: 1, sound: 'BARK', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundUrls = h.fetchCalls.map((c) => c.url).filter((u) => u.startsWith('sounds/'));
    t.equals(soundUrls[0], 'sounds/bark.ogg');
});

t.test('GAIN CLAMPING: values outside [0,1] and non-numeric values all clamp/coerce correctly on audio:play', async () => {
    const cases = [
        [2, 1], [-5, 0], ['abc', 0], [undefined, 0], [null, 0], [0.35, 0.35], [1, 1], [0, 0],
    ];

    for (const [rawGain, expectedGain] of cases) {
        const h = createHarness();
        h.postMessage('audio:play', { id: 1, sound: 'bark', gain: rawGain, loop: false });
        await waitFor(() => {
            const ctx = h.getAudioContextInstance();
            return !!(ctx && ctx._lastCreatedGain);
        }, { label: `gain ${JSON.stringify(rawGain)} to produce a GainNode` });

        const ctx = h.getAudioContextInstance();
        t.near(ctx._lastCreatedGain.gain.value, expectedGain, 0.0001, `raw gain ${JSON.stringify(rawGain)} -> ${expectedGain}`);
    }
});

t.test('loop:true is passed through to the BufferSourceNode\'s .loop property', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: true });
    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: 'looping bark to start' });

    t.isTrue(h.getAudioContextInstance()._lastCreatedSource.loop);
});

t.test('a construction/start failure inside the async continuation (e.g. an exhausted AudioContext) degrades silently, no unhandled rejection', async () => {
    const unhandled = [];
    const onUnhandled = (r) => unhandled.push(r);
    process.on('unhandledRejection', onUnhandled);

    try {
        const h = createHarness({ audioBehavior: { startThrows: true } });
        h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });

        await waitFor(() => {
            const ctx = h.getAudioContextInstance();
            // start() throws synchronously inside the try block -- the
            // source object still gets constructed via createBufferSource
            // before .start() is called and throws.
            return !!(ctx && ctx._lastCreatedSource);
        }, { label: 'source construction attempt' });

        await new Promise((r) => setImmediate(r));
        t.equals(unhandled.length, 0, 'the try/catch inside handleAudioPlay\'s async continuation must itself catch this, not leak it as an unhandled rejection');
    } finally {
        process.removeListener('unhandledRejection', onUnhandled);
    }
});

t.test('RACE: an audio:stop for the same id arriving WHILE the fetch/decode is still in flight prevents playback from ever starting', async () => {
    let releaseFetch;
    const gate = new Promise((resolve) => { releaseFetch = resolve; });

    const h = createHarness({
        fetchImpl: async (url) => {
            await gate; // held open until the test explicitly releases it, simulating a slow load
            return { ok: true, status: 200, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) };
        },
    });

    h.postMessage('audio:play', { id: 42, sound: 'bark', gain: 1, loop: false });
    // The fetch is still pending (gated) -- 'audio:stop' for the SAME id
    // arrives before there is anything yet to stop, per app.js's own
    // documented stoppedBeforeStart mechanism.
    h.postMessage('audio:stop', { id: 42 });

    releaseFetch();
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const ctx = h.getAudioContextInstance();
    t.isDefined(ctx, 'AudioContext was still constructed (ensureAudioContext runs synchronously before the async load)');
    t.isUndefined(ctx._lastCreatedSource, 'playback must never start once a stop raced ahead of the load finishing');
});

t.run();
