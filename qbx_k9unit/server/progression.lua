--[[
    qbx_k9unit/server/progression.lua

    Phase 4 (coder-backend). Owns `Config.Features.XPProgression` end to
    end: server-authoritative XP accumulation, the `k9_progression`
    persistence table (sql/install.sql), the `K9XP[citizenid]` in-memory
    cache mirroring `server/certifications.lua`'s `Certifications` cache
    pattern exactly (per phase2_notes/RESEARCH_ARCHIVE.md#xp-schema §5's own
    recommendation), and the tier-lookup helper walking `Config.XPTiers` the
    same way `server/search.lua` walks `Config.ContrabandAlertTiers`.

    PERSISTENCE DECISION (not re-litigated here — see
    phase2_notes/RESEARCH_ARCHIVE.md#xp-schema, db-schema's design note, and
    PHASE4_SPEC.md §13.4.1/§13.5's own header claiming this note is
    "adopted"): a dedicated table, `k9_progression`, ONE ROW PER CITIZENID —
    NOT a qbx_core metadata field. XP is real, mechanical, capability-
    adjacent state (a tier crossing changes a K9's actual scent range and
    movement speed, per Config.XPTiers), the same category of decision this
    resource already made once for `k9_certifications` over metadata
    (SPEC.md §4.3), for the same three reasons: offline correction must
    work, atomic accumulation needs a single UPSERT (not a Lua-side
    read-modify-write race), and admin/ops queryability without scanning
    every player's JSON blob. See sql/install.sql's own `k9_progression`
    header comment for the schema itself.

    SCOPING: per Config.XP.scopePerCitizenidOrJob (currently only
    'citizenid' is implemented — see that config field's own comment and
    PHASE4_SPEC.md §13.6 item 2 for the still-open 'job' alternative, a
    product call this file does not attempt to resolve). `k9_progression`
    has a plain `citizenid` PRIMARY KEY, no job column — XP survives a
    department change, unlike `k9_certifications`.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4. Identical in format to
    server/certifications.lua's contract block.

    Callbacks: none. There is no "what's my current XP/tier" callback —
    every tier-relevant push is the server-initiated event below; a future
    UI wanting to *display* XP can read from that push, not poll for it.

    Server events (RegisterNetEvent, client->server): NONE for awarding XP.
    Every award is server-triggered internally, from inside the existing
    server-side success paths of server/search.lua and server/tracking.lua
    (this pass), and eventually server/combat.lua once Phase 3 lands (see
    Config.XP.awards' own comments in config.lua) — never from a
    client-fired "I earned XP" event. There is no legitimate reason for a
    client to ever claim this, and none is exposed.

    Client events (RegisterNetEvent, server->client):
    1. 'qbx_k9unit:client:xpTierChanged' (newTier: table — a full entry
       from Config.XPTiers: { xp, label, speedMultiplier, scentRangeMultiplier })
       [client/progression.lua] — sent to the K9's own client ONLY
       (never broadcast), on: (a) PlayerLoaded / resource-start backfill
       (an authoritative snapshot so a returning K9 doesn't need to earn
       fresh XP this session before their tier's effects apply again), and
       (b) any real tier crossing caused by AwardXP below. client/progression.lua
       does not need to distinguish (a) from (b) for correctness (it always
       applies newTier.speedMultiplier to K9MoveRateModifiers.xpTier either
       way) — it only distinguishes them for whether to show a "you leveled
       up" notification (never on the initial post-login snapshot).

    Commands: none.

    Automatic path: 'QBCore:Server:PlayerLoaded' (cache warm + initial
    snapshot push) and the resource-start backfill loop below (mirrors
    server/main.lua's own onResourceStart backfill for Certifications,
    same structural-gap rationale: a `/restart qbx_k9unit` while players are
    already online needs to re-warm K9XP for them too, since PlayerLoaded
    never re-fires for an already-connected player).
    ======================================================================

    FILE-TO-FILE CONTRACT — THIS FILE exposes three resource-global (no
    `local`) functions:
        AwardXP(citizenid, actionKey)
            actionKey is a string key into Config.XP.awards (e.g.
            'searchContrabandFound', 'trackSourceResolved',
            'biteHoldSuccess', 'takedownSuccess'). Re-checks
            Config.Features.XPProgression itself (defensive no-op if
            disabled, per SPEC.md §3 — callers are not required to gate
            this themselves, though every current call site already does
            for clarity). Updates the in-memory K9XP cache SYNCHRONOUSLY
            before firing a non-blocking DB UPSERT (phase4_xp_schema_notes.md
            §5 — correctness of the applied gameplay effect never depends on
            DB round-trip latency). Called from server/search.lua and
            server/tracking.lua this pass via a `type(AwardXP) == 'function'`
            runtime existence guard (the same guard server/medkit.lua's
            RestoreInjury call site already established for an equivalent
            soft cross-file dependency) — NOT a load-order assumption, so
            this file's position in fxmanifest.lua's server_scripts list is
            not load-bearing for those callers. server/combat.lua, once
            built, should call this the same way for 'biteHoldSuccess'/
            'takedownSuccess' — see config.lua's own comment on those two
            award keys.
        GetXPTier(citizenid) -> table
            Always returns a real Config.XPTiers entry (never nil) — an
            unknown/not-yet-cached citizenid resolves to the base tier
            (Config.XPTiers[1], 0 XP), the same "unknown state defaults to
            least privilege" posture this resource already applies
            elsewhere. Read by server/tracking.lua's findTrackableSource to
            apply the tier's `scentRangeMultiplier` server-side — callers are
            responsible for gating this read behind
            Config.Features.XPProgression themselves (this accessor does
            not gate internally, so it stays a plain, always-correct cache
            read regardless of caller).
        GetXP(citizenid) -> number
            Raw accumulated total (0 if uncached). Not currently consumed
            anywhere in this resource — exposed for a future HUD/display
            need (PHASE4_SPEC.md §13.4.1's own "additive read, not a new
            authorization surface" framing) rather than re-deriving a
            second cache elsewhere.

    XP TIER UNLOCKS ADDITION (this pass, FEATURE_IDEAS.md Part B §8) — one
    more resource-global, documented in full at its own declaration below
    (search this file for "GetXPTierMedkitCooldownMs") rather than repeated
    here: GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs) -> number. See
    the dedicated "XP TIER UNLOCKS" section further down this file for the
    full design (which three tiers unlock what, and why every rejected
    candidate was rejected — both on farmability grounds and on composition
    with server/permissions.lua's grant/block resolution order).
    THIS FILE calls `HasK9Access`... it does NOT — AwardXP is only ever
    invoked from a caller that has already independently re-verified
    HasK9Access for the acting player at its own call site (server/search.lua,
    server/tracking.lua); duplicating that check here would be redundant,
    not defense-in-depth, since AwardXP is not itself a network-facing
    surface (no RegisterNetEvent/lib.callback reaches it directly).
    THIS FILE owns `K9XP` (citizenid -> number) as file-local state,
    structurally identical to server/certifications.lua's `Certifications`
    cache (refreshed on PlayerLoaded/resource-start backfill, evicted on
    playerDropped to bound memory growth, per that file's own "regression-
    test fix" precedent).
    ======================================================================
]]

-- K9XP[citizenid] = number (accumulated total). Local: nothing outside this
-- file should read/write it directly — always go through AwardXP/GetXPTier/
-- GetXP. Mirrors server/certifications.lua's `Certifications` cache shape
-- and its own "nothing outside this file should read it directly" rule.
local K9XP = {}

-- CHOKEPOINT-LEVEL RATE FLOOR (audit finding, this pass). Every anti-farm
-- defence that exists today (server/search.lua's contraband-weight-change
-- dedup, server/tracking.lua's travel-distance/minimum-elapsed-time arrival
-- gate, server/combat.lua's MIN_BITE_HOLD_XP_DURATION_MS) was built
-- per-call-site, tailored to that action's own semantics — and each of
-- those is a BETTER fit for its own action than anything generic could be
-- (only server/tracking.lua's own pending-arrival state knows what "genuine
-- travel time" means for a track resolution; only server/search.lua's own
-- ContrabandXpState knows what "a materially different search result"
-- means). This tracker is NOT trying to replace or re-litigate any of
-- those — it exists for the failure mode none of them can cover: a FUTURE
-- call site (a new Config.XP.awards key, a new subsystem calling AwardXP
-- the same soft-dependency way server/search.lua and server/tracking.lua
-- already do) that simply forgets to add its own rate limiting at all,
-- e.g. a bug that lets a per-tick/per-frame handler re-fire the same
-- successful action every server tick instead of once. Without a floor
-- HERE, that class of bug has no ceiling whatsoever — AwardXP itself
-- imposes none, and a caller bug is exactly the situation where "the caller
-- is expected to have already handled it" fails.
--
-- Keyed by (citizenid, actionKey) via NewNestedCooldown, NOT a blanket
-- per-citizenid floor — server/tenure.lua's CheckTenureMilestonesForK9
-- legitimately calls AwardXP more than once for the SAME citizenid within
-- the SAME server tick (a K9 reunited after a long absence can cross
-- several milestone thresholds in one pass, per that file's own "pays every
-- newly-crossed milestone" comment), each with a DIFFERENT actionKey
-- (partnershipTenure1Day/7Day/30Day) — a per-citizenid-any-action floor
-- would silently drop the 2nd/3rd milestone's XP in exactly that legitimate
-- case, the same class of silent-loss bug this pass was asked to rule out
-- elsewhere. Per-(citizenid, actionKey) never collides with that: each
-- milestone key is touched at most once ever per partnership (non-repeating
-- by tenure.lua's own design), so this floor is never even reached there.
--
-- THRESHOLD (500ms) chosen against every real call site's own already-
-- established minimum real-world spacing between two GENUINE awards of the
-- SAME actionKey for the SAME citizenid, so a real player can never
-- perceive this floor: searchContrabandFound (Config.SearchZones.
-- searchCooldownMs = 10000ms per target — a different target still needs
-- physical travel time between two genuine finds), trackSourceResolved
-- (TRACK_ARRIVAL_REPORT_COOLDOWN_MS = 2000ms, plus its own minElapsedMs
-- travel gate), biteHoldSuccess (MIN_BITE_HOLD_XP_DURATION_MS = 3000ms),
-- takedownSuccess (Config.Combat.NonLethalTakedown.targetCooldownMs =
-- 30000ms per target), tenure milestones (one-time, never repeating). 500ms
-- sits comfortably below all of those, so it only ever bites a call pattern
-- no genuine player action can produce — a runaway/looping caller bug (or a
-- future actionKey added without its own gate) — while still turning
-- "unbounded per tick" into "at most 2/second," a bounded, investigable
-- ceiling instead of an open one.
--
-- Cleaned up in the playerDropped handler below (NewNestedCooldown's
-- :Clear(primaryKey) drops every actionKey entry for that citizenid in one
-- call, mirroring server/tracking.lua's own LastTrackQueryAt[src] = nil
-- shape) rather than via :RegisterPlayerDropped(), since that helper clears
-- by the raw `source` value and this tracker's primaryKey is citizenid, not
-- a player source.
local AwardXPCooldown = NewNestedCooldown(500)

-- ==========================================================================
-- EIGHTH XP-FARM FIX (this pass, coder-backend, red-team-flagged COMPOUND-
-- FARM follow-up to the SEVENTH fix -- every number below independently
-- re-verified against the real, currently-shipped source before acting, not
-- taken on the report alone; see this file's own report for the full
-- arithmetic). The four per-mechanic MINT cooldowns this codebase already
-- built (server/combat.lua's BiteHoldXpMintCooldown/TakedownXpMintCooldown,
-- server/search.lua's ContrabandXpMintCooldown, server/tracking.lua's
-- TrackTicketMintCooldown -- see each one's own declaration comment for its
-- own "SEVENTH XP-FARM FIX" writeup) are each a real, independently correct
-- per-ACTOR ceiling for ITS OWN mechanic -- but every one of them is keyed
-- by the SAME acting player's source/citizenid, and nothing before this pass
-- ever summed the four together. A single player round-robining all four --
-- bite-hold one NPC, takedown a different NPC, run their own
-- self-controlled contraband stash, resolve their own track -- is blocked
-- by NONE of them, because each cooldown only ever sees its own single
-- mechanic's calls.
--
-- RE-DERIVED FROM THE REAL SHIPPED CONSTANTS (not copied from the report):
--   biteHoldSuccess:       20 XP / BITE_HOLD_XP_MINT_COOLDOWN_MS  (60000ms) = 1,200 XP/hr
--   takedownSuccess:       30 XP / TAKEDOWN_XP_MINT_COOLDOWN_MS   (60000ms) = 1,800 XP/hr
--   searchContrabandFound: 25 XP / CONTRABAND_XP_MINT_COOLDOWN_MS (60000ms) = 1,500 XP/hr
--   trackSourceResolved:   10 XP / TRACK_TICKET_MINT_COOLDOWN_MS  (30000ms) = 1,200 XP/hr
--   SUM (uncapped, structurally independent today) .................. = 5,700 XP/hr
-- Config.XPTiers' own economy comment (config.lua) was retuned specifically
-- so the worst-case farmable ceiling takes "over 2 hours" to reach the
-- 9,000-XP Elite tier. At the uncapped 5,700 XP/hr sum above, Elite is
-- reachable in 9000/5700 = 1.579 hours (~1h 35m) -- BELOW that floor, and
-- reachable with close to zero real police work once server/combat.lua's
-- own NPC-mint gate (Config.XP.mintXpForNpcCombatTargets, see that file) is
-- also accounted for.
--
-- FIX: a SHARED, cross-mechanic budget, keyed by citizenid (matching
-- Config.XP.scopePerCitizenidOrJob -- asserted 'citizenid' by the
-- onResourceStart handler below -- the same identity every award in this
-- file is already scoped by), consulted by EVERY AwardXP call regardless of
-- actionKey. This is the single chokepoint every mechanic's award already
-- passes through (that is the whole point of AwardXP being resource-global
-- and the sole write path to K9XP), so putting the shared budget HERE, once,
-- is sufficient -- no call site in server/combat.lua, server/search.lua, or
-- server/tracking.lua needs to change for this budget itself to apply to it.
--
-- NOT A REPLACEMENT for the four per-mechanic mint cooldowns -- kept
-- unchanged, deliberately (do not weaken or remove either half alongside
-- this): they shape WHICH mechanic can mint and at what per-mechanic
-- cadence (e.g. takedownSuccess's own 1,800 XP/hr ceiling is still the
-- right number for takedown ALONE); this budget caps the TOTAL across all
-- of them combined. Removing either half reopens a real gap the other half
-- cannot cover on its own: without the per-mechanic cooldowns, a single
-- mechanic could burn the ENTIRE shared budget in seconds (the exact
-- runaway-caller shape AwardXPCooldown above already exists to catch --
-- this budget is not a substitute for that floor either); without this
-- shared budget, the four independent ceilings simply never interact, which
-- is exactly the gap this section exists to close.
--
-- IMPLEMENTATION: a per-citizenid TOKEN BUCKET, refilling continuously
-- toward XP_MINT_BUDGET_CAP_XP at a constant rate -- NOT a fixed-window
-- counter that resets to 0 on a wall-clock boundary. A fixed window has a
-- well-known boundary-doubling flaw for this exact use case: a player could
-- spend a full budget in the last instant of window N, then spend a full
-- budget again in the first instant of window N+1, minting up to 2x the
-- intended cap within a couple of real seconds around every window edge. A
-- token bucket has no such edge -- capacity refills continuously, never
-- resets to 0 on a clock boundary.
--
-- STARTING BALANCE -- THIS TOOK THREE ATTEMPTS TO GET RIGHT, in this same
-- pass, each verified by direct simulation rather than assumed correct on
-- reasoning alone (see this pass's own report for the full numbers):
--   1. REJECTED: start FULL (tokens = XP_MINT_BUDGET_CAP_XP). The textbook
--      token-bucket default, and it does let a brand-new citizenid's first
--      award through -- but it re-opens exactly the burst-doubling flaw the
--      fixed-window rejection above already exists to avoid, just shifted to
--      "every citizenid's first hour" (and every hour immediately following
--      a long-idle-triggered sweep eviction, see the sweep thread's own
--      comment below): a full starting balance PLUS a full hour's continuous
--      refill-and-spend on top of it. Simulated: up to 7,150 XP in a
--      citizenid's first simulated hour of continuous max-rate farming --
--      pushing worst-case time-to-Elite back down to ~1.5 hours, BELOW the
--      >2-hour floor this entire section exists to restore.
--   2. REJECTED: start EMPTY (tokens = 0). This makes the bound rigorous
--      instead of approximate for a bucket already in motion (cumulative XP
--      granted by any elapsed time T becomes provably <= CAP * T / WINDOW_MS)
--      -- but it has a fatal edge case at T=0 itself: a bucket created AND
--      checked inside the SAME AwardXP call has, by definition, zero elapsed
--      time since its own creation, so it can never have refilled anything
--      yet -- meaning EVERY citizenid's FIRST-EVER AwardXP call, every
--      session, was silently denied before K9XP was ever touched. Caught by
--      two independent agents hitting it live via tests/progression_spec.lua
--      (9 failures, every one consistent with "AwardXP never grants on a
--      fresh citizenid") before this shipped -- a full regression of the
--      happy path, not a theoretical edge case, and THE SAME FOOTGUN SHAPE
--      server/cooldowns.lua's own IsOnCooldown has for a non-positive
--      threshold: a boundary condition silently meaning "blocked forever"
--      instead of "unrestricted."
--   3. CHOSEN: start at XP_MINT_BUDGET_STARTER_TOKENS (see its own
--      declaration below) -- a small, ONE-TIME allowance, sized to the
--      worst-case realistic SAME-TICK burst this file's own award table can
--      produce for a single citizenid (the SUM of every Config.XP.awards
--      value, computed once from the real live config, never hardcoded), NOT
--      the full cap. This exists specifically because AwardXP can
--      legitimately fire more than once in the SAME tick for the SAME
--      citizenid with DIFFERENT actionKeys (server/tenure.lua's
--      CheckTenureMilestonesForK9 -- see AwardXPCooldown's own declaration
--      comment above: a K9 reunited after a long absence can cross several
--      one-time, non-repeating milestones in a single pass, and every one of
--      them must still be paid). A starting balance this small barely moves
--      the long-run bound at all (see NUMBERS CHOSEN below for the exact,
--      simulated impact) while completely fixing both rejected attempts'
--      failure modes: a brand-new citizenid's first award (or first-tick
--      burst) is never denied, and no citizenid can ever bank close to a
--      whole extra cap's worth of "free" tokens the way a full start would.
--
-- Re-verified by direct simulation with the REAL shipped award table (search
-- 25 + track 10 + bite 20 + takedown 30 + tenure 15+40+100 = 240 starter
-- tokens) AND the REAL bucket-created-at-first-use semantics (a bucket's
-- own `lastRefillAt` is set to the instant of its OWN first AwardXP call,
-- crediting ZERO prior elapsed time -- an earlier draft of this simulation
-- wrongly assumed a bucket already existed, accruing, from some earlier
-- "time 0" baseline, which overstated every number below; re-simulated and
-- cross-checked directly against tests/progression_spec.lua's own EIGHTH-
-- XP-farm-fix section, which exercises the REAL AwardXP function end to
-- end, not a re-implementation, before landing these final figures):
-- continuous max-rate round-robin farming across all four mechanics grants
-- 3,810 XP at T=1hr (vs. the four independent per-mechanic ceilings' own
-- UNCAPPED sum of 5,700 XP/hr -- this budget is still the binding
-- constraint), and the 9,000-XP Elite tier is first reached at
-- T=8,820,000ms = 2.45 hours (2h 27m) -- comfortably over the 2-hour floor,
-- though with a smaller margin (~27 minutes) than a pure start-empty
-- design's clean 2.5h would have had.
--
-- NUMBERS CHOSEN (XP_MINT_BUDGET_CAP_XP / XP_MINT_BUDGET_WINDOW_MS below):
-- 3,600 XP per 3,600,000ms (1 hour) -- clean, round numbers to reason about.
-- Needed: comfortably below 4,500 XP/hr (9000 / 4500 = exactly 2.0 hours --
-- the retuned floor requires MORE than 2 hours, so the cap must clear that
-- with real margin, not sit on the boundary), which it does even with the
-- 240-XP starter offset above (2.45h > 2.0h). Recomputed tier times at this
-- REAL post-fix ceiling (simulated AND test-verified, not a pure-continuous
-- approximation), reported to whoever owns config.lua for that file's own
-- Config.XPTiers economy comment (not edited by this pass):
--   Trained (1,250 XP): reached at 0.30h    (18m)
--   Veteran (4,000 XP): reached at ~1.058h  (~1h 3.5m)
--   Elite   (9,000 XP): reached at 2.45h    (2h 27m -- clears the floor)
--
-- FILE-LOCAL CONSTANTS, NOT CONFIG KEYS -- same reasoning as every one of
-- the four per-mechanic mint cooldowns' own "FILE-LOCAL CONSTANTS, NOT
-- CONFIG KEYS" comment (server/combat.lua, server/search.lua,
-- server/tracking.lua): this is a security floor, not an operator-tunable
-- balance knob, and a merely-too-low operator-set value would pass every
-- existing validity check while silently reopening the exact farm this
-- exists to close. The only way to weaken it is to edit this file's own
-- source under code review.
-- ==========================================================================
local XP_MINT_BUDGET_CAP_XP    = 3600     -- XP -- the bucket's max capacity (a citizenid can never hold more than this many unspent tokens at once, however long they go without earning)
local XP_MINT_BUDGET_WINDOW_MS = 3600000  -- 1 hour -- the refill PERIOD: a bucket held at 0 reaches full capacity after exactly this many real ms of continuous refill

-- STARTER TOKENS -- see the "STARTING BALANCE" writeup above for the full
-- reasoning (start-full and start-empty were both tried and rejected first,
-- this pass, before landing here). Sized as the SUM of every configured
-- Config.XP.awards value -- not the largest single one -- specifically to
-- cover server/tenure.lua's documented multi-milestone-in-one-tick case
-- (several one-time, non-repeating awards for the SAME citizenid in the SAME
-- AwardXP-call-adjacent moment), computed once here from the REAL live
-- config rather than hardcoded, so it can never silently drift out of sync
-- if config.lua's award list changes shape later. Clamped to
-- XP_MINT_BUDGET_CAP_XP so a starting balance can never itself violate this
-- bucket's own "never more than CAP tokens at once" invariant (relevant only
-- if a future award table's sum somehow exceeded the cap -- not true of any
-- currently shipped value, but this constant is derived, not asserted, so it
-- must clamp itself rather than rely on the assert below alone). Falls back
-- to a safe, small, non-zero default (100) if Config.XP.awards is not yet a
-- usable table at this file's OWN load time -- never 0, since 0 here would
-- silently reintroduce the exact "first award always denied" regression this
-- constant exists to fix, just for the narrower case of a malformed config.
local XP_MINT_BUDGET_STARTER_TOKENS = 100
if type(Config.XP) == 'table' and type(Config.XP.awards) == 'table' then
    local sum = 0
    for _, amount in pairs(Config.XP.awards) do
        if type(amount) == 'number' and amount > 0 then
            sum = sum + amount
        end
    end
    if sum > 0 then
        XP_MINT_BUDGET_STARTER_TOKENS = math.min(sum, XP_MINT_BUDGET_CAP_XP)
    end
end

--- Shared validity test, deliberately mirroring server/cooldowns.lua's own
--- IsValidThreshold (identical rejection list: non-number, NaN, non-
--- positive) -- NOT calling that function directly (this file has no
--- `local` access to it -- it is an internal helper of that file's own two
--- constructors, correctly not exposed as a resource-global), duplicated
--- here rather than newly invented.
--- @param value any
--- @return boolean
local function IsValidBudgetParam(value)
    return type(value) == 'number' and value == value and value > 0
end

--- TEST/INSPECTION SEAM (resource-global, no `local`) -- same precedent and
--- reasoning as server/search.lua's GetContrabandAlertTier: a thin pass-
--- through to a file-local pure function, added specifically so a spec can
--- exercise the exact validity logic this section's fail-OPEN decision is
--- built on with ARBITRARY inputs (0, negative, nil, NaN), not just the two
--- hardcoded constants above -- there is no other way to reach a `local`
--- function's behavior for inputs other than the ones this file's own
--- top-level code happens to call it with (see tests/fixtures/sandbox.lua's
--- own header on this exact limitation). Widens no trust boundary: this
--- performs a plain, side-effect-free math/type check on a number the
--- caller already has, reads no player/citizenid/XP state, and cannot be
--- used to influence or observe any real award.
--- @param value any
--- @return boolean
function IsValidXpMintBudgetParam(value)
    return IsValidBudgetParam(value)
end

-- CRITICAL DESIGN CHOICE, READ BEFORE EVER CHANGING EITHER CONSTANT ABOVE:
-- FAIL OPEN HERE, DELIBERATELY -- THE OPPOSITE DIRECTION FROM
-- server/cooldowns.lua's OWN IsOnCooldown, AND FROM EVERY PER-MECHANIC MINT
-- COOLDOWN ABOVE.
--
-- server/cooldowns.lua's own header documents the "Config.Recall footgun"
-- shape at length: a non-positive threshold there silently means
-- "permanently blocked," never "no cooldown," and that fail-CLOSED choice is
-- the RIGHT one for a single-mechanic cooldown, because the blast radius of
-- getting it wrong is contained -- one action, for players who happen to
-- touch that one mechanic, recoverable by a targeted fix. THIS budget is
-- different in kind, not just degree: it is consulted by EVERY AwardXP
-- call, for EVERY actionKey, for EVERY citizenid, resource-wide --
-- server/search.lua, server/tracking.lua, server/combat.lua,
-- server/tenure.lua's partnership milestones, and any future caller.
-- Reusing cooldowns.lua's fail-closed convention here would mean a single
-- bad constant (a future edit that typos XP_MINT_BUDGET_WINDOW_MS to 0, or
-- a future refactor that starts reading either constant from Config without
-- re-deriving the same validation this file's own onResourceStart guards
-- already apply to Config.XPTiers) could silently and PERMANENTLY block ALL
-- XP progression for the ENTIRE server, forever, until a restart -- a far
-- larger and far less visible outcome than this one security floor going
-- temporarily unenforced while the four independent per-mechanic mint
-- cooldowns above (unaffected by this flag either way) keep doing their own
-- job. Explicit, not accidental: when either constant fails validation,
-- this budget is DISABLED (never denies, never mutates XPMintBudget, never
-- touches the timer at all) and says so loudly exactly once, rather than
-- silently doing either extreme.
local XPMintBudgetEnabled = IsValidBudgetParam(XP_MINT_BUDGET_CAP_XP) and IsValidBudgetParam(XP_MINT_BUDGET_WINDOW_MS)
if not XPMintBudgetEnabled then
    print(
        ('[qbx_k9unit] progression: XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS are invalid ' ..
         '(capXp=%s, windowMs=%s) -- the SHARED cross-mechanic XP mint budget is DISABLED for this ' ..
         'entire session (fail OPEN, deliberately -- see this file\'s own comment on XPMintBudgetEnabled ' ..
         'for why this is the opposite of server/cooldowns.lua\'s usual fail-closed convention). The four ' ..
         'independent per-mechanic mint cooldowns (server/combat.lua, server/search.lua, ' ..
         'server/tracking.lua) are UNAFFECTED and keep enforcing their own limits regardless. Fix these ' ..
         'two constants in server/progression.lua.'):format(tostring(XP_MINT_BUDGET_CAP_XP), tostring(XP_MINT_BUDGET_WINDOW_MS))
    )
end

-- Deliberately NOT also exposing a read-only status/enabled accessor here as
-- a second test seam -- tests/progression_spec.lua's own EIGHTH-XP-farm-fix
-- compound-farm test already proves the REAL shipped constants are valid
-- and enabled, more precisely than a boolean flag could: it asserts the
-- EXACT total (3,600 XP after one simulated hour of round-robined real
-- awards, 9,000 XP after 2.5) that is only reachable at all if
-- XPMintBudgetEnabled is true AND both constants are exactly what they
-- claim to be. A second global purely for this would be redundant surface
-- for no extra coverage.

-- XPMintBudget[citizenid] = { tokens = number, lastRefillAt = gameTimerMs }.
-- DELIBERATELY NOT cleared on playerDropped (unlike K9XP/AwardXPCooldown
-- below -- see the playerDropped handler's own comment near the bottom of
-- this file for the full reasoning): clearing this on disconnect would let
-- a farmer reset their own budget early simply by reconnecting, defeating
-- the entire point of this section. Bounded instead by the periodic sweep
-- below, which only ever evicts an entry once it would already have
-- refilled to full capacity anyway -- behaviorally identical to leaving it
-- in place, just reclaiming memory for a citizenid that has been inactive
-- for a full window.
local XPMintBudget = {}

--- Refills `bucket` in place for the elapsed time since its own last
--- refill, capped at XP_MINT_BUDGET_CAP_XP (a token bucket's capacity is
--- also its max burst allowance -- see this section's header for why that
--- is fine here). `now` is a single GetGameTimer() value the caller already
--- captured, never re-read here, mirroring server/cooldowns.lua's own
--- IsOnCooldown `now` parameter convention.
---
--- GetGameTimer() WRAPAROUND CAVEAT (same disclosed, not-fixed-here issue as
--- server/cooldowns.lua's own IsOnCooldown -- see that file's header for the
--- full writeup): if `elapsed` reads negative (the ~24.85-day int32 wrap),
--- this function does nothing rather than let a negative elapsed *
--- refillRate corrupt `tokens` -- the safe direction here is "skip this
--- refill," not "guess," since briefly under-refilling is recoverable and
--- over-refilling is not (it would hand out budget that was never earned).
--- @param bucket table
--- @param now number
local function RefillMintBudget(bucket, now)
    local elapsed = now - bucket.lastRefillAt
    if elapsed <= 0 then return end
    local refillRate = XP_MINT_BUDGET_CAP_XP / XP_MINT_BUDGET_WINDOW_MS -- XP per ms
    bucket.tokens = math.min(XP_MINT_BUDGET_CAP_XP, bucket.tokens + elapsed * refillRate)
    bucket.lastRefillAt = now
end

-- Bounds XPMintBudget's memory growth WITHOUT resetting any citizenid's
-- remaining budget EARLY (see XPMintBudget's own declaration comment above
-- for why playerDropped cannot be used here the way K9XP/AwardXPCooldown
-- use it). An entry is only ever dropped once `now - lastRefillAt >=
-- XP_MINT_BUDGET_WINDOW_MS` -- the exact point at which RefillMintBudget
-- would have clamped it back to a FULL bucket had anyone looked. Dropping it
-- here and letting AwardXP recreate a fresh bucket at
-- XP_MINT_BUDGET_STARTER_TOKENS (see AwardXP's own comment on why a new/
-- recreated bucket starts there, not at 0 and not at capacity) on that
-- citizenid's next award is therefore CONSERVATIVE, not exactly identical to
-- leaving the old (by then full) entry in place -- a citizenid who returns
-- right after this sweep evicted them starts back at the small starter
-- allowance instead of resuming from a full bucket. That is always the SAFE
-- direction (strictly less budget available than an always-resident
-- implementation would have had, never more), and never actually reachable
-- by a genuinely legitimate player (see AwardXP's own comment: real play
-- never gets remotely close to a full bucket in the first place), so it
-- costs nothing in practice while keeping this sweep's own logic simple.
-- Sweep interval (5 minutes) is well under the window (1 hour) so no entry lingers
-- long past the point it became safe to drop; not built on
-- server/cooldowns.lua's own :StartSweep helper since this tracker's shape
-- (tokens + lastRefillAt, not a single timestamp) does not fit that
-- constructor's isStaleFn(now, loggedAt) signature. Only started when the
-- budget itself is enabled -- when disabled, XPMintBudget is never written
-- to at all, so a sweep thread would just be an empty no-op loop forever.
if XPMintBudgetEnabled then
    CreateThread(function()
        while true do
            Wait(300000)
            local now = GetGameTimer()
            for citizenid, bucket in pairs(XPMintBudget) do
                if (now - bucket.lastRefillAt) >= XP_MINT_BUDGET_WINDOW_MS then
                    XPMintBudget[citizenid] = nil
                end
            end
        end
    end)
end

-- STRUCTURAL GUARD (this pass): if the budget is enabled, verify at resource
-- start that its cap can never make a single genuine award un-payable. A cap
-- below some Config.XP.awards[key] value would mean even a FULLY refilled
-- bucket (tokens == cap) is smaller than that one award's own amount, so
-- `bucket.tokens < amount` inside AwardXP below would be true FOREVER for
-- that actionKey, for every citizenid, regardless of how long they wait --
-- a self-inflicted version of exactly the "permanently blocked" footgun this
-- section's own fail-OPEN choice above otherwise avoids for a BAD CONSTANT,
-- but which a bad constant RELATIONSHIP (cap too small relative to a real
-- award) would still reintroduce. Fails loudly at resource start, matching
-- this file's existing Config.XPTiers/scopePerCitizenidOrJob asserts below.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not XPMintBudgetEnabled then return end
    if type(Config.XP) ~= 'table' or type(Config.XP.awards) ~= 'table' then return end -- defensive only -- every other AwardXP call site in this file already assumes this table exists

    for actionKey, amount in pairs(Config.XP.awards) do
        assert(
            type(amount) ~= 'number' or amount <= XP_MINT_BUDGET_CAP_XP,
            ('[qbx_k9unit] progression: Config.XP.awards.%s (%s XP) exceeds XP_MINT_BUDGET_CAP_XP (%d XP) -- ' ..
             'a single award larger than the shared budget\'s own full capacity could never be paid, for any ' ..
             'citizenid, ever, regardless of how long they wait between awards. Raise XP_MINT_BUDGET_CAP_XP ' ..
             '(server/progression.lua) to at least this amount.')
                :format(tostring(actionKey), tostring(amount), XP_MINT_BUDGET_CAP_XP)
        )
        -- SECOND GUARD (coordinator-prompted re-check, this pass): a
        -- non-positive award amount breaks the shared budget's own math in
        -- a DIFFERENT way than "too large" above -- see AwardXP's own
        -- runtime `amount > 0` guard on this same block for the exact
        -- mechanism (a NEGATIVE amount would silently INCREASE the bucket
        -- instead of spending it, since `tokens < amount` never trips and
        -- `tokens - amount` then subtracts a negative number). ZERO is
        -- explicitly allowed here, deliberately NOT bundled into this
        -- guard: a 0-XP award is a harmless no-op either way (AwardXP's own
        -- `amount > 0` runtime check already skips the budget entirely for
        -- it, and `K9XP[citizenid] = oldXp + 0` changes nothing) -- some
        -- callers legitimately use a 0-value actionKey as a placeholder
        -- (this file's own test suite does), and this guard exists to catch
        -- the genuinely dangerous case, not to forbid a harmless one. No
        -- currently shipped Config.XP.awards value is negative, but nothing
        -- before this pass ever asserted that -- fails loudly here rather
        -- than relying solely on the runtime guard to silently no-op it.
        assert(
            type(amount) ~= 'number' or amount >= 0,
            ('[qbx_k9unit] progression: Config.XP.awards.%s (%s XP) must not be negative -- a negative award ' ..
             'amount would silently inflate the shared XP mint budget instead of spending it (see AwardXP\'s ' ..
             'own runtime `amount > 0` guard on the XPMintBudget block for the exact mechanism).')
                :format(tostring(actionKey), tostring(amount))
        )
    end
end)

-- CONFIG-SAFETY GUARD (config audit finding, this pass — same precedent as
-- server/inventory.lua's `Config.K9Inventory.accessScope` assert and
-- server/main.lua's `nudgeRequiresUnlocked` assert). This file's own header
-- SCOPING section, config.lua's own comment on this field, and README.md's
-- `Config.Features.XPProgression` section all already document that only
-- `'citizenid'` is implemented — but until now nothing ever READ the value
-- to enforce that, so a server owner who set `'job'` (a documented, but
-- explicitly NOT-YET-built, alternative — PHASE4_SPEC.md §13.6 item 2) got
-- silently citizenid-scoped behaviour with no warning at all: every award
-- and lookup in this file goes straight through K9XP[citizenid] and the
-- `k9_progression` table's plain `citizenid` key, never once branching on
-- this config field.
--
-- This is NOT a "feature merely unimplemented, pick the other value and
-- wait" situation the way an inert placeholder would be — `k9_progression`
-- (sql/install.sql) has a plain `VARCHAR(50) citizenid` PRIMARY KEY and NO
-- job column at all. 'job' scoping would need a composite (citizenid, job)
-- key instead (mirroring `k9_certifications`), which is a SCHEMA change,
-- not a config choice this file could honor today even if it tried to
-- switch on the value — the current schema cannot express per-job XP
-- totals at all. Failing loudly at resource start, rather than letting a
-- misconfigured value silently produce behaviour the operator did not
-- choose, matches the established precedent above.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    assert(
        Config.XP.scopePerCitizenidOrJob == 'citizenid',
        "[qbx_k9unit] Config.XP.scopePerCitizenidOrJob must be 'citizenid' -- " ..
        "'job' is a documented-but-unimplemented alternative (PHASE4_SPEC.md §13.6 item 2), " ..
        'not a selectable config choice this file can honor: the `k9_progression` table ' ..
        '(sql/install.sql) has a plain `citizenid` PRIMARY KEY and no job column at all, so ' ..
        "job-scoped XP totals cannot even be persisted under the current schema, let alone " ..
        'read/written correctly by this file, which unconditionally keys every K9XP cache ' ..
        'entry and every k9_progression query by citizenid alone. Setting this to anything ' ..
        "other than 'citizenid' would silently keep citizenid-scoped behaviour with no " ..
        'warning, misleading an operator who believes they configured job-scoped progression.'
    )

    -- TIER-SHAPE GUARD (audit finding, this pass). ResolveTier/GetXPTier's
    -- own doc comments both promise "always returns a real Config.XPTiers
    -- entry, never nil" — but nothing ever checked that promise against the
    -- config's actual shape; it has only ever been true because
    -- Config.XPTiers (config.lua, still marked "placeholder numbers pending
    -- economy-balance-agent review") happens to already be well-formed
    -- today. ResolveTier's own walk (`for _, tier in ipairs(...) do if xp >=
    -- tier.xp then resolvedTier = tier end end`, no `break`) has two
    -- load-bearing assumptions this guard verifies at resource start rather
    -- than silently trusting:
    --   1. Config.XPTiers is non-empty AND its first entry's `xp` is
    --      exactly 0. If either fails, `Config.XPTiers[1]` (ResolveTier's
    --      pre-loop default) is either nil (an EMPTY table) or a non-zero
    --      floor (some xp > 0 could then resolve to no tier if the loop
    --      body somehow still ran zero times, and more importantly a
    --      brand-new citizenid at 0 XP would incorrectly inherit whatever
    --      that first entry's speedMultiplier/scentRangeMultiplier is,
    --      rather than the neutral 1.0 baseline every other file in this
    --      resource assumes "unknown citizenid" means).
    --   2. Every `xp` threshold is a number, in STRICTLY ASCENDING order.
    --      ResolveTier never `break`s early — it keeps overwriting
    --      `resolvedTier` with EVERY entry whose `xp` the current total
    --      already clears, in ARRAY order, not threshold order. That is
    --      only equivalent to "the tier with the highest threshold not
    --      exceeding xp" (the intended, documented semantics) if the array
    --      is sorted ascending by `xp` — exactly the same caller-maintained-
    --      order contract Config.ContrabandAlertTiers and
    --      server/tenure.lua's own milestone walk already require and
    --      document for the identical reason. An out-of-order or
    --      non-numeric entry would not crash this loop, but would silently
    --      resolve some XP totals to the WRONG tier — directly changing a
    --      K9's real movement speed and scent range, this file's header's
    --      own definition of a "live gameplay effect," with no error or log
    --      line anywhere to reveal it.
    -- Fails loudly at resource start (same posture as the assert above) —
    -- a malformed Config.XPTiers should block startup, not quietly hand out
    -- wrong-tier gameplay effects to every K9 for the rest of the session.
    assert(
        type(Config.XPTiers) == 'table' and #Config.XPTiers > 0,
        '[qbx_k9unit] Config.XPTiers must be a non-empty array -- ResolveTier/GetXPTier ' ..
        '(server/progression.lua) fall back to Config.XPTiers[1] as their mandatory base-tier ' ..
        'default, which does not exist if this table is empty or malformed.'
    )
    assert(
        type(Config.XPTiers[1].xp) == 'number' and Config.XPTiers[1].xp == 0,
        '[qbx_k9unit] Config.XPTiers[1].xp must be exactly 0 -- it is this resource-wide ' ..
        "\"unknown/uncached citizenid\" and \"brand-new K9\" baseline (every file's own " ..
        '"unknown state defaults to least privilege" convention applied to XP), read by ' ..
        'ResolveTier (server/progression.lua) before its ascending walk even runs.'
    )
    for i = 1, #Config.XPTiers do
        local tier = Config.XPTiers[i]
        assert(
            type(tier) == 'table' and type(tier.xp) == 'number'
                and type(tier.speedMultiplier) == 'number' and type(tier.scentRangeMultiplier) == 'number',
            ('[qbx_k9unit] Config.XPTiers[%d] must be a table with numeric xp/speedMultiplier/' ..
                'scentRangeMultiplier fields -- ResolveTier compares `xp >= tier.xp` directly ' ..
                'against every entry with no type check of its own, and a non-numeric ' ..
                'speedMultiplier/scentRangeMultiplier would feed straight into a live movement/' ..
                'scent-range effect via client/progression.lua and server/tracking.lua.'):format(i)
        )
        if i > 1 then
            assert(
                tier.xp > Config.XPTiers[i - 1].xp,
                ('[qbx_k9unit] Config.XPTiers must be strictly ascending by xp -- entry %d ' ..
                    '(xp=%s) does not exceed entry %d (xp=%s). ResolveTier walks this array ' ..
                    'with no `break` and no threshold-order re-sort of its own, relying entirely ' ..
                    'on this caller-maintained ascending order (same contract ' ..
                    'Config.ContrabandAlertTiers and server/tenure.lua\'s milestone walk already ' ..
                    'require) to resolve the HIGHEST qualifying tier rather than an arbitrary ' ..
                    'array-order one.'):format(i, tostring(tier.xp), i - 1, tostring(Config.XPTiers[i - 1].xp))
            )
        end
    end
end)

--- Resolves `xp` to the matching entry in Config.XPTiers. Identical walk
--- shape to server/search.lua's ResolveAlertTier — Config.XPTiers[1] is the
--- mandatory `xp = 0` baseline (same role Config.ContrabandAlertTiers'
--- `minWeight = 0` baseline plays there), so this never returns nil.
--- Returns the SAME table object (by reference) for every xp value that
--- falls in one tier's bracket, which AwardXP below relies on to detect a
--- tier crossing via plain `~=` comparison rather than a deep-equality
--- check.
--- @param xp number
--- @return table tier -- { xp, label, speedMultiplier, scentRangeMultiplier }
local function ResolveTier(xp)
    local resolvedTier = Config.XPTiers[1]
    for _, tier in ipairs(Config.XPTiers) do
        if xp >= tier.xp then
            resolvedTier = tier
        end
    end
    return resolvedTier
end

--- Resource-global — see FILE-TO-FILE CONTRACT above. Always returns a real
--- Config.XPTiers entry, defaulting to the base tier for an uncached
--- citizenid (never nil, never a security-relevant fail-open — the base
--- tier grants the SMALLEST scentRangeMultiplier/speedMultiplier in the table, so an
--- unresolved cache entry can only ever under-grant, never over-grant).
--- @param citizenid string
--- @return table tier
function GetXPTier(citizenid)
    return ResolveTier(K9XP[citizenid] or 0)
end

--- Resource-global — see FILE-TO-FILE CONTRACT above.
--- @param citizenid string
--- @return number
function GetXP(citizenid)
    return K9XP[citizenid] or 0
end

-- ==========================================================================
-- XP TIER UNLOCKS -- FEATURE_IDEAS.md Part B §8 (coder-backend, this pass).
-- Config.XPTiers previously only ever changed speedMultiplier/
-- scentRangeMultiplier -- two numbers invisible to the player except as "a
-- slightly faster dog." This section connects tiers to real, checkable
-- capability by reusing systems that already exist (the doc's own framing:
-- "connects them instead of adding a new subsystem"), NOT a new
-- authorization layer of its own.
--
-- THREE UNLOCKS SHIPPED, ONE PER NON-BASE TIER:
--   Trained (1,250 XP) -- eligibility for the cooperative search bonus
--     (server/search.lua, Part B §10): BOTH the searcher and their currently
--     active partner must be Trained+ (`GetXPTier(citizenid).xp > 0` on both
--     citizenids -- never by label/index, so this stays correct even if the
--     tier table is retuned later). Lives entirely in server/search.lua's
--     TryAwardCoopSearchBonus; nothing else needed here beyond the
--     already-existing GetXPTier this reuses completely unchanged.
--   Veteran (4,000 XP) -- a reduced server/medkit.lua K9Medkit cooldown, via
--     GetXPTierMedkitCooldownMs below. See that function's own doc comment
--     for the exact contract, and this pass's own report for why the
--     one-line medkit.lua call site is REPORTED, not wired here -- that file
--     has a live owner this session.
--   Elite (9,000 XP) -- a cosmetic HUD tier badge. NO CODE CHANGE in this
--     file: PushTierSnapshot/CopyTier already forward EVERY field present on
--     a Config.XPTiers[n] row to the client verbatim (CopyTier's own
--     `for key, value in pairs(tier) do copy[key] = value end`), so a
--     reported `badge` field added to config.lua's Elite row is sufficient
--     on its own -- client/hud.lua/html/app.js (coder-ui) render it once
--     added. See this pass's own report for the exact field/asset needs.
--
-- COMPOSITION WITH THE PERMISSION/FEATURE-CONTROL LAYER (server/
-- permissions.lua's HasPermission, config.lua's Config.FeatureControl
-- resolution order -- this task's own explicit requirement). That order is
-- FOUR steps long ("Config.Features.<Name> false -> deny always; an
-- explicit BLOCK -> deny; RequireGrant -> needs a grant; otherwise ->
-- allow"), and reaching an XP tier is not, and must never become, a fifth.
-- None of the three unlocks above adds one:
--   * GetXPTierMedkitCooldownMs returns a NUMBER, never a boolean, and is
--     documented to be consulted ONLY AFTER the caller's own
--     Config.Features.K9Medkit / HasK9Access / department / proximity /
--     item gate has already allowed the action. If K9Medkit is off, blocked
--     for that citizenid, or they are not certified, medkit.lua's own
--     existing gate denies BEFORE this function is ever reached, tier or no
--     tier -- there is nothing this function could do to "silently
--     re-enable" a block, because it never participates in the allow/deny
--     decision at all. It only ever adjusts a duration for an action that
--     was already independently authorized.
--   * The coop-search-bonus tier gate (server/search.lua) only ever
--     WITHHOLDS a bonus XP amount. Reaching Trained tier cannot make anyone
--     able to search who couldn't already -- HasK9Access is re-checked,
--     unchanged, at the top of the real searchTarget callback, exactly as
--     before this pass.
--   * The HUD badge is pure display. It grants no capability at all, so
--     there is nothing for a block to conflict with.
-- REJECTED ON THIS EXACT BASIS -- composing badly with the block/grant
-- layer, not merely "not chosen": auto-granting BiteAndHold/
-- NonLethalTakedown/PropDragging (Config.FeatureControl.RequireGrant), or
-- the 'k9.access'/'k9.certify'/'k9.audit'/'k9.givexp' permissions
-- (Config.Permissions), via a tier threshold. All five are EXPLICITLY the
-- capabilities those two tables exist to put behind a deliberate, named,
-- revocable, AUDITED human decision (config.lua's own words: "this hands it
-- to one specific person," "every use is logged"). A tier-based auto-unlock
-- of any of them would be a SECOND, ungoverned path to the exact same
-- capability -- reachable purely by grinding, with no grant, no audit row,
-- and, specifically, no way for a human BLOCK to ever catch up to it, since
-- a block only stops the grant/rank path, never an XP total.
--
-- TIERS ARE REACHABLE BY FARMING -- REJECTED UNLOCKS ON THAT BASIS ALONE,
-- separate from the composition concern above (an unlock can fail this test
-- even with zero permission/block interaction). This project has closed
-- eight XP farms; the current, closed, TESTED ceiling is 3,600 XP/hr shared
-- per citizenid (XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS above),
-- reaching Elite (9,000 XP) in ~2h27m of deliberate, maximal grinding, not
-- incidental play. Considered and rejected as unsafe in the hands of a
-- citizenid who did nothing but grind for it:
--   * Any reduction of a per-mechanic MINT cooldown (BiteHoldXpMintCooldown/
--     TakedownXpMintCooldown/ContrabandXpMintCooldown/
--     TrackTicketMintCooldown/the new CoopSearchXpMintCooldown), or of
--     XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS themselves, or a raised
--     Config.XP.awards value. Every one of these IS the anti-farm floor the
--     EIGHTH-XP-FARM-FIX section above documents at length -- making any of
--     them tier-dependent would let a farmer's OWN grinding progressively
--     widen the exact ceiling meant to bound that same grinding, a
--     compounding/runaway shape strictly worse than a static farm.
--   * A reduced NonLethalTakedown/BiteAndHold ACTION cooldown (
--     Config.Combat.NonLethalTakedown.targetCooldownMs and its bite-hold
--     equivalent -- the cooldown on the ABILITY itself, not on its XP
--     mint). K9 combat is player-vs-player (a settled decision) -- a faster
--     action cooldown is a genuine PvP re-engagement advantage, not a
--     cosmetic or economy concern, and handing one to whoever ground the
--     longest is exactly the "harmful in the hands of a farmer" case this
--     task named explicitly.
--   * A raised wellbeing stat MAX (Fatigue/Mood/FearStress/Injury) via
--     tier -- the doc's own suggested example. Investigated this pass:
--     every single Clamp(...) call site in server/wellbeing.lua's tick loop
--     reads Config.Wellbeing.<Stat>.max directly, as one GLOBAL constant --
--     there is no per-citizenid cap composer to add one more input to, the
--     way client/movement.lua's K9MoveRateModifiers already composes the
--     speed/scent tier bonus. Making the cap per-citizenid would mean
--     threading a new parameter through dozens of call sites in a
--     security/balance-reviewed file this pass does not own -- a real,
--     invasive refactor, not the "small-moderate, mostly reads" effort the
--     doc estimated. Rejected on cost/ownership grounds, not a farmability
--     concern -- flagged here so a future pass with wellbeing.lua ownership
--     does not have to rediscover this from scratch.
-- ==========================================================================

--- Resource-global — Part B §8 XP TIER UNLOCKS (see the section header
--- immediately above for the full "why this is safe" writeup). Returns the
--- EFFECTIVE K9Medkit cooldown for `citizenid`'s own tier given the
--- feature's own configured `baseCooldownMs` — never a boolean, never an
--- access decision. A pass-through-with-clamping over an OPTIONAL
--- `medkitCooldownMultiplier` field on the citizenid's current
--- Config.XPTiers row (reported to config.lua's owner; not present on any
--- shipped row today, so this defensively returns `baseCooldownMs`
--- UNCHANGED until that field is added — a clean no-op, never an error, on
--- an unmodified config).
---
--- CALLER CONTRACT (server/medkit.lua — reported, not wired, this pass; see
--- this pass's own report for the exact one-line call-site snippet):
--- consult this ONLY AFTER every one of that file's own existing gates
--- (Config.Features.K9Medkit, the proximity/item/department checks) has
--- already allowed the action. This function performs NONE of those checks
--- itself and must never be treated as one — it is a pure numeric modifier
--- for an action the caller has already independently authorized, the same
--- "modifier, never a gate" role speedMultiplier/scentRangeMultiplier
--- already play for movement/tracking.
---
--- DEFENSIVE BOUNDS, never trust the config value blindly: a multiplier
--- that is missing, non-numeric, NaN, <= 0, or > 1 returns `baseCooldownMs`
--- UNCHANGED rather than applying it — this is an UNLOCK (only ever a
--- reduction), never a way to lengthen a cooldown, and a <= 0 result would
--- hand server/cooldowns.lua's IsOnCooldown a non-positive threshold, which
--- that file's own header documents as PERMANENTLY ON — the opposite of a
--- Veteran-tier reward, and exactly the kind of footgun this guard exists
--- to prevent.
--- @param citizenid string
--- @param baseCooldownMs number
--- @return number effectiveCooldownMs
function GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs)
    if type(baseCooldownMs) ~= 'number' or baseCooldownMs ~= baseCooldownMs or baseCooldownMs <= 0 then
        return baseCooldownMs
    end

    local tier = GetXPTier(citizenid)
    local multiplier = tier.medkitCooldownMultiplier
    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 or multiplier > 1 then
        return baseCooldownMs
    end

    return math.max(1, math.floor(baseCooldownMs * multiplier))
end

--- Loads a citizenid's real XP total from k9_progression into the K9XP
--- cache. pcall-wrapped mirroring server/certifications.lua's
--- RefreshCertificationCache precedent — an uncaught error here must not
--- abort the caller's own loop (PlayerLoaded fires per-player, but the
--- resource-start backfill loop below iterates every connected player in
--- one handler invocation, and FXServer's dispatch pcalls the whole
--- handler, not each iteration, so one bad row would otherwise wedge every
--- subsequent player — the exact bug class server/main.lua's own backfill
--- loop header already documents finding and fixing once for
--- certifications). Unlike certification access, a failed XP read has no
--- security consequence either way (XP grants a bounded scent/speed bonus,
--- never a permission), so this fails to a safe 0-XP baseline rather than
--- "failing closed" in the access-control sense.
--- @param citizenid string
--- @return number xp -- the freshly-cached value
local function LoadXPForCitizenid(citizenid)
    local queryOk, xpOrErr = pcall(MySQL.scalar.await, 'SELECT xp FROM k9_progression WHERE citizenid = ? LIMIT 1', {
        citizenid,
    })

    if not queryOk then
        print(('[qbx_k9unit] progression: LoadXPForCitizenid query failed for %s: %s'):format(citizenid, tostring(xpOrErr)))
        K9XP[citizenid] = 0
        return 0
    end

    K9XP[citizenid] = xpOrErr or 0 -- no row yet = 0 XP / base tier, same as k9_certifications' "no active cert row" = false
    return K9XP[citizenid]
end

--- Pushes an authoritative tier snapshot to a specific, currently-connected
--- player's client. Gated on Config.Features.XPProgression — no client-side
--- consequence should ever apply while the feature is disabled, per
--- SPEC.md §3's "read the flag at the point of use" rule; the K9XP cache
--- itself is still warmed/kept in sync regardless of the flag (cheap, and
--- avoids losing real accumulated progress data just because the feature
--- is temporarily toggled off).
--- @param targetSrc number
--- @param tier table
local function PushTierSnapshot(targetSrc, tier)
    if not Config.Features.XPProgression then return end
    TriggerClientEvent('qbx_k9unit:client:xpTierChanged', targetSrc, tier)
end

--- Copies a Config.XPTiers-shaped entry (xp/label/speedMultiplier/
--- scentRangeMultiplier) into a fresh table — identical shape/purpose to
--- server/exports.lua's own `ShallowCopyTier`, duplicated here rather than
--- shared, since this file has no import mechanism to reach that one.
--- ResolveTier above deliberately returns the SAME Config.XPTiers[n] table
--- object (by reference) for every citizenid whose xp falls in one tier's
--- bracket (see that function's own doc comment) — handing that reference
--- out in an outbound event payload would let an external resource's
--- handler mutate `tier.speedMultiplier` and corrupt movement speed for
--- every K9 in that tier, server-wide, for the rest of this resource's
--- uptime. Always copy before it leaves this file via FireOutboundEvent.
--- @param tier table
--- @return table copy
local function CopyTier(tier)
    local copy = {}
    for key, value in pairs(tier) do
        copy[key] = value
    end
    return copy
end

--- Fires a stable `qbx_k9unit:events:*` outbound event for other resources
--- (dispatch/MDT/evidence integrations — see server/exports.lua's header
--- "EVENT CONTRACT" section for the full documented contract this
--- implements). Same shape/reasoning as server/certifications.lua's and
--- server/partnership.lua's own file-local copies of this helper: fired
--- ONLY after the change it reports on has already committed (per this
--- file's own design, that commit point is the synchronous K9XP cache
--- write in AwardXP below, NOT the fire-and-forget DB UPSERT that follows
--- it — see that function's own comment on why correctness never depends
--- on DB round-trip latency here), and pcall-wrapped so a misbehaving
--- consumer's `AddEventHandler` throwing can never unwind back into (and
--- abort) the AwardXP call that fired it.
--- @param eventName string
--- @param ... any
local function FireOutboundEvent(eventName, ...)
    local ok, err = pcall(TriggerEvent, eventName, ...)
    if not ok then
        print(('[qbx_k9unit] outbound event %s: a registered handler in another resource errored: %s'):format(eventName, tostring(err)))
    end
end

--- Resource-global — see FILE-TO-FILE CONTRACT above for the full contract.
--- THE single server-authoritative XP-award entry point. Never trusts a
--- client-claimed XP delta or tier — `actionKey` selects a flat, config-owned
--- amount; there is no path for a caller (or, transitively, a client) to
--- specify an arbitrary amount.
--- @param citizenid string
--- @param actionKey string -- a key in Config.XP.awards
function AwardXP(citizenid, actionKey)
    if not Config.Features.XPProgression then return end -- real server-side no-op regardless of caller state, per SPEC.md §3
    if type(citizenid) ~= 'string' or citizenid == '' then return end -- defensive: never trust a malformed caller argument

    local amount = Config.XP.awards[actionKey]
    if type(amount) ~= 'number' then
        -- Defensive: an unknown actionKey is a CALLER bug (a typo'd string
        -- literal at a new call site), not a runtime condition to silently
        -- swallow — log it so it's visible in server console rather than
        -- silently granting 0 XP forever.
        print(('[qbx_k9unit] progression: AwardXP called with unknown actionKey %q for citizenid %s'):format(tostring(actionKey), citizenid))
        return
    end

    -- CHOKEPOINT-LEVEL RATE FLOOR — see AwardXPCooldown's own declaration
    -- comment above for the full reasoning/threshold justification. Gated
    -- AFTER the actionKey validity check above (a malformed/unknown-key call
    -- is already rejected and should not consume this budget), BEFORE any
    -- cache mutation or DB write below — this is a pure entry guard, no
    -- state has been touched yet if this returns early. Silent no-op on
    -- trip (consistent with every existing per-site cooldown's own "still on
    -- cooldown = quiet no-op" convention, e.g. server/tracking.lua's
    -- TrackArrivalReportCooldown), but logged — unlike those per-site
    -- cooldowns, a real player's own normal play can never trip this one
    -- (see threshold reasoning above), so a trip here is itself a signal
    -- worth surfacing to server console rather than staying silent forever.
    if not AwardXPCooldown.Consume(citizenid, actionKey, 500) then
        print(('[qbx_k9unit] progression: AwardXP rate floor tripped for citizenid %s actionKey %q -- this should never happen from genuine play; investigate the calling code path'):format(citizenid, actionKey))
        return
    end

    -- EIGHTH XP-FARM FIX -- see the XP_MINT_BUDGET_*/XPMintBudget
    -- declarations above this function for the full derivation and the
    -- fail-OPEN reasoning. Checked AFTER the actionKey-validity and
    -- per-(citizenid, actionKey) rate-floor checks above (an already-
    -- rejected call must never spend this shared budget either), BEFORE any
    -- cache/DB mutation below -- same "reject before touching state" order
    -- this function already follows throughout.
    -- EDGE CASE, checked before touching the bucket at all (coordinator-
    -- prompted re-check, this pass, of "what else could go wrong here"):
    -- `amount` is only type-checked as `type(amount) == 'number'` above --
    -- never asserted positive. Every Config.XP.awards value shipped today
    -- IS positive, but nothing enforces that for a future entry, and this
    -- budget's own math silently breaks on a non-positive one: `bucket.
    -- tokens < amount` is FALSE for any non-positive amount (tokens is
    -- never negative), so the deny-path never triggers, and `tokens =
    -- tokens - amount` then SUBTRACTS a non-positive number, i.e. INCREASES
    -- the bucket -- a negative/zero award would silently mint free budget
    -- instead of spending it. `amount > 0` is asserted at resource start
    -- below for every currently-configured award (see the STRUCTURAL GUARD
    -- assert further above) precisely so this can never fire against a real
    -- shipped value -- kept here anyway as an explicit runtime guard, not
    -- just a start-time assert, matching this file's own "fail loud enough
    -- to be caught, never silently wrong" posture elsewhere.
    if XPMintBudgetEnabled and amount > 0 then
        local budgetNow = GetGameTimer()
        local bucket = XPMintBudget[citizenid]
        if not bucket then
            -- Starts at XP_MINT_BUDGET_STARTER_TOKENS -- NEITHER 0 NOR the
            -- full cap. See that constant's own declaration comment (and the
            -- XP_MINT_BUDGET_* section's "STARTING BALANCE" writeup above
            -- this function) for the full history: both other options were
            -- tried and rejected THIS SAME PASS after simulation showed each
            -- one broken in a different, serious way -- start-full re-opens
            -- a burst-doubling exploit that defeats this section's own
            -- >2-hour design goal; start-EMPTY-with-no-elapsed-time silently
            -- denies every citizenid's very first-ever AwardXP call, every
            -- session (caught live via tests/progression_spec.lua before
            -- this shipped). Do not change this back to either without
            -- re-reading that history first.
            bucket = { tokens = XP_MINT_BUDGET_STARTER_TOKENS, lastRefillAt = budgetNow }
            XPMintBudget[citizenid] = bucket
        else
            RefillMintBudget(bucket, budgetNow)
        end
        if bucket.tokens < amount then
            -- Silent no-op on trip -- same convention as every per-mechanic
            -- mint cooldown's own Consume-fails-silently posture. Unlike
            -- AwardXPCooldown's own trip above, this is the EXPECTED
            -- steady-state outcome for a citizenid genuinely farming at or
            -- near the combined ceiling, not a caller-bug signal -- logging
            -- every occurrence here would spam console under exactly the
            -- sustained-farming behavior this section exists to bound.
            return
        end
        bucket.tokens = bucket.tokens - amount
    end

    local oldXp = K9XP[citizenid] or 0
    local oldTier = ResolveTier(oldXp)

    local newXp = oldXp + amount
    -- Update the in-memory cache SYNCHRONOUSLY, before the DB write below —
    -- phase2_notes/RESEARCH_ARCHIVE.md#xp-schema §5: correctness of the applied
    -- gameplay effect (tier-derived scentRangeMultiplier/speedMultiplier) depends only
    -- on this line, never on DB round-trip latency.
    K9XP[citizenid] = newXp

    -- Non-blocking, atomic UPSERT — never delays or risks whatever
    -- server-side success path just called this function. `amount` (the
    -- delta), not `newXp` (the new total), is the second bound parameter —
    -- `VALUES(xp)` on the ON DUPLICATE KEY branch refers to the
    -- just-inserted delta, giving a single-statement atomic
    -- increment-or-create with no separate SELECT-then-UPDATE round trip
    -- (phase2_notes/RESEARCH_ARCHIVE.md#xp-schema §4). CONCURRENCY: this is safe
    -- against a lost update even with several of these in flight at once for
    -- the SAME citizenid (e.g. two award paths landing in the same tick) —
    -- MySQL/MariaDB serializes concurrent UPSERTs against the same unique
    -- key via row-level locking, and `xp = xp + VALUES(xp)` is evaluated
    -- inside that same locked, single statement, so there is no read-then-
    -- write gap for a second statement to race into. The in-memory K9XP
    -- cache write above is ALSO safe under concurrency for a more basic
    -- reason: FXServer's Lua VM is single-threaded/cooperatively
    -- scheduled, and AwardXP contains no `await`/yield point before that
    -- line, so two calls for the same citizenid can never interleave
    -- between the read of `oldXp` and the write of `K9XP[citizenid]`.
    --
    -- SILENT-FAILURE FIX, this pass (audit finding): this used to be
    -- `pcall(MySQL.insert, [[...]], {...})` — a fire-and-forget call with NO
    -- callback at all. That pcall is decorative, not protective: oxmysql's
    -- non-`.await` entry point (server/cooldowns.lua's sibling files'
    -- comments call this "Non-blocking (`MySQL.insert(...)` WITHOUT
    -- `.await`)") returns to the caller the instant the query is HANDED OFF
    -- to oxmysql's own async worker, before the query has actually run
    -- against the database — a real failure (a missing `k9_progression`
    -- table from an unapplied migration, a constraint violation, a
    -- transient connection drop) surfaces later, asynchronously, entirely
    -- outside this pcall's stack frame. Worse, oxmysql only forwards a
    -- query's error into a caller-supplied callback when
    -- `return_callback_errors` is enabled (fxmanifest.lua's own
    -- `mysql_option` metadata — grepped this resource's fxmanifest.lua
    -- before writing this comment: not set anywhere), which the original
    -- callback-less call never opted into either way. Net effect: a broken
    -- `k9_progression` table could make every single award silently fail to
    -- persist forever, while every in-memory/gameplay effect (tier bonuses,
    -- the xpTierChanged push) kept working normally — completely invisible
    -- until someone happened to compare a player's real DB row against
    -- their session's tier. FIXED by moving the write into its own
    -- CreateThread and using `MySQL.insert.await` inside it: `.await`
    -- (server/oxmysql's own promise-based wrapper) unconditionally requests
    -- error propagation regardless of the `return_callback_errors` resource
    -- metadata setting, so a real query failure now raises a genuine Lua
    -- error that this pcall actually catches and logs. The CreateThread
    -- wrapper is what keeps this non-blocking for AwardXP's own caller:
    -- `.await` yields the coroutine it runs IN, and running it inside a
    -- freshly spawned thread means the coroutine that suspends is this
    -- write's own, never the search/tracking/combat/tenure call site's own
    -- execution path — AwardXP itself still returns immediately either way.
    CreateThread(function()
        local insertOk, insertErr = pcall(MySQL.insert.await, [[
            INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?)
              ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP
        ]], { citizenid, amount })
        if not insertOk then
            print(('[qbx_k9unit] progression: AwardXP UPSERT failed for citizenid %s -- %d XP for actionKey %q was NOT persisted to k9_progression (in-memory tier/session effects already applied and are unaffected): %s'):format(citizenid, amount, actionKey, tostring(insertErr)))
        end
    end)

    local newTier = ResolveTier(newXp)
    if newTier ~= oldTier then
        -- Outbound integration event (server/exports.lua's EVENT CONTRACT
        -- §6) — fired here, at the exact crossing this branch already
        -- exists to detect, with FRESH COPIES of both tiers (never the
        -- shared Config.XPTiers[n] reference newTier/oldTier actually hold
        -- — see CopyTier's own doc comment above for exactly why that
        -- matters). Deliberately fired regardless of whether `citizenid`
        -- currently resolves to an online player, unlike the client-facing
        -- PushTierSnapshot call below it: this is a citizenid-keyed
        -- integration signal for OTHER resources, not a client HUD push, so
        -- there is no reason to suppress it just because this K9's own
        -- client happens not to be connected right now (mirrors
        -- server/certifications.lua's certificationRevoked event, which
        -- likewise fires for both online and offline targets).
        FireOutboundEvent('qbx_k9unit:events:xpTierReached', citizenid, CopyTier(newTier), CopyTier(oldTier))

        -- Only push the CLIENT-facing snapshot if the citizenid resolves to
        -- a CURRENTLY connected player — every real call site today only
        -- ever awards XP to the player who just performed the action
        -- (always online at call time), but this stays generic
        -- (GetPlayerByCitizenId, not an assumed `source`) rather than
        -- asserting that invariant, mirroring server/certifications.lua's
        -- ForceDetachLeashIfOnline's own "resolve by citizenid, no-op if
        -- not currently online" shape.
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            PushTierSnapshot(onlineSrc, newTier)
        end
    end
end

--- Awards an EXPLICIT XP amount, for /k9givexp only.
---
--- This deliberately breaks the invariant AwardXP above exists to protect.
--- AwardXP takes an actionKey and looks the amount up in config precisely so
--- that no caller -- and therefore, transitively, no client -- can ever name
--- an arbitrary number. Weakening AwardXP to accept an amount would have
--- removed that guarantee for every one of its callers, so this is a
--- separate entry point rather than a new parameter.
---
--- What bounds it instead:
---   * server/highcommand.lua is the ONLY caller, and re-resolves the
---     caller's rank server-side on every invocation.
---   * the amount is clamped to Config.HighCommand.maxXpPerGrant there.
---   * every grant is logged with granter, target, amount and new total.
---
--- Deliberately NOT subject to AwardXPCooldown or the shared XP mint budget.
--- Those exist to bound how fast a PLAYER can farm XP through gameplay; a
--- high-command grant is an audited administrative act, and silently
--- swallowing one because a farming budget was exhausted would look to the
--- officer like the command simply did nothing.
---
--- @param citizenid string
--- @param amount number a positive integer; fractional values are floored
--- @param reason string? free-text, for the failure log only
--- @return number|nil newTotal nil if the award was rejected
function AwardXPDirect(citizenid, amount, reason)
    if not Config.Features.XPProgression then return nil end
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    -- amount ~= amount catches NaN, which would otherwise poison the total.
    if type(amount) ~= 'number' or amount ~= amount or amount <= 0 then return nil end
    if amount == math.huge then return nil end
    amount = math.floor(amount)

    local oldXp = K9XP[citizenid] or 0
    local oldTier = ResolveTier(oldXp)
    local newXp = oldXp + amount
    K9XP[citizenid] = newXp

    -- Non-blocking, matching AwardXP's own persistence shape: a fresh thread
    -- so the .await is real (and so the pcall around it can actually catch a
    -- DB error -- a pcall around a non-await MySQL call catches nothing,
    -- because the worker runs the query long after the pcall frame is gone).
    CreateThread(function()
        local ok, err = pcall(MySQL.insert.await, [[
            INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?)
              ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP
        ]], { citizenid, amount })
        if not ok then
            print(('[qbx_k9unit] progression: AwardXPDirect UPSERT failed for %s -- %d XP (%s) granted in memory but NOT persisted: %s')
                :format(citizenid, amount, tostring(reason), tostring(err)))
        end
    end)

    local newTier = ResolveTier(newXp)
    if newTier ~= oldTier then
        FireOutboundEvent('qbx_k9unit:events:xpTierReached', citizenid, CopyTier(newTier), CopyTier(oldTier))
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            PushTierSnapshot(onlineSrc, newTier)
        end
    end

    return newXp
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then return end

    local xp = LoadXPForCitizenid(citizenid)

    -- Authoritative snapshot on every login, unconditionally (not just on a
    -- "change" from some prior value) — a freshly connected client has no
    -- prior client-side tier state to diff against at all, so there is
    -- nothing to compare here. See client/progression.lua's own
    -- xpTierChanged handler for how it avoids treating this as a fresh
    -- level-up notification.
    local targetSrc = Player.PlayerData.source
    if type(targetSrc) == 'number' then
        PushTierSnapshot(targetSrc, ResolveTier(xp))
    end
end)

-- STRUCTURAL GAP backfill (mirrors server/main.lua's identical backfill for
-- Certifications, same rationale restated here for THIS cache): a
-- `/restart qbx_k9unit` while players are already online does not re-fire
-- PlayerLoaded for them, so their K9XP entry would sit at the default
-- ResolveTier(0) baseline (silently losing their real tier's scent/speed
-- bonus for the remainder of their session) until their next reconnect —
-- unless this loop re-warms the cache immediately at resource start.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- PERFORMANCE FIX (QA pass): AwardXP (this file's ONLY write path to
    -- `k9_progression`) is itself a no-op whenever Config.Features.XPProgression
    -- is false, so on a server where the flag has never been enabled no
    -- citizenid can have a real row to warm here -- this loop was still
    -- running a real MySQL.scalar.await per connected player
    -- (LoadXPForCitizenid) for a cache PushTierSnapshot immediately
    -- discards anyway (it's gated on the same flag). Gated here the same
    -- way the write path already is.
    --
    -- KNOWN TRADE-OFF, disclosed rather than silently accepted: GetXP/
    -- GetXPTier (server/exports.lua, and this file's own doc comments) are
    -- deliberately NOT gated on this flag, so an operator who enables it,
    -- lets a citizenid earn real XP, disables it again, then restarts this
    -- resource while that citizenid is still online reintroduces this
    -- loop's own original "cache sits at 0 until next reconnect" gap for
    -- that narrow case. Accepted here for the same reason
    -- server/partnership.lua's identical-shape fix accepts the mirror
    -- case: earning XP at all already required the flag to have been
    -- deliberately turned on once; the common "flag has always been
    -- false" default-install case this fix targets cannot exhibit it.
    if not Config.Features.XPProgression then return end

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                local citizenid = Player.PlayerData.citizenid
                local xp = LoadXPForCitizenid(citizenid)
                PushTierSnapshot(src, ResolveTier(xp))
            end
        end
    end
end)

-- Regression-test-class fix, applied proactively (mirrors
-- server/certifications.lua's own documented fix for the identical shape of
-- bug on its `Certifications` cache): K9XP is keyed by citizenid and would
-- otherwise accumulate one entry per distinct citizenid ever loaded this
-- session with nothing ever evicting an entry — not a correctness bug (a
-- stale cached total for a now-offline citizenid is simply never read again
-- until PlayerLoaded repopulates it fresh), just unbounded memory growth on
-- a long-running server. Resolve the citizenid for the disconnecting source
-- via qbx_core (still resolvable here — playerDropped fires before the
-- framework fully tears down the player object, same timing
-- server/certifications.lua's own playerDropped handler already relies on)
-- and drop its cache entry.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        K9XP[citizenid] = nil
        -- Drops every actionKey entry AwardXPCooldown holds for this
        -- citizenid in one call (NewNestedCooldown's :Clear(primaryKey)
        -- shape) — see that tracker's own declaration comment for why this
        -- is a per-citizenid prune rather than :RegisterPlayerDropped().
        -- Not a correctness requirement (a stale entry for an offline
        -- citizenid is simply never read again until they reconnect and
        -- earn XP fresh), same bounded-memory-growth rationale as the K9XP
        -- eviction above it.
        AwardXPCooldown.Clear(citizenid)

        -- XPMintBudget (the EIGHTH-XP-farm-fix shared cross-mechanic budget)
        -- is DELIBERATELY NOT cleared here, unlike K9XP/AwardXPCooldown
        -- immediately above -- see that tracker's own declaration comment
        -- for the full reasoning. Clearing it on disconnect would hand a
        -- farmer a fresh, full budget just by reconnecting, defeating the
        -- entire point of the fix this pass exists to close. It is bounded
        -- for memory instead by its own periodic sweep thread, which only
        -- evicts an entry once it would already have refilled to full
        -- capacity anyway.
    end
end)
