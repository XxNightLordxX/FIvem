--[[
    qbx_k9unit/client/announce.lua

    APPREHENSION ANNOUNCEMENT, client half. See server/announce.lua's own
    header for the full real-world sourcing and the "handler vs. dog, two
    different connections" design-tension writeup this file's counterpart
    resolves -- not re-derived here.

    This file is COSMETIC AND CONVENIENCE ONLY, never authoritative: it
    plays a sound, shows a prompt, and decides when to even attempt sending
    the request (so a doomed request -- feature off, no target in range --
    gets useful local feedback instead of a silent server-side no-op). The
    ONE thing that actually decides whether an apprehension warning
    happened, and whether its window is still open, is
    server/announce.lua's IsApprehensionWarned() -- a modified client
    cannot forge a warning by skipping this file, it can only ask the
    server to open one, and the server re-derives every fact that matters
    (access, live proximity, timing) itself.

    RequestApprehensionWarning() below deliberately mirrors
    client/combat.lua's RequestBiteHold()/RequestTakedown() shape byte-for-
    byte in STRUCTURE (same ordered precondition checks, same
    lib.notify/locale() call shape) -- that file's own FindNearestCombatTarget
    is `local`, not a resource-global (confirmed: client/combat.lua:603),
    so it cannot be reused from here; FindNearestApprehensionTarget below is
    this file's own small, self-contained copy of the identical
    nearest-ped-in-range scan, matching this codebase's own established
    "each file keeps its own tiny copy of a genuinely small, self-contained
    check" convention (server/permissions.lua's IsDuplicateKeyError doc
    comment names this precedent explicitly) rather than promoting the
    original to a global for one new caller.

    TWO EXISTING, UNCHANGED CONTRACTS THIS FILE CONSUMES:
      - 'qbx_k9unit:client:playBark' (netId, barkType) -- client/main.lua's
        own already-shipped RegisterNetEvent handler. server/announce.lua's
        successful-announce path fires this at every player within earshot
        (itself included), which is what makes the announcement genuinely
        AUDIBLE to the person being warned without this file needing to
        register a second sound-playing path of its own.
      - locale('combat.no_target_in_range') / locale('common.notify_title')
        -- reused verbatim from client/combat.lua's own identical "no
        eligible target" case, rather than minting a near-duplicate string.

    STALE-NOTE FIX (this pass): 'announce.warning_received', read by this
    file's own 'qbx_k9unit:client:apprehensionWarningReceived' handler
    below to tell the SUSPECT, specifically, that they have just been
    warned, HAS LANDED in locales/en.json -- this section used to describe
    it as "not yet landed" and explain why shipping the call anyway was
    safe (ox_lib's real locale() degrades to the raw key on a miss, rather
    than erroring). That degradation note is still accurate in general (see
    server/combat.lua's own 'combat.tier_capability_denied' history for the
    same pattern used once), it just no longer describes this key's own
    current state -- kept here, corrected, rather than deleted, so a future
    reader does not have to rediscover why this call was ever written
    "riskily" in the first place.
]]

--- Small, self-contained copy of client/combat.lua's `local`
--- FindNearestCombatTarget -- see this file's header for why it cannot be
--- reused directly. DISPLAY/CONVENIENCE ONLY: server/announce.lua
--- independently re-resolves and re-validates the target from the netId
--- this hands off, from scratch, exactly like every ox_target
--- candidate-search predicate in this resource already documents for
--- itself.
--- @param rangeMeters number
--- @return number? targetPed
local function FindNearestApprehensionTarget(rangeMeters)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPed, nearestDist

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= myPed and DoesEntityExist(ped) and not IsEntityDead(ped) then
            local dist = #(myCoords - GetEntityCoords(ped))
            if dist <= rangeMeters and (not nearestDist or dist < nearestDist) then
                nearestPed, nearestDist = ped, dist
            end
        end
    end

    return nearestPed
end

--- Entry point for both the keybind below and any future radial/tablet
--- item that wants to reuse it (same "resource-global so more than one
--- entry point can reach it" convention as RequestRecall/RequestPursuitSprint).
--- PRECONDITIONS MIRROR client/combat.lua's RequestBiteHold/RequestTakedown
--- deliberately -- see this file's header.
function RequestApprehensionWarning()
    if not Config.Features.ApprehensionAnnouncement then
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.feature_disabled'), type = 'error' })
        return
    end

    -- GATE WIDENED TO HasK9Access() ALONE (QA finding, this pass) -- the
    -- same fix, for the same reason, already applied to
    -- client/combat.lua's RequestBiteHold/RequestTakedown/RequestDrag and
    -- client/defense.lua's ConfirmHandlerDownDefense. This one was missed.
    --
    -- THE BUG: this used to read `if not CanShowK9UI() then
    -- DenyK9UIAccess() return end`, and CanShowK9UI() is
    -- IsOwnModelK9()/IsK9Role() AND HasK9Access() -- it requires the
    -- caller to currently BE the dog. server/announce.lua's own handler
    -- gates on HasK9Access(src) ALONE, and its header says why in as many
    -- words: "EITHER PARTY MAY ANNOUNCE... HasK9Access deliberately does
    -- not [check the model]". A human handler standing next to the suspect
    -- is supposed to be exactly as able to give the warning as the K9 is --
    -- that is the whole cooperative half of the feature, and the reason the
    -- warning window is keyed per-TARGET rather than per-announcer.
    --
    -- So the client refused, locally, before the request was ever sent, the
    -- one party the server was specifically written to accept. A certified
    -- handler pressing M next to a suspect got "you cannot use K9 features
    -- right now" while genuinely holding full access, and there is no
    -- second route to fall back on -- /k9announce and its M keybind are
    -- this feature's ONLY entry points (no radial item, no tablet action).
    -- In the design's own worst case (the handler is the one near the
    -- suspect, the K9 is not) the feature was unusable outright, and the
    -- bite or takedown it exists to authorize was then refused server-side
    -- for want of a warning nobody was allowed to give.
    --
    -- This is the one-layer-up trap: a correct, deliberately-permissive
    -- server gate re-narrowed by its own client caller. START HALF ONLY --
    -- there is no stop half here to widen (an announcement is
    -- fire-and-forget; the window it opens expires on its own timer and has
    -- no release path that could be gated).
    if type(HasK9Access) ~= 'function' or not HasK9Access() then
        DenyK9UIAccess()
        return
    end

    local cfg = Config.Combat and Config.Combat.ApprehensionAnnouncement
    local range = (cfg and type(cfg.range) == 'number' and cfg.range > 0) and cfg.range or 8.0

    local target = FindNearestApprehensionTarget(range)
    if not target then
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.no_target_in_range'), type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:announceApprehensionWarning', NetworkGetNetworkIdFromEntity(target))
end

--- The SUSPECT's own client. See this file's header for the "one new
--- locale key, not yet landed, safe to ship anyway" disclosure.
--- SOURCE-ORIGIN GUARD, same convention and same confidence grading as
--- client/main.lua's own 'qbx_k9unit:client:playBark' handler (this file's
--- header names that precedent explicitly) -- `source ~= 65535` rejects a
--- locally self-triggered forgery of this event, accepting only a genuine
--- server-sent one. Not a feature-flag gate (forging this only shows the
--- forger themselves a notification -- there is no wider consequence to
--- gate), same reasoning playBark's own handler documents for itself.
--- @param expiresAt number -- server GetGameTimer() timestamp, informational only (this file draws no local countdown from it)
RegisterNetEvent('qbx_k9unit:client:apprehensionWarningReceived', function(expiresAt)
    if source ~= 65535 then return end

    lib.notify({ title = locale('common.notify_title'), description = locale('announce.warning_received'), type = 'inform' })
end)

RegisterCommand('k9announce', function()
    RequestApprehensionWarning()
end, false)

RegisterKeyMapping('k9announce', locale('announce.keybind_label'), 'keyboard', 'M')
