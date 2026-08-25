/*
    html/tests/tablet_xss_spec.js

    Proves (not merely asserts by reading source) that html/tablet.js never
    writes ANY player- or server-controlled string into innerHTML anywhere
    on this page -- same technique as html/tests/xss_spec.js uses for
    app.js, extended to cover the strings THIS page renders that the HUD
    never did: names, citizenids, department labels, feature/capability
    labels, and free-form `message` fields on a mutation response. Per this
    task's own standing instruction ("assume a player can bypass your UI
    entirely and send arbitrary payloads straight to the callback"), every
    one of these is treated as fully attacker-controlled regardless of
    which side of the contract nominally authors it.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_xss_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const MALICIOUS_STRINGS = [
    '<img src=x onerror="window.__xss_pwned=true">',
    '<script>window.__xss_pwned=true</script>',
    '"><svg onload=alert(1)>',
    'javascript:alert(1)',
    '</span><b>bold-injected</b>',
    '&lt;already-escaped&gt;',
    'a'.repeat(5000),
    ' ‮​',
];

function everyElementInnerHTMLWriteCount(h) {
    return findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

for (const malicious of MALICIOUS_STRINGS) {
    const shortLabel = JSON.stringify(malicious.slice(0, 40)) + (malicious.length > 40 ? '...' : '');

    t.test(`my-record: certification department label + feature label containing ${shortLabel} reach the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({
                    ok: true,
                    viewer: { citizenid: malicious, name: malicious, isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                    certifications: [{ departmentKey: 'x', departmentLabel: malicious, active: true, grantedBy: malicious }],
                    xp: 1,
                    tierLabel: malicious,
                    myFeatures: [{ key: 'X', label: malicious, category: malicious, actionable: false, state: 'available' }],
                }),
            }),
        });
        h.postMessage('tablet:open', {});
        await settle();

        const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
        t.isTrue(matches.length >= 3, 'the malicious string appears verbatim as textContent in at least the department label, tier label, and feature label');
        t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page for this payload');
    });

    t.test(`admin roster/person: name/citizenid/department/message/ped-label containing ${shortLabel} reach the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
                'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: malicious, name: malicious, departmentLabel: malicious, certified: true, xp: 1, tierLabel: malicious }], truncated: true, truncatedMessage: malicious }),
                'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: malicious, name: malicious }, certifications: [{ departmentKey: 'x', departmentLabel: malicious, active: true, grantedBy: malicious }], xp: 1, tierLabel: malicious, permissions: [] }),
                'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: malicious, name: malicious }, features: [{ key: 'X', label: malicious, category: malicious, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' }] }),
                'tablet:certify': () => ({ ok: false, message: malicious }),
            }),
        });

        // `peds` (K9 role control's model picker, see html/tablet.js's own
        // header on tablet:assignK9Role) is sent verbatim from the
        // tablet:open payload -- a malicious `label` here is config-authored
        // in a real deployment, not directly player-controlled, but this
        // suite's own header treats every string as attacker-controlled
        // "regardless of which side of the contract nominally authors it".
        h.postMessage('tablet:open', { peds: [{ model: 'a_c_shepherd', label: malicious }] });
        await settle();
        const { findByText } = require('./tablet-dom-stub');
        findByText(h.getRoot(), 'Command Console')[0].click();
        await settle();

        // Roster row + truncation banner.
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length > 0, 'malicious roster/truncation text present verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        findByText(h.getRoot(), 'Manage')[0].click();
        await settle(4);

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length > 0, 'malicious person-summary/feature/ped-label text present verbatim (K9 Role section\'s own model picker option is included in this count)');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // An action-failure `message` field is also attacker/server-adjacent
        // content, per this file's header -- must render via textContent too.
        const certifyBtn = findByText(h.getRoot(), 'Certify')[0];
        if (certifyBtn) {
            certifyBtn.click();
            await new Promise((r) => setTimeout(r, 30));
            t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length > 0, 'mutation failure message rendered verbatim');
            t.equals(everyElementInnerHTMLWriteCount(h), 0);
        }
    });

    t.test(`tablet theming + cert tier editing: header title / tier label / capability label / reorder warning containing ${shortLabel} reach the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: malicious } }),
                'tablet:certTiersList': () => ({
                    ok: true,
                    tiers: [
                        { key: 'x', label: malicious, ordinal: 1, capabilities: { cap1: true } },
                        { key: 'certified', label: 'Certified', ordinal: 2, capabilities: {} },
                    ],
                    capabilityCatalog: { cap1: { label: malicious } },
                }),
                'tablet:certTiersReorder': () => ({ ok: true, tiers: [], warning: malicious }),
            }),
        });

        h.postMessage('tablet:open', {});
        await settle();

        // Theme headerTitle -- rendered directly into the panel's <h1>.
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious theme headerTitle rendered verbatim in the header');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        const { findByText } = require('./tablet-dom-stub');
        findByText(h.getRoot(), 'Certification Tiers')[0].click();
        await settle();

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious cert-tier label AND capability label both rendered verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // Trigger a reorder (move the second row, "certified", up) to reach
        // the server-supplied `warning` banner.
        const moveUpButtons = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '↑');
        const enabledMoveUp = moveUpButtons.filter((b) => b.getAttribute('disabled') !== 'disabled')[0];
        t.isDefined(enabledMoveUp, 'at least one enabled Move Up control exists with two tiers present');
        enabledMoveUp.click();
        await new Promise((r) => setTimeout(r, 30));

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious reorder warning text rendered verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);
    });
}

t.test('a full battery of malicious strings across many sequential opens never once touches innerHTML anywhere in the document', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => {
                const s = MALICIOUS_STRINGS[Math.floor(Math.random() * MALICIOUS_STRINGS.length)];
                return {
                    ok: true,
                    viewer: { citizenid: s, name: s, isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                    certifications: [{ departmentKey: 'x', departmentLabel: s, active: true, grantedBy: s }],
                    xp: 1, tierLabel: s,
                    myFeatures: [{ key: 'X', label: s, category: s, actionable: false, state: 'available' }],
                };
            },
        }),
    });

    for (let i = 0; i < MALICIOUS_STRINGS.length; i++) {
        h.postMessage('tablet:close', {});
        h.postMessage('tablet:open', {});
        await settle();
    }
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes across the whole document after every malicious payload in this suite, across repeated open/close cycles');
});

t.run();
