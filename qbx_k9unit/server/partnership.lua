--[[
    qbx_k9unit/server/partnership.lua

    Phase 3 implementation (coder-backend), PHASE3_SPEC.md §12.0 item 7
    (Revision 5, coder-architect resolution) / §12.3's file-plan entry.
    Owns the "K9 partnership" registry -- a persistent, DB-backed,
    mutually-consented "who is my ongoing handler/K9 partner" relationship,
    independent of momentary leash state (server/main.lua's `LeashPairs`).
    This file is a FOUNDATION ONLY: it establishes/persists/tears down a
    partnership and exposes read accessors for a future consumer, but wires
    NO combat consequence of its own. `BiteAndHold`'s Recall actor and
    `HandlerDownDefense` (the two features PHASE3_SPEC.md §12.0 item 7 names
    as blocked on this file existing) are explicitly OUT OF SCOPE here and
    remain unimplemented -- see "FUTURE CONSUMERS" below for the exact
    accessor functions either should call once built.

    ======================================================================
    WHY OPTION B (THIS FILE), NOT LeashPairs -- one-paragraph restatement,
    full reasoning in PHASE3_SPEC.md §12.0 item 7: `LeashPairs` is
    explicitly ephemeral, session-scoped state for a movement-restriction
    mechanic (server/main.lua's own header: "a live session mechanic, not
    part of the certification/permission system"). `HandlerDownDefense`'s
    own motivating scenario is an off-leash foot chase -- the pair is
    DELIBERATELY unleashed at exactly the moment a defense trigger would
    matter most -- so reusing `LeashPairs` would leave that feature
    non-functional for its own primary use case. This registry exists
    specifically to answer "who is this K9's handler right now" at moments
    `LeashPairs` cannot, including across a resource restart (no leash's own
    game state could ever hint at reconstructing a partnership the way it
    hints at nothing today either -- there is no physical/game state to
    recover a partnership from, hence DB-backed rather than in-memory-only).
    ======================================================================

    SCHEMA-TO-CODE MAPPING (sql/install.sql's `k9_partnerships`, read in
    full, in real column order, before this file was written -- see that
    table's own header comment for the schema rationale from the other
    direction):
      id                         -> never referenced by citizenid-keyed
                                    application code below except as the
                                    row handle passed straight through a
                                    SELECT-then-UPDATE-by-id pair (avoids a
                                    second WHERE-by-citizenid race window
                                    between the two statements).
      k9_citizenid               -> the K9-role party at establishment time
                                    (live model check via IsConfiguredK9Model,
                                    never re-checked after establishment --
                                    see "ROLE IS FROZEN AT ESTABLISHMENT"
                                    below).
      handler_citizenid          -> the officer/handler-role party.
      established_by             -> the INITIATOR's own citizenid (whoever's
                                    client sent requestPartnerUp), resolved
                                    here from `fromServerId`, never the
                                    accepter's -- see respondPartnerUp.
      established_at             -> DB default (CURRENT_TIMESTAMP), never
                                    written by this file directly.
      ended_by                   -> either the ENDING party's own citizenid
                                    (self-initiated breakPartnership, zero
                                    consent) or a `'system:<reason>'`
                                    sentinel (automatic teardown via
                                    ForceBreakPartnershipForCitizenId),
                                    mirroring `k9_certifications.revoked_by`'s
                                    identical convention.
      ended_at                   -> DB write (CURRENT_TIMESTAMP), same shape
                                    as `k9_certifications.revoked_at`.
      active                     -> 1 while live, flipped to 0 on any
                                    teardown path; never deleted, matching
                                    this resource's append-mostly-audit-row
                                    convention.
      active_partner_k9_key /
      active_partner_handler_key -> generated columns, NEVER written by
                                    this file directly (VIRTUAL, DB-derived
                                    from `active`+the two citizenid columns).
                                    Their only role in this file is as the
                                    THING the two UNIQUE KEYs below are
                                    declared on -- this file only ever reads
                                    `active`+`k9_citizenid`/`handler_citizenid`
                                    directly, never these two columns by name.

    ======================================================================
    THE TWO UNIQUE CONSTRAINTS -- WHAT THEY ACTUALLY GUARANTEE, AND WHAT
    THEY DON'T (read before touching the establish flow below):
    `uq_one_active_partnership_per_k9` and `uq_one_active_partnership_per_handler`
    are two INDEPENDENT constraints, one per COLUMN
    (`active_partner_k9_key` / `active_partner_handler_key`), not one
    constraint scoped to "this citizenid, regardless of role." Concretely:
    they guarantee no citizenid can simultaneously be the ACTIVE K9-role
    party of two different rows, and (independently) that no citizenid can
    simultaneously be the ACTIVE handler-role party of two different rows.
    They do NOT, by themselves, guarantee a single citizenid can't hold an
    active row as k9_citizenid in one partnership AND, at the same time, an
    active row as handler_citizenid in a completely different one -- those
    are two different columns, so MySQL's per-column unique-index
    enforcement never sees them as conflicting. This resource's own design
    intent (the flat `Partnerships[citizenid] = { partner, isK9, active }`
    cache shape PHASE3_SPEC.md §12.0 item 7 itself specifies -- ONE entry
    per citizenid, not a list) assumes a citizenid holds AT MOST ONE active
    partnership TOTAL, in either role, at a time -- a real player controls
    one character at a time, and "you have one partner" is the intended
    invariant, not "you have one partner per role you've ever played." The
    DB schema alone does not enforce that broader invariant; this file
    enforces it at the APPLICATION layer instead (the pre-INSERT existence
    checks in respondPartnerUp below, checking BOTH citizenid columns for
    EITHER party before ever inserting), backstopped by
    `PartnershipEstablishMutex` (a single, resource-wide critical-section
    lock around every establish attempt -- see that mutex's own comment)
    rather than by a DB constraint, precisely because no single DB
    constraint can express "these two independent unique columns must also
    be mutually exclusive for the same citizenid value." This is a REAL,
    DISCLOSED residual gap versus a database-level guarantee: a citizenid
    already the k9_citizenid of one PARTNERSHIP could, in a version of this
    file WITHOUT the mutex/pre-check discipline below, race to establish a
    SECOND partnership as handler_citizenid of an unrelated row, since the
    two unique keys would not conflict with each other. `PartnershipEstablishMutex`
    closes this in-process (every establish attempt, for BOTH roles,
    serializes through the same single critical section before any INSERT),
    which is sufficient for this resource (a single FXServer process, no
    horizontal scaling of this resource's own server-side state) -- it is
    not a claim that the DB schema itself would reject this on its own, and
    is flagged here explicitly so a future schema change doesn't
    accidentally rely on a guarantee the two existing UNIQUE KEYs don't
    actually provide.
    ======================================================================

    ROLE IS FROZEN AT ESTABLISHMENT, NEVER RE-DERIVED: unlike leash (which
    re-checks `IsConfiguredK9Model` on every attach attempt, since a leash
    pairing is transient and reformed constantly), a partnership's
    `k9_citizenid`/`handler_citizenid` columns are decided ONCE, at
    establishment time, and never re-validated against the parties' CURRENT
    ped model while the partnership stays active. This is intentional, not
    an oversight: the entire point of this registry (per PHASE3_SPEC.md
    §12.0 item 7's own framing) is to answer "who is my partner"
    independent of momentary state -- re-deriving role from a live model
    check on every read would reintroduce exactly the "goes stale the
    moment either party isn't currently in the expected state" problem this
    registry exists to solve for leash. A citizenid who switches away from
    a K9 model mid-partnership keeps their `k9_citizenid`-role row exactly
    the way a decertified-but-not-yet-revoked handler keeps their
    certification per server/certifications.lua's own documented tradeoff
    (see that file's header) -- this is the same category of accepted
    staleness, not a new one invented here.

    ======================================================================
    FUTURE CONSUMERS (both explicitly OUT OF SCOPE for this file/pass --
    read PHASE3_SPEC.md §12.0 item 7's "Consumers, made concrete" block
    before wiring either):
    - BiteAndHold's Recall actor should call
        IsActivePartnerOf(recallerCitizenid, heldK9Citizenid)
      which returns exactly the boolean expression PHASE3_SPEC.md §12.0
      item 7 specifies (`Partnerships[recallerCitizenid].active and
      Partnerships[recallerCitizenid].partner == heldK9Citizenid`) via a
      safe accessor rather than reaching into `Partnerships` directly --
      that table is `local` to this file, mirroring
      server/certifications.lua's own `Certifications` table (never
      exposed raw; always go through an accessor function).
    - HandlerDownDefense's trigger should call
        GetActivePartnerCitizenId(handlerCitizenid)
      which returns `(partnerCitizenid, isK9)` or `(nil, nil)` if no active
      partnership exists for that citizenid -- a silent no-op per
      PHASE3_SPEC.md §12.0 item 7's own "never partnered, or partnership
      broken: silent no-op" framing. The caller is still responsible for
      separately checking the resolved K9 citizenid is CURRENTLY ONLINE
      (e.g. via exports.qbx_core:GetPlayerByCitizenId) before notifying --
      this file only answers "who," never "are they online right now."
    ======================================================================

    EVENT/CALLBACK CONTRACT:

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:requestPartnerUp' (targetServerId: number)
      Mirrors server/main.lua's requestLeashAttach exactly, including its
      single-slot-per-target pending-request discipline (see
      PendingPartnershipRequests below) -- initiator asks; does NOT
      establish anything by itself, only relays a consent prompt.
    - 'qbx_k9unit:server:respondPartnerUp' (fromServerId: number, accepted: boolean)
      Mirrors respondLeashAttach's exact verified-match + TTL re-check
      discipline. On acceptance, RE-VALIDATES eligibility (TOCTOU, same as
      leash) and then runs the DB establish flow under
      PartnershipEstablishMutex.
    - 'qbx_k9unit:server:breakPartnership' ()
      Either party, at any time, ZERO consent needed -- mirrors leash's
      detachLeash exactly (PHASE3_SPEC.md §12.0 item 7 point 3's own "no
      unbounded trap" restatement, now applied to a persistent relationship
      rather than only a transient one).

    Client events (server->client), registered by client/partnership.lua:
    - 'qbx_k9unit:client:partnerUpRequest' (fromServerId: number)
      Shown to the target as an accept/decline prompt, mirroring
      leashAttachRequest.
    - 'qbx_k9unit:client:partnershipEstablished' (partnerServerId: number, isK9: boolean)
      Sent individually to BOTH parties once accepted, each with their OWN
      role flag -- mirrors leashAttached's exact per-party-role-flag shape.
    - 'qbx_k9unit:client:partnershipEnded' (reason: string)
      Sent to whichever of the two parties are CURRENTLY ONLINE (unlike
      leash's leashDetached, which can assume both are online since a
      leash pairing cannot exist with either party disconnected -- a
      partnership very much can; see "OFFLINE-CAPABLE BY DESIGN" below).

    Resource-global (no `local`) functions exposed for OTHER files:
    - RefreshPartnershipCache(citizenid: string) -> partnerCitizenid: string?, isK9: boolean?
      Modeled on server/certifications.lua's RefreshCertificationCache --
      SAME pcall/fail-closed discipline, for the SAME reason: this function
      is called from this file's own onResourceStart backfill loop (see
      below), and an unguarded read there would abort that loop for every
      player after the first one processed, exactly the bug class
      RefreshCertificationCache was hardened against this session. Exposed
      globally (not `local`) for the same "documented reuse hook" reason
      IsConfiguredK9Model was -- no other file calls this today, but a
      future admin command forcing a resync for one citizenid without a
      full resource restart is a plausible, cheap reuse.
    - GetActivePartnerCitizenId(citizenid: string) -> partnerCitizenid: string?, isK9: boolean?
    - IsActivePartnerOf(citizenid: string, allegedPartnerCitizenid: string) -> boolean
      Both read-only accessors over the `local` `Partnerships` cache -- see
      "FUTURE CONSUMERS" above.
    - ForceBreakPartnershipForCitizenId(citizenid: string, reason: string) -> boolean
      Citizenid-keyed (NOT source-keyed, unlike server/main.lua's
      ForceDetachLeashForSource) -- see "OFFLINE-CAPABLE BY DESIGN" below
      for why this is a required divergence, not a style choice. Called
      from server/certifications.lua alongside every existing
      ForceDetachLeashForSource/ForceDetachOfficerLeashForSource call site
      (K9-role cert revocation, either party's department change) --
      PHASE3_SPEC.md §12.0 item 7 point 3's exact instruction: "the exact
      call-site list that file already maintains for leash, extended with
      one more line per site rather than a new independent mechanism."
      Returns `false` (no-op, not an error) if `citizenid` has no active
      partnership to end.

    ======================================================================
    OFFLINE-CAPABLE BY DESIGN -- the one place this file's shape MUST
    diverge from leash's, not just could: `ForceDetachLeashForSource`
    (server/main.lua) is source-keyed and is a genuine no-op for an
    offline citizenid, because `LeashPairs` is in-memory/ephemeral and an
    offline citizenid cannot have an active pairing in it by construction
    (server/certifications.lua's own `ForceDetachLeashIfOnline` wrapper
    exists specifically to make this no-op explicit at the call site). A
    K9 partnership is the OPPOSITE by design intent -- DB-backed
    specifically so it survives a disconnect (PHASE3_SPEC.md §12.0 item 7
    point 2: "session-spanning, plausibly shift-spanning"). This means
    `RevokeCertificationOffline` (server/certifications.lua) revoking a
    GENUINELY OFFLINE K9-role citizenid's certification must still be able
    to tear down a real, currently-active, persisted partnership row for
    them -- an online-only teardown function would silently leave that
    partnership standing indefinitely for an offline K9 revoked while
    off-shift, exactly the gap this registry was built to not have.
    `ForceBreakPartnershipForCitizenId` is therefore citizenid-keyed and
    works identically online or offline (it operates on the DB row
    directly; `TellCitizenIdPartnershipEnded` below is the only piece that
    cares whether either party happens to be connected right now, and it
    only affects whether a live client gets notified, never whether the
    DB teardown itself succeeds).

    Symmetric consequence, also intentional: THIS FILE's own `playerDropped`
    handler does NOT tear down a partnership on disconnect (unlike
    server/main.lua's `LeashPairs` cleanup, which unconditionally ends a
    leash pairing on either side disconnecting, since a disconnected party
    cannot remain leashed to anything meaningful). Only the disconnecting
    citizenid's in-memory CACHE entry is dropped -- mirroring
    server/certifications.lua's own unbounded-growth fix for `Certifications`
    (harmless, cheaply rebuilt from a fresh DB query on that citizenid's
    next PlayerLoaded) -- the underlying persisted partnership, and the
    still-online partner's own view of it, are left completely untouched.
    See that handler's own comment below for the full writeup.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `IsConfiguredK9Model(modelHash)` and
      `HasK9Access(source)`, both resource-global functions exposed by
      server/certifications.lua -- do not re-implement either check here
      (mirrors server/main.lua's own leash-eligibility reuse of both).
    - THIS FILE calls `NewCooldown`/`NewMutex`, resource-global constructors
      exposed by server/cooldowns.lua, at THIS file's own file-load time --
      per that file's own header, THIS FILE must load after
      server/cooldowns.lua in fxmanifest.lua's server_scripts (confirmed
      there).
    - server/certifications.lua calls `ForceBreakPartnershipForCitizenId`
      from three places (RevokeCertification's online branch,
      RevokeCertificationOffline, and the QBCore:Server:OnJobUpdate
      handler's TWO branches -- department-loss and cert-revoke-due-to-
      job-change) -- each guarded by a `type(...) == 'function'` runtime
      existence check per this resource's established "runtime existence
      guard, not a load-order assumption" convention (see fxmanifest.lua's
      own comment on server/medkit.lua's RestoreInjury reuse for the same
      precedent), since THIS FILE is loaded AFTER server/certifications.lua
      in fxmanifest.lua (see that file's own header for why: this file
      also needs `IsConfiguredK9Model`/`HasK9Access` at RUNTIME, inside the
      eligibility check below, which certifications.lua already guarantees
      exist unconditionally without its own guard -- the two files'
      dependencies on each other are both real, but only one direction
      needs a guard, since only one direction is a call made from a file
      loaded BEFORE its callee).
    - client/partnership.lua is the ONLY client file that should register
      handlers for the three partnership client events above, or trigger
      the three partnership server events above -- same "keep the full
      subsystem confined to one client/one server file" discipline
      server/main.lua's own header establishes for leash.
]]

-- Partnerships[citizenid] = { partner = partnerCitizenid, isK9 = boolean,
-- active = true } -- ONE entry per citizenid, per PHASE3_SPEC.md §12.0 item
-- 7's own cache shape (see the "THE TWO UNIQUE CONSTRAINTS" header section
-- above for the gap between this single-entry assumption and what the DB
-- schema alone actually enforces). `local`, exactly like
-- server/certifications.lua's `Certifications` -- nothing outside this file
-- should read it directly; always go through RefreshPartnershipCache /
-- GetActivePartnerCitizenId / IsActivePartnerOf below. Populated ONLY by
-- RefreshPartnershipCache (a fresh DB read each time), never hand-written
-- elsewhere in this file, so there is exactly one place cache entries are
-- ever constructed -- avoids the cache and the DB ever drifting out of sync
-- from two independent write paths.
local Partnerships = {}

-- Ephemeral pending partner-up requests: PendingPartnershipRequests[targetSrc]
-- = { from = initiatorSrc, expiresAt = <GetGameTimer() timestamp> }. Exact
-- same shape, TTL, and single-slot-per-target discipline as
-- server/main.lua's `PendingLeashRequests` -- including that file's own
-- fix for the request-clobbering bug (a second incoming request for a
-- target with a live, unexpired pending entry is REJECTED outright, not
-- silently overwritten with no notice to the superseded initiator, and not
-- resolved by notifying a third party). See requestPartnerUp below for
-- where that rejection happens, mirroring requestLeashAttach's own comment
-- almost verbatim. Local: nothing outside this file needs it.
local PendingPartnershipRequests = {}

--- Single, resource-wide critical-section lock around every "establish a
--- partnership" attempt, from the moment eligibility is re-validated
--- (TOCTOU-safe) through the INSERT completing. See "THE TWO UNIQUE
--- CONSTRAINTS" in this file's header for exactly what race this closes
--- that the two DB-level UNIQUE KEYs alone cannot (a citizenid racing to
--- become the K9-role party of one partnership AND the handler-role party
--- of a different one at the same instant, which hits two INDEPENDENT
--- unique columns and so would not conflict at the DB level).
---
--- DELIBERATELY A SINGLE GLOBAL KEY, NOT PER-CITIZENID: a per-citizenid
--- locking scheme would need a fixed acquisition ORDER across both
--- citizenids in a pair to avoid a classic two-lock deadlock (initiator A
--- accepting B's request while, in the same instant, some other pairing
--- acquires B-then-A) -- solvable, but real added complexity for an action
--- that is: (a) gated by mutual consent + a TTL'd single-slot pending
--- request + a per-source rate limit already, making genuine contention
--- vanishingly rare in practice, and (b) cheap to just ask the loser to
--- retry (their PendingPartnershipRequests entry is already consumed by
--- the time this mutex is even reached -- see respondPartnerUp -- so a
--- rejected acquisition here simply means "send a fresh request," not any
--- loss of a real in-flight guarantee). A single global lock is the
--- simplest correct answer for an action this infrequent; per-citizenid
--- lock ordering would be solving a contention problem that does not
--- exist here.
---
--- The establish flow below (respondPartnerUp) wraps its ENTIRE critical
--- section in `pcall` and unconditionally releases this mutex in a
--- `finally`-equivalent (Release called right after the pcall returns,
--- before branching on its result) specifically so a thrown DB error can
--- never leave this global lock permanently held -- an unreleased global
--- mutex would be a self-inflicted, resource-wide denial of the ENTIRE
--- partnership-establish feature until the next resource restart, which
--- would be a strictly worse failure mode than the rare race it exists to
--- prevent.
local PartnershipEstablishMutex = NewMutex()
local PARTNERSHIP_ESTABLISH_MUTEX_KEY = 'establish'

-- Mirrors server/main.lua's LeashRequestCooldown exactly -- same
-- UI-harassment-vector rationale (an eligible nearby party spamming
-- accept/decline prompts at a target with no rate limit), same
-- NewCooldown()-backed, per-INITIATOR-source keying, same
-- :RegisterPlayerDropped() cleanup.
local PartnerRequestCooldown = NewCooldown(Config.Partnership.RequestCooldownMs)
PartnerRequestCooldown.RegisterPlayerDropped()

--- Sends an ox_lib notification to a specific player. Duplicated here
--- rather than shared across files -- same tiny, generic UI-plumbing
--- helper this resource already duplicates in both server/main.lua and
--- server/certifications.lua (see either file's own identical comment on
--- this exact function) for the same reason: it is not
--- certification/permission logic that must stay a single source of
--- truth.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    TriggerClientEvent('ox_lib:notify', target, {
        title = 'K9 Unit',
        description = description,
        type = notifyType or 'inform',
    })
end

--- Sends the `partnershipEnded` client event to `citizenid` ONLY if they
--- currently resolve to a connected server id -- silent no-op otherwise
--- (an offline party has no client to tell, and will see the correct,
--- already-updated state the next time RefreshPartnershipCache runs for
--- them at their own next PlayerLoaded). Mirrors
--- server/certifications.lua's `ForceDetachLeashIfOnline`'s own
--- online-resolution pattern, applied here to a notification instead of a
--- state mutation (the mutation -- the DB UPDATE -- already happened
--- unconditionally by the time this is called; this only decides whether
--- there's a live client worth telling about it).
--- @param citizenid string
--- @param reason string
local function TellCitizenIdPartnershipEnded(citizenid, reason)
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local src = player and player.PlayerData and player.PlayerData.source
    if not src then return end
    TriggerClientEvent('qbx_k9unit:client:partnershipEnded', src, reason)
end

--- Re-queries the active-partnership row for `citizenid` (in EITHER role)
--- and updates the in-memory cache. Exposed globally (no `local`) -- see
--- this file's header for the full pcall/fail-closed rationale, mirroring
--- server/certifications.lua's `RefreshCertificationCache` for the exact
--- same reason (this file's own onResourceStart backfill loop below calls
--- this once per already-connected player; an unguarded error on the
--- first iteration would otherwise abort the whole loop for every
--- subsequent player, per this resource's own confirmed and fixed
--- regression on the certification side of the same pattern).
--- @param citizenid string
--- @return string? partnerCitizenid -- nil if no active partnership
--- @return boolean? isK9 -- true if `citizenid` is the K9-role party; nil if no active partnership
function RefreshPartnershipCache(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, nil end

    local queryOk, rowOrErr = pcall(
        MySQL.single.await,
        'SELECT k9_citizenid, handler_citizenid FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
        { citizenid, citizenid }
    )

    if not queryOk then
        print(('[qbx_k9unit] RefreshPartnershipCache query failed for %s: %s'):format(citizenid, tostring(rowOrErr)))
        -- FAIL CLOSED: an unreadable partnership row must never be treated
        -- as an active partnership -- same discipline as
        -- RefreshCertificationCache, for the same disclosed reason (see
        -- that function's own doc comment in server/certifications.lua).
        Partnerships[citizenid] = nil
        return nil, nil
    end

    if not rowOrErr then
        Partnerships[citizenid] = nil
        return nil, nil
    end

    local isK9 = rowOrErr.k9_citizenid == citizenid
    local partner = isK9 and rowOrErr.handler_citizenid or rowOrErr.k9_citizenid
    Partnerships[citizenid] = { partner = partner, isK9 = isK9, active = true }
    return partner, isK9
end

--- Read-only accessor over the `local` `Partnerships` cache -- see
--- "FUTURE CONSUMERS" in this file's header for the intended caller
--- (HandlerDownDefense's trigger, not yet implemented).
--- @param citizenid string
--- @return string? partnerCitizenid
--- @return boolean? isK9
function GetActivePartnerCitizenId(citizenid)
    local cached = Partnerships[citizenid]
    if not cached or not cached.active then return nil, nil end
    return cached.partner, cached.isK9
end

--- Read-only accessor over the `local` `Partnerships` cache, expressing
--- exactly the boolean check PHASE3_SPEC.md §12.0 item 7 specifies for
--- BiteAndHold's Recall actor -- see "FUTURE CONSUMERS" in this file's
--- header for the intended caller (not yet implemented).
--- @param citizenid string
--- @param allegedPartnerCitizenid string
--- @return boolean
function IsActivePartnerOf(citizenid, allegedPartnerCitizenid)
    local cached = Partnerships[citizenid]
    return cached ~= nil and cached.active == true and cached.partner == allegedPartnerCitizenid
end

--- @param citizenid string
--- @return boolean
local function IsAlreadyPartnered(citizenid)
    local cached = Partnerships[citizenid]
    return cached ~= nil and cached.active == true
end

--- Returns true if `err` (the value pcall caught around the establishing
--- INSERT) represents a MySQL/MariaDB duplicate-key error (1062) on either
--- of this table's two UNIQUE KEYs. Duplicated from
--- server/certifications.lua's `IsDuplicateKeyError` rather than shared --
--- same tiny, self-contained, no-shared-state helper, same reasoning as
--- this file's own duplicated `NotifyPlayer` above. See that function's own
--- doc comment for why every shape checked here (table with
--- .errno/.code/.message/.sqlMessage, or a plain string) is checked rather
--- than assuming one specific oxmysql error shape.
--- @param err any
--- @return boolean
local function IsDuplicateKeyError(err)
    if type(err) == 'table' then
        if err.errno == 1062 or err.code == 1062 then return true end
        local message = err.message or err.sqlMessage
        if type(message) == 'string' and (message:find('1062', 1, true) or message:find('ER_DUP_ENTRY', 1, true)) then
            return true
        end
    elseif type(err) == 'string' then
        if err:find('1062', 1, true) or err:find('ER_DUP_ENTRY', 1, true) or err:find('Duplicate entry', 1, true) then
            return true
        end
    end
    return false
end

--- Human-readable rejection messages for CheckPartnershipEligibility's
--- `reason` return value. Mirrors server/main.lua's LEASH_REJECT_MESSAGES
--- shape exactly.
local PARTNERSHIP_REJECT_MESSAGES = {
    feature_disabled          = 'Handler partnership is disabled on this server.',
    invalid_target            = 'Invalid partner target.',
    already_partnered         = 'One of you is already partnered with someone else.',
    offline                   = 'That player is no longer online.',
    too_far                   = 'You are too far apart to partner up.',
    no_k9_party               = 'Neither party is playing a recognized K9 model.',
    not_certified             = 'The K9 is not certified for K9 duty.',
    officer_not_in_department = 'The handler must be employed by an eligible department.',
}

--- @param reason string?
--- @return string
local function PartnershipRejectReasonMessage(reason)
    return PARTNERSHIP_REJECT_MESSAGES[reason] or 'Unable to set up partnership.'
end

--- Shared eligibility/proximity checks for establishing a partnership, run
--- at BOTH request time and accept time (mirrors server/main.lua's
--- CheckLeashEligibility exact TOCTOU discipline -- re-run at accept time
--- so nothing that changed in between slips through).
---
--- AUTHORIZATION MODEL (PHASE3_SPEC.md §12.0 item 7 point 4 -- "mutual
--- consent only, no certifier-grade hierarchy"): deliberately reuses
--- LEASH's own asymmetric eligibility shape, not a stricter
--- both-need-HasK9Access reading of that item's own point 1 prose ("both
--- parties currently pass HasK9Access-equivalent checks for the same
--- department"). CONFIDENCE NOTE, disclosed rather than silently resolved:
--- that phrase is genuinely ambiguous between (a) "both parties go through
--- an eligibility check styled after HasK9Access" (satisfied by the
--- leash-mirroring shape below) and (b) "the handler must ALSO hold an
--- active HasK9Access-passing certification, in the SAME department as the
--- K9." Reading (b) literally would mean a handler who has never
--- personally certified (the overwhelmingly common real case for an
--- officer who only ever anchors/partners, never plays the K9 role
--- themselves) could never be anyone's partner at all, which contradicts
--- point 4's own "peer relationship between two parties who are each
--- already independently eligible (department membership / K9 model)" --
--- that later, more precisely-scoped sentence matches leash's actual
--- shipped, reviewed model exactly (K9-role needs HasK9Access, officer-role
--- needs mere department membership, no same-department cross-check).
--- This function follows point 4's precise wording and
--- CheckLeashEligibility's shipped precedent over point 1's looser prose,
--- since PHASE3_SPEC.md §12.0 item 7 point 1 itself says this design
--- "reuses `CheckLeashEligibility`" as its own stated model. Flagged
--- honestly as a judgment call on an ambiguous spec phrase, not asserted
--- as the only possible reading.
--- @param initiatorSrc number
--- @param targetSrc number
--- @return boolean ok
--- @return number? k9Src
--- @return number? officerSrc
--- @return string? reason -- present when ok == false
--- @return string? k9Citizenid -- present when ok == true
--- @return string? officerCitizenid -- present when ok == true
local function CheckPartnershipEligibility(initiatorSrc, targetSrc)
    if not Config.Features.HandlerPartnership then
        return false, nil, nil, 'feature_disabled'
    end

    if type(initiatorSrc) ~= 'number' or type(targetSrc) ~= 'number' or initiatorSrc == targetSrc then
        return false, nil, nil, 'invalid_target'
    end

    local initiatorPed = GetPlayerPed(initiatorSrc)
    local targetPed = GetPlayerPed(targetSrc)
    if initiatorPed == 0 or targetPed == 0 then
        return false, nil, nil, 'offline'
    end

    local initiatorPlayer = exports.qbx_core:GetPlayer(initiatorSrc)
    local targetPlayer = exports.qbx_core:GetPlayer(targetSrc)
    local initiatorCitizenid = initiatorPlayer and initiatorPlayer.PlayerData and initiatorPlayer.PlayerData.citizenid
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not initiatorCitizenid or not targetCitizenid then
        return false, nil, nil, 'offline'
    end

    -- Cache-based pre-check only -- a fast, early, honest rejection before
    -- either party goes through a consent prompt for a request that could
    -- never complete. NOT the final authority: the establish flow itself
    -- (respondPartnerUp) re-checks this against the DB directly, under
    -- PartnershipEstablishMutex, immediately before the INSERT -- see this
    -- file's "THE TWO UNIQUE CONSTRAINTS" header section for exactly why a
    -- cache-only check here would not be sufficient on its own.
    if IsAlreadyPartnered(initiatorCitizenid) or IsAlreadyPartnered(targetCitizenid) then
        return false, nil, nil, 'already_partnered'
    end

    local dist = #(GetEntityCoords(initiatorPed) - GetEntityCoords(targetPed))
    if dist > Config.Partnership.ProximityMeters then
        return false, nil, nil, 'too_far'
    end

    -- Roles via live model check (never client-claimed) -- see this file's
    -- header "ROLE IS FROZEN AT ESTABLISHMENT" note for why this is the
    -- ONLY point in this partnership's lifetime role is derived this way.
    local initiatorIsK9 = IsConfiguredK9Model(GetEntityModel(initiatorPed))
    local targetIsK9 = IsConfiguredK9Model(GetEntityModel(targetPed))

    if not initiatorIsK9 and not targetIsK9 then
        return false, nil, nil, 'no_k9_party'
    end

    -- Same tie-break as server/main.lua's CheckLeashEligibility when BOTH
    -- are K9-modeled: the REQUEST TARGET defaults to the K9 role.
    local k9Src, officerSrc, k9Citizenid, officerCitizenid
    if targetIsK9 then
        k9Src, officerSrc = targetSrc, initiatorSrc
        k9Citizenid, officerCitizenid = targetCitizenid, initiatorCitizenid
    else
        k9Src, officerSrc = initiatorSrc, targetSrc
        k9Citizenid, officerCitizenid = initiatorCitizenid, targetCitizenid
    end

    if not HasK9Access(k9Src) then
        return false, nil, nil, 'not_certified'
    end

    -- Officer/handler-role party: mere department membership, no
    -- certification of their own required -- see this function's own
    -- AUTHORIZATION MODEL doc comment above.
    local officerPlayer = (officerSrc == initiatorSrc) and initiatorPlayer or targetPlayer
    local officerJob = officerPlayer and officerPlayer.PlayerData and officerPlayer.PlayerData.job
    if not officerJob or not Config.Departments[officerJob.name] then
        return false, nil, nil, 'officer_not_in_department'
    end

    return true, k9Src, officerSrc, nil, k9Citizenid, officerCitizenid
end

--- Step 1 of the consent handshake: initiator asks to partner with target.
--- Does NOT establish anything -- only relays a prompt if the request
--- itself is currently valid. Mirrors server/main.lua's requestLeashAttach
--- almost line-for-line, including its exact fix for the request-
--- clobbering bug (see that handler's own comment for the full writeup;
--- restated briefly here since this is a near-verbatim mirror, not a
--- reference to it).
--- @param targetServerId number
RegisterNetEvent('qbx_k9unit:server:requestPartnerUp', function(targetServerId)
    local src = source

    if type(targetServerId) ~= 'number' then
        NotifyPlayer(src, 'Invalid partner target.', 'error')
        return
    end

    local ok, _, _, reason = CheckPartnershipEligibility(src, targetServerId)
    if not ok then
        NotifyPlayer(src, PartnershipRejectReasonMessage(reason), 'error')
        return
    end

    -- SECURITY FIX PRECEDENT APPLIED HERE (mirrors server/main.lua's
    -- requestLeashAttach, coder-security, exploit-tester + qa-tester
    -- finding, 2026-08-23): reject a SECOND request outright while a live,
    -- unexpired one is already pending for this target, rather than
    -- silently overwriting it -- that shape previously let a second
    -- initiator silently clobber a first initiator's pending request with
    -- no notice to the superseded party (a denial-of-service/UX-integrity
    -- gap, not a consent-guarantee weakening, since respondPartnerUp's own
    -- match+TTL check below still requires the correct initiator either
    -- way). Reject the SECOND caller with a notice to THEMSELVES (the same
    -- "notify the caller of their own rejected action" convention
    -- CheckPartnershipEligibility's rejection path above already uses)
    -- rather than trying to notify a THIRD party (the first initiator)
    -- about an action they themselves didn't take. Checked BEFORE consuming
    -- the rate limit below so a legitimately-rejected duplicate doesn't
    -- burn the caller's own cooldown allowance.
    local existingPending = PendingPartnershipRequests[targetServerId]
    if existingPending and GetGameTimer() <= existingPending.expiresAt then
        NotifyPlayer(src, 'That player already has a pending partner request.', 'error')
        return
    end

    if not PartnerRequestCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches this resource's bark/leash-request/certify-action convention)
    end

    PendingPartnershipRequests[targetServerId] = { from = src, expiresAt = GetGameTimer() + Config.Partnership.RequestTTLMs }

    TriggerClientEvent('qbx_k9unit:client:partnerUpRequest', targetServerId, src)
    NotifyPlayer(src, 'Partner request sent.', 'inform')
end)

--- Step 2 of the consent handshake: target's response. Mirrors
--- server/main.lua's respondLeashAttach's exact validate-before-notify
--- discipline (coder-security, final pass, 2026-08-23 finding on that
--- handler -- restated briefly here since this is a near-verbatim mirror):
--- the pending request is verified genuine (matching initiator + unexpired)
--- BEFORE any TriggerClientEvent/NotifyPlayer referencing the
--- client-supplied `fromServerId` fires, so a spoofed/expired/mismatched
--- claim only ever results in an error notice to the CALLER themselves,
--- never an arbitrary-target notification.
--- @param fromServerId number
--- @param accepted boolean
RegisterNetEvent('qbx_k9unit:server:respondPartnerUp', function(fromServerId, accepted)
    local src = source -- the target, responding

    if type(fromServerId) ~= 'number' then return end

    local pending = PendingPartnershipRequests[src]
    local verifiedMatch = pending ~= nil and pending.from == fromServerId

    if not verifiedMatch or GetGameTimer() > pending.expiresAt then
        PendingPartnershipRequests[src] = nil -- drop a stale/expired entry, if any
        NotifyPlayer(src, 'That partner request is no longer valid.', 'error')
        if verifiedMatch then
            NotifyPlayer(fromServerId, 'Your partner request is no longer valid.', 'error')
        end
        return
    end

    PendingPartnershipRequests[src] = nil -- consumed either way, accept or decline, now that it's confirmed genuine

    if not accepted then
        NotifyPlayer(fromServerId, 'Your partner request was declined.', 'inform')
        return
    end

    -- RE-VALIDATE -- do not trust that nothing changed since the request
    -- was sent (classic TOCTOU: either party could have disconnected,
    -- moved out of range, gotten partnered with someone else, or lost
    -- eligibility in the meantime).
    local ok, k9Src, officerSrc, reason, k9Citizenid, officerCitizenid = CheckPartnershipEligibility(fromServerId, src)
    if not ok then
        NotifyPlayer(fromServerId, PartnershipRejectReasonMessage(reason), 'error')
        NotifyPlayer(src, PartnershipRejectReasonMessage(reason), 'error')
        return
    end

    if not PartnershipEstablishMutex.TryAcquire(PARTNERSHIP_ESTABLISH_MUTEX_KEY) then
        -- Genuinely rare in practice (see PartnershipEstablishMutex's own
        -- doc comment) -- both PendingPartnershipRequests entries for this
        -- pair are already consumed at this point either way, so the only
        -- recovery is a fresh request; tell both parties plainly rather
        -- than silently dropping the accept.
        NotifyPlayer(fromServerId, 'Partner setup is busy, please try again in a moment.', 'error')
        NotifyPlayer(src, 'Partner setup is busy, please try again in a moment.', 'error')
        return
    end

    -- Everything from here through Release() below is the critical
    -- section PartnershipEstablishMutex protects -- wrapped in pcall so a
    -- thrown DB error can never leave the mutex permanently held (see that
    -- mutex's own doc comment for why this matters more here than an
    -- ordinary single-request failure would).
    local ranOk, outcomeOrErr = pcall(function()
        -- Fresh, AUTHORITATIVE re-check immediately before the INSERT --
        -- the cache-based check inside CheckPartnershipEligibility above is
        -- a fast early-reject only, not the final word (see this file's
        -- header "THE TWO UNIQUE CONSTRAINTS" section for exactly which
        -- race this closes that the DB's own two independent UNIQUE KEYs
        -- cannot). Checks EACH citizenid against BOTH DB columns, not just
        -- their own expected role's column, since the whole point of this
        -- check is catching a citizenid who raced into the OTHER role
        -- somewhere else.
        local k9AlreadyPartnered = MySQL.scalar.await(
            'SELECT id FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
            { k9Citizenid, k9Citizenid }
        )
        if k9AlreadyPartnered then return 'already_partnered' end

        local officerAlreadyPartnered = MySQL.scalar.await(
            'SELECT id FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
            { officerCitizenid, officerCitizenid }
        )
        if officerAlreadyPartnered then return 'already_partnered' end

        -- established_by = the INITIATOR's own citizenid (whoever's client
        -- sent requestPartnerUp), never the accepter's -- see this file's
        -- header "SCHEMA-TO-CODE MAPPING" for why.
        local initiatorCitizenid = (fromServerId == k9Src) and k9Citizenid or officerCitizenid

        local insertOk, insertResultOrErr = pcall(
            MySQL.insert.await,
            'INSERT INTO k9_partnerships (k9_citizenid, handler_citizenid, established_by) VALUES (?, ?, ?)',
            { k9Citizenid, officerCitizenid, initiatorCitizenid }
        )

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                -- Another request won a check-then-act race between the
                -- pre-check above and this INSERT (the DB-level backstop,
                -- one of the two UNIQUE KEYs) -- treat identically to the
                -- normal "already partnered" rejection.
                RefreshPartnershipCache(k9Citizenid)
                RefreshPartnershipCache(officerCitizenid)
                return 'already_partnered'
            end

            print(('[qbx_k9unit] Partnership establish INSERT failed for k9=%s handler=%s: %s'):format(k9Citizenid, officerCitizenid, tostring(insertResultOrErr)))
            return 'insert_failed'
        end

        RefreshPartnershipCache(k9Citizenid)
        RefreshPartnershipCache(officerCitizenid)
        return 'ok'
    end)

    -- ALWAYS release before branching on the result -- see
    -- PartnershipEstablishMutex's own doc comment for why this must happen
    -- unconditionally, even (especially) when `ranOk` is false.
    PartnershipEstablishMutex.Release(PARTNERSHIP_ESTABLISH_MUTEX_KEY)

    if not ranOk then
        print(('[qbx_k9unit] Partnership establish critical section errored for k9=%s handler=%s: %s'):format(k9Citizenid, officerCitizenid, tostring(outcomeOrErr)))
        NotifyPlayer(fromServerId, 'An error occurred while setting up the partnership.', 'error')
        NotifyPlayer(src, 'An error occurred while setting up the partnership.', 'error')
        return
    end

    if outcomeOrErr == 'already_partnered' then
        NotifyPlayer(fromServerId, PartnershipRejectReasonMessage('already_partnered'), 'error')
        NotifyPlayer(src, PartnershipRejectReasonMessage('already_partnered'), 'error')
        return
    elseif outcomeOrErr == 'insert_failed' then
        NotifyPlayer(fromServerId, 'An error occurred while setting up the partnership.', 'error')
        NotifyPlayer(src, 'An error occurred while setting up the partnership.', 'error')
        return
    end

    -- outcomeOrErr == 'ok' -- both parties are online by construction here
    -- (the consent handshake requires it), unlike DoBreakPartnership below,
    -- which must tolerate either side being offline.
    TriggerClientEvent('qbx_k9unit:client:partnershipEstablished', k9Src, officerSrc, true)  -- isK9 = true
    TriggerClientEvent('qbx_k9unit:client:partnershipEstablished', officerSrc, k9Src, false) -- isK9 = false
end)

--- Internal teardown core, keyed by CITIZENID (not source) so it works
--- identically whether `citizenid` is currently online or not -- see this
--- file's header "OFFLINE-CAPABLE BY DESIGN" section for why this is a
--- required divergence from server/main.lua's source-keyed
--- `doDetachLeash`, not a style choice. Shared by the player-initiated
--- breakPartnership event below and by ForceBreakPartnershipForCitizenId
--- (server-triggered, e.g. cert revocation) so there is exactly one place
--- that mutates a partnership row on teardown.
--- @param citizenid string -- either party's citizenid; the OTHER side is resolved from the row itself
--- @param endedByValue string -- either `citizenid` itself (self-initiated) or a 'system:<reason>' sentinel (automatic teardown)
--- @param broadcastReason string -- sent to whichever party/parties are online via partnershipEnded
--- @return boolean ended -- false if `citizenid` wasn't actively partnered (no-op, not an error)
local function DoBreakPartnership(citizenid, endedByValue, broadcastReason)
    local row = MySQL.single.await(
        'SELECT id, k9_citizenid, handler_citizenid FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
        { citizenid, citizenid }
    )
    if not row then return false end -- no-op: this citizenid isn't currently partnered

    local affectedRows = MySQL.update.await(
        'UPDATE k9_partnerships SET active = 0, ended_by = ?, ended_at = CURRENT_TIMESTAMP WHERE id = ? AND active = 1',
        { endedByValue, row.id }
    )

    -- Refresh BOTH citizenids' cache unconditionally, regardless of whether
    -- this specific call actually flipped the row: either this call won a
    -- race against a concurrent teardown of the SAME row (e.g. both
    -- parties call breakPartnership in the same instant, or a manual break
    -- races an automatic cert-revoke teardown) and the cache was stale, or
    -- it lost that race and some OTHER call already refreshed it -- either
    -- way, re-reading here is correct and, in the loss case, a harmless
    -- redundant read.
    RefreshPartnershipCache(row.k9_citizenid)
    RefreshPartnershipCache(row.handler_citizenid)

    if not affectedRows or affectedRows == 0 then
        return false -- lost the race above -- someone else already ended this exact row
    end

    local partnerCitizenid = (row.k9_citizenid == citizenid) and row.handler_citizenid or row.k9_citizenid
    TellCitizenIdPartnershipEnded(citizenid, broadcastReason)
    TellCitizenIdPartnershipEnded(partnerCitizenid, broadcastReason)

    return true
end

--- Either party ends the partnership unilaterally, no consent required --
--- mirrors server/main.lua's detachLeash exactly (PHASE3_SPEC.md §12.0
--- item 7 point 3's "no unbounded trap" guarantee, now applied to a
--- persistent relationship). No-op if the caller isn't currently
--- partnered with anyone.
RegisterNetEvent('qbx_k9unit:server:breakPartnership', function()
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end

    local ok, brokeOrErr = pcall(DoBreakPartnership, citizenid, citizenid, 'broken')
    if not ok then
        print(('[qbx_k9unit] breakPartnership failed for %s: %s'):format(citizenid, tostring(brokeOrErr)))
        NotifyPlayer(src, 'An error occurred while ending the partnership.', 'error')
        return
    end
    if not brokeOrErr then
        NotifyPlayer(src, 'You are not currently partnered with anyone.', 'inform')
    end
    -- On success, TriggerClientEvent already fired inside DoBreakPartnership
    -- (via TellCitizenIdPartnershipEnded) -- no separate NotifyPlayer here,
    -- mirroring leash's own "state-change broadcasts show their own
    -- notification client-side, only error/ack paths use server-side
    -- NotifyPlayer directly" convention (compare doDetachLeash, which never
    -- calls NotifyPlayer itself either).
end)

--- Resource-global (no `local`) -- exposed for server/certifications.lua to
--- call alongside every existing ForceDetachLeashForSource/
--- ForceDetachOfficerLeashForSource call site (K9-role cert revocation,
--- either party's department change) -- PHASE3_SPEC.md §12.0 item 7 point
--- 3's exact instruction. CITIZENID-keyed, not source-keyed -- works
--- whether `citizenid` is online or offline right now (see this file's
--- header "OFFLINE-CAPABLE BY DESIGN" section for why this is required,
--- not optional, for the RevokeCertificationOffline call site
--- specifically). No-op (returns false) if `citizenid` has no active
--- partnership, in EITHER role -- unlike leash's role-gated
--- ForceDetachLeashForSource/ForceDetachOfficerLeashForSource pair, a
--- SINGLE function covers both roles here, since certification revocation
--- and department loss both end a partnership regardless of which side
--- `citizenid` happens to be on (a K9-role citizenid loses HasK9Access on
--- revoke; a handler/officer-role citizenid loses department membership on
--- the same triggers -- either one invalidates the partnership).
--- @param citizenid string
--- @param reason string -- plain reason (e.g. 'certification_revoked', 'department_changed') -- this function prefixes it with 'system:' for the DB's ended_by column, and passes it unprefixed to partnershipEnded
--- @return boolean ended
function ForceBreakPartnershipForCitizenId(citizenid, reason)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end

    local ok, result = pcall(DoBreakPartnership, citizenid, ('system:%s'):format(reason or 'unknown'), reason or 'ended')
    if not ok then
        print(('[qbx_k9unit] ForceBreakPartnershipForCitizenId failed for %s: %s'):format(citizenid, tostring(result)))
        return false
    end
    return result
end

--- Cleans up ephemeral request state on disconnect, and drops this
--- citizenid's in-memory cache entry -- does NOT tear down an actual
--- partnership. See this file's header "OFFLINE-CAPABLE BY DESIGN" section
--- for the full reasoning on why this handler's shape is a deliberate,
--- disclosed divergence from server/main.lua's LeashPairs cleanup
--- (restated briefly inline below since this is the load-bearing part of
--- this file most likely to be "fixed" back toward leash's shape by a
--- future editor skimming server/main.lua's own playerDropped handler
--- without reading this file's header first).
AddEventHandler('playerDropped', function(_reason)
    local src = source

    -- Target-side: a request aimed AT the disconnecting player.
    PendingPartnershipRequests[src] = nil

    -- Initiator-side: scan for a still-open request the disconnecting
    -- player themselves sent to someone else -- same reasoning as
    -- server/main.lua's identical scan for PendingLeashRequests (FiveM
    -- recycles numeric server ids, so an unscanned stale `.from` entry
    -- could otherwise resolve to a different, unrelated player who
    -- happens to reconnect with the same id before this entry's TTL
    -- expires). Table is small and short-lived (Config.Partnership.RequestTTLMs),
    -- so a linear scan here is not a performance concern.
    for targetSrc, pending in pairs(PendingPartnershipRequests) do
        if pending.from == src then
            PendingPartnershipRequests[targetSrc] = nil
        end
    end

    -- DELIBERATELY DOES NOT CALL DoBreakPartnership / ForceBreakPartnershipForCitizenId
    -- HERE. A K9 partnership is explicitly designed to SURVIVE a
    -- disconnect/reconnect -- that is the entire reason it is DB-backed
    -- rather than ephemeral (PHASE3_SPEC.md §12.0 item 7 point 2:
    -- "session-spanning, plausibly shift-spanning"). Only this citizenid's
    -- in-memory CACHE entry is dropped below -- mirroring
    -- server/certifications.lua's own unbounded-growth fix for its
    -- `Certifications` table (see that file's own playerDropped handler
    -- and comment) -- harmless, since it's cheaply rebuilt from a fresh DB
    -- query on this citizenid's next PlayerLoaded, and the underlying
    -- persisted row plus the still-online partner's own cache entry are
    -- left completely untouched.
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        Partnerships[citizenid] = nil
    end
end)

-- STRUCTURAL GAP backfill, mirroring server/main.lua's own identical-purpose
-- onResourceStart loop for RefreshCertificationCache: server/certifications.lua's
-- (and this file's own) cache populates per-player on a player-loaded
-- event, which only fires for players who connect/load AFTER that handler
-- is registered. On a `/restart qbx_k9unit` (or a crash-restart) while
-- players are already online, nobody re-fires that event for them, so
-- their partnership cache entry would sit empty (= "no active partnership
-- known") until their next reconnect -- a genuinely-partnered pair could
-- silently see BiteAndHold's Recall / HandlerDownDefense's trigger (once
-- either is built) treat them as unpartnered for the remainder of their
-- session. GetPlayers() returns connected player ids as strings; tonumber'd
-- below, same pattern as server/main.lua's own loop.
--
-- CONFIDENCE NOTE: uses 'QBCore:Server:PlayerLoaded' below with the SAME
-- MEDIUM-HIGH confidence server/certifications.lua's own identical-purpose
-- hook already carries (see that file's own CONFIDENCE NOTE near its
-- bottom) -- not re-derived independently here, since it's the exact same
-- event, already relied on elsewhere in this resource.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                RefreshPartnershipCache(Player.PlayerData.citizenid)
            end
        end
    end
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if citizenid then
        RefreshPartnershipCache(citizenid)
    end
end)
