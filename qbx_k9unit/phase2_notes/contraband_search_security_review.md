# Contraband search security review — SUPERSEDED

**Consolidated into [`phase2_notes/RESEARCH_ARCHIVE.md`](RESEARCH_ARCHIVE.md#contraband-search)
on 2026-08-25.** `server/search.lua` is the authoritative, current source
for how contraband search actually works — every blocking finding in this
review (distance-filtered broadcast, tier-only broadcast payload, per-target
cooldown, entity-type cross-check) is implemented there today.

This stub exists because the documentation pass that did this consolidation
had no shell/git tool access to remove the file. **An agent with git access
should run `git rm phase2_notes/contraband_search_security_review.md`.**
Every code comment that used to cite this file by name has already been
repointed at the archive above.
