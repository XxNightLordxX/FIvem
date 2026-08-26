/*
    html/tests/hud_locale_strings_spec.js

    Regression coverage for a defect found in review: html/app.js's
    applyDistractionStatus() used to render the Distraction status row's
    text via a hardcoded `rawDistracted ? 'Distracted' : 'Clear'` ternary
    -- literal, un-localizable English -- while the ADJACENT xpTier status
    row (applyXPTierStatus) correctly renders whatever string
    client/hud.lua/client/progression.lua's Config.XPTiers label sends
    (itself locale-authored server-side). Every other user-facing string
    on the K9 Command Tablet (html/tablet.js) already routes through a
    `state.strings[key]` (server-sent, locale()-resolved) -> DEFAULT_STRINGS
    (English fallback) lookup -- see html/tablet.js's own S()/
    DEFAULT_STRINGS -- so the Distraction row was the one place on this
    surface that could never be localized no matter what the server sent.

    Fix: applyDistractionStatus() now resolves through the identical
    "state.strings[key] first, English fallback object second" shape via
    hudString()/HUD_DEFAULT_STRINGS, and handleUpdateVitals() forwards an
    optional `data.strings` through to it. The `hud:updateVitals` payload
    contract does not carry a `strings` field yet (client/hud.lua is out of
    this pass' file scope -- reported to the locale/backend owners
    separately: a new `hud` locales/en.json group with
    `distraction_active` = "Distracted" and `distraction_clear` = "Clear"
    is needed, sent the same way client/tablet.lua's BuildTabletStrings()
    already sends the `tablet` group), so today `strings` is always
    absent/undefined and every case below still renders the English
    fallback -- this file exists to (a) prove that fallback still matches
    the pre-existing 'Distracted'/'Clear' text exactly (no behavior
    regression -- hud_wellbeing_shape_spec.js's own assertions on those
    exact literals must keep passing unmodified) and (b) prove the
    override path actually works the moment a future payload supplies it,
    without requiring any further app.js change.
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

function freshHarnessNoAudio() {
    return createHarness({ AudioContextCtor: undefined });
}

function baseVitals(extra) {
    return Object.assign({ visible: true, health: 100, stamina: 100, hunger: 100, thirst: 100 }, extra);
}

t.test('no `strings` field in the payload (today\'s real contract): distracted:true renders the English fallback "Distracted"', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { distracted: true }, xpTier: {} }));
    t.equals(h.getStatusRow('distraction').value.textContent, 'Distracted');
});

t.test('no `strings` field in the payload: distracted:false renders the English fallback "Clear"', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { distracted: false }, xpTier: {} }));
    t.equals(h.getStatusRow('distraction').value.textContent, 'Clear');
});

t.test('a future `strings.distraction_active`/`strings.distraction_clear` payload overrides the English fallback -- proves the lookup is genuinely locale-ready, not just a renamed literal', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({
        wellbeing: { distracted: true },
        xpTier: {},
        strings: { distraction_active: 'Distrait', distraction_clear: 'Dégagé' },
    }));
    t.equals(h.getStatusRow('distraction').value.textContent, 'Distrait');

    const h2 = freshHarnessNoAudio();
    h2.postMessage('hud:updateVitals', baseVitals({
        wellbeing: { distracted: false },
        xpTier: {},
        strings: { distraction_active: 'Distrait', distraction_clear: 'Dégagé' },
    }));
    t.equals(h2.getStatusRow('distraction').value.textContent, 'Dégagé');
});

t.test('a malformed `strings` entry (wrong type, empty string, or the whole object missing the key) falls back to English per-key, not a blank render', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({
        wellbeing: { distracted: true },
        xpTier: {},
        strings: { distraction_active: 42, distraction_clear: '' },
    }));
    t.equals(h.getStatusRow('distraction').value.textContent, 'Distracted', 'non-string value falls back to English');

    const h2 = freshHarnessNoAudio();
    h2.postMessage('hud:updateVitals', baseVitals({
        wellbeing: { distracted: false },
        xpTier: {},
        strings: { distraction_active: 'Distrait' }, // distraction_clear key entirely absent
    }));
    t.equals(h2.getStatusRow('distraction').value.textContent, 'Clear', 'missing key falls back to English, sibling key\'s override is unaffected');
});

t.test('`strings` present but `data.strings` itself is not an object (e.g. a stray string/number) does not throw and still falls back to English', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', baseVitals({ wellbeing: { distracted: true }, xpTier: {}, strings: 'not-an-object' }));
    t.equals(h.getStatusRow('distraction').value.textContent, 'Distracted');
});

t.run();
