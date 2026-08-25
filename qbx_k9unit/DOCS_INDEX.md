# qbx_k9unit — Documentation Index

This resource has grown a lot of markdown files. This page is a map, not a
summary — each entry is one or two lines on **who should open it and why**,
and whether it's still current or mostly historical. If a document is
listed as historical, that means it captured a plan or a snapshot at one
point in time; it may no longer match the code, and `config.lua` plus the
actual `.lua` files are always the final word on what the resource does
today.

## Start here, depending on who you are

| You are... | Open this |
|---|---|
| A player on a server running this | [`PLAYER_GUIDE.md`](PLAYER_GUIDE.md) |
| Standing this resource up on a server for the first time | [`OPERATOR_RUNBOOK.md`](OPERATOR_RUNBOOK.md) |
| A developer who wants config flags, dependencies, and technical detail | [`README.md`](README.md) |
| A server owner deciding whether to turn on a not-yet-enabled feature | [`DECISIONS_NEEDED.md`](DECISIONS_NEEDED.md) |

## Player-facing

- **`PLAYER_GUIDE.md`** — how to actually play with this resource: commands,
  world interactions, the radial menu, what's on by default and what isn't.
  For players, not developers. **Current.**

## Install, operate, and decide

- **`README.md`** — the main technical reference: dependencies, every
  `Config.Features` flag with its default and what it does, exports, and
  event contracts. For developers and technically-minded operators.
  **Current**, and the closest thing this resource has to a living
  reference — but it explicitly warns it can go stale quickly since several
  agents edit this resource in parallel.
- **`OPERATOR_RUNBOOK.md`** — step-by-step instructions for installing or
  upgrading this resource on a real server (SQL migration order, first-start
  checklist). For whoever is doing the install, not for background reading.
  **Current.**
- **`DECISIONS_NEEDED.md`** — the open questions only a server/product owner
  can answer (mostly: which not-yet-enabled features are safe to turn on,
  and any tuning numbers that need a real judgment call). Read this if
  you're deciding what to switch on next. **Current** as of its own stated
  date; says plainly that a couple of its items may pick up more detail
  soon.

## Project health and history

- **`PROJECT_STATUS.md`** — a whole-project snapshot written by a reviewer
  at one point in time (what's implemented, what's risky, what's stale).
  Useful for a fast "where do things stand" read, but it says itself that a
  new commit can outdate it within minutes — treat it as a snapshot, not a
  live dashboard.
- **`WATCHDOG_LOG.md`** — a running, dated log of periodic health-check
  passes (syntax checks, test results, config sanity). Read the **most
  recent entry** for anything close to current status; older entries are
  history showing how things got here.
- **`CHANGELOG.md`** — a dated record of what actually changed in the code,
  commit by commit. **Current**, updated as work lands. The best place to
  see what's new since you last looked.

## Specs and planning documents — largely historical

These describe **intent at the time they were written**, not a guarantee of
what the code does today. The code (and `README.md`/`PLAYER_GUIDE.md`
summarizing it) always wins if something disagrees.

- **`SPEC.md`** — the original product spec covering Phase 1 (certification,
  leash, radial menu, vehicle load, bark) and Phase 2 (tracking, search,
  vision, doors). Historical planning document; still useful for the
  reasoning behind Phase 1/2 design choices, but not re-verified against
  current code by this pass.
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
  behavior without checking the actual code.

## Ideas and audits — historical, mostly overtaken

- **`FEATURE_IDEAS.md`** — a brainstorm list of possible future features.
  Explicitly ideation only; nothing in it is approved or built just because
  it's listed. Historical.
- **`COMPLEMENTARY_FEATURES.md`** — a past decision-aid document about which
  ecosystem integrations were worth building. Its own header notes that its
  top recommendations have since all been built. Historical.
- **`REFACTOR_ROADMAP.md`** and **`REFACTOR_ROADMAP_2.md`** — two
  independent technical-debt audits of the codebase (duplicate code,
  cleanup candidates), each a snapshot as of its own pass. For developers
  doing cleanup work. Historical/point-in-time, not living documents.

## Audio

- **`html/sounds/CREDITS.md`** — the authoritative, up-to-date record of
  which sound files actually exist in this resource and under what license.
  Check this file, not assumptions, before trusting any claim about bark
  audio working. **Current.**
- **`AUDIO_SOURCING.md`** — a decision document weighing licensing options
  for bark sound files (attribution-required vs. none found yet). Useful
  background for whoever makes the final call on which audio to ship;
  supplements `html/sounds/CREDITS.md` rather than replacing it.

## Developer process docs

- **`tests/README.md`** — how to run this resource's automated test suite.
  For developers. **Current.**
- **`locales/README.md`** — status of the in-progress translation/text
  migration (which files have been converted to use `locale()` and which
  still have hardcoded English). For developers touching any player-facing
  text. **Current** as a status snapshot; explicitly a partial migration,
  not a finished one.

## This file

- **`DOCS_INDEX.md`** — this page.
