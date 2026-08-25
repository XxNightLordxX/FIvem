# Moved — see `OPERATOR_RUNBOOK.md` §6 and §7

This file's content was merged into `OPERATOR_RUNBOOK.md` on 2026-08-25:
the `k9_setup.sh` single-entry-point workflow and the two-kinds-of-backup
explanation are in §6; uninstalling/rolling back is in §7 (itself merged
from `sql/rollback/README.md`). No code cited this file directly by path,
so nothing else needed updating.

This file is intentionally left as a redirect stub rather than removed,
because the tooling used to perform this consolidation pass had no shell/git
access and could not run `git rm`. Whoever next has shell access should
delete this file outright.
