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
            // CLIENT-LOCAL role signal (this pass, owner-directed
            // "restructure the tablet around WHO IS HOLDING IT") --
            // ENRICHED ONTO THIS EXACT RESPONSE BY client/tablet.lua'S
            // OWN RegisterNUICallback('tablet:requestMyRecord', ...)
            // HANDLER, not sent by server/tablet.lua at all -- see that
            // handler's own ResolveLocalRoleFlags() doc comment. Cosmetic
            // framing ONLY for buildHomeScreen()'s role badge/partnered
            // indicator -- never read by, or forwarded into, any
            // mutation/trigger callback (see THE SECURITY RULE above).
            isK9Model: boolean,   // IsOwnModelK9() -- is this client currently wearing a K9 model right now
            isPartnered: boolean, // IsPartnered() -- is this client currently in an established handler/K9 partnership right now
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
                blockEnforcement?: 'enforced'|'client_enforced'|'not_yet_enforced'|'not_enforceable',
                // ^ NOW LANDED for every Config.Features key (server/tablet.lua's
                // ResolveBlockEnforcement, called from BuildPersonFeaturesArray) --
                // see server/tablet.lua's own `blocked`/`state` fields above: neither
                // one tells the operator whether setting block.<key> actually stops
                // anything. This page cannot answer that itself (Do not invent a
                // client-side list here -- see featureBlockEnforcement() below for
                // why, and THE SECURITY RULE for why a hardcoded guess would rot the
                // moment another feature's own server file gets a real `block.<key>`
                // check wired in). Server-side, FOUR states:
                //   'enforced'         -- some feature-owning server file confirmed,
                //                         by direct code read, to check
                //                         HasPermission(citizenid, 'block.<key>') before
                //                         permitting the actual ability -- mirrors
                //                         server/runtimecontrol.lua's own FEATURE_TIERS
                //                         discipline (a small, explicit, code-read-verified
                //                         registry, not a guess), for the identical reason:
                //                         a manually-derived claim needs a human to have
                //                         actually read the file it's claiming something about.
                //   'client_enforced'  -- STRICTLY WEAKER than 'enforced', and a
                //                         DIFFERENT thing from 'not_enforceable':
                //                         client/featureblocks.lua's twelve purely
                //                         client-rendered/client-local abilities (e.g.
                //                         ThermalVision/NightVision) now DO honour a
                //                         per-person block -- genuinely, for every
                //                         ordinary, unmodified client -- but the check
                //                         runs entirely on the PLAYER'S OWN client, so a
                //                         modified one can always choose to skip it,
                //                         exactly like this resource's other client-side
                //                         gates (IsOwnModelK9/CanShowK9UI). Rendering
                //                         this as bare 'enforced' would falsely claim
                //                         server-side parity; rendering it as
                //                         'not_enforceable' would falsely claim the
                //                         block does nothing. See
                //                         locales/en.json's
                //                         tablet.block_client_enforced_badge/_hint for
                //                         the operator-facing "best-effort, not a
                //                         guarantee" wording -- never soften it.
                //   'not_enforceable'  -- structurally cannot ever take effect, for a
                //                         reason that is NOT "nobody has wired it in
                //                         yet": either there is no per-citizenid ability
                //                         here at all to gate in the first place (a pure
                //                         administrative/infrastructure switch -- e.g.
                //                         HighCommand, CommandTablet), or the feature's
                //                         own owning file documents a DELIBERATE decision
                //                         never to honour one (e.g. server/recall.lua's
                //                         block.Recall -- a termination/escape-hatch path
                //                         that must never be gated, by this resource's
                //                         own "no unbounded trap" rule). NOTE: an EARLIER
                //                         version of this comment also named
                //                         K9EquipmentShop here -- that was corrected:
                //                         server/equipmentshop.lua now genuinely enforces
                //                         a block via ox_inventory's own openShop/buyItem
                //                         hooks, so it resolves 'enforced' like any other
                //                         server-gated ability.
                //   'not_yet_enforced' -- (also the FALLBACK for a missing/unrecognized
                //                         value, and for this field being entirely absent
                //                         from an older server response) -- structurally
                //                         possible, simply not read/confirmed yet. THE SAFE
                //                         DEFAULT DIRECTION: this page never renders a
                //                         feature as 'enforced' (or 'client_enforced')
                //                         unless the server explicitly says so.
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
          { ok: true, rows: Array<object>, label: string, cap: number, limit?: number, truncated?: boolean }
        `cap`/`limit`/`truncated` (added in a LATER pass than the five
        bridges themselves -- see server/admin.lua's own ClampLimit and
        CALLBACK SURFACE comments for the authoritative contract): `cap` is
        that file's own HARD_MAX_RESULTS, served back on EVERY success
        response (including tabletAuditXp's, for a uniform shape, even
        though that one query takes no `limit` at all); `limit` is the
        exact, already-clamped value the server actually used for a query
        that DOES take one; `truncated` is `true` only when the caller's
        own request exceeded `cap` and was cut down to it. This page treats
        `cap` as the LIVE, authoritative ceiling from the moment any query
        succeeds (see auditEffectiveCap()/AUDIT_LIMIT_MAX_FALLBACK below) --
        the fallback constant is a last resort only, never assumed correct
        once the server has actually reported a real value. `label` is
        SERVER-AUTHORED, already locale()-resolved prose (this
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
        [AUDIT_LIMIT_MIN, auditEffectiveCap()] client-side so a typed value
        is never silently truncated server-side with no visible feedback
        here. auditEffectiveCap() prefers the REAL cap the server itself
        reported on the most recent successful query (`result.cap` above)
        -- AUDIT_LIMIT_MAX_FALLBACK (a hardcoded 100, matching
        server/admin.lua's HARD_MAX_RESULTS at the time this fallback was
        written) is used ONLY before that has ever happened (first render
        of a fresh tablet session) or if a response is ever missing `cap`
        entirely (a server build that predates this field) -- see that
        constant's own comment for why it is deliberately never assumed
        correct once a real value is known. Even when this page's own guess
        is stale and sends a `limit` the server ends up clamping further,
        `result.truncated`/`result.limit` on the response tell the operator
        exactly what happened rather than silently showing a short list --
        see buildAuditResults()'s own truncation notice.

    Lua -> JS (SendNUIMessage on the TOP window, relayed into this page's
    OWN window by html/tablet-bridge.js for any action matching /^tablet:/
    -- see that file's header for why a relay is needed at all):

      { action: 'tablet:open', data: {
          capabilities: { 'k9.access': {label,description}, ... },  // verbatim Config.Permissions text -- see html/tablet-bridge... no, see this file's DEFAULT_CAPABILITIES for the exact fallback copy this must match
          strings: { <key>: <resolved locale string>, ... },        // see DEFAULT_STRINGS below for the full key list this page understands
          requestedView: 'highCommand'|null,                        // client/tablet.lua's new Config.CommandTablet.highCommandCommand shortcut -- PRESENTATION HINT ONLY. loadMyRecord() consumes this (see its own comment) strictly AFTER tablet:requestMyRecord's server-verified viewer.isHighCommand for THIS caller is known: true lands on the console tab pre-loaded, anything else shows a plain "you don't have access" notice with the caller's own record underneath, exactly as the ordinary command would show them. Never used to skip, gate, or shortcut any fetch above.
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

    /** Floor this page enforces on every tabletAudit* `limit` input,
     * client-side, BEFORE it is ever sent. This is a UX convenience only,
     * same as every other client-side clamp on this page -- ClampLimit
     * server-side is the only real bound regardless of what this page
     * ever sends. */
    var AUDIT_LIMIT_MIN = 1;

    /** FALLBACK ONLY -- explicitly NOT the authoritative ceiling. This used
     * to be treated as if it were server/admin.lua's own HARD_MAX_RESULTS,
     * hardcoded here and "updated by hand if that server-side constant
     * ever changes" -- exactly the two-copies-of-one-number problem this
     * pass exists to close. server/admin.lua's five tabletAudit* callbacks
     * now serve their real, live ceiling back as `cap` on every successful
     * response (see this file's header NUI CONTRACT note on those five
     * bridges, and server/admin.lua's own ClampLimit/CALLBACK SURFACE
     * comments for the authoritative contract) -- auditEffectiveCap()
     * below is what every clamp/UI-hint on this page actually calls, and
     * it prefers that SERVED value the moment any query has ever
     * succeeded. This constant is used ONLY as a last resort: the very
     * first render of a fresh tablet session, before any audit query has
     * run at all, and as a safety net if a response is ever missing `cap`
     * entirely (a server build predating this pass). Deliberately renamed
     * from the old `AUDIT_LIMIT_MAX` (rather than quietly keeping that name
     * while its meaning changed underneath it) so every remaining use is
     * self-evidently a GUESS, never mistaken for the real bound again. */
    var AUDIT_LIMIT_MAX_FALLBACK = 100;

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
        high_command_required_notice: 'You don\'t have High Command access, so here is your own record instead.',
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
        // {requested}/{shown} filled in via formatTemplate() -- see
        // auditTruncatedText() for the exact contract (both are real,
        // server-reported numbers, never a client-side guess). Kept
        // byte-identical to locales/en.json's `tablet.audit_truncated_notice`.
        audit_truncated_notice: 'You asked for {requested} results; the server limit is {shown}, so only the first {shown} are shown.',
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
        // PERMISSION-KEY CATALOG (owner-directed "add or remove permissions"
        // pass, server/permissionkeycatalog.lua) -- see
        // client/tablet.lua's own TABLET_STRING_KEYS comment: NOT YET in
        // locales/en.json (report filed with this pass), same disclosed-gap
        // posture as the tier_label..expired_badge block above.
        tab_permission_keys: 'Permission Keys',
        permission_keys_heading: 'Permission Key Catalog',
        permission_keys_add_label: 'Add Permission Key',
        permission_key_key_label: 'Key',
        permission_key_key_placeholder: 'e.g. k9.custom_ability',
        permission_key_label_label: 'Label',
        permission_key_description_label: 'Description (optional)',
        permission_key_description_placeholder: 'What this permission lets someone do',
        permission_key_save_label: 'Save',
        permission_key_cancel_label: 'Cancel',
        permission_key_edit_label: 'Edit',
        permission_key_delete_label: 'Delete',
        permission_key_default_badge: 'Default',
        permission_key_retired_badge: 'Retired',
        column_description: 'Description',
        permission_key_error_denied: 'You are not authorized to manage the permission-key catalog.',
        permission_key_error_rate_limited: 'Please wait a moment before trying again.',
        permission_key_error_invalid_key: 'Key must be 2-40 lowercase letters, numbers, underscores and dots (e.g. k9.custom_ability).',
        permission_key_error_invalid_label: 'Label must be 1-60 characters with no special markup.',
        permission_key_error_invalid_description: 'Description must be 300 characters or fewer, with no special markup.',
        permission_key_error_reserved_namespace: 'That key name is reserved for per-feature grants and blocks and cannot be used here.',
        permission_key_error_busy: 'Another edit to this key is in progress -- try again in a moment.',
        permission_key_error_too_many_keys: 'The permission-key catalog is full.',
        permission_key_error_unknown_key: 'That permission key does not exist.',
        permission_key_error_db_error: 'A database error occurred. Please try again.',
        permission_key_error_invalid_payload: 'The request was malformed.',
        // XP RANK EDITOR (owner-directed "...set experience level for each
        // rank up" pass, server/xptiers.lua) -- sits alongside the
        // cert-tier/permission-key/shop-location/runtime-control tabs
        // above, same high-command gate, same disclosed-gap posture: NOT
        // YET in locales/en.json's `tablet` group as of this pass (report
        // filed with this pass's own hand-off) -- BuildTabletStrings()'s
        // own pcall-per-key guard in client/tablet.lua simply omits each of
        // these from `strings` until added there, and this block covers
        // that exact gap in the meantime, same resilience-net role every
        // other DEFAULT_STRINGS key already documents.
        tab_xp_tiers: 'XP Ranks',
        xp_tiers_heading: 'XP Rank Editor',
        xp_tiers_empty: 'No XP ranks are configured.',
        column_rank: 'Rank',
        column_xp_threshold: 'XP Threshold',
        column_speed_multiplier: 'Speed Multiplier',
        column_scent_range_multiplier: 'Scent Range Multiplier',
        column_medkit_cooldown_multiplier: 'Medkit Cooldown Multiplier',
        column_badge: 'Badge',
        xp_tier_edit_label: 'Edit',
        xp_tier_save_label: 'Save Rank',
        xp_tier_cancel_label: 'Cancel',
        xp_tier_xp_label: 'XP Threshold',
        xp_tier_xp_locked_hint: 'Rank 1 is the starting rank -- its XP threshold is fixed at 0 and cannot be changed here.',
        xp_tier_label_label: 'Label',
        xp_tier_speed_multiplier_label: 'Speed Multiplier',
        xp_tier_scent_range_multiplier_label: 'Scent Range Multiplier',
        xp_tier_medkit_cooldown_multiplier_label: 'Medkit Cooldown Multiplier (optional)',
        xp_tier_medkit_cooldown_multiplier_placeholder: 'Not configured',
        xp_tier_badge_label: 'Badge (optional)',
        xp_tier_badge_placeholder: 'None',
        xp_tier_error_denied: 'You are not authorized to edit XP ranks.',
        xp_tier_error_rate_limited: 'Please wait a moment before trying again.',
        xp_tier_error_busy: 'Another XP rank edit is in progress -- try again in a moment.',
        xp_tier_error_invalid_ordinal: 'That rank could not be found.',
        xp_tier_error_invalid_xp: 'XP threshold must be a whole number of 0 or more.',
        xp_tier_error_base_tier_xp_fixed: 'Rank 1 must always start at 0 XP -- this field cannot be changed.',
        xp_tier_error_invalid_label: 'Enter a valid label (1-60 characters, no special symbols).',
        xp_tier_error_invalid_speed_multiplier: 'Speed multiplier must be greater than 0 and no more than 3.',
        xp_tier_error_invalid_scent_range_multiplier: 'Scent range multiplier must be greater than 0 and no more than 3.',
        xp_tier_error_invalid_medkit_cooldown_multiplier: 'Medkit cooldown multiplier must be greater than 0 and no more than 1, or left blank.',
        xp_tier_error_invalid_badge: 'Enter a valid badge (up to 30 characters, no special symbols) or leave it blank.',
        xp_tier_error_invalid_order: 'That XP threshold would put this rank out of order with the rank above or below it.',
        xp_tier_error_db_error: 'The rank could not be saved due to a database error. Try again.',
        xp_tier_error_invalid_payload: 'That request was malformed. Try again.',
        // K9 SUPPLY SHOP ITEM CATALOG (this pass, coder-ui,
        // server/equipmentshop.lua's own "EQUIPMENT SHOP ITEM CATALOG"
        // section) -- sits alongside the shop_location_*/tab_shop_locations
        // keys above, same "K9 Supply Shop" domain. SAME disclosed-gap
        // posture as the 'tab_audit'/'tier_label'/'tab_xp_tiers' blocks
        // above: these 44 keys are NOT YET present in locales/en.json's
        // `tablet` group as of this pass -- flagged to that file's owner
        // (see this pass's own report for the exact key -> English-string
        // list). BuildTabletStrings()'s own pcall-per-key guard means each
        // is simply omitted from `strings` until added there, and this
        // very DEFAULT_STRINGS table covers that exact gap in the
        // meantime, same resilience-net role it already documents for
        // every other key.
        tab_shop_items: 'Shop Items',
        shop_items_heading: 'K9 Supply Shop Items',
        shop_items_add_label: 'Add New Item',
        shop_items_empty: 'No shop items configured yet.',
        column_price: 'Price',
        column_currency: 'Currency',
        column_required_tier: 'Required Tier',
        column_required_specialization: 'Required Specialization',
        shop_item_key_label: 'Item Key',
        shop_item_key_placeholder: 'e.g. k9_medkit',
        shop_item_price_label: 'Price',
        shop_item_label_label: 'Display Label',
        shop_item_label_placeholder: "Leave blank to use the item's own name",
        shop_item_currency_label: 'Currency Item',
        shop_item_currency_placeholder: 'Leave blank to use the shop default',
        shop_item_required_tier_label: 'Required Certification Tier',
        shop_item_required_specialization_label: 'Required Specialization',
        shop_item_no_requirement: 'None',
        shop_item_retired_reference_badge: '(retired)',
        shop_item_save_label: 'Save Item',
        shop_item_cancel_label: 'Cancel',
        shop_item_edit_label: 'Edit',
        shop_item_delete_label: 'Delete',
        shop_item_move_up_label: '↑',
        shop_item_move_up_title: 'Move up (earlier in the shop)',
        shop_item_move_down_label: '↓',
        shop_item_move_down_title: 'Move down (later in the shop)',
        shop_item_price_free_badge: 'Free',
        shop_item_currency_default_note: 'Shop default',
        shop_item_error_denied: 'You are not authorized to manage the K9 Supply Shop item catalog.',
        shop_item_error_rate_limited: 'Please wait a moment before trying again.',
        shop_item_error_invalid_payload: 'That request was malformed. Try again.',
        shop_item_error_invalid_key: 'That item key is invalid -- use 1-50 lowercase letters, numbers, or underscores, starting with a letter.',
        shop_item_error_invalid_price: 'That price is invalid -- enter a whole number from 0 up to 1,000,000,000. Zero is allowed for a free item.',
        shop_item_error_invalid_label: 'That label is invalid or too long (max 60 characters, no special markup characters).',
        shop_item_error_invalid_currency: 'That currency item key is invalid -- use 1-50 lowercase letters, numbers, or underscores, starting with a letter.',
        shop_item_error_invalid_required_tier: 'That required certification tier does not exist.',
        shop_item_error_invalid_required_specialization: 'That required specialization does not exist.',
        shop_item_error_busy: 'This item is being edited elsewhere right now -- try again in a moment.',
        shop_item_error_too_many_items: 'The maximum number of shop items has been reached.',
        shop_item_error_unknown_item: 'That item no longer exists in the catalog.',
        shop_item_error_must_include_every_item: 'The new order must include every existing item, with none missing or duplicated.',
        shop_item_error_invalid_key_set: 'The new order must include every existing item, with none missing or duplicated.',
        shop_item_error_db_error: 'A database error occurred. Try again.',

        // ---- HOME / LANDING VIEW (this pass, owner-directed "restructure
        // the tablet around WHO IS HOLDING IT... a first-time player who
        // has read nothing should open this and know what to do within
        // seconds"). See buildHomeScreen() below for the full writeup --
        // this is now the DEFAULT screen on open, ahead of every existing
        // tab; nothing below removes or renames an existing screen.
        tab_home: 'Home',
        home_welcome_template: 'Welcome, {name}.',
        home_role_high_command: 'High Command',
        home_role_k9: 'K9',
        home_role_handler: 'Certified Handler',
        home_role_uncertified: 'New Arrival',
        home_partnered_badge: 'Partnered',
        home_not_partnered_badge: 'No Partner',
        home_certified_count_template: 'Certified in {count} of {total} departments',
        home_quick_actions_heading: 'What do you want to do?',
        home_view_my_record_label: 'View My Record',
        home_view_my_record_hint: 'Your certifications, XP, and the abilities you can use right now.',
        home_open_console_label: 'Open Command Console',
        home_open_console_hint: 'Look up and manage handlers and K9s.',
        home_high_command_heading: 'High Command Tools',
        home_high_command_hint: 'Server-wide settings: theming, certification tiers, permission keys, the supply shop, runtime switches, XP ranks, and the audit trail.',
        home_no_certification_title: "You're not certified yet",
        home_no_certification_body: 'Ask a certifier or a High Command officer to certify you in a department. Once certified, your abilities and record will appear here.',
        home_ready_abilities_heading: 'Ready to use right now',
        home_no_ready_abilities: 'Nothing is ready to use right now.',
        home_view_all_abilities_label: 'View all abilities',
        home_blocked_count_template: '{count} of your abilities are currently blocked',

        // ---- COMMAND REFERENCE (this pass -- "36 commands, no way for a
        // player to discover them in-game"). See COMMAND_REFERENCE/
        // buildCommandReferenceScreen() below for the full design. Every
        // one of these keys is NOT YET present in locales/en.json's
        // `tablet` group as of this pass -- flagged to that file's owner
        // (see this pass's own report for the exact key -> English-string
        // list). BuildTabletStrings()'s own pcall-per-key guard means each
        // is simply omitted from `strings` until added there, and this
        // DEFAULT_STRINGS table covers that exact gap in the meantime,
        // same resilience-net role it already plays for every other key.
        tab_commands: 'Commands',
        cmdref_heading: 'Command Reference',
        cmdref_intro: 'Every command this resource registers, grouped by what you are trying to do. A command you cannot currently use is marked, with the reason why -- the server still decides what actually works; this list only tells you the truth about it.',
        cmdref_search_placeholder: 'Search commands...',
        cmdref_empty: 'No commands match your search.',
        cmdref_column_command: 'Command',
        cmdref_column_does: 'What It Does',
        cmdref_column_needs: 'What It Needs',
        cmdref_admin_badge: 'Admin',
        cmdref_status_insufficient_authorization: 'Requires higher authorization',

        cmdref_category_field_gear: 'Field Gear & Equipment',
        cmdref_category_calling_off: 'Calling Your K9 Off',
        cmdref_category_scent_games: 'Scent Games',
        cmdref_category_search_rescue: 'Search & Rescue',
        cmdref_category_training: 'Training',
        cmdref_category_records: 'Records & Progress',
        cmdref_category_certification: 'Certification Management',
        cmdref_category_xp: 'XP Management',
        cmdref_category_audit: 'Audit & Oversight',
        cmdref_category_devtools: 'Developer Tools',
        cmdref_category_permissions: 'Permission Management',

        cmdref_k9deploykennel_usage: '/k9deploykennel',
        cmdref_k9deploykennel_does: 'Places a portable kennel at your feet.',
        cmdref_k9deploykennel_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server.',
        cmdref_k9propattach_usage: '/k9propattach',
        cmdref_k9propattach_does: 'Attaches or removes a prop (for example a vest) on your K9.',
        cmdref_k9propattach_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server.',
        cmdref_k9throwfetchball_usage: '/k9throwfetchball',
        cmdref_k9throwfetchball_does: 'Throws a fetch ball for your K9 to chase.',
        cmdref_k9throwfetchball_needs: 'An active K9 certification. Only one ball may be in play for you at a time. This feature must be turned on for your server.',
        cmdref_k9dropfetchball_usage: '/k9dropfetchball',
        cmdref_k9dropfetchball_does: 'Drops the fetch ball you are currently carrying.',
        cmdref_k9dropfetchball_needs: 'Nothing -- always available while you are carrying a ball, so you can never get stuck holding one.',
        cmdref_k9recallfetchball_usage: '/k9recallfetchball',
        cmdref_k9recallfetchball_does: 'Cancels your own fetch throw in progress.',
        cmdref_k9recallfetchball_needs: 'Nothing -- always available, so a throw can always be called off.',

        cmdref_k9recall_usage: '/k9recall',
        cmdref_k9recall_does: 'Calls your K9 partner back from whatever it is doing (a bite hold, a takedown, a drag).',
        cmdref_k9recall_needs: 'Nothing. This is deliberately never blocked, so you can always call your own K9 off. This feature must be turned on for your server.',
        cmdref_k9calmdown_usage: '/k9calmdown',
        cmdref_k9calmdown_does: 'Calms your K9 down, reducing fear and stress.',
        cmdref_k9calmdown_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server.',
        cmdref_k9meatbait_usage: '/k9meatbait',
        cmdref_k9meatbait_does: 'Uses meat bait to distract any K9 nearby, yours or someone else\'s.',
        cmdref_k9meatbait_needs: 'You must be holding the item this server has configured for meat bait. Open to any player, not just certified handlers. This feature must be turned on for your server.',
        cmdref_k9whistle_usage: '/k9whistle',
        cmdref_k9whistle_does: 'Uses a whistle to distract any K9 nearby.',
        cmdref_k9whistle_needs: 'You must be holding the item this server has configured for a whistle. Open to any player, not just certified handlers. This feature must be turned on for your server.',

        cmdref_k9lineup_usage: '/k9lineup <server id> <server id> ...',
        cmdref_k9lineup_does: 'Starts a scent line-up: invites several players to stand in a row so your K9 can pick the one real match out of them.',
        cmdref_k9lineup_needs: 'An active K9 certification, and, on some servers, a specific grant for this feature. Needs at least the server\'s configured minimum number of participants. This feature must be turned on for your server.',
        cmdref_k9lineuppick_usage: '/k9lineuppick <position number>',
        cmdref_k9lineuppick_does: 'Makes your K9\'s one guess, once everyone invited has accepted.',
        cmdref_k9lineuppick_needs: 'You must already be running a locked line-up (started with /k9lineup).',
        cmdref_k9lineupcancel_usage: '/k9lineupcancel',
        cmdref_k9lineupcancel_does: 'Leaves or cancels your current scent line-up, whether you started it or were invited.',
        cmdref_k9lineupcancel_needs: 'Nothing -- always available, so nobody is ever stuck in a line-up.',
        cmdref_k9nosehunt_usage: '/k9nosehunt [stop]',
        cmdref_k9nosehunt_does: 'Starts a scent-trail hunt for your K9 (a follow-the-growl guessing game, no marker). Add "stop" to abandon a hunt already running.',
        cmdref_k9nosehunt_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server. ("stop" is always available.)',

        cmdref_k9sarcall_usage: '/k9sarcall [stop]',
        cmdref_k9sarcall_does: 'Starts a search-and-rescue call for your K9 to work (a missing person or lost property). Add "stop" to abandon a call already running.',
        cmdref_k9sarcall_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server. ("stop" is always available.)',

        cmdref_k9training_usage: '/k9training <on|off>',
        cmdref_k9training_does: 'Turns Training Mode on or off, for practice drills.',
        cmdref_k9training_needs: 'An active K9 certification, you must currently be controlling your K9, and you must be standing in one of this server\'s configured training areas.',
        cmdref_k9trainsearch_usage: '/k9trainsearch',
        cmdref_k9trainsearch_does: 'Runs a practice search drill (no real consequences, just reps).',
        cmdref_k9trainsearch_needs: 'Training Mode must already be switched on for you (see /k9training).',
        cmdref_k9trainbite_usage: '/k9trainbite',
        cmdref_k9trainbite_does: 'Runs a practice bite-hold drill.',
        cmdref_k9trainbite_needs: 'Training Mode must already be switched on for you (see /k9training).',

        cmdref_k9stats_usage: '/k9stats [limit]',
        cmdref_k9stats_does: 'Shows the server\'s K9 XP leaderboard.',
        cmdref_k9stats_needs: 'An active K9 certification. This feature must be turned on for your server.',

        cmdref_k9certify_usage: '/k9certify <server id>',
        cmdref_k9certify_does: 'Certifies a currently-online player as a K9 handler for their current department.',
        cmdref_k9certify_needs: 'High Command, the certify permission, or your department\'s certifier rank. The target must be online, in a configured department, and within certifying distance (unless you are certifying yourself and self-certification is allowed).',
        cmdref_k9certifyoffline_usage: '/k9certifyoffline <citizenid> <job>',
        cmdref_k9certifyoffline_does: 'Same as /k9certify, but for a player who is currently offline.',
        cmdref_k9certifyoffline_needs: 'Same as /k9certify. Refuses if that person is actually online right now (use /k9certify instead), and refuses if your server requires an on-model check, since that can only happen while they are online.',
        cmdref_k9decertify_usage: '/k9decertify <server id> [reason]',
        cmdref_k9decertify_does: 'Revokes an online player\'s current department certification.',
        cmdref_k9decertify_needs: 'Same as /k9certify. Proximity is required unless you are revoking your own.',
        cmdref_k9decertifyoffline_usage: '/k9decertifyoffline <citizenid> <job> [reason]',
        cmdref_k9decertifyoffline_does: 'Same as /k9decertify, but for an offline citizen.',
        cmdref_k9decertifyoffline_needs: 'Same as /k9certify. Refuses if that person is actually online right now.',
        cmdref_k9settier_usage: '/k9settier <server id> <tier>',
        cmdref_k9settier_does: 'Changes an online, actively-certified handler\'s certification tier.',
        cmdref_k9settier_needs: 'Same as /k9certify. The target must already hold an active certification.',
        cmdref_k9settieroffline_usage: '/k9settieroffline <citizenid> <job> <tier>',
        cmdref_k9settieroffline_does: 'Same as /k9settier, but for an offline citizen.',
        cmdref_k9settieroffline_needs: 'Same as /k9settier. Refuses if that person is actually online right now.',
        cmdref_k9recertify_usage: '/k9recertify <server id>',
        cmdref_k9recertify_does: 'Renews (extends) an online handler\'s certification expiry.',
        cmdref_k9recertify_needs: 'Same as /k9certify. Only does anything if this server has certification expiry turned on, and the target holds an active certification.',
        cmdref_k9recertifyoffline_usage: '/k9recertifyoffline <citizenid> <job>',
        cmdref_k9recertifyoffline_does: 'Same as /k9recertify, but for an offline citizen.',
        cmdref_k9recertifyoffline_needs: 'Same as /k9recertify. Refuses if that person is actually online right now.',
        cmdref_k9specialize_usage: '/k9specialize <server id> <specialization>',
        cmdref_k9specialize_does: 'Grants an online, actively-certified handler a specialization.',
        cmdref_k9specialize_needs: 'Same as /k9certify. The target\'s certification tier must be allowed to hold specializations. There is no offline version of this command -- granting a specialization always requires the target to be online.',
        cmdref_k9unspecialize_usage: '/k9unspecialize <server id> <specialization>',
        cmdref_k9unspecialize_does: 'Revokes an online handler\'s specialization.',
        cmdref_k9unspecialize_needs: 'Same as /k9certify.',
        cmdref_k9unspecializeoffline_usage: '/k9unspecializeoffline <citizenid> <job> <specialization>',
        cmdref_k9unspecializeoffline_does: 'Same as /k9unspecialize, but for an offline citizen.',
        cmdref_k9unspecializeoffline_needs: 'Same as /k9certify. Refuses if that person is actually online right now.',

        cmdref_k9givexp_usage: '/k9givexp <server id> <amount>',
        cmdref_k9givexp_does: 'Awards XP directly to an online player.',
        cmdref_k9givexp_needs: 'High Command or the grant-XP permission. The amount is capped by this server\'s configured maximum per grant, and repeated use is rate-limited.',

        cmdref_k9auditcert_usage: '/k9auditcert <citizenid> [limit]',
        cmdref_k9auditcert_does: 'Looks up a citizen\'s certification history (grants and revokes).',
        cmdref_k9auditcert_needs: 'High Command, the audit permission, or your department\'s audit rank. The Audit Trail feature must be turned on for your server.',
        cmdref_k9auditpartner_usage: '/k9auditpartner <citizenid> [limit]',
        cmdref_k9auditpartner_does: 'Looks up a citizen\'s K9 partnership history.',
        cmdref_k9auditpartner_needs: 'Same as /k9auditcert.',
        cmdref_k9auditsearch_usage: '/k9auditsearch <officer|plate|person|recent> [value] [limit]',
        cmdref_k9auditsearch_does: 'Looks up search-log entries by officer, by plate, by the person searched, or the most recent overall.',
        cmdref_k9auditsearch_needs: 'Same as /k9auditcert.',
        cmdref_k9auditxp_usage: '/k9auditxp <citizenid>',
        cmdref_k9auditxp_does: 'Looks up a citizen\'s XP/progression snapshot.',
        cmdref_k9auditxp_needs: 'Same as /k9auditcert.',
        cmdref_k9auditdept_usage: '/k9auditdept <job> [limit]',
        cmdref_k9auditdept_does: 'Lists everyone currently certified in a department.',
        cmdref_k9auditdept_needs: 'Same as /k9auditcert.',

        cmdref_k9bonetool_usage: '/k9bonetool <goto|next|prev|test|stop|known|help> [value]',
        cmdref_k9bonetool_does: 'Developer tool for sweeping through a test prop\'s skeleton bones, to find the right one for attaching a leash, vest, or prop.',
        cmdref_k9bonetool_needs: 'Your department\'s boss rank or High Command, AND a server operator must have explicitly turned this dev tool on -- it is off by default, and unsafe to leave on in production.',

        cmdref_k9grantpermission_usage: '/k9grantpermission <citizenid> <permissionKey>',
        cmdref_k9grantpermission_does: 'Grants a named permission key (a capability like certifying others, or a specific feature/block override) directly to a citizen.',
        cmdref_k9grantpermission_needs: 'High Command only. This feature must be turned on for your server. You cannot grant a permission to yourself.',
        cmdref_k9revokepermission_usage: '/k9revokepermission <citizenid> <permissionKey>',
        cmdref_k9revokepermission_does: 'Revokes a previously-granted permission key from a citizen.',
        cmdref_k9revokepermission_needs: 'High Command only. This feature must be turned on for your server.',
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
    // COMMAND REFERENCE (this pass) -- "the resource registers 36
    // commands, a player has no way to discover them in-game". This is
    // the single, HAND-MAINTAINED catalog that screen renders from --
    // see buildCommandReferenceScreen() below for the UI itself.
    //
    // DRIFT GUARD, NOT A PROMISE THIS NEVER ROTS BY ITSELF: nothing on
    // this page derives COMMAND_REFERENCE from the real RegisterCommand
    // calls (there is no shared runtime registry the commands themselves
    // feed -- they are plain `RegisterCommand('k9x', ...)` calls scattered
    // across 19 server/client files with nothing to introspect from a
    // browser sandbox). What keeps this list honest instead is
    // tests/commandreferenceregistry_spec.lua: it greps the REAL
    // server/*.lua + client/*.lua source for every literal
    // `RegisterCommand('...')` name (the exact
    // `RegisterCommand\('[a-z0-9_]+'` shape this task was scoped from) and
    // fails LOUDLY, naming the exact command, if that set and this
    // catalog's own `command` field set ever diverge in EITHER direction
    // -- a command added here with no real RegisterCommand behind it, or a
    // real command with no entry here. Add command #37 to this array in
    // the SAME change that registers it, or that spec turns red.
    //
    // Each entry:
    //   command    string   -- the exact RegisterCommand name, e.g. 'k9auditcert'
    //   category   string   -- a COMMAND_REFERENCE_CATEGORIES key, grouping by
    //                          WHAT THE PLAYER IS TRYING TO DO, never by which
    //                          file registers it
    //   adminOnly  boolean  -- true for a command whose real gate is a
    //                          rank/permission/High-Command check rather than
    //                          "any certified handler" -- rendered with the
    //                          (Admin) badge for EVERY viewer, high command
    //                          included, per this task's own "high command
    //                          sees everything, with the admin ones marked as
    //                          such" instruction
    //   usageKey/doesKey/needsKey  string -- DEFAULT_STRINGS/locales keys for
    //                          the argument shape, the one-line plain-English
    //                          description, and the plain-English requirement
    //                          text, respectively
    //   gate       object   -- see commandReferenceStatus() below for exactly
    //                          how each `kind` is resolved; NEVER an
    //                          enforcement decision, only this screen's own
    //                          best-effort, honest-when-uncertain PRESENTATION
    //                          of what the server would decide -- the server
    //                          re-checks everything independently regardless
    //                          of what this badge says (THE SECURITY RULE).
    // ------------------------------------------------------------------
    var COMMAND_REFERENCE_CATEGORIES = [
        { key: 'field_gear', labelKey: 'cmdref_category_field_gear' },
        { key: 'calling_off', labelKey: 'cmdref_category_calling_off' },
        { key: 'scent_games', labelKey: 'cmdref_category_scent_games' },
        { key: 'search_rescue', labelKey: 'cmdref_category_search_rescue' },
        { key: 'training', labelKey: 'cmdref_category_training' },
        { key: 'records', labelKey: 'cmdref_category_records' },
        { key: 'certification', labelKey: 'cmdref_category_certification' },
        { key: 'xp', labelKey: 'cmdref_category_xp' },
        { key: 'audit', labelKey: 'cmdref_category_audit' },
        { key: 'devtools', labelKey: 'cmdref_category_devtools' },
        { key: 'permissions', labelKey: 'cmdref_category_permissions' },
    ];

    var COMMAND_REFERENCE = [
        // ---- Field Gear & Equipment ----
        { command: 'k9deploykennel', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9deploykennel_usage', doesKey: 'cmdref_k9deploykennel_does', needsKey: 'cmdref_k9deploykennel_needs', gate: { kind: 'access', featureKey: 'DeployableKennel' } },
        { command: 'k9propattach', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9propattach_usage', doesKey: 'cmdref_k9propattach_does', needsKey: 'cmdref_k9propattach_needs', gate: { kind: 'access', featureKey: 'PropAttachments' } },
        { command: 'k9throwfetchball', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9throwfetchball_usage', doesKey: 'cmdref_k9throwfetchball_does', needsKey: 'cmdref_k9throwfetchball_needs', gate: { kind: 'access', featureKey: 'FetchMechanic' } },
        { command: 'k9dropfetchball', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9dropfetchball_usage', doesKey: 'cmdref_k9dropfetchball_does', needsKey: 'cmdref_k9dropfetchball_needs', gate: { kind: 'open' } },
        { command: 'k9recallfetchball', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9recallfetchball_usage', doesKey: 'cmdref_k9recallfetchball_does', needsKey: 'cmdref_k9recallfetchball_needs', gate: { kind: 'open' } },

        // ---- Calling Your K9 Off ----
        { command: 'k9recall', category: 'calling_off', adminOnly: false, usageKey: 'cmdref_k9recall_usage', doesKey: 'cmdref_k9recall_does', needsKey: 'cmdref_k9recall_needs', gate: { kind: 'open', featureKey: 'Recall' } },
        { command: 'k9calmdown', category: 'calling_off', adminOnly: false, usageKey: 'cmdref_k9calmdown_usage', doesKey: 'cmdref_k9calmdown_does', needsKey: 'cmdref_k9calmdown_needs', gate: { kind: 'access', featureKey: 'FearStressSystem' } },
        { command: 'k9meatbait', category: 'calling_off', adminOnly: false, usageKey: 'cmdref_k9meatbait_usage', doesKey: 'cmdref_k9meatbait_does', needsKey: 'cmdref_k9meatbait_needs', gate: { kind: 'open', featureKey: 'DistractionSystem' } },
        { command: 'k9whistle', category: 'calling_off', adminOnly: false, usageKey: 'cmdref_k9whistle_usage', doesKey: 'cmdref_k9whistle_does', needsKey: 'cmdref_k9whistle_needs', gate: { kind: 'open', featureKey: 'DistractionSystem' } },

        // ---- Scent Games ----
        { command: 'k9lineup', category: 'scent_games', adminOnly: false, usageKey: 'cmdref_k9lineup_usage', doesKey: 'cmdref_k9lineup_does', needsKey: 'cmdref_k9lineup_needs', gate: { kind: 'access', featureKey: 'ScentLineup' } },
        { command: 'k9lineuppick', category: 'scent_games', adminOnly: false, usageKey: 'cmdref_k9lineuppick_usage', doesKey: 'cmdref_k9lineuppick_does', needsKey: 'cmdref_k9lineuppick_needs', gate: { kind: 'open' } },
        { command: 'k9lineupcancel', category: 'scent_games', adminOnly: false, usageKey: 'cmdref_k9lineupcancel_usage', doesKey: 'cmdref_k9lineupcancel_does', needsKey: 'cmdref_k9lineupcancel_needs', gate: { kind: 'open' } },
        { command: 'k9nosehunt', category: 'scent_games', adminOnly: false, usageKey: 'cmdref_k9nosehunt_usage', doesKey: 'cmdref_k9nosehunt_does', needsKey: 'cmdref_k9nosehunt_needs', gate: { kind: 'access', featureKey: 'ScentTrailHunt' } },

        // ---- Search & Rescue ----
        { command: 'k9sarcall', category: 'search_rescue', adminOnly: false, usageKey: 'cmdref_k9sarcall_usage', doesKey: 'cmdref_k9sarcall_does', needsKey: 'cmdref_k9sarcall_needs', gate: { kind: 'access', featureKey: 'SARCalls' } },

        // ---- Training ----
        { command: 'k9training', category: 'training', adminOnly: false, usageKey: 'cmdref_k9training_usage', doesKey: 'cmdref_k9training_does', needsKey: 'cmdref_k9training_needs', gate: { kind: 'access', featureKey: 'TrainingMode' } },
        { command: 'k9trainsearch', category: 'training', adminOnly: false, usageKey: 'cmdref_k9trainsearch_usage', doesKey: 'cmdref_k9trainsearch_does', needsKey: 'cmdref_k9trainsearch_needs', gate: { kind: 'access', featureKey: 'TrainingMode' } },
        { command: 'k9trainbite', category: 'training', adminOnly: false, usageKey: 'cmdref_k9trainbite_usage', doesKey: 'cmdref_k9trainbite_does', needsKey: 'cmdref_k9trainbite_needs', gate: { kind: 'access', featureKey: 'TrainingMode' } },

        // ---- Records & Progress ----
        { command: 'k9stats', category: 'records', adminOnly: false, usageKey: 'cmdref_k9stats_usage', doesKey: 'cmdref_k9stats_does', needsKey: 'cmdref_k9stats_needs', gate: { kind: 'access', featureKey: 'K9Leaderboard' } },

        // ---- Certification Management (admin) ----
        { command: 'k9certify', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9certify_usage', doesKey: 'cmdref_k9certify_does', needsKey: 'cmdref_k9certify_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9certifyoffline', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9certifyoffline_usage', doesKey: 'cmdref_k9certifyoffline_does', needsKey: 'cmdref_k9certifyoffline_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9decertify', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9decertify_usage', doesKey: 'cmdref_k9decertify_does', needsKey: 'cmdref_k9decertify_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9decertifyoffline', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9decertifyoffline_usage', doesKey: 'cmdref_k9decertifyoffline_does', needsKey: 'cmdref_k9decertifyoffline_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9settier', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9settier_usage', doesKey: 'cmdref_k9settier_does', needsKey: 'cmdref_k9settier_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9settieroffline', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9settieroffline_usage', doesKey: 'cmdref_k9settieroffline_does', needsKey: 'cmdref_k9settieroffline_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9recertify', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9recertify_usage', doesKey: 'cmdref_k9recertify_does', needsKey: 'cmdref_k9recertify_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9recertifyoffline', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9recertifyoffline_usage', doesKey: 'cmdref_k9recertifyoffline_does', needsKey: 'cmdref_k9recertifyoffline_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9specialize', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9specialize_usage', doesKey: 'cmdref_k9specialize_does', needsKey: 'cmdref_k9specialize_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9unspecialize', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9unspecialize_usage', doesKey: 'cmdref_k9unspecialize_does', needsKey: 'cmdref_k9unspecialize_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9unspecializeoffline', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9unspecializeoffline_usage', doesKey: 'cmdref_k9unspecializeoffline_does', needsKey: 'cmdref_k9unspecializeoffline_needs', gate: { kind: 'capability', capability: 'k9.certify' } },

        // ---- XP Management (admin) ----
        { command: 'k9givexp', category: 'xp', adminOnly: true, usageKey: 'cmdref_k9givexp_usage', doesKey: 'cmdref_k9givexp_does', needsKey: 'cmdref_k9givexp_needs', gate: { kind: 'capability', capability: 'k9.givexp' } },

        // ---- Audit & Oversight (admin) ----
        { command: 'k9auditcert', category: 'audit', adminOnly: true, usageKey: 'cmdref_k9auditcert_usage', doesKey: 'cmdref_k9auditcert_does', needsKey: 'cmdref_k9auditcert_needs', gate: { kind: 'capability', capability: 'k9.audit', featureKey: 'AdminAuditCommands' } },
        { command: 'k9auditpartner', category: 'audit', adminOnly: true, usageKey: 'cmdref_k9auditpartner_usage', doesKey: 'cmdref_k9auditpartner_does', needsKey: 'cmdref_k9auditpartner_needs', gate: { kind: 'capability', capability: 'k9.audit', featureKey: 'AdminAuditCommands' } },
        { command: 'k9auditsearch', category: 'audit', adminOnly: true, usageKey: 'cmdref_k9auditsearch_usage', doesKey: 'cmdref_k9auditsearch_does', needsKey: 'cmdref_k9auditsearch_needs', gate: { kind: 'capability', capability: 'k9.audit', featureKey: 'AdminAuditCommands' } },
        { command: 'k9auditxp', category: 'audit', adminOnly: true, usageKey: 'cmdref_k9auditxp_usage', doesKey: 'cmdref_k9auditxp_does', needsKey: 'cmdref_k9auditxp_needs', gate: { kind: 'capability', capability: 'k9.audit', featureKey: 'AdminAuditCommands' } },
        { command: 'k9auditdept', category: 'audit', adminOnly: true, usageKey: 'cmdref_k9auditdept_usage', doesKey: 'cmdref_k9auditdept_does', needsKey: 'cmdref_k9auditdept_needs', gate: { kind: 'capability', capability: 'k9.audit', featureKey: 'AdminAuditCommands' } },

        // ---- Developer Tools (admin) ----
        { command: 'k9bonetool', category: 'devtools', adminOnly: true, usageKey: 'cmdref_k9bonetool_usage', doesKey: 'cmdref_k9bonetool_does', needsKey: 'cmdref_k9bonetool_needs', gate: { kind: 'highCommandOnly', featureKey: 'BoneSweepDevTool' } },

        // ---- Permission Management (admin) -- server/permissions.lua's
        // console/chat "CONSOLE/CHAT COMMAND GRANT PATH" section: the same
        // authorization tablet:grantPermission/tablet:revokePermission
        // already require (IsHighCommand ONLY -- no rank/permission-grant
        // bypass, unlike certification's IsEligibleCertifier), reachable
        // without the tablet too.
        { command: 'k9grantpermission', category: 'permissions', adminOnly: true, usageKey: 'cmdref_k9grantpermission_usage', doesKey: 'cmdref_k9grantpermission_does', needsKey: 'cmdref_k9grantpermission_needs', gate: { kind: 'highCommandOnly', featureKey: 'PermissionGrants' } },
        { command: 'k9revokepermission', category: 'permissions', adminOnly: true, usageKey: 'cmdref_k9revokepermission_usage', doesKey: 'cmdref_k9revokepermission_does', needsKey: 'cmdref_k9revokepermission_needs', gate: { kind: 'highCommandOnly', featureKey: 'PermissionGrants' } },
    ];

    /**
     * Best-effort, HONEST-WHEN-UNCERTAIN availability for one COMMAND_REFERENCE
     * entry's `gate`, from data this page ALREADY has (state.viewer,
     * state.myRecord.myFeatures) -- no new NUI callback, no new round trip.
     * NEVER an enforcement decision (THE SECURITY RULE) -- the server
     * independently re-checks everything this predicts, on every real
     * command/callback, regardless of what this returns.
     *
     * Gate kinds, and exactly what each reuses:
     *   'open'       -- no personal certification/permission gate at all in
     *                   the real command (k9dropfetchball, k9lineupcancel,
     *                   etc.) -- always 'available' UNLESS an optional
     *                   `featureKey` names a Config.Features key that is
     *                   globally off (state.myRecord.myFeatures[key].state
     *                   === 'global_off'), the one signal that check is
     *                   accurate for REGARDLESS of this viewer's own
     *                   certification/block status (server/tablet.lua's
     *                   ResolveFeatureState checks Config.Features[key]
     *                   FIRST, before anything person-specific).
     *   'access'     -- the real command requires HasK9Access() (an active
     *                   certification) -- checked via 'k9.access' in
     *                   viewer.effectivePermissions (server/tablet.lua's own
     *                   ResolveEffectivePermissions resolves that key from
     *                   the exact same HasK9Access(source) the real command
     *                   calls). `featureKey` here is REQUIRED and its
     *                   resolved `state` is trusted AS-IS: every command
     *                   using this gate kind (verified by direct read of
     *                   each one's own server handler, not assumed from its
     *                   feature's general purpose) checks Config.Features[key]
     *                   AND a per-person block/RequireGrant AND HasK9Access,
     *                   in the SAME order ResolveFeatureState resolves them,
     *                   so its `state` field is a byte-accurate proxy.
     *   'capability' -- the real command's gate is IsEligibleCertifier-style
     *                   (job.isboss OR a named HasPermission grant OR
     *                   IsHighCommand OR a department rank threshold) rather
     *                   than "any certified handler" -- checked via
     *                   viewer.isHighCommand OR that exact capability key in
     *                   viewer.effectivePermissions (server/tablet.lua's own
     *                   ResolveEffectivePermissions resolves 'k9.certify'/
     *                   'k9.audit'/'k9.givexp' through the SAME
     *                   MeetsDepartmentRank/HasPermission/IsHighCommand calls
     *                   each real command's own eligibility function uses --
     *                   verified by direct read of each, not assumed). An
     *                   optional `featureKey` is used ONLY for its
     *                   'global_off'/'blocked' states (both resolved BEFORE
     *                   ResolveFeatureState's own HasK9Access branch, so
     *                   accurate regardless of whether THIS viewer happens to
     *                   hold a K9 certification too, which the real gate for
     *                   these commands never asks about) -- its
     *                   'not_certified'/'requires_grant_missing'/'available'
     *                   states are NOT trusted here for that same reason (see
     *                   COMMAND_REFERENCE's own header). A KNOWN, DISCLOSED
     *                   GAP: if this viewer both holds the capability AND is
     *                   personally missing a configured feature.<Name> grant
     *                   AND does not otherwise hold an active K9
     *                   certification, this can under-rarely show 'available'
     *                   for what the server would actually refuse as
     *                   'requires_grant_missing' -- narrow, disclosed, and
     *                   never the OTHER direction (never claims available for
     *                   someone who lacks the capability at all).
     *   'highCommandOnly' -- same as 'capability' but for a real gate this
     *                   page has no direct capability-key proxy for
     *                   (k9bonetool's job.isboss-or-IsHighCommand, with no
     *                   matching entry in AdminCapabilityCandidateKeys) --
     *                   deliberately checks viewer.isHighCommand ONLY, a
     *                   CONSERVATIVE under-approximation: a department boss
     *                   who is not ALSO high command may see this marked
     *                   unavailable even though the real command would allow
     *                   them. Disclosed here rather than silently guessed at,
     *                   and safe in the direction that matters (never
     *                   over-promises).
     * @param {{kind:string, capability?:string, featureKey?:string}} gate
     * @returns {string} one of 'available'|'blocked'|'global_off'|'not_certified'|'requires_grant_missing'|'insufficient_authorization'
     */
    function commandReferenceStatus(gate) {
        var viewer = state.viewer || {};
        var effectivePermissions = Array.isArray(viewer.effectivePermissions) ? viewer.effectivePermissions : [];
        var hasAccess = effectivePermissions.indexOf('k9.access') !== -1;

        function myFeatureState(key) {
            var list = (state.myRecord && Array.isArray(state.myRecord.myFeatures)) ? state.myRecord.myFeatures : [];
            for (var i = 0; i < list.length; i++) {
                if (list[i] && list[i].key === key) return list[i].state;
            }
            return null;
        }

        if (gate.kind === 'open') {
            if (gate.featureKey && myFeatureState(gate.featureKey) === 'global_off') return 'global_off';
            return 'available';
        }

        if (gate.kind === 'access') {
            if (!hasAccess) return 'not_certified';
            var accessState = gate.featureKey ? myFeatureState(gate.featureKey) : null;
            return accessState || 'available';
        }

        if (gate.kind === 'capability' || gate.kind === 'highCommandOnly') {
            var hasCapability = viewer.isHighCommand === true
                || (gate.kind === 'capability' && effectivePermissions.indexOf(gate.capability) !== -1);
            var gatedFeatureState = gate.featureKey ? myFeatureState(gate.featureKey) : null;
            if (gatedFeatureState === 'global_off') return 'global_off';
            if (gatedFeatureState === 'blocked') return 'blocked';
            if (!hasCapability) return 'insufficient_authorization';
            if (gatedFeatureState === 'requires_grant_missing') return 'requires_grant_missing';
            return 'available';
        }

        return 'available';
    }

    /** @param {string} status @returns {string} localized badge text -- reuses
     * featureStateLabel()'s own four real strings for the states that are
     * genuinely the same concept, and one new key for the one status
     * featureStateLabel() has no honest word for ('insufficient_authorization'
     * -- a rank/permission/High-Command gate, not a certification one; see
     * commandReferenceStatus()'s own doc comment for why these are kept
     * distinct rather than reusing 'state_not_certified', which would be
     * simply WRONG for e.g. /k9auditcert). */
    function commandReferenceStatusLabel(status) {
        if (status === 'insufficient_authorization') return S('cmdref_status_insufficient_authorization');
        return featureStateLabel(status);
    }

    /** @param {string} status @returns {string} CSS class SUFFIX -- reuses the
     * existing `.k9tablet-feature-state--*` palette (available=green,
     * blocked=red, global_off/not_certified/requires_grant_missing=amber)
     * with ZERO new CSS: 'insufficient_authorization' maps onto the SAME
     * amber "you don't currently hold what this needs" bucket as
     * 'requires_grant_missing' -- visually identical concern, distinguished
     * only by its own, more precise label text above. */
    function commandReferenceStatusClass(status) {
        if (status === 'insufficient_authorization') return 'requires_grant_missing';
        return status;
    }

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
        screen: 'home', // 'home' | 'my_record' | 'console' | 'person' | 'theme' | 'cert_tiers' | 'shop_locations' | 'runtime_control' | 'xp_tiers' | ... -- 'home' is the DEFAULT landing view (see buildHomeScreen()), reset on every open in handleOpen()
        strings: {},
        // Standalone block-enforcement badge/hint text -- see
        // clientEnforcedBadgeText()/clientEnforcedHintText()'s own doc
        // comment for why these two are NOT part of `strings` above.
        blockClientEnforcedBadge: null,
        blockClientEnforcedHint: null,
        capabilities: {},
        maxXpPerGrant: null,
        peds: [], // Config.Peds, verbatim -- see tablet:assignK9Role's own NUI contract note; display list only, server re-validates the chosen model regardless
        specializations: {}, // Config.K9Specializations, verbatim -- display list only for the person screen's specialization grant picker; server/certifications.lua's GrantSpecialization re-checks this SAME table server-side
        themingEnabled: false, // Config.Features.TabletTheming -- UX hint only, see client/tablet.lua's own NUI CONTRACT note
        shopLocationsEnabled: false, // Config.Features.K9EquipmentShop -- UX hint only, SAME posture as themingEnabled
        branding: {}, // { serverName, logo, theme:{4 colors} } -- Config.CommandTablet.branding, verbatim; see buildBrandingElement()/applyBrandingSeedTheme()
        // 'highCommand' | null -- set from tablet:open's own `requestedView`
        // (client/tablet.lua's new Config.CommandTablet.highCommandCommand
        // shortcut), CONSUMED (reset to null) the first time loadMyRecord()
        // resolves after an open -- see that function's own comment. A
        // PRESENTATION HINT ONLY: it never gates a fetch by itself, it only
        // decides which screen loadMyRecord() lands on once the server's
        // own `viewer.isHighCommand` for THIS caller is known.
        requestedView: null,

        viewer: null, // set once tablet:requestMyRecord resolves successfully
        myRecordLoading: false,
        myRecordError: null, // { error, message }
        myRecord: null, // { certifications, xp, tierLabel, myFeatures }
        // CLIENT-LOCAL "who is holding it" role signal (this pass) --
        // client/tablet.lua's own ResolveLocalRoleFlags() doc comment has
        // the full reasoning. Cosmetic/framing ONLY (buildHomeScreen()'s
        // own role badge), never sent back to any mutation/trigger
        // callback -- see THE SECURITY RULE at the top of this file.
        // Populated from tablet:requestMyRecord's response alongside
        // `viewer` above (same loadMyRecord() call, same lifecycle), and
        // reset to false on every open, same as viewer/myRecord above.
        isK9Model: false,
        isPartnered: false,

        // Command Reference screen's own search box -- see
        // buildCommandReferenceScreen() below. A plain client-side filter
        // over the static COMMAND_REFERENCE catalog, never a server round
        // trip (there is nothing server-side to ask -- this whole screen is
        // presentation over data this page already has, see
        // commandReferenceStatus()'s own doc comment), so this needs no
        // loading/error pair the way rosterQuery's server-backed search
        // does just below.
        commandReferenceQuery: '',

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

        // Permission-key catalog editing -- server/permissionkeycatalog.lua
        // (owner-directed "...even add or remove permissions" pass). Sits
        // alongside the cert-tier screen above, same "never hardcoded,
        // never preloaded" posture: `permissionKeys` is null until the
        // first successful tablet:permKeysList. No ordinal/capabilities
        // concept exists for a permission key (see that file's own header
        // "WHY NO ORDINAL"), so this state is deliberately simpler than
        // certTier* above -- no warning banner, no reorder.
        permissionKeys: null, // [{ key, label, description, isConfigDefault }, ...], alphabetical (server-sorted)
        permissionKeysLoading: false,
        permissionKeysError: null,
        permissionKeyDraft: null, // { key, label, description, isNew } -- the add/edit form's own working copy; null = form closed
        permissionKeyFieldError: null, // 'key' | 'label' | 'description' | null -- which of the draft form's own inputs the server's last permKeysUpsert rejected
        permissionKeyActionError: null, // { key, text } -- a delete REFUSAL (reserved_namespace/unknown_key) rendered inline on that specific row, same shape as certTierActionError

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

        // XP Rank Editor -- server/xptiers.lua (owner-directed "...set
        // experience level for each rank up" pass). Sits alongside the
        // cert-tier/permission-key/shop-location/runtime-control tabs
        // above, same "never hardcoded, never preloaded" posture:
        // `xpTiers` is null until the first successful tablet:xpTiersList
        // -- the four-rank ladder is DB-overlaid config (server/xptiers.lua's
        // own header), never duplicated here. No add/remove/reorder for
        // this ladder (fixed cardinality -- see that file's own header
        // "SCOPE DECISION"), so this state is deliberately simpler than
        // certTiers* above: one draft slot for whichever single rank is
        // currently being edited, no key/ordinal picker.
        xpTiers: null, // [{ ordinal, xp, label, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier?, badge?, xpLocked }, ...], ordinal-ordered, straight from the server
        xpTiersLoading: false,
        xpTiersError: null,
        // Non-optional whenever the LAST successful upsert demoted at least
        // one currently-connected K9 -- server/xptiers.lua's own header
        // "THE ALREADY-PROMOTED PLAYER". Rendered as its own prominent
        // banner, SAME posture as certTierWarning above, never folded into
        // the generic actionNotice, so it is never missed.
        xpTierWarning: null,
        xpTierDraft: null, // { ordinal, xp: string, label: string, speedMultiplier: string, scentRangeMultiplier: string, medkitCooldownMultiplier: string, badge: string, xpLocked } -- the ONE open rank's working copy; null = no editor open. `xp` is never user-editable when xpLocked (rank 1) -- always submitted as 0 regardless of this field's own value.
        xpTierFieldError: null, // 'xp' | 'label' | 'speedMultiplier' | 'scentRangeMultiplier' | 'medkitCooldownMultiplier' | 'badge' | null -- which of the open draft's own inputs the last xpTiersUpsert rejected (client-side pre-check OR the server's own refusal, same field either way)
        xpTierActionError: null, // { ordinal, text } -- an upsert REFUSAL rendered inline on that specific rank's own row, same "cannot, and here is why" convention as certTierActionError/permissionKeyActionError/shopLocationActionError/runtimeTunableFieldError above

        // K9 Supply Shop ITEM CATALOG editing -- server/equipmentshop.lua's
        // own "EQUIPMENT SHOP ITEM CATALOG" section. Sits alongside the
        // Shop Locations tab above -- same "K9 Supply Shop" domain, split
        // into two tabs because WHICH items are sold/at what price/order/
        // purchase-requirement is a SEPARATE server-side authorization key
        // ('k9.equipmentshopitems') from WHERE a shop ped stands
        // ('k9.equipmentshoplocations') -- see that file's own
        // CanManageShopItems/CanManageShopLocations doc comments. Same
        // "never hardcoded, never preloaded" posture as certTiers/
        // shopLocations/xpTiers above: `shopItems` is null until the first
        // successful tablet:equipmentShopItemsList.
        shopItems: null, // [{ key, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization }, ...], already sortOrder-ascending, straight from server/equipmentshop.lua's own ListEquipmentShopItems. A TOMBSTONED item never appears in this array at all (the server's own catalog merge excludes it entirely -- see that file's own "TOMBSTONE, NOT HARD-DELETE" section) -- this screen never has to render a "retired" row for one, only ever fewer rows after a successful delete.
        shopItemsLoading: false,
        shopItemsError: null,
        shopItemDraft: null, // { key, price: string, label: string, currency: string, requiredTierKey: string, requiredSpecialization: string, isNew } -- the add/edit form's own working copy; requiredTierKey/requiredSpecialization are '' for "no requirement" (the draft form's own <select> "None" option), never null, so a plain `.value` read always works; null = form closed
        shopItemFieldError: null, // 'key' | 'price' | 'label' | 'currency' | 'requiredTierKey' | 'requiredSpecialization' | null -- which of the draft form's own inputs the server's last equipmentShopItemsUpsert rejected
        shopItemActionError: null, // { key, text } -- a Delete/Reorder refusal rendered inline on that specific row, same convention as certTierActionError above

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
        auditLimit: 20, // shared numeric input for every mode except 'xp' (which takes none) -- clamped into [AUDIT_LIMIT_MIN, auditEffectiveCap()] before ever being sent, see runAuditQuery()
        auditServerCap: null, // the REAL cap (server/admin.lua's HARD_MAX_RESULTS) as reported by `result.cap` on the most recent successful tabletAudit* response -- null until the FIRST one ever succeeds this session, or if a response is ever missing the field (older server build) -- see auditEffectiveCap()/AUDIT_LIMIT_MAX_FALLBACK
        auditLoading: false,
        auditError: null, // { error, message } -- the LAST failed tabletAudit* response, cleared on the next successful query or mode switch
        auditResult: null, // { rows, label, truncated, requestedLimit, actualLimit } -- the LAST successful response; NOT reset on tab re-entry (same posture as roster/theme -- switching away and back keeps showing the last result), only on mode switch or tablet:open
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
     * English fallback text for the two 'client_enforced' badge/hint
     * strings -- the SAME "resilience net" role DEFAULT_STRINGS plays for
     * every S()-driven key, but kept as its OWN small pair here rather
     * than folded into DEFAULT_STRINGS/S(): tests/tabletlocalization_spec.lua
     * (off-limits to this pass, and itself locked from being edited by it)
     * hardcodes DEFAULT_STRINGS at an EXACT 287 keys and the real
     * `strings` NUI payload at EXACTLY 287 entries -- adding either new
     * key through that normal path would push both counts to 289 and trip
     * a locked assertion this pass has no way to update. client/tablet.lua
     * sends the real, locale()-resolved text through two STANDALONE
     * `tablet:open` fields instead (`blockClientEnforcedBadge`/
     * `blockClientEnforcedHint` -- see that file's own OpenTablet() doc
     * comment), captured below into `state.blockClientEnforcedBadge`/
     * `state.blockClientEnforcedHint`; these two constants are what this
     * page shows ONLY if that real text is ever missing (an older
     * client/tablet.lua, or a locale() failure server-side) -- text kept
     * byte-identical to locales/en.json's
     * tablet.block_client_enforced_badge/_hint. FOLLOW-UP, reported: once
     * tests/tabletlocalization_spec.lua's owner can update its hardcoded
     * counts, fold these two back into the ordinary
     * TABLET_STRING_KEYS/DEFAULT_STRINGS mechanism and retire this pair.
     */
    var CLIENT_ENFORCED_FALLBACK_BADGE = 'Enforced (client-side)';
    var CLIENT_ENFORCED_FALLBACK_HINT = "Blocking this stops the ability on the player's own game client. Unlike a server-enforced block, a modified or cheating client can bypass it -- treat this as best-effort, not a guarantee.";

    /** @returns {string} */
    function clientEnforcedBadgeText() {
        return (typeof state.blockClientEnforcedBadge === 'string' && state.blockClientEnforcedBadge.length > 0)
            ? state.blockClientEnforcedBadge
            : CLIENT_ENFORCED_FALLBACK_BADGE;
    }

    /** @returns {string} */
    function clientEnforcedHintText() {
        return (typeof state.blockClientEnforcedHint === 'string' && state.blockClientEnforcedHint.length > 0)
            ? state.blockClientEnforcedHint
            : CLIENT_ENFORCED_FALLBACK_HINT;
    }

    /**
     * Normalizes `feature.blockEnforcement` (server-reported, see this
     * file's own PersonFeaturesResult doc comment for the four real
     * values and why 'not_yet_enforced' is the safe fallback) -- NEVER
     * derived from `feature.key` here. This page has no hardcoded list of
     * which features honour a block and never will: the whole point of
     * this field is that the server is the only place that answer can
     * come from without rotting the moment another feature gets wired
     * (see server/runtimecontrol.lua's own FEATURE_TIERS for the identical
     * reasoning applied to a different question). An unrecognized or
     * absent value collapses to 'not_yet_enforced', the same direction
     * server/runtimecontrol.lua's own 'unaudited' tier fails closed in --
     * this page must never claim a block works (fully OR client-side-only)
     * when it does not know.
     * @param {{blockEnforcement?: string}} feature
     * @returns {'enforced'|'client_enforced'|'not_enforceable'|'not_yet_enforced'}
     */
    function featureBlockEnforcement(feature) {
        var v = feature && feature.blockEnforcement;
        if (v === 'enforced' || v === 'client_enforced' || v === 'not_enforceable') return v;
        return 'not_yet_enforced';
    }

    /** @param {'enforced'|'client_enforced'|'not_enforceable'|'not_yet_enforced'} enforcement @returns {string} */
    function blockEnforcementBadgeLabel(enforcement) {
        if (enforcement === 'enforced') return S('block_enforced_badge');
        if (enforcement === 'client_enforced') return clientEnforcedBadgeText();
        return S('block_not_yet_enforced_badge');
    }

    /**
     * Hint tooltip for the Block Effect badge -- 'not_yet_enforced' AND
     * 'client_enforced' both carry one (the two states where the operator
     * genuinely needs the extra sentence: "not wired up yet" vs. "works,
     * but only against an unmodified client"); 'enforced' needs no
     * qualifier and 'not_enforceable' shows its own separate note instead
     * of a badge at all (see buildPersonFeatureRow below).
     * @param {'enforced'|'client_enforced'|'not_enforceable'|'not_yet_enforced'} enforcement
     * @returns {string|undefined}
     */
    function blockEnforcementBadgeTitle(enforcement) {
        if (enforcement === 'not_yet_enforced') return S('block_not_yet_enforced_hint');
        if (enforcement === 'client_enforced') return clientEnforcedHintText();
        return undefined;
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
        // ALWAYS rendered now (this pass) -- previously gated on
        // canManageRoster, which meant a viewer with zero effective
        // permissions (in practice: someone certified nowhere at all, not
        // even the base 'k9.access' HasK9Access() resolves for almost
        // every certified handler/K9 -- see server/tablet.lua's
        // ResolveEffectivePermissions) saw NO navigation at all, not even
        // a way back to 'my_record'. buildTabs() itself now gates its own
        // Command Console entry on this SAME canManageRoster expression
        // (see that function) so this widening never exposes a tab that
        // would silently dead-end into the wrong screen -- the Home tab
        // (and, for a resolved viewer, My Record) are the only two every
        // viewer is guaranteed to see.
        panel.appendChild(buildTabs());

        if (state.screen === 'home') {
            panel.appendChild(buildHomeScreen());
        } else if (state.screen === 'commands') {
            panel.appendChild(buildCommandReferenceScreen());
        } else if (state.screen === 'console' && canManageRoster) {
            panel.appendChild(buildConsoleScreen());
        } else if (state.screen === 'person' && canManageRoster) {
            panel.appendChild(buildPersonScreen());
        } else if (state.screen === 'theme' && state.viewer.isHighCommand) {
            panel.appendChild(buildThemeScreen());
        } else if (state.screen === 'cert_tiers' && state.viewer.isHighCommand) {
            panel.appendChild(buildCertTiersScreen());
        } else if (state.screen === 'permission_keys' && state.viewer.isHighCommand) {
            panel.appendChild(buildPermissionKeysScreen());
        } else if (state.screen === 'shop_locations' && state.viewer.isHighCommand) {
            panel.appendChild(buildShopLocationsScreen());
        } else if (state.screen === 'shop_items' && state.viewer.isHighCommand) {
            panel.appendChild(buildShopItemsScreen());
        } else if (state.screen === 'runtime_control' && state.viewer.isHighCommand) {
            panel.appendChild(buildRuntimeControlScreen());
        } else if (state.screen === 'xp_tiers' && state.viewer.isHighCommand) {
            panel.appendChild(buildXpTiersScreen());
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

    /**
     * Larger, one-off branding badge for the screen a player sees before
     * anything else -- buildViewerGate() below, which covers BOTH the
     * initial loading state (requestMyRecord in flight) and the error/
     * retry state, i.e. the tablet's actual "landing" moment. Deliberately
     * the ONLY other place a logo appears besides the small header mark
     * (buildBrandingElement(), shown in buildHeader() on every single
     * screen already, which is why this is not ALSO repeated on e.g. the
     * My Record tab or as a per-screen title decoration -- a busy, high-
     * contrast crest shown six times on one panel reads worse than once,
     * placed well).
     *
     * Same missing/broken-logo-degrades-to-text discipline as
     * buildBrandingElement() immediately above -- see that function's own
     * doc comment for why the `error` listener is the one place this file
     * mutates an already-built element's style directly instead of going
     * through state+render(). `serverName`/`logo` are OPERATOR-SUPPLIED,
     * DOM-bound strings here too -- textContent / an `attrs.src`+`attrs.alt`
     * pair only, never innerHTML, same as the header mark.
     */
    function buildBrandingMark() {
        var branding = state.branding || {};
        var serverName = (typeof branding.serverName === 'string' && branding.serverName.length > 0) ? branding.serverName : '';
        var logoPath = (typeof branding.logo === 'string' && branding.logo.length > 0) ? branding.logo : '';

        var wrap = mk('div', { class: 'k9tablet-branding-mark' });
        if (serverName.length === 0 && logoPath.length === 0) return wrap;

        var fallbackText = mk('span', { class: 'k9tablet-branding-mark-name', text: serverName });

        if (logoPath.length > 0) {
            var frame = mk('div', { class: 'k9tablet-branding-mark-frame' });
            var img = mk('img', { class: 'k9tablet-branding-mark-logo', attrs: { src: logoPath, alt: serverName } });
            // Same hidden-until-error handshake as buildBrandingElement():
            // the frame (border/background box) hides along with the image
            // it exists to frame, never left behind as an empty outline.
            fallbackText.style.display = 'none';
            img.addEventListener('error', function () {
                frame.style.display = 'none';
                fallbackText.style.display = '';
            });
            frame.appendChild(img);
            wrap.appendChild(frame);
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
        wrap.appendChild(buildBrandingMark());
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

        // HOME -- the new landing view (owner-directed "restructure the
        // tablet around WHO IS HOLDING IT... a first-time player who has
        // read nothing should open this and know what to do within
        // seconds", see buildHomeScreen()). Always first, and, unlike
        // every tab below, ALWAYS shown regardless of canManageRoster --
        // buildBackdrop() now renders this whole tab bar unconditionally
        // for every resolved viewer, and Home is the one screen every
        // single one of them, including a brand-new uncertified arrival,
        // can always usefully land on.
        var homeTab = mkButton(S('tab_home'), 'k9tablet-tab' + (state.screen === 'home' ? ' k9tablet-tab--active' : ''), function () {
            state.screen = 'home';
            render();
        });
        tabs.appendChild(homeTab);

        var myTab = mkButton(S('tab_my_record'), 'k9tablet-tab' + (state.screen === 'my_record' ? ' k9tablet-tab--active' : ''), function () {
            state.screen = 'my_record';
            render();
            loadMyRecord();
        });
        tabs.appendChild(myTab);

        // COMMANDS -- the command reference (this pass, "36 commands, no
        // way for a player to discover them in-game"). ALWAYS shown, same
        // as Home/My Record immediately above and for the identical
        // reason: it is presentation over data every resolved viewer
        // already has (state.viewer/state.myRecord.myFeatures -- see
        // commandReferenceStatus()'s own doc comment), never a
        // console-only capability, so a brand-new uncertified arrival can
        // browse it to see what there is to earn just as usefully as a
        // high-command officer can browse it to see the full admin set
        // (marked as such -- see COMMAND_REFERENCE's own header).
        var commandsTab = mkButton(S('tab_commands'), 'k9tablet-tab' + (state.screen === 'commands' ? ' k9tablet-tab--active' : ''), function () {
            state.screen = 'commands';
            render();
        });
        tabs.appendChild(commandsTab);

        // Command Console -- ONLY meaningful for a viewer who actually has
        // console access. Previously appended unconditionally (safe only
        // because buildBackdrop() used to skip calling buildTabs() at all
        // for a canManageRoster === false viewer) -- now guarded HERE
        // explicitly, since this pass widens buildBackdrop() to always
        // render this tab bar (so the new Home tab above is reachable by
        // everyone); without this guard a viewer with no console access
        // would see a Console tab that silently dead-ends into My Record
        // instead (buildBackdrop()'s own 'console' branch already requires
        // canManageRoster) -- exactly the "button exists, does something
        // else" trap this codebase's own consistency rules forbid.
        var canManageRoster = state.viewer.isHighCommand || (state.viewer.effectivePermissions && state.viewer.effectivePermissions.length > 0);
        if (canManageRoster) {
            var consoleTab = mkButton(S('tab_console'), 'k9tablet-tab' + (state.screen === 'console' || state.screen === 'person' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'console';
                render();
                loadRoster(state.rosterQuery);
            });
            tabs.appendChild(consoleTab);
        }

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

            // Permission-key catalog editing -- owner-directed "...even add
            // or remove permissions" pass, server/permissionkeycatalog.lua.
            // SAME high-command gate as every tab in this block (a UX
            // convenience only: CanManagePermissionKeys is re-verified
            // server-side on every one of the three callbacks regardless of
            // whether this tab was ever shown). Sits immediately alongside
            // the cert-tier tab above, not in a new unrelated place, per
            // this pass's own explicit instruction. Fresh entry clears any
            // leftover draft/refusal, same reset discipline as every other
            // tab switch on this page.
            var permissionKeysTab = mkButton(S('tab_permission_keys'), 'k9tablet-tab' + (state.screen === 'permission_keys' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'permission_keys';
                state.permissionKeyDraft = null;
                state.permissionKeyFieldError = null;
                state.permissionKeyActionError = null;
                render();
                loadPermissionKeys();
            });
            tabs.appendChild(permissionKeysTab);

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

            // K9 Supply Shop ITEM CATALOG editing -- SAME high-command gate
            // (server/equipmentshop.lua's own CanManageShopItems is the
            // real, re-verified-per-call gate; this tab hides the screen
            // from everyone else as a convenience only). Sits alongside
            // the Shop Locations tab immediately above -- same "K9 Supply
            // Shop" domain, split into two tabs because WHICH items are
            // sold (this tab) vs. WHERE the shop ped stands (the tab
            // above) are two independent server-side authorization keys.
            // Fresh entry clears any leftover draft/refusal, same reset
            // discipline as every other tab switch on this page. Also
            // opportunistically loads the certification-tier catalog
            // (needed for this screen's own "Required Tier" picker) --
            // SAME best-effort posture as openPerson()'s own
            // loadCertTiers() call: a caller who cannot list tiers simply
            // sees the raw tier key as plain text instead of a labelled
            // dropdown option, never a broken control.
            var shopItemsTab = mkButton(S('tab_shop_items'), 'k9tablet-tab' + (state.screen === 'shop_items' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'shop_items';
                state.shopItemDraft = null;
                state.shopItemFieldError = null;
                state.shopItemActionError = null;
                render();
                loadEquipmentShopItems();
                loadCertTiers();
            });
            tabs.appendChild(shopItemsTab);

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

            // XP Rank Editor -- SAME high-command gate as every tab in this
            // block (a UX convenience only: CanManageXPTiers is re-verified
            // server-side on every one of the two callbacks this screen
            // calls regardless of whether this tab was ever shown -- see
            // server/xptiers.lua's own header "AUTHORIZATION"). Fresh entry
            // clears any leftover draft/refusal/warning from a previous
            // visit, same reset discipline as every other tab switch on
            // this page.
            var xpTiersTab = mkButton(S('tab_xp_tiers'), 'k9tablet-tab' + (state.screen === 'xp_tiers' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'xp_tiers';
                state.xpTierDraft = null;
                state.xpTierFieldError = null;
                state.xpTierActionError = null;
                state.xpTierWarning = null;
                render();
                loadXpTiers();
            });
            tabs.appendChild(xpTiersTab);
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

    // ------------------------------------------------------------------
    // HOME / LANDING VIEW (this pass -- owner's own words, verbatim:
    // "make the tablet UI for all k9 dogs, k9 handlers, k9 partners and k9
    // high command more fluid, easier to understand, more personal...
    // everything in the tablet more structured... easier to understand
    // where if someone is an idiot they can figure it out very quickly").
    //
    // THE PROBLEM THIS SCREEN SOLVES: every OTHER screen in this file is
    // organised around a SUBSYSTEM (certifications, permissions, the shop,
    // runtime switches, the audit trail) -- correct for someone who already
    // knows what they are looking for, useless as a FIRST thing to see.
    // This screen is organised around the VIEWER instead: it answers "what
    // am I, and what can I do?" in one glance, before asking them to decode
    // a tab bar at all. It is now the DEFAULT screen on every open (see
    // handleOpen()) and the first tab in buildTabs() -- every existing
    // screen/tab is UNCHANGED and still one click away, nothing here
    // deletes or renames anything.
    //
    // FOUR VIEWERS, ONE SCREEN, DIFFERENT CONTENT (never a different
    // screen -- one consistent layout, one consistent set of patterns,
    // per this pass's own "Consistency" requirement):
    //   THE K9 (state.isK9Model true) -- role badge reads 'K9'.
    //   THE HANDLER (certified, not currently wearing a K9 model) -- role
    //     badge reads 'Certified Handler'.
    //   THE PARTNER -- EITHER of the above, PLUS the partnered/no-partner
    //     badge (state.isPartnered, a client-local signal -- see
    //     client/tablet.lua's ResolveLocalRoleFlags() for why this can
    //     never be a THE SECURITY RULE concern: it is read-only framing,
    //     never sent back into any mutation/trigger callback).
    //   HIGH COMMAND (viewer.isHighCommand) -- role badge reads 'High
    //     Command'; ALSO gets the dedicated High Command Tools section
    //     below, which a Handler/K9/Partner viewer never sees at all --
    //     THE PROGRESSIVE-DISCLOSURE REQUIREMENT: high command's own
    //     twelve-ish admin screens are grouped under ONE heading, below
    //     the fold, rather than crowding the two or three actions an
    //     ordinary handler actually wants.
    //
    // STATE AT A GLANCE (this pass's own explicit ask -- "a player should
    // never have to infer"): the identity card's badge row shows certified
    // count, partnered/not, and a blocked-ability count WITHOUT the viewer
    // opening a single other screen, reusing the SAME semantic colour
    // classes (.k9tablet-feature-state--available/--blocked/--global_off)
    // every other screen already uses for the identical good/bad/neutral
    // meaning -- never a new, one-off colour.
    //
    // NO CERTIFICATION IS NOT AN EMPTY SHELL: a viewer with zero active
    // certifications still gets a real, useful screen -- an explicit
    // "you're not certified yet, here is what to do" notice (see
    // buildHomeIdentityCard() below) INSTEAD OF a blank card, and still
    // gets the "View My Record" quick action (which itself already
    // renders 'no_certifications'/'no_abilities' honestly, never a
    // broken screen -- see buildMyRecordScreen() immediately below this
    // block).
    //
    // NAVIGATION HELPERS immediately below are COPIED VERBATIM from
    // buildTabs()'s own matching tab onClick bodies (same screen, same
    // fresh-entry draft/error/warning reset, same reload calls) --
    // deliberately NOT a refactor of buildTabs() itself to share these
    // (this file is being edited by several other agents concurrently
    // this same pass; touching every existing tab's own closure body
    // to share code carries far more conflict risk than one small,
    // clearly-labelled, easy-to-audit duplication here). If buildTabs()
    // ever changes one of these bodies, keep this block in sync.
    // ------------------------------------------------------------------

    function goToMyRecordScreen() {
        state.screen = 'my_record';
        render();
        loadMyRecord();
    }

    function goToConsoleScreen() {
        state.screen = 'console';
        render();
        loadRoster(state.rosterQuery);
    }

    function goToThemeScreen() {
        state.screen = 'theme';
        render();
        loadTheme();
    }

    function goToCertTiersScreen() {
        state.screen = 'cert_tiers';
        state.certTierDraft = null;
        state.certTierFieldError = null;
        state.certTierActionError = null;
        state.certTierWarning = null;
        render();
        loadCertTiers();
    }

    function goToPermissionKeysScreen() {
        state.screen = 'permission_keys';
        state.permissionKeyDraft = null;
        state.permissionKeyFieldError = null;
        state.permissionKeyActionError = null;
        render();
        loadPermissionKeys();
    }

    function goToShopLocationsScreen() {
        state.screen = 'shop_locations';
        state.shopLocationDraft = null;
        state.shopLocationActionError = null;
        render();
        loadShopLocations();
    }

    function goToShopItemsScreen() {
        state.screen = 'shop_items';
        state.shopItemDraft = null;
        state.shopItemFieldError = null;
        state.shopItemActionError = null;
        render();
        loadEquipmentShopItems();
        loadCertTiers();
    }

    function goToRuntimeControlScreen() {
        state.screen = 'runtime_control';
        state.runtimeFeatureActionError = null;
        state.runtimeTunableDraft = null;
        state.runtimeTunableFieldError = null;
        render();
        loadRuntimeFeatures();
        loadRuntimeTunables();
    }

    function goToXpTiersScreen() {
        state.screen = 'xp_tiers';
        state.xpTierDraft = null;
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        state.xpTierWarning = null;
        render();
        loadXpTiers();
    }

    function goToAuditScreen() {
        state.screen = 'audit';
        render();
    }

    /** @returns {boolean} -- SAME expression as buildBackdrop()/buildTabs() own local canManageRoster; a small, deliberate, per-function duplicate of a two-line boolean, matching this resource's own established convention for this exact situation (see e.g. server/tablet.lua's MeetsDepartmentRank doc comment) rather than a shared helper that would require touching either of those two functions' own call sites. */
    function homeCanManageRoster() {
        return !!(state.viewer && (state.viewer.isHighCommand || (state.viewer.effectivePermissions && state.viewer.effectivePermissions.length > 0)));
    }

    /** @returns {{active:number, total:number}} */
    function homeCertificationCounts() {
        var certs = (state.myRecord && state.myRecord.certifications) || [];
        var active = 0;
        for (var i = 0; i < certs.length; i++) {
            if (certs[i] && certs[i].active) active++;
        }
        return { active: active, total: certs.length };
    }

    /** @returns {number} */
    function homeBlockedFeatureCount() {
        var features = (state.myRecord && state.myRecord.myFeatures) || [];
        var count = 0;
        for (var i = 0; i < features.length; i++) {
            if (features[i] && features[i].state === 'blocked') count++;
        }
        return count;
    }

    /** Actionable AND currently available features only -- the "ready to
     * use right now" subset shown on Home; the FULL list (every state,
     * actionable or not) stays on My Record -- see buildMyFeaturesList().
     * @returns {Array} */
    function homeReadyFeatures() {
        var features = (state.myRecord && state.myRecord.myFeatures) || [];
        var out = [];
        for (var i = 0; i < features.length; i++) {
            var f = features[i];
            if (f && f.actionable === true && f.state === 'available') out.push(f);
        }
        return out;
    }

    /** @returns {string} */
    function homeRoleLabel() {
        if (state.viewer.isHighCommand) return S('home_role_high_command');
        if (state.isK9Model) return S('home_role_k9');
        if (homeCertificationCounts().active > 0) return S('home_role_handler');
        return S('home_role_uncertified');
    }

    function buildHomeActionCard(label, hint, onClick) {
        var card = mk('button', { class: 'k9tablet-home-action-card' });
        card.setAttribute('type', 'button');
        card.appendChild(mk('span', { class: 'k9tablet-home-action-label', text: label }));
        if (typeof hint === 'string' && hint.length > 0) {
            card.appendChild(mk('span', { class: 'k9tablet-home-action-hint', text: hint }));
        }
        card.addEventListener('click', function (e) {
            if (e && typeof e.preventDefault === 'function') e.preventDefault();
            onClick();
        });
        return card;
    }

    function buildHomeIdentityCard() {
        var card = mk('div', { class: 'k9tablet-home-card k9tablet-home-identity' });

        var name = (typeof state.viewer.name === 'string' && state.viewer.name.length > 0) ? state.viewer.name : state.viewer.citizenid;
        card.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: formatTemplate(S('home_welcome_template'), { name: String(name) }) }));

        var badges = mk('div', { class: 'k9tablet-home-badges' });
        badges.appendChild(mk('span', { class: 'k9tablet-home-role-badge', text: homeRoleLabel() }));

        if (state.isPartnered) {
            badges.appendChild(mk('span', { class: 'k9tablet-feature-state k9tablet-feature-state--available', text: S('home_partnered_badge') }));
        } else {
            badges.appendChild(mk('span', { class: 'k9tablet-muted', text: S('home_not_partnered_badge') }));
        }

        var counts = homeCertificationCounts();
        if (counts.total > 0) {
            var certClass = counts.active > 0 ? 'k9tablet-feature-state--available' : 'k9tablet-feature-state--global_off';
            badges.appendChild(mk('span', {
                class: 'k9tablet-feature-state ' + certClass,
                text: formatTemplate(S('home_certified_count_template'), { count: counts.active, total: counts.total }),
            }));
        }

        var blockedCount = homeBlockedFeatureCount();
        if (blockedCount > 0) {
            badges.appendChild(mk('span', {
                class: 'k9tablet-feature-state k9tablet-feature-state--blocked',
                text: formatTemplate(S('home_blocked_count_template'), { count: blockedCount }),
            }));
        }

        card.appendChild(badges);

        // NO CERTIFICATION IS NOT AN EMPTY SHELL -- see this block's own
        // header comment. Shown whenever this viewer holds zero ACTIVE
        // certifications but at least one department exists to be
        // certified in at all (a misconfigured zero-department server has
        // nothing useful to say here either way).
        if (counts.active === 0 && counts.total > 0) {
            var notice = mk('div', { class: 'k9tablet-home-notice' });
            notice.appendChild(mk('p', { class: 'k9tablet-home-notice-title', text: S('home_no_certification_title') }));
            notice.appendChild(mk('p', { class: 'k9tablet-muted', text: S('home_no_certification_body') }));
            card.appendChild(notice);
        }

        return card;
    }

    function buildHomeQuickActions() {
        var section = mk('div', { class: 'k9tablet-home-section' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('home_quick_actions_heading') }));

        var grid = mk('div', { class: 'k9tablet-home-actions' });
        grid.appendChild(buildHomeActionCard(S('home_view_my_record_label'), S('home_view_my_record_hint'), goToMyRecordScreen));

        if (homeCanManageRoster()) {
            grid.appendChild(buildHomeActionCard(S('home_open_console_label'), S('home_open_console_hint'), goToConsoleScreen));
        }

        section.appendChild(grid);
        return section;
    }

    function buildHomeReadyAbilities() {
        var section = mk('div', { class: 'k9tablet-home-section' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('home_ready_abilities_heading') }));

        var ready = homeReadyFeatures();
        if (ready.length === 0) {
            section.appendChild(mk('p', { class: 'k9tablet-muted', text: S('home_no_ready_abilities') }));
        } else {
            var list = mk('div', { class: 'k9tablet-feature-list' });
            for (var i = 0; i < ready.length; i++) {
                list.appendChild(buildMyFeatureRow(ready[i]));
            }
            section.appendChild(list);
        }

        section.appendChild(mkButton(S('home_view_all_abilities_label'), 'k9tablet-link-btn', goToMyRecordScreen));
        return section;
    }

    /**
     * A Home-screen shortcut to an existing high-command tab. DELIBERATELY
     * NOT rendered with the tab's own exact label string -- an arrow
     * suffix keeps the SAME recognizable name (never a second, different
     * name for the same screen -- see this block's own "Name things in
     * the player's language... consistency" header note) while keeping
     * this shortcut's own DOM node textually distinct from the real tab
     * button that ALSO sits in the document at the same time (buildTabs()
     * is always rendered alongside every screen, including Home) --
     * several existing specs assert a tab exists via an EXACT, single
     * textContent match (e.g. tablet_xp_tiers_spec.js / tablet_audit_spec.js),
     * an assumption this screen must not break just by adding a second,
     * synonymous way to reach the same place.
     * @param {string} label @param {() => void} onClick */
    function buildHomeToolLink(label, onClick) {
        return mkButton(label + ' →', 'k9tablet-btn k9tablet-home-tool-link', onClick);
    }

    /** HIGH COMMAND ONLY (see buildHomeScreen()'s own call site) -- the
     * PROGRESSIVE-DISCLOSURE section: every admin screen this page has,
     * grouped under one heading, below the two or three actions an
     * ordinary viewer wants. Reuses the EXISTING tab_* labels
     * (tab_theme/tab_cert_tiers/...) rather than inventing a second name
     * for each screen -- one name per screen, everywhere it appears, per
     * this pass's own "Name things in the player's language... consistency"
     * requirement. Each link is a plain S('tab_x')-labelled button, not a
     * hinted card like buildHomeActionCard() above -- deliberately
     * LOWER-EMPHASIS than the two common actions, never competing with
     * them for attention. */
    function buildHomeHighCommandTools() {
        var section = mk('div', { class: 'k9tablet-home-section k9tablet-home-highcommand' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('home_high_command_heading') }));
        section.appendChild(mk('p', { class: 'k9tablet-muted', text: S('home_high_command_hint') }));

        var grid = mk('div', { class: 'k9tablet-home-tools' });
        grid.appendChild(buildHomeToolLink(S('tab_theme'), goToThemeScreen));
        grid.appendChild(buildHomeToolLink(S('tab_cert_tiers'), goToCertTiersScreen));
        grid.appendChild(buildHomeToolLink(S('tab_permission_keys'), goToPermissionKeysScreen));
        grid.appendChild(buildHomeToolLink(S('tab_shop_locations'), goToShopLocationsScreen));
        grid.appendChild(buildHomeToolLink(S('tab_shop_items'), goToShopItemsScreen));
        grid.appendChild(buildHomeToolLink(S('tab_runtime_control'), goToRuntimeControlScreen));
        grid.appendChild(buildHomeToolLink(S('tab_xp_tiers'), goToXpTiersScreen));
        if (canViewAudit()) {
            grid.appendChild(buildHomeToolLink(S('tab_audit'), goToAuditScreen));
        }
        section.appendChild(grid);
        return section;
    }

    /** THE LANDING VIEW -- see this block's own header comment for the
     * full information-architecture writeup. Same loading/error/empty
     * posture as buildMyRecordScreen() immediately below (this file's one
     * consistent loading/error pattern, reused here rather than a second
     * one invented for this screen). */
    function buildHomeScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen k9tablet-home' });

        if (state.myRecordLoading && !state.myRecord) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.myRecordError && !state.myRecord) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.myRecordError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadMyRecord));
            return wrap;
        }
        if (!state.myRecord || !state.viewer) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildHomeIdentityCard());
        wrap.appendChild(buildHomeQuickActions());
        wrap.appendChild(buildHomeReadyAbilities());

        if (state.viewer.isHighCommand) {
            wrap.appendChild(buildHomeHighCommandTools());
        }

        return wrap;
    }

    // ------------------------------------------------------------------
    // COMMAND REFERENCE screen (this pass) -- see COMMAND_REFERENCE's own
    // header above for the catalog, its drift guard, and exactly what
    // commandReferenceStatus() does and does not promise. Grouped by
    // COMMAND_REFERENCE_CATEGORIES (what the player is trying to do, never
    // by which server/client file registers the command), filterable by a
    // single client-side search box (36 entries is too many to scan, and
    // there is nothing server-side to ask -- see state.commandReferenceQuery's
    // own doc comment), and every row shows the SAME four things for every
    // viewer: the command with its argument shape, one plain-English line
    // on what it does, one on what it needs, and a live status badge --
    // never hidden for a viewer who cannot use it, per this task's own
    // "that is more useful than hiding it, because it tells them what to
    // go earn" instruction.
    // ------------------------------------------------------------------

    function buildCommandReferenceScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('cmdref_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('cmdref_intro') }));

        var search = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('cmdref_search_placeholder') } });
        search.value = state.commandReferenceQuery;
        search.addEventListener('input', function (e) {
            state.commandReferenceQuery = e.target.value;
            render();
        });
        wrap.appendChild(search);

        var query = (state.commandReferenceQuery || '').toLowerCase();
        var anyRendered = false;

        for (var c = 0; c < COMMAND_REFERENCE_CATEGORIES.length; c++) {
            var category = COMMAND_REFERENCE_CATEGORIES[c];
            var categoryLabel = S(category.labelKey);

            var rows = [];
            for (var i = 0; i < COMMAND_REFERENCE.length; i++) {
                var entry = COMMAND_REFERENCE[i];
                if (entry.category !== category.key) continue;
                if (query.length > 0) {
                    var haystack = (
                        entry.command + ' ' + S(entry.usageKey) + ' ' + S(entry.doesKey) + ' ' +
                        S(entry.needsKey) + ' ' + categoryLabel
                    ).toLowerCase();
                    if (haystack.indexOf(query) === -1) continue;
                }
                rows.push(entry);
            }
            if (rows.length === 0) continue;

            anyRendered = true;
            wrap.appendChild(mk('h3', { class: 'k9tablet-specializations-heading', text: categoryLabel }));

            var table = mk('table', { class: 'k9tablet-table' });
            var thead = mk('thead');
            var headRow = mk('tr');
            [S('cmdref_column_command'), S('cmdref_column_does'), S('cmdref_column_needs'), S('status_column')].forEach(function (h) {
                headRow.appendChild(mk('th', { text: h }));
            });
            thead.appendChild(headRow);
            table.appendChild(thead);

            var tbody = mk('tbody');
            for (var r = 0; r < rows.length; r++) {
                tbody.appendChild(buildCommandReferenceRow(rows[r]));
            }
            table.appendChild(tbody);
            wrap.appendChild(table);
        }

        if (!anyRendered) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('cmdref_empty') }));
        }

        return wrap;
    }

    /** @param {{command:string, adminOnly:boolean, usageKey:string, doesKey:string, needsKey:string, gate:object}} entry */
    function buildCommandReferenceRow(entry) {
        var tr = mk('tr');

        var commandTd = mk('td');
        commandTd.appendChild(mk('span', { text: S(entry.usageKey) }));
        if (entry.adminOnly) {
            // Same "(Default)"/"(Retired)" inline-parenthetical convention
            // buildPersonFeaturesSection()/buildPermissionKeysScreen() already
            // use elsewhere on this page (plain text, k9tablet-muted, never a
            // new badge class) -- shown to EVERY viewer, not only high
            // command, per this task's own "high command sees everything,
            // with the admin ones marked as such" instruction: a handler
            // browsing this list should see which commands are the ones to
            // go earn authorization for, not just that they personally
            // can't run them today.
            commandTd.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('cmdref_admin_badge') + ')' }));
        }
        tr.appendChild(commandTd);

        tr.appendChild(mk('td', { text: S(entry.doesKey) }));
        tr.appendChild(mk('td', { text: S(entry.needsKey) }));

        var status = commandReferenceStatus(entry.gate);
        var statusTd = mk('td');
        statusTd.appendChild(mk('span', {
            class: 'k9tablet-feature-state k9tablet-feature-state--' + commandReferenceStatusClass(status),
            text: commandReferenceStatusLabel(status),
        }));
        tr.appendChild(statusTd);

        return tr;
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

    /**
     * Merges the four always-present shipped capabilities with whatever
     * server/permissionkeycatalog.lua's live catalog (state.permissionKeys,
     * populated by loadPermissionKeys() -- see openPerson()'s own
     * opportunistic call) currently reports, plus anything `heldKeys`
     * names that neither source accounts for. THREE buckets, in this
     * fixed order, each key appearing exactly once (first bucket wins):
     *
     *   1. CAPABILITY_ORDER's own four keys, ALWAYS present, in their
     *      existing fixed order, labelled via capabilityInfo() exactly as
     *      before this pass -- an operator who never touches the
     *      Permission Keys tab sees byte-identical output to today.
     *   2. Every OTHER catalog entry from a SUCCESSFUL state.permissionKeys
     *      fetch, in the order the server sent (alphabetical -- see that
     *      file's own ListPermissionCatalogKeys doc comment). A key only
     *      ever reaches this bucket when the catalog fetch actually
     *      confirmed it is currently known and non-tombstoned, so Grant is
     *      never offered for a key this page cannot confirm is real --
     *      state.permissionKeys stays null (or unrelated to this shape) on
     *      a failed/not-yet-run fetch, which simply yields zero rows here,
     *      never a synthesized "maybe grantable" guess.
     *   3. Any `heldKeys` entry bucket 1/2 didn't already cover. The ONLY
     *      way a currently-ACTIVE grant can name a key absent from a
     *      successful catalog fetch is server/permissionkeycatalog.lua's
     *      own tombstone behavior (ListPermissionCatalogKeys/
     *      IsKnownPermissionCatalogKey both exclude a tombstoned key
     *      entirely -- see that file's header "TOMBSTONE, NOT
     *      REFERENCE-COUNTED") -- so this bucket is rendered RETIRED and
     *      revoke-only, never offered a Grant button: a retired key that
     *      became invisible while still granted would otherwise be a
     *      permission nobody could take away. (The same bucket also
     *      quietly covers a held key while the catalog fetch simply
     *      hasn't resolved yet -- indistinguishable from "retired" from
     *      here, and the right action is the same either way: let the
     *      operator revoke it.)
     * @param {string[]} heldKeys
     * @returns {Array<{key:string,label:string,description:string,held:boolean,retired:boolean,grantable:boolean}>}
     */
    function resolveCapabilityRows(heldKeys) {
        heldKeys = Array.isArray(heldKeys) ? heldKeys : [];
        var rows = [];
        var seen = {};

        for (var i = 0; i < CAPABILITY_ORDER.length; i++) {
            var defaultKey = CAPABILITY_ORDER[i];
            seen[defaultKey] = true;
            var defaultInfo = capabilityInfo(defaultKey);
            rows.push({
                key: defaultKey,
                label: defaultInfo.label,
                description: defaultInfo.description || '',
                held: heldKeys.indexOf(defaultKey) !== -1,
                retired: false,
                grantable: true,
            });
        }

        if (Array.isArray(state.permissionKeys)) {
            for (var j = 0; j < state.permissionKeys.length; j++) {
                var entry = state.permissionKeys[j];
                if (!entry || typeof entry.key !== 'string' || seen[entry.key]) continue;
                seen[entry.key] = true;
                rows.push({
                    key: entry.key,
                    label: (typeof entry.label === 'string' && entry.label.length > 0) ? entry.label : entry.key,
                    description: (typeof entry.description === 'string') ? entry.description : '',
                    held: heldKeys.indexOf(entry.key) !== -1,
                    retired: false,
                    grantable: true,
                });
            }
        }

        for (var k = 0; k < heldKeys.length; k++) {
            var heldKey = heldKeys[k];
            if (typeof heldKey !== 'string' || heldKey.length === 0 || seen[heldKey]) continue;
            seen[heldKey] = true;
            var retiredInfo = capabilityInfo(heldKey);
            rows.push({
                key: heldKey,
                label: retiredInfo.label,
                description: retiredInfo.description || '',
                held: true,
                retired: true,
                grantable: false,
            });
        }

        return rows;
    }

    function buildCapabilityList(heldKeys) {
        var rows = resolveCapabilityRows(heldKeys);
        var wrap = mk('div', { class: 'k9tablet-capability-list' });
        var citizenid = state.person.citizenid;

        for (var i = 0; i < rows.length; i++) {
            var rowData = rows[i];

            var row = mk('div', { class: 'k9tablet-capability-row' });
            var labelWrap = mk('span', { class: 'k9tablet-capability-label', text: rowData.label, title: rowData.description });
            if (rowData.retired) {
                labelWrap.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('permission_key_retired_badge') + ')' }));
            }
            row.appendChild(labelWrap);
            row.appendChild(mk('span', { class: 'k9tablet-capability-state', text: rowData.held ? S('certified_yes') : S('certified_no') }));

            if (rowData.held) {
                row.appendChild(mkConfirmButton(S('revoke_label'), 'k9tablet-btn k9tablet-btn--danger', function (k) {
                    return function () {
                        runMutation('tablet:revokePermission', { targetCitizenId: citizenid, permission: k }, function () {
                            loadPersonSummary(citizenid);
                        });
                    };
                }(rowData.key), { disabled: state.pendingAction }));
            } else if (rowData.grantable) {
                row.appendChild(mkButton(S('grant_label'), 'k9tablet-btn', function (k) {
                    return function () {
                        runMutation('tablet:grantPermission', { targetCitizenId: citizenid, permission: k }, function () {
                            loadPersonSummary(citizenid);
                        });
                    };
                }(rowData.key), { disabled: state.pendingAction }));
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
                title: blockEnforcementBadgeTitle(enforcement),
            }));
        }
        tr.appendChild(blockEffectTd);

        var actionsTd = mk('td', { class: 'k9tablet-feature-actions' });

        // Block/Unblock -- offered for every feature EXCEPT one this page
        // has been told, server-side, can never honour one at all
        // (`enforcement === 'not_enforceable'`) -- see this file's own
        // PersonFeaturesResult doc comment above for the two ways that
        // happens (no per-citizenid ability here to gate in the first
        // place, e.g. an administrative switch like CommandTablet; or a
        // deliberate design decision, e.g. server/recall.lua's
        // escape-hatch path). Offering a button that can never do
        // anything is exactly the dishonest control this task exists to
        // remove -- HIDDEN, not merely labeled, for this one case. A
        // 'client_enforced' feature (e.g. ThermalVision/NightVision) is
        // DELIBERATELY NOT included in this hidden case -- its Block
        // button genuinely does something, just with the weaker,
        // client-side-only guarantee the badge above already discloses.
        // `feature.blocked` (a block row may already exist from before
        // this distinction was surfaced) is still shown via the state
        // badge above regardless.
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

    // ---- Permission-key catalog screen (high command only) ----
    // Owner-directed "...even add or remove permissions" pass,
    // server/permissionkeycatalog.lua. Sits alongside the cert-tier screen
    // immediately above -- same structure (table + inline row actions +
    // add/edit form below), deliberately simpler: no ordinal/move-up-down,
    // no capabilities checkboxes (a permission key carries neither -- see
    // that file's own header "WHY NO ORDINAL").

    /**
     * Renders the LIVE catalogue from state.permissionKeys (populated by
     * loadPermissionKeys() -- see that function's own comment on why this
     * is never a hardcoded list: the four admin capability names
     * (k9.access/k9.certify/k9.audit/k9.givexp) are NOT hardcoded here
     * either, since high command can rename or retire any of them at
     * runtime), a per-row Edit/Delete set of controls, and (when a draft is
     * open) the add/edit form below the table.
     * server/permissionkeycatalog.lua's own CanManagePermissionKeys is the
     * real authorization gate, re-checked on every one of the three
     * callbacks this screen calls -- see THE SECURITY RULE.
     */
    function buildPermissionKeysScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('permission_keys_heading') }));

        if (state.permissionKeysLoading && !state.permissionKeys) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.permissionKeysError && !state.permissionKeys) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.permissionKeysError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadPermissionKeys));
            return wrap;
        }
        if (!state.permissionKeys) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildPermissionKeysTable());

        if (state.permissionKeyDraft) {
            wrap.appendChild(buildPermissionKeyDraftForm());
        } else {
            wrap.appendChild(mkButton(S('permission_keys_add_label'), 'k9tablet-btn', openNewPermissionKeyDraft, { disabled: state.pendingAction }));
        }

        return wrap;
    }

    function buildPermissionKeysTable() {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_key'), S('column_label'), S('column_description'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.permissionKeys.length; i++) {
            tbody.appendChild(buildPermissionKeyRow(state.permissionKeys[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {object} entry */
    function buildPermissionKeyRow(entry) {
        var tr = mk('tr');
        var keyTd = mk('td', { text: entry.key });
        if (entry.isConfigDefault === true) {
            keyTd.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('permission_key_default_badge') + ')' }));
        }
        tr.appendChild(keyTd);
        tr.appendChild(mk('td', { text: entry.label }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof entry.description === 'string' && entry.description.length > 0) ? entry.description : '' }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('permission_key_edit_label'), 'k9tablet-btn', function () {
            openPermissionKeyEditDraft(entry);
        }, { disabled: state.pendingAction }));
        actionsTd.appendChild(mkConfirmButton(S('permission_key_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            deletePermissionKey(entry.key);
        }, { disabled: state.pendingAction }));

        // A delete REFUSAL (reserved_namespace/unknown_key) renders INLINE
        // on THIS specific row -- "cannot, and here is why" -- same
        // convention as certTierActionError above.
        if (state.permissionKeyActionError && state.permissionKeyActionError.key === entry.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.permissionKeyActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Add/edit form -- see openNewPermissionKeyDraft()/
     * openPermissionKeyEditDraft() for how state.permissionKeyDraft is
     * populated. `key` is editable only for a BRAND NEW key --
     * server/permissionkeycatalog.lua's own permKeysUpsert has no "rename"
     * concept (submitting a DIFFERENT key while editing would create a
     * second, separate entry, not rename this one), same reasoning as the
     * cert-tier form's own key input above. */
    function buildPermissionKeyDraftForm() {
        var draft = state.permissionKeyDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var keyRow = mk('div', { class: 'k9tablet-theme-field' + (state.permissionKeyFieldError === 'key' ? ' k9tablet-theme-field--invalid' : '') });
        keyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('permission_key_key_label') }));
        var keyInput = mk('input', { class: 'k9tablet-cert-tier-key-input', attrs: { type: 'text', placeholder: S('permission_key_key_placeholder'), maxlength: '40' } });
        keyInput.value = draft.key;
        if (draft.isNew) {
            keyInput.addEventListener('input', function (e) { draft.key = e.target.value; });
        } else {
            keyInput.setAttribute('disabled', 'disabled');
        }
        keyRow.appendChild(keyInput);
        wrap.appendChild(keyRow);

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.permissionKeyFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('permission_key_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var descriptionRow = mk('div', { class: 'k9tablet-theme-field' + (state.permissionKeyFieldError === 'description' ? ' k9tablet-theme-field--invalid' : '') });
        descriptionRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('permission_key_description_label') }));
        var descriptionInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('permission_key_description_placeholder'), maxlength: '300' } });
        descriptionInput.value = draft.description || '';
        descriptionInput.addEventListener('input', function (e) { draft.description = e.target.value; });
        descriptionRow.appendChild(descriptionInput);
        wrap.appendChild(descriptionRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('permission_key_save_label'), 'k9tablet-btn', savePermissionKeyDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('permission_key_cancel_label'), 'k9tablet-link-btn', closePermissionKeyDraft));
        wrap.appendChild(actions);

        return wrap;
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

    // ---- K9 Supply Shop ITEM CATALOG editing screen (high command only) ----
    // server/equipmentshop.lua's own "EQUIPMENT SHOP ITEM CATALOG" section
    // -- owner's own words: "give high command real control over the
    // equipment shop." Sits alongside the Shop Locations screen above --
    // same table + inline row actions + add/edit form below shape as the
    // Certification Tier screen (this is the closest analogue: a
    // DB-backed catalog with list/upsert/reorder/tombstone), reusing the
    // SAME field/form/table CSS classes -- no new CSS introduced for this
    // screen either.
    //
    // TOMBSTONE, HANDLED HONESTLY: server/equipmentshop.lua's own
    // ListEquipmentShopItems (tablet:equipmentShopItemsList's response)
    // NEVER includes a tombstoned item_key at all -- the server's own
    // catalog merge excludes it entirely before this page ever sees it
    // (see that file's own "TOMBSTONE, NOT HARD-DELETE" section: a
    // tombstoned row is not a row with a flag, it is simply absent from
    // the merged map). There is therefore no "retired" STATE this screen
    // could render inline for a row still present in `state.shopItems` --
    // a successful delete's own response (`result.items`) is the new,
    // already-tombstone-filtered list, and this screen simply shows one
    // fewer row afterward, exactly like server/certtiers.lua's own
    // DeleteTier/certTiersDelete does for a tier. This is disclosed here
    // rather than silently assumed: existing purchases/grants referencing
    // a retired item key are NEVER affected by this (ox_inventory's own
    // already-granted item stays in whatever bag it is in; nothing in
    // this resource's own schema references an item_key at all -- see
    // that file's header) -- the tombstone protects the SELLING side
    // only, which is exactly the side this screen edits.
    //
    // REORDER VALIDITY BY CONSTRUCTION: moveShopItem() below, like
    // moveCertTier() above, ALWAYS submits the full current key list (via
    // state.shopItems, sortOrder-ascending) with two entries swapped --
    // never a partial list -- so this UI is structurally incapable of
    // sending anything server/equipmentshop.lua's own
    // equipmentShopItemsReorder (which refuses any partial/duplicated
    // permutation) would ever reject for that reason.

    /**
     * Renders the LIVE catalogue from state.shopItems (populated by
     * loadEquipmentShopItems() -- NEVER hardcoded: an operator can
     * add/retire/reprice/reorder items at runtime, and this page must
     * reflect that with no UI change), a per-row Move Up/Move Down/Edit/
     * Delete set of controls, and (when a draft is open) the add/edit
     * form below the table. server/equipmentshop.lua's own
     * CanManageShopItems is the real authorization gate, re-checked on
     * every one of the four callbacks this screen calls -- see THE
     * SECURITY RULE.
     */
    function buildShopItemsScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('shop_items_heading') }));

        if (state.shopItemsLoading && !state.shopItems) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.shopItemsError && !state.shopItems) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: shopItemErrorText(state.shopItemsError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadEquipmentShopItems));
            return wrap;
        }
        if (!state.shopItems) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildShopItemsTable());

        if (state.shopItemDraft) {
            wrap.appendChild(buildShopItemDraftForm());
        } else {
            wrap.appendChild(mkButton(S('shop_items_add_label'), 'k9tablet-btn', openNewShopItemDraft, { disabled: state.pendingAction }));
        }

        return wrap;
    }

    function buildShopItemsTable() {
        if (state.shopItems.length === 0) {
            var empty = mk('div', {});
            empty.appendChild(mk('p', { class: 'k9tablet-muted', text: S('shop_items_empty') }));
            return empty;
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_position'), S('column_key'), S('column_label'), S('column_price'), S('column_currency'),
            S('column_required_tier'), S('column_required_specialization'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.shopItems.length; i++) {
            tbody.appendChild(buildShopItemRow(state.shopItems[i], i));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {number|null|undefined} price @returns {string} */
    function formatShopItemPrice(price) {
        if (typeof price !== 'number' || !isFinite(price)) return '';
        return String(price);
    }

    /** @param {object} item @param {number} index */
    function buildShopItemRow(item, index) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(index + 1) }));
        tr.appendChild(mk('td', { text: item.key }));
        tr.appendChild(mk('td', { text: (typeof item.label === 'string') ? item.label : item.key }));

        var priceTd = mk('td', { text: formatShopItemPrice(item.price) });
        // ZERO IS A LEGAL, DELIBERATE PRICE (a free item) -- see
        // server/equipmentshop.lua's own "PRICE VALIDATION" section. Never
        // hidden or treated as a display bug -- called out with its own
        // small badge so an operator sees at a glance that a 0 is
        // intentional, not a blank/error.
        if (item.price === 0) {
            priceTd.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('shop_item_price_free_badge') + ')' }));
        }
        tr.appendChild(priceTd);

        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof item.currency === 'string' && item.currency.length > 0) ? item.currency : S('shop_item_currency_default_note') }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof item.requiredTierKey === 'string' && item.requiredTierKey.length > 0) ? tierDisplayLabel(item.requiredTierKey) : S('shop_item_no_requirement') }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof item.requiredSpecialization === 'string' && item.requiredSpecialization.length > 0) ? specializationDisplayLabel(item.requiredSpecialization) : S('shop_item_no_requirement') }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('shop_item_move_up_label'), 'k9tablet-btn', function () {
            moveShopItem(index, -1);
        }, { disabled: state.pendingAction || index === 0, title: S('shop_item_move_up_title') }));
        actionsTd.appendChild(mkButton(S('shop_item_move_down_label'), 'k9tablet-btn', function () {
            moveShopItem(index, 1);
        }, { disabled: state.pendingAction || index === state.shopItems.length - 1, title: S('shop_item_move_down_title') }));
        actionsTd.appendChild(mkButton(S('shop_item_edit_label'), 'k9tablet-btn', function () {
            openEditShopItemDraft(item);
        }, { disabled: state.pendingAction }));
        actionsTd.appendChild(mkConfirmButton(S('shop_item_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            deleteShopItem(item.key);
        }, { disabled: state.pendingAction }));

        // A delete/reorder REFUSAL renders INLINE on THIS specific row --
        // "cannot, and here is why" -- same convention as
        // certTierActionError/shopLocationActionError above.
        if (state.shopItemActionError && state.shopItemActionError.key === item.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.shopItemActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** 1-50 chars, lowercase-start, lowercase/digit/underscore only -- a
     * CLIENT-SIDE MIRROR of server/equipmentshop.lua's own
     * IsValidShopItemKey, a UX convenience only (THE SECURITY RULE: the
     * server re-validates this independently regardless of what this
     * check does or does not catch first).
     * @param {any} key @returns {boolean} */
    function isValidShopItemKeyClient(key) {
        return typeof key === 'string' && key.length >= 1 && key.length <= 50 && /^[a-z][a-z0-9_]*$/.test(key);
    }

    /** CLIENT-SIDE MIRROR of server/equipmentshop.lua's own
     * IsSafeShortString -- same reasoning as isSafeShortStringForXpTier
     * above (this codebase's own convention: each screen keeps its own
     * tiny, self-contained copy rather than a shared cross-screen call).
     * @param {any} value @param {number} maxLen @returns {boolean} */
    function isSafeShortStringForShopItem(value, maxLen) {
        if (typeof value !== 'string') return false;
        var len = value.length;
        if (len === 0 || len > maxLen) return false;
        if (/[<>&"'`\r\n\t]/.test(value)) return false;
        for (var i = 0; i < len; i++) {
            var code = value.charCodeAt(i);
            if (code < 0x20 || code === 0x7F) return false;
        }
        return true;
    }

    // Mirrors server/equipmentshop.lua's own MAX_SHOP_ITEM_PRICE exactly
    // -- see that file's own "PRICE VALIDATION" section. ZERO IS
    // DELIBERATELY NOT excluded by this check (a free item is a real,
    // documented, legitimate price) -- only non-numbers, NaN,
    // +/-infinity, negatives, fractions, and anything above this ceiling
    // are rejected.
    var SHOP_ITEM_MAX_PRICE = 1000000000;

    /** @param {any} value @returns {boolean} */
    function isValidShopItemPriceClient(value) {
        return typeof value === 'number' && isFinite(value) && value >= 0 && value <= SHOP_ITEM_MAX_PRICE && value === Math.floor(value);
    }

    /** Opens a BLANK draft for a brand-new item. requiredTierKey/
     * requiredSpecialization start at '' (the draft form's own "None"
     * option) -- never null -- so a plain `.value` read on the <select>
     * always works. @see buildShopItemDraftForm */
    function openNewShopItemDraft() {
        state.shopItemDraft = { key: '', price: '', label: '', currency: '', requiredTierKey: '', requiredSpecialization: '', isNew: true };
        state.shopItemFieldError = null;
        render();
    }

    /** Opens a draft pre-filled from an EXISTING item row -- a COPY of its
     * fields, never the live object, so Cancel never mutates
     * state.shopItems. Pre-filling EVERY field (not just the ones an
     * operator intends to touch) matters here specifically:
     * server/equipmentshop.lua's own equipmentShopItemsUpsert REPLACES
     * label/currency/requiredTierKey/requiredSpecialization wholesale from
     * whatever this ONE payload sends (never a partial merge with the
     * existing row) -- an edit draft that started blank on, say, currency
     * would silently CLEAR an existing currency override on Save, not
     * leave it untouched. @param {object} item */
    function openEditShopItemDraft(item) {
        state.shopItemDraft = {
            key: item.key,
            price: formatShopItemPrice(item.price),
            label: (typeof item.label === 'string' && item.label !== item.key) ? item.label : '',
            currency: (typeof item.currency === 'string') ? item.currency : '',
            requiredTierKey: (typeof item.requiredTierKey === 'string') ? item.requiredTierKey : '',
            requiredSpecialization: (typeof item.requiredSpecialization === 'string') ? item.requiredSpecialization : '',
            isNew: false,
        };
        state.shopItemFieldError = null;
        render();
    }

    function closeShopItemDraft() {
        state.shopItemDraft = null;
        state.shopItemFieldError = null;
        render();
    }

    /** Add/edit form -- see openNewShopItemDraft()/openEditShopItemDraft()
     * for how state.shopItemDraft is populated. `key` is editable only for
     * a BRAND NEW item: server/equipmentshop.lua's own
     * equipmentShopItemsUpsert has no "rename" concept (submitting a
     * DIFFERENT key while editing would create a second, separate item,
     * not rename this one), same reasoning as the cert-tier/permission-key
     * forms' own key input. */
    function buildShopItemDraftForm() {
        var draft = state.shopItemDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var keyRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'key' ? ' k9tablet-theme-field--invalid' : '') });
        keyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_key_label') }));
        var keyInput = mk('input', { class: 'k9tablet-cert-tier-key-input', attrs: { type: 'text', placeholder: S('shop_item_key_placeholder'), maxlength: '50' } });
        keyInput.value = draft.key;
        if (draft.isNew) {
            keyInput.addEventListener('input', function (e) { draft.key = e.target.value; });
        } else {
            keyInput.setAttribute('disabled', 'disabled');
        }
        keyRow.appendChild(keyInput);
        wrap.appendChild(keyRow);

        var priceRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'price' ? ' k9tablet-theme-field--invalid' : '') });
        priceRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_price_label') }));
        var priceInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: '1', min: '0', max: String(SHOP_ITEM_MAX_PRICE) } });
        priceInput.value = draft.price;
        priceInput.addEventListener('input', function (e) { draft.price = e.target.value; });
        priceRow.appendChild(priceInput);
        wrap.appendChild(priceRow);

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_item_label_placeholder'), maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var currencyRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'currency' ? ' k9tablet-theme-field--invalid' : '') });
        currencyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_currency_label') }));
        var currencyInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_item_currency_placeholder'), maxlength: '50' } });
        currencyInput.value = draft.currency;
        currencyInput.addEventListener('input', function (e) { draft.currency = e.target.value; });
        currencyRow.appendChild(currencyInput);
        wrap.appendChild(currencyRow);

        // Required Tier -- populated from state.certTiers (opportunistic,
        // see the tab's own click handler comment) -- a "None" option is
        // ALWAYS first, never omitted, since a purchase requirement is
        // optional. ALWAYS a real, editable <select>, never a read-only
        // text fallback -- see the RETIRED REFERENCE note just below for
        // why a read-only fallback would itself be a hazard here.
        //
        // RETIRED REFERENCE: `draft.requiredTierKey` may name a tier this
        // screen's own (possibly stale, possibly never-loaded)
        // state.certTiers does not currently contain -- e.g. a tier
        // retired by a different high-command session since this item was
        // last saved, or a session where the certTiersList fetch was
        // denied/still in flight. Per this function's own header ("an
        // edit draft always starts pre-filled... equipmentShopItemsUpsert
        // REPLACES ... wholesale from whatever this ONE payload sends"),
        // silently DROPPING it from the <select> would make a plain Save
        // (touching nothing else) silently CLEAR a real, currently-
        // configured purchase requirement the operator never asked to
        // remove -- so it is always added as its own, clearly-labelled
        // option and pre-selected instead: visible, and only ever cleared
        // by a deliberate choice of "None", never a hidden side effect.
        var tierRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'requiredTierKey' ? ' k9tablet-theme-field--invalid' : '') });
        tierRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_required_tier_label') }));
        var tierSelect = mk('select', { class: 'k9tablet-role-select' });
        var noneTierOption = mk('option', { text: S('shop_item_no_requirement') });
        noneTierOption.setAttribute('value', '');
        tierSelect.appendChild(noneTierOption);
        var knownTierKeys = {};
        if (Array.isArray(state.certTiers)) {
            for (var ti = 0; ti < state.certTiers.length; ti++) {
                var tierEntry = state.certTiers[ti];
                if (!tierEntry || typeof tierEntry.key !== 'string' || tierEntry.key.length === 0) continue;
                knownTierKeys[tierEntry.key] = true;
                var tierOption = mk('option', { text: (typeof tierEntry.label === 'string' && tierEntry.label.length > 0) ? tierEntry.label : tierEntry.key });
                tierOption.setAttribute('value', tierEntry.key);
                tierSelect.appendChild(tierOption);
            }
        }
        if (draft.requiredTierKey.length > 0 && !knownTierKeys[draft.requiredTierKey]) {
            var retiredTierOption = mk('option', { text: tierDisplayLabel(draft.requiredTierKey) + ' ' + S('shop_item_retired_reference_badge') });
            retiredTierOption.setAttribute('value', draft.requiredTierKey);
            tierSelect.appendChild(retiredTierOption);
        }
        tierSelect.value = draft.requiredTierKey;
        tierSelect.addEventListener('input', function (e) { draft.requiredTierKey = e.target.value; });
        tierRow.appendChild(tierSelect);
        wrap.appendChild(tierRow);

        // Required Specialization -- SAME shape, SAME RETIRED REFERENCE
        // safeguard, as Required Tier immediately above. Populated from
        // state.specializations (Config.K9Specializations, sent verbatim
        // at tablet:open -- always available with no separate fetch,
        // unlike the tier catalog, but an operator can still rename/remove
        // a specialization key in config.lua between this item's last
        // save and now, so the same hazard applies).
        var specRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'requiredSpecialization' ? ' k9tablet-theme-field--invalid' : '') });
        specRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_required_specialization_label') }));
        var specCatalog = (state.specializations && typeof state.specializations === 'object') ? state.specializations : {};
        var specSelect = mk('select', { class: 'k9tablet-role-select' });
        var noneSpecOption = mk('option', { text: S('shop_item_no_requirement') });
        noneSpecOption.setAttribute('value', '');
        specSelect.appendChild(noneSpecOption);
        var knownSpecKeys = {};
        for (var specKey in specCatalog) {
            if (!Object.prototype.hasOwnProperty.call(specCatalog, specKey)) continue;
            knownSpecKeys[specKey] = true;
            var specOption = mk('option', { text: specializationDisplayLabel(specKey) });
            specOption.setAttribute('value', specKey);
            specSelect.appendChild(specOption);
        }
        if (draft.requiredSpecialization.length > 0 && !knownSpecKeys[draft.requiredSpecialization]) {
            var retiredSpecOption = mk('option', { text: specializationDisplayLabel(draft.requiredSpecialization) + ' ' + S('shop_item_retired_reference_badge') });
            retiredSpecOption.setAttribute('value', draft.requiredSpecialization);
            specSelect.appendChild(retiredSpecOption);
        }
        specSelect.value = draft.requiredSpecialization;
        specSelect.addEventListener('input', function (e) { draft.requiredSpecialization = e.target.value; });
        specRow.appendChild(specSelect);
        wrap.appendChild(specRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('shop_item_save_label'), 'k9tablet-btn', saveShopItemDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('shop_item_cancel_label'), 'k9tablet-link-btn', closeShopItemDraft));
        wrap.appendChild(actions);

        return wrap;
    }

    /** @param {object|undefined} result @returns {string} */
    function shopItemErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('shop_item_error_denied');
            case 'rate_limited': return S('shop_item_error_rate_limited');
            case 'invalid_payload': return S('shop_item_error_invalid_payload');
            case 'invalid_key': return S('shop_item_error_invalid_key');
            case 'invalid_price': return S('shop_item_error_invalid_price');
            case 'invalid_label': return S('shop_item_error_invalid_label');
            case 'invalid_currency': return S('shop_item_error_invalid_currency');
            case 'invalid_required_tier': return S('shop_item_error_invalid_required_tier');
            case 'invalid_required_specialization': return S('shop_item_error_invalid_required_specialization');
            case 'busy': return S('shop_item_error_busy');
            case 'too_many_items': return S('shop_item_error_too_many_items');
            case 'unknown_item': return S('shop_item_error_unknown_item');
            case 'must_include_every_item': return S('shop_item_error_must_include_every_item');
            case 'invalid_key_set': return S('shop_item_error_invalid_key_set');
            case 'db_error': return S('shop_item_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function shopItemFieldFromError(errorCode) {
        if (errorCode === 'invalid_key') return 'key';
        if (errorCode === 'invalid_price') return 'price';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_currency') return 'currency';
        if (errorCode === 'invalid_required_tier') return 'requiredTierKey';
        if (errorCode === 'invalid_required_specialization') return 'requiredSpecialization';
        return null;
    }

    /**
     * Fetched fresh every time the Shop Items tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers()/loadShopLocations() above. High command only
     * (server-side gate -- server/equipmentshop.lua's own
     * CanManageShopItems).
     */
    function loadEquipmentShopItems() {
        state.shopItemsLoading = true;
        state.shopItemsError = null;
        render();

        fetchNui('tablet:equipmentShopItemsList', {}).then(function (result) {
            state.shopItemsLoading = false;
            if (!result || result.ok !== true) {
                state.shopItemsError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.shopItems = Array.isArray(result.items) ? result.items : [];
            render();
        });
    }

    /**
     * Saves the shop-item draft form's current working copy. NOT the
     * generic runMutation() helper: a rejected save carries a `field`
     * naming which of the six inputs failed, which runMutation's own
     * message-only handling has no slot for, same reasoning as
     * saveCertTierDraft()/savePermissionKeyDraft() above. Every check
     * below mirrors server/equipmentshop.lua's own validators
     * (IsValidShopItemKey/IsValidShopItemPrice/IsSafeShortString) as a UX
     * CONVENIENCE ONLY -- THE SECURITY RULE: the server independently
     * re-validates every one of these fields regardless of what this
     * function does or does not catch first. Blank
     * label/currency/requiredTierKey/requiredSpecialization are sent as
     * `undefined` (omitted), never `''` -- matching
     * server/equipmentshop.lua's own "nil means no override" optional-field
     * contract for every one of those four fields.
     */
    function saveShopItemDraft() {
        if (state.pendingAction || !state.shopItemDraft) return;
        var draft = state.shopItemDraft;

        if (!isValidShopItemKeyClient(draft.key)) {
            failShopItemDraft('key', S('shop_item_error_invalid_key'));
            return;
        }

        var priceNum = Number(draft.price);
        if (!isValidShopItemPriceClient(priceNum)) {
            failShopItemDraft('price', S('shop_item_error_invalid_price'));
            return;
        }

        var label;
        if (typeof draft.label === 'string' && draft.label.trim().length > 0) {
            if (!isSafeShortStringForShopItem(draft.label, 60)) {
                failShopItemDraft('label', S('shop_item_error_invalid_label'));
                return;
            }
            label = draft.label;
        }

        var currency;
        if (typeof draft.currency === 'string' && draft.currency.trim().length > 0) {
            if (!isValidShopItemKeyClient(draft.currency)) {
                failShopItemDraft('currency', S('shop_item_error_invalid_currency'));
                return;
            }
            currency = draft.currency;
        }

        var requiredTierKey;
        if (typeof draft.requiredTierKey === 'string' && draft.requiredTierKey.length > 0) {
            requiredTierKey = draft.requiredTierKey;
        }

        var requiredSpecialization;
        if (typeof draft.requiredSpecialization === 'string' && draft.requiredSpecialization.length > 0) {
            requiredSpecialization = draft.requiredSpecialization;
        }

        state.pendingAction = true;
        state.shopItemFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = { key: draft.key, price: priceNum };
        if (label !== undefined) payload.label = label;
        if (currency !== undefined) payload.currency = currency;
        if (requiredTierKey !== undefined) payload.requiredTierKey = requiredTierKey;
        if (requiredSpecialization !== undefined) payload.requiredSpecialization = requiredSpecialization;

        fetchNui('tablet:equipmentShopItemsUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.shopItems = Array.isArray(result.items) ? result.items : state.shopItems;
                state.shopItemDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.shopItemFieldError = shopItemFieldFromError(result && result.error);
                state.actionNotice = { kind: 'error', text: shopItemErrorText(result) };
            }
            render();
        });
    }

    /** Sets the field-highlight/top-banner error pair for the CURRENTLY
     * open shop-item draft in one place -- shared by every client-side
     * pre-check branch in saveShopItemDraft() above, so a pre-check
     * failure and a server refusal for the SAME reason render
     * byte-identically. @param {string} field @param {string} text */
    function failShopItemDraft(field, text) {
        state.shopItemFieldError = field;
        state.actionNotice = { kind: 'error', text: text };
        render();
    }

    /**
     * Swaps item `index` with its immediate neighbour (`direction` is -1
     * for up / +1 for down) and submits the FULL resulting key order --
     * server/equipmentshop.lua's own equipmentShopItemsReorder REFUSES any
     * partial reorder (must be an exact permutation of every currently-known
     * item), so this always sends every key, never just the two that moved.
     * A no-op past either end of the list -- also enforced by each row's
     * own `disabled` state in buildShopItemRow, this is the real,
     * server-call-blocking guard, that being a convenience only.
     * @param {number} index @param {number} direction -1 | 1
     */
    function moveShopItem(index, direction) {
        if (state.pendingAction || !state.shopItems) return;
        var targetIndex = index + direction;
        if (targetIndex < 0 || targetIndex >= state.shopItems.length) return;

        var orderedKeys = [];
        for (var i = 0; i < state.shopItems.length; i++) orderedKeys.push(state.shopItems[i].key);
        var moved = orderedKeys[index];
        orderedKeys[index] = orderedKeys[targetIndex];
        orderedKeys[targetIndex] = moved;

        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopItemsReorder', { orderedKeys: orderedKeys }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.shopItems = Array.isArray(result.items) ? result.items : state.shopItems;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: shopItemErrorText(result) };
            }
            render();
        });
    }

    /**
     * Deletes (tombstones) item `key`. server/equipmentshop.lua's own
     * ShopItemsDelete carries NO reference-count refusal (unlike
     * deleteCertTier()'s own tier_in_use -- see that file's own
     * "TOMBSTONE, NOT HARD-DELETE" section for exactly why this schema has
     * nothing an item_key delete could ever strand), so any failure here
     * is a plain refusal/error, rendered INLINE on that item's own row
     * (state.shopItemActionError), same "cannot, and here is why"
     * convention as deleteCertTier()/deletePermissionKey() above.
     * @param {string} key
     */
    function deleteShopItem(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.shopItemActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopItemsDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.shopItems = Array.isArray(result.items) ? result.items : state.shopItems;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = shopItemErrorText(result);
                state.shopItemActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
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
            // max is the REAL, server-reported cap once known -- see
            // auditEffectiveCap()'s own comment for why this is only ever
            // AUDIT_LIMIT_MAX_FALLBACK's hardcoded guess before the FIRST
            // successful query this session (or if a response is ever
            // missing `cap`, an older server build). This attribute is a
            // UX hint only, same as every other client-side clamp on this
            // page -- server/admin.lua's own ClampLimit is the real bound.
            var limitInput = mk('input', {
                class: 'k9tablet-audit-limit-input',
                attrs: { type: 'number', min: String(AUDIT_LIMIT_MIN), max: String(auditEffectiveCap()) },
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
     * "You asked for 500, here are the first 100" -- this pass's own
     * explicit requirement: a caller finding out their result set was
     * silently cut short is the bug, not the cutting itself (the cap is a
     * real, necessary DoS guard -- see server/admin.lua's own header). Only
     * ever called when `result.truncated === true` (see buildAuditResults()
     * above), so `result.actualLimit` is always a real server-reported
     * number here -- `result.requestedLimit` is the value THIS PAGE sent
     * for the request that produced `result` (closured at the call site in
     * runAuditQuery(), never re-derived from the CURRENT `state.auditLimit`,
     * which may already have moved on to a different typed value by the
     * time this renders).
     * @param {{requestedLimit:number, actualLimit:number}} result
     * @returns {string}
     */
    function auditTruncatedText(result) {
        return formatTemplate(S('audit_truncated_notice'), {
            requested: (typeof result.requestedLimit === 'number') ? result.requestedLimit : '?',
            shown: (typeof result.actualLimit === 'number') ? result.actualLimit : '?',
        });
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
        // TRUNCATION NOTICE (this pass) -- "you asked for 500, here are the
        // first 100" is information the operator needs; a silently short
        // list is the bug this pass exists to fix. `truncated` comes
        // straight from the server's own tabletAudit* response (see this
        // file's header NUI CONTRACT note) -- never inferred client-side
        // from rows.length, which cannot tell "there were exactly `cap`
        // matching rows" apart from "there were more than that".
        if (state.auditResult.truncated) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: auditTruncatedText(state.auditResult) }));
        }
        if (state.auditResult.rows.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_result_empty') }));
            return wrap;
        }
        wrap.appendChild(buildAuditResultTable(state.auditMode, state.auditResult.rows));
        return wrap;
    }

    // ---- XP Rank Editor screen (high command only) ----
    // Owner-directed "...set experience level for each rank up" pass,
    // server/xptiers.lua -- the OTHER half of the same quote the
    // permission-key catalog screen above answers for permission keys.
    // Renders the LIVE four-rank ladder from state.xpTiers (populated by
    // loadXpTiers() below -- never hardcoded here, see that function's own
    // comment), a per-row Edit control, and (when a draft is open) the
    // single open rank's edit form below the table. There is no add/
    // remove/reorder for this ladder (server/xptiers.lua's own header
    // "SCOPE DECISION" -- fixed cardinality, four ranks, edited in place),
    // so this screen is deliberately simpler than buildCertTiersScreen()
    // above: no "Add New" button, no move-up/down, no delete.
    // server/xptiers.lua's own CanManageXPTiers is the real authorization
    // gate, re-checked on every one of the two callbacks this screen
    // calls -- see THE SECURITY RULE.

    /** Mirrors server/xptiers.lua's own MAX_SPEED_SCENT_MULTIPLIER exactly
     * -- a UX convenience only (THE SECURITY RULE): kept in exact lockstep
     * with that file's own constant so this page's own pre-check can never
     * be looser OR tighter than what the server will actually accept, but
     * the server's own re-check of the CURRENT live ladder is what
     * actually matters regardless of what this page allows through. */
    var XP_TIER_MAX_SPEED_SCENT_MULTIPLIER = 3.0;

    /** Mirrors server/xptiers.lua's own MAX_MEDKIT_COOLDOWN_MULTIPLIER
     * exactly -- same posture as XP_TIER_MAX_SPEED_SCENT_MULTIPLIER above. */
    var XP_TIER_MAX_MEDKIT_COOLDOWN_MULTIPLIER = 1.0;

    function buildXpTiersScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('xp_tiers_heading') }));

        // THE ALREADY-PROMOTED PLAYER -- surfaced per the server side's own
        // explicit ask: a successful upsert's `warning` (present whenever
        // at least one currently-connected K9 was just re-ranked LOWER by
        // this exact edit -- server/xptiers.lua's own header) is
        // non-optional and must not be silently discarded -- its own
        // prominent banner, SAME treatment certTiersReorder's own warning
        // already gets above, never folded into the generic
        // (easy-to-miss-amid-other-clicks) actionNotice.
        if (state.xpTierWarning) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.xpTierWarning }));
        }

        if (state.xpTiersLoading && !state.xpTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.xpTiersError && !state.xpTiers) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: xpTierErrorText(state.xpTiersError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadXpTiers));
            return wrap;
        }
        if (!state.xpTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildXpTiersTable());

        if (state.xpTierDraft) {
            wrap.appendChild(buildXpTierDraftForm());
        }

        return wrap;
    }

    function buildXpTiersTable() {
        if (state.xpTiers.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('xp_tiers_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_rank'), S('column_xp_threshold'), S('column_label'), S('column_speed_multiplier'),
            S('column_scent_range_multiplier'), S('column_medkit_cooldown_multiplier'), S('column_badge'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.xpTiers.length; i++) {
            tbody.appendChild(buildXpTierRow(state.xpTiers[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {{ordinal:number,xp:number,label:string,speedMultiplier:number,scentRangeMultiplier:number,medkitCooldownMultiplier?:number,badge?:string,xpLocked:boolean}} tier */
    function buildXpTierRow(tier) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(tier.ordinal) }));
        tr.appendChild(mk('td', { text: String(tier.xp) }));
        tr.appendChild(mk('td', { text: tier.label }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: String(tier.speedMultiplier) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: String(tier.scentRangeMultiplier) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (tier.medkitCooldownMultiplier === undefined || tier.medkitCooldownMultiplier === null) ? '' : String(tier.medkitCooldownMultiplier) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof tier.badge === 'string' && tier.badge.length > 0) ? tier.badge : '' }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('xp_tier_edit_label'), 'k9tablet-btn', function () {
            openXpTierEditDraft(tier);
        }, { disabled: state.pendingAction }));

        // An upsert REFUSAL (any of the 12 reasons server/xptiers.lua's own
        // xpTiersUpsert can return, INCLUDING a client-side pre-check
        // failure caught before the round trip -- see saveXpTierDraft()
        // below) renders INLINE on THIS specific rank's own row -- "cannot,
        // and here is why" -- same convention as certTierActionError/
        // permissionKeyActionError/shopLocationActionError above, alongside
        // the same text in the generic top-of-panel notice for visibility.
        if (state.xpTierActionError && state.xpTierActionError.ordinal === tier.ordinal) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.xpTierActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Edit form for the SINGLE open rank (state.xpTierDraft) -- see
     * openXpTierEditDraft() for how it is populated. `xp` renders GENUINELY
     * read-only (a `disabled` input, exactly matching the cert-tier form's
     * own disabled key input for an existing tier) whenever
     * `draft.xpLocked` is true (rank 1 only, server/xptiers.lua's own
     * mandatory `xp == 0` baseline) -- saveXpTierDraft() below never even
     * reads this field's own value for a locked rank, always submitting 0,
     * so there is no path through this form that could ever send an edit
     * this server will always refuse anyway. Label/multipliers/badge stay
     * fully editable regardless of xpLocked. */
    function buildXpTierDraftForm() {
        var draft = state.xpTierDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var xpRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'xp' ? ' k9tablet-theme-field--invalid' : '') });
        xpRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_xp_label') }));
        var xpInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: '1', min: '0' } });
        xpInput.value = draft.xp;
        if (draft.xpLocked) {
            xpInput.setAttribute('disabled', 'disabled');
        } else {
            xpInput.addEventListener('input', function (e) { draft.xp = e.target.value; });
        }
        xpRow.appendChild(xpInput);
        wrap.appendChild(xpRow);
        if (draft.xpLocked) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('xp_tier_xp_locked_hint') }));
        }

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var speedRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'speedMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        speedRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_speed_multiplier_label') }));
        var speedInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0' } });
        speedInput.value = draft.speedMultiplier;
        speedInput.addEventListener('input', function (e) { draft.speedMultiplier = e.target.value; });
        speedRow.appendChild(speedInput);
        wrap.appendChild(speedRow);

        var scentRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'scentRangeMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        scentRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_scent_range_multiplier_label') }));
        var scentInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0' } });
        scentInput.value = draft.scentRangeMultiplier;
        scentInput.addEventListener('input', function (e) { draft.scentRangeMultiplier = e.target.value; });
        scentRow.appendChild(scentInput);
        wrap.appendChild(scentRow);

        var medkitRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'medkitCooldownMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        medkitRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_medkit_cooldown_multiplier_label') }));
        var medkitInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0', placeholder: S('xp_tier_medkit_cooldown_multiplier_placeholder') } });
        medkitInput.value = draft.medkitCooldownMultiplier;
        medkitInput.addEventListener('input', function (e) { draft.medkitCooldownMultiplier = e.target.value; });
        medkitRow.appendChild(medkitInput);
        wrap.appendChild(medkitRow);

        var badgeRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'badge' ? ' k9tablet-theme-field--invalid' : '') });
        badgeRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_badge_label') }));
        var badgeInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '30', placeholder: S('xp_tier_badge_placeholder') } });
        badgeInput.value = draft.badge;
        badgeInput.addEventListener('input', function (e) { draft.badge = e.target.value; });
        badgeRow.appendChild(badgeInput);
        wrap.appendChild(badgeRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('xp_tier_save_label'), 'k9tablet-btn', saveXpTierDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('xp_tier_cancel_label'), 'k9tablet-link-btn', closeXpTierDraft));
        wrap.appendChild(actions);

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
            // CLIENT-LOCAL role signal -- client/tablet.lua's own
            // ResolveLocalRoleFlags() enriches this exact response with
            // these two fields; see state.isK9Model's own doc comment
            // above for why this is cosmetic/framing only.
            state.isK9Model = result.isK9Model === true;
            state.isPartnered = result.isPartnered === true;

            // Config.CommandTablet.highCommandCommand shortcut (this pass)
            // -- CONSUMED here, exactly once per open, strictly AFTER the
            // server's own viewer.isHighCommand for THIS caller is known.
            // This is presentation only: it decides which screen to land
            // on, never whether the request above succeeded or what data
            // it returned -- see THE SECURITY RULE at the top of this file
            // and client/tablet.lua's own NUI CONTRACT note on
            // `requestedView`. A caller who is genuinely high command
            // lands on the console tab, pre-loaded; anyone else typed the
            // High Command shortcut without holding the access it opens to
            // -- refused with a plain, visible notice, never a blank or
            // broken screen, and left on the exact same screen the
            // ordinary command already lands everyone on by default (see
            // handleOpen()'s own `state.screen` reset) -- never a second,
            // different "consolation" view invented just for this path.
            if (state.requestedView === 'highCommand') {
                state.requestedView = null;
                if (state.viewer && state.viewer.isHighCommand === true) {
                    state.screen = 'console';
                    render();
                    loadRoster(state.rosterQuery);
                    return;
                }
                state.actionNotice = { kind: 'error', text: S('high_command_required_notice') };
            }

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
            // Opportunistic, best-effort: populates state.permissionKeys
            // for buildCapabilityList()'s own merged rendering (the
            // Permission Keys tab shares this exact same state -- see
            // that tab's loadPermissionKeys() doc comment). Gated on
            // isHighCommand, unlike loadCertTiers() just below, because
            // ONLY a high-command viewer ever reaches buildCapabilityList
            // at all (see buildPersonScreen()) -- a non-high-command
            // caller has nothing here to populate. A failed/denied fetch
            // leaves state.permissionKeys exactly as it was (usually
            // null); resolveCapabilityRows() falls back to rendering just
            // the four shipped capabilities in that case, never an empty
            // panel.
            loadPermissionKeys();
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

    /** Fetched fresh every time the Permission Keys tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers() just above: the four admin capability names are
     * Config.Permissions defaults merged with database overrides (database
     * wins, per server/permissionkeycatalog.lua's own header), and high
     * command can add/relabel/retire keys at runtime -- a list captured
     * once here would already be stale the moment anyone does. High
     * command only (server/permissionkeycatalog.lua's own
     * CanManagePermissionKeys re-verifies this on every one of the three
     * callbacks regardless of whether this ever loads). */
    function loadPermissionKeys() {
        state.permissionKeysLoading = true;
        state.permissionKeysError = null;
        render();

        fetchNui('tablet:permKeysList', {}).then(function (result) {
            state.permissionKeysLoading = false;
            if (!result || result.ok !== true) {
                state.permissionKeysError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.permissionKeys = Array.isArray(result.keys) ? result.keys : [];
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

    /** @param {object|undefined} result @returns {string} */
    function permissionKeyErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('permission_key_error_denied');
            case 'rate_limited': return S('permission_key_error_rate_limited');
            case 'invalid_key': return S('permission_key_error_invalid_key');
            case 'invalid_label': return S('permission_key_error_invalid_label');
            case 'invalid_description': return S('permission_key_error_invalid_description');
            case 'busy': return S('permission_key_error_busy');
            case 'too_many_keys': return S('permission_key_error_too_many_keys');
            case 'unknown_key': return S('permission_key_error_unknown_key');
            // 'reserved_namespace'/'unknown_key' are REFUSALS ("cannot, and
            // here is why"), not generic failures -- same posture as
            // certTierErrorText's own 'protected_tier'/'tier_in_use' above.
            case 'reserved_namespace': return S('permission_key_error_reserved_namespace');
            case 'invalid_payload': return S('permission_key_error_invalid_payload');
            case 'db_error': return S('permission_key_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function permissionKeyFieldFromError(errorCode) {
        if (errorCode === 'invalid_key' || errorCode === 'reserved_namespace') return 'key';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_description') return 'description';
        return null;
    }

    /** Opens a BLANK draft for a brand-new permission key. @see buildPermissionKeyDraftForm */
    function openNewPermissionKeyDraft() {
        state.permissionKeyDraft = { key: '', label: '', description: '', isNew: true };
        state.permissionKeyFieldError = null;
        render();
    }

    /** Opens a draft pre-filled from an EXISTING catalog row. @param {object} entry */
    function openPermissionKeyEditDraft(entry) {
        state.permissionKeyDraft = { key: entry.key, label: entry.label, description: entry.description || '', isNew: false };
        state.permissionKeyFieldError = null;
        render();
    }

    function closePermissionKeyDraft() {
        state.permissionKeyDraft = null;
        state.permissionKeyFieldError = null;
        render();
    }

    /**
     * Saves the permission-key draft form's current working copy. NOT the
     * generic runMutation() helper: a rejected save carries a `field`
     * naming which input failed (key/label/description), which
     * runMutation's own message-only handling has no slot for, same
     * reasoning as saveCertTierDraft() above. An empty description is sent
     * as `undefined` (omitted), never `''` -- matching
     * server/permissionkeycatalog.lua's own "nil is stored as SQL NULL"
     * optional-field contract.
     */
    function savePermissionKeyDraft() {
        if (state.pendingAction || !state.permissionKeyDraft) return;
        var draft = state.permissionKeyDraft;

        state.pendingAction = true;
        state.permissionKeyFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = { key: draft.key, label: draft.label };
        if (typeof draft.description === 'string' && draft.description.length > 0) {
            payload.description = draft.description;
        }

        fetchNui('tablet:permKeysUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.permissionKeys = Array.isArray(result.keys) ? result.keys : state.permissionKeys;
                state.permissionKeyDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.permissionKeyFieldError = permissionKeyFieldFromError(result && result.error);
                state.actionNotice = { kind: 'error', text: permissionKeyErrorText(result) };
            }
            render();
        });
    }

    /**
     * Deletes permission key `key`. A REFUSAL (reserved_namespace --
     * should be unreachable through this UI, since this screen never lets
     * anyone create such a key in the first place; unknown_key) is
     * rendered INLINE on that key's own row (state.permissionKeyActionError),
     * same convention as deleteCertTier() above. Unlike that function,
     * this delete NEVER carries a reference-count refusal -- see
     * server/permissionkeycatalog.lua's own header "TOMBSTONE, NOT
     * REFERENCE-COUNTED" -- so there is no equivalent of tier_in_use here.
     * @param {string} key
     */
    function deletePermissionKey(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.permissionKeyActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:permKeysDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.permissionKeys = Array.isArray(result.keys) ? result.keys : state.permissionKeys;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = permissionKeyErrorText(result);
                state.permissionKeyActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
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

    /** @returns {number} the REAL effective ceiling server/admin.lua
     * enforces (that file's own HARD_MAX_RESULTS), learned from the `cap`
     * field of the most recent successful tabletAudit* response
     * (state.auditServerCap) -- falls back to AUDIT_LIMIT_MAX_FALLBACK's
     * hardcoded guess ONLY before any query has ever succeeded this
     * session, or if a response is ever missing `cap` entirely (a server
     * build predating this pass). See AUDIT_LIMIT_MAX_FALLBACK's own
     * comment for why that fallback is never assumed correct once a real
     * value is known, and this file's header NUI CONTRACT note on
     * tablet:auditCert/Partner/Search/Xp/Dept for where `cap` comes from. */
    function auditEffectiveCap() {
        return (typeof state.auditServerCap === 'number' && isFinite(state.auditServerCap) && state.auditServerCap >= AUDIT_LIMIT_MIN)
            ? state.auditServerCap
            : AUDIT_LIMIT_MAX_FALLBACK;
    }

    /** @param {*} value @returns {number} floored + clamped into
     * [AUDIT_LIMIT_MIN, auditEffectiveCap()]. Never lets an unclamped value
     * reach fetchNui(), even though server/admin.lua's own ClampLimit would
     * independently catch it anyway -- this page's own "make the UI agree
     * with what the server enforces" duty, per this task's instruction.
     * `Number('')` is NaN, `Number(undefined)` is NaN, `Math.floor(NaN)` is
     * NaN, and `NaN < x`/`NaN > x` are both false for any x -- so a
     * blank/garbage input falls through both clamp branches below unless
     * caught first, exactly the failure shape server/admin.lua's own
     * ClampLimit doc comment names for the identical reason; guarded here
     * the same way, once, via `isFinite`. */
    function clampAuditLimit(value) {
        var n = Math.floor(Number(value));
        var max = auditEffectiveCap();
        if (!isFinite(n)) return AUDIT_LIMIT_MIN;
        if (n < AUDIT_LIMIT_MIN) return AUDIT_LIMIT_MIN;
        if (n > max) return max;
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
            // Server-reported effective cap (server/admin.lua's own
            // HARD_MAX_RESULTS) -- learned here so the NEXT render's limit
            // input/clamp reflects the REAL ceiling rather than this page's
            // own AUDIT_LIMIT_MAX_FALLBACK guess. Absent on a response from
            // a server build predating this field -- silently keeps
            // whatever was already known (or the fallback) rather than
            // clobbering a good value with an invalid one.
            if (typeof result.cap === 'number' && isFinite(result.cap) && result.cap >= AUDIT_LIMIT_MIN) {
                state.auditServerCap = result.cap;
            }
            state.auditResult = {
                rows: Array.isArray(result.rows) ? result.rows : [],
                label: (typeof result.label === 'string') ? result.label : '',
                // TRUNCATION (this pass) -- see auditTruncatedText() above.
                // `truncated`/`actualLimit` are the server's OWN account of
                // what happened to THIS request; `requestedLimit` is the
                // `limit` THIS PAGE sent for it (closured from above --
                // always defined, even for 'xp', which simply never sets
                // `truncated` true since server/admin.lua's tabletAuditXp
                // never reports it).
                truncated: result.truncated === true,
                requestedLimit: limit,
                actualLimit: (typeof result.limit === 'number') ? result.limit : null,
            };
            render();
        });
    }

    /** Fetched fresh every time the XP Ranks tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers()/loadPermissionKeys() above: the four-rank ladder is
     * Config.XPTiers shipped defaults merged with k9_xp_tiers database
     * overrides (database wins, per server/xptiers.lua's own header), and
     * high command can retune any rank at runtime -- a list captured once
     * here would already be stale the moment anyone does. High command
     * only (server/xptiers.lua's own CanManageXPTiers re-verifies this on
     * every one of the two callbacks regardless of whether this ever
     * loads). */
    function loadXpTiers() {
        state.xpTiersLoading = true;
        state.xpTiersError = null;
        render();

        fetchNui('tablet:xpTiersList', {}).then(function (result) {
            state.xpTiersLoading = false;
            if (!result || result.ok !== true) {
                state.xpTiersError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.xpTiers = Array.isArray(result.tiers) ? result.tiers : [];
            render();
        });
    }

    /** @param {object|undefined} result @returns {string} */
    function xpTierErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('xp_tier_error_denied');
            case 'rate_limited': return S('xp_tier_error_rate_limited');
            case 'busy': return S('xp_tier_error_busy');
            case 'invalid_ordinal': return S('xp_tier_error_invalid_ordinal');
            case 'invalid_xp': return S('xp_tier_error_invalid_xp');
            // A REFUSAL ("cannot, and here is why" -- rank 1 must always be
            // exactly 0 XP), not a generic failure -- per this task's own
            // instruction, same posture as certTierErrorText's own
            // 'protected_tier'/'tier_in_use' above.
            case 'base_tier_xp_fixed': return S('xp_tier_error_base_tier_xp_fixed');
            case 'invalid_label': return S('xp_tier_error_invalid_label');
            case 'invalid_speed_multiplier': return S('xp_tier_error_invalid_speed_multiplier');
            case 'invalid_scent_range_multiplier': return S('xp_tier_error_invalid_scent_range_multiplier');
            case 'invalid_medkit_cooldown_multiplier': return S('xp_tier_error_invalid_medkit_cooldown_multiplier');
            case 'invalid_badge': return S('xp_tier_error_invalid_badge');
            case 'invalid_order': return S('xp_tier_error_invalid_order');
            case 'db_error': return S('xp_tier_error_db_error');
            case 'invalid_payload': return S('xp_tier_error_invalid_payload');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function xpTierFieldFromError(errorCode) {
        if (errorCode === 'invalid_xp' || errorCode === 'base_tier_xp_fixed') return 'xp';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_speed_multiplier') return 'speedMultiplier';
        if (errorCode === 'invalid_scent_range_multiplier') return 'scentRangeMultiplier';
        if (errorCode === 'invalid_medkit_cooldown_multiplier') return 'medkitCooldownMultiplier';
        if (errorCode === 'invalid_badge') return 'badge';
        return null;
    }

    /** Opens a draft pre-filled from an EXISTING rank row -- a COPY of its
     * own values, never the live object, so cancelling never mutates
     * state.xpTiers. Numeric fields are stored as STRINGS in the draft
     * (same posture as state.runtimeTunableDraft.value above) so a
     * partially-typed value never gets silently coerced mid-edit.
     * @param {object} tier */
    function openXpTierEditDraft(tier) {
        state.xpTierDraft = {
            ordinal: tier.ordinal,
            xp: String(tier.xp),
            label: tier.label,
            speedMultiplier: String(tier.speedMultiplier),
            scentRangeMultiplier: String(tier.scentRangeMultiplier),
            medkitCooldownMultiplier: (tier.medkitCooldownMultiplier === undefined || tier.medkitCooldownMultiplier === null) ? '' : String(tier.medkitCooldownMultiplier),
            badge: (typeof tier.badge === 'string') ? tier.badge : '',
            xpLocked: tier.xpLocked === true,
        };
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        render();
    }

    function closeXpTierDraft() {
        state.xpTierDraft = null;
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        render();
    }

    /** Mirrors server/xptiers.lua's own IsSafeShortString exactly -- a UX
     * convenience only (THE SECURITY RULE): catches an obviously-invalid
     * label/badge before a round trip, but the server's own identical
     * check is what actually matters; this page's own check being wrong in
     * either direction only ever costs an extra network round trip, never
     * a false sense of safety.
     * @param {*} value @param {number} maxLen @returns {boolean} */
    function isSafeShortStringForXpTier(value, maxLen) {
        if (typeof value !== 'string') return false;
        var len = value.length;
        if (len === 0 || len > maxLen) return false;
        if (/[<>&"'`\r\n\t]/.test(value)) return false;
        for (var i = 0; i < len; i++) {
            var code = value.charCodeAt(i);
            if (code < 0x20 || code === 0x7F) return false;
        }
        return true;
    }

    /** Sets the field-highlight/row-inline/top-banner error trio for the
     * CURRENTLY open xp-tier draft in one place -- shared by every
     * client-side pre-check branch in saveXpTierDraft() below AND its own
     * server-rejection branch, so a pre-check failure and a server refusal
     * for the SAME reason render byte-identically.
     * @param {string} field @param {string} text */
    function failXpTierDraft(field, text) {
        state.xpTierFieldError = field;
        state.xpTierActionError = { ordinal: state.xpTierDraft.ordinal, text: text };
        state.actionNotice = { kind: 'error', text: text };
        render();
    }

    /**
     * Saves the xp-rank draft form's current working copy. Every check
     * below mirrors server/xptiers.lua's own validators
     * (IsValidXpThreshold/IsSafeShortString/IsValidMultiplier/
     * IsStrictlyAscending) as a UX CONVENIENCE ONLY -- THE SECURITY RULE:
     * the server independently re-validates every one of these fields
     * against the CURRENT LIVE ladder (not this page's own possibly-stale
     * state.xpTiers) before writing anything, so a modified client sending
     * an out-of-range value straight to tablet:xpTiersUpsert is refused
     * there regardless of what this function does or does not catch first.
     * NOT the generic runMutation() helper: a rejected save carries a
     * `field` naming which of the six inputs failed, which runMutation's
     * own message-only handling has no slot for, same reasoning as
     * saveCertTierDraft()/saveTheme() above.
     */
    function saveXpTierDraft() {
        if (state.pendingAction || !state.xpTierDraft) return;
        var draft = state.xpTierDraft;

        // xp -- SKIPPED entirely for a locked rank (rank 1): always
        // submitted as 0, never this field's own (disabled, unreachable)
        // value. See server/xptiers.lua's own header "SCOPE DECISION"
        // point 1.
        var xp = 0;
        if (!draft.xpLocked) {
            var xpNum = Number(draft.xp);
            if (!isFinite(xpNum) || xpNum < 0 || Math.floor(xpNum) !== xpNum) {
                failXpTierDraft('xp', S('xp_tier_error_invalid_xp'));
                return;
            }
            xp = xpNum;
        }

        if (!isSafeShortStringForXpTier(draft.label, 60)) {
            failXpTierDraft('label', S('xp_tier_error_invalid_label'));
            return;
        }

        var speedMultiplier = Number(draft.speedMultiplier);
        if (!isFinite(speedMultiplier) || speedMultiplier <= 0 || speedMultiplier > XP_TIER_MAX_SPEED_SCENT_MULTIPLIER) {
            failXpTierDraft('speedMultiplier', S('xp_tier_error_invalid_speed_multiplier'));
            return;
        }

        var scentRangeMultiplier = Number(draft.scentRangeMultiplier);
        if (!isFinite(scentRangeMultiplier) || scentRangeMultiplier <= 0 || scentRangeMultiplier > XP_TIER_MAX_SPEED_SCENT_MULTIPLIER) {
            failXpTierDraft('scentRangeMultiplier', S('xp_tier_error_invalid_scent_range_multiplier'));
            return;
        }

        // OPTIONAL -- blank means "omit entirely" (server treats a missing
        // field as "not configured"), same posture as
        // savePermissionKeyDraft()'s own description field above.
        var medkitCooldownMultiplier;
        var medkitRaw = (typeof draft.medkitCooldownMultiplier === 'string') ? draft.medkitCooldownMultiplier.trim() : '';
        if (medkitRaw.length > 0) {
            var medkitNum = Number(medkitRaw);
            if (!isFinite(medkitNum) || medkitNum <= 0 || medkitNum > XP_TIER_MAX_MEDKIT_COOLDOWN_MULTIPLIER) {
                failXpTierDraft('medkitCooldownMultiplier', S('xp_tier_error_invalid_medkit_cooldown_multiplier'));
                return;
            }
            medkitCooldownMultiplier = medkitNum;
        }

        // OPTIONAL -- same "blank means omit" posture as
        // medkitCooldownMultiplier immediately above.
        var badge;
        var badgeRaw = (typeof draft.badge === 'string') ? draft.badge.trim() : '';
        if (badgeRaw.length > 0) {
            if (!isSafeShortStringForXpTier(badgeRaw, 30)) {
                failXpTierDraft('badge', S('xp_tier_error_invalid_badge'));
                return;
            }
            badge = badgeRaw;
        }

        // THE WALK-INTO-INVALID-STATE HAZARD, client-side mirror -- see
        // server/xptiers.lua's own header of the identical name. Built
        // from state.xpTiers (this page's own LAST KNOWN live ladder, not
        // necessarily still current -- another high-command session could
        // have edited a different rank since this page's last load), so
        // this check can occasionally be wrong in EITHER direction; the
        // server's own re-check against the ACTUAL current ladder inside
        // its mutex-held critical section is what actually decides, this
        // is purely to avoid an obviously-doomed round trip for the common
        // single-editor case.
        if (Array.isArray(state.xpTiers)) {
            var thresholds = state.xpTiers.map(function (t) { return (t.ordinal === draft.ordinal) ? xp : t.xp; });
            for (var i = 1; i < thresholds.length; i++) {
                if (!(thresholds[i] > thresholds[i - 1])) {
                    failXpTierDraft('xp', S('xp_tier_error_invalid_order'));
                    return;
                }
            }
        }

        state.pendingAction = true;
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = {
            ordinal: draft.ordinal, xp: xp, label: draft.label,
            speedMultiplier: speedMultiplier, scentRangeMultiplier: scentRangeMultiplier,
        };
        if (medkitCooldownMultiplier !== undefined) payload.medkitCooldownMultiplier = medkitCooldownMultiplier;
        if (badge !== undefined) payload.badge = badge;

        fetchNui('tablet:xpTiersUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.xpTiers = Array.isArray(result.tiers) ? result.tiers : state.xpTiers;
                // Non-optional whenever this edit demoted at least one
                // currently-connected K9 -- server/xptiers.lua's own header
                // "THE ALREADY-PROMOTED PLAYER". Forwarded as-is regardless,
                // so a future wording change needs no client edit, same
                // posture as moveCertTier()'s own certTierWarning above.
                state.xpTierWarning = (typeof result.warning === 'string' && result.warning.length > 0) ? result.warning : null;
                state.xpTierDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                render();
            } else {
                var text = xpTierErrorText(result);
                state.xpTierFieldError = xpTierFieldFromError(result && result.error);
                state.xpTierActionError = { ordinal: draft.ordinal, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    // ------------------------------------------------------------------
    // OPEN / CLOSE
    // ------------------------------------------------------------------

    function handleOpen(data) {
        data = data || {};
        state.open = true;
        state.strings = (data.strings && typeof data.strings === 'object') ? data.strings : {};
        state.blockClientEnforcedBadge = typeof data.blockClientEnforcedBadge === 'string' ? data.blockClientEnforcedBadge : null;
        state.blockClientEnforcedHint = typeof data.blockClientEnforcedHint === 'string' ? data.blockClientEnforcedHint : null;
        state.capabilities = (data.capabilities && typeof data.capabilities === 'object') ? data.capabilities : {};
        // See this file's header NUI CONTRACT note on `requestedView` --
        // presentation hint only, consumed once by loadMyRecord() below
        // (called a few lines down this same function) once the server's
        // own viewer.isHighCommand for this caller is known.
        state.requestedView = data.requestedView === 'highCommand' ? 'highCommand' : null;
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
        // DEFAULT SCREEN IS 'home' (this pass) -- see buildHomeScreen()'s
        // own header for why the landing view now comes before every
        // existing tab, including 'my_record'. requestedView === 'highCommand'
        // (handled a few lines below by loadMyRecord()) still overrides this
        // to 'console' for a genuine high-command caller, exactly as it
        // already overrode the previous 'my_record' default.
        state.screen = 'home';
        state.viewer = null;
        state.myRecord = null;
        state.myRecordError = null;
        state.isK9Model = false;
        state.isPartnered = false;
        state.commandReferenceQuery = '';
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
        // state.auditServerCap is DELIBERATELY NOT reset here -- same
        // exception, same reasoning, as state.theme just below: it is a
        // resource-wide server constant (server/admin.lua's own
        // HARD_MAX_RESULTS), not per-viewer data that could go stale
        // across a job/grant change, so forgetting it on every reopen
        // would only force this page back to guessing via
        // AUDIT_LIMIT_MAX_FALLBACK until the next query succeeds, for no
        // correctness benefit.

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
