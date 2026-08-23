# DECISION NEEDED — Handler-partnership link for Phase 3 combat features

Status: **BLOCKING, genuinely unresolved.** No further research pass can
close this on its own — `phase2_notes/phase3_combat_patterns.md` and
`phase2_notes/phase3_combat_natives.md` were both checked for evidence and
neither says anything about how other K9/handler scripts model an ongoing
partnership link, because the surveyed ecosystem is overwhelmingly
handler-commands-NPC-dog architecture, where "who is the handler" is
trivial and definitionally always true. That precedent doesn't transfer to
this codebase's player-plays-the-dog model, so this is a genuine product/
design fork, not a research gap. This is the **one remaining item** out of
PHASE3_SPEC.md's original four cross-cutting design forks (§12.0) — the
other three (PvP-vs-NPC target scope, HandlerDownDefense's "aggressive
state" reading, AgilityAdvanced's obstacle-detection method) were resolved
with evidence-backed decisions in the same pass that produced this
document. This one could not be, and is written up separately rather than
forced, per that pass's own conclusion.

Author: this pass (issue-closer sweep), 2026-08-23. Not a new investigation
— this is a pointer/extraction of PHASE3_SPEC.md §12.0 item 7, §12.5.3, and
§12.7 item 7 into a standalone decision doc, since that material is
currently spread across a 1,600+ line spec document. Read PHASE3_SPEC.md's
own sections for full context; this file exists so a human decision-maker
doesn't have to find them first.

---

## What needs deciding

Two Phase 3 features need to know "who is this K9's handler" at the moment
they trigger, independent of whether a leash happens to be attached right
now:

- **`BiteAndHold`'s Recall actor** — who is allowed to issue the Recall
  command that ends a bite-hold state.
- **`HandlerDownDefense`'s trigger** — whose health dropping below
  `Config.Combat.HandlerDownDefense.handlerHealthThreshold` should notify
  which K9's client.

Both need an answer to "which human officer is *this* K9's handler right
now" that isn't simply "whoever is currently leashed to them," because a
K9 mid-foot-chase is very plausibly **off-leash** at the exact moment a
defense trigger or a Recall would matter most.

## Why this blocks implementation

Per PHASE3_SPEC.md §12.1's dependency ordering:
- **Sub-phase 3b (`BiteAndHold`)** is blocked on this item — it establishes
  the shared hold/incapacitate state and Recall actor every later combat
  feature reuses or mirrors.
- **Sub-phase 3e (`HandlerDownDefense`)** is blocked on this item for the
  same reason, and additionally depends on Phase 2's tracking infra.

`AgilityAdvanced` (3a), `NonLethalTakedown` (3c), and `PropDragging` (3d)
do **not** depend on this item and can proceed independently.

## Option A — Reuse the existing active leash pairing (`LeashPairs`)

The only "who is this K9's handler" link that currently exists anywhere in
this codebase is `server/main.lua`'s `LeashPairs` table, built for the
Phase 1 leash mechanic.

**Pros:**
- Zero new persistent state, zero new schema, zero new registry to keep in
  sync with disconnects/job changes/leash detach.
- Reuses code and a mental model already reviewed and shipped in Phase 1.
- Lower implementation cost — this is genuinely close to "free" relative
  to Option B.

**Cons — a real, disclosed functional limitation, not a hidden one:**
- A K9 deliberately off-leash during a foot chase (the single most
  plausible moment `HandlerDownDefense` would matter) gets **no** defense-
  mode support under this option, because there is no leash pairing to
  read at that moment.
- Ties two conceptually different things together — "is currently leashed"
  (a Phase 1 movement-restriction mechanic) and "is my ongoing combat
  partner" (a Phase 3 concept) — that may want to diverge later (e.g. a
  server that wants partnership to survive a temporary unleash).

## Option B — New persistent "K9 partnership" registry

A dedicated data structure (in-memory, mirroring `LeashPairs`'s shape, or
persisted, mirroring `k9_certifications`) that tracks an ongoing handler/K9
partnership independently of momentary leash state — established once
(e.g. on first leash-together, or via a dedicated "partner up" action) and
surviving detach/re-leash within some scope (session, shift, indefinitely).

**Pros:**
- Solves the off-leash foot-chase gap Option A leaves open.
- Cleanly separates "movement mechanic" (leash) from "ongoing relationship"
  (partnership) as two independent concepts, which may be the more
  future-proof shape if Phase 4/5 ever want to hang more on "who's my
  handler" (e.g. XP sharing, a HUD element, proximity audio).

**Cons:**
- Real new design surface: what establishes a partnership, what ends one
  (job change? logout? explicit action? never, until manually reset?),
  whether it needs persistence across restarts/reconnects, whether it
  needs its own DB table (à la `k9_certifications`) or is fine ephemeral
  (à la `LeashPairs`), and who is authorized to establish/break it.
  None of this has been scoped — it is a **new design pass**, not a
  drop-in replacement for `LeashPairs`.
- Meaningfully more implementation and review cost than Option A.
- No ecosystem precedent surveyed for this shape either (per the Status
  note above), so there's no existing pattern to lean on for the details.

## Default-if-forced

PHASE3_SPEC.md §12.5.3 and §12.7 both name **Option A (reuse `LeashPairs`)
as the lower-cost default if a decision is forced without further design
input** — explicitly *not* the same as this document recommending it. It's
recorded here so whoever picks this up knows a reasonable fallback exists,
not to pre-empt the actual decision.

## What this document is asking for

One of:
1. **An explicit product decision** that Option A's off-leash functional
   gap is an acceptable Phase 3 trade-off (ship 3b/3e on top of
   `LeashPairs`, document the gap in `SPEC.md`/`CHANGELOG.md` the same way
   the `ScentTracking` deferral is documented today).
2. **A scoped design pass** for Option B's partnership registry (a small
   spec addendum covering establish/end conditions, persistence, and
   authorization — comparable in shape to `SPEC.md` §4.3's certification
   schema design, just much smaller) before 3b/3e implementation starts.

Neither this document nor PHASE3_SPEC.md picks between them — see
PHASE3_SPEC.md §12.0 item 7 for the original evidence review that reached
the same conclusion.

## Pointers

- `PHASE3_SPEC.md` §12.0 item 7 — the full evidence review and why it
  can't be resolved from available research.
- `PHASE3_SPEC.md` §12.5.3 — `HandlerDownDefense`'s concrete dependency on
  this decision.
- `PHASE3_SPEC.md` §12.7 item 7 — the quick-reference entry.
- `PHASE3_SPEC.md` §12.1 — sub-phase dependency graph (3b, 3e blocked;
  3a/3c/3d are not).
- `server/main.lua`'s `LeashPairs` — the existing structure Option A would
  reuse as-is.
