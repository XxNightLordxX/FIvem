--[[
    qbx_k9unit/server/announce.lua

    APPREHENSION ANNOUNCEMENT (Config.Features.ApprehensionAnnouncement). A
    real K9 handler must give a loud verbal warning before releasing a dog
    to apprehend somebody -- settled use-of-force doctrine (police1.com's
    "K-9 announcements: dos and don'ts", tacticalk9usa.com, Madison PD's
    published K9 use SOP), not a courtesy: a bite is force, and force
    requires a genuine chance to comply first. Nothing in this resource
    required that before this file existed -- Config.Combat.BiteAndHold and
    NonLethalTakedown (server/combat.lua) could both be triggered with zero
    warning.

    ======================================================================
    THE DESIGN TENSION, AND HOW IT IS RESOLVED HERE
    ======================================================================
    In real life the HANDLER shouts the warning. In this resource the
    handler and the dog are TWO DIFFERENT CONNECTED PLAYERS, and it is the
    DOG's player whose client sends requestBiteHold/requestTakedown
    (server/combat.lua's `src` throughout ValidateCombatRequest is the K9's
    own player, never the handler's). A naive "the handler must announce"
    design would make every apprehension require two humans coordinating in
    the same moment -- worsening this resource's own already-disclosed
    "two-player tax" (a dog player whose handler is busy has nothing to
    do), for a lone K9 with no handler online most of all.

    RESOLVED as follows, deliberately:

    1. EITHER PARTY MAY ANNOUNCE. The gate below is HasK9Access(src), the
       SAME server-authoritative check server/combat.lua's own
       ValidateCombatRequest uses to decide "is this connection allowed to
       use K9 features at all" -- and HasK9Access deliberately does not
       care whether the caller is currently playing the handler or the dog
       (server/certifications.lua's own doc comment: "Deliberately does NOT
       check ped model"). A human handler standing next to the suspect and
       a K9 player standing next to the same suspect are EQUALLY able to
       fire the net event below. This is also, quite literally, "the dog's
       own warning bark counts" (see point 3) -- the K9's own player is
       never blocked from being the one who warns.
    2. A LONE K9 WITH NO HANDLER ONLINE IS NEVER STRANDED. Because either
       party can announce (point 1) and the window this file opens is
       PER-TARGET, not per-announcer-identity (point 4), a solo K9 player
       announces themselves, then bites -- one player, two actions, no
       coordination required. This was the deciding constraint: any design
       that could not satisfy it outright was rejected before being
       written down.
    3. THE ANNOUNCEMENT PLAYS AS THE K9's OWN BARK. The success path below
       reuses client/main.lua's existing, already-shipped
       'qbx_k9unit:client:playBark' broadcast contract verbatim (same event
       name, same (netId, barkType) payload shape it already documents) --
       no change to client/main.lua or server/main.lua was needed or made.
       In-fiction this genuinely IS a bark (an aggressive one,
       'Bark_Alert'); mechanically it is the SAME audio pipeline
       Config.Features.BasicBarkSounds already ships, reused rather than
       forked, so the warning has a real, audible, positional sound the
       instant this feature is enabled, not a silent flag with no
       in-game presence.
    4. THE WINDOW IS PER-TARGET, NOT PER-(ANNOUNCER,TARGET) PAIR. Keying
       solely by the SUSPECT's own netId (AnnouncedWindows below), rather
       than by which specific connection announced, is what makes "the
       handler warns, the dog bites" work at all -- the bite is always
       executed by the K9's OWN connection (server/combat.lua's `src`),
       which is necessarily a DIFFERENT connection than a human handler who
       gave the warning. Restricting consumption to "only the announcer's
       own src may act on it" would make the handler-warns/dog-bites half
       of point 1 impossible to use, defeating the whole resolution. This
       does NOT "license biting everybody nearby" -- opening a window still
       requires live server-side proximity to THIS ONE target (Config.
       Combat.ApprehensionAnnouncement.range, below), and the window only
       ever answers the question "was THIS netId warned", never "was
       anybody near here warned".
    5. GATES THE START, NEVER THE STOP. IsApprehensionWarned() below is
       consulted ONLY from server/combat.lua's ValidateCombatRequest -- the
       function that OPENS a bite-hold/takedown request -- and from
       nowhere else. EndHold, EndActiveEffectForHolder, the maintenance
       expiry sweep, and releaseBiteHold/releaseTakedown never call it and
       must never be changed to. A warning window lapsing mid-hold can
       therefore never strand an already-open hold or interfere with
       releasing/ending one -- this file adds no new termination path and
       touches none of the existing ones.
    6. BALANCE: THIS ONLY MAKES APPREHENSION HARDER. Every branch below
       either does nothing (feature off, guard function absent) or adds a
       NEW way to be refused (no announcement on file for this target) --
       nothing here shortens a cooldown, widens a range, or otherwise makes
       BiteAndHold/NonLethalTakedown easier to land, matching this
       resource's own stated K9-balance posture (Config.PursuitSprint's
       deliberate speed clamp is the precedent named in this feature's own
       brief). Config.Features.ApprehensionAnnouncement therefore ships
       `true` by default, mirroring Config.Combat.ExcludeVehicleSeatedTargets'
       own precedent immediately below it in config.lua -- a purely
       restrictive, fairness-motivated check layered onto this SAME shared
       validator, also shipped `true`.

    ======================================================================
    SERVER AUTHORITY
    ======================================================================
    The client may play a sound and show a prompt; ONLY this file decides
    whether an announcement actually happened and whether its window is
    still open. Every fact IsApprehensionWarned/the net event handler below
    relies on is server-held: HasK9Access(src) (a DB-backed cert/grant
    check, never a client claim), live GetEntityCoords() distance between
    the announcer's and target's OWN peds (never a client-reported
    distance), and a server-side GetGameTimer() expiry stamp. A modified
    client cannot forge "I already warned them" -- it can only ask this
    file to open a window, and this file re-derives everything that
    matters about that request from server-held state.

    ======================================================================
    FEATURE TIER (server/runtimecontrol.lua's FEATURE_TIERS -- this file
    does NOT edit that table; see this pass's own report for why)
    ======================================================================
    LIVE. Config.Features.ApprehensionAnnouncement is read fresh, on every
    single call, by IsApprehensionWarned() below AND by the net event
    handler that opens a window -- never captured once at file-load time,
    never gated behind a whole-file early return the way e.g.
    client/audio.lua gates BasicBarkSounds. Flipping this flag through the
    runtime tablet takes effect on the very next ValidateCombatRequest call
    in EITHER direction (on->off immediately stops gating; off->on
    immediately starts), with no resource restart needed -- exactly the
    same live contract BiteAndHold/NonLethalTakedown's own flags already
    have at that identical call site, which is what this gate rides on top
    of.

    ======================================================================
    CLEANUP (task requirement -- a per-target table with no cleanup path is
    a defect this codebase already treats as such: see server/combat.lua's
    own ActiveHolds/K9ActiveEffect/K9PositionHistory precedent)
    ======================================================================
    AnnouncedWindows is bounded three independent ways:
      1. LAZY EXPIRY -- IsApprehensionWarned() itself deletes an entry the
         first time it is consulted after expiresAt has passed.
      2. PLAYER-TARGET DISCONNECT -- the playerDropped handler below clears
         any window whose stored targetSrc is the disconnecting source
         (an NPC-target window has no targetSrc and nothing to clear here;
         those are covered by (1) and (3) instead).
      3. onResourceStop -- wipes the whole table. Honest disclosure: since
         AnnouncedWindows is pure in-memory Lua state with no corresponding
         world entity or database row, FXServer's own resource-stop tear-
         down of this resource's entire Lua VM already discards it; this
         handler is belt-and-braces symmetry with this codebase's other
         onResourceStop cleanups (e.g. server/fetch.lua's own, which DOES
         have real work to do -- deleting orphaned world objects), not a
         gap this file would otherwise have.
]]

-- ----------------------------------------------------------------------
-- Tuning constants -- code-local, not Config.* entries, matching how
-- server/main.lua's own NEARBY_BROADCAST_RADIUS_METERS is a file-local
-- constant rather than an exposed config knob for the identical "who is
-- close enough to hear a bark" question.
-- ----------------------------------------------------------------------

-- Meters. How far from the ANNOUNCER a connected player must be to hear
-- the reused 'qbx_k9unit:client:playBark' cue this file broadcasts on a
-- successful announcement. Deliberately generous relative to
-- Config.Combat.ApprehensionAnnouncement.range (the announcer-to-TARGET
-- distance the request itself is gated on) -- a "LOUD" warning per this
-- feature's own real-world sourcing should carry to bystanders well beyond
-- the one suspect it is legally aimed at, and this is cosmetic-only (it
-- gates no permission), so erring generous costs nothing but a few extra
-- TriggerClientEvent calls.
local ANNOUNCE_BROADCAST_RADIUS_METERS = 30.0

--- Config.Combat.ApprehensionAnnouncement.range/windowMs, defensively
--- validated inline (NOT via server/cooldowns.lua's ResolveConfiguredThresholdMs
--- -- that helper is for a value handed straight to NewCooldown's own
--- constructor, and windowMs/range are read fresh per-call here instead,
--- never captured as a constructor default). A non-finite/non-positive
--- Config value fails toward the SAFE direction for both: an unusably
--- small range/window makes this feature strictly HARDER to satisfy, never
--- easier, consistent with this file's own "never make apprehension
--- easier" guarantee.
--- @return number range, number windowMs
local function ResolvedAnnouncementTuning()
    local cfg = Config.Combat and Config.Combat.ApprehensionAnnouncement
    local range = cfg and cfg.range
    local windowMs = cfg and cfg.windowMs
    if type(range) ~= 'number' or range ~= range or range <= 0 then
        range = 8.0
    end
    if type(windowMs) ~= 'number' or windowMs ~= windowMs or windowMs <= 0 then
        windowMs = 20000
    end
    return range, windowMs
end

-- Per-ANNOUNCER (never per-target) spam guard on the announce action
-- itself -- same rationale config.lua's own scratchCooldownMs comment
-- gives for BasicBarkSounds' server-side bark cooldown. src-keyed, so
-- :RegisterPlayerDropped() (server/cooldowns.lua's own documented cleanup
-- mode for a source-keyed tracker) is the correct cleanup mode here.
local AnnounceActionCooldown = NewCooldown(
    ResolveConfiguredThresholdMs(
        Config.Combat and Config.Combat.ApprehensionAnnouncement and Config.Combat.ApprehensionAnnouncement.announceCooldownMs,
        5000,
        'Config.Combat.ApprehensionAnnouncement.announceCooldownMs'
    )
)
AnnounceActionCooldown.RegisterPlayerDropped()

--- targetNetId -> { expiresAt = <GetGameTimer() ms>, targetSrc = number? }.
--- targetSrc is nil for an NPC target (no connected client to clean up on
--- disconnect -- see this file's own CLEANUP section above) and the
--- CONNECTED PLAYER SERVER ID for a player target.
local AnnouncedWindows = {}

--- Server-authoritative: has `targetNetId` genuinely been given an
--- apprehension warning within its own still-open window? Consulted ONLY
--- from server/combat.lua's ValidateCombatRequest, at REQUEST time, for
--- BiteAndHold/NonLethalTakedown specifically -- never from a
--- termination/cleanup path (see this file's header, point 5). Reads
--- Config.Features.ApprehensionAnnouncement fresh on every call (tier =
--- 'live', see this file's header) and is fully PERMISSIVE the moment that
--- flag is false, so a server that has this feature switched off is
--- byte-for-byte unaffected by this file's existence.
--- @param targetNetId number
--- @return boolean warned
function IsApprehensionWarned(targetNetId)
    if not Config.Features.ApprehensionAnnouncement then
        return true
    end

    local window = AnnouncedWindows[targetNetId]
    if not window then
        return false
    end

    if GetGameTimer() >= window.expiresAt then
        AnnouncedWindows[targetNetId] = nil -- lazy eviction, see CLEANUP (1)
        return false
    end

    return true
end

--- Opens (or refreshes) a per-target apprehension-warning window. Either a
--- human handler or the K9's own player may fire this -- see this file's
--- header, point 1 -- gated only on the SAME HasK9Access(src) check
--- server/combat.lua's ValidateCombatRequest already applies to every
--- combat request, never on which role the caller happens to be playing.
---
--- Every failure path below is a SILENT no-op (no NotifyPlayer/locale()
--- call): the client-side entry point (client/announce.lua's
--- RequestApprehensionWarning) already runs the same feature-flag/
--- CanShowK9UI/range preconditions locally before ever sending this event,
--- so a rejection reaching this far is the rare forged/stale-client case
--- this resource's other relay handlers (e.g. the SOURCE-ORIGIN GUARD
--- convention client/main.lua's own playBark handler documents) also
--- decline to narrate -- matching, not inventing, that precedent.
RegisterNetEvent('qbx_k9unit:server:announceApprehensionWarning', function(targetNetId)
    local src = source

    if not Config.Features.ApprehensionAnnouncement then return end
    if type(targetNetId) ~= 'number' then return end
    if type(HasK9Access) ~= 'function' or not HasK9Access(src) then return end
    if AnnounceActionCooldown.IsOnCooldown(src) then return end

    if type(ResolveNetworkEntity) ~= 'function' then return end
    -- expectedEntityType = 1 (ped) -- see server/entities.lua's
    -- ResolveNetworkEntity doc comment for the GetEntityType numbering,
    -- same convention server/combat.lua's ValidateCombatRequest already
    -- follows for its own identically-shaped target resolution.
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then return end

    local announcerPed = GetPlayerPed(src)
    if announcerPed == 0 then return end -- defensive: src disconnected between the event firing and this line
    if targetPed == announcerPed then return end -- warning yourself is not a meaningful action

    local range, windowMs = ResolvedAnnouncementTuning()

    -- Live server-side proximity -- NEVER a client-claimed distance, same
    -- discipline ValidateCombatRequest's own `too_far` check documents.
    local dist = #(GetEntityCoords(announcerPed) - GetEntityCoords(targetPed))
    if dist > range then return end

    AnnounceActionCooldown.Touch(src)

    local targetSrc = type(ResolveConnectedPlayerFromPed) == 'function' and ResolveConnectedPlayerFromPed(targetPed) or nil
    local expiresAt = GetGameTimer() + windowMs

    AnnouncedWindows[targetNetId] = {
        expiresAt = expiresAt,
        targetSrc = targetSrc,
    }

    -- VISIBLE, to the person being warned specifically -- requirement is
    -- "audible/visible to the SUSPECT", not merely to whoever announced.
    -- Only reachable when the target resolves to a connected player; an
    -- NPC target has no client to show this to (the window still opens
    -- either way -- see this file's header point 4 on why NPC/player
    -- targets are not special-cased here).
    if targetSrc then
        TriggerClientEvent('qbx_k9unit:client:apprehensionWarningReceived', targetSrc, expiresAt)
    end

    -- AUDIBLE -- reuses client/main.lua's existing, unmodified
    -- 'qbx_k9unit:client:playBark' broadcast contract (this file's header,
    -- point 3): (netId, barkType), announcerNetId as the SOUND'S OWN
    -- origin so it plays positionally from wherever the announcer actually
    -- is, 'Bark_Alert' as one of Config.AdvancedBarkRadial's own existing,
    -- already-shipped bark variants. Bounded to players within
    -- ANNOUNCE_BROADCAST_RADIUS_METERS of the ANNOUNCER (never an
    -- unconditional `-1` broadcast to the whole server), mirroring
    -- server/main.lua's own relayBark bounded-broadcast pattern -- a small,
    -- self-contained copy of that shape in this file rather than a call
    -- into server/main.lua, per this codebase's own established "each file
    -- keeps its own tiny copy of a genuinely small, self-contained check"
    -- convention (server/permissions.lua's IsDuplicateKeyError doc comment
    -- names this precedent explicitly).
    local announcerNetId = NetworkGetNetworkIdFromEntity(announcerPed)
    local announcerCoords = GetEntityCoords(announcerPed)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        local otherPed = playerId and GetPlayerPed(playerId)
        if otherPed and otherPed ~= 0 then
            local otherDist = #(announcerCoords - GetEntityCoords(otherPed))
            if otherDist <= ANNOUNCE_BROADCAST_RADIUS_METERS then
                TriggerClientEvent('qbx_k9unit:client:playBark', playerId, announcerNetId, 'Bark_Alert')
            end
        end
    end
end)

-- ================= DISCONNECT / RESTART CLEANUP =================
-- See this file's header CLEANUP section for the full three-mechanism
-- writeup this implements.

AddEventHandler('playerDropped', function()
    local src = source

    for netId, window in pairs(AnnouncedWindows) do
        if window.targetSrc == src then
            AnnouncedWindows[netId] = nil
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    AnnouncedWindows = {}
end)
