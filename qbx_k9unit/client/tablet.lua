--[[
    qbx_k9unit/client/tablet.lua

    Config.Features.CommandTablet. Client-side bridge for the K9 Command
    Tablet. Owner's own words (relayed by the coordinator, scope expanded
    twice mid-pass): high command gets a control console over every
    feature/handler/K9; every certified handler or K9 gets a read-only
    view of their own record plus the ability to TRIGGER what they hold,
    as an alternative to keybinds/commands; opening is command- or
    item-based, operator's choice.

    THIS FILE OWNS: opening/closing the NUI + its focus lifecycle,
    resolving Config.CommandTablet.openMode, and routing every NUI
    callback to either (a) an EXISTING client resource-global the
    keybind/radial already calls, (b) the SAME chat-command handler a
    typed command would hit (via ExecuteCommand), or (c) a server
    callback -- proposed ones flagged explicitly below, since not every
    piece of server support this needs exists yet (server/permissions.lua's
    own header already names the roster/record aggregation as "a genuine
    cross-file architecture question... reported to coder-frontend/
    coder-ui/coder-architect rather than decided unilaterally" -- picked up
    here from the client side and relayed onward, not solved unilaterally
    by this file either).

    ======================================================================
    RIGHT-VS-WRONG (coordinator's own framing, verbatim): "route each
    tablet action to the SAME client function the keybind and command
    already call. One code path, one set of guards, one place to fix a
    bug... if one is a local rather than a global, report exactly which
    file and function needs a seam opened rather than duplicating its
    body." Named precedent: ScratchAtDoor/NudgeDoor checked vehicle state
    in ox_target's canInteract but not inside the function itself, so one
    entry point was guarded and the other was not.

    Applied here:
      - SECTION 2 (tablet:triggerFeature) calls the exact same
        resource-global every keybind/radial item already calls, mirroring
        client/radial.lua's own per-item gate CHOICE for that action
        line-for-line (cited per entry). FindNearestLeashCandidate/
        FindNearestPartnerCandidate were `local` in client/radial.lua --
        the coordinator has since opened that seam (dropped `local`,
        allowlisted both) rather than this file duplicating the search.
        Guarded with `type(fn) == 'function'` regardless (radial.lua
        returns early with neither defined when its own flag is off --
        this is not optional).
      - SECTION 3 (tablet:decertify's own command bridge) calls
        `ExecuteCommand`, the SAME mechanism the chat box itself uses to
        submit a typed command -- a tablet-triggered
        `/k9decertifyoffline <citizenid> <job>` is, from the server's
        perspective, LITERALLY THE SAME EVENT as an officer typing it.
        Allowlisted by exact command name (never a raw string), since a
        generic passthrough is exactly what server/highcommand.lua's own
        header already rejected for the identical reason. (A prior,
        broader 'tablet:runCommand' generic bridge -- allowlisting
        k9certify/k9decertify/k9givexp plus five k9audit* commands -- was
        REMOVED this pass: it had no caller anywhere in html/, was never
        part of this file's own documented NUI CONTRACT below, and at the
        time the five k9audit* commands it existed to reach were
        chat/console-notify oriented at the server layer with no callback
        that returned structured data. STATUS UPDATE (later pass):
        server/admin.lua has since grown the exact `lib.callback.register`
        surface that gap named (tabletAuditCert/Partner/Search/Xp/Dept,
        each returning `{ok, rows, label}` -- see its own header CALLBACK
        SURFACE section), and this file's own NUI CONTRACT below now lists
        the five tablet:audit* bridges built against it, plus the real
        Audit Trail tab in html/tablet.js that consumes them -- the "real
        audit tab" this note originally deferred. Left here, corrected
        rather than deleted, so the reasoning for the ORIGINAL removal
        (a generic passthrough is not how this file exposes new server
        capability) still reads accurately for whoever finds this
        comment.)
    ======================================================================

    ======================================================================
    SECURITY NOTE. THE TABLET IS A VIEW. IT DECIDES NOTHING. Every action
    it offers -- viewing a record, granting a permission, triggering an
    ability, certifying, running an admin command -- is re-authorized
    server-side from the caller's own live job/grants/blocks, exactly as
    if they had typed the command or pressed the keybind. A modified
    client can fire any NUI callback with any payload, so nothing in this
    file may ever be the thing that actually authorizes an action.
    `Config.FeatureControl.allowActionsFromTablet` (checked before
    SECTION 2/3 dispatch) is a pure UX toggle, not an authorization
    boundary -- turning it off only removes the tablet's trigger buttons,
    it cannot and does not change what a keybind/command/radial item can
    still do.
    ======================================================================

    ======================================================================
    OPENING -- Config.CommandTablet.openMode ('command' | 'item' | 'both').
    An unrecognised value falls back to 'command' with a loud console
    warning -- never leaves a player with NO way in at all.
      'command' -- RegisterCommand only. No item involvement.
      'item'    -- the command is NOT registered at all. The ox_inventory
                   item (Config.CommandTablet.itemName) is the only way in.
      'both'    -- both paths work; the item is a convenience, not a gate.
    THE TRAP (config.lua's own words): the item must already exist in the
    OPERATOR'S OWN ox_inventory items table -- this resource cannot create
    it, and an unregistered name resolves to a "no such item" callback
    that never fires, which in 'item' mode means NOBODY can open the
    tablet with nothing to explain why. server/wellbeing.lua's
    WarnIfItemMissing is the established SERVER-side pattern for this
    exact class of placeholder-item check (exports.ox_inventory:Items());
    this file cannot run that check itself (no server-side export access),
    so it is requested from whoever owns the tablet's server-side glue
    (this pass's own report), with escalated wording in 'item' mode per
    the coordinator's own instruction. This file's OWN, client-side
    defence is narrower but real: IsInventoryUseCapable() below guards the
    K9Compat-routed `UseItem` call itself (asks shared/compat/core.lua's own
    detection result, not `exports.ox_inventory` directly -- see that
    function's own doc comment), so a missing/outdated/undetected inventory
    degrades to a logged warning + a player-facing notify, never an
    uncaught error out of an item-use event.
    The radial entry point (this pass's own report names the exact item)
    stays available in EVERY mode -- a UI affordance, not a third open
    mode, honouring the same OpenTablet() gate either way.
    ======================================================================

    ======================================================================
    NUI CONTRACT -- authoritative source is html/tablet.js's own header
    (coder-ui); condensed here, byte-exact on names/payload keys (a
    mismatch just hangs the fetch promise or drops a push, no error either
    side). SendNUIMessage targets the TOP window; html/tablet-bridge.js
    relays any '/^tablet:/' action down into the tablet's own iframe.

    JS -> Lua (RegisterNUICallback, every path calls cb(...) unconditionally):
      tablet:ready {}                                             -> cb({})
      tablet:close {}                                             -> cb({})
      tablet:requestMyRecord {}                                   -> cb(MyRecordResult)
      tablet:requestRoster {query}                                -> cb(RosterResult)          [console audience]
      tablet:requestPersonSummary {targetCitizenId}               -> cb(PersonSummaryResult)    [console audience]
      tablet:requestPersonFeatures {targetCitizenId}               -> cb(PersonFeaturesResult)   [high command only]
      tablet:triggerFeature {feature}                             -> cb({ok,error?})            [SECTION 2]
      tablet:certify {targetCitizenId, departmentKey}             -> cb({ok,error?,message?})   [server/certifications.lua's tabletCertify -- online OR offline, see GrantCertificationForTablet's own header]
      tablet:decertify {targetCitizenId, departmentKey}           -> cb({ok,error?,message?})   [SECTION 3, k9decertifyoffline]
      tablet:setCertificationTier {targetCitizenId, departmentKey, tier}     -> cb({ok,error?})  [server/certifications.lua's tabletSetCertificationTier -- online OR offline]
      tablet:renewCertification {targetCitizenId, departmentKey}            -> cb({ok,error?})  [tabletRenewCertification -- online OR offline]
      tablet:grantSpecialization {targetCitizenId, departmentKey, specialization}  -> cb({ok,error?})  [tabletGrantSpecialization -- ONLINE ONLY, see that function's own header for why]
      tablet:revokeSpecialization {targetCitizenId, departmentKey, specialization} -> cb({ok,error?})  [tabletRevokeSpecialization -- online OR offline]
      tablet:givexp {targetCitizenId, amount}                     -> cb({ok,error?,message?})   [proposed]
      tablet:grantPermission {targetCitizenId, permission}        -> cb({ok,error?,message?})   [server/permissions.lua]
      tablet:revokePermission {targetCitizenId, permission}       -> cb({ok,error?,message?})
      tablet:grantFeature {targetCitizenId, feature}              -> cb(...)  -- same callback as grantPermission, key = 'feature.'..feature
      tablet:revokeFeature {targetCitizenId, feature}             -> cb(...)  -- revokePermission, key = 'feature.'..feature
      tablet:blockFeature {targetCitizenId, feature}              -> cb(...)  -- grantPermission, key = 'block.'..feature
      tablet:unblockFeature {targetCitizenId, feature}            -> cb(...)  -- revokePermission, key = 'block.'..feature
        (config.lua's own header: grants and blocks share the k9_permissions
        table and revoke semantics -- revoking a 'block.<Name>' row is how
        it's lifted. Nothing new needed server-side for these four.)
      tablet:assignK9Role {targetCitizenId, modelName}            -> cb({ok,error?,message?})   [high command -- server/tablet.lua's tabletAssignK9Role]
        Forwarded VERBATIM -- server/appearance.lua's ApplyK9PedRole (via
        that callback) already re-checks IsHighCommand itself and already
        accepts ANY Config.Peds entry; this file adds no authorization and
        no second appearance-mutation path. `modelName` is display-chosen
        from the `peds` list this file sends in the tablet:open payload
        below, but the SERVER'S OWN IsValidPedModelName re-check against
        its OWN Config.Peds is what actually matters -- a modified client
        sending an arbitrary string gets 'invalid_model' back, nothing more.
      tablet:revertK9Ped {targetCitizenId}                        -> cb({ok,error?,message?})   [high command -- server/tablet.lua's tabletRevertK9Ped]
        THE NO-UNBOUNDED-TRAP ACTION -- forwarded verbatim, gated
        server-side on the GRANTER's own authorization ONLY, never on
        anything about the target (see server/tablet.lua's own header): a
        target who already lost every certification/grant/feature check
        must still be revertible, or revoking someone first would strand
        them as an animal permanently. This file's OWN contribution to that
        guarantee is UI-side, not authorization-side: html/tablet.js's
        "open by citizen ID" control (its own header) exists specifically
        so high command can reach a person screen for a citizenid who no
        longer appears in tablet:requestRoster's own certified-only rows,
        and therefore still has a path to press this button on them at all.
      tablet:getTheme {}                                          -> cb({ok,theme?,error?})     [Config.Features.TabletTheming -- server/runtimecontrol.lua]
      tablet:setTheme {primaryColor?,accentColor?,backgroundColor?,textColor?,density?,headerTitle?} -> cb({ok,theme?,error?,field?})  [high command]
      tablet:resetTheme {}                                        -> cb({ok,theme?,error?})     [high command]
        All three forwarded through TranslateReasonResult (below), which
        only renames server/runtimecontrol.lua's `reason` field to this
        contract's `error` (and forwards `field`, set only on
        error='invalid_field', naming which of the six theme inputs failed)
        -- COSMETIC ONLY, see that file's own PART 2 header: nothing a
        theme value carries is ever consulted by an authorization check,
        here or anywhere else in this resource. getTheme has no
        authorization gate at all (applied for every viewer); setTheme/
        resetTheme re-check high command server-side regardless of what
        this page shows.
      tablet:certTiersList {}                                     -> cb({ok,tiers?,capabilityCatalog?,error?})   [high command -- server/certtiers.lua]
      tablet:certTiersUpsert {key,label,capabilities:string[]}    -> cb({ok,tiers?,capabilityCatalog?,error?})   [high command]
      tablet:certTiersReorder {orderedKeys:string[]}              -> cb({ok,tiers?,warning?,error?})             [high command]
      tablet:certTiersDelete {key}                                -> cb({ok,tiers?,error?,referenceCount?})      [high command]
        All four forwarded through the SAME TranslateReasonResult --
        server/certtiers.lua's own header states its response shape
        "mirrors server/runtimecontrol.lua's own `{ ok, reason, ... }`
        convention exactly", so it needs the identical `reason` -> `error`
        bridge, done HERE (client-side), not in that file, so it can keep
        matching its sibling's convention without also learning this
        contract's `error`-keyed shape. `tiers` (every list/mutation
        response) is the FULL, current, DYNAMIC catalog -- html/tablet.js
        must never hardcode a tier list, see ListCertificationTiers's own
        doc comment. A successful reorder's `warning` is non-optional and
        MUST be surfaced prominently (server/certtiers.lua's own header
        "HAZARD 3": a reorder re-ranks every citizenid already holding one
        of the reordered tiers, retroactively). `tier_in_use`/
        `protected_tier` on a failed delete are REFUSALS ("cannot, and
        here is why" -- a referenced or protected tier), not failures in
        the "something went wrong" sense; `referenceCount` (delete only)
        names how many k9_certifications rows still reference the tier.
      tablet:permKeysList {}                                      -> cb({ok,keys?,error?})        [high command -- server/permissionkeycatalog.lua]
      tablet:permKeysUpsert {key,label,description?}              -> cb({ok,keys?,error?})         [high command]
      tablet:permKeysDelete {key}                                 -> cb({ok,keys?,error?,activeGrantCount?}) [high command]
        Same TranslateReasonResult bridge as the cert-tier trio above --
        server/permissionkeycatalog.lua's own header states its response
        shape mirrors server/certtiers.lua's own convention exactly. `keys`
        (every list/mutation response) is the FULL, current, DYNAMIC
        catalog -- html/tablet.js must never hardcode the four admin
        capability names, see ListPermissionCatalogKeys's own doc comment.
        `reserved_namespace` (create/rename) and `unknown_key` (delete) are
        REFUSALS ("cannot, and here is why" -- the key collides with the
        feature./block. per-person-feature-control namespace, or does not
        exist), not failures in the "something went wrong" sense.
        `activeGrantCount` (delete only, may be nil on a degraded read)
        names how many k9_permissions rows currently hold the deleted key
        -- INFORMATIONAL ONLY, unlike certTiersDelete's `referenceCount`:
        this delete is NEVER refused because of it (see that file's own
        header "TOMBSTONE, NOT REFERENCE-COUNTED" for why a permission key
        has no equivalent hazard to server/certtiers.lua's own
        'tier_in_use' refusal). There is no reorder counterpart -- a
        permission key carries no ordinal.
      tablet:equipmentShopGetLocations {}                         -> cb({ok,locations?,error?})   [high command -- server/equipmentshop.lua]
      tablet:equipmentShopAddLocation {label?,model?,scenario?}   -> cb({ok,locationKey?,locations?,error?})
        COORDINATES ARE NEVER SENT BY html/tablet.js -- a CEF browser page
        has no native access to GetEntityCoords at all (see this task's own
        instruction: "Get it client-side and send it; do not expect the
        server to know where they are"). THIS FILE captures the caller's
        own current position/heading (GetEntityCoords/GetEntityHeading on
        PlayerPedId()) at the moment this callback fires and adds it to the
        `location` table sent to the server -- the ONLY point in this whole
        round trip that has that information. `label`/`model`/`scenario`
        are each OMITTED entirely when blank (never sent as `''`, which the
        server's own IsSafeShortString would reject outright) -- meaning
        "inherit the shop-wide default", exactly like a config.lua location
        entry with that field left unset.
      tablet:equipmentShopMoveLocation {locationKey,updates?:{label?,model?,scenario?},useCurrentPosition?} -> cb({ok,locations?,error?})
        Serves BOTH this screen's "Edit" (metadata only: `updates.label`/
        `.model`/`.scenario`, ALWAYS all three, each either a non-empty
        string override or `false` to reset that field back to the
        shop-wide default -- never omitted here, unlike Add above, since an
        edit's draft always starts pre-filled from a real, already-resolved
        value) and its "Move Here" (`useCurrentPosition = true`, no
        label/model/scenario at all) -- ONE server callback, so both flow
        through here. `useCurrentPosition` triggers the SAME THIS-FILE
        GetEntityCoords/GetEntityHeading capture as AddLocation above,
        merged into `updates.x/.y/.z/.heading` -- never requested of, or
        assumed by, the server.
      tablet:equipmentShopRemoveLocation {locationKey}             -> cb({ok,locations?,error?})
        All four forwarded through the SAME TranslateReasonResult as the
        theme/cert-tier callbacks above -- server/equipmentshop.lua's own
        header states its response shape is a plain `{ ok, reason, ... }`
        outcome table, "never player-facing prose", same convention. High
        command only (`CanManageShopLocations` re-verified server-side on
        every one of the three mutating calls; GetLocations itself has NO
        such gate server-side -- open to any connected player, matching
        that file's own header note that this only needs to be true for
        someone who has not yet earned any special trust) -- this page
        still only ever shows the MANAGEMENT screen to high command, a
        convenience per THE SECURITY RULE, not the real gate. A `db:<n>`
        location key may be moved/removed; a `cfg:<n>` one (defined in
        config.lua) is refused outright (`invalid_key`) by the server on
        purpose -- see that file's own SCOPE note -- and this page never
        offers Move/Remove controls for one, only a note pointing at
        config.lua.
      tablet:runtimeListFeatures {}                               -> cb({ok,features?,error?})   [high command -- server/runtimecontrol.lua]
      tablet:runtimeSetFeature {name,value:boolean}               -> cb({ok,appliedLive?,restartRequired?,configEditRequired?,tier?,error?})
      tablet:runtimeResetFeature {name}                           -> cb({ok,value?,restartRequired?,error?})
      tablet:runtimeListTunables {}                                -> cb({ok,tunables?,error?})
      tablet:runtimeSetTunable {key,value:number}                 -> cb({ok,appliedLive?,restartRequired?,value?,error?,min?,max?})
      tablet:runtimeResetTunable {key}                            -> cb({ok,value?,restartRequired?,error?})
        All six forwarded through the SAME TranslateReasonResult as the
        theme/cert-tier/shop-location callbacks above --
        server/runtimecontrol.lua's own callbacks return the identical
        `{ ok, reason, ... }` outcome shape (that file's own header states
        it explicitly). High command only (`CanManageRuntimeControl`
        re-verified server-side on every one of the six calls regardless of
        what this page shows) -- server/runtimecontrol.lua's own header:
        "LOCALE KEYS THIS FILE NEEDS: none... outcome tags, never
        player-facing prose" -- meaning the `tier`/`note` fields that file
        returns are DELIBERATELY NOT forwarded to the player as-is by
        html/tablet.js: that page derives its OWN locale-driven plain-
        language explanation from the `tier` string alone (see that file's
        own header on the five tiers: 'live'/'onstart'/'rawtoplevel'/
        'clientonly'/'protected', plus the client-side-only 'unaudited'
        fallback for a feature GetFeatureTier could not classify), never
        the server's own raw English `note` prose. `reason='unaudited_feature'`
        and `reason='protected_feature'` are REFUSALS ("cannot, and here is
        why"), not generic failures, per this task's own instruction --
        html/tablet.js's own runtimeFeatureErrorText() gives each its own
        explanatory copy rather than a bare code. `reason='out_of_range'`
        on a rejected tunable set carries the server's own real `min`/`max`
        back (TUNABLE_REGISTRY's own bounds) -- forwarded verbatim so the
        tablet can tell the operator the exact range, never a guess of its
        own; this page does NOT independently enforce that range as if it
        were authoritative (server/runtimecontrol.lua's own SetTunable is
        the only real gate), only uses it as an `<input type="number">`
        min/max HINT that does not block submission.

      tablet:auditCert {targetCitizenId, limit?}    -> cb(AuditResult)  [server/admin.lua's tabletAuditCert]
      tablet:auditPartner {targetCitizenId, limit?} -> cb(AuditResult)  [tabletAuditPartner]
      tablet:auditSearch {mode, value?, limit?}     -> cb(AuditResult)  [tabletAuditSearch -- mode in {'officer','plate','person','recent'}]
      tablet:auditXp {targetCitizenId}              -> cb(AuditResult)  [tabletAuditXp -- no limit, single-row point lookup]
      tablet:auditDept {departmentKey, limit?}      -> cb(AuditResult)  [tabletAuditDept]
        AuditResult = { ok:true, rows:table, label:string, cap:number, limit?:number, truncated?:boolean } |
                      { ok:false, error:'not_authorized'|'rate_limited'|'invalid_args', message?:string }
        `cap` (server/admin.lua's own HARD_MAX_RESULTS, added in a LATER
        pass than these five bridges themselves) is present on every
        success response, including tabletAuditXp's -- a uniform shape
        across all five, even though that one callback takes no `limit` at
        all. `limit`/`truncated` are present on the other four (the ones
        that DO take a `limit`): `limit` is the exact, already-clamped
        value the server actually used, and `truncated` is `true` only when
        the caller's own request exceeded `cap` and was cut down to it --
        see server/admin.lua's own ClampLimit doc comment for the full
        contract these two mirror verbatim. NEVER present on a failure --
        an unauthorized/rate-limited/malformed caller learns nothing new
        from these fields. These five bridges originally closed the gap
        server/admin.lua's own header once named by name: "no NUI callback
        and no client/tablet.lua change are part of this pass; this is the
        server-side contract a follow-up tablet screen builds against" --
        THIS file is that follow-up (that sentence has since been corrected
        in server/admin.lua's own header to say so). Forwarded VERBATIM --
        that file's own CALLBACK SURFACE header states its response shape
        mirrors THIS file's established `{ok, error, message}` convention
        DIRECTLY, so AwaitServerCallback's own synthetic
        `{ok=false, error='timeout'}` (a thrown/unregistered callback)
        already matches without a translator, same as every other
        passthrough bridge above. `rows`'s exact column shape differs PER
        CALLBACK -- see server/admin.lua's own Query* functions
        (QueryCertificationHistory/QueryPartnershipHistory/
        QuerySearchLogBy{Officer,Plate,Person}/Recent/
        QueryProgressionSnapshot/QueryDepartmentRoster) for the
        authoritative column list of each; this file does not reshape or
        rename a single field. `limit` is always OPTIONAL: an absent or
        non-number value is dropped to `nil` here (see
        OptionalNumericLimit below), letting server/admin.lua's own
        ClampLimit apply ITS configured default/hard cap (HARD_MAX_RESULTS
        = 100) rather than this file guessing one. GATING: that file's own
        IsAuthorizedAdmin (job.isboss, job.grade >=
        Config.Departments[job.name].auditGrade, an explicit 'k9.audit'
        permission grant, or high command) is the ONLY real gate,
        re-verified from the caller's own live `source` on every single
        invocation -- same THE SECURITY RULE as every other callback in
        this file.

    Lua -> JS (SendNUIMessage):
      { action = 'tablet:open', data = { capabilities = Config.Permissions,
          strings = BuildTabletStrings() (locales/en.json's `tablet` group -- see LOCALIZATION below),
          maxXpPerGrant = Config.HighCommand.maxXpPerGrant,
          peds = Config.Peds,               -- shared config, no round trip -- display list only for tablet:assignK9Role's model picker; server/appearance.lua's IsValidPedModelName is the real gate
          specializations = Config.K9Specializations, -- shared config, no round trip -- display list only for the person screen's specialization grant picker (buildCertificationRow); server/certifications.lua's GrantSpecialization re-checks this SAME table server-side, the real gate
          themingEnabled = Config.Features.TabletTheming == true, -- UX hint only -- hides the theme editor's Save/Reset controls when off rather than offering ones that would always come back 'feature_disabled'; the CURRENT theme is still fetched/applied for every viewer regardless (tablet:getTheme has no such gate)
          shopLocationsEnabled = Config.Features.K9EquipmentShop == true, -- UX hint only, SAME shape as themingEnabled just above -- shows a disabled-server-wide note on the Shop Locations screen rather than one that would always come back 'feature_disabled'; tablet:equipmentShopGetLocations/Add/Move/RemoveLocation all re-check this live, server-side, regardless of what this flag says
          runtimeControlEnabled = Config.Features.RuntimeFeatureControl == true, -- UX hint only, SAME shape as themingEnabled/shopLocationsEnabled -- runtimeListFeatures/ListTunables have NO such gate server-side (open to any high-command caller regardless), only the four mutating runtimeSet*/Reset* calls actually refuse with `reason='feature_disabled'` when this is off; this page still shows the disabled note and the (read-only) current values regardless
          auditEnabled = Config.Features.AdminAuditCommands == true, -- UX hint only, but UNLIKE the three flags above: server/admin.lua gates its five tabletAudit* callbacks at REGISTRATION TIME behind this same flag, so a query made while it is false hangs until a generic 'timeout' synthesizes, not a clean 'feature_disabled' refusal -- html/tablet.js disables the Audit screen's query controls (and shows a disabled note) whenever this is false, specifically to avoid that confusing dead end
          branding = Config.CommandTablet.branding,  -- shared config, no round trip -- { serverName: string, logo: string (relative to html/), theme: {primaryColor,accentColor,backgroundColor,textColor} }. Owner-supplied server identity (name/logo) PLUS the operator's chosen starting palette for a fresh install -- COSMETIC ONLY, same as tablet:getTheme's own theme, never consulted by any authorization check. html/tablet.js renders `logo` with a `serverName`-text fallback on load failure (never a broken-image icon -- the operator hand-swaps this file and may typo it) and seeds its OWN pre-fetch initial paint from `branding.theme`'s four colours ONLY until the real, authoritative tablet:getTheme response lands (which always wins once it does, same "config is the starting point, the runtime edit wins" precedence server/runtimecontrol.lua's own DEFAULT_THEME->k9_tablet_theme-DB-override chain already establishes for that file's own default).
      } }
      { action = 'tablet:close', data = {} }
      { action = 'tablet:themeUpdated', data = Theme }
        Lua-INITIATED, NOT tied to this player's own tablet being open --
        relayed verbatim from server/runtimecontrol.lua's
        qbx_k9unit:client:themeUpdated broadcast (see that file's own PART 2
        header: "an already-open tablet updates without the viewer having
        to close and reopen it"), which fires for EVERY connected client on
        every successful SetTheme/ResetTheme, not only the officer who
        triggered it. This file registers that event UNCONDITIONALLY (not
        only while tabletOpen) and does nothing more than relay it into the
        SAME SendNUIMessage channel tablet:open/tablet:close already use --
        html/tablet-bridge.js's existing `/^tablet:/` relay picks it up with
        no further change on that file's side; html/tablet.js's own header
        documents what it does with a push arriving while hidden.
      { action = 'tablet:equipmentShopLocationsUpdated', data = table<string,ShopLocation> }
        Lua-INITIATED, SAME shape/posture as tablet:themeUpdated immediately
        above -- relayed verbatim from server/equipmentshop.lua's
        qbx_k9unit:client:equipmentShopLocationsUpdated broadcast (that
        file's own header: "an already-connected player's own shop-ped
        thread AND any already-open tablet screen updates live"), fired for
        EVERY connected client on every successful Add/Move/RemoveLocation.
        client/equipmentshop.lua ALSO listens for this exact event
        independently (to respawn/reposition shop peds) -- AddEventHandler
        supports any number of handlers per event name, so this is a
        second, additive listener, not a replacement for that one.

    LOCALIZATION: `strings` ships the FULL, real, locale()-resolved set --
    all 117 of html/tablet.js's own DEFAULT_STRINGS keys, one-for-one,
    built by BuildTabletStrings() below from locales/en.json's `tablet`
    group (keyed identically to DEFAULT_STRINGS, no `tablet.` prefix
    inside that group). DEFAULT_STRINGS itself is KEPT, unchanged, in
    html/tablet.js -- it remains the resilience net for a key this payload
    ever fails to resolve (a misconfigured/hand-edited locale file, or a
    future key added to one side and not the other), never removed just
    because Lua now sends the real thing.
    ======================================================================

    ======================================================================
    FOCUS/CLOSE DISCIPLINE -- first focus-taking surface in this resource.
    A stuck focus locks a player out of their own character with no way
    back except a reconnect. FOUR close paths, ALL funneling through the
    ONE CloseTablet() (the only site that ever calls SetNuiFocus(false,
    false)):
      1. JS calls 'tablet:close' (button, or its own in-iframe Escape
         listener, or html/tablet-bridge.js's independent TOP-DOCUMENT
         Escape listener -- see that file's own header for why it keeps a
         second one).
      2. ESC handled ENTIRELY Lua-side, independent of any NUI callback --
         EnsureTabletWatchThreadRunning() below. A crashed/unresponsive
         tablet page can never fire tablet:close; this is what closes it
         anyway.
      3. Own death -- same thread as ESC. FiveM's respawn REUSES the same
         ped handle (this resource has already shipped this exact bug once
         -- a K9 that died mid-vehicle-load respawned frozen/invisible/
         still-attached, client/vehicle.lua's header), so a focus grab
         would otherwise survive a respawn with nothing to release it.
      4. onResourceStop (this resource only).
    CloseTablet() has NO access/state gate beyond "is it even open" -- the
    "no unbounded trap" rule this codebase applies to every release path.
    ======================================================================

    ======================================================================
    XP-RANK EDITOR (owner-directed "set experience level for each rank up"
    pass, server/xptiers.lua):
      tablet:xpTiersList {}                                       -> cb({ok,tiers?,error?})   [high command -- server/xptiers.lua]
      tablet:xpTiersUpsert {ordinal,xp,label,speedMultiplier,scentRangeMultiplier,medkitCooldownMultiplier?,badge?} -> cb({ok,tiers?,warning?,error?})
        Same TranslateReasonResult bridge as the theme/cert-tier/permission-
        key callbacks above -- server/xptiers.lua's own header states its
        response shape mirrors server/certtiers.lua's own convention
        exactly. `tiers` (both calls) is the FULL, current, live ladder
        (four entries as shipped -- this pass edits existing ranks only,
        never adds/removes/reorders one, see that file's own header
        "SCOPE DECISION"); each entry's `xpLocked` flag (true for rank 1
        only) tells this page which one field to render read-only. A
        successful edit's `warning` (non-optional whenever at least one
        currently-connected K9 was just re-ranked LOWER by this exact edit)
        MUST be surfaced prominently, identical posture to certTiersReorder's
        own warning above -- see server/xptiers.lua's own header "THE
        ALREADY-PROMOTED PLAYER" for why this can happen from a single
        threshold edit (no reorder concept exists for this ladder at all).
        `base_tier_xp_fixed` (rank 1 only) is a REFUSAL ("cannot, and here
        is why" -- rank 1 must always be exactly 0 XP), not a generic
        failure -- html/tablet.js's own error-text mapping should give it
        distinct copy, the same way certTierErrorText() already does for
        'tier_in_use'/'protected_tier'.
    ======================================================================

    FILE-TO-FILE CONTRACT: exposes OpenTablet()/CloseTablet() as resource-
    globals (both already allowlisted) -- CloseTablet() deliberately IS
    global, not file-private, so no future call site is ever tempted to
    call SetNuiFocus a second time itself; it should always call this
    instead. Calls client/main.lua's HasK9Access()/CanShowK9UI()/
    DenyK9UIAccess() and client/radial.lua's FindNearestLeashCandidate()/
    FindNearestPartnerCandidate() (both guarded with
    `type(fn) == 'function'`).
]]

if not Config.Features.CommandTablet then return end

-- ----------------------------------------------------------------------
-- PART 0 -- open/close + focus lifecycle
-- ----------------------------------------------------------------------

local tabletOpen = false -- single source of truth for CloseTablet()'s no-op guard and the watch thread's loop condition

--- Pcall-wrapped, fail-closed wrapper around every server callback this
--- file awaits. `lib.callback.await` THROWS (never returns nil) on a
--- timeout or an unregistered callback -- see client/main.lua's
--- HasK9Access() doc comment for the exact ox_lib/FiveM source citation;
--- duplicated here rather than shared, matching this codebase's per-file
--- convention for this exact guard. Every caller gets back a plain table
--- either way, never a propagating error that could abort a
--- RegisterNUICallback mid-way and leave its `cb` uninvoked (client/hud.lua:
--- "an uninvoked NUI callback hangs the frontend's fetch promise forever").
--- The synthetic failure shape (`error = 'timeout'`) matches html/tablet.js's
--- OWN `{ ok:false, error, message? }` contract directly -- every endpoint
--- that forwards this result verbatim needs no further translation.
--- @param name string
--- @return table result -- always a table
local function AwaitServerCallback(name, ...)
    local ok, result = pcall(lib.callback.await, name, false, ...)
    if not ok or type(result) ~= 'table' then
        return { ok = false, error = 'timeout' }
    end
    return result
end

--- Every DEFAULT_STRINGS key from html/tablet.js, in that file's own
--- declared order -- kept as an explicit list (rather than derived from
--- anything at runtime) so BuildTabletStrings() below and
--- tests/tablet_strings_spec.lua both iterate the SAME set, and so a key
--- added to html/tablet.js without a matching addition here/in
--- locales/en.json's `tablet` group is caught by that spec instead of
--- silently falling back to English forever. 255 keys total (this pass
--- added the 53 K9 Audit Trail viewer keys at the end of this list; see
--- this pass's own report for the count this changed from).
local TABLET_STRING_KEYS = {
    'title', 'close_label', 'tab_console', 'tab_my_record', 'loading',
    'error_generic', 'error_not_authorized', 'error_timeout', 'error_network',
    'retry_label', 'search_placeholder', 'refresh_label', 'empty_roster',
    'column_name', 'column_citizenid', 'column_department', 'column_certified',
    'column_xp', 'column_actions', 'certified_yes', 'certified_no',
    'certify_label', 'decertify_label', 'confirm_label', 'grant_label',
    'revoke_label', 'block_label', 'unblock_label', 'manage_label',
    -- Block Effect column (html/tablet.js's featureBlockEnforcement()) --
    -- THE HONESTY REQUIREMENT: server/tablet.lua's own `blocked`/`state`
    -- fields never told the operator whether a block does anything; these
    -- four keys are this page's plain-language rendering of the new,
    -- REQUESTED `blockEnforcement` field (see html/tablet.js's own
    -- PersonFeaturesResult doc comment for the full three-state contract
    -- and why it is never guessed client-side).
    'column_block_effect', 'block_enforced_badge', 'block_not_yet_enforced_badge',
    'block_not_yet_enforced_hint', 'block_not_enforceable_note',
    'back_label', 'givexp_label', 'givexp_placeholder', 'givexp_max_hint',
    'self_grant_disabled_title', 'truncated_notice', 'action_working',
    'action_failed', 'action_succeeded', 'no_certifications',
    'my_certifications_heading', 'my_xp_heading', 'my_abilities_heading',
    'no_abilities', 'search_features_placeholder', 'state_global_off',
    'state_blocked', 'state_not_certified', 'state_requires_grant_missing',
    'state_available', 'feature_column', 'status_column',
    'person_features_heading', 'person_capabilities_heading',
    'person_certifications_heading', 'person_xp_heading', 'xp_tier_unknown',
    'use_label', 'not_available_short', 'opening_person',
    'open_by_id_placeholder', 'open_by_id_label', 'open_by_id_empty',
    'role_heading', 'role_model_label', 'role_assign_label',
    'role_assign_hint', 'role_revert_label', 'role_revert_hint',
    'role_no_peds_configured', 'tab_theme', 'theme_heading',
    'theme_primary_label', 'theme_accent_label', 'theme_background_label',
    'theme_text_label', 'theme_density_label', 'theme_density_comfortable',
    'theme_density_compact', 'theme_header_title_label', 'theme_save_label',
    'theme_reset_label', 'theme_disabled_note', 'theme_field_invalid',
    'tab_cert_tiers', 'cert_tiers_heading', 'cert_tiers_add_label',
    'cert_tier_key_label', 'cert_tier_key_placeholder', 'cert_tier_label_label',
    'cert_tier_capabilities_label', 'cert_tier_no_capabilities',
    'cert_tier_save_label', 'cert_tier_cancel_label', 'cert_tier_edit_label',
    'cert_tier_delete_label', 'cert_tier_move_up_label', 'cert_tier_move_up_title',
    'cert_tier_move_down_label', 'cert_tier_move_down_title', 'column_position',
    'column_key', 'column_label', 'column_capabilities', 'cert_tier_error_denied',
    'cert_tier_error_rate_limited', 'cert_tier_error_invalid_key',
    'cert_tier_error_invalid_label', 'cert_tier_error_invalid_capabilities',
    'cert_tier_error_busy', 'cert_tier_error_too_many_tiers',
    'cert_tier_error_unknown_tier', 'cert_tier_error_protected_tier',
    'cert_tier_error_tier_in_use', 'cert_tier_error_must_include_every_tier',
    'cert_tier_error_invalid_key_set', 'cert_tier_error_db_error',
    'cert_tier_error_invalid_payload',
    -- Permission-key catalog editing (high command only, sits alongside the
    -- cert-tier screen above) -- see this file's own header NUI CONTRACT
    -- section on the three tablet:permKeys* callbacks.
    'tab_permission_keys', 'permission_keys_heading', 'permission_keys_add_label',
    'permission_key_key_label', 'permission_key_key_placeholder',
    'permission_key_label_label', 'permission_key_description_label',
    'permission_key_description_placeholder', 'permission_key_save_label',
    'permission_key_cancel_label', 'permission_key_edit_label',
    'permission_key_delete_label', 'permission_key_default_badge',
    'column_description', 'permission_key_error_denied',
    'permission_key_error_rate_limited', 'permission_key_error_invalid_key',
    'permission_key_error_invalid_label', 'permission_key_error_invalid_description',
    'permission_key_error_reserved_namespace', 'permission_key_error_busy',
    'permission_key_error_too_many_keys', 'permission_key_error_unknown_key',
    'permission_key_error_db_error', 'permission_key_error_invalid_payload',
    -- K9 Supply Shop location management (high command only) -- see this
    -- file's own header NUI CONTRACT section on the four
    -- tablet:equipmentShop*Location(s) callbacks.
    'tab_shop_locations', 'shop_locations_heading', 'shop_locations_disabled_note',
    'shop_locations_empty', 'column_coordinates', 'column_model', 'column_source',
    'source_config', 'source_runtime', 'shop_location_add_here_label',
    'shop_location_add_hint', 'shop_location_label_label', 'shop_location_label_placeholder',
    'shop_location_model_label', 'shop_location_model_placeholder',
    'shop_location_scenario_label', 'shop_location_scenario_placeholder',
    'shop_location_save_label', 'shop_location_cancel_label', 'shop_location_edit_label',
    'shop_location_move_here_label', 'shop_location_move_here_hint',
    'shop_location_remove_label', 'shop_location_config_note',
    'shop_location_error_denied', 'shop_location_error_rate_limited',
    'shop_location_error_invalid_coords', 'shop_location_error_invalid_heading',
    'shop_location_error_invalid_model', 'shop_location_error_invalid_scenario',
    'shop_location_error_invalid_label', 'shop_location_error_invalid_key',
    'shop_location_error_invalid_payload', 'shop_location_error_db_error',
    'shop_location_error_feature_disabled',
    -- Runtime feature control + tuning (its own tab, high command only) --
    -- server/runtimecontrol.lua PART 1/1B. Owner's own words: "Lets high
    -- command switch features on and off SERVER-WIDE from the tablet, and
    -- tune numbers live." The five tier labels/descriptions below are this
    -- page's OWN plain-language rendering of that file's `tier` field --
    -- see this file's own NUI CONTRACT note on why the server's raw `note`
    -- prose is never forwarded/rendered verbatim.
    'tab_runtime_control', 'runtime_control_heading', 'runtime_control_intro',
    'runtime_control_disabled_note', 'runtime_features_heading',
    'runtime_features_empty', 'runtime_tunables_heading', 'runtime_tunables_empty',
    'column_tier', 'column_current_value', 'column_range', 'column_type',
    'runtime_tier_live', 'runtime_tier_live_desc',
    'runtime_tier_onstart', 'runtime_tier_onstart_desc',
    'runtime_tier_rawtoplevel', 'runtime_tier_rawtoplevel_desc',
    'runtime_tier_clientonly', 'runtime_tier_clientonly_desc',
    'runtime_tier_protected', 'runtime_tier_protected_desc',
    'runtime_tier_unaudited', 'runtime_tier_unaudited_desc',
    'runtime_value_on', 'runtime_value_off', 'runtime_overridden_by_at',
    'runtime_feature_toggle_on_label', 'runtime_feature_toggle_off_label',
    'runtime_feature_reset_label',
    'runtime_error_denied', 'runtime_error_rate_limited', 'runtime_error_db_error',
    'runtime_feature_error_invalid_feature', 'runtime_feature_error_invalid_value',
    'runtime_tunable_edit_label', 'runtime_tunable_save_label',
    'runtime_tunable_cancel_label', 'runtime_tunable_reset_label',
    'runtime_tunable_type_integer', 'runtime_tunable_type_decimal',
    'runtime_tunable_error_invalid_key', 'runtime_tunable_error_out_of_range',
    'runtime_tunable_error_not_integer', 'runtime_tunable_error_not_a_number',
    -- K9 Audit Trail viewer (its own tab -- see this file's own NUI
    -- CONTRACT section on tablet:auditCert/Partner/Search/Xp/Dept). NOT
    -- YET present in locales/en.json's `tablet` group as of this pass --
    -- flagged to that file's owner (see this pass's own report for the
    -- full key -> English-string list); BuildTabletStrings()'s own
    -- pcall-per-key guard means each is simply omitted from `strings`
    -- until added there, and html/tablet.js's own DEFAULT_STRINGS covers
    -- that exact gap in the meantime, same resilience-net role it already
    -- documents for every other key.
    'tab_audit', 'audit_heading', 'audit_intro', 'audit_disabled_note',
    'audit_mode_cert', 'audit_mode_partner', 'audit_mode_search', 'audit_mode_xp',
    'audit_mode_dept', 'audit_citizenid_label', 'audit_citizenid_placeholder',
    'audit_department_label', 'audit_department_placeholder', 'audit_department_hint',
    'audit_search_mode_label', 'audit_search_mode_officer', 'audit_search_mode_plate',
    'audit_search_mode_person', 'audit_search_mode_recent', 'audit_value_label',
    'audit_value_placeholder_citizenid', 'audit_value_placeholder_plate',
    'audit_limit_label', 'audit_run_label', 'audit_result_empty', 'audit_result_prompt',
    'audit_error_not_authorized', 'audit_error_rate_limited', 'audit_error_invalid_args',
    'audit_boolean_yes', 'audit_boolean_no', 'audit_na', 'column_active',
    'column_granted_by', 'column_granted_at', 'column_revoked_by', 'column_revoked_at',
    'column_k9', 'column_handler', 'column_established_by', 'column_established_at',
    'column_ended_by', 'column_ended_at', 'column_searched_at', 'column_searcher',
    'column_searcher_job', 'column_target_type', 'column_target', 'column_result',
    'column_weight', 'column_alert_tier', 'column_audit_xp', 'column_updated_at',
    -- CERTIFICATION TIER / RENEWAL / SPECIALIZATION (this pass) -- the
    -- person screen's certification row grows a tier control, a renew
    -- button, and a specializations sub-list (buildCertificationRow).
    -- SAME disclosed-gap posture as the 'tab_audit'/'audit_*' block
    -- immediately above (added by a concurrent pass): these 7 keys are
    -- NOT YET present in locales/en.json's `tablet` group as of this pass
    -- -- flagged to that file's owner (see this pass's own report for the
    -- exact key -> English-string list). BuildTabletStrings()'s own
    -- pcall-per-key guard means each is simply omitted from `strings`
    -- until added there, and html/tablet.js's own DEFAULT_STRINGS covers
    -- that exact gap in the meantime.
    'tier_label', 'tier_set_label', 'renew_label', 'specializations_heading',
    'no_specializations', 'expires_label', 'expired_badge',
}

--- Builds the FULL, localized `strings` payload for tablet:open, one
--- locale() call per TABLET_STRING_KEYS entry against locales/en.json's
--- `tablet` group (e.g. `locale('tablet.title')`). Pcall-wrapped PER KEY,
--- matching AwaitServerCallback's own fail-safe posture just below -- a
--- single missing/misconfigured key must never abort the whole payload or
--- throw out of OpenTablet(); it is simply omitted, and html/tablet.js's
--- own DEFAULT_STRINGS (kept, unchanged, in that file) covers exactly that
--- gap for that one key, same "resilience net" role it already documents.
--- @return table<string,string>
local function BuildTabletStrings()
    local strings = {}
    for i = 1, #TABLET_STRING_KEYS do
        local key = TABLET_STRING_KEYS[i]
        local ok, value = pcall(locale, 'tablet.' .. key)
        if ok and type(value) == 'string' then
            strings[key] = value
        end
    end
    return strings
end

--- The ONE place this file ever calls SetNuiFocus(false, false) -- see
--- FOCUS/CLOSE DISCIPLINE. No access/state check beyond "is it open" --
--- a close/termination path must never be gated (this codebase's "no
--- unbounded trap" rule; see client/recall.lua's header). Idempotent --
--- html/tablet-bridge.js's own header documents firing tablet:close from
--- more than one path and expects Lua to treat a repeat as a safe no-op.
function CloseTablet()
    if not tabletOpen then return end

    tabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'tablet:close', data = {} })
end

--- ESC-close + own-death watch -- one thread for both, mirrors
--- client/vision.lua's maintenance-thread lifecycle guard exactly:
--- started only from OpenTablet(), a no-op while already running,
--- self-resetting the instant `tabletOpen` goes false.
---
--- Wait(0) is correct here, not a "no tight loop" violation:
--- DisableControlAction must be re-asserted every frame to suppress the
--- native pause menu (it does not persist across frames on its own), and
--- this thread's lifetime is already bounded to "while the tablet is
--- open," never a perpetual idle poll.
local tabletWatchThreadRunning = false
local function EnsureTabletWatchThreadRunning()
    if tabletWatchThreadRunning then return end
    tabletWatchThreadRunning = true

    CreateThread(function()
        while tabletOpen do
            -- INPUT_FRONTEND_PAUSE (200) -- standard FiveM ESC-closeable-NUI
            -- idiom: DisableControlAction suppresses the native pause menu;
            -- IsDisabledControlJustPressed (the DISABLED variant -- plain
            -- IsControlJustPressed stops reporting a press once a control
            -- is disabled) detects the keypress in that same frame.
            DisableControlAction(0, 200, true)

            if IsDisabledControlJustPressed(0, 200) then
                CloseTablet()
            elseif IsEntityDead(PlayerPedId()) then
                -- Same IsEntityDead(PlayerPedId()) polling shape already
                -- established by client/vision.lua/screenfx.lua/
                -- propattachment.lua/fetch.lua/vehicle.lua for "clean up
                -- per-ped state on death, since respawn reuses the ped
                -- handle" -- applied here to a focus grab.
                CloseTablet()
            end

            Wait(0)
        end

        tabletWatchThreadRunning = false
    end)
end

--- Opens the K9 Command Tablet for the LOCAL player. Exposed globally for
--- a future client/radial.lua entry (this pass's report names it).
---
--- NO server round trip before opening -- html/tablet.js's own design
--- opens immediately and shows a loading/error state INSIDE the tablet
--- while tablet:requestMyRecord resolves (its buildViewerGate()), rather
--- than this file deciding "authorized enough to even open" itself. That
--- is also what makes "every k9 or handler can open the tablet and see
--- whatever they've been certified in" true for someone not yet
--- certified: they still open it and see why, instead of never opening
--- at all.
--- @return nil
function OpenTablet()
    if tabletOpen then return end

    tabletOpen = true
    SendNUIMessage({
        action = 'tablet:open',
        data = {
            capabilities = Config.Permissions, -- shared config, no round trip
            strings = BuildTabletStrings(), -- locales/en.json's `tablet` group, one key per html/tablet.js's own DEFAULT_STRINGS -- see this file's header LOCALIZATION note
            maxXpPerGrant = (type(Config.HighCommand) == 'table' and type(Config.HighCommand.maxXpPerGrant) == 'number')
                and Config.HighCommand.maxXpPerGrant or nil,
            peds = Config.Peds, -- shared config, no round trip -- see this file's header NUI CONTRACT note on tablet:assignK9Role
            themingEnabled = Config.Features and Config.Features.TabletTheming == true, -- UX hint only, see NUI CONTRACT
            shopLocationsEnabled = Config.Features and Config.Features.K9EquipmentShop == true, -- UX hint only, SAME shape as themingEnabled -- see NUI CONTRACT
            runtimeControlEnabled = Config.Features and Config.Features.RuntimeFeatureControl == true, -- UX hint only, SAME shape as themingEnabled/shopLocationsEnabled -- see NUI CONTRACT
            -- UX hint only, but a MEANINGFULLY DIFFERENT shape from the
            -- three above: server/admin.lua gates its five tabletAudit*
            -- callbacks at REGISTRATION TIME behind this SAME flag (if not
            -- `true`, none of them are ever registered at all, not merely a
            -- runtime no-op) -- so unlike themingEnabled/shopLocationsEnabled/
            -- runtimeControlEnabled (whose underlying read callbacks stay
            -- live either way), a tabletAudit* call made while this is
            -- false would hang until AwaitServerCallback's own pcall
            -- synthesizes a generic 'timeout', not a clean 'feature_disabled'
            -- refusal. html/tablet.js disables the Audit screen's query
            -- controls (and shows a disabled-server-wide note) whenever this
            -- is false, precisely to avoid surfacing that confusing generic
            -- timeout for an officer who otherwise qualifies.
            auditEnabled = Config.Features and Config.Features.AdminAuditCommands == true,
            -- CERTIFICATION SPECIALIZATIONS -- shared config, no round trip,
            -- SAME "no hardcoded list" posture as `peds` above:
            -- Config.K9Specializations (server/certifications.lua's
            -- GrantSpecialization is the real, server-side gate on this
            -- exact same table) is the resource's ONE real specialization
            -- catalog -- html/tablet.js's specialization picker populates
            -- from this, never a hardcoded narcotics/explosives/patrol
            -- list, so an operator-added specialization key appears with
            -- zero UI change the moment it's added to config.lua.
            specializations = (type(Config.K9Specializations) == 'table') and Config.K9Specializations or {},
            branding = (type(Config.CommandTablet) == 'table' and type(Config.CommandTablet.branding) == 'table')
                and Config.CommandTablet.branding or {}, -- shared config, no round trip -- { serverName, logo, theme:{4 colors} } -- see this file's header NUI CONTRACT note
        },
    })
    SetNuiFocus(true, true)
    EnsureTabletWatchThreadRunning()
end

-- ----------------------------------------------------------------------
-- OPENING -- Config.CommandTablet.openMode resolution + registration. See
-- this file's header "OPENING" section for the full trap writeup.
-- ----------------------------------------------------------------------
local cfgTablet = type(Config.CommandTablet) == 'table' and Config.CommandTablet or {}
local openMode = cfgTablet.openMode
if openMode ~= 'command' and openMode ~= 'item' and openMode ~= 'both' then
    print(('[qbx_k9unit] WARNING: Config.CommandTablet.openMode (%s) is not \'command\'/\'item\'/\'both\' -- ' ..
        'falling back to \'command\' so the tablet is not left completely unreachable.'):format(tostring(openMode)))
    openMode = 'command'
end

if openMode == 'command' or openMode == 'both' then
    local tabletCommand = cfgTablet.command
    if type(tabletCommand) == 'string' and tabletCommand ~= '' then
        RegisterCommand(tabletCommand, function() OpenTablet() end, false)
    else
        print('[qbx_k9unit] WARNING: Config.CommandTablet.command is missing or not a valid string -- the K9 Command Tablet will not be reachable by command this session.')
    end
end

if openMode == 'item' or openMode == 'both' then
    --- Runtime existence guard for the K9Compat-detected inventory's
    --- UseItem method -- same PURPOSE as the pre-compat-layer
    --- `IsOxInventoryUseCapable` this replaces (mirrors
    --- client/inventory.lua's IsOxInventoryOpenCapable's GetResourceState +
    --- pcall'd export-access shape at the adapter-build layer), but now
    --- asks the compat layer's own detection result instead of probing
    --- `exports.ox_inventory` directly, so this guard -- and its warning --
    --- are correct for WHATEVER inventory Config.Compat resolved, not only
    --- ox_inventory. `K9Compat.Which('inventory')` returns a non-nil
    --- resourceName only when a real, verified adapter is currently active
    --- for this realm; `K9Compat.Get('inventory')` itself is NEVER nil (see
    --- shared/compat/core.lua's own header) so it cannot be used for this
    --- existence check on its own -- its no-op stub would silently satisfy
    --- a bare `type(...) == 'table'` test.
    --- @return boolean
    local function IsInventoryUseCapable()
        return K9Compat.Which('inventory') ~= nil
    end

    -- Purely LOCAL client event (never networked -- no `source`, no
    -- forgery surface beyond "another local script on this same client
    -- opening the tablet early," which is harmless), matching ox_inventory's
    -- own real, documented `item.client.event` dispatch mechanism
    -- (verified against overextended/ox_inventory's modules/items/client.lua
    -- this pass: item definitions carry a `client = { export=... } |
    -- { event=... }` field, dispatched via a plain, non-networked
    -- TriggerEvent). THE OPERATOR'S OWN ox_inventory items.lua entry for
    -- Config.CommandTablet.itemName must set `client = { event =
    -- 'qbx_k9unit:client:useTabletItem' }` for this to ever fire at all --
    -- this resource cannot create or edit that entry (same "cannot create
    -- the item itself" limitation config.lua's own comment already states
    -- for the item's mere EXISTENCE); documented here, and in this pass's
    -- own report, not assumed silently.
    AddEventHandler('qbx_k9unit:client:useTabletItem', function(data, slot)
        if not IsInventoryUseCapable() then
            print('[qbx_k9unit] WARNING: the K9 Command Tablet item was used, but no usable inventory adapter is currently detected (Config.Compat) -- cannot open. Run /k9compat (if enabled) to see why.')
            lib.notify({ title = locale('common.notify_title'), description = locale('tablet.open_failed_generic'), type = 'error' })
            return
        end

        -- useItem's own callback tells us whether the SERVER actually
        -- approved this use (still holds the item, etc.) -- OpenTablet()
        -- only runs on a truthy result, never optimistically before that
        -- confirmation lands. Config.CommandTablet.consumeItemOnUse is NOT
        -- something this call can override -- ox_inventory consumes (or
        -- doesn't) per the item's OWN `consume` field in the operator's
        -- items.lua, which this resource does not own; consumeItemOnUse is
        -- a documented EXPECTATION for what that field should be set to
        -- (0/false for a reusable tablet), not an enforced override -- see
        -- this pass's own report. Routed through K9Compat.Get('inventory')
        -- rather than `exports.ox_inventory:useItem` directly this pass
        -- (shared/compat/core.lua) -- the adapter's own UseItem is already
        -- pcall-safe and guarantees `cb` fires exactly once even if the
        -- underlying export throws (see shared/compat/inventory.lua's own
        -- UseItem doc comment), so no additional guard is needed here
        -- beyond the IsInventoryUseCapable() check above.
        K9Compat.Get('inventory').UseItem(data, function(approved)
            if approved then OpenTablet() end
        end)
    end)
end

-- ----------------------------------------------------------------------
-- SECTION 2 -- tablet:triggerFeature. Keyed by Config.Features NAME
-- (e.g. 'BiteAndHold'), matching html/tablet.js's `myFeatures[].key`
-- exactly -- the SERVER decides which keys are even sent/actionable
-- (tabletRequestMyRecord's own resolution), this file only needs an
-- entry for a key it might be asked to fire. Each `run()` mirrors
-- client/radial.lua's own onSelect gate CHOICE for that action
-- line-for-line (cited per entry) -- see RIGHT-VS-WRONG above.
--
-- DISCLOSED SIMPLIFICATION: three Config.Features keys cover MORE than
-- one distinct action in client/radial.lua (HandlerPartnership: Partner
-- Up vs Break Partnership; HandlerDownDefense: confirm-bite vs
-- confirm-takedown; FetchMechanic: throw/release vs recall) -- this
-- contract's `{feature}`-only payload (no extra args) has room for
-- exactly ONE behavior per key. Each is given the single most defensible
-- default below (documented per entry) rather than left unreachable; a
-- future JS revision that wants the explicit choice back would need an
-- `args` addition to the trigger payload, which is this file's call to
-- make once asked for, not assumed here.
-- 'Sit' has no Config.Features key of its own (radial.lua's own comment:
-- "bundled under the general RadialMenu flag") and so has no entry here
-- -- the server-driven myFeatures list has nothing to key it under either.
-- ----------------------------------------------------------------------
local FEATURE_TRIGGERS = {
    -- radial.lua 'k9_leash': Detach UNGATED, Attach gated + nearest candidate.
    LeashMechanics = function()
        if type(IsLeashed) == 'function' and IsLeashed() then
            if type(DetachLeash) == 'function' then DetachLeash() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(FindNearestLeashCandidate) ~= 'function' then return false, 'not_available' end
        local candidateServerId = FindNearestLeashCandidate()
        if not candidateServerId then
            lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_leash_candidate'), type = 'error' })
            return false, 'not_available'
        end
        if type(RequestLeashAttach) == 'function' then RequestLeashAttach(candidateServerId) end
        return true
    end,
    -- radial.lua 'k9_vehicle': BOTH directions gated.
    VehicleEntryExit = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
            if type(ExitK9Vehicle) == 'function' then ExitK9Vehicle() end
        elseif type(EnterNearestK9Vehicle) == 'function' then
            EnterNearestK9Vehicle()
        end
        return true
    end,
    -- radial.lua 'k9_bark' (non-AdvancedBarkRadial literal only -- no
    -- variant arg in this contract, see DISCLOSED SIMPLIFICATION above).
    BasicBarkSounds = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        TriggerServerEvent('qbx_k9unit:server:relayBark', 'bark')
        return true
    end,
    -- radial.lua 'k9_track_scent'/'k9_track_blood'/'k9_track_gunpowder':
    -- each stops itself if already the active type, else starts.
    ScentTracking = function()
        if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'scent' then
            if type(StopTracking) == 'function' then StopTracking() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(StartScentTrack) == 'function' then StartScentTrack() end
        return true
    end,
    BloodTracking = function()
        if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'blood' then
            if type(StopTracking) == 'function' then StopTracking() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(StartBloodTrack) == 'function' then StartBloodTrack() end
        return true
    end,
    GunpowderSniffing = function()
        if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'gunpowder' then
            if type(StopTracking) == 'function' then StopTracking() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(StartGunpowderTrack) == 'function' then StartGunpowderTrack() end
        return true
    end,
    -- NOT in client/radial.lua at all (keybind-only by design). Both
    -- Toggle*Vision() already gate + notify internally (IsOwnModelK9()
    -- only, per client/vision.lua's own RESOLVED ACCESS-GATING DECISION)
    -- -- call straight through.
    ThermalVision = function()
        if type(ToggleThermalVision) == 'function' then ToggleThermalVision(); return true end
        return false, 'not_available'
    end,
    NightVision = function()
        if type(ToggleNightVision) == 'function' then ToggleNightVision(); return true end
        return false, 'not_available'
    end,
    -- radial.lua 'k9_bite_hold': Release UNGATED, Attempt gated.
    BiteAndHold = function()
        if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
            if type(ReleaseBiteHold) == 'function' then ReleaseBiteHold() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestBiteHold) == 'function' then RequestBiteHold() end
        return true
    end,
    -- radial.lua 'k9_takedown': one-shot, gated, no release counterpart.
    NonLethalTakedown = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestTakedown) == 'function' then RequestTakedown() end
        return true
    end,
    -- radial.lua 'k9_drag': Release UNGATED, Attempt gated.
    PropDragging = function()
        if type(IsDragEngaged) == 'function' and IsDragEngaged() then
            if type(ReleaseDrag) == 'function' then ReleaseDrag() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestDrag) == 'function' then RequestDrag() end
        return true
    end,
    -- DISCLOSED SIMPLIFICATION: radial.lua exposes Partner Up and Break
    -- Partnership as two SEPARATE always-offered items specifically to
    -- dodge IsPartnered()'s own documented cache-staleness gap (see that
    -- file's "KNOWN CACHE-STALENESS GAP" section). This single-button
    -- contract cannot offer both, so this toggles off the same local cache
    -- read anyway -- a reconnected, genuinely-partnered player who hits
    -- staleness here gets RequestPartnerUp()'s own "already partnered"
    -- server rejection instead of the Break option, same bounded failure
    -- mode client/partnership.lua's own ox_target predicate already
    -- tolerates for the identical reason.
    HandlerPartnership = function()
        if type(IsPartnered) == 'function' and IsPartnered() then
            if type(BreakPartnership) == 'function' then BreakPartnership() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(FindNearestPartnerCandidate) ~= 'function' then return false, 'not_available' end
        local candidateServerId = FindNearestPartnerCandidate()
        if not candidateServerId then
            lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_partner_candidate'), type = 'error' })
            return false, 'not_available'
        end
        if type(RequestPartnerUp) == 'function' then RequestPartnerUp(candidateServerId) end
        return true
    end,
    -- radial.lua 'k9_recall': UNGATED, unconditional.
    Recall = function()
        if type(RequestRecall) == 'function' then RequestRecall() end
        return true
    end,
    -- DISCLOSED SIMPLIFICATION: defaults to 'bite', matching
    -- ConfirmHandlerDownDefense()'s own documented default-action-type
    -- reasoning ("bite-and-hold... has no additional precondition beyond
    -- the shared validation prefix"). The explicit bite-vs-takedown choice
    -- radial.lua's own two-item submenu offers is not reachable through
    -- this single-button contract.
    HandlerDownDefense = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(ConfirmHandlerDownDefense) == 'function' then ConfirmHandlerDownDefense('bite') end
        return true
    end,
    -- DISCLOSED SIMPLIFICATION: throw/release toggle only (radial.lua's
    -- own Throw item shape) -- Recall Fetch Ball is a separate action in
    -- radial.lua with no feature key of its own to hang off here.
    -- Gated on HasK9Access() ONLY, matching RequestThrowFetchBall()'s own
    -- doc comment verbatim (a human-handler action).
    FetchMechanic = function()
        if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then
            if type(ReleaseFetchBall) == 'function' then ReleaseFetchBall() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestThrowFetchBall) == 'function' then RequestThrowFetchBall() end
        return true
    end,
    -- radial.lua 'k9_prop_attachment': gated (redundant with the callee, kept for consistency).
    PropAttachments = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestToggleK9PropAttachment) == 'function' then RequestToggleK9PropAttachment() end
        return true
    end,
    -- radial.lua 'k9_deploy_kennel': gated (redundant with the callee, kept for consistency).
    DeployableKennel = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestDeployKennel) == 'function' then RequestDeployKennel() end
        return true
    end,
    -- radial.lua 'k9_open_inventory': gated (redundant with the callee, kept for consistency).
    K9Inventory = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestOpenOwnK9Inventory) == 'function' then RequestOpenOwnK9Inventory() end
        return true
    end,
    -- radial.lua 'k9_treat_nearest': gated (redundant with the callee, kept for consistency).
    K9Medkit = function()
        if not CanShowK9UI() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestTreatNearestK9) == 'function' then RequestTreatNearestK9() end
        return true
    end,
    -- NOT YET in client/radial.lua (client/wellbeing.lua's own header:
    -- "a future radial menu entry should call this"). RequestK9CalmDown()
    -- is FULLY self-gating internally -- call straight through.
    FearStressSystem = function()
        if type(RequestK9CalmDown) == 'function' then RequestK9CalmDown() end
        return true
    end,
}

RegisterNUICallback('tablet:triggerFeature', function(data, cb)
    -- Pure UX toggle, not an authorization boundary -- see SECURITY NOTE.
    if not (Config.FeatureControl and Config.FeatureControl.allowActionsFromTablet == true) then
        cb({ ok = false, error = 'actions_disabled' })
        return
    end
    if type(data) ~= 'table' or type(data.feature) ~= 'string' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end

    local trigger = FEATURE_TRIGGERS[data.feature]
    if not trigger then
        cb({ ok = false, error = 'unknown_action' })
        return
    end

    local ok, errorCode = trigger()
    cb({ ok = ok == true, error = (ok ~= true) and (errorCode or 'not_available') or nil })
end)

-- ----------------------------------------------------------------------
-- SECTION 3 -- tablet:decertify's own command bridge. Submits the EXACT
-- SAME command string the chat box would, via `ExecuteCommand` (verified
-- this pass: ext/native-decls/ExecuteCommand.md returns HTTP 200,
-- `apiset: shared`). The command's own RegisterCommand handler is the one
-- and only place that authorizes anything here (IsEligibleCertifier) --
-- this bridge adds no authority, exactly the "one code path"
-- RIGHT-VS-WRONG note above demands.
--
-- ALLOWLISTED BY NAME, never "run anything" -- server/highcommand.lua's
-- own header already rejected a generic passthrough for the identical
-- reason. Every arg token is checked for whitespace/control characters
-- before being concatenated into a command string, so a malformed NUI
-- payload can't inject a second command or shift argument positions.
--
-- REMOVED THIS PASS: a broader 'tablet:runCommand' NUI callback used to
-- expose this same SubmitAllowlistedCommand plumbing generically, keyed
-- by an allowlist of NINE command names (k9certify, k9decertify,
-- k9decertifyoffline, k9givexp, plus five k9audit* commands from
-- server/admin.lua). A frontend sweep (html/, exhaustive) found zero
-- references to 'tablet:runCommand' anywhere, and it was never even part
-- of this file's own documented NUI CONTRACT above -- unlike every other
-- callback in this file, no html/tablet.js UI element ever fired it.
-- Eight of those nine allowlisted names had NO OTHER caller either (only
-- k9decertifyoffline is reachable at all, via tablet:decertify's direct,
-- hardcoded call to SubmitAllowlistedCommand just below) -- a registered
-- capability nothing could reach, exactly the "dead code that looks live"
-- failure mode this resource has already shipped once before (five files
-- once written, tested, and never registered in the manifest).
--
-- The five k9audit* names specifically were evaluated for a real audit-log
-- tab and rejected -- see this pass's own report for the full reasoning.
-- Short version: every one of them (server/admin.lua) is chat/console-
-- notify oriented at the server layer (RegisterCommand handlers that only
-- ever call NotifyPlayer/ox_lib toast or print() -- see that file's own
-- PresentRows/PrintRowsToConsole, its only two output paths) with no
-- server callback that returns structured row data to a caller. Building
-- an actual audit tab would need a NEW, PROPOSED server callback that runs
-- the SAME query functions already in that file (QueryCertificationHistory
-- etc.) and returns raw rows instead of formatted notify strings -- real
-- server-side work outside this file's ownership, reported to main/
-- coder-backend/coder-security rather than half-built here as another
-- unreachable stub.
-- ----------------------------------------------------------------------
local ALLOWLISTED_TABLET_COMMANDS = {
    k9decertifyoffline = true, -- tablet:decertify's own implementation below -- the only allowlisted name with a real caller
}
local MAX_TABLET_COMMAND_ARGS = 2 -- k9decertifyoffline's exact shape: <citizenid> <job>, its only allowlisted command today

--- @param token any
--- @return boolean
local function IsSafeCommandArgToken(token)
    token = tostring(token)
    return token ~= '' and #token <= 64 and not token:find('[%s;]')
end

--- Shared submit path -- currently only reached from tablet:decertify's
--- internal reuse below, but kept as a small, named-allowlist helper
--- (rather than inlining a single string check into that one call site)
--- so a FUTURE tablet mutation that wants to reuse an existing chat
--- command has one already-vetted place to add its name to, instead of
--- reinventing this validation shape from scratch.
--- @param command string
--- @param args table?
--- @return boolean ok
--- @return string? errorCode
local function SubmitAllowlistedCommand(command, args)
    if not ALLOWLISTED_TABLET_COMMANDS[command] then return false, 'invalid_args' end
    args = type(args) == 'table' and args or {}
    if #args > MAX_TABLET_COMMAND_ARGS then return false, 'invalid_args' end

    local parts = { command }
    for i = 1, #args do
        if not IsSafeCommandArgToken(args[i]) then return false, 'invalid_args' end
        parts[#parts + 1] = tostring(args[i])
    end

    -- Fire-and-forget, same as a player typing this command themselves --
    -- the command's OWN handler notifies success/failure/authorization
    -- outcome, exactly as it already does for chat-typed usage. `true`
    -- here means only "submitted," never "succeeded" -- a RegisterCommand
    -- handler has no synchronous return value to relay.
    ExecuteCommand(table.concat(parts, ' '))
    return true
end

-- ----------------------------------------------------------------------
-- PART 1 -- VIEW + mutation callbacks matching html/tablet.js's own
-- contract exactly. See this file's header NUI CONTRACT for the full
-- name/payload table.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:ready', function(_, cb)
    cb({})
end)

RegisterNUICallback('tablet:close', function(_, cb)
    CloseTablet()
    cb({})
end)

--- PROPOSED server callback (not yet built -- see this pass's own
--- report). Forwarded verbatim: AwaitServerCallback's own failure shape
--- (`{ok=false, error='timeout'}`) already matches html/tablet.js's
--- `{ok:false, error, message?}` contract directly, and the proposed
--- server side is asked to return the SAME JS-shaped object on success
--- too, so this file needs zero translation logic for these.
RegisterNUICallback('tablet:requestMyRecord', function(_, cb)
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestMyRecord'))
end)

RegisterNUICallback('tablet:requestRoster', function(data, cb)
    local query = (type(data) == 'table' and type(data.query) == 'string') and data.query or ''
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestRoster', query))
end)

RegisterNUICallback('tablet:requestPersonSummary', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestPersonSummary', data.targetCitizenId))
end)

RegisterNUICallback('tablet:requestPersonFeatures', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestPersonFeatures', data.targetCitizenId))
end)

RegisterNUICallback('tablet:certify', function(data, cb)
    -- UPDATED THIS PASS (coordinator-directed follow-up): this comment
    -- used to say certify has "no offline-capable equivalent to reuse,
    -- unlike decertify below" -- that was true when it was written, but
    -- server/certifications.lua's own GrantCertificationForTablet now
    -- resolves an offline `targetCitizenId` to GrantCertificationOffline
    -- internally (see that function's own header for the full "why this
    -- is now safe on the shipped Config.K9Appearance.requireK9ModelForRole
    -- default, and when it deliberately still refuses" writeup). NO CHANGE
    -- NEEDED HERE: this callback was already citizenid-keyed and already
    -- forwarded verbatim, so it transparently gained offline support the
    -- moment the server side did -- exactly like decertify below already
    -- worked this way for revoke.
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletCertify', data.targetCitizenId, data.departmentKey))
end)

RegisterNUICallback('tablet:decertify', function(data, cb)
    -- Maps directly onto the EXISTING '/k9decertifyoffline <citizenid> <job>'
    -- command (server/certifications.lua) -- citizenid-keyed and already
    -- offline-capable, so this needs no new server code at all. Routed
    -- through SECTION 3's SAME allowlisted-command path, not a duplicate.
    --
    -- BUGFIX (this pass): this callback did not check
    -- Config.FeatureControl.allowActionsFromTablet before submitting the
    -- command, even though this file's own header documents that flag as
    -- "checked before SECTION 2/3 dispatch" -- tablet:triggerFeature
    -- (SECTION 2) already did; this SECTION 3 consumer never did, the only
    -- gap of its kind now that the unreachable generic 'tablet:runCommand'
    -- bridge (which DID check it) has been removed. Pure UX toggle, not an
    -- authorization boundary -- see SECURITY NOTE -- but an operator who
    -- turns it off expects EVERY tablet action button inert, not just the
    -- ability-trigger ones.
    if not (Config.FeatureControl and Config.FeatureControl.allowActionsFromTablet == true) then
        cb({ ok = false, error = 'actions_disabled' })
        return
    end
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    local ok, errorCode = SubmitAllowlistedCommand('k9decertifyoffline', { data.targetCitizenId, data.departmentKey })
    cb({ ok = ok, error = (not ok) and errorCode or nil })
end)

-- ----------------------------------------------------------------------
-- CERTIFICATION TIER / RENEWAL / SPECIALIZATION -- closing this file's own
-- biggest remaining "reachable only via net event/command, no tablet path
-- at all" gap (server/certifications.lua's SetCertificationTier/
-- RenewCertification/GrantSpecialization/RevokeSpecialization). Forwarded
-- VERBATIM, mirroring tablet:certify/tablet:grantPermission's own shape
-- EXACTLY: each server callback (server/certifications.lua's
-- tabletSetCertificationTier/tabletRenewCertification/
-- tabletGrantSpecialization/tabletRevokeSpecialization) already returns
-- this contract's `{ok, error?}` shape directly (no `reason` field to
-- translate, unlike TranslateReasonResult's targets below), already
-- re-verifies IsEligibleCertifier/the shared cooldown/TierEditMutex
-- internally, and already resolves online-vs-offline targets itself --
-- this file adds no authorization, no online/offline branching, and no
-- second mutation path of its own. `departmentKey` selects WHICH of the
-- target's per-department certification rows to act on (the tablet
-- already renders one row per configured department, see
-- buildCertificationRow) -- never used to override the target's actual
-- live job when online (server-side `department_mismatch` handles that).
-- ----------------------------------------------------------------------
RegisterNUICallback('tablet:setCertificationTier', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == ''
        or type(data.tier) ~= 'string' or data.tier == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletSetCertificationTier', data.targetCitizenId, data.departmentKey, data.tier))
end)

RegisterNUICallback('tablet:renewCertification', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRenewCertification', data.targetCitizenId, data.departmentKey))
end)

RegisterNUICallback('tablet:grantSpecialization', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == ''
        or type(data.specialization) ~= 'string' or data.specialization == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletGrantSpecialization', data.targetCitizenId, data.departmentKey, data.specialization))
end)

RegisterNUICallback('tablet:revokeSpecialization', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == ''
        or type(data.specialization) ~= 'string' or data.specialization == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRevokeSpecialization', data.targetCitizenId, data.departmentKey, data.specialization))
end)

RegisterNUICallback('tablet:givexp', function(data, cb)
    -- PROPOSED server callback -- see this pass's own report.
    -- server/highcommand.lua's AwardXPDirect(citizenid, amount, reason)
    -- already takes a citizenid directly; this needs that same file's
    -- IsHighCommand/maxXpPerGrant/allowSelfGrant/cooldown/audit checks
    -- wrapped for a citizenid target instead of '/k9givexp's server-id one
    -- -- that file has a live owner, so not built here.
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.amount) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletGiveXp', data.targetCitizenId, data.amount))
end)

--- Translates server/permissions.lua's REAL, already-built response shape
--- (`{ok=true}` | `{ok=true, reason=stillHasAccess}` | `{ok=false,
--- reason=outcome}`) into html/tablet.js's `{ok, error?, message?}`
--- contract. The two `reason` values a successful revoke can still carry
--- (permissions.lua's header: "the tablet is expected to render THREE
--- distinct messages, not two") get real, locale-resolved text; anything
--- else on a failure path is forwarded as an opaque `error` code (JS's
--- own errorText() falls back to a generic message for a code it doesn't
--- specifically recognize -- acceptable today, no player-facing meaning
--- is lost, just not maximally specific).
--- @param serverResult table
--- @return table
local function ReasonToJsResult(serverResult)
    if type(serverResult) ~= 'table' then return { ok = false, error = 'server_error' } end
    if serverResult.ok ~= true then
        return { ok = false, error = serverResult.error or serverResult.reason or 'server_error' }
    end
    if serverResult.reason == 'rank_or_high_command' then
        return { ok = true, message = locale('tablet.revoke_still_has_access') }
    elseif serverResult.reason == 'unknown_target_offline' then
        return { ok = true, message = locale('tablet.revoke_target_offline') }
    end
    return { ok = true }
end

--- Shared shape guard for every grant/revoke/feature/block mutation below.
--- @param data any
--- @return boolean
local function IsValidTargetKeyPayload(data, keyField)
    return type(data) == 'table'
        and type(data.targetCitizenId) == 'string' and data.targetCitizenId ~= ''
        and type(data[keyField]) == 'string' and data[keyField] ~= ''
end

RegisterNUICallback('tablet:grantPermission', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'permission') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.targetCitizenId, data.permission)))
end)

RegisterNUICallback('tablet:revokePermission', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'permission') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.targetCitizenId, data.permission)))
end)

-- Feature grant/revoke/block/unblock all reuse the SAME two, already-built
-- server callbacks with the 'feature.<Name>'/'block.<Name>' key namespace
-- server/permissions.lua's own header documents -- no new server code.
RegisterNUICallback('tablet:grantFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.targetCitizenId, 'feature.' .. data.feature)))
end)

RegisterNUICallback('tablet:revokeFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.targetCitizenId, 'feature.' .. data.feature)))
end)

RegisterNUICallback('tablet:blockFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.targetCitizenId, 'block.' .. data.feature)))
end)

RegisterNUICallback('tablet:unblockFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.targetCitizenId, 'block.' .. data.feature)))
end)

-- ----------------------------------------------------------------------
-- K9 ROLE ASSIGN / REVERT-TO-HUMAN -- owner's own words: "assign de
-- assign give certs remove certs remove k9 ped and reverts them to a
-- human". Both forwarded VERBATIM -- server/tablet.lua's own
-- tabletAssignK9Role/tabletRevertK9Ped already return this exact
-- {ok,error?,message?} shape and already re-verify IsHighCommand
-- themselves (see that file's own header); this file adds no
-- authorization and no second appearance-mutation path. THE TABLET IS A
-- VIEW. IT DECIDES NOTHING -- same rule as every other mutation above.
-- ----------------------------------------------------------------------
RegisterNUICallback('tablet:assignK9Role', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.modelName) ~= 'string' or data.modelName == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAssignK9Role', data.targetCitizenId, data.modelName))
end)

--- NO UNBOUNDED TRAP: server/tablet.lua's tabletRevertK9Ped gates purely on
--- the CALLER's own IsHighCommand, never on anything about the target, so
--- this must work for a target who has already lost every certification/
--- grant/feature check -- see this file's own header NUI CONTRACT note.
RegisterNUICallback('tablet:revertK9Ped', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRevertK9Ped', data.targetCitizenId))
end)

-- ----------------------------------------------------------------------
-- TABLET THEMING -- Config.Features.TabletTheming. COSMETIC ONLY (see
-- server/runtimecontrol.lua's own PART 2 header): nothing a theme value
-- carries is ever consulted by an authorization check, here or anywhere
-- else in this resource. getTheme has no authorization gate server-side
-- at all (applied for every viewer); setTheme/resetTheme re-check high
-- command server-side regardless of what this page shows or hides.
-- ----------------------------------------------------------------------

--- SHARED translator for every tablet-facing surface that mirrors
--- server/runtimecontrol.lua's own raw `{ok, reason?, ...}` response shape
--- DIRECTLY, rather than this contract's own `{ok, error?, message?}`
--- shape -- currently server/runtimecontrol.lua's own tabletGetTheme/
--- tabletSetTheme/tabletResetTheme (Config.Features.TabletTheming) AND
--- server/certtiers.lua's certTiersList/certTiersUpsert/certTiersReorder/
--- certTiersDelete, whose OWN header says so explicitly: "Response shape
--- mirrors server/runtimecontrol.lua's own `{ ok, reason, ... }` convention
--- exactly, for consistency across this resource's tablet-facing surfaces."
---
--- THE ASYMMETRY THIS FIXES (flagged by the server side, bridged here --
--- CLIENT/coder-ui owns this translation, not server/certtiers.lua, so
--- that file's own response shape can keep matching its sibling
--- server/runtimecontrol.lua's convention without also having to know
--- anything about html/tablet.js's separate, older `error`-keyed
--- contract): every OTHER tablet mutation in this resource already
--- resolves to `{ok, error?, message?}` by the time it reaches
--- html/tablet.js -- ReasonToJsResult above performs the identical
--- `reason` -> `error` rename for server/permissions.lua's grant/revoke
--- pair. Left unbridged, a rejected cert-tier/theme edit would arrive at
--- the NUI as `{ok:false, reason:'...'}` with NO `error` key at all --
--- html/tablet.js's own errorText()/generic failure-notice paths only ever
--- read `.error`/`.message`, so the tablet would render nothing, the
--- single worst outcome for an admin tool (a click that visibly does
--- nothing is indistinguishable from a hang).
---
--- Deliberately GENERIC, not hand-listing each surface's own extra fields
--- (theme/field/tiers/capabilityCatalog/warning/referenceCount, ...): every
--- key from `serverResult` is forwarded verbatim except `reason` itself,
--- which is renamed to `error` (only when `ok` is not `true`, and only if
--- `error` was not already set some other way) and then removed, since the
--- JS-facing contract has no `reason` field of its own to leave dangling
--- alongside it. A future fifth surface built the same way needs no edit
--- here at all.
--- @param serverResult table
--- @return table
local function TranslateReasonResult(serverResult)
    if type(serverResult) ~= 'table' then return { ok = false, error = 'server_error' } end
    local out = {}
    for k, v in pairs(serverResult) do out[k] = v end
    if out.ok ~= true and out.error == nil then
        out.error = out.reason or 'server_error'
    end
    out.reason = nil
    return out
end

RegisterNUICallback('tablet:getTheme', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:tabletGetTheme')))
end)

RegisterNUICallback('tablet:setTheme', function(data, cb)
    -- Deliberately NO field-by-field re-validation here beyond "is this
    -- even a table" -- server/runtimecontrol.lua's ValidateFullTheme is
    -- the real, strict gate (exact #RRGGBB match, a fixed density enum, a
    -- <=40-char/no-markup header title) and this file must never re-derive
    -- or loosen that; a modified client sending a bogus payload gets back
    -- {ok=false, error='invalid_field', field=...} same as a legitimate one
    -- that somehow raced a config change.
    if type(data) ~= 'table' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:tabletSetTheme', data)))
end)

RegisterNUICallback('tablet:resetTheme', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:tabletResetTheme')))
end)

-- ----------------------------------------------------------------------
-- CERTIFICATION TIER EDITING -- server/certtiers.lua, high command only
-- (CanManageCertTiers re-checked there on every call; this file adds no
-- authorization of its own). Every payload shape below is forwarded
-- EXACTLY as that file's own callbacks expect -- see its own header
-- "CALLBACKS" section: certTiersUpsert takes the WHOLE {key,label,
-- capabilities:string[]} table as one argument (mirrors tablet:setTheme's
-- own whole-table forwarding just above), certTiersReorder takes a bare
-- array of tier key strings, certTiersDelete takes a bare key string.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:certTiersList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersList')))
end)

RegisterNUICallback('tablet:certTiersUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersUpsert', data)))
end)

RegisterNUICallback('tablet:certTiersReorder', function(data, cb)
    if type(data) ~= 'table' or type(data.orderedKeys) ~= 'table' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersReorder', data.orderedKeys)))
end)

RegisterNUICallback('tablet:certTiersDelete', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- 'tier_in_use'/'protected_tier' are REFUSALS ("cannot, and here is
    -- why"), not errors -- forwarded through the SAME translation
    -- regardless (TranslateReasonResult does not distinguish a refusal
    -- from a failure; html/tablet.js's own certTierErrorText() is what
    -- renders 'tier_in_use' with its own explanatory copy instead of a
    -- generic failure message -- see that function for the full list).
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersDelete', data.key)))
end)

-- ----------------------------------------------------------------------
-- PERMISSION-KEY CATALOG EDITING -- server/permissionkeycatalog.lua, high
-- command only (CanManagePermissionKeys re-checked there on every call;
-- this file adds no authorization of its own). Owner's own words for this
-- pass: "...even add or remove permissions" -- the second half of the same
-- ask server/certtiers.lua's own tier-editing screen above already
-- answers for certification ROLES. Sits alongside that screen in
-- html/tablet.js, not in a new unrelated place. Same "CALLBACKS" shape as
-- certTiers* above: permKeysUpsert takes the WHOLE {key,label,description?}
-- table as one argument, permKeysDelete takes a bare key string. There is
-- no reorder counterpart -- a permission key carries no ordinal (see
-- server/permissionkeycatalog.lua's own header "WHY NO ORDINAL").
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:permKeysList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:permKeysList')))
end)

RegisterNUICallback('tablet:permKeysUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:permKeysUpsert', data)))
end)

RegisterNUICallback('tablet:permKeysDelete', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- 'reserved_namespace'/'unknown_key' are REFUSALS ("cannot, and here is
    -- why"), not failures -- forwarded through the SAME translation
    -- regardless, same posture as certTiersDelete's own 'tier_in_use'/
    -- 'protected_tier' immediately above.
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:permKeysDelete', data.key)))
end)

-- ----------------------------------------------------------------------
-- XP-RANK EDITOR -- server/xptiers.lua, high command only
-- (CanManageXPTiers re-checked there on every call; this file adds no
-- authorization of its own). Owner's own words for this pass: "...set
-- experience level for each rank up etc." -- the OTHER half of the same
-- quote server/permissionkeycatalog.lua's own screen above answers for
-- permission keys. Same "CALLBACKS" shape as certTiers*/permKeys* above:
-- xpTiersUpsert takes the WHOLE payload table as one argument. There is no
-- delete/create/reorder counterpart -- see server/xptiers.lua's own header
-- "SCOPE DECISION" for why this pass edits existing ranks only.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:xpTiersList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:xpTiersList')))
end)

RegisterNUICallback('tablet:xpTiersUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.ordinal) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- 'base_tier_xp_fixed' is a REFUSAL ("cannot, and here is why" -- rank
    -- 1 must always be exactly 0 XP), not a failure -- forwarded through
    -- the SAME translation regardless, same posture as certTiersDelete's
    -- own 'tier_in_use'/'protected_tier' above.
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:xpTiersUpsert', data)))
end)

-- ----------------------------------------------------------------------
-- K9 EQUIPMENT SHOP LOCATIONS -- server/equipmentshop.lua, high command
-- only (CanManageShopLocations re-checked there on every mutating call;
-- GetLocations itself has no gate server-side at all -- see this file's
-- header NUI CONTRACT note). Owner's own words: "make the shop a dog ped
-- and i can change the locations in the config or add more locations
-- remove locations etc along with in the high command tablet."
--
-- COORDINATES: html/tablet.js (a CEF browser page) has NO native access to
-- GetEntityCoords/GetEntityHeading -- this file is the ONLY place in the
-- whole round trip that can capture "where is the caller standing right
-- now," so both mutating callbacks below do it themselves, at the moment
-- each fires, rather than trusting anything the NUI payload claims (which
-- could not even supply it in the first place). Every response is routed
-- through the SAME TranslateReasonResult already used for theme/cert-tier
-- calls above -- server/equipmentshop.lua's own header states its response
-- shape is a plain `{ ok, reason, ... }` outcome table, identical
-- convention.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:equipmentShopGetLocations', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopGetLocations')))
end)

--- DISCLOSED SIMPLIFICATION: a blank label/model/scenario field in the NUI
--- payload is OMITTED here entirely (never forwarded as `''`, which the
--- server's own IsSafeShortString would reject as invalid) -- meaning
--- "inherit the shop-wide default," exactly like a config.lua location
--- entry with that field left unset. This contract has no way to ADD a
--- location with an EXPLICIT "no scenario even though the shop default has
--- one" override in one step (unlike editing one afterward, just below,
--- which can via `false`) -- an operator who needs that reaches for Edit
--- immediately after adding. See html/tablet.js's own comment on its Add
--- form for the matching client-side half of this choice.
RegisterNUICallback('tablet:equipmentShopAddLocation', function(data, cb)
    data = type(data) == 'table' and data or {}

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local location = {
        x = coords.x,
        y = coords.y,
        z = coords.z,
        heading = GetEntityHeading(ped),
    }
    if type(data.label) == 'string' and data.label ~= '' then location.label = data.label end
    if type(data.model) == 'string' and data.model ~= '' then location.model = data.model end
    if type(data.scenario) == 'string' and data.scenario ~= '' then location.scenario = data.scenario end

    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopAddLocation', location)))
end)

--- Serves BOTH this screen's "Edit" (metadata only) and "Move Here"
--- (position only) actions -- ONE server callback, so both flow through
--- here rather than each inventing its own. See this file's header NUI
--- CONTRACT note for the full `updates`/`useCurrentPosition` shape.
RegisterNUICallback('tablet:equipmentShopMoveLocation', function(data, cb)
    if type(data) ~= 'table' or type(data.locationKey) ~= 'string' or data.locationKey == '' then
        cb({ ok = false, error = 'invalid_key' })
        return
    end

    local updates = {}
    if type(data.updates) == 'table' then
        -- ALWAYS forwarded when present (never omitted for being blank,
        -- unlike Add above) -- an edit draft always starts pre-filled from
        -- a real, already-resolved value (server/equipmentshop.lua's own
        -- ShopLocation class: model/label are "already resolved ... never
        -- nil/empty"; scenario's OWN doc comment there is narrower --
        -- "'' means 'no scenario', never nil" -- so a blank scenario field
        -- can legitimately mean "already resolved to no scenario," not
        -- only "untouched"), so html/tablet.js sends `false` for a field
        -- the operator deliberately blanked out (reset to the shop-wide
        -- default -- a genuine no-op if that field already resolved to
        -- empty/default) and a non-empty string for a real override --
        -- both are meaningful values this file must not silently drop.
        if data.updates.label ~= nil then updates.label = data.updates.label end
        if data.updates.model ~= nil then updates.model = data.updates.model end
        if data.updates.scenario ~= nil then updates.scenario = data.updates.scenario end
    end

    if data.useCurrentPosition == true then
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        updates.x, updates.y, updates.z = coords.x, coords.y, coords.z
        updates.heading = GetEntityHeading(ped)
    end

    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopMoveLocation', data.locationKey, updates)))
end)

RegisterNUICallback('tablet:equipmentShopRemoveLocation', function(data, cb)
    if type(data) ~= 'table' or type(data.locationKey) ~= 'string' or data.locationKey == '' then
        cb({ ok = false, error = 'invalid_key' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopRemoveLocation', data.locationKey)))
end)

-- ----------------------------------------------------------------------
-- RUNTIME FEATURE CONTROL + TUNING -- server/runtimecontrol.lua PART 1/1B,
-- high command only (CanManageRuntimeControl re-checked there on every one
-- of these six calls; this file adds no authorization of its own). Owner's
-- own words: "Lets high command switch features on and off SERVER-WIDE
-- from the tablet, and tune numbers live." Every response is routed
-- through the SAME TranslateReasonResult already used for theme/cert-tier/
-- shop-location calls above -- server/runtimecontrol.lua's own header
-- states its response shape is the identical `{ ok, reason, ... }` outcome
-- table convention.
--
-- THE ENGINE CONSTRAINT, bridged honestly: server/runtimecontrol.lua's own
-- header classifies every feature into one of five tiers
-- (live/onstart/rawtoplevel/clientonly/protected, plus 'unaudited' for a
-- feature its own FEATURE_TIERS table has never classified) describing
-- whether a toggle takes effect immediately, needs a restart, needs a
-- config.lua edit AND a restart, has no confirmed server-side effect at
-- all, or cannot be toggled through this system at all. THIS FILE forwards
-- `tier` (and, on a rejected set, the tunable's real `min`/`max`) VERBATIM
-- -- but per that file's own "LOCALE KEYS THIS FILE NEEDS: none... never
-- player-facing prose" header note, it never sends a human-readable
-- sentence of its own; html/tablet.js's own runtimeTierLabel()/
-- runtimeTierDescription() are what turn a bare `tier` string into the
-- locale-driven plain-language explanation the operator actually reads --
-- see this file's header NUI CONTRACT note for the full reasoning.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:runtimeListFeatures', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeListFeatures')))
end)

RegisterNUICallback('tablet:runtimeSetFeature', function(data, cb)
    if type(data) ~= 'table' or type(data.name) ~= 'string' or data.name == '' or type(data.value) ~= 'boolean' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeSetFeature', data.name, data.value)))
end)

RegisterNUICallback('tablet:runtimeResetFeature', function(data, cb)
    if type(data) ~= 'table' or type(data.name) ~= 'string' or data.name == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeResetFeature', data.name)))
end)

RegisterNUICallback('tablet:runtimeListTunables', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeListTunables')))
end)

--- `value` is FORWARDED AS-IS, never clamped/rounded here -- see this
--- file's header NUI CONTRACT note: server/runtimecontrol.lua's own
--- SetTunable is the only real, authoritative [min,max]/integer check;
--- this file's own type(data.value) ~= 'number' guard below rejects only
--- something that could not possibly be a valid tunable value at all
--- (missing, a string, NaN would still pass `type(...) == 'number'` in
--- Lua, but the SERVER's own `newValue == newValue` NaN test -- see that
--- file's own SetTunable comment -- is what actually catches that; this
--- file duplicating it would be exactly the "treat client-side validation
--- as authoritative" mistake this task's own brief warns against).
RegisterNUICallback('tablet:runtimeSetTunable', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' or type(data.value) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeSetTunable', data.key, data.value)))
end)

RegisterNUICallback('tablet:runtimeResetTunable', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeResetTunable', data.key)))
end)

-- Lua-INITIATED push, SAME shape/posture as tablet:themeUpdated just below
-- -- see this file's header NUI CONTRACT note on
-- tablet:equipmentShopLocationsUpdated. client/equipmentshop.lua ALSO
-- listens for this exact event independently (to respawn/reposition shop
-- peds) -- AddEventHandler supports any number of handlers per event name,
-- so this is a second, additive listener, not a replacement for that one.
AddEventHandler('qbx_k9unit:client:equipmentShopLocationsUpdated', function(locations)
    SendNUIMessage({ action = 'tablet:equipmentShopLocationsUpdated', data = locations })
end)

-- Lua-INITIATED push, NOT tied to this player's own tablet being open --
-- see this file's header NUI CONTRACT note on tablet:themeUpdated.
-- Registered UNCONDITIONALLY (not only while tabletOpen) so an
-- already-open tablet elsewhere on the server updates live the instant
-- high command saves a change, matching server/runtimecontrol.lua's own
-- "applied for everyone" broadcast intent. No listener/interval is started
-- here that would ever need cleanup on close -- this is a single,
-- session-lifetime AddEventHandler, registered once at file load, exactly
-- like every other AddEventHandler in this file.
AddEventHandler('qbx_k9unit:client:themeUpdated', function(theme)
    SendNUIMessage({ action = 'tablet:themeUpdated', data = theme })
end)

-- ----------------------------------------------------------------------
-- K9 AUDIT TRAIL VIEWER -- server/admin.lua's five tabletAudit* callbacks
-- (Cert/Partner/Search/Xp/Dept), added this pass to close the gap that
-- file's own header names by name: "no NUI callback and no
-- client/tablet.lua change are part of this pass; this is the
-- server-side contract a follow-up tablet screen builds against." This
-- IS that follow-up -- see this file's own header NUI CONTRACT note on
-- these five names for the full AuditResult contract.
--
-- THE TABLET IS A VIEW. IT DECIDES NOTHING -- same rule as every other
-- callback in this file. server/admin.lua's own IsAuthorizedAdmin is the
-- ONLY real gate, re-verified from the CALLER's own live `source` on
-- every single invocation; this file adds no authorization of its own
-- and no second query path.
-- ----------------------------------------------------------------------

--- Shared helper for the five bridges below: an optional numeric `limit`
--- field, dropped to `nil` (never forwarded as anything else) unless it
--- is already a plain Lua number. A trailing `nil` argument is always
--- safe here (indistinguishable, on the receiving Lua function, from the
--- argument simply being omitted -- true whether or not the ox_lib wire
--- transport itself preserves the trailing slot) precisely BECAUSE
--- `limit` is always the LAST positional argument passed to
--- AwaitServerCallback at every one of this section's five call sites --
--- server/admin.lua's own ClampLimit already treats an absent/non-number
--- rawArg identically to this file passing `nil` outright (falls back to
--- its own configured default, then still floor+range-clamps into
--- [1, HARD_MAX_RESULTS]), so this file need not guess a default itself.
--- @param data table
--- @return number? limit
local function OptionalNumericLimit(data)
    return (type(data.limit) == 'number') and data.limit or nil
end

--- 'tablet:auditCert' -- mirrors server/admin.lua's '/k9auditcert'. `rows`
--- shape: one row per k9_certifications grant/revoke event for this
--- citizenid, across every department (job, granted_by, granted_at,
--- revoked_by, revoked_at, active) -- see that file's own
--- QueryCertificationHistory doc comment for the authoritative column
--- list.
RegisterNUICallback('tablet:auditCert', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditCert', data.targetCitizenId, OptionalNumericLimit(data)))
end)

--- 'tablet:auditPartner' -- mirrors '/k9auditpartner'. `rows` shape: this
--- citizenid's full partnership history in EITHER role (id, k9_citizenid,
--- handler_citizenid, established_by, established_at, ended_by, ended_at,
--- active) -- see QueryPartnershipHistory's own doc comment.
RegisterNUICallback('tablet:auditPartner', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditPartner', data.targetCitizenId, OptionalNumericLimit(data)))
end)

--- 'tablet:auditSearch' -- mirrors '/k9auditsearch'. `data.mode` is
--- forwarded VERBATIM, unchecked against server/admin.lua's own
--- VALID_SEARCH_LOG_MODES whitelist here -- that file's own callback
--- already whitelist-checks it before `value` is even inspected and
--- returns 'invalid_args' for anything else, so a second copy of that
--- whitelist here would only be able to drift from the real one, never
--- make it any safer (THE SECURITY RULE). `rows` shape is IDENTICAL
--- across all four modes (searcher_citizenid, searcher_job, target_type,
--- target_plate, target_citizenid, result, total_weight, alert_tier,
--- searched_at, id) -- see QuerySearchLogByOfficer/ByPlate/ByPerson/
--- Recent's own doc comments.
RegisterNUICallback('tablet:auditSearch', function(data, cb)
    if type(data) ~= 'table' or type(data.mode) ~= 'string' or data.mode == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- `value` is sent as an empty string, NEVER Lua `nil`, when absent or
    -- not already a string -- unlike `limit` above, `value` is NOT this
    -- call's last positional argument (`limit` follows it), and an
    -- explicit nil in a NON-TRAILING position risks the wire transport
    -- misaligning every argument after it. An empty string is safe here
    -- regardless: server/admin.lua's own IsValidCitizenId/
    -- NormalizePlateArg both already reject '' as invalid input for
    -- every mode that inspects `value` at all, and 'recent' never reads
    -- it either way.
    local value = (type(data.value) == 'string') and data.value or ''
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditSearch', data.mode, value, OptionalNumericLimit(data)))
end)

--- 'tablet:auditXp' -- mirrors '/k9auditxp'. NO `limit` argument --
--- citizenid is k9_progression's own PRIMARY KEY, so `rows` is always 0
--- or 1 elements ({ xp, updated_at }) regardless of what any caller
--- supplies -- see QueryProgressionSnapshot's own doc comment.
RegisterNUICallback('tablet:auditXp', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditXp', data.targetCitizenId))
end)

--- 'tablet:auditDept' -- mirrors '/k9auditdept'. `departmentKey` is
--- forwarded VERBATIM as the server's own `job` argument -- server-side
--- IsValidDepartment (a `Config.Departments[job] ~= nil` lookup) is the
--- real gate; this file does not hardcode or duplicate the configured
--- department list. `rows` shape: this department's CURRENT active-only
--- certified-handler roster (citizenid, granted_by, granted_at) -- see
--- QueryDepartmentRoster's own doc comment, including why revoked rows
--- are deliberately excluded.
RegisterNUICallback('tablet:auditDept', function(data, cb)
    if type(data) ~= 'table' or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditDept', data.departmentKey, OptionalNumericLimit(data)))
end)

-- ----------------------------------------------------------------------
-- Resource-stop safety net -- see FOCUS/CLOSE DISCIPLINE point 4.
-- ----------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CloseTablet()
end)
