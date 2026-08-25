# qbx_k9unit — Documentation Index

**Updated 2026-08-25 (documentation-consolidation pass).** This resource had
grown to roughly eighteen markdown files at its root, several overlapping.
Some have since been merged; this page reflects the result. Each entry
below is one or two lines on **who should open it and why**, and whether
it's still current or mostly historical. If a document is listed as
historical, that means it captured a plan or a snapshot at one point in
time; it may no longer match the code, and `config.lua` plus the actual
`.lua` files are always the final word on what the resource does today.

**The single most important fact not obvious from file names:** as of
2026-08-25, **every one of this resource's 40 `Config.Features` flags is
switched on** (verified directly against `config.lua`). Several documents
below were written when only five were on and have been updated to say so;
`PROJECT_STATUS.md` has the full, current, plain-language picture,
including one setting (`Config.Features.BoneSweepDevTool`) that should not
stay on and is explained there.

## Start here, depending on who you are

| You are... | Open this |
|---|---|
| A player on a server running this | [`PLAYER_GUIDE.md`](PLAYER_GUIDE.md) |
| Standing this resource up on a server for the first time | [`OPERATOR_RUNBOOK.md`](OPERATOR_RUNBOOK.md) |
| A developer who wants config flags, dependencies, and technical detail | [`README.md`](README.md) |
| A server owner or non-technical operator who wants to know where things stand and what needs your decision | [`PROJECT_STATUS.md`](PROJECT_STATUS.md) |

## Player-facing

- **`PLAYER_GUIDE.md`** — how to actually play with this resource: commands,
  world interactions, the radial menu, what's on and what isn't. For
  players, not developers. **Current** — updated 2026-08-25 to reflect that
  every feature now ships on by default, and to correct a stale XP-tier
  table.

## Install, operate, and decide

- **`README.md`** — the main technical reference: dependencies, every
  `Config.Features` flag with its shipped default and what it does,
  exports, and event contracts. For developers and technically-minded
  operators. **Current**, with a prominent correction notice near the top
  explaining that the "ships `false`"/"only five flags are `true`" language
  throughout the rest of the file describes the *shipped* default, not
  today's actual value — it explicitly warns it can go stale quickly since
  several agents edit this resource in parallel.
- **`OPERATOR_RUNBOOK.md`** — step-by-step instructions for installing or
  upgrading this resource on a real server (SQL migration order, first-start
  checklist, the dev-server checks that used to gate enabling certain
  features and are now overdue verification steps instead). For whoever is
  doing the install, not for background reading. **Current** — updated
  2026-08-25; its former "recommended first tranche to enable" section is
  now a "what to verify now that everything is already on" checklist, and
  it leads with the same `BoneSweepDevTool` warning as `PROJECT_STATUS.md`.
- **`PROJECT_STATUS.md`** — **merged, 2026-08-25**, from what used to be two
  separate documents: a whole-project status snapshot, and a list of open
  decisions only a server/product owner can make. They're one document now,
  written in plain language for a non-technical reader (with a short
  glossary at the top), because keeping "what needs your decision" apart
  from "where things stand" was exactly why decisions were getting missed.
  Read this if you're deciding anything about this resource, including the
  two genuinely still-open safety questions (D3, D13) that gate the combat
  features — both are explained without jargon and without softening that
  they're unresolved. **Current** as of its own stated date; treat it as a
  snapshot, not a live dashboard, the same caveat it gives about itself.

## History

- **`WATCHDOG_LOG.md`** — a running, dated, **append-only** log of periodic
  health-check passes (syntax checks, test results, config sanity). Read the
  **most recent entry** for anything close to current status; older entries
  are history showing how things got here. Deliberately left as one
  document and not touched by the 2026-08-25 consolidation pass — an
  append-only log is a different kind of document from the ones that got
  merged, and splitting or combining it with anything else would destroy
  the one thing that makes it useful (a single chronological record).
- **`CHANGELOG.md`** — a dated record of what actually changed in the code
  (and, as of 2026-08-25, in configuration and in this documentation set),
  commit by commit. **Current**, updated as work lands. The best place to
  see what's new since you last looked; if you want a plain-language
  summary instead of a commit history, its own opening line now points you
  to `PROJECT_STATUS.md`.

## Specs and planning documents — historical

These describe **intent at the time they were written**, not a guarantee of
what the code does today. The code (and `README.md`/`PLAYER_GUIDE.md`
summarizing it) always wins if something disagrees. Each of the four now
carries its own "HISTORICAL DESIGN DOCUMENT" banner at the top (added
2026-08-25) so this is clear even to someone who opens the file directly
without going through this index. They were deliberately **not** merged
into one archive file — each covers a distinct, non-overlapping phase, and
this index already tells you which one to open; concatenating four
~1,000-2,000 line documents into one giant file would make each individual
one harder to find, not easier.

- **`SPEC.md`** — the original product spec covering Phase 1 (certification,
  leash, radial menu, vehicle load, bark) and Phase 2 (tracking, search,
  vision, doors). Historical planning document; still useful for the
  reasoning behind Phase 1/2 design choices.
- **`PHASE3_SPEC.md`** — planning document for combat/takedowns/advanced
  agility, written ahead of that code being built. Historical.
- **`PHASE4_SPEC.md`** — planning document for inventory, XP progression,
  and K9 wellbeing, written ahead of that code being built. Historical.
- **`PHASE5_SPEC.md`** — planning document for proximity audio, prop
  attachments, and fetch. Historical.
- **`phase2_notes/`** (14 files) — a folder of research and design notes
  written during development: native-function verification passes, security
  reviews, and design sketches for individual mechanics. This is scratch
  work from building the resource, not a maintained reference — open a
  specific file only if you're chasing the history behind one particular
  mechanic; do not treat anything in this folder as describing current
  behavior without checking the actual code. Reviewed during the
  2026-08-25 consolidation pass and left as-is — it was already clearly
  described as historical scratch, and its 14 files each cover a distinct
  mechanic rather than duplicating each other, so there was nothing to
  merge.

## Ideas and integrations — historical, mostly overtaken

- **`FEATURE_IDEAS.md`** — **merged, 2026-08-25.** Now contains two parts:
  Part A is the original cross-phase feature brainstorm; Part B is what
  used to be the separate `COMPLEMENTARY_FEATURES.md`, a decision-aid about
  which ecosystem integrations (dispatch, MDT, etc.) were worth building.
  Both are ideation only — nothing in either part is approved or built just
  because it's listed, and Part B's own header already notes its top three
  recommendations have since all been built (see `README.md`'s exports/
  admin-command/tenure-bonus sections for the current, shipped state).
  Historical.
- **`COMPLEMENTARY_FEATURES.md`** — **now a redirect stub.** Its content
  lives in `FEATURE_IDEAS.md`'s Part B. Left behind only because the
  tooling used for the merge could not delete a file outright; whoever next
  has shell access should remove it.

## Technical debt

- **`REFACTOR_ROADMAP.md`** — **merged, 2026-08-25.** Now contains two
  parts: Part A is the original, full technical-debt audit (Revision 6);
  Part B is what used to be the separate `REFACTOR_ROADMAP_2.md`, an
  independent second audit written alongside it. Two roadmaps auditing the
  same codebase was one too many documents for a developer to have to find
  and cross-reference by hand — they're combined here, unedited beyond the
  merge itself. For developers doing cleanup work. Historical/point-in-time
  snapshot in each part, not a living document — both parts say this about
  themselves.
- **`REFACTOR_ROADMAP_2.md`** — **now a redirect stub.** Its content lives
  in `REFACTOR_ROADMAP.md`'s Part B. Left behind only because the tooling
  used for the merge could not delete a file outright; whoever next has
  shell access should remove it.

## Audio

- **`html/sounds/CREDITS.md`** — the authoritative, up-to-date record of
  which sound files actually exist in this resource and under what license.
  Check this file, not assumptions, before trusting any claim about bark
  audio working. **Current.** Outside this documentation pass's editable
  scope (owned by whoever maintains `html/`).
- **`AUDIO_SOURCING.md`** — a decision document weighing licensing options
  for bark sound files, and the record of shipping the one sound file this
  resource actually ships today (`bark.ogg`, under an attribution-only
  license). Its own recommendation has since been carried out — see its
  closing note. **This document is a good candidate to fold into
  `html/sounds/CREDITS.md`** (the same licensing decision, split across two
  files); not done as part of this pass because `CREDITS.md` is outside
  this pass's editable scope. Whoever owns that file should do this merge
  next.

## Developer process docs

- **`tests/README.md`** — how to run this resource's automated test suite.
  For developers. **Current.** Outside this documentation pass's editable
  scope.
- **`locales/README.md`** — status of the in-progress translation/text
  migration (which files have been converted to use `locale()` and which
  still have hardcoded English). For developers touching any player-facing
  text. **Current** as a status snapshot; explicitly a partial migration,
  not a finished one. Outside this documentation pass's editable scope.

## This file

- **`DOCS_INDEX.md`** — this page. Updated 2026-08-25 to reflect the merges
  above; re-check the file list at the resource root against this page if
  it's been a while, since this project is edited by multiple agents in
  parallel.
