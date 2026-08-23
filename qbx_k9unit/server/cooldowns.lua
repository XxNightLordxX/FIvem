--[[
    qbx_k9unit/server/cooldowns.lua

    coder-architect, REFACTOR_ROADMAP.md item 1 ("Extract the shared
    cooldown/TTL/mutex helper now — retroactively, not preemptively").
    Pure structural extraction, NOT a redesign: every one of the 11
    independent hand-rolled cooldown/mutex tables inventoried in the
    roadmap's Phase 2 retrospective is migrated onto the constructors below
    with its exact existing threshold, keying, and cleanup timing preserved
    — see each call site's own comment (server/main.lua,
    server/certifications.lua, server/tracking.lua, server/search.lua) for
    the "migrated from X, behavior unchanged" note.

    Loaded FIRST in fxmanifest.lua's server_scripts (before main.lua,
    certifications.lua, tracking.lua, search.lua) since it exposes
    resource-global (no `local`) constructor functions those four files
    call at their own file-load time to build their own private tracker
    instances — same "global helper, private per-file state" shape
    HasK9Access/IsConfiguredK9Model already established in
    server/certifications.lua, just for the cooldown/mutex pattern instead
    of the access-check pattern.

    WHY A NEW FILE, NOT FOLDED INTO server/certifications.lua OR
    server/main.lua: this resource's existing convention (per both of
    those files' own headers) is that a shared file should be scoped to ONE
    responsibility so it doesn't balloon into an everything-file as later
    phases add more call sites — certifications.lua is scoped to
    grant/revoke/check, main.lua to small gated actions + the leash
    subsystem. A generic timing/mutex primitive used by all four
    server files (plus, per the roadmap's own "Order" note, whatever
    Phase 3 combat/agility cooldown comes next) is exactly the kind of
    cross-cutting mechanism that belongs in its own file rather than
    attached to one of the four call sites as if it were that file's
    private concern.

    THREE CONSTRUCTORS, not one over-generalized function — because the 11
    real call sites genuinely split into three different shapes, confirmed
    by reading all four files' actual implementations (not just the
    roadmap's summary table) before writing this:

    1. NewCooldown(defaultThresholdMs?) — a flat `key -> lastTouchedAtMs`
       tracker. Covers every single-level cooldown in this resource:
       lastBarkAt, lastLeashRequestAt, lastDoorScratchAt (all three keyed by
       player source), lastDoorScratchAtByDoor (keyed by doorNetId, NOT a
       player source), lastCertifyActionAt (keyed by the certifier's
       source), lastDamageRelayAt, lastWeaponFireRelayAt (both keyed by
       source), lastSearchAt (keyed by source), lastTargetSearchAt (keyed by
       a resolved 'vehicle:<plate>' | 'person:<citizenid>' string, NOT a
       player source). That's 9 of the 11 tables — despite the very
       different key domains (source vs. doorNetId vs. resolved-identity
       string), the read/check/stamp/evict MECHANICS are identical in every
       one of them; only the key type and the cleanup hook differ, both of
       which this constructor already takes as call-site-supplied values
       rather than baking in an assumption that the key is a player source.

    2. NewNestedCooldown(defaultThresholdMs?) — a two-level
       `primaryKey -> { secondaryKey -> lastTouchedAtMs }` tracker. Exactly
       one real call site needs this shape:
       server/tracking.lua's LastTrackQueryAt[source][trackType]. Kept as
       its own constructor rather than forcing callers to compose a single
       string key (e.g. `source .. ':' .. trackType`) into NewCooldown,
       because the ORIGINAL table's playerDropped cleanup clears every
       trackType for a disconnecting source in one shot
       (`LastTrackQueryAt[src] = nil`) — a composite-string-keyed flat
       table cannot replicate that without an extra linear scan-and-match
       pass, which would be a behavior-preserving but needlessly more
       expensive migration than just keeping the two-level shape the
       original code already chose for exactly this reason.

    3. NewMutex() — a flat `key -> true|nil` held-flag, no timestamp/
       threshold at all. Exactly one real call site needs this shape:
       server/search.lua's SearchInFlight. Deliberately NOT modeled as
       "NewCooldown with threshold = infinity" — a mutex is
       acquire/release, not check/consume-after-elapsed-time, and giving it
       its own tiny constructor makes the call site
       (`if not SearchMutex.TryAcquire(source) then ... end` /
       `SearchMutex.Release(source)`) read as what it actually is instead of
       a cooldown pretending to have no expiry.

    CLEANUP: two mechanisms, matching the two that already existed —
    neither is "better," they're for genuinely different key domains:
      - :RegisterPlayerDropped() — for any tracker keyed by player source.
        Registers its own `AddEventHandler('playerDropped', ...)` closure
        that clears that source's entry. Multiple trackers each calling
        this independently is fine — FXServer dispatches every registered
        handler for a given `playerDropped` invocation with the same
        `source` value.
      - :StartSweep(intervalMs, isStaleFn) — for a tracker keyed by
        something with no per-connection hook (a door's netId, a resolved
        plate/citizenid identity that outlives any one connection). Runs
        its own `CreateThread` loop, exactly mirroring the shape every
        existing sweep thread in this resource already used (a `pairs`
        traversal with in-place `nil` removal, safe in Lua since clearing
        the CURRENT key mid-traversal is well-defined) — just parameterized
        by the caller's own staleness predicate and interval instead of
        each file hand-writing the loop.

    DELIBERATELY NOT MIGRATED, OUT OF SCOPE FOR THIS PASS:
    server/tracking.lua's `TrackableLog` (the blood/gunpowder event log) and
    its `PruneTrackableLogs` sweep thread are NOT one of the 11 cooldown/
    mutex tables and are NOT touched here. They're a different shape
    entirely — an append-only ARRAY of `{coords, loggedAt}` entries pruned
    by age and separately scanned-by-distance at query time, not a
    `key -> lastTouchedAtMs` map at all. REFACTOR_ROADMAP.md's own inventory
    table (and its item-1 tally of exactly 11 tables) does not count
    TrackableLog among them, and separately flags the "array of aged log
    entries, nearest-match scan" shape as medium-term item 5
    (`FindNearestEntity`), explicitly deferred as "worth a light look, not
    urgent" rather than folded into this pass. Forcing it onto NewCooldown/
    NewNestedCooldown here would be exactly the "over-generalized function"
    the task asked this extraction to avoid.

    API surface below intentionally mirrors the exact read/check/stamp
    ORDER every migrated call site already used, so migrating a call site is
    a mechanical swap, not a reordering:
      :IsOnCooldown(key, thresholdMs?, now?) -> boolean   -- check only, never mutates
      :Touch(key, now?)                                    -- stamp only, never checks
      :Consume(key, thresholdMs?, now?) -> boolean allowed -- check, and stamp iff allowed (false = still on cooldown, nothing stamped)
      :Clear(key)                                          -- evict one entry
      :RegisterPlayerDropped()                             -- see above
      :StartSweep(intervalMs, isStaleFn)                    -- see above
    NewNestedCooldown's methods take (primaryKey, secondaryKey, ...) in
    place of a single `key`, except :Clear(primaryKey), which — matching the
    original LastTrackQueryAt[src] = nil shape — drops every secondaryKey
    under that primaryKey in one call, not one specific secondaryKey.
    NewMutex only exposes :TryAcquire(key), :Release(key), :IsHeld(key), and
    :RegisterPlayerDropped() — no threshold-based methods, per the "not a
    cooldown pretending to have no expiry" reasoning above.
]]

--- Flat, single-level `key -> lastTouchedAtMs` cooldown tracker. See this
--- file's header for the full list of the 9 real call sites this covers.
--- @param defaultThresholdMs number? -- used by :IsOnCooldown/:Consume when no per-call override is given; several call sites (e.g. door-scratch, per-target search) read a Config value that could differ per invocation, so this is a convenience default, not a hard requirement.
--- @return table tracker
function NewCooldown(defaultThresholdMs)
    local store = {}
    local tracker = {}

    --- Check-only — never stamps/mutates anything. Mirrors every existing
    --- call site's own `if store[key] and (now - store[key]) < threshold`
    --- read.
    --- @param key any
    --- @param thresholdMs number?
    --- @param now number? -- override GetGameTimer(); pass the SAME timestamp already captured earlier in a call site that needs to compare multiple cooldowns against one consistent instant (mirrors the original code's own single-`now`-variable pattern).
    --- @return boolean
    function tracker.IsOnCooldown(key, thresholdMs, now)
        local lastAt = store[key]
        if not lastAt then return false end
        local threshold = thresholdMs or defaultThresholdMs
        if not threshold or threshold <= 0 then
            -- FAIL CLOSED: an absent (no per-call override AND no
            -- constructor default) or non-positive (0/negative) threshold
            -- is always a caller bug (nil arithmetic, a misconfigured
            -- Config value, a future call site forgetting its override) —
            -- `elapsed < 0` is never true, so treating it as a normal
            -- threshold would silently and permanently disable this
            -- cooldown for every already-touched key instead of erroring
            -- loudly. Never let a bad threshold turn into unlimited spam.
            return true
        end
        return ((now or GetGameTimer()) - lastAt) < threshold
    end

    --- Stamp-only — never checks anything.
    --- @param key any
    --- @param now number?
    function tracker.Touch(key, now)
        store[key] = now or GetGameTimer()
    end

    --- Check-and-consume: true (and `key` is stamped to `now`/GetGameTimer())
    --- if `key` is NOT currently on cooldown; false (and NOTHING is
    --- stamped) if it is. This is the single most common shape among the
    --- 9 flat tables this constructor covers — "stamp BEFORE the guarded
    --- work" falls out naturally since the stamp happens synchronously
    --- inside this call, before the caller does anything else.
    --- @param key any
    --- @param thresholdMs number?
    --- @param now number?
    --- @return boolean allowed
    function tracker.Consume(key, thresholdMs, now)
        if tracker.IsOnCooldown(key, thresholdMs, now) then
            return false
        end
        tracker.Touch(key, now)
        return true
    end

    --- Drops `key`'s entry entirely.
    --- @param key any
    function tracker.Clear(key)
        store[key] = nil
    end

    --- For a tracker keyed by player source ONLY. Registers a dedicated
    --- `playerDropped` handler that clears the disconnecting source's own
    --- entry. Do NOT call this for a tracker keyed by anything else
    --- (doorNetId, a resolved plate/citizenid string) — use :StartSweep
    --- instead, since a non-player key has no per-connection hook to clean
    --- up on.
    function tracker.RegisterPlayerDropped()
        AddEventHandler('playerDropped', function()
            tracker.Clear(source)
        end)
    end

    --- For a tracker with no natural per-connection cleanup hook. Starts a
    --- periodic sweep thread evicting any entry `isStaleFn(now, loggedAt)`
    --- reports as stale. Exactly mirrors the shape every existing sweep
    --- thread in this resource already used before this extraction.
    --- @param intervalMs number
    --- @param isStaleFn fun(now: number, loggedAt: number): boolean
    function tracker.StartSweep(intervalMs, isStaleFn)
        CreateThread(function()
            while true do
                Wait(intervalMs)
                local now = GetGameTimer()
                for key, loggedAt in pairs(store) do
                    if isStaleFn(now, loggedAt) then
                        store[key] = nil
                    end
                end
            end
        end)
    end

    return tracker
end

--- Two-level `primaryKey -> { secondaryKey -> lastTouchedAtMs }` cooldown
--- tracker. Exactly one real call site needs this shape — see this file's
--- header for why it's a separate constructor rather than a composite
--- string key into NewCooldown.
--- @param defaultThresholdMs number?
--- @return table tracker
function NewNestedCooldown(defaultThresholdMs)
    local store = {}
    local tracker = {}

    --- @param primaryKey any
    --- @param secondaryKey any
    --- @param thresholdMs number?
    --- @param now number?
    --- @return boolean
    function tracker.IsOnCooldown(primaryKey, secondaryKey, thresholdMs, now)
        local bucket = store[primaryKey]
        local lastAt = bucket and bucket[secondaryKey]
        if not lastAt then return false end
        local threshold = thresholdMs or defaultThresholdMs
        if not threshold or threshold <= 0 then
            -- FAIL CLOSED — see NewCooldown's IsOnCooldown for the full
            -- reasoning: a bad/missing threshold must never silently
            -- disable this cooldown.
            return true
        end
        return ((now or GetGameTimer()) - lastAt) < threshold
    end

    --- @param primaryKey any
    --- @param secondaryKey any
    --- @param now number?
    function tracker.Touch(primaryKey, secondaryKey, now)
        store[primaryKey] = store[primaryKey] or {}
        store[primaryKey][secondaryKey] = now or GetGameTimer()
    end

    --- @param primaryKey any
    --- @param secondaryKey any
    --- @param thresholdMs number?
    --- @param now number?
    --- @return boolean allowed
    function tracker.Consume(primaryKey, secondaryKey, thresholdMs, now)
        if tracker.IsOnCooldown(primaryKey, secondaryKey, thresholdMs, now) then
            return false
        end
        tracker.Touch(primaryKey, secondaryKey, now)
        return true
    end

    --- Clears EVERY secondaryKey entry under `primaryKey` in one call —
    --- matches the original flat `store[primaryKey] = nil` playerDropped
    --- cleanup shape (e.g. LastTrackQueryAt[src] = nil dropping
    --- scent/blood/gunpowder all at once for that source).
    --- @param primaryKey any
    function tracker.Clear(primaryKey)
        store[primaryKey] = nil
    end

    --- For a tracker whose primaryKey is a player source. See NewCooldown's
    --- :RegisterPlayerDropped doc comment — same reasoning, applied to the
    --- primaryKey level here.
    function tracker.RegisterPlayerDropped()
        AddEventHandler('playerDropped', function()
            tracker.Clear(source)
        end)
    end

    return tracker
end

--- Per-key mutex (boolean held-flag, no timestamp/threshold at all). See
--- this file's header for why this is a separate constructor from
--- NewCooldown rather than a cooldown with an infinite threshold.
--- @return table mutex
function NewMutex()
    local held = {}
    local mutex = {}

    --- Atomically checks-and-sets in one call — true (and `key` becomes
    --- held) if `key` was NOT already held; false (and nothing changes) if
    --- it was. Preserves the original SearchInFlight call site's exact
    --- "reject outright, never queue/race a concurrent call from the same
    --- source" behavior.
    --- @param key any
    --- @return boolean acquired
    function mutex.TryAcquire(key)
        if held[key] then return false end
        held[key] = true
        return true
    end

    --- Releases `key`. Safe to call even if `key` was never held (matches
    --- the original `SearchInFlight[source] = nil` unconditional-clear
    --- shape used on every exit path).
    --- @param key any
    function mutex.Release(key)
        held[key] = nil
    end

    --- @param key any
    --- @return boolean
    function mutex.IsHeld(key)
        return held[key] == true
    end

    --- For a mutex keyed by player source. Same reasoning as NewCooldown's
    --- :RegisterPlayerDropped.
    function mutex.RegisterPlayerDropped()
        AddEventHandler('playerDropped', function()
            mutex.Release(source)
        end)
    end

    return mutex
end
