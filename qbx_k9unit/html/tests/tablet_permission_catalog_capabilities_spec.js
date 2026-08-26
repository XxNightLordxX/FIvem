/*
    html/tests/tablet_permission_catalog_capabilities_spec.js

    Covers the person screen's Capabilities section (html/tablet.js's
    resolveCapabilityRows()/buildCapabilityList()) rendering the LIVE
    server/permissionkeycatalog.lua catalog (tablet:permKeysList) instead
    of a hardcoded four-key array -- the "a custom permission key can be
    created but never given to anyone" fix. Five scenarios, matching this
    pass's own acceptance criteria:

      1. The four shipped keys render unchanged (same order, same labels,
         same Grant/Revoke split) when an operator never touches the
         catalog -- including when the catalog ALSO happens to report
         those same four keys back (no duplicate rows).
      2. A custom (non-default) catalog key appears AFTER the four shipped
         ones and is genuinely grantable.
      3. A key `heldKeys` names but a SUCCESSFUL catalog fetch does not
         (the only way that happens is server/permissionkeycatalog.lua's
         own tombstone behavior -- see that file's header "TOMBSTONE, NOT
         REFERENCE-COUNTED") still renders, labelled retired, with a
         Revoke control and NO Grant control.
      4. A failed/denied catalog fetch falls back to exactly the four
         shipped keys -- never an empty panel.
      5. A hostile catalog label/description reaches the DOM only via
         textContent, never innerHTML (same proof technique as
         html/tests/tablet_xss_spec.js -- see tablet-dom-stub.js's own
         trapped innerHTML setter).
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
        if (!h) return Promise.reject(new Error('tablet_permission_catalog_capabilities_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

const FOUR_SHIPPED_KEYS_CATALOG = [
    { key: 'k9.access', label: 'Use K9 abilities', description: 'Equivalent to holding a K9 certification.', isConfigDefault: true },
    { key: 'k9.audit', label: 'View the audit records', description: 'Run the read-only audit commands.', isConfigDefault: true },
    { key: 'k9.certify', label: 'Certify and decertify others', description: 'Grant and revoke K9 certifications.', isConfigDefault: true },
    { key: 'k9.givexp', label: 'Grant XP', description: 'Award XP directly to a K9 or handler.', isConfigDefault: true },
];

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

function getCapabilityRows(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-capability-row'));
}

function capabilityLabelText(row) {
    const span = findAll(row, (n) => n.classList && n.classList.contains('k9tablet-capability-label'))[0];
    return span ? span._textContent : undefined;
}

t.test('the four shipped keys render unchanged (same order, same labels, same Grant/Revoke split) when the catalog reports exactly those four back', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: FOUR_SHIPPED_KEYS_CATALOG }),
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 4, 'exactly the four shipped rows -- the catalog echoing them back must never duplicate a row');
    t.equals(capabilityLabelText(rows[0]), 'Use K9 abilities');
    t.equals(capabilityLabelText(rows[1]), 'Certify and decertify others');
    t.equals(capabilityLabelText(rows[2]), 'View the audit records');
    t.equals(capabilityLabelText(rows[3]), 'Grant XP');
    t.equals(findByText(h.getRoot(), 'Revoke').length, 1, 'k9.access is held -> exactly one Revoke');
    t.equals(findByText(h.getRoot(), 'Grant').length, 3, 'the other three are un-held -> Grant');
    t.equals(findByText(h.getRoot(), 'Retired').length, 0, 'no retired badge anywhere for an untouched catalog');
});

t.test('a custom (non-default) catalog key appears AFTER the four shipped ones and fires tablet:grantPermission with its exact key', async () => {
    let grantBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            'tablet:permKeysList': () => ({
                ok: true,
                keys: FOUR_SHIPPED_KEYS_CATALOG.concat([
                    { key: 'k9.custom_ability', label: 'Custom Ability', description: 'A brand new ability an operator just invented.', isConfigDefault: false },
                ]),
            }),
            'tablet:grantPermission': (body) => { grantBody = body; return { ok: true }; },
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 5, 'the four shipped rows plus the one custom catalog row');
    t.equals(capabilityLabelText(rows[4]), 'Custom Ability', 'the custom key is appended after the four shipped ones, not spliced into their fixed order');

    findByText(rows[4], 'Grant')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(grantBody, 'tablet:grantPermission was actually called');
    t.equals(grantBody.targetCitizenId, 'TARGET1');
    t.equals(grantBody.permission, 'k9.custom_ability', 'the custom key name is sent verbatim, not one of the four hardcoded ones');
});

t.test('a held key absent from a successful catalog fetch (tombstoned) still renders, labelled retired, with Revoke but no Grant', async () => {
    let revokeBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            // k9.legacy_ability is held (an active grant row still exists)
            // but deliberately ABSENT from the catalog response below --
            // exactly what a tombstoned key looks like from this page's
            // point of view (server/permissionkeycatalog.lua's own
            // ListPermissionCatalogKeys excludes a tombstoned key entirely).
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.legacy_ability'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: FOUR_SHIPPED_KEYS_CATALOG }),
            'tablet:revokePermission': (body) => { revokeBody = body; return { ok: true }; },
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 5, 'the four shipped rows plus the retired-but-held row');
    const retiredRow = rows[4];
    t.contains(capabilityLabelText(retiredRow) || '', 'k9.legacy_ability', 'no catalog entry survives for this key, so its own raw key name is the best available label');
    const retiredBadges = findAll(retiredRow, (n) => typeof n._textContent === 'string' && n._textContent.indexOf('Retired') !== -1);
    t.equals(retiredBadges.length, 1, 'a retired badge is shown exactly once, on the retired row only');
    t.equals(findAll(rows[0], (n) => typeof n._textContent === 'string' && n._textContent.indexOf('Retired') !== -1).length, 0, 'the shipped k9.access row never carries a retired badge');
    t.equals(findByText(retiredRow, 'Grant').length, 0, 'a retired key is never offered a Grant control');
    t.equals(findByText(retiredRow, 'Revoke').length, 1, 'Revoke remains available -- this is exactly what makes it actually revocable');

    const revokeBtn = findByText(retiredRow, 'Revoke')[0];
    revokeBtn.click(); // arm confirm
    revokeBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(revokeBody, 'tablet:revokePermission was actually called for the retired key');
    t.equals(revokeBody.targetCitizenId, 'TARGET1');
    t.equals(revokeBody.permission, 'k9.legacy_ability');
});

t.test('a failed/denied catalog fetch falls back to exactly the four shipped keys -- never an empty panel', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: false, reason: 'denied' }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Capabilities').length, 1, 'the section heading itself still renders');
    const rows = getCapabilityRows(h);
    t.equals(rows.length, 4, 'falls back to exactly the four shipped keys, never zero');
    t.equals(findByText(h.getRoot(), 'Revoke').length, 1);
    t.equals(findByText(h.getRoot(), 'Grant').length, 3);
});

t.test('an unhandled/network-error catalog fetch (no tablet:permKeysList route at all) ALSO falls back to the four shipped keys, never a crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            // deliberately no 'tablet:permKeysList' handler -- routeFetch
            // rejects, fetchNui()'s own .catch() turns that into
            // { ok: false, error: 'network_error' }.
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 4, 'still exactly the four shipped keys after a hard fetch failure');
    t.equals(findByText(h.getRoot(), 'Grant').length, 4, 'none held -> all four offer Grant');
});

t.test('a hostile catalog label/description reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            'tablet:permKeysList': () => ({
                ok: true,
                keys: FOUR_SHIPPED_KEYS_CATALOG.concat([
                    { key: 'k9.custom_ability', label: malicious, description: malicious, isConfigDefault: false },
                ]),
            }),
        })),
    });
    await openPersonScreen(h);

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious catalog label reaches the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious catalog label/description');
});

t.run();
