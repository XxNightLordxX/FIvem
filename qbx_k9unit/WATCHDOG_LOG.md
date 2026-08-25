# Removed — see `CHANGELOG.md` and `DEVELOPER_REFERENCE.md` §16

This file was a running, append-only diary of periodic code-health/
regression-check passes. Deleted on 2026-08-25 as pure decision/audit
history — the one thing worth keeping (the per-feature "still not
implemented" status table) had already gone stale multiple times in the
diary itself and is superseded by `README.md`'s own current config
reference and `DEVELOPER_REFERENCE.md` §16 (technical debt roadmap), which
carries forward the still-relevant items.

The single code comment that cited this file by name
(`client/appearance.lua`, describing a "K9 died in a vehicle, respawned
frozen/invisible/attached" bug found by a past watchdog pass) has been
updated to describe the hazard directly rather than pointing at a deleted
diary entry.

This file is intentionally left as a redirect stub rather than removed,
because the tooling used to perform this consolidation pass had no shell/git
access and could not run `git rm`. Whoever next has shell access should
delete this file outright.
