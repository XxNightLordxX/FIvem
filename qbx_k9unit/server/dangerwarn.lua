--[[
    qbx_k9unit/server/dangerwarn.lua

    DANGER WARN -- the reverse direction of server/defense.lua's
    HandlerDownDefense. That file lets the SERVER notice a handler going
    down and alert the partnered K9's client. Nothing in this resource let
    the other half of the pair say anything back: a K9 who spots trouble
    with their own eyes had no way to tell their handler except typing in
    chat, which breaks the fiction of a real working dog. This file is a
    DELIBERATE, PLAYER-TRIGGERED warning the K9's own player fires -- never
    an automatic detector -- because a player-controlled dog has already
    seen whatever it is; the only missing piece is a way to say so.

    ======================================================================
    WHY DELIBERATE, NOT AUTOMATIC (the one rule everything below is
    subordinate to, mirrors server/defense.lua's own "§12.0 ITEM 2" framing
    for the identical reason applied in the opposite direction): an NPC dog
    has to warn automatically, because there is no intelligence behind it.
    A player-controlled K9 does not -- the player already knows what they
    saw. This file therefore never inspects nearby entities, threat levels,
    weapons, or wanted status to decide FOR the K9 that something dangerous
    is happening; it only relays a warning the K9's own player chose to
    send, at a moment they chose, with a type they chose from a small,
    configured set.
    ======================================================================

    ======================================================================
    THE ONE PIECE OF INFORMATION THIS FILE ACTUALLY SENDS, AND WHY IT IS
    NOT A WALLHACK:
    The handler receives a NOTIFICATION carrying the alert's configured
    type, plus a COARSE compass direction (one of 8 sectors: N/NE/E/SE/S/
    SW/W/NW) and a COARSE distance bucket (close/nearby/far/very_far) FROM
    THE HANDLER'S OWN POSITION TOWARD THE K9's OWN CURRENT POSITION -- both
    computed HERE, server-side, from GetEntityCoords on each party's real
    ped, NEVER from anything the client supplies. No exact coordinate, no
    entity, no identity of any third party, and no marker of any kind is
    ever sent to anyone.
    This is deliberately NOT the same shape as server/defense.lua's
    `suggestedTargetNetId` (a pre-selected HIDDEN THIRD PARTY's own entity
    handle) -- that shape would be the actual wallhack here: revealing an
    unseen suspect's position or identity to a handler who has not spotted
    them. This file carries none of that. The only position it ever
    describes is the K9's OWN position -- which the K9's own player already
    knows perfectly (they are standing there), and which any bystander with
    ordinary line of sight could already see for free. Telling the
    HANDLER, who currently has zero information, roughly which of 8
    directions and roughly which of 4 distance bands their OWN partner is
    in is the in-fiction equivalent of hearing a dog bark somewhere off to
    your left -- atmosphere, not intelligence. 32 discrete (direction,
    distance) combinations across an entire map is nowhere near precise
    enough to pinpoint anything, and repeated warnings from the same
    physical spot cannot sharpen that: the buckets are wide, fixed, and
    never narrow with repetition.
    ======================================================================

    ======================================================================
    A SMALL, CONFIGURABLE SET OF WARNING TYPES -- not ten. Two are built in
    by default (Config.DangerWarn.Types, both operator-editable, and the
    table itself accepts more without any code change here):
      - 'Alert'  -- something/someone nearby is off; low urgency.
      - 'Threat' -- an active, armed, or aggressive danger; high urgency.
    "Found something" is already this resource's own FindAlerts feature
    (server/findalert.lua) -- reusing this file for that would duplicate an
    existing, shipped reaction rather than fill a real gap. "Follow me" is
    a navigation mechanic, not a danger warning, and a materially different
    shape of feature (it would need to tell the HANDLER where to go, which
    is exactly the precision problem this file's own header above spent a
    whole section arguing against) -- out of scope for a file literally
    named dangerwarn.lua.
    ======================================================================

    ======================================================================
    WHO HEARS WHAT:
      - The bonded HANDLER (server/partnership.lua's
        GetActivePartnerCitizenId, read-only, never re-derived here) gets
        the full readable alert via NotifyPlayer -- regardless of distance,
        since the entire point is reaching a handler who may be far away.
      - Every CONNECTED PLAYER within Config.DangerWarn.audibleRadius of
        the K9's OWN real position (server/search.lua's ForEachNearbyPlayer
        -- read-only, distance-filtered, exactly the helper server/main.lua
        already reuses for relayBark/relayDoorScratch) hears the actual
        bark over this resource's existing NUI audio bridge
        (client/audio.lua's PlayK9Sound) -- audio only, no text, and no
        information beyond "a dog is barking near me," which anyone
        standing there could already hear for real. The handler, if within
        that same radius, hears this too, on top of their own text alert --
        no de-duplication is needed because one event carries sound and the
        other carries text; they never conflict.
      - Nobody else. No global broadcast, no dispatch integration, no
        third-party notification.
    ======================================================================

    ======================================================================
    RATE LIMIT: DangerWarnCooldown (server/cooldowns.lua's NewCooldown,
    ResolveConfiguredThresholdMs-clamped so a non-positive Config value
    warns and falls back rather than either erroring at load or silently
    permitting unlimited spam), keyed by the K9's own connection source and
    cleaned up via .RegisterPlayerDropped() -- this is a live-session,
    connection-scoped throttle (not a persistent-identity one like
    server/pursuitsprint.lua's citizenid-keyed cooldown), because the worst
    a reconnect-to-bypass could buy here is an extra cosmetic
    notification/bark -- this feature mints no XP, changes no game state,
    and grants no capability, so citizenid-keyed persistence (which would
    additionally require a sweep thread) buys no real security against a
    threat model that does not exist for this specific mechanic. Consumed
    (`.Consume`, check-and-stamp together) as the LAST gate, only once
    every other check has already passed -- same "never burn the anti-spam
    budget on a request that was going to fail anyway" discipline
    server/pursuitsprint.lua's own request handler already documents.
    ======================================================================

    ======================================================================
    SERVER-AUTHORITATIVE, END TO END:
      - The requesting source must pass HasK9Access(src) -- this is a
        K9-role action, never available to a handler.
      - The K9's own coordinates come from GetPlayerPed(src) ->
        GetEntityCoords, resolved HERE, never a client-supplied coordinate
        of any kind.
      - The partner lookup comes from GetActivePartnerCitizenId
        (server/partnership.lua), server-side cached state, never a client
        claim about who its partner is.
      - The warning TYPE is validated against Config.DangerWarn.Types (or
        this file's own built-in fallback table if that Config block is
        missing/malformed) -- an unrecognized or garbage value from a
        modified client silently resolves to the configured default type
        rather than being trusted or rejected outright, since there is no
        differential capability between types for this to protect (see
        "A SMALL, CONFIGURABLE SET" above) -- the whitelist exists only to
        keep the sound-name/notify-type lookup sane, not as an
        authorization boundary.
      - Per-person feature control (Config.FeatureControl, block./feature.
        permission keys) is checked for BOTH parties, mirroring
        server/defense.lua's own IsHandlerDownDefensePermittedForCitizenId
        -- an explicit block on either side silently suppresses this one
        notification, never a hard error.
    ======================================================================

    ======================================================================
    NEVER GATE A TERMINATION PATH -- CHECKED, AND N/A: this file has no
    held state, no active effect, and no start/stop pair of any kind. It is
    a single, one-shot, fire-and-forget notification with nothing left
    running afterward for any escape hatch to release. There is nothing
    here for that rule to apply to, which was confirmed by design (not
    merely by absence of an obvious counterexample) before this file was
    written -- see "WHY DELIBERATE, NOT AUTOMATIC" above: this is
    intentionally a single action, not a mode.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:requestDangerWarn' (warnType: string)
      Fired by client/dangerwarn.lua's RequestDangerWarn(). See "A SMALL,
      CONFIGURABLE SET" above for the accepted values and the "SERVER-
      AUTHORITATIVE" section above for why an unrecognized value is never
      rejected outright.

    Client events (server->client), registered by client/dangerwarn.lua:
    - 'qbx_k9unit:client:dangerWarnAudible' (k9NetId: number, soundName:
      string)
      Sent to every player within Config.DangerWarn.audibleRadius of the
      K9's own position (see "WHO HEARS WHAT" above) -- audio only, no
      text, no state.
    The full readable alert to the handler is sent via NotifyPlayer
    (server/notify.lua)'s existing 'ox_lib:notify' contract -- no new
    client-side text-handling event was needed for this file at all.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls HasK9Access(source) (server/certifications.lua) bare, no
      runtime existence guard -- same convention as every other
      self-initiated K9 trigger in this resource (server/pursuitsprint.lua,
      server/sarcalls.lua both call it the same way): certifications.lua is
      a hard, always-loaded part of this resource, not an optional sibling.
    - Calls GetActivePartnerCitizenId(citizenid) (server/partnership.lua)
      behind a `type(...) == 'function'` runtime existence guard -- soft
      dependency, this resource's established convention, since
      HandlerPartnership may be disabled or that file may be absent.
    - Calls HasPermission(citizenid, key) (server/permissions.lua) behind
      the same runtime existence guard, inside
      IsDangerWarnPermittedForCitizenId below -- identical shape to
      server/pursuitsprint.lua's own IsPursuitSprintPermittedForCitizenId
      and server/defense.lua's IsHandlerDownDefensePermittedForCitizenId;
      read one of those two before writing a third variant of this
      four-step resolution anywhere else.
    - Calls ForEachNearbyPlayer(coords, radius, callback)
      (server/search.lua) behind a `type(...) == 'function'` runtime
      existence guard, same as server/main.lua's own relayBark/
      relayDoorScratch call sites -- if absent, the bystander/handler
      audible bark simply does not go out; the handler's own text alert
      above is unaffected either way.
    - Calls NotifyPlayer(target, description, notifyType) (server/notify.lua)
      bare, no guard -- another hard, always-loaded shared primitive.
    - Calls NewCooldown() (server/cooldowns.lua) at this file's own
      file-load time -- HARD load-order requirement, same as every other
      consumer of that constructor.
    - Recommended fxmanifest.lua placement: after server/cooldowns.lua
      (hard requirement), server/certifications.lua (HasK9Access, bare
      call), server/notify.lua (NotifyPlayer, bare call),
      server/partnership.lua (soft dependency, readability) and
      server/search.lua (ForEachNearbyPlayer, soft dependency,
      readability) -- e.g. immediately after server/defense.lua, alongside
      this resource's other self-initiated K9-trigger files
      (server/pursuitsprint.lua, server/sarcalls.lua). Not a hard
      requirement beyond server/cooldowns.lua, since every other named
      global here is reached only at RUN time, by which point every
      server_scripts file has already finished loading regardless of
      manifest order.
    ======================================================================

    LOCALE: every player-facing string below is proposed, not yet in
    locales/en.json (this file may not edit that file directly) -- each is
    resolved through `pcall(locale, 'dangerwarn.<key>', ...)` with a
    hardcoded English last-resort fallback BYTE-IDENTICAL to the proposed
    text, exactly mirroring server/runtimecontrol.lua's own
    GetFeatureLockoutWarning/GetActiveUsageWarning pattern and
    server/tenure.lua's TenureMilestoneNotificationText pattern -- so this
    feature is fully functional today and upgrades to a real localized
    string automatically, with no further code change, the moment each key
    lands. See this file's own closing report for the exact proposed key
    list, forwarded verbatim to whoever owns locales/en.json.

    Config surface: PROPOSED (this file may not edit config.lua directly).
    `Config.Features.DangerWarn` (recommended default `false`, per this
    resource's own stated convention that a brand-new mechanic stays off
    until its own balance/security review, mirroring how
    Config.Features.HandlerPartnership originally shipped) and
    `Config.DangerWarn` (cooldownMs, audibleRadius, distanceBuckets.{close,
    nearby,far}, Types.{Alert,Threat}.{soundName,notifyType}, keybind) --
    every field defensively resolved below with a built-in, loudly-warned
    fallback if missing or malformed, so this file never aborts its own
    load over a bad/absent Config block the way an unguarded top-level
    `assert` would (server/cooldowns.lua's header ADDENDUM is the reason
    this matters: an uncaught error here would silently un-register this
    entire file's net event).
]]

if not Config.Features.DangerWarn then return end

-- ======================================================================
-- CONFIG-SAFETY: every field below is resolved defensively -- clamped and
-- loudly warned, never hard-asserted -- because an uncaught error from
-- this file's own top-level chunk would abort the WHOLE FILE's load from
-- that line onward (server/cooldowns.lua's header ADDENDUM), silently
-- un-registering 'qbx_k9unit:server:requestDangerWarn' over one bad
-- Config number. Config.DangerWarn itself may be entirely absent (a
-- server that only ever set Config.Features.DangerWarn = true and never
-- added the block) -- that is not an error, it just means every field
-- below falls back to its own built-in default.
-- ======================================================================
local dangerWarnCfg = Config.DangerWarn
if type(dangerWarnCfg) ~= 'table' then
    print('[qbx_k9unit] NOTE: Config.Features.DangerWarn is enabled but Config.DangerWarn is missing -- using this file\'s built-in defaults for every field (cooldownMs=15000, audibleRadius=30.0, distanceBuckets={close=15,nearby=50,far=150}, Types={Alert,Threat}, keybind=\'N\'). Add a Config.DangerWarn block to config.lua to customize this feature.')
    dangerWarnCfg = {}
end

local DangerWarnCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    dangerWarnCfg.cooldownMs, 15000, 'Config.DangerWarn.cooldownMs'))
DangerWarnCooldown.RegisterPlayerDropped()

-- Matches client/audio.lua's own AUDIO_MAX_DISTANCE gain-falloff ceiling
-- by default, so this file never wastes a broadcast on a client whose own
-- audio bridge would already compute zero gain for it -- see that file's
-- own GetK9AudioMaxDistance accessor. Not READ from it directly (that
-- accessor is guarded `type(...) == 'function'` and this is a SERVER
-- file; GetK9AudioMaxDistance is client-only) -- this is a deliberately
-- separate, server-side constant kept in sync BY VALUE, same
-- "duplicate constant, not a live cross-realm read" situation
-- client/proximityaudio.lua's own PROXIMITY_TRIGGER_DISTANCE_METERS is in
-- relative to that same accessor.
local DEFAULT_AUDIBLE_RADIUS = 30.0

--- @return number meters
local function ResolveAudibleRadius()
    local v = dangerWarnCfg.audibleRadius
    if type(v) == 'number' and v == v and v > 0 then return v end
    if v ~= nil then
        print(('[qbx_k9unit] WARNING: Config.DangerWarn.audibleRadius must be a positive number of meters (found: %s). Using the built-in fallback of %s instead.'):format(tostring(v), DEFAULT_AUDIBLE_RADIUS))
    end
    return DEFAULT_AUDIBLE_RADIUS
end
local AudibleRadius = ResolveAudibleRadius()

local DEFAULT_DISTANCE_BUCKETS = { close = 15.0, nearby = 50.0, far = 150.0 }

--- Validates the three upper-bound fields are positive numbers in strictly
--- increasing order (close < nearby < far) -- an out-of-order or
--- non-positive set would silently make every distance read as the wrong
--- bucket (or the SAME bucket for everything), which is a much quieter
--- failure than a missing table, so this checks the whole shape at once
--- rather than field-by-field.
--- @return table { close: number, nearby: number, far: number }
local function ResolveDistanceBuckets()
    local b = dangerWarnCfg.distanceBuckets
    local function isValid(t)
        return type(t) == 'table'
            and type(t.close) == 'number' and t.close == t.close and t.close > 0
            and type(t.nearby) == 'number' and t.nearby == t.nearby and t.nearby > t.close
            and type(t.far) == 'number' and t.far == t.far and t.far > t.nearby
    end
    if isValid(b) then return b end
    if b ~= nil then
        print('[qbx_k9unit] WARNING: Config.DangerWarn.distanceBuckets must be a table of three increasing positive numbers { close, nearby, far } (found something else). Using the built-in fallback of { close = 15.0, nearby = 50.0, far = 150.0 } instead.')
    end
    return DEFAULT_DISTANCE_BUCKETS
end
local DistanceBuckets = ResolveDistanceBuckets()

local DEFAULT_WARN_TYPE = 'Alert'
local DEFAULT_TYPES = {
    Alert  = { soundName = 'Bark_Alert', notifyType = 'warning' },     -- html/sounds/bark_alert.ogg, already shipped and listed in fxmanifest.lua's files{} block -- see this file's closing report for the exact confirmation
    Threat = { soundName = 'Bark_Aggressive', notifyType = 'error' },  -- html/sounds/bark_aggressive.ogg, same confirmation
}

--- Resolves a requested warn type against Config.DangerWarn.Types (or this
--- file's own DEFAULT_TYPES if that block is missing/malformed), falling
--- back to DEFAULT_WARN_TYPE for anything unrecognized -- see this file's
--- header "SERVER-AUTHORITATIVE" section for why an unrecognized value is
--- a silent fallback, never a rejection: there is no differential
--- capability between warn types for a whitelist to protect here, only a
--- sound-name/notify-type lookup to keep sane.
--- @param warnType any
--- @return string resolvedType, table typeConfig -- typeConfig is never
---   nil; the last-resort branch returns this file's own hardcoded
---   DEFAULT_TYPES[DEFAULT_WARN_TYPE] directly, so a caller never needs a
---   nil guard on the second return value.
local function ResolveWarnType(warnType)
    local types = type(dangerWarnCfg.Types) == 'table' and dangerWarnCfg.Types or DEFAULT_TYPES

    local function isValidEntry(entry)
        return type(entry) == 'table'
            and type(entry.soundName) == 'string' and entry.soundName ~= ''
            and type(entry.notifyType) == 'string' and entry.notifyType ~= ''
    end

    if type(warnType) == 'string' then
        local entry = types[warnType]
        if isValidEntry(entry) then return warnType, entry end
    end

    local fallbackEntry = types[DEFAULT_WARN_TYPE]
    if isValidEntry(fallbackEntry) then return DEFAULT_WARN_TYPE, fallbackEntry end

    -- Config.DangerWarn.Types exists but is malformed even for the default
    -- key -- last resort, never nil, per this function's own @return doc.
    return DEFAULT_WARN_TYPE, DEFAULT_TYPES[DEFAULT_WARN_TYPE]
end

-- ======================================================================
-- LOCALE -- see this file's own header closing section. Every key below
-- is PROPOSED, not yet in locales/en.json; `SafeLocale` tries the real key
-- first and falls back to the literal, byte-identical proposed English
-- text the instant that lookup fails for any reason, so this feature is
-- fully functional today and upgrades automatically once each key lands.
-- ======================================================================
--- @param key string
--- @param fallback string
--- @return string
local function SafeLocale(key, fallback, ...)
    local ok, text = pcall(locale, key, ...)
    if ok and type(text) == 'string' and text ~= '' then return text end
    return fallback
end

local COMPASS_LABEL = {
    N = 'north', NE = 'north-east', E = 'east', SE = 'south-east',
    S = 'south', SW = 'south-west', W = 'west', NW = 'north-west',
}
local COMPASS_ORDER = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }

--- Coarse, 8-sector compass bearing FROM `fromCoords` TOWARD `toCoords`.
--- "North" is defined as +Y in world space -- a documented approximation
--- (same disclosure convention as client/vision.lua's own honest
--- limitations list), not a claim this matches GTA's in-game compass
--- exactly; it is internally consistent, which is all a coarse "roughly
--- that way" cue needs to be.
--- @param fromCoords table -- { x:number, y:number, z:number }
--- @param toCoords table
--- @return string sector -- one of COMPASS_ORDER
local function BearingSector(fromCoords, toCoords)
    local dx = toCoords.x - fromCoords.x
    local dy = toCoords.y - fromCoords.y
    if dx == 0 and dy == 0 then return 'N' end -- degenerate (same point) -- arbitrary but deterministic
    local angle = math.deg(math.atan(dx, dy))
    if angle < 0 then angle = angle + 360 end
    local index = math.floor((angle + 22.5) / 45) % 8
    return COMPASS_ORDER[index + 1]
end

local DISTANCE_LABEL = {
    close = 'very close', nearby = 'nearby', far = 'some distance away', very_far = 'far away',
}

--- @param distance number meters
--- @return string bucket -- one of 'close' | 'nearby' | 'far' | 'very_far'
local function DistanceBucket(distance)
    if distance <= DistanceBuckets.close then return 'close' end
    if distance <= DistanceBuckets.nearby then return 'nearby' end
    if distance <= DistanceBuckets.far then return 'far' end
    return 'very_far'
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own documented 4-step
-- resolution, step 1 (Config.Features.DangerWarn) already checked at the
-- top of this file. Byte-for-byte the same shape as
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId and
-- server/defense.lua's IsHandlerDownDefensePermittedForCitizenId -- read
-- one of those two before writing a third variant of this anywhere else.
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
--- @return ('blocked'|'not_granted')? denyReason
local function IsDangerWarnPermittedForCitizenId(citizenid)
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.DangerWarn') == true then
        return false, 'blocked' -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.DangerWarn == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        if hasPermissionAvailable and HasPermission(citizenid, 'feature.DangerWarn') == true then
            return true
        end
        return false, 'not_granted'
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

-- ======================================================================
-- REQUEST HANDLER
-- ======================================================================
RegisterNetEvent('qbx_k9unit:server:requestDangerWarn', function(warnType)
    local src = source

    if not HasK9Access(src) then
        NotifyPlayer(src, SafeLocale('dangerwarn.denied_no_access',
            'You are not certified to use K9 danger warnings.'), 'error')
        return
    end

    -- Cheapest-first check (no state mutated yet) -- the real .Consume()
    -- stamp happens only once every other check below has ALSO passed,
    -- same "never burn the anti-spam budget on a request that was going to
    -- fail anyway" discipline server/pursuitsprint.lua's own request
    -- handler already documents.
    if DangerWarnCooldown.IsOnCooldown(src) then
        NotifyPlayer(src, SafeLocale('dangerwarn.on_cooldown',
            'Your K9 needs a moment before it can warn again.'), 'error')
        return
    end

    local k9Player = exports.qbx_core:GetPlayer(src)
    local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
    if not k9Citizenid then return end -- no resolvable identity -- nothing to attribute this request to

    if type(GetActivePartnerCitizenId) ~= 'function' then
        NotifyPlayer(src, SafeLocale('dangerwarn.no_partner',
            'You have no partnered handler to alert -- Partner Up first.'), 'error')
        return
    end

    -- NAMING, matching server/defense.lua's own identical note: the second
    -- return value describes whether the QUERIED citizenid (k9Citizenid,
    -- the argument passed in) is the K9-role party -- not whether the
    -- resolved partner is. This file's whole point is a K9 warning ITS
    -- handler, so the querying party must itself hold the K9 role.
    local partnerCitizenid, queriedIsK9Role = GetActivePartnerCitizenId(k9Citizenid)
    if not partnerCitizenid or queriedIsK9Role ~= true then
        NotifyPlayer(src, SafeLocale('dangerwarn.no_partner',
            'You have no partnered handler to alert -- Partner Up first.'), 'error')
        return
    end

    local handlerPlayer = exports.qbx_core:GetPlayerByCitizenId(partnerCitizenid)
    local handlerSrc = handlerPlayer and handlerPlayer.PlayerData and handlerPlayer.PlayerData.source
    if not handlerSrc then
        NotifyPlayer(src, SafeLocale('dangerwarn.handler_offline',
            'Your partnered handler is not currently online.'), 'error')
        return
    end

    local k9Permitted, k9DenyReason = IsDangerWarnPermittedForCitizenId(k9Citizenid)
    if not k9Permitted then
        if k9DenyReason == 'blocked' then
            NotifyPlayer(src, SafeLocale('dangerwarn.denied_blocked',
                'High Command has individually blocked you from using danger warnings. This is not a missing grant -- ask them why.'), 'error')
        else
            NotifyPlayer(src, SafeLocale('dangerwarn.denied_not_granted',
                "Danger warnings have not been granted to you individually. Ask a high command officer to grant you 'Danger Warn' access."), 'error')
        end
        return
    end

    -- The HANDLER's own block/grant state is checked too (mirrors
    -- server/defense.lua's identical "checked against BOTH parties"
    -- convention), but silently suppresses rather than notifying the K9 --
    -- a fact about the HANDLER's own permission state is not this K9's
    -- business to be told, same reasoning server/defense.lua's own
    -- TryNotifyPartnerK9 already applies in the opposite direction.
    local handlerPermitted = IsDangerWarnPermittedForCitizenId(partnerCitizenid)
    if not handlerPermitted then return end

    local k9Ped = GetPlayerPed(src)
    local handlerPed = GetPlayerPed(handlerSrc)
    if k9Ped == 0 or handlerPed == 0 then return end -- disconnected between the event firing and this line

    -- Every real precondition has now passed -- consume the cooldown here,
    -- immediately before actually sending, per this function's own
    -- cheapest-first comment above.
    -- Nothing between the IsOnCooldown check above and here can yield (no
    -- callback/DB await of any kind in this handler), so this can never
    -- actually fail today -- kept as a real check anyway rather than an
    -- assumption, matching this resource's own defensive convention of
    -- never trusting an earlier check to still hold without re-verifying
    -- at the point that matters.
    if not DangerWarnCooldown.Consume(src) then return end

    local resolvedType, typeCfg = ResolveWarnType(warnType)

    local k9Coords = GetEntityCoords(k9Ped)
    local handlerCoords = GetEntityCoords(handlerPed)
    local direction = COMPASS_LABEL[BearingSector(handlerCoords, k9Coords)]
    local distance = DistanceBucket(#(k9Coords - handlerCoords))
    local distanceLabel = DISTANCE_LABEL[distance]

    local description
    if resolvedType == 'Threat' then
        description = SafeLocale('dangerwarn.handler_alert_Threat',
            ('Your K9 is barking at a real threat %s of it, %s! Approach with caution.'):format(direction, distanceLabel),
            direction, distanceLabel)
    elseif resolvedType == 'Alert' then
        description = SafeLocale('dangerwarn.handler_alert_Alert',
            ('Your K9 is alerting -- something seems off %s of it, %s. Worth a look.'):format(direction, distanceLabel),
            direction, distanceLabel)
    else
        -- An operator-added custom Config.DangerWarn.Types entry beyond
        -- the two shipped defaults -- no dedicated locale key is proposed
        -- for an unknown custom name, so this generic, still-informative
        -- fallback is used directly rather than guessing a key that would
        -- never resolve.
        description = ('Your K9 is warning you (%s) -- %s of it, %s.'):format(resolvedType, direction, distanceLabel)
    end

    NotifyPlayer(handlerSrc, description, typeCfg.notifyType)

    -- Bystander/handler-in-range audible bark -- see this file's header
    -- "WHO HEARS WHAT". Soft dependency: if server/search.lua's helper is
    -- unavailable for any reason, the handler's own text alert above has
    -- already gone out unaffected.
    if type(ForEachNearbyPlayer) == 'function' then
        local k9NetId = NetworkGetNetworkIdFromEntity(k9Ped)
        ForEachNearbyPlayer(k9Coords, AudibleRadius, function(playerId)
            TriggerClientEvent('qbx_k9unit:client:dangerWarnAudible', playerId, k9NetId, typeCfg.soundName)
        end)
    end
end)
