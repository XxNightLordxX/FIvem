/*
    html/tests/hud_wellbeing_shape_spec.js

    Covers the wellbeing/xpTier extension to `hud:updateVitals`
    (applyGatedBarStat/applyDistractionStatus/applyXPTierStatus in
    html/app.js), specifically:

      1. The DEFAULT config case -- every wellbeing feature flag off, so
         `wellbeing`/`xpTier` are tables with every key ABSENT
         (client/hud.lua's own header: "A key's ABSENCE... is how a
         disabled feature... is signaled").
      2. The `{}` vs `[]` wire-shape question this task calls out by name:
         client/hud.lua's PushVitals() applies a `setmetatable(..., {
         __jsontype = 'object' })` hint specifically so dkjson encodes an
         empty wellbeing/xpTier table as `{}` on the wire, not `[]` --
         PROVING html/app.js's own `wellbeing[stat]`/`wellbeing.distracted`
         bracket/dot property access genuinely tolerates BOTH shapes
         (older Lua without that fix would have sent `[]`), so the fix is
         a wire-hygiene/downstream-consumer improvement, not something
         current app.js needed to avoid breaking.
      3. Partial presence (some keys present, others absent).
      4. Full presence (every gated row visible with a real value).
      5. The exact type-strictness contract each apply*Status() function
         enforces (`typeof rawValue === 'number'` / `... === 'boolean'` /
         `typeof ... === 'string' && length > 0`) -- a value present but
         of the WRONG type must still hide the row, exactly like an absent
         key would.
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

function freshHarnessNoAudio() {
    return createHarness({ AudioContextCtor: undefined });
}

const GATED_BAR_STATS = ['fatigue', 'mood', 'fearStress', 'injury'];

function assertAllGatedRowsHidden(h, message) {
    for (const stat of GATED_BAR_STATS) {
        t.isTrue(h.getBarRow(stat).row.classList.contains('k9hud-row--hidden'), `${stat} row hidden: ${message}`);
    }
    t.isTrue(h.getStatusRow('distraction').row.classList.contains('k9hud-row--hidden'), `distraction row hidden: ${message}`);
    t.isTrue(h.getStatusRow('xpTier').row.classList.contains('k9hud-row--hidden'), `xpTier row hidden: ${message}`);
}

function baseVitals(extra) {
    return Object.assign({ visible: true, health: 100, stamina: 100, hunger: 100, thirst: 100 }, extra);
}

t.test('DEFAULT CONFIG: wellbeing={} and xpTier={} (every feature flag off) hides every gated row, never blank/zeroed', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: {} }));
    assertAllGatedRowsHidden(h, 'default config, {} shape');
});

t.test('EMPTY-ARRAY SHAPE: wellbeing=[] and xpTier=[] (older-Lua/pre-setmetatable wire shape) behaves IDENTICALLY to {}', () => {
    const h = freshHarnessNoAudio();
    // This is the exact case this task calls out: dkjson defaults an empty
    // Lua table to a JSON array without the __jsontype='object' hint --
    // proving app.js's property access on an array is indistinguishable
    // from property access on an object for every key it actually reads.
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: [], xpTier: [] }));
    assertAllGatedRowsHidden(h, 'legacy [] shape');
});

t.test('wellbeing/xpTier entirely missing from the payload (data.wellbeing/data.xpTier undefined) does not throw and hides every gated row', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({}));
    assertAllGatedRowsHidden(h, 'keys entirely absent from data');
});

t.test('PARTIAL PRESENCE: only fatigue present as a number shows fatigue alone, everything else stays hidden', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { fatigue: 42 }, xpTier: {} }));

    const fatigue = h.getBarRow('fatigue');
    t.isFalse(fatigue.row.classList.contains('k9hud-row--hidden'), 'fatigue row shown');
    t.equals(fatigue.fill.style.width, '42%');
    t.equals(fatigue.value.textContent, '42');

    for (const stat of ['mood', 'fearStress', 'injury']) {
        t.isTrue(h.getBarRow(stat).row.classList.contains('k9hud-row--hidden'), `${stat} row still hidden`);
    }
    t.isTrue(h.getStatusRow('distraction').row.classList.contains('k9hud-row--hidden'));
    t.isTrue(h.getStatusRow('xpTier').row.classList.contains('k9hud-row--hidden'));
});

t.test('FULL PRESENCE: every wellbeing key + xpTier.label present renders every row with the right values', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({
        wellbeing: { fatigue: 10, mood: 20, fearStress: 30, injury: 40, distracted: true },
        xpTier: { label: 'Veteran' },
    }));

    t.equals(h.getBarRow('fatigue').value.textContent, '10');
    t.equals(h.getBarRow('mood').value.textContent, '20');
    t.equals(h.getBarRow('fearStress').value.textContent, '30');
    t.equals(h.getBarRow('injury').value.textContent, '40');
    for (const stat of GATED_BAR_STATS) {
        t.isFalse(h.getBarRow(stat).row.classList.contains('k9hud-row--hidden'), `${stat} row shown`);
    }

    const distraction = h.getStatusRow('distraction');
    t.isFalse(distraction.row.classList.contains('k9hud-row--hidden'));
    t.equals(distraction.value.textContent, 'Distracted');

    const xpTier = h.getStatusRow('xpTier');
    t.isFalse(xpTier.row.classList.contains('k9hud-row--hidden'));
    t.equals(xpTier.value.textContent, 'Veteran');
});

t.test('xpTier.badge: absent when the tier carries none -- label renders alone, no trailing separator/badge text', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { label: 'Veteran' } }));
    t.equals(h.getStatusRow('xpTier').value.textContent, 'Veteran');
});

t.test('xpTier.badge: present alongside label renders both -- the previously-disclosed "computed, forwarded, cached, but never rendered" gap (server/progression.lua) is closed', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { label: 'Elite K9', badge: 'elite' } }));
    const xpTier = h.getStatusRow('xpTier');
    t.isFalse(xpTier.row.classList.contains('k9hud-row--hidden'));
    t.isTrue(xpTier.value.textContent.indexOf('Elite K9') !== -1, 'label text is present');
    t.isTrue(xpTier.value.textContent.indexOf('elite') !== -1, 'badge text is present');
});

t.test('TYPE STRICTNESS: xpTier.badge sent as an empty string renders label alone, same as an absent badge', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { label: 'Elite K9', badge: '' } }));
    t.equals(h.getStatusRow('xpTier').value.textContent, 'Elite K9');
});

t.test('TYPE STRICTNESS: xpTier.badge sent as a non-string (number) renders label alone, defensively', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { label: 'Elite K9', badge: 7 } }));
    t.equals(h.getStatusRow('xpTier').value.textContent, 'Elite K9');
});

t.test('xpTier.badge present but xpTier.label absent still hides the whole row -- a badge never renders on its own', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { badge: 'elite' } }));
    t.isTrue(h.getStatusRow('xpTier').row.classList.contains('k9hud-row--hidden'));
});

t.test('distracted:false renders "Clear" text and still shows the row (false is a valid present boolean, not an absence)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { distracted: false }, xpTier: {} }));
    const distraction = h.getStatusRow('distraction');
    t.isFalse(distraction.row.classList.contains('k9hud-row--hidden'));
    t.equals(distraction.value.textContent, 'Clear');
});

t.test('TYPE STRICTNESS: a wellbeing numeric field sent as a numeric STRING is treated as absent (hidden), matching the documented `typeof === number` contract', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { fatigue: '42' }, xpTier: {} }));
    t.isTrue(h.getBarRow('fatigue').row.classList.contains('k9hud-row--hidden'), 'a numeric-string value must not count as "present"');
});

t.test('TYPE STRICTNESS: distracted sent as a truthy non-boolean (1) is treated as absent, matching the documented `typeof === boolean` contract', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { distracted: 1 }, xpTier: {} }));
    t.isTrue(h.getStatusRow('distraction').row.classList.contains('k9hud-row--hidden'), 'a truthy-but-non-boolean value must not count as "present"');
});

t.test('TYPE STRICTNESS: xpTier.label sent as an empty string is treated as absent (row hidden) -- a documented app.js quirk, not a crash', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { label: '' } }));
    t.isTrue(h.getStatusRow('xpTier').row.classList.contains('k9hud-row--hidden'), 'empty-string label hides the row per applyXPTierStatus\' own `rawLabel.length > 0` check');
});

t.test('TYPE STRICTNESS: xpTier.label sent as a non-string (number) is treated as absent', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: { label: 5 } }));
    t.isTrue(h.getStatusRow('xpTier').row.classList.contains('k9hud-row--hidden'));
});

t.test('a gated row, once shown, correctly HIDES again on a later push where its key goes back to absent (feature toggled off mid-session is not expected, but the per-message re-gating must still work)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { fatigue: 77 }, xpTier: {} }));
    t.isFalse(h.getBarRow('fatigue').row.classList.contains('k9hud-row--hidden'));

    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: {}, xpTier: {} }));
    t.isTrue(h.getBarRow('fatigue').row.classList.contains('k9hud-row--hidden'), 'fatigue row re-hides once its key is absent again');
});

t.test('out-of-range wellbeing numeric values clamp the same way the core four vitals do', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { fatigue: 250, mood: -50 }, xpTier: {} }));
    t.equals(h.getBarRow('fatigue').value.textContent, '100');
    t.equals(h.getBarRow('mood').value.textContent, '0');
});

t.run();
