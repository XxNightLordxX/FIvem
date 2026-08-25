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

**Update (third migration pass):** `client/main.lua`, `client/movement.lua`,
`client/agility.lua`, and `client/inventory.lua` are now also migrated (new
`movement.*`/`agility.*`/`inventory.*` groups below, plus one new `common.*`
key — see "The `common.no_k9_access` promotion" below). These were chosen
as the highest-traffic remaining files: `client/main.lua` holds
`BasicBarkSounds`, one of only five features shipping `true` by default, so
its strings are live on every install today (its bark-playback path itself
has no player-facing strings — only its `DenyK9UIAccess()` helper did).
`client/movement.lua` is this resource's largest client file and owns the
leash consent handshake, the two door-interaction actions, and the
certify/revoke `ox_target` entry points, all of which show `lib.notify`/
`lib.alertDialog` text or `ox_target` labels. `client/agility.lua` and
`client/inventory.lua` are smaller but each had at least one real
player-facing string worth closing out in the same pass.

**Update (fourth migration pass):** `client/partnership.lua`,
`client/defense.lua`, `client/fetch.lua`, and `client/propattachment.lua`
are now also migrated (new `partnership.*`/`defense.*`/`fetch.*`/
`propattachment.*` groups below — see their own sections for the full
per-key breakdown, the cross-file `movement.*` key reuse in
`client/partnership.lua`, and the three out-of-scope duplicate findings in
`client/radial.lua`/`server/partnership.lua`/`server/combat.lua`).
`client/hud.lua` was also reviewed this pass and confirmed to need **no**
migration — see its own section below and the updated "What's left" count.

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

### The `common.no_k9_access` promotion (third migration pass)

Done, per the plan the paragraph above laid out: `DenyK9UIAccess()`
(`client/main.lua`) now calls `locale('common.no_k9_access')`, and every
verbatim copy of `'You cannot use K9 features right now.'` found across
this pass's four files was pointed at the SAME key rather than minted
per-file — `client/movement.lua` (`K9Sit()`, `RequestLeashAttach()`,
`ScratchAtDoor()`, `NudgeDoor()`, four call sites) and `client/agility.lua`
(`TryVault()`, one call site). Confirmed by grep before this pass:
`client/tracking.lua` also hardcodes this exact string — it is NOT touched
by this change (out of scope, a different file), but whoever migrates it
next should point it at `common.no_k9_access` too rather than minting a
fourth copy.

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

### `movement.*` / `agility.*` / `inventory.*` (added in the third migration pass)

`movement.*` (`client/movement.lua`, 20 leaf keys): the camera
first/third-person pair (`camera_first_person`/`camera_third_person`, kept
as two full-sentence keys rather than one templated "%s-person view."
string — same "on/off state words don't translate uniformly" reasoning the
"Why no interpolation was used for the vision on/off strings" section below
already gives, applied here to a different on/off-shaped pair), the leash
consent-handshake strings (`leash_request_header`/`leash_request_content`
— the latter is this pass's only `%s`-interpolated string,
`locale('movement.leash_request_content', fromName)` — plus
`accept_label`/`decline_label` for the `lib.alertDialog` buttons), the
leash lifecycle notifications (`already_leashed`, `leash_request_sent`,
`leash_now_leashed`, `leash_now_anchoring`, `leash_detached`,
`leash_detached_partner_disconnected`, `leash_snapped_too_far`), three
`ox_target` labels (`attach_leash_target_label`,
`certify_handler_target_label`, `revoke_certification_target_label`), the
door-interaction error/label strings (`nothing_to_scratch`,
`nothing_to_nudge`, `scratch_door_target_label`, `nudge_door_target_label`),
and the camera keybind description (`toggle_camera_keybind_label`). Also
new: `officer_fallback_name` (`"Officer #%d"`) — the leash-request prompt's
fallback display name for a target whose `GetPlayerName` isn't resolvable
used to be built with Lua string concatenation (`'Officer #' .. fromServerId`)
directly in `client/movement.lua`; that's exactly the untranslatable
pattern this whole migration exists to close (see "Format" below), so it's
now `locale('movement.officer_fallback_name', fromServerId)` like every
other dynamic value here, not a special case.

**Deliberately kept separate, not collapsed:** `leash_detached` ("Leash
detached.") and `leash_detached_partner_disconnected` ("Leash detached —
your partner disconnected.") look like a base string plus an appended
reason clause, which might tempt a future editor into one templated key
with an optional `%s` reason argument. They're kept as two independent
full-sentence keys instead, same reasoning as the vision on/off pair and
`kennel.placement_failed`'s own non-duplication note above: whether and how
a reason clause attaches to a sentence varies by language, so a template
that assumes English's "base sentence + dash + reason" structure would
translate awkwardly or incorrectly elsewhere. Revisit only with a concrete
translator complaint, not preemptively.

`agility.*` (`client/agility.lua`, 1 leaf key): `vault_keybind_label`, the
Advanced Agility vault's `RegisterKeyMapping` description. `TryVault()`'s
own `lib.notify` denial message reuses `common.no_k9_access` (see above) —
no new key needed for it.

### `partnership.*` / `defense.*` / `fetch.*` / `propattachment.*` (fourth migration pass)

`partnership.*` (`client/partnership.lua`, 9 leaf keys): `already_partnered`,
`partner_request_sent` (the two `RequestPartnerUp()` notifications),
`partner_request_header`/`partner_request_content` (the incoming
`lib.alertDialog` prompt — `partner_request_content` is `%s`-interpolated
with the requester's display name, `locale('partnership.partner_request_content', fromName)`),
`now_partnered_as_handler`/`now_partnered_as_k9` (the
`partnershipEstablished` success notify — kept as two full-sentence keys
for the same "on/off-shaped state words don't translate uniformly" reasoning
`vision.*`'s thermal/night pair and `movement.camera_first_person`/
`camera_third_person` already established, applied here to a different
boolean-shaped pair), `ended_generic`/`ended_with_reason` (the
`partnershipEnded` notify — `ended_with_reason` is `%s`-interpolated with
the raw `reason` string rather than rebuilt via `..`, replacing what was
previously `('Partnership ended (%s).'):format(reason)`), and
`partner_up_target_label` (the "Partner Up" `ox_target` option label).

**Cross-file key reuse, not a new duplicate:** `client/partnership.lua`'s
leash-request-shaped fallback name (`'Officer #' .. fromServerId`, the
concatenation shape this migration's own convention exists to close — see
"Format" above) and its accept/decline `lib.alertDialog` labels are
byte-for-byte identical to `client/movement.lua`'s own already-migrated
`movement.officer_fallback_name`/`movement.accept_label`/
`movement.decline_label`. Rather than mint
`partnership.officer_fallback_name`/`accept_label`/`decline_label` as a
third near-duplicate, `client/partnership.lua` now calls
`locale('movement.officer_fallback_name', fromServerId)` /
`locale('movement.accept_label')` / `locale('movement.decline_label')`
directly — no new keys added for these three. These stay under the
`movement.*` group rather than being promoted to `common.*` because
promotion would require also editing `client/movement.lua` to point at a
new `common.*` key, and that file is owned elsewhere / out of scope for
this pass. Whoever next touches both files should consider promoting all
three to `common.*` in one change that updates every call site at once,
the same way `common.no_k9_access` was promoted in the third pass.

**Found, NOT touched (out of scope, flagged for the owning file's next
migration):** `client/radial.lua` (owned elsewhere) hardcodes its own
`label = 'Partner Up'` for its Partner Up/Break Partnership radial entry —
verbatim identical to this pass's new `partnership.partner_up_target_label`.
Whoever migrates `client/radial.lua` should reuse
`partnership.partner_up_target_label` rather than minting a fourth copy.
Separately, `server/partnership.lua` (also owned elsewhere) has its own
`NotifyPlayer(src, 'Partner request sent.', 'inform')` (verbatim identical
to this pass's `partnership.partner_request_sent`) and its own
`already_partnered = 'One of you is already partnered with someone else.'`
rejection string, which reads similarly to but is NOT identical wording to
this pass's `partnership.already_partnered` ("You are already partnered.")
— same "different failure cause, different sentence, don't collapse" reasoning
as `kennel.placement_failed`'s own non-duplication note. Whoever migrates
`server/partnership.lua` should reuse `partnership.partner_request_sent`
for the first (identical text) but give the second its own new key (do not
reuse `partnership.already_partnered` for a different sentence).

`defense.*` (`client/defense.lua`, 5 leaf keys): `handler_under_attack`
(the handler-down trigger notify, `%s`-interpolated with the configured
confirm keybind — `locale('defense.handler_under_attack', Config.Combat.HandlerDownDefense.confirmKey)`;
this string's "...or use the radial menu" clause is preserved verbatim,
unchanged in meaning, per this pass's own instruction not to touch that
claim's truth value while translating it — see this file's own
"WRONG-INSTRUCTION FIX (QA follow-up)" comment for why that clause is
currently true), `no_active_alert`, `already_engaged`,
`no_hostile_detected` (the three `ConfirmHandlerDownDefense` rejection
notifies), and `confirm_keybind_label` (the `RegisterKeyMapping`
description). **Found, NOT touched:** `server/combat.lua` (owned
elsewhere) has its own `already_engaged = 'You are already engaged with
another target.'` in a rejection-reason table — verbatim identical to this
pass's new `defense.already_engaged`. Flagged for whoever migrates
`server/combat.lua` to reuse `defense.already_engaged` rather than minting
a duplicate (these two are the same client-visible sentence for a related
concept — "already fighting something" — reported from two different
files, unlike the kennel/partnership cases above which are genuinely
different sentences).

`fetch.*` (`client/fetch.lua`, 5 leaf keys): `prop_load_failed`,
`throw_failed`, `carry_failed` (three distinct `lib.notify` failure
reasons — a load failure, a spawn failure, and an attach failure — kept
separate, not templated, same reasoning as `inventory.*`'s six `reason_*`
keys), and `pickup_target_label`/`deliver_target_label` (the "Pick Up
Ball"/"Deliver Fetch Item" `ox_target` option labels). None of these five
were found duplicated elsewhere in this resource (confirmed by grep before
minting).

`propattachment.*` (`client/propattachment.lua`, 1 leaf key):
`vest_prop_load_failed` (the vest-attach failure notify — this file's
`print()` fallback-model breadcrumb one line below it is server-console
diagnostics, not player-facing, and is correctly left untouched). Not
duplicated elsewhere (it reads similarly to `fetch.prop_load_failed`/
`kennel.prop_load_failed` — "X prop failed to load" — but each names a
different X for a different feature and none are verbatim-identical text,
so none were collapsed).

`client/hud.lua` was reviewed for this pass and found to need **no**
`locale()` migration at all: every value it sends via `SendNUIMessage`
('hud:updateVitals') is a number or boolean (health/stamina/hunger/thirst/
wellbeing fields), except `xpTier.label`, which is a pass-through string
already sourced from `client/progression.lua`'s `GetCurrentXPTier()` (that
file's own responsibility to localize, not this one's — `client/hud.lua`
never constructs that string itself). There is no `lib.notify`,
`ox_target` label, `RegisterKeyMapping`, or any other hardcoded
player-facing string anywhere in this file (confirmed by grep, not just a
skim) — it is pure NUI data-plumbing, the same class of file
`client/screenfx.lua`/`client/audio.lua` were found to be in the second
pass.

`inventory.*` (`client/inventory.lua`, 8 leaf keys): `open_gear_target_label`
(the "Open K9 Gear" `ox_target` option), `unable_to_open_generic` (the
fallback shown when `openK9Inventory`'s callback returns an unrecognized/nil
`reason`), and six `reason_*` keys (`reason_feature_disabled`,
`reason_invalid_target`, `reason_no_access`, `reason_too_far`,
`reason_not_authorized`, `reason_stash_failed`) for
`K9_INVENTORY_REASON_MESSAGES`'s six distinct rejection causes.

**Deliberately kept separate, not collapsed (the exact trap this file's own
"What's left" section warns about for `server/kennel.lua`):** all six
`reason_*` strings, plus `unable_to_open_generic`, read similarly ("K9 gear
access is disabled...", "That is not a working K9.", "...not currently
certified...", "...too far away...", "...not authorized...", "Unable to
open K9 gear right now." / "Unable to open K9 gear."), but each is a
genuinely distinct failure cause reported by a different `reason` value
from the server's `openK9Inventory` callback (feature off, wrong target,
uncertified target, distance, caller authorization, and a stash-open
failure, respectively), plus a separate generic fallback for an
unrecognized/nil reason. None were merged into one templated "Unable to
open K9 gear: %s" message — doing so would erase the distinction between
"this is disabled" and "you're not allowed," which matters for a player
trying to understand what to do next, and would make each cause
individually untranslatable as a complete sentence.

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

As of this (fourth) pass, **11 of roughly 48 Lua files** in this
resource's `client/` + `server/` trees have actually needed a `locale()`
migration — `client/vision.lua`, `client/vehicle.lua`, `client/kennel.lua`,
`client/main.lua`, `client/movement.lua`, `client/agility.lua`,
`client/inventory.lua`, and now `client/partnership.lua`,
`client/defense.lua`, `client/fetch.lua`, and `client/propattachment.lua`.
Five files (`client/screenfx.lua`, `client/audio.lua`,
`client/proximityaudio.lua`, `client/recall.lua`, and now `client/hud.lua`)
have been checked and confirmed to have **no player-facing strings at
all**, so they need no `locale()` calls — don't re-check them again from
scratch, but do re-check if you add new player-facing UI to any of them
later. That's 16 of ~48 files actually checked one way or the other.

Every other file — `client/radial.lua`, `client/tracking.lua`,
`client/search.lua`, `client/medkit.lua`, `client/wellbeing.lua`,
`client/progression.lua`, `client/combat.lua`, `client/bonetool.lua`,
`client/exports.lua`, and every file under `server/` — is UNCHECKED by
this pass and should be assumed to still have 100% hardcoded English for
any player-facing string it contains (server-side strings sent to players
via `lib.notify`/`exports.qbx_core:Notify`/similar are just as in scope as
client-side ones; only `print()`/comments are out of scope). This file
establishes the pattern and the shared `common.*` keys; it does not claim
to have finished the job.

**Notes for whoever migrates these specific still-unchecked files, found
by this pass while grepping for duplicates (see the fourth-pass sections
above for full detail):**
- `client/radial.lua`: hardcodes `label = 'Partner Up'` verbatim identical
  to the now-migrated `partnership.partner_up_target_label` — reuse that
  key, don't mint a new one.
- `server/partnership.lua`: hardcodes `'Partner request sent.'` verbatim
  identical to `partnership.partner_request_sent` (reuse it), and a
  DIFFERENT, NOT-identical `already_partnered = 'One of you is already
  partnered with someone else.'` rejection string that must NOT be
  collapsed into `partnership.already_partnered` ("You are already
  partnered.") — give it its own new key.
- `server/combat.lua`: hardcodes `already_engaged = 'You are already
  engaged with another target.'` verbatim identical to the now-migrated
  `defense.already_engaged` — reuse that key.

**Note for whoever migrates `client/tracking.lua`:** confirmed by grep
during the third pass, that file also hardcodes `'You cannot use K9
features right now.'` verbatim — point it at `common.no_k9_access` (now a
real, migrated key — see "The `common.no_k9_access` promotion" above)
rather than minting a duplicate.

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

## Manifest status (`fxmanifest.lua` is out of scope for this file's own
changes, but its state is worth recording accurately here)

DONE, as of some pass before this one (this section used to say the
opposite — "not made here," describing a gap — which was true when
written and is exactly the kind of stale doc this project's own convention
warns against carrying forward silently). `fxmanifest.lua` already has
`ox_lib 'locale'` and `'@ox_lib/init.lua'` in `shared_scripts` (needed for
the bare `locale()` global to work), AND already lists `'locales/en.json'`
explicitly in its `files { ... }` block (listed by exact name, not a
`'locales/*.json'` glob — see that file's own inline comment on why: a
`files{}` glob was found to behave recursively, which is the subject of an
open upstream replacement proposal, so every entry in that manifest is
explicit instead). Whoever adds a SECOND locale file (e.g. `es.json`) must
add its own explicit `'locales/es.json'` line to that same block — it will
NOT be picked up automatically by the existing `'locales/en.json'` entry.
