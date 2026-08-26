--[[
    qbx_k9unit/server/exports.lua

    PUBLIC API SURFACE — coder-architect pass, 2026-08-24. See
    DEVELOPER_REFERENCE.md Part B §1 (formerly COMPLEMENTARY_FEATURES.md, merged
    2026-08-25; "Give this resource a real export/event
    API — prerequisite, not optional") for why this file exists: before this
    pass, fxmanifest.lua declared zero exports and README.md said so
    explicitly ("integration by other resources is currently limited to
    reading the metadata.k9certified display flag... these are internal
    contracts, not a stable public API"). Every export below closes that gap
    for READ access. See "NOT IN THIS FILE" near the bottom for what is
    deliberately still missing and why — that section is as load-bearing as
    the exports themselves for anyone reviewing this contract.

    SCOPE BOUNDARY THIS FILE OPERATED UNDER AT THE TIME IT WAS WRITTEN: this
    pass added ONLY this new file (plus its fxmanifest.lua/.luacheckrc
    script-list entries, reported separately to whoever owned those files,
    not edited here) — it did not modify any other existing .lua file in
    this resource at the time. That constraint directly shaped two decisions
    below: the "NO NEW MUTATIONS" stance (still current), and the original
    "EVENT CONTRACT — DOCUMENTED, NOT YET WIRED" section immediately below,
    which is **no longer accurate as a status claim** — see the correction
    at the top of that section before assuming the six events it lists still
    need wiring.

    ======================================================================
    DESIGN PRINCIPLES — read before adding a new export here:
    1. READ-ONLY. Every export below reads existing server-authoritative
       state; none of them grant, revoke, award, or otherwise mutate
       anything. See "NOT IN THIS FILE" for the mutations considered and
       explicitly rejected for v1.
    2. RE-DERIVE, NEVER TRUST. Every export re-derives its answer from the
       same server-authoritative source the internal code already uses
       (the certification cache via HasK9Access, the partnership cache via
       GetActivePartnerCitizenId/IsActivePartnerOf, the XP cache via
       GetXP/GetXPTier). A caller-supplied source/citizenid is only ever
       used as a LOOKUP KEY into that state, never as a claim about the
       result — an export is not a trusted caller, exactly like any other
       network-facing entry point in this resource.
    3. NO RAW INTERNAL TABLES. Every table-returning export copies before
       returning. This is not theoretical: server/progression.lua's own
       doc comment confirms its internal tier resolver "returns the SAME
       table object (by reference) for every xp value that falls in one
       tier's bracket" — that object IS Config.XPTiers[n], shared by every
       citizenid in that bracket. Handing that reference to an external
       resource would let a caller's `tier.speedMultiplier = 999` corrupt
       movement speed for every K9 in that tier, server-wide, for the rest
       of this resource's uptime. Copy first, always — see CopyTier
       below.
    4. THIS FILE WRAPS, IT DOES NOT REIMPLEMENT. Every export below is a
       thin wrapper around an existing resource-global function or a
       direct Config table read — no new business logic, no new SQL.
       Where a genuinely new read (e.g. search-log audit access) would
       require query logic that its owning file doesn't already expose
       globally, it is deliberately NOT added here — see "NOT IN THIS
       FILE". Writing that logic in this file instead of the file that
       owns the table would split ownership of that table across two
       files for no reason beyond this file's own convenience.
    5. FAIL CLOSED, NEVER THROW ACROSS THE RESOURCE BOUNDARY. Every export
       body validates its own argument types and pcall-wraps the call into
       the wrapped function — a bug on this resource's side must never
       propagate an uncaught error into a caller resource's own call
       stack, and a caller passing a malformed argument must never reach
       the wrapped function with it. Bad input returns the same safe
       default this resource already treats as "unknown state" everywhere
       else (false / 0 / nil) — matching server/certifications.lua's own
       "fail closed" convention for an unreadable cert row.

    NOTE ON NAMING: several exports below are given the exact same name as
    the resource-global function they wrap (e.g. `exports('HasK9Access', ...)`
    wraps the global `HasK9Access`), for 1:1 traceability against the
    functions this contract cites. `exports(name, fn)` registers into
    FXServer's per-resource export table, NOT the Lua global namespace — it
    does not shadow, rename, or otherwise touch the actual global `HasK9Access`
    function, so a call to the bare identifier `HasK9Access(...)` inside one
    of this file's export bodies still reaches server/certifications.lua's
    real implementation, not this file's own export of the same name. This
    mirrors an already-established convention in this codebase (client/
    main.lua's `HasK9Access()` and server/certifications.lua's
    `HasK9Access(source)` already share a name across the client/server realm
    split — see .luacheckrc's own comment on that pair).
    ======================================================================

    VERSIONING: GetAPIVersion() is the intended feature-detection entry
    point. This surface starts at 1.0.0. Semver posture: an additive change
    (a new export, a new optional field on an existing return table) bumps
    MINOR; removing/renaming an export or narrowing an existing return shape
    bumps MAJOR and should be treated as a breaking change requiring a
    migration note, not a silent edit. A consumer should call
    GetAPIVersion() once and branch on `.major` rather than assume this
    surface never changes underneath it.

    ======================================================================
    Config.Features GATING — DECISION, PER EXPORT (reasoned explicitly per
    this task's own instruction, not defaulted either way):
    - HasK9Access / IsConfiguredK9Model: NOT gated by any Config.Features
      flag. Neither wrapped function is itself gated by a Phase-numbered
      flag internally — HasK9Access is the core access gate DEVELOPER_REFERENCE.md §4.1
      describes (independent of which specific K9 mechanics are toggled
      on), and IsConfiguredK9Model is roster truth, not a feature. An
      export diverging from its own wrapped function's real behavior would
      be a worse bug than not gating at all.
    - GetActivePartnerCitizenId / IsActivePartnerOf: NOT gated on
      Config.Features.HandlerPartnership. Mirrors the wrapped functions
      exactly — server/partnership.lua's own accessors read the in-memory
      cache unconditionally, with no internal feature check. If that flag
      is later flipped off on a live server, any partnership established
      while it was on remains real, queryable state until torn down some
      other way; gating the EXPORT but not the underlying cache would make
      this file lie about state relative to its own source of truth.
    - GetXP / GetXPTier: NOT gated on Config.Features.XPProgression, for
      the identical reason — server/progression.lua's own doc comment
      states its GetXPTier "does not gate internally, so it stays a plain,
      always-correct cache read regardless of caller," with the gating
      responsibility explicitly pushed to the CALLER. This file is exactly
      that caller, so it inherits that responsibility rather than
      resolving it silently on the operator's behalf. A consumer that
      wants to respect the operator's toggle should pair a GetXP/GetXPTier
      call with IsFeatureEnabled('XPProgression') (below) and decide for
      itself what "disabled" should mean for its own UI.
    - IsFeatureEnabled(featureKey): reads Config.Features directly, so by
      definition always reflects the operator's real, current toggle
      state — this is the one export whose entire purpose IS reading a
      feature flag, so there is nothing else for it to be gated by.
    ======================================================================

    EVENT CONTRACT — WIRED, NOT JUST DOCUMENTED (correction: this section
    originally read "DOCUMENTED, NOT YET WIRED" — that was accurate when
    this file was first written and is stale now; do not re-implement any
    of the wiring described below, it already exists). Verified by direct
    grep of the current tree: server/certifications.lua,
    server/partnership.lua, server/progression.lua, server/search.lua,
    server/sarcalls.lua, and server/integrations.lua each fire their events
    at the exact success points described below, by their exact
    names/payload shapes.

    CORRECTED 2026-08-25 (same pass as the count correction below): this
    paragraph previously said those files "each now call a shared
    `FireOutboundEvent(...)` helper" — that was NOT true when written. It
    was six INDEPENDENT, byte-for-byte identical `local function
    FireOutboundEvent` copies, one per file (and only four of the six
    firing files were even named above; server/sarcalls.lua and
    server/integrations.lua each had their own copy too, undocumented
    here). It is genuinely shared now: all six copies have been extracted
    into ONE resource-global `FireOutboundEvent` in server/events.lua (see
    that file's header for the full extraction writeup) — this correction
    exists so a future reader does not repeat the earlier mistake of
    trusting this claim as already-true before it actually was.

    This file itself still only documents the contract and does not fire
    anything directly (it never did — firing happens at the owning files'
    own success points, which was always the intended design, not a
    placeholder); what changed is that those files' owners have since done
    the wiring this section originally described as still needed.
    DEVELOPER_REFERENCE.md Part B §1's ask (outbound events other resources can
    react to — certification granted/revoked, a partnership formed/broken,
    a contraband search completing, an XP tier crossing) is therefore now
    fully delivered, not merely specified — see the FOURTEEN-event count
    below for the current full list, not the six named in this paragraph's
    original draft.

    CORRECTED 2026-08-25, LATE PASS. The paragraph that stood here said
    "still exactly the six calls... still no seventh", and then the very
    next lines listed a seventh -- a self-contradiction that survived two
    passes precisely because each one re-verified the claim it inherited
    rather than re-deriving the number. It was wrong. The real count today
    is FOURTEEN, measured by grepping every `qbx_k9unit:events:` string
    literal across client/ and server/ and de-duplicating:

      certificationGranted      certificationRenewed
      certificationRevoked      certificationTierChanged
      k9Down                    partnershipEnded
      partnershipEstablished    sarCallCompleted
      sarCallStarted            scentLineupResolved
      searchCompleted           specializationGranted
      specializationRevoked     xpTierReached

    The lesson worth keeping, since this is a PUBLIC contract other
    resources are written against: do not state a count here unless you
    just measured it, and do not re-affirm an inherited one. A stale count
    in a stable-contract header is worse than no count, because a consumer
    trusts it. If you add an event, add its name to the list above in the
    same edit -- the list is the contract; the number is only a summary of
    it.

    Naming: a new `qbx_k9unit:events:<name>` namespace, distinct from the
    existing `qbx_k9unit:server:`/`qbx_k9unit:client:` namespaces (which
    README.md already documents as internal and "may change between
    phases") — `qbx_k9unit:events:*` is the one meant to be a stable
    contract going forward. Every one fires via plain `TriggerEvent`
    (server-local — any other server-side resource can `AddEventHandler`
    on these directly; never `TriggerClientEvent`, these are not for this
    resource's own clients).

    1. 'qbx_k9unit:events:certificationGranted'
       (citizenid: string, jobName: string, grantedByCitizenid: string)
       Fire from: server/certifications.lua's GrantCertification, right
       after the `RefreshCertificationCache(targetCitizenid, jobName)` call
       that follows a successful INSERT (current line ~513) — targetCitizenid/
       jobName/granterCitizenid are already in scope there.

    2. 'qbx_k9unit:events:certificationRevoked'
       (citizenid: string, jobName: string, reason: 'manual'|'manual_offline'|'job_changed')
       Fire from THREE existing success points in server/certifications.lua:
       RevokeCertification (current line ~608-611, right after `affectedRows`
       confirms a real row flipped; reason = 'manual'),
       RevokeCertificationOffline (its equivalent UPDATE success point;
       reason = 'manual_offline'), and the QBCore:Server:OnJobUpdate
       auto-revoke path (reason = 'job_changed'). Same payload shape at all
       three — consider one small shared local helper in that file rather
       than duplicating the TriggerEvent call three times.

    3. 'qbx_k9unit:events:partnershipEstablished'
       (k9Citizenid: string, handlerCitizenid: string)
       Fire from: server/partnership.lua's respondPartnerUp handler,
       alongside the two existing
       `TriggerClientEvent('qbx_k9unit:client:partnershipEstablished', ...)`
       calls (current line ~909-910) — k9Citizenid/officerCitizenid are
       already in scope there.

    4. 'qbx_k9unit:events:partnershipEnded'
       (k9Citizenid: string, handlerCitizenid: string, reason: string)
       Fire from: server/partnership.lua's DoBreakPartnership, right before
       its final `return true` (current line ~956) — row.k9_citizenid/
       row.handler_citizenid/broadcastReason are already in scope there.
       This one function backs both the player-initiated breakPartnership
       event AND ForceBreakPartnershipForCitizenId (the automatic teardown
       on cert revoke), so wiring it here — not at either caller — covers
       both paths in one place.

    5. 'qbx_k9unit:events:searchCompleted'
       (searcherCitizenid: string, searcherJob: string,
        targetType: 'vehicle'|'person', result: 'found'|'clean'|'search_failed',
        totalWeight: number?, alertTier: string?)
       Fire from: server/search.lua's LogSearchAttempt, right after its
       `pcall(MySQL.insert, ...)` call (current line ~433) — every field in
       this payload is already a parameter of that function, and all six
       call sites in that file already funnel through it, so wiring the
       event there (not at each call site) covers all of them at once and
       guarantees the event payload can never drift from what actually
       lands in the `k9_search_log` audit row.
       RECOMMENDED, NOT YET APPLIED (server/integrations.lua's own header,
       2026-08-25 pass): extend this payload with the two target-identity
       fields (`plateOrNil`, `targetCitizenidOrNil`) already in scope at
       this exact call site — an MDT/evidence integration cannot attach a
       `found` result to a real case record without knowing WHAT was
       searched, only who searched it. Additive (MINOR), not applied here
       since server/search.lua's ownership this session belongs to a
       different agent — see server/integrations.lua's header for the full
       writeup.

    6. 'qbx_k9unit:events:xpTierReached'
       (citizenid: string, newTier: table, oldTier: table — both COPIES,
        same shape as this file's own GetXPTier export below, never the
        raw Config.XPTiers reference)
       Fire from: server/progression.lua's AwardXP, at the existing
       `if newTier ~= oldTier then` branch (current line ~300), which
       already detects the exact crossing this event exists to announce —
       right alongside the existing `PushTierSnapshot(targetSrc, newTier)`
       call in that same branch.

    7. 'qbx_k9unit:events:k9Down' (ADDED — DEVELOPER_REFERENCE.md Part A §7, "K9
       down / injured critically" dispatch integration hook)
       (source: number, citizenid: string, jobName: string, coords: vector3,
        health: number)
       Fire from: server/integrations.lua's own self-contained health-poll
       thread (PollK9Health), not from an existing success point in another
       file — see that file's own header for the full design (edge-triggered
       on a configurable Config.K9DownDispatch.healthThreshold, a minimum
       qualifying duration, and a per-source re-fire cooldown, mirroring
       server/wellbeing.lua's own PED_DEAD_HEALTH_THRESHOLD pattern) and for
       why this is a poll rather than a hook inside that file's existing
       TickWellbeing loop (an ownership-boundary decision for this session,
       not a structural preference). The one payload in this whole contract
       that carries a location (`coords`), deliberately: unlike the other
       six events, a dispatch alert's entire purpose is a map pin.

    Every payload above uses ONLY values the owning file already computes
    for its own internal purposes (a DB column just written, an existing
    TriggerClientEvent's own arguments, or — for #7 — a live, server-resolved
    read taken at the moment of firing) — wiring #1 through #6 in was
    arithmetic-free, matching DEVELOPER_REFERENCE.md Part B's own "Effort: small"
    assessment for that item; #7 is genuinely new detection logic, scoped to
    its own file rather than any existing one, per server/integrations.lua's
    own header.
    ======================================================================

    ======================================================================
    SIX-FEATURE COVERAGE AUDIT (2026-08-25 coder-architect pass) — six
    features have landed in this resource since this file was first
    written: Recall (server/recall.lua, client/recall.lua),
    HandlerDownDefense (server/defense.lua, client/defense.lua),
    PropAttachments (server/propattachment.lua, client/propattachment.lua),
    FetchMechanic (server/fetch.lua, client/fetch.lua), ProximityAudioFX
    (client/proximityaudio.lua only — no server-side file exists for it),
    and two more that don't map to a single feature file: partnership
    tenure (server/tenure.lua) and the admin/audit surface
    (server/admin.lua). Each was read in full this pass and evaluated
    against this file's own DESIGN PRINCIPLES above (wrap an EXISTING
    resource-global read accessor, never invent one; never add SQL; never
    weaken the "no new mutations" stance). Result for THIS file
    (server/exports.lua): **zero new exports.** Every one of the six either
    exposes no resource-global function this file could wrap at all, or its
    only resource-global surface is a self-initiated mutation already
    excluded by this file's existing "no new mutations" principle. Decided
    per feature, not defaulted:

    - Recall (server/recall.lua): NOTHING. The file registers exactly one
      RegisterNetEvent and defines no resource-global (non-`local`)
      function of its own — verified by direct read, not grep alone,
      since a false negative here would be the exact "silently stops
      protecting" failure class this file's CopyTier comment warns about
      elsewhere. There is no per-citizenid or per-source cached state this
      file could read (no "is a recall on cooldown" accessor exists, nor
      would one be safe to add: RecallCooldown is `local` to
      server/recall.lua and adding a resource-global reader for it is that
      file's call, not this one's, per DESIGN PRINCIPLE 4). The
      client-initiated action (`RequestRecall()`) is evaluated in
      client/exports.lua instead, where it is also excluded — see that
      file's own reasoning; there is no server-exportable half of Recall
      period.
    - HandlerDownDefense (server/defense.lua): NOTHING. Confirmed by direct
      read: this file exposes NO resource-global function — `LastHostile`,
      `AttackerReportCooldown`, and `DefenseTriggerCooldown` are all
      `local`, and `IsHandlerDown`/`TryNotifyPartnerK9` are both `local`
      too. The only state genuinely worth reading externally (does the
      local K9 currently have a fresh handler-down prompt, and what target
      did the server suggest) is CLIENT-side ephemeral UI state
      (`HasFreshDefensePrompt()`/`GetDefenseSuggestedTargetNetId()`,
      client/defense.lua) — added to client/exports.lua instead, not here.
      Also note for whoever next touches server/defense.lua: its own
      client-facing relay event (`qbx_k9unit:client:handlerDownDefenseTrigger`)
      uses this resource's `qbx_k9unit:client:`/`qbx_k9unit:server:`
      namespace, which README.md documents as internal and subject to
      change — NOT the `qbx_k9unit:events:*` stable-contract namespace
      the EVENT CONTRACT section above documents. A dispatch/MDT-style
      resource wanting to know "a handler just went down and their K9 was
      notified" would be a reasonable FUTURE addition to that stable
      namespace, but adding it means calling `FireOutboundEvent` from
      inside server/defense.lua itself — off limits to this pass (this
      file wraps, it does not add firing points to files it doesn't own).
      Flagged as a genuine gap, not silently dropped.
    - PropAttachments (server/propattachment.lua): NOTHING. That file's own
      header says so explicitly and this pass re-confirmed it by direct
      read: "THIS FILE exposes NO resource-global functions... no other
      file in this resource... needs to call into prop-attachment state
      directly." `PropAttachmentState`/`PendingPropAttachConfirm` are both
      `local`. There is no "is citizenid X currently wearing a prop"
      accessor to wrap because none exists, and adding one would mean
      writing new code inside a file this pass does not own.
    - FetchMechanic (server/fetch.lua): NOTHING on the server side, by the
      identical reasoning — `FetchBalls`/`CarrierIndex`/
      `PendingFetchThrows`/`PendingFetchCarries`/`PendingFetchDrops` are
      all `local`, and every server-side function in that file is `local`
      too (confirmed: zero `function <Name>(` — non-`local` — declarations
      anywhere in server/fetch.lua). The one genuinely useful read this
      feature produces — is the LOCAL K9 currently carrying a fetch ball
      right now — is client-side (`IsFetchCarryEngaged()`,
      client/fetch.lua), added to client/exports.lua instead.
    - ProximityAudioFX (client/proximityaudio.lua): NOTHING, and there is
      no server-side file for this feature to begin with — it is a
      purely client-local cosmetic ambient-audio effect (see that file's
      own header). Not applicable to this file at all.
    - Partnership tenure (server/tenure.lua): NOTHING. That file's own
      header says so explicitly ("THIS FILE owns no resource-global
      (non-`local`) function of its own"), re-confirmed by direct read.
      Beyond that: the tenure VALUE itself is never cached in memory at
      all — `CheckTenureMilestonesForK9` computes it fresh via a
      `TIMESTAMPDIFF(SECOND, established_at, NOW())` SELECT every time it
      is checked (that file's own header, design question 1); the only
      in-memory table this file keeps, `TenureFullyCollected`, is a
      per-row boolean skip-cache with no tenure DURATION in it, and is
      `local` regardless. Exporting a genuine "current tenure for this
      pair" read would require either (a) a brand-new SQL query this file
      would have to own itself (forbidden by DESIGN PRINCIPLE 4 — "no
      unbounded DB work," and a caller-invoked export is exactly the "in a
      loop" case that principle exists to prevent), or (b) adding a new
      resource-global accessor inside server/tenure.lua itself, which is
      not this file's own file to edit this pass. Both routes are closed;
      nothing is exported.
    - Admin/audit surface (server/admin.lua): NOTHING — already covered by
      the existing "k9_search_log READ-BACK" entry in "NOT IN THIS FILE"
      below, re-verified accurate this pass by direct read of
      server/admin.lua: every query function in that file
      (QueryCertificationHistory/QueryPartnershipHistory/
      QuerySearchLogByOfficer/QuerySearchLogByPlate/QuerySearchLogByPerson/
      QuerySearchLogRecent, etc.) is `local`, ACE-gated, and command-driven
      — no resource-global accessor exists to wrap, and building one here
      would mean inventing a new any-caller-resource authorization model
      for tables this file doesn't own, exactly the objection that
      existing entry already raises. No change needed there.

    NET EFFECT ON VERSIONING: because none of the six produced a wrappable
    resource-global on the SERVER side, this file's own API_VERSION stays
    at 1.0.0 — there is nothing additive to bump for. See VERSIONING above
    and client/exports.lua's own header for why that file's version DID
    move — to 1.1.0 in that pass, for two genuinely new reads
    (`IsFetchCarryEngaged`, `HasFreshDefensePrompt` +
    `GetDefenseSuggestedTargetNetId`), and again to 1.2.0 on 2026-08-26 for
    a third, `IsPropAttachmentEngaged`. Do not read a count off this
    paragraph: client/exports.lua's own API_VERSION line is the authority,
    and this cross-reference has already gone stale once by trying to
    restate it. The two files' API_VERSION numbers
    are independent contracts, tracked separately, and are not expected to
    stay numerically identical going forward; see client/exports.lua's own
    corrected VERSIONING note for the full reasoning on why "kept in sync"
    was the wrong framing from the start.
    ======================================================================

    NOT IN THIS FILE — deliberate, with reasons:
    - Any grant/revoke/award/force-detach MUTATION (GrantCertification,
      RevokeCertification*, AwardXP, ForceDetachLeashForSource,
      ForceDetachOfficerLeashForSource, ForceBreakPartnershipForCitizenId,
      RestoreInjury). Every one of these has its own reviewed eligibility/
      proximity/cooldown/notification logic specific to how this resource's
      own client-triggered flow calls it; exporting the mutation directly
      would let an external resource skip all of that context (e.g. an MDT
      plugin "granting" a certification without ever running
      IsEligibleCertifier's checks, or a badly-written integration spamming
      ForceDetachLeashForSource). A bug in someone else's resource would
      become a live bug in this resource's own authorization state. None of
      these are exposed in v1; a genuine cross-resource need for one should
      be reviewed on its own merits, not added by default alongside the
      read-only surface.
    - k9_search_log READ-BACK (audit/dispute-history access) as a PUBLIC
      EXPORT. Still deliberately not added here. No resource-global accessor
      this file could wrap exists — server/search.lua's own LogSearchAttempt
      remains `local`. NOTE, since this section was first written:
      server/admin.lua has since added its own direct, ACE-gated
      `/k9auditsearch` SELECT against this table — so an absolute "nothing
      in this resource ever reads it back" framing is no longer true (this
      file's own text used that framing originally; `sql/install.sql`'s own
      current schema comment was not found to make that same absolute claim
      as of this correction, so check that file directly rather than
      assuming it needs the identical fix). That does not change the
      reasoning for this file: server/admin.lua's read
      is a console/ACE-authorized admin command with its own access-scope
      decision already made for that context, not a general-purpose,
      any-caller-resource export — building the latter would still mean
      inventing new authorization logic for a table this file doesn't own
      (principle 4 above), and would still be a distinct, unreviewed product
      question (should an arbitrary caller resource see every row, only
      their own department's, only one citizenid's?) from the admin
      command's own already-settled ACE model. Recommend, unchanged: a real
      `GetSearchHistoryForCitizenid`/`GetSearchHistoryForPlate`-style
      accessor belongs in server/search.lua itself first (coder-backend),
      exported from here once it exists and its access scope is decided —
      server/admin.lua's existence is useful precedent for that future pass,
      not a substitute for it.
    - RefreshCertificationCache / RefreshPartnershipCache. Both are already
      resource-global functions, but both perform a live, awaited SQL query
      as a side effect of being called, and today are only ever invoked
      from this resource's own reviewed trigger points (job change,
      PlayerLoaded, resource start, an explicit revoke). Exposing either
      would let any external resource trigger an unbounded number of ad hoc
      DB round-trips against this resource's own tables on a schedule this
      resource doesn't control. HasK9Access(source) below already covers
      the overwhelming common real use case (is THIS currently-online
      player allowed to use K9 features right now) without that cost; an
      offline-citizenid certification check has no existing internal
      accessor to wrap, and building a new one here is the same "new logic
      outside its owning file" objection as the search-log case above.
    - ResolveNetworkEntity / ResolveConnectedPlayerFromPed (server/
      entities.lua), NewCooldown / NewNestedCooldown / NewMutex (server/
      cooldowns.lua). Internal plumbing utilities, not domain state — no
      external resource has a legitimate reason to resolve this resource's
      own netId-to-entity mappings, or to construct one of this resource's
      own cooldown objects.
    - A generic "list all K9 citizenids" / "list all active partnerships"
      export. Would require iterating internal `local` caches
      (Certifications in server/certifications.lua, Partnerships in
      server/partnership.lua, K9XP in server/progression.lua) that this
      file genuinely cannot see — true Lua file-local scope, not just a
      convention this file is choosing to respect. The only honest way to
      build one would be a new accessor added inside each owning file,
      which is exactly the "off limits: edit nothing else" boundary this
      pass operates under. Hand off to coder-backend alongside the
      event-wiring work above if a real consumer needs it.
    ======================================================================
]]

--- Copies a Config.XPTiers-shaped entry (xp/label/speedMultiplier/
--- scentRangeMultiplier) into a fresh table. See DESIGN PRINCIPLES item 3 above for
--- exactly why this matters: the wrapped GetXPTier() can return the SAME
--- Config.XPTiers[n] table object for many different citizenids, and this
--- file must never let an external caller obtain a live reference to it.
--- @param tier table
--- @return table copy
local function CopyTier(tier)
    -- WHY THIS RECURSES, given Config.XPTiers is flat today: the whole point
    -- of copying is that GetXPTier() internally returns the SHARED
    -- Config.XPTiers[n] reference, so handing it out raw would let any
    -- consumer mutate movement speed for every K9 in that tier, server-wide
    -- and for the rest of this resource's uptime. A shallow copy closes that
    -- for the current flat shape (xp/label/speedMultiplier/scentRangeMultiplier, all
    -- scalars) -- but it would SILENTLY STOP protecting the moment anyone
    -- adds a nested field, e.g. a per-tier perks list. Nothing would error,
    -- no test would fail, and the hole would just be open again. That
    -- "a control quietly stops working and says nothing" failure mode has
    -- bitten this resource repeatedly, so this recurses instead of relying
    -- on a shape assumption a future editor has no reason to know about.
    local copy = {}
    for key, value in pairs(tier) do
        if type(value) == 'table' then
            copy[key] = CopyTier(value)
        else
            copy[key] = value
        end
    end
    return copy
end

-- Base-tier fallback used whenever the real GetXPTier() global is missing,
-- errors, or is handed a malformed citizenid — Config.XPTiers[1] is this
-- resource's own established "unknown state defaults to least privilege"
-- baseline (see server/progression.lua's ResolveTier doc comment), reused
-- here rather than inventing a second one.
local function BaseTierCopy()
    return CopyTier(Config.XPTiers[1])
end

-- ======================================================================
-- VERSIONING
-- ======================================================================

local API_VERSION = { major = 1, minor = 0, patch = 0, string = '1.0.0' }

--- @return table { major: number, minor: number, patch: number, string: string }
exports('GetAPIVersion', function()
    -- Fresh copy every call, per DESIGN PRINCIPLES item 3 — API_VERSION
    -- above is this file's own internal state, not something a caller
    -- should hold a live reference to.
    return { major = API_VERSION.major, minor = API_VERSION.minor, patch = API_VERSION.patch, string = API_VERSION.string }
end)

-- ======================================================================
-- CERTIFICATION / ACCESS STATE (wraps server/certifications.lua)
-- ======================================================================

--- Server-authoritative: is `source` (a live, currently-connected player)
--- currently allowed to use K9 features? Wraps the real HasK9Access(source)
--- global 1:1 — see this file's header for why this is NOT gated on any
--- Config.Features flag. Only ever resolves a CURRENTLY-CONNECTED player;
--- there is no offline-citizenid variant (see "NOT IN THIS FILE" above).
--- @param source number
--- @return boolean
exports('HasK9Access', function(source)
    if type(source) ~= 'number' then return false end
    if type(HasK9Access) ~= 'function' then return false end -- runtime existence guard, not a load-order assumption (this resource's own convention)

    local ok, result = pcall(HasK9Access, source)
    if not ok then
        print(('[qbx_k9unit] exports:HasK9Access failed for source %s: %s'):format(tostring(source), tostring(result)))
        return false
    end
    return result == true
end)

--- Is `modelHash` (a GetHashKey'd ped model) one of this server's
--- configured K9 models (Config.Peds)? Wraps IsConfiguredK9Model 1:1 — pure
--- roster truth, not gated by any feature flag.
--- @param modelHash number
--- @return boolean
exports('IsConfiguredK9Model', function(modelHash)
    if type(modelHash) ~= 'number' then return false end
    if type(IsConfiguredK9Model) ~= 'function' then return false end

    local ok, result = pcall(IsConfiguredK9Model, modelHash)
    if not ok then return false end
    return result == true
end)

--- Is `jobName` one of this server's configured K9-eligible departments
--- (Config.Departments)? Pure config read, no wrapped function needed.
--- @param jobName string
--- @return boolean
exports('IsK9Department', function(jobName)
    if type(jobName) ~= 'string' then return false end
    return Config.Departments[jobName] ~= nil
end)

-- ======================================================================
-- PARTNERSHIP STATE (wraps server/partnership.lua)
-- ======================================================================

--- Is `citizenid` currently in an active partnership, and if so with whom?
--- Wraps GetActivePartnerCitizenId 1:1 — see this file's header for why
--- this is NOT gated on Config.Features.HandlerPartnership.
--- @param citizenid string
--- @return string? partnerCitizenid — nil if not currently partnered
--- @return boolean? isK9 — true if `citizenid` is the K9-role party; nil if not currently partnered
exports('GetActivePartnerCitizenId', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, nil end
    if type(GetActivePartnerCitizenId) ~= 'function' then return nil, nil end

    local ok, partner, isK9 = pcall(GetActivePartnerCitizenId, citizenid)
    if not ok then return nil, nil end
    return partner, isK9
end)

--- Is `citizenid` currently actively partnered specifically with
--- `allegedPartnerCitizenid`? Wraps IsActivePartnerOf 1:1.
--- @param citizenid string
--- @param allegedPartnerCitizenid string
--- @return boolean
exports('IsActivePartnerOf', function(citizenid, allegedPartnerCitizenid)
    if type(citizenid) ~= 'string' or type(allegedPartnerCitizenid) ~= 'string' then return false end
    if type(IsActivePartnerOf) ~= 'function' then return false end

    local ok, result = pcall(IsActivePartnerOf, citizenid, allegedPartnerCitizenid)
    if not ok then return false end
    return result == true
end)

-- ======================================================================
-- XP / PROGRESSION STATE (wraps server/progression.lua)
-- ======================================================================

--- Raw accumulated XP total for `citizenid` (0 if uncached/unknown/invalid
--- input). Wraps GetXP 1:1 — see this file's header for why this is NOT
--- gated on Config.Features.XPProgression.
--- @param citizenid string
--- @return number
exports('GetXP', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    if type(GetXP) ~= 'function' then return 0 end

    local ok, xp = pcall(GetXP, citizenid)
    if not ok or type(xp) ~= 'number' then return 0 end
    return xp
end)

--- The resolved Config.XPTiers entry for `citizenid`'s current XP total —
--- ALWAYS a fresh copy (see DESIGN PRINCIPLES item 3; CopyTier
--- above), never the shared Config.XPTiers[n] reference the internal
--- GetXPTier() returns. Defaults to a copy of the base tier for an
--- unknown/invalid citizenid or if the wrapped global is unavailable —
--- this resource's own "unknown state defaults to least privilege"
--- convention, so an unresolved lookup can only ever under-report, never
--- over-report, a K9's real tier.
--- @param citizenid string
--- @return table { xp: number, label: string, speedMultiplier: number, scentRangeMultiplier: number }
exports('GetXPTier', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return BaseTierCopy() end
    if type(GetXPTier) ~= 'function' then return BaseTierCopy() end

    local ok, tier = pcall(GetXPTier, citizenid)
    if not ok or type(tier) ~= 'table' then return BaseTierCopy() end
    return CopyTier(tier)
end)

-- ======================================================================
-- FEATURE-FLAG INTROSPECTION
-- ======================================================================

--- Reads Config.Features[featureKey] directly — always reflects the
--- operator's real, current toggle state (see this file's header gating
--- rationale for why every other export above is deliberately NOT gated
--- the same way). Distinguishes "a real feature that is off" (returns
--- false) from "not a recognized feature name" (returns nil) so a caller
--- can feature-detect rather than silently treat a typo'd key as disabled.
--- @param featureKey string — a key in Config.Features, e.g. 'XPProgression'
--- @return boolean? enabled — nil if featureKey is not a recognized Config.Features key
exports('IsFeatureEnabled', function(featureKey)
    if type(featureKey) ~= 'string' then return nil end

    local value = Config.Features[featureKey]
    if value == nil then return nil end
    return value == true
end)
