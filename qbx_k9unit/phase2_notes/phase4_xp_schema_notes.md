# Phase 4 design note: where does K9 XP actually get stored? (`Config.Features.XPProgression`)

Author: db-schema
Date: 2026-08-23
Status: **DESIGN NOTE ONLY — no `sql/install.sql`, `config.lua`, or `.lua`
file is touched by this note.** Written ahead of a detailed Phase 4 spec
pass, the same way `phase2_notes/phase4_hud_early_design.md` and
`phase2_notes/phase4_hud_bridge_design.md` worked ahead of one for the
vitality HUD, and the same way this resource's Phase 2 `phase2_notes/*.md`
pairs worked ahead of SPEC.md §11 before it existed. Placed in
`phase2_notes/` per this resource's established convention: that directory
is the general "working ahead of the detailed spec" notes location
regardless of which phase the content actually belongs to.

**Scope:** answers exactly one question — given `Config.XPTiers` (4 tiers,
thresholds `0`/`500`/`1500`/`3500`, each carrying a `speedMultiplier` and a
`scentRange`) and SPEC.md §6.5's requirement that XP "persists per-handler"
and that crossing a threshold "applies the tier's `speedMultiplier` and
`scentRange` to the dog immediately, without a resource restart" — where
does the accumulated XP number itself live? Nothing else about Phase 4's
XP system (which actions award how much XP, exact award values, whether
XP can be spent/lost) is addressed here; that's SPEC.md §9 item 4's
explicit "needs economy-balance-agent review" territory, not a schema
question.

---

## 1. Recommendation, stated up front

**A dedicated table, `k9_progression`, one row per `citizenid` — not
`qbx_core` metadata.** Same category of decision this resource already
made once, for the same reasons, for `k9_certifications` (SPEC.md §4.3).
The sketch is in §4 below.

---

## 2. Is XP a certification or a `k9certified` mirror? It's a certification.

The task framing asks the right contrast question, so answer it directly
rather than asserting the conclusion: **XP is real, persistent,
capability-adjacent state — structurally a certification, not a cosmetic
mirror.**

The test this codebase already established for that distinction (SPEC.md
§4.3, restated in `server/certifications.lua`'s own comments on
`metadata.k9certified`): a DB table is the *authorization-relevant* source
of truth; `qbx_core` metadata is written **only** as a read-only display
mirror, and the codebase is explicit that it is "never read by any
server-side authorization check." That line is exactly where XP fails to
qualify as "just a mirror":

- SPEC.md §6.5 is explicit that crossing an XP threshold **applies a real
  mechanical effect** — `speedMultiplier` and `scentRange` — "immediately,
  without a resource restart." `scentRange` in particular isn't a HUD
  number; per `Config.Tracking.Scent.maxRange` and §11.5's tracking logic,
  a K9's effective search range is exactly the kind of value
  `server/search.lua`/`server/tracking.lua` would need to read and enforce
  server-side (the same "never trust a client-reported value" posture
  already applied to ped model in §4.5 and ordinary K9 access in §4.1)
  — a modified client claiming "I'm Elite tier, give me 10.0m scent range
  and +15% speed" is a real speedhack/detection-range exploit if the
  server ever takes that claim at face value instead of computing the
  tier itself from a value it trusts.
- Contrast with `k9certified`: that flag is written purely so a client can
  render its own "K9 Certified" badge. Nothing downstream ever
  recomputes gameplay behavior from it. XP fails that test the moment
  §6.5 requires a tier crossing to change actual movement speed and
  detection range — those are mechanical, not decorative.
- This is also exactly the reasoning `k9_search_log`'s own header used to
  decide a *different* question (log the search or not) — worth
  contrasting explicitly since the task asked for it:
  - `k9_search_log` exists for **accountability/dispute-resolution**: no
    future decision ever re-reads a past search row to authorize
    anything; the row's only job is to let an admin answer "did this K9
    unit actually search my vehicle" after the fact, because nothing else
    in the system leaves a trace of that event. That's a *purely
    historical* persistence rationale.
  - `k9_certifications` exists for a *different* reason: its active row
    **is** the access-control mechanism — current state that must survive
    a restart, be queried on every relevant check, and be modifiable even
    while the subject is offline.
  - XP's persistence need is the **second** kind, not the first. The
    accumulated XP total is live state a gameplay system (movement speed,
    scent range) reads and applies going forward, not a closed historical
    record being consulted for a dispute. That makes it structurally a
    `k9_certifications`-shaped problem, not a `k9_search_log`-shaped one
    — although §6 below flags that an *optional* `k9_search_log`-style
    award-history table is still worth a separate, explicit decision later,
    for a genuinely different reason (anti-cheat audit trail).

## 3. Why a table beats metadata here specifically (not just "convention")

Restated in XP's own terms, mirroring the three concrete reasons SPEC.md
§4.3 gave for `k9_certifications` over metadata — each one applies to XP
too, not just by analogy:

1. **Offline correction must work.** An admin/GM needs to be able to
   correct an exploited/duped XP total (or manually award a "shift bonus")
   for a citizenid who is not currently online, the same way §4.3 requires
   `/k9decertifyoffline` to work against a disconnected target. Doing that
   against `qbx_core` metadata means loading and rewriting another
   player's offline data out of band — the exact fragility SPEC.md §4.3
   already rejected once for this resource.
2. **Atomic accumulation, not read-modify-write.** XP awards fire from
   multiple independent gameplay events (successful search, successful
   takedown, etc., per §6.5) that can complete in close succession. A real
   table supports a single atomic
   `INSERT ... ON DUPLICATE KEY UPDATE xp = xp + ?` (§4 below) with no
   read-then-write race window. Reproducing that safely against a
   Lua-side metadata read/increment/write pattern is exactly the kind of
   check-then-act race `k9_certifications`' own `uq_one_active_cert_per_job`
   unique index was added to close for grants — same failure shape,
   different table.
3. **Admin/ops queryability without scanning every player's JSON blob.**
   SPEC.md §4.3's own phrasing: a table "trivially supports 'list all
   certified handlers in department X'... without scanning every player's
   metadata JSON." The XP equivalent is just as real once this ships:
   "list every K9 currently at Elite tier," "average XP across the
   department," "did anyone's XP jump suspiciously in the last hour" —
   all one indexed query against a table, none of them reasonably done by
   iterating every online-or-not player's metadata.

Cost is the same shape §4.3 already accepted for certifications: one
small table, one migration, cheap relative to the benefit.

## 4. Schema sketch (not added to `sql/install.sql` — Phase 4 isn't scoped yet)

```sql
-- =====================================================================
-- qbx_k9unit :: k9_progression  (Phase 4 — NOT YET IMPLEMENTED, sketch only)
--
-- Source of truth for a K9 character's accumulated XP (Config.XPTiers,
-- SPEC.md §6.5). One row per citizenid — see the OPEN QUESTION below on
-- whether XP should instead be scoped per (citizenid, job) the way
-- k9_certifications is; this sketch assumes NOT, i.e. XP belongs to the
-- K9 character itself and survives a department change, since SPEC.md
-- §6.5 says XP "persists per-handler," not "per-handler-per-department."
--
-- Deliberately NOT an append-only log like k9_search_log: this is a
-- live profile row that gets UPDATEd in place on every XP award (an
-- atomic increment, see the query pattern below), not an audit trail of
-- individual award events. Whether a *separate* append-only
-- k9_xp_log-style table is also worth adding for anti-cheat/dispute
-- auditing is a distinct, deliberately open question — see this note's
-- §6, not decided here.
--
-- No FK to a `players` table, for the identical reason k9_certifications
-- and k9_search_log both declare none (see either table's header comment
-- in sql/install.sql): this resource's migration must not depend on
-- qbx_core's schema existing first, and a player-data reset workflow on
-- another resource's table must never be able to fail this table's
-- constraints. Relational integrity to qbx_core players is enforced at
-- the application layer, same convention as the other two tables.
--
-- xp's tier is intentionally NOT computed in SQL (no generated column
-- the way k9_certifications.active_cert_key is generated): Config.XPTiers
-- is code-side and config-driven, so the tier lookup must be done in Lua
-- by walking Config.XPTiers exactly the way server/search.lua already
-- walks Config.ContrabandAlertTiers (last tier whose threshold is met,
-- ascending order) -- baking the thresholds into a SQL CASE expression
-- here would create a second, driftable copy of the same tier boundaries
-- config.lua already owns, which is the exact anti-pattern
-- Config.SearchContrabandItems' own comment calls out for item weights
-- ("read live... at search time, never duplicated into this config, so
-- there is exactly one source of truth").
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once, matching the convention
-- already used for k9_certifications/k9_search_log above.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_progression` (
  `citizenid`  VARCHAR(50)  NOT NULL,                    -- qbx_core / QBCore citizenid convention, matches every other k9_* table
  `xp`         INT UNSIGNED NOT NULL DEFAULT 0,          -- accumulated total; source of truth for Config.XPTiers lookups. UNSIGNED
                                                          -- guards against a negative value at the type level, but see the OPEN
                                                          -- QUESTION note below on why that's not a substitute for app-layer
                                                          -- clamping if a future "reduce XP" admin path is ever added.
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,  -- last award timestamp, cheap "is this
                                                                                              -- profile stale/abandoned" signal
                                                                                              -- without needing a separate log table
  PRIMARY KEY (`citizenid`)

  -- Optional, NOT added here: `KEY idx_xp (xp)` for a leaderboard-style
  -- "top K9s by XP" admin query. SPEC.md has no such requirement today —
  -- adding an index nothing queries yet is speculative cost for no
  -- confirmed benefit; add it if/when that query is actually built.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**Hot-path read** (on player load / job change / whenever a gameplay
system needs the currently-applicable tier — cached in memory after that,
same pattern `k9_certifications`' `Certifications` table already
establishes in `server/certifications.lua`):
```sql
SELECT xp FROM k9_progression WHERE citizenid = ? LIMIT 1;
-- (no row yet = 0 XP / base tier, same as "no active cert row" = false)
```

**Atomic award** (avoids a read-modify-write race across concurrent XP
sources — successful search, successful takedown, etc., per §6.5):
```sql
INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?)
  ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP;
```
The second parameter is the *delta* being awarded (e.g. a configured
"successful search" XP value), not the new total — `VALUES(xp)` refers to
the just-inserted delta on the `ON DUPLICATE KEY UPDATE` branch, giving a
single-statement atomic increment-or-create with no separate
SELECT-then-UPDATE round trip.

## 5. How this should integrate with the existing cert-cache pattern

Not a schema decision, but worth flagging now so whoever implements Phase
4 doesn't reinvent it independently: `server/certifications.lua` already
establishes the shape this should follow — an in-memory
`Certifications[citizenid]` cache, refreshed on `PlayerLoaded`/grant/
revoke, so `HasK9Access` never hits the DB on the hot path. XP should get
the same treatment (e.g. `K9XP[citizenid] = number`, refreshed on
`PlayerLoaded` and updated in-memory immediately on every award), so that:
- The *gameplay effect* (speed/scent bonus per §6.5's "immediately")
  applies from the in-memory value the instant an award happens, with no
  dependency on DB round-trip latency.
- The DB write (§4's atomic UPSERT) can fire without `.await` — similar
  non-blocking treatment to `k9_search_log`'s INSERT, though for a
  different reason: that one is non-blocking because it's a pure audit
  side-effect nobody waits on; this one can be non-blocking because
  correctness of the *applied* gameplay effect depends only on updating
  the in-memory cache synchronously, not on the DB write completing first
  — the DB row just needs to eventually catch up, for restart-survival.

## 6. Open questions flagged, not resolved here

1. **Per-citizenid or per-(citizenid, job)?** This sketch assumes XP
   belongs to the K9 character itself (one row per citizenid, portable
   across a department change), reading SPEC.md §6.5's "persists
   per-handler" literally rather than assuming it mirrors
   `k9_certifications`' job-scoping. This is a real design fork, not a
   formality: if a K9 player leaves `police` for `sheriff` (triggering
   §4.4's automatic cert revoke on the *old* job), should their
   accumulated training/speed/scent skill reset too, the way their access
   does? A working dog's trained ability plausibly shouldn't vanish on a
   transfer even though its *authorization* does — but this is a product
   call, not a schema one. If the eventual answer is "scope it to the
   job instead," the fix is small (composite `PRIMARY KEY (citizenid,
   job)` instead of `citizenid` alone, mirroring `k9_certifications`'
   `idx_citizen_job_active` shape) — flagged for product-agent/
   team-leader before implementation, not guessed silently.
2. **Does a separate `k9_xp_log` (append-only, `k9_search_log`-shaped)
   also belong in Phase 4?** `k9_progression` alone answers "what is this
   K9's current XP," but not "prove how it got there" — the same
   accountability gap `k9_search_log` was added to close for search
   actions, applied to a currency that's arguably more exploit-sensitive
   (XP directly buys a mechanical speed/detection advantage). This is
   worth an explicit yes/no from whoever writes Phase 4's detailed spec
   (the way `k9_search_log` got an explicit yes from db-schema during
   Phase 2's review, recorded in that table's own header) rather than
   being silently skipped or silently added — not decided in this note.
3. **Negative-XP / admin-correction path.** `xp INT UNSIGNED` prevents a
   negative value from ever being *stored*, but does not prevent an
   application-level bug from attempting `xp - largeValue` and either
   erroring or wrapping, depending on SQL mode. If a future "reduce/reset
   XP" admin command is ever built, it must clamp the delta in Lua before
   issuing the UPDATE (`GREATEST(0, xp - ?)` or an app-side floor), not
   rely on the column type alone to make that safe.

## 7. Where this goes once Phase 4 is actually scoped

This `CREATE TABLE IF NOT EXISTS` block (§4) would be appended to
`qbx_k9unit/sql/install.sql`, directly after the existing `k9_search_log`
block — matching this file's own established convention of one idempotent
install script with multiple `CREATE TABLE IF NOT EXISTS` statements
rather than a separate incremental-migrations directory (there is no
`migrations/` folder in this resource; `sql/install.sql` is the only
schema file and is written to be safely re-run). No `ALTER TABLE` is
needed since this is a wholly new table, not a change to
`k9_certifications` or `k9_search_log`. Not applied now, per this note's
own scope (Phase 4/`Config.Features.XPProgression` is still `false`, no
code reads or writes this table yet).
