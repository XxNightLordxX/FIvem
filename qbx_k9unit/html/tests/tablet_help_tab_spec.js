/*
    html/tests/tablet_help_tab_spec.js

    Covers the Help screen (html/tablet.js's buildHelpScreen() and
    everything it assembles -- HELP_TAB_CATALOG, buildHelpStartHereSection(),
    buildHelpTabsSection(), buildHelpCommandsSection(), buildHelpTasksSection(),
    buildHelpTroubleshootingSection()) -- the owner-directed "a separate tab
    that teaches you how to use the entire tablet... super detailed but
    dumbed down" pass. Distinct from html/tests/tablet_command_reference_spec.js
    (which owns the Commands Reference screen's own coverage) -- this file
    only covers the NEW Help screen.

    Five scenarios:
      1. The tab renders and is reachable for any resolved viewer,
         including one with zero certifications (the "New Arrival" case
         this whole page exists to serve first).
      2. Role-based content: a K9-model viewer sees the K9 Start Here
         track; anyone else sees the Handler track -- never both at once.
      3. ADDITIVE, NOT REPLACEMENT: a High Command viewer sees every
         section a plain handler sees, PLUS the admin-only command table
         and task walkthroughs -- proven by an exact row count derived
         from the real COMMAND_REFERENCE array, not a hardcoded number.
      4. A plain handler/K9 viewer (not High Command) does NOT see any
         admin-only command row or admin task heading at all.
      5. XSS safety -- a hostile string arriving via `data.strings` for a
         Help-screen key reaches the DOM only via textContent, never
         innerHTML, same proof technique as html/tests/tablet_xss_spec.js.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

// DERIVED, NOT HARDCODED -- same technique and same reasoning as
// html/tests/tablet_command_reference_spec.js's own
// countRealCommandReferenceEntries(): reads html/tablet.js's raw source
// text so this spec's own row-count assertions never need a manual bump
// when COMMAND_REFERENCE legitimately grows.
const tabletJsSource = fs.readFileSync(path.join(__dirname, '..', 'tablet.js'), 'utf8');
function countCommandReferenceEntriesByAdminOnly(wantAdminOnly) {
    const startPos = tabletJsSource.indexOf('var COMMAND_REFERENCE = [');
    if (startPos === -1) throw new Error('tablet_help_tab_spec: var COMMAND_REFERENCE = [ not found in html/tablet.js');
    const endPos = tabletJsSource.indexOf('\n    ];', startPos);
    if (endPos === -1) throw new Error('tablet_help_tab_spec: closing "];" for COMMAND_REFERENCE not found in html/tablet.js');
    const body = tabletJsSource.slice(startPos, endPos);
    const lines = body.split('\n').filter((l) => l.indexOf('command:') !== -1);
    const needle = 'adminOnly: ' + wantAdminOnly;
    const matches = lines.filter((l) => l.indexOf(needle) !== -1);
    if (matches.length === 0) throw new Error('tablet_help_tab_spec: matched zero COMMAND_REFERENCE entries for adminOnly=' + wantAdminOnly + ' -- extraction pattern is stale');
    return matches.length;
}
const REAL_NON_ADMIN_COMMAND_COUNT = countCommandReferenceEntriesByAdminOnly(false);
const REAL_ADMIN_COMMAND_COUNT = countCommandReferenceEntriesByAdminOnly(true);

function routeFetch(handlers) {
    return function (url) {
        const name = url.split('/').pop();
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_help_tab_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h()));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function myRecordHandler(viewer, opts) {
    opts = opts || {};
    return () => ({
        ok: true,
        viewer: viewer,
        certifications: opts.certifications || [],
        xp: null,
        tierLabel: null,
        myFeatures: opts.myFeatures || [],
        isK9Model: opts.isK9Model === true,
        isPartnered: opts.isPartnered === true,
    });
}

const UNCERTIFIED_VIEWER = { citizenid: 'U1', name: 'New Arrival', isHighCommand: false, effectivePermissions: [] };
const HANDLER_VIEWER = { citizenid: 'H1', name: 'Rex Handler', isHighCommand: false, effectivePermissions: ['k9.access'] };
const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'] };

async function openHelpScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Help')[0].click();
    await settle();
}

/** findByText() only matches an EXACT textContent string -- this page's
 * own step paragraphs are full sentences, so substring assertions below
 * use this instead of a brittle exact-copy-paste of the whole sentence. */
function findByTextContaining(node, substring) {
    return findAll(node, (n) => typeof n._textContent === 'string' && n._textContent.indexOf(substring) !== -1);
}

function statusBadges(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
}

t.test('the Help tab renders for a brand-new, uncertified viewer -- the exact reader this screen exists for first', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(UNCERTIFIED_VIEWER, {}),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'How to Use This Tablet').length, 1, 'the screen heading renders');
    t.equals(findByText(h.getRoot(), 'Start Here').length, 1);
    t.equals(findByText(h.getRoot(), 'Every Tab, Explained').length, 1);
    t.equals(findByText(h.getRoot(), 'Commands You Can Use').length, 1);
    t.equals(findByText(h.getRoot(), 'How to Do the Common Things').length, 1);
    t.equals(findByText(h.getRoot(), "When Something Doesn't Work").length, 1);
    // Getting Started role note -- uncertified, not K9, not handler.
    t.isTrue(findByTextContaining(h.getRoot(), 'Getting Started version of this guide').length >= 1);
});

t.test('role-based Start Here: a K9-model viewer sees the K9 track, never the Handler track', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { isK9Model: true, certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'You are playing as the dog').length >= 1, 'K9 track step 1 renders');
    t.equals(findByTextContaining(h.getRoot(), 'Look at the top of the Home tab. It shows your name').length, 0, 'Handler track step 1 does NOT render at the same time');
});

t.test('role-based Start Here: a non-K9 viewer sees the Handler track, never the K9 track', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { isK9Model: false, certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'Look at the top of the Home tab. It shows your name').length >= 1, 'Handler track step 1 renders');
    t.equals(findByTextContaining(h.getRoot(), 'You are playing as the dog').length, 0, 'K9 track step 1 does NOT render at the same time');
});

t.test('ADDITIVE, NOT REPLACEMENT: High Command sees every non-admin command PLUS every admin-only command', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'Admin Commands (High Command Only)').length, 1, 'the admin heading renders for High Command');
    t.equals(statusBadges(h).length, REAL_NON_ADMIN_COMMAND_COUNT + REAL_ADMIN_COMMAND_COUNT, 'every non-admin AND every admin-only command row renders');

    // High-command-only task walkthroughs are additive too.
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 1);
    t.equals(findByText(h.getRoot(), 'Turn Someone Into a K9').length, 1);
    t.equals(findByText(h.getRoot(), 'Turn a Feature On or Off').length, 1);
    t.equals(findByText(h.getRoot(), 'Check What Someone Did').length, 1);
    // The derived Guided Flows step line -- proves this is rendered from
    // the SAME live flowOnboardStepLabels()/flowTuningStepLabels() this
    // pass's own header promises, not a separate hand-typed copy.
    t.isTrue(findByTextContaining(h.getRoot(), 'Select Person → Certify → K9 Role → Tier & Specializations → Feature Access → Summary').length >= 1, 'the onboarding flow\'s real step sequence is quoted live');
});

t.test('a plain handler (not High Command) sees the non-admin commands only -- no admin row, no admin heading, no admin tasks', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'Admin Commands (High Command Only)').length, 0, 'no admin heading for a plain handler');
    t.equals(statusBadges(h).length, REAL_NON_ADMIN_COMMAND_COUNT, 'only the non-admin commands render');
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 0);
    t.equals(findByText(h.getRoot(), 'Turn Someone Into a K9').length, 0);
});

t.test('DELEGATED, NOT HIGH COMMAND: a rank-based certifier holding only the k9.certify capability sees the certification admin table and the Certify Someone task, but NOT Turn Someone Into a K9 or the Runtime Control task', async () => {
    const DELEGATED_CERTIFIER = { citizenid: 'D1', name: 'Sergeant Certifier', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify'] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_CERTIFIER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'Admin Commands (High Command Only)').length, 1, 'a delegated k9.certify holder IS taught the admin command table exists');
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 1, 'and gets the Certify Someone walkthrough');
    t.equals(findByText(h.getRoot(), 'Turn Someone Into a K9').length, 0, 'but NOT the true-high-command-only Assign K9 Role walkthrough');
    t.equals(findByText(h.getRoot(), 'Turn a Feature On or Off').length, 0, 'and NOT the Runtime Control walkthrough, which this viewer has no capability for');
    t.equals(findByText(h.getRoot(), 'Runtime Control').length, 0, 'nor is the Runtime Control tab itself explained to them');
});

t.test('DELEGATED, NOT HIGH COMMAND: a runtime-control-only delegate sees the Runtime Control tab/task but NOT the certification admin table', async () => {
    const DELEGATED_RUNTIME = { citizenid: 'D2', name: 'Ops Delegate', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.runtimecontrol'] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_RUNTIME, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'Turn individual features on or off for the whole server').length >= 1, 'the Runtime Control tab is explained to this delegate');
    t.equals(findByText(h.getRoot(), 'Turn a Feature On or Off').length, 1, 'and they get the matching task walkthrough');
    t.equals(findByText(h.getRoot(), 'Admin Commands (High Command Only)').length, 0, 'but the certification/audit/xp admin command table is NOT shown -- this capability gates no real command');
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 0);
});

t.test('Every Tab, Explained only lists tabs this viewer can actually see -- High Command gets more entries than a plain handler', async () => {
    const handlerHarness = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { certifications: [{ active: true }] }) }),
    });
    await openHelpScreen(handlerHarness);
    t.equals(findByText(handlerHarness.getRoot(), 'Runtime Control').length, 0, 'a plain handler is not taught about the high-command-only Runtime Control tab');
    t.equals(findByText(handlerHarness.getRoot(), 'Home').length >= 1 ? 1 : 0, 1, 'a plain handler IS taught about Home');

    const hcHarness = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}) }),
    });
    await openHelpScreen(hcHarness);
    t.isTrue(findByText(hcHarness.getRoot(), 'Runtime Control').length >= 1, 'High Command IS taught about the Runtime Control tab');
    t.isTrue(findByText(hcHarness.getRoot(), 'Audit Trail').length >= 1, 'High Command IS taught about the Audit Trail tab');
});

t.test('a hostile string arriving via data.strings for a Help-screen key reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}),
        }),
    });
    h.postMessage('tablet:open', { strings: { help_heading: malicious, help_trouble_no_k9_access_body: malicious } });
    await settle();
    findByText(h.getRoot(), 'Help')[0].click();
    await settle();

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious string reaches the DOM verbatim as textContent somewhere on this screen');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious Help-screen string');
});

t.run();
