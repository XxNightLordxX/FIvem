/*
    html/tests/tablet_person_rank_partnership_spec.js

    Covers the person screen's Rank and Partnership sections
    (html/tablet.js's buildRankSection()/buildPartnershipSection()) --
    owner-directed "roster panel: cert+tier, rank, XP+tier, partnership,
    permissions, all in one screen" pass. Both sections are READ-ONLY
    (server/tablet.lua's PersonSummaryResult.job/.partnership) -- this file
    also proves NO promotion/rank-change control is ever rendered, since
    this resource has no write path for job grade at all today (see
    buildRankSection's own doc comment).
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
        if (!h) return Promise.reject(new Error('tablet_person_rank_partnership_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 500, tierLabel: 'Trained K9' }], truncated: false }),
        'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
    }, overrides || {});
}

async function openPersonScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);
}

function rankLines(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-rank-line')).map((n) => n._textContent);
}

function partnershipLines(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-partnership-line')).map((n) => n._textContent);
}

t.test('a resolvable job renders department + grade name/level as plain text, with NO promotion control anywhere on the page', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: { departmentLabel: 'Los Santos Police Department', gradeLabel: 'Sergeant', gradeLevel: 4, isBoss: false },
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Rank').length, 1, 'the Rank section heading renders');
    const lines = rankLines(h);
    t.equals(lines[0], 'Department: Los Santos Police Department');
    t.equals(lines[1], 'Grade: Sergeant (4)');

    // NO PROMOTION CONTROL -- this resource has no job-grade write path at
    // all today; there must be no rank-specific <select>/dropdown anywhere
    // on this screen, and no button whose label suggests one.
    const rankSection = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-rank-section'))[0];
    t.isDefined(rankSection);
    t.equals(findAll(rankSection, (n) => n.tagName === 'select' || n.tagName === 'button').length, 0, 'the rank section is plain text only -- no control at all, promotion or otherwise');
    t.equals(findByText(h.getRoot(), 'Promote').length, 0);
    t.equals(findByText(h.getRoot(), 'Set Grade').length, 0);
});

t.test('an isBoss target gets the Boss badge appended to their grade line', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: { departmentLabel: 'Blaine County Sheriff', gradeLabel: 'Sheriff', gradeLevel: 5, isBoss: true },
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    const lines = rankLines(h);
    t.equals(lines[1], 'Grade: Sheriff (5) (Boss)');
});

t.test('job === null renders the disclosed "not available" note, never a blank section or a guessed value', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: null,
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Rank information is not available for this person right now.').length, 1);
    t.equals(rankLines(h).length, 0);
});

t.test('partnership === null renders "Not currently partnered."', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: null,
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Partnership').length, 1, 'the Partnership section heading renders');
    t.equals(findByText(h.getRoot(), 'Not currently partnered.').length, 1);
});

t.test('an active partnership renders the partner name and this person\'s role in it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: null,
                partnership: { partnerCitizenid: 'HANDLER1', partnerName: 'Jane Handler', role: 'k9' },
            }),
        })),
    });
    await openPersonScreen(h);

    const lines = partnershipLines(h);
    t.equals(lines[0], 'Partner: Jane Handler');
    t.equals(lines[1], 'Role in partnership: K9');
});

t.test('a hostile department/grade/partner name reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: { departmentLabel: malicious, gradeLabel: malicious, gradeLevel: 1, isBoss: false },
                partnership: { partnerCitizenid: 'HANDLER1', partnerName: malicious, role: 'handler' },
            }),
        })),
    });
    await openPersonScreen(h);

    const matches = findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf(malicious) !== -1);
    t.isTrue(matches.length >= 3, 'the malicious department/grade/partner-name strings all reach the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious job/partnership field');
});

t.run();
