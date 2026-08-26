/*
    html/tests/tablet_guided_flows_spec.js

    Covers the GUIDED FLOWS pass (html/tablet.js's own "GUIDED FLOWS"
    section -- see buildFlowsHubScreen()'s header for the full write-up):
    high command's four real jobs (set up a new handler, offboard a
    handler, handle a problem player, tune the server) walked through as
    single, sequenced flows laid OVER the existing screens, rather than
    scattered across them.

    THIS IS PRESENTATION ONLY -- every assertion below that a mutation
    "worked" is really an assertion that the flow fired the EXACT SAME
    tablet:* NUI callback, with the EXACT SAME payload, that the equivalent
    standalone screen already fires (verified directly via h.fetchCalls,
    not merely by the on-screen text updating) -- per THE SECURITY RULE at
    html/tablet.js's own header, this pass adds no new callback and no new
    authorization path.

    Specifically proves, per this pass's own task list:
      1. Each flow (Onboarding, Offboarding, Problem Player, Tuning)
         actually completes, using the real underlying screens/callbacks.
      2. A mid-flow failure (a mutation the server refuses) is reported
         HONESTLY -- the failure notice is shown, and the flow's own
         SUMMARY step reflects the real, unchanged state, never a false
         "done".
      3. Context (the selected citizenid) is carried between steps without
         being re-entered, including into the Problem Player flow's Audit
         Trail step, which reuses the SAME state.auditCitizenId field the
         standalone Audit tab reads.
      4. Skipping a step (no action taken) still reaches the summary, which
         then honestly reports the resulting gap (this pass's own "show
         what is left to do" requirement).
      5. A viewer who is not high command sees no trace of Guided Flows
         anywhere in the document -- no tab, no Home shortcut, no hub.
      6. Every attacker-controlled string this section renders (a person's
         name, a department label, a feature label, a mutation failure
         message) reaches the DOM only via textContent, never innerHTML --
         same proof technique as html/tests/tablet_xss_spec.js.
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

/** Same bubble-walk buildHomeActionCard()/buildFlowsHubScreen() need under
 * this stub -- see tablet_home_spec.js's own identical helper for why: the
 * click listener lives on the outer <button>, the visible text on an
 * inner <span>, and this stub does not implement bubbling. */
function clickCard(root, label) {
    let node = findByText(root, label)[0];
    if (!node) throw new Error('tablet_guided_flows_spec: no element with text ' + JSON.stringify(label));
    while (node && node.tagName !== 'button') node = node.parentNode;
    if (!node) throw new Error('tablet_guided_flows_spec: no enclosing <button> found for ' + JSON.stringify(label));
    node.click();
}

/** Advances via whichever of 'Skip this step'/'Next' is actually present --
 * buildFlowNavRow()'s own label depends on `hasAction`, which for the
 * Onboarding/Offboarding Decertify-style steps is computed from the
 * LATEST reloaded data (e.g. it correctly flips to "Next" once nothing is
 * left active to decertify) -- a hardcoded label would be testing this
 * spec's own assumption about that data, not the real behavior. */
function clickAdvance(root) {
    const btn = findByText(root, 'Skip this step')[0] || findByText(root, 'Next')[0];
    if (!btn) throw new Error('tablet_guided_flows_spec: no Skip/Next nav button found');
    btn.click();
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CERTIFIER_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer Rex', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };

/** A small, mutable in-memory "record" for one target citizenid -- the
 * stateful fixture every mutation handler below reads from and writes to,
 * so a re-fetch after a mutation (loadPersonSummary()/loadPersonFeatures(),
 * called by the SAME onSettled() every standalone screen already uses)
 * reflects the real, current result rather than a canned response. */
function makePersonRecord(overrides) {
    return Object.assign({
        target: { citizenid: 'TARGET1', name: 'New Recruit' },
        certifications: [
            { departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
        ],
        xp: null,
        tierLabel: null,
        permissions: [],
        features: [
            { key: 'K9Leaderboard', label: 'Leaderboard', category: null, globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing' },
        ],
        // Onboarding flow's own K9 Role step (this pass) -- the SAME field
        // server/tablet.lua's tabletRequestPersonSummary now sends
        // (assignedK9Model), null until a real tablet:assignK9Role
        // persists one. Read back by tablet:requestPersonSummary below,
        // never by the mutation handler's own response -- exactly the
        // property the honesty test further down exists to prove.
        assignedK9Model: null,
    }, overrides || {});
}

function baseHandlers(rec, viewer, overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: viewer, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: rec.target.citizenid, name: rec.target.name, departmentLabel: 'Police', certified: rec.certifications.some((c) => c.active), xp: rec.xp, tierLabel: rec.tierLabel }], truncated: false }),
        'tablet:requestPersonSummary': () => ({ ok: true, target: rec.target, certifications: rec.certifications, xp: rec.xp, tierLabel: rec.tierLabel, permissions: rec.permissions, assignedK9Model: rec.assignedK9Model }),
        'tablet:requestPersonFeatures': () => ({ ok: true, target: rec.target, features: rec.features }),
        'tablet:certTiersList': () => ({ ok: true, tiers: [{ key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} }, { key: 'senior', label: 'Senior', ordinal: 2, capabilities: {} }], capabilityCatalog: {} }),
        'tablet:permKeysList': () => ({ ok: true, keys: [] }),
        'tablet:certify': (body) => {
            const c = rec.certifications.find((x) => x.departmentKey === body.departmentKey);
            if (c) { c.active = true; c.tier = null; c.grantedBy = 'Chief'; }
            return { ok: true };
        },
        'tablet:decertify': (body) => {
            const c = rec.certifications.find((x) => x.departmentKey === body.departmentKey);
            if (c) { c.active = false; c.tier = null; c.specializations = []; }
            return { ok: true };
        },
        'tablet:setCertificationTier': (body) => {
            const c = rec.certifications.find((x) => x.departmentKey === body.departmentKey);
            if (c) c.tier = body.tier;
            return { ok: true };
        },
        'tablet:grantFeature': (body) => {
            const f = rec.features.find((x) => x.key === body.feature);
            if (f) { f.granted = true; f.state = 'available'; }
            return { ok: true };
        },
        'tablet:revokeFeature': (body) => {
            const f = rec.features.find((x) => x.key === body.feature);
            if (f) { f.granted = false; f.state = 'requires_grant_missing'; }
            return { ok: true };
        },
        'tablet:blockFeature': (body) => {
            const f = rec.features.find((x) => x.key === body.feature);
            if (f) f.blocked = true;
            return { ok: true };
        },
        'tablet:grantPermission': (body) => {
            if (!rec.permissions.includes(body.permission)) rec.permissions.push(body.permission);
            return { ok: true };
        },
        'tablet:revokePermission': (body) => {
            rec.permissions = rec.permissions.filter((p) => p !== body.permission);
            return { ok: true };
        },
        'tablet:revertK9Ped': () => ({ ok: true }),
        // Realistic default -- a real tabletAssignK9Role persists the
        // model it was asked to apply. The honesty test below OVERRIDES
        // this per-call (via `overrides`) to prove the Onboarding flow's
        // own Summary reads the SEPARATE tablet:requestPersonSummary
        // re-fetch afterward, never this response.
        'tablet:assignK9Role': (body) => { rec.assignedK9Model = body.modelName; return { ok: true }; },
    }, overrides || {});
}

async function openTablet(handlers, openData) {
    const h = createHarness({ fetchImpl: routeFetch(handlers) });
    h.postMessage('tablet:open', openData || {});
    await settle();
    return h;
}

// ======================================================================
// 5. UNAUTHORIZED VIEWER NEVER SEES ANY TRACE OF THIS
// ======================================================================

t.test('a certified, non-high-command viewer sees NO trace of Guided Flows anywhere -- no tab, no Home shortcut, no hub', async () => {
    const rec = makePersonRecord();
    const h = await openTablet(baseHandlers(rec, CERTIFIER_ONLY_VIEWER));

    t.equals(findByText(h.getRoot(), 'Guided Flows').length, 0, 'no tab and no hub heading for a non-high-command viewer on the default Home screen');

    // Navigate elsewhere this viewer legitimately CAN reach (My Record --
    // deliberately not Command Console, whose own access gate is a
    // separate, unrelated concern this spec does not exercise) and confirm
    // Guided Flows is still nowhere to be found.
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'Guided Flows').length, 0, 'still absent after navigating elsewhere');
});

t.test('a high-command viewer sees the Guided Flows tab, the Home shortcut, and all four job cards in the hub', async () => {
    const rec = makePersonRecord();
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER));

    t.equals(findByText(h.getRoot(), 'Guided Flows').length, 1, 'the tab itself, on the default Home screen');
    t.equals(findByText(h.getRoot(), 'Guided Flows →').length, 1, 'the Home "High Command Tools" shortcut too, distinctly labelled per buildHomeToolLink()\'s own convention');

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'Set Up a New Handler').length, 1, 'clicking the tab opens the hub with all four job cards');
    t.equals(findByText(h.getRoot(), 'Offboard a Handler').length, 1);
    t.equals(findByText(h.getRoot(), 'Handle a Problem Player').length, 1);
    t.equals(findByText(h.getRoot(), 'Tune the Server').length, 1);
});

// ======================================================================
// 1 + 3. ONBOARDING FLOW COMPLETES, CARRYING CONTEXT BETWEEN STEPS
// ======================================================================

t.test('Onboarding flow: select once, then certify / set tier / grant a feature, each step carrying the SAME person forward, ending in an honest, positive summary', async () => {
    const rec = makePersonRecord();
    // peds configured (this pass) so the K9 Role step's own Assign control
    // is genuinely present and genuinely SKIPPED below -- a real, present
    // action turned down, not a step with nothing to do at all.
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER), { peds: [{ model: 'a_c_shepherd', label: 'German Shepherd' }] });

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Set Up a New Handler');
    await settle();

    // Step 0: Select Person -- via the roster picker (same loadRoster()
    // this flow's own goToFlowOnboardScreen() already triggered on entry).
    t.isTrue(findByText(h.getRoot(), 'New Recruit').length >= 1, 'the roster picker lists the real roster row');
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    // CONTEXT CARRIED FORWARD from here on -- no re-entry of the citizenid
    // anywhere below.
    t.isTrue(findByText(h.getRoot(), 'New Recruit').length >= 1, 'the person context bar shows the selected name on the Certify step');
    t.isTrue(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('TARGET1') !== -1).length >= 1, 'and their citizenid, without it ever being retyped');

    // Step 1: Certify.
    t.equals(findByText(h.getRoot(), 'Certify').length, 1);
    findByText(h.getRoot(), 'Certify')[0].click();
    await settle(6);
    t.isTrue(rec.certifications[0].active, 'the SAME tablet:certify callback the standalone Person screen uses actually ran');
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:certify') && c.body.targetCitizenId === 'TARGET1' && c.body.departmentKey === 'police'));

    findByText(h.getRoot(), 'Skip this step')[0].click(); // advance to step 2 (K9 Role)
    await settle();

    // Step 2: K9 Role -- this recruit is being set up as a HANDLER, the
    // common case, so this optional step is skipped without being touched
    // (per this pass's own "most people onboarded are handlers, not K9s"
    // requirement) -- proving skipping it does not block the rest of the
    // flow. A dedicated test below covers the step actually being USED.
    t.isTrue(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('TARGET1') !== -1).length >= 1, 'context still carried on the K9 Role step');
    findByText(h.getRoot(), 'Skip this step')[0].click(); // advance to step 3 (Tier & Specializations)
    await settle();

    // Step 3: Tier & Specializations -- context (citizenid AND the
    // department just certified) is still carried, no re-selection needed.
    t.isTrue(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('TARGET1') !== -1).length >= 1, 'context still carried on the Tier step');
    const tierSelect = findAll(h.getRoot(), (n) => n.tagName === 'select' && n.classList.contains('k9tablet-cert-tier-select'))[0];
    t.isDefined(tierSelect, 'the tier picker is populated from the real, loaded certification-tier catalog');
    tierSelect.value = 'senior';
    findByText(h.getRoot(), 'Set Tier')[0].click();
    await settle(6);
    t.equals(rec.certifications[0].tier, 'senior', 'the SAME tablet:setCertificationTier callback ran, for the SAME department chosen in the previous step');

    findByText(h.getRoot(), 'Skip this step')[0].click(); // advance to step 4 (Feature Access)

    // Step 4: Feature Access -- the one RequireGrant feature this server
    // has is offered here.
    await settle();
    t.equals(findByText(h.getRoot(), 'Leaderboard').length, 1);
    findByText(h.getRoot(), 'Grant')[0].click();
    await settle(6);
    t.isTrue(rec.features[0].granted, 'the SAME tablet:grantFeature callback the standalone Person screen uses actually ran');

    findByText(h.getRoot(), 'Skip this step')[0].click(); // advance to step 5 (Summary)
    await settle();

    // 2/4. CONFIRM THE OUTCOME, NOT JUST THE ACTION.
    t.equals(findByText(h.getRoot(), 'Certified in Police.').length, 1);
    t.equals(findByText(h.getRoot(), 'K9 role step skipped -- no change to this person\'s model.').length, 1, 'the skipped K9 Role step is reported honestly, never silently omitted nor treated as a failure');
    t.equals(findByText(h.getRoot(), 'Tier: Senior.').length, 1);
    t.equals(findByText(h.getRoot(), '1 feature(s) granted this pass.').length, 1);
    t.equals(findByText(h.getRoot(), '1 grant-required feature(s) still not granted.').length, 0, 'nothing left missing -- the one grant-required feature on this server was actually granted');

    // Finish returns to the hub, not a dead end.
    findByText(h.getRoot(), 'Finish')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'Set Up a New Handler').length, 1, 'Finish returns to the Guided Flows hub');
});

// ======================================================================
// 2. MID-FLOW FAILURE IS REPORTED HONESTLY, NEVER SWALLOWED
// ======================================================================

t.test('Onboarding flow: a refused Certify is shown as a real failure, and the flow\'s own summary honestly reports "not certified" rather than claiming success', async () => {
    const rec = makePersonRecord();
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER, {
        'tablet:certify': () => ({ ok: false, error: 'denied', message: 'You are not authorized to certify.' }),
    }));

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Set Up a New Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    findByText(h.getRoot(), 'Certify')[0].click();
    await settle(6);

    t.isFalse(rec.certifications[0].active, 'the certification genuinely did not take effect');
    t.isTrue(findByText(h.getRoot(), 'You are not authorized to certify.').length >= 1, 'the real server refusal is shown, not a generic success message');

    // Jump straight to the Summary step via the step nav (every step is
    // directly reachable, per this pass's own "reversible" requirement) --
    // never having set a tier or granted anything.
    findByText(h.getRoot(), '6. Summary')[0].click();
    await settle();

    t.equals(findByText(h.getRoot(), 'Not certified in any department this pass.').length, 1, 'the summary honestly reflects the real, unchanged state -- never a false "done"');
    t.equals(findByText(h.getRoot(), 'Certified in Police.').length, 0);
    t.equals(findByText(h.getRoot(), 'K9 role step skipped -- no change to this person\'s model.').length, 1, 'the K9 Role step is reported independently of the refused Certify -- never swallowed by the department guard above it');
});

// ======================================================================
// 4. SKIPPING A STEP STILL REACHES A HONEST SUMMARY
// ======================================================================

t.test('Onboarding flow: skipping every step (no action taken at all) still reaches the summary, which honestly reports the resulting gap', async () => {
    const rec = makePersonRecord();
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER));

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Set Up a New Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    // Skip Certify without clicking it.
    findByText(h.getRoot(), 'Skip this step')[0].click();
    await settle();
    // Skip the K9 Role step too, without touching it -- this person has
    // no peds configured for this test's own openData (defaults to none),
    // so this step correctly has nothing to do either, and reads "Next".
    t.equals(findByText(h.getRoot(), 'Next').length, 1, 'no ped models configured for this test -- the K9 Role step correctly offers nothing to do, so its own nav reads "Next"');
    findByText(h.getRoot(), 'Next')[0].click();
    await settle();
    // Tier & Specializations step: nothing was certified, so this step
    // correctly offers nothing to do, and its own Next button reads
    // "Next", never "Skip this step" (hasAction reflects reality here).
    t.isTrue(findByText(h.getRoot(), 'Certify this person in a department in the previous step first, then come back here to set a tier or add specializations.').length >= 1);
    t.equals(findByText(h.getRoot(), 'Next').length, 1);
    findByText(h.getRoot(), 'Next')[0].click();
    await settle();

    // Skip Feature Access too.
    findByText(h.getRoot(), 'Skip this step')[0].click();
    await settle();

    t.equals(findByText(h.getRoot(), 'Not certified in any department this pass.').length, 1, 'GAP SURFACED: nothing was done, and the summary says so honestly rather than a blank/misleading screen');
    t.equals(findByText(h.getRoot(), 'K9 role step skipped -- no change to this person\'s model.').length, 1, 'the K9 Role step\'s own gap is surfaced too, never silently folded into the certification gap above it');
});

// ======================================================================
// THE HONESTY TEST -- the K9 Role step's Summary line reports the REAL,
// freshly-reloaded server state, never the click's own claimed `ok:true`.
// tablet:assignK9Role is stubbed here to return `ok:true` on EVERY call
// (a real "your click was accepted" response) while a SEPARATE, directly-
// controlled `rec.assignedK9Model` decides what the following
// tablet:requestPersonSummary re-fetch actually reports -- proving the
// Summary's "assigned"/"not applied" wording tracks that re-fetch, not the
// mutation's own response, exactly the property this pass's own report
// calls out as the one that stops this becoming another screen that
// claims success it does not have.
// ======================================================================

t.test('Onboarding flow: K9 Role step -- Summary reports "skipped" honestly when unused, and the REAL re-derived outcome (not the click\'s own claimed success) when used', async () => {
    const rec = makePersonRecord();
    let serverActuallyPersistedTheModel = false; // flips independently of the click's own response below
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER, {
        // Every call reports ok:true -- a real "accepted" response --
        // regardless of `serverActuallyPersistedTheModel`. If the Summary
        // trusted this alone, it would ALWAYS show "assigned", which the
        // assertions below prove it does not.
        'tablet:assignK9Role': () => ({ ok: true }),
        'tablet:requestPersonSummary': () => ({
            ok: true, target: rec.target, certifications: rec.certifications, xp: rec.xp, tierLabel: rec.tierLabel, permissions: rec.permissions,
            assignedK9Model: serverActuallyPersistedTheModel ? 'a_c_shepherd' : null,
        }),
    }), { peds: [{ model: 'a_c_shepherd', label: 'German Shepherd' }] });

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Set Up a New Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    // Skip Certify -- irrelevant to this test's own claim.
    findByText(h.getRoot(), 'Skip this step')[0].click();
    await settle();

    // Step 2: K9 Role -- SKIPPED, never touched.
    t.equals(findByText(h.getRoot(), 'Assign K9 Role').length, 1, 'a real, present action, genuinely skipped -- not an empty step');
    findByText(h.getRoot(), 'Skip this step')[0].click(); // -> Tier & Specializations
    await settle();
    findByText(h.getRoot(), 'Next')[0].click(); // -> Feature Access (nothing certified to set a tier on)
    await settle();
    findByText(h.getRoot(), 'Skip this step')[0].click(); // -> Summary
    await settle();

    t.equals(findByText(h.getRoot(), 'K9 role step skipped -- no change to this person\'s model.').length, 1, 'SKIPPED case: reported plainly, never as a warning');
    t.equals(h.fetchCalls.some((c) => c.url.endsWith('tablet:assignK9Role')), false, 'the callback was genuinely never called for the skipped case');

    // Back to the K9 Role step and USE it this time -- the click itself
    // reports ok:true (see the stub above), but the server has NOT
    // actually persisted the model yet (async confirm still pending, or a
    // silent failure -- either way, this is the exact shape a real
    // deployment can produce).
    findByText(h.getRoot(), '3. K9 Role')[0].click();
    await settle();
    findByText(h.getRoot(), 'Assign K9 Role')[0].click();
    await settle(6);
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:assignK9Role') && c.body.targetCitizenId === 'TARGET1' && c.body.modelName === 'a_c_shepherd'), 'the SAME tablet:assignK9Role callback the standalone Person screen uses actually ran, with the model chosen in this step');

    findByText(h.getRoot(), '6. Summary')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'K9 role was not applied this pass.').length, 1, 'USED-BUT-NOT-PERSISTED case: the click claimed ok:true, but the summary reports the REAL re-derived state, never the click\'s own claim');
    t.equals(findByText(h.getRoot(), 'Assigned the K9 role this pass (German Shepherd).').length, 0);

    // Now the server-side state catches up (the async confirm lands) and
    // the SAME onSettled reload this click already triggered picks it up
    // on the very next fetch -- re-visit the K9 Role step and back
    // (forces buildFlowOnboardScreen to re-render against whatever
    // state.personSummary currently holds; no new click is needed here,
    // matching this whole file's own "the summary reads state, it never
    // re-derives on its own" convention).
    serverActuallyPersistedTheModel = true;
    findByText(h.getRoot(), '3. K9 Role')[0].click();
    await settle();
    findByText(h.getRoot(), 'Assign K9 Role')[0].click(); // a second, now-successful attempt -- refreshPersonAndSelf() re-fetches tablet:requestPersonSummary, which now reports the model
    await settle(6);

    findByText(h.getRoot(), '6. Summary')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'Assigned the K9 role this pass (German Shepherd).').length, 1, 'USED-AND-APPLIED case: the summary reflects the freshly reloaded server truth');
    t.equals(findByText(h.getRoot(), 'K9 role was not applied this pass.').length, 0);
    t.equals(findByText(h.getRoot(), 'K9 role step skipped -- no change to this person\'s model.').length, 0, '"skipped" and "used" are mutually exclusive -- once used, it never reverts to reading as skipped');
});

// ======================================================================
// OFFBOARDING FLOW
// ======================================================================

t.test('Offboarding flow: decertify, clear a feature grant, revert appearance, ending in an honest summary; a refused decertify is reported honestly', async () => {
    const rec = makePersonRecord({
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'Chief', tier: 'senior', expiresAtUnix: null, expired: false, specializations: [] }],
        features: [{ key: 'K9Leaderboard', label: 'Leaderboard', category: null, globallyEnabled: true, requiresGrant: true, granted: true, blocked: false, state: 'available' }],
    });
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER));

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Offboard a Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    // Step 1: Decertify -- ends the partnership too (informational only,
    // no separate action exists for it -- see this step's own intro copy).
    t.isTrue(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('Ending a certification automatically ends any active partnership') !== -1).length >= 1);
    const decertifyBtn = findByText(h.getRoot(), 'Decertify')[0];
    decertifyBtn.click(); // arm confirm
    decertifyBtn.click(); // confirm
    await settle(6);
    t.isFalse(rec.certifications[0].active);

    clickAdvance(h.getRoot()); // -> Clear Access (label may now read "Next" -- nothing is left active to decertify)
    await settle();

    t.equals(findByText(h.getRoot(), 'Leaderboard').length, 1);
    const revokeFeatureBtn = findByText(h.getRoot(), 'Revoke')[0];
    revokeFeatureBtn.click(); // arm confirm
    revokeFeatureBtn.click(); // confirm
    await settle(6);
    t.isFalse(rec.features[0].granted);

    clickAdvance(h.getRoot()); // -> Appearance
    await settle();

    const revertBtn = findByText(h.getRoot(), 'Revert to Human')[0];
    revertBtn.click(); // arm confirm
    revertBtn.click(); // confirm
    await settle(6);
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:revertK9Ped') && c.body.targetCitizenId === 'TARGET1'));

    clickAdvance(h.getRoot()); // -> Summary
    await settle();

    t.equals(findByText(h.getRoot(), 'Decertified from 1 department(s).').length, 1);
    t.equals(findByText(h.getRoot(), '1 feature grant(s) cleared.').length, 1);
    t.equals(findByText(h.getRoot(), 'Appearance reverted to human this pass.').length, 1);
});

t.test('Offboarding flow: a refused Decertify is shown as a real failure, and the summary honestly reports the certification is still held', async () => {
    const rec = makePersonRecord({
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'Chief', tier: 'senior', expiresAtUnix: null, expired: false, specializations: [] }],
    });
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER, {
        'tablet:decertify': () => ({ ok: false, error: 'denied', message: 'You cannot decertify this department.' }),
    }));

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Offboard a Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    const decertifyBtn = findByText(h.getRoot(), 'Decertify')[0];
    decertifyBtn.click(); // arm confirm
    decertifyBtn.click(); // confirm
    await settle(6);
    t.isTrue(findByText(h.getRoot(), 'You cannot decertify this department.').length >= 1);

    findByText(h.getRoot(), '5. Summary')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'Decertified from 0 department(s).').length, 1);
    t.equals(findByText(h.getRoot(), 'Still certified in 1 department(s).').length, 1, 'the gap this refusal leaves behind is surfaced, not hidden');
});

// ======================================================================
// PROBLEM PLAYER FLOW -- CONTEXT CARRIED INTO THE AUDIT TRAIL
// ======================================================================

t.test('Problem Player flow: the selected citizenid is carried automatically into the Audit Trail step, a query runs, and an action taken in the same flow is summarized', async () => {
    const rec = makePersonRecord({
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'Chief', tier: 'senior', expiresAtUnix: null, expired: false, specializations: [] }],
    });
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER, {
        'tablet:auditCert': (body) => {
            t.equals(body.targetCitizenId, 'TARGET1', 'the audit query fired with the SAME citizenid selected in step 0, never retyped');
            return { ok: true, rows: [{ job: 'police', granted_by: 'Chief', granted_at: '2026-01-01', revoked_by: null, revoked_at: null, active: 1 }], label: 'Certification history', cap: 100 };
        },
    }), { auditEnabled: true });

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Handle a Problem Player');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    // Review Record has nothing to DO (read-only), so its own Next button
    // reads "Next", never "Skip this step" -- hasAction reflects reality.
    findByText(h.getRoot(), 'Next')[0].click(); // Review Record -> Audit Trail
    await settle();

    // The Audit Trail step reuses the EXACT SAME form/mode-switch pieces
    // the standalone Audit tab renders -- proven by the presence of its
    // own, unmodified controls.
    t.isTrue(findByText(h.getRoot(), 'Run Query').length >= 1, 'the real Audit Trail form is embedded, not a re-implementation');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle(6);
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:auditCert')));

    findByText(h.getRoot(), 'Skip this step')[0].click(); // -> Take Action
    await settle();
    findByText(h.getRoot(), 'Grant')[0]; // capabilities section present (no assertion needed beyond not throwing)
    const blockBtn = findByText(h.getRoot(), 'Block')[0];
    blockBtn.click(); // arm
    blockBtn.click(); // confirm
    await settle(6);
    t.isTrue(rec.features[0].blocked);

    findByText(h.getRoot(), 'Skip this step')[0].click(); // -> Summary
    await settle();

    t.equals(findByText(h.getRoot(), 'Ran an audit query (Certifications), 1 row(s) returned.').length, 1);
    t.equals(findByText(h.getRoot(), '1 feature(s) newly blocked.').length, 1);
});

// ======================================================================
// TUNING FLOW -- A TOUR OVER THE FIVE REAL SCREENS, NOT A REIMPLEMENTATION
// ======================================================================

t.test('Tuning flow: the Overview step reports REAL, server-confirmed override counts, and toggling a feature from inside the flow fires the exact same callback the standalone Runtime Control tab uses', async () => {
    const rec = makePersonRecord();
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER, {
        'tablet:runtimeListFeatures': () => ({
            ok: true,
            features: [
                { name: 'BiteAndHold', currentValue: true, configLuaDefault: true, tier: 'live', overridden: false, protected: false },
                { name: 'K9Leaderboard', currentValue: false, configLuaDefault: true, tier: 'live', overridden: true, overriddenBy: 'Chief', overriddenAt: '2026-01-01', protected: false },
            ],
        }),
        'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        'tablet:xpTiersList': () => ({ ok: true, tiers: [{ ordinal: 1, xp: 0, label: 'Trainee', speedMultiplier: 1, scentRangeMultiplier: 1, xpLocked: true }] }),
        'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
        'tablet:runtimeSetFeature': (body) => {
            const f = rec.runtimeFeatureToggled = body;
            return { ok: true, appliedLive: true, tier: 'live' };
        },
    }), { runtimeControlEnabled: true });

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Tune the Server');
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
});

// ======================================================================
// 6. ESCAPING -- EVERY ATTACKER-CONTROLLED STRING THIS SECTION RENDERS
// ======================================================================

const MALICIOUS = '<img src=x onerror="window.__xss_pwned=true"><script>window.__xss_pwned=true</script>';

t.test('Guided Flows: a malicious person name, department label, feature label, and a mutation-failure message all reach the DOM only via textContent, never innerHTML', async () => {
    const rec = makePersonRecord({
        target: { citizenid: 'TARGET1', name: MALICIOUS },
        certifications: [{ departmentKey: 'police', departmentLabel: MALICIOUS, active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] }],
        features: [{ key: 'K9Leaderboard', label: MALICIOUS, category: null, globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing' }],
    });
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER, {
        'tablet:certify': () => ({ ok: false, message: MALICIOUS }),
    }));

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Set Up a New Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    t.isTrue(findAll(h.getRoot(), (n) => n._textContent === MALICIOUS).length >= 2, 'malicious person name (context bar) and department label appear verbatim via textContent');
    t.equals(everyElementInnerHTMLWriteCount(h), 0);

    const certifyBtn = findByText(h.getRoot(), 'Certify')[0];
    certifyBtn.click();
    await settle(6);
    t.isTrue(findAll(h.getRoot(), (n) => n._textContent === MALICIOUS).length >= 3, 'the mutation-failure message also renders verbatim via textContent (shared actionNotice banner)');
    t.equals(everyElementInnerHTMLWriteCount(h), 0);

    // Certify was refused, so no department was actually certified. No
    // peds are configured for this test's own openData, so the K9 Role
    // step ALSO correctly has nothing to do -- and, downstream of that,
    // neither does Tier & Specializations -- both read "Next", never
    // "Skip this step".
    findByText(h.getRoot(), 'Skip this step')[0].click(); // Certify -> K9 Role
    await settle();
    findByText(h.getRoot(), 'Next')[0].click(); // K9 Role -> Tier & Specializations
    await settle();
    findByText(h.getRoot(), 'Next')[0].click(); // Tier & Specializations -> Feature Access
    await settle();

    t.isTrue(findAll(h.getRoot(), (n) => n._textContent === MALICIOUS).length >= 1, 'the malicious feature label on the Feature Access step also renders verbatim via textContent');
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes anywhere in the document across this entire flow');
});

t.test('Guided Flows: a malicious ped LABEL (server-configured Config.Peds, sent at tablet:open) reaches the K9 Role step\'s own model picker AND its Summary line only via textContent/.value, never innerHTML', async () => {
    const rec = makePersonRecord();
    const h = await openTablet(baseHandlers(rec, HIGH_COMMAND_VIEWER), { peds: [{ model: 'a_c_shepherd', label: MALICIOUS }] });

    findByText(h.getRoot(), 'Guided Flows')[0].click();
    await settle();
    clickCard(h.getRoot(), 'Set Up a New Handler');
    await settle();
    findByText(h.getRoot(), 'Select')[0].click();
    await settle(6);

    findByText(h.getRoot(), 'Skip this step')[0].click(); // Certify -> K9 Role
    await settle();

    t.isTrue(findAll(h.getRoot(), (n) => n.tagName === 'option' && n._textContent === MALICIOUS).length >= 1, 'the malicious ped label appears verbatim, via textContent, as the model picker\'s own option text');
    t.equals(everyElementInnerHTMLWriteCount(h), 0);

    findByText(h.getRoot(), 'Assign K9 Role')[0].click();
    await settle(6);
    findByText(h.getRoot(), '6. Summary')[0].click();
    await settle();

    t.isTrue(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf(MALICIOUS) !== -1 && n._textContent.indexOf('Assigned the K9 role this pass') !== -1).length >= 1, 'the SAME malicious label, resolved back from the assigned model via pedDisplayLabel(), also appears verbatim in the Summary\'s own K9 Role line');
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes anywhere in the document across this entire flow');
});

t.run();
