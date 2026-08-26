/*
    qbx_k9unit/html/tablet.js

    K9 Command Tablet -- Config.Features.CommandTablet. The in-game roster
    and self-service UI for certifications, XP, the four admin capabilities
    (Config.Permissions: k9.access/k9.certify/k9.audit/k9.givexp), and
    per-person feature enable/disable (Config.FeatureControl). Runs inside
    html/tablet.html, loaded once via an <iframe src="tablet.html"> embedded
    in html/index.html (see that file's own comment, and html/tablet-bridge.js,
    for the isolation mechanism this relies on) -- NOT a panel bolted onto
    the existing HUD document, and NOT touching html/app.js at all.

    ======================================================================
    THE SECURITY RULE -- READ THIS BEFORE CHANGING ANYTHING BELOW.

    THIS PAGE IS A VIEW. IT DECIDES NOTHING. Every single NUI callback this
    file fetches is re-authorized SERVER-SIDE from the caller's own live
    job, grants and blocks, exactly as if they had typed the equivalent
    chat command or pressed the equivalent keybind. A modified client can
    open this resource's dev tools (or skip this page entirely) and fire
    ANY of the fetch() calls below with ANY payload it likes, targeting any
    citizenid, any permission, any feature, any amount -- so a button
    existing on screen, or a section being rendered at all, must NEVER be
    what makes the action it fires permitted. Every `if (canX(...))` check
    in this file exists ONLY to decide what to show as a convenience for a
    legitimate user; deleting all of them would make this file annoying to
    use, never insecure, because the real gate lives entirely in
    client/tablet.lua and the server files behind it. If you are reading
    this because you're about to "simplify" by removing a server-side
    re-check because "the UI already hides that button" -- don't. That is
    exactly the mistake this comment exists to prevent.

    With this page now able to TRIGGER abilities (tablet:triggerFeature)
    and not just view/manage records, that rule matters even more than it
    did for the original grant/revoke/certify surface: a trigger callback
    must do the FULL validation the real command/keybind path already does
    (certification, feature flag, block, grant-if-required, cooldowns,
    target resolution) -- never less, just because the request arrived via
    NUI instead of a RegisterCommand.
    ======================================================================

    ======================================================================
    NUI CONTRACT -- must match client/tablet.lua exactly, byte-for-byte on
    every name and payload shape (this codebase's single most common
    silent-failure point: a mismatched name just hangs the fetch promise or
    drops a push silently, no error on either side). See this repo's
    coordination notes for the full write-up; short form below.

    Every RegisterNUICallback handler below MUST call its cb(...), even for
    a fire-and-forget message -- an uninvoked callback hangs this page's
    fetch() promise forever, which for a couple of these (tablet:ready,
    tablet:close) is harmless only because nothing here awaits them, but is
    the wrong thing to build on the Lua side regardless.

    JS -> Lua (RegisterNUICallback, fetch(`https://${resourceName}/<name>`)):

      tablet:ready {} -> cb({})
        Fired once, immediately after this page attaches its `message`
        listener (same ordering/race-closing purpose as html/app.js's own
        hud:ready). This page's iframe loads ONCE for the whole client
        session (never re-created per open/close), so this fires once per
        session, not once per open.

      tablet:requestMyRecord {} -> cb(MyRecordResult)
        Gated only by Config.FeatureControl.everyoneCanViewOwnRecord (and
        whatever base "are you even a real, loaded player" check makes
        sense) -- EVERY handler/K9 can call this, not just high command.
        MyRecordResult, success:
          {
            ok: true,
            viewer: {
              citizenid: string,
              name: string,
              isHighCommand: boolean,
              // Subset of ['k9.access','k9.certify','k9.audit','k9.givexp']
              // this CALLER currently qualifies for via ANY path (explicit
              // grant, high command bypass, or legacy rank gate) --
              // config.lua's own 4-step resolution order, already fully
              // resolved server-side. Convenience only, see THE SECURITY
              // RULE above.
              effectivePermissions: string[],
              allowSelfGrant: boolean, // mirrors Config.HighCommand.allowSelfGrant, UX hint only
            },
            certifications: [ { departmentKey, departmentLabel, active, grantedBy: string|null } ],
            xp: number|null,       // null if XPProgression is off or no record yet
            tierLabel: string|null,
            // Every Config.Features key this resource considers
            // "actionable" from the tablet, resolved for the CALLER
            // specifically -- see the `state` precedence note below.
            myFeatures: [
              {
                key: string,          // Config.Features key, e.g. 'BiteAndHold'
                label: string,        // human label -- config/locale-authored; falls back to a humanized key client-side if absent
                category: string|null,
                actionable: boolean,  // false = status-only row, no trigger button (most features have no single-button "use it now" action)
                // Precedence, first match wins (mirrors config.lua's own
                // FeatureControl resolution order, PLUS the base
                // certification gate underneath it):
                //   'global_off'              Config.Features.<key> is false
                //   'blocked'                 explicit per-person block row
                //   'not_certified'           lacks the underlying K9 access/certification this feature needs
                //   'requires_grant_missing'  key is in RequireGrant and caller holds no grant
                //   'available'               usable now (actionable buttons only meaningful here)
                state: 'global_off'|'blocked'|'not_certified'|'requires_grant_missing'|'available',
              },
            ],
          }
        Failure: { ok: false, error: string, message?: string }
        (error is a short machine code -- 'not_authorized'/'server_error'/
        anything else Lua wants to add; this page also synthesizes
        'timeout'/'network_error'/'exception' locally if the fetch itself
        never resolves -- see fetchNui() below. `message`, if present, is
        rendered verbatim via textContent as a human-readable detail.)

      tablet:triggerFeature { feature: string } -> cb({ ok, error?, message? })
        Gated by Config.FeatureControl.allowActionsFromTablet AND the SAME
        full resolution myFeatures[].state already describes -- re-checked
        from scratch server-side, never trusted from this page's own cached
        copy. No extra args in this pass: this fires the exact same
        client-side entry point the feature's existing keybind/command
        already calls, which resolves its own context (nearest target,
        etc.) exactly as it does today -- the tablet is an alternative
        trigger for that same path, not a new mechanism with its own
        targeting model. After ANY response (success or failure) this page
        re-calls tablet:requestMyRecord to refresh (cooldowns, certification
        changes, etc.) -- never assumes the local cached state is still
        accurate.

      tablet:requestRoster { query: string } -> cb(RosterResult)
        Only meaningful for a caller with at least one of
        effectivePermissions non-empty, or isHighCommand -- but, per THE
        SECURITY RULE, the SERVER must independently re-verify this on
        every call; this page hiding the "Command Console" tab for
        everyone else is a convenience, not the access control.
        `query` is the raw, untrimmed search box text (name/citizenid/
        department substring match, case-insensitive) -- arbitrary
        player-controlled string, never assume it's been sanitized here.
        Success:
          {
            ok: true,
            rows: [ { citizenid, name, departmentLabel, certified, xp, tierLabel } ],
            truncated: boolean,          // more rows exist beyond Config.CommandTablet.maxRosterRows for this query
            truncatedMessage?: string,   // pre-formatted, locale-resolved (e.g. locale('k9tablet.truncated_notice', rows.length)) -- preferred over this page building its own count text when present
          }
        Failure: { ok: false, error, message? }

      tablet:requestPersonSummary { targetCitizenId: string } -> cb(PersonSummaryResult)
        Same viewer-side gate as tablet:requestRoster (anyone who can see
        the console at all can open a person's summary from it).
        Success:
          {
            ok: true,
            target: { citizenid, name },
            certifications: [ { departmentKey, departmentLabel, active, grantedBy: string|null } ],
            // ^ ONE ROW PER CONFIGURED DEPARTMENT (Config.Departments),
            // including departments this citizenid has never held, so the
            // UI can offer "Certify" for a brand-new department, not only
            // "Decertify" for ones they already hold.
            xp: number|null,
            tierLabel: string|null,
            // Capability keys (Config.Permissions) this TARGET currently
            // holds -- rendered as read-only chips unless viewer.isHighCommand,
            // in which case grant/revoke controls are also shown.
            permissions: string[],
          }
        Failure: { ok: false, error, message? }

      tablet:requestPersonFeatures { targetCitizenId: string } -> cb(PersonFeaturesResult)
        HIGH COMMAND ONLY -- re-verified server-side regardless of what this
        page believes viewer.isHighCommand to be.
        Success:
          {
            ok: true,
            target: { citizenid, name },
            features: [
              {
                key, label, category,
                globallyEnabled: boolean,  // Config.Features.<key> -- if false, EVERYTHING else here is moot; this page renders NO controls at all for such a row, only a "disabled server-wide" note -- never a button that would silently do nothing
                requiresGrant: boolean,    // Config.FeatureControl.RequireGrant[key] === true
                granted: boolean,          // meaningful only if requiresGrant -- does this TARGET currently hold an explicit grant
                blocked: boolean,          // does this TARGET currently have an explicit block row -- ORTHOGONAL to requiresGrant/granted, see config.lua's own "steps 2 and 3 are DIFFERENT THINGS" note
                state: 'global_off'|'blocked'|'requires_grant_missing'|'available',
              },
            ],
          }
        Failure: { ok: false, error, message? }

      tablet:certify { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
      tablet:decertify { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
        Requires effectivePermissions to include 'k9.certify' (which already
        covers high command and legacy-rank certifiers per config.lua's own
        resolution order) -- re-verified server-side.

      tablet:givexp { targetCitizenId: string, amount: number } -> cb({ ok, error?, message? })
        Requires effectivePermissions to include 'k9.givexp'. `amount` is
        whatever numeric value this page's input currently holds --
        Config.HighCommand.maxXpPerGrant/allowSelfGrant/grantCooldownMs are
        ALL re-enforced server-side; this page only clamps the input's
        `max` attribute and disables self-targeting as a typo/UX guard.

      tablet:grantPermission { targetCitizenId: string, permission: string } -> cb({ ok, error?, message? })
      tablet:revokePermission { targetCitizenId: string, permission: string } -> cb({ ok, error?, message? })
        HIGH COMMAND ONLY. Granting/revoking one of the four admin
        capabilities is not itself delegable via any capability -- there is
        no fifth "can manage permissions" key -- so this page shows these
        controls ONLY when viewer.isHighCommand, distinct from the
        effectivePermissions-driven controls above.

      tablet:grantFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
      tablet:revokeFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
      tablet:blockFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
      tablet:unblockFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
        HIGH COMMAND ONLY, same reasoning as the permission grant/revoke
        pair above. Grant/Revoke and Block/Unblock are deliberately TWO
        SEPARATE, independent toggles per feature per config.lua's own
        instruction that these are different things -- never collapsed
        into one control.

      tablet:close {} -> cb({})
        Fire-and-forget. Tells Lua the player wants to close (Close button
        or Escape) so it can release SetNuiFocus. MUST be safe to call
        repeatedly / while already closed -- this page fires it from more
        than one path (button click, Escape inside this document, and
        html/tablet-bridge.js's own top-level Escape listener as a second,
        independent path for when keyboard focus is on the parent document
        instead of this iframe) and never waits for its response before
        hiding itself locally (see closeTablet() below -- the close path
        must never depend on a round trip succeeding).

    Lua -> JS (SendNUIMessage on the TOP window, relayed into this page's
    OWN window by html/tablet-bridge.js for any action matching /^tablet:/
    -- see that file's header for why a relay is needed at all):

      { action: 'tablet:open', data: {
          capabilities: { 'k9.access': {label,description}, ... },  // verbatim Config.Permissions text -- see html/tablet-bridge... no, see this file's DEFAULT_CAPABILITIES for the exact fallback copy this must match
          strings: { <key>: <resolved locale string>, ... },        // see DEFAULT_STRINGS below for the full key list this page understands
          maxXpPerGrant: number|null,                               // Config.HighCommand.maxXpPerGrant, UX hint only
        } }
        Sent once per open (every time the player runs the command/keybind
        that opens the tablet). This page reacts by becoming visible and
        immediately calling tablet:requestMyRecord.

      { action: 'tablet:close', data: {} }
        Lua-INITIATED close (player death, job change invalidating the
        session, resource stop). This page hides itself and resets ALL
        internal state back to a fresh-open baseline, so a later reopen
        never shows stale data from a previous session.
    ======================================================================

    ARCHITECTURE NOTE -- why an iframe, not a panel inside index.html:
    index.html's own `ui_page` is loaded once for the resource's entire
    client session and already hosts the always-on, focus-free HUD
    (html/app.js) -- FiveM's `ui_page` manifest key can only point at ONE
    file, so a genuinely separate document needs a different mechanism.
    This page is embedded via <iframe src="tablet.html"> inside
    index.html, itself unhidden/hidden by html/tablet-bridge.js. That gives
    this page its OWN JS global scope, its OWN DOM, and its OWN stylesheet
    -- a bug here (a global name collision, a CSS rule that would otherwise
    cascade) structurally CANNOT reach app.js's HUD, and vice versa. The
    one thing an iframe does NOT get for free is SendNUIMessage delivery --
    that lands on the top-level window only, never a descendant iframe
    automatically -- which is why tablet-bridge.js exists purely to relay
    tablet:* actions down into this page's own `message` listener below.

    FOCUS: this is the FIRST interactive, focus-taking NUI surface in this
    resource (contrast html/app.js's own "NO SetNuiFocus, ANYWHERE, EVER"
    HUD contract). SetNuiFocus itself is called ONLY from client/tablet.lua
    -- never from this file. This file's job on the closing side is only to
    reliably TELL Lua to release it (tablet:close) through every path a
    player might use to want out (Close button, Escape). Because a fully
    unresponsive/crashed copy of this page could never fire that fetch at
    all, client/tablet.lua should ALSO carry its own independent
    native-level Escape/close-keybind check that force-releases focus
    without depending on any NUI callback ever arriving -- flagged here so
    the requirement travels with the contract, not just in a chat message.
    ======================================================================
*/

(function () {
    'use strict';

    // ------------------------------------------------------------------
    // CONSTANTS
    // ------------------------------------------------------------------

    /** How long fetchNui() waits for a NUI callback response before giving
     * up and synthesizing a 'timeout' failure -- see this file's header
     * "never leave the player looking at an empty tablet with no
     * explanation" requirement. The underlying fetch is NOT aborted (no
     * AbortController dependency); its eventual real result, if any, is
     * simply ignored once this fires. */
    var NUI_TIMEOUT_MS = 8000;

    /** Debounce window for the roster search box -- avoids firing a
     * tablet:requestRoster round trip on every keystroke. */
    var SEARCH_DEBOUNCE_MS = 300;

    /** How long a destructive action button (Decertify/Revoke/Block) shows
     * its "Confirm?" state before reverting, if not clicked again -- see
     * makeConfirmButton() below. Deliberately NOT window.confirm()/alert():
     * FiveM's CEF-based NUI does not reliably support native browser
     * dialogs, so a real, in-DOM two-click confirm is used instead. */
    var CONFIRM_WINDOW_MS = 3000;

    /** English fallback UI-chrome strings, keyed exactly as
     * client/tablet.lua's `strings` map in the tablet:open payload uses
     * (see this file's header contract). client/tablet.lua's
     * BuildTabletStrings() sends `strings.title = locale('tablet.title')`
     * (and so on, one locale() call per key here) from locales/en.json's
     * `tablet` group, which is kept byte-identical to this object. Used
     * ONLY when a key is missing from that payload -- a hand-edited or
     * out-of-sync locale file, or a future key added here before
     * locales/*.json catches up -- so this page is never blank/broken for
     * a single missing key -- see S() below. This is a resilience net, not
     * a permanent i18n system: for every key currently in this object,
     * Lua already sends the real, locale()-resolved value, and this
     * fallback is simply never consulted.
     * @type {Record<string,string>} */
    var DEFAULT_STRINGS = {
        title: 'K9 Command Tablet',
        close_label: 'Close',
        tab_console: 'Command Console',
        tab_my_record: 'My Record',
        loading: 'Loading...',
        error_generic: 'Something went wrong. Try again.',
        error_not_authorized: 'You are not authorized to view this.',
        error_timeout: 'The server did not respond in time.',
        error_network: 'Could not reach the server.',
        retry_label: 'Retry',
        search_placeholder: 'Search by name, citizen ID, or department...',
        refresh_label: 'Refresh',
        empty_roster: 'No results.',
        column_name: 'Name',
        column_citizenid: 'Citizen ID',
        column_department: 'Department',
        column_certified: 'Certified',
        column_xp: 'XP / Tier',
        column_actions: 'Actions',
        certified_yes: 'Certified',
        certified_no: 'Not certified',
        certify_label: 'Certify',
        decertify_label: 'Decertify',
        confirm_label: 'Confirm?',
        grant_label: 'Grant',
        revoke_label: 'Revoke',
        block_label: 'Block',
        unblock_label: 'Unblock',
        manage_label: 'Manage',
        back_label: '← Back to roster',
        givexp_label: 'Give XP',
        givexp_placeholder: 'Amount',
        givexp_max_hint: 'Max per grant applies -- enforced by the server.',
        self_grant_disabled_title: 'High command cannot grant XP to themselves on this server.',
        truncated_notice: 'Showing a limited number of results. Refine your search to find someone not listed.',
        action_working: 'Working...',
        action_failed: 'Action failed.',
        action_succeeded: 'Done.',
        no_certifications: 'Not certified in any department.',
        my_certifications_heading: 'Certifications',
        my_xp_heading: 'XP',
        my_abilities_heading: 'Abilities',
        no_abilities: 'Nothing to show yet.',
        search_features_placeholder: 'Search abilities...',
        state_global_off: 'Disabled server-wide',
        state_blocked: 'Blocked',
        state_not_certified: 'Not certified',
        state_requires_grant_missing: 'Requires a grant (not granted)',
        state_available: 'Available',
        feature_column: 'Ability',
        status_column: 'Status',
        person_features_heading: 'Abilities',
        person_capabilities_heading: 'Capabilities',
        person_certifications_heading: 'Certifications',
        person_xp_heading: 'XP',
        xp_tier_unknown: 'No XP record yet.',
        use_label: 'Use',
        not_available_short: 'Unavailable',
        opening_person: 'Loading record...',

        // ---- Open-by-citizen-ID (console screen) -- see this file's
        // header note on why the roster search box alone cannot reach a
        // decertified/never-certified citizenid.
        open_by_id_placeholder: 'Open by exact citizen ID...',
        open_by_id_label: 'Open',
        open_by_id_empty: 'Enter a citizen ID first.',

        // ---- K9 role control (person screen, high command only) --
        // owner's own words: "assign de assign give certs remove certs
        // remove k9 ped and reverts them to a human".
        role_heading: 'K9 Role',
        role_model_label: 'Ped model',
        role_assign_label: 'Assign K9 Role',
        role_assign_hint: 'Turns this person into the selected model. Their current appearance is preserved for a later revert.',
        role_revert_label: 'Revert to Human',
        role_revert_hint: 'Forces this person back to human immediately -- works even if they hold no certification, no access, and no grant at all.',
        role_no_peds_configured: 'No ped models are configured on this server.',

        // ---- Tablet theming (its own tab, high command only to edit;
        // the resulting colours/density/title apply for every viewer).
        tab_theme: 'Tablet Theme',
        theme_heading: 'Tablet Appearance',
        theme_primary_label: 'Primary colour',
        theme_accent_label: 'Accent colour',
        theme_background_label: 'Background colour',
        theme_text_label: 'Text colour',
        theme_density_label: 'Density',
        theme_density_comfortable: 'Comfortable',
        theme_density_compact: 'Compact',
        theme_header_title_label: 'Header title',
        theme_save_label: 'Save Theme',
        theme_reset_label: 'Reset to Default',
        theme_disabled_note: 'Tablet theming is disabled server-wide. The current theme still applies; these controls will not save.',
        theme_field_invalid: 'That value was rejected by the server.',

        // ---- Certification tier editing (its own tab, high command
        // only). Owner's own words: "Allow high command to edit the
        // tiers trainee certified senior etc add more roles edit
        // permissions for those roles etc." The catalogue itself is
        // NEVER hardcoded here -- see loadCertTiers()'s own comment.
        tab_cert_tiers: 'Certification Tiers',
        cert_tiers_heading: 'Certification Tiers',
        cert_tiers_add_label: 'Add New Tier',
        cert_tier_key_label: 'Key',
        cert_tier_key_placeholder: 'e.g. master',
        cert_tier_label_label: 'Label',
        cert_tier_capabilities_label: 'Capabilities',
        cert_tier_no_capabilities: 'No capabilities selected.',
        cert_tier_save_label: 'Save Tier',
        cert_tier_cancel_label: 'Cancel',
        cert_tier_edit_label: 'Edit',
        cert_tier_delete_label: 'Delete',
        cert_tier_move_up_label: '↑',
        cert_tier_move_up_title: 'Move up (higher rank)',
        cert_tier_move_down_label: '↓',
        cert_tier_move_down_title: 'Move down (lower rank)',
        column_position: 'Position',
        column_key: 'Key',
        column_label: 'Label',
        column_capabilities: 'Capabilities',
        cert_tier_error_denied: 'You are not authorized to manage certification tiers.',
        cert_tier_error_rate_limited: 'Please wait a moment before trying again.',
        cert_tier_error_invalid_key: 'That key is invalid -- use 2-20 lowercase letters, numbers, or underscores, starting with a letter.',
        cert_tier_error_invalid_label: 'That label is invalid or too long (max 60 characters, no special markup characters).',
        cert_tier_error_invalid_capabilities: 'One or more selected capabilities is not recognized.',
        cert_tier_error_busy: 'This tier is being edited elsewhere right now -- try again in a moment.',
        cert_tier_error_too_many_tiers: 'The maximum number of certification tiers has been reached.',
        cert_tier_error_unknown_tier: 'That tier no longer exists.',
        cert_tier_error_protected_tier: '"Certified" is a protected tier and can never be deleted.',
        cert_tier_error_tier_in_use: 'This tier cannot be deleted -- {count} certification record(s) still reference it. Move them to a different tier first, then delete.',
        cert_tier_error_must_include_every_tier: 'The new order must include every existing tier, with none missing or duplicated.',
        cert_tier_error_invalid_key_set: 'The new order must include every existing tier, with none missing or duplicated.',
        cert_tier_error_db_error: 'A database error occurred. Try again.',
        cert_tier_error_invalid_payload: 'That request was malformed. Try again.',
    };

    /** English fallback for Config.Permissions -- MUST be kept byte-identical
     * to config.lua's own Config.Permissions label/description text (copied
     * verbatim from there, not invented here). Used only when
     * tablet:open's `capabilities` payload is missing or incomplete --
     * exactly the same fallback posture as DEFAULT_STRINGS above.
     * @type {Record<string,{label:string,description:string}>} */
    var DEFAULT_CAPABILITIES = {
        'k9.access': { label: 'Use K9 abilities', description: 'Equivalent to holding a K9 certification. Grant this to let someone work as a K9 without going through a certifying officer.' },
        'k9.certify': { label: 'Certify and decertify others', description: 'Grant and revoke K9 certifications. Normally requires a senior rank; this hands it to one specific person.' },
        'k9.audit': { label: 'View the audit records', description: 'Run the read-only audit commands. PRIVACY-SENSITIVE: this reveals who searched whom, and when.' },
        'k9.givexp': { label: 'Grant XP', description: 'Award XP directly to a K9 or handler. This mints economy value -- every use is logged.' },
    };

    /** Canonical order the four capability keys are rendered in, wherever
     * they're listed (my record, person summary) -- otherwise object key
     * order would depend on whatever order the server happens to send. */
    var CAPABILITY_ORDER = ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'];

    /** English fallback theme -- MUST be kept byte-identical to
     * server/runtimecontrol.lua's own DEFAULT_THEME, so this page looks
     * right even before tablet:getTheme's own response lands (or if it
     * never does -- see loadTheme() below). Never itself sent anywhere;
     * this is a local rendering fallback only, same posture as
     * DEFAULT_STRINGS/DEFAULT_CAPABILITIES above.
     * @type {{primaryColor:string,accentColor:string,backgroundColor:string,textColor:string,density:string,headerTitle:string}} */
    var DEFAULT_THEME = {
        primaryColor: '#2563eb',
        accentColor: '#f59e0b',
        backgroundColor: '#111827',
        textColor: '#f9fafb',
        density: 'comfortable',
        headerTitle: 'K9 Command Tablet',
    };

    /** The exact, fixed density enum server/runtimecontrol.lua's own
     * IsValidDensity accepts -- rendered as a `<select>`, never free text,
     * matching that file's own "a fixed lookup table, never free text"
     * comment. This page enforces the SAME set purely so the dropdown
     * cannot even offer a value the server would reject -- the server's own
     * re-check is still what actually matters (see THE SECURITY RULE). */
    var THEME_DENSITY_OPTIONS = ['comfortable', 'compact'];

    // ------------------------------------------------------------------
    // STATE -- single source of truth. Every mutation calls render(),
    // which clears and rebuilds the ENTIRE visible screen from this object.
    // No incremental DOM patching anywhere in this file: given this page's
    // real update frequency (user-driven clicks/searches, not a per-frame
    // HUD), a full rebuild per change is simpler to prove correct/secure
    // than tracking manual DOM diffs, at a perf cost that does not matter
    // here. See render() below.
    // ------------------------------------------------------------------
    var state = {
        open: false,
        screen: 'my_record', // 'my_record' | 'console' | 'person' | 'theme'
        strings: {},
        capabilities: {},
        maxXpPerGrant: null,
        peds: [], // Config.Peds, verbatim -- see tablet:assignK9Role's own NUI contract note; display list only, server re-validates the chosen model regardless
        themingEnabled: false, // Config.Features.TabletTheming -- UX hint only, see client/tablet.lua's own NUI CONTRACT note
        branding: {}, // { serverName, logo, theme:{4 colors} } -- Config.CommandTablet.branding, verbatim; see buildBrandingElement()/applyBrandingSeedTheme()

        viewer: null, // set once tablet:requestMyRecord resolves successfully
        myRecordLoading: false,
        myRecordError: null, // { error, message }
        myRecord: null, // { certifications, xp, tierLabel, myFeatures }

        rosterLoading: false,
        rosterError: null,
        roster: null, // { rows, truncated, truncatedMessage }
        rosterQuery: '',
        openByIdValue: '', // console screen's "open by exact citizen ID" box -- see buildConsoleScreen()

        person: null, // { citizenid, name } -- who the 'person' screen is currently showing
        personSummaryLoading: false,
        personSummaryError: null,
        personSummary: null, // { certifications, xp, tierLabel, permissions }
        personFeaturesLoading: false,
        personFeaturesError: null,
        personFeatures: null, // { features }
        personFeatureQuery: '',

        // Tablet theming -- applied for EVERY viewer (theme itself is
        // fetched once per open and again live on every
        // qbx_k9unit:client:themeUpdated push, regardless of which screen
        // is showing or whether this viewer is high command at all).
        theme: null, // { primaryColor, accentColor, backgroundColor, textColor, density, headerTitle } -- null until the first tablet:getTheme resolves; DEFAULT_THEME is used to render/apply in the meantime, see applyThemeToDocument()
        themeLoading: false,
        themeError: null,
        themeDraft: null, // a WORKING COPY of `theme` the theme-editor screen's inputs mutate locally before Save -- never sent anywhere until the operator presses Save, and always reset from the authoritative `theme` on load/open/push so a stale edit can never silently linger across a reopen
        themeFieldError: null, // set to e.g. 'primaryColor' when the server's last tabletSetTheme response was reason='invalid_field' -- highlights which of the six inputs it rejected; cleared on the next Save attempt

        // Certification tier editing -- server/certtiers.lua. The
        // catalogue is NEVER hardcoded here (see loadCertTiers()'s own
        // comment): `certTiers` is null until the first successful
        // tablet:certTiersList, exactly like every other server-sourced
        // list on this page (roster/personSummary/personFeatures/theme).
        certTiers: null, // [{ key, label, ordinal, capabilities: {capKey:true} }, ...], already ordinal-sorted by the server
        certTierCapabilityCatalog: {}, // { [capabilityKey]: { label } } -- server/certtiers.lua's own fixed, code-owned CAPABILITY_CATALOG, still FETCHED rather than hardcoded, so a future catalog entry needs no client change here
        certTiersLoading: false,
        certTiersError: null,
        certTierWarning: null, // the non-optional retroactive-rerank warning from the LAST successful reorder (server/certtiers.lua's own HAZARD 3) -- rendered as its own prominent banner, not folded into the generic actionNotice, so it is never missed
        certTierDraft: null, // { key, label, capabilities: {capKey:true}, isNew } -- the add/edit form's own working copy; null = form closed
        certTierFieldError: null, // 'key' | 'label' | 'capabilities' | null -- which of the draft form's own inputs the server's last certTiersUpsert rejected
        certTierActionError: null, // { key, text } -- a delete REFUSAL (tier_in_use/protected_tier) rendered inline on that specific row, not just the generic top-of-panel notice

        pendingAction: false, // true while ANY mutation/trigger fetch is in flight -- disables action buttons to prevent double-submit
        actionNotice: null, // { kind: 'ok'|'error', text: string } -- transient, cleared on next navigation/reload
    };

    var searchDebounceTimer = null;

    // ------------------------------------------------------------------
    // DOM REFS
    // ------------------------------------------------------------------
    var rootEl = null;

    // ------------------------------------------------------------------
    // NETWORKING
    // ------------------------------------------------------------------

    /**
     * Resolves this resource's name for building an NUI callback URL.
     * Primary path mirrors html/app.js's own GetParentResourceName() use.
     * SECONDARY path (window.parent.GetParentResourceName()) is a defensive
     * fallback ONLY -- this page's own primary assumption, stated plainly
     * rather than silently relied on, is that CitizenFX exposes
     * GetParentResourceName() to every frame of this resource's NUI
     * browser (top document AND iframes alike), not only the top one; this
     * is reasonable and community-precedented (iframe-based multi-page NUI
     * is a known pattern) but was NOT independently verified in-engine
     * this pass. If that assumption ever turns out wrong, the fallback
     * below (same-origin access to the parent window, which this page's
     * whole iframe design already depends on for html/tablet-bridge.js's
     * relay to work at all) covers it.
     * @returns {string}
     */
    function resolveResourceName() {
        try {
            if (typeof GetParentResourceName === 'function') return GetParentResourceName();
        } catch (err) {
            // fall through
        }
        try {
            if (window.parent && typeof window.parent.GetParentResourceName === 'function') {
                return window.parent.GetParentResourceName();
            }
        } catch (err) {
            // cross-origin or otherwise inaccessible -- fall through
        }
        // Last-resort dev-preview literal -- NOT a production fallback path,
        // mirrors app.js's own "opened directly in a plain browser" posture,
        // just made non-throwing here (a hardcoded resource name lets the
        // fetch attempt happen and fail gracefully through fetchNui()'s own
        // error handling below, rather than throwing synchronously).
        return 'qbx_k9unit';
    }

    /**
     * Fetches one NUI callback. NEVER rejects -- always resolves with
     * either the parsed JSON body, or a synthesized `{ ok: false, error }`
     * on timeout/network failure/malformed response, so every caller below
     * can treat this uniformly and this page can always show a clear
     * failure state rather than hang indefinitely (per this file's header
     * "never leave the player looking at an empty tablet" requirement).
     * @param {string} name
     * @param {object} [payload]
     * @returns {Promise<object>}
     */
    function fetchNui(name, payload) {
        return new Promise(function (resolve) {
            var settled = false;
            var timer = setTimeout(function () {
                if (settled) return;
                settled = true;
                resolve({ ok: false, error: 'timeout' });
            }, NUI_TIMEOUT_MS);

            function finish(result) {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                resolve(result);
            }

            try {
                fetch('https://' + resolveResourceName() + '/' + name, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                    body: JSON.stringify(payload || {}),
                }).then(function (resp) {
                    return resp.json().catch(function () { return {}; });
                }).then(function (json) {
                    finish(json && typeof json === 'object' ? json : {});
                }).catch(function () {
                    finish({ ok: false, error: 'network_error' });
                });
            } catch (err) {
                finish({ ok: false, error: 'exception' });
            }
        });
    }

    /** Fire-and-forget variant for messages this page never waits on
     * (tablet:ready, tablet:close) -- same underlying fetch, response
     * ignored entirely, swallows any construction-time throw. */
    function fireAndForget(name, payload) {
        try {
            fetch('https://' + resolveResourceName() + '/' + name, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify(payload || {}),
            }).catch(function () {});
        } catch (err) {
            // Swallowed -- see resolveResourceName()'s own dev-preview note.
        }
    }

    // ------------------------------------------------------------------
    // STRING / LABEL HELPERS
    // ------------------------------------------------------------------

    /** @param {string} key @returns {string} */
    function S(key) {
        if (state.strings && typeof state.strings[key] === 'string' && state.strings[key].length > 0) {
            return state.strings[key];
        }
        return DEFAULT_STRINGS[key] || key;
    }

    /** @param {string} key @returns {{label:string,description:string}} */
    function capabilityInfo(key) {
        var fromServer = state.capabilities && state.capabilities[key];
        if (fromServer && typeof fromServer.label === 'string' && fromServer.label.length > 0) return fromServer;
        return DEFAULT_CAPABILITIES[key] || { label: key, description: '' };
    }

    /** Turns 'BiteAndHold' into 'Bite And Hold' -- last-resort label for a
     * feature key the server didn't (yet) send a human `label` for, so
     * this page never renders a blank cell. Not a substitute for real,
     * non-technical-officer-facing copy -- see this file's header/this
     * pass's hand-off note for that ask.
     * @param {string} key @returns {string} */
    function humanizeFeatureKey(key) {
        if (typeof key !== 'string' || key.length === 0) return '';
        return key
            .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
            .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
            .trim();
    }

    /** @param {{key:string,label?:string}} feature @returns {string} */
    function featureLabel(feature) {
        if (feature && typeof feature.label === 'string' && feature.label.length > 0) return feature.label;
        return humanizeFeatureKey(feature ? feature.key : '') || (feature ? String(feature.key) : '');
    }

    /** @param {string} state key @returns {string} localized state badge text */
    function featureStateLabel(s) {
        switch (s) {
            case 'global_off': return S('state_global_off');
            case 'blocked': return S('state_blocked');
            case 'not_certified': return S('state_not_certified');
            case 'requires_grant_missing': return S('state_requires_grant_missing');
            case 'available': return S('state_available');
            default: return S('not_available_short');
        }
    }

    // ------------------------------------------------------------------
    // DOM BUILD HELPERS -- every string value below is assigned via
    // `.textContent`, NEVER `.innerHTML` (this page never writes innerHTML
    // anywhere -- see html/tests/tablet_xss_spec.js, which proves this the
    // same way html/tests/xss_spec.js proves it for html/app.js).
    // ------------------------------------------------------------------

    function clearChildren(node) {
        while (node.firstChild) node.removeChild(node.firstChild);
    }

    /**
     * @param {string} tag
     * @param {{class?:string, text?:string, attrs?:Record<string,string>, title?:string}} [opts]
     * @returns {HTMLElement}
     */
    function mk(tag, opts) {
        opts = opts || {};
        var node = document.createElement(tag);
        if (opts.class) node.className = opts.class;
        if (typeof opts.text === 'string' || typeof opts.text === 'number') node.textContent = String(opts.text);
        if (opts.title) node.setAttribute('title', opts.title);
        if (opts.attrs) {
            for (var k in opts.attrs) {
                if (Object.prototype.hasOwnProperty.call(opts.attrs, k)) node.setAttribute(k, opts.attrs[k]);
            }
        }
        return node;
    }

    /**
     * @param {string} text
     * @param {string} cls
     * @param {() => void} onClick
     * @param {{disabled?:boolean,title?:string}} [opts]
     */
    function mkButton(text, cls, onClick, opts) {
        opts = opts || {};
        var btn = mk('button', { class: cls, text: text, title: opts.title });
        btn.setAttribute('type', 'button');
        if (opts.disabled) btn.setAttribute('disabled', 'disabled');
        btn.addEventListener('click', function (e) {
            if (e && typeof e.preventDefault === 'function') e.preventDefault();
            if (btn.getAttribute('disabled')) return;
            onClick();
        });
        return btn;
    }

    /**
     * A two-click confirm button for destructive actions (Decertify,
     * Revoke, Block/Unblock) -- see CONFIRM_WINDOW_MS's own comment for why
     * this exists instead of window.confirm(). First click swaps the label
     * to S('confirm_label') and arms a revert timer; a second click within
     * the window calls onConfirm(); anything else (timeout, or the whole
     * screen re-rendering for an unrelated reason) simply discards the
     * armed state, since render() rebuilds this element from scratch.
     * @param {string} label
     * @param {string} cls
     * @param {() => void} onConfirm
     * @param {{disabled?:boolean,title?:string}} [opts]
     */
    function mkConfirmButton(label, cls, onConfirm, opts) {
        var armed = false;
        var revertTimer = null;
        var btn = mkButton(label, cls, function () {
            if (!armed) {
                armed = true;
                btn.textContent = S('confirm_label');
                revertTimer = setTimeout(function () {
                    armed = false;
                    btn.textContent = label;
                }, CONFIRM_WINDOW_MS);
                return;
            }
            clearTimeout(revertTimer);
            onConfirm();
        }, opts);
        return btn;
    }

    // ------------------------------------------------------------------
    // RENDER
    // ------------------------------------------------------------------

    function render() {
        if (!rootEl) return;
        clearChildren(rootEl);
        if (!state.open) return;

        rootEl.appendChild(buildBackdrop());
    }

    function buildBackdrop() {
        var backdrop = mk('div', { class: 'k9tablet-backdrop' });
        // Density is COSMETIC ONLY (see server/runtimecontrol.lua's own PART
        // 2 header) -- applied here as a plain class on the panel this
        // render() rebuilds from scratch every time, never persisted on any
        // element across renders, exactly like every other piece of this
        // page's state.
        var density = (state.theme && state.theme.density) || DEFAULT_THEME.density;
        var panelClass = 'k9tablet-panel' + (density === 'compact' ? ' k9tablet-density-compact' : '');
        var panel = mk('div', { class: panelClass, attrs: { role: 'dialog', 'aria-modal': 'true' } });
        panel.appendChild(buildHeader());

        if (state.actionNotice) {
            panel.appendChild(buildActionNotice());
        }

        if (!state.viewer) {
            panel.appendChild(buildViewerGate());
            backdrop.appendChild(panel);
            return backdrop;
        }

        var canManageRoster = state.viewer.isHighCommand || (state.viewer.effectivePermissions && state.viewer.effectivePermissions.length > 0);
        if (canManageRoster) {
            panel.appendChild(buildTabs());
        }

        if (state.screen === 'console' && canManageRoster) {
            panel.appendChild(buildConsoleScreen());
        } else if (state.screen === 'person' && canManageRoster) {
            panel.appendChild(buildPersonScreen());
        } else if (state.screen === 'theme' && state.viewer.isHighCommand) {
            panel.appendChild(buildThemeScreen());
        } else if (state.screen === 'cert_tiers' && state.viewer.isHighCommand) {
            panel.appendChild(buildCertTiersScreen());
        } else {
            panel.appendChild(buildMyRecordScreen());
        }

        backdrop.appendChild(panel);
        return backdrop;
    }

    function buildHeader() {
        var header = mk('div', { class: 'k9tablet-header' });

        var left = mk('div', { class: 'k9tablet-header-left' });
        left.appendChild(buildBrandingElement());
        var titleText = (state.theme && typeof state.theme.headerTitle === 'string' && state.theme.headerTitle.length > 0)
            ? state.theme.headerTitle : S('title');
        left.appendChild(mk('h1', { class: 'k9tablet-title', text: titleText }));
        header.appendChild(left);

        header.appendChild(mkButton('×', 'k9tablet-close-btn', requestClose, { title: S('close_label') }));
        return header;
    }

    /**
     * Server logo + name (Config.CommandTablet.branding, owner-supplied)
     * -- MUST DEGRADE TO TEXT: a missing/failed-to-load image shows
     * `serverName` alone, NEVER a broken-image icon, since the operator
     * hand-swaps html/images/logo.png and may typo/omit it (config.lua's
     * own comment: "It never shows a broken image"). The `error` listener
     * below is the ONLY place this file ever mutates an already-built
     * element's style directly rather than going through state+render() --
     * a deliberate, narrow exception: an <img> load failure is an
     * asynchronous BROWSER event with no corresponding state change this
     * page's own render() cycle would ever naturally re-run for, and the
     * fix (hide the broken image, reveal the plain-text fallback that is
     * ALREADY in the DOM right beside it) is a pure, local, one-way,
     * idempotent visibility flip -- see html/tests/tablet-dom-stub.js's
     * Element.style (`{}`, a plain settable object) for how this stays
     * fully testable without a real image-loading engine: a test can
     * dispatch the SAME 'error' event this real img element would.
     * `serverName`/`logo` are OPERATOR-SUPPLIED, DOM-bound strings --
     * rendered via mk()'s own textContent-only path / an `alt` attribute
     * only, never innerHTML, matching html/tests/tablet_xss_spec.js's own
     * coverage of this exact element.
     */
    function buildBrandingElement() {
        var branding = state.branding || {};
        var serverName = (typeof branding.serverName === 'string' && branding.serverName.length > 0) ? branding.serverName : '';
        var logoPath = (typeof branding.logo === 'string' && branding.logo.length > 0) ? branding.logo : '';

        var wrap = mk('div', { class: 'k9tablet-branding' });
        if (serverName.length === 0 && logoPath.length === 0) return wrap;

        var fallbackText = mk('span', { class: 'k9tablet-branding-name', text: serverName });

        if (logoPath.length > 0) {
            var img = mk('img', { class: 'k9tablet-branding-logo', attrs: { src: logoPath, alt: serverName } });
            // Hidden unless/until the image actually fails -- showing both
            // at once would duplicate the server name for no reason in the
            // ordinary (image loads fine) case.
            fallbackText.style.display = 'none';
            img.addEventListener('error', function () {
                img.style.display = 'none';
                fallbackText.style.display = '';
            });
            wrap.appendChild(img);
        }
        wrap.appendChild(fallbackText);
        return wrap;
    }

    function buildActionNotice() {
        var notice = mk('div', { class: 'k9tablet-notice k9tablet-notice--' + (state.actionNotice.kind === 'error' ? 'error' : 'ok'), text: state.actionNotice.text });
        return notice;
    }

    function buildViewerGate() {
        var wrap = mk('div', { class: 'k9tablet-status-block' });
        if (state.myRecordLoading) {
            wrap.appendChild(mk('p', { text: S('loading') }));
        } else if (state.myRecordError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.myRecordError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadMyRecord));
        } else {
            wrap.appendChild(mk('p', { text: S('loading') }));
        }
        return wrap;
    }

    function errorText(err) {
        if (!err) return S('error_generic');
        if (typeof err.message === 'string' && err.message.length > 0) return err.message;
        switch (err.error) {
            case 'not_authorized': return S('error_not_authorized');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('error_generic');
        }
    }

    function buildTabs() {
        var tabs = mk('div', { class: 'k9tablet-tabs' });
        var myTab = mkButton(S('tab_my_record'), 'k9tablet-tab' + (state.screen === 'my_record' ? ' k9tablet-tab--active' : ''), function () {
            state.screen = 'my_record';
            render();
            loadMyRecord();
        });
        var consoleTab = mkButton(S('tab_console'), 'k9tablet-tab' + (state.screen === 'console' || state.screen === 'person' ? ' k9tablet-tab--active' : ''), function () {
            state.screen = 'console';
            render();
            loadRoster(state.rosterQuery);
        });
        tabs.appendChild(myTab);
        tabs.appendChild(consoleTab);

        // High command only, matching the SAME gate the theme editor
        // controls themselves use -- see buildThemeScreen(). GetTheme
        // itself has no such gate (applied for every viewer regardless of
        // which tab, or whether any tab, is even showing), so a non-high-
        // command viewer still sees the current theme applied; they just
        // never see a way to change it.
        if (state.viewer.isHighCommand) {
            var themeTab = mkButton(S('tab_theme'), 'k9tablet-tab' + (state.screen === 'theme' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'theme';
                render();
                loadTheme();
            });
            tabs.appendChild(themeTab);

            // Certification tier editing -- SAME high-command gate (this
            // is a UX convenience only: CanManageCertTiers is re-verified
            // server-side on every one of the four callbacks regardless of
            // whether this tab was ever shown). Fresh entry into this
            // screen clears any leftover draft/refusal/warning from a
            // previous visit, exactly like every other tab switch on this
            // page resets its own screen's transient state.
            var certTiersTab = mkButton(S('tab_cert_tiers'), 'k9tablet-tab' + (state.screen === 'cert_tiers' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'cert_tiers';
                state.certTierDraft = null;
                state.certTierFieldError = null;
                state.certTierActionError = null;
                state.certTierWarning = null;
                render();
                loadCertTiers();
            });
            tabs.appendChild(certTiersTab);
        }
        return tabs;
    }

    // ---- My Record screen ----

    function buildMyRecordScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });

        if (state.myRecordLoading && !state.myRecord) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.myRecordError && !state.myRecord) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.myRecordError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadMyRecord));
            return wrap;
        }
        if (!state.myRecord) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('my_certifications_heading') }));
        wrap.appendChild(buildCertificationList(state.myRecord.certifications, null));

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('my_xp_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-xp-line', text: xpLine(state.myRecord.xp, state.myRecord.tierLabel) }));

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('my_abilities_heading') }));
        wrap.appendChild(buildMyFeaturesList());

        return wrap;
    }

    function xpLine(xp, tierLabel) {
        if (xp === null || xp === undefined) return S('xp_tier_unknown');
        var line = String(xp);
        if (typeof tierLabel === 'string' && tierLabel.length > 0) line += ' — ' + tierLabel;
        return line;
    }

    /** Read-only certification list -- used both in My Record (no actions)
     * and, with onAction set, in the admin Person screen. */
    function buildCertificationList(list, onAction) {
        var wrap = mk('div', { class: 'k9tablet-cert-list' });
        if (!list || list.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_certifications') }));
            return wrap;
        }
        for (var i = 0; i < list.length; i++) {
            wrap.appendChild(buildCertificationRow(list[i], onAction));
        }
        return wrap;
    }

    function buildCertificationRow(entry, onAction) {
        var row = mk('div', { class: 'k9tablet-cert-row' });
        row.appendChild(mk('span', { class: 'k9tablet-cert-dept', text: entry.departmentLabel }));
        row.appendChild(mk('span', { class: 'k9tablet-cert-status k9tablet-cert-status--' + (entry.active ? 'yes' : 'no'), text: entry.active ? S('certified_yes') : S('certified_no') }));
        if (entry.active && typeof entry.grantedBy === 'string' && entry.grantedBy.length > 0) {
            row.appendChild(mk('span', { class: 'k9tablet-cert-granter', text: entry.grantedBy }));
        }
        if (onAction) {
            if (entry.active) {
                row.appendChild(mkConfirmButton(S('decertify_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                    onAction('decertify', entry.departmentKey);
                }, { disabled: state.pendingAction }));
            } else {
                row.appendChild(mkButton(S('certify_label'), 'k9tablet-btn', function () {
                    onAction('certify', entry.departmentKey);
                }, { disabled: state.pendingAction }));
            }
        }
        return row;
    }

    function buildMyFeaturesList() {
        var wrap = mk('div', { class: 'k9tablet-feature-list' });
        var features = (state.myRecord && state.myRecord.myFeatures) || [];
        if (features.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_abilities') }));
            return wrap;
        }
        for (var i = 0; i < features.length; i++) {
            wrap.appendChild(buildMyFeatureRow(features[i]));
        }
        return wrap;
    }

    function buildMyFeatureRow(feature) {
        var row = mk('div', { class: 'k9tablet-feature-row' });
        row.appendChild(mk('span', { class: 'k9tablet-feature-label', text: featureLabel(feature) }));
        row.appendChild(mk('span', { class: 'k9tablet-feature-state k9tablet-feature-state--' + feature.state, text: featureStateLabel(feature.state) }));
        if (feature.actionable && feature.state === 'available') {
            row.appendChild(mkButton(S('use_label'), 'k9tablet-btn', function () {
                triggerFeature(feature.key);
            }, { disabled: state.pendingAction }));
        }
        return row;
    }

    // ---- Console (roster) screen ----

    function buildConsoleScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });

        var toolbar = mk('div', { class: 'k9tablet-toolbar' });
        var search = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('search_placeholder') } });
        search.value = state.rosterQuery;
        search.addEventListener('input', function (e) {
            var q = e.target.value;
            state.rosterQuery = q;
            clearTimeout(searchDebounceTimer);
            searchDebounceTimer = setTimeout(function () { loadRoster(q); }, SEARCH_DEBOUNCE_MS);
        });
        toolbar.appendChild(search);
        toolbar.appendChild(mkButton(S('refresh_label'), 'k9tablet-btn', function () { loadRoster(state.rosterQuery); }));
        wrap.appendChild(toolbar);

        // "Open by exact citizen ID" -- see this file's header note on
        // tablet:revertK9Ped's own NO-UNBOUNDED-TRAP contract. The roster
        // above lists ONLY citizenids holding an ACTIVE certification
        // (server/tablet.lua's tabletRequestRoster reads `active = 1`
        // rows only), so a decertified or never-certified target can never
        // appear in a search result there -- yet exactly that target must
        // still be reachable to revert their appearance. This box calls
        // tablet:requestPersonSummary directly by citizenid, which (per
        // that callback's own contract) works for ANY citizenid regardless
        // of certification state, bypassing the roster's own filter.
        var idBar = mk('div', { class: 'k9tablet-toolbar k9tablet-id-toolbar' });
        var idInput = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('open_by_id_placeholder') } });
        idInput.value = state.openByIdValue;
        idInput.addEventListener('input', function (e) { state.openByIdValue = e.target.value; });
        idBar.appendChild(idInput);
        idBar.appendChild(mkButton(S('open_by_id_label'), 'k9tablet-btn', function () {
            var id = (idInput.value || '').trim();
            if (id.length === 0) return;
            openPerson(id, id);
        }));
        wrap.appendChild(idBar);

        if (state.rosterLoading && !state.roster) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.rosterError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.rosterError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadRoster(state.rosterQuery); }));
            return wrap;
        }
        if (!state.roster || state.roster.rows.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('empty_roster') }));
            return wrap;
        }

        if (state.roster.truncated) {
            wrap.appendChild(mk('p', { class: 'k9tablet-truncated-note', text: state.roster.truncatedMessage || S('truncated_notice') }));
        }

        wrap.appendChild(buildRosterTable(state.roster.rows));
        return wrap;
    }

    function buildRosterTable(rows) {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_name'), S('column_citizenid'), S('column_department'), S('column_certified'), S('column_xp'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < rows.length; i++) {
            tbody.appendChild(buildRosterRow(rows[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    function buildRosterRow(row) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: row.name }));
        tr.appendChild(mk('td', { text: row.citizenid }));
        tr.appendChild(mk('td', { text: row.departmentLabel }));
        tr.appendChild(mk('td', { class: row.certified ? 'k9tablet-cert-status--yes' : 'k9tablet-cert-status--no', text: row.certified ? S('certified_yes') : S('certified_no') }));
        tr.appendChild(mk('td', { text: xpLine(row.xp, row.tierLabel) }));

        var actionsTd = mk('td');
        actionsTd.appendChild(mkButton(S('manage_label'), 'k9tablet-btn', function () {
            openPerson(row.citizenid, row.name);
        }));
        tr.appendChild(actionsTd);
        return tr;
    }

    // ---- Person detail screen ----

    function buildPersonScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mkButton(S('back_label'), 'k9tablet-link-btn', function () {
            state.screen = 'console';
            render();
        }));

        if (!state.person) {
            wrap.appendChild(mk('p', { text: S('opening_person') }));
            return wrap;
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-person-name', text: state.person.name }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: state.person.citizenid }));

        if (state.personSummaryLoading && !state.personSummary) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.personSummaryError && !state.personSummary) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.personSummaryError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadPersonSummary(state.person.citizenid); }));
            return wrap;
        }

        if (state.personSummary) {
            var canCertify = state.viewer.effectivePermissions.indexOf('k9.certify') !== -1;
            var canGiveXp = state.viewer.effectivePermissions.indexOf('k9.givexp') !== -1;

            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_certifications_heading') }));
            wrap.appendChild(buildCertificationList(state.personSummary.certifications, canCertify ? handlePersonCertAction : null));

            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_xp_heading') }));
            wrap.appendChild(mk('p', { class: 'k9tablet-xp-line', text: xpLine(state.personSummary.xp, state.personSummary.tierLabel) }));
            if (canGiveXp) {
                wrap.appendChild(buildGiveXpControl());
            }

            if (state.viewer.isHighCommand) {
                wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_capabilities_heading') }));
                wrap.appendChild(buildCapabilityList(state.personSummary.permissions));

                wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_features_heading') }));
                wrap.appendChild(buildPersonFeaturesSection());

                wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('role_heading') }));
                wrap.appendChild(buildRoleControl());
            }
        }

        return wrap;
    }

    /**
     * K9 role assign / revert-to-human -- owner's own words: "assign de
     * assign give certs remove certs remove k9 ped and reverts them to a
     * human". Reachable for ANY citizenid this screen is currently showing,
     * including one reached via the console's "open by exact citizen ID"
     * box specifically BECAUSE they hold no active certification at all --
     * see this file's THE SECURITY RULE header and tablet:revertK9Ped's own
     * NO-UNBOUNDED-TRAP contract: this button is never disabled or hidden
     * based on anything about the TARGET's own certification/access state,
     * only on state.pendingAction (an unrelated mutation already in
     * flight), exactly like every other action button on this page.
     */
    function buildRoleControl() {
        var wrap = mk('div', { class: 'k9tablet-role-control' });
        var citizenid = state.person.citizenid;

        if (!state.peds || state.peds.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('role_no_peds_configured') }));
        } else {
            var row = mk('div', { class: 'k9tablet-role-row' });
            var select = mk('select', { class: 'k9tablet-role-select' });
            var firstModel = null;
            for (var i = 0; i < state.peds.length; i++) {
                var ped = state.peds[i];
                if (!ped || typeof ped.model !== 'string' || ped.model.length === 0) continue;
                if (firstModel === null) firstModel = ped.model;
                var option = mk('option', { text: (typeof ped.label === 'string' && ped.label.length > 0) ? ped.label : ped.model });
                option.setAttribute('value', ped.model);
                select.appendChild(option);
            }
            if (firstModel !== null) select.value = firstModel;
            row.appendChild(select);
            row.appendChild(mkButton(S('role_assign_label'), 'k9tablet-btn', function () {
                var modelName = select.value;
                if (!modelName) return;
                runMutation('tablet:assignK9Role', { targetCitizenId: citizenid, modelName: modelName }, function () {
                    loadPersonSummary(citizenid);
                });
            }, { disabled: state.pendingAction }));
            wrap.appendChild(row);
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('role_assign_hint') }));
        }

        wrap.appendChild(mkConfirmButton(S('role_revert_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            runMutation('tablet:revertK9Ped', { targetCitizenId: citizenid }, function () {
                loadPersonSummary(citizenid);
            });
        }, { disabled: state.pendingAction }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('role_revert_hint') }));

        return wrap;
    }

    function handlePersonCertAction(kind, departmentKey) {
        var citizenid = state.person.citizenid;
        if (kind === 'certify') {
            runMutation('tablet:certify', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                loadPersonSummary(citizenid);
            });
        } else {
            runMutation('tablet:decertify', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                loadPersonSummary(citizenid);
            });
        }
    }

    function buildGiveXpControl() {
        var wrap = mk('div', { class: 'k9tablet-givexp' });
        var selfTarget = state.person.citizenid === state.viewer.citizenid;
        var disallowSelf = selfTarget && !state.viewer.allowSelfGrant;

        var input = mk('input', { class: 'k9tablet-givexp-input', attrs: { type: 'number', min: '1', placeholder: S('givexp_placeholder') } });
        if (typeof state.maxXpPerGrant === 'number' && state.maxXpPerGrant > 0) {
            input.setAttribute('max', String(state.maxXpPerGrant));
        }
        if (disallowSelf) {
            input.setAttribute('disabled', 'disabled');
            input.setAttribute('title', S('self_grant_disabled_title'));
        }
        wrap.appendChild(input);

        wrap.appendChild(mkButton(S('givexp_label'), 'k9tablet-btn', function () {
            var amount = Number(input.value);
            if (!isFinite(amount) || amount <= 0) return;
            runMutation('tablet:givexp', { targetCitizenId: state.person.citizenid, amount: amount }, function () {
                loadPersonSummary(state.person.citizenid);
            });
        }, { disabled: state.pendingAction || disallowSelf, title: disallowSelf ? S('self_grant_disabled_title') : undefined }));

        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('givexp_max_hint') }));
        return wrap;
    }

    function buildCapabilityList(heldKeys) {
        heldKeys = heldKeys || [];
        var wrap = mk('div', { class: 'k9tablet-capability-list' });
        for (var i = 0; i < CAPABILITY_ORDER.length; i++) {
            var key = CAPABILITY_ORDER[i];
            var held = heldKeys.indexOf(key) !== -1;
            var info = capabilityInfo(key);

            var row = mk('div', { class: 'k9tablet-capability-row' });
            var labelWrap = mk('span', { class: 'k9tablet-capability-label', text: info.label, title: info.description });
            row.appendChild(labelWrap);
            row.appendChild(mk('span', { class: 'k9tablet-capability-state', text: held ? S('certified_yes') : S('certified_no') }));

            var citizenid = state.person.citizenid;
            if (held) {
                row.appendChild(mkConfirmButton(S('revoke_label'), 'k9tablet-btn k9tablet-btn--danger', function (k) {
                    return function () {
                        runMutation('tablet:revokePermission', { targetCitizenId: citizenid, permission: k }, function () {
                            loadPersonSummary(citizenid);
                        });
                    };
                }(key), { disabled: state.pendingAction }));
            } else {
                row.appendChild(mkButton(S('grant_label'), 'k9tablet-btn', function (k) {
                    return function () {
                        runMutation('tablet:grantPermission', { targetCitizenId: citizenid, permission: k }, function () {
                            loadPersonSummary(citizenid);
                        });
                    };
                }(key), { disabled: state.pendingAction }));
            }
            wrap.appendChild(row);
        }
        return wrap;
    }

    function buildPersonFeaturesSection() {
        var wrap = mk('div', { class: 'k9tablet-feature-section' });

        var search = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('search_features_placeholder') } });
        search.value = state.personFeatureQuery;
        search.addEventListener('input', function (e) {
            state.personFeatureQuery = e.target.value;
            render();
        });
        wrap.appendChild(search);

        if (state.personFeaturesLoading && !state.personFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.personFeaturesError && !state.personFeatures) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.personFeaturesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadPersonFeatures(state.person.citizenid); }));
            return wrap;
        }
        if (!state.personFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        var all = state.personFeatures.features || [];
        var q = (state.personFeatureQuery || '').toLowerCase();
        var filtered = q.length === 0 ? all : all.filter(function (f) {
            var haystack = (featureLabel(f) + ' ' + (f.key || '') + ' ' + (f.category || '')).toLowerCase();
            return haystack.indexOf(q) !== -1;
        });

        if (filtered.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_abilities') }));
            return wrap;
        }

        var table = mk('table', { class: 'k9tablet-table k9tablet-feature-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('feature_column'), S('status_column'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < filtered.length; i++) {
            tbody.appendChild(buildPersonFeatureRow(filtered[i]));
        }
        table.appendChild(tbody);
        wrap.appendChild(table);
        return wrap;
    }

    function buildPersonFeatureRow(feature) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: featureLabel(feature) }));
        tr.appendChild(mk('td', { class: 'k9tablet-feature-state--' + feature.state, text: featureStateLabel(feature.state) }));

        var actionsTd = mk('td', { class: 'k9tablet-feature-actions' });
        var citizenid = state.person.citizenid;
        var key = feature.key;

        if (!feature.globallyEnabled) {
            // Step 1 is absolute -- see this file's header. NO controls
            // rendered at all for a globally-disabled feature: a grant here
            // would produce a button that silently does nothing, and this
            // page must not offer that.
            actionsTd.appendChild(mk('span', { class: 'k9tablet-muted', text: S('state_global_off') }));
            tr.appendChild(actionsTd);
            return tr;
        }

        // Block/Unblock -- ALWAYS offered (independent of requiresGrant),
        // per config.lua's own "steps 2 and 3 are different things" note.
        if (feature.blocked) {
            actionsTd.appendChild(mkButton(S('unblock_label'), 'k9tablet-btn', function () {
                runMutation('tablet:unblockFeature', { targetCitizenId: citizenid, feature: key }, function () {
                    loadPersonFeatures(citizenid);
                });
            }, { disabled: state.pendingAction }));
        } else {
            actionsTd.appendChild(mkConfirmButton(S('block_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                runMutation('tablet:blockFeature', { targetCitizenId: citizenid, feature: key }, function () {
                    loadPersonFeatures(citizenid);
                });
            }, { disabled: state.pendingAction }));
        }

        // Grant/Revoke -- ONLY when this feature is actually grant-gated.
        if (feature.requiresGrant) {
            if (feature.granted) {
                actionsTd.appendChild(mkConfirmButton(S('revoke_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                    runMutation('tablet:revokeFeature', { targetCitizenId: citizenid, feature: key }, function () {
                        loadPersonFeatures(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            } else {
                actionsTd.appendChild(mkButton(S('grant_label'), 'k9tablet-btn', function () {
                    runMutation('tablet:grantFeature', { targetCitizenId: citizenid, feature: key }, function () {
                        loadPersonFeatures(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            }
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    // ---- Tablet theme screen (high command only) ----

    /**
     * Six inputs, one per field server/runtimecontrol.lua's own
     * ValidateFullTheme accepts -- see this file's header THE SECURITY RULE:
     * every constraint here (the `<input type="color">` picker's own
     * #RRGGBB-only value space, the density `<select>`'s fixed two-option
     * list, the header-title `maxlength`) is a UX convenience only. The
     * server re-validates the FULL merged theme from scratch on every
     * tabletSetTheme call regardless of what this page sends -- a modified
     * client posting an out-of-band value gets back
     * {ok:false, error:'invalid_field', field:...} same as a legitimate
     * request that somehow raced a stricter config change.
     */
    function buildThemeScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('theme_heading') }));

        if (state.themeLoading && !state.themeDraft) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.themeError && !state.themeDraft) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.themeError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadTheme));
            return wrap;
        }
        if (!state.themeDraft) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        if (!state.themingEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('theme_disabled_note') }));
        }

        var draft = state.themeDraft;
        var form = mk('div', { class: 'k9tablet-theme-form' });

        form.appendChild(buildThemeColorField('primaryColor', S('theme_primary_label'), draft));
        form.appendChild(buildThemeColorField('accentColor', S('theme_accent_label'), draft));
        form.appendChild(buildThemeColorField('backgroundColor', S('theme_background_label'), draft));
        form.appendChild(buildThemeColorField('textColor', S('theme_text_label'), draft));

        var densityRow = mk('div', { class: 'k9tablet-theme-field' + (state.themeFieldError === 'density' ? ' k9tablet-theme-field--invalid' : '') });
        densityRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('theme_density_label') }));
        var densitySelect = mk('select', { class: 'k9tablet-theme-density-select' });
        for (var i = 0; i < THEME_DENSITY_OPTIONS.length; i++) {
            var value = THEME_DENSITY_OPTIONS[i];
            var opt = mk('option', { text: value === 'compact' ? S('theme_density_compact') : S('theme_density_comfortable') });
            opt.setAttribute('value', value);
            densitySelect.appendChild(opt);
        }
        densitySelect.value = draft.density || DEFAULT_THEME.density;
        densitySelect.addEventListener('input', function (e) { draft.density = e.target.value; });
        densityRow.appendChild(densitySelect);
        form.appendChild(densityRow);

        var titleRow = mk('div', { class: 'k9tablet-theme-field' + (state.themeFieldError === 'headerTitle' ? ' k9tablet-theme-field--invalid' : '') });
        titleRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('theme_header_title_label') }));
        var titleInput = mk('input', { class: 'k9tablet-theme-title-input', attrs: { type: 'text', maxlength: '40' } });
        titleInput.value = draft.headerTitle || '';
        titleInput.addEventListener('input', function (e) { draft.headerTitle = e.target.value; });
        titleRow.appendChild(titleInput);
        form.appendChild(titleRow);

        wrap.appendChild(form);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('theme_save_label'), 'k9tablet-btn', saveTheme, { disabled: state.pendingAction || !state.themingEnabled }));
        actions.appendChild(mkConfirmButton(S('theme_reset_label'), 'k9tablet-btn k9tablet-btn--danger', resetThemeToDefault, { disabled: state.pendingAction || !state.themingEnabled }));
        wrap.appendChild(actions);

        return wrap;
    }

    /** One `<input type="color">` row bound to `draft[field]`, mutating the
     * WORKING COPY directly (never `state.theme` itself, and never sent
     * anywhere until saveTheme() below) -- see state.themeDraft's own
     * comment.
     * @param {string} field @param {string} label @param {object} draft */
    function buildThemeColorField(field, label, draft) {
        var row = mk('div', { class: 'k9tablet-theme-field' + (state.themeFieldError === field ? ' k9tablet-theme-field--invalid' : '') });
        row.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: label }));
        var input = mk('input', { class: 'k9tablet-theme-color-input', attrs: { type: 'color' } });
        input.value = draft[field] || DEFAULT_THEME[field];
        input.addEventListener('input', function (e) { draft[field] = e.target.value; });
        row.appendChild(input);
        return row;
    }

    // ---- Certification tier editing screen (high command only) ----

    /**
     * Owner's own words: "Allow high command to edit the tiers trainee
     * certified senior etc add more roles edit permissions for those roles
     * etc." Renders the LIVE catalogue from state.certTiers (populated by
     * loadCertTiers() -- see that function's own comment on why this is
     * never a hardcoded list), a per-row Edit/Move Up/Move Down/Delete set
     * of controls, and (when a draft is open) the add/edit form below the
     * table. server/certtiers.lua's own CanManageCertTiers is the real
     * authorization gate, re-checked on every one of the four callbacks
     * this screen calls -- see THE SECURITY RULE.
     */
    function buildCertTiersScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('cert_tiers_heading') }));

        // HAZARD 3, surfaced per the server side's own explicit ask: a
        // successful reorder's `warning` is non-optional and must not be
        // silently discarded -- its own prominent banner, not folded into
        // the generic (and easy-to-miss-amid-other-clicks) actionNotice.
        if (state.certTierWarning) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.certTierWarning }));
        }

        if (state.certTiersLoading && !state.certTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.certTiersError && !state.certTiers) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.certTiersError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadCertTiers));
            return wrap;
        }
        if (!state.certTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildCertTiersTable());

        if (state.certTierDraft) {
            wrap.appendChild(buildCertTierDraftForm());
        } else {
            wrap.appendChild(mkButton(S('cert_tiers_add_label'), 'k9tablet-btn', openNewCertTierDraft, { disabled: state.pendingAction }));
        }

        return wrap;
    }

    function buildCertTiersTable() {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_position'), S('column_key'), S('column_label'), S('column_capabilities'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.certTiers.length; i++) {
            tbody.appendChild(buildCertTierRow(state.certTiers[i], i));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {string} capabilityKey @returns {string} */
    function certTierCapabilityLabel(capabilityKey) {
        var def = state.certTierCapabilityCatalog[capabilityKey];
        return (def && typeof def.label === 'string' && def.label.length > 0) ? def.label : capabilityKey;
    }

    /** @param {object} capabilities @returns {string} */
    function certTierCapabilitiesSummary(capabilities) {
        if (!capabilities || typeof capabilities !== 'object') return S('cert_tier_no_capabilities');
        var labels = [];
        for (var key in capabilities) {
            if (Object.prototype.hasOwnProperty.call(capabilities, key) && capabilities[key] === true) {
                labels.push(certTierCapabilityLabel(key));
            }
        }
        if (labels.length === 0) return S('cert_tier_no_capabilities');
        return labels.join(', ');
    }

    /** @param {object} tier @param {number} index */
    function buildCertTierRow(tier, index) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(index + 1) }));
        tr.appendChild(mk('td', { text: tier.key }));
        tr.appendChild(mk('td', { text: tier.label }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: certTierCapabilitiesSummary(tier.capabilities) }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('cert_tier_move_up_label'), 'k9tablet-btn', function () {
            moveCertTier(index, -1);
        }, { disabled: state.pendingAction || index === 0, title: S('cert_tier_move_up_title') }));
        actionsTd.appendChild(mkButton(S('cert_tier_move_down_label'), 'k9tablet-btn', function () {
            moveCertTier(index, 1);
        }, { disabled: state.pendingAction || index === state.certTiers.length - 1, title: S('cert_tier_move_down_title') }));
        actionsTd.appendChild(mkButton(S('cert_tier_edit_label'), 'k9tablet-btn', function () {
            openCertTierEditDraft(tier);
        }, { disabled: state.pendingAction }));

        // UX CONVENIENCE ONLY -- see server/certtiers.lua's own
        // PROTECTED_TIER_KEYS/HAZARD 2: 'certified' is UNCONDITIONALLY
        // undeletable server-side regardless of this hint; a modified
        // client sending certTiersDelete for 'certified' anyway still gets
        // refused (reason='protected_tier') by the real gate.
        var isProtected = tier.key === 'certified';
        actionsTd.appendChild(mkConfirmButton(S('cert_tier_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            deleteCertTier(tier.key);
        }, { disabled: state.pendingAction || isProtected, title: isProtected ? S('cert_tier_error_protected_tier') : undefined }));

        // A delete REFUSAL (tier_in_use/protected_tier) renders inline on
        // THIS specific row -- "cannot, and here is why" -- not merely as
        // an easy-to-miss generic top-of-panel notice (which still also
        // shows, for anyone not looking at this exact row).
        if (state.certTierActionError && state.certTierActionError.key === tier.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.certTierActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Add/edit form -- see openNewCertTierDraft()/openCertTierEditDraft()
     * for how state.certTierDraft is populated. `key` is editable only for
     * a BRAND NEW tier: server/certtiers.lua's own certTiersUpsert treats
     * an existing key's ordinal as fixed (only ReorderTiers ever changes
     * it) and has no "rename" concept -- submitting a DIFFERENT key while
     * editing would create a second, separate tier, not rename this one,
     * so the key input is disabled once a tier already exists under it. */
    function buildCertTierDraftForm() {
        var draft = state.certTierDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var keyRow = mk('div', { class: 'k9tablet-theme-field' + (state.certTierFieldError === 'key' ? ' k9tablet-theme-field--invalid' : '') });
        keyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('cert_tier_key_label') }));
        var keyInput = mk('input', { class: 'k9tablet-cert-tier-key-input', attrs: { type: 'text', placeholder: S('cert_tier_key_placeholder'), maxlength: '20' } });
        keyInput.value = draft.key;
        if (draft.isNew) {
            keyInput.addEventListener('input', function (e) { draft.key = e.target.value; });
        } else {
            keyInput.setAttribute('disabled', 'disabled');
        }
        keyRow.appendChild(keyInput);
        wrap.appendChild(keyRow);

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.certTierFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('cert_tier_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var capsWrap = mk('div', { class: 'k9tablet-cert-tier-capabilities' + (state.certTierFieldError === 'capabilities' ? ' k9tablet-theme-field--invalid' : '') });
        capsWrap.appendChild(mk('p', { class: 'k9tablet-theme-field-label', text: S('cert_tier_capabilities_label') }));
        var anyCapability = false;
        for (var capKey in state.certTierCapabilityCatalog) {
            if (!Object.prototype.hasOwnProperty.call(state.certTierCapabilityCatalog, capKey)) continue;
            anyCapability = true;
            capsWrap.appendChild(buildCertTierCapabilityCheckbox(capKey, draft));
        }
        if (!anyCapability) {
            capsWrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('cert_tier_no_capabilities') }));
        }
        wrap.appendChild(capsWrap);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('cert_tier_save_label'), 'k9tablet-btn', saveCertTierDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('cert_tier_cancel_label'), 'k9tablet-link-btn', closeCertTierDraft));
        wrap.appendChild(actions);

        return wrap;
    }

    /** One checkbox row bound to `draft.capabilities[capabilityKey]`,
     * mutating the WORKING COPY directly (never sent anywhere until Save)
     * -- same posture as buildThemeColorField's own color inputs.
     * @param {string} capabilityKey @param {object} draft */
    function buildCertTierCapabilityCheckbox(capabilityKey, draft) {
        var row = mk('label', { class: 'k9tablet-cert-tier-capability-row' });
        var checkbox = mk('input', { attrs: { type: 'checkbox' } });
        checkbox.checked = draft.capabilities[capabilityKey] === true;
        checkbox.addEventListener('change', function (e) {
            draft.capabilities[capabilityKey] = !!(e.target && e.target.checked);
        });
        row.appendChild(checkbox);
        row.appendChild(mk('span', { text: certTierCapabilityLabel(capabilityKey) }));
        return row;
    }

    // ------------------------------------------------------------------
    // DATA LOADERS
    // ------------------------------------------------------------------

    function loadMyRecord() {
        state.myRecordLoading = true;
        state.myRecordError = null;
        render();

        fetchNui('tablet:requestMyRecord', {}).then(function (result) {
            state.myRecordLoading = false;
            if (!result || result.ok !== true) {
                state.myRecordError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.viewer = result.viewer || null;
            state.myRecord = {
                certifications: result.certifications || [],
                xp: typeof result.xp === 'number' ? result.xp : null,
                tierLabel: typeof result.tierLabel === 'string' ? result.tierLabel : null,
                myFeatures: result.myFeatures || [],
            };
            render();
        });
    }

    function loadRoster(query) {
        state.rosterLoading = true;
        state.rosterError = null;
        render();

        fetchNui('tablet:requestRoster', { query: query || '' }).then(function (result) {
            // STALE-RESPONSE GUARD: the search box's debounce only SPACES
            // requests out, it does not cancel one already sent -- a fast
            // retype (or a slow/lagged server response) can let an OLDER
            // query's fetch resolve AFTER a newer one already has, or while
            // a newer one is still in flight. Without this check, an
            // out-of-order response for a query the user has since moved on
            // from would silently overwrite the currently-displayed roster
            // with results for text no longer in the search box -- a
            // silent-failure path, not a visible error, exactly the class
            // of bug this file's own header warns loudest about. Discarding
            // here leaves whatever the CURRENT (matching) request already
            // wrote to rosterLoading/rosterError/roster untouched, which is
            // correct either way (still in flight, or already settled).
            if (query !== state.rosterQuery) return;

            state.rosterLoading = false;
            if (!result || result.ok !== true) {
                state.rosterError = result || { error: 'unknown_error' };
                state.roster = null;
                render();
                return;
            }
            state.roster = {
                rows: result.rows || [],
                truncated: result.truncated === true,
                truncatedMessage: typeof result.truncatedMessage === 'string' ? result.truncatedMessage : null,
            };
            render();
        });
    }

    function openPerson(citizenid, name) {
        state.screen = 'person';
        state.person = { citizenid: citizenid, name: name };
        state.personSummary = null;
        state.personFeatures = null;
        state.personFeatureQuery = '';
        render();
        loadPersonSummary(citizenid);
        if (state.viewer && state.viewer.isHighCommand) {
            loadPersonFeatures(citizenid);
        }
    }

    function loadPersonSummary(citizenid) {
        state.personSummaryLoading = true;
        state.personSummaryError = null;
        render();

        fetchNui('tablet:requestPersonSummary', { targetCitizenId: citizenid }).then(function (result) {
            // STALE-RESPONSE GUARD: openPerson()/the console's "open by
            // exact citizen ID" box can navigate to a DIFFERENT person (or
            // back to the console/my-record screen entirely) while this
            // request is still in flight -- nothing here cancels the
            // underlying fetch. Without this check, an out-of-order
            // response for a citizenid no longer on screen would silently
            // apply THAT person's certifications/XP/permissions under the
            // CURRENTLY-displayed person's name/header -- a wrong-data bug
            // with no visible error, not merely a stale-but-harmless retry
            // (contrast loadMyRecord/loadTheme/loadCertTiers, which have no
            // target parameter and are safe to apply regardless of arrival
            // order). Discarding here leaves whatever the CURRENT
            // navigation's own request already wrote untouched.
            if (!state.person || state.person.citizenid !== citizenid) return;

            state.personSummaryLoading = false;
            if (!result || result.ok !== true) {
                state.personSummaryError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.personSummary = {
                certifications: result.certifications || [],
                xp: typeof result.xp === 'number' ? result.xp : null,
                tierLabel: typeof result.tierLabel === 'string' ? result.tierLabel : null,
                permissions: result.permissions || [],
            };
            if (result.target && typeof result.target.name === 'string' && state.person) {
                state.person.name = result.target.name;
            }
            render();
        });
    }

    function loadPersonFeatures(citizenid) {
        state.personFeaturesLoading = true;
        state.personFeaturesError = null;
        render();

        fetchNui('tablet:requestPersonFeatures', { targetCitizenId: citizenid }).then(function (result) {
            // STALE-RESPONSE GUARD -- see loadPersonSummary()'s identical
            // comment just above; same race, same fix, applied to the
            // Abilities table instead of the certifications/XP/permissions
            // block.
            if (!state.person || state.person.citizenid !== citizenid) return;

            state.personFeaturesLoading = false;
            if (!result || result.ok !== true) {
                state.personFeaturesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.personFeatures = { features: result.features || [] };
            render();
        });
    }

    /**
     * Applies the four colour slots to CSS custom properties on
     * `document.documentElement` so tablet.css's own `var(--k9tablet-*, ...)`
     * rules pick them up immediately, independent of render()'s own
     * clear-and-rebuild cycle (this survives every subsequent render()
     * automatically via normal CSS inheritance/cascade, rather than needing
     * to be re-applied to a freshly built panel element every time -- see
     * buildBackdrop()'s own density-class handling for the ONE piece of
     * theming that DOES need to be re-applied per render, and why).
     *
     * Guarded, not assumed: `document.documentElement` does not exist in
     * this project's own test stub (html/tests/tablet-dom-stub.js builds
     * only the one static `#k9tablet-root` div tablet.html actually ships,
     * matching that file's own "everything else is built by tablet.js"
     * design) -- this silently no-ops there rather than throwing, which is
     * correct: nothing under test ever asserts on real CSS cascade, only on
     * the DOM nodes/text/classes this page itself builds.
     * @param {object} theme
     */
    function applyThemeToDocument(theme) {
        theme = theme || DEFAULT_THEME;
        var docEl = (typeof document !== 'undefined') ? document.documentElement : null;
        var styleTarget = (docEl && docEl.style && typeof docEl.style.setProperty === 'function') ? docEl.style : null;
        if (!styleTarget) return;
        styleTarget.setProperty('--k9tablet-primary', theme.primaryColor || DEFAULT_THEME.primaryColor);
        styleTarget.setProperty('--k9tablet-accent', theme.accentColor || DEFAULT_THEME.accentColor);
        styleTarget.setProperty('--k9tablet-bg', theme.backgroundColor || DEFAULT_THEME.backgroundColor);
        styleTarget.setProperty('--k9tablet-text', theme.textColor || DEFAULT_THEME.textColor);
    }

    /**
     * Seeds state.theme/applies it, from Config.CommandTablet.branding's
     * own `theme` (four colours only -- density/headerTitle are NOT part
     * of branding, see config.lua's own comment: branding.theme is only
     * "starting colours, matched to the shipped logo"). Called ONLY when
     * state.theme is still null (see handleOpen()) -- i.e. this page's
     * very first open this session, before tablet:getTheme has EVER
     * resolved even once. Purely a first-paint cosmetic improvement so
     * the tablet does not flash the generic code-level DEFAULT_THEME
     * before the real fetch lands; the real tablet:getTheme response
     * (server/runtimecontrol.lua's own CurrentTheme -- config default,
     * DB override wins, the SAME precedence this function mirrors for the
     * brief window before that fetch resolves) is what actually matters
     * and OVERWRITES this the moment it arrives, every time, unconditionally
     * -- see loadTheme() below, which never checks "do I already have a
     * seeded value" before applying its own result.
     */
    function applyBrandingSeedTheme() {
        var brandingTheme = state.branding && state.branding.theme;
        if (!brandingTheme || typeof brandingTheme !== 'object') return;
        var seeded = assignShallow({}, DEFAULT_THEME);
        // Only the four colour keys -- an unexpected extra key on
        // branding.theme (a config mistake) is silently ignored here, not
        // propagated; server/runtimecontrol.lua's own ValidateFullTheme is
        // still the only check that actually matters once the real fetch
        // lands regardless.
        if (typeof brandingTheme.primaryColor === 'string') seeded.primaryColor = brandingTheme.primaryColor;
        if (typeof brandingTheme.accentColor === 'string') seeded.accentColor = brandingTheme.accentColor;
        if (typeof brandingTheme.backgroundColor === 'string') seeded.backgroundColor = brandingTheme.backgroundColor;
        if (typeof brandingTheme.textColor === 'string') seeded.textColor = brandingTheme.textColor;
        state.theme = seeded;
        state.themeDraft = assignShallow({}, seeded);
        applyThemeToDocument(seeded);
    }

    /** Fetched once per open (see handleOpen()) and again on the theme tab
     * being opened directly (see buildTabs()) -- APPLIED FOR EVERY VIEWER
     * regardless of role (tablet:getTheme itself has no authorization gate,
     * see this file's header THE SECURITY RULE / NUI CONTRACT), even though
     * only high command ever sees buildThemeScreen()'s own edit controls. */
    function loadTheme() {
        state.themeLoading = true;
        state.themeError = null;
        render();

        fetchNui('tablet:getTheme', {}).then(function (result) {
            state.themeLoading = false;
            if (!result || result.ok !== true) {
                state.themeError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.theme = result.theme || DEFAULT_THEME;
            state.themeDraft = assignShallow({}, state.theme);
            state.themeFieldError = null;
            applyThemeToDocument(state.theme);
            render();
        });
    }

    /** IE11-free shallow-copy helper -- this file otherwise targets very
     * old-JS syntax throughout (`var`, no arrow functions, no template
     * literals -- see this page's existing style), so `Object.assign` is
     * avoided here for the same reason, not because it is unavailable in
     * CEF specifically.
     * @param {object} target @param {object} source @returns {object} */
    function assignShallow(target, source) {
        for (var k in source) {
            if (Object.prototype.hasOwnProperty.call(source, k)) target[k] = source[k];
        }
        return target;
    }

    /** Substitutes `{key}`-style tokens in `template` from `replacements`
     * -- this file's only string-formatting need (currently just
     * cert_tier_error_tier_in_use's `{count}`), so a tiny token replace is
     * used rather than pulling in a template-literal/sprintf dependency.
     * @param {string} template @param {Record<string, string|number>} replacements @returns {string} */
    function formatTemplate(template, replacements) {
        var out = template;
        for (var key in replacements) {
            if (Object.prototype.hasOwnProperty.call(replacements, key)) {
                out = out.split('{' + key + '}').join(String(replacements[key]));
            }
        }
        return out;
    }

    /** Fetched fresh every time the Cert Tiers tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list. server/certtiers.lua's own
     * header: the catalogue is Config.CertificationTiers defaults merged
     * with database overrides (database wins), and high command can add
     * tiers at runtime -- a list captured once here would already be stale
     * the moment anyone adds/renames/deletes a tier. High command only
     * (server/certtiers.lua's own CanManageCertTiers re-verifies this on
     * every one of the four callbacks regardless of whether this ever
     * loads). */
    function loadCertTiers() {
        state.certTiersLoading = true;
        state.certTiersError = null;
        render();

        fetchNui('tablet:certTiersList', {}).then(function (result) {
            state.certTiersLoading = false;
            if (!result || result.ok !== true) {
                state.certTiersError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.certTiers = Array.isArray(result.tiers) ? result.tiers : [];
            state.certTierCapabilityCatalog = (result.capabilityCatalog && typeof result.capabilityCatalog === 'object') ? result.capabilityCatalog : {};
            render();
        });
    }

    /** @param {object|undefined} result @returns {string} */
    function certTierErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('cert_tier_error_denied');
            case 'rate_limited': return S('cert_tier_error_rate_limited');
            case 'invalid_key': return S('cert_tier_error_invalid_key');
            case 'invalid_label': return S('cert_tier_error_invalid_label');
            case 'invalid_capabilities': return S('cert_tier_error_invalid_capabilities');
            case 'busy': return S('cert_tier_error_busy');
            case 'too_many_tiers': return S('cert_tier_error_too_many_tiers');
            case 'unknown_tier': return S('cert_tier_error_unknown_tier');
            // 'protected_tier'/'tier_in_use' are REFUSALS ("cannot, and
            // here is why"), not generic failures -- per this task's own
            // instruction, given their own explanatory copy rather than a
            // bare machine code or S('action_failed').
            case 'protected_tier': return S('cert_tier_error_protected_tier');
            case 'tier_in_use': return formatTemplate(S('cert_tier_error_tier_in_use'), { count: typeof result.referenceCount === 'number' ? result.referenceCount : '' });
            case 'must_include_every_tier': return S('cert_tier_error_must_include_every_tier');
            case 'invalid_key_set': return S('cert_tier_error_invalid_key_set');
            case 'invalid_payload': return S('cert_tier_error_invalid_payload');
            case 'db_error': return S('cert_tier_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function certTierFieldFromError(errorCode) {
        if (errorCode === 'invalid_key') return 'key';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_capabilities') return 'capabilities';
        return null;
    }

    /** Opens a BLANK draft for a brand-new tier. @see buildCertTierDraftForm */
    function openNewCertTierDraft() {
        state.certTierDraft = { key: '', label: '', capabilities: {}, isNew: true };
        state.certTierFieldError = null;
        render();
    }

    /** Opens a draft pre-filled from an EXISTING tier row -- a COPY of its
     * capabilities set, never the live object, so cancelling never mutates
     * state.certTiers. @param {object} tier */
    function openCertTierEditDraft(tier) {
        var capabilities = {};
        if (tier.capabilities && typeof tier.capabilities === 'object') {
            for (var k in tier.capabilities) {
                if (Object.prototype.hasOwnProperty.call(tier.capabilities, k) && tier.capabilities[k] === true) capabilities[k] = true;
            }
        }
        state.certTierDraft = { key: tier.key, label: tier.label, capabilities: capabilities, isNew: false };
        state.certTierFieldError = null;
        render();
    }

    function closeCertTierDraft() {
        state.certTierDraft = null;
        state.certTierFieldError = null;
        render();
    }

    /**
     * Generic mutation runner -- every grant/revoke/certify/decertify/
     * givexp/block/unblock action shares this shape. Disables further
     * actions while in flight (state.pendingAction), shows a transient
     * notice from the result, and always calls `onSettled` (regardless of
     * ok/fail) so callers can refresh whatever data the mutation might have
     * changed -- this page NEVER optimistically mutates its own local copy
     * of server state; every action re-pulls the authoritative version.
     * @param {string} nuiName
     * @param {object} payload
     * @param {() => void} onSettled
     */
    function runMutation(nuiName, payload, onSettled) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui(nuiName, payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.actionNotice = { kind: 'ok', text: (typeof result.message === 'string' && result.message) || S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: (result && typeof result.message === 'string' && result.message) || S('action_failed') };
            }
            onSettled();
        });
    }

    function triggerFeature(key) {
        runMutation('tablet:triggerFeature', { feature: key }, function () {
            loadMyRecord();
        });
    }

    /**
     * Saves the theme editor's current WORKING COPY (state.themeDraft) --
     * NOT the generic runMutation() helper above, because a rejected save
     * here carries a `field` (which of the six inputs failed) that
     * runMutation's own `result.message`-only handling has no slot for, and
     * because a successful save must apply the server's CANONICAL returned
     * theme immediately (applyThemeToDocument) rather than merely re-pull
     * an unrelated screen the way every other mutation's `onSettled` does.
     * Shares state.pendingAction with every other action on this page
     * regardless (same "at most one mutation in flight" invariant).
     */
    function saveTheme() {
        if (state.pendingAction || !state.themeDraft) return;
        state.pendingAction = true;
        state.themeFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:setTheme', state.themeDraft).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.theme = result.theme || state.theme;
                state.themeDraft = assignShallow({}, state.theme || DEFAULT_THEME);
                applyThemeToDocument(state.theme);
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.themeFieldError = (result && typeof result.field === 'string') ? result.field : null;
                var failText = (result && result.error === 'invalid_field') ? S('theme_field_invalid') : S('action_failed');
                state.actionNotice = { kind: 'error', text: failText };
            }
            render();
        });
    }

    /** Restores the SERVER's own built-in default (server/runtimecontrol.lua's
     * DEFAULT_THEME) -- a destructive action from an operator's point of
     * view (discards every customization), hence mkConfirmButton's two-click
     * guard at its own call site, same posture as Decertify/Revoke/Block. */
    function resetThemeToDefault() {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.themeFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:resetTheme', {}).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.theme = result.theme || DEFAULT_THEME;
                state.themeDraft = assignShallow({}, state.theme);
                applyThemeToDocument(state.theme);
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: S('action_failed') };
            }
            render();
        });
    }

    /**
     * Saves the cert-tier draft form's current working copy. Converts
     * `draft.capabilities` (a {capKey:true} SET, convenient for the
     * checkbox UI) into the ARRAY shape server/certtiers.lua's own
     * NormalizeCapabilitiesInput expects (`ipairs`-iterated) immediately
     * before sending -- the set shape never leaves this function.
     * NOT the generic runMutation() helper: a rejected save carries a
     * `field` naming which of the three inputs failed (key/label/
     * capabilities), which runMutation's own message-only handling has no
     * slot for, same reasoning as saveTheme() above.
     */
    function saveCertTierDraft() {
        if (state.pendingAction || !state.certTierDraft) return;
        var draft = state.certTierDraft;
        var capabilities = [];
        for (var capKey in draft.capabilities) {
            if (Object.prototype.hasOwnProperty.call(draft.capabilities, capKey) && draft.capabilities[capKey] === true) {
                capabilities.push(capKey);
            }
        }

        state.pendingAction = true;
        state.certTierFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:certTiersUpsert', { key: draft.key, label: draft.label, capabilities: capabilities }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.certTiers = Array.isArray(result.tiers) ? result.tiers : state.certTiers;
                if (result.capabilityCatalog && typeof result.capabilityCatalog === 'object') state.certTierCapabilityCatalog = result.capabilityCatalog;
                state.certTierDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.certTierFieldError = certTierFieldFromError(result && result.error);
                state.actionNotice = { kind: 'error', text: certTierErrorText(result) };
            }
            render();
        });
    }

    /**
     * Swaps tier `index` with its immediate neighbour (`direction` is -1
     * for up / +1 for down) and submits the FULL resulting key order --
     * server/certtiers.lua's own certTiersReorder REFUSES any partial
     * reorder (must be an exact permutation of every known tier, see its
     * own HAZARD 3), so this always sends every key, never just the two
     * that moved. A no-op past either end of the list (nothing to swap
     * with) -- also enforced by each row's own `disabled` state in
     * buildCertTierRow, this is the real, server-call-blocking guard,
     * that being a convenience only.
     * @param {number} index @param {number} direction -1 | 1
     */
    function moveCertTier(index, direction) {
        if (state.pendingAction || !state.certTiers) return;
        var targetIndex = index + direction;
        if (targetIndex < 0 || targetIndex >= state.certTiers.length) return;

        var orderedKeys = [];
        for (var i = 0; i < state.certTiers.length; i++) orderedKeys.push(state.certTiers[i].key);
        var moved = orderedKeys[index];
        orderedKeys[index] = orderedKeys[targetIndex];
        orderedKeys[targetIndex] = moved;

        state.pendingAction = true;
        state.certTierWarning = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:certTiersReorder', { orderedKeys: orderedKeys }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.certTiers = Array.isArray(result.tiers) ? result.tiers : state.certTiers;
                // Non-optional per server/certtiers.lua's own HAZARD 3 --
                // ALWAYS present on a successful reorder; forwarded as-is
                // regardless, so a future wording change needs no client
                // edit.
                state.certTierWarning = (typeof result.warning === 'string' && result.warning.length > 0) ? result.warning : null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: certTierErrorText(result) };
            }
            render();
        });
    }

    /**
     * Deletes tier `key`. A REFUSAL (tier_in_use -- still referenced by at
     * least one k9_certifications row; protected_tier -- 'certified',
     * unconditionally) is rendered INLINE on that tier's own row
     * (state.certTierActionError) as "cannot, and here is why", per this
     * task's own explicit instruction, alongside the same text in the
     * generic top-of-panel notice for visibility.
     * @param {string} key
     */
    function deleteCertTier(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.certTierActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:certTiersDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.certTiers = Array.isArray(result.tiers) ? result.tiers : state.certTiers;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = certTierErrorText(result);
                state.certTierActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    // ------------------------------------------------------------------
    // OPEN / CLOSE
    // ------------------------------------------------------------------

    function handleOpen(data) {
        data = data || {};
        state.open = true;
        state.strings = (data.strings && typeof data.strings === 'object') ? data.strings : {};
        state.capabilities = (data.capabilities && typeof data.capabilities === 'object') ? data.capabilities : {};
        state.maxXpPerGrant = typeof data.maxXpPerGrant === 'number' ? data.maxXpPerGrant : null;
        state.peds = Array.isArray(data.peds) ? data.peds : [];
        state.themingEnabled = data.themingEnabled === true;
        state.branding = (data.branding && typeof data.branding === 'object') ? data.branding : {};

        // First-open ONLY, cosmetic seeding -- see applyBrandingSeedTheme()'s
        // own comment: gives this page an immediately correct-looking
        // palette before tablet:getTheme's real, authoritative response
        // (loaded a few lines below) has had a chance to land, WITHOUT ever
        // overwriting an already-loaded/edited theme on a later re-open.
        if (!state.theme) applyBrandingSeedTheme();

        // Fresh baseline every open -- never show stale data from a
        // previous session (see this file's header contract note on
        // tablet:close resetting state; opening does the same reset, since
        // either one could be the first message this page ever sees after
        // a long idle period with a job/grant change in between).
        state.screen = 'my_record';
        state.viewer = null;
        state.myRecord = null;
        state.myRecordError = null;
        state.roster = null;
        state.rosterError = null;
        state.rosterQuery = '';
        state.openByIdValue = '';
        state.person = null;
        state.personSummary = null;
        state.personFeatures = null;
        state.actionNotice = null;

        // Theme is DELIBERATELY NOT reset to null/defaults here, unlike
        // everything above -- see loadTheme()'s own comment: it is applied
        // for every viewer independent of this player's own open/close
        // cycle (server/runtimecontrol.lua's PART 2 header: "applied for
        // everyone... an already-open tablet updates without the viewer
        // having to close and reopen it"), and the qbx_k9unit:client:themeUpdated
        // push already keeps it current while this page is open OR closed.
        // Resetting it here would only manufacture a visible flash back to
        // DEFAULT_THEME on every single open for no correctness benefit.
        render();
        loadMyRecord();
        loadTheme();
    }

    function handleClose() {
        state.open = false;
        render();
    }

    /** User-initiated close (Close button or Escape) -- see this file's
     * header: hides this page's own UI IMMEDIATELY and unconditionally,
     * never waiting on the tablet:close fetch's result, so a slow/failed
     * network round trip can never leave the player staring at a stuck-open
     * tablet. Also best-effort hides the parent wrapper directly (this
     * page's iframe design already relies on same-origin access to
     * window.parent for tablet-bridge.js's relay to exist at all, so this
     * is not a new assumption) -- belt-and-suspenders alongside Lua's own
     * tablet:close push, not a replacement for it: only Lua's
     * SetNuiFocus(false, false) actually restores game input. */
    function requestClose() {
        fireAndForget('tablet:close', {});
        handleClose();
        try {
            if (window.parent && window.parent.document) {
                var wrap = window.parent.document.getElementById('k9tablet-wrap');
                if (wrap && wrap.classList) wrap.classList.add('hidden');
            }
        } catch (err) {
            // Cross-origin or otherwise inaccessible -- Lua's own
            // tablet:close push (relayed back down) is still the
            // authoritative path; this is a same-tick UX nicety only.
        }
    }

    // ------------------------------------------------------------------
    // INIT
    // ------------------------------------------------------------------

    function attachEscapeHandling() {
        document.addEventListener('keydown', function (e) {
            if (!state.open) return;
            if (e && (e.key === 'Escape' || e.key === 'Esc' || e.keyCode === 27)) {
                requestClose();
            }
        });
    }

    function sendReadyAck() {
        fireAndForget('tablet:ready', {});
    }

    /** qbx_k9unit:client:themeUpdated relayed push -- see client/tablet.lua's
     * own NUI CONTRACT note: fires for EVERY connected client on every
     * successful tabletSetTheme/tabletResetTheme, not only the officer who
     * triggered it, and NOT gated on this page's own open/closed state on
     * either side of the bridge -- applies live immediately, and updates the
     * theme editor's own working copy so it never overwrites the fresh
     * server value with a stale local edit the NEXT time Save is pressed.
     * @param {object} theme */
    function handleThemeUpdated(theme) {
        if (!theme || typeof theme !== 'object') return;
        state.theme = theme;
        state.themeDraft = assignShallow({}, theme);
        state.themeFieldError = null;
        applyThemeToDocument(theme);
        render();
    }

    function init() {
        rootEl = document.getElementById('k9tablet-root');

        window.addEventListener('message', function (event) {
            var msg = event.data;
            if (!msg || typeof msg.action !== 'string') return;
            switch (msg.action) {
                case 'tablet:open':
                    handleOpen(msg.data);
                    break;
                case 'tablet:close':
                    handleClose();
                    break;
                case 'tablet:themeUpdated':
                    handleThemeUpdated(msg.data);
                    break;
                default:
                    break;
            }
        });

        attachEscapeHandling();
        sendReadyAck();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    // Test-only hook -- NOT used by production code anywhere in this file,
    // and never relied upon by client/tablet.lua. Exposed solely so
    // html/tests/tablet_*.js can drive internals (triggerFeature,
    // resolveResourceName's fallback chain) that have no other externally
    // observable entry point, mirroring html/tests/sandbox.js's own
    // message-driven-only posture for app.js wherever possible and falling
    // back to this only where app.js's own IIFE truly exposes nothing
    // equivalent (this page's mutation buttons are reachable via the DOM
    // the same way a real click would drive them, so this hook is kept
    // minimal on purpose).
    if (typeof window !== 'undefined') {
        window.__k9tabletTestHook = { state: state };
    }
})();
