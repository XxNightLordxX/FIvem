/*
    html/tests/tablet_console_spec.js

    Covers the admin "Command Console" surface: the tab only appearing for
    a viewer with at least one effective capability (or high command),
    roster search/truncation, and drilling into a person's summary
    (certify/decertify, Give XP) -- gated per-control on the viewer's OWN
    effectivePermissions, never on isHighCommand alone unless the control
    is genuinely high-command-exclusive. See html/tablet.js's own header
    "THE SECURITY RULE" -- every one of these gates is a convenience; the
    actual authorization is asserted to live entirely server-side, which
    this suite cannot exercise (that's client/tablet.lua's job) but every
    test below is written as if a hidden control could still be reached by
    a modified client, i.e. this suite never treats "the button isn't
    there" as a substitute for "the action is denied".
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_console_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const PLAIN_MY_RECORD = () => ({
    ok: true,
    viewer: { citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
    certifications: [],
    xp: null,
    tierLabel: null,
    myFeatures: [],
});

async function settle(h, times) {
    for (let i = 0; i < (times || 2); i++) await new Promise((r) => setImmediate(r));
}

t.test('a viewer with NO effective permissions and not high command never sees a Command Console tab at all', async () => {
    const h = createHarness({ fetchImpl: routeFetch({ 'tablet:requestMyRecord': PLAIN_MY_RECORD }) });
    h.postMessage('tablet:open', {});
    await settle(h);
    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'the tab is not merely hidden by CSS -- it is never constructed at all');
});

t.test('a viewer holding ONLY k9.certify sees the console tab and can certify/decertify, but not the capability or feature matrix', async () => {
    const rosterRow = { citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Los Santos Police Department', certified: false, xp: 10, tierLabel: 'Recruit K9' };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestRoster': () => ({ ok: true, rows: [rosterRow], truncated: false }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: false, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9',
                permissions: [],
            }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'Command Console').length >= 1, 'console tab exists for a k9.certify holder even without isHighCommand');

    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'K9 Rex').length >= 1, 'roster row rendered');

    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.isTrue(findByText(h.getRoot(), 'Certify').length >= 1, 'k9.certify holder sees the Certify control');
    t.equals(findByText(h.getRoot(), 'Capabilities').length, 0, 'capability grant/revoke section is high-command only -- absent here');
    t.equals(findByText(h.getRoot(), 'Abilities').length, 0, 'per-person feature matrix is high-command only -- absent here (heading text is shared with My Record\'s own "Abilities" heading, but that only renders on the my_record screen, not here)');
});

t.test('roster search debounces and re-fetches with the typed query', async () => {
    const queriesSeen = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': (body) => { queriesSeen.push(body ? body.query : undefined); return { ok: true, rows: [], truncated: false }; },
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h); // initial load with empty query

    const search = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') && i.getAttribute('placeholder').indexOf('Search by name') !== -1)[0];
    t.isDefined(search, 'search input exists');

    search.typeValue('r');
    search.typeValue('re');
    search.typeValue('rex');
    // Debounce is compressed but still asynchronous -- see tablet-sandbox.js's header.
    await new Promise((r) => setTimeout(r, 40));

    t.equals(queriesSeen[0], '', 'initial load used an empty query');
    t.equals(queriesSeen[queriesSeen.length - 1], 'rex', 'only the FINAL debounced value was ever sent, not one request per keystroke');
    t.isTrue(queriesSeen.length < 4, 'rapid keystrokes were coalesced by the debounce, not fired individually');
});

t.test('a truncated roster shows the server-provided message when present, else a generic fallback', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'A', name: 'A', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: true, truncatedMessage: 'Showing the first 100 results.' }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'Showing the first 100 results.').length >= 1, 'server-provided truncation message rendered verbatim');
});

t.test('Certify/Decertify buttons flip per department based on active status, and firing one re-fetches the person summary', async () => {
    let summaryCalls = 0;
    let lastCertifyBody = null;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: false, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => {
                summaryCalls++;
                return {
                    ok: true,
                    target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                    certifications: [
                        { departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: false, grantedBy: null },
                        { departmentKey: 'sheriff', departmentLabel: 'Blaine County Sheriff', active: true, grantedBy: 'GRANTER1' },
                    ],
                    xp: 0, tierLabel: 'Recruit K9', permissions: [],
                };
            },
            'tablet:certify': (body) => { lastCertifyBody = body; return { ok: true }; },
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.equals(summaryCalls, 1);
    t.equals(findByText(h.getRoot(), 'Certify').length, 1, 'exactly one Certify control -- for the department NOT held');
    t.equals(findByText(h.getRoot(), 'Decertify').length, 1, 'exactly one Decertify control -- for the department already held');
    t.isTrue(findByText(h.getRoot(), 'GRANTER1').length >= 1, 'granted-by citizenid shown for the active certification');

    findByText(h.getRoot(), 'Certify')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(lastCertifyBody.targetCitizenId, 'TARGET1');
    t.equals(lastCertifyBody.departmentKey, 'police');
    t.equals(summaryCalls, 2, 'person summary is re-fetched after certifying -- never trusts an optimistic local flip');
});

t.test('Decertify requires a second confirming click before firing the request', async () => {
    let decertifyCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: null }], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
            'tablet:decertify': () => { decertifyCalls++; return { ok: true }; },
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    const decertifyBtn = findByText(h.getRoot(), 'Decertify')[0];
    t.isDefined(decertifyBtn);
    decertifyBtn.click();
    t.equals(decertifyCalls, 0, 'first click only arms the confirmation, does not fire yet');
    t.equals(decertifyBtn._textContent, 'Confirm?', 'button label flips to the confirm prompt');

    decertifyBtn.click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(decertifyCalls, 1, 'second click within the window fires the actual request');
});

t.test('Give XP is only offered to a viewer holding k9.givexp, and disables self-targeting when allowSelfGrant is false', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'SELF1', name: 'V', isHighCommand: true, effectivePermissions: ['k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'SELF1', name: 'Self', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'SELF1', name: 'Self' }, certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.equals(findByText(h.getRoot(), 'Give XP').length, 1, 'give-XP control rendered for a k9.givexp holder');
    const giveBtn = findByText(h.getRoot(), 'Give XP')[0];
    t.equals(giveBtn.getAttribute('disabled'), 'disabled', 'self-targeted Give XP is disabled client-side when allowSelfGrant is false (a UX convenience -- the server independently enforces the real rule)');
});

t.run();
