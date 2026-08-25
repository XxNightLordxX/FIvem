/*
    html/tests/audio_setgain_stop_spec.js

    Covers `audio:setGain` (handleAudioSetGain) and `audio:stop`
    (handleAudioStop) in html/app.js -- both only ever reachable in a
    meaningful way AFTER a prior `audio:play` has actually started
    something (client/audio.lua's own PlayK9Sound/StopK9Sound contract:
    `id` addresses "the exact playback instance", so both a not-yet-started
    and an already-ended id must be silent no-ops, never an error).
*/
'use strict';

const t = require('./testkit');
const { createHarness, waitFor } = require('./sandbox');

async function playAndWaitStarted(h, id, opts) {
    h.postMessage('audio:play', Object.assign({ id, sound: 'bark', gain: 0.5, loop: false }, opts));
    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: `id ${id} to start playing` });
}

t.test('audio:setGain before any audio:play has ever run is a total no-op (audioCtx is still null -- never even constructed)', async () => {
    const h = createHarness();
    h.postMessage('audio:setGain', { id: 1, gain: 0.9 });
    await new Promise((r) => setImmediate(r));

    t.isUndefined(h.getAudioContextInstance(), 'handleAudioSetGain\'s own `if (!data || !audioCtx) return` must short-circuit before ever touching Web Audio');
});

t.test('audio:setGain for an unknown id (after Web Audio IS already in use) is a silent no-op, does not touch the wrong sound', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 1);
    const ctx = h.getAudioContextInstance();
    const originalRampCalls = ctx._lastCreatedGain.gain._rampCalls.length;

    h.postMessage('audio:setGain', { id: 999, gain: 0.1 });
    await new Promise((r) => setImmediate(r));

    t.equals(ctx._lastCreatedGain.gain._rampCalls.length, originalRampCalls, 'no ramp scheduled for an id that is not active');
});

t.test('audio:setGain for the active id schedules a linearRampToValueAtTime toward the (clamped) target gain', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 7);
    const ctx = h.getAudioContextInstance();

    h.postMessage('audio:setGain', { id: 7, gain: 0.2 });
    await new Promise((r) => setImmediate(r));

    const ramps = ctx._lastCreatedGain.gain._rampCalls;
    t.equals(ramps.length, 1);
    t.near(ramps[0].v, 0.2, 0.0001);
    t.isTrue(ctx._lastCreatedGain.gain._cancelCalls >= 1, 'cancelScheduledValues called before scheduling the new ramp');
});

t.test('audio:setGain clamps out-of-range/non-numeric gain the same way audio:play does', async () => {
    const cases = [[5, 1], [-1, 0], ['nope', 0]];
    for (const [rawGain, expectedGain] of cases) {
        const h = createHarness();
        await playAndWaitStarted(h, 1);
        const ctx = h.getAudioContextInstance();

        h.postMessage('audio:setGain', { id: 1, gain: rawGain });
        await new Promise((r) => setImmediate(r));

        const ramps = ctx._lastCreatedGain.gain._rampCalls;
        t.equals(ramps.length, 1, `one ramp scheduled for gain ${JSON.stringify(rawGain)}`);
        t.near(ramps[0].v, expectedGain, 0.0001, `raw gain ${JSON.stringify(rawGain)} -> ${expectedGain}`);
    }
});

t.test('audio:setGain swallows a linearRampToValueAtTime failure silently (no throw reaches the message dispatcher)', async () => {
    const h = createHarness({ audioBehavior: { rampThrows: true } });
    await playAndWaitStarted(h, 1);

    // If handleAudioSetGain's own try/catch were missing, this postMessage
    // call itself would throw synchronously (linearRampToValueAtTime
    // throws synchronously inside handleAudioSetGain, unlike the async
    // handleAudioPlay path) -- reaching the next line at all is the test.
    h.postMessage('audio:setGain', { id: 1, gain: 0.5 });
    t.isTrue(true, 'postMessage returned normally despite the simulated ramp failure');
});

t.test('audio:stop before any audio:play has ever run for that id is a silent no-op (also true when Web Audio is already active for OTHER ids)', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 1);
    h.postMessage('audio:stop', { id: 999 });
    await new Promise((r) => setImmediate(r));
    // The real (id:1) sound must be entirely unaffected.
    const ctx = h.getAudioContextInstance();
    t.isFalse(ctx._lastCreatedSource._stopped, 'stopping an unrelated id must not stop id 1\'s own source');
});

t.test('audio:stop for an active id actually stops the source and disconnects both nodes', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 5);
    const ctx = h.getAudioContextInstance();

    h.postMessage('audio:stop', { id: 5 });
    await new Promise((r) => setImmediate(r));

    t.isTrue(ctx._lastCreatedSource._stopped, 'source.stop() was called');
    t.isTrue(ctx._lastCreatedSource._disconnected, 'source.disconnect() was called');
    t.isTrue(ctx._lastCreatedGain._disconnected, 'gain.disconnect() was called');
});

t.test('a second audio:stop for the same (already-stopped) id is a harmless no-op, never a double-stop/double-disconnect throw reaching the caller', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 5);

    h.postMessage('audio:stop', { id: 5 });
    await new Promise((r) => setImmediate(r));
    // Second stop for the same id: by now activeSounds[5] has already been
    // deleted by the first call, so this is the "unknown id" no-op branch,
    // NOT a second real source.stop() call -- exercised directly here to
    // prove it doesn't throw either.
    h.postMessage('audio:stop', { id: 5 });
    await new Promise((r) => setImmediate(r));
    t.isTrue(true, 'no throw from either stop call');
});

t.test('source.stop() itself throwing (e.g. the sound already ended naturally at the exact moment stop arrives) is caught -- disconnect is still attempted', async () => {
    const h = createHarness({ audioBehavior: { stopThrows: true } });
    await playAndWaitStarted(h, 1);
    const ctx = h.getAudioContextInstance();

    h.postMessage('audio:stop', { id: 1 });
    await new Promise((r) => setImmediate(r));

    t.isFalse(ctx._lastCreatedSource._stopped, 'the simulated stop() failure means _stopped never actually flips true');
    t.isTrue(ctx._lastCreatedSource._disconnected, 'disconnect() is attempted in its OWN try/catch, independent of whether stop() succeeded');
    t.isTrue(ctx._lastCreatedGain._disconnected);
});

t.test('gain.disconnect() itself throwing is also caught (the second, independent try/catch in handleAudioStop)', async () => {
    const h = createHarness({ audioBehavior: { disconnectThrows: true } });
    await playAndWaitStarted(h, 1);

    h.postMessage('audio:stop', { id: 1 });
    // No throw should escape to here.
    t.isTrue(true, 'postMessage returned normally despite the simulated gain.disconnect() failure');
});

t.test('audio:setGain and audio:stop both no-op cleanly on a null/undefined data payload', async () => {
    const h = createHarness();
    h.postMessage('audio:setGain', null);
    h.postMessage('audio:setGain', undefined);
    h.postMessage('audio:stop', null);
    h.postMessage('audio:stop', undefined);
    await new Promise((r) => setImmediate(r));
    t.isTrue(true, 'no throw for any of the four calls above');
});

t.run();
