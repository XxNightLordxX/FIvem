# K9 bark audio — sourcing decision

Author: technology-scout pass, 2026-08-25, jlwood17190665@gmail.com.

This is a decision document, not a link dump: it answers whether attribution-
licensed audio is actually acceptable here, and gives one recommendation.
It supersedes nothing in `html/sounds/CREDITS.md` — that file's 2026-08-25
"LICENCE VERIFICATION PASS" section did real, curl-verified license lookups
(Wikimedia Commons API, OpenGameArt's own license field) that this pass could
not repeat: this session's `WebFetch` was itself blocked (`EGRESS_BLOCKED`)
on `commons.wikimedia.org`, `opengameart.org`, and `freesound.org` when tried
directly, same failure mode CREDITS.md's *first* pass hit before a
Bash/curl-equipped pass got through. This pass has no Bash tool available at
all, so it relies on CREDITS.md's curl-verified findings as the primary
record, cross-checked here with independent `WebSearch` queries (a different
tool, same conclusions — see below), and adds one gap CREDITS.md's own
required-sounds list missed.

## 1. What the code actually needs (verified by grep, not assumed)

`client/audio.lua`'s `SOUND_NAME_TO_FILE_KEY` (lines 217-222) maps three
config-authored sound names to files; `client/main.lua`'s `BARK_SOUND_NAME`
supplies a fourth; and **`client/proximityaudio.lua` supplies a fifth that
CREDITS.md's own required-sounds table does not list**:

| Filename (`html/sounds/`) | Sound-name string in code | Where | Default state | One-shot or loop |
|---|---|---|---|---|
| `bark.ogg` | `'Bark'` (`BARK_SOUND_NAME`, `client/main.lua:202`) | Phase 1 generic bark | **`Config.Features.BasicBarkSounds = true`** (`config.lua:29`) — live today | One-shot |
| `bark_alert.ogg` | `'Bark_Alert'` (`config.lua:964`) | `Config.AdvancedBarkRadial` | Gated: `Config.Features.AdvancedBarkRadial = false` (`config.lua:139`) | One-shot |
| `bark_aggressive.ogg` | `'Bark_Aggressive'` (`config.lua:965`) | same | same, off by default | One-shot |
| `bark_calm.ogg` | `'Bark_Calm'` (`config.lua:966`) | same | same, off by default | One-shot |
| `growl_ambient.ogg` | `'Growl_Ambient'` (`PROXIMITY_SOUND_NAME`, `client/proximityaudio.lua:238`, sourced from `Config.ProximityAudioFX.soundName`, `config.lua:1323`) | Distance-scaled ambient growl | Gated: `Config.Features.ProximityAudioFX = false` (`config.lua:140`) | **`loop = true`** — `client/proximityaudio.lua:277` calls `PlayK9Sound(netId, PROXIMITY_SOUND_NAME, { loop = true })` |

Two corrections to carry forward from CREDITS.md's brief:

- **`growl_ambient.ogg` exists as a real requirement and was omitted from
  CREDITS.md's four-file table.** It's low priority (feature flag defaults
  to `false`, same as the three `Bark_*` variants), but it is not covered by
  any of that document's sourcing leads, which were all single-bark clips.
- **CREDITS.md's blanket duration guidance ("well under 2 seconds each,"
  "not a loop") is correct for the four bark files but wrong for this fifth
  one.** `growl_ambient.ogg` is played with `loop = true`, so it needs a
  seamlessly-loopable ambient clip (a growl/breathing bed, not a single
  bark) — a different sourcing target than "isolated single dog bark"
  entirely, and worth treating as its own search, not a byproduct of
  whatever bark clip gets picked.
- **Only `bark.ogg` blocks any behavior a server operator sees by default.**
  `Config.Features.BasicBarkSounds` is `true` out of the box; `AdvancedBarkRadial`
  and `ProximityAudioFX` are both `false`. The other four files are inert
  until an operator opts into a disabled feature — same "silent by design,
  not broken" posture `config.lua`'s own comments already describe. This
  means the sourcing problem has a genuinely small critical path: one clip.

Format contract, confirmed by reading `html/app.js` directly: `loadSoundBuffer()`
(line 519, fetch at line 524) does `fetch('sounds/' + key + '.ogg')` — the
`.ogg` extension is hard-required by the fetch path itself, not a convention.

## 2. Licence findings per route

I could not independently open `commons.wikimedia.org`, `opengameart.org`,
or `freesound.org` this session (`WebFetch` returned `EGRESS_BLOCKED` for
all three on direct attempts). What follows layers two things: CREDITS.md's
own curl-verified table (dated 2026-08-25, same day, a different pass with
Bash access), and independent `WebSearch` queries I ran this pass, which is
a different tool/mechanism and landed on the same conclusions without
having read CREDITS.md's own text first (I ran the searches after reading
CREDITS.md, but the search results themselves are query-driven public
snippets, not a copy of that file) — treat this as corroboration, not a
fresh independent proof.

| Candidate | Licence | Verified how, and by whom | My cross-check this pass |
|---|---|---|---|
| Wikimedia Commons, `File:Barking of a dog.ogg` and four sibling files | **CC BY-SA 3.0/4.0** (varies by file — see CREDITS.md's table) | CREDITS.md: Commons API `extmetadata.LicenseShortName`, curl, 2026-08-25 | `WebSearch` for `"Barking of a dog.ogg" wikimedia commons license` independently returned "Creative Commons Attribution-Share Alike 3.0 Unported" — matches |
| OpenGameArt, "Dog barking mono" (HaelDB / Brandon Morris) | **OGA-BY 3.0** — *not* CC0, despite the page belonging to a collection literally titled "CC0 Audio" | CREDITS.md: the asset page's own per-file licence field, curl, 2026-08-25 | `WebSearch` for this exact asset returned a snippet claiming "OGA-BY 3.0 **and** CC0" in the same sentence — i.e. my independent search reproduced the exact same name-vs-licence-field ambiguity CREDITS.md flagged as a trap. That the trap resurfaces in a differently-worded, independently-run query is decent corroboration that the confusion is baked into the page's own text (collection name vs. licence field), not an artifact of one prior session's phrasing. |
| Freesound, filtered to CC0 license facet | **Unverified this pass** — the filter itself (`f=license%3A%22Creative+Commons+0%22`) is a legitimate mechanism (Freesound lets uploaders pick CC0/CC-BY/CC-BY-NC per sound), but I could not open any specific result page to confirm a per-file licence. `WebSearch` surfaced several named candidates (AleXZavesa's "Dog Bark" pack, nick121087's "Dog Barking", a generic "My dog barking" CC0 hit) with no page fetch to confirm any of their actual licence tags. | — | Not independently confirmed. Do not treat any specific Freesound URL in this document or CREDITS.md as cleared without opening its page directly. |
| OpenGameArt collections literally titled "CC0 Sound Effects" / "80 CC0 creature SFX" (search-surfaced this pass, not in CREDITS.md) | **Unverified** | — | `WebSearch` only; the HaelDB case above is a direct demonstration that an OpenGameArt page's *title* containing "CC0" is not proof of the *licence field* being CC0. These are new leads, not confirmations, and must be opened and checked per-asset before use — exactly per CREDITS.md's existing checklist. |
| Internet Archive 78rpm-era "dog effects"/"dogs barking" records (search-surfaced this pass) | **Not recommended as a route** — genuinely unverified and legally non-trivial, not just "unconfirmed pending a page read." US pre-1972 sound recordings have their own copyright timeline (recordings from before 1923 entered the public domain on 2022-01-01 under the Music Modernization Act; 1923-1946 recordings have a longer, staggered term) that is *independent* of whether Archive.org hosts the file. Archive.org hosting a recording is not itself evidence of public-domain status, and confirming it requires knowing the specific recording's actual production date and clearing it against that schedule — a level of provenance research this task's per-asset checklist doesn't currently anticipate and I did not do. | — | Flagging as a route to not pursue casually, not endorsing or ruling it out definitively. |
| Kenney.nl animal/audio packs | **No dog-bark asset found** | CREDITS.md: site asset search, 2026-08-25 | Not re-checked this pass; no reason to doubt CREDITS.md here. |

## 3. Is CC-BY-SA / OGA-BY actually blocking, or was it over-rejected?

**Over-rejected, for OGA-BY specifically; CC-BY-SA needs one more check before
using it, but likely also fine unmodified.** The task's own constraint is
"CC0/public-domain **or permissively-licensed**," not "CC0 only" — and
CREDITS.md's closing framing ("Real, usable dog-bark audio is obtainable.
**None of it is public domain.**") reads more alarmed than the actual
licence terms justify:

- **OGA-BY 3.0 is exactly the "permissively-licensed, attribution-required"
  category the task explicitly says is acceptable.** It has no share-alike,
  no non-commercial restriction, and no field-of-use restriction — the only
  obligation is crediting the author, which is precisely what `CREDITS.md`
  already exists to carry (it has a ready-made per-file template: source
  URL, author, licence, date, at the bottom of that file). There is no real
  cost here beyond writing one attribution line. Treating "not CC0" as
  equivalent to "blocked" for this specific licence was the over-rejection.

- **CC BY-SA (the Wikimedia files) is the one that deserves a genuinely
  more careful read, and I want to be precise about what I have and haven't
  verified about it.** CC BY-SA's ShareAlike clause (as CC licenses are
  generally structured) attaches to the *Licensed Material* and *Adapted
  Material* — i.e., it requires anything you *modify and redistribute* to
  carry the same licence. It does not require unrelated software that is
  merely *aggregated alongside* an unmodified copy of the licensed file
  (a "Collection," in Creative Commons' own terminology) to be relicensed.
  Bundling an unmodified `.ogg` into this resource's `html/sounds/` folder
  reads like the "Collection" case, not the "Adapted Material" case — which
  would mean CC BY-SA's copyleft does not reach into `qbx_k9unit`'s own code
  at all, only into the audio file itself (and only bites if the audio file
  is later remixed/re-edited and redistributed as a modification). **I have
  not fetched the CC BY-SA 3.0/4.0 legal code itself this session to confirm
  this reading against the primary licence text** — `creativecommons.org`
  was not tried — so this is my own reasoning about how CC BY-SA is
  structured, not a verified claim. It should be confirmed against the
  actual licence text before relying on it for the Wikimedia files
  specifically. Until then, OGA-BY is the safer of the two to act on first
  since it carries no such open question at all.

Net: attribution-required licences are not the blocker the prior framing
implied. The real, still-open blocker for CC BY-SA is one unread legal text,
not the fact of attribution.

## 4. Recommendation

**Ship `bark.ogg` now, sourced from OpenGameArt's "Dog barking mono"
(HaelDB / Brandon Morris) under OGA-BY 3.0, with attribution recorded in
`CREDITS.md`'s existing template. Leave the other four files
(`bark_alert.ogg`, `bark_aggressive.ogg`, `bark_calm.ogg`, `growl_ambient.ogg`)
for a later pass — they sit behind features that default to `false`, so
their absence changes nothing a server operator experiences today.**

Why this one, over the alternatives:

- It is the only candidate in either document with a *directly verified*
  per-asset licence field (not a search snippet) that is unambiguously
  permissive — OGA-BY 3.0, attribution-only, no share-alike, no open
  question left to resolve (unlike the Wikimedia CC BY-SA files).
- It is already the right *content*: per CREDITS.md, the uploader already
  isolated four individual barks and removed background ambiance — i.e.,
  someone already did the "cut a clean one-shot bark out of a longer
  recording" work this task needs, rather than leaving it to whoever
  downloads it.
- Cost is small and known, not open-ended: one attribution line in
  `CREDITS.md`, and one format conversion (the source is `.wav`; `html/app.js`
  requires `.ogg` — a container conversion, which does not touch or
  relicense the underlying audio).

What this recommendation does **not** cover, on purpose: I have no ability
in this pass to fetch and write binary bytes faithfully (no Bash/curl tool
available to me, matching CREDITS.md's own first-pass limitation) — actually
downloading the OpenGameArt `.wav`, verifying it directly (`OggS` magic
bytes after conversion, duration, file size, per CREDITS.md's own
pre-drop checklist), converting it, and writing the `CREDITS.md` attribution
entry and `fxmanifest.lua` `files{}` line is a follow-up action for whoever
has that tooling (coder-backend/coder-frontend, per this project's own
routing) — not something to fabricate here.

Do not use this pass as licence clearance for the Freesound leads or the
newly-surfaced OpenGameArt "CC0 Sound Effects"/"80 CC0 creature SFX"
collections — both are unverified leads only, same status CREDITS.md already
assigns its own unverified leads. Do not pursue the Internet Archive 78rpm
route without dedicated recording-date research; it is not a quick win.

---

**Docs-consolidation note, 2026-08-25.** This recommendation has since been
carried out: `html/sounds/CREDITS.md` records `bark.ogg` as downloaded,
converted, and credited under OGA-BY 3.0, and `fxmanifest.lua`'s `files{}`
block now lists `'html/sounds/bark.ogg'` — confirmed by reading both files
directly. `PLAYER_GUIDE.md` and `PROJECT_STATUS.md` both describe the Bark
action as audible today, not silent.

**This file is a natural candidate to fold into `html/sounds/CREDITS.md`**
(the same licensing decision, split across two files, is exactly the kind
of overlap this project's own documentation-consolidation effort is trying
to remove elsewhere). Not done as part of this pass because `CREDITS.md`
is outside this pass's editable scope — flagged here for whoever owns that
file next.
