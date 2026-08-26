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
       reason: ('already_active'|'cooldown'|'denied')? } [lib.callback]
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
       fresh one this way; the only OTHER thing that clears one is this
       file's own maxHuntDurationMs lazy-expiry check inside pollScentHunt
       below, or the player disconnecting.
    2. 'qbx_k9unit:server:pollScentHunt' (source) -> { active: boolean,
       distance: number?, found: boolean?, expired: boolean? } [lib.callback]
       Re-validates access on EVERY call (a QUERY, not a termination -- see
       this resource's established gating split, e.g. client/radial.lua's
       own extensive Detach/Release/Recall-vs-Start*/Track* commentary).
       Rate-limited per source by POLL_RATE_FLOOR_MS below, independent of
       whatever Config.ScentTrailHunt.pollIntervalMs the operator configures
       for the CLIENT's own cadence -- a defensive floor against a modified
       client polling faster than intended, not the feature's real pacing
       control.
    3. 'qbx_k9unit:server:stopScentHunt' (source) [RegisterNetEvent] --
       UNCONDITIONAL. Never checks Config.Features.ScentTrailHunt or
       HasK9Access -- an unconditional `ActiveHunts[source] = nil`, so it
       is always safe to call (including when nothing is active, or when
       the feature was disabled/access was revoked after a hunt started).
       See this resource's standing "no unbounded trap" requirement,
       already applied identically to e.g. server/recall.lua's
       requestRecall and server/main.lua's detachLeash handlers.
    4. 'qbx_k9unit:client:scentHuntFound' (source's own client only, never
       broadcast) [TriggerClientEvent, THIS FILE only ever SENDS this] --
       fired the first time a given hunt's distance is observed to be
       at/under Config.ScentTrailHunt.arrivalRadius (guarded by
       `hunt.alertSent`, fired exactly once per hunt). A low-latency nudge
       only -- client/scenttrail.lua's own poll loop independently observes
       `result.found` from THIS SAME callback's return value regardless, so
       a dropped push is not a stuck-forever failure mode for the caller
       that triggered it.

    Automatic path: none. Every code path in this file runs in direct
    response to one of the three named calls above, or to a
    `playerDropped` disconnect -- no self-scheduled sweep thread exists
    (ActiveHunts is small, ephemeral, single-slot-per-source, and already
    bounded by Config.ScentTrailHunt.maxHuntDurationMs's own lazy check
    inside pollScentHunt -- a dedicated sweep thread would only matter for
    a source that starts a hunt, then never polls AND never disconnects,
    which cannot happen from this file's own client: client/scenttrail.lua
    always either polls on an interval or sends stopScentHunt on death/
    abandon. `playerDropped` covers the one remaining case, a genuine
    disconnect).
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
    - Exposes NO resource-global functions. ActiveHunts is this file's own
      private state; nothing outside this file (including
      client/scenttrail.lua) ever reads it directly.
    - Does NOT read or write anything in server/tracking.lua's TrackableLog
      or client/tracking.lua's trackingState -- structurally unrelated
      systems that happen to share a "K9 walks toward a resolved point"
      shape. No shared state, no coupling either direction.
    - Does NOT call AwardXP, AwardXPDirect, or any progression.lua global --
      see this file's header "THE XP DECISION" above.
    - No natives are used anywhere in this file beyond GetEntityCoords/
      GetPlayerPed/GetGameTimer, all already allowlisted in the repo-root
      .luacheckrc read_globals list from this resource's existing usage
      elsewhere -- verification method: no new native surface was
      introduced, so no new native-decl/hash-database lookup was required
      for this file. math.random/math.sqrt/math.pi/math.cos/math.sin are
      the standard Lua 5.4 math library, not FiveM natives.
]]

local ScentHuntConfig = Config.ScentTrailHunt or {}

-- ActiveHunts[source] = { targetX: number, targetY: number, startedAt:
-- number (GetGameTimer() ms), lastDistance: number?, found: boolean,
-- alertSent: boolean }. Ephemeral, in-memory only, single-slot per source --
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
    local minR = ScentHuntConfig.minRadius or 10.0
    local maxR = ScentHuntConfig.maxRadius or 30.0
    if maxR < minR then maxR = minR end -- defensive: never let a misconfigured inverted range make the radius roll below negative-width

    local radius = minR + (maxR - minR) * math.random()
    local angle = math.random() * 2 * math.pi

    return originX + math.cos(angle) * radius, originY + math.sin(angle) * radius
end

lib.callback.register('qbx_k9unit:server:startScentHunt', function(source)
    if not Config.Features.ScentTrailHunt then return { started = false, reason = 'denied' } end
    if not HasK9Access(source) then return { started = false, reason = 'denied' } end

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
    }

    return { started = true }
end)

--- UNCONDITIONAL -- see this file's header EVENT/CALLBACK CONTRACT item 3
--- and the standing "no unbounded trap" requirement it cites. Never checks
--- Config.Features.ScentTrailHunt or HasK9Access on purpose.
RegisterNetEvent('qbx_k9unit:server:stopScentHunt', function()
    ActiveHunts[source] = nil
end)

lib.callback.register('qbx_k9unit:server:pollScentHunt', function(source)
    if not Config.Features.ScentTrailHunt then return { active = false } end
    if not HasK9Access(source) then return { active = false } end

    local hunt = ActiveHunts[source]
    if not hunt then return { active = false } end

    local now = GetGameTimer()
    local maxDurationMs = ScentHuntConfig.maxHuntDurationMs or 300000
    if (now - hunt.startedAt) > maxDurationMs then
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

    local arrivalRadius = ScentHuntConfig.arrivalRadius or 3.0
    local found = distance <= arrivalRadius

    hunt.lastDistance = distance
    hunt.found = found

    if found and not hunt.alertSent then
        hunt.alertSent = true
        TriggerClientEvent('qbx_k9unit:client:scentHuntFound', source)
    end

    return { active = true, distance = distance, found = found }
end)
