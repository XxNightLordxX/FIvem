# qbx_k9unit/html/sounds — bark audio sourcing brief

Author: technology-scout pass, 2026-08-24, jlwood17190665@gmail.com.

**Status: NO audio files were added in this pass.** This file is a sourcing
brief, not a credits log — there is nothing to credit yet. That is a
deliberate, honest outcome, not an oversight: see "Why no files shipped"
below before assuming this is unfinished work someone forgot to do.

**Confidence convention** (same standard `phase2_notes/dependency_and_audio_status.md`
already uses in this resource): a claim below is marked CONFIRMED only when
independently corroborated; anything resting on a single, unverifiable
source is marked UNCONFIRMED/PLAUSIBLE and flagged as such.

---

## What is actually needed

Four short, one-shot Ogg Vorbis (`.ogg`) files, at these exact paths and
filenames — read directly from `client/audio.lua`'s `SOUND_NAME_TO_FILE_KEY`
table and `html/app.js`'s `loadSoundBuffer()` (`fetch('sounds/' + key + '.ogg')`,
resolved relative to `html/index.html`, i.e. under `html/sounds/`):

| Filename (place at `html/sounds/`) | Sound name in code | Tone guidance |
|---|---|---|
| `bark.ogg` | `'Bark'` — `client/main.lua`'s `BARK_SOUND_NAME`, the Phase 1 generic bark | Generic/neutral single bark |
| `bark_alert.ogg` | `'Bark_Alert'` — `config.lua`'s `Config.AdvancedBarkRadial` | Sharper, attention-getting bark |
| `bark_aggressive.ogg` | `'Bark_Aggressive'` — `config.lua`'s `Config.AdvancedBarkRadial` | Growl-tinged / threatening bark |
| `bark_calm.ogg` | `'Bark_Calm'` — `config.lua`'s `Config.AdvancedBarkRadial` | Soft, single low bark/chuff |

Practical constraints, from reading `client/audio.lua` directly (it plays
these as one-shot, non-looping sounds today — nothing in this resource
passes `loop=true` yet):
- **Duration:** a single bark, not a barking sequence or ambience loop —
  realistically well under 2 seconds each.
- **Size:** should be well under 1 MB each; a short mono/stereo bark SFX at
  a normal game-audio bitrate is typically tens to a couple hundred KB. A
  file anywhere near a megabyte for a one-shot bark is a sign the wrong
  asset (e.g. a long ambience track) was picked.
- **Format:** must actually be Ogg Vorbis, not just `.ogg`-named. Verify by
  checking the file's magic bytes (`OggS` as the first four ASCII bytes of
  the file) — do not trust the extension alone. This resource's own
  `html/app.js` (`ctx.decodeAudioData`) will simply fail silently on a
  wrong-format file (by design, per that file's "GRACEFUL DEGRADATION"
  contract), so a bad file wouldn't even throw a visible error — it would
  just look like a normal not-yet-supplied file. Checking the header
  yourself before committing is the only way to catch that.
- Four *distinct* tones are the ideal end state, but are not a hard
  blocker: `client/audio.lua`'s header states a not-yet-mapped/duplicate
  sound name degrades to a harmless resolved key, so shipping the same
  generic `bark.ogg` bytes under all four filenames as an honest first pass
  (better than no audio, clearly worse than four real distinct takes) is a
  legitimate incremental option if only one clean, well-licensed bark can
  be sourced initially.

## Why no files shipped this pass

Two independent blockers, either one of which alone would already justify
not shipping anything real:

1. **Tooling:** this pass's available tools are web search/fetch (which
   fetches a page and returns an AI-summarized markdown/text rendering of
   it — not a raw byte stream) and a text file writer. Neither is capable
   of downloading and faithfully preserving the exact binary bytes of a
   remote audio file. Attempting to "write" audio bytes through a
   text-oriented tool risks silently producing a corrupt or fabricated
   file that merely has a `.ogg` name — exactly the "placeholder that
   looks like a real asset" outcome this task explicitly rules out. Rather
   than risk that, no file was written.
2. **Egress:** even setting tooling aside, this session's network egress
   proxy actively blocked every candidate audio-hosting/reference domain
   tried directly: `freesound.org`, `opengameart.org`, `kenney.nl`,
   `pixabay.com`, and `commons.wikimedia.org` all returned an explicit
   `EGRESS_BLOCKED` error on fetch. (`github.com`/`raw.githubusercontent.com`
   were reachable, for contrast — this looks like a narrow allowlist, not a
   total network outage.) So even a tool that *could* download bytes
   would not have reached most of the sources below this session anyway.

This matches the task's own anticipated "egress blocked / cannot obtain
assets meeting the bar" outcome — treated here as the legitimate result it
is, not something to work around by fabricating a file.

## Candidate CC0 / public-domain sources for whoever sources these next

None of these were independently opened and read this session (blocked, see
above) — each is carried here as a **named, single-source lead from a web
search snippet only**, i.e. UNCONFIRMED/PLAUSIBLE, not verified first-hand.
Whoever pulls from these must open the asset's own page and confirm the
license stated *on that specific asset* before use — do not treat this
list itself as a license clearance.

1. **OpenGameArt.org — "Dog barking mono"** by uploader HaelDB.
   `https://opengameart.org/content/dog-barking-mono`
   Search-snippet description: CC0-licensed, 4 barks recorded at 48kHz,
   mono, background ambiance removed by the uploader. If the license page
   confirms CC0 on this specific submission, this is close to an ideal
   source — already isolated single-bark clips, already processed.
2. **Kenney.nl — "Animal Pack"**.
   `https://kenney.nl/assets/animal-pack`
   Kenney's asset packs are broadly known to be released under CC0 as a
   blanket studio policy, and this pack was returned by search as
   containing animal sounds — but whether it specifically contains a dog
   bark (vs. other animals only) was not confirmed this session; open the
   pack listing and check its actual file list before assuming it has one.
3. **Freesound.org — filter by CC0 specifically.**
   `https://freesound.org/search/?q=dog+bark&f=license%3A%22Creative+Commons+0%22`
   (or manually filter the license facet to "Creative Commons 0" on any
   freesound search) — Freesound hosts a mix of CC0, CC-BY, and
   CC-BY-NC-licensed sounds side by side on the same site, so the license
   filter (or a per-sound license check) is mandatory, not optional, here.
   A specific lead surfaced by search this session:
   `https://freesound.org/people/Juan_Merie_Venter/sounds/327666/`
   ("Dog Bark.wav") — its exact license tag was not independently
   confirmed (page unreachable this session); check it directly.
4. **Wikimedia Commons — "File:Barking of a dog.ogg".**
   `https://commons.wikimedia.org/wiki/File:Barking_of_a_dog.ogg`
   Search snippet describes this as a public-domain `.ogg` file — notably
   already in the exact target format if confirmed. Commons pages
   typically carry an explicit, individually-stated license/author block
   per file, which is exactly the kind of "license stated on the asset
   itself" this task requires — but that block was not independently read
   this session (page unreachable); confirm it directly before use.

## Sources actively checked and ruled out this pass — do not reuse without re-checking the specific caveat

- **`github.com/suzuki256/dog-dataset`** — its `LICENSE` file was read
  directly this session. It is a **mixed-license aggregate**: some
  component sources are `CC BY-NC` (non-commercial), explicitly
  disqualified by this task's constraint (a game server can be monetized).
  Since the file-level license within the dataset isn't uniformly
  CC0/CC-BY at a glance, do not pull an individual file from this repo
  without independently re-confirming that specific file's own license,
  not just the repo's blended summary.
- **`github.com/lavenderdotpet/CC0-Public-Domain-Sounds`** — the repo
  itself carries a CC0 `LICENSE` file, and search suggested it may contain
  a folder resembling dog sounds. **Not used regardless**: it is a
  personal "collection ... over some time" with no stated per-file
  original source or original author for its contents. A CC0 declaration
  by whoever aggregated the files does not establish that the *original*
  recording was theirs to relicense, and this task requires being able to
  cite an actual source URL and license for the asset itself — an
  aggregator's own blanket relicensing claim over unattributed collected
  content does not clear that bar. Flagging this explicitly so it isn't
  reused later on the strength of its LICENSE file alone.

## Checklist before actually dropping files into `html/sounds/`

1. Open the asset's own original page (not an aggregator/mirror) and
   confirm the license stated there is CC0, public domain, or CC-BY.
2. If CC-BY: add an entry to *this* file recording the exact attribution
   text the license requires, verbatim.
3. Confirm the file is genuinely Ogg Vorbis (check the `OggS` magic bytes),
   not merely named `.ogg`.
4. Confirm it's a short, single bark and not a loop/ambience/multi-bark
   sequence; confirm the file size is well under 1 MB.
5. Record filename, source URL, author, license, and retrieval date as a
   new entry in this file for every file actually added.
6. Update `fxmanifest.lua`'s `files{}` block so the new files are actually
   shipped to clients — see the note below; explicit entries are the safe
   default regardless of what glob support turns out to allow.

## `fxmanifest.lua` `files{}` — glob support finding (for whoever owns that file)

**This resource's current `files{}` block already lists every entry
explicitly** (`html/index.html`, `html/style.css`, `html/app.js` — no
glob today), so adding four explicit lines
(`'html/sounds/bark.ogg'`, `'html/sounds/bark_alert.ogg'`,
`'html/sounds/bark_aggressive.ogg'`, `'html/sounds/bark_calm.ogg'`) is a
same-pattern, zero-risk change requiring no new investigation.

On whether a glob would also work (e.g. `'html/sounds/*.ogg'` instead):
the primary CFX documentation pages (`docs.fivem.net`,
`docs-backend.fivem.net`) were unreachable this session (egress-blocked),
so this could not be confirmed first-hand against the authoritative source.
From what could be reached:
- `github.com/citizenfx/fivem` issue **#1406** ("Bash Glob for resource
  file matching") was read directly. It is a live proposal to *replace*
  fxmanifest's existing glob behavior, and in doing so describes today's
  behavior as already having "a current glob pattern system" where a
  single `*` behaves recursively (roughly equivalent to `**/**`, not
  scoped to just the immediate folder) — i.e. **some glob support already
  exists**, but its exact matching semantics are non-obvious and are
  themselves the subject of an open compatibility-breaking change request.
- Multiple independent web-search summaries (not independently opened
  pages, so PLAUSIBLE rather than CONFIRMED to this project's own
  two-primary-source bar) describe the `files` directive specifically as
  glob-capable, one quoting what reads like a docs example:
  `files { 'html/index.html', 'html/**/*', 'data/handling.meta' }`.
- Net assessment: a glob such as `'html/sounds/*.ogg'` is **plausibly
  supported**, but not confirmed against the primary doc this session, and
  its precise matching behavior is under active upstream discussion.
  **Recommendation: use explicit filenames**, matching this manifest's own
  existing convention and sidestepping any ambiguity in current-vs-future
  glob semantics, rather than adopting a mechanism whose exact behavior
  this pass could not verify against the authoritative source.

## Files actually added this pass

`bark.ogg` was added in the 2026-08-25 "AUDIO SHIP PASS" below. Use this
template for any future file added to `html/sounds/`:

```
### <filename>
- Source URL:
- Author:
- License:
- Date retrieved:
- Verified Ogg Vorbis (OggS magic bytes): yes/no
- File size:
```


---

# AUDIO SHIP PASS — 2026-08-25

Author: jlwood17190665@gmail.com. Downloaded and shipped the one file that
gates default-on behavior (`bark.ogg`); the other four (`bark_alert.ogg`,
`bark_aggressive.ogg`, `bark_calm.ogg`, `growl_ambient.ogg`) sit behind
features that ship `false` and were left for a later pass, per
`AUDIO_SOURCING.md`'s recommendation.

## Re-verification of the licence, this pass, against the live page

Fetched `https://opengameart.org/content/dog-barking-mono` directly with curl
(HTTP 200) and read the page's own `field-name-field-art-licenses` block
(the structured "License(s):" taxonomy field, not the "Collections:" field
that carries collection titles like "CC0 Audio - Uploader: HaelDB").

**Important correction to the record left by the prior two research passes
(this file's own 2026-08-25 "LICENCE VERIFICATION PASS" section and the
sibling `AUDIO_SOURCING.md`):** both describe the page's "CC0" string as
appearing *only* as a collection name, with the actual License(s) field
containing OGA-BY 3.0 alone. Reading the raw HTML directly, the License(s)
field on this page in fact lists **two** field-items:

```
field-name-field-art-licenses ("License(s):")
  1. <a href='http://opengameart.org/content/oga-by-30-faq'>  license-name: OGA-BY 3.0
  2. <a href='http://creativecommons.org/publicdomain/zero/1.0/'>  license-name: CC0
```

The second entry links to the actual CC0 legal code, not to a collection
page, and sits inside the same taxonomy field as the first — this is
OpenGameArt's standard mechanism for an author offering a submission under
either of two licenses (the downloader's choice), not a stray keyword. I
confirmed this is a genuine structural difference (not a parsing artifact
of mine) by fetching a second, unrelated OGA asset known to be single-licensed
(`content/rpg-sound-pack`, CC0 only) as a control: its License(s) field
contains exactly one `field-item`, where this page's contains two.

This is recorded here for the next person who reads this file, but it does
**not** change what's shipped below: the task constraint this file operates
under only requires "verifiably CC0/public-domain **or** permissively-licensed
(attribution-only)", and **OGA-BY 3.0 alone already clears that bar** —
attribution-only, no share-alike, no NC. So this file is credited under
OGA-BY 3.0, the license this pass can defend with full confidence regardless
of how the CC0 field-item is ultimately read, and no attribution obligation
is skipped by doing so. If a future pass wants to rely on the CC0 option
instead (dropping the attribution requirement below), that reading of the
page should be independently confirmed first, since it revises what two
prior passes concluded.

## `bark.ogg`

- **Source URL:** https://opengameart.org/content/dog-barking-mono (submission page); direct file: https://opengameart.org/sites/default/files/dog_barking_mono.wav
- **Author:** Brandon Morris (submitted by OpenGameArt user HaelDB)
- **License:** OGA-BY 3.0 (attribution-only; see http://opengameart.org/content/oga-by-30-faq). Per the page's own License(s) field this asset is also offered under CC0 — see the correction note above — but this credit is made under OGA-BY 3.0 only, which requires the attribution line below regardless.
- **Attribution text (as OGA-BY 3.0 requires):** "Dog barking mono" by Brandon Morris (HaelDB), https://opengameart.org/content/dog-barking-mono, licensed under OGA-BY 3.0.
- **Date retrieved / verified:** 2026-08-25
- **Verification commands run, and their output:**
  - `curl -sS -L "https://opengameart.org/content/dog-barking-mono" -o oga_page.html -w "HTTP_CODE:%{http_code}\n"` -> `HTTP_CODE:200`; confirmed page identity via `<link rel="canonical" href="https://opengameart.org/content/dog-barking-mono" />` and `<title>Dog barking mono | OpenGameArt.org</title>`.
  - `curl -sS -L "https://opengameart.org/sites/default/files/dog_barking_mono.wav" -o dog_barking_mono.wav -w "HTTP_CODE:%{http_code} SIZE:%{size_download}\n"` -> `HTTP_CODE:200 SIZE:179848`, matching the page's own `<a ... type="audio/x-wav; length=179848">` byte count exactly.
  - `file dog_barking_mono.wav` -> `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 44100 Hz` — confirms a real WAV container, mono as the page's own tags claim.
  - `python3 -c "import wave; ..."` on the downloaded file -> `channels 1, sampwidth 2, framerate 44100, nframes 89902, duration_sec 2.0386`. The source file is the uploader's full "4 pitched barks" take (matching the page's own `4`/`barks`/`pitch` tags), not a single one-shot bark.
  - `ffmpeg -i dog_barking_mono.wav -af silencedetect=noise=-30dB:d=0.05 -f null -` -> found four separate audible segments separated by silence, the first spanning ~0.000s-0.195s. **Trimmed to the first bark only** (`-ss 0 -t 0.35`, with a 50ms fade-out from 0.30s to avoid a hard cut) so the shipped one-shot file is actually one bark, matching how `client/audio.lua` plays it (`PlayK9Sound` with no `loop`, per `AUDIO_SOURCING.md`'s own table) — the full 4-bark take would not have been a faithful one-shot bark sound. This is a straightforward trim of an unmodified excerpt, permitted under an attribution-only license.
  - `ffmpeg -y -i dog_barking_mono.wav -ss 0 -t 0.35 -af "afade=t=out:st=0.30:d=0.05" -c:a libvorbis -qscale:a 5 -ac 1 bark.ogg` -> encoded to Ogg Vorbis, mono, 44100 Hz.
  - `head -c4 bark.ogg | od -c` -> `O g g S` (confirmed `OggS` magic bytes; genuinely Ogg container, not just `.ogg`-named).
  - `ffprobe -v error -show_format -show_streams bark.ogg` -> `codec_name=vorbis`, `sample_rate=44100`, `channels=1`, `duration=0.350000`, `size=6951`, `probe_score=100`.
- **Verified Ogg Vorbis (OggS magic bytes):** yes
- **Duration:** 0.35 seconds (well under 2s)
- **File size:** 6,951 bytes (well under 1 MB)
- **Filename and path, derived from code (not assumed):** `html/sounds/bark.ogg`. `client/audio.lua`'s `SOUND_NAME_TO_FILE_KEY` maps sound name `'Bark'` (`client/main.lua`'s `BARK_SOUND_NAME`) to file key `'bark'`; `html/app.js`'s `loadSoundBuffer()` does `fetch('sounds/' + key + '.ogg')`, resolved relative to `html/index.html` — i.e. `html/sounds/bark.ogg`.

## Outstanding follow-up (outside this file's scope — `html/sounds/` only)

`fxmanifest.lua`'s `files{}` block does not yet list `html/sounds/bark.ogg`
(verified by reading it directly this pass — only `html/index.html`,
`html/style.css`, `html/app.js`, `locales/en.json` are listed). Per
`AUDIO_SOURCING.md`'s own note, this resource's manifest convention is
explicit entries, not globs. **The file will not actually reach clients
until `'html/sounds/bark.ogg'` is added to that block** — flagged here for
whoever owns `fxmanifest.lua`, since this pass's scope is `html/sounds/`
only and does not touch it.

# LICENCE VERIFICATION PASS — 2026-08-25

The leads listed above were recorded from search snippets and explicitly marked
UNCONFIRMED. They have now been checked directly against each asset's own page
or API. **Two of the four were mislicensed in the brief above.** Nothing was
downloaded and nothing was added to this resource.

Why this pass could go further than the last one: earlier attempts had only a
fetch tool that returns an AI summary of a page, and every audio host came back
blocked. Plain `curl` through the environment's proxy reaches all of them. The
hosts were never the obstacle — the tool was.

## Verified findings

| Candidate | Brief claimed | **Actually licensed** | Verified how |
|---|---|---|---|
| `File:Barking of a dog.ogg` (Wikimedia) | public domain | **CC BY-SA 3.0** | Commons API `extmetadata.LicenseShortName` |
| `File:Barking of a dog 2.ogg` | — | **CC BY-SA 3.0** | same |
| `File:Perro ladrando.ogg` | — | **CC BY-SA 4.0** | same |
| `File:Rottweiler Barking.oga` | — | **CC BY-SA 4.0** | same |
| `File:Barking dog in Rome.ogg` | — | **CC BY-SA 3.0** | same |
| OpenGameArt "Dog barking mono" (HaelDB) | CC0 | **OGA-BY 3.0** | the asset page's own licence field |
| Kenney animal/audio pack | CC0, dog unconfirmed | **no animal or dog audio pack found** | site asset search |
| Commons `incategory:CC-Zero` + dog audio | — | **no genuine bark** | every hit is either the London place name "Barking" or a spoken-word pronunciation |

## The OpenGameArt one is a trap, and worth understanding before re-checking it

Searching that page for "CC0" **does** return a hit — because the file belongs
to a user-curated collection *named* "CC0 Audio - Uploader: HaelDB". The
licence field itself says OGA-BY 3.0. Anyone confirming the brief's claim with a
quick text search, human or otherwise, gets a false positive and ships an
attribution-licensed asset believing it is public domain.

That is almost certainly how the original snippet-sourced claim went wrong.

## Where this leaves the decision

Real, usable dog-bark audio is obtainable. **None of it is public domain.**
Every candidate found carries an obligation:

- **CC BY-SA** (the Wikimedia files) — attribution *plus share-alike*. Share-alike
  is the significant one: it is a copyleft term, and applying it to audio
  shipped inside a resource distributed to server owners is a licensing
  commitment about this project, not a formality.
- **OGA-BY 3.0** (OpenGameArt) — attribution only, no share-alike. Materially
  lighter than CC BY-SA, and the more likely fit.

This is the owner's call, not one to make on their behalf, which is why nothing
was downloaded. Whichever way it goes, the four filenames
`html/sounds/{bark,bark_alert,bark_aggressive,bark_calm}.ogg` and the pre-drop
checklist above still apply, and the attribution must be recorded in this file.

Note the format gap: every verified candidate is `.ogg`/`.oga`/`.wav`, while the
NUI bridge expects `.ogg`. The Wikimedia files already qualify; the OpenGameArt
ones are `.wav` and would need converting.
