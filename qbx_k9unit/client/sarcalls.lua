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
       ('already_active'|'cooldown'|'denied')? } [lib.callback]
    2. 'qbx_k9unit:server:abandonSarCall' () [RegisterNetEvent, this file
       only ever SENDS this] -- UNCONDITIONAL, see RequestAbandonSarCall
       below: never gated on CanShowK9UI()/access of any kind.
    3. 'qbx_k9unit:client:sarHintTierChanged' (tier: string) [RegisterNetEvent,
       server -> this caller's client only, never broadcast]
    4. 'qbx_k9unit:client:sarCallEnded' (reason: string, callType: string?)
       [RegisterNetEvent, server -> this caller's client only]
    Both server->client pushes carry the standard TRUST-BOUNDARY ORIGIN
    GUARD (`source ~= 65535` -- FiveM's documented sentinel for "this event
    genuinely came from the server," phase2_notes/RESEARCH_ARCHIVE.md#trust-boundary,
    the exact same convention client/screenfx.lua and client/scenttrail.lua
    already apply to their own server->client pushes). Forging either
    grants no real advantage here (worst case: a spurious notification/
    sound, or an early cosmetic reveal spawned at your own feet) -- kept
    anyway for consistency with this resource's standing convention on
    every server->client push.

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
-- field, which THAT file reads and this one never touches). Same
-- "validate what you consume, at load time, fail loud once the operator
-- has opted in" posture as server/sarcalls.lua's own guard.
-- ======================================================================
assert(type(tuning.missingPersonPedModel) == 'string' and tuning.missingPersonPedModel ~= '',
    '[qbx_k9unit] Config.SARCalls.missingPersonPedModel must be a non-empty string -- the ped model this file ' ..
    'spawns (non-networked, cosmetic only) for a "person"-type call\'s reveal.')
assert(type(tuning.lostPropertyPropModel) == 'string' and tuning.lostPropertyPropModel ~= '',
    '[qbx_k9unit] Config.SARCalls.lostPropertyPropModel must be a non-empty string -- the prop model this file ' ..
    'spawns (non-networked, cosmetic only) for a "property"-type call\'s reveal.')
assert(type(tuning.revealDurationMs) == 'number' and tuning.revealDurationMs > 0,
    '[qbx_k9unit] Config.SARCalls.revealDurationMs must be a positive number -- how long the cosmetic reveal ' ..
    'entity is kept alive before this file deletes it itself.')

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

    revealEntity = newEntity

    CreateThread(function()
        Wait(tuning.revealDurationMs)
        if myGeneration == revealGeneration then -- nothing else (a resource stop, an earlier/later ShowReveal) already cleared this
            ClearReveal()
        end
    end)
end

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    ClearReveal()
end)

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
--- abandoned. Safe to call when nothing is active -- server/sarcalls.lua's
--- abandonSarCall handler is unconditional too, a harmless no-op if there
--- was nothing to clear.
function RequestAbandonSarCall()
    requestGeneration = requestGeneration + 1
    sarCallActive = false
    TriggerServerEvent('qbx_k9unit:server:abandonSarCall')
end

RegisterNetEvent('qbx_k9unit:client:sarHintTierChanged', function(tier)
    if source ~= 65535 then return end -- TRUST-BOUNDARY ORIGIN GUARD -- see this file's header
    if not sarCallActive then return end -- a stale push after an already-ended call on this client

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

RegisterNetEvent('qbx_k9unit:client:sarCallEnded', function(reason, callType)
    if source ~= 65535 then return end -- TRUST-BOUNDARY ORIGIN GUARD -- see this file's header

    requestGeneration = requestGeneration + 1 -- invalidate any in-flight RequestStartSarCall() await that might resolve after this
    sarCallActive = false

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
