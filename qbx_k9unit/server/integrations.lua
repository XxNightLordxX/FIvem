--[[
    qbx_k9unit/server/integrations.lua

    EXTERNAL-SYSTEM INTEGRATION SURFACE -- the seam this resource offers to
    dispatch, MDT, evidence, jail, phone, billing, or any other operator-run
    system, KNOWN OR UNKNOWN, per FEATURE_IDEAS.md Part A §7 ("K9-down
    dispatch integration hook") and Part B §2/§3 ("Dispatch integration" /
    "MDT / evidence integration"). Read those three sections before touching
    this file.

    ======================================================================
    THE HARD CONSTRAINT THIS FILE IS BUILT UNDER: every server running this
    resource may run a DIFFERENT, possibly custom-built, possibly
    not-yet-written dispatch/MDT/ambulance/jail/phone/billing/evidence
    system. This file therefore never names, requires, `exports.<name>:...`
    calls, or `GetResourceState('<name>')`-branches on any specific
    third-party resource -- not even as a "sensible default." See DESIGN
    PRINCIPLES near the bottom of this header for how that constraint shapes
    every choice below.

    ======================================================================
    OUTBOUND vs. INBOUND -- the two, and only two, integration shapes this
    resource uses, and why a third shape (a per-hook `{ event = '...',
    export = '...', enabled = bool }` config table) was considered and
    rejected for this pass:

    OUTBOUND (a fact THIS resource announces -- "a K9 went down", "a search
    found contraband", "a cert was granted") -- a plain `TriggerEvent` on the
    stable `qbx_k9unit:events:*` namespace server/exports.lua's header
    documents, with ZERO config surface. Any resource -- dispatch, MDT, a
    Discord bridge, a homebrew logger, something that does not exist yet --
    reacts by writing exactly one `AddEventHandler('qbx_k9unit:events:...',
    function(...) ... end)`, from documentation alone, with no coupling to
    this resource's internals and no possibility of ever seeing an error
    thrown by a handler this resource doesn't know exists. This is already
    how six events work today (server/exports.lua's EVENT CONTRACT) and this
    file adds a seventh (k9Down) the identical way. A `{ event = '...',
    export = '...', enabled = bool }`-shaped config table for THIS direction
    would be strictly WORSE, not merely unnecessary: it would let an
    operator "rename" the event we fire (a new place to typo, and a reason a
    listener written straight from this file's docs would silently stop
    matching), and an `export` variant would mean calling into exactly ONE
    named resource -- the single-integration assumption this whole task
    exists to forbid. `TriggerEvent` already IS the any-number-of-listeners,
    zero-coupling primitive; wrapping it in config changes nothing for the
    better and adds a real footgun.

    INBOUND (a fact THIS resource needs FROM an operator's own system --
    "is this player wanted", "is this player downed") -- a bare
    `function(...) -> value` Config field, nil by default, called through
    pcall, FAILS CLOSED on error or absence. Already shipped twice, not
    invented here: `Config.Combat.WantedStatusCheckOverride` and
    `Config.Combat.PropDragging.IsPlayerDownedOverride`. Neither hook this
    file adds needs to ask an operator's own system anything, so this file
    introduces NO new inbound config -- it is pure OUTBOUND, which is a
    deliberate reflection of what Part A §7 / Part B §2 / §3 actually need,
    not an oversight. If a genuine future hook ever needs an answer FROM an
    external system, follow this exact shape (bare function, nil default,
    pcall, fail closed) rather than inventing a third one.

    ======================================================================
    WHAT'S ALREADY DONE, NOT DUPLICATED HERE (verified by direct read of
    server/exports.lua's EVENT CONTRACT and config.lua before writing a
    single line of this file):
    - Part B §2's OUTBOUND half ("a completed contraband search... fires a
      dispatch call") -- already covered by
      'qbx_k9unit:events:searchCompleted' (server/exports.lua EVENT
      CONTRACT #5, wired in server/search.lua's LogSearchAttempt).
    - Part B §2's INBOUND half (asking a real dispatch/wanted system instead
      of guessing off metadata.wanted) -- already covered by
      `Config.Combat.WantedStatusCheckOverride` (config.lua, consumed by
      server/combat.lua's IsPlayerWantedEligible).
    - Part B §3's certification half ("MDT relevance" for grant/revoke) --
      already covered by 'qbx_k9unit:events:certificationGranted' /
      'qbx_k9unit:events:certificationRevoked' (EVENT CONTRACT #1/#2, wired
      in server/certifications.lua).
    - Part B §5's ambulance/laststand half -- already covered by
      `Config.Combat.PropDragging.IsPlayerDownedOverride`, per that config
      field's own comment ("Reuses ... rather than adding its own").
    None of the above needed a single line changed for this pass -- listed
    here so a reader of THIS file (the one place someone will look for "the
    integration surface") does not go hunting for something that already
    shipped under a different file's byline.

    ======================================================================
    RECOMMENDED, NOT APPLIED HERE -- server/search.lua's ownership this
    session belongs to the XP-economy agent (see the coordination map), so
    this is reported rather than edited: 'qbx_k9unit:events:searchCompleted'
    's payload (searcherCitizenid, searcherJob, targetType, result,
    totalWeight?, alertTier?) carries no identifier for WHAT was searched --
    an MDT wanting to attach a `found` result to a real case/evidence record
    (Part B §3's actual stated goal, "turns 'the K9 found drugs' into an
    actual case artifact") cannot do that from this payload alone. Both
    missing values (`plateOrNil`, `targetCitizenidOrNil`) are ALREADY local
    variables in scope at server/search.lua's own
    `FireOutboundEvent('qbx_k9unit:events:searchCompleted', ...)` call site
    inside LogSearchAttempt -- this would be a strictly additive two-argument
    change (MINOR per server/exports.lua's own versioning posture; never
    reordering or removing an existing argument), not a redesign. Left for
    that file's actual owner to apply; noted here so the gap stays visible
    to whoever next has authority over it, rather than being silently
    reopened as "new" by a future audit.

    ======================================================================
    K9-DOWN DISPATCH HOOK (FEATURE_IDEAS.md Part A §7, THIS FILE's actual
    new logic) -- 'qbx_k9unit:events:k9Down'.

    WHY A SELF-CONTAINED POLL, NOT A HOOK INSIDE server/wellbeing.lua'S
    EXISTING TickWellbeing LOOP: that loop already iterates every online K9
    once per Config.Wellbeing.tickIntervalMs and already reads
    GetEntityHealth(ped) under Config.Features.InjuryLimping -- a textbook
    "add one call at an existing success path." server/wellbeing.lua is
    owned by the injury agent this session (see the coordination map), so
    this file does not edit it. Part A §7's own text explicitly names the
    alternative used here ("doable even earlier off raw GetEntityHealth
    polling if wanted sooner") -- this is that alternative, not a shortcut
    taken without grounds. Flagged as a genuine, disclosed future
    consolidation opportunity: whoever next owns server/wellbeing.lua could
    fold this file's detection into that shared tick loop and delete this
    file's own thread, with no change to the event contract itself.

    DETECTION SHAPE, mirroring server/wellbeing.lua's own
    PED_DEAD_HEALTH_THRESHOLD / MIN_DEATH_EPISODE_DURATION_MS pattern (same
    file) rather than inventing an unrelated one: a raw native-health read,
    edge-triggered (fires at most once per continuous at/below-threshold
    episode, never once per poll tick), with a minimum qualifying duration
    so an ordinary combat graze healed a moment later never fires a dispatch
    alert. See Config.K9DownDispatch below (reported to the config owner,
    not edited here) for the exact tuning values.

    WHO COUNTS: a currently-connected player whose live ped model is a
    configured K9 model (IsConfiguredK9Model, server/certifications.lua) AND
    who currently has K9 access (HasK9Access, same file) -- i.e. a real,
    on-duty, certified handler's K9, not merely anyone who happens to be
    wearing a dog skin. Both are resource-global functions from
    server/certifications.lua, called directly with no runtime existence
    guard: unlike a genuinely optional soft dependency (a different feature
    file that might be removed or whose flag might be off), certifications.lua
    is this resource's own permission-system root and is always present,
    loaded well before this file (fxmanifest.lua's own server_scripts order),
    matching every other same-resource, same-load-time caller of these two.

    PAYLOAD: 'qbx_k9unit:events:k9Down' (source: number, citizenid: string,
    jobName: string, coords: vector3, health: number). `source` is the
    live, currently-connected server id at the moment of firing -- a
    listener that wants to act on it (e.g. TriggerClientEvent a nearby
    unit) should treat it exactly as any other TriggerEvent payload: a
    hint, not a guarantee the source is still connected by the time the
    listener's own handler runs. `coords` is included deliberately, unlike
    this resource's other outbound events -- a dispatch alert is the one
    integration in this whole contract for which a map location is the
    entire point (an "Officer K9 Down" board entry with no location is not
    useful), so this one payload carries it while the others correctly do
    not manufacture a location need they don't have.

    NOT IN SCOPE: a corresponding "recovered"/"cleared" event. Nothing in
    Part A §7 asks for one, and this resource's own minimalism convention
    (HandlerDownDefense: "detection only, never enforcement") argues against
    announcing something nobody asked for. A dispatch resource that wants a
    "cleared" concept can already infer one from its own timeout, the same
    way a real dispatch board ages out a stale call.
    ======================================================================

    DESIGN PRINCIPLES (mirrors server/exports.lua's, restated for the
    boundary this file specifically guards):
    1. RE-DERIVE, NEVER TRUST. Every value in the k9Down payload is read
       fresh, server-side, at the moment of firing -- never a client claim.
    2. FAIL CLOSED, NEVER THROW ACROSS THE RESOURCE BOUNDARY. FireOutboundEvent
       below pcall-wraps the TriggerEvent call, exactly like every other
       file in this resource's own copy of this helper (certifications.lua,
       partnership.lua, progression.lua, search.lua) -- a misbehaving
       listener's own AddEventHandler throwing can never unwind back into
       this file's own poll thread. This is the file's fifth copy of this
       six-line helper; extracting it to a shared global would mean editing
       four files this pass does not own to delete their copies -- reported
       as a legitimate future cleanup, not done here.
    3. ABSENCE IS A CLEAN NO-OP. With Config.Features.K9DownDispatch false
       (or absent), this file starts no thread, allocates no table, and
       calls TriggerEvent zero times -- a server with no dispatch resource
       listening sees zero errors and zero log spam, identically whether the
       flag is on or off, since TriggerEvent-ing to zero registered handlers
       is itself already a documented no-op in FXServer.
    ======================================================================
]]

if not Config.Features.K9DownDispatch then return end

-- CONFIG-SAFETY GUARD -- run at this file's own LOAD time, NOT deferred into
-- an onResourceStart handler (server/certifications.lua's own header gives
-- the identical reasoning for the identical structural reason): the
-- K9DownFireCooldown construction a few lines below this guard calls
-- NewCooldown(tuning.reFireCooldownMs) immediately, at this file's own load
-- time -- by the time any onResourceStart handler could run, that call has
-- already executed (and, unguarded, would already have crashed loudly via
-- NewCooldown's own AssertValidDefaultThreshold, just with a less specific
-- message than the asserts below give). config.lua is a shared_script,
-- loaded in full before any server_scripts file (this one included) starts
-- executing, so Config already holds its real, final values by the time
-- this line runs -- not a load-order gamble.
local tuning = Config.K9DownDispatch
assert(type(tuning) == 'table',
    '[qbx_k9unit] Config.K9DownDispatch must be a table when Config.Features.K9DownDispatch is true -- ' ..
    'this file reads healthThreshold/minDurationMs/pollIntervalMs/reFireCooldownMs from it unconditionally ' ..
    'once the feature flag is on.')
assert(type(tuning.healthThreshold) == 'number' and tuning.healthThreshold == tuning.healthThreshold and tuning.healthThreshold > 0,
    '[qbx_k9unit] Config.K9DownDispatch.healthThreshold must be a positive number -- compared directly against ' ..
    "GetEntityHealth(ped) in this file's own poll loop below; a non-positive or NaN value would make every " ..
    'online K9 read as permanently down (or never down at all), silently.')
assert(type(tuning.minDurationMs) == 'number' and tuning.minDurationMs == tuning.minDurationMs and tuning.minDurationMs >= 0,
    '[qbx_k9unit] Config.K9DownDispatch.minDurationMs must be a non-negative number -- 0 is a legitimate choice ' ..
    '("fire on the very first qualifying poll tick, no debounce"), but nil/a string/NaN/negative is a config error.')
assert(type(tuning.pollIntervalMs) == 'number' and tuning.pollIntervalMs > 0,
    '[qbx_k9unit] Config.K9DownDispatch.pollIntervalMs must be a positive number -- passed directly to Wait() in ' ..
    "this file's own poll thread below; a non-positive value would poll needlessly tightly for a feature whose " ..
    'entire purpose is periodic background monitoring, not a per-frame check.')
-- reFireCooldownMs is intentionally NOT re-validated here beyond what
-- NewCooldown(tuning.reFireCooldownMs) below already enforces on its own --
-- see AssertValidDefaultThreshold in server/cooldowns.lua, which errors
-- loudly (naming that exact constructor call) on anything that isn't a
-- valid positive number. Duplicating that check here would only race it:
-- this file's own assert would have to run BEFORE the NewCooldown call a
-- few lines down to ever actually be the one that fires, and would gain
-- nothing over letting the already-loud, already-tested existing guard do
-- its job.

--- MOVED to server/events.lua (2026-08-25 cross-file cleanup pass): this
--- file's header's own DESIGN PRINCIPLE 2 deferred this exact
--- consolidation to "whoever next does a genuine cross-file cleanup pass";
--- that pass has now happened. This file's own copy, byte-for-byte
--- identical to the five others that existed alongside it, is now the
--- single shared resource-global implementation in that file. See
--- server/events.lua's header for the full extraction writeup. The one
--- call site below is unchanged: same event name, arguments, and firing
--- condition.

-- Per-source candidate-episode state -- see this file's header "DETECTION
-- SHAPE" for the episode/edge-trigger design this backs.
-- K9DownState[source] = { candidateDownSince = <GetGameTimer() ms, 0 = not
--   currently in a candidate episode>, firedThisEpisode = boolean }
-- Deliberately NOT a server/cooldowns.lua NewCooldown/NewMutex instance --
-- same "different shape entirely, do not force it onto the cooldown
-- constructors" reasoning server/search.lua's own ContrabandXpState gives
-- for its own bespoke table: this tracks an episode START TIME and a fired
-- FLAG, not a single "has enough time elapsed" instant, so it does not fit
-- either constructor. Cleared per-source on disconnect below -- a
-- disconnected K9 has nothing further to report.
local K9DownState = {}

AddEventHandler('playerDropped', function()
    K9DownState[source] = nil
end)

-- Flat per-source cooldown on the FIRE itself (not the detection) -- a
-- backstop against a K9 flapping across the threshold boundary faster than
-- minDurationMs alone would filter (e.g. a heal landing exactly mid-episode
-- and a re-injury moments later), independent of the episode/edge-trigger
-- logic above. Mirrors this resource's own established "flat per-source
-- cooldown, a real server/cooldowns.lua tracker, never a hand-rolled table"
-- convention. NewCooldown's own constructor guard
-- (AssertValidDefaultThreshold) already errors loudly at this exact line if
-- tuning.reFireCooldownMs is not a valid positive number -- see the CONFIG-
-- SAFETY GUARD comment above for why that is deliberately relied on here
-- rather than re-checked.
local K9DownFireCooldown = NewCooldown(tuning.reFireCooldownMs)
K9DownFireCooldown.RegisterPlayerDropped()

--- One poll pass over every currently-connected player -- see this file's
--- header "WHO COUNTS" / "DETECTION SHAPE" for the full design this
--- implements.
local function PollK9Health()
    local now = GetGameTimer()

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local ped = GetPlayerPed(src)
            if ped == 0 then
                -- Not actually a live, spawned player ped right now (still
                -- loading in, or GetPlayers() briefly stale) -- clear any
                -- stale episode state rather than let a later reconnect
                -- inherit an unrelated old episode.
                K9DownState[src] = nil
            elseif not (IsConfiguredK9Model(GetEntityModel(ped)) and HasK9Access(src)) then
                -- Not currently a real, on-duty, certified K9 (WHO COUNTS
                -- above) -- clear any stale episode so a K9 who lost
                -- certification or changed model mid-episode cannot later
                -- fire off a health reading taken before that change.
                K9DownState[src] = nil
            else
                local health = GetEntityHealth(ped)
                local state = K9DownState[src]
                if not state then
                    state = { candidateDownSince = 0, firedThisEpisode = false }
                    K9DownState[src] = state
                end

                if health <= tuning.healthThreshold then
                    if state.candidateDownSince == 0 then
                        state.candidateDownSince = now
                    end

                    if not state.firedThisEpisode and (now - state.candidateDownSince) >= tuning.minDurationMs then
                        if K9DownFireCooldown.Consume(src) then
                            local Player = exports.qbx_core:GetPlayer(src)
                            local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
                            local jobName = Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.name
                            if citizenid and jobName then
                                FireOutboundEvent('qbx_k9unit:events:k9Down', src, citizenid, jobName, GetEntityCoords(ped), health)
                                state.firedThisEpisode = true
                            end
                            -- else: a transient exports.qbx_core:GetPlayer
                            -- resolution miss -- firedThisEpisode stays
                            -- false, so the very next poll tick (while
                            -- health is still <= threshold) tries again;
                            -- the fire cooldown above was already consumed
                            -- though, so a genuinely persistent resolution
                            -- failure is still bounded by
                            -- reFireCooldownMs, not retried every single
                            -- poll tick forever.
                        end
                        -- else: still within reFireCooldownMs of a PRIOR
                        -- fire (a different earlier episode, or this same
                        -- one's own earlier attempt) -- firedThisEpisode
                        -- stays false, so this retries on the very next
                        -- poll tick once the cooldown clears, rather than
                        -- permanently giving up on reporting a K9 that is
                        -- STILL down right now.
                    end
                else
                    state.candidateDownSince = 0
                    state.firedThisEpisode = false
                end
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(tuning.pollIntervalMs)
        local ok, err = pcall(PollK9Health)
        if not ok then
            print(('[qbx_k9unit] K9-down dispatch poll error: %s'):format(tostring(err)))
        end
    end
end)
