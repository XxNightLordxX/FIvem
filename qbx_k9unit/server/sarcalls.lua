--[[
    qbx_k9unit/server/sarcalls.lua

    Missing-person / search-and-rescue calls -- PROJECT_HISTORY.md §3. Sibling to
    server/scenttrail.lua (PROJECT_HISTORY.md §2's "follow your nose" hunting
    feel): same core shape (a hidden point near the officer's own current
    position, closed on purely by a felt distance cue, never a revealed
    coordinate), pointed at a different kind of call -- nobody is a
    suspect, nothing bad happens at the end, the call resolves as a rescue.
    Read server/scenttrail.lua's own header first; several design choices
    below are DELIBERATE, DISCLOSED DEPARTURES from that file's precedent,
    not an accident of two agents solving the same problem differently --
    see "WHY THIS FILE DIFFERS FROM server/scenttrail.lua" below for
    exactly which choices differ and why.

    ======================================================================
    THE HARDEST PART OF THIS FEATURE, READ FIRST: an SAR call spawns or
    designates a "missing person." This resource has already been bitten by
    an ARBITRARY-ENTITY-DELETION bug (server/kennel.lua's history) and a
    NETID RACE (server/propattachment.lua's history). This file's answer:
    IT NEVER CREATES, TRACKS, OR RESOLVES A NETID AT ALL FOR THE HIDDEN
    TARGET. The "missing person"/"lost property" is not a game entity while
    it is missing -- it is a bare (x, y) pair held only in this file's own
    ActiveSarCalls table, exactly mirroring server/scenttrail.lua's
    ActiveHunts. There is nothing to delete, nothing to race, nothing to
    hijack across features, because nothing is ever spawned until AFTER the
    call has already resolved -- see "THE COSMETIC REVEAL" below for the
    one entity this feature ever causes to exist, and why it is entirely
    client/sarcalls.lua's own problem, never this file's.

    ======================================================================
    WHY THE TARGET COORDINATE NEVER CROSSES THE WIRE:
    Identical reasoning to server/scenttrail.lua's own "WHY THE COORDINATE
    NEVER LEAVES THIS FILE" section, restated here because it is equally
    load-bearing for this file: the K9 is never told where the spot is
    (PROJECT_HISTORY.md §2's "you don't get told where the thing is... you're
    guided toward it" framing, which §3 explicitly reuses). The tick loop
    below only ever PUSHES a coarse tier label ('cold'/'warm'/'hot'/
    'burning') to the caller's own client -- never the target's coordinate,
    never a bearing. A modified client can still triangulate the hidden
    point by walking a line and comparing successive tier answers -- that
    is not a bug, it is the intended "hot/cold" mechanic; what this closes
    is a modified client reading the raw coordinate off the wire once and
    jumping straight to it.

    WHY 2D (HORIZONTAL) DISTANCE ONLY, NOT 3D: identical reasoning to
    server/scenttrail.lua's own "WHY 2D" section -- FXServer has no
    renderer and no loaded world collision, so there is no reliable
    server-side "what is the ground height here" query. RollSarTarget below
    only ever produces an (x, y) pair; distance is a flat dx/dy/sqrt,
    ignoring Z entirely. DISCLOSED LIMITATION, same as that file's: a call
    area with real vertical separation (a target one floor up, a target
    below a target's own vantage point on a hill) will read as closer than
    it plays. Acceptable for a v1 whose hidden target starts life inside
    the same rough horizontal search area as the requesting officer, not
    claimed to handle every possible terrain shape.

    ======================================================================
    WHY THIS FILE DIFFERS FROM server/scenttrail.lua (both are legitimate
    patterns already established in this exact codebase for "K9 hunts a
    hidden point" -- the choice below was made deliberately per this
    feature's own constraints, not a stylistic preference):

    1. ACTIVE SERVER-SIDE TICK LOOP, NOT A CLIENT-DRIVEN POLL. server/
       scenttrail.lua's pollScentHunt is a lib.callback the CLIENT calls on
       its own interval; ActiveHunts entries are only ever lazily expired
       "whenever next polled" (that file's own header: "no dedicated sweep
       thread exists... a source that starts a hunt, then never polls AND
       never disconnects, cannot happen from this file's own client"). That
       reasoning does not transfer here: THIS feature's task explicitly
       requires a call to "ALWAYS expire on a timer even if nobody completes
       it," not merely "whenever the client happens to ask again" -- a
       modified or simply stalled client that stops polling but never
       disconnects would otherwise leave an ActiveSarCalls entry (and,
       transitively, an unclosed 'qbx_k9unit:events:sarCallStarted' from a
       dispatch listener's point of view) sitting forever. A single
       CreateThread tick loop below, mirroring server/integrations.lua's
       K9DownDispatch PollK9Health shape exactly (iterate active state once
       per Config.SARCalls.pollIntervalMs, read each caller's own live
       server-side position fresh), guarantees the expiry actually fires on
       its own, independent of client behavior, and doubles as the hint-push
       mechanism (no separate poll endpoint needed at all).
    2. XP IS AWARDED HERE; SCENT TRAIL HUNTS AWARD ZERO, DELIBERATELY (see
       that file's own "THE XP DECISION"). Because this feature pays out,
       it needs its own re-derived anti-farm stack rather than borrowing
       that file's -- see "XP ARITHMETIC" below for the concrete numbers.
    3. StartSarCallCooldown IS KEYED BY CITIZENID, NOT BY SOURCE (server/
       scenttrail.lua's StartHuntCooldown is keyed by source, and
       deliberately cleared via :RegisterPlayerDropped() on disconnect).
       A cooldown that resets on reconnect is fine for a zero-stakes
       feature; it is a relog-to-bypass hole for one that mints real XP.
       This file's cooldown is therefore keyed by the resolved citizenid
       (matching server/progression.lua's own AwardXPCooldown convention)
       and is deliberately NEVER cleared on disconnect -- see the
       StartSarCallCooldown declaration below.
    4. THE HIDDEN TARGET SPAWNS A REAL, IF PURELY COSMETIC, ENTITY ON
       COMPLETION. Scent Trail Hunts never spawn anything. See "THE
       COSMETIC REVEAL" below.

    ======================================================================
    THE COSMETIC REVEAL -- what "finding" the missing person/property
    actually looks like, and why it is entirely OUT OF THIS FILE'S HANDS:
    when a call resolves as 'found', this file's only obligations are (a)
    award XP, (b) fire the outbound integration event, (c) tell the
    finding client's own client, by TriggerClientEvent, that it was found
    and which kind of call it was ('person' | 'property'). It NEVER sends a
    coordinate for the reveal -- client/sarcalls.lua spawns whatever it
    spawns AT THE FINDING CLIENT'S OWN CURRENT POSITION, which it already
    knows without being told anything further. That reveal entity is
    created, tracked, and deleted entirely inside client/sarcalls.lua, is
    NEVER networked (isNetwork = false on both the CreatePed and
    CreateObject call it can make), and therefore NEVER receives a netId,
    is NEVER resolvable by ResolveNetworkEntity, and can NEVER be targeted
    by this or any other feature's cleanup/claim logic -- see that file's
    own header for the full writeup. This file has zero code touching that
    entity's lifecycle in any way, which is the point: the one entity this
    feature ever causes to exist is structurally incapable of becoming
    either of this resource's two previously-found entity bugs, because it
    never has an identity any OTHER piece of code could reference.

    ======================================================================
    NO UNBOUNDED TRAP:
    - RegisterNetEvent('qbx_k9unit:server:abandonSarCall', ...) below is
      UNCONDITIONAL -- it never checks Config.Features.SARCalls or
      HasK9Access. A player who loses access, or a K9 whose certification
      is revoked mid-call, or a player who simply wants to give up, must
      always be able to end their own call. Mirrors server/scenttrail.lua's
      stopScentHunt, server/recall.lua's requestRecall, and every other
      termination path in this resource.
    - Every active call ALSO expires unconditionally, on its own, via the
      tick loop's own Config.SARCalls.maxCallDurationMs check -- see
      "WHY THIS FILE DIFFERS" item 1 above. A call that nobody completes
      and nobody abandons still self-clears within one poll interval of its
      deadline, regardless of whether the officer disconnects, alt-tabs, or
      simply stops caring.
    - playerDropped unconditionally clears ActiveSarCalls[source] too, so a
      genuine disconnect never leaves a stale entry for a reconnecting
      source (a fresh connection gets a fresh `source` id in FXServer
      anyway, but this also protects a same-session id reuse edge case).

    ======================================================================
    XP ARITHMETIC (per this task's own requirement -- state the additional
    XP/hr ceiling this feature makes reachable, with the numbers):
    Config.SARCalls.startCooldownMs = 600000 (10 minutes), keyed per
    citizenid, gates the REQUEST, not the completion -- so even a citizenid
    who instantly solves every call (implausible given minRadius below, but
    treated as the worst case anyway) can request at most 6 calls/hour
    (60 min / 10 min). Config.XP.awards.sarCallCompleted = 30 XP per
    genuine 'found' completion (never on timeout/abandon). Worst-case
    additional ceiling this feature adds: 6 * 30 = 180 XP/hour. That is
    additionally bounded by server/progression.lua's own AwardXP chokepoint
    (a 500ms-per-(citizenid, actionKey) floor, entirely moot here since
    600000ms >> 500ms, and the shared cross-mechanic XP_MINT_BUDGET_CAP_XP
    bucket refilling at 3,600 XP/hour combined across every mechanic this
    resource has) -- 180 is this feature's own worst-case CONTRIBUTION
    toward that shared ceiling, not a ceiling it can exceed: AwardXP's own
    bucket-based budget still caps the CITIZENID'S combined total from every
    source at 3,600/hour regardless of what this file does. 180 is 5% of
    that shared budget even if this feature is run flat-out and nothing
    else the citizenid does mints a single point of XP that same hour.
    Config.SARCalls.minRadius = 40.0m is the source-level floor that makes
    "instantly solves every call" itself implausible in the first place --
    every call requires at least ~34m of real travel from spawn to
    Config.SARCalls.arrivalRadius (6.0m) regardless of how good the player
    is at reading the hint tiers, so the 6/hour figure above is already a
    conservative upper bound, not a number that assumes real play matches
    it.

    ======================================================================
    EVENT/CALLBACK CONTRACT:
    1. 'qbx_k9unit:server:requestSarCall' (source) -> { started: boolean,
       reason: ('already_active'|'cooldown'|'denied')?, callId: number?
       [present iff started == true -- see "STALE-SESSION RACE" below] }
       [lib.callback]
       Re-validates Config.Features.SARCalls and HasK9Access(source)
       server-side regardless of client UI state, mirrors server/
       scenttrail.lua's startScentHunt exactly, including the "denied"
       collapse for feature-off/no-access/citizenid-unresolvable/no-live-ped
       (this resource's established "don't invent a distinction the server
       doesn't give data for" precedent) -- a per-person block.SARCalls
       grant, or a missing feature.SARCalls grant while
       Config.FeatureControl.RequireGrant.SARCalls is true, collapses into
       the same 'denied' reason (see PER-PERSON FEATURE CONTROL below, and
       IsSarCallsPermittedForCitizenId's own doc comment). Resolves the CALLER'S OWN live
       server-side position as the origin to roll a target near -- NEVER a
       client-supplied coordinate. The call's type ('person' | 'property')
       is rolled here too and kept server-side only until the call resolves
       as 'found' -- neither the client nor any caller of this callback
       ever learns it up front, preserving the same mystery for BOTH kinds
       of call. 'already_active' now also covers "already a MEMBER of
       someone else's call" -- see "TWO OFFICERS, ONE CALL" below: one
       citizenid, one call, in either role, at a time.
    2. 'qbx_k9unit:server:abandonSarCall' (source) [RegisterNetEvent] --
       UNCONDITIONAL. See "NO UNBOUNDED TRAP" above. Since "TWO OFFICERS,
       ONE CALL" below, this is the ONE unconditional path for leaving a
       call in EITHER role -- see that section for exactly what leaving
       means when other members remain.
    3. 'qbx_k9unit:server:requestJoinSarCall' (source, targetServerId: number)
       [RegisterNetEvent] -- step 1 of a second officer's join handshake.
       See "TWO OFFICERS, ONE CALL" below for the full design.
    4. 'qbx_k9unit:server:respondJoinSarCall' (source, fromServerId: number,
       accepted: boolean) [RegisterNetEvent] -- step 2, the call OWNER's
       response. See "TWO OFFICERS, ONE CALL" below.
    5. 'qbx_k9unit:client:sarHintTierChanged' (tier: string, callId: number)
       [TriggerClientEvent, THIS FILE only ever SENDS this, to ONE member's
       own client at a time, never broadcast] -- fired once immediately for
       a member the instant they join the call (whether by starting it or
       by having a join request accepted), and again every time the tick
       loop below observes a DIFFERENT tier than last observed FOR THAT
       MEMBER. Never fired twice in a row with the same tier for the same
       member -- see TierForDistance/the tick loop's own edge-trigger
       comment. callId added -- see "STALE-SESSION RACE" below.
    6. 'qbx_k9unit:client:sarCallEnded' (reason: ('found'|'found_by_teammate'|
       'timeout'|'abandoned'), callType: ('person'|'property')? [only
       meaningful when reason == 'found'], callId: number, targetX: number?,
       targetY: number? [present iff reason == 'found'|'found_by_teammate'
       -- see "SHARED FOUND MARKER" below])
       [TriggerClientEvent, THIS FILE only ever SENDS this, to one member's
       own client at a time] -- the one and only signal telling
       client/sarcalls.lua to run its own local cosmetic reveal (reason ==
       'found' only -- see "TWO OFFICERS, ONE CALL" below for why
       'found_by_teammate' deliberately never triggers the FINDER-ONLY
       entity reveal) and/or its own shared found-MARKER (reason == 'found'
       OR 'found_by_teammate' -- see "SHARED FOUND MARKER" below, added this
       pass, for exactly what widened and what deliberately did not).
       callId added -- see "STALE-SESSION RACE" below.
    7. 'qbx_k9unit:client:sarCallJoined' (callId: number, initialTier: string)
       [TriggerClientEvent, THIS FILE only ever SENDS this, to the newly-
       accepted joiner's own client only] -- see "TWO OFFICERS, ONE CALL"
       below.
    8. 'qbx_k9unit:client:sarJoinRequest' (fromServerId: number)
       [TriggerClientEvent, THIS FILE only ever SENDS this, to the call
       OWNER's own client only] -- shown as an accept/decline prompt,
       mirroring server/partnership.lua's partnerUpRequest push.

    Outbound integration events (server/exports.lua's `qbx_k9unit:events:*`
    namespace, server/integrations.lua's OUTBOUND-only convention -- this
    file never names, requires, or GetResourceState-branches on any
    specific dispatch/MDT/framework resource):
      'qbx_k9unit:events:sarCallStarted'   (source, citizenid, jobName, callType)
      'qbx_k9unit:events:sarCallCompleted' (source, citizenid, jobName, callType, durationMs)
    NO corresponding 'timeout'/'abandoned' outbound event, on purpose --
    identical reasoning to server/integrations.lua's own "NOT IN SCOPE: a
    corresponding recovered/cleared event" section for k9Down: a dispatch
    resource that wants a "stood down" concept can already infer one from
    its own timeout, the same way a real dispatch board ages out a stale
    call with no explicit "never mind" message ever needed.

    Automatic path: the tick loop (CreateThread below) and a
    `playerDropped` handler. No commands/chat handlers live in this file --
    those are client/sarcalls.lua's concern ('/k9sarcall [stop]').
    ======================================================================

    PER-PERSON FEATURE CONTROL -- ADDED A LATER PASS (this pass found and
    closed the gap; not present when this file was first written).
    config.lua's own Config.FeatureControl.RequireGrant.SARCalls entry has
    existed since that block was authored (with its own comment explaining
    SARCalls is listed there "so high command can phase the hunt in per
    person"), but requestSarCall below checked only Config.Features.SARCalls
    and HasK9Access(source) -- the grant/block never had any effect. Fixed by
    copying server/pursuitsprint.lua's own
    IsPursuitSprintPermittedForCitizenId shape verbatim (see
    IsSarCallsPermittedForCitizenId below) -- pursuitsprint.lua's own header
    says to read it before writing another variant, and server/findalert.lua
    already did the same for its own equivalent gap. Checked AFTER citizenid
    resolves (a request that cannot be attributed to a real citizenid was
    already 'denied' before this existed) and BEFORE
    StartSarCallCooldown.Consume(citizenid) -- a denied request must never
    spend the caller's cooldown budget, same reasoning the citizenid
    resolution check immediately above it already established.
    UNCONDITIONAL AND UNAFFECTED: 'qbx_k9unit:server:abandonSarCall' and the
    tick loop's own timeout/found resolution -- this gate exists ONLY on the
    call-START path. A citizenid whose grant is revoked, or who is freshly
    blocked, mid-call must still be able to end that call exactly like
    everyone else (see "NO UNBOUNDED TRAP" above) -- this resource's
    established rule that a termination path is never gated on
    access/certification/permission is not negotiable, and gating abandon
    here would violate it for no benefit (the call is already running; all
    a block should do is stop a NEW one from starting).
    ======================================================================

    STALE-SESSION RACE -- ADDED A LATER PASS (found by a client-side sweep;
    not present when this file was first written): client/sarcalls.lua's own
    header documents the client-side half of this fix in full -- restated
    here from this file's point of view because minting the id is this
    file's own job.

    THE BUG: neither requestSarCall's response nor any of the three pushes
    (sarHintTierChanged, sarCallEnded) ever carried anything identifying
    WHICH call they belonged to. A client that abandons call A and
    immediately starts call B could have call A's own late-arriving
    'abandoned' echo land while call B's own requestSarCall await was still
    pending; that echo's handler had no way to tell "a late echo of the call
    I already left" from "a newer start already in flight" and bumped the
    client's own staleness counter regardless -- discarding call B's own,
    entirely legitimate, successful grant as if it were stale. The result:
    the server ran call B fully live (tick loop, hint pushes, eventual
    found/timeout) while the client's own `sarCallActive` flag stuck false,
    silently dropping every hint notification for the rest of it. The
    ANALOGOUS bug in server/scenttrail.lua's own sibling feature is spelled
    out in client/scenttrail.lua's header.

    THE FIX: this file now mints a small, monotonically increasing,
    SERVER-ISSUED session id (NewSarCallId below) once per call, the moment
    ActiveSarCalls[source] is created -- never client-generated (a
    client-generated id could be spoofed or duplicated, defeating the whole
    point). It rides along on every push belonging that call: the
    return value's own `callId` field, both sarHintTierChanged pushes (the
    immediate one below and the tick loop's own), and all three
    sarCallEnded branches inside EndSarCall (found/timeout/abandoned).
    client/sarcalls.lua stores the id from its own successful grant and
    drops any push whose id does not match its own currently tracked one --
    see that file's own IsForCurrentSarCall for the exact matching rule,
    including the deliberate "a push with no id at all is always accepted,
    never silently dropped" decision (a defensive floor against a future
    call site here forgetting to pass one -- see that same doc comment for
    why the opposite default would be far worse).

    NOT A TERMINATION-PATH CHANGE: this fix touches only how the CLIENT
    interprets an incoming push. It adds nothing this file's own
    RegisterNetEvent('qbx_k9unit:server:abandonSarCall', ...) below reads,
    checks, or requires -- that handler remains exactly as unconditional as
    it already was (see "NO UNBOUNDED TRAP" above), taking no id, keyed
    purely on the ambient `source`. A client holding a stale/wrong/nil
    session id, for any reason, can still always abandon and be cleaned up
    -- the id mechanism exists purely to let the client tell two of ITS OWN
    past/current sessions apart when deciding whether to act on a push, not
    to gate anything server-side.

    ======================================================================

    TWO OFFICERS, ONE CALL (this pass -- closes the resource's own recorded
    limitation that a search-and-rescue call could only ever be worked
    solo). Read server/partnership.lua's own "requestPartnerUp"/
    "respondPartnerUp" pair and server/main.lua's "requestLeashAttach"/
    "respondLeashAttach" pair before touching anything below -- this reuses
    their exact consent-handshake shape (single-slot-per-target pending
    table, TTL, re-validate everything at accept time, clean up on
    disconnect from BOTH sides), not a fourth, independently-invented one.

    DECISION 1 -- WHO INITIATES: THE WOULD-BE JOINER, NOT THE OWNER. An
    officer who wants to help sends 'qbx_k9unit:server:requestJoinSarCall'
    naming the officer already running a call; THAT OWNER'S client shows
    the accept/decline prompt via 'qbx_k9unit:client:sarJoinRequest'. This
    is deliberately the OPPOSITE direction from "the owner invites" --
    an owner mid-search should not have to stop and go hunt down a specific
    colleague to bring them in; a nearby, eligible officer offering to help
    costs the owner nothing more than a single accept/decline tap, and
    nothing happens to the owner's call at all unless they explicitly say
    yes. This is neither of the two extremes named in this feature's own
    design brief ("open join" — anyone can seat themselves with zero
    consent, a real griefing surface — or "owner invites" — real friction,
    since the owner would need to already know who is nearby and willing)
    -- it is the SAME two-step consent shape this codebase already ships
    twice for an analogous "may I do a thing WITH you" question, aimed the
    direction that fits this feature's own scenario (a second responder
    arriving at an active scene) rather than partnership/leash's "either
    party may ask" symmetry, since here only the OWNER has something to
    consent to protect (their run, their workflow) -- the joiner is already
    consenting to help by asking. CheckSarJoinEligibility below re-validates
    HasK9Access/feature flag/per-person grant/proximity/call-not-full for
    the REQUESTER at REQUEST time (an honest early rejection) and AGAIN at
    ACCEPT time (TOCTOU -- either party could have moved, disconnected,
    lost access, or the call could have ended entirely, in between). No
    mutex is needed for the accept step, unlike server/partnership.lua's
    DB-backed establish flow: adding a member here is a single, synchronous,
    in-memory table write with no yielding DB round-trip in between the
    re-check and the write, so there is no window for a second accept to
    race into.

    DECISION 2 -- THE OWNER DISCONNECTING TRANSFERS THE CALL, NEVER ENDS IT
    OUT FROM UNDER A REMAINING SEARCHER. `ActiveSarCalls` is now keyed by
    the call's own immutable `callId`, not by a source that can go stale --
    `call.ownerSrc` is a MUTABLE FIELD naming whichever member currently
    "runs" the call (the only thing that field controls: who
    CheckSarJoinEligibility treats as the accept authority for a NEW join
    request). `call.citizenid`/`call.jobName`, by contrast, are captured
    ONCE at creation and NEVER change -- they identify who PAID
    StartSarCallCooldown's own anti-farm floor to create this call, which
    is a completely separate question from who is currently online to
    manage it (see DECISION 3 for why this split matters). When the current
    owner leaves (voluntarily via abandonSarCall, or involuntarily via
    playerDropped), RemoveMemberFromSarCall below reassigns `call.ownerSrc`
    to whichever remaining member joined earliest (deterministic; not a
    popularity contest) and the call keeps running, exactly as if nothing
    happened, for every member still in it -- the tick loop iterates
    `call.members`, never a single hardcoded source, so it needs no special
    case for this at all. The call only ever ends OUTRIGHT when its LAST
    member leaves (see RemoveMemberFromSarCall's own doc comment) --
    "ending it under someone still actively searching" (this feature's own
    named trap shape) is therefore structurally impossible: nobody's own
    membership is ever touched by anyone else's disconnect.

    DECISION 3 -- JOINERS EARN ZERO XP. THIS IS DELIBERATE, NOT AN
    OVERSIGHT. server/search.lua's TryAwardCoopSearchBonus (grep
    'coopSearchBonus') is this resource's own precedent for paying a SECOND
    person for someone else's success, and read in full before this
    decision was made -- it only ever pays out to an established, DB-backed,
    mutually-consented PARTNERSHIP (server/partnership.lua), gated on BOTH
    parties holding Trained-tier XP or above, the receiving partner being
    ONLINE and within COOP_SEARCH_PARTNER_PROXIMITY_METERS of the find, AND
    its own dedicated per-receiving-citizenid mint cooldown, ALL routed
    through the SAME shared AwardXP budget everything else already competes
    for. That is a lot of machinery, and it exists precisely because
    letting a second citizenid earn XP from a first citizenid's action is
    an easy new farm surface the moment the two can coordinate. A SAR-call
    joiner has NONE of that machinery's preconditions -- by DECISION 1's own
    design, joining requires no pre-existing relationship at all, just
    "nearby, eligible, and the owner said yes" -- which makes it a
    STRICTLY EASIER two-account loop to run than coopSearchBonus's own:
    citizenid A starts a call (spending A's own 10-minute
    StartSarCallCooldown) and invites B to join; if joining minted XP, B
    would earn a full sarCallCompleted award WITHOUT EVER TOUCHING B's OWN
    StartSarCallCooldown budget, and the two could then swap roles on B's
    own next call, each collecting a sarCallCompleted award on BOTH their
    own start-path AND the other's join-path on the very same 10-minute
    cycle -- silently doubling this mechanic's own documented 180 XP/hr
    worst-case ceiling (see "XP ARITHMETIC" above) for two coordinating
    accounts, with no new per-citizenid cooldown anywhere to catch it. Doing
    this SAFELY would mean building coopSearchBonus's own full stack a
    second time (a per-joiner-citizenid mint cooldown, a tier floor, routing
    through the shared budget, and probably a proximity-to-the-find check
    identical to "am I actually helping or just standing near the owner at
    the start") for a bonus this feature's own design brief explicitly
    permits skipping. THE DECISION: a joining officer's citizenid is
    NEVER passed to AwardXP, for any reason, on any resolution of any
    call -- only `call.citizenid` (the ORIGINAL starter, fixed at
    creation, per DECISION 2) ever receives sarCallCompleted, on 'found',
    exactly as before this pass, REGARDLESS of which member's own live
    position is the one that actually crossed arrivalRadius. This makes
    the two-colluding-accounts loop pay off NOTHING beyond what solo play
    already allows: each citizenid can only ever mint SAR XP from a call
    THEY THEMSELVES paid the cooldown to start, exactly as before this
    pass -- joining someone else's call is worth doing for the roleplay
    and for genuinely finishing the call faster (the same "help them find
    it sooner" value coopSearchBonus's own header describes), never for a
    payout. Proven by tests/sarcalls_spec.lua's own anti-farm test:
    two citizenids alternately starting-and-inviting each other, finding
    every single call, still each earn XP at exactly the rate their OWN
    solo cooldown alone would allow -- the join path itself never calls
    AwardXP at all.

    THE FINDER STILL MATTERS, EVEN THOUGH XP DOES NOT DEPEND ON IT: the
    tick loop below identifies WHICH member's own live position crossed
    arrivalRadius (`finderSrc`) and treats them differently from every
    other current member purely for FEEDBACK, never for reward -- only the
    finder gets reason == 'found' (which triggers client/sarcalls.lua's own
    FINDER-ONLY entity-level reveal AT THAT CLIENT'S OWN POSITION, since only
    the finder is actually standing where the target was). Every OTHER
    member gets reason == 'found_by_teammate' instead -- their own state
    resets the same way, and (see "SHARED FOUND MARKER" immediately below,
    this pass) now also sees a shared, non-entity marker at the real target
    coordinates, but the entity-level reveal never spawns at THEIR position,
    since they are not standing anywhere near the real target and a spawned
    ped/prop there would misrepresent what just happened. Both branches are
    IN EndSarCall below, never a separate code path, so both inherit the
    exact same "one resolution, notify everyone once" discipline.

    ======================================================================
    SHARED FOUND MARKER (this pass -- closes the resource's own recorded
    limitation, KNOWN_ISSUES.md's "Search-and-rescue 'found' reveal is
    visible only to the officer who found it," which predates "TWO
    OFFICERS, ONE CALL" and was written back when a call had exactly one
    officer to begin with). Now that a call can have several genuinely
    searching MEMBERS, a member who never sees any signal that the search is
    over would otherwise keep hunting a target that no longer exists --
    EXCEPT that was already NOT true even before this pass: every member,
    finder or not, was already unconditionally sent 'qbx_k9unit:client:
    sarCallEnded' (see the loop over `call.members` above, present since
    "TWO OFFICERS, ONE CALL" first shipped), which already resets that
    client's own `sarCallActive` and shows a real NotifyPlayer toast
    ('sar.found_by_teammate') -- nobody was ever left silently hunting a
    resolved call. What was genuinely still true one-officer-shaped: the
    VISUAL payoff (see client/sarcalls.lua's own "WHY THE REVEAL IS NEVER
    NETWORKED" header section) landed on the finder's own screen alone, with
    nothing for anyone else to look at or walk toward.

    THE ENTITY-LEVEL REVEAL STAYS FINDER-ONLY. UNCHANGED, ON PURPOSE. That
    reveal's own "ghost-entity" concern (client/sarcalls.lua's header,
    predating this pass) is about a client rendering an entity it does not
    itself hold a live, correctly-scoped handle for -- and this file's own
    entity history (kennel's arbitrary-entity-deletion bug, propattachment's
    netId race, both named in this file's own opening header) is exactly
    that failure mode: a piece of code holding a reference to, or an
    identity for, an entity it does not fully own the lifecycle of. Widening
    ShowReveal's own CreatePed/CreateObject call to fire on every member's
    own client would mean EVERY member spawns their OWN separate, unrelated,
    equally non-networked ped/prop, at THEIR OWN current position (never the
    real target's, since that coordinate was never sent to them before this
    pass either) -- which is not "the team sees one shared find," it is
    "every member sees an unrelated stand-in appear at their own feet,"
    strictly worse than doing nothing, not better. Networking the entity
    instead (spawn once, report the netId, have this file claim and own it
    via server/entities.lua the way kennel/fetch/propattachment already do)
    would be a structurally different feature -- a real, tracked, claimed
    entity with its own cleanup obligations -- exactly the risk class this
    whole feature's own header states, up front, it exists to avoid for a
    purely cosmetic payoff. NOT ATTEMPTED HERE. See client/sarcalls.lua's
    own header for the confirmation that ShowReveal's call sites are
    unchanged by this pass.

    THE ANSWER: everything BELOW the entity is safe to share, because none
    of it is an entity at all. This pass adds `call.targetX`/`call.targetY`
    -- the SAME two numbers this file's own "WHY THE TARGET COORDINATE
    NEVER CROSSES THE WIRE" header section above says must never cross the
    wire -- to the sarCallEnded push, for EVERY member, on BOTH the 'found'
    and 'found_by_teammate' branches below. This is NOT a reversal of that
    section's own reasoning, because the reasoning was scoped to WHILE THE
    CALL IS STILL ACTIVE: the whole point of never sending the coordinate
    earlier is that a modified client could read it once and skip straight
    to the target, bypassing the entire hot/cold mechanic this feature
    exists to be. By the time EndSarCall runs for reason == 'found', the
    mechanic is already over -- the finder already solved it by genuinely
    closing the distance, and every OTHER member has already lost whatever
    "advantage" reading this coordinate now could possibly grant, because
    there is nothing left to search for. Sending it here costs the mechanic
    nothing and buys client/sarcalls.lua's own ShowFoundMarker (its header,
    same section name) the one thing it needs: a real, shared, in-world
    coordinate for a DrawMarker-only, per-frame-rendered, never-created,
    never-networked, nothing-for-anyone's-cleanup-logic-to-ever-reference
    visual cue -- see that file's own header for exactly why a marker (a
    pure render call, no entity, no handle, no netId) is categorically
    unlike CreatePed/CreateObject and cannot reintroduce the ghost-entity
    bug class no matter how many clients receive it.
    ======================================================================

    ONE CITIZENID, ONE CALL, IN EITHER ROLE, AT A TIME: `MemberToCallId[src]
    = callId` is the reverse index every entry point below (requestSarCall,
    requestJoinSarCall/respondJoinSarCall, abandonSarCall, playerDropped)
    consults to answer "is this source currently part of ANY call" in O(1)
    -- a citizenid already owning or having joined a call cannot start a
    second one, join a second one, or be accepted into a second one, closing
    off the one other farm shape decision 3's own arithmetic did not
    already: nobody can multiply their own StartSarCallCooldown budget by
    quietly running two calls at once.

    NOT A TERMINATION-PATH CHANGE, AND NOT GATED ON ANYTHING:
    RemoveMemberFromSarCall (reached from either abandonSarCall or
    playerDropped) never checks Config.Features.SARCalls, HasK9Access, or
    any per-person grant -- leaving, whether voluntary or by disconnecting,
    must always work, for anyone, in any role, exactly like every other
    termination path in this resource. See "NO UNBOUNDED TRAP" above; this
    section extends that guarantee to every member of a call, not only its
    original owner.

    ======================================================================

    STALE JOIN-REQUEST FIX (RED-TEAM PASS -- found live, not present when
    "TWO OFFICERS, ONE CALL" first shipped): PendingSarJoinRequests entries
    used to be cleared in exactly two places -- consumed inside
    respondJoinSarCall once answered, and playerDropped's own two-directional
    scan on a genuine disconnect. Neither one ran when a member left a call
    VOLUNTARILY (abandonSarCall, reaching RemoveMemberFromSarCall while
    still fully connected), which is the ordinary, expected way an officer
    stops a call -- not an edge case.

    THE BUG, CONCRETELY: officer A owns call C1. Officer B sends
    requestJoinSarCall naming A -- PendingSarJoinRequests[A] = { from = B,
    ... } and A's client shows the accept/decline prompt. Before answering,
    A calls abandonSarCall -- C1 ends via RemoveMemberFromSarCall, but the
    pending entry survives (A never disconnected, so playerDropped's own
    scan never ran). A starts a brand-new call, C2. A then taps Accept on
    the dialog still sitting on their screen from BEFORE C1 ended.
    respondJoinSarCall finds the entry still genuine and unexpired,
    re-validates via CheckSarJoinEligibility (which, correctly, resolves
    MemberToCallId[A] to whatever A is a member of RIGHT NOW -- there is no
    way for that function to know the request was made "about" a call that
    no longer exists), and seats B into C2 -- a call B never asked to help
    with, off a prompt that named a call that had already ended by the time
    B was added. `respondJoinSarCall` did exactly what it was asked; the bug
    is that it was asked the wrong question, because nothing ever
    invalidated a still-pending request when the party it named stopped
    being reachable through the call it was actually about.

    THE FIX: RemoveMemberFromSarCall now also clears any PendingSarJoinRequests
    entry naming `src`, in EITHER direction (`src` as the pending TARGET, the
    scenario above; `src` as the pending REQUESTER -- an officer who asked to
    join, then abandoned some OTHER call they happened to also be a member of
    in between asking and being answered, whose now-stale request should not
    silently seat them somewhere later either) -- via
    ClearPendingSarJoinRequestsFor, the same two-directional scan
    playerDropped already performed, extracted into a shared helper so both
    call sites stay byte-for-byte identical rather than two copies that can
    drift. Called UNCONDITIONALLY at the top of RemoveMemberFromSarCall,
    before either early-return -- see "NO UNBOUNDED TRAP"/this section's own
    "NOT A TERMINATION-PATH CHANGE" framing below: this is cleanup work
    riding along an already-unconditional path, never a new gate on it.
    playerDropped's own call to the same helper is now technically redundant
    with RemoveMemberFromSarCall's copy for a disconnecting member (RemoveMemberFromSarCall
    already ran for them, above), but is INTENTIONALLY KEPT, unconditionally,
    for the case RemoveMemberFromSarCall is never reached at all: a source
    with a pending request who is not currently a member of ANY call (e.g. an
    officer who sent requestJoinSarCall and disconnects before ever being
    answered). Both copies are idempotent (repeated nil-assignment), so the
    overlap for the "was a member, then disconnected" case costs nothing.

    NOT A TERMINATION-PATH CHANGE: this fix only ever REMOVES stale state
    that could otherwise be misread later -- it adds no new check that could
    ever block or delay abandonSarCall, playerDropped, or any other
    termination path from doing its own job. A source with no pending
    request at all sees zero behavioral difference.

    ======================================================================

    JOIN-ELIGIBILITY CHECK ORDERING FIX (RED-TEAM PASS -- a narrow
    information-leak, not a correctness bug): CheckSarJoinEligibility used
    to resolve call ownership (`MemberToCallId[targetSrc]`/`targetCall.ownerSrc
    ~= targetSrc` -> 'invalid_target') BEFORE the proximity check
    (`too_far`). GetPlayerPed(targetSrc) succeeding only requires the named
    target to be ONLINE somewhere on the server, not anywhere near the
    requester -- so any citizenid with genuine, un-blocked K9 access could
    aim requestJoinSarCall at an arbitrary online server id from across the
    map and read the DIFFERENCE between 'invalid_target' ("that officer is
    not running a call right now") and 'too_far' ("they are, but you are not
    close enough") as a free, standing signal of whether a specific named
    officer currently has an active search running -- no position, call
    type, or hidden-target bearing leaks, but this file's own "WHY THE
    TARGET COORDINATE NEVER CROSSES THE WIRE" section's whole premise is
    that nothing about a call should be readable by a non-member at all, and
    this was a real, if narrow, hole in that premise the check ORDER opened
    by accident.

    THE FIX: the proximity check now runs FIRST, ahead of ownership
    resolution -- a requester who is not within joinProximityMeters of
    targetSrc gets 'too_far' regardless of whether targetSrc turns out to
    own a call, is a mere non-owner member of one, or has no call at all,
    collapsing the three into one answer for anyone too far away to have
    ever been a legitimate joiner in the first place. THE CARE THIS ORDER
    CHANGE NEEDS: a genuinely NEARBY requester targeting someone with no
    call (or a non-owner member) must still see the HONEST answer,
    'invalid_target', not 'too_far' -- a proximity check that runs first but
    is otherwise unchanged (still just Distance3D against targetSrc's own
    live position) produces exactly that: nearby -> proximity check passes
    -> falls through to ownership resolution -> 'invalid_target' for a real
    non-owner/no-call target, same as before this pass. Only a requester who
    is BOTH far away AND targeting a non-call-owner now gets 'too_far'
    instead of 'invalid_target' -- a strictly LESS informative answer for
    that one combination, never a wrong one: 'too_far' remains true in that
    case (they are, in fact, too far, independent of whatever targetSrc is
    or is not doing), it is just no longer the MOST specific true answer,
    which is the entire point -- a distant caller can no longer distinguish
    "no call" from "call, but I'm too far" for someone they are not actually
    close enough to legitimately join either way. Proximity is now checked
    against targetSrc's own live position in every case, ownership or not,
    which is unchanged from before this pass -- only the ORDER of the two
    checks moved.

    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls HasK9Access(source) (server/certifications.lua), reused, never
      re-derived.
    - Calls NewCooldown (server/cooldowns.lua) at this file's own file-load
      time -- HARD load-order requirement: this file must load AFTER
      server/cooldowns.lua and server/certifications.lua, same precedent
      every other server file in this resource with an identical
      requirement already documents (server/scenttrail.lua, server/
      tracking.lua, server/search.lua, server/defense.lua).
    - Calls AwardXP (server/progression.lua) behind a
      `type(AwardXP) == 'function'` runtime-existence guard -- the same
      soft-dependency convention server/medkit.lua's RestoreInjury call
      site and server/tracking.lua's own AwardXP call sites already
      establish. NOT a hard load-order requirement: this file's position in
      fxmanifest.lua's server_scripts list relative to
      server/progression.lua does not matter.
    - Calls NotifyPlayer (server/notify.lua), reused, never re-derived.
    - Calls HasPermission (server/permissions.lua) behind a
      `type(HasPermission) == 'function'` runtime-existence guard, only from
      IsSarCallsPermittedForCitizenId below -- same soft-dependency
      convention as AwardXP above, matching server/pursuitsprint.lua's own
      identical guard on its own copy of this exact check.
    - Exposes NO resource-global functions. ActiveSarCalls and
      StartSarCallCooldown are this file's own private state; nothing
      outside this file ever reads them directly.
    - Does NOT read or write server/scenttrail.lua's ActiveHunts, server/
      tracking.lua's TrackableLog, or anything else outside this file --
      structurally unrelated systems that happen to share a "K9 walks
      toward a resolved point" shape. No coupling either direction.
    - Never calls AwardXPDirect (that entry point takes a caller-chosen
      amount and exists specifically so nothing else has to; using it here
      would defeat the entire point of Config.XP.awards' fixed, config-
      owned amounts).

    ======================================================================
    NATIVE/GLOBAL VERIFICATION: this file introduces ZERO new natives.
    GetPlayers/GetPlayerPed/GetEntityCoords/GetGameTimer are all already
    allowlisted in the repo-root .luacheckrc read_globals list from this
    resource's existing usage elsewhere (server/integrations.lua's
    PollK9Health is the closest structural precedent for this exact
    combination). math.random/math.sqrt/math.cos/math.sin/math.pi are the
    standard Lua 5.4 math library, not FiveM natives. THIS FILE never uses
    the `#(a - b)` vector-subtraction idiom server/partnership.lua's own
    proximity check uses (that idiom needs a real vector metatable behind
    both operands) -- both Distance2D (the hidden-target math, per "WHY 2D"
    above) and Distance3D (the join-proximity check, "TWO OFFICERS, ONE
    CALL" below) read coordinates by plain `.x`/`.y`/`.z` field access
    only, which works identically whether GetEntityCoords hands back a
    real vector3 or a bare table, and introduces no vector-arithmetic
    native/metamethod dependency of any kind. The one native
    this WHOLE FEATURE needs that this resource has never used before
    (CreatePed) is called ONLY from client/sarcalls.lua, never from this
    file -- see that file's own header for the full verification writeup
    and why this file deliberately never needs a server-side ped-creation
    path at all.
]]

-- FEATURE GATE -- a genuine bug caught and only PARTIALLY fixed by another
-- pass while this file was mid-write (found via this session's own
-- diff-on-external-change review, not left as found): this file originally
-- had NO top-level early return at all, so with Config.Features.SARCalls
-- false, every assert below AND the NewCooldown construction AND the tick
-- CreateThread AND both event registrations still ran unconditionally --
-- directly violating this resource's own "flag off means genuinely inert"
-- invariant (client/kennel.lua's own header names this exact invariant by
-- name) and, if an operator ever removed the then-unused Config.SARCalls
-- block entirely, a hard crash on `local tuning = Config.SARCalls` being
-- nil. An intermediate fix wrapped ONLY the assert block in an `if
-- Config.Features.SARCalls then ... end` -- that stopped the asserts from
-- firing, but left `NewCooldown(tuning.startCooldownMs)` a few lines below
-- (which also indexes `tuning`) and the entire tick loop/event registration
-- surface still unconditional, so the crash and the "still runs when
-- disabled" bug both remained. THE ACTUAL FIX: a single top-level early
-- return, before `tuning` is even read -- the exact, sole pattern every
-- other feature file in this resource already uses for this (client/
-- sarcalls.lua's own top-level gate; server/integrations.lua's `if not
-- Config.Features.K9DownDispatch then return end`; client/recall.lua;
-- client/scenttrail.lua) -- so the rest of this file, guard included,
-- reads exactly as originally written, straight-line, with no internal
-- `if`/`end` wrapper of its own: it simply never executes past this line
-- when the feature is off.
if not Config.Features.SARCalls then return end

local tuning = Config.SARCalls

-- ======================================================================
-- CONFIG-SAFETY GUARD -- run at this file's own LOAD time (Config.lua is a
-- shared_script, loaded in full before any server_scripts file starts
-- executing -- not a load-order gamble), mirroring server/integrations.lua's
-- K9DownDispatch guard exactly. Scoped to ONLY the fields THIS file reads --
-- missingPersonPedModel/lostPropertyPropModel/revealDurationMs are read
-- and validated by client/sarcalls.lua alone (this file never touches
-- them), per this resource's own "validate what you consume" convention.
--
-- CLAMP AND WARN, NOT ASSERT (this pass -- closes a real instance of this
-- task's own NON-NEGOTIABLE: "NEVER a bare assert on a config value"). This
-- was a hard `assert(type(tuning) == 'table', ...)` -- correctly diagnosing
-- a real risk (every field below is read unconditionally once the feature
-- flag is on) but with the wrong remedy: an uncaught error thrown from
-- THIS FILE's own top-level chunk aborts server/sarcalls.lua's load from
-- this line onward -- silently un-registering the playerDropped handler,
-- the tick loop, the requestSarCall callback, and the UNCONDITIONAL
-- abandonSarCall event this file's own header calls a "NO UNBOUNDED TRAP"
-- guarantee -- over an operator leaving Config.SARCalls out of config.lua
-- entirely while flipping Config.Features.SARCalls on by hand. Mirrors
-- server/scenttrail.lua's own identical fix for its "whole table missing"
-- case: substituting an empty table lets every one of the per-field
-- clamp-and-warn resolvers immediately below fall back to its own
-- already-established default, exactly as if an operator had left each
-- field individually blank, and the feature keeps working instead of never
-- registering at all.
-- ======================================================================
if type(tuning) ~= 'table' then
    print(
        '[qbx_k9unit] WARNING: Config.Features.SARCalls is true but Config.SARCalls is missing or not a table -- ' ..
        'using this file\'s own built-in defaults for every field it would have set (minRadius=40.0, ' ..
        'maxRadius=90.0, arrivalRadius=6.0, burningDistance=8.0, hotDistance=20.0, warmDistance=45.0, ' ..
        'pollIntervalMs=2000, maxCallDurationMs=480000, startCooldownMs=600000). Add the settings table back to ' ..
        'config.lua.'
    )
    tuning = {}
end

-- ======================================================================
-- CLAMP AND WARN, NOT ASSERT (this pass -- see server/cooldowns.lua's
-- header ADDENDUM: "does an operator's config.lua edit alone... reach this
-- value? If yes it must be clamped and warned about, never asserted and
-- aborted"). The eight fields below USED TO be eight separate hard
-- `assert`s here -- each one correctly diagnosing a real risk (a bad
-- radius/distance could invert RollSarTarget's ring math or TierForDistance's
-- ordering; a bad duration could busy-poll or never expire a call) but with
-- the wrong remedy: an uncaught error thrown from THIS FILE's own top-level
-- chunk aborts server/sarcalls.lua's load from that line onward -- silently
-- un-registering the playerDropped handler, the tick loop, the
-- requestSarCall callback, and the UNCONDITIONAL abandonSarCall event this
-- file's own header calls a "NO UNBOUNDED TRAP" guarantee, over one
-- operator typo. startCooldownMs (a few lines below) was already migrated to
-- ResolveConfiguredThresholdMs in an earlier pass -- these eight siblings
-- were missed only because none of them feed NewCooldown, not because the
-- risk was any different.
--
-- Two of these eight are RELATIONSHIPS, not independent values -- clamping
-- one field in a related pair/chain without checking the others could
-- silently produce an internally-inconsistent set worse than any single bad
-- number alone (e.g. raising an invalid minRadius up past an operator's
-- own, individually-fine maxRadius would silently invert the ring
-- RollSarTarget rolls inside). When a group's relationship is violated,
-- EVERY field in that group falls back to its own shipped default TOGETHER,
-- never a mix of kept-and-substituted values:
--   GROUP 1: minRadius / maxRadius (maxRadius must stay >= minRadius).
--   GROUP 2: arrivalRadius / burningDistance / hotDistance / warmDistance
--            (TierForDistance below reads this as an ascending-distance,
--            descending-intensity chain -- each must stay strictly greater
--            than the one before it).
-- pollIntervalMs and maxCallDurationMs have no relationship to any other
-- field here, so each is resolved independently through
-- ResolveConfiguredThresholdMs (server/cooldowns.lua) -- both are genuine
-- durations (Wait()/a hard elapsed-time expiry) with no legitimate
-- non-positive meaning, an exact fit for that function's own validity rule.
-- ======================================================================
local function IsPositiveNumber(v)
    return type(v) == 'number' and v == v and v > 0
end

-- GROUP 1: minRadius/maxRadius.
if not (IsPositiveNumber(tuning.minRadius) and IsPositiveNumber(tuning.maxRadius) and tuning.maxRadius >= tuning.minRadius) then
    print(
        ('[qbx_k9unit] Config.SARCalls.minRadius/maxRadius must both be positive numbers with maxRadius >= ' ..
         'minRadius (found minRadius=%s, maxRadius=%s) -- RollSarTarget\'s ring math silently inverts otherwise. ' ..
         'Using the shipped defaults for BOTH fields together (minRadius=40.0, maxRadius=90.0) instead of ' ..
         'clamping just one into an incoherent pair -- find Config.SARCalls.minRadius/maxRadius in config.lua ' ..
         'and fix them together.')
            :format(tostring(tuning.minRadius), tostring(tuning.maxRadius))
    )
    tuning.minRadius, tuning.maxRadius = 40.0, 90.0
end

-- GROUP 2: arrivalRadius/burningDistance/hotDistance/warmDistance.
if not (
    IsPositiveNumber(tuning.arrivalRadius) and IsPositiveNumber(tuning.burningDistance) and
    IsPositiveNumber(tuning.hotDistance) and IsPositiveNumber(tuning.warmDistance) and
    tuning.burningDistance > tuning.arrivalRadius and tuning.hotDistance > tuning.burningDistance and
    tuning.warmDistance > tuning.hotDistance
) then
    print(
        ('[qbx_k9unit] Config.SARCalls.arrivalRadius/burningDistance/hotDistance/warmDistance must all be ' ..
         'positive numbers in strictly ascending order (arrivalRadius < burningDistance < hotDistance < ' ..
         'warmDistance) -- found arrivalRadius=%s, burningDistance=%s, hotDistance=%s, warmDistance=%s. Using ' ..
         'the shipped defaults for ALL FOUR fields together (arrivalRadius=6.0, burningDistance=8.0, ' ..
         'hotDistance=20.0, warmDistance=45.0) instead of clamping just one into an incoherent chain -- find ' ..
         'these four fields in config.lua and fix them together.')
            :format(tostring(tuning.arrivalRadius), tostring(tuning.burningDistance), tostring(tuning.hotDistance), tostring(tuning.warmDistance))
    )
    tuning.arrivalRadius, tuning.burningDistance, tuning.hotDistance, tuning.warmDistance = 6.0, 8.0, 20.0, 45.0
end

-- INDEPENDENT DURATIONS.
tuning.pollIntervalMs = ResolveConfiguredThresholdMs(
    tuning.pollIntervalMs, 2000, 'Config.SARCalls.pollIntervalMs')
tuning.maxCallDurationMs = ResolveConfiguredThresholdMs(
    tuning.maxCallDurationMs, 480000, 'Config.SARCalls.maxCallDurationMs')

-- ======================================================================
-- TWO OFFICERS, ONE CALL (this pass) -- three new fields, same
-- clamp-and-warn discipline as every field above, never a bare assert.
-- joinProximityMeters has no ordering relationship to any other field
-- here (unlike GROUP 1/GROUP 2 above), so it is validated standalone.
-- joinRequestTTLMs/joinRequestCooldownMs are genuine durations with no
-- legitimate non-positive meaning, same as pollIntervalMs/
-- maxCallDurationMs immediately above -- resolved the same way, through
-- the same helper.
-- ======================================================================
if not IsPositiveNumber(tuning.joinProximityMeters) then
    print(
        ('[qbx_k9unit] Config.SARCalls.joinProximityMeters must be a positive number (found: %s). Using the ' ..
         'shipped default of 10.0 instead -- find Config.SARCalls.joinProximityMeters in config.lua and fix it.')
            :format(tostring(tuning.joinProximityMeters))
    )
    tuning.joinProximityMeters = 10.0
end

local function IsPositiveInteger(v)
    return type(v) == 'number' and v == v and v > 0 and v == math.floor(v)
end
if not IsPositiveInteger(tuning.maxMembers) then
    print(
        ('[qbx_k9unit] Config.SARCalls.maxMembers must be a positive whole number (found: %s). Using the shipped ' ..
         'default of 4 instead -- find Config.SARCalls.maxMembers in config.lua and fix it.')
            :format(tostring(tuning.maxMembers))
    )
    tuning.maxMembers = 4
end

tuning.joinRequestTTLMs = ResolveConfiguredThresholdMs(
    tuning.joinRequestTTLMs, 30000, 'Config.SARCalls.joinRequestTTLMs')
tuning.joinRequestCooldownMs = ResolveConfiguredThresholdMs(
    tuning.joinRequestCooldownMs, 1000, 'Config.SARCalls.joinRequestCooldownMs')

-- startCooldownMs is deliberately NOT re-validated here -- NewCooldown's
-- own AssertValidDefaultThreshold below already errors loudly, naming that
-- exact constructor call, the identical reasoning server/integrations.lua's
-- own CONFIG-SAFETY GUARD gives for its own reFireCooldownMs, and
-- server/scenttrail.lua gives for its own startCooldownMs.

--- MOVED to server/events.lua (2026-08-25 cross-file cleanup pass): this
--- was the "deliberate Nth copy" this comment used to defend -- that
--- genuine cross-file cleanup pass it deferred to has now happened. This
--- file's own copy, byte-for-byte identical to the five others that
--- existed alongside it, is now the single shared resource-global
--- implementation in that file. See server/events.lua's header for the
--- full extraction writeup. Every call site below is unchanged: same event
--- names, arguments, order, and firing conditions.

-- Per-CITIZENID request cooldown -- see this file's header "WHY THIS FILE
-- DIFFERS" item 3 for why this is keyed by citizenid rather than source,
-- unlike server/scenttrail.lua's per-source StartHuntCooldown. Constructor
-- default validated by server/cooldowns.lua's own AssertValidDefaultThreshold
-- -- a non-positive Config.SARCalls.startCooldownMs errors loudly at
-- resource start naming this exact call site, rather than silently
-- becoming a permanent lockout (the exact footgun that file's own header
-- documents finding in server/fetch.lua's releaseFetchBall).
-- Clamp-and-warn rather than a raw Config read. This file's own config-safety
-- guard above deliberately covers only the fields it validates by name, and
-- startCooldownMs was not one of them -- so a `startCooldownMs = 0` reached
-- NewCooldown(0) and errored at file-load time, taking the feature with it.
local START_SAR_CALL_COOLDOWN_MS = ResolveConfiguredThresholdMs(
    tuning.startCooldownMs, 600000, 'Config.SARCalls.startCooldownMs')
local StartSarCallCooldown = NewCooldown(START_SAR_CALL_COOLDOWN_MS)
-- Deliberately NOT .RegisterPlayerDropped() -- this cooldown is keyed by
-- citizenid, which OUTLIVES a disconnect/reconnect within the same server
-- uptime. Clearing it on disconnect would let a citizenid bypass the
-- anti-farm floor simply by relogging, defeating the entire reason this
-- cooldown is keyed by citizenid instead of by source in the first place.
--
-- That said, a citizenid who calls ONCE and never plays again (account
-- abandoned, banned, or simply moved on) would otherwise leave a single
-- `store[citizenid] = lastTouchedAtMs` entry in this tracker for the rest
-- of this resource's uptime with nothing to reclaim it -- a real, if slow,
-- unbounded leak QA found live in this file. FIXED via :StartSweep, not
-- :RegisterPlayerDropped -- the anti-farm property above depends entirely
-- on this table surviving a disconnect, so the ONLY safe way to bound its
-- memory is to evict an entry ONLY once it is no longer doing any gating
-- work at all, never on a connection-lifecycle event. The predicate below
-- (`elapsed > threshold * 2`, mirroring server/combat.lua's
-- TakedownTargetCooldown/BiteHoldTargetCooldown sweep predicates for the
-- identical "citizenid/targetNetId-keyed, no connection hook" shape) only
-- ever matches an entry for which IsOnCooldown/Consume would ALREADY
-- unconditionally return "not on cooldown" -- eviction here can never
-- change what any future call to this tracker answers, it only reclaims
-- memory for bookkeeping nothing will ever consult again unless that same
-- citizenid calls again, at which point Touch simply recreates the entry
-- fresh. The x2 margin (not x1) is deliberate slack against this file's
-- own documented GetGameTimer() caveat and normal sweep-vs-touch timing
-- jitter, so a genuinely-still-cooling-down entry can never be swept out
-- from under a citizenid who is one poll away from being allowed again.
local START_SAR_CALL_COOLDOWN_SWEEP_INTERVAL_MS = 60000
StartSarCallCooldown.StartSweep(START_SAR_CALL_COOLDOWN_SWEEP_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (START_SAR_CALL_COOLDOWN_MS * 2)
end)

-- Per-SOURCE join-request rate limit -- purely an anti-UI-harassment
-- throttle on how often ONE source may send requestJoinSarCall, same role
-- (and same source-keyed, RegisterPlayerDropped-cleaned shape) as server/
-- main.lua's LeashRequestCooldown / server/partnership.lua's
-- PartnerRequestCooldown. NOT an anti-farm mechanism -- see "TWO OFFICERS,
-- ONE CALL" (DECISION 3) above for why this feature's real anti-farm floor
-- is StartSarCallCooldown alone, which this tracker neither replaces nor
-- weakens. Safe to clear on disconnect, unlike StartSarCallCooldown: rate-
-- limiting a request is a UI-spam concern only, not a mint-XP concern.
local SarJoinRequestCooldown = NewCooldown(tuning.joinRequestCooldownMs)
SarJoinRequestCooldown.RegisterPlayerDropped()

-- SERVER-ISSUED, monotonically increasing session id -- see this file's
-- header "STALE-SESSION RACE" section for the full writeup. Minted once per
-- call, at the moment ActiveSarCalls[callId] is created below, and never
-- reused -- a plain incrementing counter is sufficient (no per-source
-- scoping needed): every push this file sends already targets a single
-- member `src`, so this id only ever has to disambiguate one member's own
-- calls from each other over time, never one member's id from another's.
local NextSarCallId = 0
local function NewSarCallId()
    NextSarCallId = NextSarCallId + 1
    return NextSarCallId
end

-- ======================================================================
-- ActiveSarCalls[callId] = { citizenid: string, jobName: string?,
--   callType: ('person'|'property'), targetX: number, targetY: number,
--   startedAt: number (GetGameTimer() ms), callId: number,
--   ownerSrc: number, members: { [src] = { citizenid: string,
--   tier: string, joinedAt: number } } }.
--
-- KEYED BY callId, NOT BY SOURCE -- see "TWO OFFICERS, ONE CALL" above
-- (DECISION 2). A source is only ever the right key for something that
-- cannot outlive one connection; a call now can (ownership transfers when
-- its current owner leaves), so the table's own key must be the one thing
-- about a call that never changes for its whole lifetime.
--
-- `citizenid`/`jobName` are captured ONCE, at creation, from whichever
-- citizenid actually paid StartSarCallCooldown to create this call, and
-- NEVER reassigned -- they are who EndSarCall's 'found' branch pays,
-- regardless of who is currently `ownerSrc` or which member's own position
-- actually triggered the find (see DECISION 3).
--
-- `ownerSrc` is the one MUTABLE field: whichever member currently has the
-- authority to accept a new join request. RemoveMemberFromSarCall below is
-- the only place that ever reassigns it.
--
-- `members` always contains at least `ownerSrc` itself (a call with zero
-- members has, by definition, already been removed from this table
-- entirely -- see RemoveMemberFromSarCall). Ephemeral, in-memory only,
-- same as before this pass -- a short-lived session record, not a rate
-- limiter, so a plain table + manual playerDropped cleanup, not a
-- NewCooldown/NewMutex instance, mirroring server/scenttrail.lua's
-- ActiveHunts' own identical reasoning.
local ActiveSarCalls = {}

-- MemberToCallId[src] = callId, for EVERY current member of EVERY active
-- call (owner or joiner alike). The reverse index every entry point below
-- (requestSarCall, requestJoinSarCall/respondJoinSarCall, abandonSarCall,
-- playerDropped) consults to answer "is this source currently part of ANY
-- call" in O(1), without a linear scan of ActiveSarCalls -- and, as a
-- direct consequence, the thing that actually enforces "one citizenid, one
-- call, in either role, at a time" (see "TWO OFFICERS, ONE CALL" above).
-- Plain table, not a NewCooldown/NewMutex instance -- an entry exists for
-- exactly as long as its matching membership does, added and removed in
-- lockstep with `ActiveSarCalls[callId].members[src]` at every single call
-- site that touches either, so there is nothing here for a
-- RegisterPlayerDropped/StartSweep hook to do that RemoveMemberFromSarCall
-- (called from THIS file's own playerDropped handler below) does not
-- already guarantee.
local MemberToCallId = {}

-- Ephemeral pending join requests: PendingSarJoinRequests[targetServerId]
-- = { from = requesterSrc, expiresAt = <GetGameTimer() timestamp> }. Exact
-- same shape, TTL, and single-slot-per-target discipline as server/
-- main.lua's PendingLeashRequests / server/partnership.lua's
-- PendingPartnershipRequests -- see requestJoinSarCall below for the
-- identical anti-clobber rejection those two files already established.
local PendingSarJoinRequests = {}

--- Clears any pending join request naming `src` as either party -- `src` as
--- the pending TARGET (a request aimed AT src, whether or not src has
--- answered it yet) and `src` as the pending REQUESTER (a request src sent,
--- naming someone else, not yet answered). Idempotent -- a harmless no-op
--- in either or both directions if no such entry exists. Shared by
--- RemoveMemberFromSarCall (below -- see that function's own "STALE
--- JOIN-REQUEST FIX" reference) and playerDropped (below), so the two call
--- sites can never drift into two different definitions of "clear a stale
--- pending entry" -- see this file's header "STALE JOIN-REQUEST FIX" for
--- the concrete bug this closes.
--- @param src number
local function ClearPendingSarJoinRequestsFor(src)
    PendingSarJoinRequests[src] = nil -- target-side: a request aimed AT src
    for targetSrc, pending in pairs(PendingSarJoinRequests) do
        if pending.from == src then
            PendingSarJoinRequests[targetSrc] = nil
        end
    end
end

--- Removes `src` from `callId`'s membership -- the ONE path covering both
--- "a member chooses to leave, the call continues for everyone else" and
--- "the member disconnects" alike (`isDisconnect` only controls whether
--- `src` itself is notified/pushed to, since a disconnected source cannot
--- receive either). Idempotent -- a harmless no-op if `src` is not
--- currently a member of `callId` (or `callId` no longer exists at all),
--- covering a genuine double-call the same way EndSarCall below always
--- has. NEVER gated on access/certification/the feature flag -- see this
--- file's header "NO UNBOUNDED TRAP" and "TWO OFFICERS, ONE CALL".
---
--- If `src` was the LAST remaining member, the call ends entirely (reason
--- 'abandoned', unchanged client contract from before this pass). If
--- other members remain and `src` was the current `ownerSrc`, ownership
--- transfers to whichever remaining member joined earliest -- see "TWO
--- OFFICERS, ONE CALL" (DECISION 2) above for why this can never leave a
--- remaining, actively-searching member's call terminated out from under
--- them.
--- @param callId number
--- @param src number
--- @param isDisconnect boolean
local function RemoveMemberFromSarCall(callId, src, isDisconnect)
    -- STALE JOIN-REQUEST FIX (RED-TEAM PASS) -- see this file's header
    -- section of the same name for the full writeup. Unconditional, before
    -- either early-return below: a pending request naming `src`, in either
    -- direction, must never survive `src` leaving whatever call that
    -- request was actually about -- otherwise a LATER accept/decline can
    -- resolve against a call that has since changed entirely.
    ClearPendingSarJoinRequestsFor(src)

    local call = ActiveSarCalls[callId]
    if not call or not call.members[src] then
        MemberToCallId[src] = nil -- defensive: clear a dangling reverse-index entry even if the forward record is already gone/mismatched
        return
    end

    call.members[src] = nil
    MemberToCallId[src] = nil

    if next(call.members) == nil then
        -- Last member out -- the call ends entirely, exactly like the
        -- original single-owner abandon path.
        ActiveSarCalls[callId] = nil
        if not isDisconnect then
            NotifyPlayer(src, locale('sar.call_abandoned'), 'inform')
            TriggerClientEvent('qbx_k9unit:client:sarCallEnded', src, 'abandoned', nil, call.callId)
        end
        return
    end

    if not isDisconnect then
        NotifyPlayer(src, locale('sar.left_call'), 'inform')
        TriggerClientEvent('qbx_k9unit:client:sarCallEnded', src, 'abandoned', nil, call.callId)
    end

    if call.ownerSrc == src then
        local newOwnerSrc, newOwnerJoinedAt
        for memberSrc, state in pairs(call.members) do
            if not newOwnerJoinedAt or state.joinedAt < newOwnerJoinedAt then
                newOwnerSrc, newOwnerJoinedAt = memberSrc, state.joinedAt
            end
        end
        call.ownerSrc = newOwnerSrc
        -- Best-effort courtesy notice only -- the tick loop below needed no
        -- code change at all to keep servicing this call correctly for
        -- every member, transferred owner included; this is purely so a
        -- human knows the call is now theirs to manage (e.g. a future
        -- accept/decline for a NEW join request will show up on their
        -- screen, not the disconnected original owner's).
        NotifyPlayer(newOwnerSrc, locale('sar.ownership_transferred'), 'inform')
    end
end

AddEventHandler('playerDropped', function()
    local src = source

    local callId = MemberToCallId[src]
    if callId then
        RemoveMemberFromSarCall(callId, src, true) -- this now ALSO clears any pending join-request entries naming src, in either direction -- see that function's own "STALE JOIN-REQUEST FIX" comment
    end

    -- Pending join-request cleanup, BOTH directions -- mirrors server/
    -- main.lua's PendingLeashRequests / server/partnership.lua's
    -- PendingPartnershipRequests identical two-directional scan (FiveM
    -- recycles numeric server ids, so an unscanned stale `.from` entry
    -- could otherwise resolve to a different, unrelated player who
    -- reconnects with the same id before this entry's own TTL expires).
    -- Always run, UNCONDITIONALLY, even though RemoveMemberFromSarCall above
    -- already did this same cleanup when `callId` was truthy (harmless,
    -- idempotent overlap in that case) -- this is what still covers a
    -- disconnecting source with NO current call membership at all, e.g. one
    -- whose own requestJoinSarCall was sent but never answered before they
    -- dropped -- RemoveMemberFromSarCall is never reached for that source at
    -- all, since `callId` above is nil for them.
    ClearPendingSarJoinRequestsFor(src)
end)

--- Flat 2D distance -- see this file's header "WHY 2D" section.
--- @param x1 number
--- @param y1 number
--- @param x2 number
--- @param y2 number
--- @return number
local function Distance2D(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

--- Full 3D distance between two live coordinate tables, each read only by
--- `.x`/`.y`/`.z` FIELD ACCESS -- deliberately NOT server/partnership.lua's
--- `#(a - b)` vector-subtraction idiom (that shape needs a real vector
--- metatable behind both operands; this file's own established convention,
--- per Distance2D immediately above, is plain field access on whatever
--- GetEntityCoords returns, which works identically whether that happens
--- to be a real vector3 or a bare `{x=,y=,z=}` table). Used ONLY for the
--- join-proximity check below -- "are these two officers standing near
--- each other," a genuinely different question from RollSarTarget/
--- TierForDistance's own 2D-only hidden-target math (see this file's
--- header "WHY 2D" for why THAT one stays flat); two live officers'
--- own Z really can differ (one on a step, one on a porch) in a way that
--- would produce a wrong answer here if flattened the same way.
--- @param a {x: number, y: number, z: number?}
--- @param b {x: number, y: number, z: number?}
--- @return number
local function Distance3D(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Rolls a random (x, y) between Config.SARCalls.minRadius and .maxRadius
--- of (originX, originY), uniformly by angle and linearly interpolated by
--- radius -- same "a real uniform-by-AREA distribution would need a
--- sqrt(t) bias instead, not done here" honesty server/scenttrail.lua's
--- own RollHuntTarget already states for the identical math: a mild pull
--- toward the outer edge of the ring is a harmless, undisclosed-to-the-
--- player cosmetic bias, not a fairness-relevant value. Unlike that
--- function, this one does NOT re-clamp `maxR < minR` defensively at call
--- time -- this file's own CONFIG-SAFETY GUARD above already guarantees
--- maxRadius >= minRadius at load time (GROUP 1's clamp-and-warn: either the
--- configured pair already satisfies this, or both fields together fall
--- back to the shipped defaults, which do), so that condition is provably
--- unreachable here rather than merely assumed -- no longer via a hard
--- assert, but the guarantee itself is unchanged.
--- @param originX number
--- @param originY number
--- @return number targetX, number targetY
local function RollSarTarget(originX, originY)
    local radius = tuning.minRadius + (tuning.maxRadius - tuning.minRadius) * math.random()
    local angle = math.random() * 2 * math.pi
    return originX + math.cos(angle) * radius, originY + math.sin(angle) * radius
end

--- Resolves a distance into a coarse hint tier -- ascending distance,
--- descending intensity. Never reveals the actual number, only which of
--- four fixed bands it falls in -- see this file's header "WHY THE TARGET
--- COORDINATE NEVER CROSSES THE WIRE".
--- @param distance number
--- @return string tier -- one of 'burning' | 'hot' | 'warm' | 'cold'
local function TierForDistance(distance)
    if distance <= tuning.burningDistance then return 'burning' end
    if distance <= tuning.hotDistance then return 'hot' end
    if distance <= tuning.warmDistance then return 'warm' end
    return 'cold'
end

--- Ends `callId` entirely, for `reason` ('found'|'timeout'), notifying
--- EVERY current member -- not merely one source -- and clearing every
--- member's own MemberToCallId entry so nobody is left believing they are
--- still in a call that no longer exists. Idempotent -- a harmless no-op
--- if `callId` no longer resolves to a live call (covers a genuine
--- double-call, e.g. the tick loop observing 'found' for one member in the
--- same instant a DIFFERENT member's abandonSarCall also fires -- whichever
--- runs first wins, the second is simply a no-op since ActiveSarCalls[callId]
--- is already nil by then). NEVER gated on access or certification -- see
--- this file's header "NO UNBOUNDED TRAP".
---
--- `reason == 'abandoned'` is deliberately NOT handled here any more --
--- see RemoveMemberFromSarCall above, this pass's own single-member leave
--- path (a full call end via a member leaving is just "the last member
--- left", not a distinct case this function needs to know about).
--- @param callId number
--- @param reason string -- 'found' | 'timeout'
--- @param finderSrc number? -- required iff reason == 'found': the ONE member whose own live position triggered this -- see "TWO OFFICERS, ONE CALL" (THE FINDER STILL MATTERS) above
local function EndSarCall(callId, reason, finderSrc)
    local call = ActiveSarCalls[callId]
    if not call then return end
    ActiveSarCalls[callId] = nil
    for memberSrc in pairs(call.members) do
        MemberToCallId[memberSrc] = nil
    end

    if reason == 'found' then
        -- Runtime-existence guard, not a load-order assumption -- see this
        -- file's header FILE-TO-FILE CONTRACT. AwardXP itself re-checks
        -- Config.Features.XPProgression and re-derives the amount from
        -- Config.XP.awards.sarCallCompleted -- this file never computes or
        -- passes an amount. `call.citizenid` -- the ORIGINAL starter, fixed
        -- at creation -- is the ONLY citizenid ever paid here, regardless of
        -- which member `finderSrc` actually is -- see "TWO OFFICERS, ONE
        -- CALL" (DECISION 3) above: a joiner's own citizenid is never
        -- passed to AwardXP for any reason, on any resolution.
        if type(AwardXP) == 'function' then
            AwardXP(call.citizenid, 'sarCallCompleted')
        end
        FireOutboundEvent('qbx_k9unit:events:sarCallCompleted', finderSrc, call.citizenid, call.jobName, call.callType, GetGameTimer() - call.startedAt)
        -- SHARED FOUND MARKER (this pass) -- see this file's header section
        -- of the same name for the full writeup. call.targetX/call.targetY
        -- ride along on EVERY member's own push below, finder and teammate
        -- alike -- safe only because the call has already resolved by this
        -- point (see that header section for exactly why that timing is
        -- what makes this different from "WHY THE TARGET COORDINATE NEVER
        -- CROSSES THE WIRE" above, not a quiet reversal of it).
        for memberSrc in pairs(call.members) do
            if memberSrc == finderSrc then
                NotifyPlayer(memberSrc, call.callType == 'person' and locale('sar.found_person') or locale('sar.found_property'), 'success')
                TriggerClientEvent('qbx_k9unit:client:sarCallEnded', memberSrc, 'found', call.callType, call.callId, call.targetX, call.targetY)
            else
                -- A teammate's own position never crossed arrivalRadius --
                -- reason 'found_by_teammate' resets their state exactly the
                -- same way, and (this pass) still carries the target
                -- coordinates so client/sarcalls.lua can draw its own
                -- shared, non-entity found-marker there -- but this
                -- deliberately never triggers that file's FINDER-ONLY
                -- entity-level reveal (they are not standing anywhere near
                -- the real target -- see "THE FINDER STILL MATTERS" and
                -- "SHARED FOUND MARKER" above).
                NotifyPlayer(memberSrc, locale('sar.found_by_teammate'), 'success')
                TriggerClientEvent('qbx_k9unit:client:sarCallEnded', memberSrc, 'found_by_teammate', nil, call.callId, call.targetX, call.targetY)
            end
        end
    elseif reason == 'timeout' then
        -- No outbound event here on purpose -- see this file's header
        -- EVENT/CALLBACK CONTRACT note on why 'timeout'/'abandoned' never
        -- fire one. `nil` passed explicitly for callType (unused for this
        -- reason) so callId still lands in its own fixed 3rd position --
        -- see this file's header "STALE-SESSION RACE".
        for memberSrc in pairs(call.members) do
            NotifyPlayer(memberSrc, locale('sar.call_timeout'), 'inform')
            TriggerClientEvent('qbx_k9unit:client:sarCallEnded', memberSrc, 'timeout', nil, call.callId)
        end
    end
end

-- ======================================================================
-- ACTIVE TICK LOOP -- see this file's header "WHY THIS FILE DIFFERS" item
-- 1 for why this is an active server-side push rather than
-- server/scenttrail.lua's lazy client-poll shape. Structurally mirrors
-- server/integrations.lua's PollK9Health exactly: one CreateThread, one
-- Wait(Config.SARCalls.pollIntervalMs), one pass over currently-active
-- state per tick. Every distance measurement reads GetEntityCoords(
-- GetPlayerPed(src)) freshly, every tick, from THIS file's own live
-- server-side view -- never a client-supplied position.
-- ======================================================================
CreateThread(function()
    while true do
        Wait(tuning.pollIntervalMs)
        local now = GetGameTimer()

        -- Safe to clear the CURRENT key mid-`pairs` traversal in Lua (well-
        -- defined per the Lua reference manual -- server/cooldowns.lua's
        -- own StartSweep already relies on this exact property) -- EndSarCall
        -- below does exactly that via ActiveSarCalls[callId] = nil.
        for callId, call in pairs(ActiveSarCalls) do
            if (now - call.startedAt) >= tuning.maxCallDurationMs then
                EndSarCall(callId, 'timeout')
            else
                -- TWO OFFICERS, ONE CALL (this pass): each MEMBER is
                -- measured against the target independently -- they are
                -- standing in different places, so they can be in
                -- different hint tiers, and any one of them finding it
                -- ends the call for everyone. `call.members` is mutated
                -- elsewhere ONLY by RemoveMemberFromSarCall/respondJoinSarCall,
                -- never from inside this loop, so iterating it here while
                -- EndSarCall (below) separately clears the OUTER
                -- ActiveSarCalls[callId] entry is safe -- two different
                -- tables, no pairs-mutation conflict.
                for memberSrc, memberState in pairs(call.members) do
                    local ped = GetPlayerPed(memberSrc)
                    if ped ~= 0 then
                        local pos = GetEntityCoords(ped)
                        local distance = Distance2D(pos.x, pos.y, call.targetX, call.targetY)

                        if distance <= tuning.arrivalRadius then
                            EndSarCall(callId, 'found', memberSrc)
                            break -- the call this member table belonged to no longer exists -- stop scanning its other (now-irrelevant) members this tick
                        else
                            local tier = TierForDistance(distance)
                            if tier ~= memberState.tier then
                                memberState.tier = tier
                                TriggerClientEvent('qbx_k9unit:client:sarHintTierChanged', memberSrc, tier, call.callId)
                            end
                        end
                    end
                    -- ped == 0: not actually spawned in right now (still
                    -- loading, or GetPlayers()-adjacent staleness) -- skip
                    -- this member this tick and try again next tick, same
                    -- as server/integrations.lua's PollK9Health does for the
                    -- identical condition. A genuine disconnect is handled
                    -- by the playerDropped handler above, not by anything
                    -- in this loop.
                end
            end
        end
    end
end)

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes (server/findalert.lua's
--- own IsFindAlertsPermittedForCitizenId is a second, independent copy of
--- the same shape) -- that file's own header says to read it before writing
--- a variant, so this is a copy of its shape, not a new one. Step 1 (the
--- global Config.Features.SARCalls flag) is already checked by
--- requestSarCall below, before this function is ever reached:
---   2. an explicit block.SARCalls grant -> DENY
---   3. SARCalls listed in RequireGrant -> ALLOW only with an active
---      feature.SARCalls grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
--- @return ('blocked'|'not_granted')? denyReason -- nil when allowed == true;
---   see SAR_DENY_MESSAGES below for the player-facing copy each maps to,
---   and this file's header "DISCOVERABILITY FIX" for why these two now get
---   different, actionable copy instead of one collapsed 'denied' reason.
local function IsSarCallsPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.SARCalls') == true then
        return false, 'blocked' -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.SARCalls == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        if hasPermissionAvailable and HasPermission(citizenid, 'feature.SARCalls') == true then
            return true
        end
        return false, 'not_granted'
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

-- ======================================================================
-- DISCOVERABILITY FIX (this pass) -- the `reason` field returned to the
-- CALLER of this callback stays exactly 'denied' for every one of these
-- cases below (see the REGRESSION-safety note at each call site) --
-- client/sarcalls.lua's own collapse of every non-'already_active'/
-- non-'cooldown' reason into one generic denial is UNCHANGED, since fixing
-- that properly is a client-side change outside this pass's file
-- ownership. What changes here is a SEPARATE, ADDITIVE NotifyPlayer sent
-- directly from this handler for the cases where the generic client-side
-- copy is actively wrong or unhelpful: 'feature disabled' reads as if it
-- is about the caller personally when it is not, and a block/not_granted
-- denial gave no hint that a per-person grant was even the mechanism in
-- play, let alone which one to ask for or who can grant it. HasK9Access
-- failing and an unresolvable citizenid stay silent (this handler's only
-- side channel) -- see each branch below for why.
-- ======================================================================
local SAR_DENY_MESSAGES = {
    feature_disabled = locale('sar.feature_disabled'),
    blocked          = locale('sar.blocked'),
    not_granted      = locale('sar.not_granted'),
}

lib.callback.register('qbx_k9unit:server:requestSarCall', function(source)
    if not Config.Features.SARCalls then
        -- Global off -- nothing the caller can do, and this must not read
        -- as if it were about them personally (see this file's header
        -- "DISCOVERABILITY FIX").
        NotifyPlayer(source, SAR_DENY_MESSAGES.feature_disabled, 'error')
        return { started = false, reason = 'denied' }
    end
    if not HasK9Access(source) then
        -- Silent, on purpose: server/sarcalls.lua's task is a real K9
        -- ability, and client/sarcalls.lua already gates '/k9sarcall' on
        -- CanShowK9UI() before ever reaching this callback -- a real player
        -- reaching this branch already saw the "you cannot use K9 features"
        -- denial client-side; a modified client bypassing that check is not
        -- owed a second, more detailed explanation server-side.
        return { started = false, reason = 'denied' }
    end

    -- TWO OFFICERS, ONE CALL: one citizenid, one call, in EITHER role
    -- (owner or joiner), at a time -- see this file's header for the full
    -- reasoning. MemberToCallId covers both "already running a call" and
    -- "already joined someone else's", which is why this single check now
    -- replaces the old `ActiveSarCalls[source]` lookup.
    if MemberToCallId[source] then
        return { started = false, reason = 'already_active' }
    end

    -- Resolve citizenid/job BEFORE consuming the cooldown -- a request that
    -- cannot even be attributed to a real citizenid must never spend the
    -- cooldown budget of whichever citizenid it might otherwise have been
    -- charged to. Same idiom server/combat.lua's ValidateCombatRequest
    -- already uses for its own IsHesitating/IsDistracted lookup.
    local player = exports.qbx_core:GetPlayer(source)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    local jobName = player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.name
    if not citizenid then
        return { started = false, reason = 'denied' }
    end

    -- PER-PERSON FEATURE CONTROL -- see IsSarCallsPermittedForCitizenId
    -- above and this file's own header "PER-PERSON FEATURE CONTROL" section.
    -- Checked BEFORE consuming the cooldown, same reasoning as the
    -- citizenid-resolution check immediately above: a denied request must
    -- never spend the cooldown budget it would otherwise have been charged
    -- to. The `reason` field returned to the caller stays the same generic
    -- 'denied' as every other non-cooldown/non-already_active rejection in
    -- this callback (client/sarcalls.lua's own collapse is unchanged -- see
    -- this file's header "DISCOVERABILITY FIX"), but a blocked/not_granted
    -- denial now ALSO gets a direct, distinct NotifyPlayer naming which of
    -- the two it is -- collapsing them into one message would leave a
    -- blocked handler unable to tell "nothing to ask for" apart from
    -- "ask high command for this specific grant".
    local citizenPermitted, denyReason = IsSarCallsPermittedForCitizenId(citizenid)
    if not citizenPermitted then
        NotifyPlayer(source, SAR_DENY_MESSAGES[denyReason], 'error')
        return { started = false, reason = 'denied' }
    end

    if not StartSarCallCooldown.Consume(citizenid) then
        return { started = false, reason = 'cooldown' }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { started = false, reason = 'denied' } end -- defensive: no live ped to resolve a starting position from

    local coords = GetEntityCoords(ped)
    local targetX, targetY = RollSarTarget(coords.x, coords.y)
    local callType = math.random() < 0.5 and 'person' or 'property'
    local initialTier = TierForDistance(Distance2D(coords.x, coords.y, targetX, targetY))
    local callId = NewSarCallId()

    ActiveSarCalls[callId] = {
        citizenid = citizenid, -- FIXED for this call's whole lifetime -- see "TWO OFFICERS, ONE CALL" (DECISION 2/3)
        jobName = jobName,
        callType = callType,
        targetX = targetX,
        targetY = targetY,
        startedAt = GetGameTimer(),
        callId = callId,
        ownerSrc = source, -- MUTABLE -- see "TWO OFFICERS, ONE CALL" (DECISION 2)
        members = {
            [source] = { citizenid = citizenid, tier = initialTier, joinedAt = GetGameTimer() },
        },
    }
    MemberToCallId[source] = callId

    FireOutboundEvent('qbx_k9unit:events:sarCallStarted', source, citizenid, jobName, callType)
    NotifyPlayer(source, locale('sar.call_started'), 'inform')
    -- Immediate first hint -- the tick loop above only pushes on a CHANGE
    -- from the previously observed tier, so without this the caller would
    -- otherwise hear/see nothing until the first tick that happens to cross
    -- a tier boundary, even if the roll already landed inside one.
    TriggerClientEvent('qbx_k9unit:client:sarHintTierChanged', source, initialTier, callId)

    return { started = true, callId = callId }
end)

-- ======================================================================
-- TWO OFFICERS, ONE CALL -- the join consent handshake. See this file's
-- header for the full design (DECISION 1). Mirrors server/main.lua's
-- requestLeashAttach/respondLeashAttach and server/partnership.lua's
-- requestPartnerUp/respondPartnerUp almost line-for-line -- read either
-- pair first; this is not a fourth, independently-invented shape.
-- ======================================================================

--- @param requesterSrc number -- the would-be joiner
--- @param targetSrc number -- the alleged call owner
--- @return boolean ok
--- @return number? callId
--- @return string? reason -- 'feature_disabled' | 'denied' (silent) | 'invalid_target' | 'already_active' | 'too_far' | 'call_full' | 'blocked' | 'not_granted'
--- @return string? requesterCitizenid
local function CheckSarJoinEligibility(requesterSrc, targetSrc)
    if not Config.Features.SARCalls then
        return false, nil, 'feature_disabled'
    end

    if type(requesterSrc) ~= 'number' or type(targetSrc) ~= 'number' or requesterSrc == targetSrc then
        return false, nil, 'invalid_target'
    end

    -- Silent, on purpose -- same "already saw the client-side denial"
    -- reasoning as requestSarCall's own HasK9Access branch above.
    if not HasK9Access(requesterSrc) then
        return false, nil, 'denied'
    end

    local requesterPed = GetPlayerPed(requesterSrc)
    local targetPed = GetPlayerPed(targetSrc)
    if requesterPed == 0 or targetPed == 0 then
        return false, nil, 'denied' -- one side has no live ped to resolve a position from -- same silent posture as requestSarCall's own no-live-ped branch
    end

    local requesterPlayer = exports.qbx_core:GetPlayer(requesterSrc)
    local requesterCitizenid = requesterPlayer and requesterPlayer.PlayerData and requesterPlayer.PlayerData.citizenid
    if not requesterCitizenid then
        return false, nil, 'denied'
    end

    -- ONE CITIZENID, ONE CALL, IN EITHER ROLE -- see this file's header.
    if MemberToCallId[requesterSrc] then
        return false, nil, 'already_active'
    end

    -- JOIN-ELIGIBILITY CHECK ORDERING FIX (RED-TEAM PASS) -- see this
    -- file's header section of the same name for the full writeup. THIS
    -- CHECK MUST RUN BEFORE OWNERSHIP RESOLUTION BELOW, not after: it used
    -- to run second, which let anyone with genuine K9 access distinguish
    -- "that officer has no call" (invalid_target) from "they do, but I'm
    -- too far" (too_far) for an arbitrary online target from anywhere on
    -- the map -- a real, if narrow, leak of "is this named officer
    -- currently running a search" to a non-member. Distance3D only needs
    -- targetSrc's own live position (already resolved above as targetPed),
    -- never targetCall -- moving this ahead of ownership resolution costs
    -- nothing and collapses that leak into one honest 'too_far' for anyone
    -- not actually close enough to have ever been a legitimate joiner.
    local dist = Distance3D(GetEntityCoords(requesterPed), GetEntityCoords(targetPed))
    if dist > tuning.joinProximityMeters then
        return false, nil, 'too_far'
    end

    -- The target must be the CURRENT owner of a live call -- a request
    -- naming a mere participant (not the owner) is rejected the same way
    -- as naming someone with no call at all; only the owner is the accept
    -- authority for a NEW join (see "TWO OFFICERS, ONE CALL" DECISION 1).
    -- Reached only once the requester is already confirmed near enough to
    -- targetSrc (see the ordering fix immediately above) -- a genuinely
    -- NEARBY requester targeting a non-owner/no-call target still gets this
    -- honest 'invalid_target' answer, unchanged from before this pass.
    local targetCallId = MemberToCallId[targetSrc]
    local targetCall = targetCallId and ActiveSarCalls[targetCallId]
    if not targetCall or targetCall.ownerSrc ~= targetSrc then
        return false, nil, 'invalid_target'
    end

    local memberCount = 0
    for _ in pairs(targetCall.members) do memberCount = memberCount + 1 end
    if memberCount >= tuning.maxMembers then
        return false, nil, 'call_full'
    end

    -- PER-PERSON FEATURE CONTROL -- joining is using this feature exactly
    -- as much as starting one is, so the same per-citizenid grant/block
    -- applies to the REQUESTER. Checked last (cheapest/most-defensive
    -- checks first, matching requestSarCall's own established discipline).
    local permitted, denyReason = IsSarCallsPermittedForCitizenId(requesterCitizenid)
    if not permitted then
        return false, nil, denyReason
    end

    return true, targetCallId, nil, requesterCitizenid
end

local SAR_JOIN_REJECT_MESSAGES = {
    feature_disabled = locale('sar.feature_disabled'),
    already_active   = locale('sar.already_active'),
    invalid_target   = locale('sar.join_invalid_target'),
    too_far          = locale('sar.join_too_far'),
    call_full        = locale('sar.call_full'),
    blocked          = locale('sar.blocked'),
    not_granted      = locale('sar.not_granted'),
}
--- @param reason string?
--- @return string? -- nil for the silent 'denied' reason (and any unmapped reason), same posture as requestSarCall's own silent branches
local function SarJoinRejectReasonMessage(reason)
    return reason and SAR_JOIN_REJECT_MESSAGES[reason] or nil
end

--- Step 1 of the join consent handshake: the would-be joiner asks. Does
--- NOT add anyone to the call -- only relays a prompt if the request
--- itself is currently valid.
--- @param targetServerId number
RegisterNetEvent('qbx_k9unit:server:requestJoinSarCall', function(targetServerId)
    local src = source

    if type(targetServerId) ~= 'number' then
        NotifyPlayer(src, SAR_JOIN_REJECT_MESSAGES.invalid_target, 'error')
        return
    end

    local ok, _, reason = CheckSarJoinEligibility(src, targetServerId)
    if not ok then
        local msg = SarJoinRejectReasonMessage(reason)
        if msg then NotifyPlayer(src, msg, 'error') end
        return
    end

    -- Single-slot-per-target anti-clobber, identical to server/main.lua's
    -- requestLeashAttach / server/partnership.lua's requestPartnerUp: a
    -- second requester targeting the SAME owner while one request is
    -- already live is rejected outright, never silently overwritten.
    local existingPending = PendingSarJoinRequests[targetServerId]
    if existingPending and GetGameTimer() <= existingPending.expiresAt then
        NotifyPlayer(src, locale('sar.join_pending_request_exists'), 'error')
        return
    end

    if not SarJoinRequestCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches this resource's leash/partnership-request convention)
    end

    PendingSarJoinRequests[targetServerId] = { from = src, expiresAt = GetGameTimer() + tuning.joinRequestTTLMs }

    TriggerClientEvent('qbx_k9unit:client:sarJoinRequest', targetServerId, src)
    NotifyPlayer(src, locale('sar.join_request_sent'), 'inform')
end)

--- Step 2 of the join consent handshake: the call OWNER's response.
--- Mirrors server/partnership.lua's respondPartnerUp's exact
--- validate-before-notify discipline: the pending request is verified
--- genuine (matching initiator + unexpired) BEFORE any
--- TriggerClientEvent/NotifyPlayer referencing the client-supplied
--- `fromServerId` fires.
--- @param fromServerId number
--- @param accepted boolean
RegisterNetEvent('qbx_k9unit:server:respondJoinSarCall', function(fromServerId, accepted)
    local src = source -- the call owner, responding

    if type(fromServerId) ~= 'number' then return end

    local pending = PendingSarJoinRequests[src]
    local verifiedMatch = pending ~= nil and pending.from == fromServerId

    if not verifiedMatch or GetGameTimer() > pending.expiresAt then
        PendingSarJoinRequests[src] = nil -- drop a stale/expired entry, if any
        NotifyPlayer(src, locale('sar.join_request_no_longer_valid_self'), 'error')
        if verifiedMatch then
            NotifyPlayer(fromServerId, locale('sar.join_request_no_longer_valid_initiator'), 'error')
        end
        return
    end

    PendingSarJoinRequests[src] = nil -- consumed either way, accept or decline, now that it's confirmed genuine

    if not accepted then
        NotifyPlayer(fromServerId, locale('sar.join_request_declined'), 'inform')
        return
    end

    -- RE-VALIDATE -- do not trust that nothing changed since the request
    -- was sent (classic TOCTOU: either party could have disconnected,
    -- moved out of range, joined/started a different call, lost access,
    -- or the call itself could have ended entirely, in the meantime). No
    -- mutex needed here -- see this file's header (DECISION 1): adding a
    -- member below is a single synchronous in-memory write, with no
    -- yielding call between this check and that write for a second accept
    -- to race into.
    local ok, callId, reason, joinerCitizenid = CheckSarJoinEligibility(fromServerId, src)
    if not ok then
        local msg = SarJoinRejectReasonMessage(reason)
        if msg then
            NotifyPlayer(fromServerId, msg, 'error')
            NotifyPlayer(src, msg, 'error')
        end
        return
    end

    local call = ActiveSarCalls[callId]
    local joinerPed = GetPlayerPed(fromServerId)
    local joinerPos = GetEntityCoords(joinerPed)
    local initialTier = TierForDistance(Distance2D(joinerPos.x, joinerPos.y, call.targetX, call.targetY))

    call.members[fromServerId] = { citizenid = joinerCitizenid, tier = initialTier, joinedAt = GetGameTimer() }
    MemberToCallId[fromServerId] = callId

    NotifyPlayer(fromServerId, locale('sar.joined_call'), 'success')
    NotifyPlayer(src, locale('sar.member_joined'), 'inform')
    -- Initial tier bundled into ONE push (sarCallJoined) rather than a
    -- separate sarHintTierChanged -- see client/sarcalls.lua's own header
    -- for why: it lets the joiner's client activate its local state AND
    -- show the first hint atomically, with no dependency on which of two
    -- separate network messages happens to arrive first.
    TriggerClientEvent('qbx_k9unit:client:sarCallJoined', fromServerId, callId, initialTier)
end)

--- UNCONDITIONAL -- see this file's header "NO UNBOUNDED TRAP". Never
--- checks Config.Features.SARCalls or HasK9Access on purpose. Covers
--- EVERY member leaving, owner or joiner alike -- see
--- RemoveMemberFromSarCall's own doc comment for exactly what leaving
--- means when other members remain.
RegisterNetEvent('qbx_k9unit:server:abandonSarCall', function()
    local src = source
    local callId = MemberToCallId[src]
    if not callId then return end -- no-op: this source is not currently part of any call
    RemoveMemberFromSarCall(callId, src, false)
end)
