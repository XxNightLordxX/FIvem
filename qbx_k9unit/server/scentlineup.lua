--[[
    qbx_k9unit/server/scentlineup.lua

    SCENT LINEUP (Config.Features.ScentLineup) -- PROJECT_HISTORY.md §4, "Scent
    lineup -- 'sniff the row and pick the match'". A certified K9 invites
    several online players to stand in a lineup; the server picks ONE of
    them as "the match" once every invite is accepted, and the K9 makes a
    single, final, committing guess at which one it is. Companion file:
    client/scentlineup.lua (the invite consent dialog only -- see that
    file's header for why everything else is plain NotifyPlayer text).

    ======================================================================
    THE SECURITY SHAPE OF THIS FEATURE -- READ THIS BEFORE CHANGING
    ANYTHING BELOW. This is the one property every other decision in this
    file exists to protect.

    WHERE THE ANSWER LIVES: `Sessions[conductorSrc].matchSrc`, a plain Lua
    table field that exists ONLY in this file's own server-side memory.
    Nothing else in this resource, and no client of any kind (the K9's own
    client included), can read it. It is set exactly once, inside
    LockSession() below, the instant every invited player has accepted --
    picked uniformly at random from that exact set via math.random(), which
    is why NOTHING (not this file, not the conductor, not an omniscient
    modified client) can know the answer before that moment: it does not
    exist as a decided fact until then.

    WHAT THE CLIENT IS TOLD, AND WHEN:
      - Before the pick: the K9's client is told WHO is standing in the
        lineup and in what numbered order (LockSession's roster string,
        e.g. "1) Alice  2) Bob  3) Carol") -- this is safe to reveal in
        full, because the order was shuffled independently of matchSrc and
        carries zero information about which position is correct. It is
        NEVER told which index, if any, matches.
      - The client's ONLY lineup-related outbound message that touches the
        puzzle at all is a single command argument: `/k9lineuppick <N>` --
        one integer, submitted once per session (RegisterCommand handler
        below refuses to run twice against the same session -- see
        CleanupSession). This is a GUESS being asserted, never a question
        being asked: there is no callback, no per-position probe, no
        "am I getting warmer" round trip of any kind anywhere in this file
        or in client/scentlineup.lua. A client that wanted to learn the
        answer before committing would have to guess it exactly the way a
        real human would -- there is no information channel to exploit
        instead.
      - After the pick: `correct` is computed here, server-side, by
        comparing `pickedSrc` to the already-decided `matchSrc`. Only NOW
        is the real match's identity ever sent to any client (via
        NotifyPlayer text to the conductor and every lineup participant) --
        the drill is over at that point, so revealing it is a reward, not a
        leak.

    WHY THIS RULES OUT THE "GROWL GETS SHARPER AS YOU GET CLOSER"
    LIVE-PROXIMITY EFFECT PROJECT_HISTORY.md §4 DESCRIBES -- DELIBERATELY LEFT OUT,
    NOT FORGOTTEN: idea #2's own version of that effect (client/audio.lua's
    distance-scaled gain, client/proximityaudio.lua) works because the
    thing being searched for is a single hidden COORDINATE with no identity
    attached to any visible entity. This feature is the opposite shape: the
    candidates are several already-visible, already-named players standing
    at positions the K9's own client can already see and measure. Feeding
    the client ANY live signal that changes based on proximity to the
    correct one specifically -- audio gain, a screen tint, a numeric
    "getting warmer" readout -- would let an ordinary, unmodified client
    solve the whole puzzle by simply comparing that signal against its own
    already-known distance to each named lineup member, with no exploit or
    mod menu required at all: it is not a client-trust problem, it is a
    plain geometry problem, and no amount of clamping/rounding/rate-limiting
    the signal closes it while it still varies by proximity to the
    specific correct answer. The only signal this file will ever send about
    correctness is the one-shot, post-commit reveal described above.

    ======================================================================
    THE XP DECISION -- ZERO, BY CONSTRUCTION. Read server/training.lua's own
    "THE XP DECISION" header before assuming this needs a smaller/rarer
    award instead of none; the same reasoning applies here, one level worse:

    A completed lineup's "correct" outcome is a uniform 1-in-N random draw
    made by this file itself (see "WHERE THE ANSWER LIVES" above) -- it
    carries NO information about real police work, real detection skill, or
    real suspicion, because none of those inputs exist anywhere in this
    file. Any group of consenting friends can run this drill again and
    again, entirely self-contained, with no vehicle, no NPC, no wanted
    target, no real contraband, and no cooldown floor beyond
    Config.ScentLineup.startCooldownMs -- which bounds how often ONE
    conductor can START a lineup, not how many DIFFERENT willing conductors
    a group of friends could rotate through to keep the drill running
    continuously. That is precisely the shape server/training.lua's own
    header names as "a NINTH farm, and a cheaper one to run than any of the
    eight already found and closed" -- except training mode at least
    requires standing in a configured zone; this feature requires nothing
    but consenting friends. Paying XP for a coin flip that requires zero
    real police work is not a smaller version of that problem, it is the
    same problem with a friendlier premise attached.

    DECISION: this file contains NO call to AwardXP, NO call to
    AwardXPDirect, and reads no field of Config.XP.awards. THE CEILING IS
    0 XP/HOUR, BY CONSTRUCTION -- grep-verifiable, matching
    server/training.lua's own precedent (see tests/scentlineup_spec.lua's
    "no AwardXP reference anywhere in this file's source text" case). The
    genuine payoff this feature offers is the shared multiplayer moment
    PROJECT_HISTORY.md §4 describes ("a whole little scene involving several
    players standing in a row while everyone watches the dog work its way
    down the line") -- that is real value on its own and does not need an
    XP top-up to justify existing.

    ======================================================================
    NO UNBOUNDED TRAP:
      - /k9lineupcancel (below) is reachable by ANY current session member
        (conductor, an invited-but-not-yet-answered player, or an accepted
        participant) with NO HasK9Access/CanUseScentLineup/grant check of
        any kind -- only "are you currently part of a session at all". A
        handler whose certification lapses mid-session, or a participant
        who was never certified in the first place (participants never
        need K9 access -- see below), can always get out.
      - Every session carries an absolute server-side expiry
        (`phaseExpiresAt`) in BOTH of its two phases ('inviting' -- must
        fully fill within Config.ScentLineup.inviteWindowMs, and 'locked'
        -- must receive a pick within Config.ScentLineup.pickWindowMs). A
        background sweep (below) force-cancels and frees everyone the
        instant either window lapses, with no player action required.
      - A disconnect by ANY member (conductor or participant/invitee),
        via the `playerDropped` handler below, immediately tears down the
        whole session and frees everyone still connected in it.
    No path through this file can leave a player stuck waiting on another
    human being who has stopped responding.

    ======================================================================
    WHO NEEDS WHAT ACCESS -- only the CONDUCTOR (the player who runs
    /k9lineup and later /k9lineuppick) needs HasK9Access + the per-person
    grant below. Invited players need NEITHER: a real scent lineup tests
    suspects, who are not K9s -- gating participation on K9 access would
    make the drill unusable against the very population it is meant to
    represent. The only thing participants must do is explicitly consent
    (accept the client-side dialog in client/scentlineup.lua) before
    anything about them is used for anything, mirroring this resource's
    existing leash/partnership consent-handshake convention.

    ======================================================================
    RequireGrant (Config.FeatureControl.RequireGrant.ScentLineup): this
    feature summons named OTHER players into a scene and (at the very end)
    publicly identifies one of them as "the match" -- the same "acts on
    another player, not just on the K9 itself" shape config.lua's own
    comment gives for BiteAndHold/NonLethalTakedown/PropDragging, so it is
    reported to main to be added to that same RequireGrant table, gated
    through the exact same generic HasPermission('feature.ScentLineup' /
    'block.ScentLineup', ...) mechanism client/tablet.lua already drives
    for those four -- see CanUseScentLineup() below for the 4-step
    resolution this file implements from config.lua's own documented order.

    DISCLOSED GAP, NOT INTRODUCED BY THIS FILE: as of this pass,
    server/permissions.lua's IsValidPermissionKey(value) accepts only a
    value that is a literal key of Config.Permissions (the four
    k9.access/k9.certify/k9.audit/k9.givexp capabilities) -- it does not
    yet recognise the 'feature.<Name>'/'block.<Name>' key shape
    client/tablet.lua's grantFeature/blockFeature already send. If that gap
    is still open when this ships, HasPermission('feature.ScentLineup')
    can never return true for anyone (GrantPermission itself would refuse
    to write such a row), meaning ScentLineup fails CLOSED for every
    citizenid until a high-command grant can actually land -- the safe
    direction, but not a usable one. This is not new or specific to this
    feature: it equally blocks the four EXISTING RequireGrant entries
    today. Flagged for coder-security/coder-architect rather than "fixed"
    here -- server/permissions.lua is outside this file's ownership this
    pass.

    DISCOVERABILITY FIX (this pass, no authorization logic touched):
    CanUseScentLineup() used to return a single boolean, and /k9lineup sent
    the SAME 'scentlineup.no_grant' copy ("You don't have permission to run
    a Scent Lineup.") whether the caller was explicitly blocked, simply
    never granted, or had an unresolvable identity (K9Compat's framework
    adapter not yet ready). Those are three different problems with three
    different fixes -- nothing to ask for, a specific grant to request from
    High Command, or a transient state to retry -- and collapsing them left
    the caller unable to tell which applied. CanUseScentLineup() now returns
    a second value ('blocked'|'not_granted'|'identity_unresolved') and the
    command handler below routes each to its own copy via
    SCENTLINEUP_PERMISSION_DENY_MESSAGES. Nothing about WHICH citizenids
    pass or fail changed -- this is a message-routing fix only.

    ======================================================================
    SYSTEM-AGNOSTIC BY CONSTRUCTION: the one piece of durable identity this
    file needs (the CONDUCTOR's citizenid, to consult the per-person
    grant/block above) is resolved through `K9Compat.Get('framework')`
    (shared/compat/core.lua + shared/compat/framework.lua), never through a
    direct `exports.qbx_core` call -- unlike several older files in this
    resource (server/fetch.lua, server/appearance.lua,
    server/propattachment.lua) that still hardcode qbx_core directly, this
    file follows the newer K9Compat seam so it keeps working unchanged on
    whatever framework the operator's adapter resolves to. NOTE:
    `GetCitizenId` is a PLAYER-OBJECT method, not a source-taking one -- its
    contract (shared/compat/framework.lua, DEVELOPER_REFERENCE.md §21) is
    `GetCitizenId(player)`, matching every real framework's own shape (a raw
    connection source number is not a player object and every adapter
    returns nil for one). ResolveCitizenId() below therefore calls
    `framework.GetPlayer(source)` FIRST to get the actual player object, then
    passes THAT to `GetCitizenId`, exactly like server/search.lua/
    server/highcommand.lua's own existing `GetPlayer(src)` then
    `player.PlayerData.X` two-step convention, just through the compat seam
    instead of a direct qbx_core call. If K9Compat is not yet loaded, if no
    framework adapter is resolved at all (the built-in no-op stub, whose
    GetPlayer/GetCitizenId always return nil), or if the resolved player
    can't be found, this two-step call returns nil at either step --
    CanUseScentLineup() below therefore fails CLOSED (denies everyone)
    rather than erroring, exactly the same safe direction as the
    permissions gap above, and self-heals with zero code change here the
    moment a working framework adapter is resolved. Every OTHER identity
    used anywhere in this file is a bare connection `source` number
    (FiveM's own, always-available, zero-dependency identity) -- lineup
    membership, invite state and the match itself are all keyed by source,
    never by citizenid, specifically so this file needs the framework
    adapter for exactly one thing and nothing else.

    Every OTHER native this file calls (GetPlayerPed, GetPlayerName,
    GetGameTimer, math.random) is a bare CFX/Lua primitive, not a
    third-party resource call, and every one used in a way this pass
    verified against a native's own declaration where the correct usage
    was not already proven elsewhere in this resource (see call sites
    below for the individual notes). This file has no `target`/
    `inventory`/`dispatch`/`ambulance` dependency of any kind -- every
    interaction is a plain RegisterCommand/RegisterNetEvent, and the one
    outbound fact this file produces (a resolved lineup) fires on the
    generic `qbx_k9unit:events:scentLineupResolved` channel with zero
    required listener, per server/integrations.lua's own established
    outbound convention.

    ======================================================================
    NO YIELDING CALLS ANYWHERE IN THIS FILE -- NO MUTEX NEEDED. Unlike
    server/partnership.lua's PartnershipEstablishMutex (needed because that
    file's accept path makes real MySQL.*.await calls, a genuine yield a
    second dispatch could interleave through), nothing in this file ever
    touches a database or awaits anything. Every RegisterCommand/
    RegisterNetEvent handler below runs to completion synchronously in one
    uninterrupted pass, so there is no check-then-act window for a second,
    concurrent dispatch of the SAME event to land in the middle of the
    first -- two calls are always fully ordered, never interleaved. This is
    a deliberate design property (this feature is pure in-memory
    coordination, no persistence), not an oversight that happens not to
    have been exploited yet.

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Commands (client -> server, chat commands, restricted=false, every
    check happens INSIDE the handler, per this resource's established
    convention):
    1. '/k9lineup <serverId1> <serverId2> ...>' -- conductor starts a
       lineup and sends an invite to each listed, currently-connected,
       distinct, non-self server id (Config.ScentLineup.minParticipants..
       maxParticipants of them).
    2. '/k9lineuppick <N>' -- conductor's ONE, final, committing guess,
       only accepted once every invite has been accepted (session phase
       'locked'). See "THE SECURITY SHAPE" above.
    3. '/k9lineupcancel' -- ANYONE currently part of a session (any role,
       any phase) abandons it immediately. See "NO UNBOUNDED TRAP" above.

    Net events (client -> server):
    4. 'qbx_k9unit:server:respondScentLineupInvite' (fromServerId: number,
       accepted: boolean) -- an invited player's answer to the dialog
       client/scentlineup.lua showed them. `fromServerId` is NEVER trusted
       as the source of truth by itself -- it must match this file's OWN
       `ParticipantSession[source]` record of who actually invited them, or
       the response is rejected as stale/forged.

    Client events (server -> client):
    5. 'qbx_k9unit:client:scentLineupInvite' (fromServerId: number,
       inviteWindowMs: number) -- sent to one invited player only, never
       broadcast. client/scentlineup.lua's ENTIRE reason to exist.

    Outbound (system-agnostic, zero required listener, per
    server/integrations.lua's own convention):
    6. 'qbx_k9unit:events:scentLineupResolved' (conductorSrc: number,
       correct: boolean) -- fired once, immediately after a pick resolves.

    Automatic: a background sweep thread (phase-expiry enforcement, see
    "NO UNBOUNDED TRAP" above) and a `playerDropped` handler (same
    section).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls `NewCooldown()` (server/cooldowns.lua) at THIS file's own
      file-load time -- must load after server/cooldowns.lua, same
      requirement every other consumer already states.
    - Calls `NotifyPlayer` (server/notify.lua) and `HasK9Access`
      (server/certifications.lua) at RUN time only, with the standard
      `type(...) == 'function'` runtime-existence guard even though both
      are expected to already be loaded (this resource's established
      "guard is not a load-order assumption" convention) -- reported to
      main to place this file after both, mirroring server/kennel.lua's/
      server/medkit.lua's own stated ordering for the identical reason.
    - Calls `HasPermission` (server/permissions.lua), same guard/ordering
      note as above.
    - Calls `K9Compat.Get('framework')` (shared/compat/core.lua, a
      shared_script loaded before every server_script) at RUN time only,
      guarded the same way -- see "SYSTEM-AGNOSTIC BY CONSTRUCTION" above.
    - Exposes NO resource-global function of its own. Nothing outside this
      file (and client/scentlineup.lua, reached only through the
      documented events above) touches this file's state.
    - Never calls AwardXP/AwardXPDirect, never reads Config.XP -- see
      "THE XP DECISION" above.

    CONFIG THIS FILE ASSUMES EXISTS -- reported to main, not owned here:
      Config.Features.ScentLineup           : boolean (new; default false)
      Config.ScentLineup.minParticipants    : positive integer (new; built-in fallback 2)
      Config.ScentLineup.maxParticipants    : positive integer (new; built-in fallback 6)
      Config.ScentLineup.inviteWindowMs     : positive number (new; built-in fallback 30000)
      Config.ScentLineup.pickWindowMs       : positive number (new; built-in fallback 240000)
      Config.ScentLineup.startCooldownMs    : positive number (new; built-in fallback 60000)
      Config.FeatureControl.RequireGrant.ScentLineup : true (new)
    A missing/malformed value for any of the five ScentLineup fields
    degrades to the built-in fallback above with one loud console line,
    mirroring server/training.lua's own ReadPositiveMsOrFallback
    convention -- directly closes this task's own "NewCooldown footgun"
    warning (IsOnCooldown/Consume treat a missing/non-positive threshold as
    PERMANENTLY on, not "no cooldown"), since every one of these values
    eventually reaches either NewCooldown's threshold or a phase-length
    comparison. A missing Config.Features.ScentLineup is treated as
    `false` (whole feature inert), matching this resource's universal
    feature-flag convention.
]]

if not Config.Features.ScentLineup then return end

-- ----------------------------------------------------------------------
-- DEFENSIVE CONFIG READS -- mirrors server/training.lua's
-- ReadPositiveMsOrFallback pattern exactly (a missing/malformed value
-- degrades to a safe built-in default with a loud console print, never an
-- error at file-load time, never a silent wrong value fed straight into
-- NewCooldown -- see this file's header CONFIG section for why this
-- matters specifically for the cooldown/phase-length fields below).
-- ----------------------------------------------------------------------
local MIN_PARTICIPANTS_FALLBACK = 2
local MAX_PARTICIPANTS_FALLBACK = 6
local INVITE_WINDOW_FALLBACK_MS = 30000
local PICK_WINDOW_FALLBACK_MS = 240000
local START_COOLDOWN_FALLBACK_MS = 60000

--- @param value any
--- @param fallback number
--- @param fieldName string
--- @return number
local function ReadPositiveMsOrFallback(value, fallback, fieldName)
    if type(value) == 'number' and value > 0 then return value end
    print(('[qbx_k9unit] scentlineup: Config.ScentLineup.%s is missing or not a positive number; using a built-in %dms default instead.'):format(fieldName, fallback))
    return fallback
end

--- @param value any
--- @param fallback number
--- @param fieldName string
--- @return number
local function ReadPositiveIntOrFallback(value, fallback, fieldName)
    if type(value) == 'number' and value >= 1 and value == math.floor(value) then return value end
    print(('[qbx_k9unit] scentlineup: Config.ScentLineup.%s is missing or not a positive integer; using a built-in %d default instead.'):format(fieldName, fallback))
    return fallback
end

local slCfg = Config.ScentLineup
local minParticipants = MIN_PARTICIPANTS_FALLBACK
local maxParticipants = MAX_PARTICIPANTS_FALLBACK
local inviteWindowMs = INVITE_WINDOW_FALLBACK_MS
local pickWindowMs = PICK_WINDOW_FALLBACK_MS
local startCooldownMs = START_COOLDOWN_FALLBACK_MS

if type(slCfg) == 'table' then
    minParticipants = ReadPositiveIntOrFallback(slCfg.minParticipants, MIN_PARTICIPANTS_FALLBACK, 'minParticipants')
    maxParticipants = ReadPositiveIntOrFallback(slCfg.maxParticipants, MAX_PARTICIPANTS_FALLBACK, 'maxParticipants')
    inviteWindowMs = ReadPositiveMsOrFallback(slCfg.inviteWindowMs, INVITE_WINDOW_FALLBACK_MS, 'inviteWindowMs')
    pickWindowMs = ReadPositiveMsOrFallback(slCfg.pickWindowMs, PICK_WINDOW_FALLBACK_MS, 'pickWindowMs')
    startCooldownMs = ReadPositiveMsOrFallback(slCfg.startCooldownMs, START_COOLDOWN_FALLBACK_MS, 'startCooldownMs')
else
    print('[qbx_k9unit] scentlineup: Config.ScentLineup is missing entirely; using built-in defaults for every tuning value.')
end

if minParticipants > maxParticipants then
    print(('[qbx_k9unit] scentlineup: Config.ScentLineup.minParticipants (%d) exceeds maxParticipants (%d); swapping so max is never smaller than min.'):format(minParticipants, maxParticipants))
    minParticipants, maxParticipants = maxParticipants, minParticipants
end

-- Background sweep cadence -- an implementation detail, not a spec-mandated
-- number, matching server/tracking.lua's TRACKABLE_LOG_PRUNE_INTERVAL_MS
-- precedent for the identical "local constant, not Config.*" reasoning.
local SWEEP_INTERVAL_MS = 5000

-- ----------------------------------------------------------------------
-- STATE -- both keyed by bare connection `source` numbers, never by
-- citizenid (see header "SYSTEM-AGNOSTIC BY CONSTRUCTION"). Ephemeral,
-- in-memory only, matching every other consent-handshake table in this
-- resource (PendingLeashRequests, PendingPartnershipRequests) -- a lineup
-- has no reason to survive a restart.
--
-- Sessions[conductorSrc] = {
--     phase = 'inviting' | 'locked',
--     participants = { [participantSrc] = { accepted = boolean } },
--     order = nil | array of participantSrc, shuffled, only set once locked,
--     matchSrc = nil | number -- SET ONLY ONCE LOCKED. See header. NEVER
--         read by anything other than the /k9lineuppick handler below.
--     createdAt = <GetGameTimer() ms>,
--     phaseExpiresAt = <GetGameTimer() ms> -- absolute deadline for the
--         CURRENT phase; see the sweep thread below.
-- }
-- ----------------------------------------------------------------------
local Sessions = {}

-- ParticipantSession[participantSrc] = conductorSrc -- reverse index so an
-- invited/accepted player's own commands and net events can find their
-- session in O(1), and so this file can refuse to let one player be pulled
-- into two lineups (as invitee/participant) at once, or run their own
-- lineup while already tangled up in someone else's.
local ParticipantSession = {}

-- Single-key-per-source cooldown on STARTING a new lineup (server/
-- cooldowns.lua's NewCooldown; called at THIS file's own file-load time,
-- which is why cooldowns.lua must load first -- see header FILE-TO-FILE
-- CONTRACT). startCooldownMs above has already been defensively validated
-- to be a positive number, closing this task's own "NewCooldown footgun"
-- warning for this specific call site.
local StartCooldown = NewCooldown(startCooldownMs)
StartCooldown.RegisterPlayerDropped()

--- Resolves `src`'s citizenid through the framework compat adapter, never
--- through a direct third-party export -- see header "SYSTEM-AGNOSTIC BY
--- CONSTRUCTION". `GetCitizenId` takes a PLAYER OBJECT, not a bare source
--- number (shared/compat/framework.lua's/README.md's documented contract,
--- matching every real framework's own shape) -- `GetPlayer(src)` is called
--- first to obtain that object, then passed to `GetCitizenId`. Fails closed
--- (returns nil) if K9Compat is not yet loaded for any reason, if the
--- adapter has no framework resolved at all (the built-in no-op stub, whose
--- GetPlayer/GetCitizenId always return nil), if `GetPlayer` can't resolve
--- `src` to a live player object, or if whatever `GetCitizenId` returns is
--- not a real, non-empty string.
--- @param src number
--- @return string? citizenid
local function ResolveCitizenId(src)
    if type(K9Compat) ~= 'table' or type(K9Compat.Get) ~= 'function' then return nil end

    local framework = K9Compat.Get('framework')
    if type(framework) ~= 'table' or type(framework.GetPlayer) ~= 'function'
        or type(framework.GetCitizenId) ~= 'function' then
        return nil
    end

    local player = framework.GetPlayer(src)
    if player == nil then return nil end

    local citizenid = framework.GetCitizenId(player)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    return citizenid
end

--- THE 4-step per-person feature resolution config.lua's own
--- Config.FeatureControl comment documents, implemented here exactly (step
--- 1 -- the global Config.Features.ScentLineup flag -- is checked
--- separately by every caller below, before this function is ever
--- reached, matching how HasK9Access's own "feature off" case is usually a
--- distinct message elsewhere in this resource):
---   2. an explicit block.ScentLineup grant row -> DENY
---   3. ScentLineup listed in RequireGrant -> ALLOW only with a
---      feature.ScentLineup grant row
---   4. otherwise -> ALLOW
--- Fails CLOSED if this file cannot resolve `src`'s own citizenid at all
--- (see ResolveCitizenId above) -- a per-person check with no resolvable
--- person to check can never be answered "allow".
---
--- DISCOVERABILITY FIX (this pass): used to return a single boolean, and
--- /k9lineup below sent the SAME 'scentlineup.no_grant' copy for an
--- explicit block, a missing grant, AND an unresolvable identity alike --
--- three different problems ("nothing to ask for", "ask High Command for
--- this specific grant", "your account could not be verified right now")
--- collapsed into one generic denial that told the caller nothing about
--- which applied or what to do about it. Now returns a second value so the
--- caller can route each to its own copy -- see
--- SCENTLINEUP_PERMISSION_DENY_MESSAGES below.
--- @param src number
--- @return boolean allowed
--- @return ('blocked'|'not_granted'|'identity_unresolved')? denyReason -- nil when allowed == true
local function CanUseScentLineup(src)
    local citizenid = ResolveCitizenId(src)
    if type(citizenid) ~= 'string' then return false, 'identity_unresolved' end

    if type(HasPermission) == 'function' and HasPermission(citizenid, 'block.ScentLineup') then
        return false, 'blocked'
    end

    local requireGrant = type(Config.FeatureControl) == 'table'
        and type(Config.FeatureControl.RequireGrant) == 'table'
        and Config.FeatureControl.RequireGrant.ScentLineup == true

    if requireGrant then
        if type(HasPermission) == 'function' and HasPermission(citizenid, 'feature.ScentLineup') then
            return true
        end
        return false, 'not_granted'
    end

    return true
end

--- Player-facing copy for each of CanUseScentLineup's three denial reasons
--- -- see that function's own doc comment for why these must not collapse
--- back into one message.
local SCENTLINEUP_PERMISSION_DENY_MESSAGES = {
    blocked             = locale('scentlineup.blocked'),
    not_granted         = locale('scentlineup.not_granted'),
    identity_unresolved = locale('scentlineup.identity_unresolved'),
}

--- Best-effort display name for `src`, server-side, via the real CFX
--- native GetPlayerName(playerSrc) (verified: ext/native-decls/
--- GetPlayerName.md, HTTP 200, apiset: server -- a core game native, not a
--- third-party resource call). Falls back to the SAME "Officer #%d" locale
--- key client/partnership.lua/client/movement.lua already use for the
--- identical fallback shape, reused deliberately rather than minting a
--- near-duplicate (this resource's established locale convention).
--- @param src number
--- @return string
local function DisplayName(src)
    local ok, name = pcall(GetPlayerName, src)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return locale('movement.officer_fallback_name', src)
end

--- Builds the numbered roster string sent to the conductor once a lineup
--- locks -- see header "THE SECURITY SHAPE" for why revealing WHO is at
--- each position is safe (it carries no information about WHICH position
--- is correct).
--- @param order number[]
--- @return string
local function BuildRosterLabel(order)
    local parts = {}
    for i, participantSrc in ipairs(order) do
        parts[#parts + 1] = ('%d) %s'):format(i, DisplayName(participantSrc))
    end
    return table.concat(parts, '  ')
end

--- Drops both sides of the bookkeeping for a finished/cancelled session.
--- Safe to call on a session already mid-cleanup (defensive only -- every
--- real call site below calls this at most once per session).
--- @param conductorSrc number
--- @param session table
local function CleanupSession(conductorSrc, session)
    for participantSrc in pairs(session.participants) do
        ParticipantSession[participantSrc] = nil
    end
    Sessions[conductorSrc] = nil
end

--- Cancels an in-progress session for ANY reason, notifying every member
--- still around except `actorSrc` (whoever explicitly triggered this --
--- the calling command/event handler sends that player their OWN, more
--- specific self-message; nil for a reason nobody personally triggered,
--- e.g. a timeout, in which case everyone gets the same broadcast). NEVER
--- gated on HasK9Access/CanUseScentLineup -- see header "NO UNBOUNDED
--- TRAP". No-op (returns false) if `conductorSrc` has no session at all.
--- @param conductorSrc number
--- @param reason 'declined' | 'left' | 'timeout' | string -- any other value reads as a generic cancellation
--- @param actorSrc number? -- the player whose own action caused this, if any; used only to (a) build the "%s left" broadcast text and (b) skip sending that same player the broadcast copy
--- @return boolean cancelled
local function CancelSession(conductorSrc, reason, actorSrc)
    local session = Sessions[conductorSrc]
    if not session then return false end

    local message
    if (reason == 'declined' or reason == 'left') and actorSrc then
        message = locale('scentlineup.cancelled_participant_left', DisplayName(actorSrc))
    elseif reason == 'timeout' then
        message = locale('scentlineup.cancelled_timeout')
    else
        message = locale('scentlineup.cancelled_generic')
    end

    for participantSrc in pairs(session.participants) do
        if participantSrc ~= actorSrc then
            NotifyPlayer(participantSrc, message, 'warning')
        end
    end
    if conductorSrc ~= actorSrc then
        NotifyPlayer(conductorSrc, message, 'warning')
    end

    CleanupSession(conductorSrc, session)
    return true
end

--- Every invite has been accepted -- picks the match, builds the shuffled
--- order, transitions the session to 'locked', and notifies everyone. See
--- header "THE SECURITY SHAPE" for why math.random() here is fine despite
--- not being cryptographically secure: this drill mints zero XP and has no
--- other stake, so there is no incentive strong enough to make predicting
--- Lua's PRNG worth doing, and no information channel (see the "growl"
--- section of the header) exists for a predicted value to be checked
--- against even if someone tried.
--- @param conductorSrc number
--- @param session table
local function LockSession(conductorSrc, session)
    local order = {}
    for participantSrc in pairs(session.participants) do
        order[#order + 1] = participantSrc
    end

    -- Fisher-Yates shuffle. Purely cosmetic (see header -- order carries no
    -- information about matchSrc either way), kept because "the row" being
    -- in invite-typed order every single time would be a needlessly flat
    -- presentation of what PROJECT_HISTORY.md §4 describes as a physical scene.
    for i = #order, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end

    session.order = order
    session.matchSrc = order[math.random(#order)]
    session.phase = 'locked'
    session.phaseExpiresAt = GetGameTimer() + pickWindowMs

    NotifyPlayer(conductorSrc, locale('scentlineup.lineup_ready_conductor', BuildRosterLabel(order), #order), 'success')
    for _, participantSrc in ipairs(order) do
        NotifyPlayer(participantSrc, locale('scentlineup.lineup_ready_participant'), 'info')
    end
end

-- ----------------------------------------------------------------------
-- COMMAND 1: /k9lineup <serverId1> <serverId2> ...>
-- ----------------------------------------------------------------------
RegisterCommand('k9lineup', function(source, args)
    local src = source

    if not Config.Features.ScentLineup then
        NotifyPlayer(src, locale('scentlineup.feature_disabled'), 'error')
        return
    end

    if type(HasK9Access) ~= 'function' or not HasK9Access(src) then
        NotifyPlayer(src, locale('common.no_k9_access'), 'error')
        return
    end

    local permitted, denyReason = CanUseScentLineup(src)
    if not permitted then
        NotifyPlayer(src, SCENTLINEUP_PERMISSION_DENY_MESSAGES[denyReason] or locale('scentlineup.no_grant'), 'error')
        return
    end

    if Sessions[src] or ParticipantSession[src] then
        NotifyPlayer(src, locale('scentlineup.already_running'), 'error')
        return
    end

    if not StartCooldown.Consume(src, startCooldownMs) then
        NotifyPlayer(src, locale('scentlineup.on_cooldown'), 'error')
        return
    end

    if type(args) ~= 'table' or #args == 0 then
        NotifyPlayer(src, locale('scentlineup.usage_start', minParticipants, maxParticipants), 'error')
        return
    end

    local seen = {}
    local targets = {}
    for i = 1, #args do
        local n = tonumber(args[i])
        if not n or n ~= math.floor(n) or n <= 0 then
            NotifyPlayer(src, locale('scentlineup.usage_start', minParticipants, maxParticipants), 'error')
            return
        end
        n = math.floor(n)
        if n == src then
            NotifyPlayer(src, locale('scentlineup.cannot_invite_self'), 'error')
            return
        end
        if seen[n] then
            NotifyPlayer(src, locale('scentlineup.duplicate_participant'), 'error')
            return
        end
        seen[n] = true
        targets[#targets + 1] = n
    end

    if #targets < minParticipants then
        NotifyPlayer(src, locale('scentlineup.too_few_participants', minParticipants), 'error')
        return
    end
    if #targets > maxParticipants then
        NotifyPlayer(src, locale('scentlineup.too_many_participants', maxParticipants), 'error')
        return
    end

    -- Full validation pass BEFORE any state is created -- an invalid
    -- target anywhere in the list must never leave a half-built session
    -- behind, or leave an earlier target in the list already marked busy
    -- with nothing to show for it.
    for _, t in ipairs(targets) do
        if GetPlayerPed(t) == 0 then
            NotifyPlayer(src, locale('scentlineup.invalid_participant', t), 'error')
            return
        end
        if Sessions[t] or ParticipantSession[t] then
            NotifyPlayer(src, locale('scentlineup.target_busy', DisplayName(t)), 'error')
            return
        end
    end

    local now = GetGameTimer()
    local participants = {}
    for _, t in ipairs(targets) do
        participants[t] = { accepted = false }
        ParticipantSession[t] = src
    end

    Sessions[src] = {
        phase = 'inviting',
        participants = participants,
        order = nil,
        matchSrc = nil,
        createdAt = now,
        phaseExpiresAt = now + inviteWindowMs,
    }

    for _, t in ipairs(targets) do
        TriggerClientEvent('qbx_k9unit:client:scentLineupInvite', t, src, inviteWindowMs)
    end

    NotifyPlayer(src, locale('scentlineup.invite_sent_summary', #targets), 'info')
end, false)

-- ----------------------------------------------------------------------
-- NET EVENT: an invited player's response to client/scentlineup.lua's
-- consent dialog.
-- ----------------------------------------------------------------------
RegisterNetEvent('qbx_k9unit:server:respondScentLineupInvite', function(fromServerId, accepted)
    local src = source

    -- `fromServerId` is a CLIENT CLAIM -- never trusted alone. The only
    -- thing that actually decides whether `src` has a live pending invite,
    -- and from whom, is this file's OWN ParticipantSession/Sessions state;
    -- fromServerId is required to MATCH it, not to establish it.
    local conductorSrc = ParticipantSession[src]
    local session = conductorSrc and Sessions[conductorSrc]
    if not conductorSrc or not session or session.phase ~= 'inviting'
        or type(fromServerId) ~= 'number' or conductorSrc ~= fromServerId
        or session.participants[src] == nil then
        NotifyPlayer(src, locale('scentlineup.no_pending_invite'), 'error')
        return
    end

    if session.participants[src].accepted then
        return -- already accepted -- a duplicate/replayed response is a silent no-op, not an error
    end

    if accepted ~= true then
        CancelSession(conductorSrc, 'declined', src)
        NotifyPlayer(src, locale('scentlineup.invite_declined_self'), 'info')
        return
    end

    session.participants[src].accepted = true

    local acceptedCount, total = 0, 0
    for _, p in pairs(session.participants) do
        total = total + 1
        if p.accepted then acceptedCount = acceptedCount + 1 end
    end

    NotifyPlayer(conductorSrc, locale('scentlineup.invite_accepted_progress', DisplayName(src), acceptedCount, total), 'info')

    if acceptedCount == total then
        LockSession(conductorSrc, session)
    end
end)

-- ----------------------------------------------------------------------
-- COMMAND 2: /k9lineuppick <N> -- see header "THE SECURITY SHAPE": this is
-- the ONLY message in this whole feature that touches the puzzle, and it
-- is a one-shot guess, never a query.
-- ----------------------------------------------------------------------
RegisterCommand('k9lineuppick', function(source, args)
    local src = source

    local session = Sessions[src]
    if not session then
        NotifyPlayer(src, locale('scentlineup.not_in_lineup'), 'error')
        return
    end
    if session.phase ~= 'locked' then
        NotifyPlayer(src, locale('scentlineup.not_locked_yet'), 'error')
        return
    end

    local index = tonumber(args and args[1])
    if not index or index ~= math.floor(index) then
        NotifyPlayer(src, locale('scentlineup.usage_pick', #session.order), 'error')
        return
    end
    index = math.floor(index)
    if index < 1 or index > #session.order then
        NotifyPlayer(src, locale('scentlineup.invalid_pick_index', index), 'error')
        return
    end

    local pickedSrc = session.order[index]
    local correct = (pickedSrc == session.matchSrc)
    local matchName = DisplayName(session.matchSrc)

    if correct then
        NotifyPlayer(src, locale('scentlineup.pick_result_correct', matchName), 'success')
    else
        NotifyPlayer(src, locale('scentlineup.pick_result_incorrect', matchName), 'warning')
    end

    for _, participantSrc in ipairs(session.order) do
        NotifyPlayer(participantSrc, locale('scentlineup.pick_result_reveal', matchName), 'info')
    end

    -- Outbound, system-agnostic, zero required listener -- see header.
    -- Deliberately carries `src` (the conductor's own connection id), never
    -- a citizenid: a real listener that wants a durable identity can
    -- resolve one itself while `src` is still valid, exactly like every
    -- other still-online-only outbound payload in this resource. Fired via
    -- the shared FireOutboundEvent (server/events.lua), never a raw
    -- TriggerEvent -- matching all fourteen other `qbx_k9unit:events:*`
    -- call sites in this resource. This one MUST NOT regress back to a bare
    -- TriggerEvent: a throwing handler registered by some other resource on
    -- this event runs synchronously, on this same call stack, and a bare
    -- TriggerEvent would let that exception unwind straight into the
    -- CleanupSession call immediately below, aborting it and leaving this
    -- session stuck in Sessions/ParticipantSession forever -- exactly the
    -- "unbounded trap" this file's header rules out. FireOutboundEvent
    -- pcall-wraps the fire and only ever logs, never re-throws, so
    -- CleanupSession always runs regardless of what any listener does.
    FireOutboundEvent('qbx_k9unit:events:scentLineupResolved', src, correct)

    CleanupSession(src, session)
end, false)

-- ----------------------------------------------------------------------
-- COMMAND 3: /k9lineupcancel -- see header "NO UNBOUNDED TRAP". NO
-- HasK9Access/CanUseScentLineup/grant check anywhere in this handler, by
-- design.
-- ----------------------------------------------------------------------
RegisterCommand('k9lineupcancel', function(source)
    local src = source

    if Sessions[src] then
        CancelSession(src, 'conductor_cancelled', src)
        NotifyPlayer(src, locale('scentlineup.left_lineup_self'), 'info')
        return
    end

    local conductorSrc = ParticipantSession[src]
    if conductorSrc then
        CancelSession(conductorSrc, 'left', src)
        NotifyPlayer(src, locale('scentlineup.left_lineup_self'), 'info')
        return
    end

    NotifyPlayer(src, locale('scentlineup.not_in_lineup'), 'error')
end, false)

-- ----------------------------------------------------------------------
-- AUTOMATIC: phase-expiry sweep -- see header "NO UNBOUNDED TRAP". Removing
-- ONLY the current key of a Lua table mid-`pairs()` traversal (never a
-- DIFFERENT key) is well-defined per the Lua 5.4 reference manual ("you may
-- however clear existing fields"), which is all CancelSession/
-- CleanupSession ever do here (`Sessions[conductorSrc] = nil`) -- safe
-- without a separate collect-then-delete pass.
-- ----------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(SWEEP_INTERVAL_MS)

        local now = GetGameTimer()
        for conductorSrc, session in pairs(Sessions) do
            if now >= session.phaseExpiresAt then
                CancelSession(conductorSrc, 'timeout', nil)
            end
        end
    end
end)

-- ----------------------------------------------------------------------
-- AUTOMATIC: disconnect cleanup -- see header "NO UNBOUNDED TRAP". No
-- attempt is made to resolve the disconnecting player's own display name
-- here (GetPlayerName against an already-dropped source is not reliable);
-- 'disconnect' is not 'declined'/'left'/'timeout' so CancelSession's own
-- branch already falls through to the generic broadcast message, which
-- needs no name at all.
-- ----------------------------------------------------------------------
AddEventHandler('playerDropped', function()
    local src = source

    if Sessions[src] then
        CancelSession(src, 'disconnect', nil)
    end

    local conductorSrc = ParticipantSession[src]
    if conductorSrc then
        CancelSession(conductorSrc, 'disconnect', nil)
    end
end)
