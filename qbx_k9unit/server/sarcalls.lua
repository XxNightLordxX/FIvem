--[[
    qbx_k9unit/server/sarcalls.lua

    Missing-person / search-and-rescue calls -- K9_IDEAS.md §3. Sibling to
    server/scenttrail.lua (K9_IDEAS.md §2's "follow your nose" hunting
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
    (K9_IDEAS.md §2's "you don't get told where the thing is... you're
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
       reason: ('already_active'|'cooldown'|'denied')? } [lib.callback]
       Re-validates Config.Features.SARCalls and HasK9Access(source)
       server-side regardless of client UI state, mirrors server/
       scenttrail.lua's startScentHunt exactly, including the "denied"
       collapse for feature-off/no-access/citizenid-unresolvable/no-live-ped
       (this resource's established "don't invent a distinction the server
       doesn't give data for" precedent). Resolves the CALLER'S OWN live
       server-side position as the origin to roll a target near -- NEVER a
       client-supplied coordinate. The call's type ('person' | 'property')
       is rolled here too and kept server-side only until the call resolves
       as 'found' -- neither the client nor any caller of this callback
       ever learns it up front, preserving the same mystery for BOTH kinds
       of call.
    2. 'qbx_k9unit:server:abandonSarCall' (source) [RegisterNetEvent] --
       UNCONDITIONAL. See "NO UNBOUNDED TRAP" above.
    3. 'qbx_k9unit:client:sarHintTierChanged' (tier: string) [TriggerClientEvent,
       THIS FILE only ever SENDS this, to the caller's own client only,
       never broadcast] -- fired once immediately on a successful
       requestSarCall (the starting tier, whatever it genuinely is) and
       again every time the tick loop below observes a DIFFERENT tier than
       last observed for that call. Never fired twice in a row with the
       same tier -- see TierForDistance/the tick loop's own edge-trigger
       comment.
    4. 'qbx_k9unit:client:sarCallEnded' (reason: ('found'|'timeout'|
       'abandoned'), callType: ('person'|'property')? [only meaningful when
       reason == 'found']) [TriggerClientEvent, THIS FILE only ever SENDS
       this, to the caller's own client only] -- the one and only signal
       telling client/sarcalls.lua to run its own local cosmetic reveal
       (reason == 'found' only).

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
    standard Lua 5.4 math library, not FiveM natives, and vector3/vector2
    arithmetic (the `#(a - b)` idiom used nowhere in THIS file, since
    distance here is a flat 2D dx/dy/sqrt per "WHY 2D" above, not a vector
    subtraction) is already used throughout this resource's server files
    with no .luacheckrc entry required (confirmed: `luacheck config.lua`
    reports zero warnings on its own literal `vector3(...)` call, and
    luacheck 1.2.0 recognizes vector2/vector3/vector4/quat as built-in
    globals even under `std = "lua54"` -- verified directly against the
    installed luacheck binary this session, not assumed). The one native
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
-- ======================================================================
assert(type(tuning) == 'table',
    '[qbx_k9unit] Config.SARCalls must be a table when Config.Features.SARCalls is true -- this file reads ' ..
    'minRadius/maxRadius/arrivalRadius/burningDistance/hotDistance/warmDistance/pollIntervalMs/' ..
    'maxCallDurationMs/startCooldownMs from it unconditionally once the feature flag is on.')
assert(type(tuning.minRadius) == 'number' and tuning.minRadius > 0,
    '[qbx_k9unit] Config.SARCalls.minRadius must be a positive number -- this is the ONE value that guarantees ' ..
    'real travel distance for every SAR call regardless of how fast requests are repeated (see this file\'s own ' ..
    '"XP ARITHMETIC" section) -- a non-positive value would let a call spawn its hidden target on top of the requester.')
assert(type(tuning.maxRadius) == 'number' and tuning.maxRadius >= tuning.minRadius,
    '[qbx_k9unit] Config.SARCalls.maxRadius must be a number >= Config.SARCalls.minRadius.')
assert(type(tuning.arrivalRadius) == 'number' and tuning.arrivalRadius > 0,
    '[qbx_k9unit] Config.SARCalls.arrivalRadius must be a positive number -- the server-authoritative "found" distance.')
assert(type(tuning.burningDistance) == 'number' and tuning.burningDistance > tuning.arrivalRadius,
    '[qbx_k9unit] Config.SARCalls.burningDistance must be a number greater than Config.SARCalls.arrivalRadius -- ' ..
    'the officer must be able to reach the "burning" hint tier before actually arriving, or the hint feed jumps ' ..
    'straight from silence to "found" with no warning tier in between.')
assert(type(tuning.hotDistance) == 'number' and tuning.hotDistance > tuning.burningDistance,
    '[qbx_k9unit] Config.SARCalls.hotDistance must be a number greater than Config.SARCalls.burningDistance.')
assert(type(tuning.warmDistance) == 'number' and tuning.warmDistance > tuning.hotDistance,
    '[qbx_k9unit] Config.SARCalls.warmDistance must be a number greater than Config.SARCalls.hotDistance.')
assert(type(tuning.pollIntervalMs) == 'number' and tuning.pollIntervalMs > 0,
    '[qbx_k9unit] Config.SARCalls.pollIntervalMs must be a positive number -- passed directly to Wait() in this ' ..
    'file\'s own tick thread below; a non-positive value would poll needlessly tightly for a feature whose hint ' ..
    'cadence has no reason to be per-frame.')
assert(type(tuning.maxCallDurationMs) == 'number' and tuning.maxCallDurationMs > 0,
    '[qbx_k9unit] Config.SARCalls.maxCallDurationMs must be a positive number -- the hard, unconditional expiry ' ..
    'every active call is measured against regardless of whether anyone completes it (see this file\'s own ' ..
    '"NO UNBOUNDED TRAP" section). A non-positive value here would make every call expire the instant it starts.')

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
local StartSarCallCooldown = NewCooldown(tuning.startCooldownMs)
-- Deliberately NOT .RegisterPlayerDropped() -- this cooldown is keyed by
-- citizenid, which OUTLIVES a disconnect/reconnect within the same server
-- uptime. Clearing it on disconnect would let a citizenid bypass the
-- anti-farm floor simply by relogging, defeating the entire reason this
-- cooldown is keyed by citizenid instead of by source in the first place.

-- ActiveSarCalls[source] = { citizenid: string, jobName: string?,
--   callType: ('person'|'property'), targetX: number, targetY: number,
--   startedAt: number (GetGameTimer() ms), currentTier: string }. Ephemeral,
-- in-memory only, single-slot per source -- mirrors server/scenttrail.lua's
-- ActiveHunts shape exactly (a short-lived session record, not a rate
-- limiter, so a plain table + manual playerDropped cleanup, not a
-- NewCooldown/NewMutex instance, per that file's own identical reasoning).
local ActiveSarCalls = {}

AddEventHandler('playerDropped', function()
    ActiveSarCalls[source] = nil
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

--- Rolls a random (x, y) between Config.SARCalls.minRadius and .maxRadius
--- of (originX, originY), uniformly by angle and linearly interpolated by
--- radius -- same "a real uniform-by-AREA distribution would need a
--- sqrt(t) bias instead, not done here" honesty server/scenttrail.lua's
--- own RollHuntTarget already states for the identical math: a mild pull
--- toward the outer edge of the ring is a harmless, undisclosed-to-the-
--- player cosmetic bias, not a fairness-relevant value. Unlike that
--- function, this one does NOT re-clamp `maxR < minR` defensively at call
--- time -- this file's own CONFIG-SAFETY GUARD above already asserts
--- maxRadius >= minRadius at load time, so that condition is provably
--- unreachable here rather than merely assumed.
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

--- Ends `src`'s active call, if any, for `reason`
--- ('found'|'timeout'|'abandoned'). Idempotent -- a harmless no-op if
--- nothing is active for `src` (covers a genuine double-call, e.g. the
--- tick loop observing 'found' in the same instant abandonSarCall also
--- fires -- whichever runs first wins, the second is simply a no-op since
--- ActiveSarCalls[src] is already nil by then). NEVER gated on access or
--- certification -- see this file's header "NO UNBOUNDED TRAP".
--- @param src number
--- @param reason string -- 'found' | 'timeout' | 'abandoned'
local function EndSarCall(src, reason)
    local call = ActiveSarCalls[src]
    if not call then return end
    ActiveSarCalls[src] = nil

    if reason == 'found' then
        -- Runtime-existence guard, not a load-order assumption -- see this
        -- file's header FILE-TO-FILE CONTRACT. AwardXP itself re-checks
        -- Config.Features.XPProgression and re-derives the amount from
        -- Config.XP.awards.sarCallCompleted -- this file never computes or
        -- passes an amount.
        if type(AwardXP) == 'function' then
            AwardXP(call.citizenid, 'sarCallCompleted')
        end
        FireOutboundEvent('qbx_k9unit:events:sarCallCompleted', src, call.citizenid, call.jobName, call.callType, GetGameTimer() - call.startedAt)
        NotifyPlayer(src, call.callType == 'person' and locale('sar.found_person') or locale('sar.found_property'), 'success')
        TriggerClientEvent('qbx_k9unit:client:sarCallEnded', src, 'found', call.callType)
    elseif reason == 'timeout' then
        -- No outbound event here on purpose -- see this file's header
        -- EVENT/CALLBACK CONTRACT note on why 'timeout'/'abandoned' never
        -- fire one.
        NotifyPlayer(src, locale('sar.call_timeout'), 'inform')
        TriggerClientEvent('qbx_k9unit:client:sarCallEnded', src, 'timeout')
    elseif reason == 'abandoned' then
        NotifyPlayer(src, locale('sar.call_abandoned'), 'inform')
        TriggerClientEvent('qbx_k9unit:client:sarCallEnded', src, 'abandoned')
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
        -- below does exactly that via ActiveSarCalls[src] = nil.
        for src, call in pairs(ActiveSarCalls) do
            if (now - call.startedAt) >= tuning.maxCallDurationMs then
                EndSarCall(src, 'timeout')
            else
                local ped = GetPlayerPed(src)
                if ped ~= 0 then
                    local pos = GetEntityCoords(ped)
                    local distance = Distance2D(pos.x, pos.y, call.targetX, call.targetY)

                    if distance <= tuning.arrivalRadius then
                        EndSarCall(src, 'found')
                    else
                        local tier = TierForDistance(distance)
                        if tier ~= call.currentTier then
                            call.currentTier = tier
                            TriggerClientEvent('qbx_k9unit:client:sarHintTierChanged', src, tier)
                        end
                    end
                end
                -- ped == 0: not actually spawned in right now (still loading,
                -- or GetPlayers()-adjacent staleness) -- skip this tick and
                -- try again next tick, same as server/integrations.lua's
                -- PollK9Health does for the identical condition. A genuine
                -- disconnect is handled by the playerDropped handler above,
                -- not by anything in this loop.
            end
        end
    end
end)

lib.callback.register('qbx_k9unit:server:requestSarCall', function(source)
    if not Config.Features.SARCalls then return { started = false, reason = 'denied' } end
    if not HasK9Access(source) then return { started = false, reason = 'denied' } end

    if ActiveSarCalls[source] then
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

    if not StartSarCallCooldown.Consume(citizenid) then
        return { started = false, reason = 'cooldown' }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { started = false, reason = 'denied' } end -- defensive: no live ped to resolve a starting position from

    local coords = GetEntityCoords(ped)
    local targetX, targetY = RollSarTarget(coords.x, coords.y)
    local callType = math.random() < 0.5 and 'person' or 'property'
    local initialDistance = Distance2D(coords.x, coords.y, targetX, targetY)

    ActiveSarCalls[source] = {
        citizenid = citizenid,
        jobName = jobName,
        callType = callType,
        targetX = targetX,
        targetY = targetY,
        startedAt = GetGameTimer(),
        currentTier = TierForDistance(initialDistance),
    }

    FireOutboundEvent('qbx_k9unit:events:sarCallStarted', source, citizenid, jobName, callType)
    NotifyPlayer(source, locale('sar.call_started'), 'inform')
    -- Immediate first hint -- the tick loop above only pushes on a CHANGE
    -- from the previously observed tier, so without this the caller would
    -- otherwise hear/see nothing until the first tick that happens to cross
    -- a tier boundary, even if the roll already landed inside one.
    TriggerClientEvent('qbx_k9unit:client:sarHintTierChanged', source, ActiveSarCalls[source].currentTier)

    return { started = true }
end)

--- UNCONDITIONAL -- see this file's header "NO UNBOUNDED TRAP". Never
--- checks Config.Features.SARCalls or HasK9Access on purpose.
RegisterNetEvent('qbx_k9unit:server:abandonSarCall', function()
    EndSarCall(source, 'abandoned')
end)
