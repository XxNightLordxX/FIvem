/*
    html/tests/tablet_home_spec.js

    Covers the Home / landing view (html/tablet.js's own buildHomeScreen()
    -- see that function's own header for the full information-architecture
    writeup this pass introduced): the tablet is now organised around WHO
    IS HOLDING IT rather than which subsystem a screen belongs to, and this
    is the ONE screen every viewer type lands on first.

    Specifically proves:
      1. Home is the DEFAULT screen for every one of the four viewer types
         the owner named (K9, handler, partner, high command) -- no click
         required to reach it.
      2. Each viewer type gets the right ROLE BADGE and the right set of
         screens reachable from Home (progressive disclosure: High Command
         Tools only ever appears for state.viewer.isHighCommand === true).
      3. A viewer with ZERO active certifications gets a real, useful
         screen (an explicit guidance notice) instead of an empty shell,
         and still has a working path to their own (empty) record -- never
         a dead end.
      4. State-at-a-glance: the certified-department count and the
         blocked-ability count badges reflect the real numbers, and the
         blocked badge is absent entirely when the count is zero (never a
         "0 blocked" badge nobody needs to see).

    Escaping of the Home screen's one attacker-controlled surface (the
    welcome heading's interpolated viewer name/citizenid) is covered in
    html/tests/tablet_xss_spec.js, alongside every other screen this
    resource renders, per that file's own "keep this the one XSS suite"
    posture -- not duplicated here.
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
        if (!h) return Promise.reject(new Error('tablet_home_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

/**
 * buildHomeActionCard() puts its click listener on the OUTER <button>,
 * with the visible label/hint as two SEPARATE child <span> elements (see
 * that function's own doc comment) -- correct in a real browser (a click
 * on either span bubbles up to the button's own listener), but this
 * stub's own `_dispatch` deliberately does NOT implement bubbling (see
 * tablet-dom-stub.js's own header). Finds the label text via findByText
 * as usual, then walks UP to the enclosing <button> and clicks THAT node
 * -- exactly what a real click-then-bubble would already deliver to.
 * @param {object} root @param {string} label
 */
function clickActionCard(root, label) {
    var node = findByText(root, label)[0];
    if (!node) throw new Error('tablet_home_spec: no element with text ' + JSON.stringify(label));
    while (node && node.tagName !== 'button') node = node.parentNode;
    if (!node) throw new Error('tablet_home_spec: no enclosing <button> found for ' + JSON.stringify(label));
    node.click();
}

async function openTablet(myRecordResult, extraHandlers) {
    const h = createHarness({
        fetchImpl: routeFetch(Object.assign({
            'tablet:requestMyRecord': () => myRecordResult,
        }, extraHandlers || {})),
    });
    h.postMessage('tablet:open', {});
    await settle();
    return h;
}

// ======================================================================
// THE FOUR VIEWER TYPES -- role badge + right screens, all on the DEFAULT
// (no-click) Home screen.
// ======================================================================

t.test('HIGH COMMAND: lands on Home by default, role badge reads "High Command", and the High Command Tools shortcuts are all present', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC1', name: 'Chief Hopps', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'senior', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 500, tierLabel: 'Veteran K9', myFeatures: [],
    });

    t.isTrue(findByText(h.getRoot(), 'Welcome, Chief Hopps.').length >= 1, 'welcome heading shown immediately, no navigation needed');
    t.equals(findByText(h.getRoot(), 'High Command').length, 1, 'role badge reads High Command');
    t.equals(findByText(h.getRoot(), 'View My Record').length, 1);
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 1, 'high command also gets the console quick action');
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 1, 'the progressive-disclosure admin section is present');

    // Every admin shortcut exists, distinctly labelled from its own tab
    // (arrow suffix -- see buildHomeToolLink()'s own doc comment) so it
    // never collides with, or replaces, that tab's own single occurrence.
    for (const label of ['Tablet Theme', 'Certification Tiers', 'Permission Keys', 'Shop Locations', 'Shop Items', 'Runtime Control', 'XP Ranks', 'Audit Trail']) {
        t.equals(findByText(h.getRoot(), label).length, 1, `"${label}" tab itself still appears exactly once`);
        t.equals(findByText(h.getRoot(), label + ' →').length, 1, `"${label}" ALSO has a Home shortcut`);
    }
});

t.test('HIGH COMMAND: clicking a High Command Tools shortcut actually navigates to that real screen (not a dead link)', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    }, {
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    });

    findByText(h.getRoot(), 'Tablet Theme →')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Tablet Appearance').length >= 1, 'the Home shortcut opened the real Tablet Theme screen');
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:getTheme')), 'clicking the shortcut fired the SAME server round trip the real tab would');
});

t.test('CERTIFIED HANDLER (not high command, not a K9 model): role badge reads "Certified Handler", console quick action present, NO High Command Tools section', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'OFFICER1', name: 'Officer Rex', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 100, tierLabel: 'Trained K9',
        myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: 'Combat', actionable: true, state: 'available' }],
    });

    t.equals(findByText(h.getRoot(), 'Certified Handler').length, 1);
    t.equals(findByText(h.getRoot(), 'High Command').length, 0, 'no High Command role badge for this viewer');
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 0, 'admin section never renders for a non-high-command viewer');
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 1, 'k9.access alone already grants console access -- see server/tablet.lua ResolveEffectivePermissions');
    t.isTrue(findByText(h.getRoot(), 'Recall your K9').length >= 1, 'an actionable, available ability shows on Home\'s own "ready to use" list, not only on My Record');
});

t.test('K9 (isK9Model true, not high command): role badge reads "K9"', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'K9DOG1', name: 'Rex', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 0, tierLabel: null, myFeatures: [],
        // Simulates client/tablet.lua's ResolveLocalRoleFlags() enrichment
        // of this exact response (see that function's own doc comment) --
        // this suite mocks the round trip at the fetch layer the same way
        // every other spec in this directory already mocks the
        // server-authoritative fields.
        isK9Model: true,
    });

    t.equals(findByText(h.getRoot(), 'K9').length, 1, 'role badge reads K9, not Certified Handler, when this client is currently wearing a K9 model');
});

t.test('PARTNERED viewer shows the Partnered badge; a non-partnered viewer shows No Partner', async () => {
    const partnered = await openTablet({
        ok: true,
        viewer: { citizenid: 'P1', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
        isPartnered: true,
    });
    t.equals(findByText(partnered.getRoot(), 'Partnered').length, 1);
    t.equals(findByText(partnered.getRoot(), 'No Partner').length, 0);

    const unpartnered = await openTablet({
        ok: true,
        viewer: { citizenid: 'P2', name: 'B', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
        isPartnered: false,
    });
    t.equals(findByText(unpartnered.getRoot(), 'No Partner').length, 1);
    t.equals(findByText(unpartnered.getRoot(), 'Partnered').length, 0);
});

// ======================================================================
// NO CERTIFICATION IS NOT AN EMPTY SHELL
// ======================================================================

t.test('a viewer with ZERO active certifications and no console access sees real guidance, not a blank screen -- and still has a working path to their own record', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'NEW1', name: 'New Recruit', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] }],
        xp: null, tierLabel: null, myFeatures: [],
    });

    t.equals(findByText(h.getRoot(), 'New Arrival').length, 1, 'role badge for a not-yet-certified viewer');
    t.equals(findByText(h.getRoot(), "You're not certified yet").length, 1, 'the explicit no-certification notice title is shown');
    t.isTrue(findByText(h.getRoot(), 'Ask a certifier or a High Command officer to certify you in a department. Once certified, your abilities and record will appear here.').length >= 1);
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 0, 'no console access for this viewer -- the quick action is correctly absent, never a dead-click');
    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'the Console TAB is also absent for the same reason');

    // Still not a dead end: "My Record" is always reachable, and its own
    // screen already renders 'no_certifications'/'no_abilities' honestly
    // (see tests/... buildMyRecordScreen coverage elsewhere) rather than
    // erroring.
    t.equals(findByText(h.getRoot(), 'My Record').length, 1, 'the My Record tab is still present for every viewer, even this one');
    clickActionCard(h.getRoot(), 'View My Record');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Not certified').length >= 1, 'My Record itself also renders this department as honestly not-yet-certified, never an error or a blank screen');
});

t.test('a viewer with zero certifications who IS high command still sees the High Command Tools section (the notice is additive, never a replacement screen)', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC2', name: 'Overseer', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    });
    t.equals(findByText(h.getRoot(), 'New Arrival').length, 0, 'isHighCommand takes priority over the uncertified role label');
    t.equals(findByText(h.getRoot(), 'High Command').length, 1);
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 1, 'still gets full admin access despite holding no certification personally');
    // certifications is an empty array here (zero departments configured
    // in this mock), so the certified-count chip is correctly omitted
    // entirely -- "0 of 0" would be meaningless noise, not a real state.
    t.equals(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('of 0 departments') !== -1).length, 0);
});

// ======================================================================
// STATE AT A GLANCE
// ======================================================================

t.test('the certified-department count badge reflects the real numbers, and turns from the neutral to the positive colour class once at least one is active', async () => {
    const zeroActive = await openTablet({
        ok: true,
        viewer: { citizenid: 'C1', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [
            { departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
            { departmentKey: 'fire', departmentLabel: 'Fire', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
        ],
        xp: null, tierLabel: null, myFeatures: [],
    });
    t.equals(findByText(zeroActive.getRoot(), 'Certified in 0 of 2 departments').length, 1);
    t.equals(findAll(zeroActive.getRoot(), (n) => n._textContent === 'Certified in 0 of 2 departments' && n.classList && n.classList.contains('k9tablet-feature-state--global_off')).length, 1, 'zero-active state uses the SAME neutral/warning colour class every other screen uses for this meaning');

    const oneActive = await openTablet({
        ok: true,
        viewer: { citizenid: 'C2', name: 'B', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
        certifications: [
            { departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] },
            { departmentKey: 'fire', departmentLabel: 'Fire', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
        ],
        xp: null, tierLabel: null, myFeatures: [],
    });
    t.equals(findByText(oneActive.getRoot(), 'Certified in 1 of 2 departments').length, 1);
    t.equals(findAll(oneActive.getRoot(), (n) => n._textContent === 'Certified in 1 of 2 departments' && n.classList && n.classList.contains('k9tablet-feature-state--available')).length, 1, 'at-least-one-active state uses the SAME positive colour class every other screen uses for this meaning');
});

t.test('the blocked-ability count badge shows the real count and the correct colour, and is entirely ABSENT when nothing is blocked', async () => {
    const blocked = await openTablet({
        ok: true,
        viewer: { citizenid: 'C3', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [],
        xp: null, tierLabel: null,
        myFeatures: [
            { key: 'X', label: 'X', category: null, actionable: true, state: 'blocked' },
            { key: 'Y', label: 'Y', category: null, actionable: false, state: 'blocked' },
            { key: 'Z', label: 'Z', category: null, actionable: true, state: 'available' },
        ],
    });
    t.equals(findByText(blocked.getRoot(), '2 of your abilities are currently blocked').length, 1);
    t.equals(findAll(blocked.getRoot(), (n) => n._textContent === '2 of your abilities are currently blocked' && n.classList && n.classList.contains('k9tablet-feature-state--blocked')).length, 1);

    const notBlocked = await openTablet({
        ok: true,
        viewer: { citizenid: 'C4', name: 'B', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null,
        myFeatures: [{ key: 'Z', label: 'Z', category: null, actionable: true, state: 'available' }],
    });
    t.equals(findAll(notBlocked.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('currently blocked') !== -1).length, 0, 'no blocked-count badge at all when the count is zero -- never a "0 blocked" badge nobody needs');
});

t.test('the "ready to use right now" list shows ONLY actionable+available abilities, never a not-yet-usable one, and always offers a way to see the full list', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'C5', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null,
        myFeatures: [
            { key: 'Ready1', label: 'Ready Ability', category: null, actionable: true, state: 'available' },
            { key: 'NotActionable', label: 'Status Only Ability', category: null, actionable: false, state: 'available' },
            { key: 'Blocked1', label: 'Blocked Ability', category: null, actionable: true, state: 'blocked' },
        ],
    });
    t.equals(findByText(h.getRoot(), 'Ready Ability').length, 1);
    t.equals(findByText(h.getRoot(), 'Status Only Ability').length, 0, 'a non-actionable feature never appears in the "ready to use" list');
    t.equals(findByText(h.getRoot(), 'Blocked Ability').length, 0, 'a blocked feature never appears in the "ready to use" list either');
    t.equals(findByText(h.getRoot(), 'View all abilities').length, 1, 'a link to the full My Record list is always present, even when something is already ready here');
});

t.test('"ready to use right now" shows its own honest empty state (never a blank gap) when nothing is currently usable', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'C6', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    });
    t.equals(findByText(h.getRoot(), 'Nothing is ready to use right now.').length, 1);
});

t.run();
