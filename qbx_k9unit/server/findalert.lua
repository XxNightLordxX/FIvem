--[[
    qbx_k9unit/server/findalert.lua

    K9_IDEAS.md §1 ("Make finds feel like a real alert, not a pop-up
    message"). Server half of client/findalert.lua -- see that file's own
    header for the client-side reaction contract. This file adds ZERO new
    detection logic of its own: it is a pure ADDITIONAL CONSUMER of two
    events server/search.lua and client/tracking.lua already fire for their
    own, unrelated purposes -- the same "FiveM fires every registered
    handler, so this is an additional consumer, not a replacement" pattern
    fxmanifest.lua's own comment already documents for server/wellbeing.lua
    listening in on server/tracking.lua's relayDamageEvent/relayWeaponFire.

    STRICT SESSION OWNERSHIP: this file, client/findalert.lua and
    tests/findalert_spec.lua were the ONLY three new files this pass was
    authorized to create. server/search.lua, server/tracking.lua,
    server/certifications.lua and server/cooldowns.lua are all owned by
    other agents this session and are only READ (globals/events they
    already expose), never edited, to build this.

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Inbound (AddEventHandler -- events this resource ALREADY fires for
    other reasons; this file only listens, it never redefines or re-wires
    either one):
    1. 'qbx_k9unit:events:searchCompleted'
       (searcherCitizenid: string, searcherJob: string,
        targetType: 'vehicle'|'person', result: 'found'|'clean'|'search_failed',
        totalWeight: number?, alertTier: string?)
       [server/search.lua's LogSearchAttempt -- see server/exports.lua's
       EVENT CONTRACT §5 for the authoritative, already-wired definition of
       this event]. Only `alertTier` is read below -- `searcherCitizenid` is
       used solely to resolve which CURRENTLY connected player to react on,
       never stored, logged, or forwarded anywhere; `searcherJob`/
       `targetType`/`result`/`totalWeight` are read by nobody in this file
       (job/weight in particular are exactly the fields server/search.lua's
       own header already treats as private to the requester -- this file
       adds no new exposure of them). `alertTier` is nil exactly when
       `result == 'search_failed'` (confirmed by reading server/search.lua's
       own LogSearchAttempt call sites directly: every 'search_failed' path
       passes `nil, nil` for totalWeight/alertTier) -- nothing to react to,
       so this file no-ops on a nil alertTier rather than guessing.
    2. 'qbx_k9unit:server:reportTrackSourceArrival' ()
       [client/tracking.lua's own render thread -- see that file's own
       EVENT/CALLBACK CONTRACT item 4 for the authoritative definition].
       server/tracking.lua is its PRIMARY consumer (awards
       Config.XP.awards.trackSourceResolved XP, independently re-measuring
       distance against its own server-held state before doing so) -- this
       file is a SECOND, entirely independent consumer of the exact same
       already-fired signal, reacting with ZERO economy consequence of its
       own (this file mints no XP, checks no distance, and does not care
       whether server/tracking.lua's own award succeeds, is on cooldown, or
       even runs at all).
       ONE DISCLOSED LIMITATION, not fixable from either of this feature's
       two files: client/tracking.lua only fires this event while
       Config.Features.XPProgression is ALSO true (nested inside that
       flag's own check, for that file's own unrelated XP-trigger purpose --
       see its own header). This means the "react on reaching a scent
       trail's end" bonus path below stays silently inert whenever
       XPProgression is off, even with ScentTracking/BloodTracking/
       GunpowderSniffing and Config.Features.FindAlerts both on. Flagged for
       coder-frontend/coder-architect as a candidate for decoupling in a
       future pass (client/tracking.lua is owned by a different agent this
       session, not edited here) -- not a bug in this file, a real,
       disclosed coverage gap in the one signal available to hook without
       editing that file.

    Outbound (TriggerClientEvent):
    3. 'qbx_k9unit:client:playFindAlertReaction' (alertTier: string)
       [client/findalert.lua] -- see that file's own header EVENT/CALLBACK
       CONTRACT for the full contract. ALWAYS unicast to exactly the one
       resolved source, NEVER a -1 broadcast -- unlike client/main.lua's
       relayBark, this reaction is about the searching/tracking K9's OWN
       body, not something bystanders are meant to be told about (that is
       Config.Features.ContrabandAlerts' own, separate, already-shipped
       broadcast, radius-filtered server-side in server/search.lua for
       privacy -- this file does not duplicate or extend that surface).
    ======================================================================

    WHY exports.qbx_core:GetPlayerByCitizenId(...) DIRECTLY, not through
    Config.Compat: config.lua's Config.Compat.Systems.framework block lists
    'qbx_core'/'qb-core'/'es_extended' as detection CANDIDATES, but as of
    this pass there is no resource-global accessor anywhere in this tree
    that actually resolves Config.Compat's detection result into a callable
    citizenid->source lookup (no compat.lua/framework wrapper file exists
    yet). fxmanifest.lua's own `dependencies` table hard-requires 'qbx_core'
    for the ENTIRE resource (unlike the genuinely swappable
    inventory/target/dispatch/ambulance systems), and every other feature
    file that needs this exact lookup today -- server/progression.lua's
    AwardXP/AwardXPDirect, server/recall.lua, server/partnership.lua,
    server/appearance.lua -- calls
    `exports.qbx_core:GetPlayerByCitizenId(citizenid).PlayerData.source`
    directly, unconditionally, right now, with no pcall wrapping at that
    exact call (this file matches that, relying on this file's own outer
    per-handler pcall instead -- see each handler below). This file matches
    that real, working, resource-wide convention rather than inventing a
    new Config.Compat-routed abstraction this session's other agents have
    not yet built (which would risk calling a global that does not exist
    and silently no-op'ing this entire feature forever -- the exact "silent
    no-op" failure class this pass was told to guard against). Flagged for
    coder-backend/coder-architect: if/when a real framework compat wrapper
    lands, this file's ONE call site should be migrated to it alongside
    every other file listed above, not treated as a one-off exception.
    ======================================================================
]]

--- Defense-in-depth per-source throttle on how often ONE player's own
--- automatic find-alert reaction may fire, shared across BOTH trigger paths
--- below (search-completion and track-arrival) deliberately -- so a player
--- cannot use one path to route around the other path's own throttle.
--- NOT the primary gate for either path: the search path is already bounded
--- by server/search.lua's own Config.SearchZones.searchCooldownMs (a
--- searcher cannot complete a NEW search faster than that regardless), and
--- the track-arrival path already has its own independent per-source
--- cooldown inside server/tracking.lua (that file's own
--- TrackArrivalReportCooldown, guarding ITS XP award). This tracker exists
--- because 'qbx_k9unit:server:reportTrackSourceArrival' is a bare
--- client->server event ANY connected client can call directly (bypassing
--- client/tracking.lua's own local IsTracking()/arrivalReported gating
--- entirely) -- server/tracking.lua's own cooldown only protects ITS OWN
--- XP-award logic, not this file's independent handler for the exact same
--- event, so without this, a modified client could otherwise make its OWN
--- server do real (if cheap, purely cosmetic) work once per network round
--- trip. Mirrors this resource's established "every relay handler gets its
--- own cooldown, belt-and-suspenders over an upstream gate" convention
--- (server/main.lua's BarkCooldown/DoorScratchCooldown, each independent of
--- any client-side debounce).
local FIND_ALERT_REACTION_COOLDOWN_MS = 1500
local FindAlertReactionCooldown = NewCooldown(FIND_ALERT_REACTION_COOLDOWN_MS)
FindAlertReactionCooldown.RegisterPlayerDropped()

--- Resolves `citizenid` to its CURRENTLY connected player's server id, or
--- nil if that citizenid is not online right now. See this file's header
--- "WHY exports.qbx_core:GetPlayerByCitizenId(...) DIRECTLY" section for why
--- this calls the framework export directly rather than through some
--- not-yet-existing Config.Compat wrapper -- mirrors
--- server/progression.lua's AwardXP/AwardXPDirect's own identical
--- `onlinePlayer.PlayerData.source` resolution byte-for-byte. Not
--- separately pcall-wrapped here -- both call sites below already run
--- inside their own outer pcall, matching this codebase's "wrap the whole
--- handler body once, don't nest a second pcall around a call already
--- covered by it" posture.
--- @param citizenid string
--- @return number? onlineSrc
local function ResolveOnlineSourceForCitizenid(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local src = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    if type(src) ~= 'number' then return nil end
    return src
end

--- Shared implementation behind both inbound event handlers below. Never
--- called with an untrusted/raw client-claimed alertTier -- see each
--- caller's own comment for exactly where its alertTier argument comes
--- from (either server/search.lua's own already-computed tier, or this
--- file's own hardcoded 'aggressive_bark' literal for the track-arrival
--- path).
--- @param targetSrc number
--- @param alertTier string
local function DispatchFindAlertReaction(targetSrc, alertTier)
    if not Config.Features.FindAlerts then return end -- real no-op, not just hidden -- this resource's own "gate at the point of activation" convention

    -- Read from the SAME shared config table client/findalert.lua resolves
    -- against -- see that file's own header for why the reaction SHAPE
    -- (sit/sound) is never computed or echoed by this file, only the
    -- alertTier lookup key is ever sent. Checked here too (not just
    -- client-side) purely to avoid sending a pointless event to a client
    -- that would only discard it anyway -- an unrecognized/unmapped tier
    -- (e.g. 'clean', which has no entry by design) is a real no-op at
    -- EVERY layer, never a guessed default at any of them.
    local reaction = Config.FindAlerts and Config.FindAlerts.reactionsByAlertTier and Config.FindAlerts.reactionsByAlertTier[alertTier]
    if not reaction then return end

    if not HasK9Access(targetSrc) then return end -- reuse the global from server/certifications.lua, do not re-derive the job/cert check here -- mirrors server/main.lua's relayBark

    if not FindAlertReactionCooldown.Consume(targetSrc) then
        return -- silent no-op: rate-limited, not an error worth notifying about -- matches this resource's bark/leash-request/certify-action convention
    end

    TriggerClientEvent('qbx_k9unit:client:playFindAlertReaction', targetSrc, alertTier)
end

--- See this file's header EVENT/CALLBACK CONTRACT item 1.
AddEventHandler('qbx_k9unit:events:searchCompleted', function(searcherCitizenid, searcherJob, targetType, result, totalWeightOrNil, alertTierOrNil)
    -- Wrapped defensively: this file is one of potentially SEVERAL
    -- registered handlers for this event (server/exports.lua's own header
    -- documents this as a stable, other-resource-facing contract), fired
    -- via server/search.lua's FireOutboundEvent, which itself already calls
    -- `pcall(TriggerEvent, ...)` -- an uncaught throw here would already be
    -- swallowed at that level and only logged, but this file pcalls its own
    -- body anyway rather than relying on an upstream file's own defensive
    -- wrapping, matching this resource's "never assume another file's guard
    -- covers you" posture.
    local ok, err = pcall(function()
        if type(searcherCitizenid) ~= 'string' or searcherCitizenid == '' then return end -- defensive: never trust an event payload's shape blindly, even a same-resource one
        if type(alertTierOrNil) ~= 'string' then return end -- 'search_failed' (and any other shape carrying no real tier) has nothing to react to -- see this file's header item 1 for why alertTier is nil for that result

        local targetSrc = ResolveOnlineSourceForCitizenid(searcherCitizenid)
        if not targetSrc then return end -- the searcher disconnected in the (very narrow) window between their search completing and this handler running -- fail closed, not an error

        DispatchFindAlertReaction(targetSrc, alertTierOrNil)
    end)
    if not ok then
        print(('[qbx_k9unit] findalert.lua: searchCompleted handler errored: %s'):format(tostring(err)))
    end
end)

--- See this file's header EVENT/CALLBACK CONTRACT item 2.
AddEventHandler('qbx_k9unit:server:reportTrackSourceArrival', function()
    local src = source -- the REAL sender of this client->server event -- captured immediately, before the pcall below, matching this resource's own `local src = source` convention (server/main.lua's relayBark and others)

    local ok, err = pcall(function()
        if not (Config.Features.ScentTracking or Config.Features.BloodTracking or Config.Features.GunpowderSniffing) then return end -- none of the three trail types this event can originate from are even enabled -- treat any occurrence as not worth reacting to
        if not (Config.FindAlerts and Config.FindAlerts.reactOnTrackArrival) then return end

        -- Reaching a trail's actual resolved source is unambiguously a
        -- genuine positive find, not a graded quantity the way contraband
        -- weight is -- always react with the SAME strength as the biggest
        -- contraband tier. This is the only place in this file that
        -- hardcodes a tier name rather than reading one out of an event
        -- payload -- deliberate, since this event carries no tier
        -- information of its own to read.
        DispatchFindAlertReaction(src, 'aggressive_bark')
    end)
    if not ok then
        print(('[qbx_k9unit] findalert.lua: reportTrackSourceArrival handler errored: %s'):format(tostring(err)))
    end
end)
