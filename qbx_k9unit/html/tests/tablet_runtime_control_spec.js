/*
    html/tests/tablet_runtime_control_spec.js

    Covers the Runtime Control screen (its own tab, high command OR a
    delegated 'k9.runtimecontrol' grant -- server/runtimecontrol.lua's own
    CanManageRuntimeControl(source): IsHighCommand(source) OR
    HasPermission(citizenid, 'k9.runtimecontrol') == true,
    tests/runtimecontrol_spec.lua:523. Client-side gate: html/tablet.js's
    canManageRuntimeControl()) -- server/runtimecontrol.lua PART 1/1B.
    Owner's own words: "Lets high command switch features on and off
    SERVER-WIDE from the tablet, and tune numbers live."

    Server contract verified against server/runtimecontrol.lua directly
    (not assumed): runtimeListFeatures/runtimeListTunables each return
    `{ok, features?/tunables?, reason?}`; runtimeSetFeature/ResetFeature/
    SetTunable/ResetTunable each return `{ok, ..., reason?}` -- `reason`
    renamed to `error` by client/tablet.lua's TranslateReasonResult before
    it ever reaches this page, so every failure fixture below uses `error`,
    never `reason`.

    THE HONESTY REQUIREMENT is this file's main subject: a feature's `tier`
    ('live'|'onstart'|'rawtoplevel'|'clientonly'|'protected'|'unaudited')
    must render a plain-language explanation BEFORE any click, a
    protected/unaudited feature must render NO toggle at all, and a
    tunable's out-of-range refusal must echo the server's REAL min/max, not
    a client-guessed one.

    Every gate below is asserted as a CONVENIENCE, per html/tablet.js's own
    THE SECURITY RULE -- covered server-side in
    tests/runtimecontrol_spec.lua/tests/runtimefeaturetiers_spec.lua/
    tests/clienttabletruntimecontrol_spec.lua.
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
        if (!h) return Promise.reject(new Error('tablet_runtime_control_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CONSOLE_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };
// Holds the delegated capability but is NOT high command -- server/
// runtimecontrol.lua's own CanManageRuntimeControl admits this exact
// citizenid (see this file's header). See canManageRuntimeControl()'s own
// doc comment.
const DELEGATED_RUNTIME_CONTROL_VIEWER = { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.runtimecontrol'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    }, overrides || {});
}

async function openTablet(h, extraOpenData) {
    h.postMessage('tablet:open', Object.assign({ runtimeControlEnabled: true }, extraOpenData || {}));
    await settle();
}

function openRuntimeControlTab(h) {
    return findByText(h.getRoot(), 'Runtime Control')[0].click();
}

// ======================================================================
// GATING
// ======================================================================

t.test('a non-high-command console user never sees the Runtime Control tab', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Runtime Control').length, 0);
});

t.test('a non-high-command officer holding a delegated k9.runtimecontrol grant DOES see the Runtime Control tab, and can open it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: DELEGATED_RUNTIME_CONTROL_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    const tab = findByText(h.getRoot(), 'Runtime Control')[0];
    t.isTrue(!!tab, 'the tab itself is visible to a delegated non-high-command officer');
    tab.click();
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Runtime Feature Control').length >= 1, 'the real screen renders, not a dead end');
});

t.test('runtimeControlEnabled=false shows the disabled note (lists still fetched/shown regardless)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    h.postMessage('tablet:open', { runtimeControlEnabled: false });
    await settle();
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Runtime feature control is disabled server-wide. Current values are shown for reference only; changes will not save until it is re-enabled.').length >= 1);
});

// ======================================================================
// FEATURES -- DYNAMIC LIST + THE HONESTY REQUIREMENT
// ======================================================================

t.test('DYNAMIC LIST: features rendered come entirely from tablet:runtimeListFeatures, sorted by name', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [
                    { name: 'ZzyzxInventedFeature', currentValue: true, tier: 'live', overridden: false, protected: false },
                    { name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: false, protected: false },
                ],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'ZzyzxInventedFeature').length >= 1, 'a feature name this test invented on the fly renders correctly -- proves no hardcoded list');
    t.isTrue(findByText(h.getRoot(), 'BiteAndHold').length >= 1);

    // Sorted alphabetically -- BiteAndHold before ZzyzxInventedFeature.
    const names = findAll(h.getRoot(), (n) => n.tagName === 'td').map((n) => n.textContent).filter((tx) => tx === 'BiteAndHold' || tx === 'ZzyzxInventedFeature');
    t.equals(names[0], 'BiteAndHold');
    t.equals(names[1], 'ZzyzxInventedFeature');
});

t.test('empty features/tunables lists show their own empty-state notes, not a crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No features to show.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'No tunables to show.').length >= 1);
});

t.test('a load failure shows the error and a Retry button that re-fetches', async () => {
    let calls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => {
                calls++;
                return calls === 1 ? { ok: false, error: 'denied' } : { ok: true, features: [] };
            },
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'You are not authorized to manage runtime feature control.').length >= 1);
    findByText(h.getRoot(), 'Retry')[0].click();
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No features to show.').length >= 1);
    t.equals(calls, 2);
});

// ---- THE HONESTY REQUIREMENT: every tier renders its own plain-language explanation, BEFORE any click ----

t.test('a "live" feature shows the Live badge + its own honest description, and a toggle button', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Live').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Takes effect immediately for every player, and can be switched back at any time.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'On').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Disable').length >= 1, 'currently on -- offers Disable');
});

t.test('an "onstart" feature is honestly labelled Restart Required with its own explanation', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'AdminAuditCommands', currentValue: true, tier: 'onstart', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Restart Required').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Saved now, but only takes effect after this resource is restarted. Nothing changes for players in this session.').length >= 1);
});

t.test('a "rawtoplevel" feature is honestly labelled Config Edit + Restart Required', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'FetchMechanic', currentValue: true, tier: 'rawtoplevel', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Config Edit + Restart Required').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Saved, but a restart of this resource alone is NOT enough -- config.lua itself must also be edited to match, and the server restarted, for this to actually take effect.').length >= 1);
});

t.test('a "clientonly" feature is honestly labelled Client-Side Only', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'RadialMenu', currentValue: true, tier: 'clientonly', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Client-Side Only').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'This feature has no confirmed server-side effect. Saving this value cannot be confirmed to change anything for a connected player.').length >= 1);
});

t.test('a "protected" feature renders NO toggle/reset at all -- only the explanation', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'HighCommand', currentValue: true, tier: 'protected', overridden: false, protected: true }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Protected').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'This feature protects the authorization system this panel itself depends on, and can never be toggled from here. Change it in config.lua and restart if you are certain.').length >= 1);
    t.equals(findByText(h.getRoot(), 'Enable').length, 0);
    t.equals(findByText(h.getRoot(), 'Disable').length, 0);
});

t.test('an "unaudited" feature (a future 57th feature) renders NO toggle either -- shown, but refused for safety', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BrandNewFeature', currentValue: false, tier: 'unaudited', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Not Yet Classified').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'This feature has not yet been classified for runtime control, and is refused for safety. Ask a developer to audit it before it can be toggled here.').length >= 1);
    t.equals(findByText(h.getRoot(), 'Enable').length, 0);
});

t.test('a per-feature server-authored `note` (e.g. ScentTracking\'s drop-hook caveat) is shown as supplementary text, alongside the tier explanation', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'ScentTracking', currentValue: true, tier: 'live', note: 'A very specific caveat about the drop hook.', overridden: false, protected: false }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Takes effect immediately for every player, and can be switched back at any time.').length >= 1, 'primary, locale-driven tier explanation still shown');
    t.isTrue(findByText(h.getRoot(), 'A very specific caveat about the drop hook.').length >= 1, 'server-authored per-feature note shown as supplementary text');
});

// ======================================================================
// FEATURE TOGGLE / RESET
// ======================================================================

t.test('Enable/Disable requires two clicks (confirm), sends {name, value}', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': (body) => { setBody = body; return { ok: true, appliedLive: true, restartRequired: false, tier: 'live' }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click(); // arm confirm
    t.isNull(setBody, 'the first click only arms the confirm -- no request sent yet');
    enableBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.name, 'BiteAndHold');
    t.equals(setBody.value, true);
});

t.test('a rejected toggle (protected_feature/unaudited_feature refusal) renders inline on that row using the SAME tier explanation, not a generic failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'SomeFeature', currentValue: false, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: false, error: 'unaudited_feature' }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click();
    enableBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'This feature has not yet been classified for runtime control, and is refused for safety. Ask a developer to audit it before it can be toggled here.').length >= 1);
});

t.test('Reset to default only appears when overridden, requires two clicks, sends {name}', async () => {
    let resetBody = null;
    let listCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => {
                listCalls++;
                return { ok: true, features: [{ name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: true, overriddenBy: 'CIT1', overriddenAt: '2026-01-01 00:00:00', protected: false }] };
            },
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeResetFeature': (body) => { resetBody = body; return { ok: true, value: true, restartRequired: false }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Overridden by CIT1 at 2026-01-01 00:00:00').length >= 1);

    const resetBtn = findByText(h.getRoot(), 'Reset to default')[0];
    resetBtn.click();
    t.isNull(resetBody);
    resetBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(resetBody.name, 'BiteAndHold');
    t.isTrue(listCalls >= 2, 'a successful reset re-pulls the authoritative list rather than optimistically mutating locally');
});

t.test('a non-overridden feature shows no Reset button at all', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.equals(findByText(h.getRoot(), 'Reset to default').length, 0);
});

// ======================================================================
// TUNABLES -- EDIT / SAVE / RESET, SERVER IS THE ONLY AUTHORITATIVE RANGE CHECK
// ======================================================================

t.test('DYNAMIC LIST: tunables rendered come entirely from tablet:runtimeListTunables, with range and type shown', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'LeashMaxDistance').length >= 1);
    t.isTrue(findByText(h.getRoot(), '8.5').length >= 1);
    t.isTrue(findByText(h.getRoot(), '3 – 20').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Decimal').length >= 1);
});

t.test('an integer tunable shows "Whole number"', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'Tracking.Scent.maxAgeSeconds', currentValue: 300, min: 30, max: 3600, integer: true, overridden: false }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Whole number').length >= 1);
});

function findInput(root, predicate) {
    return findAll(root, (n) => n.tagName === 'input' && predicate(n))[0];
}

t.test('Edit opens an inline number editor pre-filled with the current value; Save sends {key, value}', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': (body) => { setBody = body; return { ok: true, appliedLive: true, restartRequired: false, value: 12 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    t.isDefined(input);
    t.equals(input.value, '8.5', 'pre-filled from the current value');
    input.typeValue('12');

    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.key, 'LeashMaxDistance');
    t.equals(setBody.value, 12);
});

t.test('Save with a non-numeric value shows a client-side "enter a valid number" note WITHOUT any server round trip', async () => {
    let setCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': () => { setCalled = true; return { ok: true, value: 1 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    input.typeValue('not-a-number');
    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isFalse(setCalled, 'a non-numeric value never reaches the server at all');
    t.isTrue(findByText(h.getRoot(), 'Enter a valid number.').length >= 1);
});

t.test('an out-of-range value IS sent to the server unclamped, and the server\'s REAL min/max is echoed back on refusal', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': (body) => { setBody = body; return { ok: false, error: 'out_of_range', min: 3.0, max: 20.0 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    input.typeValue('999999');
    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.value, 999999, 'this page never clamps a tunable value before sending it -- the server is the only authoritative gate');
    t.isTrue(findByText(h.getRoot(), 'That value must be between 3 and 20.').length >= 1, 'the server\'s own real bounds are shown, not a client-guessed range');
});

t.test('Cancel discards the edit without saving', async () => {
    let setCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': () => { setCalled = true; return { ok: true, value: 1 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number').typeValue('15');
    findByText(h.getRoot(), 'Cancel')[0].click();
    await settle();

    t.isFalse(setCalled);
    t.isTrue(findByText(h.getRoot(), '8.5').length >= 1, 'the original value is shown again, unchanged');
});

t.test('Reset (tunable) only appears when overridden, requires two clicks, sends {key}', async () => {
    let resetBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 12, min: 3.0, max: 20.0, integer: false, overridden: true, overriddenBy: 'CIT9', overriddenAt: '2026-02-02 00:00:00' }],
            }),
            'tablet:runtimeResetTunable': (body) => { resetBody = body; return { ok: true, value: 8, restartRequired: false }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Overridden by CIT9 at 2026-02-02 00:00:00').length >= 1);

    const resetBtn = findByText(h.getRoot(), 'Reset to default')[0];
    resetBtn.click();
    resetBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(resetBody.key, 'LeashMaxDistance');
});

// ======================================================================
// STALE-RESPONSE GUARD -- same class of race as tests/tablet_stale_response_spec.js
// and tablet_shop_locations_spec.js's own equivalent, applied here via a
// request-generation counter (this list has no per-request identity like a
// citizenid/query to compare against arrival order).
// ======================================================================

t.test('a late tablet:runtimeListFeatures response for an OLDER request never overwrites what a NEWER request already resolved', async () => {
    let resolveStale = null;
    let callNumber = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeListFeatures': () => {
                callNumber++;
                if (callNumber === 1) {
                    return new Promise((resolve) => {
                        resolveStale = () => resolve({ ok: true, features: [{ name: 'STALE_FIRST_RESULT', currentValue: true, tier: 'live', overridden: false, protected: false }] });
                    });
                }
                return { ok: true, features: [{ name: 'FRESH_SECOND_RESULT', currentValue: true, tier: 'live', overridden: false, protected: false }] };
            },
        })),
    });
    await openTablet(h);

    openRuntimeControlTab(h);
    await settle();
    t.isDefined(resolveStale, 'the first request was sent and is being held unresolved');

    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'FRESH_SECOND_RESULT').length >= 1, 'the second (current) request\'s result is showing');
    t.equals(findByText(h.getRoot(), 'STALE_FIRST_RESULT').length, 0, 'the first request has not (yet) resolved at all');

    resolveStale();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'FRESH_SECOND_RESULT').length >= 1, 'the fresh result is still showing after the late first response arrives');
    t.equals(findByText(h.getRoot(), 'STALE_FIRST_RESULT').length, 0, 'the late, OLDER response never replaces the current, NEWER one');
});

// ======================================================================
// LOCKOUT-RISK FEATURES (HighCommand/PermissionGrants/RuntimeFeatureControl/
// TabletTheming/CommandTablet) -- server/runtimecontrol.lua's own
// runtimeListFeatures already returns `lockoutRisk`/`sessionOnly`/
// `lockoutWarning` per row, and runtimeSetFeature/runtimeResetFeature
// already refuse a `lockoutRisk` feature without a `confirm` argument
// matching that feature's own `name` exactly (reason='confirmation_required'
// otherwise) -- this section covers the UI half that lets an operator
// actually satisfy that requirement: THE ROW MUST LOOK DIFFERENT BEFORE ANY
// CLICK, a real read-and-type confirmation (never the ordinary two-click
// mkConfirmButton pattern used for ordinary destructive actions elsewhere
// on this page) showing the server's OWN warning text verbatim, and a
// clear distinction for `sessionOnly` ("a restart puts this back").
// ======================================================================

const LOCKOUT_WARNING_TEXT = 'Disabling this immediately revokes access for EVERY high-command officer, including you. Nobody can use this screen to turn it back on once it is off. RECOVERY: restart this resource.';

t.test('a lockoutRisk + sessionOnly feature (e.g. HighCommand) shows the Lockout Risk AND Session-Only badges, and their own plain-language hints, BEFORE any click', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Lockout Risk').length >= 1, 'the Lockout Risk badge is visible before any click');
    t.isTrue(findByText(h.getRoot(), 'Session-Only').length >= 1, 'the Session-Only badge is visible before any click');
    t.isTrue(findByText(h.getRoot(), 'Disabling this can immediately lock every administrator, including you, out of this tablet. Changing it requires reading a full warning and typing the feature name to confirm.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Not saved to the database -- a restart alone reverts this, even without a config.lua edit.').length >= 1, 'the reassuring session-only explanation is shown, not just the risk warning');
    // The server's own full warning text is NOT shown yet -- only after
    // the operator actually clicks to open the confirmation panel.
    t.equals(findByText(h.getRoot(), LOCKOUT_WARNING_TEXT).length, 0, 'the full server warning is not rendered until the confirmation panel is opened');
});

t.test('a lockoutRisk feature that is NOT sessionOnly (e.g. CommandTablet) shows the Lockout Risk badge but NEVER the Session-Only badge', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'CommandTablet', currentValue: true, tier: 'rawtoplevel', overridden: false, protected: false, lockoutRisk: true, sessionOnly: false, lockoutWarning: 'Disabling this removes the tablet entirely once a config.lua edit and restart both happen.' }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Lockout Risk').length >= 1);
    t.equals(findByText(h.getRoot(), 'Session-Only').length, 0, 'a persisted lockout-risk feature never claims to be session-only');
});

t.test('a non-lockoutRisk feature never shows either badge', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.equals(findByText(h.getRoot(), 'Lockout Risk').length, 0);
    t.equals(findByText(h.getRoot(), 'Session-Only').length, 0);
});

// ---- THE SAFETY PROPERTY: a click alone must never mutate; only a MATCHING typed confirmation may ----

t.test('SAFETY: clicking a lockoutRisk toggle opens the confirmation panel and sends NOTHING -- the server\'s own warning is shown verbatim; a non-matching typed value keeps Confirm disabled and still sends nothing; only the EXACT feature name enables Confirm, which then sends {name, value, confirm: name}', async () => {
    let setCalls = [];
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': (body) => { setCalls.push(body); return { ok: true, appliedLive: true, restartRequired: false, tier: 'live', sessionOnly: true }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // A single click on the toggle for a lockoutRisk feature must ONLY
    // open the confirmation panel -- never the two-click arm/confirm
    // sequence, and never a request.
    const disableBtn = findByText(h.getRoot(), 'Disable')[0];
    disableBtn.click();
    await settle();
    t.equals(setCalls.length, 0, 'opening the confirmation panel alone never sends a request');
    t.isTrue(findByText(h.getRoot(), 'Confirm This Change').length >= 1, 'the read-and-type confirmation panel is now open');
    t.isTrue(findByText(h.getRoot(), LOCKOUT_WARNING_TEXT).length >= 1, 'the server\'s own lockoutWarning text is shown verbatim -- never this page\'s own wording');

    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    t.isDefined(confirmInput, 'the type-to-confirm input is present');

    // Wrong value -- Confirm must stay disabled, and clicking it (a
    // disabled button never fires its handler, see mkButton()) must send
    // nothing.
    confirmInput.typeValue('HighCommnad'); // typo, deliberately close but wrong
    await settle();
    const confirmBtnWrong = findByText(h.getRoot(), 'Confirm and Apply')[0];
    t.equals(confirmBtnWrong.getAttribute('disabled'), 'disabled', 'Confirm stays disabled until the typed value matches exactly');
    confirmBtnWrong.click();
    await settle();
    t.equals(setCalls.length, 0, 'a non-matching typed value never sends a request, even if Confirm is clicked directly');

    // Exact value -- Confirm enables, and the resulting call carries
    // `confirm` set to the feature's own name, exactly.
    confirmInput.typeValue('HighCommand');
    await settle();
    const confirmBtnRight = findByText(h.getRoot(), 'Confirm and Apply')[0];
    t.isTrue(confirmBtnRight.getAttribute('disabled') !== 'disabled', 'Confirm enables once the typed value matches exactly');
    confirmBtnRight.click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setCalls.length, 1, 'exactly one request was sent, only after a matching confirmation');
    t.equals(setCalls[0].name, 'HighCommand');
    t.equals(setCalls[0].value, false, 'currently on -- Disable requests newValue=false');
    t.equals(setCalls[0].confirm, 'HighCommand', 'confirm carries the exact feature name');
});

t.test('SAFETY: Cancel on the confirmation panel closes it and sends nothing', async () => {
    let setCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => { setCalled = true; return { ok: true }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Disable')[0].click();
    await settle();
    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    confirmInput.typeValue('HighCommand');
    await settle();

    findByText(h.getRoot(), 'Cancel')[0].click();
    await settle();

    t.isFalse(setCalled, 'Cancel never sends a request');
    t.equals(findByText(h.getRoot(), 'Confirm This Change').length, 0, 'the confirmation panel is closed');
    t.isTrue(findByText(h.getRoot(), 'Disable').length >= 1, 'the ordinary toggle button is back');
});

t.test('SAFETY: Reset (config.lua default) on a lockoutRisk feature goes through the SAME read-and-type panel, sending {name, confirm: name} -- never the ordinary two-click Reset', async () => {
    let resetCalls = [];
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'TabletTheming', currentValue: false, tier: 'live', overridden: true, overriddenBy: 'CIT1', overriddenAt: '2026-01-01 00:00:00', protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: 'Disabling this disables SetTheme/ResetTheme until a restart.' }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeResetFeature': (body) => { resetCalls.push(body); return { ok: true, value: true, restartRequired: false }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const resetBtn = findByText(h.getRoot(), 'Reset to default')[0];
    resetBtn.click(); // must NOT arm a two-click confirm -- opens the read-and-type panel instead
    await settle();
    t.equals(resetCalls.length, 0, 'opening the confirmation panel alone never sends a request');
    t.isTrue(findByText(h.getRoot(), 'Confirm This Change').length >= 1, 'the read-and-type panel opened, not an armed two-click button');

    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    t.isDefined(confirmInput, 'the same read-and-type panel is used for Reset');
    confirmInput.typeValue('TabletTheming');
    await settle();
    findByText(h.getRoot(), 'Confirm and Apply')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(resetCalls.length, 1);
    t.equals(resetCalls[0].name, 'TabletTheming');
    t.equals(resetCalls[0].confirm, 'TabletTheming');
});

t.test('a `confirmation_required` refusal (the server disagreeing with a stale/bypassed confirm) renders its OWN clear message, not a generic failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: false, error: 'confirmation_required', lockoutRisk: true, warning: LOCKOUT_WARNING_TEXT }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Disable')[0].click();
    await settle();
    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    confirmInput.typeValue('HighCommand');
    await settle();
    findByText(h.getRoot(), 'Confirm and Apply')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(
        findByText(h.getRoot(), 'The confirmation did not match the feature name exactly. Read the warning again and re-type it to confirm.').length >= 1,
        'a dedicated, clear message is shown for confirmation_required -- never a bare/generic failure'
    );
});

t.run();
