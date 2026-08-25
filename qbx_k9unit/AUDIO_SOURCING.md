# AUDIO_SOURCING.md — merged into html/sounds/CREDITS.md

This file's entire content — the sourcing brief, the licence
verification passes, the "AUDIO SHIP PASS" record for `bark.ogg`, the
CC BY-SA share-alike reasoning, and the "don't pursue casually" route
warnings — has been merged into `html/sounds/CREDITS.md` (technical-writer
docs-consolidation pass, 2026-08-25). Every licence name and quoted
finding was carried over exactly as written, not paraphrased. Open
`html/sounds/CREDITS.md` instead; there is nothing left here.

Two corrections made during the merge, both verified directly against
current code, not assumed:

- **`fxmanifest.lua` DOES list `html/sounds/bark.ogg`** in its `files{}`
  block. This file's own "Outstanding follow-up" section previously said
  otherwise — that claim was stale by the time this merge happened, and
  `html/sounds/CREDITS.md`'s copy of that section has been corrected.
- **`growl_ambient.ogg`** (the fifth required sound, used by
  `ProximityAudioFX`, a loop rather than a one-shot) is now listed in
  `html/sounds/CREDITS.md`'s own required-sounds table, which previously
  covered only the four bark files.

**Why this stub exists instead of the file being gone:** the tooling
available for this pass could create, write, and edit files, but had no
way to actually delete a file from disk. This stub is the closest
available substitute — please delete this file for real the next time
someone with shell/filesystem access is doing housekeeping here.
