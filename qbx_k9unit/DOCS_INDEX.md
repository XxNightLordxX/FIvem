# qbx_k9unit — Documentation Index

**Recreated 2026-08-25 (documentation pass).** `SPEC.md`, `PHASE3_SPEC.md`,
`PHASE4_SPEC.md`, `PHASE5_SPEC.md`, and `CHANGELOG.md` all point here by
name, but this file itself had been deleted from the working tree with no
replacement — every one of those citations was dangling before this pass.
Recreated as a genuine, current map of every document in this resource,
not restored from any prior version (none was available to read). If you
find this file missing or wrong again, that's a real documentation defect —
report it rather than assuming the citing document is wrong instead.

**If you only read three files, read these:**
- `README.md` — the technical reference: install steps, every config
  option, exports, events.
- `OPERATOR_RUNBOOK.md` — plain-language guide for whoever runs the server
  this is installed on.
- `PLAYER_GUIDE.md` — plain-language guide for someone playing a K9
  character in-game.

## Start here, depending on what you're trying to do

| You want to... | Read |
|---|---|
| Install this resource or configure a setting | `README.md`, then `OPERATOR_RUNBOOK.md` |
| Understand what's currently on/off and what needs a human decision | `PROJECT_STATUS.md` |
| See exactly what changed and when, in technical detail | `CHANGELOG.md` |
| Learn how to play a K9 character | `PLAYER_GUIDE.md` |
| Understand *why* a feature was designed the way it was (historical) | `SPEC.md` (Phases 1-2), `PHASE3_SPEC.md`, `PHASE4_SPEC.md`, `PHASE5_SPEC.md` |
| Propose or evaluate a not-yet-built feature | `FEATURE_IDEAS.md` (general backlog) or `K9_IDEAS.md` (features currently being built) |
| Find outstanding technical debt / refactor targets | `REFACTOR_ROADMAP.md` |
| See the history of periodic code-health/regression checks | `WATCHDOG_LOG.md` |
| Add or translate player-facing text | `locales/README.md` |
| Run or extend the automated test suite | `tests/README.md` |
| Uninstall / roll back a database migration | `sql/rollback/README.md` |
| Credit/license the shipped audio files | `html/sounds/CREDITS.md` |
| Read this resource's license terms | `LICENSE.md` |
| Read consolidated Phase 2-5 native/security research | `phase2_notes/RESEARCH_ARCHIVE.md` |

## Every document in this resource, in full

- **`README.md`** — the main technical reference: dependencies, install
  steps, every `config.lua` option documented, every export and event,
  known issues. The default starting point for a developer or integrator.
- **`PLAYER_GUIDE.md`** — plain-language, written for someone playing a K9
  character. No config/code detail.
- **`OPERATOR_RUNBOOK.md`** — plain-language, written for whoever manages
  the server's files (install, convars, what to check after an update).
  No code-level detail beyond what an operator needs.
- **`PROJECT_STATUS.md`** — plain-language snapshot of what's currently
  live, what's risky, and what open questions need a human decision (not
  more code). Merges what used to be a separate `DECISIONS_NEEDED.md`.
  Reflects a specific date — check that date before trusting it.
- **`CHANGELOG.md`** — the full, chronological, technical record of every
  notable change, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
  style. Entries are historical records of what was true and cited at the
  time they were written; older entries are not rewritten when something
  they mention is later renamed or consolidated.
- **`SPEC.md`** — the original design spec (Phases 1-2 in full, plus the
  overall goal/scope/hard-requirements that apply across all phases). A
  **historical design document**: it captures the reasoning as of when it
  was written, not a live description of today's code — `config.lua` and
  the actual `.lua` files always win if the two disagree.
- **`PHASE3_SPEC.md`** — historical, detailed design spec for Phase 3
  (combat, takedowns, advanced agility). Same "historical, code wins"
  caveat as `SPEC.md`. Deliberately kept as a separate file rather than
  folded into `SPEC.md` — see that file's own header for why.
- **`PHASE4_SPEC.md`** — historical, detailed design spec for Phase 4
  (K9 inventory, XP progression, wellbeing). Same caveats as above.
- **`PHASE5_SPEC.md`** — historical, detailed design spec for Phase 5
  (proximity audio, prop attachments, fetch mechanic). Same caveats as
  above.
- **`REFACTOR_ROADMAP.md`** — a live, maintained technical-debt/refactor
  tracking document for developers (Part A: the original full audit;
  Part B: a second, independent audit later merged in). Not written for a
  non-technical reader.
- **`WATCHDOG_LOG.md`** — a running, append-only diary of periodic
  code-health/regression-check passes (syntax/lint baselines, specific
  line-number regression spot-checks, documentation-vs-code drift found
  and fixed). Corrections are layered on top of old entries, never
  rewritten in place — an old entry describing something as "not yet
  built" that has since shipped is corrected by a later, dated entry, not
  by editing the original.
- **`FEATURE_IDEAS.md`** — ideation only, nothing here is approved or
  built just because it's listed. Part A: general cross-phase feature
  brainstorm. Part B: ecosystem-integration ideas (dispatch, MDT, etc.),
  merged in from a separate `COMPLEMENTARY_FEATURES.md`.
- **`K9_IDEAS.md`** — feature ideas that are, or recently were, actively
  being built from as a real spec. Treat this one as closer to a backlog
  of committed work than `FEATURE_IDEAS.md`'s pure brainstorm.
- **`LICENSE.md`** — this resource's license terms. Proprietary; do not
  strip authorship.
- **`phase2_notes/RESEARCH_ARCHIVE.md`** — a consolidated archive of
  Phase 2-5 native-verification/security-review/design research, organized
  by topic with in-page anchors. Replaces 24 previously-separate files in
  that folder; its own "Where each old file went" table maps every old
  filename to where its content now lives (or notes that it was dropped
  as fully superseded by a `.lua` file's own header comment). **A citation
  elsewhere in this resource that still names one of those 24 old
  filenames directly (e.g. in a historical `CHANGELOG.md`/`WATCHDOG_LOG.md`
  entry, or inside a frozen phase-spec document) will not resolve as a
  file path — look it up in that table instead.**
- **`locales/README.md`** — explains this resource's translation system
  (`locales/en.json`, the `locale()` function) and the process for adding
  or translating player-facing text.
- **`tests/README.md`** — explains the automated test suite: how to run
  it, what it covers, how the sandbox works, and its own known limits.
- **`sql/rollback/README.md`** — uninstall/rollback instructions for this
  resource's database migrations.
- **`html/sounds/CREDITS.md`** — attribution and license record for every
  shipped audio file. Legally load-bearing — do not edit or delete it.

## A note on why some of these overlap in subject but aren't merged

Several pairs of documents above cover related ground on purpose, not by
accident — each serves a different reader or a different point in the
resource's life:

- `PROJECT_STATUS.md` (a snapshot, dated, expected to go stale) vs.
  `CHANGELOG.md` (a permanent, chronological record) vs. `README.md` (the
  living technical reference, always describing today's code).
- `SPEC.md`/`PHASE3_SPEC.md`/`PHASE4_SPEC.md`/`PHASE5_SPEC.md` (frozen,
  historical design reasoning) vs. `README.md`/`PROJECT_STATUS.md` (live,
  current-state documentation). The phase specs are not kept up to date on
  purpose — they're a record of the reasoning that produced the code, not
  a second copy of the code's current behavior.
- `FEATURE_IDEAS.md`/`K9_IDEAS.md` (unbuilt ideas) vs. `REFACTOR_ROADMAP.md`
  (debt in code that already exists) vs. `WATCHDOG_LOG.md` (a diary of
  checks already run, not a plan for new work).

If you're about to propose merging or deleting one of the documents above,
check this section and the document's own header first — several past
consolidation passes on this resource have already looked at exactly that
question for the files listed here and left them separate for a stated
reason, not by oversight.
