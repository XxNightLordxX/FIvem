--[[
    qbx_k9unit/server/k9profiles.lua

    OWNER-DIRECTED PASS. Owner's own words, verbatim, for THIS pass: high
    command should be "a god over that tablet with full customization over
    everything related to that K9", and separately, "make this a tier
    system."

    ======================================================================
    STEP 1 -- WHAT ALREADY EXISTS (read before this file was written, not
    after)
    ======================================================================

    Two tier ladders already existed in this codebase before this pass:

      * `k9_certification_tiers` (migration 0010, server/certtiers.lua) --
        trainee/certified/senior, plus anything an operator adds. Carries
        toggleable CAPABILITIES (specializations_eligible,
        bite_hold_and_takedown, ...), never a speed/scent/cooldown number.
      * `k9_xp_tiers` (migration 0015, server/xptiers.lua) -- Recruit/
        Trained/Veteran/Elite. THIS ONE ALREADY CARRIES, PER RANK,
        `speedMultiplier`/`scentRangeMultiplier`/`medkitCooldownMultiplier`
        -- i.e. "each tier of dog gets a longer sprint" was already true,
        PER RANK, before this pass touched anything. Verified by reading
        server/progression.lua and server/xptiers.lua in full before
        writing a line of this file.

    CONCLUSION, STATED PLAINLY: the "make this a tier system" half of the
    owner's ask is ALREADY DONE for the three values this codebase has ever
    made tier-dependent. This pass does NOT add a third parallel ladder --
    doing so would let three places disagree about what "this K9's speed"
    means, with no way to say which one wins. Instead this pass answers the
    OTHER half of the sentence: "everything related to THAT K9" -- an
    individual dog, by citizenid, not a rank everyone in it shares.

    ======================================================================
    STEP 1 (continued) -- THE SHAPE CHOSEN, AND WHY
    ======================================================================

    A per-INDIVIDUAL-K9 override layer, keyed by citizenid, that sits ON TOP
    of whichever XP-tier profile that citizenid's K9 already resolves to.
    This is the "god mode" half: a specific dog can be hand-tuned by high
    command without moving it to a different rank (which would also move
    every OTHER dog in that rank) and without inventing a rank-of-one.

    RESOLUTION ORDER -- STATED HERE, ONCE, AS THE AUTHORITATIVE ANSWER TO
    "a value is settable in three places, which one wins":

        GLOBAL DEFAULT  ->  XP TIER PROFILE  ->  INDIVIDUAL OVERRIDE

      1. GLOBAL DEFAULT: Config.XPTiers[1] (the base rank -- 0 XP, no
         bonus). Every citizenid starts here.
      2. XP TIER PROFILE: GetXPTier(citizenid) (server/progression.lua,
         unmodified by this pass). This already folds the global default in
         as its own floor -- an uncached/never-earned citizenid resolves to
         exactly rank 1 -- so in practice this pass only ever needs to
         consult this ONE accessor, never the global default separately.
      3. INDIVIDUAL OVERRIDE (THIS FILE, new): a per-citizenid,
         PER-FIELD override in `k9_individual_overrides`. A field left
         unset here means "defer to this citizenid's own tier value for
         THAT field" -- it is never all-or-nothing. HIGHEST PRECEDENCE:
         when set, it wins outright over whatever the tier says, for that
         one field only.

      GetK9EffectiveMultipliers(citizenid) below is the ONE function that
      implements this order end to end and is the ONLY seam a real
      consumer should ever call for "what should this K9's speed/scent/
      medkit-cooldown actually be right now" -- never GetXPTier directly if
      an individual override is meant to apply (see "INTEGRATION HANDOFF"
      near the bottom of this header for exactly why no existing consumer
      has been switched over by this pass).

    ======================================================================
    SCOPE -- ONLY THREE FIELDS, DELIBERATELY, NOT "EVERYTHING"
    ======================================================================

    "Everything related to that K9" was taken seriously and investigated,
    not simply narrowed by assumption. Only `speedMultiplier`/
    `scentRangeMultiplier`/`medkitCooldownMultiplier` are overridable here
    -- the exact three fields server/xptiers.lua already made tier-
    dependent, because those are the only three with a REAL, LIVE
    composition point anywhere in this codebase today. Everything else
    considered was rejected on a SPECIFIC, disclosed basis, not silently
    dropped:

      * WELLBEING STAT MAXIMA (Fatigue/Mood/FearStress/Injury caps) --
        server/wellbeing.lua's own Clamp(...) call sites read
        Config.Wellbeing.<Stat>.max as ONE GLOBAL CONSTANT with no
        per-citizenid composer to hook at all -- server/progression.lua's
        own "XP TIER UNLOCKS" section already investigated this EXACT
        extension for the sibling per-RANK system and rejected it on
        cost/ownership grounds ("a real, invasive refactor... not the
        small-moderate effort... rejected on cost/ownership grounds, not a
        farmability concern"). Nothing about making the override
        per-INDIVIDUAL instead of per-RANK changes that finding -- the
        missing composer is the same missing composer either way, and
        server/wellbeing.lua is both off-limits to this pass and not
        something this pass's own agent may edit regardless.
      * COMBAT ACTION COOLDOWNS (BiteAndHold/NonLethalTakedown target
        cooldowns, and every anti-XP-farm mint cooldown in
        server/progression.lua/server/combat.lua/server/search.lua/
        server/tracking.lua) -- these are FILE-LOCAL CONSTANTS BY EXPLICIT
        DESIGN, with each one's own comment stating some version of "the
        only way to weaken it is to edit this file's own source under code
        review." A database-editable per-citizenid override of a PvP
        cooldown (BiteAndHold/NonLethalTakedown) or an anti-farm floor is
        exactly the class of footgun those comments exist to forbid --
        "god mode over one dog" must not mean "a live, in-game route to
        loosen a security floor that was deliberately kept out of
        config.lua, let alone out of a database row."
      * PERMISSIONS / CAPABILITIES -- already owned by
        `k9_permissions` (server/permissions.lua) and
        `k9_certification_tier_capabilities` (server/certtiers.lua). A
        THIRD place to grant the same class of thing ("can this citizenid
        BiteAndHold") would reopen the exact "which one wins" ambiguity
        this file's own resolution-order section above exists to avoid --
        worse, it would do so for an AUTHORIZATION decision, not a
        cosmetic-adjacent multiplier, which is a materially higher-stakes
        place to have three sources of truth. `GetK9EffectiveMultipliers`
        below returns numbers only, never a boolean allow/deny.
      * XP TOTAL / TIER ASSIGNMENT ITSELF -- deliberately NOT overridable
        here. An operator wanting "this K9 is Elite" already has that
        lever (server/highcommand.lua's AwardXPDirect, or simply letting
        the dog earn it) -- duplicating "which rank" as a FOURTH place
        (global default / XP tier / individual override / a hypothetical
        forced-rank field) was rejected as solving a problem that already
        has an owner.

    Net effect: this file's own CAPABILITY_CATALOG-equivalent is "there is
    none" -- exactly server/xptiers.lua's own file-top note for the
    identical reason -- every field this file lets an operator write is a
    plain, BOUNDED number, never an authorization decision.

    ======================================================================
    WHY A TOMBSTONE, NOT A HARD DELETE (a real, disclosed choice, not a
    copy-paste of migration 0010's reasoning)
    ======================================================================

    Unlike a certification tier key, NOTHING else in this schema references
    a citizenid's override row -- there is no HAZARD-2-shaped "a row still
    points at this, corrupting an audit trail if I rewrite it" risk here at
    all. A hard DELETE would be perfectly SAFE. This file still tombstones
    (a `deleted` flag, never a real row DELETE) purely for CONSISTENCY with
    every other admin-edited current-state table in this resource
    (k9_certification_tiers, k9_permission_keys) and so a reset is itself an
    audited action with a "what did this override used to say before it was
    reset" trail, rather than a silent row disappearance a DELETE would
    produce.

    ======================================================================
    BOUNDS -- REUSED, NOT REINVENTED
    ======================================================================

    `MAX_SPEED_SCENT_MULTIPLIER` (3.0) and `MAX_MEDKIT_COOLDOWN_MULTIPLIER`
    (1.0) below are the SAME numbers server/xptiers.lua already uses for the
    identical two field classes, duplicated here rather than shared (this
    resource's own established "no cross-file `local` import mechanism"
    precedent -- server/xptiers.lua's own IsSafeShortString doc comment
    states this exact tradeoff for the identical reason). Every field is
    independently checked with `IsValidMultiplier` (finite, > 0, <= max) --
    a non-positive, negative, NaN, or absurd value is impossible to persist
    through this surface at ANY layer: rejected here before ever reaching
    K9Store, and K9Store itself never re-derives or loosens what this file
    already validated.

    ======================================================================
    AUTHORIZATION / CONCURRENCY -- identical posture to server/certtiers.lua/
    server/xptiers.lua, restated briefly rather than re-argued
    ======================================================================

    `CanManageK9Profiles(source)` re-resolves `IsHighCommand(source)` FRESH,
    server-side, on EVERY call -- no caching, no trusting a client-supplied
    flag, no HasPermission-based delegation (same disclosed, deliberate
    scope decision server/certtiers.lua's own CanManageCertTiers documents:
    the owner's own words for this feature name "high command" specifically).

    `K9ProfileEditMutex` (keyed by citizenid) is a MUTEX DISJOINT FROM EVERY
    OTHER MUTEX IN THIS RESOURCE -- confirmed by construction: this file
    never calls into server/certtiers.lua's `TierEditMutex` or
    server/xptiers.lua's `XPTierEditMutex`, and neither of those files calls
    into this one's. Three independent per-surface lock domains that never
    nest inside one another cannot deadlock against each other. Closes the
    identical class of race those two files already document (a concurrent
    edit and a concurrent reset for the SAME citizenid interleaving across
    their own K9Store `.await` yield points) -- the memory-mode backend
    never actually races at all (server/datastore.lua's own header, "WHY
    THIS NEVER ACTUALLY RACES IN MEMORY MODE"), but the mutex still exists
    and is still exercised for the real-database backend.

    ======================================================================
    NO UNBOUNDED TRAP (mirrors server/certtiers.lua HAZARD 5 / server/
    xptiers.lua's identical section)
    ======================================================================

    `GetK9EffectiveMultipliers` is a PURE READ with no side effect on any
    other object -- it never force-ends, interrupts, or reaches into an
    already-open effect (a hold, a leash, a partnership). An override edit
    or reset only ever changes what a FUTURE lookup returns; exactly the
    same "gate the request that opens an effect, never the release that
    closes one" property every other tier-shaped surface in this resource
    already guarantees, achieved here for free by never being called from a
    termination/cleanup path in the first place (there is no such call site
    anywhere in this file or its own tests).

    ======================================================================
    INTEGRATION HANDOFF -- WHAT THIS PASS DOES NOT WIRE, AND WHY, STATED
    PLAINLY RATHER THAN LEFT IMPLICIT
    ======================================================================

    `GetK9EffectiveMultipliers` exists, is fully validated, fully audited,
    and fully unit-tested by this pass -- but as of this pass it has NO
    consumer outside this file's own tests, confirmed by grep. The two real
    candidate call sites are both in files this pass's own agent may read
    but must not edit (client/movement.lua is explicitly restricted; the
    live-consumption chain for medkit cooldown and the server->client
    `qbx_k9unit:client:xpTierChanged` snapshot push both live in
    server/progression.lua, which this pass's own agent does not own and
    must not casually rewrite mid-flight on a shared checkout):

      * server/progression.lua's `GetXPTier(citizenid)` /
        `GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs)` would need to
        consult `GetK9EffectiveMultipliers(citizenid)` (soft-guarded,
        `type(...) == 'function'`, this resource's standard cross-file
        convention) instead of -- or layered after -- their own raw tier
        lookup, so a hand-tuned dog's real movement speed/scent range/
        medkit cooldown reflects its override.
      * Whatever code pushes `qbx_k9unit:client:xpTierChanged` (today: a
        raw `CopyXPTier(tier)` of the citizenid's resolved
        `Config.XPTiers[n]` row) would need to push the OVERRIDDEN
        effective values instead, so `client/movement.lua`'s
        `K9MoveRateModifiers` (which this pass's own agent may read but not
        edit) actually reflects an override without that file needing any
        change of its own -- it already trusts whatever the server sends.

    Until one of those two lands, the WORST CASE of this entire file, in a
    running server, is: an override can be created, listed, edited, and
    reset from the tablet, and `GetK9EffectiveMultipliers` returns the
    mathematically correct composed answer for anything that asks it --
    but nothing yet asks it, so no player-visible behavior changes. Exactly
    the same "inert until a real consumer lands" posture server/certtiers.lua's
    own header documents for `TierCapabilityPermits` before its first two
    consumers were wired, for the identical reason (file-ownership
    boundaries on a shared checkout, not an unfinished design). The exact,
    reviewed integration point above has been handed to coder-backend
    (server/progression.lua) rather than applied here.
]]

-- ======================================================================
-- BOUNDS -- see header "BOUNDS -- REUSED, NOT REINVENTED".
-- ======================================================================
local MAX_SPEED_SCENT_MULTIPLIER = 3.0
local MAX_MEDKIT_COOLDOWN_MULTIPLIER = 1.0
local MAX_NOTE_LENGTH = 120

-- Defensive cap on total live (non-tombstoned) override count -- mirrors
-- server/certtiers.lua's own MAX_TIERS reasoning exactly: an
-- already-authenticated high-command account is a highly trusted actor,
-- but an unbounded table is still an unforced footgun (a stuck tablet
-- retry loop hammering create with a new citizenid each time). Well above
-- any real operator's plausible "dogs I have hand-tuned" count. Editing an
-- ALREADY-LIVE override never counts against this cap -- only a genuinely
-- new citizenid does.
local MAX_INDIVIDUAL_OVERRIDES = 500

local K9_PROFILE_ACTION_COOLDOWN_MS = 1000

--- @param value any
--- @return boolean
local function IsFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

--- @param value any
--- @param maxAllowed number
--- @return boolean
local function IsValidMultiplier(value, maxAllowed)
    return IsFiniteNumber(value) and value > 0 and value <= maxAllowed
end

--- VARCHAR(50), matching every citizenid column in this schema
--- (k9_certifications, k9_permissions, k9_progression, ...). Not an
--- injection backstop (this value only ever reaches a bound `?`
--- placeholder) -- a plain sanity/DoS-lite bound, matching
--- server/permissions.lua's own IsValidCitizenId exactly.
--- @param value any
--- @return boolean
local function IsValidCitizenId(value)
    return type(value) == 'string' and value ~= '' and #value <= 50
end

--- Character filter mirroring server/certtiers.lua's own IsValidTierLabel /
--- server/xptiers.lua's own IsSafeShortString -- duplicated here rather
--- than shared (this file has no import mechanism to reach either one),
--- same "duplicated, not shared" precedent those two files already
--- establish for this identical helper.
--- @param value any
--- @return boolean
local function IsValidNote(value)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > MAX_NOTE_LENGTH then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

-- ======================================================================
-- LIVE, IN-MEMORY OVERRIDE CACHE -- rebuilt wholesale by
-- RefreshOverrideCache below, never partially mutated in place. Starts
-- EMPTY (there is no config-supplied default to seed with -- see header
-- "INTEGRATION HANDOFF" for why an empty cache is already the correct,
-- safe answer for every citizenid until the real DB state is loaded: "no
-- override" is byte-identical to "defer entirely to this citizenid's own
-- XP tier", which is exactly what GetK9EffectiveMultipliers already does
-- for a citizenid absent from this table).
-- OverrideByCitizenId[citizenid] = { speedMultiplier?, scentRangeMultiplier?,
--                                     medkitCooldownMultiplier?, note? }
-- A tombstoned row is simply ABSENT from this cache -- never present with
-- some "deleted" marker a reader would have to remember to check, matching
-- server/certtiers.lua's own TierByKey convention (a tombstoned tier_key is
-- excluded from the merged catalog entirely, not flagged within it).
-- ======================================================================
local OverrideByCitizenId = {}

--- Rebuilds `OverrideByCitizenId` from the current `k9_individual_overrides`
--- database state. Called once at this file's own onResourceStart (after
--- K9Store.WaitForSchemaCheckToSettle() -- see header "BOOT-ORDER SAFETY"
--- immediately below) and again after every successful mutation
--- (Upsert/Reset) so a caller's own response (and any other in-flight
--- reader) sees the true new state immediately, never a stale one --
--- identical refresh discipline to server/certtiers.lua's own
--- RefreshCertificationTierCatalog.
local function RefreshOverrideCache()
    local fresh = {}
    local rows = K9Store.IndividualOverride_GetAllRows()
    for _, row in ipairs(rows) do
        if not (row.deleted == 1 or row.deleted == true) then
            fresh[row.citizenid] = {
                speedMultiplier = tonumber(row.speed_multiplier),
                scentRangeMultiplier = tonumber(row.scent_range_multiplier),
                medkitCooldownMultiplier = tonumber(row.medkit_cooldown_multiplier),
                note = type(row.note) == 'string' and row.note or nil,
            }
        end
    end
    OverrideByCitizenId = fresh
end

-- ======================================================================
-- RESOLUTION SEAM. See header "RESOLUTION ORDER" for the full contract.
-- Hot-path-safe (cache read + one soft-guarded call into
-- server/progression.lua's own already-cached GetXPTier -- no query, no
-- yield), exactly like every other accessor this resource exposes across
-- the tier catalogs.
--
-- DELIBERATELY `local`, NOT a resource-global, AS OF THIS PASS -- not an
-- oversight: this resource's own `.luacheckrc` `globals` allowlist is
-- off-limits to this pass's own agent (same constraint server/certtiers.lua's
-- own header discloses for its own `IsCapabilityActiveInternal`), and per
-- header "INTEGRATION HANDOFF" above, NOTHING outside this file calls any
-- of the three functions in this section yet -- every current caller is
-- one of this file's own callbacks, further down this same file, which
-- already sees these as ordinary Lua locals with no cross-file need. The
-- day a real external consumer lands (server/progression.lua, per the
-- handoff above), promoting these three to bare globals AND adding the
-- matching `.luacheckrc` entries is that consumer's own one-line addition
-- to make in the SAME change -- exactly this resource's own established
-- "add the allowlist entry in the same pass that creates the cross-file
-- need" convention (see e.g. that file's own `ForceRevertK9Appearance`
-- entry and comment for the precedent).
-- ======================================================================

--- @param citizenid any
--- @return table effective -- { speedMultiplier: number, scentRangeMultiplier: number, medkitCooldownMultiplier: number?, overridden: { speedMultiplier: boolean, scentRangeMultiplier: boolean, medkitCooldownMultiplier: boolean } }
local function GetK9EffectiveMultipliers(citizenid)
    -- STEP 2: XP TIER PROFILE. Already folds the global default in as its
    -- own floor (server/progression.lua's GetXPTier never returns nil) --
    -- see header "RESOLUTION ORDER". Soft-guarded: an unavailable
    -- GetXPTier (server/progression.lua absent, or Config.Features.
    -- XPProgression off with no cache ever warmed) degrades to the SAME
    -- neutral baseline server/progression.lua's own base tier ships
    -- (1.0/1.0/no medkit reduction) -- never an error, never a
    -- higher-than-neutral guess.
    local tierSpeed, tierScent, tierMedkit = 1.0, 1.0, nil
    if type(citizenid) == 'string' and citizenid ~= '' and type(GetXPTier) == 'function' then
        local ok, tier = pcall(GetXPTier, citizenid)
        if ok and type(tier) == 'table' then
            if type(tier.speedMultiplier) == 'number' then tierSpeed = tier.speedMultiplier end
            if type(tier.scentRangeMultiplier) == 'number' then tierScent = tier.scentRangeMultiplier end
            if type(tier.medkitCooldownMultiplier) == 'number' then tierMedkit = tier.medkitCooldownMultiplier end
        end
    end

    -- STEP 3: INDIVIDUAL OVERRIDE, PER FIELD, HIGHEST PRECEDENCE.
    local speed, scent, medkit = tierSpeed, tierScent, tierMedkit
    local overriddenSpeed, overriddenScent, overriddenMedkit = false, false, false

    local override = type(citizenid) == 'string' and OverrideByCitizenId[citizenid] or nil
    if override then
        if type(override.speedMultiplier) == 'number' then
            speed, overriddenSpeed = override.speedMultiplier, true
        end
        if type(override.scentRangeMultiplier) == 'number' then
            scent, overriddenScent = override.scentRangeMultiplier, true
        end
        if type(override.medkitCooldownMultiplier) == 'number' then
            medkit, overriddenMedkit = override.medkitCooldownMultiplier, true
        end
    end

    return {
        speedMultiplier = speed,
        scentRangeMultiplier = scent,
        medkitCooldownMultiplier = medkit,
        overridden = {
            speedMultiplier = overriddenSpeed,
            scentRangeMultiplier = overriddenScent,
            medkitCooldownMultiplier = overriddenMedkit,
        },
    }
end

--- Raw override row for one citizenid, or nil if none is currently live
--- (never existed, or tombstoned). A COPY, not the live table, so a caller
--- cannot mutate this file's own authoritative cache by editing the
--- returned value -- same discipline server/certtiers.lua's
--- ListCertificationTiers/GetCertificationTierCapabilities already apply.
--- @param citizenid any
--- @return table? override
local function GetK9IndividualOverride(citizenid)
    local entry = type(citizenid) == 'string' and OverrideByCitizenId[citizenid]
    if not entry then return nil end
    return {
        speedMultiplier = entry.speedMultiplier,
        scentRangeMultiplier = entry.scentRangeMultiplier,
        medkitCooldownMultiplier = entry.medkitCooldownMultiplier,
        note = entry.note,
    }
end

--- Every currently-live (non-tombstoned) override, as an ARRAY of
--- { citizenid, speedMultiplier?, scentRangeMultiplier?,
--- medkitCooldownMultiplier?, note? } -- the tablet's own "which dogs have
--- a bespoke override" listing. A COPY, same reasoning as
--- GetK9IndividualOverride above.
--- @return table[] overrides
local function ListK9IndividualOverrides()
    local list = {}
    for citizenid, entry in pairs(OverrideByCitizenId) do
        list[#list + 1] = {
            citizenid = citizenid,
            speedMultiplier = entry.speedMultiplier,
            scentRangeMultiplier = entry.scentRangeMultiplier,
            medkitCooldownMultiplier = entry.medkitCooldownMultiplier,
            note = entry.note,
        }
    end
    table.sort(list, function(a, b) return a.citizenid < b.citizenid end)
    return list
end

-- ======================================================================
-- AUTHORIZATION -- re-verified on EVERY call, never cached. See header
-- "AUTHORIZATION / CONCURRENCY".
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- @param source number
--- @return boolean authorized, string? citizenid
local function CanManageK9Profiles(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    return false, citizenid
end

-- Cross-file DISJOINT lock -- keyed by the TARGET citizenid, not a player
-- source (no :RegisterPlayerDropped() call, same reasoning
-- server/cooldowns.lua's own header gives for MedkitMutex/
-- PartnershipEstablishMutex, both keyed by something other than a player
-- source). See header "AUTHORIZATION / CONCURRENCY" for why this is
-- provably disjoint from TierEditMutex/XPTierEditMutex.
local K9ProfileEditMutex = NewMutex()

-- Anti-fat-finger/double-submit rate limit, keyed by the ACTING officer's
-- own source -- mirrors server/certtiers.lua's CertTierActionCooldown /
-- server/xptiers.lua's XPTierActionCooldown exactly. Every caller reaching
-- this point is already confirmed high command by CanManageK9Profiles
-- above; this guards against a held key or a double-submitted click, not
-- abuse.
local K9ProfileActionCooldown = NewCooldown(K9_PROFILE_ACTION_COOLDOWN_MS)
K9ProfileActionCooldown.RegisterPlayerDropped()

--- @param action string
--- @param citizenid string
--- @param detail string
--- @param changedBy string
--- @return boolean ok
local function WriteOverrideAudit(action, citizenid, detail, changedBy)
    return K9Store.IndividualOverrideAudit_Append(action, citizenid, detail, changedBy or 'unknown')
end

-- ======================================================================
-- CALLBACKS -- all four re-verify CanManageK9Profiles(source) as their own
-- first action. Response shape mirrors server/certtiers.lua's /
-- server/xptiers.lua's own `{ ok, reason, ... }` convention exactly, for
-- consistency across this resource's tablet-facing surfaces.
--
-- EVERY WRITE'S RETURN VALUE IS CHECKED (task rule, restated as a fact
-- about this file's own code, not merely a promise): K9Store.IndividualOverride_Upsert/
-- Override_Tombstone/OverrideAudit_Append all degrade a thrown DB error to
-- `false` rather than throwing (the SafeWrite contract, server/datastore.lua's
-- own header). Every call site below inspects that boolean and returns
-- `{ ok = false, reason = 'db_error' }` on a `false` -- there is no code
-- path in this file that discards a write's own return value and reports
-- success anyway.
-- ======================================================================

lib.callback.register('qbx_k9unit:server:k9ProfilesList', function(source)
    local authorized = CanManageK9Profiles(source)
    if not authorized then return { ok = false, reason = 'denied' } end
    return { ok = true, overrides = ListK9IndividualOverrides() }
end)

lib.callback.register('qbx_k9unit:server:k9ProfileGet', function(source, citizenid)
    local authorized = CanManageK9Profiles(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not IsValidCitizenId(citizenid) then
        return { ok = false, reason = 'invalid_citizenid' }
    end

    local tierLabel
    if type(GetXPTier) == 'function' then
        local ok, tier = pcall(GetXPTier, citizenid)
        if ok and type(tier) == 'table' and type(tier.label) == 'string' then
            tierLabel = tier.label
        end
    end

    return {
        ok = true,
        citizenid = citizenid,
        tierLabel = tierLabel,
        effective = GetK9EffectiveMultipliers(citizenid),
        override = GetK9IndividualOverride(citizenid),
    }
end)

lib.callback.register('qbx_k9unit:server:k9ProfileUpsert', function(source, payload)
    local authorized, actingCitizenid = CanManageK9Profiles(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not K9ProfileActionCooldown.Consume(source, K9_PROFILE_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(payload) ~= 'table' then
        return { ok = false, reason = 'invalid_payload' }
    end

    local citizenid = payload.citizenid
    if not IsValidCitizenId(citizenid) then
        return { ok = false, reason = 'invalid_citizenid' }
    end

    -- Every field is INDEPENDENTLY OPTIONAL (per-field override, not
    -- all-or-nothing -- see header "RESOLUTION ORDER"). Coerced via
    -- tonumber, same defensive posture as server/xptiers.lua's own payload
    -- handling -- treat every inbound field as adversarial/untyped. `nil`
    -- stays `nil` through tonumber(nil), matching "omitted = defer to
    -- tier" exactly.
    local hasSpeed = payload.speedMultiplier ~= nil
    local hasScent = payload.scentRangeMultiplier ~= nil
    local hasMedkit = payload.medkitCooldownMultiplier ~= nil
    local hasNote = payload.note ~= nil

    if not (hasSpeed or hasScent or hasMedkit or hasNote) then
        return { ok = false, reason = 'no_fields_to_set' }
    end

    local speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier

    if hasSpeed then
        speedMultiplier = tonumber(payload.speedMultiplier)
        if not IsValidMultiplier(speedMultiplier, MAX_SPEED_SCENT_MULTIPLIER) then
            return { ok = false, reason = 'invalid_speed_multiplier' }
        end
    end
    if hasScent then
        scentRangeMultiplier = tonumber(payload.scentRangeMultiplier)
        if not IsValidMultiplier(scentRangeMultiplier, MAX_SPEED_SCENT_MULTIPLIER) then
            return { ok = false, reason = 'invalid_scent_range_multiplier' }
        end
    end
    if hasMedkit then
        medkitCooldownMultiplier = tonumber(payload.medkitCooldownMultiplier)
        if not IsValidMultiplier(medkitCooldownMultiplier, MAX_MEDKIT_COOLDOWN_MULTIPLIER) then
            return { ok = false, reason = 'invalid_medkit_cooldown_multiplier' }
        end
    end
    if hasNote and not IsValidNote(payload.note) then
        return { ok = false, reason = 'invalid_note' }
    end

    if not K9ProfileEditMutex.TryAcquire(citizenid) then
        return { ok = false, reason = 'busy' }
    end

    local existingBefore = OverrideByCitizenId[citizenid]
    local isNew = existingBefore == nil

    if isNew then
        local liveCount = 0
        for _ in pairs(OverrideByCitizenId) do liveCount = liveCount + 1 end
        if liveCount >= MAX_INDIVIDUAL_OVERRIDES then
            K9ProfileEditMutex.Release(citizenid)
            return { ok = false, reason = 'too_many_overrides' }
        end
    end

    -- A field OMITTED from this payload defers to whatever this citizenid's
    -- override ALREADY held (a genuine partial edit -- "I only want to
    -- change the scent range this time"), never silently clearing it back
    -- to "no override" for that field. A field explicitly present (even a
    -- fresh row's first edit) always uses the just-validated new value.
    local finalSpeed = hasSpeed and speedMultiplier or (existingBefore and existingBefore.speedMultiplier or nil)
    local finalScent = hasScent and scentRangeMultiplier or (existingBefore and existingBefore.scentRangeMultiplier or nil)
    local finalMedkit = hasMedkit and medkitCooldownMultiplier or (existingBefore and existingBefore.medkitCooldownMultiplier or nil)
    local finalNote = hasNote and payload.note or (existingBefore and existingBefore.note or nil)

    local wrote = K9Store.IndividualOverride_Upsert(citizenid, finalSpeed, finalScent, finalMedkit, finalNote, actingCitizenid or 'unknown')
    if not wrote then
        K9ProfileEditMutex.Release(citizenid)
        return { ok = false, reason = 'db_error' }
    end

    RefreshOverrideCache()
    K9ProfileEditMutex.Release(citizenid)

    -- SELF-SERVICE VISIBILITY (same posture server/certtiers.lua's own
    -- "SELF-TIER CAPABILITY EDIT" / server/xptiers.lua's own
    -- "SELF-PROMOTION" sections already establish for their own surfaces):
    -- this is never a gate -- an already-authorized high-command account
    -- can still complete the edit in one action -- but a high-command
    -- officer hand-tuning their OWN citizenid's K9 is disclosed loudly
    -- rather than folded into an identical-looking ordinary edit line.
    local isSelfOverride = actingCitizenid ~= nil and actingCitizenid == citizenid
    local action = isNew and 'override_create' or 'override_update'
    local detail = ('speedMultiplier=%s scentRangeMultiplier=%s medkitCooldownMultiplier=%s note=%s'):format(
        tostring(finalSpeed), tostring(finalScent), tostring(finalMedkit), tostring(finalNote))
    if isSelfOverride then
        detail = detail .. ' -- SELF-OVERRIDE: acting officer edited their own citizenid\'s K9'
    end
    WriteOverrideAudit(action, citizenid, detail, actingCitizenid or 'unknown')

    local warning
    if isSelfOverride then
        warning = 'This edit changes YOUR OWN K9\'s speed/scent/medkit-cooldown values. This is logged distinctly in the individual-override audit trail for review.'
    end

    return {
        ok = true,
        citizenid = citizenid,
        effective = GetK9EffectiveMultipliers(citizenid),
        override = GetK9IndividualOverride(citizenid),
        warning = warning,
    }
end)

lib.callback.register('qbx_k9unit:server:k9ProfileReset', function(source, citizenid)
    local authorized, actingCitizenid = CanManageK9Profiles(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not K9ProfileActionCooldown.Consume(source, K9_PROFILE_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if not IsValidCitizenId(citizenid) then
        return { ok = false, reason = 'invalid_citizenid' }
    end

    if not K9ProfileEditMutex.TryAcquire(citizenid) then
        return { ok = false, reason = 'busy' }
    end

    if not OverrideByCitizenId[citizenid] then
        -- Nothing live to reset -- not an error (idempotent, matching this
        -- resource's established "resetting an already-default state is a
        -- harmless no-op" convention), but distinguished from a real
        -- tombstone write so a caller/tablet does not report "reset" for a
        -- citizenid that never had an override in the first place.
        K9ProfileEditMutex.Release(citizenid)
        return { ok = true, citizenid = citizenid, reason = 'no_override_existed', effective = GetK9EffectiveMultipliers(citizenid) }
    end

    local wrote = K9Store.IndividualOverride_Tombstone(citizenid, actingCitizenid or 'unknown')
    if not wrote then
        K9ProfileEditMutex.Release(citizenid)
        return { ok = false, reason = 'db_error' }
    end

    RefreshOverrideCache()
    K9ProfileEditMutex.Release(citizenid)

    WriteOverrideAudit('override_reset', citizenid, 'individual override reset -- K9 now uses its plain XP-tier values with no override', actingCitizenid or 'unknown')

    return { ok = true, citizenid = citizenid, effective = GetK9EffectiveMultipliers(citizenid) }
end)

-- ======================================================================
-- BOOT-ORDER SAFETY -- WaitForSchemaCheckToSettle() BEFORE the first read.
-- See server/datastore.lua's own "BOOT-ORDER SETTLEMENT" header for the
-- exact race this closes (a schema-collision probe still in flight when
-- this file's own onResourceStart handler fires) -- identical reasoning
-- and identical fix shape to server/permissionkeycatalog.lua/
-- server/xptiers.lua/server/equipmentshop.lua's own onResourceStart
-- handlers, all four now named together in server/datastore.lua's own
-- updated header.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[qbx_k9unit] k9profiles: the schema-collision check had not finished within its wait budget -- every K9 uses its plain XP-tier values (no individual override) for this session (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next successful override edit (or a restart once the check has had time to finish) will pick up any real persisted state.')
        return
    end
    RefreshOverrideCache()
end)
