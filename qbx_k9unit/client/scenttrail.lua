--[[
    qbx_k9unit/client/scenttrail.lua

    "Follow your nose" -- K9_IDEAS.md §2. Turns a search into a hunt instead
    of a single click: a K9 starts a Scent Trail Hunt near its own current
    position, is never told where the hidden spot actually is, and is
    instead guided toward it purely by a felt cue -- a growl/pant pulse that
    speeds up the closer the K9 gets -- ending in an automatic "trained
    final response" (the dog sits and barks on its own) once it's close
    enough, reusing K9_IDEAS.md §1's exact framing rather than a text
    pop-up.

    This is a NEW file alongside client/tracking.lua, not an extension of
    it -- deliberately. client/tracking.lua's Scent/Blood/Gunpowder trails
    hand the resolved coordinate straight to the client and render explicit
    ground markers; this feature is the opposite shape on purpose (no
    marker, no blip, no coordinate ever sent to this client at all -- see
    server/scenttrail.lua's own header for why) and does not touch that
    file's trackingState/currentTrailMarkers or its five resource-globals.

    ======================================================================
    WHY NO COORDINATE, NO MARKER, NO BLIP (design, not a limitation):
    K9_IDEAS.md §2's own "watch out for" section explicitly warns against
    turning a sense into "a menu that hands you the answer" (citing
    Batman/Witcher detective-vision criticism). The server therefore never
    reveals the hidden target's coordinate to this client at all -- it only
    ever answers "how far, in a straight line, is the caller's OWN live
    position from the target right now" (server/scenttrail.lua's
    pollScentHunt callback), which this file turns into pacing, never a
    number shown on screen. This is a smaller information surface than
    client/tracking.lua's own trails get (those DO hand over a coordinate,
    because rendering an explicit trail is that feature's whole point) --
    a deliberate, disclosed difference in shape between two features that
    otherwise sound similar.

    ======================================================================
    HOW THE FEEDBACK WORKS -- reusing an already-proven building block, per
    K9_IDEAS.md §2's own note that this trick is not a new invention:
    client/proximityaudio.lua already plays a sound that gets louder/
    quieter with distance to a nearby K9 ENTITY. This feature has no entity
    to fall back on (the hidden spot is a bare coordinate, not an entity),
    so it cannot reuse that entity-distance gain math directly -- instead it
    reuses client/audio.lua's PlayK9Sound() bridge as a plain one-shot
    trigger (opts omitted => loop=false, per that function's own doc
    comment: "a one-shot sound simply ends on its own... no thread, no
    tracking needed") and encodes proximity in PACING (how often a pulse
    fires) rather than gain. Closer = faster pulses; farther = slower
    pulses, floored/ceilinged by PULSE_MIN_INTERVAL_MS/PULSE_MAX_INTERVAL_MS
    below. The pulse itself reuses the ALREADY-SHIPPED 'Growl_Ambient' sound
    key (client/main.lua's BARK_SOUND_NAME sibling, mapped by
    client/audio.lua's ToAudioFileKey fallback to html/sounds/
    growl_ambient.ogg -- already listed in fxmanifest.lua's files{} block
    for Config.Features.ProximityAudioFX) -- this feature ships ZERO new
    audio assets and needs ZERO new html/app.js or client/audio.lua changes,
    both of which are off-limits to this pass anyway.

    Calling PlayK9Sound with THIS client's own ped netId as the "source
    entity" means client/audio.lua's own GainToEntity computes a distance of
    0 every time (listener and "source" are the same ped) -- gain is always
    1.0. That is intentional, not a missed opportunity to also modulate
    volume: the felt cue here is CADENCE, and layering a second, unrelated
    distance metric (gain, which would always read 0 anyway for a
    self-targeted call) on top would add nothing.

    NATIVE VERIFICATION: this file introduces ZERO natives beyond ones
    already allowlisted in the repo-root .luacheckrc read_globals list
    (PlayerPedId, IsEntityDead, NetworkGetNetworkIdFromEntity,
    RegisterCommand) and ZERO new resource-global functions (every helper
    below is `local`; the only new globals this feature needs at all are
    the two new network names below, not Lua globals) -- so no
    .luacheckrc/globals change was needed for this file, and none is
    requested. PlayK9Sound/CanShowK9UI/DenyK9UIAccess/K9Sit are all
    pre-existing resource-globals already declared there, called behind
    this resource's standard `type(fn) == 'function'` runtime-existence
    guard.

    ======================================================================
    DELIBERATELY OMITTED, DISCLOSED (not oversights):

    1. NO SCREEN-TINT LAYER. K9_IDEAS.md §2 mentions "your view tints
       slightly" as a possible SECOND channel alongside sound.
       client/screenfx.lua already owns the ONE engine-global
       SetTimecycleModifier/ClearTimecycleModifier slot this resource uses
       (Config.Features.ContrabandScreenFX), and that native is verified
       (per its own file's header and this repo's .luacheckrc) to be a
       single shared "whatever was set last wins" piece of engine state --
       there is no per-caller ownership token. Layering a second,
       continuously-updating tint on top from this file, entirely
       independently, would fight that file for the same slot: a
       contraband find mid-hunt would stomp this feature's tint for its
       whole duration, and that file's own onResourceStop/expiry handler
       unconditionally calls ClearTimecycleModifier() with no concept of
       "was that actually mine to clear." Rather than reach into
       client/screenfx.lua (off-limits to this pass) to add ownership
       arbitration for a `false`-by-default feature, this pass ships sound
       alone and leaves a tint layer as a disclosed future addition to
       coordinate with coder-ui/coder-security, not something silently
       skipped.
    2. NO XP AWARD. See server/scenttrail.lua's own header "THE XP
       DECISION" for the full reasoning -- this feature mints zero XP by
       design, so it adds 0 XP/hr to the shared budget
       server/progression.lua enforces.
    3. NOT WIRED INTO client/radial.lua. That file is owned by another
       coder this session and off-limits to this pass's edits (its own
       registration is a fixed, monolithic RegisterK9RadialMenu() function
       with no dynamic/exported "add an item" seam to hook into without
       editing it directly). This feature is fully reachable on its own via
       the '/k9nosehunt' chat command below (start) and '/k9nosehunt stop'
       (abandon) -- the exact same "command-only, no radial entry yet"
       shape this resource already ships for k9recall/k9calmdown/
       k9deploykennel. Flagged for whoever next touches client/radial.lua
       to add a "Start/Stop Nose Hunt" item calling StartScentHunt()/
       StopScentHunt() the same context-sensitive way that file's own Track
       Scent/Blood/Gunpowder items already do -- not done here, since it
       would require editing a file this pass does not own.

    ======================================================================
    EVENT/CALLBACK CONTRACT (server side: server/scenttrail.lua):
    1. 'qbx_k9unit:server:startScentHunt' () -> { started: boolean, reason:
       ('already_active'|'cooldown'|'denied')?, huntId: number? [present iff
       started == true -- see "STALE-SESSION RACE" below] } [lib.callback]
       Re-validates Config.Features.ScentTrailHunt and HasK9Access(source)
       server-side regardless of client UI state, same posture as every
       other Phase 2 callback in this resource. Never takes or returns a
       coordinate of any kind.
    2. 'qbx_k9unit:server:pollScentHunt' () -> { active: boolean, distance:
       number?, found: boolean?, expired: boolean? } [lib.callback]
       Called on an interval (never per-frame -- see EnsureHuntPollThreadRunning
       below), re-validates access on every call (a QUERY, not a
       termination -- see this resource's established initiation/query-vs-
       termination gating split, e.g. client/radial.lua's own extensive
       commentary on Detach/Release/Recall never being gated while
       Start*/Track* always are). Deliberately does NOT carry a huntId --
       see "STALE-SESSION RACE" below for why this one channel does not
       need it.
    3. 'qbx_k9unit:server:stopScentHunt' () [RegisterNetEvent, this file
       only ever SENDS this] -- UNCONDITIONAL, never gated on
       CanShowK9UI()/access of any kind, and never takes or needs a huntId.
       See StopScentHunt() below: a player who loses access, or simply
       wants to give up, must always be able to abandon a hunt -- the
       standing "no unbounded trap" requirement this resource applies to
       every start/stop pair.
    4. 'qbx_k9unit:client:scentHuntFound' (huntId: number) [RegisterNetEvent,
       server->client, THIS caller only, never broadcast] -- a low-latency
       nudge so the "found" reaction doesn't wait for this file's own next
       poll tick; the poll loop's own `result.found` check (independent, see
       EnsureHuntPollThreadRunning) is the primary/robust detection path,
       so a dropped push of this event is not a stuck-forever failure mode.
       `huntId` added -- see "STALE-SESSION RACE" below.
    ======================================================================

    STALE-SESSION RACE -- ADDED A LATER PASS (found by a client-side sweep;
    not present when this file was first written): server/scenttrail.lua's
    own header carries the full server-side writeup of this same fix, and
    server/sarcalls.lua's/client/sarcalls.lua's own identically-shaped
    sections cover the sibling feature this mirrors -- one pattern, not two,
    for the same underlying gap.

    THE BUG: the 'qbx_k9unit:client:scentHuntFound' handler below used to
    check only `if not huntActive then return end`, with nothing identifying
    WHICH hunt a push belonged to. A stale, delayed 'found' push for a hunt
    already stopped or completed could arrive AFTER a brand-new hunt had
    already started (huntActive true again, now for the new hunt) and would
    be accepted as belonging to it, completing that new, unsolved hunt
    early -- the dog sits and barks on a hunt it never actually finished.
    More benign than server/sarcalls.lua's own version of this bug (a wrong
    EARLY completion here, versus a silent, total dropout of every
    in-between hint there) and the poll loop's own independent `result.found`
    check is this feature's documented primary detection path regardless, so
    nothing was ever left permanently hanging -- but a genuine, real race
    all the same, closed the same way.

    THE FIX: server/scenttrail.lua now mints a small, monotonically
    increasing, SERVER-ISSUED hunt id once per hunt (never client-generated
    -- could be spoofed or duplicated) and includes it on
    startScentHunt's own `huntId` return field and on the scentHuntFound
    push. `currentHuntId` below tracks the id THIS client currently believes
    is its own live hunt. IsForCurrentHunt(pushedId) decides whether an
    incoming scentHuntFound push belongs to that hunt:
      - no id at all (pushedId == nil) is ALWAYS ACCEPTED, deliberately,
        never silently dropped -- see server/sarcalls.lua's own identical
        reasoning for why the opposite default would quietly reintroduce a
        dropout failure mode the moment a future call site forgot to pass
        one, which matters just as much here even though there is only one
        push call site today.
      - a real id is accepted only if it matches `currentHuntId` exactly.
        StopScentHunt() and CompleteHunt() below both set
        `currentHuntId = nil` the moment they run (mirroring their own
        already-immediate `huntActive = false`), so a late push for a hunt
        this client has already left behind can never again match whatever
        it currently considers current.

    NOT A TERMINATION-PATH CHANGE: StopScentHunt() below remains exactly as
    unconditional as it already was -- it never reads, sends, or needs any
    huntId, and this fix adds nothing to it. A client holding a stale,
    wrong, or nil `currentHuntId`, for any reason, can always still call
    StopScentHunt() and have server/scenttrail.lua's own side cleaned up --
    the id mechanism only ever decides whether THIS CLIENT acts on an
    incoming scentHuntFound push, never whether the server accepts a
    termination request. See this resource's standing "no unbounded trap"
    rule, which this fix does not touch.
    ======================================================================

    RESOURCE-STOP HYGIENE -- FIXED THIS PASS (found by a client-side sweep;
    not present when this file was first written). client/pursuitsprint.lua
    already resets its own state on `onResourceStop`; this file used to have
    NO `onResourceStop` handler at all, so a client-side stop (this
    resource's own copy being independently restarted, or the FXServer
    client runtime unilaterally stopping just THIS client's copy after
    repeated script errors -- a real, server-independent event) never told
    server/scenttrail.lua to release ActiveHunts[source].

    WORSE THAN A BOUNDED "SELF-HEALS IN MINUTES" GAP: server/scenttrail.lua's
    own header states its expiry check is LAZY, run only "inside
    pollScentHunt" -- there is no separate, always-running sweep thread
    server-side (contrast server/sarcalls.lua's own unconditional periodic
    tick loop, which keeps re-checking every active call on its own
    schedule regardless of the client). A source that starts a hunt and
    then never polls again -- exactly what a dead/restarted client script
    produces, since its own poll thread dies with the rest of this
    resource's Lua state and sends nothing further -- leaves
    ActiveHunts[source] with NOTHING left to trigger its own lazy expiry
    check. That record then blocks a fresh '/k9nosehunt' with
    reason = 'already_active' until the ONLY other thing that clears it:
    this player's next genuine disconnect (playerDropped), not
    Config.ScentTrailHunt.maxHuntDurationMs's own timer, which never gets a
    chance to run for a source nobody polls for anymore.

    THE FIX: an unconditional `onResourceStop` handler below calls
    StopScentHunt() itself -- the exact same unconditional abandon path
    '/k9nosehunt stop' already uses, so this is not a new code path, just a
    new caller of an existing, already-safe-to-call-anytime one. NEVER
    gated on CanShowK9UI()/access of any kind, per this file's own standing
    "no unbounded trap" rule (see StopScentHunt()'s own doc comment).
    ======================================================================

    FILE-TO-FILE CONTRACT: this file exposes NO resource-global functions
    at all (a deliberate choice -- see the .luacheckrc note above). Its only
    external surface is the '/k9nosehunt' [stop] chat command. It calls
    CanShowK9UI()/DenyK9UIAccess() (client/main.lua), K9Sit()
    (client/movement.lua) and PlayK9Sound() (client/audio.lua), every one
    behind a `type(fn) == 'function'` runtime-existence guard per this
    resource's standing convention -- no load-order assumption on any of
    them, so this file's own position in fxmanifest.lua's client_scripts
    list does not matter relative to any of the three.
]]

if not Config.Features.ScentTrailHunt then return end

local ScentHuntConfig = Config.ScentTrailHunt or {}

-- Fastest pulse cadence, right on top of the hidden spot. MUST stay >=
-- server/scenttrail.lua's own POLL_RATE_FLOOR_MS (also 500ms, see that
-- file's declaration comment on that constant) -- both are local
-- implementation constants this pass owns on both ends, so keeping them
-- numerically identical is a one-pass guarantee, not a hand-sync risk
-- across another file this session does not control. If either changes,
-- change both together.
local PULSE_MIN_INTERVAL_MS = 500

-- Slowest pulse cadence, at/beyond the edge of the hunt area -- config-
-- tunable (an operator's "how often should a far-away pulse check in"
-- preference), unlike the fixed close-in floor above.
--
-- CLAMP AND WARN (bug found + fixed this pass): this used to be a bare
-- `ScentHuntConfig.pollIntervalMs or 2000` -- Lua's `or` only falls through
-- on nil/false, so a configured `pollIntervalMs = 0` (or any other
-- non-positive/invalid value) passed straight through, same bug class as
-- client/proximityaudio.lua's own PROXIMITY_SCAN_INTERVAL_MS fix (see that
-- file's comment for the fuller writeup) and this resource's own on-record
-- "a non-positive cooldown must never silently remove a throttle"
-- precedent. Here the effect is worse than a flat Wait(0): IntervalForDistance()
-- below LINEARLY INTERPOLATES between PULSE_MIN_INTERVAL_MS (500, at 0m) and
-- this value (at/beyond PULSE_MAX_DISTANCE_METERS) and its result is fed
-- directly into `Wait(...)` at this file's own poll loop below with no
-- further clamp there either -- a PULSE_MAX_INTERVAL_MS below
-- PULSE_MIN_INTERVAL_MS does not just remove the throttle, it INVERTS the
-- curve (far away becomes FASTER than close-in), and a sufficiently
-- negative configured value drives the interpolated result negative or to
-- zero even for a NEARBY player, i.e. a Wait(0)-or-worse full-per-frame
-- pulse loop. Clamped to a positive number no smaller than
-- PULSE_MIN_INTERVAL_MS (so the curve can never invert), never asserted at
-- file scope -- a malformed config value must degrade, not take this
-- whole file's load down with it (client/agility.lua's own
-- vaultCooldownMs clamp-and-warn precedent).
local PULSE_MAX_INTERVAL_MS_DEFAULT = 2000
local PULSE_MAX_INTERVAL_MS = PULSE_MAX_INTERVAL_MS_DEFAULT
if ScentHuntConfig.pollIntervalMs ~= nil then
    local configured = ScentHuntConfig.pollIntervalMs
    if type(configured) == 'number' and configured == configured and configured >= PULSE_MIN_INTERVAL_MS then
        PULSE_MAX_INTERVAL_MS = configured
    else
        print(('[qbx_k9unit] ScentTrailHunt: Config.ScentTrailHunt.pollIntervalMs must be a number >= %dms (this file\'s own PULSE_MIN_INTERVAL_MS floor, got %s) -- falling back to the shipped default of %dms. A value below that floor would invert the distance/cadence curve (far away pulsing FASTER than close-in) and, past a certain point, drive the interval to zero or negative -- a Wait(0)-or-worse full-per-frame pulse loop.'):format(PULSE_MIN_INTERVAL_MS, tostring(configured), PULSE_MAX_INTERVAL_MS_DEFAULT))
    end
end

-- Distance (meters) at/beyond which the pulse sits at its slowest. Mirrors
-- server/scenttrail.lua's own default so the felt curve matches the actual
-- hunt-area size even if this client never learns the real config value
-- (Config is a shared_script, so in practice it does -- this fallback only
-- matters if ScentHuntConfig itself is missing).
--
-- CLAMP AND WARN (bug found + fixed this pass, same audit as
-- PULSE_MAX_INTERVAL_MS immediately above): a bare `ScentHuntConfig.maxRadius
-- or 30.0` let a configured `maxRadius = 0` divide-by-zero this file's own
-- IntervalForDistance() below (`t = clamped / PULSE_MAX_DISTANCE_METERS`,
-- i.e. `0 / 0`) -- producing NaN, which then propagates through
-- `PULSE_MIN_INTERVAL_MS + t * (...)` into a NaN passed straight to
-- `Wait(...)` at this file's own poll loop, an unvalidated native argument
-- with no established, verified behavior in this codebase. A negative
-- maxRadius does not crash but silently collapses the whole distance curve
-- to always-closest, defeating the feature. Clamped to a positive number,
-- never asserted at file scope, mirroring PULSE_MAX_INTERVAL_MS_DEFAULT's
-- own reasoning immediately above.
local PULSE_MAX_DISTANCE_METERS_DEFAULT = 30.0
local PULSE_MAX_DISTANCE_METERS = PULSE_MAX_DISTANCE_METERS_DEFAULT
if ScentHuntConfig.maxRadius ~= nil then
    local configuredRadius = ScentHuntConfig.maxRadius
    if type(configuredRadius) == 'number' and configuredRadius == configuredRadius and configuredRadius > 0 then
        PULSE_MAX_DISTANCE_METERS = configuredRadius
    else
        print(('[qbx_k9unit] ScentTrailHunt: Config.ScentTrailHunt.maxRadius must be a positive number of meters (got %s) -- falling back to the shipped default of %.1fm. A non-positive/invalid value here would divide-by-zero this file\'s own distance/cadence curve (NaN fed straight into Wait()).'):format(tostring(configuredRadius), PULSE_MAX_DISTANCE_METERS_DEFAULT))
    end
end

-- Already-shipped, already-mapped ambient growl asset -- see this file's
-- header for the full "why this needs zero new audio assets" writeup.
local PULSE_SOUND_NAME = 'Growl_Ambient'

--- @type boolean -- true while a hunt this client started is in progress (not yet found/stopped/expired)
local huntActive = false
--- @type boolean -- guards CompleteHunt() from running twice for the same hunt (the pushed event and this file's own poll loop can both independently observe "found")
local huntCompleted = false
--- @type boolean -- in-flight guard on StartScentHunt()'s own awaited callback, same shape/reasoning as client/tracking.lua's startInFlight
local startInFlight = false
--- @type number -- staleness token, same shape/reasoning as client/tracking.lua's trackRequestGeneration: bumped by every Start/Stop/Complete so a callback awaited before one of those ran can never resurrect or double-act on a session the player already moved past
local huntGeneration = 0

--- @type number? -- the SERVER-ISSUED id of the hunt this client currently
--- believes is its own live one, or nil when none is tracked -- see this
--- file's header "STALE-SESSION RACE" section. Set from the start response
--- the moment StartScentHunt() succeeds; cleared back to nil the instant
--- StopScentHunt() or CompleteHunt() runs.
local currentHuntId = nil

--- True if a scentHuntFound push carrying `pushedId` belongs to the hunt
--- this client currently tracks -- see this file's header "STALE-SESSION
--- RACE" for the full reasoning behind both branches below.
--- @param pushedId number?
--- @return boolean
local function IsForCurrentHunt(pushedId)
    if pushedId == nil then return true end -- never silently drop an unlabeled push -- see header
    return pushedId == currentHuntId
end

--- Plays one pulse. A one-shot (opts omitted => loop=false) fire-and-forget
--- call -- no id/thread bookkeeping needed, per PlayK9Sound's own doc
--- comment on that shape. No-ops cleanly if PlayK9Sound doesn't currently
--- exist (Config.Features.BasicBarkSounds off -- client/audio.lua never
--- loads/defines it in that case) or this client's own netId doesn't
--- resolve for some reason -- either way the hunt itself still fully
--- functions (poll/found/sit/bark), just silently, matching how this
--- resource's own placeholder-sound convention already degrades
--- everywhere else.
local function PlayPulse()
    if type(PlayK9Sound) ~= 'function' then return end

    local netId = NetworkGetNetworkIdFromEntity(PlayerPedId())
    if not netId or netId == 0 then return end

    PlayK9Sound(netId, PULSE_SOUND_NAME)
end

--- Straight-line interval curve: PULSE_MIN_INTERVAL_MS at 0m, linearly up
--- to PULSE_MAX_INTERVAL_MS at/beyond PULSE_MAX_DISTANCE_METERS. Same
--- "simplest possible curve, not a claim of realism" honesty this
--- resource's client/audio.lua already states for its own analogous
--- DistanceToGain -- a more considered curve is a pure tuning change,
--- flagged (per K9_IDEAS.md §2's own "budget real playtesting time for
--- this, it's easy to get the strength wrong") as worth an actual in-game
--- pass before treating the numbers here as final.
--- @param distance number?
--- @return number intervalMs
local function IntervalForDistance(distance)
    if type(distance) ~= 'number' then return PULSE_MAX_INTERVAL_MS end

    local clamped = math.max(0.0, math.min(distance, PULSE_MAX_DISTANCE_METERS))
    local t = clamped / PULSE_MAX_DISTANCE_METERS
    return PULSE_MIN_INTERVAL_MS + t * (PULSE_MAX_INTERVAL_MS - PULSE_MIN_INTERVAL_MS)
end

--- Unconditional abandon path. NEVER gated on CanShowK9UI()/access of any
--- kind -- see this file's header EVENT/CALLBACK CONTRACT item 3. Bumps
--- huntGeneration so any in-flight Start/poll callback that resolves after
--- this runs discards its result as stale rather than resurrecting the
--- session just abandoned (same race this resource's client/tracking.lua
--- already documents for its own trackRequestGeneration). Safe to call
--- when nothing is active -- server/scenttrail.lua's stopScentHunt handler
--- is an unconditional clear, a harmless no-op if there was nothing to
--- clear.
local function StopScentHunt()
    huntGeneration = huntGeneration + 1
    huntActive = false
    huntCompleted = false
    currentHuntId = nil -- see this file's header "STALE-SESSION RACE" -- this is what a late scentHuntFound push for THIS hunt can no longer match
    TriggerServerEvent('qbx_k9unit:server:stopScentHunt')
end

--- The "trained final response" -- K9_IDEAS.md §1's exact framing reused
--- here rather than a text pop-up: the dog itself reacts (sits, barks),
--- the player is never told "found!" in a toast. Idempotent via
--- huntCompleted -- the pushed 'qbx_k9unit:client:scentHuntFound' event
--- and this file's own poll loop observing `result.found == true` can both
--- independently reach this function for the SAME completed hunt; only the
--- first call does anything.
local function CompleteHunt()
    if huntCompleted then return end
    huntCompleted = true
    huntGeneration = huntGeneration + 1
    huntActive = false
    currentHuntId = nil -- see this file's header "STALE-SESSION RACE"

    -- Tidy up the server-side record immediately rather than leaving it to
    -- Config.ScentTrailHunt.maxHuntDurationMs's own lazy expiry sweep --
    -- see server/scenttrail.lua's ActiveHunts declaration comment for why
    -- an unstopped, found-but-never-cleared record would otherwise sit in
    -- server memory until that timeout.
    TriggerServerEvent('qbx_k9unit:server:stopScentHunt')

    if type(K9Sit) == 'function' then K9Sit() end
    -- Opaque, length-capped passthrough per server/main.lua's relayBark
    -- contract -- 'alert' is well under BARK_TYPE_MAX_LENGTH (16) and,
    -- being absent from client/main.lua's BarkTypeSoundNames table, falls
    -- back to that file's single generic bark sound, exactly like Phase
    -- 1's literal 'bark' already does for every AdvancedBarkRadial-less
    -- server. Server independently re-validates Config.Features.
    -- BasicBarkSounds and HasK9Access regardless of anything this file
    -- claims.
    TriggerServerEvent('qbx_k9unit:server:relayBark', 'alert')
end

-- TRUST-BOUNDARY ORIGIN GUARD (DEVELOPER_REFERENCE.md#trust-boundary,
-- same convention client/screenfx.lua already applies to its own server->
-- client push): `source ~= 65535` is FiveM's documented way to reject a
-- local, zero-server-contact self-TriggerEvent of this same event name.
-- Forging this grants no real advantage (worst case: your own dog sits and
-- barks on your own screen a little early) -- kept anyway for consistency
-- with this resource's standing convention on every server->client push.
RegisterNetEvent('qbx_k9unit:client:scentHuntFound', function(huntId)
    if source ~= 65535 then return end
    if not huntActive then return end -- stale/duplicate push after an already-completed or already-abandoned hunt
    if not IsForCurrentHunt(huntId) then return end -- a late push for a hunt this client has already left behind (see header "STALE-SESSION RACE") -- must not complete a DIFFERENT, still-unsolved hunt early
    CompleteHunt()
end)

--- Polls the server on an INTERVAL (never per-frame -- see this file's
--- header) for as long as `huntActive` and this thread's own captured
--- generation both still match current state, converting the returned
--- live distance into pulse pacing. Own-death handling mirrors
--- client/tracking.lua's identical "FiveM respawn reuses the ped handle,
--- so clear trail state on death explicitly" precedent: a dead K9 must not
--- keep polling from a stale position, and must not silently resume on
--- respawn (a fresh '/k9nosehunt' is required, same as a fresh "Track
--- <Type>" after tracking.lua's own water-break/death cases).
local function EnsureHuntPollThreadRunning()
    CreateThread(function()
        local myGeneration = huntGeneration

        while huntActive and myGeneration == huntGeneration do
            if IsEntityDead(PlayerPedId()) then
                StopScentHunt()
                break
            end

            -- FAIL-CLOSED GUARD, same reasoning/precedent as
            -- client/tracking.lua's StartTrack(): lib.callback.await throws
            -- rather than returning nil on a timeout/rejection. Uncaught
            -- here, a throw would abort this whole CreateThread body,
            -- silently killing the poll loop with huntActive still stuck
            -- true and no further pulses ever firing -- pcall it and treat
            -- a throw the same as any other "nothing usable came back".
            local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:pollScentHunt', false)
            if not ok then result = nil end

            -- Staleness check -- a Stop/Complete that ran while the await
            -- above was pending must not let this stale result resurrect
            -- or double-act on a session the player already moved past.
            if myGeneration ~= huntGeneration then break end

            if not result or not result.active then
                if result and result.expired then
                    lib.notify({ title = locale('common.notify_title'), description = locale('scenttrail.expired'), type = 'info' })
                end
                huntActive = false
                break
            end

            if result.found then
                CompleteHunt()
                break
            end

            PlayPulse()
            Wait(IntervalForDistance(result.distance))
        end
    end)
end

--- Self-initiated entry point. CanShowK9UI() re-checked here purely as a
--- client-side courtesy (server/scenttrail.lua's startScentHunt callback
--- re-validates HasK9Access independently regardless, per this resource's
--- "never trust the caller already checked" standard).
local function StartScentHunt()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if huntActive then
        lib.notify({ title = locale('common.notify_title'), description = locale('scenttrail.already_active'), type = 'error' })
        return
    end

    -- In-flight guard -- same shape/reasoning as client/tracking.lua's
    -- own startInFlight: reject a second concurrent start outright rather
    -- than letting two overlapping lib.callback.await calls race.
    if startInFlight then return end
    startInFlight = true
    huntGeneration = huntGeneration + 1
    local myGeneration = huntGeneration

    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:startScentHunt', false)
    if not ok then result = nil end
    startInFlight = false

    -- Staleness check -- a StopScentHunt() (or another StartScentHunt())
    -- that ran while the await above was pending must not let this stale
    -- result resurrect a session the player already moved past.
    if myGeneration ~= huntGeneration then return end

    if not result or not result.started then
        local reason = result and result.reason
        if reason == 'already_active' then
            lib.notify({ title = locale('common.notify_title'), description = locale('scenttrail.already_active'), type = 'error' })
        elseif reason == 'cooldown' then
            lib.notify({ title = locale('common.notify_title'), description = locale('scenttrail.cooldown'), type = 'error' })
        else
            -- Collapses "feature disabled" / "no access" / any other
            -- server-side rejection to the same generic denial, mirroring
            -- client/tracking.lua's own findTrackableSource "one generic
            -- message, don't invent a distinction the server doesn't give
            -- data for" precedent.
            DenyK9UIAccess()
        end
        return
    end

    huntActive = true
    huntCompleted = false
    currentHuntId = result.huntId -- see this file's header "STALE-SESSION RACE"
    EnsureHuntPollThreadRunning()

    -- START CONFIRMATION. This mechanic deliberately never reveals the
    -- distance or direction to the target -- guidance is meant to come from
    -- the audio pulse, so the player has to work for it. But this resource
    -- ships with several sound files absent (see client/audio.lua's own
    -- disclosure), and on a stock install those degrade to silence. That
    -- left the common case giving NO feedback at all: type the command,
    -- nothing happens, and the hunt is silently live.
    --
    -- This says only that the hunt started. It reveals nothing about where
    -- anything is, so it does not weaken the design -- it just stops a
    -- working feature from looking broken on an install with no custom
    -- audio.
    lib.notify({ description = locale('scenttrail.hunt_started'), type = 'success' })
end

-- '/k9nosehunt' starts a hunt; '/k9nosehunt stop' abandons one. Mirrors
-- this resource's existing command-only entry points for a feature not
-- (yet) wired into client/radial.lua (k9recall, k9calmdown,
-- k9deploykennel) -- see this file's header item 3 for why the radial
-- itself isn't touched by this pass. `false` (not ACE-restricted): access
-- is enforced by CanShowK9UI()/HasK9Access() above and server-side, the
-- same posture every other unrestricted K9 command in this resource uses.
RegisterCommand('k9nosehunt', function(_, args)
    if args[1] and tostring(args[1]):lower() == 'stop' then
        StopScentHunt() -- never gated -- see this file's header EVENT/CALLBACK CONTRACT item 3
        return
    end

    StartScentHunt()
end, false)

-- Resource-stop hygiene -- see this file's header "RESOURCE-STOP HYGIENE"
-- for the full writeup. Mirrors client/pursuitsprint.lua's own
-- onResourceStop handler in shape. NEVER gated on CanShowK9UI()/access of
-- any kind -- StopScentHunt() itself is the same unconditional abandon
-- path '/k9nosehunt stop' already uses, and is always safe to call
-- (including when nothing is active).
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    StopScentHunt()
end)
