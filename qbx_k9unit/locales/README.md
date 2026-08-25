# qbx_k9unit locales

## What this is

This resource shows text to players — notification messages, menu labels, keybind descriptions, and so on. Instead of writing that English text directly into the Lua code, it's kept in one file, `locales/en.json`, and the Lua code asks for it by a short name (a **locale key**, e.g. `combat.no_target_in_range`) using a function called `locale()`. This is what lets the text be translated into another language later, by adding a second file (e.g. `es.json`) with the same keys, without touching any Lua code.

If you're adding a brand-new player-facing message to this resource, or translating the existing ones, this file explains the pattern to follow. If you're checking whether this migration (see below) is finished, see "Status" and "The numbers below expire" right after it.

## Terms used in this document

- **Locale key** — the short name used to look up one piece of text, e.g. `combat.no_target_in_range`. Always written as `group.name`.
- **Leaf key** — same thing as a locale key, described from the JSON file's point of view: `locales/en.json` is a file of nested groups, and a "leaf" is one of the actual text values at the bottom of that nesting (as opposed to a group name, which just holds other keys).
- **Migration / migrating a string** — the one-time act of taking a piece of text that used to be hardcoded directly in a `.lua` file and moving it into `en.json` under a new locale key, then changing the Lua code to call `locale('that.key')` instead of writing the sentence out. You'll sometimes see "migration pass" in commit history — one batch of files converted in one work session.

## Status: this migration is complete

Every player-facing string in this resource — every notification, menu label, keybind description, and command-usage message — now goes through `locale()`. There are no `.lua` files left with hardcoded English text that a player would see. (Server-console-only `print()` lines, which nobody but a developer/admin ever sees, are intentionally left as plain strings — see "What was deliberately NOT touched" below.)

This has not always been true. Earlier versions of this file described the migration as in-progress with several files still outstanding, and — because several people were editing this file and the underlying code at the same time — that in-progress description briefly kept describing files as "still to do" even after they'd actually been finished by someone else. That's the specific problem the next section exists to prevent from happening quietly again.

## The numbers below expire — here's how to re-check them

Every count in this document (leaf-key total, files migrated, groups) was checked by actually reading the files, not by trusting an older version of this same document. But this codebase has many people working on it at once, and any of these numbers can change the moment someone adds a new feature with new player-facing text. **Don't repeat a number from this file without re-checking it if any real time has passed.**

Here is exactly how each number below was produced, so you can reproduce it:

- **Commit these numbers were checked at:** `9808e56` (full hash `9808e568809bdf96c60ea2716ad1b65b03ec9456`), made 2026-08-25 09:45:22 UTC, message "Guard prop attachment against cross-citizen netId collisions".
- **Total leaf keys (306):** counted directly from `locales/en.json` — every line matching a `"name": "text"` pattern nested inside a group. Reproduce with either a small script (recursively count non-object values in the parsed JSON) or `grep -cE '^\s{2,}"[a-zA-Z0-9_]+":\s*"' locales/en.json`. Both independently gave 306 at the commit above.
- **Zero files left with hardcoded text:** checked two ways — (1) every locale key in `en.json` has at least one real call site in the Lua code, and every `locale(...)` call in the Lua code points at a key that actually exists (a "both directions" cross-check), and (2) the two files most recently in question, `server/combat.lua` and `server/bonetool.lua`, were directly confirmed to call `locale()` (27 and 3 times respectively — `grep -c "locale(" server/combat.lua server/bonetool.lua`) rather than still holding hardcoded text.
- **File counts (47 total: 25 client + 22 server):** `ls qbx_k9unit/client/*.lua | wc -l` and `ls qbx_k9unit/server/*.lua | wc -l`.
- **To check whether all of this is still current:** run `git rev-parse HEAD`. If it isn't `9808e56`, re-run the checks above yourself, especially if you know a new feature landed since — a new feature almost always means new locale keys.

Of those 47 `.lua` files, 33 call `locale()` for real player-facing text, and the other 14 were checked and confirmed to have no player-facing text at all (pure background logic, or plumbing that only sends numbers/booleans to the UI). 33 + 14 = 47. Nothing is left unchecked.

## Where the text actually lives, and its current shape

All English text is in one file: `locales/en.json`. It's plain JSON, organized as named groups, each holding one or more leaf keys. For example:

```json
"combat": {
  "no_target_in_range": "No eligible target in range."
}
```

is looked up in Lua as `locale('combat.no_target_in_range')`.

As of the commit above, there are **24 top-level groups**: `admin`, `agility`, `bonetool`, `certifications`, `combat`, `common`, `defense`, `fetch`, `inventory`, `kennel`, `leash`, `medkit`, `movement`, `partnership`, `progression`, `propattachment`, `radial`, `recall`, `search`, `tenure`, `tracking`, `vehicle`, `vision`, `wellbeing`. Most groups are named after the `.lua` file whose text they hold (`vision.*` for `client/vision.lua`'s text, and so on). This document doesn't try to list every one of the 306 individual keys — that list changes often, and `en.json` itself is always the accurate, up-to-date source for it. What this document does keep track of is the small set of keys that are deliberately **shared across multiple files** — see the next section — because those are easy to accidentally duplicate if you don't know they already exist.

## Shared keys — check this list before adding a new one

A few messages are used by more than one file on purpose, so a translator only has to translate them once and every place that shows them stays in sync. Before writing a new key, check whether your exact sentence is already one of these:

- **`common.notify_title`** ("K9 Unit") — the title used by nearly every notification in this resource.
- **`common.no_k9_access`** ("You cannot use K9 features right now.") — shown by `client/main.lua`'s `DenyK9UIAccess()` helper. Most files that need this message call that helper directly rather than calling `locale()` themselves; `client/tracking.lua` calls the locale key directly instead.
- **`common.not_k9_model`** ("This only works while playing a K9 character.")
- **`common.too_far_from_k9`** ("Get closer to the K9 first.") — shared by `client/wellbeing.lua` and `client/medkit.lua`.
- **`common.target_no_longer_online`**, **`common.no_k9_party`**, **`common.k9_not_certified`**, **`common.handler_not_in_department`** — shared rejection reasons reused inside `server/main.lua`'s leash-request rejection table.
- **`common.unable_to_resolve_citizenid`**
- **`defense.already_engaged`** ("You are already engaged with another target.") — reused as-is by `server/combat.lua`, rather than that file minting its own copy.
- **`partnership.partner_up_target_label`** ("Partner Up") — reused as-is by `client/radial.lua`'s own "Partner Up" menu entry.
- **`movement.officer_fallback_name`**, **`movement.accept_label`**, **`movement.decline_label`** — reused as-is by `client/partnership.lua`'s leash-style request prompt, instead of that file minting `partnership.*` copies of the same three strings.

If you're adding a message and it's similar-but-not-identical to one of the above, don't reuse the key — read the "similar sentences kept separate on purpose" note below first.

### Similar sentences are sometimes kept as separate keys on purpose

A few pairs of messages read almost the same (e.g. "Thermal vision on." / "Thermal vision off.", or two different "kennel placement failed" messages for two genuinely different reasons) but are kept as fully separate, complete-sentence keys rather than one key with a filled-in blank (like `"Thermal vision %s."` with `"on"`/`"off"` substituted in). Two different reasons show up in practice:

1. **A state word like "on"/"off" doesn't translate the same way in every language** — the word order or grammar around it can change depending on the state, so one template can't safely cover both.
2. **Two messages that read similarly are actually reporting two different failure causes** — collapsing them into one generic message would make it harder for a player to tell what's actually wrong, and harder for a translator to phrase correctly.

If you're tempted to merge two keys to reduce duplication, check which of these reasons applies first — if either does, keep them separate.

## How to add a new locale key

This is the standard process for any new player-facing text, whether it's part of a brand-new feature or a change to an existing one:

1. Read the file you're changing and list every piece of text a player would actually see: notification titles/descriptions, target/menu labels, keybind descriptions, command-usage text shown in chat or F8. Don't touch `print()` calls — those are developer/admin console output, not player-facing (see "What was deliberately NOT touched" below).
2. Before inventing a new key, check the "Shared keys" list above and search `en.json` for your exact English sentence. If it already exists, reuse that key instead of creating a near-duplicate.
3. Add the new key to `locales/en.json`, under a top-level group named after the file it belongs to (or `common` if it's shared — see above). Use `snake_case` for the key name, and name it after what the message *means*, not its exact English wording (e.g. `no_vehicle_nearby`, not `error_1`) — the key is what a translator's work is anchored to, and it should stay stable even if the English wording changes later.
4. In the Lua file, replace the hardcoded string with `locale('group.key')`. If the message needs a dynamic value (a player's name, a number, and so on), don't build it with Lua's `..` string concatenation — put a `%s` or `%d` placeholder in the JSON string itself and pass the value as an extra argument: `locale('group.key', someValue)`.
5. Check your work: `locales/en.json` must still be valid JSON (`python3 -c "import json; json.load(open('locales/en.json'))"` should run with no error), and `luac5.4 -p` / `luacheck` on the Lua file(s) you changed should still be clean.
6. No `fxmanifest.lua` change is needed for a new key inside `en.json` — see "Manifest requirements" below for the one thing that *does* need a manifest change (adding a whole new language file).

## How the `locale()` function itself works (verified against ox_lib)

This resource uses `ox_lib`'s locale system, not something custom-built. A few mechanical details worth knowing:

- The file must be **strictly valid JSON** — no comments, no trailing commas. That's why this guidance lives in a separate `README.md` instead of comments inside `en.json` itself.
- Nested groups in the JSON (like `"combat": { "no_target_in_range": "..." }`) get automatically flattened into dotted keys (`combat.no_target_in_range`) when the file loads — you don't need to do anything extra for this.
- `locale(key, ...)` is available as a plain global function anywhere in this resource's Lua code, with no extra setup call needed — `fxmanifest.lua` already declares the dependency that makes this work (see "Manifest requirements" below).
- A JSON string value can reference another key with `${other.key}` — this gets resolved once, when the locale file loads, to that other key's already-resolved text. Used once so far, in `radial.menu_open_label`, which is set to `"${common.notify_title}"` instead of a fourth independent copy of "K9 Unit".

## Manifest requirements (`fxmanifest.lua`)

This is already done and doesn't need repeating for new keys, but it matters if you ever add a second language file:

- `fxmanifest.lua` declares `ox_lib 'locale'` and `'@ox_lib/init.lua'`, which is what makes the bare `locale()` function available.
- It also explicitly lists `'locales/en.json'` in its `files { ... }` block, by exact filename rather than a wildcard pattern like `'locales/*.json'` (a wildcard was found to behave unexpectedly here, per that file's own comment).
- **If you add a second language file** (e.g. `es.json`), you must add its own explicit `'locales/es.json'` line to that same `files { ... }` block — it will not be picked up automatically.

## What was deliberately NOT touched

- **`print()` calls** anywhere in this resource are developer/admin console output, not something a player ever sees, and are intentionally left as plain hardcoded strings.
- **Data sent to the UI that's a number or boolean** (health percentages, timers, on/off flags) obviously isn't text and was never a candidate for a locale key.

## History

This migration happened gradually, file by file, across many separate work sessions, starting from two reference files (`client/vision.lua`, `client/vehicle.lua`) and ending with every client and server file checked. The full step-by-step account of which pass migrated which file lived in earlier versions of this document; it's not repeated here because it was the exact thing that went stale and self-contradictory as work continued in parallel (see "Status" above). If you need that level of detail — for example, to understand why a specific key is named the way it is — `git log` on this file and on `locales/en.json` has the real, timestamped record.
