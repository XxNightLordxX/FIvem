--[[
    qbx_k9unit/client/sarcalls.lua

    Missing-person / search-and-rescue calls -- K9_IDEAS.md §3. Client half
    of server/sarcalls.lua -- read that file's header in full first; it is
    the authoritative contract for the hunt mechanic itself (where the
    target is, how the hint tiers are decided, the XP/anti-farm reasoning,
    and why the target coordinate never reaches this file at all). This
    file owns exactly two things server/sarcalls.lua deliberately never
    touches: turning a pushed hint tier into something the player feels,
    and the one-off cosmetic "you found it" reveal.

    ======================================================================
    WHY THE REVEAL IS NEVER NETWORKED (the load-bearing decision in this
    file -- read this before touching ShowReveal/ClearReveal below):
    server/sarcalls.lua's own header names this resource's two prior entity
    bugs (kennel's arbitrary-entity-deletion history, propattachment's
    netId race) and states plainly that this feature's answer is to never
    create anything with an identity another piece of code could reference
    while the call is still active. The SAME reasoning applies to the
    reveal this file spawns AFTER the call resolves: it is created with
    `isNetwork = false` on both the CreatePed and CreateObject call sites
    below, which means it is NEVER given a network id at all. There is
    therefore structurally nothing here to hand to
    server/entities.lua's ClaimNetworkEntity/ResolveNetworkEntity registry,
    nothing another client could ever reference by netId, and nothing a
    modified client could ever point THIS feature's own cleanup at to
    delete something it does not own -- the entity is only ever reachable
    through this file's own private `revealEntity` local, by this same
    client, for as long as this same client's own game process considers
    it alive. It is deleted by the exact client that created it, on a
    plain client-side timer (Config.SARCalls.revealDurationMs), and again,
    defensively, on this resource stopping -- see ClearReveal/the
    onResourceStop handler below. This mirrors client/bonetool.lua's own
    established "CreateObject's isNetwork = false -- a purely local visual
    aid" precedent, extended here to a ped for the first time in this
    resource.

    A CONSEQUENCE WORTH STATING EXPLICITLY: because the reveal is never
    networked, only the FINDING player's own client ever sees it -- no
    other nearby player, however close, will see the rescued hiker/found
    item appear. That is a real, disclosed trade-off (K9_IDEAS.md's own
    "a short visual effect on one specific player's own screen" precedent,
    client/screenfx.lua) chosen deliberately over the alternative (a real,
    networked, claimed-and-tracked entity everyone could see), because the
    alternative reintroduces exactly the entity-lifecycle risk this whole
    feature exists to avoid, for a purely cosmetic payoff. A future pass
    that wants a shared multiplayer reveal moment would need to do that
    properly (client creates, networks, reports the netId to
    server/sarcalls.lua, server claims it via server/entities.lua's shared
    registry, server owns its cleanup with the same rigor kennel/fetch/
    propattachment already do) -- not attempted here, and not a small
    addition on top of this file, a structurally different feature.

    ======================================================================
    HOW THE FEEDBACK WORKS, AND WHY IT DIFFERS FROM client/scenttrail.lua's
    CONTINUOUS PULSE-PACING: that file (K9_IDEAS.md §2) encodes distance in
    the CADENCE of a repeating one-shot pulse (closer = faster pulses).
    This file instead reacts only to DISCRETE TIER CHANGES pushed by
    server/sarcalls.lua ('cold'/'warm'/'hot'/'burning') -- one notification
    and, for the two closer tiers, one bark-family sound, per tier crossed,
    never a continuous loop. This is a deliberate, simpler choice for this
    feature (a "getting warmer" search over a much larger area -- up to
    Config.SARCalls.maxRadius meters -- than Scent Trail Hunt's tighter
    hunt radius), not a claim that it feels better -- K9_IDEAS.md §2/§3's
    own "budget real playtesting time for this" caution applies equally
    here: HONEST CONFIDENCE GRADING, stated plainly rather than presented
    as tuned: the exact distances in Config.SARCalls (burningDistance/
    hotDistance/warmDistance) and which sound plays at which tier are a
    first-pass judgment call, not something verified to feel good in-game
    this session. The mechanic is correct and safe; the FEEL of it is
    exactly the kind of thing this resource's own K9_IDEAS.md repeatedly
    warns needs an actual playtest before being treated as final.

    Sounds reused, zero new assets needed (all four already ship per
    fxmanifest.lua's files{} block, confirmed by directory listing before
    writing this file: html/sounds/{bark,bark_aggressive,bark_alert,
    bark_calm,growl_ambient}.ogg):
      'warm'    -> 'Growl_Ambient' (the same already-shipped ambient growl
                   key client/scenttrail.lua/client/proximityaudio.lua use)
      'hot'     -> 'Bark_Calm'
      'burning' -> 'Bark_Alert'
      'found'   -> 'Bark_Alert' again, PLUS K9Sit() -- the "trained final
                   response" (K9_IDEAS.md §1's exact framing, reused here
                   verbatim per §3's own suggestion, exactly like
                   client/scenttrail.lua's CompleteHunt already does).
      'cold'    -> no sound, notification only (this resource's own
                   "watch out for... doing it so often it gets annoying"
                   caution, K9_IDEAS.md §1, applies just as much to a
                   losing-interest cue as a gaining-interest one).
    Every PlayK9Sound call is a ONE-SHOT (opts omitted => loop = false, per
    that function's own doc comment) against THIS client's own ped's own
    netId as the "source entity" -- identical shape/reasoning to
    client/scenttrail.lua's PlayPulse: gain is always 1.0 (distance to
    self is always 0), which is intentional, not a missed opportunity --
    the felt cue here is WHICH sound plays and WHEN, not its volume.

    ======================================================================
    NATIVE VERIFICATION -- CreatePed, the one native in this whole feature
    that is new to this resource (client or server): ext/native-decls/
    CreatePed.md 404s -- a legacy R* native with no CFX decl page, which
    per this repo's own .luacheckrc header ("a 404 alone is never grounds
    to reject a native") is NOT proof of absence. Checked instead against
    the natives.json hash database (runtime.fivem.net/doc/natives.json,
    fetched 2026-08-25, HTTP 200): namespace PED, hash
    0xD49F9B0955C367DE, name CREATE_PED, params (pedType, modelHash, x, y,
    z, heading, isNetwork, bScriptHostPed), and critically NO `apiset` key
    at all -- which, per this exact repo's own already-established reading
    of that same database for SetPlayerModel (.luacheckrc's own comment on
    that entry: "NO apiset key -- which for that database means the
    default, client-only"), means CREATE_PED is CLIENT-ONLY. This resource
    therefore never calls CreatePed from server/sarcalls.lua (confirmed by
    that file's own header) -- this file is its only call site, called only
    from client code, which is the realm that database entry actually
    supports. CreateObject's argument order (modelHash, x, y, z, isNetwork,
    netMissionEntity, doorFlag) was cross-checked the same way (hash
    0x509D5878EB39E842, ns OBJECT) before writing ShowReveal below, purely
    to confirm the boolean argument ORDER this file passes matches
    client/kennel.lua's own already-shipped, already-working call --
    CreateObject itself is not new to this resource and needed no fresh
    apiset verification.

    Every other native this file uses (RequestModel, HasModelLoaded,
    SetModelAsNoLongerNeeded, IsModelValid, GetHashKey, DoesEntityExist,
    DeleteEntity, FreezeEntityPosition, TaskStartScenarioInPlace,
    GetOffsetFromEntityInWorldCoords, GetEntityHeading, PlayerPedId,
    NetworkGetNetworkIdFromEntity, GetGameTimer, CreateThread, Wait) is
    already allowlisted in the repo-root .luacheckrc read_globals list from
    this resource's existing usage elsewhere -- no fresh verification
    needed for any of them.

    ======================================================================
    EVENT/CALLBACK CONTRACT (server side: server/sarcalls.lua, restated
    here from this file's point of view):
    1. 'qbx_k9unit:server:requestSarCall' () -> { started: boolean, reason:
       ('already_active'|'cooldown'|'denied')?, callId: number? [present
       iff started == true -- see "STALE-SESSION RACE" below] } [lib.callback]
    2. 'qbx_k9unit:server:abandonSarCall' () [RegisterNetEvent, this file
       only ever SENDS this] -- UNCONDITIONAL, see RequestAbandonSarCall
       below: never gated on CanShowK9UI()/access of any kind, and NEVER
       takes or needs a callId -- see "STALE-SESSION RACE" below for why.
    3. 'qbx_k9unit:client:sarHintTierChanged' (tier: string, callId: number)
       [RegisterNetEvent, server -> this caller's client only, never
       broadcast]
    4. 'qbx_k9unit:client:sarCallEnded' (reason: string, callType: string?,
       callId: number) [RegisterNetEvent, server -> this caller's client
       only]
    Both server->client pushes carry the standard TRUST-BOUNDARY ORIGIN
    GUARD (`source ~= 65535` -- FiveM's documented sentinel for "this event
    genuinely came from the server," DEVELOPER_REFERENCE.md#trust-boundary,
    the exact same convention client/screenfx.lua and client/scenttrail.lua
    already apply to their own server->client pushes). Forging either
    grants no real advantage here (worst case: a spurious notification/
    sound, or an early cosmetic reveal spawned at your own feet) -- kept
    anyway for consistency with this resource's standing convention on
    every server->client push.

    ======================================================================
    STALE-SESSION RACE -- ADDED A LATER PASS (found by a client-side sweep;
    not present when this file was first written):

    THE BUG: RequestAbandonSarCall() below clears the local `sarCallActive`
    flag and fires abandonSarCall, but a player who immediately starts a NEW
    call via RequestStartSarCall() begins a fresh lib.callback.await while
    the OLD call's own server-side echo (sarCallEnded, reason 'abandoned')
    may still be in flight back to this same client. That echo's handler
    used to bump `requestGeneration` UNCONDITIONALLY -- it had no way to
    tell "a late echo of the call I already left" from "a newer start
    already in flight" -- so if it landed while the new start's own await
    was still pending, the new call's own successful grant would be
    discarded as stale (myGeneration ~= requestGeneration by the time it
    returned), leaving `sarCallActive` stuck false for a call the server was
    running fully live. Every sarHintTierChanged push for that live call was
    then silently dropped (that handler gates on sarCallActive) for the rest
    of the call, with no error, no notify, nothing -- only the eventual
    found/timeout push (which carries no such gate) would ever land, making
    the call LOOK like it simply had no hints, not that it silently broke.

    THE FIX: server/sarcalls.lua now mints a small, server-issued,
    monotonically increasing session id once per call (never
    client-generated -- a client-generated id could be spoofed or
    duplicated) and includes it on every push belonging to that call: the
    requestSarCall grant's own `callId` field, every sarHintTierChanged
    push, and every sarCallEnded push (found/timeout/abandoned alike).
    `currentSarCallId` below tracks the id THIS client currently believes is
    its own live call. IsForCurrentSarCall(pushedId) is the one place that
    decides whether an incoming push belongs to that session:
      - a push carrying NO id at all (pushedId == nil) is ALWAYS ACCEPTED,
        deliberately, never silently dropped -- a stricter default here
        would mean a single future TriggerClientEvent call site that
        forgets to pass its callId (there are four of them in
        server/sarcalls.lua) silently reintroduces THIS EXACT bug in a
        different shape: a whole class of pushes going dark with no error
        anywhere. Accepting an unlabeled push degrades this mechanism back
        to its own pre-fix behavior for that one push only, never to a
        stuck-forever session.
      - a push carrying a REAL id is accepted only if it matches
        `currentSarCallId` exactly. RequestAbandonSarCall() below sets
        `currentSarCallId = nil` the moment it runs (mirroring its own
        already-immediate `sarCallActive = false`) -- this is what makes the
        fix actually close the race: from that instant on, the OLD call's id
        can never again equal whatever this client currently believes is
        current (nil until a new call's own grant arrives, then that new
        call's own, different, id), so a late echo for the old call is
        rejected outright rather than resurrecting the "unconditionally
        bump the generation counter" bug above. This is symmetric with
        client/scenttrail.lua's own currentHuntId/IsForCurrentHunt fix for
        the analogous bug in that file -- same shape, same reasoning, one
        pattern for a reader who has already read either file once.

    NOT A TERMINATION-PATH CHANGE: RequestAbandonSarCall() below remains
    exactly as unconditional as it already was -- it never reads, checks, or
    sends any callId at all, and this fix adds nothing it needs to. A client
    holding a stale, wrong, or nil `currentSarCallId`, for any reason, can
    always still call RequestAbandonSarCall() and have the server clean its
    own side up -- the id mechanism only ever decides whether THIS CLIENT
    acts on an incoming push, never whether the server accepts a
    termination request. See this resource's standing "no unbounded trap"
    rule, which this fix does not touch.

    ======================================================================
    RESOURCE-STOP HYGIENE -- FIXED THIS PASS (found by a client-side sweep;
    not present when this file was first written). client/pursuitsprint.lua
    already resets its own state on `onResourceStop`; this file's own
    `onResourceStop` handler used to call ONLY ClearReveal() -- purely
    cosmetic cleanup of the local, never-networked reveal entity -- and
    never told server/sarcalls.lua to release ActiveSarCalls[source]. A
    client-side stop (this resource's own copy being independently
    restarted, or the FXServer client runtime unilaterally stopping just
    THIS client's copy after repeated script errors -- a real,
    server-independent event) left that record behind, blocking a fresh
    '/k9sarcall' with reason = 'already_active' until it cleared on its own.

    LOWER SEVERITY THAN client/scenttrail.lua's OWN IDENTICAL GAP (see that
    file's own header "RESOURCE-STOP HYGIENE" for the contrast): unlike
    server/scenttrail.lua's lazy, poll-driven expiry,
    server/sarcalls.lua runs an unconditional periodic tick loop (see that
    file's own "ACTIVE TICK LOOP" header) that keeps re-checking every
    active call on its own schedule regardless of whether this client is
    still talking to it -- so an orphaned ActiveSarCalls[source] entry
    already self-cleared within Config.SARCalls.maxCallDurationMs (eight
    minutes) even before this fix. That is still a real, disclosed,
    player-facing lockout window, not merely cosmetic -- eight minutes
    unable to take a new call is a genuine bug, just a bounded one -- and
    this fix makes the cleanup immediate instead of waiting on that timer.

    THE FIX: the `onResourceStop` handler below now also calls
    RequestAbandonSarCall() -- the exact same unconditional abandon path
    '/k9sarcall stop' already uses, so this is not a new code path, just a
    new caller of an existing, already-safe-to-call-anytime one. NEVER
    gated on CanShowK9UI()/access of any kind, per this file's own standing
    "no unbounded trap" rule (see RequestAbandonSarCall()'s own doc
    comment). Moved to the bottom of this file, after both
    RequestAbandonSarCall() and ClearReveal() are defined, purely for
    readability -- Lua's own closure semantics mean the handler could have
    referenced either from its original position just as safely, since
    neither is called until the event actually fires.

    ======================================================================
    FILE-TO-FILE CONTRACT: this file exposes exactly two resource-global
    (no `local`) functions, the established "global helper, private
    per-file state" convention (client/recall.lua's RequestRecall,
    client/combat.lua's RequestBiteHold/RequestDrag are the precedent this
    follows):
        RequestStartSarCall()  -- self-initiated, gated (CanShowK9UI()).
        RequestAbandonSarCall() -- UNCONDITIONAL, never gated -- see its
            own doc comment for why, mirroring client/recall.lua's
            RequestRecall/client/scenttrail.lua's StopScentHunt exactly.
    Neither is wired into client/radial.lua by this pass -- that file is
    owned by another agent this session and has no dynamic "add an item"
    seam to hook into without editing it directly (the identical disclosed
    gap client/scenttrail.lua's own header already reports for itself).
    Reachable today via '/k9sarcall' (start) / '/k9sarcall stop' (abandon),
    the same command-with-a-stop-argument shape client/scenttrail.lua's
    '/k9nosehunt [stop]' already established for this exact class of
    feature, rather than two separate commands (client/recall.lua's/
    client/kennel.lua's older single-purpose-command shape) -- picked here
    for consistency with the freshest, most directly comparable precedent
    in this codebase, not because the older shape was wrong.
    Calls CanShowK9UI()/DenyK9UIAccess() (client/main.lua), K9Sit()
    (client/movement.lua) and PlayK9Sound() (client/audio.lua), every one
    behind a `type(fn) == 'function'` runtime-existence guard -- no
    load-order assumption on any of them, so this file's own position in
    fxmanifest.lua's client_scripts list does not matter relative to any of
    the three.

    ======================================================================
    A GAP DISCLOSED, NOT FIXED: this file does not detect the local
    player's own death/downed state mid-call the way client/scenttrail.lua
    explicitly does for its own poll loop (IsEntityDead(PlayerPedId())
    aborting the hunt). This file has no continuous client-side loop to put
    that check in at all -- every distance measurement happens entirely
    server-side, on server/sarcalls.lua's own tick, driven by that file's
    own GetEntityCoords(GetPlayerPed(source)) read, which keeps working
    (reading a downed ped's last position) whether or not the local player
    is currently alive. A K9 who goes down mid-call therefore simply keeps
    being measured against wherever their body currently is -- not wrong,
    not exploitable (arriving is still real distance travelled, downed or
    not), just a minor experiential rough edge (no explicit "search paused,
    you're down" feedback) left for a future pass rather than added here.
]]

if not Config.Features.SARCalls then return end

local tuning = Config.SARCalls or {}

-- ======================================================================
-- CLIENT-SIDE CONFIG-SAFETY GUARD -- scoped to ONLY the three fields THIS
-- file reads (missingPersonPedModel/lostPropertyPropModel/revealDurationMs
-- -- server/sarcalls.lua's own guard covers every other Config.SARCalls
-- field, which THAT file reads and this one never touches).
--
-- CLAMP AND WARN, NOT ASSERT (this pass -- see server/cooldowns.lua's
-- header ADDENDUM: "does an operator's config.lua edit alone... reach this
-- value? If yes it must be clamped and warned about, never asserted and
-- aborted"). This used to be three hard `assert`s here, correctly
-- diagnosing a real risk but with the wrong remedy: an uncaught error
-- thrown from THIS FILE's own top-level chunk (this guard sits directly
-- after the feature-flag early-return above, with no deferring
-- onResourceStart/RegisterNetEvent wrapper around it) aborts
-- client/sarcalls.lua's load from that line onward, silently un-registering
-- every SAR-call net event/callback handler this file defines below --
-- the entire client half of the feature, over one operator typo in a
-- cosmetic model name or a duration. Substituting a safe built-in default
-- and printing a loud, exact-key warning keeps this file's own registrations
-- intact while the config gets fixed.
-- ======================================================================
if type(tuning.missingPersonPedModel) ~= 'string' or tuning.missingPersonPedModel == '' then
    print(
        ("[qbx_k9unit] Config.SARCalls.missingPersonPedModel must be a non-empty string (found: %s). Using the " ..
         "built-in fallback of 'mp_m_freemode_01' instead so this feature keeps working while the config is " ..
         "fixed -- find Config.SARCalls.missingPersonPedModel in config.lua and set it to a real ped model name."
        ):format(tostring(tuning.missingPersonPedModel))
    )
    tuning.missingPersonPedModel = 'mp_m_freemode_01'
end
if type(tuning.lostPropertyPropModel) ~= 'string' or tuning.lostPropertyPropModel == '' then
    print(
        ("[qbx_k9unit] Config.SARCalls.lostPropertyPropModel must be a non-empty string (found: %s). Using the " ..
         "built-in fallback of 'prop_tennis_ball' instead so this feature keeps working while the config is " ..
         "fixed -- find Config.SARCalls.lostPropertyPropModel in config.lua and set it to a real prop model name."
        ):format(tostring(tuning.lostPropertyPropModel))
    )
    tuning.lostPropertyPropModel = 'prop_tennis_ball'
end
if type(tuning.revealDurationMs) ~= 'number' or tuning.revealDurationMs ~= tuning.revealDurationMs or tuning.revealDurationMs <= 0 then
    print(
        ('[qbx_k9unit] Config.SARCalls.revealDurationMs must be a positive number (found: %s). Using the ' ..
         'built-in fallback of 15000ms instead so this feature keeps working while the config is fixed -- find ' ..
         'Config.SARCalls.revealDurationMs in config.lua and set it to a positive number of milliseconds.'
        ):format(tostring(tuning.revealDurationMs))
    )
    tuning.revealDurationMs = 15000
end

-- Mirrors client/kennel.lua's own REQUEST_MODEL_TIMEOUT_MS value exactly
-- (5000ms) -- not extracted into a shared global (that file's own model-load
-- helper is `local`, per this resource's established "private per-file
-- state" convention for a small, single-purpose helper -- see this file's
-- own LoadModelWithTimeout below, a deliberate independent copy, not a
-- shared extraction this pass does not own the authority to make).
local REQUEST_MODEL_TIMEOUT_MS = 5000

--- Loads `modelName`, waiting up to REQUEST_MODEL_TIMEOUT_MS. Returns the
--- model hash on success, or nil (releasing any streaming reference it took
--- along the way) on an invalid name or a load timeout -- mirrors
--- client/kennel.lua's LoadModelWithTimeout byte-for-byte in shape (a
--- private copy, not a shared extraction this pass does not own the
--- authority to make).
--- @param modelName string
--- @return number? modelHash
local function LoadModelWithTimeout(modelName)
    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then return nil end

    RequestModel(modelHash)
    local waited = 0
    while not HasModelLoaded(modelHash) and waited < REQUEST_MODEL_TIMEOUT_MS do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        SetModelAsNoLongerNeeded(modelHash) -- release the streaming reference RequestModel took above -- see client/kennel.lua's own identical comment for why this matters on the failure path specifically
        return nil
    end

    return modelHash
end

--- @type boolean -- true while a call THIS client started is active (not yet found/abandoned/expired)
local sarCallActive = false

--- @type number -- staleness token. Bumped by every start attempt, abandon
--- and sarCallEnded push, so an in-flight requestSarCall await that
--- resolves AFTER one of those already ran can never resurrect or
--- double-act on a session the player already moved past -- same shape/
--- reasoning as client/tracking.lua's trackRequestGeneration and
--- client/scenttrail.lua's huntGeneration.
local requestGeneration = 0

--- @type boolean -- in-flight guard on RequestStartSarCall()'s own awaited
--- callback, same shape/reasoning as client/tracking.lua's startInFlight
--- and client/scenttrail.lua's startInFlight.
local startInFlight = false

--- @type number? -- the SERVER-ISSUED id of the call this client currently
--- believes is its own live one, or nil when none is tracked -- see this
--- file's header "STALE-SESSION RACE" section. Set from the grant response
--- the moment RequestStartSarCall() succeeds; cleared back to nil the
--- instant RequestAbandonSarCall() runs (before the server has even
--- acknowledged it) and again once a genuine sarCallEnded push for the
--- CURRENT session is processed.
local currentSarCallId = nil

--- True if a push carrying `pushedId` belongs to the session this client
--- currently tracks -- see this file's header "STALE-SESSION RACE" for the
--- full reasoning behind both branches below.
--- @param pushedId number?
--- @return boolean
local function IsForCurrentSarCall(pushedId)
    if pushedId == nil then return true end -- never silently drop an unlabeled push -- see header
    return pushedId == currentSarCallId
end

-- ======================================================================
-- THE COSMETIC REVEAL -- see this file's header "WHY THE REVEAL IS NEVER
-- NETWORKED" for the full design writeup this section implements.
-- ======================================================================

--- @type number -- the currently-alive reveal entity's handle, or 0 if none
local revealEntity = 0
--- @type number -- staleness token for the reveal's own auto-clear timer, same shape as requestGeneration above
local revealGeneration = 0

--- Deletes the current cosmetic reveal entity, if any, and invalidates any
--- pending auto-clear timer for it. Safe to call at any time, including
--- when nothing is active. NEVER resolves a netId of any kind -- revealEntity
--- is always a handle THIS client itself created moments earlier via
--- CreatePed/CreateObject with isNetwork = false, so this is a plain,
--- ordinary DeleteEntity on a locally-owned, never-networked handle, never
--- the arbitrary-entity-deletion shape server/kennel.lua's own history
--- warns against (that bug was about a netId RESOLVED from a claim another
--- party could make; there is no netId here for anyone to claim at all).
local function ClearReveal()
    revealGeneration = revealGeneration + 1
    if revealEntity ~= 0 and DoesEntityExist(revealEntity) then
        DeleteEntity(revealEntity)
    end
    revealEntity = 0
end

--- Spawns the cosmetic, non-networked "you found it" reveal at THIS
--- client's own current position -- see this file's header for why no
--- coordinate is ever needed from the server for this (the call has
--- already resolved by the time this runs; wherever this client's ped
--- currently stands IS, by construction, within
--- Config.SARCalls.arrivalRadius of the real hidden target). A model-load
--- failure (an operator-misconfigured or not-yet-streamed model name)
--- degrades to a silent no-op here -- the XP/notification/outbound-event
--- side of the completion has ALREADY happened server-side by the time
--- this runs (server/sarcalls.lua's EndSarCall), so a failed cosmetic
--- reveal costs the player nothing beyond the visual itself, mirroring
--- this resource's own established "a placeholder/failed asset degrades to
--- nothing, never to a broken reward" posture.
--- @param callType string -- 'person' | 'property'
local function ShowReveal(callType)
    ClearReveal() -- defensive: a stray leftover from an earlier call this same session should never linger underneath a new one
    local myGeneration = revealGeneration -- captured AFTER ClearReveal's own bump above, so THIS attempt's own timer has its own fresh token

    local ped = PlayerPedId()
    local offset = GetOffsetFromEntityInWorldCoords(ped, 0.0, 1.5, 0.0)
    local heading = GetEntityHeading(ped)

    local newEntity
    if callType == 'person' then
        local modelHash = LoadModelWithTimeout(tuning.missingPersonPedModel)
        if not modelHash then return end

        -- CreatePed(pedType, modelHash, x, y, z, heading, isNetwork,
        -- bScriptHostPed) -- pedType is documented as unused by this
        -- native ("Peds get set to CIVMALE/CIVFEMALE/etc. no matter the
        -- value specified"), any value is equivalent; 4 is passed for no
        -- reason beyond matching a commonly-seen convention in published
        -- examples. isNetwork = false, bScriptHostPed = false -- see this
        -- file's header "WHY THE REVEAL IS NEVER NETWORKED": this ped is
        -- never networked, never given a network id, at all.
        newEntity = CreatePed(4, modelHash, offset.x, offset.y, offset.z, heading, false, false)
        SetModelAsNoLongerNeeded(modelHash)
        if not DoesEntityExist(newEntity) then return end

        -- Best-effort idle animation -- a harmless no-op if this scenario
        -- name is not recognized on this client's game data (this native
        -- does not error either way; see this resource's own established
        -- "an unrecognized scenario/sound name degrades silently" posture,
        -- e.g. client/wellbeing.lua's own TaskStartScenarioInPlace usage).
        TaskStartScenarioInPlace(newEntity, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    else
        local modelHash = LoadModelWithTimeout(tuning.lostPropertyPropModel)
        if not modelHash then return end

        -- CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity,
        -- doorFlag) -- argument order cross-checked against the natives.json
        -- hash database before writing this (see this file's header NATIVE
        -- VERIFICATION section). isNetwork = false: same "never networked"
        -- reasoning as the ped branch above, extending client/bonetool.lua's
        -- own established isNetwork = false precedent for CreateObject.
        newEntity = CreateObject(modelHash, offset.x, offset.y, offset.z, false, true, false)
        SetModelAsNoLongerNeeded(modelHash)
        if not DoesEntityExist(newEntity) then return end

        FreezeEntityPosition(newEntity, true)
    end

    -- STALE-REVEAL GUARD (same bug class as client/kennel.lua's own
    -- "STALE-KENNEL GUARD" and client/vision.lua's own "STALE-CAM GUARD" on
    -- ToggleCameraFeed -- read either one first, not re-derived here). Both
    -- LoadModelWithTimeout branches above can YIELD (their own Wait(50)
    -- polling loop) before reaching this line. If a SECOND ShowReveal() call
    -- for a genuinely NEWER sar call (this client finishing one call,
    -- immediately starting and completing another before the first
    -- reveal's own model ever finished loading) ran its OWN ClearReveal()
    -- and full creation sequence to completion WHILE this attempt was still
    -- stuck waiting on its model, `revealGeneration` has already moved past
    -- `myGeneration` -- assigning THIS attempt's now-stale `newEntity` into
    -- `revealEntity` unconditionally would silently overwrite/orphan
    -- whatever that newer, now-current attempt already created (or is still
    -- creating): nothing would hold this stale entity's handle again, so
    -- ClearReveal()/onResourceStop below could never delete it. Detected
    -- with the exact same generation-counter this function's own
    -- auto-clear timer below already uses for the identical staleness
    -- question, just checked one step earlier (at creation, not only at
    -- auto-clear time).
    if myGeneration ~= revealGeneration then
        if DoesEntityExist(newEntity) then
            DeleteEntity(newEntity)
        end
        return
    end

    revealEntity = newEntity

    CreateThread(function()
        Wait(tuning.revealDurationMs)
        if myGeneration == revealGeneration then -- nothing else (a resource stop, an earlier/later ShowReveal) already cleared this
            ClearReveal()
        end
    end)
end

--- Plays one one-shot sound against THIS client's own ped's own netId --
--- see this file's header "HOW THE FEEDBACK WORKS" for why gain is always
--- 1.0 here and that is intentional. Silently no-ops (never errors) if
--- PlayK9Sound doesn't currently exist (Config.Features.BasicBarkSounds
--- off -- client/audio.lua never defines it in that case) or this client's
--- own netId doesn't resolve for some reason -- either way the hint feed
--- itself still fully functions (notification text always fires
--- regardless), just silently on the audio side, matching how this
--- resource's own placeholder-sound convention already degrades
--- everywhere else. Mirrors client/scenttrail.lua's PlayPulse exactly.
--- @param soundName string
local function PlayOwnPedSound(soundName)
    if type(PlayK9Sound) ~= 'function' then return end

    local netId = NetworkGetNetworkIdFromEntity(PlayerPedId())
    if not netId or netId == 0 then return end

    PlayK9Sound(netId, soundName)
end

--- Unconditional abandon path. NEVER gated on CanShowK9UI()/access of any
--- kind -- a player who loses access, or simply wants to give up, must
--- always be able to abandon a call. Bumps requestGeneration so any
--- in-flight RequestStartSarCall() await that resolves after this runs
--- discards its result as stale rather than resurrecting the call just
--- abandoned. Also immediately forgets `currentSarCallId` -- see this
--- file's header "STALE-SESSION RACE": this is the step that guarantees a
--- late echo of the call just abandoned can never again match whatever
--- this client considers "current" from this point on, closing the race a
--- generation-counter bump alone could not. Safe to call when nothing is
--- active -- server/sarcalls.lua's abandonSarCall handler is unconditional
--- too, a harmless no-op if there was nothing to clear, and this function
--- never sends or needs currentSarCallId's value -- see the header's own
--- "NOT A TERMINATION-PATH CHANGE" note.
function RequestAbandonSarCall()
    requestGeneration = requestGeneration + 1
    sarCallActive = false
    currentSarCallId = nil
    TriggerServerEvent('qbx_k9unit:server:abandonSarCall')
end

RegisterNetEvent('qbx_k9unit:client:sarHintTierChanged', function(tier, callId)
    if source ~= 65535 then return end -- TRUST-BOUNDARY ORIGIN GUARD -- see this file's header
    if not sarCallActive then return end -- a stale push after an already-ended call on this client
    if not IsForCurrentSarCall(callId) then return end -- stale push from a session this client has already moved past -- see header "STALE-SESSION RACE"

    if tier == 'burning' then
        lib.notify({ title = locale('common.notify_title'), description = locale('sar.hint_burning'), type = 'inform' })
        PlayOwnPedSound('Bark_Alert')
    elseif tier == 'hot' then
        lib.notify({ title = locale('common.notify_title'), description = locale('sar.hint_hot'), type = 'inform' })
        PlayOwnPedSound('Bark_Calm')
    elseif tier == 'warm' then
        lib.notify({ title = locale('common.notify_title'), description = locale('sar.hint_warm'), type = 'inform' })
        PlayOwnPedSound('Growl_Ambient')
    else -- 'cold'
        lib.notify({ title = locale('common.notify_title'), description = locale('sar.hint_cold'), type = 'inform' })
    end
end)

RegisterNetEvent('qbx_k9unit:client:sarCallEnded', function(reason, callType, callId)
    if source ~= 65535 then return end -- TRUST-BOUNDARY ORIGIN GUARD -- see this file's header
    if not IsForCurrentSarCall(callId) then return end -- a late echo of a call this client already left behind (see header "STALE-SESSION RACE") -- must NOT clobber a newer session's own state

    requestGeneration = requestGeneration + 1 -- invalidate any in-flight RequestStartSarCall() await that might resolve after this
    sarCallActive = false
    currentSarCallId = nil

    if reason == 'found' then
        -- The "trained final response" -- K9_IDEAS.md §1's exact framing,
        -- reused here per §3's own suggestion, exactly like
        -- client/scenttrail.lua's CompleteHunt does for its own hunt type.
        -- The player is never told "found!" in a toast for THIS specific
        -- moment (server/sarcalls.lua's own 'sar.found_person'/
        -- 'sar.found_property' notify already covers the text side) --
        -- this is the dog's own physical reaction on top of that text.
        PlayOwnPedSound('Bark_Alert')
        if type(K9Sit) == 'function' then K9Sit() end
        ShowReveal(callType)
    end
    -- 'timeout'/'abandoned': server/sarcalls.lua's own NotifyPlayer call
    -- already told the player what happened; nothing further to do here.
end)

--- Self-initiated entry point. CanShowK9UI() re-checked here purely as a
--- client-side courtesy (server/sarcalls.lua's requestSarCall callback
--- re-validates HasK9Access independently regardless, per this resource's
--- "never trust the caller already checked" standard).
function RequestStartSarCall()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if sarCallActive then
        lib.notify({ title = locale('common.notify_title'), description = locale('sar.already_active'), type = 'error' })
        return
    end

    if startInFlight then return end -- reject a second concurrent start outright rather than letting two overlapping lib.callback.await calls race
    startInFlight = true
    requestGeneration = requestGeneration + 1
    local myGeneration = requestGeneration

    -- FAIL-CLOSED GUARD -- lib.callback.await throws rather than returning
    -- nil on a timeout/rejection; pcall it and treat a throw the same as
    -- "nothing usable came back", same precedent as client/scenttrail.lua's
    -- StartScentHunt/client/tracking.lua's StartTrack.
    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:requestSarCall', false)
    startInFlight = false

    -- Staleness check -- an abandon (or the server itself ending this same
    -- call before this await even returned) that ran while this was
    -- pending must not let a stale result resurrect a session the player
    -- already moved past.
    if myGeneration ~= requestGeneration then return end

    if not ok then result = nil end

    if not result or not result.started then
        local reason = result and result.reason
        if reason == 'already_active' then
            lib.notify({ title = locale('common.notify_title'), description = locale('sar.already_active'), type = 'error' })
        elseif reason == 'cooldown' then
            lib.notify({ title = locale('common.notify_title'), description = locale('sar.request_cooldown'), type = 'error' })
        else
            -- Collapses "feature disabled" / "no access" / "no live ped" /
            -- any other server-side rejection to the same generic denial,
            -- mirroring client/scenttrail.lua's/client/tracking.lua's own
            -- "one generic message, don't invent a distinction the server
            -- doesn't give data for" precedent.
            DenyK9UIAccess()
        end
        return
    end

    sarCallActive = true
    currentSarCallId = result.callId -- see this file's header "STALE-SESSION RACE"
end

-- '/k9sarcall' starts a call; '/k9sarcall stop' abandons one -- same
-- command-with-a-stop-argument shape as client/scenttrail.lua's
-- '/k9nosehunt [stop]', this resource's freshest precedent for this exact
-- class of feature. `false` (not ACE-restricted): access is enforced by
-- CanShowK9UI()/HasK9Access() above and server-side, the same posture
-- every other unrestricted K9 command in this resource uses.
RegisterCommand('k9sarcall', function(_, args)
    if args[1] and tostring(args[1]):lower() == 'stop' then
        RequestAbandonSarCall() -- never gated -- see its own doc comment
        return
    end

    RequestStartSarCall()
end, false)

-- Resource-stop hygiene -- see this file's header "RESOURCE-STOP HYGIENE"
-- for the full writeup. Mirrors client/pursuitsprint.lua's own
-- onResourceStop handler in shape, and client/scenttrail.lua's own
-- identical fix for the sibling gap. RequestAbandonSarCall() is NEVER
-- gated on CanShowK9UI()/access of any kind -- it is the same unconditional
-- abandon path '/k9sarcall stop' already uses, and is always safe to call
-- (including when nothing is active). ClearReveal() runs alongside it,
-- exactly as it always did -- this handler now does both cleanup jobs
-- instead of only the cosmetic one.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    RequestAbandonSarCall()
    ClearReveal()
end)
