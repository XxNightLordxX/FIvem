# Door interaction security review — SUPERSEDED

**Consolidated into [`phase2_notes/RESEARCH_ARCHIVE.md`](RESEARCH_ARCHIVE.md#door-interaction)
on 2026-08-25.** `client/movement.lua`/`server/main.lua` are the
authoritative, current source for how door interaction actually works —
every blocking finding in this review (the unvalidated `doorNetId`, the
missing target-scoped cooldown, the unenforced `nudgeRequiresUnlocked`
flag) is implemented there today.

This stub exists because the documentation pass that did this consolidation
had no shell/git tool access to remove the file. **An agent with git access
should run `git rm phase2_notes/door_interaction_security_review.md`.**
Every code comment that used to cite this file by name has already been
repointed at the archive above.
