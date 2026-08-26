--[[
    qbx_k9unit/client/proximityaudio.lua

    PROXIMITY AUDIO FX (Config.Features.ProximityAudioFX, still `false`) --
    client-side ambient K9 presence audio that scales with the LISTENING
    player's own live distance to a nearby, recognized K9-modeled ped: the
    dog audibly gets louder as a listener approaches it and quieter as they
    move away. Entirely delivered via client/audio.lua's existing NUI/
    Web-Audio GainNode bridge (PlayK9Sound/StopK9Sound/IsK9SoundActive --
    the last of these added THIS pass, see that file's own new header
    comment above it) -- this file adds ZERO new natives beyond ones this
    resource already uses elsewhere for the identical purpose, ZERO new
    server events, and does not touch client/audio.lua's SendNUIMessage
    payload contract with html/app.js at all (its one addition,
    IsK9SoundActive, is a pure Lua-side read of that file's own private
    state, never a new NUI message -- see that file's own comment on it).

    ==========================================================================
    SCOPE -- WHAT THIS FILE IS, AND, EXPLICITLY, IS NOT:

    This is NOT DEVELOPER_REFERENCE.md's §14.4.1 full "hidden-suspect growl relay"
    design (Config.ProximityAudioFX.SuspectDistanceSource, distanceTiers,
    a new server/main.lua relayGrowl handler, cadenceMs-gated bursts). That
    document's own §14.0 Fork 2 explicitly scopes "detect a hidden suspect"
    OUT of any single pass -- verbatim: "this resource does not and cannot
    supply a sensible default implementation for this on its own... no
    ecosystem-dominant metadata convention... to guess at" -- and names it a
    precondition for a later v2. That boundary is respected here by building
    NEITHER that trigger condition NOR the server-relay/tiered-growl
    plumbing that would sit on top of it, per this pass's own explicit
    instruction to respect it.

    What THIS file ships instead is the literal, narrower ask handed to its
    author: "K9 audio that scales with distance -- the dog sounds closer or
    further as the listener moves." That is delivered as a self-contained,
    purely-cosmetic, CLIENT-LOCAL effect with no "suspect"/trigger concept
    at all -- any live, non-dead, streamed-in ped matching one of
    Config.Peds' recognized K9 models (the SAME IsEntityModelK9() global
    check client/wellbeing.lua's Pet/Feed K9 targeting and
    client/medkit.lua's Treat K9 targeting already use for the identical
    "is this plausibly a K9" question -- an already-accepted ambiguity
    inherited here, not a new one: a wild, non-player NPC wearing the same
    model gets the same ambient effect, exactly as it would already be
    picked up by those existing targeting checks) gets a continuous, looped
    ambient sound whose gain THIS client alone computes from ITS OWN live
    distance, via client/audio.lua's already-built PlayK9Sound(..., {loop =
    true}) machinery -- there is no new falloff math to build here at all.

    This is a legitimate, self-contained v1 that neither blocks, nor is
    blocked by, a future SuspectDistanceSource-driven layer being added on
    top later -- that later layer would most naturally reuse this file's
    per-entity loop-lifecycle plumbing below (swapping "is this ped a
    recognized K9 model" for "is SuspectDistanceSource's own live suspect
    within range"), leaving PlayK9Sound/StopK9Sound/IsK9SoundActive
    untouched either way.

    WHY THE NUI/GainNode PATH (client/audio.lua), NOT DEVELOPER_REFERENCE.md
    §14.4.1's PREFERRED NATIVE PlaySoundOnNetworkEntity PATH: that section
    only ever calls the native engine's own free 3D falloff "worth naming,
    not required" -- and it is moot regardless, because
    PlaySoundFromEntity against this resource's placeholder K9_SOUND_SET
    (client/main.lua's BARK_SOUND_NAME/K9_SOUND_SET) is a permanently-inert
    no-op absent a real, authored .awc/dat151/dat54 RAGE audio bank, a
    materially bigger, unstarted asset task. The NUI bridge is the ONLY
    delivery path in this resource that can ever produce real, audible
    output once an operator drops in a plain html/sounds/<key>.ogg file
    (client/audio.lua's own header) -- this file was explicitly directed to
    build on that bridge for exactly that reason, a disclosed, deliberate
    divergence from DEVELOPER_REFERENCE.md's own "worth naming" lean, not an
    oversight of it.

    ==========================================================================
    FALLOFF MATH -- HONEST CONFIDENCE GRADING (stated plainly, per this
    pass's own instruction, rather than presented as a proven pattern):

    The actual gain-vs-distance curve (linear, 1.0 at 0m down to 0.0 at
    client/audio.lua's own private AUDIO_MAX_DISTANCE constant) and its
    500ms re-poll cadence are BOTH already implemented inside
    client/audio.lua's PlayK9Sound(loop = true) path (that file's own
    DistanceToGain/GainToEntity functions) -- this file adds NO new falloff
    math of its own, only the discovery/lifecycle layer deciding WHICH
    entities get a loop started or stopped, and when.
    client/audio.lua's own header already carries the correct, honest
    confidence grading for that underlying falloff curve itself: "new,
    unverified-in-the-wild plumbing, not a copy of a proven pattern" --
    phase2_notes/DEVELOPER_REFERENCE.md#phase-5-research §1 found that even
    the ecosystem's most-used NUI audio library (plunkettscott/
    interact-sound) still has an OPEN, unresolved TODO for the SIMPLE,
    single-factor version of this. Nothing about this file changes that
    grading -- it is inherited, not re-verified, here.

    This file's OWN contribution -- "which entities get a loop," "start or
    stop now" -- is, by contrast, ORDINARY, well-established client
    scripting with an existing in-repo precedent for the exact same
    GetGamePool('CPed') + distance-check idiom (client/combat.lua's
    FindNearestCombatTarget), HIGH confidence. Only the underlying
    continuous-gain mechanism this file delegates to (client/audio.lua)
    carries the lower, disclosed confidence grading above.

    ==========================================================================
    GATING -- "gate at registration, not just inside the loop" (same
    convention as client/audio.lua's own header, client/vision.lua's
    ThermalVision gate, client/movement.lua's AgilityBasicJump thread). This
    file returns entirely below, starting no thread at all, unless
    Config.Features.ProximityAudioFX is true (shipped default: false). It
    additionally never calls PlayK9Sound/StopK9Sound/IsK9SoundActive without
    a `type(...) == 'function'` runtime existence guard immediately before
    the call -- this resource's own documented "runtime existence guard, not
    a load-order assumption" convention (config.lua's globals comment on
    RestoreInjury/AwardXP/GetXPTier is the precedent this follows).
    Config.Features.ProximityAudioFX being true does not, by itself,
    guarantee client/audio.lua has already executed and defined those
    globals by the time THIS file's own client_scripts position runs --
    fxmanifest.lua load order (client/audio.lua before this file) is the
    reported, requested ordering, not a correctness guarantee this file
    silently assumes.

    ==========================================================================
    "EVERYTHING MUST STOP" -- how each required stop trigger actually maps
    onto this file's design, stated per-case rather than asserted in the
    abstract:
      - K9 DEATH: the discovery scan below skips (and, if previously
        tracked, stops the loop for) any candidate where IsEntityDead(ped)
        is true. Stop latency is bounded by PROXIMITY_SCAN_INTERVAL_MS below
        (a few seconds, not instantaneous) -- disclosed, not hidden.
      - K9 DESPAWN / entity no longer resolvable: double-covered. This
        file's own scan drops anything DoesEntityExist() no longer confirms
        AND client/audio.lua's own loop-poll thread independently self-heals
        the identical case already (its own ResolveNetworkEntity check each
        500ms tick calls StopK9Sound and exits if the entity streamed out
        from under it) -- see that file's PlayK9Sound doc comment.
      - LISTENER DISCONNECT: trivial by construction -- this is a
        client-local effect with no server-side bookkeeping of any kind, so
        a disconnecting listener's own state (their whole Lua VM and NUI
        page) simply stops existing; there is nothing left running to leak.
      - FEATURE DISABLED AT RUNTIME: this resource's own established
        convention (see every Config.Features.* flag in config.lua) is a
        static, gate-at-resource-start value, not a live-reloadable one --
        nothing in this codebase flips a Config.Features.* flag while
        running. The realistic way this feature actually gets "disabled at
        runtime" on a live server is an operator restarting the resource
        with the flag now false, which is exactly the onResourceStop case
        below, plus this file's own top-level gate simply not registering
        anything on the next start.
      - onResourceStop: explicit handler below stops every currently-tracked
        loop. Defense in depth, not strictly load-bearing on its own --
        FiveM tearing down this resource's NUI page on stop would already
        take the whole AudioContext (and therefore every sound it is
        playing) with it; this handler exists so this file's own behavior
        does not silently DEPEND on that being true, per this resource's own
        "restart-safety-net precedent" (client/kennel.lua's onResourceStop).

    ==========================================================================
    WORST-CASE PER-TICK COST (the discovery/maintenance thread below, once
    every PROXIMITY_SCAN_INTERVAL_MS -- NOT per frame, NEVER Wait(0)): one
    GetGamePool('CPed') call, bounded by THIS client's own already-streamed
    ped pool (typically well under a few hundred handles on any real
    server -- GetGamePool only ever returns entities already resident in
    this client's LOCAL entity pool; it is NOT a world/database scan, and
    this resource already uses this exact idiom on-demand elsewhere,
    client/combat.lua's FindNearestCombatTarget). For each handle: one
    GetEntityModel-backed IsEntityModelK9() hash-table lookup (O(1)), and
    ONLY for an actual K9-model match (realistically 0-a few concurrent K9s
    server-wide, a tiny subset of the pool) one IsEntityDead() call plus one
    `#(vec3 - vec3)` distance calc. Total: O(pool size) cheap native calls
    once every PROXIMITY_SCAN_INTERVAL_MS, never more often. This thread
    never stops running for the life of the resource while the feature flag
    is on -- a client-driven "is a new K9 now nearby" discovery mechanism
    structurally cannot avoid SOME periodic check; there is no server push
    signal it could block on instead -- but it never drops into a tight
    per-frame loop just because a K9 IS currently being tracked: gain
    updates for an already-started loop are client/audio.lua's own separate,
    already-running 500ms poll (client/audio.lua's AUDIO_GAIN_POLL_MS), not
    this thread's job.
]]

if not Config.Features.ProximityAudioFX then return end

-- ----------------------------------------------------------------------
-- Tuning -- read defensively from Config.ProximityAudioFX (a table this
-- pass's author does not own and did not add to config.lua -- see the
-- integration notes reported alongside this file for the exact block
-- requested). Defaulting inline rather than hard-erroring if that table
-- doesn't exist yet mirrors client/main.lua's own defensive
-- `Config.AdvancedBarkRadial or {}` posture for a config table a feature
-- flag references before its own schema addition has necessarily landed.
-- ----------------------------------------------------------------------
local ProximityAudioFXConfig = Config.ProximityAudioFX or {}

-- How often the discovery/maintenance thread below re-scans this client's
-- own streamed ped pool. See this file's header "WORST-CASE PER-TICK COST"
-- for the full cost model this interval feeds into.
local PROXIMITY_SCAN_INTERVAL_MS = ProximityAudioFXConfig.scanIntervalMs or 2500

-- Meters. A candidate K9 ped beyond this distance never gets a loop started
-- at all -- this MUST stay <= client/audio.lua's own real falloff ceiling
-- or a started loop would sit at a permanent, wasted gain of 0.0 (an active
-- AudioBufferSource + a 500ms poll thread producing no audible effect at
-- all).
--
-- FOUND EARLIER THIS PASS: this used to be an unenforced hand-sync
-- requirement against a private constant in another file (the comment here
-- literally said "HAND-SYNC REQUIRED if audio.lua's AUDIO_MAX_DISTANCE is
-- ever retuned below this value" and did nothing about it) -- if
-- Config.ProximityAudioFX.triggerDistance was ever configured (or
-- defaulted) above audio.lua's real ceiling, every ambient loop this file
-- starts would silently sit at gain 0.0 forever, with no error and no
-- console output.
--
-- CLOSED IN BOTH DIRECTIONS, now that client/audio.lua exposes
-- GetK9AudioMaxDistance() (added this pass specifically for this, allowed
-- into the root .luacheckrc `globals` list for exactly this cross-file
-- read): the clamp below reads that live value every time this file loads,
-- so it can never sit inconsistent with whatever audio.lua's own
-- AUDIO_MAX_DISTANCE actually is, in either direction, without a code
-- change forcing a re-evaluation of both. Falls back to a hardcoded 25.0
-- (this file's own historical default, safely under audio.lua's
-- documented 30.0 as of this pass) if GetK9AudioMaxDistance does not exist
-- as a global at all -- this resource's own "runtime existence guard, not
-- a load-order assumption" convention (client/audio.lua does not define
-- this function while Config.Features.BasicBarkSounds is false, regardless
-- of what fxmanifest.lua's load order promises).
local FALLBACK_TRIGGER_DISTANCE_METERS = 25.0
local audioMaxDistance = type(GetK9AudioMaxDistance) == 'function'
    and GetK9AudioMaxDistance()
    or FALLBACK_TRIGGER_DISTANCE_METERS
local PROXIMITY_TRIGGER_DISTANCE_METERS = math.min(
    ProximityAudioFXConfig.triggerDistance or FALLBACK_TRIGGER_DISTANCE_METERS,
    audioMaxDistance
)

-- RAGE-audio-style placeholder sound name, translated by client/audio.lua's
-- ToAudioFileKey() the exact same way BARK_SOUND_NAME is (client/main.lua)
-- -- NOT a real filename. Resolves to html/sounds/growl_ambient.ogg once an
-- operator supplies one; until then this degrades to the same silent,
-- zero-console-output no-op every other placeholder sound name in this
-- resource already degrades to (client/audio.lua's own header).
local PROXIMITY_SOUND_NAME = ProximityAudioFXConfig.soundName or 'Growl_Ambient'

-- Currently-tracked ambient loops, keyed by the LIVE ped entity handle
-- discovered by the scan below. Entity handles can be recycled by the game
-- once an entity streams out and something else streams in later -- this
-- table is intentionally rebuilt against a fresh "still valid this scan"
-- set every tick (see the thread below) rather than trusted to stay correct
-- indefinitely between scans.
--- @type table<number, { soundId: number, netId: number }>
local activeLoops = {}

--- Stops and untracks the ambient loop for `pedHandle`, if one is active.
--- Idempotent -- calling this for a ped with no tracked loop is a no-op,
--- same posture as client/audio.lua's own StopK9Sound doc comment.
--- @param pedHandle number
local function StopProximityLoop(pedHandle)
    local tracked = activeLoops[pedHandle]
    if not tracked then return end

    activeLoops[pedHandle] = nil

    if type(StopK9Sound) == 'function' then
        StopK9Sound(tracked.soundId)
    end
end

--- Starts a new ambient loop for `pedHandle` (identified to
--- client/audio.lua by `netId`, since PlayK9Sound resolves its own entity
--- from a netId, never a raw handle -- see that file's own doc comment).
--- No-ops (and tracks nothing) if PlayK9Sound doesn't currently exist as a
--- global (runtime existence guard, per this file's own header "GATING"
--- section) or declines to start (e.g. this client doesn't have `pedHandle`
--- streamed in as a network entity at all, or netId doesn't resolve on
--- client/audio.lua's own side by the time it runs).
--- @param pedHandle number
--- @param netId number
local function StartProximityLoop(pedHandle, netId)
    if type(PlayK9Sound) ~= 'function' then return end

    local soundId = PlayK9Sound(netId, PROXIMITY_SOUND_NAME, { loop = true })
    if soundId then
        activeLoops[pedHandle] = { soundId = soundId, netId = netId }
    end
end

-- ----------------------------------------------------------------------
-- DISCOVERY / MAINTENANCE THREAD -- see this file's header "WORST-CASE
-- PER-TICK COST" for the full cost model. One thread, one flat interval,
-- for the life of the resource while Config.Features.ProximityAudioFX is
-- true (the top-of-file gate above already skips this file's whole body,
-- including this CreateThread call, when the flag is false).
-- ----------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(PROXIMITY_SCAN_INTERVAL_MS)

        -- Per-person block (client/featureblocks.lua, REQUESTED -- see
        -- that file's header for the full contract). This is the
        -- LISTENER's own ability to hear ambient K9 audio -- blocking it
        -- stops every currently-tracked loop outright and skips discovery
        -- entirely for this scan, rather than merely refusing new loops,
        -- so a block applied while a loop is already playing is silenced
        -- within one PROXIMITY_SCAN_INTERVAL_MS of arriving (this thread's
        -- own established "polling detection, not instant, but real"
        -- posture -- see client/vision.lua's maintenance thread for the
        -- identical precedent). Muting a passive listening effect is never
        -- a "trap" -- there is no exit path to strand anyone from.
        if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('ProximityAudioFX') then
            for ped in pairs(activeLoops) do
                StopProximityLoop(ped)
            end
            goto continueProximityScan
        end

        local myPed = PlayerPedId()
        local myCoords = GetEntityCoords(myPed)

        -- Entities confirmed in range THIS scan -- anything currently
        -- tracked but absent from this set below gets stopped, whether
        -- that's because it moved out of range, died, or no longer exists.
        local stillInRange = {}

        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= myPed and DoesEntityExist(ped) and not IsEntityDead(ped) and IsEntityModelK9(ped) then
                local distance = #(myCoords - GetEntityCoords(ped))

                if distance <= PROXIMITY_TRIGGER_DISTANCE_METERS then
                    stillInRange[ped] = true

                    local tracked = activeLoops[ped]
                    -- A tracked loop can go stale two ways: client/audio.lua's
                    -- own AUDIO_MAX_LOOP_MS safety ceiling force-stopped it
                    -- (IsK9SoundActive now false), or nothing is tracked yet
                    -- for this ped at all (first time seen in range).
                    local staleLoop = tracked ~= nil
                        and type(IsK9SoundActive) == 'function'
                        and not IsK9SoundActive(tracked.soundId)

                    if not tracked or staleLoop then
                        if staleLoop then activeLoops[ped] = nil end

                        local netId = NetworkGetNetworkIdFromEntity(ped)
                        if netId and netId ~= 0 then
                            StartProximityLoop(ped, netId)
                        end
                    end
                end
            end
        end

        for ped in pairs(activeLoops) do
            if not stillInRange[ped] then
                StopProximityLoop(ped)
            end
        end

        ::continueProximityScan::
    end
end)

-- See this file's header "'EVERYTHING MUST STOP'" section for why this is
-- defense in depth rather than strictly load-bearing on its own.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    for ped in pairs(activeLoops) do
        StopProximityLoop(ped)
    end
end)
