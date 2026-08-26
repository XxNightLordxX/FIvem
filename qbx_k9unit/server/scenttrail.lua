--[[
    qbx_k9unit/server/scenttrail.lua

    Server half of "Follow your nose" (K9_IDEAS.md §2) -- client/scenttrail.lua's
    own header carries the full feature writeup (design rationale, why no
    marker/blip/coordinate is ever sent to the client, the omitted
    screen-tint layer, native verification). This file owns the one thing
    that must never live client-side: WHERE the hidden spot actually is.

    ======================================================================
    WHY THE COORDINATE NEVER LEAVES THIS FILE:
    Unlike client/tracking.lua's Scent/Blood/Gunpowder trails (which hand
    the resolved coordinate to the client so it can render explicit ground
    markers -- that IS the feature), this one's entire design point is that
    the K9 is never told where the spot is (K9_IDEAS.md §2's explicit
    "you don't get told where the thing is... you're guided toward it"
    framing). The ONLY thing `pollScentHunt` below ever answers is "how far
    is the caller's OWN live position from the target, right now" -- never
    the target's coordinate, never the caller's own bearing/direction to
    it. A modified client can still, in principle, triangulate the hidden
    point by walking a line and comparing successive distance answers --
    that is not a bug, it is the entire intended "hot/cold" mechanic
    (real players do exactly this, on purpose); what this design closes is
    a modified client reading the raw answer off the wire once and jumping
    straight to it, which coordinate-revealing tracking already accepts as
    a non-goal for itself (client/tracking.lua's own trails ARE fully
    revealed by design) but this feature explicitly does not want.

    ======================================================================
    WHY 2D (HORIZONTAL) DISTANCE ONLY, NOT 3D:
    FXServer has no renderer and no loaded world collision -- there is no
    reliable server-side "what is the ground height at this X/Y" query the
    way client/tracking.lua's GetWaterHeightNoWaves-style natives exist
    client-side (GetGroundZFor_3dCoord and its relatives are CLIENT-side
    natives, gated on streamed-in collision, per this resource's own
    established "verify before trusting" posture -- not independently
    re-verified this pass since this file deliberately avoids needing any
    such native at all, by design, rather than reaching for one and hoping
    it resolves server-side). The hidden target's Z is therefore never
    computed or stored at all -- RollHuntTarget below only ever produces an
    (x, y) pair, and distance is measured ignoring Z entirely (a flat
    dx/dy/sqrt, not a vector subtraction). DISCLOSED LIMITATION: a hunt area
    with real vertical separation (a target one floor up in a multi-story
    building, a cliff edge) will read as closer than it plays -- acceptable
    for a v1 whose stated area is "somewhere in this yard/house" at ground
    level (K9_IDEAS.md §2's own framing), not claimed to handle every
    possible terrain shape.

    ======================================================================
    THE XP DECISION (read this before "fixing" a missing AwardXP call):
    THIS FEATURE MINTS ZERO XP, DELIBERATELY. This codebase has already had
    to close eight XP farms, several compounding across mechanics nobody
    had summed (server/progression.lua's own header table), and
    server/tracking.lua's own trackSourceResolved award needed THREE
    separate follow-up hardening passes (a minimum real-travel distance, a
    one-ticket-per-logged-event rule, a real-elapsed-time-vs-distance floor,
    and finally a per-source mint-cooldown) before a structurally similar
    "resolve a source, then arrive near it" shape was judged safe to pay
    for. This feature has the SAME shape (resolve, then close distance,
    then arrive) with an even CHEAPER entry cost than any of tracking's
    three trail types: no logged event of any kind is required first (no
    drop, no damage, no gunfire) -- a hunt can be started, and therefore
    completed, purely by typing a command, with only Config.ScentTrailHunt.
    startCooldownMs standing between one completion and the next. Reaching
    tracking.lua's own accepted safety bar for this shape would mean
    re-deriving essentially all of that same anti-farm machinery from
    scratch for a brand-new, unreviewed feature in the same pass that
    introduces it -- judged not worth doing speculatively.

    ADDITIONAL XP/HR CEILING THIS FEATURE MAKES REACHABLE: 0. AwardXP is
    never called anywhere in this file or client/scenttrail.lua, so this
    feature cannot mint against server/progression.lua's shared
    3,600 XP/hr cross-mechanic budget (XP_MINT_BUDGET_CAP_XP/
    XP_MINT_BUDGET_WINDOW_MS) at all -- the ceiling that budget already
    enforces for every OTHER mechanic is completely unaffected by this
    feature existing. This is why this pass is safe to ship without a
    matching anti-farm hardening pass of its own: there is nothing to farm.
    If a future pass wants to pay XP for this (a legitimate thing to want --
    a full hunt is real, sustained gameplay, arguably more effortful than a
    single search click), it must route through AwardXP with a config-owned
    actionKey (never AwardXPDirect) and separately re-derive tracking.lua's
    full anti-farm stack for this shape (minimum real-travel distance
    between a hunt's start position and its target, a real-elapsed-time
    floor scaled to that distance, and a per-source mint cooldown) before
    shipping -- not assumed safe by analogy alone.

    ======================================================================
    EVENT/CALLBACK CONTRACT -- see client/scenttrail.lua's own header for
    the client-side half of this same contract, restated here from the
    server's point of view:

    1. 'qbx_k9unit:server:startScentHunt' (source) -> { started: boolean,
       reason: ('already_active'|'cooldown'|'denied')?, huntId: number?
       [present iff started == true -- see "STALE-SESSION RACE" below] }
       [lib.callback]
       Re-validates Config.Features.ScentTrailHunt and HasK9Access(source)
       regardless of client UI state (reason = 'denied' collapses both, per
       this resource's "don't invent a distinction the server doesn't give
       data for" precedent, client/tracking.lua's own findTrackableSource).
       Resolves the CALLER'S OWN live server-side position
       (GetEntityCoords(GetPlayerPed(source))) as the origin to roll a
       target near -- NEVER a client-supplied coordinate. Rejects (reason =
       'already_active') if this source already has an unfinished hunt --
       a hunt marked found always self-clears immediately (see
       CompleteHunt()'s own TriggerServerEvent('...stopScentHunt') call,
       client/scenttrail.lua) so a completed hunt never lingers to block a
       fresh one this way; the other things that clear one are this file's
       own maxHuntDurationMs check (now enforced BOTH lazily inside
       pollScentHunt below AND unconditionally by the sweep thread near the
       end of this file -- see "SESSION HYGIENE" below for why the lazy
       check alone was not enough), pollScentHunt's own access/feature-loss
       cleanup (same section), or the player disconnecting.
    2. 'qbx_k9unit:server:pollScentHunt' (source) -> { active: boolean,
       distance: number?, found: boolean?, expired: boolean? } [lib.callback]
       Re-validates access on EVERY call (a QUERY, not a termination -- see
       this resource's established gating split, e.g. client/radial.lua's
       own extensive Detach/Release/Recall-vs-Start*/Track* commentary).
       Rate-limited per source by POLL_RATE_FLOOR_MS below, independent of
       whatever Config.ScentTrailHunt.pollIntervalMs the operator configures
       for the CLIENT's own cadence -- a defensive floor against a modified
       client polling faster than intended, not the feature's real pacing
       control. IMPORTANT, see "SESSION HYGIENE" below: when either
       re-validation fails, this callback now ALSO clears ActiveHunts[source]
       before answering `{ active = false }` -- this is cleanup triggered BY
       a failed gate check, never cleanup GATED ON a check passing (the
       standing "gate the start, never the stop" rule is not violated by
       this: the gate here decides what to report, and reporting "inactive"
       while leaving a real record behind would itself be the bug).
    3. 'qbx_k9unit:server:stopScentHunt' (source) [RegisterNetEvent] --
       UNCONDITIONAL. Never checks Config.Features.ScentTrailHunt or
       HasK9Access -- an unconditional `ActiveHunts[source] = nil`, so it
       is always safe to call (including when nothing is active, or when
       the feature was disabled/access was revoked after a hunt started).
       See this resource's standing "no unbounded trap" requirement,
       already applied identically to e.g. server/recall.lua's
       requestRecall and server/main.lua's detachLeash handlers.
    4. 'qbx_k9unit:client:scentHuntFound' (huntId: number) (source's own
       client only, never broadcast) [TriggerClientEvent, THIS FILE only
       ever SENDS this] -- fired the first time a given hunt's distance is
       observed to be at/under Config.ScentTrailHunt.arrivalRadius (guarded
       by `hunt.alertSent`, fired exactly once per hunt). A low-latency nudge
       only -- client/scenttrail.lua's own poll loop independently observes
       `result.found` from THIS SAME callback's return value regardless, so
       a dropped push is not a stuck-forever failure mode for the caller
       that triggered it. `huntId` added -- see "STALE-SESSION RACE" below.

    Automatic path: a background sweep thread (see "SESSION HYGIENE" below)
    and a `playerDropped` handler. Every OTHER code path in this file runs in
    direct response to one of the three named calls above.
    ======================================================================

    SESSION HYGIENE -- FIXED THIS PASS (a real defect, of the exact class
    QA's own repro named: "a client stopping without ending its hunt left a
    live server record, and the server refuses a new hunt while one is
    active, so the player was locked out of ever starting another"). This
    file used to claim (see the paragraph this section replaces) that no
    sweep thread was needed because "a source that starts a hunt, then never
    polls AND never disconnects... cannot happen from this file's own
    client." That reasoning MISSED A REAL CASE: pollScentHunt's own two
    access-re-validation checks (Config.Features.ScentTrailHunt off,
    HasK9Access(source) false) used to return `{ active = false }` WITHOUT
    touching ActiveHunts[source] at all. client/scenttrail.lua's own poll
    loop treats ANY `{ active = false }` response as "this hunt is over" --
    it sets `huntActive = false` and stops polling, WITHOUT sending
    stopScentHunt (that branch is not treated as an abandon, since from the
    client's point of view nothing needs telling: the server just said the
    hunt isn't active). So the moment a K9's access was revoked mid-hunt
    (certification lapse) or Config.Features.ScentTrailHunt was toggled off
    mid-hunt, the client stopped polling for good, while ActiveHunts[source]
    silently lived on forever -- not cleared by any lazy check (nothing polls
    it again to trigger one), not cleared by playerDropped (the player never
    disconnected). The very next legitimate '/k9nosehunt' from that same
    source -- even long after access was restored -- was rejected with
    reason = 'already_active' permanently, for the rest of this resource's
    uptime or until that player happened to disconnect.

    THE FIX, two independent layers, matching this resource's own "layered
    checks over a single point of failure" convention:
      1. pollScentHunt below now clears ActiveHunts[source] itself, in the
         SAME branch that fails Config.Features.ScentTrailHunt/HasK9Access,
         before answering `{ active = false }`. This is NOT "gating cleanup
         on a check" (forbidden by this resource's standing rule) -- it is
         the opposite: this callback is about to tell the client the hunt is
         over, so it makes that true server-side in the same breath, rather
         than lying by omission and leaving an orphaned record behind. The
         query's own re-validation is unchanged; only its side effect on a
         failure is new.
      2. A genuine, unconditional sweep thread (CreateThread below, near the
         end of this file) now re-checks EVERY entry in ActiveHunts against
         Config.ScentTrailHunt.maxHuntDurationMs on its own fixed interval,
         independent of whether anyone ever polls again -- mirroring
         server/scentlineup.lua's own phase-expiry sweep and
         server/sarcalls.lua's own tick-loop timeout check, both of which
         already do not depend on the client for their own expiry. This is a
         backstop for every OTHER way a client could stop polling without
         disconnecting that this file cannot enumerate in advance (a client
         script error outside the pcall'd callback.await, a third-party
         resource restarting just this resource's client copy in a way that
         does not reach client/scenttrail.lua's own onResourceStop handler,
         etc.) -- belt-and-suspenders with fix 1 above, not a replacement for
         it: fix 1 closes the specific, now-understood access/feature-loss
         case immediately (no need to wait up to SWEEP_INTERVAL_MS); fix 2
         closes every case fix 1 does not know to look for.
    NEITHER fix touches a termination path's own gating -- stopScentHunt
    remains exactly as unconditional as it already was (see item 3 above);
    both fixes only ever make a session END sooner/more reliably, never make
    ending one harder or conditional on anything new.
    ======================================================================

    PER-PERSON FEATURE CONTROL -- ADDED A LATER PASS (this pass found and
    closed the gap; not present when this file was first written).
    startScentHunt below used to check only Config.Features.ScentTrailHunt
    and HasK9Access(source) -- config.lua's own
    Config.FeatureControl.RequireGrant.ScentTrailHunt entry (already
    present, with its own comment explaining it exists so high command can
    phase the hunt in per person, e.g. reserve it for K9s who finished
    search training) had ZERO effect: a citizenid with an active
    block.ScentTrailHunt row could still start a hunt, and one with no
    feature.ScentTrailHunt grant could still start one too, while
    RequireGrant.ScentTrailHunt was true. Fixed by copying
    server/pursuitsprint.lua's own IsPursuitSprintPermittedForCitizenId
    shape verbatim (see IsScentTrailHuntPermittedForCitizenId below) --
    pursuitsprint.lua's own header says to read it before writing another
    variant, so this is a copy, not a new one.

    GATED ON THE START PATH ONLY, deliberately, mirroring
    server/scentlineup.lua's own established precedent (that file's
    CanUseScentLineup() is likewise consulted only at its one entry point,
    /k9lineup, never at its continuation command /k9lineuppick or its
    unconditional /k9lineupcancel): a hunt, once legitimately started, is a
    single already-authorized session, not a repeated re-grantable action --
    pollScentHunt is a read-only QUERY against that already-decided session
    (same "re-validates Config.Features.ScentTrailHunt/HasK9Access on EVERY
    call because it is a query, not a termination" reasoning this file's
    own EVENT/CALLBACK CONTRACT item 2 already gives ITSELF, which this
    pass does not extend to the per-person grant/block -- a query is not
    where "does this person's feature act" is decided, the start is), and
    stopScentHunt MUST remain unconditional regardless (see this file's own
    "NO UNBOUNDED TRAP" citation in EVENT/CALLBACK CONTRACT item 3 -- a
    handler whose grant is revoked or who is freshly blocked mid-hunt must
    still be able to stop it; gating cleanup on this check would be exactly
    the trap that rule exists to forbid).
    ======================================================================

    STALE-SESSION RACE -- ADDED A LATER PASS (found by a client-side sweep;
    not present when this file was first written). See client/scenttrail.lua's
    own header for the full client-side writeup, and server/sarcalls.lua's
    own identically-shaped section for the sibling feature this fix mirrors
    (both share the same underlying gap and the same fix shape, deliberately
    -- one pattern, not two). Restated here from this file's point of view
    because minting the id is this file's own job:

    THE BUG: client/scenttrail.lua's `qbx_k9unit:client:scentHuntFound`
    handler used to check only `if not huntActive then return end`, with no
    way to tell WHICH hunt a given push belonged to. A stale, delayed
    'found' push for a hunt the player already stopped or completed could
    arrive after a brand-new hunt had already started (huntActive true
    again, for the new hunt) and would be accepted as if it belonged to
    that new hunt, ending it early -- the dog sits and barks on a hunt that
    was never actually solved.

    THE FIX: this file now mints a small, monotonically increasing,
    SERVER-ISSUED hunt id (NewHuntId below) once per hunt, the moment
    ActiveHunts[source] is created -- never client-generated, for the same
    "could be spoofed or duplicated" reason server/sarcalls.lua's own
    NewSarCallId gives. It rides along on startScentHunt's own `huntId`
    return field and on the scentHuntFound push below.
    client/scenttrail.lua stores the id from its own successful start and
    drops any scentHuntFound push whose id does not match its own currently
    tracked one -- see that file's own IsForCurrentHunt for the exact
    matching rule, including the deliberate "a push with no id at all is
    always accepted, never silently dropped" decision.

    pollScentHunt's OWN return value deliberately does NOT gain a huntId --
    unlike the pushed scentHuntFound event, a poll response is not
    unsolicited: client/scenttrail.lua's own poll loop already re-checks its
    own `huntGeneration` immediately after every lib.callback.await returns,
    before ever looking at `result.found`, which already closes the
    identical staleness window for that one specific channel without
    needing an id at all (see that file's own EnsureHuntPollThreadRunning
    comment). Adding an unused field there would be surface with no
    corresponding gap to close.

    NOT A TERMINATION-PATH CHANGE: stopScentHunt below remains exactly as
    unconditional as it already was (see "NO UNBOUNDED TRAP" in its own
    EVENT/CALLBACK CONTRACT entry above) -- it takes no huntId, checks none,
    and this fix adds nothing it needs. A client holding a stale, wrong, or
    nil hunt id, for any reason, can always still call stopScentHunt and
    have this file's own ActiveHunts[source] entry cleared -- the id
    mechanism only ever decides whether the CLIENT acts on an incoming
    scentHuntFound push, never whether this file accepts a termination
    request.

    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls `HasK9Access(source)` (server/certifications.lua), reused, never
      re-derived -- that file's own "single source of truth" rule.
    - Calls `NewCooldown` (server/cooldowns.lua) at this file's own
      file-load time -- HARD load-order requirement: this file must load
      AFTER server/cooldowns.lua, mirroring every other server file in this
      resource with the same requirement (see fxmanifest.lua's own comments
      on server/tracking.lua/server/search.lua/server/defense.lua for the
      identical precedent).
    - Calls `exports.qbx_core:GetPlayer(source).PlayerData.citizenid`
      (ADDED this pass, for the per-person feature-control check above only
      -- see "WHY exports.qbx_core... DIRECTLY" in server/findalert.lua's
      own header for the resource-wide convention this matches) and
      `HasPermission(citizenid, key)` (server/permissions.lua), the latter
      behind a `type(HasPermission) == 'function'` soft-dependency guard,
      same as every other RequireGrant-consuming file in this resource.
    - Exposes NO resource-global functions. ActiveHunts is this file's own
      private state; nothing outside this file (including
      client/scenttrail.lua) ever reads it directly.
    - Does NOT read or write anything in server/tracking.lua's TrackableLog
      or client/tracking.lua's trackingState -- structurally unrelated
      systems that happen to share a "K9 walks toward a resolved point"
      shape. No shared state, no coupling either direction.
    - Does NOT call AwardXP, AwardXPDirect, or any progression.lua global --
      see this file's header "THE XP DECISION" above.
    - Natives used: GetEntityCoords/GetPlayerPed/GetGameTimer, all already
      allowlisted in the repo-root .luacheckrc read_globals list from this
      resource's existing usage elsewhere -- verification method: no new
      native surface was introduced, so no new native-decl/hash-database
      lookup was required for this file. math.random/math.sqrt/math.pi/
      math.cos/math.sin are the standard Lua 5.4 math library, not FiveM
      natives. `exports`/`HasPermission` above are resource
      exports/globals, not natives, and are listed separately.
]]

local ScentHuntConfig = Config.ScentTrailHunt or {}

-- ======================================================================
-- CONFIG-SAFETY: CLAMP AND WARN, never assert-and-abort (server/
-- cooldowns.lua's header ADDENDUM: an uncaught error thrown from this
-- file's own top-level chunk would abort its load from that line onward,
-- silently un-registering startScentHunt/pollScentHunt AND the
-- UNCONDITIONAL stopScentHunt event this file's own EVENT/CALLBACK CONTRACT
-- item 3 calls a "no unbounded trap" guarantee). minRadius/maxRadius/
-- arrivalRadius/maxHuntDurationMs below used to be read with a bare
-- `ScentHuntConfig.X or <default>` idiom at each individual use site --
-- exactly this resource's own documented footgun (that same header: `0 or
-- 500` evaluates to `0` in Lua, never the fallback, since 0 is truthy) --
-- an operator setting any of these four fields to 0/negative/NaN would
-- silently reach RollHuntTarget/pollScentHunt as a real, accepted, wrong
-- value instead of falling back to a safe default. server/sarcalls.lua's
-- own identically-shaped config block (minRadius/maxRadius/arrivalRadius/
-- burningDistance/hotDistance/warmDistance) already resolves this exact
-- class of field this same way -- this is that same treatment applied to
-- this file's own sibling fields, a gap left open when that pattern was
-- established elsewhere but never brought back to this file.
-- ======================================================================
local function IsPositiveNumber(v)
    return type(v) == 'number' and v == v and v > 0
end

-- GROUP 1: minRadius/maxRadius (maxRadius must stay >= minRadius) -- kept as
-- a related pair, same reasoning as server/sarcalls.lua's own GROUP 1:
-- clamping one half of an inverted/invalid pair without the other could
-- silently produce an internally-inconsistent range worse than either bad
-- value alone.
if not (IsPositiveNumber(ScentHuntConfig.minRadius) and IsPositiveNumber(ScentHuntConfig.maxRadius)
    and ScentHuntConfig.maxRadius >= ScentHuntConfig.minRadius) then
    print(
        ('[qbx_k9unit] Config.ScentTrailHunt.minRadius/maxRadius must both be positive numbers with maxRadius >= ' ..
         'minRadius (found minRadius=%s, maxRadius=%s) -- RollHuntTarget\'s ring math silently misbehaves ' ..
         'otherwise. Using the shipped defaults for BOTH fields together (minRadius=10.0, maxRadius=30.0) ' ..
         'instead of clamping just one into an incoherent pair -- find Config.ScentTrailHunt.minRadius/maxRadius ' ..
         'in config.lua and fix them together.')
            :format(tostring(ScentHuntConfig.minRadius), tostring(ScentHuntConfig.maxRadius))
    )
    ScentHuntConfig.minRadius, ScentHuntConfig.maxRadius = 10.0, 30.0
end

-- arrivalRadius: independent of the pair above. A non-positive/NaN value
-- here means pollScentHunt's own `distance <= arrivalRadius` check could
-- never pass (0 -- standing exactly on the target's coordinate, not
-- achievable given a real ped's own collision radius; NaN -- every
-- comparison against it is false) -- silently making a hunt permanently
-- un-completable rather than merely harder, the same "fails toward
-- permanently stuck" direction this resource's cooldown/threshold code
-- exists to prevent everywhere else (see server/cooldowns.lua's own
-- IsValidThreshold doc comment).
if not IsPositiveNumber(ScentHuntConfig.arrivalRadius) then
    print(
        ('[qbx_k9unit] Config.ScentTrailHunt.arrivalRadius must be a positive number (found: %s) -- a ' ..
         'non-positive/NaN value here would make every hunt permanently un-completable (the distance check can ' ..
         'never pass). Using the shipped default of 3.0 instead -- find Config.ScentTrailHunt.arrivalRadius in ' ..
         'config.lua and fix it.')
            :format(tostring(ScentHuntConfig.arrivalRadius))
    )
    ScentHuntConfig.arrivalRadius = 3.0
end

-- maxHuntDurationMs is a genuine duration (a hard elapsed-time expiry, both
-- in pollScentHunt's own lazy check below AND this file's own sweep thread
-- near the end of this file -- see header "SESSION HYGIENE") -- an exact
-- fit for server/cooldowns.lua's own ResolveConfiguredThresholdMs, same as
-- startCooldownMs a few lines below. Resolved ONCE, here, so both
-- consumers read the identical, already-validated value.
ScentHuntConfig.maxHuntDurationMs = ResolveConfiguredThresholdMs(
    ScentHuntConfig.maxHuntDurationMs, 300000, 'Config.ScentTrailHunt.maxHuntDurationMs')

-- SERVER-ISSUED, monotonically increasing session id -- see this file's
-- header "STALE-SESSION RACE" section. Minted once per hunt, at the moment
-- ActiveHunts[source] is created below, and never reused -- a plain
-- incrementing counter is sufficient (no need for per-source scoping) since
-- every push this file sends already targets a single `src`, so this id
-- only ever has to disambiguate THAT source's own hunts from each other
-- over time, never one source's id from another's. Mirrors
-- server/sarcalls.lua's own NewSarCallId exactly, deliberately.
local NextHuntId = 0
local function NewHuntId()
    NextHuntId = NextHuntId + 1
    return NextHuntId
end

-- ActiveHunts[source] = { targetX: number, targetY: number, startedAt:
-- number (GetGameTimer() ms), lastDistance: number?, found: boolean,
-- alertSent: boolean, huntId: number }. Ephemeral, in-memory only,
-- single-slot per source --
-- mirrors server/main.lua's PendingLeashRequests/server/tracking.lua's
-- PendingTrackArrival shape (a short-lived claim/session record, not a
-- rate limiter), same "plain table + manual playerDropped cleanup, not a
-- NewCooldown/NewMutex shape" reasoning those two give for themselves.
local ActiveHunts = {}

AddEventHandler('playerDropped', function()
    ActiveHunts[source] = nil
end)

-- DEVELOPER_REFERENCE.md item 1 convention: server/cooldowns.lua's NewCooldown,
-- same as every other per-source start-side cooldown in this resource.
-- Constructor default validated by that file's own AssertValidDefaultThreshold
-- -- a non-positive Config.ScentTrailHunt.startCooldownMs errors loudly at
-- resource start (naming this exact call site) rather than silently
-- becoming a permanent lockout, closing the exact footgun that file's
-- header documents finding in server/fetch.lua's releaseFetchBall.
-- Clamp-and-warn rather than a raw Config read: NewCooldown() errors on a
-- non-positive threshold, and an error here at file-load time would take the
-- whole hunt feature down silently. See server/cooldowns.lua's ADDENDUM.
local StartHuntCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    ScentHuntConfig.startCooldownMs, 8000, 'Config.ScentTrailHunt.startCooldownMs'))
StartHuntCooldown.RegisterPlayerDropped()

-- Local implementation constant, NOT Config-owned -- same "internal
-- defensive bound, not an operator tuning knob" posture
-- server/tracking.lua's own MIN_TRACK_XP_DISTANCE/TRACK_TICKET_MINT_COOLDOWN_MS
-- declaration comments already establish for this identical shape. Defends
-- pollScentHunt against a modified client polling far faster than
-- Config.ScentTrailHunt.pollIntervalMs intends, independent of whatever
-- that operator-facing value is set to. MUST stay equal to
-- client/scenttrail.lua's own PULSE_MIN_INTERVAL_MS (also 500ms, see that
-- file's declaration comment on that constant) so a legitimately fast,
-- close-range poll is never mistaken for abuse and downgraded to a stale
-- cached answer.
local POLL_RATE_FLOOR_MS = 500
local PollCooldown = NewCooldown() -- no constructor default -- every call site below passes POLL_RATE_FLOOR_MS explicitly, same shape server/wellbeing.lua's own per-call-threshold NewCooldown instances already use
PollCooldown.RegisterPlayerDropped()

--- Rolls a random (x, y) between Config.ScentTrailHunt.minRadius and
--- .maxRadius of (originX, originY), uniformly by angle and linearly
--- interpolated by radius (a real uniform-by-AREA distribution would bias
--- the interpolation by sqrt(t) instead -- not done here: a mild pull
--- toward the outer edge of the ring is a harmless, undisclosed-to-the-
--- player cosmetic bias for a hunt game, not a fairness-relevant value the
--- way e.g. Config.ContrabandAlertTiers' thresholds are). Z is never
--- computed -- see this file's header "WHY 2D" section.
--- @param originX number
--- @param originY number
--- @return number targetX, number targetY
local function RollHuntTarget(originX, originY)
    -- No defensive `if maxR < minR` re-clamp needed here -- this file's own
    -- CONFIG-SAFETY block above already guarantees
    -- ScentHuntConfig.maxRadius >= ScentHuntConfig.minRadius >= (a positive
    -- number) at file-load time (GROUP 1's clamp-and-warn: either the
    -- configured pair already satisfies this, or both fields together fall
    -- back to the shipped defaults, which do) -- provably unreachable here
    -- rather than merely assumed, same "provably unreachable" standard
    -- server/sarcalls.lua's own RollSarTarget doc comment states for the
    -- identical guarantee.
    local minR = ScentHuntConfig.minRadius
    local maxR = ScentHuntConfig.maxRadius

    local radius = minR + (maxR - minR) * math.random()
    local angle = math.random() * 2 * math.pi

    return originX + math.cos(angle) * radius, originY + math.sin(angle) * radius
end

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.
--- ScentTrailHunt flag) is already checked by startScentHunt below, before
--- this function is ever reached:
---   2. an explicit block.ScentTrailHunt grant -> DENY
---   3. ScentTrailHunt listed in RequireGrant -> ALLOW only with an active
---      feature.ScentTrailHunt grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsScentTrailHuntPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.ScentTrailHunt') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.ScentTrailHunt == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.ScentTrailHunt') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

lib.callback.register('qbx_k9unit:server:startScentHunt', function(source)
    if not Config.Features.ScentTrailHunt then return { started = false, reason = 'denied' } end
    if not HasK9Access(source) then return { started = false, reason = 'denied' } end

    -- PER-PERSON FEATURE CONTROL -- see IsScentTrailHuntPermittedForCitizenId
    -- above. Keyed on `source`, the ONLY person this feature ever acts for
    -- (the K9 starting the hunt -- see this file's header "WHY THE
    -- COORDINATE NEVER LEAVES THIS FILE": nobody else is ever told
    -- anything about a hunt). Resolved via a DIRECT
    -- exports.qbx_core:GetPlayer(source) call, matching
    -- server/pursuitsprint.lua's own identical `k9Player.PlayerData.
    -- citizenid` resolution shape. Fails CLOSED (reason = 'denied', which
    -- the client already collapses into the same generic denial as
    -- 'no_access' -- see this file's header EVENT/CALLBACK CONTRACT item 1)
    -- when the citizenid cannot be resolved at all -- a per-person check
    -- with no resolvable person to check can never be answered "allow".
    -- Deliberately placed only on this START path, not on pollScentHunt or
    -- stopScentHunt below -- see this file's header "PER-PERSON FEATURE
    -- CONTROL" section for why.
    local k9Player = exports.qbx_core:GetPlayer(source)
    local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
    if not k9Citizenid or not IsScentTrailHuntPermittedForCitizenId(k9Citizenid) then
        return { started = false, reason = 'denied' }
    end

    if ActiveHunts[source] then
        return { started = false, reason = 'already_active' }
    end

    if not StartHuntCooldown.Consume(source) then
        return { started = false, reason = 'cooldown' }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { started = false, reason = 'denied' } end -- defensive: no live ped to resolve a starting position from

    local coords = GetEntityCoords(ped)
    local targetX, targetY = RollHuntTarget(coords.x, coords.y)

    ActiveHunts[source] = {
        targetX = targetX,
        targetY = targetY,
        startedAt = GetGameTimer(),
        found = false,
        alertSent = false,
        -- SERVER-ISSUED session id -- see this file's header "STALE-SESSION
        -- RACE" and NewHuntId's own declaration comment above.
        huntId = NewHuntId(),
    }

    return { started = true, huntId = ActiveHunts[source].huntId }
end)

--- UNCONDITIONAL -- see this file's header EVENT/CALLBACK CONTRACT item 3
--- and the standing "no unbounded trap" requirement it cites. Never checks
--- Config.Features.ScentTrailHunt or HasK9Access on purpose.
RegisterNetEvent('qbx_k9unit:server:stopScentHunt', function()
    ActiveHunts[source] = nil
end)

lib.callback.register('qbx_k9unit:server:pollScentHunt', function(source)
    -- SESSION HYGIENE (see this file's header section by that name): a
    -- failed re-validation here is ABOUT to answer `{ active = false }`,
    -- which client/scenttrail.lua's own poll loop treats as "this hunt is
    -- over" and stops polling for -- WITHOUT ever sending stopScentHunt (it
    -- is not treated as an abandon on that client). If this file did not
    -- also clear ActiveHunts[source] in the same breath, the record would
    -- silently outlive the only thing that was ever going to ask about it
    -- again, permanently blocking a fresh hunt as 'already_active' the
    -- instant access/the feature came back. This is cleanup triggered BY a
    -- failed gate, never cleanup GATED ON a check passing -- the standing
    -- "gate the start, never the stop" rule is unaffected: the gate still
    -- only ever decides what this callback REPORTS, and it must not report
    -- something server-side state disagrees with.
    if not Config.Features.ScentTrailHunt or not HasK9Access(source) then
        ActiveHunts[source] = nil
        return { active = false }
    end

    local hunt = ActiveHunts[source]
    if not hunt then return { active = false } end

    local now = GetGameTimer()
    if (now - hunt.startedAt) > ScentHuntConfig.maxHuntDurationMs then
        ActiveHunts[source] = nil
        return { active = false, expired = true }
    end

    if not PollCooldown.Consume(source, POLL_RATE_FLOOR_MS, now) then
        -- Rate-limited -- return the hunt's last computed snapshot rather
        -- than rejecting outright, so a client polling faster than
        -- intended degrades to a stale-but-harmless repeat of its last
        -- real answer instead of a spurious "inactive" state.
        return { active = true, distance = hunt.lastDistance, found = hunt.found }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { active = false } end -- defensive: no live ped to measure from

    local coords = GetEntityCoords(ped)
    -- 2D/horizontal distance only -- see this file's header "WHY 2D" section.
    local dx = coords.x - hunt.targetX
    local dy = coords.y - hunt.targetY
    local distance = math.sqrt(dx * dx + dy * dy)

    local found = distance <= ScentHuntConfig.arrivalRadius

    hunt.lastDistance = distance
    hunt.found = found

    if found and not hunt.alertSent then
        hunt.alertSent = true
        TriggerClientEvent('qbx_k9unit:client:scentHuntFound', source, hunt.huntId)
    end

    return { active = true, distance = distance, found = found }
end)

-- ======================================================================
-- SESSION HYGIENE -- BACKGROUND SWEEP (see this file's header section by
-- that exact name for the full incident this closes). Unconditional,
-- independent of whether any client ever polls again -- mirrors
-- server/scentlineup.lua's own phase-expiry sweep and server/sarcalls.lua's
-- own tick-loop timeout check, both of which already do not rely on the
-- client to expire themselves. ActiveHunts is small and ephemeral (at most
-- one entry per currently-connected, currently-hunting source), so a linear
-- `pairs` pass on this interval is cheap. Removing ONLY the current key of a
-- Lua table mid-`pairs()` traversal (never a different key) is well-defined
-- per the Lua 5.4 reference manual -- server/scentlineup.lua's own sweep
-- already relies on this exact property, and this loop does the same thing
-- (`ActiveHunts[src] = nil`).
--
-- Deliberately does NOT duplicate pollScentHunt's own access/feature-loss
-- check -- that specific case is already closed immediately (no need to
-- wait for this interval) by pollScentHunt's own SESSION HYGIENE fix above.
-- This sweep's only job is the pure time-based backstop: a hunt older than
-- Config.ScentTrailHunt.maxHuntDurationMs is cleared regardless of whether
-- anything ever asks about it again.
-- ======================================================================
local HUNT_SWEEP_INTERVAL_MS = 30000 -- local implementation constant, not Config-owned -- same "internal detail, not an operator tuning knob" posture server/scentlineup.lua's own SWEEP_INTERVAL_MS declaration comment establishes for the identical shape

CreateThread(function()
    while true do
        Wait(HUNT_SWEEP_INTERVAL_MS)

        local now = GetGameTimer()
        for src, hunt in pairs(ActiveHunts) do
            if (now - hunt.startedAt) > ScentHuntConfig.maxHuntDurationMs then
                ActiveHunts[src] = nil
            end
        end
    end
end)
