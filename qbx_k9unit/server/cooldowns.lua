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

    ======================================================================
    FAIL-CLOSED THRESHOLD HANDLING — SETTLED THIS PASS (coder-backend,
    following a Phase 5 review that found the live consequence of this in
    server/fetch.lua's releaseFetchBall, fixed separately in that file):
    IsOnCooldown/Consume on BOTH constructors below have always treated a
    missing/non-positive threshold as "permanently on cooldown" (fail
    closed), never as "no cooldown" — correct for this file's own stated
    goal (never let a bad threshold turn into unlimited spam), but entirely
    SILENT, which is exactly how server/fetch.lua's bug went unnoticed: a
    `Config.X = 0` intended by an operator/author to mean "no throttle" reads
    as truthy in Lua (`0 or 500` evaluates to `0`, not `500`), so it reaches
    this file as a real, accepted, wrong default with no signal anything was
    off until a player got permanently stuck.

    Two independent backstops now close that silence, matching what each
    call SHAPE actually allows this file to catch:
      1. CONSTRUCTOR TIME (AssertValidDefaultThreshold, used by both
         NewCooldown and NewNestedCooldown): a non-nil defaultThresholdMs
         that isn't a valid threshold now ERRORS immediately, at resource
         start, before any player ever reaches the guarded action — this is
         the majority call shape in this resource (a Config value captured
         once as the constructor's own default, e.g.
         `NewCooldown(Config.FetchMechanic.pickupCooldownMs or 500)`), and
         turns a fetch.lua-shaped mistake into a startup crash naming the
         exact constructor, not a report filed weeks later. Verified against
         EVERY current NewCooldown/NewNestedCooldown call site in this
         resource before landing this (grep of every call site + every
         corresponding config.lua default, this pass's own report) — every
         shipped default is already a positive number, so this is a new
         backstop against FUTURE misconfiguration, not a behavior change for
         anything currently deployed.
      2. CALL TIME (inside :IsOnCooldown itself, both constructors): a
         per-call `thresholdMs` override read fresh from Config on every
         invocation (the OTHER real shape in this resource — e.g.
         server/wellbeing.lua's `IsOnCooldown(src,
         Config.Tracking.Blood.relayCooldownMs)`, never captured as a
         constructor default) cannot be validated at construction time at
         all, since the constructor never sees it. The RETURN VALUE here is
         UNCHANGED (still fails closed, still `true`) — every existing
         caller and this file's own tests keep working exactly as before —
         but the first time any given tracker instance hits this branch, it
         now prints one unmissable console line naming the key and the bad
         threshold, instead of failing silently forever. Printed once per
         tracker instance (not once per call) so an already-broken config
         under real traffic produces one line, not a flood.
    Neither backstop changes IsValidThreshold's actual verdict (still
    rejects nil/non-number/zero/negative) — NaN is now also explicitly
    rejected (`value == value` is Lua's standard NaN test; `value <= 0`
    alone does NOT catch NaN, since every comparison against NaN is false,
    which would otherwise slip through as "looks positive" and then make
    every later `elapsed < threshold` comparison ALSO always false —
    fail OPEN, unlimited spam, the one outcome this whole file exists to
    prevent). See IsValidThreshold's own doc comment below for the full
    reasoning.

    NOT CHANGED, DELIBERATELY: the GetGameTimer() wraparound caveat
    documented on both IsOnCooldown implementations below is a SEPARATE,
    already-disclosed issue (a ~24.85-day int32 wrap, not a
    threshold-validity question) and still needs the coordinated,
    reported pass its own comment already calls for — not folded into this
    pass.
    ======================================================================
]]

--- Shared validity test for any threshold this file ever compares elapsed
--- time against — a threshold is valid iff it is a finite, positive Lua
--- number. Centralized so NewCooldown/NewNestedCooldown's constructor guard
--- and their :IsOnCooldown call-time guard can never drift apart on what
--- counts as "bad". Rejects, in one pass:
---   - nil / non-number (the "no threshold supplied at all" case),
---   - 0 or negative (see FOOTGUN below — never a valid "disabled" signal),
---   - NaN (`t ~= t` is Lua's standard NaN test — `t <= 0` alone does NOT
---     catch this, since EVERY comparison against NaN is false; an
---     uncaught NaN would silently fall through as "looks positive" and
---     then make every later `elapsed < threshold` comparison ALSO false
---     forever, i.e. fail OPEN — unlimited spam — the one direction this
---     whole file exists to prevent).
---
--- FOOTGUN THIS EXISTS TO CATCH (found for real in server/fetch.lua's
--- releaseFetchBall, a path documented as "always let go", by a Phase 5
--- review — coder-architect/coder-backend, this pass): an operator setting
--- a cooldown Config field to `0` meaning "no throttle" instead silently
--- got "blocked forever", because `0 or 500`-style fallback idioms treat 0
--- as present (0 is truthy in Lua) and this file's own :IsOnCooldown then
--- fails closed on it. server/recall.lua already worked around this
--- independently for Config.Recall.RequestCooldownMs (falls back to a
--- built-in constant and prints a warning rather than trusting a raw
--- non-positive config read) — this constructor-time guard below makes
--- that same class of mistake loud AT RESOURCE START for the common
--- "NewCooldown(Config.X.cooldownMs)" shape (verified: every current
--- NewCooldown/NewNestedCooldown call site's shipped config.lua default is
--- a positive number — see this pass's own report — so this is a new
--- backstop, not a behavior change for any currently-shipped config), and
--- :IsOnCooldown's own call-time branch below now prints a one-time loud
--- warning (never silent) for the remaining shape this can't catch at
--- construction: a per-call threshold read fresh from Config on every
--- invocation rather than captured as a constructor default.
--- @param value any
--- @return boolean
local function IsValidThreshold(value)
    return type(value) == 'number' and value == value and value > 0
end

--- Fails loudly (error, not a silent accept) if `defaultThresholdMs` was
--- supplied (non-nil) and is not a valid threshold per IsValidThreshold
--- above. A nil default is always fine — it just means every call to this
--- tracker must supply its own per-call override (several real call sites
--- in this resource construct exactly this way, e.g. AuditCooldown in
--- server/admin.lua). Only a NON-nil-but-invalid default is a caller bug,
--- and this is the one shape this file CAN catch at resource-start time,
--- before any player ever reaches the guarded action — see IsValidThreshold
--- above for why this matters and what it can't catch (per-call-only
--- thresholds, guarded separately at call time below).
--- @param defaultThresholdMs any
--- @param constructorName string
local function AssertValidDefaultThreshold(defaultThresholdMs, constructorName)
    if defaultThresholdMs ~= nil and not IsValidThreshold(defaultThresholdMs) then
        error(
            ('[qbx_k9unit] %s called with a non-positive/invalid defaultThresholdMs (%s). ' ..
             '0 or a negative number here does NOT mean "no cooldown" -- this file\'s ' ..
             'IsOnCooldown fails CLOSED on a non-positive threshold (permanently blocks the ' ..
             'guarded action instead), which is almost never the intent. Pass nil instead if ' ..
             'no default is wanted, or fix the Config value this was read from.')
                :format(constructorName, tostring(defaultThresholdMs)),
            3 -- blame the constructor call site, not this line
        )
    end
end

--- Flat, single-level `key -> lastTouchedAtMs` cooldown tracker. See this
--- file's header for the full list of the 9 real call sites this covers.
--- @param defaultThresholdMs number? -- used by :IsOnCooldown/:Consume when no per-call override is given; several call sites (e.g. door-scratch, per-target search) read a Config value that could differ per invocation, so this is a convenience default, not a hard requirement. Validated by AssertValidDefaultThreshold above when non-nil — see that function's doc comment.
--- @return table tracker
function NewCooldown(defaultThresholdMs)
    AssertValidDefaultThreshold(defaultThresholdMs, 'NewCooldown')

    local store = {}
    local tracker = {}
    local warnedBadCallTimeThreshold = false

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
        if not IsValidThreshold(threshold) then
            -- FAIL CLOSED: an absent (no per-call override AND no
            -- constructor default) or non-positive/NaN (0/negative/NaN)
            -- threshold is always a caller bug (nil arithmetic, a
            -- misconfigured Config value, a future call site forgetting its
            -- override) — `elapsed < 0` is never true, so treating it as a
            -- normal threshold would silently and permanently disable this
            -- cooldown for every already-touched key instead of erroring
            -- loudly. Never let a bad threshold turn into unlimited spam.
            --
            -- NOT SILENT ANYMORE (this pass): a non-nil `thresholdMs`
            -- override reaching this branch could not be caught by
            -- AssertValidDefaultThreshold above (that only validates the
            -- CONSTRUCTOR's default) — this is the per-call-Config-read
            -- shape (e.g. a file calling `.IsOnCooldown(key,
            -- Config.X.cooldownMs)` fresh every invocation). Printed once
            -- per tracker instance, not once per call, so a live server
            -- under normal call volume against an already-broken config
            -- gets exactly one unmissable line instead of a flood.
            if not warnedBadCallTimeThreshold then
                warnedBadCallTimeThreshold = true
                print(
                    ('[qbx_k9unit] cooldowns.lua: IsOnCooldown/Consume called with a missing or ' ..
                     'non-positive/invalid threshold (key=%s, thresholdMs=%s, constructor default=%s). ' ..
                     'This key is now PERMANENTLY on cooldown (fail-closed) until this resource ' ..
                     'restarts with a fixed config -- 0/negative/nil never means "no cooldown" in ' ..
                     'this API. Find the Config field this threshold was read from and set it to a ' ..
                     'positive number.')
                        :format(tostring(key), tostring(thresholdMs), tostring(defaultThresholdMs))
                )
            end
            return true
        end
        -- CAVEAT, not fixed here (documentation only — see this pass's own
        -- report to coder-architect before this math is ever changed):
        -- GetGameTimer() is FXServer's process-uptime millisecond counter,
        -- reported to have gone negative on some long-uptime servers
        -- (consistent with the underlying native being a 32-bit signed
        -- counter that wraps after ~24.85 days of continuous uptime,
        -- well within a real server's lifetime between restarts). This
        -- naive `now - lastAt` subtraction is NOT wraparound-safe: a `key`
        -- touched shortly before a wrap would read as still on cooldown
        -- (elapsed appears deeply negative, and negative < any positive
        -- threshold is true) until enough real wall-clock time passes for
        -- `now` to numerically catch back up — up to ~24.85 days, not just
        -- until the configured threshold elapses. Every call site in this
        -- resource already tolerates "cooldown briefly stuck on" as a
        -- fail-safe direction (never "cooldown silently disabled"), so this
        -- is flagged as a known caveat for a resource restarted well under
        -- monthly, not silently patched — a wraparound-safe rewrite of this
        -- subtraction changes observable timing behavior across every one
        -- of this file's 16 call-time consumers and needs a reported,
        -- coordinated pass, not a quiet fix buried in an audit.
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
--- @param defaultThresholdMs number? -- validated by AssertValidDefaultThreshold when non-nil, same as NewCooldown.
--- @return table tracker
function NewNestedCooldown(defaultThresholdMs)
    AssertValidDefaultThreshold(defaultThresholdMs, 'NewNestedCooldown')

    local store = {}
    local tracker = {}
    local warnedBadCallTimeThreshold = false

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
        if not IsValidThreshold(threshold) then
            -- FAIL CLOSED — see NewCooldown's IsOnCooldown for the full
            -- reasoning: a bad/missing threshold must never silently
            -- disable this cooldown. NOT SILENT ANYMORE (this pass) — same
            -- one-time-per-tracker loud warning as NewCooldown's
            -- IsOnCooldown above, for the same reason (a per-call
            -- threshold read fresh from Config can't be caught by
            -- AssertValidDefaultThreshold at construction time).
            if not warnedBadCallTimeThreshold then
                warnedBadCallTimeThreshold = true
                print(
                    ('[qbx_k9unit] cooldowns.lua: NewNestedCooldown IsOnCooldown/Consume called with a ' ..
                     'missing or non-positive/invalid threshold (primaryKey=%s, secondaryKey=%s, ' ..
                     'thresholdMs=%s, constructor default=%s). This (primaryKey, secondaryKey) pair is ' ..
                     'now PERMANENTLY on cooldown (fail-closed) until this resource restarts with a ' ..
                     'fixed config -- 0/negative/nil never means "no cooldown" in this API.')
                        :format(tostring(primaryKey), tostring(secondaryKey), tostring(thresholdMs), tostring(defaultThresholdMs))
                )
            end
            return true
        end
        -- Same GetGameTimer() wraparound caveat as NewCooldown's
        -- IsOnCooldown above (see its doc comment for the full writeup) —
        -- this subtraction is not wraparound-safe either.
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
---
--- DEADLOCK VERDICT (audited): TryAcquire/Release themselves cannot
--- deadlock — both are single synchronous table operations with no
--- internal Wait/await, and FXServer's Lua execution is cooperative
--- (never preempted between two non-yielding statements), so there is no
--- window where two callers can interleave inside TryAcquire itself. This
--- mutex also has NO built-in timeout/expiry — a `key` that is TryAcquire'd
--- and never Release'd stays held FOREVER (silently disabling whatever it
--- guards for that key, with no error), by design, matching every other
--- primitive in this file: a mutex "expiring" would defeat the point of a
--- mutex. That makes "is a mutex ever left held with no way to release it"
--- entirely a caller-discipline question, not something this constructor
--- can enforce — audited across all 5 current call sites (server/search.lua
--- SearchMutex, server/combat.lua TakedownMutex, server/inventory.lua
--- K9InventoryOpenMutex, server/medkit.lua MedkitMutex,
--- server/partnership.lua PartnershipEstablishMutex): every one wraps its
--- entire critical section (including any yielding `await` calls inside
--- it) in `pcall(...)` and unconditionally calls `:Release(key)` on the
--- very next line after the pcall returns, regardless of success/failure —
--- so a thrown error mid-critical-section is already covered by every
--- existing caller. `:RegisterPlayerDropped()` is a second, independent
--- backstop for the subset of these keyed by player source (SearchMutex,
--- TakedownMutex, K9InventoryOpenMutex — all `RegisterPlayerDropped()`ed at
--- their own declaration) so a source that disconnects mid-critical-section
--- (rather than erroring) still gets its held key cleared; the two callers
--- keyed by something else (MedkitMutex by targetCitizenid,
--- PartnershipEstablishMutex by a fixed constant key) do NOT call
--- RegisterPlayerDropped, correctly, since neither key is a player source —
--- their sole release path is the pcall-guaranteed one, which does not
--- depend on any player staying connected.
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
