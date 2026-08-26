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
            certifications: [ { departmentKey, departmentLabel, active, grantedBy: string|null,
              // ^ tier/expiresAtUnix/expired/specializations are only ever populated
              // for an ACTIVE row (server/tablet.lua's BuildCertificationsArray) --
              // never guess a value for a department this citizenid has never held.
              tier: string|null, expiresAtUnix: number|null, expired: boolean,
              specializations: string[] } ],
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
            certifications: [ { departmentKey, departmentLabel, active, grantedBy: string|null,
              // ^ tier/expiresAtUnix/expired/specializations are only ever populated
              // for an ACTIVE row (server/tablet.lua's BuildCertificationsArray) --
              // never guess a value for a department this citizenid has never held.
              tier: string|null, expiresAtUnix: number|null, expired: boolean,
              specializations: string[] } ],
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
                blockEnforcement?: 'enforced'|'not_yet_enforced'|'not_enforceable',
                // ^ REQUESTED FROM THE SERVER, NOT YET LANDED for every key as of
                // this pass -- see server/tablet.lua's own `blocked`/`state` fields
                // above: neither one tells the operator whether setting block.<key>
                // actually stops anything. This page cannot answer that itself
                // (Do not invent a client-side list here -- see featureBlockEnforcement()
                // below for why, and THE SECURITY RULE for why a hardcoded guess would
                // rot the moment another feature's own server file gets a real
                // `block.<key>` check wired in). Server-side, three states:
                //   'enforced'         -- some feature-owning server file confirmed,
                //                         by direct code read, to check
                //                         HasPermission(citizenid, 'block.<key>') before
                //                         permitting the actual ability -- mirrors
                //                         server/runtimecontrol.lua's own FEATURE_TIERS
                //                         discipline (a small, explicit, code-read-verified
                //                         registry, not a guess), for the identical reason:
                //                         a manually-derived claim needs a human to have
                //                         actually read the file it's claiming something about.
                //   'not_enforceable'  -- structurally cannot ever take effect: either no
                //                         server-side implementation exists for this key at
                //                         all (server/runtimecontrol.lua's own `tier ===
                //                         'clientonly'` classification -- e.g. ThermalVision/
                //                         NightVision, a client-toggled ability with nothing
                //                         server-side to check a block against, so even a
                //                         wired check could never stop a modified client),
                //                         OR the feature's own owning file documents a
                //                         DELIBERATE decision never to honour one (e.g.
                //                         server/recall.lua's block.Recall -- a termination/
                //                         escape-hatch path that must never be gated, by this
                //                         resource's own "no unbounded trap" rule).
                //   'not_yet_enforced' -- (also the FALLBACK for a missing/unrecognized
                //                         value, and for this field being entirely absent
                //                         from an older server response) -- structurally
                //                         possible, simply not read/confirmed yet. THE SAFE
                //                         DEFAULT DIRECTION: this page never renders a
                //                         feature as 'enforced' unless the server explicitly
                //                         says so.
              },
            ],
          }
        Failure: { ok: false, error, message? }

      tablet:certify { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
      tablet:decertify { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
        Requires effectivePermissions to include 'k9.certify' (which already
        covers high command and legacy-rank certifiers per config.lua's own
        resolution order) -- re-verified server-side. Both work for an
        ONLINE or OFFLINE target (server/certifications.lua's
        GrantCertificationForTablet/RevokeCertificationOffline resolve
        this themselves) -- this page never needs to know or ask which.

      tablet:setCertificationTier { targetCitizenId: string, departmentKey: string, tier: string } -> cb({ ok, error?, message? })
      tablet:renewCertification { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
      tablet:revokeSpecialization { targetCitizenId: string, departmentKey: string, specialization: string } -> cb({ ok, error?, message? })
        Same 'k9.certify' gate as certify/decertify above, same online-OR-
        offline transparency. `tier` is validated server-side against the
        LIVE tier catalog (server/certtiers.lua) -- this page's own tier
        picker (buildCertificationDetail) is populated from
        tablet:certTiersList, never a hardcoded trainee/certified/senior
        list, but a modified client sending an arbitrary string still gets
        a clean 'invalid_tier' refusal, not a crash or a silent no-op.

      tablet:grantSpecialization { targetCitizenId: string, departmentKey: string, specialization: string } -> cb({ ok, error?, message? })
        Same 'k9.certify' gate -- but, UNLIKE the four calls immediately
        above, ONLINE TARGETS ONLY (server/certifications.lua's
        GrantSpecializationForTablet own header explains why: the
        precondition this gates on -- an active, non-expired base
        certification AND a tier-capability check -- is read from
        online-only cached state that cannot be safely reconstructed for a
        disconnected citizenid without weakening the check). A disconnected
        target gets 'target_must_be_online' back, an honest, distinguishable
        refusal -- this page does not attempt to disable the Grant control
        based on the target's online status (it has no reliable way to know
        that live from a person summary that already works offline), it
        simply surfaces whatever error?/message? the server returns.

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

      tablet:equipmentShopGetLocations {} -> cb({ ok, locations?, error? })
        HIGH COMMAND ONLY screen (server/equipmentshop.lua's own
        GetLocations callback has no such gate -- open to any connected
        player -- but this page only ever shows the management screen to
        high command, per THE SECURITY RULE a convenience, not the real
        gate). `locations` is a map keyed by location key
        (`cfg:<n>` -- defined in config.lua, read-only from here -- or
        `db:<id>` -- added via this screen, editable/removable) to
        `{ x, y, z, heading, model, scenario, label }`, ALL fields already
        resolved against the shop's own defaults server-side (never nil).

      tablet:equipmentShopAddLocation { label?: string, model?: string, scenario?: string } -> cb({ ok, locationKey?, locations?, error? })
        COORDINATES ARE NEVER SENT BY THIS PAGE -- a CEF browser page has no
        native access to GetEntityCoords/GetEntityHeading at all.
        client/tablet.lua captures the OPERATOR'S OWN current position at
        the moment this fires and adds it before forwarding to the server
        -- see this task's own instruction: "Get it client-side and send
        it; do not expect the server to know where they are." A blank
        label/model/scenario field is sent as an EMPTY STRING here and
        OMITTED by client/tablet.lua before forwarding (never sent as `''`,
        which the server would reject) -- meaning "inherit the shop-wide
        default," same as a config.lua location entry with that field
        unset.

      tablet:equipmentShopMoveLocation { locationKey: string, updates?: { label?: string|false, model?: string|false, scenario?: string|false }, useCurrentPosition?: boolean } -> cb({ ok, locations?, error? })
        Serves BOTH this screen's "Edit" (metadata only: `updates` present,
        `useCurrentPosition` absent -- each of label/model/scenario is
        EITHER a non-empty string override OR `false` to reset that field
        back to the shop-wide default; ALWAYS all three, never omitted,
        since the edit form always starts pre-filled from a real,
        already-resolved value) and "Move Here" (`useCurrentPosition: true`,
        `updates` absent -- client/tablet.lua captures the SAME
        GetEntityCoords/GetEntityHeading this page cannot). Only ever valid
        for a `db:<id>` locationKey -- refused (`invalid_key`) for a
        `cfg:<n>` one, which this page never offers Edit/Move Here for.

      tablet:equipmentShopRemoveLocation { locationKey: string } -> cb({ ok, locations?, error? })
        Only ever valid for a `db:<id>` locationKey, same reasoning as Move
        above. HIGH COMMAND ONLY, re-verified server-side on every one of
        these three mutating calls regardless of what this page shows.

      tablet:runtimeListFeatures {} -> cb({ ok, features?, error? })
        HIGH COMMAND ONLY screen (server/runtimecontrol.lua's own
        runtimeListFeatures re-verifies CanManageRuntimeControl itself
        regardless of what this page shows). `features` is an ARRAY (order
        NOT guaranteed -- this page sorts it by `name` for a stable
        display), one entry per Config.Features key:
          { name, currentValue: boolean, configLuaDefault: boolean,
            tier: 'live'|'onstart'|'rawtoplevel'|'clientonly'|'protected'|'unaudited',
            note?: string, overridden: boolean, overriddenBy?: string,
            overriddenAt?: string, protected: boolean }
        `tier` is THE HONESTY REQUIREMENT this screen exists to satisfy --
        see runtimeTierLabel()/runtimeTierDescription() below, which turn
        this bare string into the plain-language explanation shown on every
        row BEFORE a toggle is ever pressed. `note`, when present, is
        server-authored SUPPLEMENTARY prose about a specific partial-
        liveness gap for that one feature (e.g. ScentTracking's drop-hook
        caveat) -- rendered as a passthrough, same posture as this page's
        own `message`-field handling elsewhere, never this row's PRIMARY
        (locale-driven) explanation.

      tablet:runtimeSetFeature { name: string, value: boolean } -> cb({ ok, appliedLive?, restartRequired?, configEditRequired?, tier?, error? })
        A `protected`/`unaudited` tier feature is REFUSED outright
        (`error='protected_feature'`/`'unaudited_feature'`) -- this page
        never even renders a toggle for either (see buildRuntimeFeatureRow()
        below), so reaching this refusal at all would mean a modified
        client bypassed this page entirely, exactly the case THE SECURITY
        RULE above already assumes. On success, the post-action notice
        reuses the SAME tier description already shown on the row before
        the click was made (never re-derived from `note`, which this file
        does not forward at all -- see runtimeFeatureListFeatures' own doc
        note above and this page's header THE SECURITY RULE).

      tablet:runtimeResetFeature { name: string } -> cb({ ok, value?, restartRequired?, error? })
        Restores `name` to its config.lua-shipped default. NOTE: this
        page does NOT trust this response's own `restartRequired` (server/
        runtimecontrol.lua's own runtimeResetFeature always reports `false`
        regardless of tier -- a known asymmetry flagged upstream, not
        relied on here); the post-reset notice instead reuses this row's
        OWN, already-known `tier` from the last successful
        tablet:runtimeListFeatures load, same as a successful Set above.

      tablet:runtimeListTunables {} -> cb({ ok, tunables?, error? })
        Same HIGH COMMAND ONLY posture as runtimeListFeatures above.
        `tunables` is an ARRAY (order not guaranteed -- sorted by `key`
        here), one entry per TUNABLE_REGISTRY key:
          { key, currentValue: number, configLuaDefault: number,
            min: number, max: number, integer: boolean, overridden: boolean,
            overriddenBy?: string, overriddenAt?: string }
        Every tunable is server-confirmed LIVE (server/runtimecontrol.lua's
        own header PART 1B, exclusion rule 3) -- there is no tier concept
        for this list.

      tablet:runtimeSetTunable { key: string, value: number } -> cb({ ok, appliedLive?, restartRequired?, value?, error?, min?, max? })
        `value` is forwarded AS-IS (only a basic "is this even a number"
        guard applies client-side) -- server/runtimecontrol.lua's own
        [min,max]/integer check is the only authoritative gate; a rejection
        (`error='out_of_range'`) carries the REAL `min`/`max` back, echoed
        verbatim by this page's own runtimeTunableErrorText(), never a
        client-guessed range.

      tablet:runtimeResetTunable { key: string } -> cb({ ok, value?, restartRequired?, error? })
        Restores `key` to its config.lua-shipped default. Unlike
        runtimeResetFeature above, `restartRequired` here is always
        correctly `false` (every tunable is live), so no special handling
        is needed on this page for it.

      tablet:auditCert { targetCitizenId: string, limit?: number } -> cb(AuditResult)
      tablet:auditPartner { targetCitizenId: string, limit?: number } -> cb(AuditResult)
      tablet:auditSearch { mode: 'officer'|'plate'|'person'|'recent', value?: string, limit?: number } -> cb(AuditResult)
      tablet:auditXp { targetCitizenId: string } -> cb(AuditResult)
      tablet:auditDept { departmentKey: string, limit?: number } -> cb(AuditResult)
        The K9 Audit Trail viewer's own tab -- server/admin.lua's five
        tabletAudit* callbacks, verified directly against that file's own
        source (not assumed): each is a thin, read-only wrapper around the
        EXACT SAME Query* function/K9Store accessor its `/k9audit*` chat
        command counterpart already calls, gated by the SAME
        IsAuthorizedAdmin(source) and the SAME shared per-source cooldown
        budget. AuditResult, success:
          { ok: true, rows: Array<object>, label: string }
        `label` is SERVER-AUTHORED, already locale()-resolved prose (this
        resource's `admin` locale group, a DIFFERENT namespace than this
        page's own `strings`/S()) -- rendered verbatim via textContent as
        a result-set caption, same "message-field passthrough" posture
        this page already applies to every other server-authored detail
        string. `rows`'s column shape is DIFFERENT PER MODE, never
        reshaped by this page -- see buildAuditResultTable() below for the
        exact column list each mode renders:
          cert:    { job, granted_by, granted_at, revoked_by, revoked_at, active }
          partner: { k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active } (also carries `id`, a sort key only -- never rendered)
          search:  { searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at } (also carries `id`, not rendered)
          xp:      { xp, updated_at } -- 0 or 1 rows, citizenid is k9_progression's own PRIMARY KEY
          dept:    { citizenid, granted_by, granted_at } -- ACTIVE roster only, never revoked history
        Failure: { ok: false, error: 'not_authorized'|'rate_limited'|'invalid_args'|'timeout'|'network_error'|'exception', message?: string }
        -- same generic failure shape/fetchNui() synthesis as every other
        callback on this page; see auditErrorText() below.
        GATING (a CONVENIENCE ONLY, per THE SECURITY RULE -- see canViewAudit()
        below): server/admin.lua's own IsAuthorizedAdmin qualifies a caller
        via job.isboss, job.grade >= Config.Departments[job.name].auditGrade,
        an explicit 'k9.audit' permission grant, OR high command -- the FIRST
        THREE of those are EXACTLY what server/tablet.lua's own
        MeetsDepartmentRank(source, 'auditGrade')/ResolveEffectivePermissions
        already resolve into viewer.effectivePermissions containing
        'k9.audit' (verified directly against that file's source, not
        assumed) -- so this page shows the Audit tab to ANY viewer whose
        effectivePermissions includes 'k9.audit', not only isHighCommand,
        unlike the Theme/Cert Tiers/Shop Locations/Runtime Control tabs
        above. The one thing this client-side signal does NOT reflect is
        server/admin.lua's own PER-PERSON FEATURE CONTROL layer
        (block.AdminAuditCommands / RequireGrant.AdminAuditCommands) --
        exactly why this is a convenience only: a viewer who qualifies by
        rank/grant but is individually blocked still sees this tab, and
        simply gets `error: 'not_authorized'` back on every query, which
        this screen renders as a normal error state, never a blank one.
        `limit`, wherever accepted, is OPTIONAL -- an absent value lets
        server/admin.lua's own ClampLimit apply its configured default;
        this page still clamps whatever it sends into
        [AUDIT_LIMIT_MIN, AUDIT_LIMIT_MAX] client-side (see those
        constants' own comment for why AUDIT_LIMIT_MAX mirrors, but cannot
        dynamically read, that file's own HARD_MAX_RESULTS=100) so a typed
        value is never silently truncated server-side with no visible
        feedback here.

    Lua -> JS (SendNUIMessage on the TOP window, relayed into this page's
    OWN window by html/tablet-bridge.js for any action matching /^tablet:/
    -- see that file's header for why a relay is needed at all):

      { action: 'tablet:open', data: {
          capabilities: { 'k9.access': {label,description}, ... },  // verbatim Config.Permissions text -- see html/tablet-bridge... no, see this file's DEFAULT_CAPABILITIES for the exact fallback copy this must match
          strings: { <key>: <resolved locale string>, ... },        // see DEFAULT_STRINGS below for the full key list this page understands
          maxXpPerGrant: number|null,                               // Config.HighCommand.maxXpPerGrant, UX hint only
          shopLocationsEnabled: boolean,                            // Config.Features.K9EquipmentShop -- UX hint only, SAME posture as themingEnabled: shows a disabled-server-wide note rather than hiding the screen; every equipmentShop* callback re-checks this live, server-side, regardless
          runtimeControlEnabled: boolean,                           // Config.Features.RuntimeFeatureControl -- UX hint only, SAME posture as themingEnabled/shopLocationsEnabled: shows a disabled-server-wide note rather than hiding the screen; runtimeListFeatures/ListTunables have no such gate at all (read-only values still load), only the four mutating runtimeSetFeature/runtimeSetTunable/runtimeResetFeature/runtimeResetTunable calls actually refuse ('feature_disabled') when this is off
        } }
        Sent once per open (every time the player runs the command/keybind
        that opens the tablet). This page reacts by becoming visible and
        immediately calling tablet:requestMyRecord.

      { action: 'tablet:close', data: {} }
        Lua-INITIATED close (player death, job change invalidating the
        session, resource stop). This page hides itself and resets ALL
        internal state back to a fresh-open baseline, so a later reopen
        never shows stale data from a previous session.

      { action: 'tablet:equipmentShopLocationsUpdated', data: { <key>: {x,y,z,heading,model,scenario,label}, ... } }
        Lua-INITIATED, NOT tied to this player's own tablet being open --
        fires for EVERY connected client on every successful Add/Move/
        RemoveLocation, so an already-open Shop Locations screen elsewhere
        updates live without a tab-switch or a tablet reopen. Applied
        unconditionally to state.shopLocations; never touches an
        in-progress add/edit draft (see handleShopLocationsUpdated()).
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

    /** [Min, max] this page enforces on every tabletAudit* `limit` input,
     * client-side, BEFORE it is ever sent -- so a typed value is never
     * silently truncated server-side with no visible feedback here (this
     * task's own "make the UI agree with what the server enforces"
     * instruction). AUDIT_LIMIT_MAX mirrors server/admin.lua's own
     * HARD_MAX_RESULTS constant, verified directly against that file's
     * source (`local HARD_MAX_RESULTS = 100`) -- but NOT fetched
     * dynamically: no tabletAudit* response carries it, so this is a
     * hardcoded, disclosed duplicate that must be updated by hand if that
     * server-side constant ever changes (flagged as a reasonable
     * follow-up: have server/admin.lua's own AuditResult carry its real
     * max back, the same way runtimeSetTunable's own `min`/`max` already
     * do, rather than this page guessing). This is a UX convenience only,
     * same as every other client-side clamp on this page -- ClampLimit
     * server-side is the only real bound regardless of what this page
     * ever sends. */
    var AUDIT_LIMIT_MIN = 1;
    var AUDIT_LIMIT_MAX = 100;

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
        column_block_effect: 'Block Effect',
        block_enforced_badge: 'Enforced',
        block_not_yet_enforced_badge: 'Not enforced yet',
        block_not_yet_enforced_hint: 'Blocking this here will not currently stop the feature in-game -- the server does not enforce this block yet.',
        block_not_enforceable_note: 'Cannot be blocked per-person -- there is no server-side enforcement point for this feature.',
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

        // ---- K9 Supply Shop location management (its own tab, high
        // command only). Owner's own words: "make the shop a dog ped and i
        // can change the locations in the config or add more locations
        // remove locations etc along with in the high command tablet."
        // config.lua's own locations stay editable only by hand (shown
        // here read-only, source_config); this tab manages the runtime,
        // database-backed pool ONLY (source_runtime) -- see
        // server/equipmentshop.lua's own SCOPE note.
        tab_shop_locations: 'Shop Locations',
        shop_locations_heading: 'K9 Supply Shop Locations',
        shop_locations_disabled_note: 'The K9 Supply Shop is disabled server-wide. Existing locations are shown for reference only.',
        shop_locations_empty: 'No shop locations configured yet.',
        column_coordinates: 'Coordinates',
        column_model: 'Ped Model',
        column_source: 'Source',
        source_config: 'Config',
        source_runtime: 'Runtime',
        shop_location_add_here_label: 'Add Location Here',
        shop_location_add_hint: 'Adds a new shop location at your CURRENT in-game position. Walk to the spot first, then press this button.',
        shop_location_label_label: 'Label',
        shop_location_label_placeholder: 'e.g. Downtown K9 Supply',
        shop_location_model_label: 'Ped model',
        shop_location_model_placeholder: 'Leave blank to use the shop default',
        shop_location_scenario_label: 'Idle scenario',
        shop_location_scenario_placeholder: 'Leave blank to use the shop default',
        shop_location_save_label: 'Save Location',
        shop_location_cancel_label: 'Cancel',
        shop_location_edit_label: 'Edit',
        shop_location_move_here_label: 'Move Here',
        shop_location_move_here_hint: 'Moves this location to your CURRENT in-game position.',
        shop_location_remove_label: 'Remove',
        shop_location_config_note: 'Defined in config.lua -- edit that file and restart the resource to change or remove this one.',
        shop_location_error_denied: 'You are not authorized to manage shop locations.',
        shop_location_error_rate_limited: 'Please wait a moment before trying again.',
        shop_location_error_invalid_coords: 'Your current position could not be used. Try again.',
        shop_location_error_invalid_heading: 'That heading was rejected by the server.',
        shop_location_error_invalid_model: 'That ped model is invalid. Use a plain model name with no special characters.',
        shop_location_error_invalid_scenario: 'That scenario name is invalid. Use a plain name with no special characters.',
        shop_location_error_invalid_label: 'That label is invalid or too long.',
        shop_location_error_invalid_key: 'That location no longer exists, or cannot be edited from here.',
        shop_location_error_invalid_payload: 'That request was malformed. Try again.',
        shop_location_error_db_error: 'A database error occurred. Try again.',
        shop_location_error_feature_disabled: 'The K9 Supply Shop is disabled server-wide.',

        // ---- Runtime feature control + tuning (its own tab, high command
        // only) -- server/runtimecontrol.lua PART 1/1B. Owner's own words:
        // "Lets high command switch features on and off SERVER-WIDE from
        // the tablet, and tune numbers live." THE HONESTY REQUIREMENT: the
        // six `runtime_tier_*`/`runtime_tier_*_desc` pairs below are this
        // page's OWN plain-language rendering of server/runtimecontrol.lua's
        // `tier` field (see runtimeTierLabel()/runtimeTierDescription()) --
        // that file's raw English `note` prose is NEVER rendered verbatim,
        // per its own header ("LOCALE KEYS THIS FILE NEEDS: none... never
        // player-facing prose").
        tab_runtime_control: 'Runtime Control',
        runtime_control_heading: 'Runtime Feature Control',
        runtime_control_intro: 'These settings apply server-wide, for every player. Check the Effect column before changing anything — not every switch takes effect immediately.',
        runtime_control_disabled_note: 'Runtime feature control is disabled server-wide. Current values are shown for reference only; changes will not save until it is re-enabled.',
        runtime_features_heading: 'Features',
        runtime_features_empty: 'No features to show.',
        runtime_tunables_heading: 'Tunables',
        runtime_tunables_empty: 'No tunables to show.',
        column_tier: 'Effect',
        column_current_value: 'Current Value',
        column_range: 'Range',
        column_type: 'Type',
        runtime_tier_live: 'Live',
        runtime_tier_live_desc: 'Takes effect immediately for every player, and can be switched back at any time.',
        runtime_tier_onstart: 'Restart Required',
        runtime_tier_onstart_desc: 'Saved now, but only takes effect after this resource is restarted. Nothing changes for players in this session.',
        runtime_tier_rawtoplevel: 'Config Edit + Restart Required',
        runtime_tier_rawtoplevel_desc: 'Saved, but a restart of this resource alone is NOT enough -- config.lua itself must also be edited to match, and the server restarted, for this to actually take effect.',
        runtime_tier_clientonly: 'Client-Side Only',
        runtime_tier_clientonly_desc: 'This feature has no confirmed server-side effect. Saving this value cannot be confirmed to change anything for a connected player.',
        runtime_tier_protected: 'Protected',
        runtime_tier_protected_desc: 'This feature protects the authorization system this panel itself depends on, and can never be toggled from here. Change it in config.lua and restart if you are certain.',
        runtime_tier_unaudited: 'Not Yet Classified',
        runtime_tier_unaudited_desc: 'This feature has not yet been classified for runtime control, and is refused for safety. Ask a developer to audit it before it can be toggled here.',
        runtime_value_on: 'On',
        runtime_value_off: 'Off',
        runtime_overridden_by_at: 'Overridden by {who} at {when}',
        runtime_feature_toggle_on_label: 'Enable',
        runtime_feature_toggle_off_label: 'Disable',
        runtime_feature_reset_label: 'Reset to config.lua default',
        runtime_error_denied: 'You are not authorized to manage runtime feature control.',
        runtime_error_rate_limited: 'Please wait a moment before trying again.',
        runtime_error_db_error: 'A database error occurred. Try again.',
        runtime_feature_error_invalid_feature: 'That feature no longer exists.',
        runtime_feature_error_invalid_value: 'That value was rejected by the server.',
        runtime_tunable_edit_label: 'Edit',
        runtime_tunable_save_label: 'Save Value',
        runtime_tunable_cancel_label: 'Cancel',
        runtime_tunable_reset_label: 'Reset to config.lua default',
        runtime_tunable_type_integer: 'Whole number',
        runtime_tunable_type_decimal: 'Decimal',
        runtime_tunable_error_invalid_key: 'That tunable no longer exists.',
        runtime_tunable_error_out_of_range: 'That value must be between {min} and {max}.',
        runtime_tunable_error_not_integer: 'This value must be a whole number.',
        runtime_tunable_error_not_a_number: 'Enter a valid number.',

        // ---- K9 Audit Trail viewer (its own tab) -- server/admin.lua's
        // five tabletAudit* callbacks. Shown to any viewer whose
        // effectivePermissions includes 'k9.audit' (isHighCommand also
        // qualifies), NOT high-command-only like the four tabs above --
        // see canViewAudit()/buildTabs()'s own comment for why.
        tab_audit: 'Audit Trail',
        audit_heading: 'K9 Audit Trail',
        audit_intro: 'Read-only history from this resource\'s own certification, partnership, search, XP and department records. Every query here is rate-limited and logged, the same as running the equivalent chat command.',
        audit_disabled_note: 'The audit command surface is disabled server-wide. Queries cannot be run until it is re-enabled.',
        audit_mode_cert: 'Certifications',
        audit_mode_partner: 'Partnerships',
        audit_mode_search: 'Search Log',
        audit_mode_xp: 'XP Snapshot',
        audit_mode_dept: 'Department Roster',
        audit_citizenid_label: 'Citizen ID',
        audit_citizenid_placeholder: 'e.g. ABC12345',
        audit_department_label: 'Department',
        audit_department_placeholder: 'e.g. police',
        audit_department_hint: 'Must match a configured department key -- pick one of your own certified departments below, or type another.',
        audit_search_mode_label: 'Search by',
        audit_search_mode_officer: 'Officer (searches performed by)',
        audit_search_mode_plate: 'Vehicle plate',
        audit_search_mode_person: 'Person (searches of)',
        audit_search_mode_recent: 'Most recent (any)',
        audit_value_label: 'Value',
        audit_value_placeholder_citizenid: 'e.g. ABC12345',
        audit_value_placeholder_plate: 'e.g. ABC123',
        audit_limit_label: 'Max results',
        audit_run_label: 'Run Query',
        audit_result_empty: 'No matching records found.',
        audit_result_prompt: 'Fill in the fields above and press "Run Query".',
        audit_error_not_authorized: 'You are not authorized to view the audit trail.',
        audit_error_rate_limited: 'Please wait a moment before running another audit query.',
        audit_error_invalid_args: 'That query is invalid -- check the required field and try again.',
        audit_boolean_yes: 'Yes',
        audit_boolean_no: 'No',
        audit_na: 'N/A',
        // column_department (roster's own, above) is reused verbatim for
        // the audit dept-roster table -- same word, same meaning, no
        // separate key needed. column_xp (also above, 'XP / Tier') is
        // NOT reused here -- the audit XP snapshot shows a raw, undecorated
        // total (server/admin.lua's own "COMPUTES NOTHING NEW" rule; no
        // derived tier), so it gets its own distinct column_audit_xp key
        // instead of silently redefining column_xp's text out from under
        // the roster table that key already serves.
        column_active: 'Active',
        column_granted_by: 'Granted By',
        column_granted_at: 'Granted At',
        column_revoked_by: 'Revoked By',
        column_revoked_at: 'Revoked At',
        column_k9: 'K9',
        column_handler: 'Handler',
        column_established_by: 'Established By',
        column_established_at: 'Established At',
        column_ended_by: 'Ended By',
        column_ended_at: 'Ended At',
        column_searched_at: 'Searched At',
        column_searcher: 'Searcher',
        column_searcher_job: 'Searcher Job',
        column_target_type: 'Target Type',
        column_target: 'Target',
        column_result: 'Result',
        column_weight: 'Weight',
        column_alert_tier: 'Alert Tier',
        column_audit_xp: 'XP',
        column_updated_at: 'Updated At',
        // CERTIFICATION TIER / RENEWAL / SPECIALIZATION (this pass) -- see
        // client/tablet.lua's own TABLET_STRING_KEYS comment on this exact
        // 7-key set for the "not yet in locales/en.json" disclosure.
        tier_label: 'Tier',
        tier_set_label: 'Set Tier',
        renew_label: 'Renew',
        specializations_heading: 'Specializations',
        no_specializations: 'No specializations held.',
        expires_label: 'Expires',
        expired_badge: 'Expired',
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
        screen: 'my_record', // 'my_record' | 'console' | 'person' | 'theme' | 'cert_tiers' | 'shop_locations' | 'runtime_control'
        strings: {},
        capabilities: {},
        maxXpPerGrant: null,
        peds: [], // Config.Peds, verbatim -- see tablet:assignK9Role's own NUI contract note; display list only, server re-validates the chosen model regardless
        specializations: {}, // Config.K9Specializations, verbatim -- display list only for the person screen's specialization grant picker; server/certifications.lua's GrantSpecialization re-checks this SAME table server-side
        themingEnabled: false, // Config.Features.TabletTheming -- UX hint only, see client/tablet.lua's own NUI CONTRACT note
        shopLocationsEnabled: false, // Config.Features.K9EquipmentShop -- UX hint only, SAME posture as themingEnabled
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

        // K9 Supply Shop location management -- server/equipmentshop.lua.
        // Owner's own words: "make the shop a dog ped and i can change the
        // locations in the config or add more locations remove locations
        // etc along with in the high command tablet." `shopLocations` is
        // null until the first successful tablet:equipmentShopGetLocations,
        // same "never hardcoded, never preloaded" posture as certTiers.
        shopLocations: null, // { [locationKey]: {x,y,z,heading,model,scenario,label} } -- raw map from the server, keyed 'cfg:<n>' (config.lua, read-only here) or 'db:<id>' (runtime, editable)
        shopLocationsLoading: false,
        shopLocationsError: null,
        // STALE-RESPONSE GUARD counter -- see loadShopLocations()'s own
        // comment. This list has no per-viewer "identity" to compare
        // against arrival order the way loadPersonSummary() compares
        // targetCitizenId, so a monotonically increasing request id is
        // used instead: a response is only applied if it is still the
        // MOST RECENT request issued, discarding an older one that
        // resolves late (tab re-visited, or Refresh pressed twice).
        shopLocationsRequestId: 0,
        shopLocationDraft: null, // { key: string|null, label, model, scenario } -- key===null means "new location"; null = form closed
        shopLocationActionError: null, // { key, text } -- a Move/Remove refusal rendered inline on that specific row, same shape as certTierActionError

        // Runtime feature control + tuning -- server/runtimecontrol.lua
        // PART 1/1B. `runtimeFeatures`/`runtimeTunables` are null until the
        // first successful load, same "never hardcoded, never preloaded"
        // posture as certTiers/shopLocations above -- the registry lives
        // entirely server-side (FEATURE_TIERS/TUNABLE_REGISTRY), never
        // duplicated here.
        runtimeControlEnabled: false, // Config.Features.RuntimeFeatureControl -- UX hint only, see client/tablet.lua's own NUI CONTRACT note
        runtimeFeatures: null, // [{ name, currentValue, configLuaDefault, tier, note, overridden, overriddenBy, overriddenAt, protected }, ...]
        runtimeFeaturesLoading: false,
        runtimeFeaturesError: null,
        runtimeFeaturesRequestId: 0, // STALE-RESPONSE GUARD -- same request-id shape as shopLocationsRequestId above (this list has no per-request identity to compare against arrival order)
        runtimeFeatureActionError: null, // { key: featureName, text } -- a Set/Reset refusal rendered inline on that specific row, same convention as certTierActionError/shopLocationActionError
        runtimeTunables: null, // [{ key, currentValue, configLuaDefault, min, max, integer, overridden, overriddenBy, overriddenAt }, ...]
        runtimeTunablesLoading: false,
        runtimeTunablesError: null,
        runtimeTunablesRequestId: 0, // STALE-RESPONSE GUARD, same shape as runtimeFeaturesRequestId
        runtimeTunableDraft: null, // { key, value: string } -- the inline number-editor's own working copy for ONE tunable at a time; null = no editor open
        runtimeTunableFieldError: null, // { key, text } -- a Set refusal (out_of_range/not_integer/etc.) rendered inline on that specific row

        // K9 Audit Trail viewer -- server/admin.lua's five tabletAudit*
        // callbacks (this file's own NUI CONTRACT note on
        // tablet:auditCert/Partner/Search/Xp/Dept has the full contract).
        // Gated on canViewAudit() (see buildTabs()), NOT isHighCommand
        // alone, unlike runtimeControlEnabled/shopLocationsEnabled/
        // themingEnabled above -- see that function's own comment.
        auditEnabled: false, // Config.Features.AdminAuditCommands -- UX hint only, but see this file's own NUI CONTRACT note on why this one specifically disables the query controls rather than just showing a note
        auditMode: 'cert', // 'cert' | 'partner' | 'search' | 'xp' | 'dept' -- which of the five tabletAudit* callbacks the query form below currently targets
        auditCitizenId: '', // shared free-text input for the cert/partner/xp modes
        auditDepartment: '', // tabletAuditDept's own `departmentKey` input -- free text, but pre-offered as a <select> from state.myRecord.certifications' own real departmentKey list (never a hardcoded department list -- see buildAuditDeptFields())
        auditSearchMode: 'officer', // 'officer' | 'plate' | 'person' | 'recent' -- tabletAuditSearch's own `mode`
        auditSearchValue: '', // citizenid (officer/person) or plate (plate); unused for 'recent'
        auditLimit: 20, // shared numeric input for every mode except 'xp' (which takes none) -- clamped into [AUDIT_LIMIT_MIN, AUDIT_LIMIT_MAX] before ever being sent, see runAuditQuery()
        auditLoading: false,
        auditError: null, // { error, message } -- the LAST failed tabletAudit* response, cleared on the next successful query or mode switch
        auditResult: null, // { rows, label } -- the LAST successful response; NOT reset on tab re-entry (same posture as roster/theme -- switching away and back keeps showing the last result), only on mode switch or tablet:open
        auditRequestId: 0, // STALE-RESPONSE GUARD, same request-id shape as shopLocationsRequestId/runtimeFeaturesRequestId above -- a user can switch mode or press Run Query again while an earlier query is still in flight

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

    /**
     * Human label for a certification tier KEY -- resolved against the
     * LIVE tier catalog (state.certTiers, populated by loadCertTiers(),
     * server/certtiers.lua's own tablet:certTiersList) whenever it has
     * been loaded, falling back to the raw key otherwise -- NEVER a
     * hardcoded trainee/certified/senior map (server/certtiers.lua's own
     * header: an operator can add/rename tiers at runtime, and this page
     * must reflect that with no UI change). state.certTiers can be null
     * (never loaded, or the caller lacks the console-management access
     * tablet:certTiersList requires) -- the raw key fallback keeps this
     * always safe to call.
     * @param {any} tierKey @returns {string} */
    function tierDisplayLabel(tierKey) {
        if (typeof tierKey !== 'string' || tierKey.length === 0) return String(tierKey);
        var tiers = state.certTiers;
        if (Array.isArray(tiers)) {
            for (var i = 0; i < tiers.length; i++) {
                var tier = tiers[i];
                if (tier && tier.key === tierKey) {
                    return (typeof tier.label === 'string' && tier.label.length > 0) ? tier.label : tierKey;
                }
            }
        }
        return tierKey;
    }

    /**
     * Human label for a specialization KEY -- resolved against
     * state.specializations (Config.K9Specializations, sent verbatim in
     * tablet:open's payload -- see client/tablet.lua's own header) whenever
     * that entry carries a `.label`, falling back to the raw key
     * otherwise. NEVER a hardcoded narcotics/explosives/patrol map -- an
     * operator-added specialization key must render correctly with no UI
     * change.
     * @param {any} key @returns {string} */
    function specializationDisplayLabel(key) {
        var catalog = state.specializations;
        if (catalog && typeof catalog === 'object' && catalog[key] && typeof catalog[key].label === 'string' && catalog[key].label.length > 0) {
            return catalog[key].label;
        }
        return String(key);
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

    /**
     * Normalizes `feature.blockEnforcement` (server-reported, see this
     * file's own PersonFeaturesResult doc comment for the three real
     * values and why 'not_yet_enforced' is the safe fallback) -- NEVER
     * derived from `feature.key` here. This page has no hardcoded list of
     * which features honour a block and never will: the whole point of
     * this field is that the server is the only place that answer can
     * come from without rotting the moment another feature gets wired
     * (see server/runtimecontrol.lua's own FEATURE_TIERS for the identical
     * reasoning applied to a different question). An unrecognized or
     * absent value collapses to 'not_yet_enforced', the same direction
     * server/runtimecontrol.lua's own 'unaudited' tier fails closed in --
     * this page must never claim a block works when it does not know.
     * @param {{blockEnforcement?: string}} feature
     * @returns {'enforced'|'not_enforceable'|'not_yet_enforced'}
     */
    function featureBlockEnforcement(feature) {
        var v = feature && feature.blockEnforcement;
        if (v === 'enforced' || v === 'not_enforceable') return v;
        return 'not_yet_enforced';
    }

    /** @param {'enforced'|'not_enforceable'|'not_yet_enforced'} enforcement @returns {string} */
    function blockEnforcementBadgeLabel(enforcement) {
        if (enforcement === 'enforced') return S('block_enforced_badge');
        return S('block_not_yet_enforced_badge');
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

    /**
     * Gate for the Audit Trail tab/screen -- a CONVENIENCE ONLY, per THE
     * SECURITY RULE, same as every other `if (canX(...))` on this page.
     * Deliberately NOT `state.viewer.isHighCommand` alone, unlike the
     * Theme/Cert Tiers/Shop Locations/Runtime Control tabs: server/
     * tablet.lua's own MeetsDepartmentRank(source, 'auditGrade') /
     * ResolveEffectivePermissions already resolve 'k9.audit' into
     * viewer.effectivePermissions for EXACTLY the same job.isboss /
     * job.grade>=auditGrade / explicit-grant / high-command paths
     * server/admin.lua's own IsAuthorizedAdmin checks for its five
     * tabletAudit* callbacks (verified directly against both files'
     * source, not assumed) -- so a senior officer who qualifies by rank
     * but is NOT high command already sees this tab, the same way they
     * would see the Console tab for holding any other capability. The one
     * thing this does NOT reflect is server/admin.lua's own PER-PERSON
     * FEATURE CONTROL layer (an individual block/missing-grant on
     * 'feature.AdminAuditCommands') -- a viewer who passes this client-side
     * check but is blocked there simply gets `error: 'not_authorized'`
     * back on every query, rendered as a normal error state by this
     * screen, never a blank one.
     * @returns {boolean}
     */
    function canViewAudit() {
        return !!(state.viewer && (state.viewer.isHighCommand
            || (Array.isArray(state.viewer.effectivePermissions) && state.viewer.effectivePermissions.indexOf('k9.audit') !== -1)));
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
        } else if (state.screen === 'shop_locations' && state.viewer.isHighCommand) {
            panel.appendChild(buildShopLocationsScreen());
        } else if (state.screen === 'runtime_control' && state.viewer.isHighCommand) {
            panel.appendChild(buildRuntimeControlScreen());
        } else if (state.screen === 'audit' && canViewAudit()) {
            panel.appendChild(buildAuditScreen());
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

            // K9 Supply Shop location management -- SAME high-command gate
            // (server/equipmentshop.lua's own CanManageShopLocations is the
            // real, re-verified-per-call gate; this tab hides the screen
            // from everyone else as a convenience only). Fresh entry clears
            // any leftover draft/refusal, same reset discipline as every
            // other tab switch on this page.
            var shopLocationsTab = mkButton(S('tab_shop_locations'), 'k9tablet-tab' + (state.screen === 'shop_locations' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'shop_locations';
                state.shopLocationDraft = null;
                state.shopLocationActionError = null;
                render();
                loadShopLocations();
            });
            tabs.appendChild(shopLocationsTab);

            // Runtime feature control + tuning -- SAME high-command gate
            // (server/runtimecontrol.lua's own CanManageRuntimeControl is
            // the real, re-verified-per-call gate; this tab hides the
            // screen from everyone else as a convenience only). Fresh
            // entry clears any leftover in-progress tunable edit/refusal,
            // same reset discipline as every other tab switch on this page.
            var runtimeControlTab = mkButton(S('tab_runtime_control'), 'k9tablet-tab' + (state.screen === 'runtime_control' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'runtime_control';
                state.runtimeFeatureActionError = null;
                state.runtimeTunableDraft = null;
                state.runtimeTunableFieldError = null;
                render();
                loadRuntimeFeatures();
                loadRuntimeTunables();
            });
            tabs.appendChild(runtimeControlTab);
        }

        // K9 Audit Trail viewer -- DELIBERATELY its own gate, NOT nested in
        // the `state.viewer.isHighCommand` block above -- see canViewAudit()'s
        // own doc comment for why a rank/grant-qualifying non-high-command
        // officer must see this tab too. No reset-on-click beyond the
        // screen switch itself: unlike the three tabs above, nothing here
        // auto-fetches on entry (every mode needs at least one caller-typed
        // field), so the last query's mode/inputs/result are left exactly
        // as the viewer left them, the same way the Console tab's own
        // rosterQuery persists across a tab switch.
        if (canViewAudit()) {
            var auditTab = mkButton(S('tab_audit'), 'k9tablet-tab' + (state.screen === 'audit' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'audit';
                render();
            });
            tabs.appendChild(auditTab);
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

        // TIER / EXPIRY / SPECIALIZATIONS -- only meaningful for an ACTIVE
        // certification (an inactive/never-held row has none of these to
        // show, matching server/tablet.lua's own BuildCertificationsArray
        // contract: tier/expiresAtUnix/specializations are only populated
        // for `active == true` rows). Read-only in My Record (onAction is
        // null); with real controls on the Person screen when the viewer
        // holds k9.certify (see buildCertificationDetail's own doc comment
        // for exactly which controls need which additional preconditions).
        if (entry.active) {
            row.appendChild(buildCertificationDetail(entry, onAction));
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

    /**
     * Tier / expiry / specializations detail block for an ACTIVE
     * certification row -- see buildCertificationRow's own call site
     * comment for when this is read-only vs. controlled.
     *
     * TIER ASSIGNMENT IS ADDITIONALLY GATED ON state.certTiers BEING
     * LOADED (loadCertTiers(), called from openPerson() below) -- a real,
     * disclosed scope decision, not an oversight: server/certtiers.lua's
     * own tablet:certTiersList/CanManageCertTiers is HIGH-COMMAND ONLY
     * today (narrower than the k9.certify/IsEligibleCertifier gate that
     * actually authorizes tablet:setCertificationTier server-side -- see
     * that file's own header, "a follow-up pass can widen this... tracked
     * here, not silently done"). Rather than render a tier picker with NO
     * real choices behind it for a plain certifier-grade officer who is
     * not high command (a control that would always fail 'denied' the
     * moment loadCertTiers() itself gets refused), this falls back to
     * read-only tier text for that caller -- honest about what THIS
     * SESSION can actually do, never a button that looks live but cannot
     * work. Renew/specialization controls have no such extra gate (their
     * own server-side authorization is k9.certify, matching
     * certify/decertify already on this same row).
     * @param {object} entry
     * @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction
     */
    function buildCertificationDetail(entry, onAction) {
        var wrap = mk('div', { class: 'k9tablet-cert-detail' });

        var tierLine = mk('div', { class: 'k9tablet-cert-tier-line' });
        tierLine.appendChild(mk('span', { class: 'k9tablet-cert-tier-label', text: S('tier_label') + ': ' + tierDisplayLabel(entry.tier) }));
        if (entry.expired) {
            tierLine.appendChild(mk('span', { class: 'k9tablet-cert-expired-badge', text: S('expired_badge') }));
        } else if (typeof entry.expiresAtUnix === 'number') {
            tierLine.appendChild(mk('span', {
                class: 'k9tablet-cert-expiry',
                text: S('expires_label') + ': ' + new Date(entry.expiresAtUnix * 1000).toLocaleDateString(),
            }));
        }
        wrap.appendChild(tierLine);

        if (onAction) {
            var tiers = Array.isArray(state.certTiers) ? state.certTiers : null;
            if (tiers && tiers.length > 0) {
                var tierRow = mk('div', { class: 'k9tablet-cert-tier-controls' });
                var select = mk('select', { class: 'k9tablet-cert-tier-select k9tablet-role-select' });
                for (var i = 0; i < tiers.length; i++) {
                    var tier = tiers[i];
                    if (!tier || typeof tier.key !== 'string' || tier.key.length === 0) continue;
                    var option = mk('option', { text: (typeof tier.label === 'string' && tier.label.length > 0) ? tier.label : tier.key });
                    option.setAttribute('value', tier.key);
                    select.appendChild(option);
                }
                if (typeof entry.tier === 'string') select.value = entry.tier;
                tierRow.appendChild(select);
                tierRow.appendChild(mkButton(S('tier_set_label'), 'k9tablet-btn', function () {
                    var chosen = select.value;
                    if (!chosen || chosen === entry.tier) return;
                    onAction('setTier', entry.departmentKey, chosen);
                }, { disabled: state.pendingAction }));
                wrap.appendChild(tierRow);
            }

            wrap.appendChild(mkButton(S('renew_label'), 'k9tablet-btn', function () {
                onAction('renew', entry.departmentKey);
            }, { disabled: state.pendingAction }));
        }

        wrap.appendChild(buildSpecializationsBlock(entry, onAction));

        return wrap;
    }

    /**
     * Specializations sub-list for one active certification row -- the
     * held set (entry.specializations, a plain string[] of keys) plus, for
     * a controlled row, a picker over whatever this resource's REAL
     * specialization catalog (state.specializations ==
     * Config.K9Specializations, sent verbatim in tablet:open -- see
     * client/tablet.lua's own header) currently contains that this
     * citizenid does not already hold. Never a hardcoded
     * narcotics/explosives/patrol list.
     * @param {object} entry
     * @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction
     */
    function buildSpecializationsBlock(entry, onAction) {
        var wrap = mk('div', { class: 'k9tablet-specializations' });
        wrap.appendChild(mk('span', { class: 'k9tablet-specializations-heading', text: S('specializations_heading') }));

        var held = Array.isArray(entry.specializations) ? entry.specializations : [];
        if (held.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_specializations') }));
        } else {
            for (var i = 0; i < held.length; i++) {
                wrap.appendChild(buildSpecializationRow(held[i], entry, onAction));
            }
        }

        if (onAction) {
            var catalog = (state.specializations && typeof state.specializations === 'object') ? state.specializations : {};
            var available = [];
            for (var key in catalog) {
                if (Object.prototype.hasOwnProperty.call(catalog, key) && held.indexOf(key) === -1) {
                    available.push(key);
                }
            }
            if (available.length > 0) {
                var addRow = mk('div', { class: 'k9tablet-specialization-add' });
                var select = mk('select', { class: 'k9tablet-specialization-select k9tablet-role-select' });
                for (var j = 0; j < available.length; j++) {
                    var option = mk('option', { text: specializationDisplayLabel(available[j]) });
                    option.setAttribute('value', available[j]);
                    select.appendChild(option);
                }
                addRow.appendChild(select);
                addRow.appendChild(mkButton(S('grant_label'), 'k9tablet-btn', function () {
                    var chosen = select.value;
                    if (!chosen) return;
                    onAction('grantSpecialization', entry.departmentKey, chosen);
                }, { disabled: state.pendingAction }));
                wrap.appendChild(addRow);
            }
        }

        return wrap;
    }

    /** @param {string} key @param {object} entry @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction */
    function buildSpecializationRow(key, entry, onAction) {
        var row = mk('div', { class: 'k9tablet-specialization-row' });
        row.appendChild(mk('span', { class: 'k9tablet-specialization-label', text: specializationDisplayLabel(key) }));
        if (onAction) {
            row.appendChild(mkConfirmButton(S('revoke_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                onAction('revokeSpecialization', entry.departmentKey, key);
            }, { disabled: state.pendingAction }));
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

    /**
     * @param {string} kind -- 'certify' | 'decertify' | 'setTier' | 'renew' | 'grantSpecialization' | 'revokeSpecialization'
     * @param {string} departmentKey
     * @param {string} [extra] -- the chosen tier key (setTier) or specialization key (grant/revokeSpecialization); unused otherwise
     */
    function handlePersonCertAction(kind, departmentKey, extra) {
        var citizenid = state.person.citizenid;
        if (kind === 'certify') {
            runMutation('tablet:certify', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                loadPersonSummary(citizenid);
            });
        } else if (kind === 'decertify') {
            runMutation('tablet:decertify', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                loadPersonSummary(citizenid);
            });
        } else if (kind === 'setTier') {
            runMutation('tablet:setCertificationTier', { targetCitizenId: citizenid, departmentKey: departmentKey, tier: extra }, function () {
                loadPersonSummary(citizenid);
            });
        } else if (kind === 'renew') {
            runMutation('tablet:renewCertification', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                loadPersonSummary(citizenid);
            });
        } else if (kind === 'grantSpecialization') {
            runMutation('tablet:grantSpecialization', { targetCitizenId: citizenid, departmentKey: departmentKey, specialization: extra }, function () {
                loadPersonSummary(citizenid);
            });
        } else if (kind === 'revokeSpecialization') {
            runMutation('tablet:revokeSpecialization', { targetCitizenId: citizenid, departmentKey: departmentKey, specialization: extra }, function () {
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
        [S('feature_column'), S('status_column'), S('column_block_effect'), S('column_actions')].forEach(function (h) {
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

    /**
     * THE HONESTY REQUIREMENT this task exists to satisfy: this row's
     * Block Effect cell renders BEFORE Actions, so an operator sees what a
     * block would actually do to this feature BEFORE deciding whether to
     * press it -- never after. See featureBlockEnforcement() above for the
     * three-state contract this reads and why it is never derived from
     * `feature.key` here.
     */
    function buildPersonFeatureRow(feature) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: featureLabel(feature) }));
        tr.appendChild(mk('td', { class: 'k9tablet-feature-state--' + feature.state, text: featureStateLabel(feature.state) }));

        var citizenid = state.person.citizenid;
        var key = feature.key;
        var enforcement = featureBlockEnforcement(feature);

        var blockEffectTd = mk('td', { class: 'k9tablet-block-effect' });

        if (!feature.globallyEnabled) {
            // Step 1 is absolute -- see this file's header. NO controls
            // rendered at all for a globally-disabled feature: a grant here
            // would produce a button that silently does nothing, and this
            // page must not offer that. The Block Effect column stays
            // blank/muted for the same reason -- whether a block would be
            // honoured is moot when the feature cannot run at all.
            tr.appendChild(blockEffectTd);
            var offActionsTd = mk('td', { class: 'k9tablet-feature-actions' });
            offActionsTd.appendChild(mk('span', { class: 'k9tablet-muted', text: S('state_global_off') }));
            tr.appendChild(offActionsTd);
            return tr;
        }

        if (enforcement === 'not_enforceable') {
            blockEffectTd.appendChild(mk('span', {
                class: 'k9tablet-block-badge k9tablet-block-badge--unavailable',
                text: S('block_not_enforceable_note'),
            }));
        } else {
            blockEffectTd.appendChild(mk('span', {
                class: 'k9tablet-block-badge k9tablet-block-badge--' + enforcement,
                text: blockEnforcementBadgeLabel(enforcement),
                title: enforcement === 'not_yet_enforced' ? S('block_not_yet_enforced_hint') : undefined,
            }));
        }
        tr.appendChild(blockEffectTd);

        var actionsTd = mk('td', { class: 'k9tablet-feature-actions' });

        // Block/Unblock -- offered for every feature EXCEPT one this page
        // has been told, server-side, can never honour one (`enforcement
        // === 'not_enforceable'`) -- see this file's own PersonFeaturesResult
        // doc comment above for the two ways that happens (no server-side
        // implementation point at all, e.g. a client-toggled ability like
        // ThermalVision/NightVision against a modified client; or a
        // deliberate design decision, e.g. server/recall.lua's escape-hatch
        // path). Offering a button that can never do anything is exactly
        // the dishonest control this task exists to remove -- HIDDEN, not
        // merely labeled, for this one case. `feature.blocked` (a block row
        // may already exist from before this distinction was surfaced) is
        // still shown via the state badge above regardless.
        if (enforcement !== 'not_enforceable') {
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

    // ---- K9 Supply Shop location management screen (high command only) ----

    /**
     * Owner's own words: "make the shop a dog ped and i can change the
     * locations in the config or add more locations remove locations etc
     * along with in the high command tablet." Renders the LIVE, effective
     * location list from state.shopLocations (populated by
     * loadShopLocations() -- never hardcoded here), each row either a
     * read-only `cfg:<n>` (config.lua) entry or an editable/removable
     * `db:<id>` (runtime) one, plus (when a draft is open) the add/edit
     * form below the table. server/equipmentshop.lua's own
     * CanManageShopLocations is the real authorization gate, re-checked on
     * every one of the three mutating callbacks this screen calls -- see
     * THE SECURITY RULE.
     */
    function buildShopLocationsScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('shop_locations_heading') }));

        if (!state.shopLocationsEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('shop_locations_disabled_note') }));
        }

        if (state.shopLocationsLoading && !state.shopLocations) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.shopLocationsError && !state.shopLocations) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: shopLocationErrorText(state.shopLocationsError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadShopLocations));
            return wrap;
        }
        if (!state.shopLocations) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildShopLocationsTable());

        if (state.shopLocationDraft) {
            wrap.appendChild(buildShopLocationDraftForm());
        } else {
            wrap.appendChild(mkButton(S('shop_location_add_here_label'), 'k9tablet-btn', openNewShopLocationDraft, { disabled: state.pendingAction }));
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('shop_location_add_hint') }));
        }

        return wrap;
    }

    /**
     * `state.shopLocations` is a MAP (location key -> location), not an
     * array -- server/equipmentshop.lua's own GetLocations response shape
     * (`table<string, ShopLocation>`). Sorted here purely for a stable,
     * predictable display order: config.lua's own `cfg:<n>` entries first
     * (by their numeric config-array index), then runtime `db:<id>` ones
     * (by numeric id) -- never an ordinal the server tracks (there isn't
     * one for this list, unlike certification tiers).
     * @returns {Array<{key: string, loc: object}>}
     */
    function sortedShopLocationEntries() {
        var keys = [];
        for (var k in state.shopLocations) {
            if (Object.prototype.hasOwnProperty.call(state.shopLocations, k)) keys.push(k);
        }
        keys.sort(function (a, b) {
            var aIsConfig = a.indexOf('cfg:') === 0;
            var bIsConfig = b.indexOf('cfg:') === 0;
            if (aIsConfig !== bIsConfig) return aIsConfig ? -1 : 1;
            var aNum = parseInt(a.split(':')[1], 10);
            var bNum = parseInt(b.split(':')[1], 10);
            if (isFinite(aNum) && isFinite(bNum) && aNum !== bNum) return aNum - bNum;
            return a < b ? -1 : (a > b ? 1 : 0);
        });
        var out = [];
        for (var i = 0; i < keys.length; i++) out.push({ key: keys[i], loc: state.shopLocations[keys[i]] });
        return out;
    }

    /** @param {object} loc @returns {string} e.g. "123.4, -456.7, 30.0" */
    function formatShopLocationCoordinates(loc) {
        if (!loc || typeof loc.x !== 'number' || typeof loc.y !== 'number' || typeof loc.z !== 'number') return '';
        return loc.x.toFixed(1) + ', ' + loc.y.toFixed(1) + ', ' + loc.z.toFixed(1);
    }

    function buildShopLocationsTable() {
        var entries = sortedShopLocationEntries();
        if (entries.length === 0) {
            var empty = mk('div', {});
            empty.appendChild(mk('p', { class: 'k9tablet-muted', text: S('shop_locations_empty') }));
            return empty;
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_label'), S('column_coordinates'), S('column_model'), S('column_source'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < entries.length; i++) {
            tbody.appendChild(buildShopLocationRow(entries[i].key, entries[i].loc));
        }
        table.appendChild(tbody);
        return table;
    }

    /**
     * @param {string} key -- 'cfg:<n>' (config.lua, read-only) or 'db:<id>' (runtime, editable/removable)
     * @param {object} loc -- {x,y,z,heading,model,scenario,label}, ALL already resolved server-side, never nil
     */
    function buildShopLocationRow(key, loc) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: (loc && typeof loc.label === 'string') ? loc.label : '' }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: formatShopLocationCoordinates(loc) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (loc && typeof loc.model === 'string') ? loc.model : '' }));

        var isRuntime = key.indexOf('db:') === 0;
        tr.appendChild(mk('td', { text: isRuntime ? S('source_runtime') : S('source_config') }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        if (isRuntime) {
            actionsTd.appendChild(mkButton(S('shop_location_edit_label'), 'k9tablet-btn', function () {
                openEditShopLocationDraft(key, loc);
            }, { disabled: state.pendingAction }));
            // Two-click confirm (not styled `--danger`: repositioning is
            // reversible, but consequential enough -- it moves a live shop
            // ped to wherever the operator happens to be standing -- that a
            // stray click deserves a second one, same reasoning as every
            // other mkConfirmButton on this page).
            actionsTd.appendChild(mkConfirmButton(S('shop_location_move_here_label'), 'k9tablet-btn', function () {
                moveShopLocationHere(key);
            }, { disabled: state.pendingAction, title: S('shop_location_move_here_hint') }));
            actionsTd.appendChild(mkConfirmButton(S('shop_location_remove_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                removeShopLocation(key);
            }, { disabled: state.pendingAction }));
        } else {
            // config.lua entries are NEVER editable/removable from here --
            // see server/equipmentshop.lua's own SCOPE note: a stored
            // override keyed to config.lua's own array index would silently
            // apply to the wrong location the instant an operator reorders
            // that array.
            actionsTd.appendChild(mk('span', { class: 'k9tablet-muted', text: S('shop_location_config_note') }));
        }

        // A Move/Remove REFUSAL renders INLINE on THIS specific row --
        // "cannot, and here is why" -- same convention as
        // certTierActionError just above.
        if (state.shopLocationActionError && state.shopLocationActionError.key === key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.shopLocationActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Opens a BLANK draft for a brand-new location -- `key: null` marks it
     * as "new" for saveShopLocationDraft() below. Deliberately NO x/y/z/
     * heading fields on this draft at all: those are captured entirely
     * client(Lua)-side from the operator's own current position at Save
     * time (see client/tablet.lua's own tablet:equipmentShopAddLocation --
     * this page has no native access to GetEntityCoords to offer them even
     * if it wanted to). */
    function openNewShopLocationDraft() {
        state.shopLocationDraft = { key: null, label: '', model: '', scenario: '' };
        render();
    }

    /** Opens a draft pre-filled from an EXISTING runtime location -- a COPY
     * of its fields, never the live object, so Cancel never mutates
     * state.shopLocations. @param {string} key @param {object} loc */
    function openEditShopLocationDraft(key, loc) {
        state.shopLocationDraft = {
            key: key,
            label: (loc && typeof loc.label === 'string') ? loc.label : '',
            model: (loc && typeof loc.model === 'string') ? loc.model : '',
            scenario: (loc && typeof loc.scenario === 'string') ? loc.scenario : '',
        };
        render();
    }

    function closeShopLocationDraft() {
        state.shopLocationDraft = null;
        render();
    }

    /** Add/Edit form -- label/model/scenario ONLY, reusing the SAME field/
     * form classes as the theme editor / certification tier form (no new
     * CSS introduced for this screen -- see html/tablet.css's own note).
     * Position is NEVER edited here -- see openNewShopLocationDraft()'s own
     * comment and the "Move Here" row action instead. */
    function buildShopLocationDraftForm() {
        var draft = state.shopLocationDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var labelRow = mk('div', { class: 'k9tablet-theme-field' });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_location_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_location_label_placeholder'), maxlength: '100' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var modelRow = mk('div', { class: 'k9tablet-theme-field' });
        modelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_location_model_label') }));
        var modelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_location_model_placeholder'), maxlength: '64' } });
        modelInput.value = draft.model;
        modelInput.addEventListener('input', function (e) { draft.model = e.target.value; });
        modelRow.appendChild(modelInput);
        wrap.appendChild(modelRow);

        var scenarioRow = mk('div', { class: 'k9tablet-theme-field' });
        scenarioRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_location_scenario_label') }));
        var scenarioInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_location_scenario_placeholder'), maxlength: '64' } });
        scenarioInput.value = draft.scenario;
        scenarioInput.addEventListener('input', function (e) { draft.scenario = e.target.value; });
        scenarioRow.appendChild(scenarioInput);
        wrap.appendChild(scenarioRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('shop_location_save_label'), 'k9tablet-btn', saveShopLocationDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('shop_location_cancel_label'), 'k9tablet-link-btn', closeShopLocationDraft));
        wrap.appendChild(actions);

        if (draft.key === null) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('shop_location_add_hint') }));
        }

        return wrap;
    }

    /** @param {object|undefined} result @returns {string} */
    function shopLocationErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('shop_location_error_denied');
            case 'rate_limited': return S('shop_location_error_rate_limited');
            case 'invalid_coords': return S('shop_location_error_invalid_coords');
            case 'invalid_heading': return S('shop_location_error_invalid_heading');
            case 'invalid_model': return S('shop_location_error_invalid_model');
            case 'invalid_scenario': return S('shop_location_error_invalid_scenario');
            case 'invalid_label': return S('shop_location_error_invalid_label');
            case 'invalid_key': return S('shop_location_error_invalid_key');
            case 'invalid_payload': return S('shop_location_error_invalid_payload');
            case 'db_error': return S('shop_location_error_db_error');
            case 'feature_disabled': return S('shop_location_error_feature_disabled');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    // ---- Runtime feature control + tuning screen (high command only) ----

    /**
     * Owner's own words: "Lets high command switch features on and off
     * SERVER-WIDE from the tablet, and tune numbers live."
     * server/runtimecontrol.lua's own CanManageRuntimeControl is the real
     * authorization gate, re-checked on every one of the six callbacks
     * this screen calls -- see THE SECURITY RULE. Renders TWO independent
     * sections (Features, Tunables) on one screen -- same "several headed
     * sections, one screen" shape buildMyRecordScreen() already uses for
     * Certifications/XP/Abilities.
     */
    function buildRuntimeControlScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('runtime_control_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('runtime_control_intro') }));

        if (!state.runtimeControlEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('runtime_control_disabled_note') }));
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('runtime_features_heading') }));
        wrap.appendChild(buildRuntimeFeaturesSection());

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('runtime_tunables_heading') }));
        wrap.appendChild(buildRuntimeTunablesSection());

        return wrap;
    }

    /** @param {string} tier @returns {string} plain-language badge text -- NEVER server/runtimecontrol.lua's own raw `note` prose, see this screen's own header note. */
    function runtimeTierLabel(tier) {
        switch (tier) {
            case 'live': return S('runtime_tier_live');
            case 'onstart': return S('runtime_tier_onstart');
            case 'rawtoplevel': return S('runtime_tier_rawtoplevel');
            case 'clientonly': return S('runtime_tier_clientonly');
            case 'protected': return S('runtime_tier_protected');
            default: return S('runtime_tier_unaudited');
        }
    }

    /** @param {string} tier @returns {string} one-sentence, locale-driven explanation of what this tier actually means -- rendered BEFORE a toggle is ever pressed (always visible on the row) and reused as the post-action notice text (see toggleRuntimeFeature()/resetRuntimeFeature() below), so the SAME honest explanation is shown before and after. */
    function runtimeTierDescription(tier) {
        switch (tier) {
            case 'live': return S('runtime_tier_live_desc');
            case 'onstart': return S('runtime_tier_onstart_desc');
            case 'rawtoplevel': return S('runtime_tier_rawtoplevel_desc');
            case 'clientonly': return S('runtime_tier_clientonly_desc');
            case 'protected': return S('runtime_tier_protected_desc');
            default: return S('runtime_tier_unaudited_desc');
        }
    }

    /** `state.runtimeFeatures` arrives as a Lua array built from `pairs()`
     * traversal order (server/runtimecontrol.lua's own runtimeListFeatures),
     * which is NOT a stable/predictable order across boots -- sorted here
     * purely for a stable display, same reasoning as
     * sortedShopLocationEntries() above. @returns {Array<object>} */
    function sortedRuntimeFeatures() {
        var list = (state.runtimeFeatures || []).slice();
        list.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
        return list;
    }

    /** @returns {Array<object>} same reasoning as sortedRuntimeFeatures() above, sorted by `key`. */
    function sortedRuntimeTunables() {
        var list = (state.runtimeTunables || []).slice();
        list.sort(function (a, b) { return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0); });
        return list;
    }

    function buildRuntimeFeaturesSection() {
        var wrap = mk('div', {});
        if (state.runtimeFeaturesLoading && !state.runtimeFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.runtimeFeaturesError && !state.runtimeFeatures) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: runtimeListErrorText(state.runtimeFeaturesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadRuntimeFeatures));
            return wrap;
        }
        if (!state.runtimeFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        wrap.appendChild(buildRuntimeFeaturesTable());
        return wrap;
    }

    function buildRuntimeFeaturesTable() {
        var list = sortedRuntimeFeatures();
        if (list.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('runtime_features_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_name'), S('column_tier'), S('column_current_value'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < list.length; i++) tbody.appendChild(buildRuntimeFeatureRow(list[i]));
        table.appendChild(tbody);
        return table;
    }

    /**
     * @param {{name:string,currentValue:boolean,tier:string,note?:string,overridden:boolean,overriddenBy?:string,overriddenAt?:string}} feature
     */
    function buildRuntimeFeatureRow(feature) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: feature.name }));

        var tierTd = mk('td');
        tierTd.appendChild(mk('span', { class: 'k9tablet-runtime-tier k9tablet-runtime-tier--' + feature.tier, text: runtimeTierLabel(feature.tier) }));
        // THE HONESTY REQUIREMENT, satisfied BEFORE any click: this
        // sentence is always visible on the row, never hidden behind a
        // hover/tooltip -- see this screen's own header note and
        // buildRuntimeControlScreen()'s doc comment.
        tierTd.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: runtimeTierDescription(feature.tier) }));
        // A per-feature caveat (e.g. ScentTracking's drop-hook gap) is
        // server-authored, dynamic supplementary text -- rendered as a
        // passthrough, same posture as errorText()'s own `message` field,
        // NEVER treated as this row's PRIMARY (locale-driven) explanation.
        if (typeof feature.note === 'string' && feature.note.length > 0) {
            tierTd.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: feature.note }));
        }
        tr.appendChild(tierTd);

        var valueTd = mk('td');
        valueTd.appendChild(mk('span', { class: 'k9tablet-runtime-value k9tablet-runtime-value--' + (feature.currentValue ? 'on' : 'off'), text: feature.currentValue ? S('runtime_value_on') : S('runtime_value_off') }));
        if (feature.overridden) {
            valueTd.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('runtime_overridden_by_at'), { who: feature.overriddenBy || '?', when: feature.overriddenAt || '?' }) }));
        }
        tr.appendChild(valueTd);

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        if (feature.tier === 'protected' || feature.tier === 'unaudited') {
            // NO TOGGLE RENDERED AT ALL for these two -- server/runtimecontrol.lua
            // refuses both unconditionally (reason='protected_feature'/
            // 'unaudited_feature'); offering a button that always comes
            // back refused would be exactly the "switch that appears to
            // work" problem this task exists to fix.
            actionsTd.appendChild(mk('p', { class: 'k9tablet-muted', text: runtimeTierDescription(feature.tier) }));
        } else {
            var toggleLabel = feature.currentValue ? S('runtime_feature_toggle_off_label') : S('runtime_feature_toggle_on_label');
            actionsTd.appendChild(mkConfirmButton(toggleLabel, 'k9tablet-btn' + (feature.currentValue ? ' k9tablet-btn--danger' : ''), function () {
                toggleRuntimeFeature(feature.name, !feature.currentValue, feature.tier);
            }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));

            if (feature.overridden) {
                actionsTd.appendChild(mkConfirmButton(S('runtime_feature_reset_label'), 'k9tablet-link-btn', function () {
                    resetRuntimeFeature(feature.name, feature.tier);
                }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            }
        }

        // A Set/Reset REFUSAL renders INLINE on THIS specific row --
        // "cannot, and here is why" -- same convention as
        // certTierActionError/shopLocationActionError above.
        if (state.runtimeFeatureActionError && state.runtimeFeatureActionError.key === feature.name) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.runtimeFeatureActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    function buildRuntimeTunablesSection() {
        var wrap = mk('div', {});
        if (state.runtimeTunablesLoading && !state.runtimeTunables) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.runtimeTunablesError && !state.runtimeTunables) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: runtimeListErrorText(state.runtimeTunablesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadRuntimeTunables));
            return wrap;
        }
        if (!state.runtimeTunables) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        wrap.appendChild(buildRuntimeTunablesTable());
        return wrap;
    }

    function buildRuntimeTunablesTable() {
        var list = sortedRuntimeTunables();
        if (list.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('runtime_tunables_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_key'), S('column_current_value'), S('column_range'), S('column_type'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < list.length; i++) tbody.appendChild(buildRuntimeTunableRow(list[i]));
        table.appendChild(tbody);
        return table;
    }

    /**
     * @param {{key:string,currentValue:number,min:number,max:number,integer:boolean,overridden:boolean,overriddenBy?:string,overriddenAt?:string}} tunable
     */
    function buildRuntimeTunableRow(tunable) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: tunable.key }));

        var isEditing = state.runtimeTunableDraft && state.runtimeTunableDraft.key === tunable.key;

        var valueTd = mk('td');
        if (isEditing) {
            // A plain number-input HINT only (min/max/step) -- NOT an
            // authoritative gate: this page never blocks Save based on
            // these attributes, and reads `.value` directly rather than
            // relying on native form validation to enforce them (see
            // saveRuntimeTunableDraft() below and this screen's own header
            // note: "do not duplicate the validation client-side as if it
            // were authoritative").
            var input = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', min: String(tunable.min), max: String(tunable.max), step: tunable.integer ? '1' : 'any' } });
            input.value = state.runtimeTunableDraft.value;
            input.addEventListener('input', function (e) { state.runtimeTunableDraft.value = e.target.value; });
            valueTd.appendChild(input);
        } else {
            valueTd.appendChild(mk('span', { text: String(tunable.currentValue) }));
            if (tunable.overridden) {
                valueTd.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('runtime_overridden_by_at'), { who: tunable.overriddenBy || '?', when: tunable.overriddenAt || '?' }) }));
            }
        }
        tr.appendChild(valueTd);

        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: tunable.min + ' – ' + tunable.max }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: tunable.integer ? S('runtime_tunable_type_integer') : S('runtime_tunable_type_decimal') }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        if (isEditing) {
            actionsTd.appendChild(mkButton(S('runtime_tunable_save_label'), 'k9tablet-btn', function () {
                saveRuntimeTunableDraft(tunable);
            }, { disabled: state.pendingAction }));
            actionsTd.appendChild(mkButton(S('runtime_tunable_cancel_label'), 'k9tablet-link-btn', closeRuntimeTunableDraft));
        } else {
            actionsTd.appendChild(mkButton(S('runtime_tunable_edit_label'), 'k9tablet-btn', function () {
                openRuntimeTunableDraft(tunable);
            }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            if (tunable.overridden) {
                actionsTd.appendChild(mkConfirmButton(S('runtime_tunable_reset_label'), 'k9tablet-link-btn', function () {
                    resetRuntimeTunable(tunable.key);
                }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            }
        }

        if (state.runtimeTunableFieldError && state.runtimeTunableFieldError.key === tunable.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.runtimeTunableFieldError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Shared by both the Features and Tunables LIST loaders below -- their
     * only failure mode beyond fetchNui()'s own synthetic timeout/network
     * codes is `reason='denied'` (CanManageRuntimeControl), renamed to
     * `error` by client/tablet.lua's TranslateReasonResult.
     * @param {object|undefined} result @returns {string} */
    function runtimeListErrorText(result) {
        if (!result) return S('error_generic');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        if (result.error === 'denied') return S('runtime_error_denied');
        return errorText(result);
    }

    /** @param {object|undefined} result @returns {string} */
    function runtimeFeatureErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('runtime_error_denied');
            case 'rate_limited': return S('runtime_error_rate_limited');
            case 'invalid_feature': return S('runtime_feature_error_invalid_feature');
            case 'invalid_value': return S('runtime_feature_error_invalid_value');
            // REFUSALS ("cannot, and here is why"), not generic failures --
            // per this task's own explicit instruction -- reuse the SAME
            // tier description this row already shows before the click,
            // so the reason given here is never a DIFFERENT story than the
            // one already on screen.
            case 'protected_feature': return S('runtime_tier_protected_desc');
            case 'unaudited_feature': return S('runtime_tier_unaudited_desc');
            case 'feature_disabled': return S('runtime_control_disabled_note');
            case 'db_error': return S('runtime_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {object|undefined} result @returns {string} */
    function runtimeTunableErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('runtime_error_denied');
            case 'rate_limited': return S('runtime_error_rate_limited');
            case 'invalid_key': return S('runtime_tunable_error_invalid_key');
            // The server's OWN real min/max, echoed back verbatim -- see
            // this file's header NUI CONTRACT note: never a client-guessed
            // range.
            case 'out_of_range': return formatTemplate(S('runtime_tunable_error_out_of_range'), {
                min: (result && result.min !== undefined && result.min !== null) ? result.min : '?',
                max: (result && result.max !== undefined && result.max !== null) ? result.max : '?',
            });
            case 'not_integer': return S('runtime_tunable_error_not_integer');
            case 'feature_disabled': return S('runtime_control_disabled_note');
            case 'db_error': return S('runtime_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {object} tunable */
    function openRuntimeTunableDraft(tunable) {
        state.runtimeTunableDraft = { key: tunable.key, value: String(tunable.currentValue) };
        state.runtimeTunableFieldError = null;
        render();
    }

    function closeRuntimeTunableDraft() {
        state.runtimeTunableDraft = null;
        state.runtimeTunableFieldError = null;
        render();
    }

    // ---- K9 Audit Trail viewer screen (see canViewAudit()) ----

    /** Fixed order the five mode buttons render in -- matches
     * server/admin.lua's own COMMAND SURFACE listing (k9auditcert,
     * k9auditpartner, k9auditsearch, k9auditxp, k9auditdept). */
    var AUDIT_MODES = ['cert', 'partner', 'search', 'xp', 'dept'];

    /** @param {string} mode @returns {string} */
    function auditModeLabel(mode) {
        switch (mode) {
            case 'cert': return S('audit_mode_cert');
            case 'partner': return S('audit_mode_partner');
            case 'search': return S('audit_mode_search');
            case 'xp': return S('audit_mode_xp');
            case 'dept': return S('audit_mode_dept');
            default: return mode;
        }
    }

    /**
     * Owner's own framing (relayed): the audit trail this resource
     * carefully writes -- certification grants/revokes, partnership
     * history, the search log, XP totals, department rosters -- was
     * invisible to anyone without server console/SQL access, even though
     * server/admin.lua's own five commands already existed to query it.
     * This screen is that surface. server/admin.lua's own IsAuthorizedAdmin
     * is the ONLY real gate (see canViewAudit()'s own doc comment); every
     * control here is a convenience, per THE SECURITY RULE.
     */
    function buildAuditScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('audit_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_intro') }));

        if (!state.auditEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_disabled_note') }));
        }

        wrap.appendChild(buildAuditModeSwitch());
        wrap.appendChild(buildAuditForm());
        wrap.appendChild(buildAuditResults());
        return wrap;
    }

    function buildAuditModeSwitch() {
        var row = mk('div', { class: 'k9tablet-audit-modes' });
        AUDIT_MODES.forEach(function (mode) {
            row.appendChild(mkButton(auditModeLabel(mode), 'k9tablet-tab' + (state.auditMode === mode ? ' k9tablet-tab--active' : ''), function () {
                // Switching mode changes which fields/columns even apply --
                // the LAST mode's result would be the wrong shape to keep
                // showing under a different mode's table columns, so it (and
                // any leftover error) is cleared here. The typed field
                // VALUES themselves (citizenid/department/search value/limit)
                // are deliberately left alone -- several modes share the
                // same citizenid input, and there is no reason to make an
                // officer retype it just for glancing between Certifications
                // and Partnerships for the same person.
                state.auditMode = mode;
                state.auditError = null;
                state.auditResult = null;
                render();
            }, { disabled: state.auditLoading }));
        });
        return row;
    }

    /**
     * @returns {string[]} the REAL, configured department keys this VIEWER
     * currently holds a certification row for -- server/tablet.lua's own
     * tabletRequestMyRecord returns "ONE ROW PER CONFIGURED DEPARTMENT",
     * so this is never a hardcoded department list, and needs no extra
     * round trip: loadMyRecord() already runs on every tablet:open. Used
     * ONLY as `<datalist>` autocomplete suggestions for the Department
     * Roster mode's free-text input, never as the sole way to enter one
     * -- server/admin.lua's own IsValidDepartment is the real gate, and an
     * operator may legitimately want to audit a department this VIEWER
     * personally holds no certification in at all (that file's own header:
     * "NOT SCOPED TO THE CALLER'S OWN DEPARTMENT").
     */
    function knownDepartmentKeys() {
        if (!state.myRecord || !Array.isArray(state.myRecord.certifications)) return [];
        var out = [];
        state.myRecord.certifications.forEach(function (c) {
            if (c && typeof c.departmentKey === 'string' && c.departmentKey.length > 0) out.push(c.departmentKey);
        });
        return out;
    }

    function buildAuditForm() {
        var form = mk('div', { class: 'k9tablet-audit-form' });

        if (state.auditMode === 'cert' || state.auditMode === 'partner' || state.auditMode === 'xp') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_citizenid_label') }));
            var idInput = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('audit_citizenid_placeholder') } });
            idInput.value = state.auditCitizenId;
            idInput.addEventListener('input', function (e) { state.auditCitizenId = e.target.value; });
            form.appendChild(idInput);
        } else if (state.auditMode === 'dept') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_department_label') }));
            var deptInput = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('audit_department_placeholder'), list: 'k9tablet-audit-dept-options' } });
            deptInput.value = state.auditDepartment;
            deptInput.addEventListener('input', function (e) { state.auditDepartment = e.target.value; });
            form.appendChild(deptInput);

            var knownDepts = knownDepartmentKeys();
            if (knownDepts.length > 0) {
                var dataList = mk('datalist', { attrs: { id: 'k9tablet-audit-dept-options' } });
                knownDepts.forEach(function (key) {
                    var opt = mk('option', {});
                    opt.setAttribute('value', key);
                    dataList.appendChild(opt);
                });
                form.appendChild(dataList);
            } else {
                form.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('audit_department_hint') }));
            }
        } else if (state.auditMode === 'search') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_search_mode_label') }));
            var modeSelect = mk('select', { class: 'k9tablet-audit-select' });
            [
                ['officer', S('audit_search_mode_officer')],
                ['plate', S('audit_search_mode_plate')],
                ['person', S('audit_search_mode_person')],
                ['recent', S('audit_search_mode_recent')],
            ].forEach(function (pair) {
                var opt = mk('option', { text: pair[1] });
                opt.setAttribute('value', pair[0]);
                modeSelect.appendChild(opt);
            });
            modeSelect.value = state.auditSearchMode;
            modeSelect.addEventListener('input', function (e) {
                state.auditSearchMode = e.target.value;
                render(); // the Value field below only applies to 3 of the 4 sub-modes -- must appear/disappear immediately, unlike a plain text field's own deferred-render convention elsewhere on this page
            });
            form.appendChild(modeSelect);

            if (state.auditSearchMode !== 'recent') {
                form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_value_label') }));
                var valueInput = mk('input', {
                    class: 'k9tablet-search',
                    attrs: {
                        type: 'text',
                        placeholder: state.auditSearchMode === 'plate' ? S('audit_value_placeholder_plate') : S('audit_value_placeholder_citizenid'),
                    },
                });
                valueInput.value = state.auditSearchValue;
                valueInput.addEventListener('input', function (e) { state.auditSearchValue = e.target.value; });
                form.appendChild(valueInput);
            }
        }

        if (state.auditMode !== 'xp') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_limit_label') }));
            var limitInput = mk('input', {
                class: 'k9tablet-audit-limit-input',
                attrs: { type: 'number', min: String(AUDIT_LIMIT_MIN), max: String(AUDIT_LIMIT_MAX) },
            });
            limitInput.value = String(state.auditLimit);
            limitInput.addEventListener('input', function (e) { state.auditLimit = e.target.value; });
            form.appendChild(limitInput);
        }

        form.appendChild(mkButton(S('audit_run_label'), 'k9tablet-btn', runAuditQuery, { disabled: state.auditLoading || !state.auditEnabled }));
        return form;
    }

    /** @param {*} v @returns {string} S('audit_na') for null/undefined/'' -- never a raw 'null'/'undefined' string on screen. */
    function auditText(v) {
        if (v === null || v === undefined || v === '') return S('audit_na');
        return String(v);
    }

    /** @param {*} v @returns {string} */
    function auditBoolText(v) {
        return v ? S('audit_boolean_yes') : S('audit_boolean_no');
    }

    /** @param {object|undefined} result @returns {string} */
    function auditErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'not_authorized': return S('audit_error_not_authorized');
            case 'rate_limited': return S('audit_error_rate_limited');
            case 'invalid_args': return S('audit_error_invalid_args');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /**
     * Per-mode column definitions -- see this file's own NUI CONTRACT note
     * on tablet:auditCert/Partner/Search/Xp/Dept for the authoritative row
     * shape each mode returns; this table renders EXACTLY those fields,
     * nothing reshaped or renamed. `id` (partner/search rows' own sort key)
     * is deliberately never a column here -- it is a MergeSortedByIdDesc
     * implementation detail server-side, meaningless to an officer reading
     * the table.
     * @param {'cert'|'partner'|'search'|'xp'|'dept'} mode
     * @returns {Array<{header:string, render:(row:object)=>string}>}
     */
    function auditColumnsForMode(mode) {
        switch (mode) {
            case 'cert':
                return [
                    { header: S('column_department'), render: function (r) { return auditText(r.job); } },
                    { header: S('column_active'), render: function (r) { return auditBoolText(r.active); } },
                    { header: S('column_granted_by'), render: function (r) { return auditText(r.granted_by); } },
                    { header: S('column_granted_at'), render: function (r) { return auditText(r.granted_at); } },
                    { header: S('column_revoked_by'), render: function (r) { return auditText(r.revoked_by); } },
                    { header: S('column_revoked_at'), render: function (r) { return auditText(r.revoked_at); } },
                ];
            case 'partner':
                return [
                    { header: S('column_k9'), render: function (r) { return auditText(r.k9_citizenid); } },
                    { header: S('column_handler'), render: function (r) { return auditText(r.handler_citizenid); } },
                    { header: S('column_active'), render: function (r) { return auditBoolText(r.active); } },
                    { header: S('column_established_by'), render: function (r) { return auditText(r.established_by); } },
                    { header: S('column_established_at'), render: function (r) { return auditText(r.established_at); } },
                    { header: S('column_ended_by'), render: function (r) { return auditText(r.ended_by); } },
                    { header: S('column_ended_at'), render: function (r) { return auditText(r.ended_at); } },
                ];
            case 'search':
                return [
                    { header: S('column_searched_at'), render: function (r) { return auditText(r.searched_at); } },
                    { header: S('column_searcher'), render: function (r) { return auditText(r.searcher_citizenid); } },
                    { header: S('column_searcher_job'), render: function (r) { return auditText(r.searcher_job); } },
                    { header: S('column_target_type'), render: function (r) { return auditText(r.target_type); } },
                    { header: S('column_target'), render: function (r) { return auditText(r.target_type === 'vehicle' ? r.target_plate : r.target_citizenid); } },
                    { header: S('column_result'), render: function (r) { return auditText(r.result); } },
                    { header: S('column_weight'), render: function (r) { return auditText(r.total_weight); } },
                    { header: S('column_alert_tier'), render: function (r) { return auditText(r.alert_tier); } },
                ];
            case 'xp':
                return [
                    { header: S('column_audit_xp'), render: function (r) { return auditText(r.xp); } },
                    { header: S('column_updated_at'), render: function (r) { return auditText(r.updated_at); } },
                ];
            case 'dept':
                return [
                    { header: S('column_citizenid'), render: function (r) { return auditText(r.citizenid); } },
                    { header: S('column_granted_by'), render: function (r) { return auditText(r.granted_by); } },
                    { header: S('column_granted_at'), render: function (r) { return auditText(r.granted_at); } },
                ];
            default:
                return [];
        }
    }

    /**
     * @param {'cert'|'partner'|'search'|'xp'|'dept'} mode
     * @param {Array<object>} rows
     */
    function buildAuditResultTable(mode, rows) {
        var columns = auditColumnsForMode(mode);
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        columns.forEach(function (c) { headRow.appendChild(mk('th', { text: c.header })); });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        rows.forEach(function (row) {
            var tr = mk('tr');
            columns.forEach(function (c) { tr.appendChild(mk('td', { text: c.render(row) })); });
            tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        return table;
    }

    /**
     * Renders exactly ONE of: a loading line, an error (with NO further
     * explanation lost -- see auditErrorText()), a first-visit prompt (never
     * a blank panel before the officer has run anything), an explicit empty-
     * result note, or the results table -- per this task's own "a failed
     * callback must not leave the screen blank with no explanation"
     * requirement.
     */
    function buildAuditResults() {
        var wrap = mk('div', {});

        if (state.auditLoading) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.auditError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: auditErrorText(state.auditError) }));
            return wrap;
        }
        if (!state.auditResult) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_result_prompt') }));
            return wrap;
        }
        if (state.auditResult.label) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: state.auditResult.label }));
        }
        if (state.auditResult.rows.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_result_empty') }));
            return wrap;
        }
        wrap.appendChild(buildAuditResultTable(state.auditMode, state.auditResult.rows));
        return wrap;
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
        // Opportunistic, best-effort: populates state.certTiers for this
        // screen's tier-assignment picker (buildCertificationDetail).
        // loadCertTiers() is target-independent and safe to call
        // regardless of arrival order (same note already on this
        // function's own definition) -- a caller who is not high command
        // simply gets `error:'denied'` back, state.certTiers stays
        // whatever it was (usually null), and the tier control falls back
        // to read-only text; see buildCertificationDetail's own doc
        // comment for why that fallback, rather than a second gate, is the
        // right call here.
        loadCertTiers();
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

    /** Fetched fresh every time the Shop Locations tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers() just above. High command only (server-side gate --
     * see this screen's own buildShopLocationsScreen() doc comment). */
    function loadShopLocations() {
        state.shopLocationsLoading = true;
        state.shopLocationsError = null;
        // STALE-RESPONSE GUARD: this tab can be left and revisited (or
        // Refresh -- via Retry after an error -- pressed twice) while an
        // earlier tablet:equipmentShopGetLocations request is still in
        // flight; nothing here cancels the underlying fetch. Unlike
        // loadPersonSummary()/loadRoster() (which compare the in-flight
        // request's own captured target/query against current state at
        // resolution time), this list has no such per-request identity to
        // key off -- so a plain, monotonically increasing request id is
        // used instead: only the response for the MOST RECENTLY issued
        // request is ever applied, exactly the same class of fix, applied
        // the only way it CAN be applied when every request asks the exact
        // same question.
        var requestId = ++state.shopLocationsRequestId;
        render();

        fetchNui('tablet:equipmentShopGetLocations', {}).then(function (result) {
            if (requestId !== state.shopLocationsRequestId) return;

            state.shopLocationsLoading = false;
            if (!result || result.ok !== true) {
                state.shopLocationsError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.shopLocations = (result.locations && typeof result.locations === 'object') ? result.locations : {};
            render();
        });
    }

    /** Fetched fresh every time the Runtime Control tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers()/loadShopLocations() above. High command only
     * (server-side gate -- see buildRuntimeControlScreen()'s own doc
     * comment). STALE-RESPONSE GUARD: same request-id shape as
     * loadShopLocations() above -- this list has no per-request identity
     * (like a citizenid/query) to compare against arrival order. */
    function loadRuntimeFeatures() {
        state.runtimeFeaturesLoading = true;
        state.runtimeFeaturesError = null;
        var requestId = ++state.runtimeFeaturesRequestId;
        render();

        fetchNui('tablet:runtimeListFeatures', {}).then(function (result) {
            if (requestId !== state.runtimeFeaturesRequestId) return;

            state.runtimeFeaturesLoading = false;
            if (!result || result.ok !== true) {
                state.runtimeFeaturesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.runtimeFeatures = Array.isArray(result.features) ? result.features : [];
            render();
        });
    }

    /** Same posture as loadRuntimeFeatures() immediately above, for the
     * Tunables section on the same screen. */
    function loadRuntimeTunables() {
        state.runtimeTunablesLoading = true;
        state.runtimeTunablesError = null;
        var requestId = ++state.runtimeTunablesRequestId;
        render();

        fetchNui('tablet:runtimeListTunables', {}).then(function (result) {
            if (requestId !== state.runtimeTunablesRequestId) return;

            state.runtimeTunablesLoading = false;
            if (!result || result.ok !== true) {
                state.runtimeTunablesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.runtimeTunables = Array.isArray(result.tunables) ? result.tunables : [];
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

    /**
     * Saves the shop-location draft form -- either creating a brand-new
     * location (draft.key === null, via tablet:equipmentShopAddLocation)
     * or editing an existing runtime one's metadata (via
     * tablet:equipmentShopMoveLocation's `updates` shape). NOT the generic
     * runMutation() helper: this page never optimistically mutates its own
     * shopLocations map for anything other than the server's own returned
     * `locations` (same "re-pull the authoritative version" posture as
     * every other mutation on this page), and needs its OWN post-success
     * handling (close the draft) rather than a generic reload callback.
     *
     * A blank field means two DIFFERENT things depending on isNew -- see
     * client/tablet.lua's own tablet:equipmentShopAddLocation/
     * MoveLocation doc comments for the full reasoning:
     *   - Add (isNew): OMITTED entirely (empty string is never sent) --
     *     "inherit the shop-wide default".
     *   - Edit: sent as `false` -- "reset this field back to the shop-wide
     *     default", since an edit draft always starts pre-filled from a
     *     real, already-resolved value (label/model are never blank; a
     *     blank scenario CAN legitimately mean "already resolved to no
     *     scenario" -- sending `false` for one that is already blank is a
     *     harmless no-op either way), so a blank field here is always
     *     either a DELIBERATE clear or a value that was already effectively
     *     the default, never silent data loss.
     */
    function saveShopLocationDraft() {
        if (state.pendingAction || !state.shopLocationDraft) return;
        var draft = state.shopLocationDraft;
        var isNew = draft.key === null;

        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var nuiName, payload;
        if (isNew) {
            payload = {};
            if (draft.label.trim().length > 0) payload.label = draft.label.trim();
            if (draft.model.trim().length > 0) payload.model = draft.model.trim();
            if (draft.scenario.trim().length > 0) payload.scenario = draft.scenario.trim();
            nuiName = 'tablet:equipmentShopAddLocation';
        } else {
            var toUpdateValue = function (value) {
                var trimmed = value.trim();
                return trimmed.length > 0 ? trimmed : false;
            };
            payload = {
                locationKey: draft.key,
                updates: {
                    label: toUpdateValue(draft.label),
                    model: toUpdateValue(draft.model),
                    scenario: toUpdateValue(draft.scenario),
                },
            };
            nuiName = 'tablet:equipmentShopMoveLocation';
        }

        fetchNui(nuiName, payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (result.locations && typeof result.locations === 'object') state.shopLocations = result.locations;
                state.shopLocationDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: shopLocationErrorText(result) };
            }
            render();
        });
    }

    /**
     * "Move Here" -- repositions an EXISTING runtime location to the
     * operator's own CURRENT in-game position. `useCurrentPosition: true`
     * is the ONLY thing sent for coordinates -- this page has no native
     * access to GetEntityCoords at all; client/tablet.lua captures the
     * real values at the moment this callback fires (see that file's own
     * tablet:equipmentShopMoveLocation doc comment).
     * @param {string} key
     */
    function moveShopLocationHere(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.shopLocationActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopMoveLocation', { locationKey: key, useCurrentPosition: true }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (result.locations && typeof result.locations === 'object') state.shopLocations = result.locations;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = shopLocationErrorText(result);
                state.shopLocationActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /** Deletes runtime location `key`. A refusal renders INLINE on that
     * row (state.shopLocationActionError), same "cannot, and here is why"
     * convention as deleteCertTier() above.
     * @param {string} key */
    function removeShopLocation(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.shopLocationActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopRemoveLocation', { locationKey: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (result.locations && typeof result.locations === 'object') state.shopLocations = result.locations;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = shopLocationErrorText(result);
                state.shopLocationActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /**
     * Toggles feature `name` to `newValue` -- NOT the generic runMutation()
     * helper: this page never optimistically mutates its own runtimeFeatures
     * copy (the response carries no full, refreshed list the way
     * certTiersUpsert's own `tiers` does), so a successful set/reset always
     * re-pulls via loadRuntimeFeatures() instead, same "re-pull the
     * authoritative version" posture as saveShopLocationDraft() above.
     *
     * THE HONESTY REQUIREMENT, satisfied AFTER the click too: the post-action
     * notice reuses the SAME tier description already shown on the row
     * BEFORE this was pressed (the `tier` argument here is this row's own,
     * already-known tier -- never trusted from the mutation response, since
     * server/runtimecontrol.lua's own runtimeResetFeature always reports
     * `restartRequired = false` regardless of tier, a known asymmetry
     * flagged to main rather than relied upon here).
     * @param {string} name @param {boolean} newValue @param {string} tier
     */
    function toggleRuntimeFeature(name, newValue, tier) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.runtimeFeatureActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:runtimeSetFeature', { name: name, value: newValue }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.actionNotice = { kind: 'ok', text: runtimeTierDescription(tier) };
                loadRuntimeFeatures();
            } else {
                var text = runtimeFeatureErrorText(result);
                state.runtimeFeatureActionError = { key: name, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /** Restores feature `name` to its config.lua-shipped default -- a
     * destructive action from an operator's point of view (discards an
     * override), hence mkConfirmButton's two-click guard at its own call
     * site, same posture as resetThemeToDefault()/deleteCertTier() above.
     * @param {string} name @param {string} tier -- this row's own,
     * already-known tier, see toggleRuntimeFeature()'s own doc comment on
     * why the response is not trusted for this. */
    function resetRuntimeFeature(name, tier) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.runtimeFeatureActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:runtimeResetFeature', { name: name }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.actionNotice = { kind: 'ok', text: runtimeTierDescription(tier) };
                loadRuntimeFeatures();
            } else {
                var text = runtimeFeatureErrorText(result);
                state.runtimeFeatureActionError = { key: name, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /**
     * Saves the inline number-editor's current working copy for ONE
     * tunable. Only a basic "is this even parseable as a number" guard is
     * applied HERE (see this file's header NUI CONTRACT note) -- the real
     * [min,max]/integer check is server/runtimecontrol.lua's own
     * runtimeSetTunable, whose exact bounds are echoed back verbatim on a
     * rejection (see runtimeTunableErrorText() above) rather than guessed
     * or re-derived client-side.
     * @param {{key:string}} tunable
     */
    function saveRuntimeTunableDraft(tunable) {
        if (state.pendingAction || !state.runtimeTunableDraft || state.runtimeTunableDraft.key !== tunable.key) return;

        var numericValue = parseFloat(state.runtimeTunableDraft.value);
        if (!isFinite(numericValue)) {
            state.runtimeTunableFieldError = { key: tunable.key, text: S('runtime_tunable_error_not_a_number') };
            render();
            return;
        }

        state.pendingAction = true;
        state.runtimeTunableFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:runtimeSetTunable', { key: tunable.key, value: numericValue }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.runtimeTunableDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                loadRuntimeTunables();
            } else {
                var text = runtimeTunableErrorText(result);
                state.runtimeTunableFieldError = { key: tunable.key, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /** Restores tunable `key` to its config.lua-shipped default -- same
     * two-click destructive-action posture as resetRuntimeFeature() above.
     * @param {string} key */
    function resetRuntimeTunable(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.runtimeTunableFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:runtimeResetTunable', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                loadRuntimeTunables();
            } else {
                var text = runtimeTunableErrorText(result);
                state.runtimeTunableFieldError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /** @param {*} value @returns {number} floored + clamped into
     * [AUDIT_LIMIT_MIN, AUDIT_LIMIT_MAX] -- see those constants' own
     * comment. Never lets an unclamped value reach fetchNui(), even
     * though server/admin.lua's own ClampLimit would independently catch
     * it anyway -- this page's own "make the UI agree with what the
     * server enforces" duty, per this task's instruction. `Number('')` is
     * NaN, `Number(undefined)` is NaN, `Math.floor(NaN)` is NaN, and
     * `NaN < x`/`NaN > x` are both false for any x -- so a blank/garbage
     * input falls through both clamp branches below unless caught first,
     * exactly the failure shape server/admin.lua's own ClampLimit doc
     * comment names for the identical reason; guarded here the same way,
     * once, via `isFinite`. */
    function clampAuditLimit(value) {
        var n = Math.floor(Number(value));
        if (!isFinite(n)) return AUDIT_LIMIT_MIN;
        if (n < AUDIT_LIMIT_MIN) return AUDIT_LIMIT_MIN;
        if (n > AUDIT_LIMIT_MAX) return AUDIT_LIMIT_MAX;
        return n;
    }

    /**
     * Submits the CURRENT audit form's fields to whichever tabletAudit*
     * callback state.auditMode selects. The blank-required-field checks
     * below are a UX CONVENIENCE ONLY, per THE SECURITY RULE -- they
     * synthesize the SAME `{error: 'invalid_args'}` shape server/admin.lua's
     * own IsValidCitizenId/IsValidDepartment/VALID_SEARCH_LOG_MODES would
     * refuse with anyway, rendered through the exact same auditErrorText(),
     * purely to avoid a pointless round trip for an obviously-incomplete
     * form -- a modified client skipping this check entirely still gets
     * refused, just one network hop later, by the real gate.
     * STALE-RESPONSE GUARD: same request-id shape as
     * shopLocationsRequestId/runtimeFeaturesRequestId elsewhere on this
     * page -- an officer can switch mode or press Run Query again while an
     * earlier query is still in flight; only the MOST RECENTLY issued
     * request's response is ever applied.
     */
    function runAuditQuery() {
        if (state.auditLoading || !state.auditEnabled) return;

        var limit = clampAuditLimit(state.auditLimit);
        state.auditLimit = limit; // reflect the clamp back into the input itself, so a typed 500 visibly becomes 100, never silently

        var name, payload;
        switch (state.auditMode) {
            case 'cert':
            case 'partner': {
                var certOrPartnerId = state.auditCitizenId.trim();
                if (certOrPartnerId.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = (state.auditMode === 'cert') ? 'tablet:auditCert' : 'tablet:auditPartner';
                payload = { targetCitizenId: certOrPartnerId, limit: limit };
                break;
            }
            case 'xp': {
                var xpId = state.auditCitizenId.trim();
                if (xpId.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = 'tablet:auditXp';
                payload = { targetCitizenId: xpId };
                break;
            }
            case 'dept': {
                var dept = state.auditDepartment.trim();
                if (dept.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = 'tablet:auditDept';
                payload = { departmentKey: dept, limit: limit };
                break;
            }
            case 'search': {
                var searchMode = state.auditSearchMode;
                var searchValue = state.auditSearchValue.trim();
                if (searchMode !== 'recent' && searchValue.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = 'tablet:auditSearch';
                payload = { mode: searchMode, limit: limit };
                if (searchMode !== 'recent') payload.value = searchValue;
                break;
            }
            default:
                return;
        }

        state.auditLoading = true;
        state.auditError = null;
        var requestId = ++state.auditRequestId;
        render();

        fetchNui(name, payload).then(function (result) {
            if (requestId !== state.auditRequestId) return; // STALE-RESPONSE GUARD -- a newer query has since been issued

            state.auditLoading = false;
            if (!result || result.ok !== true) {
                state.auditError = result || { error: 'unknown_error' };
                state.auditResult = null;
                render();
                return;
            }
            state.auditResult = {
                rows: Array.isArray(result.rows) ? result.rows : [],
                label: (typeof result.label === 'string') ? result.label : '',
            };
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
        state.specializations = (data.specializations && typeof data.specializations === 'object') ? data.specializations : {};
        state.themingEnabled = data.themingEnabled === true;
        state.shopLocationsEnabled = data.shopLocationsEnabled === true;
        state.runtimeControlEnabled = data.runtimeControlEnabled === true;
        state.auditEnabled = data.auditEnabled === true;
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
        state.auditMode = 'cert';
        state.auditCitizenId = '';
        state.auditDepartment = '';
        state.auditSearchMode = 'officer';
        state.auditSearchValue = '';
        state.auditError = null;
        state.auditResult = null;

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

    /** qbx_k9unit:client:equipmentShopLocationsUpdated relayed push -- SAME
     * posture as handleThemeUpdated() just above: fires for EVERY connected
     * client on every successful Add/Move/RemoveLocation, not only the
     * officer who triggered it, and NOT gated on this page's own open/
     * closed state. Applied unconditionally to state.shopLocations so an
     * already-open Shop Locations screen updates live; deliberately never
     * touches state.shopLocationDraft -- an in-progress add/edit form is
     * left alone, same as the theme editor's own working copy is (there)
     * intentionally overwritten but this one is not, since a location
     * DRAFT's own key may not even be present in the pushed map yet (a new,
     * unsaved one) and forcibly closing it out from under the operator
     * would discard work in progress for no correctness benefit.
     * @param {object} locations */
    function handleShopLocationsUpdated(locations) {
        if (!locations || typeof locations !== 'object') return;
        state.shopLocations = locations;
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
                case 'tablet:equipmentShopLocationsUpdated':
                    handleShopLocationsUpdated(msg.data);
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
