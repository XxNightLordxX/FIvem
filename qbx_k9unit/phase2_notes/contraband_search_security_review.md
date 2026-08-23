# Security review — Phase 2 Search Vehicle/Person + Contraband Alert Levels

Author: coder-security
Date: 2026-08-23
Status: **REVIEWING THE REAL CONTRACT.** `phase2_notes/contraband_search_contract.md`
never appeared from coder-backend in this session (repeatedly checked;
`coder-backend` and `team-leader` were both unreachable via `SendMessage`
throughout). The authoritative contract turned out to already exist in
**SPEC.md §11** (product-agent, same day) — specifically §11.4 item 2
(`qbx_k9unit:server:searchTarget`), §11.5's "Search vehicle/person +
contraband alert tiers" acceptance criteria, and §11.6's reality-check note
on ox_inventory export uncertainty. This document reviews **that** contract
directly, adversarially, per the coordinator's redirect. An earlier draft of
this file (pre-dating discovery of §11) reviewed a hypothetical contract
built only from §6.3's one-sentence description; that draft is superseded
and its content is folded in below only where it raises a point §11 doesn't
already resolve.

Baseline already correctly specified in §11.4 item 2 / §11.5 (confirmed
sound, not re-litigated below):
- Server resolves `targetNetId` to a live entity via
  `NetworkGetEntityFromNetworkId` and confirms it still exists — never
  trusts a client claim about what the target is.
- Proximity is re-checked against the caller's own **live** server-side
  position at the moment the callback runs (never a client-claimed
  distance), and — because the client only invokes the callback *after*
  its local sniff-animation delay (§11.5) — this naturally lands the
  proximity/existence check at effective "resolution time," not just
  "request time," closing the most obvious TOCTOU gap (target driving off
  mid-animation) by construction rather than requiring a second explicit
  check.
- Inventory contents and item weight are read live from real ox_inventory
  data at call time; nothing is duplicated into `Config.*` that could drift
  (§11.2's explicit rationale for not storing weight in
  `Config.SearchContrabandItems`).
- `Config.Features.SearchZones` / `HasK9Access(source)` are re-validated
  server-side regardless of client UI/menu state.
- A cooldown exists and is server-enforced, not just a client-side
  disabled-button convenience.

The findings below are gaps §11 leaves open or doesn't explicitly address,
per the coordinator's ask to flag what the real contract doesn't already
cover.

---

## 1. (Highest severity) Reusing `relayBark`'s global `-1` broadcast for the contraband alert leaks target identity server-wide

§11.3's `server/search.lua` row and §11.5's acceptance bullet both describe
the alert as "mirrors how `relayBark` already broadcasts rather than
playing client-locally only" / "a broadcast alert sound/animation... the
same way `server/main.lua`'s `relayBark` does." Read literally, that means
reusing `relayBark`'s actual code shape:

```lua
TriggerClientEvent('qbx_k9unit:client:playBark', -1, netId, barkType)
```

— a raw broadcast to **every connected client on the server**, relying on
in-game positional audio (`PlaySoundFromEntity`-style distance falloff) to
make it *sound* like it only matters nearby. For a bark, that's harmless:
the payload (`netId`, `barkType`) carries no information a modified client
couldn't already infer by looking at the K9 player directly, and the
in-fiction stakes of "everyone's client technically receives a bark event"
are zero.

**For a contraband alert, this is a real information leak, not a cosmetic
one.** The payload necessarily includes (at minimum) the target's `netId`
and the matched `alertTier`. A modified client anywhere on the map —
including an accomplice of the exact person/vehicle being searched, with no
proximity to the search at all — can listen for this broadcast event and
immediately resolve `netId` to "which vehicle/ped just got flagged for
contraband, and roughly how much" via `NetworkGetEntityFromNetworkId`. This
defeats the entire tactical value of an in-fiction K9 search (the point of
a real K9 alert is that only people *actually near it* learn anything) and
turns a supposedly local sensory cue into a server-wide surveillance feed
for anyone running a bark-alert listener. This is strictly worse than the
already-accepted "everyone technically gets a bark event" tradeoff, because
bark carries no target-identifying payload and contraband alert does.

**Requirement (blocking):** the contraband alert broadcast must be sent
only to clients within a real distance filter of the target — either by
having the server iterate connected players and `TriggerClientEvent` only
to those within some `Config.SearchZones`-driven audible radius of the
target's live coordinates (computed server-side, same live-position
discipline as the rest of this contract), or by explicitly deciding this
tradeoff is acceptable and stating why in the contract doc (not silently
inherited from a pattern built for a payload with different stakes). Do
not reuse `relayBark`'s literal `-1` broadcast for this event without that
distance filter — flag this explicitly to whoever implements
`server/search.lua`, since "mirror `relayBark`'s broadcast pattern" as
currently worded in §11.3 reads as an instruction to copy the `-1` shape
too.

**Secondary, same root cause:** confirm the broadcast payload itself
carries **only** `netId` + `alertTier` (whatever's needed to pick a
sound/animation), never `totalWeight` or `contrabandFound`'s exact value.
§11.4 item 2's callback return type includes `totalWeight: number?` for the
*requester's own* response — that field must not also ride along on the
broadcast event to bystanders. This isn't stated explicitly either way in
§11.3/§11.4/§11.5; call it out as a hard requirement in `server/search.lua`
so a "just pass the whole result table into the broadcast for convenience"
implementation shortcut doesn't silently leak `totalWeight` to everyone in
audible range too.

---

## 2. No flat per-source rate limit — only per-(source, target) — leaves a real-time environment scan wide open

§11.4 item 2 and §11.5 both specify the cooldown as **per `(source,
targetNetId)` pair**, explicitly "not globally" (§11.5: "per `(K9 player,
target)` pair, not globally"). That's a deliberate, stated design choice
for the *legitimate* replay-the-same-target case, but it has a side effect
the contract doesn't address: **nothing stops a single source from
searching many different targets back-to-back with zero delay.**

The `sniffAnimDurationMs` client-side animation is described as "purely
cosmetic pacing" (§11.5) — a modified client can skip it entirely and
invoke the `searchTarget` callback immediately, repeatedly, against a new
`targetNetId` every call (every vehicle in a parking lot, every player ped
in a crowd). Each of those is a *first-time* call for that particular
`(source, targetNetId)` pair, so the per-pair cooldown never engages. The
practical impact is two-fold:

1. **Resource cost:** every call does a real ox_inventory export read
   (server-authoritative by design, per §1's baseline above) — a client
   that skips the cosmetic delay and loops over every vehicle netId it can
   see turns "one officer walks their K9 down a row of cars" into "one
   client fires N inventory reads per second," a real per-source flood
   vector against ox_inventory/the DB, structurally identical in shape to
   the flood `server/main.lua`'s header already flags and fixes for
   `relayBark` ("a single modified client spamming this event as fast as
   the network allows") — except `relayBark` has no external I/O cost per
   call and this does.
2. **Intel-gathering at bulk speed:** even setting resource cost aside, a
   modified client can now sweep an entire area's contraband status in
   real time (which cars/peds are "hot") far faster than the sniff-animation
   pacing was ever meant to allow, since the animation was never a
   real constraint to begin with.

**Requirement:** add a flat per-source cooldown on `searchTarget` itself
(independent of which target is named), sized to roughly
`Config.SearchZones.sniffAnimDurationMs` (i.e., a source cannot invoke this
callback again — against *any* target — until the previous call's
cosmetic animation window has elapsed), in addition to the existing
per-`(source, targetNetId)` cooldown. This is the same
`BARK_COOLDOWN_MS`/`lastBarkAt`-shaped fix already proven in this codebase,
just applied to a second, orthogonal axis (any-target rate, not
same-target-replay rate) that §11 doesn't currently cover.

---

## 3. Check-then-act race between the cooldown check and the awaited ox_inventory read

This is new territory for this resource: every cooldown pattern shipped so
far (`BARK_COOLDOWN_MS`/`lastBarkAt`, `LEASH_REQUEST_COOLDOWN_MS`/
`lastLeashRequestAt` in `server/main.lua`) checks-and-immediately-sets the
timestamp with **no `await` in between** — there's no yield point for a
second invocation to interleave. `searchTarget` is different: per §11.4
item 2, resolving the result requires an **awaited** ox_inventory export
call (`MySQL`/`exports.ox_inventory:...` style call that yields the
coroutine) between "check the cooldown" and "know the real result." If the
implementation checks the cooldown, then `await`s the inventory read, and
only *then* writes the new cooldown timestamp (the natural way to write
this function if following the same shape as `GrantCertification`'s
pre-check-then-insert pattern), a second `searchTarget` call for the same
`(source, targetNetId)` fired before the first call's `await` resolves
would still see the old (stale, not-yet-updated) timestamp, pass the
cooldown check too, and trigger a second full inventory read and a second
broadcast alert — a double-search from what should be a single rate-limited
action. This is the exact class of bug `certifications.lua`'s §4.3 DB
unique-index backstop exists to close for the grant-race case, except here
there's no DB uniqueness constraint to fall back on (the cooldown is a
plain in-memory table, not a DB row), so the fix has to be structural:

**Requirement:** write the new cooldown timestamp **before** the awaited
ox_inventory call, immediately after the cooldown check passes (mirroring
`relayBark`'s "check, then immediately set, then do the rest of the work"
ordering) — not after the result comes back. If the search is later
rejected for an unrelated reason (target vanished mid-await, etc.), that's
an acceptable minor false-positive on the cooldown (the caller can retry
after the normal cooldown window) and is a far smaller problem than a
double-search bypassing the rate limit entirely. Flag this ordering
explicitly in `server/search.lua`'s implementation — it is not obvious from
reading `certifications.lua`'s DB-race pattern that the *ordering* of the
in-memory write relative to the await, not a DB constraint, is the fix
needed here.

---

## 4. No stated cross-check that the resolved entity's real type matches the client's claimed `targetType`

§11.4 item 2's signature is `(targetType: 'vehicle'|'person', targetNetId:
number)`. The contract describes resolving `targetNetId` to a live entity
and confirming *existence* and *proximity*, but never explicitly states
that the server confirms the **resolved entity's actual type matches the
claimed `targetType`** before doing a type-specific inventory read. Two
concrete gaps this leaves open if not added explicitly:

- A client could claim `targetType = 'vehicle'` while supplying the netId
  of a player ped (or vice versa). Whether this "just errors out safely" or
  does something worse depends entirely on how permissively the chosen
  ox_inventory export handles being handed an entity of the wrong kind —
  not something to assume is safe without an explicit check. Add:
  `GetEntityType(entity)` must equal the vehicle/ped type expected for the
  claimed `targetType`, rejected with `ok = false` otherwise (a new
  `reason`, e.g. `'target_type_mismatch'`, fits the existing
  `LEASH_REJECT_MESSAGES`-style reason-string convention §11.4 already
  cites).
- For `targetType = 'person'` specifically, §11.5 scopes this to
  "player-only" (NPC/ped variant flagged as a stretch item, not required).
  That scoping needs an explicit **enforcement**, not just a documented
  intent: confirm `IsPedAPlayer(entity)` and that the entity actually
  belongs to a currently-connected player (resolve via
  `NetworkGetEntityOwner`/`GetPlayerFromServerId`-equivalent lookup) before
  treating it as a searchable "person" and calling into
  ox_inventory's player-inventory path. Without this, a client handing in
  an NPC ped's netId as a "person" search target is either silently
  rejected by whatever export is called (fine, but accidental) or produces
  undefined behavior against a non-player inventory lookup (not fine) —
  this should be a deliberate, stated check, not an emergent property of
  whichever export happens to be chosen per §11.6's still-open "exact
  export name TBD" item.

---

## 5. Per-(K9, target) cooldown is a stated, deliberate tradeoff — but its multi-actor exposure isn't discussed

§11.5 is explicit that the cooldown is scoped per-pair "not globally," which
reads as a considered choice (presumably: two *different* legitimate K9
units should each be able to search the same vehicle without waiting on
each other's cooldown, e.g. during a joint traffic stop). Flagging the
consequence rather than asserting it's wrong: this same scoping means nothing
stops **two colluding or two alt-account K9-certified characters** (or one
player round-tripping between two certified characters, if that's even
possible under this server's account model) from re-probing the exact same
target back-to-back with no target-side throttle at all — each individual
searcher is within their own per-pair cooldown, so the target itself has no
floor on how often it can be re-read. Combined with finding §1
(server-wide broadcast) this is lower-severity once §1 is fixed (a
distance-filtered broadcast means only people actually near the target ever
learn anything from a repeat search anyway), but worth an explicit decision
in the contract doc: is a secondary, lighter **per-target-only** cooldown
(independent of searcher identity) wanted as a backstop, or is "any
certified K9 can always search any target, other units' cooldowns don't
apply to me" the intended behavior? Either answer is defensible — flagging
so it's a decision, not a default that fell out of not considering the
multi-searcher case.

---

## 6. `totalWeight`/`contrabandFound` returned to the requester — confirm this is bounded to the requester only

§11.4 item 2's return type (`{ ok, reason?, contrabandFound?, totalWeight?,
alertTier? }`) and §11.5's acceptance bullet ("a successful search still
reports `contrabandFound`/`totalWeight` to the requesting K9 player" even
when `ContrabandAlerts` is off) are explicit and deliberate — the K9
handler who performed a real, gated, proximity-checked search is meant to
learn the real number, not just a tier. That's a defensible trust boundary
(this is the same class of "real capability grant" as certification itself,
per §11.3's own framing: "search reveals real, server-verified inventory
contents (a real capability, same category as certification)"). No change
requested here — just tying it explicitly to finding §1: the boundary this
resource is drawing is "the requester gets the real number, the broadcast
gets a tier-only cue, nobody else gets anything," and that boundary only
holds if the broadcast path is actually distance-filtered and tier-only as
required in §1. If §1 isn't fixed, this deliberate requester-only trust
grant is moot — everyone gets the same intel as the requester via the
broadcast side-channel regardless of how carefully the callback return
value itself is scoped.

---

## 7. Minor: keying the person-search cooldown by ped netId rather than citizenid

Not blocking, but worth a design note: §11.4 item 2 keys the search
cooldown on `(source, targetNetId)`. For `targetType = 'person'`, if the
target's ped entity is ever recreated (respawn flow that swaps the
underlying ped rather than reusing it — framework-dependent, not confirmed
either way for this server), the netId changes and the per-pair cooldown
silently resets for what's conceptually "the same person." Recommend
keying the person-search cooldown on the target's **citizenid** instead of
raw ped netId (resolved once at request time, same as
`certifications.lua`'s citizenid-keyed cache) so it survives a ped
recreation — this is a robustness nice-to-have, not a security hole on its
own, since worst case it just under-throttles a respawn-triggered edge
case rather than granting any capability that shouldn't exist.

---

## 8. Summary — items to resolve before `server/search.lua` is written

- [ ] **Blocking:** contraband alert broadcast must be distance-filtered,
      not a global `-1` broadcast like `relayBark`'s (§1).
- [ ] **Blocking:** broadcast payload carries `netId` + `alertTier` only —
      never `totalWeight`/`contrabandFound` (§1).
- [ ] Add a flat per-source cooldown on `searchTarget` (any target),
      independent of the existing per-`(source, targetNetId)` cooldown,
      sized around `Config.SearchZones.sniffAnimDurationMs` (§2).
- [ ] Write the per-pair cooldown timestamp **before** the awaited
      ox_inventory read, not after — closes a real check-then-act race this
      resource hasn't needed to handle before now (§3).
- [ ] Cross-validate the resolved entity's real type against the claimed
      `targetType`; for `'person'`, confirm `IsPedAPlayer` and that it
      resolves to a currently-connected player before treating it as
      searchable (§4).
- [ ] Explicit decision (not a default): does a per-target-only backstop
      cooldown exist alongside the per-`(K9, target)` one, given multiple
      certified K9s can otherwise re-probe the same target with no
      target-side floor (§5).
- [ ] Confirm §6's requester-only trust grant (`totalWeight` to the
      searcher) actually stays requester-only once §1's broadcast fix
      lands — the two are coupled.
- [ ] Nice-to-have: key the person-search cooldown by citizenid, not raw
      ped netId (§7).

None of the above require rewriting §11's design — they're gaps/refinements
on top of an otherwise sound, already-server-authoritative contract. Will
re-review once `server/search.lua` exists against this checklist.
