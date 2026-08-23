# Security review — Phase 2 Door Interaction (nudge-open / scratch-to-alert)

Author: coder-security (adversarial/red-team pass)
Date: 2026-08-23
Status: **PRE-IMPLEMENTATION.** Written against the design docs only —
`server/main.lua`'s `relayDoorScratch` handler and `client/movement.lua`'s
door-interaction extension do not exist yet as of this pass (two coder
agents are implementing them concurrently right now). This mirrors
`phase2_notes/contraband_search_security_review.md`'s own precedent
(written before `server/search.lua` existed, then absorbed line-by-line
into the real implementation) — same intent here: hand the two implementing
agents a concrete exploit list to design against, not a retrospective audit.

Reviewed against: SPEC.md §11.1 (sub-phase ordering), §11.3 (file/module
plan), §11.4 item 5/6 (event contract), §11.5 (door-interaction acceptance
criteria), §11.6 (reality-check), §9 items 12/16 (open questions),
`phase2_notes/door_interaction.md` (design note, coder-frontend),
`phase2_notes/door_interaction_natives.md` (native verification,
native-api-specialist), `config.lua`'s `Config.DoorInteraction` table
(lines 244–248), and the already-shipped `server/main.lua` /
`client/movement.lua` / `client/main.lua` Phase 1 code that the new door
handlers are documented to structurally mirror (`relayBark` /
`lastBarkAt` / `playBark`).

Baseline already correctly specified and **not** re-litigated below:
- `Config.Features.DoorInteraction` and `HasK9Access(source)` are both
  documented to be re-checked server-side in `relayDoorScratch`, regardless
  of client UI/menu state (SPEC.md §11.4 item 5, door_interaction.md §4.2)
  — same discipline as every other gated action in this resource.
- A server-enforced (not just client-cosmetic) cooldown exists on the
  scratch event, structurally identical to `BARK_COOLDOWN_MS`/`lastBarkAt`
  in `server/main.lua` (confirmed at lines 291–292, 308–312 of the current
  file) — this is a real backstop, not a display-only convenience.
- The broadcast payload is minimal: `doorNetId` only (SPEC.md §11.4 item 5:
  "No inventory/lock-state reveal of any kind — purely a sound cue"). Unlike
  the contraband-search broadcast (which this same reviewer flagged as a
  blocking information leak in the companion review, since it carried a
  target identity + a found/not-found signal), a door's own coordinate
  genuinely carries no person/vehicle-identifying information by itself —
  **so the task's framing that a global `-1` broadcast is an accepted,
  deliberate choice for this specific feature is correct and this review
  does not dispute it.** The real gap this review found is different in
  kind from the contraband case: it's not about *who receives* the
  broadcast, it's about *what the server allows the payload to point at*
  before broadcasting it at all (Finding 1).
- Nudge-open is correctly scoped as fully client-local — no
  `TriggerServerEvent`, no callback, nothing server-authoritative at stake
  (SPEC.md §11.3/§11.4/§11.6; door_interaction.md §4.1; mirrors
  `client/vehicle.lua`'s documented §4.1 exception). There is no server
  trust boundary to attack here at all *for nudge specifically* — this
  review's nudge-related finding (Finding 3) is a config/enforcement-design
  gap, not a bypass of any check that currently exists, because no check
  currently exists to bypass.

---

## Finding 1 (High — confirmed, concretely exploitable; this is exactly the gap SPEC.md §9 item 16 already flagged as "not yet resolved") — `relayDoorScratch`'s `doorNetId` is never resolved, existence-checked, type-checked, or proximity-checked server-side before being broadcast

### The exact call

Any player who currently holds valid `HasK9Access` (a legitimately certified
K9 officer running a modified client — this is not reachable by an
uncertified account, see the "who can actually pull this off" note at the
end of this finding) can skip `client/movement.lua`'s door-detection scan
entirely and call:

```lua
TriggerServerEvent('qbx_k9unit:server:relayDoorScratch', <any netId>)
```

with a `doorNetId` that is a real, currently-networked entity that is
**not a door and not anywhere near the caller** — for example, another
connected player's own ped netId, obtained once by briefly getting within
streaming range of them (trivial for a mod-menu client, which can read
`NetworkGetNetworkIdFromEntity` off any streamed-in entity), after which
the attacker can walk away and keep firing the event indefinitely.

### Why nothing stops it

Per the documented handler shape (door_interaction.md §4.2; SPEC.md §11.4
item 5 — and confirmed by literally reading `server/main.lua`'s existing,
structurally-identical `relayBark` handler, lines 301–323, which this one is
supposed to mirror), the planned server-side steps are only:

1. `Config.Features.DoorInteraction` check.
2. `HasK9Access(source)` check.
3. `type(doorNetId) ~= 'number'` defensive payload check.
4. `Config.DoorInteraction.scratchCooldownMs` per-source cooldown.
5. `TriggerClientEvent('qbx_k9unit:client:playDoorScratch', -1, doorNetId)`.

**No step resolves `doorNetId` to a live entity, confirms it exists,
confirms it's anywhere near the reporting player, or confirms it's actually
a door-shaped object rather than a player ped, a vehicle, or any other
networked entity.** This is a direct violation of this resource's own
established standard — every other entity-identifying, client-supplied
value in this codebase is independently re-resolved and re-validated
server-side before being trusted (`CheckLeashEligibility`'s live proximity
check on both peds in `server/main.lua`; the target-model live re-check in
certification grants per SPEC.md §4.2.5; the planned target-existence +
proximity + type cross-check for `searchTarget` per SPEC.md §11.4 item 2)
— `relayDoorScratch` as currently scoped is the one documented exception to
that pattern, and SPEC.md §9 item 16 already says so explicitly: "Neither
§11.4 item 5 nor `phase2_notes/door_interaction.md`'s server-handler sketch
... call for resolving that id... A modified client could supply any
entity's netId... and have it broadcast server-wide."

The **receiving** side makes this concretely exploitable rather than
theoretical: §11.4 item 6 documents `playDoorScratch` as mirroring
`client/main.lua`'s existing `playBark` handler "exactly" — which, read
directly (lines 157–171 of that file today), is:

```lua
RegisterNetEvent('qbx_k9unit:client:playBark', function(netId, barkType)
    if not NetworkDoesEntityExistWithNetworkId(netId) then return end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(entity) then return end
    PlaySoundFromEntity(-1, BARK_SOUND_NAME, entity, BARK_SOUND_SET, false, 0)
end)
```

`PlaySoundFromEntity` takes **whatever entity the netId resolves to** on
each receiving client — there is no door-specific check on the receiving
end either. So the only gate between "arbitrary client-supplied netId" and
"every connected client who has that entity streamed in plays a sound
attached to it" is whether the entity happens to exist at all.

### The two distinct cases this actually splits into (answering the task's question precisely)

- **Nonexistent/garbage `doorNetId`** (a made-up integer, a stale netId from
  a despawned entity, a wildly out-of-range number): **harmless.**
  `NetworkDoesEntityExistWithNetworkId` fails on every single receiving
  client, so this degrades to a no-op broadcast (negligible network
  chatter at the throttled cooldown rate — not worth mitigating on its own).
- **A real, currently-existing entity's `doorNetId` that is not a door and/or
  not near the caller**: **this is the actual exploit.** It resolves
  successfully on every client that has that entity streamed in (i.e.,
  everyone currently near it, which the attacker does not need to be),
  and plays a sound "from" it unconditionally.

### Concrete consequence

`doorNetId` can be set to any live networked entity anywhere on the map,
including a specific victim player's own ped. Every `scratchCooldownMs`
(3000ms default), the attacker re-triggers the event, and every other
connected client who currently has that victim's ped streamed in plays a
repeating "scratch"/alert sound cue anchored to that specific player,
indefinitely, for as long as the attacker keeps calling it — from anywhere
on the map, without ever being near the victim, a door, or even a
recognizable K9 interaction. To bystanders and the victim, this presents as
an unexplained, disembodied, repeating K9-alert sound following one
specific player with no visible source and no way to identify or block the
attacker. This is a real, low-effort, sustained per-victim harassment
primitive — a materially different (and worse) category of consequence
than the "everyone technically gets a bark event" tradeoff this resource
has already accepted for `relayBark`, precisely because `relayBark`'s
payload always resolves to the *sender's own*, already-access-checked ped
(no free choice of target), while `relayDoorScratch`'s payload is a free,
unconstrained pointer to any entity on the server.

**Who can actually do this:** only a player who currently holds valid
`HasK9Access` (department + active certification, per §4). This bounds the
threat to "an insider with legitimate K9 access running a modified client,"
not "any connected player" — worth stating plainly since it meaningfully
narrows the population that can pull this off, but does not make it
non-exploitable: certified accounts are exactly the accounts most likely to
exist on any server running this resource at all, and nothing about holding
a legitimate K9 certification implies trustworthiness against a compromised
or intentionally malicious client.

### Fix (cheap, and it is the *only* missing piece relative to this resource's own existing pattern)

Resolve and validate `doorNetId` server-side before ever broadcasting it —
mirroring `CheckLeashEligibility`'s live-coordinate distance check in the
same file:

```lua
local entity = NetworkGetEntityFromNetworkId(doorNetId)
if not DoesEntityExist(entity) then return end -- silent no-op: never trust that this netId is real

local ped = GetPlayerPed(src)
local dist = #(GetEntityCoords(ped) - GetEntityCoords(entity))
if dist > Config.DoorInteraction.interactDistance then return end -- silent no-op: caller isn't actually near what they claim to be scratching
```

Optional, cheap defense-in-depth on top, once the entity is already being
resolved for the check above: also reject unless `GetEntityType(entity) ==
3` (`OBJECT` — GTA's `GetEntityType` returns `1` for a ped, `2` for a
vehicle, `3` for an object; door props are objects). This doesn't add a new
round-trip or new state, it's one more comparison on a value already in
hand, and it closes the narrower remaining case where an attacker stands
within `interactDistance` of an actual bystander and supplies that
bystander's own ped netId (the distance check alone doesn't rule this out
if the attacker is willing to be physically close to the victim at the
moment of the call; the type check does).

---

## Finding 2 (Medium — directly answers the task's cooldown-sufficiency question; a real residual gap even after Finding 1 is fixed) — a flat per-source cooldown does not bound target exposure, only attacker rate

Assume Finding 1 is fixed (existence + proximity validated). The remaining
question the task poses is whether `Config.DoorInteraction.scratchCooldownMs`
(3000ms, per-source, mirroring `BARK_COOLDOWN_MS`'s exact shape per
door_interaction.md §4.2 and SPEC.md §11.4 item 5) is actually sufficient
given the broadcast is global. **No — not on its own.** It bounds how fast
one attacking source can fire, but it bounds nothing about *what* gets
targeted or *how long/how many sources* can sustain pressure on one target:

- **Single attacker, one location, indefinitely:** once genuinely standing
  within `interactDistance` of a real door (satisfying Finding 1's fix), a
  single certified attacker can still re-trigger the broadcast once every
  3 seconds forever, with no cap on total duration or count. Anchored to a
  fixed, real-world location a crowd of players may be occupying (a PD
  lobby, a bank, a jail entrance — all realistic door locations), this is a
  sustained, disembodied, repeating alert sound audible to everyone nearby
  for as long as the attacker cares to stay — a real nuisance/harassment
  vector distinct from bark's "comes from one visible, identifiable player
  ped" framing, since bystanders can at least visually attribute and route
  around a barking dog but not an alert sound with no visible source.
- **Multiple sources, one target:** the cooldown is scoped per-source only,
  the same pattern already flagged as an open, unresolved multi-actor gap
  for `searchTarget` in the companion contraband-search review (finding
  §5: "nothing stops two colluding or two alt-account K9-certified
  characters ... from re-probing the exact same target back-to-back with no
  target-side throttle at all"). The identical structural gap applies here:
  two or more K9-certified accounts (colluding players, or one attacker
  cycling between certified alt characters, if the target server's account
  model permits it) can each independently respect their own 3-second
  cooldown while collectively producing a far higher effective rate against
  one door/victim than the single-source number implies.

**Recommendation:** add a second, target-scoped cooldown keyed by the
*resolved* `doorNetId` itself (e.g. `lastDoorScratchByTarget[netId] =
GetGameTimer()`), independent of `source`, so the same entity cannot be
re-triggered faster than some floor (matching or slightly exceeding
`scratchCooldownMs`) no matter how many distinct sources request it — this
is the same fix shape the contraband review already recommended (as an
explicit open decision, not yet mandated) for `searchTarget`'s analogous
per-`(source, target)`-only cooldown.

**One new engineering wrinkle this introduces, worth flagging explicitly so
it isn't discovered as an afterthought:** `lastBarkAt` / `lastLeashRequestAt`
/ a source-keyed `lastDoorScratchAt` are all keyed by connected server id
and get cleaned up for free by the existing `playerDropped` handler
(`server/main.lua` lines 614–649, e.g. `lastBarkAt[src] = nil`). A
*netId*-keyed table has no equivalent natural cleanup hook — an entity can
stop existing (despawn, streamed out permanently, resource restart) without
any event this file currently listens for. Left unpruned, this table grows
unbounded over a long-running server session. Whoever implements this
should pick an explicit bounded-lifetime strategy (a periodic sweep
dropping entries older than some small multiple of `scratchCooldownMs`, or
a max-size eviction) rather than assuming it self-cleans the way the
existing source-keyed tables do.

---

## Finding 3 (Process/design gap — directly answers the task's `nudgeRequiresUnlocked` question) — the flag has no enforcement path in any design document, and none is planned for this pass

### Re-confirmed, precisely, from every document that mentions it

- `config.lua` (lines 244–248) ships `nudgeRequiresUnlocked = true` with an
  inline comment: "hard requirement, not a toggle: nudge-open must never
  function as a lockpick bypass."
- `README.md` (lines 601–604) repeats the identical framing to server
  owners reading the shipped config reference, again with no code
  reference — a server owner has no way to learn from either document that
  no code currently reads this value at all.
- `phase2_notes/door_interaction.md` §4.1 states nudge-open is "fully
  client-only, no server event at all," and its own §3.2 explicitly frames
  "when in doubt, don't offer nudge" as "this note's own conservative lean,
  not a spec mandate," flagging it for whoever implements this to confirm
  — i.e., even the design note that introduced the guarantee doesn't claim
  to have wired real enforcement for it yet.
- `phase2_notes/door_interaction_natives.md` §0.5/§4 (the authoritative
  native-verification pass, and the most concrete implementation guidance
  that exists for this feature) goes further and **actively recommends
  against** ever consulting a lock-state native for this check at all
  (correctly — it documents that GTA's native `CDoor` system would return
  "nothing to say" for the exact doors a real door-lock resource manages,
  which "risks being misread as 'unlocked' — a false-negative read there
  would be a concrete way to violate the hard `nudgeRequiresUnlocked`
  guarantee"). Its recommended design instead makes nudge-open **purely
  cosmetic** — a push animation triggered only as the K9 walks through a
  door it can already physically pass, "never consulting `CDoor` state as a
  safety check" at all.
- SPEC.md §11.5's acceptance criteria states the guarantee ("nudge must
  never open a locked door under any circumstance; this is a hard
  behavioral guarantee, not just a default") but, like every other
  document, never specifies what code actually reads
  `nudgeRequiresUnlocked` to enforce it.

**Putting these together confirms the config-validator's flag precisely:**
under the actually-recommended implementation (native-verification doc's
own "Practical recommendation," §4), there is no "is this door unlocked?"
branch anywhere in the planned code for nudge-open to gate with this
flag — the feature is designed to be structurally incapable of touching
lock state at all, regardless of what `nudgeRequiresUnlocked` is set to.
**The flag is not currently a toggle that does something conservative by
default; it is a boolean that, as designed, no code reads at all.**

### Why this is worse than an inert config value, not just harmlessly unused

This is the one field in `Config.DoorInteraction` whose own inline comment
insists it is uniquely non-optional ("not a toggle"), which is exactly the
framing most likely to make a server owner assume it *does* something
functional today — its name and comment both actively invite the belief
that flipping it to `false` changes real behavior. The actual risk isn't
today's behavior (nothing reads it, so today `false` and `true` are
identical no-ops); it's a **future** one: if a later implementer builds the
richer, lock-state-aware nudge feature that SPEC.md §9 item 12 explicitly
defers (a real door-lock-resource integration export hook), the most
natural, unremarkable-looking way to "respect the existing config field"
would be to add precisely the branch this whole design has been avoiding —
`if not Config.DoorInteraction.nudgeRequiresUnlocked then <force-open via
the integration hook, skipping the lock-state check> end` — at which point
a server owner who set the flag to `false` months earlier, for any reason
(testing, a copy-pasted "permissive" example config, or simply not
understanding the field's real weight), would silently acquire a genuine
lockpick-equivalent exploit with no one having deliberately, reviewedly
wired that path for that purpose. A boolean whose only currently-safe
values are "true" and "true, but nothing reads it anyway" is a fragile
contract to leave sitting in a user-editable config file.

### Answering the direct question: yes, there is a cheap way to make this safer now, before nudge-open exists

**Option A — recommended. Add a one-line resource-start assertion.**

```lua
assert(Config.DoorInteraction.nudgeRequiresUnlocked == true,
    'Config.DoorInteraction.nudgeRequiresUnlocked must remain true — nudge-open has no lock-bypass enforcement code path in this version; see phase2_notes/door_interaction_security_review.md')
```

This converts "silently does nothing today, could quietly become dangerous
later" into "loudly breaks resource start the moment anyone sets it to
`false`" — the same fail-safe-not-fail-silent posture this codebase already
applies elsewhere (the `uq_one_active_cert_per_job` DB-level backstop in
SPEC.md §4.3; the "never trust a client claim" refrain running through
every event handler reviewed above). It costs one line, touches no
already-written spec/README text (SPEC.md, both phase2_notes door
documents, and README.md can all keep citing this field by name with zero
drift), and — critically — gives whoever eventually implements the richer,
integration-backed nudge feature an explicit, impossible-to-miss trip-wire
the instant they try to wire a real branch off this flag, forcing a
deliberate, reviewed removal of the assertion at the same moment real
enforcement code lands, rather than an accidental, unreviewed one.

**Option B — more invasive, matches the task's literal phrasing, real cost
worth naming rather than assuming free.** Remove `nudgeRequiresUnlocked`
from `Config.DoorInteraction` entirely until the door-lock-resource
integration hook (§9 item 12) ships alongside real code that reads it —
re-add it only paired with its enforcement, applying §3's own "a config
value must be read at the point where it matters, not just declared"
discipline (written for `Config.Features` flags, but the same reasoning
applies to a sub-field that claims comparable weight). This is the
textually cleanest outcome, but it is not free: SPEC.md alone references
this exact field by name in at least five places (§5's forward pointer,
§11.2, §11.5, §11.6 twice), both `phase2_notes` door-interaction documents
build real analysis around it, and `README.md` documents it as shipped,
settled config. Removing it now would put `config.lua` out of sync with
all of that already-cross-referenced spec text — the same kind of
doc/code reconciliation burden SPEC.md's own header already had to call
out once (the note that `config.lua`, not §5, is the source of truth for
the Phase 2 tables). Worth doing only as part of a coordinated documentation
pass once nudge-open's real (deferred) design is finalized, not as a
same-day fix.

**This review's recommendation: ship Option A now** (cheap, zero doc-drift,
immediately effective) **and revisit Option B if/when §9 item 12's
door-lock integration is actually scheduled**, at which point removing the
assertion and wiring real enforcement become the same reviewed change.

---

## Summary — items for the two implementing agents to resolve

- [ ] **Recommended before merge:** resolve `doorNetId` via
      `NetworkGetEntityFromNetworkId` + `DoesEntityExist`, and reject unless
      within `Config.DoorInteraction.interactDistance` of the reporting
      player's own live server-side position, before broadcasting
      `playDoorScratch` — closes a confirmed, concretely-exploitable
      per-victim harassment vector (Finding 1; this is SPEC.md §9 item 16,
      confirmed here with a full worked attack, not merely restated).
- [ ] **Cheap defense-in-depth alongside the above:** also reject unless
      the resolved entity's `GetEntityType(entity) == 3` (object) — closes
      the narrower remaining case where an attacker stands genuinely near a
      bystander and supplies that bystander's own ped netId (Finding 1).
- [ ] Add a secondary cooldown keyed by the *resolved* `doorNetId`
      (independent of `source`), since the per-source cooldown alone
      doesn't bound sustained single-attacker pressure on one door/location
      or collective multi-account pressure on one target, once Finding 1 is
      fixed (Finding 2) — and pick an explicit prune/eviction strategy for
      that table, since (unlike every existing source-keyed cooldown table
      in this file) it has no `playerDropped`-style natural cleanup hook.
- [ ] Add a resource-start `assert(Config.DoorInteraction.nudgeRequiresUnlocked
      == true, ...)` (Option A, Finding 3) before nudge-open is implemented,
      so the flag can never silently sit in a state where it looks
      load-bearing but isn't — cheap, zero doc-drift, and gives a future
      integration-backed nudge implementation an explicit trip-wire.
- [x] Confirmed sound, not re-flagged: `Config.Features.DoorInteraction` /
      `HasK9Access(source)` re-validation server-side; the existing
      per-source cooldown mechanism itself (shape is correct, scope is the
      only gap — see Finding 2); the broadcast payload's minimality
      (`doorNetId` only — the "global broadcast is acceptable for this
      feature" design choice holds once Finding 1 is fixed, since the
      payload genuinely carries no person/vehicle identity, unlike the
      contraband-search case); nudge-open's fully-client-local, no-server-
      event structure (no trust boundary exists there to attack).

None of the above require rewriting SPEC.md §11's design — Finding 1 and
Finding 2 are the same "never trust a client-supplied entity id" and
"cooldowns need a target-scoped floor, not just a source-scoped one"
disciplines this resource already applies everywhere else, applied here for
the first time to a payload that identifies a *different* entity than the
sender; Finding 3 is a one-line, additive safety net that costs nothing to
ship immediately. Will re-review once `server/main.lua`'s `relayDoorScratch`
handler and `client/movement.lua`'s door-interaction extension actually
exist, against this checklist, the same way the contraband-search review
was re-checked against `server/search.lua` once it landed.
