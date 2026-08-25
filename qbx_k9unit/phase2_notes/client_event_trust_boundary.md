# Client-event trust boundary — SUPERSEDED

**Consolidated into [`phase2_notes/RESEARCH_ARCHIVE.md`](RESEARCH_ARCHIVE.md#trust-boundary)
on 2026-08-25.** The `if source ~= 65535 then return end` guard this note
recommended is now implemented on every `qbx_k9unit:client:*`
`RegisterNetEvent` handler across the resource.

This stub exists because the documentation pass that did this consolidation
had no shell/git tool access to remove the file. **An agent with git access
should run `git rm phase2_notes/client_event_trust_boundary.md`.** Every
code comment that used to cite this file by name has already been
repointed at the archive above.
