# DECISIONS_NEEDED.md — merged into PROJECT_STATUS.md

This file's entire content — every decision item (D1 through D13),
including the still-open D3 and D13 — has been merged into
`PROJECT_STATUS.md` (docs-consolidation pass, 2026-08-25). "What needs a
human decision" is now part of the same document as "where things stand,"
on purpose: keeping them in separate files was exactly why decisions were
getting missed. Open `PROJECT_STATUS.md` instead; there is nothing left
here.

Several `.lua` files in this codebase still have comments referencing
`DECISIONS_NEEDED.md` by name (e.g. `config.lua`, `server/admin.lua`,
`server/tenure.lua`, `server/exports.lua`, `client/tracking.lua`,
`tests/main_spec.lua`, `fxmanifest.lua`). Those comments were not edited
as part of this pass (code files are outside this pass's scope) — treat
any of them as pointing to `PROJECT_STATUS.md` now, and whoever next
touches one of those files for an unrelated reason should update the
filename in the comment while they're there.

**Why this stub exists instead of the file being gone:** the tooling
available for the pass that did this merge could create, write, and edit
files, but had no way to actually delete a file from disk. This stub is
the closest available substitute — please delete this file for real the
next time someone with shell/filesystem access is doing housekeeping here.
