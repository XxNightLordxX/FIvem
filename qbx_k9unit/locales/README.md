# qbx_k9unit locales

## Status: pattern established, migration NOT finished

This directory and the `locale()` calls in `client/vision.lua` and
`client/vehicle.lua` are a **reference migration of two files only**.
`fxmanifest.lua` has declared `ox_lib 'locale'` since Phase 1, but until
this change no `locales/` directory existed and every player-facing string
in this resource was hardcoded English. That gap is now closed for two
files. It is not closed for the rest of the resource — see "What's left"
below.

**Update (second migration pass):** `client/kennel.lua` is now also
migrated (new `kennel.*` group below). Four more files —
`client/screenfx.lua`, `client/audio.lua`, `client/proximityaudio.lua`,
`client/recall.lua` — were reviewed for this same pass and found to
contain **zero player-facing strings** to migrate at all: they are pure
NUI/Web-Audio plumbing, a discovery/maintenance thread, and a bare
`RegisterCommand`/`TriggerServerEvent` pair with no `lib.notify`, no
`ox_target` labels, and no `RegisterKeyMapping` description anywhere in
them (confirmed by grep, not just a skim — see "What's left" below for the
exact count this leaves). Do not assume a file is unmigrated just because
it isn't named in the two-file list above; check whether it actually has
any player-facing strings first.

## Format (verified against ox_lib source, not assumed)

Checked directly against `overextended/ox_lib`
(`imports/locale/shared.lua`, `resource/server.lua`) and against a real
shipped Qbox-project resource that already uses this exact convention
(`Qbox-project/qbx_ambulancejob`, which `fxmanifest.lua`'s own header
comment already cites as a matched reference):

- File lives at `locales/<lang>.json` (`en.json` for this file), loaded by
  `LoadResourceFile` + `json.decode` — it must be **strictly valid JSON**,
  no comments, no trailing commas. That's why this migration guide is a
  separate `README.md` instead of a comment inside `en.json`.
- The JSON object may nest (as this file does: `common`/`vision`/`vehicle`
  top-level groups). ox_lib flattens nested tables into `parent.child` dot
  keys at load time (`flattenDict` in `imports/locale/shared.lua`) — so
  `"vision": { "thermal_on": "..." }` becomes the lookup key
  `vision.thermal_on`.
- Call it with the bare global `locale(key, ...)` (this global is exposed
  automatically once `ox_lib 'locale'` + `'@ox_lib/init.lua'` are in the
  manifest, as they already are here — no extra bootstrap call is needed;
  confirmed against qbx_ambulancejob, which never calls `lib.locale()`
  itself either and uses bare `locale(...)` directly, including at file-load
  time in top-level statements, not just inside functions).
- Dynamic values are NOT Lua string concatenation. Pass them as extra
  arguments and use `%s`/`%d`-style placeholders in the JSON string itself
  — `locale()` runs the matched string through `string.format` against
  whatever extra args you pass, e.g. `locale('info.ems_alert', text)`
  against a JSON value of `"EMS Alert - %s"`. This resource's two migrated
  files happen not to need this yet (see "Why no interpolation was used
  here" below), but the next file to migrate almost certainly will —
  reach for `%s`/`%d` placeholders + extra `locale()` args before reaching
  for `..` string concatenation.
- `${other.key}` inside a JSON string value is ox_lib's OWN
  cross-reference syntax (resolved once, at `lib.locale()` load time, by
  substituting another key's already-resolved value) — different from the
  runtime `%s` interpolation above. Not used in this file yet; only reach
  for it if a string needs to embed another locale string verbatim.

## Key-naming scheme chosen here

Top-level group = the domain the string belongs to, mirroring the owning
client file's name where the string is specific to that file
(`vision.*`, `vehicle.*`). Leaf keys are `snake_case`, short, and describe
the string's *purpose* not its English wording (`no_vehicle_nearby`, not
`error_message_1`) — a locale key is an API translators depend on, and it
should stay stable even if the English wording it maps to changes later.

One deliberate exception: **`common.*`**. Two strings —
`'K9 Unit'` (the `lib.notify` title used everywhere) and
`'This only works while playing a K9 character.'` (the
`IsOwnModelK9()`-gate deny message) — are already duplicated verbatim
across `client/vision.lua` and `client/movement.lua` (confirmed by
grepping the tree before writing this file; `client/movement.lua` is NOT
touched by this change, only checked for its existing hardcoded copies to
avoid creating a second, drifting key for the same string). Give these a
shared `common.*` key rather than a new `vision.notify_title` /
`vehicle.notify_title` pair per file — when the next agent migrates
`client/movement.lua` or any other file that reuses `'K9 Unit'` /
`'This only works while playing a K9 character.'`, point it at
`common.notify_title` / `common.not_k9_model` instead of minting a
duplicate key. Do NOT invent a third near-duplicate key for the same
English string anywhere in this resource — check this file's existing
keys first.

`client/main.lua`'s own `DenyK9UIAccess()` (`'You cannot use K9 features
right now.'`) was deliberately left alone here — it's a third,
already-centralized, resource-global function in a file this migration
does not touch, so localizing that message is the job of whoever
migrates `client/main.lua`, not this change. When that happens, put it in
this same `common.*` group (e.g. `common.no_k9_access`) for the identical
reason above — it too is duplicated verbatim across several other files
(`client/movement.lua` alone hardcodes it at least four times).

### `kennel.*` (added in the second migration pass, `client/kennel.lua`)

Five new leaf keys: `already_deployed`, `prop_load_failed`,
`placement_failed`, `no_suitable_ground` (all four `lib.notify`
descriptions, each paired with `common.notify_title` exactly like
`vision.*`/`vehicle.*` already do — none of the four were duplicated
elsewhere in this resource's `client/` tree, confirmed by grep, so none
were promoted to `common.*`), and `pickup_target_label` (the "Pick Up
Kennel" `ox_target` option label). See "What's left" below for an
important **non**-duplication note about `server/kennel.lua`'s own
similarly-worded-but-different `NotifyPlayer` strings — do not reuse
`kennel.placement_failed` for those when that file gets migrated.

## Why no interpolation was used for the vision on/off strings

`vision.thermal_on` / `vision.thermal_off` (and the `night_*` pair) are
four separate, complete-sentence keys rather than one templated
`"Thermal vision %s."` key interpolated with `"on"` / `"off"`. Word order
and inflection around a state word like "on"/"off" don't translate
uniformly across languages, so collapsing them into one template would
make the string harder, not easier, to localize correctly later — full
sentences per state is the safer default absent a concrete reason to
template. This is a judgment call, not something ox_lib forces either
way; revisit it if a future translator reports it's a poor fit for a
specific language.

## How to migrate one more file (the pattern this established)

1. Read the target file and list every hardcoded string that is actually
   shown to a player: `lib.notify`/similar UI descriptions and titles,
   `ox_target` option labels, `RegisterKeyMapping` description strings,
   command help text shown in F8/chat suggestions. Do **not** touch
   `print()` calls (server-operator diagnostics, some of them deliberate
   audit logging) and do not touch comments.
2. Before minting a new key, grep this resource for the exact English
   string first — several strings (starting with `'K9 Unit'` and
   `'This only works while playing a K9 character.'`, see `common.*`
   above) are already duplicated across multiple files. Reuse the existing
   key rather than creating a near-duplicate.
3. Add the new key(s) to `locales/en.json` under a top-level group named
   after the owning file (or `common` if it's already shared across
   files), `snake_case` leaf name describing purpose.
4. In the Lua file, replace the literal string with `locale('group.key')`,
   or `locale('group.key', arg1, arg2)` if the JSON value has `%s`/`%d`
   placeholders for dynamic parts — never rebuild the sentence with `..`.
5. Validate: `python3 -c "import json; json.load(open('locales/en.json'))"`
   (or any JSON parser) must succeed, and `luac5.4 -p` / `luacheck` on the
   changed Lua file(s) must still be clean.
6. If this is the first string from a whole new file family, flag to
   whoever owns `fxmanifest.lua` that no manifest change is needed per new
   locale key — the `locales/*.json` files{} entry (added once, see the
   note at the bottom of this file) already covers every key added here
   going forward.

## What's left (honest count)

As of this pass, **3 of roughly 48 Lua files** in this resource's
`client/` + `server/` trees have actually needed a `locale()` migration —
`client/vision.lua`, `client/vehicle.lua`, and now `client/kennel.lua`.
Four more files (`client/screenfx.lua`, `client/audio.lua`,
`client/proximityaudio.lua`, `client/recall.lua`) were checked this pass
and confirmed to have **no player-facing strings at all**, so they need no
`locale()` calls — don't re-check them again from scratch, but do
re-check if you add new player-facing UI to any of them later.

Every other file — `client/main.lua`, `client/movement.lua`,
`client/radial.lua`, `client/tracking.lua`, `client/search.lua`,
`client/hud.lua`, `client/inventory.lua`, `client/medkit.lua`,
`client/wellbeing.lua`, `client/progression.lua`, `client/combat.lua`,
`client/partnership.lua`, `client/defense.lua`,
`client/propattachment.lua`, `client/bonetool.lua`, `client/fetch.lua`,
`client/exports.lua`, and every file under `server/` — is UNCHECKED by
this pass and should be assumed to still have 100% hardcoded English for
any player-facing string it contains (server-side strings sent to players
via `lib.notify`/`exports.qbx_core:Notify`/similar are just as in scope as
client-side ones; only `print()`/comments are out of scope). This file
establishes the pattern and the shared `common.*` keys; it does not claim
to have finished the job.

**Note for whoever migrates `server/kennel.lua`:** that file has its own
`NotifyPlayer(src, '...', 'error')` strings ("Kennel placement failed —
the object could not be confirmed.", "...— unexpected object model.",
"...— placed too far from the assigned spot.") that are SIMILAR to but NOT
identical with this pass's new `kennel.placement_failed` ("Kennel
placement failed.", used by `client/kennel.lua` for a different failure
case — a client-side object-creation/grounding failure, not the server's
own post-hoc placement validation). Do not silently collapse these into
one key — they are different messages for different failure conditions,
even though they share the "Kennel placement failed" phrase; give the
server-side ones their own `kennel.*` keys (or a `server_kennel.*` group,
your call) rather than reusing `kennel.placement_failed` for a different
sentence.

## Manifest change needed (not made here — `fxmanifest.lua` is out of
scope for this change)

`fxmanifest.lua` already has `ox_lib 'locale'` and
`'@ox_lib/init.lua'` in `shared_scripts`, which is all that's needed for
the bare `locale()` global to work. The one thing still missing is
listing the new JSON file(s) in the `files {}` block so the client
actually downloads `locales/en.json` (client-side `LoadResourceFile` reads
only files a resource has declared, and the JSON is read from BOTH client
and server contexts since `imports/locale/shared.lua` is shared). Add this
line inside the existing `files { ... }` block (which currently only lists
`html/index.html`, `html/style.css`, `html/app.js`):

```
'locales/*.json',
```
