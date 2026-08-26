/*
    html/tests/tablet_command_reference_spec.js

    Covers the Command Reference screen (html/tablet.js's COMMAND_REFERENCE /
    buildCommandReferenceScreen() / commandReferenceStatus()) -- the "36
    commands, no way for a player to discover them in-game" screen, shown to
    EVERY resolved viewer (handler or high command alike -- see buildTabs()'s
    own comment on why the Commands tab is unconditional, same as Home/My
    Record).

    Six scenarios, matching this pass's own acceptance criteria:
      1. The screen renders -- every catalog entry appears,
         grouped under its own category heading, with a live status badge.
      2. Filtering -- typing in the search box narrows the visible rows (and
         hides a category heading entirely once none of its rows match),
         typing something matching nothing shows the empty-state message.
      3. A HANDLER (certified, no special capability) sees a restricted
         admin-tier command marked unavailable, with a status distinct from
         (never confused with) an ordinary "not certified" reading.
      4. HIGH COMMAND sees every admin-tier command marked with the (Admin)
         badge -- shown to high command too, not hidden from them, per this
         task's own "high command sees everything, with the admin ones
         marked as such" instruction -- and available when nothing else
         blocks it.
      5. A feature that is blocked for this viewer, or switched off
         server-wide, overrides an otherwise-qualifying capability (proves
         `global_off`/`blocked` are checked BEFORE the capability check, not
         instead of it).
      6. Escaping -- a hostile string arriving via `data.strings` for one of
         this screen's own keys reaches the DOM only via textContent, never
         innerHTML, same proof technique as html/tests/tablet_xss_spec.js.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, findByTag } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_command_reference_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h()));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function myRecordHandler(viewer, myFeatures) {
    return () => ({
        ok: true,
        viewer: viewer,
        certifications: [],
        xp: null,
        tierLabel: null,
        myFeatures: myFeatures || [],
    });
}

const HANDLER_VIEWER = { citizenid: 'H1', name: 'Rex Handler', isHighCommand: false, effectivePermissions: ['k9.access'] };
const UNCERTIFIED_VIEWER = { citizenid: 'U1', name: 'New Arrival', isHighCommand: false, effectivePermissions: [] };
const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'] };

async function openCommandsScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Commands')[0].click();
    await settle();
}

function statusBadges(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
}

function statusBadgeFor(h, commandText) {
    // The command's own <span> (its usage text, e.g. "/k9deploykennel")
    // sits in the first <td> of its row; the status badge is the last
    // <span> in that same <tr>.
    const cmdSpan = findByText(h.getRoot(), commandText)[0];
    t.isDefined(cmdSpan, 'expected to find a rendered command span for ' + commandText);
    let row = cmdSpan;
    while (row && row.tagName !== 'tr') row = row.parentNode;
    t.isDefined(row, 'expected an ancestor <tr> for ' + commandText);
    const badges = findAll(row, (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
    t.equals(badges.length, 1, 'exactly one status badge in the row for ' + commandText);
    return badges[0];
}

t.test('screen rendering: every catalog entry renders, one status badge each, under category headings', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, []),
        }),
    });
    await openCommandsScreen(h);

    t.equals(findByText(h.getRoot(), 'Command Reference').length, 1, 'the screen heading renders');
    t.isTrue(findByText(h.getRoot(), 'Certification Management').length >= 1, 'a category heading renders');
    t.isTrue(findByText(h.getRoot(), 'Field Gear & Equipment').length >= 1, 'another category heading renders');
    t.equals(statusBadges(h).length, 38, 'exactly 38 status badges -- one per real RegisterCommand this resource registers (see tests/commandreferenceregistry_spec.lua for the drift guard that keeps this number honest)');
    t.isTrue(findByText(h.getRoot(), '/k9auditcert <citizenid> [limit]').length === 1, 'a specific command\'s exact usage string renders verbatim');
});

t.test('filtering: typing in the search box narrows to matching rows and hides an emptied category heading; a non-matching query shows the empty-state message', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, []),
        }),
    });
    await openCommandsScreen(h);

    const search = findByTag(h.getRoot(), 'input')[0];
    t.isDefined(search, 'the search box renders');

    search.typeValue('bonetool');
    await settle();
    t.equals(statusBadges(h).length, 1, 'only the one matching command remains');
    t.equals(findByText(h.getRoot(), 'Developer Tools').length, 1, 'its own category heading still shows');
    t.equals(findByText(h.getRoot(), 'Certification Management').length, 0, 'an emptied category heading is not shown at all');

    search.typeValue('this-matches-absolutely-nothing-xyz');
    await settle();
    t.equals(statusBadges(h).length, 0, 'no rows remain');
    t.equals(findByText(h.getRoot(), 'No commands match your search.').length, 1, 'the empty-state message renders instead');
});

t.test('a HANDLER (certified, no special capability) sees a restricted admin-tier command marked unavailable, distinctly from a plain "not certified" reading', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, [
                { key: 'DeployableKennel', label: null, category: null, actionable: false, state: 'available' },
            ]),
        }),
    });
    await openCommandsScreen(h);

    const auditBadge = statusBadgeFor(h, '/k9auditcert <citizenid> [limit]');
    t.equals(auditBadge._textContent, 'Requires higher authorization', 'a handler with no k9.audit/k9.certify/k9.givexp/high-command sees the admin-tier reason, not a certification-flavored one');
    t.isTrue(auditBadge.classList.contains('k9tablet-feature-state--requires_grant_missing'), 'reuses the existing amber "needs a grant" CSS bucket -- no new CSS class');

    const kennelBadge = statusBadgeFor(h, '/k9deploykennel');
    t.equals(kennelBadge._textContent, 'Available', 'a handler-tier command this viewer genuinely qualifies for (an active certification, feature state available) shows Available');
});

t.test('an UNCERTIFIED viewer (no k9.access at all) sees a handler-tier command marked "Not certified", while an open-tier command with no personal gate stays Available', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(UNCERTIFIED_VIEWER, []),
        }),
    });
    await openCommandsScreen(h);

    const kennelBadge = statusBadgeFor(h, '/k9deploykennel');
    t.equals(kennelBadge._textContent, 'Not certified');

    const dropBadge = statusBadgeFor(h, '/k9dropfetchball');
    t.equals(dropBadge._textContent, 'Available', 'an open-tier command (no HasK9Access check in its real handler) is available to anyone, including someone with zero certifications');
});

t.test('HIGH COMMAND sees every admin-tier command marked with the (Admin) badge -- shown to high command too, not hidden -- and Available when nothing else blocks it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, []),
        }),
    });
    await openCommandsScreen(h);

    const adminBadges = findAll(h.getRoot(), (n) => n._textContent === ' (Admin)');
    // 20 admin-tier commands in COMMAND_REFERENCE: 11 certification + 1
    // givexp + 5 audit + 1 bonetool + 2 permission grant/revoke.
    t.equals(adminBadges.length, 20, 'every admin-tier command carries the (Admin) marker, for high command too');

    const auditBadge = statusBadgeFor(h, '/k9auditcert <citizenid> [limit]');
    t.equals(auditBadge._textContent, 'Available');
    const certifyBadge = statusBadgeFor(h, '/k9certify <server id>');
    t.equals(certifyBadge._textContent, 'Available');
});

t.test('a server-wide-disabled feature overrides an otherwise-qualifying high-command capability (checked BEFORE the capability check, not instead of it)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, [
                { key: 'AdminAuditCommands', label: null, category: null, actionable: false, state: 'global_off' },
            ]),
        }),
    });
    await openCommandsScreen(h);

    const auditBadge = statusBadgeFor(h, '/k9auditcert <citizenid> [limit]');
    t.equals(auditBadge._textContent, 'Disabled server-wide', 'a global_off feature state wins even for a high-command viewer who otherwise qualifies by capability');
});

t.test('a per-person block overrides an otherwise-qualifying high-command capability', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, [
                { key: 'AdminAuditCommands', label: null, category: null, actionable: false, state: 'blocked' },
            ]),
        }),
    });
    await openCommandsScreen(h);

    const auditBadge = statusBadgeFor(h, '/k9auditcert <citizenid> [limit]');
    t.equals(auditBadge._textContent, 'Blocked', 'a personal block wins even for a high-command viewer');
});

t.test('a blocked handler-tier feature shows Blocked for a certified handler who otherwise holds k9.access', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, [
                { key: 'PropAttachments', label: null, category: null, actionable: false, state: 'blocked' },
            ]),
        }),
    });
    await openCommandsScreen(h);

    const badge = statusBadgeFor(h, '/k9propattach');
    t.equals(badge._textContent, 'Blocked');
});

t.test('a hostile string arriving via data.strings for a Command Reference key reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, []),
        }),
    });
    h.postMessage('tablet:open', { strings: { cmdref_k9auditcert_does: malicious, cmdref_heading: malicious } });
    await settle();
    findByText(h.getRoot(), 'Commands')[0].click();
    await settle();

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious string reaches the DOM verbatim as textContent somewhere on this screen');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious Command Reference string');
});

t.run();
