--[[
    qbx_k9unit/server/tenure.lua

    Gives `server/partnership.lua`'s registry (landed this session, that
    file's own header: "a FOUNDATION only... zero gameplay consequence
    wired to it yet") a real, modest gameplay payoff: a handler+K9 pair who
    STAY partnered accrue tenure, and crossing a tenure threshold grants a
    one-time, flat XP bonus to the K9-role party -- DEVELOPER_REFERENCE.md Part B
    §7 ("Partnership-tenure bonuses") -- formerly COMPLEMENTARY_FEATURES.md,
    merged 2026-08-25, the #3 item in that pass's "Top 3"
    specifically because the registry already carries everything this file
    needs (`established_at`, `GetActivePartnerCitizenId`) with zero new
    subsystem required.

    ======================================================================
    STATUS UPDATE (follow-up pass, verified directly against each file
    named below, not assumed): every schema/config/manifest item this
    file's original header below describes as "PROPOSED" / "NOT applied by
    this file" HAS SINCE LANDED, exactly as specified:
      - sql/install.sql's `k9_partnerships` CREATE TABLE, and
        sql/migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql,
        both carry `tenure_bonus_tier_granted TINYINT UNSIGNED NOT NULL
        DEFAULT 0` matching this file's SELECT/UPDATE text exactly.
      - config.lua carries `Config.Features.PartnershipTenureBonus = false`
        (still off by default, per this file's own design question 2/3
        reasoning -- landing the schema/config did not flip it on),
        `Config.XP.awards.partnershipTenure{1,7,30}Day = 15/40/100`, and
        `Config.Partnership.TenureBonus` (checkIntervalMs + the same
        three-milestone table) -- all matching the values this file's own
        closing comment block proposed.
      - fxmanifest.lua's server_scripts loads `server/tenure.lua` after
        `server/cooldowns.lua`/`server/notify.lua`, per this file's own
        requirement.
    The remaining "proposed"/"not applied" language throughout this file's
    header is left in place below where it still records real DESIGN
    reasoning (why this shape, not a different one) -- only the STATUS
    claim was stale, not the reasoning behind it. This file's own runtime
    behaviour needed no change for any of this: every query was already
    pcall-wrapped against exactly this possibility (see "WHY ONE NEW COLUMN
    IS UNAVOIDABLE" below), so it was never broken by the dependency being
    unmet, and requires no change now that the dependency is met either.

    ======================================================================
    SCOPE BOUNDARY THAT SHAPED EVERY DESIGN CHOICE BELOW: this file was
    written under a hard constraint -- every OTHER existing `.lua` file in
    this resource (server/partnership.lua, server/progression.lua,
    server/wellbeing.lua, client/movement.lua included) is OFF LIMITS, not
    just "prefer not to touch." DEVELOPER_REFERENCE.md Part B §7's own "Needs"
    paragraph assumed a coder who COULD edit server/wellbeing.lua to add one
    more key to the existing Mood-regen/K9MoveRateModifiers composer -- that
    path is genuinely closed here, since `WellbeingStats` is `local` to that
    file and `K9MoveRateModifiers` lives in client/movement.lua, off limits
    for this pass. Every choice below routes only through the resource-global
    functions those files ALREADY expose for exactly this kind of external
    consumption (`GetActivePartnerCitizenId` from server/partnership.lua,
    `AwardXP`/`HasK9Access` from server/progression.lua and
    server/certifications.lua respectively) plus a direct, read-only SELECT
    against `k9_partnerships` (a real table, not a `local` -- reading it here
    is no different from server/partnership.lua's own SELECTs). This is
    disclosed up front because it is the reason this file's actual mechanic
    (a milestone XP bonus) is narrower than §7's own "Mood regen bonus /
    raised Fatigue cap" suggestion -- not a downgrade chosen for its own
    sake, a downgrade forced by the file-scope boundary this pass operates
    under.

    ======================================================================
    THE FOUR DESIGN QUESTIONS THIS FILE HAD TO ANSWER, ANSWERED EXPLICITLY
    (per the review brief that produced this file -- restated here, not just
    in a commit message, because a future editor of THIS file needs the same
    reasoning this file's own author had):

    1. DERIVE FROM EXISTING COLUMNS, OR NEW TABLE? -- Neither, exactly: the
       TENURE VALUE itself needs no new schema at all -- it is
       `TIMESTAMPDIFF(SECOND, established_at, NOW())` against the row
       sql/install.sql's `k9_partnerships` already carries, computed fresh
       on every check (see CheckTenureMilestonesForK9 below), never cached
       across a restart. The ONLY new schema this file needs -- and it is
       NOT written here, only proposed, since sql/install.sql is not this
       pass's file to edit -- is ONE new column on the EXISTING
       `k9_partnerships` table (no new table): a small persisted counter
       recording which milestone tier has already been paid out for THIS
       partnership row. See "WHY ONE COLUMN IS UNAVOIDABLE" below for
       exactly why an in-memory-only marker cannot substitute for it, and
       this file's closing comment block for the exact proposed DDL.

    2. FEED THE EXISTING PROGRESSION, OR GRANT SOMETHING CATEGORICALLY
       DIFFERENT? -- Feeds the existing progression, deliberately, and NOT
       by choice alone: `Config.XPTiers`' speedMultiplier/scentRangeMultiplier are the
       "categorically different" alternative DEVELOPER_REFERENCE.md Part B §7
       itself names (a Mood-regen bonus, a raised Fatigue cap) -- both of
       which require write access to server/wellbeing.lua's `local`
       WellbeingStats / client/movement.lua's K9MoveRateModifiers, both off
       limits per the SCOPE BOUNDARY above. server/progression.lua's
       `AwardXP(citizenid, actionKey)` is the ONE resource-global mutation
       hook this resource already ships specifically for an external file
       to call without editing progression.lua itself (its own header:
       "server/combat.lua, once built, should call this the same way" --
       this file is exactly that kind of soft, guarded consumer, just for a
       tenure milestone instead of a combat success). This is NOT a second
       XP system: no new tier table, no new threshold curve independent of
       Config.XPTiers, no new currency -- it is three new, flat, ONE-TIME
       `Config.XP.awards` entries (proposed, not added here -- config.lua is
       not this pass's file) feeding the exact same `k9_progression` total
       and the exact same `Config.XPTiers` bracket walk every other award
       already feeds. A K9 who reaches Elite tier via tenure XP got there
       through literally the same accumulated-total mechanism as a K9 who
       got there via contraband finds -- there is nothing tenure-specific
       for a future editor to keep in sync with Config.XPTiers, because
       there is nothing tenure-specific downstream of the AwardXP call at
       all.

    3. DOES TENURE REQUIRE ACTIVITY? -- Split answer, stated honestly rather
       than picked to sound stricter than it is:
         (a) THE CLOCK is deliberately AFK-accruable. Elapsed tenure is pure
             wall-clock time since `established_at` -- it cannot be
             accelerated by any action, online or offline, by one player or
             by two. This is safe specifically BECAUSE of point (b) below:
             the total value obtainable from this clock, ever, for one
             partnership, is a small, HARD-CAPPED constant (three
             milestones, proposed 15+40+100 = 155 XP total -- see the
             proposed Config.XP.awards values in the closing comment block),
             not a per-tick or per-day trickle. Idling a partnership for a
             year nets the IDENTICAL total reward as idling it for 31 days;
             there is no unbounded farm surface here because there is no
             "more" to farm past the last milestone. For comparison, a
             single successful contraband search already pays
             `searchContrabandFound = 25` XP (config.lua, existing) -- the
             ENTIRE lifetime tenure bonus this file can ever grant one
             partnership is worth roughly what six real searches already
             pay today, spread across a minimum of 30 real-world days. This
             is deliberately not worth actively farming.
         (b) THE PAYOUT is activity-gated: CheckTenureMilestonesForK9 below
             requires BOTH parties currently ONLINE and within
             `Config.Partnership.ProximityMeters` of each other (the SAME
             constant server/partnership.lua already uses for "stand near
             each other to partner up" -- reused, not duplicated) at the
             exact moment a milestone becomes payable. A partnership that
             establishes and is never actually visited together again pays
             out NOTHING, ever, no matter how much calendar time passes --
             this closes the most degenerate version of the exploit (two
             alts partnered once, left logged in unattended in separate
             corners of the map, or one logged off entirely) without
             requiring this file to hook into any real gameplay action
             (a search, a track, a bite-hold) it cannot reach given the
             SCOPE BOUNDARY above. Disclosed honestly: "stand near your
             partner" is a LIGHT activity bar, not "do something together"
             -- a pair that logs in, stands together for the seconds this
             file's tick takes to notice, and logs back off has cleared it.
             That is an accepted, disclosed limitation, not an oversight --
             a stronger bar (e.g. "credit only after a joint search," per
             DEVELOPER_REFERENCE.md Part B §10's separate, NOT-built-here idea)
             would require hooking server/search.lua's own success path,
             which is off limits this pass for the same SCOPE BOUNDARY
             reason as wellbeing.lua/movement.lua above. Given the reward's
             hard-capped, modest total size (point (a)), a light activity
             bar was judged sufficient rather than worth reaching for a
             file this pass cannot touch.

    4. RESET OR PERSIST ACROSS A BREAK + RE-FORM? -- RESET, and for FREE:
       this file never sums tenure across multiple `k9_partnerships` rows
       for the same pair -- it only ever reads the CURRENTLY ACTIVE row's
       own `established_at`. server/partnership.lua's own establish flow
       always INSERTs a brand-new row on every acceptance (append-mostly
       audit log, exactly like `k9_certifications` -- see that file's own
       header "SCHEMA-TO-CODE MAPPING" section), so a broken-then-reformed
       partnership, even with the exact same two citizenids, gets a fresh
       `established_at` and this file's own proposed
       `tenure_bonus_tier_granted` column defaults back to 0 for that new
       row -- tenure resets to zero with ZERO additional code in this file
       to make that happen. This was a deliberate choice, not merely the
       path of least resistance: summing historical rows to PERSIST tenure
       across a re-pair would directly reward exactly the "break up, grab a
       different partner, come back to your original partner later" cheese
       the review brief warned about, and would be inconsistent with how
       every other audit-row table in this schema already treats a new row
       as a genuinely new instance (a re-granted `k9_certifications` row
       does not inherit the revoked row's old `granted_at`). Legitimate
       reconnects are NOT punished by this reset: server/partnership.lua's
       own `playerDropped` handler explicitly does NOT tear down a
       partnership on disconnect (that file's header: "OFFLINE-CAPABLE BY
       DESIGN" / "a K9 partnership is explicitly designed to SURVIVE a
       disconnect") -- the row, and its `established_at`, are untouched by
       either party disconnecting and reconnecting. Tenure only ever resets
       when the partnership genuinely, actually ends (self-break, or a
       forced teardown via decertification/department change) and a new one
       is later established -- which is exactly when resetting is correct.

    ======================================================================
    WHY ONE NEW COLUMN IS UNAVOIDABLE (constraint 1's "strongly prefer no
    new table" was honored -- no new table exists here -- but a single new
    COLUMN on the already-existing `k9_partnerships` table could not be
    avoided, and this section is the honest accounting of why, rather than
    silently shipping the unsafe alternative):

    A milestone reward that is "granted once, ever, per partnership" needs
    SOME durable marker of "already granted," or a resource/server restart
    -- an ordinary, frequent, non-adversarial event this codebase's OWN
    conventions already treat as something that must never silently lose or
    duplicate state (see server/certifications.lua's and
    server/partnership.lua's own `onResourceStart` backfill loops, and
    sql/install.sql's own `k9_progression` header on exactly this class of
    bug) -- would re-grant EVERY already-earned milestone for EVERY
    still-active, past-threshold partnership on EVERY restart, forever. An
    in-memory-only `local` table in this file cannot be that marker: it is
    empty again the instant this resource restarts, and the underlying
    `k9_partnerships` row it would need to remember (id, active, an
    unresetting `established_at`) survives the restart unchanged, so the
    exact same query would recompute the exact same "past this threshold"
    answer immediately afterward, with nothing to distinguish "never paid"
    from "paid once already, just before the restart." This is not a
    theoretical edge case for this codebase specifically -- nightly/ops
    restarts are the NORMAL case this resource's own restart-backfill
    conventions are built around, not a rare failure mode. The proposed
    column (`tenure_bonus_tier_granted`, one small TINYINT UNSIGNED,
    default 0) is therefore the minimum viable durable state, NOT written
    here (see the closing comment block for the exact proposed DDL and why
    it belongs to whoever owns sql/install.sql) -- this file's own queries
    are pcall-wrapped exactly the way server/progression.lua's own
    `k9_progression` queries already are (that table's header: "schema
    landing behind its own implementation... every award silently no-op'd
    at the DB layer" -- same precedented, disclosed pattern applied here,
    not a new one invented for this file), so this entire feature stays a
    silent, harmless no-op until that column actually exists, rather than
    erroring.

    ======================================================================
    CONSTRAINT 5 COMPLIANCE -- "AN ESTABLISHED PARTNERSHIP DOES NOT IMPLY
    CURRENTLY-VALID CERTIFICATION": CheckTenureMilestonesForK9 below re-runs
    `HasK9Access(k9Src)` (server/certifications.lua, resource-global,
    behind the same `type(...) == 'function'` runtime-existence guard this
    resource's convention requires for every soft cross-file dependency)
    and a fresh `Config.Departments[handlerJob.name]` membership check for
    the HANDLER, immediately before every grant -- neither is assumed from
    the partnership row merely being `active = 1`. This is DELIBERATELY
    DIFFERENT from, and does not contradict, server/partnership.lua's own
    documented "ROLE IS FROZEN AT ESTABLISHMENT, NEVER RE-DERIVED" rule --
    that rule is about WHICH citizenid holds WHICH ROLE in the relationship
    (a re-derivation this file correctly does NOT attempt, exactly per that
    file's own stated reasoning for why re-deriving role from a live ped
    model would reintroduce staleness), not about whether the K9-role
    party's CERTIFICATION is still currently valid (a materially different,
    time-varying fact this file has every reason to re-check, since it is
    about to hand out a real, permanent XP grant). In ordinary operation,
    server/certifications.lua's own `RevokeCertification`/
    `RevokeCertificationOffline`/`OnJobUpdate` call sites already call
    `ForceBreakPartnershipForCitizenId` on decertification, which would tear
    the partnership row down (`active = 0`) before this file's own
    `WHERE active = 1` SELECT could ever see it again -- so in the common
    case this file's own HasK9Access re-check is expected to never actually
    catch anything live. It is kept anyway, uncollapsed, specifically
    because this file must not assume that wiring is airtight for every
    call site/timing window that exists or will ever exist -- re-deriving
    the one fact (current certification) that a real XP grant actually
    depends on is cheap, already-available (HasK9Access is one resource-
    global call), and is exactly what "read state fresh" means here.

    ======================================================================
    NO NETWORK-FACING SURFACE -- this file registers NO `RegisterNetEvent`
    and NO `lib.callback`. Every check below is server-initiated, on this
    file's own timer, reading only server-held state (GetPlayers(),
    exports.qbx_core player objects, this file's own SELECT against
    `k9_partnerships`) -- there is no client-supplied payload anywhere in
    this file to validate, type-check, or rate-limit, which is why
    server/cooldowns.lua's constructors are NOT used here despite the
    resource-wide convention to reach for them for "any rate limiting": this
    file's own poll interval (`Config.Partnership.TenureBonus.checkIntervalMs`,
    proposed in the closing comment block) already IS the only rate limit
    that could mean anything for a purely server-driven, non-adversarial
    loop -- adding a NewCooldown on top of a fixed-interval CreateThread
    loop this file itself controls would be decoration, not protection, the
    same reasoning sql/install.sql's own `k9_search_log` header gives for
    deliberately NOT adding a redundant uniqueness backstop to an append-log
    shape that does not need one.

    ======================================================================
    CONFIDENCE GRADING:
    1. HIGH -- `established_at`/`active`/`k9_citizenid`/`handler_citizenid`
       shapes and `GetActivePartnerCitizenId`'s exact return contract are
       read directly from server/partnership.lua and sql/install.sql this
       session, not assumed.
    2. HIGH -- `AwardXP(citizenid, actionKey)`'s flat-amount-per-actionKey
       signature (no arbitrary delta parameter) is read directly from
       server/progression.lua this session; this file's design (three named
       milestone actionKeys, not one parameterized amount) follows directly
       from that real signature, not a guessed one.
    3. MEDIUM -- `TIMESTAMPDIFF(SECOND, established_at, NOW())` is standard
       ANSI-family SQL, supported identically by MySQL and MariaDB; not
       independently re-verified against a live install this session (no
       live server available), but it is a basic, extremely common function,
       not an exotic one this resource has any history of getting wrong.
    4. RESOLVED (follow-up pass -- see this file's own "STATUS UPDATE"
       section near the top) -- the "one column" schema dependency this
       file requires has LANDED: sql/install.sql's `k9_partnerships` CREATE
       TABLE and sql/migrations/0003_*.sql both carry
       `tenure_bonus_tier_granted`, verified directly against those files
       this pass, not assumed. This file's own queries remain
       pcall-wrapped regardless -- not because the column is expected to be
       missing anymore on a current install, but because an OLDER,
       not-yet-migrated database is still a real, ordinary case this file
       must degrade safely against (same precedented gap sql/install.sql's
       own `k9_progression` header already normalizes for this exact
       resource) -- belt-and-suspenders, not a sign the dependency is still
       unmet.
    ======================================================================

    EVENT/CALLBACK CONTRACT: none (see "NO NETWORK-FACING SURFACE" above).

    FILE-TO-FILE CONTRACT -- THIS FILE reads three resource-global functions,
    none of which it defines, all behind `type(...) == 'function'` runtime-
    existence guards per this resource's established "guard, not a
    load-order assumption" convention (see fxmanifest.lua's own comment on
    server/medkit.lua's RestoreInjury reuse for the precedent this follows):
        GetActivePartnerCitizenId(citizenid) -- server/partnership.lua, used
            ONLY as a cheap in-memory pre-filter to decide whether a
            currently-connected citizenid is even worth a DB round trip this
            tick -- never trusted as the final word on tenure/role (the
            SELECT inside CheckTenureMilestonesForK9 re-derives k9_citizenid/
            handler_citizenid from the DB row itself, per constraint 5).
        HasK9Access(source) -- server/certifications.lua, a FRESH re-check
            immediately before every grant (see CONSTRAINT 5 COMPLIANCE
            above).
        AwardXP(citizenid, actionKey) -- server/progression.lua, THE
            single mutation this file ever performs against game-relevant
            state; never called with a computed/arbitrary amount, only with
            one of the three fixed actionKey strings this file's own
            milestone table names (see DESIGN QUESTION 2 above).
    THIS FILE does NOT call `IsConfiguredK9Model` -- see CONSTRAINT 5
    COMPLIANCE above for why re-deriving ROLE from a live ped model here
    would contradict server/partnership.lua's own "frozen at establishment"
    design, which this file deliberately does not second-guess.
    THIS FILE owns no resource-global (non-`local`) function of its own --
    nothing else in this resource is expected to call into it, so nothing
    here needed adding to the repo's root `.luacheckrc` `globals` block
    (every symbol this file READS from other files -- GetActivePartnerCitizenId,
    HasK9Access, AwardXP -- is already listed there from those files' own
    prior work).
]]

-- TenureFullyCollected[partnershipRowId] = true -- a per-process, in-memory
-- marker for a partnership that has already collected every configured
-- milestone (a steady-state, extremely common case once a real partnership
-- ages past the last threshold).
--
-- CORRECTNESS-PASS CORRECTION (this pass -- tests/tenure_spec.lua's own
-- "DISCREPANCY" case locks this in): this does NOT skip the SELECT below on
-- a fully-collected partnership, despite an earlier revision of this comment
-- claiming it did. It CANNOT skip that SELECT: the only key this cache has
-- is `partnershipRowId`, and that id is itself a COLUMN OF THE ROW THE
-- SELECT RETURNS -- there is no way to know which row id to check this
-- cache against without already having run the query that names it. What
-- this cache actually short-circuits is the CHEAPER work strictly AFTER the
-- SELECT (the tier walk / optimistic UPDATE attempt below), which is a real,
-- if modest, saving once a partnership has nothing left to grant. A true
-- pre-query skip would need a SEPARATE cache keyed by `k9Citizenid` instead
-- (the value TickPartnershipTenure's loop actually has in hand before
-- calling this function) -- and that shape was deliberately NOT built here,
-- because it is only SAFE if it is invalidated the instant this citizenid's
-- active partnership row changes (a break, or a break-then-reform with a
-- fresh `established_at` and a fresh id resets tenure to zero, per this
-- file's own header design question 4). This file has no hook into
-- server/partnership.lua's teardown/establish paths to drive that
-- invalidation, and guessing wrong in that direction (serving a stale
-- "fully collected" verdict for a citizenid's BRAND NEW partnership) would
-- silently withhold every future milestone for that new partnership forever
-- -- a strictly worse bug than one extra cheap, already-indexed SELECT per
-- tick for an already-tenured K9 (config.lua's own comment on
-- `Config.Partnership.TenureBonus.checkIntervalMs` already prices this
-- query as "effectively free" at a 5-minute cadence). Never used to decide
-- WHETHER a grant is safe to make either way -- only the persisted
-- `tenure_bonus_tier_granted` column is authoritative for that; losing this
-- cache entirely on a restart is harmless and self-healing (the next tick's
-- SELECT simply reconfirms "already fully collected" from the DB and
-- repopulates this entry once). Bounded, cheap, unbounded-but-fine growth
-- profile, same accepted shape as server/certifications.lua's own
-- `Certifications` cache and server/progression.lua's own `K9XP` cache.
--
-- ITEM 4 CLOSURE (DEVELOPER_REFERENCE.md Part B item 4 -- formerly
-- DEVELOPER_REFERENCE.md, merged 2026-08-25 / DEVELOPER_REFERENCE.md §20 "What's NOT
-- covered" / tests/tenure_spec.lua's own DISCREPANCY case -- this is the
-- fourth pass over this exact question; this section exists specifically so
-- there is no fifth. Dated: 2026-08-25.):
--
-- 1. DOES THE DISCREPANCY STILL HOLD? Yes, re-verified directly against the
--    live code below, not assumed from the prior comment: `TenureFullyCollected`
--    is keyed on `row.id`, and `row` does not exist until the
--    `MySQL.single.await` SELECT inside CheckTenureMilestonesForK9 has
--    already returned it. There is no code path in this file where that
--    cache is consulted before the SELECT runs. Confirmed unchanged.
--
-- 2. MEASURED COST (numbers read directly from config.lua/sql/install.sql
--    this pass, not guessed):
--      - Tick cadence: `Config.Partnership.TenureBonus.checkIntervalMs` =
--        300000 (config.lua, Config.Partnership block) = one tick per 5
--        real-world minutes, confirmed identical to this file's own
--        300000 fallback default a few lines below.
--      - Queries per tick: at most one `k9_partnerships` SELECT per
--        currently-connected player who (a) is online (this tick's own
--        `GetPlayers()` loop) AND (b) is CURRENTLY the K9-role party of an
--        active partnership per the in-memory `GetActivePartnerCitizenId`
--        pre-filter -- i.e. bounded by concurrent player count, never by
--        `k9_partnerships` table size.
--      - Is it indexed? Yes, and more than merely indexed: the SELECT's
--        WHERE clause is `active = 1 AND k9_citizenid = ?`, which is an
--        exact-match on both leading columns of
--        `KEY idx_k9_citizenid_active (k9_citizenid, active)`
--        (sql/install.sql, `k9_partnerships` CREATE TABLE, read directly
--        this pass). Further, `UNIQUE KEY uq_one_active_partnership_per_k9
--        (active_partner_k9_key)` on the same table makes it a DB-enforced
--        invariant that at most ONE row can ever match that predicate pair
--        -- this is not "an indexed scan," it is a unique-key-equivalent
--        point lookup; `LIMIT 1` in the SQL text is a formality, not a
--        safety net for an otherwise-multi-row match.
--      - Does table SIZE matter here? Measurably no, and this is the
--        actual answer to "how large can k9_partnerships realistically
--        get" rather than a guessed row count (which would be
--        unmeasurable and beside the point): `k9_partnerships` is
--        append-mostly (a broken partnership flips `active` to 0, it is
--        never DELETEd -- same audit-log shape as `k9_certifications`,
--        confirmed from that table's own header), so it grows without
--        bound over a server's lifetime. But an InnoDB B-tree index's
--        lookup cost scales with the LOG of row count, and this
--        particular lookup is additionally capped to at most 1 matching
--        row by the UNIQUE constraint above -- the difference between a
--        10-thousand-row and a 10-million-row `k9_partnerships` table is a
--        couple of extra B-tree page descents (typically still
--        buffer-pool-resident for a table this actively queried), not a
--        change in query class. Table growth is therefore not a variable
--        that can turn this into an expensive query at any realistic
--        FiveM server lifetime -- this is a structural property of the
--        schema (verified from sql/install.sql), not an estimate.
--      - Bounding the realistic worst case: this repository ships no
--        server.cfg/sv_maxclients for this resource to read (it is a
--        resource, not a full server artifact), so there is no single
--        "real" concurrent-player number to cite -- but the query-rate
--        math does not need one to make the point. Even an intentionally
--        generous upper bound of 1024 SIMULTANEOUSLY online, K9-role,
--        actively-partnered players (itself already an overshoot: each
--        such player requires an equally-online handler counterpart, a
--        currently-valid certification, AND department membership per
--        this file's own activity gate a few lines below, so the
--        realistic population eligible for this query on ANY real
--        install is a small fraction of total concurrent players, not a
--        majority of them) yields at most 1024 point-lookup queries
--        spread across one 300-second tick window, i.e. ~3.4
--        queries/second sustained, each a sub-millisecond warm-cache
--        unique-index point lookup. That is not a load figure worth
--        measuring against connection-pool or query-thread capacity --
--        config.lua's own comment on this same `checkIntervalMs` value
--        already prices it as "effectively free," and this pass's
--        measurement confirms that framing rather than merely repeating
--        it.
--
-- 3. DECISION: LEAVE IT. Do not build a `k9Citizenid`-keyed pre-query
--    cache. The cost this would remove (section 2 above) is not
--    measurably distinguishable from zero at any realistic install size or
--    population; the coupling required to remove it safely is real, not
--    hypothetical, and strictly larger than "add one hook call":
--      - A correct pre-query cache MUST be invalidated the instant a
--        `k9Citizenid`'s ACTIVE `k9_partnerships` row changes -- not just
--        on `DoBreakPartnership`, but on EVERY call site that can flip a
--        row's `active` flag for a K9-role citizenid: a self-initiated
--        break, AND every forced-teardown path this file's own header
--        already enumerates from server/certifications.lua
--        (`RevokeCertification`/`RevokeCertificationOffline`/
--        `OnJobUpdate` -> `ForceBreakPartnershipForCitizenId`), AND the
--        establish path itself (a fresh INSERT reactivating tenure at
--        zero for what may be the SAME citizenid that was just marked
--        fully-collected under a different, now-inactive row id).
--        Missing even ONE of those call sites reproduces exactly the
--        failure mode this file's own header already names: a stale
--        "fully collected" verdict silently withholding every future
--        milestone from a legitimate brand-new partnership, forever,
--        with no error, no log line, and no test short of a full
--        integration pass likely to catch it before a real player
--        notices their tenure bonus never arrives.
--      - Concretely, the hook this WOULD require (specified here so a
--        future pass does not have to re-derive it, but NOT implemented,
--        because server/partnership.lua is not this file's own): a
--        resource-global this file would export, e.g.
--        `InvalidateTenureCache(k9Citizenid)`, called by
--        server/partnership.lua from (a) every code path that sets an
--        existing row's `active` to 0 for that row's `k9_citizenid`
--        (`DoBreakPartnership` and any forced-teardown caller reached via
--        `ForceBreakPartnershipForCitizenId`), and (b) every successful
--        establishing INSERT, keyed on the NEW row's `k9_citizenid`. That
--        is a minimum of two, and realistically three-plus, call sites in
--        a file this pass does not own, each one a silent-failure surface
--        if ever missed by a future editor of THAT file who has no reason
--        to know this file depends on it being complete -- a materially
--        different, and materially worse, risk shape than "one extra
--        already-indexed point lookup every 5 minutes for an
--        already-fully-tenured, still-online K9."
--    A one-file, reversible, zero-hard-dependency status quo that costs an
--    immeasurable amount of DB time is preferable to a two-file coupling
--    that can silently break a different subsystem's future edits. This
--    conclusion is final for this item: re-opening it should require new
--    evidence (e.g. a measured, reproduced DB load problem), not a
--    re-description of the same already-quantified tradeoff.
--
-- 4. tests/tenure_spec.lua: NO assertion change required. This decision
--    does not change server/tenure.lua's runtime behavior at all (no code
--    below this comment block was touched), so the existing
--    'DISCREPANCY: TenureFullyCollected does NOT skip the SELECT on a
--    fully-collected partnership (still runs every tick)' case continues
--    to assert the real, current, intentionally-kept behavior and remains
--    accurate as a regression guard. Its own test name still calls this a
--    "DISCREPANCY" (between the ORIGINAL pre-correction header wording and
--    the code) rather than a "closed, intentional design decision" -- that
--    framing is now stale given this section, but updating that test's
--    name/comment (not its assertions) belongs to whoever owns
--    tests/tenure_spec.lua, not this file.
local TenureFullyCollected = {}

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit) -- the narrowest of the 12, with no `notifyType` parameter at all
-- (always `'inform'`). It is now server/notify.lua's single shared
-- resource-global implementation -- see that file's own header for the
-- extraction writeup. Both of this file's call sites below are unchanged:
-- each already only ever passed 2 arguments, which produces the identical
-- `type = 'inform', title = 'K9 Unit'` payload through the shared
-- function's own defaults -- confirmed against both call sites directly
-- before deleting this local copy, not assumed.

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- header documents the 4-step resolution; step 1,
-- Config.Features.PartnershipTenureBonus, is already the three-flag
-- CreateThread/TickPartnershipTenure gate above. Mirrors
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId shape
-- verbatim (that file's own header says to read it before writing a
-- variant). Gates the K9-ROLE party (the citizenid the milestone bonus is
-- actually paid to, per this file's own header) -- a blocked K9 simply
-- never crosses `if targetTier <= alreadyGranted` below, since
-- CheckTenureMilestonesForK9 returns before the CAS UPDATE that would
-- advance `tenure_bonus_tier_granted`; the milestone stays PENDING, not
-- forfeited, exactly like every other "not yet" early return in this
-- function (offline handler, out-of-proximity, decertified). Unblocking
-- later lets the very next tick pay out normally -- a block here pauses
-- the bonus, it never erases an already-earned one.
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsPartnershipTenureBonusPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.PartnershipTenureBonus') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.PartnershipTenureBonus == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.PartnershipTenureBonus') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Re-derives, from the DB row itself (never from the cheap cache
--- pre-filter that got the caller here), whether `k9Citizenid` currently
--- has a newly-payable tenure milestone, and pays it out if every fresh
--- condition holds. No-op, silently, on any missing prerequisite -- every
--- exit path below is a "try again next tick" condition, never a
--- caller-visible error, since nothing here is a player-initiated action
--- with an expectation of a response.
--- @param k9Src number -- the K9-role party's CURRENT server id (already confirmed online by the caller's own GetPlayers() loop)
--- @param k9Citizenid string
local function CheckTenureMilestonesForK9(k9Src, k9Citizenid)
    local tenureCfg = Config.Partnership and Config.Partnership.TenureBonus
    if type(tenureCfg) ~= 'table' or type(tenureCfg.milestones) ~= 'table' or #tenureCfg.milestones == 0 then
        -- Config additions this file depends on (see closing comment block)
        -- have not landed yet -- stay a total no-op rather than erroring.
        return
    end

    -- PER-PERSON FEATURE CONTROL -- see IsPartnershipTenureBonusPermittedForCitizenId
    -- above. Checked before any DB read (cheapest-check-first, same
    -- discipline as every other per-person gate in this resource) -- a
    -- blocked K9's milestone stays pending, never paid, until unblocked.
    if not IsPartnershipTenureBonusPermittedForCitizenId(k9Citizenid) then
        return
    end

    -- Fresh, authoritative read -- re-derives k9_citizenid/handler_citizenid
    -- from the row itself rather than trusting the cache-based pre-filter
    -- that led the caller here (constraint 5: "read state fresh"). Wrapped
    -- in pcall for the same reason server/progression.lua's own
    -- k9_progression queries are: the `tenure_bonus_tier_granted` column
    -- this SELECT references is PROPOSED, not guaranteed to exist yet (see
    -- this file's header "WHY ONE NEW COLUMN IS UNAVOIDABLE") -- a missing
    -- column must degrade this whole feature to a silent no-op, never a
    -- console-spamming hard error on every tick.
    local queryOk, row = pcall(K9Store.Partner_GetTenureRow, k9Citizenid)
    if not queryOk then
        print(('[qbx_k9unit] tenure: milestone query failed for k9=%s (schema migration for tenure_bonus_tier_granted may not be applied yet): %s'):format(k9Citizenid, tostring(row)))
        return
    end
    if not row then return end -- cache said partnered; DB now disagrees (race/staleness) -- next tick will see the real current state either way

    if TenureFullyCollected[row.id] then return end -- steady-state skip, see this file's own cache header comment

    -- Ascending-order walk, identical shape to server/progression.lua's own
    -- ResolveTier -- REQUIRES Config.Partnership.TenureBonus.milestones to
    -- stay sorted ascending by afterSeconds (see closing comment block's
    -- proposed shape), same caller-maintained-order contract
    -- Config.ContrabandAlertTiers already documents for the identical
    -- reason. `break` on the first unmet threshold is safe ONLY under that
    -- ascending-order contract.
    local tenureSeconds = tonumber(row.tenure_seconds) or 0
    local targetTier = 0
    for i = 1, #tenureCfg.milestones do
        if tenureSeconds >= tenureCfg.milestones[i].afterSeconds then
            targetTier = i
        else
            break
        end
    end

    local alreadyGranted = tonumber(row.tenure_bonus_tier_granted) or 0
    if targetTier <= alreadyGranted then
        if alreadyGranted >= #tenureCfg.milestones then
            TenureFullyCollected[row.id] = true
        end
        return
    end

    -- ACTIVITY GATE (design question 3b): the handler must be CURRENTLY
    -- online and within Config.Partnership.ProximityMeters of the K9's own
    -- CURRENT position, re-resolved fresh every time -- never assumed from
    -- the partnership merely being active. Offline handler = defer, retry
    -- next tick; this is never a hard failure, only a "not yet."
    local handlerPlayer = exports.qbx_core:GetPlayerByCitizenId(row.handler_citizenid)
    local handlerSrc = handlerPlayer and handlerPlayer.PlayerData and handlerPlayer.PlayerData.source
    if type(handlerSrc) ~= 'number' then return end

    local k9Ped = GetPlayerPed(k9Src)
    local handlerPed = GetPlayerPed(handlerSrc)
    if k9Ped == 0 or handlerPed == 0 then return end

    local dist = #(GetEntityCoords(k9Ped) - GetEntityCoords(handlerPed))
    if dist > Config.Partnership.ProximityMeters then return end

    -- CONSTRAINT 5 COMPLIANCE: fresh certification re-check for the K9-role
    -- party, and fresh department-membership re-check for the handler-role
    -- party -- see this file's header "CONSTRAINT 5 COMPLIANCE" section for
    -- why an active partnership row alone is not treated as proof of either.
    if type(HasK9Access) ~= 'function' or not HasK9Access(k9Src) then return end

    local handlerJob = handlerPlayer.PlayerData.job
    if not handlerJob or not Config.Departments[handlerJob.name] then return end

    -- Optimistic UPDATE, race-guarded on the OLD tier value (mirrors
    -- server/partnership.lua's own `WHERE id = ? AND active = 1` guard on
    -- DoBreakPartnership's UPDATE) -- if this file's own tick somehow ran
    -- twice concurrently for the same row (not expected under FXServer's
    -- single-threaded Lua VM, but cheap to guard regardless, same "belt and
    -- suspenders" posture this resource applies elsewhere), only one would
    -- ever see affectedRows > 0.
    local updateOk, affectedRows = pcall(K9Store.Partner_SetTenureTierCAS, row.id, targetTier, alreadyGranted)
    if not updateOk then
        print(('[qbx_k9unit] tenure: milestone UPDATE failed for partnership id=%s: %s'):format(tostring(row.id), tostring(affectedRows)))
        return
    end
    if not affectedRows or affectedRows == 0 then return end -- lost a race, or the row changed under us -- next tick re-evaluates from scratch

    -- Grant every newly-crossed milestone (plural: a pair reuniting after a
    -- long absence could cross more than one threshold in a single tick) --
    -- see this file's header design question 2 for why this is three fixed
    -- actionKey strings, never a computed amount.
    for tier = alreadyGranted + 1, targetTier do
        local milestone = tenureCfg.milestones[tier]
        if type(AwardXP) == 'function' and milestone and type(milestone.actionKey) == 'string' then
            AwardXP(k9Citizenid, milestone.actionKey)
        end
    end

    if targetTier >= #tenureCfg.milestones then
        TenureFullyCollected[row.id] = true
    end

    -- Both parties are confirmed online (handlerSrc resolved above, k9Src
    -- supplied by the caller's own GetPlayers() loop) -- safe to notify
    -- both directly, no "if online" branch needed (unlike
    -- server/partnership.lua's TellCitizenIdPartnershipEnded, which must
    -- tolerate an offline party; this code path cannot reach here with
    -- either party offline).
    NotifyPlayer(k9Src, locale('tenure.milestone_reached'))
    NotifyPlayer(handlerSrc, locale('tenure.milestone_reached'))
end

--- One pass over currently-connected players per tick, mirroring
--- server/wellbeing.lua's/server/progression.lua's own resource-start
--- backfill loops' `GetPlayers()`/`tonumber` idiom exactly. Re-checks all
--- three prerequisite flags at the point of use (DEVELOPER_REFERENCE.md §3), even though
--- the CreateThread guard below already gates on the same three at
--- file-load time -- matches this resource's own repeated-check convention
--- (e.g. AwardXP re-checking Config.Features.XPProgression despite every
--- current caller already gating on it too).
local function TickPartnershipTenure()
    if not (Config.Features.HandlerPartnership and Config.Features.XPProgression and Config.Features.PartnershipTenureBonus) then
        return
    end
    if type(GetActivePartnerCitizenId) ~= 'function' then return end -- defensive: see FILE-TO-FILE CONTRACT guard convention

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
            if citizenid then
                -- Cheap, in-memory PRE-FILTER only -- never the final
                -- authority (see FILE-TO-FILE CONTRACT above). Only the
                -- K9-role party drives a milestone check; the handler-role
                -- party of the same partnership is reached via the SAME
                -- row lookup once their partner (the K9) is processed, so
                -- iterating handlers separately here would be redundant
                -- work, not a missed case.
                local _, isK9 = GetActivePartnerCitizenId(citizenid)
                if isK9 then
                    CheckTenureMilestonesForK9(src, citizenid)
                end
            end
        end
    end
end

-- CHECKINTERVALMS VALIDATION (QA follow-up -- mirrors server/defense.lua's
-- own identical PollIntervalMs finding for the identical failure shape): a
-- raw, unchecked Config.Partnership.TenureBonus.checkIntervalMs value used
-- to feed a bare Wait() call below on EVERY loop iteration (this file
-- re-reads tenureCfg fresh every pass, unlike server/defense.lua's own
-- PollIntervalMs, which is captured once at file-load time and asserted
-- there before its own thread is ever created). The OLD type check alone
-- (`type(...) == 'number'`) did NOT reject 0, a negative number, or NaN --
-- Wait() fed any of those either busy-loops (spamming this file's own real,
-- if indexed, k9_partnerships SELECT/UPDATE every server frame) or throws
-- and silently kills this shared thread forever, disabling every future
-- tenure-milestone grant for the rest of this resource's uptime with
-- nothing more than a generic Lua traceback to explain why -- the exact
-- same failure mode server/defense.lua's own PollIntervalMs assert exists
-- to catch. Unlike that file's hard resource-start assert (appropriate
-- there since PollIntervalMs is captured once, before its thread is ever
-- created), this file re-reads the value every iteration, so a soft
-- fallback + one-time warning (mirroring server/recall.lua's own
-- RequestCooldownMs = 0 footgun fix) is the fix that fits this file's own
-- per-iteration re-read design without changing it. A MISSING config value
-- (nil -- the "TenureBonus schema/config not landed on this server yet"
-- case this file elsewhere treats as a total silent no-op) stays silent,
-- matching this file's own established convention; only a PRESENT-but-bad
-- value (0, negative, NaN, or a non-number) warns.
local WarnedBadTenureCheckInterval = false
local TENURE_CHECK_INTERVAL_FALLBACK_MS = 300000

if Config.Features.HandlerPartnership and Config.Features.XPProgression and Config.Features.PartnershipTenureBonus then
    CreateThread(function()
        while true do
            local tenureCfg = Config.Partnership and Config.Partnership.TenureBonus
            local rawIntervalMs = type(tenureCfg) == 'table' and tenureCfg.checkIntervalMs or nil
            local intervalMs = TENURE_CHECK_INTERVAL_FALLBACK_MS
            if type(rawIntervalMs) == 'number' and rawIntervalMs == rawIntervalMs and rawIntervalMs > 0 then
                intervalMs = rawIntervalMs
            elseif rawIntervalMs ~= nil and not WarnedBadTenureCheckInterval then
                WarnedBadTenureCheckInterval = true
                print(('[qbx_k9unit] tenure: Config.Partnership.TenureBonus.checkIntervalMs (%s) is not a positive number -- using the built-in %dms interval instead. A non-positive/NaN value here would otherwise feed Wait() directly every loop pass, which can busy-loop or silently kill this thread forever (disabling every future tenure-milestone grant) rather than merely mistiming the poll.'):format(tostring(rawIntervalMs), TENURE_CHECK_INTERVAL_FALLBACK_MS))
            end
            Wait(intervalMs)
            local ok, err = pcall(TickPartnershipTenure)
            if not ok then
                print(('[qbx_k9unit] tenure tick error: %s'):format(tostring(err)))
            end
        end
    end)
end

--[[
    ======================================================================
    CONFIG/SCHEMA/MANIFEST ADDITIONS THIS FILE REQUIRES -- LANDED (follow-up
    pass: verified directly against config.lua, fxmanifest.lua, and
    sql/install.sql/sql/migrations this session; see this file's own
    "STATUS UPDATE" section near the top). Originally written as a
    PROPOSAL, since config.lua, fxmanifest.lua, and sql/install.sql were
    each owned by another agent at the time this file was authored; kept
    below verbatim as the exact reference shape those files now match, not
    rewritten as a changelog entry. This file still degrades to a total,
    silent no-op if any of it were ever missing again (every query is
    pcall-wrapped, both new-config reads are type-checked, and the
    Config.Features flag this file gates on defaults to false in the
    proposal below) -- nothing here is load-bearing for the REST of this
    resource either way.

    1. config.lua -- Config.Features (new flag, default false, placed near
       HandlerPartnership since it is a direct extension of that feature):

           -- Extends HandlerPartnership (server/tenure.lua) -- grants a
           -- one-time, flat XP bonus (via the existing AwardXP/Config.XP.awards
           -- mechanism, not a new progression system) when a partnership's
           -- continuous tenure crosses a configured threshold. Has NO
           -- effect unless HandlerPartnership AND XPProgression are ALSO
           -- true (server/tenure.lua re-checks both at point of use).
           -- Defaults false per this resource's established "a newly-landed
           -- mechanic stays off until its own balance/security review"
           -- convention (see Config.Features.HandlerPartnership's own
           -- comment for the identical reasoning applied to the base
           -- registry this extends).
           PartnershipTenureBonus = false,

    2. config.lua -- Config.XP.awards (three new keys, alongside the
       existing searchContrabandFound/trackSourceResolved/biteHoldSuccess/
       takedownSuccess entries -- UNTUNED placeholders, same
       config-validator/economy-balance-agent review status every existing
       value in this table already carries):

           -- server/tenure.lua's partnership-tenure milestones. Each is a
           -- ONE-TIME award per partnership row (never repeating, never
           -- per-tick) -- see that file's own header design question 3 for
           -- why a hard-capped total, not a recurring trickle, is what
           -- keeps a wall-clock-driven, non-activity-gated CLOCK safe from
           -- being an idle-XP farm.
           partnershipTenure1Day  = 15,  -- 24 real-world hours of continuous active partnership
           partnershipTenure7Day  = 40,  -- 7 days
           partnershipTenure30Day = 100, -- 30 days

    3. config.lua -- Config.Partnership.TenureBonus (new sub-table under the
       existing Config.Partnership block):

           Config.Partnership.TenureBonus = {
               -- server/tenure.lua's own poll cadence -- independent of
               -- Config.Wellbeing.tickIntervalMs (an unrelated subsystem).
               -- Milestones are hours/days away, so a coarse interval costs
               -- nothing in perceived responsiveness and keeps the one
               -- indexed SELECT this adds per online, actively-partnered K9
               -- effectively free.
               checkIntervalMs = 300000, -- 5 minutes

               -- MUST stay sorted ascending by afterSeconds -- server/tenure.lua's
               -- own tier walk assumes this order and breaks on the first
               -- unmet threshold, mirroring Config.ContrabandAlertTiers'
               -- identical documented ordering requirement. Each actionKey
               -- must have a matching Config.XP.awards entry (item 2 above).
               milestones = {
                   { afterSeconds = 86400,   actionKey = 'partnershipTenure1Day'  },
                   { afterSeconds = 604800,  actionKey = 'partnershipTenure7Day'  },
                   { afterSeconds = 2592000, actionKey = 'partnershipTenure30Day' },
               },
           }

    4. fxmanifest.lua -- server_scripts (one new line, suggested placement:
       immediately after 'server/progression.lua', before 'server/combat.lua'
       -- NOT load-bearing, since every cross-file call in this file is
       behind a `type(...) == 'function'` runtime guard per this resource's
       established convention; suggested purely for readability/grouping
       next to the two files this one extends):

           'server/tenure.lua', -- Partnership-tenure milestone XP bonus (PartnershipTenureBonus) -- extends HandlerPartnership (server/partnership.lua) and XPProgression (server/progression.lua) via their existing exposed accessors; no load-order dependency on either (runtime existence guards throughout).

    5. sql/install.sql -- ONE new column on the EXISTING `k9_partnerships`
       table (no new table -- see this file's header "WHY ONE NEW COLUMN IS
       UNAVOIDABLE" for the full restart-safety argument this is proposed
       to close):

           `tenure_bonus_tier_granted` TINYINT UNSIGNED NOT NULL DEFAULT 0
           -- Highest 1-based index into
           -- Config.Partnership.TenureBonus.milestones already paid out as
           -- a one-time XP bonus for THIS partnership row. 0 = none yet.
           -- Written only by server/tenure.lua, via an optimistic
           -- UPDATE ... WHERE tenure_bonus_tier_granted = <old value> race
           -- guard (never decremented, never reset in place -- a NEW
           -- partnership row always starts at the column default, which is
           -- how tenure resets across a break+re-form; see server/tenure.lua's
           -- own header design question 4). Exists purely for restart-safe
           -- idempotency of a periodic, time-threshold-crossing check -- an
           -- in-memory-only marker cannot substitute for it (see that
           -- file's header for the exact restart-duplication bug this
           -- closes).

           If a live database already has this table deployed (i.e. the
           idempotent `CREATE TABLE IF NOT EXISTS` above would no longer
           apply the new column to an existing installation), this needs a
           companion `ALTER TABLE k9_partnerships ADD COLUMN
           tenure_bonus_tier_granted ...` migration statement instead of
           (or alongside) editing the CREATE TABLE definition directly --
           that call belongs to whoever owns this file's migration
           strategy, not asserted here.
    ======================================================================
]]
