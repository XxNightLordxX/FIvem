# Phase 2 design note — Door Interaction (nudge-open / scratch-to-alert)

Status: DESIGN ONLY — no `.lua` written against this note. **Superseded/
realigned once**: SPEC.md's real Phase 2 detailed spec landed in §11 after
this note's first draft (which was written against §2/§6.3's placeholder
one-liner only, before §11 existed). This version is aligned to §11.2
(config), §11.3 (file plan), §11.4 (event contract), §11.5 (acceptance
criteria), and §11.6 (reality-check) as the authoritative source — where
this note's first draft guessed something §11 has since settled
differently, that guess is called out and corrected below rather than
silently dropped, so the "what changed and why" is visible.

Author: coder-frontend. Native claims are graded by confidence
(HIGH/MEDIUM/LOW), same convention `client/movement.lua`'s Sit-anim comment
already established. **native-api-assistant was not reachable this session**
via SendMessage (`"No agent named 'native-api-assistant' is reachable"`) —
SPEC.md §11.6 notes native-api-assistant *did* independently reconfirm the
vision natives (`SetSeethrough`/`SetNightvision`) for the product-agent's
Phase 2 pass, so that verification already happened at the spec level for
vision; it has **not** yet happened for anything door-specific (push-force
natives, door-prop detection heuristics) — that gap is this note's own
remaining verification checklist in §7.

---

## 1. What SPEC.md §11 already settled (do not re-litigate)

- **File placement: extends `client/movement.lua`, no new file.** Per
  §11.3's file/module plan: "a small, single self-action-shaped feature
  (find nearest door within `Config.DoorInteraction.interactDistance`, act
  on it) — the same shape as the existing Sit action already in this file,
  not big enough on its own to justify a fifth file." My first draft
  proposed a new door-detection scheme without pinning down which file
  owns it — that's now settled: `client/movement.lua`, alongside camera/
  Sit/leash.
- **Nudge-open is fully client-local, no server event at all** — mirrors
  `client/vehicle.lua`'s documented §4.1 exception (vehicle entry/exit
  grants no real capability, so no server round-trip is needed). Same
  reasoning applied here: nudging a door that's *already unlocked* grants
  nothing a modified client couldn't already get by calling the same
  client-only door-prop natives on itself directly.
- **`nudgeRequiresUnlocked = true` is a hard behavioral guarantee, not a
  toggle** (§11.2, §11.5): nudge must never function as a lockpick bypass,
  under any config value — the shipped default is `true` and per §11.6 it
  "is not intended to ever ship as `false`." My first draft's "unknown
  state = don't offer the feature" fallback (§3.2 of the prior draft) is
  now the *specific, spec-mandated* behavior, not just this note's own
  cautious lean: if the interaction code cannot positively confirm a door
  is unlocked, nudge-open must not be offered for it, full stop.
- **Scratch-to-alert gets a thin, bark-shaped server round-trip** — this
  is the one place my first draft under-specified vs. what actually landed:
  I'd flagged the *recipient scope* (leash partner vs. broader dispatch-style
  alert) as an open question needing coder-backend's sign-off. §11.4 item 5
  and §11.3's `server/main.lua` row settle it definitively: **it's a plain
  server-wide broadcast, structurally identical to `relayBark`**, not a
  targeted "alert the handler specifically" mechanism at all — despite the
  feature's own name. See §4 below for what this means for the design.
- **No door-lock-resource integration is attempted for Phase 2** (§11.6,
  §9 item 12) — narrower than my first draft's §3.2 recommendation ("prefer
  integrating with the server's door-lock resource as the source of truth").
  §11.6 explicitly chose the narrower, safe path instead: nudge-open only
  ever needs to know "is this specific door already unlocked," and rather
  than guessing at a specific door-lock resource's API without confirming
  it exists on the target server, Phase 2 scopes nudge to the (real, if
  narrower) subset of doors where that fact is knowable without any
  integration at all — see §3 below for what that subset actually is.
- **Sub-phase ordering (§11.1)**: scratch-to-alert is in sub-phase **2a**
  (independent, parallelizable, start immediately — "pure client-side...
  with no dependency on anything else in this phase"). Nudge-open is
  explicitly split out as its own row, scoped as "a stretch item within
  `DoorInteraction`, not a blocker for shipping scratch-to-alert." **This
  means the two halves can and should ship independently** — scratch first,
  nudge as a follow-up once door detection is settled.

---

## 2. Config shape (§11.2, verbatim — do not re-derive)

```
Config.DoorInteraction = {
    interactDistance      = 1.5,
    nudgeRequiresUnlocked = true,  -- hard requirement, never a toggle in practice
    scratchCooldownMs     = 3000,
}
```

No `Config.K9Doors` list is introduced — my first draft's proposed
door-list config (§2/§3 of the prior version) is **not** what §11 chose.
Instead, door detection is proximity-based at interaction time (find the
nearest door-shaped entity within `interactDistance`), same shape as
`client/vehicle.lua`'s `FindNearestK9Vehicle` scanning `GetGamePool` rather
than a maintained config list — consistent with door instances not being a
small, curated set the way `Config.K9Vehicles` models are.

---

## 3. Door detection and "is it unlocked" — the part still needing a real answer

This is the one area §11 flags as genuinely unresolved rather than settled
(§11.6's door-interaction paragraph, §9 item 12) — this note's job is to
lay out the concrete options for whoever implements it, not to invent a
false certainty.

### 3.1 Finding a nearby "door entity" at all

There is no generic, safe native predicate for "is this object entity an
interactive door" — GTA door props aren't tagged with a queryable "I am a
door" flag independent of the door-system registry discussed in §3.2 below.
Two realistic approaches for the proximity scan `client/movement.lua` would
need (mirroring `FindNearestK9Vehicle`'s `GetGamePool('CVehicle')` scan
shape, but for objects):

1. **Model-name heuristic scan**: `GetGamePool('CObject')`, filter by
   `GetEntityModel` against a small, checked-in list of common GTA door
   prop model hashes (many follow recognizable naming patterns in
   community-maintained model lists, e.g. `v_ilev_*door*`,
   `prop_*_door_*`, `plyr_dlc_gengarage_door`), then take the nearest match
   within `Config.DoorInteraction.interactDistance`. **LOW-MEDIUM
   confidence** this covers the common case well — door prop naming is not
   fully standardized across every interior in the base map, so this will
   likely miss some real doors and this should be treated as a
   best-effort heuristic, not a complete enumeration. A short, reviewed
   list checked in as a small local table (not `Config.*`, since it's an
   implementation detail of "how do we find door objects" rather than a
   server-owner-tunable value) is the right shape if this path is taken.
2. **Rely on whatever interior/MLO resource already tags its own doors**
   (if the target server's interiors are MLO-based and the MLO/door-lock
   resource already exposes a list of door entities/coords) — same
   "integration point, not guessable" caveat as door-lock state in §3.2,
   and explicitly **not required** for Phase 2 per §11.6's narrow-scope
   decision; flagged as a nice-to-have upgrade path, not something to
   block the model-name heuristic on.

Either way, whichever entity is resolved needs a **network id** —
`Config.DoorInteraction`-gated scratch-to-alert's server event takes a
`doorNetId: number` (§11.4 item 5), so the resolved door object must be a
real networked entity (`NetworkGetNetworkIdFromEntity`), not a raw local
handle, mirroring `client/vehicle.lua`'s "store the network id, not the
raw handle" pattern for exactly the same staleness reason documented
there.

### 3.2 Determining "already unlocked" for nudge, without a door-lock integration

§11.6 is explicit: "GTA has no generic native to query or set lock state on
arbitrary map/interior doors the way it does for vehicle doors" and door
lock state for MLO/interior doors "lives entirely inside a separate,
server-specific door-lock resource's own data model... with no vanilla
native surface at all to query it from outside that resource." Given
Phase 2 deliberately does **not** integrate with any such resource, the
realistic subset of doors where "unlocked" is knowable without integration
is narrow:

1. **Game "door system" doors** (the same category my first draft's §3.1.1
   described) — a global registry keyed by a `doorHash`, queryable via
   natives IF the specific door is registered in it (either shipped
   pre-registered by Rockstar for a subset of map doors, or registered by
   another script via `ADD_DOOR_TO_SYSTEM`). For this narrow subset, a
   genuine native lock-state read is possible. This is likely a *small*
   fraction of doors on any given interior-heavy FiveM server, but it's
   the one category where "unlocked" is a real, checkable fact with no
   external integration needed.
2. **Plain physics-object doors with no lock concept applied to them at
   all** — i.e., doors nobody has scripted a lock onto. These are
   trivially "unlocked" by definition (there's no lock system involved),
   so nudge is safe to offer unconditionally for this category — the risk
   here is a false negative (missing that some *other* resource silently
   treats this door as "locked" via a mechanism outside this resource's
   knowledge, e.g. freezing the object at a closed heading with no
   registry entry at all) rather than a false positive that would violate
   `nudgeRequiresUnlocked`. Given the hard-requirement framing, **this
   ambiguity should be resolved conservatively**: if there's any doubt
   whether a resolved door object might be externally lock-managed, the
   safer default is to *not* offer nudge for it rather than risk it being
   perceived as bypassing a lock this resource simply couldn't see. This
   is this note's own conservative lean, not a spec mandate — flagging it
   for coder-security/whoever implements this to confirm, since it trades
   away feature coverage for a hard safety guarantee (§11.5's stated
   priority: "nudge must never open a locked door under any circumstance;
   this is a hard behavioral guarantee, not just a default").
3. Any door not confidently resolved into category 1 or 2 above: **nudge
   is not offered at all** for it (only scratch-to-alert, which per §11.5
   is available "regardless of lock state" and has no such constraint).

Net effect: nudge-open, as scoped for Phase 2, will realistically only
ever appear for a real subset of doors on a given server — likely fewer
than a player might expect from the feature's name. §11.6 already frames
this as an accepted, deliberate tradeoff ("this makes nudge-open safe to
ship without an integration decision, at the cost of it being a fairly
thin feature") — this note is not proposing to fix that gap, just
documenting precisely where the line falls so whoever implements it
doesn't accidentally widen it back into a lock-bypass by being too
permissive in category 2 above.

---

## 4. Mechanics

### 4.1 Nudge-open (client-only, no server event — §11.3/§11.5/§11.6)

- Resolve nearest door entity per §3.1, within `Config.DoorInteraction.interactDistance`.
- Confirm category per §3.2; no-op (or don't even show the option) if not
  confidently "unlocked."
- Apply a one-shot push force/impulse to the door object (exact native
  TBD, see §7 — `ApplyForceToEntity` or the FiveM-native equivalent is the
  expected tool) in the direction of the K9's facing/approach, plus a
  local animation/sound cue on the K9 for legible player feedback (same
  reasoning as my first draft: a deliberate scripted push reads as an
  intentional action better than relying on incidental ped-vs-door
  collision physics, which may not even apply distinctly to a quadruped
  model).
- No-op if the door is already open past some threshold (avoid
  re-triggering an impulse into an already-swinging object).
- **Zero server involvement of any kind** — this is the one thing to get
  right structurally even before the native details are nailed down: no
  `TriggerServerEvent`, no callback, nothing. If a later reviewer sees a
  server round-trip anywhere in a nudge code path, that's a structural
  deviation from §11.3/§11.5/§11.6's explicit, repeated framing, not a
  judgment call left open by this note.

### 4.2 Scratch-to-alert (thin server round-trip, mirrors `relayBark` exactly — §11.3/§11.4 item 5)

Client (`client/movement.lua`, per §11.4 item 6's file placement for the
*receiving* handler):
- Resolve nearest door entity per §3.1 (no lock-state check needed at all
  — §11.5: "available on any door... regardless of lock state").
- Play a scratch/paw animation + sound cue locally on the K9 (same
  unresolved scenario-name caveat as my first draft — no "dog scratches at
  door" scenario has been confirmed to exist; treat as unconfirmed, verify
  before implementation, same standard `movement.lua`'s Sit action already
  applied to its own scenario names).
- `TriggerServerEvent('qbx_k9unit:server:relayDoorScratch', doorNetId)` —
  the resolved door's **network id**, not a raw handle, so the server can
  resolve it back to a live entity for the receiving clients (mirrors
  `relayBark`'s `netId` argument, except here the netId is the door's, not
  the sender's own ped's).

Server (`server/main.lua`, extends — §11.3's `server/main.lua` row, §11.4
item 5):
- `RegisterNetEvent('qbx_k9unit:server:relayDoorScratch', function(doorNetId) ... end)`,
  structurally identical to the existing `relayBark` handler immediately
  above it in that file:
  - Re-check `Config.Features.DoorInteraction` (silent no-op if false, per
    §3's "disabled feature must be a server-side no-op" requirement,
    applied here exactly as `relayBark` already applies it to
    `Config.Features.BasicBarkSounds`).
  - Re-check `HasK9Access(source)` (reuse the existing global from
    `server/certifications.lua`, same as `relayBark` — do not re-derive
    the job/cert check here).
  - Defensive payload type-check on `doorNetId` (mirrors `relayBark`'s
    `type(barkType) ~= 'string'` guard — here, `type(doorNetId) ~=
    'number'`).
  - Per-source cooldown table using `Config.DoorInteraction.scratchCooldownMs`,
    same pattern as `relayBark`'s `BARK_COOLDOWN_MS`/`lastBarkAt` (a
    sibling table, e.g. `lastDoorScratchAt`, not a shared table with bark's
    — these are two independently-cooldowned actions per §11.4/§11.5,
    don't conflate them into one rate limiter).
  - Broadcast: `TriggerClientEvent('qbx_k9unit:client:playDoorScratch', -1, doorNetId)`
    — same broadcast-to-everyone shape as `relayBark`'s
    `TriggerClientEvent(..., -1, ...)`. **Note the corollary from §1
    above**: despite the feature's name, this is not targeted at "the
    handler" in any way that differs from bark's own "anyone nearby with
    it streamed in" broadcast — any connected client whose game has the
    door entity streamed in will play the sound, not specifically a
    leash partner or on-duty officer. If a more targeted delivery is
    wanted later, that's a real behavioral change from what §11.4/§11.6
    describe as "confirmed achievable, no caveats" (i.e., the *simple*
    broadcast version), not something to quietly build differently than
    documented here.
  - Add the disconnect-cleanup line (`lastDoorScratchAt[src] = nil`) to
    the existing `playerDropped` handler in `server/main.lua`, alongside
    the existing `lastBarkAt[src] = nil` / `lastLeashRequestAt[src] = nil`
    lines — same "don't leak one cooldown entry per session" reasoning
    already documented there.

Client receiver (`client/movement.lua`, per §11.4 item 6):
- `RegisterNetEvent('qbx_k9unit:client:playDoorScratch', function(netId) ... end)`
  — mirrors `client/main.lua`'s `playBark` handler exactly: resolve the
  network entity, no-op if not streamed in (`NetworkDoesEntityExistWithNetworkId`),
  play a sound from that entity. The only structural difference from
  `playBark` is which file it lives in (`movement.lua`, since this file
  now owns door interaction end-to-end, vs. `main.lua` owning bark) — the
  handler body shape should be copy-structurally identical otherwise.

---

## 5. Radial menu — not touched by this feature

Per §11.3's `client/radial.lua` row: door interaction is **not** added to
the K9 Unit radial menu (it's an ox_target-or-equivalent entity option,
same category as the existing leash/certify options already registered
directly in `client/movement.lua`, not a self-action the way Sit is) —
consistent with the vision toggles also being keybind-only, not radial
items. Nothing in `client/radial.lua` needs to change for this feature.

---

## 6. Security framing (for coder-security's eventual review)

- **Nudge**: no server-side check exists or is needed, by design (§4.1) —
  the entire security question is "can nudge ever bypass a real lock,"
  which is a *client-side logic correctness* question (§3.2), not a trust
  boundary question, since nothing server-authoritative is at stake here
  (same category as vehicle entry/exit's §4.1 exception). The one thing
  worth a second look from coder-security specifically: confirm the §3.2
  conservative-default reasoning (when in doubt, don't offer nudge) is
  actually followed in the implementation, since "hard behavioral
  guarantee" language in §11.5 puts real weight on getting this right
  rather than optimizing for feature coverage.
- **Scratch-to-alert**: identical risk profile to `relayBark` — re-verify
  `Config.Features.DoorInteraction` + `HasK9Access(source)` server-side
  regardless of client claims, cooldown-gated to prevent spam, no
  inventory/lock-state information is revealed by this event at all (§11.5:
  "No inventory/lock-state reveal of any kind — purely a sound cue, which
  is exactly why it's allowed to be this simple"). Nothing beyond
  `relayBark`'s existing, already-reviewed pattern is introduced here.

---

## 7. Native / implementation verification checklist (pending, before real code)

native-api-assistant should confirm these before `client/movement.lua`'s
door-interaction extension is actually written — none are asserted as
certain here:

| Item | Confidence this session |
|---|---|
| Exact push/impulse native for swinging a physics door object (`ApplyForceToEntity` name/signature, appropriate force-type constant, bone/offset targeting) | MEDIUM that the native family exists and is the right general tool; LOW on exact tuning parameters for a convincing door-swing specifically |
| `DOES_DOOR_EXIST` / door-system state-query natives, for category-1 doors in §3.2 (same checklist as this note's prior draft — reproduced here since §11 didn't resolve these specific signatures) | MEDIUM on names/existence, LOW-MEDIUM on exact parameter shapes |
| Whether there's any lighter-weight way to detect "this CObject is currently a swinging/hinged door" (vs. a static prop) short of a model-hash list, e.g. an entity-flag or bone-name check | Not verified — flagged as worth asking about directly rather than assumed absent |
| A representative, checked list of common door prop model hashes for the §3.1 heuristic scan, if that path is taken | Not compiled this session — needs either native-api-assistant or a community model-list cross-check, same two-source-agreement standard `movement.lua`'s Sit scenario verification already used |
| A "dog scratches at door" scenario/clipset name, for the scratch animation | Not confirmed to exist at all this session — treat as unconfirmed, not assumed absent, same caveat `movement.lua`'s Sit-action header already applies to its own scenario names |

---

## 8. What this note deliberately still does not decide

- The exact model-hash list (or alternative detection method) for §3.1 —
  a real implementation task, not a design-note-level decision.
- The exact push-force magnitude/direction tuning for a convincing nudge
  animation — a feel/tuning knob, not a structural decision.
- Whether a future phase revisits the door-lock-resource integration
  §11.6/§9 item 12 explicitly deferred — out of scope for Phase 2 per the
  landed spec, not reopened here.
