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

None. Nothing below this line exists yet — when a real, licensed file is
added, record it here in this format:

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
