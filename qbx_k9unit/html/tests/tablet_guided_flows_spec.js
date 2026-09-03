/*
    html/tests/tablet_guided_flows_spec.js

    Covers the ONE remaining guided flow -- Server Tuning (html/tablet.js's
    buildFlowTuningScreen()): a sequenced pass over the server-wide
    settings (feature toggles, tunables, certification tiers, XP ranks,
    shop items) laid OVER the existing screens rather than replacing them.

    THREE FLOWS USED TO LIVE HERE TOO -- Set Up a New Handler, Offboard a
    Handler, Handle a Problem Player -- reached from a hub of four cards.
    They were retired once the Person screen became the single place all of
    their steps happen: each had become that screen's own sections, in that
    same order, reached through a SECOND person-search box. Tuning is the
    one that still sequences work no single screen holds, so it stays, and
    with nothing left to choose between, the tab opens it directly.

    What the retirement did NOT lose, and this file no longer needs to
    re-prove:
      - The person-shaped mutations (certify, decertify, tier, feature
        grant/revoke, permission, K9 role, appearance revert) are the
        Person screen's own, covered by tablet_person_spec.js and friends.
      - The escaping proofs for a person's name, department label, feature
        label and a malicious ped label are covered directly against those
        same screens by tablet_xss_spec.js ("admin roster/person:
        name/citizenid/department/message/ped-label ..."), which is where
        those strings are actually rendered now.

    THIS IS PRESENTATION ONLY -- the assertion that a mutation "worked" is
    really an assertion that the flow fired the EXACT SAME tablet:* NUI
    callback, with the EXACT SAME payload, that the equivalent standalone
    screen already fires (verified via h.fetchCalls, not merely by the
    on-screen text updating). Per THE SECURITY RULE at html/tablet.js's own
    header, this section adds no new callback and no new authorization
    path.

    Specifically proves:
      1. The flow completes, using the real underlying screens/callbacks.
      2. Its Overview reports REAL, server-confirmed override counts --
         read from the `overridden` field the server already sends, never
         from a client-side change log.
      3. A viewer who is not high command sees no trace of it anywhere.
      4. The tab opens the flow directly, with no hub in between and --
         the whole point of retiring the other three -- no person-search
         box anywhere inside it.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_guided_flows_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 4); i++) await new Promise((r) => setImmediate(r));
}

function everyElementInnerHTMLWriteCount(h) {
    return findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CERTIFIER_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer Rex', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };

/** The callbacks the tuning flow's own five steps load, and nothing else.
 * The person-shaped handlers this file used to carry went with the three
 * retired flows -- this flow never touches a person. */
function baseHandlers(viewer, overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: viewer, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
        'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        'tablet:certTiersList': () => ({ ok: true, tiers: [], capabilityCatalog: {} }),
        'tablet:xpTiersList': () => ({ ok: true, tiers: [] }),
        'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
    }, overrides || {});
}

async function openTablet(handlers, openData) {
    const h = createHarness({ fetchImpl: routeFetch(handlers) });
    h.postMessage('tablet:open', openData || {});
    await settle();
    return h;
}

// ======================================================================
// 3. UNAUTHORIZED VIEWER NEVER SEES ANY TRACE OF THIS
// ======================================================================

t.test('a certified, non-high-command viewer sees NO trace of the tuning flow anywhere -- no tab, no Home shortcut', async () => {
    const h = await openTablet(baseHandlers(CERTIFIER_ONLY_VIEWER));

    t.equals(findByText(h.getRoot(), 'Server Tuning').length, 0, 'no tab for a non-high-command viewer on the default Home screen');
    t.equals(findByText(h.getRoot(), 'Guided Flows').length, 0, 'and no trace of the old hub name either');

    // Navigate elsewhere this viewer legitimately CAN reach (My Record --
    // deliberately not Command Console, whose own access gate is a
    // separate, unrelated concern this spec does not exercise) and confirm
    // it is still nowhere to be found.
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'Server Tuning').length, 0, 'still absent after navigating elsewhere');
});

// ======================================================================
// 4. THE TAB OPENS THE FLOW DIRECTLY -- NO HUB, NO PERSON PICKER
// ======================================================================

t.test('the tab opens the tuning flow directly: no hub of cards in between, and no person-search box anywhere inside it', async () => {
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER), { runtimeControlEnabled: true });

    t.equals(findByText(h.getRoot(), 'Server Tuning').length, 1, 'the tab itself, on the default Home screen');

    findByText(h.getRoot(), 'Server Tuning')[0].click();
    await settle(6);

    // Straight onto the flow's own first step -- the hub that used to sit
    // here, holding four cards, is gone along with three of the four.
    t.equals(findByText(h.getRoot(), 'Tune the Server').length, 1, 'the flow heading renders immediately, with no card to click first');
    t.equals(findByText(h.getRoot(), '1. Overview').length, 1, 'and the step nav is already showing');

    // The retired flows, by name -- none of them reachable any more.
    t.equals(findByText(h.getRoot(), 'Set Up a New Handler').length, 0);
    t.equals(findByText(h.getRoot(), 'Offboard a Handler').length, 0);
    t.equals(findByText(h.getRoot(), 'Handle a Problem Player').length, 0);

    // THE POINT OF THE WHOLE EXERCISE: the person picker those three
    // needed was the last duplicate person-search box on the tablet. This
    // flow never selects a person, so there must be no text input at all
    // in it -- not a filter, not a lookup, nothing to re-type.
    const inputs = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.type !== 'checkbox');
    t.equals(inputs.length, 0, 'no text input anywhere in the flow -- the duplicate person-finder is gone, not merely hidden');
});

// ======================================================================
// 1 + 2. THE FLOW COMPLETES, ON REAL SERVER-CONFIRMED DATA
// ======================================================================

t.test('Tuning flow: the Overview step reports REAL, server-confirmed override counts, and toggling a feature from inside the flow fires the exact same callback the standalone Runtime Control tab uses', async () => {
    const toggled = {};
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER, {
        'tablet:runtimeListFeatures': () => ({
            ok: true,
            features: [
                { name: 'BiteAndHold', currentValue: true, configLuaDefault: true, tier: 'live', overridden: false, protected: false },
                { name: 'K9Leaderboard', currentValue: false, configLuaDefault: true, tier: 'live', overridden: true, overriddenBy: 'Chief', overriddenAt: '2026-01-01', protected: false },
            ],
        }),
        'tablet:xpTiersList': () => ({ ok: true, tiers: [{ ordinal: 1, xp: 0, label: 'Trainee', speedMultiplier: 1, scentRangeMultiplier: 1, xpLocked: true }] }),
        'tablet:runtimeSetFeature': (body) => { toggled.last = body; return { ok: true, appliedLive: true, tier: 'live' }; },
    }), { runtimeControlEnabled: true });

    findByText(h.getRoot(), 'Server Tuning')[0].click();
    await settle(6);

    // Step 0: Overview -- computed from the SAME server-reported
    // `overridden` field every runtime feature/tunable already carries,
    // never a client-side change log.
    t.equals(findByText(h.getRoot(), '1 of 2 feature toggle(s) overridden from their config.lua default.').length, 1);
    t.equals(findByText(h.getRoot(), '1 XP rank(s) configured.').length, 1);

    // Jump directly to the Feature Toggles step via the step nav (every
    // step is directly reachable -- reversible/skippable).
    findByText(h.getRoot(), '2. Feature Toggles')[0].click();
    await settle();

    t.equals(findByText(h.getRoot(), 'BiteAndHold').length, 1, 'the REAL, unmodified Runtime Control feature table is embedded here');
    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click(); // arm
    enableBtn.click(); // confirm
    await settle(6);

    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:runtimeSetFeature') && c.body.name === 'K9Leaderboard' && c.body.value === true), 'the flow fired the IDENTICAL tablet:runtimeSetFeature callback/payload the standalone Runtime Control tab already uses -- no new authorization path');
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes anywhere in the document across the whole flow');
});

t.test('Tuning flow: Finish returns to the flow\'s own Overview rather than a hub that no longer exists', async () => {
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER), { runtimeControlEnabled: true });

    findByText(h.getRoot(), 'Server Tuning')[0].click();
    await settle(6);

    // Jump to the last step, where buildFlowNavRow() renders Finish.
    findByText(h.getRoot(), '6. Shop Items')[0].click();
    await settle(4);

    const finish = findByText(h.getRoot(), 'Finish')[0];
    t.isTrue(!!finish, 'the last step offers Finish');
    finish.click();
    await settle(4);

    // Back to step 0 of the SAME flow -- not booted out of the tab, and
    // not sent to a deleted hub screen (which would have fallen through
    // to the Home fallback instead).
    t.equals(findByText(h.getRoot(), 'Tune the Server').length, 1, 'still on the tuning flow');
    t.equals(findByText(h.getRoot(), '1. Overview').length, 1, 'and back at its Overview step');
});

t.run();
