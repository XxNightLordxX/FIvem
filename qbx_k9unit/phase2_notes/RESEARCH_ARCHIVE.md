# Moved — see `DEVELOPER_REFERENCE.md` §15

This file's content was merged into `DEVELOPER_REFERENCE.md` §15 on
2026-08-25. Every anchor this file used to contain (`#vision`, `#tracking`,
`#scent-source-resolution`, `#door-interaction`, `#contraband-search`,
`#phase-3-combat`, `#handler-partnership`, `#hud-bridge`, `#xp-schema`,
`#phase-5-research`, `#dependencies-and-audio`, `#trust-boundary`) is
unchanged there — only the filename changed. A citation reading
`RESEARCH_ARCHIVE.md#tracking` or `phase2_notes/RESEARCH_ARCHIVE.md#tracking`
now resolves to `DEVELOPER_REFERENCE.md#tracking`, same anchor, same
content. (Fine-grained `§N` sub-references some older comments cite inside
an anchor, e.g. `#tracking §2.4`, predate this archive's own prior
consolidation from 24 files down to 12 topics and were never re-numbered
against that condensed version; the anchor-level topic still resolves
correctly, but the exact sub-paragraph number may not — a pre-existing
imprecision this pass did not introduce and did not attempt to fully
resolve.)

This file is intentionally left as a redirect stub rather than removed,
because the tooling used to perform this consolidation pass had no shell/git
access and could not run `git rm`. Whoever next has shell access should
delete this file (and the now-empty `phase2_notes/` directory, if nothing
else lives in it) outright.
