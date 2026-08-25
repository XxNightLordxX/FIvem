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

**Update (fifth migration pass):** `client/radial.lua`, `client/search.lua`,
`client/tracking.lua`, `client/wellbeing.lua`, `client/progression.lua`,
`client/medkit.lua`, and `client/bonetool.lua` are now also migrated (new
`radial.*`/`search.*`/`tracking.*`/`wellbeing.*`/`progression.*`/`medkit.*`/
`bonetool.*` groups below, plus one new `common.*` key — see "The
`common.too_far_from_k9` promotion" in each of `wellbeing.*`/`medkit.*`'s
own sections below). This pass closes out both of the fourth pass's own
flagged reuse opportunities: `client/radial.lua`'s `'Partner Up'` label now
calls `locale('partnership.partner_up_target_label')` instead of minting a
duplicate, and `client/tracking.lua`'s `DenyK9UIAccess`-shaped rejection now
calls `common.no_k9_access` instead of hardcoding a fourth copy of "You
cannot use K9 features right now." — see each file's own section below for
the exact call sites. `client/radial.lua`'s own opener item label is the
first use of ox_lib's `${other.key}` cross-reference syntax anywhere in this
resource (`radial.menu_open_label` = `"${common.notify_title}"`) rather than
a fourth "K9 Unit" string under a new name — see the "Format" section below
for what that syntax does. `client/bonetool.lua`'s strings are kept under
their own `bonetool.*` group deliberately, NOT folded into `common.*` or any
other feature group: per this file's own task instructions, that file is a
dev-only diagnostic tool (a bone-index sweep), and its strings guide a human
through using the tool rather than describing anything a normal player ever
sees — a translator working through this resource's locale keys should be
able to tell at a glance that `bonetool.*` is tooling, not in-fiction UI,
without having to open the Lua file to find out. **A THIRD concatenation
instance was found and fixed**, per this pass's own explicit instruction to
expect one: `client/bonetool.lua`'s preview-label draw code built
`labelText .. ' (TEST PROP ATTACHED)'` — the exact same "build a
player/dev-facing string by appending a literal suffix to a dynamic value
with `..`" pattern the two earlier passes' own `'Officer #' .. serverId`
findings already exist to close. Fixed the same way this migration fixed
those: not a template + concatenation, but two independent full-sentence
keys (`bonetool.bone_index_label` / `bonetool.bone_index_label_test_attached`),
matching the established "on/off-shaped state words don't collapse cleanly
into one template" reasoning already used for `movement.camera_first_person`/
`camera_third_person` and `partnership.now_partnered_as_handler`/
`now_partnered_as_k9`.

**Update (sixth migration pass, coder-frontend, `client/combat.lua`):**
`client/combat.lua` — previously named explicitly in "What's left" below as
UNCHECKED — is now migrated. It had exactly one hardcoded player-facing
string, `lib.notify({ title = 'K9 Unit', description = 'No eligible target
in range.', type = 'error' })`, repeated verbatim at three call sites
(`RequestBiteHold`/`RequestTakedown`/`RequestDrag`'s own "no candidate found
in range" rejection). The title is now `locale('common.notify_title')`
(reusing the existing shared key, not a fourth "K9 Unit" copy, same
convention every other file's own notify title already follows); the
description is a single new key, `combat.no_target_in_range`, shared across
all three call sites since the text is genuinely identical for all three
(same "one key, multiple call sites" precedent as `common.no_k9_access`).
`client/combat.lua`'s OTHER player-facing text — every `lib.notify` call
inside its `RegisterNetEvent` handlers — does not exist: those handlers
apply native side effects only (`DisableControlAction`/
`SetEntityCanBeDamaged`/etc.), never a notification, so there was nothing
further to migrate in this file. `client/defense.lua` was already fully
migrated as of the fourth pass (`defense.*`, above) and needed no further
work this pass.

**Update (server migration pass — first `server/` files, recounted directly
against the tree rather than assumed from the sixth pass's client-only
tally):** eight `server/*.lua` files now call `locale()` for real
player-facing text — `server/main.lua`, `server/kennel.lua`,
`server/partnership.lua`, `server/tenure.lua`, `server/certifications.lua`,
`server/recall.lua`, `server/inventory.lua`, and `server/wellbeing.lua`.
This section records what each added, since the sixth pass's own "What's
left" count below (18 of ~48, all client) predates every one of these and is
corrected below.

- **`leash.*` (`server/main.lua`, 10 leaf keys) — a NEW top-level group, not
  folded into `movement.*`:** `feature_disabled`, `invalid_target`,
  `already_leashed`, `too_far`, `pending_request_exists`, `request_sent`,
  `request_no_longer_valid_self`, `request_no_longer_valid_initiator`,
  `request_declined`, `reject_fallback`. This is the SERVER's own leash
  request/rejection vocabulary — a separate concern from `movement.*`'s
  already-migrated CLIENT-side leash strings (the consent-prompt UI, the
  lifecycle notifies like `leash_now_leashed`/`leash_detached`). Kept as its
  own group rather than merged into `movement.*` because the two files own
  genuinely different message sets for the same feature (client UI text vs.
  server authorization/rejection text), the same "different file, different
  concern" reasoning `bonetool.*` already established for staying separate
  from `common.*`. Three of the ten leaf keys are direct reuses of existing
  `common.*` keys inside the same rejection-message lookup table
  (`common.target_no_longer_online`, `common.no_k9_party`,
  `common.k9_not_certified`, `common.handler_not_in_department`) rather than
  new `leash.*` duplicates — confirmed by reading the table before writing
  this, not assumed.
- **`kennel.*` (`server/kennel.lua`, 11 new leaf keys added to the existing
  group):** `not_authorized_to_deploy`, `already_active_deployed`,
  `placement_already_in_progress`, `placement_timed_out`,
  `placement_failed_unconfirmed`, `placement_failed_wrong_model`,
  `placement_failed_too_far`, `placement_failed_already_claimed`,
  `deployed_success`, `not_owner`, `picked_up_success`. **This resolves the
  exact non-duplication note this file previously carried** (see "What's
  left" history below): the server-side placement-failure messages are
  genuinely distinct sentences from the client's own `kennel.placement_failed`
  ("Kennel placement failed — the object could not be confirmed." vs. the
  client's plain "Kennel placement failed.") and were correctly given their
  own new leaf keys under the same `kennel.*` group rather than reusing
  `kennel.placement_failed` for a different sentence — confirmed by reading
  `server/kennel.lua`'s actual `locale(...)` call sites, not assumed from the
  old note's plan.
- **`partnership.*` (`server/partnership.lua`, 13 new leaf keys added to the
  existing group):** `feature_disabled`, `invalid_target`,
  `reject_already_partnered`, `too_far`, `pending_request_exists`,
  `request_no_longer_valid_self`, `request_no_longer_valid_initiator`,
  `request_declined`, `setup_busy`, `establish_error`, `break_error`,
  `not_partnered_with_anyone`, `reject_fallback`. **This also resolves a
  previously-flagged note exactly as planned:** the server's own
  `'Partner request sent.'` reuses the existing `partnership.partner_request_sent`
  key (confirmed identical text, not duplicated), while the server's
  DIFFERENT "one of you is already partnered with someone else" rejection got
  its own new key, `partnership.reject_already_partnered` — NOT collapsed
  into the client's `partnership.already_partnered` ("You are already
  partnered."), which remains a different sentence for a different caller
  context. Confirmed by reading the actual call sites.
- **`tenure.*` (`server/tenure.lua`, 1 leaf key) — a NEW top-level group:**
  `milestone_reached` ("Your partnership has reached a new tenure
  milestone."), sent to both the handler and the K9 on a milestone grant.
- **`certifications.*` (`server/certifications.lua`, 25 leaf keys) — a NEW
  top-level group:** every `NotifyPlayer(...)` string in the file's
  grant/revoke/offline-revoke/job-change-auto-revoke paths and command-usage
  errors — e.g. `grant_success_granter`, `grant_success_target`,
  `not_authorized_to_certify`, `target_already_certified`,
  `target_too_far_to_certify`, `revoked_notice_job_change` (`%s`-interpolated
  with the department), `invalid_department` (`%s`-interpolated),
  `target_online_use_decertify_command` (`%d`-interpolated with a server id),
  and three `usage_*` command-help strings. Not cross-checked leaf-by-leaf
  against every other group for duplicate English text by this pass — flag
  for a future pass if a near-duplicate turns up.
- **`recall.*` (`server/recall.lua`, 6 leaf keys) — a NEW top-level group:**
  `partnership_unavailable`, `not_partnered_to_recall`, `partner_not_online`,
  `not_engaged`, `recall_issued`, `recalled_notice`.
- **`inventory.*` (`server/inventory.lua`, 1 new leaf key added to the
  existing group):** `stash_label` ("K9 Gear") — the `ox_inventory:RegisterStash`
  display label, previously a hardcoded string passed straight to that
  export call.
- **`wellbeing.*` (`server/wellbeing.lua`, 2 new leaf keys added to the
  existing group):** `calm_down_on_cooldown`, `calm_down_success` — the
  `/k9calmdown`(-shaped) command's own rejection/success text.

**SUPERSEDED WITHIN THE HOUR — read this before acting on the list below.**
Four of the six files named here (`server/fetch.lua`, `server/propattachment.lua`,
`server/medkit.lua`, `server/admin.lua`) were migrated by a concurrent pass
immediately after this section was written, and are NO LONGER outstanding:
fetch now has 25 `locale()` call sites, admin 25, propattachment 9, medkit 2.
`en.json` is at 275 leaf keys, not 223, cross-checked to zero missing and
zero unused in both directions.

Only TWO of the six remain genuinely outstanding: **`server/combat.lua`**
(0 `locale()` calls) and **`server/bonetool.lua`** (0). The `already_engaged`
reuse note below still stands for combat.lua.

The original six-file list, kept for its per-file detail on what each
hardcodes:** `server/combat.lua`
(the largest gap — a dozen-plus hardcoded strings across `BiteAndHold`/
`NonLethalTakedown`/`PropDragging`'s reject-message table and success/status
notifies, PLUS a hardcoded `'K9 Unit — Non-Compliance'` title/description
built with `..`/`:format(...)` and sent via a raw `TriggerClientEvent('ox_lib:notify', ...)`
table rather than `NotifyPlayer`; note its `already_engaged` rejection text
is byte-identical to the already-migrated `defense.already_engaged` and
should reuse that key, not mint a new `combat.*` one, when this file is
migrated), `server/medkit.lua` (`'K9 treated.'`/`'Your K9 has been treated.'`),
`server/fetch.lua` (about 20 hardcoded strings across throw/carry/deliver/
recall), `server/propattachment.lua` (9 hardcoded strings across
attach/remove), `server/admin.lua` (a handful of command-usage/authorization
strings reached via its own local `NotifyPlayer` delegating wrapper — see
`tests/README.md`'s coverage notes on that wrapper for why it's a deliberate
non-recursive shadow, not a leftover), and `server/bonetool.lua` (a few
similar command-usage/authorization strings through its own equivalent
wrapper).

**Eight more `server/*.lua` files were checked this pass and confirmed to
have ZERO player-facing text to migrate** (grepped for `NotifyPlayer(`,
`lib.notify`, and any `TriggerClientEvent` carrying an inline literal string,
not just skimmed): `server/defense.lua` and `server/tracking.lua` and
`server/search.lua` and `server/progression.lua` all send data-only
`TriggerClientEvent`s (netIds, tier tables, alert-tier names) whose text is
already owned and localized client-side (`defense.*`/`tracking.*`/`search.*`/
`progression.*` in the client migration passes above); `server/entities.lua`,
`server/exports.lua`, `server/notify.lua` (the file `server/admin.lua`'s and
`server/bonetool.lua`'s own `NotifyPlayer` wrappers delegate into — it is
itself pure plumbing with no literal player text of its own; the title/
description strings it receives are the CALLER's job to localize), and
`server/cooldowns.lua` are pure infrastructure with no `TriggerClientEvent`
call anywhere in them.

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

### `radial.*` / `search.*` / `tracking.*` / `wellbeing.*` / `progression.*` / `medkit.*` / `bonetool.*` (fifth migration pass)

`radial.*` (`client/radial.lua`, 23 leaf keys): every `lib.addRadialItem`/
`lib.registerRadial` item `label` in this file, plus the two
"no nearby candidate" `lib.notify` descriptions
(`no_leash_candidate`/`no_partner_candidate`). Full leaf list: `sit_label`,
`bark_label` (shared by both the plain-Bark item and, when
`AdvancedBarkRadial` is on, the Bark submenu's own opener item — same
literal "Bark" either way, one key), `leash_toggle_label`,
`no_leash_candidate`, `vehicle_toggle_label`, `track_scent_label`,
`track_blood_label`, `track_gunpowder_label`, `bite_hold_toggle_label`,
`takedown_label`, `drag_toggle_label`, `break_partnership_label`,
`no_partner_candidate`, `defense_menu_label`, `defense_bite_label`,
`defense_takedown_label`, `fetch_menu_label`, `fetch_throw_label`,
`fetch_recall_label`, `toggle_vest_label`, `deploy_kennel_label`,
`recall_label` (the "Recall K9" item — do not confuse with
`fetch_recall_label`, a different item/feature), and `menu_open_label`.
**`k9_partner_up`'s label does NOT get a new key** — it calls
`locale('partnership.partner_up_target_label')` directly, closing the
fourth pass's own flagged reuse opportunity (see that pass's "Found, NOT
touched" note, now resolved). **`menu_open_label`'s value is
`"${common.notify_title}"`**, not a fourth independent "K9 Unit" string —
this is the first use anywhere in this resource of ox_lib's own
`${other.key}` cross-reference syntax (see "Format" above), chosen because
this opener's label is byte-for-byte the same "K9 Unit" text every
`lib.notify` title in this resource already uses, and every other
`lib.notify` call this file makes was pointed at the existing
`common.notify_title` key rather than a per-file title copy, matching every
other file this migration has touched.

`search.*` (`client/search.lua`, 9 leaf keys): `nothing_to_search`,
`progress_vehicle_label`/`progress_person_label` (the `lib.progressBar`
label, kept as two full sentences rather than one `"Searching %s..."`
template interpolated with a bare noun — same "a state/category word
doesn't translate uniformly by simple substitution" reasoning already
established for `vision.thermal_on`/`thermal_off` and every other on/off- or
category-shaped pair in this file), `failed` (used at BOTH of this file's
two "the search could not be completed" call sites — the `reason ==
'search_failed'` branch and the outer `pcall` failure branch — confirmed
byte-identical text before pointing both at one key rather than two),
`generic_denied`, `contraband_found`, `nothing_found`, and
`vehicle_target_label`/`person_target_label` (the "Search Vehicle"/"Search
Person" `ox_target` option labels). None of these nine were found
duplicated elsewhere in this resource (confirmed by grep before minting).

`tracking.*` (`client/tracking.lua`, 4 leaf keys): `already_tracking`
("Already tracking something — stop first.") and `starting_in_progress`
("Already starting a track — please wait.") are the two similar-looking but
genuinely distinct rejection messages this file's task instructions flagged
by name — kept separate per this migration's standing "distinct failure
causes stay distinct messages" rule, same reasoning as
`inventory.*`'s six `reason_*` keys. Also `nothing_to_track` and
`trail_lost_water`. **`StartTrack()`'s `CanShowK9UI()` rejection does NOT
get a new key** — it now calls `common.no_k9_access` directly, closing the
exact reuse this file's own hardcoded copy was flagged for back in the
third pass's own "What's left" notes (confirmed by grep: this was the
fourth verbatim copy of "You cannot use K9 features right now." found
across this resource's migration so far, now pointed at the shared key
instead of becoming a fifth).

`wellbeing.*` (`client/wellbeing.lua`, 18 leaf keys): the four
distraction/hesitation state-transition notifies (`distracted`, `refocused`,
`hesitating`, `settled`), the "Pet K9"/"Feed K9" `ox_target` labels
(`pet_target_label`/`feed_target_label`) and their success notifies
(`pet_success`/`feed_success`), five `reason_*` keys for the Pet/Feed
rejection table (`reason_feature_disabled`, `reason_invalid_target`,
`reason_on_cooldown`, `reason_no_item`, `reason_generic` — the unrecognized-
reason fallback), and for the separate meat-bait/whistle distraction path:
`distraction_used`, `reason_invalid_item`, `reason_use_generic` (shared by
BOTH that table's own `invalid_target` entry and its unrecognized-reason
fallback — confirmed byte-identical text before collapsing to one key,
same as `search.failed` above), and `reason_no_meat_bait`/`reason_no_whistle`
(the two distinct "you don't have the item" messages passed in as
`failDescription` by the `/k9meatbait`/`/k9whistle` commands respectively —
kept apart since a future translator might reasonably want each item named
differently depending on grammatical gender/article, even though the
underlying `no_item` reason code is shared).

### The `common.too_far_from_k9` promotion (fifth migration pass)

`client/wellbeing.lua`'s Pet/Feed rejection table and `client/medkit.lua`'s
Treat rejection table each independently had `too_far = 'Get closer to the
K9 first.'` — byte-for-byte identical text, confirmed by grep before
minting anything, in two different files THIS SAME PASS happened to touch
together. Rather than mint `wellbeing.reason_too_far` and
`medkit.reason_too_far` as two drifting copies of the same sentence (the
exact anti-pattern this migration's `common.*` group exists to prevent —
see the original `common.notify_title`/`common.not_k9_model` reasoning at
the top of this file), both now call `locale('common.too_far_from_k9')`
directly. Not the same sentence as `inventory.reason_too_far` ("You are too
far away to access that K9's gear.") — that one stays its own key, a
longer, feature-specific sentence for a different rejection context, not a
verbatim duplicate.

`progression.*` (`client/progression.lua`, 1 leaf key): `tier_up`
("Your K9 has reached the %s tier!" — `%s`-interpolated with
`tostring(newTier.label)`, replacing the previous
`('...'):format(...)`-built string; the format/interpolation mechanism was
already correct here, only the literal moved into `locales/en.json`). This
is the only player-facing string anywhere in this file — everything else is
server-authoritative state bookkeeping with no local notify/label of its
own, confirmed by reading the file in full per this migration's own
step-1 checklist.

`medkit.*` (`client/medkit.lua`, 10 leaf keys): `treated_success`, nine
`reason_*`/lookup keys for the Treat-K9 rejection table
(`reason_feature_disabled`, `reason_no_access`, `reason_invalid_target`,
`reason_target_dead`, `reason_on_cooldown`, `reason_no_item`,
`reason_treatment_in_progress`, `reason_medkit_failed` — this last one
shared by BOTH the table's own `medkit_failed` entry and the unrecognized-
reason fallback, confirmed byte-identical before collapsing, same pattern
as `search.failed`/`wellbeing.reason_use_generic` above), plus
`treat_target_label` (the "Treat K9" `ox_target` option) and `no_nearby_k9`
(`RequestTreatNearestK9()`'s own "no candidate" rejection). **`too_far`
does NOT get a `medkit.*` key** — see "The `common.too_far_from_k9`
promotion" immediately above. **`RequestTreatNearestK9()`'s own
`Config.Features.K9Medkit` guard reuses `medkit.reason_feature_disabled`**
rather than minting a second "K9 medkit is not enabled." key — confirmed
byte-identical to the rejection table's own `feature_disabled` entry before
reusing it.

`bonetool.*` (`client/bonetool.lua`, 9 leaf keys — kept in their own group,
NOT folded into `common.*`, per this file's own task instructions: this is
a dev-only diagnostic tool, and its strings are instructions for running a
bone-index sweep, not in-fiction player copy, so a translator should be
able to tell that at a glance from the key group alone): `notify_title`
("K9 Unit — Bone Tool" — a DIFFERENT title from `common.notify_title`'s
plain "K9 Unit", used by every `lib.notify` call in this file instead of
the shared one, since this tool's notifications are visibly a distinct
sub-brand within the resource, not standard player-facing K9 Unit
messaging), `preview_bone_index` (the multi-line "Previewing bone index:
%d..." instructional notify, `%d`-interpolated), `bone_index_label` /
`bone_index_label_test_attached` (the on-screen 3D text label drawn next to
the preview marker — see "A third concatenation instance" below for why
this is two keys, not one template), `test_prop_load_failed`,
`test_attached` (the multi-line "Test-attached at bone index %d..."
instructional notify), and `known_sweep_header`/`known_sweep_line`/
`known_sweep_footer` (the three pieces `RunKnownBoneSweep()` assembles via
`table.concat(lines, '\n')` into one `lib.notify` description —
`known_sweep_line` is `%s`-interpolated three times per candidate,
`('  %s (0x%X) -> %s')`, note the `%X` hex specifier passes through
`string.format` inside `locale()` exactly as it did before migration). This
file's own `print()` calls (the operator breadcrumb in `SetPreviewBoneIndex`
and the console echo in `RunKnownBoneSweep`) are correctly left untouched,
per this migration's standing print()-is-out-of-scope rule — the latter's
own `'[qbx_k9unit] bonetool known-name sweep:\n' .. message` string
concatenation is fine to leave as-is even though it uses `..`, since it's
building an operator-console string, not a player-facing one, and `message`
itself is already fully composed from `locale()`-sourced lines by the time
this concatenation runs.

**A third concatenation instance, found and fixed, per this pass's own
explicit instruction to expect one:** `client/bonetool.lua`'s preview-draw
loop built its on-screen bone-index label as
`labelText = ('Bone Index: %d'):format(currentBoneIndex)` followed
conditionally by `labelText = labelText .. ' (TEST PROP ATTACHED)'` — the
same "append a literal suffix onto a dynamic string with `..`" shape the
two earlier passes' own `'Officer #' .. serverId` findings (now both fixed,
see `movement.officer_fallback_name`/its `client/partnership.lua` reuse
above) already exist to close. Fixed the same way those were: NOT a
`"Bone Index: %d%s"` template interpolated with a conditional suffix
argument (that would still be templating a state-dependent clause onto a
sentence, the exact thing this migration's `leash_detached`/
`leash_detached_partner_disconnected` precedent already rejected for the
identical reason), but two independent, complete-sentence keys —
`bone_index_label` ("Bone Index: %d") and `bone_index_label_test_attached`
("Bone Index: %d (TEST PROP ATTACHED)") — selected by a plain `if/else` in
the Lua rather than built by concatenation or a partial template.

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

## What's left (honest count, recounted directly against the tree — every
number below comes from actually reading/grepping the current `client/*.lua`
and `server/*.lua` files, not from incrementing the prior pass's tally)

This resource's `client/` + `server/` trees hold **47 `.lua` files** total
(25 under `client/`, 22 under `server/`) — close enough to the "~48" this
document has always used as a round number that it isn't being changed.
Every one of those 47 has now been individually checked for player-facing
strings; **none are unchecked anymore**, which was not true as of the sixth
pass (it left every `server/*.lua` file, plus `client/exports.lua`,
unchecked).

- **27 of 47 files have needed and received a real `locale()` migration:**
  19 client files (`client/vision.lua`, `client/vehicle.lua`,
  `client/kennel.lua`, `client/main.lua`, `client/movement.lua`,
  `client/agility.lua`, `client/inventory.lua`, `client/partnership.lua`,
  `client/defense.lua`, `client/fetch.lua`, `client/propattachment.lua`,
  `client/radial.lua`, `client/search.lua`, `client/tracking.lua`,
  `client/wellbeing.lua`, `client/progression.lua`, `client/medkit.lua`,
  `client/bonetool.lua`, `client/combat.lua`) plus 8 server files
  (`server/main.lua`, `server/kennel.lua`, `server/partnership.lua`,
  `server/tenure.lua`, `server/certifications.lua`, `server/recall.lua`,
  `server/inventory.lua`, `server/wellbeing.lua` — see "Update (server
  migration pass...)" above for what each added).
- **14 of 47 files have been checked and confirmed to need NO `locale()`
  calls at all** (zero player-facing strings found, by grep for
  `NotifyPlayer(`/`lib.notify`/any literal-string-carrying
  `TriggerClientEvent`, not just a skim): 6 client files
  (`client/screenfx.lua`, `client/audio.lua`, `client/proximityaudio.lua`,
  `client/recall.lua`, `client/hud.lua`, and — newly checked this pass —
  `client/exports.lua`) and 8 server files (`server/defense.lua`,
  `server/entities.lua`, `server/exports.lua`, `server/notify.lua`,
  `server/cooldowns.lua`, `server/progression.lua`, `server/tracking.lua`,
  `server/search.lua`). Don't re-check these again from scratch, but do
  re-check any of them if new player-facing UI is added later.
- **6 of 47 files are checked and confirmed to STILL have real, hardcoded
  player-facing strings genuinely left to migrate:** `server/combat.lua`,
  `server/medkit.lua`, `server/fetch.lua`, `server/propattachment.lua`,
  `server/admin.lua`, `server/bonetool.lua` — see "Update (server migration
  pass...)" above for what each one still hardcodes and which existing keys
  they should reuse where a duplicate was found (`server/combat.lua`'s
  `already_engaged` → `defense.already_engaged`).

27 + 14 + 6 = 47. This file establishes the pattern and the shared
`common.*` keys; it does not claim to have finished the job — 6 files with
real work still outstanding is real work still outstanding, not "basically
done."

**Both of the fourth pass's own flagged reuse notes were resolved by THIS
(fifth) pass, not left stale:**
- `client/radial.lua`'s `label = 'Partner Up'` now calls
  `locale('partnership.partner_up_target_label')` directly — no new key
  minted for it.
- `client/tracking.lua`'s `'You cannot use K9 features right now.'` now
  calls `common.no_k9_access` directly — no fifth verbatim copy minted for
  it (see "The `common.no_k9_access` promotion" above for the running
  count).

**Both notes below were resolved by the server migration pass recorded
above — kept here, corrected in place, rather than deleted, so a future
reader can see the plan and confirm it was actually followed:**
- `server/partnership.lua`: ~~hardcodes `'Partner request sent.'`~~ **DONE
  — now calls `locale('partnership.partner_request_sent')`**, confirmed
  byte-identical text before reuse, no duplicate minted. The DIFFERENT,
  NOT-identical `already_partnered = 'One of you is already partnered with
  someone else.'` rejection string ~~must NOT be collapsed into
  `partnership.already_partnered`~~ **DONE — it got its own new key,
  `partnership.reject_already_partnered`**, exactly as this note asked; the
  two keys hold two different sentences for two different contexts, as
  intended.
- `server/combat.lua`: **STILL OPEN, NOT done.** Still hardcodes
  `already_engaged = 'You are already engaged with another target.'`,
  verbatim identical to the already-migrated `defense.already_engaged` —
  reuse that key when this file is finally migrated (see "6 of 47 files...
  still have real, hardcoded player-facing strings" above; `server/combat.lua`
  is the largest of the six).

**Note for whoever migrates `server/kennel.lua`: RESOLVED, confirmed by
reading the actual call sites, not assumed from this note's old plan.**
The server-side placement-failure strings this note worried about
(`'...the object could not be confirmed.'`, `'...unexpected object model.'`,
`'...placed too far from the assigned spot.'`) were given their OWN new
leaf keys inside the existing `kennel.*` group — `placement_failed_unconfirmed`,
`placement_failed_wrong_model`, `placement_failed_too_far` — exactly the
"give them their own keys, don't collapse into `kennel.placement_failed`"
outcome this note asked for. No `server_kennel.*` group was needed; the
existing `kennel.*` group was descriptive enough once each distinct failure
got its own leaf name. `client/kennel.lua`'s own `kennel.placement_failed`
is untouched and still means what it always meant (the client-side
object-creation/grounding failure).

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
